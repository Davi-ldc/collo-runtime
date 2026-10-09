// Collo compatibility contract derived from Bun v1.3.14:
// - reference/bun-v1.3.14/test/js/web/web-globals.test.js
// - reference/bun-v1.3.14/test/js/web/crypto/web-crypto.test.ts
// - reference/bun-v1.3.14/test/js/web/crypto/web-crypto-sha3.test.ts

function expectDOMException(fn, name) {
  const error = assert.throws(fn);
  assert(error instanceof DOMException, `${name} should throw DOMException`);
  assert.equal(error.name, name);
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

function bytesOf(view) {
  return new Uint8Array(view.buffer, view.byteOffset, view.byteLength);
}

function hex(buffer) {
  return Array.from(new Uint8Array(buffer), byte => byte.toString(16).padStart(2, "0")).join("");
}

function fromHex(string) {
  return Uint8Array.from(string.match(/../g) ?? [], byte => Number.parseInt(byte, 16));
}

function base64Url(bytes) {
  let binary = "";
  for (const byte of bytes)
    binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

async function expectRejectsName(promise, name) {
  try {
    await promise;
  } catch (error) {
    assert.equal(error.name, name);
    return error;
  }
  throw new Error(`promise should reject with ${name}`);
}

describe("crypto", () => {
  test("globals and descriptors", () => {
    assert.equal(typeof crypto, "object");
    assert.equal(typeof Crypto, "function");
    assert.equal(typeof SubtleCrypto, "function");
    assert.equal(typeof CryptoKey, "function");
    assert(crypto instanceof Crypto, "global crypto should be a Crypto");
    assert(crypto.subtle instanceof SubtleCrypto, "crypto.subtle should be a SubtleCrypto");
    assert.equal(Object.prototype.toString.call(crypto), "[object Crypto]");
    assert.equal(Object.prototype.toString.call(crypto.subtle), "[object SubtleCrypto]");
    assert.equal(Crypto.length, 0);
    assert.equal(SubtleCrypto.length, 0);
    assert.equal(CryptoKey.length, 0);
    assert.equal(crypto.getRandomValues.length, 1);
    assert.equal(crypto.randomUUID.length, 0);
    assert.equal(crypto.timingSafeEqual.length, 2);
    assert.equal(crypto.subtle.digest.length, 2);
    assert.equal(crypto.subtle.importKey.length, 5);
    assert.equal(crypto.subtle.sign.length, 3);
    assert.equal(crypto.subtle.verify.length, 4);
    assert.equal(crypto.subtle.deriveKey.length, 5);
    assert.equal(crypto.subtle.deriveBits.length, 3);
    assert.equal(crypto.subtle.wrapKey.length, 4);
    assert.equal(crypto.subtle.unwrapKey.length, 7);

    assertDataDescriptor(descriptor(globalThis, "crypto"), crypto, false, false, true, "global crypto");
    assertDataDescriptor(descriptor(globalThis, "Crypto"), Crypto, true, false, true, "global Crypto");
    assertDataDescriptor(descriptor(globalThis, "SubtleCrypto"), SubtleCrypto, true, false, true, "global SubtleCrypto");
    assertDataDescriptor(descriptor(globalThis, "CryptoKey"), CryptoKey, true, false, true, "global CryptoKey");
    assertFunctionShape(Crypto, "Crypto", 0, true);
    assertFunctionShape(SubtleCrypto, "SubtleCrypto", 0, true);
    assertFunctionShape(CryptoKey, "CryptoKey", 0, true);
    assertDataDescriptor(descriptor(Crypto, "prototype"), Crypto.prototype, false, false, false, "Crypto.prototype");
    assertDataDescriptor(descriptor(SubtleCrypto, "prototype"), SubtleCrypto.prototype, false, false, false, "SubtleCrypto.prototype");
    assertDataDescriptor(descriptor(CryptoKey, "prototype"), CryptoKey.prototype, false, false, false, "CryptoKey.prototype");
    assertDataDescriptor(descriptor(Crypto.prototype, "constructor"), Crypto, true, false, true, "Crypto.prototype.constructor");
    assertDataDescriptor(descriptor(SubtleCrypto.prototype, "constructor"), SubtleCrypto, true, false, true, "SubtleCrypto.prototype.constructor");
    assertDataDescriptor(descriptor(CryptoKey.prototype, "constructor"), CryptoKey, true, false, true, "CryptoKey.prototype.constructor");
    assertDataDescriptor(descriptor(Crypto.prototype, Symbol.toStringTag), "Crypto", false, false, true, "Crypto.prototype Symbol.toStringTag");
    assertDataDescriptor(descriptor(SubtleCrypto.prototype, Symbol.toStringTag), "SubtleCrypto", false, false, true, "SubtleCrypto.prototype Symbol.toStringTag");
    assertDataDescriptor(descriptor(CryptoKey.prototype, Symbol.toStringTag), "CryptoKey", false, false, true, "CryptoKey.prototype Symbol.toStringTag");

    assertDataDescriptor(descriptor(crypto, "subtle"), crypto.subtle, false, true, false, "crypto.subtle");
    assert.equal(Object.keys(Crypto.prototype).join(","), "getRandomValues,randomUUID,timingSafeEqual");
    assert.equal(Object.keys(SubtleCrypto.prototype).join(","), "encrypt,decrypt,sign,verify,digest,generateKey,deriveKey,deriveBits,importKey,exportKey,wrapKey,unwrapKey");
    assert.equal(Object.keys(CryptoKey.prototype).join(","), "algorithm,extractable,type,usages");

    for (const [name, length] of [["getRandomValues", 1], ["randomUUID", 0], ["timingSafeEqual", 2]]) {
      const property = descriptor(Crypto.prototype, name);
      assertDataDescriptor(property, Crypto.prototype[name], true, true, true, `Crypto.prototype.${name}`);
      assertFunctionShape(property.value, name, length, false, `Crypto.${name}`);
    }

    for (const [name, length] of [
      ["encrypt", 3],
      ["decrypt", 3],
      ["sign", 3],
      ["verify", 4],
      ["digest", 2],
      ["generateKey", 3],
      ["deriveKey", 5],
      ["deriveBits", 3],
      ["importKey", 5],
      ["exportKey", 2],
      ["wrapKey", 4],
      ["unwrapKey", 7],
    ]) {
      const property = descriptor(SubtleCrypto.prototype, name);
      assertDataDescriptor(property, SubtleCrypto.prototype[name], true, true, true, `SubtleCrypto.prototype.${name}`);
      assertFunctionShape(property.value, name, length, false, `SubtleCrypto.${name}`);
    }

    for (const name of ["algorithm", "extractable", "type", "usages"]) {
      const property = descriptor(CryptoKey.prototype, name);
      assert.equal(property.set, undefined, `${name} setter`);
      assert.equal(property.enumerable, true, `${name} enumerable`);
      assert.equal(property.configurable, true, `${name} configurable`);
      assertFunctionShape(property.get, `get ${name}`, 0, false, `CryptoKey.${name} getter`);
      assert.throws(() => property.get.call({}), TypeError);
    }

    assert.throws(() => Crypto(), TypeError);
    assert.throws(() => new Crypto(), TypeError);
    assert.throws(() => SubtleCrypto(), TypeError);
    assert.throws(() => new SubtleCrypto(), TypeError);
    assert.throws(() => CryptoKey(), TypeError);
    assert.throws(() => new CryptoKey(), TypeError);
  });

  test("getRandomValues fills integer typed arrays and returns the same object", () => {
    const constructors = [
      Int8Array,
      Uint8Array,
      Uint8ClampedArray,
      Int16Array,
      Uint16Array,
      Int32Array,
      Uint32Array,
      BigInt64Array,
      BigUint64Array,
    ];

    for (const Constructor of constructors) {
      const array = new Constructor(64);
      const returned = crypto.getRandomValues(array);
      assert.equal(returned, array, `${Constructor.name} should be returned`);
      const bytes = bytesOf(array);
      assert(bytes.some(byte => byte !== 0), `${Constructor.name} should receive random bytes`);
    }

    const empty = new Uint8Array(0);
    assert.equal(crypto.getRandomValues(empty), empty);
  });

  test("getRandomValues accepts extra arguments without changing return value", () => {
    const array = new Uint8Array(32);
    assert.equal(crypto.getRandomValues(array, "ignored"), array);
    assert(bytesOf(array).some(byte => byte !== 0));
  });

  test("getRandomValues rejects non-integer views and non-views", () => {
    for (const value of [
      undefined,
      null,
      {},
      [],
      new ArrayBuffer(8),
      new DataView(new ArrayBuffer(8)),
      new Float32Array(8),
      new Float64Array(8),
    ]) {
      expectDOMException(() => crypto.getRandomValues(value), "TypeMismatchError");
    }

    if (typeof Float16Array === "function")
      expectDOMException(() => crypto.getRandomValues(new Float16Array(8)), "TypeMismatchError");
  });

  test("getRandomValues enforces the 65536 byte quota", () => {
    crypto.getRandomValues(new Uint8Array(65536));
    expectDOMException(() => crypto.getRandomValues(new Uint8Array(65537)), "QuotaExceededError");
    expectDOMException(() => crypto.getRandomValues(new Uint32Array(16385)), "QuotaExceededError");
  });

  test("getRandomValues enforces Crypto receiver brand", () => {
    const getRandomValues = crypto.getRandomValues;
    assert.throws(() => getRandomValues(new Uint8Array(1)), TypeError);
    assert.throws(() => crypto.getRandomValues.call({}, new Uint8Array(1)), TypeError);
  });

  test("randomUUID returns valid lowercase UUID v4 strings", () => {
    const seen = new Set();
    for (let i = 0; i < 256; i++) {
      const uuid = crypto.randomUUID();
      assert.equal(typeof uuid, "string");
      assert.equal(uuid.length, 36);
      assert(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(uuid), uuid);
      seen.add(uuid);
    }
    assert.equal(seen.size, 256, "UUIDs should not repeat in a small sample");
  });

  test("randomUUID ignores arguments and enforces Crypto receiver brand", () => {
    const uuidV4 = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
    for (const args of [
      ["ignored"],
      [{}],
      [{ disableEntropyCache: true }],
      [{ disableEntropyCache: false }],
      [{ disableEntropyCache: "ignored" }],
      [null],
      [42],
    ]) {
      const uuid = crypto.randomUUID(...args);
      assert.equal(typeof uuid, "string");
      assert.equal(uuid.length, 36);
      assert(uuidV4.test(uuid), `randomUUID(${args.map(String).join(",")}) returned ${uuid}`);
    }

    const randomUUID = crypto.randomUUID;
    assert.throws(() => randomUUID(), TypeError);
    assert.throws(() => crypto.randomUUID.call({}), TypeError);
  });

  test("timingSafeEqual compares BufferSource bytes", () => {
    assert.equal(crypto.timingSafeEqual(new Uint8Array([1, 2, 3]), new Uint8Array([1, 2, 3])), true);
    assert.equal(crypto.timingSafeEqual(new Uint8Array([1, 2, 3]), new Uint8Array([1, 2, 4])), false);
    assert.equal(crypto.timingSafeEqual(new ArrayBuffer(2), new Uint8Array([0, 0])), true);
    assert.equal(crypto.timingSafeEqual(new DataView(new Uint8Array([7, 8]).buffer), new Uint8Array([7, 8])), true);

    assert.throws(() => crypto.timingSafeEqual(new Uint8Array([1]), new Uint8Array([1, 2])), RangeError);
    assert.throws(() => crypto.timingSafeEqual([1], new Uint8Array([1])), TypeError);
    assert.throws(() => crypto.timingSafeEqual(new Uint8Array([1]), [1]), TypeError);
    const timingSafeEqual = crypto.timingSafeEqual;
    assert.throws(() => timingSafeEqual(new Uint8Array(1), new Uint8Array(1)), TypeError);
    assert.throws(() => crypto.timingSafeEqual.call({}, new Uint8Array(1), new Uint8Array(1)), TypeError);
  });

  test("subtle.digest implements SHA algorithms and BufferSource views", async () => {
    const bytes = new TextEncoder().encode("hello");
    assert.equal(hex(await crypto.subtle.digest("SHA-1", bytes)), "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d");
    assert.equal(hex(await crypto.subtle.digest("SHA-224", bytes)), "ea09ae9cc6768c50fcee903ed054556e5bfc8347907f12598aa24193");
    assert.equal(hex(await crypto.subtle.digest("sha-256", bytes)), "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824");
    assert.equal(hex(await crypto.subtle.digest({ name: "SHA-384" }, bytes)), "59e1748777448c69de6b800d7a33bbfb9ff1b463e44354c3553bcdb9c666fa90125a3c79f90397bdf5f6a13de828684f");
    assert.equal(hex(await crypto.subtle.digest("SHA-512", bytes.buffer)), "9b71d224bd62f3785d96d46ad3ea3d73319bfbc2890caadae2dff72519673ca72323c3d99ba5c11d7c7acc6e14b8c5da0c4663475c2e5c3adef46f73bcdec043");

    const padded = new Uint8Array([0, 1, 2, 3, 4, 5, 6]);
    assert.equal(hex(await crypto.subtle.digest("SHA-256", new DataView(padded.buffer, 2, 3))), "1f528ffd2895634c176537c055daa5c0971b7915519999337a0e355410d8fd98");
  });

  test("subtle.digest implements Bun SHA-3 vectors", async () => {
    const vectors = [
      ["SHA3-224", "", "6b4e03423667dbb73b6e15454f0eb1abd4597f9a1b078e3f5b5a6bc7"],
      ["SHA3-224", "abc", "e642824c3f8cf24ad09234ee7d3c766fc9a3a5168d0c94ad73b46fdf"],
      ["SHA3-256", "", "a7ffc6f8bf1ed76651c14756a061d662f580ff4de43b49fa82d80a4b80f8434a"],
      ["SHA3-256", "abc", "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532"],
      ["SHA3-384", "", "0c63a75b845e4f7d01107d852e4c2485c51a50aaaa94fc61995e71bbee983a2ac3713831264adb47fb6bd1e058d5f004"],
      ["SHA3-384", "abc", "ec01498288516fc926459f58e2c6ad8df9b473cb0fc08c2596da7cf0e49be4b298d88cea927ac7f539f1edf228376d25"],
      ["SHA3-512", "", "a69f73cca23a9ac5c8b567dc185a756e97c982164fe25859e0d1dcc1475c80a615b2123af1f5f94c11e3e9402c3ac558f500199d95b6d3e301758586281dcd26"],
      ["SHA3-512", "abc", "b751850b1a57168a5693cd924b6b096e08f621827444f70d884f5d0240d2712e10e116e9192af3c91a7ec57647e3934057340b4cf408d5a56592f8274eec53f0"],
    ];

    for (const [algorithm, input, expected] of vectors) {
      const digest = await crypto.subtle.digest(algorithm, new TextEncoder().encode(input));
      assert.equal(hex(digest), expected, `${algorithm}(${JSON.stringify(input)})`);
    }

    const large = new Uint8Array(1_000_000).fill(0x61);
    assert.equal(hex(await crypto.subtle.digest("SHA3-224", large)), "d69335b93325192e516a912e6d19a15cb51c6ed5c15243e7a7fd653c");
    assert.equal(hex(await crypto.subtle.digest("SHA3-256", large)), "5c8875ae474a3634ba4fd55ec85bffd661f32aca75c6d699d0cdcb6c115891c1");
    await expectRejectsName(crypto.subtle.digest("SHA3-1024", new Uint8Array()), "NotSupportedError");
  });

  test("subtle.digest returns rejected promises for WebCrypto errors", async () => {
    await expectRejectsName(crypto.subtle.digest(), "TypeError");
    await expectRejectsName(crypto.subtle.digest("SHA-256"), "TypeError");
    await expectRejectsName(crypto.subtle.digest("SHA-999", new Uint8Array()), "NotSupportedError");
    await expectRejectsName(crypto.subtle.digest("SHA-256", {}), "TypeError");

    const digest = crypto.subtle.digest;
    await expectRejectsName(digest("SHA-256", new Uint8Array()), "TypeError");
    await expectRejectsName(crypto.subtle.digest({ get name() { throw new DOMException("boom", "DataError"); } }, new Uint8Array()), "DataError");
  });

  test("subtle HMAC raw import, generate, sign, verify, and export", async () => {
    const keyData = new TextEncoder().encode("key");
    const data = new TextEncoder().encode("The quick brown fox jumps over the lazy dog");
    const key = await crypto.subtle.importKey("raw", keyData, { name: "HMAC", hash: "SHA-256" }, true, ["verify", "sign", "sign"]);

    assert(key instanceof CryptoKey);
    assert.equal(Object.prototype.toString.call(key), "[object CryptoKey]");
    assert.equal(key.type, "secret");
    assert.equal(key.extractable, true);
    assert.deepEqual(key.usages, ["sign", "verify"]);
    assert.deepEqual(key.algorithm, { name: "HMAC", hash: { name: "SHA-256" }, length: 24 });

    const signature = await crypto.subtle.sign("HMAC", key, data);
    assert.equal(hex(signature), "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8");
    assert.equal(await crypto.subtle.verify("HMAC", key, signature, data), true);
    assert.equal(await crypto.subtle.verify("HMAC", key, new Uint8Array(signature), new Uint8Array([1, 2, 3])), false);
    assert.equal(await crypto.subtle.verify("HMAC", key, new Uint8Array(signature).subarray(0, 31), data), false);
    const longSignature = new Uint8Array(signature.byteLength + 1);
    longSignature.set(new Uint8Array(signature));
    assert.equal(await crypto.subtle.verify("HMAC", key, longSignature, data), false);
    assert.deepEqual(Array.from(new Uint8Array(await crypto.subtle.exportKey("raw", key))), Array.from(keyData));

    const sha224 = await crypto.subtle.importKey("raw", keyData, { name: "HMAC", hash: "SHA-224" }, true, ["sign", "verify"]);
    const sha224Signature = await crypto.subtle.sign("HMAC", sha224, data);
    assert.equal(hex(sha224Signature), "88ff8b54675d39b8f72322e65ff945c52d96379988ada25639747e69");
    assert.equal(sha224Signature.byteLength, 28);
    assert.equal(await crypto.subtle.verify("HMAC", sha224, sha224Signature, data), true);
    assert.deepEqual(sha224.algorithm, { name: "HMAC", hash: { name: "SHA-224" }, length: 24 });
    assert.equal((await crypto.subtle.exportKey("jwk", sha224)).alg, "HS224");

    const generated = await crypto.subtle.generateKey({ name: "HMAC", hash: "SHA-512" }, true, ["sign"]);
    assert(generated instanceof CryptoKey);
    assert.equal(generated.algorithm.length, 1024);
    assert.deepEqual(generated.usages, ["sign"]);
    assert.equal(new Uint8Array(await crypto.subtle.exportKey("raw", generated)).length, 128);
  });

  test("subtle HMAC implements Bun SHA-3 vectors", async () => {
    const generatedSha224 = await crypto.subtle.generateKey({ name: "HMAC", hash: "SHA3-224" }, true, ["sign", "verify"]);
    const generated = await crypto.subtle.generateKey({ name: "HMAC", hash: "SHA3-256" }, true, ["sign", "verify"]);
    const data = new TextEncoder().encode("hello world");
    const sha224Signature = await crypto.subtle.sign("HMAC", generatedSha224, data);
    assert.equal(sha224Signature.byteLength, 28);
    assert.equal(await crypto.subtle.verify("HMAC", generatedSha224, sha224Signature, data), true);
    assert.equal((await crypto.subtle.exportKey("raw", generatedSha224)).byteLength, 144);

    const signature = await crypto.subtle.sign("HMAC", generated, data);
    assert.equal(signature.byteLength, 32);
    assert.equal(await crypto.subtle.verify("HMAC", generated, signature, data), true);

    const tampered = new Uint8Array(signature);
    tampered[0] ^= 0xff;
    assert.equal(await crypto.subtle.verify("HMAC", generated, tampered, data), false);

    const keyBytes = new Uint8Array(32).map((_, index) => index);
    const vectorKeySha224 = await crypto.subtle.importKey("raw", keyBytes, { name: "HMAC", hash: "SHA3-224" }, false, ["sign"]);
    const vectorKey = await crypto.subtle.importKey("raw", keyBytes, { name: "HMAC", hash: "SHA3-256" }, false, ["sign"]);
    const message = new TextEncoder().encode("Sample message for keylen<blocklen");
    const vectorSignatureSha224 = await crypto.subtle.sign("HMAC", vectorKeySha224, message);
    assert.equal(hex(vectorSignatureSha224), "7bf598119c2788783550195d105f6956986e0076bd2097e10c979c89");
    const vectorSignature = await crypto.subtle.sign("HMAC", vectorKey, message);
    assert.equal(hex(vectorSignature), "4fe8e202c4f058e8dddc23d8c34e467343e23555e24fc2f025d598f558f67205");

    const sha384 = await crypto.subtle.generateKey({ name: "HMAC", hash: "SHA3-384" }, true, ["sign"]);
    assert.equal((await crypto.subtle.exportKey("raw", sha384)).byteLength, 104);

    const exportedSha224 = await crypto.subtle.exportKey("jwk", generatedSha224);
    assert.equal(Object.hasOwn(exportedSha224, "alg"), false);
    const exportedSha3 = await crypto.subtle.exportKey("jwk", generated);
    assert.equal(Object.hasOwn(exportedSha3, "alg"), false);
    assert.deepEqual(exportedSha3.key_ops, ["sign", "verify"]);
  });

  test("subtle HMAC JWK import and export mirrors Bun behavior", async () => {
    const jwk = {
      kty: "oct",
      k: "AQIDBAUGBwgJCgsMDQ4PEA",
      alg: "HS256",
      ext: true,
      key_ops: ["sign"],
    };
    const key = await crypto.subtle.importKey("jwk", jwk, { name: "HMAC", hash: "SHA-256" }, true, ["sign"]);
    const signature = await crypto.subtle.sign("HMAC", key, new Uint8Array([1, 2, 3, 4]));
    assert.equal(hex(signature), "3baaffd8338d33c2d53029bfb828d82f82a5cb1aa32b2647177ade01922eb657");
    assert.deepEqual(await crypto.subtle.exportKey("jwk", key), jwk);

    const sha3Jwk = { kty: "oct", k: base64Url(new TextEncoder().encode("key")), ext: true, key_ops: ["sign"] };
    const sha3Key = await crypto.subtle.importKey("jwk", sha3Jwk, { name: "HMAC", hash: "SHA3-224" }, true, ["sign"]);
    const sha3Signature = await crypto.subtle.sign("HMAC", sha3Key, new TextEncoder().encode("The quick brown fox jumps over the lazy dog"));
    assert.equal(hex(sha3Signature), "ff6fa8447ce10fb1efdccfe62caf8b640fe46c4fb1007912bf85100f");
    assert.deepEqual(await crypto.subtle.exportKey("jwk", sha3Key), sha3Jwk);
  });

  test("subtle HMAC rejects invalid usages and access", async () => {
    await expectRejectsName(crypto.subtle.importKey("raw", new Uint8Array([1]), { name: "HMAC", hash: "SHA-256" }, true, ["encrypt"]), "SyntaxError");
    await expectRejectsName(crypto.subtle.importKey("raw", new Uint8Array([1]), { name: "HMAC", hash: "SHA-256" }, true, []), "SyntaxError");
    await expectRejectsName(crypto.subtle.generateKey({ name: "HMAC", hash: "SHA-256" }, true, []), "SyntaxError");
    await expectRejectsName(crypto.subtle.importKey("raw", new Uint8Array(), { name: "HMAC", hash: "SHA-256" }, true, ["sign"]), "DataError");

    const verifyOnly = await crypto.subtle.importKey("raw", new Uint8Array([1]), { name: "HMAC", hash: "SHA-256" }, true, ["verify"]);
    await expectRejectsName(crypto.subtle.sign("HMAC", verifyOnly, new Uint8Array()), "InvalidAccessError");

    const signOnly = await crypto.subtle.importKey("raw", new Uint8Array([1]), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    await expectRejectsName(crypto.subtle.exportKey("raw", signOnly), "InvalidAccessError");
    await expectRejectsName(crypto.subtle.encrypt("HMAC", signOnly, new Uint8Array()), "NotSupportedError");
  });

  test("subtle PBKDF2 derives RFC vectors and exposes nonextractable raw keys", async () => {
    const encoder = new TextEncoder();
    const key = await crypto.subtle.importKey("raw", encoder.encode("password"), "PBKDF2", false, ["deriveKey", "deriveBits"]);
    assert(key instanceof CryptoKey);
    assert.deepEqual(key.algorithm, { name: "PBKDF2" });
    assert.equal(key.extractable, false);
    assert.deepEqual(key.usages, ["deriveKey", "deriveBits"]);

    const params = { name: "PBKDF2", salt: encoder.encode("salt"), iterations: 1, hash: "SHA-256" };
    assert.equal(hex(await crypto.subtle.deriveBits(params, key, 160)), "120fb6cffcf8b32c43e7225256c4f837a86548c9");

    const emptyKey = await crypto.subtle.importKey("raw", new Uint8Array(), "PBKDF2", false, ["deriveBits"]);
    assert.equal(hex(await crypto.subtle.deriveBits({ name: "PBKDF2", salt: new Uint8Array(), iterations: 1, hash: "SHA-256" }, emptyKey, 256)), "f7ce0b653d2d72a4108cf5abe912ffdd777616dbbb27a70e8204f3ae2d0f6fad");
  });

  test("subtle HKDF derives RFC 5869 vectors", async () => {
    const ikm = new Uint8Array(22).fill(0x0b);
    const key = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
    assert.deepEqual(key.algorithm, { name: "HKDF" });
    assert.equal(key.extractable, false);
    assert.deepEqual(key.usages, ["deriveBits"]);

    const salt = Uint8Array.from("000102030405060708090a0b0c".match(/../g), byte => Number.parseInt(byte, 16));
    const info = Uint8Array.from("f0f1f2f3f4f5f6f7f8f9".match(/../g), byte => Number.parseInt(byte, 16));
    const bits = await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, key, 336);
    assert.equal(hex(bits), "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865");
  });

  test("subtle PBKDF2/HKDF deriveKey creates AES and HMAC keys", async () => {
    const encoder = new TextEncoder();
    const pbkdf2 = await crypto.subtle.importKey("raw", encoder.encode("password"), "PBKDF2", false, ["deriveKey"]);
    const pbkdf2Params = { name: "PBKDF2", salt: encoder.encode("salt"), iterations: 1, hash: "SHA-256" };

    const aes = await crypto.subtle.deriveKey(pbkdf2Params, pbkdf2, { name: "AES-GCM", length: 128 }, true, ["encrypt"]);
    assert(aes instanceof CryptoKey);
    assert.deepEqual(aes.algorithm, { name: "AES-GCM", length: 128 });
    assert.equal(aes.extractable, true);
    assert.deepEqual(aes.usages, ["encrypt"]);
    assert.equal(hex(await crypto.subtle.exportKey("raw", aes)), "120fb6cffcf8b32c43e7225256c4f837");

    const hmac = await crypto.subtle.deriveKey(pbkdf2Params, pbkdf2, { name: "HMAC", hash: "SHA-256", length: 256 }, true, ["sign"]);
    assert.deepEqual(hmac.algorithm, { name: "HMAC", hash: { name: "SHA-256" }, length: 256 });
    assert.deepEqual(hmac.usages, ["sign"]);
    assert.equal(hex(await crypto.subtle.exportKey("raw", hmac)), "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b");

    const cbc = await crypto.subtle.deriveKey(pbkdf2Params, pbkdf2, { name: "AES-CBC", length: 128 }, true, ["encrypt"]);
    assert.deepEqual(cbc.algorithm, { name: "AES-CBC", length: 128 });
    assert.equal(hex(await crypto.subtle.exportKey("raw", cbc)), "120fb6cffcf8b32c43e7225256c4f837");

    const ctr = await crypto.subtle.deriveKey(pbkdf2Params, pbkdf2, { name: "AES-CTR", length: 192 }, true, ["decrypt"]);
    assert.deepEqual(ctr.algorithm, { name: "AES-CTR", length: 192 });
    assert.equal(new Uint8Array(await crypto.subtle.exportKey("raw", ctr)).length, 24);

    const kw = await crypto.subtle.deriveKey(pbkdf2Params, pbkdf2, { name: "AES-KW", length: 128 }, true, ["wrapKey"]);
    assert.deepEqual(kw.algorithm, { name: "AES-KW", length: 128 });
    assert.deepEqual(kw.usages, ["wrapKey"]);

    const ikm = new Uint8Array(22).fill(0x0b);
    const hkdf = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveKey"]);
    const salt = Uint8Array.from("000102030405060708090a0b0c".match(/../g), byte => Number.parseInt(byte, 16));
    const info = Uint8Array.from("f0f1f2f3f4f5f6f7f8f9".match(/../g), byte => Number.parseInt(byte, 16));
    const hkdfAes = await crypto.subtle.deriveKey({ name: "HKDF", hash: "SHA-256", salt, info }, hkdf, { name: "AES-GCM", length: 256 }, true, ["encrypt", "decrypt"]);
    assert.deepEqual(hkdfAes.algorithm, { name: "AES-GCM", length: 256 });
    assert.equal(hex(await crypto.subtle.exportKey("raw", hkdfAes)), "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf");

    const defaultHmac = await crypto.subtle.deriveKey(
      { name: "PBKDF2", salt: new Uint8Array(), iterations: 20, hash: "SHA-256" },
      await crypto.subtle.importKey("raw", new Uint8Array(), "PBKDF2", false, ["deriveKey"]),
      { name: "HMAC", hash: "SHA-384" },
      false,
      ["sign"],
    );
    assert.deepEqual(defaultHmac.algorithm, { name: "HMAC", hash: { name: "SHA-384" }, length: 1024 });
    assert.equal(defaultHmac.extractable, false);

    const pbkdf2Sha3Aes = await crypto.subtle.deriveKey(
      { name: "PBKDF2", salt: encoder.encode("salt"), iterations: 1000, hash: "SHA3-224" },
      pbkdf2,
      { name: "AES-GCM", length: 128 },
      true,
      ["encrypt"],
    );
    assert.deepEqual(pbkdf2Sha3Aes.algorithm, { name: "AES-GCM", length: 128 });
    assert.equal(hex(await crypto.subtle.exportKey("raw", pbkdf2Sha3Aes)), "2c63ae34f3c11883e945e556cfe40c4d");

    const hkdfSha3Aes = await crypto.subtle.deriveKey(
      { name: "HKDF", hash: "SHA3-224", salt, info },
      hkdf,
      { name: "AES-GCM", length: 128 },
      true,
      ["encrypt"],
    );
    assert.deepEqual(hkdfSha3Aes.algorithm, { name: "AES-GCM", length: 128 });
    assert.equal(hex(await crypto.subtle.exportKey("raw", hkdfSha3Aes)), "5058867fc7bdb118ce6a703add6edbf8");
  });

  test("subtle PBKDF2/HKDF deriveBits supports SHA-3 hashes", async () => {
    const encoder = new TextEncoder();
    const pbkdf2 = await crypto.subtle.importKey("raw", encoder.encode("pw"), "PBKDF2", false, ["deriveBits"]);
    const hkdf = await crypto.subtle.importKey("raw", new Uint8Array(22).fill(0x0b), "HKDF", false, ["deriveBits"]);
    const salt = Uint8Array.from("000102030405060708090a0b0c".match(/../g), byte => Number.parseInt(byte, 16));
    const info = Uint8Array.from("f0f1f2f3f4f5f6f7f8f9".match(/../g), byte => Number.parseInt(byte, 16));
    const vectors = [
      ["SHA3-224", "8e5795aea58e47df8a6e94b5e57644fc548c19fdc6d3aa1de5eb81e8c4fd072b", "5058867fc7bdb118ce6a703add6edbf8e2ce21f5766cfc2e662e1a36ff6922fa"],
      ["SHA3-256", "53b1bc246a311cbf8e2c907d96bcb209ddf95cd9f0a74fdcbab033b6ea82e30a", "0c5160501d65021deaf2c14f5abce04c5bd2635abceeba61c2edb6e8ed726749"],
      ["SHA3-384", "a95873dc9d98eba5c08a02eec48b262d810338277be553f59882f524ee4be165", "138d8521e5a346a9cb770f762b9c04d9ca317409fb6a3ef9cb905228385589ae"],
      ["SHA3-512", "54c90752c97aa013d266a69ef850eb4792376ed63c91104919e753de905a3135", "40e9f17e9bf2ef99425c2b23ccdf20a018ea5513f9ae68e1ea8c626deb57dfa4"],
    ];
    for (const [hash, expectedPbkdf2, expectedHkdf] of vectors) {
      const pbkdf2Bits = await crypto.subtle.deriveBits(
        { name: "PBKDF2", salt: encoder.encode("salt"), iterations: 1000, hash },
        pbkdf2,
        256,
      );
      assert.equal(hex(pbkdf2Bits), expectedPbkdf2, `PBKDF2 ${hash}`);
      const hkdfBits = await crypto.subtle.deriveBits({ name: "HKDF", hash, salt, info }, hkdf, 256);
      assert.equal(hex(hkdfBits), expectedHkdf, `HKDF ${hash}`);
    }
  });

  test("subtle PBKDF2/HKDF reject invalid import, params, and access", async () => {
    const raw = new Uint8Array([1, 2, 3]);
    await expectRejectsName(crypto.subtle.importKey("raw", raw, "PBKDF2", true, ["deriveBits"]), "SyntaxError");
    await expectRejectsName(crypto.subtle.importKey("raw", raw, "HKDF", true, ["deriveBits"]), "SyntaxError");
    await expectRejectsName(crypto.subtle.importKey("raw", raw, "PBKDF2", false, ["sign"]), "SyntaxError");

    const pbkdf2 = await crypto.subtle.importKey("raw", raw, "PBKDF2", false, ["deriveBits"]);
    const hkdf = await crypto.subtle.importKey("raw", raw, "HKDF", false, ["deriveBits"]);
    await expectRejectsName(crypto.subtle.exportKey("raw", pbkdf2), "NotSupportedError");
    await expectRejectsName(crypto.subtle.deriveBits({ name: "PBKDF2", salt: raw, iterations: 1, hash: "SHA-256" }, pbkdf2), "TypeError");
    assert.equal((await crypto.subtle.deriveBits({ name: "PBKDF2", salt: raw, iterations: 1, hash: "SHA-256" }, pbkdf2, 0)).byteLength, 0);
    assert.equal((await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt: raw, info: raw }, hkdf, 0)).byteLength, 0);
    await expectRejectsName(crypto.subtle.deriveBits({ name: "PBKDF2", salt: raw, iterations: 1, hash: "SHA-256" }, pbkdf2, 7), "OperationError");
    await expectRejectsName(crypto.subtle.deriveBits({ name: "PBKDF2", salt: raw, iterations: 0, hash: "SHA-256" }, pbkdf2, 8), "OperationError");
    await expectRejectsName(crypto.subtle.deriveBits({ name: "PBKDF2", salt: raw, iterations: 1_000_001, hash: "SHA-256" }, pbkdf2, 8), "OperationError");
    await expectRejectsName(crypto.subtle.deriveBits({ name: "PBKDF2", salt: raw, iterations: -1, hash: "SHA-256" }, pbkdf2, 8), "TypeError");
    await expectRejectsName(crypto.subtle.deriveBits({ name: "PBKDF2", salt: raw, iterations: 1, hash: "SHA-999" }, pbkdf2, 8), "NotSupportedError");
    await expectRejectsName(crypto.subtle.deriveBits({ name: "PBKDF2", iterations: 1, hash: "SHA-256" }, pbkdf2, 8), "TypeError");
    await expectRejectsName(crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt: raw, info: raw }, pbkdf2, 8), "InvalidAccessError");
    await expectRejectsName(crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt: raw }, hkdf, 8), "TypeError");

    const deriveKeyOnly = await crypto.subtle.importKey("raw", raw, "PBKDF2", false, ["deriveKey"]);
    await expectRejectsName(crypto.subtle.deriveBits({ name: "PBKDF2", salt: raw, iterations: 1, hash: "SHA-256" }, deriveKeyOnly, 8), "InvalidAccessError");
    await expectRejectsName(crypto.subtle.deriveBits({ name: "PBKDF2", iterations: 1, hash: "SHA-256" }, deriveKeyOnly, 8), "TypeError");
    await expectRejectsName(crypto.subtle.deriveBits({ name: "PBKDF2", salt: raw, iterations: 1, hash: "SHA-256" }, deriveKeyOnly, 0), "InvalidAccessError");
    await expectRejectsName(crypto.subtle.deriveKey({ name: "PBKDF2", salt: raw, iterations: 1, hash: "SHA-256" }, pbkdf2, { name: "AES-GCM", length: 128 }, true, ["encrypt"]), "InvalidAccessError");
    await expectRejectsName(crypto.subtle.deriveKey({ name: "PBKDF2", iterations: 1, hash: "SHA-256" }, pbkdf2, { name: "AES-GCM" }, true, ["encrypt"]), "TypeError");
    await expectRejectsName(crypto.subtle.deriveKey({ name: "PBKDF2", salt: raw, iterations: 1, hash: "SHA-256" }, pbkdf2, { name: "AES-GCM" }, true, ["encrypt"]), "TypeError");
    await expectRejectsName(crypto.subtle.deriveKey({ name: "PBKDF2", salt: raw, iterations: 1, hash: "SHA-256" }, deriveKeyOnly, { name: "AES-GCM" }, true, ["encrypt"]), "TypeError");
    await expectRejectsName(crypto.subtle.deriveKey({ name: "PBKDF2", salt: raw, iterations: 1, hash: "SHA-256" }, deriveKeyOnly, { name: "AES-GCM", length: 129 }, true, ["encrypt"]), "OperationError");
    await expectRejectsName(crypto.subtle.deriveKey({ name: "HKDF", hash: "SHA-256", salt: raw, info: raw }, deriveKeyOnly, { name: "AES-GCM", length: 128 }, true, ["encrypt"]), "InvalidAccessError");
    await expectRejectsName(crypto.subtle.deriveKey({ name: "PBKDF2", salt: raw, iterations: 1, hash: "SHA-256" }, deriveKeyOnly, { name: "HMAC", hash: "SHA-256" }, true, ["encrypt"]), "SyntaxError");
    await expectRejectsName(crypto.subtle.deriveKey({ name: "PBKDF2", salt: raw, iterations: 1, hash: "SHA-256" }, deriveKeyOnly, { name: "AES-GCM", length: 128 }, true, []), "SyntaxError");
    await expectRejectsName(crypto.subtle.deriveKey({ name: "PBKDF2", salt: raw, iterations: 1, hash: "SHA-256" }, deriveKeyOnly, { name: "HMAC", hash: "SHA-256" }, true, []), "SyntaxError");
    await expectRejectsName(crypto.subtle.importKey("raw", raw, "PBKDF2", false, []), "SyntaxError");
    await expectRejectsName(crypto.subtle.importKey("raw", raw, "HKDF", false, []), "SyntaxError");
    await expectRejectsName(crypto.subtle.deriveKey({ name: "PBKDF2", salt: raw, iterations: 0, hash: "SHA-256" }, deriveKeyOnly, { name: "AES-GCM", length: 128 }, true, ["encrypt"]), "OperationError");
    await expectRejectsName(crypto.subtle.deriveKey({ name: "PBKDF2", salt: raw, iterations: 1_000_001, hash: "SHA-256" }, deriveKeyOnly, { name: "AES-GCM", length: 128 }, true, ["encrypt"]), "OperationError");
  });

  test("subtle AES-GCM raw import, export, encrypt, and decrypt", async () => {
    const keyData = new Uint8Array(16);
    const key = await crypto.subtle.importKey("raw", keyData, { name: "AES-GCM" }, true, ["decrypt", "encrypt", "wrapKey", "unwrapKey"]);

    assert(key instanceof CryptoKey);
    assert.deepEqual(key.algorithm, { name: "AES-GCM", length: 128 });
    assert.deepEqual(key.usages, ["encrypt", "decrypt", "wrapKey", "unwrapKey"]);
    assert.deepEqual(Array.from(new Uint8Array(await crypto.subtle.exportKey("raw", key))), Array.from(keyData));
    assert.deepEqual(await crypto.subtle.exportKey("jwk", key), {
      kty: "oct",
      k: "AAAAAAAAAAAAAAAAAAAAAA",
      alg: "A128GCM",
      ext: true,
      key_ops: ["encrypt", "decrypt", "wrapKey", "unwrapKey"],
    });

    const iv = new Uint8Array(12);
    const plaintext = new Uint8Array(16);
    const encrypted = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, plaintext);
    assert.equal(hex(encrypted), "0388dace60b6a392f328c2b971b2fe78ab6e47d42cec13bdf53a67b21257bddf");
    assert.deepEqual(Array.from(new Uint8Array(await crypto.subtle.decrypt({ name: "AES-GCM", iv }, key, encrypted))), Array.from(plaintext));
  });

  test("subtle AES-GCM generateKey supports additionalData, variable IV, and tagLength", async () => {
    const key = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, true, ["encrypt", "decrypt"]);
    assert.equal(key.algorithm.length, 256);
    assert.deepEqual(key.usages, ["encrypt", "decrypt"]);

    const iv = crypto.getRandomValues(new Uint8Array(16));
    const additionalData = crypto.getRandomValues(new Uint8Array(16));
    const empty = new Uint8Array();
    const encryptedEmpty = await crypto.subtle.encrypt({ name: "AES-GCM", iv, tagLength: 128, additionalData }, key, empty);
    assert.equal(new Uint8Array(encryptedEmpty).length, 16);
    assert.equal(new TextDecoder().decode(await crypto.subtle.decrypt({ name: "AES-GCM", iv, tagLength: 128, additionalData }, key, encryptedEmpty)), "");

    const small = new TextEncoder().encode("Hello World!");
    const encryptedWithShortTag = await crypto.subtle.encrypt({ name: "AES-GCM", iv: iv.subarray(0, 12), tagLength: 96 }, key, small);
    assert.equal(new Uint8Array(encryptedWithShortTag).length, small.length + 12);
    assert.equal(new TextDecoder().decode(await crypto.subtle.decrypt({ name: "AES-GCM", iv: iv.subarray(0, 12), tagLength: 96 }, key, encryptedWithShortTag)), "Hello World!");
  });

  test("subtle AES-GCM JWK import mirrors Bun behavior", async () => {
    const jwk = {
      kty: "oct",
      k: "AQIDBAUGBwgJCgsMDQ4PEA",
      alg: "A128GCM",
      ext: true,
      key_ops: ["encrypt"],
    };
    const key = await crypto.subtle.importKey("jwk", jwk, { name: "AES-GCM" }, true, ["encrypt"]);
    assert.deepEqual(key.algorithm, { name: "AES-GCM", length: 128 });
    assert.deepEqual(await crypto.subtle.exportKey("jwk", key), jwk);
  });

  test("subtle AES-CBC raw and JWK import, generate, encrypt, and decrypt", async () => {
    const keyData = fromHex("2b7e151628aed2a6abf7158809cf4f3c");
    const iv = fromHex("000102030405060708090a0b0c0d0e0f");
    const plaintext = fromHex("6bc1bee22e409f96e93d7e117393172a");
    const key = await crypto.subtle.importKey("raw", keyData, { name: "AES-CBC" }, true, ["decrypt", "encrypt", "wrapKey", "unwrapKey"]);

    assert.deepEqual(key.algorithm, { name: "AES-CBC", length: 128 });
    assert.deepEqual(key.usages, ["encrypt", "decrypt", "wrapKey", "unwrapKey"]);
    assert.equal(hex(await crypto.subtle.exportKey("raw", key)), "2b7e151628aed2a6abf7158809cf4f3c");
    assert.deepEqual(await crypto.subtle.exportKey("jwk", key), {
      kty: "oct",
      k: "K34VFiiu0qar9xWICc9PPA",
      alg: "A128CBC",
      ext: true,
      key_ops: ["encrypt", "decrypt", "wrapKey", "unwrapKey"],
    });

    const encrypted = await crypto.subtle.encrypt({ name: "AES-CBC", iv }, key, plaintext);
    assert.equal(hex(encrypted), "7649abac8119b246cee98e9b12e9197d8964e0b149c10b7b682e6e39aaeb731c");
    assert.equal(hex(await crypto.subtle.decrypt({ name: "AES-CBC", iv }, key, encrypted)), hex(plaintext));

    const jwk = { kty: "oct", k: "AAECAwQFBgcICQoLDA0ODw", alg: "A128CBC", ext: true, key_ops: ["encrypt"] };
    const jwkKey = await crypto.subtle.importKey("jwk", jwk, { name: "AES-CBC" }, true, ["encrypt"]);
    assert.deepEqual(jwkKey.algorithm, { name: "AES-CBC", length: 128 });
    assert.deepEqual(await crypto.subtle.exportKey("jwk", jwkKey), jwk);

    const generated = await crypto.subtle.generateKey({ name: "AES-CBC", length: 192 }, true, ["encrypt"]);
    assert.deepEqual(generated.algorithm, { name: "AES-CBC", length: 192 });
    assert.equal(new Uint8Array(await crypto.subtle.exportKey("raw", generated)).length, 24);

    await expectRejectsName(crypto.subtle.encrypt({ name: "AES-CBC", iv: new Uint8Array(15) }, key, plaintext), "OperationError");
    await expectRejectsName(crypto.subtle.encrypt({ name: "AES-CBC" }, key, plaintext), "TypeError");
  });

  test("subtle AES-CTR raw and JWK import, generate, encrypt, and decrypt", async () => {
    const keyData = fromHex("2b7e151628aed2a6abf7158809cf4f3c");
    const counter = fromHex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff");
    const plaintext = fromHex("6bc1bee22e409f96e93d7e117393172a");
    const key = await crypto.subtle.importKey("raw", keyData, { name: "AES-CTR" }, true, ["decrypt", "encrypt", "wrapKey", "unwrapKey"]);

    assert.deepEqual(key.algorithm, { name: "AES-CTR", length: 128 });
    assert.deepEqual(key.usages, ["encrypt", "decrypt", "wrapKey", "unwrapKey"]);
    assert.deepEqual(await crypto.subtle.exportKey("jwk", key), {
      kty: "oct",
      k: "K34VFiiu0qar9xWICc9PPA",
      alg: "A128CTR",
      ext: true,
      key_ops: ["encrypt", "decrypt", "wrapKey", "unwrapKey"],
    });

    const encrypted = await crypto.subtle.encrypt({ name: "AES-CTR", counter, length: 128 }, key, plaintext);
    assert.equal(hex(encrypted), "874d6191b620e3261bef6864990db6ce");
    assert.equal(hex(await crypto.subtle.decrypt({ name: "AES-CTR", counter, length: 128 }, key, encrypted)), hex(plaintext));

    const longPlaintext = fromHex(
      "6bc1bee22e409f96e93d7e117393172a" +
      "ae2d8a571e03ac9c9eb76fac45af8e51" +
      "30c81c46a35ce411e5fbc1191a0a52ef" +
      "f69f2445df4f9b17ad2b417be66c3710"
    );
    const ctr64 = await crypto.subtle.encrypt({ name: "AES-CTR", counter, length: 64 }, key, longPlaintext);
    assert.equal(
      hex(ctr64),
      "874d6191b620e3261bef6864990db6ce" +
        "9806f66b7970fdff8617187bb9fffdff" +
        "5ae4df3edbd5d35e5b4f09020db03eab" +
        "1e031dda2fbe03d1792170a0f3009cee"
    );

    const jwk = { kty: "oct", k: "AAECAwQFBgcICQoLDA0ODw", alg: "A128CTR", ext: true, key_ops: ["decrypt"] };
    const jwkKey = await crypto.subtle.importKey("jwk", jwk, { name: "AES-CTR" }, true, ["decrypt"]);
    assert.deepEqual(jwkKey.algorithm, { name: "AES-CTR", length: 128 });
    assert.deepEqual(await crypto.subtle.exportKey("jwk", jwkKey), jwk);

    const generated = await crypto.subtle.generateKey({ name: "AES-CTR", length: 256 }, true, ["decrypt"]);
    assert.deepEqual(generated.algorithm, { name: "AES-CTR", length: 256 });
    assert.equal(new Uint8Array(await crypto.subtle.exportKey("raw", generated)).length, 32);

    await expectRejectsName(crypto.subtle.encrypt({ name: "AES-CTR", counter: new Uint8Array(15), length: 64 }, key, plaintext), "OperationError");
    await expectRejectsName(crypto.subtle.encrypt({ name: "AES-CTR", counter, length: 0 }, key, plaintext), "OperationError");
    await expectRejectsName(crypto.subtle.encrypt({ name: "AES-CTR", counter, length: 129 }, key, plaintext), "OperationError");
    await expectRejectsName(crypto.subtle.encrypt({ name: "AES-CTR", counter, length: 1 }, key, new Uint8Array(48)), "OperationError");
    await expectRejectsName(crypto.subtle.encrypt({ name: "AES-CTR", counter }, key, plaintext), "TypeError");
  });

  test("subtle AES-CFB-8 raw and JWK import, generate, encrypt, decrypt, and wrap", async () => {
    const keyData = fromHex("2b7e151628aed2a6abf7158809cf4f3c");
    const iv = fromHex("000102030405060708090a0b0c0d0e0f");
    const plaintext = fromHex("6bc1bee22e409f96e93d7e117393172a");
    const key = await crypto.subtle.importKey("raw", keyData, { name: "AES-CFB-8" }, true, ["decrypt", "encrypt", "wrapKey", "unwrapKey"]);

    assert.deepEqual(key.algorithm, { name: "AES-CFB-8", length: 128 });
    assert.deepEqual(key.usages, ["encrypt", "decrypt", "wrapKey", "unwrapKey"]);
    assert.deepEqual(await crypto.subtle.exportKey("jwk", key), {
      kty: "oct",
      k: "K34VFiiu0qar9xWICc9PPA",
      alg: "A128CFB8",
      ext: true,
      key_ops: ["encrypt", "decrypt", "wrapKey", "unwrapKey"],
    });

    const encrypted = await crypto.subtle.encrypt({ name: "AES-CFB-8", iv }, key, plaintext);
    assert.equal(hex(encrypted), "3b79424c9c0dd436bace9e0ed4586a4f");
    assert.equal(hex(await crypto.subtle.decrypt({ name: "AES-CFB-8", iv }, key, encrypted)), hex(plaintext));

    for (const [length, expected] of [
      [17, "5055986aba87b80250cade7c5986335145"],
      [31, "5055986aba87b80250cade7c59863351459eebed680c26ae20ca58ccf5a7b3"],
      [32, "5055986aba87b80250cade7c59863351459eebed680c26ae20ca58ccf5a7b3d2"],
      [33, "5055986aba87b80250cade7c59863351459eebed680c26ae20ca58ccf5a7b3d2bb"],
    ]) {
      const multiBlockPlaintext = Uint8Array.from({ length }, (_, index) => index);
      const multiBlockEncrypted = await crypto.subtle.encrypt({ name: "AES-CFB-8", iv }, key, multiBlockPlaintext);
      assert.equal(hex(multiBlockEncrypted), expected, `AES-CFB-8 ${length} byte ciphertext`);
      assert.equal(hex(await crypto.subtle.decrypt({ name: "AES-CFB-8", iv }, key, multiBlockEncrypted)), hex(multiBlockPlaintext));
    }

    const aliasKey = await crypto.subtle.generateKey({ name: "AES-CFB", length: 128 }, true, ["encrypt"]);
    assert.deepEqual(aliasKey.algorithm, { name: "AES-CFB-8", length: 128 });

    const jwk = { kty: "oct", k: "AAECAwQFBgcICQoLDA0ODw", alg: "A128CFB8", ext: true, key_ops: ["decrypt"] };
    const jwkKey = await crypto.subtle.importKey("jwk", jwk, { name: "AES-CFB" }, true, ["decrypt"]);
    assert.deepEqual(jwkKey.algorithm, { name: "AES-CFB-8", length: 128 });
    assert.deepEqual(await crypto.subtle.exportKey("jwk", jwkKey), jwk);

    for (const [jwkData, algorithmName, expected] of [
      [
        { kty: "oct", k: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYX", alg: "A192CFB8", ext: true, key_ops: ["encrypt", "decrypt"] },
        "AES-CFB-8",
        "00aa1c190d92061fcb5c470f70de74a33780cf429f4c1a7dec61d4a8d421820a4c",
      ],
      [
        { kty: "oct", k: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8", alg: "A256CFB8", ext: true, key_ops: ["encrypt", "decrypt"] },
        "AES-CFB",
        "5a962fda85eedcc87f8b0f4f91eda6cbb7a9f141c1397c7c5bb63ec37a7b82caa8",
      ],
    ]) {
      const imported = await crypto.subtle.importKey("jwk", jwkData, { name: algorithmName }, true, ["encrypt", "decrypt"]);
      assert.deepEqual(imported.algorithm, { name: "AES-CFB-8", length: jwkData.k.length === 32 ? 192 : 256 });
      assert.deepEqual(await crypto.subtle.exportKey("jwk", imported), jwkData);
      const data = Uint8Array.from({ length: 33 }, (_, index) => index);
      const encryptedData = await crypto.subtle.encrypt({ name: "AES-CFB-8", iv }, imported, data);
      assert.equal(hex(encryptedData), expected);
      assert.equal(hex(await crypto.subtle.decrypt({ name: "AES-CFB-8", iv }, imported, encryptedData)), hex(data));
    }

    const wrappedKeyData = new Uint8Array(16).fill(7);
    const keyToWrap = await crypto.subtle.importKey("raw", wrappedKeyData, { name: "AES-GCM" }, true, ["encrypt"]);
    const wrapped = await crypto.subtle.wrapKey("raw", keyToWrap, key, { name: "AES-CFB-8", iv });
    assert.equal(new Uint8Array(wrapped).length, 16);
    const unwrapped = await crypto.subtle.unwrapKey("raw", wrapped, key, { name: "AES-CFB-8", iv }, { name: "AES-GCM" }, true, ["encrypt"]);
    assert.equal(hex(await crypto.subtle.exportKey("raw", unwrapped)), hex(wrappedKeyData));

    await expectRejectsName(crypto.subtle.encrypt({ name: "AES-CFB-8", iv: new Uint8Array(15) }, key, plaintext), "OperationError");
    await expectRejectsName(crypto.subtle.encrypt({ name: "AES-CFB-8" }, key, plaintext), "TypeError");
  });

  test("subtle AES numeric parameters reject extreme JS numbers", async () => {
    const raw128 = new Uint8Array(16);
    const gcm = await crypto.subtle.importKey("raw", raw128, { name: "AES-GCM" }, false, ["encrypt"]);
    const ctr = await crypto.subtle.importKey("raw", raw128, { name: "AES-CTR" }, false, ["encrypt"]);
    const pbkdf2 = await crypto.subtle.importKey("raw", raw128, "PBKDF2", false, ["deriveKey"]);
    const kdfParams = { name: "PBKDF2", salt: raw128, iterations: 1, hash: "SHA-256" };

    for (const value of [Number.MAX_VALUE, 1e100, Infinity, NaN, -1, 128.5]) {
      await expectRejectsName(crypto.subtle.generateKey({ name: "AES-GCM", length: value }, false, ["encrypt"]), "OperationError");
      await expectRejectsName(crypto.subtle.encrypt({ name: "AES-GCM", iv: new Uint8Array(12), tagLength: value }, gcm, raw128), "OperationError");
      await expectRejectsName(crypto.subtle.encrypt({ name: "AES-CTR", counter: raw128, length: value }, ctr, raw128), "OperationError");
      await expectRejectsName(crypto.subtle.deriveKey(kdfParams, pbkdf2, { name: "AES-GCM", length: value }, false, ["encrypt"]), "OperationError");
    }

    // The AES importKey algorithm is a plain Algorithm dictionary; a "length"
    // member is non-spec and must be ignored.
    const lengthIgnored = await crypto.subtle.importKey("raw", raw128, { name: "AES-GCM", length: Number.MAX_VALUE }, false, ["encrypt"]);
    assert.deepEqual(lengthIgnored.algorithm, { name: "AES-GCM", length: 128 });
  });

  test("subtle AES-KW raw and JWK import, generate, wrap, and unwrap", async () => {
    const kek = fromHex("000102030405060708090a0b0c0d0e0f");
    const keyData = fromHex("00112233445566778899aabbccddeeff");
    const wrappingKey = await crypto.subtle.importKey("raw", kek, { name: "AES-KW" }, true, ["wrapKey", "unwrapKey"]);
    const key = await crypto.subtle.importKey("raw", keyData, { name: "AES-GCM" }, true, ["encrypt"]);

    assert.deepEqual(wrappingKey.algorithm, { name: "AES-KW", length: 128 });
    assert.deepEqual(wrappingKey.usages, ["wrapKey", "unwrapKey"]);
    assert.deepEqual(await crypto.subtle.exportKey("jwk", wrappingKey), {
      kty: "oct",
      k: "AAECAwQFBgcICQoLDA0ODw",
      alg: "A128KW",
      ext: true,
      key_ops: ["wrapKey", "unwrapKey"],
    });

    const wrapped = await crypto.subtle.wrapKey("raw", key, wrappingKey, "AES-KW");
    assert.equal(hex(wrapped), "1fa68b0a8112b447aef34bd8fb5a7b829d3e862371d2cfe5");
    const unwrapped = await crypto.subtle.unwrapKey("raw", wrapped, wrappingKey, "AES-KW", { name: "AES-GCM" }, true, ["encrypt"]);
    assert.equal(hex(await crypto.subtle.exportKey("raw", unwrapped)), hex(keyData));

    const jwk = { kty: "oct", k: "AAECAwQFBgcICQoLDA0ODw", alg: "A128KW", ext: true, key_ops: ["wrapKey"] };
    const jwkKey = await crypto.subtle.importKey("jwk", jwk, { name: "AES-KW" }, true, ["wrapKey"]);
    assert.deepEqual(await crypto.subtle.exportKey("jwk", jwkKey), jwk);

    const generated = await crypto.subtle.generateKey({ name: "AES-KW", length: 256 }, true, ["wrapKey"]);
    assert.deepEqual(generated.algorithm, { name: "AES-KW", length: 256 });
    assert.deepEqual(generated.usages, ["wrapKey"]);

    const shortHmac = await crypto.subtle.importKey("raw", new TextEncoder().encode("key"), { name: "HMAC", hash: "SHA-256" }, true, ["sign"]);
    await expectRejectsName(crypto.subtle.wrapKey("raw", shortHmac, wrappingKey, "AES-KW"), "OperationError");
    await expectRejectsName(crypto.subtle.generateKey({ name: "AES-KW", length: 128 }, false, ["encrypt"]), "SyntaxError");
    await expectRejectsName(crypto.subtle.encrypt("AES-KW", wrappingKey, new Uint8Array(16)), "NotSupportedError");
  });

  test("subtle key import and generation read algorithm name once", async () => {
    let aesImportNameReads = 0;
    await crypto.subtle.importKey("raw", new Uint8Array(16), {
      get name() {
        aesImportNameReads++;
        return "AES-GCM";
      },
    }, true, ["encrypt"]);
    assert.equal(aesImportNameReads, 1);

    let aesGenerateNameReads = 0;
    await crypto.subtle.generateKey({
      get name() {
        aesGenerateNameReads++;
        return "AES-GCM";
      },
      length: 128,
    }, true, ["encrypt"]);
    assert.equal(aesGenerateNameReads, 1);

    let hmacImportNameReads = 0;
    await crypto.subtle.importKey("raw", new Uint8Array([1]), {
      get name() {
        hmacImportNameReads++;
        return "HMAC";
      },
      hash: "SHA-256",
    }, true, ["sign"]);
    assert.equal(hmacImportNameReads, 1);
  });

  test("subtle AES-GCM rejects invalid params and access", async () => {
    await expectRejectsName(crypto.subtle.generateKey({ name: "AES-GCM", length: 129 }, false, ["encrypt"]), "OperationError");
    await expectRejectsName(crypto.subtle.generateKey({ name: "AES-GCM", length: 128 }, false, ["sign"]), "SyntaxError");
    await expectRejectsName(crypto.subtle.generateKey({ name: "AES-GCM", length: 128 }, false, []), "SyntaxError");
    await expectRejectsName(crypto.subtle.importKey("raw", new Uint8Array(15), { name: "AES-GCM" }, true, ["encrypt"]), "DataError");
    await expectRejectsName(crypto.subtle.importKey("raw", new Uint8Array(16), { name: "AES-GCM" }, true, []), "SyntaxError");

    const decryptOnly = await crypto.subtle.generateKey({ name: "AES-GCM", length: 128 }, false, ["decrypt"]);
    await expectRejectsName(crypto.subtle.encrypt({ name: "AES-GCM", iv: new Uint8Array(12) }, decryptOnly, new Uint8Array()), "InvalidAccessError");
    await expectRejectsName(crypto.subtle.encrypt({ name: "AES-GCM" }, decryptOnly, new Uint8Array()), "TypeError");
    await expectRejectsName(crypto.subtle.encrypt({ name: "AES-GCM", iv: new Uint8Array(12), tagLength: 40 }, decryptOnly, new Uint8Array()), "OperationError");

    const roundtrip = await crypto.subtle.generateKey({ name: "AES-GCM", length: 128 }, false, ["encrypt", "decrypt"]);
    const iv = new Uint8Array(12);
    const encrypted = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, roundtrip, new Uint8Array([1, 2, 3])));
    encrypted[0] ^= 1;
    await expectRejectsName(crypto.subtle.decrypt({ name: "AES-GCM", iv }, roundtrip, encrypted), "OperationError");
    await expectRejectsName(crypto.subtle.encrypt({ get name() { throw new DOMException("boom", "DataError"); }, iv }, roundtrip, new Uint8Array()), "DataError");
  });

  test("subtle AES-GCM wraps and unwraps raw and JWK keys", async () => {
    const wrappingKey = await crypto.subtle.importKey("raw", new Uint8Array(32).fill(1), { name: "AES-GCM" }, false, ["wrapKey", "unwrapKey"]);
    const iv = new Uint8Array(12).fill(2);

    const hmacKey = await crypto.subtle.importKey("raw", new TextEncoder().encode("key"), { name: "HMAC", hash: "SHA-256" }, true, ["sign", "verify"]);
    const wrappedRaw = await crypto.subtle.wrapKey("raw", hmacKey, wrappingKey, { name: "AES-GCM", iv });
    const unwrappedHmac = await crypto.subtle.unwrapKey("raw", wrappedRaw, wrappingKey, { name: "AES-GCM", iv }, { name: "HMAC", hash: "SHA-256", length: 24 }, true, ["sign"]);
    assert.deepEqual(unwrappedHmac.algorithm, { name: "HMAC", hash: { name: "SHA-256" }, length: 24 });
    assert.equal(hex(await crypto.subtle.sign("HMAC", unwrappedHmac, new TextEncoder().encode("The quick brown fox jumps over the lazy dog"))), "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8");

    const aesKey = await crypto.subtle.importKey("raw", new Uint8Array(16).fill(3), { name: "AES-GCM" }, true, ["encrypt", "decrypt"]);
    const wrappedJwk = await crypto.subtle.wrapKey("jwk", aesKey, wrappingKey, { name: "AES-GCM", iv });
    const unwrappedAes = await crypto.subtle.unwrapKey("jwk", wrappedJwk, wrappingKey, { name: "AES-GCM", iv }, { name: "AES-GCM" }, true, ["encrypt"]);
    assert.deepEqual(unwrappedAes.algorithm, { name: "AES-GCM", length: 128 });
    assert.deepEqual(unwrappedAes.usages, ["encrypt"]);
    assert.deepEqual(Array.from(new Uint8Array(await crypto.subtle.exportKey("raw", unwrappedAes))), Array.from(new Uint8Array(16).fill(3)));
  });

  test("subtle AES-CBC and AES-CTR wrap and unwrap raw keys", async () => {
    const keyData = new Uint8Array(16).fill(7);
    const key = await crypto.subtle.importKey("raw", keyData, { name: "AES-GCM" }, true, ["encrypt"]);

    const cbcWrappingKey = await crypto.subtle.importKey("raw", new Uint8Array(16).fill(1), { name: "AES-CBC" }, false, ["wrapKey", "unwrapKey"]);
    const iv = new Uint8Array(16).fill(2);
    const wrappedCbc = await crypto.subtle.wrapKey("raw", key, cbcWrappingKey, { name: "AES-CBC", iv });
    assert.equal(new Uint8Array(wrappedCbc).length, 32);
    const unwrappedCbc = await crypto.subtle.unwrapKey("raw", wrappedCbc, cbcWrappingKey, { name: "AES-CBC", iv }, { name: "AES-GCM" }, true, ["encrypt"]);
    assert.equal(hex(await crypto.subtle.exportKey("raw", unwrappedCbc)), hex(keyData));

    const ctrWrappingKey = await crypto.subtle.importKey("raw", new Uint8Array(16).fill(3), { name: "AES-CTR" }, false, ["wrapKey", "unwrapKey"]);
    const counter = new Uint8Array(16).fill(4);
    const wrappedCtr = await crypto.subtle.wrapKey("raw", key, ctrWrappingKey, { name: "AES-CTR", counter, length: 64 });
    assert.equal(new Uint8Array(wrappedCtr).length, 16);
    const unwrappedCtr = await crypto.subtle.unwrapKey("raw", wrappedCtr, ctrWrappingKey, { name: "AES-CTR", counter, length: 64 }, { name: "AES-GCM" }, true, ["encrypt"]);
    assert.equal(hex(await crypto.subtle.exportKey("raw", unwrappedCtr)), hex(keyData));
  });

  test("subtle RSA signing algorithms generate, import, export, sign, and verify", async () => {
    const publicExponent = new Uint8Array([1, 0, 1]);
    const data = new TextEncoder().encode("collo rsa signing");

    const rsassa = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 1024, publicExponent, hash: "SHA-256" }, true, ["sign", "verify"]);
    assert(rsassa.publicKey instanceof CryptoKey);
    assert(rsassa.privateKey instanceof CryptoKey);
    assert.equal(rsassa.publicKey.type, "public");
    assert.equal(rsassa.privateKey.type, "private");
    assert.deepEqual(rsassa.publicKey.usages, ["verify"]);
    assert.deepEqual(rsassa.privateKey.usages, ["sign"]);
    assert.equal(rsassa.publicKey.algorithm.name, "RSASSA-PKCS1-v1_5");
    assert.equal(rsassa.publicKey.algorithm.modulusLength, 1024);
    assert(rsassa.publicKey.algorithm.publicExponent instanceof Uint8Array);
    assert.deepEqual(Array.from(rsassa.publicKey.algorithm.publicExponent), [1, 0, 1]);
    assert.deepEqual(rsassa.publicKey.algorithm.hash, { name: "SHA-256" });

    const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", rsassa.privateKey, data);
    assert.equal(new Uint8Array(signature).length, 128);
    assert.equal(await crypto.subtle.verify("RSASSA-PKCS1-v1_5", rsassa.publicKey, signature, data), true);
    assert.equal(await crypto.subtle.verify("RSASSA-PKCS1-v1_5", rsassa.publicKey, signature, new Uint8Array([1])), false);

    const spki = await crypto.subtle.exportKey("spki", rsassa.publicKey);
    const pkcs8 = await crypto.subtle.exportKey("pkcs8", rsassa.privateKey);
    const importedPublic = await crypto.subtle.importKey("spki", spki, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, true, ["verify"]);
    const importedPrivate = await crypto.subtle.importKey("pkcs8", pkcs8, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, true, ["sign"]);
    const importedPublicNoUsages = await crypto.subtle.importKey("spki", spki, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, true, []);
    assert.deepEqual(importedPublicNoUsages.usages, []);
    const importedSignature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", importedPrivate, data);
    assert.equal(await crypto.subtle.verify("RSASSA-PKCS1-v1_5", importedPublic, importedSignature, data), true);

    const publicJwk = await crypto.subtle.exportKey("jwk", rsassa.publicKey);
    const privateJwk = await crypto.subtle.exportKey("jwk", rsassa.privateKey);
    assert.equal(publicJwk.kty, "RSA");
    assert.equal(publicJwk.alg, "RS256");
    assert.equal(privateJwk.alg, "RS256");
    const jwkPublic = await crypto.subtle.importKey("jwk", publicJwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, true, ["verify"]);
    const jwkPrivate = await crypto.subtle.importKey("jwk", privateJwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, true, ["sign"]);
    const jwkPublicNoUsages = await crypto.subtle.importKey("jwk", publicJwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, true, []);
    assert.deepEqual(jwkPublicNoUsages.usages, []);
    const jwkSignature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", jwkPrivate, data);
    assert.equal(await crypto.subtle.verify("RSASSA-PKCS1-v1_5", jwkPublic, jwkSignature, data), true);

    const rsassa224 = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 1024, publicExponent, hash: "SHA-224" }, true, ["sign", "verify"]);
    const rsassa224Jwk = await crypto.subtle.exportKey("jwk", rsassa224.publicKey);
    assert.equal(rsassa224Jwk.alg, "RS224");
    const rsassa224Signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", rsassa224.privateKey, data);
    assert.equal(await crypto.subtle.verify("RSASSA-PKCS1-v1_5", rsassa224.publicKey, rsassa224Signature, data), true);

    const rsassaSha3 = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 1024, publicExponent, hash: "SHA3-256" }, true, ["sign", "verify"]);
    const rsassaSha3Signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", rsassaSha3.privateKey, data);
    assert.equal(await crypto.subtle.verify("RSASSA-PKCS1-v1_5", rsassaSha3.publicKey, rsassaSha3Signature, data), true);
    const rsassaSha3Jwk = await crypto.subtle.exportKey("jwk", rsassaSha3.publicKey);
    const rsassaSha3PrivateJwk = await crypto.subtle.exportKey("jwk", rsassaSha3.privateKey);
    assert.equal(Object.hasOwn(rsassaSha3Jwk, "alg"), false);
    assert.equal(Object.hasOwn(rsassaSha3PrivateJwk, "alg"), false);
    const rsassaSha3Imported = await crypto.subtle.importKey("jwk", rsassaSha3Jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA3-256" }, true, ["verify"]);
    const rsassaSha3PrivateImported = await crypto.subtle.importKey("jwk", rsassaSha3PrivateJwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA3-256" }, true, ["sign"]);
    assert.equal(await crypto.subtle.verify("RSASSA-PKCS1-v1_5", rsassaSha3Imported, rsassaSha3Signature, data), true);
    const rsassaSha3ImportedSignature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", rsassaSha3PrivateImported, data);
    assert.equal(await crypto.subtle.verify("RSASSA-PKCS1-v1_5", rsassaSha3.publicKey, rsassaSha3ImportedSignature, data), true);
    await expectRejectsName(crypto.subtle.importKey("jwk", { ...rsassaSha3Jwk, alg: "RS256" }, { name: "RSASSA-PKCS1-v1_5", hash: "SHA3-256" }, true, ["verify"]), "DataError");
    for (const hash of ["SHA3-224", "SHA3-384", "SHA3-512"]) {
      const pair = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 1024, publicExponent, hash }, true, ["sign", "verify"]);
      const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", pair.privateKey, data);
      assert.equal(await crypto.subtle.verify("RSASSA-PKCS1-v1_5", pair.publicKey, sig, data), true, `RSASSA ${hash}`);
      const sha3Jwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
      assert.equal(Object.hasOwn(sha3Jwk, "alg"), false, `RSASSA ${hash} JWK alg`);
      if (hash === "SHA3-224") {
        const imported = await crypto.subtle.importKey("jwk", sha3Jwk, { name: "RSASSA-PKCS1-v1_5", hash }, true, ["verify"]);
        assert.equal(await crypto.subtle.verify("RSASSA-PKCS1-v1_5", imported, sig, data), true, `RSASSA ${hash} JWK import`);
      }
    }

    const pss = await crypto.subtle.generateKey({ name: "RSA-PSS", modulusLength: 1024, publicExponent, hash: "SHA-256" }, true, ["sign", "verify"]);
    const pssSignature = await crypto.subtle.sign({ name: "RSA-PSS", saltLength: 32 }, pss.privateKey, data);
    assert.equal(await crypto.subtle.verify({ name: "RSA-PSS", saltLength: 32 }, pss.publicKey, pssSignature, data), true);
    assert.equal(await crypto.subtle.verify({ name: "RSA-PSS", saltLength: 31 }, pss.publicKey, pssSignature, data), false);

    const pss224 = await crypto.subtle.generateKey({ name: "RSA-PSS", modulusLength: 1024, publicExponent, hash: "SHA-224" }, true, ["sign", "verify"]);
    assert.equal((await crypto.subtle.exportKey("jwk", pss224.publicKey)).alg, "PS224");
    const pss224Signature = await crypto.subtle.sign({ name: "RSA-PSS", saltLength: 28 }, pss224.privateKey, data);
    assert.equal(await crypto.subtle.verify({ name: "RSA-PSS", saltLength: 28 }, pss224.publicKey, pss224Signature, data), true);

    const pssSha3 = await crypto.subtle.generateKey({ name: "RSA-PSS", modulusLength: 1024, publicExponent, hash: "SHA3-256" }, true, ["sign", "verify"]);
    const pssSha3Signature = await crypto.subtle.sign({ name: "RSA-PSS", saltLength: 32 }, pssSha3.privateKey, data);
    assert.equal(await crypto.subtle.verify({ name: "RSA-PSS", saltLength: 32 }, pssSha3.publicKey, pssSha3Signature, data), true);
    assert.equal(await crypto.subtle.verify({ name: "RSA-PSS", saltLength: 31 }, pssSha3.publicKey, pssSha3Signature, data), false);
    const pssSha3Jwk = await crypto.subtle.exportKey("jwk", pssSha3.publicKey);
    const pssSha3PrivateJwk = await crypto.subtle.exportKey("jwk", pssSha3.privateKey);
    assert.equal(Object.hasOwn(pssSha3Jwk, "alg"), false);
    assert.equal(Object.hasOwn(pssSha3PrivateJwk, "alg"), false);
    const pssSha3Imported = await crypto.subtle.importKey("jwk", pssSha3Jwk, { name: "RSA-PSS", hash: "SHA3-256" }, true, ["verify"]);
    const pssSha3PrivateImported = await crypto.subtle.importKey("jwk", pssSha3PrivateJwk, { name: "RSA-PSS", hash: "SHA3-256" }, true, ["sign"]);
    assert.equal(await crypto.subtle.verify({ name: "RSA-PSS", saltLength: 32 }, pssSha3Imported, pssSha3Signature, data), true);
    const pssSha3ImportedSignature = await crypto.subtle.sign({ name: "RSA-PSS", saltLength: 32 }, pssSha3PrivateImported, data);
    assert.equal(await crypto.subtle.verify({ name: "RSA-PSS", saltLength: 32 }, pssSha3.publicKey, pssSha3ImportedSignature, data), true);
    await expectRejectsName(crypto.subtle.importKey("jwk", { ...pssSha3Jwk, alg: "PS256" }, { name: "RSA-PSS", hash: "SHA3-256" }, true, ["verify"]), "DataError");
    for (const [hash, saltLength] of [["SHA3-224", 28], ["SHA3-384", 48], ["SHA3-512", 32]]) {
      const pair = await crypto.subtle.generateKey({ name: "RSA-PSS", modulusLength: 1024, publicExponent, hash }, true, ["sign", "verify"]);
      const sig = await crypto.subtle.sign({ name: "RSA-PSS", saltLength }, pair.privateKey, data);
      assert.equal(await crypto.subtle.verify({ name: "RSA-PSS", saltLength }, pair.publicKey, sig, data), true, `RSA-PSS ${hash}`);
      assert.equal(await crypto.subtle.verify({ name: "RSA-PSS", saltLength: saltLength - 1 }, pair.publicKey, sig, data), false, `RSA-PSS ${hash} wrong salt`);
      const sha3Jwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
      assert.equal(Object.hasOwn(sha3Jwk, "alg"), false, `RSA-PSS ${hash} JWK alg`);
      if (hash === "SHA3-224") {
        const imported = await crypto.subtle.importKey("jwk", sha3Jwk, { name: "RSA-PSS", hash }, true, ["verify"]);
        assert.equal(await crypto.subtle.verify({ name: "RSA-PSS", saltLength }, imported, sig, data), true, `RSA-PSS ${hash} JWK import`);
      }
    }

    await expectRejectsName(crypto.subtle.generateKey({ name: "RSA-PSS", modulusLength: 1024, publicExponent, hash: "SHA-256" }, true, ["encrypt"]), "SyntaxError");
    await expectRejectsName(crypto.subtle.generateKey({ name: "RSA-PSS", modulusLength: 1024, publicExponent, hash: "SHA-256" }, true, ["verify"]), "SyntaxError");
    await expectRejectsName(crypto.subtle.generateKey({ name: "RSA-PSS", modulusLength: 1024, publicExponent, hash: "SHA-256" }, true, []), "SyntaxError");
    await expectRejectsName(crypto.subtle.generateKey({ name: "RSA-PSS", modulusLength: 512, publicExponent, hash: "SHA-256" }, true, ["sign"]), "OperationError");
    await expectRejectsName(crypto.subtle.generateKey({ name: "RSA-PSS", modulusLength: 16384, publicExponent, hash: "SHA-256" }, true, ["sign"]), "OperationError");
    await expectRejectsName(crypto.subtle.sign("RSASSA-PKCS1-v1_5", rsassa.publicKey, data), "InvalidAccessError");
    await expectRejectsName(crypto.subtle.importKey("pkcs8", pkcs8, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, true, []), "SyntaxError");
    await expectRejectsName(crypto.subtle.importKey("jwk", privateJwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, true, []), "SyntaxError");
    await expectRejectsName(crypto.subtle.importKey("jwk", { ...publicJwk, alg: "RS384" }, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, true, ["verify"]), "DataError");
    await expectRejectsName(crypto.subtle.importKey("jwk", { ...publicJwk, n: "A".repeat(1368) }, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, true, ["verify"]), "DataError");
  });

  test("subtle RSA-OAEP generates, imports, exports, encrypts, decrypts, wraps, and unwraps", async () => {
    const publicExponent = new Uint8Array([1, 0, 1]);
    const label = new TextEncoder().encode("label");
    const plaintext = new TextEncoder().encode("rsa oaep");
    const pair = await crypto.subtle.generateKey({ name: "RSA-OAEP", modulusLength: 1024, publicExponent, hash: "SHA-256" }, true, ["encrypt", "decrypt", "wrapKey", "unwrapKey"]);
    assert.deepEqual(pair.publicKey.usages, ["encrypt", "wrapKey"]);
    assert.deepEqual(pair.privateKey.usages, ["decrypt", "unwrapKey"]);

    const encrypted = await crypto.subtle.encrypt({ name: "RSA-OAEP", label }, pair.publicKey, plaintext);
    assert.equal(new TextDecoder().decode(await crypto.subtle.decrypt({ name: "RSA-OAEP", label }, pair.privateKey, encrypted)), "rsa oaep");
    await expectRejectsName(crypto.subtle.decrypt({ name: "RSA-OAEP", label: new Uint8Array([1]) }, pair.privateKey, encrypted), "OperationError");

    const aesKeyData = new Uint8Array(16).fill(9);
    const aesKey = await crypto.subtle.importKey("raw", aesKeyData, { name: "AES-GCM" }, true, ["encrypt"]);
    const wrapped = await crypto.subtle.wrapKey("raw", aesKey, pair.publicKey, { name: "RSA-OAEP" });
    const unwrapped = await crypto.subtle.unwrapKey("raw", wrapped, pair.privateKey, { name: "RSA-OAEP" }, { name: "AES-GCM" }, true, ["encrypt"]);
    assert.deepEqual(Array.from(new Uint8Array(await crypto.subtle.exportKey("raw", unwrapped))), Array.from(aesKeyData));

    const spki = await crypto.subtle.exportKey("spki", pair.publicKey);
    const pkcs8 = await crypto.subtle.exportKey("pkcs8", pair.privateKey);
    const importedPublic = await crypto.subtle.importKey("spki", spki, { name: "RSA-OAEP", hash: "SHA-256" }, true, ["encrypt", "wrapKey"]);
    const importedPrivate = await crypto.subtle.importKey("pkcs8", pkcs8, { name: "RSA-OAEP", hash: "SHA-256" }, true, ["decrypt", "unwrapKey"]);
    const importedEncrypted = await crypto.subtle.encrypt("RSA-OAEP", importedPublic, plaintext);
    assert.equal(new TextDecoder().decode(await crypto.subtle.decrypt("RSA-OAEP", importedPrivate, importedEncrypted)), "rsa oaep");

    const publicJwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
    const privateJwk = await crypto.subtle.exportKey("jwk", pair.privateKey);
    assert.equal(publicJwk.alg, "RSA-OAEP-256");
    assert.equal(privateJwk.alg, "RSA-OAEP-256");
    const jwkPublic = await crypto.subtle.importKey("jwk", publicJwk, { name: "RSA-OAEP", hash: "SHA-256" }, true, ["encrypt"]);
    const jwkPrivate = await crypto.subtle.importKey("jwk", privateJwk, { name: "RSA-OAEP", hash: "SHA-256" }, true, ["decrypt"]);
    const jwkEncrypted = await crypto.subtle.encrypt("RSA-OAEP", jwkPublic, plaintext);
    assert.equal(new TextDecoder().decode(await crypto.subtle.decrypt("RSA-OAEP", jwkPrivate, jwkEncrypted)), "rsa oaep");

    const oaep224 = await crypto.subtle.generateKey({ name: "RSA-OAEP", modulusLength: 1024, publicExponent, hash: "SHA-224" }, true, ["encrypt", "decrypt"]);
    assert.equal((await crypto.subtle.exportKey("jwk", oaep224.publicKey)).alg, "RSA-OAEP-224");
    const oaep224Encrypted = await crypto.subtle.encrypt("RSA-OAEP", oaep224.publicKey, plaintext);
    assert.equal(new TextDecoder().decode(await crypto.subtle.decrypt("RSA-OAEP", oaep224.privateKey, oaep224Encrypted)), "rsa oaep");

    const oaepSha3 = await crypto.subtle.generateKey({ name: "RSA-OAEP", modulusLength: 1024, publicExponent, hash: "SHA3-256" }, true, ["encrypt", "decrypt"]);
    const oaepSha3Encrypted = await crypto.subtle.encrypt("RSA-OAEP", oaepSha3.publicKey, plaintext);
    assert.equal(new TextDecoder().decode(await crypto.subtle.decrypt("RSA-OAEP", oaepSha3.privateKey, oaepSha3Encrypted)), "rsa oaep");
    const oaepSha3Jwk = await crypto.subtle.exportKey("jwk", oaepSha3.publicKey);
    const oaepSha3PrivateJwk = await crypto.subtle.exportKey("jwk", oaepSha3.privateKey);
    assert.equal(Object.hasOwn(oaepSha3Jwk, "alg"), false);
    assert.equal(Object.hasOwn(oaepSha3PrivateJwk, "alg"), false);
    const oaepSha3Imported = await crypto.subtle.importKey("jwk", oaepSha3Jwk, { name: "RSA-OAEP", hash: "SHA3-256" }, true, ["encrypt"]);
    const oaepSha3PrivateImported = await crypto.subtle.importKey("jwk", oaepSha3PrivateJwk, { name: "RSA-OAEP", hash: "SHA3-256" }, true, ["decrypt"]);
    const importedOaepSha3Encrypted = await crypto.subtle.encrypt("RSA-OAEP", oaepSha3Imported, plaintext);
    assert.equal(new Uint8Array(importedOaepSha3Encrypted).length, 128);
    assert.equal(new TextDecoder().decode(await crypto.subtle.decrypt("RSA-OAEP", oaepSha3PrivateImported, importedOaepSha3Encrypted)), "rsa oaep");
    await expectRejectsName(crypto.subtle.importKey("jwk", { ...oaepSha3Jwk, alg: "RSA-OAEP-256" }, { name: "RSA-OAEP", hash: "SHA3-256" }, true, ["encrypt"]), "DataError");
    for (const [hash, modulusLength] of [["SHA3-224", 1024], ["SHA3-384", 1024], ["SHA3-512", 2048]]) {
      const pair = await crypto.subtle.generateKey({ name: "RSA-OAEP", modulusLength, publicExponent, hash }, true, ["encrypt", "decrypt"]);
      const encrypted = await crypto.subtle.encrypt("RSA-OAEP", pair.publicKey, plaintext);
      assert.equal(new TextDecoder().decode(await crypto.subtle.decrypt("RSA-OAEP", pair.privateKey, encrypted)), "rsa oaep", `RSA-OAEP ${hash}`);
      const sha3Jwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
      assert.equal(Object.hasOwn(sha3Jwk, "alg"), false, `RSA-OAEP ${hash} JWK alg`);
      if (hash === "SHA3-224") {
        const imported = await crypto.subtle.importKey("jwk", sha3Jwk, { name: "RSA-OAEP", hash }, true, ["encrypt"]);
        const importedEncrypted = await crypto.subtle.encrypt("RSA-OAEP", imported, plaintext);
        assert.equal(new TextDecoder().decode(await crypto.subtle.decrypt("RSA-OAEP", pair.privateKey, importedEncrypted)), "rsa oaep", `RSA-OAEP ${hash} JWK import`);
      }
    }

    await expectRejectsName(crypto.subtle.generateKey({ name: "RSA-OAEP", modulusLength: 1024, publicExponent, hash: "SHA-256" }, true, ["sign"]), "SyntaxError");
    await expectRejectsName(crypto.subtle.encrypt("RSA-OAEP", pair.privateKey, plaintext), "InvalidAccessError");
    await expectRejectsName(crypto.subtle.sign("RSA-OAEP", pair.privateKey, plaintext), "NotSupportedError");
  });

  test("subtle RSAES-PKCS1-v1_5 generates, imports, exports, encrypts, and decrypts", async () => {
    const publicExponent = new Uint8Array([1, 0, 1]);
    const plaintext = new TextEncoder().encode("rsaes pkcs1");
    const pair = await crypto.subtle.generateKey({ name: "RSAES-PKCS1-v1_5", modulusLength: 1024, publicExponent }, true, ["encrypt", "decrypt"]);

    assert.deepEqual(pair.publicKey.algorithm, {
      name: "RSAES-PKCS1-v1_5",
      modulusLength: 1024,
      publicExponent: new Uint8Array([1, 0, 1]),
    });
    assert.equal(Object.hasOwn(pair.publicKey.algorithm, "hash"), false);
    assert.deepEqual(pair.publicKey.usages, ["encrypt"]);
    assert.deepEqual(pair.privateKey.usages, ["decrypt"]);

    const encrypted = await crypto.subtle.encrypt("RSAES-PKCS1-v1_5", pair.publicKey, plaintext);
    assert.equal(new Uint8Array(encrypted).length, 128);
    assert.equal(new TextDecoder().decode(await crypto.subtle.decrypt("RSAES-PKCS1-v1_5", pair.privateKey, encrypted)), "rsaes pkcs1");

    const publicJwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
    const privateJwk = await crypto.subtle.exportKey("jwk", pair.privateKey);
    assert.equal(publicJwk.alg, "RSA1_5");
    assert.equal(privateJwk.alg, "RSA1_5");
    assert.deepEqual(publicJwk.key_ops, ["encrypt"]);
    assert.deepEqual(privateJwk.key_ops, ["decrypt"]);

    const jwkPublic = await crypto.subtle.importKey("jwk", { ...publicJwk, use: "enc" }, "RSAES-PKCS1-v1_5", true, ["encrypt"]);
    const jwkPrivate = await crypto.subtle.importKey("jwk", { ...privateJwk, use: "enc" }, "RSAES-PKCS1-v1_5", true, ["decrypt"]);
    const jwkEncrypted = await crypto.subtle.encrypt("RSAES-PKCS1-v1_5", jwkPublic, plaintext);
    assert.equal(new TextDecoder().decode(await crypto.subtle.decrypt("RSAES-PKCS1-v1_5", jwkPrivate, jwkEncrypted)), "rsaes pkcs1");

    const spki = await crypto.subtle.exportKey("spki", pair.publicKey);
    const pkcs8 = await crypto.subtle.exportKey("pkcs8", pair.privateKey);
    const spkiPublic = await crypto.subtle.importKey("spki", spki, "RSAES-PKCS1-v1_5", true, ["encrypt"]);
    const pkcs8Private = await crypto.subtle.importKey("pkcs8", pkcs8, "RSAES-PKCS1-v1_5", true, ["decrypt"]);
    const derEncrypted = await crypto.subtle.encrypt("RSAES-PKCS1-v1_5", spkiPublic, plaintext);
    assert.equal(new TextDecoder().decode(await crypto.subtle.decrypt("RSAES-PKCS1-v1_5", pkcs8Private, derEncrypted)), "rsaes pkcs1");

    await expectRejectsName(crypto.subtle.generateKey({ name: "RSAES-PKCS1-v1_5", modulusLength: 1024, publicExponent }, true, ["wrapKey"]), "SyntaxError");
    await expectRejectsName(crypto.subtle.generateKey({ name: "RSAES-PKCS1-v1_5", modulusLength: 512, publicExponent }, true, ["encrypt", "decrypt"]), "OperationError");
    await expectRejectsName(crypto.subtle.encrypt("RSAES-PKCS1-v1_5", pair.privateKey, plaintext), "InvalidAccessError");
    await expectRejectsName(crypto.subtle.sign("RSAES-PKCS1-v1_5", pair.privateKey, plaintext), "NotSupportedError");
    await expectRejectsName(crypto.subtle.importKey("jwk", { ...publicJwk, use: "sig" }, "RSAES-PKCS1-v1_5", true, ["encrypt"]), "DataError");
  });

  test("subtle RSA import rejects undersized JWK, DER, and unwrapped keys", async () => {
    const rsa512PublicJwk = {
      kty: "RSA",
      n: "t50-PAnbWllBBwQWzCfKXb1664EThp7ZanCIFTzWU5vX5ACQOcwHkHXAXqSPDs3xMy5hotLQE6MlN4XHh3i4ww",
      e: "AQAB",
    };
    const rsa512PrivateJwk = {
      ...rsa512PublicJwk,
      d: "suhLCJMOIaWP__cTA4_N1bLXf3sAfI5xCA5n-lGSAFnUkHKd1YYmHK0z9w2Jon3Vwa9WR9fox8RSUEATVkMIyQ",
      p: "6uXKBDj8nqPcMzkz1-F05o0uFH9AfZxWkJkGeNVvgZ0",
      q: "yBwH7fo-W_W_Op3oTtkQzJd58fyPRNEad99jg9Qtxd8",
      dp: "PxXh0IqBhhWZ8QPe4Y7Cd5zZEFYwust_ECyY6WDhJp0",
      dq: "iA4--fgOFBpXRbR9cba2bFSFbhlpE8IUe_JfyA8ofAM",
      qi: "GKOcAIjp9FvFH_y3lmmRepviDIng8ZS1gKhhXD8QE6o",
    };
    const rsa512Spki = fromHex(
      "305c300d06092a864886f70d0101010500034b003048024100b79d3e3c09db5a5941070416cc27ca5dbd7aeb8113869ed96a7088153cd6539bd7e4009039cc079075c05ea48f0ecdf1332e61a2d2d013a3253785c78778b8c30203010001",
    );
    const rsa512Pkcs8 = fromHex(
      "30820155020100300d06092a864886f70d01010105000482013f3082013b020100024100b79d3e3c09db5a5941070416cc27ca5dbd7aeb8113869ed96a7088153cd6539bd7e4009039cc079075c05ea48f0ecdf1332e61a2d2d013a3253785c78778b8c30203010001024100b2e84b08930e21a58ffff713038fcdd5b2d77f7b007c8e71080e67fa51920059d490729dd586261cad33f70d89a27dd5c1af5647d7e8c7c452504013564308c9022100eae5ca0438fc9ea3dc333933d7e174e68d2e147f407d9c5690990678d56f819d022100c81c07edfa3e5bf5bf3a9de84ed910cc9779f1fc8f44d11a77df6383d42dc5df02203f15e1d08a81861599f103dee18ec2779cd9105630bacb7f102c98e960e1269d022100880e3ef9f80e141a5745b47d71b6b66c54856e196913c2147bf25fc80f287c03022018a39c0088e9f45bc51ffcb79669917a9be20c89e0f194b580a8615c3f1013aa",
    );
    const specs = [
      { algorithm: { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, alg: "RS256", use: "sig", publicUsages: ["verify"], privateUsages: ["sign"] },
      { algorithm: { name: "RSA-PSS", hash: "SHA-256" }, alg: "PS256", use: "sig", publicUsages: ["verify"], privateUsages: ["sign"] },
      { algorithm: { name: "RSA-OAEP", hash: "SHA-256" }, alg: "RSA-OAEP-256", use: "enc", publicUsages: ["encrypt"], privateUsages: ["decrypt"] },
      { algorithm: "RSAES-PKCS1-v1_5", alg: "RSA1_5", use: "enc", publicUsages: ["encrypt"], privateUsages: ["decrypt"] },
    ];
    const encoder = new TextEncoder();
    const wrappingKeyBytes = new Uint8Array(16).fill(15);
    const encryptKey = await crypto.subtle.importKey("raw", wrappingKeyBytes, { name: "AES-GCM" }, false, ["encrypt"]);
    const unwrapKey = await crypto.subtle.importKey("raw", wrappingKeyBytes, { name: "AES-GCM" }, false, ["unwrapKey"]);
    let ivCounter = 0;

    async function encryptForUnwrap(data) {
      const iv = new Uint8Array(12);
      iv[11] = ++ivCounter;
      return {
        iv,
        wrapped: await crypto.subtle.encrypt({ name: "AES-GCM", iv }, encryptKey, data),
      };
    }

    async function expectUndersizedUnwrap(format, data, algorithm, usages) {
      const { iv, wrapped } = await encryptForUnwrap(data);
      await expectRejectsName(
        crypto.subtle.unwrapKey(format, wrapped, unwrapKey, { name: "AES-GCM", iv }, algorithm, true, usages),
        "DataError",
      );
    }

    for (const { algorithm, alg, use, publicUsages, privateUsages } of specs) {
      const publicJwk = { ...rsa512PublicJwk, alg, use, ext: true, key_ops: publicUsages };
      const privateJwk = { ...rsa512PrivateJwk, alg, use, ext: true, key_ops: privateUsages };

      await expectRejectsName(crypto.subtle.importKey("jwk", publicJwk, algorithm, true, publicUsages), "DataError");
      await expectRejectsName(crypto.subtle.importKey("jwk", privateJwk, algorithm, true, privateUsages), "DataError");
      await expectRejectsName(crypto.subtle.importKey("spki", rsa512Spki, algorithm, true, publicUsages), "DataError");
      await expectRejectsName(crypto.subtle.importKey("pkcs8", rsa512Pkcs8, algorithm, true, privateUsages), "DataError");

      await expectUndersizedUnwrap("jwk", encoder.encode(JSON.stringify(publicJwk)), algorithm, publicUsages);
      await expectUndersizedUnwrap("jwk", encoder.encode(JSON.stringify(privateJwk)), algorithm, privateUsages);
      await expectUndersizedUnwrap("spki", rsa512Spki, algorithm, publicUsages);
      await expectUndersizedUnwrap("pkcs8", rsa512Pkcs8, algorithm, privateUsages);
    }
  });

  test("subtle ECDSA generates, imports, exports, signs, and verifies", async () => {
    const data = new TextEncoder().encode("collo ecdsa signing");
    const curves = [
      ["P-256", "SHA-256", 65, 64],
      ["P-384", "SHA-384", 97, 96],
      ["P-521", "SHA-512", 133, 132],
    ];

    for (const [namedCurve, hash, rawLength, signatureLength] of curves) {
      const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve }, true, ["sign", "verify"]);
      assert(pair.publicKey instanceof CryptoKey);
      assert(pair.privateKey instanceof CryptoKey);
      assert.equal(pair.publicKey.type, "public");
      assert.equal(pair.privateKey.type, "private");
      assert.deepEqual(pair.publicKey.usages, ["verify"]);
      assert.deepEqual(pair.privateKey.usages, ["sign"]);
      assert.deepEqual(pair.publicKey.algorithm, { name: "ECDSA", namedCurve });
      assert.deepEqual(pair.privateKey.algorithm, { name: "ECDSA", namedCurve });

      const signature = await crypto.subtle.sign({ name: "ECDSA", hash }, pair.privateKey, data);
      assert.equal(new Uint8Array(signature).length, signatureLength);
      assert.equal(await crypto.subtle.verify({ name: "ECDSA", hash }, pair.publicKey, signature, data), true);
      assert.equal(await crypto.subtle.verify({ name: "ECDSA", hash }, pair.publicKey, signature, new Uint8Array([1])), false);

      const raw = await crypto.subtle.exportKey("raw", pair.publicKey);
      assert.equal(new Uint8Array(raw)[0], 4);
      assert.equal(raw.byteLength, rawLength);
      const rawPublic = await crypto.subtle.importKey("raw", raw, { name: "ECDSA", namedCurve }, true, ["verify"]);
      assert.equal(await crypto.subtle.verify({ name: "ECDSA", hash }, rawPublic, signature, data), true);
      await expectRejectsName(crypto.subtle.exportKey("raw", pair.privateKey), "InvalidAccessError");

      const spki = await crypto.subtle.exportKey("spki", pair.publicKey);
      const pkcs8 = await crypto.subtle.exportKey("pkcs8", pair.privateKey);
      const spkiPublic = await crypto.subtle.importKey("spki", spki, { name: "ECDSA", namedCurve }, true, ["verify"]);
      const pkcs8Private = await crypto.subtle.importKey("pkcs8", pkcs8, { name: "ECDSA", namedCurve }, true, ["sign"]);
      const importedSignature = await crypto.subtle.sign({ name: "ECDSA", hash }, pkcs8Private, data);
      assert.equal(await crypto.subtle.verify({ name: "ECDSA", hash }, spkiPublic, importedSignature, data), true);
    }

    const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
    const publicJwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
    const privateJwk = await crypto.subtle.exportKey("jwk", pair.privateKey);
    assert.equal(publicJwk.kty, "EC");
    assert.equal(publicJwk.crv, "P-256");
    assert.equal(privateJwk.kty, "EC");
    assert.equal(privateJwk.crv, "P-256");
    assert.equal(typeof publicJwk.x, "string");
    assert.equal(typeof publicJwk.y, "string");
    assert.equal(typeof privateJwk.d, "string");
    assert.deepEqual(publicJwk.key_ops, ["verify"]);
    assert.deepEqual(privateJwk.key_ops, ["sign"]);

    const jwkPublic = await crypto.subtle.importKey("jwk", publicJwk, { name: "ECDSA", namedCurve: "P-256" }, true, ["verify"]);
    const jwkPrivate = await crypto.subtle.importKey("jwk", privateJwk, { name: "ECDSA", namedCurve: "P-256" }, true, ["sign"]);
    const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, jwkPrivate, data);
    assert.equal(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, jwkPublic, signature, data), true);
    const sha224Signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-224" }, jwkPrivate, data);
    assert.equal(sha224Signature.byteLength, 64);
    assert.equal(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-224" }, jwkPublic, sha224Signature, data), true);
    for (const hash of ["SHA3-224", "SHA3-256", "SHA3-384", "SHA3-512"]) {
      const sha3Signature = await crypto.subtle.sign({ name: "ECDSA", hash }, jwkPrivate, data);
      assert.equal(sha3Signature.byteLength, 64, `ECDSA ${hash} length`);
      assert.equal(await crypto.subtle.verify({ name: "ECDSA", hash }, jwkPublic, sha3Signature, data), true, `ECDSA ${hash}`);
    }

    const wrappingKey = await crypto.subtle.importKey("raw", new Uint8Array(16).fill(11), { name: "AES-GCM" }, false, ["wrapKey", "unwrapKey"]);
    const iv = new Uint8Array(12).fill(12);
    const wrappedPrivate = await crypto.subtle.wrapKey("jwk", pair.privateKey, wrappingKey, { name: "AES-GCM", iv });
    const unwrappedPrivate = await crypto.subtle.unwrapKey("jwk", wrappedPrivate, wrappingKey, { name: "AES-GCM", iv }, { name: "ECDSA", namedCurve: "P-256" }, true, ["sign"]);
    const unwrappedSignature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, unwrappedPrivate, data);
    assert.equal(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pair.publicKey, unwrappedSignature, data), true);

    await expectRejectsName(crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, []), "SyntaxError");
    await expectRejectsName(crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-224" }, true, ["sign"]), "NotSupportedError");
    await expectRejectsName(crypto.subtle.sign("ECDSA", pair.privateKey, data), "TypeError");
    await expectRejectsName(crypto.subtle.sign({ name: "ECDSA", hash: "SHA-999" }, pair.privateKey, data), "NotSupportedError");
    await expectRejectsName(crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.publicKey, data), "InvalidAccessError");
    await expectRejectsName(crypto.subtle.importKey("pkcs8", await crypto.subtle.exportKey("pkcs8", pair.privateKey), { name: "ECDSA", namedCurve: "P-256" }, true, []), "SyntaxError");
    await expectRejectsName(crypto.subtle.importKey("jwk", { ...publicJwk, crv: "P-384" }, { name: "ECDSA", namedCurve: "P-256" }, true, ["verify"]), "DataError");
    await expectRejectsName(crypto.subtle.importKey("jwk", { ...publicJwk, x: publicJwk.x.slice(2) }, { name: "ECDSA", namedCurve: "P-256" }, true, ["verify"]), "DataError");
    await expectRejectsName(crypto.subtle.importKey("jwk", { ...privateJwk, d: privateJwk.d.slice(2) }, { name: "ECDSA", namedCurve: "P-256" }, true, ["sign"]), "DataError");
    await expectRejectsName(crypto.subtle.importKey("jwk", privateJwk, { name: "ECDSA", namedCurve: "P-256" }, true, []), "SyntaxError");
    await expectRejectsName(crypto.subtle.importKey("jwk", { ...publicJwk, key_ops: ["sign"] }, { name: "ECDSA", namedCurve: "P-256" }, true, ["verify"]), "DataError");
  });

  test("subtle ECDH generates, imports, exports, derives, and unwraps derived keys", async () => {
    const alice = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits", "deriveKey"]);
    const bob = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits", "deriveKey"]);
    assert.deepEqual(alice.publicKey.usages, []);
    assert.deepEqual(alice.privateKey.usages, ["deriveKey", "deriveBits"]);
    assert.deepEqual(alice.publicKey.algorithm, { name: "ECDH", namedCurve: "P-256" });
    assert.deepEqual(alice.privateKey.algorithm, { name: "ECDH", namedCurve: "P-256" });

    const aliceBits = await crypto.subtle.deriveBits({ name: "ECDH", public: bob.publicKey }, alice.privateKey, 256);
    const bobBits = await crypto.subtle.deriveBits({ name: "ECDH", public: alice.publicKey }, bob.privateKey, 256);
    assert.equal(aliceBits.byteLength, 32);
    assert.equal(hex(aliceBits), hex(bobBits));

    assert.equal((await crypto.subtle.deriveBits({ name: "ECDH", public: bob.publicKey }, alice.privateKey, null)).byteLength, 32);
    assert.equal((await crypto.subtle.deriveBits({ name: "ECDH", public: bob.publicKey }, alice.privateKey, 0)).byteLength, 32);
    assert.equal((await crypto.subtle.deriveBits({ name: "ECDH", public: bob.publicKey }, alice.privateKey, 1)).byteLength, 1);
    assert.equal((await crypto.subtle.deriveBits({ name: "ECDH", public: bob.publicKey }, alice.privateKey, 128)).byteLength, 16);

    const derivedKey = await crypto.subtle.deriveKey({ name: "ECDH", public: bob.publicKey }, alice.privateKey, { name: "AES-GCM", length: 128 }, true, ["encrypt"]);
    assert.deepEqual(derivedKey.algorithm, { name: "AES-GCM", length: 128 });
    assert.deepEqual(derivedKey.usages, ["encrypt"]);
    assert.equal((await crypto.subtle.exportKey("raw", derivedKey)).byteLength, 16);

    const rawPublic = await crypto.subtle.exportKey("raw", alice.publicKey);
    assert.equal(new Uint8Array(rawPublic)[0], 4);
    assert.equal(rawPublic.byteLength, 65);
    const rawImportedPublic = await crypto.subtle.importKey("raw", rawPublic, { name: "ECDH", namedCurve: "P-256" }, true, []);
    assert.equal(hex(await crypto.subtle.deriveBits({ name: "ECDH", public: rawImportedPublic }, bob.privateKey, 256)), hex(bobBits));
    await expectRejectsName(crypto.subtle.exportKey("raw", alice.privateKey), "InvalidAccessError");

    const spki = await crypto.subtle.exportKey("spki", alice.publicKey);
    const pkcs8 = await crypto.subtle.exportKey("pkcs8", alice.privateKey);
    const spkiPublic = await crypto.subtle.importKey("spki", spki, { name: "ECDH", namedCurve: "P-256" }, true, []);
    const pkcs8Private = await crypto.subtle.importKey("pkcs8", pkcs8, { name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
    assert.equal(hex(await crypto.subtle.deriveBits({ name: "ECDH", public: bob.publicKey }, pkcs8Private, 256)), hex(aliceBits));
    assert.equal(hex(await crypto.subtle.deriveBits({ name: "ECDH", public: spkiPublic }, bob.privateKey, 256)), hex(bobBits));

    const publicJwk = await crypto.subtle.exportKey("jwk", alice.publicKey);
    const privateJwk = await crypto.subtle.exportKey("jwk", alice.privateKey);
    assert.equal(publicJwk.kty, "EC");
    assert.equal(publicJwk.crv, "P-256");
    assert.deepEqual(publicJwk.key_ops, []);
    assert.deepEqual(privateJwk.key_ops, ["deriveKey", "deriveBits"]);
    const jwkPublic = await crypto.subtle.importKey("jwk", publicJwk, { name: "ECDH", namedCurve: "P-256" }, true, []);
    const jwkPrivate = await crypto.subtle.importKey("jwk", privateJwk, { name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
    assert.equal(hex(await crypto.subtle.deriveBits({ name: "ECDH", public: bob.publicKey }, jwkPrivate, 256)), hex(aliceBits));
    assert.equal(hex(await crypto.subtle.deriveBits({ name: "ECDH", public: jwkPublic }, bob.privateKey, 256)), hex(bobBits));

    const wrappingKey = await crypto.subtle.importKey("raw", new Uint8Array(16).fill(5), { name: "AES-GCM" }, false, ["wrapKey", "unwrapKey"]);
    const iv = new Uint8Array(12).fill(6);
    const wrapped = await crypto.subtle.wrapKey("jwk", alice.publicKey, wrappingKey, { name: "AES-GCM", iv });
    const unwrapped = await crypto.subtle.unwrapKey("jwk", wrapped, wrappingKey, { name: "AES-GCM", iv }, { name: "ECDH", namedCurve: "P-256" }, true, []);
    assert.equal(hex(await crypto.subtle.deriveBits({ name: "ECDH", public: unwrapped }, bob.privateKey, 256)), hex(bobBits));

    const p384 = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-384" }, true, ["deriveBits"]);
    await expectRejectsName(crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, []), "SyntaxError");
    await expectRejectsName(crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-224" }, true, ["deriveBits"]), "NotSupportedError");
    await expectRejectsName(crypto.subtle.deriveBits({ name: "ECDH", public: bob.publicKey }, alice.publicKey, 256), "InvalidAccessError");
    // Per the WebCrypto spec, a mismatch between the public and private key's
    // named curves is an InvalidAccessError (not OperationError).
    await expectRejectsName(crypto.subtle.deriveBits({ name: "ECDH", public: p384.publicKey }, alice.privateKey, 256), "InvalidAccessError");
    await expectRejectsName(crypto.subtle.deriveBits({ name: "ECDH", public: bob.publicKey }, alice.privateKey, 264), "OperationError");
    await expectRejectsName(crypto.subtle.deriveBits({ name: "ECDH" }, alice.privateKey, 256), "TypeError");
    await expectRejectsName(crypto.subtle.importKey("jwk", { ...privateJwk, key_ops: ["verify"] }, { name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]), "DataError");
  });

  test("subtle Ed25519 generates, imports, exports, signs, verifies, and unwraps", async () => {
    const data = new TextEncoder().encode("collo ed25519 signing");
    const pair = await crypto.subtle.generateKey("Ed25519", true, ["sign", "verify"]);
    assert(pair.publicKey instanceof CryptoKey);
    assert(pair.privateKey instanceof CryptoKey);
    assert.equal(pair.publicKey.type, "public");
    assert.equal(pair.privateKey.type, "private");
    assert.deepEqual(pair.publicKey.algorithm, { name: "Ed25519" });
    assert.deepEqual(pair.privateKey.algorithm, { name: "Ed25519" });
    assert.deepEqual(pair.publicKey.usages, ["verify"]);
    assert.deepEqual(pair.privateKey.usages, ["sign"]);

    const signature = await crypto.subtle.sign("Ed25519", pair.privateKey, data);
    assert.equal(signature.byteLength, 64);
    assert.equal(await crypto.subtle.verify("Ed25519", pair.publicKey, signature, data), true);
    assert.equal(await crypto.subtle.verify("Ed25519", pair.publicKey, signature, new Uint8Array([1])), false);

    const raw = await crypto.subtle.exportKey("raw", pair.publicKey);
    assert.equal(raw.byteLength, 32);
    const rawPublic = await crypto.subtle.importKey("raw", raw, "Ed25519", true, ["verify"]);
    assert.equal(await crypto.subtle.verify("Ed25519", rawPublic, signature, data), true);
    await expectRejectsName(crypto.subtle.exportKey("raw", pair.privateKey), "InvalidAccessError");

    const spki = await crypto.subtle.exportKey("spki", pair.publicKey);
    const pkcs8 = await crypto.subtle.exportKey("pkcs8", pair.privateKey);
    assert.equal(spki.byteLength, 44);
    assert.equal(pkcs8.byteLength, 48);
    const spkiPublic = await crypto.subtle.importKey("spki", spki, "Ed25519", true, ["verify"]);
    const pkcs8Private = await crypto.subtle.importKey("pkcs8", pkcs8, "Ed25519", true, ["sign"]);
    const importedSignature = await crypto.subtle.sign("Ed25519", pkcs8Private, data);
    assert.equal(await crypto.subtle.verify("Ed25519", spkiPublic, importedSignature, data), true);

    const publicJwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
    const privateJwk = await crypto.subtle.exportKey("jwk", pair.privateKey);
    assert.deepEqual({ kty: publicJwk.kty, crv: publicJwk.crv, key_ops: publicJwk.key_ops, ext: publicJwk.ext }, { kty: "OKP", crv: "Ed25519", key_ops: ["verify"], ext: true });
    assert.equal(typeof publicJwk.x, "string");
    assert.equal(typeof privateJwk.x, "string");
    assert.equal(typeof privateJwk.d, "string");
    assert.deepEqual(privateJwk.key_ops, ["sign"]);
    const jwkPublic = await crypto.subtle.importKey("jwk", publicJwk, "Ed25519", true, ["verify"]);
    const jwkPrivate = await crypto.subtle.importKey("jwk", privateJwk, "Ed25519", true, ["sign"]);
    const jwkSignature = await crypto.subtle.sign("Ed25519", jwkPrivate, data);
    assert.equal(await crypto.subtle.verify("Ed25519", jwkPublic, jwkSignature, data), true);

    // RFC 8037: an OKP private JWK must also carry the public key in "x".
    await expectRejectsName(crypto.subtle.importKey("jwk", { ...privateJwk, x: undefined }, "Ed25519", true, ["sign"]), "DataError");

    const wrappingKey = await crypto.subtle.importKey("raw", new Uint8Array(16).fill(7), { name: "AES-GCM" }, false, ["encrypt", "decrypt", "wrapKey", "unwrapKey"]);
    const iv = new Uint8Array(12).fill(8);
    const wrapped = await crypto.subtle.wrapKey("jwk", pair.publicKey, wrappingKey, { name: "AES-GCM", iv });
    const unwrapped = await crypto.subtle.unwrapKey("jwk", wrapped, wrappingKey, { name: "AES-GCM", iv }, "Ed25519", true, ["verify"]);
    assert.equal(await crypto.subtle.verify("Ed25519", unwrapped, signature, data), true);

    const privatePayload = new TextEncoder().encode(JSON.stringify(privateJwk));
    const privateIv = new Uint8Array(12).fill(9);
    const wrappedPrivate = await crypto.subtle.encrypt({ name: "AES-GCM", iv: privateIv }, wrappingKey, privatePayload);
    const unwrappedPrivate = await crypto.subtle.unwrapKey("jwk", wrappedPrivate, wrappingKey, { name: "AES-GCM", iv: privateIv }, "Ed25519", true, ["sign"]);
    const unwrappedSignature = await crypto.subtle.sign("Ed25519", unwrappedPrivate, data);
    assert.equal(await crypto.subtle.verify("Ed25519", pair.publicKey, unwrappedSignature, data), true);

    // Unwrapped private JWKs are held to the same rule: "x" is required.
    const payloadWithoutX = new TextEncoder().encode(JSON.stringify({ ...privateJwk, x: undefined }));
    const wrappedWithoutX = await crypto.subtle.encrypt({ name: "AES-GCM", iv: privateIv }, wrappingKey, payloadWithoutX);
    await expectRejectsName(crypto.subtle.unwrapKey("jwk", wrappedWithoutX, wrappingKey, { name: "AES-GCM", iv: privateIv }, "Ed25519", true, ["sign"]), "DataError");

    await expectRejectsName(crypto.subtle.generateKey("Ed25519", true, []), "SyntaxError");
    await expectRejectsName(crypto.subtle.generateKey("Ed25519", true, ["encrypt"]), "SyntaxError");
    await expectRejectsName(crypto.subtle.sign("Ed25519", pair.publicKey, data), "InvalidAccessError");
    await expectRejectsName(crypto.subtle.verify("Ed25519", pair.privateKey, signature, data), "InvalidAccessError");
    await expectRejectsName(crypto.subtle.importKey("raw", raw, "Ed25519", true, ["sign"]), "SyntaxError");
    await expectRejectsName(crypto.subtle.importKey("pkcs8", pkcs8, "Ed25519", true, []), "SyntaxError");
    await expectRejectsName(crypto.subtle.importKey("jwk", { ...publicJwk, crv: "X25519" }, "Ed25519", true, ["verify"]), "DataError");
    await expectRejectsName(crypto.subtle.importKey("jwk", privateJwk, "Ed25519", true, []), "SyntaxError");
    await expectRejectsName(crypto.subtle.importKey("jwk", { ...privateJwk, key_ops: ["verify"] }, "Ed25519", true, ["sign"]), "DataError");
  });

  test("subtle X25519 generates, imports, exports, derives, and unwraps", async () => {
    const alice = await crypto.subtle.generateKey("X25519", true, ["deriveBits", "deriveKey"]);
    const bob = await crypto.subtle.generateKey({ name: "X25519" }, true, ["deriveBits", "deriveKey"]);
    assert.deepEqual(alice.publicKey.algorithm, { name: "X25519" });
    assert.deepEqual(alice.privateKey.algorithm, { name: "X25519" });
    assert.deepEqual(alice.publicKey.usages, []);
    assert.deepEqual(alice.privateKey.usages, ["deriveKey", "deriveBits"]);

    const aliceBits = await crypto.subtle.deriveBits({ name: "X25519", public: bob.publicKey }, alice.privateKey, 256);
    const bobBits = await crypto.subtle.deriveBits({ name: "X25519", public: alice.publicKey }, bob.privateKey, 256);
    assert.equal(aliceBits.byteLength, 32);
    assert.equal(hex(aliceBits), hex(bobBits));
    assert.equal((await crypto.subtle.deriveBits({ name: "X25519", public: bob.publicKey }, alice.privateKey, null)).byteLength, 32);
    assert.equal((await crypto.subtle.deriveBits({ name: "X25519", public: bob.publicKey }, alice.privateKey, 0)).byteLength, 32);
    assert.equal((await crypto.subtle.deriveBits({ name: "X25519", public: bob.publicKey }, alice.privateKey, 1)).byteLength, 1);
    assert.equal((await crypto.subtle.deriveBits({ name: "X25519", public: bob.publicKey }, alice.privateKey, 128)).byteLength, 16);

    const derivedKey = await crypto.subtle.deriveKey({ name: "X25519", public: bob.publicKey }, alice.privateKey, { name: "AES-GCM", length: 128 }, true, ["encrypt"]);
    assert.deepEqual(derivedKey.algorithm, { name: "AES-GCM", length: 128 });
    assert.equal((await crypto.subtle.exportKey("raw", derivedKey)).byteLength, 16);

    const rawPublic = await crypto.subtle.exportKey("raw", alice.publicKey);
    assert.equal(rawPublic.byteLength, 32);
    const rawImportedPublic = await crypto.subtle.importKey("raw", rawPublic, "X25519", true, []);
    assert.equal(hex(await crypto.subtle.deriveBits({ name: "X25519", public: rawImportedPublic }, bob.privateKey, 256)), hex(bobBits));
    await expectRejectsName(crypto.subtle.exportKey("raw", alice.privateKey), "InvalidAccessError");

    const spki = await crypto.subtle.exportKey("spki", alice.publicKey);
    const pkcs8 = await crypto.subtle.exportKey("pkcs8", alice.privateKey);
    assert.equal(spki.byteLength, 44);
    assert.equal(pkcs8.byteLength, 48);
    const spkiPublic = await crypto.subtle.importKey("spki", spki, "X25519", true, []);
    const pkcs8Private = await crypto.subtle.importKey("pkcs8", pkcs8, "X25519", true, ["deriveBits"]);
    assert.equal(hex(await crypto.subtle.deriveBits({ name: "X25519", public: bob.publicKey }, pkcs8Private, 256)), hex(aliceBits));
    assert.equal(hex(await crypto.subtle.deriveBits({ name: "X25519", public: spkiPublic }, bob.privateKey, 256)), hex(bobBits));

    const publicJwk = await crypto.subtle.exportKey("jwk", alice.publicKey);
    const privateJwk = await crypto.subtle.exportKey("jwk", alice.privateKey);
    assert.deepEqual({ kty: publicJwk.kty, crv: publicJwk.crv, key_ops: publicJwk.key_ops, ext: publicJwk.ext }, { kty: "OKP", crv: "X25519", key_ops: [], ext: true });
    assert.equal(typeof publicJwk.x, "string");
    assert.equal(typeof privateJwk.x, "string");
    assert.equal(typeof privateJwk.d, "string");
    assert.deepEqual(privateJwk.key_ops, ["deriveKey", "deriveBits"]);
    const jwkPublic = await crypto.subtle.importKey("jwk", publicJwk, "X25519", true, []);
    const jwkPrivate = await crypto.subtle.importKey("jwk", privateJwk, "X25519", true, ["deriveBits"]);
    assert.equal(hex(await crypto.subtle.deriveBits({ name: "X25519", public: bob.publicKey }, jwkPrivate, 256)), hex(aliceBits));
    assert.equal(hex(await crypto.subtle.deriveBits({ name: "X25519", public: jwkPublic }, bob.privateKey, 256)), hex(bobBits));

    const wrappingKey = await crypto.subtle.importKey("raw", new Uint8Array(16).fill(9), { name: "AES-GCM" }, false, ["wrapKey", "unwrapKey"]);
    const iv = new Uint8Array(12).fill(10);
    const wrapped = await crypto.subtle.wrapKey("jwk", alice.publicKey, wrappingKey, { name: "AES-GCM", iv });
    const unwrapped = await crypto.subtle.unwrapKey("jwk", wrapped, wrappingKey, { name: "AES-GCM", iv }, "X25519", true, []);
    assert.equal(hex(await crypto.subtle.deriveBits({ name: "X25519", public: unwrapped }, bob.privateKey, 256)), hex(bobBits));

    const zeroPublic = await crypto.subtle.importKey("raw", new Uint8Array(32), "X25519", true, []);
    await expectRejectsName(crypto.subtle.deriveBits({ name: "X25519", public: zeroPublic }, alice.privateKey, 256), "OperationError");

    const lowOrderRaw = new Uint8Array(32);
    lowOrderRaw[0] = 1;
    const lowOrderSpki = fromHex("302a300506032b656e03210001" + "00".repeat(31));
    const lowOrderJwk = { kty: "OKP", crv: "X25519", x: base64Url(lowOrderRaw), ext: true, key_ops: [] };
    const lowOrderEncryptKey = await crypto.subtle.importKey("raw", new Uint8Array(16).fill(13), { name: "AES-GCM" }, false, ["encrypt"]);
    const lowOrderUnwrapKey = await crypto.subtle.importKey("raw", new Uint8Array(16).fill(13), { name: "AES-GCM" }, false, ["unwrapKey"]);
    const encoder = new TextEncoder();
    let lowOrderIvCounter = 0;

    async function unwrapLowOrder(format, keyData, importAlgorithm) {
      const lowOrderIv = new Uint8Array(12).fill(14);
      lowOrderIv[11] = ++lowOrderIvCounter;
      const ciphertext = await crypto.subtle.encrypt({ name: "AES-GCM", iv: lowOrderIv }, lowOrderEncryptKey, keyData);
      return crypto.subtle.unwrapKey(format, ciphertext, lowOrderUnwrapKey, { name: "AES-GCM", iv: lowOrderIv }, importAlgorithm, true, []);
    }

    for (const [label, publicKey] of [
      ["raw", await crypto.subtle.importKey("raw", lowOrderRaw, "X25519", true, [])],
      ["jwk", await crypto.subtle.importKey("jwk", lowOrderJwk, "X25519", true, [])],
      ["spki", await crypto.subtle.importKey("spki", lowOrderSpki, "X25519", true, [])],
      ["unwrapped raw", await unwrapLowOrder("raw", lowOrderRaw, "X25519")],
      ["unwrapped jwk", await unwrapLowOrder("jwk", encoder.encode(JSON.stringify(lowOrderJwk)), "X25519")],
      ["unwrapped spki", await unwrapLowOrder("spki", lowOrderSpki, "X25519")],
    ]) {
      await expectRejectsName(
        crypto.subtle.deriveBits({ name: "X25519", public: publicKey }, alice.privateKey, 256),
        "OperationError",
      );
      assert.equal(publicKey.algorithm.name, "X25519", `${label} low-order key algorithm`);
    }

    await expectRejectsName(crypto.subtle.generateKey("X25519", true, []), "SyntaxError");
    await expectRejectsName(crypto.subtle.generateKey("X25519", true, ["sign"]), "SyntaxError");
    await expectRejectsName(crypto.subtle.deriveBits({ name: "X25519", public: bob.publicKey }, alice.publicKey, 256), "InvalidAccessError");
    await expectRejectsName(crypto.subtle.deriveBits({ name: "X25519", public: bob.publicKey }, alice.privateKey, 257), "OperationError");
    await expectRejectsName(crypto.subtle.deriveBits({ name: "X25519" }, alice.privateKey, 256), "TypeError");
    await expectRejectsName(crypto.subtle.deriveBits({ name: "X25519", publicKey: bob.publicKey }, alice.privateKey, 256), "TypeError");
    await expectRejectsName(crypto.subtle.importKey("raw", rawPublic, "X25519", true, ["deriveBits"]), "SyntaxError");
    await expectRejectsName(crypto.subtle.importKey("pkcs8", pkcs8, "X25519", true, []), "SyntaxError");
    await expectRejectsName(crypto.subtle.importKey("jwk", privateJwk, "X25519", true, []), "SyntaxError");
    await expectRejectsName(crypto.subtle.importKey("jwk", { ...privateJwk, key_ops: ["verify"] }, "X25519", true, ["deriveBits"]), "DataError");
  });

  test("subtle unwrapKey rejects malformed JWK payloads without throwing synchronously", async () => {
    const wrappingKey = await crypto.subtle.importKey("raw", new Uint8Array(32).fill(1), { name: "AES-GCM" }, false, ["encrypt", "decrypt", "wrapKey", "unwrapKey"]);
    const iv = new Uint8Array(12).fill(2);

    const invalidJson = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, wrappingKey, new TextEncoder().encode("not json {{{"));
    await expectRejectsName(crypto.subtle.unwrapKey("jwk", invalidJson, wrappingKey, { name: "AES-GCM", iv }, { name: "AES-GCM" }, true, ["encrypt", "decrypt"]), "DataError");

    const invalidJwk = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, wrappingKey, new TextEncoder().encode(JSON.stringify({ foo: "bar" })));
    await expectRejectsName(crypto.subtle.unwrapKey("jwk", invalidJwk, wrappingKey, { name: "AES-GCM", iv }, { name: "AES-GCM" }, true, ["encrypt", "decrypt"]), "TypeError");

    const invalidKeyOps = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, wrappingKey, new TextEncoder().encode(JSON.stringify({
      kty: "oct",
      k: "AwMDAwMDAwMDAwMDAwMDAw",
      alg: "A128GCM",
      ext: true,
      key_ops: ["bogus"],
    })));
    // Unknown key_ops values are a JWK data problem (DataError), not a WebIDL
    // conversion failure.
    await expectRejectsName(crypto.subtle.unwrapKey("jwk", invalidKeyOps, wrappingKey, { name: "AES-GCM", iv }, { name: "AES-GCM" }, true, ["encrypt"]), "DataError");

    const hugeJwk = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, wrappingKey, new TextEncoder().encode(JSON.stringify({
      kty: "oct",
      k: "A".repeat(70 * 1024),
    })));
    await expectRejectsName(crypto.subtle.unwrapKey("jwk", hugeJwk, wrappingKey, { name: "AES-GCM", iv }, { name: "AES-GCM" }, true, ["encrypt"]), "DataError");

    const rawKey = await crypto.subtle.importKey("raw", new Uint8Array(16).fill(3), { name: "AES-GCM" }, true, ["encrypt"]);
    const wrappedRaw = await crypto.subtle.wrapKey("raw", rawKey, wrappingKey, { name: "AES-GCM", iv });
    for (let index = 0; index < 16; index++) {
      await expectRejectsName(crypto.subtle.unwrapKey("raw", wrappedRaw, wrappingKey, { name: "AES-GCM", iv }, { name: "AES-GCM" }, true, []), "SyntaxError");
    }

    const unwrapOnly = await crypto.subtle.importKey("raw", new Uint8Array(32).fill(1), { name: "AES-GCM" }, false, ["unwrapKey"]);
    const key = await crypto.subtle.importKey("raw", new Uint8Array(16), { name: "AES-GCM" }, true, ["encrypt"]);
    await expectRejectsName(crypto.subtle.wrapKey("raw", key, unwrapOnly, { name: "AES-GCM", iv }), "InvalidAccessError");
  });

  test("crypto.subtle is read-only", () => {
    const subtle = crypto.subtle;
    Function("crypto", "crypto.subtle = null;")(crypto);
    assert.equal(crypto.subtle, subtle, "sloppy-mode assignment should be a silent no-op");
    assert.throws(() => {
      "use strict";
      crypto.subtle = null;
    }, TypeError);
    assert.equal(crypto.subtle, subtle);
    assert.equal(Function("crypto", "return delete crypto.subtle;")(crypto), false);
    assert.equal(crypto.subtle, subtle);
  });

  test("subtle rejects invalid KeyFormat strings with TypeError", async () => {
    const key = await crypto.subtle.importKey("raw", new Uint8Array(16), { name: "AES-GCM" }, true, ["encrypt"]);
    const wrappingKey = await crypto.subtle.importKey("raw", new Uint8Array(16).fill(1), { name: "AES-KW" }, false, ["wrapKey", "unwrapKey"]);
    await expectRejectsName(crypto.subtle.importKey("bogus", new Uint8Array(16), { name: "AES-GCM" }, true, ["encrypt"]), "TypeError");
    await expectRejectsName(crypto.subtle.exportKey("bogus", key), "TypeError");
    await expectRejectsName(crypto.subtle.wrapKey("bogus", key, wrappingKey, "AES-KW"), "TypeError");
    await expectRejectsName(crypto.subtle.unwrapKey("bogus", new Uint8Array(24), wrappingKey, "AES-KW", { name: "AES-GCM" }, true, ["encrypt"]), "TypeError");
  });

  test("subtle oct JWK use member must match the algorithm", async () => {
    const aesJwk = { kty: "oct", k: "AAECAwQFBgcICQoLDA0ODw" };
    await expectRejectsName(crypto.subtle.importKey("jwk", { ...aesJwk, use: "sig" }, { name: "AES-GCM" }, true, ["encrypt"]), "DataError");
    const aesKey = await crypto.subtle.importKey("jwk", { ...aesJwk, use: "enc" }, { name: "AES-GCM" }, true, ["encrypt"]);
    assert.deepEqual(aesKey.algorithm, { name: "AES-GCM", length: 128 });

    const hmacJwk = { kty: "oct", k: "AQIDBAUGBwgJCgsMDQ4PEA" };
    await expectRejectsName(crypto.subtle.importKey("jwk", { ...hmacJwk, use: "enc" }, { name: "HMAC", hash: "SHA-256" }, true, ["sign"]), "DataError");
    const hmacKey = await crypto.subtle.importKey("jwk", { ...hmacJwk, use: "sig" }, { name: "HMAC", hash: "SHA-256" }, true, ["sign"]);
    assert.equal(hmacKey.algorithm.name, "HMAC");

    // Unwrapped JWKs hit the native parser; same rule applies.
    const gcmWrapKey = await crypto.subtle.importKey("raw", new Uint8Array(32).fill(1), { name: "AES-GCM" }, false, ["encrypt", "unwrapKey"]);
    const iv = new Uint8Array(12).fill(2);
    const wrongUse = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, gcmWrapKey, new TextEncoder().encode(JSON.stringify({ ...aesJwk, use: "sig" })));
    await expectRejectsName(crypto.subtle.unwrapKey("jwk", wrongUse, gcmWrapKey, { name: "AES-GCM", iv }, { name: "AES-GCM" }, true, ["encrypt"]), "DataError");
  });

  test("subtle HMAC import length window", async () => {
    const raw = new Uint8Array(16); // 128 data bits
    const exact = await crypto.subtle.importKey("raw", raw, { name: "HMAC", hash: "SHA-256", length: 128 }, true, ["sign"]);
    assert.equal(exact.algorithm.length, 128);

    // data_bits - 8 < length <= data_bits succeeds and algorithm.length
    // reports the declared value, not the data size.
    const truncated = await crypto.subtle.importKey("raw", raw, { name: "HMAC", hash: "SHA-256", length: 124 }, true, ["sign"]);
    assert.equal(truncated.algorithm.length, 124);
    assert.equal((await crypto.subtle.exportKey("raw", truncated)).byteLength, 16);

    await expectRejectsName(crypto.subtle.importKey("raw", raw, { name: "HMAC", hash: "SHA-256", length: 120 }, true, ["sign"]), "DataError");
    await expectRejectsName(crypto.subtle.importKey("raw", raw, { name: "HMAC", hash: "SHA-256", length: 136 }, true, ["sign"]), "DataError");

    const jwk = { kty: "oct", k: "AQIDBAUGBwgJCgsMDQ4PEA" }; // 16 bytes
    const jwkTruncated = await crypto.subtle.importKey("jwk", jwk, { name: "HMAC", hash: "SHA-256", length: 121 }, true, ["sign"]);
    assert.equal(jwkTruncated.algorithm.length, 121);
    await expectRejectsName(crypto.subtle.importKey("jwk", jwk, { name: "HMAC", hash: "SHA-256", length: 120 }, true, ["sign"]), "DataError");
    await expectRejectsName(crypto.subtle.importKey("jwk", jwk, { name: "HMAC", hash: "SHA-256", length: 129 }, true, ["sign"]), "DataError");
  });

  test("subtle JWK missing kty is TypeError, mismatched kty is DataError", async () => {
    await expectRejectsName(crypto.subtle.importKey("jwk", { k: "AAECAwQFBgcICQoLDA0ODw" }, { name: "AES-GCM" }, true, ["encrypt"]), "TypeError");
    await expectRejectsName(crypto.subtle.importKey("jwk", { k: "AAECAwQFBgcICQoLDA0ODw" }, { name: "HMAC", hash: "SHA-256" }, true, ["sign"]), "TypeError");
    await expectRejectsName(crypto.subtle.importKey("jwk", {}, "Ed25519", true, ["verify"]), "TypeError");
    await expectRejectsName(crypto.subtle.importKey("jwk", { kty: "RSA", k: "AAECAwQFBgcICQoLDA0ODw" }, { name: "AES-GCM" }, true, ["encrypt"]), "DataError");
    await expectRejectsName(crypto.subtle.importKey("jwk", { kty: "oct", k: "AAECAwQFBgcICQoLDA0ODw", key_ops: ["bogus"] }, { name: "AES-GCM" }, true, ["encrypt"]), "DataError");
  });

  test("key.usages and JWK key_ops follow spec KeyUsage order", async () => {
    const aes = await crypto.subtle.importKey("raw", new Uint8Array(16), { name: "AES-GCM" }, true, ["unwrapKey", "wrapKey", "decrypt", "encrypt"]);
    assert.deepEqual(aes.usages, ["encrypt", "decrypt", "wrapKey", "unwrapKey"]);
    assert.deepEqual((await crypto.subtle.exportKey("jwk", aes)).key_ops, ["encrypt", "decrypt", "wrapKey", "unwrapKey"]);

    const ecdh = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits", "deriveKey"]);
    assert.deepEqual(ecdh.privateKey.usages, ["deriveKey", "deriveBits"]);
    assert.deepEqual((await crypto.subtle.exportKey("jwk", ecdh.privateKey)).key_ops, ["deriveKey", "deriveBits"]);
  });

  test("subtle OKP private JWK requires a consistent x", async () => {
    const x25519 = await crypto.subtle.generateKey("X25519", true, ["deriveBits"]);
    const x25519PrivateJwk = await crypto.subtle.exportKey("jwk", x25519.privateKey);
    await expectRejectsName(crypto.subtle.importKey("jwk", { ...x25519PrivateJwk, x: undefined }, "X25519", true, ["deriveBits"]), "DataError");

    const ed25519 = await crypto.subtle.generateKey("Ed25519", true, ["sign", "verify"]);
    const otherEd25519 = await crypto.subtle.generateKey("Ed25519", true, ["sign", "verify"]);
    const privateJwk = await crypto.subtle.exportKey("jwk", ed25519.privateKey);
    const otherPublicJwk = await crypto.subtle.exportKey("jwk", otherEd25519.publicKey);
    await expectRejectsName(crypto.subtle.importKey("jwk", { ...privateJwk, x: undefined }, "Ed25519", true, ["sign"]), "DataError");
    await expectRejectsName(crypto.subtle.importKey("jwk", { ...privateJwk, x: otherPublicJwk.x }, "Ed25519", true, ["sign"]), "DataError");

    const publicJwk = await crypto.subtle.exportKey("jwk", ed25519.publicKey);
    await crypto.subtle.importKey("jwk", { ...publicJwk, alg: "Ed25519" }, "Ed25519", true, ["verify"]);
    await crypto.subtle.importKey("jwk", { ...publicJwk, alg: "EdDSA" }, "Ed25519", true, ["verify"]);
    await expectRejectsName(crypto.subtle.importKey("jwk", { ...publicJwk, alg: "ES256" }, "Ed25519", true, ["verify"]), "DataError");
  });

  test("subtle raw EC import rejects non-uncompressed point encodings", async () => {
    // Web Crypto raw EC keys must be uncompressed SEC1 points: 0x04 || X || Y.
    for (const namedCurve of ["P-256", "P-384", "P-521"]) {
      const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve }, true, ["sign", "verify"]);
      const raw = new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey));
      assert.equal(raw[0], 0x04);
      const coordinateBytes = (raw.length - 1) / 2;

      // Round-trip the legitimate uncompressed point still works.
      await crypto.subtle.importKey("raw", raw, { name: "ECDSA", namedCurve }, true, ["verify"]);

      // Compressed encoding (0x02/0x03 || X) must be rejected with DataError.
      const compressed = new Uint8Array(1 + coordinateBytes);
      compressed[0] = (raw[raw.length - 1] & 1) ? 0x03 : 0x02;
      compressed.set(raw.subarray(1, 1 + coordinateBytes), 1);
      await expectRejectsName(crypto.subtle.importKey("raw", compressed, { name: "ECDSA", namedCurve }, true, ["verify"]), "DataError");

      // Hybrid encoding (0x06/0x07 || X || Y) carries both coordinates but is
      // still not the uncompressed form Web Crypto allows.
      const hybrid = new Uint8Array(raw);
      hybrid[0] = (raw[raw.length - 1] & 1) ? 0x07 : 0x06;
      await expectRejectsName(crypto.subtle.importKey("raw", hybrid, { name: "ECDSA", namedCurve }, true, ["verify"]), "DataError");

      // The point-at-infinity octet (0x00) and a truncated buffer are rejected.
      await expectRejectsName(crypto.subtle.importKey("raw", new Uint8Array([0x00]), { name: "ECDSA", namedCurve }, true, ["verify"]), "DataError");
      await expectRejectsName(crypto.subtle.importKey("raw", raw.subarray(0, raw.length - 1), { name: "ECDSA", namedCurve }, true, ["verify"]), "DataError");

      // ECDH raw import enforces the same rule.
      const ecdh = await crypto.subtle.generateKey({ name: "ECDH", namedCurve }, true, ["deriveBits"]);
      const ecdhRaw = new Uint8Array(await crypto.subtle.exportKey("raw", ecdh.publicKey));
      const ecdhCompressed = new Uint8Array(1 + coordinateBytes);
      ecdhCompressed[0] = 0x02;
      ecdhCompressed.set(ecdhRaw.subarray(1, 1 + coordinateBytes), 1);
      await expectRejectsName(crypto.subtle.importKey("raw", ecdhCompressed, { name: "ECDH", namedCurve }, true, []), "DataError");
    }
  });

  test("subtle ECDSA produces fixed-width IEEE P1363 signatures that round-trip", async () => {
    const data = new TextEncoder().encode("collo p1363 fixed width");
    const curves = [
      ["P-256", "SHA-256", 64],
      ["P-384", "SHA-384", 96],
      ["P-521", "SHA-512", 132],
    ];
    for (const [namedCurve, hash, signatureLength] of curves) {
      const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve }, true, ["sign", "verify"]);
      // Run several signatures: the P1363 r||s components must always be exactly
      // signatureLength bytes, even when r or s would have leading zero bytes.
      for (let i = 0; i < 8; i++) {
        const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash }, pair.privateKey, data));
        assert.equal(signature.length, signatureLength, `${namedCurve} P1363 length`);
        assert.equal(await crypto.subtle.verify({ name: "ECDSA", hash }, pair.publicKey, signature, data), true);
        // Tampering with the high byte of s must fail verification.
        const tampered = new Uint8Array(signature);
        tampered[signatureLength / 2] ^= 0x01;
        assert.equal(await crypto.subtle.verify({ name: "ECDSA", hash }, pair.publicKey, tampered, data), false);
      }
      // A signature with the wrong length is rejected as invalid (not an error).
      const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash }, pair.privateKey, data));
      assert.equal(await crypto.subtle.verify({ name: "ECDSA", hash }, pair.publicKey, sig.subarray(0, sig.length - 1), data), false);
    }
  });

  test("subtle deriveBits null length derives the full hash output for HKDF/PBKDF2", async () => {
    const ikm = fromHex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b");
    const salt = fromHex("000102030405060708090a0b0c");
    const info = fromHex("f0f1f2f3f4f5f6f7f8f9");

    // HKDF: null length must yield the digest length of the chosen hash.
    const hkdf = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
    const hkdfDigestBytes = {
      "SHA-224": 28,
      "SHA-256": 32,
      "SHA-384": 48,
      "SHA-512": 64,
      "SHA3-224": 28,
      "SHA3-256": 32,
      "SHA3-384": 48,
      "SHA3-512": 64,
    };
    for (const [hash, bytes] of Object.entries(hkdfDigestBytes)) {
      const full = await crypto.subtle.deriveBits({ name: "HKDF", hash, salt, info }, hkdf, null);
      assert.equal(full.byteLength, bytes, `HKDF ${hash} null length`);
      // Same result as asking for exactly that many bits explicitly.
      const explicit = await crypto.subtle.deriveBits({ name: "HKDF", hash, salt, info }, hkdf, bytes * 8);
      assert.equal(hex(full), hex(explicit));
      // undefined behaves the same as null.
      const undef = await crypto.subtle.deriveBits({ name: "HKDF", hash, salt, info }, hkdf, undefined);
      assert.equal(hex(undef), hex(full));
    }

    // PBKDF2: null length must yield the digest length of the chosen hash.
    const password = new TextEncoder().encode("password");
    const pbkdf2 = await crypto.subtle.importKey("raw", password, "PBKDF2", false, ["deriveBits"]);
    for (const [hash, bytes] of Object.entries(hkdfDigestBytes)) {
      const params = { name: "PBKDF2", salt: new TextEncoder().encode("salt"), iterations: 2, hash };
      const full = await crypto.subtle.deriveBits(params, pbkdf2, null);
      assert.equal(full.byteLength, bytes, `PBKDF2 ${hash} null length`);
      const explicit = await crypto.subtle.deriveBits(params, pbkdf2, bytes * 8);
      assert.equal(hex(full), hex(explicit));
    }
  });

  test("native JWK unwrap parser matches the importKey base64url and ext semantics", async () => {
    // The native (unwrapKey) JWK parser must accept the same inputs the JSC
    // importKey front-end accepts. We inject custom JWK JSON by AES-GCM
    // encrypting it ourselves and feeding the ciphertext to unwrapKey.
    const kekBytes = new Uint8Array(16).fill(7);
    const iv = new Uint8Array(12).fill(9);
    const encoder = new TextEncoder();
    const encryptKey = await crypto.subtle.importKey("raw", kekBytes, { name: "AES-GCM" }, false, ["encrypt"]);
    const unwrapKeyHandle = await crypto.subtle.importKey("raw", kekBytes, { name: "AES-GCM" }, false, ["unwrapKey"]);

    async function unwrapJson(json, importAlgo, usages) {
      const ciphertext = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, encryptKey, encoder.encode(json));
      return crypto.subtle.unwrapKey("jwk", ciphertext, unwrapKeyHandle, { name: "AES-GCM", iv }, importAlgo, true, usages);
    }

    // The canonical (unpadded) base64url AES key, as importKey accepts.
    const baseJwk = { kty: "oct", k: "AAECAwQFBgcICQoLDA0ODw", alg: "A128GCM", ext: true, key_ops: ["encrypt"] };

    // importKey accepts '=' padding (WTF::base64URLDecode does not validate it);
    // the native parser must accept it identically, yielding the same key bytes.
    const padded = await unwrapJson(JSON.stringify({ ...baseJwk, k: "AAECAwQFBgcICQoLDA0ODw==" }), { name: "AES-GCM" }, ["encrypt"]);
    assert.equal(hex(await crypto.subtle.exportKey("raw", padded)), "000102030405060708090a0b0c0d0e0f");

    // ext is coerced with JS ToBoolean: the string "false" is truthy, so the
    // (extractable: true) import is allowed, matching the importKey path.
    const extStringFalse = await unwrapJson(JSON.stringify({ ...baseJwk, ext: "false" }), { name: "AES-GCM" }, ["encrypt"]);
    assert.equal(hex(await crypto.subtle.exportKey("raw", extStringFalse)), "000102030405060708090a0b0c0d0e0f");

    // A real boolean false with extractable: true must still be rejected.
    await expectRejectsName(unwrapJson(JSON.stringify({ ...baseJwk, ext: false }), { name: "AES-GCM" }, ["encrypt"]), "DataError");

    // A \u escape in an ignored member must not corrupt parsing (full Unicode +
    // surrogate pairs are decoded as UTF-8, mirroring JS string semantics).
    const withUnicodeMember = await unwrapJson(
      JSON.stringify({ ...baseJwk, kid: " key-é-😀" }),
      { name: "AES-GCM" },
      ["encrypt"]);
    assert.equal(hex(await crypto.subtle.exportKey("raw", withUnicodeMember)), "000102030405060708090a0b0c0d0e0f");

    // A lone (unpaired) surrogate escape is invalid JSON and must be rejected.
    await expectRejectsName(
      unwrapJson('{"kty":"oct","k":"AAECAwQFBgcICQoLDA0ODw","alg":"A128GCM","ext":true,"key_ops":["encrypt"],"kid":"\\ud83d"}', { name: "AES-GCM" }, ["encrypt"]),
      "DataError");
  });

  test("subtle AES-GCM decrypt verifies the authentication tag", async () => {
    const key = await crypto.subtle.importKey("raw", new Uint8Array(16).fill(3), { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
    const iv = new Uint8Array(12).fill(5);
    const additionalData = new TextEncoder().encode("aad");
    const plaintext = new TextEncoder().encode("collo gcm tag check");

    const ciphertext = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData }, key, plaintext));
    const roundTrip = await crypto.subtle.decrypt({ name: "AES-GCM", iv, additionalData }, key, ciphertext);
    assert.equal(hex(roundTrip), hex(plaintext));

    // Flipping a bit in the tag (last 16 bytes) must fail authentication.
    const tampered = new Uint8Array(ciphertext);
    tampered[tampered.length - 1] ^= 0x01;
    await expectRejectsName(crypto.subtle.decrypt({ name: "AES-GCM", iv, additionalData }, key, tampered), "OperationError");

    // Changing the additional data must also fail authentication.
    await expectRejectsName(
      crypto.subtle.decrypt({ name: "AES-GCM", iv, additionalData: new TextEncoder().encode("AAD") }, key, ciphertext),
      "OperationError");
  });
});
