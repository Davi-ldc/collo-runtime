/**
 * Codec repertoire + robustness gate for TextDecoder.
 *
 * Collo minimizes its embedded ICU data footprint, so a spec-required label can
 * resolve in our label table yet still fail at construction time if the ICU
 * build is missing that converter (createIcuConverter throws RangeError) or
 * decode wrong bytes. This file is the gate that catches a data-reduced ICU
 * build: it constructs a TextDecoder for EVERY WHATWG label and decodes a
 * representative sample for every encoding, asserting construction does not
 * throw and a known-good sample round-trips.
 *
 * It also exercises malformed multi-byte sequences for the legacy CJK encodings
 * to document where ICU's SUBSTITUTE callback may diverge from the WHATWG
 * "maximal subpart" U+FFFD count (finding #2).
 *
 * Spec: https://encoding.spec.whatwg.org/
 * Labels: https://encoding.spec.whatwg.org/#names-and-labels
 */

import { describe, expect, test } from "collo:test";

const FFFD = "�";

// Every WHATWG label, grouped by its canonical encoding name. Mirrors the
// textDecoderLabels table in text_codec.cpp. "replacement" labels are tested
// separately (they must throw).
const labelsByEncoding = {
  "utf-8": ["utf-8", "utf8", "unicode-1-1-utf-8", "unicode11utf8", "unicode20utf8", "x-unicode20utf8"],
  "ibm866": ["866", "cp866", "csibm866", "ibm866"],
  "iso-8859-2": ["csisolatin2", "iso-8859-2", "iso-ir-101", "iso8859-2", "iso88592", "iso_8859-2", "iso_8859-2:1987", "l2", "latin2"],
  "iso-8859-3": ["csisolatin3", "iso-8859-3", "iso-ir-109", "iso8859-3", "iso88593", "iso_8859-3", "iso_8859-3:1988", "l3", "latin3"],
  "iso-8859-4": ["csisolatin4", "iso-8859-4", "iso-ir-110", "iso8859-4", "iso88594", "iso_8859-4", "iso_8859-4:1988", "l4", "latin4"],
  "iso-8859-5": ["csisolatincyrillic", "cyrillic", "iso-8859-5", "iso-ir-144", "iso8859-5", "iso88595", "iso_8859-5", "iso_8859-5:1988"],
  "iso-8859-6": ["arabic", "asmo-708", "csiso88596e", "csiso88596i", "csisolatinarabic", "ecma-114", "iso-8859-6", "iso-8859-6-e", "iso-8859-6-i", "iso-ir-127", "iso8859-6", "iso88596", "iso_8859-6", "iso_8859-6:1987"],
  "iso-8859-7": ["csisolatingreek", "ecma-118", "elot_928", "greek", "greek8", "iso-8859-7", "iso-ir-126", "iso8859-7", "iso88597", "iso_8859-7", "iso_8859-7:1987", "sun_eu_greek"],
  "iso-8859-8": ["csiso88598e", "csisolatinhebrew", "hebrew", "iso-8859-8", "iso-8859-8-e", "iso-ir-138", "iso8859-8", "iso88598", "iso_8859-8", "iso_8859-8:1988", "visual"],
  "iso-8859-8-i": ["csiso88598i", "iso-8859-8-i", "logical"],
  "iso-8859-10": ["csisolatin6", "iso-8859-10", "iso-ir-157", "iso8859-10", "iso885910", "l6", "latin6"],
  "iso-8859-13": ["iso-8859-13", "iso8859-13", "iso885913"],
  "iso-8859-14": ["iso-8859-14", "iso8859-14", "iso885914"],
  "iso-8859-15": ["csisolatin9", "iso-8859-15", "iso8859-15", "iso885915", "iso_8859-15", "l9"],
  "iso-8859-16": ["iso-8859-16"],
  "koi8-r": ["cskoi8r", "koi", "koi8", "koi8-r", "koi8_r"],
  "koi8-u": ["koi8-ru", "koi8-u"],
  "windows-874": ["dos-874", "iso-8859-11", "iso8859-11", "iso885911", "tis-620", "windows-874"],
  "windows-1250": ["cp1250", "windows-1250", "x-cp1250"],
  "windows-1251": ["cp1251", "windows-1251", "x-cp1251"],
  "windows-1252": ["ansi_x3.4-1968", "ascii", "cp1252", "cp819", "csisolatin1", "ibm819", "iso-8859-1", "iso-ir-100", "iso8859-1", "iso88591", "iso_8859-1", "iso_8859-1:1987", "l1", "latin1", "us-ascii", "windows-1252", "x-cp1252"],
  "windows-1253": ["cp1253", "windows-1253", "x-cp1253"],
  "windows-1254": ["cp1254", "csisolatin5", "iso-8859-9", "iso-ir-148", "iso8859-9", "iso88599", "iso_8859-9", "iso_8859-9:1989", "l5", "latin5", "windows-1254", "x-cp1254"],
  "windows-1255": ["cp1255", "windows-1255", "x-cp1255"],
  "windows-1256": ["cp1256", "windows-1256", "x-cp1256"],
  "windows-1257": ["cp1257", "windows-1257", "x-cp1257"],
  "windows-1258": ["cp1258", "windows-1258", "x-cp1258"],
  "macintosh": ["csmacintosh", "mac", "macintosh", "x-mac-roman"],
  "x-mac-cyrillic": ["x-mac-cyrillic", "x-mac-ukrainian"],
  "gbk": ["chinese", "csgb2312", "csiso58gb231280", "gb2312", "gb_2312", "gb_2312-80", "gbk", "iso-ir-58", "x-gbk"],
  "gb18030": ["gb18030"],
  "big5": ["big5", "big5-hkscs", "cn-big5", "csbig5", "x-x-big5"],
  "euc-jp": ["cseucpkdfmtjapanese", "euc-jp", "x-euc-jp"],
  "iso-2022-jp": ["csiso2022jp", "iso-2022-jp"],
  "shift_jis": ["csshiftjis", "ms932", "ms_kanji", "shift-jis", "shift_jis", "sjis", "windows-31j", "x-sjis"],
  "euc-kr": ["cseuckr", "csksc56011987", "euc-kr", "iso-ir-149", "korean", "ks_c_5601-1987", "ks_c_5601-1989", "ksc5601", "ksc_5601", "windows-949"],
  "utf-16be": ["unicodefffe", "utf-16be"],
  "utf-16le": ["csunicode", "iso-10646-ucs-2", "ucs-2", "unicode", "unicodefeff", "utf-16", "utf-16le"],
  "x-user-defined": ["x-user-defined"],
};

// A representative byte sample for each canonical encoding and the string it
// must decode to. These bytes are valid in the target encoding and exercise the
// non-ASCII repertoire, so they fail loudly if the embedded ICU build lacks the
// converter or its data.
const decodeSamples = {
  "utf-8": { bytes: [0xc3, 0xa9], text: "é" }, // é
  "ibm866": { bytes: [0x8f, 0xe0, 0xa8, 0xa2, 0xa5, 0xe2], text: "Привет" }, // Привет
  "iso-8859-2": { bytes: [0xe8], text: "č" },
  "iso-8859-3": { bytes: [0xa1, 0x65, 0x6c, 0x6c, 0x6f], text: "Ħello" },
  "iso-8859-4": { bytes: [0xe0], text: "ā" },
  "iso-8859-5": { bytes: [0xc0], text: "а" },
  "iso-8859-6": { bytes: [0xc7], text: "ا" },
  "iso-8859-7": { bytes: [0xc3, 0xe5, 0xe9, 0xdc], text: "Γειά" }, // Γειά
  "iso-8859-8": { bytes: [0xf9, 0xec, 0xe5, 0xed], text: "שלום" }, // שלום
  "iso-8859-8-i": { bytes: [0xf9, 0xec, 0xe5, 0xed], text: "שלום" },
  "iso-8859-10": { bytes: [0xc0], text: "Ā" },
  "iso-8859-13": { bytes: [0xc0], text: "Ą" },
  "iso-8859-14": { bytes: [0xa1], text: "Ḃ" },
  "iso-8859-15": { bytes: [0xa4], text: "€" }, // €
  "iso-8859-16": { bytes: [0xa4], text: "€" }, // custom table, no ICU
  "koi8-r": { bytes: [0xc1], text: "а" },
  "koi8-u": { bytes: [0xf0, 0xd2, 0xc9, 0xd7, 0xa6, 0xd4], text: "Привіт" }, // Привіт
  "windows-874": { bytes: [0xca, 0xc7, 0xd1, 0xca, 0xb4, 0xd5], text: "สวัสดี" }, // สวัสดี
  "windows-1250": { bytes: [0xe8], text: "č" },
  "windows-1251": { bytes: [0xcf, 0xf0, 0xe8, 0xe2, 0xe5, 0xf2], text: "Привет" }, // Привет
  "windows-1252": { bytes: [0x80], text: "€" }, // €
  "windows-1253": { bytes: [0xca, 0xe1, 0xeb, 0xe7, 0xec, 0xdd, 0xf1, 0xe1], text: "Καλημέρα" }, // Καλημέρα
  "windows-1254": { bytes: [0xfe], text: "þ" },
  "windows-1255": { bytes: [0xf9, 0xec, 0xe5, 0xed], text: "שלום" }, // שלום
  "windows-1256": { bytes: [0xc7, 0xe1, 0xd3, 0xe1, 0xc7, 0xe3], text: "السلام" }, // السلام
  "windows-1257": { bytes: [0xe0], text: "ą" },
  "windows-1258": { bytes: [0xe2], text: "â" },
  "macintosh": { bytes: [0x80], text: "Ä" },
  "x-mac-cyrillic": { bytes: [0x80], text: "А" },
  "gbk": { bytes: [0xc4, 0xe3, 0xba, 0xc3, 0xca, 0xc0, 0xbd, 0xe7], text: "你好世界" }, // 你好世界
  "gb18030": { bytes: [0xc4, 0xe3, 0xba, 0xc3], text: "你好" }, // 你好
  "big5": { bytes: [0xa7, 0x41, 0xa6, 0x6e], text: "你好" }, // 你好
  "euc-jp": { bytes: [0xc6, 0xfc, 0xcb, 0xdc, 0xb8, 0xec], text: "日本語" }, // 日本語
  "iso-2022-jp": {
    bytes: [0x1b, 0x24, 0x42, 0x46, 0x7c, 0x4b, 0x5c, 0x1b, 0x28, 0x42],
    text: "日本", // 日本
  },
  "shift_jis": { bytes: [0x82, 0xb1, 0x82, 0xf1, 0x82, 0xc9, 0x82, 0xbf, 0x82, 0xcd], text: "こんにちは" }, // こんにちは
  "euc-kr": { bytes: [0xbe, 0xc8, 0xb3, 0xe7, 0xc7, 0xcf, 0xbc, 0xbc, 0xbf, 0xe4], text: "안녕하세요" }, // 안녕하세요
  "utf-16be": { bytes: [0x30, 0x53, 0x30, 0x93], text: "こん" }, // こん
  "utf-16le": { bytes: [0x53, 0x30, 0x93, 0x30], text: "こん" },
  "x-user-defined": { bytes: [0x41, 0x80, 0xff], text: "A" },
};

describe("repertoire: every spec label constructs and round-trips", () => {
  for (const [canonical, labels] of Object.entries(labelsByEncoding)) {
    describe(canonical, () => {
      for (const label of labels) {
        test(`construct '${label}'`, () => {
          // The TextDecoder constructor opens the ICU converter eagerly, so a
          // missing converter in a data-reduced ICU build throws here.
          let decoder;
          expect(() => {
            decoder = new TextDecoder(label);
          }).not.toThrow();
          expect(decoder.encoding).toBe(canonical);
        });
      }

      const sample = decodeSamples[canonical];
      test("decode sample bytes", () => {
        const decoder = new TextDecoder(canonical);
        const result = decoder.decode(new Uint8Array(sample.bytes));
        expect(result).toBe(sample.text);
      });
    });
  }
});

describe("repertoire: replacement labels throw RangeError", () => {
  const replacementLabels = ["csiso2022kr", "hz-gb-2312", "iso-2022-cn", "iso-2022-cn-ext", "iso-2022-kr", "replacement"];
  for (const label of replacementLabels) {
    test(`'${label}'`, () => {
      expect(() => new TextDecoder(label)).toThrow(RangeError);
    });
  }
});

// Malformed-sequence tests for the legacy CJK encodings.
//
// The EXACT number of U+FFFD that WHATWG's "maximal subpart" algorithm emits
// for a malformed multi-byte sequence can differ from ICU's SUBSTITUTE callback
// (this is finding #2: we decode CJK via ICU). Because this gate cannot execute
// the real ICU build to confirm a byte-exact count, the multi-byte cases below
// assert only the spec-certain, ICU-vs-WHATWG-invariant properties:
//   - a malformed sequence in non-fatal mode does NOT throw and yields at least
//     one U+FFFD;
//   - the same sequence in fatal mode throws.
// The "lone trailing lead byte at end of stream" cases ARE unambiguous (every
// WHATWG CJK decoder emits exactly one U+FFFD on flush), so those pin the count
// exactly. If a future change adds a custom UConverterToUCallback that matches
// WHATWG maximal-subpart, tighten the multi-byte cases to exact strings.
//
//   https://encoding.spec.whatwg.org/#shift_jis-decoder
//   https://encoding.spec.whatwg.org/#euc-jp-decoder
//   https://encoding.spec.whatwg.org/#gbk-decoder
const countFFFD = (s) => [...s].filter((c) => c === FFFD).length;

describe("CJK malformed sequences", () => {
  // [encoding, malformed two-byte sequence] where the bytes cannot form a valid
  // character under the WHATWG decoder for that encoding.
  const malformed = {
    "shift_jis": [0x80, 0x80], // 0x80 is not a Shift_JIS lead byte.
    "euc-jp": [0x8e, 0xff], // 0x8E (JIS X 0201 prefix) + invalid follower.
    "gbk": [0x81, 0x7f], // 0x81 lead + 0x7F below the valid trail range.
    "big5": [0x81, 0x20], // 0x81 lead + space (invalid trail).
    "euc-kr": [0x81, 0x20], // 0x81 lead + space (invalid trail).
  };

  for (const [encoding, bytes] of Object.entries(malformed)) {
    describe(encoding, () => {
      test("non-fatal: does not throw and emits at least one U+FFFD", () => {
        const decoder = new TextDecoder(encoding);
        let result;
        expect(() => {
          result = decoder.decode(new Uint8Array(bytes));
        }).not.toThrow();
        expect(countFFFD(result)).toBeGreaterThan(0);
      });

      test("fatal: throws on the malformed sequence", () => {
        const decoder = new TextDecoder(encoding, { fatal: true });
        expect(() => decoder.decode(new Uint8Array(bytes))).toThrow();
      });
    });
  }

  // A lone trailing lead byte at end of stream is exactly one U+FFFD in every
  // WHATWG CJK decoder, so the count is pinned here regardless of ICU behavior.
  const loneLead = {
    "shift_jis": [0x82],
    "euc-jp": [0xa1],
    "gbk": [0x81],
    "big5": [0xa1],
    "euc-kr": [0xa1],
  };
  for (const [encoding, bytes] of Object.entries(loneLead)) {
    test(`${encoding}: lone trailing lead byte -> exactly one U+FFFD`, () => {
      const decoder = new TextDecoder(encoding);
      expect(decoder.decode(new Uint8Array(bytes))).toBe(FFFD);
    });
  }
});
