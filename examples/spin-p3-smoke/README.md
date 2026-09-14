# Spin P3 smoke component

This isolated component proves the Spin 4.1 HTTP handler and direct outbound
request path. It uses the pinned Spin Go SDK v3.0.0, `componentize-go` v0.3.3,
and `go.bytecodealliance.org/pkg` v0.2.1.

Run the host-compilable policy tests with:

```sh
(cd examples/spin-p3-smoke && go test ./internal/probe/...)
```

Build and inspect the manifest with:

```sh
spin build --from examples/spin-p3-smoke/spin.toml
spin doctor --from examples/spin-p3-smoke/spin.toml
```

The probe accepts only `http://127.0.0.1:18080`; an origin-only value is
canonicalized to `/`, while userinfo, other scheme/host/port values, queries,
and fragments are rejected. The exact outbound grant remains in `spin.toml`.

The generated Spin export glue is not host-testable on this macOS target, so
the focused policy package is tested separately and the component is verified
with Spin build/doctor and black-box runtime checks.

Run the reproducible capability gate with:

```sh
SPIN_ACCEPTANCE_OUT=/tmp/spin-acceptance.json ./examples/spin-p3-smoke/acceptance.sh
```

It rebuilds and diagnoses the component, runs policy tests, checks the WIT
imports/exports, records one artifact hash, and performs a zero-match scan
using a mode-0600 temporary secret file. Runtime restart/concurrency evidence
must be added by the launcher UAT harness before this capability issue closes.

The latest secret-free runtime transcript is committed at
`evidence/runtime-39d6cae3.json`; it is tied to commit `39d6cae3` and records
the exact artifact hash and result counts without recording the sentinel.
