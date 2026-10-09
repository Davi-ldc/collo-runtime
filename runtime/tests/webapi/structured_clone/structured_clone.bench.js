// Collo-only.

bench("structured-clone.primitive-string", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += structuredClone("collo").length;
  return checksum;
}, { iterations: 200000, warmup: 10000 });

bench("structured-clone.small-object", iterations => {
  const input = { id: 1, name: "demo", flags: [true, false, null], nested: { value: 42 } };
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += structuredClone(input).nested.value;
  return checksum;
}, { iterations: 50000, warmup: 5000 });

bench("structured-clone.small-array", iterations => {
  const input = [1, 2, 3, "four", { five: 5 }];
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += structuredClone(input)[4].five;
  return checksum;
}, { iterations: 50000, warmup: 5000 });

bench("structured-clone.map-set", iterations => {
  const key = { id: 1 };
  const value = { value: 2 };
  const input = { map: new Map([[key, value]]), set: new Set([key, value]) };
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const cloned = structuredClone(input);
    checksum += cloned.map.size + cloned.set.size;
  }
  return checksum;
}, { iterations: 20000, warmup: 2000 });

bench("structured-clone.array-buffer-copy", iterations => {
  const buffer = new ArrayBuffer(1024);
  new Uint8Array(buffer).fill(7);
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += new Uint8Array(structuredClone(buffer))[0];
  return checksum;
}, { iterations: 50000, warmup: 5000 });

bench("structured-clone.array-buffer-transfer", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const buffer = new ArrayBuffer(16);
    new Uint8Array(buffer)[0] = i & 255;
    const cloned = structuredClone(buffer, { transfer: [buffer] });
    checksum += buffer.byteLength + new Uint8Array(cloned)[0];
  }
  return checksum;
}, { iterations: 20000, warmup: 2000 });

bench("structured-clone.blob", iterations => {
  const blob = new Blob(["hello"], { type: "text/plain" });
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += structuredClone(blob).size;
  return checksum;
}, { iterations: 50000, warmup: 5000 });
