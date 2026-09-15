package main

import (
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	spinhttp "github.com/spinframework/spin-go-sdk/v3/http"
	"github.com/spinframework/spin-go-sdk/v3/kv"
	"github.com/spinframework/spin-go-sdk/v3/variables"
	"github.com/webfish0/picoclaw-wasm/examples/spin-p3-smoke/internal/probe"
)

func init() {
	spinhttp.Handle(func(w http.ResponseWriter, r *http.Request) {
		if os.Getenv("SPIN_PROBE_INTERNAL_MOCK") == "1" {
			if r.Method != http.MethodPost {
				http.Error(w, "not found", http.StatusNotFound)
				return
			}
			_, _ = w.Write([]byte("CHAIN_OK"))
			return
		}
		if r.URL.Path == "/matrix" && os.Getenv("SPIN_PROBE_MATRIX_ENABLED") == "1" {
			handleMatrix(w, r)
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
		deniedStoreClass := ""
		for _, deniedStore := range []string{"default", "ungranted"} {
			if denied, openErr := kv.Open(deniedStore); openErr == nil {
				_ = denied
				http.Error(w, "probe store boundary violated", http.StatusInternalServerError)
				return
			} else if deniedStoreClass == "" {
				deniedStoreClass = boundaryErrorClass(openErr)
			}
		}
		key := "request/" + correlationID
		preexisting, err := store.Exists(key)
		if err != nil {
			http.Error(w, "probe storage unavailable", http.StatusServiceUnavailable)
			return
		}
		previous := ""
		if preexisting {
			old, getErr := store.Get(key)
			if getErr != nil {
				http.Error(w, "probe storage unavailable", http.StatusServiceUnavailable)
				return
			}
			previous = string(old)
		}
		if err := store.Set(key, []byte(correlationID)); err != nil {
			http.Error(w, "probe storage unavailable", http.StatusServiceUnavailable)
			return
		}
		stored, err := store.Get(key)
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
		_, _ = fmt.Fprintf(w, "SPIN_P3_OK\nrequest_id=%s\nstored_id=%s\npreexisting=%t\nprevious_id=%s\ndenied_store_class=%s\nfixtures=read-only\n%s", correlationID, stored, preexisting, previous, deniedStoreClass, strings.TrimSpace(string(body)))
	})
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

// Matrix requests are available only in the isolated smoke harness. The
// caller selects a fixed case, never an arbitrary destination URL.
func handleMatrix(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	caseName := r.Header.Get("X-Matrix-Case")
	if caseName == "raw-socket" {
		connection, err := net.DialTimeout("tcp", "127.0.0.1:18090", time.Second)
		if err == nil {
			_ = connection.Close()
			http.Error(w, "raw socket boundary violated", http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusBadGateway)
		_, _ = fmt.Fprintf(w, "case=%s\nclass=raw-socket-denied\n", caseName)
		return
	}
	url, ok := map[string]string{
		"control":      "http://127.0.0.1:18090/",
		"wrong-scheme": "https://127.0.0.1:18090/",
		"wrong-host":   "http://localhost:18090/",
		"wrong-port":   "http://127.0.0.1:18091/",
		"userinfo":     "http://user@127.0.0.1:18090/",
		"redirect":     "http://127.0.0.1:18090/redirect",
		"chain":        "http://mock.spin.internal/",
	}[caseName]
	if !ok {
		http.Error(w, "unknown matrix case", http.StatusBadRequest)
		return
	}
	response, err := spinhttp.NewClient().Post(url, "text/plain", strings.NewReader("matrix-sentinel"))
	if err != nil {
		w.WriteHeader(http.StatusBadGateway)
		_, _ = fmt.Fprintf(w, "case=%s\nclass=%s\n", caseName, matrixErrorClass(err))
		return
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 4096))
	if err != nil {
		http.Error(w, "matrix response unavailable", http.StatusBadGateway)
		return
	}
	w.WriteHeader(response.StatusCode)
	_, _ = fmt.Fprintf(w, "case=%s\nclass=http-%d\n%s", caseName, response.StatusCode, body)
}

func matrixErrorClass(err error) string {
	message := strings.ToLower(err.Error())
	switch {
	case strings.Contains(message, "destination not allowed"):
		return "destination-not-allowed"
	case strings.Contains(message, "destination ip prohibited"):
		return "destination-ip-prohibited"
	case strings.Contains(message, "uri invalid"):
		return "invalid-uri"
	case strings.Contains(message, "connection refused"):
		return "connection-refused"
	default:
		return "other-transport-denial"
	}
}

func main() {}
