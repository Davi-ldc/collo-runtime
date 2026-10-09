# Request I/O benchmark

This harness measures requests per second, latency and CPU per request for the smallest useful handler on `collo serve` and on two Bun servers, over TLS on loopback with one certificate shared by every server: Collo over HTTP/2, `Bun.serve` over HTTP/1.1 (it negotiates no `h2`), and Bun's `node:http2` server as the HTTP/2 reference. It answers how much Collo's request path costs; it does not measure memory, cold start or isolation, which [../sandbox/README.md](../sandbox/README.md) covers.

## Files

| File | Role |
| --- | --- |
| [run.sh](run.sh) | runs every server through every level, each repetition with fresh servers in their own cgroup scopes, the server order rotating |
| [loadgen.mjs](loadgen.mjs) | the closed-loop load generator: forked child processes, a fixed number of requests in flight per connection, HTTP/2 framed directly on the TLS socket, HTTP/1.1 with keep-alive |
| [summarize.mjs](summarize.mjs) | the median of the repetitions with their range, into `summary.json` and `summary.md` |
| [threads.sh](threads.sh) | splits a Collo scope's CPU time by process role and thread over an interval |
| [collo.json](collo.json), [hello-collo.js](hello-collo.js), [hello-bun.js](hello-bun.js), [hello-bun-h2.js](hello-bun-h2.js) | the configuration and the three handlers, each answering `hello\n` |

## Method

Each server runs in its own scope under the delegated cgroup subtree (`wsl-config scope-create`), started through `wsl-config run` with `COLLO_TEST_CGROUP=<scope>/main COLLO_WORKER_CGROUP_ROOT=<scope>/workers`, so the scope's `cpu.stat` covers every process of the server: Collo's server, zygote, gateway and workers. Every server answers one request before the first level, so the first worker's launch stays out of the windows. Each level opens new connections, warms up and then measures; before each level the script waits until the machine as a whole uses fewer than `QUIET_CORES` cores, up to `QUIET_WAIT_S`.

Requests per second count only responses with status 200 and the exact body completed inside the window. Latency runs from queueing the request on the socket to receiving the end of the response, in a histogram with 1 µs buckets below 100 ms, and percentiles come from per-request totals. The parent reads the scope's `cpu.stat` and `/proc/stat` at the edges of the window, and each child its own CPU time, so the client's share is reported beside the server's. One request in flight per connection runs at each of `LEVELS`; for the two HTTP/2 servers, `MUX_LEVELS` spread streams over `ceil(concurrency / 64)` connections.

## Run

Build Collo in ReleaseFast into its own prefix, as any figure against a budget requires (conventions.md, "Performance claims"), provision the delegated subtree for this boot, and run from the repository root:

```sh
COLLO_BUILD_JOBS=4 CMAKE_BUILD_PARALLEL_LEVEL=4 zig build -j4 -Doptimize=ReleaseFast --prefix <prefix>
sudo ./zig-out/bin/wsl-config prepare
COLLO_BIN=<prefix>/bin/collo runtime/bench/io/run.sh
node runtime/bench/io/summarize.mjs <results directory>
```

The script needs Node.js and, for the Bun rows, Bun (`NODE_BIN`, `BUN_BIN`), and openssl to generate the EC P-256 certificate for `localhost` and `127.0.0.1` into `WORK_DIR`. It asks sudo only for the first hop into the delegated subtree, or reads the password from `SUDO_PASSWORD`. `REPS`, `WARMUP_S`, `DURATION_S`, `LEVELS`, `MUX_LEVELS`, `PROCS`, `QUIET_CORES` and `QUIET_WAIT_S` override the defaults (3, 5, 10, `1 16 64 256`, `16 64 256`, 8, 3 and 120). Results go to `OUT_DIR`, by default a new directory under `report/bench-io/`, which git ignores: `commands.log` holds every command the run executed, `progress.log` its log, `logs/` each server's stderr, `raw/` one JSON file per run and `environment.json` the machine, the binary's hash and the settings.

For the thread split, start Collo in a scope as above, keep it under load with `loadgen.mjs`, and run `runtime/bench/io/threads.sh <scope> 6` inside the measured window.

## Reading the numbers

Client and servers share the machine, so a level whose busiest client process approaches a core measures the client too; `summary.json` reports it. Bun runs as one process and fills one core from 16 connections on, while Collo spreads over its lanes, so the comparison above that level is Bun's single-core limit against Collo's whole server. Collo hands TLS records to kernel TLS and Bun encrypts in user space, and the traffic crosses loopback, not a network card. The generator is closed-loop: it sends a request only when another completes, so it never measures latency at a fixed arrival rate.
