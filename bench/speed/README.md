# Speed: Collo, workerd and Bun at full load

This folder measures how many requests per second Collo, workerd and Bun serve on one CPU, how much CPU each spends per request, and how much memory each holds before, during and after the load. It needs nothing from the rest of the repository except the `collo` binary under test, which `COLLO` names. Everything else is pinned here: the driver (`bench.js`), the summary (`summarize.js`), the servers and cases, the npm packages (`package.json`, `bun.lock`), and the tools that `./run.sh setup` downloads and checks by hash (Bun 1.4.3 and oha 1.16.0).

## What it measures

Each run starts one runtime alone in a fresh cgroup scope under the bench's own subtree, `/sys/fs/cgroup/collo-speed-bench`, pinned to `SERVER_CPU`, serving one case bundle over TLS on one port: Collo and Bun over HTTP/2, workerd over HTTP/1.1, the only protocol it accepts. Collo runs `collo serve` on the bundle, workerd one worker per case (`servers/workerd.capnp`), and Bun `Bun.serve` calling the bundle's `fetch` (`servers/bun.js`). The driver and oha run on `CLIENT_CPU`.

The cases (`cases/`) are a plain hello, a Hono JSON API whose load creates a user, and a webhook whose load checks an HMAC signature over a 1 KB event; `./run.sh check` confirms every runtime answers every case's checks with the same status and body.

A run waits until the one-minute load average is below `QUIET_LOAD`, starts the runtime, sends the first request (Collo starts its worker on it, where workerd and Bun load the case at startup), reads the scope's memory 1 s later as the base, warms up with oha for `WARMUP` seconds, then measures a `WINDOW`-second closed loop of oha at `CONNECTIONS` connections, with one request in flight each, and waits for the requests still in flight at the end. The window records the requests answered with the case's status, any other answer or error, which invalidates the run, the scope's CPU over the window per answered request, the scope's peak memory, and oha's whole report. After `IDLE` seconds the scope is read again. Runs rotate the runtimes' order each repetition, `REPS` repetitions per case.

With `CONNECTIONS` unset, a sweep first runs every runtime at 1, 8, 32, 64 and 128 connections for 3 s each and picks, per case, the smallest count where each runtime reaches 95% of its own best. On a four-CPU machine set `CONNECTIONS=8`: from about 32 connections workerd's event loop can go 5 s without polling for I/O under saturation, and its 5 s keep-alive timeout then resets every connection that waited, which invalidates its runs.

`summary.md` gives, per case and runtime, the median and range over valid runs of req/s, CPU per request and the three memory readings, the slowest request over every run, and the sweep when one ran.

## Running it

Linux with cgroup v2, sudo, curl, unzip and openssl. Four CPUs fit the default pinning; set `SERVER_CPU` and `CLIENT_CPU` otherwise.

```sh
./run.sh setup                                       # once
./run.sh prepare                                     # once per boot (sudo)
COLLO=/path/to/collo ./run.sh check
COLLO=/path/to/collo CONNECTIONS=8 REPS=3 ./run.sh measure
```

`./run.sh unprepare` removes the cgroup subtree once no session runs. `run.sh`'s header lists every setting with its default.
