// Collo compatibility contract derived from Bun v1.3.14:
// - reference/bun-v1.3.14/test/js/web/fetch/response.test.ts

describe("Response", () => {
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
    assert.equal(typeof Response, "function");
    assert.equal(Response.length, 1);
    assert.equal(Response.name, "Response");
    assert.throws(() => Response("x"), TypeError);

    assertDataDescriptor(descriptor(globalThis, "Response"), Response, true, false, true, "global Response");
    assertFunctionShape(Response, "Response", 1, true);
    assertDataDescriptor(descriptor(Response, "prototype"), Response.prototype, false, false, false, "Response.prototype");
    assertDataDescriptor(descriptor(Response.prototype, "constructor"), Response, true, false, true, "Response.prototype.constructor");
    assert.equal(Object.getPrototypeOf(Response.prototype), Object.prototype);
    assert.equal(Response.prototype[Symbol.toStringTag], "Response");
    assertDataDescriptor(descriptor(Response.prototype, Symbol.toStringTag), "Response", false, false, true, "Response.prototype Symbol.toStringTag");

    for (const name of ["status", "statusText", "url", "type", "redirected", "body", "headers", "ok", "bodyUsed"]) {
      const property = descriptor(Response.prototype, name);
      assert.equal(typeof property.get, "function", `${name} getter`);
      assert.equal(property.set, undefined, `${name} setter`);
      assert.equal(property.enumerable, false, `${name} enumerable`);
      assert.equal(property.configurable, true, `${name} configurable`);
      assertFunctionShape(property.get, `get ${name}`, 0, false, `Response.${name} getter`);
      assert.throws(() => property.get.call({}), TypeError);
    }

    for (const name of ["text", "json", "arrayBuffer", "bytes", "blob", "formData", "clone"]) {
      const property = descriptor(Response.prototype, name);
      assert.equal(typeof property.value, "function", `${name} function`);
      assert.equal(property.enumerable, false, `${name} enumerable`);
      assert.equal(property.configurable, true, `${name} configurable`);
      assert.equal(property.writable, true, `${name} writable`);
      assertFunctionShape(property.value, name, 0, false, `Response.${name}`);
      assert.throws(() => property.value.call({}), TypeError);
    }

    for (const [name, length] of [["json", 2], ["redirect", 1], ["error", 0]]) {
      const property = descriptor(Response, name);
      assert.equal(typeof property.value, "function", `${name} static`);
      assert.equal(property.enumerable, false, `${name} enumerable`);
      assert.equal(property.configurable, true, `${name} configurable`);
      assert.equal(property.writable, true, `${name} writable`);
      assertFunctionShape(property.value, name, length, false, `Response.${name}`);
    }
  });

  test("zero and undefined args return empty 200 response", () => {
    const empty = new Response();
    assert.equal(empty.status, 200);
    assert.equal(empty.statusText, "");
    assert.equal(empty.type, "default");
    assert.equal(empty.redirected, false);
    assert.equal(empty.url, "");
    assert.equal(empty.ok, true);
    assert.equal(empty.body, null);
    assert.equal(empty.bodyUsed, false);
    assert.equal(Object.prototype.toString.call(empty), "[object Response]");

    const explicit = new Response("", {
      status: undefined,
      statusText: undefined,
      headers: undefined,
    });
    assert.equal(explicit.status, 200);
    assert.equal(explicit.statusText, "");
  });

  test("body and init set public state", async () => {
    const one = new Response("body text");
    assert.equal(one.status, 200);
    assert.equal(one.statusText, "");
    assert.equal(await one.text(), "body text");

    const two = new Response("body text", { status: 202, statusText: "Accepted." });
    assert.equal(two.status, 202);
    assert.equal(two.statusText, "Accepted.");
    assert.equal(two.ok, true);
  });

  test("statusText is stringified and unrelated init members are ignored", () => {
    assert.equal(new Response("123", { statusText: 123 }).statusText, "123");
    assert.doesNotThrow(() => new Response("123", { method: 456 }));
  });

  test("status conversion validates integer response status range", () => {
    assert.equal(new Response(null, { status: "201" }).status, 201);
    assert.throws(() => new Response(null, { status: 199 }), RangeError);
    assert.throws(() => new Response(null, { status: 600 }), RangeError);
    assert.throws(() => new Response(null, { status: 200.5 }), RangeError);
    assert.throws(() => new Response(null, { status: NaN }), RangeError);
    for (const status of [204, 205, 304])
      assert.throws(() => new Response("body", { status }), TypeError);
  });

  test("invalid WebAPI inputs are rejected", () => {
    assert.throws(() => new Response("missing", 404), TypeError);
    assert.throws(() => new Response("x", { status: 204 }), TypeError);
    assert.equal(new Response(null, { status: 204 }).status, 204);
    assert.throws(() => Response.json({ toJSON() { return undefined; } }), TypeError);
    assert.throws(() => Response.json({ ok: true }, { status: 204 }), TypeError);
  });

  test("Response.json sets body and default content-type", async () => {
    const response = Response.json({ ok: true });
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-type"), "application/json");
    assert.deepEqual(await response.json(), { ok: true });

    const custom = Response.json({ ok: true }, { headers: { "content-type": "application/vnd.collo+json" } });
    assert.equal(custom.headers.get("content-type"), "application/vnd.collo+json");
    assert.deepEqual(await custom.json(), { ok: true });
  });

  test("Response.redirect validates redirect status and sets location", () => {
    const defaultRedirect = Response.redirect("https://example.com/path");
    assert.equal(defaultRedirect.status, 302);
    assert.equal(defaultRedirect.type, "default");
    assert.equal(defaultRedirect.redirected, false);
    assert.equal(defaultRedirect.ok, false);
    assert.equal(defaultRedirect.headers.get("location"), "https://example.com/path");

    for (const status of [301, 302, 303, 307, 308])
      assert.equal(Response.redirect("https://example.com/", status).status, status);

    assert.equal(Response.redirect("https://example.com/", { status: 308 }).status, 308);
    assert.throws(() => Response.redirect("https://example.com/", 200), RangeError);
    assert.throws(() => Response.redirect("https://example.com/", { status: 400 }), RangeError);
  });

  test("Response.error returns network error response", () => {
    const response = Response.error();
    assert(response instanceof Response);
    assert.equal(response.type, "error");
    assert.equal(response.redirected, false);
    assert.equal(response.status, 0);
    assert.equal(response.statusText, "");
    assert.equal(response.ok, false);
    assert.equal(response.headers.get("x-missing"), null);
    response.headers.set("x-test", "1");
    assert.equal(response.headers.get("x-test"), "1");
  });

  test("Response.clone copies headers and readable text body", async () => {
    const response = new Response("<div>hello</div>", {
      status: 201,
      statusText: "Created",
      headers: {
        "content-type": "text/html; charset=utf-8",
        "x-original": "yes",
      },
    });

    const clone = response.clone();
    assert(clone instanceof Response);
    assert.equal(clone.status, 201);
    assert.equal(clone.statusText, "Created");
    assert.equal(clone.type, "default");
    assert.equal(clone.redirected, false);

    response.headers.set("content-type", "text/plain");
    response.headers.set("x-original", "changed");
    assert.equal(clone.headers.get("content-type"), "text/html; charset=utf-8");
    assert.equal(clone.headers.get("x-original"), "yes");
    assert.equal(response.headers.get("content-type"), "text/plain");

    assert.equal(await clone.text(), "<div>hello</div>");
    assert.equal(await response.text(), "<div>hello</div>");
  });

  test("subclassing preserves internal response slots", async () => {
    class SpecialResponse extends Response {}
    const response = new SpecialResponse("special", {
      status: 201,
      headers: { "x-special": "1" },
    });
    assert(response instanceof SpecialResponse);
    assert(response instanceof Response);
    assert.equal(response.status, 201);
    assert.equal(response.headers.get("x-special"), "1");
    assert.equal(await response.text(), "special");
  });

  test("Response.clone rejects used body and clones error responses", async () => {
    const response = new Response("used");
    await response.text();
    assert.throws(() => response.clone(), TypeError);

    const errorClone = Response.error().clone();
    assert.equal(errorClone.type, "error");
    assert.equal(errorClone.status, 0);
    assert.equal(await errorClone.text(), "");
  });

  test("body consumption rejects second read", async () => {
    const response = new Response("a");
    assert.equal(await response.text(), "a");
    let rejected = false;
    try {
      await response.text();
    } catch (err) {
      rejected = err instanceof TypeError;
    }
    assert(rejected, "second body read should reject with TypeError");
  });
});
