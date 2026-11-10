package mihomo

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func geodataFixture(t *testing.T) (geodataPreparer, map[string][]byte) {
	t.Helper()
	p, err := newGeodataPreparer()
	if err != nil {
		t.Fatal(err)
	}
	data := map[string][]byte{}
	for i := range p.catalog.Assets {
		a := &p.catalog.Assets[i]
		data[a.Name] = []byte("synthetic test data: " + a.Name)
		a.Size = int64(len(data[a.Name]))
		a.SHA256 = runtimeDigest(data[a.Name])
	}
	p.sources = func(GeodataAsset) []string { t.Error("unexpected network fallback"); return nil }
	return p, data
}

func seedGeodata(t *testing.T, resource string, p geodataPreparer, data map[string][]byte) {
	t.Helper()
	directory := filepath.Join(resource, "Geodata", p.catalog.Revision)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	for name, bytes := range data {
		if err := os.WriteFile(filepath.Join(directory, name), bytes, 0o400); err != nil {
			t.Fatal(err)
		}
	}
}

func TestPinnedGeodataCatalog(t *testing.T) {
	p, err := newGeodataPreparer()
	if err != nil {
		t.Fatal(err)
	}
	for _, a := range p.catalog.Assets {
		for _, url := range p.sources(a) {
			if !strings.HasPrefix(url, "https://") || !strings.Contains(url, p.catalog.Revision) || strings.Contains(url, "latest") {
				t.Fatal(url)
			}
		}
	}
	for _, mutate := range []func(*GeodataCatalog){
		func(c *GeodataCatalog) { c.Revision = "../escape" },
		func(c *GeodataCatalog) { c.Assets[0].Name = "../GeoSite.dat" },
		func(c *GeodataCatalog) { c.Assets[0].SHA256 = "bad" },
		func(c *GeodataCatalog) { c.Assets[0].Size = maxGeositeSize + 1 },
		func(c *GeodataCatalog) { c.Assets[1] = c.Assets[0] },
	} {
		c, _ := PinnedGeodata()
		mutate(&c)
		if c.validate() == nil {
			t.Fatal("accepted bad catalog")
		}
	}
}

func TestGeodataPackageExplicitSeedAndCache(t *testing.T) {
	p, data := geodataFixture(t)
	resource, cache := t.TempDir(), t.TempDir()
	seedGeodata(t, resource, p, data)
	initial, err := p.inspect(context.Background(), cache)
	if err != nil || initial.Available {
		t.Fatal(initial, err)
	}
	var events []GeodataProgress
	result, err := p.prepare(context.Background(), resource, cache, func(p GeodataProgress) { events = append(events, p) })
	if err != nil || !result.Available {
		t.Fatal(result, err)
	}
	if len(events) != 7 {
		t.Fatal(events)
	}
	for _, a := range result.Files {
		info, err := os.Stat(filepath.Join(result.Directory, a.Name))
		if err != nil {
			t.Fatal(info, err)
		}
		// Windows exposes the read-only attribute, not POSIX permission bits.
		if runtime.GOOS != "windows" && info.Mode().Perm() != 0o600 {
			t.Fatalf("cache file permissions: got %o, want 600", info.Mode().Perm())
		}
		seed, _ := os.ReadFile(filepath.Join(resource, "Geodata", p.catalog.Revision, a.Name))
		if string(seed) != string(data[a.Name]) {
			t.Fatal("modified resource")
		}
	}
	encoded, _ := json.Marshal(result)
	if strings.Contains(string(encoded), cache) || strings.Contains(string(encoded), resource) {
		t.Fatal("exposed path")
	}
	// Repeated prepare only inspects. Corruption must invalidate readiness.
	if result, err = p.prepare(context.Background(), resource, cache, nil); err != nil || !result.Available {
		t.Fatal(result, err)
	}
	bad := filepath.Join(result.Directory, p.catalog.Assets[1].Name)
	if err := os.WriteFile(bad, []byte("corrupt"), 0o600); err != nil {
		t.Fatal(err)
	}
	result, err = p.inspect(context.Background(), cache)
	if err != nil || result.Available || result.Files[1].Available {
		t.Fatal(result, err)
	}
	result, err = p.prepare(context.Background(), resource, cache, nil)
	if err != nil || !result.Available {
		t.Fatal(result, err)
	}
}

func TestGeodataPackageFallbackAndPartialResume(t *testing.T) {
	p, data := geodataFixture(t)
	var allowRest atomic.Bool
	var hits atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits.Add(1)
		name := strings.TrimPrefix(r.URL.Path, "/")
		if name != GeositeFileName && !allowRest.Load() {
			http.Error(w, "failure", 503)
			return
		}
		w.Write(data[name])
	}))
	defer server.Close()
	p.sources = func(a GeodataAsset) []string { return []string{server.URL + "/bad", server.URL + "/" + a.Name} }
	resource, cache := t.TempDir(), t.TempDir()
	// An HTML-like seed with the right size is rejected by the pinned digest.
	bad := map[string][]byte{GeositeFileName: []byte(strings.Repeat("x", len(data[GeositeFileName])))}
	seedGeodata(t, resource, p, bad)
	result, err := p.prepare(context.Background(), resource, cache, nil)
	if err == nil || result.Available || !result.Files[0].Available {
		t.Fatal(result, err)
	}
	files, _ := os.ReadDir(result.Directory)
	if len(files) != 1 || files[0].Name() != GeositeFileName {
		t.Fatal("partial files leaked", files)
	}
	allowRest.Store(true)
	hits.Store(0)
	result, err = p.prepare(context.Background(), resource, cache, nil)
	if err != nil || !result.Available || hits.Load() != 4 {
		t.Fatal(result, hits.Load(), err)
	}
}

func TestGeodataPackageReplacesCacheSymlinkWithoutChangingTarget(t *testing.T) {
	p, data := geodataFixture(t)
	resource, cache := t.TempDir(), t.TempDir()
	seedGeodata(t, resource, p, data)
	result, err := p.prepare(context.Background(), resource, cache, nil)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(result.Directory, GeositeFileName)
	outside := filepath.Join(t.TempDir(), "unrelated")
	if err := os.WriteFile(outside, data[GeositeFileName], 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, path); err != nil {
		t.Skip("symlink unavailable:", err)
	}
	result, err = p.inspect(context.Background(), cache)
	if err != nil || result.Available {
		t.Fatal(result, err)
	}
	result, err = p.prepare(context.Background(), resource, cache, nil)
	if err != nil || !result.Available {
		t.Fatal(result, err)
	}
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() {
		t.Fatal(info, err)
	}
	bytes, err := os.ReadFile(outside)
	if err != nil || string(bytes) != string(data[GeositeFileName]) {
		t.Fatal("changed unrelated target", err)
	}
}

func TestGeodataPackageRejectsBadTransfersAndCleansCancellation(t *testing.T) {
	for _, scenario := range []string{"wrong-hash", "truncated", "oversized", "chunked-oversized", "cancel", "stalled"} {
		t.Run(scenario, func(t *testing.T) {
			p, data := geodataFixture(t)
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				body := append([]byte{}, data[GeositeFileName]...)
				switch scenario {
				case "wrong-hash":
					body[0] = 'x'
				case "truncated":
					body = body[:3]
				case "oversized", "chunked-oversized":
					body = append(body, 'x')
				case "cancel", "stalled":
					w.Write(body[:1])
					w.(http.Flusher).Flush()
					if scenario == "cancel" {
						cancel()
					}
					<-r.Context().Done()
					return
				}
				if scenario == "chunked-oversized" {
					w.(http.Flusher).Flush()
				}
				w.Write(body)
			}))
			defer server.Close()
			p.stall, p.interval = 30*time.Millisecond, 5*time.Millisecond
			p.sources = func(GeodataAsset) []string { return []string{server.URL} }
			result, err := p.prepare(ctx, t.TempDir(), t.TempDir(), nil)
			if err == nil || result.Available {
				t.Fatal(result, err)
			}
			if scenario == "cancel" && !errors.Is(err, context.Canceled) {
				t.Fatal(err)
			}
			entries, _ := os.ReadDir(result.Directory)
			if len(entries) != 0 {
				t.Fatal("temporary data left behind", entries)
			}
		})
	}
}

func TestRealPinnedGeodata(t *testing.T) {
	fixtures := os.Getenv("FREEV6_GEODATA_FIXTURES_DIR")
	if fixtures == "" {
		t.Skip("set FREEV6_GEODATA_FIXTURES_DIR to verify official upstream assets")
	}
	p, err := newGeodataPreparer()
	if err != nil {
		t.Fatal(err)
	}
	data := map[string][]byte{}
	for _, a := range p.catalog.Assets {
		if err := verifyRuntimeFile(context.Background(), filepath.Join(fixtures, a.Name), a.SHA256, a.Size); err != nil {
			t.Fatal(a.Name, err)
		}
		data[a.Name], err = os.ReadFile(filepath.Join(fixtures, a.Name))
		if err != nil {
			t.Fatal(err)
		}
	}
	resource := t.TempDir()
	seedGeodata(t, resource, p, data)
	p.sources = func(GeodataAsset) []string { t.Fatal("must use verified seeds"); return nil }
	result, err := p.prepare(context.Background(), resource, t.TempDir(), nil)
	if err != nil || !result.Available {
		t.Fatal(result, err)
	}
}
