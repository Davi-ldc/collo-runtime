// The export checks and the byte-format export core, under the contract in key_io.h. Every exported byte lands in a
// `SecretBytes`, since a raw secret key and a PrivateKeyInfo are key material; BoringSSL's own buffers for the DER are
// cleansed when freed.

#include "jsc/runtime/state.h"

#include "host_functions/webapi/crypto/key_io/key_io.h"

#include "host_functions/webapi/crypto/algorithms.h"
#include "jsc/runtime/js_support.h"

#include <JavaScriptCore/JSCInlines.h>
#include <openssl/bytestring.h>
#include <openssl/ec.h>
#include <openssl/ec_key.h>
#include <openssl/evp.h>
#include <wtf/text/WTFString.h>

namespace Collo::HostFunctions::WebCrypto {

using Collo::JscSupport::throwDOMException;

namespace {

    // The DER of `pkey` as a SubjectPublicKeyInfo or a PrivateKeyInfo; false when BoringSSL fails or `out` cannot
    // grow.
    bool marshalKey(EVP_PKEY* pkey, bool private_key, SecretBytes& out)
    {
        bssl::ScopedCBB cbb;
        if (!CBB_init(cbb.get(), 0))
            return false;
        const int marshaled
            = private_key ? EVP_marshal_private_key(cbb.get(), pkey) : EVP_marshal_public_key(cbb.get(), pkey);
        if (!marshaled)
            return false;
        return out.tryAppend(std::span<const uint8_t> { CBB_data(cbb.get()), CBB_len(cbb.get()) });
    }

    bool rawPublicKey(JSColloCryptoKey* key, SecretBytes& out)
    {
        if (algorithmSpec(key->algorithm()).family == AlgorithmFamily::Okp) {
            size_t length = 0;
            return EVP_PKEY_get_raw_public_key(key->pkey(), nullptr, &length) == 1 && length && out.tryGrow(length)
                && EVP_PKEY_get_raw_public_key(key->pkey(), out.data(), &length) == 1 && length == out.size();
        }
        auto* ec = EVP_PKEY_get0_EC_KEY(key->pkey());
        auto* group = ec ? EC_KEY_get0_group(ec) : nullptr;
        auto* point = ec ? EC_KEY_get0_public_key(ec) : nullptr;
        if (!group || !point)
            return false;
        const size_t length = EC_POINT_point2oct(group, point, POINT_CONVERSION_UNCOMPRESSED, nullptr, 0, nullptr);
        return length && out.tryGrow(length)
            && EC_POINT_point2oct(group, point, POINT_CONVERSION_UNCOMPRESSED, out.data(), out.size(), nullptr)
            == length;
    }

} // namespace

void checkExportable(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSColloCryptoKey* key)
{
    if (algorithmSpec(key->algorithm()).family == AlgorithmFamily::Kdf) {
        throwDOMException(global_object, scope, DOMExceptionCode::NotSupportedError);
        return;
    }
    if (!key->extractable())
        throwDOMException(
            global_object, scope, DOMExceptionCode::InvalidAccessError, "The CryptoKey is nonextractable"_s);
}

std::optional<SecretBytes> exportKeyBytes(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, KeyFormat format, JSColloCryptoKey* key)
{
    ASSERT(format != KeyFormat::Jwk);
    const auto family = algorithmSpec(key->algorithm()).family;
    SecretBytes out;
    if (key->type() == CryptoKeyType::Secret) {
        if (format != KeyFormat::Raw) {
            throwDOMException(global_object, scope, DOMExceptionCode::NotSupportedError);
            return std::nullopt;
        }
        if (!out.tryAppend(key->material())) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return std::nullopt;
        }
        return out;
    }
    if (format == KeyFormat::Raw && family == AlgorithmFamily::Rsa) {
        throwDOMException(global_object, scope, DOMExceptionCode::NotSupportedError);
        return std::nullopt;
    }
    const auto carried_type = format == KeyFormat::Pkcs8 ? CryptoKeyType::Private : CryptoKeyType::Public;
    if (key->type() != carried_type) {
        throwDOMException(global_object, scope, DOMExceptionCode::InvalidAccessError);
        return std::nullopt;
    }
    const bool exported
        = format == KeyFormat::Raw ? rawPublicKey(key, out) : marshalKey(key->pkey(), format == KeyFormat::Pkcs8, out);
    if (!exported) {
        throwDOMException(global_object, scope, DOMExceptionCode::OperationError);
        return std::nullopt;
    }
    return out;
}

}
