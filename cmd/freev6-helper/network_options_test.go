package main

import (
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestNetworkOptionsSaveRejectsInvalidWithoutChangingPrevious(t *testing.T) {
	h := &helper{root: t.TempDir()}
	put := func(body string) int {
		response := httptest.NewRecorder()
		h.networkOptions(response, httptest.NewRequest("PUT", "/", strings.NewReader(body)))
		return response.Code
	}
	if code := put(`{"dnsMode":"redir-host","tunStack":"system","tunMtu":1400,"nameservers":["https://dns.example/dns-query"],"logLevel":"warning"}`); code != 200 {
		t.Fatal(code)
	}
	before, err := os.ReadFile(h.networkOptionsPath())
	if err != nil {
		t.Fatal(err)
	}
	for _, body := range []string{`{"tunMtu":1279}`, `{"nameservers":["file:///private"]}`, `{"tunStack":"invalid"}`, `{"controllerSecret":"x"}`, `{} {}`, `{"mixedPort":0}`, `{"httpPort":7890}`, `{"dnsPort":9090}`, `{"socksPort":65536}`} {
		if code := put(body); code != 400 {
			t.Fatalf("%s: %d", body, code)
		}
		after, _ := os.ReadFile(h.networkOptionsPath())
		if string(after) != string(before) {
			t.Fatal("invalid update replaced valid settings")
		}
	}
	options, err := h.loadNetworkOptions()
	if err != nil || options.TUNMTU != 1400 {
		t.Fatalf("%+v %v", options, err)
	}
}

func TestNetworkOptionsPreservesGeneratedRoutingAndTunnel(t *testing.T) {
	const original = "dns:\n  enable: true\n  ipv6: true\n  enhanced-mode: fake-ip\n  nameserver: [system]\ntun:\n  enable: true\n  auto-route: true\n  device: flux6\n  mtu: 9000\n  stack: mixed\nproxies: [{name: WARP, type: wireguard}]\nrules: [MATCH,WARP]\nsecret: fixture\n"
	options := defaultNetworkOptions()
	options.DNSMode, options.TUNStack, options.TUNMTU = "redir-host", "system", 1400
	options.MixedPort, options.HTTPPort, options.SOCKSPort, options.DNSPort = 17890, 17891, 17892, 11053
	result, err := applyNetworkOptions(original, options)
	if err != nil {
		t.Fatal(err)
	}
	var before, after map[string]any
	yaml.Unmarshal([]byte(original), &before)
	yaml.Unmarshal([]byte(result), &after)
	before["dns"].(map[string]any)["enhanced-mode"] = "redir-host"
	before["tun"].(map[string]any)["stack"] = "system"
	before["tun"].(map[string]any)["mtu"] = 1400
	before["log-level"] = "info"
	before["mixed-port"], before["port"], before["socks-port"] = 17890, 17891, 17892
	before["dns"].(map[string]any)["listen"] = "0.0.0.0:11053"
	if !reflect.DeepEqual(before, after) {
		t.Fatalf("unrelated configuration changed: %s", result)
	}
}
