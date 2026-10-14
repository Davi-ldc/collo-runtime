// The decoders behind TextDecoderCommon, one per DecoderKind: UTF-8 through `utf8.h`, UTF-16 and the single-byte
// encodings natively, x-user-defined, and the multi-byte encodings through ICU. `text_decoder_common.h` owns the state
// they share and the streaming contract. Runs on the VM thread.

#include "host_functions/webapi/encoding/text_decoder_common.h"

#include "host_functions/webapi/buffer_source.h"
#include "host_functions/webapi/encoding/utf8.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/ExceptionHelpers.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/JSArrayBuffer.h>
#include <JavaScriptCore/JSArrayBufferView.h>
#include <JavaScriptCore/JSCInlines.h>
#include <wtf/CheckedArithmetic.h>
#include <wtf/SIMDUTF.h>
#include <wtf/StdLibExtras.h>
#include <wtf/text/ASCIIFastPath.h>
#include <wtf/text/Latin1Character.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringImpl.h>

#include <unicode/ucnv.h>
#include <unicode/ucnv_cb.h>
#include <unicode/utf16.h>

#include <algorithm>
#include <bit>
#include <type_traits>

namespace Collo::HostFunctions {
namespace {

    using JSC::JSValue;
    using WTF::String;

    // WTF builds ICU with UChar as char16_t, so decoded units go to and from ICU without a cast.
    static_assert(std::is_same_v<UChar, char16_t>);
    // The UTF-16LE fast path copies bytes straight into char16_t storage, which is UTF-16LE only on a little-endian
    // target. x86_64 and ARM64, the runtime's targets, are little-endian.
    static_assert(std::endian::native == std::endian::little);

    // Every message a fatal decoder throws for malformed input other than UTF-8.
    constexpr auto invalidEncodedDataMessage = "The encoded data was not valid for this TextDecoder"_s;

    // A string of `length` uninitialized characters, which the caller fills through `output`. Throws an
    // OutOfMemoryError and returns a null string when the length exceeds WTF::String::MaxLength or the allocation
    // fails.
    template <typename CharacterType>
    static String createUninitializedString(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, size_t length, std::span<CharacterType>& output)
    {
        auto impl = WTF::StringImpl::tryCreateUninitialized(length, output);
        if (!impl) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return {};
        }
        return String(WTF::move(impl));
    }

    static bool isUtf8Continuation(uint8_t byte) { return (byte & 0xc0) == 0x80; }

    static bool isUtf8ContinuationInRange(uint8_t byte, uint8_t minimum, uint8_t maximum)
    {
        return byte >= minimum && byte <= maximum;
    }

    static size_t utf8SequenceLength(uint8_t lead)
    {
        if (lead < 0x80)
            return 1;
        if (lead >= 0xc2 && lead <= 0xdf)
            return 2;
        if (lead >= 0xe0 && lead <= 0xef)
            return 3;
        if (lead >= 0xf0 && lead <= 0xf4)
            return 4;
        return 0;
    }

    // Whether the bytes from `start` to the end, fewer than the `expected` length of the sequence their lead byte
    // starts, can still become a valid sequence: the Encoding Standard narrows the second byte's range after 0xE0,
    // 0xED, 0xF0 and 0xF4.
    static bool isValidIncompleteTrailingUtf8(std::span<const uint8_t> bytes, size_t start, size_t expected)
    {
        const size_t available = bytes.size() - start;
        ASSERT(expected > 1);
        ASSERT(available < expected);
        ASSERT(available > 0);

        if (available == 1)
            return true;

        const uint8_t lead = bytes[start];
        const uint8_t second = bytes[start + 1];
        bool second_valid = false;
        if (lead >= 0xc2 && lead <= 0xdf)
            second_valid = isUtf8Continuation(second);
        else if (lead == 0xe0)
            second_valid = isUtf8ContinuationInRange(second, 0xa0, 0xbf);
        else if (lead >= 0xe1 && lead <= 0xec)
            second_valid = isUtf8Continuation(second);
        else if (lead == 0xed)
            second_valid = isUtf8ContinuationInRange(second, 0x80, 0x9f);
        else if (lead >= 0xee && lead <= 0xef)
            second_valid = isUtf8Continuation(second);
        else if (lead == 0xf0)
            second_valid = isUtf8ContinuationInRange(second, 0x90, 0xbf);
        else if (lead >= 0xf1 && lead <= 0xf3)
            second_valid = isUtf8Continuation(second);
        else if (lead == 0xf4)
            second_valid = isUtf8ContinuationInRange(second, 0x80, 0x8f);

        if (!second_valid)
            return false;
        if (available == 2)
            return true;

        ASSERT(expected == 4);
        return isUtf8Continuation(bytes[start + 2]);
    }

    // Finds a sequence at the end of `bytes` that is cut off but can still become valid. On true, `split` is where it
    // starts; on false, `split` is bytes.size().
    static bool hasIncompleteTrailingUtf8(std::span<const uint8_t> bytes, size_t& split)
    {
        split = bytes.size();
        if (bytes.empty())
            return false;

        size_t start = bytes.size() - 1;
        size_t continuation_count = 0;
        while (start > 0 && isUtf8Continuation(bytes[start])) {
            continuation_count++;
            start--;
            if (continuation_count == 3)
                break;
        }

        size_t expected = utf8SequenceLength(bytes[start]);
        if (expected == 0 || expected == 1)
            return false;
        size_t available = bytes.size() - start;
        if (available >= expected)
            return false;
        if (!isValidIncompleteTrailingUtf8(bytes, start, expected))
            return false;
        split = start;
        return true;
    }

    template <bool big_endian> static char16_t utf16CodeUnit(uint8_t first, uint8_t second)
    {
        if constexpr (big_endian)
            return static_cast<char16_t>((first << 8) | second);
        return static_cast<char16_t>((second << 8) | first);
    }

    // The Encoding Standard's decoders emit U+FFFD for every error. ICU's own SUBSTITUTE callback writes U+001A instead
    // for a one-byte error in a converter whose table defines a one-byte substitution character, as the Shift_JIS and
    // EUC-JP tables do, so a decoder that is not fatal substitutes through this callback.
    static void substituteReplacementCharacter(const void*, UConverterToUnicodeArgs* args, const char*, int32_t,
        UConverterCallbackReason reason, UErrorCode* status)
    {
        // A reset, close or clone is a notification, not an error.
        if (reason > UCNV_IRREGULAR)
            return;
        *status = U_ZERO_ERROR;
        static constexpr UChar replacement = 0xFFFD;
        ucnv_cbToUWriteUChars(args, &replacement, 1, 0, status);
    }

} // namespace

void TextDecoderCommon::IcuConverterCloser::operator()(UConverter* converter) const { ucnv_close(converter); }

std::optional<TextDecoderCommon> TextDecoderCommon::create(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue label, JSValue options)
{
    String label_string = "utf-8"_s;
    if (!label.isUndefined()) {
        label_string = label.toWTFString(global_object);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
    }

    bool fatal = false;
    bool ignore_bom = false;
    if (!options.isUndefinedOrNull()) {
        if (!options.isObject()) {
            JSC::throwVMTypeError(global_object, scope, "TextDecoder options must be an object"_s);
            return std::nullopt;
        }
        fatal = decoderOptionBoolean(global_object, scope, options, "fatal"_s);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        ignore_bom = decoderOptionBoolean(global_object, scope, options, "ignoreBOM"_s);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
    }

    auto encoding = textEncodingForLabel(label_string);
    if (!encoding) {
        JSC::throwException(
            global_object, scope, JSC::createRangeError(global_object, "TextDecoder label is not supported"_s));
        return std::nullopt;
    }

    IcuConverter converter;
    if (const char* converter_name = encodingSpec(*encoding).icu_converter) {
        UErrorCode status = U_ZERO_ERROR;
        converter.reset(ucnv_open(converter_name, &status));
        if (U_FAILURE(status) || !converter) {
            JSC::throwException(global_object, scope,
                JSC::createRangeError(global_object, "TextDecoder label is not supported by ICU"_s));
            return std::nullopt;
        }
        ucnv_setToUCallBack(converter.get(), fatal ? UCNV_TO_U_CALLBACK_STOP : substituteReplacementCharacter, nullptr,
            nullptr, nullptr, &status);
        if (U_FAILURE(status)) {
            JSC::throwException(global_object, scope,
                JSC::createRangeError(global_object, "TextDecoder failed to initialize converter"_s));
            return std::nullopt;
        }
    }
    return TextDecoderCommon(*encoding, WTF::move(converter), fatal, ignore_bom);
}

String TextDecoderCommon::decode(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const uint8_t> bytes, bool stream)
{
    auto decoded = decodeChunk(global_object, scope, bytes, stream);
    if (scope.exception() || !stream)
        reset();
    return decoded;
}

String TextDecoderCommon::decodeChunk(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const uint8_t> bytes, bool stream)
{
    const auto& spec = encodingSpec(m_encoding);
    switch (spec.kind) {
    case DecoderKind::Utf8:
        return decodeUtf8(global_object, scope, bytes, stream);
    case DecoderKind::Utf16LE:
        return decodeUtf16<false>(global_object, scope, bytes, stream);
    case DecoderKind::Utf16BE:
        return decodeUtf16<true>(global_object, scope, bytes, stream);
    case DecoderKind::SingleByte:
        return decodeSingleByte(global_object, scope, *spec.single_byte_index, bytes);
    case DecoderKind::XUserDefined:
        return decodeXUserDefined(global_object, scope, bytes);
    case DecoderKind::Icu:
        return decodeIcu(global_object, scope, bytes, stream);
    }
    RELEASE_ASSERT_NOT_REACHED();
}

void TextDecoderCommon::setPending(std::span<const uint8_t> bytes)
{
    RELEASE_ASSERT(bytes.size() <= m_pending.size());
    memcpySpan(std::span { m_pending }, bytes);
    m_pending_length = static_cast<uint8_t>(bytes.size());
}

void TextDecoderCommon::reset()
{
    m_pending_length = 0;
    m_bom_seen = false;
    if (m_converter)
        ucnv_resetToUnicode(m_converter.get());
}

void TextDecoderCommon::release()
{
    m_converter.reset();
    m_pending_length = 0;
    m_bom_seen = false;
}

bool TextDecoderCommon::appendDecodeError(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, WTF::Vector<char16_t>& units)
{
    if (m_fatal) {
        JSC::throwVMTypeError(global_object, scope, invalidEncodedDataMessage);
        return false;
    }
    units.append(0xfffd);
    return true;
}

// Decodes one contiguous UTF-8 run whose BOM, if any, the caller already dropped, through `utf8.h`, which owns the
// decode. A fatal decoder throws a TypeError for invalid UTF-8; either mode throws an OutOfMemoryError for a result it
// cannot allocate, a run longer than WTF::String::MaxLength included.
String TextDecoderCommon::decodeUtf8Run(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const uint8_t> bytes)
{
    String decoded;
    if (!m_fatal) {
        if (!decodeUtf8BytesPreservingBom(global_object, scope, bytes, decoded))
            return {};
        return decoded;
    }
    switch (decodeUtf8Fatal(bytes, decoded)) {
    case Utf8DecodeResult::Decoded:
        return decoded;
    case Utf8DecodeResult::Invalid:
        JSC::throwVMTypeError(global_object, scope, "The encoded data was not valid UTF-8"_s);
        return {};
    case Utf8DecodeResult::OutOfMemory:
        JSC::throwOutOfMemoryError(global_object, scope);
        return {};
    }
    RELEASE_ASSERT_NOT_REACHED();
}

// Returns how many leading bytes to drop as a UTF-8 BOM: 3 when `stream_prefix` starts with EF BB BF and ignoreBOM is
// off, otherwise 0. Only the first non-empty prefix of a stream is checked, and checking it settles the BOM. The
// prefix is the logical start of the stream, which may straddle pending() and the new chunk, so the caller assembles
// it.
size_t TextDecoderCommon::consumeUtf8Bom(std::span<const uint8_t> stream_prefix)
{
    if (m_bom_seen || stream_prefix.empty())
        return 0;
    m_bom_seen = true;
    if (!m_ignore_bom && stream_prefix.size() >= 3 && stream_prefix[0] == 0xef && stream_prefix[1] == 0xbb
        && stream_prefix[2] == 0xbf)
        return 3;
    return 0;
}

// With `stream`, an incomplete sequence at the end is carried in pending() to the next call; on a flush, a carried or
// trailing incomplete sequence decodes as an error. The concatenated output of a stream's calls equals decoding all of
// its bytes as one buffer.
String TextDecoderCommon::decodeUtf8(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const uint8_t> chunk, bool stream)
{
    // Nothing is carried from the previous call, as in a whole-buffer decode or a stream split on sequence boundaries.
    // The chunk is decoded in place: the BOM is cut off as a subspan, and only a trailing incomplete sequence of at
    // most three bytes is copied into pending().
    if (pending().empty()) {
        size_t split = chunk.size();
        if (stream && hasIncompleteTrailingUtf8(chunk, split)) {
            setPending(chunk.subspan(split));
            chunk = chunk.first(split);
        }
        size_t bom = consumeUtf8Bom(chunk);
        return decodeUtf8Run(global_object, scope, chunk.subspan(bom));
    }

    // A previous streaming call left one to three bytes in pending() that begin a valid sequence. Only that boundary
    // sequence is resolved, in a small stack buffer, and the rest of the chunk is decoded in place.
    std::array<uint8_t, 4> boundary;
    size_t boundary_length = pending().size();
    memcpySpan(std::span { boundary }, pending());
    m_pending_length = 0;

    const size_t expected = utf8SequenceLength(boundary[0]);
    ASSERT(expected >= 2 && expected <= 4 && expected > boundary_length);
    const size_t need = expected - boundary_length;

    // Continuation bytes join the boundary until the sequence reaches its expected length, the chunk runs out, or
    // another byte appears. No UTF-8 sequence, valid or not, continues across a byte that is not a continuation byte,
    // so decoding the boundary and the rest of the chunk separately gives the output of decoding pending() and the
    // chunk as one buffer.
    size_t take = 0;
    while (take < need && take < chunk.size() && isUtf8Continuation(chunk[take])) {
        boundary[boundary_length + take] = chunk[take];
        ++take;
    }
    boundary_length += take;
    std::span<const uint8_t> chunk_tail = chunk.subspan(take);
    std::span<const uint8_t> boundary_bytes { boundary.data(), boundary_length };

    // The chunk ran out before the sequence did, with only continuation bytes seen. While the bytes still begin a valid
    // sequence, a streaming call carries them to the next call and a flush decodes them as an error. Bytes that no
    // valid sequence begins with take the resolved path below at once, since no later byte can change their output.
    if (take < need && chunk_tail.empty() && isValidIncompleteTrailingUtf8(boundary_bytes, 0, expected)) {
        if (stream) {
            setPending(boundary_bytes);
            // The BOM stays unsettled: the carried bytes may be the start of a BOM.
            return emptyString();
        }
        // The flushed bytes still go through the BOM check, which a partial BOM never passes.
        size_t bom = consumeUtf8Bom(boundary_bytes);
        return decodeUtf8Run(global_object, scope, boundary_bytes.subspan(bom));
    }

    // The boundary sequence is resolved, complete or broken. A BOM may straddle pending() and the chunk, so the BOM
    // check reads the stream's first three bytes from the boundary and then from the rest of the chunk.
    size_t bom = 0;
    if (!m_bom_seen) {
        std::array<uint8_t, 3> prefix;
        size_t prefix_length = std::min<size_t>(prefix.size(), boundary_length);
        memcpySpan(std::span { prefix }, boundary_bytes.first(prefix_length));
        if (prefix_length < prefix.size()) {
            size_t extra = std::min(prefix.size() - prefix_length, chunk_tail.size());
            memcpySpan(std::span { prefix }.subspan(prefix_length), chunk_tail.first(extra));
            prefix_length += extra;
        }
        bom = consumeUtf8Bom(std::span<const uint8_t> { prefix.data(), prefix_length });
    }

    // A streaming chunk may end in another incomplete sequence, which is carried to the next call.
    if (stream) {
        size_t tail_split = chunk_tail.size();
        if (hasIncompleteTrailingUtf8(chunk_tail, tail_split)) {
            setPending(chunk_tail.subspan(tail_split));
            chunk_tail = chunk_tail.first(tail_split);
        }
    }

    // Drops the BOM bytes from whichever side of the split they fell on.
    std::span<const uint8_t> boundary_decode = boundary_bytes;
    if (bom) {
        const size_t from_boundary = std::min(bom, boundary_length);
        boundary_decode = boundary_bytes.subspan(from_boundary);
        if (bom > from_boundary)
            chunk_tail = chunk_tail.subspan(bom - from_boundary);
    }

    String boundary_string = decodeUtf8Run(global_object, scope, boundary_decode);
    RETURN_IF_EXCEPTION(scope, {});
    if (chunk_tail.empty())
        return boundary_string;
    String tail_string = decodeUtf8Run(global_object, scope, chunk_tail);
    RETURN_IF_EXCEPTION(scope, {});
    if (boundary_string.isEmpty())
        return tail_string;
    auto joined = tryMakeString(boundary_string, tail_string);
    if (joined.isNull()) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return {};
    }
    return joined;
}

// The Encoding Standard's UTF-16 decoder. Between streaming calls it carries the raw bytes of an unfinished code unit
// and of a lead surrogate still waiting for its trail, at most three bytes, in pending().
template <bool big_endian>
String TextDecoderCommon::decodeUtf16(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const uint8_t> chunk, bool stream)
{
    // Nothing is carried and the chunk holds whole code units. When those units are well-formed, the decoder's output
    // is the units themselves, minus a leading BOM, and nothing is left to carry. The bytes go into the string's own
    // storage before validation, because a view may start at any byte offset, which can misalign them for char16_t.
    if (pending().empty() && !(chunk.size() % 2)) {
        const bool strip_bom = !m_bom_seen && !m_ignore_bom && chunk.size() >= 2
            && utf16CodeUnit<big_endian>(chunk[0], chunk[1]) == 0xfeff;
        auto payload = chunk.subspan(strip_bom ? 2 : 0);
        std::span<char16_t> units;
        auto decoded = createUninitializedString(global_object, scope, payload.size() / 2, units);
        RETURN_IF_EXCEPTION(scope, {});
        memcpySpan(asWritableBytes(units), payload);
        if constexpr (big_endian) {
            // Every simdutf implementation reads a block of units before it writes that block, so the swap runs in
            // place.
            simdutf::change_endianness_utf16(units.data(), units.size(), units.data());
        }
        if (units.empty() || simdutf::validate_utf16(units.data(), units.size())) {
            if (!chunk.empty())
                m_bom_seen = true;
            return decoded;
        }
    }

    // Otherwise the decoder runs unit by unit over the carried bytes and then the chunk. Every two bytes give at most
    // one unit, since the U+FFFD for a lone lead surrogate takes the place of the lead itself, and a flush adds at most
    // one U+FFFD, for a cut-off unit or lead surrogate or both.
    const size_t carried = pending().size();
    CheckedSize total_checked = carried;
    total_checked += chunk.size();
    if (total_checked.hasOverflowed()) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return {};
    }
    const size_t total = total_checked.value();
    WTF::Vector<char16_t> units;
    if (!units.tryReserveInitialCapacity(total / 2 + 1)) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return {};
    }
    auto byte_at = [&](size_t index) { return index < carried ? m_pending[index] : chunk[index - carried]; };

    std::optional<char16_t> lead_surrogate;
    size_t index = 0;
    while (index + 2 <= total) {
        const char16_t unit = utf16CodeUnit<big_endian>(byte_at(index), byte_at(index + 1));
        if (lead_surrogate) {
            if (U16_IS_TRAIL(unit)) {
                units.append(*lead_surrogate);
                units.append(unit);
                lead_surrogate.reset();
                index += 2;
                continue;
            }
            // The lead surrogate is an error, and `unit` is decoded again on its own.
            lead_surrogate.reset();
            if (!appendDecodeError(global_object, scope, units))
                return {};
            continue;
        }
        index += 2;
        if (U16_IS_LEAD(unit))
            lead_surrogate = unit;
        else if (U16_IS_TRAIL(unit)) {
            if (!appendDecodeError(global_object, scope, units))
                return {};
        } else
            units.append(unit);
    }

    // What the loop left: the two bytes of a waiting lead surrogate and an odd byte after them.
    const size_t left = lead_surrogate ? index - 2 : index;
    if (stream) {
        std::array<uint8_t, 3> rest;
        const size_t rest_length = total - left;
        for (size_t offset = 0; offset < rest_length; ++offset)
            rest[offset] = byte_at(left + offset);
        setPending({ rest.data(), rest_length });
    } else if (left < total && !appendDecodeError(global_object, scope, units))
        return {};

    return utf16Output(global_object, scope, units.span());
}

// Copies decoded UTF-16 units into a string, dropping the stream's leading BOM.
String TextDecoderCommon::utf16Output(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const char16_t> units)
{
    if (units.empty())
        return emptyString();
    if (!m_bom_seen) {
        m_bom_seen = true;
        if (!m_ignore_bom && units.front() == 0xfeff)
            units = units.subspan(1);
    }
    std::span<char16_t> output;
    auto decoded = createUninitializedString(global_object, scope, units.size(), output);
    RETURN_IF_EXCEPTION(scope, {});
    memcpySpan(output, units);
    return decoded;
}

// Every byte is one code unit and no state carries across calls, so a streaming chunk decodes like a whole buffer, and
// the result is Latin-1 when every unit fits. These encodings have no BOM: FF FE and EF BB BF decode as the characters
// their bytes map to.
String TextDecoderCommon::decodeSingleByte(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    const SingleByteIndex& index, std::span<const uint8_t> input)
{
    auto unit_for = [&](uint8_t byte) { return byte < 0x80 ? static_cast<char16_t>(byte) : index[byte - 0x80]; };

    // A fatal decoder scans every byte for an unmapped one; a replacing decoder stops at the first unit that needs
    // UTF-16 storage.
    bool needs_utf16 = false;
    for (uint8_t byte : input) {
        const char16_t unit = unit_for(byte);
        if (unit == unmappedSingleByte && m_fatal) {
            JSC::throwVMTypeError(global_object, scope, invalidEncodedDataMessage);
            return {};
        }
        if (unit > 0xff) {
            needs_utf16 = true;
            if (!m_fatal)
                break;
        }
    }

    if (!needs_utf16) {
        std::span<Latin1Character> output;
        auto decoded = createUninitializedString(global_object, scope, input.size(), output);
        RETURN_IF_EXCEPTION(scope, {});
        for (size_t offset = 0; offset < input.size(); ++offset)
            output[offset] = static_cast<Latin1Character>(unit_for(input[offset]));
        return decoded;
    }

    std::span<char16_t> output;
    auto decoded = createUninitializedString(global_object, scope, input.size(), output);
    RETURN_IF_EXCEPTION(scope, {});
    for (size_t offset = 0; offset < input.size(); ++offset)
        output[offset] = unit_for(input[offset]);
    return decoded;
}

// x-user-defined decodes a byte below 0x80 as itself and byte b above as U+F780 + b - 0x80, so the result is Latin-1
// exactly when every byte is ASCII. It has no errors, no BOM and no state.
String TextDecoderCommon::decodeXUserDefined(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const uint8_t> input)
{
    if (WTF::charactersAreAllASCII(input)) {
        std::span<Latin1Character> output;
        auto decoded = createUninitializedString(global_object, scope, input.size(), output);
        RETURN_IF_EXCEPTION(scope, {});
        memcpySpan(output, input);
        return decoded;
    }

    std::span<char16_t> output;
    auto decoded = createUninitializedString(global_object, scope, input.size(), output);
    RETURN_IF_EXCEPTION(scope, {});
    for (size_t offset = 0; offset < input.size(); ++offset) {
        const uint8_t byte = input[offset];
        output[offset] = byte < 0x80 ? byte : static_cast<char16_t>(0xf780 + byte - 0x80);
    }
    return decoded;
}

// The multi-byte encodings have no BOM handling: a leading U+FEFF is output like any other code point.
String TextDecoderCommon::decodeIcu(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const uint8_t> input, bool stream)
{
    auto* converter = m_converter.get();
    // create() opens a converter for every encoding whose decoder is ICU's.
    RELEASE_ASSERT(converter);

    static constexpr char empty_source = 0;
    const char* source = input.empty() ? &empty_source : byteCast<char>(input.data());
    const char* const source_limit = source + input.size();

    // Every ICU converter here emits at most one UTF-16 unit per input byte, plus a few for bytes the converter
    // carried from the previous call; the loop grows the buffer whenever ICU reports it full anyway.
    constexpr size_t output_slack_units = 8;
    // The least a step grows the buffer by, so a flush that only drains the converter's carried bytes, with no input
    // left, still makes progress.
    constexpr size_t output_growth_units_min = 64;
    WTF::Vector<char16_t, 256> units;
    CheckedSize initial_capacity = input.size();
    initial_capacity += output_slack_units;
    const size_t capacity = initial_capacity.hasOverflowed()
        ? static_cast<size_t>(String::MaxLength)
        : std::min(initial_capacity.value(), static_cast<size_t>(String::MaxLength));
    if (!units.tryReserveInitialCapacity(capacity)) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return {};
    }

    for (;;) {
        const size_t old_size = units.size();
        if (old_size >= String::MaxLength) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return {};
        }
        // Each step leaves room for the rest of the input, and for at least output_growth_units_min units.
        CheckedSize desired_growth = static_cast<size_t>(source_limit - source);
        desired_growth += output_slack_units;
        const size_t room = String::MaxLength - old_size;
        const size_t growth = desired_growth.hasOverflowed()
            ? room
            : std::min(std::max(output_growth_units_min, desired_growth.value()), room);
        if (!units.tryGrow(old_size + growth)) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return {};
        }

        auto target_units = units.mutableSpan().subspan(old_size);
        char16_t* target = target_units.data();
        char16_t* const target_limit = std::to_address(target_units.end());
        UErrorCode status = U_ZERO_ERROR;
        ucnv_toUnicode(converter, &target, target_limit, &source, source_limit, nullptr, !stream, &status);
        units.shrink(old_size + static_cast<size_t>(target - target_units.data()));

        if (status == U_BUFFER_OVERFLOW_ERROR)
            continue;
        if (U_FAILURE(status)) {
            JSC::throwVMTypeError(global_object, scope, invalidEncodedDataMessage);
            return {};
        }
        break;
    }

    std::span<char16_t> output;
    auto decoded = createUninitializedString(global_object, scope, units.size(), output);
    RETURN_IF_EXCEPTION(scope, {});
    memcpySpan(output, units.span());
    return decoded;
}

bool decoderOptionBoolean(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue dictionary, WTF::ASCIILiteral name)
{
    if (!dictionary.isObject())
        return false;
    auto value = dictionary.getObject()->getIfPropertyExists(
        global_object, JSC::Identifier::fromString(global_object->vm(), name));
    RETURN_IF_EXCEPTION(scope, false);
    if (value.isEmpty() || value.isUndefined())
        return false;
    return value.toBoolean(global_object);
}

bool decoderInputBytes(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value,
    WTF::ASCIILiteral type_error, WTF::Vector<uint8_t>& snapshot, std::span<const uint8_t>& out)
{
    out = {};
    // Neither check below refuses a resizable buffer: decoding runs no JavaScript, so the length read here holds
    // through the decode.
    std::span<const uint8_t> bytes;
    bool is_shared = false;
    if (auto* view = dynamicDowncast<JSC::JSArrayBufferView>(value)) {
        if (view->isDetached() || view->isOutOfBounds())
            return true;
        bytes = arrayBufferViewBytes(view);
        is_shared = view->isShared();
    } else if (auto* array_buffer = dynamicDowncast<JSC::JSArrayBuffer>(value)) {
        auto* buffer = array_buffer->impl();
        if (!buffer || buffer->isDetached())
            return true;
        bytes = arrayBufferBytes(array_buffer);
        is_shared = buffer->isShared();
    } else {
        JSC::throwVMTypeError(global_object, scope, type_error);
        return false;
    }

    if (!is_shared || bytes.empty()) {
        out = bytes;
        return true;
    }
    if (!snapshot.tryAppend(bytes)) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }
    out = snapshot.span();
    return true;
}

} // namespace Collo::HostFunctions
