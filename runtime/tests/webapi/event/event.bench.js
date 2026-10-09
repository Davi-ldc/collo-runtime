// Collo-only.

bench("event.construct-and-read", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const event = new Event("tick", { cancelable: (i & 1) === 0 });
    checksum += event.type.length;
    checksum += event.cancelable ? 1 : 0;
    checksum += event.isTrusted ? 8 : 0;
    checksum += event.timeStamp >= 0 ? 1 : 0;
  }
  return checksum;
}, { iterations: 100000, warmup: 5000 });

bench("custom-event.construct-and-read", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const event = new CustomEvent("tick", { detail: i, cancelable: (i & 1) === 0 });
    checksum += event.type.length;
    checksum += event.detail & 1;
    checksum += event.cancelable ? 1 : 0;
  }
  return checksum;
}, { iterations: 100000, warmup: 5000 });

bench("message-event.construct-and-read", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const event = new MessageEvent("message", {
      data: i,
      origin: "https://example.test",
      lastEventId: String(i),
    });
    checksum += event.type.length;
    checksum += event.data & 1;
    checksum += event.origin.length;
    checksum += event.lastEventId.length;
    checksum += event.ports.length;
  }
  return checksum;
}, { iterations: 100000, warmup: 5000 });

bench("error-event.construct-and-read", iterations => {
  let checksum = 0;
  const error = new Error("boom");
  for (let i = 0; i < iterations; i++) {
    const event = new ErrorEvent("error", {
      message: "boom",
      filename: "route.js",
      lineno: i,
      colno: i & 255,
      error,
    });
    checksum += event.type.length;
    checksum += event.message.length;
    checksum += event.filename.length;
    checksum += event.lineno & 1;
    checksum += event.colno;
    checksum += event.error === error ? 1 : 0;
  }
  return checksum;
}, { iterations: 100000, warmup: 5000 });

bench("close-event.construct-and-read", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const event = new CloseEvent("close", {
      code: 1000 + (i & 15),
      reason: "done",
      wasClean: (i & 1) === 0,
    });
    checksum += event.type.length;
    checksum += event.code;
    checksum += event.reason.length;
    checksum += event.wasClean ? 1 : 0;
  }
  return checksum;
}, { iterations: 100000, warmup: 5000 });

bench("event-target.dispatch-single-listener", iterations => {
  const target = new EventTarget();
  let checksum = 0;
  target.addEventListener("tick", event => {
    checksum += event.eventPhase;
    checksum += event.currentTarget === target ? 1 : 0;
  });
  for (let i = 0; i < iterations; i++)
    target.dispatchEvent(new Event("tick"));
  return checksum;
}, { iterations: 100000, warmup: 5000 });

bench("event-target.dispatch-many-listeners", iterations => {
  const target = new EventTarget();
  let checksum = 0;
  for (let i = 0; i < 8; i++)
    target.addEventListener("tick", event => { checksum += event.type.length + i; });
  for (let i = 0; i < iterations; i++)
    target.dispatchEvent(new Event("tick"));
  return checksum;
}, { iterations: 50000, warmup: 2000 });

bench("event-target.add-remove", iterations => {
  const target = new EventTarget();
  let checksum = 0;
  function listener() { checksum++; }
  for (let i = 0; i < iterations; i++) {
    target.addEventListener("tick", listener, (i & 1) === 0);
    target.removeEventListener("tick", listener, (i & 1) === 0);
  }
  target.dispatchEvent(new Event("tick"));
  return checksum;
}, { iterations: 100000, warmup: 5000 });

bench("global-event-target.dispatch-handler-listener", iterations => {
  let checksum = 0;
  function listener(event) {
    checksum += event.type.length;
  }
  try {
    globalThis.onerror = event => {
      checksum += event.error === "bench" ? 1 : 0;
    };
    addEventListener("error", listener);
    for (let i = 0; i < iterations; i++)
      dispatchEvent(new ErrorEvent("error", { error: "bench" }));
  } finally {
    globalThis.onerror = null;
    removeEventListener("error", listener);
  }
  return checksum;
}, { iterations: 50000, warmup: 2000 });
