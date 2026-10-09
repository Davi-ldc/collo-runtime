// Collo compatibility contract derived from Bun v1.3.14:
// - reference/bun-v1.3.14/test/js/web/fetch/request.test.ts
// - reference/bun-v1.3.14/test/js/web/fetch/body.test.ts

describe("Request", () => {
  const bytes = value => Array.from(value instanceof ArrayBuffer ? new Uint8Array(value) : value);

  function descriptor(obj, key) {
    const desc = Object.getOwnPropertyDescriptor(obj, key);
    assert(desc, `${String(key)} descriptor should exist`);
    return desc;
  }

  function assertDataDescriptor(desc, value, writable, enumerable, configurable, label) {
    assert.equal(desc.value, value, `${label} value`);
    assert.equal(desc.writable, writable, `${label} writable`);
    assert.equal(desc.enumerable, enumerable, `${label} enumerable`);
    assert.equal(desc.configurable, configurable, `${label} configurable`);
    assert.equal("get" in desc, false, `${label} should not be accessor`);
    assert.equal("set" in desc, false, `${label} should not be accessor`);
  }

  function assertFunctionShape(fn, name, length, hasPrototype, label = name) {
    assert.equal(typeof fn, "function", `${label} should be a function`);
    assertDataDescriptor(descriptor(fn, "name"), name, false, false, true, `${label}.name`);
    assertDataDescriptor(descriptor(fn, "length"), length, false, false, true, `${label}.length`);
    assert.equal(Object.hasOwn(fn, "prototype"), hasPrototype, `${label} prototype presence`);
  }

  test("globals and descriptors", () => {
    assert.equal(typeof Request, "function");
    assert.equal(Request.length, 1);
    assert.equal(Request.name, "Request");
    assert.throws(() => Request("https://example.com/"), TypeError);

    assertDataDescriptor(descriptor(globalThis, "Request"), Request, true, false, true, "global Request");
    assertFunctionShape(Request, "Request", 1, true);
    assertDataDescriptor(descriptor(Request, "prototype"), Request.prototype, false, false, false, "Request.prototype");
    assertDataDescriptor(descriptor(Request.prototype, "constructor"), Request, true, false, true, "Request.prototype.constructor");
    assert.equal(Object.getPrototypeOf(Request.prototype), Object.prototype);
    assert.equal(Request.prototype[Symbol.toStringTag], "Request");
    assertDataDescriptor(descriptor(Request.prototype, Symbol.toStringTag), "Request", false, false, true, "Request.prototype Symbol.toStringTag");

    for (const name of [
      "method",
      "destination",
      "referrer",
      "referrerPolicy",
      "mode",
      "credentials",
      "cache",
      "redirect",
      "integrity",
      "keepalive",
      "path",
      "url",
      "headers",
      "body",
      "bodyUsed",
      "signal",
      "params",
      "query",
    ]) {
      const property = descriptor(Request.prototype, name);
      assert.equal(typeof property.get, "function", `${name} getter`);
      assert.equal(property.set, undefined, `${name} setter`);
      assert.equal(property.enumerable, false, `${name} enumerable`);
      assert.equal(property.configurable, true, `${name} configurable`);
      assertFunctionShape(property.get, `get ${name}`, 0, false, `Request.${name} getter`);
      assert.throws(() => property.get.call({}), TypeError);
    }

    for (const name of ["text", "json", "arrayBuffer", "bytes", "blob", "formData", "clone"]) {
      const property = descriptor(Request.prototype, name);
      assert.equal(typeof property.value, "function", `${name} function`);
      assert.equal(property.enumerable, false, `${name} enumerable`);
      assert.equal(property.configurable, true, `${name} configurable`);
      assert.equal(property.writable, true, `${name} writable`);
      assertFunctionShape(property.value, name, 0, false, `Request.${name}`);
      assert.throws(() => property.value.call({}), TypeError);
    }
  });

  test("constructor accepts URL strings and default init", () => {
    const request = new Request("https://example.com/a/b?x=1&y=2");
    assert(request instanceof Request);
    assert.equal(request.method, "GET");
    assert.equal(request.url, "https://example.com/a/b?x=1&y=2");
    assert.equal(request.path, "/a/b");
    assert.equal(request.query.get("x"), "1");
    assert.equal(request.headers.get("missing"), null);
    assert.equal(request.body, null);
    assert.equal(request.bodyUsed, false);
    assert(request.signal instanceof AbortSignal);
    assert.equal(request.signal.aborted, false);
    assert.equal(request.destination, "");
    assert.equal(request.referrer, "about:client");
    assert.equal(request.mode, "cors");
    assert.equal(request.credentials, "same-origin");
    assert.equal(request.cache, "default");
    assert.equal(request.redirect, "follow");
    assert.equal(request.integrity, "");
    assert.equal(request.keepalive, false);

    const fromURL = new Request(new URL("https://example.com/from-url"));
    assert.equal(fromURL.url, "https://example.com/from-url");
    assert.equal(fromURL.path, "/from-url");
    assert.equal(Object.prototype.toString.call(request), "[object Request]");
  });

  test("constructor normalizes method and filters forbidden request headers", async () => {
    const request = new Request("https://example.com/submit", {
      method: "post",
      headers: {
        host: "tenant.example",
        "content-length": "7",
        "x-custom": "yes",
      },
      body: "payload",
      keepalive: true,
    });

    assert.equal(request.method, "POST");
    assert.equal(request.headers.get("host"), null);
    assert.equal(request.headers.get("content-length"), null);
    assert.equal(request.headers.get("x-custom"), "yes");
    assert.equal(request.keepalive, true);
    assert.equal(await request.text(), "payload");

    const copied = new Request("https://example.com/copy", {
      headers: new Headers({ host: "tenant.example", cookie: "secret=1", "x-copy": "yes" }),
    });
    assert.equal(copied.headers.get("host"), null);
    assert.equal(copied.headers.get("cookie"), null);
    assert.equal(copied.headers.get("x-copy"), "yes");
  });

  test("constructor supports binary BodyInit", async () => {
    const source = new Uint8Array([0, 255, 65]);
    const request = new Request("https://example.com/binary", {
      method: "PUT",
      body: source,
    });
    source[0] = 9;

    assert.deepEqual(bytes(await request.bytes()), [0, 255, 65]);

    const blobRequest = new Request("https://example.com/json", {
      method: "POST",
      body: new Blob(["{}"], { type: "application/json" }),
    });
    assert.equal(blobRequest.headers.get("content-type"), "application/json");
    assert.deepEqual(await blobRequest.json(), {});
  });

  test("copy constructor clones headers and body", async () => {
    const original = new Request("https://example.com/path?q=1", {
      method: "POST",
      headers: { "x-original": "yes" },
      body: "hello",
    });

    const clone = new Request(original);
    original.headers.set("x-original", "changed");
    clone.headers.set("x-clone", "1");

    assert.equal(clone.method, "POST");
    assert.equal(clone.url, "https://example.com/path?q=1");
    assert.equal(clone.headers.get("x-original"), "yes");
    assert.equal(original.headers.get("x-original"), "changed");
    assert.equal(original.headers.get("x-clone"), null);
    assert.equal(await original.text(), "hello");
    assert.equal(await clone.text(), "hello");
  });

  test("subclassing preserves internal request slots", async () => {
    class SpecialRequest extends Request {}
    const request = new SpecialRequest("https://example.com/special", {
      method: "POST",
      headers: { "x-special": "1" },
      body: "special",
    });
    assert(request instanceof SpecialRequest);
    assert(request instanceof Request);
    assert.equal(request.method, "POST");
    assert.equal(request.headers.get("x-special"), "1");
    assert.equal(await request.text(), "special");
  });

  test("init overrides copied request fields", async () => {
    const original = new Request("https://example.com/path", {
      method: "POST",
      headers: { "x-original": "yes" },
      body: "old",
    });
    const request = new Request(original, {
      method: "PATCH",
      headers: { "x-new": "yes" },
      body: "new",
      cache: "no-store",
      redirect: "manual",
      integrity: "sha256-test",
    });

    assert.equal(request.method, "PATCH");
    assert.equal(request.headers.get("x-original"), null);
    assert.equal(request.headers.get("x-new"), "yes");
    assert.equal(request.cache, "no-store");
    assert.equal(request.redirect, "manual");
    assert.equal(request.integrity, "sha256-test");
    assert.equal(await request.text(), "new");
  });

  test("constructor validates standard init enum fields", () => {
    for (const value of ["cors", "same-origin", "no-cors"])
      assert.equal(new Request("https://example.com/", { mode: value }).mode, value);
    assert.throws(() => new Request("https://example.com/", { mode: "navigate" }), TypeError);
    assert.throws(() => new Request("https://example.com/", { mode: "invalid" }), TypeError);

    for (const value of ["omit", "same-origin", "include"])
      assert.equal(new Request("https://example.com/", { credentials: value }).credentials, value);
    assert.throws(() => new Request("https://example.com/", { credentials: "invalid" }), TypeError);

    for (const value of ["default", "no-store", "reload", "no-cache", "force-cache"])
      assert.equal(new Request("https://example.com/", { cache: value }).cache, value);
    assert.equal(new Request("https://example.com/", { mode: "same-origin", cache: "only-if-cached" }).cache, "only-if-cached");
    assert.equal(new Request(new Request("https://example.com/", { mode: "same-origin" }), { cache: "only-if-cached" }).cache, "only-if-cached");
    assert.throws(() => new Request("https://example.com/", { cache: "only-if-cached" }), TypeError);
    assert.throws(() => new Request("https://example.com/", { cache: "invalid" }), TypeError);

    for (const value of ["follow", "error", "manual"])
      assert.equal(new Request("https://example.com/", { redirect: value }).redirect, value);
    assert.throws(() => new Request("https://example.com/", { redirect: "invalid" }), TypeError);

    for (const value of [
      "",
      "no-referrer",
      "no-referrer-when-downgrade",
      "same-origin",
      "origin",
      "strict-origin",
      "origin-when-cross-origin",
      "strict-origin-when-cross-origin",
      "unsafe-url",
    ])
      assert.equal(new Request("https://example.com/", { referrerPolicy: value }).referrerPolicy, value);
    assert.throws(() => new Request("https://example.com/", { referrerPolicy: "invalid" }), TypeError);
  });

  test("constructor validates referrer, window, and no-cors method restrictions", () => {
    assert.equal(new Request("https://example.com/").referrer, "about:client");
    assert.equal(new Request("https://example.com/", { referrer: "" }).referrer, "");
    assert.equal(new Request("https://example.com/", { referrer: "about:client" }).referrer, "about:client");
    assert.equal(new Request("https://example.com/", { referrer: "https://ref.example/path#section" }).referrer, "https://ref.example/path#section");
    assert.equal(new Request("https://example.com/", { referrer: "about:blank" }).referrer, "about:blank");
    assert.throws(() => new Request("https://example.com/", { referrer: "not a url" }), TypeError);
    assert.throws(() => new Request("https://example.com/", { referrer: "/relative" }), TypeError);

    assert.equal(new Request("https://example.com/", { window: null }).url, "https://example.com/");
    assert.equal(new Request("https://example.com/", { window: undefined }).url, "https://example.com/");
    assert.throws(() => new Request("https://example.com/", { window: {} }), TypeError);

    assert.equal(new Request("https://example.com/", { mode: "no-cors", method: "POST" }).method, "POST");
    assert.throws(() => new Request("https://example.com/", { mode: "no-cors", method: "PUT" }), TypeError);
    assert.throws(() => new Request("https://example.com/", { mode: "no-cors", method: "DELETE" }), TypeError);
  });

  test("clone copies readable body and rejects used body", async () => {
    const request = new Request("https://example.com/", {
      method: "POST",
      headers: { "x-test": "1" },
      body: "clone me",
    });
    const clone = request.clone();
    request.headers.set("x-test", "2");

    assert(clone instanceof Request);
    assert.equal(clone.headers.get("x-test"), "1");
    assert.equal(await clone.text(), "clone me");
    assert.equal(await request.text(), "clone me");
    assert.throws(() => request.clone(), TypeError);
  });

  test("signal init is preserved", () => {
    const controller = new AbortController();
    const request = new Request("https://example.com/", { signal: controller.signal });
    assert.equal(request.signal, controller.signal);
    assert.equal(request.signal.aborted, false);
    controller.abort("boom");
    assert.equal(request.signal.aborted, true);
    assert.equal(request.signal.reason, "boom");
  });

  test("invalid constructor inputs throw", () => {
    assert.throws(() => Request("https://example.com/"), TypeError);
    assert.throws(() => new Request(), TypeError);
    assert.throws(() => new Request("not a url"), TypeError);
    assert.throws(() => new Request("https://example.com/", { method: "" }), TypeError);
    assert.throws(() => new Request("https://example.com/", { method: "bad method" }), TypeError);
    assert.throws(() => new Request("https://example.com/", { method: "GET", body: "x" }), TypeError);
    assert.throws(() => new Request("https://example.com/", { method: "HEAD", body: "x" }), TypeError);
    assert.throws(() => new Request(new Request("https://example.com/", { method: "POST", body: "x" }), { method: "GET" }), TypeError);
    assert.throws(() => new Request("https://example.com/", { signal: {} }), TypeError);
    assert.throws(() => new Request("https://example.com/", { credentials: "same-origin\0" }), TypeError);
  });

  test("body readers decode invalid UTF-8 with replacement and reject detached BodyInit", async () => {
    assert.equal(await new Request("https://example.com/", {
      method: "POST",
      body: new Uint8Array([0xe2, 0x28, 0xa1]),
    }).text(), "\uFFFD(\uFFFD");

    const buffer = new ArrayBuffer(4);
    const view = new Uint8Array(buffer);
    structuredClone(buffer, { transfer: [buffer] });
    assert.throws(() => new Request("https://example.com/", { method: "POST", body: view }), TypeError);
  });
});
