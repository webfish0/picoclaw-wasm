#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")" && pwd)
cd "$root"
out=${SPIN_ACCEPTANCE_OUT:-"$(mktemp /tmp/picoclaw-spin-gate.XXXXXX.json)"}
cleanup_out() { [[ -n "${SPIN_ACCEPTANCE_OUT:-}" ]] || rm -f "$out"; }
trap cleanup_out EXIT

SPIN_ACCEPTANCE_OUT="$out" ./runtime-acceptance.sh
jq -e '.status == "pass" and .artifact.sha256 != null and (.secret_scan_counts | to_entries | all(.value == "0"))' "$out" >/dev/null
git diff --check
printf '{"status":"pass","gate":"#20","evidence":"%s"}\n' "$out"
