#!/usr/bin/env bash
# Runs the I/O comparison described in README.md: collo serve, Bun.serve and
# Bun's node:http2 server answering the same handler over TLS on loopback,
# measured by loadgen.mjs at each concurrency level.
#
# Every repetition starts each server fresh in its own cgroup scope under the
# delegated subtree, so the scope's cpu.stat holds every process of that
# server (Collo's server, zygote, gateway and workers). The server order
# rotates between repetitions. Before each run the script waits, up to
# QUIET_WAIT_S, until the machine as a whole uses less than QUIET_CORES.
# The certificate, key and the copies of the configuration and handlers live
# in WORK_DIR, so collo.json's relative paths resolve there.
#
# Requires `wsl-config prepare` for this boot and a built `collo`. Uses sudo
# only for the first hop into the delegated subtree (`wsl-config run`); set
# SUDO_PASSWORD to feed sudo -S instead of prompting.
#
#   COLLO_BIN=/path/to/release/bin/collo runtime/bench/io/run.sh
#
# Results go to OUT_DIR, by default a new directory under report/bench-io/,
# which git ignores: measurements stay on the machine that took them.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
collo=${COLLO_BIN:?set COLLO_BIN to the collo binary under test}
bun=${BUN_BIN:-$(command -v bun || echo "$HOME/.bun/bin/bun")}
node=${NODE_BIN:-$(command -v node || echo /usr/local/bin/node)}
wsl_config=$repo/zig-out/bin/wsl-config
work=${WORK_DIR:-${TMPDIR:-/tmp}/collo-bench-io}
out=${OUT_DIR:-$repo/report/bench-io/results-$(date -u +%Y%m%dT%H%M%SZ)}
reps=${REPS:-3}
warmup_s=${WARMUP_S:-5}
duration_s=${DURATION_S:-10}
levels=${LEVELS:-"1 16 64 256"}
mux_levels=${MUX_LEVELS:-"16 64 256"}
procs=${PROCS:-8}
streams_per_connection_max=64
quiet_cores=${QUIET_CORES:-3}
quiet_wait_s=${QUIET_WAIT_S:-120}
servers=(collo bun bun-h2)

declare -A port=([collo]=18443 [bun]=18444 [bun-h2]=18445)
declare -A proto=([collo]=h2 [bun]=h1 [bun-h2]=h2)

mkdir -p "$work" "$out/raw" "$out/logs"
commands=$out/commands.log
: > "$commands"

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$out/progress.log" >&2; }

run_sudo() {
  if [[ -n ${SUDO_PASSWORD:-} ]]; then
    printf '%s\n' "$SUDO_PASSWORD" | sudo -S -p "" "$@"
  else
    sudo "$@"
  fi
}

# Busy cores over one second, summed over every CPU.
busy_cores() {
  local a b
  read -r -a a < <(head -1 /proc/stat)
  sleep 1
  read -r -a b < <(head -1 /proc/stat)
  local busy=$(( (b[1]+b[2]+b[3]+b[6]+b[7]+b[8]) - (a[1]+a[2]+a[3]+a[6]+a[7]+a[8]) ))
  local idle=$(( (b[4]+b[5]) - (a[4]+a[5]) ))
  awk -v busy="$busy" -v idle="$idle" -v cpus="$(nproc)" 'BEGIN { printf "%.2f", busy * cpus / (busy + idle) }'
}

wait_quiet() {
  local waited=0 cores
  while :; do
    cores=$(busy_cores)
    if awk -v c="$cores" -v q="$quiet_cores" 'BEGIN { exit !(c < q) }'; then break; fi
    if (( waited >= quiet_wait_s )); then
      log "machine still busy ($cores cores) after ${quiet_wait_s}s; running anyway"
      break
    fi
    waited=$((waited + 1))
  done
}

# The process of the scope whose parent is outside it: the server itself.
scope_root_pid() {
  local scope=$1 pid ppid
  local pids
  pids=$(cat "$scope/main/cgroup.procs")
  for pid in $pids; do
    ppid=$(awk '{ print $4 }' "/proc/$pid/stat" 2>/dev/null) || continue
    if ! grep -qx "$ppid" <<<"$pids"; then echo "$pid"; return; fi
  done
}

server_command() {
  local name=$1
  case $name in
    collo) echo "$collo serve $work/collo.json --listen 127.0.0.1:${port[collo]}" ;;
    bun) echo "env PORT=${port[bun]} TLS_CERT=$work/cert.pem TLS_KEY=$work/key.pem $bun $work/hello-bun.js" ;;
    bun-h2) echo "env PORT=${port[bun-h2]} TLS_CERT=$work/cert.pem TLS_KEY=$work/key.pem $bun $work/hello-bun-h2.js" ;;
  esac
}

sudo_pid=
server_pid=
scope=
server_log=

start_server() {
  local name=$1 rep=$2
  scope=/sys/fs/cgroup/collo-dev/collo-bench-io-$name-r$rep
  server_log=$out/logs/$name-r$rep.log
  "$wsl_config" scope-create "$scope"
  local cmd
  cmd=$(server_command "$name")
  echo "COLLO_TEST_CGROUP=$scope/main COLLO_WORKER_CGROUP_ROOT=$scope/workers sudo --preserve-env=PATH $wsl_config run -- $cmd" >> "$commands"
  # shellcheck disable=SC2086
  run_sudo --preserve-env=PATH COLLO_TEST_CGROUP="$scope/main" COLLO_WORKER_CGROUP_ROOT="$scope/workers" \
    "$wsl_config" run -- $cmd > "$server_log" 2>&1 &
  sudo_pid=$!
  local i
  for i in $(seq 1 300); do
    if grep -q "listening on" "$server_log"; then break; fi
    if ! kill -0 "$sudo_pid" 2>/dev/null; then log "$name exited during boot"; cat "$server_log" >&2; exit 1; fi
    sleep 0.2
  done
  grep -q "listening on" "$server_log" || { log "$name did not start"; exit 1; }
  server_pid=$(scope_root_pid "$scope")
  # The first request makes Collo fork its first worker; it is not measured.
  local curl_proto=--http2
  [[ ${proto[$name]} == h1 ]] && curl_proto=--http1.1
  for i in $(seq 1 150); do
    if [[ $(curl -s -o /dev/null -w '%{http_code}' $curl_proto --cacert "$work/cert.pem" "https://127.0.0.1:${port[$name]}/") == 200 ]]; then break; fi
    sleep 0.2
  done
  log "$name r$rep listening (pid $server_pid, scope $scope)"
}

# An interrupted run still stops its server and removes the scope.
cleanup() {
  [[ -n $server_pid ]] || return 0
  kill -INT "$server_pid" 2>/dev/null || true
  wait "$sudo_pid" 2>/dev/null || true
  sleep 2
  if ! "$wsl_config" scope-remove "$scope" 2>/dev/null; then
    "$wsl_config" scope-kill "$scope" 2>/dev/null || true
    sleep 1
    "$wsl_config" scope-remove "$scope" 2>/dev/null || true
  fi
}
trap cleanup EXIT

stop_server() {
  local name=$1 status=0
  kill -INT "$server_pid"
  wait "$sudo_pid" || status=$?
  server_pid=
  echo "$status" > "${server_log%.log}.exit"
  local i
  for i in $(seq 1 75); do
    grep -q "^populated 0" "$scope/cgroup.events" && break
    sleep 0.2
  done
  if ! grep -q "^populated 0" "$scope/cgroup.events"; then
    log "$name left processes in $scope; killing them"
    "$wsl_config" scope-kill "$scope"
  fi
  "$wsl_config" scope-remove "$scope"
  log "$name stopped, exit status $status"
}

run_level() {
  local name=$1 rep=$2 layout=$3 concurrency=$4 connections streams
  if [[ $layout == conn ]]; then
    connections=$concurrency
    streams=1
  else
    connections=$(( (concurrency + streams_per_connection_max - 1) / streams_per_connection_max ))
    streams=$(( concurrency / connections ))
  fi
  local result=$out/raw/$name-$layout-c$concurrency-r$rep.json
  local args=(--url "https://127.0.0.1:${port[$name]}/" --proto "${proto[$name]}" --connections "$connections"
    --streams "$streams" --procs "$procs" --warmup-s "$warmup_s" --duration-s "$duration_s" --ca "$work/cert.pem"
    --cgroup "$scope" --label "$name" --out "$result")
  [[ $name == collo ]] && args+=(--log-file "$server_log" --log-pattern "worker liveness closed")
  wait_quiet
  echo "$node $here/loadgen.mjs ${args[*]}" >> "$commands"
  local status=0
  "$node" "$here/loadgen.mjs" "${args[@]}" || status=$?
  if [[ -f $result ]]; then
    log "$name $layout c=$concurrency r$rep: $("$node" -e '
      const r = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
      const errors = Object.values(r.errors).reduce((a, b) => a + b, 0);
      console.log(`${Math.round(r.rps)} req/s p50 ${r.latencyUs?.p50} us p99 ${r.latencyUs?.p99} us errors ${errors} server ${r.cpu.serverCores?.toFixed(2)} cores client max ${r.cpu.clientCoresMax.toFixed(2)} other ${r.cpu.otherCores?.toFixed(2)}`);
    ' "$result") (exit $status)"
  else
    log "$name $layout c=$concurrency r$rep: no result (exit $status)"
  fi
}

write_environment() {
  local head
  head=$(cat "$repo/.git/HEAD")
  if [[ $head == ref:* ]]; then head="${head#ref: } $(cat "$repo/.git/${head#ref: }" 2>/dev/null || echo unknown)"; fi
  "$node" -e '
    const fs = require("fs");
    const os = require("os");
    const [out, collo, colloSha, colloMtime, bunVersion, head, nodePath] = process.argv.slice(1);
    const cpuinfo = fs.readFileSync("/proc/cpuinfo", "utf8");
    const meminfo = fs.readFileSync("/proc/meminfo", "utf8");
    fs.writeFileSync(out, JSON.stringify({
      date: new Date().toISOString(),
      cpuModel: /model name\s*:\s*(.*)/.exec(cpuinfo)[1],
      logicalCpus: os.cpus().length,
      memTotalKiB: Number(/MemTotal:\s*(\d+)/.exec(meminfo)[1]),
      kernel: os.release(),
      collo: { binary: collo, sha256: colloSha, modified: colloMtime, optimize: "ReleaseFast", jscProfile: "release", worktreeHead: head },
      bun: bunVersion,
      node: { path: nodePath, version: process.version },
      settings: { reps: Number(process.env.REPS_), warmupS: Number(process.env.WARMUP_), durationS: Number(process.env.DURATION_), procs: Number(process.env.PROCS_) },
    }, null, 2) + "\n");
  ' "$out/environment.json" "$collo" "$(sha256sum "$collo" | cut -d" " -f1)" "$(date -u -r "$collo" +%Y-%m-%dT%H:%M:%SZ)" \
    "$("$bun" --version)" "$head" "$node"
}

openssl_cert() {
  [[ -f $work/cert.pem && -f $work/key.pem ]] && return
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$work/key.pem" -out "$work/cert.pem" \
    -days 30 -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null
}

openssl_cert
cp "$here/collo.json" "$here/hello-collo.js" "$here/hello-bun.js" "$here/hello-bun-h2.js" "$work/"
REPS_=$reps WARMUP_=$warmup_s DURATION_=$duration_s PROCS_=$procs write_environment
log "results in $out"

for rep in $(seq 1 "$reps"); do
  order=("${servers[@]:$(( (rep - 1) % ${#servers[@]} ))}" "${servers[@]:0:$(( (rep - 1) % ${#servers[@]} ))}")
  for name in "${order[@]}"; do
    start_server "$name" "$rep"
    for concurrency in $levels; do run_level "$name" "$rep" conn "$concurrency"; done
    if [[ ${proto[$name]} == h2 ]]; then
      for concurrency in $mux_levels; do run_level "$name" "$rep" mux "$concurrency"; done
    fi
    stop_server "$name"
  done
done
log "done"
