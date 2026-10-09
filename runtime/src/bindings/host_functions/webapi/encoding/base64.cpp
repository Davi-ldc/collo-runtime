// atob and btoa from the HTML Standard's base64 utility methods, run on the VM thread. Input that is not valid base64
// (atob) or holds a code point above U+00FF (btoa) throws an InvalidCharacterError DOMException. Both functions size
// their Latin-1 result before writing it, and a result longer than WTF::String::MaxLength, or one that cannot be
// allocated, throws an OutOfMemoryError. Every check on script input is a thrown error, since hostile input must never
// reach an assertion that ships in a release build. The ASSERTs restate what those checks established, except the one
// after atob decodes, which reports in debug builds an input on which simdutf and decodedBase64Length disagree.

#include "host_functions/webapi/encoding/base64.h"

#include "host_functions/webapi/dom/dom_exception.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSString.h>
#include <wtf/SIMDUTF.h>
#include <wtf/StdLibExtras.h>
#include <wtf/text/Latin1Character.h>
#include <wtf/text/StringImpl.h>
#include <wtf/text/WTFString.h>

#include <array>
#include <cstdint>
#include <span>

namespace Collo::HostFunctions {
namespace {

    static JSC::EncodedJSValue throwInvalidCharacter(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
    {
        auto* exception = createDOMException(global_object, DOMExceptionCode::InvalidCharacterError);
        return JSC::JSValue::encode(JSC::throwException(global_object, scope, exception));
    }

    static JSC::EncodedJSValue throwOutOfMemory(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
    {
        return JSC::JSValue::encode(
            JSC::throwException(global_object, scope, JSC::createOutOfMemoryError(global_object)));
    }

    static bool isTooLargeForWTFString(size_t length) { return length > WTF::String::MaxLength; }

    static bool tryCreateLatin1String(size_t length, std::span<Latin1Character>& output, WTF::String& string)
    {
        if (length == 0) {
            output = {};
            string = WTF::emptyString();
            return true;
        }
        if (isTooLargeForWTFString(length))
            return false;

        auto impl = WTF::StringImpl::tryCreateUninitialized(length, output);
        if (!impl)
            return false;

        string = WTF::String(WTF::move(impl));
        return true;
    }

    static constexpr std::array<Latin1Character, 64> base64_alphabet { 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J',
        'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'a', 'b', 'c', 'd', 'e', 'f',
        'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z', '0', '1',
        '2', '3', '4', '5', '6', '7', '8', '9', '+', '/' };

    template <typename Character> static bool isBase64AsciiWhitespace(Character character)
    {
        return character == ' ' || character == '\t' || character == '\n' || character == '\f' || character == '\r';
    }

    template <typename Character> static bool isBase64Character(Character character)
    {
        return (character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z')
            || (character >= '0' && character <= '9') || character == '+' || character == '/';
    }

    // Checks `input` against the Infra Standard's forgiving-base64 decode: ASCII whitespace is skipped, at most two
    // `=` may end the input and only when they complete a group of four, and a lone trailing character fails. On
    // success, sets `output_length` to the exact number of decoded bytes; on false, atob must throw.
    template <typename Character>
    static bool decodedBase64Length(std::span<const Character> input, size_t& output_length)
    {
        size_t characters = 0;
        size_t padding = 0;
        bool saw_padding = false;

        for (auto character : input) {
            if (isBase64AsciiWhitespace(character))
                continue;

            if (character == '=') {
                saw_padding = true;
                ++padding;
                size_t quartet_size = characters % 4;
                if (padding > 2 || quartet_size < 2 || quartet_size > 3)
                    return false;
                continue;
            }

            if (saw_padding)
                return false;
            if (!isBase64Character(character))
                return false;

            ++characters;
        }

        size_t remaining = characters % 4;
        if (padding) {
            if (remaining == 2 && padding == 2)
                output_length = (characters / 4) * 3 + 1;
            else if (remaining == 3 && padding == 1)
                output_length = (characters / 4) * 3 + 2;
            else
                return false;
        } else {
            if (remaining == 1)
                return false;
            output_length = (characters / 4) * 3;
            if (remaining == 2)
                output_length += 1;
            else if (remaining == 3)
                output_length += 2;
        }

        return true;
    }

    // simdutf decodes the Infra Standard's forgiving-base64 with the standard alphabet and the loose last-chunk
    // policy: ASCII whitespace is skipped, `=` padding is validated when present, and a partial final chunk is
    // decoded. Both options equal simdutf's defaults; they are passed by name so a change of library defaults cannot
    // change what atob accepts.
    static constexpr simdutf::base64_options forgivingBase64Options = simdutf::base64_default;
    static constexpr simdutf::last_chunk_handling_options forgivingBase64LastChunk = simdutf::loose;

    static simdutf::result decodeBase64Bytes(
        std::span<const Latin1Character> input, std::span<Latin1Character> output, size_t& output_length)
    {
        output_length = output.size();
        return simdutf::base64_to_binary_safe(reinterpret_cast<const char*>(input.data()), input.size(),
            reinterpret_cast<char*>(output.data()), output_length, forgivingBase64Options, forgivingBase64LastChunk,
            /* decode_up_to_bad_char */ false);
    }

    static simdutf::result decodeBase64Bytes(
        std::span<const char16_t> input, std::span<Latin1Character> output, size_t& output_length)
    {
        output_length = output.size();
        return simdutf::base64_to_binary_safe(input.data(), input.size(), reinterpret_cast<char*>(output.data()),
            output_length, forgivingBase64Options, forgivingBase64LastChunk, /* decode_up_to_bad_char */ false);
    }

    template <typename Character>
    static JSC::EncodedJSValue decodeAtobBytes(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const Character> input)
    {
        size_t decoded_length = 0;
        if (!decodedBase64Length(input, decoded_length))
            return throwInvalidCharacter(global_object, scope);

        std::span<Latin1Character> output;
        WTF::String decoded;
        if (!tryCreateLatin1String(decoded_length, output, decoded))
            return throwOutOfMemory(global_object, scope);
        if (decoded_length == 0)
            return JSC::JSValue::encode(JSC::jsString(global_object->vm(), decoded));

        // decodedBase64Length validated the input and sized the output exactly, and simdutf decodes the same grammar,
        // so it must succeed and fill the buffer. A decode error or a short write means the two implementations
        // disagree on this input. atob then throws InvalidCharacterError instead of returning a truncated string, and
        // the ASSERT reports the disagreement in debug builds; a RELEASE_ASSERT would let script input end the worker.
        size_t actual_length = 0;
        auto result = decodeBase64Bytes(input, output, actual_length);
        if (result.error != simdutf::error_code::SUCCESS || actual_length != decoded.length()) {
            ASSERT(result.error == simdutf::error_code::SUCCESS && actual_length == decoded.length());
            return throwInvalidCharacter(global_object, scope);
        }
        return JSC::JSValue::encode(JSC::jsString(global_object->vm(), decoded));
    }

    static JSC::EncodedJSValue decodeAtobString(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const WTF::String& encoded)
    {
        if (encoded.isEmpty())
            return JSC::JSValue::encode(JSC::jsString(global_object->vm(), WTF::emptyString()));

        if (encoded.is8Bit())
            return decodeAtobBytes(global_object, scope, encoded.span8());
        return decodeAtobBytes(global_object, scope, encoded.span16());
    }

    static JSC::EncodedJSValue encodeBtoaBytes(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const Latin1Character> input)
    {
        if (input.empty())
            return JSC::JSValue::encode(JSC::jsString(global_object->vm(), WTF::emptyString()));

        const size_t encoded_length = simdutf::base64_length_from_binary(input.size(), simdutf::base64_default);
        if (isTooLargeForWTFString(encoded_length))
            return throwOutOfMemory(global_object, scope);

        std::span<Latin1Character> output;
        WTF::String encoded;
        if (!tryCreateLatin1String(encoded_length, output, encoded))
            return throwOutOfMemory(global_object, scope);

        const size_t written = simdutf::binary_to_base64(reinterpret_cast<const char*>(input.data()), input.size(),
            reinterpret_cast<char*>(output.data()), simdutf::base64_default);
        ASSERT(written == output.size());
        return JSC::JSValue::encode(JSC::jsString(global_object->vm(), encoded));
    }

    // Encodes a 16-bit string whose units are all at most U+00FF, each unit standing for one byte, without first
    // narrowing it to 8 bits. The caller checks the units and sizes `output` with base64_length_from_binary.
    static void encodeBtoaUtf16Latin1Bytes(std::span<const char16_t> input, std::span<Latin1Character> output)
    {
        size_t input_index = 0;
        size_t output_index = 0;

        while (input_index + 3 <= input.size()) {
            unsigned first = input[input_index++];
            unsigned second = input[input_index++];
            unsigned third = input[input_index++];
            ASSERT(first <= 0xff);
            ASSERT(second <= 0xff);
            ASSERT(third <= 0xff);

            unsigned triple = (first << 16) | (second << 8) | third;
            output[output_index++] = base64_alphabet[(triple >> 18) & 0x3f];
            output[output_index++] = base64_alphabet[(triple >> 12) & 0x3f];
            output[output_index++] = base64_alphabet[(triple >> 6) & 0x3f];
            output[output_index++] = base64_alphabet[triple & 0x3f];
        }

        size_t remaining = input.size() - input_index;
        if (remaining == 1) {
            unsigned first = input[input_index];
            ASSERT(first <= 0xff);

            unsigned triple = first << 16;
            output[output_index++] = base64_alphabet[(triple >> 18) & 0x3f];
            output[output_index++] = base64_alphabet[(triple >> 12) & 0x3f];
            output[output_index++] = '=';
            output[output_index++] = '=';
        } else if (remaining == 2) {
            unsigned first = input[input_index++];
            unsigned second = input[input_index];
            ASSERT(first <= 0xff);
            ASSERT(second <= 0xff);

            unsigned triple = (first << 16) | (second << 8);
            output[output_index++] = base64_alphabet[(triple >> 18) & 0x3f];
            output[output_index++] = base64_alphabet[(triple >> 12) & 0x3f];
            output[output_index++] = base64_alphabet[(triple >> 6) & 0x3f];
            output[output_index++] = '=';
        }

        ASSERT(output_index == output.size());
    }

    static JSC::EncodedJSValue encodeBtoaUtf16Latin1String(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const char16_t> input)
    {
        const size_t encoded_length = simdutf::base64_length_from_binary(input.size(), simdutf::base64_default);
        if (isTooLargeForWTFString(encoded_length))
            return throwOutOfMemory(global_object, scope);

        std::span<Latin1Character> output;
        WTF::String encoded;
        if (!tryCreateLatin1String(encoded_length, output, encoded))
            return throwOutOfMemory(global_object, scope);

        encodeBtoaUtf16Latin1Bytes(input, output);
        return JSC::JSValue::encode(JSC::jsString(global_object->vm(), encoded));
    }

    static JSC::EncodedJSValue encodeBtoaString(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const WTF::String& input)
    {
        if (input.is8Bit())
            return encodeBtoaBytes(global_object, scope, input.span8());
        if (!input.containsOnlyLatin1())
            return throwInvalidCharacter(global_object, scope);

        return encodeBtoaUtf16Latin1String(global_object, scope, input.span16());
    }

} // namespace

JSC_DEFINE_HOST_FUNCTION(atob, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto scope = DECLARE_THROW_SCOPE(global_object->vm());

    if (call_frame->argumentCount() == 0)
        return JSC::throwVMTypeError(global_object, scope, "atob requires 1 argument (a string)"_s);

    auto encoded = call_frame->uncheckedArgument(0).toWTFString(global_object);
    RETURN_IF_EXCEPTION(scope, {});

    return decodeAtobString(global_object, scope, encoded);
}

JSC_DEFINE_HOST_FUNCTION(btoa, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto scope = DECLARE_THROW_SCOPE(global_object->vm());

    if (call_frame->argumentCount() == 0)
        return JSC::throwVMTypeError(global_object, scope, "btoa requires 1 argument (a string)"_s);

    auto input = call_frame->uncheckedArgument(0).toWTFString(global_object);
    RETURN_IF_EXCEPTION(scope, {});

    return encodeBtoaString(global_object, scope, input);
}

} // namespace Collo::HostFunctions
