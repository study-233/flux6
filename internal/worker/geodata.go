package worker

import (
	"context"
	"encoding/json"
	"sync"

	"github.com/yourname/freev6/internal/mihomo"
)

type GeodataManager struct {
	resources, cache string
	mu               sync.Mutex
}

func NewGeodataManager(resources, cache string) *GeodataManager {
	return &GeodataManager{resources: resources, cache: cache}
}

func GeodataHandler(manager *GeodataManager, next Handler) Handler {
	return func(ctx context.Context, method string, params json.RawMessage) (any, error) {
		if method != "geodata.status" && method != "geodata.prepare" {
			return next(ctx, method, params)
		}
		if len(params) > 0 {
			if err := decodeObject(params, &struct{}{}); err != nil {
				return nil, &RPCError{InvalidParams, "geodata methods accept no paths, URLs or digests"}
			}
		}
		if !manager.mu.TryLock() {
			return nil, &RPCError{Busy, "geodata preparation already in progress"}
		}
		defer manager.mu.Unlock()
		var result mihomo.GeodataPackage
		var err error
		if method == "geodata.status" {
			result, err = mihomo.InspectGeodataPackage(ctx, manager.cache)
		} else {
			result, err = mihomo.PrepareGeodataPackage(ctx, manager.resources, manager.cache, func(p mihomo.GeodataProgress) {
				ReportProgress(ctx, Progress{Phase: p.Phase, Received: p.Received, Total: p.Total, Attempt: p.Attempt, Attempts: p.Attempts, Asset: p.Asset})
			})
		}
		if err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			// File-system errors may contain private user paths. Keep the boundary generic.
			return nil, &RPCError{ResourceError, "规则数据准备未完成，请检查网络与缓存目录权限后重试。"}
		}
		return result, nil
	}
}
