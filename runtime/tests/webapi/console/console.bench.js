// Collo-only.

const consoleMethods = [
  "assert",
  "clear",
  "debug",
  "dir",
  "dirxml",
  "error",
  "group",
  "groupCollapsed",
  "groupEnd",
  "info",
  "log",
  "table",
  "timeStamp",
  "trace",
  "warn",
];

bench("console.global-shape", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const desc = Object.getOwnPropertyDescriptor(globalThis, "console");
    checksum += typeof console === "object";
    checksum += desc && desc.enumerable === false;
    checksum += Object.prototype.toString.call(console) === "[object console]";
  }
  return checksum;
}, { iterations: 100000, warmup: 5000 });

bench("console.method-shape", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    for (const name of consoleMethods) {
      const method = console[name];
      checksum += typeof method === "function";
      checksum += method.length === 0;
    }
  }
  return checksum;
}, { iterations: 50000, warmup: 2000 });

bench("console.assert-true", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    checksum += console.assert(true) === undefined;
  }
  return checksum;
}, { iterations: 200000, warmup: 10000 });
