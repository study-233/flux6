package worker

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"runtime"
	"strings"
	"sync"

	"github.com/yourname/freev6/internal/app"
	"github.com/yourname/freev6/internal/mihomo"
	"github.com/yourname/freev6/internal/warp"
)

type ConfigurationManager struct {
	notices        *NoticeManager
	settings       *SettingsStore
	mu             sync.Mutex
	inspectRuntime func(context.Context) (mihomo.RuntimePackage, error)
	inspectGeodata func(context.Context) (mihomo.GeodataPackage, error)
}

func NewConfigurationManager(settings *SettingsStore, cache string, notices *NoticeManager) *ConfigurationManager {
	return &ConfigurationManager{settings: settings, notices: notices,
		inspectRuntime: func(ctx context.Context) (mihomo.RuntimePackage, error) {
			return mihomo.InspectRuntimePackage(ctx, cache, runtime.GOOS, runtime.GOARCH)
		},
		inspectGeodata: func(ctx context.Context) (mihomo.GeodataPackage, error) {
			return mihomo.InspectGeodataPackage(ctx, cache)
		},
	}
}

type PreparedConfiguration struct {
	SchemaVersion      int                       `json:"schemaVersion"`
	SettingsRevision   uint64                    `json:"settingsRevision"`
	CredentialRevision string                    `json:"credentialRevision"`
	RuntimeID          string                    `json:"runtimeId"`
	GeodataID          string                    `json:"geodataId"`
	Configuration      app.BusinessConfiguration `json:"configuration"`
}

func (PreparedConfiguration) String() string   { return "PreparedConfiguration(redacted)" }
func (PreparedConfiguration) GoString() string { return "PreparedConfiguration(redacted)" }

func validRevisionUUID(value string) bool {
	if len(value) != 36 || value[8] != '-' || value[13] != '-' || value[18] != '-' || value[23] != '-' {
		return false
	}
	bytes, err := hex.DecodeString(strings.ReplaceAll(value, "-", ""))
	return err == nil && len(bytes) == 16
}

type configurationInput struct {
	Source             string                  `json:"source"`
	SettingsRevision   *uint64                 `json:"settingsRevision"`
	CredentialRevision string                  `json:"credentialRevision"`
	ChainKey           []byte                  `json:"chainKey,omitempty"`
	ProfileKey         []byte                  `json:"profileKey,omitempty"`
	Tunnel             *warp.TunnelCredentials `json:"tunnel"`
}

func ConfigurationHandler(manager *ConfigurationManager, next Handler) Handler {
	return func(ctx context.Context, method string, params json.RawMessage) (any, error) {
		if method != "configuration.prepare" {
			return next(ctx, method, params)
		}
		var input configurationInput
		if len(params) > 32*1024 || decodeObject(params, &input) != nil || input.SettingsRevision == nil || !validRevisionUUID(input.CredentialRevision) {
			return nil, &RPCError{InvalidParams, "invalid configuration parameters"}
		}
		switch input.Source {
		case "warp":
			if input.Tunnel == nil || warp.ValidateTunnelCredentials(*input.Tunnel) != nil || input.ProfileKey != nil {
				return nil, &RPCError{InvalidParams, "invalid WARP configuration parameters"}
			}
		case "cloud":
			if input.Tunnel != nil || input.ChainKey != nil || len(input.ProfileKey) != 32 {
				return nil, &RPCError{InvalidParams, "备用配置只需要已保存的节点密钥"}
			}
		default:
			return nil, &RPCError{InvalidParams, "unknown configuration source"}
		}
		if !manager.mu.TryLock() {
			return nil, &RPCError{Busy, "configuration preparation already in progress"}
		}
		defer manager.mu.Unlock()
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		snapshot, err := manager.settings.Get()
		if err != nil {
			return nil, &RPCError{StorageError, "cannot load settings; original retained"}
		}
		if snapshot.Revision != *input.SettingsRevision {
			return nil, &RPCError{Conflict, "settings changed; reload before preparation"}
		}
		ReportProgress(ctx, Progress{Phase: "checking", Total: -1})
		core, err := manager.inspectRuntime(ctx)
		if err != nil || !core.Available {
			return nil, preparationResourceError(ctx)
		}
		geodata, err := manager.inspectGeodata(ctx)
		if err != nil || !geodata.Available {
			return nil, preparationResourceError(ctx)
		}
		ReportProgress(ctx, Progress{Phase: "rendering", Total: -1})
		configuration, err := manager.render(snapshot, input)
		if err != nil {
			return nil, err
		}
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		latest, err := manager.settings.Get()
		if err != nil {
			return nil, &RPCError{StorageError, "cannot recheck settings"}
		}
		if latest.Revision != snapshot.Revision {
			return nil, &RPCError{Conflict, "settings changed during preparation"}
		}
		if input.Source == "cloud" && !manager.notices.cached().CloudAllowed {
			return nil, cloudLocked()
		}
		return PreparedConfiguration{1, snapshot.Revision, input.CredentialRevision, core.ResourceID, geodata.ResourceID, configuration}, nil
	}
}

func (m *ConfigurationManager) render(s SettingsSnapshot, in configurationInput) (app.BusinessConfiguration, error) {
	var empty app.BusinessConfiguration
	if in.Source == "cloud" {
		if s.Cloud == nil || !s.Cloud.Enabled || !strings.EqualFold(s.Cloud.ID, in.CredentialRevision) {
			return empty, &RPCError{Conflict, "备用配置已变化"}
		}
		if !m.notices.cached().CloudAllowed {
			return empty, cloudLocked()
		}
		saved, err := s.openCloud(in.ProfileKey)
		if err != nil {
			return empty, &RPCError{ConfigurationError, "无法解密备用配置"}
		}
		document, err := saved.nodeDocument()
		if err != nil {
			return empty, err
		}
		profile, err := mihomo.ParseCloudProfile(document)
		if err != nil {
			return empty, &RPCError{ConfigurationError, "备用节点无效"}
		}
		result, err := app.PrepareCloudConfiguration(s.Settings, profile.Nodes)
		if err != nil {
			return empty, &RPCError{ConfigurationError, "无法生成备用连接配置"}
		}
		return result, nil
	}
	if s.Cloud != nil && s.Cloud.Enabled {
		return empty, &RPCError{Conflict, "当前已启用备用配置"}
	}
	var chain []mihomo.ChainProxy
	if s.Chain != nil && s.Chain.Enabled {
		saved, err := s.openChain(in.ChainKey)
		if err != nil {
			return empty, &RPCError{ConfigurationError, "无法打开已启用的链式配置"}
		}
		document, err := saved.nodeDocument()
		if err != nil {
			return empty, err
		}
		chain, err = mihomo.ParseChainProxies(document)
		if err != nil || len(chain) == 0 {
			return empty, &RPCError{ConfigurationError, "已启用的链式节点无效"}
		}
	} else if len(in.ChainKey) != 0 {
		return empty, &RPCError{Conflict, "链式设置已改变"}
	}
	result, err := app.PrepareWarpWithChain(s.Settings, *in.Tunnel, chain)
	if err != nil {
		return empty, &RPCError{ConfigurationError, "cannot prepare connection configuration"}
	}
	return result, nil
}

func (p chainPayload) nodeDocument() ([]byte, error) {
	data, err := json.Marshal(struct {
		Proxies []json.RawMessage `json:"proxies"`
	}{p.Proxies})
	if err != nil {
		return nil, &RPCError{ConfigurationError, "保存的节点配置无效"}
	}
	return data, nil
}

func preparationResourceError(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	return &RPCError{ResourceError, "请先准备并校验核心安装包与规则数据。"}
}
