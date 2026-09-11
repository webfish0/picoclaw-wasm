# Port status

Updated: 2026-09-11

## Completed

- Inspected the fork, Go version, entry points, dependencies and portability
  risks.
- Baseline `GOOS=wasip1 GOARCH=wasm go build ./...` was rechecked and fails in
  ten native dependency paths; the exact failures are recorded in
  FEASIBILITY.md. The focused WASI entry point builds successfully.
- Added repository-local feasibility, architecture, port-plan and agent rules.
- Added eight fully specified draft items to the `wasm-claw` GitHub project,
  including runtime decision and visible Issues-disabled blocker.
- Implemented `cmd/picoclaw-wasi` with explicit config, instruction-only skill
  loading, rooted-path validation and OpenAI-compatible provider requests.
- Added deterministic provider/path/secret tests, Make targets, example config
  and example `SKILL.md`.
- `make wasi` produced a 10.1 MiB WebAssembly MVP module.

## Current blockers

- GitHub Issues are disabled on `webfish0/picoclaw-wasm`; draft project items
  are the active workaround. Human must enable Issues or confirm draft-only
  governance.
- Wasmtime 48.0.1 is installed and executes the module with explicit preopens;
  the measured cold run was about 70 ms in the local test.
- Go `wasip1` under Wasmtime could not resolve OpenRouter DNS and could not
  connect to a local mock socket. This is the active provider/network blocker.

## Tests and failures

- Focused WASI build: passed.
- Full-tree WASI build: expected failure in modernc libc, readline platform and
  libolm dependency paths; this remains a Phase 0 compatibility finding.
- `go test ./cmd/picoclaw-wasi`: 3 tests passed.
- `make wasi`: passed; WebAssembly module produced.
- `make wasi-test`: passed; native tests passed and a 12.6 MiB WASI test
  artifact compiled without attempting to execute it on macOS.
- `git diff --check`: passed.
- Wasmtime 48.0.1 filesystem/skill smoke test passed with three explicit
  preopens; provider smoke test failed at DNS/loopback as documented.
- The first `make wasi-test` attempt exposed the expected limitation that a
  macOS host cannot execute a WASI test binary directly (`exec format error`);
  the target now compiles the WASI test artifact and runs the tests natively.

## Next action

Keep Phase 0 open until its corrected compatibility evidence is reviewed. Then
evaluate a WASI sockets or Component Model HTTP path under Spin/Wasmtime, then
implement the provider adapter that matches the chosen runtime. Do not mark the
provider or runtime phases Done until a runtime-backed mock request succeeds.
