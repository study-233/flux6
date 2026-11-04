package worker

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"io"
	"net"
	"testing"
	"time"
)

func testConnection(t *testing.T, handler Handler) (net.Conn, <-chan error) {
	t.Helper()
	client, server := net.Pipe()
	done := make(chan error, 1)
	go func() { done <- Serve(context.Background(), server, server, handler) }()
	client.SetDeadline(time.Now().Add(5 * time.Second))
	t.Cleanup(func() { client.Close() })
	return client, done
}

func request(t *testing.T, conn net.Conn, body string) map[string]json.RawMessage {
	t.Helper()
	if err := WriteFrame(conn, []byte(body)); err != nil {
		t.Fatal(err)
	}
	data, err := ReadFrame(conn)
	if err != nil {
		t.Fatal(err)
	}
	var response map[string]json.RawMessage
	if err := json.Unmarshal(data, &response); err != nil {
		t.Fatal(err)
	}
	return response
}

func expectCode(t *testing.T, response map[string]json.RawMessage, code int) {
	t.Helper()
	var failure RPCError
	if err := json.Unmarshal(response["error"], &failure); err != nil || failure.Code != code {
		t.Fatalf("error %d: %s", code, response)
	}
}

func TestProtocolHandshakeDispatchAndEOF(t *testing.T) {
	store, _ := testStore(t)
	client, done := testConnection(t, SettingsHandler(store))
	expectCode(t, request(t, client, `{"jsonrpc":"2.0","id":"1","method":"settings.get"}`), NotInitialized)
	expectCode(t, request(t, client, `{"jsonrpc":"2.0","id":"2","method":"initialize","params":{"protocolVersion":99}}`), VersionMismatch)
	if result := request(t, client, `{"jsonrpc":"2.0","id":"3","method":"initialize","params":{"protocolVersion":1}}`); result["result"] == nil {
		t.Fatal(result)
	}
	expectCode(t, request(t, client, `{`), ParseError)
	expectCode(t, request(t, client, `{"jsonrpc":"2.0","id":"4","method":"executeShell"}`), MethodNotFound)
	expectCode(t, request(t, client, `{"jsonrpc":"2.0","id":"5","method":"settings.patch","params":{"changes":{}}}`), InvalidParams)
	result := request(t, client, `{"jsonrpc":"2.0","id":"6","method":"settings.patch","params":{"expectedRevision":0,"changes":{"mode":"direct"}}}`)
	var snapshot SettingsSnapshot
	if err := json.Unmarshal(result["result"], &snapshot); err != nil || snapshot.Revision != 1 || snapshot.Settings.Mode != "direct" {
		t.Fatalf("%s", result)
	}
	client.Close()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("worker failed to exit on parent EOF")
	}
}

func TestCancellationConcurrencyAndParentLoss(t *testing.T) {
	started := make(chan struct{}, MaxInFlight)
	client, done := testConnection(t, func(ctx context.Context, _ string, _ json.RawMessage) (any, error) {
		started <- struct{}{}
		<-ctx.Done()
		return nil, ctx.Err()
	})
	request(t, client, `{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":1}}`)
	for i := range MaxInFlight {
		body, _ := json.Marshal(Request{JSONRPC: "2.0", ID: string(rune('a' + i)), Method: "wait"})
		if err := WriteFrame(client, body); err != nil {
			t.Fatal(err)
		}
		<-started
	}
	expectCode(t, request(t, client, `{"jsonrpc":"2.0","id":"overflow","method":"wait"}`), Busy)
	if err := WriteFrame(client, []byte(`{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":"a"}}`)); err != nil {
		t.Fatal(err)
	}
	data, err := ReadFrame(client)
	if err != nil {
		t.Fatal(err)
	}
	var response map[string]json.RawMessage
	json.Unmarshal(data, &response)
	expectCode(t, response, Canceled)
	client.Close()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("requests survived parent loss")
	}
}

type singleByteReader struct{ io.Reader }

func (r singleByteReader) Read(p []byte) (int, error) { return r.Reader.Read(p[:1]) }

func TestFramingBoundsAndFragmentation(t *testing.T) {
	var wire bytes.Buffer
	if err := WriteFrame(&wire, []byte(`{"id":"one"}`)); err != nil {
		t.Fatal(err)
	}
	if data, err := ReadFrame(singleByteReader{&wire}); err != nil || string(data) != `{"id":"one"}` {
		t.Fatalf("fragmented: %s %v", data, err)
	}
	for _, size := range []uint32{0, MaxFrameBytes + 1, ^uint32(0)} {
		var header [4]byte
		binary.BigEndian.PutUint32(header[:], size)
		if _, err := ReadFrame(bytes.NewReader(header[:])); err == nil {
			t.Fatal("accepted oversize/empty frame")
		}
	}
	if _, err := ReadFrame(bytes.NewReader([]byte{0, 0, 0, 4, '{'})); err == nil {
		t.Fatal("accepted truncated frame")
	}
}
