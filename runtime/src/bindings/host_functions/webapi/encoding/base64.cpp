// atob and btoa from the HTML Standard's base64 utility methods, run on the VM thread through WTF's base64 codec, which
// runs simdutf. Input that is not forgiving-base64 (atob) or holds a code point above U+00FF (btoa) throws an
// InvalidCharacterError DOMException. A result longer than WTF::String::MaxLength, or one that cannot be allocated,
// throws an OutOfMemoryError, so script input reaches no assertion and no allocation that would end the worker.

#include "host_functions/webapi/encoding/base64.h"

#include "host_functions/webapi/dom/dom_exception.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/ExceptionHelpers.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSString.h>
#include <wtf/StdLibExtras.h>
#include <wtf/Vector.h>
#include <wtf/text/Base64.h>
#include <wtf/text/Latin1Character.h>
#include <wtf/text/StringImpl.h>
#include <wtf/text/WTFString.h>

namespace Collo::HostFunctions {
namespace {

    static JSC::EncodedJSValue throwInvalidCharacter(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
    {
        auto* exception = createDOMException(global_object, DOMExceptionCode::InvalidCharacterError);
        return JSC::JSValue::encode(JSC::throwException(global_object, scope, exception));
    }

    static JSC::EncodedJSValue throwOutOfMemory(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
    {
        return JSC::JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
    }

    // The Infra Standard's forgiving-base64 decode: ASCII whitespace is skipped, at most two `=` may end the input and
    // only when they complete a group of four, and a lone trailing character fails. WTF's fromBase64 runs simdutf's
    // decoder with the loose last-chunk policy, which is that algorithm. maxLengthFromBase64 counts every character
    // that is not trailing padding as data, so it bounds the output of every input the decoder accepts, and of every
    // prefix it decodes before it finds an error; the decode therefore never runs out of room, which fromBase64 would
    // not report as an error. The bound overshoots only for input with whitespace, whose bytes then move into a
    // string of the exact length.
    static JSC::EncodedJSValue decodeAtob(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const WTF::String& encoded)
    {
        auto& vm = global_object->vm();
        std::span<Latin1Character> output;
        auto decoded = WTF::StringImpl::tryCreateUninitialized(WTF::maxLengthFromBase64(encoded), output);
        if (!decoded)
            return throwOutOfMemory(global_object, scope);
        auto [should_throw, read, written] = WTF::fromBase64(
            encoded, output, WTF::Alphabet::Base64, WTF::LastChunkHandling::Loose, WTF::OutputSizeIsMaxLength::No);
        UNUSED_VARIABLE(read);
        if (should_throw == WTF::FromBase64ShouldThrowError::Yes)
            return throwInvalidCharacter(global_object, scope);
        if (written == output.size())
            return JSC::JSValue::encode(JSC::jsString(vm, WTF::String(WTF::move(decoded))));

        std::span<Latin1Character> exact_output;
        auto exact = WTF::StringImpl::tryCreateUninitialized(written, exact_output);
        if (!exact)
            return throwOutOfMemory(global_object, scope);
        memcpySpan(exact_output, output.first(written));
        return JSC::JSValue::encode(JSC::jsString(vm, WTF::String(WTF::move(exact))));
    }

    // A null result from base64EncodeToStringReturnNullIfOverflow means the encoding is longer than
    // WTF::String::MaxLength or could not be allocated. The input goes in as std::byte: the uint8_t overload declares
    // no default options, so a call with the bytes alone would convert them to a CString, a copy whose allocation
    // failure ends the worker.
    static JSC::EncodedJSValue encodeBtoa(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const WTF::String& input)
    {
        auto& vm = global_object->vm();
        if (input.isEmpty())
            return JSC::JSValue::encode(JSC::jsEmptyString(vm));

        WTF::String encoded;
        if (input.is8Bit())
            encoded = WTF::base64EncodeToStringReturnNullIfOverflow(std::as_bytes(input.span8()));
        else {
            if (!input.containsOnlyLatin1())
                return throwInvalidCharacter(global_object, scope);
            // Each code unit of a 16-bit string that fits in Latin-1 stands for one byte, so the units narrow first.
            WTF::Vector<uint8_t> bytes;
            if (!bytes.tryReserveInitialCapacity(input.length()))
                return throwOutOfMemory(global_object, scope);
            for (char16_t unit : input.span16())
                bytes.append(static_cast<uint8_t>(unit));
            encoded = WTF::base64EncodeToStringReturnNullIfOverflow(std::as_bytes(bytes.span()));
        }
        if (encoded.isNull())
            return throwOutOfMemory(global_object, scope);
        return JSC::JSValue::encode(JSC::jsString(vm, encoded));
    }

} // namespace

JSC_DEFINE_HOST_FUNCTION(atob, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto scope = DECLARE_THROW_SCOPE(global_object->vm());

    if (call_frame->argumentCount() == 0)
        return JSC::throwVMTypeError(global_object, scope, "atob requires 1 argument (a string)"_s);

    auto encoded = call_frame->uncheckedArgument(0).toWTFString(global_object);
    RETURN_IF_EXCEPTION(scope, {});

    return decodeAtob(global_object, scope, encoded);
}

JSC_DEFINE_HOST_FUNCTION(btoa, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto scope = DECLARE_THROW_SCOPE(global_object->vm());

    if (call_frame->argumentCount() == 0)
        return JSC::throwVMTypeError(global_object, scope, "btoa requires 1 argument (a string)"_s);

    auto input = call_frame->uncheckedArgument(0).toWTFString(global_object);
    RETURN_IF_EXCEPTION(scope, {});

    return encodeBtoa(global_object, scope, input);
}

} // namespace Collo::HostFunctions
