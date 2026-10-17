// The driver behind `./run.sh check` and `./run.sh measure`. run.sh starts it
// inside the bench's own delegated cgroup subtree (`./run.sh prepare`), pinned
// to CLIENT_CPU, with the settings it documents in the environment; README.md
// describes the method.
//
//   bun bench.js check
//   bun bench.js measure <results directory>
import { appendFileSync, closeSync, mkdirSync, openSync, readFileSync, readSync, readdirSync, rmdirSync, writeFileSync, writeSync } from "node:fs";
import cases from "./cases/requests.js";

const env = process.env;
const HERE = import.meta.dir;
const PORT = 18443;
const SWEEP = [1, 8, 32, 64, 128];
const SWEEP_SECONDS = 3;
const [REPS, WINDOW, WARMUP, IDLE, QUIET_LOAD] = [env.REPS, env.WINDOW, env.WARMUP, env.IDLE, env.QUIET_LOAD].map(Number);
const CASES = env.CASES.split(" ");
const RUNTIMES = env.RUNTIMES.split(" ");
const CLIENT_CPUS = env.CLIENT_CPU.split(",").reduce((n, range) => {
  const [first, last = first] = range.split("-").map(Number);
  return n + last - first + 1;
}, 0);
// The bench's delegated subtree; run.sh moved this process into its runner.
const SUBTREE = env.SPEED_BENCH_CGROUP;

// Each runtime serves a case bundle on PORT over TLS. Collo and Bun speak
// HTTP/2, workerd HTTP/1.1, its only protocol.
const bundle = (name) => `${HERE}/dist/${name}.js`;
const runtimes = {
  collo: { http2: true, command: (name) => [env.COLLO, "serve", bundle(name), "--listen", `127.0.0.1:${PORT}`] },
  workerd: { http2: false, command: (name) => [env.WORKERD, "serve", `${HERE}/servers/workerd.capnp`, name, "--socket-addr", `https=127.0.0.1:${PORT}`] },
  bun: { http2: true, command: (name) => [env.BUN, `${HERE}/servers/bun.js`, bundle(name), String(PORT)] },
};
for (const name of CASES) if (!(name in cases)) throw new Error(`unknown case ${name}`);
for (const name of RUNTIMES) if (!(name in runtimes)) throw new Error(`unknown runtime ${name}`);

// --- servers ------------------------------------------------------------------

let scopes = 0;
// The one server that runs at a time.
let running = null;

// The kernel takes each write to a cgroup control file as one command, and a
// short string goes out in one write.
const writeControl = (directory, file, text) => writeFileSync(`${directory}/${file}`, text);

// A scope for one server: a `main` leaf for its first process and a
// process-free `workers` branch where Collo creates its workers' leaves. cpu,
// memory and pids reach the children of both, and no page of the scope goes
// to swap.
function createScope(scope) {
  mkdirSync(`${scope}/main`, { recursive: true });
  mkdirSync(`${scope}/workers`);
  writeControl(scope, "cgroup.subtree_control", "+cpu +memory +pids");
  writeControl(`${scope}/workers`, "cgroup.subtree_control", "+cpu +memory +pids");
  try {
    writeControl(scope, "memory.swap.max", "0");
  } catch {
    // A kernel without swap accounting has no such file.
  }
}

// Removes a scope once no process is left in it, its deepest cgroups first.
function removeScope(directory) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    if (entry.isDirectory()) removeScope(`${directory}/${entry.name}`);
  }
  rmdirSync(directory);
}

// Starts a runtime in a fresh scope, pinned to SERVER_CPU, and returns once it
// answers. Every runtime gets the same launch; only Collo reads the workers
// directory. The shell moves itself into the scope's main leaf and execs the
// server, so every page the server faults is charged to the scope.
async function start(runtime, name, log) {
  if (curl(runtime, { path: "/" }).status) throw new Error(`port ${PORT} already answers; stop that server first`);
  const scope = `${SUBTREE}/scope-${process.pid}-${++scopes}`;
  createScope(scope);
  appendFileSync(log, `--- ${runtime} ${name}\n`);
  const output = openSync(log, "a");
  const enter = 'echo $$ > "$1/cgroup.procs" && shift && exec "$@"';
  const proc = Bun.spawn(["sh", "-c", enter, "sh", `${scope}/main`, "taskset", "-c", env.SERVER_CPU, ...runtimes[runtime].command(name)], {
    env: { ...env, COLLO_WORKER_CGROUP_ROOT: `${scope}/workers` },
    stdout: output,
    stderr: output,
  });
  closeSync(output);
  running = { runtime, scope, proc };
  for (let i = 0; i < 300 && proc.exitCode === null; i++) {
    if (curl(runtime, { path: "/" }).status) return running;
    await Bun.sleep(100);
  }
  await stop();
  throw new Error(`${runtime} did not answer within 30 s; see ${log}`);
}

// Stops the running server with SIGTERM, kills its whole scope if it still
// runs 10 s later, and removes the scope.
async function stop() {
  if (running === null) return;
  const { runtime, scope, proc } = running;
  running = null;
  proc.kill("SIGTERM");
  for (let i = 0; populated(scope); i++) {
    if (i === 100) {
      console.log(`${runtime} still runs 10 s after SIGTERM; killing its scope`);
      writeControl(scope, "cgroup.kill", "1");
    }
    if (i === 200) throw new Error(`${scope} keeps processes after a kill`);
    await Bun.sleep(100);
  }
  await proc.exited;
  removeScope(scope);
}

process.on("SIGINT", async () => {
  await stop();
  process.exit(130);
});

const populated = (scope) => readFileSync(`${scope}/cgroup.events`, "utf8").includes("populated 1");

// --- requests -----------------------------------------------------------------

const url = (path) => `https://127.0.0.1:${PORT}${path}`;
const headerArgs = (headers = {}) => Object.entries(headers).flatMap(([name, value]) => ["-H", `${name}: ${value}`]);

// One request with curl in the runtime's protocol; status 0 when nothing answers.
function curl(runtime, { method = "GET", path, headers, body }) {
  const args = ["curl", "-sk", runtimes[runtime].http2 ? "--http2" : "--http1.1", "--max-time", "5", "-X", method, ...headerArgs(headers)];
  if (body !== undefined) args.push("--data-binary", body);
  const out = Bun.spawnSync([...args, "-w", "\n%{http_code} %{http_version}", url(path)]).stdout.toString();
  const cut = out.lastIndexOf("\n");
  const [status, version] = out.slice(cut + 1).split(" ");
  return { status: Number(status), version, body: out.slice(0, cut) };
}

// One closed-loop oha window on the case's load request: `connections`
// connections with one request in flight each, for `seconds`, and the
// requests in flight at the end waited for, so every one counts. `responses`
// are the answers with the load's status (201 for the API's POST, otherwise
// 200), and any other answer or error invalidates the window. It is
// client-bound when oha used at least 95% of the client CPUs.
async function oha(runtime, name, connections, seconds) {
  const { request, status } = cases[name].load;
  const { method = "GET", path, headers, body } = request;
  const args = [env.OHA, "--no-tui", "--output-format", "json", "--insecure", "--wait-ongoing-requests-after-deadline"];
  args.push("-c", String(connections), "-z", `${seconds}s`, "-m", method, ...headerArgs(headers));
  if (runtimes[runtime].http2) args.push("--http2");
  if (body !== undefined) args.push("-d", body);
  const proc = Bun.spawn([...args, url(path)], { stdout: "pipe", stderr: "inherit" });
  const report = JSON.parse(await new Response(proc.stdout).text());
  await proc.exited;
  const { [status]: responses = 0, ...otherStatuses } = report.statusCodeDistribution;
  const failures = { ...otherStatuses, ...report.errorDistribution };
  const clientCpuUsec = Number(proc.resourceUsage().cpuTime.total);
  return {
    seconds: report.summary.total,
    responses,
    failures,
    valid: responses > 0 && Object.keys(failures).length === 0,
    rps: responses / report.summary.total,
    client_cpu_usec: clientCpuUsec,
    client_bound: clientCpuUsec >= 0.95 * CLIENT_CPUS * report.summary.total * 1e6,
    oha: report,
  };
}

// --- what a scope reads -------------------------------------------------------

const number = (path) => Number(readFileSync(path, "utf8"));
const cpuUsec = (scope) => Number(/^usage_usec (\d+)$/m.exec(readFileSync(`${scope}/cpu.stat`, "utf8"))[1]);
const pss = (pid) => 1024 * Number(/^Pss:\s+(\d+) kB$/m.exec(readFileSync(`/proc/${pid}/smaps_rollup`, "utf8"))[1]);

function pids(cgroup) {
  const own = readFileSync(`${cgroup}/cgroup.procs`, "utf8").split("\n").filter(Boolean).map(Number);
  const children = readdirSync(cgroup, { withFileTypes: true }).filter((entry) => entry.isDirectory());
  return own.concat(...children.map((child) => pids(`${cgroup}/${child.name}`)));
}

// The scope's charged memory and the summed PSS of its processes, in bytes.
function memory(scope) {
  const list = pids(scope);
  return { current: number(`${scope}/memory.current`), pss: list.reduce((sum, pid) => sum + pss(pid), 0), processes: list.length };
}

// Since Linux 6.12 a write to memory.peak restarts the peak that reads through
// the same descriptor see. Older kernels refuse it, and the window falls back
// to its 100 ms samples.
function restartPeak(scope) {
  const fd = openSync(`${scope}/memory.peak`, "r+");
  try {
    writeSync(fd, "reset\n");
    return fd;
  } catch {
    closeSync(fd);
    return null;
  }
}

function readPeak(fd) {
  const text = Buffer.alloc(32);
  const length = readSync(fd, text, 0, text.length, 0);
  closeSync(fd);
  return Number(text.toString("utf8", 0, length));
}

// --- a run --------------------------------------------------------------------

// Waits until the 1-minute load average is below QUIET_LOAD and returns it.
async function quiet() {
  for (;;) {
    const load1 = Number(readFileSync("/proc/loadavg", "utf8").split(" ")[0]);
    if (load1 < QUIET_LOAD) return load1;
    console.log(`load1 ${load1} is not below ${QUIET_LOAD}; waiting`);
    await Bun.sleep(30_000);
  }
}

// The measured load window: oha with the scope's memory.current sampled every
// 100 ms and its CPU usage read on both sides.
async function loadWindow({ runtime, scope }, name, connections) {
  const peakFd = restartPeak(scope);
  const cpuBefore = cpuUsec(scope);
  let sampledMax = number(`${scope}/memory.current`);
  const sampler = setInterval(() => (sampledMax = Math.max(sampledMax, number(`${scope}/memory.current`))), 100);
  const load = await oha(runtime, name, connections, WINDOW);
  clearInterval(sampler);
  const cpu = cpuUsec(scope) - cpuBefore;
  const end = memory(scope);
  sampledMax = Math.max(sampledMax, end.current);
  return {
    ...load,
    cpu_usec: cpu,
    cpu_us_per_request: cpu / load.responses,
    peak: peakFd === null ? sampledMax : readPeak(peakFd),
    peak_source: peakFd === null ? "samples" : "memory.peak",
    sampled_max: sampledMax,
    end,
  };
}

async function run(runtime, name, connections, rep, log) {
  const load1 = await quiet();
  const server = await start(runtime, name, log);
  try {
    // Base is a server ready to serve the case: Collo starts its worker on
    // the first request, where workerd and Bun load the case at startup.
    const first = curl(runtime, cases[name].load.request);
    if (first.status !== cases[name].load.status) throw new Error(`${runtime} answered the first ${name} request with ${first.status}`);
    await Bun.sleep(1000);
    const base = memory(server.scope);
    await oha(runtime, name, connections, WARMUP);
    const load = await loadWindow(server, name, connections);
    await Bun.sleep(IDLE * 1000);
    const idle = memory(server.scope);
    const settings = { server_cpu: env.SERVER_CPU, client_cpu: env.CLIENT_CPU, warmup: WARMUP, window: WINDOW, idle: IDLE, quiet_load: QUIET_LOAD };
    return { kind: "run", case: name, runtime, rep, connections, load1, settings, base, load, idle };
  } finally {
    await stop();
  }
}

// Every runtime at each SWEEP point after a warm-up. The case's full load is
// the smallest point where each reaches 95% of its own best, or, when no point
// does, the one where the runtime furthest from its best comes closest.
async function sweep(name, log, write) {
  const rps = {};
  for (const runtime of RUNTIMES) {
    const load1 = await quiet();
    await start(runtime, name, log);
    try {
      await oha(runtime, name, SWEEP.at(-1), WARMUP);
      rps[runtime] = {};
      for (const connections of SWEEP) {
        const point = { kind: "sweep", case: name, runtime, connections, load1, ...(await oha(runtime, name, connections, SWEEP_SECONDS)) };
        rps[runtime][connections] = point.rps;
        write(point);
        console.log(`${name} sweep ${runtime} ${connections} connections: ${point.rps.toFixed(0)} req/s${point.valid ? "" : ", invalid"}`);
      }
    } finally {
      await stop();
    }
  }
  const ratio = (connections) => Math.min(...RUNTIMES.map((runtime) => rps[runtime][connections] / Math.max(...Object.values(rps[runtime]))));
  return SWEEP.find((connections) => ratio(connections) >= 0.95) ?? SWEEP.reduce((a, b) => (ratio(b) > ratio(a) ? b : a));
}

// --- commands -----------------------------------------------------------------

const MiB = (bytes) => (bytes / 2 ** 20).toFixed(1);
// The API answers with a random UUID per user.
const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/g;

async function check() {
  mkdirSync(`${HERE}/results`, { recursive: true });
  const log = `${HERE}/results/check.log`;
  let failed = 0;
  for (const name of CASES) {
    for (const runtime of RUNTIMES) {
      const server = await start(runtime, name, log);
      try {
        const version = runtimes[runtime].http2 ? "2" : "1.1";
        let passed = 0;
        for (const { request, status, body } of cases[name].checks) {
          const answer = curl(runtime, request);
          const got = `${answer.status} HTTP/${answer.version} ${answer.body.replace(UUID, "<uuid>")}`;
          const want = `${status} HTTP/${version} ${body}`;
          if (got === want) passed++;
          else console.log(`${name} ${runtime} ${request.method ?? "GET"} ${request.path}: got ${got}, want ${want}`);
        }
        failed += cases[name].checks.length - passed;
        const { processes, pss: bytes } = memory(server.scope);
        console.log(`${name} ${runtime}: ${passed}/${cases[name].checks.length} checks pass over HTTP/${version}; ${processes} processes, PSS ${MiB(bytes)} MiB`);
      } finally {
        await stop();
      }
    }
  }
  if (failed > 0) throw new Error(`${failed} checks failed; server output in ${log}`);
  console.log("check passed");
}

async function measure(out) {
  const log = `${out}/servers.log`;
  const write = (record) => appendFileSync(`${out}/runs.jsonl`, `${JSON.stringify(record)}\n`);
  for (const name of CASES) {
    const connections = Number(env.CONNECTIONS) || (await sweep(name, log, write));
    console.log(`${name}: ${connections} connections`);
    for (let rep = 1; rep <= REPS; rep++) {
      // Rotating the order each repetition spreads drift over every runtime.
      for (const runtime of RUNTIMES.map((_, i) => RUNTIMES[(i + rep - 1) % RUNTIMES.length])) {
        const record = await run(runtime, name, connections, rep, log);
        write(record);
        const { load, base, idle } = record;
        console.log(
          `${name} rep ${rep} ${runtime}: ${load.rps.toFixed(0)} req/s, ${load.cpu_us_per_request.toFixed(1)} CPU µs/request, ` +
            `base ${MiB(base.current)} MiB, peak ${MiB(load.peak)} MiB, idle ${MiB(idle.current)} MiB, load1 ${record.load1}` +
            `${load.valid ? "" : `, invalid ${JSON.stringify(load.failures)}`}${load.client_bound ? ", client-bound" : ""}`,
        );
      }
    }
  }
}

const [command, out] = process.argv.slice(2);
if (command === "check") await check();
else if (command === "measure") await measure(out);
else throw new Error("usage: bun bench.js check | measure <results directory>");
