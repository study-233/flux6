package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"gopkg.in/yaml.v3"
)

const probeErrorTimeout = "timeout"
const browserUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

var windowsProbeSlots = make(chan struct{}, 4)

type ProbeResult struct {
	StatusCode                  int
	Delay                       int64
	Body, Url, Error, lowerBody string
	Chains                      []string
	header                      http.Header
}
type probeRequest struct {
	method, url string
	headers     map[string]string
	body        []byte
	maxBody     int64
	noRedirect  bool
	until       func(string) bool
}
type serviceEnv struct {
	ctx       context.Context
	transport http.RoundTripper
	valid     func() bool
}

func (e serviceEnv) get(address string, cap int64) *ProbeResult {
	return e.send(probeRequest{method: http.MethodGet, url: address, maxBody: cap})
}
func (e serviceEnv) scan(address string, until func(string) bool) *ProbeResult {
	return e.send(probeRequest{method: http.MethodGet, url: address, maxBody: serviceScanMaxBody, until: until})
}
func (e serviceEnv) send(query probeRequest) *ProbeResult {
	result := &ProbeResult{Url: query.url, Error: serviceFailed}
	if e.valid != nil && !e.valid() {
		return result
	}
	ctx, cancel := context.WithTimeout(e.ctx, 10*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, query.method, query.url, bytes.NewReader(query.body))
	if err != nil {
		return result
	}
	request.Header.Set("User-Agent", browserUserAgent)
	for key, value := range query.headers {
		request.Header.Set(key, value)
	}
	client := &http.Client{Transport: e.transport, CheckRedirect: func(_ *http.Request, via []*http.Request) error {
		if query.noRedirect {
			return http.ErrUseLastResponse
		}
		if len(via) >= 5 {
			return errors.New("too many redirects")
		}
		if e.valid != nil && !e.valid() {
			return context.Canceled
		}
		return nil
	}}
	start := time.Now()
	response, err := client.Do(request)
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			result.Error = probeErrorTimeout
		}
		return result
	}
	defer response.Body.Close()
	result.StatusCode, result.header = response.StatusCode, response.Header
	reader := io.LimitReader(response.Body, min(query.maxBody, serviceScanMaxBody))
	var body bytes.Buffer
	buffer := make([]byte, 32*1024)
	for {
		count, readErr := reader.Read(buffer)
		body.Write(buffer[:count])
		if query.until != nil && query.until(body.String()) {
			break
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			if errors.Is(readErr, context.DeadlineExceeded) {
				result.Error = probeErrorTimeout
			}
			return result
		}
	}
	if e.valid != nil && !e.valid() {
		return result
	}
	result.Body, result.Error = body.String(), ""
	result.Delay = max(1, time.Since(start).Milliseconds())
	return result
}

func (h *helper) diagnosticProbe(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	var input struct {
		Kind    string   `json:"kind"`
		Session string   `json:"session"`
		Names   []string `json:"names"`
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&input) != nil || decoder.Decode(new(any)) != io.EOF ||
		(input.Kind != "ip" && input.Kind != "services") || len(input.Names) > 13 {
		writeJSON(w, 400, map[string]string{"error": "诊断参数无效"})
		return
	}
	h.mu.Lock()
	h.downloads.mu.Lock()
	channel := h.downloads.channel
	valid := channel != nil && channel.session == input.Session && input.Session != ""
	h.downloads.mu.Unlock()
	var config struct {
		MixedPort int `yaml:"mixed-port"`
	}
	data, err := os.ReadFile(filepath.Join(h.root, "state", "mihomo.yaml"))
	if err == nil {
		err = yaml.Unmarshal(data, &config)
	}
	h.mu.Unlock()
	if !valid || err != nil || config.MixedPort < 1 || config.MixedPort > 65535 {
		writeJSON(w, 409, map[string]string{"error": "请先连接免流后重试诊断"})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 40*time.Second)
	defer cancel()
	if channel.probeContext != nil {
		stop := context.AfterFunc(channel.probeContext, cancel)
		defer stop()
	}
	select {
	case windowsProbeSlots <- struct{}{}:
		defer func() { <-windowsProbeSlots }()
	case <-ctx.Done():
		writeJSON(w, 408, map[string]string{"error": "诊断超时"})
		return
	}
	// Read the active YAML, never the saved preferences which may await reconnect.
	// Explicit proxying prevents a stopped tunnel from silently testing direct access.
	transport := &http.Transport{
		Proxy:                 http.ProxyURL(&url.URL{Scheme: "http", Host: net.JoinHostPort("127.0.0.1", strconv.Itoa(config.MixedPort))}),
		DialContext:           (&net.Dialer{Timeout: 5 * time.Second}).DialContext,
		TLSHandshakeTimeout:   8 * time.Second,
		ResponseHeaderTimeout: 10 * time.Second,
	}
	defer transport.CloseIdleConnections()
	env := serviceEnv{ctx: ctx, transport: transport, valid: func() bool {
		h.downloads.mu.Lock()
		defer h.downloads.mu.Unlock()
		return h.downloads.channel == channel
	}}
	if input.Kind == "ip" {
		const address = "https://www.cloudflare.com/cdn-cgi/trace"
		result := env.get(address, serviceSmallMaxBody)
		response := map[string]any{"url": address, "body": result.Body, "delay": result.Delay}
		if result.Error != "" {
			response["error"] = result.Error
		}
		writeJSON(w, 200, response)
		return
	}
	items := []ServiceCheckItem{}
	for _, checker := range serviceCheckers {
		wanted := len(input.Names) == 0
		for _, name := range input.Names {
			if name == checker.name {
				wanted = true
			}
		}
		if !wanted {
			continue
		}
		item := checker.check(env)
		item.Name, item.CheckedAt = checker.name, time.Now().UnixMilli()
		items = append(items, item)
	}
	if !env.valid() {
		writeJSON(w, 409, map[string]string{"error": "连接已变化，请重新检测"})
		return
	}
	writeJSON(w, 200, map[string]any{"items": items})
}
