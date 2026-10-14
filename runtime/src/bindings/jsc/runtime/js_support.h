// Helpers the WebCrypto bridge shares: throwing a DOMException, reading BufferSource arguments, and WebIDL's rule that
// turns an operation's throwing steps into the promise it returns. They run on the VM thread with the JSC API lock
// held.
//
// A span borrowBufferSource returns points into the JavaScript buffer's own storage. It is valid only while the caller
// keeps the buffer alive and no JavaScript runs, because JavaScript can detach or resize the buffer, so a caller
// borrows after the last step that can run script, or copies with copyBufferSource.

#pragma once

#include "host_functions/support.h"
#include "host_functions/webapi/dom/dom_exception.h"

#include <JavaScriptCore/JSCJSValue.h>
#include <JavaScriptCore/ThrowScope.h>
#include <JavaScriptCore/TopExceptionScope.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

#include <cstdint>
#include <optional>
#include <span>

namespace Collo::JscSupport {

using DOMExceptionCode = Collo::HostFunctions::DOMExceptionCode;

// Throws a new DOMException with `code`; an empty `message` takes the default message of the code's name.
void throwDOMException(JSC::JSGlobalObject*, JSC::ThrowScope&, DOMExceptionCode, WTF::String message = {});

// Whether the value has a type a BufferSource argument accepts: an ArrayBuffer or an ArrayBuffer view. It checks the
// type alone; borrowBufferSource also refuses a detached, out-of-bounds or resizable buffer.
bool isBufferSource(JSC::JSValue);

// Borrows the bytes of an ArrayBuffer view, or of an ArrayBuffer that is neither resizable nor growable. A detached or
// out-of-bounds view, or any other value, throws a TypeError and returns no value.
std::optional<std::span<const uint8_t>> borrowBufferSource(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue);

// Copies what borrowBufferSource accepts, throwing its TypeError, or an OutOfMemoryError when the copy cannot be
// allocated.
std::optional<WTF::Vector<uint8_t>> copyBufferSource(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue);

// A new ArrayBuffer holding a copy of the bytes. Throws an OutOfMemoryError, returning an empty value, when it cannot
// be allocated.
JSC::JSValue createArrayBufferCopy(JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<const uint8_t>);

// WebIDL's rule for an operation that returns a promise: if its steps throw, it returns a rejected promise. `steps` is
// a callable that declares its own ThrowScope and returns the value to resolve with, or an empty value with an
// exception pending. The result is a promise resolved with that value, or rejected with the thrown value, which this
// clears. A termination is never cleared: the function returns an empty value with the termination still pending, so
// the VM keeps unwinding and no promise is made on the way out. Steps that return an empty value with no exception
// break that contract; the promise then rejects with an OperationError rather than resolving with no value.
template <typename Steps>
JSC::EncodedJSValue promiseFromThrowingSteps(JSC::JSGlobalObject* global_object, const Steps& steps)
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    JSC::JSValue result = steps();
    if (scope.exception()) {
        JSC::JSValue thrown = scope.exception()->value();
        if (!scope.clearExceptionExceptTermination())
            return {};
        return Collo::HostFunctions::rejectedPromise(global_object, thrown);
    }
    ASSERT(result);
    if (!result) [[unlikely]] {
        return Collo::HostFunctions::rejectedPromise(
            global_object, Collo::HostFunctions::createDOMException(global_object, DOMExceptionCode::OperationError));
    }
    return Collo::HostFunctions::resolvedPromise(global_object, result);
}

}
