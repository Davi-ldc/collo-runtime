// Answers with a token drawn once per worker process and the MiB it keeps.
// With `?grow=1` it first keeps 1 MiB Uint8Arrays, each filled so the kernel
// charges every page of it to the worker's cgroup leaf, until the worker
// dies of its memory limit (runtime/tests/integration/local_server/limits.zig).
// Kept arrays cannot be collected, so no collection delays the death. The
// bound only ends a worker that no limit stops, which the test then fails.
let token = "";
const kept = [];
const growMiBMax = 256;

export default function handler(req) {
  if (token === "") token = crypto.randomUUID();
  if (req.query.get("grow") === "1") {
    for (let mib = 0; mib < growMiBMax; mib++) {
      const chunk = new Uint8Array(1 << 20);
      chunk.fill(1);
      kept.push(chunk);
    }
  }
  return Response.json({ token, keptMiB: kept.length });
}
