package worker

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/yourname/freev6/internal/app"
	"github.com/yourname/freev6/internal/mihomo"
	"gopkg.in/yaml.v3"
)

const maxChainPayload = 320 * 1024

type ChainSummary struct {
	Source  string   `json:"source"`
	Enabled bool     `json:"enabled"`
	Names   []string `json:"names"`
}
type chainPayload struct {
	Proxies []json.RawMessage `json:"proxies"`
	URL     string            `json:"url,omitempty"`
}
type chainCandidate struct {
	token    string
	revision uint64
	expiry   time.Time
	summary  *ChainSummary
	sealed   []byte
}
type chainPreview struct {
	Token string            `json:"token"`
	Nodes []json.RawMessage `json:"nodes"`
}

func (s SettingsSnapshot) validChain() bool {
	if s.Chain == nil {
		return len(s.sealedChain) == 0
	}
	c := s.Chain
	return (c.Source == "file" || c.Source == "url") && validProfile(c.Names, s.sealedChain, 64)
}

func validProfile(names []string, sealed []byte, maximum int) bool {
	if len(names) == 0 || len(names) > maximum || len(sealed) < 28 || len(sealed) > maxChainPayload+28 {
		return false
	}
	seen := make(map[string]bool, len(names))
	for _, name := range names {
		if name == "" || len(name) > 128 || seen[name] || strings.ContainsFunc(name, unicode.IsControl) {
			return false
		}
		seen[name] = true
	}
	return true
}

func chainCipher(key []byte) (cipher.AEAD, error) {
	if len(key) != 32 {
		return nil, errors.New("invalid chain key")
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCMWithRandomNonce(block)
}
func (s SettingsSnapshot) openChain(key []byte) (chainPayload, error) {
	if s.Chain == nil {
		return chainPayload{}, errors.New("missing chain profile")
	}
	return openProfile(key, s.sealedChain, "dev.freev6.chain.v1", s.Chain.Source, s.Chain.Names)
}

func openProfile(key, sealed []byte, binding, source string, expected []string) (chainPayload, error) {
	var value chainPayload
	box, err := chainCipher(key)
	if err != nil {
		return value, errors.New("missing chain profile or key")
	}
	plain, err := box.Open(nil, nil, sealed, []byte(binding))
	if err != nil || decodeObject(plain, &value) != nil || (value.URL != "") != (source == "url") {
		return chainPayload{}, errors.New("invalid saved chain profile")
	}
	names := make([]string, len(value.Proxies))
	for i, node := range value.Proxies {
		var n struct{ Name string }
		if json.Unmarshal(node, &n) != nil {
			return chainPayload{}, errors.New("invalid chain node")
		}
		names[i] = n.Name
	}
	if !slices.Equal(names, expected) {
		return chainPayload{}, errors.New("chain summary mismatch")
	}
	return value, nil
}

// Parser output is reused for preview and rendering. The source document's
// headers, rules and provider URLs never enter the encrypted snapshot.
func normalizedChain(content []byte) (chainPayload, []string, error) {
	nodes, err := mihomo.ParseChainProxies(bytes.TrimPrefix(content, []byte{0xef, 0xbb, 0xbf}))
	if err != nil {
		return chainPayload{}, nil, errors.New("文件需要包含有效的 Clash/mihomo proxies 列表，节点名称须唯一")
	}
	if len(nodes) > 64 {
		return chainPayload{}, nil, errors.New("当前 Mac 版本每组最多支持 64 个节点")
	}
	return normalizedNodes(nodes)
}

func normalizedNodes(nodes []mihomo.ChainProxy) (chainPayload, []string, error) {
	value := chainPayload{}
	var names []string
	for _, node := range nodes {
		var entry []map[string]any
		if err := yaml.Unmarshal([]byte(node.YAML), &entry); err != nil || len(entry) != 1 {
			return chainPayload{}, nil, errors.New("节点数据无效")
		}
		fields := entry[0]
		kind, ok := fields["type"].(string)
		if !ok {
			return chainPayload{}, nil, errors.New("节点类型无效")
		}
		fields["name"] = node.Name
		fields["type"] = strings.ToLower(strings.TrimSpace(kind))
		data, err := json.Marshal(fields)
		if err != nil {
			return chainPayload{}, nil, errors.New("节点字段类型无效")
		}
		value.Proxies = append(value.Proxies, data)
		names = append(names, node.Name)
	}
	return value, names, nil
}

func readChainFile(path string) ([]byte, error) {
	if !filepath.IsAbs(path) || len(path) > 4096 {
		return nil, errors.New("请选择本地的 YAML 文件")
	}
	f, err := os.OpenFile(path, os.O_RDONLY|importFileFlags, 0)
	if err != nil {
		return nil, errors.New("无法打开所选文件")
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > app.MaxSubscriptionBytes {
		return nil, errors.New("请选择 2 MiB 以内的普通文件")
	}
	data, err := io.ReadAll(io.LimitReader(f, app.MaxSubscriptionBytes+1))
	if err != nil || len(data) > app.MaxSubscriptionBytes {
		return nil, errors.New("无法完整读取文件或内容超过 2 MiB")
	}
	return data, nil
}

type chainManager struct {
	settings  *SettingsStore
	mu        sync.Mutex
	candidate *chainCandidate
}

func (m *chainManager) preview(ctx context.Context, params json.RawMessage) (any, error) {
	var input struct {
		Revision *uint64 `json:"expectedRevision"`
		Key      []byte  `json:"key"`
		File     *string `json:"file"`
		URL      *string `json:"url"`
		Refresh  *bool   `json:"refresh"`
	}
	if len(params) > 16*1024 || decodeObject(params, &input) != nil || input.Revision == nil || len(input.Key) != 32 {
		return nil, &RPCError{InvalidParams, "导入参数无效"}
	}
	current, err := m.settings.Get()
	if err != nil {
		return nil, &RPCError{StorageError, "无法读取设置"}
	}
	if *input.Revision != current.Revision {
		return nil, &RPCError{Conflict, "设置已改变"}
	}
	if current.Cloud != nil && current.Cloud.Enabled {
		return nil, &RPCError{InvalidParams, "请先停用备用配置，再导入链式代理"}
	}
	var content []byte
	var source, rawURL string
	switch {
	case input.File != nil && input.URL == nil && input.Refresh == nil:
		source = "file"
		content, err = readChainFile(*input.File)
	case input.File == nil && input.URL != nil && input.Refresh == nil:
		source = "url"
		rawURL = strings.TrimSpace(*input.URL)
	case input.File == nil && input.URL == nil && input.Refresh != nil && *input.Refresh:
		old, openErr := current.openChain(input.Key)
		if openErr != nil || old.URL == "" {
			return nil, &RPCError{InvalidParams, "无法读取已有订阅地址，请重新导入"}
		}
		source = "url"
		rawURL = old.URL
	default:
		return nil, &RPCError{InvalidParams, "请选择一个导入来源"}
	}
	if source == "url" {
		if rawURL == "" || len(rawURL) > 4096 {
			return nil, &RPCError{InvalidParams, "订阅地址无效"}
		}
		content, err = app.FetchSubscription(ctx, rawURL)
		if err != nil {
			return nil, &RPCError{InvalidParams, "订阅下载失败，请检查 http(s) 地址、网络及 2 MiB 大小限制"}
		}
	}
	if err != nil {
		return nil, &RPCError{InvalidParams, err.Error()}
	}
	payload, names, err := normalizedChain(content)
	if err != nil {
		return nil, &RPCError{InvalidParams, err.Error()}
	}
	payload.URL = rawURL
	plain, err := json.Marshal(payload)
	if err != nil || len(plain) > maxChainPayload {
		return nil, &RPCError{InvalidParams, "选用节点的配置内容过大"}
	}
	box, err := chainCipher(input.Key)
	if err != nil {
		return nil, err
	}
	var nonce [16]byte
	if _, err = rand.Read(nonce[:]); err != nil {
		return nil, err
	}
	token := hex.EncodeToString(nonce[:])
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	m.candidate = &chainCandidate{
		token: token, revision: current.Revision, expiry: time.Now().Add(2 * time.Minute),
		summary: &ChainSummary{Source: source, Enabled: true, Names: names},
		sealed:  box.Seal(nil, nil, plain, []byte("dev.freev6.chain.v1")),
	}
	return chainPreview{Token: token, Nodes: payload.Proxies}, nil
}

func (m *chainManager) apply(ctx context.Context, method string, params json.RawMessage) (any, error) {
	var input struct {
		Revision *uint64 `json:"expectedRevision"`
		Token    *string `json:"token"`
		Enabled  *bool   `json:"enabled"`
	}
	if len(params) > 512 || decodeObject(params, &input) != nil || input.Revision == nil {
		return nil, &RPCError{InvalidParams, "链式设置参数无效"}
	}
	s := m.settings
	s.mu.Lock()
	defer s.mu.Unlock()
	current, err := s.read()
	if err != nil {
		return nil, &RPCError{StorageError, "无法读取设置"}
	}
	if current.Revision != *input.Revision {
		return nil, &RPCError{Conflict, "设置已改变"}
	}
	switch method {
	case "chain.commit":
		c := m.candidate
		if input.Token == nil || input.Enabled != nil || c == nil || c.revision != current.Revision || c.token != *input.Token || time.Now().After(c.expiry) {
			return nil, &RPCError{Conflict, "导入已过期，请重新选择"}
		}
		current.Chain, current.sealedChain = c.summary, c.sealed
	case "chain.enable":
		if input.Enabled == nil || input.Token != nil || current.Chain == nil {
			return nil, &RPCError{InvalidParams, "请先导入链式配置"}
		}
		current.Chain.Enabled = *input.Enabled
	case "chain.clear":
		if input.Enabled != nil || input.Token != nil {
			return nil, &RPCError{InvalidParams, "清除参数无效"}
		}
		current.Chain, current.sealedChain = nil, nil
	}
	if current.Chain != nil && current.Chain.Enabled && current.Cloud != nil && current.Cloud.Enabled {
		return nil, &RPCError{InvalidParams, "请先停用备用配置，再启用链式代理"}
	}
	if !current.validChain() {
		return nil, &RPCError{InvalidParams, "链式信息无效"}
	}
	saved, err := s.commit(ctx, current)
	if err == nil {
		m.candidate = nil
	}
	return saved, err
}

func ChainHandler(settings *SettingsStore, next Handler) Handler {
	m := &chainManager{settings: settings}
	return func(ctx context.Context, method string, params json.RawMessage) (any, error) {
		switch method {
		case "chain.preview", "chain.commit", "chain.enable", "chain.clear":
		default:
			return next(ctx, method, params)
		}
		if !m.mu.TryLock() {
			return nil, &RPCError{Busy, "链式操作正在进行"}
		}
		defer m.mu.Unlock()
		if method == "chain.preview" {
			return m.preview(ctx, params)
		}
		return m.apply(ctx, method, params)
	}
}
