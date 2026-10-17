#!/usr/bin/env bash
# Collo, workerd and Bun serving the cases in cases/ over TLS at full load, one
# process tree each on one server CPU, with oha on the client CPUs. README.md
# describes the method; bench.js is the driver.
#
#   ./run.sh setup     installs the pinned Bun and oha into .tools/ and the
#                      pinned packages into node_modules/, bundles the cases
#                      into dist/ and makes the certificate
#   ./run.sh prepare   creates the bench's cgroup subtree and delegates it to
#                      this user (sudo, once per boot)
#   ./run.sh check     every runtime answers every check in cases/requests.js
#   ./run.sh measure   one session into results/<UTC stamp>/: runs.jsonl,
#                      environment.txt, summary.md, servers.log
#   ./run.sh unprepare removes the cgroup subtree once it is empty (sudo)
#
# check and measure need COLLO, the collo binary under test, and run the driver
# inside the subtree through sudo, which reads its password from SUDO_PASSWORD
# when set.
#
# Settings, with their defaults:
#   COLLO               the collo binary under test (required by check and measure)
#   SERVER_CPU 1        the CPU every runtime runs on
#   CLIENT_CPU 2-3      the CPUs of the driver, curl and oha
#   REPS 5; CASES "hello api crypto"; RUNTIMES "collo workerd bun"
#   CONNECTIONS unset: a sweep picks it per case; set, it skips the sweep. On
#     a 4-CPU machine, 8: from about 32, workerd's event loop can go 5 s without
#     polling for I/O, and its keep-alive timeout then resets every waiting
#     connection
#   WINDOW 10, WARMUP 5, IDLE 10 (seconds)
#   QUIET_LOAD 2        each run waits until the 1-minute load is below it
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
HERE=$PWD
password=${SUDO_PASSWORD:-}
unset SUDO_PASSWORD

BUN_VERSION=1.4.3
OHA_VERSION=1.16.0
SPEED_BENCH_CGROUP=/sys/fs/cgroup/collo-speed-bench
case $(uname -m) in
  x86_64)
    bun_arch=x64 workerd_arch=64 oha_arch=amd64
    bun_sha256=3e730528d89775f03f87f05c06787c4df4099d0a37f3f252e7b829cb23816e18
    oha_sha256=620bb9e16fb53eabc9a3fc45f88bdb41fefa3fee5c05e75892011ce320391716
    ;;
  aarch64)
    bun_arch=aarch64 workerd_arch=arm64 oha_arch=arm64
    bun_sha256=efa9813da5ed72423bf847f916e8d2c47c0d776add972354026a75e10da9aa21
    oha_sha256=99a790eb8c3e0feaca974bd6b32f0f8d4426a0c5b289f39e833e5b2c7529cd39
    ;;
  *) echo "unsupported machine $(uname -m)" >&2; exit 2 ;;
esac

ALL_CASES="hello api crypto"
TOOLS=$HERE/.tools
BUN=$TOOLS/bun
OHA=$TOOLS/oha
WORKERD=$HERE/node_modules/@cloudflare/workerd-linux-$workerd_arch/bin/workerd
COLLO=${COLLO:-}
SERVER_CPU=${SERVER_CPU:-1}
CLIENT_CPU=${CLIENT_CPU:-2-3}
REPS=${REPS:-5}
CASES=${CASES:-$ALL_CASES}
RUNTIMES=${RUNTIMES:-collo workerd bun}
CONNECTIONS=${CONNECTIONS:-}
WINDOW=${WINDOW:-10}
WARMUP=${WARMUP:-5}
IDLE=${IDLE:-10}
QUIET_LOAD=${QUIET_LOAD:-2}
SETTINGS=(COLLO WORKERD BUN OHA SPEED_BENCH_CGROUP SERVER_CPU CLIENT_CPU REPS CASES RUNTIMES CONNECTIONS WINDOW WARMUP IDLE QUIET_LOAD)
export "${SETTINGS[@]}"

die() { echo "$*" >&2; exit 1; }

as_root() {
  if [[ -n $password ]]; then
    printf '%s\n' "$password" | sudo -S -p '' "$@"
  else
    sudo "$@"
  fi
}

# Downloads <url> to <file> and keeps it only when its <sha>sum is <sum>.
fetch() {
  local url=$1 sha=$2 sum=$3 file=$4
  curl -fsSL "$url" -o "$file.download"
  echo "$sum  $file.download" | "${sha}sum" --check --quiet || { rm -f "$file.download"; die "$url does not match its pinned checksum"; }
  mv "$file.download" "$file"
}

setup() {
  mkdir -p "$TOOLS" dist
  if [[ ! -x $BUN ]]; then
    fetch "https://github.com/oven-sh/bun/releases/download/bun-v$BUN_VERSION/bun-linux-$bun_arch.zip" sha256 "$bun_sha256" "$TOOLS/bun.zip"
    unzip -p "$TOOLS/bun.zip" "bun-linux-$bun_arch/bun" > "$BUN"
    chmod +x "$BUN"
    rm "$TOOLS/bun.zip"
  fi
  [[ $("$BUN" --version) == "$BUN_VERSION" ]] || die "$BUN is Bun $("$BUN" --version), the pin is $BUN_VERSION"
  if [[ ! -x $OHA ]]; then
    fetch "https://github.com/hatoo/oha/releases/download/v$OHA_VERSION/oha-linux-$oha_arch" sha256 "$oha_sha256" "$OHA"
    chmod +x "$OHA"
  fi
  [[ $("$OHA" --version) == "oha $OHA_VERSION" ]] || die "$OHA is $("$OHA" --version), the pin is $OHA_VERSION"
  "$BUN" install --frozen-lockfile
  for name in $ALL_CASES; do
    "$BUN" build "cases/$name.js" --target=browser --format=esm --minify --outfile="dist/$name.js"
  done
  if [[ ! -f dist/cert.pem ]]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 -subj /CN=localhost \
      -addext subjectAltName=DNS:localhost,IP:127.0.0.1 -keyout dist/key.pem -out dist/cert.pem 2> /dev/null
  fi
}

# Enables cpu, memory and pids at the cgroup2 root, makes the subtree with its
# runner leaf, enables the three for the subtree's children, and hands both
# directories and the control files /sys/kernel/cgroup/delegate lists to this
# user, so the driver and the runtimes it starts manage their scopes without
# root.
prepare() {
  # shellcheck disable=SC2016 # the root shell expands its own arguments
  as_root sh -c '
    set -e
    subtree=$1 owner=$2
    for controller in cpu memory pids; do
      grep -qw "$controller" /sys/fs/cgroup/cgroup.subtree_control || echo "+$controller" > /sys/fs/cgroup/cgroup.subtree_control
    done
    mkdir -p "$subtree/runner"
    echo "+cpu +memory +pids" > "$subtree/cgroup.subtree_control"
    for directory in "$subtree" "$subtree/runner"; do
      chown "$owner" "$directory"
      for file in $(cat /sys/kernel/cgroup/delegate); do
        if [ -e "$directory/$file" ]; then chown "$owner" "$directory/$file"; fi
      done
    done
  ' sh "$SPEED_BENCH_CGROUP" "$(id -u):$(id -g)"
}

require_tools() {
  [[ -n $COLLO && -x $COLLO ]] || die "COLLO must name the collo binary under test"
  for tool in "$WORKERD" "$BUN" "$OHA"; do [[ -x $tool ]] || die "$tool is missing; run ./run.sh setup"; done
  [[ -w $SPEED_BENCH_CGROUP/runner/cgroup.procs ]] || die "$SPEED_BENCH_CGROUP is not prepared for this user; run ./run.sh prepare"
}

# Runs the driver with Bun as this user inside the subtree's runner, pinned to
# CLIENT_CPU (oha and curl inherit it), with the settings in its environment:
# root moves the shell into the runner, which only root may do from outside
# the subtree, then setpriv drops back to this user and execs the driver in the
# same process, so it can move each runtime into its scope.
in_subtree() {
  # shellcheck disable=SC2016 # the root shell expands its own arguments
  as_root --preserve-env="PATH,HOME,$(IFS=,; echo "${SETTINGS[*]}")" sh -c \
    'subtree=$1 user=$2 group=$3 cpus=$4; shift 4; echo $$ > "$subtree/runner/cgroup.procs" && exec setpriv --reuid="$user" --regid="$group" --init-groups -- taskset -c "$cpus" "$@"' \
    sh "$SPEED_BENCH_CGROUP" "$(id -u)" "$(id -g)" "$CLIENT_CPU" "$BUN" "$@"
}

sha256() { sha256sum "$1" | cut -d' ' -f1; }

environment() {
  echo "cpu: $(lscpu | sed -n 's/^Model name: *//p'), online $(< /sys/devices/system/cpu/online)"
  echo "kernel: $(uname -r), page size $(getconf PAGESIZE) bytes"
  echo "collo: $COLLO, sha256 $(sha256 "$COLLO")"
  echo "workerd: $("$WORKERD" --version), sha256 $(sha256 "$WORKERD")"
  echo "bun: $("$BUN" --version), sha256 $(sha256 "$BUN")"
  echo "oha: $("$OHA" --version), sha256 $(sha256 "$OHA")"
  echo "hono: $("$BUN" -p 'require("./node_modules/hono/package.json").version')"
  echo "settings: SERVER_CPU=$SERVER_CPU CLIENT_CPU=$CLIENT_CPU REPS=$REPS CASES=\"$CASES\" RUNTIMES=\"$RUNTIMES\"" \
    "CONNECTIONS=${CONNECTIONS:-sweep} WINDOW=$WINDOW WARMUP=$WARMUP IDLE=$IDLE QUIET_LOAD=$QUIET_LOAD"
}

case ${1:-} in
  setup) setup ;;
  prepare) prepare ;;
  check)
    require_tools
    in_subtree bench.js check
    ;;
  measure)
    require_tools
    out=$HERE/results/$(date -u +%Y%m%dT%H%M%SZ)
    mkdir -p "$out"
    environment > "$out/environment.txt"
    in_subtree bench.js measure "$out"
    "$BUN" summarize.js "$out" > "$out/summary.md"
    cat "$out/summary.md"
    ;;
  unprepare) as_root rmdir "$SPEED_BENCH_CGROUP/runner" "$SPEED_BENCH_CGROUP" ;;
  *) die "usage: $0 setup | prepare | check | measure | unprepare" ;;
esac
