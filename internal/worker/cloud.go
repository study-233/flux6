package worker

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/yourname/freev6/internal/app"
	"github.com/yourname/freev6/internal/mihomo"
)

type CloudSummary struct {
	ChainSummary
	ID        string   `json:"id"`
	UpdatedAt string   `json:"updatedAt"`
	Ignored   []string `json:"ignored"`
}

func (s SettingsSnapshot) validCloud() bool {
	if s.PortalHost != "" {
		host, err := mihomo.NormalizePortalHost(s.PortalHost)
		if err != nil || host != s.PortalHost || len(host) > 253 {
			return false
		}
	}
	c := s.Cloud
	if c == nil {
		return len(s.sealedCloud) == 0
	}
	if c.Enabled && s.Chain != nil && s.Chain.Enabled {
		return false
	}
	_, err := time.Parse(time.RFC3339, c.UpdatedAt)
	return err == nil && validRevisionUUID(c.ID) && (c.Source == "file" || c.Source == "url" || c.Source == "portal") &&
		validProfile(c.Names, s.sealedCloud, mihomo.CloudMaxNodes)
}

func (s SettingsSnapshot) openCloud(key []byte) (chainPayload, error) {
	if s.Cloud == nil {
		return chainPayload{}, errors.New("missing campus profile")
	}
	return openProfile(key, s.sealedCloud, "dev.freev6.cloud.v1/"+s.Cloud.ID, s.Cloud.Source, s.Cloud.Names)
}

type cloudDraft struct {
	token    string
	expires  time.Time
	revision uint64
	summary  *CloudSummary
	portal   string
	sealed   []byte
}

type cloudManager struct {
	store  *SettingsStore
	notice *NoticeManager
	fetch  func(context.Context, string) ([]byte, error)
	mu     sync.Mutex
	draft  *cloudDraft
}

type cloudInput struct {
	Revision *uint64 `json:"expectedRevision"`
	Key      []byte  `json:"key"`
	Source   string  `json:"source"`
	Value    string  `json:"value,omitempty"`
}

type cloudLocation struct {
	source    string
	portal    string
	customURL string
}

func (s SettingsSnapshot) cloudLocation(in cloudInput) (cloudLocation, error) {
	location := cloudLocation{source: in.Source, portal: s.PortalHost}
	value := strings.TrimSpace(in.Value)
	switch in.Source {
	case "file":
		// The absolute file path is used once and never saved.
	case "portal":
		if value != "" {
			host, err := mihomo.NormalizePortalHost(value)
			if err != nil || len(host) > 253 {
				return cloudLocation{}, errors.New("校园登录页地址无效")
			}
			location.portal = host
		}
	case "url":
		location.customURL = value
	case "refresh":
		if s.Cloud == nil || value != "" || s.Cloud.Source == "file" {
			return cloudLocation{}, errors.New("此配置没有可刷新的网络来源")
		}
		saved, err := s.openCloud(in.Key)
		if err != nil {
			return cloudLocation{}, errors.New("无法打开已保存的备用配置")
		}
		location.source, location.customURL = s.Cloud.Source, saved.URL
	default:
		return cloudLocation{}, errors.New("备用配置来源无效")
	}
	return location, nil
}

func (m *cloudManager) load(ctx context.Context, location cloudLocation, file string) ([]byte, error) {
	if location.source == "file" {
		return readChainFile(file)
	}
	address := location.customURL
	if location.source == "portal" {
		derived, err := mihomo.CloudProfileURL(location.portal)
		if err != nil {
			return nil, errors.New("请填写校园登录页地址")
		}
		address = derived
	}
	u, err := url.Parse(address)
	if err != nil || u.Hostname() == "" || (u.Scheme != "https" && u.Scheme != "http") || len(address) > 4096 {
		return nil, errors.New("备用配置地址必须是有效的 http(s) URL")
	}
	return m.fetch(ctx, address)
}

func (m *cloudManager) preview(ctx context.Context, params json.RawMessage) (any, error) {
	var in cloudInput
	if len(params) > 16*1024 || decodeObject(params, &in) != nil || in.Revision == nil || len(in.Key) != 32 {
		return nil, &RPCError{InvalidParams, "备用配置参数无效"}
	}
	if !m.notice.cached().CloudAllowed {
		return nil, cloudLocked()
	}
	current, err := m.store.Get()
	if err != nil {
		return nil, &RPCError{StorageError, "无法读取备用配置设置"}
	}
	if current.Revision != *in.Revision {
		return nil, &RPCError{Conflict, "设置已变化"}
	}
	if current.Chain != nil && current.Chain.Enabled {
		return nil, cloudChainConflict()
	}
	location, err := current.cloudLocation(in)
	if err != nil {
		return nil, &RPCError{InvalidParams, err.Error()}
	}
	content, err := m.load(ctx, location, in.Value)
	if err != nil {
		return nil, &RPCError{InvalidParams, err.Error()}
	}
	profile, err := mihomo.ParseCloudProfile(bytes.TrimPrefix(content, []byte{0xef, 0xbb, 0xbf}))
	if err != nil {
		return nil, &RPCError{InvalidParams, "备用配置需要 1 至 200 个有效且不重名的 Clash/mihomo 节点"}
	}
	payload, names, err := normalizedNodes(profile.Nodes)
	if err != nil {
		return nil, &RPCError{InvalidParams, err.Error()}
	}
	payload.URL = location.customURL
	plain, err := json.Marshal(payload)
	if err != nil || len(plain) > maxChainPayload {
		return nil, &RPCError{InvalidParams, "备用节点内容过大"}
	}
	box, err := chainCipher(in.Key)
	if err != nil {
		return nil, err
	}
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		return nil, err
	}
	id[6] = id[6]&15 | 64
	id[8] = id[8]&63 | 128
	version := fmt.Sprintf("%x-%x-%x-%x-%x", id[:4], id[4:6], id[6:8], id[8:10], id[10:])
	token := hex.EncodeToString(id[:])
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	m.draft = &cloudDraft{token: token, revision: current.Revision, expires: time.Now().Add(2 * time.Minute), portal: location.portal,
		summary: &CloudSummary{ChainSummary: ChainSummary{Source: location.source, Enabled: true, Names: names}, ID: version, UpdatedAt: time.Now().UTC().Format(time.RFC3339), Ignored: profile.Ignored},
		sealed:  box.Seal(nil, nil, plain, []byte("dev.freev6.cloud.v1/"+version))}
	return chainPreview{Token: token, Nodes: payload.Proxies}, nil
}

func cloudLocked() error {
	return &RPCError{InvalidParams, "备用配置当前未开放，请刷新维护者公告"}
}
func cloudChainConflict() error {
	return &RPCError{InvalidParams, "请先停用链式代理，再启用备用配置"}
}

func (m *cloudManager) apply(ctx context.Context, method string, params json.RawMessage) (any, error) {
	var in struct {
		Revision *uint64 `json:"expectedRevision"`
		Token    *string `json:"token"`
		Enabled  *bool   `json:"enabled"`
		Host     *string `json:"portalHost"`
	}
	if len(params) > 8192 || decodeObject(params, &in) != nil || in.Revision == nil {
		return nil, &RPCError{InvalidParams, "备用配置参数无效"}
	}
	s := m.store
	s.mu.Lock()
	defer s.mu.Unlock()
	current, err := s.read()
	if err != nil {
		return nil, &RPCError{StorageError, "无法读取设置"}
	}
	if current.Revision != *in.Revision {
		return nil, &RPCError{Conflict, "设置已变化"}
	}
	switch method {
	case "cloud.commit":
		d := m.draft
		if in.Enabled != nil || in.Host != nil || in.Token == nil || d == nil || *in.Token != d.token || current.Revision != d.revision || time.Now().After(d.expires) {
			return nil, &RPCError{Conflict, "导入已过期，请重新获取"}
		}
		current.Cloud, current.sealedCloud, current.PortalHost = d.summary, d.sealed, d.portal
	case "cloud.enable":
		if in.Enabled == nil || in.Token != nil || in.Host != nil || current.Cloud == nil {
			return nil, &RPCError{InvalidParams, "请先获取备用配置"}
		}
		current.Cloud.Enabled = *in.Enabled
	case "cloud.clear":
		if in.Enabled != nil || in.Token != nil || in.Host != nil {
			return nil, &RPCError{InvalidParams, "清除参数无效"}
		}
		current.Cloud, current.sealedCloud = nil, nil
	case "cloud.portal":
		if in.Host == nil || in.Token != nil || in.Enabled != nil {
			return nil, &RPCError{InvalidParams, "登录页地址无效"}
		}
		host := strings.TrimSpace(*in.Host)
		if host != "" {
			host, err = mihomo.NormalizePortalHost(host)
			if err != nil || len(host) > 253 {
				return nil, &RPCError{InvalidParams, "登录页地址无效"}
			}
		}
		current.PortalHost = host
	}
	if current.Cloud != nil && current.Cloud.Enabled {
		if current.Chain != nil && current.Chain.Enabled {
			return nil, cloudChainConflict()
		}
		if !m.notice.cached().CloudAllowed {
			return nil, cloudLocked()
		}
	}
	if !current.validCloud() {
		return nil, &RPCError{InvalidParams, "备用配置无效"}
	}
	saved, err := s.commit(ctx, current)
	if err == nil {
		m.draft = nil
	}
	return saved, err
}

func CloudHandler(store *SettingsStore, notice *NoticeManager, next Handler) Handler {
	m := &cloudManager{store: store, notice: notice, fetch: app.FetchCloudProfile}
	return func(ctx context.Context, method string, params json.RawMessage) (any, error) {
		switch method {
		case "cloud.preview", "cloud.commit", "cloud.enable", "cloud.clear", "cloud.portal":
		default:
			return next(ctx, method, params)
		}
		if !m.mu.TryLock() {
			return nil, &RPCError{Busy, "备用配置操作进行中"}
		}
		defer m.mu.Unlock()
		if method == "cloud.preview" {
			return m.preview(ctx, params)
		}
		return m.apply(ctx, method, params)
	}
}
