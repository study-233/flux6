package worker

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/yourname/freev6/internal/mihomo"
	"github.com/yourname/freev6/internal/notice"
)

func TestNoticeCacheAndRevocation(t *testing.T) {
	settings, _ := testStore(t)
	m := NewNoticeManager(settings.root)
	now := time.Now().UTC().Truncate(time.Second)
	m.now = func() time.Time { return now }
	flag := true
	m.fetch = func(context.Context, time.Time) (notice.Payload, error) {
		return notice.Parse([]byte(`{"cloudProfile":true,"items":[{"id":"1","title":"Maintenance","published":"2025-01-01T00:00:00Z"}]}`), now)
	}
	ctx := context.Background()
	if m.cached().CloudAllowed {
		t.Fatal("missing notice unlocked")
	}
	freshly, err := m.refresh(ctx)
	if err != nil || !freshly.CloudAllowed || freshly.Source != "online" || len(freshly.Items) != 1 {
		t.Fatal("online", err)
	}
	m.fetch = func(context.Context, time.Time) (notice.Payload, error) {
		return notice.Payload{}, errors.New("offline")
	}
	now = now.Add(7 * 24 * time.Hour)
	fallback, err := m.refresh(ctx)
	if err != nil || fallback.Source != "cache" || !fallback.CloudAllowed {
		t.Fatal("lost usable cache")
	}
	now = now.Add(time.Second)
	if m.cached().CloudAllowed {
		t.Fatal("expired cache unlocked")
	}
	flag = false
	m.fetch = func(context.Context, time.Time) (notice.Payload, error) {
		return notice.Payload{CloudProfile: &flag, Items: []notice.Item{}}, nil
	}
	if _, err = m.refresh(ctx); err != nil || m.cached().CloudAllowed {
		t.Fatal("revocation failed", err)
	}
	// A future-dated cache cannot keep the gate open across a clock rollback.
	now = now.Add(-time.Hour)
	if m.cached().Source != "unavailable" {
		t.Fatal("future cache accepted")
	}
}

func TestPortalAndCustomRefreshDoNotReplaceValidSnapshotOnFailure(t *testing.T) {
	settings, dir := testStore(t)
	notices := NewNoticeManager(settings.root)
	allowed := true
	notices.fetch = func(context.Context, time.Time) (notice.Payload, error) {
		return notice.Payload{CloudProfile: &allowed, Items: []notice.Item{}}, nil
	}
	manager := cloudManager{store: settings, notice: notices}
	ctx := context.Background()
	sample, err := os.ReadFile("../../shared/fixtures/chain-proxies.yaml")
	if err != nil {
		t.Fatal(err)
	}
	expectedPortal, err := mihomo.CloudProfileURL("campus.example.test")
	if err != nil {
		t.Fatal(err)
	}
	fetched := 0
	manager.fetch = func(_ context.Context, url string) ([]byte, error) {
		fetched++
		if url != expectedPortal {
			t.Fatal("unexpected derived URL")
		}
		return sample, nil
	}
	key := bytes.Repeat([]byte{7}, 32)
	input := func(v any) json.RawMessage {
		b, e := json.Marshal(v)
		if e != nil {
			t.Fatal(e)
		}
		return b
	}
	preview := func(source, value string, rev uint64) (any, error) {
		return manager.preview(ctx, input(cloudInput{&rev, key, source, value}))
	}
	mutate := func(method string, values map[string]any) (any, error) {
		return manager.apply(ctx, method, input(values))
	}
	if _, err := preview("portal", "campus.example.test", 0); err == nil || fetched != 0 {
		t.Fatal("gate must precede downloads")
	}
	if _, err := notices.refresh(ctx); err != nil {
		t.Fatal(err)
	}
	d, err := preview("portal", "https://CAMPUS.example.test/login", 0)
	if err != nil {
		t.Fatal(err)
	}
	allowed = false
	if _, err := notices.refresh(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err = mutate("cloud.commit", map[string]any{"token": d.(chainPreview).Token, "expectedRevision": 0}); err == nil {
		t.Fatal("revoked during import")
	}
	allowed = true
	if _, err := notices.refresh(ctx); err != nil {
		t.Fatal(err)
	}
	d, err = preview("portal", "https://CAMPUS.example.test/login", 0)
	if err != nil {
		t.Fatal(err)
	}
	v, err := mutate("cloud.commit", map[string]any{"token": d.(chainPreview).Token, "expectedRevision": 0})
	if err != nil {
		t.Fatal(err)
	}
	current := v.(SettingsSnapshot)
	if current.PortalHost != "campus.example.test" || current.Cloud.Source != "portal" || !current.Cloud.Enabled || len(current.Cloud.Names) != 6 {
		t.Fatal("incorrect portal profile")
	}
	nodes, err := current.openCloud(key)
	if err != nil || nodes.URL != "" || bytes.Contains(nodes.Proxies[0], []byte("dialer-proxy")) {
		t.Fatal("portal snapshot retained derived URL or dialer")
	}
	if _, err := current.openCloud(bytes.Repeat([]byte{1}, 32)); err == nil {
		t.Fatal("wrong key accepted")
	}
	if _, err = preview("refresh", "", 1); err != nil || fetched != 3 {
		t.Fatal("derived refresh failed", err)
	}
	var fail atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("token") != "sensitive-fixture" {
			http.Error(w, "unexpected", 400)
			return
		}
		if fail.Load() {
			http.Error(w, "denied", 403)
			return
		}
		w.Write(sample)
	}))
	defer server.Close()
	handler := CloudHandler(settings, notices, nil)
	rev := uint64(1)
	d, err = handler(ctx, "cloud.preview", input(cloudInput{&rev, key, "url", server.URL + "/?token=sensitive-fixture"}))
	if err != nil {
		t.Fatal(err)
	}
	v, err = handler(ctx, "cloud.commit", input(map[string]any{"expectedRevision": 1, "token": d.(chainPreview).Token}))
	if err != nil {
		t.Fatal(err)
	}
	original, err := os.ReadFile(filepath.Join(dir, settingsFile))
	if err != nil {
		t.Fatal(err)
	}
	for _, secret := range []string{"sensitive-fixture", "synthetic-only", expectedPortal, "proxy.example.test"} {
		if bytes.Contains(original, []byte(secret)) {
			t.Fatal("plaintext in snapshot")
		}
	}
	rev = 2
	fail.Store(true)
	_, err = handler(ctx, "cloud.preview", input(cloudInput{&rev, key, "refresh", ""}))
	if err == nil || !strings.Contains(err.Error(), "校园网") || strings.Contains(err.Error(), "sensitive-fixture") {
		t.Fatal("campus denial not mapped safely")
	}
	after, err := os.ReadFile(filepath.Join(dir, settingsFile))
	if err != nil || !bytes.Equal(original, after) {
		t.Fatal("failed refresh replaced snapshot")
	}
	if _, err = mutate("cloud.clear", map[string]any{"expectedRevision": 1}); err == nil {
		t.Fatal("stale clear accepted")
	}
	allowed = false
	if _, err := notices.refresh(ctx); err != nil {
		t.Fatal(err)
	}
	v, err = mutate("cloud.enable", map[string]any{"expectedRevision": 2, "enabled": false})
	if err != nil || v.(SettingsSnapshot).Cloud.Enabled {
		t.Fatal("disabled gate prevented disabling", err)
	}
	if _, err = mutate("cloud.enable", map[string]any{"expectedRevision": 3, "enabled": true}); err == nil {
		t.Fatal("revoked profile re-enabled")
	}
	v, err = mutate("cloud.clear", map[string]any{"expectedRevision": 3})
	if err != nil || v.(SettingsSnapshot).Cloud != nil || v.(SettingsSnapshot).PortalHost != "campus.example.test" {
		t.Fatal("clear or portal retention failed", err)
	}
}
