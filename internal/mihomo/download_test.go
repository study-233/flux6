package mihomo

import (
	"archive/zip"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"debug/macho"
	"encoding/binary"
	"encoding/hex"
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

func runtimeTestBinary(goos, arch string) []byte {
	data := make([]byte, 512)
	if goos == "darwin" {
		cpu := uint32(macho.CpuArm64)
		if arch == "amd64" {
			cpu = uint32(macho.CpuAmd64)
		}
		binary.LittleEndian.PutUint32(data[0:], macho.Magic64)
		binary.LittleEndian.PutUint32(data[4:], cpu)
		binary.LittleEndian.PutUint32(data[12:], uint32(macho.TypeExec))
	} else {
		copy(data, []byte("MZ"))
		binary.LittleEndian.PutUint32(data[0x3c:], 0x40)
		copy(data[0x40:], []byte("PE\x00\x00"))
		binary.LittleEndian.PutUint16(data[0x44:], 0x8664)
		binary.LittleEndian.PutUint16(data[0x54:], 240)
		binary.LittleEndian.PutUint16(data[0x56:], 2)
		binary.LittleEndian.PutUint16(data[0x58:], 0x20b)
		binary.LittleEndian.PutUint32(data[0x58+108:], 16)
	}
	return data
}

func runtimeDigest(data []byte) string { sum := sha256.Sum256(data); return hex.EncodeToString(sum[:]) }

func runtimeFixture(t *testing.T, goos, arch string, payload []byte) (runtimeDownloader, []byte) {
	t.Helper()
	asset, err := PinnedRuntimeAsset(goos, arch)
	if err != nil {
		t.Fatal(err)
	}
	var buffer bytes.Buffer
	if goos == "windows" {
		writer := zip.NewWriter(&buffer)
		entry, err := writer.Create(asset.Binary)
		if err != nil {
			t.Fatal(err)
		}
		if _, err = entry.Write(payload); err != nil {
			t.Fatal(err)
		}
		if err = writer.Close(); err != nil {
			t.Fatal(err)
		}
	} else {
		writer := gzip.NewWriter(&buffer)
		writer.Name = "../../ignored-header-name"
		if _, err = writer.Write(payload); err != nil {
			t.Fatal(err)
		}
		if err = writer.Close(); err != nil {
			t.Fatal(err)
		}
	}
	asset.SHA256 = runtimeDigest(buffer.Bytes())
	asset.BinarySHA256 = runtimeDigest(payload)
	d := newRuntimeDownloader(asset)
	d.client = &http.Client{}
	d.stall = 300 * time.Millisecond
	d.hard = 3 * time.Second
	d.interval = 50 * time.Millisecond
	return d, buffer.Bytes()
}

func runtimeServer(t *testing.T, payload []byte) *httptest.Server {
	t.Helper()
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write(payload) }))
	t.Cleanup(s.Close)
	return s
}

func TestDownloadRuntimePlatformsAndProgress(t *testing.T) {
	for _, target := range [][2]string{{"windows", "amd64"}, {"darwin", "arm64"}, {"darwin", "amd64"}} {
		t.Run(target[0]+"-"+target[1], func(t *testing.T) {
			payload := runtimeTestBinary(target[0], target[1])
			d, archive := runtimeFixture(t, target[0], target[1], payload)
			d.urls = []string{runtimeServer(t, archive).URL}
			var received int64
			result, err := d.install(context.Background(), t.TempDir(), t.TempDir(), func(p RuntimeProgress) { received = p.Received })
			if err != nil {
				t.Fatal(err)
			}
			data, err := os.ReadFile(result.Path)
			if err != nil || !bytes.Equal(data, payload) {
				t.Fatal("incorrect extracted binary", err)
			}
			if result.SHA256 != d.asset.SHA256 || filepath.Base(result.Path) != d.asset.Binary || received != int64(len(archive)) {
				t.Fatalf("incorrect result/progress: %+v %d", result, received)
			}
			if runtime.GOOS != "windows" {
				info, _ := os.Stat(result.Path)
				if info.Mode().Perm() != 0o700 {
					t.Fatal("missing execute permission")
				}
			}
		})
	}
	if _, err := PinnedRuntimeAsset("darwin", "386"); err == nil {
		t.Fatal("unsupported architecture accepted")
	}
}

func TestDownloadRuntimeHungMirrorCutByStallWatchdog(t *testing.T) {
	d, archive := runtimeFixture(t, "windows", "amd64", runtimeTestBinary("windows", "amd64"))
	hung := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { <-r.Context().Done() }))
	defer hung.Close()
	d.urls = []string{hung.URL, runtimeServer(t, archive).URL}
	start := time.Now()
	if _, err := d.install(context.Background(), t.TempDir(), t.TempDir(), nil); err != nil {
		t.Fatal(err)
	}
	if time.Since(start) > 2*time.Second {
		t.Fatal("stalled mirror consumed hard timeout")
	}
}

func TestDownloadRuntimeHardCapCutsTricklingMirror(t *testing.T) {
	d, archive := runtimeFixture(t, "darwin", "arm64", runtimeTestBinary("darwin", "arm64"))
	trickle := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for {
			_, _ = w.Write([]byte{0})
			w.(http.Flusher).Flush()
			select {
			case <-r.Context().Done():
				return
			case <-time.After(100 * time.Millisecond):
			}
		}
	}))
	defer trickle.Close()
	d.stall = 800 * time.Millisecond
	d.hard = 1500 * time.Millisecond
	d.urls = []string{trickle.URL, runtimeServer(t, archive).URL}
	start := time.Now()
	if _, err := d.install(context.Background(), t.TempDir(), t.TempDir(), nil); err != nil {
		t.Fatal(err)
	}
	if elapsed := time.Since(start); elapsed < time.Second || elapsed > 3*time.Second {
		t.Fatalf("wrong hard-timeout behavior: %v", elapsed)
	}
}

func TestDownloadRuntimeRejectsDigestMismatchAndKeepsOldBinary(t *testing.T) {
	d, archive := runtimeFixture(t, "windows", "amd64", runtimeTestBinary("windows", "amd64"))
	bad := runtimeServer(t, []byte("untrusted"))
	good := runtimeServer(t, archive)
	d.urls = []string{bad.URL}
	directory := t.TempDir()
	old := filepath.Join(directory, d.asset.Binary)
	if err := os.WriteFile(old, []byte("previous core"), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := d.install(context.Background(), directory, t.TempDir(), nil); err == nil || !strings.Contains(err.Error(), "sha256") {
		t.Fatalf("digest mismatch accepted: %v", err)
	}
	if data, _ := os.ReadFile(old); string(data) != "previous core" {
		t.Fatal("old core overwritten on failure")
	}
	d.urls = []string{bad.URL, good.URL}
	if _, err := d.install(context.Background(), directory, t.TempDir(), nil); err != nil {
		t.Fatal(err)
	}
}

func TestDownloadRuntimeAllMirrorsFail(t *testing.T) {
	d, _ := runtimeFixture(t, "darwin", "arm64", runtimeTestBinary("darwin", "arm64"))
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { http.Error(w, "unavailable", 500) }))
	defer server.Close()
	d.urls = []string{server.URL, server.URL}
	_, err := d.install(context.Background(), t.TempDir(), t.TempDir(), nil)
	if err == nil || !strings.Contains(err.Error(), "已尝试 2/2") || !strings.Contains(err.Error(), "127.0.0.1") {
		t.Fatalf("missing mirror failure context: %v", err)
	}
}

func TestDownloadRuntimeHonorsExpiredContextAndCleansTemporary(t *testing.T) {
	d, _ := runtimeFixture(t, "darwin", "arm64", runtimeTestBinary("darwin", "arm64"))
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte{1})
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer server.Close()
	d.urls = []string{server.URL, server.URL}
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	temporary := t.TempDir()
	_, err := d.install(ctx, t.TempDir(), temporary, nil)
	if !errors.Is(err, context.DeadlineExceeded) || !strings.Contains(err.Error(), "超时") {
		t.Fatalf("lost cancellation: %v", err)
	}
	if entries, _ := os.ReadDir(temporary); len(entries) != 0 {
		t.Fatal("partial archive retained")
	}
}

func TestRuntimePackageCacheAndRepair(t *testing.T) {
	d, archive := runtimeFixture(t, "darwin", "arm64", runtimeTestBinary("darwin", "arm64"))
	var hits atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hits.Add(1); w.Write(archive) }))
	defer server.Close()
	d.urls = []string{server.URL}
	cache := t.TempDir()
	before, err := d.inspect(context.Background(), cache)
	if err != nil || before.Available {
		t.Fatal("missing archive marked ready")
	}
	prepared, err := d.prepare(context.Background(), cache, nil)
	if err != nil || !prepared.Available {
		t.Fatal(err)
	}
	if again, err := d.prepare(context.Background(), cache, nil); err != nil || !again.Available || hits.Load() != 1 {
		t.Fatalf("cache not reused: %+v %v %d", again, err, hits.Load())
	}
	if err := os.WriteFile(prepared.ArchivePath, []byte("damaged"), 0o600); err != nil {
		t.Fatal(err)
	}
	if broken, err := d.inspect(context.Background(), cache); err != nil || broken.Available {
		t.Fatal("damaged cache marked ready")
	}
	if repaired, err := d.prepare(context.Background(), cache, nil); err != nil || !repaired.Available || hits.Load() != 2 {
		t.Fatal("cache repair failed", err)
	}
	entries, _ := os.ReadDir(filepath.Dir(prepared.ArchivePath))
	if len(entries) != 1 || entries[0].Name() != d.asset.Archive {
		t.Fatal("temporary extracted executable retained")
	}
}

func TestRuntimeRejectsWrongArchitectureAndExpansionLimits(t *testing.T) {
	for _, test := range []string{"architecture", "binary-digest", "expanded-limit", "archive-limit", "unknown-length-limit"} {
		t.Run(test, func(t *testing.T) {
			d, archive := runtimeFixture(t, "darwin", "amd64", runtimeTestBinary("darwin", "arm64"))
			if test != "architecture" {
				d, archive = runtimeFixture(t, "darwin", "arm64", runtimeTestBinary("darwin", "arm64"))
			}
			switch test {
			case "binary-digest":
				d.asset.BinarySHA256 = strings.Repeat("0", 64)
			case "expanded-limit":
				d.binaryLimit = 16
			case "archive-limit", "unknown-length-limit":
				d.archiveLimit = 16
			}
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if test == "unknown-length-limit" {
					w.(http.Flusher).Flush()
				}
				w.Write(archive)
			}))
			defer server.Close()
			d.urls = []string{server.URL}
			directory := t.TempDir()
			final := filepath.Join(directory, d.asset.Binary)
			os.WriteFile(final, []byte("previous"), 0o700)
			if _, err := d.install(context.Background(), directory, t.TempDir(), nil); err == nil {
				t.Fatal("invalid asset installed")
			}
			if data, _ := os.ReadFile(final); string(data) != "previous" {
				t.Fatal("previous binary changed")
			}
			entries, _ := os.ReadDir(directory)
			if len(entries) != 1 {
				t.Fatal("partial executable retained")
			}
		})
	}
}

func TestRuntimeZIPRejectsUnexpectedEntries(t *testing.T) {
	for _, variant := range []string{"traversal", "symlink", "extra-entry", "expansion-limit"} {
		t.Run(variant, func(t *testing.T) {
			payload := runtimeTestBinary("windows", "amd64")
			d, _ := runtimeFixture(t, "windows", "amd64", payload)
			var buffer bytes.Buffer
			writer := zip.NewWriter(&buffer)
			header := &zip.FileHeader{Name: d.asset.Binary, Method: zip.Deflate}
			if variant == "traversal" {
				header.Name = "../" + header.Name
			}
			if variant == "symlink" {
				header.SetMode(os.ModeSymlink | 0o777)
			}
			entry, err := writer.CreateHeader(header)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := entry.Write(payload); err != nil {
				t.Fatal(err)
			}
			if variant == "extra-entry" {
				if _, err := writer.Create("other.exe"); err != nil {
					t.Fatal(err)
				}
			}
			if err := writer.Close(); err != nil {
				t.Fatal(err)
			}
			d.asset.SHA256 = runtimeDigest(buffer.Bytes())
			if variant == "expansion-limit" {
				d.binaryLimit = 16
			}
			d.urls = []string{runtimeServer(t, buffer.Bytes()).URL}
			dir := t.TempDir()
			if _, err := d.install(context.Background(), dir, t.TempDir(), nil); err == nil {
				t.Fatal("unsafe ZIP installed")
			}
			if entries, _ := os.ReadDir(dir); len(entries) != 0 {
				t.Fatal("unsafe ZIP left an executable")
			}
		})
	}
}
