// Runs synchronous JavaScript for `?spin_ms=N` milliseconds (none by
// default) before it reads the request body, so an upload meets a worker that
// is not reading its control socket, then answers with the body's length and
// a token drawn once per worker process
// (runtime/tests/integration/local_server/workers.zig).
let token = "";

export default async function handler(req) {
  if (token === "") token = crypto.randomUUID();
  const until = Date.now() + Number(req.query.get("spin_ms") ?? "0");
  while (Date.now() < until) {}
  const body = await req.arrayBuffer();
  return Response.json({ length: body.byteLength, token });
}
