#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd)
cd "$root"
out=${SPIN_ACCEPTANCE_OUT:-runtime-acceptance-results.json}
port=${SPIN_ACCEPTANCE_PORT:-31080}
tmp=$(mktemp -d); spin_pid=0
trap '[[ $spin_pid -eq 0 ]] || kill "$spin_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
umask 077; secret="$tmp/secret"; printf 'runtime-undisclosed-%s\n' "$(date +%s%N)" >"$secret"
PATH="${SPIN_GO_BIN:-/tmp/picoclaw-spin-native-arm64/go/bin}:$PATH" GOTOOLCHAIN=local spin build --from spin.toml >/dev/null
spin up --from spin.toml --listen "127.0.0.1:$port" --variable "probe_secret=@$secret" --runtime-config-file runtime-config.toml >"$tmp/spin.stdout" 2>"$tmp/spin.stderr" & spin_pid=$!
for _ in {1..100}; do curl -sS "http://127.0.0.1:$port/probe" -o /dev/null >/dev/null 2>&1 && break; sleep 0.1; done
request() { curl -fsS -X POST "http://127.0.0.1:$port/probe" -H "X-Request-ID: $1" --data "$1"; }
first=$(request runtime-seq-1); second=$(request runtime-seq-2)
grep -q 'request_id=runtime-seq-1' <<<"$first"; grep -q 'request_id=runtime-seq-2' <<<"$second"
for n in $(seq 1 20); do request "runtime-concurrent-$n" >"$tmp/response-$n" & done
wait
for n in $(seq 1 20); do grep -q "request_id=runtime-concurrent-$n" "$tmp/response-$n"; done
sentinel=$(<"$secret")
if rg -n -F "$sentinel" "$tmp" . --glob '!main.wasm' --glob '!runtime-acceptance-results.json' >/dev/null 2>&1; then echo '{"status":"fail","reason":"sentinel leaked"}' >"$out"; exit 1; fi
hash=$(shasum -a 256 main.wasm | awk '{print $1}')
printf '{"status":"pass","artifact_sha256":"%s","sequential":2,"concurrent":20,"sentinel_matches":0}\n' "$hash" >"$out"; cat "$out"
