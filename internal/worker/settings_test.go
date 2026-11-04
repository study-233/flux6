package worker

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"testing"
)

func testStore(t *testing.T) (*SettingsStore, string) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("Mac worker store requires POSIX directory fsync; Windows uses its existing settings adapter")
	}
	dir := t.TempDir()
	root, err := os.OpenRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { root.Close() })
	return NewSettingsStore(root), dir
}

func TestSettingsAtomicRevisionAndRetainedCorruption(t *testing.T) {
	store, dir := testStore(t)
	initial, err := store.Get()
	if err != nil || initial.Revision != 0 || initial.Settings.Mode != "rule" {
		t.Fatalf("initial: %+v %v", initial, err)
	}
	var wg sync.WaitGroup
	results := make(chan error, 2)
	for range 2 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := store.Patch(context.Background(), 0, json.RawMessage(`{"mode":"global"}`))
			results <- err
		}()
	}
	wg.Wait()
	close(results)
	success, conflicts := 0, 0
	for err := range results {
		var rpc *RPCError
		if err == nil {
			success++
		} else if errors.As(err, &rpc) && rpc.Code == Conflict {
			conflicts++
		} else {
			t.Fatal(err)
		}
	}
	if success != 1 || conflicts != 1 {
		t.Fatalf("success=%d conflict=%d", success, conflicts)
	}
	if current, err := store.Get(); err != nil || current.Revision != 1 || current.Settings.Mode != "global" {
		t.Fatalf("saved: %+v %v", current, err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := store.Patch(ctx, 1, json.RawMessage(`{"mode":"direct"}`)); err == nil {
		t.Fatal("canceled save succeeded")
	}
	if current, _ := store.Get(); current.Revision != 1 {
		t.Fatal("canceled save changed disk")
	}
	file := filepath.Join(dir, settingsFile)
	if err := os.WriteFile(file, []byte("damaged"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Patch(context.Background(), 1, json.RawMessage(`{}`)); err == nil {
		t.Fatal("overwrote damaged settings")
	}
	if data, _ := os.ReadFile(file); string(data) != "damaged" {
		t.Fatal("damaged file was replaced")
	}
}

func TestSharedSettingsFixture(t *testing.T) {
	store, dir := testStore(t)
	data, err := os.ReadFile("../../shared/fixtures/worker-settings.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, settingsFile), data, 0o600); err != nil {
		t.Fatal(err)
	}
	current, err := store.Get()
	if err != nil || current.Revision != 7 || current.Settings.Mode != "global" || !current.Settings.DevMode || len(current.Settings.CampusCIDRs) != 3 {
		t.Fatalf("fixture mismatch: %+v %v", current, err)
	}
	updated, err := store.Patch(context.Background(), 7, json.RawMessage(`{"blacklist":[]}`))
	if err != nil || updated.Revision != 8 || len(updated.Settings.CampusCIDRs) != 3 || len(updated.Settings.Blacklist) != 0 {
		t.Fatalf("patch lost fields: %+v %v", updated, err)
	}
}
