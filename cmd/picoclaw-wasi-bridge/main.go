// Command picoclaw-wasi-bridge supplies a narrowly scoped HTTP capability to
// the stdin/stdout picoclaw-wasi module. It is native host plumbing, not part
// of the WASM artifact and not available to skills or model tools.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strings"
)

type envelope struct {
	Kind       string            `json:"kind"`
	URL        string            `json:"url,omitempty"`
	Method     string            `json:"method,omitempty"`
	Headers    map[string]string `json:"headers,omitempty"`
	Body       string            `json:"body,omitempty"`
	Status     int               `json:"status,omitempty"`
	StatusText string            `json:"status_text,omitempty"`
}

func main() {
	wasm := flag.String("wasm", "build/picoclaw-wasi.wasm", "WASI module")
	config := flag.String("config", "examples/wasi", "host directory mounted as /config")
	configFile := flag.String("config-file", "config.json", "config filename within the mounted config directory")
	skills := flag.String("skills", "examples/wasi/skills", "host directory mounted as /skills")
	workspace := flag.String("workspace", "/tmp/picoclaw-wasi-workspace", "host directory mounted as /workspace")
	secretEnv := flag.String("secret-env", "OPENROUTER_API_KEY", "secret environment variable inherited by the module")
	flag.Parse()

	cmd := exec.Command("wasmtime", "run", "--dir", *config+"::/config", "--dir", *skills+"::/skills", "--dir", *workspace+"::/workspace", "--env", "PICOCLAW_WASI_HTTP_BRIDGE=1", "--env", "PICOCLAW_WASI_CONFIG=/config/"+*configFile, "--env", *secretEnv, *wasm)
	childIn, err := cmd.StdinPipe()
	if err != nil {
		fail(err)
	}
	childOut, err := cmd.StdoutPipe()
	if err != nil {
		fail(err)
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		fail(fmt.Errorf("start wasmtime: %w", err))
	}

	input, err := io.ReadAll(os.Stdin)
	if err != nil {
		fail(err)
	}
	if _, err := childIn.Write(input); err != nil {
		fail(err)
	}
	if len(input) == 0 || input[len(input)-1] != '\n' {
		_, _ = childIn.Write([]byte{'\n'})
	}

	reader := bufio.NewReader(childOut)
	line, err := reader.ReadString('\n')
	if err != nil {
		fail(fmt.Errorf("read module request: %w", err))
	}
	var request envelope
	if err := json.Unmarshal([]byte(strings.TrimSpace(line)), &request); err != nil || request.Kind != "http_request" {
		fail(errors.New("module emitted invalid HTTP bridge request"))
	}
	response := doHTTP(request)
	encoded, _ := json.Marshal(response)
	if _, err := childIn.Write(append(encoded, '\n')); err != nil {
		fail(fmt.Errorf("write module response: %w", err))
	}
	_ = childIn.Close()
	final, err := io.ReadAll(reader)
	if err != nil {
		fail(err)
	}
	_, _ = os.Stdout.Write(final)
	if err := cmd.Wait(); err != nil {
		fail(err)
	}
}

func doHTTP(request envelope) envelope {
	u, err := url.Parse(request.URL)
	allowed := err == nil && ((u.Scheme == "https" && u.Hostname() == "openrouter.ai") || (u.Scheme == "http" && (u.Hostname() == "localhost" || u.Hostname() == "127.0.0.1")))
	if !allowed {
		return envelope{Kind: "http_response", Status: 403, StatusText: "network destination denied"}
	}
	req, err := http.NewRequest(request.Method, u.String(), bytes.NewReader([]byte(request.Body)))
	if err != nil {
		return envelope{Kind: "http_response", Status: 400, StatusText: err.Error()}
	}
	for name, value := range request.Headers {
		req.Header.Set(name, value)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return envelope{Kind: "http_response", Status: 502, StatusText: err.Error()}
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return envelope{Kind: "http_response", Status: 502, StatusText: err.Error()}
	}
	return envelope{Kind: "http_response", Status: resp.StatusCode, StatusText: resp.Status, Body: string(body)}
}

func fail(err error) { fmt.Fprintln(os.Stderr, "picoclaw-wasi-bridge:", err); os.Exit(1) }
