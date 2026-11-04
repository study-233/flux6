package worker

import (
	"context"
	"encoding/json"
	"fmt"
	"sync/atomic"
	"testing"

	"github.com/yourname/freev6/internal/warp"
)

type workerRegistrar func(context.Context, string, func(string)) (warp.Device, error)

func (f workerRegistrar) RegisterWithProgress(c context.Context, n string, p func(string)) (warp.Device, error) {
	return f(c, n, p)
}

func TestWarpHandlerRestrictsParametersRedactsErrorsAndSerializesRegistration(t *testing.T) {
	var calls atomic.Int32
	started, release := make(chan struct{}), make(chan struct{})
	manager := NewWarpManager(workerRegistrar(func(context.Context, string, func(string)) (warp.Device, error) {
		calls.Add(1)
		close(started)
		<-release
		return warp.Device{}, fmt.Errorf("upstream token=secret")
	}))
	handler := WarpHandler(manager, func(context.Context, string, json.RawMessage) (any, error) { return nil, nil })
	for _, params := range []string{`{"name":"test","url":"https://evil.example"}`, `{"name":"bad\nname"}`, `null`} {
		_, err := handler(context.Background(), "warp.register", json.RawMessage(params))
		if rpc, ok := err.(*RPCError); !ok || rpc.Code != InvalidParams {
			t.Fatalf("accepted unsafe params: %v", err)
		}
	}
	if calls.Load() != 0 {
		t.Fatal("invalid params reached registrar")
	}
	done := make(chan error, 1)
	go func() {
		_, err := handler(context.Background(), "warp.register", json.RawMessage(`{"name":"test"}`))
		done <- err
	}()
	<-started
	_, err := handler(context.Background(), "warp.register", json.RawMessage(`{"name":"test"}`))
	if rpc, ok := err.(*RPCError); !ok || rpc.Code != Busy {
		t.Fatalf("duplicate registration accepted: %v", err)
	}
	close(release)
	err = <-done
	if rpc, ok := err.(*RPCError); !ok || rpc.Code != RegistrationError || rpc.Message != "WARP registration failed; check network or retry later" {
		t.Fatalf("registration error was not redacted")
	}
}
