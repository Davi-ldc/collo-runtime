#!/usr/bin/env bash
# Splits the CPU time of every process in a Collo scope by role over an
# interval: two snapshots of utime + stime per thread, the difference summed
# per role and printed in cores, then the busiest threads. Collo names no
# thread, so a thread is identified by its process role and its creation
# order in that process (0 is the main thread).
#
#   runtime/bench/io/threads.sh <scope directory> <seconds>
#
# The role comes from the process's place in the scope: `workers/` holds the
# workers; in `main`, the server, zygote and gateway are told apart by their
# command line.
set -euo pipefail

scope=${1:?scope directory}
seconds=${2:?seconds}
ticks=$(getconf CLK_TCK)

snapshot() {
  local procs pid role task
  find "$scope" -name cgroup.procs | while read -r procs; do
    for pid in $(cat "$procs"); do
      if [[ $procs == "$scope/workers/"* ]]; then
        role=worker
      else
        case $(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) in
          *zygote*) role=zygote ;;
          *gateway*) role=gateway ;;
          *serve*) role=server ;;
          *) role=other ;;
        esac
      fi
      local order=0
      for task in $(ls /proc/"$pid"/task 2>/dev/null | sort -n); do
        # Fields after "pid (comm) ": utime is the 12th, stime the 13th.
        printf '%s %s %s %s %s\n' "$task" "$role" "$pid" "$order" \
          "$(sed 's/.*) //' "/proc/$pid/task/$task/stat" 2>/dev/null | awk '{ print $12 + $13 }')"
        order=$((order + 1))
      done
    done
  done
}

before=$(snapshot)
sleep "$seconds"
after=$(snapshot)

echo "per role (cores; threads that ran / threads)"
awk -v seconds="$seconds" -v ticks="$ticks" '
  NR == FNR { start[$1] = $5; next }
  ($1 in start) {
    used = $5 - start[$1]
    total[$2] += used; threads[$2] += 1
    if (used > 0) ran[$2] += 1
    if (!(($2 " " $3) in seen)) { seen[$2 " " $3] = 1; processes[$2] += 1 }
  }
  END { for (role in total) printf "  %-8s cores=%.2f processes=%d threads ran %d / %d\n", role, total[role] / ticks / seconds, processes[role], ran[role], threads[role] }
' <(echo "$before") <(echo "$after") | sort -t= -k2 -rn
echo "busiest threads (role, creation order in its process, cores)"
awk -v seconds="$seconds" -v ticks="$ticks" '
  NR == FNR { start[$1] = $5; next }
  ($1 in start) && $5 > start[$1] { printf "  %-8s thread %-3d cores=%.2f\n", $2, $4, ($5 - start[$1]) / ticks / seconds }
' <(echo "$before") <(echo "$after") | sort -t= -k2 -rn | head -24
