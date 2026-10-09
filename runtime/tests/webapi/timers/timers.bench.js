// Collo-only.

bench("timers.set-timeout-chain", async iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    await new Promise(resolve => {
      setTimeout(value => {
        checksum += value;
        resolve();
      }, 0, 1);
    });
  }
  return checksum;
}, { iterations: 1000, warmup: 10 });

bench("timers.create-clear-timeout", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const id = setTimeout(() => {}, 1000000);
    clearTimeout(id);
    checksum++;
  }
  return checksum;
}, { iterations: 50000, warmup: 1000 });
