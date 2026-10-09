import { describe, expect, test } from "bun:test";

// Bun-compatible ReadableStream body readers:
// - reference/bun-v1.3.14/src/js/builtins/ReadableStream.ts
// - reference/bun-v1.3.14/test/js/web/fetch/utf8-bom.test.ts
// - reference/bun-v1.3.14/test/js/web/streams/readable-stream-blob-consumed.test.ts

const encoder = new TextEncoder();

function bytes(text) {
  return encoder.encode(text);
}

function defaultStream(chunks) {
  return new ReadableStream({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(chunk);
      controller.close();
    },
  });
}

function byteStream(chunks) {
  return new ReadableStream({
    type: "bytes",
    pull(controller) {
      const chunk = chunks.shift();
      if (chunk) {
        controller.enqueue(chunk);
      } else {
        controller.close();
      }
    },
  });
}

async function expectRejects(promise, constructor) {
  try {
    await promise;
  } catch (error) {
    expect(error).toBeInstanceOf(constructor);
    return error;
  }
  throw new Error("expected promise to reject");
}

describe("ReadableStream body reader prototype methods", () => {
  test("are exposed with Bun-compatible shape", () => {
    for (const name of ["blob", "bytes", "json", "text"]) {
      expect(typeof ReadableStream.prototype[name]).toBe("function");
      expect(ReadableStream.prototype[name].length).toBe(0);
    }
    expect(() => ReadableStream.prototype.text.call({})).toThrow(TypeError);
  });

  test("text() reads default and byte streams", async () => {
    expect(await defaultStream(["ab", bytes("cd")]).text()).toBe("abcd");
    expect(await byteStream([bytes("ab"), bytes("cd")]).text()).toBe("abcd");
  });

  test("bytes() returns Uint8Array with exact bytes", async () => {
    const view = new DataView(bytes("xabcdz").buffer, 1, 4);
    const output = await defaultStream([bytes("ab"), view]).bytes();
    expect(output).toBeInstanceOf(Uint8Array);
    expect(Array.from(output)).toEqual(Array.from(bytes("ababcd")));
  });

  test("json() parses stream text and rejects invalid JSON", async () => {
    expect(await defaultStream([bytes("{\"ok\":"), "true}"]).json()).toEqual({ ok: true });
    await expectRejects(defaultStream(["{"]).json(), SyntaxError);
  });

  test("blob() returns a Blob with stream bytes", async () => {
    const blob = await defaultStream([bytes("hello "), "world"]).blob();
    expect(blob).toBeInstanceOf(Blob);
    expect(blob.type).toBe("");
    expect(await blob.text()).toBe("hello world");
  });

  test("text(), json(), and blob().text() strip a leading UTF-8 BOM", async () => {
    expect(await defaultStream([new Uint8Array([0xef, 0xbb, 0xbf]), bytes("Hello")]).text()).toBe("Hello");
    expect(await defaultStream([new Uint8Array([0xef, 0xbb, 0xbf]), bytes("{\"ok\":true}")]).json()).toEqual({
      ok: true,
    });
    const blob = await defaultStream([new Uint8Array([0xef, 0xbb, 0xbf]), bytes("Hello")]).blob();
    expect(await blob.text()).toBe("Hello");
  });

  test("locked and already consumed streams reject promises", async () => {
    const locked = defaultStream([bytes("abc")]);
    const reader = locked.getReader();
    const lockedPromise = locked.text();
    expect(lockedPromise).toBeInstanceOf(Promise);
    await expectRejects(lockedPromise, TypeError);
    reader.releaseLock();

    const consumed = defaultStream([bytes("abc")]);
    expect(await consumed.text()).toBe("abc");
    await expectRejects(consumed.bytes(), TypeError);
  });

  test("body.blob() after Response consumes the body rejects instead of crashing", async () => {
    const response = new Response("Hello World");
    const body = response.body;
    await response.arrayBuffer();

    const promise = body.blob();
    expect(promise).toBeInstanceOf(Promise);
    await expectRejects(promise, TypeError);
  });

  test("underlying stream errors and invalid chunks reject", async () => {
    const reason = new TypeError("stream failed");
    const errored = new ReadableStream({
      start(controller) {
        controller.error(reason);
      },
    });
    expect(await errored.text().catch(error => error)).toBe(reason);

    await expectRejects(defaultStream([{}]).text(), TypeError);
  });
});
