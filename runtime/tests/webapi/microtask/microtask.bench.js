// Collo-only.

bench("microtask.queue-and-drain", async iterations => {
  let checksum = 0;
  await new Promise(resolve => {
    let remaining = iterations;
    for (let i = 0; i < iterations; i++) {
      queueMicrotask(() => {
        checksum++;
        if (--remaining === 0)
          resolve();
      });
    }
  });
  return checksum;
}, { iterations: 20000, warmup: 1000 });

bench("microtask.nested-chain", async iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    await new Promise(resolve => {
      queueMicrotask(() => {
        checksum++;
        queueMicrotask(resolve);
      });
    });
  }
  return checksum;
}, { iterations: 5000, warmup: 100 });
