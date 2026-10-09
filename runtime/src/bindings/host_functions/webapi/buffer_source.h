// Checks and borrows the bytes of an ArrayBuffer or ArrayBufferView for Web API code on the VM thread. A buffer is
// unavailable when it is detached, when a view runs past the end of its buffer, or when its length can change (a
// resizable ArrayBuffer or a growable SharedArrayBuffer). The span accessors check nothing themselves: call one only
// after a check passed, and finish with the span before anything that can run JavaScript, which could detach the
// buffer or, by exposing a typed array's buffer, move the view's bytes to new storage. Asking the view for its buffer
// from C++ moves them the same way. A span borrows the buffer's storage, so the cell must stay reachable through its
// last use; an argument of the current call frame does.

#pragma once

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/JSArrayBuffer.h>
#include <JavaScriptCore/JSArrayBufferView.h>
#include <wtf/text/ASCIILiteral.h>

#include <cstdint>
#include <span>

namespace Collo::HostFunctions {

// A null view is unavailable too.
inline bool arrayBufferViewIsUnavailable(JSC::JSArrayBufferView* view)
{
    return !view || view->isDetached() || view->isOutOfBounds() || view->isResizableOrGrowableShared();
}

inline bool arrayBufferIsUnavailableForCopy(JSC::JSArrayBuffer* array_buffer)
{
    auto* buffer = array_buffer ? array_buffer->impl() : nullptr;
    return !buffer || buffer->isDetached() || buffer->isResizableOrGrowableShared();
}

// Returns true when the bytes may be copied; otherwise throws a TypeError carrying `message` into the scope and
// returns false. validateArrayBufferForCopy does the same for an ArrayBuffer.
inline bool validateArrayBufferViewForCopy(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSArrayBufferView* view, WTF::ASCIILiteral message)
{
    if (!arrayBufferViewIsUnavailable(view))
        return true;
    JSC::throwVMTypeError(global_object, scope, message);
    return false;
}

inline bool validateArrayBufferForCopy(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSC::JSArrayBuffer* array_buffer, WTF::ASCIILiteral message)
{
    if (!arrayBufferIsUnavailableForCopy(array_buffer))
        return true;
    JSC::throwVMTypeError(global_object, scope, message);
    return false;
}

inline std::span<uint8_t> mutableArrayBufferViewBytes(JSC::JSArrayBufferView* view)
{
    return { static_cast<uint8_t*>(view->vector()), view->byteLength() };
}

inline std::span<const uint8_t> arrayBufferViewBytes(JSC::JSArrayBufferView* view)
{
    return { static_cast<const uint8_t*>(view->vector()), view->byteLength() };
}

inline std::span<const uint8_t> arrayBufferBytes(JSC::JSArrayBuffer* array_buffer)
{
    auto* buffer = array_buffer->impl();
    return { static_cast<const uint8_t*>(buffer->data()), buffer->byteLength() };
}

} // namespace Collo::HostFunctions
