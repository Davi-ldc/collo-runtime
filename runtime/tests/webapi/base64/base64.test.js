// Collo compatibility contract derived from Bun v1.3.14:
// - reference/bun-v1.3.14/test/js/web/util/atob.test.js
// - reference/bun-v1.3.14/test/js/node/test/parallel/test-btoa-atob.js

function expectInvalidAtob(value) {
  const error = assert.throws(() => atob(value));
  assert(error instanceof DOMException, "atob error should be DOMException");
  assert.equal(error.name, "InvalidCharacterError");
  assert.equal(error.code, DOMException.INVALID_CHARACTER_ERR);
}

function descriptor(obj, key) {
  const desc = Object.getOwnPropertyDescriptor(obj, key);
  assert(desc, `${String(key)} descriptor should exist`);
  return desc;
}

describe("atob and btoa", () => {
  test("globals and descriptors", () => {
    assert.equal(typeof atob, "function");
    assert.equal(typeof btoa, "function");
    assert.equal(atob.name, "atob");
    assert.equal(btoa.name, "btoa");
    assert.equal(atob.length, 1);
    assert.equal(btoa.length, 1);

    for (const name of ["atob", "btoa"]) {
      const globalDesc = descriptor(globalThis, name);
      assert.equal(globalDesc.value, globalThis[name]);
      assert.equal(globalDesc.writable, true);
      assert.equal(globalDesc.enumerable, false);
      assert.equal(globalDesc.configurable, true);
      assert.equal(Object.hasOwn(globalThis[name], "prototype"), false);
      assert.equal(Object.getPrototypeOf(globalThis[name]), Function.prototype);

      const lengthDescriptor = descriptor(globalThis[name], "length");
      assert.equal(lengthDescriptor.value, 1);
      assert.equal(lengthDescriptor.writable, false);
      assert.equal(lengthDescriptor.enumerable, false);
      assert.equal(lengthDescriptor.configurable, true);

      const nameDescriptor = descriptor(globalThis[name], "name");
      assert.equal(nameDescriptor.value, name);
      assert.equal(nameDescriptor.writable, false);
      assert.equal(nameDescriptor.enumerable, false);
      assert.equal(nameDescriptor.configurable, true);
    }
  });

  test("atob decodes forgiving base64 and binary strings", () => {
    assert.equal(atob("YQ=="), "a");
    assert.equal(atob("YWI="), "ab");
    assert.equal(atob("YWJj"), "abc");
    assert.equal(atob("YWJjZA=="), "abcd");
    assert.equal(atob("YWJjZGU="), "abcde");
    assert.equal(atob("YWJjZGVm"), "abcdef");
    assert.equal(atob("zzzz"), "\xcf<\xf3");
    assert.equal(atob("6ek="), "\xe9\xe9");
    assert.equal(atob("6ek"), "\xe9\xe9");
    assert.equal(atob("gIE="), "\x80\x81");
    assert.equal(atob("YQ"), "a");
    assert.equal(atob("YWI"), "ab");
    assert.equal(atob("zz"), "\xcf");
    assert.equal(atob("zzz"), "\xcf<");
    assert.equal(atob("zzz="), "\xcf<");
    assert.equal(atob(""), "");
    assert.equal(atob("\t\n\f\r "), "");
    assert.equal(atob(" "), "");
    assert.equal(atob("  Y\fW\tJ\njZ A=\r= "), "abcd");
    assert.equal(atob(("🧐" + "YQ==").substring("🧐".length)), "a");
    assert.equal(atob("/wBB"), "\xff\0A");
    assert.equal(atob.call(null, "YQ==", "ignored"), "a");
  });

  test("atob uses WebIDL string conversion", () => {
    assert.equal(atob(null), "\x9e\xe9e");
    assert.equal(atob(NaN), "5\xa3");
    assert.equal(atob(Infinity), "\"w\xe2\x9e+r");
    assert.equal(atob(true), "\xb6\xbb\x9e");
    assert.equal(atob(1234), "\xd7m\xf8");
    assert.equal(atob([]), "");
    assert.equal(atob(["YQ=="]), "a");
    assert.equal(atob(new String("YQ==")), "a");
    assert.equal(atob({ toString: () => "" }), "");
    assert.equal(atob({ [Symbol.toPrimitive]: () => "" }), "");
    assert.throws(() => atob(), TypeError);
    assert.throws(() => atob(Symbol()), TypeError);
  });

  test("atob rejects malformed base64 with DOMException InvalidCharacterError", () => {
    for (const value of [
      undefined,
      false,
      () => {},
      {},
      [1],
      0,
      1,
      0n,
      1n,
      -Infinity,
      "a",
      "a\n\n\n",
      "\ra\r\r",
      "  a ",
      "\t\t\ta",
      "a\f\f\f",
      "\ta\r \n\f",
      " abcd===",
      "abcd=== ",
      "abcd ===",
      "YQ=",
      "YWI==",
      "тест",
      "z",
      "zzz==",
      "zzz===",
      "zzz====",
      "zzz=====",
      "zzzzz",
      "z=zz",
      "YQ==$",
      "YQ==!",
      "YQ==A",
      "YQ--",
      "YQ__",
      "\vYQ==",
      "\u00a0YQ==",
      "\u0100",
      "=",
      "==",
      "===",
      "====",
      "=====",
    ]) {
      expectInvalidAtob(value);
    }
  });

  test("btoa encodes byte strings as base64", () => {
    assert.equal(btoa("a"), "YQ==");
    assert.equal(btoa("ab"), "YWI=");
    assert.equal(btoa("abc"), "YWJj");
    assert.equal(btoa("abcd"), "YWJjZA==");
    assert.equal(btoa("abcde"), "YWJjZGU=");
    assert.equal(btoa("abcdef"), "YWJjZGVm");
    assert.equal(btoa(""), "");
    assert.equal(btoa("\0"), "AA==");
    assert.equal(btoa("\0\0"), "AAA=");
    assert.equal(btoa("\0\0\0"), "AAAA");
    assert.equal(btoa(null), "bnVsbA==");
    assert.equal(btoa(undefined), "dW5kZWZpbmVk");
    assert.equal(btoa("[object Window]"), "W29iamVjdCBXaW5kb3dd");
    assert.equal(btoa("\xe9\xe9"), "6ek=");
    assert.equal(btoa("🧐\xe9\xe9".substring("🧐".length)), "6ek=");
    assert.equal(btoa(("🧐" + "\xff\0A").substring("🧐".length)), "/wBB");
    assert.equal(btoa("\x80\x81"), "gIE=");
    assert.equal(btoa(new String("ok")), "b2s=");
    assert.equal(btoa({ toString: () => "ok" }), "b2s=");
    assert.equal(btoa({ [Symbol.toPrimitive]: () => "ok" }), "b2s=");
    assert.equal(btoa.call(null, "abc", "ignored"), "YWJj");
  });

  test("btoa validates required argument and Latin1 byte range", () => {
    assert.throws(() => btoa(), TypeError);
    assert.throws(() => btoa(Symbol()), TypeError);
    for (const value of ["Ā", "😀", "тест", "\ud800"]) {
      const error = assert.throws(() => btoa(value));
      assert(error instanceof DOMException, "btoa error should be DOMException");
      assert.equal(error.name, "InvalidCharacterError");
      assert.equal(error.code, DOMException.INVALID_CHARACTER_ERR);
    }
  });

  test("global bindings are writable and configurable", () => {
    const original = { atob, btoa };
    try {
      globalThis.atob = function replacement() {
        return "decoded";
      };
      assert.equal(atob(), "decoded");

      assert.equal(delete globalThis.btoa, true);
      assert.equal(Object.hasOwn(globalThis, "btoa"), false);
    } finally {
      for (const [name, fn] of Object.entries(original)) {
        Object.defineProperty(globalThis, name, {
          value: fn,
          writable: true,
          enumerable: false,
          configurable: true,
        });
      }
    }
  });
});
