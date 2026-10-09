// Collo-only.

bench("performance.now-hot-loop", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += performance.now() >= 0;
  return checksum;
}, { iterations: 200000, warmup: 10000 });

bench("performance.time-origin-read", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += performance.timeOrigin > 0;
  return checksum;
}, { iterations: 200000, warmup: 10000 });

bench("performance.to-json", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += performance.toJSON().timeOrigin > 0;
  return checksum;
}, { iterations: 100000, warmup: 5000 });

bench("performance.timing-read", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++)
    checksum += performance.timing.responseEnd;
  return checksum;
}, { iterations: 100000, warmup: 5000 });

bench("performance.event-target-dispatch", iterations => {
  let checksum = 0;
  const event = new Event("bench-performance");
  function listener() {
    checksum++;
  }
  performance.addEventListener("bench-performance", listener);
  for (let i = 0; i < iterations; i++)
    performance.dispatchEvent(event);
  performance.removeEventListener("bench-performance", listener);
  return checksum;
}, { iterations: 50000, warmup: 1000 });

bench("performance.mark-clear", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const mark = performance.mark("bench-mark", { startTime: i & 1023 });
    checksum += mark.startTime;
    performance.clearMarks("bench-mark");
  }
  return checksum;
}, { iterations: 50000, warmup: 2000 });

bench("performance.measure-by-marks", iterations => {
  let checksum = 0;
  performance.clearMarks();
  performance.clearMeasures();
  performance.mark("bench-start", { startTime: 1 });
  performance.mark("bench-end", { startTime: 9 });
  for (let i = 0; i < iterations; i++) {
    const measure = performance.measure("bench-measure", "bench-start", "bench-end");
    checksum += measure.duration;
    performance.clearMeasures("bench-measure");
  }
  performance.clearMarks();
  return checksum;
}, { iterations: 50000, warmup: 2000 });

bench("performance.entries-query", iterations => {
  let checksum = 0;
  performance.clearMarks();
  performance.clearMeasures();
  for (let i = 0; i < 16; i++)
    performance.mark(`entry-${i}`, { startTime: i });
  for (let i = 0; i < iterations; i++) {
    checksum += performance.getEntries().length;
    checksum += performance.getEntriesByType("mark").length;
    checksum += performance.getEntriesByName("entry-8").length;
  }
  performance.clearMarks();
  return checksum;
}, { iterations: 20000, warmup: 1000 });

bench("performance.observer-create-observe-disconnect", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const observer = new PerformanceObserver(() => {});
    observer.observe({ entryTypes: ["mark", "measure"] });
    checksum += observer.takeRecords().length;
    observer.disconnect();
  }
  return checksum;
}, { iterations: 20000, warmup: 1000 });

bench("performance.observer-take-records", iterations => {
  let checksum = 0;
  performance.clearMarks();
  const observer = new PerformanceObserver(() => {});
  observer.observe({ type: "mark" });
  for (let i = 0; i < iterations; i++) {
    performance.mark("bench-observer", { startTime: i & 1023 });
    checksum += observer.takeRecords().length;
    performance.clearMarks("bench-observer");
  }
  observer.disconnect();
  return checksum;
}, { iterations: 20000, warmup: 1000 });
