// Web Crypto key import and export: one import core for byte formats (raw, spki, pkcs8) and one for JWK, both driven by
// an `ImportRequest` that importKey, unwrapKey and deriveKey normalize the same way, and one export core for each
// result shape, bytes or a JWK object. The JWK record is read from a JsonWebKey dictionary, which importKey gets from
// script and unwrapKey parses from the decrypted text, so both accept the same keys, the text holding each member as a
// JSON primitive and `key_ops` as an array of them. Everything here reads or
// builds JavaScript values, so it runs on the VM thread, and fails by throwing into the caller's ThrowScope and
// returning no value: a TypeError, a DOMException, an OutOfMemoryError, or what a getter threw. A new CryptoKey is
// rooted only by the caller's stack until the caller publishes it.

#pragma once

#include "host_functions/webapi/crypto/normalize.h"
#include "host_functions/webapi/crypto/objects.h"
#include "host_functions/webapi/crypto/types.h"

#include <JavaScriptCore/JSCJSValue.h>
#include <wtf/text/WTFString.h>

#include <cstdint>
#include <optional>
#include <span>

namespace JSC {
class JSGlobalObject;
class JSObject;
class ThrowScope;
}

namespace Collo::HostFunctions::WebCrypto {

// What an import makes: the normalized algorithm of the importKey operation, read from importKey's `algorithm`,
// unwrapKey's `unwrappedKeyAlgorithm` or deriveKey's `derivedKeyType`.
struct ImportRequest {
    KeyFormat format;
    const NormalizedAlgorithm& algorithm;
    bool extractable;
    uint8_t usages;
};

// The JsonWebKey members Collo reads; an absent or undefined member has no value. `oth`, for RSA keys with more than
// two primes, is never read.
struct JwkRecord {
    std::optional<WTF::String> alg;
    std::optional<WTF::String> crv;
    std::optional<WTF::String> d;
    std::optional<WTF::String> dp;
    std::optional<WTF::String> dq;
    std::optional<WTF::String> e;
    std::optional<bool> ext;
    std::optional<WTF::String> k;
    std::optional<KeyOps> key_ops;
    std::optional<WTF::String> kty;
    std::optional<WTF::String> n;
    std::optional<WTF::String> p;
    std::optional<WTF::String> q;
    std::optional<WTF::String> qi;
    std::optional<WTF::String> use;
    std::optional<WTF::String> x;
    std::optional<WTF::String> y;
};

// Converts a value to the JsonWebKey dictionary: undefined and null are an empty one, another non-object a TypeError,
// and an object's members are read with [[Get]] once each in lexicographic order.
std::optional<JwkRecord> readJwkRecord(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue);
// Parses the UTF-8 JSON text of a JWK, as unwrapKey's "parse a JWK" step does, and reads the parsed object's own data
// properties only, so no script runs and none sees the key: JSON.parse builds the object in the caller's realm, whose
// prototypes script controls, where the API parses in a new global object. Text longer than `jwk_text_bytes_max`,
// not UTF-8 or not JSON, a value that is not an object, a member that is not a primitive (or, for `key_ops`, not an
// array of primitives) and a JWK without `kty` are each a DataError. The text is a JavaScript string while it is
// parsed and the parsed strings are the collector's to free.
std::optional<JwkRecord> parseJwkRecord(JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<const uint8_t> text);

// HMAC import's rule for a declared `length`: it lies within (data bits - 8, data bits].
inline bool hmacLengthFits(std::optional<uint32_t> length_bits, size_t key_bytes)
{
    if (!length_bits)
        return true;
    const size_t declared_bits = *length_bits;
    return declared_bits <= key_bytes * 8 && declared_bits + 8 > key_bytes * 8;
}

// The hash an RSA key imported with `algorithm` keeps: the normalized hash, or SHA-1 for RSAES-PKCS1-v1_5, whose keys
// take none and never read it.
inline WebCryptoHash importedRsaHash(const NormalizedAlgorithm& algorithm)
{
    if (auto* params = std::get_if<HashParams>(&algorithm.params))
        return params->hash->id;
    return WebCryptoHash::SHA1;
}

// Imports `bytes` in a byte format: the raw bytes of a secret, EC or OKP public key, a SubjectPublicKeyInfo, or a
// PrivateKeyInfo. A format the algorithm has no import for is a NotSupportedError, usages the key may not hold, or no
// usages for a secret or private key, a SyntaxError, and key data that does not decode to a fitting key a DataError.
JSColloCryptoKey* importKeyFromBytes(JSC::JSGlobalObject*, JSC::ThrowScope&, const ImportRequest&, SecretBytes&& bytes);
JSColloCryptoKey* importKeyFromJwk(JSC::JSGlobalObject*, JSC::ThrowScope&, const ImportRequest&, const JwkRecord&);

// The checks before any export: PBKDF2 and HKDF keys have none, a NotSupportedError, and a nonextractable key is an
// InvalidAccessError.
void checkExportable(JSC::JSGlobalObject*, JSC::ThrowScope&, JSColloCryptoKey*);
// Exports `key` in the byte format `format`. A key type the format does not carry, a private key for raw or spki or a
// public key for pkcs8, is an InvalidAccessError; a key family without the format a NotSupportedError.
std::optional<SecretBytes> exportKeyBytes(JSC::JSGlobalObject*, JSC::ThrowScope&, KeyFormat, JSColloCryptoKey*);
// The JWK object exportKey resolves with. A PBKDF2 or HKDF key is a NotSupportedError.
JSC::JSObject* exportJwk(JSC::JSGlobalObject*, JSC::ThrowScope&, JSColloCryptoKey*);
// The UTF-8 JSON text wrapKey encrypts: what JSON.stringify gives for `exportJwk`'s object in a new global object,
// written natively, so no `toJSON` or other script can change it.
std::optional<SecretBytes> exportJwkText(JSC::JSGlobalObject*, JSC::ThrowScope&, JSColloCryptoKey*);

// Decodes a base64url JWK member into a SecretBytes allocated once at the decoded length's upper bound and shrunk to
// it. It accepts the URL alphabet, then nothing but '=' padding of any count, and refuses whitespace; anything else is
// a DataError.
std::optional<SecretBytes> decodeBase64UrlMember(JSC::JSGlobalObject*, JSC::ThrowScope&, const WTF::String&);

}
