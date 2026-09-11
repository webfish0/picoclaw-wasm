// Command picoclaw-wasi-http provides a localhost-only human/API adapter for
// the WASI prototype. It invokes the restricted native bridge for each request.
package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strings"
)

type request struct {
	Messages []struct {
		Role    string `json:"role"`
		Content string `json:"content"`
	} `json:"messages"`
}

type response struct {
	ID      string `json:"id"`
	Object  string `json:"object"`
	Model   string `json:"model"`
	Choices []struct {
		Index   int `json:"index"`
		Message struct {
			Role    string `json:"role"`
			Content string `json:"content"`
		} `json:"message"`
	} `json:"choices"`
}

func main() {
	listen := flag.String("listen", "127.0.0.1:18082", "localhost listen address")
	wasm := flag.String("wasm", "build/picoclaw-wasi.wasm", "WASI module")
	config := flag.String("config", "examples/wasi/ollama-config.json", "config file or config directory")
	skills := flag.String("skills", "examples/wasi/skills", "skills directory")
	workspace := flag.String("workspace", "/tmp/picoclaw-wasi-http-workspace", "workspace directory")
	secretEnv := flag.String("secret-env", "OLLAMA_API_KEY", "optional provider secret environment variable")
	flag.Parse()
	if err := os.MkdirAll(*workspace, 0o700); err != nil {
		fatal(err)
	}
	h := &server{wasm: *wasm, config: *config, skills: *skills, workspace: *workspace, secretEnv: *secretEnv}
	fmt.Fprintln(os.Stderr, "picoclaw-wasi-http listening on http://"+*listen)
	fatal(http.ListenAndServe(*listen, h))
}

type server struct{ wasm, config, skills, workspace, secretEnv string }

func (s *server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.URL.Path != "/v1/chat/completions" || r.Method != http.MethodPost {
		http.NotFound(w, r)
		return
	}
	var in request
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&in); err != nil {
		http.Error(w, "invalid JSON: "+err.Error(), http.StatusBadRequest)
		return
	}
	prompt := ""
	for i := len(in.Messages) - 1; i >= 0; i-- {
		if in.Messages[i].Role == "user" {
			prompt = strings.TrimSpace(in.Messages[i].Content)
			break
		}
	}
	if prompt == "" {
		http.Error(w, "a user message is required", http.StatusBadRequest)
		return
	}
	cmd := exec.Command("go", "run", "./cmd/picoclaw-wasi-bridge", "--wasm", s.wasm, "--config", configDir(s.config), "--config-file", configName(s.config), "--skills", s.skills, "--workspace", s.workspace, "--secret-env", s.secretEnv)
	cmd.Dir = repoRoot()
	cmd.Stdin = strings.NewReader(prompt + "\n")
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		http.Error(w, strings.TrimSpace(stderr.String()), http.StatusBadGateway)
		return
	}
	content := strings.TrimSpace(stdout.String())
	result := response{ID: "picoclaw-wasi", Object: "chat.completion", Model: "picoclaw-wasi"}
	result.Choices = append(result.Choices, struct {
		Index   int `json:"index"`
		Message struct {
			Role    string `json:"role"`
			Content string `json:"content"`
		} `json:"message"`
	}{Message: struct {
		Role    string `json:"role"`
		Content string `json:"content"`
	}{Role: "assistant", Content: content}})
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(result)
}

func configDir(path string) string {
	if strings.HasSuffix(path, ".json") {
		if i := strings.LastIndex(path, "/"); i >= 0 {
			return path[:i]
		}
		return "."
	}
	return path
}
func configName(path string) string {
	if i := strings.LastIndex(path, "/"); i >= 0 {
		return path[i+1:]
	}
	return path
}

func repoRoot() string {
	if root := os.Getenv("PICOCLAW_REPO_ROOT"); root != "" {
		return root
	}
	return "."
}
func fatal(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
