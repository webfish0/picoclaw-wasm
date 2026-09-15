package main

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	spinhttp "github.com/spinframework/spin-go-sdk/v3/http"
)

func init() {
	spinhttp.Handle(handleMatrixOrPrivate)
}

func handleMatrixOrPrivate(w http.ResponseWriter, r *http.Request) {
	if os.Getenv("SPIN_PROBE_INTERNAL_MOCK") == "1" {
		if r.Method != http.MethodPost {
			http.Error(w, "not found", http.StatusNotFound)
		} else {
			_, _ = w.Write([]byte("CHAIN_OK"))
		}
		return
	}
	if r.URL.Path != "/matrix" {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	handleMatrix(w, r)
}

// The test-only component chooses a fixed case, never a caller-supplied URL.
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
