# Collo

Collo runs untrusted JavaScript for cloud platforms on Linux. Each worker is a separate process forked from a warm zygote, so workers share the engine's initialized memory through copy-on-write while tenants stay separated by processes. The goal is lower memory per worker than Cloudflare Workers, about the same cold start and slightly faster execution. The engine is JavaScriptCore from Bun's WebKit fork, hosted from Zig 0.15.2 through a C ABI. Targets are Linux x86_64 and ARM64. The [README](../../../README.md) defines the public API.

The design depends on how little of the zygote's state a worker rewrites. Pages stay shared until a worker writes to them, so one more worker costs roughly what it dirties: its heap growth, stacks, kernel structures and the engine pages it touches while running.

## Priorities

1. Minimize the marginal memory cost of adding a worker.
2. Keep cold-start p95 below 10 ms on the reference workload and hardware.
3. Improve worker execution speed and algorithms.
4. Improve egress gateway efficiency.

Memory is measured as M(N+1) − M(N): the physical memory the node spends when one more worker exists, including kernel memory charged to the runtime and what the server and gateway allocate for that worker. Sharing more pages is a means to lower that number. Moving a worker's allocation into another process is not a saving, and a larger zygote helps only when it lowers the marginal cost. RSS, PSS, shared and private bytes answer different questions; report them separately and never add them together. Zygote boot time and fixed memory have low priority.

Cold start runs from the client sending a request over an established connection to the first JavaScript statement of the handler, with a warm zygote, code resident on the node and no worker available for the route. It splits into creation (send to `WorkerReady`) and entry (`WorkerReady` to first statement). Percentiles come from per-request totals, never from summed phase percentiles. Connection setup, artifact download and server boot are separate measurements. Below the budget, latency gains matter less than memory. The [microbenchmark documentation](../../../runtime/bench/sandbox/README.md) owns the exact boundaries.

## Processes

One binary serves four roles. `arg0` selects the zygote and the gateway, the `serve` command runs the server, and a worker is a `clone3` child of the zygote that never enters the binary's `main`. The server (`runtime/src/server/`) owns client connections and TLS, routing, request policies, limits, supervision and usage records. The zygote (`runtime/src/zygote/`) initializes and warms one JSC VM and forks workers from it. A worker (`runtime/src/worker/`) is a `clone3` child of the zygote that runs tenant code. The egress gateway (`runtime/src/egress/gateway/`) performs every outbound request for every worker; the server spawns it and talks to it from `runtime/src/server/gateway/`.

A worker talks to the server through its own control socket, shared-memory payload rings and a state page, and to the gateway through a separate set of rings. It never sees client sockets or TLS keys.

## Execution model

A worker is a Linux process with one JSC VM. It runs one or more routes from a single tenant; each route has an ES module entrypoint, its modules and its bindings. Configuration holds global defaults and named worker definitions. A worker definition lists its routes and overrides only the settings it names. The server starts and retires processes from each definition as demand changes; grouping equivalent processes is internal to the scheduler.

Memory and `concurrency` are limits per worker process, shared by all its routes. CPU time and the wall-clock deadline are limits per request. JSC runs one JavaScript turn at a time per VM, so concurrent requests overlap I/O and interleave continuations, and parallelism across cores comes from more processes.

`isolateRealm` defaults to `true` and gives each route its own realm, with separate globals, intrinsics and module registry. With `false`, the routes of a worker share one realm. The choice is fixed when the worker starts. Realms separate state but share the heap, the garbage collector and the process, so they are not a trust boundary.

A route reaches resources only through what its configuration grants. Bindings are the named values of the handler's `env`: configured values, the filesystem and other routes. The `network` setting grants outbound access to the route's global `fetch()`, which libraries call directly: a list of allowed hosts, with nothing allowed by default, and loopback, link-local and metadata addresses denied even for an allowed host. It cascades like other settings from global defaults to the worker definition, and a route may also override it. A route's grant is least privilege inside one tenant; the hard boundary is the process, so code that escapes the engine can reach what any route of its worker definition is granted, and nothing beyond that. Input is standard JavaScript, bundled with Bun or esbuild when needed. Bytecode and caches are internal to the runtime.

## Invariants

Every change preserves these. Performance work that needs to break one is a design question, not an optimization.

- Mutually untrusted code never shares a worker process. The platform embedding Collo decides what counts as one tenant.
- A worker is born inside its cgroup, so its limits apply before its first instruction. It then enters user, mount and network namespaces, chroots into a private tmpfs and installs a seccomp filter on every thread. From then on it cannot run programs, create processes or threads, or open sockets.
- Engine and runtime code never need a new thread in a worker after the filter is installed.
- The gateway is the only outbound path. It allows a fetch only when the `network` setting of the route that owns the request grants it, using the request identity the server recorded, so a worker never gains a grant outside its worker definition.
- The zygote holds no tenant code, state or secrets. Everything a worker inherits is the same for all tenants.
- The server treats every message from a worker as hostile input and validates framing, sizes and handles before acting on it. That channel is the only place a worker touches state shared with other tenants.
- The server assigns route, worker and request identities and owns usage records. A worker reports measurements but cannot choose whose record they enter.
- A worker that crashes or exhausts its memory ends only its own in-flight requests, and the server records why they ended.
- The engine bridge meets Zig only at the C ABI in [`abi.h`](../../../runtime/src/bindings/include/collo/abi.h): plain data types and `collo_` functions. Library shims, such as BoringSSL's, have their own narrow headers.
- Collo loads no native code at run time. Everything it runs is linked into its one binary.

## Scope

Collo runs on one Linux node without the Collo platform or Cloudflare. Logs and usage records stay local; billing, deployment and fleet management belong to the embedding platform. Native addons and other operating systems are out of scope. JITCache is a separate product, and the runtime has no JITCache integration yet. Bun API compatibility is a later goal, built on Collo's own event loop, and stays out of current work.

## Current state

`collo serve` runs a `collo.json` configuration, or an entry module with a configuration synthesized from it, behind TLS and HTTP/2, and generates a self-signed certificate when none is configured. The server matches each request's path against a static route table built at boot and schedules workers per worker definition; console lines go to stderr, and access and usage records go to a local analytics directory when one is configured. A worker runs every route of its definition, each in its own realm unless `isolateRealm` is false. `network` and `cpuMs` are rejected as not supported yet; until `network` lands, outbound `fetch` reaches any public HTTPS origin. The request path follows four principles: every failure belongs to a connection, a worker, a lane or the server; one pool per worker definition hands out worker slots and gives a freed slot to the request waiting for it; the gateway admits each fetch on a capability token the server mints with no round trip; and the server reads what a worker writes once, into a private copy. The build works, and `zig build smoke`, required before every handoff, runs the test suites and the kernel lanes with strict skips, then one HTTP/2 request through the installed `collo serve`. The cold-start budget is not met.

Every area reference under `internals/` is written from the current code and kept current with it: the change that alters a mechanism updates the reference that describes it. Where a reference disagrees with this document about goals or invariants, this document wins. Where it disagrees with the code about mechanics, the code and its `//!` headers win.

## References

Rules:

- [conventions.md](conventions.md): repository-wide rules for layout, dependencies, the ABI, memory and descriptors, errors, threads, tests, comments and performance claims.
- [cpp.md](cpp.md): C++ in the engine bridge, from the ABI boundary to JSC rooting and exceptions.
- [zig/0-15.md](zig/0-15.md): Zig 0.15.2 standard library usage.
- [zig/tiger-style.md](zig/tiger-style.md): Zig style, assertions, bounds and layout.

Build, tests and measurement:

- [internals/build.md](internals/build.md): build steps, job limits, the `runtime/deps/` layout, engine profiles and provenance, WebKit patch authoring.
- [e2e.md](e2e.md): the local full-flow test through server, zygote, sandboxed worker and gateway.
- [runtime/bench/sandbox/README.md](../../../runtime/bench/sandbox/README.md): cold-start and memory microbenchmarks.

Areas:

- [internals/boot.md](internals/boot.md): the binary's roles, the server's boot order, the zygote's preparation and fork loop, a worker's birth up to `WorkerReady`, and the shutdown.
- [internals/request.md](internals/request.md): a request from accept to response, covering h2/TLS, routing, dispatch, bodies, accounting and errors.
- [internals/request-timeline.md](internals/request-timeline.md): how a worker splits a request's wall time into execution, waiting and I/O, its two CPU clocks, and the records that carry the numbers to the server.
- [internals/scheduler.md](internals/scheduler.md): the pool per worker definition, the launcher, the reaper and the caps that bound them.
- [internals/memory-pressure.md](internals/memory-pressure.md): a worker's memory limit from the configuration to its cgroup, the marks a growing worker meets, how a memory death is classified and recorded, the OOM scores, and the memory the node spends per worker outside its cgroup.
- [internals/security.md](internals/security.md): sandbox layers, the seccomp allowlist and the server trust boundary.
- [internals/egress.md](internals/egress.md): outbound fetch through the gateway: the token, the sessions and their wake set, admission, the pools and the limits.
