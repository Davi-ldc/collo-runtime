// Collo compatibility contract for WHATWG queuing strategies.
// Bun keeps these in the broader Web Streams surface; this file isolates the
// strategy integration points that affect backpressure and byte accounting.

async function flushAsyncEvents() {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
}

function assertRejects(promise, expectedConstructor) {
  return promise.then(
    () => {
      throw new Error("expected promise to reject");
    },
    error => {
      assert(error instanceof expectedConstructor);
      return error;
    },
  );
}

function assertRejectsSame(promise, expectedReason) {
  return promise.then(
    () => {
      throw new Error("expected promise to reject");
    },
    error => {
      assert.equal(error, expectedReason);
      return error;
    },
  );
}

function assertThrowsSame(callback, expectedError) {
  try {
    callback();
  } catch (error) {
    assert.equal(error, expectedError);
    return;
  }
  throw new Error("expected callback to throw");
}

describe("QueuingStrategy globals", () => {
  test("constructors and prototypes expose the expected shape", () => {
    assert.equal(typeof ByteLengthQueuingStrategy, "function");
    assert.equal(typeof CountQueuingStrategy, "function");

    assert.throws(() => ByteLengthQueuingStrategy({ highWaterMark: 1 }), TypeError);
    assert.throws(() => CountQueuingStrategy({ highWaterMark: 1 }), TypeError);

    const byteLength = new ByteLengthQueuingStrategy({ highWaterMark: 8 });
    const count = new CountQueuingStrategy({ highWaterMark: 3 });

    assert(byteLength instanceof ByteLengthQueuingStrategy);
    assert(count instanceof CountQueuingStrategy);
    assert.equal(byteLength.highWaterMark, 8);
    assert.equal(count.highWaterMark, 3);
    assert.equal(byteLength.size({ byteLength: 7 }), 7);
    assert.equal(byteLength.size({ byteLength: undefined }), undefined);
    // The size function itself is this-agnostic once obtained from an instance.
    assert.equal(count.size.call(undefined, "ignored"), 1);

    // The size getter brand-checks its receiver, so reading it directly off
    // the prototype throws like in browsers.
    assert.throws(() => CountQueuingStrategy.prototype.size, TypeError);
    assert.throws(
      () => Reflect.get(ByteLengthQueuingStrategy.prototype, "highWaterMark", count),
      TypeError,
    );
    assert.throws(
      () => Reflect.get(CountQueuingStrategy.prototype, "highWaterMark", byteLength),
      TypeError,
    );

    const byteLengthHighWaterMarkDescriptor = Object.getOwnPropertyDescriptor(
      ByteLengthQueuingStrategy.prototype,
      "highWaterMark",
    );
    assert.equal(typeof byteLengthHighWaterMarkDescriptor.get, "function");
    assert.equal(byteLengthHighWaterMarkDescriptor.set, undefined);
    assert.equal(byteLengthHighWaterMarkDescriptor.enumerable, true);
    assert.equal(byteLengthHighWaterMarkDescriptor.configurable, true);

    const byteLengthSizeDescriptor = Object.getOwnPropertyDescriptor(
      ByteLengthQueuingStrategy.prototype,
      "size",
    );
    // Per Web IDL, size is a readonly attribute: an accessor whose getter
    // returns the per-realm cached size function.
    assert.equal(typeof byteLengthSizeDescriptor.get, "function");
    assert.equal(byteLengthSizeDescriptor.set, undefined);
    assert.equal(byteLengthSizeDescriptor.enumerable, true);
    assert.equal(byteLengthSizeDescriptor.configurable, true);
    assert.equal(typeof byteLength.size, "function");
    assert.equal(byteLength.size.name, "size");
    assert.equal(byteLength.size.length, 1);
    assert.equal("prototype" in byteLength.size, false);
    assert.equal(byteLength.size, byteLength.size);
    assert.equal(byteLength.size, new ByteLengthQueuingStrategy({ highWaterMark: 1 }).size);
    assert.throws(() => Reflect.get(ByteLengthQueuingStrategy.prototype, "size", count), TypeError);

    const countHighWaterMarkDescriptor = Object.getOwnPropertyDescriptor(
      CountQueuingStrategy.prototype,
      "highWaterMark",
    );
    assert.equal(typeof countHighWaterMarkDescriptor.get, "function");
    assert.equal(countHighWaterMarkDescriptor.set, undefined);
    assert.equal(countHighWaterMarkDescriptor.enumerable, true);
    assert.equal(countHighWaterMarkDescriptor.configurable, true);

    const countSizeDescriptor = Object.getOwnPropertyDescriptor(
      CountQueuingStrategy.prototype,
      "size",
    );
    assert.equal(typeof countSizeDescriptor.get, "function");
    assert.equal(countSizeDescriptor.set, undefined);
    assert.equal(countSizeDescriptor.enumerable, true);
    assert.equal(countSizeDescriptor.configurable, true);
    assert.equal(typeof count.size, "function");
    assert.equal(count.size.name, "size");
    assert.equal(count.size.length, 0);
    assert.equal("prototype" in count.size, false);
    assert.equal(count.size, count.size);
    assert.equal(count.size, new CountQueuingStrategy({ highWaterMark: 1 }).size);
    assert.throws(() => Reflect.get(CountQueuingStrategy.prototype, "size", byteLength), TypeError);

    assert.deepEqual(Object.keys(ByteLengthQueuingStrategy.prototype), ["highWaterMark", "size"]);
    assert.deepEqual(Object.keys(CountQueuingStrategy.prototype), ["highWaterMark", "size"]);
    assert.equal(Object.prototype.toString.call(byteLength), "[object ByteLengthQueuingStrategy]");
    assert.equal(Object.prototype.toString.call(count), "[object CountQueuingStrategy]");
  });

  test("constructor requires an object with highWaterMark", () => {
    assert.throws(() => new CountQueuingStrategy(), TypeError);
    assert.throws(() => new CountQueuingStrategy({}), TypeError);
    assert.throws(() => new ByteLengthQueuingStrategy(null), TypeError);

    assert.equal(new CountQueuingStrategy({ highWaterMark: Infinity }).highWaterMark, Infinity);
    assert(Number.isNaN(new CountQueuingStrategy({ highWaterMark: NaN }).highWaterMark));
    assert.equal(new CountQueuingStrategy({ highWaterMark: -1 }).highWaterMark, -1);
  });
});

describe("ReadableStream strategy integration", () => {
  test("default stream uses CountQueuingStrategy inherited members", () => {
    let controller;
    const stream = new ReadableStream(
      {
        start(value) {
          controller = value;
        },
      },
      new CountQueuingStrategy({ highWaterMark: 3 }),
    );

    assert.equal(controller.desiredSize, 3);
    controller.enqueue("a");
    assert.equal(controller.desiredSize, 2);
    assert.equal(stream.locked, false);
  });

  test("default stream uses ByteLengthQueuingStrategy inherited members", () => {
    let controller;
    new ReadableStream(
      {
        start(value) {
          controller = value;
        },
      },
      new ByteLengthQueuingStrategy({ highWaterMark: 8 }),
    );

    assert.equal(controller.desiredSize, 8);
    controller.enqueue(new Uint8Array([1, 2, 3]));
    assert.equal(controller.desiredSize, 5);
  });

  test("byte streams default to zero highWaterMark and reject a size strategy", () => {
    let controller;
    new ReadableStream({
      type: "bytes",
      start(value) {
        controller = value;
      },
    });
    assert.equal(controller.desiredSize, 0);

    assert.throws(
      () => new ReadableStream({ type: "bytes" }, new ByteLengthQueuingStrategy({ highWaterMark: 8 })),
      RangeError,
    );
  });

  test("stream constructors validate highWaterMark and size at use time", () => {
    // Per Web IDL, null converts to an empty QueuingStrategy dictionary and
    // explicitly-undefined callbacks count as absent.
    new ReadableStream({}, null);
    new ReadableStream({ start: undefined });
    assert.throws(() => new ReadableStream({ start: null }), TypeError);
    assert.throws(() => new ReadableStream({ start: 1 }), TypeError);
    assert.throws(() => new ReadableStream({}, new CountQueuingStrategy({ highWaterMark: -1 })), RangeError);
    assert.throws(() => new ReadableStream({}, new CountQueuingStrategy({ highWaterMark: NaN })), RangeError);
    new ReadableStream({}, new CountQueuingStrategy({ highWaterMark: Infinity }));
    assert.throws(() => new ReadableStream({}, { highWaterMark: 1, size: 1 }), TypeError);
  });

  test("strategy size failure errors the readable stream", async () => {
    let controller;
    const stream = new ReadableStream(
      {
        start(value) {
          controller = value;
        },
      },
      { highWaterMark: 1, size: () => -1 },
    );

    assert.throws(() => controller.enqueue("x"), RangeError);
    const reader = stream.getReader();
    await assertRejects(reader.read(), RangeError);
  });
});

describe("WritableStream strategy integration", () => {
  test("writer desiredSize uses CountQueuingStrategy", async () => {
    let releaseWrite;
    const stream = new WritableStream(
      {
        write() {
          return new Promise(resolve => {
            releaseWrite = resolve;
          });
        },
      },
      new CountQueuingStrategy({ highWaterMark: 2 }),
    );

    const writer = stream.getWriter();
    assert.equal(writer.desiredSize, 2);
    const first = writer.write("a");
    assert.equal(writer.desiredSize, 1);
    releaseWrite();
    await first;
    assert.equal(writer.desiredSize, 2);
  });

  test("writer desiredSize uses ByteLengthQueuingStrategy", async () => {
    let releaseWrite;
    const stream = new WritableStream(
      {
        write() {
          return new Promise(resolve => {
            releaseWrite = resolve;
          });
        },
      },
      new ByteLengthQueuingStrategy({ highWaterMark: 8 }),
    );

    const writer = stream.getWriter();
    assert.equal(writer.desiredSize, 8);
    const first = writer.write(new Uint8Array([1, 2, 3]));
    assert.equal(writer.desiredSize, 5);
    releaseWrite();
    await first;
    assert.equal(writer.desiredSize, 8);
  });

  test("strategy size failures reject write", async () => {
    const stream = new WritableStream({}, { highWaterMark: 1, size: () => -1 });
    const writer = stream.getWriter();
    await assertRejects(writer.write("x"), RangeError);
    await assertRejects(writer.closed, RangeError);
    await assertRejects(writer.write("y"), RangeError);
  });

  test("non-callable defined callbacks are rejected; null strategy and undefined callbacks are not", () => {
    // Per Web IDL, null converts to an empty QueuingStrategy dictionary and
    // explicitly-undefined callbacks count as absent.
    new WritableStream({}, null);
    new WritableStream({ start: undefined });
    assert.throws(() => new WritableStream({ write: null }), TypeError);
    assert.throws(() => new WritableStream({ close: 1 }), TypeError);
    assert.throws(() => new WritableStream({ abort: "x" }), TypeError);
  });

  test("strategy getters are observed before sink callbacks, highWaterMark first", () => {
    // Web IDL converts the QueuingStrategy argument (highWaterMark before
    // size, lexicographic order) before the constructor steps read the
    // underlying sink members.
    const sizeError = new Error("size getter");
    let observed = [];
    assertThrowsSame(
      () =>
        new WritableStream(
          {
            get start() {
              observed.push("start");
              throw new Error("wrong error");
            },
          },
          {
            get size() {
              observed.push("size");
              throw sizeError;
            },
          },
        ),
      sizeError,
    );
    assert.deepEqual(observed, ["size"]);

    const hwmError = new Error("highWaterMark getter");
    observed = [];
    assertThrowsSame(
      () =>
        new WritableStream(
          {},
          {
            get highWaterMark() {
              observed.push("highWaterMark");
              throw hwmError;
            },
            get size() {
              observed.push("size");
              return undefined;
            },
          },
        ),
      hwmError,
    );
    assert.deepEqual(observed, ["highWaterMark"]);
  });

  test("write rechecks stream state after a reentrant size callback", async () => {
    let writer;
    let closePromise;
    const stream = new WritableStream(
      {},
      {
        highWaterMark: 1,
        size() {
          closePromise = writer.close();
          return 1;
        },
      },
    );

    writer = stream.getWriter();
    await assertRejects(writer.write("x"), TypeError);
    await closePromise;
    await writer.closed;
  });

  test("write rejects instead of enqueueing while abort is erroring", async () => {
    let writer;
    const reason = new Error("abort from size");
    let reentrantWrite;
    const stream = new WritableStream(
      {
        abort() {
          reentrantWrite = writer.write("during abort");
          return new Promise(() => {});
        },
      },
    );

    writer = stream.getWriter();
    writer.abort(reason);
    await assertRejectsSame(reentrantWrite, reason);
    await assertRejectsSame(writer.closed, reason);
    // Per spec, WritableStreamClose on an errored stream rejects with a fresh
    // TypeError rather than the stored error.
    await assertRejects(writer.close(), TypeError);
  });

  test("abort callback throw rejects the abort promise", async () => {
    const reason = new Error("abort algorithm failed");
    const stream = new WritableStream({
      abort() {
        throw reason;
      },
    });

    const writer = stream.getWriter();
    await assertRejectsSame(writer.abort("abort reason"), reason);
  });

  test("controller.error inside abort does not settle abort before the abort algorithm", async () => {
    let controller;
    const stream = new WritableStream({
      start(value) {
        controller = value;
      },
      abort() {
        controller.error("inner");
        return new Promise(() => {});
      },
    });

    const writer = stream.getWriter();
    let settled = false;
    writer.abort("outer").then(
      () => {
        settled = true;
      },
      () => {
        settled = true;
      },
    );
    await flushAsyncEvents();
    assert.equal(settled, false);
  });

  test("underlying sink type is rejected only when defined", () => {
    // Per Web IDL, an explicitly-undefined member counts as absent.
    new WritableStream({ type: undefined });
    assert.throws(() => new WritableStream({ type: null }), RangeError);
    assert.throws(() => new WritableStream({ type: "bytes" }), RangeError);
  });
});

describe("TransformStream strategy integration", () => {
  test("null transformer is treated as an empty transformer", () => {
    const stream = new TransformStream(null);
    assert(stream.readable instanceof ReadableStream);
    assert(stream.writable instanceof WritableStream);
  });

  test("null strategies convert to empty dictionaries", () => {
    // Per Web IDL, null converts to an empty QueuingStrategy dictionary.
    new TransformStream({}, null, {});
    new TransformStream({}, {}, null);
  });

  test("non-callable defined transformer callbacks are rejected; undefined ones are not", () => {
    new TransformStream({ start: undefined });
    assert.throws(() => new TransformStream({ transform: null }), TypeError);
    assert.throws(() => new TransformStream({ flush: 1 }), TypeError);
  });

  test("transformer members are read in lexicographic order", () => {
    // Dictionary conversion reads cancel, flush, readableType, start,
    // transform, writableType in order, so the readableType getter runs (and
    // its error wins) before the start getter is ever observed.
    const observed = [];
    const readableTypeError = new Error("readableType getter");
    const transformer = {
      get start() {
        observed.push("start");
        throw new Error("wrong error");
      },
      get readableType() {
        observed.push("readableType");
        throw readableTypeError;
      },
    };

    assertThrowsSame(() => new TransformStream(transformer), readableTypeError);
    assert.deepEqual(observed, ["readableType"]);
  });

  test("transformer callback validation stops before later callback getters", () => {
    const observed = [];
    const transformer = {
      get start() {
        observed.push("start");
        return 1;
      },
      get transform() {
        observed.push("transform");
        throw new Error("wrong error");
      },
    };

    assert.throws(() => new TransformStream(transformer), TypeError);
    assert.deepEqual(observed, ["start"]);
  });

  test("default readable side starts with zero highWaterMark", async () => {
    const observed = [];
    const stream = new TransformStream({
      transform(chunk, controller) {
        observed.push(controller.desiredSize);
        controller.enqueue(chunk);
        observed.push(controller.desiredSize);
      },
    });

    const writer = stream.writable.getWriter();
    const pending = writer.write("x");
    await flushAsyncEvents();
    // Per spec, a zero highWaterMark readable side starts with backpressure,
    // so the transform does not run until the readable side pulls.
    assert.deepEqual(observed, []);

    const reader = stream.readable.getReader();
    assert.equal((await reader.read()).value, "x");
    // The pull cleared backpressure and ran the deferred transform; the chunk
    // went straight to the pending read request, so desiredSize stayed 0.
    assert.deepEqual(observed, [0, 0]);
    await pending;
  });

  test("readable side uses readable strategy highWaterMark and size", async () => {
    const observed = [];
    const stream = new TransformStream(
      {
        transform(chunk, controller) {
          observed.push(controller.desiredSize);
          controller.enqueue(new Uint8Array(chunk));
          observed.push(controller.desiredSize);
        },
      },
      new CountQueuingStrategy({ highWaterMark: 1 }),
      new ByteLengthQueuingStrategy({ highWaterMark: 8 }),
    );

    const writer = stream.writable.getWriter();
    const pending = writer.write([1, 2, 3]);
    await flushAsyncEvents();
    assert.deepEqual(observed, [8, 5]);

    const reader = stream.readable.getReader();
    assert.deepEqual(Array.from((await reader.read()).value), [1, 2, 3]);
    await pending;
  });

  test("writable strategy is observed before readable strategy", () => {
    // Web IDL converts arguments left to right: the writable strategy is the
    // second argument and the readable strategy the third.
    const observed = [];
    new TransformStream(
      {},
      {
        get highWaterMark() {
          observed.push("writable.highWaterMark");
          return 1;
        },
        get size() {
          observed.push("writable.size");
          return undefined;
        },
      },
      {
        get highWaterMark() {
          observed.push("readable.highWaterMark");
          return 0;
        },
        get size() {
          observed.push("readable.size");
          return undefined;
        },
      },
    );
    assert.deepEqual(observed, [
      "writable.highWaterMark",
      "writable.size",
      "readable.highWaterMark",
      "readable.size",
    ]);
  });

  test("readableType and writableType are rejected only when defined", () => {
    // Per Web IDL, an explicitly-undefined member counts as absent.
    new TransformStream({ readableType: undefined });
    new TransformStream({ writableType: undefined });
    assert.throws(() => new TransformStream({ readableType: "bytes" }), RangeError);
    assert.throws(() => new TransformStream({ writableType: "bytes" }), RangeError);
  });
});
