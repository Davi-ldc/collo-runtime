// The steps several SubtleCrypto methods share: the receiver and argument checks every method opens with, the WebIDL
// type checks of CryptoKey and BufferSource arguments, and the one cipher entry encrypt, decrypt, wrapKey and unwrapKey
// run. They run on the VM thread inside a method's throwing steps (`promiseFromThrowingSteps` in js_support.h) and fail
// by throwing into its ThrowScope.

#pragma once

#include "host_functions/webapi/crypto/normalize.h"
#include "host_functions/webapi/crypto/objects.h"
#include "host_functions/webapi/crypto/types.h"

#include <JavaScriptCore/JSCJSValue.h>
#include <wtf/text/ASCIILiteral.h>

#include <cstdint>
#include <optional>
#include <span>

namespace JSC {
class CallFrame;
class JSGlobalObject;
class ThrowScope;
}

namespace Collo::HostFunctions::WebCrypto {

// A TypeError when the receiver is not a SubtleCrypto or fewer than `required_arguments` were passed.
void checkSubtleCall(
    JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::CallFrame*, WTF::ASCIILiteral method, unsigned required_arguments);

// The CryptoKey argument conversion: a TypeError with `message` for any other value.
JSColloCryptoKey* requireCryptoKey(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue, WTF::ASCIILiteral message);

// The BufferSource argument conversion's type check: a TypeError for a value of any other type. A method borrows the
// bytes after its last step that can run script.
void requireBufferSource(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue);

enum class CipherDirection : uint8_t {
    // Encrypt, or wrap with AES-KW.
    Encrypt,
    // Decrypt, or unwrap with AES-KW.
    Decrypt,
};

// Runs the cipher `algorithm` names over `input` with `key`, which the caller checked, under a time guard (budget.h):
// an input past `single_call_input_bytes_max` where BoringSSL takes it in one call, a guard that refuses before or
// during the work, and a cipher that fails, such as a GCM tag that does not verify or an RSA input of the wrong size,
// are each an OperationError. `input` is borrowed and no script runs before this returns.
std::optional<SecretBytes> runCipher(JSC::JSGlobalObject*, JSC::ThrowScope&, CipherDirection,
    const NormalizedAlgorithm&, JSColloCryptoKey*, std::span<const uint8_t> input);

}
