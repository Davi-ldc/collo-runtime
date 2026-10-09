// Collo compatibility contract derived from Bun v1.3.14:
// - reference/bun-v1.3.14/test/js/deno/abort/abort-controller.test.ts
// - reference/bun-v1.3.14/test/js/web/abort/abort.test.ts

function descriptor(obj, key) {
  const desc = Object.getOwnPropertyDescriptor(obj, key);
  assert(desc, `${String(key)} descriptor should exist`);
  return desc;
}

function assertDataDescriptor(desc, value, writable, enumerable, configurable, label) {
  assert.equal(desc.value, value, `${label} value`);
  assert.equal(desc.writable, writable, `${label} writable`);
  assert.equal(desc.enumerable, enumerable, `${label} enumerable`);
  assert.equal(desc.configurable, configurable, `${label} configurable`);
  assert.equal("get" in desc, false, `${label} should not be accessor`);
  assert.equal("set" in desc, false, `${label} should not be accessor`);
}

function assertFunctionShape(fn, name, length, hasPrototype, label = name) {
  assert.equal(typeof fn, "function", `${label} should be a function`);
  assertDataDescriptor(descriptor(fn, "name"), name, false, false, true, `${label}.name`);
  assertDataDescriptor(descriptor(fn, "length"), length, false, false, true, `${label}.length`);
  assert.equal(Object.hasOwn(fn, "prototype"), hasPrototype, `${label} prototype presence`);
}

describe("AbortController and AbortSignal", () => {
  test("constructors globals prototype descriptors and brand checks", () => {
    assert.equal(typeof AbortController, "function");
    assert.equal(typeof AbortSignal, "function");
    assert.equal(AbortController.length, 0);
    assert.equal(AbortSignal.length, 0);
    assert.throws(() => AbortController(), TypeError);
    assert.throws(() => AbortSignal(), TypeError);
    assert.throws(() => new AbortSignal(), TypeError);

    assertDataDescriptor(descriptor(globalThis, "AbortController"), AbortController, true, false, true, "global AbortController");
    assertDataDescriptor(descriptor(globalThis, "AbortSignal"), AbortSignal, true, false, true, "global AbortSignal");
    assertFunctionShape(AbortController, "AbortController", 0, true);
    assertFunctionShape(AbortSignal, "AbortSignal", 0, true);
    assertDataDescriptor(descriptor(AbortController, "prototype"), AbortController.prototype, false, false, false, "AbortController.prototype");
    assertDataDescriptor(descriptor(AbortSignal, "prototype"), AbortSignal.prototype, false, false, false, "AbortSignal.prototype");
    assertDataDescriptor(descriptor(AbortController.prototype, "constructor"), AbortController, true, false, true, "AbortController.prototype.constructor");
    assertDataDescriptor(descriptor(AbortSignal.prototype, "constructor"), AbortSignal, true, false, true, "AbortSignal.prototype.constructor");
    assertDataDescriptor(descriptor(AbortController.prototype, Symbol.toStringTag), "AbortController", false, false, true, "AbortController.prototype Symbol.toStringTag");
    assertDataDescriptor(descriptor(AbortSignal.prototype, Symbol.toStringTag), "AbortSignal", false, false, true, "AbortSignal.prototype Symbol.toStringTag");

    const signalDescriptor = descriptor(AbortController.prototype, "signal");
    assert.equal(signalDescriptor.enumerable, true);
    assert.equal(signalDescriptor.configurable, true);
    assert.equal(signalDescriptor.set, undefined);
    assertFunctionShape(signalDescriptor.get, "get signal", 0, false, "AbortController.signal getter");
    assert.throws(() => signalDescriptor.get.call({}), TypeError);

    const abortDescriptor = descriptor(AbortController.prototype, "abort");
    assertDataDescriptor(abortDescriptor, AbortController.prototype.abort, true, true, true, "AbortController.prototype.abort");
    assertFunctionShape(abortDescriptor.value, "abort", 0, false, "AbortController.abort");
    assert.throws(() => abortDescriptor.value.call({}), TypeError);

    for (const name of ["aborted", "reason", "onabort"]) {
      const property = descriptor(AbortSignal.prototype, name);
      assert.equal(property.enumerable, true, `${name} enumerable`);
      assert.equal(property.configurable, true, `${name} configurable`);
      assertFunctionShape(property.get, `get ${name}`, 0, false, `AbortSignal.${name} getter`);
      assert.throws(() => property.get.call({}), TypeError);
      if (name === "onabort") {
        assertFunctionShape(property.set, "set onabort", 1, false, "AbortSignal.onabort setter");
        assert.throws(() => property.set.call({}, null), TypeError);
      } else {
        assert.equal(property.set, undefined, `${name} setter`);
      }
    }

    const throwIfAborted = descriptor(AbortSignal.prototype, "throwIfAborted");
    assertDataDescriptor(throwIfAborted, AbortSignal.prototype.throwIfAborted, true, true, true, "AbortSignal.prototype.throwIfAborted");
    assertFunctionShape(throwIfAborted.value, "throwIfAborted", 0, false, "AbortSignal.throwIfAborted");
    assert.throws(() => throwIfAborted.value.call({}), TypeError);

    for (const [name, length] of [["abort", 0], ["timeout", 1], ["any", 1]]) {
      const property = descriptor(AbortSignal, name);
      assertDataDescriptor(property, AbortSignal[name], true, false, true, `AbortSignal.${name}`);
      assertFunctionShape(property.value, name, length, false, `AbortSignal.${name}`);
    }

    assert.equal(Object.keys(AbortController.prototype).join(","), "signal,abort");
    assert.equal(Object.keys(AbortSignal.prototype).join(","), "aborted,reason,onabort,throwIfAborted");

    const controller = new AbortController();
    assert(controller instanceof AbortController, "controller brand");
    assert.equal(Object.prototype.toString.call(controller), "[object AbortController]");
    assert.equal(Object.prototype.toString.call(controller.signal), "[object AbortSignal]");
    assert(controller.signal instanceof AbortSignal, "signal brand");
    assert(controller.signal instanceof EventTarget, "AbortSignal extends EventTarget");
    assert.equal(Object.getPrototypeOf(AbortSignal.prototype), EventTarget.prototype);
    assert.equal(controller.signal, controller.signal, "signal is SameObject");
  });

  test("abort dispatches once with default DOMException reason", () => {
    const controller = new AbortController();
    const signal = controller.signal;
    let events = 0;
    let onabort = 0;
    signal.onabort = event => {
      onabort++;
      assert.equal(event.type, "abort");
      assert.equal(event.target, signal);
      assert.equal(event.currentTarget, signal);
      assert.equal(event.isTrusted, true);
      assert.equal(event.bubbles, false);
      assert.equal(event.cancelable, false);
    };
    signal.addEventListener("abort", function (event) {
      events++;
      assert.equal(this, signal);
      assert.equal(event.type, "abort");
    });

    assert.equal(signal.aborted, false);
    assert.equal(signal.reason, undefined);
    controller.abort();
    assert.equal(signal.aborted, true);
    assert(signal.reason instanceof DOMException, "default reason is DOMException");
    assert.equal(signal.reason.name, "AbortError");
    assert.equal(signal.reason.code, 20);
    assert.equal(events, 1);
    assert.equal(onabort, 1);

    controller.abort("ignored");
    assert.equal(signal.reason.name, "AbortError");
    assert.equal(events, 1);
    assert.equal(onabort, 1);
  });

  test("custom abort reasons and throwIfAborted", () => {
    for (const reason of [null, "stop", new Error("stop"), { stop: true }]) {
      const controller = new AbortController();
      controller.abort(reason);
      assert.equal(controller.signal.reason, reason);
      assert.throws(() => controller.signal.throwIfAborted(), reason instanceof Error ? Error : undefined);
    }

    const live = new AbortController();
    assert.equal(live.signal.throwIfAborted(), undefined);
  });

  test("onabort and addEventListener registrations are independent", () => {
    const controller = new AbortController();
    const signal = controller.signal;
    let calls = 0;
    function handler() {
      calls++;
    }
    signal.onabort = handler;
    signal.addEventListener("abort", handler);
    controller.abort();
    assert.equal(calls, 2);

    const second = new AbortController();
    let secondCalls = 0;
    function secondHandler() {
      secondCalls++;
    }
    second.signal.onabort = secondHandler;
    second.signal.addEventListener("abort", secondHandler);
    second.signal.removeEventListener("abort", secondHandler);
    second.abort();
    assert.equal(secondCalls, 1);
  });

  test("AbortSignal.abort creates an already-aborted signal", () => {
    const defaultSignal = AbortSignal.abort();
    assert(defaultSignal instanceof AbortSignal);
    assert.equal(defaultSignal.aborted, true);
    assert(defaultSignal.reason instanceof DOMException);
    assert.equal(defaultSignal.reason.name, "AbortError");

    const reason = { value: 1 };
    const customSignal = AbortSignal.abort(reason);
    assert.equal(customSignal.aborted, true);
    assert.equal(customSignal.reason, reason);
  });

  test("EventTarget listener signal option removes listener on abort", () => {
    const target = new EventTarget();
    const controller = new AbortController();
    let count = 0;
    function listener() {
      count++;
    }

    target.addEventListener("tick", listener, { signal: controller.signal });
    target.dispatchEvent(new Event("tick"));
    assert.equal(count, 1);

    controller.abort();
    target.dispatchEvent(new Event("tick"));
    assert.equal(count, 1);

    const already = AbortSignal.abort();
    target.addEventListener("tick", listener, { signal: already });
    target.dispatchEvent(new Event("tick"));
    assert.equal(count, 1);
  });

  test("removed and once signal listeners release abort cleanup", () => {
    const target = new EventTarget();
    const controller = new AbortController();
    let calls = 0;
    function listener() {
      calls++;
    }

    target.addEventListener("cleanup", listener, { signal: controller.signal });
    target.removeEventListener("cleanup", listener);
    target.addEventListener("cleanup", listener);
    controller.abort("old-cleanup");
    target.dispatchEvent(new Event("cleanup"));
    assert.equal(calls, 1, "abort must not remove a later listener after explicit remove");
    target.removeEventListener("cleanup", listener);

    const onceController = new AbortController();
    target.addEventListener("once-cleanup", listener, { once: true, signal: onceController.signal });
    target.dispatchEvent(new Event("once-cleanup"));
    assert.equal(calls, 2);
    target.addEventListener("once-cleanup", listener);
    onceController.abort("old-once-cleanup");
    target.dispatchEvent(new Event("once-cleanup"));
    assert.equal(calls, 3, "abort must not remove a later listener after once fired");
    target.removeEventListener("once-cleanup", listener);
  });

  test("AbortSignal.any follows the first aborted source", () => {
    const a = new AbortController();
    const b = new AbortController();
    const signal = AbortSignal.any([a.signal, b.signal]);
    let fired = 0;
    signal.addEventListener("abort", () => fired++);
    b.abort("b");
    assert.equal(signal.aborted, true);
    assert.equal(signal.reason, "b");
    assert.equal(fired, 1);
    a.abort("a");
    assert.equal(signal.reason, "b");
    assert.equal(fired, 1);

    const immediate = AbortSignal.any([AbortSignal.abort("ready")]);
    assert.equal(immediate.aborted, true);
    assert.equal(immediate.reason, "ready");

    const fromSetController = new AbortController();
    const fromSet = AbortSignal.any(new Set([fromSetController.signal]));
    fromSetController.abort("set");
    assert.equal(fromSet.aborted, true);
    assert.equal(fromSet.reason, "set");
  });

  test("AbortSignal.any follows WPT dependent signal ordering and reentrancy", () => {
    assert.equal(AbortSignal.any([]).aborted, false);

    const controller = new AbortController();
    const signals = [
      controller.signal,
      AbortSignal.any([controller.signal]),
      AbortSignal.any([controller.signal]),
    ];
    signals.push(AbortSignal.any([signals[0]]));
    signals.push(AbortSignal.any([signals[1]]));

    let order = "";
    for (let i = 0; i < signals.length; i++)
      signals[i].addEventListener("abort", () => order += i);

    controller.abort();
    assert.equal(order, "01234");
    for (const signal of signals) {
      assert.equal(signal.aborted, true);
      assert.equal(signal.reason, controller.signal.reason);
    }

    const reentrantA = new AbortController();
    const reentrantB = new AbortController();
    const combined = AbortSignal.any([reentrantA.signal, reentrantB.signal]);
    let combinedEvents = 0;
    reentrantA.signal.addEventListener("abort", () => reentrantB.abort("b"));
    combined.addEventListener("abort", () => combinedEvents++);
    reentrantA.abort("a");
    assert.equal(combined.aborted, true);
    assert.equal(combined.reason, "a");
    assert.equal(combinedEvents, 1);
  });

  test("AbortSignal.any marks dependents before abort events and validates input", () => {
    const controller = new AbortController();
    const first = AbortSignal.any([controller.signal]);
    const second = AbortSignal.any([first]);
    let checked = false;

    controller.signal.addEventListener("abort", () => {
      const third = AbortSignal.any([second]);
      assert.equal(controller.signal.aborted, true);
      assert.equal(first.aborted, true);
      assert.equal(second.aborted, true);
      assert.equal(third.aborted, true);
      assert.equal(third.reason, controller.signal.reason);
      checked = true;
    });

    controller.abort();
    assert.equal(checked, true);

    assert.throws(() => AbortSignal.any(), TypeError);
    assert.throws(() => AbortSignal.any(null), TypeError);
    assert.throws(() => AbortSignal.any({}), TypeError);
    assert.throws(() => AbortSignal.any([{}]), TypeError);
    assert.throws(() => AbortSignal.any([AbortSignal.abort("ready"), {}]), TypeError);
  });

  test("AbortSignal.timeout validates delay and aborts asynchronously", async () => {
    for (const value of [-1, NaN, Infinity])
      assert.throws(() => AbortSignal.timeout(value), TypeError);

    const signal = AbortSignal.timeout(0);
    assert(signal instanceof AbortSignal);
    assert.equal(signal.aborted, false);
    await new Promise(resolve => {
      signal.addEventListener("abort", resolve);
      setTimeout(resolve, 10);
    });
    assert.equal(signal.aborted, true);
    assert(signal.reason instanceof DOMException);
    assert.equal(signal.reason.name, "TimeoutError");
    assert.equal(signal.reason.code, 23);
  });

  // The timeout's backing timer must fire its abort exactly once and then be
  // done: the signal stays aborted, the abort event does not re-fire, and a
  // longer wait reveals no second timer callback. (The native side cancels and
  // clears the stored timer id when the signal aborts.)
  test("AbortSignal.timeout aborts exactly once and does not re-fire", async () => {
    const signal = AbortSignal.timeout(0);
    let abortEvents = 0;
    signal.addEventListener("abort", () => abortEvents++);
    await new Promise(resolve => {
      signal.addEventListener("abort", resolve);
      setTimeout(resolve, 10);
    });
    assert.equal(signal.aborted, true);
    assert.equal(abortEvents, 1, "abort fires once");

    // Give any stale/un-cancelled timer a chance to fire a second time.
    await new Promise(resolve => setTimeout(resolve, 20));
    assert.equal(abortEvents, 1, "timeout abort must not fire again");
    assert.equal(signal.reason.name, "TimeoutError");
  });

  // A timeout signal can be combined via AbortSignal.any; the composite must
  // observe the timeout exactly once.
  test("AbortSignal.timeout composes with AbortSignal.any", async () => {
    const timeout = AbortSignal.timeout(0);
    const composite = AbortSignal.any([timeout]);
    let compositeAborts = 0;
    composite.addEventListener("abort", () => compositeAborts++);
    await new Promise(resolve => {
      composite.addEventListener("abort", resolve);
      setTimeout(resolve, 20);
    });
    assert.equal(composite.aborted, true);
    assert.equal(compositeAborts, 1);
    assert.equal(composite.reason.name, "TimeoutError");
  });

  // AbortSignal.any must dedup its flattened sources: a source listed twice, or
  // two composites sharing an ancestor, must register the dependent edge once,
  // so the resulting signal aborts a single time with a single source ref.
  test("AbortSignal.any deduplicates repeated and shared sources", () => {
    const controller = new AbortController();

    // Same source listed multiple times in the iterable.
    const duplicated = AbortSignal.any([controller.signal, controller.signal, controller.signal]);
    let duplicatedAborts = 0;
    duplicated.addEventListener("abort", () => duplicatedAborts++);

    // Two composites that flatten down to the same ancestor source.
    const left = AbortSignal.any([controller.signal]);
    const right = AbortSignal.any([controller.signal]);
    const shared = AbortSignal.any([left, right]);
    let sharedAborts = 0;
    shared.addEventListener("abort", () => sharedAborts++);

    controller.abort("once");

    assert.equal(duplicated.aborted, true);
    assert.equal(duplicated.reason, "once");
    assert.equal(duplicatedAborts, 1, "duplicate sources must not multiply abort events");

    assert.equal(shared.aborted, true);
    assert.equal(shared.reason, "once");
    assert.equal(sharedAborts, 1, "shared-ancestor composites must abort once");
  });

  test("AbortController subclassing preserves internal signal", () => {
    class CustomAbortController extends AbortController {}
    const controller = new CustomAbortController();
    assert(controller instanceof CustomAbortController);
    assert(controller instanceof AbortController);
    assert.equal(Object.getPrototypeOf(controller), CustomAbortController.prototype);
    assert(controller.signal instanceof AbortSignal);
    controller.abort("subclass");
    assert.equal(controller.signal.reason, "subclass");
  });
});

describe("abort listener exception isolation and born-aborted signals", () => {
  // WHATWG DOM: listener exceptions are reported, not propagated.
  // controller.abort() must never throw because a listener threw, and abort
  // propagation to dependent signals must keep going.
  test("throwing abort listeners stop neither later listeners nor dependent signals", () => {
    const controller = new AbortController();
    const signal = controller.signal;
    const dependent = AbortSignal.any([signal]);
    const order = [];
    signal.onabort = () => {
      order.push("onabort");
      throw new Error("onabort failure");
    };
    signal.addEventListener("abort", () => {
      order.push("listener-throw");
      throw new Error("listener failure");
    });
    signal.addEventListener("abort", () => order.push("listener-after"));
    let dependentFired = 0;
    dependent.addEventListener("abort", () => dependentFired++);

    controller.abort("boom");

    assert.equal(signal.aborted, true);
    assert.equal(signal.reason, "boom");
    assert.deepEqual(order, ["onabort", "listener-throw", "listener-after"]);
    assert.equal(dependent.aborted, true);
    assert.equal(dependent.reason, "boom");
    assert.equal(dependentFired, 1, "dependent abort event must fire despite throwing source listeners");
  });

  // Spec: AbortSignal.abort() returns a signal aborted at birth; no abort
  // event is dispatched, so listeners attached afterwards never fire.
  test("AbortSignal.abort creates aborted signals without firing abort events", () => {
    const aborted = AbortSignal.abort("why");
    assert.equal(aborted.aborted, true);
    assert.equal(aborted.reason, "why");
    let fired = 0;
    aborted.addEventListener("abort", () => fired++);
    aborted.onabort = () => fired++;
    assert.equal(fired, 0, "no abort event fires on a born-aborted signal");

    const fresh = AbortSignal.abort();
    assert.equal(fresh.aborted, true);
    assert(fresh.reason instanceof DOMException);
    assert.equal(fresh.reason.name, "AbortError");

    const dependent = AbortSignal.any([aborted]);
    assert.equal(dependent.aborted, true);
    assert.equal(dependent.reason, "why");
    let dependentFired = 0;
    dependent.addEventListener("abort", () => dependentFired++);
    dependent.onabort = () => dependentFired++;
    assert.equal(dependentFired, 0, "AbortSignal.any with an aborted source is aborted at birth");
  });
});
