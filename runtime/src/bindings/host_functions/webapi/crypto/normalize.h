// Turns the JavaScript arguments of SubtleCrypto methods into native parameters, following the Web Cryptography API's
// algorithm normalization: algorithm names, hash identifiers, key usages, per-algorithm parameter dictionaries and
// derive-bits lengths. Runs on the VM thread, and the getters it reads may run script. Every parser fails the same
// way: it returns false and stores the reason in `out_error` (a TypeError, a DOMException, or the exception a getter
// threw, taken out of the scope), so the method rejects its promise instead of throwing. The parameter structs own
// copies of the buffers they read, which a method may move into a crypto job; `EcdhParams` and `X25519Params` hold a
// raw cell pointer, valid only during the method call that parsed it.

#pragma once

#include "host_functions/webapi/crypto/objects.h"
#include "host_functions/webapi/crypto/types.h"

#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/JSCJSValue.h>
#include <JavaScriptCore/JSObject.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>

namespace JSC {
class TopExceptionScope;
class JSGlobalObject;
class VM;
}

namespace Collo::HostFunctions::WebCrypto {

struct AesGcmParams {
    WTF::Vector<uint8_t> iv;
    WTF::Vector<uint8_t> additional_data;
    size_t tag_bytes { 16 };
};

struct AesCbcParams {
    WTF::Vector<uint8_t> iv;
};

struct AesCfbParams {
    WTF::Vector<uint8_t> iv;
};

struct AesCtrParams {
    WTF::Vector<uint8_t> counter;
    uint8_t length { 0 };
};

struct Pbkdf2Params {
    WTF::Vector<uint8_t> salt;
    uint32_t iterations { 0 };
    const HashSpec* hash { nullptr };
};

struct HkdfParams {
    WTF::Vector<uint8_t> salt;
    WTF::Vector<uint8_t> info;
    const HashSpec* hash { nullptr };
};

struct RsaHashedKeyGenParams {
    uint32_t modulus_length { 0 };
    WTF::Vector<uint8_t> public_exponent;
    const HashSpec* hash { nullptr };
};

struct RsaKeyGenParams {
    uint32_t modulus_length { 0 };
    WTF::Vector<uint8_t> public_exponent;
};

struct RsaPssParams {
    uint32_t salt_length { 0 };
};

struct RsaOaepParams {
    WTF::Vector<uint8_t> label;
};

struct EcKeyParams {
    CryptoKeyNamedCurve named_curve { CryptoKeyNamedCurve::None };
};

struct EcdsaParams {
    const HashSpec* hash { nullptr };
};

// A crypto job holds the public key through `retainSharedPkey`, never through this pointer; the same holds for
// `X25519Params`.
struct EcdhParams {
    JSColloCryptoKey* public_key { nullptr };
};

struct X25519Params {
    JSColloCryptoKey* public_key { nullptr };
};

struct DerivedKeySpec {
    CryptoKeyAlgorithm algorithm { CryptoKeyAlgorithm::AesGcm };
    const HashSpec* hash { nullptr };
    size_t length_bits { 0 };
};

bool algorithmName(
    JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue, WTF::String& out, JSC::JSValue& out_error);

bool normalizeHashAlgorithm(
    JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue, const HashSpec*& out, JSC::JSValue& out_error);

bool normalizeHmacAlgorithmAfterName(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue,
    const WTF::String& name, const HashSpec*& out_hash, std::optional<size_t>& out_length_bits,
    JSC::JSValue& out_error);

bool normalizeHmacAlgorithm(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue, const HashSpec*& out_hash,
    std::optional<size_t>& out_length_bits, JSC::JSValue& out_error);

bool normalizeHmacOperation(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue, JSC::JSValue& out_error);

bool normalizeAesNameAfterName(JSC::JSValue, const WTF::String& name, CryptoKeyAlgorithm expected,
    JSC::JSObject*& out_object, JSC::JSValue& out_error, JSC::JSGlobalObject*);

struct CryptoKeyUsageName {
    uint8_t bit;
    WTF::ASCIILiteral name;
};

// The recognized key usage values in the order of the KeyUsage enumeration, which the Web Cryptography API's usage
// intersection keeps. `key.usages` and an exported JWK's `key_ops` both list usages in this order, whatever the bit
// values.
inline constexpr std::array<CryptoKeyUsageName, 8> orderedCryptoKeyUsages { {
    { CryptoKeyUsageEncrypt, "encrypt"_s },
    { CryptoKeyUsageDecrypt, "decrypt"_s },
    { CryptoKeyUsageSign, "sign"_s },
    { CryptoKeyUsageVerify, "verify"_s },
    { CryptoKeyUsageDeriveKey, "deriveKey"_s },
    { CryptoKeyUsageDeriveBits, "deriveBits"_s },
    { CryptoKeyUsageWrapKey, "wrapKey"_s },
    { CryptoKeyUsageUnwrapKey, "unwrapKey"_s },
} };

bool parseKeyUsages(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue, uint8_t& out, JSC::JSValue& out_error);

// Like `parseKeyUsages`, but an unknown usage is a DataError: `key_ops` is a list of strings in a JWK, not a WebIDL
// enumeration whose conversion fails with a TypeError.
bool parseJwkKeyOps(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue, uint8_t& out, JSC::JSValue& out_error);

// Both fail with SyntaxError: the first when `usages` holds a bit outside `allowed`, the second when it is empty.
bool validateRequestedUsages(uint8_t usages, uint8_t allowed, JSC::JSValue& out_error, JSC::JSGlobalObject*);

bool validateRequiredUsages(uint8_t usages, JSC::JSValue& out_error, JSC::JSGlobalObject*);

// A new array of the usage names in `orderedCryptoKeyUsages` order. Null means allocation failed and an exception is
// pending.
JSC::JSArray* createUsagesArray(JSC::JSGlobalObject*, JSC::VM&, uint8_t usages);

bool parseAesGcmParamsAfterName(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue, const WTF::String& name,
    AesGcmParams& out, JSC::JSValue& out_error);

bool parseAesCbcParamsAfterName(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue, const WTF::String& name,
    AesCbcParams& out, JSC::JSValue& out_error);

bool parseAesCfbParamsAfterName(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue, const WTF::String& name,
    AesCfbParams& out, JSC::JSValue& out_error);

bool parseAesCtrParamsAfterName(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue, const WTF::String& name,
    AesCtrParams& out, JSC::JSValue& out_error);

bool parseAesKwParamsAfterName(JSC::JSGlobalObject*, const WTF::String& name, JSC::JSValue, JSC::JSValue& out_error);

bool parsePbkdf2ParamsAfterName(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue, const WTF::String& name,
    Pbkdf2Params& out, JSC::JSValue& out_error);

bool parseHkdfParamsAfterName(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue, const WTF::String& name,
    HkdfParams& out, JSC::JSValue& out_error);

bool normalizeRsaHashedAlgorithmAfterName(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue,
    const WTF::String& name, CryptoKeyAlgorithm expected, const HashSpec*& out_hash, JSC::JSValue& out_error);

bool parseRsaHashedKeyGenParamsAfterName(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue,
    const WTF::String& name, CryptoKeyAlgorithm expected, RsaHashedKeyGenParams& out, JSC::JSValue& out_error);

bool parseRsaKeyGenParamsAfterName(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue, const WTF::String& name,
    CryptoKeyAlgorithm expected, RsaKeyGenParams& out, JSC::JSValue& out_error);

bool parseRsaPssParamsAfterName(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue, const WTF::String& name,
    RsaPssParams& out, JSC::JSValue& out_error);

bool parseRsaOaepParamsAfterName(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue, const WTF::String& name,
    RsaOaepParams& out, JSC::JSValue& out_error);

bool parseEcKeyParamsAfterName(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue, const WTF::String& name,
    CryptoKeyAlgorithm expected, EcKeyParams& out, JSC::JSValue& out_error);

bool parseEcdsaParamsAfterName(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue, const WTF::String& name,
    EcdsaParams& out, JSC::JSValue& out_error);

bool parseEcdhParamsAfterName(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue, const WTF::String& name,
    EcdhParams& out, JSC::JSValue& out_error);

bool parseX25519ParamsAfterName(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue, const WTF::String& name,
    X25519Params& out, JSC::JSValue& out_error);

// A positive multiple of 8 of at most `maxWebCryptoDerivedBytes` bytes; null or undefined is an OperationError.
bool parseDeriveBitsLength(
    JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue, size_t& out_bits, JSC::JSValue& out_error);

// For ECDH and X25519: a null or undefined length derives `full_length_bits`, the size of the shared secret, and a
// longer length is an OperationError. FIXME: A zero length also derives the full secret, while the Web Cryptography
// API's ECDH and X25519 derive bits operations return the first `length` bits, an empty result for zero;
// `runtime/tests/webapi/crypto/crypto.test.js` pins the full-secret behavior.
bool parseEcDeriveBitsLength(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue, size_t full_length_bits,
    size_t& out_bits, JSC::JSValue& out_error);

// For HKDF and PBKDF2: a null or undefined length derives `default_length_bits`, the hash's full output. FIXME: The
// Web Cryptography API's HKDF and PBKDF2 derive bits operations reject a null length with OperationError;
// `runtime/tests/webapi/crypto/crypto.test.js` pins the full-output behavior. An explicit length must be a multiple
// of 8 of at most `maxWebCryptoDerivedBytes` bytes, and zero is accepted.
bool parseKdfDeriveBitsLength(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue, size_t default_length_bits,
    size_t& out_bits, JSC::JSValue& out_error);

bool parseDerivedKeySpec(
    JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue, DerivedKeySpec& out, JSC::JSValue& out_error);

}
