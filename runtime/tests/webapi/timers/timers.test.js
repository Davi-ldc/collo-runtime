// Collo compatibility contract derived from Bun v1.3.14:
// - reference/bun-v1.3.14/test/js/web/timers/setTimeout.test.js
// - reference/bun-v1.3.14/test/js/web/timers/setInterval.test.js
// - reference/bun-v1.3.14/test/js/web/timers/setImmediate.test.js
// - reference/bun-v1.3.14/test/js/node/test/parallel/test-timers-immediate-queue.js

describe("timers", () => {
  const functions = {
    setTimeout: 2,
    setInterval: 2,
    setImmediate: 1,
    clearTimeout: 1,
    clearInterval: 1,
    clearImmediate: 1,
  };

  function descriptor(obj, key) {
    const desc = Object.getOwnPropertyDescriptor(obj, key);
    assert(desc, `${String(key)} descriptor should exist`);
    return desc;
  }

  function assertTimerId(id) {
    assert.equal(typeof id, "number");
    assert(Number.isInteger(id));
    assert(id > 0);
    return id;
  }

  test("global descriptors and function shapes", () => {
    for (const [name, length] of Object.entries(functions)) {
      const fn = globalThis[name];
      assert.equal(typeof fn, "function", `${name} should be a function`);
      assert.equal(fn.name, name, `${name}.name`);
      assert.equal(fn.length, length, `${name}.length`);
      assert.equal(Object.hasOwn(fn, "prototype"), false, `${name} should not have own prototype`);

      const globalDesc = descriptor(globalThis, name);
      assert.equal(globalDesc.value, fn, `${name} global value`);
      assert.equal(globalDesc.writable, true, `${name} global writable`);
      assert.equal(globalDesc.enumerable, false, `${name} global enumerable`);
      assert.equal(globalDesc.configurable, true, `${name} global configurable`);

      const lengthDesc = descriptor(fn, "length");
      assert.equal(lengthDesc.value, length, `${name}.length descriptor value`);
      assert.equal(lengthDesc.writable, false, `${name}.length writable`);
      assert.equal(lengthDesc.enumerable, false, `${name}.length enumerable`);
      assert.equal(lengthDesc.configurable, true, `${name}.length configurable`);

      const nameDesc = descriptor(fn, "name");
      assert.equal(nameDesc.value, name, `${name}.name descriptor value`);
      assert.equal(nameDesc.writable, false, `${name}.name writable`);
      assert.equal(nameDesc.enumerable, false, `${name}.name enumerable`);
      assert.equal(nameDesc.configurable, true, `${name}.name configurable`);
    }
  });

  test("setTimeout and setInterval reject missing or non-callable callbacks", () => {
    for (const fn of [setTimeout, setInterval]) {
      assert.throws(() => fn(), TypeError);
      assert.throws(() => fn(undefined), TypeError);
      assert.throws(() => fn(null), TypeError);
      assert.throws(() => fn(0), TypeError);
      assert.throws(() => fn("callback"), TypeError);
      assert.throws(() => fn({ handleEvent() {} }), TypeError);
    }
  });

  test("setImmediate rejects missing or non-callable callbacks", () => {
    assert.throws(() => setImmediate(), TypeError);
    assert.throws(() => setImmediate(undefined), TypeError);
    assert.throws(() => setImmediate(null), TypeError);
    assert.throws(() => setImmediate(0), TypeError);
    assert.throws(() => setImmediate("callback"), TypeError);
    assert.throws(() => setImmediate({ handleEvent() {} }), TypeError);
  });

  test("setTimeout runs with args and global this", async () => {
    let marker = "";
    await new Promise(resolve => {
      const id = setTimeout(function (text, suffix) {
        marker = text + ":" + suffix + ":" + (this === globalThis);
        resolve();
      }, 0, "hello", "timer");
      assert.equal(typeof id, "number");
      assert(Number.isFinite(id));
      assert(id > 0);
    });
    assert.equal(marker, "hello:timer:true");
  });

  // setImmediate returns a numeric id as setTimeout does, not Node's Immediate object.
  test("setImmediate returns a number", () => {
    const id = setImmediate(() => {});
    try {
      assertTimerId(id);
      assert.equal(typeof id, "number");
    } finally {
      clearImmediate(id);
    }
  });

  test("setImmediate returns increasing ids and runs callbacks with args and global this in FIFO order", async () => {
    let marker = "";
    const order = [];
    let lastId = 0;
    await new Promise(resolve => {
      for (let i = 0; i < 5; i++) {
        const id = setImmediate(function (value) {
          order.push(value);
          marker = value + ":" + (this === globalThis);
          if (order.length === 5)
            resolve();
        }, i);
        assert(assertTimerId(id) > lastId);
        lastId = id;
      }
    });
    assert.deepEqual(order, [0, 1, 2, 3, 4]);
    assert.equal(marker, "4:true");
  });

  test("setTimeout treats omitted, negative, NaN, and object delays as zero-or-clamped timers", async () => {
    const order = [];
    await new Promise(resolve => {
      setTimeout(() => order.push("omitted"));
      setTimeout(() => order.push("negative"), -1);
      setTimeout(() => order.push("nan"), NaN);
      setTimeout(() => {
        order.push("object");
        resolve();
      }, { valueOf: () => 0 });
    });
    assert.deepEqual(order, ["omitted", "negative", "nan", "object"]);
  });

  test("setTimeout converts its delay with ToInt32, so a delay past 2 ** 31 - 1 wraps instead of saturating", async () => {
    // HTML's timeout is a WebIDL long: 2 ** 31 wraps to -(2 ** 31), which HTML
    // clamps to 0, and 2 ** 32 + 2 wraps to 2.
    const order = [];
    await new Promise(resolve => {
      setTimeout(() => order.push("wrapped-to-zero"), 2 ** 31);
      setTimeout(() => order.push("one"), 1);
      setTimeout(() => {
        order.push("wrapped-to-two");
        resolve();
      }, 2 ** 32 + 2);
    });
    assert.deepEqual(order, ["wrapped-to-zero", "one", "wrapped-to-two"]);
  });

  test("clear functions ignore a number no timer id can be, at or past 2 ** 64", () => {
    // Converting such a number to a 64-bit id is undefined behavior, which
    // only the UBSan mode (-Dsanitize=undefined) turns into a failure.
    assert.equal(clearTimeout(2 ** 64), undefined);
    assert.equal(clearInterval(2 ** 64), undefined);
    assert.equal(clearImmediate(2 ** 64), undefined);
    assert.equal(clearTimeout(2 ** 70), undefined);
    assert.equal(clearImmediate(2 ** 70), undefined);
  });

  test("clearTimeout cancels pending callback", async () => {
    let called = false;
    const id = setTimeout(() => {
      called = true;
    }, 0);
    clearTimeout(id);
    await new Promise(resolve => setTimeout(resolve, 0));
    assert.equal(called, false);
  });

  test("clearImmediate cancels pending callback and is idempotent", async () => {
    let called = false;
    const id = setImmediate(() => {
      called = true;
    });
    assertTimerId(id);
    clearImmediate(id);
    clearImmediate(id);
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(called, false);
  });

  test("clearImmediate converts its argument to a number as clearTimeout does", async () => {
    let called = false;
    const id = setImmediate(() => {
      called = true;
    });
    clearImmediate({ valueOf: () => id });
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(called, false);
    assert.throws(() => clearImmediate({ valueOf() { throw new TypeError("converted"); } }), TypeError);
  });

  test("clear functions are receiver independent, no-op invalid ids, and interchangeable", async () => {
    assert.equal(clearTimeout(), undefined);
    assert.equal(clearTimeout(null), undefined);
    assert.equal(clearTimeout(undefined), undefined);
    assert.equal(clearTimeout(0), undefined);
    assert.equal(clearTimeout(-1), undefined);
    assert.equal(clearTimeout(NaN), undefined);
    assert.equal(clearTimeout(Infinity), undefined);
    assert.equal(clearInterval(), undefined);
    assert.equal(clearInterval.call(null, "not-a-timer"), undefined);
    assert.equal(clearImmediate(), undefined);
    assert.equal(clearImmediate(null), undefined);
    assert.equal(clearImmediate(undefined), undefined);
    assert.equal(clearImmediate(0), undefined);
    assert.equal(clearImmediate(-1), undefined);
    assert.equal(clearImmediate(NaN), undefined);
    assert.equal(clearImmediate(Infinity), undefined);
    assert.equal(clearImmediate.call(null, "not-a-timer"), undefined);

    let timeoutCalled = false;
    const timeoutId = setTimeout(() => {
      timeoutCalled = true;
    }, 0);
    clearInterval(timeoutId);

    let intervalCalled = false;
    const intervalId = setInterval(() => {
      intervalCalled = true;
    }, 0);
    clearTimeout.call(undefined, intervalId);

    await new Promise(resolve => setTimeout(resolve, 0));
    assert.equal(timeoutCalled, false);
    assert.equal(intervalCalled, false);
  });

  test("clearImmediate and clearTimeout do not cross-cancel", async () => {
    let timeoutCalled = false;
    const timeoutId = setTimeout(() => {
      timeoutCalled = true;
    }, 0);
    clearImmediate(timeoutId);

    let immediateCalled = false;
    const immediateId = setImmediate(() => {
      immediateCalled = true;
    });
    clearTimeout(immediateId);

    await new Promise(resolve => setTimeout(resolve, 0));
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(timeoutCalled, true);
    assert.equal(immediateCalled, true);
  });

  test("setInterval repeats and can be cleared", async () => {
    let count = 0;
    await new Promise(resolve => {
      const id = setInterval(() => {
        count++;
      if (count === 2) {
        clearInterval(id);
        resolve();
      }
    }, 0);
    });
    assert.equal(count, 2);
  });

  test("setImmediate callbacks scheduled during a batch run in the next batch", async () => {
    const order = [];
    await new Promise(resolve => {
      setImmediate(() => {
        order.push("first");
        setImmediate(() => order.push("nested"));
      });
      setImmediate(() => order.push("second"));
      setImmediate(() => {
        order.push("third");
        setImmediate(() => {
          order.push("after");
          resolve();
        });
      });
    });
    assert.deepEqual(order, ["first", "second", "third", "nested", "after"]);
  });

  test("setImmediate drains microtasks before the next immediate callback", async () => {
    const order = [];
    await new Promise(resolve => {
      setImmediate(() => {
        order.push("immediate-1");
        queueMicrotask(() => order.push("microtask"));
      });
      setImmediate(() => {
        order.push("immediate-2");
        resolve();
      });
    });
    assert.deepEqual(order, ["immediate-1", "microtask", "immediate-2"]);
  });

  test("throwing setImmediate callback does not stop later immediates", async () => {
    const order = [];
    await new Promise(resolve => {
      setImmediate(() => {
        order.push("first");
        throw new Error("expected immediate boom");
      });
      setImmediate(() => {
        order.push("second");
        setImmediate(() => {
          order.push("nested");
          resolve();
        });
      });
      setImmediate(() => order.push("third"));
    });
    assert.deepEqual(order, ["first", "second", "third", "nested"]);
  });

  test("timer globals are writable and configurable", () => {
    const original = {
      setTimeout,
      setInterval,
      setImmediate,
      clearTimeout,
      clearInterval,
      clearImmediate,
    };
    try {
      globalThis.setTimeout = function replacement() {
        return "timeout";
      };
      assert.equal(setTimeout(), "timeout");
      globalThis.setImmediate = function replacementImmediate() {
        return "immediate";
      };
      assert.equal(setImmediate(), "immediate");
      assert.equal(delete globalThis.clearImmediate, true);
      assert.equal(Object.hasOwn(globalThis, "clearImmediate"), false);
    } finally {
      for (const [name, fn] of Object.entries(original)) {
        Object.defineProperty(globalThis, name, {
          value: fn,
          writable: true,
          enumerable: false,
          configurable: true,
        });
      }
    }
  });
});
