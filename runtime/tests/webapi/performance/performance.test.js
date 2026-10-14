// Collo compatibility contract derived from Bun v1.3.14:
// - reference/bun-v1.3.14/test/js/web/timers/performance.test.js
// - reference/bun-v1.3.14/test/js/web/timers/performance-entries.test.ts
// - reference/bun-v1.3.14/test/js/web/web-globals.test.js

test("Performance globals and descriptors", () => {
  assert.equal(typeof performance, "object");
  assert.equal(typeof Performance, "function");
  assert(performance instanceof Performance);
  assert.equal(Object.prototype.toString.call(performance), "[object Performance]");

  assert.equal(Performance.length, 0);
  assert.throws(() => Performance(), TypeError);
  assert.throws(() => new Performance(), TypeError);

  const performanceDescriptor = Object.getOwnPropertyDescriptor(globalThis, "performance");
  assert.equal(performanceDescriptor.enumerable, false);
  assert.equal(performanceDescriptor.configurable, true);
  assert.equal(performanceDescriptor.writable, false);

  const constructorDescriptor = Object.getOwnPropertyDescriptor(globalThis, "Performance");
  assert.equal(constructorDescriptor.enumerable, false);
  assert.equal(constructorDescriptor.configurable, true);
  assert.equal(constructorDescriptor.writable, true);

  const proto = Performance.prototype;
  assert.equal(Object.getPrototypeOf(proto), Object.prototype);
  assert.equal(proto.constructor, Performance);
  assert.equal(proto[Symbol.toStringTag], "Performance");

  const nowDescriptor = Object.getOwnPropertyDescriptor(proto, "now");
  assert.equal(typeof nowDescriptor.value, "function");
  assert.equal(nowDescriptor.value.length, 0);
  assert.equal(nowDescriptor.enumerable, true);

  const originDescriptor = Object.getOwnPropertyDescriptor(proto, "timeOrigin");
  assert.equal(typeof originDescriptor.get, "function");
  assert.equal(originDescriptor.set, undefined);
  assert.equal(originDescriptor.enumerable, true);

  const jsonDescriptor = Object.getOwnPropertyDescriptor(proto, "toJSON");
  assert.equal(typeof jsonDescriptor.value, "function");
  assert.equal(jsonDescriptor.value.length, 0);
  assert.equal(jsonDescriptor.enumerable, true);

  for (const [key, length] of [
    ["mark", 1],
    ["measure", 1],
    ["getEntries", 0],
    ["getEntriesByName", 1],
    ["getEntriesByType", 1],
    ["clearMarks", 0],
    ["clearMeasures", 0],
  ]) {
    const descriptor = Object.getOwnPropertyDescriptor(proto, key);
    assert.equal(typeof descriptor.value, "function", `${key} is a function`);
    assert.equal(descriptor.value.length, length, `${key}.length`);
    assert.equal(descriptor.enumerable, true, `${key} enumerable`);
  }
});

// The timeline records User Timing only: no resource timing, no legacy performance.timing, and `performance` is not
// an EventTarget, since nothing ever fires an event at it.
test("Performance has neither resource timing, nor performance.timing, nor EventTarget members", () => {
  assert.deepEqual(Object.getOwnPropertyNames(Performance.prototype).sort(), [
    "clearMarks",
    "clearMeasures",
    "constructor",
    "getEntries",
    "getEntriesByName",
    "getEntriesByType",
    "mark",
    "measure",
    "now",
    "timeOrigin",
    "toJSON",
  ]);
  assert.equal("PerformanceTiming" in globalThis, false);
  assert.equal(performance.timing, undefined);
  assert.equal(performance instanceof EventTarget, false);
  for (const key of [
    "onresourcetimingbufferfull",
    "clearResourceTimings",
    "setResourceTimingBufferSize",
    "markResourceTiming",
    "addEventListener",
    "removeEventListener",
    "dispatchEvent",
  ])
    assert.equal(performance[key], undefined, `${key} is not a Performance member`);
});

test("performance.now is monotonic and close to wall clock through timeOrigin", () => {
  const beforeDate = Date.now();
  const first = performance.now();
  let previous = first;
  for (let i = 0; i < 1000; i++) {
    const current = performance.now();
    assert(current >= previous, `performance.now went backwards: ${current} < ${previous}`);
    previous = current;
  }
  const afterDate = Date.now();
  assert.equal(typeof performance.timeOrigin, "number");
  assert(performance.timeOrigin > 0);
  const syntheticNow = performance.timeOrigin + first;
  assert(syntheticNow >= beforeDate - 1000, "timeOrigin + now is too far before Date.now()");
  assert(syntheticNow <= afterDate + 1000, "timeOrigin + now is too far after Date.now()");
});

test("performance.toJSON returns Web-compatible timing data", () => {
  const snapshot = performance.toJSON();
  assert.equal(Object.getPrototypeOf(snapshot), Object.prototype);
  assert.equal(typeof snapshot.timeOrigin, "number");
  assert.equal(snapshot.timeOrigin, performance.timeOrigin);
});

test("Performance methods enforce native receiver brand", () => {
  assert.throws(() => Performance.prototype.now.call({}), TypeError);
  assert.throws(() => Object.getOwnPropertyDescriptor(Performance.prototype, "timeOrigin").get.call({}), TypeError);
  assert.throws(() => Performance.prototype.toJSON.call({}), TypeError);
  assert.throws(() => Performance.prototype.mark.call({}, "x"), TypeError);
  assert.throws(() => PerformanceEntry.prototype.toJSON.call({}), TypeError);
  assert.throws(() => Object.getOwnPropertyDescriptor(PerformanceEntry.prototype, "name").get.call({}), TypeError);
});

test("PerformanceEntry, PerformanceMark, and PerformanceMeasure descriptors", () => {
  assert.equal(typeof PerformanceEntry, "function");
  assert.equal(typeof PerformanceMark, "function");
  assert.equal(typeof PerformanceMeasure, "function");
  assert.equal(typeof PerformanceObserver, "function");
  assert.equal(typeof PerformanceObserverEntryList, "function");
  assert.equal(PerformanceEntry.length, 0);
  assert.equal(PerformanceMark.length, 1);
  assert.equal(PerformanceMeasure.length, 0);
  assert.equal(PerformanceObserver.length, 1);
  assert.equal(PerformanceObserverEntryList.length, 0);
  assert.equal(Object.getPrototypeOf(PerformanceMark), PerformanceEntry);
  assert.equal(Object.getPrototypeOf(PerformanceMeasure), PerformanceEntry);
  assert.equal(Object.getPrototypeOf(PerformanceMark.prototype), PerformanceEntry.prototype);
  assert.equal(Object.getPrototypeOf(PerformanceMeasure.prototype), PerformanceEntry.prototype);
  assert.equal(PerformanceEntry.prototype[Symbol.toStringTag], "PerformanceEntry");
  assert.equal(PerformanceMark.prototype[Symbol.toStringTag], "PerformanceMark");
  assert.equal(PerformanceMeasure.prototype[Symbol.toStringTag], "PerformanceMeasure");
  assert.equal(PerformanceObserver.prototype[Symbol.toStringTag], "PerformanceObserver");
  assert.equal(PerformanceObserverEntryList.prototype[Symbol.toStringTag], "PerformanceObserverEntryList");

  for (const key of ["name", "entryType", "startTime", "duration"]) {
    const descriptor = Object.getOwnPropertyDescriptor(PerformanceEntry.prototype, key);
    assert.equal(typeof descriptor.get, "function", `${key} getter`);
    assert.equal(descriptor.set, undefined, `${key} setter`);
    assert.equal(descriptor.enumerable, true, `${key} enumerable`);
  }
  assert.equal(Object.getOwnPropertyDescriptor(PerformanceEntry.prototype, "toJSON").value.length, 0);
  assert.equal(typeof Object.getOwnPropertyDescriptor(PerformanceMark.prototype, "detail").get, "function");
  assert.equal(typeof Object.getOwnPropertyDescriptor(PerformanceMeasure.prototype, "detail").get, "function");

  assert.throws(() => PerformanceEntry(), TypeError);
  assert.throws(() => new PerformanceEntry(), TypeError);
  assert.throws(() => PerformanceMark("x"), TypeError);
  assert.throws(() => new PerformanceMark(), TypeError);
  assert.throws(() => PerformanceMeasure(), TypeError);
  assert.throws(() => new PerformanceMeasure(), TypeError);
  assert.throws(() => PerformanceObserver(() => {}), TypeError);
  assert.throws(() => new PerformanceObserver(), TypeError);
  assert.throws(() => new PerformanceObserver(1), TypeError);
  assert.throws(() => PerformanceObserverEntryList(), TypeError);
  assert.throws(() => new PerformanceObserverEntryList(), TypeError);
});

test("PerformanceObserver descriptors and validation match server runtime baseline", () => {
  // Web IDL interface objects are non-enumerable properties of the global object.
  const observerDescriptor = Object.getOwnPropertyDescriptor(globalThis, "PerformanceObserver");
  assert.equal(observerDescriptor.enumerable, false);
  assert.equal(observerDescriptor.configurable, true);
  assert.equal(observerDescriptor.writable, true);

  const listDescriptor = Object.getOwnPropertyDescriptor(globalThis, "PerformanceObserverEntryList");
  assert.equal(listDescriptor.enumerable, false);
  assert.equal(listDescriptor.configurable, true);
  assert.equal(listDescriptor.writable, true);

  const supportedA = PerformanceObserver.supportedEntryTypes;
  const supportedB = PerformanceObserver.supportedEntryTypes;
  assert.deepEqual(supportedA, ["mark", "measure"]);
  assert.equal(Object.isFrozen(supportedA), true);
  assert.equal(supportedA === supportedB, false);

  for (const [key, length] of [
    ["observe", 0],
    ["disconnect", 0],
    ["takeRecords", 0],
  ]) {
    const descriptor = Object.getOwnPropertyDescriptor(PerformanceObserver.prototype, key);
    assert.equal(typeof descriptor.value, "function", `${key} is a function`);
    assert.equal(descriptor.value.length, length, `${key}.length`);
    assert.equal(descriptor.enumerable, true, `${key} enumerable`);
  }

  for (const [key, length] of [
    ["getEntries", 0],
    ["getEntriesByType", 1],
    ["getEntriesByName", 1],
  ]) {
    const descriptor = Object.getOwnPropertyDescriptor(PerformanceObserverEntryList.prototype, key);
    assert.equal(typeof descriptor.value, "function", `${key} is a function`);
    assert.equal(descriptor.value.length, length, `${key}.length`);
    assert.equal(descriptor.enumerable, true, `${key} enumerable`);
  }

  const observer = new PerformanceObserver(() => {});
  assert.throws(() => PerformanceObserver.prototype.observe.call({}, { entryTypes: ["mark"] }), TypeError);
  assert.throws(() => PerformanceObserver.prototype.disconnect.call({}), TypeError);
  assert.throws(() => PerformanceObserver.prototype.takeRecords.call({}), TypeError);
  assert.throws(() => observer.observe(), TypeError);
  assert.throws(() => observer.observe({}), TypeError);
  assert.throws(() => observer.observe(1), TypeError);
  assert.throws(() => observer.observe({ entryTypes: null }), TypeError);
  assert.throws(() => observer.observe({ entryTypes: "mark" }), TypeError);
  assert.throws(() => observer.observe({ entryTypes: ["mark"], type: "mark" }), TypeError);
  assert.equal(observer.observe({ entryTypes: ["not-real"] }), undefined);
  assert.equal(observer.observe({ type: "not-real" }), undefined);
  // A type the timeline never records is ignored, as observe() ignores any unsupported type.
  assert.equal(observer.observe({ type: "resource" }), undefined);
  assert.deepEqual(observer.takeRecords(), []);

  const byEntryTypes = new PerformanceObserver(() => {});
  byEntryTypes.observe({ entryTypes: ["mark"] });
  const switchToType = assert.throws(() => byEntryTypes.observe({ type: "mark" }), DOMException);
  assert.equal(switchToType.name, "InvalidModificationError");

  const byType = new PerformanceObserver(() => {});
  byType.observe({ type: "mark" });
  const switchToEntryTypes = assert.throws(() => byType.observe({ entryTypes: ["mark"] }), DOMException);
  assert.equal(switchToEntryTypes.name, "InvalidModificationError");
});

test("performance marks create entries and are queryable by name and type", () => {
  performance.clearMarks();
  performance.clearMeasures();

  const start = performance.mark("collo-start", { startTime: 3, detail: "start-detail" });
  const end = performance.mark("collo-end", { startTime: 8 });

  assert(start instanceof PerformanceMark);
  assert(start instanceof PerformanceEntry);
  assert.equal(start.name, "collo-start");
  assert.equal(start.entryType, "mark");
  assert.equal(start.startTime, 3);
  assert.equal(start.duration, 0);
  assert.equal(start.detail, "start-detail");
  assert.equal(Object.prototype.toString.call(start), "[object PerformanceMark]");

  assert.deepEqual(start.toJSON(), {
    name: "collo-start",
    entryType: "mark",
    startTime: 3,
    duration: 0,
  });

  const names = performance.getEntries().map(entry => entry.name);
  assert.deepEqual(names, ["collo-start", "collo-end"]);
  assert.equal(performance.getEntriesByName("collo-start").length, 1);
  assert.equal(performance.getEntriesByName("collo-start", "mark").length, 1);
  assert.equal(performance.getEntriesByName("collo-start", "measure").length, 0);
  assert.equal(performance.getEntriesByType("mark").length, 2);

  performance.clearMarks("collo-start");
  assert.equal(performance.getEntriesByName("collo-start").length, 0);
  assert.equal(performance.getEntriesByName("collo-end").length, 1);
  performance.clearMarks();
  assert.equal(performance.getEntriesByType("mark").length, 0);
  assert.equal(end.name, "collo-end");
});

// The timeline outlives every request on its realm, so it keeps at most WebApiPerformanceEntriesMax entries and drops
// the oldest beyond it.
test("performance entries are capped at 1000", () => {
  performance.clearMarks();
  performance.clearMeasures();
  for (let i = 0; i < 1050; i++)
    performance.mark(`cap-${i}`, { startTime: i });

  const entries = performance.getEntriesByType("mark");
  assert.equal(entries.length, 1000);
  assert.equal(entries[0].name, "cap-50");
  assert.equal(entries[entries.length - 1].name, "cap-1049");
  assert.equal(performance.getEntriesByName("cap-49").length, 0);
  assert.equal(performance.getEntriesByName("cap-1049").length, 1);
  performance.clearMarks();
});

test("performance measures support mark names and option dictionaries", () => {
  performance.clearMarks();
  performance.clearMeasures();
  performance.mark("a", { startTime: 2 });
  performance.mark("b", { startTime: 7 });

  const fromMarks = performance.measure("a-to-b", "a", "b");
  assert(fromMarks instanceof PerformanceMeasure);
  assert(fromMarks instanceof PerformanceEntry);
  assert.equal(fromMarks.name, "a-to-b");
  assert.equal(fromMarks.entryType, "measure");
  assert.equal(fromMarks.startTime, 2);
  assert.equal(fromMarks.duration, 5);
  assert.equal(fromMarks.detail, null);
  assert.equal(Object.prototype.toString.call(fromMarks), "[object PerformanceMeasure]");

  const fromOptions = performance.measure("options", { start: 3, duration: 4, detail: "measure-detail" });
  assert.equal(fromOptions.startTime, 3);
  assert.equal(fromOptions.duration, 4);
  assert.equal(fromOptions.detail, "measure-detail");
  assert.deepEqual(fromOptions.toJSON(), {
    name: "options",
    entryType: "measure",
    startTime: 3,
    duration: 4,
  });

  const fromEndAndDuration = performance.measure("end-duration", { end: 9, duration: 2 });
  assert.equal(fromEndAndDuration.startTime, 7);
  assert.equal(fromEndAndDuration.duration, 2);

  const negativeDuration = performance.measure("negative-duration", { start: 9, end: 4 });
  assert.equal(negativeDuration.startTime, 9);
  assert.equal(negativeDuration.duration, 0);

  assert.equal(performance.getEntriesByName("a-to-b", "measure").length, 1);
  assert.equal(performance.getEntriesByType("measure").length, 4);
  assert.throws(() => performance.measure("missing", "missing-mark"), SyntaxError);
  assert.throws(() => performance.mark("bad", { startTime: -1 }), TypeError);
  assert.throws(() => performance.measure("bad", { start: -1, duration: 1 }), TypeError);
  assert.throws(() => performance.measure("bad", { duration: 1 }), TypeError);
  assert.throws(() => performance.measure("bad", { start: 1, end: 2, duration: 1 }), TypeError);

  performance.clearMeasures("a-to-b");
  assert.equal(performance.getEntriesByName("a-to-b").length, 0);
  assert.equal(performance.getEntriesByName("options").length, 1);
  performance.clearMeasures();
  assert.equal(performance.getEntriesByType("measure").length, 0);
});

test("PerformanceMark supports subclass construction without publishing entries", () => {
  performance.clearMarks();
  class SpecialMark extends PerformanceMark {}
  const mark = new SpecialMark("subclass", { startTime: 12 });
  assert(mark instanceof SpecialMark);
  assert(mark instanceof PerformanceMark);
  assert.equal(mark.name, "subclass");
  assert.equal(mark.startTime, 12);
  assert.equal(performance.getEntriesByName("subclass").length, 0);
});

async function flushPerformanceObserver() {
  await Promise.resolve();
  await Promise.resolve();
}

test("PerformanceObserver batches mark and measure entries asynchronously", async () => {
  performance.clearMarks();
  performance.clearMeasures();

  const deliveries = [];
  let observer;
  observer = new PerformanceObserver((list, deliveredObserver) => {
    assert(deliveredObserver === observer);
    assert(list instanceof PerformanceObserverEntryList);
    assert.throws(() => PerformanceObserverEntryList.prototype.getEntries.call({}), TypeError);
    deliveries.push({
      all: list.getEntries().map(entry => entry.name),
      marks: list.getEntriesByType("mark").map(entry => entry.name),
      named: list.getEntriesByName("obs-measure", "measure").map(entry => entry.name),
      missingLength: list.getEntriesByName("missing").length,
    });
  });

  observer.observe({ entryTypes: ["measure", "mark", "unknown"] });
  performance.mark("obs-start", { startTime: 2 });
  performance.mark("obs-end", { startTime: 7 });
  performance.measure("obs-measure", "obs-start", "obs-end");
  assert.equal(deliveries.length, 0);

  await flushPerformanceObserver();
  assert.equal(deliveries.length, 1);
  assert.deepEqual(deliveries[0].all, ["obs-start", "obs-measure", "obs-end"]);
  assert.deepEqual(deliveries[0].marks, ["obs-start", "obs-end"]);
  assert.deepEqual(deliveries[0].named, ["obs-measure"]);
  assert.equal(deliveries[0].missingLength, 0);

  observer.disconnect();
  performance.mark("after-disconnect");
  await flushPerformanceObserver();
  assert.equal(deliveries.length, 1);
  performance.clearMarks();
  performance.clearMeasures();
});

test("PerformanceObserver takeRecords drains pending delivery", async () => {
  performance.clearMarks();
  const calls = [];
  const observer = new PerformanceObserver(list => {
    calls.push(list.getEntries().map(entry => entry.name));
  });

  observer.observe({ type: "mark" });
  performance.mark("take-records", { startTime: 4 });
  const records = observer.takeRecords();
  assert.deepEqual(records.map(entry => entry.name), ["take-records"]);

  await flushPerformanceObserver();
  assert.equal(calls.length, 0);
  observer.disconnect();
  performance.clearMarks();
});

test("PerformanceObserver pending record cap keeps newest entries", () => {
  performance.clearMarks();
  const observer = new PerformanceObserver(() => {});
  observer.observe({ type: "mark" });

  for (let index = 0; index < 1100; index++)
    performance.mark(`observer-cap-${index}`, { startTime: index });

  const records = observer.takeRecords();
  assert.equal(records.length, 1024);
  assert.equal(records[0].name, "observer-cap-76");
  assert.equal(records[records.length - 1].name, "observer-cap-1099");
  observer.disconnect();
  performance.clearMarks();
});

test("PerformanceObserver pending records survive global entry clear until drained", async () => {
  performance.clearMarks();
  const delivered = [];
  const observer = new PerformanceObserver(list => {
    delivered.push(...list.getEntries().map(entry => entry.name));
  });

  observer.observe({ type: "mark" });
  performance.mark("pending-after-clear", { startTime: 1 });
  performance.clearMarks("pending-after-clear");
  assert.deepEqual(observer.takeRecords().map(entry => entry.name), ["pending-after-clear"]);

  performance.mark("deliver-after-clear", { startTime: 2 });
  performance.clearMarks("deliver-after-clear");
  await flushPerformanceObserver();
  assert.deepEqual(delivered, ["deliver-after-clear"]);
  observer.disconnect();
  performance.clearMarks();
});

test("PerformanceObserver buffered type replay uses existing entries", async () => {
  performance.clearMarks();
  performance.mark("buffered-a", { startTime: 1 });
  performance.mark("buffered-b", { startTime: 3 });

  let delivered = null;
  const observer = new PerformanceObserver(list => {
    const entries = list.getEntriesByName("buffered-a");
    assert.equal(entries.length, 1);
    delivered = entries.map(entry => entry.name);
  });
  observer.observe({ type: "mark", buffered: true });

  await flushPerformanceObserver();
  assert.deepEqual(delivered, ["buffered-a"]);
  observer.disconnect();
  performance.clearMarks();
});
