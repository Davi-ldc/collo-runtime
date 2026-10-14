// DOMException throwing and BufferSource access for the WebCrypto bridge; js_support.h states the borrowing rule and
// each helper's failure contract. Runs on the VM thread with the JSC API lock held.

#include "jsc/runtime/js_support.h"

#include <JavaScriptCore/ArrayBuffer.h>
#include <JavaScriptCore/ArrayBufferSharingMode.h>
#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/JSArrayBuffer.h>
#include <JavaScriptCore/JSArrayBufferView.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSGenericTypedArrayViewInlines.h>
#include <JavaScriptCore/JSTypedArrays.h>
#include <wtf/text/WTFString.h>

namespace Collo::JscSupport {

void throwDOMException(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, DOMExceptionCode code, WTF::String message)
{
    JSC::throwException(
        global_object, scope, Collo::HostFunctions::createDOMException(global_object, code, WTF::move(message)));
}

bool isBufferSource(JSC::JSValue value)
{
    return dynamicDowncast<JSC::JSArrayBufferView>(value) || dynamicDowncast<JSC::JSArrayBuffer>(value);
}

std::optional<std::span<const uint8_t>> borrowBufferSource(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value)
{
    if (auto* view = dynamicDowncast<JSC::JSArrayBufferView>(value)) {
        if (view->isDetached() || view->isOutOfBounds()) {
            JSC::throwTypeError(global_object, scope, "BufferSource is detached"_s);
            return std::nullopt;
        }
        return std::span<const uint8_t> { static_cast<const uint8_t*>(view->vector()), view->byteLength() };
    }

    if (auto* array_buffer = dynamicDowncast<JSC::JSArrayBuffer>(value)) {
        auto* buffer = array_buffer->impl();
        if (!buffer || buffer->isResizableOrGrowableShared()) {
            JSC::throwTypeError(global_object, scope, "BufferSource must be a fixed-length ArrayBuffer"_s);
            return std::nullopt;
        }
        return std::span<const uint8_t> { static_cast<const uint8_t*>(buffer->data()), buffer->byteLength() };
    }

    JSC::throwTypeError(global_object, scope, "Expected an ArrayBuffer, TypedArray, or DataView"_s);
    return std::nullopt;
}

std::optional<WTF::Vector<uint8_t>> copyBufferSource(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value)
{
    auto bytes = borrowBufferSource(global_object, scope, value);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    WTF::Vector<uint8_t> copy;
    if (!copy.tryReserveInitialCapacity(bytes->size())) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return std::nullopt;
    }
    copy.append(*bytes);
    return copy;
}

JSC::JSValue createArrayBufferCopy(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const uint8_t> bytes)
{
    auto buffer = JSC::ArrayBuffer::tryCreate(bytes);
    if (!buffer) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return {};
    }
    auto* result = JSC::JSArrayBuffer::create(global_object->vm(),
        global_object->arrayBufferStructure(JSC::ArrayBufferSharingMode::Default), WTF::move(buffer));
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

}
