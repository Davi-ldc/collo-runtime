#!/usr/bin/env bash
set -euo pipefail

if ! command -v strace >/dev/null 2>&1; then
  echo "strace is required for syscall benchmark collection" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

# Own cache dir: /tmp/collo-cache is the JSC artifact cache, not a zig cache.
export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-/tmp/collo-zig-cache-bench}"
export COLLO_BENCH_EGRESS_HTTP1_ITERATIONS="${COLLO_BENCH_EGRESS_HTTP1_ITERATIONS:-3}"
export COLLO_BENCH_EGRESS_HTTP1_REQUESTS="${COLLO_BENCH_EGRESS_HTTP1_REQUESTS:-16}"
export COLLO_BENCH_EGRESS_ITERATIONS="${COLLO_BENCH_EGRESS_ITERATIONS:-3}"
export COLLO_BENCH_EGRESS_WARMUP="${COLLO_BENCH_EGRESS_WARMUP:-1}"

mkdir -p "$ZIG_LOCAL_CACHE_DIR"

# Warm the Zig cache first. The measured command still includes the build runner,
# but with a warm cache the syscall table is dominated by the benchmark process.
zig build bench-egress-http1 >/dev/null
zig build bench-egress-tls >/dev/null

http1_out="${COLLO_BENCH_SYSCALL_HTTP1_OUT:-/tmp/collo-egress-http1.syscalls}"
tls_out="${COLLO_BENCH_SYSCALL_TLS_OUT:-/tmp/collo-egress-tls.syscalls}"

strace -f -c -o "$http1_out" zig build bench-egress-http1 >/tmp/collo-egress-http1.bench
strace -f -c -o "$tls_out" zig build bench-egress-tls >/tmp/collo-egress-tls.bench

echo "== HTTP/1 syscall summary =="
cat "$http1_out"
echo
echo "== HTTP/2/TLS syscall summary =="
cat "$tls_out"
echo
echo "bench output:"
echo "  /tmp/collo-egress-http1.bench"
echo "  /tmp/collo-egress-tls.bench"
