// Collo compatibility contract derived from Bun v1.3.14:
// - reference/bun-v1.3.14/test/js/web/fetch/fetch-args.test.ts

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

describe("fetch", () => {
  async function rejectsTypeError(promise, label) {
    try {
      await promise;
    } catch (err) {
      assert(err instanceof TypeError, `${label} should reject with TypeError`);
      return;
    }
    assert(false, `${label} should reject`);
  }

  test("serverless global shape", () => {
    assert.equal(self, globalThis);
    assert.equal(typeof window, "undefined");
    assertDataDescriptor(descriptor(globalThis, "self"), globalThis, true, false, true, "global self");
  });

  test("global descriptor and function shape", () => {
    assert.equal(typeof fetch, "function");
    assert.equal(fetch.name, "fetch");
    assert.equal(fetch.length, 1);
    assert.equal(Object.hasOwn(fetch, "prototype"), false);
    assert.equal(Object.getPrototypeOf(fetch), Function.prototype);

    assertDataDescriptor(descriptor(globalThis, "fetch"), fetch, true, false, true, "global fetch");
    assertDataDescriptor(descriptor(fetch, "length"), 1, false, false, true, "fetch.length");
    assertDataDescriptor(descriptor(fetch, "name"), "fetch", false, false, true, "fetch.name");
  });

  test("invalid URL rejects synchronously", () => {
    assert.throws(() => fetch(), TypeError);
    assert.throws(() => fetch(""), TypeError);
    assert.throws(() => fetch("has space"), TypeError);
    assert.throws(() => fetch({ url: "" }), TypeError);
    assert.throws(() => fetch(Symbol("url")), TypeError);
  });

  test("uses Request validation for method and body", () => {
    assert.throws(() => fetch("https://example.com/", { method: "GET", body: "x" }), TypeError);
    assert.throws(() => fetch("https://example.com/", { mode: "no-cors", method: "PUT" }), TypeError);
  });

  test("rejects parsed but unsupported fetch options before native egress", async () => {
    await rejectsTypeError(fetch("https://example.com/", { integrity: "sha256-test" }), "integrity");
    await rejectsTypeError(fetch("https://example.com/", { mode: "same-origin" }), "mode");
    await rejectsTypeError(fetch("https://example.com/", { credentials: "include" }), "credentials");
    await rejectsTypeError(fetch("https://example.com/", { cache: "reload" }), "cache");
    await rejectsTypeError(fetch("https://example.com/", { referrerPolicy: "no-referrer" }), "referrerPolicy");
    await rejectsTypeError(fetch("https://example.com/", { referrer: "https://referrer.example/" }), "referrer");
    await rejectsTypeError(fetch("https://example.com/", { keepalive: true }), "keepalive");
  });
});
