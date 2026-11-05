package worker

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"

	"github.com/yourname/freev6/internal/app"
)

func TestChainSubscriptionSnapshotAndRefresh(t *testing.T) {
	settings, dir := testStore(t)
	handler := ChainHandler(settings, nil)
	ctx := context.Background()
	call := func(method string, params map[string]any) (any, error) {
		t.Helper()
		data, err := json.Marshal(params)
		if err != nil {
			t.Fatal(err)
		}
		return handler(ctx, method, data)
	}
	key := bytes.Repeat([]byte{7}, 32)
	sample, err := os.ReadFile("../../shared/fixtures/chain-proxies.yaml")
	if err != nil {
		t.Fatal(err)
	}
	var fail atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("token") != "test-private-token" || r.UserAgent() != "FreeV6" {
			http.Error(w, "bad request", 400)
			return
		}
		if fail.Load() {
			http.Error(w, "unavailable", 503)
			return
		}
		w.Write(sample)
	}))
	defer server.Close()
	proposal, err := call("chain.preview", map[string]any{"url": server.URL + "/?token=test-private-token", "expectedRevision": 0, "key": key})
	if err != nil {
		t.Fatal(err)
	}
	preview := proposal.(chainPreview)
	if len(preview.Nodes) != 6 {
		t.Fatal("missing imported nodes")
	}
	if _, err = call("chain.commit", map[string]any{"token": "wrong", "expectedRevision": 0}); err == nil {
		t.Fatal("wrong candidate accepted")
	}
	saved, err := call("chain.commit", map[string]any{"token": preview.Token, "expectedRevision": 0})
	if err != nil {
		t.Fatal(err)
	}
	snapshot := saved.(SettingsSnapshot)
	if snapshot.Revision != 1 || !snapshot.Chain.Enabled || snapshot.Chain.Source != "url" {
		t.Fatal("incorrect settings")
	}
	original, err := os.ReadFile(filepath.Join(dir, settingsFile))
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{"synthetic-only", "test-private-token", "proxy.example.test", server.URL} {
		if bytes.Contains(original, []byte(secret)) {
			t.Fatal("plaintext retained")
		}
	}
	if _, err := snapshot.openChain(bytes.Repeat([]byte{8}, 32)); err == nil {
		t.Fatal("wrong key opened profile")
	}
	if _, err = call("chain.commit", map[string]any{"token": preview.Token, "expectedRevision": 0}); err == nil {
		t.Fatal("stale commit accepted")
	}
	handler = ChainHandler(settings, nil)
	fail.Store(true)
	if _, err = call("chain.preview", map[string]any{"refresh": true, "expectedRevision": 1, "key": key}); err == nil {
		t.Fatal("bad refresh accepted")
	}
	current, _ := os.ReadFile(filepath.Join(dir, settingsFile))
	if !bytes.Equal(original, current) {
		t.Fatal("failed refresh modified snapshot")
	}
	fail.Store(false)
	proposal, err = call("chain.preview", map[string]any{"refresh": true, "expectedRevision": 1, "key": key})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = settings.Patch(ctx, 1, json.RawMessage(`{"mode":"global"}`)); err != nil {
		t.Fatal(err)
	}
	if _, err = call("chain.commit", map[string]any{"token": proposal.(chainPreview).Token, "expectedRevision": 1}); err == nil {
		t.Fatal("staged import replaced newer settings")
	}
	off, err := call("chain.enable", map[string]any{"expectedRevision": 2, "enabled": false})
	if err != nil || off.(SettingsSnapshot).Chain.Enabled {
		t.Fatal("disable failed", err)
	}
	cleared, err := call("chain.clear", map[string]any{"expectedRevision": 3})
	if err != nil || cleared.(SettingsSnapshot).Chain != nil {
		t.Fatal("clear failed", err)
	}
}

func TestChainSelectedFileBound(t *testing.T) {
	s, dir := testStore(t)
	path := filepath.Join(dir, "large.yaml")
	for _, size := range []int{app.MaxSubscriptionBytes, app.MaxSubscriptionBytes + 1} {
		if err := os.WriteFile(path, bytes.Repeat([]byte{' '}, size), 0600); err != nil {
			t.Fatal(err)
		}
		data, err := readChainFile(path)
		if size == app.MaxSubscriptionBytes && (err != nil || len(data) != size) {
			t.Fatal("2 MiB file rejected")
		}
		if size > app.MaxSubscriptionBytes && err == nil {
			t.Fatal("oversized file accepted")
		}
	}
	linked := filepath.Join(dir, "linked.yaml")
	if err := os.Symlink(path, linked); err != nil {
		t.Fatal(err)
	}
	if _, err := readChainFile(linked); err == nil {
		t.Fatal("symlink accepted")
	}
	snap, err := s.Get()
	if err != nil || snap.Revision != 0 {
		t.Fatal("file reads changed settings")
	}
}

func TestNormalizedChainKeepsCanonicalNamesAndTypes(t *testing.T) {
	content := []byte("proxies: [{name: '  padded  ', type: SOCKS5, server: localhost, port: 1080}]")
	profile, names, err := normalizedChain(content)
	if err != nil {
		t.Fatal(err)
	}
	var node struct{ Name, Type string }
	if len(profile.Proxies) != 1 || json.Unmarshal(profile.Proxies[0], &node) != nil ||
		len(names) != 1 || names[0] != "padded" || node.Name != names[0] || node.Type != "socks5" {
		t.Fatal("preview, saved metadata and rendered node must use the same canonical spelling")
	}
}
