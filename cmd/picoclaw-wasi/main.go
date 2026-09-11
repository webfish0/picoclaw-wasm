// Command picoclaw-wasi is the minimal, capability-oriented PicoClaw entry point.
// It handles one prompt per process through stdin/stdout.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

type config struct {
	Model       string `json:"model"`
	APIBase     string `json:"api_base"`
	APIKeyEnv   string `json:"api_key_env"`
	SkillsRoot  string `json:"skills_root"`
	Workspace   string `json:"workspace"`
	AllowedHost string `json:"allowed_host"`
}

type chatRequest struct {
	Model    string        `json:"model"`
	Messages []chatMessage `json:"messages"`
}
type chatMessage struct{ Role, Content string }
type chatResponse struct {
	Choices []struct {
		Message chatMessage `json:"message"`
	} `json:"choices"`
}

func main() {
	cfgPath := os.Getenv("PICOCLAW_WASI_CONFIG")
	if cfgPath == "" {
		cfgPath = "/config/config.json"
	}
	cfg, err := loadConfig(cfgPath)
	if err != nil {
		fail(err)
	}
	prompt, err := bufio.NewReader(os.Stdin).ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		fail(fmt.Errorf("read prompt: %w", err))
	}
	prompt = strings.TrimSpace(prompt)
	if prompt == "" {
		fail(errors.New("prompt is empty"))
	}
	skillText, err := loadSkills(cfg.SkillsRoot)
	if err != nil {
		fail(err)
	}
	if err := validateRoot(cfg.Workspace, "workspace"); err != nil {
		fail(err)
	}
	answer, err := callProvider(cfg, skillText, prompt)
	if err != nil {
		fail(err)
	}
	fmt.Fprintln(os.Stdout, answer)
}

func fail(err error) { fmt.Fprintln(os.Stderr, "picoclaw-wasi:", err); os.Exit(1) }

func loadConfig(path string) (config, error) {
	if err := validateConfigPath(path); err != nil {
		return config{}, err
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return config{}, fmt.Errorf("read config: %w", err)
	}
	var c config
	if err := json.Unmarshal(b, &c); err != nil {
		return config{}, fmt.Errorf("parse config: %w", err)
	}
	if c.Model == "" || c.APIBase == "" || c.SkillsRoot == "" || c.Workspace == "" {
		return config{}, errors.New("config requires model, api_base, skills_root and workspace")
	}
	if c.APIKeyEnv == "" {
		c.APIKeyEnv = "OPENROUTER_API_KEY"
	}
	if c.AllowedHost == "" {
		c.AllowedHost = "api.openrouter.ai"
	}
	return c, nil
}

func validateConfigPath(path string) error {
	if filepath.IsAbs(path) && !strings.HasPrefix(filepath.Clean(path), "/config/") {
		return errors.New("config path must be under /config")
	}
	return validateRelative(filepath.Base(path))
}

func validateRoot(path, name string) error {
	if path == "" || !filepath.IsAbs(path) {
		return fmt.Errorf("%s must be an absolute preopened path", name)
	}
	if strings.Contains(path, "..") {
		return fmt.Errorf("%s traversal is forbidden", name)
	}
	return nil
}

func validateRelative(path string) error {
	if path == "" || path == "." || filepath.IsAbs(path) || path == ".." || strings.HasPrefix(path, ".."+string(filepath.Separator)) {
		return errors.New("path traversal is forbidden")
	}
	return nil
}

func loadSkills(root string) (string, error) {
	if err := validateRoot(root, "skills_root"); err != nil {
		return "", err
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return "", fmt.Errorf("read skills: %w", err)
	}
	var b strings.Builder
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		name := entry.Name()
		if err := validateRelative(name); err != nil {
			return "", err
		}
		path := filepath.Join(root, name, "SKILL.md")
		content, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		b.WriteString("\n<skill name=\"")
		b.WriteString(name)
		b.WriteString("\">\n")
		b.Write(content)
		b.WriteString("\n</skill>\n")
	}
	return b.String(), nil
}

func callProvider(c config, skills, prompt string) (string, error) {
	u, err := url.Parse(c.APIBase)
	if err != nil || u.Scheme != "https" && u.Hostname() != "localhost" && u.Hostname() != "127.0.0.1" {
		return "", errors.New("api_base must use HTTPS or localhost")
	}
	if u.Hostname() != c.AllowedHost && !(u.Hostname() == "localhost" || u.Hostname() == "127.0.0.1") {
		return "", fmt.Errorf("network destination %q is not allowed", u.Hostname())
	}
	key := os.Getenv(c.APIKeyEnv)
	if key == "" {
		return "", fmt.Errorf("missing runtime secret %s", c.APIKeyEnv)
	}
	body, _ := json.Marshal(chatRequest{Model: c.Model, Messages: []chatMessage{{Role: "system", Content: "You are PicoClaw-WASI.\n" + skills}, {Role: "user", Content: prompt}}})
	req, err := http.NewRequest(http.MethodPost, strings.TrimRight(c.APIBase, "/")+"/chat/completions", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("provider request: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("provider returned HTTP %s", resp.Status)
	}
	var decoded chatResponse
	if err := json.NewDecoder(resp.Body).Decode(&decoded); err != nil {
		return "", fmt.Errorf("decode provider response: %w", err)
	}
	if len(decoded.Choices) == 0 {
		return "", errors.New("provider response contained no choices")
	}
	return decoded.Choices[0].Message.Content, nil
}
