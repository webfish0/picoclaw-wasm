package probe

import "testing"

func TestNormalizeMockURL(t *testing.T) {
	tests := []struct {
		name, input, want string
	}{
		{"origin", "http://127.0.0.1:18080", "http://127.0.0.1:18080/"},
		{"path", "http://127.0.0.1:18080/mock", "http://127.0.0.1:18080/mock"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := NormalizeMockURL(tt.input)
			if err != nil || got != tt.want {
				t.Fatalf("got %q, %v; want %q", got, err, tt.want)
			}
		})
	}
}

func TestNormalizeMockURLRejectsAmbiguousDestinations(t *testing.T) {
	for _, input := range []string{
		"https://127.0.0.1:18080", "http://127.0.0.2:18080", "http://127.0.0.1:18081",
		"http://user@127.0.0.1:18080", "http://127.0.0.1:18080/?token=secret", "http://127.0.0.1:18080/#x",
	} {
		if _, err := NormalizeMockURL(input); err == nil {
			t.Errorf("accepted %q", input)
		}
	}
}

func TestNormalizeMockURLPreservesPathAndRejectsQuery(t *testing.T) {
	got, err := NormalizeMockURL("http://127.0.0.1:18080/mock")
	if err != nil || got != "http://127.0.0.1:18080/mock" {
		t.Fatalf("path changed: got %q, %v", got, err)
	}
	for _, input := range []string{
		"http://127.0.0.1:18080/mock?next=http://evil.test",
		"http://127.0.0.1:18080/mock#fragment",
	} {
		if _, err := NormalizeMockURL(input); err == nil {
			t.Errorf("accepted ambiguous URL %q", input)
		}
	}
}
