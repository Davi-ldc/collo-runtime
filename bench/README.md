# Benchmarks against workerd, Bun and gVisor

Two self-contained benchmarks, each in its own folder with its own driver, servers, cases, pinned packages and tools, cgroup setup and README. Each needs only the `collo` binary under test.

- [`speed/`](speed/README.md): requests per second, CPU per request and memory of Collo, workerd and Bun at full load on one CPU.
- [`memory/`](memory/README.md): what each added tenant costs Collo, workerd and Bun in gVisor as GKE Sandbox runs it, idle, under steady load and in a multi-tenant scenario.

`results/` holds sessions recorded before the two were split, with the harness they came from.
