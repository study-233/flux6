package worker

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"

	"github.com/yourname/freev6/internal/mihomo"
)

func configurationParams(t *testing.T) map[string]any {
	t.Helper()
	data, err := os.ReadFile("../../shared/fixtures/warp-credential.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture map[string]any
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	d := fixture["device"].(map[string]any)
	tunnel := map[string]any{}
	for _, key := range []string{"privateKey", "peerPublicKey", "ipv4", "ipv6"} {
		tunnel[key] = d[key]
	}
	return map[string]any{"source": "warp", "settingsRevision": 0, "credentialRevision": "11111111-2222-4333-8444-555555555555", "tunnel": tunnel}
}

func testConfigurationManager(t *testing.T) (*ConfigurationManager, string) {
	s, directory := testStore(t)
	m := NewConfigurationManager(s, t.TempDir(), NewNoticeManager(s.root))
	m.inspectRuntime = func(context.Context) (mihomo.RuntimePackage, error) {
		return mihomo.RuntimePackage{Available: true, ResourceID: "approved-runtime"}, nil
	}
	m.inspectGeodata = func(context.Context) (mihomo.GeodataPackage, error) {
		return mihomo.GeodataPackage{Available: true, ResourceID: "approved-geodata"}, nil
	}
	return m, directory
}

func TestConfigurationHandlerNoSideEffectsAndInputRestrictions(t *testing.T) {
	m, directory := testConfigurationManager(t)
	handler := ConfigurationHandler(m, nil)
	call := func(params map[string]any) (any, error) {
		data, _ := json.Marshal(params)
		return handler(context.Background(), "configuration.prepare", data)
	}
	result, err := call(configurationParams(t))
	if err != nil {
		t.Fatal(err)
	}
	prepared := result.(PreparedConfiguration)
	if prepared.SchemaVersion != 1 || prepared.SettingsRevision != 0 || prepared.RuntimeID != "approved-runtime" {
		t.Fatal("incorrect metadata")
	}
	files, err := os.ReadDir(directory)
	if err != nil || len(files) != 0 {
		t.Fatal("configuration generation persisted data", files, err)
	}
	for _, mutate := range []func(map[string]any){
		func(p map[string]any) { p["source"] = "cloud" },
		func(p map[string]any) { delete(p, "settingsRevision") },
		func(p map[string]any) { p["credentialRevision"] = "not-uuid" },
		func(p map[string]any) { p["path"] = "/tmp/config" },
		func(p map[string]any) { p["tunnel"].(map[string]any)["token"] = "secret-account-token" },
		func(p map[string]any) { p["tunnel"].(map[string]any)["privateKey"] = "secret-invalid-key" },
	} {
		params := configurationParams(t)
		mutate(params)
		_, err := call(params)
		var rpc *RPCError
		if !errors.As(err, &rpc) || rpc.Code != InvalidParams || strings.Contains(err.Error(), "secret-") {
			t.Fatal("input accepted or leaked", err)
		}
	}
}

func TestConfigurationHandlerRejectsStaleAndMissingResources(t *testing.T) {
	m, _ := testConfigurationManager(t)
	handler := ConfigurationHandler(m, nil)
	data, _ := json.Marshal(configurationParams(t))
	checkCode := func(want int) {
		t.Helper()
		_, err := handler(context.Background(), "configuration.prepare", data)
		var rpc *RPCError
		if !errors.As(err, &rpc) || rpc.Code != want {
			t.Fatal(want, err)
		}
	}
	m.mu.Lock()
	checkCode(Busy)
	m.mu.Unlock()
	runtimeInspect := m.inspectRuntime
	m.inspectRuntime = func(context.Context) (mihomo.RuntimePackage, error) {
		return mihomo.RuntimePackage{}, errors.New("private/cache/path")
	}
	checkCode(ResourceError)
	m.inspectRuntime = runtimeInspect
	m.inspectGeodata = func(ctx context.Context) (mihomo.GeodataPackage, error) {
		_, err := m.settings.Patch(ctx, 0, json.RawMessage(`{"mode":"global"}`))
		if err != nil {
			t.Fatal(err)
		}
		return mihomo.GeodataPackage{Available: true}, nil
	}
	checkCode(Conflict) // changed during resource inspection
	checkCode(Conflict) // stale at entry, before inspecting again
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := handler(ctx, "configuration.prepare", data)
	if !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
}
