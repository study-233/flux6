package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/yourname/freev6/internal/app"
	"github.com/yourname/freev6/internal/mihomo"
	"github.com/yourname/freev6/internal/notice"
	"github.com/yourname/freev6/internal/publisher"
)

// 备用配置（cloud profile）：校内服务端下发的出口节点。
//
// 与链式代理共用同一套"拉取 → 校验 → 落盘 → 启动时合并"管线，区别只有两点：
//  1. 校园节点是出口本身，不套 WARP 接入点，因此启动时也不再要求 WARP 凭据；
//  2. 入口地址可以是内置常量，学生零输入（见下方门禁说明）。
const (
	// maxCloudProfileBytes 与订阅导入同档：正常节点表 <100KB，2MB 挡住
	// 失控下载与内存空转。
	maxCloudProfileBytes = 2 << 20
)

// 门户地址选择当前发行仓库 profiles/ 中的公开 YAML。旧发行方的节点快照
// 不自动沿用；迁移后需要从当前来源重新获取或显式导入。

func (h *helper) cloudProfilePath() string {
	return filepath.Join(h.root, "config", "cloud-profile-"+publisher.CacheNamespace+".yaml")
}

// cloudProfileUnlocked 读取「公告里维护者开关」的最近一次结果。
//
// 语义与 notice.json 的 cloudProfile 一致：显式 true 才开放；公告拉不到、
// 没写这个字段、缓存超过 7 天，一律锁定（fail-closed）。
//
// 读缓存而不是当场联网：启动免流不该再多一次网络往返，且离线时缓存仍能
// 反映维护者最近一次的决定。公告本身由前端启动时的 /api/v1/notice 拉取
// 并写入同一个缓存文件。
func (h *helper) cloudProfileUnlocked(now time.Time) bool {
	cache, ok := h.loadNoticeCache(now)
	if !ok {
		return false
	}
	return notice.CloudAllowed(cache.CloudProfile)
}

// cloudConfig serves GET/PUT/DELETE /api/v1/cloud-config. Every method sits
// behind withCORS(guardLocalOnly(requireAuth(...))) registered in main().
func (h *helper) cloudConfig(writer http.ResponseWriter, request *http.Request) {
	switch request.Method {
	case http.MethodGet:
		h.cloudStatus(writer)
	case http.MethodPut:
		h.cloudImport(writer, request)
	case http.MethodDelete:
		h.cloudClear(writer)
	default:
		writeJSON(writer, http.StatusMethodNotAllowed, map[string]string{"error": "method not allowed"})
	}
}

func (h *helper) cloudStatus(writer http.ResponseWriter) {
	current, err := h.loadSettings()
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		writeJSON(writer, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	response := map[string]any{
		"enabled":    current.CloudEnabled,
		"count":      0,
		"names":      []string{},
		"sourceUrl":  current.CloudSourceURL,
		"updatedAt":  current.CloudUpdatedAt,
		"ignored":    []string{},
		"portalHost": current.PortalHost,
		// 公告开关：前端据此禁用「获取」与开关，而不是点下去才报错。
		"locked": !h.cloudProfileUnlocked(time.Now()),
	}
	// 只回显打码后的入口：完整地址一旦出现在界面上，截图/日志就会把它
	// 带出去，白白抵消派生的意义。
	if current.PortalHost != "" {
		if derived, deriveErr := mihomo.CloudProfileURL(current.PortalHost); deriveErr == nil {
			response["entryMasked"] = maskCloudEntry(derived)
		}
	}
	data, readErr := os.ReadFile(h.cloudProfilePath())
	switch {
	case readErr == nil:
		profile, parseErr := mihomo.ParseCloudProfile(data)
		if parseErr != nil {
			// 如实暴露坏内容（文件被手改/截断），不假装 0 个节点。
			response["error"] = parseErr.Error()
			break
		}
		names := make([]string, 0, len(profile.Nodes))
		for _, node := range profile.Nodes {
			names = append(names, node.Name)
		}
		response["count"] = len(profile.Nodes)
		response["names"] = names
		response["ignored"] = profile.Ignored
	case errors.Is(readErr, os.ErrNotExist):
		// 尚未获取：计数保持 0。
	default:
		response["error"] = readErr.Error()
	}
	writeJSON(writer, http.StatusOK, response)
}

func (h *helper) cloudImport(writer http.ResponseWriter, request *http.Request) {
	// 总开关：维护者在公告里关闭 / 公告没拿到 → 连拉取都不允许，
	// 免得学生反复点「获取」只看到网络错误。
	if !h.cloudProfileUnlocked(time.Now()) {
		writeJSON(writer, http.StatusConflict, map[string]string{"error": "备用配置当前未开放（维护者已在公告中关闭或未获取到公告）", "code": "cloud-locked"})
		return
	}
	body, err := io.ReadAll(io.LimitReader(request.Body, maxCloudProfileBytes+1))
	if err != nil {
		writeJSON(writer, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	if len(body) > maxCloudProfileBytes {
		writeJSON(writer, http.StatusBadRequest, map[string]string{"error": "内容超过 2MB 上限"})
		return
	}
	var input struct {
		Content    string `json:"content"`
		URL        string `json:"url"`
		PortalHost string `json:"portalHost"`
	}
	if err := json.Unmarshal(body, &input); err != nil {
		writeJSON(writer, http.StatusBadRequest, map[string]string{"error": "invalid JSON"})
		return
	}
	stored, loadErr := h.loadSettings()
	if loadErr != nil {
		stored = defaultSettings()
	}
	// 门户地址：本次请求填了就用新的，没填就沿用上次的（刷新不必重输）。
	portalHost := strings.TrimSpace(input.PortalHost)
	if portalHost == "" {
		portalHost = strings.TrimSpace(stored.PortalHost)
	}
	if portalHost != "" {
		normalized, normErr := mihomo.NormalizePortalHost(portalHost)
		if normErr != nil {
			writeJSON(writer, http.StatusBadRequest, map[string]string{"error": normErr.Error()})
			return
		}
		portalHost = normalized
	}
	var content []byte
	sourceType := ""
	sourceURL := ""
	switch {
	case strings.TrimSpace(input.Content) != "":
		content = []byte(input.Content)
		sourceType = "file"
	default:
		rawURL := strings.TrimSpace(input.URL)
		if rawURL == "" {
			if portalHost == "" {
				writeJSON(writer, http.StatusBadRequest, map[string]string{"error": "请先填写校园网登录页地址"})
				return
			}
			derived, deriveErr := mihomo.CloudProfileURL(portalHost)
			if deriveErr != nil {
				writeJSON(writer, http.StatusBadRequest, map[string]string{"error": deriveErr.Error()})
				return
			}
			rawURL = derived
		}
		parsed, parseErr := url.Parse(rawURL)
		if parseErr != nil || parsed.Host == "" || (parsed.Scheme != "http" && parsed.Scheme != "https") {
			writeJSON(writer, http.StatusBadRequest, map[string]string{"error": "入口地址必须是 http(s) URL"})
			return
		}
		// 先拉取后落盘：失败的刷新绝不能覆盖上一份可用快照（服务端维护
		// 中/网络抖动时，已缓存配置仍要能启动）。
		fetched, fetchErr := app.FetchCloudProfile(request.Context(), parsed.String())
		if fetchErr != nil {
			writeJSON(writer, http.StatusBadGateway, map[string]string{"error": fetchErr.Error(), "code": app.CloudErrorCode(fetchErr)})
			return
		}
		content = fetched
		sourceType = "url"
		// 派生出的地址不落盘：需要时由门户地址重新派生即可，settings.json
		// 里少一处完整入口，就少一处被顺手贴出去的地方。只有用户显式
		// 指定了自定义地址时才记录。
		if strings.TrimSpace(input.URL) != "" {
			sourceURL = parsed.String()
		}
	}
	// Tolerate a UTF-8 BOM pasted from Windows editors.
	content = bytes.TrimPrefix(content, []byte("\xEF\xBB\xBF"))
	profile, parseErr := mihomo.ParseCloudProfile(content)
	if parseErr != nil {
		writeJSON(writer, http.StatusBadRequest, map[string]string{"error": parseErr.Error()})
		return
	}
	if stored.ChainEnabled {
		writeJSON(writer, http.StatusConflict, map[string]string{"error": "链式代理已启用，两种模式改的是同一个出口，请先关闭链式代理"})
		return
	}
	if err := os.MkdirAll(filepath.Dir(h.cloudProfilePath()), 0o700); err != nil {
		writeJSON(writer, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	if err := os.WriteFile(h.cloudProfilePath(), content, 0o600); err != nil {
		writeJSON(writer, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	stored.CloudEnabled = true
	if portalHost != "" {
		stored.PortalHost = portalHost
	}
	if sourceURL != "" {
		stored.CloudSourceURL = sourceURL
	}
	stored.CloudUpdatedAt = time.Now().Format(time.RFC3339)
	if err := h.saveSettings(stored); err != nil {
		writeJSON(writer, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	names := make([]string, 0, len(profile.Nodes))
	for _, node := range profile.Nodes {
		names = append(names, node.Name)
	}
	writeJSON(writer, http.StatusOK, map[string]any{
		"ok":         true,
		"count":      len(profile.Nodes),
		"names":      names,
		"ignored":    profile.Ignored,
		"sourceType": sourceType,
		"sourceUrl":  sourceURL,
		"updatedAt":  stored.CloudUpdatedAt,
	})
}

func (h *helper) cloudClear(writer http.ResponseWriter) {
	if err := os.Remove(h.cloudProfilePath()); err != nil && !errors.Is(err, os.ErrNotExist) {
		writeJSON(writer, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	stored, loadErr := h.loadSettings()
	if loadErr != nil {
		stored = defaultSettings()
	}
	stored.CloudEnabled = false
	stored.CloudSourceURL = ""
	stored.CloudUpdatedAt = ""
	if err := h.saveSettings(stored); err != nil {
		writeJSON(writer, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(writer, http.StatusOK, map[string]bool{"ok": true})
}

// maskCloudEntry 只保留子域名前 4 位用于界面回显：完整入口不该出现在
// 能被截图/贴群的地方。
func maskCloudEntry(rawURL string) string {
	if strings.HasPrefix(rawURL, publisher.ProfilesURL) {
		return publisher.Repository + "/profiles/…"
	}
	parsed, err := url.Parse(rawURL)
	if err != nil || parsed.Host == "" {
		return ""
	}
	labels := strings.SplitN(parsed.Host, ".", 2)
	if len(labels) != 2 {
		return ""
	}
	slug := labels[0]
	if len(slug) > 4 {
		slug = slug[:4]
	}
	return slug + "…" + labels[1] + parsed.Path
}
