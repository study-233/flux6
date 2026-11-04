package mihomo

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestPinnedRuntimeCatalogAndArchitectureBaselines(t *testing.T) {
	for _, target := range [][3]string{{"windows", "amd64", "mihomo-windows-amd64-v3.exe"}, {"darwin", "arm64", "mihomo-darwin-arm64"}, {"darwin", "amd64", "mihomo-darwin-amd64-v1"}} {
		a, err := PinnedRuntimeAsset(target[0], target[1])
		if err != nil {
			t.Fatal(err)
		}
		if a.Binary != target[2] || a.Version != "v1.19.31" || len(a.SourceURLs()) != 6 {
			t.Fatalf("catalog mismatch: %+v", a)
		}
	}
}

func TestRealPinnedRuntimeArtifacts(t *testing.T) {
	directory := os.Getenv("FREEV6_RUNTIME_FIXTURES_DIR")
	if directory == "" {
		t.Skip("set FREEV6_RUNTIME_FIXTURES_DIR to verify downloaded official artifacts")
	}
	for _, target := range [][2]string{{"windows", "amd64"}, {"darwin", "arm64"}, {"darwin", "amd64"}} {
		t.Run(target[0]+"-"+target[1], func(t *testing.T) {
			a, err := PinnedRuntimeAsset(target[0], target[1])
			if err != nil {
				t.Fatal(err)
			}
			archive := filepath.Join(directory, a.Archive)
			if err := verifyRuntimeFile(context.Background(), archive, a.SHA256, maxRuntimeDownload); err != nil {
				t.Fatal(err)
			}
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.ServeFile(w, r, archive) }))
			defer server.Close()
			d := newRuntimeDownloader(a)
			d.client = &http.Client{}
			d.urls = []string{server.URL}
			result, err := d.install(context.Background(), t.TempDir(), t.TempDir(), nil)
			if err != nil {
				t.Fatal(err)
			}
			if err := verifyRuntimeFile(context.Background(), result.Path, a.BinarySHA256, maxRuntimeDownload); err != nil {
				t.Fatal(err)
			}
			info, err := os.Stat(result.Path)
			if err != nil {
				t.Fatal(err)
			}
			t.Logf("verified %s/%s: archive=%s binary=%s bytes=%d", a.OS, a.Arch, a.SHA256, a.BinarySHA256, info.Size())
		})
	}
}
