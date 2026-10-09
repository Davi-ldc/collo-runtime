// Collo compatibility contract derived from Bun v1.3.14:
// - reference/bun-v1.3.14/test/js/web/streams/streams.test.js
// - reference/bun-v1.3.14/test/js/web/fetch/body-stream.test.ts
// - reference/bun-v1.3.14/test/js/web/fetch/body-clone.test.ts
// - reference/bun-v1.3.14/test/js/web/fetch/body-async-iterator.test.ts
// - reference/bun-v1.3.14/test/js/web/streams/readable-stream-blob-consumed.test.ts
// - reference/bun-v1.3.14/test/js/web/streams/compression.test.ts
// - reference/bun-v1.3.14/test/js/node/test/parallel/test-whatwg-webstreams-compression.js

async function assertRejects(promise, expectedConstructor) {
  try {
    await promise;
  } catch (error) {
    assert(error instanceof expectedConstructor);
    return error;
  }
  throw new Error("expected promise to reject");
}

function concatUint8(chunks) {
  let byteLength = 0;
  for (const chunk of chunks) byteLength += chunk.byteLength;

  const bytes = new Uint8Array(byteLength);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

async function collectBytes(stream) {
  const chunks = [];
  const reader = stream.getReader();
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    assert(value instanceof Uint8Array);
    chunks.push(value);
  }
  reader.releaseLock();
  return concatUint8(chunks);
}

async function waitForMicrotaskCondition(label, predicate) {
  for (let index = 0; index < 16; index++) {
    await Promise.resolve();
    if (predicate()) return;
  }
  throw new Error(`timed out waiting for ${label}`);
}

describe("ReadableStream core", () => {
  test("constructs with start/enqueue/close and reads chunks", async () => {
    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue("a");
        controller.enqueue("b");
        controller.close();
      },
    });

    assert(stream instanceof ReadableStream);
    assert.equal(stream.locked, false);

    const reader = stream.getReader();
    assert.equal(stream.locked, true);
    assert.deepEqual(await reader.read(), { value: "a", done: false });
    assert.deepEqual(await reader.read(), { value: "b", done: false });
    assert.deepEqual(await reader.read(), { value: undefined, done: true });
    await reader.closed;
    reader.releaseLock();
    assert.equal(stream.locked, false);
  });

  test("pull runs when a pending read needs data", async () => {
    let pulls = 0;
    const stream = new ReadableStream({
      pull(controller) {
        pulls += 1;
        controller.enqueue(`chunk-${pulls}`);
        controller.close();
      },
    });

    const reader = stream.getReader();
    assert.deepEqual(await reader.read(), { value: "chunk-1", done: false });
    assert.deepEqual(await reader.read(), { value: undefined, done: true });
    assert.equal(pulls, 1);
  });

  test("pull waits for an asynchronous start promise", async () => {
    let resolveStart;
    let pulls = 0;
    const stream = new ReadableStream({
      start() {
        return new Promise(resolve => {
          resolveStart = resolve;
        });
      },
      pull(controller) {
        pulls += 1;
        controller.enqueue("ready");
        controller.close();
      },
    });

    const reader = stream.getReader();
    const pending = reader.read();
    await Promise.resolve();
    assert.equal(pulls, 0);
    resolveStart();
    assert.deepEqual(await pending, { value: "ready", done: false });
    assert.equal(pulls, 1);
  });

  test("cancel forwards the reason to the underlying source", async () => {
    let reason = undefined;
    const stream = new ReadableStream({
      cancel(value) {
        reason = value;
      },
    });

    await stream.cancel("stop");
    assert.equal(reason, "stop");
  });

  test("cancel resolves undefined even when underlying cancel returns a value", async () => {
    const sync = new ReadableStream({
      cancel() {
        return "hidden";
      },
    });
    assert.equal(await sync.cancel("stop"), undefined);

    const async = new ReadableStream({
      cancel() {
        return Promise.resolve("hidden");
      },
    });
    assert.equal(await async.cancel("stop"), undefined);
  });

  test("tee duplicates already queued default chunks", async () => {
    const [left, right] = new ReadableStream({
      start(controller) {
        controller.enqueue("a");
        controller.enqueue("b");
        controller.close();
      },
    }).tee();

    async function collect(stream) {
      let output = "";
      for await (const chunk of stream) output += chunk;
      return output;
    }

    assert.equal(await collect(left), "ab");
    assert.equal(await collect(right), "ab");
  });

  test("tee duplicates chunks produced by future pulls", async () => {
    let pulls = 0;
    const [left, right] = new ReadableStream({
      pull(controller) {
        pulls += 1;
        controller.enqueue(String(pulls));
        if (pulls === 2) controller.close();
      },
    }).tee();

    async function collect(stream) {
      let output = "";
      for await (const chunk of stream) output += chunk;
      return output;
    }

    assert.equal(await collect(left), "12");
    assert.equal(await collect(right), "12");
    assert.equal(pulls, 2);
  });

  test("tee cancels original source only after both branches cancel", async () => {
    let cancel_reason;
    const [left, right] = new ReadableStream({
      cancel(reason) {
        cancel_reason = reason;
      },
    }).tee();

    await left.cancel("left reason");
    assert.equal(cancel_reason, undefined);

    await right.cancel("right reason");
    assert.deepEqual(cancel_reason, ["left reason", "right reason"]);
  });

  test("tee does not eagerly drain a default source without branch demand", async () => {
    let resolveStart;
    let pulls = 0;
    const stream = new ReadableStream({
      start() {
        return new Promise(resolve => {
          resolveStart = resolve;
        });
      },
      pull(controller) {
        pulls += 1;
        controller.enqueue(String(pulls));
        if (pulls === 4) controller.close();
      },
    });

    const [left, right] = stream.tee();
    resolveStart();
    for (let i = 0; i < 8; i++) await Promise.resolve();
    assert.equal(pulls, 1);

    const leftReader = left.getReader();
    assert.deepEqual(await leftReader.read(), { value: "1", done: false });
    for (let i = 0; i < 8; i++) await Promise.resolve();
    assert.equal(pulls, 2);

    const rightReader = right.getReader();
    assert.deepEqual(await rightReader.read(), { value: "1", done: false });
    assert.deepEqual(await rightReader.read(), { value: "2", done: false });
  });

  test("async iterator consumes chunks", async () => {
    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue("hello");
        controller.enqueue("world");
        controller.close();
      },
    });

    const chunks = [];
    for await (const chunk of stream) chunks.push(chunk);
    assert.equal(chunks.join(""), "helloworld");
  });

  test("async iterator releases reader on normal completion", async () => {
    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue("done");
        controller.close();
      },
    });

    const chunks = [];
    for await (const chunk of stream) chunks.push(chunk);
    assert.equal(chunks.join(""), "done");
    assert.equal(stream.locked, false);
    assert.deepEqual(await stream.getReader().read(), { value: undefined, done: true });
  });

  test("async iterator releases reader on rejection", async () => {
    const error = new Error("boom");
    const stream = new ReadableStream({
      start(controller) {
        controller.error(error);
      },
    });

    const observed = await (async () => {
      try {
        for await (const _ of stream) {
        }
        return "resolved";
      } catch (caught) {
        return caught;
      }
    })();

    assert.equal(observed, error);
    assert.equal(stream.locked, false);
  });

  test("async iterator return waits for cancel to settle", async () => {
    let resolveCancel;
    let cancelSettled = false;
    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue("x");
      },
      cancel() {
        return new Promise(resolve => {
          resolveCancel = () => {
            cancelSettled = true;
            resolve("ignored");
          };
        });
      },
    });

    const iterator = stream[Symbol.asyncIterator]();
    assert.deepEqual(await iterator.next(), { value: "x", done: false });
    const returned = iterator.return("stop").then(result => ({ result, cancelSettled }));
    await Promise.resolve();
    assert.equal(cancelSettled, false);
    resolveCancel();
    assert.deepEqual(await returned, {
      result: { value: "stop", done: true },
      cancelSettled: true,
    });
    assert.equal(stream.locked, false);
  });

  test("constructor uses highWaterMark and size strategy", () => {
    let controller;
    const stream = new ReadableStream(
      {
        start(value) {
          controller = value;
        },
      },
      {
        highWaterMark: 8,
        size(chunk) {
          return chunk.length;
        },
      },
    );

    assert.equal(controller.desiredSize, 8);
    controller.enqueue("abc");
    assert.equal(controller.desiredSize, 5);
    assert.equal(stream.locked, false);
  });

  test("reentrant close and error inside the size callback do not make enqueue throw", async () => {
    // Per WPT reentrant-strategies, close() inside size() with an empty queue
    // closes the stream and the chunk being enqueued is silently swallowed.
    let controller;
    const closed = new ReadableStream(
      {
        start(value) {
          controller = value;
        },
      },
      {
        size() {
          controller.close();
          return 1;
        },
      },
    );

    controller.enqueue("swallowed");
    assert.equal(controller.desiredSize, 0);
    assert.deepEqual(await closed.getReader().read(), { value: undefined, done: true });

    // error() inside size() errors the stream; enqueue still does not throw
    // and reads reject with the stored error.
    let erroredController;
    const error = new Error("size failed later");
    const errored = new ReadableStream(
      {
        start(value) {
          erroredController = value;
        },
      },
      {
        size() {
          erroredController.error(error);
          return 1;
        },
      },
    );

    erroredController.enqueue("swallowed");
    assert.equal(erroredController.desiredSize, null);
    assert.equal(await errored.getReader().read().then(() => "resolved", caught => caught), error);
  });

  test("close requested inside the size callback still delivers the queued chunk", async () => {
    let controller;
    let closeInSize = false;
    const stream = new ReadableStream(
      {
        start(value) {
          controller = value;
        },
      },
      {
        size() {
          if (closeInSize) controller.close();
          return 1;
        },
      },
    );

    controller.enqueue("a");
    closeInSize = true;
    controller.enqueue("b");

    const reader = stream.getReader();
    assert.deepEqual(await reader.read(), { value: "a", done: false });
    assert.deepEqual(await reader.read(), { value: "b", done: false });
    assert.deepEqual(await reader.read(), { value: undefined, done: true });
  });

  test("constructor supports byte streams and rejects invalid strategy", () => {
    const byteStream = new ReadableStream({
      type: "bytes",
      start(controller) {
        controller.enqueue(new Uint8Array([1, 2, 3]));
        controller.close();
      },
    });

    assert(byteStream instanceof ReadableStream);
    assert.throws(() => new ReadableStream({}, 1), TypeError);
    assert.throws(() => new ReadableStream({}, { highWaterMark: -1 }), RangeError);
    assert.throws(() => new ReadableStream({}, { size: 1 }), TypeError);
  });

  test("Bun port: byte streams exist globally", () => {
    assert.equal(typeof ReadableStreamBYOBReader, "function");
    assert.equal(typeof ReadableStreamBYOBRequest, "function");
    assert.equal(typeof ReadableByteStreamController, "function");
  });

  test("Bun port: ReadableStream bytes works with default reader", async () => {
    const stream = new ReadableStream({
      type: "bytes",
      start(controller) {
        controller.enqueue(new Uint8Array([97, 98, 100, 101, 102, 103, 104]));
        controller.close();
      },
      pull() {},
      cancel() {},
    });

    const chunk = await stream.getReader().read();
    assert.deepEqual(Array.from(chunk.value), [97, 98, 100, 101, 102, 103, 104]);
    assert.equal(chunk.done, false);
  });

  test("ReadableByteStreamController.enqueue transfers byte chunks for default readers", async () => {
    let original = new Uint8Array([1, 2, 3]);
    const stream = new ReadableStream({
      type: "bytes",
      start(controller) {
        controller.enqueue(original);
        assert.equal(original.byteLength, 0);
        controller.close();
      },
    });

    const reader = stream.getReader();
    const first = await reader.read();
    assert.equal(first.done, false);
    assert.deepEqual(Array.from(first.value), [1, 2, 3]);
    assert.deepEqual(await reader.read(), { value: undefined, done: true });
  });

  test("Bun port: BYOB reader fills caller-provided views", async () => {
    let pulls = 0;
    const stream = new ReadableStream({
      type: "bytes",
      pull(controller) {
        pulls += 1;
        const request = controller.byobRequest;
        assert(request instanceof ReadableStreamBYOBRequest);
        const view = request.view;
        view[0] = 4;
        view[1] = 5;
        view[2] = 6;
        request.respond(3);
        controller.close();
      },
    });

    const reader = stream.getReader({ mode: "byob" });
    assert(reader instanceof ReadableStreamBYOBReader);
    assert.equal(stream.locked, true);

    const first = await reader.read(new Uint8Array(8));
    assert.equal(first.done, false);
    assert.deepEqual(Array.from(first.value), [4, 5, 6]);
    assert.equal(pulls, 1);
    const done = await reader.read(new Uint8Array(8));
    assert.equal(done.done, true);
    assert.equal(done.value.byteLength, 0);

    reader.releaseLock();
    assert.equal(stream.locked, false);
  });

  test("ReadableByteStreamController.enqueue transfers byte chunks before BYOB reads", async () => {
    let original = new Uint8Array([1, 2, 3, 4]);
    const stream = new ReadableStream({
      type: "bytes",
      start(controller) {
        controller.enqueue(original);
        assert.equal(original.byteLength, 0);
        controller.close();
      },
    });

    const reader = stream.getReader({ mode: "byob" });
    const first = await reader.read(new Uint8Array(2));
    assert.equal(first.done, false);
    assert.deepEqual(Array.from(first.value), [1, 2]);

    const second = await reader.read(new Uint8Array(4));
    assert.equal(second.done, false);
    assert.deepEqual(Array.from(second.value), [3, 4]);
  });

  test("byte streams reject out-of-bounds ArrayBufferViews", async () => {
    if (typeof ArrayBuffer.prototype.resize !== "function")
      return;

    const buffer = new ArrayBuffer(8, { maxByteLength: 8 });
    const view = new Uint8Array(buffer, 4, 4);
    buffer.resize(2);

    const stream = new ReadableStream({
      type: "bytes",
      start(controller) {
        assert.throws(() => controller.enqueue(view), TypeError);
        controller.close();
      },
    });
    assert.equal((await stream.getReader().read()).done, true);

    const reader = new ReadableStream({ type: "bytes" }).getReader({ mode: "byob" });
    await assertRejects(reader.read(view), TypeError);
  });

  test("BYOB reader drains queued byte chunks partially", async () => {
    const stream = new ReadableStream({
      type: "bytes",
      start(controller) {
        controller.enqueue(new Uint8Array([1, 2, 3, 4, 5]));
        controller.close();
      },
    });

    const reader = stream.getReader({ mode: "byob" });
    const first = await reader.read(new Uint8Array(2));
    assert.deepEqual(Array.from(first.value), [1, 2]);

    const second = await reader.read(new Uint8Array(4));
    assert.deepEqual(Array.from(second.value), [3, 4, 5]);
    assert.equal(second.done, false);
    const done = await reader.read(new Uint8Array(4));
    assert.equal(done.done, true);
    assert.equal(done.value.byteLength, 0);
  });

  test("BYOB request respondWithNewView resolves with the supplied view", async () => {
    const stream = new ReadableStream({
      type: "bytes",
      pull(controller) {
        const view = controller.byobRequest.view;
        view[0] = 8;
        view[1] = 9;
        controller.byobRequest.respondWithNewView(view.subarray(0, 2));
        controller.close();
      },
    });

    const result = await stream.getReader({ mode: "byob" }).read(new Uint8Array(6));
    assert.equal(result.done, false);
    assert.deepEqual(Array.from(result.value), [8, 9]);
  });

  test("BYOB request is invalidated after respond", async () => {
    let request;
    const stream = new ReadableStream({
      type: "bytes",
      pull(controller) {
        request = controller.byobRequest;
        request.view[0] = 7;
        request.respond(1);
        controller.close();
      },
    });

    const result = await stream.getReader({ mode: "byob" }).read(new Uint8Array(1));
    assert.equal(result.done, false);
    assert.deepEqual(Array.from(result.value), [7]);
    assert.throws(() => request.respond(0), TypeError);
    assert.equal(request.view, null);
  });

  test("BYOB request rejects nonzero respond after close", async () => {
    let request;
    const stream = new ReadableStream({
      type: "bytes",
      pull(controller) {
        request = controller.byobRequest;
        controller.close();
        assert.throws(() => request.respond(1), TypeError);
        request.respond(0);
      },
    });

    const result = await stream.getReader({ mode: "byob" }).read(new Uint8Array(4));
    assert.equal(result.done, true);
    assert.equal(request.view, null);
  });

  test("Bun port: byte stream getReader rejects invalid options and modes", () => {
    const stream = new ReadableStream({ type: "bytes" });
    assert.throws(() => stream.getReader(1), TypeError);
    assert.throws(() => stream.getReader("asdf"), TypeError);
    assert.throws(() => stream.getReader({ mode: "" }), TypeError);
    assert.throws(() => stream.getReader({ mode: null }), TypeError);
  });

  test("Bun port: byte stream rejects strategy size", () => {
    assert.throws(() => new ReadableStream({ type: "bytes" }, { size() { return 1; } }), RangeError);
  });

  test("Bun port: byte stream autoAllocateChunkSize creates BYOB request for default reader", async () => {
    const stream = new ReadableStream({
      type: "bytes",
      autoAllocateChunkSize: 8,
      pull(controller) {
        const request = controller.byobRequest;
        assert(request instanceof ReadableStreamBYOBRequest);
        const view = request.view;
        view[0] = 20;
        view[1] = 21;
        request.respondWithNewView(view.subarray(0, 2));
        controller.close();
      },
    });

    const result = await stream.getReader().read();
    assert.equal(result.done, false);
    assert.deepEqual(Array.from(result.value), [20, 21]);
  });

  test("BYOB reader read rejects invalid views with promises", async () => {
    const reader = new ReadableStream({ type: "bytes" }).getReader({ mode: "byob" });

    await assertRejects(reader.read(), TypeError);
    await assertRejects(reader.read(new Uint8Array(0)), TypeError);
    reader.releaseLock();
    await assertRejects(reader.read(new Uint8Array(1)), TypeError);
    await assertRejects(reader.closed, TypeError);
  });

  test("BYOB invalid respond calls do not consume the pending request", async () => {
    let request;
    const stream = new ReadableStream({
      type: "bytes",
      pull(controller) {
        request = controller.byobRequest;
        assert.throws(() => request.respond(0), TypeError);
        assert.throws(() => request.respond(99), RangeError);
        request.view[0] = 1;
        request.respond(1);
        controller.close();
      },
    });

    const result = await stream.getReader({ mode: "byob" }).read(new Uint8Array(2));
    assert.equal(result.done, false);
    assert.deepEqual(Array.from(result.value), [1]);
  });

  test("BYOB respondWithNewView rejects unrelated views without consuming request", async () => {
    const stream = new ReadableStream({
      type: "bytes",
      pull(controller) {
        assert.throws(() => controller.byobRequest.respondWithNewView(new Uint8Array([1])), RangeError);
        const view = controller.byobRequest.view;
        view[0] = 3;
        controller.byobRequest.respondWithNewView(view.subarray(0, 1));
        controller.close();
      },
    });

    const result = await stream.getReader({ mode: "byob" }).read(new Uint8Array(4));
    assert.equal(result.done, false);
    assert.deepEqual(Array.from(result.value), [3]);
  });

  test("tee preserves byte stream branches and BYOB reads", async () => {
    const [left, right] = new ReadableStream({
      type: "bytes",
      start(controller) {
        controller.enqueue(new Uint8Array([1, 2, 3, 4]));
        controller.close();
      },
    }).tee();

    const leftReader = left.getReader({ mode: "byob" });
    const rightReader = right.getReader({ mode: "byob" });

    const leftResult = await leftReader.read(new Uint8Array(4));
    assert.equal(leftResult.done, false);
    assert.deepEqual(Array.from(leftResult.value), [1, 2, 3, 4]);

    const rightResult = await rightReader.read(new Uint8Array(4));
    assert.equal(rightResult.done, false);
    assert.deepEqual(Array.from(rightResult.value), [1, 2, 3, 4]);
  });

  test("controller.close throws when close is already requested", () => {
    let controller;
    new ReadableStream({
      start(value) {
        controller = value;
      },
    });

    controller.close();
    assert.throws(() => controller.close(), TypeError);
  });

  test("releaseLock rejects pending reads", async () => {
    const stream = new ReadableStream({});
    const reader = stream.getReader();
    const pending = reader.read().then(
      () => "resolved",
      error => String(error && (error.message || error)),
    );

    reader.releaseLock();
    assert.equal(stream.locked, false);
    assert((await pending).includes("reader was released"));
  });

  test("cancel clears queued chunks", async () => {
    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue("x");
      },
    });

    await stream.cancel("stop");
    assert.equal(stream.locked, false);
    assert.deepEqual(await stream.getReader().read(), { value: undefined, done: true });
  });

  test("values is the async iterator function", () => {
    assert.equal(ReadableStream.prototype.values, ReadableStream.prototype[Symbol.asyncIterator]);
  });
});

describe("ReadableStream Body integration", () => {
  test("disturbed Response readable stream body rejects later consumers and clone", async () => {
    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue("x");
        controller.close();
      },
    });
    const response = new Response(stream);
    const reader = response.body.getReader();
    assert.deepEqual(await reader.read(), { value: "x", done: false });
    reader.releaseLock();

    await assertRejects(response.text(), TypeError);
    assert.throws(() => response.clone(), TypeError);
  });

  test("Response readable stream body consumer releases reader after chunk type error", async () => {
    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue({});
        controller.close();
      },
    });
    const response = new Response(stream);

    await assertRejects(response.text(), TypeError);
    assert.equal(stream.locked, false);
  });

  test("Response readable stream body rejects resizable ArrayBufferView chunks", async () => {
    if (typeof ArrayBuffer.prototype.resize !== "function")
      return;

    const buffer = new ArrayBuffer(3, { maxByteLength: 3 });
    const chunk = new Uint8Array(buffer);
    chunk.set([1, 2, 3]);
    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue(chunk);
        controller.close();
      },
    });

    await assertRejects(new Response(stream).bytes(), TypeError);
    assert.equal(stream.locked, false);
  });

  test("ReadableStream body methods reject when public reader hooks throw", async () => {
    const getReaderError = new TypeError("patched getReader");
    const originalGetReader = ReadableStream.prototype.getReader;
    try {
      ReadableStream.prototype.getReader = function () {
        throw getReaderError;
      };
      const stream = new ReadableStream({
        pull() {},
      });
      const promise = stream.text();
      assert(promise instanceof Promise);
      assert.equal(await promise.catch(error => error), getReaderError);
    } finally {
      ReadableStream.prototype.getReader = originalGetReader;
    }

    const probe = new ReadableStream({
      pull() {},
    });
    const probeReader = probe.getReader();
    const readerPrototype = Object.getPrototypeOf(probeReader);
    probeReader.releaseLock();

    const readError = new TypeError("patched read");
    const originalRead = readerPrototype.read;
    try {
      readerPrototype.read = function () {
        throw readError;
      };
      const stream = new ReadableStream({
        pull() {},
      });
      const promise = stream.text();
      assert(promise instanceof Promise);
      assert.equal(await promise.catch(error => error), readError);
    } finally {
      readerPrototype.read = originalRead;
    }
  });
});

describe("WritableStream core", () => {
  test("Bun port: WritableStream works", async () => {
    const chunks = [];
    const writable = new WritableStream({
      write(chunk) {
        chunks.push(chunk);
      },
      close() {},
      abort() {},
    });

    const writer = writable.getWriter();
    await writer.write(new Uint8Array([1, 2, 3]));
    await writer.write(new Uint8Array([4, 5, 6]));
    await writer.close();

    const joined = [];
    for (const chunk of chunks) joined.push(...chunk);
    assert.deepEqual(joined, [1, 2, 3, 4, 5, 6]);
    assert.equal(writable.locked, true);
    writer.releaseLock();
    assert.equal(writable.locked, false);
  });

  test("serializes asynchronous writes before close", async () => {
    const events = [];
    let releaseFirst;
    const writable = new WritableStream({
      write(chunk) {
        events.push(`write:${chunk}`);
        if (chunk === "a") {
          return new Promise(resolve => {
            releaseFirst = () => {
              events.push("release:a");
              resolve();
            };
          });
        }
      },
      close() {
        events.push("close");
      },
    });

    const writer = writable.getWriter();
    const first = writer.write("a");
    const second = writer.write("b");
    const close = writer.close();
    await Promise.resolve();
    assert.deepEqual(events, ["write:a"]);
    releaseFirst();
    await Promise.all([first, second, close]);
    assert.deepEqual(events, ["write:a", "release:a", "write:b", "close"]);
  });

  test("writer.ready follows highWaterMark backpressure", async () => {
    let releaseWrite;
    const writable = new WritableStream(
      {
        write() {
          return new Promise(resolve => {
            releaseWrite = resolve;
          });
        },
      },
      { highWaterMark: 1 },
    );
    const writer = writable.getWriter();
    assert.equal(writer.desiredSize, 1);
    const write = writer.write("x");
    assert.equal(writer.desiredSize, 0);
    let ready = false;
    writer.ready.then(() => {
      ready = true;
    });
    await Promise.resolve();
    assert.equal(ready, false);
    releaseWrite();
    await write;
    await writer.ready;
    assert.equal(ready, true);
    await writer.close();
  });

  test("releaseLock rejects captured pending writer promises", async () => {
    const writable = new WritableStream({}, { highWaterMark: 0 });
    const writer = writable.getWriter();
    const ready = writer.ready.then(
      () => "resolved",
      error => String(error && (error.message || error)),
    );
    const closed = writer.closed.then(
      () => "resolved",
      error => String(error && (error.message || error)),
    );

    writer.releaseLock();
    assert.equal(writable.locked, false);
    assert((await ready).includes("released"));
    assert((await closed).includes("released"));
  });

  test("releaseLock returns stable rejected writer promises", async () => {
    const writable = new WritableStream({}, { highWaterMark: 0 });
    const writer = writable.getWriter();
    writer.releaseLock();

    const ready = writer.ready;
    const closed = writer.closed;
    assert.equal(writer.ready, ready);
    assert.equal(writer.closed, closed);
    await assertRejects(ready, TypeError);
    await assertRejects(closed, TypeError);
  });

  test("write rejection errors stream and rejects closed", async () => {
    const error = new Error("write failed");
    const writable = new WritableStream({
      write() {
        throw error;
      },
    });
    const writer = writable.getWriter();
    const seen = await writer.write("x").then(
      () => "resolved",
      caught => caught,
    );
    assert.equal(seen, error);
    assert.equal(
      await writer.closed.then(
        () => "resolved",
        caught => caught,
      ),
      error,
    );
  });
});

describe("ReadableStream.prototype.pipeTo", () => {
  test("Bun port: pipeTo writes chunks", async () => {
    const readable = new ReadableStream({
      start(controller) {
        controller.enqueue("hello world");
        controller.close();
      },
    });

    let received;
    const writable = new WritableStream({
      write(chunk) {
        received = chunk;
      },
    });
    await readable.pipeTo(writable);
    assert.equal(received, "hello world");
  });

  test("waits for writable backpressure before reading another chunk", async () => {
    const events = [];
    let releaseWrite;
    let pull_count = 0;
    const readable = new ReadableStream({
      pull(controller) {
        pull_count += 1;
        events.push(`pull:${pull_count}`);
        controller.enqueue(String(pull_count));
        if (pull_count === 2) controller.close();
      },
    });
    const writable = new WritableStream({
      write(chunk) {
        events.push(`write:${chunk}`);
        if (chunk === "1") {
          return new Promise(resolve => {
            releaseWrite = resolve;
          });
        }
      },
    });

    const piping = readable.pipeTo(writable);
    await waitForMicrotaskCondition("pipeTo first write", () => typeof releaseWrite === "function");
    assert.deepEqual(events, ["pull:1", "write:1"]);
    releaseWrite();
    await piping;
    assert.deepEqual(events, ["pull:1", "write:1", "pull:2", "write:2"]);
  });

  test("uses destination highWaterMark to pipeline writes", async () => {
    const events = [];
    const releases = [];
    let pull_count = 0;
    const readable = new ReadableStream({
      pull(controller) {
        pull_count += 1;
        events.push(`pull:${pull_count}`);
        controller.enqueue(String(pull_count));
        if (pull_count === 3) controller.close();
      },
    });
    const writable = new WritableStream(
      {
        write(chunk) {
          events.push(`write:${chunk}`);
          return new Promise(resolve => {
            releases.push(resolve);
          });
        },
      },
      { highWaterMark: 2 },
    );

    const piping = readable.pipeTo(writable);
    await waitForMicrotaskCondition("pipeTo first two writes", () => releases.length === 2);
    assert.deepEqual(events, ["pull:1", "write:1", "pull:2", "write:2"]);

    releases.shift()();
    await waitForMicrotaskCondition("pipeTo third write", () => releases.length === 2);
    assert.deepEqual(events, ["pull:1", "write:1", "pull:2", "write:2", "pull:3", "write:3"]);
    while (releases.length) releases.shift()();
    await piping;
  });

  test("preventClose leaves destination writable open", async () => {
    const readable = new ReadableStream({
      start(controller) {
        controller.close();
      },
    });
    const writable = new WritableStream({});
    await readable.pipeTo(writable, { preventClose: true });
    const writer = writable.getWriter();
    await writer.write("still-open");
    await writer.close();
  });

  test("AbortSignal aborts destination and cancels source after the pending write settles", async () => {
    let canceled;
    let aborted;
    let releaseWrite;
    const controller = new AbortController();
    const readable = new ReadableStream({
      start(stream_controller) {
        stream_controller.enqueue("x");
      },
      cancel(reason) {
        canceled = reason;
      },
    });
    const writable = new WritableStream({
      write() {
        return new Promise(resolve => {
          releaseWrite = resolve;
        });
      },
      abort(reason) {
        aborted = reason;
      },
    });

    const piping = readable.pipeTo(writable, { signal: controller.signal }).then(
      () => "resolved",
      error => error,
    );
    await waitForMicrotaskCondition("pipeTo first write", () => typeof releaseWrite === "function");
    controller.abort("stop");
    // Spec: chunks that have been read must finish writing before the
    // destination is aborted.
    await Promise.resolve();
    await Promise.resolve();
    assert.equal(aborted, undefined);
    releaseWrite();
    assert.equal(await piping, "stop");
    assert.equal(canceled, "stop");
    assert.equal(aborted, "stop");
  });

  test("option getter errors do not leave source or destination locked", async () => {
    const readable = new ReadableStream();
    const writable = new WritableStream();
    const options = {};
    Object.defineProperty(options, "preventClose", {
      get() {
        throw new Error("option failed");
      },
    });

    let result;
    try {
      result = await readable.pipeTo(writable, options).then(
        () => "resolved",
        error => error,
      );
    } catch (error) {
      result = error;
    }
    assert(result instanceof Error);
    assert.equal(result.message, "option failed");
    assert.equal(readable.locked, false);
    assert.equal(writable.locked, false);
  });

  test("AbortSignal hooks are internal to pipeTo", async () => {
    const controller = new AbortController();
    Object.defineProperty(controller.signal, "addEventListener", {
      value() {
        throw new Error("observable addEventListener must not be used");
      },
    });
    Object.defineProperty(controller.signal, "removeEventListener", {
      value() {
        throw new Error("observable removeEventListener must not be used");
      },
    });
    Object.defineProperty(controller.signal, "reason", {
      get() {
        throw new Error("observable reason getter must not be used");
      },
    });

    let canceled;
    let aborted;
    let releaseWrite;
    const readable = new ReadableStream({
      pull(controller) {
        controller.enqueue("x");
      },
      cancel(reason) {
        canceled = reason;
      },
    });
    const writable = new WritableStream({
      write() {
        return new Promise(resolve => {
          releaseWrite = resolve;
        });
      },
      abort(reason) {
        aborted = reason;
      },
    });

    const piping = readable.pipeTo(writable, { signal: controller.signal }).then(
      () => "resolved",
      error => error,
    );
    await waitForMicrotaskCondition("pipeTo first write", () => typeof releaseWrite === "function");
    controller.abort("stop");
    releaseWrite();
    assert.equal(await piping, "stop");
    assert.equal(canceled, "stop");
    assert.equal(aborted, "stop");
    assert.equal(readable.locked, false);
    assert.equal(writable.locked, false);
  });

  test("public abort event dispatch does not trigger pipeTo abort algorithm", async () => {
    const controller = new AbortController();
    let canceled;
    let aborted;
    let releaseWrite;
    let settled = false;
    const readable = new ReadableStream({
      pull(controller) {
        controller.enqueue("x");
      },
      cancel(reason) {
        canceled = reason;
      },
    });
    const writable = new WritableStream({
      write() {
        return new Promise(resolve => {
          releaseWrite = resolve;
        });
      },
      abort(reason) {
        aborted = reason;
      },
    });

    const piping = readable.pipeTo(writable, { signal: controller.signal }).then(
      () => {
        settled = true;
        return "resolved";
      },
      error => {
        settled = true;
        return error;
      },
    );
    await waitForMicrotaskCondition("pipeTo first write", () => typeof releaseWrite === "function");
    controller.signal.dispatchEvent(new Event("abort"));
    await Promise.resolve();
    assert.equal(settled, false);
    assert.equal(canceled, undefined);
    assert.equal(aborted, undefined);

    controller.abort("stop");
    releaseWrite();
    assert.equal(await piping, "stop");
    assert.equal(canceled, "stop");
    assert.equal(aborted, "stop");
  });

  test("signal option getter value is kept alive until pipeTo installs it", async () => {
    let controller = new AbortController();
    const options = {};
    Object.defineProperty(options, "signal", {
      get() {
        const signal = controller.signal;
        controller = null;
        return signal;
      },
    });

    const readable = new ReadableStream({
      start(controller) {
        controller.close();
      },
    });
    const writable = new WritableStream({});
    await readable.pipeTo(writable, options);
    assert.equal(readable.locked, false);
    assert.equal(writable.locked, false);
  });

  test("AbortSignal waits for asynchronous abort and cancel before pipeTo settles", async () => {
    const controller = new AbortController();
    let releaseAbort;
    let releaseCancel;
    let settled = false;
    const readable = new ReadableStream({
      pull(controller) {
        controller.enqueue("x");
      },
      cancel(reason) {
        assert.equal(reason, "stop");
        return new Promise(resolve => {
          releaseCancel = resolve;
        });
      },
    });
    let releaseWrite;
    const writable = new WritableStream({
      write() {
        return new Promise(resolve => {
          releaseWrite = resolve;
        });
      },
      abort(reason) {
        assert.equal(reason, "stop");
        return new Promise(resolve => {
          releaseAbort = resolve;
        });
      },
    });

    const piping = readable.pipeTo(writable, { signal: controller.signal }).then(
      () => {
        settled = true;
        return "resolved";
      },
      error => {
        settled = true;
        return error;
      },
    );

    await waitForMicrotaskCondition("pipeTo first write", () => typeof releaseWrite === "function");
    controller.abort("stop");
    releaseWrite();
    await waitForMicrotaskCondition("pipeTo abort action", () => typeof releaseAbort === "function");
    assert.equal(settled, false);
    releaseAbort();
    await Promise.resolve();
    assert.equal(settled, false);
    releaseCancel();
    assert.equal(await piping, "stop");
    assert.equal(settled, true);
  });

  test("AbortSignal beats a stale pending write fulfillment", async () => {
    const controller = new AbortController();
    let releaseWrite;
    let releaseAbort;
    let releaseCancel;
    let settled = false;
    const readable = new ReadableStream({
      pull(controller) {
        controller.enqueue("x");
      },
      cancel(reason) {
        assert.equal(reason, "stop");
        return new Promise(resolve => {
          releaseCancel = resolve;
        });
      },
    });
    const writable = new WritableStream({
      write() {
        return new Promise(resolve => {
          releaseWrite = resolve;
        });
      },
      abort(reason) {
        assert.equal(reason, "stop");
        return new Promise(resolve => {
          releaseAbort = resolve;
        });
      },
    });

    const piping = readable.pipeTo(writable, { signal: controller.signal }).then(
      () => {
        settled = true;
        return "resolved";
      },
      error => {
        settled = true;
        return error;
      },
    );

    await waitForMicrotaskCondition("pipeTo write to start", () => typeof releaseWrite === "function");
    controller.abort("stop");
    await Promise.resolve();
    assert.equal(settled, false);
    assert.equal(typeof releaseAbort, "undefined");
    releaseWrite();
    await waitForMicrotaskCondition("pipeTo abort action", () => typeof releaseAbort === "function");
    assert.equal(settled, false);
    releaseAbort();
    await Promise.resolve();
    assert.equal(settled, false);
    releaseCancel();
    assert.equal(await piping, "stop");
  });

  test("abort during an in-flight close is a no-op once shutdown started", async () => {
    // Spec: closing the destination is a shutdown; a signal abort after that
    // neither aborts the destination nor rejects the pipe.
    const controller = new AbortController();
    let releaseClose;
    let aborted = false;
    const readable = new ReadableStream({
      start(controller) {
        controller.close();
      },
    });
    const writable = new WritableStream({
      close() {
        return new Promise(resolve => {
          releaseClose = resolve;
        });
      },
      abort() {
        aborted = true;
      },
    });

    const piping = readable.pipeTo(writable, { signal: controller.signal }).then(
      () => "resolved",
      error => error,
    );

    await waitForMicrotaskCondition("pipeTo close to start", () => typeof releaseClose === "function");
    controller.abort("stop");
    await Promise.resolve();
    releaseClose();
    assert.equal(await piping, "resolved");
    assert.equal(aborted, false);
  });

  test("pre-aborted signal still returns the pipe promise", async () => {
    const controller = new AbortController();
    controller.abort("stop");
    const readable = new ReadableStream();
    const writable = new WritableStream({
      abort(reason) {
        assert.equal(reason, "stop");
      },
    });

    const promise = readable.pipeTo(writable, { signal: controller.signal });
    assert(promise instanceof Promise);
    assert.equal(await promise.then(
      () => "resolved",
      error => error,
    ), "stop");
  });
});

describe("TransformStream core", () => {
  test("Bun port: TransformStream encodes chunks", async () => {
    const TextEncoderStreamInterface = {
      start() {
        this.encoder = new TextEncoder();
      },
      transform(chunk, controller) {
        controller.enqueue(this.encoder.encode(chunk));
      },
    };

    const instances = new WeakMap();
    class JSTextEncoderStream extends TransformStream {
      constructor() {
        super(TextEncoderStreamInterface);
        instances.set(this, TextEncoderStreamInterface);
      }
      get encoding() {
        return instances.get(this).encoder.encoding;
      }
    }

    const stream = new JSTextEncoderStream();
    assert.equal(stream.encoding, "utf-8");
    const writer = stream.writable.getWriter();
    // Per spec the readable side's default highWaterMark is 0, so the stream
    // starts with backpressure and writes only complete once the readable
    // side pulls; queue them instead of awaiting before reading.
    const pendingWrites = Promise.all([writer.write("hello"), writer.write("world")]);
    const pendingClose = writer.close();

    const reader = stream.readable.getReader();
    const chunks = [];
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(new TextDecoder().decode(value));
    }
    assert.equal(chunks.join(""), "helloworld");
    await pendingWrites;
    await pendingClose;
  });

  test("flush runs before readable closes", async () => {
    const stream = new TransformStream({
      transform(chunk, controller) {
        controller.enqueue(chunk);
      },
      flush(controller) {
        controller.enqueue("!");
      },
    });
    const writer = stream.writable.getWriter();
    // Backpressure starts set (readable highWaterMark 0), so the write only
    // completes after the readable side pulls.
    const pendingWrite = writer.write("ok");
    const pendingClose = writer.close();
    const reader = stream.readable.getReader();
    assert.deepEqual(await reader.read(), { value: "ok", done: false });
    assert.deepEqual(await reader.read(), { value: "!", done: false });
    assert.deepEqual(await reader.read(), { value: undefined, done: true });
    await pendingWrite;
    await pendingClose;
  });
});

describe("ReadableStream.prototype.pipeThrough", () => {
  test("pipes through a TransformStream and returns the readable side", async () => {
    const readable = new ReadableStream({
      start(controller) {
        controller.enqueue("a");
        controller.enqueue("b");
        controller.close();
      },
    });
    const transform = new TransformStream({
      transform(chunk, controller) {
        controller.enqueue(chunk.toUpperCase());
      },
    });

    const piped = readable.pipeThrough(transform);
    assert(piped instanceof ReadableStream);
    const output = [];
    for await (const chunk of piped) output.push(chunk);
    assert.equal(output.join(""), "AB");
  });
});

describe("CompressionStream and DecompressionStream", () => {
  async function roundTrip(format, input) {
    const data = new TextEncoder().encode(input);
    const compressed = await new Response(
      new Blob([data]).stream().pipeThrough(new CompressionStream(format)),
    ).arrayBuffer();
    const decompressed = await new Response(
      new Blob([compressed]).stream().pipeThrough(new DecompressionStream(format)),
    ).arrayBuffer();
    return new TextDecoder().decode(decompressed);
  }

  async function compressedBytes(format, input) {
    const data = new TextEncoder().encode(input);
    return new Uint8Array(await new Response(
      new Blob([data]).stream().pipeThrough(new CompressionStream(format)),
    ).arrayBuffer());
  }

  test("Bun port: globals, tags, and accessors are installed", () => {
    assert.equal(typeof CompressionStream, "function");
    assert.equal(typeof DecompressionStream, "function");

    const gzip = new CompressionStream("gzip");
    const gunzip = new DecompressionStream("gzip");
    assert.equal(gzip[Symbol.toStringTag], "CompressionStream");
    assert.equal(gunzip[Symbol.toStringTag], "DecompressionStream");
    assert(gzip.readable instanceof ReadableStream);
    assert(gzip.writable instanceof WritableStream);
    assert(gunzip.readable instanceof ReadableStream);
    assert(gunzip.writable instanceof WritableStream);

    assert.throws(() => Reflect.get(CompressionStream.prototype, "readable", {}), TypeError);
    assert.throws(() => Reflect.get(CompressionStream.prototype, "writable", {}), TypeError);
    assert.throws(() => Reflect.get(DecompressionStream.prototype, "readable", {}), TypeError);
    assert.throws(() => Reflect.get(DecompressionStream.prototype, "writable", {}), TypeError);
  });

  test("server profile rejects formats outside the current compression set", () => {
    for (const format of [1, "hello", false, {}, "br", "zstd"]) {
      assert.throws(() => new CompressionStream(format), TypeError);
      assert.throws(() => new DecompressionStream(format), TypeError);
    }
  });

  test("Bun port: pipe compression directly into decompression", async () => {
    for (const format of ["gzip", "deflate", "deflate-raw", "brotli"]) {
      const compression = new CompressionStream(format);
      const decompression = new DecompressionStream(format);
      const piping = compression.readable.pipeTo(decompression.writable);
      const reader = decompression.readable.getReader();
      const writer = compression.writable.getWriter();

      const chunks = [];
      const readerPromise = (async () => {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;
          chunks.push(value);
        }
      })();

      await writer.write(new TextEncoder().encode("hello"));
      await writer.close();
      await piping;
      await readerPromise;
      assert.equal(new TextDecoder().decode(concatUint8(chunks)), "hello");
      assert.deepEqual(await reader.read(), { value: undefined, done: true });
    }
  });

  test("Bun port: round-trips all supported formats", async () => {
    const inputs = [
      "Simple string",
      "A".repeat(1000),
      "Mixed 123 !@# symbols",
      "",
      JSON.stringify({ nested: { object: "value" } }),
    ];

    for (const format of ["gzip", "deflate", "deflate-raw", "brotli"]) {
      for (const input of inputs) {
        assert.equal(await roundTrip(format, input), input);
      }
    }
  });

  test("Bun port: compressed chunks are Uint8Array and non-empty for non-empty input", async () => {
    const writerInput = new TextEncoder().encode("Hello, Bun compression stream.");
    for (const format of ["gzip", "deflate", "deflate-raw", "brotli"]) {
      const stream = new CompressionStream(format);
      const writer = stream.writable.getWriter();
      // The readable side has a zero highWaterMark, so writes only complete
      // once the readable side is drained; queue them before reading.
      const pendingWrites = Promise.all([writer.write(writerInput), writer.close()]);

      const compressed = await collectBytes(stream.readable);
      await pendingWrites;
      assert(compressed.byteLength > 0);
    }
  });

  test("invalid compressed input rejects decompression", async () => {
    for (const format of ["gzip", "deflate", "deflate-raw", "brotli"]) {
      const stream = new DecompressionStream(format);
      const reader = stream.readable.getReader();
      const readResult = reader.read().then(
        () => "resolved",
        error => error,
      );
      const writer = stream.writable.getWriter();
      const result = await writer.write(new Uint8Array([1, 2, 3, 4])).then(
        () => writer.close(),
        error => Promise.reject(error),
      ).then(
        () => "resolved",
        error => error,
      );
      assert(result instanceof TypeError);
      assert((await readResult) instanceof TypeError);
    }
  });

  test("invalid compressed input rejects readable side too", async () => {
    const stream = new DecompressionStream("gzip");
    const reader = stream.readable.getReader();
    const writer = stream.writable.getWriter();
    const readResult = reader.read().then(
      () => "resolved",
      error => error,
    );
    const writeResult = writer.write(new Uint8Array([1, 2, 3, 4])).then(
      () => "resolved",
      error => error,
    );

    assert((await writeResult) instanceof TypeError);
    assert((await readResult) instanceof TypeError);
  });

  test("truncated compressed close rejects readable side", async () => {
    const stream = new DecompressionStream("gzip");
    const reader = stream.readable.getReader();
    const writer = stream.writable.getWriter();
    const readResult = reader.read().then(
      () => "resolved",
      error => error,
    );
    const closeResult = writer.close().then(
      () => "resolved",
      error => error,
    );

    assert((await closeResult) instanceof TypeError);
    assert((await readResult) instanceof TypeError);
  });

  test("gzip trailing data rejects instead of being ignored", async () => {
    const compressed = await compressedBytes("gzip", "hello");
    const withTrailing = new Uint8Array(compressed.byteLength + 3);
    withTrailing.set(compressed);
    withTrailing.set([1, 2, 3], compressed.byteLength);

    const stream = new DecompressionStream("gzip");
    const reader = stream.readable.getReader();
    const writer = stream.writable.getWriter();
    const readResult = (async () => {
      try {
        await reader.read();
        await reader.read();
        return "resolved";
      } catch (error) {
        return error;
      }
    })();
    const writeResult = writer.write(withTrailing).then(
      () => "resolved",
      error => error,
    );

    assert((await writeResult) instanceof Error);
    assert((await readResult) instanceof Error);
  });

  test("large decompression write waits for readable demand", async () => {
    const compressed = await compressedBytes("gzip", "A".repeat(512 * 1024));
    const stream = new DecompressionStream("gzip");
    const writer = stream.writable.getWriter();
    let writeSettled = false;
    const writePromise = writer.write(compressed).then(() => {
      writeSettled = true;
    });

    await Promise.resolve();
    await Promise.resolve();
    assert.equal(writeSettled, false);

    const reader = stream.readable.getReader();
    let decodedLength = 0;
    while (!writeSettled) {
      const { done, value } = await reader.read();
      if (done) break;
      decodedLength += value.byteLength;
    }
    await writePromise;
    assert(decodedLength > 64 * 1024);
    await writer.close();
  });

  test("readable cancel rejects a backpressured compression write", async () => {
    const compressed = await compressedBytes("gzip", "A".repeat(512 * 1024));
    const stream = new DecompressionStream("gzip");
    const writer = stream.writable.getWriter();
    const writeResultPromise = writer.write(compressed).then(
      () => "resolved",
      error => error,
    );

    await Promise.resolve();
    await Promise.resolve();
    await stream.readable.cancel("stop");
    assert.equal(await writeResultPromise, "stop");
  });

  test("compression write rejects non-BufferSource chunks including strings", async () => {
    // Per the Compression spec, chunks must be BufferSource.
    for (const chunk of [{}, "hello", 42, null, undefined]) {
      const writer = new CompressionStream("gzip").writable.getWriter();
      assert(await writer.write(chunk).then(
        () => false,
        error => error instanceof TypeError,
      ));
    }
  });

  test("compression write rejects unavailable BufferSource chunks", async () => {
    const detached = new ArrayBuffer(8);
    structuredClone(detached, { transfer: [detached] });
    const writer = new CompressionStream("gzip").writable.getWriter();
    await assertRejects(writer.write(detached), TypeError);

    if (typeof ArrayBuffer.prototype.resize === "function") {
      const resizable = new ArrayBuffer(8, { maxByteLength: 8 });
      const resizableWriter = new CompressionStream("gzip").writable.getWriter();
      await assertRejects(resizableWriter.write(resizable), TypeError);

      const buffer = new ArrayBuffer(8, { maxByteLength: 8 });
      const view = new Uint8Array(buffer, 4, 4);
      buffer.resize(2);

      const viewWriter = new CompressionStream("gzip").writable.getWriter();
      await assertRejects(viewWriter.write(view), TypeError);
    }
  });
});

describe("Stream lock lifecycle", () => {
  test("reader and writer locks are released on explicit completion paths", async () => {
    const readable = new ReadableStream({
      start(controller) {
        controller.enqueue("x");
        controller.close();
      },
    });
    const reader = readable.getReader();
    assert.equal(readable.locked, true);
    assert.deepEqual(await reader.read(), { value: "x", done: false });
    assert.deepEqual(await reader.read(), { value: undefined, done: true });
    await reader.closed;
    reader.releaseLock();
    assert.equal(readable.locked, false);

    const writable = new WritableStream({});
    const writer = writable.getWriter();
    assert.equal(writable.locked, true);
    await writer.close();
    await writer.closed;
    writer.releaseLock();
    assert.equal(writable.locked, false);
  });

  test("reader and writer locks are released after error and cancel paths", async () => {
    const sourceError = new Error("source failed");
    const readable = new ReadableStream({
      start(controller) {
        controller.error(sourceError);
      },
    });
    const reader = readable.getReader();
    assert.equal(await reader.read().then(() => "resolved", error => error), sourceError);
    assert.equal(await reader.closed.then(() => "resolved", error => error), sourceError);
    reader.releaseLock();
    assert.equal(readable.locked, false);

    const writable = new WritableStream({
      write() {
        throw new Error("write failed");
      },
    });
    const writer = writable.getWriter();
    assert(await writer.write("x").then(
      () => false,
      error => error instanceof Error,
    ));
    assert(await writer.closed.then(
      () => false,
      error => error instanceof Error,
    ));
    writer.releaseLock();
    assert.equal(writable.locked, false);

    const canceled = new ReadableStream({
      start(controller) {
        controller.enqueue("x");
      },
    });
    const cancelReader = canceled.getReader();
    await cancelReader.cancel("stop");
    await cancelReader.closed;
    cancelReader.releaseLock();
    assert.equal(canceled.locked, false);
  });

});

describe("Body stream integration", () => {
  test("Blob.stream returns Uint8Array chunks", async () => {
    const stream = new Blob(["abc"]).stream();
    assert(stream instanceof ReadableStream);
    const reader = stream.getReader();
    const first = await reader.read();
    const second = await reader.read();
    assert.equal(first.done, false);
    assert(first.value instanceof Uint8Array);
    assert.equal(new TextDecoder().decode(first.value), "abc");
    assert.deepEqual(second, { value: undefined, done: true });
    await reader.closed;
  });

  test("Blob.stream reads nested sliced blob parts", async () => {
    const source = new Blob(["ab", new Uint8Array([99, 100, 101, 102])]);
    const stream = new Blob([source.slice(1, 5), source.slice(5)]).stream();
    const reader = stream.getReader();
    const first = await reader.read();
    const second = await reader.read();

    assert.equal(first.done, false);
    assert.equal(new TextDecoder().decode(first.value), "bcdef");
    assert.deepEqual(second, { value: undefined, done: true });
  });

  test("Blob.stream chunks large blobs", async () => {
    const bytes = new Uint8Array(70 * 1024);
    bytes.fill(0x61);
    const reader = new Blob([bytes]).stream().getReader();

    const first = await reader.read();
    const second = await reader.read();
    const third = await reader.read();

    assert.equal(first.done, false);
    assert.equal(first.value.byteLength, 64 * 1024);
    assert.equal(second.done, false);
    assert.equal(second.value.byteLength, 6 * 1024);
    assert.deepEqual(third, { value: undefined, done: true });
  });

  test("native source keeps a pending chunk when releaseLock races pull fulfillment", async () => {
    const stream = new Blob(["abc"]).stream();
    const reader = stream.getReader();
    const pending = reader.read().then(
      () => "resolved",
      error => String(error && (error.message || error)),
    );

    reader.releaseLock();
    assert((await pending).includes("reader was released"));

    const nextReader = stream.getReader();
    const first = await nextReader.read();
    assert.equal(first.done, false);
    assert.equal(new TextDecoder().decode(first.value), "abc");
    assert.deepEqual(await nextReader.read(), { value: undefined, done: true });
  });

  test("Blob.stream tee reads both branches", async () => {
    const [left, right] = new Blob(["abc"]).stream().tee();
    async function readText(stream) {
      const reader = stream.getReader();
      const first = await reader.read();
      const second = await reader.read();
      assert.equal(first.done, false);
      assert.deepEqual(second, { value: undefined, done: true });
      return new TextDecoder().decode(first.value);
    }

    assert.equal(await readText(left), "abc");
    assert.equal(await readText(right), "abc");
  });

  test("Blob.stream tee branches do not share mutable chunks", async () => {
    const [left, right] = new Blob([new Uint8Array([1, 2, 3])]).stream().tee();
    const leftChunk = (await left.getReader().read()).value;
    const rightChunk = (await right.getReader().read()).value;

    leftChunk[0] = 99;
    assert.deepEqual(Array.from(leftChunk), [99, 2, 3]);
    assert.deepEqual(Array.from(rightChunk), [1, 2, 3]);
  });

  test("Blob.stream tee after a read does not replay consumed bytes", async () => {
    const bytes = new Uint8Array(70 * 1024);
    bytes.fill(0x61);
    const stream = new Blob([bytes]).stream();
    const reader = stream.getReader();
    const consumed = await reader.read();
    assert.equal(consumed.done, false);
    assert.equal(consumed.value.byteLength, 64 * 1024);
    reader.releaseLock();

    const [left, right] = stream.tee();
    async function readRemainder(branch) {
      const branchReader = branch.getReader();
      const first = await branchReader.read();
      const second = await branchReader.read();
      assert.equal(first.done, false);
      assert.deepEqual(second, { value: undefined, done: true });
      return first.value.byteLength;
    }

    assert.equal(await readRemainder(left), 6 * 1024);
    assert.equal(await readRemainder(right), 6 * 1024);
  });

  test("Response.body returns a standard ReadableStream", async () => {
    const response = new Response("abc");
    assert(response.body instanceof ReadableStream);
    assert.equal(response.bodyUsed, false);

    const reader = response.body.getReader();
    const first = await reader.read();
    assert.equal(response.bodyUsed, true);
    assert.equal(new TextDecoder().decode(first.value), "abc");
    assert.deepEqual(await reader.read(), { value: undefined, done: true });
    await reader.closed;
  });

  test("Response.body cancel marks bodyUsed", async () => {
    const response = new Response("abc");
    await response.body.cancel("stop");
    assert.equal(response.bodyUsed, true);
    const rejection = await response.text().then(
      () => "resolved",
      error => String(error && (error.message || error)),
    );
    assert(rejection.includes("body already used"));
  });

  test("Response.body tee reads both branches", async () => {
    const [left, right] = new Response("abc").body.tee();
    async function readText(stream) {
      const reader = stream.getReader();
      const first = await reader.read();
      const second = await reader.read();
      assert.equal(first.done, false);
      assert.deepEqual(second, { value: undefined, done: true });
      return new TextDecoder().decode(first.value);
    }

    assert.equal(await readText(left), "abc");
    assert.equal(await readText(right), "abc");
  });

  test("Response.body tee branches do not share mutable chunks", async () => {
    const [left, right] = new Response(new Uint8Array([4, 5, 6])).body.tee();
    const leftChunk = (await left.getReader().read()).value;
    const rightChunk = (await right.getReader().read()).value;

    leftChunk[1] = 88;
    assert.deepEqual(Array.from(leftChunk), [4, 88, 6]);
    assert.deepEqual(Array.from(rightChunk), [4, 5, 6]);
  });

  test("Response.body tee after a read does not replay consumed bytes", async () => {
    const response = new Response("abc");
    const reader = response.body.getReader();
    assert.equal(new TextDecoder().decode((await reader.read()).value), "abc");
    reader.releaseLock();

    const [left, right] = response.body.tee();
    assert.deepEqual(await left.getReader().read(), { value: undefined, done: true });
    assert.deepEqual(await right.getReader().read(), { value: undefined, done: true });
  });

  test("ReadableStream.blob-style consumption after body use does not crash", async () => {
    const response = new Response(new Blob(["abc"]));
    assert.equal(await response.text(), "abc");
    assert.equal(response.bodyUsed, true);
    const reader = response.body.getReader();
    const rejection = await reader.read().then(
      () => "resolved",
      error => String(error && (error.message || error)),
    );
    assert(rejection.includes("body stream already used"));
  });
});
