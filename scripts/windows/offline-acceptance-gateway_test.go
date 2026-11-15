//go:build windows

package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestAcceptanceGatewayNeverForwardsNetworkActions(t *testing.T) {
	for _, path := range []string{"/proxy/start", "/warp/register", "/runtime/download", "/update/download", "/chain-proxy", "/cloud-config", "/settings/reset"} {
		t.Run(path, func(t *testing.T) {
			forwarded := false
			h := acceptanceHandler("fixture", http.HandlerFunc(func(http.ResponseWriter, *http.Request) { forwarded = true }), func(string, string, string) {})
			r := httptest.NewRequest(http.MethodPost, "/api/v1"+path, nil)
			r.Header.Set("Authorization", "Bearer fixture")
			w := httptest.NewRecorder()
			h.ServeHTTP(w, r)
			if forwarded || w.Code != http.StatusServiceUnavailable {
				t.Fatalf("forwarded=%v status=%d", forwarded, w.Code)
			}
		})
	}
}

func TestAcceptanceGatewayUsesNativeSettingsAndRequiresAuth(t *testing.T) {
	forwarded := 0
	h := acceptanceHandler("fixture", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { forwarded++; w.WriteHeader(http.StatusNoContent) }), func(string, string, string) {})
	for _, method := range []string{http.MethodGet, http.MethodPut} {
		r := httptest.NewRequest(method, "/api/v1/settings", nil)
		r.Header.Set("Authorization", "Bearer fixture")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != http.StatusNoContent {
			t.Fatal(w.Code)
		}
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/api/v1/settings", nil))
	if forwarded != 2 || w.Code != http.StatusUnauthorized {
		t.Fatalf("forwarded=%d status=%d", forwarded, w.Code)
	}
}
