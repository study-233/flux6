package app

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"sync"
	"testing"

	"github.com/yourname/freev6/internal/warp"
)

type testRegistrar func(context.Context, string, func(string)) (warp.Device, error)

func (f testRegistrar) RegisterWithProgress(c context.Context, name string, p func(string)) (warp.Device, error) {
	return f(c, name, p)
}

func TestWarpRegistrationOverHTTPUsesValidatedCredentialContract(t *testing.T) {
	fixture := fixtureCredential(t)
	var methods []string
	var methodsMu sync.Mutex
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		methodsMu.Lock()
		methods = append(methods, r.Method)
		methodsMu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		if r.Method == "POST" && r.URL.Path == "/reg" {
			json.NewEncoder(w).Encode(map[string]string{"id": fixture.Device.DeviceID, "token": fixture.Device.Token})
			return
		}
		if r.Method != "PATCH" || r.URL.Path != "/reg/"+fixture.Device.DeviceID || r.Header.Get("Authorization") != "Bearer "+fixture.Device.Token {
			t.Error("unexpected enrollment request")
			http.Error(w, "invalid", 400)
			return
		}
		var body map[string]string
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body["name"] != "Mac" || body["key_type"] != "secp256r1" {
			t.Error("invalid enrollment payload")
		}
		json.NewEncoder(w).Encode(map[string]any{"config": map[string]any{
			"interface": map[string]any{"addresses": map[string]string{"v4": fixture.Device.IPv4, "v6": fixture.Device.IPv6}},
			"peers":     []map[string]string{{"public_key": fixture.Device.PeerPublicKey}},
		}})
	}))
	defer server.Close()
	client := warp.NewClient(server.Client())
	client.BaseURL = server.URL
	var phases []string
	result, err := RegisterWarp(context.Background(), client, " Mac ", func(phase string) { phases = append(phases, phase) })
	if err != nil {
		t.Fatal(err)
	}
	if err := warp.ValidateDevice(result.Device); err != nil {
		t.Fatal(err)
	}
	methodsMu.Lock()
	defer methodsMu.Unlock()
	if result.SchemaVersion != 1 || !reflect.DeepEqual(phases, []string{"registering", "enrolling"}) || !reflect.DeepEqual(methods, []string{"POST", "PATCH"}) {
		t.Fatal("registration contract or phase order changed")
	}
}

func fixtureCredential(t *testing.T) WarpCredential {
	t.Helper()
	data, err := os.ReadFile("../../shared/fixtures/warp-credential.json")
	if err != nil {
		t.Fatal(err)
	}
	var result WarpCredential
	if err := json.Unmarshal(data, &result); err != nil {
		t.Fatal(err)
	}
	return result
}

func TestWarpRegistrationValidatesBeforeAndAfterNetwork(t *testing.T) {
	fixture := fixtureCredential(t)
	calls := 0
	registrar := testRegistrar(func(ctx context.Context, name string, p func(string)) (warp.Device, error) {
		calls++
		if name != "freev6-macos" {
			t.Fatalf("unexpected normalized name")
		}
		return fixture.Device, nil
	})
	for _, name := range []string{"bad\nname", strings.Repeat("名", 50)} {
		if _, err := RegisterWarp(context.Background(), registrar, name, nil); err == nil {
			t.Fatal("invalid name accepted")
		}
	}
	if calls != 0 {
		t.Fatal("invalid name reached registrar")
	}
	result, err := RegisterWarp(context.Background(), registrar, "  ", nil)
	if err != nil || result.SchemaVersion != 1 || result.Device.DeviceID != fixture.Device.DeviceID {
		t.Fatalf("registration failed: %v", err)
	}
	bad := fixture.Device
	bad.PrivateKey = "credential-must-not-appear-in-errors"
	_, err = RegisterWarp(context.Background(), testRegistrar(func(context.Context, string, func(string)) (warp.Device, error) { return bad, nil }), "test", nil)
	if err == nil || strings.Contains(err.Error(), bad.PrivateKey) {
		t.Fatal("invalid secret was accepted or exposed")
	}
	_, err = RegisterWarp(context.Background(), testRegistrar(func(context.Context, string, func(string)) (warp.Device, error) {
		return warp.Device{}, context.Canceled
	}), "test", nil)
	if !errors.Is(err, context.Canceled) {
		t.Fatal("cancellation lost")
	}
}
