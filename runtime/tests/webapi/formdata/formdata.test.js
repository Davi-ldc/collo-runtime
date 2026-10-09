// Collo compatibility contract derived from Bun v1.3.14:
// - reference/bun-v1.3.14/test/js/web/html/FormData.test.ts

function formDataFrom(pairs, method = "append") {
  const form = new FormData();
  for (const pair of pairs)
    form[method](...pair);
  return form;
}

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

function assertThrowsTypeError(label, fn) {
  try {
    fn();
  } catch (error) {
    assert(error instanceof TypeError, `${label} should throw TypeError, got ${error?.constructor?.name}`);
    return error;
  }
  throw new Error(`${label} did not throw`);
}

function assertThrowsQuota(label, fn) {
  try {
    fn();
  } catch (error) {
    assert(error instanceof DOMException, `${label} should throw DOMException, got ${error?.constructor?.name}`);
    assert.equal(error.name, "QuotaExceededError", `${label} error name`);
    return error;
  }
  throw new Error(`${label} did not throw`);
}

test("FormData globals descriptors and prototype shape", () => {
  assert.equal(typeof FormData, "function");
  assert.equal(FormData.length, 0);
  assert.equal(FormData.name, "FormData");
  assert.throws(() => FormData(), TypeError);

  assertDataDescriptor(descriptor(globalThis, "FormData"), FormData, true, false, true, "global FormData");
  assertFunctionShape(FormData, "FormData", 0, true);
  assertDataDescriptor(descriptor(FormData, "prototype"), FormData.prototype, false, false, false, "FormData.prototype");
  assertDataDescriptor(descriptor(FormData.prototype, "constructor"), FormData, true, false, true, "FormData.prototype.constructor");
  assertDataDescriptor(descriptor(FormData.prototype, Symbol.toStringTag), "FormData", false, false, true, "FormData.prototype Symbol.toStringTag");

  const form = new FormData();
  assert(form instanceof FormData);
  assert.equal(Object.prototype.toString.call(form), "[object FormData]");
  assert.equal(form.constructor, FormData);
  assert.equal(FormData.prototype[Symbol.iterator], FormData.prototype.entries);
  assert.equal(Object.keys(FormData.prototype).join(","), "append,delete,get,getAll,has,set,entries,keys,values,forEach,toJSON");

  for (const [name, length] of [
    ["append", 2],
    ["delete", 1],
    ["get", 1],
    ["getAll", 1],
    ["has", 1],
    ["set", 2],
    ["forEach", 1],
    ["entries", 0],
    ["keys", 0],
    ["values", 0],
  ]) {
    const property = descriptor(FormData.prototype, name);
    assert.equal(typeof property.value, "function", `${name} function`);
    assert.equal(property.enumerable, true, `${name} enumerable`);
    assert.equal(property.configurable, true, `${name} configurable`);
    assert.equal(property.writable, true, `${name} writable`);
    assertFunctionShape(property.value, name, length, false, `FormData.${name}`);
  }

  const toJSON = descriptor(FormData.prototype, "toJSON");
  assert.equal(toJSON.value.length, 0);
  assert.equal(toJSON.enumerable, true);
  assert.equal(toJSON.configurable, false);
  assert.equal(toJSON.writable, false);
  assertFunctionShape(toJSON.value, "toJSON", 0, false, "FormData.toJSON");

  const length = descriptor(FormData.prototype, "length");
  assert.equal(length.enumerable, false);
  assert.equal(length.configurable, false);
  assertFunctionShape(length.get, "get length", 0, false, "FormData.length getter");

  const from = descriptor(FormData, "from");
  assert.equal(from.value.length, 1);
  assert.equal(from.enumerable, true);
  assert.equal(from.configurable, false);
  assert.equal(from.writable, false);
  assertFunctionShape(from.value, "from", 1, false, "FormData.from");

  assertDataDescriptor(descriptor(FormData.prototype, Symbol.iterator), FormData.prototype.entries, true, false, true, "FormData.prototype @@iterator");
  const iterator = form.entries();
  assert.equal(Object.prototype.toString.call(iterator), "[object FormData Iterator]");
  const iteratorPrototype = Object.getPrototypeOf(iterator);
  assertDataDescriptor(descriptor(iteratorPrototype, Symbol.toStringTag), "FormData Iterator", false, false, true, "FormData Iterator Symbol.toStringTag");
  assertFunctionShape(descriptor(iteratorPrototype, "next").value, "next", 0, false, "FormData Iterator.next");
});

test("FormData constructor supports empty construction only", () => {
  assert(new FormData() instanceof FormData);
  assert(new FormData(undefined) instanceof FormData);
  for (const value of [null, "form", {}, 1, true])
    assert.throws(() => new FormData(value), TypeError);
});

test("FormData string entries append get getAll has delete and set", () => {
  const form = formDataFrom([
    ["key", "value1"],
    ["key", "value2"],
    ["other", "value3"],
  ]);
  assert.equal(form.get("key"), "value1");
  assert.deepEqual(form.getAll("key"), ["value1", "value2"]);
  assert.equal(form.get("missing"), null);
  assert.deepEqual(form.getAll("missing"), []);
  assert.equal(form.has("key"), true);
  assert.equal(form.has("missing"), false);

  form.delete("key");
  assert.equal(form.get("key"), null);
  assert.equal(form.get("other"), "value3");

  const setForm = formDataFrom([
    ["key", "value1"],
    ["key", "value2"],
    ["tail", "value3"],
  ], "set");
  assert.deepEqual(Array.from(setForm), [["key", "value2"], ["tail", "value3"]]);

  setForm.set("key", "value4");
  assert.deepEqual(Array.from(setForm), [["key", "value4"], ["tail", "value3"]]);
  setForm.set("new", "value5");
  assert.deepEqual(Array.from(setForm), [["key", "value4"], ["tail", "value3"], ["new", "value5"]]);
});

test("FormData Bun-compatible length and toJSON", () => {
  const form = new FormData();
  form.append(1, 1);
  form.append("a", "1");
  form.append("a", "2");
  const file = new File(["hello"], "hello.txt", { type: "text/plain" });
  form.append("file", file);

  const json = form.toJSON();
  assert.equal(form.length, 4);
  assert.deepEqual(json["1"], "1");
  assert.deepEqual(json.a, ["1", "2"]);
  assert.equal(json.file instanceof File, true);
  assert.equal(json.file.name, "hello.txt");
  assert.equal(JSON.stringify(json), '{"1":"1","a":["1","2"],"file":{}}');
  assert.throws(() => FormData.prototype.toJSON.call({}), TypeError);
  assert.throws(() => Object.getOwnPropertyDescriptor(FormData.prototype, "length").get.call({}), TypeError);
});

test("FormData.from parses urlencoded and multipart bytes", async () => {
  assert.deepEqual(FormData.from("a=1&b=2&a=3").toJSON(), { a: ["1", "3"], b: "2" });

  const encoded = new TextEncoder().encode("x=1&x=2");
  assert.deepEqual(FormData.from(encoded).toJSON(), { x: ["1", "2"] });
  assert.deepEqual(FormData.from(encoded.buffer).toJSON(), { x: ["1", "2"] });

  const multipart = '--foo\r\nContent-Disposition: form-data; name="field"\r\n\r\nvalue\r\n--foo\r\nContent-Disposition: form-data; name="file"; filename="a.txt"\r\nContent-Type: text/plain\r\n\r\nhello\r\n--foo--\r\n';
  const parsed = FormData.from(multipart, "foo");
  assert.equal(parsed.get("field"), "value");
  assert.equal(parsed.get("file") instanceof File, true);
  assert.equal(parsed.get("file").name, "a.txt");
  assert.equal(parsed.get("file").type, "text/plain");
  assert.equal(await parsed.get("file").text(), "hello");

  const parsedBlob = FormData.from(new Blob([multipart], { type: "multipart/form-data; boundary=foo" }));
  assert.equal(parsedBlob.get("field"), "value");

  const invalidFilenameStar = '--foo\r\nContent-Disposition: form-data; name="file"; filename="plain.txt"; filename*=iso-8859-1\'\'ignored.txt\r\n\r\nhello\r\n--foo--\r\n';
  const fallback = FormData.from(invalidFilenameStar, "foo").get("file");
  assert(fallback instanceof File);
  assert.equal(fallback.name, "plain.txt");
  assert.equal(await fallback.text(), "hello");

  const invalidEscapedFilenameStar = '--foo\r\nContent-Disposition: form-data; name="file"; filename="plain.txt"; filename*=UTF-8\'\'bad%ZZ.txt\r\n\r\nhello\r\n--foo--\r\n';
  const escapedFallback = FormData.from(invalidEscapedFilenameStar, "foo").get("file");
  assert(escapedFallback instanceof File);
  assert.equal(escapedFallback.name, "plain.txt");

  const invalidUtf8FilenameStar = '--foo\r\nContent-Disposition: form-data; name="file"; filename="plain.txt"; filename*=UTF-8\'\'bad%FF.txt\r\n\r\nhello\r\n--foo--\r\n';
  const utf8Fallback = FormData.from(invalidUtf8FilenameStar, "foo").get("file");
  assert(utf8Fallback instanceof File);
  assert.equal(utf8Fallback.name, "plain.txt");

  const encoder = new TextEncoder();
  const rawInvalidFilenameStarPrefix = encoder.encode('--foo\r\nContent-Disposition: form-data; name="file"; filename="plain.txt"; filename*=UTF-8\'\'bad');
  const rawInvalidFilenameStarSuffix = encoder.encode('.txt\r\n\r\nhello\r\n--foo--\r\n');
  const rawInvalidFilenameStar = new Uint8Array(rawInvalidFilenameStarPrefix.length + 1 + rawInvalidFilenameStarSuffix.length);
  rawInvalidFilenameStar.set(rawInvalidFilenameStarPrefix);
  rawInvalidFilenameStar[rawInvalidFilenameStarPrefix.length] = 0xff;
  rawInvalidFilenameStar.set(rawInvalidFilenameStarSuffix, rawInvalidFilenameStarPrefix.length + 1);
  const rawInvalidFallback = FormData.from(rawInvalidFilenameStar, "foo").get("file");
  assert(rawInvalidFallback instanceof File);
  assert.equal(rawInvalidFallback.name, "plain.txt");

  const emptyFilenameStar = '--foo\r\nContent-Disposition: form-data; name="file"; filename="plain.txt"; filename*=UTF-8\'\'\r\n\r\nhello\r\n--foo--\r\n';
  const emptyStarFile = FormData.from(emptyFilenameStar, "foo").get("file");
  assert(emptyStarFile instanceof File);
  assert.equal(emptyStarFile.name, "");
  assert.equal(await emptyStarFile.text(), "hello");

  const onlyEmptyFilenameStar = '--foo\r\nContent-Disposition: form-data; name="file"; filename*=UTF-8\'\'\r\n\r\nhello\r\n--foo--\r\n';
  const onlyEmptyStarFile = FormData.from(onlyEmptyFilenameStar, "foo").get("file");
  assert(onlyEmptyStarFile instanceof File);
  assert.equal(onlyEmptyStarFile.name, "");

  const quotedSemicolonFilename = '--foo\r\nContent-Disposition: form-data; name="file"; filename="a;b.txt"\r\n\r\nhello\r\n--foo--\r\n';
  const semicolonFile = FormData.from(quotedSemicolonFilename, "foo").get("file");
  assert(semicolonFile instanceof File);
  assert.equal(semicolonFile.name, "a;b.txt");

  const boundaryLikeData = '--foo\r\nContent-Disposition: form-data; name="field"\r\n\r\nbefore\r\n--foo-not-a-boundary\r\nafter\r\n--foo--\r\n';
  assert.equal(FormData.from(boundaryLikeData, "foo").get("field"), "before\r\n--foo-not-a-boundary\r\nafter");

  const closeBoundaryLikeData = '--foo\r\nContent-Disposition: form-data; name="field"\r\n\r\nbefore\r\n--foo--not-a-boundary\r\nafter\r\n--foo--\r\n';
  assert.equal(FormData.from(closeBoundaryLikeData, "foo").get("field"), "before\r\n--foo--not-a-boundary\r\nafter");

  const internalSpaceBoundary = '--foo bar\r\nContent-Disposition: form-data; name="field"\r\n\r\nvalue\r\n--foo bar--\r\n';
  assert.equal(FormData.from(internalSpaceBoundary, "foo bar").get("field"), "value");

  const paddedDelimiterBody = '--foo \t\r\nContent-Disposition: form-data; name="a"\r\n\r\none\r\n--foo\t\r\nContent-Disposition: form-data; name="b"\r\n\r\ntwo\r\n--foo-- \t\r\n';
  const paddedDelimiterForm = FormData.from(paddedDelimiterBody, "foo");
  assert.equal(paddedDelimiterForm.get("a"), "one");
  assert.equal(paddedDelimiterForm.get("b"), "two");

  assert.throws(() => FormData.from(), TypeError);
  assert.throws(() => FormData.from({}), TypeError);
});

test("FormData.from rejects malformed multipart boundaries and detached buffers", () => {
  const validBody = '--foo\r\nContent-Disposition: form-data; name="field"\r\n\r\nvalue\r\n--foo--\r\n';
  assertThrowsTypeError("quote boundary", () => FormData.from(validBody, '"'));
  assertThrowsTypeError("trailing-space boundary", () => FormData.from(validBody, "foo "));
  assertThrowsTypeError("line-break boundary", () => FormData.from(validBody, "foo\nbar"));
  assertThrowsTypeError("non-ascii boundary", () => FormData.from(validBody, "f\u00f8\u00f8"));
  assertThrowsTypeError("semicolon boundary", () => FormData.from(validBody, "foo;bar"));
  assertThrowsTypeError("missing final boundary", () => FormData.from('--foo\r\nContent-Disposition: form-data; name="field"\r\n\r\nvalue\r\n', "foo"));
  assertThrowsTypeError("unclosed quote boundary", () => FormData.from("body", "\"abc"));
  assertThrowsTypeError("malformed filename-star", () => FormData.from('--foo\r\nContent-Disposition: form-data; name="file"; filename*UTF-8\'\'x.txt\r\n\r\nx\r\n--foo--\r\n', "foo"));
  assertThrowsTypeError("raw newline in name", () => FormData.from('--foo\r\nContent-Disposition: form-data; name="bad\nname"\r\n\r\nx\r\n--foo--\r\n', "foo"));
  assertThrowsTypeError("unterminated quoted name", () => FormData.from('--foo\r\nContent-Disposition: form-data; name="field\r\n\r\nx\r\n--foo--\r\n', "foo"));
  assertThrowsTypeError("junk after quoted name", () => FormData.from('--foo\r\nContent-Disposition: form-data; name="field"junk\r\n\r\nx\r\n--foo--\r\n', "foo"));
  assertThrowsTypeError("close-like opener", () => FormData.from("--foo--not-a-boundary\r\n", "foo"));
  assertThrowsTypeError("junk before opener", () => FormData.from('junk--foo\r\nContent-Disposition: form-data; name="field"\r\n\r\nvalue\r\n--foo--\r\n', "foo"));

  const buffer = new TextEncoder().encode("x=1").buffer;
  assertThrowsTypeError("detached ArrayBuffer input", () => FormData.from(buffer, {
    toString() {
      structuredClone(buffer, { transfer: [buffer] });
      return "foo";
    },
  }));

  if (typeof ArrayBuffer.prototype.resize === "function")
    assertThrowsTypeError("resizable ArrayBuffer input", () => FormData.from(new ArrayBuffer(8, { maxByteLength: 8 })));

  if (typeof ArrayBuffer.prototype.resize === "function") {
    const resizableInputBuffer = new ArrayBuffer(3, { maxByteLength: 3 });
    const resizableInput = new Uint8Array(resizableInputBuffer);
    resizableInput.set([120, 61, 49]);
    assertThrowsTypeError("resizable ArrayBufferView input", () => FormData.from(resizableInput));

    const resizableBoundaryBuffer = new ArrayBuffer(3, { maxByteLength: 3 });
    const resizableBoundary = new Uint8Array(resizableBoundaryBuffer);
    resizableBoundary.set([102, 111, 111]);
    assertThrowsTypeError("resizable ArrayBufferView boundary", () => FormData.from(validBody, resizableBoundary));
  }

  const viewBacking = new TextEncoder().encode("x=1").buffer;
  const view = new Uint8Array(viewBacking);
  assertThrowsTypeError("detached ArrayBufferView input", () => FormData.from(view, {
    toString() {
      structuredClone(viewBacking, { transfer: [viewBacking] });
      return "foo";
    },
  }));
});

test("FormData.from rejects bodies over the materialized body limit", () => {
  const oversized = `a=${"x".repeat(4 * 1024 * 1024)}`;
  assertThrowsQuota("oversized urlencoded string", () => FormData.from(oversized));
  assertThrowsQuota("oversized urlencoded blob", () => FormData.from(new Blob([oversized], {
    type: "application/x-www-form-urlencoded",
  })));
  assertThrowsQuota("oversized multipart with explicit boundary", () => FormData.from(oversized, "foo"));
});

test("FormData.from caps multipart part and per-part header counts", () => {
  let manyParts = "";
  for (let i = 0; i < 1001; i++)
    manyParts += `--foo\r\nContent-Disposition: form-data; name="p${i}"\r\n\r\n\r\n`;
  manyParts += "--foo--\r\n";
  let error = assert.throws(() => FormData.from(manyParts, "foo"), DOMException);
  assert.equal(error.name, "QuotaExceededError");

  let headers = 'Content-Disposition: form-data; name="field"\r\n';
  for (let i = 0; i < 32; i++)
    headers += `X-${i}: value\r\n`;
  const manyHeaders = `--foo\r\n${headers}\r\nvalue\r\n--foo--\r\n`;
  error = assert.throws(() => FormData.from(manyHeaders, "foo"), DOMException);
  assert.equal(error.name, "QuotaExceededError");
});

test("FormData WebIDL string conversion and arity", () => {
  const form = new FormData();
  form.append("undefined", undefined);
  form.append("null", null);
  form.append(1, 2);
  form.append("surrogate", "a\uD800b");
  form.append("a\uD800b", "name");
  assert.equal(form.get("undefined"), "undefined");
  assert.equal(form.get("null"), "null");
  assert.equal(form.get("1"), "2");
  assert.equal(form.get("surrogate"), "a\ufffdb");
  assert.equal(form.get("a\ufffdb"), "name");

  assert.throws(() => form.append("missing"), TypeError);
  assert.throws(() => form.set("missing"), TypeError);
  assert.throws(() => form.delete(), TypeError);
  assert.throws(() => form.get(), TypeError);
  assert.throws(() => form.getAll(), TypeError);
  assert.throws(() => form.has(), TypeError);
  assert.throws(() => form.append("x", "y", "filename.txt"), TypeError);
  assert.throws(() => form.set("x", "y", "filename.txt"), TypeError);
});

test("FormData Blob and File entries follow create-entry semantics", async () => {
  const form = new FormData();
  const blob = new Blob(["blob"], { type: "Text/Plain" });
  const before = Date.now();
  form.append("blob-default", blob);
  const blobDefault = form.get("blob-default");
  assert(blobDefault instanceof File);
  assert(blobDefault instanceof Blob);
  assert.equal(blobDefault === blob, false);
  assert.equal(blobDefault.name, "blob");
  assert.equal(blobDefault.type, "text/plain");
  assert(blobDefault.lastModified >= before - 1000);
  assert(blobDefault.lastModified <= Date.now() + 1000);
  assert.equal(await blobDefault.text(), "blob");
  assert.equal(form.get("blob-default"), blobDefault);

  form.append("blob-renamed", blob, "renamed.txt");
  const blobRenamed = form.get("blob-renamed");
  assert(blobRenamed instanceof File);
  assert.equal(blobRenamed.name, "renamed.txt");
  assert.equal(blobRenamed.type, "text/plain");
  assert.equal(await blobRenamed.text(), "blob");

  const file = new File(["file"], "original.txt", { type: "Text/Custom", lastModified: 123 });
  form.append("file-default", file);
  assert.equal(form.get("file-default"), file);

  form.append("file-renamed", file, "custom.txt");
  const fileRenamed = form.get("file-renamed");
  assert(fileRenamed instanceof File);
  assert.equal(fileRenamed === file, false);
  assert.equal(fileRenamed.name, "custom.txt");
  assert.equal(fileRenamed.type, "text/custom");
  assert.equal(fileRenamed.lastModified, 123);
  assert.equal(await fileRenamed.text(), "file");

  form.set("blob-set", new Blob(["x"]), "set.txt");
  assert.equal(form.get("blob-set").name, "set.txt");
});

test("FormData iteration preserves order duplicates and live mutation behavior", () => {
  const file = new File(["hello"], "hello.txt");
  const form = new FormData();
  form.append("n1", "v1");
  form.append("n2", "v2");
  form.append("n3", "v3");
  form.append("n1", "v4");
  form.append("n2", "v5");
  form.append("n3", "v6");
  form.delete("n2");
  form.append("f1", file);

  assert.deepEqual(Array.from(form.keys()), ["n1", "n3", "n1", "n3", "f1"]);
  assert.deepEqual(Array.from(form.values()), ["v1", "v3", "v4", "v6", file]);
  assert.deepEqual(Array.from(form.entries()), [["n1", "v1"], ["n3", "v3"], ["n1", "v4"], ["n3", "v6"], ["f1", file]]);
  assert.deepEqual(Array.from(form), Array.from(form.entries()));

  const removedFuture = formDataFrom([["foo", "0"], ["baz", "1"], ["BAR", "2"]]);
  const seenFuture = [];
  for (const [name, value] of removedFuture) {
    seenFuture.push([name, value]);
    removedFuture.delete("baz");
  }
  assert.deepEqual(seenFuture, [["foo", "0"], ["BAR", "2"]]);

  const removedPast = formDataFrom([["foo", "0"], ["baz", "1"], ["BAR", "2"], ["quux", "3"]]);
  const seenPast = [];
  for (const [name, value] of removedPast) {
    seenPast.push([name, value]);
    if (name === "baz")
      removedPast.delete("foo");
  }
  assert.deepEqual(seenPast, [["foo", "0"], ["baz", "1"], ["quux", "3"]]);

  const appended = formDataFrom([["foo", "0"], ["baz", "1"], ["BAR", "2"], ["quux", "3"]]);
  const seenAppend = [];
  for (const [name, value] of appended) {
    seenAppend.push([name, value]);
    if (name === "baz")
      appended.append("X-yZ", "4");
  }
  assert.deepEqual(seenAppend, [["foo", "0"], ["baz", "1"], ["BAR", "2"], ["quux", "3"], ["X-yZ", "4"]]);
});

test("FormData iterator does not advance past exhaustion", () => {
  const form = new FormData();
  form.append("a", "1");
  const iterator = form.entries();

  let result = iterator.next();
  assert.equal(result.done, false);
  assert.deepEqual(result.value, ["a", "1"]);

  // Exhaust the iterator several times; the index must not keep advancing.
  for (let i = 0; i < 5; i++) {
    result = iterator.next();
    assert.equal(result.done, true);
    assert.equal(result.value, undefined);
  }

  // Entries appended after exhaustion are still observed, not skipped.
  form.append("b", "2");
  form.append("c", "3");
  result = iterator.next();
  assert.equal(result.done, false);
  assert.deepEqual(result.value, ["b", "2"]);
  result = iterator.next();
  assert.equal(result.done, false);
  assert.deepEqual(result.value, ["c", "3"]);
  result = iterator.next();
  assert.equal(result.done, true);

  // Keys and values iterators behave the same way.
  const keys = form.keys();
  assert.deepEqual(Array.from(keys), ["a", "b", "c"]);
  assert.equal(keys.next().done, true);
  form.append("d", "4");
  assert.deepEqual(keys.next(), { value: "d", done: false });
});

test("FormData getAll handles many entries", () => {
  const form = new FormData();
  for (let i = 0; i < 1000; i++) {
    form.append("dup", `v${i}`);
    form.append(`unique-${i}`, `u${i}`);
  }
  assert.equal(form.length, 2000);

  const all = form.getAll("dup");
  assert.equal(all.length, 1000);
  assert.equal(all[0], "v0");
  assert.equal(all[499], "v499");
  assert.equal(all[999], "v999");
  assert.deepEqual(form.getAll("unique-999"), ["u999"]);
  assert.deepEqual(form.getAll("missing"), []);
});

test("FormData append and set filename overload throws before converting name", () => {
  const form = new FormData();
  let conversions = 0;
  const name = {
    toString() {
      conversions++;
      return "spy";
    },
  };

  assert.throws(() => form.append(name, "value", "file.txt"), TypeError);
  assert.equal(conversions, 0, "append must not convert name before overload TypeError");
  assert.throws(() => form.set(name, "value", "file.txt"), TypeError);
  assert.equal(conversions, 0, "set must not convert name before overload TypeError");
  assert.equal(form.length, 0);

  // Valid overloads still convert the name.
  form.append(name, "value");
  assert.equal(conversions, 1);
  assert.equal(form.get("spy"), "value");
});

test("FormData USV conversion replaces unpaired surrogates after fast path", () => {
  const form = new FormData();
  form.append("\uD800", "lone-lead");
  form.append("tail\uD800", "lead-at-end");
  form.append("a\uDC00b", "lone-trail");
  form.append("pair\uD83D\uDE00", "valid-pair");
  form.append("ascii", "plain\uDFFF");

  assert.equal(form.get("\uFFFD"), "lone-lead");
  assert.equal(form.get("tail\uFFFD"), "lead-at-end");
  assert.equal(form.get("a\uFFFDb"), "lone-trail");
  assert.equal(form.get("pair\uD83D\uDE00"), "valid-pair");
  assert.equal(form.get("ascii"), "plain\uFFFD");

  // Lookup names are converted through the same USV path.
  assert.equal(form.get("\uD800"), "lone-lead");
  assert.equal(form.has("tail\uDBFF"), true);
  assert.deepEqual(Array.from(form.keys()), ["\uFFFD", "tail\uFFFD", "a\uFFFDb", "pair\uD83D\uDE00", "ascii"]);
});

test("FormData forEach uses value name object thisArg and observes appends", () => {
  const form = formDataFrom([["a", "1"], ["b", "2"]]);
  const thisArg = { marker: true };
  const calls = [];
  form.forEach(function(value, name, object) {
    calls.push([this, name, value, object === form]);
    if (name === "a")
      form.append("c", "3");
  }, thisArg);
  assert.equal(calls[0][0], thisArg);
  assert.deepEqual(calls.map(call => call.slice(1)), [["a", "1", true], ["b", "2", true], ["c", "3", true]]);
  assert.throws(() => form.forEach(), TypeError);
  assert.throws(() => form.forEach({}), TypeError);
});

test("FormData supports subclass new.target and native receiver brands", () => {
  class CustomFormData extends FormData {}
  const form = new CustomFormData();
  form.append("a", "1");
  assert(form instanceof CustomFormData);
  assert(form instanceof FormData);
  assert.equal(Object.getPrototypeOf(form), CustomFormData.prototype);
  assert.equal(form.get("a"), "1");

  for (const name of ["append", "delete", "get", "getAll", "has", "set", "forEach", "entries", "keys", "values", "toJSON"])
    assert.throws(() => FormData.prototype[name].call({}), TypeError);

  const iterator = form.entries();
  assert.equal(iterator[Symbol.iterator](), iterator);
  const next = Object.getPrototypeOf(iterator).next;
  assert.throws(() => next.call({}), TypeError);
});
