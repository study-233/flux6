package app

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
)

type cloudRoundTripper func(*http.Request) (*http.Response, error)

func (f cloudRoundTripper) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

type interruptedCloudBody struct{}

func (interruptedCloudBody) Read([]byte) (int, error) { return 0, io.ErrUnexpectedEOF }
func (interruptedCloudBody) Close() error             { return nil }

func TestCloudFetchRetryAndCancellation(t *testing.T) {
	for _, kind := range []string{"reset", "body", "persistent", "dns", "certificate", "gate", "canceled", "large"} {
		t.Run(kind, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			attempts := 0
			var logs []string
			client := &http.Client{Transport: cloudRoundTripper(func(r *http.Request) (*http.Response, error) {
				attempts++
				if r.Header.Get("User-Agent") != "FreeV6" {
					t.Fatal("missing user agent")
				}
				if _, ok := r.Context().Deadline(); !ok {
					t.Fatal("missing attempt deadline")
				}
				if attempts == 1 || kind == "persistent" {
					switch kind {
					case "reset", "persistent":
						return nil, errors.New("connection reset by peer")
					case "body":
						return &http.Response{StatusCode: 200, Body: interruptedCloudBody{}, Header: make(http.Header)}, nil
					case "dns":
						return nil, &net.DNSError{Err: "no such host", Name: r.URL.Hostname()}
					case "certificate":
						return nil, errors.New("certificate verification failed")
					case "gate":
						return &http.Response{StatusCode: 403, Body: io.NopCloser(strings.NewReader("")), Header: make(http.Header)}, nil
					case "canceled":
						cancel()
						return nil, context.Canceled
					case "large":
						return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(strings.Repeat("x", MaxSubscriptionBytes+1))), Header: make(http.Header)}, nil
					}
				}
				return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader("profile")), Header: make(http.Header)}, nil
			})}
			data, err := fetchCloudProfile(ctx, "https://private.example/profile?secret=hidden", client, func(s string) { logs = append(logs, s) })
			wantAttempts := 1
			if kind == "reset" || kind == "body" || kind == "persistent" {
				wantAttempts = 2
			}
			if attempts != wantAttempts {
				t.Fatalf("attempts = %d, want %d", attempts, wantAttempts)
			}
			if kind == "reset" || kind == "body" {
				if err != nil || string(data) != "profile" {
					t.Fatalf("data = %q, error = %v", data, err)
				}
			} else {
				if err == nil {
					t.Fatal("expected error")
				}
				if strings.Contains(err.Error(), "private.example") || strings.Contains(err.Error(), "hidden") {
					t.Fatalf("unredacted error: %v", err)
				}
			}
			if kind == "gate" && CloudErrorCode(err) != "campus-only" {
				t.Fatalf("wrong gate classification: %v", err)
			}
			if len(logs) == 0 {
				t.Fatal("missing failure diagnostics")
			}
		})
	}
}

func TestCloudFetchTransportStaysDirect(t *testing.T) {
	transport := cloudHTTPClient.Transport.(*http.Transport)
	if transport.Proxy != nil || transport.ForceAttemptHTTP2 {
		t.Fatal("cloud requests must use direct HTTP/1.1")
	}
	if transport.TLSHandshakeTimeout <= 0 || transport.ResponseHeaderTimeout <= 0 || cloudHTTPClient.Timeout <= 0 {
		t.Fatal("unbounded cloud request")
	}
}

// 失败分类与"是否值得重试"是弹窗文案与重试策略的唯一依据，单测锁住。
func TestFetchFailureClassification(t *testing.T) {
	refused := errors.New("dial tcp 1.2.3.4:443: connect: connection refused")
	reset := errors.New("read tcp 1.2.3.4:443: connection reset by peer")
	dns := &net.DNSError{Err: "no such host", Name: "x.freev6.cc.cd"}

	cases := []struct {
		name   string
		err    error
		reason string
		retry  bool
	}{
		{"deadline", context.DeadlineExceeded, "请求超时，请稍后重试", true},
		{"dns", dns, "域名解析失败，请检查网络或 DNS", false},
		{"refused", refused, "连接被拒绝", false},
		{"reset", reset, "网络请求失败，请稍后重试", true},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			if got := describeFetchFailure(testCase.err); got != testCase.reason {
				t.Fatalf("reason = %q, want %q", got, testCase.reason)
			}
			if got := isRetryableFetch(testCase.err); got != testCase.retry {
				t.Fatalf("retryable = %v, want %v", got, testCase.retry)
			}
		})
	}
}
