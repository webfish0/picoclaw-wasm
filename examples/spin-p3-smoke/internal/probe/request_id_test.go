package probe

import (
	"net/http/httptest"
	"strings"
	"testing"
)

func TestRequestIDValidatesAndGenerates(t *testing.T) {
	valid := httptest.NewRequest("POST", "/probe", nil)
	valid.Header.Set("X-Request-ID", " client-01 ")
	got, err := RequestID(valid)
	if err != nil || got != "client-01" {
		t.Fatalf("valid ID = %q, %v", got, err)
	}

	invalid := httptest.NewRequest("POST", "/probe", nil)
	invalid.Header.Set("X-Request-ID", "../escape")
	if _, err := RequestID(invalid); err == nil {
		t.Fatal("path traversal ID was accepted")
	}

	generated, err := RequestID(httptest.NewRequest("POST", "/probe", nil))
	if err != nil || !strings.HasPrefix(generated, "probe-") || len(generated) != len("probe-")+32 {
		t.Fatalf("generated ID = %q, %v", generated, err)
	}
}
