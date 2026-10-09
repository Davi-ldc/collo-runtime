// Collo-only.

bench("text-encoder.encode-ascii", iterations => {
  const encoder = new TextEncoder();
  const text = "hello world ".repeat(8);
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += encoder.encode(text).length;
  return checksum;
}, { iterations: 120000, warmup: 8000 });

bench("text-encoder.encode-unicode", iterations => {
  const encoder = new TextEncoder();
  const text = "H©世😀 ".repeat(12);
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += encoder.encode(text).length;
  return checksum;
}, { iterations: 80000, warmup: 5000 });

bench("text-encoder.encode-into", iterations => {
  const encoder = new TextEncoder();
  const text = "A©😀 ".repeat(16);
  const destination = new Uint8Array(512);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const result = encoder.encodeInto(text, destination);
    checksum += result.read + result.written + destination[0];
  }
  return checksum;
}, { iterations: 100000, warmup: 8000 });

bench("text-encoder.encode-into-ascii", iterations => {
  const encoder = new TextEncoder();
  const text = "hello world ".repeat(8);
  const destination = new Uint8Array(128);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const result = encoder.encodeInto(text, destination);
    checksum += result.read + result.written + destination[0];
  }
  return checksum;
}, { iterations: 120000, warmup: 8000 });

bench("text-decoder.decode-ascii", iterations => {
  const decoder = new TextDecoder();
  const bytes = new TextEncoder().encode("hello world ".repeat(12));
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += decoder.decode(bytes).length;
  return checksum;
}, { iterations: 120000, warmup: 8000 });

bench("text-decoder.decode-unicode", iterations => {
  const decoder = new TextDecoder();
  const bytes = new TextEncoder().encode("H©世😀 ".repeat(12));
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += decoder.decode(bytes).length;
  return checksum;
}, { iterations: 80000, warmup: 5000 });

bench("text-decoder.decode-streaming", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const decoder = new TextDecoder();
    checksum += decoder.decode(new Uint8Array([0xe2]), { stream: true }).length;
    checksum += decoder.decode(new Uint8Array([0x82, 0xac])).length;
  }
  return checksum;
}, { iterations: 60000, warmup: 5000 });

bench("text-decoder.decode-windows-1252", iterations => {
  const decoder = new TextDecoder("windows-1252");
  const bytes = new Uint8Array([72, 101, 108, 108, 111, 32, 0x80, 32, 0x93, 113, 117, 111, 116, 101, 0x94]);
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += decoder.decode(bytes).length;
  return checksum;
}, { iterations: 100000, warmup: 8000 });

bench("text-decoder.decode-utf16le", iterations => {
  const decoder = new TextDecoder("utf-16le");
  const bytes = new Uint8Array([0x48, 0x00, 0x65, 0x00, 0x6c, 0x00, 0x6c, 0x00, 0x6f, 0x00, 0x20, 0x00, 0x16, 0x4e, 0x4c, 0x75]);
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += decoder.decode(bytes).length;
  return checksum;
}, { iterations: 100000, warmup: 8000 });

bench("text-decoder.decode-shift-jis", iterations => {
  const decoder = new TextDecoder("shift_jis");
  const bytes = new Uint8Array([0x82, 0xb1, 0x82, 0xf1, 0x82, 0xc9, 0x82, 0xbf, 0x82, 0xcd]);
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += decoder.decode(bytes).length;
  return checksum;
}, { iterations: 80000, warmup: 5000 });
