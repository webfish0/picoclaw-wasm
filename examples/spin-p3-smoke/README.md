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
