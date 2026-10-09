// Collo-only.

bench("fetch.invalid-url-validation", async iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    try {
      await fetch("");
    } catch (_) {
      checksum++;
    }
  }
  return checksum;
}, {
  iterations: 20000,
  warmup: 1000,
});
