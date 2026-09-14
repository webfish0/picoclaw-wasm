package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"sync"
	"sync/atomic"
)

var (
	receiptMu sync.Mutex
	receiptNo uint64
)

type receipt struct {
	ID         string `json:"receipt_id"`
	RequestID  string `json:"request_id"`
	BodySHA256 string `json:"body_sha256"`
	BodyBytes  int    `json:"body_bytes"`
	Body       string `json:"body"`
}

func main() {
	port := os.Getenv("SPIN_PROBE_MOCK_PORT")
	if port == "" {
		port = "31808"
	}
	receiptsPath := os.Getenv("SPIN_MOCK_RECEIPTS")
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(io.LimitReader(r.Body, 4096))
		if err != nil {
			http.Error(w, "read failed", http.StatusBadRequest)
			return
		}
		if r.Method == http.MethodPost && receiptsPath != "" {
			digest := sha256.Sum256(body)
			receiptMu.Lock()
			file, openErr := os.OpenFile(receiptsPath, os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0600)
			if openErr != nil {
				receiptMu.Unlock()
				http.Error(w, "receipt unavailable", http.StatusInternalServerError)
				return
			}
			entry := receipt{
				ID:         fmt.Sprintf("receipt-%d", atomic.AddUint64(&receiptNo, 1)),
				RequestID:  r.Header.Get("X-Request-ID"),
				BodySHA256: hex.EncodeToString(digest[:]),
				BodyBytes:  len(body),
				Body:       string(body),
			}
			encodeErr := json.NewEncoder(file).Encode(entry)
			_ = file.Close()
			receiptMu.Unlock()
			if encodeErr != nil {
				http.Error(w, "receipt unavailable", http.StatusInternalServerError)
				return
			}
		}
		w.Header().Set("Content-Type", "text/plain")
		_, _ = fmt.Fprintln(w, "BROWSER_UAT_OK")
	})
	if err := http.ListenAndServe("127.0.0.1:"+port, nil); err != nil {
		os.Exit(1)
	}
}
