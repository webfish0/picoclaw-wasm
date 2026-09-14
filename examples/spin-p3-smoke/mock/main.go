package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
)

func main() {
	port := os.Getenv("SPIN_PROBE_MOCK_PORT")
	if port == "" {
		port = "18080"
	}
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(io.LimitReader(r.Body, 4096))
		if err != nil {
			http.Error(w, "read failed", http.StatusBadRequest)
			return
		}
		_ = body
		w.Header().Set("Content-Type", "text/plain")
		_, _ = fmt.Fprintln(w, "BROWSER_UAT_OK")
	})
	if err := http.ListenAndServe("127.0.0.1:"+port, nil); err != nil {
		os.Exit(1)
	}
}
