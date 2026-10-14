// The Encoding Standard's encodings as TextDecoder and TextDecoderStream see them: one row per encoding naming its
// canonical name and the decoder that reads it, and the label lookup that the constructors run. Everything here is
// constant data and runs on the VM thread; `encodings.cpp` holds the tables, and `text_decoder_common.cpp` the
// decoders the rows name.
//
// The replacement encoding has no row: its labels are absent from the label table, so the constructors throw the
// RangeError the standard requires for them, as they do for an unknown label.

#pragma once

#include "jsc/runtime/state.h"

#include <wtf/text/ASCIILiteral.h>
#include <wtf/text/StringView.h>

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>

namespace Collo::HostFunctions {

enum class TextEncoding : uint8_t {
    Utf8,
    IBM866,
    ISO88592,
    ISO88593,
    ISO88594,
    ISO88595,
    ISO88596,
    ISO88597,
    ISO88598,
    ISO88598I,
    ISO885910,
    ISO885913,
    ISO885914,
    ISO885915,
    ISO885916,
    KOI8R,
    KOI8U,
    Windows874,
    Windows1250,
    Windows1251,
    Windows1252,
    Windows1253,
    Windows1254,
    Windows1255,
    Windows1256,
    Windows1257,
    Windows1258,
    Utf16BE,
    Utf16LE,
    XUserDefined,
    Big5,
    EUCJP,
    ISO2022JP,
    ShiftJIS,
    EUCKR,
    GBK,
    GB18030,
    Macintosh,
    XMacCyrillic,
};

inline constexpr size_t textEncodingCount = static_cast<size_t>(TextEncoding::XMacCyrillic) + 1;

// Only the Utf8, Utf16LE and Utf16BE decoders drop a leading U+FEFF, once per stream unless ignoreBOM is set; the
// others emit it like any other code point.
enum class DecoderKind : uint8_t {
    Utf8,
    Utf16LE,
    Utf16BE,
    // Byte 0x80 + i decodes as entry i of the encoding's index, and bytes below 0x80 as themselves.
    SingleByte,
    XUserDefined,
    // The multi-byte encodings, decoded by the ICU converter the row names.
    Icu,
};

// An Encoding Standard index of a single-byte encoding: entry i holds the code point of byte 0x80 + i. Every index maps
// into the Basic Multilingual Plane, so an entry is one UTF-16 code unit. A byte the index leaves unmapped holds
// unmappedSingleByte, and since no index maps a byte to U+FFFD, the replacing decoder emits every entry as it is and
// the fatal decoder treats U+FFFD as the error.
using SingleByteIndex = std::array<char16_t, 128>;
inline constexpr char16_t unmappedSingleByte = 0xfffd;

struct EncodingSpec {
    TextEncoding encoding;
    // The canonical name, which the `encoding` attribute returns.
    WTF::ASCIILiteral name;
    DecoderKind kind;
    // Set exactly when `kind` is SingleByte.
    const SingleByteIndex* single_byte_index;
    // The name ucnv_open takes, set exactly when `kind` is Icu.
    const char* icu_converter;
};

const EncodingSpec& encodingSpec(TextEncoding);

// The Encoding Standard's "get an encoding": strips leading and trailing ASCII whitespace from `label`, then matches it
// ASCII case-insensitively against the label table. Returns nullopt for an unknown label.
std::optional<TextEncoding> textEncodingForLabel(WTF::StringView label);

} // namespace Collo::HostFunctions
