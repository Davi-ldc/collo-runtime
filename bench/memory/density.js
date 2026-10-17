// What each added tenant costs Collo, workerd and Bun in gVisor, idle and under
// load. run.sh starts this driver inside the bench's own delegated cgroup
// subtree (`./run.sh prepare`), pinned to CLIENT_CPU, with the settings it
// documents; README.md describes the method.
//
//   bun density.js measure <results directory>
//
// For each side and phase, a fresh cgroup scope under the subtree holds the
// runtime and nothing else, on SERVER_CPU. Tenants come one at a time: in the
// idle phase each new tenant serves REQUESTS requests and goes quiet, in the
// load phase it starts receiving RATE requests per second and keeps receiving
// them to the end of the phase. WAIT_S seconds after each tenant arrives, the
// step records:
//   - memory, the scope's memory.current - (file - shmem) - slab_reclaimable:
//     what the runtime's processes hold and the kernel cannot drop on its own,
//     kernel memory and shared memory included, the page cache and
//     reclaimable slab left out;
//   - outside, the memory of the side's processes that run outside the scope,
//     the gvisor side's containerd shims, as their proportional set size;
//   - the scope's raw memory.current and memory.stat;
//   - the machine's used memory, MemTotal - MemFree - Buffers - (Cached -
//     Shmem) - SReclaimable from /proc/meminfo, the same sum over the whole
//     machine, whoever it is charged to.
// Step 0 is the runtime with no tenant. The series phase instead puts one
// tenant under RATE requests per second for SERIES_S seconds and reads the
// same every SAMPLE_S seconds, to show whether memory under load settles. The
// scenario phase, once per count in SCENARIO_TENANTS, starts that many tenants
// and puts them all under RATE requests per second together for SCENARIO_S
// seconds, read every SAMPLE_S seconds; it also records each tenant's latency
// percentiles and the CPU the runtime spent per request.
// The sharing phase, Collo only, starts SHARING_TENANTS tenants with one
// request each, reads every process's smaps_rollup and every worker's cgroup
// leaf WAIT_S seconds later, then sends each tenant nine more requests and
// reads again, to show how much of an idle worker's resident memory it shares
// and how much is its own.
// Every tenant gets a memory limit of MEMORY_MIB: Collo's limits.memoryMiB,
// V8's old space through workerd's v8Flags, and the pod's limit on the gvisor
// side. summary.md lists every step and each phase's figures.
import { appendFileSync, closeSync, existsSync, mkdirSync, openSync, readdirSync, readFileSync, rmdirSync, rmSync, writeFileSync } from "node:fs";
import cases from "./cases/requests.js";

const env = process.env;
const HERE = import.meta.dir;
const PORT = 18443;
const [TENANTS, REQUESTS, WAIT_S, RATE, SERIES_S, SAMPLE_S, QUIET_LOAD, MEMORY_MIB, SCENARIO_S] = [
  env.TENANTS,
  env.REQUESTS,
  env.WAIT_S,
  env.RATE,
  env.SERIES_S,
  env.SAMPLE_S,
  env.QUIET_LOAD,
  env.MEMORY_MIB,
  env.SCENARIO_S,
].map(Number);
const CASE = env.CASE;
const SIDES = env.SIDES.split(" ");
const PHASES = env.PHASES.split(" ");
const SCENARIO_TENANTS = env.SCENARIO_TENANTS.split(" ").map(Number);
const SHARING_TENANTS = Number(env.SHARING_TENANTS);
// Every tenant any phase may start.
const TENANT_COUNT = Math.max(TENANTS, SHARING_TENANTS, ...(PHASES.includes("scenario") ? SCENARIO_TENANTS : []));
// The bench's delegated subtree; run.sh moved this process into its runner.
const SUBTREE = env.MEMORY_BENCH_CGROUP;
const WORK = `${HERE}/dist/density`;
const COMPATIBILITY_DATE = "2026-10-12";

if (!(CASE in cases)) throw new Error(`unknown case ${CASE}`);
for (const phase of PHASES) if (!["idle", "load", "series", "scenario", "sharing"].includes(phase)) throw new Error(`unknown phase ${phase}`);

// --- what a step reads --------------------------------------------------------

function meminfo() {
  const fields = {};
  for (const line of readFileSync("/proc/meminfo", "utf8").split("\n")) {
    const match = /^(\w+):\s+(\d+) kB$/.exec(line);
    if (match) fields[match[1]] = Number(match[2]) * 1024;
  }
  return fields;
}

const machineUsed = (m) => m.MemTotal - m.MemFree - m.Buffers - (m.Cached - m.Shmem) - m.SReclaimable;
const STAT_KEYS = ["anon", "file", "shmem", "kernel", "kernel_stack", "pagetables", "sock", "slab_reclaimable", "slab_unreclaimable"];

function cgroupStat(scope) {
  const stat = {};
  for (const line of readFileSync(`${scope}/memory.stat`, "utf8").split("\n")) {
    const [key, value] = line.split(" ");
    if (STAT_KEYS.includes(key)) stat[key] = Number(value);
  }
  return stat;
}

function sample(scope, side, state) {
  const cgroup = Number(readFileSync(`${scope}/memory.current`, "utf8"));
  const stat = cgroupStat(scope);
  return {
    memory: cgroup - (stat.file - stat.shmem) - stat.slab_reclaimable,
    outside: side.outside?.(state).pss ?? 0,
    cgroup,
    cgroup_stat: stat,
    machine: machineUsed(meminfo()),
    at: Date.now(),
  };
}

// The CPU time, in microseconds, of everything in the scope and of the side's
// processes outside it.
function cpuUsec(scope, side, state) {
  const line = readFileSync(`${scope}/cpu.stat`, "utf8").split("\n").find((entry) => entry.startsWith("usage_usec "));
  return Number(line.split(" ")[1]) + (side.outside?.(state).cpu_usec ?? 0);
}

// Waits until the 1-minute load average is below QUIET_LOAD and returns it.
async function quiet() {
  for (;;) {
    const load1 = Number(readFileSync("/proc/loadavg", "utf8").split(" ")[0]);
    if (load1 < QUIET_LOAD) return load1;
    console.log(`load1 ${load1} is not below ${QUIET_LOAD}; waiting`);
    await Bun.sleep(30_000);
  }
}

// --- scopes ---------------------------------------------------------------------

// The kernel takes each write to a cgroup control file as one command, and a
// short string goes out in one write.
const writeControl = (directory, file, text) => writeFileSync(`${directory}/${file}`, text);
const populated = (scope) => readFileSync(`${scope}/cgroup.events`, "utf8").includes("populated 1");

// A scope for one side and phase: a `main` leaf for the runtime's first
// process, a process-free `workers` branch where Collo creates its workers'
// leaves, and the pods' leaves the gvisor side creates beside them. cpu,
// memory, pids and cpuset reach the scope's children, cpu, memory and pids
// the workers', and no page of the scope goes to swap.
function createScope(scope) {
  mkdirSync(`${scope}/main`, { recursive: true });
  mkdirSync(`${scope}/workers`);
  writeControl(scope, "cgroup.subtree_control", "+cpu +memory +pids +cpuset");
  writeControl(`${scope}/workers`, "cgroup.subtree_control", "+cpu +memory +pids");
  if (existsSync(`${scope}/memory.swap.max`)) writeControl(scope, "memory.swap.max", "0");
}

// Removes a scope once no process is left in it, its deepest cgroups first.
function removeScope(directory) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    if (entry.isDirectory()) removeScope(`${directory}/${entry.name}`);
  }
  rmdirSync(directory);
}

// Starts a runtime's first process in the scope's main leaf, pinned to
// SERVER_CPU: the shell moves itself there and execs, so every page the
// runtime faults is charged to the scope. Collo creates its workers' leaves
// under `workers`.
function spawnInScope(scope, command, log) {
  const output = openSync(log, "a");
  const enter = 'echo $$ > "$1/cgroup.procs" && shift && exec "$@"';
  const proc = Bun.spawn(["sh", "-c", enter, "sh", `${scope}/main`, "taskset", "-c", env.SERVER_CPU, ...command], {
    env: { ...env, COLLO_WORKER_CGROUP_ROOT: `${scope}/workers` },
    stdout: output,
    stderr: output,
  });
  closeSync(output);
  return proc;
}

async function stopScope(scope, proc) {
  proc?.kill("SIGTERM");
  for (let i = 0; populated(scope); i++) {
    if (i === 100) writeControl(scope, "cgroup.kill", "1");
    if (i === 200) throw new Error(`${scope} keeps processes after a kill`);
    await Bun.sleep(100);
  }
  await proc?.exited;
}

// --- tenants --------------------------------------------------------------------

// Every tenant runs its own copy of the case's bundle, with a last line that
// names it, so no two tenants share code, as no two customers would. Collo
// gets a definition per tenant, workerd a front that loads each one or a
// service per tenant, and the gvisor side a pod per tenant.
function writeTenants() {
  rmSync(WORK, { recursive: true, force: true });
  mkdirSync(WORK, { recursive: true });
  const source = readFileSync(`${HERE}/dist/${CASE}.js`, "utf8");
  const workers = {};
  const tenants = {};
  for (let i = 1; i <= TENANT_COUNT; i++) {
    const code = `${source}\n// tenant ${i}\n`;
    writeFileSync(`${WORK}/t${i}.js`, code);
    workers[`t${i}`] = { routes: { [`/t${i}/*`]: { entry: `./t${i}.js` } } };
    tenants[`t${i}`] = code;
  }
  // Each Collo tenant holds a network grant, as a workerd tenant and a pod can
  // reach the network, so every Collo worker also pays for its egress session.
  writeFileSync(`${WORK}/collo.json`, JSON.stringify({ settings: { network: { allow: ["api.example.com"] }, limits: { memoryMiB: MEMORY_MIB } }, workers }, null, 2));
  writeFileSync(`${WORK}/sources.json`, JSON.stringify({ compatibilityDate: COMPATIBILITY_DATE, tenants }));
  writeFileSync(
    `${WORK}/workerd.capnp`,
    `using Workerd = import "/workerd/workerd.capnp";

const config :Workerd.Config = (
  services = [
    (name = "front", worker = (
      modules = [
        (name = "front.js", esModule = embed "../../servers/workerd-front.js"),
        (name = "sources.json", json = embed "sources.json"),
      ],
      compatibilityDate = "${COMPATIBILITY_DATE}",
      bindings = [(name = "LOADER", workerLoader = ())],
    )),
  ],
  sockets = [${socketEntry("front", PORT)}],
  v8Flags = ["--max-old-space-size=${MEMORY_MIB}"],
);
`,
  );
}

function socketEntry(service, port) {
  return `(name = "${service}", address = "127.0.0.1:${port}", service = "${service}", https = (options = (), tlsOptions = (keypair = (privateKey = embed "../key.pem", certificateChain = embed "../cert.pem"))))`;
}

// One request in the side's protocol; its HTTP status, 0 when nothing answered.
function request(side, url, { method = "GET", headers = {}, body } = {}) {
  const args = ["curl", "-sk", side.http2 ? "--http2" : "--http1.1", "--max-time", "10", "-o", "/dev/null", "-w", "%{http_code}", "-X", method];
  for (const [name, value] of Object.entries(headers)) args.push("-H", `${name}: ${value}`);
  if (body !== undefined) args.push("--data-binary", body);
  return Number(Bun.spawnSync([...args, url]).stdout.toString());
}

// The case's load request, `count` times; each must answer with its status.
function serveRequests(side, base, i, count = REQUESTS) {
  const { request: load, status } = cases[CASE].load;
  for (let n = 0; n < count; n++) {
    const answer = request(side, `${base}${load.path}`, load);
    if (answer !== status) throw new Error(`${side.name} tenant ${i} answered ${answer}, not ${status}`);
  }
}

// RATE requests per second to one tenant over one connection until stopped;
// its report says how many answered with the case's status, and how fast.
// --latency-correction counts each request's latency from the moment its slot
// came, so a stall shows in the percentiles instead of only delaying the
// requests behind it.
function startLoad(side, phaseName, base, out, i) {
  const { request: load } = cases[CASE].load;
  const args = [env.OHA, "--no-tui", "--output-format", "json", "--insecure", "-c", "1", "-q", String(RATE), "--latency-correction", "-z", "1h", "-m", load.method ?? "GET"];
  for (const [name, value] of Object.entries(load.headers ?? {})) args.push("-H", `${name}: ${value}`);
  if (side.http2) args.push("--http2");
  if (load.body !== undefined) args.push("-d", load.body);
  const report = openSync(`${out}/load-${side.name}-${phaseName}-t${i}.json`, "w");
  const proc = Bun.spawn([...args, `${base}${load.path}`], { stdout: report, stderr: "inherit" });
  closeSync(report);
  return proc;
}

async function waitFor(condition, what) {
  for (let i = 0; i < 300; i++) {
    if (condition()) return;
    await Bun.sleep(100);
  }
  throw new Error(`${what} within 30 s`);
}

// --- sides ----------------------------------------------------------------------

// Collo: one server with a worker definition per tenant; a tenant's first
// request launches its worker.
const collo = {
  name: "collo",
  http2: true,
  async start(scope, log) {
    const proc = spawnInScope(scope, [env.COLLO, "serve", `${WORK}/collo.json`, "--listen", `127.0.0.1:${PORT}`], log);
    await waitFor(() => request(this, `https://127.0.0.1:${PORT}/__collo/healthz`) === 200, "collo did not answer");
    return { proc };
  },
  base: (state, i) => `https://127.0.0.1:${PORT}/t${i}`,
  async add() {},
  stop: (scope, { proc }) => stopScope(scope, proc),
};

// workerd: one process whose front worker loads each tenant as an isolate of
// its own on the tenant's first request, through the experimental
// workerLoader, so tenants arrive one at a time as in the idle phase. Every
// request crosses the front's isolate first, which costs CPU and latency under
// load, where the workerd-static side is the fair one. workerd speaks HTTP/1.1
// only.
const workerd = {
  name: "workerd",
  http2: false,
  async start(scope, log) {
    const proc = spawnInScope(scope, [env.WORKERD, "serve", `${WORK}/workerd.capnp`, "config", "--experimental"], log);
    await waitFor(() => request(this, `https://127.0.0.1:${PORT}/ping`) === 200, "workerd did not answer");
    return { proc };
  },
  base: (state, i) => `https://127.0.0.1:${PORT}/t${i}`,
  async add() {},
  stop: (scope, { proc }) => stopScope(scope, proc),
};

// workerd as a self-hosted node runs a fixed set of workers: one process whose
// static configuration holds a service and a TLS socket per tenant, each
// tenant its own isolate behind its own port, with no front worker and
// nothing experimental. workerd builds every configured worker at startup, so
// step 0 already holds the tenants' idle isolates, a scenario's per-tenant
// figure counts only what load adds, and the idle and load phases, which add
// tenants one at a time, do not suit this side.
const workerdStatic = {
  name: "workerd-static",
  http2: false,
  async start(scope, log, count) {
    const services = [`    (name = "ping", worker = (modules = [(name = "ping.js", esModule = "export default { fetch() { return new Response('ok'); } };")], compatibilityDate = "${COMPATIBILITY_DATE}")),`];
    const sockets = [`    ${socketEntry("ping", PORT)},`];
    for (let i = 1; i <= count; i++) {
      services.push(`    (name = "t${i}", worker = (modules = [(name = "main.js", esModule = embed "t${i}.js")], compatibilityDate = "${COMPATIBILITY_DATE}")),`);
      sockets.push(`    ${socketEntry(`t${i}`, PORT + i)},`);
    }
    const config = `${WORK}/workerd-static-${count}.capnp`;
    writeFileSync(
      config,
      `using Workerd = import "/workerd/workerd.capnp";\n\nconst config :Workerd.Config = (\n  services = [\n${services.join("\n")}\n  ],\n  sockets = [\n${sockets.join("\n")}\n  ],\n  v8Flags = ["--max-old-space-size=${MEMORY_MIB}"],\n);\n`,
    );
    const proc = spawnInScope(scope, [env.WORKERD, "serve", config, "config"], log);
    await waitFor(() => request(this, `https://127.0.0.1:${PORT}/`) === 200, "workerd did not answer");
    return { proc };
  },
  base: (state, i) => `https://127.0.0.1:${PORT + i}`,
  async add() {},
  stop: (scope, { proc }) => stopScope(scope, proc),
};

// Bun in gVisor as GKE Sandbox runs a pod: containerd starts each tenant
// through gVisor's shim (containerd-shim-runsc-v1, one per sandbox) on the
// systrap platform, with gVisor's own network stack serving a network
// namespace the ptp CNI plugin wires to the host over a veth, as GKE's pod
// network does, and a root from the pinned image under runsc's overlay. Bun,
// the server and the tenant's bundle come in read-only bind mounts. The
// sandbox's processes sit in a cgroup of their own under the scope, with the
// tenant's memory limit and SERVER_CPU as its cpuset, which binds every one of
// them, the systrap stubs that run Bun's code included; each shim runs under
// containerd, outside the scope, and its proportional set size and CPU count
// beside the scope's. A GKE pod's sandbox also holds a pause container, left
// out here.
const GVISOR_NAMESPACE = "collo-memory-bench";
const GVISOR_RUN = "/run/collo-memory-bench";
const GVISOR_PORT = 8443;
const podId = (i) => `collo-memory-bench-t${String(i).padStart(3, "0")}`;
const sudo = (args, options = {}) => Bun.spawnSync(["sudo", "-n", ...args], { stdin: "ignore", ...options });
const ctr = (...args) => sudo(["ctr", "-n", GVISOR_NAMESPACE, ...args]);

// Runs the ptp plugin as a container runtime does, for the network namespace
// named `id`; ADD returns the plugin's result, with the pod's address.
function cni(command, id) {
  const config = {
    cniVersion: "1.0.0",
    name: GVISOR_NAMESPACE,
    type: "ptp",
    ipMasq: false,
    ipam: { type: "host-local", ranges: [[{ subnet: "10.89.0.0/24" }]], dataDir: `${GVISOR_RUN}/ipam` },
  };
  const cniEnv = [`CNI_COMMAND=${command}`, `CNI_CONTAINERID=${id}`, `CNI_NETNS=/var/run/netns/${id}`, "CNI_IFNAME=eth0", `CNI_PATH=${env.CNI_DIR}`];
  const { exitCode, stdout, stderr } = sudo(["env", ...cniEnv, `${env.CNI_DIR}/ptp`], { stdin: Buffer.from(JSON.stringify(config)) });
  if (exitCode !== 0) throw new Error(`CNI ${command} for ${id} failed: ${stdout}${stderr}`);
  return command === "ADD" ? JSON.parse(stdout.toString()) : null;
}

const gvisor = {
  name: "gvisor",
  http2: true,
  async start() {
    if (!ctr("image", "ls", "-q").stdout.toString().split("\n").includes(env.GVISOR_IMAGE)) throw new Error(`${env.GVISOR_IMAGE} is missing; run ./run.sh gvisor-setup`);
    // The shim reads its runsc from this file; the rest of runsc's flags keep
    // the release's defaults: the systrap platform, gVisor's network stack
    // and runsc's overlay over the root.
    writeFileSync(`${WORK}/runsc.toml`, `binary_name = "${env.RUNSC}"\nroot = "${GVISOR_RUN}/runsc"\n`);
    return { ids: [], ips: [] };
  },
  base: (state, i) => `https://${state.ips[i]}:${GVISOR_PORT}`,
  async add(scope, state, i) {
    const id = podId(i);
    if (sudo(["ip", "netns", "add", id]).exitCode !== 0) throw new Error(`ip netns add ${id} failed`);
    state.ids.push(id);
    state.ips[i] = cni("ADD", id).ips[0].address.split("/")[0];
    const mounts = [
      [env.BUN, "/usr/local/bin/bun"],
      [`${HERE}/servers/bun.js`, "/srv/servers/bun.js"],
      [`${HERE}/dist/cert.pem`, "/srv/dist/cert.pem"],
      [`${HERE}/dist/key.pem`, "/srv/dist/key.pem"],
      [`${WORK}/t${i}.js`, "/srv/app.js"],
    ];
    const args = ["run", "--detach", "--runtime", env.RUNSC_SHIM, "--runtime-config-path", `${WORK}/runsc.toml`];
    args.push("--with-ns", `network:/var/run/netns/${id}`, "--cgroup", `${scope.replace("/sys/fs/cgroup", "")}/t${i}`, "--cpuset-cpus", env.SERVER_CPU);
    // No --log-uri: gVisor's shim opens a file:// URI as a literal path and
    // fails, so a detached sandbox's stdio goes nowhere.
    args.push("--memory-limit", String(MEMORY_MIB * 2 ** 20));
    args.push("--env", "HOME=/tmp", "--env", "BUN_RUNTIME_TRANSPILER_CACHE_PATH=0");
    for (const [source, destination] of mounts) args.push("--mount", `type=bind,src=${source},dst=${destination},options=rbind:ro`);
    args.push(env.GVISOR_IMAGE, id, "/usr/local/bin/bun", "/srv/servers/bun.js", "/srv/app.js", String(GVISOR_PORT), "0.0.0.0");
    const { exitCode, stderr } = ctr(...args);
    if (exitCode !== 0) throw new Error(`ctr run ${id} failed: ${stderr}`);
    const cpus = readFileSync(`${scope}/t${i}/cpuset.cpus.effective`, "utf8").trim();
    if (cpus !== env.SERVER_CPU) throw new Error(`${id} runs on CPUs ${cpus}, not ${env.SERVER_CPU}`);
    await waitFor(() => request(this, `${this.base(state, i)}/`) !== 0, `${id} did not answer`);
  },
  // The shims' proportional set size in bytes and their CPU time in
  // microseconds, read as root, since containerd starts them. The pattern's
  // [e] keeps pgrep from matching the shell that runs this script, whose
  // command line holds the pattern itself.
  outside() {
    const script = `for p in $(pgrep -f 'containerd-shim-runsc-v1 -namespac[e] ${GVISOR_NAMESPACE} '); do
      awk '/^Pss:/ {print "pss", $2 * 1024}' /proc/$p/smaps_rollup
      awk '{print "ticks", $14 + $15}' /proc/$p/stat
    done`;
    let pss = 0;
    let ticks = 0;
    for (const line of sudo(["sh", "-c", script]).stdout.toString().split("\n")) {
      const [key, value] = line.split(" ");
      if (key === "pss") pss += Number(value);
      if (key === "ticks") ticks += Number(value);
    }
    // USER_HZ is 100 on Linux.
    return { pss, cpu_usec: ticks * 10_000 };
  },
  // Kills and deletes every container, then its network, until containerd
  // lists none of them.
  async stop(scope, { ids }) {
    let left = ids;
    for (let round = 1; left.length; round++) {
      if (round > 5) throw new Error(`containerd still lists ${left.join(" ")} after five rounds of kill and delete`);
      for (const id of left) {
        ctr("task", "kill", "--signal", "KILL", id);
        ctr("task", "delete", "--force", id);
        ctr("container", "delete", id);
      }
      await Bun.sleep(1000);
      const listed = ctr("container", "ls", "-q").stdout.toString().split("\n");
      left = left.filter((id) => listed.includes(id));
    }
    for (const id of ids) {
      cni("DEL", id);
      sudo(["ip", "netns", "delete", id]);
    }
    await stopScope(scope, null);
  },
};

const sides = { collo, workerd, "workerd-static": workerdStatic, gvisor };
for (const name of SIDES) if (!(name in sides)) throw new Error(`unknown side ${name}`);

// --- phases ---------------------------------------------------------------------

async function phase(side, phaseName, out) {
  if (side === workerdStatic && phaseName !== "series") throw new Error(`the workerd-static side fixes its tenants at startup and takes no ${phaseName} phase`);
  const load1 = await quiet();
  const scope = `${SUBTREE}/scope-${process.pid}-${side.name}-${phaseName}`;
  createScope(scope);
  const log = `${out}/servers.log`;
  appendFileSync(log, `--- ${side.name} ${phaseName}\n`);
  const state = await side.start(scope, log, 1);
  const loads = [];
  const steps = [];
  try {
    await Bun.sleep(WAIT_S * 1000);
    steps.push({ tenants: 0, elapsed_s: 0, ...sample(scope, side, state) });
    if (phaseName === "series") {
      await side.add(scope, state, 1);
      loads.push(startLoad(side, phaseName, side.base(state, 1), out, 1));
      for (let elapsed = SAMPLE_S; elapsed <= SERIES_S; elapsed += SAMPLE_S) {
        await Bun.sleep(SAMPLE_S * 1000);
        steps.push({ tenants: 1, elapsed_s: elapsed, ...sample(scope, side, state) });
        console.log(`${side.name} series ${elapsed} s: memory ${MiB(steps.at(-1).memory)} MiB, outside ${MiB(steps.at(-1).outside)} MiB`);
      }
    }
    for (let i = 1; phaseName !== "series" && i <= TENANTS; i++) {
      await side.add(scope, state, i);
      const base = side.base(state, i);
      if (phaseName === "idle") serveRequests(side, base, i);
      else loads.push(startLoad(side, phaseName, base, out, i));
      await Bun.sleep(WAIT_S * 1000);
      steps.push({ tenants: i, ...sample(scope, side, state) });
      const [last, before] = [steps.at(-1), steps.at(-2)];
      console.log(`${side.name} ${phaseName} ${i}: memory ${MiB(last.memory)} MiB, outside ${MiB(last.outside)} MiB (+${MiB(last.memory + last.outside - before.memory - before.outside)})`);
    }
  } finally {
    for (const proc of loads) proc.kill("SIGINT");
    await Promise.all(loads.map((proc) => proc.exited));
    await side.stop(scope, state);
    removeScope(scope);
  }
  const loaded = phaseName === "load" ? TENANTS : phaseName === "series" ? 1 : 0;
  return { kind: "phase", side: side.name, phase: phaseName, case: CASE, load1, wait_s: WAIT_S, requests: REQUESTS, rate: RATE, memory_mib: MEMORY_MIB, steps, load: loaded ? loadReports(side, phaseName, out, loaded) : null };
}

// A scenario: `count` tenants start, then all of them take RATE requests per
// second together for SCENARIO_S seconds, read every SAMPLE_S seconds. The
// CPU per request covers the load window, from the first load generator's
// start to the last one's stop.
async function scenario(side, count, out) {
  const load1 = await quiet();
  const name = `scenario${count}`;
  const scope = `${SUBTREE}/scope-${process.pid}-${side.name}-${name}`;
  createScope(scope);
  const log = `${out}/servers.log`;
  appendFileSync(log, `--- ${side.name} ${name}\n`);
  // A side whose configuration fixes its tenants at startup takes the count.
  const state = await side.start(scope, log, count);
  const loads = [];
  const steps = [];
  let cpu_usec = null;
  const stopLoads = async () => {
    for (const proc of loads) proc.kill("SIGINT");
    await Promise.all(loads.map((proc) => proc.exited));
  };
  try {
    await Bun.sleep(WAIT_S * 1000);
    steps.push({ tenants: 0, elapsed_s: 0, ...sample(scope, side, state) });
    for (let i = 1; i <= count; i++) await side.add(scope, state, i);
    const cpuStart = cpuUsec(scope, side, state);
    for (let i = 1; i <= count; i++) loads.push(startLoad(side, name, side.base(state, i), out, i));
    for (let elapsed = SAMPLE_S; elapsed <= SCENARIO_S; elapsed += SAMPLE_S) {
      await Bun.sleep(SAMPLE_S * 1000);
      steps.push({ tenants: count, elapsed_s: elapsed, ...sample(scope, side, state) });
      const last = steps.at(-1);
      console.log(`${side.name} ${name} ${elapsed} s: memory ${MiB(last.memory)} MiB, outside ${MiB(last.outside)} MiB`);
    }
    await stopLoads();
    cpu_usec = cpuUsec(scope, side, state) - cpuStart;
  } finally {
    await stopLoads();
    await side.stop(scope, state);
    removeScope(scope);
  }
  return { kind: "phase", side: side.name, phase: "scenario", tenants: count, case: CASE, load1, wait_s: WAIT_S, rate: RATE, memory_mib: MEMORY_MIB, steps, cpu_usec, load: loadReports(side, name, out, count) };
}

// --- sharing --------------------------------------------------------------------

const ROLLUP_KEYS = ["Rss", "Pss", "Shared_Clean", "Shared_Dirty", "Private_Clean", "Private_Dirty", "Anonymous"];

// The fields of a process's smaps_rollup this phase keeps, in bytes, or null
// when the process is gone.
function rollup(pid) {
  let text;
  try {
    text = readFileSync(`/proc/${pid}/smaps_rollup`, "utf8");
  } catch {
    return null;
  }
  const fields = {};
  for (const key of ROLLUP_KEYS) fields[key] = 1024 * Number(new RegExp(`^${key}:\\s+(\\d+) kB$`, "m").exec(text)?.[1] ?? 0);
  return fields;
}

const procs = (cgroup) => readFileSync(`${cgroup}/cgroup.procs`, "utf8").split("\n").filter(Boolean).map(Number);

// Every cgroup under `directory` that holds a process: one leaf per worker
// under the scope's workers branch.
function leaves(directory) {
  const found = procs(directory).length ? [directory] : [];
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    if (entry.isDirectory()) found.push(...leaves(`${directory}/${entry.name}`));
  }
  return found;
}

// What a process of the scope's main leaf is: Collo's binary picks its role by
// argv[0], so the zygote and the gateway name themselves there.
function role(pid) {
  const argv0 = readFileSync(`/proc/${pid}/cmdline`, "utf8").split("\0")[0];
  const comm = readFileSync(`/proc/${pid}/comm`, "utf8").trim();
  const name = `${argv0} ${comm}`;
  return { argv0, comm, role: name.includes("zygote") ? "zygote" : name.includes("gateway") ? "gateway" : "server" };
}

// One reading: every process of the main leaf with its role and rollup, and
// every worker leaf with its processes' rollups and the leaf's charge.
function readSharing(scope) {
  const main = [];
  for (const pid of procs(`${scope}/main`)) {
    const fields = rollup(pid);
    if (fields) main.push({ pid, ...role(pid), ...fields });
  }
  const workers = leaves(`${scope}/workers`).map((leaf) => {
    const stat = cgroupStat(leaf);
    const processes = procs(leaf).map((pid) => ({ pid, ...rollup(pid) }));
    return { leaf: leaf.slice(scope.length + 1), current: Number(readFileSync(`${leaf}/memory.current`, "utf8")), anon: stat.anon, file: stat.file, kernel: stat.kernel, processes };
  });
  return { main, workers, scope_memory: sample(scope, collo, null).memory, at: Date.now() };
}

// The sharing phase: SHARING_TENANTS tenants on one Collo, read after each has
// served its first request and again after its tenth, WAIT_S seconds after
// the last request of each round, so every worker has gone quiet and run its
// idle collection.
async function sharing(out) {
  const load1 = await quiet();
  const scope = `${SUBTREE}/scope-${process.pid}-collo-sharing`;
  createScope(scope);
  const log = `${out}/servers.log`;
  appendFileSync(log, `--- collo sharing\n`);
  const state = await collo.start(scope, log);
  const readings = [];
  try {
    for (const [round, count] of [[1, 1], [10, 9]]) {
      for (let i = 1; i <= SHARING_TENANTS; i++) serveRequests(collo, collo.base(state, i), i, count);
      await Bun.sleep(WAIT_S * 1000);
      readings.push({ requests: round, ...readSharing(scope) });
      console.log(`collo sharing after ${round} requests: ${readings.at(-1).workers.length} workers`);
    }
  } finally {
    await collo.stop(scope, state);
    removeScope(scope);
  }
  return { kind: "phase", side: "collo", phase: "sharing", case: CASE, load1, wait_s: WAIT_S, tenants: SHARING_TENANTS, readings };
}

// One line per reading: the median worker's rollup and leaf, and the main
// leaf's processes by role.
function sharingTable(record) {
  const lines = [
    "",
    `## collo, sharing, ${record.tenants} tenants`,
    "",
    "Median over the workers of each field; shared is Shared_Clean + Shared_Dirty, private is Private_Clean + Private_Dirty, shared share is shared / Rss; leaf is the worker's cgroup leaf, which the kernel charges. Main-leaf processes by role: Pss (Rss).",
    "",
    "| after requests | workers | Rss | Pss | shared | private | shared share | Private_Dirty | Anonymous | leaf memory.current | leaf anon | leaf kernel | zygote Pss (Rss) | server Pss (Rss) | gateway Pss (Rss) |",
    "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|",
  ];
  for (const reading of record.readings) {
    const workers = reading.workers.map((worker) => {
      const sum = (key) => worker.processes.reduce((total, process) => total + (process[key] ?? 0), 0);
      const fields = Object.fromEntries(ROLLUP_KEYS.map((key) => [key, sum(key)]));
      return { ...fields, shared: fields.Shared_Clean + fields.Shared_Dirty, private: fields.Private_Clean + fields.Private_Dirty, current: worker.current, anon: worker.anon, kernel: worker.kernel };
    });
    const med = (key) => median(workers.map((worker) => worker[key]));
    const byRole = (name) => {
      const list = reading.main.filter((process) => process.role === name);
      return list.length ? `${MiB(list.reduce((total, process) => total + process.Pss, 0))} (${MiB(list.reduce((total, process) => total + process.Rss, 0))})` : "-";
    };
    const shares = workers.map((worker) => worker.shared / worker.Rss);
    lines.push(
      `| ${reading.requests} | ${workers.length} | ${MiB(med("Rss"))} | ${MiB(med("Pss"))} | ${MiB(med("shared"))} | ${MiB(med("private"))} | ${(100 * median(shares)).toFixed(1)}% | ${MiB(med("Private_Dirty"))} | ${MiB(med("Anonymous"))} | ${MiB(med("current"))} | ${MiB(med("anon"))} | ${MiB(med("kernel"))} | ${byRole("zygote")} | ${byRole("server")} | ${byRole("gateway")} |`,
    );
  }
  return lines;
}

// What each tenant's load generator saw: answers by status and errors, the
// rate it reached and its latency percentiles in seconds.
function loadReports(side, phaseName, out, count) {
  const reports = [];
  for (let i = 1; i <= count; i++) {
    try {
      const report = JSON.parse(readFileSync(`${out}/load-${side.name}-${phaseName}-t${i}.json`, "utf8"));
      const answered = Object.values(report.statusCodeDistribution ?? {}).reduce((sum, n) => sum + n, 0);
      reports.push({ tenant: i, statuses: report.statusCodeDistribution, errors: report.errorDistribution, rps: report.summary.requestsPerSec, answered, p50: report.latencyPercentiles?.p50, p99: report.latencyPercentiles?.p99 });
    } catch (error) {
      reports.push({ tenant: i, unreadable: String(error) });
    }
  }
  return reports;
}

// --- summary --------------------------------------------------------------------

const MiB = (bytes) => (bytes / 2 ** 20).toFixed(2);
const median = (values) => {
  const sorted = values.toSorted((a, b) => a - b);
  return (sorted[(sorted.length - 1) >> 1] + sorted[sorted.length >> 1]) / 2;
};
const ms = (seconds) => (seconds * 1000).toFixed(2);
const total = (step) => step.memory + step.outside;

// One line per idle or load phase: the median of what each added tenant
// changed, outside memory included, and the median of the step's total.
function perTenantTable(records) {
  const lines = ["", "## Per added tenant", "", "| side | phase | tenants | median Δ memory MiB | memory with every tenant MiB |", "|---|---|---|---|---|"];
  for (const record of records) {
    const deltas = record.steps.slice(1).map((step, index) => total(step) - total(record.steps[index]));
    lines.push(`| ${record.side} | ${record.phase} | ${deltas.length} | ${MiB(median(deltas))} | ${MiB(total(record.steps.at(-1)))} |`);
  }
  return lines;
}

// One line per scenario: memory over the last minute of load, per tenant,
// against the scope with no tenant; requests, CPU per request and the
// tenants' latency percentiles.
function scenarioTable(records) {
  const lines = [
    "",
    "## Scenarios",
    "",
    `Each count of tenants under ${RATE} requests per second each for ${SCENARIO_S} s, every tenant limited to ${MEMORY_MIB} MiB. memory is the median over the last minute of the scope plus the side's memory outside it; per tenant is that minus step 0, divided by the tenants. CPU is the scope's and the outside processes' over the load window, per answered request. p50 and p99 are each tenant's, median across tenants, and the worst p99.`,
    "",
    "| side | tenants | memory MiB | per tenant MiB | outside MiB | answered | CPU µs/request | p50 ms | p99 ms | worst p99 ms |",
    "|---|---|---|---|---|---|---|---|---|---|",
  ];
  for (const record of records) {
    const lastMinute = record.steps.filter((step) => step.elapsed_s > SCENARIO_S - 60);
    const memory = median(lastMinute.map(total));
    const outside = median(lastMinute.map((step) => step.outside));
    const answered = record.load.reduce((sum, report) => sum + (report.answered ?? 0), 0);
    const p50 = median(record.load.map((report) => report.p50 ?? NaN));
    const p99s = record.load.map((report) => report.p99 ?? NaN);
    lines.push(
      `| ${record.side} | ${record.tenants} | ${MiB(memory)} | ${MiB((memory - total(record.steps[0])) / record.tenants)} | ${MiB(outside)} | ${answered} | ${record.cpu_usec === null || !answered ? "" : (record.cpu_usec / answered).toFixed(1)} | ${ms(p50)} | ${ms(median(p99s))} | ${ms(Math.max(...p99s))} |`,
    );
  }
  return lines;
}

function summarize(records) {
  const lines = ["# Memory per added tenant", ""];
  lines.push(
    `Each tenant is a copy of the \`${CASE}\` case. Idle: a new tenant serves ${REQUESTS} requests and goes quiet; load: a new tenant starts receiving ${RATE} requests per second and keeps receiving them. Each step is read ${WAIT_S} s after its tenant arrives. memory is the runtime's scope, \`memory.current - (file - shmem) - slab_reclaimable\`; outside is the side's memory outside the scope; cgroup is the scope's raw \`memory.current\`; machine is the same sum over the whole machine, MemTotal - MemFree - Buffers - (Cached - Shmem) - SReclaimable. MiB; Δ is the change from the step before. Method: README.md; environment: environment.txt.`,
  );
  const added = records.filter((record) => record.phase === "idle" || record.phase === "load");
  if (added.length) lines.push(...perTenantTable(added));
  const scenarios = records.filter((record) => record.phase === "scenario");
  if (scenarios.length) lines.push(...scenarioTable(scenarios));
  for (const record of records.filter((entry) => entry.phase === "sharing")) lines.push(...sharingTable(record));
  for (const record of records.filter((entry) => entry.phase !== "sharing")) {
    const series = record.phase === "series" || record.phase === "scenario";
    const title = record.phase === "scenario" ? `scenario, ${record.tenants} tenants` : record.phase;
    lines.push("", `## ${record.side}, ${title}`, "", `| ${series ? "seconds" : "tenants"} | memory | outside | Δ memory + outside | cgroup | Δ machine | anon | shmem | kernel | page cache |`, "|---|---|---|---|---|---|---|---|---|---|");
    record.steps.forEach((step, index) => {
      const previous = record.steps[index - 1];
      const stat = step.cgroup_stat;
      lines.push(
        `| ${series ? step.elapsed_s : step.tenants} | ${MiB(step.memory)} | ${MiB(step.outside)} | ${previous ? MiB(total(step) - total(previous)) : ""} | ${MiB(step.cgroup)} | ${previous ? MiB(step.machine - previous.machine) : ""} | ${MiB(stat.anon)} | ${MiB(stat.shmem)} | ${MiB(stat.kernel)} | ${MiB(stat.file - stat.shmem)} |`,
      );
    });
    if (record.load) {
      const failed = record.load.filter((report) => report.unreadable || Object.keys(report.errors ?? {}).length || Object.keys(report.statuses ?? {}).some((status) => Number(status) !== cases[CASE].load.status));
      lines.push("", failed.length ? `Load generators with failures or other statuses: ${failed.map((report) => `t${report.tenant}`).join(", ")}.` : `Every load generator saw only status ${cases[CASE].load.status}.`);
    }
  }
  return lines.join("\n") + "\n";
}

async function measure(out) {
  writeTenants();
  const records = [];
  const record = (entry) => {
    records.push(entry);
    appendFileSync(`${out}/runs.jsonl`, `${JSON.stringify(entry)}\n`);
  };
  for (const phaseName of PHASES) {
    // A scenario runs each count on every side before the next count, so
    // the sides of one count sit close together in time.
    if (phaseName === "scenario") {
      for (const count of SCENARIO_TENANTS) for (const name of SIDES) record(await scenario(sides[name], count, out));
      continue;
    }
    // Collo only, whatever SIDES names.
    if (phaseName === "sharing") {
      record(await sharing(out));
      continue;
    }
    for (const name of SIDES) record(await phase(sides[name], phaseName, out));
  }
  writeFileSync(`${out}/summary.md`, summarize(records));
}

const [command, out] = process.argv.slice(2);
if (command === "measure") await measure(out);
else throw new Error("usage: bun density.js measure <results directory>");
