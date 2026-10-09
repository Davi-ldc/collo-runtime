#!/bin/bash
# N native Bun processes, one hello server each. Prints one JSON line: time
# to first response per process (spawn included) and PSS/private-dirty per
# process once every instance answered.
set -uo pipefail
N=${1:-4}; here=$(cd "$(dirname "$0")" && pwd); . "$here/../lib.sh"
BUN=${BUN:-bun}
pids=(); ttfr=()
for i in $(seq 1 "$N"); do
  port=$((3100 + i))
  PORT=$port "$BUN" "$here/server.js" >/dev/null 2>&1 &
  pids+=($!)
  ttfr+=("$(wait_first_response "$port" "hello from bun: GET /hi")")
done
sleep 0.5
pss=$(for p in "${pids[@]}"; do pss_kib "$p"; done | sum)
dirty=$(for p in "${pids[@]}"; do private_dirty_kib "$p"; done | sum)
printf '{"bench":"bun_native","n":%d,"ttfr_ms_p50":%s,"ttfr_ms_max":%s,"pss_per_instance_kib":%d,"private_dirty_per_instance_kib":%d}\n' \
  "$N" "$(printf '%s\n' "${ttfr[@]}" | percentile 50)" "$(printf '%s\n' "${ttfr[@]}" | percentile 100)" $((pss / N)) $((dirty / N))
kill "${pids[@]}" 2>/dev/null; wait 2>/dev/null
