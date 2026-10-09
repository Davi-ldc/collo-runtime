# Sandbox microbenches

These benchmarks measure the current production TLS/h2 ingress, supervisor, warm zygote, isolated sandbox processes and strict egress gateway. The HTTP client and memory sampler run outside the measured cgroup. The runtime daemon writes a `collo.json` configuration and builds its routes from it at boot, as a server does.

## Build and run

Build as your normal user, with no other build running:

```sh
COLLO_BUILD_JOBS=4 CMAKE_BUILD_PARALLEL_LEVEL=4 \
  zig build -j4 -Doptimize=ReleaseFast -Djsc-prebuilt \
  --prefix "$PWD/.zig-cache/sandbox-bench" install-microbench
zig build -j4 microbench-test
```

The delegated WSL subtree must already exist. If needed, provision it once per boot using the installed tool:

```sh
sudo ./.zig-cache/sandbox-bench/bin/wsl-config prepare
```

Run without compiling under sudo:

```sh
sudo bash runtime/bench/sandbox/run.sh cold
sudo bash runtime/bench/sandbox/run.sh memory
```

`all` runs both. An optional second argument names a new results directory; it must not already exist. `COLLO_BENCH_PREFIX` selects another absolute installation path. The runtime runs as root because its cache sits in the results directory, which root creates. The gateway itself needs no privilege, since it builds its sandbox inside a user namespace, and the benchmark fails if that sandbox cannot be installed.

The runner records binary and engine-input hashes, environment, stderr, raw JSONL and a derived summary. Only a complete run with valid sample counts publishes `results.jsonl` and `status.txt` containing `succeeded`. Failure preserves partial output. Temporary fixture files stay inside the result directory and are removed after successful teardown. Cgroup scopes are exclusive to each trial and removed after children exit. Failure cleanup can kill only the benchmark's own scope.

## Cold start

Each sample sends a GET on an established loopback TLS/h2 connection. `/__collo/healthz` completes the handshake without creating a sandbox. All code packs are resident, and the target pool is empty. Requests are sequential; this is unloaded cold-start latency, not throughput under saturation.

The raw record has these timestamps from `CLOCK_MONOTONIC`:

- `request_sent_ns`: immediately before writing the prepared request headers.
- `worker_ready_ns`: host receipt of `WorkerReady`, before post-ready draining.
- `handler_enter_ns`: the fixture's first JavaScript statement calls a native marker.
- `response_received_ns`: HTTP 200, exact body and END_STREAM received.

Creation is ready minus send. Dispatch is handler minus ready. Total is handler minus send, computed per request before percentiles. The JavaScript marker includes first-call compilation and frame preparation inside JSC, plus its own installation and call overhead. Ordinary execution does not install this marker or sample its clock. The marker is enabled only for the first handler in each benchmark sandbox and removed before microtasks drain.

The host and sandbox records must agree on request, stream, worker generation and PID. A fresh child discarded in favor of a warm sandbox is rejected. No timestamp, invalid ordering, wrong response or incomplete teardown invalidates the run. The target p95 is below 10 ms; the benchmark reports rather than conceals misses. Connection setup, Internet latency, artifact downloads and whole-server boot are separate scenarios.

Defaults are three fresh runtime rounds with 32 cold samples each. Override `COLLO_BENCH_ROUNDS` or `COLLO_BENCH_SAMPLES` on the runtime invocation. The runner preserves them when set through `sudo env NAME=value ...`.

## Memory

Each independent trial starts a runtime in its own cgroup before engine, artifact and channel allocation. All runtime children remain in that subtree; swap is disabled. The sampler checks every reported process's membership and verifies its own exclusion.

The primary value is `memory.current` after adding one instance minus the same runtime's value before adding it. It includes charged memory in the host, zygote, gateway, sandbox processes and accounted kernel allocations. Amortized cost over the initial runtime is reported separately. Population sizes before insertion are 0, 1, 4 and 16, rotated between rounds. Each target is removed and recreated; both cycles and the post-removal retention remain in the output.

Ready trials do not execute the handler. In post-load trials, existing instances have completed the declared workload; the new target is sampled at Ready and after the workload with the same PID, generation and surrounding inventory. `load_growth_bytes` compares those paired snapshots. Different population-history trials are not compared as though they were the same process.

Each process snapshot reports RSS, PSS, private clean/dirty and shared clean/dirty bytes. USS is private clean plus private dirty. Shared mappings are not unique physical bytes and must not be summed across processes. Cgroup `memory.stat` categories also overlap: shmem belongs to file; page tables, kernel stacks and slab belong to kernel. None of these should be added to `memory.current`.

An open `memory.peak` descriptor is reset immediately before creation and retained for reading the peak. Each resting snapshot requires five samples 20 ms apart whose current/stat ranges fit within 64 KiB; failure to stabilize within 25 samples is reported with its raw window. This bounds measurement uncertainty, not all background activity. Swap, pressure or OOM event changes invalidate the sample.

Defaults are three rounds, ready and post-load cohorts, and ten sequential hello requests per loaded instance. `COLLO_BENCH_LOAD_REQUESTS` changes that count. No forced GC runs.

## Scope and limitations

The runtime keys pools by worker definition, and a worker serves one route. The configuration therefore declares 64 definitions, `sandbox-0` to `sandbox-63`, each with the single route `/sandbox/<i>` on one shared entry file; every definition gets its own pack, with identical source under different specifiers, built before the empty baseline. Their metadata is recorded. This is not a measurement of several sandboxes sharing one application artifact. The configuration sets each worker's memory limit and request deadline; the cgroup CPU quota is the supervisor's default, since a configuration has no CPU field.

Executable and shared-library pages can have existing charges outside the trial. Moving a process does not migrate those charges, and Linux does not account every kernel allocation. Cgroup deltas measure attributable marginal cost under this cache policy, not an exact counterfactual for the entire machine. PSS complements that view but apportions pages among external sharers too.

Gateway session reclamation follows liveness HUP asynchronously. The controller confirms worker death, cgroup removal and server-side detachment, then applies the bounded stability window. Later reclamation can produce negative insertion or teardown deltas even when both sampling windows were stable. Such a sample reports net change, not proof that adding an instance frees memory. Keep its uncertainty visible and compare fresh insertion separately from recreation; every reading remains in the report.

Warnings about unavailable WSL PSI triggers and liveness-driven session retirement are preserved in stderr. No fallback weakens the gateway or worker sandbox.

`bench-memory` and `bench-cold-start` are the build steps for these measurements. `bench-host` remains a narrower host-only diagnostic and cannot substitute for them. Parser, arithmetic and protocol tests live in `runtime/tests/contracts/benchmark_*.zig` and also run through the main test collection.
