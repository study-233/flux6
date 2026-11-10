package worker

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"runtime"
	"sync"
	"time"
)

const (
	ProtocolVersion    = 1
	MaxFrameBytes      = 1024 * 1024
	MaxInFlight        = 8
	ParseError         = -32700
	InvalidRequest     = -32600
	MethodNotFound     = -32601
	InvalidParams      = -32602
	InternalError      = -32603
	NotInitialized     = -32001
	VersionMismatch    = -32002
	Busy               = -32003
	Conflict           = -32004
	StorageError       = -32005
	Canceled           = -32800
	ResourceError      = -32006
	RegistrationError  = -32007
	ConfigurationError = -32008
)

type RPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (e *RPCError) Error() string { return e.Message }

type Request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      string          `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type Response struct {
	JSONRPC string    `json:"jsonrpc"`
	ID      *string   `json:"id"`
	Result  any       `json:"result,omitempty"`
	Error   *RPCError `json:"error,omitempty"`
}

type Handler func(context.Context, string, json.RawMessage) (any, error)

type ServerOptions struct{ Capabilities []string }

type Progress struct {
	RequestID string `json:"requestId"`
	Sequence  uint64 `json:"sequence"`
	Phase     string `json:"phase"`
	Received  int64  `json:"received"`
	Total     int64  `json:"total"`
	Attempt   int    `json:"attempt"`
	Attempts  int    `json:"attempts"`
	Asset     string `json:"asset,omitempty"`
}

type progressContextKey struct{}

func ReportProgress(ctx context.Context, progress Progress) {
	if emit, ok := ctx.Value(progressContextKey{}).(func(Progress)); ok {
		emit(progress)
	}
}

func ReadFrame(reader io.Reader) ([]byte, error) {
	var header [4]byte
	if _, err := io.ReadFull(reader, header[:]); err != nil {
		return nil, err
	}
	size := binary.BigEndian.Uint32(header[:])
	if size == 0 || size > MaxFrameBytes {
		return nil, errors.New("invalid worker frame length")
	}
	data := make([]byte, size)
	_, err := io.ReadFull(reader, data)
	return data, err
}

func WriteFrame(writer io.Writer, data []byte) error {
	if len(data) == 0 || len(data) > MaxFrameBytes {
		return errors.New("invalid worker frame length")
	}
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], uint32(len(data)))
	for _, buffer := range [][]byte{header[:], data} {
		for len(buffer) != 0 {
			n, err := writer.Write(buffer)
			if err != nil {
				return err
			}
			if n == 0 {
				return io.ErrShortWrite
			}
			buffer = buffer[n:]
		}
	}
	return nil
}

func decodeObject(data []byte, target any) error {
	data = bytes.TrimSpace(data)
	if len(data) == 0 || data[0] != '{' {
		return errors.New("expected object")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	var extra any
	if decoder.Decode(&extra) != io.EOF {
		return errors.New("trailing JSON")
	}
	return nil
}

// Serve owns both streams. Closing either side cancels outstanding operations
// and closes the other side. All writes are serialized through a bounded queue;
// a parent which stops consuming output cannot create an unbounded backlog.
func Serve(parent context.Context, input io.ReadCloser, output io.WriteCloser, handler Handler, options ...ServerOptions) error {
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	responses := make(chan any, MaxInFlight*2)
	capabilities := []string{"settings.get", "settings.patch"}
	if len(options) > 0 {
		capabilities = options[0].Capabilities
	}
	writerDone := make(chan error, 1)
	go func() {
		var failure error
		defer func() { writerDone <- failure; cancel(); input.Close() }()
		for {
			select {
			case <-ctx.Done():
				return
			case response := <-responses:
				data, err := json.Marshal(response)
				if err == nil {
					err = WriteFrame(output, data)
				}
				if err != nil {
					failure = err
					return
				}
			}
		}
	}()
	closerDone := make(chan struct{})
	go func() { <-ctx.Done(); input.Close(); output.Close(); close(closerDone) }()
	send := func(response Response) {
		select {
		case responses <- response:
		case <-ctx.Done():
		}
	}
	replyError := func(id *string, code int, message string) {
		send(Response{JSONRPC: "2.0", ID: id, Error: &RPCError{code, message}})
	}
	var mu sync.Mutex
	active := map[string]context.CancelFunc{}
	var tasks sync.WaitGroup
	ready := false
	var readErr error
	for {
		data, err := ReadFrame(input)
		if err != nil {
			readErr = err
			break
		}
		if !json.Valid(data) {
			replyError(nil, ParseError, "invalid JSON")
			continue
		}
		var request Request
		if err := decodeObject(data, &request); err != nil || request.JSONRPC != "2.0" || request.Method == "" || len(request.Method) > 128 || len(request.ID) > 64 {
			replyError(nil, InvalidRequest, "invalid request")
			continue
		}
		var fields map[string]json.RawMessage
		_ = json.Unmarshal(data, &fields)
		if _, hasID := fields["id"]; hasID && request.ID == "" {
			replyError(nil, InvalidRequest, "id must be a nonempty string")
			continue
		}
		if request.ID == "" {
			if request.Method == "$/cancelRequest" {
				var params struct {
					ID string `json:"id"`
				}
				if decodeObject(request.Params, &params) == nil {
					mu.Lock()
					if stop := active[params.ID]; stop != nil {
						stop()
					}
					mu.Unlock()
				}
			}
			continue // JSON-RPC notifications do not get responses.
		}
		id := request.ID
		if request.Method == "initialize" {
			var params struct {
				ProtocolVersion int `json:"protocolVersion"`
			}
			if ready {
				replyError(&id, InvalidRequest, "already initialized")
				continue
			}
			if decodeObject(request.Params, &params) != nil {
				replyError(&id, InvalidParams, "invalid initialization")
				continue
			}
			if params.ProtocolVersion != ProtocolVersion {
				replyError(&id, VersionMismatch, "unsupported protocol version")
				continue
			}
			ready = true
			send(Response{JSONRPC: "2.0", ID: &id, Result: map[string]any{
				"protocolVersion": ProtocolVersion, "workerVersion": "0.1.0", "platform": runtime.GOOS, "architecture": runtime.GOARCH,
				"capabilities": capabilities, "maxFrameBytes": MaxFrameBytes, "maxInFlight": MaxInFlight,
			}})
			continue
		}
		if !ready {
			replyError(&id, NotInitialized, "initialize first")
			continue
		}
		mu.Lock()
		_, duplicate := active[id]
		if duplicate || len(active) >= MaxInFlight {
			mu.Unlock()
			replyError(&id, Busy, "request already active or concurrency limit reached")
			continue
		}
		timeout := 30 * time.Second
		if request.Method == "runtime.download" || request.Method == "geodata.prepare" {
			timeout = 3 * time.Minute
		}
		if request.Method == "warp.register" {
			timeout = 45 * time.Second
		}
		requestCtx, stop := context.WithTimeout(ctx, timeout)
		active[id] = stop
		mu.Unlock()
		tasks.Add(1)
		go func(request Request) {
			defer tasks.Done()
			defer func() { stop(); mu.Lock(); delete(active, request.ID); mu.Unlock() }()
			var progressMu sync.Mutex
			var sequence uint64
			var last time.Time
			var lastPhase string
			var lastAsset string
			var lastAttempt int
			withProgress := context.WithValue(requestCtx, progressContextKey{}, func(progress Progress) {
				progressMu.Lock()
				defer progressMu.Unlock()
				if requestCtx.Err() != nil {
					return
				}
				if progress.Phase == lastPhase && progress.Asset == lastAsset && progress.Attempt == lastAttempt && time.Since(last) < 200*time.Millisecond {
					return
				}
				sequence++
				progress.RequestID = request.ID
				progress.Sequence = sequence
				notification := struct {
					JSONRPC string   `json:"jsonrpc"`
					Method  string   `json:"method"`
					Params  Progress `json:"params"`
				}{"2.0", "$/progress", progress}
				select {
				case responses <- notification:
					last = time.Now()
					lastPhase = progress.Phase
					lastAsset = progress.Asset
					lastAttempt = progress.Attempt
				default: // Droppable progress must never block transfer or cancellation.
				}
			})
			result, err := handler(withProgress, request.Method, request.Params)
			if result == nil && err == nil {
				result = json.RawMessage("null")
			}
			response := Response{JSONRPC: "2.0", ID: &request.ID, Result: result}
			if err != nil {
				response.Result = nil
				var rpcErr *RPCError
				if errors.As(err, &rpcErr) {
					response.Error = rpcErr
				} else if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
					response.Error = &RPCError{Canceled, "request canceled or timed out"}
				} else {
					response.Error = &RPCError{InternalError, "worker operation failed"}
				}
			}
			send(response)
		}(request)
	}
	cancel()
	<-closerDone
	tasks.Wait()
	writeErr := <-writerDone
	if writeErr != nil {
		return fmt.Errorf("worker output: %w", writeErr)
	}
	if errors.Is(readErr, io.EOF) || parent.Err() != nil {
		return nil
	}
	return readErr
}

func SettingsHandler(store *SettingsStore) Handler {
	return func(ctx context.Context, method string, params json.RawMessage) (any, error) {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		switch method {
		case "settings.get":
			if len(params) != 0 {
				if err := decodeObject(params, &struct{}{}); err != nil {
					return nil, &RPCError{InvalidParams, "expected empty parameters"}
				}
			}
			current, err := store.Get()
			if err != nil {
				return nil, &RPCError{StorageError, "cannot load settings; original retained"}
			}
			return current, nil
		case "settings.patch":
			var input struct {
				ExpectedRevision *uint64         `json:"expectedRevision"`
				Changes          json.RawMessage `json:"changes"`
			}
			if decodeObject(params, &input) != nil || input.ExpectedRevision == nil {
				return nil, &RPCError{InvalidParams, "expected revision and changes"}
			}
			return store.Patch(ctx, *input.ExpectedRevision, input.Changes)
		default:
			return nil, &RPCError{MethodNotFound, "method not found"}
		}
	}
}
