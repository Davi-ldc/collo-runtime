// Byte and string helpers that the Body implementation shares with the ReadableStream body consumer
// (readable_stream_consume.cpp) and node:fs. Runs on the VM thread. A helper that takes a ThrowScope reports failure
// by throwing into it, an OutOfMemoryError unless its comment names another error, and returning false, null or an
// empty value. The two form data parsers reject their promise for a body that does not parse.

#pragma once

#include "host_functions/support.h"
#include "host_functions/webapi/encoding/utf8.h"
#include "host_functions/webapi/files/blob.h"
#include "host_functions/webapi/streams/shared_bytes.h"

#include <JavaScriptCore/JSArrayBuffer.h>
#include <JavaScriptCore/JSTypedArrays.h>
#include <wtf/RefPtr.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

#include <span>

namespace Collo::HostFunctions {

// The consumers that resolve with bytes: arrayBuffer(), bytes() and blob().
enum class BodyByteConsumer : uint8_t {
    ArrayBuffer,
    Bytes,
    Blob,
};

bool bodyValueIsCallable(JSC::JSValue);
// Releases the lock of a default or BYOB reader and ignores null or any other object.
void releaseReadableStreamReader(JSC::JSGlobalObject*, JSC::JSObject*);
// The TypeError a used body produces, carrying the caller's message, as a value, a rejected promise or a throw.
JSC::JSObject* createAlreadyUsedTypeError(JSC::JSGlobalObject*, WTF::ASCIILiteral message);
JSC::EncodedJSValue rejectedAlreadyUsedTypeError(JSC::JSGlobalObject*, WTF::ASCIILiteral message);
void throwAlreadyUsedTypeError(JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::ASCIILiteral message);

// Appends the string's UTF-8 encoding, with each unpaired surrogate encoded as U+FFFD.
bool appendStringBytes(JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::Vector<uint8_t>&, const WTF::String&);
bool copyBytes(JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::Vector<uint8_t>&, std::span<const uint8_t>);
// The number of bytes appendStringBytes appends, counted without encoding. Returns false when the count overflows
// size_t, and stringUtf8LengthWithinLimit then returns false too.
bool stringUtf8ByteLength(const WTF::String&, size_t& out);
bool stringUtf8LengthWithinLimit(const WTF::String&, size_t limit);
// An empty span for a null buffer.
std::span<const uint8_t> sharedBytesSpan(const WTF::RefPtr<ColloSharedBytes>&);
// decodeUtf8Bytes accepts at most WTF::String::MaxLength bytes, so a longer body throws an OutOfMemoryError here
// instead of reaching WTF's RELEASE_ASSERT.
bool ensureDecodedStringSize(JSC::JSGlobalObject*, JSC::ThrowScope&, size_t byte_size);
// Parses the text as JSON after dropping a leading U+FEFF, as json() parses bytes after a UTF-8 decode that drops the
// BOM. A parse error rejects the promise, and a termination stays pending.
JSC::EncodedJSValue parseBodyJsonTextToPromise(JSC::JSGlobalObject*, const WTF::String&);
// Parse a form body with the parser `content_type` selects. An unsupported type or a malformed body rejects with a
// TypeError, and a body over one of the parser's caps rejects with a QuotaExceededError DOMException.
JSC::EncodedJSValue parseBodyFormDataBytesToPromise(
    JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<const uint8_t>, WTF::String content_type);
JSC::EncodedJSValue parseBodyFormDataTextToPromise(
    JSC::JSGlobalObject*, JSC::ThrowScope&, const WTF::String&, WTF::String content_type);

// Copy the bytes, or `size` bytes of `storage` at `offset`, into a new ArrayBuffer or Uint8Array. The storage range
// must lie within the storage; only debug builds check it.
JSC::JSArrayBuffer* createArrayBufferCopy(JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<const uint8_t>);
JSC::JSArrayBuffer* createArrayBufferCopy(
    JSC::JSGlobalObject*, JSC::ThrowScope&, const BlobStorage&, size_t offset, size_t size);
JSC::JSUint8Array* createBodyUint8ArrayCopy(JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<const uint8_t>);
JSC::JSUint8Array* createBodyUint8ArrayCopy(
    JSC::JSGlobalObject*, JSC::ThrowScope&, const BlobStorage&, size_t offset, size_t size);
// Normalizes a type as the File API's Blob constructor does: the empty string when any character falls outside
// U+0020 to U+007E, and otherwise the type with ASCII letters lowercased.
WTF::String normalizeBlobType(WTF::String);
// A new Blob that adopts the bytes, with its type normalized.
JSColloBlob* createBodyBlob(JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::Vector<uint8_t>&&, WTF::String type);

} // namespace Collo::HostFunctions
