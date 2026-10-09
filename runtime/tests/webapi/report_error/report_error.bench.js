// Collo-only.

bench("report-error.global-shape", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const fn = globalThis.reportError;
    const desc = Object.getOwnPropertyDescriptor(globalThis, "reportError");
    checksum += typeof fn === "function";
    checksum += fn.length === 1;
    checksum += fn.name === "reportError";
    checksum += !!desc;
    checksum += desc && desc.writable === true;
    checksum += desc && desc.configurable === true;
  }
  return checksum;
}, { iterations: 200000, warmup: 10000 });
