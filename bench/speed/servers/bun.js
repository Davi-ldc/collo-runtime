// Serves a case bundle with Bun.serve, over HTTP/2 only and TLS, calling the
// default export's fetch as workerd and Collo do.
//
//   bun servers/bun.js <bundle> <port>
const [bundle, port] = process.argv.slice(2);
const app = (await import(bundle)).default;
const pem = (name) => Bun.file(new URL(`../dist/${name}`, import.meta.url));

Bun.serve({
  hostname: "127.0.0.1",
  port: Number(port),
  http2: true,
  http1: false,
  tls: { cert: pem("cert.pem"), key: pem("key.pem") },
  development: false,
  fetch: (request) => app.fetch(request),
});
