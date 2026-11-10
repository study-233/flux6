package mihomo

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"github.com/yourname/freev6/internal/warp"
	"gopkg.in/yaml.v3"
)

func TestDarwinConfigUsesDynamicTUNAndLoopbackDNS(t *testing.T) {
	device := warp.Device{PrivateKey: "private", PeerPublicKey: "peer", IPv4: "172.16.0.2", IPv6: "2606:4700::2"}
	data, err := RenderJSONWithOptions(device, RenderOptions{Platform: PlatformDarwin, Mode: ModeGlobal})
	if err != nil {
		t.Fatal(err)
	}
	var config map[string]any
	if err := json.Unmarshal(data, &config); err != nil {
		t.Fatal(err)
	}
	tun := config["tun"].(map[string]any)
	if _, ok := tun["device"]; ok {
		t.Fatal("Darwin must allocate its own utun")
	}
	if _, ok := tun["strict-route"]; ok {
		t.Fatal("Windows strict-route must not imply Darwin DNS protection")
	}
	if config["dns"].(map[string]any)["listen"] != "127.0.0.1:1053" {
		t.Fatal("DNS must bind loopback")
	}
	if config["mode"] != ModeGlobal || len(config["proxies"].([]any)) != 28 {
		t.Fatal("business configuration changed")
	}
	if config["geo-auto-update"] != false {
		t.Fatal("core must not update the pinned data set")
	}
	catalog, err := PinnedGeodata()
	if err != nil {
		t.Fatal(err)
	}
	for _, value := range config["geox-url"].(map[string]any) {
		if !strings.Contains(value.(string), catalog.Revision) || strings.Contains(value.(string), "latest") {
			t.Fatal("unversioned Darwin geodata", value)
		}
	}
}

func TestJSONOutputPreservesBusinessConfiguration(t *testing.T) {
	device := warp.Device{PrivateKey: "private", PeerPublicKey: "peer", IPv4: "172.16.0.2", IPv6: "2606:4700::2"}
	for _, platform := range []string{PlatformWindows, PlatformDarwin} {
		options := RenderOptions{Platform: platform, CampusCIDRs: []string{"edu.cn", "10.0.0.0/8"}, Blacklist: []string{"example.org"}}
		text, err := RenderWithOptions(device, options)
		if err != nil {
			t.Fatal(err)
		}
		var yamlValue any
		if err := yaml.Unmarshal([]byte(text), &yamlValue); err != nil {
			t.Fatal(err)
		}
		// Normalize numeric representations through JSON before comparing.
		expectedJSON, err := json.Marshal(yamlValue)
		if err != nil {
			t.Fatal(err)
		}
		var expected, actual any
		if err := json.Unmarshal(expectedJSON, &expected); err != nil {
			t.Fatal(err)
		}
		data, err := RenderJSONWithOptions(device, options)
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(data, &actual); err != nil {
			t.Fatal(err)
		}
		if !reflect.DeepEqual(expected, actual) {
			t.Fatalf("JSON changed %s business semantics", platform)
		}
	}
}

func TestConfigurationPlatformIsExplicitAndValidated(t *testing.T) {
	device := warp.Device{PrivateKey: "private", PeerPublicKey: "peer", IPv4: "172.16.0.2", IPv6: "2606:4700::2"}
	legacy, err := RenderWithOptions(device, RenderOptions{})
	if err != nil {
		t.Fatal(err)
	}
	windows, err := RenderWithOptions(device, RenderOptions{Platform: PlatformWindows})
	if err != nil {
		t.Fatal(err)
	}
	if windows != legacy || !strings.Contains(windows, "device: FreeV6TUN") {
		t.Fatal("Windows output changed")
	}
	if _, err := RenderWithOptions(device, RenderOptions{Platform: "unknown"}); err == nil {
		t.Fatal("unsupported platform accepted")
	}
}
