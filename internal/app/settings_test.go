package app

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestLegacyPUTFieldOwnership(t *testing.T) {
	stored := DefaultSettings()
	stored.AutoStart, stored.SilentStart, stored.DevMode = true, true, true
	stored.AutoRunProxy, stored.HotkeyEnabled, stored.HotspotShare = true, true, true
	stored.ChainEnabled, stored.CloudEnabled = true, true
	stored.ChainSourceType, stored.ChainSourceURL = "url", "https://example.com/chain"
	stored.CloudSourceURL, stored.CloudUpdatedAt, stored.PortalHost = "https://example.com/cloud", "date", "portal.example.com"
	stored.Blacklist = []string{"ADS.EXAMPLE.COM"}
	got, err := DecodeLegacySettingsPUT([]byte(`{"mode":"direct","campusCidrs":[],"blacklist":null}`), stored)
	if err != nil {
		t.Fatal(err)
	}
	want := stored
	want.Mode, want.CampusCIDRs, want.Blacklist = "direct", []string{}, []string{"ads.example.com"}
	want.AutoStart, want.SilentStart, want.DevMode = false, false, false
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("legacy replacement/preservation contract changed: %+v", got)
	}
	got, err = DecodeLegacySettingsPUT([]byte(`{"autoRunProxy":false,"chainEnabled":false,"blacklist":[]}`), stored)
	if err != nil || got.AutoRunProxy || got.ChainEnabled || len(got.Blacklist) != 0 {
		t.Fatalf("explicit clears: %+v %v", got, err)
	}
}

func TestNativePatchUsesSharedValidation(t *testing.T) {
	got, err := PatchProxyPreferences(DefaultProxyPreferences(), json.RawMessage(`{"campusCidrs":[" EDU.CN "],"devMode":true}`))
	if err != nil || got.Mode != "rule" || got.CampusCIDRs[0] != "edu.cn" || !got.DevMode {
		t.Fatalf("patch: %+v %v", got, err)
	}
	for _, body := range []string{`null`, `[]`, `{"hotspotShare":true}`, `{"mode":"invalid"}`, `{"mode":null}`, `{"blacklist":["https://bad.example"]}`, `{"campusCidrs":null}`, `{"devMode":"true"}`} {
		if _, err := PatchProxyPreferences(got, json.RawMessage(body)); err == nil {
			t.Errorf("accepted %s", body)
		}
	}
}
