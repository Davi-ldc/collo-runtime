#!/bin/bash
# Records the actual artifacts and the checkout supplied to this run. A
# checkout commit is not evidence that either executable was built from it.
# Usage: metadata.sh <repo-root> <collo-binary> <bench-binary> <jsc-build-dir>
set -euo pipefail
[[ $# == 4 ]] || { echo 'metadata: expected <repo> <collo> <bench> <jsc>' >&2; exit 2; }
repo=$1; bin=$2; bench_bin=$3; jsc=$4

file_sha() {
  local result
  result=$(sha256sum "$1")
  printf '%s\n' "${result%% *}"
}
if [[ -f $repo/SOURCE_COMMIT ]]; then
  commit=$(<"$repo/SOURCE_COMMIT")
  commit_origin=SOURCE_COMMIT
else
  commit=$(git -C "$repo" rev-parse HEAD)
  commit_origin=git
fi
[[ $commit =~ ^[0-9a-f]{40}$ ]] || { echo 'metadata: invalid source commit' >&2; exit 1; }
collo_sha=$(file_sha "$bin")
bench_sha=$(file_sha "$bench_bin")
attestation_sha=$(file_sha "$jsc/.collo-jsc.attestation.v2")
source_sha=$(file_sha "$repo/runtime/bench/host_lifecycle.zig")
cpu=$(lscpu | awk -F: '/Model name/{sub(/^ +/, "", $2); print $2}')
[[ -n $cpu ]] || cpu=unknown
cpus=$(nproc)
mem_total=$(awk '/^MemTotal:/ {print $2; found=1} END {if (!found) exit 1}' /proc/meminfo)
[[ $cpus =~ ^[1-9][0-9]*$ && $mem_total =~ ^[1-9][0-9]*$ ]] || exit 1
jq -cn --arg commit "$commit" --arg commit_origin "$commit_origin" \
  --arg collo "$bin" --arg collo_sha "$collo_sha" \
  --arg bench "$bench_bin" --arg bench_sha "$bench_sha" \
  --arg attestation "$jsc/.collo-jsc.attestation.v2" --arg attestation_sha "$attestation_sha" \
  --arg source_sha "$source_sha" --arg optimize "${OPTIMIZE:-ReleaseSafe}" \
  --arg kernel "$(uname -r)" --arg arch "$(uname -m)" --arg cpu "$cpu" \
  --argjson cpus "$cpus" --argjson mem_total "$mem_total" \
  --arg counts "${COUNTS:-1 4 16}" --arg rounds "${ROUNDS:-3}" \
  --arg warm "${WARM_REQUESTS:-200}" --arg timestamp "$(date -Is)" '
  {bench: "harness_metadata", source_checkout_commit: $commit, source_commit_origin: $commit_origin,
   binary_source_correspondence: "not_verified_by_this_runner",
   collo_binary: $collo, collo_sha256: $collo_sha,
   bench_binary: $bench, bench_sha256: $bench_sha,
   jsc_attestation: $attestation, jsc_attestation_sha256: $attestation_sha,
   benchmark_source_sha256: $source_sha, declared_optimize_mode: $optimize,
   kernel: $kernel, arch: $arch, cpu: $cpu, cpus: $cpus, mem_total_kib: $mem_total,
   counts: $counts, rounds: ($rounds | tonumber), warm_requests: ($warm | tonumber),
   timestamp: $timestamp}
'
