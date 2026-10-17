// Prints summary.md for one results directory: per case, a row per runtime
// with the median [min, max] of its valid runs, then the connection sweep.
//
//   bun summarize.js <results directory>
import { readFileSync } from "node:fs";

const dir = process.argv[2];
const records = readFileSync(`${dir}/runs.jsonl`, "utf8").trim().split("\n").map((line) => JSON.parse(line));
const unique = (values) => [...new Set(values)];
const MiB = (bytes) => bytes / 2 ** 20;

function spread(values, digits) {
  const sorted = values.toSorted((a, b) => a - b);
  const median = (sorted[(sorted.length - 1) >> 1] + sorted[sorted.length >> 1]) / 2;
  const format = (value) => value.toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits });
  return `${format(median)} [${format(sorted[0])}, ${format(sorted.at(-1))}]`;
}

const lines = ["# Collo, workerd and Bun", ""];
const { settings } = records.find((record) => record.kind === "run");
lines.push(
  `Server CPU ${settings.server_cpu}, client CPUs ${settings.client_cpu}; warm-up ${settings.warmup} s, load window ${settings.window} s, idle ${settings.idle} s. ` +
    "Memory is the runtime's cgroup scope (`memory.current`): base 1 s after its first answer, its peak in the load window, idle after the idle wait; medians [min, max] over valid runs, except the slowest request, over every run. Environment: environment.txt.",
);

for (const name of unique(records.map((record) => record.case))) {
  const runs = records.filter((record) => record.kind === "run" && record.case === name);
  const sweep = records.filter((record) => record.kind === "sweep" && record.case === name);
  const connections = runs[0].connections;
  lines.push("", `## ${name}, ${connections} connections`, "");
  lines.push("| runtime | valid runs | req/s | CPU µs/request | slowest ms, all runs | base MiB | load peak MiB | idle MiB |", "|---|---|---|---|---|---|---|---|");
  const notes = [];
  for (const runtime of unique(runs.map((run) => run.runtime))) {
    const all = runs.filter((run) => run.runtime === runtime);
    const valid = all.filter((run) => run.load.valid);
    for (const run of all) {
      if (!run.load.valid) notes.push(`- ${runtime} rep ${run.rep} is invalid: ${run.load.responses} expected answers, then ${JSON.stringify(run.load.failures)}`);
      if (run.load.client_bound) notes.push(`- ${runtime} rep ${run.rep} is client-bound: oha used at least 95% of the client CPUs`);
    }
    const column = (value, digits) => (valid.length ? spread(valid.map(value), digits) : "-");
    lines.push(
      `| ${runtime} | ${valid.length}/${all.length} | ${column((run) => run.load.rps, 0)} | ${column((run) => run.load.cpu_us_per_request, 1)} | ` +
        `${spread(all.map((run) => 1000 * run.load.oha.summary.slowest), 0)} | ` +
        `${column((run) => MiB(run.base.current), 1)} | ${column((run) => MiB(run.load.peak), 1)} | ${column((run) => MiB(run.idle.current), 1)} |`,
    );
  }
  if (notes.length) lines.push("", ...notes);

  if (sweep.length === 0) {
    lines.push("", "No sweep: CONNECTIONS was set.");
    continue;
  }
  const runtimes = unique(sweep.map((point) => point.runtime));
  lines.push("", "Sweep, req/s over 3 s per point:", "", `| connections | ${runtimes.join(" | ")} |`, `|---|${"---|".repeat(runtimes.length)}`);
  for (const count of unique(sweep.map((point) => point.connections))) {
    const cells = runtimes.map((runtime) => {
      const point = sweep.find((p) => p.runtime === runtime && p.connections === count);
      return `${Math.round(point.rps).toLocaleString("en-US")}${point.valid ? "" : " (invalid)"}${point.client_bound ? " (client-bound)" : ""}`;
    });
    lines.push(`| ${count}${count === connections ? " (chosen)" : ""} | ${cells.join(" | ")} |`);
  }
}

console.log(lines.join("\n"));
