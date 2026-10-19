# Benches

All on the Oracle A1 (Neoverse-N1, 4 cores),Code and full method: [`bench/memory/`](bench/memory/README.md) and [`bench/speed/`](bench/speed/README.md).

| side | how it runs a tenant |
|---|---|
| Collo | a process forked from a zygote, in its own cgroup, namespaces and seccomp filter |
| workerd 2026-10-12 | a V8 isolate inside one shared process |
| gVisor | Bun 1.4.3 in a pod as GKE Sandbox runs it: containerd, the runsc shim, gVisor's network stack, an image root |
| Bun 1.4.3 | one process, no isolation (speed reference only) |

Memory is the runtime's cgroup minus page cache, plus gVisor's shims, which run outside it. Every tenant is limited to 128 MiB.

## Idle

Each tenant serves 10 hello requests and goes quiet; median over 16 added tenants.

| | Collo | workerd | gVisor |
|---|---:|---:|---:|
| memory per tenant | 2.0 MiB | 2.3 MiB | 22.6 MiB |

About 93% of an idle Collo worker's resident memory is shared with the zygote and the other workers.

## Busy

3, 6 and 9 Hono tenants at 100 requests per second each, for 5 minutes.

| | Collo | workerd | gVisor |
|---|---:|---:|---:|
| memory per tenant | 10–12 MiB | 130 MiB, keeps growing | 31–35 MiB |
| CPU per request | 191–204 µs | 267–273 µs | 493–523 µs |
| p99 | 0.43–0.55 ms | 0.42–1.62 ms | 1.24–2.03 ms |

## Full load

8 connections, 3 runs, medians, requests per second (CPU µs per request).

| | Collo | workerd | Bun |
|---|---:|---:|---:|
| hello | 12,830 (78) | 8,628 (115) | 31,644 (31) |
| Hono API | 6,727 (148) | 6,250 (159) | 16,738 (59) |
| crypto | 6,339 (157) | 5,591 (178) | 8,659 (115) |

workerd's slowest requests reach 0.3 to 1.2 s; at 32 connections it resets connections, so every side runs at 8.
