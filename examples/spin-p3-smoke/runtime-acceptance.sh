#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd); cd "$root"
tmp=$(mktemp -d "/tmp/picoclaw-spin-acceptance.XXXXXX")
out=${SPIN_ACCEPTANCE_OUT:-"$root/runtime-acceptance-results.json"}
port=${SPIN_ACCEPTANCE_PORT:-31080}; mock_port=31808
base_url="http://127.0.0.1:$port"; mock_url="http://127.0.0.1:$mock_port/"
spin_pid=0; spin_listener_pid=0; mock_pid=0; missing_pid=0; spin_exit="not-stopped"; first_spin_pid=0; first_spin_listener_pid=0; restart_spin_pid=0; restart_spin_listener_pid=0; first_spin_command=""; first_spin_listener_command=""; restart_spin_command=""; restart_spin_listener_command=""; first_spin_exit=""; restart_spin_exit=""
run_started=$(date -u '+%Y-%m-%dT%H:%M:%SZ'); commit=$(git rev-parse HEAD 2>/dev/null || printf unknown)
status_before=$(git status --porcelain 2>/dev/null || true)
state_path="$tmp/workspace.db"; runtime_cfg="$tmp/runtime-config.toml"; mock_receipts="$tmp/mock-receipts.jsonl"
spin_dir="$root/.spin"; component_logs_path="$spin_dir/logs"; spin_dir_preexisting=false; spin_dir_created=false; spin_dir_cleanup="not-needed"
[[ -e "$spin_dir" ]] && spin_dir_preexisting=true
clean_run_spin_dir() {
  if [[ "$spin_dir_preexisting" == false ]] && [[ -e "$spin_dir" ]]; then
    rm -rf "$spin_dir"; [[ ! -e "$spin_dir" ]] || fail "failed to remove run-created Spin directory"; spin_dir_cleanup="removed-run-created"
  elif [[ "$spin_dir_preexisting" == true ]]; then
    spin_dir_cleanup="preserved-preexisting"
  fi
}
cleanup() {
  if [[ "$spin_pid" != 0 ]] && kill -0 "$spin_pid" 2>/dev/null; then
    command=$(ps -p "$spin_pid" -o command= 2>/dev/null || true); [[ "$command" == *"spin up"* ]] && kill "$spin_pid" 2>/dev/null || true
  fi
  if [[ "$spin_listener_pid" != 0 ]] && [[ "$spin_listener_pid" != "$spin_pid" ]] && kill -0 "$spin_listener_pid" 2>/dev/null; then
    command=$(ps -p "$spin_listener_pid" -o command= 2>/dev/null || true); [[ "$command" == *"spin"* ]] && kill "$spin_listener_pid" 2>/dev/null || true
  fi
  if [[ "$mock_pid" != 0 ]] && kill -0 "$mock_pid" 2>/dev/null; then
    command=$(ps -p "$mock_pid" -o command= 2>/dev/null || true); [[ "$command" == *"$tmp/mock"* ]] && kill "$mock_pid" 2>/dev/null || true
  fi
  if [[ "$missing_pid" != 0 ]] && kill -0 "$missing_pid" 2>/dev/null; then
    command=$(ps -p "$missing_pid" -o command= 2>/dev/null || true); [[ "$command" == *"spin up"* ]] && kill "$missing_pid" 2>/dev/null || true
  fi
  clean_run_spin_dir
  rm -rf "$tmp"
}
trap cleanup EXIT
fail() { local reason=$1; mkdir -p "$(dirname "$out")"; jq -n --arg reason "$reason" --arg commit "$commit" --arg started "$run_started" '{status:"fail",reason:$reason,commit:$commit,started_utc:$started}' >"$out"; exit 1; }
for tool in spin wasm-tools go curl jq rg lsof ps shasum xxd python3 file uname sysctl find; do command -v "$tool" >/dev/null 2>&1 || fail "missing tool: $tool"; done
[[ -z "$status_before" ]] || fail "checkout is not clean before runtime gate"
assert_free() { if lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; then fail "port already owned: $1"; fi; }
owned() { local pid=$1 pattern=$2 command; kill -0 "$pid" 2>/dev/null || fail "owned process exited: $pid"; command=$(ps -p "$pid" -o command= 2>/dev/null || true); [[ "$command" == *"$pattern"* ]] || fail "ownership mismatch pid=$pid command=$command"; }
wait_http() { local url=$1 body=$2 code=000; for _ in $(seq 1 120); do if code=$(curl -sS -o "$body" -w '%{http_code}' "$url" 2>/dev/null); then :; else code=000; fi; [[ "$code" != 000 ]] && { printf '%s' "$code"; return; }; sleep 0.1; done; printf '%s' "$code"; return 1; }
start_spin() {
  local label=$1 secret_file=${2:-}; assert_free "$port"
  if [[ -n "$secret_file" ]]; then
    PATH="${SPIN_GO_BIN:-/tmp/picoclaw-spin-native-arm64/go/bin}:$PATH" GOTOOLCHAIN=local spin up --from spin.toml --listen "127.0.0.1:$port" --env "SPIN_PROBE_MOCK_URL=$mock_url" --variable "probe_secret=@$secret_file" --runtime-config-file "$runtime_cfg" >"$tmp/$label.stdout" 2>"$tmp/$label.stderr" &
  else
    PATH="${SPIN_GO_BIN:-/tmp/picoclaw-spin-native-arm64/go/bin}:$PATH" GOTOOLCHAIN=local spin up --from spin.toml --listen "127.0.0.1:$port" --env "SPIN_PROBE_MOCK_URL=$mock_url" --runtime-config-file "$runtime_cfg" >"$tmp/$label.stdout" 2>"$tmp/$label.stderr" &
  fi
  spin_pid=$!; owned "$spin_pid" "spin up"; local code listener listener_ppid listener_command; code=$(wait_http "$base_url/probe" "$tmp/$label.ready" || true)
  if [[ "$code" == 000 ]]; then kill -0 "$spin_pid" 2>/dev/null && fail "$label did not become ready"; return 1; fi
  owned "$spin_pid" "spin up"; spin_listener_pid=0
  while read -r listener; do
    [[ -n "$listener" ]] || continue
    listener_ppid=$(ps -p "$listener" -o ppid= 2>/dev/null | tr -d ' '); listener_command=$(ps -p "$listener" -o command= 2>/dev/null || true)
    if [[ "$listener" == "$spin_pid" || "$listener_ppid" == "$spin_pid" ]] && [[ "$listener_command" == *"spin"* ]]; then
      spin_listener_pid=$listener; break
    fi
  done < <(lsof -nP -t -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | sort -u)
  [[ "$spin_listener_pid" != 0 ]] || fail "$label listener ownership mismatch"
  if [[ "$label" == success ]]; then first_spin_listener_pid="$spin_listener_pid"; first_spin_listener_command=$(ps -p "$spin_listener_pid" -o command= 2>/dev/null || true); else restart_spin_listener_pid="$spin_listener_pid"; restart_spin_listener_command=$(ps -p "$spin_listener_pid" -o command= 2>/dev/null || true); fi
}
stop_spin() {
  local label=$1 command listener_command exit_code listener_owned=false; [[ "$spin_pid" != 0 ]] || return
  command=$(ps -p "$spin_pid" -o command= 2>/dev/null || true); [[ "$command" == *"spin up"* ]] || fail "refusing to stop unowned Spin pid=$spin_pid"
  if [[ "$spin_listener_pid" != 0 ]] && [[ "$spin_listener_pid" != "$spin_pid" ]]; then
    listener_command=$(ps -p "$spin_listener_pid" -o command= 2>/dev/null || true); [[ "$listener_command" == *"spin"* ]] || fail "refusing to stop unowned Spin listener pid=$spin_listener_pid"; listener_owned=true
  fi
  if [[ "$label" == success ]]; then first_spin_command="$command"; else restart_spin_command="$command"; fi
  kill "$spin_pid" 2>/dev/null || true; set +e; wait "$spin_pid"; exit_code=$?; set -e; spin_exit="$label:$exit_code"; if [[ "$label" == success ]]; then first_spin_exit="$exit_code"; else restart_spin_exit="$exit_code"; fi
  if [[ "$listener_owned" == true ]] && kill -0 "$spin_listener_pid" 2>/dev/null; then kill "$spin_listener_pid" 2>/dev/null || true; fi
  for _ in $(seq 1 50); do lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 || break; sleep 0.1; done
  lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 && fail "Spin listener did not stop"; spin_pid=0; spin_listener_pid=0
}
request_file() {
  local id=$1 payload=$2 body=$3 status
  curl -sS -X POST "$base_url/probe" -H "X-Request-ID: $id" --data-binary "$payload" -o "$body" -w '%{http_code}' >"$body.status" || true
  status=$(<"$body.status"); [[ "$status" == 200 ]] || fail "request failed id=$id http=$status"
  [[ "$(awk -F= '$1=="request_id"{print $2}' "$body")" == "$id" ]] || fail "request id mismatch: $id"
  grep -Eq "^stored_value=server-[0-9a-f]{16}\\|$id\\|$payload$" "$body" || fail "stored value mismatch: $id"
}
umask 077; [[ -f "$root/spin.toml" ]] || fail "manifest missing"; assert_free "$port"; assert_free "$mock_port"
config_expected=3d2f8c447b8118a666b13aa213c7d4d4c929529535058d23972787f60491db5e; skill_expected=9ba8c0cd3778f38a9a55616ca0b88770f34ba40d81135e4cc3ac8f13618c7833
config_before=$(shasum -a 256 fixtures/config.json | awk '{print $1}'); skill_before=$(shasum -a 256 fixtures/SKILL.md | awk '{print $1}'); manifest_hash=$(shasum -a 256 spin.toml | awk '{print $1}')
[[ "$config_before" == "$config_expected" ]] || fail "config fixture baseline hash changed"; [[ "$skill_before" == "$skill_expected" ]] || fail "skill fixture baseline hash changed"
wasm-tools component wit main.wasm >"$tmp/wit.txt"; [[ "$(wc -c <"$tmp/wit.txt" | tr -d ' ')" -lt 200000 ]] || fail "WIT output exceeded bound"
grep -Fq 'export wasi:http/handler' "$tmp/wit.txt" || fail "WIT HTTP export missing"; grep -Fq 'import spin:variables/variables@3.0.0' "$tmp/wit.txt" || fail "WIT variables import missing"; grep -Fq 'import spin:key-value/key-value@3.0.0' "$tmp/wit.txt" || fail "WIT KV import missing"
wit_hash=$(shasum -a 256 "$tmp/wit.txt" | awk '{print $1}'); artifact_committed_hash=$(shasum -a 256 main.wasm | awk '{print $1}'); artifact_committed_bytes=$(wc -c <main.wasm | tr -d ' ')
go build -o "$tmp/mock" ./mock; printf '[key_value_store.workspace]\ntype = "spin"\npath = "%s"\n' "$state_path" >"$runtime_cfg"; printf 'runtime-undisclosed-%s\n' "$(date +%s%N)" >"$tmp/secret"; : >"$tmp/empty-secret"; printf '   \t\n' >"$tmp/whitespace-secret"; secret_mode=$(stat -f '%Lp' "$tmp/secret" 2>/dev/null || stat -c '%a' "$tmp/secret"); [[ "$secret_mode" == 600 ]] || fail "secret file mode is not 0600"
SPIN_PROBE_MOCK_PORT="$mock_port" SPIN_MOCK_RECEIPTS="$mock_receipts" "$tmp/mock" >"$tmp/mock.stdout" 2>"$tmp/mock.stderr" & mock_pid=$!; owned "$mock_pid" "$tmp/mock"; mock_ready=$(wait_http "$mock_url" "$tmp/mock.ready" || true); [[ "$mock_ready" == 200 ]] || fail "mock readiness failed"; lsof -nP -a -p "$mock_pid" -iTCP:"$mock_port" -sTCP:LISTEN | grep -Fq ":$mock_port" || fail "mock listener ownership mismatch"
artifact_backup="$tmp/main.wasm.backup"; cp main.wasm "$artifact_backup"; PATH="${SPIN_GO_BIN:-/tmp/picoclaw-spin-native-arm64/go/bin}:$PATH" GOTOOLCHAIN=local spin build --from spin.toml >"$tmp/build.stdout" 2>"$tmp/build.stderr" || { cp "$artifact_backup" main.wasm; fail "Spin build failed"; }
artifact_run_hash=$(shasum -a 256 main.wasm | awk '{print $1}'); artifact_run_bytes=$(wc -c <main.wasm | tr -d ' '); [[ "$artifact_run_hash" == "$artifact_committed_hash" ]] || { cp "$artifact_backup" main.wasm; fail "built artifact differs from committed artifact"; }; [[ "$artifact_run_bytes" == "$artifact_committed_bytes" ]] || fail "artifact byte count changed"
PATH="${SPIN_GO_BIN:-/tmp/picoclaw-spin-native-arm64/go/bin}:$PATH" GOTOOLCHAIN=local spin doctor --from spin.toml >"$tmp/doctor.stdout" 2>"$tmp/doctor.stderr" || fail "Spin doctor failed"
assert_free "$port"
spin up --from spin.toml --listen "127.0.0.1:$port" --runtime-config-file "$runtime_cfg" >"$tmp/missing.stdout" 2>"$tmp/missing.stderr" & missing_pid=$!
for _ in $(seq 1 50); do kill -0 "$missing_pid" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$missing_pid" 2>/dev/null; then command=$(ps -p "$missing_pid" -o command= 2>/dev/null || true); [[ "$command" == *"spin up"* ]] || fail "missing-secret process ownership mismatch"; kill "$missing_pid" 2>/dev/null || true; fail "missing secret startup did not terminate within bound"; fi
set +e; wait "$missing_pid"; missing_exit=$?; set -e; missing_pid=0; [[ "$missing_exit" != 0 ]] || fail "missing secret did not fail closed"
grep -Fq 'no provider resolved required variable' "$tmp/missing.stderr" || fail "missing secret error was not exact"
assert_no_data_routes() { local label=$1 path code body; for path in /snapshot /probe; do body="$tmp/$label${path//\//-}.body"; code=$(curl -sS -o "$body" -w '%{http_code}' "$base_url$path" || true); [[ "$code" == 404 ]] || fail "$label exposed data route $path http=$code"; done; }
run_rejected() { local label=$1 file=$2 code body; if start_spin "$label" "$file"; then assert_no_data_routes "$label"; body="$tmp/$label.response"; code=$(curl -sS -X POST "$base_url/probe" -H 'X-Request-ID: rejected-secret' --data-binary 'request_id=rejected-secret;value=none' -o "$body" -w '%{http_code}' || true); [[ "$code" != 200 ]] || fail "$label secret was accepted"; grep -Fq 'probe unavailable' "$body" || fail "$label denial was not explicit"; stop_spin "$label"; else [[ -s "$tmp/$label.stderr" ]] || fail "$label failure had no diagnostic"; fi; }
run_rejected empty "$tmp/empty-secret"; run_rejected whitespace "$tmp/whitespace-secret"
start_spin success "$tmp/secret"; first_spin_pid=$spin_pid; curl -sS -X POST "$base_url/probe" --data-binary 'request_id=generated;value=payload-generated' -o "$tmp/generated.body" -w '%{http_code}' >"$tmp/generated.body.status" || true; [[ "$(<"$tmp/generated.body.status")" == 200 ]] || fail "server-generated request failed"; generated_id=$(awk -F= '/^request_id=/{print $2}' "$tmp/generated.body"); [[ "$generated_id" == probe-* ]] || fail "server-generated request ID missing"; curl -sS -X POST "$base_url/probe" --data-binary 'request_id=generated-2;value=payload-generated-2' -o "$tmp/generated-2.body" -w '%{http_code}' >"$tmp/generated-2.body.status" || true; [[ "$(<"$tmp/generated-2.body.status")" == 200 ]] || fail "second server-generated request failed"; generated_id_2=$(awk -F= '/^request_id=/{print $2}' "$tmp/generated-2.body"); [[ "$generated_id_2" == probe-* && "$generated_id_2" != "$generated_id" ]] || fail "server-generated request IDs are not distinct"; grep -Fq server_id= "$tmp/generated.body" || fail "server-generated value missing"; grep -Fq server_id= "$tmp/generated-2.body" || fail "second server-generated value missing"; request_file runtime-seq-1 'request_id=runtime-seq-1;value=payload-seq-1' "$tmp/seq-1.body"; request_file runtime-seq-2 'request_id=runtime-seq-2;value=payload-seq-2' "$tmp/seq-2.body"
grep -Fq preexisting=false "$tmp/seq-1.body" || fail "first sequential request preexisting"; grep -Fq preexisting=false "$tmp/seq-2.body" || fail "second sequential request preexisting"
for class in denied_default_class denied_ungranted_class; do grep -Eq "$class=(access-denied|no-such-store)" "$tmp/seq-1.body" || fail "invalid store error: $class"; done
grep -Fq fixtures=read-only "$tmp/seq-1.body" || fail "fixture read evidence missing"; grep -Fq 'denied_paths=/etc/hosts,/fixtures/../config.json,/fixtures/other.txt,/spin.toml' "$tmp/seq-1.body" || fail "denied path evidence missing"; grep -Fq BROWSER_UAT_OK "$tmp/seq-1.body" || fail "mock response missing"
request_pids=(); for n in $(seq 1 20); do id="runtime-concurrent-$n"; request_file "$id" "request_id=$id;value=payload-concurrent-$n" "$tmp/concurrent-$n.body" & request_pids+=("$!"); done
for pid in "${request_pids[@]}"; do wait "$pid"; done
case_args=("$tmp/generated.body" "$generated_id" 'request_id=generated;value=payload-generated' "$tmp/generated-2.body" "$generated_id_2" 'request_id=generated-2;value=payload-generated-2' "$tmp/seq-1.body" runtime-seq-1 'request_id=runtime-seq-1;value=payload-seq-1' "$tmp/seq-2.body" runtime-seq-2 'request_id=runtime-seq-2;value=payload-seq-2')
for n in $(seq 1 20); do case_args+=("$tmp/concurrent-$n.body" "runtime-concurrent-$n" "request_id=runtime-concurrent-$n;value=payload-concurrent-$n"); done
python3 - "${case_args[@]}" <<'PY'
import re,sys
args=sys.argv[1:]
if len(args)%3:
    raise SystemExit("invalid case arguments")
cases=[]
for path,expected_id,expected_payload in zip(args[0::3],args[1::3],args[2::3]):
    text=open(path,encoding="utf-8").read()
    fields={line.split("=",1)[0]:line.split("=",1)[1] for line in text.splitlines() if "=" in line}
    if fields.get("request_id") != expected_id:
        raise SystemExit(f"request id mismatch: {path}")
    stored=fields.get("stored_value","")
    if not re.fullmatch(rf"server-[0-9a-f]{{16}}\|{re.escape(expected_id)}\|{re.escape(expected_payload)}",stored):
        raise SystemExit(f"stored value mismatch: {path}")
    cases.append((expected_id,stored))
ids=[case[0] for case in cases]
if len(ids) != len(set(ids)):
    raise SystemExit("duplicate request IDs")
for own,stored in cases:
    for other in ids:
        if own != other and f"|{other}|" in stored:
            raise SystemExit(f"foreign stored value: {own} contains {other}")
PY
assert_no_data_routes success; stop_spin success
start_spin restart "$tmp/secret"; restart_spin_pid=$spin_pid; assert_no_data_routes restart; request_file runtime-seq-1 'request_id=runtime-seq-1;value=payload-restart' "$tmp/restart.body"; grep -Fq preexisting=true "$tmp/restart.body" || fail "restart did not observe old value"; grep -Eq '^previous_value=.*payload-seq-1$' "$tmp/restart.body" || fail "old value was not read"; grep -Fq payload-restart "$tmp/restart.body" || fail "new value was not written"; stop_spin restart
config_after=$(shasum -a 256 fixtures/config.json | awk '{print $1}'); skill_after=$(shasum -a 256 fixtures/SKILL.md | awk '{print $1}'); [[ "$config_before" == "$config_after" ]] || fail "config fixture changed"; [[ "$skill_before" == "$skill_after" ]] || fail "skill fixture changed"; [[ -s "$mock_receipts" ]] || fail "mock captured no requests"; receipt_count=$(wc -l <"$mock_receipts" | tr -d ' '); [[ "$receipt_count" == 25 ]] || fail "mock receipt count mismatch: $receipt_count"; jq -s -e 'length == 25 and ([.[].receipt_id] | unique | length == 25)' "$mock_receipts" >/dev/null || fail "mock receipt IDs are not unique"; for expected in generated generated-2 runtime-seq-1 runtime-seq-2; do grep -Fq "request_id=$expected" "$mock_receipts" || fail "mock receipt missing: $expected"; done; for n in $(seq 1 20); do grep -Fq "runtime-concurrent-$n" "$mock_receipts" || fail "mock receipt missing concurrent-$n"; done; grep -Fq 'payload-restart' "$mock_receipts" || fail "mock receipt missing restart"
default_store_class=$(awk -F= '/^denied_default_class=/{print $2}' "$tmp/seq-1.body"); ungranted_store_class=$(awk -F= '/^denied_ungranted_class=/{print $2}' "$tmp/seq-1.body"); [[ "$default_store_class" =~ ^(access-denied|no-such-store)$ ]] || fail "default store class invalid"; [[ "$ungranted_store_class" =~ ^(access-denied|no-such-store)$ ]] || fail "ungranted store class invalid"
stored_value() { awk -F= '/^stored_value=/{print substr($0,index($0,"=")+1)}' "$1"; }
kv_args=("request/$generated_id" "$(stored_value "$tmp/generated.body")" "request/$generated_id_2" "$(stored_value "$tmp/generated-2.body")" "request/runtime-seq-1" "$(stored_value "$tmp/restart.body")" "request/runtime-seq-2" "$(stored_value "$tmp/seq-2.body")")
for n in $(seq 1 20); do kv_args+=("request/runtime-concurrent-$n" "$(stored_value "$tmp/concurrent-$n.body")"); done
kv_result=$(python3 - "$state_path" "${kv_args[@]}" <<'PY'
import json,sqlite3,sys
state,*args=sys.argv[1:]
if len(args) % 2:
    raise SystemExit("invalid expected KV argument count")
expected=dict(zip(args[0::2],args[1::2]))
if len(expected) != 24:
    raise SystemExit(f"expected 24 KV keys, got {len(expected)}")
try:
    db=sqlite3.connect(f"file:{state}?mode=ro", uri=True)
    tables=db.execute("SELECT name, sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").fetchall()
except sqlite3.Error as error:
    raise SystemExit(f"KV schema inspection failed: {error}")
candidates=[]
for name, sql in tables:
    quoted='"'+name.replace('"','""')+'"'
    columns=[row[1] for row in db.execute(f"PRAGMA table_info({quoted})")]
    if columns == ["key", "value"]:
        candidates.append((name, sql, columns))
if len(candidates) != 1:
    raise SystemExit(f"KV schema mismatch: expected one key/value table, found {[(name, columns) for name,_,columns in candidates]}")
name,sql,columns=candidates[0]
quoted='"'+name.replace('"','""')+'"'
try:
    rows=db.execute(f"SELECT key, value FROM {quoted} ORDER BY key").fetchall()
except sqlite3.Error as error:
    raise SystemExit(f"KV query mismatch: {error}")
actual={}
for key,value in rows:
    if not isinstance(key,str) or not isinstance(value,(bytes,bytearray)):
        raise SystemExit("KV query returned unexpected key/value types")
    try:
        actual[key]=bytes(value).decode("utf-8")
    except UnicodeDecodeError as error:
        raise SystemExit(f"KV value was not UTF-8: {error}")
if len(rows) != len(actual) or len(actual) != 24:
    raise SystemExit(f"KV key count mismatch: rows={len(rows)} keys={len(actual)}")
if actual != expected:
    missing=sorted(set(expected)-set(actual)); extra=sorted(set(actual)-set(expected)); changed=sorted(k for k in set(actual)&set(expected) if actual[k]!=expected[k])
    raise SystemExit(f"KV map mismatch: missing={missing} extra={extra} changed={changed}")
print(json.dumps({"map":actual,"table":name,"columns":columns,"schema":sql,"key_count":len(actual)},sort_keys=True,separators=(",",":")))
PY
) || fail "final stopped-state KV verification failed"
final_map=$(printf '%s' "$kv_result" | jq -ce '.map') || fail "final KV map encoding failed"; kv_db_schema=$(printf '%s' "$kv_result" | jq -ce 'del(.map)') || fail "final KV schema encoding failed"
sentinel=$(<"$tmp/secret"); repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || fail "cannot resolve repository root"; diff_base=$(git -C "$repo_root" merge-base origin/main HEAD 2>/dev/null) || fail "cannot resolve merge-base for origin/main and HEAD"; [[ -n "$diff_base" ]] || fail "empty merge-base for origin/main and HEAD"; source_diff_limit=16000000; git -C "$repo_root" diff --binary "$diff_base" HEAD -- examples/spin-p3-smoke PORT_STATUS.md >"$tmp/source-diff" || fail "cannot generate scoped source diff"; source_diff_hash=$(shasum -a 256 "$tmp/source-diff" | awk '{print $1}'); source_diff_bytes=$(wc -c <"$tmp/source-diff" | tr -d ' '); [[ "$source_diff_bytes" -gt 0 ]] || fail "scoped source diff was empty"; [[ "$source_diff_bytes" -le "$source_diff_limit" ]] || fail "scoped source diff exceeded ${source_diff_limit} bytes"
[[ -d "$component_logs_path" ]] || fail "Spin component log directory missing: $component_logs_path"; component_log_files=$(find "$component_logs_path" -type f | wc -l | tr -d ' '); [[ "$component_log_files" -gt 0 ]] || fail "Spin component log directory was empty"
cat "$tmp"/concurrent-*.body >"$tmp/concurrent-bodies.scan"; cat "$tmp"/*.stdout "$tmp"/*.stderr >"$tmp/launcher-logs.scan"; cat "$tmp/generated.body" "$tmp/generated-2.body" "$tmp/seq-1.body" "$tmp/seq-2.body" "$tmp"/concurrent-*.body "$tmp/restart.body" >"$tmp/http-bodies.scan"
scan_labels=(source diff manifest config skill runtime_config artifact missing_stdout missing_stderr empty_stdout empty_stderr whitespace_stdout whitespace_stderr generated_body generated_body_2 seq1_body seq2_body concurrent_bodies restart_body mock_capture launcher_logs component_logs kv_db evidence); scan_paths=("$root" "$tmp/source-diff" "$root/spin.toml" "$root/fixtures/config.json" "$root/fixtures/SKILL.md" "$runtime_cfg" "$root/main.wasm" "$tmp/missing.stdout" "$tmp/missing.stderr" "$tmp/empty.stdout" "$tmp/empty.stderr" "$tmp/whitespace.stdout" "$tmp/whitespace.stderr" "$tmp/generated.body" "$tmp/generated-2.body" "$tmp/seq-1.body" "$tmp/seq-2.body" "$tmp/concurrent-bodies.scan" "$tmp/restart.body" "$mock_receipts" "$tmp/launcher-logs.scan" "$component_logs_path" "$state_path" "$out"); scan_counts=()
for i in "${!scan_labels[@]}"; do count=$(rg -a -F -o "$sentinel" "${scan_paths[$i]}" 2>/dev/null | wc -l | tr -d ' ' || true); scan_counts+=("${scan_labels[$i]}=$count"); [[ "$count" == 0 ]] || fail "secret leaked into ${scan_labels[$i]}"; done
[[ "$spin_dir_preexisting" == true ]] || spin_dir_created=true
clean_run_spin_dir
[[ "$spin_dir_preexisting" == true || "$spin_dir_cleanup" == removed-run-created ]] || fail "run-created Spin directory cleanup was not recorded"
mock_pid_record=$mock_pid; mock_command=$(ps -p "$mock_pid" -o command= 2>/dev/null || true); [[ "$mock_command" == *"$tmp/mock"* ]] || fail "mock ownership lost"; kill "$mock_pid" 2>/dev/null || true; set +e; wait "$mock_pid"; mock_exit=$?; set -e; mock_pid=0
scan_json=$(printf '%s\n' "${scan_counts[@]}" | python3 -c 'import json,sys; print(json.dumps(dict(x.rstrip("\n").split("=",1) for x in sys.stdin), sort_keys=True, separators=(",",":")))')
spin_version=$(spin --version | head -1); go_version=$(go version); wasm_tools_version=$(wasm-tools --version | head -1); curl_version=$(curl --version | head -1)
host_os=$(uname -s); host_kernel=$(uname -r); host_kernel_machine=$(uname -m); host_hardware=$(sysctl -n hw.machine 2>/dev/null || printf unavailable); host_process_translation=$(sysctl -in sysctl.proc_translated 2>/dev/null || printf unavailable)
tool_architectures=$(python3 - "$(command -v spin)" "$(command -v go)" "$(command -v wasm-tools)" "$(command -v curl)" "$(command -v jq)" "$(command -v rg)" "$(command -v python3)" <<'PY'
import json,os,subprocess,sys
names=("spin","go","wasm-tools","curl","jq","rg","python3")
result={}
for name,path in zip(names,sys.argv[1:]):
    try:
        output=subprocess.check_output(["file","-b",path],text=True).strip()
    except (OSError,subprocess.CalledProcessError) as error:
        raise SystemExit(f"cannot inspect {name} architecture: {error}")
    result[name]={"path":path,"resolved_path":os.path.realpath(path),"file":output}
print(json.dumps(result,sort_keys=True,separators=(",",":")))
PY
) || fail "tool binary architecture inspection failed"
status_clean=true; mkdir -p "$(dirname "$out")"
wit_summary=$(rg 'export wasi:http/handler|import spin:variables/variables@3.0.0|import spin:key-value/key-value@3.0.0' "$tmp/wit.txt" | tr '\n' ';')
receipt_ids=$(jq -sc '[.[].receipt_id]' "$mock_receipts")
python3 - "$out" "$commit" "$run_started" "$artifact_run_hash" "$artifact_run_bytes" "$manifest_hash" "$wit_hash" "$wit_summary" "$port" "$mock_port" "$mock_pid_record" "$mock_exit" "$mock_command" "$first_spin_pid" "$first_spin_listener_pid" "$first_spin_command" "$first_spin_listener_command" "$first_spin_exit" "$restart_spin_pid" "$restart_spin_listener_pid" "$restart_spin_command" "$restart_spin_listener_command" "$restart_spin_exit" "$state_path" "$config_before" "$config_after" "$config_expected" "$skill_before" "$skill_after" "$skill_expected" "$receipt_count" "$receipt_ids" "$generated_id" "$generated_id_2" "$default_store_class" "$ungranted_store_class" "$final_map" "$scan_json" "$status_clean" "$spin_version" "$go_version" "$wasm_tools_version" "$curl_version" "$diff_base" "$source_diff_hash" "$source_diff_bytes" "$source_diff_limit" "$host_os" "$host_kernel" "$host_kernel_machine" "$host_hardware" "$host_process_translation" "$tool_architectures" "$component_logs_path" "$component_log_files" "$spin_dir_preexisting" "$spin_dir_created" "$spin_dir_cleanup" "$kv_db_schema" <<'PY'
import json,sys,platform
(out,commit,started,artifact,artifact_bytes,manifest,wit,wit_summary,port,mock_port,mock_pid,mock_exit,mock_command,first_pid,first_listener_pid,first_command,first_listener_command,first_exit,restart_pid,restart_listener_pid,restart_command,restart_listener_command,restart_exit,state_path,cb,ca,config_expected,sb,sa,skill_expected,receipts,receipt_ids,generated_id,generated_id_2,default_class,ungranted_class,final_map,scans,clean,spin_version,go_version,wasm_tools_version,curl_version,diff_base,diff_hash,diff_bytes,diff_limit,host_os,host_kernel,host_machine,host_hardware,process_translation,tool_architectures,component_logs_path,component_log_files,spin_dir_preexisting,spin_dir_created,spin_dir_cleanup,kv_db_schema)=sys.argv[1:]
cases=[{"id":generated_id,"kind":"generated","http":200,"foreign_value":False},{"id":generated_id_2,"kind":"generated","http":200,"foreign_value":False}]+[{"id":f"runtime-seq-{n}","kind":"sequential","http":200,"foreign_value":False} for n in (1,2)]+[{"id":f"runtime-concurrent-{n}","kind":"concurrent","http":200,"foreign_value":False} for n in range(1,21)]+[{"id":"runtime-seq-1","kind":"restart","http":200,"old_read":True,"foreign_value":False}]
d={"status":"pass","started_utc":started,"commit":commit,"clean_checkout_before":clean=="true","host":{"os":platform.system(),"release":platform.release(),"architecture":platform.machine()},"tool_versions":{"spin":{"version":spin_version,"architecture":platform.machine()},"go":{"version":go_version,"architecture":platform.machine()},"wasm_tools":{"version":wasm_tools_version,"architecture":platform.machine()},"curl":{"version":curl_version,"architecture":platform.machine()}},"artifact":{"path":"examples/spin-p3-smoke/main.wasm","sha256":artifact,"bytes":int(artifact_bytes)},"manifest":{"sha256":manifest,"grants":{"outbound_hosts":["http://127.0.0.1:31808"],"variables":["probe_secret->secret"],"files":["fixtures/config.json->/fixtures/config.json","fixtures/SKILL.md->/fixtures/SKILL.md"],"key_value_stores":["workspace"]}},"wit":{"summary":wit_summary,"sha256":wit},"ports":{"spin_http":int(port),"mock_http":int(mock_port)},"processes":{"mock":{"pid":int(mock_pid),"command":mock_command,"exit":int(mock_exit)},"first_spin":{"pid":int(first_pid),"listener_pid":int(first_listener_pid),"command":first_command,"listener_command":first_listener_command,"exit":int(first_exit)},"restart_spin":{"pid":int(restart_pid),"listener_pid":int(restart_listener_pid),"command":restart_command,"listener_command":restart_listener_command,"exit":int(restart_exit)}},"state_path":state_path,"secret_cases":{"missing":{"result":"startup-denied","error":"no provider resolved required variable"},"empty":{"result":"request-denied"},"whitespace":{"result":"request-denied"},"injected_by":"file-path"},"requests":{"case_table":cases,"sequential":2,"concurrent":20,"restart":"old-read-before-overwrite","server_generated_ids":True,"generated_ids":[generated_id,generated_id_2],"foreign_values":False},"stores":{"default":default_class,"ungranted":ungranted_class},"fixtures":{"config_before":cb,"config_after":ca,"expected_config":config_expected,"skill_before":sb,"skill_after":sa,"expected_skill":skill_expected,"writes_denied":True,"named_repo_file_denied":"spin.toml","denied_paths":["/etc/hosts","/fixtures/../config.json","/fixtures/other.txt","/spin.toml"]},"mock":{"owned":True,"receipt_count":int(receipts),"receipt_ids":json.loads(receipt_ids),"capture":"mock-receipts.jsonl"},"final_kv_map":json.loads(final_map),"secret_scan_counts":json.loads(scans),"secret_scan_self_check":0,"provenance":{"evidence":"generated directly by this clean runtime run","old_secret_value_recorded":False,"scoped_diff":{"base_ref":"origin/main","base_commit":diff_base,"head_commit":commit,"paths":["examples/spin-p3-smoke","PORT_STATUS.md"],"sha256":diff_hash,"bytes":int(diff_bytes),"max_bytes":int(diff_limit)}}}
d["host"]={"os":host_os,"kernel_release":host_kernel,"kernel_machine":host_machine,"hardware_machine":host_hardware,"process_translation":process_translation}
d["tool_versions"]={"spin":{"version":spin_version},"go":{"version":go_version},"wasm_tools":{"version":wasm_tools_version},"curl":{"version":curl_version}}
d["tool_binary_architectures"]=json.loads(tool_architectures)
d["secret_cases"]["empty"]["data_routes"]={"/snapshot":404,"/probe":404}
d["secret_cases"]["whitespace"]["data_routes"]={"/snapshot":404,"/probe":404}
d["kv_db"]=json.loads(kv_db_schema)
d["component_logs"]={"path":component_logs_path,"files":int(component_log_files),"spin_dir_preexisting":spin_dir_preexisting=="true","spin_dir_created":spin_dir_created=="true","cleanup":spin_dir_cleanup}
with open(out,"w",encoding="utf-8") as f: json.dump(d,f,indent=2,sort_keys=True); f.write("\n")
PY
rg -a -F "$sentinel" "$out" >/dev/null 2>&1 && fail "secret leaked into final evidence"; cat "$out"
