# Memory and startup harness

The harness measures Collo only. The runner does not compile, does not run comparators and stops at the first failure. A valid pass contains `status.json` with `state: succeeded` and `results.jsonl`. A failure keeps the logs and `partial.jsonl` but produces no valid results. Bun in a container and workerd are measured separately, after this pass is validated.

## Prepare and run

The reference machine is Ubuntu 24.04 aarch64 on Oracle A1, with Bash, jq, coreutils, util-linux and a systemd user session with cgroup v2 delegation. Build the executables before measuring. The normal build needs Zig 0.15.2, clang-19 and the native dependencies in [build.md](../../../skills/runtime/references/internals/build.md); the engine is provisioned and built inside the repository, never taken from the JITCache checkout.

```bash
export PREFIX=/path/to/artifacts
export JSC="$PWD/runtime/deps/jsc-build/aarch64-linux-gnu/release/build"

zig build webkit-provision
zig build -j4 -Doptimize=ReleaseSafe --prefix "$PREFIX" install install-bench-host

BENCH_BIN="$PREFIX/bin/host_lifecycle" \
ROUNDS=3 COUNTS='1 4 16' WARM_REQUESTS=200 OPTIMIZE=ReleaseSafe \
  runtime/bench/harness/run.sh "$PWD" "$PREFIX/bin/collo" "$JSC" /path/to/results
```

The engine is admitted by provenance against this checkout. A build made at another path is rejected, and the attestation must not be edited to get around the rejection.

`install-bench-host` installs the bench without running it. `BENCH_BIN` selects that artifact, and the runner tells the bench which Collo executable to launch. `OPTIMIZE` must match the mode the binaries were built in. The initial measurements use ReleaseSafe, so they are not a final ReleaseFast performance evaluation.

On Ubuntu with the AppArmor restriction on user namespaces, the executable needs a profile that allows creating the namespaces the sandbox uses. Inspect `/etc/apparmor.d/collo-runtime` before running `install_apparmor_profile.sh <collo>`, since the script replaces that profile. On the reference A1 the profile covers only the measured binary's path, and the global restriction stays enabled. Do not disable the worker's namespaces or seccomp to make the bench pass.

Without `COLLO_WORKER_CGROUP_ROOT`, the runner uses `cgroup_scope_run.sh` to create a delegated scope. The smoke and the bench use the same tree. Stop builds and other test loads before measuring; the runner's lock prevents another pass from using the same results root, but it does not control other sessions or the hypervisor.

Each results directory keeps stdout and stderr separately, full SHA-256 hashes of the executables and the attestation, the checkout's commit, the parameters, the cgroup limits and CPU and process snapshots taken before and after. The recorded commit alone does not prove the binaries came from that source, so keep the build log and the hashes of the inputs next to the results. Run another pass with the same artifacts to check the variation between runs.

## Reading the results

`fork_to_ready` covers creating and configuring the cgroup leaf, the fork and initialization up to WorkerReady, with the zygote already warm. `first_response` runs from sending the first request to the end of its response. WorkerReady alone does not prove that a module with top-level await has finished; the hello-world used here is synchronous. The cost of initializing the zygote is reported separately.

Additional memory per worker is `(PSS of the zygote and all workers − PSS of the idle zygote) / N`. PSS splits shared physical pages among the processes that map them. The zygote's fixed cost and the total for the set are reported too. These values include neither the harness process nor all the kernel memory of the isolation structures. `Private_Dirty` is complementary; it is not an independent measure of the incremental copy-on-write cost.

The bench checks the status and body of every response. Cold percentiles are computed within each round, never across all rounds together. Warm latency measures the host-worker path; it is not the HTTP throughput of a public server. For future comparisons, process or container startup, worker startup from a warm zygote and an isolate's first request must stay labeled as distinct measurements.
