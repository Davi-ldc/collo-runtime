// Answers with a token drawn once per worker process, so a test can tell
// whether two responses came from the same worker
// (runtime/tests/integration/local_server/workers.zig). `?ms=N` holds the
// request for N milliseconds before it answers, and `?hang=1` holds it until
// its deadline, when the worker answers 504 itself and keeps serving.
let token = "";

export default async function handler(req) {
  if (token === "") token = crypto.randomUUID();
  if (req.query.get("hang") === "1") await new Promise(() => {});
  const ms = Number(req.query.get("ms") ?? "0");
  if (ms > 0) await new Promise((resolve) => setTimeout(resolve, ms));
  return Response.json({ token });
}
