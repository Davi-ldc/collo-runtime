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

test("File globals descriptors and inheritance", () => {
  assert.equal(typeof File, "function");
  assert.equal(File.length, 2);
  assert.equal(File.name, "File");
  assert.throws(() => File([], "x"), TypeError);

  assertDataDescriptor(descriptor(globalThis, "File"), File, true, false, true, "global File");
  assertFunctionShape(File, "File", 2, true);
  assertDataDescriptor(descriptor(File, "prototype"), File.prototype, false, false, false, "File.prototype");
  assertDataDescriptor(descriptor(File.prototype, "constructor"), File, true, false, true, "File.prototype.constructor");
  assert.equal(Object.getPrototypeOf(File), Blob);
  assert.equal(File.prototype[Symbol.toStringTag], "File");
  assertDataDescriptor(descriptor(File.prototype, Symbol.toStringTag), "File", false, false, true, "File.prototype Symbol.toStringTag");

  const file = new File(["abc"], "demo.txt", { type: "Text/Plain", lastModified: 42 });
  assert(file instanceof File);
  assert(file instanceof Blob);
  assert.equal(Object.getPrototypeOf(File.prototype), Blob.prototype);
  assert.equal(Object.prototype.toString.call(file), "[object File]");
  assert.equal(file.constructor, File);
  assert.equal(file.size, 3);
  assert.equal(file.type, "text/plain");
  assert.equal(file.name, "demo.txt");
  assert.equal(file.lastModified, 42);

  for (const name of ["name", "lastModified"]) {
    const property = descriptor(File.prototype, name);
    assert.equal(typeof property.get, "function", `${name} getter`);
    assert.equal(property.set, undefined, `${name} setter`);
    assert.equal(property.enumerable, true, `${name} enumerable`);
    assert.equal(property.configurable, true, `${name} configurable`);
    assertFunctionShape(property.get, `get ${name}`, 0, false, `File.${name} getter`);
  }
});

test("File constructor requires fileBits and fileName", () => {
  assert.throws(() => new File(), TypeError);
  assert.throws(() => new File([]), TypeError);
});

test("File constructor accepts WebIDL sequence fileBits", async () => {
  const cases = [
    [[], 0, ""],
    [["bits"], 4, "bits"],
    [["𝓽𝓮𝔁𝓽"], 16, "𝓽𝓮𝔁𝓽"],
    [[new String("string object")], 13, "string object"],
    [[new Blob(["bits"])], 4, "bits"],
    [[new File(["file"], "inner.txt")], 4, "file"],
    [[new ArrayBuffer(3)], 3, "\0\0\0"],
    [[new Uint8Array([0x50, 0x41, 0x53, 0x53])], 4, "PASS"],
    [[12], 2, "12"],
    [[[1, 2, 3]], 5, "1,2,3"],
    [[{}], 15, "[object Object]"],
    [{ *[Symbol.iterator]() { yield "ab"; yield "cde"; } }, 5, "abcde"],
    [new Uint8Array([1, 2, 3]), 3, "123"],
  ];

  for (const [bits, expectedSize, expectedText] of cases) {
    const file = new File(bits, "dummy");
    assert(file instanceof File);
    assert.equal(file.name, "dummy");
    assert.equal(file.size, expectedSize);
    assert.equal(file.type, "");
    assert.equal(await file.text(), expectedText);
  }

  for (const bits of ["hello", 0, null, true])
    assert.throws(() => new File(bits, "bad.txt"), TypeError);
});

test("File fileName is converted to USVString without path normalization", async () => {
  const cases = [
    ["dummy", "dummy"],
    ["dummy/foo", "dummy/foo"],
    [null, "null"],
    [1, "1"],
    ["", ""],
    ["a\uD800b", "a\ufffdb"],
  ];

  for (const [input, expected] of cases) {
    const file = new File(["x"], input);
    assert.equal(file.name, expected);
    assert.equal(await file.text(), "x");
  }
});

test("File options share BlobPropertyBag behavior and add lastModified", async () => {
  const file = new File(["\ra\r\nb\n"], "lines.txt", {
    endings: "native",
    type: "Text/Plain;Charset=UTF-8",
    lastModified: new Date(10),
  });
  assert.equal(await file.text(), "\na\nb\n");
  assert.equal(file.type, "text/plain;charset=utf-8");
  assert.equal(file.lastModified, 10);

  assert.equal(new File(["bits"], "dummy", { type: "ascii/nonprintable\u001F" }).type, "");
  assert.equal(new File(["bits"], "dummy", { unknownKey: "value" }).name, "dummy");
  assert.equal(new File(["bits"], "dummy", { name: "ignored" }).name, "dummy");
  assert.equal(new File(["bits"], "dummy", { lastModified: Number.POSITIVE_INFINITY }).lastModified, 0);
  assert.equal(new File(["bits"], "dummy", { lastModified: Number.NaN }).lastModified, 0);
  assert.equal(new File(["bits"], "dummy", { lastModified: 1.9 }).lastModified, 1);
  const hugeLastModified = new File(["bits"], "dummy", { lastModified: 1e30 }).lastModified;
  assert(Number.isFinite(hugeLastModified));
  assert(Number.isInteger(hugeLastModified));

  for (const value of [123, 123.4, true, "abc"])
    assert.throws(() => new File(["bits"], "name.txt", value), TypeError);

  for (const value of [null, undefined, [1, 2, 3], /regex/, function ignored() {}])
    assert.equal(new File(["bits"], "name.txt", value).size, 4);
});

test("File default lastModified is a finite timestamp", () => {
  const file = new File(["x"], "x.txt");
  assert.equal(typeof file.lastModified, "number");
  assert(Number.isFinite(file.lastModified));
  assert(file.lastModified > 0);
});

test("File constructor evaluation order matches WebIDL", () => {
  const accessed = [];
  new File([], "x", {
    get type() { accessed.push("type"); return ""; },
    get lastModified() { accessed.push("lastModified"); return 1; },
    get endings() { accessed.push("endings"); return "transparent"; },
  });
  assert.deepEqual(accessed, ["endings", "lastModified", "type"]);

  const marker = { name: "marker" };
  let thrown;
  try {
    new File([{ toString() { throw marker; } }], {
      toString() { throw new Error("should not convert filename after fileBits failure"); },
    }, {
      get type() { throw new Error("should not read options after fileBits failure"); },
    });
  } catch (error) {
    thrown = error;
  }
  assert.equal(thrown, marker);
});

test("File supports subclass new.target and Blob methods", async () => {
  class CustomFile extends File {}
  const file = new CustomFile(["hello"], "hello.txt", { type: "text/plain", lastModified: 7 });
  assert(file instanceof CustomFile);
  assert(file instanceof File);
  assert(file instanceof Blob);
  assert.equal(Object.getPrototypeOf(file), CustomFile.prototype);
  assert.equal(file.name, "hello.txt");
  assert.equal(file.lastModified, 7);
  assert.equal(await file.text(), "hello");
  assert.deepEqual(Array.from(await file.bytes()), [104, 101, 108, 108, 111]);

  const sliced = file.slice(1, 4, "Text/HTML");
  assert(sliced instanceof Blob);
  assert.equal(sliced instanceof File, false);
  assert.equal(sliced.type, "text/html");
  assert.equal(await sliced.text(), "ell");
});

test("File accessors enforce native receiver brand", () => {
  const nameGetter = Object.getOwnPropertyDescriptor(File.prototype, "name").get;
  const lastModifiedGetter = Object.getOwnPropertyDescriptor(File.prototype, "lastModified").get;
  assert.throws(() => nameGetter.call({}), TypeError);
  assert.throws(() => lastModifiedGetter.call({}), TypeError);
});
