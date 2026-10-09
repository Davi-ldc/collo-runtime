// Collo compatibility contract derived from Bun v1.3.14:
// - reference/bun-v1.3.14/test/js/web/fetch/body.test.ts
// - reference/bun-v1.3.14/test/js/web/fetch/body-mixin-errors.test.ts

describe("Body", () => {
  const bytes = value => Array.from(value instanceof ArrayBuffer ? new Uint8Array(value) : value);

  test("Response string bodies preserve UTF-8 text", async () => {
    for (const text of ["", "Hello world", "🫠", "⁉️"]) {
      const response = new Response(text);
      assert.equal(await response.text(), text);
    }
  });

  test("Response json parses and marks body used", async () => {
    const response = new Response("{\"value\":42}");
    assert.equal(response.bodyUsed, false);
    assert.deepEqual(await response.json(), { value: 42 });
    assert.equal(response.bodyUsed, true);
  });

  test("invalid json rejects promise", async () => {
    const response = new Response("{");
    let rejected = false;
    try {
      await response.json();
    } catch (err) {
      rejected = err instanceof SyntaxError || err instanceof Error;
    }
    assert(rejected, "invalid json should reject");
  });

  test("Response arrayBuffer and bytes preserve UTF-8 bytes", async () => {
    const expected = [72, 194, 169, 228, 184, 150];

    const buffer = await new Response("H©世").arrayBuffer();
    assert(buffer instanceof ArrayBuffer);
    assert.deepEqual(bytes(buffer), expected);

    const view = await new Response("H©世").bytes();
    assert(view instanceof Uint8Array);
    assert.deepEqual(bytes(view), expected);
  });

  test("Response binary BodyInit preserves raw bytes and Blob content type", async () => {
    const source = new Uint8Array([0, 255, 65]);
    const response = new Response(source);
    source[0] = 9;
    assert.deepEqual(bytes(await response.bytes()), [0, 255, 65]);

    const backing = new Uint8Array([4, 5, 6, 7]).buffer;
    assert.deepEqual(bytes(await new Response(new DataView(backing, 1, 2)).bytes()), [5, 6]);
    assert.deepEqual(bytes(await new Response(new ArrayBuffer(3)).arrayBuffer()), [0, 0, 0]);

    if (typeof ArrayBuffer.prototype.resize === "function") {
      const resizable = new ArrayBuffer(3, { maxByteLength: 3 });
      new Uint8Array(resizable).set([1, 2, 3]);
      assert.throws(() => new Response(new Uint8Array(resizable)), TypeError);
    }

    const blobResponse = new Response(new Blob(["{}"], { type: "Application/JSON;charset=UTF-8" }));
    assert.equal(blobResponse.headers.get("content-type"), "application/json;charset=utf-8");
    assert.deepEqual(await blobResponse.json(), {});
  });

  test("Response Blob BodyInit preserves nested sliced blob bytes", async () => {
    const source = new Blob(["ab", new Uint8Array([99, 100, 101, 102])]);
    const body = new Blob([source.slice(1, 5), source.slice(5)], { type: "Text/Plain" });

    assert.equal(await new Response(body).text(), "bcdef");
    assert.deepEqual(bytes(await new Response(body).bytes()), [98, 99, 100, 101, 102]);
    assert.equal(new TextDecoder().decode(await new Response(body).arrayBuffer()), "bcdef");

    const blob = await new Response(body).blob();
    assert.equal(blob.type, "text/plain");
    assert.equal(await blob.text(), "bcdef");
  });

  test("Response blob preserves UTF-8 bytes and content type", async () => {
    const blob = await new Response("H©世", {
      headers: { "content-type": "Text/Plain;charset=UTF-8" },
    }).blob();

    assert(blob instanceof Blob);
    assert.equal(blob.type, "text/plain;charset=utf-8");
    assert.equal(await blob.text(), "H©世");
    assert.deepEqual(bytes(await blob.bytes()), [72, 194, 169, 228, 184, 150]);
  });

  test("Response formData parses URL encoded bodies", async () => {
    const response = new Response("\uFEFFok=true&name=Collo+Runtime&emoji=%F0%9F%8C%8E", {
      headers: { "content-type": "application/x-www-form-urlencoded;charset=utf-8" },
    });
    const form = await response.formData();
    assert(form instanceof FormData);
    assert.equal(form.get("ok"), "true");
    assert.equal(form.get("name"), "Collo Runtime");
    assert.equal(form.get("emoji"), "🌎");
  });

  test("Response formData parses multipart text and file entries", async () => {
    const body = [
      "--abc123",
      'Content-Disposition: form-data; name="metadata"',
      "",
      "{\"ok\":true}",
      "--abc123",
      "Content-Disposition: form-data; name=\"file\"; filename*=\"UTF-8''%F0%9F%9A%80.txt\"",
      "Content-Type: Text/Plain",
      "",
      "hello file",
      "--abc123--",
      "",
    ].join("\r\n");
    const form = await new Response(body, {
      headers: { "content-type": 'multipart/form-data; boundary="abc123"' },
    }).formData();
    assert.equal(form.get("metadata"), "{\"ok\":true}");
    const file = form.get("file");
    assert(file instanceof File);
    assert.equal(file.name, "🚀.txt");
    assert.equal(file.type, "text/plain");
    assert.equal(await file.text(), "hello file");
  });

  test("Response formData matches Bun multipart edge cases", async () => {
    const empty = await new Response("--def456--", {
      headers: { "content-type": "multipart/form-data; boundary=def456" },
    }).formData();
    assert.deepEqual(Array.from(empty), []);

    const unquoted = await new Response([
      "----123456",
      "Content-Disposition: form-data; name=value",
      "Content-Type: text/plain",
      "",
      "goodbye",
      "----123456--",
      "",
    ].join("\r\n"), {
      headers: { "content-type": "multipart/form-data; boundary=--123456" },
    }).formData();
    assert.equal(unquoted.get("value"), "goodbye");

    const rfc5987 = await new Response([
      "----abcdefg",
      "Content-Disposition: form-data; name=\"emoji\"; filename*=UTF-8''%F0%9F%9A%80.js",
      "Content-Type: application/javascript;charset=utf-8",
      "",
      "console.log(\"🚀\");\n",
      "----abcdefg--",
      "",
    ].join("\r\n"), {
      headers: { "content-type": "multipart/form-data; boundary=--abcdefg" },
    }).formData();
    const file = rfc5987.get("emoji");
    assert(file instanceof File);
    assert.equal(file.name, "🚀.js");
    assert.equal(file.type, "application/javascript;charset=utf-8");
    assert.equal(await file.text(), "console.log(\"🚀\");\n");
  });

  test("Response formData rejects null unsupported and malformed bodies", async () => {
    for (const response of [
      new Response(),
      new Response("plain", { headers: { "content-type": "text/plain" } }),
      new Response("--abc\r\n\r\nx", { headers: { "content-type": "multipart/form-data" } }),
      new Response("body", { headers: { "content-type": 'multipart/form-data; boundary="' } }),
      new Response("--abc\r\nContent-Disposition: form-data; name=\"file\"; filename*UTF-8''x.txt\r\n\r\nx\r\n--abc--\r\n", { headers: { "content-type": "multipart/form-data; boundary=abc" } }),
      new Response("--abc\r\nContent-Disposition: form-data; name=\"bad\nname\"\r\n\r\nx\r\n--abc--\r\n", { headers: { "content-type": "multipart/form-data; boundary=abc" } }),
    ]) {
      let rejected = false;
      try {
        await response.formData();
      } catch (err) {
        rejected = err instanceof TypeError;
      }
      assert(rejected, "invalid formData input should reject with TypeError");
    }
  });

  test("null body consumers resolve empty values without marking bodyUsed", async () => {
    for (const method of ["text", "arrayBuffer", "bytes", "blob"]) {
      const response = new Response();
      const value = await response[method]();
      if (method === "text")
        assert.equal(value, "");
      else if (method === "blob")
        assert.equal(value.size, 0);
      else
        assert.deepEqual(bytes(value), []);
      assert.equal(response.bodyUsed, false, `${method} should not disturb null body`);
    }

    const nullable = new Response(null);
    await nullable.arrayBuffer();
    assert.equal(nullable.bodyUsed, false);
  });

  test("non-null body consumers mark bodyUsed", async () => {
    for (const method of ["text", "json", "arrayBuffer", "bytes", "blob"]) {
      const response = new Response("{\"ok\":true}");
      assert.equal(response.bodyUsed, false);
      await response[method]();
      assert.equal(response.bodyUsed, true, `${method} should disturb non-null body`);
    }
  });

  test("body already used rejects with TypeError across consumers", async () => {
    const methods = ["text", "json", "arrayBuffer", "bytes", "blob"];
    for (const first of methods) {
      for (const second of methods) {
        const response = new Response("{\"ok\":true}");
        await response[first]();
        try {
          await response[second]();
          assert(false, `${first} then ${second} should reject`);
        } catch (err) {
          assert.equal(err.name, "TypeError");
          assert(err instanceof TypeError);
        }
      }
    }
  });

  test("formData marks bodyUsed and rejects second reads", async () => {
    const response = new Response("a=1", {
      headers: { "content-type": "application/x-www-form-urlencoded" },
    });
    assert.equal(response.bodyUsed, false);
    assert.equal((await response.formData()).get("a"), "1");
    assert.equal(response.bodyUsed, true);
    let rejected = false;
    try {
      await response.text();
    } catch (err) {
      rejected = err instanceof TypeError;
    }
    assert(rejected, "second read after formData should reject");
  });

  test("arrayBuffer and bytes return independent copies", async () => {
    const first = new Uint8Array(await new Response("abc").arrayBuffer());
    first[0] = 120;
    assert.equal(await new Response("abc").text(), "abc");

    const second = await new Response("abc").bytes();
    second[1] = 121;
    assert.equal(await new Response("abc").text(), "abc");
  });

  test("Request body consumers share Body mixin semantics with Response", async () => {
    const request = new Request("https://example.com/body", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{\"ok\":true}",
    });
    assert(request.body instanceof ReadableStream);
    assert.equal(request.bodyUsed, false);
    assert.deepEqual(await request.json(), { ok: true });
    assert.equal(request.bodyUsed, true);
    let rejected = false;
    try {
      await request.text();
    } catch (err) {
      rejected = err instanceof TypeError;
    }
    assert(rejected, "Request second body read should reject");

    const binary = new Request("https://example.com/binary", {
      method: "POST",
      body: new Uint8Array([1, 2, 3]),
    });
    const copy = await binary.bytes();
    copy[0] = 9;
    assert.deepEqual(bytes(await new Request("https://example.com/binary", {
      method: "POST",
      body: new Uint8Array([1, 2, 3]),
    }).bytes()), [1, 2, 3]);
  });

  test("BodyInit string conversion and unavailable buffer sources are handled consistently", async () => {
    assert.equal(await new Response({ toString() { return "object body"; } }).text(), "object body");

    const buffer = new ArrayBuffer(8);
    const view = new Uint8Array(buffer);
    structuredClone(buffer, { transfer: [buffer] });
    assert.throws(() => new Response(view), TypeError);
    assert.throws(() => new Response(buffer), TypeError);

    const streamBuffer = new ArrayBuffer(8);
    structuredClone(streamBuffer, { transfer: [streamBuffer] });
    const detachedStreamResponse = new Response(new ReadableStream({
      start(controller) {
        controller.enqueue(streamBuffer);
        controller.close();
      },
    }));
    assert(await detachedStreamResponse.arrayBuffer().then(
      () => false,
      error => error instanceof TypeError,
    ));

    if (typeof ArrayBuffer.prototype.resize === "function") {
      const resizable = new ArrayBuffer(8, { maxByteLength: 8 });
      assert.throws(() => new Response(resizable), TypeError);

      const resized = new ArrayBuffer(8, { maxByteLength: 8 });
      const outOfBounds = new Uint8Array(resized, 4, 4);
      resized.resize(2);
      assert.throws(() => new Response(outOfBounds), TypeError);

      const streamResponse = new Response(new ReadableStream({
        start(controller) {
          controller.enqueue(outOfBounds);
          controller.close();
        },
      }));
      assert(await streamResponse.arrayBuffer().then(
        () => false,
        error => error instanceof TypeError,
      ));
    }
  });
});
