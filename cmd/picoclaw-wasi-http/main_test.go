package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestServeHTTPRejectsInvalidRequests(t *testing.T) {
	s := &server{}
	checks := []struct {
		name   string
		method string
		path   string
		body   string
		want   int
	}{
		{"wrong method", http.MethodGet, "/v1/chat/completions", "", http.StatusNotFound},
		{"wrong path", http.MethodPost, "/v1/models", `{}`, http.StatusNotFound},
		{"invalid json", http.MethodPost, "/v1/chat/completions", `{`, http.StatusBadRequest},
		{"missing user message", http.MethodPost, "/v1/chat/completions", `{"messages":[{"role":"system","content":"x"}]}`, http.StatusBadRequest},
	}
	for _, tc := range checks {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.body))
			got := httptest.NewRecorder()
			s.ServeHTTP(got, req)
			if got.Code != tc.want {
				t.Fatalf("status = %d, want %d; body = %s", got.Code, tc.want, got.Body.String())
			}
		})
	}
}

func TestConfigPathSplit(t *testing.T) {
	if got := configDir("examples/wasi/ollama-config.json"); got != "examples/wasi" {
		t.Fatalf("configDir = %q", got)
	}
	if got := configName("examples/wasi/ollama-config.json"); got != "ollama-config.json" {
		t.Fatalf("configName = %q", got)
	}
	if got := configDir("config.json"); got != "." {
		t.Fatalf("bare configDir = %q", got)
	}
}
