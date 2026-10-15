// The helpers body_utils.h declares, whose comments there are their contracts. Runs on the VM thread.

#include "host_functions/server/fetch/body_utils.h"

#include "host_functions/webapi/dom/dom_exception.h"
#include "host_functions/webapi/files/formdata.h"
#include "host_functions/webapi/streams/readable_stream.h"
#include "host_functions/webapi/streams/readable_stream_private.h"

#include <JavaScriptCore/ArrayBufferSharingMode.h>
#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/JSArrayBufferView.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSGenericTypedArrayViewInlines.h>
#include <JavaScriptCore/JSONObject.h>
#include <wtf/SIMDUTF.h>
#include <wtf/text/StringBuilder.h>

#include <cstring>

namespace Collo::HostFunctions {

void releaseReadableStreamReader(JSC::JSGlobalObject* global_object, JSC::JSObject* reader)
{
    if (!reader)
        return;
    if (auto* byob_reader = dynamicDowncast<JSColloReadableStreamBYOBReader>(reader)) {
        byob_reader->release(global_object);
        return;
    }
    if (auto* default_reader = dynamicDowncast<JSColloReadableStreamDefaultReader>(reader))
        default_reader->release(global_object);
}

JSC::JSObject* createAlreadyUsedTypeError(JSC::JSGlobalObject* global_object, WTF::ASCIILiteral message)
{
    return JSC::createTypeError(global_object, message);
}

JSC::EncodedJSValue rejectedAlreadyUsedTypeError(JSC::JSGlobalObject* global_object, WTF::ASCIILiteral message)
{
    return rejectedPromise(global_object, createAlreadyUsedTypeError(global_object, message));
}

void throwAlreadyUsedTypeError(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, WTF::ASCIILiteral message)
{
    JSC::throwException(global_object, scope, createAlreadyUsedTypeError(global_object, message));
}

bool appendStringBytes(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, WTF::Vector<uint8_t>& output, const WTF::String& string)
{
    // The string is encoded straight into the output, sized by stringUtf8ByteLength, with no buffer in between. An
    // ASCII Latin-1 string, which JSON.stringify and most response bodies make, is its own UTF-8.
    if (string.isEmpty())
        return true;
    const size_t start = output.size();
    if (string.is8Bit()) {
        auto latin1 = string.span8();
        const auto* chars = reinterpret_cast<const char*>(latin1.data());
        if (simdutf::validate_ascii(chars, latin1.size())) {
            if (output.tryAppend(latin1))
                return true;
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        const size_t utf8_length = simdutf::utf8_length_from_latin1(chars, latin1.size());
        if (!output.tryGrow(start + utf8_length)) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        const size_t written = simdutf::convert_latin1_to_utf8(
            chars, latin1.size(), reinterpret_cast<char*>(output.mutableSpan().subspan(start).data()));
        // The output was sized by the count; a converter that disagreed has written past it or left bytes unset,
        // and neither may leave the worker.
        RELEASE_ASSERT(written == utf8_length);
        return true;
    }
    auto units = string.span16();
    const auto measured = simdutf::utf8_length_from_utf16_with_replacement(units.data(), units.size());
    if (!output.tryGrow(start + measured.count)) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }
    auto* destination = reinterpret_cast<char*>(output.mutableSpan().subspan(start).data());
    // The count reports any surrogate it met, paired or not. Well-formed text, surrogate pairs included, takes the
    // vectorized conversion; only text with an unpaired surrogate takes the replacing one, which writes U+FFFD for
    // each and in this simdutf runs scalar. Both write what the count counted.
    const bool well_formed = measured.error == simdutf::SUCCESS || simdutf::validate_utf16(units.data(), units.size());
    const size_t written = well_formed
        ? simdutf::convert_valid_utf16_to_utf8(units.data(), units.size(), destination)
        : simdutf::convert_utf16_to_utf8_with_replacement(units.data(), units.size(), destination);
    RELEASE_ASSERT(written == measured.count);
    return true;
}

bool copyBytes(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, WTF::Vector<uint8_t>& output,
    std::span<const uint8_t> bytes)
{
    if (output.tryAppend(bytes))
        return true;
    JSC::throwOutOfMemoryError(global_object, scope);
    return false;
}

size_t stringUtf8ByteLength(const WTF::String& string)
{
    if (string.isEmpty())
        return 0;
    if (string.is8Bit()) {
        auto latin1 = string.span8();
        return simdutf::utf8_length_from_latin1(reinterpret_cast<const char*>(latin1.data()), latin1.size());
    }
    // An unpaired surrogate counts as U+FFFD, three bytes, which appendStringBytes writes for it, and a pair as
    // four; simdutf's error field only reports that a surrogate was seen.
    auto units = string.span16();
    return simdutf::utf8_length_from_utf16_with_replacement(units.data(), units.size()).count;
}

bool stringUtf8LengthWithinLimit(const WTF::String& string, size_t limit)
{
    return stringUtf8ByteLength(string) <= limit;
}

std::span<const uint8_t> sharedBytesSpan(const WTF::RefPtr<ColloSharedBytes>& bytes)
{
    if (!bytes)
        return {};
    return bytes->span();
}

bool ensureDecodedStringSize(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, size_t byte_size)
{
    if (byte_size <= WTF::String::MaxLength)
        return true;
    JSC::throwOutOfMemoryError(global_object, scope);
    return false;
}

JSC::EncodedJSValue parseBodyJsonTextToPromise(JSC::JSGlobalObject* global_object, const WTF::String& text)
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    JSC::JSValue parsed = JSC::JSONParse(global_object, stripLeadingUtf8Bom(text));
    if (scope.exception()) {
        auto exception = scope.exception()->value();
        // A termination stays pending and ends the request; nothing may be settled while it unwinds.
        if (!scope.clearExceptionExceptTermination())
            return {};
        if (!exception)
            exception = JSC::createSyntaxError(global_object, "Invalid JSON"_s);
        return rejectedPromise(global_object, exception);
    }
    if (!parsed)
        return rejectedPromise(global_object, JSC::createSyntaxError(global_object, "Invalid JSON"_s));
    return resolvedPromise(global_object, parsed);
}

JSC::EncodedJSValue parseBodyFormDataBytesToPromise(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    std::span<const uint8_t> bytes, WTF::String content_type)
{
    WTF::ASCIILiteral parse_error = "Invalid form data"_s;
    auto* form_data = createFormDataFromBodyBytes(global_object, scope, bytes, WTF::move(content_type), &parse_error);
    RETURN_IF_EXCEPTION(scope, {});
    if (!form_data) {
        if (isFormDataQuotaParseError(parse_error))
            return rejectedPromise(global_object, scope,
                createDOMException(global_object, DOMExceptionCode::QuotaExceededError, WTF::String(parse_error)));
        return rejectedTypeError(global_object, scope, parse_error);
    }
    return resolvedPromise(global_object, form_data);
}

JSC::EncodedJSValue parseBodyFormDataTextToPromise(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const WTF::String& text, WTF::String content_type)
{
    WTF::Vector<uint8_t> bytes;
    if (!appendStringBytes(global_object, scope, bytes, text))
        return {};
    RETURN_IF_EXCEPTION(scope, {});
    return parseBodyFormDataBytesToPromise(global_object, scope, bytes.span(), WTF::move(content_type));
}

JSC::JSArrayBuffer* createArrayBufferCopy(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const uint8_t> bytes)
{
    auto buffer = JSC::ArrayBuffer::tryCreate(bytes);
    if (!buffer) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return nullptr;
    }
    return JSC::JSArrayBuffer::create(global_object->vm(),
        global_object->arrayBufferStructure(JSC::ArrayBufferSharingMode::Default), WTF::move(buffer));
}

JSC::JSArrayBuffer* createArrayBufferCopy(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const BlobStorage& storage, size_t offset, size_t size)
{
    auto buffer = JSC::ArrayBuffer::tryCreateUninitialized(size, 1);
    if (!buffer) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return nullptr;
    }
    if (size)
        storage.copyTo(std::span<uint8_t> { static_cast<uint8_t*>(buffer->data()), size }, offset, size);
    return JSC::JSArrayBuffer::create(global_object->vm(),
        global_object->arrayBufferStructure(JSC::ArrayBufferSharingMode::Default), WTF::move(buffer));
}

JSC::JSUint8Array* createBodyUint8ArrayCopy(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const uint8_t> bytes)
{
    auto* structure = global_object->typedArrayStructureWithTypedArrayType<JSC::TypeUint8>();
    auto* array = JSC::JSUint8Array::createUninitialized(global_object, structure, bytes.size());
    RETURN_IF_EXCEPTION(scope, nullptr);
    if (!bytes.empty())
        std::memcpy(array->vector(), bytes.data(), bytes.size());
    return array;
}

JSC::JSUint8Array* createBodyUint8ArrayCopy(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const BlobStorage& storage, size_t offset, size_t size)
{
    auto* structure = global_object->typedArrayStructureWithTypedArrayType<JSC::TypeUint8>();
    auto* array = JSC::JSUint8Array::createUninitialized(global_object, structure, size);
    RETURN_IF_EXCEPTION(scope, nullptr);
    if (size)
        storage.copyTo(std::span<uint8_t> { static_cast<uint8_t*>(array->vector()), size }, offset, size);
    return array;
}

WTF::String normalizeBlobType(WTF::String type)
{
    if (type.isEmpty())
        return WTF::emptyString();

    WTF::StringBuilder builder;
    builder.reserveCapacity(type.length());
    for (unsigned index = 0; index < type.length(); index++) {
        char16_t character = type[index];
        if (character < 0x20 || character > 0x7e)
            return WTF::emptyString();
        if (character >= 'A' && character <= 'Z')
            character = static_cast<char16_t>(character + 0x20);
        builder.append(character);
    }
    return builder.toString();
}

JSColloBlob* createBodyBlob(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, WTF::Vector<uint8_t>&& bytes, WTF::String type)
{
    auto* blob = JSColloBlob::create(global_object->vm(),
        uncheckedDowncast<Collo::GlobalObject>(global_object)->blobStructure(), WTF::move(bytes),
        normalizeBlobType(WTF::move(type)));
    if (blob)
        return blob;
    JSC::throwOutOfMemoryError(global_object, scope);
    return nullptr;
}

} // namespace Collo::HostFunctions
