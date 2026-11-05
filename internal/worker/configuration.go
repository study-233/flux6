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
	settings       *SettingsStore
	mu             sync.Mutex
	inspectRuntime func(context.Context) (mihomo.RuntimePackage, error)
	inspectGeodata func(context.Context) (mihomo.GeodataPackage, error)
}

func NewConfigurationManager(settings *SettingsStore, cache string) *ConfigurationManager {
	return &ConfigurationManager{settings: settings,
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

func ConfigurationHandler(manager *ConfigurationManager, next Handler) Handler {
	return func(ctx context.Context, method string, params json.RawMessage) (any, error) {
		if method != "configuration.prepare" {
			return next(ctx, method, params)
		}
		var input struct {
			Source             string                 `json:"source"`
			SettingsRevision   *uint64                `json:"settingsRevision"`
			CredentialRevision string                 `json:"credentialRevision"`
			ChainKey           []byte                 `json:"chainKey,omitempty"`
			Tunnel             warp.TunnelCredentials `json:"tunnel"`
		}
		if len(params) > 32*1024 || decodeObject(params, &input) != nil || input.Source != "warp" || input.SettingsRevision == nil || !validRevisionUUID(input.CredentialRevision) || warp.ValidateTunnelCredentials(input.Tunnel) != nil {
			return nil, &RPCError{InvalidParams, "invalid configuration parameters"}
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
		var chain []mihomo.ChainProxy
		if snapshot.Chain != nil && snapshot.Chain.Enabled {
			stored, err := snapshot.openChain(input.ChainKey)
			if err != nil {
				return nil, &RPCError{ConfigurationError, "无法打开已启用的链式配置"}
			}
			document, err := json.Marshal(struct {
				Proxies []json.RawMessage `json:"proxies"`
			}{stored.Proxies})
			if err != nil {
				return nil, &RPCError{ConfigurationError, "链式节点无效"}
			}
			chain, err = mihomo.ParseChainProxies(document)
			if err != nil || len(chain) == 0 {
				return nil, &RPCError{ConfigurationError, "已启用的链式节点无效"}
			}
		} else if len(input.ChainKey) != 0 {
			return nil, &RPCError{Conflict, "链式设置已改变"}
		}
		configuration, err := app.PrepareWarpWithChain(snapshot.Settings, input.Tunnel, chain)
		if err != nil {
			return nil, &RPCError{ConfigurationError, "cannot prepare connection configuration"}
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
		return PreparedConfiguration{1, snapshot.Revision, input.CredentialRevision, core.ResourceID, geodata.ResourceID, configuration}, nil
	}
}

func preparationResourceError(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	return &RPCError{ResourceError, "请先准备并校验核心安装包与规则数据。"}
}
