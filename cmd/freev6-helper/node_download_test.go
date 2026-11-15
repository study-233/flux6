package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"gopkg.in/yaml.v3"
)

func TestDownloadRequestGuards(t *testing.T) {
	h := &helper{}
	h.downloads.activate(&downloadChannel{session: "current", members: map[string][]string{accessGroup: {"a/b"}}})
	for _, sample := range []struct {
		session, group, name string
		want                 int
	}{
		{"old", accessGroup, "a/b", 409}, {"current", accessGroup, "REJECT", 400}, {"current", "other", "a/b", 400},
	} {
		body, _ := json.Marshal(map[string]string{"session": sample.session, "group": sample.group, "node": sample.name})
		w := httptest.NewRecorder()
		h.measureNode(w, httptest.NewRequest("POST", "/", strings.NewReader(string(body))))
		if w.Code != sample.want {
			t.Fatalf("got %d want %d", w.Code, sample.want)
		}
	}
}

func TestDownloadSampleBounds(t *testing.T) {
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/oversize":
			w.Header().Set("Content-Length", strconv.Itoa(downloadLimit+1))
		case "/partial":
			io.WriteString(w, "partial")
			w.(http.Flusher).Flush()
			<-r.Context().Done()
		case "/error":
			w.WriteHeader(503)
		}
	}))
	defer server.Close()
	for _, path := range []string{"/oversize", "/error", "/empty"} {
		if _, err := sampleDownload(context.Background(), server.Client(), downloadPlan{server.URL + path, 1, downloadLimit, time.Second}); err == nil {
			t.Fatalf("accepted %s", path)
		}
	}
	r, err := sampleDownload(context.Background(), server.Client(), downloadPlan{server.URL + "/partial", 1, downloadLimit, 350 * time.Millisecond})
	if err != nil || r.Bytes != 7 || r.BytesPerSecond <= 0 {
		t.Fatalf("partial: %+v %v", r, err)
	}
}

func TestFourStreamsShareTimeAndByteBudget(t *testing.T) {
	var requests atomic.Int32
	ready := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if requests.Add(1) == 4 {
			close(ready)
		}
		select {
		case <-ready:
		case <-r.Context().Done():
			return
		}
		if r.URL.Query().Get("bytes") != "8388608" {
			t.Errorf("incorrect per-stream budget %s", r.URL)
		}
		w.WriteHeader(200)
		w.(http.Flusher).Flush()
		time.Sleep(100 * time.Millisecond)
		io.WriteString(w, strings.Repeat("x", 1000))
	}))
	defer server.Close()
	p := manualPlan(4)
	p.url = server.URL + strings.TrimPrefix(p.url, downloadTarget)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	r, err := sampleDownload(ctx, server.Client(), p)
	if err != nil || r.Bytes != 4000 || r.DurationMS < 90 || r.BytesPerSecond < 1000 || r.BytesPerSecond > 45000 {
		t.Fatalf("aggregate %+v %v", r, err)
	}
}

// Opt in with a verified Windows mihomo binary. Only CONNECT to this test's
// loopback TLS server is accepted by either node. TUN and DNS are disabled.
func TestDownloadPinnedCoreLoopback(t *testing.T) {
	testCoreLoopback(t, false)
}

func TestAdaptivePoolCoreLoopback(t *testing.T) {
	testCoreLoopback(t, true)
}

func testCoreLoopback(t *testing.T, balanced bool) {
	binary := os.Getenv("FLUX6_TEST_MIHOMO")
	if binary == "" || runtime.GOOS != "windows" {
		t.Skip("requires a local Windows mihomo test executable")
	}
	started := make(chan struct{}, 1)
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		time.Sleep(12 * time.Millisecond)
		io.WriteString(w, "download sample")
		if r.URL.Path == "/slow" {
			w.(http.Flusher).Flush()
			started <- struct{}{}
			<-r.Context().Done()
		}
	}))
	defer server.Close()
	target, _ := url.Parse(server.URL)
	health := "http://127.0.0.1:1/health"
	healthHost := ""
	if balanced {
		healthServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(204) }))
		defer healthServer.Close()
		health = healthServer.URL
		healthHost = healthServer.Listener.Addr().String()
	}
	proxies := []map[string]any{}
	names := []string{"Node A", "节点 / B"}
	if balanced {
		for len(names) < 28 {
			names = append(names, fmt.Sprintf("接入点 %d", len(names)+1))
		}
	}
	hits := make([]atomic.Int32, len(names))
	for i, name := range names {
		relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Method != "CONNECT" || (r.Host != target.Host && (healthHost == "" || r.Host != healthHost)) {
				http.Error(w, "loopback only", 403)
				return
			}
			up, err := net.Dial("tcp", r.Host)
			if err != nil {
				http.Error(w, "fixture unavailable", 502)
				return
			}
			defer up.Close()
			conn, buf, err := w.(http.Hijacker).Hijack()
			if err != nil {
				return
			}
			defer conn.Close()
			if r.Host == target.Host {
				hits[i].Add(1)
			}
			buf.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n")
			buf.Flush()
			go func() { io.Copy(up, buf); up.Close() }()
			io.Copy(conn, up)
		}))
		defer relay.Close()
		proxies = append(proxies, map[string]any{"type": "http", "name": name, "server": "127.0.0.1", "port": relay.Listener.Addr().(*net.TCPAddr).Port})
	}
	// On machines where 9090 is already reserved or in use, leave its owner alone.
	if occupied, err := net.ListenTCP("tcp4", net.TCPAddrFromAddrPort(defaultController)); err == nil {
		defer occupied.Close()
	}
	port, err := reserveController(defaultController, true)
	if err != nil {
		t.Fatal(err)
	}
	address := port.Addr().(*net.TCPAddr).AddrPort()
	defer port.Close()
	if address == defaultController || !address.Addr().IsLoopback() {
		t.Fatalf("expected a different loopback address: %s", address)
	}
	conf, _ := yaml.Marshal(map[string]any{"mode": "direct", "external-controller": defaultController.String(), "secret": "fixture",
		"tun": map[string]bool{"enable": false}, "dns": map[string]bool{"enable": false}, "log-level": "error", "proxies": proxies,
		"proxy-groups": []any{map[string]any{"name": accessGroup, "type": "url-test", "proxies": names, "url": health, "interval": 0}}, "rules": []string{"MATCH,REJECT"}})
	c, config, err := prepareDownloadChannel(string(conf), "fixture", address, balanced)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "config.yaml")
	if balanced {
		var fixture map[string]any
		if err := yaml.Unmarshal([]byte(config), &fixture); err != nil {
			t.Fatal(err)
		}
		// Route our loopback test clients through the same public group as user traffic.
		fixture["listeners"].([]any)[0].(map[string]any)["proxy"] = accessGroup
		data, err := yaml.Marshal(fixture)
		if err != nil {
			t.Fatal(err)
		}
		config = string(data)
	}
	if err := os.WriteFile(path, []byte(config), 0600); err != nil {
		t.Fatal(err)
	}
	port.Close()
	cmd := exec.Command(binary, "-d", dir, "-f", path)
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { cmd.Process.Kill(); cmd.Wait() }()
	c.pid = cmd.Process.Pid
	deadline := time.Now().Add(8 * time.Second)
	for !c.ownsListeners() {
		if time.Now().After(deadline) {
			t.Fatal("private core listeners not ready")
		}
		time.Sleep(80 * time.Millisecond)
	}
	if got := recoverControllerPort(path, c.pid); got != address.Port() {
		t.Fatalf("recovered controller %d, want %d", got, address.Port())
	}
	if got := recoverControllerPort(path, os.Getpid()); got != 0 {
		t.Fatal("trusted another process's controller")
	}
	connections := nodeDownloads{channel: c}
	if session, port := connections.connection(c.pid, true); session != c.session || port != address.Port() {
		t.Fatal("status advertised a different connection")
	}
	current := func(group string) string {
		req, _ := http.NewRequest("GET", "http://"+c.controller.String()+"/proxies/"+url.PathEscape(group), nil)
		req.Header.Set("Authorization", "Bearer fixture")
		resp, err := localController.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		var data struct{ Now string }
		if err = json.NewDecoder(resp.Body).Decode(&data); err != nil {
			t.Fatal(err)
		}
		return data.Now
	}
	roots := server.Client().Transport.(*http.Transport).TLSClientConfig
	if balanced {
		testActivePool(t, c, dir, names, server, hits)
		return
	}
	unauth, err := net.DialTimeout("tcp", c.address, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	fmt.Fprintf(unauth, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", target.Host, target.Host)
	reply := make([]byte, 256)
	unauth.SetReadDeadline(time.Now().Add(time.Second))
	n, _ := unauth.Read(reply)
	unauth.Close()
	if !strings.Contains(string(reply[:n]), "407") {
		t.Fatalf("expected proxy auth challenge: %q", reply[:n])
	}
	result, err := c.measureTarget(context.Background(), names[1], downloadPlan{server.URL, 1, downloadLimit, 3 * time.Second}, roots)
	if err != nil || result.Bytes != 15 || result.BytesPerSecond <= 0 {
		t.Fatalf("sample: %+v %v", result, err)
	}
	four, err := c.measureTarget(context.Background(), names[1], downloadPlan{server.URL, 4, downloadLimit, 3 * time.Second}, roots)
	if err != nil || four.Bytes != 60 || four.Connections != 4 || four.BytesPerSecond <= 0 {
		t.Fatalf("four streams: %+v %v", four, err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, err := c.measureTarget(ctx, names[1], downloadPlan{server.URL + "/slow", 1, downloadLimit, 4 * time.Second}, roots)
		done <- err
	}()
	select {
	case <-started:
		cancel()
	case <-time.After(4 * time.Second):
		t.Fatal("slow response never started")
	}
	if err := <-done; err == nil {
		t.Fatal("cancelled sample accepted")
	}
	if a, b := hits[0].Load(), hits[1].Load(); a != 0 || b != 6 {
		t.Fatalf("relay hits A=%d B=%d", a, b)
	}
	if current(accessGroup) != c.latencyGroup || current(c.group) != "REJECT" {
		t.Fatal("incorrect final selectors")
	}
	// Verify the same API used by the production UI, including a new helper
	// reading the saved pin and invalidating it when the user returns to auto.
	c.network = "dorm"
	h := &helper{root: dir}
	h.downloads.activate(c)
	h.downloads.quality = qualityStore{}
	put := func(mode, node string) {
		t.Helper()
		data, _ := json.Marshal(map[string]string{"session": c.session, "profile": c.network, "group": accessGroup, "mode": mode, "node": node})
		w := httptest.NewRecorder()
		h.nodeQuality(w, httptest.NewRequest("PUT", "/", strings.NewReader(string(data))))
		if w.Code != 200 {
			t.Fatalf("policy %s: %s", mode, w.Body)
		}
	}
	put("fixed", names[1])
	if current(accessGroup) != names[1] {
		t.Fatal("manual pin did not reach core")
	}
	h = &helper{root: dir}
	h.downloads.activate(c)
	h.downloads.quality, err = h.loadQuality()
	if err != nil {
		t.Fatal(err)
	}
	g := h.downloads.qualityGroup(c, accessGroup)
	if g.Pinned != names[1] {
		t.Fatal("manual pin not persisted")
	}
	if err := c.selectGroup(context.Background(), accessGroup, c.latencyGroup); err != nil {
		t.Fatal(err)
	}
	h.restoreQualityLocked(context.Background(), c)
	if current(accessGroup) != names[1] {
		t.Fatal("restart lost pin")
	}
	put("auto", "")
	if g.Pinned != "" || current(accessGroup) != current(c.latencyGroup) {
		t.Fatal("auto did not adopt cold-start exit")
	}
	base := current(c.latencyGroup)
	faster := names[0]
	if base == faster {
		faster = names[1]
	}
	h.downloads.rounds = map[string]*probeRound{}
	probe := func(_ context.Context, node string, _ downloadPlan) (downloadResult, error) {
		rate := 2e6
		if node == faster {
			rate = 5e6
		}
		return downloadResult{BytesPerSecond: rate, DurationMS: 1200, SteadyRate: rate, Connections: 1}, nil
	}
	verify := func(context.Context, string) (bool, error) { t.Fatal("unexpected failure check"); return false, nil }
	h.probePair(context.Background(), c, accessGroup, "dorm", probe, verify)
	if current(accessGroup) != base {
		t.Fatal("one lucky sample changed the route")
	}
	h.probePair(context.Background(), c, accessGroup, "dorm", probe, verify)
	if current(accessGroup) != faster || g.Preferred != faster {
		t.Fatal("two better samples did not change route")
	}
	if last := g.Switches[len(g.Switches)-1]; last.From != base || last.To != faster || !strings.Contains(last.Reason, "MB/s") {
		t.Fatal(g.Switches)
	}
	down := func(ctx context.Context, node string, p downloadPlan) (downloadResult, error) {
		if node == faster {
			return downloadResult{}, fmt.Errorf("unreachable")
		}
		return probe(ctx, node, p)
	}
	h.probePair(context.Background(), c, accessGroup, "dorm", down, func(context.Context, string) (bool, error) { return true, nil })
	if current(accessGroup) != faster {
		t.Fatal("speed service failure stole the route")
	}
	h.probePair(context.Background(), c, accessGroup, "dorm", down, func(_ context.Context, n string) (bool, error) { return n == base, nil })
	if current(accessGroup) != base || !strings.Contains(g.Switches[len(g.Switches)-1].Reason, "复核") {
		t.Fatal("confirmed outage did not override cooldown")
	}
	stored, err := h.loadQuality()
	if err != nil || len(stored[c.qualityKey(accessGroup)].Switches) != len(g.Switches) {
		t.Fatal("lost switch history", err)
	}
	put("fixed", base)
	h.probePair(context.Background(), c, accessGroup, "dorm", probe, verify)
	if current(accessGroup) != base {
		t.Fatal("background challenger overrode manual pin")
	}
}
