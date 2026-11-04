package mihomo

import (
	"archive/zip"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"debug/macho"
	"debug/pe"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"time"
)

const maxRuntimeDownload = 150 << 20

type DownloadResult struct{ Version, Path, SHA256 string }
type progressSink func(received, total int64)

type RuntimeProgress struct {
	Phase    string `json:"phase"`
	Received int64  `json:"received"`
	Total    int64  `json:"total"`
	Attempt  int    `json:"attempt"`
	Attempts int    `json:"attempts"`
}

type RuntimePackage struct {
	ResourceID   string `json:"resourceId"`
	Version      string `json:"version"`
	Platform     string `json:"platform"`
	Architecture string `json:"architecture"`
	Archive      string `json:"archive"`
	SHA256       string `json:"sha256"`
	BinarySHA256 string `json:"binarySha256"`
	Available    bool   `json:"available"`
	ArchivePath  string `json:"-"`
}

type runtimeDownloader struct {
	asset                     RuntimeAsset
	urls                      []string
	client                    *http.Client
	stall, hard, interval     time.Duration
	archiveLimit, binaryLimit int64
}

func newRuntimeDownloader(asset RuntimeAsset) runtimeDownloader {
	return runtimeDownloader{asset: asset, urls: asset.SourceURLs(), client: pinnedHTTPClient(), stall: 10 * time.Second, hard: time.Minute, interval: time.Second,
		archiveLimit: maxRuntimeDownload, binaryLimit: maxRuntimeDownload}
}

func DownloadLatest(ctx context.Context, root string) (DownloadResult, error) {
	return DownloadLatestWithProgress(ctx, root, nil)
}

// The legacy helper retains its API and runtime directory. Windows amd64
// continues to use the pinned v3 executable; other hosts select their own asset.
func DownloadLatestWithProgress(ctx context.Context, root string, progress progressSink) (DownloadResult, error) {
	asset, err := PinnedRuntimeAsset(runtime.GOOS, runtime.GOARCH)
	if err != nil {
		return DownloadResult{}, err
	}
	d := newRuntimeDownloader(asset)
	return d.install(ctx, filepath.Join(root, "runtime"), os.TempDir(), func(p RuntimeProgress) {
		if progress != nil {
			progress(p.Received, p.Total)
		}
	})
}

func InspectRuntimePackage(ctx context.Context, cacheDir, goos, goarch string) (RuntimePackage, error) {
	asset, err := PinnedRuntimeAsset(goos, goarch)
	if err != nil {
		return RuntimePackage{}, err
	}
	d := newRuntimeDownloader(asset)
	return d.inspect(ctx, cacheDir)
}

// PrepareRuntimePackage validates a user-owned cache artifact. It never
// executes the core. The root service must independently verify both pinned
// digests before installing a copy in its own directory.
func PrepareRuntimePackage(ctx context.Context, cacheDir, goos, goarch string, progress func(RuntimeProgress)) (RuntimePackage, error) {
	asset, err := PinnedRuntimeAsset(goos, goarch)
	if err != nil {
		return RuntimePackage{}, err
	}
	d := newRuntimeDownloader(asset)
	return d.prepare(ctx, cacheDir, progress)
}

func (d runtimeDownloader) packageInfo(cacheDir string) RuntimePackage {
	a := d.asset
	return RuntimePackage{ResourceID: a.ResourceID(), Version: a.Version, Platform: a.OS, Architecture: a.Arch,
		Archive: a.Archive, SHA256: a.SHA256, BinarySHA256: a.BinarySHA256,
		ArchivePath: filepath.Join(cacheDir, "runtime", a.SHA256, a.Archive)}
}

func (d runtimeDownloader) inspect(ctx context.Context, cacheDir string) (RuntimePackage, error) {
	info := d.packageInfo(cacheDir)
	if err := d.asset.validate(); err != nil {
		return info, err
	}
	if _, err := os.Lstat(info.ArchivePath); os.IsNotExist(err) {
		return info, nil
	} else if err != nil {
		return info, err
	}
	if err := verifyRuntimeFile(ctx, info.ArchivePath, d.asset.SHA256, d.archiveLimit); err != nil {
		if ctx.Err() != nil {
			return info, ctx.Err()
		}
		return info, nil
	}
	output, err := d.extract(ctx, info.ArchivePath, filepath.Dir(info.ArchivePath))
	if err != nil {
		return info, err
	}
	if err := os.Remove(output); err != nil {
		return info, err
	}
	info.Available = true
	return info, nil
}

func (d runtimeDownloader) prepare(ctx context.Context, cacheDir string, progress func(RuntimeProgress)) (RuntimePackage, error) {
	if progress != nil {
		progress(RuntimeProgress{Phase: "checking", Total: -1})
	}
	info, err := d.inspect(ctx, cacheDir)
	if err != nil || info.Available {
		return info, err
	}
	directory := filepath.Dir(info.ArchivePath)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return info, err
	}
	archive, err := d.download(ctx, directory, progress)
	if err != nil {
		return info, err
	}
	defer os.Remove(archive)
	if progress != nil {
		progress(RuntimeProgress{Phase: "verifying", Total: -1})
	}
	output, err := d.extract(ctx, archive, directory)
	if err != nil {
		return info, err
	}
	defer os.Remove(output)
	if err := ctx.Err(); err != nil {
		return info, err
	}
	if err := os.Rename(archive, info.ArchivePath); err != nil {
		return info, err
	}
	if err := syncRuntimeDirectory(directory); err != nil {
		return info, err
	}
	info.Available = true
	return info, nil
}

func (d runtimeDownloader) install(ctx context.Context, runtimeDir, temporaryDir string, progress func(RuntimeProgress)) (DownloadResult, error) {
	if err := d.asset.validate(); err != nil {
		return DownloadResult{}, err
	}
	archive, err := d.download(ctx, temporaryDir, progress)
	if err != nil {
		return DownloadResult{}, err
	}
	defer os.Remove(archive)
	if err := os.MkdirAll(runtimeDir, 0o700); err != nil {
		return DownloadResult{}, err
	}
	output, err := d.extract(ctx, archive, runtimeDir)
	if err != nil {
		return DownloadResult{}, err
	}
	defer os.Remove(output)
	if err := os.Chmod(output, 0o700); err != nil {
		return DownloadResult{}, err
	}
	if err := ctx.Err(); err != nil {
		return DownloadResult{}, err
	}
	final := filepath.Join(runtimeDir, d.asset.Binary)
	if err := os.Rename(output, final); err != nil {
		return DownloadResult{}, err
	}
	return DownloadResult{Version: d.asset.Version, Path: final, SHA256: d.asset.SHA256}, nil
}

func (d runtimeDownloader) download(ctx context.Context, temporaryDir string, progress func(RuntimeProgress)) (string, error) {
	var failures []string
	for index, source := range d.urls {
		if ctx.Err() != nil {
			break
		}
		notify := func(received, total int64) {
			if progress != nil {
				progress(RuntimeProgress{"downloading", received, total, index + 1, len(d.urls)})
			}
		}
		notify(0, -1)
		path, err := d.mirror(ctx, source, temporaryDir, notify)
		if err == nil {
			return path, nil
		}
		failures = append(failures, fmt.Sprintf("%s: %v", hostOf(source), err))
	}
	if ctx.Err() != nil {
		return "", fmt.Errorf("下载 mihomo 已取消或超时（剩余 %d 个镜像未尝试）: %w", len(d.urls)-len(failures), ctx.Err())
	}
	return "", fmt.Errorf("下载 mihomo runtime 失败（已尝试 %d/%d 个镜像: %s），请检查网络后重试", len(failures), len(d.urls), strings.Join(failures, "; "))
}

func (d runtimeDownloader) mirror(ctx context.Context, source, temporaryDir string, progress progressSink) (string, error) {
	return (pinnedTransfer{client: d.client, digest: d.asset.SHA256, limit: d.archiveLimit,
		stall: d.stall, hard: d.hard, interval: d.interval}).download(ctx, source, temporaryDir, progress)
}

type progressReportingReader struct {
	r          io.Reader
	received   *atomic.Int64
	total      int64
	onProgress progressSink
}

func (p *progressReportingReader) Read(b []byte) (int, error) {
	n, err := p.r.Read(b)
	if n > 0 && p.onProgress != nil {
		p.onProgress(p.received.Load(), p.total)
	}
	return n, err
}

type runtimeContextReader struct {
	context context.Context
	reader  io.Reader
}

func (r runtimeContextReader) Read(p []byte) (int, error) {
	if err := r.context.Err(); err != nil {
		return 0, err
	}
	return r.reader.Read(p)
}

func verifyRuntimeFile(ctx context.Context, path, digest string, limit int64) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Size() > limit {
		return fmt.Errorf("invalid runtime file")
	}
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	hash := sha256.New()
	n, err := io.Copy(hash, io.LimitReader(runtimeContextReader{ctx, f}, limit+1))
	if err != nil {
		return err
	}
	if n > limit || hex.EncodeToString(hash.Sum(nil)) != digest {
		return fmt.Errorf("runtime sha256 mismatch")
	}
	return nil
}

func (d runtimeDownloader) extract(ctx context.Context, archivePath, directory string) (string, error) {
	var input io.ReadCloser
	var archiveCloser io.Closer
	if filepath.Ext(d.asset.Archive) == ".zip" {
		archive, err := zip.OpenReader(archivePath)
		if err != nil {
			return "", err
		}
		defer archive.Close()
		if len(archive.File) != 1 || archive.File[0].Name != d.asset.Binary || !archive.File[0].Mode().IsRegular() {
			return "", fmt.Errorf("unexpected runtime ZIP contents")
		}
		if archive.File[0].UncompressedSize64 > uint64(d.binaryLimit) {
			return "", fmt.Errorf("expanded runtime exceeds size limit")
		}
		input, err = archive.File[0].Open()
		if err != nil {
			return "", err
		}
	} else {
		archive, err := os.Open(archivePath)
		if err != nil {
			return "", err
		}
		archiveCloser = archive
		input, err = gzip.NewReader(archive)
		if err != nil {
			archive.Close()
			return "", err
		}
	}
	defer input.Close()
	if archiveCloser != nil {
		defer archiveCloser.Close()
	}
	output, err := os.CreateTemp(directory, ".freev6-binary-*")
	if err != nil {
		return "", err
	}
	keep := false
	defer func() {
		output.Close()
		if !keep {
			os.Remove(output.Name())
		}
	}()
	hash := sha256.New()
	n, err := io.Copy(io.MultiWriter(output, hash), io.LimitReader(runtimeContextReader{ctx, input}, d.binaryLimit+1))
	if err != nil {
		return "", err
	}
	if n > d.binaryLimit {
		return "", fmt.Errorf("expanded runtime exceeds size limit")
	}
	if hex.EncodeToString(hash.Sum(nil)) != d.asset.BinarySHA256 {
		return "", fmt.Errorf("expanded runtime sha256 mismatch")
	}
	if err := output.Sync(); err != nil {
		return "", err
	}
	if err := output.Close(); err != nil {
		return "", err
	}
	if err := validateRuntimeArchitecture(output.Name(), d.asset); err != nil {
		return "", err
	}
	keep = true
	return output.Name(), nil
}

func validateRuntimeArchitecture(path string, asset RuntimeAsset) error {
	if asset.OS == "darwin" {
		file, err := macho.Open(path)
		if err != nil {
			return fmt.Errorf("invalid Mach-O core: %w", err)
		}
		defer file.Close()
		cpu := macho.CpuArm64
		if asset.Arch == "amd64" {
			cpu = macho.CpuAmd64
		}
		if file.Magic != macho.Magic64 || file.Type != macho.TypeExec || file.Cpu != cpu {
			return fmt.Errorf("wrong Mach-O architecture or type")
		}
		return nil
	}
	file, err := pe.Open(path)
	if err != nil {
		return fmt.Errorf("invalid PE core: %w", err)
	}
	defer file.Close()
	_, is64 := file.OptionalHeader.(*pe.OptionalHeader64)
	if file.Machine != pe.IMAGE_FILE_MACHINE_AMD64 || !is64 || file.Characteristics&pe.IMAGE_FILE_EXECUTABLE_IMAGE == 0 || file.Characteristics&pe.IMAGE_FILE_DLL != 0 {
		return fmt.Errorf("wrong PE architecture or type")
	}
	return nil
}

func syncRuntimeDirectory(path string) error {
	if runtime.GOOS == "windows" {
		return nil
	}
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Sync()
}
