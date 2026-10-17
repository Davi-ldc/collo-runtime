# Memory per tenant: Collo, workerd and gVisor

This folder measures what each added tenant costs three ways of running many small JavaScript tenants on one Linux machine: Collo, workerd, and Bun in gVisor as GKE Sandbox runs a pod. It needs nothing from the rest of the repository except the `collo` binary under test, which `COLLO` names. Everything else is pinned here: the driver (`density.js`), the servers and cases, the npm packages (`package.json`, `bun.lock`), and the tools that `./run.sh setup` downloads and checks by hash (Bun 1.4.3, oha 1.16.0, gVisor `release-20261005.0` with its containerd shim, the CNI plugins 1.9.1, and `debian:bookworm-slim` by digest).

## What it measures

Each side and phase gets a fresh cgroup scope under the bench's own subtree, `/sys/fs/cgroup/collo-memory-bench`, and the runtime runs alone in it with all its processes, pinned to `SERVER_CPU`. The driver, curl and oha run on `CLIENT_CPU`, outside the scope.

A reading takes `memory.current - (file - shmem) - slab_reclaimable` of the scope: what the runtime holds and the kernel cannot drop on its own, anonymous memory, kernel memory and shared memory included, the page cache and reclaimable slab left out. gVisor's memory file is shared memory, so it counts. The gvisor side's containerd shims run outside the scope, under containerd, and the reading adds their proportional set size as `outside`. Each reading also keeps the scope's raw `memory.current` and `memory.stat`, and the machine's used memory from `/proc/meminfo`, which swings by tens of MiB and serves only as a cross-check.

Every tenant runs its own copy of the case's bundle, so no two tenants share code, and gets a memory limit of `MEMORY_MIB`: Collo's `limits.memoryMiB`, V8's old space through workerd's `v8Flags`, and the pod's limit on the gvisor side.

Phases (`PHASES`):

- **idle**: tenants arrive one at a time; each serves `REQUESTS` requests and goes quiet, and the scope is read `WAIT_S` seconds after it arrives. The figure is the median of what each added tenant changed, outside memory included.
- **load**: as idle, but each new tenant starts receiving `RATE` requests per second from its own oha over one connection and keeps receiving them.
- **series**: one tenant under `RATE` requests per second for `SERIES_S` seconds, read every `SAMPLE_S` seconds, to show whether memory under load settles.
- **scenario**: for each count in `SCENARIO_TENANTS`, that many tenants start, then all of them take `RATE` requests per second together for `SCENARIO_S` seconds, read every `SAMPLE_S` seconds. Memory is the median over the last minute; per tenant is that minus the reading before any load, divided by the tenants. It also records the CPU of the scope and the shims over the load window, per answered request, and each tenant's p50 and p99 from oha with `--latency-correction`.
- **sharing**, Collo only: `SHARING_TENANTS` tenants each serve one request, and `WAIT_S` seconds later, once every worker has gone quiet and run its idle collection, the phase reads `/proc/<pid>/smaps_rollup` of every process in the scope and the cgroup leaf of every worker; then each tenant serves nine more and the phase reads again. It shows how much of an idle worker's resident memory it shares with other processes and how much is its own.

What the sharing phase reads:

- `Rss`: the process's resident pages, shared or not.
- `Pss`: each resident page divided by the number of processes that map it, so the Pss of all processes adds up to the memory they use together.
- `Shared_Clean`, `Shared_Dirty`: resident pages that at least one other process maps too. A worker shares with the zygote the pages it inherited at the fork and has not written since, clean or dirty as they were in the zygote, and the binary's text with every Collo process.
- `Private_Clean`, `Private_Dirty`: resident pages only this process maps. Private_Dirty is what the worker wrote itself: its own allocations and the copies of inherited pages it modified.
- `Anonymous`: pages that no file backs, heap and stacks, whether shared or private.
- A worker leaf's `memory.current`, with `anon`, `file` and `kernel` from its `memory.stat`: the kernel charges a page to the cgroup of the process that first brought it into memory, so a worker's leaf holds the pages the worker faulted itself, its private memory, the kernel memory of its tasks and any shared page it touched first, and not the pages it inherited from the zygote, which stay charged to the scope's main leaf.

smaps covers user-space mappings only: kernel memory, page tables and socket buffers among it, shows up in a leaf's `kernel`, not in `Rss`. A shared page's sharer is not named: `Shared_*` counts the zygote, the other workers and the server alike, the latter through the memory the server and a worker map together.

Sides (`SIDES`):

- **collo**: one `collo serve` with a worker definition per tenant, each with a network grant so it pays for its egress session as the others can reach the network. A tenant's first request launches its worker. The server, the zygote, the egress gateway and every worker share the scope.
- **workerd**: one workerd process whose front worker loads each tenant as an isolate of its own on its first request, through the experimental `workerLoader`, so tenants arrive one at a time. Every request crosses the front's isolate, which costs CPU and latency under load.
- **workerd-static**: workerd as a self-hosted node runs a fixed set of workers, a static service and TLS socket per tenant, with nothing experimental. workerd builds every configured worker at startup, so the reading before load already holds the idle isolates and a scenario's per-tenant figure counts only what load adds. It takes only the series and scenario phases. Use it, not `workerd`, under load.
- **gvisor**: Bun serving each tenant in a pod as GKE Sandbox runs one: containerd starts it through gVisor's shim, one per sandbox, on the systrap platform, with gVisor's own network stack in a network namespace that the ptp CNI plugin wires to the host over a veth, and a root from the pinned image under runsc's overlay. The pod's cgroup holds the sandbox with the tenant's memory limit and `SERVER_CPU` as its cpuset, which binds every process of the sandbox, the systrap stubs that run Bun's code included. A GKE pod also holds a pause container, left out here, and Bun, the server and the tenant's bundle come in read-only bind mounts rather than the image.

Every side serves TLS: Collo and Bun over HTTP/2, workerd over HTTP/1.1, the only protocol it accepts.

## Running it

Linux with cgroup v2, sudo, curl, unzip, zstd and openssl; the gvisor side also needs containerd running with its `ctr` client, and sudo without a password, since it calls `sudo -n` during a session. Four CPUs fit the default pinning; set `SERVER_CPU` and `CLIENT_CPU` otherwise.

```sh
./run.sh setup                          # once: tools, packages, bundles, certificate
./run.sh prepare                        # once per boot (sudo)
./run.sh gvisor-setup                   # once, for the gvisor side (sudo)
COLLO=/path/to/collo ./run.sh measure   # idle, all three sides
COLLO=/path/to/collo PHASES=scenario SIDES="collo workerd-static gvisor" CASE=hono ./run.sh measure
```

Each session writes `results/<UTC stamp>/`: `summary.md` with a table per phase and every reading, `runs.jsonl` with the raw readings and load reports, `environment.txt` with the machine, every tool's version and hash and the settings, `servers.log` with the runtimes' output, and each oha report.

`./run.sh gvisor-revert` removes what the gvisor side leaves on the machine: its containers, image and namespace in containerd, any network namespace left by an interrupted session, and `/run/collo-memory-bench`. `./run.sh unprepare` removes the cgroup subtree once no session runs. A session leaves no scope, pod, network namespace or route behind, even when a side fails.

## Settings

`run.sh`'s header lists every setting with its default: `COLLO`, `SERVER_CPU` 1, `CLIENT_CPU` 2-3, `QUIET_LOAD` 2 (each phase waits until the one-minute load average is below it), `SIDES` "collo workerd gvisor", `PHASES` "idle", `CASE` hello (or hono, or crypto, a webhook whose request checks an HMAC signature over a 1 KB event), `TENANTS` 16, `REQUESTS` 10, `RATE` 100, `WAIT_S` 10, `SERIES_S` 300, `SAMPLE_S` 10, `MEMORY_MIB` 128, `SCENARIO_TENANTS` "3 6 9", `SCENARIO_S` 300, `SHARING_TENANTS` 8.
