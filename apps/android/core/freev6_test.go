package core

import (
	"encoding/json"
	"os"
	"testing"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/config"
)

func TestFreeV6ProfileMatchesEmbeddedMasqueCore(t *testing.T) {
	data, err := os.ReadFile("../../../shared/fixtures/warp-credential.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Device json.RawMessage `json:"device"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	profile, err := renderFreeV6Profile(freeV6ProfileParams{
		Credentials: string(fixture.Device), CampusTargets: []string{"campus.example.edu"},
	})
	if err != nil {
		t.Fatal(err)
	}
	raw, err := config.UnmarshalRawConfig([]byte(profile))
	if err != nil {
		t.Fatal(err)
	}
	if !raw.IPv6 || !raw.DNS.IPv6 || len(raw.Proxy) != 28 {
		t.Fatal("FreeV6 must retain IPv6 DNS and all 28 WARP endpoints")
	}
	for _, definition := range raw.Proxy {
		proxy, err := adapter.ParseProxy(definition)
		if err != nil {
			t.Fatalf("embedded core rejected generated MASQUE configuration: %v", err)
		}
		proxy.Close()
	}
}
