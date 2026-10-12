// The route of a definition without a `network` grant
// (runtime/tests/integration/local_server/network.zig): its module's
// top-level code and its handler each fetch, and both fetches must reject at
// once. The host never resolves, so a fetch that was not refused would fail
// later and differently.
const target = "http://no-grant.example.test/";

async function outcome() {
  try {
    const res = await fetch(target);
    return { status: res.status };
  } catch (error) {
    return { error: error.name, message: String(error.message) };
  }
}

const topLevel = await outcome();

export default async function handler() {
  return Response.json({ top_level: topLevel, request_time: await outcome() });
}
