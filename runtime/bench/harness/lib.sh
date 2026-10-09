# Startup samples include shell/probe overhead and use CLOCK_REALTIME.
now_ns() { date +%s%N; }
elapsed_ns() {
  local end
  end=$(now_ns)
  (( end >= $1 )) || { echo 'clock moved backwards' >&2; return 1; }
  echo $((end - $1))
}
prepare_output() {
  [[ $N =~ ^[1-9][0-9]*$ && ${#N} -le 2 ]] && (( N <= 64 )) || {
    echo 'N must be in 1..64' >&2; return 1;
  }
  for tool in jq curl timeout sha256sum cmp realpath; do
    command -v "$tool" >/dev/null || return 1
  done
  if [[ -n ${OUT_DIR:-} ]]; then
    mkdir -p "$OUT_DIR"
    [[ -z $(find "$OUT_DIR" -mindepth 1 -maxdepth 1 -print -quit) ]] || {
      echo "OUT_DIR must be empty: $OUT_DIR" >&2; return 1;
    }
    out=$(realpath "$OUT_DIR")
  else
    : "${OUTPUT_ROOT:?set OUTPUT_ROOT or an empty OUT_DIR}"
    mkdir -p "$OUTPUT_ROOT"
    out=$(mktemp -d "$(realpath "$OUTPUT_ROOT")/$1.XXXXXX")
  fi
  echo "benchmark logs: $out" >&2
}
# All retries share the launch deadline. Preserve final newlines with cmp.
wait_http_exact() { # port expected-file output-prefix launch-ns
  local code elapsed
  while :; do
    elapsed=$(elapsed_ns "$4") || return
    (( elapsed < 30000000000 )) || break
    if code=$(curl --noproxy '*' -sS --max-time 0.2 -o "$3.body" -w '%{http_code}' "http://127.0.0.1:$1/hi" 2>"$3.curl.stderr"); then
      [[ $code == 200 ]] && cmp -s "$3.body" "$2" || {
        echo "unexpected HTTP response on port $1; see $3.body" >&2; return 1;
      }
      elapsed_ns "$4"
      return
    fi
    sleep 0.002
  done
  echo "timeout waiting for HTTP on port $1" >&2
  return 1
}
# Kept for the separate native-Bun runner's existing call signature.
wait_first_response() {
  local t0 body elapsed
  t0=$(now_ns)
  while :; do
    elapsed=$(elapsed_ns "$t0") || return
    (( elapsed < 30000000000 )) || break
    if body=$(curl --noproxy '*' -fsS --max-time 0.2 "http://127.0.0.1:$1/hi" 2>/dev/null); then
      [[ $body == "$2" ]] || return 1
      echo $(( $(elapsed_ns "$t0") / 1000000 ))
      return
    fi
    sleep 0.002
  done
  echo "timeout waiting on port $1" >&2
  return 1
}
read_proc() {
  cat "$1" 2>/dev/null || timeout 5 sudo -n cat "$1"
}
proc_key() {
  awk -v key="$2" '$1 == key {if ($2 !~ /^[0-9]+$/) exit 1; value=$2; found++} END {if (found != 1) exit 1; print value}' "$1"
}
pss_kib() { local text; text=$(read_proc "/proc/$1/smaps_rollup") || return; proc_key /dev/stdin Pss: <<< "$text"; }
private_dirty_kib() { local text; text=$(read_proc "/proc/$1/smaps_rollup") || return; proc_key /dev/stdin Private_Dirty: <<< "$text"; }
# Nearest rank is ceil(p*N/100), not rounding to the nearest integer.
percentile() {
  sort -n | awk -v p="$1" '{a[NR]=$1} END{if (!NR) exit 1; x=p*NR/100; i=int(x); if(i<x)i++; if(i<1)i=1; print a[i]}'
}
sum() { awk '{if ($1 !~ /^[0-9]+$/) bad=1; s+=$1} END{if (!NR || bad) exit 1; print s}'; }
process_identity() {
  local stat rest
  local -a fields
  stat=$(cat "/proc/$1/stat" 2>/dev/null) || return
  rest=${stat##*) }
  read -r -a fields <<< "$rest"
  (( ${#fields[@]} >= 20 )) && [[ ${fields[0]} != Z && ${fields[0]} != X ]] || return 1
  printf '%s:%s\n' "$1" "${fields[19]}"
}
