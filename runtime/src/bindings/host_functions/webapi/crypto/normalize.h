// The Web Cryptography API's conversions of SubtleCrypto arguments into native values: algorithm normalization through
// the registration table (algorithms.h), hash identifiers, key usages, JWK `key_ops`, key formats and secret
// BufferSources. Runs on the VM thread. Every conversion reads script values, whose getters may run script, and fails
// by throwing into the caller's ThrowScope: a TypeError for a value of the wrong type, NotSupportedError for an
// unregistered algorithm, OperationError for a parameter value an operation refuses, or whatever a getter threw. On
// failure it returns no value.
//
// A normalized algorithm reads its name once and each member of its parameter dictionary once, in the order WebIDL
// converts dictionary members in, an inherited dictionary's members first and each dictionary's in lexicographic order,
// and copies every BufferSource member, so later script cannot change the parameters. `EcdhKeyDeriveParams` holds a raw
// cell pointer, which the stack roots for the method call that normalized it and no longer.

#pragma once

#include "host_functions/webapi/crypto/algorithms.h"
#include "host_functions/webapi/crypto/objects.h"
#include "host_functions/webapi/crypto/types.h"

#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/JSCJSValue.h>
#include <wtf/Assertions.h>
#include <wtf/Vector.h>
#include <wtf/text/ASCIILiteral.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <variant>

namespace JSC {
class JSGlobalObject;
class ThrowScope;
}

namespace Collo::HostFunctions::WebCrypto {

// AesCbcParams, which 8-bit AES-CFB shares: `iv` is 16 bytes.
struct AesCbcParams {
    WTF::Vector<uint8_t> iv;
};

// `counter` is 16 bytes and `length` within [1, 128].
struct AesCtrParams {
    WTF::Vector<uint8_t> counter;
    uint8_t length { 0 };
};

// `iv` is not empty and fits an int, and `tag_bytes` is one of the tag lengths the API allows.
struct AesGcmParams {
    WTF::Vector<uint8_t> additional_data;
    WTF::Vector<uint8_t> iv;
    size_t tag_bytes { 16 };
};

// AesKeyGenParams and AesDerivedKeyParams. `length` is the number as given; the operation that uses it refuses a value
// other than 128, 192 or 256 with OperationError.
struct AesLengthParams {
    double length { 0 };
};

// HmacImportParams and HmacKeyGenParams. `length_bits`, when present, is within [1, 2^32 - 1].
struct HmacParams {
    const HashSpec* hash { nullptr };
    std::optional<uint32_t> length_bits;
};

// RsaHashedImportParams and EcdsaParams.
struct HashParams {
    const HashSpec* hash { nullptr };
};

// RsaKeyGenParams, and RsaHashedKeyGenParams with a hash. `public_exponent` is not empty.
struct RsaKeyGenParams {
    const HashSpec* hash { nullptr };
    uint32_t modulus_bits { 0 };
    WTF::Vector<uint8_t> public_exponent;
};

struct RsaPssParams {
    uint32_t salt_length { 0 };
};

struct RsaOaepParams {
    WTF::Vector<uint8_t> label;
};

// EcKeyGenParams and EcKeyImportParams: one of P-256, P-384 and P-521.
struct EcKeyParams {
    CryptoKeyNamedCurve named_curve { CryptoKeyNamedCurve::None };
};

// EcdhKeyDeriveParams, for ECDH and X25519.
struct EcdhKeyDeriveParams {
    JSColloCryptoKey* public_key { nullptr };
};

struct Pbkdf2Params {
    const HashSpec* hash { nullptr };
    uint32_t iterations { 0 };
    WTF::Vector<uint8_t> salt;
};

struct HkdfParams {
    const HashSpec* hash { nullptr };
    WTF::Vector<uint8_t> info;
    WTF::Vector<uint8_t> salt;
};

using AlgorithmParams
    = std::variant<std::monostate, AesCbcParams, AesCtrParams, AesGcmParams, AesLengthParams, HmacParams, HashParams,
        RsaKeyGenParams, RsaPssParams, RsaOaepParams, EcKeyParams, EcdhKeyDeriveParams, Pbkdf2Params, HkdfParams>;

struct NormalizedAlgorithm {
    CryptoKeyAlgorithm id;
    AlgorithmParams params;

    const AlgorithmSpec& spec() const { return algorithmSpec(id); }

    // The parameters the registration of `id` for the normalizing operation reads, which the caller names by type.
    template <typename Params> const Params& paramsAs() const
    {
        auto* params_value = std::get_if<Params>(&params);
        RELEASE_ASSERT(params_value);
        return *params_value;
    }
};

std::optional<NormalizedAlgorithm> normalizeAlgorithm(JSC::JSGlobalObject*, JSC::ThrowScope&, Operation, JSC::JSValue);

// A HashAlgorithmIdentifier, normalized as the digest operation would; null on failure.
const HashSpec* normalizeHashAlgorithm(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue);

// The KeyFormat enumeration; any other string is a TypeError.
std::optional<KeyFormat> parseKeyFormat(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue);

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

// A sequence<KeyUsage>, read as an array-like object of at most `key_usages_length_max` entries. A value that names
// no usage is a TypeError, as WebIDL's enumeration conversion fails.
std::optional<uint8_t> parseKeyUsages(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue);

// A JWK `key_ops` list, read like the usages. Its entries are strings, not a WebIDL enumeration, so a value that names
// no usage is recorded for the import to refuse with a DataError instead of failing here.
struct KeyOps {
    uint8_t usages { 0 };
    bool names_unknown_usage { false };
};
std::optional<KeyOps> readKeyOps(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue);
// Adds the usage `name` names to `key_ops`, or records that it names none.
void noteKeyOp(KeyOps&, const WTF::String& name);

// A new array of the usage names in `orderedCryptoKeyUsages` order.
JSC::JSArray* createUsagesArray(JSC::JSGlobalObject*, JSC::ThrowScope&, uint8_t usages);

// Copies a BufferSource that holds secret bytes, such as key data, into a SecretBytes; fails like copyBufferSource in
// js_support.h.
std::optional<SecretBytes> copySecretBufferSource(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue);

}
