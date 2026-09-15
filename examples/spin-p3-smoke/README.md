# Spin P3 smoke component

This isolated component proves the Spin 4.1 HTTP handler and direct outbound
request path. It uses the pinned Spin Go SDK v3.0.0, `componentize-go` v0.3.3,
and `go.bytecodealliance.org/pkg` v0.2.1.

Select the native ARM64 Go toolchain before running Spin or the harness. On
this macOS host the official Go 1.27.1 binary is `/opt/homebrew/bin/go`:

```sh
export PATH="/opt/homebrew/bin:$PATH"
export SPIN_GO_BIN=/opt/homebrew/bin
go version
```

Run the host-compilable policy tests with:

```sh
(cd examples/spin-p3-smoke && go test ./internal/probe/...)
```

Build and inspect the manifest with:

```sh
spin build --from examples/spin-p3-smoke/spin.toml
spin doctor --from examples/spin-p3-smoke/spin.toml
```

Start the deterministic mock from `examples/spin-p3-smoke` with `go run ./mock`
and confirm it owns free port `127.0.0.1:18080`. If that port is occupied,
identify its owner before using the response as acceptance evidence.
The owned runtime harness checks a fresh mock `/_health` run marker, matches
that marker in Spin responses, and matches SHA-256 receipts for every positive
request. It fails when another listener owns 18080; stop only processes your
run started.

Start Spin with the tracked runtime configuration for its named `workspace`
store. Plain `spin up` fails with `unknown key_value_stores label "workspace"`
because the manifest grant alone does not select a store backend:

```sh
mkdir -p examples/spin-p3-smoke/.spin
spin up --from examples/spin-p3-smoke/spin.toml \
  --runtime-config-file examples/spin-p3-smoke/runtime-config.toml \
  --listen 127.0.0.1:3014 \
  --env 'SPIN_PROBE_MOCK_URL=http://127.0.0.1:18080/' \
  --variable 'probe_secret=@/path/to/secret'
curl --fail-with-body --show-error -X POST \
  -H 'X-Request-ID: smoke-001' --data 'SPIN_P3_OK' \
  http://127.0.0.1:3014/probe
```

Create the secret file outside the repository and inject it only at runtime;
never print or commit it. The runtime config sets only `.spin/workspace.db`
and is not a substitute for the required secret or mock URL.

The probe accepts only `http://127.0.0.1:18080`; an origin-only value is
canonicalized to `/`, while userinfo, other scheme/host/port values, queries,
and fragments are rejected. The exact outbound grant remains in `spin.toml`.

The generated Spin export glue is not host-testable on this macOS target, so
the focused policy package is tested separately and the component is verified
with Spin build/doctor and black-box runtime checks.

Run the reproducible capability gate with:

```sh
SPIN_ACCEPTANCE_OUT=/tmp/spin-acceptance.json ./examples/spin-p3-smoke/acceptance.sh
SPIN_ACCEPTANCE_OUT=/tmp/spin-runtime-acceptance.json \
  ./examples/spin-p3-smoke/runtime-acceptance.sh
```

It rebuilds and diagnoses the component, runs policy tests, checks the WIT
imports/exports, records one artifact hash, and performs a zero-match scan
using a mode-0600 temporary secret file. The runtime acceptance harness also
checks restart/concurrency and requires its own mock to become ready; a port
collision fails the check instead of accepting an unrelated service. Launcher
and visible-browser UAT are separate gates.

The outbound matrix uses test-only manifests in `testdata/matrix/`. Its allowed
variant grants exactly `http://127.0.0.1:18090` to a task-owned mock and,
separately, `http://mock.spin.internal` for an in-process private component.
The empty variant grants no outbound hosts. The `/matrix` route is enabled only
by these test manifests and accepts fixed case names, never a caller-supplied
URL. This 18090 control does not substitute for the required owned 18080 run
on the production smoke manifest. In the 2026-09-15 control, Spin denied wrong
scheme, host and port, while a direct URL containing userinfo reached the
allowed mock; the normal `/probe` URL validator rejects userinfo before
outbound. Issue #19 records the specialist review of that difference and the
redirect/raw-socket limits before any final capability claim.

For startup measurements, use the same runtime configuration and record ten
valid cold starts, request latency, idle RSS, and peak RSS with the host and
artifact under test. Do not include starts that failed before readiness.

The latest secret-free runtime transcript is committed at
`evidence/runtime-39d6cae3.json`; it is tied to commit `39d6cae3` and records
the exact artifact hash and result counts without recording the sentinel.
