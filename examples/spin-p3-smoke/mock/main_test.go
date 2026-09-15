package main

import (
	"crypto/sha256"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestOwnedMockMarkerAndReceipt(t *testing.T) {
	receipts := filepath.Join(t.TempDir(), "receipts")
	handler := newHandler("owned-test-run", receipts)
	health := httptest.NewRecorder()
	handler.ServeHTTP(health, httptest.NewRequest(http.MethodGet, "/_health", nil))
	if health.Code != http.StatusOK || strings.TrimSpace(health.Body.String()) != "owned-test-run" {
		t.Fatalf("health did not identify fixture: %d %q", health.Code, health.Body.String())
	}
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, httptest.NewRequest(http.MethodPost, "/", strings.NewReader("request-1")))
	if response.Code != http.StatusOK || !strings.Contains(response.Body.String(), "mock_run=owned-test-run") {
		t.Fatalf("response did not identify fixture: %d %q", response.Code, response.Body.String())
	}
	data, err := os.ReadFile(receipts)
	if err != nil {
		t.Fatal(err)
	}
	want := fmt.Sprintf("POST %x\n", sha256.Sum256([]byte("request-1")))
	if string(data) != want {
		t.Fatalf("receipt = %q, want digest %q", data, want)
	}
}
