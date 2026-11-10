package mihomo

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"sync/atomic"
	"time"

	"github.com/yourname/freev6/internal/stallhttp"
)

// Shared bounded transport for pinned runtime and geodata bytes. Callers own
// asset selection, format validation and the final atomic commit.
type pinnedTransfer struct {
	client                *http.Client
	digest                string
	limit                 int64
	stall, hard, interval time.Duration
}

func pinnedHTTPClient() *http.Client {
	return &http.Client{CheckRedirect: func(request *http.Request, via []*http.Request) error {
		if len(via) >= 10 || request.URL.Scheme != "https" {
			return fmt.Errorf("unsafe or excessive resource redirect")
		}
		return nil
	}}
}

func (transfer pinnedTransfer) download(ctx context.Context, source, temporaryDir string, progress progressSink) (string, error) {
	mirrorCtx, cancel := context.WithTimeout(ctx, transfer.hard)
	defer cancel()
	var received atomic.Int64
	stop := stallhttp.StartWatchdog(mirrorCtx, cancel, &received, transfer.stall, transfer.interval)
	defer stop()
	request, err := http.NewRequestWithContext(mirrorCtx, http.MethodGet, source, nil)
	if err != nil {
		return "", err
	}
	request.Header.Set("User-Agent", "freev6")
	response, err := transfer.client.Do(request)
	if err != nil {
		return "", fmt.Errorf("download: %w", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("download returned HTTP %s", response.Status)
	}
	if response.ContentLength > transfer.limit {
		return "", fmt.Errorf("resource exceeds size limit")
	}
	temporary, err := os.CreateTemp(temporaryDir, ".freev6-transfer-*")
	if err != nil {
		return "", err
	}
	keep := false
	defer func() {
		temporary.Close()
		if !keep {
			os.Remove(temporary.Name())
		}
	}()
	hash := sha256.New()
	body := &stallhttp.CountingReader{Reader: response.Body, Counter: &received}
	reader := &progressReportingReader{r: io.TeeReader(body, hash), received: &received, total: response.ContentLength, onProgress: progress}
	count, err := io.Copy(temporary, io.LimitReader(reader, transfer.limit+1))
	if err != nil {
		return "", err
	}
	if count > transfer.limit {
		return "", fmt.Errorf("resource exceeds size limit")
	}
	if hex.EncodeToString(hash.Sum(nil)) != transfer.digest {
		return "", fmt.Errorf("sha256 与固定值不符，镜像内容不可信")
	}
	if err := temporary.Sync(); err != nil {
		return "", err
	}
	if err := temporary.Close(); err != nil {
		return "", err
	}
	if err := mirrorCtx.Err(); err != nil {
		return "", err
	}
	keep = true
	return temporary.Name(), nil
}
