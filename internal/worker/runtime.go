package worker

import (
	"context"
	"encoding/json"
	"runtime"
	"sync"

	"github.com/yourname/freev6/internal/mihomo"
)

type RuntimeManager struct {
	cacheDir string
	mu       sync.Mutex
}

func NewRuntimeManager(cacheDir string) *RuntimeManager { return &RuntimeManager{cacheDir: cacheDir} }

func BusinessHandler(settings *SettingsStore, resources *RuntimeManager) Handler {
	settingsHandler := SettingsHandler(settings)
	return func(ctx context.Context, method string, params json.RawMessage) (any, error) {
		if method != "runtime.status" && method != "runtime.download" {
			return settingsHandler(ctx, method, params)
		}
		if len(params) > 0 {
			if err := decodeObject(params, &struct{}{}); err != nil {
				return nil, &RPCError{InvalidParams, "runtime methods accept no paths, URLs or targets"}
			}
		}
		if !resources.mu.TryLock() {
			return nil, &RPCError{Busy, "runtime preparation already in progress"}
		}
		defer resources.mu.Unlock()
		var result mihomo.RuntimePackage
		var err error
		if method == "runtime.status" {
			result, err = mihomo.InspectRuntimePackage(ctx, resources.cacheDir, runtime.GOOS, runtime.GOARCH)
		} else {
			result, err = mihomo.PrepareRuntimePackage(ctx, resources.cacheDir, runtime.GOOS, runtime.GOARCH, func(p mihomo.RuntimeProgress) {
				ReportProgress(ctx, Progress{Phase: p.Phase, Received: p.Received, Total: p.Total, Attempt: p.Attempt, Attempts: p.Attempts})
			})
		}
		if err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			return nil, &RPCError{ResourceError, err.Error()}
		}
		return result, nil
	}
}
