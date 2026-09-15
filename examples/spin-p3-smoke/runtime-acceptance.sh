#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd)
cd "$root"
out=${SPIN_ACCEPTANCE_OUT:-runtime-acceptance-results.json}
port=${SPIN_ACCEPTANCE_PORT:-31080}
mock_url=${SPIN_PROBE_MOCK_URL:-http://127.0.0.1:18080/}
tmp=$(mktemp -d); spin_pid=0; mock_pid=0
trap '[[ $spin_pid -eq 0 ]] || kill "$spin_pid" 2>/dev/null || true; [[ $mock_pid -eq 0 ]] || kill "$mock_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
umask 077; secret="$tmp/secret"; printf 'runtime-undisclosed-%s\n' "$(date +%s%N)" >"$secret"
runtime_cfg="$tmp/runtime-config.toml"
printf '[key_value_store.workspace]\ntype = "spin"\npath = "%s"\n' "$tmp/workspace.db" >"$runtime_cfg"
artifact_backup="$tmp/main.wasm.backup"
cp main.wasm "$artifact_backup"
if [[ "$mock_url" == "http://127.0.0.1:18080/" ]]; then
  if command -v lsof >/dev/null && lsof -nP -t -iTCP:18080 -sTCP:LISTEN >"$tmp/port-owner"; then
    echo '{"status":"fail","reason":"port 18080 already has a listener; deterministic mock cannot own it"}' >"$out"
    exit 1
  fi
  mock_marker="owned-$(date +%s%N)-$$"
  mock_receipts="$tmp/mock.receipts"
  go build -o "$tmp/mock" ./mock
  SPIN_PROBE_MOCK_MARKER="$mock_marker" SPIN_PROBE_MOCK_RECEIPTS="$mock_receipts" "$tmp/mock" >"$tmp/mock.stdout" 2>"$tmp/mock.stderr" & mock_pid=$!
  mock_ready=0
  for _ in {1..100}; do
    if [[ "$(curl --fail --silent --show-error --max-time 1 "http://127.0.0.1:18080/_health" 2>/dev/null || true)" == "$mock_marker" ]] && kill -0 "$mock_pid" 2>/dev/null; then
      mock_ready=1
      break
    fi
    sleep 0.1
  done
  if [[ "$mock_ready" -ne 1 ]]; then
    echo '{"status":"fail","reason":"deterministic mock did not become ready; check port 18080 ownership"}' >"$out"
    exit 1
  fi
fi
if ! PATH="${SPIN_GO_BIN:-/tmp/picoclaw-spin-native-arm64/go/bin}:$PATH" GOTOOLCHAIN=local spin build --from spin.toml >/dev/null; then
  cp "$artifact_backup" main.wasm
  echo '{"status":"fail","reason":"spin build failed; prior artifact restored"}' >"$out"
  exit 1
fi
if [[ "$(xxd -p -l 4 main.wasm)" != "0061736d" ]]; then
  cp "$artifact_backup" main.wasm
  echo '{"status":"fail","reason":"spin build produced invalid wasm; prior artifact restored"}' >"$out"
  exit 1
fi
if spin up --from spin.toml --listen "127.0.0.1:$port" --runtime-config-file "$runtime_cfg" >"$tmp/missing.stdout" 2>"$tmp/missing.stderr"; then
  echo '{"status":"fail","reason":"missing secret did not fail closed"}' >"$out"; exit 1
fi
grep -q 'no provider resolved required variable' "$tmp/missing.stderr"
spin up --from spin.toml --listen "127.0.0.1:$port" --env "SPIN_PROBE_MOCK_URL=$mock_url" --variable "probe_secret=@$secret" --runtime-config-file "$runtime_cfg" >"$tmp/spin.stdout" 2>"$tmp/spin.stderr" & spin_pid=$!
for _ in {1..100}; do curl -sS "http://127.0.0.1:$port/probe" -o /dev/null >/dev/null 2>&1 && break; sleep 0.1; done
request() { curl -fsS -X POST "http://127.0.0.1:$port/probe" -H "X-Request-ID: $1" --data "$1"; }
mock_receipt() {
  [[ "$mock_pid" -ne 0 ]] || return 0
  local digest
  digest=$(printf '%s' "$1" | shasum -a 256 | awk '{print $1}')
  rg -q -F "$digest" "$mock_receipts"
}
mock_response() {
  [[ "$mock_pid" -ne 0 ]] || return 0
  grep -q "mock_run=$mock_marker" <<<"$1"
  kill -0 "$mock_pid" 2>/dev/null
}
first=$(request runtime-seq-1); second=$(request runtime-seq-2)
mock_response "$first"; mock_response "$second"
mock_receipt runtime-seq-1; mock_receipt runtime-seq-2
grep -q 'request_id=runtime-seq-1' <<<"$first"; grep -q 'request_id=runtime-seq-2' <<<"$second"
grep -q 'stored_id=runtime-seq-1' <<<"$first"; grep -q 'stored_id=runtime-seq-2' <<<"$second"
grep -Eq 'denied_store_class=(access-denied|no-such-store|denied)' <<<"$first"
grep -q 'fixtures=read-only' <<<"$first"; grep -q 'BROWSER_UAT_OK' <<<"$first"
request_pids=()
for n in $(seq 1 20); do request "runtime-concurrent-$n" >"$tmp/response-$n" & request_pids+=("$!"); done
for pid in "${request_pids[@]}"; do wait "$pid"; done
for n in $(seq 1 20); do
  mock_response "$(<"$tmp/response-$n")"
  mock_receipt "runtime-concurrent-$n"
  grep -q "request_id=runtime-concurrent-$n" "$tmp/response-$n"
  grep -q "stored_id=runtime-concurrent-$n" "$tmp/response-$n"
  if rg -a -F "stored_id=runtime-concurrent-" "$tmp/response-$n" | rg -v -F "stored_id=runtime-concurrent-$n" >/dev/null; then
    echo '{"status":"fail","reason":"concurrent request stored a foreign value"}' >"$out"; exit 1
  fi
done
kill "$spin_pid"; wait "$spin_pid" 2>/dev/null || true; spin_pid=0; sleep 1
spin up --from spin.toml --listen "127.0.0.1:$port" --env "SPIN_PROBE_MOCK_URL=$mock_url" --variable "probe_secret=@$secret" --runtime-config-file "$runtime_cfg" >"$tmp/restart.stdout" 2>"$tmp/restart.stderr" & spin_pid=$!
for _ in {1..100}; do curl -sS "http://127.0.0.1:$port/probe" -o /dev/null >/dev/null 2>&1 && break; sleep 0.1; done
restart=$(request runtime-seq-1)
mock_response "$restart"; mock_receipt runtime-seq-1
grep -q 'preexisting=true' <<<"$restart"
grep -q 'previous_id=runtime-seq-1' <<<"$restart"
sentinel=$(<"$secret")
scan_targets=("$tmp/spin.stdout" "$tmp/spin.stderr" "$tmp/restart.stdout" "$tmp/restart.stderr" "$tmp/mock.stdout" "$tmp/mock.stderr" "$tmp"/response-* "$tmp/workspace.db" main.wasm)
if [[ "$mock_pid" -ne 0 ]]; then scan_targets+=("$mock_receipts"); fi
if rg -a -n -F "$sentinel" "${scan_targets[@]}" >/dev/null 2>&1; then echo '{"status":"fail","reason":"sentinel leaked"}' >"$out"; exit 1; fi
scan_counts=""
for target in "${scan_targets[@]}"; do
  matches=$(rg -a -F -o "$sentinel" "$target" 2>/dev/null || true)
  if [[ -n "$matches" ]]; then matches=$(printf '%s\n' "$matches" | wc -l | tr -d ' '); else matches=0; fi
  scan_counts="${scan_counts}${target##*/}=${matches};"
done
hash=$(shasum -a 256 main.wasm | awk '{print $1}')
config_hash=$(shasum -a 256 fixtures/config.json | awk '{print $1}')
skill_hash=$(shasum -a 256 fixtures/SKILL.md | awk '{print $1}')
manifest_hash=$(shasum -a 256 spin.toml | awk '{print $1}')
wit_hash=$(wasm-tools component wit main.wasm | shasum -a 256 | awk '{print $1}')
spin_version=$(spin --version | head -1)
go_version=$(go version)
printf '{"status":"pass","artifact_sha256":"%s","missing_secret":"fail-closed-exact-variable-error","sequential":2,"concurrent":20,"restart":"pass","mock_pid":%s,"mock_run":"%s","mock_receipts":%s,"spin_pid":%s,"kv_state":"%s/workspace.db","fixture_sha256":{"config":"%s","skill":"%s"},"manifest_sha256":"%s","wit_sha256":"%s","tool_versions":{"spin":"%s","go":"%s"},"scan_counts":"%s","sentinel_matches":0}\n' "$hash" "$mock_pid" "${mock_marker:-external}" "$(if [[ "$mock_pid" -ne 0 ]]; then wc -l <"$mock_receipts" | tr -d ' '; else echo 0; fi)" "$spin_pid" "$tmp" "$config_hash" "$skill_hash" "$manifest_hash" "$wit_hash" "$spin_version" "$go_version" "$scan_counts" >"$out"; cat "$out"
