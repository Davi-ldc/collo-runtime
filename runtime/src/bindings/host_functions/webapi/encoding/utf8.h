// UTF-8 decoding for Web API bodies, blobs and form data, run on the VM thread. Every invalid sequence becomes
// U+FFFD, one per maximal invalid subsequence as in the Encoding Standard's UTF-8 decoder. The result is a new string
// that does not alias the input, so the caller may release the bytes as soon as the call returns. WTF ends the process
// when it cannot allocate the result, in every form below.

#pragma once

#include <JavaScriptCore/JSGlobalObject.h>
#include <wtf/text/WTFString.h>

#include <cstdint>
#include <span>

namespace Collo::HostFunctions {

// The Encoding Standard's UTF-8 decode, which drops a leading UTF-8 BOM. The input must be at most
// WTF::String::MaxLength bytes: WTF's converter RELEASE_ASSERTs on longer input, so script-controlled bytes of
// unbounded length go to the throwing form instead.
WTF::String decodeUtf8Bytes(std::span<const uint8_t>);
// The Encoding Standard's UTF-8 decode without BOM, which keeps a leading BOM as U+FEFF. Same length contract as
// decodeUtf8Bytes.
WTF::String decodeUtf8BytesPreservingBom(std::span<const uint8_t>);
// The same two decodes for input of any length. Input longer than WTF::String::MaxLength throws an OutOfMemoryError
// into the scope and returns false; on true, `out` holds the decoded text.
bool decodeUtf8Bytes(JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<const uint8_t>, WTF::String& out);
bool decodeUtf8BytesPreservingBom(JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<const uint8_t>, WTF::String& out);
// Drops a leading U+FEFF from text that is already decoded.
WTF::String stripLeadingUtf8Bom(const WTF::String&);

} // namespace Collo::HostFunctions
