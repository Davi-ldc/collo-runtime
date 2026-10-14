// The WritableStream state machine (Streams, "Writable streams"): queueing writes, calling the sink, closing, aborting
// and erroring, and the writer's ready and closed promises. Runs on the VM thread.
//
// The sink starts through a promise even when its start returns synchronously, so the first write reaches the sink a
// microtask after construction at the earliest. The sink's write, close and abort complete the same way: what the
// method returned or threw becomes a promise (promiseForCallbackCompletion), and the step finishes in that promise's
// reaction. So a sink that finishes every write synchronously gets the next queued write from a new microtask, never
// from inside its own call, and the native stack stays flat however long the queue. processQueue starts a write or the
// close only after start has finished and while no write, close or abort is in flight, and it marks the write or close
// in flight before it calls the sink, so script the sink runs that writes through this stream queues behind it.
// write() runs the strategy's size callback before it reads the state, as WritableStreamDefaultWriterWrite does; the
// callback goes with the sink's other algorithms once the close reaches the sink. abort() does not wait: it rejects
// the active write and calls the sink's abort even while the sink's start or write promise is pending. The stream is
// Errored before the sink's abort runs, as WritableStreamFinishErroring leaves it, and once start has settled a later
// abort() resolves at once.
// finishErroring settles the abort request and the closed promise of whichever writer holds the stream then. A
// JavaScript sink's methods run with the underlying sink as this; a TransformStream sink's are its C++ sink algorithms.
//
// Every promise is settled through Collo::settlePromise. A false result means a termination is pending, and the caller
// returns at once without calling the sink or settling anything else.

#include "host_functions/webapi/streams/transform_stream_private.h"

namespace Collo::HostFunctions {

JSColloWritableStreamDefaultController* JSColloWritableStreamDefaultController::create(
    JSC::VM& vm, JSC::JSGlobalObject* global_object, JSColloWritableStream* stream)
{
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto* object = new (NotNull, JSC::allocateCell<JSColloWritableStreamDefaultController>(vm))
        JSColloWritableStreamDefaultController(vm, collo_global->writableStreamDefaultControllerStructure());
    object->finishCreation(vm, stream);
    return object;
}

void JSColloWritableStreamDefaultController::setTransformSink(JSC::VM& vm, JSColloTransformStream* transform)
{
    m_sink_kind = SinkKind::Transform;
    m_sink.set(vm, this, transform);
}

JSColloWritableStream* JSColloWritableStream::create(
    JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::Structure* structure)
{
    auto* object = new (NotNull, JSC::allocateCell<JSColloWritableStream>(vm)) JSColloWritableStream(vm, structure);
    object->finishCreation(vm);
    // The stream is finished before its controller is allocated, so a collection that allocation triggers finds a
    // complete cell, which the stack roots.
    object->m_controller.set(vm, object, JSColloWritableStreamDefaultController::create(vm, global_object, object));
    return object;
}

void JSColloWritableStream::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
}

JSColloWritableStreamDefaultWriter* JSColloWritableStreamDefaultWriter::create(
    JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::ThrowScope&, JSColloWritableStream* stream)
{
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto* object = new (NotNull, JSC::allocateCell<JSColloWritableStreamDefaultWriter>(vm))
        JSColloWritableStreamDefaultWriter(vm, collo_global->writableStreamDefaultWriterStructure());
    if (!object->finishCreation(vm, global_object, stream))
        return nullptr;
    stream->lock(vm, object);
    return object;
}

// SetUpWritableStreamDefaultWriter.
bool JSColloWritableStreamDefaultWriter::finishCreation(
    JSC::VM& vm, JSC::JSGlobalObject* global_object, JSColloWritableStream* stream)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
    m_stream.set(vm, this, stream);
    m_ready_promise.set(vm, this, Collo::newPromise(global_object));
    m_closed_promise.set(vm, this, Collo::newPromise(global_object));

    JSC::JSValue stored_error = stream->storedError();
    if (!stored_error)
        stored_error = JSC::jsUndefined();
    switch (stream->state()) {
    case WritableState::Writable:
        // Ready stays pending only under backpressure with no close queued.
        if (stream->closeRequested() || stream->desiredSize() > 0)
            return settleReady(global_object, JSC::jsUndefined(), false);
        return true;
    case WritableState::Erroring:
        // Closed stays pending until finishErroring rejects it.
        return settleReady(global_object, stored_error, true);
    case WritableState::Closed:
        return settleReady(global_object, JSC::jsUndefined(), false) && settleClosed(JSC::jsUndefined(), false);
    case WritableState::Errored:
        return settleReady(global_object, stored_error, true) && settleClosed(stored_error, true);
    }
    return true;
}

void JSColloWritableStreamDefaultWriter::ensureReadyPending(JSC::JSGlobalObject* global_object)
{
    if (promiseIsPending(m_ready_promise.get()))
        return;
    m_ready_promise.set(global_object->vm(), this, Collo::newPromise(global_object));
}

void JSColloWritableStreamDefaultWriter::resolveReadyIfNeeded(
    JSC::JSGlobalObject* global_object, JSColloWritableStream* stream)
{
    if (stream->state() != WritableState::Writable || stream->desiredSize() <= 0)
        return;
    settleReady(global_object, JSC::jsUndefined(), false);
}

// Every rejection of ready goes through WritableStreamDefaultWriterEnsureReadyPromiseRejected, which replaces a settled
// promise and marks the result handled.
bool JSColloWritableStreamDefaultWriter::settleReady(
    JSC::JSGlobalObject* global_object, JSC::JSValue value, bool is_rejection)
{
    if (is_rejection)
        return ensurePromiseRejected(global_object, this, m_ready_promise, value);
    return Collo::settlePromise(m_ready_promise.get(), value, false);
}

// Every rejection of closed is marked handled (WritableStreamRejectCloseAndClosedPromiseIfNeeded); a closed promise
// that already settled stays as it is.
bool JSColloWritableStreamDefaultWriter::settleClosed(JSC::JSValue value, bool is_rejection)
{
    auto* promise = m_closed_promise.get();
    if (is_rejection && promiseIsPending(promise))
        promise->markAsHandled();
    return Collo::settlePromise(promise, value, is_rejection);
}

void JSColloWritableStreamDefaultWriter::release(JSC::JSGlobalObject* global_object)
{
    auto* current_stream = stream();
    if (!current_stream)
        return;
    if (current_stream->writer() == this)
        current_stream->unlock();
    m_stream.clear();
    auto* error = JSC::createTypeError(global_object, "WritableStreamDefaultWriter lock was released"_s);
    if (!ensurePromiseRejected(global_object, this, m_ready_promise, error))
        return;
    ensurePromiseRejected(global_object, this, m_closed_promise, error);
}

void JSColloWritableStream::resolveReadyIfNeeded(JSC::JSGlobalObject* global_object)
{
    if (auto* current_writer = writer())
        current_writer->resolveReadyIfNeeded(global_object, this);
}

bool JSColloWritableStream::settleClosed(JSC::JSGlobalObject* global_object, JSC::JSValue value, bool is_rejection)
{
    if (auto* current_writer = writer())
        return current_writer->settleClosed(value, is_rejection);
    return noExceptionPending(global_object->vm());
}

void JSColloWritableStream::activateFirstWrite(JSC::VM& vm)
{
    auto request = m_write_queue.takeFirst(this);
    m_active_write.value.set(vm, this, request.value.get());
    m_active_write.promise.set(vm, this, request.promise.get());
    m_active_write.size = request.size;
    m_has_active_write = true;
}

bool JSColloWritableStream::settleActiveWrite(JSC::JSGlobalObject* global_object, JSC::JSValue value, bool is_rejection)
{
    m_has_active_write = false;
    m_write_in_flight = false;
    subtractQueueSize(m_active_write.size);
    m_active_write.size = 0;
    m_active_write.value.clear();
    return settleAndClearPromise(global_object, m_active_write.promise, value, is_rejection);
}

bool JSColloWritableStream::clearWriteQueue(JSC::JSGlobalObject* global_object, JSC::JSValue error)
{
    if (m_has_active_write && !settleActiveWrite(global_object, error, true))
        return false;
    while (!m_write_queue.isEmpty()) {
        auto request = m_write_queue.takeFirst(this);
        subtractQueueSize(request.size);
        if (!Collo::settlePromise(request.promise.get(), error, true))
            return false;
    }
    m_queue_total_size = 0;
    return true;
}

void JSColloWritableStream::startWith(JSC::JSGlobalObject* global_object, JSC::JSPromise* start_promise)
{
    m_starting = true;
    reactToPromise(global_object, start_promise, StreamReaction::WritableStart, this);
}

void JSColloWritableStream::finishStart(JSC::JSGlobalObject* global_object)
{
    m_starting = false;
    processQueue(global_object);
}

void JSColloWritableStream::startFailed(JSC::JSGlobalObject* global_object, JSC::JSValue reason)
{
    m_starting = false;
    error(global_object, reason);
}

// WritableStreamStartErroring and WritableStreamFinishErroring in one step, for every caller but abort(); the FIXME in
// abort() describes the wait this skips.
void JSColloWritableStream::error(JSC::JSGlobalObject* global_object, JSC::JSValue error)
{
    if (m_state != WritableState::Writable)
        return;
    m_state = WritableState::Errored;
    m_stored_error.set(global_object->vm(), this, error);
    clearAlgorithms();
    m_close_requested = false;
    m_close_in_flight = false;
    if (!clearWriteQueue(global_object, error))
        return;
    if (auto* current_writer = writer(); current_writer && !current_writer->settleReady(global_object, error, true))
        return;
    if (!settleAndClearPromise(global_object, m_close_promise, error, true))
        return;
    if (!settleAndClearPromise(global_object, m_abort_promise, JSC::jsUndefined(), false))
        return;
    settleClosed(global_object, error, true);
}

void JSColloWritableStream::finishWrite(JSC::JSGlobalObject* global_object)
{
    if (!m_has_active_write)
        return;
    if (!settleActiveWrite(global_object, JSC::jsUndefined(), false))
        return;
    resolveReadyIfNeeded(global_object);
    if (!noExceptionPending(global_object->vm()))
        return;
    processQueue(global_object);
}

void JSColloWritableStream::rejectWrite(JSC::JSGlobalObject* global_object, JSC::JSValue reason)
{
    error(global_object, reason);
}

void JSColloWritableStream::finishClose(JSC::JSGlobalObject* global_object)
{
    m_close_in_flight = false;
    if (m_state != WritableState::Writable || !m_close_requested)
        return;
    m_state = WritableState::Closed;
    m_close_requested = false;
    if (!settleAndClearPromise(global_object, m_close_promise, JSC::jsUndefined(), false))
        return;
    settleClosed(global_object, JSC::jsUndefined(), false);
}

void JSColloWritableStream::rejectClose(JSC::JSGlobalObject* global_object, JSC::JSValue reason)
{
    m_close_in_flight = false;
    if (m_state != WritableState::Writable || !m_close_requested)
        return;
    error(global_object, reason);
}

void JSColloWritableStream::finishAbort(JSC::JSGlobalObject* global_object)
{
    m_abort_in_flight = false;
    finishErroring(global_object, JSC::jsUndefined(), false);
}

void JSColloWritableStream::rejectAbort(JSC::JSGlobalObject* global_object, JSC::JSValue error)
{
    m_abort_in_flight = false;
    finishErroring(global_object, error, true);
}

void JSColloWritableStream::finishErroring(JSC::JSGlobalObject* global_object, JSC::JSValue value, bool is_rejection)
{
    m_state = WritableState::Errored;
    if (!settleAndClearPromise(global_object, m_abort_promise, value, is_rejection))
        return;
    JSC::JSValue stored_error = storedError();
    settleClosed(global_object, stored_error ? stored_error : JSC::jsUndefined(), true);
}

void JSColloWritableStream::processQueue(JSC::JSGlobalObject* global_object)
{
    if (m_state != WritableState::Writable)
        return;
    if (m_starting || m_write_in_flight || m_close_in_flight || m_abort_in_flight)
        return;
    if (!m_has_active_write && !m_write_queue.isEmpty())
        activateFirstWrite(global_object->vm());
    if (m_has_active_write) {
        writeToSink(global_object);
        return;
    }
    if (m_close_requested)
        closeSink(global_object);
}

void JSColloWritableStream::writeToSink(JSC::JSGlobalObject* global_object)
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* current_controller = controller();
    JSC::JSValue chunk = m_active_write.value.get();
    JSC::JSValue result = JSC::jsUndefined();
    m_write_in_flight = true;
    if (current_controller
        && current_controller->sinkKind() == JSColloWritableStreamDefaultController::SinkKind::Transform) {
        if (auto* transform = dynamicDowncast<JSColloTransformStream>(current_controller->sink()))
            result = JSC::JSValue::decode(transform->sinkWrite(global_object, scope, chunk));
    } else {
        JSC::JSValue write_callback = current_controller ? current_controller->writeCallback() : JSC::jsUndefined();
        if (valueIsCallable(write_callback)) {
            JSC::MarkedArgumentBuffer arguments;
            arguments.append(chunk);
            arguments.append(current_controller);
            if (arguments.hasOverflowed()) {
                JSC::throwOutOfMemoryError(global_object, scope);
            } else {
                auto call_data = JSC::getCallData(write_callback);
                result = JSC::call(
                    global_object, write_callback.getObject(), call_data, current_controller->sink(), arguments);
            }
        }
    }
    // Finishing a synchronous write here would start the next queued write from inside this call, one native frame
    // per queued write, so it too finishes in the reaction.
    auto* promise = promiseForCallbackCompletion(global_object, scope, result);
    if (!promise)
        return;
    reactToPromise(global_object, promise, StreamReaction::WritableWrite, this);
}

void JSColloWritableStream::closeSink(JSC::JSGlobalObject* global_object)
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* current_controller = controller();
    JSC::JSValue result = JSC::jsUndefined();
    m_close_in_flight = true;
    if (current_controller
        && current_controller->sinkKind() == JSColloWritableStreamDefaultController::SinkKind::Transform) {
        if (auto* transform = dynamicDowncast<JSColloTransformStream>(current_controller->sink()))
            result = JSC::JSValue::decode(transform->sinkClose(global_object, scope));
    } else {
        JSC::JSValue close_callback = current_controller ? current_controller->closeCallback() : JSC::jsUndefined();
        if (valueIsCallable(close_callback)) {
            JSC::MarkedArgumentBuffer arguments;
            auto call_data = JSC::getCallData(close_callback);
            result = JSC::call(
                global_object, close_callback.getObject(), call_data, current_controller->sink(), arguments);
        }
    }
    auto* promise = promiseForCallbackCompletion(global_object, scope, result);
    // WritableStreamDefaultControllerProcessClose drops the sink's algorithms once its close has returned: the stream
    // calls the sink no more, a later write() asks no size callback, and a later abort() reaches no sink.
    clearAlgorithms();
    if (!promise)
        return;
    reactToPromise(global_object, promise, StreamReaction::WritableClose, this);
}

bool JSColloWritableStream::chunkSize(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue chunk, double& out_size)
{
    out_size = 1;
    auto* current_controller = controller();
    JSC::JSValue size_callback = current_controller ? current_controller->sizeCallback() : JSC::jsUndefined();
    if (!valueIsCallable(size_callback))
        return true;
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(chunk);
    if (arguments.hasOverflowed()) {
        JSC::throwOutOfMemoryError(global_object, scope);
    } else {
        auto call_data = JSC::getCallData(size_callback);
        JSC::JSValue size
            = JSC::call(global_object, size_callback.getObject(), call_data, JSC::jsUndefined(), arguments);
        // The callback returns unrestricted double, so converting its result belongs to the call.
        if (!scope.exception()) {
            const double number = size.toNumber(global_object);
            if (!scope.exception())
                out_size = number;
        }
    }
    auto* exception = scope.exception();
    if (!exception)
        return true;
    JSC::JSValue size_error = exception->value();
    if (!scope.tryClearException())
        return false;
    error(global_object, size_error);
    RETURN_IF_EXCEPTION(scope, false);
    return true;
}

JSC::EncodedJSValue JSColloWritableStream::write(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSColloWritableStreamDefaultWriter* writer, JSC::JSValue chunk)
{
    // WritableStreamDefaultWriterWrite asks for the chunk's size before it reads the state, so the size callback runs,
    // and may error the stream, even while a close is queued. It is script and may also release the writer or close,
    // abort or error the stream, so every check follows it.
    double size = 1;
    if (!chunkSize(global_object, scope, chunk, size))
        return {};
    if (writer && writer->stream() != this)
        return rejectedTypeError(global_object, scope, "WritableStreamDefaultWriter has been released"_s);
    if (m_state == WritableState::Errored)
        return rejectedPromise(global_object, scope, storedError());
    if (m_state == WritableState::Closed)
        return rejectedTypeError(global_object, scope, "WritableStream is closed"_s);
    if (m_close_requested)
        return rejectedTypeError(global_object, scope, "WritableStream is closing"_s);
    if (m_state == WritableState::Erroring)
        return rejectedPromise(global_object, scope, storedError());
    // EnqueueValueWithSize refuses a size that is not a finite non-negative number by erroring the stream, which
    // rejects this write with the same RangeError.
    if (!std::isfinite(size) || size < 0) {
        auto* size_error
            = JSC::createRangeError(global_object, "WritableStream chunk size must be a finite non-negative number"_s);
        error(global_object, size_error);
        RETURN_IF_EXCEPTION(scope, {});
        return rejectedPromise(global_object, scope, size_error);
    }

    // Reserving first leaves nothing after the promise exists that can fail.
    if (!m_write_queue.tryReserveAdditional(this, 1)) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return {};
    }
    if (m_high_water_mark - (m_queue_total_size + size) <= 0) {
        if (auto* current_writer = this->writer())
            current_writer->ensureReadyPending(global_object);
    }
    auto* promise = Collo::newPromise(global_object);
    WriteRequest request;
    request.value.setWithoutWriteBarrier(chunk);
    request.promise.setWithoutWriteBarrier(promise);
    request.size = size;
    if (!m_write_queue.tryAppend(global_object->vm(), this, WTF::move(request))) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return {};
    }
    m_queue_total_size += size;
    processQueue(global_object);
    RETURN_IF_EXCEPTION(scope, {});
    return JSC::JSValue::encode(promise);
}

JSC::EncodedJSValue JSColloWritableStream::close(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    // WritableStreamClose: closing a closed or errored stream rejects with a TypeError, not the stored error.
    if (m_state == WritableState::Closed)
        return rejectedTypeError(global_object, scope, "WritableStream is already closed"_s);
    if (m_state == WritableState::Errored || m_state == WritableState::Erroring)
        return rejectedTypeError(global_object, scope, "WritableStream is errored"_s);
    if (m_close_requested)
        return rejectedTypeError(global_object, scope, "WritableStream is already closing"_s);

    auto* promise = Collo::newPromise(global_object);
    m_close_promise.set(global_object->vm(), this, promise);
    m_close_requested = true;
    // A writer waiting out backpressure is ready once the close is queued.
    if (auto* current_writer = writer(); current_writer && desiredSize() <= 0) {
        if (!current_writer->settleReady(global_object, JSC::jsUndefined(), false))
            return {};
    }
    processQueue(global_object);
    RETURN_IF_EXCEPTION(scope, {});
    return JSC::JSValue::encode(promise);
}

JSC::EncodedJSValue JSColloWritableStream::abort(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue reason)
{
    // WritableStreamAbort: a pending abort request answers every later abort with its own promise, and aborting a
    // closed or errored stream resolves with undefined. The standard keeps the request pending until
    // WritableStreamFinishErroring clears it, which waits for start to settle (the FIXME below). So here the request
    // stays pending until start settles, and from then on a later abort resolves at once even while the request's
    // promise still waits for the sink's abort.
    if (auto* pending = m_abort_promise.get(); pending && (m_starting || m_state == WritableState::Erroring))
        return JSC::JSValue::encode(pending);
    if (m_state != WritableState::Writable)
        return resolvedPromise(global_object, JSC::jsUndefined());

    auto& vm = global_object->vm();
    auto* promise = Collo::newPromise(global_object);
    m_abort_promise.set(vm, this, promise);
    m_state = WritableState::Erroring;
    m_stored_error.set(vm, this, reason);
    if (!clearWriteQueue(global_object, reason))
        return {};
    if (auto* current_writer = writer(); current_writer && !current_writer->settleReady(global_object, reason, true))
        return {};
    m_close_requested = false;
    m_close_in_flight = false;
    if (!settleAndClearPromise(global_object, m_close_promise, reason, true))
        return {};
    if (!settleClosed(global_object, reason, true))
        return {};

    // FIXME: WritableStreamStartErroring keeps the stream Erroring until start has finished and no write or close is in
    // flight; only then does WritableStreamFinishErroring make it Errored and call the sink's abort. So an in-flight
    // write or close still settles with the sink's result, and a queued close and the closed promise reject only once
    // the abort settles. Every caller of StartErroring skips that wait here: abort(), and error() for a rejected sink
    // start, write or close, WritableStreamDefaultController.error(), a size callback that throws or returns an
    // invalid size, and a TransformStream that errors its writable side. Each rejects the active write, a queued close
    // and the closed promise at once, and abort() calls the sink's abort even while the sink is still starting or
    // writing.
    //
    // The sink's abort is the last thing the stream calls on it, so the controller drops the sink's algorithms first,
    // and the stream is Errored while it runs.
    auto* current_controller = controller();
    const bool transform_sink = current_controller
        && current_controller->sinkKind() == JSColloWritableStreamDefaultController::SinkKind::Transform;
    JSC::JSValue sink = current_controller ? current_controller->sink() : JSC::jsUndefined();
    JSC::JSValue abort_callback = current_controller ? current_controller->abortCallback() : JSC::jsUndefined();
    clearAlgorithms();
    m_state = WritableState::Errored;
    JSC::JSValue result = JSC::jsUndefined();
    if (transform_sink) {
        if (auto* transform = dynamicDowncast<JSColloTransformStream>(sink))
            result = JSC::JSValue::decode(transform->sinkAbort(global_object, scope, reason));
    } else if (valueIsCallable(abort_callback)) {
        JSC::MarkedArgumentBuffer arguments;
        arguments.append(reason);
        if (arguments.hasOverflowed()) {
            JSC::throwOutOfMemoryError(global_object, scope);
        } else {
            auto call_data = JSC::getCallData(abort_callback);
            result = JSC::call(global_object, abort_callback.getObject(), call_data, sink, arguments);
        }
    }
    auto* sink_promise = promiseForCallbackCompletion(global_object, scope, result);
    if (!sink_promise)
        return {};
    m_abort_in_flight = true;
    reactToPromise(global_object, sink_promise, StreamReaction::WritableAbort, this);
    return JSC::JSValue::encode(promise);
}

JSColloWritableStream* requireWritableStream(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value)
{
    return requireStreamCell<JSColloWritableStream>(global_object, scope, value, "WritableStream"_s);
}

} // namespace Collo::HostFunctions
