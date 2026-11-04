package worker

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
)

func TestGeodataHandlerRestrictsInputsAndSerializes(t *testing.T) {
	manager := NewGeodataManager(t.TempDir(), t.TempDir())
	forwarded := false
	handler := GeodataHandler(manager, func(context.Context, string, json.RawMessage) (any, error) { forwarded = true; return nil, nil })
	for _, input := range []string{`{"path":"/tmp/elsewhere"}`, `{"url":"https://example.com"}`, `{"sha256":"custom"}`, `null`, `[]`} {
		_, err := handler(context.Background(), "geodata.prepare", json.RawMessage(input))
		var rpc *RPCError
		if !errors.As(err, &rpc) || rpc.Code != InvalidParams {
			t.Fatal(input, err)
		}
	}
	manager.mu.Lock()
	_, err := handler(context.Background(), "geodata.status", nil)
	manager.mu.Unlock()
	var rpc *RPCError
	if !errors.As(err, &rpc) || rpc.Code != Busy {
		t.Fatal(err)
	}
	result, err := handler(context.Background(), "geodata.status", json.RawMessage(`{}`))
	if err != nil || result == nil {
		t.Fatal(result, err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = handler(ctx, "geodata.prepare", nil)
	if !errors.Is(err, context.Canceled) {
		t.Fatal(err)
	}
	handler(context.Background(), "other.method", nil)
	if !forwarded {
		t.Fatal("method not forwarded")
	}
}
