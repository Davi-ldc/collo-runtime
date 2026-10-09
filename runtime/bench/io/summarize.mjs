// Summarizes a run.sh results directory: for each server, layout and
// concurrency, the median of the repetitions with their minimum and maximum.
// Writes summary.json and summary.md into the results directory.
//
// Usage: node runtime/bench/io/summarize.mjs <results directory>

import fs from "node:fs";
import path from "node:path";

const dir = process.argv[2];
if (!dir) throw new Error("usage: node summarize.mjs <results directory>");

const runs = fs.readdirSync(path.join(dir, "raw")).filter((name) => name.endsWith(".json")).map((name) => {
  const match = /^(.+)-(conn|mux)-c(\d+)-r(\d+)\.json$/.exec(name);
  if (!match) throw new Error(`unexpected file ${name}`);
  const result = JSON.parse(fs.readFileSync(path.join(dir, "raw", name), "utf8"));
  return { server: match[1], layout: match[2], concurrency: Number(match[3]), rep: Number(match[4]), result };
});

const median = (values) => {
  const sorted = values.filter((value) => value !== null && value !== undefined).sort((a, b) => a - b);
  if (sorted.length === 0) return null;
  const mid = sorted.length >> 1;
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
};
const spread = (values) => {
  const present = values.filter((value) => value !== null && value !== undefined);
  return { median: median(present), min: Math.min(...present), max: Math.max(...present), n: present.length };
};

const groups = new Map();
for (const run of runs) {
  const key = `${run.server}|${run.layout}|${run.concurrency}`;
  if (!groups.has(key)) groups.set(key, []);
  groups.get(key).push(run);
}

const serverOrder = { collo: 0, bun: 1, "bun-h2": 2 };
const rows = [...groups.values()].map((group) => {
  const first = group[0];
  const results = group.map((run) => run.result);
  const errors = {};
  for (const result of results) for (const [kind, value] of Object.entries(result.errors)) errors[kind] = (errors[kind] ?? 0) + value;
  return {
    server: first.server, layout: first.layout, concurrency: first.concurrency,
    connections: first.result.connections, streamsPerConnection: first.result.streamsPerConnection,
    protocol: first.result.meta.alpn, tls: `${first.result.meta.tlsVersion} ${first.result.meta.cipher}`,
    certSha256: first.result.meta.certSha256, reps: group.map((run) => run.rep).sort(),
    rps: spread(results.map((r) => r.rps)),
    p50Us: spread(results.map((r) => r.latencyUs?.p50)),
    p99Us: spread(results.map((r) => r.latencyUs?.p99)),
    p999Us: spread(results.map((r) => r.latencyUs?.p999)),
    maxUs: spread(results.map((r) => r.latencyUs?.max)),
    errors,
    refusedPerSecond: spread(results.map((r) => r.errors.rst / r.durationS)),
    serverCores: spread(results.map((r) => r.cpu.serverCores)),
    serverSystemShare: spread(results.map((r) => (r.server?.systemCores === null || !r.cpu.serverCores ? null : r.server.systemCores / r.cpu.serverCores))),
    serverCpuUsPerRequest: spread(results.map((r) => (r.cpu.serverCores === null || r.rps === 0 ? null : (r.cpu.serverCores * 1e6) / r.rps))),
    clientCoresMax: spread(results.map((r) => r.cpu.clientCoresMax)),
    clientCoresTotal: spread(results.map((r) => r.cpu.clientCoresTotal)),
    otherCores: spread(results.map((r) => r.cpu.otherCores)),
    serverMemoryMiBAtEnd: spread(results.map((r) => (r.server?.memoryBytesAtEnd ?? null) === null ? null : r.server.memoryBytesAtEnd / 1048576)),
    colloWorkersAtEnd: first.server === "collo" ? spread(results.map((r) => r.server?.colloWorkersAtEnd)) : null,
    colloWorkerEndingsInWindow: first.server === "collo" ? results.map((r) => r.server?.logMatchesInWindow) : null,
  };
}).sort((a, b) => (a.layout === b.layout ? 0 : a.layout === "conn" ? -1 : 1) || a.concurrency - b.concurrency || serverOrder[a.server] - serverOrder[b.server]);

const lanes = {};
const exits = {};
for (const name of fs.readdirSync(path.join(dir, "logs"))) {
  const file = path.join(dir, "logs", name);
  if (name.endsWith(".exit")) exits[name.replace(/\.exit$/, "")] = Number(fs.readFileSync(file, "utf8").trim());
  if (name.startsWith("collo-") && name.endsWith(".log")) {
    const match = /lane_count=(\d+) lane_cpus=(\{[^}]*\})/.exec(fs.readFileSync(file, "utf8"));
    if (match) lanes[name.replace(/\.log$/, "")] = { laneCount: Number(match[1]), laneCpus: match[2] };
  }
}

fs.writeFileSync(path.join(dir, "summary.json"), `${JSON.stringify({ rows, colloLanes: lanes, serverExitStatus: exits }, null, 2)}\n`);

const fmt = (value, digits = 0) => (value === null || value === undefined ? "n/a" : value.toLocaleString("en-US", { maximumFractionDigits: digits, minimumFractionDigits: digits }));
const ms = (us) => (us === null || us === undefined ? "n/a" : (us / 1000).toFixed(us < 10000 ? 2 : 0));
const cell = (s, f) => `${f(s.median)} [${f(s.min)}, ${f(s.max)}]`;
const label = { collo: "Collo", bun: "Bun.serve", "bun-h2": "Bun node:http2" };
const protocolName = (row) => (row.protocol === "h2" ? "HTTP/2" : "HTTP/1.1");
const tables = [];
for (const layout of ["conn", "mux"]) {
  const layoutRows = rows.filter((row) => row.layout === layout);
  if (layoutRows.length === 0) continue;
  const lines = [
    layout === "conn"
      ? "One request in flight per connection (connections = concurrency):"
      : "Multiplexed HTTP/2 (streams spread over ceil(concurrency / 64) connections):",
    "",
    "| Concurrency | Server | Protocol | Requests/s | p50 ms | p99 ms | Server cores | Server CPU µs/request | Refused streams/s |",
    "| ---: | --- | --- | --- | --- | --- | --- | ---: | ---: |",
  ];
  for (const row of layoutRows) {
    const concurrency = layout === "conn" ? `${row.concurrency}` : `${row.concurrency} (${row.connections}×${row.streamsPerConnection})`;
    lines.push(`| ${concurrency} | ${label[row.server]} | ${protocolName(row)} | ${cell(row.rps, (v) => fmt(v))} | ${cell(row.p50Us, ms)} | ${cell(row.p99Us, ms)} | ${cell(row.serverCores, (v) => fmt(v, 2))} | ${fmt(row.serverCpuUsPerRequest.median)} | ${fmt(row.refusedPerSecond.median)} |`);
  }
  tables.push(lines.join("\n"));
}
const text = `${tables.join("\n\n")}\n`;
fs.writeFileSync(path.join(dir, "summary.md"), text);
process.stdout.write(text);
