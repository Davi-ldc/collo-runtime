// UTF-8 for Web APIs, run on the VM thread: the Encoding Standard's UTF-8 decode for bodies, blobs, form data, files
// and TextDecoder, and its UTF-8 encode for TextEncoder, TextEncoderStream and form bodies.
//
// Decoding with error mode replacement turns every invalid sequence into U+FFFD, one per maximal invalid subsequence as
// in the Encoding Standard's UTF-8 decoder; with error mode fatal, an invalid sequence fails the decode. The result is
// a new string that does not alias the input, so the caller may release the bytes as soon as the call returns. Every
// decode allocates its result fallibly and reports one it cannot allocate, including input past WTF::String::MaxLength
// bytes, as an error the caller can throw, so no input length ends the worker.
//
// Encoding turns every lone surrogate into U+FFFD, as the Encoding Standard's UTF-8 encoder does. The text is borrowed
// for the call, which runs no JavaScript.

#pragma once

#include "jsc/runtime/state.h"

#include <JavaScriptCore/JSGlobalObject.h>
#include <wtf/text/StringView.h>
#include <wtf/text/WTFString.h>

#include <cstddef>
#include <cstdint>
#include <span>

namespace Collo::HostFunctions {

// The Encoding Standard's UTF-8 decode, which drops a leading UTF-8 BOM, with error mode replacement. On true `out`
// holds the decoded text; on false an OutOfMemoryError is pending in the scope.
bool decodeUtf8Bytes(JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<const uint8_t>, WTF::String& out);
// The Encoding Standard's UTF-8 decode without BOM, which keeps a leading BOM as U+FEFF, with error mode replacement.
// Fails as decodeUtf8Bytes does.
bool decodeUtf8BytesPreservingBom(JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<const uint8_t>, WTF::String& out);

enum class Utf8DecodeResult : uint8_t {
    Decoded,
    Invalid,
    OutOfMemory,
};
// The Encoding Standard's UTF-8 decode without BOM with error mode fatal: a leading BOM stays as U+FEFF, and bytes
// that are not well-formed UTF-8 give Invalid. `out` holds the text only on Decoded. Throws nothing, so the caller
// picks the error each result raises.
Utf8DecodeResult decodeUtf8Fatal(std::span<const uint8_t>, WTF::String& out);

// Drops a leading U+FEFF from text that is already decoded.
WTF::String stripLeadingUtf8Bom(const WTF::String&);

// The exact length of the UTF-8 encoding of `text`. It cannot overflow: a WTF string holds at most
// WTF::String::MaxLength code units, and each unit encodes to at most three bytes.
size_t utf8EncodedLength(WTF::StringView text);
// Writes the UTF-8 encoding of `text` into `destination`, whose size must be utf8EncodedLength(text).
void encodeUtf8(WTF::StringView text, std::span<uint8_t> destination);

struct Utf8EncodeIntoResult {
    // UTF-16 code units of the text consumed.
    size_t read { 0 };
    // Bytes of the destination written.
    size_t written { 0 };
};
// TextEncoder.encodeInto's encoder: encodes `text` from its start while the next code point's bytes fit in
// `destination`, so a code point is never split, and stops at the first one that does not fit.
Utf8EncodeIntoResult encodeUtf8Into(WTF::StringView text, std::span<uint8_t> destination);

} // namespace Collo::HostFunctions
