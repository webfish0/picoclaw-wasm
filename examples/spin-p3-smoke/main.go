package main

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"regexp"
	"strings"

	spinhttp "github.com/spinframework/spin-go-sdk/v3/http"
	"github.com/spinframework/spin-go-sdk/v3/kv"
	"github.com/spinframework/spin-go-sdk/v3/variables"
	"github.com/webfish0/picoclaw-wasm/examples/spin-p3-smoke/internal/probe"
)

var requestIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

func requestID(r *http.Request) (string, error) {
	id := strings.TrimSpace(r.Header.Get("X-Request-ID"))
	if id != "" {
		if !requestIDPattern.MatchString(id) {
			return "", fmt.Errorf("invalid request id")
		}
		return id, nil
	}
	var bytes [16]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		return "", fmt.Errorf("generate request id: %w", err)
	}
	return "probe-" + hex.EncodeToString(bytes[:]), nil
}

func init() {
	spinhttp.Handle(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/probe" {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		correlationID, err := requestID(r)
		if err != nil {
			http.Error(w, "invalid request id", http.StatusBadRequest)
			return
		}
		log.Printf("probe request id=%s", correlationID)
		if _, err := variables.Get("secret"); err != nil {
			http.Error(w, "probe unavailable", http.StatusServiceUnavailable)
			return
		}
		var store *kv.Store
		store, err = kv.Open("workspace")
		if err != nil {
			http.Error(w, "probe storage unavailable", http.StatusServiceUnavailable)
			return
		}
		for _, deniedStore := range []string{"default", "ungranted"} {
			if denied, openErr := kv.Open(deniedStore); openErr == nil {
				_ = denied
				http.Error(w, "probe store boundary violated", http.StatusInternalServerError)
				return
			}
		}
		if err := store.Set("request/"+correlationID, []byte(correlationID)); err != nil {
			http.Error(w, "probe storage unavailable", http.StatusServiceUnavailable)
			return
		}
		stored, err := store.Get("request/" + correlationID)
		if err != nil || string(stored) != correlationID {
			http.Error(w, "probe storage unavailable", http.StatusServiceUnavailable)
			return
		}
		for _, fixture := range []string{"/fixtures/config.json", "/fixtures/SKILL.md"} {
			if _, err := os.ReadFile(fixture); err != nil {
				http.Error(w, "probe fixtures unavailable", http.StatusServiceUnavailable)
				return
			}
			file, err := os.OpenFile(fixture, os.O_WRONLY|os.O_APPEND, 0)
			if err == nil {
				_ = file.Close()
				http.Error(w, "probe fixture is writable", http.StatusInternalServerError)
				return
			}
		}
		for _, denied := range []string{"/etc/hosts", "/fixtures/../config.json", "/fixtures/other.txt"} {
			if _, err := os.ReadFile(denied); err == nil {
				http.Error(w, "probe filesystem boundary violated", http.StatusInternalServerError)
				return
			}
		}
		previous := ""
		mockURL := os.Getenv("SPIN_PROBE_MOCK_URL")
		if mockURL == "" {
			http.Error(w, "probe mock is not configured", http.StatusInternalServerError)
			return
		}
		mockURL, err = probe.NormalizeMockURL(mockURL)
		if err != nil {
			http.Error(w, "invalid probe destination", http.StatusBadRequest)
			return
		}
		resp, err := spinhttp.NewClient().Post(mockURL, "application/json", r.Body)
		if err != nil {
			http.Error(w, "outbound probe failed", http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()
		body, err := io.ReadAll(io.LimitReader(resp.Body, 4096))
		if err != nil || resp.StatusCode < 200 || resp.StatusCode >= 300 {
			http.Error(w, "outbound probe returned an error", http.StatusBadGateway)
			return
		}
		w.Header().Set("Content-Type", "text/plain")
		w.Header().Set("X-Request-ID", correlationID)
		w.WriteHeader(http.StatusOK)
		_, _ = fmt.Fprintf(w, "SPIN_P3_OK\nrequest_id=%s\nstored_id=%s\nprevious_id=%s\nfixtures=read-only\n%s", correlationID, stored, previous, strings.TrimSpace(string(body)))
	})
}

func main() {}
