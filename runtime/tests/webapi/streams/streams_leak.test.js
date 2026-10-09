// Leak coverage derived from Bun v1.3.14:
// - reference/bun-v1.3.14/test/js/web/streams/transform-stream-leak.test.ts
// - reference/bun-v1.3.14/test/js/web/streams/pipeTo-signal-leak.test.ts
// - reference/bun-v1.3.14/test/js/web/streams/streams-leak.test.ts

describeLeaks("Streams retention and leak coverage", () => {
  leakTest(
    "Bun port intent: dropped WritableStream wrappers are collectable",
    () => [
      weakRecord("WritableStream", makeWeakRefs(1000, () => new WritableStream()), 50),
    ],
    expectLeakRecordsCollected,
  );

  leakTest(
    "Bun port intent: dropped TransformStream wrappers are collectable",
    () => [
      weakRecord("TransformStream", makeWeakRefs(1000, () => new TransformStream()), 50),
    ],
    expectLeakRecordsCollected,
  );

  leakTest(
    "Bun port intent: live WritableStream keeps internal state through GC",
    () => {
      const received = [];
      const writable = new WritableStream({
        write(chunk) {
          received.push(chunk);
        },
      });
      return { writable, received };
    },
    async ({ writable, received }) => {
      assert.equal(writable.locked, false);
      const writer = writable.getWriter();
      assert.equal(writable.locked, true);
      await writer.write("a");
      await writer.write("b");
      await writer.close();
      assert.deepEqual(received, ["a", "b"]);
      writer.releaseLock();
      assert.equal(writable.locked, false);
    },
  );

  leakTest(
    "Bun port intent: pending pipeTo does not retain dropped AbortSignal",
    () => {
      const signalRefs = [];

      for (let index = 0; index < 64; index++) {
        let controller = new AbortController();
        let readable = new ReadableStream({
          pull() {
            return new Promise(() => {});
          },
        });
        let writable = new WritableStream({});

        readable.pipeTo(writable, { signal: controller.signal }).catch(() => {});
        signalRefs.push(new WeakRef(controller.signal));
        controller = null;
        readable = null;
        writable = null;
      }

      return [
        weakRecord("pipeTo AbortSignal", signalRefs, 8),
      ];
    },
    expectLeakRecordsCollected,
  );

  leakTest(
    "Collo contract: pending pipeTo with AbortSignal does not retain source or sink",
    () => {
      const signalRefs = [];
      const readableRefs = [];
      const writableRefs = [];

      for (let index = 0; index < 64; index++) {
        let controller = new AbortController();
        let readable = new ReadableStream({
          pull() {
            return new Promise(() => {});
          },
        });
        let writable = new WritableStream({});

        readable.pipeTo(writable, { signal: controller.signal }).catch(() => {});
        signalRefs.push(new WeakRef(controller.signal));
        readableRefs.push(new WeakRef(readable));
        writableRefs.push(new WeakRef(writable));
        controller = null;
        readable = null;
        writable = null;
      }

      return [
        weakRecord("pending pipeTo signal", signalRefs, 8),
        weakRecord("pending pipeTo source", readableRefs, 8),
        weakRecord("pending pipeTo sink", writableRefs, 8),
      ];
    },
    expectLeakRecordsCollected,
  );

  leakTest(
    "Bun port intent: aborted pipeTo releases AbortSignal",
    async () => {
      const signalRefs = [];

      for (let index = 0; index < 64; index++) {
        let controller = new AbortController();
        let readable = new ReadableStream({
          pull() {
            return new Promise(() => {});
          },
        });
        let writable = new WritableStream({});
        const piping = readable.pipeTo(writable, { signal: controller.signal }).catch(error => error);

        controller.abort("stop");
        assert.equal(await piping, "stop");
        signalRefs.push(new WeakRef(controller.signal));
        controller = null;
        readable = null;
        writable = null;
      }

      return [
        weakRecord("aborted pipeTo AbortSignal", signalRefs, 8),
      ];
    },
    expectLeakRecordsCollected,
  );

  leakTest(
    "Collo contract: aborted pipeTo releases source and sink",
    async () => {
      const readableRefs = [];
      const writableRefs = [];

      for (let index = 0; index < 64; index++) {
        let controller = new AbortController();
        let readable = new ReadableStream({
          pull() {
            return new Promise(() => {});
          },
        });
        let writable = new WritableStream({});
        const piping = readable.pipeTo(writable, { signal: controller.signal }).catch(error => error);

        controller.abort("stop");
        assert.equal(await piping, "stop");
        readableRefs.push(new WeakRef(readable));
        writableRefs.push(new WeakRef(writable));
        controller = null;
        readable = null;
        writable = null;
      }

      return [
        weakRecord("aborted pipeTo source", readableRefs, 8),
        weakRecord("aborted pipeTo sink", writableRefs, 8),
      ];
    },
    expectLeakRecordsCollected,
  );

  leakTest(
    "Collo contract: async iterator return does not retain settled return values",
    async () => {
      const valueRefs = [];

      for (let index = 0; index < 64; index++) {
        let releaseCancel;
        let stream = new ReadableStream({
          cancel() {
            return new Promise(resolve => {
              releaseCancel = resolve;
            });
          },
        });
        let iterator = stream[Symbol.asyncIterator]();
        let value = { index, bytes: new Uint8Array(64 * 1024) };
        let returned = iterator.return(value);
        valueRefs.push(new WeakRef(value));

        value = null;
        releaseCancel();
        await returned;
        returned = null;
        iterator = null;
        stream = null;
      }

      return [
        weakRecord("async iterator return values", valueRefs, 8),
      ];
    },
    expectLeakRecordsCollected,
  );

  leakTest(
    "closed compression streams are collectable after body drain",
    async () => {
      async function createClosedCompressionRefs() {
        let stream = new CompressionStream("gzip");
        const refs = [
          new WeakRef(stream),
          new WeakRef(stream.readable),
          new WeakRef(stream.writable),
        ];
        const writer = stream.writable.getWriter();
        // Writes only complete once the readable side drains (zero
        // highWaterMark), so queue them before reading.
        const pendingWrites = Promise.all([
          writer.write(new TextEncoder().encode("hello")),
          writer.close(),
        ]);
        await collectBytes(stream.readable);
        await pendingWrites;
        writer.releaseLock();
        stream = null;
        return refs;
      }

      const refs = [];
      for (let index = 0; index < 24; index++) {
        refs.push(...await createClosedCompressionRefs());
      }
      return [
        weakRecord("closed CompressionStream", refs, 8),
      ];
    },
    expectLeakRecordsCollected,
  );

  leakTest(
    "errored decompression streams are collectable after readable and writable rejection",
    async () => {
      async function createErroredDecompressionRefs() {
        let stream = new DecompressionStream("gzip");
        const refs = [
          new WeakRef(stream),
          new WeakRef(stream.readable),
          new WeakRef(stream.writable),
        ];
        const reader = stream.readable.getReader();
        const writer = stream.writable.getWriter();
        const read = reader.read().then(
          () => "resolved",
          error => error,
        );
        const write = writer.write(new Uint8Array([1, 2, 3, 4])).then(
          () => "resolved",
          error => error,
        );
        assert((await read) instanceof Error);
        assert((await write) instanceof Error);
        reader.releaseLock();
        writer.releaseLock();
        stream = null;
        return refs;
      }

      const refs = [];
      for (let index = 0; index < 24; index++) {
        refs.push(...await createErroredDecompressionRefs());
      }
      return [
        weakRecord("errored DecompressionStream", refs, 8),
      ];
    },
    expectLeakRecordsCollected,
  );
});
