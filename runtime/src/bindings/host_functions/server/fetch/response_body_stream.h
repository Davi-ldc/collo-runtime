// The extraction step that hands a Response's ReadableStream body to the worker, which then reads it through the
// collo_response_body_stream_* functions response_body_stream.cpp defines. VM thread only.

#pragma once

#include "host_functions/support.h"

namespace Collo::HostFunctions {

// For collo_response_extract: takes `body_stream`, the ReadableStream body of the Response being extracted, into
// `out`. A closed stream has nothing left to send and leaves `out` an empty body. An errored one throws its stored
// error, and a locked or disturbed one, which the Fetch Standard calls unusable, a TypeError; either returns
// COLLO_STATUS_JS_EXCEPTION with the exception pending in `scope`. Otherwise the stream is locked with a reader of the
// bridge's own, so no script can read, cancel or lock it from then on, and `out` becomes a
// COLLO_EXTRACTED_RESPONSE_BODY_READABLE_STREAM body whose `body_stream` the caller owns. Every other step of the
// extraction that can fail must run before this one, since a lock is never undone. Fails with
// COLLO_STATUS_OUT_OF_MEMORY when the handle cannot be made, leaving the stream unlocked.
ColloStatus extractResponseBodyStream(
    ColloVm*, JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSObject* body_stream, ColloExtractedResponseBody& out);

} // namespace Collo::HostFunctions
