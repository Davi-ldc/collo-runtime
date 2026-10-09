// Collo-only.

function fromHex(string) {
  return Uint8Array.from(string.match(/../g) ?? [], byte => Number.parseInt(byte, 16));
}

bench("crypto.getRandomValues-u8-16", iterations => {
  const bytes = new Uint8Array(16);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    crypto.getRandomValues(bytes);
    checksum ^= bytes[i & 15];
  }
  return checksum;
}, { iterations: 220000, warmup: 10000 });

bench("crypto.getRandomValues-u8-1024", iterations => {
  const bytes = new Uint8Array(1024);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    crypto.getRandomValues(bytes);
    checksum ^= bytes[i & 1023];
  }
  return checksum;
}, { iterations: 70000, warmup: 5000 });

bench("crypto.getRandomValues-u32-256", iterations => {
  const words = new Uint32Array(256);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    crypto.getRandomValues(words);
    checksum ^= words[i & 255] & 0xff;
  }
  return checksum;
}, { iterations: 70000, warmup: 5000 });

bench("crypto.randomUUID", iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const uuid = crypto.randomUUID();
    checksum ^= uuid.charCodeAt(i % 36);
  }
  return checksum;
}, { iterations: 180000, warmup: 10000 });

bench("crypto.timingSafeEqual-u8-32", iterations => {
  const left = new Uint8Array(32);
  const right = new Uint8Array(32);
  right[31] = 1;
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    left[31] = i & 1;
    checksum ^= crypto.timingSafeEqual(left, right) ? 1 : 0;
  }
  return checksum;
}, { iterations: 250000, warmup: 10000 });

bench("crypto.timingSafeEqual-u8-1024", iterations => {
  const left = new Uint8Array(1024);
  const right = new Uint8Array(1024);
  right[1023] = 1;
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    left[1023] = i & 1;
    checksum ^= crypto.timingSafeEqual(left, right) ? 1 : 0;
  }
  return checksum;
}, { iterations: 90000, warmup: 5000 });

bench("crypto.subtle.digest-sha256-32", async iterations => {
  const data = new Uint8Array(32);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    data[0] = i & 0xff;
    const digest = await crypto.subtle.digest("SHA-256", data);
    checksum ^= new Uint8Array(digest)[i & 31];
  }
  return checksum;
}, { iterations: 2500, warmup: 100 });

bench("crypto.subtle.digest-sha256-1024", async iterations => {
  const data = new Uint8Array(1024);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    data[i & 1023] = i & 0xff;
    const digest = await crypto.subtle.digest("SHA-256", data);
    checksum ^= new Uint8Array(digest)[i & 31];
  }
  return checksum;
}, { iterations: 1200, warmup: 60 });

bench("crypto.subtle.digest-sha3-256-1024", async iterations => {
  const data = new Uint8Array(1024);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    data[i & 1023] = i & 0xff;
    const digest = await crypto.subtle.digest("SHA3-256", data);
    checksum ^= new Uint8Array(digest)[i & 31];
  }
  return checksum;
}, { iterations: 900, warmup: 50 });

bench("crypto.subtle.hmac-sha256-sign", async iterations => {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode("key"), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const data = new Uint8Array(64);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    data[0] = i & 0xff;
    const signature = await crypto.subtle.sign("HMAC", key, data);
    checksum ^= new Uint8Array(signature)[i & 31];
  }
  return checksum;
}, { iterations: 2000, warmup: 100 });

bench("crypto.subtle.hmac-sha3-256-sign", async iterations => {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode("key"), { name: "HMAC", hash: "SHA3-256" }, false, ["sign"]);
  const data = new Uint8Array(64);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    data[0] = i & 0xff;
    const signature = await crypto.subtle.sign("HMAC", key, data);
    checksum ^= new Uint8Array(signature)[i & 31];
  }
  return checksum;
}, { iterations: 1400, warmup: 80 });

bench("crypto.subtle.pbkdf2-sha256-200-32", async iterations => {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode("password"), "PBKDF2", false, ["deriveBits"]);
  const salt = new TextEncoder().encode("salt");
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    salt[0] = 0x73 ^ (i & 0xff);
    const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", salt, iterations: 200, hash: "SHA-256" }, key, 256);
    checksum ^= new Uint8Array(bits)[i & 31];
  }
  return checksum;
}, { iterations: 120, warmup: 8 });

bench("crypto.subtle.hkdf-sha256-42", async iterations => {
  const ikm = new Uint8Array(22).fill(0x0b);
  const key = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveBits"]);
  const salt = Uint8Array.from("000102030405060708090a0b0c".match(/../g), byte => Number.parseInt(byte, 16));
  const info = Uint8Array.from("f0f1f2f3f4f5f6f7f8f9".match(/../g), byte => Number.parseInt(byte, 16));
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    info[0] = 0xf0 ^ (i & 0xff);
    const bits = await crypto.subtle.deriveBits({ name: "HKDF", hash: "SHA-256", salt, info }, key, 336);
    checksum ^= new Uint8Array(bits)[i % 42];
  }
  return checksum;
}, { iterations: 1600, warmup: 80 });

bench("crypto.subtle.pbkdf2-derivekey-aes-gcm-128", async iterations => {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode("password"), "PBKDF2", false, ["deriveKey"]);
  const salt = new TextEncoder().encode("salt");
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    salt[0] = 0x73 ^ (i & 0xff);
    const derived = await crypto.subtle.deriveKey({ name: "PBKDF2", salt, iterations: 160, hash: "SHA-256" }, key, { name: "AES-GCM", length: 128 }, true, ["encrypt"]);
    checksum ^= derived.algorithm.length & 0xff;
  }
  return checksum;
}, { iterations: 100, warmup: 8 });

bench("crypto.subtle.hkdf-derivekey-hmac-sha256", async iterations => {
  const ikm = new Uint8Array(22).fill(0x0b);
  const key = await crypto.subtle.importKey("raw", ikm, "HKDF", false, ["deriveKey"]);
  const salt = Uint8Array.from("000102030405060708090a0b0c".match(/../g), byte => Number.parseInt(byte, 16));
  const info = Uint8Array.from("f0f1f2f3f4f5f6f7f8f9".match(/../g), byte => Number.parseInt(byte, 16));
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    info[0] = 0xf0 ^ (i & 0xff);
    const derived = await crypto.subtle.deriveKey({ name: "HKDF", hash: "SHA-256", salt, info }, key, { name: "HMAC", hash: "SHA-256", length: 256 }, true, ["sign"]);
    checksum ^= derived.algorithm.length & 0xff;
  }
  return checksum;
}, { iterations: 1400, warmup: 70 });

bench("crypto.subtle.aes-gcm-128-encrypt-32", async iterations => {
  const key = await crypto.subtle.importKey("raw", new Uint8Array(16), { name: "AES-GCM" }, false, ["encrypt"]);
  const iv = new Uint8Array(12);
  const data = new Uint8Array(32);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    iv[11] = i & 0xff;
    data[0] = i & 0xff;
    const encrypted = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, data);
    checksum ^= new Uint8Array(encrypted)[i & 31];
  }
  return checksum;
}, { iterations: 1800, warmup: 80 });

bench("crypto.subtle.aes-gcm-128-decrypt-32", async iterations => {
  const key = await crypto.subtle.importKey("raw", new Uint8Array(16), { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
  const iv = new Uint8Array(12);
  const data = new Uint8Array(32);
  const encrypted = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, data);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const decrypted = await crypto.subtle.decrypt({ name: "AES-GCM", iv }, key, encrypted);
    checksum ^= new Uint8Array(decrypted)[i & 31];
  }
  return checksum;
}, { iterations: 1800, warmup: 80 });

bench("crypto.subtle.aes-gcm-256-encrypt-1024", async iterations => {
  const key = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt"]);
  const iv = new Uint8Array(12);
  const data = new Uint8Array(1024);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    iv[11] = i & 0xff;
    data[i & 1023] = i & 0xff;
    const encrypted = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, data);
    checksum ^= new Uint8Array(encrypted)[i & 1023];
  }
  return checksum;
}, { iterations: 1000, warmup: 60 });

bench("crypto.subtle.aes-cbc-128-encrypt-32", async iterations => {
  const key = await crypto.subtle.importKey("raw", new Uint8Array(16), { name: "AES-CBC" }, false, ["encrypt"]);
  const iv = new Uint8Array(16);
  const data = new Uint8Array(32);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    iv[15] = i & 0xff;
    data[0] = i & 0xff;
    const encrypted = await crypto.subtle.encrypt({ name: "AES-CBC", iv }, key, data);
    checksum ^= new Uint8Array(encrypted)[i & 31];
  }
  return checksum;
}, { iterations: 1600, warmup: 80 });

bench("crypto.subtle.aes-cbc-128-decrypt-32", async iterations => {
  const key = await crypto.subtle.importKey("raw", new Uint8Array(16), { name: "AES-CBC" }, false, ["encrypt", "decrypt"]);
  const iv = new Uint8Array(16);
  const data = new Uint8Array(32);
  const encrypted = await crypto.subtle.encrypt({ name: "AES-CBC", iv }, key, data);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const decrypted = await crypto.subtle.decrypt({ name: "AES-CBC", iv }, key, encrypted);
    checksum ^= new Uint8Array(decrypted)[i & 31];
  }
  return checksum;
}, { iterations: 1600, warmup: 80 });

bench("crypto.subtle.aes-ctr-128-encrypt-1024", async iterations => {
  const key = await crypto.subtle.importKey("raw", new Uint8Array(16), { name: "AES-CTR" }, false, ["encrypt"]);
  const counter = new Uint8Array(16);
  const data = new Uint8Array(1024);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    counter[15] = i & 0xff;
    data[i & 1023] = i & 0xff;
    const encrypted = await crypto.subtle.encrypt({ name: "AES-CTR", counter, length: 64 }, key, data);
    checksum ^= new Uint8Array(encrypted)[i & 1023];
  }
  return checksum;
}, { iterations: 1000, warmup: 60 });

bench("crypto.subtle.aes-kw-wrap-raw-16", async iterations => {
  const wrappingKey = await crypto.subtle.importKey("raw", fromHex("000102030405060708090a0b0c0d0e0f"), { name: "AES-KW" }, false, ["wrapKey"]);
  const key = await crypto.subtle.importKey("raw", fromHex("00112233445566778899aabbccddeeff"), { name: "AES-GCM" }, true, ["encrypt"]);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const wrapped = await crypto.subtle.wrapKey("raw", key, wrappingKey, "AES-KW");
    checksum ^= new Uint8Array(wrapped)[i % 24];
  }
  return checksum;
}, { iterations: 1400, warmup: 80 });

bench("crypto.subtle.wrap-unwrap-raw-hmac-aes-gcm", async iterations => {
  const wrappingKey = await crypto.subtle.importKey("raw", new Uint8Array(32).fill(1), { name: "AES-GCM" }, false, ["wrapKey", "unwrapKey"]);
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode("key"), { name: "HMAC", hash: "SHA-256" }, true, ["sign"]);
  const iv = new Uint8Array(12);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    iv[11] = i & 0xff;
    const wrapped = await crypto.subtle.wrapKey("raw", key, wrappingKey, { name: "AES-GCM", iv });
    const unwrapped = await crypto.subtle.unwrapKey("raw", wrapped, wrappingKey, { name: "AES-GCM", iv }, { name: "HMAC", hash: "SHA-256", length: 24 }, true, ["sign"]);
    checksum ^= unwrapped.algorithm.length & 0xff;
  }
  return checksum;
}, { iterations: 500, warmup: 40 });

bench("crypto.subtle.wrap-unwrap-jwk-aes-gcm", async iterations => {
  const wrappingKey = await crypto.subtle.importKey("raw", new Uint8Array(32).fill(1), { name: "AES-GCM" }, false, ["wrapKey", "unwrapKey"]);
  const key = await crypto.subtle.importKey("raw", new Uint8Array(16).fill(3), { name: "AES-GCM" }, true, ["encrypt"]);
  const iv = new Uint8Array(12);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    iv[11] = i & 0xff;
    const wrapped = await crypto.subtle.wrapKey("jwk", key, wrappingKey, { name: "AES-GCM", iv });
    const unwrapped = await crypto.subtle.unwrapKey("jwk", wrapped, wrappingKey, { name: "AES-GCM", iv }, { name: "AES-GCM" }, true, ["encrypt"]);
    checksum ^= unwrapped.algorithm.length & 0xff;
  }
  return checksum;
}, { iterations: 400, warmup: 30 });

bench("crypto.subtle.rsa-oaep-1024-generate-key", async iterations => {
  const publicExponent = new Uint8Array([1, 0, 1]);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const pair = await crypto.subtle.generateKey({ name: "RSA-OAEP", modulusLength: 1024, publicExponent, hash: "SHA-256" }, true, ["encrypt", "decrypt"]);
    checksum ^= pair.publicKey.algorithm.modulusLength & 0xff;
    checksum ^= pair.privateKey.usages.length;
  }
  return checksum;
}, { iterations: 20, warmup: 2 });

bench("crypto.subtle.rsa-spki-pkcs8-roundtrip-1024", async iterations => {
  const publicExponent = new Uint8Array([1, 0, 1]);
  const pair = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 1024, publicExponent, hash: "SHA-256" }, true, ["sign", "verify"]);
  const spki = await crypto.subtle.exportKey("spki", pair.publicKey);
  const pkcs8 = await crypto.subtle.exportKey("pkcs8", pair.privateKey);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const publicKey = await crypto.subtle.importKey("spki", spki, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, true, ["verify"]);
    const privateKey = await crypto.subtle.importKey("pkcs8", pkcs8, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, true, ["sign"]);
    const exportedPublic = await crypto.subtle.exportKey("spki", publicKey);
    const exportedPrivate = await crypto.subtle.exportKey("pkcs8", privateKey);
    checksum ^= new Uint8Array(exportedPublic)[i % exportedPublic.byteLength];
    checksum ^= new Uint8Array(exportedPrivate)[i % exportedPrivate.byteLength];
  }
  return checksum;
}, { iterations: 80, warmup: 8 });

bench("crypto.subtle.rsa-jwk-roundtrip-1024", async iterations => {
  const publicExponent = new Uint8Array([1, 0, 1]);
  const pair = await crypto.subtle.generateKey({ name: "RSA-OAEP", modulusLength: 1024, publicExponent, hash: "SHA-256" }, true, ["encrypt", "decrypt"]);
  const publicJwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
  const privateJwk = await crypto.subtle.exportKey("jwk", pair.privateKey);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const publicKey = await crypto.subtle.importKey("jwk", publicJwk, { name: "RSA-OAEP", hash: "SHA-256" }, true, ["encrypt"]);
    const privateKey = await crypto.subtle.importKey("jwk", privateJwk, { name: "RSA-OAEP", hash: "SHA-256" }, true, ["decrypt"]);
    const exportedPublic = await crypto.subtle.exportKey("jwk", publicKey);
    const exportedPrivate = await crypto.subtle.exportKey("jwk", privateKey);
    checksum ^= exportedPublic.n.charCodeAt(i % exportedPublic.n.length);
    checksum ^= exportedPrivate.d.charCodeAt(i % exportedPrivate.d.length);
  }
  return checksum;
}, { iterations: 80, warmup: 8 });

bench("crypto.subtle.rsassa-pkcs1-v1_5-sha256-sign-verify-1024", async iterations => {
  const publicExponent = new Uint8Array([1, 0, 1]);
  const pair = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 1024, publicExponent, hash: "SHA-256" }, false, ["sign", "verify"]);
  const data = new Uint8Array(64);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    data[0] = i & 0xff;
    const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", pair.privateKey, data);
    const valid = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", pair.publicKey, signature, data);
    checksum ^= valid ? new Uint8Array(signature)[i % 128] : 0xff;
  }
  return checksum;
}, { iterations: 220, warmup: 20 });

bench("crypto.subtle.rsa-pss-sha256-sign-verify-1024", async iterations => {
  const publicExponent = new Uint8Array([1, 0, 1]);
  const pair = await crypto.subtle.generateKey({ name: "RSA-PSS", modulusLength: 1024, publicExponent, hash: "SHA-256" }, false, ["sign", "verify"]);
  const data = new Uint8Array(64);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    data[0] = i & 0xff;
    const signature = await crypto.subtle.sign({ name: "RSA-PSS", saltLength: 32 }, pair.privateKey, data);
    const valid = await crypto.subtle.verify({ name: "RSA-PSS", saltLength: 32 }, pair.publicKey, signature, data);
    checksum ^= valid ? new Uint8Array(signature)[i % 128] : 0xff;
  }
  return checksum;
}, { iterations: 200, warmup: 20 });

bench("crypto.subtle.rsa-oaep-sha256-encrypt-decrypt-16-1024", async iterations => {
  const publicExponent = new Uint8Array([1, 0, 1]);
  const pair = await crypto.subtle.generateKey({ name: "RSA-OAEP", modulusLength: 1024, publicExponent, hash: "SHA-256" }, false, ["encrypt", "decrypt"]);
  const data = new Uint8Array(16);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    data[0] = i & 0xff;
    const encrypted = await crypto.subtle.encrypt("RSA-OAEP", pair.publicKey, data);
    const decrypted = await crypto.subtle.decrypt("RSA-OAEP", pair.privateKey, encrypted);
    checksum ^= new Uint8Array(decrypted)[0];
  }
  return checksum;
}, { iterations: 180, warmup: 20 });

bench("crypto.subtle.rsa-oaep-wrap-unwrap-raw-aes-128-1024", async iterations => {
  const publicExponent = new Uint8Array([1, 0, 1]);
  const pair = await crypto.subtle.generateKey({ name: "RSA-OAEP", modulusLength: 1024, publicExponent, hash: "SHA-256" }, false, ["wrapKey", "unwrapKey"]);
  const keyData = new Uint8Array(16).fill(7);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    keyData[0] = i & 0xff;
    const key = await crypto.subtle.importKey("raw", keyData, { name: "AES-GCM" }, true, ["encrypt"]);
    const wrapped = await crypto.subtle.wrapKey("raw", key, pair.publicKey, "RSA-OAEP");
    const unwrapped = await crypto.subtle.unwrapKey("raw", wrapped, pair.privateKey, "RSA-OAEP", { name: "AES-GCM" }, true, ["encrypt"]);
    const exported = await crypto.subtle.exportKey("raw", unwrapped);
    checksum ^= new Uint8Array(exported)[0];
  }
  return checksum;
}, { iterations: 120, warmup: 12 });

bench("crypto.subtle.ecdsa-p256-generate-key", async iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
    checksum ^= pair.publicKey.algorithm.namedCurve.charCodeAt(i % 5);
    checksum ^= pair.privateKey.usages.length;
  }
  return checksum;
}, { iterations: 80, warmup: 8 });

bench("crypto.subtle.ecdsa-p256-jwk-roundtrip", async iterations => {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const publicJwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
  const privateJwk = await crypto.subtle.exportKey("jwk", pair.privateKey);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const publicKey = await crypto.subtle.importKey("jwk", publicJwk, { name: "ECDSA", namedCurve: "P-256" }, true, ["verify"]);
    const privateKey = await crypto.subtle.importKey("jwk", privateJwk, { name: "ECDSA", namedCurve: "P-256" }, true, ["sign"]);
    const exportedPublic = await crypto.subtle.exportKey("jwk", publicKey);
    const exportedPrivate = await crypto.subtle.exportKey("jwk", privateKey);
    checksum ^= exportedPublic.x.charCodeAt(i % exportedPublic.x.length);
    checksum ^= exportedPrivate.d.charCodeAt(i % exportedPrivate.d.length);
  }
  return checksum;
}, { iterations: 160, warmup: 16 });

bench("crypto.subtle.ecdsa-p256-sha256-sign-verify", async iterations => {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, false, ["sign", "verify"]);
  const data = new Uint8Array(64);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    data[0] = i & 0xff;
    const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, data);
    const valid = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pair.publicKey, signature, data);
    checksum ^= valid ? new Uint8Array(signature)[i & 63] : 0xff;
  }
  return checksum;
}, { iterations: 450, warmup: 40 });

bench("crypto.subtle.ecdh-p256-derivebits-256", async iterations => {
  const alice = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
  const bob = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const bits = await crypto.subtle.deriveBits({ name: "ECDH", public: bob.publicKey }, alice.privateKey, 256);
    checksum ^= new Uint8Array(bits)[i & 31];
  }
  return checksum;
}, { iterations: 650, warmup: 60 });

bench("crypto.subtle.ecdh-p256-derivekey-aes-gcm-128", async iterations => {
  const alice = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, false, ["deriveKey"]);
  const bob = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, false, ["deriveKey"]);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const key = await crypto.subtle.deriveKey({ name: "ECDH", public: bob.publicKey }, alice.privateKey, { name: "AES-GCM", length: 128 }, true, ["encrypt"]);
    const exported = await crypto.subtle.exportKey("raw", key);
    checksum ^= new Uint8Array(exported)[i & 15];
  }
  return checksum;
}, { iterations: 420, warmup: 40 });

bench("crypto.subtle.ed25519-generate-key", async iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const pair = await crypto.subtle.generateKey("Ed25519", true, ["sign", "verify"]);
    checksum ^= pair.publicKey.algorithm.name.charCodeAt(i % 7);
    checksum ^= pair.privateKey.usages.length;
  }
  return checksum;
}, { iterations: 120, warmup: 12 });

bench("crypto.subtle.ed25519-jwk-roundtrip", async iterations => {
  const pair = await crypto.subtle.generateKey("Ed25519", true, ["sign", "verify"]);
  const publicJwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
  const privateJwk = await crypto.subtle.exportKey("jwk", pair.privateKey);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const publicKey = await crypto.subtle.importKey("jwk", publicJwk, "Ed25519", true, ["verify"]);
    const privateKey = await crypto.subtle.importKey("jwk", privateJwk, "Ed25519", true, ["sign"]);
    const exportedPublic = await crypto.subtle.exportKey("jwk", publicKey);
    const exportedPrivate = await crypto.subtle.exportKey("jwk", privateKey);
    checksum ^= exportedPublic.x.charCodeAt(i % exportedPublic.x.length);
    checksum ^= exportedPrivate.d.charCodeAt(i % exportedPrivate.d.length);
  }
  return checksum;
}, { iterations: 220, warmup: 20 });

bench("crypto.subtle.ed25519-sign-verify", async iterations => {
  const pair = await crypto.subtle.generateKey("Ed25519", false, ["sign", "verify"]);
  const data = new Uint8Array(64);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    data[0] = i & 0xff;
    const signature = await crypto.subtle.sign("Ed25519", pair.privateKey, data);
    const valid = await crypto.subtle.verify("Ed25519", pair.publicKey, signature, data);
    checksum ^= valid ? new Uint8Array(signature)[i & 63] : 0xff;
  }
  return checksum;
}, { iterations: 900, warmup: 80 });

bench("crypto.subtle.x25519-generate-key", async iterations => {
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const pair = await crypto.subtle.generateKey("X25519", true, ["deriveBits"]);
    checksum ^= pair.publicKey.algorithm.name.charCodeAt(i % 6);
    checksum ^= pair.privateKey.usages.length;
  }
  return checksum;
}, { iterations: 140, warmup: 14 });

bench("crypto.subtle.x25519-jwk-roundtrip", async iterations => {
  const pair = await crypto.subtle.generateKey("X25519", true, ["deriveBits", "deriveKey"]);
  const publicJwk = await crypto.subtle.exportKey("jwk", pair.publicKey);
  const privateJwk = await crypto.subtle.exportKey("jwk", pair.privateKey);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const publicKey = await crypto.subtle.importKey("jwk", publicJwk, "X25519", true, []);
    const privateKey = await crypto.subtle.importKey("jwk", privateJwk, "X25519", true, ["deriveBits"]);
    const exportedPublic = await crypto.subtle.exportKey("jwk", publicKey);
    const exportedPrivate = await crypto.subtle.exportKey("jwk", privateKey);
    checksum ^= exportedPublic.x.charCodeAt(i % exportedPublic.x.length);
    checksum ^= exportedPrivate.d.charCodeAt(i % exportedPrivate.d.length);
  }
  return checksum;
}, { iterations: 220, warmup: 20 });

bench("crypto.subtle.x25519-derivebits-256", async iterations => {
  const alice = await crypto.subtle.generateKey("X25519", false, ["deriveBits"]);
  const bob = await crypto.subtle.generateKey("X25519", false, ["deriveBits"]);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const bits = await crypto.subtle.deriveBits({ name: "X25519", public: bob.publicKey }, alice.privateKey, 256);
    checksum ^= new Uint8Array(bits)[i & 31];
  }
  return checksum;
}, { iterations: 900, warmup: 80 });

bench("crypto.subtle.x25519-derivekey-aes-gcm-128", async iterations => {
  const alice = await crypto.subtle.generateKey("X25519", false, ["deriveKey"]);
  const bob = await crypto.subtle.generateKey("X25519", false, ["deriveKey"]);
  let checksum = 0;
  for (let i = 0; i < iterations; i++) {
    const key = await crypto.subtle.deriveKey({ name: "X25519", public: bob.publicKey }, alice.privateKey, { name: "AES-GCM", length: 128 }, true, ["encrypt"]);
    const exported = await crypto.subtle.exportKey("raw", key);
    checksum ^= new Uint8Array(exported)[i & 15];
  }
  return checksum;
}, { iterations: 600, warmup: 60 });
