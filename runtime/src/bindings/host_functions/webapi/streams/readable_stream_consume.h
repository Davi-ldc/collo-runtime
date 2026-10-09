// Reads a whole ReadableStream for the Body methods of Request and Response, and for the blob(), bytes(), json() and
// text() methods of ReadableStream. Runs on the VM thread.

#pragma once

#include "jsc/runtime/state.h"

#include <wtf/text/WTFString.h>

#include <cstdint>

namespace Collo::HostFunctions {

// The Body method being implemented, which decides how the collected bytes are converted.
enum class ReadableStreamBodyConsumer : uint8_t {
    Text,
    Json,
    ArrayBuffer,
    Bytes,
    Blob,
    FormData,
};

// Returns a promise for the whole body converted as the consumer says; content_type becomes a Blob's type and
// selects the form-data parser. The promise rejects with a TypeError when the stream is null, disturbed or locked,
// and with a QuotaExceededError when the body exceeds WebApiMaterializedBodyBytesMax. A stream whose native source
// can drain in one step is read without a reader, and any other stream through its getReader(). The call throws and
// returns an empty value when the consumption cannot be set up for lack of memory.
JSC::EncodedJSValue consumeReadableStreamBodyWithNativeFastPath(JSC::JSGlobalObject*, JSC::ThrowScope&,
    JSC::JSObject* stream, ReadableStreamBodyConsumer, WTF::String content_type);

} // namespace Collo::HostFunctions
