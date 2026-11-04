package app

import (
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/yourname/freev6/internal/mihomo"
	"github.com/yourname/freev6/internal/warp"
)

func configurationTunnel(t *testing.T) warp.TunnelCredentials {
	t.Helper()
	data, err := os.ReadFile("../../shared/fixtures/warp-credential.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Device warp.Device `json:"device"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	d := fixture.Device
	return warp.TunnelCredentials{PrivateKey: d.PrivateKey, PeerPublicKey: d.PeerPublicKey, IPv4: d.IPv4, IPv6: d.IPv6}
}

func TestPrepareWarpConfigurationContractAndNoSystemFields(t *testing.T) {
	data, err := os.ReadFile("../../shared/fixtures/worker-settings.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Settings ProxyPreferences `json:"settings"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	prepared, err := PrepareWarpConfiguration(fixture.Settings, configurationTunnel(t))
	if err != nil {
		t.Fatal(err)
	}
	got, err := json.Marshal(prepared)
	if err != nil {
		t.Fatal(err)
	}
	want, err := os.ReadFile("../../shared/fixtures/warp-business-configuration.json")
	if err != nil {
		t.Fatal(err)
	}
	var a, b map[string]any
	json.Unmarshal(got, &a)
	json.Unmarshal(want, &b)
	if !reflect.DeepEqual(a, b) {
		t.Fatal("shared Go/Swift fixture drifted")
	}
	if len(a) != 5 || len(prepared.Proxies) != 28 || len(prepared.RuleProviders) != 10 {
		t.Fatal("unexpected business shape")
	}
	for _, key := range []string{"tun", "dns", "secret", "external-controller", "mixed-port", "geox-url", "external-ui", "profile"} {
		if _, exists := a[key]; exists {
			t.Fatal("system field crossed boundary", key)
		}
	}
	if strings.Contains(string(got), "synthetic-token") || strings.Contains(string(got), "synthetic-device") {
		t.Fatal("unneeded account identity crossed boundary")
	}
	if fmt.Sprintf("%+v %#v", prepared, configurationTunnel(t)) != "BusinessConfiguration(redacted) TunnelCredentials(redacted)" {
		t.Fatal("secret-bearing debug output")
	}
}

func TestPrepareWarpConfigurationBusinessPolicies(t *testing.T) {
	tunnel := configurationTunnel(t)
	defaults := DefaultProxyPreferences()
	base, err := PrepareWarpConfiguration(defaults, tunnel)
	if err != nil {
		t.Fatal(err)
	}
	builtin, err := mihomo.DefaultBlacklist()
	if err != nil {
		t.Fatal(err)
	}
	for _, domain := range builtin {
		if !strings.Contains(strings.Join(base.Rules, "\n"), "DOMAIN-SUFFIX,"+domain+",REJECT") {
			t.Fatal("lost default blacklist")
		}
	}
	for _, mode := range []string{"rule", "global", "direct"} {
		defaults.Mode = mode
		defaults.Blacklist = []string{" ads.example.com "}
		defaults.CampusCIDRs = []string{" EDU.CN ", "2001:db8::/32"}
		result, err := PrepareWarpConfiguration(defaults, tunnel)
		if err != nil || result.Mode != mode || result.Rules[0] != "DOMAIN-SUFFIX,ads.example.com,REJECT" {
			t.Fatal(mode, err)
		}
		defaults.DevMode = true
		result, err = PrepareWarpConfiguration(defaults, tunnel)
		if err != nil || strings.Contains(strings.Join(result.Rules, "\n"), "ads.example.com") {
			t.Fatal("developer policy", err)
		}
		defaults.DevMode = false
	}
	defaults.Mode = "bad-sensitive-value"
	_, err = PrepareWarpConfiguration(defaults, tunnel)
	if err == nil || strings.Contains(err.Error(), defaults.Mode) {
		t.Fatal("invalid settings not sanitized")
	}
	defaults = DefaultProxyPreferences()
	tunnel.PrivateKey = "sensitive-invalid-key"
	_, err = PrepareWarpConfiguration(defaults, tunnel)
	if err == nil || strings.Contains(err.Error(), tunnel.PrivateKey) {
		t.Fatal("invalid credential not sanitized")
	}
}
