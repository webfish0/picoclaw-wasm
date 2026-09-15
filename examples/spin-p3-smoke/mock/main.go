package main

import (
	"crypto/sha256"
	"fmt"
	"io"
	"net/http"
	"os"
	"sync"
)

func main() {
	port := os.Getenv("SPIN_PROBE_MOCK_PORT")
	if port == "" {
		port = "18080"
	}
	marker := os.Getenv("SPIN_PROBE_MOCK_MARKER")
	receipts := os.Getenv("SPIN_PROBE_MOCK_RECEIPTS")
	if err := http.ListenAndServe("127.0.0.1:"+port, newHandler(marker, receipts)); err != nil {
		os.Exit(1)
	}
}

func newHandler(marker, receipts string) http.Handler {
	var receiptMu sync.Mutex
	mux := http.NewServeMux()
	mux.HandleFunc("/_health", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		_, _ = fmt.Fprintln(w, marker)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(io.LimitReader(r.Body, 4096))
		if err != nil {
			http.Error(w, "read failed", http.StatusBadRequest)
			return
		}
		if receipts != "" {
			receiptMu.Lock()
			file, openErr := os.OpenFile(receipts, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0600)
			if openErr == nil {
				_, openErr = fmt.Fprintf(file, "%s %x\n", r.Method, sha256.Sum256(body))
				_ = file.Close()
			}
			receiptMu.Unlock()
			if openErr != nil {
				http.Error(w, "receipt unavailable", http.StatusInternalServerError)
				return
			}
		}
		if r.URL.Path == "/redirect" {
			w.Header().Set("Location", "http://127.0.0.1:18091/denied")
			w.WriteHeader(http.StatusFound)
			return
		}
		w.Header().Set("Content-Type", "text/plain")
		_, _ = fmt.Fprintf(w, "BROWSER_UAT_OK\nmock_run=%s\n", marker)
	})
	return mux
}
