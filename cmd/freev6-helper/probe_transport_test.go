package main

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type probeRoundTrip func(*http.Request) (*http.Response, error)

func (f probeRoundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestProbeJudgmentAndChangedSession(t *testing.T) {
	downloads := &nodeDownloads{}
	channel := &downloadChannel{}
	downloads.activate(channel)
	downloads.activate(nil)
	if channel.probeContext.Err() != context.Canceled {
		t.Fatal("stopped session did not cancel its diagnostics")
	}
	valid := true
	requests := 0
	env := serviceEnv{ctx: context.Background(), valid: func() bool { return valid }, transport: probeRoundTrip(func(r *http.Request) (*http.Response, error) {
		requests++
		if r.URL.String() != "https://claude.ai/cdn-cgi/trace" {
			t.Fatal(r.URL)
		}
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader("ip=203.0.113.2\nloc=SG\n")), Header: http.Header{}}, nil
	})}
	result := checkClaude(env)
	if result.Status != serviceAvailable || result.Region != "SG" {
		t.Fatalf("%+v", result)
	}
	valid = false
	if result = checkClaude(env); result.Status != serviceFailed || requests != 1 {
		t.Fatalf("stale session used: %+v, requests=%d", result, requests)
	}
	env.valid = func() bool { return true }
	env.transport = probeRoundTrip(func(_ *http.Request) (*http.Response, error) { return nil, context.DeadlineExceeded })
	if result = checkClaude(env); result.Status != serviceTimeout {
		t.Fatalf("%+v", result)
	}
}

func TestProbeRequiresActiveSessionAndRejectsArbitraryURLs(t *testing.T) {
	h := &helper{root: t.TempDir()}
	for _, check := range []struct {
		body   string
		status int
	}{
		{`{"kind":"ip","session":"stale"}`, 409},
		{`{"kind":"ip","url":"https://example.test/private"}`, 400},
	} {
		r := httptest.NewRecorder()
		h.diagnosticProbe(r, httptest.NewRequest("POST", "/", strings.NewReader(check.body)))
		if r.Code != check.status {
			t.Fatalf("%d: %s", r.Code, r.Body.String())
		}
	}
}
