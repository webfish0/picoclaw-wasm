# Port status

Updated: 2026-09-12

## Completed

- Inspected the fork, Go version, entry points, dependencies and portability
  risks.
- Baseline `GOOS=wasip1 GOARCH=wasm go build ./...` was rechecked and fails in
  ten native dependency paths; the exact failures are recorded in
  FEASIBILITY.md. The focused WASI entry point builds successfully.
- Added repository-local feasibility, architecture, port-plan and agent rules.
- Added nine fully specified GitHub issues to the `wasm-claw` project, including
  phase tasks, the runtime decision, and measurable blockers. Issues are now
  enabled on the fork and duplicate draft cards were removed.
- Adopted milestone-1 runtime decision: Wasmtime plus the restricted native
  HTTP bridge. Direct Component Model networking is follow-on issue #10.
- Sol triage of Spin spike #14 isolated the local P3 outbound failure: the
  SDK v3.0.0 request converter rejects an origin-only mock URL because its
  path is empty. Keeping the exact loopback grant and canonicalising the
  runtime URL to `http://127.0.0.1:31808/` returned `SPIN_P3_OK` directly
  through Spin 4.1.0 under the required componentize-go v0.3.3 pin.
- Split the remaining #14 work into bounded board sub-issues #18–#21 for
  reproducibility, outbound-denial evidence, variable/file/store/isolation
  evidence, and the final WIT/measurement/Sol gate.
- Implemented `cmd/picoclaw-wasi` with explicit config, instruction-only skill
  loading, rooted-path validation and OpenAI-compatible provider requests.
- Added deterministic provider/path/secret tests, Make targets, example config
  and example `SKILL.md`.
- Added and verified `picoclaw-wasi-bridge`, a native allowlisted HTTP adapter
  that completes a real mock OpenAI-compatible request without adding sockets
  or subprocess authority to the WASM module.
- Added a workspace-bound prompt persistence check, proving the prototype uses
  the declared read/write workspace capability without implicit home/temp paths.
- `make wasi` produced a 10.1 MiB WebAssembly MVP module.
- Bridge measurements: 10.1 MiB WASM, 8.5 MiB native bridge, approximately
  0.84 s cold end-to-end process time and 72.99 MiB peak RSS on this macOS host.

## Current blockers

- Wasmtime 48.0.1 is installed and executes the module with explicit preopens;
  the measured cold run was about 70 ms in the local test.
- Direct Go `wasip1` networking remains unavailable under Wasmtime; the
  limitation is resolved for the milestone through the restricted bridge and is
  tracked as follow-on issue #10.
- Local Go source inspection confirms `net_fake.go` is selected for `wasip1`,
  so Wasmtime network flags cannot provide real host TCP to this module.
- Direct in-module provider networking remains unavailable; the verified
  working deployment currently requires the restricted native bridge.
- Spin spike #14 is resolvable but not complete. The checked-out smoke module
  still has incomplete test wiring, no complete
  negative-network/secret/storage/concurrency evidence, no WIT inspection or
  measurements, and no final Sol GO/NO-GO for #11.
- `wasm-tools` v1.259.0 is now installed and
  `wasm-tools component wit examples/spin-p3-smoke/main.wasm` confirms the
  expected `wasi:http/handler@0.3.0-rc-2026-03-15` export and standard WASI
  HTTP client imports. Runtime capability effectiveness still requires the
  negative matrix.
- The isolated Spin P3 smoke now includes the Sol-approved required variable,
  read-only fixture mappings, and one named persistent `workspace` KV store.
  WIT inspection confirms `spin:variables/variables@3.0.0` and
  `spin:key-value/key-value@3.0.0`; missing-variable startup fails closed and
  the supplied-variable direct mock request returns HTTP 200 with a matched
  correlation ID. Restart/concurrency, sentinel scans, and final Sol GO remain
  outstanding.
- Prerequisite #13 has a successful native ARM64 template build/start, but its
  remaining WIT and reproducibility evidence must be completed before #14 can
  close.

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
- `go test ./cmd/picoclaw-wasi-bridge`: bridge allowlist/response test passed.
- Native bridge integration: mock request returned `bridge ok`.
- Provider examples now target OpenRouter model
  `nvidia/nemotron-3-ultra-550b-a55b:free` with runtime secret `ORkey`, plus
  local model `1kb/huihui-qwen3.8-27b-mlx` through Ollama at `127.0.0.1:11434`.
- Real OpenRouter smoke now uses the official `https://openrouter.ai/api/v1`
  endpoint and reaches the service through the restricted bridge. After a new
  profile session loaded the updated `ORkey`, authentication succeeded; the
  requested Nvidia free-model route currently reports an upstream provider
  overload (`provider_unavailable`, HTTP 502 in the direct diagnostic). Live
  model success is therefore dependent on provider availability, not WASI or
  credential transport.
- The user-supplied exact streaming `curl -N` payload was rerun in a fresh
  profile session with `OPENROUTER_API_KEY` mapped from `ORkey`. OpenRouter
  returned SSE chunks and the final event identified Nvidia
  `provider_unavailable` / HTTP 502 `Service temporarily overloaded`, proving
  the same result independently of PicoClaw.
- Spin 4.1.0 smoke test: direct `spin up -f build/picoclaw-wasi.wasm` failed
  with the expected missing supported HTTP/component export; this is recorded
  as a runtime compatibility result, not a silent failure.
- Focused #14 diagnostic: exact-pinned Spin P3 build and `spin doctor` passed;
  the origin-only loopback URL returned the classified error
  `HTTP request URI invalid`, while the same exact origin with path `/`
  returned HTTP 200 with `SPIN_P3_OK` and `BROWSER_UAT_OK`. The 10,407,829-byte
  artifact SHA-256 was
  `c693b46a2509ca15613a761b0333f3c14402d01ed1df6666a77e88bd679d5acd`.
- Spin P3 direct cold-start measurement against the deterministic loopback mock
  passed 10/10 on port 3030: 92, 149, 153, 155, 156, 157, 160, 160, 161,
  165 ms; median 156 ms and observed nearest-rank p95 165 ms. Each request
  used a unique correlation ID and the legacy bridge/Wasmtime processes were
  stopped.
- Native `go test .` for the nested P3 component remains unavailable because
  SDK-generated export glue has a missing function body on the host target;
  #18 must extract host-testable logic and use a black-box runtime check.
- Added optional OCI distribution guidance. `oras` is not installed locally, so
  no registry push or digest verification is claimed.
- The first `make wasi-test` attempt exposed the expected limitation that a
  macOS host cannot execute a WASI test binary directly (`exec format error`);
  the target now compiles the WASI test artifact and runs the tests natively.
- Full human-style browser UAT passed through the localhost adapter: browser
  POST → `picoclaw-wasi-http` → restricted bridge → Wasmtime → WASI module →
  Ollama model `1kb/huihui-qwen3.8-27b-mlx`; visible response was
  `BROWSER_UAT_OK`. The earlier direct browser page was not this path.
- Fresh macOS measurements: `build/picoclaw-wasi.wasm` is 10,604,882 bytes;
  idle Wasmtime RSS was 70.9 MiB; one local-model bridge request peaked at
  73.1 MiB and completed in 9.76 s (including local model inference). Docker
  is not installed on this host, so no Docker baseline is claimed.

## Remediation checkpoint

Commits `46b15621` and `18cc45f4` constrain and host-test request IDs and add
a reproducible capability acceptance gate. The gate passed focused policy
tests, Spin build/doctor, WIT checks, and a zero-match scan using a mode-0600
temporary sentinel; artifact hash was
`cd5de0679d220d6d92ca801bdecd5ee796569ef6940fef38c6fb432b28a38286`.
This does not claim the remaining black-box restart/concurrency matrix or
launcher/browser UAT.

## Next action

Keep #11 blocked and complete the runtime restart/concurrency and denied-
resource harness for #20, then #21 with final Sol re-review. Formally complete
#13 before #21. Continue to use the verified bridge path for the existing
prototype until direct Spin launcher integration and #15 real-browser UAT pass;
human approval remains required before merge.

## Spin capability-closure remediation (PR #29)

The scoped Spin harness now rebuilds and hashes the committed component before
the run, records WIT/manifest/tool/host/process/port/state metadata, owns and
verifies its deterministic mock and Spin listeners, injects the required secret
only by a mode-0600 file path, and cleans up only processes whose command and
listener ownership match. It exercises missing, empty and whitespace secret
cases; separate default/ungranted store error classes; generated and explicit
request IDs; sequential and 20-way concurrent KV ownership; restart read-before
overwrite; fixture immutability and denied writes; a named existing repository
file denial; and per-target secret scans including the final evidence file.

The clean-checkout #20 gate passed on 2026-09-14 and published its direct
transcript at `examples/spin-p3-smoke/runtime-acceptance-results.json`. The
transcript's source commit is `bd9c496d84c7d195343bd1a48a4770604bf40f6a` and
the transcript is committed separately as the publication record; it reports
`clean_checkout_before: true`, the exact committed-and-run `main.wasm` hash
`528ac70eaacfca3dd10a3078382c1c3606dc68aec3b9fbf4f74e5ccebe303880` (10,960,440
bytes), 25 mock receipts, the full final KV map, owned launcher/listener PIDs,
and zero matches for every scanned secret target. The public snapshot route is
removed: empty and whitespace secret modes receive 404 for both `/snapshot`
and `/probe`. After both Spin processes stop, the harness reads only its
task-owned SQLite state and proves the exact 24-key map in
`spin_key_value(store,key,value)` with no extras. It scans the two hidden
`.spin/logs` component logs directly, scans launcher logs separately, and
removes only the run-created `.spin` directory. It records the actual host
kernel/hardware/process translation and `file` output for each tool binary.
The scoped binary diff is bounded at 16,000,000 bytes and was 3,425,790 bytes
from `origin/main` merge-base `0f97ca842ceb709dba412051d3db22530f7172e5`.
The dedicated mock origin is 31808; an unrelated listener on a different port
was left untouched.

This evidence satisfies the implementation gate but does not self-approve the
protected capability boundary. #20, #23, and #24 remain open pending the
required independent named Sol review and human merge approval.
