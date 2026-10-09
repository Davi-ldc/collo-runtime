// Collo-only.

bench("navigator.identity-hot-read", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    checksum += typeof navigator === "object";
    checksum += navigator.userAgent.length > 0;
    checksum += navigator.platform.length > 0;
    checksum += navigator.hardwareConcurrency >= 1;
    checksum += navigator[Symbol.toStringTag] === "Navigator";
  }
  return checksum;
}, { iterations: 200000, warmup: 10000 });

bench("navigator.descriptor-shape", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const desc = Object.getOwnPropertyDescriptor(globalThis, "navigator");
    const tag = Object.getOwnPropertyDescriptor(navigator, Symbol.toStringTag);
    checksum += desc && desc.enumerable === true;
    checksum += desc && desc.configurable === true;
    checksum += tag && tag.value === "Navigator";
    checksum += tag && tag.enumerable === false;
  }
  return checksum;
}, { iterations: 100000, warmup: 5000 });
