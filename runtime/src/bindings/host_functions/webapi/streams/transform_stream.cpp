// TransformStream (Streams, "Transform streams") with a JavaScript or a native transformer, its default controller, the
// GenericTransformStream surface of transform_stream.h, and the installer of the two interfaces. Runs on the VM
// thread, except visitChildren, which collector threads run concurrently.
//
// With a JavaScript transformer, a write waits while backpressure is set: it parks its chunk until the readable side
// pulls, and a parked write that the pull releases after the writable side stopped being writable fails with that
// side's stored error without reaching transform. What transform and flush return or throw becomes a promise
// (promiseForCallbackCompletion), so a thenable is adopted, and the write or the close finishes in that promise's
// reaction, as TransformStreamDefaultControllerPerformTransform and TransformStreamDefaultSinkCloseAlgorithm do; a
// missing flush counts as one that returned undefined.
//
// With a native transformer, a write parks the same way, so the transformer sees a chunk only once the readable side
// has pulled since the last output. Its output is then demand-driven: the pump asks the transformer for output only
// while the readable side wants it, and the write settles once everything it fed the transformer has been enqueued.
// A close enqueues what the transformer's close() left without waiting for demand, closes the readable side and
// settles, as the flush of the Streams Standard's "set up a TransformStream" does; the transformer contract
// (transform_stream.h) bounds that output.
// An enqueue can run script, because fulfilling a pending read looks up `then` on the read result, and that script can
// cancel the stream, read again or error it, so the pump reads its state again after each enqueue and never holds a
// span of transformer data across one.

#include "host_functions/webapi/streams/transform_stream_private.h"

#include <wtf/SetForScope.h>

namespace Collo::HostFunctions {

JSColloTransformStreamDefaultController* JSColloTransformStreamDefaultController::create(
    JSC::VM& vm, JSC::JSGlobalObject* global_object, JSColloTransformStream* stream)
{
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto* object = new (NotNull, JSC::allocateCell<JSColloTransformStreamDefaultController>(vm))
        JSColloTransformStreamDefaultController(vm, collo_global->transformStreamDefaultControllerStructure());
    object->finishCreation(vm, stream);
    return object;
}

JSColloTransformStream* JSColloTransformStream::create(JSC::VM& vm, JSC::Structure* structure, TransformStreamKind kind)
{
    auto* object
        = new (NotNull, JSC::allocateCell<JSColloTransformStream>(vm)) JSColloTransformStream(vm, structure, kind);
    object->finishCreation(vm);
    return object;
}

void JSColloTransformStream::initializeSides(JSC::JSGlobalObject* global_object, JSC::JSPromise* start_promise,
    double writable_high_water_mark, JSC::JSValue writable_size, double readable_high_water_mark,
    JSC::JSValue readable_size)
{
    auto& vm = global_object->vm();
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);

    auto* readable = JSColloReadableStream::create(vm, collo_global);
    auto* readable_controller = JSColloReadableStreamDefaultController::create(vm, global_object, readable);
    readable_controller->setSizeCallback(vm, readable_size);
    readable_controller->setNativeSource(vm, JSColloReadableStreamController::SourceKind::Transform, this);
    readable->setController(vm, readable_controller);
    readable->setHighWaterMark(readable_high_water_mark);
    m_readable.set(vm, this, readable);

    auto* writable = JSColloWritableStream::create(vm, global_object, collo_global->writableStreamStructure());
    writable->controller()->setTransformSink(vm, this);
    writable->controller()->setSizeCallback(vm, writable_size);
    writable->setHighWaterMark(writable_high_water_mark);
    m_writable.set(vm, this, writable);

    // InitializeTransformStream sets backpressure and the readable side's first pull clears it. With a positive
    // readable high-water mark that pull follows start at once, so writes may proceed from the beginning.
    m_backpressure = !(readable_high_water_mark > 0);

    // InitializeTransformStream creates the writable side first, so its start reaction runs before the readable's.
    readable_controller->markStarting();
    writable->startWith(global_object, start_promise);
    readable_controller->startWith(global_object, start_promise);
}

void JSColloTransformStream::setJavaScriptTransformer(JSC::VM& vm, JSColloTransformStreamDefaultController* controller,
    JSC::JSValue transformer, JSC::JSValue transform, JSC::JSValue flush, JSC::JSValue cancel)
{
    m_controller.set(vm, this, controller);
    m_transformer.set(vm, this, transformer);
    m_transform.set(vm, this, transform);
    m_flush.set(vm, this, flush);
    m_cancel.set(vm, this, cancel);
}

void JSColloTransformStream::setNativeTransformer(JSC::VM& vm, WTF::Ref<TransformStreamNativeTransformer>&& transformer)
{
    m_native_transformer.set(vm, this, WTF::move(transformer));
    noteNativeMemoryCost();
}

void JSColloTransformStream::clearAlgorithms()
{
    m_transformer.setUndefined();
    m_transform.setUndefined();
    m_flush.setUndefined();
    m_cancel.setUndefined();
}

void JSColloTransformStream::enqueue(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue chunk)
{
    auto* stream = readable();
    if (!stream) {
        JSC::throwVMTypeError(global_object, scope, "TransformStream readable side is unavailable"_s);
        return;
    }
    stream->enqueue(global_object, scope, chunk);
    if (scope.exception()) {
        // TransformStreamDefaultControllerEnqueue: a failed enqueue errors the writable side and unblocks a parked
        // write before it rethrows.
        JSC::JSValue reason = scope.exception()->value();
        if (!scope.tryClearException())
            return;
        errorWritableAndUnblockWrite(global_object, reason);
        RETURN_IF_EXCEPTION(scope, void());
        JSC::throwException(global_object, scope, reason);
        return;
    }
    if (stream->desiredSize() <= 0 && !stream->hasPendingReadRequests())
        m_backpressure = true;
}

void JSColloTransformStream::error(JSC::JSGlobalObject* global_object, JSC::JSValue reason)
{
    clearAlgorithms();
    m_backpressure = false;
    if (auto* stream = readable())
        stream->error(global_object, reason);
    if (auto* stream = writable())
        stream->error(global_object, reason);
    if (!noExceptionPending(global_object->vm()))
        return;
    if (!rejectPendingWrite(global_object, reason))
        return;
    if (m_native_transformer) {
        releaseNativeTransformer();
        rejectNativeOperation(reason);
        noteNativeMemoryCost();
    }
}

void JSColloTransformStream::terminate(JSC::JSGlobalObject* global_object)
{
    if (auto* stream = readable())
        stream->close(global_object);
    if (!noExceptionPending(global_object->vm()))
        return;
    errorWritableAndUnblockWrite(
        global_object, JSC::createTypeError(global_object, "The transform stream has been terminated"_s));
}

void JSColloTransformStream::errorWritableAndUnblockWrite(JSC::JSGlobalObject* global_object, JSC::JSValue reason)
{
    clearAlgorithms();
    m_backpressure = false;
    if (auto* stream = writable())
        stream->error(global_object, reason);
    if (!noExceptionPending(global_object->vm()))
        return;
    rejectPendingWrite(global_object, reason);
}

bool JSColloTransformStream::rejectPendingWrite(JSC::JSGlobalObject* global_object, JSC::JSValue reason)
{
    m_pending_write_chunk.clear();
    return settleAndClearPromise(global_object, m_pending_write_promise, reason, true);
}

JSC::EncodedJSValue JSColloTransformStream::performTransform(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue chunk)
{
    JSC::JSValue transform = m_transform.get();
    if (!valueIsCallable(transform)) {
        // The identity transform enqueues at once; a failed enqueue errors the writable side before it rethrows.
        enqueue(global_object, scope, chunk);
        RETURN_IF_EXCEPTION(scope, {});
        return JSC::JSValue::encode(JSC::jsUndefined());
    }
    JSC::JSValue result = JSC::jsUndefined();
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(chunk);
    arguments.append(controller());
    if (arguments.hasOverflowed()) {
        JSC::throwOutOfMemoryError(global_object, scope);
    } else {
        auto call_data = JSC::getCallData(transform);
        result = JSC::call(global_object, transform.getObject(), call_data, m_transformer.get(), arguments);
    }
    // TransformStreamDefaultControllerPerformTransform: when the transform's promise rejects, or the transform threw,
    // transformSettled errors both sides and rejects the returned promise with the same reason.
    auto* promise = promiseForCallbackCompletion(global_object, scope, result);
    if (!promise)
        return {};
    auto* transform_promise = Collo::newPromise(global_object);
    reactToPromise(global_object, promise, StreamReaction::TransformResult, this, transform_promise);
    return JSC::JSValue::encode(transform_promise);
}

JSC::JSValue JSColloTransformStream::transformSettled(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value, bool fulfilled)
{
    if (fulfilled)
        return JSC::jsUndefined();
    error(global_object, value);
    RETURN_IF_EXCEPTION(scope, {});
    JSC::throwException(global_object, scope, value);
    return {};
}

JSC::EncodedJSValue JSColloTransformStream::deferWrite(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue chunk)
{
    // The writable side marks a write in flight before it calls this sink and keeps it so until the returned promise
    // settles, so a second write never arrives while one is parked; one that did is refused, never parked over the
    // first.
    if (m_pending_write_promise.get())
        return rejectedTypeError(global_object, scope, "TransformStream already has a parked write"_s);
    auto& vm = global_object->vm();
    auto* promise = Collo::newPromise(global_object);
    m_pending_write_chunk.set(vm, this, chunk);
    m_pending_write_promise.set(vm, this, promise);
    return JSC::JSValue::encode(promise);
}

bool JSColloTransformStream::takeParkedWrite(JSC::JSPromise*& out_promise, JSC::JSValue& out_chunk)
{
    out_promise = m_pending_write_promise.get();
    out_chunk = m_pending_write_chunk.get();
    if (!out_promise)
        return false;
    m_pending_write_chunk.clear();
    m_pending_write_promise.clear();
    // A parked write fails with the writable side's stored error once that side is no longer writable, as when its
    // size callback threw for a later write.
    auto* writable_stream = writable();
    if (!writable_stream || writable_stream->state() != WritableState::Writable) {
        JSC::JSValue stored_error = writable_stream ? writable_stream->storedError() : JSC::JSValue();
        (void)Collo::settlePromise(out_promise, stored_error ? stored_error : JSC::jsUndefined(), true);
        return false;
    }
    return true;
}

void JSColloTransformStream::sourcePull(JSC::JSGlobalObject* global_object)
{
    m_backpressure = false;
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (m_native_transformer) {
        // A pull that script starts during an enqueue finds the pump running, and one that script run by write()
        // starts finds the transformer busy; either way the drive that follows checks demand again.
        if (m_pumping || m_transformer_busy)
            return;
        // A failure errors both sides and rejects the operation; only a termination stays pending.
        if (m_native_operation != NativeOperation::None) {
            driveNativeOperation(global_object, scope);
            return;
        }
    }

    JSC::JSPromise* promise = nullptr;
    JSC::JSValue chunk;
    if (!takeParkedWrite(promise, chunk))
        return;
    if (m_native_transformer) {
        if (m_native_released) {
            (void)Collo::settlePromise(
                promise, JSC::createTypeError(global_object, "TransformStream has ended"_s), true);
            return;
        }
        beginNativeOperation(vm, promise, NativeOperation::Write);
        runNativeWrite(global_object, scope, chunk);
        return;
    }
    JSC::JSValue result = JSC::JSValue::decode(performTransform(global_object, scope, chunk));
    if (scope.exception()) {
        JSC::JSValue reason = scope.exception()->value();
        if (!scope.tryClearException())
            return;
        (void)Collo::settlePromise(promise, reason, true);
        return;
    }
    // Resolving with the transform's result adopts it when it is a promise, so an asynchronous transform keeps the
    // writable side waiting.
    (void)Collo::settlePromise(promise, result ? result : JSC::jsUndefined(), false);
}

JSC::JSValue JSColloTransformStream::sourceCancel(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue reason)
{
    if (m_native_transformer) {
        const bool had_pending = m_native_operation != NativeOperation::None || m_pending_write_promise.get();
        releaseNativeTransformer();
        // A pending or parked write, or a pending close, errors the writable side when its rejected promise reaches the
        // writable stream; with none, the writable side is errored here.
        rejectNativeOperation(reason);
        if (!rejectPendingWrite(global_object, reason))
            return {};
        if (!had_pending) {
            if (auto* stream = writable())
                stream->error(global_object, reason);
        }
        noteNativeMemoryCost();
        RETURN_IF_EXCEPTION(scope, {});
        return JSC::jsUndefined();
    }

    JSC::JSValue cancel = m_cancel.get();
    JSC::JSValue transformer = m_transformer.get();
    clearAlgorithms();
    JSC::JSValue result = JSC::jsUndefined();
    if (valueIsCallable(cancel)) {
        JSC::MarkedArgumentBuffer arguments;
        arguments.append(reason);
        if (arguments.hasOverflowed()) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return {};
        }
        auto call_data = JSC::getCallData(cancel);
        result = JSC::call(global_object, cancel.getObject(), call_data, transformer, arguments);
        if (scope.exception()) {
            // A cancel that throws errors the writable side with what it threw, and the readable side's cancel
            // rejects with it.
            JSC::JSValue exception = scope.exception()->value();
            if (!scope.tryClearException())
                return {};
            errorWritableAndUnblockWrite(global_object, exception);
            RETURN_IF_EXCEPTION(scope, {});
            JSC::throwException(global_object, scope, exception);
            return {};
        }
    }
    errorWritableAndUnblockWrite(global_object, reason);
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

JSC::EncodedJSValue JSColloTransformStream::sinkWrite(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue chunk)
{
    if (!m_native_transformer) {
        // With backpressure the write parks until the readable side pulls; the writable side waits for the returned
        // promise before its next write.
        if (m_backpressure)
            return deferWrite(global_object, scope, chunk);
        return performTransform(global_object, scope, chunk);
    }

    if (m_native_operation != NativeOperation::None || m_pending_write_promise.get())
        return rejectedTypeError(global_object, scope, "TransformStream already has a pending operation"_s);
    if (m_native_released)
        return rejectedTypeError(global_object, scope, "TransformStream has ended"_s);
    // TransformStreamDefaultSinkWriteAlgorithm waits out backpressure before it transforms, so the transformer sees the
    // chunk, and converts it, only once the readable side has pulled since the last output; until then the chunk
    // stays the writable side's.
    if (m_backpressure)
        return deferWrite(global_object, scope, chunk);
    auto* promise = Collo::newPromise(global_object);
    beginNativeOperation(global_object->vm(), promise, NativeOperation::Write);
    runNativeWrite(global_object, scope, chunk);
    RETURN_IF_EXCEPTION(scope, {});
    return JSC::JSValue::encode(promise);
}

void JSColloTransformStream::runNativeWrite(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue chunk)
{
    bool accepted = false;
    {
        WTF::SetForScope busy { m_transformer_busy, true };
        accepted = m_native_transformer->write(global_object, scope, chunk);
    }
    if (m_release_deferred) {
        // Script that write() ran canceled or aborted the stream, which rejected this write; the transformer is
        // released now that write() returned.
        m_release_deferred = false;
        releaseNativeTransformer();
        noteNativeMemoryCost();
        if (scope.exception() && !scope.tryClearException())
            return;
        auto* stream = writable();
        JSC::JSValue reason = stream ? stream->storedError() : JSC::JSValue();
        rejectNativeOperation(reason ? reason : JSC::jsUndefined());
        return;
    }
    noteNativeMemoryCost();
    if (!accepted || scope.exception()) {
        failTransformerCall(global_object, scope);
        return;
    }
    driveNativeOperation(global_object, scope);
}

JSC::EncodedJSValue JSColloTransformStream::sinkClose(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    if (!m_native_transformer) {
        JSC::JSValue flush = m_flush.get();
        JSC::JSValue transformer = m_transformer.get();
        clearAlgorithms();
        JSC::JSValue result = JSC::jsUndefined();
        if (valueIsCallable(flush)) {
            JSC::MarkedArgumentBuffer arguments;
            arguments.append(controller());
            if (arguments.hasOverflowed()) {
                JSC::throwOutOfMemoryError(global_object, scope);
            } else {
                auto call_data = JSC::getCallData(flush);
                result = JSC::call(global_object, flush.getObject(), call_data, transformer, arguments);
            }
        }
        // TransformStreamDefaultSinkCloseAlgorithm: flushSettled closes the readable side, or errors both sides, in
        // the reaction to the flush's promise.
        auto* promise = promiseForCallbackCompletion(global_object, scope, result);
        if (!promise)
            return {};
        auto* flush_promise = Collo::newPromise(global_object);
        reactToPromise(global_object, promise, StreamReaction::TransformFlush, this, flush_promise);
        return JSC::JSValue::encode(flush_promise);
    }

    if (m_native_operation != NativeOperation::None || m_pending_write_promise.get())
        return rejectedTypeError(global_object, scope, "TransformStream already has a pending operation"_s);
    if (m_native_released)
        return rejectedTypeError(global_object, scope, "TransformStream has ended"_s);
    // TransformStreamDefaultSinkCloseAlgorithm runs flush, which enqueues whatever it produces whether or not a read
    // waits, then closes the readable side; the close settles then, before any read takes that output.
    auto* promise = Collo::newPromise(global_object);
    beginNativeOperation(global_object->vm(), promise, NativeOperation::Close);
    bool closed = false;
    {
        WTF::SetForScope busy { m_transformer_busy, true };
        closed = m_native_transformer->close(global_object, scope);
    }
    noteNativeMemoryCost();
    if (!closed || scope.exception())
        failTransformerCall(global_object, scope);
    else
        driveNativeOperation(global_object, scope);
    RETURN_IF_EXCEPTION(scope, {});
    return JSC::JSValue::encode(promise);
}

JSC::EncodedJSValue JSColloTransformStream::sinkAbort(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue reason)
{
    if (m_native_transformer) {
        failNative(global_object, reason);
        RETURN_IF_EXCEPTION(scope, {});
        return JSC::JSValue::encode(JSC::jsUndefined());
    }

    JSC::JSValue cancel = m_cancel.get();
    JSC::JSValue transformer = m_transformer.get();
    clearAlgorithms();
    JSC::JSValue result = JSC::jsUndefined();
    if (valueIsCallable(cancel)) {
        JSC::MarkedArgumentBuffer arguments;
        arguments.append(reason);
        if (arguments.hasOverflowed()) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return {};
        }
        auto call_data = JSC::getCallData(cancel);
        result = JSC::call(global_object, cancel.getObject(), call_data, transformer, arguments);
        if (scope.exception()) {
            JSC::JSValue exception = scope.exception()->value();
            if (!scope.tryClearException())
                return {};
            error(global_object, exception);
            RETURN_IF_EXCEPTION(scope, {});
            JSC::throwException(global_object, scope, exception);
            return {};
        }
    }
    error(global_object, reason);
    RETURN_IF_EXCEPTION(scope, {});
    return JSC::JSValue::encode(result);
}

JSC::JSValue JSColloTransformStream::finishFlush(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    auto* stream = readable();
    if (stream && stream->state() == StreamState::Errored) {
        JSC::throwException(global_object, scope, stream->storedError());
        return {};
    }
    if (stream)
        stream->close(global_object);
    RETURN_IF_EXCEPTION(scope, {});
    return JSC::jsUndefined();
}

JSC::JSValue JSColloTransformStream::flushSettled(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value, bool fulfilled)
{
    if (fulfilled)
        return finishFlush(global_object, scope);
    // A failed flush errors both sides; the close rejects with the readable side's stored error.
    error(global_object, value);
    RETURN_IF_EXCEPTION(scope, {});
    auto* stream = readable();
    JSC::JSValue reason = stream ? stream->storedError() : JSC::JSValue();
    JSC::throwException(global_object, scope, reason ? reason : value);
    return {};
}

bool JSColloTransformStream::readableWantsOutput() const
{
    auto* stream = readable();
    if (!stream || stream->state() != StreamState::Readable)
        return false;
    return stream->hasPendingReadRequests() || stream->desiredSize() > 0;
}

void JSColloTransformStream::failTransformerCall(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    JSC::JSValue reason = scope.exception()
        ? scope.exception()->value()
        : JSC::createTypeError(global_object, "TransformStream transformer failed"_s);
    if (scope.exception() && !scope.tryClearException()) {
        // A termination stays pending and ends the request: free the native state, settle nothing, and let it unwind.
        releaseNativeTransformer();
        (void)takeNativeOperation();
        noteNativeMemoryCost();
        return;
    }
    failNative(global_object, reason);
}

void JSColloTransformStream::beginNativeOperation(JSC::VM& vm, JSC::JSPromise* promise, NativeOperation operation)
{
    m_native_promise.set(vm, this, promise);
    m_native_operation = operation;
}

void JSColloTransformStream::driveNativeOperation(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    // Every caller drives the operation it began or found pending; with none there is nothing to pump or settle.
    auto* promise = m_native_promise.get();
    if (!promise)
        return;
    const PumpResult result = pumpNative(global_object, scope);
    if (auto* exception = scope.exception()) {
        JSC::JSValue reason = exception->value();
        if (!scope.tryClearException()) {
            // A termination stays pending and ends the request: free the native state, settle nothing, and let it
            // unwind.
            releaseNativeTransformer();
            if (m_native_promise.get() == promise)
                (void)takeNativeOperation();
            noteNativeMemoryCost();
            return;
        }
        if (m_native_promise.get() == promise)
            failNative(global_object, reason);
        return;
    }
    if (result == PumpResult::Complete)
        completeNativeOperation(global_object);
}

JSColloTransformStream::PumpResult JSColloTransformStream::pumpNative(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    ASSERT(!m_pumping);
    WTF::SetForScope pumping { m_pumping, true };
    auto* promise = m_native_promise.get();
    while (true) {
        auto* transformer = m_native_transformer.get();
        if (!transformer || m_native_released)
            return PumpResult::Superseded;
        if (!transformer->hasPendingOutput())
            return PumpResult::Complete;
        // What close() left is enqueued whether or not a read waits; the transformer contract bounds it.
        if (m_native_operation == NativeOperation::Write && !readableWantsOutput())
            return PumpResult::Blocked;
        JSC::JSValue chunk;
        {
            WTF::SetForScope busy { m_transformer_busy, true };
            chunk = transformer->produce(global_object, scope);
        }
        noteNativeMemoryCost();
        if (scope.exception())
            return PumpResult::Threw;
        if (!chunk)
            continue;
        // An enqueue runs script: nothing of the transformer is held across it, and the state is read again after it.
        if (auto* stream = readable())
            stream->enqueue(global_object, scope, chunk);
        if (scope.exception())
            return PumpResult::Threw;
        // TransformStreamDefaultControllerEnqueue sets backpressure once the readable side wants no more, so the next
        // write waits for a pull.
        if (!readableWantsOutput())
            m_backpressure = true;
        if (m_native_promise.get() != promise)
            return PumpResult::Superseded;
    }
}

JSC::JSPromise* JSColloTransformStream::takeNativeOperation()
{
    auto* promise = m_native_promise.get();
    m_native_promise.clear();
    m_native_operation = NativeOperation::None;
    return promise;
}

void JSColloTransformStream::completeNativeOperation(JSC::JSGlobalObject* global_object)
{
    if (!m_native_promise.get())
        return;
    const bool closing = m_native_operation == NativeOperation::Close;
    // Closing the readable side settles its pending reads, which runs script, so the operation is detached first.
    auto* promise = takeNativeOperation();
    if (closing) {
        // The transformer produced its last output and is done.
        releaseNativeTransformer();
        noteNativeMemoryCost();
        if (auto* stream = readable())
            stream->close(global_object);
    }
    // settlePromise refuses while a termination that script raised is pending, and then nothing is left to undo.
    (void)Collo::settlePromise(promise, JSC::jsUndefined(), false);
}

void JSColloTransformStream::rejectNativeOperation(JSC::JSValue reason)
{
    if (m_native_operation == NativeOperation::None)
        return;
    auto* promise = takeNativeOperation();
    // The writable side may react to this promise only after it rejects, as when the sink rejects it before returning
    // it, so it is marked handled; the writable side reports the failure through its own promises.
    promise->markAsHandled();
    (void)Collo::settlePromise(promise, reason, true);
}

void JSColloTransformStream::failNative(JSC::JSGlobalObject* global_object, JSC::JSValue reason)
{
    if (auto* stream = readable())
        stream->error(global_object, reason);
    releaseNativeTransformer();
    rejectNativeOperation(reason);
    (void)rejectPendingWrite(global_object, reason);
    noteNativeMemoryCost();
}

void JSColloTransformStream::releaseNativeTransformer()
{
    if (m_transformer_busy) {
        m_release_deferred = true;
        return;
    }
    if (m_native_released)
        return;
    m_native_released = true;
    if (auto* transformer = m_native_transformer.get())
        transformer->release();
}

void JSColloTransformStream::noteNativeMemoryCost()
{
    // A transformer method still on the stack may be changing what memoryCost() reads; its caller notes the cost once
    // it returns.
    if (m_transformer_busy)
        return;
    auto* transformer = m_native_transformer.get();
    const size_t cost = transformer ? transformer->memoryCost() : 0;
    m_native_memory_cost.store(cost, std::memory_order_relaxed);
    if (cost <= m_native_memory_cost_reported)
        return;
    const size_t growth = cost - m_native_memory_cost_reported;
    m_native_memory_cost_reported = cost;
    vm().heap.reportExtraMemoryAllocated(this, growth);
}

JSC::Structure* createTransformStreamStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::JSValue prototype)
{
    return JSColloTransformStream::createStructure(vm, global_object, prototype);
}

JSC::JSObject* createNativeTransformStream(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSC::Structure* structure, TransformStreamKind kind, WTF::Ref<TransformStreamNativeTransformer>&& transformer)
{
    ASSERT(kind != TransformStreamKind::TransformStream);
    auto& vm = global_object->vm();
    auto* stream = JSColloTransformStream::create(vm, structure, kind);
    stream->setNativeTransformer(vm, WTF::move(transformer));
    // The Streams Standard's "set up a TransformStream": a start that returns undefined, through a resolved promise.
    auto* start_promise = JSC::JSPromise::resolvedPromise(global_object, JSC::jsUndefined());
    RETURN_IF_EXCEPTION(scope, nullptr);
    stream->initializeSides(global_object, start_promise, 1, JSC::jsUndefined(), 0, JSC::jsUndefined());
    return stream;
}

JSC::JSObject* transformStreamOfKind(JSC::JSValue value, TransformStreamKind kind)
{
    auto* stream = dynamicDowncast<JSColloTransformStream>(value);
    return stream && stream->kind() == kind ? stream : nullptr;
}

JSC::JSObject* transformStreamReadable(JSC::JSObject* stream)
{
    auto* transform = dynamicDowncast<JSColloTransformStream>(stream);
    return transform ? transform->readable() : nullptr;
}

JSC::JSObject* transformStreamWritable(JSC::JSObject* stream)
{
    auto* transform = dynamicDowncast<JSColloTransformStream>(stream);
    return transform ? transform->writable() : nullptr;
}

TransformStreamNativeTransformer* transformStreamNativeTransformer(JSC::JSObject* stream)
{
    auto* transform = dynamicDowncast<JSColloTransformStream>(stream);
    return transform ? transform->nativeTransformer() : nullptr;
}

namespace {

    JSColloTransformStream* requireTransformStream(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value)
    {
        if (auto* stream = transformStreamOfKind(value, TransformStreamKind::TransformStream))
            return uncheckedDowncast<JSColloTransformStream>(stream);
        JSC::throwVMTypeError(global_object, scope, "TransformStream method called on incompatible receiver"_s);
        return nullptr;
    }

    JSC_DEFINE_HOST_FUNCTION(
        transformStreamConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        // The argument is `optional object`: undefined stands for an empty transformer, and null fails the conversion
        // like any other value that is not an object.
        JSC::JSValue transformer = call_frame->argument(0);
        if (transformer.isUndefined())
            transformer = JSC::constructEmptyObject(global_object);
        if (!transformer.isObject()) {
            JSC::throwVMTypeError(global_object, scope, "TransformStream transformer must be an object"_s);
            return {};
        }

        // Web IDL argument conversion reads the writable strategy, then the readable strategy, before the constructor
        // steps convert the transformer dictionary, whose members are read in lexicographic order: cancel, flush,
        // readableType, start, transform, writableType. Defined readableType or writableType reject only after the
        // conversion.
        bool has_writable_high_water_mark = false;
        double writable_high_water_mark = 0;
        JSC::JSValue writable_size = JSC::jsUndefined();
        if (!parseQueuingStrategy(global_object, scope, call_frame->argument(1), "TransformStream writable"_s,
                has_writable_high_water_mark, writable_high_water_mark, writable_size))
            return {};
        bool has_readable_high_water_mark = false;
        double readable_high_water_mark = 0;
        JSC::JSValue readable_size = JSC::jsUndefined();
        if (!parseQueuingStrategy(global_object, scope, call_frame->argument(2), "TransformStream readable"_s,
                has_readable_high_water_mark, readable_high_water_mark, readable_size))
            return {};

        auto* transformer_object = transformer.getObject();
        JSC::JSValue cancel = JSC::jsUndefined();
        if (!strictCallbackPropertyOrUndefined(
                global_object, scope, transformer_object, "cancel"_s, "TransformStream cancel"_s, cancel))
            return {};
        JSC::JSValue flush = JSC::jsUndefined();
        if (!strictCallbackPropertyOrUndefined(
                global_object, scope, transformer_object, "flush"_s, "TransformStream flush"_s, flush))
            return {};
        JSC::JSValue readable_type
            = transformer_object->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "readableType"_s));
        RETURN_IF_EXCEPTION(scope, {});
        JSC::JSValue start = JSC::jsUndefined();
        if (!strictCallbackPropertyOrUndefined(
                global_object, scope, transformer_object, "start"_s, "TransformStream start"_s, start))
            return {};
        JSC::JSValue transform = JSC::jsUndefined();
        if (!strictCallbackPropertyOrUndefined(
                global_object, scope, transformer_object, "transform"_s, "TransformStream transform"_s, transform))
            return {};
        JSC::JSValue writable_type
            = transformer_object->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "writableType"_s));
        RETURN_IF_EXCEPTION(scope, {});

        if (!readable_type.isEmpty() && !readable_type.isUndefined()) {
            JSC::throwException(global_object, scope,
                JSC::createRangeError(global_object, "TransformStream readableType is invalid"_s));
            return {};
        }
        if (!writable_type.isEmpty() && !writable_type.isUndefined()) {
            JSC::throwException(global_object, scope,
                JSC::createRangeError(global_object, "TransformStream writableType is invalid"_s));
            return {};
        }
        if (!validateHighWaterMark(global_object, scope, "TransformStream readable"_s, has_readable_high_water_mark, 0,
                readable_high_water_mark))
            return {};
        if (!validateHighWaterMark(global_object, scope, "TransformStream writable"_s, has_writable_high_water_mark, 1,
                writable_high_water_mark))
            return {};

        auto* structure
            = streamStructureForNewTarget(global_object, scope, call_frame, collo_global->transformStreamStructure());
        RETURN_IF_EXCEPTION(scope, {});
        auto* stream = JSColloTransformStream::create(vm, structure, TransformStreamKind::TransformStream);
        auto* controller = JSColloTransformStreamDefaultController::create(vm, global_object, stream);
        stream->setJavaScriptTransformer(vm, controller, transformer, transform, flush, cancel);

        // Both sides start once the start promise fulfills, which the transformer's start resolves.
        auto* start_promise = Collo::newPromise(global_object);
        stream->initializeSides(global_object, start_promise, writable_high_water_mark, writable_size,
            readable_high_water_mark, readable_size);
        JSC::JSValue start_result = JSC::jsUndefined();
        if (valueIsCallable(start)) {
            JSC::MarkedArgumentBuffer arguments;
            arguments.append(controller);
            if (arguments.hasOverflowed()) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return {};
            }
            auto call_data = JSC::getCallData(start);
            start_result = JSC::call(global_object, start.getObject(), call_data, transformer, arguments);
            RETURN_IF_EXCEPTION(scope, {});
        }
        if (!Collo::settlePromise(start_promise, start_result, false))
            return {};
        return JSC::JSValue::encode(stream);
    }

    JSC_DEFINE_HOST_FUNCTION(
        transformStreamGetReadable, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireTransformStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSC::JSValue::encode(stream->readable());
    }

    JSC_DEFINE_HOST_FUNCTION(
        transformStreamGetWritable, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireTransformStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSC::JSValue::encode(stream->writable());
    }

    JSColloTransformStreamDefaultController* requireTransformController(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value)
    {
        return requireStreamCell<JSColloTransformStreamDefaultController>(
            global_object, scope, value, "TransformStreamDefaultController"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(
        transformControllerEnqueue, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* controller = requireTransformController(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (auto* stream = controller->transformStream())
            stream->enqueue(global_object, scope, call_frame->argument(0));
        RETURN_IF_EXCEPTION(scope, {});
        return JSC::JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(
        transformControllerError, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* controller = requireTransformController(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (auto* stream = controller->transformStream())
            stream->error(global_object, call_frame->argument(0));
        return JSC::JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(
        transformControllerTerminate, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* controller = requireTransformController(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (auto* stream = controller->transformStream())
            stream->terminate(global_object);
        return JSC::JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(
        transformControllerDesiredSize, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* controller = requireTransformController(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* stream = controller->transformStream();
        auto* readable = stream ? stream->readable() : nullptr;
        if (!readable || readable->state() == StreamState::Errored)
            return JSC::JSValue::encode(JSC::jsNull());
        if (readable->state() == StreamState::Closed)
            return JSC::JSValue::encode(JSC::jsNumber(0));
        return JSC::JSValue::encode(JSC::jsNumber(readable->desiredSize()));
    }

    constexpr unsigned methodAttributes = static_cast<unsigned>(JSC::PropertyAttribute::None);
    constexpr unsigned accessorAttributes = static_cast<unsigned>(JSC::PropertyAttribute::Accessor);

} // namespace

void installTransformStreamClasses(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    auto& cache = global_object->webApiCache();

    auto* stream_prototype = JSC::constructEmptyObject(global_object);
    putWebApiAccessor(
        global_object, stream_prototype, vm, "readable"_s, transformStreamGetReadable, nullptr, accessorAttributes);
    putWebApiAccessor(
        global_object, stream_prototype, vm, "writable"_s, transformStreamGetWritable, nullptr, accessorAttributes);
    installStreamInterface(global_object, vm, "TransformStream"_s, 0, stream_prototype, transformStreamConstruct);
    cache.transform_stream_structure.set(vm, createTransformStreamStructure(vm, global_object, stream_prototype));

    auto* controller_prototype = JSC::constructEmptyObject(global_object);
    putWebApiFunction(
        global_object, controller_prototype, vm, "enqueue"_s, 1, transformControllerEnqueue, methodAttributes);
    putWebApiFunction(
        global_object, controller_prototype, vm, "error"_s, 1, transformControllerError, methodAttributes);
    putWebApiFunction(
        global_object, controller_prototype, vm, "terminate"_s, 0, transformControllerTerminate, methodAttributes);
    putWebApiAccessor(global_object, controller_prototype, vm, "desiredSize"_s, transformControllerDesiredSize, nullptr,
        accessorAttributes);
    installStreamInterface(global_object, vm, "TransformStreamDefaultController"_s, 0, controller_prototype, nullptr);
    cache.transform_stream_default_controller_structure.set(
        vm, JSColloTransformStreamDefaultController::createStructure(vm, global_object, controller_prototype));
}

const JSC::ClassInfo JSColloTransformStream::s_info
    = { "TransformStream"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloTransformStream) };
const JSC::ClassInfo JSColloTransformStreamDefaultController::s_info = { "TransformStreamDefaultController"_s,
    &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloTransformStreamDefaultController) };

// Runs on collector threads while the VM thread mutates the cell: it visits every WriteBarrier field, reaches the
// native transformer only through CellNativeRef's protocol, and reads the native cost only through its atomic.
template <typename Visitor> void JSColloTransformStream::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloTransformStream*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_readable);
    visitor.append(this_object->m_writable);
    visitor.append(this_object->m_controller);
    visitor.append(this_object->m_transformer);
    visitor.append(this_object->m_transform);
    visitor.append(this_object->m_flush);
    visitor.append(this_object->m_cancel);
    visitor.append(this_object->m_pending_write_chunk);
    visitor.append(this_object->m_pending_write_promise);
    visitor.append(this_object->m_native_promise);
    this_object->m_native_transformer.visit(this_object, visitor);
    visitor.reportExtraMemoryVisited(this_object->m_native_memory_cost.load(std::memory_order_relaxed));
}

template <typename Visitor>
void JSColloTransformStreamDefaultController::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloTransformStreamDefaultController*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_stream);
}

DEFINE_VISIT_CHILDREN(JSColloTransformStream);
DEFINE_VISIT_CHILDREN(JSColloTransformStreamDefaultController);

} // namespace Collo::HostFunctions
