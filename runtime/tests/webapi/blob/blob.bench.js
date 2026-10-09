// Collo-only.

bench("blob.construct-string", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += new Blob(["hello", " ", "world"]).size;
  return checksum;
}, { iterations: 100000, warmup: 5000 });

bench("blob.construct-typed-array", iterations => {
  const bytes = new Uint8Array(256);
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += new Blob([bytes, bytes]).size;
  return checksum;
}, { iterations: 100000, warmup: 5000 });

bench("blob.slice-no-copy", iterations => {
  const blob = new Blob(["0123456789".repeat(128)]);
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += blob.slice(4, 512, "Text/Plain").size;
  return checksum;
}, { iterations: 200000, warmup: 10000 });

bench("blob.text-small", async iterations => {
  const blob = new Blob(["hello world ".repeat(16)]);
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += (await blob.text()).length;
  return checksum;
}, { iterations: 20000, warmup: 1000 });

bench("blob.array-buffer-small", async iterations => {
  const blob = new Blob([new Uint8Array(512)]);
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += (await blob.arrayBuffer()).byteLength;
  return checksum;
}, { iterations: 20000, warmup: 1000 });

bench("blob.bytes-small", async iterations => {
  const blob = new Blob([new Uint8Array(512)]);
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += (await blob.bytes()).byteLength;
  return checksum;
}, { iterations: 20000, warmup: 1000 });

bench("blob.form-data-urlencoded", async iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const form = await new Blob(["hello=world&n=", String(i & 15)], {
      type: "application/x-www-form-urlencoded",
    }).formData();
    checksum += form.get("hello").length + form.get("n").length;
  }
  return checksum;
}, { iterations: 20000, warmup: 1000 });
