package worker

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"sync"
	"time"

	"github.com/yourname/freev6/internal/notice"
	"github.com/yourname/freev6/internal/publisher"
)

const noticeFile = "maintainer-notice-" + publisher.CacheNamespace + ".json"
const maxNoticeCache = 768 << 10

type NoticeSnapshot struct {
	Source       string        `json:"source"`
	FetchedAt    *time.Time    `json:"fetchedAt,omitempty"`
	CloudAllowed bool          `json:"cloudAllowed"`
	Items        []notice.Item `json:"items"`
}

type NoticeManager struct {
	root        *os.Root
	fetch       func(context.Context, time.Time) (notice.Payload, error)
	refreshLock sync.Mutex
	mu          sync.Mutex
	failedSave  bool
	now         func() time.Time
}

func NewNoticeManager(root *os.Root) *NoticeManager {
	return &NoticeManager{root: root, fetch: notice.FetchPublished, now: time.Now}
}

func (m *NoticeManager) cached() NoticeSnapshot {
	m.mu.Lock()
	defer m.mu.Unlock()
	empty := NoticeSnapshot{Source: "unavailable", Items: []notice.Item{}}
	if m.failedSave {
		return empty
	}
	f, err := m.root.OpenFile(noticeFile, os.O_RDONLY|importFileFlags, 0)
	if err != nil {
		return empty
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > maxNoticeCache {
		return empty
	}
	data, err := io.ReadAll(io.LimitReader(f, maxNoticeCache+1))
	var cache notice.Cache
	now := m.now()
	if err != nil || len(data) > maxNoticeCache || json.Unmarshal(data, &cache) != nil || !cache.Fresh(now) {
		return empty
	}
	// Re-validate text, expiry and links even when the file originated on this machine.
	p, err := notice.Parse(data, now)
	if err != nil {
		return empty
	}
	return NoticeSnapshot{Source: "cache", FetchedAt: &cache.FetchedAt, CloudAllowed: notice.CloudAllowed(p.CloudProfile), Items: p.Items}
}

func (m *NoticeManager) refresh(ctx context.Context) (NoticeSnapshot, error) {
	if !m.refreshLock.TryLock() {
		return NoticeSnapshot{}, &RPCError{Busy, "正在更新公告"}
	}
	defer m.refreshLock.Unlock()
	now := m.now().UTC().Truncate(time.Second)
	p, err := m.fetch(ctx, now)
	if err != nil {
		if ctx.Err() != nil {
			return NoticeSnapshot{}, ctx.Err()
		}
		return m.cached(), nil
	}
	cache := notice.Cache{FetchedAt: now, Items: p.Items, CloudProfile: p.CloudProfile, Updated: p.Updated}
	data, err := json.Marshal(cache)
	if err != nil || len(data) > maxNoticeCache {
		return NoticeSnapshot{}, &RPCError{StorageError, "公告超出缓存上限"}
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return NoticeSnapshot{}, err
	}
	if err := replaceDataFile(ctx, m.root, noticeFile, data); err != nil {
		m.failedSave = true
		// Do not reuse the old permission after receiving an explicit revocation.
		if !notice.CloudAllowed(p.CloudProfile) {
			_ = m.root.Remove(noticeFile)
		}
		return NoticeSnapshot{}, &RPCError{StorageError, "无法保存公告"}
	}
	m.failedSave = false
	return NoticeSnapshot{Source: "online", FetchedAt: &now, CloudAllowed: notice.CloudAllowed(p.CloudProfile), Items: p.Items}, nil
}
func NoticeHandler(m *NoticeManager, next Handler) Handler {
	return func(ctx context.Context, method string, params json.RawMessage) (any, error) {
		if method != "notice.status" && method != "notice.refresh" {
			return next(ctx, method, params)
		}
		var input struct{}
		if decodeObject(params, &input) != nil {
			return nil, &RPCError{InvalidParams, "公告方法只接受空对象"}
		}
		if method == "notice.refresh" {
			return m.refresh(ctx)
		}
		return m.cached(), nil
	}
}
