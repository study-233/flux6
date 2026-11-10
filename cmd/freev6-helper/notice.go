package main

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"github.com/yourname/freev6/internal/notice"
	"github.com/yourname/freev6/internal/publisher"
)

// 公告板：唯一发布入口是仓库根目录的 notice.json（见 docs/notice.md），
// 客户端不直连 GitHub——helper 承担拉取、解析、过期过滤与本机缓存，
// 与更新检查共用同一套「镜像前缀 + 直连兜底 + 静默失败」策略：
// api.github.com 有 60 次/小时/IP 的共享配额且大陆经常不可达，
// raw.githubusercontent.com 在校园网实测直连超时，只有镜像族稳定。
//
// 任何失败都不是错误响应：离线、镜像全挂、文件被删都返回 200 + 空列表
// （必要时回退本机缓存），绝不阻塞启动。

var noticeURLs = func() []string { return notice.Sources(updateMirrorPrefixes) }

func (h *helper) noticeCachePath() string {
	return filepath.Join(h.root, "state", "notice-cache-"+publisher.CacheNamespace+".json")
}

// loadNoticeCache 读取本机缓存并按当前时间重新过滤过期条目；
// 缓存过旧（> 7 天）视为不可用——宁可空着也不展示失效通知。
func (h *helper) loadNoticeCache(now time.Time) (notice.Cache, bool) {
	var cache notice.Cache
	data, err := os.ReadFile(h.noticeCachePath())
	if err != nil {
		return cache, false
	}
	if err := json.Unmarshal(data, &cache); err != nil {
		return cache, false
	}
	if !cache.Fresh(now) {
		return cache, false
	}
	cache.Items = notice.LiveItems(cache.Items, now)
	return cache, true
}

// saveNoticeCache 原子写入（临时文件 + rename），半截文件永远不会被读到。
// 写失败只影响离线回退，调用方无需处理。
func (h *helper) saveNoticeCache(payload notice.Payload, now time.Time) {
	cache := notice.Cache{FetchedAt: now, Updated: payload.Updated, Items: payload.Items, CloudProfile: payload.CloudProfile}
	data, err := json.Marshal(cache)
	if err != nil {
		return
	}
	path := h.noticeCachePath()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return
	}
	temp := path + ".tmp"
	if err := os.WriteFile(temp, data, 0o644); err != nil {
		return
	}
	if err := os.Rename(temp, path); err != nil {
		_ = os.Remove(temp)
	}
}

// notice 回答前端的公告检查：
//
//	{ok:true, notices:[...], updated, fetchedAt, stale:false} 拉取成功
//	{ok:true, notices:[...], updated, fetchedAt, stale:true}  回退本机缓存
//	{ok:true, notices:[], error:"..."}                        离线且无缓存
//
// 三种情况都是 200：公告属于「可有可无」的附加信息，任何失败都不该
// 让前端把它当成错误弹窗。
func (h *helper) notice(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet {
		writeJSON(writer, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
		return
	}
	now := time.Now()
	client := &http.Client{Timeout: 8 * time.Second}
	payload, lastErr := notice.Fetch(request.Context(), client, noticeURLs(), now, func(raw string) error {
		return validateUpdateURL(raw, updateAllowedHosts)
	})
	if lastErr != nil {
		// 全线失败（或响应是空对象）：能回退缓存就回退，并如实标注 stale。
		if cache, ok := h.loadNoticeCache(now); ok {
			writeJSON(writer, http.StatusOK, map[string]any{
				"ok":           true,
				"notices":      cache.Items,
				"updated":      cache.Updated,
				"fetchedAt":    cache.FetchedAt.Format(time.RFC3339),
				"stale":        true,
				"cloudProfile": notice.CloudAllowed(cache.CloudProfile),
				"error":        errorText(lastErr),
			})
			return
		}
		writeJSON(writer, http.StatusOK, map[string]any{
			"ok":      true,
			"notices": []notice.Item{},
			"stale":   false,
			// 公告拿不到且没有缓存 → 不知道维护者是否开放，按关闭处理。
			"cloudProfile": false,
			"error":        errorText(lastErr),
		})
		return
	}

	h.saveNoticeCache(payload, now)
	writeJSON(writer, http.StatusOK, map[string]any{
		"ok":           true,
		"notices":      payload.Items,
		"updated":      payload.Updated,
		"fetchedAt":    now.Format(time.RFC3339),
		"stale":        false,
		"cloudProfile": notice.CloudAllowed(payload.CloudProfile),
	})
}
