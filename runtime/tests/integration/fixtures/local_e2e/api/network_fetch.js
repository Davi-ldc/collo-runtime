// Fetches the URL in `?url=` and answers with how the fetch ended: the
// status and body text, or the error's name and message
// (runtime/tests/integration/local_server/network.zig). `?timeout=N` bounds
// the fetch with AbortSignal.timeout(N).
export default async function handler(req) {
  const url = req.query.get("url");
  const timeout = Number(req.query.get("timeout") ?? "0");
  const init = timeout > 0 ? { signal: AbortSignal.timeout(timeout) } : {};
  try {
    const res = await fetch(url, init);
    return Response.json({ status: res.status, text: await res.text() });
  } catch (error) {
    return Response.json({ error: error.name, message: String(error.message) });
  }
}
