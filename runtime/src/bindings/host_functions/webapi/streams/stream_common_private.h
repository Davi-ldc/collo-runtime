// Declarations every stream class in the bridge shares: the property
// identifiers that tie a native callback to its cell, buffer and promise
// helpers, and the stream state enums. All of it runs on the VM thread.
//
// A ColloPromiseDeferred from createDeferredPromise (defined in
// jsc/runtime/promise.cpp) owns Strong handles to its promise's resolving
// functions, so it roots that promise, and whatever the promise's reactions
// reach, until settleDeferred settles and releases it.
//
// FIXME: a cell that holds one releases it in its destructor, but only if the
// cell dies first. A reaction that reaches the cell, such as a script closure
// over the stream or a cachedThenCallback function whose state cell leads back
// to it, keeps the cell alive until the deferred settles or destroyVmContents
// clears every value handle, so a stream abandoned with such a promise pending
// lives until VM teardown.
#pragma once

#include "host_functions/webapi/streams/readable_stream.h"

#include "host_functions/support.h"
#include "host_functions/webapi/buffer_source.h"
#include "host_functions/webapi/events/abort.h"

#include <JavaScriptCore/ArrayBufferSharingMode.h>
#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/GetterSetter.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/JSArrayBuffer.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSDataView.h>
#include <JavaScriptCore/JSDestructibleObject.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSGenericTypedArrayViewInlines.h>
#include <JavaScriptCore/JSNativeStdFunction.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSPromise.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/JSTypedArrays.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <JavaScriptCore/Strong.h>
#include <JavaScriptCore/StrongInlines.h>
#include <wtf/FastMalloc.h>
#include <wtf/Forward.h>
#include <wtf/SharedTask.h>
#include <wtf/Vector.h>
#include <wtf/text/CString.h>
#include <wtf/text/MakeString.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <new>
#include <span>

namespace Collo::HostFunctions {

using JSC::EncodedJSValue;
using JSC::JSValue;
using namespace JSC;

JSC_DECLARE_HOST_FUNCTION(resolveUndefinedCallback);
JSC_DECLARE_HOST_FUNCTION(rethrowCallback);

const JSC::Identifier& cachedReadableStreamIdentifier(
    JSC::JSGlobalObject*, JSC::Identifier ColloWebApiCache::*, WTF::ASCIILiteral);
const JSC::Identifier& readableStreamIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& readableStreamOwnerIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& readableStreamIteratorIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& readableStreamIteratorReturnValueIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& readableStreamIteratorReturnPendingIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& readableStreamControllerIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& readableStreamTeeStateIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& teeOriginalIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& teeBranchAIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& teeBranchBIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& teeReadingIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& teeFulfilledIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& teeRejectedIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& teeBranchACanceledIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& teeBranchBCanceledIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& teeBranchAReasonIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& teeBranchBReasonIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& readableStreamFromStateIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& readableStreamFromIteratorIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& readableStreamFromNextIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& readableStreamFromIsAsyncIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& readableStreamFromDoneIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& readableStreamFromNextFulfilledIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& readableStreamFromNextRejectedIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& readableStreamFromValueFulfilledIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& readableStreamFromValueRejectedIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& readableStreamFromReturnFulfilledIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& readableStreamFromReturnRejectedIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& writableStreamIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& writableStreamControllerIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& transformStreamIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& pipeToStateIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& compressionStreamStateIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& textEncoderStreamStateIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& textDecoderStreamStateIdentifier(JSC::JSGlobalObject*);
const JSC::Identifier& byteLengthIdentifier(JSC::JSGlobalObject*);
// Returns the function cached in slot, creating it on first use. The new
// function stores state_cell under state_identifier as a DontEnum property, so
// callback finds its cell through a traced edge; owner is the cell that holds
// slot.
JSC::JSFunction* cachedThenCallback(JSC::JSGlobalObject*, JSC::WriteBarrier<JSC::JSFunction>&, JSC::JSCell*,
    WTF::ASCIILiteral, JSC::NativeFunction, const JSC::Identifier&, JSC::JSCell*);
JSC::JSUint8Array* createUint8ArrayCopy(JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<const uint8_t>);
JSC::JSUint8Array* createUint8Array(JSC::JSGlobalObject*, JSC::ThrowScope&, size_t);
JSC::JSUint8Array* createUint8ArrayCopy(JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<uint8_t>);
// Both wrap a range of bytes without copying. Script can write through the
// result, so bytes must hold the only reference, and the returned buffer keeps
// it alive. A range outside bytes throws a RangeError.
JSC::JSArrayBuffer* createArrayBufferFromExclusiveSharedBytes(
    JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::Ref<ColloSharedBytes>&&, size_t offset, size_t byte_length);
JSC::JSUint8Array* createUint8ArrayFromExclusiveSharedBytes(
    JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::Ref<ColloSharedBytes>&&, size_t offset, size_t byte_length);
// A Uint8Array over a range of the source view's buffer, sharing it.
JSC::JSUint8Array* createUint8ArrayView(
    JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSArrayBufferView*, size_t relative_byte_offset, size_t byte_length);
// The three transfer helpers detach the source view's buffer, as the Streams
// TransferArrayBuffer operation does, and return a view of the same range over
// the transferred contents: a Uint8Array, or a view of the source's own type
// for the SameView variant. A detached, shared, resizable or non-detachable
// buffer throws a TypeError, a range outside the view a RangeError; name
// prefixes the error message.
JSC::JSUint8Array* transferArrayBufferViewToUint8Array(
    JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSArrayBufferView*, WTF::ASCIILiteral);
JSC::JSUint8Array* transferArrayBufferViewRangeToUint8Array(JSC::JSGlobalObject*, JSC::ThrowScope&,
    JSC::JSArrayBufferView*, size_t relative_byte_offset, size_t byte_length, WTF::ASCIILiteral);
JSC::JSArrayBufferView* transferArrayBufferViewRangeToSameView(JSC::JSGlobalObject*, JSC::ThrowScope&,
    JSC::JSArrayBufferView*, size_t relative_byte_offset, size_t byte_length, WTF::ASCIILiteral);
JSC::JSArrayBufferView* requireArrayBufferView(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue, WTF::ASCIILiteral);
std::span<uint8_t> mutableViewBytes(JSC::JSArrayBufferView*);
std::span<const uint8_t> viewBytes(JSC::JSArrayBufferView*);
bool viewRangeIsInside(JSC::JSArrayBufferView*, JSC::JSArrayBufferView*);
bool viewSharesBuffer(JSC::JSArrayBufferView*, JSC::JSArrayBufferView*);
bool valueIsCallable(JSValue);
// The bytes a queued chunk keeps alive: a view or buffer is billed for its
// whole buffer, at the maximum length when resizable, a string for two bytes
// per code unit, and any other value for one byte.
size_t streamChunkMemoryCost(JSValue);
JSC::JSObject* createStreamQueueLimitExceededError(JSC::JSGlobalObject*, WTF::ASCIILiteral message);
// On success, sets the promise and an owned deferred for settleDeferred. On
// failure, throws an OutOfMemoryError or a TypeError and returns false with
// both outputs cleared.
bool createDeferredPromise(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue&, ColloPromiseDeferred*&);
// Resolves or rejects the deferred's promise, then releases the deferred and
// nulls the caller's pointer. A null deferred is ignored, and an exception from
// the resolving function is dropped unless it is a termination.
void settleDeferred(JSC::JSGlobalObject*, ColloPromiseDeferred*&, JSC::JSValue, bool);

// A promise with its resolving functions as plain JSValues, rooted only while
// they sit on the stack or in a traced field.
struct JSDeferredPromise {
    JSC::JSValue promise;
    JSC::JSValue resolve;
    JSC::JSValue reject;
};

bool createJSDeferredPromise(JSC::JSGlobalObject*, JSC::ThrowScope&, JSDeferredPromise&);
// Calls a resolving function with the value. A callback that is not callable
// ends the process; an exception is dropped unless it is a termination.
void settleJSDeferredPromise(JSC::JSGlobalObject*, JSC::JSValue, JSC::JSValue);
JSC::JSObject* createReadResult(JSC::JSGlobalObject*, JSC::JSValue, bool);
EncodedJSValue promiseThenUndefined(JSC::JSGlobalObject*, JSC::ThrowScope&, JSValue);
EncodedJSValue resolvedReadResult(JSC::JSGlobalObject*, JSC::JSValue, bool);

enum class StreamState : uint8_t {
    Readable,
    Closed,
    Errored,
};

enum class WritableState : uint8_t {
    Writable,
    Erroring,
    Errored,
    Closed,
};

class JSColloReadableStream;
class JSColloReadableStreamDefaultReader;
class JSColloReadableStreamDefaultController;
class JSColloReadableStreamBYOBReader;
class JSColloReadableStreamBYOBRequest;
class JSColloReadableByteStreamController;
class JSColloReadableStreamAsyncIterator;
class JSColloWritableStream;
class JSColloWritableStreamDefaultWriter;
class JSColloWritableStreamDefaultController;
class JSColloTransformStream;
class JSColloTransformStreamDefaultController;
class JSColloCompressionStream;
class JSColloPipeToState;

JSValue propertyOrUndefined(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSObject*, WTF::ASCIILiteral);
bool normalizeOptionalCallback(JSC::JSGlobalObject*, JSC::ThrowScope&, JSValue&, WTF::ASCIILiteral);
bool strictCallbackPropertyOrUndefined(
    JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSObject*, WTF::ASCIILiteral, WTF::ASCIILiteral, JSValue&);
bool readResultDone(JSC::JSGlobalObject*, JSValue, bool&, JSValue&);
JSValue readResultValue(JSC::JSGlobalObject*, JSValue);
bool parseQueuingStrategy(JSC::JSGlobalObject*, JSC::ThrowScope&, JSValue, WTF::ASCIILiteral, bool&, double&, JSValue&);
bool validateHighWaterMark(JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::ASCIILiteral, bool, double, double&);
JSC::Structure* streamStructureForNewTarget(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::CallFrame*, JSC::Structure*);

} // namespace Collo::HostFunctions
