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

function utf8(text) {
  return new TextEncoder().encode(text);
}

function chunkStream(chunks) {
  return new ReadableStream({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(chunk);
      controller.close();
    },
  });
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

    // A branch's cancel settles with the original's cancel, so the first one is not awaited alone.
    const leftCancel = left.cancel("left reason");
    for (let index = 0; index < 8; index++) await Promise.resolve();
    assert.equal(cancel_reason, undefined);

    await right.cancel("right reason");
    await leftCancel;
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

  test("a 17th tee in one tee tree throws a QuotaExceededError like a 17th Response.clone and leaves the stream readable", async () => {
    // WebApiBodyCloneFanoutMax (limits.h): the clones and tees one tree may make.
    const fanoutMax = 16;
    function throwsQuotaExceeded(fn) {
      const error = assert.throws(fn, DOMException);
      assert.equal(error.name, "QuotaExceededError");
      return error;
    }

    const response = new Response(new ReadableStream());
    for (let index = 0; index < fanoutMax; index++) response.clone();
    const cloneError = throwsQuotaExceeded(() => response.clone());

    for (const createRoot of [() => chunkStream([new Uint8Array([7])]), () => new Blob([new Uint8Array([7])]).stream()]) {
      // Each tee splits the oldest stream of the tree that nobody has teed yet, so the tees spread over the branches.
      const untouched = [createRoot()];
      for (let index = 0; index < fanoutMax; index++) untouched.push(...untouched.shift().tee());
      const stream = untouched.shift();
      const teeError = throwsQuotaExceeded(() => stream.tee());
      assert.equal(teeError.code, cloneError.code);

      assert.equal(stream.locked, false);
      const reader = stream.getReader();
      const first = await reader.read();
      assert.deepEqual(Array.from(first.value), [7]);
      assert.deepEqual(await reader.read(), { value: undefined, done: true });
    }
  });

  test("close resolves the reader's closed promise before it settles pending reads", async () => {
    let controller;
    const stream = new ReadableStream({
      start(value) {
        controller = value;
      },
    });
    const reader = stream.getReader();
    const order = [];
    const read = reader.read().then(() => order.push("read"));
    const closed = reader.closed.then(() => order.push("closed"));
    controller.close();
    await Promise.all([read, closed]);
    assert.deepEqual(order, ["closed", "read"]);
  });

  test("cancel closes the stream before the source's cancel runs", async () => {
    let controller;
    let desiredSize;
    let enqueueError;
    const stream = new ReadableStream({
      start(value) {
        controller = value;
      },
      cancel() {
        desiredSize = controller.desiredSize;
        try {
          controller.enqueue("late");
        } catch (error) {
          enqueueError = error;
        }
      },
    });
    const reader = stream.getReader();
    const read = reader.read();
    await reader.cancel("stop");
    assert.equal(desiredSize, 0);
    assert(enqueueError instanceof TypeError);
    assert.deepEqual(await read, { value: undefined, done: true });
  });

  test("cancel ends a pending BYOB read as done instead of rejecting it", async () => {
    const reader = new ReadableStream({ type: "bytes" }).getReader({ mode: "byob" });
    const read = reader.read(new Uint8Array(4));
    await reader.cancel("stop");
    assert.deepEqual(await read, { value: undefined, done: true });
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

  test("BYOB respondWithNewView refuses a view that does not start at the filled bytes, before it transfers anything", async () => {
    let refusal = null;
    const stream = new ReadableStream({
      type: "bytes",
      pull(controller) {
        const view = controller.byobRequest.view;
        try {
          controller.byobRequest.respondWithNewView(new Uint8Array(view.buffer, view.byteOffset + 1, 2));
        } catch (error) {
          refusal = error;
        }
        // The refusal transferred nothing, so the request's own view still writes into the read.
        view.set([4, 5]);
        controller.byobRequest.respondWithNewView(view.subarray(0, 2));
      },
    });

    const result = await stream.getReader({ mode: "byob" }).read(new Uint8Array(4));
    assert(refusal instanceof RangeError);
    assert.equal(result.done, false);
    assert.deepEqual(Array.from(result.value), [4, 5]);
  });

  test("BYOB respondWithNewView with a partial element delivers the whole elements and queues the rest", async () => {
    let pulls = 0;
    const stream = new ReadableStream({
      type: "bytes",
      pull(controller) {
        pulls += 1;
        if (pulls > 1) return;
        const view = controller.byobRequest.view;
        view.set([1, 2, 3]);
        controller.byobRequest.respondWithNewView(new Uint8Array(view.buffer, view.byteOffset, 3));
      },
    });

    const reader = stream.getReader({ mode: "byob" });
    const first = await reader.read(new Uint16Array(2));
    assert.equal(first.done, false);
    assert(first.value instanceof Uint16Array);
    assert.deepEqual(Array.from(new Uint8Array(first.value.buffer, first.value.byteOffset, first.value.byteLength)), [1, 2]);
    const second = await reader.read(new Uint8Array(4));
    assert.equal(second.done, false);
    assert.deepEqual(Array.from(second.value), [3]);
  });

  test("a BYOB read's trailing partial element is queued before the read settles, so a read its settlement starts finds it", async () => {
    // A Blob's source answers a pull at once, so the read below settles inside read(), where resolving it looks up
    // `then` on its result; the getter issues the next read from there.
    const stream = new Blob([new Uint8Array([1, 2, 3])]).stream();
    const reader = stream.getReader({ mode: "byob" });
    let nested = null;
    Object.defineProperty(Object.prototype, "then", {
      configurable: true,
      get() {
        if (nested === null && this !== null && typeof this === "object" && this.value instanceof Uint16Array) {
          delete Object.prototype.then;
          nested = reader.read(new Uint8Array(4));
        }
        return undefined;
      },
    });
    let outer;
    try {
      outer = reader.read(new Uint16Array(2));
    } finally {
      delete Object.prototype.then;
    }

    const outerResult = await outer;
    assert.equal(outerResult.done, false);
    const outerBytes = new Uint8Array(outerResult.value.buffer, outerResult.value.byteOffset, outerResult.value.byteLength);
    assert.deepEqual(Array.from(outerBytes), [1, 2]);
    assert(nested !== null, "settling the read looked up no then");
    const nestedResult = await nested;
    assert.equal(nestedResult.done, false);
    assert.deepEqual(Array.from(nestedResult.value), [3]);
    assert.equal((await reader.read(new Uint8Array(1))).done, true);
  });

  test("a byte source that responds one byte per synchronous pull fills a large min read without nesting a call per pull", async () => {
    // Enough pulls that one native frame per pull would exhaust the stack.
    const size = 65536;
    let pulls = 0;
    const stream = new ReadableStream({
      type: "bytes",
      pull(controller) {
        pulls += 1;
        controller.byobRequest.view[0] = pulls & 0xff;
        controller.byobRequest.respond(1);
      },
    });

    const { value, done } = await stream.getReader({ mode: "byob" }).read(new Uint8Array(size), { min: size });
    assert.equal(done, false);
    assert.equal(value.byteLength, size);
    assert.equal(pulls, size);
    assert.equal(value[0], 1);
    assert.equal(value[size - 1], size & 0xff);
  });

  test("byte stream sizes convert as [EnforceRange] unsigned long long, which ends at 2^53 - 1", async () => {
    for (const size of [2 ** 53, 2 ** 64, Number.MAX_VALUE])
      assert.throws(() => new ReadableStream({ type: "bytes", autoAllocateChunkSize: size }), TypeError);
    new ReadableStream({ type: "bytes", autoAllocateChunkSize: 2 ** 53 - 1 });

    const reader = new ReadableStream({ type: "bytes" }).getReader({ mode: "byob" });
    await assertRejects(reader.read(new Uint8Array(1), { min: 2 ** 53 }), TypeError);
    await assertRejects(reader.read(new Uint8Array(1), { min: 2 }), RangeError);
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

  test("Body consumption settles with the converted body itself, in the microtask of the read that ends the stream", async () => {
    let controller;
    const stream = new ReadableStream({
      start(value) {
        controller = value;
      },
    });
    const consumption = new Response(stream).arrayBuffer();
    // The consumption's read waits on the empty stream.
    for (let index = 0; index < 8; index++) await Promise.resolve();

    const order = [];
    consumption.then(() => order.push("body"));
    const markers = Promise.resolve()
      .then(() => order.push(1))
      .then(() => order.push(2))
      .then(() => order.push(3))
      .then(() => order.push(4));
    // The chunk fulfills the waiting read; its reaction takes the chunk, finds the stream closed and settles the
    // consumption, whose own reaction then runs one turn later. A promise in between would add two turns.
    controller.enqueue(utf8("abc"));
    controller.close();
    const body = await consumption;
    await markers;
    assert.deepEqual(Array.from(new Uint8Array(body)), [97, 98, 99]);
    assert(order.indexOf("body") < order.indexOf(3), `the body settled late: ${JSON.stringify(order)}`);
  });

  test("Response readable stream body consumer keeps the stream locked after chunk type error", async () => {
    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue({});
        controller.close();
      },
    });
    const response = new Response(stream);

    await assertRejects(response.text(), TypeError);
    assert.equal(stream.locked, true);
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
    assert.equal(stream.locked, true);
  });

  test("Body methods take only ArrayBuffer and ArrayBufferView chunks and reject a string chunk with a TypeError", async () => {
    const buffer = text => Uint8Array.from(text, character => character.charCodeAt(0)).buffer;
    const chunks = [
      buffer("a"),
      new Uint8Array(buffer("b")),
      new Uint8ClampedArray(buffer("c")),
      new Int8Array(buffer("d")),
      new Int16Array(buffer("ef")),
      new Uint16Array(buffer("gh")),
      new Int32Array(buffer("ijkl")),
      new Uint32Array(buffer("mnop")),
      new Float32Array(buffer("qrst")),
      new Float64Array(buffer("uvwxyz01")),
      new BigInt64Array(buffer("23456789")),
      new BigUint64Array(buffer("ABCDEFGH")),
      new DataView(buffer("IJ")),
      new Uint8Array(buffer("xKLx"), 1, 2),
    ];
    const expected = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKL";
    const request = body => new Request("https://example.test/", { method: "POST", body, duplex: "half" });

    assert.equal(await new Response(chunkStream(chunks)).text(), expected);
    assert.equal(new TextDecoder().decode(await new Response(chunkStream(chunks)).arrayBuffer()), expected);
    assert.equal(await request(chunkStream(chunks)).text(), expected);
    assert.equal(await chunkStream(chunks).text(), expected);
    const json = [buffer("{\"ok\":"), new Uint16Array(buffer("tr")), new DataView(buffer("ue}"))];
    assert.deepEqual(await new Response(chunkStream(json)).json(), { ok: true });

    const consumers = [
      stream => new Response(stream).text(),
      stream => new Response(stream).arrayBuffer(),
      stream => new Response(stream).json(),
      stream => request(stream).text(),
      stream => stream.text(),
    ];
    for (const consume of consumers) {
      await assertRejects(consume(chunkStream(["\"text\""])), TypeError);
      await assertRejects(consume(chunkStream([buffer("\""), "text\""])), TypeError);
    }
  });

  test("Body methods read a stream without calling its getReader or the reader's read", async () => {
    let calls = 0;
    const own = chunkStream([utf8("ok")]);
    own.getReader = () => {
      calls += 1;
      throw new TypeError("own getReader");
    };
    assert.equal(await new Response(own).text(), "ok");

    const originalGetReader = ReadableStream.prototype.getReader;
    const originalRead = ReadableStreamDefaultReader.prototype.read;
    try {
      ReadableStream.prototype.getReader = function () {
        calls += 1;
        throw new TypeError("patched getReader");
      };
      ReadableStreamDefaultReader.prototype.read = function () {
        calls += 1;
        throw new TypeError("patched read");
      };
      assert.equal(await new Response(chunkStream([utf8("ok")])).text(), "ok");
      const request = new Request("https://example.test/", {
        method: "POST",
        body: chunkStream([utf8("ok")]),
        duplex: "half",
      });
      assert.equal(await request.text(), "ok");
      assert.equal(await chunkStream([utf8("ok")]).text(), "ok");
    } finally {
      ReadableStream.prototype.getReader = originalGetReader;
      ReadableStreamDefaultReader.prototype.read = originalRead;
    }
    assert.equal(calls, 0);
  });

  test("a Response built from a stream returns that stream as its body and reads the chunks its pull enqueues", async () => {
    const stream = new ReadableStream({
      pull(controller) {
        controller.enqueue(utf8("hello"));
        controller.enqueue(utf8("world"));
        controller.close();
      },
    });
    const response = new Response(stream);
    assert.equal(response.body, stream);
    assert.equal(await response.text(), "helloworld");
  });

  test("ReadableStream text, json and blob join the chunks of default and byte streams, and json rejects invalid JSON with a SyntaxError", async () => {
    assert.equal(await chunkStream([utf8("ab"), utf8("cd")]).text(), "abcd");
    const byteChunks = [utf8("ab"), utf8("cd")];
    const byteStream = new ReadableStream({
      type: "bytes",
      pull(controller) {
        if (byteChunks.length) controller.enqueue(byteChunks.shift());
        else controller.close();
      },
    });
    assert.equal(await byteStream.text(), "abcd");
    assert.deepEqual(await chunkStream([utf8("{\"ok\":"), utf8("true}")]).json(), { ok: true });
    const blob = await chunkStream([utf8("hello "), utf8("world")]).blob();
    assert(blob instanceof Blob);
    assert.equal(blob.type, "");
    assert.equal(await blob.text(), "hello world");
    await assertRejects(chunkStream([utf8("{")]).json(), SyntaxError);
  });

  test("Response formData parses a multipart body from the byte chunks of start, pull and asynchronous pull sources", async () => {
    const boundary = "WebKitFormBoundary7MA4YWxkTrZu0gW";
    const parts = [
      `--${boundary}\r\n`,
      "Content-Disposition: form-data; name=\"field\"\r\n",
      "\r\n",
      "value",
      "\r\n",
      `--${boundary}\r\n`,
      "Content-Disposition: form-data; name=\"file\"; filename=\"test.txt\"\r\n",
      "Content-Type: text/plain\r\n",
      "\r\n",
      "hello world",
      "\r\n",
      `--${boundary}--\r\n`,
      "\r\n",
    ];
    const sources = [
      {
        start(controller) {
          for (const part of parts) controller.enqueue(utf8(part));
          controller.close();
        },
      },
      {
        pull(controller) {
          for (const part of parts) controller.enqueue(utf8(part));
          controller.close();
        },
      },
      {
        async pull(controller) {
          for (const part of parts) {
            await Promise.resolve();
            controller.enqueue(utf8(part));
          }
          controller.close();
        },
      },
    ];
    for (const source of sources) {
      const response = new Response(new ReadableStream(source), {
        headers: { "content-type": `multipart/form-data; boundary=${boundary}` },
      });
      const form = await response.formData();
      assert.deepEqual([...form.keys()], ["field", "file"]);
      assert.equal(form.get("field"), "value");
      const file = form.get("file");
      assert(file instanceof File);
      assert.equal(file.name, "test.txt");
      assert.equal(file.type, "text/plain");
      assert.equal(await file.text(), "hello world");
    }
  });

  test("Body methods reject a stream body beyond the materialized body limit with a QuotaExceededError", async () => {
    // One byte past WebApiMaterializedBodyBytesMax (limits.h).
    const oversized = new Uint8Array(4 * 1024 * 1024 + 1);
    for (const stream of [chunkStream([oversized]), new Blob([oversized]).stream()]) {
      const error = await assertRejects(new Response(stream).arrayBuffer(), DOMException);
      assert.equal(error.name, "QuotaExceededError");
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

  test("the sink starts through a promise, so a first write waits even when start returns synchronously", async () => {
    for (const hasStart of [true, false]) {
      const events = [];
      const sink = {
        write(chunk) {
          events.push(`write:${chunk}`);
        },
      };
      if (hasStart) {
        sink.start = () => {
          events.push("start");
        };
      }
      const writer = new WritableStream(sink).getWriter();
      const written = writer.write("a");
      assert.deepEqual(events, hasStart ? ["start"] : []);
      await written;
      assert.deepEqual(events, hasStart ? ["start", "write:a"] : ["write:a"]);
    }
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

  test("releaseLock rejects the pending ready and closed promises in place", async () => {
    const writable = new WritableStream({}, { highWaterMark: 0 });
    const writer = writable.getWriter();
    const ready = writer.ready;
    const closed = writer.closed;
    writer.releaseLock();
    assert.equal(writer.ready, ready);
    assert.equal(writer.closed, closed);
    await assertRejects(ready, TypeError);
    await assertRejects(closed, TypeError);
  });

  test("a second abort while the sink's abort is pending returns the same promise", async () => {
    let finishAbort;
    const writable = new WritableStream({
      abort() {
        return new Promise(resolve => {
          finishAbort = resolve;
        });
      },
    });
    const first = writable.abort(new Error("first"));
    const second = writable.abort(new Error("second"));
    assert.equal(second, first);
    let settled = false;
    second.then(() => {
      settled = true;
    });
    await Promise.resolve();
    await Promise.resolve();
    assert.equal(settled, false);
    finishAbort();
    await first;
    assert.equal(settled, true);
  });

  test("a writer taken while the sink's abort runs gets its closed promise rejected", async () => {
    for (const outcome of ["throws", "returns a value"]) {
      const reason = new Error("abort reason");
      let writer;
      const writable = new WritableStream({
        abort() {
          writer = writable.getWriter();
          if (outcome === "throws") throw new Error("abort failed");
          return "not a promise";
        },
      });
      const abort = writable.abort(reason).then(
        () => "resolved",
        () => "rejected",
      );
      assert(writer instanceof WritableStreamDefaultWriter);
      assert.equal(
        await writer.closed.then(
          () => "resolved",
          error => error,
        ),
        reason,
      );
      assert.equal(await abort, outcome === "throws" ? "rejected" : "resolved");
    }
  });

  test("a write the sink issues through the stream's own writer queues behind the current one", async () => {
    const written = [];
    let writer;
    const writable = new WritableStream({
      write(chunk) {
        written.push(chunk);
        if (chunk === "first") void writer.write("second");
      },
    });
    writer = writable.getWriter();
    await writer.write("first");
    await writer.ready;
    await writer.close();
    assert.deepEqual(written, ["first", "second"]);
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
    // The source pulls only for a pending read, so each pull is the pipe reading.
    const readable = new ReadableStream(
      {
        pull(controller) {
          pull_count += 1;
          events.push(`pull:${pull_count}`);
          controller.enqueue(String(pull_count));
          if (pull_count === 3) controller.close();
        },
      },
      { highWaterMark: 0 },
    );
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

    // The sink runs one write at a time, and while it runs the pipe reads the
    // next chunk into the destination's queue, which has room for two.
    const piping = readable.pipeTo(writable);
    await waitForMicrotaskCondition("pipeTo reading ahead of the first write", () => events.includes("pull:2"));
    assert.deepEqual(events, ["pull:1", "write:1", "pull:2"]);
    assert.equal(releases.length, 1);

    releases.shift()();
    await waitForMicrotaskCondition("pipeTo second write", () => events.includes("write:2") && events.includes("pull:3"));
    assert.equal(releases.length, 1);

    releases.shift()();
    await waitForMicrotaskCondition("pipeTo third write", () => events.includes("write:3"));
    releases.shift()();
    await piping;
    assert.deepEqual(events.filter(event => event.startsWith("write:")), ["write:1", "write:2", "write:3"]);
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

  describe("ReadableStream pull results, tee, from and Body consumption", () => {
    const outcome = promise => promise.then(() => "fulfilled", reason => reason);

    async function flushMicrotasks() {
      for (let index = 0; index < 8; index++) await Promise.resolve();
    }

    test("pull adopts a thenable it returns and pulls again only once that thenable settles", async () => {
      let pulls = 0;
      let settlePull;
      const stream = new ReadableStream(
        {
          pull(controller) {
            pulls += 1;
            controller.enqueue(pulls);
            return {
              then(resolve) {
                settlePull = resolve;
              },
            };
          },
        },
        { highWaterMark: 0 },
      );
      const reader = stream.getReader();
      assert.deepEqual(await reader.read(), { value: 1, done: false });
      const second = reader.read();
      await flushMicrotasks();
      assert.equal(pulls, 1);
      settlePull();
      assert.deepEqual(await second, { value: 2, done: false });
      assert.equal(pulls, 2);
    });

    test("a tee reads the original once at a time, even when that read runs script that reads a branch", async () => {
      let pulls = 0;
      const [left, right] = new ReadableStream({
        start(controller) {
          controller.enqueue("a");
          controller.enqueue("b");
        },
        pull(controller) {
          pulls += 1;
          controller.enqueue(`p${pulls}`);
        },
      }).tee();
      const leftReader = left.getReader();
      const rightReader = right.getReader();
      // Both branches take "a" and, holding one chunk each, want no more.
      await flushMicrotasks();

      let reenter = null;
      Object.defineProperty(Object.prototype, "then", {
        configurable: true,
        get() {
          const action = reenter;
          reenter = null;
          if (action) action();
          return undefined;
        },
      });
      let leftFirst;
      let rightFirst;
      try {
        // Reading "a" from the left branch makes the tee read "b" from the original. Settling that read looks up
        // `then` on its result, and the getter reads "a" from the right branch, which asks the tee for a chunk again.
        reenter = () => {
          rightFirst = rightReader.read();
        };
        leftFirst = leftReader.read();
      } finally {
        delete Object.prototype.then;
      }
      assert.deepEqual(await leftFirst, { value: "a", done: false });
      assert.deepEqual(await rightFirst, { value: "a", done: false });
      assert.deepEqual(await leftReader.read(), { value: "b", done: false });
      assert.deepEqual(await leftReader.read(), { value: "p1", done: false });
      assert.deepEqual(await rightReader.read(), { value: "b", done: false });
    });

    test("a tee keeps its read in flight until the chunk reached both branches, so a branch read from a then getter loses nothing", async () => {
      let controller;
      const [left, right] = new ReadableStream({
        start(value) {
          controller = value;
        },
      }).tee();
      const leftReader = left.getReader();
      const rightReader = right.getReader();
      const leftFirst = leftReader.read();
      await flushMicrotasks();

      // The first result holding "a" is the tee's read of the original, settled inside enqueue(). The second is the
      // left branch's, settled while the tee hands "a" to the branches; the getter reads the right branch from there,
      // which asks the tee for a chunk while "a" is still on its way to the right branch.
      let sightings = 0;
      let nested = null;
      Object.defineProperty(Object.prototype, "then", {
        configurable: true,
        get() {
          if (this !== null && typeof this === "object" && this.value === "a" && ++sightings === 2) {
            delete Object.prototype.then;
            nested = rightReader.read();
          }
          return undefined;
        },
      });
      try {
        controller.enqueue("a");
        controller.enqueue("b");
        controller.close();
        await flushMicrotasks();
      } finally {
        delete Object.prototype.then;
      }

      assert(nested !== null, "settling the left read looked up no then");
      assert.deepEqual(await leftFirst, { value: "a", done: false });
      assert.deepEqual(await nested, { value: "a", done: false });
      assert.deepEqual(await leftReader.read(), { value: "b", done: false });
      assert.deepEqual(await leftReader.read(), { value: undefined, done: true });
      assert.deepEqual(await rightReader.read(), { value: "b", done: false });
      assert.deepEqual(await rightReader.read(), { value: undefined, done: true });
    });

    test("a tee of a native stream with bytes already queued reads them first, so both branches get every byte", async () => {
      const total = 100000;
      const data = new Uint8Array(total);
      for (let index = 0; index < total; index++) data[index] = index & 0xff;
      const stream = new Blob([data]).stream();
      // The Blob's source hands over its first chunk whole; the read takes 10 bytes and the rest stays queued.
      const reader = stream.getReader({ mode: "byob" });
      const first = await reader.read(new Uint8Array(10));
      assert.deepEqual(Array.from(first.value), Array.from(data.subarray(0, 10)));
      reader.releaseLock();

      const [left, right] = stream.tee();
      const [leftBytes, rightBytes] = await Promise.all([collectBytes(left), collectBytes(right)]);
      for (const bytes of [leftBytes, rightBytes]) {
        assert.equal(bytes.byteLength, total - 10);
        assert.deepEqual(Array.from(bytes.subarray(0, 4)), Array.from(data.subarray(10, 14)));
        assert.deepEqual(Array.from(bytes.subarray(bytes.byteLength - 4)), Array.from(data.subarray(total - 4)));
      }
    });

    test("tee branches' cancels share one promise that follows the original's cancel, or resolves when the original ends first", async () => {
      const cancelError = new Error("cancel failed");
      const [left, right] = new ReadableStream({
        cancel() {
          throw cancelError;
        },
      }).tee();
      const leftCancel = left.cancel("left");
      const rightCancel = right.cancel("right");
      assert.equal(await outcome(leftCancel), cancelError);
      assert.equal(await outcome(rightCancel), cancelError);

      let closeController;
      const [first, second] = new ReadableStream({
        start(controller) {
          closeController = controller;
        },
      }).tee();
      let firstSettled = false;
      const firstCancel = first.cancel("first").then(() => {
        firstSettled = true;
      });
      await flushMicrotasks();
      assert.equal(firstSettled, false);
      closeController.close();
      await firstCancel;
      assert.deepEqual(await second.getReader().read(), { value: undefined, done: true });

      let errorController;
      const [third] = new ReadableStream({
        start(controller) {
          errorController = controller;
        },
      }).tee();
      const thirdCancel = third.cancel("third");
      errorController.error(new Error("source failed"));
      assert.equal(await thirdCancel, undefined);
    });

    test("a tee errors both branches as soon as the original errors, with no read in flight", async () => {
      const sourceError = new Error("source failed");
      let sourceController;
      const [left, right] = new ReadableStream({
        start(controller) {
          sourceController = controller;
          controller.enqueue("x");
        },
      }).tee();
      // Both branches take "x"; the tee then has no read in flight.
      await flushMicrotasks();
      sourceController.error(sourceError);
      await flushMicrotasks();
      for (const branch of [left, right])
        assert.equal(await outcome(branch.getReader().read()), sourceError);
    });

    test("a tee closes both branches when the original closes while the tee is idle, or was closed before the tee", async () => {
      async function expectDone(reader, label) {
        let result;
        reader.read().then(value => {
          result = value;
        });
        await waitForMicrotaskCondition(label, () => result !== undefined);
        assert.deepEqual(result, { value: undefined, done: true });
      }

      let sourceController;
      const [left, right] = new ReadableStream({
        start(controller) {
          sourceController = controller;
          controller.enqueue("x");
        },
      }).tee();
      await flushMicrotasks();
      sourceController.close();
      for (const branch of [left, right]) {
        const reader = branch.getReader();
        assert.deepEqual(await reader.read(), { value: "x", done: false });
        await expectDone(reader, "a branch of an original that closed while the tee was idle closes");
      }

      const closed = new ReadableStream({
        start(controller) {
          controller.close();
        },
      });
      for (const branch of closed.tee())
        await expectDone(branch.getReader(), "a branch of a closed stream closes");
    });

    test("ReadableStream.from keeps a sync iterator's rejected value as the error when closing the iterator throws", async () => {
      const throwingReturn = {
        [Symbol.iterator]() {
          return this;
        },
        next() {
          return { done: false, value: Promise.reject("value") };
        },
        return() {
          throw "return";
        },
      };
      assert.equal(await outcome(ReadableStream.from(throwingReturn).getReader().read()), "value");

      const throwingGetter = {
        [Symbol.iterator]() {
          return this;
        },
        next() {
          return { done: false, value: Promise.reject("value") };
        },
        get return() {
          throw "getter";
        },
      };
      assert.equal(await outcome(ReadableStream.from(throwingGetter).getReader().read()), "value");
    });

    test("ReadableStream.from reads and awaits the value of a sync iterator's done result before closing", async () => {
      let valueReads = 0;
      const plain = {
        [Symbol.iterator]() {
          return this;
        },
        next() {
          return {
            done: true,
            get value() {
              valueReads += 1;
              return "ignored";
            },
          };
        },
      };
      assert.deepEqual(await ReadableStream.from(plain).getReader().read(), { value: undefined, done: true });
      assert.equal(valueReads, 1);

      let returnCalls = 0;
      const rejecting = {
        [Symbol.iterator]() {
          return this;
        },
        next() {
          return { done: true, value: Promise.reject("late") };
        },
        return() {
          returnCalls += 1;
          return {};
        },
      };
      assert.equal(await outcome(ReadableStream.from(rejecting).getReader().read()), "late");
      // The iterator said it was done, so its rejected value does not close it.
      assert.equal(returnCalls, 0);
    });

    test("Body consumption leaves the stream locked after it succeeds or fails, drained in one step or read chunk by chunk", async () => {
      const drained = new Blob([utf8("abc")]).stream();
      assert.equal(await new Response(drained).text(), "abc");
      assert.equal(drained.locked, true);
      assert.throws(() => drained.getReader(), TypeError);

      const read = chunkStream([utf8("abc")]);
      assert.equal(await new Response(read).text(), "abc");
      assert.equal(read.locked, true);

      const failed = chunkStream(["not bytes"]);
      await assertRejects(new Response(failed).text(), TypeError);
      assert.equal(failed.locked, true);
    });
  });

  test("pipes sharing an AbortSignal each abort once, including those after pipes that settle during the abort", async () => {
    const controller = new AbortController();
    const reason = new Error("stop");
    // Every other pipe, starting with the first, prevents both actions, so it settles while the signal is still running
    // its abort steps for the pipes after it.
    const pipes = [];
    for (let index = 0; index < 6; index++) {
      const pipe = { prevent: index % 2 === 0, cancels: [], aborts: [] };
      pipe.source = new ReadableStream({
        cancel(value) {
          pipe.cancels.push(value);
        },
      });
      pipe.destination = new WritableStream({
        abort(value) {
          pipe.aborts.push(value);
        },
      });
      const options = pipe.prevent
        ? { signal: controller.signal, preventAbort: true, preventCancel: true }
        : { signal: controller.signal };
      pipe.result = pipe.source.pipeTo(pipe.destination, options).then(
        () => "resolved",
        error => error,
      );
      pipes.push(pipe);
    }

    controller.abort(reason);
    for (const pipe of pipes) {
      assert.equal(await pipe.result, reason);
      assert.deepEqual(pipe.cancels, pipe.prevent ? [] : [reason]);
      assert.deepEqual(pipe.aborts, pipe.prevent ? [] : [reason]);
      assert.equal(pipe.source.locked, false);
      assert.equal(pipe.destination.locked, false);
    }
  });

  describe("shutdown conditions and actions", () => {
    // The pipe's outcome, "resolved" or its rejection reason. Fails once the pipe is still pending after more
    // microtasks than any pipe here needs, so a pipe that never settles fails at once.
    async function outcome(promise) {
      const pending = {};
      let result = pending;
      promise.then(
        () => {
          result = "resolved";
        },
        error => {
          result = error;
        },
      );
      for (let tick = 0; tick < 64 && result === pending; tick++) await Promise.resolve();
      if (result === pending) throw new Error("the pipe did not settle");
      return result;
    }

    test("an already closed or errored source ends a pipe into a destination whose highWaterMark is 0", async () => {
      let closed = false;
      const closing = new ReadableStream({
        start(controller) {
          controller.close();
        },
      }).pipeTo(
        new WritableStream(
          {
            close() {
              closed = true;
            },
          },
          { highWaterMark: 0 },
        ),
      );
      assert.equal(await outcome(closing), "resolved");
      assert.equal(closed, true);

      const broken = new Error("broken");
      let aborted;
      const aborting = new ReadableStream({
        start(controller) {
          controller.error(broken);
        },
      }).pipeTo(
        new WritableStream(
          {
            abort(reason) {
              aborted = reason;
            },
          },
          { highWaterMark: 0 },
        ),
      );
      assert.equal(await outcome(aborting), broken);
      assert.equal(aborted, broken);
    });

    test("a destination its controller errors while the source idles rejects the pipe and cancels the source", async () => {
      const broken = new Error("broken");
      let destinationController;
      let canceled;
      const source = new ReadableStream({
        cancel(reason) {
          canceled = reason;
        },
      });
      const destination = new WritableStream({
        start(controller) {
          destinationController = controller;
        },
      });
      const piping = source.pipeTo(destination);
      await Promise.resolve();
      destinationController.error(broken);
      assert.equal(await outcome(piping), broken);
      assert.equal(canceled, broken);
    });

    test("a destination errored before the source closes rejects the pipe with the destination's error", async () => {
      const broken = new Error("broken");
      let sourceController;
      let destinationController;
      const source = new ReadableStream({
        start(controller) {
          sourceController = controller;
        },
      });
      const destination = new WritableStream({
        start(controller) {
          destinationController = controller;
        },
      });
      const piping = source.pipeTo(destination);
      await Promise.resolve();
      destinationController.error(broken);
      sourceController.close();
      assert.equal(await outcome(piping), broken);
    });

    test("a closed source piped into a destination that is closed or closing resolves", async () => {
      const closedDestination = new WritableStream();
      const closedWriter = closedDestination.getWriter();
      await closedWriter.close();
      closedWriter.releaseLock();

      const closingDestination = new WritableStream({
        close() {
          return new Promise(() => {});
        },
      });
      const closingWriter = closingDestination.getWriter();
      void closingWriter.close();
      closingWriter.releaseLock();

      for (const destination of [closedDestination, closingDestination]) {
        const source = new ReadableStream({
          start(controller) {
            controller.close();
          },
        });
        assert.equal(await outcome(source.pipeTo(destination)), "resolved");
        assert.equal(destination.locked, false);
      }
    });

    test("a write queued before the pipe took the lock does not stall the pipe once it finishes", async () => {
      const written = [];
      let releaseFirst;
      const destination = new WritableStream({
        write(chunk) {
          written.push(chunk);
          if (chunk === "x") {
            return new Promise(resolve => {
              releaseFirst = resolve;
            });
          }
        },
      });
      const writer = destination.getWriter();
      const first = writer.write("x");
      writer.releaseLock();
      const source = new ReadableStream({
        start(controller) {
          controller.enqueue("y");
          controller.close();
        },
      });
      const piping = source.pipeTo(destination);
      await waitForMicrotaskCondition("the queued write to reach the sink", () => typeof releaseFirst === "function");
      releaseFirst();
      await first;
      assert.equal(await outcome(piping), "resolved");
      assert.deepEqual(written, ["x", "y"]);
    });

    test("a source that closes while backpressure holds the pipe closes the destination, even if the signal aborts later", async () => {
      const controller = new AbortController();
      let sourceController;
      let releaseWrite;
      let closed = false;
      let aborted = false;
      const source = new ReadableStream({
        start(streamController) {
          sourceController = streamController;
          streamController.enqueue("a");
        },
      });
      const destination = new WritableStream({
        write() {
          return new Promise(resolve => {
            releaseWrite = resolve;
          });
        },
        close() {
          closed = true;
        },
        abort() {
          aborted = true;
        },
      });
      const piping = source.pipeTo(destination, { signal: controller.signal });
      await waitForMicrotaskCondition("the first write to reach the sink", () => typeof releaseWrite === "function");
      sourceController.close();
      // The pipe sees the close when the source reader's closed promise resolves, a microtask later.
      await Promise.resolve();
      await Promise.resolve();
      controller.abort("stop");
      releaseWrite();
      assert.equal(await outcome(piping), "resolved");
      assert.equal(closed, true);
      assert.equal(aborted, false);
    });

    test("a chunk the source delivers while a shutdown waits for writes is written before the destination is aborted", async () => {
      const controller = new AbortController();
      const written = [];
      let sourceController;
      let releaseWrite;
      let aborted;
      let canceled;
      let pulls = 0;
      // A source of highWaterMark 0 pulls only for a pending read, so its second pull shows the pipe's second read.
      const source = new ReadableStream(
        {
          pull(streamController) {
            pulls += 1;
            if (pulls === 1) {
              streamController.enqueue("x");
              return undefined;
            }
            sourceController = streamController;
            return new Promise(() => {});
          },
          cancel(reason) {
            canceled = reason;
          },
        },
        { highWaterMark: 0 },
      );
      // Room for two chunks, so the pipe reads again while the sink still writes the first.
      const destination = new WritableStream(
        {
          write(chunk) {
            written.push(chunk);
            if (chunk === "x") {
              return new Promise(resolve => {
                releaseWrite = resolve;
              });
            }
          },
          abort(reason) {
            aborted = reason;
          },
        },
        { highWaterMark: 2 },
      );
      const piping = source.pipeTo(destination, { signal: controller.signal });
      await waitForMicrotaskCondition("a second read during the first write", () => pulls === 2 && releaseWrite !== undefined);
      controller.abort("stop");
      releaseWrite();
      // The chunk arrives after the first write has finished but before the pipe has seen it finish.
      await Promise.resolve();
      sourceController.enqueue("y");
      assert.equal(await outcome(piping), "stop");
      assert.deepEqual(written, ["x", "y"]);
      assert.equal(aborted, "stop");
      assert.equal(canceled, "stop");
    });

    test("the first shutdown action to reject gives the pipe its reason without waiting for the other", async () => {
      async function abortPipe(cancel) {
        const controller = new AbortController();
        const source = new ReadableStream({ cancel });
        const destination = new WritableStream({
          abort() {
            return Promise.reject("a");
          },
        });
        const piping = source.pipeTo(destination, { signal: controller.signal });
        // Lets the destination start, so the abort reaches its sink at once.
        for (let tick = 0; tick < 4; tick++) await Promise.resolve();
        controller.abort("stop");
        return outcome(piping);
      }
      assert.equal(await abortPipe(() => Promise.reject("c")), "a");
      assert.equal(await abortPipe(() => new Promise(() => {})), "a");
    });

    test("a signal abort leaves an errored source alone, so the pipe rejects with the signal's reason", async () => {
      const broken = new Error("broken");
      const controller = new AbortController();
      controller.abort("stop");
      let aborted;
      const source = new ReadableStream({
        start(streamController) {
          streamController.error(broken);
        },
      });
      const destination = new WritableStream({
        abort(reason) {
          aborted = reason;
        },
      });
      assert.equal(await outcome(source.pipeTo(destination, { signal: controller.signal })), "stop");
      assert.equal(aborted, "stop");
    });

    test("pipeTo marks the source disturbed even when it never reads from it", async () => {
      // A Response's bodyUsed reports whether its stream is disturbed; a constructor that refuses a disturbed stream
      // reports it too.
      function disturbed(stream) {
        try {
          return new Response(stream).bodyUsed;
        } catch (error) {
          return error instanceof TypeError;
        }
      }
      assert.equal(disturbed(new ReadableStream()), false);

      const aborted = new AbortController();
      aborted.abort("stop");
      const preAborted = new ReadableStream();
      const preAbortedOptions = { signal: aborted.signal, preventCancel: true };
      assert.equal(await outcome(preAborted.pipeTo(new WritableStream(), preAbortedOptions)), "stop");
      assert.equal(preAborted.locked, false);
      assert.equal(disturbed(preAborted), true);

      const controller = new AbortController();
      const held = new ReadableStream();
      const piping = held.pipeTo(new WritableStream({}, { highWaterMark: 0 }), {
        signal: controller.signal,
        preventCancel: true,
      });
      await Promise.resolve();
      controller.abort("stop");
      assert.equal(await outcome(piping), "stop");
      assert.equal(disturbed(held), true);
    });
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

  test("returns its promise when the pipe settles before pipeTo returns", async () => {
    const broken = new Error("broken");
    const destination = new WritableStream({
      start(controller) {
        controller.error(broken);
      },
    });
    const promise = new ReadableStream().pipeTo(destination, { preventCancel: true });
    assert(promise instanceof Promise);
    assert.equal(await promise.then(
      () => "resolved",
      error => error,
    ), broken);
  });

  test("converts its options before it checks the locks", async () => {
    const source = new ReadableStream();
    source.getReader();
    let read = false;
    const options = {
      get preventAbort() {
        read = true;
        return false;
      },
    };
    await assertRejects(source.pipeTo(new WritableStream(), options), TypeError);
    assert.equal(read, true);
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

  test("a transform that writes through the stream's own writer gets both chunks out in order", async () => {
    let writer;
    const stream = new TransformStream(
      {
        transform(chunk, controller) {
          controller.enqueue(chunk);
          if (chunk === "first") void writer.write("second");
        },
      },
      undefined,
      { highWaterMark: 1 },
    );
    writer = stream.writable.getWriter();
    const reader = stream.readable.getReader();
    const first = writer.write("first");
    assert.deepEqual(await reader.read(), { value: "first", done: false });
    assert.deepEqual(await reader.read(), { value: "second", done: false });
    await first;
  });
});

describe("TransformStream with a native transformer", () => {
  // The promise's outcome after more microtask turns than any step here takes: { pending: true }, { value } or
  // { error }.
  async function outcomeSoon(promise) {
    let outcome = { pending: true };
    promise.then(
      value => {
        outcome = { value };
      },
      error => {
        outcome = { error };
      },
    );
    for (let index = 0; index < 32; index++) await Promise.resolve();
    return outcome;
  }

  async function flush() {
    for (let index = 0; index < 8; index++) await Promise.resolve();
  }

  test("a write waits for a pull before its chunk reaches the transformer", async () => {
    const encoder = new TextEncoderStream();
    const writer = encoder.writable.getWriter();
    let conversions = 0;
    const write = writer.write({
      toString() {
        conversions += 1;
        return "";
      },
    });
    assert.deepEqual(await outcomeSoon(write), { pending: true });
    assert.equal(conversions, 0);
    const reader = encoder.readable.getReader();
    const read = reader.read();
    // The chunk converts to no output, so the write settles with the read still waiting.
    assert.deepEqual(await outcomeSoon(write), { value: undefined });
    assert.equal(conversions, 1);
    await writer.close();
    assert.deepEqual(await read, { value: undefined, done: true });

    // A fatal decoder meets the invalid byte only once a read lets the write through.
    const decoder = new TextDecoderStream("utf-8", { fatal: true });
    const decoderWriter = decoder.writable.getWriter();
    const decoderWrite = decoderWriter.write(new Uint8Array([0xff]));
    assert.deepEqual(await outcomeSoon(decoderWrite), { pending: true });
    const decoderRead = decoder.readable.getReader().read();
    assert((await outcomeSoon(decoderWrite)).error instanceof TypeError);
    await assertRejects(decoderRead, TypeError);
  });

  test("a pull lifts backpressure until output is enqueued, so a write after its reader let go still converts at once", async () => {
    const encoder = new TextEncoderStream();
    const writer = encoder.writable.getWriter();
    const firstReader = encoder.readable.getReader();
    const released = firstReader.read().catch(() => "released");
    await flush();
    firstReader.releaseLock();
    assert.equal(await released, "released");

    let conversions = 0;
    const write = writer.write({
      toString() {
        conversions += 1;
        return "y";
      },
    });
    // The chunk converts now; its output waits for a read.
    assert.deepEqual(await outcomeSoon(write), { pending: true });
    assert.equal(conversions, 1);
    const reader = encoder.readable.getReader();
    assert.deepEqual(Array.from((await reader.read()).value), [0x79]);
    assert.deepEqual(await outcomeSoon(write), { value: undefined });
  });

  test("a read made from a write's conversion waits for that write's output", async () => {
    const encoder = new TextEncoderStream();
    const reader = encoder.readable.getReader();
    const writer = encoder.writable.getWriter();
    // Both sides have started, so the write below reaches the transformer inside write().
    await writer.ready;
    await flush();
    const first = reader.read();
    let nested = null;
    const write = writer.write({
      toString() {
        nested = reader.read();
        return "x";
      },
    });
    assert.deepEqual(await outcomeSoon(write), { value: undefined });
    assert.deepEqual(Array.from((await first).value), [0x78]);
    await writer.close();
    assert(nested !== null, "the conversion never ran");
    assert.deepEqual(await nested, { value: undefined, done: true });
  });

  test("close resolves once the last output is enqueued, before any read takes it", async () => {
    const encoder = new TextEncoderStream();
    const encoderReader = encoder.readable.getReader();
    const encoderWriter = encoder.writable.getWriter();
    const firstEncoded = encoderReader.read();
    await encoderWriter.write("a\uD83D");
    assert.deepEqual(Array.from((await firstEncoded).value), [0x61]);
    // The lead surrogate the write carried becomes U+FFFD at close.
    assert.deepEqual(await outcomeSoon(encoderWriter.close()), { value: undefined });
    assert.deepEqual(Array.from((await encoderReader.read()).value), [0xef, 0xbf, 0xbd]);
    assert.deepEqual(await encoderReader.read(), { value: undefined, done: true });

    const decoder = new TextDecoderStream();
    const decoderReader = decoder.readable.getReader();
    const decoderWriter = decoder.writable.getWriter();
    const firstDecoded = decoderReader.read();
    await decoderWriter.write(new Uint8Array([0x41, 0xe2]));
    assert.deepEqual(await firstDecoded, { value: "A", done: false });
    assert.deepEqual(await outcomeSoon(decoderWriter.close()), { value: undefined });
    assert.deepEqual(await decoderReader.read(), { value: "�", done: false });
    assert.deepEqual(await decoderReader.read(), { value: undefined, done: true });

    const compressor = new CompressionStream("gzip");
    const compressorReader = compressor.readable.getReader();
    const compressorWriter = compressor.writable.getWriter();
    const firstCompressed = compressorReader.read();
    await compressorWriter.write(utf8("hello"));
    assert.deepEqual(await outcomeSoon(compressorWriter.close()), { value: undefined });
    const chunks = [];
    for (let result = await firstCompressed; !result.done; result = await compressorReader.read())
      chunks.push(result.value);
    const decompressed = new Blob(chunks).stream().pipeThrough(new DecompressionStream("gzip"));
    assert.equal(await new Response(decompressed).text(), "hello");
  });

  test("a write whose conversion cancels the readable side rejects with the cancel's reason", async () => {
    const encoder = new TextEncoderStream();
    const reader = encoder.readable.getReader();
    const writer = encoder.writable.getWriter();
    const reason = new Error("canceled during the conversion");
    const read = reader.read();
    let cancel = null;
    const write = writer.write({
      toString() {
        cancel = reader.cancel(reason);
        return "x";
      },
    });
    const outcome = await outcomeSoon(write);
    assert.equal(outcome.error, reason);
    assert.deepEqual(await read, { value: undefined, done: true });
    assert(cancel !== null, "the conversion never ran");
    assert.equal(await cancel, undefined);
  });

  test("each class's readable and writable accessors accept only its own instances", () => {
    const classes = { TransformStream, CompressionStream, DecompressionStream, TextEncoderStream, TextDecoderStream };
    const instances = {
      TransformStream: new TransformStream(),
      CompressionStream: new CompressionStream("gzip"),
      DecompressionStream: new DecompressionStream("gzip"),
      TextEncoderStream: new TextEncoderStream(),
      TextDecoderStream: new TextDecoderStream(),
    };
    for (const [className, Class] of Object.entries(classes)) {
      for (const [instanceName, instance] of Object.entries(instances)) {
        for (const [side, Side] of [["readable", ReadableStream], ["writable", WritableStream]]) {
          if (className === instanceName) {
            assert(Reflect.get(Class.prototype, side, instance) instanceof Side, `${className}.prototype.${side}`);
          } else {
            assert.throws(
              () => Reflect.get(Class.prototype, side, instance),
              TypeError,
              `${className}.prototype.${side} accepted a ${instanceName}`,
            );
          }
        }
      }
    }
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

  test("throws a TypeError when the source or the transform's writable is locked", () => {
    const lockedSource = new ReadableStream();
    lockedSource.getReader();
    assert.throws(() => lockedSource.pipeThrough(new TransformStream()), TypeError);

    const transform = new TransformStream();
    transform.writable.getWriter();
    assert.throws(() => new ReadableStream().pipeThrough(transform), TypeError);
  });

  test("reads the pair's readable before its writable", () => {
    const order = [];
    const transform = new TransformStream();
    const pair = {
      get writable() {
        order.push("writable");
        return transform.writable;
      },
      get readable() {
        order.push("readable");
        return transform.readable;
      },
    };
    new ReadableStream().pipeThrough(pair);
    assert.deepEqual(order, ["readable", "writable"]);
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
    const expectedLength = 512 * 1024;
    const compressed = await compressedBytes("gzip", "A".repeat(expectedLength));
    const stream = new DecompressionStream("gzip");
    const writer = stream.writable.getWriter();
    let writeSettled = false;
    const writePromise = writer.write(compressed).then(() => {
      writeSettled = true;
    });

    await Promise.resolve();
    await Promise.resolve();
    assert.equal(writeSettled, false);

    // The last chunk can reach a read in the same step that completes the
    // write, so the loop reads the known length instead of waiting for the
    // write to settle.
    const reader = stream.readable.getReader();
    let decodedLength = 0;
    let reads = 0;
    while (decodedLength < expectedLength) {
      const { done, value } = await reader.read();
      assert.equal(done, false);
      decodedLength += value.byteLength;
      reads += 1;
    }
    await writePromise;
    assert.equal(decodedLength, expectedLength);
    assert(reads > 1);
    await writer.close();
    assert.deepEqual(await reader.read(), { value: undefined, done: true });
  });

  // Resolving a pending read looks up `then` on the read result, so a getter
  // on Object.prototype runs script in the middle of a delivery. The getter
  // matches only read results and is removed before the test awaits anything
  // else.
  function onReadResult(callback) {
    Object.defineProperty(Object.prototype, "then", {
      configurable: true,
      get() {
        if (this !== null && typeof this === "object" && Object.hasOwn(this, "done") && Object.hasOwn(this, "value"))
          callback(this);
        return undefined;
      },
    });
  }

  test("a then getter that cancels during a delivery settles the read and the cancel", async () => {
    for (const format of ["brotli", "gzip", "deflate", "deflate-raw"]) {
      const compressed = await compressedBytes(format, "A".repeat(256 * 1024));
      const stream = new DecompressionStream(format);
      const reader = stream.readable.getReader();
      const writer = stream.writable.getWriter();
      const read = reader.read();
      let cancel = null;
      let write = null;
      onReadResult(() => {
        if (cancel === null) cancel = reader.cancel("stop");
      });
      try {
        write = writer.write(compressed).then(
          () => "resolved",
          error => error,
        );
        const result = await read;
        assert.equal(result.done, false);
        assert(result.value instanceof Uint8Array);
      } finally {
        delete Object.prototype.then;
      }
      assert(cancel !== null, "the getter cancelled the stream");
      assert.equal(await cancel, undefined);
      assert.equal(await write, "stop");
    }
  });

  test("a then getter that reads during a delivery gets the output once and in order", async () => {
    const text = "0123456789abcdef".repeat(16 * 1024);
    for (const format of ["brotli", "gzip", "deflate", "deflate-raw"]) {
      const compressed = await compressedBytes(format, text);
      const stream = new DecompressionStream(format);
      const reader = stream.readable.getReader();
      const writer = stream.writable.getWriter();
      const reads = [reader.read()];
      onReadResult(result => {
        if (result.done === false && reads.length < 1024) reads.push(reader.read());
      });
      try {
        await writer.write(compressed);
      } finally {
        delete Object.prototype.then;
      }
      const closing = writer.close();
      const chunks = [];
      let done = false;
      for (const pending of reads) {
        const result = await pending;
        if (result.done) {
          done = true;
          break;
        }
        chunks.push(result.value);
      }
      while (!done) {
        const result = await reader.read();
        done = result.done;
        if (!done) chunks.push(result.value);
      }
      await closing;
      assert.equal(new TextDecoder().decode(concatUint8(chunks)), text);
    }
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

  // A write reaches the codec, which checks its chunk, only once a read waits.
  function readingCompressionWriter() {
    const stream = new CompressionStream("gzip");
    stream.readable.getReader().read().catch(() => {});
    return stream.writable.getWriter();
  }

  test("compression write rejects non-BufferSource chunks including strings", async () => {
    // Per the Compression spec, chunks must be BufferSource.
    for (const chunk of [{}, "hello", 42, null, undefined]) {
      const writer = readingCompressionWriter();
      assert(await writer.write(chunk).then(
        () => false,
        error => error instanceof TypeError,
      ));
    }
  });

  test("compression write rejects unavailable BufferSource chunks", async () => {
    const detached = new ArrayBuffer(8);
    structuredClone(detached, { transfer: [detached] });
    const writer = readingCompressionWriter();
    await assertRejects(writer.write(detached), TypeError);

    if (typeof ArrayBuffer.prototype.resize === "function") {
      const resizable = new ArrayBuffer(8, { maxByteLength: 8 });
      const resizableWriter = readingCompressionWriter();
      await assertRejects(resizableWriter.write(resizable), TypeError);

      const buffer = new ArrayBuffer(8, { maxByteLength: 8 });
      const view = new Uint8Array(buffer, 4, 4);
      buffer.resize(2);

      const viewWriter = readingCompressionWriter();
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

  test("releaseLock rejects a reader's pending closed promise in place", async () => {
    const reader = new ReadableStream().getReader();
    const closed = reader.closed;
    reader.releaseLock();
    assert.equal(reader.closed, closed);
    await assertRejects(closed, TypeError);
  });

  test("a pending read's promise exposes no property of the stream's own", () => {
    const reader = new ReadableStream().getReader();
    const read = reader.read();
    assert.deepEqual(Object.getOwnPropertyNames(read), []);
    assert.deepEqual(Object.getOwnPropertySymbols(read), []);
    const byobRead = new ReadableStream({ type: "bytes" }).getReader({ mode: "byob" }).read(new Uint8Array(4));
    assert.deepEqual(Object.getOwnPropertyNames(byobRead), []);
    assert.deepEqual(Object.getOwnPropertySymbols(byobRead), []);
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

  test("a Blob stream fulfills a read from its synchronous source before a releaseLock right after it", async () => {
    // A deliberate departure from the File API, whose Blob stream reads its bytes in parallel and so always answers a
    // pull later: Collo's Blob source answers at once, from bytes already in memory.
    const stream = new Blob(["abc"]).stream();
    const reader = stream.getReader();
    const pending = reader.read();
    reader.releaseLock();

    const first = await pending;
    assert.equal(first.done, false);
    assert.equal(new TextDecoder().decode(first.value), "abc");
    assert.deepEqual(await stream.getReader().read(), { value: undefined, done: true });
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

describe("Sink and transformer callbacks, abort and chunk checks", () => {
  // The promise's outcome after a bounded number of microtask turns, so a promise that never settles fails the
  // assertion instead of stalling the test.
  async function outcomeAfterMicrotasks(promise) {
    let outcome = { pending: true };
    promise.then(
      value => {
        outcome = { value };
      },
      error => {
        outcome = { error };
      },
    );
    for (let index = 0; index < 32; index++) await Promise.resolve();
    return outcome;
  }

  test("32768 writes that each finish synchronously complete without nesting a native call per write", async () => {
    // A few native frames per write exhaust an 8 MiB stack in about ten thousand writes, so this many would overflow it
    // if writes nested, while staying small enough for the forced-collection profile.
    const count = 32768;
    const transform = new TransformStream(undefined, undefined, { highWaterMark: Infinity });
    const writer = transform.writable.getWriter();
    for (let index = 0; index < count; index++) writer.write(index);
    await writer.close();
    const reader = transform.readable.getReader();
    for (let index = 0; index < count; index++) {
      const { value } = await reader.read();
      if (value !== index) assert.equal(value, index);
    }
    assert.equal((await reader.read()).done, true);

    let written = 0;
    const sink = new WritableStream(
      {
        write() {
          written++;
        },
      },
      { highWaterMark: Infinity },
    );
    const sinkWriter = sink.getWriter();
    for (let index = 0; index < count; index++) sinkWriter.write(index);
    await sinkWriter.close();
    assert.equal(written, count);
  });

  test("a sink's write and close adopt the thenables they return", async () => {
    const events = [];
    const resolvers = [];
    const thenable = name => ({
      then(resolve) {
        events.push(name);
        resolvers.push(resolve);
      },
    });
    const stream = new WritableStream({
      write(chunk) {
        return thenable(`write ${chunk}`);
      },
      close() {
        return thenable("close");
      },
    });
    const writer = stream.getWriter();
    const write = writer.write("a").then(() => events.push("write settled"));
    const close = writer.close().then(() => events.push("close settled"));
    await waitForMicrotaskCondition("the write's then", () => events.length > 0);
    assert.deepEqual(events, ["write a"]);
    resolvers.shift()();
    await write;
    await waitForMicrotaskCondition("the close's then", () => events.includes("close"));
    assert.deepEqual(events, ["write a", "write settled", "close"]);
    resolvers.shift()();
    await close;
    assert.deepEqual(events, ["write a", "write settled", "close", "close settled"]);
  });

  test("a sink's abort adopts the thenable it returns", async () => {
    const events = [];
    let resolveAbort = null;
    const stream = new WritableStream({
      abort() {
        return {
          then(resolve) {
            events.push("then");
            resolveAbort = resolve;
          },
        };
      },
    });
    await Promise.resolve();
    const abort = stream.abort("stop").then(() => events.push("abort settled"));
    await waitForMicrotaskCondition("the abort's then", () => events.length > 0);
    assert.deepEqual(events, ["then"]);
    resolveAbort();
    await abort;
    assert.deepEqual(events, ["then", "abort settled"]);
  });

  test("a transformer's transform and flush adopt the thenables they return", async () => {
    const events = [];
    const resolvers = [];
    const thenable = name => ({
      then(resolve) {
        events.push(name);
        resolvers.push(resolve);
      },
    });
    const stream = new TransformStream(
      {
        transform(chunk) {
          return thenable(`transform ${chunk}`);
        },
        flush() {
          return thenable("flush");
        },
      },
      undefined,
      { highWaterMark: 1 },
    );
    const writer = stream.writable.getWriter();
    const write = writer.write("a").then(() => events.push("write settled"));
    const close = writer.close().then(() => events.push("close settled"));
    await waitForMicrotaskCondition("the transform's then", () => events.length > 0);
    assert.deepEqual(events, ["transform a"]);
    resolvers.shift()();
    await write;
    await waitForMicrotaskCondition("the flush's then", () => events.includes("flush"));
    assert.deepEqual(events, ["transform a", "write settled", "flush"]);
    resolvers.shift()();
    await close;
    assert.deepEqual(events, ["transform a", "write settled", "flush", "close settled"]);
  });

  test("a read result whose value a then getter made an accessor hands the pipe no engine-internal value", async () => {
    const chunk = { marker: true };
    const received = [];
    const source = new ReadableStream({
      start(controller) {
        controller.enqueue(chunk);
        controller.close();
      },
    });
    const destination = new WritableStream({
      write(value) {
        received.push(value);
      },
    });
    Object.defineProperty(Object.prototype, "then", {
      configurable: true,
      get() {
        if (this !== null && typeof this === "object" && Object.hasOwn(this, "done") && Object.hasOwn(this, "value")) {
          if (Object.getOwnPropertyDescriptor(this, "value").value === chunk)
            Object.defineProperty(this, "value", { configurable: true, enumerable: true, get: () => chunk });
        }
        return undefined;
      },
    });
    try {
      await source.pipeTo(destination);
    } finally {
      delete Object.prototype.then;
    }
    assert.equal(received.length, 1);
    // The standard hands the pipe the chunk itself. A pipe that reads it from the result object may see the accessor
    // as no value, but never the engine's accessor cell.
    assert(received[0] === chunk || received[0] === undefined, "the sink received an engine-internal value");
  });

  test("a write parked under backpressure never reaches transform once the writable side errored", async () => {
    const transformed = [];
    const sizeError = new Error("size");
    let sizes = 0;
    const stream = new TransformStream(
      {
        transform(chunk, controller) {
          transformed.push(chunk);
          controller.enqueue(chunk);
        },
      },
      {
        size() {
          sizes++;
          if (sizes === 2) throw sizeError;
          return 1;
        },
      },
    );
    const writer = stream.writable.getWriter();
    const first = writer.write("a").then(() => "resolved", error => error);
    // Start settles and the first write parks: the readable side's high-water mark of 0 sets backpressure.
    for (let index = 0; index < 4; index++) await Promise.resolve();
    const second = writer.write("b").then(() => "resolved", error => error);
    assert.equal(await second, sizeError);
    const reader = stream.readable.getReader();
    let readSettled = false;
    reader.read().then(
      () => {
        readSettled = true;
      },
      () => {
        readSettled = true;
      },
    );
    for (let index = 0; index < 8; index++) await Promise.resolve();
    assert.deepEqual(transformed, []);
    assert.equal(readSettled, false);
    assert.equal(await first, sizeError);
  });

  test("TransformStream refuses a null transformer with a TypeError and takes an undefined one", () => {
    assert.throws(() => new TransformStream(null), TypeError);
    assert(new TransformStream(undefined).readable instanceof ReadableStream);
  });

  test("a rejected transformer start rejects the writer's closed promise before the reader's", async () => {
    const order = [];
    const stream = new TransformStream({
      start() {
        return Promise.reject(new Error("start"));
      },
    });
    const writerClosed = stream.writable.getWriter().closed.catch(() => order.push("writable"));
    const readerClosed = stream.readable.getReader().closed.catch(() => order.push("readable"));
    await Promise.all([writerClosed, readerClosed]);
    assert.deepEqual(order, ["writable", "readable"]);
  });

  test("once start has settled, a second abort resolves at once while the first waits for the sink", async () => {
    let resolveAbort = null;
    const stream = new WritableStream({
      abort() {
        return new Promise(resolve => {
          resolveAbort = resolve;
        });
      },
    });
    await Promise.resolve();
    const first = stream.abort("first");
    assert(resolveAbort !== null, "the sink's abort ran");
    const second = stream.abort("second");
    assert(second !== first, "the second abort returned the first abort's promise");
    let firstSettled = false;
    first.then(() => {
      firstSettled = true;
    });
    assert.equal(await second, undefined);
    assert.equal(firstSettled, false);
    resolveAbort();
    assert.equal(await first, undefined);
  });

  test("write runs the strategy's size callback before it refuses a write behind a queued close", async () => {
    const sized = [];
    const stream = new WritableStream(
      {},
      {
        size(chunk) {
          sized.push(chunk);
          return 1;
        },
      },
    );
    const writer = stream.getWriter();
    const closed = writer.close();
    await assertRejects(writer.write("late"), TypeError);
    assert.deepEqual(sized, ["late"]);
    await closed;
  });

  test("once the close reaches the sink, a write asks no size callback and abort calls no sink abort", async () => {
    let sized = 0;
    let aborted = 0;
    let resolveClose = null;
    const stream = new WritableStream(
      {
        close() {
          return new Promise(resolve => {
            resolveClose = resolve;
          });
        },
        abort() {
          aborted++;
        },
      },
      {
        size() {
          sized++;
          return 1;
        },
      },
    );
    const writer = stream.getWriter();
    writer.close().catch(() => {});
    await waitForMicrotaskCondition("the sink's close", () => resolveClose !== null);
    await assertRejects(writer.write("late"), TypeError);
    assert.equal(sized, 0);
    const abort = writer.abort("stop");
    resolveClose();
    assert.equal(await abort, undefined);
    assert.equal(aborted, 0);
  });

  test("CompressionStream and DecompressionStream reject a SharedArrayBuffer chunk and a view on one", async () => {
    const shared = new SharedArrayBuffer(8);
    for (const create of [() => new CompressionStream("gzip"), () => new DecompressionStream("gzip")]) {
      for (const chunk of [shared, new Uint8Array(shared), new DataView(shared)]) {
        const stream = create();
        // The codec sees the chunk only once a read waits.
        stream.readable.getReader().read().catch(() => {});
        const writer = stream.writable.getWriter();
        const outcome = await outcomeAfterMicrotasks(writer.write(chunk));
        assert(outcome.error instanceof TypeError, `a ${chunk.constructor.name} chunk was not refused`);
      }
    }
  });
});
