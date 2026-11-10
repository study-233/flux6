package mobileapi

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestWarpProfilePreservesCampusRulesAndMasque(t *testing.T) {
	credentials := testCredentials(t)
	profile, err := RenderWarpProfile(string(credentials), []string{"campus.example.edu", "2001:db8::/32"})
	if err != nil {
		t.Fatal(err)
	}
	var parsed map[string]any
	if err := json.Unmarshal([]byte(profile), &parsed); err != nil {
		t.Fatal(err)
	}
	proxies := parsed["proxies"].([]any)
	if len(proxies) != 28 || parsed["ipv6"] != true {
		t.Fatal("expected 28 IPv6 WARP access points")
	}
	for _, proxy := range proxies {
		if proxy.(map[string]any)["type"] != "masque" {
			t.Fatal("WARP must use MASQUE")
		}
	}
	for _, key := range []string{"tun", "external-controller", "token", "deviceId"} {
		if _, present := parsed[key]; present {
			t.Fatalf("profile must not carry %s", key)
		}
	}
	for _, rule := range []string{"DOMAIN-SUFFIX,campus.example.edu,DIRECT", "IP-CIDR6,2001:db8::/32,DIRECT,no-resolve"} {
		if !strings.Contains(profile, rule) {
			t.Fatalf("missing campus rule %s", rule)
		}
	}
}

func TestWarpProfileRejectsInvalidInput(t *testing.T) {
	if _, err := RenderWarpProfile(`{"privateKey":"secret-marker"}`, nil); err == nil || strings.Contains(err.Error(), "secret-marker") {
		t.Fatal("invalid credentials must fail without disclosing secrets")
	}
	credentials := testCredentials(t)
	if _, err := RenderWarpProfile(string(credentials), []string{"example.edu\nMATCH,DIRECT"}); err == nil {
		t.Fatal("must reject rule injection")
	}
}

func testCredentials(t *testing.T) []byte {
	t.Helper()
	data, err := os.ReadFile("../shared/fixtures/warp-credential.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Device json.RawMessage `json:"device"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	return fixture.Device
}
