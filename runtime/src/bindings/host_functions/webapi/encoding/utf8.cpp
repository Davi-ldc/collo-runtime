// Implements the UTF-8 decodes declared in `utf8.h`, which owns their contract, with
// WTF::String::fromUTF8ReplacingInvalidSequences. Runs on the VM thread.

#include "host_functions/webapi/encoding/utf8.h"

#include <JavaScriptCore/ExceptionHelpers.h>

namespace Collo::HostFunctions {
namespace {

    std::span<const uint8_t> stripLeadingUtf8BomBytes(std::span<const uint8_t> bytes)
    {
        if (bytes.size() < 3)
            return bytes;
        if (bytes[0] != 0xef || bytes[1] != 0xbb || bytes[2] != 0xbf)
            return bytes;
        return bytes.subspan(3);
    }

    WTF::String decodeUtf8BytesInternal(std::span<const uint8_t> bytes, bool strip_bom)
    {
        if (strip_bom)
            bytes = stripLeadingUtf8BomBytes(bytes);
        if (bytes.empty())
            return WTF::emptyString();
        return WTF::String::fromUTF8ReplacingInvalidSequences(
            std::span<const char8_t> { reinterpret_cast<const char8_t*>(bytes.data()), bytes.size() });
    }

    bool decodeUtf8BytesInternal(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        std::span<const uint8_t> bytes, WTF::String& out, bool strip_bom)
    {
        if (strip_bom)
            bytes = stripLeadingUtf8BomBytes(bytes);
        if (bytes.size() > WTF::String::MaxLength) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        if (bytes.empty()) {
            out = WTF::emptyString();
            return true;
        }
        out = WTF::String::fromUTF8ReplacingInvalidSequences(
            std::span<const char8_t> { reinterpret_cast<const char8_t*>(bytes.data()), bytes.size() });
        if (!out) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        return true;
    }

} // namespace

WTF::String decodeUtf8Bytes(std::span<const uint8_t> bytes) { return decodeUtf8BytesInternal(bytes, true); }

WTF::String decodeUtf8BytesPreservingBom(std::span<const uint8_t> bytes)
{
    return decodeUtf8BytesInternal(bytes, false);
}

bool decodeUtf8Bytes(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const uint8_t> bytes, WTF::String& out)
{
    return decodeUtf8BytesInternal(global_object, scope, bytes, out, true);
}

bool decodeUtf8BytesPreservingBom(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const uint8_t> bytes, WTF::String& out)
{
    return decodeUtf8BytesInternal(global_object, scope, bytes, out, false);
}

WTF::String stripLeadingUtf8Bom(const WTF::String& text)
{
    if (text.isEmpty())
        return text;
    if (text[0] != 0xfeff)
        return text;
    return text.substring(1);
}

} // namespace Collo::HostFunctions
