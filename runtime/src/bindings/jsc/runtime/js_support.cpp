// Error values and BufferSource access for host functions; js_support.h states the borrowing rule and each helper's
// failure contract. Runs on the VM thread with the JSC API lock held.

#include "jsc/runtime/js_support.h"

#include "host_functions/support.h"

#include <JavaScriptCore/ArrayBuffer.h>
#include <JavaScriptCore/ArrayBufferSharingMode.h>
#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSArrayBuffer.h>
#include <JavaScriptCore/JSArrayBufferView.h>
#include <JavaScriptCore/JSGenericTypedArrayViewInlines.h>
#include <JavaScriptCore/JSTypedArrays.h>
#include <wtf/text/WTFString.h>

namespace Collo::JscSupport {

JSC::JSValue typeErrorValue(JSC::JSGlobalObject* global_object, WTF::String message)
{
    return JSC::createTypeError(global_object, WTF::move(message));
}

JSC::JSValue domExceptionValue(JSC::JSGlobalObject* global_object, DOMExceptionCode code, WTF::String message)
{
    return Collo::HostFunctions::createDOMException(global_object, code, WTF::move(message));
}

JSC::EncodedJSValue rejectedDOMException(JSC::JSGlobalObject* global_object, DOMExceptionCode code, WTF::String message)
{
    return Collo::HostFunctions::rejectedPromise(
        global_object, domExceptionValue(global_object, code, WTF::move(message)));
}

WTF::String valueToStringForPromise(
    JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSC::JSValue value, JSC::JSValue& out_error)
{
    if (value.isUndefined())
        return "undefined"_s;
    auto string = value.toWTFString(global_object);
    if (takePendingException(scope, out_error))
        return {};
    return string;
}

bool borrowBufferSource(
    JSC::JSGlobalObject* global_object, JSC::JSValue value, std::span<const uint8_t>& out, JSC::JSValue& out_error)
{
    if (auto* view = dynamicDowncast<JSC::JSArrayBufferView>(value)) {
        if (view->isDetached() || view->isOutOfBounds()) {
            out_error = typeErrorValue(global_object, "BufferSource is detached"_s);
            return false;
        }
        out = { static_cast<const uint8_t*>(view->vector()), view->byteLength() };
        return true;
    }

    if (auto* array_buffer = dynamicDowncast<JSC::JSArrayBuffer>(value)) {
        auto* buffer = array_buffer->impl();
        if (!buffer || buffer->isResizableOrGrowableShared()) {
            out_error = typeErrorValue(global_object, "BufferSource must be a fixed-length ArrayBuffer"_s);
            return false;
        }
        out = { static_cast<const uint8_t*>(buffer->data()), buffer->byteLength() };
        return true;
    }

    out_error = typeErrorValue(global_object, "Expected an ArrayBuffer, TypedArray, or DataView"_s);
    return false;
}

bool copyBufferSource(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope, JSC::JSValue value,
    WTF::Vector<uint8_t>& out, JSC::JSValue& out_error)
{
    std::span<const uint8_t> bytes;
    if (!borrowBufferSource(global_object, value, bytes, out_error))
        return false;

    if (!out.tryReserveInitialCapacity(bytes.size())) {
        out_error = JSC::createOutOfMemoryError(global_object);
        return false;
    }
    out.append(bytes);
    return !takePendingException(scope, out_error);
}

JSC::JSValue createArrayBufferCopy(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope,
    std::span<const uint8_t> bytes, JSC::JSValue& out_error)
{
    auto buffer = JSC::ArrayBuffer::tryCreate(bytes);
    if (!buffer) {
        out_error = JSC::createOutOfMemoryError(global_object);
        return {};
    }
    auto* result = JSC::JSArrayBuffer::create(global_object->vm(),
        global_object->arrayBufferStructure(JSC::ArrayBufferSharingMode::Default), WTF::move(buffer));
    if (takePendingException(scope, out_error))
        return {};
    return result;
}

}
