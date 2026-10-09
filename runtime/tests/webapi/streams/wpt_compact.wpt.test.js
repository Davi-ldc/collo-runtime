import { describe, expect, it, test } from "bun:test";
import { flushAsyncEvents } from "harness";

// Compact Web Streams WPT subset for Collo's serverless WebAPI profile.
//
// Selected cases from:
// - streams/readable-streams/async-iterator.any.js
// - streams/piping/throwing-options.any.js
// - streams/readable-byte-streams/bad-buffers-and-views.any.js
// - streams/readable-byte-streams/enqueue-with-detached-buffer.any.js
// - streams/readable-byte-streams/respond-after-enqueue.any.js
// - streams/readable-byte-streams/read-min.any.js
// - streams/readable-byte-streams/tee.any.js
//
// Excluded here:
// - full testharness.js machinery;
// - realm/window/idlharness cases;
// - tests that require ArrayBuffer.prototype.transfer instead of standard
//   structuredClone transfer in this runtime profile.

function detachBuffer(buffer) {
  structuredClone(buffer, { transfer: [buffer] });
}

function expectIterResult(result, value, done) {
  expect(typeof result).toBe("object");
  expect(Object.getPrototypeOf(result)).toBe(Object.prototype);
  expect(Object.getOwnPropertyNames(result).sort()).toEqual(["done", "value"]);
  expect(result.value).toBe(value);
  expect(result.done).toBe(done);
}

function expectByteValues(actual, expected) {
  expect(actual instanceof Uint8Array || actual instanceof DataView).toBe(true);
  const actualBytes = actual instanceof DataView
    ? new Uint8Array(actual.buffer, actual.byteOffset, actual.byteLength)
    : actual;
  expect(Array.from(actualBytes)).toEqual(Array.from(expected));
}

async function expectRejects(promise, expected) {
  try {
    await promise;
  } catch (error) {
    if (typeof expected === "function") {
      expect(error instanceof expected).toBe(true);
    } else {
      expect(error).toBe(expected);
    }
    return error;
  }
  throw new Error("expected promise rejection");
}

function recordingReadableStream(extras = {}, strategy) {
  let controllerToCopyOver;
  const stream = new ReadableStream(
    {
      type: extras.type,
      start(controller) {
        controllerToCopyOver = controller;
        if (extras.start) return extras.start(controller);
      },
      pull(controller) {
        stream.events.push("pull");
        if (extras.pull) return extras.pull(controller);
      },
      cancel(reason) {
        stream.events.push("cancel", reason);
        if (extras.cancel) return extras.cancel(reason);
      },
    },
    strategy,
  );

  stream.controller = controllerToCopyOver;
  stream.events = [];
  return stream;
}

function extractViewInfo(view) {
  return {
    constructor: view.constructor,
    bufferByteLength: view.buffer.byteLength,
    byteOffset: view.byteOffset,
    byteLength: view.byteLength,
  };
}

class ThrowingPipeOptions {
  constructor(whatShouldThrow) {
    this.whatShouldThrow = whatShouldThrow;
    this.touched = [];
  }

  get preventClose() {
    this.maybeThrow("preventClose");
    return false;
  }

  get preventAbort() {
    this.maybeThrow("preventAbort");
    return false;
  }

  get preventCancel() {
    this.maybeThrow("preventCancel");
    return false;
  }

  get signal() {
    this.maybeThrow("signal");
    return undefined;
  }

  maybeThrow(name) {
    this.touched.push(name);
    if (this.whatShouldThrow === name) throw new Error(name);
  }
}

describe("WPT compact: ReadableStream async iterator", () => {
  test("instances have the expected prototype and method descriptors", () => {
    const stream = new ReadableStream();
    const iterator = stream.values();
    const prototype = Object.getPrototypeOf(iterator);
    const asyncIteratorPrototype = Object.getPrototypeOf(Object.getPrototypeOf(async function* () {}).prototype);

    expect(Object.getPrototypeOf(prototype)).toBe(asyncIteratorPrototype);
    expect(Object.getOwnPropertyNames(prototype).sort()).toEqual(["next", "return"]);

    for (const method of ["next", "return"]) {
      const descriptor = Object.getOwnPropertyDescriptor(prototype, method);
      expect(descriptor.enumerable).toBe(true);
      expect(descriptor.configurable).toBe(true);
      expect(descriptor.writable).toBe(true);
      expect(typeof iterator[method]).toBe("function");
      expect(iterator[method].name).toBe(method);
    }

    expect(iterator.next.length).toBe(0);
    expect(iterator.return.length).toBe(1);
    expect(typeof iterator.throw).toBe("undefined");
  });

  it("iterates push, pull, and undefined chunks", async () => {
    const push = new ReadableStream({
      start(controller) {
        controller.enqueue(1);
        controller.enqueue(2);
        controller.enqueue(undefined);
        controller.close();
      },
    });
    const pushChunks = [];
    for await (const chunk of push) pushChunks.push(chunk);
    expect(pushChunks).toEqual([1, 2, undefined]);

    let value = 1;
    const pull = new ReadableStream({
      pull(controller) {
        controller.enqueue(value);
        if (value === 3) controller.close();
        value += 1;
      },
    });
    const pullChunks = [];
    for await (const chunk of pull) pullChunks.push(chunk);
    expect(pullChunks).toEqual([1, 2, 3]);
  });

  it("manual iteration pulls only on demand with highWaterMark zero", async () => {
    let value = 1;
    const stream = recordingReadableStream(
      {
        pull(controller) {
          controller.enqueue(value);
          if (value === 3) controller.close();
          value += 1;
        },
      },
      new CountQueuingStrategy({ highWaterMark: 0 }),
    );

    const iterator = stream.values();
    expect(stream.events).toEqual([]);

    expectIterResult(await iterator.next(), 1, false);
    expect(stream.events).toEqual(["pull"]);
    expectIterResult(await iterator.next(), 2, false);
    expect(stream.events).toEqual(["pull", "pull"]);
    expectIterResult(await iterator.next(), 3, false);
    expect(stream.events).toEqual(["pull", "pull", "pull"]);
    expectIterResult(await iterator.next(), undefined, true);
    expect(stream.events).toEqual(["pull", "pull", "pull"]);
  });

  it("errored, closed, stalled, and partially-consumed streams follow WPT behavior", async () => {
    const streamError = "e";
    const errored = new ReadableStream({
      start(controller) {
        controller.error(streamError);
      },
    });
    await expectRejects((async () => {
      for await (const _ of errored) {
      }
    })(), streamError);

    const closed = new ReadableStream({
      start(controller) {
        controller.close();
      },
    });
    for await (const _ of closed) throw new Error("closed stream yielded a chunk");

    const stalled = new ReadableStream();
    let completed = false;
    const loop = (async () => {
      for await (const _ of stalled) {
      }
      completed = true;
    })();
    await Promise.race([loop, flushAsyncEvents()]);
    expect(completed).toBe(false);

    const partial = new ReadableStream({
      start(controller) {
        controller.enqueue(1);
        controller.enqueue(2);
        controller.enqueue(3);
        controller.close();
      },
    });
    const reader = partial.getReader();
    expectIterResult(await reader.read(), 1, false);
    reader.releaseLock();

    const chunks = [];
    for await (const chunk of partial) chunks.push(chunk);
    expect(chunks).toEqual([2, 3]);
  });

  for (const exitType of ["throw", "break", "return"]) {
    for (const preventCancel of [false, true]) {
      it(`cancel behavior when ${exitType} exits loop body; preventCancel = ${preventCancel}`, async () => {
        const stream = recordingReadableStream({
          start(controller) {
            controller.enqueue(0);
          },
        });

        async function loop() {
          for await (const _ of stream.values({ preventCancel })) {
            if (exitType === "throw") throw new Error("stop");
            if (exitType === "break") break;
            return;
          }
        }

        try {
          await loop();
        } catch (_) {
        }

        expect(stream.events).toEqual(preventCancel ? ["pull"] : ["pull", "cancel", undefined]);
      });
    }
  }

  for (const preventCancel of [false, true]) {
    it(`iterator.return observes preventCancel = ${preventCancel}`, async () => {
      const stream = recordingReadableStream({
        start(controller) {
          controller.enqueue(0);
        },
      });

      const iterator = stream.values({ preventCancel });
      expectIterResult(await iterator.return(), undefined, true);
      expect(stream.events).toEqual(preventCancel ? [] : ["cancel", undefined]);
    });
  }

  it("return(value) waits for cancel and serializes following next()", async () => {
    let resolveCancel;
    const stream = recordingReadableStream({
      cancel() {
        return new Promise((resolve) => {
          resolveCancel = resolve;
        });
      },
    });
    const iterator = stream.values();
    const resolutionOrder = [];

    const returnPromise = iterator.return("return value").then((result) => {
      resolutionOrder.push("return");
      return result;
    });
    const nextPromise = iterator.next().then((result) => {
      resolutionOrder.push("next");
      return result;
    });

    expect(stream.events).toEqual(["cancel", "return value"]);
    await flushAsyncEvents();
    expect(resolutionOrder).toEqual([]);

    resolveCancel();
    expectIterResult(await returnPromise, "return value", true);
    expectIterResult(await nextPromise, undefined, true);
    expect(resolutionOrder).toEqual(["return", "next"]);
  });

  it("return(value) unlocks synchronously and later returns keep their values", async () => {
    const stream = new ReadableStream();
    const iterator = stream.values();
    const firstReturn = iterator.return("first");
    stream.getReader().releaseLock();

    expectIterResult(await firstReturn, "first", true);
    expectIterResult(await iterator.return("second"), "second", true);
  });
});

describe("WPT compact: pipeTo/pipeThrough option access", () => {
  const order = ["preventAbort", "preventCancel", "preventClose", "signal"];

  for (let index = 0; index < order.length; index++) {
    const property = order[index];
    const touched = order.slice(0, index + 1);

    it(`pipeTo stops after getting ${property} throws`, async () => {
      const options = new ThrowingPipeOptions(property);
      await expect(new ReadableStream().pipeTo(new WritableStream(), options)).rejects.toThrow(property);
      expect(options.touched).toEqual(touched);
    });

    test(`pipeThrough stops after getting ${property} throws`, () => {
      const options = new ThrowingPipeOptions(property);
      expect(() => new ReadableStream().pipeThrough(new TransformStream(), options)).toThrow(property);
      expect(options.touched).toEqual(touched);
    });
  }
});

describe("WPT compact: Readable byte streams", () => {
  it("read() from a closed byte stream transfers the caller buffer", async () => {
    const stream = new ReadableStream({
      type: "bytes",
      start(controller) {
        controller.close();
      },
    });

    const reader = stream.getReader({ mode: "byob" });
    const view = new Uint8Array([1, 2, 3]);
    const { value, done } = await reader.read(view);

    expect(value instanceof Uint8Array).toBe(true);
    expect(value).not.toBe(view);
    expect(Array.from(value)).toEqual([]);
    expect(done).toBe(true);
    expect(value.buffer).not.toBe(view.buffer);
    expect(view.buffer.byteLength).toBe(0);
  });

  it("read() from a closed byte stream preserves the caller view constructor", async () => {
    const stream = new ReadableStream({
      type: "bytes",
      start(controller) {
        controller.close();
      },
    });

    const reader = stream.getReader({ mode: "byob" });
    const view = new DataView(new ArrayBuffer(4));
    const { value, done } = await reader.read(view);

    expect(done).toBe(true);
    expect(value.constructor).toBe(DataView);
    expect(value.byteLength).toBe(0);
    expect(view.buffer.byteLength).toBe(0);
  });

  it("read() from queued byte chunks transfers the caller buffer", async () => {
    const stream = new ReadableStream({
      type: "bytes",
      start(controller) {
        controller.enqueue(new Uint8Array([1, 2, 3]));
      },
    });

    const reader = stream.getReader({ mode: "byob" });
    const view = new Uint8Array([4, 5, 6]);
    const { value, done } = await reader.read(view);

    expect(value instanceof Uint8Array).toBe(true);
    expect(value).not.toBe(view);
    expect(Array.from(value)).toEqual([1, 2, 3]);
    expect(done).toBe(false);
    expect(value.buffer).not.toBe(view.buffer);
    expect(view.buffer.byteLength).toBe(0);
  });

  test("enqueue rejects detached and zero-length byte chunks", () => {
    new ReadableStream({
      type: "bytes",
      start(controller) {
        const view = new Uint8Array([1, 2, 3]);
        controller.enqueue(view);
        expect(() => controller.enqueue(view)).toThrow(TypeError);
      },
    });

    new ReadableStream({
      type: "bytes",
      start(controller) {
        expect(() => controller.enqueue(new Uint8Array([]))).toThrow(TypeError);
        expect(() => controller.enqueue(new Uint8Array(new ArrayBuffer(10), 0, 0))).toThrow(TypeError);
      },
    });
  });

  it("BYOB read rejects detached and zero-length views", async () => {
    const stream = new ReadableStream({
      type: "bytes",
      start(controller) {
        controller.enqueue(new Uint8Array([1, 2, 3]));
      },
    });
    const reader = stream.getReader({ mode: "byob" });

    const transferred = new Uint8Array([4, 5, 6]);
    await reader.read(transferred);
    await expectRejects(reader.read(transferred), TypeError);

    await expectRejects(reader.read(new Uint8Array()), TypeError);
    await expectRejects(reader.read(new Uint8Array(new ArrayBuffer(10), 0, 0)), TypeError);
  });

  it("enqueue after detaching byobRequest.view.buffer throws and preserves the stream error", async () => {
    const error = new Error("cannot proceed");
    const stream = new ReadableStream({
      type: "bytes",
      pull(controller) {
        detachBuffer(controller.byobRequest.view.buffer);
        expect(() => controller.enqueue(new Uint8Array([42]))).toThrow(TypeError);
        controller.error(error);
      },
    });

    const reader = stream.getReader({ mode: "byob" });
    await expectRejects(reader.read(new Uint8Array(1)), error);
  });

  it("respondWithNewView validates supplied views in the readable state", async () => {
    async function runValidation(validate, readView = new Uint8Array([4, 5, 6])) {
      let ran = false;
      const stream = new ReadableStream({
        type: "bytes",
        pull(controller) {
          ran = true;
          validate(controller);
          controller.error(new Error("validation complete"));
        },
      });
      const reader = stream.getReader({ mode: "byob" });
      const readPromise = reader.read(readView).then(result => result, () => undefined);
      await flushAsyncEvents();
      expect(ran).toBe(true);
      return await readPromise;
    }

    await runValidation((controller) => {
      const view = new Uint8Array([1, 2, 3]);
      detachBuffer(view.buffer);
      expect(() => controller.byobRequest.respondWithNewView(view)).toThrow(TypeError);
    });

    await runValidation((controller) => {
      expect(() => controller.byobRequest.respondWithNewView(new Uint8Array())).toThrow(TypeError);
    });

    await runValidation((controller) => {
      const view = new Uint8Array(controller.byobRequest.view.buffer, 0, 0);
      expect(() => controller.byobRequest.respondWithNewView(view)).toThrow(TypeError);
    });

    const subviewResult = await runValidation((controller) => {
      const view = controller.byobRequest.view.subarray(1, 2);
      controller.byobRequest.respondWithNewView(view);
    });
    expect(subviewResult.done).toBe(false);
    expect(Array.from(subviewResult.value)).toEqual([5]);

    await runValidation((controller) => {
      const view = new Uint8Array(new ArrayBuffer(10), 0, 3);
      expect(() => controller.byobRequest.respondWithNewView(view)).toThrow(RangeError);
    });

    await runValidation((controller) => {
      const view = new Uint8Array(controller.byobRequest.view.buffer, 0, 4);
      expect(() => controller.byobRequest.respondWithNewView(view)).toThrow(RangeError);
    }, new Uint8Array(new ArrayBuffer(10), 0, 3));
  });

  it("enqueue handles a chunk that aliases the pending BYOB view", async () => {
    const stream = new ReadableStream({
      type: "bytes",
      pull(controller) {
        const view = controller.byobRequest.view;
        view[0] = 7;
        view[1] = 8;
        controller.enqueue(view);
      },
    });

    const reader = stream.getReader({ mode: "byob" });
    const target = new Uint8Array(2);
    const { value, done } = await reader.read(target);

    expect(Array.from(value)).toEqual([7, 8]);
    expect(done).toBe(false);
    expect(target.buffer.byteLength).toBe(0);
  });

  it("byobRequest.respond() after enqueue() follows WPT behavior", async () => {
    const rs = new ReadableStream({
      type: "bytes",
      autoAllocateChunkSize: 10,
      pull(controller) {
        controller.enqueue(new Uint8Array([1, 2, 3]));
        controller.byobRequest.respond(10);
      },
    });

    const { value, done } = await rs.getReader().read();
    expect(done).toBe(false);
    expectByteValues(value, [1, 2, 3]);
  });

  it("cached byobRequest.respond() after enqueue() follows WPT behavior", async () => {
    const rs = new ReadableStream({
      type: "bytes",
      autoAllocateChunkSize: 10,
      pull(controller) {
        const request = controller.byobRequest;
        controller.enqueue(new Uint8Array([1, 2, 3]));
        request.respond(10);
      },
    });

    const { value, done } = await rs.getReader().read();
    expect(done).toBe(false);
    expectByteValues(value, [1, 2, 3]);
  });

  it("byobRequest.respond() after enqueue() with double read follows WPT behavior", async () => {
    const rs = new ReadableStream({
      type: "bytes",
      autoAllocateChunkSize: 10,
      pull(controller) {
        controller.enqueue(new Uint8Array([1, 2, 3]));
        controller.byobRequest.respond(2);
      },
    });

    const reader = rs.getReader();
    const [read1, read2] = await Promise.all([reader.read(), reader.read()]);
    expect(read1.done).toBe(false);
    expectByteValues(read1.value, [1, 2, 3]);
    expect(read2.done).toBe(false);
    expectByteValues(read2.value, [0, 0]);
  });

  it("read({ min }) validates min before pulling", async () => {
    const stream = new ReadableStream({
      type: "bytes",
      pull() {
        throw new Error("pull should not be called");
      },
    });
    const reader = stream.getReader({ mode: "byob" });

    await expectRejects(reader.read(new Uint8Array(1), { min: 0 }), TypeError);
    await expectRejects(reader.read(new Uint8Array(1), { min: -1 }), TypeError);
    await expectRejects(reader.read(new Uint8Array(1), { min: 2 }), RangeError);
    await expectRejects(reader.read(new Uint16Array(1), { min: 2 }), RangeError);
    await expectRejects(reader.read(new DataView(new ArrayBuffer(1)), { min: 2 }), RangeError);
  });

  it("read({ min }), then read() combines partial BYOB responses", async () => {
    let pullCount = 0;
    const byobRequests = [];
    const rs = new ReadableStream({
      type: "bytes",
      pull(controller) {
        const byobRequest = controller.byobRequest;
        const view = byobRequest.view;
        byobRequests[pullCount] = {
          nonNull: byobRequest !== null,
          viewNonNull: view !== null,
          viewInfo: extractViewInfo(view),
        };
        if (pullCount === 0) {
          view[0] = 0x01;
          view[1] = 0x02;
          byobRequest.respond(2);
        } else if (pullCount === 1) {
          view[0] = 0x03;
          byobRequest.respond(1);
        } else if (pullCount === 2) {
          view[0] = 0x04;
          byobRequest.respond(1);
        }
        pullCount += 1;
      },
    });
    const reader = rs.getReader({ mode: "byob" });
    const read1 = reader.read(new Uint8Array(3), { min: 3 });
    const read2 = reader.read(new Uint8Array(1));

    const result1 = await read1;
    expect(result1.done).toBe(false);
    expectByteValues(result1.value, [0x01, 0x02, 0x03]);

    const result2 = await read2;
    expect(result2.done).toBe(false);
    expectByteValues(result2.value, [0x04]);

    expect(pullCount).toBe(3);
    expect(byobRequests[0].nonNull).toBe(true);
    expect(byobRequests[0].viewNonNull).toBe(true);
    expect(byobRequests[0].viewInfo).toEqual({
      constructor: Uint8Array,
      bufferByteLength: 3,
      byteOffset: 0,
      byteLength: 3,
    });
    expect(byobRequests[1].viewInfo).toEqual({
      constructor: Uint8Array,
      bufferByteLength: 3,
      byteOffset: 2,
      byteLength: 1,
    });
    expect(byobRequests[2].viewInfo).toEqual({
      constructor: Uint8Array,
      bufferByteLength: 1,
      byteOffset: 0,
      byteLength: 1,
    });
  });

  it("read({ min }) with DataView preserves the view constructor", async () => {
    let pullCount = 0;
    const byobRequests = [];
    const rs = new ReadableStream({
      type: "bytes",
      pull(controller) {
        const byobRequest = controller.byobRequest;
        const view = byobRequest.view;
        byobRequests[pullCount] = {
          nonNull: byobRequest !== null,
          viewNonNull: view !== null,
          viewInfo: extractViewInfo(view),
        };
        if (pullCount === 0) {
          view[0] = 0x01;
          view[1] = 0x02;
          byobRequest.respond(2);
        } else if (pullCount === 1) {
          view[0] = 0x03;
          byobRequest.respond(1);
        }
        pullCount += 1;
      },
    });

    const result = await rs.getReader({ mode: "byob" }).read(new DataView(new ArrayBuffer(3)), { min: 3 });
    expect(result.done).toBe(false);
    expect(result.value.constructor).toBe(DataView);
    expect(result.value.byteOffset).toBe(0);
    expect(result.value.byteLength).toBe(3);
    expect(result.value.buffer.byteLength).toBe(3);
    expectByteValues(result.value, [0x01, 0x02, 0x03]);
    expect(pullCount).toBe(2);
    expect(byobRequests[0].viewInfo).toEqual({
      constructor: Uint8Array,
      bufferByteLength: 3,
      byteOffset: 0,
      byteLength: 3,
    });
    expect(byobRequests[1].viewInfo).toEqual({
      constructor: Uint8Array,
      bufferByteLength: 3,
      byteOffset: 2,
      byteLength: 1,
    });
  });

  it("read({ min }) combines partial respondWithNewView responses", async () => {
    let pullCount = 0;
    const rs = new ReadableStream({
      type: "bytes",
      pull(controller) {
        const byobRequest = controller.byobRequest;
        const view = byobRequest.view;
        if (pullCount === 0) {
          view[0] = 0x01;
          byobRequest.respondWithNewView(view.subarray(0, 1));
        } else if (pullCount === 1) {
          view[0] = 0x02;
          byobRequest.respond(1);
        }
        pullCount += 1;
      },
    });

    const result = await rs.getReader({ mode: "byob" }).read(new Uint8Array(2), { min: 2 });
    expect(result.done).toBe(false);
    expectByteValues(result.value, [0x01, 0x02]);
    expect(pullCount).toBe(2);
  });

  it("enqueue(), then read({ min }) only pulls missing bytes", async () => {
    let pullCount = 0;
    const byobRequests = [];
    const rs = new ReadableStream({
      type: "bytes",
      start(controller) {
        controller.enqueue(new Uint8Array([0x01]));
      },
      pull(controller) {
        const byobRequest = controller.byobRequest;
        const view = byobRequest.view;
        byobRequests[pullCount] = {
          nonNull: byobRequest !== null,
          viewNonNull: view !== null,
          viewInfo: extractViewInfo(view),
        };
        if (pullCount === 0) {
          view[0] = 0x02;
          view[1] = 0x03;
          byobRequest.respond(2);
        }
        pullCount += 1;
      },
    });

    const result = await rs.getReader({ mode: "byob" }).read(new Uint8Array(3), { min: 3 });
    expect(result.done).toBe(false);
    expectByteValues(result.value, [0x01, 0x02, 0x03]);
    expect(pullCount).toBe(1);
    expect(byobRequests[0].viewInfo).toEqual({
      constructor: Uint8Array,
      bufferByteLength: 3,
      byteOffset: 1,
      byteLength: 2,
    });
  });

  it("byte stream tee lets one branch finish without closing the other", async () => {
    const rs = new ReadableStream({
      type: "bytes",
      start(controller) {
        controller.enqueue(new Uint8Array([0x01]));
        controller.enqueue(new Uint8Array([0x02]));
        controller.close();
      },
    });

    const [branch1, branch2] = rs.tee();
    const reader1 = branch1.getReader({ mode: "byob" });
    const reader2 = branch2.getReader({ mode: "byob" });

    let result = await reader1.read(new Uint8Array(1));
    expect(result.done).toBe(false);
    expectByteValues(result.value, [0x01]);

    result = await reader1.read(new Uint8Array(1));
    expect(result.done).toBe(false);
    expectByteValues(result.value, [0x02]);

    result = await reader1.read(new Uint8Array(1));
    expect(result.done).toBe(true);
    expectByteValues(result.value, []);

    result = await reader2.read(new Uint8Array(1));
    expect(result.done).toBe(false);
    expectByteValues(result.value, [0x01]);

    await reader1.closed;
  });

  it("byte stream tee clones chunks for each default-reader branch", async () => {
    let pullCount = 0;
    const enqueuedChunk = new Uint8Array([0x01]);
    const rs = new ReadableStream({
      type: "bytes",
      pull(controller) {
        pullCount += 1;
        if (pullCount === 1) controller.enqueue(enqueuedChunk);
      },
    });

    const [branch1, branch2] = rs.tee();
    const [result1, result2] = await Promise.all([
      branch1.getReader().read(),
      branch2.getReader().read(),
    ]);

    expect(result1.done).toBe(false);
    expect(result2.done).toBe(false);
    expectByteValues(result1.value, [0x01]);
    expectByteValues(result2.value, [0x01]);
    expect(result1.value.buffer).not.toBe(result2.value.buffer);
    expect(enqueuedChunk.buffer).not.toBe(result1.value.buffer);
    expect(enqueuedChunk.buffer).not.toBe(result2.value.buffer);
  });

  it("byte stream tee clones BYOB branch chunks to the default-reader branch", async () => {
    let pullCount = 0;
    const rs = new ReadableStream({
      type: "bytes",
      pull(controller) {
        pullCount += 1;
        if (pullCount === 1) {
          controller.byobRequest.view[0] = 0x01;
          controller.byobRequest.respond(1);
        }
      },
    });

    const [branch1, branch2] = rs.tee();
    const reader1 = branch1.getReader({ mode: "byob" });
    const reader2 = branch2.getReader();
    const buffer = new Uint8Array([42, 42, 42]).buffer;

    const byob = await reader1.read(new Uint8Array(buffer, 0, 1));
    expect(byob.done).toBe(false);
    expectByteValues(byob.value, [0x01]);

    const copied = await reader2.read();
    expect(copied.done).toBe(false);
    expectByteValues(copied.value, [0x01]);
  });
});
