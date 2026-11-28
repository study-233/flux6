package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"gopkg.in/yaml.v3"
)

// Windows-only overrides leave the shared WARP renderer and other clients intact.
type networkOptions struct {
	MixedPort   int      `json:"mixedPort"`
	HTTPPort    int      `json:"httpPort"`
	SOCKSPort   int      `json:"socksPort"`
	DNSPort     int      `json:"dnsPort"`
	Nameservers []string `json:"nameservers"`
	DNSMode     string   `json:"dnsMode"`
	TUNStack    string   `json:"tunStack"`
	TUNMTU      int      `json:"tunMtu"`
	LogLevel    string   `json:"logLevel"`
}

func defaultNetworkOptions() networkOptions {
	return networkOptions{MixedPort: 7890, DNSPort: 1053, Nameservers: []string{}, DNSMode: "fake-ip", TUNStack: "mixed", LogLevel: "info"}
}

func (o networkOptions) validate() error {
	seen := map[int]bool{}
	for _, port := range []struct {
		name     string
		value    int
		optional bool
	}{
		{"Mixed", o.MixedPort, false}, {"HTTP", o.HTTPPort, true},
		{"SOCKS", o.SOCKSPort, true}, {"DNS", o.DNSPort, false},
	} {
		if port.optional && port.value == 0 {
			continue
		}
		if port.value < 1 || port.value > 65535 {
			return fmt.Errorf("%s 端口应为 1–65535", port.name)
		}
		if port.value == 9090 || seen[port.value] {
			return errors.New("端口不能重复或占用控制端口 9090")
		}
		seen[port.value] = true
	}
	if o.DNSMode != "fake-ip" && o.DNSMode != "redir-host" {
		return errors.New("DNS 模式无效")
	}
	if o.TUNStack != "mixed" && o.TUNStack != "system" && o.TUNStack != "gvisor" {
		return errors.New("TUN 协议栈无效")
	}
	if o.TUNMTU != 0 && (o.TUNMTU < 1280 || o.TUNMTU > 9000) {
		return errors.New("TUN MTU 应为 1280–9000，或 0 使用默认值")
	}
	switch o.LogLevel {
	case "debug", "info", "warning", "error", "silent":
	default:
		return errors.New("日志级别无效")
	}
	if len(o.Nameservers) > 16 {
		return errors.New("DNS 服务器不能超过 16 项")
	}
	for _, address := range o.Nameservers {
		if len(address) > 1024 || strings.TrimSpace(address) != address {
			return errors.New("DNS 地址无效")
		}
		if net.ParseIP(address) != nil {
			continue
		}
		u, err := url.Parse(address)
		if err != nil || u.Hostname() == "" || u.User != nil || u.Fragment != "" {
			return errors.New("DNS 地址应为 IP 或 DNS 服务 URL")
		}
		switch u.Scheme {
		case "https", "tls", "udp", "tcp":
		default:
			return errors.New("不支持的 DNS 协议")
		}
	}
	return nil
}

func (h *helper) networkOptionsPath() string {
	return filepath.Join(h.root, "config", "network-options.json")
}

func (h *helper) loadNetworkOptions() (networkOptions, error) {
	options := defaultNetworkOptions()
	file, err := os.Open(h.networkOptionsPath())
	if errors.Is(err, os.ErrNotExist) {
		return options, nil
	}
	if err != nil {
		return options, err
	}
	defer file.Close()
	if err = json.NewDecoder(io.LimitReader(file, 64<<10)).Decode(&options); err != nil {
		return options, err
	}
	return options, options.validate()
}

func (h *helper) networkOptions(w http.ResponseWriter, r *http.Request) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if r.Method == http.MethodGet {
		options, err := h.loadNetworkOptions()
		if err != nil {
			writeJSON(w, 500, map[string]string{"error": "网络设置读取失败"})
			return
		}
		writeJSON(w, 200, options)
		return
	}
	if r.Method != http.MethodPut {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	options := defaultNetworkOptions()
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&options); err != nil {
		writeJSON(w, 400, map[string]string{"error": "网络设置格式无效"})
		return
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		writeJSON(w, 400, map[string]string{"error": "网络设置格式无效"})
		return
	}
	if err := options.validate(); err != nil {
		writeJSON(w, 400, map[string]string{"error": err.Error()})
		return
	}
	data, _ := json.MarshalIndent(options, "", "  ")
	path := h.networkOptionsPath()
	err := os.MkdirAll(filepath.Dir(path), 0700)
	if err == nil {
		err = os.WriteFile(path+".tmp", data, 0600)
	}
	if err == nil {
		err = os.Rename(path+".tmp", path)
	}
	if err != nil {
		writeJSON(w, 500, map[string]string{"error": "网络设置保存失败，原配置保留"})
		return
	}
	writeJSON(w, 200, options)
}

func applyNetworkOptions(config string, options networkOptions) (string, error) {
	if err := options.validate(); err != nil {
		return "", err
	}
	var document map[string]any
	if err := yaml.Unmarshal([]byte(config), &document); err != nil {
		return "", err
	}
	dns, ok := document["dns"].(map[string]any)
	if !ok {
		return "", errors.New("missing DNS configuration")
	}
	tun, ok := document["tun"].(map[string]any)
	if !ok {
		return "", errors.New("missing TUN configuration")
	}
	dns["enhanced-mode"] = options.DNSMode
	dns["listen"] = net.JoinHostPort("0.0.0.0", strconv.Itoa(options.DNSPort))
	document["mixed-port"] = options.MixedPort
	document["port"] = options.HTTPPort
	document["socks-port"] = options.SOCKSPort
	if len(options.Nameservers) > 0 {
		dns["nameserver"] = options.Nameservers
	}
	tun["stack"] = options.TUNStack
	if options.TUNMTU != 0 {
		tun["mtu"] = options.TUNMTU
	}
	document["log-level"] = options.LogLevel
	data, err := yaml.Marshal(document)
	return string(data), err
}

// Validate the saved listeners before touching routes, DNS or the core process.
func (o networkOptions) checkListenPorts() error {
	for _, p := range []struct {
		port int
		udp  bool
	}{
		{o.MixedPort, true}, {o.HTTPPort, false}, {o.SOCKSPort, true}, {o.DNSPort, true},
	} {
		if p.port == 0 {
			continue
		}
		for _, host := range []string{"127.0.0.1", "0.0.0.0"} {
			address := net.JoinHostPort(host, strconv.Itoa(p.port))
			listener, err := net.Listen("tcp4", address)
			if err != nil {
				return fmt.Errorf("端口 %d 已被占用: %w", p.port, err)
			}
			listener.Close()
			if p.udp {
				packet, err := net.ListenPacket("udp4", address)
				if err != nil {
					return fmt.Errorf("UDP 端口 %d 已被占用: %w", p.port, err)
				}
				packet.Close()
			}
		}
	}
	return nil
}
