// Hello-world tenant for the Bun comparators: one HTTP server per instance.
const port = Number(process.env.PORT ?? 3000);
Bun.serve({
  port,
  fetch(request) {
    const url = new URL(request.url);
    return new Response(`hello from bun: ${request.method} ${url.pathname}\n`, {
      headers: { "content-type": "text/plain" },
    });
  },
});
