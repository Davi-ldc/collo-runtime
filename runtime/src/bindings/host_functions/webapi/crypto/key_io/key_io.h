// Web Crypto key import and export: building CryptoKey cells from raw, spki, pkcs8 and JWK key data, encoding keys
// back to those formats, and importing a key that unwrapKey decrypted. The implementations are split by format across
// raw.cpp, der.cpp, jwk.cpp and unwrap.cpp. Everything here reads JavaScript values or allocates cells, so it runs on
// the VM thread; the one exception is evpGetRawPublic, which crypto jobs also call off it.
//
// The make*Key functions and importUnwrappedKeyBytesWithSpec share one contract. On success they set `out_key` to a
// new CryptoKey and return true. Only the caller's stack roots that cell, so the caller keeps it in a local until it
// is published. On failure they return false with `out_error` holding the value to reject with: a DOMException, a
// TypeError, an OutOfMemoryError, or an exception moved out of the scope by takePendingException. `out_key` can be set
// on a false return, so callers test the return value. Buffers that held secret key bytes are zeroed before they are
// freed; the known gaps carry a FIXME in jwk.cpp and unwrap.cpp.

#pragma once

#include "host_functions/webapi/crypto/normalize.h"
#include "host_functions/webapi/crypto/objects.h"

#include <JavaScriptCore/JSCJSValue.h>
#include <JavaScriptCore/JSObject.h>
#include <openssl/evp.h>
#include <wtf/Forward.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

#include <cstdint>
#include <span>

namespace JSC {
class TopExceptionScope;
class JSGlobalObject;
class VM;
class JSString;
}

namespace Collo::HostFunctions::WebCrypto {

bool makeHmacKeyFromRaw(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue key_data_value,
    JSC::JSValue algorithm_value, const WTF::String& algorithm_name, JSC::JSValue extractable_value,
    JSC::JSValue usages_value, JSColloCryptoKey*& out_key, JSC::JSValue& out_error);
bool makeHmacKeyFromJwk(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue key_data_value,
    JSC::JSValue algorithm_value, const WTF::String& algorithm_name, JSC::JSValue extractable_value,
    JSC::JSValue usages_value, JSColloCryptoKey*& out_key, JSC::JSValue& out_error);
bool makeAesKeyFromRaw(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue key_data_value,
    JSC::JSValue algorithm_value, const WTF::String& algorithm_name, JSC::JSValue extractable_value,
    JSC::JSValue usages_value, JSColloCryptoKey*& out_key, JSC::JSValue& out_error);
bool makeAesKeyFromJwk(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue key_data_value,
    JSC::JSValue algorithm_value, const WTF::String& algorithm_name, JSC::JSValue extractable_value,
    JSC::JSValue usages_value, JSColloCryptoKey*& out_key, JSC::JSValue& out_error);
bool makeDeriveKeyFromRaw(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue key_data_value,
    CryptoKeyAlgorithm, JSC::JSValue extractable_value, JSC::JSValue usages_value, JSColloCryptoKey*& out_key,
    JSC::JSValue& out_error);

bool makeRsaKeyFromJwk(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue key_data_value,
    JSC::JSValue algorithm_value, const WTF::String& algorithm_name, JSC::JSValue extractable_value,
    JSC::JSValue usages_value, JSColloCryptoKey*& out_key, JSC::JSValue& out_error);
bool makeRsaKeyFromSpki(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue key_data_value,
    JSC::JSValue algorithm_value, const WTF::String& algorithm_name, JSC::JSValue extractable_value,
    JSC::JSValue usages_value, JSColloCryptoKey*& out_key, JSC::JSValue& out_error);
bool makeRsaKeyFromPkcs8(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue key_data_value,
    JSC::JSValue algorithm_value, const WTF::String& algorithm_name, JSC::JSValue extractable_value,
    JSC::JSValue usages_value, JSColloCryptoKey*& out_key, JSC::JSValue& out_error);

bool makeEcKeyFromRaw(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue key_data_value,
    JSC::JSValue algorithm_value, const WTF::String& algorithm_name, JSC::JSValue extractable_value,
    JSC::JSValue usages_value, JSColloCryptoKey*& out_key, JSC::JSValue& out_error);
bool makeEcKeyFromJwk(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue key_data_value,
    JSC::JSValue algorithm_value, const WTF::String& algorithm_name, JSC::JSValue extractable_value,
    JSC::JSValue usages_value, JSColloCryptoKey*& out_key, JSC::JSValue& out_error);
bool makeEcKeyFromSpki(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue key_data_value,
    JSC::JSValue algorithm_value, const WTF::String& algorithm_name, JSC::JSValue extractable_value,
    JSC::JSValue usages_value, JSColloCryptoKey*& out_key, JSC::JSValue& out_error);
bool makeEcKeyFromPkcs8(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue key_data_value,
    JSC::JSValue algorithm_value, const WTF::String& algorithm_name, JSC::JSValue extractable_value,
    JSC::JSValue usages_value, JSColloCryptoKey*& out_key, JSC::JSValue& out_error);

bool makeOkpKeyFromRaw(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue key_data_value,
    const WTF::String& algorithm_name, JSC::JSValue extractable_value, JSC::JSValue usages_value,
    JSColloCryptoKey*& out_key, JSC::JSValue& out_error);
bool makeOkpKeyFromJwk(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue key_data_value,
    const WTF::String& algorithm_name, JSC::JSValue extractable_value, JSC::JSValue usages_value,
    JSColloCryptoKey*& out_key, JSC::JSValue& out_error);
bool makeOkpKeyFromSpki(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue key_data_value,
    const WTF::String& algorithm_name, JSC::JSValue extractable_value, JSC::JSValue usages_value,
    JSColloCryptoKey*& out_key, JSC::JSValue& out_error);
bool makeOkpKeyFromPkcs8(JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue key_data_value,
    const WTF::String& algorithm_name, JSC::JSValue extractable_value, JSC::JSValue usages_value,
    JSColloCryptoKey*& out_key, JSC::JSValue& out_error);

// Copies the raw public key of an Ed25519 or X25519 key into `out`, which must be empty, with no buffer.
bool evpGetRawPublic(EVP_PKEY*, WTF::Vector<uint8_t>& out);

// Each fills `out`, which must be empty, with the key in the named format. A key of the wrong type for the format, a
// private key for raw or spki or a public key for pkcs8, is an InvalidAccessError, and a BoringSSL failure is an
// OperationError. A pkcs8 export holds the private key, so the caller zeroes `out`.
bool exportEcRaw(JSC::JSGlobalObject*, JSColloCryptoKey*, WTF::Vector<uint8_t>& out, JSC::JSValue& out_error);
bool exportOkpRaw(JSC::JSGlobalObject*, JSColloCryptoKey*, WTF::Vector<uint8_t>& out, JSC::JSValue& out_error);
bool exportAsymmetricSpki(JSC::JSGlobalObject*, JSColloCryptoKey*, WTF::Vector<uint8_t>& out, JSC::JSValue& out_error);
bool exportAsymmetricPkcs8(JSC::JSGlobalObject*, JSColloCryptoKey*, WTF::Vector<uint8_t>& out, JSC::JSValue& out_error);

// Encodes secret key material, a JWK d, p, q, dp, dq, qi or k member, as a base64url JSString. The intermediate
// encoded buffer is zeroed before it is freed, so the returned string is the only copy of the encoded secret. Use it
// for every private or secret JWK member.
JSC::JSString* secretBase64UrlJsString(JSC::VM&, std::span<const uint8_t> bytes);

// Each builds the JWK object exportKey returns for an RSA, EC or OKP key. On failure it returns null with `out_error`
// set to an OperationError, the pending exception or an OutOfMemoryError.
JSC::JSObject* createRsaJwkObject(JSC::JSGlobalObject*, JSC::VM&, JSColloCryptoKey*, JSC::JSValue& out_error);
JSC::JSObject* createEcJwkObject(JSC::JSGlobalObject*, JSC::VM&, JSColloCryptoKey*, JSC::JSValue& out_error);
JSC::JSObject* createOkpJwkObject(JSC::JSGlobalObject*, JSC::VM&, JSColloCryptoKey*, JSC::JSValue& out_error);

// Serializes `key` in `format` into `out`, which must be empty, for wrapKey to encrypt; a JWK becomes its JSON text. A
// nonextractable key is an InvalidAccessError, and PBKDF2 and HKDF keys or a format the key type lacks are a
// NotSupportedError. `out` can hold secret key material, so the caller zeroes it.
bool exportKeyBytesForWrap(JSC::JSGlobalObject*, const WTF::String& format, JSColloCryptoKey*,
    WTF::Vector<uint8_t>& out, JSC::JSValue& out_error);

bool makeDerivedKeyFromMaterial(JSC::JSGlobalObject*, JSC::TopExceptionScope&, WTF::Vector<uint8_t>&& material,
    const DerivedKeySpec&, bool extractable, uint8_t usages, JSColloCryptoKey*& out_key, JSC::JSValue& out_error);

// The import parameters of the key unwrapKey will produce, read when unwrapKey is called so the job carries no
// JavaScript value. `hash` applies to HMAC and RSA, `curve` to EC and OKP, and `length_bits` to HMAC when
// `has_length_bits` is set.
struct UnwrappedKeyImportSpec {
    CryptoKeyAlgorithm algorithm { CryptoKeyAlgorithm::Hmac };
    WebCryptoHash hash { WebCryptoHash::SHA256 };
    CryptoKeyNamedCurve curve { CryptoKeyNamedCurve::None };
    bool extractable { false };
    uint8_t usages { 0 };
    bool has_length_bits { false };
    size_t length_bits { 0 };
};

// Reads the unwrapped key's algorithm, extractable flag and usages into `out`. An unrecognized algorithm is a
// NotSupportedError. The usages are checked against the algorithm only at import.
bool normalizeUnwrappedKeyImportSpec(JSC::JSGlobalObject*, JSC::TopExceptionScope&, const WTF::String& format,
    JSC::JSValue algorithm_value, JSC::JSValue extractable_value, JSC::JSValue usages_value,
    UnwrappedKeyImportSpec& out, JSC::JSValue& out_error);

// Imports the decrypted `bytes` as a `format` key under `spec` when the unwrap job settles. The bytes end up in the
// new key or are zeroed.
bool importUnwrappedKeyBytesWithSpec(JSC::JSGlobalObject*, JSC::TopExceptionScope&, const WTF::String& format,
    WTF::Vector<uint8_t>&& bytes, const UnwrappedKeyImportSpec&, JSColloCryptoKey*& out_key, JSC::JSValue& out_error);

}
