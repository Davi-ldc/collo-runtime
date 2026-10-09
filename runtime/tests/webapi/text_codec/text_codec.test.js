// Collo compatibility contract derived from Bun v1.3.14:
// - reference/bun-v1.3.14/test/js/web/encoding/text-encoder.test.js
// - reference/bun-v1.3.14/test/js/web/encoding/text-decoder.test.js
// - reference/bun-v1.3.14/test/js/node/test/parallel/test-whatwg-encoding-custom-*.js

function bytes(value) {
  return Array.from(value);
}

function detachArrayBuffer(buffer) {
  const transferred = structuredClone(buffer, { transfer: [buffer] });
  assert.equal(buffer.byteLength, 0);
  return transferred;
}

async function assertPromiseRejects(promise, expectedType, label) {
  let error = null;
  try {
    await promise;
  } catch (err) {
    error = err;
  }
  assert(error instanceof expectedType, `${label}: expected ${expectedType.name}, got ${error && error.name}`);
  return error;
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

describe("TextEncoder", () => {
  test("constructor, descriptors, and encoding", () => {
    assert.throws(() => TextEncoder(), TypeError);
    assertDataDescriptor(descriptor(globalThis, "TextEncoder"), TextEncoder, true, false, true, "global TextEncoder");
    assertFunctionShape(TextEncoder, "TextEncoder", 0, true);
    assertDataDescriptor(descriptor(TextEncoder, "prototype"), TextEncoder.prototype, false, false, false, "TextEncoder.prototype");
    assertDataDescriptor(descriptor(TextEncoder.prototype, "constructor"), TextEncoder, true, false, true, "TextEncoder.prototype.constructor");
    assertDataDescriptor(descriptor(TextEncoder.prototype, Symbol.toStringTag), "TextEncoder", false, false, true, "TextEncoder.prototype Symbol.toStringTag");

    const encodingDescriptor = descriptor(TextEncoder.prototype, "encoding");
    assert.equal(encodingDescriptor.set, undefined);
    assert.equal(encodingDescriptor.enumerable, true);
    assert.equal(encodingDescriptor.configurable, true);
    assertFunctionShape(encodingDescriptor.get, "get encoding", 0, false, "TextEncoder.encoding getter");
    assert.throws(() => encodingDescriptor.get.call({}), TypeError);

    const encodeDescriptor = descriptor(TextEncoder.prototype, "encode");
    assertDataDescriptor(encodeDescriptor, TextEncoder.prototype.encode, true, true, true, "TextEncoder.prototype.encode");
    assertFunctionShape(encodeDescriptor.value, "encode", 0, false, "TextEncoder.encode");
    assert.throws(() => encodeDescriptor.value.call({}), TypeError);

    const encodeIntoDescriptor = descriptor(TextEncoder.prototype, "encodeInto");
    assertDataDescriptor(encodeIntoDescriptor, TextEncoder.prototype.encodeInto, true, true, true, "TextEncoder.prototype.encodeInto");
    assertFunctionShape(encodeIntoDescriptor.value, "encodeInto", 2, false, "TextEncoder.encodeInto");
    assert.equal(Object.keys(TextEncoder.prototype).join(","), "encoding,encode,encodeInto");

    const encoder = new TextEncoder();
    assert.equal(encoder.encoding, "utf-8");
    assert.equal(Object.prototype.toString.call(encoder), "[object TextEncoder]");
    assert.equal(TextEncoder.prototype.encode.length, 0);
    assert.equal(TextEncoder.prototype.encodeInto.length, 2);
  });

  test("encode handles default, null, ascii, latin1, unicode, and lone surrogates", () => {
    const encoder = new TextEncoder();
    assert.deepEqual(bytes(encoder.encode()), []);
    assert.deepEqual(bytes(encoder.encode(undefined)), []);
    assert.deepEqual(bytes(encoder.encode(null)), [110, 117, 108, 108]);
    assert.deepEqual(bytes(encoder.encode("Hello")), [72, 101, 108, 108, 111]);
    assert.deepEqual(bytes(encoder.encode("H©世")), [72, 194, 169, 228, 184, 150]);
    assert.deepEqual(bytes(encoder.encode("\udc00")), [239, 191, 189]);
    assert.deepEqual(bytes(encoder.encode("😀")), [240, 159, 152, 128]);
  });

  test("encodeInto reports UTF-16 code units read and never splits a code point", () => {
    const encoder = new TextEncoder();
    let destination = new Uint8Array(32);
    let result = encoder.encodeInto("A©😀", destination);
    assert.deepEqual(result, { read: 4, written: 7 });
    assert.deepEqual(bytes(destination.subarray(0, result.written)), [65, 194, 169, 240, 159, 152, 128]);

    destination = new Uint8Array(5);
    result = encoder.encodeInto("Hello", destination);
    assert.deepEqual(result, { read: 5, written: 5 });
    assert.deepEqual(bytes(destination), [72, 101, 108, 108, 111]);

    destination = new Uint8Array(3);
    result = encoder.encodeInto("Hello", destination);
    assert.deepEqual(result, { read: 3, written: 3 });
    assert.deepEqual(bytes(destination), [72, 101, 108]);

    destination = new Uint8Array(2);
    result = encoder.encodeInto("€", destination);
    assert.deepEqual(result, { read: 0, written: 0 });
    assert.deepEqual(bytes(destination), [0, 0]);

    destination = new Uint8Array(3);
    result = encoder.encodeInto("\udc00", destination);
    assert.deepEqual(result, { read: 1, written: 3 });
    assert.deepEqual(bytes(destination), [239, 191, 189]);
  });

  test("encodeInto validates receiver and destination", () => {
    const encoder = new TextEncoder();
    assert.throws(() => encoder.encodeInto("x"), TypeError);
    assert.throws(() => encoder.encodeInto("x", new Uint16Array(2)), TypeError);
    assert.throws(() => TextEncoder.prototype.encode.call({}), TypeError);
  });

  test("encodeInto treats detached and out-of-bounds destinations as empty", () => {
    const encoder = new TextEncoder();
    const detached = new Uint8Array(4);
    detachArrayBuffer(detached.buffer);
    assert.deepEqual(encoder.encodeInto("abcd", detached), { read: 0, written: 0 });

    const destination = new Uint8Array(4);
    const source = {
      toString() {
        detachArrayBuffer(destination.buffer);
        return "abcd";
      },
    };
    assert.deepEqual(encoder.encodeInto(source, destination), { read: 0, written: 0 });

    if (typeof ArrayBuffer.prototype.resize === "function") {
      const buffer = new ArrayBuffer(8, { maxByteLength: 8 });
      const outOfBounds = new Uint8Array(buffer, 4, 4);
      buffer.resize(2);
      assert.deepEqual(encoder.encodeInto("abcd", outOfBounds), { read: 0, written: 0 });

      const trackingBuffer = new ArrayBuffer(4, { maxByteLength: 4 });
      const tracking = new Uint8Array(trackingBuffer);
      trackingBuffer.resize(2);
      assert.deepEqual(encoder.encodeInto("abcd", tracking), { read: 2, written: 2 });
      assert.deepEqual(bytes(tracking), [97, 98]);
    }
  });

  test("subclassing preserves TextEncoder brand", () => {
    class CustomTextEncoder extends TextEncoder {}
    const encoder = new CustomTextEncoder();
    assert(encoder instanceof CustomTextEncoder);
    assert(encoder instanceof TextEncoder);
    assert.equal(Object.getPrototypeOf(encoder), CustomTextEncoder.prototype);
    assert.deepEqual(bytes(encoder.encode("ok")), [111, 107]);
  });
});

describe("TextDecoder", () => {
  test("constructor, labels, options, and descriptors", () => {
    assert.throws(() => TextDecoder(), TypeError);
    assertDataDescriptor(descriptor(globalThis, "TextDecoder"), TextDecoder, true, false, true, "global TextDecoder");
    assertFunctionShape(TextDecoder, "TextDecoder", 0, true);
    assertDataDescriptor(descriptor(TextDecoder, "prototype"), TextDecoder.prototype, false, false, false, "TextDecoder.prototype");
    assertDataDescriptor(descriptor(TextDecoder.prototype, "constructor"), TextDecoder, true, false, true, "TextDecoder.prototype.constructor");
    assertDataDescriptor(descriptor(TextDecoder.prototype, Symbol.toStringTag), "TextDecoder", false, false, true, "TextDecoder.prototype Symbol.toStringTag");

    for (const name of ["encoding", "fatal", "ignoreBOM"]) {
      const property = descriptor(TextDecoder.prototype, name);
      assert.equal(property.set, undefined, `${name} setter`);
      assert.equal(property.enumerable, true, `${name} enumerable`);
      assert.equal(property.configurable, true, `${name} configurable`);
      assertFunctionShape(property.get, `get ${name}`, 0, false, `TextDecoder.${name} getter`);
      assert.throws(() => property.get.call({}), TypeError);
    }

    const decodeDescriptor = descriptor(TextDecoder.prototype, "decode");
    assertDataDescriptor(decodeDescriptor, TextDecoder.prototype.decode, true, true, true, "TextDecoder.prototype.decode");
    assertFunctionShape(decodeDescriptor.value, "decode", 0, false, "TextDecoder.decode");
    assert.throws(() => decodeDescriptor.value.call({}), TypeError);
    assert.equal(Object.keys(TextDecoder.prototype).join(","), "encoding,fatal,ignoreBOM,decode");

    assert.equal(new TextDecoder().encoding, "utf-8");
    assert.equal(new TextDecoder("utf8").encoding, "utf-8");
    assert.equal(new TextDecoder("  UTF-8  ").encoding, "utf-8");
    assert.equal(new TextDecoder("unicode-1-1-utf-8").encoding, "utf-8");
    assert.equal(new TextDecoder("latin1").encoding, "windows-1252");
    assert.equal(new TextDecoder("utf-16").encoding, "utf-16le");
    // Labels resolving to the replacement encoding throw per the WHATWG spec.
    assert.throws(() => new TextDecoder("replacement"), RangeError);
    assert.equal(new TextDecoder("x-user-defined").encoding, "x-user-defined");
    assert.equal(new TextDecoder("utf-8", { fatal: 1, ignoreBOM: 1 }).fatal, true);
    assert.equal(new TextDecoder("utf-8", { fatal: 0, ignoreBOM: 0 }).ignoreBOM, false);
    assert.throws(() => new TextDecoder("not-an-encoding"), RangeError);
    assert.equal(Object.prototype.toString.call(new TextDecoder()), "[object TextDecoder]");
    assert.equal(TextDecoder.prototype.decode.length, 0);
  });

  test("WHATWG labels map to canonical encoding names", () => {
    // Contract: the WHATWG Encoding spec "get an encoding" label table.
    const labels = {
      "utf-8": ["utf-8", "utf8", "unicode-1-1-utf-8", "unicode11utf8", "unicode20utf8", "x-unicode20utf8"],
      ibm866: ["ibm866", "866", "cp866", "csibm866"],
      "iso-8859-2": ["iso-8859-2", "iso8859-2", "iso88592", "iso_8859-2", "iso_8859-2:1987", "iso-ir-101", "latin2", "l2", "csisolatin2"],
      "iso-8859-3": ["iso-8859-3", "iso8859-3", "iso88593", "iso_8859-3", "iso_8859-3:1988", "latin3", "iso-ir-109", "l3", "csisolatin3"],
      "iso-8859-4": ["iso-8859-4", "iso8859-4", "iso88594", "iso_8859-4", "iso_8859-4:1988", "iso-ir-110", "latin4", "l4", "csisolatin4"],
      "iso-8859-5": ["iso-8859-5", "iso8859-5", "iso88595", "iso_8859-5", "iso_8859-5:1988", "cyrillic", "iso-ir-144", "csisolatincyrillic"],
      "iso-8859-6": ["iso-8859-6", "iso-8859-6-e", "iso-8859-6-i", "iso8859-6", "iso88596", "iso_8859-6", "iso_8859-6:1987", "arabic", "asmo-708", "csiso88596e", "csiso88596i", "csisolatinarabic", "ecma-114", "iso-ir-127"],
      "iso-8859-7": ["iso-8859-7", "iso8859-7", "iso88597", "iso_8859-7", "iso_8859-7:1987", "greek", "greek8", "iso-ir-126", "elot_928", "ecma-118", "csisolatingreek", "sun_eu_greek"],
      "iso-8859-8": ["iso-8859-8", "iso-8859-8-e", "iso8859-8", "iso88598", "iso_8859-8", "iso_8859-8:1988", "csiso88598e", "hebrew", "iso-ir-138", "csisolatinhebrew", "visual"],
      "iso-8859-8-i": ["iso-8859-8-i", "csiso88598i", "logical"],
      "iso-8859-10": ["iso-8859-10", "iso8859-10", "iso885910", "iso-ir-157", "latin6", "l6", "csisolatin6"],
      "iso-8859-13": ["iso-8859-13", "iso8859-13", "iso885913"],
      "iso-8859-14": ["iso-8859-14", "iso8859-14", "iso885914"],
      "iso-8859-15": ["iso-8859-15", "iso8859-15", "iso885915", "iso_8859-15", "csisolatin9", "l9"],
      "iso-8859-16": ["iso-8859-16"],
      "koi8-r": ["koi8-r", "koi", "koi8", "koi8_r", "cskoi8r"],
      "koi8-u": ["koi8-u", "koi8-ru"],
      "windows-874": ["windows-874", "dos-874", "iso-8859-11", "iso8859-11", "iso885911", "tis-620"],
      "windows-1250": ["windows-1250", "cp1250", "x-cp1250"],
      "windows-1251": ["windows-1251", "cp1251", "x-cp1251"],
      "windows-1252": ["windows-1252", "cp1252", "x-cp1252", "ansi_x3.4-1968", "ascii", "cp819", "csisolatin1", "ibm819", "iso-8859-1", "iso-ir-100", "iso8859-1", "iso88591", "iso_8859-1", "iso_8859-1:1987", "l1", "latin1", "us-ascii"],
      "windows-1253": ["windows-1253", "cp1253", "x-cp1253"],
      "windows-1254": ["windows-1254", "cp1254", "x-cp1254", "csisolatin5", "iso-8859-9", "iso-ir-148", "iso8859-9", "iso88599", "iso_8859-9", "iso_8859-9:1989", "l5", "latin5"],
      "windows-1255": ["windows-1255", "cp1255", "x-cp1255"],
      "windows-1256": ["windows-1256", "cp1256", "x-cp1256"],
      "windows-1257": ["windows-1257", "cp1257", "x-cp1257"],
      "windows-1258": ["windows-1258", "cp1258", "x-cp1258"],
      "utf-16be": ["utf-16be", "unicodefffe"],
      "utf-16le": ["utf-16le", "utf-16", "csunicode", "iso-10646-ucs-2", "ucs-2", "unicode", "unicodefeff"],
      "x-user-defined": ["x-user-defined"],
      big5: ["big5", "big5-hkscs", "cn-big5", "csbig5", "x-x-big5"],
      "euc-jp": ["euc-jp", "cseucpkdfmtjapanese", "x-euc-jp"],
      "iso-2022-jp": ["iso-2022-jp", "csiso2022jp"],
      shift_jis: ["shift_jis", "shift-jis", "csshiftjis", "ms932", "ms_kanji", "sjis", "windows-31j", "x-sjis"],
      "euc-kr": ["euc-kr", "cseuckr", "csksc56011987", "iso-ir-149", "korean", "ks_c_5601-1987", "ks_c_5601-1989", "ksc5601", "ksc_5601", "windows-949"],
      gbk: ["gbk", "chinese", "csgb2312", "csiso58gb231280", "gb2312", "gb_2312", "gb_2312-80", "iso-ir-58", "x-gbk"],
      gb18030: ["gb18030"],
      macintosh: ["macintosh", "mac", "csmacintosh", "x-mac-roman"],
      "x-mac-cyrillic": ["x-mac-cyrillic", "x-mac-ukrainian"],
    };

    for (const [canonical, aliases] of Object.entries(labels)) {
      for (const label of aliases) {
        assert.equal(new TextDecoder(label).encoding, canonical, label);
        assert.equal(new TextDecoder(label.toUpperCase()).encoding, canonical, `${label} uppercase`);
        assert.equal(new TextDecoder(`\t${label}\n`).encoding, canonical, `${label} whitespace`);
      }
    }

    // Labels that are not in the WHATWG Encoding registry must be rejected,
    // and labels of the replacement encoding must throw RangeError per the
    // TextDecoder constructor spec.
    const rejectedLabels = [
      "iso_8859-10",
      "iso_8859-13",
      "iso_8859-14",
      "iso-celtic",
      "iso-ir-199",
      "latin8",
      "l8",
      "latin9",
      "replacement",
      "csiso2022kr",
      "hz-gb-2312",
      "iso-2022-cn",
      "iso-2022-cn-ext",
      "iso-2022-kr",
    ];
    for (const label of rejectedLabels) {
      assert.throws(() => new TextDecoder(label), RangeError);
      assert.throws(() => new TextDecoderStream(label), RangeError);
    }

    assert.throws(() => new TextDecoder("x".repeat(1024 * 1024)), RangeError);

    // WHATWG "get an encoding" trims ASCII whitespace and imposes no length
    // limit on the label. A valid label padded with whitespace far exceeding any
    // internal byte cap must still resolve (regression guard for the removed
    // arbitrary 32-byte pre-reject in parseTextDecoderEncoding).
    const pad = " \t\n\f\r".repeat(64); // 320 whitespace bytes per side
    assert.equal(new TextDecoder(pad + "shift_jis" + pad).encoding, "shift_jis");
    assert.equal(new TextDecoder(pad + "cseucpkdfmtjapanese" + pad).encoding, "euc-jp");
    assert.equal(new TextDecoder(pad + "utf-8" + pad).encoding, "utf-8");
    // The longest spec label is "cseucpkdfmtjapanese" (19 bytes); a label whose
    // trimmed length exceeds every spec label must still be rejected by the
    // table lookup, not silently accepted.
    assert.throws(() => new TextDecoder(pad + "x".repeat(64) + pad), RangeError);
  });

  test("decode accepts ArrayBuffer and ArrayBufferView inputs", () => {
    const bytes = new TextEncoder().encode("hello π");
    const decoder = new TextDecoder();
    assert.equal(decoder.decode(bytes), "hello π");
    assert.equal(decoder.decode(bytes.buffer), "hello π");
    assert.equal(decoder.decode(new DataView(bytes.buffer, 6, 2)), "π");
    assert.equal(decoder.decode(), "");
    assert.equal(decoder.decode(bytes, { stream: false }), "hello π");
    assert.throws(() => decoder.decode(bytes, true), TypeError);
    assert.throws(() => decoder.decode(bytes, "ignored"), TypeError);
    assert.throws(() => decoder.decode([104, 105]), TypeError);
  });

  test("decode reads buffer sources after options.stream getters run", () => {
    const decoder = new TextDecoder();
    const detachedView = new Uint8Array([65, 66]);
    detachArrayBuffer(detachedView.buffer);
    assert.equal(decoder.decode(detachedView), "");

    const detachedBuffer = new Uint8Array([67, 68]).buffer;
    detachArrayBuffer(detachedBuffer);
    assert.equal(decoder.decode(detachedBuffer), "");

    const euros = new Uint8Array(300);
    for (let index = 0; index < euros.length; index += 3) {
      euros[index] = 0xe2;
      euros[index + 1] = 0x82;
      euros[index + 2] = 0xac;
    }

    let getterCount = 0;
    const detachedDuringGetter = new TextDecoder().decode(euros, {
      get stream() {
        getterCount++;
        const transferred = detachArrayBuffer(euros.buffer);
        new Uint8Array(transferred).fill(0x41);
        return false;
      },
    });
    assert.equal(getterCount, 1);
    assert.equal(euros.byteLength, 0);
    assert.equal(detachedDuringGetter, "");

    const mutable = new Uint8Array([65, 65, 65, 65]);
    const mutatedDuringGetter = new TextDecoder().decode(mutable, {
      get stream() {
        mutable.fill(66);
        return false;
      },
    });
    assert.equal(mutatedDuringGetter, "BBBB");

    if (typeof ArrayBuffer.prototype.resize === "function") {
      const direct = new ArrayBuffer(2, { maxByteLength: 4 });
      new Uint8Array(direct).set([104, 105]);
      assert.equal(new TextDecoder().decode(direct), "hi");
      direct.resize(0);
      assert.equal(new TextDecoder().decode(direct), "");

      const buffer = new ArrayBuffer(8, { maxByteLength: 8 });
      const outOfBounds = new Uint8Array(buffer, 4, 4);
      buffer.resize(2);
      assert.equal(new TextDecoder().decode(outOfBounds), "");
    }
  });

  test("decode handles BOM, replacement, fatal mode, and streaming", () => {
    assert.equal(new TextDecoder().decode(new Uint8Array([0xef, 0xbb, 0xbf, 65])), "A");
    assert.equal(new TextDecoder("utf-8", { ignoreBOM: true }).decode(new Uint8Array([0xef, 0xbb, 0xbf, 65])), "\ufeffA");
    assert.equal(new TextDecoder().decode(new Uint8Array([0xe2, 0x28])), "\ufffd(");
    assert.throws(() => new TextDecoder("utf-8", { fatal: true }).decode(new Uint8Array([0xe2, 0x28])), TypeError);

    const decoder = new TextDecoder();
    assert.equal(decoder.decode(new Uint8Array([0xe2]), { stream: true }), "");
    assert.equal(decoder.decode(new Uint8Array([0x82, 0xac])), "€");

    const incomplete = new TextDecoder();
    assert.equal(incomplete.decode(new Uint8Array([0xe2]), { stream: true }), "");
    assert.equal(incomplete.decode(), "\ufffd");

    const fatalIncomplete = new TextDecoder("utf-8", { fatal: true });
    assert.equal(fatalIncomplete.decode(new Uint8Array([0xe2]), { stream: true }), "");
    assert.throws(() => fatalIncomplete.decode(), TypeError);

    const fatalAfterStreaming = new TextDecoder("utf-8", { fatal: true });
    assert.equal(fatalAfterStreaming.decode(new Uint8Array([65]), { stream: true }), "A");
    assert.throws(() => fatalAfterStreaming.decode(new Uint8Array([0xe2, 0x28])), TypeError);
    assert.equal(fatalAfterStreaming.decode(new Uint8Array([0xef, 0xbb, 0xbf, 66])), "B");
  });

  test("streaming UTF-8 rejects boundary prefixes that are already invalid", () => {
    for (const chunk of [
      [0xe0, 0x80],
      [0xf0, 0x80],
      [0xf4, 0x90],
    ]) {
      const fatal = new TextDecoder("utf-8", { fatal: true });
      assert.throws(() => fatal.decode(new Uint8Array(chunk), { stream: true }), TypeError);
    }

    const replacement = new TextDecoder();
    assert.equal(replacement.decode(new Uint8Array([0xe0, 0x80]), { stream: true }), "\ufffd\ufffd");
    assert.equal(replacement.decode(), "");
  });

  test("streaming decode only strips BOM at the start of the decode sequence", () => {
    const decoder = new TextDecoder();
    assert.equal(decoder.decode(new Uint8Array([65]), { stream: true }), "A");
    assert.equal(decoder.decode(new Uint8Array([0xef, 0xbb, 0xbf, 66]), { stream: true }), "\ufeffB");
    assert.equal(decoder.decode(), "");

    assert.equal(decoder.decode(new Uint8Array([0xef, 0xbb, 0xbf, 67])), "C");
    assert.equal(decoder.decode(new Uint8Array([0xef]), { stream: true }), "");
    assert.equal(decoder.decode(new Uint8Array([0xbb]), { stream: true }), "");
    assert.equal(decoder.decode(new Uint8Array([0xbf, 68])), "D");
  });

  test("streaming UTF-8 byte-by-byte equals whole-buffer decode (boundary split)", () => {
    // Exercises the streaming boundary-buffer path that resolves a pending
    // incomplete multibyte prefix against the next chunk without copying the
    // whole chunk. Feeding the bytes one at a time forces a split at every
    // sequence boundary; the joined output must equal the whole-buffer decode.
    const samples = [
      "ASCII only",
      "café déjà",
      "Ωμέγα π",
      "日本語のテキスト",
      "mixed 1byte é 2byte 中 3byte 😀 4byte end",
      "﻿with BOM prefix and astral 😀😀",
      "edge: 😀", // astral at the very end
    ];
    for (const text of samples) {
      const full = new TextEncoder().encode(text);
      const whole = new TextDecoder().decode(full);

      const streamed = new TextDecoder();
      let out = "";
      for (let i = 0; i < full.length; i++) {
        out += streamed.decode(full.subarray(i, i + 1), { stream: true });
      }
      out += streamed.decode();
      assert.equal(out, whole, `byte-by-byte: ${JSON.stringify(text)}`);
    }

    // Also split at every possible 2-way boundary of a buffer containing
    // multibyte sequences, including splits in the middle of sequences.
    const buf = new TextEncoder().encode("a😀b中c");
    const expected = new TextDecoder().decode(buf);
    for (let split = 0; split <= buf.length; split++) {
      const d = new TextDecoder();
      const head = d.decode(buf.subarray(0, split), { stream: true });
      const tail = d.decode(buf.subarray(split));
      assert.equal(head + tail, expected, `2-way split at ${split}`);
    }
  });

  test("legacy single-byte encodings match Bun/WPT behavior", () => {
    assert.equal(new TextDecoder("latin1").decode(new Uint8Array([0x80, 0x81, 0x82, 0x83])), "€\u0081‚ƒ");
    assert.equal(new TextDecoder("ibm866").decode(new Uint8Array([0x8f, 0xe0, 0xa8, 0xa2, 0xa5, 0xe2])), "Привет");
    assert.equal(new TextDecoder("iso-8859-3").decode(new Uint8Array([0xa1, 0x65, 0x6c, 0x6c, 0x6f])), "Ħello");
    assert.equal(new TextDecoder("iso-8859-6").decode(new Uint8Array([0xc7])).charCodeAt(0), 0x0627);
    assert.equal(new TextDecoder("iso-8859-7").decode(new Uint8Array([0xc3, 0xe5, 0xe9, 0xdc])), "Γειά");
    assert.equal(new TextDecoder("iso-8859-8").decode(new Uint8Array([0xf9, 0xec, 0xe5, 0xed])), "שלום");
    assert.equal(new TextDecoder("iso-8859-8-i").decode(new Uint8Array([0xf9, 0xec, 0xe5, 0xed])), "שלום");
    assert.equal(new TextDecoder("windows-874").decode(new Uint8Array([0xca, 0xc7, 0xd1, 0xca, 0xb4, 0xd5])), "สวัสดี");
    assert.equal(new TextDecoder("windows-1253").decode(new Uint8Array([0xca, 0xe1, 0xeb, 0xe7, 0xec, 0xdd, 0xf1, 0xe1])), "Καλημέρα");
    assert.equal(new TextDecoder("windows-1255").decode(new Uint8Array([0xf9, 0xec, 0xe5, 0xed])), "שלום");
    assert.equal(new TextDecoder("windows-1257").decode(new Uint8Array([0x4c, 0x61, 0x62, 0x61, 0x73])), "Labas");
    assert.equal(new TextDecoder("koi8-u").decode(new Uint8Array([0xf0, 0xd2, 0xc9, 0xd7, 0xa6, 0xd4])), "Привіт");
  });

  test("CJK encodings decode Bun fixture bytes", () => {
    assert.equal(new TextDecoder("shift_jis").decode(new Uint8Array([0x82, 0xb1, 0x82, 0xf1, 0x82, 0xc9, 0x82, 0xbf, 0x82, 0xcd])), "こんにちは");
    assert.equal(new TextDecoder("euc-jp").decode(new Uint8Array([0xc6, 0xfc, 0xcb, 0xdc, 0xb8, 0xec])), "日本語");
    assert.equal(new TextDecoder("big5").decode(new Uint8Array([0xa7, 0x41, 0xa6, 0x6e])), "你好");
    assert.equal(new TextDecoder("euc-kr").decode(new Uint8Array([0xbe, 0xc8, 0xb3, 0xe7, 0xc7, 0xcf, 0xbc, 0xbc, 0xbf, 0xe4])), "안녕하세요");
    // WHATWG euc-kr covers the full UHC/windows-949 repertoire, not just the
    // KS X 1001 subset. Per the spec index-euc-kr, pointer 0 — bytes 0x81 0x41,
    // i.e. (0x81 - 0x81) * 190 + (0x41 - 0x41) — is U+AC02 HANGUL SYLLABLE GAGG
    // (갂), an extension syllable absent from KS X 1001.
    assert.equal(new TextDecoder("euc-kr").decode(new Uint8Array([0x81, 0x41])), "갂");
    assert.equal(new TextDecoder("gbk").decode(new Uint8Array([0xc4, 0xe3, 0xba, 0xc3, 0xca, 0xc0, 0xbd, 0xe7])), "你好世界");
    assert.equal(new TextDecoder("gb18030").decode(new Uint8Array([0xc4, 0xe3, 0xba, 0xc3])), "你好");
    assert.equal(new TextDecoder("iso-2022-jp").decode(new Uint8Array([0x1b, 0x24, 0x42, 0x46, 0x7c, 0x4b, 0x5c, 0x1b, 0x28, 0x42])), "日本");
  });

  test("UTF-16 and x-user-defined edge behavior", () => {
    assert.equal(new TextDecoder("utf-16").decode(new Uint8Array([0x41, 0x00])), "A");
    assert.equal(new TextDecoder("utf-16").decode(new Uint8Array([0xfe, 0xff, 0x00, 0x41])), "A");
    assert.equal(new TextDecoder("utf-16", { ignoreBOM: true }).decode(new Uint8Array([0xfe, 0xff, 0x00, 0x41])), "\ufeffA");
    assert.equal(new TextDecoder("utf-16le").decode(new Uint8Array([0xff, 0xfe, 0x61, 0x00, 0x62, 0x00])), "ab");
    assert.equal(new TextDecoder("utf-16le", { ignoreBOM: true }).decode(new Uint8Array([0xff, 0xfe, 0x61, 0x00])), "\ufeffa");
    assert.equal(new TextDecoder("utf-16be").decode(new Uint8Array([0xfe, 0xff, 0x00, 0x61, 0x00, 0x62])), "ab");
    assert.throws(() => new TextDecoder("utf-16le", { fatal: true }).decode(new Uint8Array([0x00])), TypeError);
    assert.equal(new TextDecoder("utf-16le").decode(new Uint8Array([0x00])), "\ufffd");

    // UTF-16LE fast path equivalence (regression guard for the simdutf
    // validate+memcpy fast path that bypasses ICU for valid LE input):
    // - a valid surrogate pair (astral code point) must round-trip,
    // - an unpaired surrogate must fall back to ICU and become U+FFFD (the fast
    //   path must reject it via validate_utf16le, not memcpy garbage),
    // - a larger buffer exercises the bulk memcpy,
    // - a misaligned (odd byte offset) source must decode identically.
    assert.equal(new TextDecoder("utf-16le").decode(new Uint8Array([0x3d, 0xd8, 0x00, 0xde])), "\ud83d\ude00");
    assert.equal(new TextDecoder("utf-16le").decode(new Uint8Array([0x00, 0xd8, 0x41, 0x00])), "\ufffdA");
    assert.equal(new TextDecoder("utf-16le", { fatal: true })
      .decode(new Uint8Array([0x41, 0x00])), "A");
    assert.throws(() => new TextDecoder("utf-16le", { fatal: true })
      .decode(new Uint8Array([0x00, 0xd8, 0x41, 0x00])), TypeError);
    const big = new Uint8Array(2048);
    for (let i = 0; i < big.length; i += 2) big[i] = 0x41; // "A" * 1024 in LE
    assert.equal(new TextDecoder("utf-16le").decode(big), "A".repeat(1024));
    const backing = new Uint8Array([0x00, 0x61, 0x00, 0x62, 0x00]); // misaligned payload at offset 1
    assert.equal(new TextDecoder("utf-16le").decode(new Uint8Array(backing.buffer, 1, 4)), "ab");

    const streaming = new TextDecoder("utf-16le");
    assert.equal(streaming.decode(new Uint8Array([0x61]), { stream: true }), "");
    assert.equal(streaming.decode(new Uint8Array([0x00]), { stream: true }), "a");
    assert.equal(streaming.decode(), "");

    const fatalUtf16AfterStreaming = new TextDecoder("utf-16le", { fatal: true });
    assert.equal(fatalUtf16AfterStreaming.decode(new Uint8Array([0x41, 0x00]), { stream: true }), "A");
    assert.throws(() => fatalUtf16AfterStreaming.decode(new Uint8Array([0x00])), TypeError);
    assert.equal(fatalUtf16AfterStreaming.decode(new Uint8Array([0xff, 0xfe, 0x42, 0x00])), "B");

    const sniffing = new TextDecoder("utf-16");
    assert.equal(sniffing.decode(new Uint8Array([0xfe]), { stream: true }), "");
    assert.equal(sniffing.decode(new Uint8Array([0xff, 0x00, 0x62])), "b");

    assert.equal(new TextDecoder("x-user-defined").decode(new Uint8Array([0x41, 0x80, 0x81, 0xff])), "A\uf780\uf781\uf7ff");
    // The replacement encoding is not constructible: the TextDecoder
    // constructor throws RangeError for labels resolving to it, so there is no
    // replacement decode path to exercise.
    assert.throws(() => new TextDecoder("replacement"), RangeError);
    assert.throws(() => new TextDecoder("replacement", { fatal: true }), RangeError);
  });

  test("subclassing preserves TextDecoder brand and state", () => {
    class CustomTextDecoder extends TextDecoder {}
    const decoder = new CustomTextDecoder("utf-8", { ignoreBOM: true });
    assert(decoder instanceof CustomTextDecoder);
    assert(decoder instanceof TextDecoder);
    assert.equal(Object.getPrototypeOf(decoder), CustomTextDecoder.prototype);
    assert.equal(decoder.ignoreBOM, true);
    assert.equal(decoder.decode(new Uint8Array([0xef, 0xbb, 0xbf, 65])), "\ufeffA");
  });
});

describe("Encoding streams", () => {
  test("SharedArrayBuffer is exposed without allowing synchronous Atomics.wait", () => {
    assert.equal(typeof SharedArrayBuffer, "function");
    const view = new Int32Array(new SharedArrayBuffer(4));
    assert.throws(() => Atomics.wait(view, 0, 0, 1), TypeError);
  });

  test("TextDecoderStream rejects boundary prefixes that are already invalid", async () => {
    for (const chunk of [
      [0xe0, 0x80],
      [0xf0, 0x80],
      [0xf4, 0x90],
    ]) {
      const stream = new TextDecoderStream("utf-8", { fatal: true });
      const writer = stream.writable.getWriter();
      const reader = stream.readable.getReader();
      const read = reader.read();
      await assertPromiseRejects(writer.write(new Uint8Array(chunk)), TypeError, `writer.write ${chunk}`);
      await assertPromiseRejects(read, TypeError, `reader.read ${chunk}`);
    }
  });

  test("TextDecoderStream emits replacement immediately for invalid boundary prefixes", async () => {
    const stream = new TextDecoderStream();
    const writer = stream.writable.getWriter();
    const reader = stream.readable.getReader();
    const read = reader.read();
    await writer.write(new Uint8Array([0xe0, 0x80]));
    assert.deepEqual(await read, { value: "\ufffd\ufffd", done: false });
    await writer.close();
    assert.deepEqual(await reader.read(), { value: undefined, done: true });
  });

  test("TextDecoderStream rejects oversized pending input beyond the native queue limit", async () => {
    const stream = new TextDecoderStream();
    const writer = stream.writable.getWriter();

    const writeError = await assertPromiseRejects(
      writer.write(new Uint8Array(4 * 1024 * 1024 + 1)),
      DOMException,
      "TextDecoderStream pending input limit",
    );
    assert.equal(writeError.name, "QuotaExceededError");

    const reader = stream.readable.getReader();
    const readError = await assertPromiseRejects(
      reader.closed,
      DOMException,
      "TextDecoderStream readable after input limit",
    );
    assert.equal(readError.name, "QuotaExceededError");
  });

  test("TextDecoderStream rejects oversized resizable input capacity", async () => {
    if (typeof ArrayBuffer.prototype.resize !== "function")
      return;

    const stream = new TextDecoderStream();
    const writer = stream.writable.getWriter();
    const buffer = new ArrayBuffer(1, { maxByteLength: 4 * 1024 * 1024 + 1 });
    const view = new Uint8Array(buffer);

    const writeError = await assertPromiseRejects(
      writer.write(view),
      DOMException,
      "TextDecoderStream resizable input capacity limit",
    );
    assert.equal(writeError.name, "QuotaExceededError");

    const reader = stream.readable.getReader();
    const readError = await assertPromiseRejects(
      reader.closed,
      DOMException,
      "TextDecoderStream readable after resizable input capacity limit",
    );
    assert.equal(readError.name, "QuotaExceededError");
  });

  test("TextDecoderStream charges out-of-bounds resizable input capacity", async () => {
    if (typeof ArrayBuffer.prototype.resize !== "function")
      return;

    const stream = new TextDecoderStream();
    const writer = stream.writable.getWriter();
    const buffer = new ArrayBuffer(2, { maxByteLength: 4 * 1024 * 1024 + 1 });
    const view = new Uint8Array(buffer, 1, 1);
    buffer.resize(0);

    const writeError = await assertPromiseRejects(
      writer.write(view),
      DOMException,
      "TextDecoderStream out-of-bounds resizable input capacity limit",
    );
    assert.equal(writeError.name, "QuotaExceededError");

    const reader = stream.readable.getReader();
    const readError = await assertPromiseRejects(
      reader.closed,
      DOMException,
      "TextDecoderStream readable after out-of-bounds resizable input capacity limit",
    );
    assert.equal(readError.name, "QuotaExceededError");
  });

  test("TextEncoderStream rejects oversized pending input beyond the native queue limit", async () => {
    const stream = new TextEncoderStream();
    const writer = stream.writable.getWriter();

    const writeError = await assertPromiseRejects(
      writer.write("x".repeat(2 * 1024 * 1024 + 1)),
      DOMException,
      "TextEncoderStream pending input limit",
    );
    assert.equal(writeError.name, "QuotaExceededError");

    const reader = stream.readable.getReader();
    const readError = await assertPromiseRejects(
      reader.closed,
      DOMException,
      "TextEncoderStream readable after input limit",
    );
    assert.equal(readError.name, "QuotaExceededError");
  });

  test("TextDecoderStream rejects queued output beyond the native queue limit", async () => {
    const stream = new TextDecoderStream();
    const writer = stream.writable.getWriter();
    const reader = stream.readable.getReader();

    const read = reader.read();
    await writer.write(new Uint8Array([0xe2]));
    reader.releaseLock();
    await assertPromiseRejects(read, TypeError, "TextDecoderStream released pending read");

    const writeError = await assertPromiseRejects(
      writer.write(new Uint8Array(2 * 1024 * 1024 + 1).fill(65)),
      DOMException,
      "TextDecoderStream pending output limit",
    );
    assert.equal(writeError.name, "QuotaExceededError");

    const errorReader = stream.readable.getReader();
    const readError = await assertPromiseRejects(
      errorReader.closed,
      DOMException,
      "TextDecoderStream readable after pending output limit",
    );
    assert.equal(readError.name, "QuotaExceededError");
  });

  test("TextEncoderStream rejects queued output beyond the native queue limit", async () => {
    const stream = new TextEncoderStream();
    const writer = stream.writable.getWriter();
    const reader = stream.readable.getReader();

    const read = reader.read();
    await writer.write("");
    reader.releaseLock();
    await assertPromiseRejects(read, TypeError, "TextEncoderStream released pending read");

    const writeError = await assertPromiseRejects(
      writer.write("\u0800".repeat(Math.floor((4 * 1024 * 1024) / 3) + 1)),
      DOMException,
      "TextEncoderStream pending output limit",
    );
    assert.equal(writeError.name, "QuotaExceededError");

    const errorReader = stream.readable.getReader();
    const readError = await assertPromiseRejects(
      errorReader.closed,
      DOMException,
      "TextEncoderStream readable after pending output limit",
    );
    assert.equal(readError.name, "QuotaExceededError");
  });

  test("TextDecoderStream handles resizable buffer chunks by current bounds", async () => {
    if (typeof ArrayBuffer.prototype.resize !== "function")
      return;

    const stream = new TextDecoderStream();
    const writer = stream.writable.getWriter();
    const reader = stream.readable.getReader();

    const direct = new ArrayBuffer(2, { maxByteLength: 4 });
    new Uint8Array(direct).set([65, 66]);
    const firstRead = reader.read();
    await writer.write(direct);
    assert.deepEqual(await firstRead, { value: "AB", done: false });

    const buffer = new ArrayBuffer(8, { maxByteLength: 8 });
    const outOfBounds = new Uint8Array(buffer, 4, 4);
    buffer.resize(2);
    const doneRead = reader.read();
    await writer.write(outOfBounds);
    await writer.close();
    assert.deepEqual(await doneRead, { value: undefined, done: true });
  });
});
