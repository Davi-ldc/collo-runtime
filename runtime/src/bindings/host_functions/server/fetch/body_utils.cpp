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
#include <wtf/text/StringBuilder.h>

#include <cstring>
#include <limits>

namespace Collo::HostFunctions {
namespace {

    bool addUtf8CodePointLength(size_t& total, uint32_t code_point)
    {
        size_t bytes = 1;
        if (code_point > 0x7f)
            bytes = code_point <= 0x7ff ? 2 : code_point <= 0xffff ? 3 : 4;
        if (total > std::numeric_limits<size_t>::max() - bytes)
            return false;
        total += bytes;
        return true;
    }

} // namespace

bool bodyValueIsCallable(JSC::JSValue value)
{
    if (!value.isCell())
        return false;
    return JSC::getCallData(value).type != JSC::CallData::Type::None;
}

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
    auto result = string.tryGetUTF8([&](std::span<const char8_t> utf8) -> bool {
        return output.tryAppend(
            std::span<const uint8_t> { reinterpret_cast<const uint8_t*>(utf8.data()), utf8.size() });
    });
    if (!result || !result.value()) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }
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

bool stringUtf8ByteLength(const WTF::String& string, size_t& out)
{
    out = 0;
    if (string.isEmpty())
        return true;

    if (string.is8Bit()) {
        for (auto ch : string.span8()) {
            if (!addUtf8CodePointLength(out, ch))
                return false;
        }
        return true;
    }

    // An unpaired surrogate counts as U+FFFD, three bytes, because tryGetUTF8's lenient conversion writes U+FFFD for
    // it; appendStringBytes then appends exactly this many bytes.
    auto units = string.span16();
    for (size_t index = 0; index < units.size(); index++) {
        uint16_t unit = units[index];
        uint32_t code_point = unit;
        if (unit >= 0xd800 && unit <= 0xdbff && index + 1 < units.size()) {
            uint16_t low = units[index + 1];
            if (low >= 0xdc00 && low <= 0xdfff) {
                code_point = 0x10000 + (((unit - 0xd800) << 10) | (low - 0xdc00));
                index++;
            } else {
                code_point = 0xfffd;
            }
        } else if (unit >= 0xdc00 && unit <= 0xdfff) {
            code_point = 0xfffd;
        }
        if (!addUtf8CodePointLength(out, code_point))
            return false;
    }
    return true;
}

bool stringUtf8LengthWithinLimit(const WTF::String& string, size_t limit)
{
    size_t length = 0;
    return stringUtf8ByteLength(string, length) && length <= limit;
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
        scope.clearExceptionExceptTermination();
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
