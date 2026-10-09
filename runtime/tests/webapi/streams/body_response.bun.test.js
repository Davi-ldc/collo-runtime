import { describe, expect, it } from "bun:test";
import {
  concatUint8,
  readableStreamToArray,
  readableStreamToArrayBuffer,
  readableStreamToBytes,
  readableStreamToText,
} from "harness";

// WebAPI-only subset from:
// reference/bun-v1.3.14/test/js/web/streams/streams.test.js
//
// The original Bun fixture uses Buffer as byte test data. Collo's WebAPI
// compat profile does not expose Buffer, so these cases use TextEncoder and
// Uint8Array while preserving the stream/body assertions.

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function bytes(text) {
  return encoder.encode(text);
}

function bytesStream(text, type = "bytes") {
  const queue = [bytes(text)];
  const source = {
    pull(controller) {
      const chunk = queue.shift();
      if (chunk) {
        controller.enqueue(chunk);
      } else {
        controller.close();
      }
    },
    cancel() {},
  };
  if (type === "bytes") source.type = "bytes";
  return new ReadableStream(source);
}

async function tick() {
  await Promise.resolve();
}

describe("TransformStream", () => {
  it("encodes chunks", async () => {
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
    const writer = stream.writable.getWriter();
    writer.write("hello");
    writer.write("world");
    writer.close();

    const chunks = await readableStreamToArray(stream.readable);
    expect(decoder.decode(concatUint8(chunks))).toEqual("helloworld");
  });

  it("readable side can be canceled after draining", async () => {
    const stream = new TransformStream({
      transform(chunk, controller) {
        controller.enqueue(chunk);
      },
    });
    const writer = stream.writable.getWriter();
    writer.write("hello");
    writer.close();

    const reader = stream.readable.getReader();
    expect(await reader.read()).toEqual({ value: "hello", done: false });
    expect(await reader.read()).toEqual({ value: undefined, done: true });
    await reader.cancel();
  });
});

describe("WritableStream", () => {
  it("works", async () => {
    const chunks = [];
    const writable = new WritableStream({
      write(chunk) {
        chunks.push(chunk);
      },
      close() {},
      abort() {},
    });

    const writer = writable.getWriter();
    writer.write(new Uint8Array([1, 2, 3]));
    writer.write(new Uint8Array([4, 5, 6]));
    await writer.close();

    expect(Array.from(concatUint8(chunks))).toEqual([1, 2, 3, 4, 5, 6]);
  });
});

describe("ReadableStream byte/default body helpers", () => {
  it("readableStreamToArray", async () => {
    const chunks = await readableStreamToArray(bytesStream("abdefgh"));
    expect(Array.from(chunks[0])).toEqual(Array.from(bytes("abdefgh")));
  });

  it("readableStreamToArrayBuffer (bytes)", async () => {
    const buffer = await readableStreamToArrayBuffer(bytesStream("abdefgh"));
    expect(decoder.decode(new Uint8Array(buffer))).toBe("abdefgh");
  });

  it("readableStreamToArrayBuffer (default)", async () => {
    const buffer = await readableStreamToArrayBuffer(bytesStream("abdefgh", "default"));
    expect(decoder.decode(new Uint8Array(buffer))).toBe("abdefgh");
  });

  it("readableStreamToBytes (bytes)", async () => {
    const output = await readableStreamToBytes(bytesStream("abdefgh"));
    expect(decoder.decode(output)).toBe("abdefgh");
  });

  it("readableStreamToText (default)", async () => {
    expect(await readableStreamToText(bytesStream("abdefgh", "default"))).toBe("abdefgh");
  });

  it("Blob.stream() supports BYOB reads", async () => {
    const reader = new Blob([bytes("abdefgh")]).stream().getReader({ mode: "byob" });
    const firstTarget = new Uint8Array(16);
    const first = await reader.read(firstTarget);
    expect(first.done).toBe(false);
    expect(decoder.decode(first.value)).toBe("abdefgh");
    expect(firstTarget.byteLength).toBe(0);
    const tailTarget = new Uint8Array(16);
    const tail = await reader.read(tailTarget);
    expect(tail.done).toBe(true);
    expect(tailTarget.byteLength).toBe(0);
    reader.releaseLock();
  });

  it("Blob.stream() drains queued bytes into pending BYOB reads", async () => {
    const reader = new Blob([bytes("abdefgh")]).stream().getReader({ mode: "byob" });
    const firstTarget = new Uint8Array(2);
    const secondTarget = new Uint8Array(3);
    const first = reader.read(firstTarget);
    const second = reader.read(secondTarget);

    let result = await first;
    expect(result.done).toBe(false);
    expect(decoder.decode(result.value)).toBe("ab");
    expect(firstTarget.byteLength).toBe(0);

    result = await second;
    expect(result.done).toBe(false);
    expect(decoder.decode(result.value)).toBe("def");
    expect(secondTarget.byteLength).toBe(0);

    const thirdTarget = new Uint8Array(8);
    result = await reader.read(thirdTarget);
    expect(result.done).toBe(false);
    expect(decoder.decode(result.value)).toBe("gh");
    expect(thirdTarget.byteLength).toBe(0);

    const tailTarget = new Uint8Array(8);
    result = await reader.read(tailTarget);
    expect(result.done).toBe(true);
    expect(tailTarget.byteLength).toBe(0);
    reader.releaseLock();
  });

  it("Blob.stream().tee() keeps byte-stream BYOB behavior", async () => {
    const [left, right] = new Blob([bytes("abdefgh")]).stream().tee();
    const leftReader = left.getReader({ mode: "byob" });
    const rightReader = right.getReader({ mode: "byob" });

    let result = await leftReader.read(new Uint8Array(3));
    expect(result.done).toBe(false);
    expect(decoder.decode(result.value)).toBe("abd");

    result = await rightReader.read(new Uint8Array(7));
    expect(result.done).toBe(false);
    expect(decoder.decode(result.value)).toBe("abdefgh");

    result = await leftReader.read(new Uint8Array(8));
    expect(result.done).toBe(false);
    expect(decoder.decode(result.value)).toBe("efgh");

    leftReader.releaseLock();
    rightReader.releaseLock();
  });

  it("Response static body supports BYOB reads", async () => {
    const reader = new Response(bytes("abdefgh")).body.getReader({ mode: "byob" });
    const firstTarget = new Uint8Array(16);
    const first = await reader.read(firstTarget);
    expect(first.done).toBe(false);
    expect(decoder.decode(first.value)).toBe("abdefgh");
    expect(firstTarget.byteLength).toBe(0);
    const tailTarget = new Uint8Array(16);
    const tail = await reader.read(tailTarget);
    expect(tail.done).toBe(true);
    expect(tailTarget.byteLength).toBe(0);
    reader.releaseLock();
  });

  it("Request static body supports BYOB reads", async () => {
    const request = new Request("https://example.test/", { method: "POST", body: bytes("abdefgh") });
    const reader = request.body.getReader({ mode: "byob" });
    const firstTarget = new Uint8Array(4);
    const first = await reader.read(firstTarget);
    expect(first.done).toBe(false);
    expect(decoder.decode(first.value)).toBe("abde");
    expect(firstTarget.byteLength).toBe(0);
    const secondTarget = new Uint8Array(8);
    const second = await reader.read(secondTarget);
    expect(second.done).toBe(false);
    expect(decoder.decode(second.value)).toBe("fgh");
    expect(secondTarget.byteLength).toBe(0);
    const tailTarget = new Uint8Array(8);
    const tail = await reader.read(tailTarget);
    expect(tail.done).toBe(true);
    expect(tailTarget.byteLength).toBe(0);
    reader.releaseLock();
  });
});

describe("Response stream body consumers", () => {
  it("new Response(stream).arrayBuffer() (bytes)", async () => {
    const buffer = await new Response(bytesStream("abdefgh")).arrayBuffer();
    expect(decoder.decode(buffer)).toBe("abdefgh");
  });

  it("new Response(stream).arrayBuffer() (default)", async () => {
    const buffer = await new Response(bytesStream("abdefgh", "default")).arrayBuffer();
    expect(decoder.decode(buffer)).toBe("abdefgh");
  });

  it("new Response(stream).bytes() (bytes)", async () => {
    const output = await new Response(bytesStream("abdefgh")).bytes();
    expect(decoder.decode(output)).toBe("abdefgh");
  });

  it("new Response(stream).bytes() (default)", async () => {
    const output = await new Response(bytesStream("abdefgh", "default")).bytes();
    expect(decoder.decode(output)).toBe("abdefgh");
  });

  it("new Response(stream).text() (bytes)", async () => {
    expect(await new Response(bytesStream("abdefgh")).text()).toBe("abdefgh");
  });

  it("new Response(stream).text() (default)", async () => {
    expect(await new Response(bytesStream("abdefgh", "default")).text()).toBe("abdefgh");
  });

  it("new Response(stream).json() (bytes)", async () => {
    const json = await new Response(bytesStream(JSON.stringify({ hello: true }))).json();
    expect(json.hello).toBe(true);
  });

  it("new Response(stream).json() (default)", async () => {
    const json = await new Response(bytesStream(JSON.stringify({ hello: true }), "default")).json();
    expect(json.hello).toBe(true);
  });

  it("new Response(stream).blob() (bytes)", async () => {
    const response = new Response(bytesStream(JSON.stringify({ hello: true })));
    const blob = await response.blob();
    expect(await blob.text()).toBe('{"hello":true}');
  });

  it("new Response(stream).blob() (default)", async () => {
    const response = new Response(bytesStream(JSON.stringify({ hello: true }), "default"));
    const blob = await response.blob();
    expect(await blob.text()).toBe('{"hello":true}');
  });

  it("new Response(stream).arrayBuffer() preserves ArrayBufferView offsets", async () => {
    const backing = bytes("xxabdefghyy").buffer;
    const view = new Uint8Array(backing, 2, 7);
    const buffer = await new Response(
      new ReadableStream({
        start(controller) {
          controller.enqueue(view);
          controller.close();
        },
      }),
    ).arrayBuffer();
    expect(decoder.decode(new Uint8Array(buffer))).toBe("abdefgh");
  });

  it("new Response(stream).bytes() preserves DataView offsets", async () => {
    const backing = bytes("xxabdefghyy").buffer;
    const view = new DataView(backing, 2, 7);
    const output = await new Response(
      new ReadableStream({
        start(controller) {
          controller.enqueue(view);
          controller.close();
        },
      }),
    ).bytes();
    expect(decoder.decode(output)).toBe("abdefgh");
  });

  it("new Response(stream).arrayBuffer() rejects bodies beyond the serverless limit", async () => {
    const chunk = new Uint8Array(4 * 1024 * 1024 + 1);
    const body = new ReadableStream({
      start(controller) {
        controller.enqueue(chunk);
        controller.close();
      },
    });

    await expect(new Response(body).arrayBuffer()).rejects.toThrow("serverless body limit");
  });

  it("new Response(Blob.stream()).arrayBuffer() rejects bodies beyond the serverless limit", async () => {
    const blob = new Blob([new Uint8Array(4 * 1024 * 1024 + 1)]);
    await expect(new Response(blob.stream()).arrayBuffer()).rejects.toThrow("serverless body limit");
  });
});

describe("Response stream formData consumers", () => {
  const fixtures = {
    withTextFile: [
      [
        "--WebKitFormBoundary7MA4YWxkTrZu0gW\r\n",
        'Content-Disposition: form-data; name="file"; filename="test.txt"\r\n',
        "Content-Type: text/plain\r\n",
        "\r\n",
        "hello world",
        "\r\n",
        "--WebKitFormBoundary7MA4YWxkTrZu0gW--\r\n",
        "\r\n",
      ],
      (() => {
        const fd = new FormData();
        fd.append("file", new Blob(["hello world"]), "test.txt");
        return fd;
      })(),
    ],
    withTextFileAndField: [
      [
        "--WebKitFormBoundary7MA4YWxkTrZu0gW\r\n",
        'Content-Disposition: form-data; name="field"\r\n',
        "\r\n",
        "value",
        "\r\n",
        "--WebKitFormBoundary7MA4YWxkTrZu0gW\r\n",
        'Content-Disposition: form-data; name="file"; filename="test.txt"\r\n',
        "Content-Type: text/plain\r\n",
        "\r\n",
        "hello world",
        "\r\n",
        "--WebKitFormBoundary7MA4YWxkTrZu0gW--\r\n",
        "\r\n",
      ],
      (() => {
        const fd = new FormData();
        fd.append("file", new Blob(["hello world"]), "test.txt");
        fd.append("field", "value");
        return fd;
      })(),
    ],
    with1Field: [
      [
        "--WebKitFormBoundary7MA4YWxkTrZu0gW\r\n",
        'Content-Disposition: form-data; name="field"\r\n',
        "\r\n",
        "value",
        "\r\n",
        "--WebKitFormBoundary7MA4YWxkTrZu0gW--\r\n",
        "\r\n",
      ],
      (() => {
        const fd = new FormData();
        fd.append("field", "value");
        return fd;
      })(),
    ],
    empty: [["--WebKitFormBoundary7MA4YWxkTrZu0gW--\r\n", "\r\n"], new FormData()],
  };

  for (const name in fixtures) {
    const [chunks, expected] = fixtures[name];

    function responseWithStart() {
      return new Response(
        new ReadableStream({
          start(controller) {
            for (const chunk of chunks) controller.enqueue(chunk);
            controller.close();
          },
        }),
        {
          headers: {
            "content-type": "multipart/form-data; boundary=WebKitFormBoundary7MA4YWxkTrZu0gW",
          },
        },
      );
    }

    function responseWithPull() {
      return new Response(
        new ReadableStream({
          pull(controller) {
            for (const chunk of chunks) controller.enqueue(chunk);
            controller.close();
          },
        }),
        {
          headers: {
            "content-type": "multipart/form-data; boundary=WebKitFormBoundary7MA4YWxkTrZu0gW",
          },
        },
      );
    }

    function responseWithPullAsync() {
      return new Response(
        new ReadableStream({
          async pull(controller) {
            for (const chunk of chunks) {
              await tick();
              controller.enqueue(chunk);
            }
            controller.close();
          },
        }),
        {
          headers: {
            "content-type": "multipart/form-data; boundary=WebKitFormBoundary7MA4YWxkTrZu0gW",
          },
        },
      );
    }

    it(`response.formData() ${name}`, async () => {
      const parsed = await responseWithPull().formData();
      expect(parsed.toJSON()).toEqual(expected.toJSON());
      expect((await responseWithStart().formData()).toJSON()).toEqual(expected.toJSON());
      expect((await responseWithPullAsync().formData()).toJSON()).toEqual(expected.toJSON());

      if (expected.has("field"))
        expect(parsed.get("field")).toBe("value");
      if (expected.has("file")) {
        const file = parsed.get("file");
        expect(file instanceof File).toBe(true);
        expect(file.name).toBe("test.txt");
        expect(file.type).toBe("text/plain");
        expect(await file.text()).toBe("hello world");
      }
    });
  }
});
