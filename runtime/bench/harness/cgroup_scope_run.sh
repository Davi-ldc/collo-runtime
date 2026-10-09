#!/bin/bash
# Runs <cmd> inside a delegated systemd user scope shaped the way
# WorkerCgroupRoot's env_root placement needs: this shell moves itself into
# <scope>/main so <scope>/workers stays process-free and can carry the
# controllers, then COLLO_WORKER_CGROUP_ROOT names that directory.
# clone3(CLONE_INTO_CGROUP) from <scope>/main into <scope>/workers/... needs
# write access to the common ancestor's cgroup.procs, which Delegate=yes
# grants to the user. Needs a systemd user manager (any logged-in session).
set -euo pipefail
if [ -z "${COLLO_SCOPE_INNER:-}" ]; then
  COLLO_SCOPE_INNER=1 exec systemd-run --user --scope -q -p Delegate=yes -- "$0" "$@"
fi
scope=/sys/fs/cgroup$(cut -d: -f3 /proc/self/cgroup)
mkdir -p "$scope/main" "$scope/workers"
echo $$ > "$scope/main/cgroup.procs"
echo "+memory +cpu +pids" > "$scope/cgroup.subtree_control"
echo "+memory +cpu +pids" > "$scope/workers/cgroup.subtree_control"
export COLLO_WORKER_CGROUP_ROOT="$scope/workers"
exec "$@"
