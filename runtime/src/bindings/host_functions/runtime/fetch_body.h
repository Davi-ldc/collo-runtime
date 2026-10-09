// Declares the reads, clones and releases of a fetch response body that fetch_body.cpp passes to the worker's Zig
// runtime, which holds the bytes. They run on the VM thread. A body belongs to the request whose fetch produced it,
// so a read, pull or clone outside a turn of that request fails before anything crosses the ABI: a promise-returning
// call returns a promise rejected with a TypeError, and a synchronous call throws one. Without a host runtime a
// promise-returning call throws an Error, a synchronous call throws a TypeError, and cancel and release do nothing.
// A deferred handed to a `collo_runtime_fetch_body_*` call belongs to Zig from then on, including when the call fails.

#pragma once

#include "host_functions/support.h"

#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

namespace Collo::HostFunctions {

// Each returns a promise the runtime settles with the whole body as text, parsed JSON, an ArrayBuffer, a Uint8Array,
// a Blob of `type`, or FormData parsed by `content_type`. A pull returns a promise for the body's next read.
JSC::EncodedJSValue fetchBodyTextForIdentity(
    JSC::JSGlobalObject*, JSC::ThrowScope&, const ColloFetchBodyIdentity& identity);
JSC::EncodedJSValue fetchBodyJsonForIdentity(
    JSC::JSGlobalObject*, JSC::ThrowScope&, const ColloFetchBodyIdentity& identity);
JSC::EncodedJSValue fetchBodyArrayBufferForIdentity(
    JSC::JSGlobalObject*, JSC::ThrowScope&, const ColloFetchBodyIdentity& identity);
JSC::EncodedJSValue fetchBodyBytesForIdentity(
    JSC::JSGlobalObject*, JSC::ThrowScope&, const ColloFetchBodyIdentity& identity);
JSC::EncodedJSValue fetchBodyBlobForIdentity(
    JSC::JSGlobalObject*, JSC::ThrowScope&, const ColloFetchBodyIdentity& identity, WTF::String type);
JSC::EncodedJSValue fetchBodyFormDataForIdentity(
    JSC::JSGlobalObject*, JSC::ThrowScope&, const ColloFetchBodyIdentity& identity, WTF::String content_type);
JSC::EncodedJSValue fetchBodyPullForIdentity(
    JSC::JSGlobalObject*, JSC::ThrowScope&, const ColloFetchBodyIdentity& identity);
// Neither checks the turn. Release takes the ColloVm rather than a global so that a native body source can drop its
// reference without one.
void fetchBodyCancelForIdentity(JSC::JSGlobalObject*, const ColloFetchBodyIdentity& identity);
void fetchBodyReleaseForIdentity(ColloVm&, const ColloFetchBodyIdentity& identity);
// On success `out_identity` names a new view of the same fetch's body, teed from this one and read independently,
// which the caller releases separately. Cloning a view already read or released throws a TypeError.
bool fetchBodyCloneForIdentity(JSC::JSGlobalObject*, JSC::ThrowScope&, const ColloFetchBodyIdentity& identity,
    ColloFetchBodyIdentity& out_identity);

// Both read the body synchronously from the runtime's storage. AppendBytes copies the bytes at once, because the
// runtime lends them only until the body changes or the turn ends (collo_runtime_fetch_body_borrow in abi.h), and
// throws an OutOfMemoryError when `out` cannot grow.
bool fetchBodyByteLengthForIdentity(
    JSC::JSGlobalObject*, JSC::ThrowScope&, const ColloFetchBodyIdentity& identity, size_t& out);
bool fetchBodyAppendBytesForIdentity(
    JSC::JSGlobalObject*, JSC::ThrowScope&, const ColloFetchBodyIdentity& identity, WTF::Vector<uint8_t>& out);

} // namespace Collo::HostFunctions
