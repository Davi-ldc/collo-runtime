#!/usr/bin/env bash
# Run prebuilt microbench binaries; never compile as root. Publish results only
# after the process, sample counts and timestamp/identity checks all succeed.
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
mode="${1:-all}"
case "$mode" in cold|memory|all) ;; *) printf 'Usage: bash %s [cold|memory|all] [results-dir]\n' "$0" >&2; exit 2 ;; esac
prefix="${COLLO_BENCH_PREFIX:-$repo/.zig-cache/sandbox-bench}"
[[ "$prefix" = /* ]] || { printf 'COLLO_BENCH_PREFIX must be absolute\n' >&2; exit 2; }
if (( EUID != 0 )); then
    printf 'The benchmark runtime runs as root. Build as your user, then run this script with sudo.\n' >&2
    exit 1
fi
if [[ -n "${2:-}" ]]; then
    results="$2"
    mkdir -- "$results"
    results="$(cd -- "$results" && pwd -P)"
else
    mkdir -p -- "$repo/report/bench-sandbox"
    results="$(mktemp -d "$repo/report/bench-sandbox/run.XXXXXX")"
fi
printf 'Results: %s\n' "$results"
finish() {
    local status=$?
    if (( status != 0 )); then printf 'failed: exit %s\n' "$status" > "$results/status.txt"; fi
    if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" ]]; then
        chown -R -- "$SUDO_UID:$SUDO_GID" "$results"
    fi
}
trap finish EXIT
cd -- "$repo"
sha256sum "$prefix/bin/sandbox-bench" "$prefix/bin/wsl-config" > "$results/binaries.sha256"
sha256sum runtime/deps/webkit.version runtime/patches/webkit/*.patch > "$results/engine-inputs.sha256"
find runtime/bench/sandbox runtime/tests/contracts -maxdepth 1 -type f \
    \( -name '*.zig' -o -name '*.cc' -o -name '*.h' -o -name '*.jq' -o -name '*.js' -o -name 'run.sh' \) -print0 \
    | sort -z | xargs -0 sha256sum > "$results/measurement-sources.sha256"
{
    date -Iseconds
    uname -srmo
    grep -m1 'model name' /proc/cpuinfo
    grep -E 'MemTotal|MemAvailable|SwapTotal' /proc/meminfo
    grep Cpus_allowed_list /proc/self/status
    printf 'mode=%s\nworkload=%s\nsettle_ms=%s\nrounds=%s\ncold_samples_per_round=%s\nload_requests=%s\n' \
        "$mode" "${COLLO_BENCH_WORKLOAD:-hello}" "${COLLO_BENCH_SETTLE_MS:-0}" \
        "${COLLO_BENCH_ROUNDS:-3}" "${COLLO_BENCH_SAMPLES:-32}" \
        "${COLLO_BENCH_LOAD_REQUESTS:-workload default}"
} > "$results/environment.txt"
# Only benchmark runtime processes retain root: the runtime cache sits in the
# results directory, which root created with mode 0700. The controller stays
# outside each measured subtree.
mkdir -- "$results/runtime-cache"
env -u SUDO_UID -u SUDO_GID -u SUDO_USER \
    COLLO_BENCH_CACHE_ROOT="$results/runtime-cache" \
    COLLO_BENCH_WSL_CONFIG="$prefix/bin/wsl-config" \
    "$prefix/bin/wsl-config" run -- "$prefix/bin/sandbox-bench" "$mode" \
    > "$results/results.partial.jsonl" 2> "$results/stderr.log"
jq -se --arg mode "$mode" '
    ([.[] | select(.kind == "metadata")] | length) == 1 and
    (.[-1].kind == "complete" and .[-1].mode == $mode) and
    ([.[] | select(.kind == "failed" or .kind == "memory_unstable")] | length) == 0 and
    (.[0] as $meta |
      (if $mode == "cold" or $mode == "all" then
        ([.[] | select(.kind == "cold_sample")] | length) == ($meta.rounds * $meta.samples_per_round) and
        all(.[] | select(.kind == "cold_sample");
          .timeline.request_sent_ns > 0 and
          .timeline.worker_ready_ns >= .timeline.request_sent_ns and
          .timeline.handler_enter_ns >= .timeline.worker_ready_ns and
          .timeline.response_received_ns >= .timeline.handler_enter_ns and
          .durations.total_ns == (.timeline.handler_enter_ns - .timeline.request_sent_ns) and
          .durations.total_ns == (.durations.creation_ns + .durations.dispatch_ns))
      else true end) and
      (if $mode == "memory" or $mode == "all" then
        ([.[] | select(.kind == "memory_sample")] | length) == ($meta.rounds * 2 * 4 * 2) and
        ([.[] | select(.kind == "memory_teardown")] | length) == ($meta.rounds * 2 * 4 * 2) and
        all(.[] | select(.kind == "memory_sample");
          .before.stable and .ready.stable and .after.stable and
          .after.snapshot.swap_bytes == 0 and
          .marginal_bytes == (.after.snapshot.current_bytes - .before.snapshot.current_bytes) and
          .load_growth_bytes == (.after.snapshot.current_bytes - .ready.snapshot.current_bytes))
      else true end))
' "$results/results.partial.jsonl" > /dev/null
jq -s -f runtime/bench/sandbox/summary.jq "$results/results.partial.jsonl" > "$results/summary.json"
rmdir -- "$results/runtime-cache"
mv -- "$results/results.partial.jsonl" "$results/results.jsonl"
printf 'succeeded\n' > "$results/status.txt"
jq -c 'select(.kind == "cold_summary" or .kind == "complete")' "$results/results.jsonl"
printf 'Verified results: %s/results.jsonl\n' "$results"
