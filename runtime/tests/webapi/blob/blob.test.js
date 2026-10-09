// Collo compatibility contract derived from Bun v1.3.14:
// - reference/bun-v1.3.14/test/js/web/fetch/blob.test.ts

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

test("Blob globals and descriptors", () => {
  assert.equal(typeof Blob, "function");
  assert.equal(Blob.length, 0);
  assert.equal(Blob.name, "Blob");
  assert.throws(() => Blob(), TypeError);

  assertDataDescriptor(descriptor(globalThis, "Blob"), Blob, true, false, true, "global Blob");
  assertFunctionShape(Blob, "Blob", 0, true);
  assertDataDescriptor(descriptor(Blob, "prototype"), Blob.prototype, false, false, false, "Blob.prototype");

  const blob = new Blob();
  assert(blob instanceof Blob);
  assert.equal(Object.prototype.toString.call(blob), "[object Blob]");
  assert.equal(blob.constructor.name, "Blob");

  const proto = Blob.prototype;
  assertDataDescriptor(descriptor(proto, "constructor"), Blob, true, false, true, "Blob.prototype.constructor");
  assert.equal(proto[Symbol.toStringTag], "Blob");
  assertDataDescriptor(descriptor(proto, Symbol.toStringTag), "Blob", false, false, true, "Blob.prototype Symbol.toStringTag");

  for (const name of ["size", "type"]) {
    const property = descriptor(proto, name);
    assert.equal(typeof property.get, "function", `${name} getter`);
    assert.equal(property.set, undefined, `${name} setter`);
    assert.equal(property.enumerable, true, `${name} enumerable`);
    assert.equal(property.configurable, true, `${name} configurable`);
    assertFunctionShape(property.get, `get ${name}`, 0, false, `Blob.${name} getter`);
  }

  for (const [name, length] of [["slice", 0], ["arrayBuffer", 0], ["bytes", 0], ["text", 0], ["formData", 0]]) {
    const property = descriptor(proto, name);
    assert.equal(typeof property.value, "function", `${name} function`);
    assert.equal(property.enumerable, true, `${name} enumerable`);
    assert.equal(property.configurable, true, `${name} configurable`);
    assert.equal(property.writable, true, `${name} writable`);
    assertFunctionShape(property.value, name, length, false, `Blob.${name}`);
  }
});

test("Blob constructor follows WebIDL sequence conversion and subclass new.target", async () => {
  for (const value of [null, true, false, 0, 1.5, "FAIL", {}, { 0: "FAIL", length: 1 }])
    assert.throws(() => new Blob(value), TypeError);

  assert.equal(await new Blob(new String("xyz")).text(), "xyz");
  assert.equal(await new Blob(new Uint8Array([1, 2, 3])).text(), "123");
  assert.equal(await new Blob({ [Symbol.iterator]: Array.prototype[Symbol.iterator], 0: "ok", length: 1 }).text(), "ok");
  assert.equal(await new Blob({ *[Symbol.iterator]() { yield "ab"; yield "c"; } }).text(), "abc");

  class CustomBlob extends Blob {}
  const blob = new CustomBlob(["ok"]);
  assert(blob instanceof CustomBlob);
  assert(blob instanceof Blob);
  assert.equal(Object.getPrototypeOf(blob), CustomBlob.prototype);
  assert.equal(blob.size, 2);
  assert.equal(await blob.text(), "ok");

  const sliced = blob.slice(0, 1);
  assert(sliced instanceof Blob);
  assert.equal(sliced instanceof CustomBlob, false);
  assert.equal(await sliced.text(), "o");
});

test("Blob constructor concatenates strings blobs and buffer sources", async () => {
  const buffer = new ArrayBuffer(4);
  const bytes = new Uint8Array(buffer);
  bytes.set([65, 66, 67, 68]);
  const view = new Uint8Array(buffer, 1, 2);
  const blob = new Blob(["hi", new Blob(["!"]), buffer, view]);

  assert.equal(blob.size, 2 + 1 + 4 + 2);
  assert.equal(blob.type, "");
  assert.equal(await blob.text(), "hi!ABCD" + "BC");
});

test("Blob constructor rejects unavailable buffer source parts", () => {
  const detached = new ArrayBuffer(8);
  structuredClone(detached, { transfer: [detached] });
  assert.throws(() => new Blob([detached]), TypeError);

  if (typeof ArrayBuffer.prototype.resize === "function") {
    const resizable = new ArrayBuffer(8, { maxByteLength: 8 });
    assert.throws(() => new Blob([resizable]), TypeError);

    const inBoundsBuffer = new ArrayBuffer(4, { maxByteLength: 4 });
    const inBoundsView = new Uint8Array(inBoundsBuffer);
    inBoundsView.set([65, 66, 67, 68]);
    assert.throws(() => new Blob([inBoundsView]), TypeError);

    const buffer = new ArrayBuffer(8, { maxByteLength: 8 });
    const view = new Uint8Array(buffer, 4, 4);
    buffer.resize(2);
    assert.throws(() => new Blob([view]), TypeError);
  }
});

test("Blob preserves nested sliced blob parts across byte consumers", async () => {
  const source = new Blob(["ab", new Uint8Array([99, 100, 101, 102])]);
  const nested = new Blob(["<", source.slice(1, 5), ">", source.slice(5)]);

  assert.equal(nested.size, 7);
  assert.equal(await nested.text(), "<bcde>f");
  assert.deepEqual(Array.from(await nested.bytes()), [60, 98, 99, 100, 101, 62, 102]);
  assert.equal(new TextDecoder().decode(await nested.arrayBuffer()), "<bcde>f");
});

test("Blob copies ArrayBufferView bytes during construction", async () => {
  const source = new Uint8Array([102, 111, 111]);
  const blob = new Blob([source]);
  source[0] = 98;

  assert.equal(await blob.text(), "foo");
  const bytes = await blob.bytes();
  assert(bytes instanceof Uint8Array);
  assert.deepEqual(Array.from(bytes), [102, 111, 111]);
});

test("Blob.arrayBuffer and Blob.bytes return independent copies", async () => {
  const blob = new Blob(["abc"]);

  const first = new Uint8Array(await blob.arrayBuffer());
  first[0] = 120;
  assert.equal(await blob.text(), "abc");

  const second = await blob.bytes();
  second[1] = 121;
  assert.equal(await blob.text(), "abc");
});

test("Blob type option is ASCII-lowercased or emptied", () => {
  assert.equal(new Blob([], { type: "Text/HTML;Charset=UTF-8" }).type, "text/html;charset=utf-8");
  assert.equal(new Blob([], { type: "text/\u0521" }).type, "");
  assert.equal(new Blob([], { type: "text/\nplain" }).type, "");
  assert.equal(new Blob([], null).type, "");
  assert.equal(new Blob([], /regex/).type, "");
  assert.equal(new Blob([], function ignored() {}).type, "");
  for (const value of [123, true, "ignored"])
    assert.throws(() => new Blob([], value), TypeError);
});

test("Blob endings option validates enum and normalizes native line endings", async () => {
  assert.equal(await new Blob(["\ra\r\nb\n"], { endings: "transparent" }).text(), "\ra\r\nb\n");
  assert.equal(await new Blob(["\ra\r\nb\n"], { endings: "native" }).text(), "\na\nb\n");
  for (const value of [null, "", "Transparent", "NATIVE", 0, {}])
    assert.throws(() => new Blob([], { endings: value }), TypeError);

  let called = false;
  new Blob([], { get endings() { called = true; return "transparent"; } });
  assert.equal(called, true);
});

test("Blob native line endings normalize across string part boundaries", async () => {
  // A \r ending one part and a \n starting the next must collapse to a single
  // \n, not be normalized independently into two \n.
  assert.equal(await new Blob(["a\r", "\nb"], { endings: "native" }).text(), "a\nb");
  assert.equal(await new Blob(["a\r", "\r\nb"], { endings: "native" }).text(), "a\n\nb");
  assert.equal(await new Blob(["x\r", "y"], { endings: "native" }).text(), "x\ny");
  // Many CR-ending parts in a row.
  assert.equal(await new Blob(["a\r", "\nb\r", "\nc"], { endings: "native" }).text(), "a\nb\nc");
  // A non-string (binary) part breaks the text stream: a \n that begins the
  // following string part is NOT consumed by the previous part's trailing \r.
  assert.equal(
    await new Blob(["a\r", new Uint8Array([0x2d]), "\nb"], { endings: "native" }).text(),
    "a\n-\nb",
  );
  // transparent leaves everything untouched even across boundaries.
  assert.equal(await new Blob(["a\r", "\nb"], { endings: "transparent" }).text(), "a\r\nb");
});

test("Blob constructor uses indexed array semantics: holes skip, prototype getters honored", async () => {
  // A real Array is walked by index (not via a custom Symbol.iterator); genuine
  // holes and explicit undefined/null elements are skipped, not stringified.
  assert.equal(await new Blob(["a", , "c"]).text(), "ac");
  assert.equal(await new Blob([undefined, "x", null]).text(), "x");

  const sparse = [];
  sparse[0] = "first";
  sparse[100] = "last";
  assert.equal(await new Blob(sparse).text(), "firstlast");

  // A hole consults the prototype chain.
  let calls = 0;
  Object.defineProperty(Array.prototype, 1, {
    get() { calls++; return "intercepted"; },
    configurable: true,
  });
  try {
    assert.equal(await new Blob(["x", , "z"]).text(), "xinterceptedz");
    assert.equal(calls, 1);
  } finally {
    delete Array.prototype[1];
  }

  // A custom Symbol.iterator on a *real* Array is ignored (indexed walk wins);
  // non-Array iterables still use the iterator protocol (covered above).
  const arr = ["a", "b"];
  arr[Symbol.iterator] = function* () { yield "IGNORED"; };
  assert.equal(await new Blob(arr).text(), "ab");
});

test("Blob.slice with no contentType yields an empty string type", () => {
  const blob = new Blob(["DenoFoo"], { type: "text/plain" });
  assert.equal(blob.slice(0, 3).type, "");
  assert.equal(blob.slice(0, 3, undefined).type, "");
  assert.equal(typeof blob.slice(0, 3).type, "string");
});

test("Blob constructor evaluates parts before options and options lexicographically", () => {
  const accessed = [];
  new Blob([], {
    get type() { accessed.push("type"); return ""; },
    get endings() { accessed.push("endings"); return "transparent"; },
  });
  assert.deepEqual(accessed, ["endings", "type"]);

  const marker = { name: "marker" };
  let thrown;
  try {
    new Blob([{ toString() { throw marker; } }], {
      get type() { throw new Error("should not read options after blobParts failure"); },
    });
  } catch (error) {
    thrown = error;
  }
  assert.equal(thrown, marker);
});

test("Blob.slice follows relative offsets and content type normalization", async () => {
  const blob = new Blob(["Deno", "Foo"], { type: "text/plain" });

  const first = blob.slice(0, 3, "Text/HTML");
  assert(first instanceof Blob);
  assert.equal(first.size, 3);
  assert.equal(first.type, "text/html");
  assert.equal(await first.text(), "Den");

  assert.equal(blob.slice(-1, 3).size, 0);
  assert.equal(blob.slice(100, 3).size, 0);
  assert.equal(blob.slice(0, 10).size, blob.size);
  assert.equal(await blob.slice(-3).text(), "Foo");
  assert.equal(await blob.slice(undefined, undefined, "bad\u0100").text(), "DenoFoo");
  assert.equal(blob.slice(undefined, undefined, "bad\u0100").type, "");
});

test("Blob methods enforce native receiver brand", () => {
  const getter = Object.getOwnPropertyDescriptor(Blob.prototype, "size").get;
  assert.throws(() => getter.call({}), TypeError);
  assert.throws(() => Blob.prototype.text.call({}), TypeError);
  assert.throws(() => Blob.prototype.arrayBuffer.call({}), TypeError);
  assert.throws(() => Blob.prototype.bytes.call({}), TypeError);
  assert.throws(() => Blob.prototype.formData.call({}), TypeError);
  assert.throws(() => Blob.prototype.slice.call({}), TypeError);
});

test("Blob.formData parses URL encoded bodies and rejects unsupported content types", async () => {
  const encoded = new Blob(["\uFEFFhello=world+ok&emoji=%F0%9F%8C%8E"], {
    type: "application/x-www-form-urlencoded;charset=utf-8",
  });
  const form = await encoded.formData();
  assert(form instanceof FormData);
  assert.equal(form.get("hello"), "world ok");
  assert.equal(form.get("emoji"), "🌎");

  let rejected = false;
  try {
    await new Blob(["hello"], { type: "text/plain" }).formData();
  } catch (err) {
    rejected = err instanceof TypeError;
  }
  assert(rejected, "unsupported Blob.formData content type should reject");
});

test("Blob.formData parses multipart and rejects malformed boundaries", async () => {
  const multipart = new Blob([
    '--foo\r\nContent-Disposition: form-data; name="field"\r\n\r\nvalue\r\n--foo--\r\n',
  ], {
    type: "multipart/form-data; boundary=foo",
  });
  const form = await multipart.formData();
  assert(form instanceof FormData);
  assert.equal(form.get("field"), "value");

  for (const blob of [
    new Blob(["body"], { type: 'multipart/form-data; boundary="' }),
    new Blob(["body"], { type: 'multipart/form-data; boundary="abc' }),
    new Blob(["body"], { type: 'multipart/form-data; boundary="; charset=utf-8' }),
  ]) {
    let rejected = false;
    try {
      await blob.formData();
    } catch (err) {
      rejected = err instanceof TypeError;
    }
    assert(rejected, "malformed Blob.formData boundary should reject");
  }
});

test("Blob.formData rejects multipart quota failures with DOMException", async () => {
  let body = "";
  for (let i = 0; i < 1001; i++)
    body += `--foo\r\nContent-Disposition: form-data; name="p${i}"\r\n\r\n\r\n`;
  body += "--foo--\r\n";
  const blob = new Blob([body], { type: "multipart/form-data; boundary=foo" });

  let quotaError;
  try {
    await blob.formData();
  } catch (err) {
    quotaError = err;
  }
  assert(quotaError instanceof DOMException);
  assert.equal(quotaError.name, "QuotaExceededError");
});

test("Blob text replaces invalid UTF-8 sequences", async () => {
  const blob = new Blob([new Uint8Array([0x66, 0x80, 0x6f])]);
  assert.equal(await blob.text(), "f\ufffdo");
});

test("Blob constructor converts string parts as USVString", async () => {
  assert.equal(await new Blob(["a\uD800b"]).text(), "a\ufffdb");
});
