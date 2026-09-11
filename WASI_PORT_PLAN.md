# WASI port plan

1. Evidence: source inventory, baseline WASI build and feasibility documents.
2. Runtime decision: measure Wasmtime and Spin; choose the first prototype
   runtime with a board decision record.
3. Core: add `cmd/picoclaw-wasi` with explicit config, skills, rooted workspace,
   stdin/stdout and provider interface.
4. Boundaries: add path, secret, destination and unsupported-capability tests.
5. Providers: test OpenRouter and local OpenAI-compatible endpoints with a mock.
6. Packaging: Make targets, examples, README, runtime smoke test and memory/
   startup/artifact measurements.
7. Follow-on: component skills, Telegram/HTTP bridge, local-first fallback,
   Preview 2/Component Model evaluation and optional OCI artifact.
