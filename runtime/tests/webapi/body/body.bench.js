// Collo-only.

bench("body.response-text", async iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const response = new Response("hello world");
    checksum += (await response.text()).length;
  }
  return checksum;
}, { iterations: 20000, warmup: 1000 });

bench("body.response-json", async iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const response = new Response("{\"value\":42}");
    checksum += (await response.json()).value;
  }
  return checksum;
}, { iterations: 15000, warmup: 1000 });

bench("body.response-array-buffer", async iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const response = new Response("hello world");
    checksum += (await response.arrayBuffer()).byteLength;
  }
  return checksum;
}, { iterations: 20000, warmup: 1000 });

bench("body.response-bytes", async iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const response = new Response("hello world");
    checksum += (await response.bytes()).byteLength;
  }
  return checksum;
}, { iterations: 20000, warmup: 1000 });

bench("body.response-uint8array-bodyinit", async iterations => {
  const payload = new Uint8Array([0, 1, 2, 3, 4, 5, 254, 255]);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const response = new Response(payload);
    checksum += (await response.bytes())[i & 7];
  }
  return checksum;
}, { iterations: 20000, warmup: 1000 });

bench("body.response-blob-bodyinit", async iterations => {
  const blob = new Blob(["hello world"], { type: "text/plain" });
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const response = new Response(blob);
    checksum += (await response.text()).length + (response.headers.get("content-type") || "").length;
  }
  return checksum;
}, { iterations: 15000, warmup: 1000 });

bench("body.response-blob", async iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const response = new Response("hello world", { headers: { "content-type": "text/plain" } });
    const blob = await response.blob();
    checksum += blob.size + blob.type.length;
  }
  return checksum;
}, { iterations: 15000, warmup: 1000 });

bench("body.response-form-data-urlencoded", async iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const response = new Response("hello=world&n=" + (i & 15), {
      headers: { "content-type": "application/x-www-form-urlencoded" },
    });
    const form = await response.formData();
    checksum += form.get("hello").length + form.get("n").length;
  }
  return checksum;
}, { iterations: 15000, warmup: 1000 });

bench("body.response-form-data-multipart", async iterations => {
  const body = [
    "--abc123",
    'Content-Disposition: form-data; name="field"',
    "",
    "value",
    "--abc123--",
    "",
  ].join("\r\n");
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const response = new Response(body, {
      headers: { "content-type": "multipart/form-data; boundary=abc123" },
    });
    checksum += (await response.formData()).get("field").length;
  }
  return checksum;
}, { iterations: 10000, warmup: 1000 });
