package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestDoHTTPAllowlistAndResponse(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test" {
			t.Errorf("authorization header missing")
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"ok"}}]}`))
	}))
	defer server.Close()
	response := doHTTP(envelope{Kind: "http_request", URL: server.URL, Method: http.MethodPost, Headers: map[string]string{"Authorization": "Bearer test"}, Body: "{}"})
	if response.Status != http.StatusOK {
		t.Fatalf("status = %d, want 200", response.Status)
	}
	if !strings.Contains(response.Body, "ok") {
		t.Fatalf("response body = %s", response.Body)
	}
	denied := doHTTP(envelope{Kind: "http_request", URL: "https://example.invalid/chat", Method: http.MethodPost})
	if denied.Status != http.StatusForbidden {
		t.Fatalf("denied status = %d, want 403", denied.Status)
	}
}
