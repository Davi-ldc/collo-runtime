// JWK import and export under the contract in key_io.h. Import reads members through property gets, which can run
// script, so it keeps only copied values across reads. Export builds the JWK object exportKey returns for RSA, EC and
// OKP keys, or the JSON text wrapKey encrypts. Every buffer a secret member passes through, decoded or encoded, is a
// `SecretBytes`, and base64url text decodes straight into one sized before the decode.

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

// The base64url alphabet's value of `character`, or -1 for a character outside it.
static int base64UrlValue(char32_t character)
{
    if (character >= 'A' && character <= 'Z')
        return static_cast<int>(character - 'A');
    if (character >= 'a' && character <= 'z')
        return static_cast<int>(character - 'a') + 26;
    if (character >= '0' && character <= '9')
        return static_cast<int>(character - '0') + 52;
    if (character == '-')
        return 62;
    if (character == '_')
        return 63;
    return -1;
}

// Accepts the same text as WTF's base64url decoder, so importKey and the unwrapKey parser agree with each other and
// with the rest of the engine: alphabet characters, then nothing but '=' padding, of any count, and no whitespace. A
// count of alphabet characters that leaves 1 mod 4 cannot encode whole bytes. The unused low bits of the last
// character are ignored, as WTF ignores them. A first pass counts, so `out` is allocated once at the decoded length,
// and the second writes each byte straight into it.
template <typename CharacterType>
static bool decodeSecretBase64UrlText(
    std::span<const CharacterType> text, SecretBytes& out, bool& out_allocation_failed)
{
    out_allocation_failed = false;
    ASSERT(out.isEmpty());

    size_t sextet_count = 0;
    bool padded = false;
    for (auto character : text) {
        if (character == '=') {
            padded = true;
            continue;
        }
        if (padded || base64UrlValue(character) < 0)
            return false;
        ++sextet_count;
    }
    if (!sextet_count)
        return !padded;
    if (sextet_count % 4 == 1)
        return false;

    const size_t decoded_length = sextet_count - (sextet_count + 3) / 4;
    if (!out.tryGrow(decoded_length)) {
        out_allocation_failed = true;
        return false;
    }
    uint8_t* destination = out.data();
    size_t written = 0;
    uint32_t pending_bits = 0;
    unsigned pending_bit_count = 0;
    for (auto character : text) {
        if (character == '=')
            break;
        pending_bits = (pending_bits << 6) | static_cast<uint32_t>(base64UrlValue(character));
        pending_bit_count += 6;
        if (pending_bit_count >= 8) {
            pending_bit_count -= 8;
            destination[written++] = static_cast<uint8_t>(pending_bits >> pending_bit_count);
            pending_bits &= (1u << pending_bit_count) - 1;
        }
    }
    pending_bits = 0;
    ASSERT(written == decoded_length);
    return true;
}

bool decodeSecretBase64Url(const String& text, SecretBytes& out, bool& out_allocation_failed)
{
    if (text.is8Bit())
        return decodeSecretBase64UrlText(text.span8(), out, out_allocation_failed);
    return decodeSecretBase64UrlText(text.span16(), out, out_allocation_failed);
}

bool decodeSecretBase64Url(std::span<const uint8_t> text, SecretBytes& out, bool& out_allocation_failed)
{
    return decodeSecretBase64UrlText(text, out, out_allocation_failed);
}

// The unpadded base64url length of `byte_length` bytes; false when it does not fit in a size_t.
static bool base64UrlEncodedLength(size_t byte_length, size_t& out)
{
    const size_t full_groups = byte_length / 3;
    const size_t remainder = byte_length % 3;
    if (full_groups > std::numeric_limits<size_t>::max() / 4)
        return false;
    out = full_groups * 4;
    if (remainder) {
        if (out > std::numeric_limits<size_t>::max() - (remainder + 1))
            return false;
        out += remainder + 1;
    }
    return true;
}

// Appends the unpadded base64url text of `bytes` to `out`, which reallocates only when the caller reserved too little.
static bool encodeBase64UrlInto(SecretBytes& out, std::span<const uint8_t> bytes)
{
    static constexpr char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

    const size_t full_groups = bytes.size() / 3;
    const size_t remainder = bytes.size() % 3;
    size_t encoded_length = 0;
    if (!base64UrlEncodedLength(bytes.size(), encoded_length))
        return false;
    if (out.size() > std::numeric_limits<size_t>::max() - encoded_length)
        return false;

    const size_t old_size = out.size();
    if (!out.tryGrow(old_size + encoded_length))
        return false;
    auto* dst = out.data() + old_size;
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

JSC::JSString* secretBase64UrlJsString(JSC::VM& vm, std::span<const uint8_t> bytes)
{
    size_t encoded_length = 0;
    SecretBytes encoded;
    if (!base64UrlEncodedLength(bytes.size(), encoded_length) || !encoded.tryReserveCapacity(encoded_length)
        || !encodeBase64UrlInto(encoded, bytes))
        return nullptr;
    // String copies the ASCII bytes into its own StringImpl, so `encoded` zeroing its buffer leaves the result intact.
    return JSC::jsString(vm,
        String { std::span<const Latin1Character> {
            reinterpret_cast<const Latin1Character*>(encoded.data()), encoded.size() } });
}

// Where a JWK's JSON text goes. A sink without a buffer only counts the bytes, so one pass measures the text and a
// second writes it into a buffer reserved at exactly that length, which then never reallocates.
class JwkJsonSink {
public:
    explicit JwkJsonSink(SecretBytes* out)
        : m_out(out)
    {
    }

    size_t length() const { return m_length; }

    bool append(std::span<const uint8_t> bytes)
    {
        if (bytes.size() > std::numeric_limits<size_t>::max() - m_length)
            return false;
        m_length += bytes.size();
        return !m_out || m_out->tryAppend(bytes);
    }

    bool appendBase64Url(std::span<const uint8_t> bytes)
    {
        size_t encoded_length = 0;
        if (!base64UrlEncodedLength(bytes.size(), encoded_length)
            || encoded_length > std::numeric_limits<size_t>::max() - m_length)
            return false;
        m_length += encoded_length;
        return !m_out || encodeBase64UrlInto(*m_out, bytes);
    }

private:
    SecretBytes* m_out { nullptr };
    size_t m_length { 0 };
};

static bool appendAscii(JwkJsonSink& out, const char* text)
{
    return out.append(std::span<const uint8_t> { reinterpret_cast<const uint8_t*>(text), std::strlen(text) });
}

template <size_t N> static bool appendAscii(JwkJsonSink& out, const char (&text)[N])
{
    return out.append(std::span<const uint8_t> { reinterpret_cast<const uint8_t*>(text), N - 1 });
}

static bool appendAscii(JwkJsonSink& out, WTF::ASCIILiteral text)
{
    auto span = text.span8();
    return out.append(std::span<const uint8_t> { reinterpret_cast<const uint8_t*>(span.data()), span.size() });
}

static bool appendUsageJson(JwkJsonSink& out, WTF::ASCIILiteral usage, bool& first)
{
    if (!first && !appendAscii(out, ","))
        return false;
    first = false;
    return appendAscii(out, "\"") && appendAscii(out, usage) && appendAscii(out, "\"");
}

// The public members are plain vectors; every private one is a SecretBytes.
struct RsaComponents {
    WTF::Vector<uint8_t> n;
    WTF::Vector<uint8_t> e;
    SecretBytes d;
    SecretBytes p;
    SecretBytes q;
    SecretBytes dp;
    SecretBytes dq;
    SecretBytes qi;
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

static bool bnModPrimeMinusOne(const BIGNUM* prime, const BIGNUM* d, BN_CTX* context, SecretBytes& out)
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

static bool appendJsonBase64UrlField(JwkJsonSink& out, const char* name, std::span<const uint8_t> bytes)
{
    return appendAscii(out, ",\"") && appendAscii(out, name) && appendAscii(out, "\":\"") && out.appendBase64Url(bytes)
        && appendAscii(out, "\"");
}

static bool appendJwkUsagesJson(JwkJsonSink& out, uint8_t usages)
{
    bool first = true;
    for (const auto& usage : orderedCryptoKeyUsages) {
        if ((usages & usage.bit) && !appendUsageJson(out, usage.name, first))
            return false;
    }
    return true;
}

// Writes `bn` big-endian, left-padded with zeros to `byte_length` bytes, into `out`, which must be empty: a
// WTF::Vector for a public coordinate, a SecretBytes for a private scalar.
template <typename Bytes> static bool bnToFixedBytes(const BIGNUM* bn, size_t byte_length, Bytes& out)
{
    if (!bn || BN_num_bytes(bn) > byte_length || !out.tryGrow(byte_length))
        return false;
    return BN_bn2bin_padded(out.mutableSpan().data(), byte_length, bn) == 1;
}

struct EcComponents {
    WTF::Vector<uint8_t> x;
    WTF::Vector<uint8_t> y;
    SecretBytes d;
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
    WTF::Vector<uint8_t> x;
    SecretBytes d;
    bool is_private { false };
};

static bool evpGetRawPrivate(EVP_PKEY* pkey, SecretBytes& out)
{
    size_t length = 0;
    if (EVP_PKEY_get_raw_private_key(pkey, nullptr, &length) != 1 || !length || !out.tryGrow(length))
        return false;
    return EVP_PKEY_get_raw_private_key(pkey, out.data(), &length) == 1 && length == out.size();
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

static bool appendRsaJwkJson(JwkJsonSink& out, JSColloCryptoKey* key, const RsaComponents& components)
{
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

static bool appendEcJwkJson(JwkJsonSink& out, JSColloCryptoKey* key, const EcComponents& components)
{
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

static bool appendOkpJwkJson(JwkJsonSink& out, JSColloCryptoKey* key, const OkpComponents& components)
{
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

static bool appendOctJwkJson(JwkJsonSink& out, JSColloCryptoKey* key)
{
    if (!appendAscii(out, "{\"kty\":\"oct\",\"k\":\""))
        return false;
    if (!out.appendBase64Url(key->material()))
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

// Runs `write` once to measure the JSON, reserves exactly that many bytes in `out`, which must be empty, and runs it
// again to fill them, so the text of a private key is never left behind in a reallocated buffer.
template <typename Write> static bool writeJwkJsonExactly(SecretBytes& out, const Write& write)
{
    JwkJsonSink measure(nullptr);
    if (!write(measure) || !out.tryReserveCapacity(measure.length()))
        return false;
    JwkJsonSink sink(&out);
    if (!write(sink))
        return false;
    ASSERT(out.size() == measure.length());
    return true;
}

static bool writeJwkJson(SecretBytes& out, JSColloCryptoKey* key)
{
    if (isRsaAlgorithm(key->algorithm())) {
        RsaComponents components;
        return exportRsaComponents(key, components)
            && writeJwkJsonExactly(out, [&](JwkJsonSink& sink) { return appendRsaJwkJson(sink, key, components); });
    }
    if (isEcAlgorithm(key->algorithm())) {
        EcComponents components;
        return exportEcComponents(key, components)
            && writeJwkJsonExactly(out, [&](JwkJsonSink& sink) { return appendEcJwkJson(sink, key, components); });
    }
    if (isOkpAlgorithm(key->algorithm())) {
        OkpComponents components;
        return exportOkpComponents(key, components)
            && writeJwkJsonExactly(out, [&](JwkJsonSink& sink) { return appendOkpJwkJson(sink, key, components); });
    }
    return writeJwkJsonExactly(out, [&](JwkJsonSink& sink) { return appendOctJwkJson(sink, key); });
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

// Decodes a JWK member's base64url text into `out`, which must be empty: malformed text is a DataError and a failed
// allocation an OutOfMemoryError.
static bool decodeJwkSecretMember(
    JSC::JSGlobalObject* global_object, const String& encoded, SecretBytes& out, JSC::JSValue& out_error)
{
    bool allocation_failed = false;
    if (decodeSecretBase64Url(encoded, out, allocation_failed))
        return true;
    if (allocation_failed)
        out_error = JSC::createOutOfMemoryError(global_object);
    else
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
    return false;
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

    SecretBytes decoded;
    if (!decodeJwkSecretMember(global_object, *k, decoded, out_error))
        return false;
    if (decoded.isEmpty()) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    // Web Crypto HMAC import requires a declared length to satisfy data_bits - 8 < length <= data_bits.
    if (length_bits && (*length_bits > decoded.size() * 8 || *length_bits + 8 <= decoded.size() * 8)) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    out_key = createHmacKey(global_object, hash->id, WTF::move(decoded), extractable_value.toBoolean(global_object),
        usages, length_bits.value_or(0));
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

    SecretBytes decoded;
    if (!decodeJwkSecretMember(global_object, *k, decoded, out_error))
        return false;
    if (!isValidAesKeyLength(decoded.size())) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    std::optional<String> alg;
    if (!getStringPropertyIfPresent(global_object, scope, jwk, "alg"_s, alg, out_error))
        return false;
    if (alg && !alg->isEmpty() && *alg != aesJwkAlgorithm(*algorithm, decoded.size())) {
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
        global_object, *algorithm, WTF::move(decoded), extractable_value.toBoolean(global_object), usages);
    return !takePendingException(scope, out_error);
}

// Decodes an RSA member, public or private, into `out`, which must be empty. `trim_leading_zero` drops the one zero
// byte an encoder may put before a modulus whose top bit is set.
static bool getRsaJwkInteger(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSC::JSObject* jwk,
    WTF::ASCIILiteral name, SecretBytes& out, bool trim_leading_zero, JSC::JSValue& out_error)
{
    std::optional<String> encoded;
    if (!getStringPropertyIfPresent(global_object, scope, jwk, name, encoded, out_error))
        return false;
    if (!encoded) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    if (!decodeJwkSecretMember(global_object, *encoded, out, out_error))
        return false;
    if (out.isEmpty()) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    if (trim_leading_zero && out.size() > 1 && !out.data()[0]) {
        std::memmove(out.data(), out.data() + 1, out.size() - 1);
        out.shrink(out.size() - 1);
    }
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

    SecretBytes n;
    SecretBytes e;
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
        SecretBytes d;
        SecretBytes p;
        SecretBytes q;
        SecretBytes dp;
        SecretBytes dq;
        SecretBytes qi;
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

// Decodes an EC coordinate or private scalar of exactly `byte_length` bytes into `out`, which must be empty.
static bool getEcJwkInteger(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSC::JSObject* jwk,
    WTF::ASCIILiteral name, size_t byte_length, SecretBytes& out, JSC::JSValue& out_error)
{
    std::optional<String> encoded;
    if (!getStringPropertyIfPresent(global_object, scope, jwk, name, encoded, out_error))
        return false;
    if (!encoded) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    if (!decodeJwkSecretMember(global_object, *encoded, out, out_error))
        return false;
    if (out.size() != byte_length) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
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
    SecretBytes x;
    SecretBytes y;
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
        SecretBytes d;
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

// Decodes an OKP member, the 32-byte "x" or "d", into `out`, which must be empty.
static bool getOkpJwkBytes(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSC::JSObject* jwk,
    WTF::ASCIILiteral name, SecretBytes& out, JSC::JSValue& out_error)
{
    std::optional<String> encoded;
    if (!getStringPropertyIfPresent(global_object, scope, jwk, name, encoded, out_error))
        return false;
    if (!encoded) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    if (!decodeJwkSecretMember(global_object, *encoded, out, out_error))
        return false;
    if (out.size() != 32) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
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

    SecretBytes material;
    SecretBytes declared_public;
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

// Puts a private or secret member on an exported JWK object; false when its encoded text cannot be allocated.
static bool putSecretJwkMember(
    JSC::VM& vm, JSC::JSObject* object, WTF::ASCIILiteral name, std::span<const uint8_t> bytes)
{
    auto* encoded = secretBase64UrlJsString(vm, bytes);
    if (!encoded)
        return false;
    object->putDirect(vm, JSC::Identifier::fromString(vm, name), encoded);
    return true;
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

    result->putDirect(vm, JSC::Identifier::fromString(vm, "kty"_s), JSC::jsString(vm, String("RSA"_s)));
    putBase64("n"_s, components.n.span());
    putBase64("e"_s, components.e.span());
    if (components.is_private) {
        if (!putSecretJwkMember(vm, result, "d"_s, components.d.span())
            || !putSecretJwkMember(vm, result, "p"_s, components.p.span())
            || !putSecretJwkMember(vm, result, "q"_s, components.q.span())
            || !putSecretJwkMember(vm, result, "dp"_s, components.dp.span())
            || !putSecretJwkMember(vm, result, "dq"_s, components.dq.span())
            || !putSecretJwkMember(vm, result, "qi"_s, components.qi.span())) {
            out_error = JSC::createOutOfMemoryError(global_object);
            return nullptr;
        }
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
    if (components.is_private && !putSecretJwkMember(vm, result, "d"_s, components.d.span())) {
        out_error = JSC::createOutOfMemoryError(global_object);
        return nullptr;
    }
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
    if (components.is_private && !putSecretJwkMember(vm, result, "d"_s, components.d.span())) {
        out_error = JSC::createOutOfMemoryError(global_object);
        return nullptr;
    }
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
    SecretBytes& out, JSC::JSValue& out_error)
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
        if (!writeJwkJson(out, key)) {
            out.clear();
            out_error = JSC::createOutOfMemoryError(global_object);
            return false;
        }
        return true;
    }

    out_error = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError);
    return false;
}

} // namespace Collo::HostFunctions::WebCrypto
