// The entry of both routes of each realm worker in collo.json: counts the
// requests its module instance served and the requests its global object
// saw, and reports them with the route's own binding and whether the request
// is a `Request` of the handler's realm
// (runtime/tests/integration/local_server/e2e.zig). With a realm per route
// both counts are per route; with one shared realm both routes count
// together.
let hits = 0;

export default function handler(req, env) {
  hits += 1;
  globalThis.__requests = (globalThis.__requests ?? 0) + 1;
  return Response.json({
    route: env.ROUTE,
    hits,
    requests: globalThis.__requests,
    request: req instanceof Request
  });
}
