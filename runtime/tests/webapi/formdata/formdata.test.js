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
  assert.equal(Object.keys(FormData.prototype).join(","), "append,delete,get,getAll,has,set,entries,keys,values,forEach");

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

  // Bun's FormData.from, toJSON and length are not part of the standard and are not offered.
  assert.equal(Object.hasOwn(FormData, "from"), false);
  assert.equal("toJSON" in FormData.prototype, false);
  assert.equal("length" in FormData.prototype, false);
  assert.equal(form.length, undefined);

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

// The form body parsers, reached through Response.formData(), which keeps the Content-Type as it was given; a Blob's
// type is normalized to lowercase, boundary included.
function parseForm(body, type) {
  return new Response(body, { headers: { "content-type": type } }).formData();
}

function parseMultipart(body, boundary = "foo") {
  return parseForm(body, `multipart/form-data; boundary=${boundary}`);
}

async function assertRejectsTypeError(label, promise) {
  try {
    await promise;
  } catch (error) {
    assert(error instanceof TypeError, `${label} should reject with TypeError, got ${error?.constructor?.name}`);
    return error;
  }
  throw new Error(`${label} did not reject`);
}

async function assertRejectsQuota(label, promise) {
  try {
    await promise;
  } catch (error) {
    assert(error instanceof DOMException, `${label} should reject with DOMException, got ${error?.constructor?.name}`);
    assert.equal(error.name, "QuotaExceededError", `${label} error name`);
    return error;
  }
  throw new Error(`${label} did not reject`);
}

test("form body parsers read urlencoded and multipart bodies", async () => {
  const urlencoded = await parseForm("a=1&b=2&a=3", "application/x-www-form-urlencoded");
  assert.deepEqual(Array.from(urlencoded), [["a", "1"], ["b", "2"], ["a", "3"]]);

  const multipart = '--foo\r\nContent-Disposition: form-data; name="field"\r\n\r\nvalue\r\n--foo\r\nContent-Disposition: form-data; name="file"; filename="a.txt"\r\nContent-Type: text/plain\r\n\r\nhello\r\n--foo--\r\n';
  const parsed = await parseMultipart(multipart);
  assert.equal(parsed.get("field"), "value");
  assert.equal(parsed.get("file") instanceof File, true);
  assert.equal(parsed.get("file").name, "a.txt");
  assert.equal(parsed.get("file").type, "text/plain");
  assert.equal(await parsed.get("file").text(), "hello");

  const fromBlob = await new Blob([multipart], { type: "multipart/form-data; boundary=foo" }).formData();
  assert.equal(fromBlob.get("field"), "value");

  // A boundary parameter's value keeps its case, as the body's delimiters do.
  const mixedCase = '--FooBar\r\nContent-Disposition: form-data; name="field"\r\n\r\nvalue\r\n--FooBar--\r\n';
  assert.equal((await parseMultipart(mixedCase, "FooBar")).get("field"), "value");

  const invalidFilenameStar = '--foo\r\nContent-Disposition: form-data; name="file"; filename="plain.txt"; filename*=iso-8859-1\'\'ignored.txt\r\n\r\nhello\r\n--foo--\r\n';
  const fallback = (await parseMultipart(invalidFilenameStar)).get("file");
  assert(fallback instanceof File);
  assert.equal(fallback.name, "plain.txt");
  assert.equal(await fallback.text(), "hello");

  const invalidEscapedFilenameStar = '--foo\r\nContent-Disposition: form-data; name="file"; filename="plain.txt"; filename*=UTF-8\'\'bad%ZZ.txt\r\n\r\nhello\r\n--foo--\r\n';
  const escapedFallback = (await parseMultipart(invalidEscapedFilenameStar)).get("file");
  assert(escapedFallback instanceof File);
  assert.equal(escapedFallback.name, "plain.txt");

  const invalidUtf8FilenameStar = '--foo\r\nContent-Disposition: form-data; name="file"; filename="plain.txt"; filename*=UTF-8\'\'bad%FF.txt\r\n\r\nhello\r\n--foo--\r\n';
  const utf8Fallback = (await parseMultipart(invalidUtf8FilenameStar)).get("file");
  assert(utf8Fallback instanceof File);
  assert.equal(utf8Fallback.name, "plain.txt");

  const encoder = new TextEncoder();
  const rawInvalidFilenameStarPrefix = encoder.encode('--foo\r\nContent-Disposition: form-data; name="file"; filename="plain.txt"; filename*=UTF-8\'\'bad');
  const rawInvalidFilenameStarSuffix = encoder.encode('.txt\r\n\r\nhello\r\n--foo--\r\n');
  const rawInvalidFilenameStar = new Uint8Array(rawInvalidFilenameStarPrefix.length + 1 + rawInvalidFilenameStarSuffix.length);
  rawInvalidFilenameStar.set(rawInvalidFilenameStarPrefix);
  rawInvalidFilenameStar[rawInvalidFilenameStarPrefix.length] = 0xff;
  rawInvalidFilenameStar.set(rawInvalidFilenameStarSuffix, rawInvalidFilenameStarPrefix.length + 1);
  const rawInvalidFallback = (await parseMultipart(rawInvalidFilenameStar)).get("file");
  assert(rawInvalidFallback instanceof File);
  assert.equal(rawInvalidFallback.name, "plain.txt");

  const emptyFilenameStar = '--foo\r\nContent-Disposition: form-data; name="file"; filename="plain.txt"; filename*=UTF-8\'\'\r\n\r\nhello\r\n--foo--\r\n';
  const emptyStarFile = (await parseMultipart(emptyFilenameStar)).get("file");
  assert(emptyStarFile instanceof File);
  assert.equal(emptyStarFile.name, "");
  assert.equal(await emptyStarFile.text(), "hello");

  const onlyEmptyFilenameStar = '--foo\r\nContent-Disposition: form-data; name="file"; filename*=UTF-8\'\'\r\n\r\nhello\r\n--foo--\r\n';
  const onlyEmptyStarFile = (await parseMultipart(onlyEmptyFilenameStar)).get("file");
  assert(onlyEmptyStarFile instanceof File);
  assert.equal(onlyEmptyStarFile.name, "");

  const quotedSemicolonFilename = '--foo\r\nContent-Disposition: form-data; name="file"; filename="a;b.txt"\r\n\r\nhello\r\n--foo--\r\n';
  const semicolonFile = (await parseMultipart(quotedSemicolonFilename)).get("file");
  assert(semicolonFile instanceof File);
  assert.equal(semicolonFile.name, "a;b.txt");

  const boundaryLikeData = '--foo\r\nContent-Disposition: form-data; name="field"\r\n\r\nbefore\r\n--foo-not-a-boundary\r\nafter\r\n--foo--\r\n';
  assert.equal((await parseMultipart(boundaryLikeData)).get("field"), "before\r\n--foo-not-a-boundary\r\nafter");

  const closeBoundaryLikeData = '--foo\r\nContent-Disposition: form-data; name="field"\r\n\r\nbefore\r\n--foo--not-a-boundary\r\nafter\r\n--foo--\r\n';
  assert.equal((await parseMultipart(closeBoundaryLikeData)).get("field"), "before\r\n--foo--not-a-boundary\r\nafter");

  const internalSpaceBoundary = '--foo bar\r\nContent-Disposition: form-data; name="field"\r\n\r\nvalue\r\n--foo bar--\r\n';
  assert.equal((await parseMultipart(internalSpaceBoundary, "foo bar")).get("field"), "value");

  const paddedDelimiterBody = '--foo \t\r\nContent-Disposition: form-data; name="a"\r\n\r\none\r\n--foo\t\r\nContent-Disposition: form-data; name="b"\r\n\r\ntwo\r\n--foo-- \t\r\n';
  const paddedDelimiterForm = await parseMultipart(paddedDelimiterBody);
  assert.equal(paddedDelimiterForm.get("a"), "one");
  assert.equal(paddedDelimiterForm.get("b"), "two");
});

test("form body parsers reject malformed multipart boundaries and framing", async () => {
  const validBody = '--foo\r\nContent-Disposition: form-data; name="field"\r\n\r\nvalue\r\n--foo--\r\n';
  await assertRejectsTypeError("quote boundary", parseMultipart(validBody, '"'));
  await assertRejectsTypeError("trailing-space boundary", parseMultipart(validBody, '"foo "'));
  await assertRejectsTypeError("semicolon boundary", parseMultipart(validBody, '"foo;bar"'));
  await assertRejectsTypeError("over-long boundary", parseMultipart(validBody, "x".repeat(71)));
  // A header value may hold Latin-1 characters, which no boundary may.
  const nonAscii = await assertRejectsTypeError("non-ASCII boundary", parseMultipart(validBody, "føø"));
  assert.equal(nonAscii.message, "invalid multipart boundary");
  await assertRejectsTypeError("missing boundary", parseForm(validBody, "multipart/form-data"));
  await assertRejectsTypeError("missing final boundary", parseMultipart('--foo\r\nContent-Disposition: form-data; name="field"\r\n\r\nvalue\r\n'));
  await assertRejectsTypeError("unclosed quote boundary", parseMultipart("body", '"abc'));
  await assertRejectsTypeError("malformed filename-star", parseMultipart('--foo\r\nContent-Disposition: form-data; name="file"; filename*UTF-8\'\'x.txt\r\n\r\nx\r\n--foo--\r\n'));
  await assertRejectsTypeError("raw newline in name", parseMultipart('--foo\r\nContent-Disposition: form-data; name="bad\nname"\r\n\r\nx\r\n--foo--\r\n'));
  await assertRejectsTypeError("unterminated quoted name", parseMultipart('--foo\r\nContent-Disposition: form-data; name="field\r\n\r\nx\r\n--foo--\r\n'));
  await assertRejectsTypeError("junk after quoted name", parseMultipart('--foo\r\nContent-Disposition: form-data; name="field"junk\r\n\r\nx\r\n--foo--\r\n'));
  await assertRejectsTypeError("close-like opener", parseMultipart("--foo--not-a-boundary\r\n"));
  await assertRejectsTypeError("junk before opener", parseMultipart('junk--foo\r\nContent-Disposition: form-data; name="field"\r\n\r\nvalue\r\n--foo--\r\n'));
  await assertRejectsTypeError("not a form type", parseForm("a=1", "text/plain"));
});

// A Response refuses a body over the limit when it is built; a Blob may hold one, and its formData() refuses it before
// copying it out.
test("form body parsers reject bodies over the materialized body limit", async () => {
  const oversized = `a=${"x".repeat(4 * 1024 * 1024)}`;
  for (const type of ["application/x-www-form-urlencoded", "multipart/form-data; boundary=foo"]) {
    const error = await assertRejectsQuota(type, new Blob([oversized], { type }).formData());
    assert.equal(error.message, "form data body exceeds the body size limit");
  }
});

// One entry cap covers both encodings, and a multipart part may carry at most 32 header lines.
test("form body parsers cap entries and per-part header counts", async () => {
  let manyParts = "";
  for (let i = 0; i < 1001; i++)
    manyParts += `--foo\r\nContent-Disposition: form-data; name="p${i}"\r\n\r\n\r\n`;
  manyParts += "--foo--\r\n";
  const partsError = await assertRejectsQuota("1001 multipart parts", parseMultipart(manyParts));
  assert.equal(partsError.message, "form data entry count exceeded");

  const thousandParts = manyParts.slice(manyParts.indexOf('--foo\r\nContent-Disposition: form-data; name="p1"'));
  assert.equal((await parseMultipart(thousandParts)).getAll("p1").length, 1);

  const manyPairs = Array.from({ length: 1001 }, (_, i) => `k${i}=v`).join("&");
  const pairsError = await assertRejectsQuota("1001 urlencoded pairs", parseForm(manyPairs, "application/x-www-form-urlencoded"));
  assert.equal(pairsError.message, "form data entry count exceeded");
  const thousandPairs = await parseForm(manyPairs.slice(manyPairs.indexOf("k1=")), "application/x-www-form-urlencoded");
  assert.equal(Array.from(thousandPairs.keys()).length, 1000);

  let headers = 'Content-Disposition: form-data; name="field"\r\n';
  for (let i = 0; i < 32; i++)
    headers += `X-${i}: value\r\n`;
  const manyHeaders = `--foo\r\n${headers}\r\nvalue\r\n--foo--\r\n`;
  await assertRejectsQuota("33 header lines", parseMultipart(manyHeaders));
});

async function elapsedMs(work) {
  const start = performance.now();
  await work();
  return performance.now() - start;
}

// Just under the 4 MiB a Response body may hold, and even, so it splits into whole "a&" pairs.
const nearLimitBodyLength = 4 * 1024 * 1024 - 2;

// The urlencoded parser stops at the first pair past the cap. Parsing every pair before counting them built about two
// million pairs for a body of tiny ones, against a thousand for a body of the same size whose 1,001st pair holds nearly
// all of it. Both are refused; the first must now cost no more than a small multiple of the second, plus room for the
// timer's coarse resolution.
test("a urlencoded body far past the entry cap is refused at the cap's cost", async () => {
  const type = "application/x-www-form-urlencoded";
  const tinyPairs = "a&".repeat(nearLimitBodyLength / 2);
  const prefix = "a&".repeat(1000) + "b=";
  const onePastCap = prefix + "x".repeat(nearLimitBodyLength - prefix.length);
  const refuse = (body) => async () => {
    const error = await assertRejectsQuota("pairs past the cap", parseForm(body, type));
    assert.equal(error.message, "form data entry count exceeded");
  };
  const baseline = await elapsedMs(refuse(onePastCap));
  const flood = await elapsedMs(refuse(tinyPairs));
  assert(flood <= 4 * baseline + 20, `two million pairs took ${flood} ms against ${baseline} ms for 1,001`);
});

// The opening delimiter is checked at offset 0. A boundary of 70 dashes over a body of dashes matches itself at every
// byte, so searching the body for an opener with a valid suffix cost about 72 steps per byte, against one per byte for
// a body of the same size holding no dash. Both are refused; the first must now cost no more than a small multiple of
// the second, plus room for the timer's coarse resolution.
test("a multipart body of boundary-like bytes is refused in time linear in its length", async () => {
  const boundary = "-".repeat(70);
  const refuse = (body) => () => assertRejectsTypeError("body without an opening delimiter", parseMultipart(body, boundary));
  const baseline = await elapsedMs(refuse("x".repeat(nearLimitBodyLength)));
  const dashes = await elapsedMs(refuse("-".repeat(nearLimitBodyLength)));
  assert(dashes <= 4 * baseline + 20, `a body of dashes took ${dashes} ms against ${baseline} ms for one without`);
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
  assert.equal(Array.from(form.keys()).length, 2000);

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
  assert.equal(Array.from(form).length, 0);

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

  for (const name of ["append", "delete", "get", "getAll", "has", "set", "forEach", "entries", "keys", "values"])
    assert.throws(() => FormData.prototype[name].call({}), TypeError);

  const iterator = form.entries();
  assert.equal(iterator[Symbol.iterator](), iterator);
  const next = Object.getPrototypeOf(iterator).next;
  assert.throws(() => next.call({}), TypeError);
});
