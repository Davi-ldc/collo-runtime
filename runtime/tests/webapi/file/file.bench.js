// Collo-only.

bench("file.construct-string", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const file = new File(["hello", " ", "world"], "demo.txt", { type: "Text/Plain", lastModified: 1 });
    checksum += file.size + file.name.length + file.type.length + file.lastModified;
  }
  return checksum;
}, { iterations: 100000, warmup: 5000 });

bench("file.construct-typed-array", iterations => {
  const bytes = new Uint8Array(256);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const file = new File([bytes, bytes], "bytes.bin");
    checksum += file.size + file.name.length;
  }
  return checksum;
}, { iterations: 100000, warmup: 5000 });

bench("file.accessors", iterations => {
  const file = new File(["abc"], "demo.txt", { type: "text/plain", lastModified: 123 });
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += file.size + file.name.length + file.type.length + file.lastModified;
  return checksum;
}, { iterations: 500000, warmup: 10000 });

bench("file.blob-method-text", async iterations => {
  const file = new File(["hello world ".repeat(16)], "text.txt");
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += (await file.text()).length;
  return checksum;
}, { iterations: 20000, warmup: 1000 });

bench("file.slice-no-copy", iterations => {
  const file = new File(["0123456789".repeat(128)], "data.txt");
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += file.slice(4, 512, "Text/Plain").size;
  return checksum;
}, { iterations: 200000, warmup: 10000 });
