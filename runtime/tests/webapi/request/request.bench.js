// Collo-only.

bench("request.prototype-shape", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    checksum += !!Object.getOwnPropertyDescriptor(Request.prototype, "method");
    checksum += !!Object.getOwnPropertyDescriptor(Request.prototype, "headers");
    checksum += !!Object.getOwnPropertyDescriptor(Request.prototype, "text");
    checksum += !!Object.getOwnPropertyDescriptor(Request.prototype, "json");
    checksum += !!Object.getOwnPropertyDescriptor(Request.prototype, "arrayBuffer");
    checksum += !!Object.getOwnPropertyDescriptor(Request.prototype, "bytes");
    checksum += !!Object.getOwnPropertyDescriptor(Request.prototype, "blob");
    checksum += !!Object.getOwnPropertyDescriptor(Request.prototype, "formData");
  }
  return checksum;
}, { iterations: 200000, warmup: 10000 });

bench("request.current-accessors", (iterations, context) => {
  const request = context.request || new Request("https://demo.test/path?q=1", {
    headers: { host: "demo.test" },
  });

  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    checksum += request.method.length;
    checksum += request.url.length;
    checksum += request.headers.has("host");
  }
  return checksum;
}, {
  iterations: 200000,
  warmup: 10000,
});

bench("request.construct-url-headers", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const request = new Request("https://example.com/path?q=" + (i & 15), {
      method: "post",
      headers: {
        host: "tenant.example",
        "x-test": "yes",
      },
    });
    checksum += request.method.length + request.url.length + request.headers.get("x-test").length;
  }
  return checksum;
}, { iterations: 50000, warmup: 5000 });

bench("request.construct-standard-options", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const request = new Request("https://example.com/options?q=" + (i & 7), {
      mode: "same-origin",
      cache: "only-if-cached",
      redirect: "manual",
    });
    checksum += request.mode.length + request.cache.length + request.redirect.length;
  }
  return checksum;
}, { iterations: 50000, warmup: 5000 });

bench("request.construct-text-body", async iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const request = new Request("https://example.com/body", {
      method: "POST",
      body: "hello " + (i & 15),
    });
    checksum += (await request.text()).length;
  }
  return checksum;
}, { iterations: 20000, warmup: 1000 });

bench("request.clone-text-body", async iterations => {
  const original = new Request("https://example.com/clone", {
    method: "POST",
    headers: { "x-test": "yes" },
    body: "clone body",
  });
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const clone = original.clone();
    checksum += clone.headers.get("x-test").length + (await clone.text()).length;
  }
  return checksum;
}, { iterations: 15000, warmup: 1000 });

bench("request.reject-get-head-body", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    try {
      new Request("https://example.com/body", { method: i & 1 ? "GET" : "HEAD", body: "x" });
    } catch (error) {
      checksum += error instanceof TypeError;
    }
  }
  return checksum;
}, { iterations: 10000, warmup: 1000 });
