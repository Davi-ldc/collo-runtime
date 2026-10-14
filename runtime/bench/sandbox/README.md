# Sandbox microbenches

These benchmarks measure the current production TLS/h2 ingress, supervisor, warm zygote, isolated sandbox processes and strict egress gateway. The HTTP client, the memory sampler and the fetch origin run outside the measured cgroup. The runtime daemon writes a `collo.json` configuration from the run's knobs (`node.zig`) and builds its routes from it at boot, as a server does.

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
sudo bash runtime/bench/sandbox/run.sh idle
sudo env COLLO_BENCH_WORKLOAD=sequence bash runtime/bench/sandbox/run.sh regions
```

`all` runs `cold` and then `memory`. An optional second argument names a new results directory; it must not already exist. `COLLO_BENCH_PREFIX` selects another absolute installation path. The runtime runs as root because its cache sits in the results directory, which root creates; the region instrument also needs root to read `/proc/<pid>/map_files`. The gateway itself needs no privilege, since it builds its sandbox inside a user namespace, and the benchmark fails if that sandbox cannot be installed.

The runner records binary and engine-input hashes, the hashes of the measurement sources, environment, stderr, raw JSONL and a derived summary. Only a complete run with valid sample counts publishes `results.jsonl` and `status.txt` containing `succeeded`. Failure preserves partial output. Temporary fixture files stay inside the result directory and are removed after successful teardown. Cgroup scopes are exclusive to each trial and removed after children exit. Failure cleanup can kill only the benchmark's own scope.

## Knobs

Each knob is an environment variable of the runtime invocation; the runner preserves it when set through `sudo env NAME=value ...`. The controller validates every knob, hands the value to the daemon and refuses a daemon whose ready line reports another, and the run's metadata records each one.

- `COLLO_BENCH_WORKLOAD` picks the fixture and the load (below); unset selects `hello`.
- `COLLO_BENCH_NETWORK=granted`, the default, gives every definition `"network": { "allow": ["*"] }`, so each worker has an egress session and the gateway runs, as in the recorded baselines.
- `COLLO_BENCH_NETWORK=none` gives no definition a grant, so no worker has an egress session and the server spawns no gateway; the difference between the two values is what a session costs per worker and in the node.
- `COLLO_BENCH_CONCURRENCY`, from 1 to 16 and 2 by default, is every definition's `limits.concurrency`, so running it at 2 and at 16 measures what the larger slot count costs a worker.
- `COLLO_BENCH_LOAD_REQUESTS`, from 1 to 10,000, replaces the request count of a single-step workload; `sequence` refuses it.
- `COLLO_BENCH_ROUNDS` (3) and `COLLO_BENCH_SAMPLES` (32 cold samples per round) size the run, and `COLLO_BENCH_SETTLE_MS` (0) pauses before every resting memory snapshot.
- `COLLO_BENCH_IDLE_WINDOW_MS`, 30,000 by default, is the `idle` window and the rest a `regions` worker gets before the second sample of each step.

## Workloads

`hello` and `crypto` keep the fixtures of the recorded baselines; every other workload installs one steps fixture that answers a plain GET as `hello` does and runs the step its `?step=` query names. A patterned body holds `(i / 65536) % 256` at byte `i`, and the client checks every response byte against the exact body or that pattern.

- `hello` sends ten GETs that answer a fixed string, the request path with the least work.
- `crypto` sends one GET that runs pure-JavaScript SHA-256 over 4 MiB and four 2048-bit modular exponentiations (`workload.zig` says how its copy for workerd is kept identical).
- `upload` sends one POST with a 1 MiB body, past the ingress payload threshold, which fills the server-to-worker payload ring.
- `stream` gets one 4 MiB response that the handler streams from a ReadableStream in 64 KiB chunks, which fills the worker-to-server payload ring.
- `fetch` makes the handler `fetch()` 4 MiB from the origin and read it through the response's stream, which fills the egress completion ring and the body pool.
- `fetch_upload` makes the handler `fetch()` four concurrent POSTs of 4 MiB to the origin, 16 MiB in all, which goes through the egress command ring and the upload pool; a body the handler holds whole is capped at 4 MiB, and a stream request body cannot be sent.
- `webcrypto` sends one GET whose handler awaits `crypto.subtle.digest` over 1 MiB, which runs inline on the worker's VM thread.
- `sequence` runs `hello` ten times, then `upload`, `stream`, `fetch` and `fetch_upload` once each on one worker.

`fetch`, `fetch_upload` and `sequence` need the origin. The gateway refuses loopback under every grant and verifies TLS, so the controller serves plain HTTP/1.1 on the default route's source address (`runtime/bench/local_origin.zig`) at an ephemeral port, and the configuration grants exactly that `<address>:<port>` beside `"*"`, with `allowHttp`, plus `allowPrivateNetworks` when the address is private, and hands each route its URL as the text binding `BENCH_ORIGIN`. Such a workload needs `COLLO_BENCH_NETWORK=granted`. The origin serves one connection at a time and fails the run when it refused any request.

## Cold start

Each sample sends a GET on an established loopback TLS/h2 connection. `/__collo/healthz` completes the handshake without creating a sandbox. All code packs are resident, and the target pool is empty. Requests are sequential; this is unloaded cold-start latency, not throughput under saturation.

The raw record has these timestamps from `CLOCK_MONOTONIC`:

- `request_sent_ns`: immediately before writing the prepared request headers.
- `worker_ready_ns`: host receipt of `WorkerReady`.
- `handler_enter_ns`: the fixture's first JavaScript statement calls a native marker.
- `response_received_ns`: HTTP 200, exact body and END_STREAM received.

Creation is ready minus send. Dispatch is handler minus ready. Total is handler minus send, computed per request before percentiles. The JavaScript marker includes first-call compilation and frame preparation inside JSC, plus its own installation and call overhead. Ordinary execution does not install this marker or sample its clock. The marker is enabled only for the first handler in each benchmark sandbox and removed before microtasks drain.

The host and sandbox records must agree on request, stream, worker generation and PID. A fresh child discarded in favor of a warm sandbox is rejected. No timestamp, invalid ordering, wrong response or incomplete teardown invalidates the run. The target p95 is below 10 ms; the benchmark reports rather than conceals misses. Connection setup, Internet latency, artifact downloads and whole-server boot are separate scenarios.

## Memory

Each independent trial starts a runtime in its own cgroup before engine, artifact and channel allocation. All runtime children remain in that subtree; swap is disabled. The sampler checks every reported process's membership and verifies its own exclusion.

The primary value is `memory.current` after adding one instance minus the same runtime's value before adding it. It includes charged memory in the host, zygote, gateway, sandbox processes and accounted kernel allocations. Amortized cost over the initial runtime is reported separately. Population sizes before insertion are 0, 1, 4 and 16, rotated between rounds. Each target is removed and recreated; both cycles and the post-removal retention remain in the output.

Ready trials do not execute the handler. In post-load trials, existing instances have run the workload's load; the new target is sampled at Ready and after the same load with the same PID, generation and surrounding inventory. `load_growth_bytes` compares those paired snapshots. Different population-history trials are not compared as though they were the same process. With `COLLO_BENCH_WORKLOAD=sequence`, the post-load cohort holds workers past the full sequence beside the ready cohort's fresh ones, so a used worker's marginal cost at 1, 4 and 16 existing workers sits beside a fresh one's.

Each process snapshot reports RSS, PSS, private clean/dirty and shared clean/dirty bytes. USS is private clean plus private dirty. Shared mappings are not unique physical bytes and must not be summed across processes. Cgroup `memory.stat` categories also overlap: shmem belongs to file; page tables, kernel stacks and slab belong to kernel. None of these should be added to `memory.current`.

An open `memory.peak` descriptor is reset immediately before creation and retained for reading the peak. Each resting snapshot requires five samples 20 ms apart whose current/stat ranges fit within 64 KiB; failure to stabilize within 25 samples is reported with its raw window. This bounds measurement uncertainty, not all background activity. Swap, pressure or OOM event changes invalidate the sample.

Defaults are three rounds, ready and post-load cohorts, and the workload's load per loaded instance, ten hello requests by default. No forced GC runs.

## Shared regions

At every resting snapshot of a memory or regions trial, a `cgroup_memory` record holds `memory.stat` of the runtime's scope, of its `main` cgroup (server, zygote and gateway) and of the target worker's leaf, and a `region_memory` record per process covers the target worker, the server and the gateway. Each region record lists every mapping whose path starts with `/memfd:collo-`, aggregated per memfd name: mapping and memfd counts, mapped size, `Rss`, `Pss`, `Shared_Dirty` and `Private_Dirty` from `/proc/<pid>/smaps`, and the allocated bytes of the memfds, `st_blocks` × 512 from `fstat` of `/proc/<pid>/map_files/<start>-<end>`. The server's and the gateway's records also carry `target_regions`, the same totals over only the memfds the target worker maps too, which is their share of that one worker.

Read the allocated bytes as the region's physical size, whoever touched its pages; each memfd counts once however many processes or mappings map it. Rss and the dirty counts say which of those pages a process has mapped, Pss splits them among the mappers, and shmem in `memory.stat` says which cgroup pays: a shared page is charged to the cgroup of the process that first touched it and stays there. These answer different questions and are never added together, within a process or across processes.

`run.sh regions` runs one worker per round through the workload's steps: it samples at WorkerReady, then after each step, and each sample twice, right after the step and again after the idle window, so what a step leaves resident shows apart from what idleness gives back. Run it with `sequence` for the table of every region after each step.

The worker's state page is the `collo-shared-metrics` memfd. Everything in it but the console ring's bytes sits in its first 4 KiB page, which the server's launch writes, and a worker's requests write only that page until its console lines pass it (`common/worker_state/page/mapping.zig:Page`). To read the page's resident share after requests, run `regions` with `COLLO_BENCH_WORKLOAD=hello` and a large `COLLO_BENCH_LOAD_REQUESTS`, for example 2,000: the growth of the target's `collo-shared-metrics` allocated bytes from `ready` to `hello` is what the requests made resident, and its `Private_Dirty` and `Shared_Dirty` in the worker and the server, with the leaf's and `main`'s shmem, say who maps and who pays for it.

## Idle

`run.sh idle` loads one worker per round with the workload's load, waits a 1.5 s settle, which lets every thread release its allocator cache and the allocator's scavenger go to sleep, then watches the worker over the idle window. The `idle_sample` record holds, at the window's start and end, the worker's `smaps_rollup` counters, its leaf's `cpu.stat` and the summed `voluntary_ctxt_switches` and `nonvoluntary_ctxt_switches` of every `/proc/<pid>/task/*/status`, with the task count, and the deltas over the window: the CPU an idle worker still burns, how often its threads wake, and the Private_Dirty it keeps. A task count that changes means a thread exited, whose switches leave the sum. Run it with `COLLO_BENCH_WORKLOAD=hello` and with `webcrypto`, each at `COLLO_BENCH_LOAD_REQUESTS=3`, to compare the idle cost after plain requests with the cost after a WebCrypto request.

## Scope and limitations

The runtime keys pools by worker definition, and a worker serves every route of its definition. The configuration therefore declares 64 definitions, `sandbox-0` to `sandbox-63`, each with the single route `/sandbox/<i>` on one shared entry file; every definition gets its own artifact, a separate sealed memfd holding the same source under the same `/var/task` key, built before the empty baseline. Their metadata is recorded. This is not a measurement of several sandboxes sharing one application artifact. The configuration sets each worker's memory limit, request deadline and concurrency and the `network` grant; the cgroup CPU quota is the one core every worker gets (`common/limits/worker.zig:cpu_max_cores`), since a configuration has no CPU field.

Executable and shared-library pages can have existing charges outside the trial. Moving a process does not migrate those charges, and Linux does not account every kernel allocation. Cgroup deltas measure attributable marginal cost under this cache policy, not an exact counterfactual for the entire machine. PSS complements that view but apportions pages among external sharers too.

Gateway session reclamation follows liveness HUP asynchronously. The controller confirms worker death, cgroup removal and server-side detachment, then applies the bounded stability window. Later reclamation can produce negative insertion or teardown deltas even when both sampling windows were stable. Such a sample reports net change, not proof that adding an instance frees memory. Keep its uncertainty visible and compare fresh insertion separately from recreation; every reading remains in the report.

Warnings about unavailable WSL PSI triggers and liveness-driven session retirement are preserved in stderr. No fallback weakens the gateway or worker sandbox.

`bench-memory`, `bench-cold-start`, `bench-idle` and `bench-regions` are the build steps for these measurements. `bench-host` remains a narrower host-only diagnostic and cannot substitute for them. Parser, arithmetic, protocol, workload and configuration tests live in `runtime/tests/contracts/benchmark_*.zig` and also run through the main test collection.
