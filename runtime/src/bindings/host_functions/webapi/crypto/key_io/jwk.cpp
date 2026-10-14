// JWK import and export under the contract in key_io.h: reading and parsing the JsonWebKey record, base64url members,
// the JWK import core for every family, and the JWK object and text exportKey and wrapKey produce from one native list
// of the key's members. Secret members decode straight into a `SecretBytes`. exportKey returns them as JavaScript
// strings, as the API's JWK object requires; wrapKey's text is written natively into a `SecretBytes`, so it runs no
// script and no secret member becomes a string.

#include "jsc/runtime/state.h"

#include "host_functions/webapi/crypto/key_io/key_io.h"

#include "host_functions/webapi/crypto/algorithms.h"
#include "host_functions/webapi/crypto/keys.h"
#include "host_functions/webapi/crypto/ops/symmetric.h"
#include "jsc/runtime/js_support.h"

#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSONObject.h>
#include <openssl/bn.h>
#include <openssl/ec.h>
#include <openssl/ec_key.h>
#include <openssl/evp.h>
#include <openssl/rsa.h>
#include <wtf/ASCIICType.h>
#include <wtf/text/Base64.h>
#include <wtf/text/StringView.h>
#include <wtf/text/WTFString.h>

#include <array>
#include <cstring>

namespace Collo::HostFunctions::WebCrypto {

using Collo::JscSupport::throwDOMException;
using JSC::JSValue;
using WTF::String;

namespace {

    void throwDataError(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
    {
        throwDOMException(global_object, scope, DOMExceptionCode::DataError);
    }

    void throwOperationError(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
    {
        throwDOMException(global_object, scope, DOMExceptionCode::OperationError);
    }

    // Where a JWK record's members come from. importKey converts a JsonWebKey dictionary from script with [[Get]], as
    // WebIDL does. unwrapKey reads the object it parsed from the decrypted text through its own data properties only:
    // JSON.parse builds that object on the caller's Object.prototype, where script may have put getters, and a getter
    // run with the parsed key as `this` would read the material of a key unwrapped as non-extractable. The Web
    // Cryptography API parses in a new global object, whose prototypes hold no JWK member, so own data properties give
    // the same members, and no script runs.
    enum class JwkSource : uint8_t {
        Dictionary,
        ParsedText,
    };

    // The value of the member `name`, undefined when absent.
    JSValue jwkMember(
        JSC::JSGlobalObject* global_object, JSC::JSObject* object, WTF::ASCIILiteral name, JwkSource source)
    {
        auto identifier = JSC::Identifier::fromString(global_object->vm(), name);
        if (source == JwkSource::Dictionary)
            return object->get(global_object, identifier);
        JSC::PropertySlot slot(object, JSC::PropertySlot::InternalMethodType::GetOwnProperty);
        if (!JSC::JSObject::getOwnPropertySlot(object, global_object, identifier, slot) || !slot.isValue())
            return JSC::jsUndefined();
        return slot.getValue(global_object, identifier);
    }

    // ToString of a member's value. For parsed text the value must be a primitive, whose conversion runs no script; an
    // object or array there is a DataError.
    std::optional<String> jwkString(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value, JwkSource source)
    {
        if (source == JwkSource::ParsedText && value.isObject()) {
            throwDataError(global_object, scope);
            return std::nullopt;
        }
        String string = value.toWTFString(global_object);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        return string;
    }

    // A DOMString member: absent when undefined, otherwise its ToString.
    void readStringMember(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* object,
        WTF::ASCIILiteral name, JwkSource source, std::optional<String>& out)
    {
        JSValue value = jwkMember(global_object, object, name, source);
        RETURN_IF_EXCEPTION(scope, void());
        if (value.isUndefined())
            return;
        out = jwkString(global_object, scope, value, source);
    }

    // `key_ops` of parsed text: an array of at most `key_usages_length_max` primitives, read through its own elements.
    // Anything else is a DataError.
    std::optional<KeyOps> readParsedKeyOps(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
    {
        auto* array = dynamicDowncast<JSC::JSArray>(value);
        if (!array || array->length() > key_usages_length_max) {
            throwDataError(global_object, scope);
            return std::nullopt;
        }
        KeyOps key_ops;
        for (unsigned index = 0; index < array->length(); ++index) {
            JSC::PropertySlot slot(array, JSC::PropertySlot::InternalMethodType::GetOwnProperty);
            JSValue item = JSC::jsUndefined();
            if (JSC::JSObject::getOwnPropertySlotByIndex(array, global_object, index, slot) && slot.isValue())
                item = slot.getValue(global_object, index);
            RETURN_IF_EXCEPTION(scope, std::nullopt);
            auto name = jwkString(global_object, scope, item, JwkSource::ParsedText);
            RETURN_IF_EXCEPTION(scope, std::nullopt);
            noteKeyOp(key_ops, *name);
        }
        return key_ops;
    }

    // Reads the JsonWebKey members of `object` once each in lexicographic order.
    std::optional<JwkRecord> readJwkObject(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* object, JwkSource source)
    {
        JwkRecord record;
        readStringMember(global_object, scope, object, "alg"_s, source, record.alg);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        readStringMember(global_object, scope, object, "crv"_s, source, record.crv);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        readStringMember(global_object, scope, object, "d"_s, source, record.d);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        readStringMember(global_object, scope, object, "dp"_s, source, record.dp);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        readStringMember(global_object, scope, object, "dq"_s, source, record.dq);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        readStringMember(global_object, scope, object, "e"_s, source, record.e);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        JSValue ext = jwkMember(global_object, object, "ext"_s, source);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        if (!ext.isUndefined())
            record.ext = ext.toBoolean(global_object);
        readStringMember(global_object, scope, object, "k"_s, source, record.k);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        JSValue key_ops = jwkMember(global_object, object, "key_ops"_s, source);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        if (!key_ops.isUndefined()) {
            record.key_ops = source == JwkSource::Dictionary ? readKeyOps(global_object, scope, key_ops)
                                                             : readParsedKeyOps(global_object, scope, key_ops);
            RETURN_IF_EXCEPTION(scope, std::nullopt);
        }
        readStringMember(global_object, scope, object, "kty"_s, source, record.kty);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        readStringMember(global_object, scope, object, "n"_s, source, record.n);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        readStringMember(global_object, scope, object, "p"_s, source, record.p);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        readStringMember(global_object, scope, object, "q"_s, source, record.q);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        readStringMember(global_object, scope, object, "qi"_s, source, record.qi);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        readStringMember(global_object, scope, object, "use"_s, source, record.use);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        readStringMember(global_object, scope, object, "x"_s, source, record.x);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        readStringMember(global_object, scope, object, "y"_s, source, record.y);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        return record;
    }

    // A member the key needs, decoded; absent is a DataError.
    std::optional<SecretBytes> decodeRequiredMember(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const std::optional<String>& member)
    {
        if (!member) {
            throwDataError(global_object, scope);
            return std::nullopt;
        }
        return decodeBase64UrlMember(global_object, scope, *member);
    }

    std::optional<SecretBytes> decodeMemberOfLength(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        const std::optional<String>& member, size_t byte_length)
    {
        auto bytes = decodeRequiredMember(global_object, scope, member);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        if (bytes->size() != byte_length) {
            throwDataError(global_object, scope);
            return std::nullopt;
        }
        return bytes;
    }

    std::optional<SecretBytes> decodeNonEmptyMember(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const std::optional<String>& member)
    {
        auto bytes = decodeRequiredMember(global_object, scope, member);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        if (bytes->isEmpty()) {
            throwDataError(global_object, scope);
            return std::nullopt;
        }
        return bytes;
    }

    // An absent or empty `alg` matches any algorithm, as JWK import allows.
    bool algMatches(const std::optional<String>& alg, WTF::ASCIILiteral expected)
    {
        return !alg || alg->isEmpty() || *alg == expected;
    }

    WTF::ASCIILiteral ktyOf(AlgorithmFamily family)
    {
        switch (family) {
        case AlgorithmFamily::Hmac:
        case AlgorithmFamily::Aes:
            return "oct"_s;
        case AlgorithmFamily::Rsa:
            return "RSA"_s;
        case AlgorithmFamily::Ec:
            return "EC"_s;
        case AlgorithmFamily::Okp:
            return "OKP"_s;
        case AlgorithmFamily::Kdf:
            break;
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

    // The checks that identify the key before its material is read, a DataError each: the curve of an EC or OKP key,
    // and the `alg` of an HMAC, RSA or Ed25519 key. An AES key's `alg` names its length, so it is checked after `k`
    // decodes.
    bool jwkIdentifiesKey(const ImportRequest& request, const JwkRecord& jwk)
    {
        const auto& spec = request.algorithm.spec();
        switch (spec.family) {
        case AlgorithmFamily::Hmac:
            return algMatches(jwk.alg, request.algorithm.paramsAs<HmacParams>().hash->jwk_alg);
        case AlgorithmFamily::Rsa:
            return algMatches(jwk.alg, rsaJwkAlgorithm(spec.id, importedRsaHash(request.algorithm)));
        case AlgorithmFamily::Ec:
            return jwk.crv && *jwk.crv == curveSpec(request.algorithm.paramsAs<EcKeyParams>().named_curve).name;
        case AlgorithmFamily::Okp:
            if (!jwk.crv || *jwk.crv != curveSpec(spec.okp_curve).name)
                return false;
            // RFC 8037 names an Ed25519 key's algorithm EdDSA; the Web Cryptography API also accepts Ed25519.
            return spec.id != CryptoKeyAlgorithm::Ed25519 || algMatches(jwk.alg, "Ed25519"_s)
                || algMatches(jwk.alg, "EdDSA"_s);
        case AlgorithmFamily::Aes:
        case AlgorithmFamily::Kdf:
            return true;
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

    JSColloCryptoKey* importOctJwk(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const ImportRequest& request, const JwkRecord& jwk)
    {
        const auto& spec = request.algorithm.spec();
        auto material = decodeRequiredMember(global_object, scope, jwk.k);
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (spec.family == AlgorithmFamily::Hmac) {
            const auto& params = request.algorithm.paramsAs<HmacParams>();
            if (material->isEmpty() || !hmacLengthFits(params.length_bits, material->size())) {
                throwDataError(global_object, scope);
                return nullptr;
            }
            return createSecretKey(global_object, spec.id, params.hash->id, WTF::move(*material), request.extractable,
                request.usages, params.length_bits.value_or(0));
        }
        if (!isValidAesKeyLength(material->size())
            || !algMatches(jwk.alg, aesJwkAlgorithm(spec.id, material->size()))) {
            throwDataError(global_object, scope);
            return nullptr;
        }
        return createSecretKey(
            global_object, spec.id, WebCryptoHash::SHA256, WTF::move(*material), request.extractable, request.usages);
    }

    JSColloCryptoKey* importRsaJwk(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        const ImportRequest& request, const JwkRecord& jwk, CryptoKeyType type)
    {
        auto n = decodeNonEmptyMember(global_object, scope, jwk.n);
        RETURN_IF_EXCEPTION(scope, nullptr);
        // An encoder may put one zero byte before a modulus whose top bit is set.
        if (n->size() > 1 && !n->data()[0]) {
            std::memmove(n->data(), n->data() + 1, n->size() - 1);
            n->shrink(n->size() - 1);
        }
        auto e = decodeNonEmptyMember(global_object, scope, jwk.e);
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (n->size() > (rsa_modulus_bits_max + 7) / 8) {
            throwDataError(global_object, scope);
            return nullptr;
        }
        auto bn_n = bytesToBn(n->span());
        auto bn_e = bytesToBn(e->span());
        if (!bn_n || !bn_e) {
            throwDataError(global_object, scope);
            return nullptr;
        }

        // BoringSSL's constructors bound the public exponent at 33 bits, as its SubjectPublicKeyInfo and PrivateKeyInfo
        // parsers do, so a JWK cannot bring an exponent that makes a public-key operation a full-size exponentiation.
        bssl::UniquePtr<RSA> rsa;
        if (type == CryptoKeyType::Public)
            rsa.reset(RSA_new_public_key(bn_n.get(), bn_e.get()));
        else {
            std::array<const std::optional<String>*, 6> members { &jwk.d, &jwk.p, &jwk.q, &jwk.dp, &jwk.dq, &jwk.qi };
            std::array<bssl::UniquePtr<BIGNUM>, 6> values;
            for (size_t index = 0; index < members.size(); ++index) {
                auto bytes = decodeNonEmptyMember(global_object, scope, *members[index]);
                RETURN_IF_EXCEPTION(scope, nullptr);
                values[index] = bytesToBn(bytes->span());
                if (!values[index]) {
                    throwDataError(global_object, scope);
                    return nullptr;
                }
            }
            rsa.reset(RSA_new_private_key(bn_n.get(), bn_e.get(), values[0].get(), values[1].get(), values[2].get(),
                values[3].get(), values[4].get(), values[5].get()));
        }
        auto pkey = pkeyFromRsa(rsa.get());
        auto* key = createAsymmetricKey(global_object,
            { request.algorithm.id, importedRsaHash(request.algorithm), CryptoKeyNamedCurve::None, type,
                request.extractable, request.usages },
            pkey);
        if (!key)
            throwDataError(global_object, scope);
        return key;
    }

    JSColloCryptoKey* importEcJwk(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        const ImportRequest& request, const JwkRecord& jwk, CryptoKeyType type)
    {
        const auto& curve = curveSpec(request.algorithm.paramsAs<EcKeyParams>().named_curve);
        auto x = decodeMemberOfLength(global_object, scope, jwk.x, curve.coordinate_bytes);
        RETURN_IF_EXCEPTION(scope, nullptr);
        auto y = decodeMemberOfLength(global_object, scope, jwk.y, curve.coordinate_bytes);
        RETURN_IF_EXCEPTION(scope, nullptr);
        auto bn_x = bytesToBn(x->span());
        auto bn_y = bytesToBn(y->span());
        bssl::UniquePtr<EC_KEY> ec(EC_KEY_new_by_curve_name(curve.nid));
        if (!bn_x || !bn_y || !ec || EC_KEY_set_public_key_affine_coordinates(ec.get(), bn_x.get(), bn_y.get()) != 1) {
            throwDataError(global_object, scope);
            return nullptr;
        }
        if (type == CryptoKeyType::Private) {
            auto d = decodeMemberOfLength(global_object, scope, jwk.d, curve.coordinate_bytes);
            RETURN_IF_EXCEPTION(scope, nullptr);
            auto bn_d = bytesToBn(d->span());
            if (!bn_d || EC_KEY_set_private_key(ec.get(), bn_d.get()) != 1) {
                throwDataError(global_object, scope);
                return nullptr;
            }
        }
        if (EC_KEY_check_key(ec.get()) != 1) {
            throwDataError(global_object, scope);
            return nullptr;
        }
        auto pkey = pkeyFromEc(ec.get());
        auto* key = createAsymmetricKey(global_object,
            { request.algorithm.id, WebCryptoHash::SHA1, curve.id, type, request.extractable, request.usages }, pkey);
        if (!key)
            throwDataError(global_object, scope);
        return key;
    }

    JSColloCryptoKey* importOkpJwk(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        const ImportRequest& request, const JwkRecord& jwk, CryptoKeyType type)
    {
        const auto& curve = curveSpec(request.algorithm.spec().okp_curve);
        bssl::UniquePtr<EVP_PKEY> pkey;
        if (type == CryptoKeyType::Private) {
            auto d = decodeMemberOfLength(global_object, scope, jwk.d, curve.coordinate_bytes);
            RETURN_IF_EXCEPTION(scope, nullptr);
            // RFC 8037 requires "x" in a private OKP JWK too, and it must be the public key "d" derives.
            auto x = decodeMemberOfLength(global_object, scope, jwk.x, curve.coordinate_bytes);
            RETURN_IF_EXCEPTION(scope, nullptr);
            pkey.reset(EVP_PKEY_new_raw_private_key(curve.nid, nullptr, d->data(), d->size()));
            std::array<uint8_t, 32> derived {};
            size_t derived_len = derived.size();
            if (!pkey || EVP_PKEY_get_raw_public_key(pkey.get(), derived.data(), &derived_len) != 1
                || derived_len != x->size() || std::memcmp(derived.data(), x->data(), derived_len)) {
                throwDataError(global_object, scope);
                return nullptr;
            }
        } else {
            auto x = decodeMemberOfLength(global_object, scope, jwk.x, curve.coordinate_bytes);
            RETURN_IF_EXCEPTION(scope, nullptr);
            pkey.reset(EVP_PKEY_new_raw_public_key(curve.nid, nullptr, x->data(), x->size()));
        }
        auto* key = createAsymmetricKey(global_object,
            { request.algorithm.id, WebCryptoHash::SHA1, curve.id, type, request.extractable, request.usages }, pkey);
        if (!key)
            throwDataError(global_object, scope);
        return key;
    }

    // A key's JWK as exportKey returns it, before encoding: `kty`, `crv` when the key has a curve, the key's base64url
    // members in order, `alg` when JWK defines one for the key, then `ext` and `key_ops`. Every member's bytes live in
    // a SecretBytes, public ones too, so the private ones never pass through any other buffer.
    struct JwkExport {
        // At most an RSA private key's eight: n, e, d, p, q, dp, dq and qi.
        static constexpr size_t members_max = 8;

        WTF::ASCIILiteral kty;
        WTF::ASCIILiteral crv;
        WTF::ASCIILiteral alg;
        std::array<WTF::ASCIILiteral, members_max> member_names {};
        std::array<SecretBytes, members_max> member_values;
        size_t member_count { 0 };
        bool ext { false };
        uint8_t usages { 0 };

        // The empty buffer of a new member, which the caller fills.
        SecretBytes& addMember(WTF::ASCIILiteral name)
        {
            ASSERT(member_count < members_max);
            member_names[member_count] = name;
            return member_values[member_count++];
        }
    };

    bool readOctJwk(JSColloCryptoKey* key, JwkExport& out)
    {
        out.kty = "oct"_s;
        out.alg = key->algorithm() == CryptoKeyAlgorithm::Hmac
            ? hashSpec(key->hash()).jwk_alg
            : aesJwkAlgorithm(key->algorithm(), key->material().size());
        return out.addMember("k"_s).tryAppend(key->material());
    }

    // Every private RSA key a CryptoKey holds carries its CRT parameters, which RFC 7518 requires in its JWK: JWK
    // import requires them (`RSA_new_private_key`), a PrivateKeyInfo's RSAPrivateKey always holds them, and key
    // generation computes them.
    bool readRsaJwk(JSColloCryptoKey* key, JwkExport& out)
    {
        RSA* rsa = EVP_PKEY_get0_RSA(key->pkey());
        if (!rsa)
            return false;
        out.kty = "RSA"_s;
        out.alg = rsaJwkAlgorithm(key->algorithm(), key->hash());
        const BIGNUM* n = nullptr;
        const BIGNUM* e = nullptr;
        const BIGNUM* d = nullptr;
        RSA_get0_key(rsa, &n, &e, &d);
        if (!bnToBytes(n, out.addMember("n"_s)) || !bnToBytes(e, out.addMember("e"_s)))
            return false;
        if (key->type() != CryptoKeyType::Private)
            return true;
        const BIGNUM* p = nullptr;
        const BIGNUM* q = nullptr;
        RSA_get0_factors(rsa, &p, &q);
        const BIGNUM* dmp1 = nullptr;
        const BIGNUM* dmq1 = nullptr;
        const BIGNUM* iqmp = nullptr;
        RSA_get0_crt_params(rsa, &dmp1, &dmq1, &iqmp);
        const std::array<std::pair<WTF::ASCIILiteral, const BIGNUM*>, 6> members { {
            { "d"_s, d },
            { "p"_s, p },
            { "q"_s, q },
            { "dp"_s, dmp1 },
            { "dq"_s, dmq1 },
            { "qi"_s, iqmp },
        } };
        for (const auto& [name, value] : members) {
            if (!bnToBytes(value, out.addMember(name)))
                return false;
        }
        return true;
    }

    // Writes `bn` big-endian, left-padded with zeros to `byte_length` bytes, into `out`, which must be empty.
    bool bnToFixedBytes(const BIGNUM* bn, size_t byte_length, SecretBytes& out)
    {
        if (!bn || BN_num_bytes(bn) > byte_length || !out.tryGrow(byte_length))
            return false;
        return BN_bn2bin_padded(out.mutableSpan().data(), byte_length, bn) == 1;
    }

    JSC::JSString* base64UrlString(JSC::VM& vm, std::span<const uint8_t> bytes)
    {
        String encoded = WTF::base64EncodeToStringReturnNullIfOverflow(
            bytes, { WTF::Base64EncodeOption::URL, WTF::Base64EncodeOption::OmitPadding });
        if (encoded.isNull())
            return nullptr;
        return JSC::jsString(vm, WTF::move(encoded));
    }

    void putString(JSC::VM& vm, JSC::JSObject* object, WTF::ASCIILiteral name, WTF::ASCIILiteral value)
    {
        object->putDirect(vm, JSC::Identifier::fromString(vm, name), JSC::jsString(vm, String(value)));
    }

    void putBase64Url(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* object,
        WTF::ASCIILiteral name, std::span<const uint8_t> bytes)
    {
        auto& vm = global_object->vm();
        auto* encoded = base64UrlString(vm, bytes);
        if (!encoded) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return;
        }
        object->putDirect(vm, JSC::Identifier::fromString(vm, name), encoded);
    }

    JSC::JSObject* newJwkObject(JSC::JSGlobalObject* global_object, unsigned inline_capacity)
    {
        return JSC::constructEmptyObject(global_object, global_object->objectPrototype(), inline_capacity);
    }

    bool readEcJwk(JSColloCryptoKey* key, JwkExport& out)
    {
        const auto& curve = curveSpec(key->namedCurve());
        auto* ec = EVP_PKEY_get0_EC_KEY(key->pkey());
        auto* group = ec ? EC_KEY_get0_group(ec) : nullptr;
        auto* public_point = ec ? EC_KEY_get0_public_key(ec) : nullptr;
        bssl::UniquePtr<BIGNUM> x(BN_new());
        bssl::UniquePtr<BIGNUM> y(BN_new());
        if (!group || !public_point || !x || !y
            || EC_POINT_get_affine_coordinates_GFp(group, public_point, x.get(), y.get(), nullptr) != 1)
            return false;
        out.kty = "EC"_s;
        out.crv = curve.name;
        if (!bnToFixedBytes(x.get(), curve.coordinate_bytes, out.addMember("x"_s))
            || !bnToFixedBytes(y.get(), curve.coordinate_bytes, out.addMember("y"_s)))
            return false;
        return key->type() != CryptoKeyType::Private
            || bnToFixedBytes(EC_KEY_get0_private_key(ec), curve.coordinate_bytes, out.addMember("d"_s));
    }

    // Writes a raw OKP key of the curve's length into `out`, which must be empty.
    template <typename Read> bool readRawOkpKey(EVP_PKEY* pkey, size_t byte_length, SecretBytes& out, const Read& read)
    {
        size_t written = byte_length;
        return out.tryGrow(byte_length) && read(pkey, out.data(), &written) == 1 && written == byte_length;
    }

    bool readOkpJwk(JSColloCryptoKey* key, JwkExport& out)
    {
        const auto& curve = curveSpec(key->namedCurve());
        out.kty = "OKP"_s;
        out.crv = curve.name;
        if (!readRawOkpKey(key->pkey(), curve.coordinate_bytes, out.addMember("x"_s), EVP_PKEY_get_raw_public_key))
            return false;
        return key->type() != CryptoKeyType::Private
            || readRawOkpKey(key->pkey(), curve.coordinate_bytes, out.addMember("d"_s), EVP_PKEY_get_raw_private_key);
    }

    // Fills `out` from `key`, which is not a PBKDF2 or HKDF key; false when BoringSSL cannot give the key's parts or a
    // buffer cannot grow.
    bool readJwkExport(JSColloCryptoKey* key, JwkExport& out)
    {
        out.ext = key->extractable();
        out.usages = key->usages();
        switch (algorithmSpec(key->algorithm()).family) {
        case AlgorithmFamily::Hmac:
        case AlgorithmFamily::Aes:
            return readOctJwk(key, out);
        case AlgorithmFamily::Rsa:
            return readRsaJwk(key, out);
        case AlgorithmFamily::Ec:
            return readEcJwk(key, out);
        case AlgorithmFamily::Okp:
            return readOkpJwk(key, out);
        case AlgorithmFamily::Kdf:
            break;
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

    // The JWK export of `key`, after refusing a PBKDF2 or HKDF key, which has no JWK form, with NotSupportedError. A
    // key whose parts cannot be read is an OperationError.
    bool readJwkExportOrThrow(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSColloCryptoKey* key, JwkExport& out)
    {
        if (algorithmSpec(key->algorithm()).family == AlgorithmFamily::Kdf) {
            throwDOMException(global_object, scope, DOMExceptionCode::NotSupportedError);
            return false;
        }
        if (!readJwkExport(key, out)) {
            throwOperationError(global_object, scope);
            return false;
        }
        return true;
    }

    constexpr WTF::OptionSet<WTF::Base64EncodeOption> base64_url_options { WTF::Base64EncodeOption::URL,
        WTF::Base64EncodeOption::OmitPadding };

    // Visits the JSON text of `parts` piece by piece, ASCII text and base64url members, in the order and form
    // JSON.stringify gives the object `exportJwk` builds: every name and string value is ASCII that needs no escape.
    template <typename Sink> void visitJwkText(const JwkExport& parts, Sink& sink)
    {
        auto stringMember = [&](WTF::ASCIILiteral name, WTF::ASCIILiteral value) {
            sink.text(",\""_s);
            sink.text(name);
            sink.text("\":\""_s);
            sink.text(value);
            sink.text("\""_s);
        };
        sink.text("{\"kty\":\""_s);
        sink.text(parts.kty);
        sink.text("\""_s);
        if (!parts.crv.isEmpty())
            stringMember("crv"_s, parts.crv);
        for (size_t index = 0; index < parts.member_count; ++index) {
            sink.text(",\""_s);
            sink.text(parts.member_names[index]);
            sink.text("\":\""_s);
            sink.base64Url(parts.member_values[index].span());
            sink.text("\""_s);
        }
        if (!parts.alg.isEmpty())
            stringMember("alg"_s, parts.alg);
        sink.text(parts.ext ? ",\"ext\":true,\"key_ops\":["_s : ",\"ext\":false,\"key_ops\":["_s);
        bool first_usage = true;
        for (const auto& usage : orderedCryptoKeyUsages) {
            if (!(parts.usages & usage.bit))
                continue;
            sink.text(first_usage ? "\""_s : ",\""_s);
            sink.text(usage.name);
            sink.text("\""_s);
            first_usage = false;
        }
        sink.text("]}"_s);
    }

    // Counts the bytes of the JSON text; `overflowed` when a member is too long for WTF's encoder.
    struct JwkTextLength {
        size_t bytes { 0 };
        bool overflowed { false };

        void text(WTF::ASCIILiteral literal) { bytes += literal.length(); }
        void base64Url(std::span<const uint8_t> input)
        {
            const size_t encoded = WTF::calculateBase64EncodedSize(input.size(), base64_url_options);
            overflowed |= !input.empty() && !encoded;
            bytes += encoded;
        }
    };

    // Writes the JSON text into a buffer of the length `JwkTextLength` counted.
    struct JwkTextWriter {
        std::span<uint8_t> output;
        size_t cursor { 0 };

        void text(WTF::ASCIILiteral literal)
        {
            auto source = literal.span8();
            std::copy(source.begin(), source.end(), output.begin() + cursor);
            cursor += source.size();
        }
        void base64Url(std::span<const uint8_t> input)
        {
            const size_t encoded = WTF::calculateBase64EncodedSize(input.size(), base64_url_options);
            WTF::base64Encode(std::as_bytes(input), output.subspan(cursor, encoded), base64_url_options);
            cursor += encoded;
        }
    };

} // namespace

std::optional<SecretBytes> decodeBase64UrlMember(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const String& text)
{
    // WTF's decoder skips ASCII whitespace and wants padding that completes the last chunk; a JWK member takes
    // neither whitespace nor padding rules, so trailing '=' are dropped here and whitespace refused.
    StringView view = text;
    size_t end = view.length();
    while (end && view[end - 1] == '=')
        --end;
    StringView body = view.left(end);
    bool malformed = !end && end != view.length();
    for (size_t index = 0; index < body.length() && !malformed; ++index)
        malformed = isASCIIWhitespace(body[index]);
    if (malformed) {
        throwDataError(global_object, scope);
        return std::nullopt;
    }

    SecretBytes decoded;
    if (!decoded.tryGrow(WTF::maxLengthFromBase64(body))) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return std::nullopt;
    }
    auto [should_throw, read, written] = WTF::fromBase64(body, decoded.mutableSpan(), WTF::Alphabet::Base64URL,
        WTF::LastChunkHandling::Loose, WTF::OutputSizeIsMaxLength::No);
    UNUSED_VARIABLE(read);
    if (should_throw == WTF::FromBase64ShouldThrowError::Yes || written > decoded.size()) {
        throwDataError(global_object, scope);
        return std::nullopt;
    }
    decoded.shrink(written);
    return decoded;
}

std::optional<JwkRecord> readJwkRecord(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    if (value.isUndefinedOrNull())
        return JwkRecord {};
    auto* object = dynamicDowncast<JSC::JSObject>(value);
    if (!object) {
        JSC::throwTypeError(global_object, scope, "JsonWebKey must be an object"_s);
        return std::nullopt;
    }
    RELEASE_AND_RETURN(scope, readJwkObject(global_object, scope, object, JwkSource::Dictionary));
}

std::optional<JwkRecord> parseJwkRecord(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const uint8_t> text)
{
    if (text.size() > jwk_text_bytes_max) {
        throwDataError(global_object, scope);
        return std::nullopt;
    }
    String json = String::fromUTF8(text);
    if (json.isNull()) {
        throwDataError(global_object, scope);
        return std::nullopt;
    }
    JSValue parsed = JSC::JSONParse(global_object, json);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    auto* object = parsed ? dynamicDowncast<JSC::JSObject>(parsed) : nullptr;
    if (!object) {
        throwDataError(global_object, scope);
        return std::nullopt;
    }
    auto record = readJwkObject(global_object, scope, object, JwkSource::ParsedText);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    // The parse a JWK step requires `kty`, where importKey's dictionary leaves it to each import.
    if (!record->kty) {
        throwDataError(global_object, scope);
        return std::nullopt;
    }
    return record;
}

JSColloCryptoKey* importKeyFromJwk(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const ImportRequest& request, const JwkRecord& jwk)
{
    ASSERT(request.format == KeyFormat::Jwk);
    const auto& spec = request.algorithm.spec();
    if (spec.family == AlgorithmFamily::Kdf) {
        throwDOMException(global_object, scope, DOMExceptionCode::NotSupportedError);
        return nullptr;
    }
    CryptoKeyType type = CryptoKeyType::Secret;
    if (!spec.secret_usages)
        type = jwk.d ? CryptoKeyType::Private : CryptoKeyType::Public;
    checkNewKeyUsages(global_object, scope, spec, type, request.usages);
    RETURN_IF_EXCEPTION(scope, nullptr);

    if (!jwk.kty) {
        JSC::throwTypeError(global_object, scope, "JsonWebKey.kty is required"_s);
        return nullptr;
    }
    if (*jwk.kty != ktyOf(spec.family) || !jwkIdentifiesKey(request, jwk)) {
        throwDataError(global_object, scope);
        return nullptr;
    }
    const bool use_mismatch = request.usages && jwk.use && !jwk.use->isEmpty() && *jwk.use != spec.jwk_use;
    const bool ext_forbids = jwk.ext && !*jwk.ext && request.extractable;
    const bool key_ops_forbid
        = jwk.key_ops && (jwk.key_ops->names_unknown_usage || (jwk.key_ops->usages & request.usages) != request.usages);
    if (use_mismatch || ext_forbids || key_ops_forbid) {
        throwDataError(global_object, scope);
        return nullptr;
    }

    switch (spec.family) {
    case AlgorithmFamily::Hmac:
    case AlgorithmFamily::Aes:
        return importOctJwk(global_object, scope, request, jwk);
    case AlgorithmFamily::Rsa:
        return importRsaJwk(global_object, scope, request, jwk, type);
    case AlgorithmFamily::Ec:
        return importEcJwk(global_object, scope, request, jwk, type);
    case AlgorithmFamily::Okp:
        return importOkpJwk(global_object, scope, request, jwk, type);
    case AlgorithmFamily::Kdf:
        break;
    }
    RELEASE_ASSERT_NOT_REACHED();
}

JSC::JSObject* exportJwk(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSColloCryptoKey* key)
{
    JwkExport parts;
    if (!readJwkExportOrThrow(global_object, scope, key, parts))
        return nullptr;
    auto& vm = global_object->vm();
    // The inline capacity holds kty, crv, alg, ext, key_ops and every member.
    auto* jwk = newJwkObject(global_object, static_cast<unsigned>(parts.member_count) + 5);
    putString(vm, jwk, "kty"_s, parts.kty);
    if (!parts.crv.isEmpty())
        putString(vm, jwk, "crv"_s, parts.crv);
    for (size_t index = 0; index < parts.member_count; ++index) {
        putBase64Url(global_object, scope, jwk, parts.member_names[index], parts.member_values[index].span());
        RETURN_IF_EXCEPTION(scope, nullptr);
    }
    if (!parts.alg.isEmpty())
        putString(vm, jwk, "alg"_s, parts.alg);
    jwk->putDirect(vm, JSC::Identifier::fromString(vm, "ext"_s), JSC::jsBoolean(parts.ext));
    auto* key_ops = createUsagesArray(global_object, scope, parts.usages);
    RETURN_IF_EXCEPTION(scope, nullptr);
    jwk->putDirect(vm, JSC::Identifier::fromString(vm, "key_ops"_s), key_ops);
    return jwk;
}

std::optional<SecretBytes> exportJwkText(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSColloCryptoKey* key)
{
    JwkExport parts;
    if (!readJwkExportOrThrow(global_object, scope, key, parts))
        return std::nullopt;
    JwkTextLength length;
    visitJwkText(parts, length);
    SecretBytes text;
    if (length.overflowed || !text.tryGrow(length.bytes)) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return std::nullopt;
    }
    JwkTextWriter writer { text.mutableSpan() };
    visitJwkText(parts, writer);
    ASSERT(writer.cursor == text.size());
    return text;
}

}
