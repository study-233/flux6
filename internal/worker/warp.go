package worker

import (
	"context"
	"encoding/json"
	"sync"

	"github.com/yourname/freev6/internal/app"
)

type WarpManager struct {
	registrar app.WarpRegistrar
	mu        sync.Mutex
}

func NewWarpManager(registrar app.WarpRegistrar) *WarpManager {
	return &WarpManager{registrar: registrar}
}

func WarpHandler(manager *WarpManager, next Handler) Handler {
	return func(ctx context.Context, method string, params json.RawMessage) (any, error) {
		if method != "warp.register" {
			return next(ctx, method, params)
		}
		var input struct {
			Name string `json:"name"`
		}
		if err := decodeObject(params, &input); err != nil {
			return nil, &RPCError{InvalidParams, "invalid registration parameters"}
		}
		name, err := app.NormalizeWarpDeviceName(input.Name)
		if err != nil {
			return nil, &RPCError{InvalidParams, err.Error()}
		}
		if !manager.mu.TryLock() {
			return nil, &RPCError{Busy, "WARP registration already in progress"}
		}
		defer manager.mu.Unlock()
		result, err := app.RegisterWarp(ctx, manager.registrar, name, func(phase string) {
			ReportProgress(ctx, Progress{Phase: phase, Total: -1})
		})
		if err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			// Third-party error payloads and registrar implementations are never
			// trusted to provide credential-free text for the protocol/UI.
			return nil, &RPCError{RegistrationError, "WARP registration failed; check network or retry later"}
		}
		return result, nil
	}
}
