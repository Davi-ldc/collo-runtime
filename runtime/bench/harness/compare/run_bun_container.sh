#!/bin/bash
# Cold container create/start to verified HTTP 200. Image pulling is excluded.
# Memory is the Bun process PSS plus separate cgroup accounting, not Docker's
# entire host footprint. No memory or CPU limit is imposed by this runner.
set -euo pipefail
N=${1:-4}
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../lib.sh"
prepare_output bun-container
IMAGE=${IMAGE:-oven/bun:1.4-slim}
docker=(docker)
if ! timeout 10 docker info >"$out/docker-info" 2>"$out/docker-info.stderr"; then
  docker=(sudo -n docker)
  timeout 10 "${docker[@]}" info >"$out/docker-info" 2>>"$out/docker-info.stderr"
fi
docker_cmd() { timeout 30 "${docker[@]}" "$@"; }
token=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
cidfiles=()
cleanup() {
  local file id label log failed=0
  # The daemon may create a container before a timed-out client writes its
  # cidfile. The run label, not that file, identifies everything we own.
  docker_cmd ps -aq --no-trunc --filter "label=collo.harness.run=$token" \
    >"$out/cleanup.ids" 2>"$out/cleanup.stderr" || return 1
  while IFS= read -r id; do
    [[ $id =~ ^[0-9a-f]{64}$ ]] || { failed=1; continue; }
    label=$(docker_cmd inspect -f '{{index .Config.Labels "collo.harness.run"}}' "$id" 2>>"$out/cleanup.stderr") || {
      failed=1; continue;
    }
    [[ $label == "$token" ]] || { failed=1; continue; }
    log="$out/cleanup-$id.log"
    for file in "${cidfiles[@]}"; do
      if [[ -s $file && $(<"$file") == "$id" ]]; then log="${file%.cid}.log"; break; fi
    done
    docker_cmd logs "$id" >"$log" 2>&1 || failed=1
    docker_cmd rm -f "$id" >/dev/null 2>>"$out/cleanup.stderr" || failed=1
  done <"$out/cleanup.ids"
  docker_cmd ps -aq --no-trunc --filter "label=collo.harness.run=$token" \
    >"$out/cleanup.remaining.ids" 2>>"$out/cleanup.stderr" || return 1
  [[ ! -s $out/cleanup.remaining.ids ]] || failed=1
  return "$failed"
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
    echo "container benchmark failed; logs: $out" >&2
  fi
  exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
docker_cmd image inspect "$IMAGE" >"$out/image.json"
image_id=$(jq -er '.[0].Id' "$out/image.json")
cp "$here/server.js" "$out/server.js"
printf 'hello from bun: GET /hi\n' >"$out/expected"
# Verify the actual pinned image version before starting any timed sample.
version_cid="$out/version.cid"
cidfiles+=("$version_cid")
docker_cmd run --rm --pull=never --cidfile "$version_cid" --label "collo.harness.run=$token" "$image_id" bun --version >"$out/bun-version" 2>"$out/version.stderr"
version=$(<"$out/bun-version")
[[ $version =~ ^1\.4\.[0-9]+ ]] || { echo "expected Bun 1.4, got $version" >&2; exit 1; }
ids=()
for (( i=1; i<=N; i++ )); do
  cid="$out/container-$i.cid"
  cidfiles+=("$cid")
  start=$(now_ns)
  docker_cmd run -d --pull=never --cidfile "$cid" --name "collo-harness-$token-$i" --label "collo.harness.run=$token" -p 127.0.0.1::3000 -v "$out:/app:ro" "$image_id" bun /app/server.js >"$out/container-$i.start.stdout" 2>"$out/container-$i.start.stderr"
  id=$(<"$cid")
  [[ $id =~ ^[0-9a-f]{64}$ ]] || exit 1
  ids+=("$id")
  docker_cmd inspect "$id" >"$out/container-$i.inspect.json"
  port=$(jq -er '.[0].NetworkSettings.Ports["3000/tcp"] | select(length == 1) | .[0] | select(.HostIp == "127.0.0.1") | .HostPort' "$out/container-$i.inspect.json")
  sample=$(wait_http_exact "$port" "$out/expected" "$out/container-$i.response" "$start")
  printf '%s\n' "$sample" >>"$out/startup-ns"
done
sleep 0.5
for (( i=1; i<=N; i++ )); do
  id=${ids[i-1]}
  docker_cmd inspect "$id" >"$out/container-$i.inspect.json"
  pid=$(jq -er '.[0].State | select(.Running == true) | .Pid | select(. > 0)' "$out/container-$i.inspect.json")
  read_proc "/proc/$pid/smaps_rollup" >"$out/container-$i.smaps"
  pss=$(proc_key "$out/container-$i.smaps" Pss:)
  dirty=$(proc_key "$out/container-$i.smaps" Private_Dirty:)
  read_proc "/proc/$pid/cgroup" >"$out/container-$i.cgroup"
  cg=$(awk -F: '$1 == "0" {print $3}' "$out/container-$i.cgroup")
  [[ $cg == /* && $cg != / && $cg != *..* ]] || { echo 'requires a visible cgroup v2 container' >&2; exit 1; }
  current=$(read_proc "/sys/fs/cgroup$cg/memory.current")
  [[ $current =~ ^[0-9]+$ ]] || exit 1
  jq -cn --arg id "$id" --argjson pid "$pid" --argjson pss "$pss" --argjson dirty "$dirty" --argjson current "$current" '{id:$id,pid:$pid,pss_kib:$pss,private_dirty_kib:$dirty,cgroup_memory_current_bytes:$current}' >>"$out/instances.jsonl"
done
jq -cn --arg bench bun_container --arg image "$image_id" --arg version "$version" --argjson n "$N" --slurpfile image_info "$out/image.json" --slurpfile instances "$out/instances.jsonl" --slurpfile samples "$out/startup-ns" '{bench:$bench,n:$n,image_id:$image,image_digests:$image_info[0][0].RepoDigests,bun_version:$version,clock:"CLOCK_REALTIME",probe_overhead_included:true,startup_definition:"docker run invocation to first verified HTTP response; preloaded image",cpu_limit:"unlimited",memory_limit_bytes:0,shim_memory:"not_measured",daemon_memory:"not_included",startup_ns:$samples,instances:$instances,process_pss_total_kib:([$instances[].pss_kib]|add),process_private_dirty_total_kib:([$instances[].private_dirty_kib]|add),process_pss_per_instance_kib:(([$instances[].pss_kib]|add)/$n),cgroup_memory_current_total_bytes:([$instances[].cgroup_memory_current_bytes]|add)}' >"$out/result.pending.json"
