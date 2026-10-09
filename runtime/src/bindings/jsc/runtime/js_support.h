// Helpers host functions share to build error values and to read BufferSource arguments. They run on the VM thread
// with the JSC API lock held.
//
// The span borrowBufferSource returns points into the JavaScript buffer's own storage. It is valid only while the
// caller keeps the buffer alive and no JavaScript runs, because JavaScript can detach or resize the buffer; a caller
// that needs the bytes past that point copies them with copyBufferSource.

#pragma once

#include "host_functions/webapi/dom/dom_exception.h"

#include <JavaScriptCore/JSCJSValue.h>
#include <JavaScriptCore/TopExceptionScope.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

#include <cstdint>
#include <span>

namespace JSC {
class TopExceptionScope;
class JSGlobalObject;
class ThrowScope;
}

namespace Collo::JscSupport {

using DOMExceptionCode = Collo::HostFunctions::DOMExceptionCode;

JSC::JSValue typeErrorValue(JSC::JSGlobalObject*, WTF::String message);
JSC::JSValue domExceptionValue(JSC::JSGlobalObject*, DOMExceptionCode, WTF::String message = {});
// A promise already rejected with a new DOMException.
JSC::EncodedJSValue rejectedDOMException(JSC::JSGlobalObject*, DOMExceptionCode, WTF::String message = {});

// Moves the pending exception of `scope` into `out_error` and returns true, or returns false when nothing is pending.
// A termination stays pending so the VM keeps unwinding.
template <typename Scope> bool takePendingException(Scope& scope, JSC::JSValue& out_error)
{
    if (!scope.exception())
        return false;
    out_error = scope.exception()->value();
    scope.clearExceptionExceptTermination();
    return true;
}

// ToString of the value. A throwing conversion returns a null string and leaves the exception in `out_error`, so the
// caller can reject a promise with it instead of throwing.
WTF::String valueToStringForPromise(
    JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue, JSC::JSValue& out_error);

// Borrows the bytes of an ArrayBuffer view, or of an ArrayBuffer that is neither resizable nor growable. A detached
// or out-of-bounds view, or any other value, fails with a TypeError in `out_error`.
bool borrowBufferSource(JSC::JSGlobalObject*, JSC::JSValue, std::span<const uint8_t>& out, JSC::JSValue& out_error);

// Copies what borrowBufferSource accepts into `out`, failing with its TypeError or with an OutOfMemoryError when
// `out` cannot grow.
bool copyBufferSource(
    JSC::JSGlobalObject*, JSC::TopExceptionScope&, JSC::JSValue, WTF::Vector<uint8_t>& out, JSC::JSValue& out_error);

// A new ArrayBuffer holding a copy of the bytes, or an empty value with an OutOfMemoryError or the pending
// exception in `out_error`.
JSC::JSValue createArrayBufferCopy(
    JSC::JSGlobalObject*, JSC::TopExceptionScope&, std::span<const uint8_t>, JSC::JSValue& out_error);

}
