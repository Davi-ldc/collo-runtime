#!/bin/bash
# Checks the complete CLI response bytes, then kills the host of a pending
# request. Only the captured host/zygote/worker identities count toward
# teardown; unrelated Collo processes are neither counted nor signalled.
# Usage: cli_smoke.sh <collo-binary> <outdir>. The POC runner bounds total wall time.
set -euo pipefail
bin=${1:?collo binary}
out=${2:?output dir}
mkdir -p "$out"
owned=()
host=

# /proc comm can contain spaces and closing parentheses. Fields after the
# final ') ' start at state (3); index 19 is starttime (22), in clock ticks.
process_identity() {
  local pid=$1 stat rest
  local -a fields
  [[ $pid =~ ^[1-9][0-9]*$ ]] || return 1
  stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
  rest=${stat##*) }
  read -r -a fields <<< "$rest"
  (( ${#fields[@]} >= 20 )) || return 1
  [[ ${fields[0]} != Z && ${fields[0]} != X && ${fields[19]} =~ ^[0-9]+$ ]] || return 1
  printf '%s:%s\n' "$pid" "${fields[19]}"
}

is_live() {
  local identity=$1 current
  current=$(process_identity "${identity%%:*}") || return 1
  [[ $current == "$identity" ]]
}

only_child() {
  local pid=$1 text
  local -a children
  text=$(cat "/proc/$pid/task/$pid/children" 2>/dev/null) || return 1
  read -r -a children <<< "$text"
  (( ${#children[@]} == 1 )) || return 1
  printf '%s\n' "${children[0]}"
}

cleanup() {
  local rc=$? identity i
  trap - EXIT
  for (( i=${#owned[@]}-1; i>=0; i-- )); do
    identity=${owned[i]}
    if is_live "$identity"; then
      kill -KILL "${identity%%:*}" 2>/dev/null || true
    fi
  done
  if [[ -n $host ]]; then wait "$host" 2>/dev/null || true; fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cat > "$out/hello.js" <<'JS'
export default function handle(request) {
  const url = new URL(request.url);
  return new Response(`hello from collo: ${request.method} ${url.pathname}\n`, {
    headers: { "content-type": "text/plain" },
  });
}
JS
cat > "$out/slow.js" <<'JS'
export default async function handle(request) {
  await new Promise((resolve) => setTimeout(resolve, 20000));
  return new Response("slow\n");
}
JS
printf 'HTTP 200 (ok)\ncontent-type: text/plain\r\n\nhello from collo: POST /hi\n' > "$out/expected"
t0=$(date +%s%N)
rc=0
"$bin" run "$out/hello.js" --method POST --path /hi --body x >"$out/stdout" 2>"$out/stderr" || rc=$?
wall_ms=$(( ($(date +%s%N) - t0) / 1000000 ))
if (( rc != 0 )) || ! cmp -s "$out/stdout" "$out/expected" || [[ -s $out/stderr ]]; then
  printf 'cli smoke: response failed, exit=%d; see %s/stdout and stderr\n' "$rc" "$out" >&2
  exit 1
fi

"$bin" run "$out/slow.js" >"$out/kill-stdout" 2>"$out/kill-stderr" &
host=$!
host_identity=$(process_identity "$host") || { echo 'cli smoke: host exited before capture' >&2; exit 1; }
owned=("$host_identity")
running=0
for (( attempt=0; attempt<100; attempt++ )); do
  is_live "$host_identity" || break
  if zygote_pid=$(only_child "$host") && zygote_identity=$(process_identity "$zygote_pid"); then
    owned=("$host_identity" "$zygote_identity")
    if worker_pid=$(only_child "$zygote_pid") && worker_identity=$(process_identity "$worker_pid"); then
      owned+=("$worker_identity")
      if is_live "$host_identity" && is_live "$zygote_identity" && is_live "$worker_identity"; then
        running=3
        break
      fi
    fi
  fi
  sleep 0.05
done
if (( running != 3 )); then
  echo 'cli smoke: did not observe a live host, zygote and worker' >&2
  exit 1
fi
printf '%s\n' "${owned[@]}" > "$out/process-identities"
# Keep the request pending before the kill rather than testing only the
# instant at which the worker process first exists.
sleep 1
for identity in "${owned[@]}"; do
  if ! is_live "$identity"; then
    echo 'cli smoke: process exited before the host kill' >&2
    exit 1
  fi
done
if [[ -s $out/kill-stdout || -s $out/kill-stderr ]]; then
  echo 'cli smoke: pending request completed or failed before the host kill' >&2
  exit 1
fi
kill -KILL "$host"
wait "$host" 2>/dev/null || true
survivors=3
for (( attempt=0; attempt<100; attempt++ )); do
  survivors=0
  for identity in "${owned[@]}"; do
    if is_live "$identity"; then (( survivors+=1 )); fi
  done
  (( survivors == 0 )) && break
  sleep 0.05
done
printf '{"bench":"cli_smoke","exit":%d,"wall_ms":%d,"stdout_exact":true,"stderr_bytes":0,"processes_while_running":%d,"survivors_after_kill":%d}\n' \
  "$rc" "$wall_ms" "$running" "$survivors"
(( survivors == 0 ))
