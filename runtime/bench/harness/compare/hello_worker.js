// Hello-world tenant for workerd: one isolate per service.
export default {
  fetch(request) {
    const url = new URL(request.url);
    return new Response(`hello from workerd: ${request.method} ${url.pathname}\n`, {
      headers: { "content-type": "text/plain" },
    });
  },
};
