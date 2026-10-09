// Collo-only.

bench("response.construct-text", async iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const response = new Response("hello", {
      status: 202,
      headers: { "content-type": "text/plain" },
    });
    checksum += response.status;
    checksum += response.redirected === false;
    checksum += response.headers.get("content-type").length;
  }
  return checksum;
}, { iterations: 80000, warmup: 5000 });

bench("response.json-helper", async iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const response = Response.json({ ok: true, value: i & 15 });
    checksum += response.status;
    checksum += response.headers.get("content-type").length;
  }
  return checksum;
}, { iterations: 70000, warmup: 5000 });

bench("response.clone-text", async iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const response = new Response("hello", {
      status: 201,
      headers: { "content-type": "text/plain" },
    });
    const clone = response.clone();
    checksum += clone.status;
    checksum += clone.headers.get("content-type").length;
  }
  return checksum;
}, { iterations: 60000, warmup: 5000 });

bench("response.error", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const response = Response.error();
    checksum += response.status;
    checksum += response.type.length;
    checksum += response.redirected === false;
    checksum += response.ok === false;
  }
  return checksum;
}, { iterations: 100000, warmup: 5000 });
