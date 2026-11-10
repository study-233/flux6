// Package notice reads the maintainer's public bulletin and its backup-profile switch.
package notice

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
	"time"
)

const (
	MaxBytes       = 256 << 10 // 公告是纯文本，256 KiB 足够且挡住恶意大包
	MaxItems       = 20
	MaxTitle       = 200
	MaxBody        = 4000
	noticeLinkText = 40
	// 离线缓存最多用 7 天：更旧的公告宁可空着，也不要展示早已失效的通知。
	CacheMaxAge = 7 * 24 * time.Hour
)

// Item 单条公告。JSON 字段同时用于对外响应，字段裁剪在 sanitize 里做。
type Item struct {
	ID        string `json:"id"`
	Title     string `json:"title"`
	Body      string `json:"body,omitempty"`
	Level     string `json:"level"`
	Published string `json:"published"`
	Expires   string `json:"expires,omitempty"`
	Link      string `json:"link,omitempty"`
	LinkText  string `json:"linkText,omitempty"`
}

// Payload 是 notice.json 顶层结构（未知字段一律忽略，便于以后扩展）。
type Payload struct {
	Updated string `json:"updated"`
	Items   []Item `json:"items"`
	// CloudProfile 是备用配置的总开关：只有显式 true 才开放。
	// 用指针区分「没写」与「写了 false」——两者都锁定，但排障时要能看出
	// 是维护者主动关闭还是公告文件压根没有这个字段。
	CloudProfile *bool `json:"cloudProfile,omitempty"`
}

// CloudAllowed 判定公告里的开关。缺省/缺失一律视为关闭（fail-closed）：
// 拿不到维护者的明确许可，就不该允许使用需要服务端资源的功能。
func CloudAllowed(flag *bool) bool {
	return flag != nil && *flag
}

// Cache 按发行仓库隔离保存，只在拉取全线失败时回退使用。
type Cache struct {
	FetchedAt    time.Time `json:"fetchedAt"`
	Updated      string    `json:"updated"`
	Items        []Item    `json:"items"`
	CloudProfile *bool     `json:"cloudProfile,omitempty"`
}

var noticeLevels = map[string]bool{"info": true, "warning": true, "critical": true}

// Parse 解析并消毒公告文件：坏条目逐条丢弃（一条写错不该让
// 整个公告板变空），过期条目直接过滤，长度一律按「字符」截断。
func Parse(data []byte, now time.Time) (Payload, error) {
	var payload Payload
	// 兼容维护者直接写成顶层数组的写法（容易手滑，但不值得为此丢公告）。
	trimmed := bytes.TrimLeft(data, " \t\r\n")
	if len(trimmed) > 0 && trimmed[0] == '[' {
		if err := json.Unmarshal(trimmed, &payload.Items); err != nil {
			return Payload{}, fmt.Errorf("invalid notice.json: %w", err)
		}
	} else if err := json.Unmarshal(trimmed, &payload); err != nil {
		return Payload{}, fmt.Errorf("invalid notice.json: %w", err)
	}
	payload.Updated = strings.TrimSpace(payload.Updated)

	items := make([]Item, 0, len(payload.Items))
	seen := make(map[string]bool, len(payload.Items))
	for _, candidate := range payload.Items {
		item, ok := sanitizeNotice(candidate, now)
		if !ok || seen[item.ID] {
			continue
		}
		seen[item.ID] = true
		items = append(items, item)
		if len(items) == MaxItems {
			break
		}
	}
	payload.Items = items
	return payload, nil
}

// sanitizeNotice 校验单条公告；返回 false 表示丢弃。
func sanitizeNotice(item Item, now time.Time) (Item, bool) {
	item.ID = strings.TrimSpace(item.ID)
	item.Title = strings.TrimSpace(item.Title)
	item.Body = strings.TrimSpace(item.Body)
	if item.ID == "" || item.Title == "" || len(item.ID) > 120 {
		return item, false
	}
	// 发布时间是必填项：没有时间轴的公告无法判断新旧，也没有意义。
	published, err := time.Parse(time.RFC3339, strings.TrimSpace(item.Published))
	if err != nil {
		return item, false
	}
	item.Published = published.Format(time.RFC3339)

	if expires, err := time.Parse(time.RFC3339, strings.TrimSpace(item.Expires)); err == nil {
		if !now.Before(expires) {
			return item, false // 已过期：不再下发
		}
		item.Expires = expires.Format(time.RFC3339)
	} else {
		item.Expires = "" // 写错的时间按「永不过期」处理，别丢整条
	}

	item.Level = strings.ToLower(strings.TrimSpace(item.Level))
	if !noticeLevels[item.Level] {
		item.Level = "info"
	}
	item.Title = truncateRunes(item.Title, MaxTitle)
	item.Body = truncateRunes(item.Body, MaxBody)

	// link 只接受 https：这条链路最终会交给系统浏览器打开，
	// javascript:/file: 之类的 scheme 一律丢弃（不因此丢整条公告）。
	item.Link = validNoticeLink(item.Link)
	if item.Link == "" {
		item.LinkText = ""
	} else {
		item.LinkText = truncateRunes(strings.TrimSpace(item.LinkText), noticeLinkText)
		if item.LinkText == "" {
			item.LinkText = "查看详情"
		}
	}
	return item, true
}

// validNoticeLink 返回规范化后的 https 链接，不合规时返回空串。
func validNoticeLink(raw string) string {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || parsed.Scheme != "https" || parsed.Hostname() == "" {
		return ""
	}
	return parsed.String()
}

// truncateRunes 按字符（而非字节）截断，避免把中文切出半个字。
func truncateRunes(value string, limit int) string {
	runes := []rune(value)
	if len(runes) <= limit {
		return value
	}
	return string(runes[:limit]) + "…"
}

// LiveItems 丢掉已过期或时间戳坏掉的条目（缓存同样适用）。
func LiveItems(items []Item, now time.Time) []Item {
	live := make([]Item, 0, len(items))
	for _, item := range items {
		if item.Expires != "" {
			if expires, err := time.Parse(time.RFC3339, item.Expires); err == nil && !now.Before(expires) {
				continue
			}
		}
		live = append(live, item)
		if len(live) == MaxItems {
			break
		}
	}
	return live
}

func (c Cache) Fresh(now time.Time) bool {
	age := now.Sub(c.FetchedAt)
	return !c.FetchedAt.IsZero() && age >= 0 && age <= CacheMaxAge
}
