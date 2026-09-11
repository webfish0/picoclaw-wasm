# PicoClaw-WASI architecture

The first artifact is a single-request WASI module:

`stdin prompt -> config + instruction SKILL.md -> OpenAI-compatible provider -> stdout response`

Host-granted capabilities are limited to read-only `/config`, read-only
`/skills`, read/write `/workspace`, selected environment variables/secrets, and
an outbound provider allowlist (`api.openrouter.ai` plus one configured local
model host). The current Go Preview 1 module has no host-network provider path;
the eventual component/bridge must enforce this allowlist. There is no
home-directory preopen, process capability, listener, PTY, Unix socket,
arbitrary fetch or stdio MCP.

Use Wasmtime first for the filesystem/stdin/stdout prototype because explicit
WASI Preview 1 preopens and environment controls are straightforward. Runtime
testing shows that this Go Preview 1 module cannot currently reach DNS or
localhost sockets, so provider calls are a verified blocker rather than a
claimed feature. Evaluate Spin/WASI sockets or a Component Model HTTP adapter
as the next provider path. OCI is distribution only; it does not replace
runtime capability policy.

The verified interim deployment is `picoclaw-wasi-bridge`: a native macOS
helper launches Wasmtime, passes only the three declared preopens, receives a
single provider request over the module's stdin/stdout protocol, enforces the
provider host allowlist, performs HTTP, and returns only the response body.
The bridge is not available to skills or model output and is not embedded in
the WASM artifact. A future Component Model HTTP implementation can replace it
without changing the agent/provider contract.

Skills are untrusted prompt data in milestone 1: no scripts, shell commands or
MCP references execute. Future WASM component skills receive explicit,
non-inherited capabilities per skill. Model inference remains native on macOS
through OpenRouter or an OpenAI-compatible Ollama/MLX/LM Studio endpoint.
