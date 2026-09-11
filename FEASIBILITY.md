# PicoClaw WASI feasibility

## Result

The focused `picoclaw-wasi` entry point is feasible, but the unmodified
all-features tree does not build for WASI at the current revision. The exact
command `GOOS=wasip1 GOARCH=wasm go build ./...` fails in ten dependency paths:
`modernc.org/libc/{errno,limits,pthread,signal,stdio,time,unistd,sys/types}`,
`github.com/ergochat/readline/internal/platform`, and
`maunium.net/go/mautrix/crypto/libolm` all exclude their files under WASI.
This confirms that the existing all-features CLI must not be the capability
boundary; the focused entry point intentionally excludes those integrations.

## Compatibility table

| Component | Current implementation | WASI result | Recommended approach |
|---|---|---|---|
| Config | `pkg/config`, JSON/YAML, env-backed secrets | Compile-compatible; implicit home paths are unsafe | Explicit `/config` and runtime secret injection |
| Skills | `pkg/skills` reads workspace/global/builtin `SKILL.md` | Instruction-only loading is portable | Read-only explicit `/skills`; disable install/registry first |
| Workspace | OS files, JSONL/session/state/media | Portable with preopens | Rooted adapter; reject absolute and parent paths |
| Providers | HTTP/OpenAI-compatible and OpenRouter | Not reachable from Go `wasip1` Preview 1 `net` today; Go uses `net_fake.go` | Component Model HTTP/sockets or narrow host bridge |
| Local models | Configurable `api_base` | Loopback unavailable through current Go Preview 1 module | Explicit component/sockets adapter or host bridge |
| Listeners | `net.Listen`, gateway and channels | Not assumed in Preview 1 | stdin/stdout first; host HTTP later |
| Processes | `os/exec`, process hooks, shell tools | Must be unavailable | Compile out and return unsupported errors |
| MCP | Stdio subprocesses plus remote transports | Stdio incompatible with goal | Exclude stdio; defer remote MCP |
| Unix/POSIX | `syscall`, `x/sys`, Unix sockets, signals | Runtime-specific/unportable | Build tags or omit feature packages |
| PTY/TUI | `creack/pty`, readline/terminal UI | Not suitable | Plain stdin/stdout |
| Native integrations | WhatsApp/Matrix, SQLite-backed channels, WebRTC | Large/native closure | Exclude from milestone 1 |
| CGO/browser/updater | Native/browser/process assumptions | Not in minimal path | `CGO_ENABLED=0`; omit |

## Main blockers

The focused prototype has no compiler blocker. The full-tree build has the
dependency blockers listed above. Runtime evidence with Wasmtime 48.0.1 shows
that explicit preopens and skill/config loading work, but Go's `wasip1`
Preview 1 networking path could not resolve `api.openrouter.ai` and could not
connect to a local `127.0.0.1` mock server. This blocks the requested provider
path in the current Preview 1 module. The next technical investigation is a
WASI sockets or Component Model HTTP path, while preserving secure no-network
failure behavior.
