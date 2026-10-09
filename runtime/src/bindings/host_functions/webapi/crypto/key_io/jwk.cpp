// JWK import and export under the contract in key_io.h. Import reads members through property gets, which can run
// script, so it keeps only copied values across reads. Export builds the JWK object exportKey returns for RSA, EC and
// OKP keys, or the JSON text wrapKey encrypts. Secret members pass through buffers that are zeroed before they are
// freed, among them the component structs below and secretBase64UrlJsString; a FIXME marks each buffer that is not.

#include "jsc/runtime/state.h"

#include "host_functions/webapi/crypto/key_io/key_io.h"

#include "host_functions/webapi/crypto/keys.h"
#include "host_functions/webapi/crypto/ops/symmetric.h"
#include "jsc/runtime/js_support.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/JSCInlines.h>
#include <openssl/bn.h>
#include <openssl/ec.h>
#include <openssl/ec_key.h>
#include <openssl/evp.h>
#include <openssl/nid.h>
#include <openssl/pkcs8.h>
#include <openssl/rsa.h>
#include <openssl/x509.h>
#include <wtf/text/Base64.h>
#include <wtf/text/WTFString.h>

#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <optional>

namespace Collo::HostFunctions::WebCrypto {

using JSC::JSValue;
using WTF::String;
using namespace Collo::JscSupport;

JSC::JSString* secretBase64UrlJsString(JSC::VM& vm, std::span<const uint8_t> bytes)
{
    WTF::Vector<uint8_t> encoded = WTF::base64URLEncodeToVector(bytes);
    // String copies the ASCII bytes into its own StringImpl, so zeroing `encoded` afterwards leaves the result intact.
    auto* result = JSC::jsString(vm,
        String { std::span<const Latin1Character> {
            reinterpret_cast<const Latin1Character*>(encoded.span().data()), encoded.size() } });
    secureZeroVector(encoded);
    return result;
}

static bool appendAscii(WTF::Vector<uint8_t>& out, const char* text)
{
    auto bytes = std::span<const uint8_t> { reinterpret_cast<const uint8_t*>(text), std::strlen(text) };
    return out.tryAppend(bytes);
}

template <size_t N> static bool appendAscii(WTF::Vector<uint8_t>& out, const char (&text)[N])
{
    auto bytes = std::span<const uint8_t> { reinterpret_cast<const uint8_t*>(text), N - 1 };
    return out.tryAppend(bytes);
}

static bool appendAscii(WTF::Vector<uint8_t>& out, WTF::ASCIILiteral text)
{
    auto span = text.span8();
    auto bytes = std::span<const uint8_t> { reinterpret_cast<const uint8_t*>(span.data()), span.size() };
    return out.tryAppend(bytes);
}

static bool appendBase64Url(WTF::Vector<uint8_t>& out, std::span<const uint8_t> bytes)
{
    static constexpr char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

    const size_t full_groups = bytes.size() / 3;
    const size_t remainder = bytes.size() % 3;
    if (full_groups > std::numeric_limits<size_t>::max() / 4)
        return false;
    size_t encoded_length = full_groups * 4;
    if (remainder) {
        if (encoded_length > std::numeric_limits<size_t>::max() - (remainder + 1))
            return false;
        encoded_length += remainder + 1;
    }
    if (out.size() > std::numeric_limits<size_t>::max() - encoded_length)
        return false;

    const size_t old_size = out.size();
    if (!out.tryGrow(old_size + encoded_length))
        return false;
    auto* dst = out.mutableSpan().data() + old_size;
    size_t dst_index = 0;
    size_t src_index = 0;

    for (size_t group = 0; group < full_groups; ++group) {
        const uint32_t value = (static_cast<uint32_t>(bytes[src_index]) << 16)
            | (static_cast<uint32_t>(bytes[src_index + 1]) << 8) | static_cast<uint32_t>(bytes[src_index + 2]);
        src_index += 3;
        dst[dst_index++] = static_cast<uint8_t>(alphabet[(value >> 18) & 0x3f]);
        dst[dst_index++] = static_cast<uint8_t>(alphabet[(value >> 12) & 0x3f]);
        dst[dst_index++] = static_cast<uint8_t>(alphabet[(value >> 6) & 0x3f]);
        dst[dst_index++] = static_cast<uint8_t>(alphabet[value & 0x3f]);
    }

    if (remainder == 1) {
        const uint32_t value = static_cast<uint32_t>(bytes[src_index]) << 16;
        dst[dst_index++] = static_cast<uint8_t>(alphabet[(value >> 18) & 0x3f]);
        dst[dst_index++] = static_cast<uint8_t>(alphabet[(value >> 12) & 0x3f]);
    } else if (remainder == 2) {
        const uint32_t value
            = (static_cast<uint32_t>(bytes[src_index]) << 16) | (static_cast<uint32_t>(bytes[src_index + 1]) << 8);
        dst[dst_index++] = static_cast<uint8_t>(alphabet[(value >> 18) & 0x3f]);
        dst[dst_index++] = static_cast<uint8_t>(alphabet[(value >> 12) & 0x3f]);
        dst[dst_index++] = static_cast<uint8_t>(alphabet[(value >> 6) & 0x3f]);
    }

    ASSERT(dst_index == encoded_length);
    return true;
}

static bool appendUsageJson(WTF::Vector<uint8_t>& out, WTF::ASCIILiteral usage, bool& first)
{
    if (!first && !appendAscii(out, ","))
        return false;
    first = false;
    return appendAscii(out, "\"") && appendAscii(out, usage) && appendAscii(out, "\"");
}

struct RsaComponents {
    ~RsaComponents()
    {
        secureZeroVector(d);
        secureZeroVector(p);
        secureZeroVector(q);
        secureZeroVector(dp);
        secureZeroVector(dq);
        secureZeroVector(qi);
    }

    WTF::Vector<uint8_t> n;
    WTF::Vector<uint8_t> e;
    WTF::Vector<uint8_t> d;
    WTF::Vector<uint8_t> p;
    WTF::Vector<uint8_t> q;
    WTF::Vector<uint8_t> dp;
    WTF::Vector<uint8_t> dq;
    WTF::Vector<uint8_t> qi;
    bool is_private { false };
};

class ClearBnGuard {
public:
    explicit ClearBnGuard(bssl::UniquePtr<BIGNUM>& value)
        : m_value(&value)
    {
    }

    ClearBnGuard(const ClearBnGuard&) = delete;
    ClearBnGuard& operator=(const ClearBnGuard&) = delete;

    ~ClearBnGuard()
    {
        if (m_value && m_value->get())
            BN_clear_free(m_value->release());
    }

private:
    bssl::UniquePtr<BIGNUM>* m_value { nullptr };
};

static bool bnModPrimeMinusOne(const BIGNUM* prime, const BIGNUM* d, BN_CTX* context, WTF::Vector<uint8_t>& out)
{
    bssl::UniquePtr<BIGNUM> minus_one(BN_dup(prime));
    bssl::UniquePtr<BIGNUM> result(BN_new());
    ClearBnGuard minus_one_guard(minus_one);
    ClearBnGuard result_guard(result);
    if (!minus_one || !result)
        return false;
    if (BN_sub_word(minus_one.get(), 1) != 1)
        return false;
    if (BN_mod(result.get(), d, minus_one.get(), context) != 1)
        return false;
    return bnToBytes(result.get(), out);
}

static bool exportRsaComponents(JSColloCryptoKey* key, RsaComponents& out)
{
    RSA* rsa = EVP_PKEY_get0_RSA(key->rsaKey());
    if (!rsa)
        return false;

    const BIGNUM* n = nullptr;
    const BIGNUM* e = nullptr;
    const BIGNUM* d = nullptr;
    RSA_get0_key(rsa, &n, &e, &d);
    if (!n || !e)
        return false;

    out.is_private = key->type() == CryptoKeyType::Private;
    if (!bnToBytes(n, out.n) || !bnToBytes(e, out.e))
        return false;
    if (!out.is_private)
        return true;
    if (!d || !bnToBytes(d, out.d))
        return false;

    const BIGNUM* p = nullptr;
    const BIGNUM* q = nullptr;
    RSA_get0_factors(rsa, &p, &q);
    if (!p || !q || !bnToBytes(p, out.p) || !bnToBytes(q, out.q))
        return false;

    const BIGNUM* dmp1 = nullptr;
    const BIGNUM* dmq1 = nullptr;
    const BIGNUM* iqmp = nullptr;
    RSA_get0_crt_params(rsa, &dmp1, &dmq1, &iqmp);
    if (dmp1 && !bnToBytes(dmp1, out.dp))
        return false;
    if (dmq1 && !bnToBytes(dmq1, out.dq))
        return false;
    if (iqmp && !bnToBytes(iqmp, out.qi))
        return false;

    if (!dmp1 || !dmq1 || !iqmp) {
        bssl::UniquePtr<BN_CTX> context(BN_CTX_new());
        if (!context)
            return false;
        // RFC 7518 section 6.3.2 requires dp, dq and qi whenever p and q are present, so a key without its CRT
        // parameters gets them computed: dp = d mod (p-1), dq = d mod (q-1) and qi = q^-1 mod p.
        if (!dmp1 && !bnModPrimeMinusOne(p, d, context.get(), out.dp))
            return false;
        if (!dmq1 && !bnModPrimeMinusOne(q, d, context.get(), out.dq))
            return false;
        if (!iqmp) {
            bssl::UniquePtr<BIGNUM> computed(BN_mod_inverse(nullptr, q, p, context.get()));
            ClearBnGuard computed_guard(computed);
            if (!computed || !bnToBytes(computed.get(), out.qi))
                return false;
        }
    }
    return !out.dp.isEmpty() && !out.dq.isEmpty() && !out.qi.isEmpty();
}

static bool appendJsonBase64UrlField(WTF::Vector<uint8_t>& out, const char* name, std::span<const uint8_t> bytes)
{
    return appendAscii(out, ",\"") && appendAscii(out, name) && appendAscii(out, "\":\"") && appendBase64Url(out, bytes)
        && appendAscii(out, "\"");
}

static bool appendJwkUsagesJson(WTF::Vector<uint8_t>& out, uint8_t usages)
{
    bool first = true;
    for (const auto& usage : orderedCryptoKeyUsages) {
        if ((usages & usage.bit) && !appendUsageJson(out, usage.name, first))
            return false;
    }
    return true;
}

static bool bnToFixedBytes(const BIGNUM* bn, size_t byte_length, WTF::Vector<uint8_t>& out)
{
    if (!bn || BN_num_bytes(bn) > static_cast<int>(byte_length) || !out.tryReserveInitialCapacity(byte_length))
        return false;
    out.grow(byte_length);
    std::memset(out.mutableSpan().data(), 0, byte_length);
    BN_bn2bin(bn, out.mutableSpan().data() + byte_length - BN_num_bytes(bn));
    return true;
}

struct EcComponents {
    ~EcComponents() { secureZeroVector(d); }

    WTF::Vector<uint8_t> x;
    WTF::Vector<uint8_t> y;
    WTF::Vector<uint8_t> d;
    bool is_private { false };
};

static bool exportEcComponents(JSColloCryptoKey* key, EcComponents& out)
{
    auto* ec = EVP_PKEY_get0_EC_KEY(key->asymmetricKey());
    if (!ec)
        return false;

    auto curve = key->namedCurve();
    auto coordinate_bytes = coordinateBytesForNamedCurve(curve);
    auto* group = EC_KEY_get0_group(ec);
    auto* public_key = EC_KEY_get0_public_key(ec);
    if (!group || !public_key || !coordinate_bytes)
        return false;

    bssl::UniquePtr<BN_CTX> context(BN_CTX_new());
    bssl::UniquePtr<BIGNUM> x(BN_new());
    bssl::UniquePtr<BIGNUM> y(BN_new());
    if (!context || !x || !y)
        return false;
    if (EC_POINT_get_affine_coordinates_GFp(group, public_key, x.get(), y.get(), context.get()) != 1)
        return false;
    if (!bnToFixedBytes(x.get(), coordinate_bytes, out.x) || !bnToFixedBytes(y.get(), coordinate_bytes, out.y))
        return false;

    out.is_private = key->type() == CryptoKeyType::Private;
    if (!out.is_private)
        return true;
    auto* private_key = EC_KEY_get0_private_key(ec);
    return bnToFixedBytes(private_key, coordinate_bytes, out.d);
}

struct OkpComponents {
    ~OkpComponents() { secureZeroVector(d); }

    WTF::Vector<uint8_t> x;
    WTF::Vector<uint8_t> d;
    bool is_private { false };
};

static bool evpGetRawPrivate(EVP_PKEY* pkey, WTF::Vector<uint8_t>& out)
{
    size_t length = 0;
    if (EVP_PKEY_get_raw_private_key(pkey, nullptr, &length) != 1 || !length || !out.tryReserveInitialCapacity(length))
        return false;
    out.grow(length);
    return EVP_PKEY_get_raw_private_key(pkey, out.mutableSpan().data(), &length) == 1 && length == out.size();
}

static bool exportOkpComponents(JSColloCryptoKey* key, OkpComponents& out)
{
    if (!isOkpAlgorithm(key->algorithm()))
        return false;
    if (!evpGetRawPublic(key->asymmetricKey(), out.x) || out.x.size() != 32)
        return false;

    out.is_private = key->type() == CryptoKeyType::Private;
    if (!out.is_private)
        return true;
    return evpGetRawPrivate(key->asymmetricKey(), out.d) && out.d.size() == 32;
}

static bool appendRsaJwkJson(WTF::Vector<uint8_t>& out, JSColloCryptoKey* key)
{
    RsaComponents components;
    if (!exportRsaComponents(key, components))
        return false;

    if (!appendAscii(out, "{\"kty\":\"RSA\""))
        return false;
    if (!appendJsonBase64UrlField(out, "n", components.n.span()))
        return false;
    if (!appendJsonBase64UrlField(out, "e", components.e.span()))
        return false;
    if (components.is_private) {
        if (!appendJsonBase64UrlField(out, "d", components.d.span()))
            return false;
        if (!appendJsonBase64UrlField(out, "p", components.p.span()))
            return false;
        if (!appendJsonBase64UrlField(out, "q", components.q.span()))
            return false;
        if (!appendJsonBase64UrlField(out, "dp", components.dp.span()))
            return false;
        if (!appendJsonBase64UrlField(out, "dq", components.dq.span()))
            return false;
        if (!appendJsonBase64UrlField(out, "qi", components.qi.span()))
            return false;
    }
    const auto jwk_alg = rsaJwkAlgorithm(key->algorithm(), key->hash());
    if (!jwk_alg.isEmpty()) {
        if (!appendAscii(out, ",\"alg\":\""))
            return false;
        if (!appendAscii(out, jwk_alg))
            return false;
        if (!appendAscii(out, "\""))
            return false;
    }
    if (!appendAscii(out, ",\"ext\":"))
        return false;
    if (!appendAscii(out, key->extractable() ? "true" : "false"))
        return false;
    if (!appendAscii(out, ",\"key_ops\":["))
        return false;
    if (!appendJwkUsagesJson(out, key->usages()))
        return false;
    return appendAscii(out, "]}");
}

static bool appendEcJwkJson(WTF::Vector<uint8_t>& out, JSColloCryptoKey* key)
{
    EcComponents components;
    if (!exportEcComponents(key, components))
        return false;

    if (!appendAscii(out, "{\"kty\":\"EC\",\"crv\":\""))
        return false;
    if (!appendAscii(out, namedCurveName(key->namedCurve())))
        return false;
    if (!appendAscii(out, "\""))
        return false;
    if (!appendJsonBase64UrlField(out, "x", components.x.span()))
        return false;
    if (!appendJsonBase64UrlField(out, "y", components.y.span()))
        return false;
    if (components.is_private && !appendJsonBase64UrlField(out, "d", components.d.span()))
        return false;
    if (!appendAscii(out, ",\"ext\":"))
        return false;
    if (!appendAscii(out, key->extractable() ? "true" : "false"))
        return false;
    if (!appendAscii(out, ",\"key_ops\":["))
        return false;
    if (!appendJwkUsagesJson(out, key->usages()))
        return false;
    return appendAscii(out, "]}");
}

static bool appendOkpJwkJson(WTF::Vector<uint8_t>& out, JSColloCryptoKey* key)
{
    OkpComponents components;
    if (!exportOkpComponents(key, components))
        return false;

    if (!appendAscii(out, "{\"kty\":\"OKP\",\"crv\":\""))
        return false;
    if (!appendAscii(out, namedCurveName(key->namedCurve())))
        return false;
    if (!appendAscii(out, "\""))
        return false;
    if (!appendJsonBase64UrlField(out, "x", components.x.span()))
        return false;
    if (components.is_private && !appendJsonBase64UrlField(out, "d", components.d.span()))
        return false;
    if (!appendAscii(out, ",\"ext\":"))
        return false;
    if (!appendAscii(out, key->extractable() ? "true" : "false"))
        return false;
    if (!appendAscii(out, ",\"key_ops\":["))
        return false;
    if (!appendJwkUsagesJson(out, key->usages()))
        return false;
    return appendAscii(out, "]}");
}

static bool appendJwkJson(WTF::Vector<uint8_t>& out, JSColloCryptoKey* key)
{
    if (isRsaAlgorithm(key->algorithm()))
        return appendRsaJwkJson(out, key);
    if (isEcAlgorithm(key->algorithm()))
        return appendEcJwkJson(out, key);
    if (isOkpAlgorithm(key->algorithm()))
        return appendOkpJwkJson(out, key);

    if (!appendAscii(out, "{\"kty\":\"oct\",\"k\":\""))
        return false;
    if (!appendBase64Url(out, key->material()))
        return false;
    if (!appendAscii(out, "\""))
        return false;
    if (key->algorithm() == CryptoKeyAlgorithm::Hmac) {
        const auto& jwk_alg = hashSpec(key->hash()).jwk_alg;
        if (!jwk_alg.isEmpty()) {
            if (!appendAscii(out, ",\"alg\":\""))
                return false;
            if (!appendAscii(out, jwk_alg))
                return false;
            if (!appendAscii(out, "\""))
                return false;
        }
    } else {
        if (!appendAscii(out, ",\"alg\":\""))
            return false;
        if (!appendAscii(out, aesJwkAlgorithm(key->algorithm(), key->material().size())))
            return false;
        if (!appendAscii(out, "\""))
            return false;
    }
    if (!appendAscii(out, ",\"ext\":"))
        return false;
    if (!appendAscii(out, key->extractable() ? "true" : "false"))
        return false;
    if (!appendAscii(out, ",\"key_ops\":["))
        return false;

    if (!appendJwkUsagesJson(out, key->usages()))
        return false;

    return appendAscii(out, "]}");
}

static bool getStringPropertyIfPresent(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope,
    JSC::JSObject* object, WTF::ASCIILiteral name, std::optional<String>& out, JSC::JSValue& out_error)
{
    auto value = object->getIfPropertyExists(global_object, JSC::Identifier::fromString(global_object->vm(), name));
    if (takePendingException(scope, out_error))
        return false;
    if (!value || value.isUndefined()) {
        out = std::nullopt;
        return true;
    }
    out = valueToStringForPromise(global_object, scope, value, out_error);
    return !out_error;
}

bool makeHmacKeyFromJwk(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue key_data_value,
    JSValue algorithm_value, const String& algorithm_name, JSValue extractable_value, JSValue usages_value,
    JSColloCryptoKey*& out_key, JSC::JSValue& out_error)
{
    auto* jwk = dynamicDowncast<JSC::JSObject>(key_data_value);
    if (!jwk) {
        out_error = typeErrorValue(global_object, "JWK key data must be an object"_s);
        return false;
    }

    const HashSpec* hash = nullptr;
    std::optional<size_t> length_bits;
    if (!normalizeHmacAlgorithmAfterName(
            global_object, scope, algorithm_value, algorithm_name, hash, length_bits, out_error))
        return false;

    uint8_t usages = 0;
    if (!parseKeyUsages(global_object, scope, usages_value, usages, out_error))
        return false;
    if (!validateRequestedUsages(usages, CryptoKeyUsageSign | CryptoKeyUsageVerify, out_error, global_object))
        return false;
    if (!validateRequiredUsages(usages, out_error, global_object))
        return false;

    std::optional<String> kty;
    if (!getStringPropertyIfPresent(global_object, scope, jwk, "kty"_s, kty, out_error))
        return false;
    if (!kty) {
        out_error = typeErrorValue(global_object, "JsonWebKey.kty is required"_s);
        return false;
    }
    std::optional<String> k;
    if (!getStringPropertyIfPresent(global_object, scope, jwk, "k"_s, k, out_error))
        return false;
    if (*kty != "oct"_s || !k) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    std::optional<String> alg;
    if (!getStringPropertyIfPresent(global_object, scope, jwk, "alg"_s, alg, out_error))
        return false;
    if (alg && !alg->isEmpty() && *alg != hash->jwk_alg) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    std::optional<String> use;
    if (!getStringPropertyIfPresent(global_object, scope, jwk, "use"_s, use, out_error))
        return false;
    if (usages && use && !use->isEmpty() && *use != "sig"_s) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    auto ext_value = jwk->getIfPropertyExists(global_object, JSC::Identifier::fromString(global_object->vm(), "ext"_s));
    if (takePendingException(scope, out_error))
        return false;
    if (ext_value && !ext_value.isUndefined() && !ext_value.toBoolean(global_object)
        && extractable_value.toBoolean(global_object)) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    auto key_ops
        = jwk->getIfPropertyExists(global_object, JSC::Identifier::fromString(global_object->vm(), "key_ops"_s));
    if (takePendingException(scope, out_error))
        return false;
    if (key_ops && !key_ops.isUndefined()) {
        uint8_t jwk_usages = 0;
        if (!parseJwkKeyOps(global_object, scope, key_ops, jwk_usages, out_error))
            return false;
        if ((jwk_usages & usages) != usages) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
    }

    // FIXME: base64URLDecode leaves the last quarter of the decoded sextets in the capacity past size(). Neither the
    // guard nor the key that takes `decoded` zeroes that capacity before it is freed.
    auto decoded = WTF::base64URLDecode(*k);
    if (!decoded || decoded->isEmpty()) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    SecureVectorGuard decoded_guard(*decoded);
    // Web Crypto HMAC import requires a declared length to satisfy data_bits - 8 < length <= data_bits.
    if (length_bits && (*length_bits > decoded->size() * 8 || *length_bits + 8 <= decoded->size() * 8)) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    out_key = createHmacKey(global_object, hash->id, WTF::move(*decoded), extractable_value.toBoolean(global_object),
        usages, length_bits.value_or(0));
    if (out_key)
        decoded_guard.dismiss();
    return !takePendingException(scope, out_error);
}

bool makeAesKeyFromJwk(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue key_data_value,
    JSValue algorithm_value, const String& algorithm_name, JSValue extractable_value, JSValue usages_value,
    JSColloCryptoKey*& out_key, JSC::JSValue& out_error)
{
    auto* jwk = dynamicDowncast<JSC::JSObject>(key_data_value);
    if (!jwk) {
        out_error = typeErrorValue(global_object, "JWK key data must be an object"_s);
        return false;
    }

    auto algorithm = aesAlgorithmFromName(algorithm_name);
    if (!algorithm) {
        out_error
            = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError, "Unrecognized algorithm name"_s);
        return false;
    }

    JSC::JSObject* algorithm_object = nullptr;
    if (!normalizeAesNameAfterName(
            algorithm_value, algorithm_name, *algorithm, algorithm_object, out_error, global_object))
        return false;

    uint8_t usages = 0;
    if (!parseKeyUsages(global_object, scope, usages_value, usages, out_error))
        return false;
    if (!validateRequestedUsages(usages, allowedUsagesForAes(*algorithm), out_error, global_object))
        return false;
    if (!validateRequiredUsages(usages, out_error, global_object))
        return false;

    std::optional<String> kty;
    if (!getStringPropertyIfPresent(global_object, scope, jwk, "kty"_s, kty, out_error))
        return false;
    if (!kty) {
        out_error = typeErrorValue(global_object, "JsonWebKey.kty is required"_s);
        return false;
    }
    std::optional<String> k;
    if (!getStringPropertyIfPresent(global_object, scope, jwk, "k"_s, k, out_error))
        return false;
    if (*kty != "oct"_s || !k) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    // FIXME: base64URLDecode leaves the last quarter of the decoded sextets in the capacity past size(). Neither the
    // guard nor the key that takes `decoded` zeroes that capacity before it is freed.
    auto decoded = WTF::base64URLDecode(*k);
    if (!decoded || !isValidAesKeyLength(decoded->size())) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    SecureVectorGuard decoded_guard(*decoded);

    std::optional<String> alg;
    if (!getStringPropertyIfPresent(global_object, scope, jwk, "alg"_s, alg, out_error))
        return false;
    if (alg && !alg->isEmpty() && *alg != aesJwkAlgorithm(*algorithm, decoded->size())) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    std::optional<String> use;
    if (!getStringPropertyIfPresent(global_object, scope, jwk, "use"_s, use, out_error))
        return false;
    if (usages && use && !use->isEmpty() && *use != "enc"_s) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    auto ext_value = jwk->getIfPropertyExists(global_object, JSC::Identifier::fromString(global_object->vm(), "ext"_s));
    if (takePendingException(scope, out_error))
        return false;
    if (ext_value && !ext_value.isUndefined() && !ext_value.toBoolean(global_object)
        && extractable_value.toBoolean(global_object)) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    auto key_ops
        = jwk->getIfPropertyExists(global_object, JSC::Identifier::fromString(global_object->vm(), "key_ops"_s));
    if (takePendingException(scope, out_error))
        return false;
    if (key_ops && !key_ops.isUndefined()) {
        uint8_t jwk_usages = 0;
        if (!parseJwkKeyOps(global_object, scope, key_ops, jwk_usages, out_error))
            return false;
        if ((jwk_usages & usages) != usages) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
    }

    out_key = createAesKey(
        global_object, *algorithm, WTF::move(*decoded), extractable_value.toBoolean(global_object), usages);
    if (out_key)
        decoded_guard.dismiss();
    return !takePendingException(scope, out_error);
}

static bool getRsaJwkInteger(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSC::JSObject* jwk,
    WTF::ASCIILiteral name, WTF::Vector<uint8_t>& out, bool trim_leading_zero, JSC::JSValue& out_error)
{
    std::optional<String> encoded;
    if (!getStringPropertyIfPresent(global_object, scope, jwk, name, encoded, out_error))
        return false;
    if (!encoded) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    // FIXME: base64URLDecode leaves the last quarter of the decoded sextets in the capacity past size(). `out` takes
    // that capacity along, and the caller's guard on a private member zeroes only size().
    auto decoded = WTF::base64URLDecode(*encoded);
    if (!decoded || decoded->isEmpty()) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    if (trim_leading_zero && decoded->size() > 1 && decoded->at(0) == 0)
        decoded->removeAt(0);
    out = WTF::move(*decoded);
    return true;
}

static bool validateRsaJwkCommon(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSC::JSObject* jwk,
    CryptoKeyAlgorithm algorithm, WebCryptoHash hash, uint8_t usages, bool extractable, JSC::JSValue& out_error)
{
    std::optional<String> kty;
    if (!getStringPropertyIfPresent(global_object, scope, jwk, "kty"_s, kty, out_error))
        return false;
    if (!kty) {
        out_error = typeErrorValue(global_object, "JsonWebKey.kty is required"_s);
        return false;
    }
    if (*kty != "RSA"_s) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    std::optional<String> alg;
    if (!getStringPropertyIfPresent(global_object, scope, jwk, "alg"_s, alg, out_error))
        return false;
    if (alg && !alg->isEmpty() && *alg != rsaJwkAlgorithm(algorithm, hash)) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    std::optional<String> use;
    if (!getStringPropertyIfPresent(global_object, scope, jwk, "use"_s, use, out_error))
        return false;
    if (usages && use && !use->isEmpty()) {
        const bool expects_encryption_use
            = algorithm == CryptoKeyAlgorithm::RsaOaep || algorithm == CryptoKeyAlgorithm::RsaEsPkcs1V15;
        bool ok = expects_encryption_use ? *use == "enc"_s : *use == "sig"_s;
        if (!ok) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
    }

    auto ext_value = jwk->getIfPropertyExists(global_object, JSC::Identifier::fromString(global_object->vm(), "ext"_s));
    if (takePendingException(scope, out_error))
        return false;
    if (ext_value && !ext_value.isUndefined() && !ext_value.toBoolean(global_object) && extractable) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    auto key_ops
        = jwk->getIfPropertyExists(global_object, JSC::Identifier::fromString(global_object->vm(), "key_ops"_s));
    if (takePendingException(scope, out_error))
        return false;
    if (key_ops && !key_ops.isUndefined()) {
        uint8_t jwk_usages = 0;
        if (!parseJwkKeyOps(global_object, scope, key_ops, jwk_usages, out_error))
            return false;
        if ((jwk_usages & usages) != usages) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
    }
    return true;
}

bool makeRsaKeyFromJwk(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue key_data_value,
    JSValue algorithm_value, const String& algorithm_name, JSValue extractable_value, JSValue usages_value,
    JSColloCryptoKey*& out_key, JSC::JSValue& out_error)
{
    auto* jwk = dynamicDowncast<JSC::JSObject>(key_data_value);
    if (!jwk) {
        out_error = typeErrorValue(global_object, "JWK key data must be an object"_s);
        return false;
    }

    auto algorithm = rsaAlgorithmFromName(algorithm_name);
    if (!algorithm) {
        out_error
            = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError, "Unrecognized algorithm name"_s);
        return false;
    }

    WebCryptoHash hash { WebCryptoHash::SHA1 };
    if (*algorithm != CryptoKeyAlgorithm::RsaEsPkcs1V15) {
        const HashSpec* hash_spec = nullptr;
        if (!normalizeRsaHashedAlgorithmAfterName(
                global_object, scope, algorithm_value, algorithm_name, *algorithm, hash_spec, out_error))
            return false;
        hash = hash_spec->id;
    }

    uint8_t usages = 0;
    if (!parseKeyUsages(global_object, scope, usages_value, usages, out_error))
        return false;

    std::optional<String> d_value;
    if (!getStringPropertyIfPresent(global_object, scope, jwk, "d"_s, d_value, out_error))
        return false;
    auto type = d_value ? CryptoKeyType::Private : CryptoKeyType::Public;
    if (!validateRequestedUsages(usages,
            type == CryptoKeyType::Private ? allowedPrivateUsagesForRsa(*algorithm)
                                           : allowedPublicUsagesForRsa(*algorithm),
            out_error, global_object))
        return false;
    if (type == CryptoKeyType::Private && !validateRequiredUsages(usages, out_error, global_object))
        return false;
    bool extractable = extractable_value.toBoolean(global_object);
    if (!validateRsaJwkCommon(global_object, scope, jwk, *algorithm, hash, usages, extractable, out_error))
        return false;

    WTF::Vector<uint8_t> n;
    WTF::Vector<uint8_t> e;
    if (!getRsaJwkInteger(global_object, scope, jwk, "n"_s, n, true, out_error))
        return false;
    if (!getRsaJwkInteger(global_object, scope, jwk, "e"_s, e, false, out_error))
        return false;
    if (n.size() > (maxWebCryptoRsaModulusLengthBits + 7) / 8) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    auto bn_n = bytesToBn(n.span());
    auto bn_e = bytesToBn(e.span());
    if (!bn_n || !bn_e) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    bssl::UniquePtr<RSA> rsa;
    if (type == CryptoKeyType::Public)
        rsa.reset(RSA_new_public_key_large_e(bn_n.get(), bn_e.get()));
    else {
        WTF::Vector<uint8_t> d;
        WTF::Vector<uint8_t> p;
        WTF::Vector<uint8_t> q;
        WTF::Vector<uint8_t> dp;
        WTF::Vector<uint8_t> dq;
        WTF::Vector<uint8_t> qi;
        SecureVectorGuard d_guard(d);
        SecureVectorGuard p_guard(p);
        SecureVectorGuard q_guard(q);
        SecureVectorGuard dp_guard(dp);
        SecureVectorGuard dq_guard(dq);
        SecureVectorGuard qi_guard(qi);
        if (!getRsaJwkInteger(global_object, scope, jwk, "d"_s, d, false, out_error))
            return false;
        if (!getRsaJwkInteger(global_object, scope, jwk, "p"_s, p, false, out_error))
            return false;
        if (!getRsaJwkInteger(global_object, scope, jwk, "q"_s, q, false, out_error))
            return false;
        if (!getRsaJwkInteger(global_object, scope, jwk, "dp"_s, dp, false, out_error))
            return false;
        if (!getRsaJwkInteger(global_object, scope, jwk, "dq"_s, dq, false, out_error))
            return false;
        if (!getRsaJwkInteger(global_object, scope, jwk, "qi"_s, qi, false, out_error))
            return false;
        auto bn_d = bytesToBn(d.span());
        auto bn_p = bytesToBn(p.span());
        auto bn_q = bytesToBn(q.span());
        auto bn_dp = bytesToBn(dp.span());
        auto bn_dq = bytesToBn(dq.span());
        auto bn_qi = bytesToBn(qi.span());
        ClearBnGuard bn_d_guard(bn_d);
        ClearBnGuard bn_p_guard(bn_p);
        ClearBnGuard bn_q_guard(bn_q);
        ClearBnGuard bn_dp_guard(bn_dp);
        ClearBnGuard bn_dq_guard(bn_dq);
        ClearBnGuard bn_qi_guard(bn_qi);
        if (!bn_d || !bn_p || !bn_q || !bn_dp || !bn_dq || !bn_qi) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
        rsa.reset(RSA_new_private_key_large_e(
            bn_n.get(), bn_e.get(), bn_d.get(), bn_p.get(), bn_q.get(), bn_dp.get(), bn_dq.get(), bn_qi.get()));
    }

    if (!rsa) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    auto pkey = pkeyFromRsa(rsa.get());
    if (!pkey) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    out_key = createRsaKey(global_object, *algorithm, hash, type, WTF::move(pkey), extractable, usages);
    if (!out_key) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    return !takePendingException(scope, out_error);
}

static bool getEcJwkInteger(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSC::JSObject* jwk,
    WTF::ASCIILiteral name, size_t byte_length, WTF::Vector<uint8_t>& out, JSC::JSValue& out_error)
{
    std::optional<String> encoded;
    if (!getStringPropertyIfPresent(global_object, scope, jwk, name, encoded, out_error))
        return false;
    if (!encoded) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    // FIXME: base64URLDecode leaves the last quarter of the decoded sextets in the capacity past size(), which the
    // guard on `decoded` does not zero, so a private "d" leaves part of itself in freed memory.
    auto decoded = WTF::base64URLDecode(*encoded);
    if (!decoded || decoded->size() != byte_length || !out.tryReserveInitialCapacity(byte_length)) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    SecureVectorGuard decoded_guard(*decoded);
    out.append(decoded->span());
    return true;
}

static bool validateEcJwkCommon(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSC::JSObject* jwk,
    CryptoKeyAlgorithm algorithm, CryptoKeyNamedCurve curve, uint8_t usages, bool extractable, JSC::JSValue& out_error)
{
    std::optional<String> kty;
    if (!getStringPropertyIfPresent(global_object, scope, jwk, "kty"_s, kty, out_error))
        return false;
    if (!kty) {
        out_error = typeErrorValue(global_object, "JsonWebKey.kty is required"_s);
        return false;
    }
    if (*kty != "EC"_s) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    std::optional<String> crv;
    if (!getStringPropertyIfPresent(global_object, scope, jwk, "crv"_s, crv, out_error))
        return false;
    if (!crv || *crv != namedCurveName(curve)) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    std::optional<String> use;
    if (!getStringPropertyIfPresent(global_object, scope, jwk, "use"_s, use, out_error))
        return false;
    if (usages && use && !use->isEmpty()) {
        bool ok = algorithm == CryptoKeyAlgorithm::Ecdh ? *use == "enc"_s : *use == "sig"_s;
        if (!ok) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
    }

    auto ext_value = jwk->getIfPropertyExists(global_object, JSC::Identifier::fromString(global_object->vm(), "ext"_s));
    if (takePendingException(scope, out_error))
        return false;
    if (ext_value && !ext_value.isUndefined() && !ext_value.toBoolean(global_object) && extractable) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    auto key_ops
        = jwk->getIfPropertyExists(global_object, JSC::Identifier::fromString(global_object->vm(), "key_ops"_s));
    if (takePendingException(scope, out_error))
        return false;
    if (key_ops && !key_ops.isUndefined()) {
        uint8_t jwk_usages = 0;
        if (!parseJwkKeyOps(global_object, scope, key_ops, jwk_usages, out_error))
            return false;
        if ((jwk_usages & usages) != usages) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
    }
    return true;
}

bool makeEcKeyFromJwk(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue key_data_value,
    JSValue algorithm_value, const String& algorithm_name, JSValue extractable_value, JSValue usages_value,
    JSColloCryptoKey*& out_key, JSC::JSValue& out_error)
{
    auto* jwk = dynamicDowncast<JSC::JSObject>(key_data_value);
    if (!jwk) {
        out_error = typeErrorValue(global_object, "JWK key data must be an object"_s);
        return false;
    }
    auto algorithm = ecAlgorithmFromName(algorithm_name);
    if (!algorithm) {
        out_error
            = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError, "Unrecognized algorithm name"_s);
        return false;
    }
    EcKeyParams params;
    if (!parseEcKeyParamsAfterName(
            global_object, scope, algorithm_value, algorithm_name, *algorithm, params, out_error))
        return false;

    uint8_t usages = 0;
    if (!parseKeyUsages(global_object, scope, usages_value, usages, out_error))
        return false;

    std::optional<String> d_value;
    if (!getStringPropertyIfPresent(global_object, scope, jwk, "d"_s, d_value, out_error))
        return false;
    auto type = d_value ? CryptoKeyType::Private : CryptoKeyType::Public;
    if (!validateRequestedUsages(usages,
            type == CryptoKeyType::Private ? allowedPrivateUsagesForEc(*algorithm)
                                           : allowedPublicUsagesForEc(*algorithm),
            out_error, global_object))
        return false;
    if (type == CryptoKeyType::Private && !validateRequiredUsages(usages, out_error, global_object))
        return false;
    bool extractable = extractable_value.toBoolean(global_object);
    if (!validateEcJwkCommon(global_object, scope, jwk, *algorithm, params.named_curve, usages, extractable, out_error))
        return false;

    auto coordinate_bytes = coordinateBytesForNamedCurve(params.named_curve);
    WTF::Vector<uint8_t> x;
    WTF::Vector<uint8_t> y;
    if (!getEcJwkInteger(global_object, scope, jwk, "x"_s, coordinate_bytes, x, out_error))
        return false;
    if (!getEcJwkInteger(global_object, scope, jwk, "y"_s, coordinate_bytes, y, out_error))
        return false;

    auto bn_x = bytesToBn(x.span());
    auto bn_y = bytesToBn(y.span());
    bssl::UniquePtr<EC_KEY> ec(EC_KEY_new_by_curve_name(nidForNamedCurve(params.named_curve)));
    if (!bn_x || !bn_y || !ec || EC_KEY_set_public_key_affine_coordinates(ec.get(), bn_x.get(), bn_y.get()) != 1) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    if (type == CryptoKeyType::Private) {
        WTF::Vector<uint8_t> d;
        SecureVectorGuard d_guard(d);
        if (!getEcJwkInteger(global_object, scope, jwk, "d"_s, coordinate_bytes, d, out_error))
            return false;
        auto bn_d = bytesToBn(d.span());
        ClearBnGuard bn_d_guard(bn_d);
        if (!bn_d || EC_KEY_set_private_key(ec.get(), bn_d.get()) != 1) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
    }
    if (EC_KEY_check_key(ec.get()) != 1) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    auto pkey = pkeyFromEc(ec.get());
    if (!pkey) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    out_key = createEcKey(global_object, *algorithm, type, params.named_curve, WTF::move(pkey), extractable, usages);
    if (!out_key) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    return !takePendingException(scope, out_error);
}

static bool getOkpJwkBytes(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSC::JSObject* jwk,
    WTF::ASCIILiteral name, WTF::Vector<uint8_t>& out, JSC::JSValue& out_error)
{
    std::optional<String> encoded;
    if (!getStringPropertyIfPresent(global_object, scope, jwk, name, encoded, out_error))
        return false;
    if (!encoded) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    // FIXME: base64URLDecode leaves the last quarter of the decoded sextets in the capacity past size(), which the
    // guard on `decoded` does not zero, so a private "d" leaves part of itself in freed memory.
    auto decoded = WTF::base64URLDecode(*encoded);
    if (!decoded || decoded->size() != 32) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    SecureVectorGuard decoded_guard(*decoded);
    if (!out.tryReserveInitialCapacity(decoded->size())) {
        out_error = JSC::createOutOfMemoryError(global_object);
        return false;
    }
    out.append(decoded->span());
    return true;
}

static bool validateOkpJwkCommon(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSC::JSObject* jwk,
    CryptoKeyAlgorithm algorithm, uint8_t usages, bool extractable, JSC::JSValue& out_error)
{
    std::optional<String> kty;
    if (!getStringPropertyIfPresent(global_object, scope, jwk, "kty"_s, kty, out_error))
        return false;
    if (!kty) {
        out_error = typeErrorValue(global_object, "JsonWebKey.kty is required"_s);
        return false;
    }
    if (*kty != "OKP"_s) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    std::optional<String> crv;
    if (!getStringPropertyIfPresent(global_object, scope, jwk, "crv"_s, crv, out_error))
        return false;
    if (!crv || *crv != namedCurveName(okpCurveForAlgorithm(algorithm))) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    std::optional<String> alg;
    if (!getStringPropertyIfPresent(global_object, scope, jwk, "alg"_s, alg, out_error))
        return false;
    if (algorithm == CryptoKeyAlgorithm::Ed25519 && alg && !alg->isEmpty() && *alg != "Ed25519"_s
        && *alg != "EdDSA"_s) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    std::optional<String> use;
    if (!getStringPropertyIfPresent(global_object, scope, jwk, "use"_s, use, out_error))
        return false;
    if (usages && use && !use->isEmpty()) {
        bool ok = algorithm == CryptoKeyAlgorithm::X25519 ? *use == "enc"_s : *use == "sig"_s;
        if (!ok) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
    }

    auto ext_value = jwk->getIfPropertyExists(global_object, JSC::Identifier::fromString(global_object->vm(), "ext"_s));
    if (takePendingException(scope, out_error))
        return false;
    if (ext_value && !ext_value.isUndefined() && !ext_value.toBoolean(global_object) && extractable) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    auto key_ops
        = jwk->getIfPropertyExists(global_object, JSC::Identifier::fromString(global_object->vm(), "key_ops"_s));
    if (takePendingException(scope, out_error))
        return false;
    if (key_ops && !key_ops.isUndefined()) {
        uint8_t jwk_usages = 0;
        if (!parseJwkKeyOps(global_object, scope, key_ops, jwk_usages, out_error))
            return false;
        if ((jwk_usages & usages) != usages) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
    }
    return true;
}

bool makeOkpKeyFromJwk(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSValue key_data_value,
    const String& algorithm_name, JSValue extractable_value, JSValue usages_value, JSColloCryptoKey*& out_key,
    JSC::JSValue& out_error)
{
    auto* jwk = dynamicDowncast<JSC::JSObject>(key_data_value);
    if (!jwk) {
        out_error = typeErrorValue(global_object, "JWK key data must be an object"_s);
        return false;
    }
    auto algorithm = okpAlgorithmFromName(algorithm_name);
    if (!algorithm) {
        out_error
            = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError, "Unrecognized algorithm name"_s);
        return false;
    }

    uint8_t usages = 0;
    if (!parseKeyUsages(global_object, scope, usages_value, usages, out_error))
        return false;

    std::optional<String> d_value;
    if (!getStringPropertyIfPresent(global_object, scope, jwk, "d"_s, d_value, out_error))
        return false;
    auto type = d_value ? CryptoKeyType::Private : CryptoKeyType::Public;
    if (!validateRequestedUsages(usages,
            type == CryptoKeyType::Private ? allowedPrivateUsagesForOkp(*algorithm)
                                           : allowedPublicUsagesForOkp(*algorithm),
            out_error, global_object))
        return false;
    if (type == CryptoKeyType::Private && !validateRequiredUsages(usages, out_error, global_object))
        return false;
    bool extractable = extractable_value.toBoolean(global_object);
    if (!validateOkpJwkCommon(global_object, scope, jwk, *algorithm, usages, extractable, out_error))
        return false;

    WTF::Vector<uint8_t> material;
    SecureVectorGuard material_guard(material);
    WTF::Vector<uint8_t> declared_public;
    if (type == CryptoKeyType::Private) {
        if (!getOkpJwkBytes(global_object, scope, jwk, "d"_s, material, out_error))
            return false;
        // RFC 8037 requires "x" in a private OKP JWK too, and the import rejects one that differs from the public
        // key derived from "d".
        if (!getOkpJwkBytes(global_object, scope, jwk, "x"_s, declared_public, out_error))
            return false;
    } else if (!getOkpJwkBytes(global_object, scope, jwk, "x"_s, material, out_error))
        return false;

    bssl::UniquePtr<EVP_PKEY> pkey(type == CryptoKeyType::Private
            ? EVP_PKEY_new_raw_private_key(evpTypeForOkp(*algorithm), nullptr, material.span().data(), material.size())
            : EVP_PKEY_new_raw_public_key(evpTypeForOkp(*algorithm), nullptr, material.span().data(), material.size()));
    if (!pkey) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    if (type == CryptoKeyType::Private) {
        WTF::Vector<uint8_t> derived_public;
        if (!evpGetRawPublic(pkey.get(), derived_public) || derived_public.size() != declared_public.size()
            || std::memcmp(derived_public.span().data(), declared_public.span().data(), declared_public.size())) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
    }

    out_key = createOkpKey(global_object, *algorithm, type, WTF::move(pkey), extractable, usages);
    if (!out_key) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    return !takePendingException(scope, out_error);
}

JSC::JSObject* createRsaJwkObject(
    JSC::JSGlobalObject* global_object, JSC::VM& vm, JSColloCryptoKey* key, JSC::JSValue& out_error)
{
    RsaComponents components;
    if (!exportRsaComponents(key, components)) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::OperationError);
        return nullptr;
    }

    auto* result
        = JSC::constructEmptyObject(global_object, global_object->objectPrototype(), components.is_private ? 12 : 6);
    auto putBase64 = [&](WTF::ASCIILiteral name, std::span<const uint8_t> bytes) {
        result->putDirect(
            vm, JSC::Identifier::fromString(vm, name), JSC::jsString(vm, WTF::base64URLEncodeToString(bytes)));
    };
    auto putSecretBase64 = [&](WTF::ASCIILiteral name, std::span<const uint8_t> bytes) {
        result->putDirect(vm, JSC::Identifier::fromString(vm, name), secretBase64UrlJsString(vm, bytes));
    };

    result->putDirect(vm, JSC::Identifier::fromString(vm, "kty"_s), JSC::jsString(vm, String("RSA"_s)));
    putBase64("n"_s, components.n.span());
    putBase64("e"_s, components.e.span());
    if (components.is_private) {
        putSecretBase64("d"_s, components.d.span());
        putSecretBase64("p"_s, components.p.span());
        putSecretBase64("q"_s, components.q.span());
        putSecretBase64("dp"_s, components.dp.span());
        putSecretBase64("dq"_s, components.dq.span());
        putSecretBase64("qi"_s, components.qi.span());
    }
    const auto jwk_alg = rsaJwkAlgorithm(key->algorithm(), key->hash());
    if (!jwk_alg.isEmpty())
        result->putDirect(vm, JSC::Identifier::fromString(vm, "alg"_s), JSC::jsString(vm, String(jwk_alg)));
    result->putDirect(vm, JSC::Identifier::fromString(vm, "ext"_s), JSC::jsBoolean(key->extractable()));
    auto* key_ops = createUsagesArray(global_object, vm, key->usages());
    if (!key_ops) {
        auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
        if (!takePendingException(scope, out_error))
            out_error = JSC::createOutOfMemoryError(global_object);
        return nullptr;
    }
    result->putDirect(vm, JSC::Identifier::fromString(vm, "key_ops"_s), key_ops);
    return result;
}

JSC::JSObject* createEcJwkObject(
    JSC::JSGlobalObject* global_object, JSC::VM& vm, JSColloCryptoKey* key, JSC::JSValue& out_error)
{
    EcComponents components;
    if (!exportEcComponents(key, components)) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::OperationError);
        return nullptr;
    }

    auto* result
        = JSC::constructEmptyObject(global_object, global_object->objectPrototype(), components.is_private ? 7 : 6);
    auto putBase64 = [&](WTF::ASCIILiteral name, std::span<const uint8_t> bytes) {
        result->putDirect(
            vm, JSC::Identifier::fromString(vm, name), JSC::jsString(vm, WTF::base64URLEncodeToString(bytes)));
    };

    result->putDirect(vm, JSC::Identifier::fromString(vm, "kty"_s), JSC::jsString(vm, String("EC"_s)));
    result->putDirect(
        vm, JSC::Identifier::fromString(vm, "crv"_s), JSC::jsString(vm, String(namedCurveName(key->namedCurve()))));
    putBase64("x"_s, components.x.span());
    putBase64("y"_s, components.y.span());
    if (components.is_private)
        result->putDirect(vm, JSC::Identifier::fromString(vm, "d"_s), secretBase64UrlJsString(vm, components.d.span()));
    result->putDirect(vm, JSC::Identifier::fromString(vm, "ext"_s), JSC::jsBoolean(key->extractable()));
    auto* key_ops = createUsagesArray(global_object, vm, key->usages());
    if (!key_ops) {
        auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
        if (!takePendingException(scope, out_error))
            out_error = JSC::createOutOfMemoryError(global_object);
        return nullptr;
    }
    result->putDirect(vm, JSC::Identifier::fromString(vm, "key_ops"_s), key_ops);
    return result;
}

JSC::JSObject* createOkpJwkObject(
    JSC::JSGlobalObject* global_object, JSC::VM& vm, JSColloCryptoKey* key, JSC::JSValue& out_error)
{
    OkpComponents components;
    if (!exportOkpComponents(key, components)) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::OperationError);
        return nullptr;
    }

    auto* result
        = JSC::constructEmptyObject(global_object, global_object->objectPrototype(), components.is_private ? 6 : 5);
    auto putBase64 = [&](WTF::ASCIILiteral name, std::span<const uint8_t> bytes) {
        result->putDirect(
            vm, JSC::Identifier::fromString(vm, name), JSC::jsString(vm, WTF::base64URLEncodeToString(bytes)));
    };

    result->putDirect(vm, JSC::Identifier::fromString(vm, "kty"_s), JSC::jsString(vm, String("OKP"_s)));
    result->putDirect(
        vm, JSC::Identifier::fromString(vm, "crv"_s), JSC::jsString(vm, String(namedCurveName(key->namedCurve()))));
    putBase64("x"_s, components.x.span());
    if (components.is_private)
        result->putDirect(vm, JSC::Identifier::fromString(vm, "d"_s), secretBase64UrlJsString(vm, components.d.span()));
    result->putDirect(vm, JSC::Identifier::fromString(vm, "ext"_s), JSC::jsBoolean(key->extractable()));
    auto* key_ops = createUsagesArray(global_object, vm, key->usages());
    if (!key_ops) {
        auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
        if (!takePendingException(scope, out_error))
            out_error = JSC::createOutOfMemoryError(global_object);
        return nullptr;
    }
    result->putDirect(vm, JSC::Identifier::fromString(vm, "key_ops"_s), key_ops);
    return result;
}

bool exportKeyBytesForWrap(JSC::JSGlobalObject* global_object, const String& format, JSColloCryptoKey* key,
    WTF::Vector<uint8_t>& out, JSC::JSValue& out_error)
{
    if (key->algorithm() == CryptoKeyAlgorithm::Pbkdf2 || key->algorithm() == CryptoKeyAlgorithm::Hkdf) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError);
        return false;
    }

    if (!key->extractable()) {
        out_error = domExceptionValue(
            global_object, DOMExceptionCode::InvalidAccessError, "The CryptoKey is nonextractable"_s);
        return false;
    }

    if (format == "raw"_s) {
        if (isRsaAlgorithm(key->algorithm())) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError);
            return false;
        }
        if (isEcAlgorithm(key->algorithm()))
            return exportEcRaw(global_object, key, out, out_error);
        if (isOkpAlgorithm(key->algorithm()))
            return exportOkpRaw(global_object, key, out, out_error);
        if (!out.tryAppend(key->material())) {
            out_error = JSC::createOutOfMemoryError(global_object);
            return false;
        }
        return true;
    }

    if (format == "spki"_s || format == "pkcs8"_s) {
        if (!isRsaAlgorithm(key->algorithm()) && !isEcAlgorithm(key->algorithm())
            && !isOkpAlgorithm(key->algorithm())) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError);
            return false;
        }
        return format == "spki"_s ? exportAsymmetricSpki(global_object, key, out, out_error)
                                  : exportAsymmetricPkcs8(global_object, key, out, out_error);
    }

    if (format == "jwk"_s) {
        // FIXME: an RSA private key's JSON text takes about 0.75 bytes per modulus bit plus its member syntax, so from
        // about 7600 bits up to maxWebCryptoRsaModulusLengthBits it runs past the 2048 + rsaModulusBits() / 2 bytes
        // reserved. appendBase64Url then reallocates `out`, and a buffer it leaves behind, already holding secret
        // members, is freed without being zeroed.
        auto reserve_size = isRsaAlgorithm(key->algorithm())
            ? 2048 + key->rsaModulusBits() / 2
            : ((isEcAlgorithm(key->algorithm()) || isOkpAlgorithm(key->algorithm()))
                      ? 512
                      : 192 + key->material().size() * 2);
        if (!out.tryReserveInitialCapacity(reserve_size)) {
            out_error = JSC::createOutOfMemoryError(global_object);
            return false;
        }
        if (!appendJwkJson(out, key)) {
            out_error = JSC::createOutOfMemoryError(global_object);
            return false;
        }
        return true;
    }

    out_error = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError);
    return false;
}

} // namespace Collo::HostFunctions::WebCrypto
