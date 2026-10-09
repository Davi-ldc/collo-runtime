import { describe, expect, it } from "bun:test";
import { readableStreamToText } from "harness";

// WebAPI-only subset from:
// reference/bun-v1.3.14/test/js/web/streams/streams.test.js
//
// Excluded from this compat fixture:
// - Buffer-based assertions.
// - Bun.file(), ArrayBufferSink, FIFO, subprocess, and node:fs/node:path cases.
// - Bun direct streams and readMany(), which are Bun extensions.

describe("WritableStream", () => {
  it("pipeTo", async () => {
    const rs = new ReadableStream({
      start(controller) {
        controller.enqueue("hello world");
        controller.close();
      },
    });

    let received;
    const ws = new WritableStream({
      write(chunk, controller) {
        received = chunk;
      },
    });
    await rs.pipeTo(ws);
    expect(received).toBe("hello world");
  });
});

describe("ReadableStream.prototype.tee", () => {
  it("class", () => {
    const [a, b] = new ReadableStream().tee();
    expect(a instanceof ReadableStream).toBe(true);
    expect(b instanceof ReadableStream).toBe(true);
  });

  describe("default stream", () => {
    it("works", async () => {
      var [a, b] = new ReadableStream({
        start(controller) {
          controller.enqueue("a");
          controller.enqueue("b");
          controller.enqueue("c");
          controller.close();
        },
      }).tee();

      expect(await readableStreamToText(a)).toBe("abc");
      expect(await readableStreamToText(b)).toBe("abc");
    });
  });
});

it("ReadableStream.prototype[Symbol.asyncIterator]", async () => {
  const stream = new ReadableStream({
    start(controller) {
      controller.enqueue("hello");
      controller.enqueue("world");
      controller.close();
    },
    cancel(reason) {},
  });

  const chunks = [];
  for await (const chunk of stream) {
    chunks.push(chunk);
  }

  expect(chunks.join("")).toBe("helloworld");
});

it("ReadableStream.prototype[Symbol.asyncIterator] pull", async () => {
  const stream = new ReadableStream({
    pull(controller) {
      controller.enqueue("hello");
      controller.enqueue("world");
      controller.close();
    },
    cancel(reason) {},
  });

  const chunks = [];
  for await (const chunk of stream) {
    chunks.push(chunk);
  }
  expect(chunks.join("")).toBe("helloworld");
});

it("ReadableStream.prototype.values() cancel", async () => {
  var cancelled = false;
  const stream = new ReadableStream({
    pull(controller) {
      controller.enqueue("hello");
      controller.enqueue("world");
    },
    cancel(reason) {
      cancelled = true;
    },
  });

  for await (const chunk of stream.values({ preventCancel: false })) {
    break;
  }
  expect(cancelled).toBe(true);
});

it("ReadableStream.prototype.values() preventCancel", async () => {
  var cancelled = false;
  const stream = new ReadableStream({
    pull(controller) {
      controller.enqueue("hello");
      controller.enqueue("world");
    },
    cancel(reason) {
      cancelled = true;
    },
  });

  for await (const chunk of stream.values({ preventCancel: true })) {
    break;
  }
  expect(cancelled).toBe(false);
});

it("ReadableStream.prototype.values", async () => {
  const stream = new ReadableStream({
    start(controller) {
      controller.enqueue("hello");
      controller.enqueue("world");
      controller.close();
    },
  });

  const chunks = [];
  for await (const chunk of stream.values()) {
    chunks.push(chunk);
  }
  expect(chunks.join("")).toBe("helloworld");
});

it("new Response(stream).body", async () => {
  var stream = new ReadableStream({
    pull(controller) {
      controller.enqueue("hello");
      controller.enqueue("world");
      controller.close();
    },
    cancel() {},
  });
  var response = new Response(stream);
  expect(response.body).toBe(stream);
  expect(await response.text()).toBe("helloworld");
});

it("ReadableStream errors the stream on pull rejection", async () => {
  let stream = new ReadableStream({
    pull(controller) {
      return Promise.reject("pull rejected");
    },
  });

  let reader = stream.getReader();
  let closed = reader.closed.catch(err => `closed: ${err}`);
  let read = reader.read().catch(err => `read: ${err}`);
  expect(await Promise.race([closed, read])).toBe("closed: pull rejected");
  expect(await read).toBe("read: pull rejected");
});

it("Blob.stream(undefined) does not crash", () => {
  var blob = new Blob(["abdefgh"]);
  var stream = blob.stream(undefined);
  expect(stream instanceof ReadableStream).toBeTrue();
  stream = blob.stream(null);
  expect(stream instanceof ReadableStream).toBeTrue();
});

it("Blob.stream() -> new Response(stream).text()", async () => {
  var blob = new Blob(["abdefgh"]);
  var stream = blob.stream();
  const text = await new Response(stream).text();
  expect(text).toBe("abdefgh");
});
