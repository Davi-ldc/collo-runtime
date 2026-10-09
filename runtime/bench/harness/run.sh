#!/bin/bash
# Measures only Collo, using binaries built before this command starts.
# Failed runs retain raw output and partial.jsonl; only a complete, validated
# run publishes results.jsonl. Comparators are separate runs, never fallthrough.
# Usage: BENCH_BIN=/absolute/host_lifecycle run.sh <repo> <collo> <jsc> <results>
# Knobs: ROUNDS=3 COUNTS="1 4 16" WARM_REQUESTS=200 OPTIMIZE=ReleaseSafe.
set -euo pipefail

fail() { printf 'harness: %s\n' "$*" >&2; exit 2; }
positive_bounded() {
  [[ $2 =~ ^[1-9][0-9]{0,5}$ ]] && (( 10#$2 <= $3 )) || fail "$1 must be in 1..$3"
}

[[ $# == 4 ]] || fail 'expected <repo> <collo> <jsc> <results>'
: "${BENCH_BIN:?BENCH_BIN must name the prebuilt host_lifecycle executable}"
[[ $BENCH_BIN == /* && -x $BENCH_BIN ]] || fail 'BENCH_BIN must be absolute and executable'
ROUNDS=${ROUNDS-3}
COUNTS=${COUNTS-'1 4 16'}
WARM_REQUESTS=${WARM_REQUESTS-200}
OPTIMIZE=${OPTIMIZE-ReleaseSafe}
positive_bounded ROUNDS "$ROUNDS" 64
positive_bounded WARM_REQUESTS "$WARM_REQUESTS" 100000
[[ $COUNTS =~ ^[[:space:]0-9]+$ ]] || fail 'COUNTS must be whitespace-separated integers'
read -r -a counts <<< "${COUNTS//$'\n'/ }"
(( ${#counts[@]} > 0 && ${#counts[@]} <= 256 )) || fail 'COUNTS must contain 1..256 entries'
seen=' '
for count in "${counts[@]}"; do
  positive_bounded COUNTS "$count" 256
  [[ $seen != *" $count "* ]] || fail "duplicate worker count: $count"
  seen+="$count "
done
case $OPTIMIZE in Debug|ReleaseSafe|ReleaseFast|ReleaseSmall) ;; *) fail 'invalid OPTIMIZE' ;; esac
for tool in timeout flock jq sha256sum realpath mktemp; do
  command -v "$tool" >/dev/null || fail "missing required command: $tool"
done

repo=$(realpath "$1")
bin=$(realpath "$2")
jsc=$(realpath "$3")
results_root=$(realpath -m "$4")
BENCH_BIN=$(realpath "$BENCH_BIN")
[[ -d $repo && -x $bin && -f $jsc/.collo-jsc.attestation.v2 ]] || fail 'missing input artifact'
here=$(cd "$(dirname "$0")" && pwd)
export BENCH_BIN ROUNDS WARM_REQUESTS OPTIMIZE
COUNTS="${counts[*]}"
export COUNTS
if [[ -z ${COLLO_WORKER_CGROUP_ROOT:-} ]]; then
  exec "$here/cgroup_scope_run.sh" "$0" "$repo" "$bin" "$jsc" "$results_root"
fi

mkdir -p "$results_root"
exec 9>"$results_root/.collo-harness.lock"
flock -n 9 || fail 'another run holds this results root'
out=$(mktemp -d "$results_root/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")
partial="$out/partial.jsonl"
stage=setup

snapshot_environment() {
  timeout --kill-after=5s 15s bash -s <<'SNAPSHOT'
set -euo pipefail
printf 'timestamp=%s\n' "$(date -Is)"
printf '\n--- resource limits ---\n'
ulimit -a
printf '\n--- system ---\n'
cat /proc/stat /proc/loadavg /proc/meminfo /proc/self/status
printf '\n--- processes ---\n'
ps -eo pid,ppid,comm,pcpu
printf '\n--- cgroup ancestors ---\n'
relative=$(awk -F: '$1 == "0" {print $3}' /proc/self/cgroup)
[[ $relative == /* ]] || exit 1
path="/sys/fs/cgroup${relative%/}"
while :; do
  printf '\n[%s]\n' "$path"
  for key in cpu.max cpu.stat pids.max memory.max memory.current memory.events; do
    if [[ -e $path/$key ]]; then
      printf '%s: ' "$key"
      cat "$path/$key"
    else
      printf '%s: unavailable\n' "$key"
    fi
  done
  [[ $path == /sys/fs/cgroup ]] && break
  path=${path%/*}
done
SNAPSHOT
}

finish() {
  local rc=$?
  trap - EXIT
  set +e
  snapshot_environment >"$out/environment.after" 2>"$out/environment.after.stderr"
  local snapshot_rc=$?
  if (( rc == 0 && snapshot_rc != 0 )); then rc=$snapshot_rc; stage=environment_after; fi
  local state=failed
  if (( rc == 0 )); then
    mv "$partial" "$out/results.jsonl"
    rc=$?
    if (( rc == 0 )); then state=succeeded; stage=complete; fi
  fi
  printf '{"state":"%s","stage":"%s","exit_code":%d,"finished":"%s"}\n' \
    "$state" "$stage" "$rc" "$(date -Is)" >"$out/status.json"
  local status_rc=$?
  if (( rc == 0 && status_rc != 0 )); then rc=$status_rc; fi
  printf 'harness: %s, exit=%d, results=%s\n' "$state" "$rc" "$out"
  exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf 'results: %s\n' "$out"

stage=environment_before
snapshot_environment >"$out/environment.before" 2>"$out/environment.before.stderr"
stage=metadata
timeout --kill-after=5s 30s "$here/metadata.sh" "$repo" "$bin" "$BENCH_BIN" "$jsc" \
  >"$out/metadata.stdout" 2>"$out/metadata.stderr"
jq -ce . "$out/metadata.stdout" >"$partial"

stage=smoke
timeout --kill-after=5s 60s "$here/cli_smoke.sh" "$bin" "$out/smoke" \
  >"$out/smoke.stdout" 2>"$out/smoke.stderr"
awk '/^[[:space:]]*\{/ {print}' "$out/smoke.stdout" "$out/smoke.stderr" >"$out/smoke.jsonl"
jq -se 'length == 1 and .[0].bench == "cli_smoke" and .[0].exit == 0 and
  .[0].stdout_exact == true and .[0].stderr_bytes == 0 and
  .[0].processes_while_running == 3 and .[0].survivors_after_kill == 0' \
  "$out/smoke.jsonl" >/dev/null
jq -c . "$out/smoke.jsonl" >>"$partial"

stage=bench
# Force the same subtree for CLI and bench instead of inheriting an unrelated
# bench/test root that takes precedence in the benchmark's placement resolver.
export COLLO_BENCH_CGROUP_ROOT=$COLLO_WORKER_CGROUP_ROOT
export COLLO_BENCH_EXECUTABLE=$bin
export COLLO_BENCH_WORKER_COUNTS=$(IFS=,; echo "${counts[*]}")
export COLLO_BENCH_ROUNDS=$ROUNDS COLLO_BENCH_WARM_REQUESTS=$WARM_REQUESTS
(cd "$repo"; timeout --kill-after=5s 1800s "$BENCH_BIN") \
  >"$out/bench.stdout" 2>"$out/bench.stderr"
stage=validate_bench
awk '/^[[:space:]]*\{/ {print}' "$out/bench.stdout" "$out/bench.stderr" >"$out/bench.jsonl"
counts_json=$(printf '%s\n' "${counts[@]}" | jq -sc '.')
jq -se --argjson counts "$counts_json" --argjson rounds "$ROUNDS" \
  --argjson warm "$WARM_REQUESTS" --arg optimize "$OPTIMIZE" --arg executable "$bin" '
  . as $rows |
  ([.[] | select(.bench == "metadata" and .benchmark == "host_lifecycle" and
     .optimize_mode == $optimize)] | length) == 1 and
  ([.[] | select(.bench == "host_lifecycle" and .scenario == "executable" and
     .path == $executable)] | length) == 1 and
  ([.[] | select(.bench == "host_lifecycle" and .scenario == "zygote_spawn")] | length) == 1 and
  ([.[] | select(.bench == "host_lifecycle" and .scenario == "warm_sequential" and
     .requests == $warm)] | length) == 1 and
  ([$counts[] as $n | range(1; $rounds + 1) as $r |
    [$rows[] | select(.bench == "host_lifecycle" and .scenario == "worker_cold_start" and
      .worker_count == $n and .round == $r)] | length == 1] | all) and
  length == ($counts | length) * $rounds + 4
' "$out/bench.jsonl" >/dev/null
jq -c . "$out/bench.jsonl" >>"$partial"
