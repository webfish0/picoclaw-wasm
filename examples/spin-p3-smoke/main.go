package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"sort"
	"strings"

	spinhttp "github.com/spinframework/spin-go-sdk/v3/http"
	"github.com/spinframework/spin-go-sdk/v3/kv"
	"github.com/spinframework/spin-go-sdk/v3/variables"
	"github.com/webfish0/picoclaw-wasm/examples/spin-p3-smoke/internal/probe"
)

func init() {
	spinhttp.Handle(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && r.URL.Path == "/snapshot" {
			writeSnapshot(w)
			return
		}
		if r.Method != http.MethodPost || r.URL.Path != "/probe" {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		correlationID, err := probe.RequestID(r)
		if err != nil {
			http.Error(w, "invalid request id", http.StatusBadRequest)
			return
		}
		log.Printf("probe request id=%s", correlationID)
		secret, err := variables.Get("secret")
		if err != nil || strings.TrimSpace(secret) == "" {
			http.Error(w, "probe unavailable", http.StatusServiceUnavailable)
			return
		}
		var store *kv.Store
		store, err = kv.Open("workspace")
		if err != nil {
			http.Error(w, "probe storage unavailable", http.StatusServiceUnavailable)
			return
		}
		deniedStoreClasses := make(map[string]string)
		for _, deniedStore := range []string{"default", "ungranted"} {
			if denied, openErr := kv.Open(deniedStore); openErr == nil {
				_ = denied
				http.Error(w, "probe store boundary violated", http.StatusInternalServerError)
				return
			} else {
				deniedStoreClasses[deniedStore] = boundaryErrorClass(openErr)
			}
		}
		if deniedStoreClasses["default"] == "" || deniedStoreClasses["ungranted"] == "" {
			http.Error(w, "probe storage boundary is unclassified", http.StatusInternalServerError)
			return
		}
		key := "request/" + correlationID
		preexisting, err := store.Exists(key)
		if err != nil {
			http.Error(w, "probe storage unavailable", http.StatusServiceUnavailable)
			return
		}
		requestBody, err := io.ReadAll(io.LimitReader(r.Body, 1024))
		if err != nil {
			http.Error(w, "invalid request body", http.StatusBadRequest)
			return
		}
		digest := sha256.Sum256(append([]byte(correlationID+"|"), requestBody...))
		serverID := "server-" + hex.EncodeToString(digest[:8])
		value := fmt.Sprintf("%s|%s|%s", serverID, correlationID, strings.TrimSpace(string(requestBody)))
		previousValue := ""
		if preexisting {
			previous, getErr := store.Get(key)
			if getErr != nil {
				http.Error(w, "probe storage unavailable", http.StatusServiceUnavailable)
				return
			}
			previousValue = string(previous)
		}
		if err := store.Set(key, []byte(value)); err != nil {
			http.Error(w, "probe storage unavailable", http.StatusServiceUnavailable)
			return
		}
		stored, err := store.Get(key)
		if err != nil || string(stored) != value {
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
		for _, denied := range []string{"/etc/hosts", "/fixtures/../config.json", "/fixtures/other.txt", "/spin.toml"} {
			if _, err := os.ReadFile(denied); err == nil {
				http.Error(w, "probe filesystem boundary violated", http.StatusInternalServerError)
				return
			}
		}
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
		resp, err := spinhttp.NewClient().Post(mockURL, "application/json", strings.NewReader(string(requestBody)))
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
		_, _ = fmt.Fprintf(w, "SPIN_P3_OK\nrequest_id=%s\nserver_id=%s\nstored_value=%s\npreexisting=%t\nprevious_value=%s\ndenied_default_class=%s\ndenied_ungranted_class=%s\nfixtures=read-only\ndenied_paths=/etc/hosts,/fixtures/../config.json,/fixtures/other.txt,/spin.toml\n%s", correlationID, serverID, stored, preexisting, previousValue, deniedStoreClasses["default"], deniedStoreClasses["ungranted"], strings.TrimSpace(string(body)))
	})
}

func writeSnapshot(w http.ResponseWriter) {
	store, err := kv.Open("workspace")
	if err != nil {
		http.Error(w, "probe storage unavailable", http.StatusServiceUnavailable)
		return
	}
	keys := make([]string, 0)
	for key, iterErr := range store.GetKeys() {
		if iterErr != nil {
			http.Error(w, "probe storage unavailable", http.StatusServiceUnavailable)
			return
		}
		keys = append(keys, key)
	}
	sort.Strings(keys)
	w.Header().Set("Content-Type", "text/plain")
	for _, key := range keys {
		value, getErr := store.Get(key)
		if getErr != nil {
			http.Error(w, "probe storage unavailable", http.StatusServiceUnavailable)
			return
		}
		_, _ = fmt.Fprintf(w, "%s=%s\n", key, value)
	}
}

func boundaryErrorClass(err error) string {
	message := strings.ToLower(err.Error())
	switch {
	case strings.Contains(message, "no such") || strings.Contains(message, "not found"):
		return "no-such-store"
	case strings.Contains(message, "access") || strings.Contains(message, "permission") || strings.Contains(message, "denied"):
		return "access-denied"
	default:
		return "denied"
	}
}

func main() {}
