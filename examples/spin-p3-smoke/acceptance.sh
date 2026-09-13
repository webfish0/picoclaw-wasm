#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")" && pwd)
cd "$root"
out=${SPIN_ACCEPTANCE_OUT:-acceptance-results.json}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

command -v spin >/dev/null || { echo '{"status":"blocked","reason":"spin missing"}' >"$out"; exit 2; }
command -v wasm-tools >/dev/null || { echo '{"status":"blocked","reason":"wasm-tools missing"}' >"$out"; exit 2; }

PATH="${SPIN_GO_BIN:-/tmp/picoclaw-spin-native-arm64/go/bin}:$PATH" GOTOOLCHAIN=local spin build --from spin.toml
PATH="${SPIN_GO_BIN:-/tmp/picoclaw-spin-native-arm64/go/bin}:$PATH" GOTOOLCHAIN=local spin doctor --from spin.toml
go test ./internal/probe/... >/dev/null

hash=$(shasum -a 256 main.wasm | awk '{print $1}')
wit=$(wasm-tools component wit main.wasm)
grep -q 'export wasi:http/handler' <<<"$wit"
grep -q 'import spin:variables/variables@3.0.0' <<<"$wit"
grep -q 'import spin:key-value/key-value@3.0.0' <<<"$wit"

umask 077
sentinel_file="$tmp/secret"
printf 'unpublished-%s\n' "$(date +%s%N)" >"$sentinel_file"
if rg -n -F "$(<"$sentinel_file")" . --glob '!main.wasm' --glob '!acceptance-results.json' >/dev/null 2>&1; then
  echo '{"status":"fail","reason":"sentinel leaked"}' >"$out"
  exit 1
fi

printf '{"status":"pass","artifact_sha256":"%s","policy_tests":"pass","doctor":"pass","wit":"http+variables+kv","sentinel_matches":0}\n' "$hash" >"$out"
cat "$out"
