// The WritableStream state machine (Streams, "Writable streams"): queueing
// writes, calling the sink, closing, aborting and erroring, and the writer's
// ready and closed promises. Runs on the VM thread.
//
// processQueue starts a write or the close only after start has finished and
// while no write, close or abort is in flight, and it marks the write or close
// in flight before it calls the sink, so script the sink runs that writes
// through this stream queues behind it. abort() does not wait: it rejects the
// active write and calls the sink's abort method even while the sink's start,
// write or close promise is pending. Erroring lasts only for the synchronous
// part of abort(): the stream is Errored once the sink's abort method returns.
// finishErroring settles the abort request and the closed promise of whichever
// writer holds the stream then. The sink's start, write, close and abort run
// with the underlying sink as this.
//
// Every promise is settled through Collo::settlePromise. A false result means a
// termination is pending, and the caller returns at once without calling the
// sink or settling anything else; the termination ends the request, whose
// cleanup releases what the stream still holds.
#include "host_functions/webapi/streams/writable_stream_private.h"

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

JSColloWritableStream* JSColloWritableStream::create(JSC::VM& vm, Collo::GlobalObject* global_object)
{
    return createWithStructure(vm, global_object, global_object->writableStreamStructure());
}

JSColloWritableStream* JSColloWritableStream::createWithStructure(
    JSC::VM& vm, Collo::GlobalObject*, JSC::Structure* structure)
{
    auto* object = new (NotNull, JSC::allocateCell<JSColloWritableStream>(vm)) JSColloWritableStream(vm, structure);
    object->finishCreation(vm);
    return object;
}

void JSColloWritableStream::finishCreation(JSC::VM& vm)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
    m_queue_memory_limit_exceeded.set(vm, this, JSC::jsUndefined());
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

    JSValue stored_error = stream->storedError();
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
        return settleReady(global_object, JSC::jsUndefined(), false)
            && settleClosed(global_object, JSC::jsUndefined(), false);
    case WritableState::Errored:
        return settleReady(global_object, stored_error, true) && settleClosed(global_object, stored_error, true);
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
    if (stream->state() != WritableState::Writable)
        return;
    if (stream->desiredSize() <= 0)
        return;
    settleReady(global_object, JSC::jsUndefined(), false);
}

// Every rejection of ready goes through WritableStreamDefaultWriterEnsureReadyPromiseRejected, which replaces a
// settled promise and marks the result handled.
bool JSColloWritableStreamDefaultWriter::settleReady(
    JSC::JSGlobalObject* global_object, JSValue value, bool is_rejection)
{
    if (is_rejection)
        return ensurePromiseRejected(global_object, this, m_ready_promise, value);
    return Collo::settlePromise(m_ready_promise.get(), value, false);
}

// Every rejection of closed is marked handled (WritableStreamRejectCloseAndClosedPromiseIfNeeded); a closed promise
// that already settled stays as it is.
bool JSColloWritableStreamDefaultWriter::settleClosed(
    JSC::JSGlobalObject*, JSValue value, bool is_rejection)
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

bool JSColloWritableStream::settleClosed(JSC::JSGlobalObject* global_object, JSValue value, bool is_rejection)
{
    if (auto* current_writer = writer())
        return current_writer->settleClosed(global_object, value, is_rejection);
    return noExceptionPending(global_object->vm());
}

bool JSColloWritableStream::queueMemoryCostWouldExceed(size_t memory_cost) const
{
    if (!m_queue_memory_cost_limit)
        return false;
    if (m_queue_memory_cost >= m_queue_memory_cost_limit)
        return memory_cost > 0;
    return memory_cost > m_queue_memory_cost_limit - m_queue_memory_cost;
}

bool JSColloWritableStream::queuePendingCountWouldExceed() const
{
    if (!m_write_queue_pending_limit)
        return false;
    return m_write_queue.size() >= m_write_queue_pending_limit;
}

void JSColloWritableStream::subtractQueueSize(double size, size_t memory_cost)
{
    m_queue_total_size = m_queue_total_size > size ? m_queue_total_size - size : 0;
    m_queue_memory_cost = m_queue_memory_cost > memory_cost ? m_queue_memory_cost - memory_cost : 0;
}

bool JSColloWritableStream::notifyQueueMemoryLimitExceeded(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue reason)
{
    JSValue callback = m_queue_memory_limit_exceeded.get();
    if (!valueIsCallable(callback)) {
        error(global_object, reason);
        return !scope.exception();
    }

    JSC::MarkedArgumentBuffer arguments;
    arguments.append(reason);
    if (arguments.hasOverflowed()) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }

    auto call_data = JSC::getCallData(callback);
    JSC::call(global_object, callback.getObject(), call_data, JSC::jsUndefined(), arguments);
    return !scope.exception();
}

void JSColloWritableStream::activateFirstWrite(JSC::VM& vm)
{
    auto request = m_write_queue.takeFirst(this);
    m_active_write.value.set(vm, this, request.value.get());
    m_active_write.promise.set(vm, this, request.promise.get());
    m_active_write.size = request.size;
    m_active_write.memory_cost = request.memory_cost;
    m_has_active_write = true;
}

bool JSColloWritableStream::settleActiveWrite(JSC::JSGlobalObject* global_object, JSValue value, bool is_rejection)
{
    m_has_active_write = false;
    m_write_in_flight = false;
    subtractQueueSize(m_active_write.size, m_active_write.memory_cost);
    m_active_write.size = 0;
    m_active_write.memory_cost = 0;
    m_active_write.value.clear();
    return settleAndClearPromise(global_object, m_active_write.promise, value, is_rejection);
}

bool JSColloWritableStream::clearWriteQueue(JSC::JSGlobalObject* global_object, JSValue error)
{
    if (m_has_active_write && !settleActiveWrite(global_object, error, true))
        return false;
    while (!m_write_queue.isEmpty()) {
        auto request = m_write_queue.takeFirst(this);
        subtractQueueSize(request.size, request.memory_cost);
        if (!Collo::settlePromise(request.promise.get(), error, true))
            return false;
    }
    m_queue_total_size = 0;
    m_queue_memory_cost = 0;
    return true;
}

void JSColloWritableStream::finishStart(JSC::JSGlobalObject* global_object)
{
    m_starting = false;
    processQueue(global_object);
}

void JSColloWritableStream::error(JSC::JSGlobalObject* global_object, JSValue error)
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

void JSColloWritableStream::rejectWrite(JSC::JSGlobalObject* global_object, JSValue reason)
{
    this->error(global_object, reason);
}

void JSColloWritableStream::finishClose(JSC::JSGlobalObject* global_object)
{
    m_close_in_flight = false;
    if (m_state != WritableState::Writable || !m_close_requested)
        return;
    m_state = WritableState::Closed;
    clearAlgorithms();
    m_close_requested = false;
    if (!settleAndClearPromise(global_object, m_close_promise, JSC::jsUndefined(), false))
        return;
    settleClosed(global_object, JSC::jsUndefined(), false);
}

void JSColloWritableStream::rejectClose(JSC::JSGlobalObject* global_object, JSValue reason)
{
    m_close_in_flight = false;
    if (m_state != WritableState::Writable || !m_close_requested)
        return;
    this->error(global_object, reason);
}

void JSColloWritableStream::finishAbort(JSC::JSGlobalObject* global_object)
{
    m_abort_in_flight = false;
    finishErroring(global_object, JSC::jsUndefined(), false);
}

void JSColloWritableStream::rejectAbort(JSC::JSGlobalObject* global_object, JSValue error)
{
    m_abort_in_flight = false;
    finishErroring(global_object, error, true);
}

void JSColloWritableStream::finishErroring(JSC::JSGlobalObject* global_object, JSValue value, bool is_rejection)
{
    m_state = WritableState::Errored;
    if (!settleAndClearPromise(global_object, m_abort_promise, value, is_rejection))
        return;
    JSValue stored_error = storedError();
    settleClosed(global_object, stored_error ? stored_error : JSC::jsUndefined(), true);
}

JSC_DEFINE_HOST_FUNCTION(writableStartFulfilled, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* function = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee());
    JSValue controller_value = function->get(global_object, writableStreamControllerIdentifier(global_object));
    RETURN_IF_EXCEPTION(scope, {});
    auto* controller = requireWritableStreamDefaultController(global_object, scope, controller_value);
    RETURN_IF_EXCEPTION(scope, {});
    if (auto* stream = controller->stream())
        stream->finishStart(global_object);
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(writableStartRejected, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* function = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee());
    JSValue controller_value = function->get(global_object, writableStreamControllerIdentifier(global_object));
    RETURN_IF_EXCEPTION(scope, {});
    auto* controller = requireWritableStreamDefaultController(global_object, scope, controller_value);
    RETURN_IF_EXCEPTION(scope, {});
    if (auto* stream = controller->stream())
        stream->error(global_object, call_frame->argument(0));
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(JSC::jsUndefined());
}

JSC::JSFunction* JSColloWritableStreamDefaultController::startFulfilledFunction(JSC::JSGlobalObject* global_object)
{
    return cachedThenCallback(global_object, m_start_fulfilled, this, "WritableStream start fulfilled"_s,
        writableStartFulfilled, writableStreamControllerIdentifier(global_object), this);
}

JSC::JSFunction* JSColloWritableStreamDefaultController::startRejectedFunction(JSC::JSGlobalObject* global_object)
{
    return cachedThenCallback(global_object, m_start_rejected, this, "WritableStream start rejected"_s,
        writableStartRejected, writableStreamControllerIdentifier(global_object), this);
}

void JSColloWritableStream::start(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue start_callback)
{
    auto* current_controller = controller();
    if (!current_controller)
        return;
    if (!valueIsCallable(start_callback)) {
        processQueue(global_object);
        return;
    }
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(current_controller);
    if (arguments.hasOverflowed()) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return;
    }
    auto call_data = JSC::getCallData(start_callback);
    JSValue result = JSC::call(
        global_object, start_callback.getObject(), call_data, current_controller->underlyingSink(), arguments);
    if (scope.exception())
        return;
    if (auto* promise = dynamicDowncast<JSC::JSPromise>(result)) {
        m_starting = true;
        promise->performPromiseThen(global_object->vm(), global_object,
            current_controller->startFulfilledFunction(global_object),
            current_controller->startRejectedFunction(global_object), JSC::jsUndefined());
        return;
    }
    processQueue(global_object);
}

JSC_DEFINE_HOST_FUNCTION(writableWriteFulfilled, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* function = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee());
    JSValue stream_value = function->get(global_object, writableStreamIdentifier(global_object));
    RETURN_IF_EXCEPTION(scope, {});
    auto* stream = requireWritableStream(global_object, scope, stream_value);
    RETURN_IF_EXCEPTION(scope, {});
    stream->finishWrite(global_object);
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(writableWriteRejected, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* function = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee());
    JSValue stream_value = function->get(global_object, writableStreamIdentifier(global_object));
    RETURN_IF_EXCEPTION(scope, {});
    auto* stream = requireWritableStream(global_object, scope, stream_value);
    RETURN_IF_EXCEPTION(scope, {});
    stream->rejectWrite(global_object, call_frame->argument(0));
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(writableCloseFulfilled, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* function = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee());
    JSValue stream_value = function->get(global_object, writableStreamIdentifier(global_object));
    RETURN_IF_EXCEPTION(scope, {});
    auto* stream = requireWritableStream(global_object, scope, stream_value);
    RETURN_IF_EXCEPTION(scope, {});
    stream->finishClose(global_object);
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(writableCloseRejected, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* function = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee());
    JSValue stream_value = function->get(global_object, writableStreamIdentifier(global_object));
    RETURN_IF_EXCEPTION(scope, {});
    auto* stream = requireWritableStream(global_object, scope, stream_value);
    RETURN_IF_EXCEPTION(scope, {});
    stream->rejectClose(global_object, call_frame->argument(0));
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(writableAbortFulfilled, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* function = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee());
    JSValue stream_value = function->get(global_object, writableStreamIdentifier(global_object));
    RETURN_IF_EXCEPTION(scope, {});
    auto* stream = requireWritableStream(global_object, scope, stream_value);
    RETURN_IF_EXCEPTION(scope, {});
    stream->finishAbort(global_object);
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(writableAbortRejected, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* function = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee());
    JSValue stream_value = function->get(global_object, writableStreamIdentifier(global_object));
    RETURN_IF_EXCEPTION(scope, {});
    auto* stream = requireWritableStream(global_object, scope, stream_value);
    RETURN_IF_EXCEPTION(scope, {});
    stream->rejectAbort(global_object, call_frame->argument(0));
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(JSC::jsUndefined());
}

JSC::JSFunction* JSColloWritableStream::writeFulfilledFunction(JSC::JSGlobalObject* global_object)
{
    return cachedThenCallback(global_object, m_write_fulfilled, this, "WritableStream write fulfilled"_s,
        writableWriteFulfilled, writableStreamIdentifier(global_object), this);
}

JSC::JSFunction* JSColloWritableStream::writeRejectedFunction(JSC::JSGlobalObject* global_object)
{
    return cachedThenCallback(global_object, m_write_rejected, this, "WritableStream write rejected"_s,
        writableWriteRejected, writableStreamIdentifier(global_object), this);
}

JSC::JSFunction* JSColloWritableStream::closeFulfilledFunction(JSC::JSGlobalObject* global_object)
{
    return cachedThenCallback(global_object, m_close_fulfilled, this, "WritableStream close fulfilled"_s,
        writableCloseFulfilled, writableStreamIdentifier(global_object), this);
}

JSC::JSFunction* JSColloWritableStream::closeRejectedFunction(JSC::JSGlobalObject* global_object)
{
    return cachedThenCallback(global_object, m_close_rejected, this, "WritableStream close rejected"_s,
        writableCloseRejected, writableStreamIdentifier(global_object), this);
}

JSC::JSFunction* JSColloWritableStream::abortFulfilledFunction(JSC::JSGlobalObject* global_object)
{
    return cachedThenCallback(global_object, m_abort_fulfilled, this, "WritableStream abort fulfilled"_s,
        writableAbortFulfilled, writableStreamIdentifier(global_object), this);
}

JSC::JSFunction* JSColloWritableStream::abortRejectedFunction(JSC::JSGlobalObject* global_object)
{
    return cachedThenCallback(global_object, m_abort_rejected, this, "WritableStream abort rejected"_s,
        writableAbortRejected, writableStreamIdentifier(global_object), this);
}

void JSColloWritableStream::processQueue(JSC::JSGlobalObject* global_object)
{
    if (m_state != WritableState::Writable)
        return;
    if (m_starting || m_write_in_flight || m_close_in_flight || m_abort_in_flight)
        return;

    auto& vm = global_object->vm();
    if (!m_has_active_write && !m_write_queue.isEmpty())
        activateFirstWrite(vm);

    if (m_has_active_write) {
        auto* current_controller = controller();
        JSValue write_callback = current_controller ? current_controller->writeCallback() : JSC::jsUndefined();
        if (!valueIsCallable(write_callback)) {
            finishWrite(global_object);
            return;
        }
        auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
        JSC::MarkedArgumentBuffer arguments;
        arguments.append(m_active_write.value.get());
        arguments.append(current_controller);
        if (arguments.hasOverflowed()) {
            rejectWrite(global_object, JSC::createOutOfMemoryError(global_object));
            return;
        }
        m_write_in_flight = true;
        auto call_data = JSC::getCallData(write_callback);
        JSValue result = JSC::call(
            global_object, write_callback.getObject(), call_data, current_controller->underlyingSink(), arguments);
        if (scope.exception()) {
            JSValue exception = scope.exception()->value();
            if (!scope.clearExceptionExceptTermination())
                return;
            rejectWrite(global_object, exception);
            return;
        }
        if (auto* promise = dynamicDowncast<JSC::JSPromise>(result)) {
            promise->performPromiseThen(vm, global_object, writeFulfilledFunction(global_object),
                writeRejectedFunction(global_object), JSC::jsUndefined());
            if (scope.exception()) {
                JSValue exception = scope.exception()->value();
                if (!scope.clearExceptionExceptTermination())
                    return;
                rejectWrite(global_object, exception);
            }
            return;
        }
        finishWrite(global_object);
        return;
    }

    if (!m_close_requested)
        return;
    auto* current_controller = controller();
    JSValue close_callback = current_controller ? current_controller->closeCallback() : JSC::jsUndefined();
    if (!valueIsCallable(close_callback)) {
        finishClose(global_object);
        return;
    }
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    m_close_in_flight = true;
    auto call_data = JSC::getCallData(close_callback);
    JSC::MarkedArgumentBuffer arguments;
    JSValue result = JSC::call(
        global_object, close_callback.getObject(), call_data, current_controller->underlyingSink(), arguments);
    if (scope.exception()) {
        JSValue exception = scope.exception()->value();
        if (!scope.clearExceptionExceptTermination())
            return;
        rejectClose(global_object, exception);
        return;
    }
    if (auto* promise = dynamicDowncast<JSC::JSPromise>(result)) {
        promise->performPromiseThen(vm, global_object, closeFulfilledFunction(global_object),
            closeRejectedFunction(global_object), JSC::jsUndefined());
        if (scope.exception()) {
            JSValue exception = scope.exception()->value();
            if (!scope.clearExceptionExceptTermination())
                return;
            rejectClose(global_object, exception);
        }
        return;
    }
    finishClose(global_object);
}

EncodedJSValue JSColloWritableStream::write(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSColloWritableStreamDefaultWriter* writer, JSValue chunk)
{
    if (m_state == WritableState::Closed)
        return rejectedTypeError(global_object, scope, "WritableStream is closed"_s);
    if (m_state == WritableState::Errored || m_state == WritableState::Erroring)
        return rejectedPromise(global_object, scope, storedError());
    if (m_close_requested)
        return rejectedTypeError(global_object, scope, "WritableStream is closing"_s);

    // WritableStreamDefaultControllerGetChunkSize: a size callback that throws
    // or returns an invalid size errors the stream, and the write is rejected
    // with the stored error below.
    double size = 1;
    if (auto* current_controller = controller()) {
        JSValue size_callback = current_controller->sizeCallback();
        if (valueIsCallable(size_callback)) {
            JSValue size_error;
            JSC::MarkedArgumentBuffer arguments;
            arguments.append(chunk);
            if (arguments.hasOverflowed()) {
                size_error = JSC::createOutOfMemoryError(global_object);
            } else {
                auto call_data = JSC::getCallData(size_callback);
                JSValue size_value
                    = JSC::call(global_object, size_callback.getObject(), call_data, JSC::jsUndefined(), arguments);
                if (scope.exception()) {
                    size_error = scope.exception()->value();
                    if (!scope.tryClearException())
                        return {};
                } else {
                    size = size_value.toNumber(global_object);
                    if (scope.exception()) {
                        size_error = scope.exception()->value();
                        if (!scope.tryClearException())
                            return {};
                    } else if (!std::isfinite(size) || size < 0) {
                        size_error = JSC::createRangeError(
                            global_object, "WritableStream chunk size must be a finite non-negative number"_s);
                    }
                }
            }
            if (size_error) {
                error(global_object, size_error);
                RETURN_IF_EXCEPTION(scope, {});
                return rejectedPromise(global_object, scope, size_error);
            }
        }
    }

    // The size callback is script and may have released the writer or closed,
    // aborted or errored the stream, so the checks above run again.
    if (writer && writer->stream() != this)
        return rejectedTypeError(global_object, scope, "WritableStreamDefaultWriter has been released"_s);
    if (m_state == WritableState::Closed)
        return rejectedTypeError(global_object, scope, "WritableStream is closed"_s);
    if (m_state == WritableState::Errored || m_state == WritableState::Erroring)
        return rejectedPromise(global_object, scope, storedError());
    if (m_close_requested)
        return rejectedTypeError(global_object, scope, "WritableStream is closing"_s);

    const size_t memory_cost = m_queue_memory_cost_limit ? streamChunkMemoryCost(chunk) : 0;
    if (queueMemoryCostWouldExceed(memory_cost) || queuePendingCountWouldExceed()) {
        JSValue reason
            = JSValue(createStreamQueueLimitExceededError(global_object, "WritableStream queue limit exceeded"_s));
        if (!notifyQueueMemoryLimitExceeded(global_object, scope, reason)) {
            if (!scope.exception())
                JSC::throwOutOfMemoryError(global_object, scope);
            JSValue exception = scope.exception()->value();
            if (!scope.tryClearException())
                return {};
            error(global_object, exception);
            RETURN_IF_EXCEPTION(scope, {});
            return rejectedPromise(global_object, scope, exception);
        }
        return rejectedPromise(global_object, scope, reason);
    }

    // Reserving first leaves nothing after the promise exists that can fail.
    if (!m_write_queue.tryReserveAdditional(this, 1)) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return {};
    }
    auto& vm = global_object->vm();
    if (m_high_water_mark - (m_queue_total_size + size) <= 0) {
        if (auto* current_writer = this->writer())
            current_writer->ensureReadyPending(global_object);
    }
    auto* promise = Collo::newPromise(global_object);
    WriteRequest request;
    request.value.setWithoutWriteBarrier(chunk);
    request.promise.setWithoutWriteBarrier(promise);
    request.size = size;
    request.memory_cost = memory_cost;
    if (!m_write_queue.tryAppend(vm, this, WTF::move(request))) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return {};
    }
    m_queue_total_size += size;
    m_queue_memory_cost += memory_cost;
    processQueue(global_object);
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(promise);
}

EncodedJSValue JSColloWritableStream::close(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    // WritableStreamClose: closing a closed or errored stream rejects with a
    // TypeError, not the stored error.
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
    return JSValue::encode(promise);
}

EncodedJSValue JSColloWritableStream::abort(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue reason)
{
    // WritableStreamAbort: a pending abort request answers every later abort
    // with its own promise, and aborting a closed or errored stream resolves
    // with undefined.
    if (auto* pending = m_abort_promise.get())
        return JSValue::encode(pending);
    if (m_state == WritableState::Closed || m_state == WritableState::Errored || m_state == WritableState::Erroring)
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

    // The sink's abort method is the last one the stream calls, so the
    // controller drops them all before calling it.
    auto* current_controller = controller();
    JSValue abort_callback = current_controller ? current_controller->abortCallback() : JSC::jsUndefined();
    JSValue sink = current_controller ? current_controller->underlyingSink() : JSC::jsUndefined();
    clearAlgorithms();
    if (!valueIsCallable(abort_callback)) {
        finishErroring(global_object, JSC::jsUndefined(), false);
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(promise);
    }

    JSC::MarkedArgumentBuffer arguments;
    arguments.append(reason);
    if (arguments.hasOverflowed()) {
        finishErroring(global_object, JSC::createOutOfMemoryError(global_object), true);
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(promise);
    }
    // FIXME: WritableStreamStartErroring waits until start has finished and no
    // write or close is in flight before WritableStreamFinishErroring calls the
    // sink's abort method. An in-flight write or close settles with the sink's
    // result, and a queued close and the closed promise reject only after the
    // abort method's promise settles. Here the active write, the close promise
    // and the closed promise are already rejected, and the abort method runs at
    // once, even while the sink is still starting, writing or closing.
    auto call_data = JSC::getCallData(abort_callback);
    JSValue result = JSC::call(global_object, abort_callback.getObject(), call_data, sink, arguments);
    if (scope.exception()) {
        JSValue error = scope.exception()->value();
        if (!scope.tryClearException())
            return {};
        finishErroring(global_object, error, true);
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(promise);
    }
    m_state = WritableState::Errored;
    if (auto* result_promise = dynamicDowncast<JSC::JSPromise>(result)) {
        m_abort_in_flight = true;
        result_promise->performPromiseThen(vm, global_object, abortFulfilledFunction(global_object),
            abortRejectedFunction(global_object), JSC::jsUndefined());
        if (scope.exception()) {
            JSValue error = scope.exception()->value();
            if (!scope.tryClearException())
                return {};
            m_abort_in_flight = false;
            finishErroring(global_object, error, true);
            RETURN_IF_EXCEPTION(scope, {});
        }
        return JSValue::encode(promise);
    }
    finishErroring(global_object, JSC::jsUndefined(), false);
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(promise);
}

JSColloWritableStream* createWritableStreamFromCallbacks(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSValue start, JSValue write, JSValue close, JSValue abort, JSValue size, double high_water_mark,
    JSValue underlying_sink)
{
    auto& vm = global_object->vm();
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto* stream = JSColloWritableStream::create(vm, collo_global);
    auto* controller = JSColloWritableStreamDefaultController::create(vm, global_object, stream);
    stream->setController(vm, controller);
    stream->setHighWaterMark(high_water_mark);
    controller->setCallbacks(vm, write, close, abort, size);
    controller->setUnderlyingSink(vm, underlying_sink);
    stream->start(global_object, scope, start);
    RETURN_IF_EXCEPTION(scope, nullptr);
    return stream;
}

} // namespace Collo::HostFunctions
