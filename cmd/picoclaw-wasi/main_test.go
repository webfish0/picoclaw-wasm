package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSkillsAndProviderRequest(t *testing.T) {
	root := t.TempDir()
	skills := filepath.Join(root, "skills")
	workspace := filepath.Join(root, "workspace")
	if err := os.MkdirAll(filepath.Join(skills, "demo"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(skills, "demo", "SKILL.md"), []byte("answer tersely"), 0o644); err != nil {
		t.Fatal(err)
	}
	seen := ""
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b := make([]byte, r.ContentLength)
		_, _ = r.Body.Read(b)
		seen = string(b)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":"ok"}}]}`))
	}))
	defer server.Close()
	u := strings.TrimPrefix(server.URL, "http://")
	os.Setenv("TEST_KEY", "redacted")
	defer os.Unsetenv("TEST_KEY")
	got, err := callProvider(config{Model: "test", APIBase: server.URL, APIKeyEnv: "TEST_KEY", SkillsRoot: skills, Workspace: workspace, AllowedHost: strings.Split(u, ":")[0]}, "answer tersely", "hello")
	if err != nil || got != "ok" {
		t.Fatalf("callProvider = %q, %v", got, err)
	}
	if !strings.Contains(seen, "hello") || !strings.Contains(seen, "answer tersely") {
		t.Fatalf("request omitted prompt or skill: %s", seen)
	}
}

func TestForbiddenPaths(t *testing.T) {
	if err := validateRoot("/Users/me", "workspace"); err != nil {
		t.Fatal(err)
	}
	if err := validateRoot("/workspace/../home", "workspace"); err == nil {
		t.Fatal("expected traversal rejection")
	}
	if err := validateConfigPath("/Users/me/config.json"); err == nil {
		t.Fatal("expected config rejection")
	}
}

func TestMissingSecret(t *testing.T) {
	_, err := callProvider(config{Model: "test", APIBase: "https://api.openrouter.ai/v1", APIKeyEnv: "MISSING_KEY", AllowedHost: "api.openrouter.ai"}, "", "hello")
	if err == nil || !strings.Contains(err.Error(), "missing runtime secret") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestProviderRejectsHostNotInConfiguredAllowlist(t *testing.T) {
	os.Setenv("TEST_KEY", "test")
	defer os.Unsetenv("TEST_KEY")
	_, err := callProvider(config{Model: "test", APIBase: "http://127.0.0.1:18080/v1", APIKeyEnv: "TEST_KEY", AllowedHost: "api.openrouter.ai"}, "", "hello")
	if err == nil || !strings.Contains(err.Error(), "HTTPS or localhost") {
		t.Fatalf("unexpected error: %v", err)
	}
}
