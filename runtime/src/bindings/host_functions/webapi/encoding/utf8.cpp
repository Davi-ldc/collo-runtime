// Implements the UTF-8 decodes and encodes declared in `utf8.h`, which owns their contract. Decoding validates with
// simdutf and converts well-formed input with it straight into string storage allocated fallibly; whole-text encoding
// goes through simdutf too, and encodeInto's bounded encoding is native, because no library encoder reports how much of
// the text fit. Runs on the VM thread.

#include "host_functions/webapi/encoding/utf8.h"

#include <JavaScriptCore/ExceptionHelpers.h>
#include <wtf/SIMDUTF.h>
#include <wtf/StdLibExtras.h>
#include <wtf/text/Latin1Character.h>
#include <wtf/text/StringImpl.h>

#include <unicode/utf16.h>
#include <unicode/utf8.h>

namespace Collo::HostFunctions {
namespace {

    enum class Utf8ErrorMode : bool {
        Replacement,
        Fatal,
    };

    std::span<const uint8_t> stripLeadingUtf8BomBytes(std::span<const uint8_t> bytes)
    {
        if (bytes.size() < 3)
            return bytes;
        if (bytes[0] != 0xef || bytes[1] != 0xbb || bytes[2] != 0xbf)
            return bytes;
        return bytes.subspan(3);
    }

    // Invalid input decodes in two scalar passes: one counts the UTF-16 code units, the other writes them into a
    // string of exactly that length. U8_NEXT_OR_FFFD emits one U+FFFD per maximal invalid subsequence, as the Encoding
    // Standard's decoder does.
    Utf8DecodeResult decodeInvalidUtf8Replacing(std::span<const uint8_t> bytes, WTF::String& out)
    {
        const size_t size = bytes.size();
        size_t length = 0;
        for (size_t offset = 0; offset < size;) {
            UChar32 code_point;
            U8_NEXT_OR_FFFD(bytes, offset, size, code_point);
            length += U16_LENGTH(code_point);
        }
        std::span<char16_t> units;
        auto impl = WTF::StringImpl::tryCreateUninitialized(length, units);
        if (!impl)
            return Utf8DecodeResult::OutOfMemory;
        size_t written = 0;
        for (size_t offset = 0; offset < size;) {
            UChar32 code_point;
            U8_NEXT_OR_FFFD(bytes, offset, size, code_point);
            U16_APPEND_UNSAFE(units, written, code_point);
        }
        // Both passes walk the same bytes, so a mismatch would mean characters left uninitialized.
        RELEASE_ASSERT(written == length);
        out = WTF::String(WTF::move(impl));
        return Utf8DecodeResult::Decoded;
    }

    // The decode itself, with no BOM handling. ASCII input becomes a Latin-1 string by copy, and other well-formed
    // input converts with simdutf into a UTF-16 string of the length simdutf counts.
    Utf8DecodeResult decodeUtf8(std::span<const uint8_t> bytes, Utf8ErrorMode mode, WTF::String& out)
    {
        out = WTF::String();
        if (bytes.empty()) {
            out = WTF::emptyString();
            return Utf8DecodeResult::Decoded;
        }
        // Each byte decodes to at most one code unit (a four-byte sequence to two), so input within this bound gives a
        // result within it too.
        if (bytes.size() > WTF::String::MaxLength)
            return Utf8DecodeResult::OutOfMemory;

        const char* characters = byteCast<char>(bytes.data());
        if (simdutf::validate_ascii(characters, bytes.size())) {
            std::span<Latin1Character> latin1;
            auto impl = WTF::StringImpl::tryCreateUninitialized(bytes.size(), latin1);
            if (!impl)
                return Utf8DecodeResult::OutOfMemory;
            memcpySpan(latin1, bytes);
            out = WTF::String(WTF::move(impl));
            return Utf8DecodeResult::Decoded;
        }
        if (simdutf::validate_utf8(characters, bytes.size())) {
            const size_t length = simdutf::utf16_length_from_utf8(characters, bytes.size());
            std::span<char16_t> units;
            auto impl = WTF::StringImpl::tryCreateUninitialized(length, units);
            if (!impl)
                return Utf8DecodeResult::OutOfMemory;
            const size_t written = simdutf::convert_valid_utf8_to_utf16(characters, bytes.size(), units.data());
            // simdutf counted the units of the same validated bytes, so a mismatch would leave units uninitialized.
            RELEASE_ASSERT(written == length);
            out = WTF::String(WTF::move(impl));
            return Utf8DecodeResult::Decoded;
        }
        if (mode == Utf8ErrorMode::Fatal)
            return Utf8DecodeResult::Invalid;
        return decodeInvalidUtf8Replacing(bytes, out);
    }

    bool decodeUtf8Replacing(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const uint8_t> bytes,
        WTF::String& out, bool strip_bom)
    {
        if (strip_bom)
            bytes = stripLeadingUtf8BomBytes(bytes);
        const auto result = decodeUtf8(bytes, Utf8ErrorMode::Replacement, out);
        if (result == Utf8DecodeResult::Decoded)
            return true;
        // Error mode replacement turns every invalid sequence into U+FFFD, so only an allocation fails it.
        ASSERT(result == Utf8DecodeResult::OutOfMemory);
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }

    template <typename CharacterType>
    Utf8EncodeIntoResult encodeUtf8IntoCharacters(std::span<const CharacterType> source, std::span<uint8_t> destination)
    {
        Utf8EncodeIntoResult result;
        while (result.read < source.size()) {
            // A run of ASCII copies as it is, up to the room left.
            size_t run_length = 0;
            const size_t room = destination.size() - result.written;
            while (run_length < room && result.read + run_length < source.size()
                && source[result.read + run_length] <= 0x7f)
                ++run_length;
            if (run_length) {
                for (size_t offset = 0; offset < run_length; ++offset)
                    destination[result.written + offset] = static_cast<uint8_t>(source[result.read + offset]);
                result.read += run_length;
                result.written += run_length;
                continue;
            }
            if (!room)
                break;

            UChar32 code_point = source[result.read];
            size_t units = 1;
            if constexpr (sizeof(CharacterType) == 2) {
                if (U16_IS_LEAD(code_point) && result.read + 1 < source.size()
                    && U16_IS_TRAIL(source[result.read + 1])) {
                    code_point = U16_GET_SUPPLEMENTARY(code_point, source[result.read + 1]);
                    units = 2;
                } else if (U16_IS_SURROGATE(code_point))
                    code_point = 0xfffd;
            }
            const size_t length = U8_LENGTH(code_point);
            if (length > room)
                break;
            size_t offset = 0;
            auto output = destination.subspan(result.written, length);
            U8_APPEND_UNSAFE(output.data(), offset, code_point);
            ASSERT(offset == length);
            result.read += units;
            result.written += length;
        }
        return result;
    }

} // namespace

bool decodeUtf8Bytes(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const uint8_t> bytes, WTF::String& out)
{
    return decodeUtf8Replacing(global_object, scope, bytes, out, true);
}

bool decodeUtf8BytesPreservingBom(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const uint8_t> bytes, WTF::String& out)
{
    return decodeUtf8Replacing(global_object, scope, bytes, out, false);
}

Utf8DecodeResult decodeUtf8Fatal(std::span<const uint8_t> bytes, WTF::String& out)
{
    return decodeUtf8(bytes, Utf8ErrorMode::Fatal, out);
}

WTF::String stripLeadingUtf8Bom(const WTF::String& text)
{
    if (text.isEmpty())
        return text;
    if (text[0] != 0xfeff)
        return text;
    return text.substring(1);
}

size_t utf8EncodedLength(WTF::StringView text)
{
    if (text.is8Bit()) {
        auto characters = text.span8();
        return simdutf::utf8_length_from_latin1(byteCast<char>(characters.data()), characters.size());
    }
    auto units = text.span16();
    return simdutf::utf8_length_from_utf16_with_replacement(units.data(), units.size()).count;
}

void encodeUtf8(WTF::StringView text, std::span<uint8_t> destination)
{
    size_t written = 0;
    if (text.is8Bit()) {
        auto characters = text.span8();
        if (characters.size() == destination.size()) {
            // Every character is ASCII, so the bytes are the characters.
            memcpySpan(destination, characters);
            written = characters.size();
        } else
            written = simdutf::convert_latin1_to_utf8(
                byteCast<char>(characters.data()), characters.size(), byteCast<char>(destination.data()));
    } else {
        // simdutf converts well-formed UTF-16 with vector instructions and ill-formed UTF-16 one unit at a time, so
        // the vectorized validation picks the fast conversion for the common case.
        auto units = text.span16();
        if (simdutf::validate_utf16(units.data(), units.size()))
            written
                = simdutf::convert_valid_utf16_to_utf8(units.data(), units.size(), byteCast<char>(destination.data()));
        else
            written = simdutf::convert_utf16_to_utf8_with_replacement(
                units.data(), units.size(), byteCast<char>(destination.data()));
    }
    // The caller sized `destination` with utf8EncodedLength; a shorter conversion would leave bytes uninitialized.
    RELEASE_ASSERT(written == destination.size());
}

Utf8EncodeIntoResult encodeUtf8Into(WTF::StringView text, std::span<uint8_t> destination)
{
    if (text.is8Bit())
        return encodeUtf8IntoCharacters(text.span8(), destination);
    return encodeUtf8IntoCharacters(text.span16(), destination);
}

} // namespace Collo::HostFunctions
