// Bun's node:http2 server with the same response as hello-collo.js, over TLS
// with the certificate and key named by TLS_CERT and TLS_KEY, on
// 127.0.0.1:PORT. Bun.serve negotiates only HTTP/1.1, so this is the Bun
// server that speaks HTTP/2 like Collo.
import fs from "node:fs";
import http2 from "node:http2";

const server = http2.createSecureServer({
  cert: fs.readFileSync(process.env.TLS_CERT),
  key: fs.readFileSync(process.env.TLS_KEY),
});
server.on("stream", (stream) => {
  stream.respond({ ":status": 200, "content-type": "text/plain;charset=utf-8" });
  stream.end("hello\n");
});
server.listen(Number(process.env.PORT ?? 8445), "127.0.0.1", () => {
  console.error(`bun-h2: listening on https://127.0.0.1:${server.address().port}/`);
});
