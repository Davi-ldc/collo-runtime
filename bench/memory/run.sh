#!/usr/bin/env bash
# The memory bench: what each added tenant costs Collo, workerd and Bun in
# gVisor as GKE Sandbox runs it, idle and under load. README.md describes the
# method; density.js is the driver.
#
#   ./run.sh setup          installs the pinned tools into .tools/ and the
#                           pinned packages into node_modules/, bundles the
#                           cases and makes the certificate
#   ./run.sh prepare        creates the bench's cgroup subtree and delegates it
#                           to this user (sudo, once per boot)
#   ./run.sh gvisor-setup   pulls the pinned image into containerd's namespace
#                           collo-memory-bench (sudo, once)
#   ./run.sh measure        one session into results/<UTC stamp>/
#   ./run.sh gvisor-revert  removes what the gvisor side left on the machine:
#                           containers, image and namespace in containerd,
#                           network namespaces, /run/collo-memory-bench (sudo)
#   ./run.sh unprepare      removes the cgroup subtree once it is empty (sudo)
#
# sudo reads its password from SUDO_PASSWORD when set; the gvisor side runs
# sudo -n during a session, so it needs sudo without a password.
#
# Settings, with their defaults:
#   COLLO               the collo binary under test (required by measure)
#   SERVER_CPU 1        the CPU every runtime and its sandboxes run on
#   CLIENT_CPU 2-3      the CPUs of the driver, curl and oha
#   QUIET_LOAD 2        each phase waits until the 1-minute load is below it
#   SIDES "collo workerd gvisor", and "workerd-static" for series and scenario
#   PHASES "idle", and "load", "series", "scenario", "sharing" (Collo only)
#   CASE hello, or hono, or crypto
#   TENANTS 16; REQUESTS 10 per new idle tenant; RATE 100 requests per second
#   per loaded tenant; WAIT_S 10; SERIES_S 300; SAMPLE_S 10; MEMORY_MIB 128
#   per tenant; SCENARIO_TENANTS "3 6 9"; SCENARIO_S 300; SHARING_TENANTS 8
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
HERE=$PWD
password=${SUDO_PASSWORD:-}
unset SUDO_PASSWORD

BUN_VERSION=1.4.3
OHA_VERSION=1.16.0
GVISOR_RELEASE=20261005.0
CNI_VERSION=1.9.1
# The multi-architecture index of debian:bookworm-slim; containerd picks the
# machine's image from it.
GVISOR_IMAGE=docker.io/library/debian:bookworm-slim@sha256:7c7b2c966bc9ee8cedfeef67e0e279108992c77681fa595db4a9d65c06ccc587
MEMORY_BENCH_CGROUP=/sys/fs/cgroup/collo-memory-bench
case $(uname -m) in
  x86_64)
    bun_arch=x64 workerd_arch=64 oha_arch=amd64 cni_arch=amd64
    bun_sha256=3e730528d89775f03f87f05c06787c4df4099d0a37f3f252e7b829cb23816e18
    oha_sha256=620bb9e16fb53eabc9a3fc45f88bdb41fefa3fee5c05e75892011ce320391716
    gvisor_sha512=27fed731b432d6a39d908956623fd273979fda66b3ccf4b9c12413ea417c516e18a9dc3cced403fb28efe495d64dce4251f51cf8c4d9f4a72f9833bd96b6bb35
    cni_sha256=b98f74a0f8522f0a83867178729c1aa70f2158f90c45a2ca8fa791db1c76b303
    ;;
  aarch64)
    bun_arch=aarch64 workerd_arch=arm64 oha_arch=arm64 cni_arch=arm64
    bun_sha256=efa9813da5ed72423bf847f916e8d2c47c0d776add972354026a75e10da9aa21
    oha_sha256=99a790eb8c3e0feaca974bd6b32f0f8d4426a0c5b289f39e833e5b2c7529cd39
    gvisor_sha512=cb1c1ac7616f1f0e2287d39660aa9a65f1d81b866c7fa29457f78da62373baadda2d55aa96a200743dfe56193e43d2b6256af23a23d41d0b49a49b4971982435
    cni_sha256=56171987d3947707c3563db2f4001bccaf50fd63468611b9f3cbecb1375ee7ec
    ;;
  *) echo "unsupported machine $(uname -m)" >&2; exit 2 ;;
esac

TOOLS=$HERE/.tools
BUN=$TOOLS/bun
OHA=$TOOLS/oha
RUNSC=$TOOLS/runsc
RUNSC_SHIM=$TOOLS/containerd-shim-runsc-v1
CNI_DIR=$TOOLS/cni
WORKERD=$HERE/node_modules/@cloudflare/workerd-linux-$workerd_arch/bin/workerd
COLLO=${COLLO:-}
SERVER_CPU=${SERVER_CPU:-1}
CLIENT_CPU=${CLIENT_CPU:-2-3}
QUIET_LOAD=${QUIET_LOAD:-2}
SIDES=${SIDES:-collo workerd gvisor}
PHASES=${PHASES:-idle}
CASE=${CASE:-hello}
TENANTS=${TENANTS:-16}
REQUESTS=${REQUESTS:-10}
RATE=${RATE:-100}
WAIT_S=${WAIT_S:-10}
SERIES_S=${SERIES_S:-300}
SAMPLE_S=${SAMPLE_S:-10}
MEMORY_MIB=${MEMORY_MIB:-128}
SCENARIO_TENANTS=${SCENARIO_TENANTS:-3 6 9}
SCENARIO_S=${SCENARIO_S:-300}
SHARING_TENANTS=${SHARING_TENANTS:-8}
SETTINGS=(COLLO WORKERD BUN OHA RUNSC RUNSC_SHIM CNI_DIR GVISOR_IMAGE MEMORY_BENCH_CGROUP SERVER_CPU CLIENT_CPU QUIET_LOAD
  SIDES PHASES CASE TENANTS REQUESTS RATE WAIT_S SERIES_S SAMPLE_S MEMORY_MIB SCENARIO_TENANTS SCENARIO_S SHARING_TENANTS)
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
  # The release's runsc starts its sandbox from the binaries in gvisor-bin/
  # beside it, so the whole release goes in.
  if [[ ! -x $RUNSC || ! -x $RUNSC_SHIM || ! -d $TOOLS/gvisor-bin ]]; then
    fetch "https://storage.googleapis.com/gvisor/releases/release/$GVISOR_RELEASE/$(uname -m)/gvisor.tar.zstd" sha512 "$gvisor_sha512" "$TOOLS/gvisor.tar.zstd"
    tar --zstd -xf "$TOOLS/gvisor.tar.zstd" -C "$TOOLS" runsc containerd-shim-runsc-v1 gvisor-bin
    rm "$TOOLS/gvisor.tar.zstd"
  fi
  [[ $("$RUNSC" --version | head -1) == "runsc version release-$GVISOR_RELEASE" ]] || die "$RUNSC is not gVisor release $GVISOR_RELEASE"
  if [[ ! -x $CNI_DIR/ptp ]]; then
    fetch "https://github.com/containernetworking/plugins/releases/download/v$CNI_VERSION/cni-plugins-linux-$cni_arch-v$CNI_VERSION.tgz" sha256 "$cni_sha256" "$TOOLS/cni.tgz"
    mkdir -p "$CNI_DIR"
    tar -xzf "$TOOLS/cni.tgz" -C "$CNI_DIR" ./ptp ./host-local
    rm "$TOOLS/cni.tgz"
  fi
  "$BUN" install --frozen-lockfile
  for name in hello hono crypto; do
    "$BUN" build "cases/$name.js" --target=browser --format=esm --minify --outfile="dist/$name.js"
  done
  if [[ ! -f dist/cert.pem ]]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 -subj /CN=localhost \
      -addext subjectAltName=DNS:localhost,IP:127.0.0.1 -keyout dist/key.pem -out dist/cert.pem 2> /dev/null
  fi
}

# Enables cpuset, cpu, memory and pids at the cgroup2 root, makes the subtree
# with its runner leaf, enables the four for the subtree's children, and hands
# both directories and the control files /sys/kernel/cgroup/delegate lists to
# this user, so the driver and the runtimes it starts manage their scopes
# without root.
prepare() {
  # shellcheck disable=SC2016 # the root shell expands its own arguments
  as_root sh -c '
    set -e
    subtree=$1 owner=$2
    for controller in cpuset cpu memory pids; do
      grep -qw "$controller" /sys/fs/cgroup/cgroup.subtree_control || echo "+$controller" > /sys/fs/cgroup/cgroup.subtree_control
    done
    mkdir -p "$subtree/runner"
    echo "+cpuset +cpu +memory +pids" > "$subtree/cgroup.subtree_control"
    for directory in "$subtree" "$subtree/runner"; do
      chown "$owner" "$directory"
      for file in $(cat /sys/kernel/cgroup/delegate); do
        if [ -e "$directory/$file" ]; then chown "$owner" "$directory/$file"; fi
      done
    done
  ' sh "$MEMORY_BENCH_CGROUP" "$(id -u):$(id -g)"
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
  if [[ $SIDES == *gvisor* ]]; then
    echo "gvisor: $("$RUNSC" --version | head -1), runsc sha256 $(sha256 "$RUNSC"), shim sha256 $(sha256 "$RUNSC_SHIM"), $(ctr --version), CNI plugins v$CNI_VERSION, image $GVISOR_IMAGE"
  fi
  local setting
  for setting in SERVER_CPU CLIENT_CPU QUIET_LOAD SIDES PHASES CASE TENANTS REQUESTS RATE WAIT_S SERIES_S SAMPLE_S MEMORY_MIB SCENARIO_TENANTS SCENARIO_S SHARING_TENANTS; do
    echo "setting: $setting=${!setting}"
  done
}

measure() {
  [[ -n $COLLO && -x $COLLO ]] || die "COLLO must name the collo binary under test"
  for tool in "$BUN" "$OHA" "$WORKERD"; do [[ -x $tool ]] || die "$tool is missing; run ./run.sh setup"; done
  if [[ $SIDES == *gvisor* ]]; then
    for tool in "$RUNSC" "$RUNSC_SHIM" "$CNI_DIR/ptp"; do [[ -x $tool ]] || die "$tool is missing; run ./run.sh setup"; done
  fi
  [[ -w $MEMORY_BENCH_CGROUP/runner/cgroup.procs ]] || die "$MEMORY_BENCH_CGROUP is not prepared for this user; run ./run.sh prepare"
  local out
  out=$HERE/results/$(date -u +%Y%m%dT%H%M%SZ)
  mkdir -p "$out"
  environment > "$out/environment.txt"
  # Root moves the shell into the subtree's runner, which only root may do from
  # outside the subtree, then setpriv drops back to this user and execs the
  # driver in the same process, so every page the driver faults is charged
  # there and it can move the runtimes into their scopes.
  # shellcheck disable=SC2016 # the root shell expands its own arguments
  as_root --preserve-env="PATH,HOME,$(IFS=,; echo "${SETTINGS[*]}")" sh -c \
    'echo $$ > "$1/runner/cgroup.procs" && exec setpriv --reuid="$2" --regid="$3" --init-groups -- taskset -c "$4" "$5" density.js measure "$6"' \
    sh "$MEMORY_BENCH_CGROUP" "$(id -u)" "$(id -g)" "$CLIENT_CPU" "$BUN" "$out"
  cat "$out/summary.md"
}

case ${1:-} in
  setup) setup ;;
  prepare) prepare ;;
  gvisor-setup) as_root ctr -n collo-memory-bench image pull "$GVISOR_IMAGE" ;;
  measure) measure ;;
  gvisor-revert)
    for id in $(as_root ctr -n collo-memory-bench task ls -q); do
      as_root ctr -n collo-memory-bench task kill --signal KILL "$id" || true
      as_root ctr -n collo-memory-bench task delete --force "$id" || true
    done
    for id in $(as_root ctr -n collo-memory-bench container ls -q); do as_root ctr -n collo-memory-bench container delete "$id"; done
    for ref in $(as_root ctr -n collo-memory-bench image ls -q); do as_root ctr -n collo-memory-bench image remove "$ref"; done
    as_root ctr -n collo-memory-bench content prune references || true
    as_root ctr namespace remove collo-memory-bench || true
    for ns in $(ip netns list | awk '/^collo-memory-bench-/ {print $1}'); do as_root ip netns delete "$ns"; done
    as_root rm -rf /run/collo-memory-bench
    ;;
  unprepare) as_root rmdir "$MEMORY_BENCH_CGROUP/runner" "$MEMORY_BENCH_CGROUP" ;;
  *) die "usage: $0 setup | prepare | gvisor-setup | measure | gvisor-revert | unprepare" ;;
esac
