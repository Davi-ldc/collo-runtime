#!/bin/bash
# One local workerd process with N configured services. Startup is measured
# from process launch, not from later requests mislabeled as isolate startup.
set -euo pipefail
N=${1:-4}
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../lib.sh"
prepare_output workerd
command -v ss >/dev/null
WORKERD=$(realpath "$(command -v "${WORKERD:-workerd}")")
timeout 10 "$WORKERD" --version >"$out/workerd-version" 2>&1
version=$(<"$out/workerd-version")
sha=$(sha256sum "$WORKERD"); sha=${sha%% *}
cp "$here/hello_worker.js" "$out/hello_worker.js"
printf 'hello from workerd: GET /hi\n' >"$out/expected"
pid=
identity=
cleanup() {
  local current attempt
  [[ -n $pid ]] || return 0
  current=$(process_identity "$pid") || { wait "$pid" 2>/dev/null || true; return 0; }
  [[ $current == "$identity" ]] || return 1
  kill -TERM "$pid" 2>/dev/null || true
  for (( attempt=0; attempt<40; attempt++ )); do
    current=$(process_identity "$pid") || break
    [[ $current == "$identity" ]] || return 1
    sleep 0.05
  done
  if current=$(process_identity "$pid"); then
    [[ $current == "$identity" ]] || return 1
    kill -KILL "$pid"
  fi
  wait "$pid" 2>/dev/null || true
}
finish() {
  local rc=$?
  trap - EXIT
  set +e
  cleanup || rc=1
  if (( rc == 0 )); then
    mv "$out/result.pending.json" "$out/result.json" || rc=1
    if (( rc == 0 )); then cat "$out/result.json" || rc=1; fi
  fi
  printf '{"exit_code":%d}\n' "$rc" >"$out/status.json" || rc=1
  if (( rc != 0 )); then
    if [[ -f $out/result.json ]]; then
      mv "$out/result.json" "$out/result.pending.json" || echo 'could not retract result' >&2
    fi
    echo "workerd benchmark failed; logs: $out" >&2
    tail -n 10 "$out/workerd.stderr" >&2
  fi
  exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
{
  echo 'using Workerd = import "/workerd/workerd.capnp";'
  echo 'const config :Workerd.Config = (services = ['
  for (( i=1; i<=N; i++ )); do
    printf ' (name = "hello%d", worker = (modules = [(name = "hello.js", esModule = embed "hello_worker.js")], compatibilityDate = "2025-01-01")),\n' "$i"
  done
  echo '], sockets = ['
  for (( i=1; i<=N; i++ )); do
    printf ' (name = "http%d", address = "127.0.0.1:0", http = (), service = "hello%d"),\n' "$i" "$i"
  done
  echo ']);'
} >"$out/workerd.capnp"
start=$(now_ns)
"$WORKERD" serve "$out/workerd.capnp" >"$out/workerd.stdout" 2>"$out/workerd.stderr" &
pid=$!
identity=$(process_identity "$pid") || { echo 'workerd exited at launch' >&2; exit 1; }
# The kernel chooses unused ports. Discover only listeners owned by this
# process; each configured service has exactly one localhost socket.
ports=()
while :; do
  elapsed=$(elapsed_ns "$start")
  (( elapsed < 30000000000 )) || break
  [[ $(process_identity "$pid") == "$identity" ]] || exit 1
  ss -H -ltnp >"$out/listeners"
  mapfile -t ports < <(awk -v owner="pid=$pid," 'index($0,owner) && $4 ~ /^127\.0\.0\.1:[0-9]+$/ {sub(/^.*:/,"",$4); print $4}' "$out/listeners" | sort -nu)
  (( ${#ports[@]} == N )) && break
  sleep 0.005
done
(( ${#ports[@]} == N )) || { echo 'workerd did not publish all listeners' >&2; exit 1; }
for (( i=0; i<N; i++ )); do
  sample=$(wait_http_exact "${ports[i]}" "$out/expected" "$out/service-$i.response" "$start")
  printf '%s\n' "$sample" >>"$out/response-end-ns"
done
sleep 0.5
[[ $(process_identity "$pid") == "$identity" ]] || { echo 'workerd exited before memory capture' >&2; exit 1; }
read_proc "/proc/$pid/smaps_rollup" >"$out/process.smaps"
pss=$(proc_key "$out/process.smaps" Pss:)
dirty=$(proc_key "$out/process.smaps" Private_Dirty:)
jq -cn --arg version "$version" --arg sha "$sha" --arg executable "$WORKERD" --argjson n "$N" --argjson pss "$pss" --argjson dirty "$dirty" --slurpfile samples "$out/response-end-ns" '{bench:"workerd",n:$n,workerd_version:$version,workerd_sha256:$sha,executable:$executable,clock:"CLOCK_REALTIME",probe_overhead_included:true,startup_definition:"process launch with N configured services to verified HTTP responses",process_to_first_response_ns:$samples[0],process_to_all_responses_ns:$samples[-1],service_response_end_ns:$samples,isolate_startup:"not_measured_independently",process_pss_kib:$pss,process_private_dirty_kib:$dirty}' >"$out/result.pending.json"
