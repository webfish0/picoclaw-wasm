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
  go run ./mock >"$tmp/mock.stdout" 2>"$tmp/mock.stderr" & mock_pid=$!
  for _ in {1..100}; do curl -sS "$mock_url" -o /dev/null >/dev/null 2>&1 && break; sleep 0.1; done
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
first=$(request runtime-seq-1); second=$(request runtime-seq-2)
grep -q 'request_id=runtime-seq-1' <<<"$first"; grep -q 'request_id=runtime-seq-2' <<<"$second"
grep -q 'stored_id=runtime-seq-1' <<<"$first"; grep -q 'stored_id=runtime-seq-2' <<<"$second"
grep -Eq 'denied_store_class=(access-denied|no-such-store|denied)' <<<"$first"
grep -q 'fixtures=read-only' <<<"$first"; grep -q 'BROWSER_UAT_OK' <<<"$first"
request_pids=()
for n in $(seq 1 20); do request "runtime-concurrent-$n" >"$tmp/response-$n" & request_pids+=("$!"); done
for pid in "${request_pids[@]}"; do wait "$pid"; done
for n in $(seq 1 20); do
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
grep -q 'preexisting=true' <<<"$restart"
grep -q 'previous_id=runtime-seq-1' <<<"$restart"
sentinel=$(<"$secret")
scan_targets=("$tmp/spin.stdout" "$tmp/spin.stderr" "$tmp/restart.stdout" "$tmp/restart.stderr" "$tmp/mock.stdout" "$tmp/mock.stderr" "$tmp"/response-* "$tmp/workspace.db" main.wasm)
if rg -a -n -F "$sentinel" "${scan_targets[@]}" >/dev/null 2>&1; then echo '{"status":"fail","reason":"sentinel leaked"}' >"$out"; exit 1; fi
hash=$(shasum -a 256 main.wasm | awk '{print $1}')
config_hash=$(shasum -a 256 fixtures/config.json | awk '{print $1}')
skill_hash=$(shasum -a 256 fixtures/SKILL.md | awk '{print $1}')
spin_version=$(spin --version | head -1)
go_version=$(go version)
printf '{"status":"pass","artifact_sha256":"%s","missing_secret":"fail-closed-exact-variable-error","sequential":2,"concurrent":20,"restart":"pass","mock_pid":%s,"spin_pid":%s,"kv_state":"%s/workspace.db","fixture_sha256":{"config":"%s","skill":"%s"},"tool_versions":{"spin":"%s","go":"%s"},"sentinel_matches":0}\n' "$hash" "$mock_pid" "$spin_pid" "$tmp" "$config_hash" "$skill_hash" "$spin_version" "$go_version" >"$out"; cat "$out"
