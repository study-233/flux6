package notice

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestOversizedValidPrefixFallsThroughToNextSource(t *testing.T) {
	doc := `{"cloudProfile":true,"items":[]}`
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("ts") == "" {
			t.Error("missing cache buster")
		}
		if r.URL.Path == "/large" {
			w.Write([]byte(doc + strings.Repeat(" ", MaxBytes)))
			return
		}
		w.Write([]byte(`{"cloudProfile":false,"items":[]}`))
	}))
	defer server.Close()
	p, err := Fetch(context.Background(), server.Client(), []string{server.URL + "/large", server.URL + "/closed"}, time.Now(), func(string) error { return nil })
	if err != nil || p.CloudProfile == nil || CloudAllowed(p.CloudProfile) {
		t.Fatal("oversized prefix opened gate or prevented failover", err)
	}
}

func TestPublishedNoticeOriginPolicy(t *testing.T) {
	for _, raw := range append(Sources(MirrorPrefixes()), "https://raw.githubusercontent.com/evansrrr/free-v6/main/notice.json") {
		if err := trustedURL(raw); err != nil {
			t.Fatal("configured origin rejected", err)
		}
	}
	for _, raw := range []string{"http://github.com/x", "https://github.com:443/x", "https://github.com@attacker.test/x", "https://name@github.com/x", "https://v6.gh-proxy.org.other.test/x", "file:///etc/hosts"} {
		if trustedURL(raw) == nil {
			t.Fatal("accepted untrusted notice URL")
		}
	}
}
