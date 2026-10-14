// Declarations every stream file shares: the state enums, the promise reactions, and the buffer, promise and argument
// helpers. Everything runs on the VM thread.
//
// A stream cell holds every promise it will settle in a JSC::WriteBarrier<JSC::JSPromise> field it visits and settles
// it through Collo::settlePromise (jsc/runtime/promise.cpp). A false result from that, or from the helpers below, means
// a termination is pending: the caller returns without entering JavaScript or settling anything else. Lists of edges
// are Collo::CellEdgeList and native objects Collo::CellNativeRef (jsc/runtime/cell_edges.h).
//
// A cell waits on a promise through reactToPromise. Each StreamReaction names two host functions, one run on
// fulfillment and one on rejection, that every realm creates once when it installs the stream classes
// (stream_reactions.cpp). The cell rides in the engine's reaction record as its context, a field the collector traces,
// and reaches the handler as its second argument. So a cell that only a pending promise's reactions reference is
// collected with that promise once nothing can settle it, and no function or property is allocated per wait.

#pragma once

#include "host_functions/webapi/streams/readable_stream.h"

#include "host_functions/support.h"
#include "host_functions/webapi/buffer_source.h"
#include "jsc/runtime/cell_edges.h"

#include <JavaScriptCore/ArrayBufferSharingMode.h>
#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/IteratorOperations.h>
#include <JavaScriptCore/JSArrayBuffer.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSDataView.h>
#include <JavaScriptCore/JSDestructibleObject.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSGenericTypedArrayViewInlines.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSPromise.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/JSTypedArrays.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <wtf/FastMalloc.h>
#include <wtf/Forward.h>
#include <wtf/Vector.h>
#include <wtf/text/MakeString.h>

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <span>

namespace Collo::HostFunctions {

// CREATE_METHOD_TABLE, which every stream cell's ClassInfo uses, names JSC's JSCastingHelpers without qualification.
namespace JSCastingHelpers = JSC::JSCastingHelpers;

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

// What a stream cell waits on a promise for. The comment names the context cell the handlers receive, and whether
// the registration passes a result promise that the handler's return value resolves.
enum class StreamReaction : uint8_t {
    // A readable controller; the start promise of its underlying source.
    ReadableStart,
    // A readable controller; the promise its underlying source's pull returned.
    ReadablePull,
    // A ReadableStream; the pending result of a native source's pull.
    NativePull,
    // Any cell; with a result promise that fulfills with undefined once the awaited promise fulfills, or rejects with
    // its reason (ReadableStreamCancel's last step).
    CancelSettled,
    // A tee state; the read it issued on the original stream.
    TeeRead,
    // A tee state; the closed promise of its reader on the original stream, whose rejection errors both branches.
    TeeClosed,
    // A ReadableStream.from state; the promise of an async iterator's next() result.
    FromNext,
    // A ReadableStream.from state; the promise a sync iterator's value resolves.
    FromValue,
    // A ReadableStream.from state, with a result promise; the iterator's return() result.
    FromReturn,
    // A ReadableStream async iterator, with a result promise; the read next() issued.
    IteratorNext,
    // The {value, done} object return() resolves with, with a result promise; the promise return() waits for.
    IteratorReturn,
    // A body consumer; its read of the stream it consumes.
    BodyConsumerRead,
    // A WritableStream; its sink's start promise.
    WritableStart,
    // A WritableStream; its sink's write promise.
    WritableWrite,
    // A WritableStream; its sink's close promise.
    WritableClose,
    // A WritableStream; its sink's abort promise.
    WritableAbort,
    // A TransformStream, with a result promise; the promise its JavaScript transform returned.
    TransformResult,
    // A TransformStream, with a result promise; the promise its JavaScript flush returned.
    TransformFlush,
    // A pipe state; its read of the source.
    PipeRead,
    // A pipe state; a write it issued to the destination.
    PipeWrite,
    // A pipe state; its source reader's closed promise, or its destination writer's closed or ready promise, after
    // which it checks both streams again.
    PipeStreamChange,
    // A pipe state; an action it started while shutting down: an abort or close of the destination, or a cancel of the
    // source.
    PipeShutdown,
};

constexpr size_t stream_reaction_count = static_cast<size_t>(StreamReaction::PipeShutdown) + 1;
// Two handlers per reaction, fulfillment then rejection.
static_assert(2 * stream_reaction_count == ColloWebApiCache::stream_function_count);

// Registers the handlers of `reaction` on `promise`, with `context` passed to whichever runs. `result` is a promise
// that the handler's return value resolves or its exception rejects, or undefined for none. The handlers come from the
// realm of `global_object`. Runs no script.
void reactToPromise(JSC::JSGlobalObject*, JSC::JSPromise*, StreamReaction, JSC::JSCell* context,
    JSC::JSValue result = JSC::jsUndefined());
// A promise of `global_object`'s realm that fulfills with undefined once `value` does and rejects as it does. A value
// that is not a promise counts as fulfilled; a thenable that is not a JSPromise is adopted first. `context` is any cell
// the reaction can carry. Returns null with an exception pending when adopting a thenable throws.
JSC::JSPromise* promiseThenUndefined(JSC::JSGlobalObject*, JSC::JSValue value, JSC::JSCell* context);
// Web IDL's conversion of a callback's result to Promise<undefined>, which the standards apply to the result of every
// underlying source, sink and transformer method: a JSPromise as it is, or a new promise of `global_object`'s realm
// resolved with the value, which adopts a thenable (reading its `then` runs script). Returns null with an exception
// pending only on termination or out of memory.
JSC::JSPromise* promiseResolvedWith(JSC::JSGlobalObject*, JSC::JSValue);
// The whole completion of a callback that returns Promise<undefined>, as Web IDL converts it: when `scope` holds an
// exception, a promise rejected with it, and the exception is cleared; otherwise promiseResolvedWith(`result`). A
// stream that reacts to this promise completes the step in a reaction however the callback returned or threw, so a
// step never starts the next one from inside its own call. Returns null with the exception pending on termination or
// out of memory.
JSC::JSPromise* promiseForCallbackCompletion(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue result);
// Creates the realm's reaction functions. streams_install.cpp calls it before anything can register one.
void installStreamFunctions(Collo::GlobalObject*, JSC::VM&);

// Defines a Web IDL interface object on the realm and returns its constructor: a function named `name` that throws a
// TypeError when called without new, constructs through `construct`, or throws a TypeError when `construct` is null
// because the interface has no public constructor. The constructor and `prototype` are linked both ways, the
// prototype gets its toStringTag, and the global gets a DontEnum property, as Web IDL requires.
JSC::JSFunction* installStreamInterface(Collo::GlobalObject*, JSC::VM&, WTF::ASCIILiteral name, unsigned length,
    JSC::JSObject* prototype, JSC::NativeFunction construct);
// Each family's installer, which streams_install.cpp calls in this order: it defines the family's interfaces and
// stores the structures its cells are built from in the realm's cache.
void installReadableStreamClasses(Collo::GlobalObject*, JSC::VM&);
void installWritableStreamClasses(Collo::GlobalObject*, JSC::VM&);
void installTransformStreamClasses(Collo::GlobalObject*, JSC::VM&);
void installQueuingStrategyClasses(Collo::GlobalObject*, JSC::VM&);

// True while no exception, such as a termination, is pending on the VM.
inline bool noExceptionPending(JSC::VM& vm)
{
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    return !scope.exception();
}

inline bool promiseIsPending(JSC::JSPromise* promise)
{
    return promise && promise->status() == JSC::JSPromise::Status::Pending;
}

// Settles the promise in `slot` and empties the slot first, so script the settlement runs finds no pending promise
// there. An empty slot settles nothing. Returns false when an exception is pending.
bool settleAndClearPromise(
    JSC::JSGlobalObject*, JSC::WriteBarrier<JSC::JSPromise>& slot, JSC::JSValue, bool is_rejection);
// WritableStreamDefaultWriterEnsureReadyPromiseRejected, and the closed promise of ReadableStreamReaderGenericRelease:
// rejects the promise in `slot` with `reason` while it is pending, otherwise puts a promise rejected with `reason` in
// its place, and marks the result handled. `owner` holds `slot`. Returns false when an exception is pending.
bool ensurePromiseRejected(
    JSC::JSGlobalObject*, const JSC::JSCell* owner, JSC::WriteBarrier<JSC::JSPromise>& slot, JSC::JSValue reason);

// A {value, done} result in the engine's iterator result shape, whose two properties are own data properties.
inline JSC::JSObject* readResult(JSC::JSGlobalObject* global_object, JSC::JSValue value, bool done)
{
    return JSC::createIteratorResultObject(global_object, value, done);
}
JSC::EncodedJSValue readResultPromise(JSC::JSGlobalObject*, JSC::JSValue value, bool done);
// Reads the done flag of a {value, done} result from own property storage only, so no getter runs, and neither an
// inherited done nor an accessor counts. Returns false with out_error set to a TypeError when the result is not an
// object or has no own data property done.
bool readResultDone(JSC::JSGlobalObject*, JSC::JSValue result, bool& out_done, JSC::JSValue& out_error);
// The own data property value of a {value, done} result, read the same way, or undefined.
JSC::JSValue readResultValue(JSC::JSGlobalObject*, JSC::JSValue result);

bool valueIsCallable(JSC::JSValue);
// Reads a callback member of a Web IDL dictionary: absent and undefined both give undefined, and a value that is not
// callable throws a TypeError naming `error_name`. Returns false with an exception pending.
bool strictCallbackPropertyOrUndefined(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSObject*,
    WTF::ASCIILiteral property_name, WTF::ASCIILiteral error_name, JSC::JSValue& out);
// Converts `strategy` as a Web IDL QueuingStrategy dictionary (readable_stream_api.cpp says how).
bool parseQueuingStrategy(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue strategy, WTF::ASCIILiteral context,
    bool& out_has_high_water_mark, double& out_high_water_mark, JSC::JSValue& out_size);
// ExtractHighWaterMark: the default when the strategy had none, otherwise the given value unless it is NaN or negative,
// which throws a RangeError prefixed with `context`.
bool validateHighWaterMark(JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::ASCIILiteral context, bool has_high_water_mark,
    double default_high_water_mark, double& high_water_mark);
// Returns `base`, or a structure derived from new.target when a subclass constructs. Returns null with an exception
// pending when deriving throws.
JSC::Structure* streamStructureForNewTarget(
    JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::CallFrame*, JSC::Structure* base);

JSC::JSUint8Array* createUint8ArrayCopy(JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<const uint8_t>);
// A zero-filled Uint8Array.
JSC::JSUint8Array* createUint8Array(JSC::JSGlobalObject*, JSC::ThrowScope&, size_t byte_length);
// Both wrap a range of bytes without copying. Script can write through the result, so bytes must hold the only
// reference, and the returned buffer keeps it alive. A range outside bytes throws a RangeError.
JSC::JSArrayBuffer* createArrayBufferFromExclusiveSharedBytes(
    JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::Ref<ColloSharedBytes>&&, size_t offset, size_t byte_length);
JSC::JSUint8Array* createUint8ArrayFromExclusiveSharedBytes(
    JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::Ref<ColloSharedBytes>&&, size_t offset, size_t byte_length);
// A Uint8Array over a range of the source view's buffer, sharing it.
JSC::JSUint8Array* createUint8ArrayView(
    JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSArrayBufferView*, size_t relative_byte_offset, size_t byte_length);
// The three transfer helpers detach the source view's buffer, as the Streams TransferArrayBuffer operation does, and
// return a view of the same range over the transferred contents: a Uint8Array, or a view of the source's own type for
// the SameView variant. A detached, shared, resizable or non-detachable buffer throws a TypeError, a range outside the
// view a RangeError; `name` prefixes the error message.
JSC::JSUint8Array* transferArrayBufferViewToUint8Array(
    JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSArrayBufferView*, WTF::ASCIILiteral name);
JSC::JSUint8Array* transferArrayBufferViewRangeToUint8Array(JSC::JSGlobalObject*, JSC::ThrowScope&,
    JSC::JSArrayBufferView*, size_t relative_byte_offset, size_t byte_length, WTF::ASCIILiteral name);
JSC::JSArrayBufferView* transferArrayBufferViewRangeToSameView(JSC::JSGlobalObject*, JSC::ThrowScope&,
    JSC::JSArrayBufferView*, size_t relative_byte_offset, size_t byte_length, WTF::ASCIILiteral name);
// The receiver check of every stream method: the value as a cell of class T, or a TypeError naming `class_name`.
template <typename T>
T* requireStreamCell(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value, WTF::ASCIILiteral class_name)
{
    if (auto* cell = dynamicDowncast<T>(value))
        return cell;
    JSC::throwVMTypeError(
        global_object, scope, WTF::makeString(class_name, " method called on incompatible receiver"_s));
    return nullptr;
}

// The value as an ArrayBufferView that is neither detached nor out of bounds, or a TypeError naming `name`.
JSC::JSArrayBufferView* requireArrayBufferView(
    JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue, WTF::ASCIILiteral name);
bool viewRangeIsInside(JSC::JSArrayBufferView* inner, JSC::JSArrayBufferView* outer);
bool viewSharesBuffer(JSC::JSArrayBufferView*, JSC::JSArrayBufferView*);

class JSColloReadableStream;
class JSColloReadableStreamController;
class JSColloReadableStreamDefaultController;
class JSColloReadableByteStreamController;
class JSColloReadableStreamDefaultReader;
class JSColloReadableStreamBYOBReader;
class JSColloReadableStreamBYOBRequest;
class JSColloReadableStreamAsyncIterator;
class JSColloReadableStreamTeeState;
class JSColloReadableStreamFromState;
class JSColloBodyConsumer;
class JSColloWritableStream;
class JSColloWritableStreamDefaultWriter;
class JSColloWritableStreamDefaultController;
class JSColloTransformStream;
class JSColloTransformStreamDefaultController;
class JSColloPipeToState;

} // namespace Collo::HostFunctions
