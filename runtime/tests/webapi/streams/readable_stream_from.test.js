// Compatibility contract derived from WPT:
// - LayoutTests/imported/w3c/web-platform-tests/streams/readable-streams/from.any.js
//
// Bun v1.3.14 does not expose ReadableStream.from, so this fixture pins the
// WHATWG behavior directly until the compact WPT pass imports the upstream file.

async function flushAsyncEvents() {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
}

async function assertRejectsExactly(promise, expected) {
  try {
    await promise;
  } catch (error) {
    assert.equal(error, expected);
    return;
  }
  throw new Error("expected promise to reject");
}

async function assertRejectsWith(promise, constructor) {
  try {
    await promise;
  } catch (error) {
    assert(error instanceof constructor, `expected ${constructor.name}, got ${error && error.name}`);
    return;
  }
  throw new Error("expected promise to reject");
}

describe("ReadableStream.from", () => {
  test("is installed as a static WebAPI function", () => {
    assert.equal(typeof ReadableStream.from, "function");
    assert.equal(ReadableStream.from.length, 1);
    assert.equal(ReadableStream.from.name, "from");

    const descriptor = Object.getOwnPropertyDescriptor(ReadableStream, "from");
    assert.equal(descriptor.enumerable, true);
    assert.equal(descriptor.configurable, true);
    assert.equal(descriptor.writable, true);
  });

  for (const [label, factory] of [
    ["an array of values", () => ["a", "b"]],
    ["an array of promises", () => [Promise.resolve("a"), Promise.resolve("b")]],
    ["an array iterator", () => ["a", "b"][Symbol.iterator]()],
    ["a string", () => "ab"],
    ["a Set", () => new Set(["a", "b"])],
    ["a Set iterator", () => new Set(["a", "b"])[Symbol.iterator]()],
    [
      "a sync generator",
      () =>
        (function* () {
          yield "a";
          yield "b";
        })(),
    ],
    [
      "an async generator",
      () =>
        (async function* () {
          yield "a";
          yield "b";
        })(),
    ],
    [
      "a sync iterable of values",
      () => {
        const chunks = ["a", "b"];
        const iterator = {
          next() {
            return { done: chunks.length === 0, value: chunks.shift() };
          },
        };
        return { [Symbol.iterator]: () => iterator };
      },
    ],
    [
      "a sync iterable of promises",
      () => {
        const chunks = ["a", "b"];
        const iterator = {
          next() {
            return chunks.length === 0 ? { done: true } : { done: false, value: Promise.resolve(chunks.shift()) };
          },
        };
        return { [Symbol.iterator]: () => iterator };
      },
    ],
    [
      "an async iterable",
      () => {
        const chunks = ["a", "b"];
        const iterator = {
          next() {
            return Promise.resolve({ done: chunks.length === 0, value: chunks.shift() });
          },
        };
        return { [Symbol.asyncIterator]: () => iterator };
      },
    ],
    [
      "a ReadableStream",
      () =>
        new ReadableStream({
          start(controller) {
            controller.enqueue("a");
            controller.enqueue("b");
            controller.close();
          },
        }),
    ],
    [
      "a ReadableStream async iterator",
      () =>
        new ReadableStream({
          start(controller) {
            controller.enqueue("a");
            controller.enqueue("b");
            controller.close();
          },
        })[Symbol.asyncIterator](),
    ],
  ]) {
    test(`accepts ${label}`, async () => {
      const stream = ReadableStream.from(factory());
      assert.equal(stream.constructor, ReadableStream);

      const reader = stream.getReader();
      assert.deepEqual(await reader.read(), { value: "a", done: false });
      assert.deepEqual(await reader.read(), { value: "b", done: false });
      assert.deepEqual(await reader.read(), { value: undefined, done: true });
      await reader.closed;
    });
  }

  for (const [label, iterable] of [
    ["null", null],
    ["undefined", undefined],
    ["0", 0],
    ["NaN", NaN],
    ["true", true],
    ["{}", {}],
    ["Object.create(null)", Object.create(null)],
    ["a function", () => 42],
    ["a symbol", Symbol()],
    ["an object with a non-callable @@iterator method", { [Symbol.iterator]: 42 }],
    ["an object with a non-callable @@asyncIterator method", { [Symbol.asyncIterator]: 42 }],
    ["an object with an @@iterator method returning a non-object", { [Symbol.iterator]: () => 42 }],
    ["an object with an @@asyncIterator method returning a non-object", { [Symbol.asyncIterator]: () => 42 }],
  ]) {
    test(`throws on invalid iterables; specifically ${label}`, () => {
      assert.throws(() => ReadableStream.from(iterable), TypeError);
    });
  }

  test("rethrows errors from calling iterator methods and prefers @@asyncIterator", () => {
    const iteratorError = new Error("sync iterator error");
    assert.equal(
      assert.throws(() => ReadableStream.from({ [Symbol.iterator]: () => { throw iteratorError; } })),
      iteratorError,
    );

    const asyncError = new Error("async iterator error");
    assert.equal(
      assert.throws(() => ReadableStream.from({ [Symbol.asyncIterator]: () => { throw asyncError; } })),
      asyncError,
    );

    const preferredError = new Error("preferred async iterator error");
    const iterable = {
      [Symbol.iterator]() {
        throw new Error("@@iterator should not be called");
      },
      [Symbol.asyncIterator]() {
        throw preferredError;
      },
    };
    assert.equal(assert.throws(() => ReadableStream.from(iterable)), preferredError);
  });

  test("ignores null @@asyncIterator and falls back to @@iterator", () => {
    const error = new Error("fallback iterator error");
    const iterable = {
      [Symbol.asyncIterator]: null,
      [Symbol.iterator]() {
        throw error;
      },
    };
    assert.equal(assert.throws(() => ReadableStream.from(iterable)), error);
  });

  test("does not call next before first read", async () => {
    let nextCalls = 0;
    let nextArgs;
    const iterable = {
      async next(...args) {
        nextCalls += 1;
        nextArgs = args;
        return { value: "a", done: false };
      },
      [Symbol.asyncIterator]: () => iterable,
    };

    const reader = ReadableStream.from(iterable).getReader();
    await flushAsyncEvents();
    assert.equal(nextCalls, 0);

    assert.deepEqual(await reader.read(), { value: "a", done: false });
    assert.equal(nextCalls, 1);
    assert.deepEqual(nextArgs, []);
  });

  test("errors when next rejects, throws, or returns malformed results", async () => {
    const rejected = new Error("rejected next");
    const rejecting = {
      next() {
        return Promise.reject(rejected);
      },
      [Symbol.asyncIterator]: () => rejecting,
    };
    {
      const reader = ReadableStream.from(rejecting).getReader();
      await Promise.all([assertRejectsExactly(reader.read(), rejected), assertRejectsExactly(reader.closed, rejected)]);
    }

    const thrown = new Error("thrown next");
    const throwing = {
      next() {
        throw thrown;
      },
      [Symbol.asyncIterator]: () => throwing,
    };
    {
      const reader = ReadableStream.from(throwing).getReader();
      await Promise.all([assertRejectsExactly(reader.read(), thrown), assertRejectsExactly(reader.closed, thrown)]);
    }

    const nonObject = {
      next() {
        return Promise.resolve(42);
      },
      [Symbol.asyncIterator]: () => nonObject,
    };
    {
      const reader = ReadableStream.from(nonObject).getReader();
      await Promise.all([assertRejectsWith(reader.read(), TypeError), assertRejectsWith(reader.closed, TypeError)]);
    }

    const syncThrown = new Error("sync thrown next");
    const syncThrowing = {
      next() {
        throw syncThrown;
      },
      [Symbol.iterator]: () => syncThrowing,
    };
    {
      const reader = ReadableStream.from(syncThrowing).getReader();
      await Promise.all([assertRejectsExactly(reader.read(), syncThrown), assertRejectsExactly(reader.closed, syncThrown)]);
    }

    const syncNonObject = {
      next() {
        return 42;
      },
      [Symbol.iterator]: () => syncNonObject,
    };
    {
      const reader = ReadableStream.from(syncNonObject).getReader();
      await Promise.all([assertRejectsWith(reader.read(), TypeError), assertRejectsWith(reader.closed, TypeError)]);
    }

    const getterError = new Error("sync result getter");
    const syncThrowingGetter = {
      next() {
        return {
          get done() {
            throw getterError;
          },
        };
      },
      [Symbol.iterator]: () => syncThrowingGetter,
    };
    {
      const reader = ReadableStream.from(syncThrowingGetter).getReader();
      await Promise.all([assertRejectsExactly(reader.read(), getterError), assertRejectsExactly(reader.closed, getterError)]);
    }
  });

  test("closes sync iterator when a yielded promise rejects", async () => {
    const error = new Error("rejected sync value");
    let returnCalls = 0;
    const iterable = {
      next() {
        return { value: Promise.reject(error), done: false };
      },
      return() {
        returnCalls += 1;
        return { done: true };
      },
      [Symbol.iterator]: () => iterable,
    };

    const reader = ReadableStream.from(iterable).getReader();
    await Promise.all([assertRejectsExactly(reader.read(), error), assertRejectsExactly(reader.closed, error)]);
    assert.equal(returnCalls, 1);
  });

  test("stalls when next never settles", async () => {
    const iterable = {
      next() {
        return new Promise(() => {});
      },
      [Symbol.asyncIterator]: () => iterable,
    };

    const reader = ReadableStream.from(iterable).getReader();
    let settled = false;
    reader.read().then(
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

  test("cancelling calls and awaits return", async () => {
    const reason = new Error("cancel reason");
    let returnCalls = 0;
    let returnArgs;
    let resolveReturn;
    const iterable = {
      next() {
        throw new Error("next should not be called");
      },
      async return(...args) {
        returnCalls += 1;
        returnArgs = args;
        await new Promise(resolve => {
          resolveReturn = resolve;
        });
        return { done: true };
      },
      [Symbol.asyncIterator]: () => iterable,
    };

    const reader = ReadableStream.from(iterable).getReader();
    let cancelResolved = false;
    const cancelPromise = reader.cancel(reason).then(() => {
      cancelResolved = true;
    });
    await flushAsyncEvents();
    assert.equal(returnCalls, 1);
    assert.deepEqual(returnArgs, [reason]);
    assert.equal(cancelResolved, false);
    resolveReturn();
    await Promise.all([cancelPromise, reader.closed]);
  });

  test("does not call return on normal completion", async () => {
    let nextCalls = 0;
    let returnCalls = 0;
    const iterable = {
      async next() {
        nextCalls += 1;
        return { value: undefined, done: true };
      },
      async return() {
        returnCalls += 1;
      },
      [Symbol.asyncIterator]: () => iterable,
    };

    const reader = ReadableStream.from(iterable).getReader();
    assert.deepEqual(await reader.read(), { value: undefined, done: true });
    assert.equal(nextCalls, 1);
    await reader.closed;
    assert.equal(returnCalls, 0);
  });

  test("cancel handles missing, invalid, rejected, thrown, and malformed return", async () => {
    const reason = new Error("cancel reason");
    {
      const iterable = { next() {}, [Symbol.asyncIterator]: () => iterable };
      const reader = ReadableStream.from(iterable).getReader();
      await Promise.all([reader.cancel(reason), reader.closed]);
    }
    {
      const iterable = { next() {}, return: 42, [Symbol.asyncIterator]: () => iterable };
      const reader = ReadableStream.from(iterable).getReader();
      await assertRejectsWith(reader.cancel(reason), TypeError);
      await reader.closed;
    }
    {
      const error = new Error("return rejected");
      const iterable = {
        next() {},
        async return() {
          throw error;
        },
        [Symbol.asyncIterator]: () => iterable,
      };
      const reader = ReadableStream.from(iterable).getReader();
      await assertRejectsExactly(reader.cancel(reason), error);
      await reader.closed;
    }
    {
      const error = new Error("return thrown");
      const iterable = {
        next() {},
        return() {
          throw error;
        },
        [Symbol.asyncIterator]: () => iterable,
      };
      const reader = ReadableStream.from(iterable).getReader();
      await assertRejectsExactly(reader.cancel(reason), error);
      await reader.closed;
    }
    {
      const iterable = {
        next() {},
        async return() {
          return 42;
        },
        [Symbol.asyncIterator]: () => iterable,
      };
      const reader = ReadableStream.from(iterable).getReader();
      await assertRejectsWith(reader.cancel(reason), TypeError);
      await reader.closed;
    }
  });

  test("handles reentrant read and cancel inside next", async () => {
    let reader;
    let nextCalls = 0;
    const values = ["a", "b", "c"];
    const reading = {
      async next() {
        nextCalls += 1;
        if (nextCalls === 1) {
          reader.read();
        }
        return { value: values.shift(), done: false };
      },
      [Symbol.asyncIterator]: () => reading,
    };
    reader = ReadableStream.from(reading).getReader();
    assert.deepEqual(await reader.read(), { value: "a", done: false });
    await flushAsyncEvents();
    assert.equal(nextCalls, 2);
    assert.deepEqual(await reader.read(), { value: "c", done: false });

    let returnCalls = 0;
    const cancelling = {
      async next() {
        await cancelReader.cancel();
        assert.equal(returnCalls, 1);
        return { value: "hidden", done: false };
      },
      async return() {
        returnCalls += 1;
        return { done: true };
      },
      [Symbol.asyncIterator]: () => cancelling,
    };
    const cancelReader = ReadableStream.from(cancelling).getReader();
    assert.deepEqual(await cancelReader.read(), { value: undefined, done: true });
    await cancelReader.closed;
  });

  test("handles reader.cancel inside return", async () => {
    let returnCalls = 0;
    let reader;
    const iterable = {
      next() {
        throw new Error("next should not be called");
      },
      async return() {
        returnCalls += 1;
        await reader.cancel();
        return { done: true };
      },
      [Symbol.asyncIterator]: () => iterable,
    };

    reader = ReadableStream.from(iterable).getReader();
    await reader.cancel();
    assert.equal(returnCalls, 1);
    await reader.closed;
  });

  test("late next fulfillment after cancel does not inspect iterator result getters", async () => {
    let resolveNext;
    let doneGetterCalls = 0;
    const iterable = {
      next() {
        return new Promise(resolve => {
          resolveNext = resolve;
        });
      },
      return() {
        return { done: true };
      },
      [Symbol.asyncIterator]: () => iterable,
    };

    const reader = ReadableStream.from(iterable).getReader();
    const readPromise = reader.read();
    await flushAsyncEvents();
    await reader.cancel();
    resolveNext({
      get done() {
        doneGetterCalls += 1;
        throw new Error("late done getter should not run");
      },
    });
    await readPromise;
    await flushAsyncEvents();
    assert.equal(doneGetterCalls, 0);
  });

  test("array iterator observes push while reading", async () => {
    const array = ["a", "b"];
    const reader = ReadableStream.from(array).getReader();
    assert.deepEqual(await reader.read(), { value: "a", done: false });
    assert.deepEqual(await reader.read(), { value: "b", done: false });
    array.push("c");
    assert.deepEqual(await reader.read(), { value: "c", done: false });
    assert.deepEqual(await reader.read(), { value: undefined, done: true });
    await reader.closed;
  });
});
