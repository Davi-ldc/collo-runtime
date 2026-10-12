// The route's top-level await rejects 50 ms after its worker evaluated it, so
// every worker of its definition fails its only route soon after it is ready:
// the requests parked on the route get the failed route's 500, the worker asks
// the server to retire it, and a fresh worker takes the next requests
// (runtime/tests/integration/local_server/workers.zig).
await new Promise((_, reject) => setTimeout(() => reject(new Error("boot")), 50));

export default function handler() {
  return new Response("unreachable: the route never evaluates");
}
