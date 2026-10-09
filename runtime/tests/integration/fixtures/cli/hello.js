// The handler `zig build smoke` serves through `collo serve`, driven by
// runtime/tests/support/serve_smoke.zig, which holds the exact body it
// expects. Echoing the method and the whole URL shows the request reached
// JavaScript with the authority the client sent.
export default function handle(request) {
  return new Response(`hello from ${request.method} ${request.url}\n`, {
    headers: { "content-type": "text/plain" },
  });
}
