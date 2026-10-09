---
name: collo-runtime-e2e
description: Build, run, and debug local-e2e, the full-flow test (TLS ALPN h2 → server → zygote fork → sandboxed worker → egress gateway) over the routes of a collo.json fixture. Use when running local-e2e, when it skips or fails, or when a worker or gateway process dies silently during it.
---

# Local full-flow e2e

local-e2e is the only test that runs the production topology in one process tree: a real server on a TLS listener serving the routes of `runtime/tests/integration/fixtures/local_e2e/collo.json`, a zygote that forks fully sandboxed workers (user, mount and network namespaces, chroot into an empty tmpfs, seccomp), and the egress gateway behind them. Unit-test binaries link no JSC and apply no real sandbox, so static TLS sizing, seccomp against thread creation and post-fork ordering are covered only here, and a green unit suite says nothing about them. The exceptions are forked children that install one filter and probe it: the worker filter in `zygote/tests/sandbox.zig`, and a gateway shard restart under the gateway filter in `egress/tests/gateway/shard_chaos.zig`.

The suites are `runtime/tests/integration/local_server/e2e.zig` and `workers.zig`, which e2e.zig brings into the lane, over the stack they share in `harness.zig`. Each test owns a `Harness`: throwaway TLS material, a zygote, the delegated cgroup root, an analytics directory, and a server with one lane or two on a thread of the test process serving the fixture configuration, driven by the h2 client of the TLS test shim (`runtime/tests/support/tls/tls_shim.cc`). The tests in e2e.zig cover h2 streams through a worker, including a request body and a 4 MiB response, and a fetch through the gateway; a hung route's deadline and a synchronously spinning worker stopped by its deadline sentinel; the handler's frozen `env` with an empty `process.env`; a module the route reaches only through a string-literal `import()`, served from the pack the server built; the paths the server answers itself; and the access and usage records in the analytics directory. The tests in workers.zig cover two lanes sharing one worker, a steady load on one connection served by one launch, a deadline that keeps its worker, a worker's death seen from two lanes, and uploads to a worker that runs synchronous JavaScript or dies. Four benchmarks run only when their environment variable is set. Each fixture route has its own worker definition, since a worker serves one route until multi-route workers land. The sources live in `fixtures/local_e2e/api/`, and the lane runs from the repository root, which anchors their paths.

## Run

The delegated cgroup environment belongs to `dev/wsl` (`dev/wsl/cgroup_env.zig`, step `wsl-config`; see "Build and tests" in CLAUDE.md), so never move processes between cgroups by hand. From the repository root, provision the subtree once per WSL boot with `sudo ./zig-out/bin/wsl-config prepare`, then run the lane inside it:

```sh
sudo --preserve-env=PATH,COLLO_BUILD_JOBS,CMAKE_BUILD_PARALLEL_LEVEL ./zig-out/bin/wsl-config run -- zig build -j4 local-e2e
```

`wsl-config run` enters the runner cgroup under `/sys/fs/cgroup/collo-dev`, recreating a leaf the kernel removed, drops back to your user and exports `COLLO_TEST_WORKER_CGROUP_ROOT`; children inherit the membership. Only the first move from a shell outside the subtree needs root, because of the cgroup v2 common-ancestor rule, and the tool fails closed with the command to run. Never `sudo zig build`, which leaves a root-owned cache. The engine comes from `runtime/deps/jsc-build`, built or admitted by the `jsc` step every JSC-linked lane depends on ([build.md](internals/build.md)). When piping build output, read the exit code from `${PIPESTATUS[0]}`, never after `| tail`.

## Skips and expected noise

`error.SkipZigTest` is an environment gate, not a pass: the kernel has no usable kTLS cipher, the process is not in a cgroup under `/collo-dev` (the move above failed), for the test that fetches through the gateway the host has no routable IPv4 address other than loopback for its local origin, or, for a test that needs two lanes, the host allows the server fewer than two CPUs, which the test prints. On a kernel without PSI, or one before Linux 6.4, which gives no PSI trigger to a process without `CAP_SYS_RESOURCE`, `memory-pressure PSI trigger unavailable: <reason>` is an expected warning, and the reaper then reads memory only on its interval and on demand reclaim; Linux 6.18, the WSL2 development kernel, arms the trigger.

Under `zig build smoke`, or with `COLLO_TEST_STRICT_SKIPS=1`, a skip fails the run unless `runtime/tests/support/skip_allowlist.zon` grants it to the suite `runtime/tests/integration/all.zig`. Only the four environment-gated `local e2e bench:` tests are listed there, so any gate above fails a strict run.

## Debugging a failure

A failing test prints the zygote trace, the `host.*`, `zygote.*`, `child.*` and `worker.*` markers in boot order. Find the last `child.*` marker: the fault is in whatever runs next. A worker that dies with no error line shows up only as gateway `worker liveness closed session=N` warnings.

- To find the dying child, run the test binary under `strace -ff -o <dir>/t <local-e2e-binary>`, grep the per-process files for the last trace marker (markers are written to fd 4) and read the system calls after it.
- A panic inside a chrooted process (worker, gateway) prints `???` frames, because the chroot has no `/proc` to symbolize from. Symbolize from outside: run `strace -ff -k -e trace=writev -o <dir>/t <local-e2e-binary>` and grep the files for `panic`; the `writev` of the panic message carries the full symbolized stack.
- The built test binary's path appears in the failing `zig build` output (`.../o/<hash>/local-e2e`); running it directly requires entering the subtree first.

## Hard invariants this test enforces

- The forked worker child enters its namespaces as its first act: `unshare(CLONE_NEWUSER)` fails with EINVAL in a multithreaded process, and JSC's `postForkChild` resumes the libpas scavenger thread.
- Every gateway thread and io_uring ring exists before `applySeccompAfterThreadsStarted`: the gateway filter denies clone, clone3, io_uring_setup and io_uring_register with EPERM. `std.Thread.spawn` treats that EPERM as unreachable, so a lazy spawn after boot panics in safe builds and is undefined behavior in ReleaseFast. A shard restart therefore reruns its engine on the threads and rings of the first start (`Shard.restart`, `egress.Engine.start`); see `internals/boot.md` (Egress gateway) and `internals/egress.md`.
- Raw `std.os.linux.*` returns are decoded with `syscallErrno` or `E.init`, never `std.posix.errno` (enforced by `runtime/tests/conventions.zig`).
