// Collo-only.

bench("abort-controller.construct-read-signal", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const controller = new AbortController();
    checksum += controller.signal.aborted ? 1 : 0;
    checksum += controller.signal.reason === undefined ? 1 : 0;
  }
  return checksum;
}, { iterations: 100000, warmup: 5000 });

bench("abort-controller.abort-listener", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const controller = new AbortController();
    controller.signal.addEventListener("abort", event => {
      checksum += event.type.length;
    });
    controller.abort();
  }
  return checksum;
}, { iterations: 50000, warmup: 2000 });

bench("abort-signal.static-abort", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const signal = AbortSignal.abort(i);
    checksum += signal.aborted ? 1 : 0;
    checksum += signal.reason;
  }
  return checksum;
}, { iterations: 100000, warmup: 5000 });

bench("abort-signal.listener-option-cleanup", iterations => {
  const target = new EventTarget();
  let checksum = 0;
  function listener() {
    checksum++;
  }
  for (let i = 0; i < iterations; i++) {
    const controller = new AbortController();
    target.addEventListener("tick", listener, { signal: controller.signal });
    controller.abort();
  }
  target.dispatchEvent(new Event("tick"));
  return checksum;
}, { iterations: 50000, warmup: 2000 });

bench("abort-signal.any-follow", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const a = new AbortController();
    const b = new AbortController();
    const signal = AbortSignal.any([a.signal, b.signal]);
    signal.addEventListener("abort", () => { checksum++; });
    b.abort();
    checksum += signal.aborted ? 1 : 0;
  }
  return checksum;
}, { iterations: 30000, warmup: 1000 });
