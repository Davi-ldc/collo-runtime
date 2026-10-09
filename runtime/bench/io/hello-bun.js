// Bun.serve with the same handler body as hello-collo.js, over TLS with the
// certificate and key named by TLS_CERT and TLS_KEY, on 127.0.0.1:PORT.
const server = Bun.serve({
  hostname: "127.0.0.1",
  port: Number(process.env.PORT ?? 8444),
  tls: { cert: Bun.file(process.env.TLS_CERT), key: Bun.file(process.env.TLS_KEY) },
  fetch: () => new Response("hello\n"),
});
console.error(`bun: listening on ${server.url}`);
