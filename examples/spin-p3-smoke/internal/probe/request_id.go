package probe

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"net/http"
	"regexp"
	"strings"
)

var requestIDPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

// RequestID returns a bounded client ID or a fresh server-generated ID.
func RequestID(r *http.Request) (string, error) {
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
