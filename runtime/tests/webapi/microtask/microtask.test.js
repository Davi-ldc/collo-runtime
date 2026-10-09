// Collo compatibility contract derived from Bun v1.3.14:
// - reference/bun-v1.3.14/test/js/web/timers/microtask.test.js

describe("queueMicrotask", () => {
  test("global descriptor and function shape", () => {
    const descriptor = Object.getOwnPropertyDescriptor(globalThis, "queueMicrotask");
    assert(descriptor, "queueMicrotask should be an own global property");
    assert.equal(typeof queueMicrotask, "function");
    assert.equal(queueMicrotask.name, "queueMicrotask");
    assert.equal(queueMicrotask.length, 1);
    assert.equal(descriptor.writable, true);
    assert.equal(descriptor.enumerable, true);
    assert.equal(descriptor.configurable, true);

    assert.equal(descriptor.value, queueMicrotask);
    assert.equal(Object.hasOwn(queueMicrotask, "prototype"), false);

    const length = Object.getOwnPropertyDescriptor(queueMicrotask, "length");
    assert.equal(length.value, 1);
    assert.equal(length.writable, false);
    assert.equal(length.enumerable, false);
    assert.equal(length.configurable, true);

    const name = Object.getOwnPropertyDescriptor(queueMicrotask, "name");
    assert.equal(name.value, "queueMicrotask");
    assert.equal(name.writable, false);
    assert.equal(name.enumerable, false);
    assert.equal(name.configurable, true);
  });

  test("throws TypeError when callback is missing or not callable", () => {
    assert.throws(() => queueMicrotask(), TypeError);
    assert.throws(() => queueMicrotask(undefined), TypeError);
    assert.throws(() => queueMicrotask(null), TypeError);
    assert.throws(() => queueMicrotask(1234), TypeError);
    assert.throws(() => queueMicrotask("callback"), TypeError);
    assert.throws(() => queueMicrotask(true), TypeError);
    assert.throws(() => queueMicrotask(Symbol("callback")), TypeError);
    assert.throws(() => queueMicrotask({}), TypeError);
    assert.throws(() => queueMicrotask({ handleEvent() {} }), TypeError);
  });

  test("runs in FIFO order and drains nested microtasks in the same checkpoint", async () => {
    const order = [];
    await new Promise((resolve, reject) => {
      queueMicrotask(() => {
        order.push(0);
        queueMicrotask(() => order.push(3));
      });
      queueMicrotask(() => {
        order.push(1);
        queueMicrotask(() => {
          order.push(4);
          queueMicrotask(() => order.push(6));
        });
      });
      queueMicrotask(() => {
        order.push(2);
        queueMicrotask(() => {
          order.push(5);
          queueMicrotask(() => {
            order.push(7);
            resolve();
          });
        });
      });
      queueMicrotask(() => {
        if (order.length > 3)
          reject(new Error("nested microtasks ran before the first queue drained"));
      });
    });
    assert.deepEqual(order, [0, 1, 2, 3, 4, 5, 6, 7]);
  });

  test("runs before timers scheduled in the same turn", async () => {
    const order = [];
    await new Promise(resolve => {
      setTimeout(() => {
        order.push("timer");
        resolve();
      }, 0);
      queueMicrotask(() => order.push("microtask"));
    });
    assert.deepEqual(order, ["microtask", "timer"]);
  });

  test("shares the Promise microtask queue", async () => {
    const order = [];
    await new Promise(resolve => {
      Promise.resolve().then(() => {
        order.push("promise-1");
        queueMicrotask(() => {
          order.push("queued-from-promise");
          resolve();
        });
      });
      queueMicrotask(() => order.push("queueMicrotask-1"));
      Promise.resolve().then(() => order.push("promise-2"));
    });
    assert.deepEqual(order, ["promise-1", "queueMicrotask-1", "promise-2", "queued-from-promise"]);
  });

  test("passes no arguments and uses Web callback this binding", async () => {
    const values = [];
    const stateKey = "__colloMicrotaskThisBinding";
    const sloppyCallback = Function(`
      const state = globalThis.${stateKey};
      state.values.push(arguments.length);
      state.values.push(this === globalThis);
      queueMicrotask(function () {
        "use strict";
        state.values.push(arguments.length);
        state.values.push(this);
        state.resolve();
      });
    `);
    await new Promise(resolve => {
      globalThis[stateKey] = { values, resolve };
      queueMicrotask(sloppyCallback);
    }).finally(() => {
      delete globalThis[stateKey];
    });
    assert.deepEqual(values, [0, true, 0, undefined]);
  });

  test("accepts callable objects", async () => {
    let called = false;
    const callback = new Proxy(function () {
      called = true;
    }, {});
    await new Promise(resolve => {
      queueMicrotask(callback);
      queueMicrotask(resolve);
    });
    assert.equal(called, true);
  });

  test("is receiver independent and ignores extra arguments", async () => {
    const q = queueMicrotask;
    const seen = [];
    assert.equal(q.call(null, () => seen.push("first"), "ignored"), undefined);
    assert.equal(q.call(undefined, () => seen.push("second")), undefined);
    await new Promise(resolve => q(resolve));
    assert.deepEqual(seen, ["first", "second"]);
  });

  test("global binding is writable and configurable", () => {
    const original = queueMicrotask;
    try {
      globalThis.queueMicrotask = function replacement(callback) {
        callback();
        return "replacement";
      };
      let called = false;
      assert.equal(queueMicrotask(() => {
        called = true;
      }), "replacement");
      assert.equal(called, true);

      assert.equal(delete globalThis.queueMicrotask, true);
      assert.equal(Object.hasOwn(globalThis, "queueMicrotask"), false);
    } finally {
      Object.defineProperty(globalThis, "queueMicrotask", {
        value: original,
        writable: true,
        enumerable: true,
        configurable: true,
      });
    }
  });
});
