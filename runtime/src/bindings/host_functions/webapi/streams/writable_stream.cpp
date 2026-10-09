// The WritableStream state machine (Streams, "Writable streams"): queueing
// writes, calling the sink, closing, aborting and erroring, and the writer's
// ready and closed promises. Runs on the VM thread.
//
// processQueue starts a write or the close only after start has finished and
// while no write, close or abort is in flight. abort() does not wait: it
// rejects the active write and calls the sink's abort method even while the
// sink's start, write or close promise is pending. Erroring lasts only for the
// synchronous part of abort(): the stream is Errored before abort() returns,
// unless a termination cuts it short. finishAbort or rejectAbort settles the
// abort promise when the abort method returns one; otherwise abort() settles
// it. The sink's start, write, close and abort run with the underlying sink as
// this.
#include "host_functions/webapi/streams/writable_stream_private.h"

namespace Collo::HostFunctions {
namespace {

    // Releases a deferred that write() created but did not queue; disarm()
    // once the queue owns it.
    class DeferredReleaseGuard {
    public:
        explicit DeferredReleaseGuard(ColloPromiseDeferred*& deferred)
            : m_deferred(deferred)
        {
        }

        ~DeferredReleaseGuard()
        {
            if (!m_armed)
                return;
            if (!m_deferred)
                return;
            collo_promise_deferred_release(m_deferred);
            m_deferred = nullptr;
        }

        void disarm() { m_armed = false; }

    private:
        ColloPromiseDeferred*& m_deferred;
        bool m_armed { true };
    };

} // namespace

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
    JSC::VM& vm, Collo::GlobalObject* global_object, JSC::Structure* structure)
{
    auto* object = new (NotNull, JSC::allocateCell<JSColloWritableStream>(vm)) JSColloWritableStream(vm, structure);
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (!object->finishCreation(vm, global_object, scope))
        return nullptr;
    return object;
}

JSColloWritableStreamDefaultWriter* JSColloWritableStreamDefaultWriter::create(
    JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSColloWritableStream* stream)
{
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto* object = new (NotNull, JSC::allocateCell<JSColloWritableStreamDefaultWriter>(vm))
        JSColloWritableStreamDefaultWriter(vm, collo_global->writableStreamDefaultWriterStructure());
    if (!object->finishCreation(vm, global_object, scope, stream))
        return nullptr;
    stream->lock(vm, object);
    return object;
}

JSColloWritableStreamDefaultWriter::~JSColloWritableStreamDefaultWriter()
{
    if (m_ready_deferred)
        collo_promise_deferred_release(m_ready_deferred);
    if (m_closed_deferred)
        collo_promise_deferred_release(m_closed_deferred);
}

JSColloWritableStream::~JSColloWritableStream()
{
    if (m_close_deferred)
        collo_promise_deferred_release(m_close_deferred);
    if (m_abort_deferred)
        collo_promise_deferred_release(m_abort_deferred);
    if (m_has_active_write && m_active_write.deferred)
        collo_promise_deferred_release(m_active_write.deferred);
    for (auto& request : m_write_queue) {
        if (request.deferred)
            collo_promise_deferred_release(request.deferred);
    }
}

bool JSColloWritableStream::finishCreation(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
    m_queue_memory_limit_exceeded.set(vm, this, JSC::jsUndefined());

    return true;
}

bool JSColloWritableStreamDefaultWriter::finishCreation(
    JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSColloWritableStream* stream)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
    m_stream.set(vm, this, stream);

    JSValue ready_promise;
    if (!createDeferredPromise(global_object, scope, ready_promise, m_ready_deferred))
        return false;
    m_ready_promise.set(vm, this, ready_promise);

    JSValue closed_promise;
    if (!createDeferredPromise(global_object, scope, closed_promise, m_closed_deferred)) {
        if (m_ready_deferred) {
            collo_promise_deferred_release(m_ready_deferred);
            m_ready_deferred = nullptr;
        }
        m_ready_promise.clear();
        return false;
    }
    m_closed_promise.set(vm, this, closed_promise);

    if (stream->state() == WritableState::Closed) {
        settleReady(global_object, JSC::jsUndefined(), false);
        settleClosed(global_object, JSC::jsUndefined(), false);
        return true;
    }
    if (stream->state() == WritableState::Erroring) {
        // SetUpWritableStreamDefaultWriter, "erroring" branch: ready is
        // rejected with the stored error and marked handled, and closed stays
        // pending. finishAbort or rejectAbort rejects it once the sink's abort
        // promise settles.
        JSValue error = stream->storedError();
        if (!error)
            error = JSC::jsUndefined();
        settleReady(global_object, error, true);
        if (auto* ready_promise = dynamicDowncast<JSC::JSPromise>(m_ready_promise.get()))
            ready_promise->markAsHandled();
        return true;
    }
    if (stream->state() == WritableState::Errored) {
        JSValue error = stream->storedError();
        if (!error)
            error = JSC::jsUndefined();
        settleReady(global_object, error, true);
        settleClosed(global_object, error, true);
        return true;
    }
    if (stream->desiredSize() > 0)
        settleReady(global_object, JSC::jsUndefined(), false);
    return true;
}

bool JSColloWritableStreamDefaultWriter::ensureReadyPending(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    if (m_ready_deferred)
        return true;
    JSValue promise;
    ColloPromiseDeferred* deferred = nullptr;
    if (!createDeferredPromise(global_object, scope, promise, deferred))
        return false;
    m_ready_promise.set(global_object->vm(), this, promise);
    m_ready_deferred = deferred;
    return true;
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

void JSColloWritableStreamDefaultWriter::settleReady(
    JSC::JSGlobalObject* global_object, JSValue value, bool is_rejection)
{
    settleDeferred(global_object, m_ready_deferred, value, is_rejection);
}

void JSColloWritableStreamDefaultWriter::settleClosed(
    JSC::JSGlobalObject* global_object, JSValue value, bool is_rejection)
{
    settleDeferred(global_object, m_closed_deferred, value, is_rejection);
}

bool JSColloWritableStream::ensureReadyPending(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    auto* current_writer = writer();
    if (!current_writer)
        return true;
    return current_writer->ensureReadyPending(global_object, scope);
}

void JSColloWritableStream::resolveReadyIfNeeded(JSC::JSGlobalObject* global_object)
{
    if (auto* current_writer = writer())
        current_writer->resolveReadyIfNeeded(global_object, this);
}

void JSColloWritableStream::settleClosed(JSC::JSGlobalObject* global_object, JSValue value, bool is_rejection)
{
    if (auto* current_writer = writer())
        current_writer->settleClosed(global_object, value, is_rejection);
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
    return m_write_queue.size() - m_write_queue_start >= m_write_queue_pending_limit;
}

void JSColloWritableStream::subtractQueueMemoryCost(size_t memory_cost)
{
    if (m_queue_memory_cost > memory_cost)
        m_queue_memory_cost -= memory_cost;
    else
        m_queue_memory_cost = 0;
}

bool JSColloWritableStream::notifyQueueMemoryLimitExceeded(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue reason)
{
    JSValue callback = m_queue_memory_limit_exceeded.get();
    if (!valueIsCallable(callback)) {
        error(global_object, reason);
        return true;
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

bool JSColloWritableStream::appendWriteRequest(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSValue chunk, double size, size_t memory_cost, JSValue promise, ColloPromiseDeferred* deferred)
{
    compactWriteQueueIfNeeded();
    bool reserved = false;
    {
        // The cell lock keeps the concurrent GC marker out of m_write_queue
        // while its buffer may reallocate. Never hold it across JS allocation.
        WTF::Locker locker { cellLock() };
        reserved = m_write_queue.tryReserveCapacity(m_write_queue.size() + 1);
    }
    if (!reserved) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }
    if (m_high_water_mark - (m_queue_total_size + size) <= 0) {
        if (!ensureReadyPending(global_object, scope))
            return false;
    }

    WriteRequest request;
    request.value.set(global_object->vm(), this, chunk);
    request.promise.set(global_object->vm(), this, promise);
    request.deferred = deferred;
    request.size = size;
    request.memory_cost = memory_cost;
    {
        WTF::Locker locker { cellLock() };
        RELEASE_ASSERT(m_write_queue.tryAppend(WTF::move(request)));
    }
    m_queue_total_size += size;
    m_queue_memory_cost += memory_cost;
    return true;
}

bool JSColloWritableStream::dequeueWriteRequest(WriteRequest& out)
{
    if (m_write_queue_start >= m_write_queue.size())
        return false;
    auto& slot = m_write_queue[m_write_queue_start++];
    out = WTF::move(slot);
    slot.deferred = nullptr;
    slot.value.clear();
    slot.promise.clear();
    compactWriteQueueIfNeeded();
    return true;
}

void JSColloWritableStream::compactWriteQueueIfNeeded()
{
    if (!m_write_queue_start)
        return;
    if (m_write_queue_start >= m_write_queue.size()) {
        WTF::Locker locker { cellLock() };
        m_write_queue.clear();
        m_write_queue_start = 0;
        return;
    }
    if (m_write_queue_start > 32 && m_write_queue_start * 2 >= m_write_queue.size()) {
        WTF::Locker locker { cellLock() };
        m_write_queue.removeAt(0, m_write_queue_start);
        m_write_queue_start = 0;
    }
}

void JSColloWritableStream::settleWriteRequest(
    JSC::JSGlobalObject* global_object, WriteRequest& request, JSValue value, bool is_rejection)
{
    request.value.clear();
    request.promise.clear();
    settleDeferred(global_object, request.deferred, value, is_rejection);
    request.size = 0;
    request.memory_cost = 0;
}

void JSColloWritableStream::clearWriteQueue(JSC::JSGlobalObject* global_object, JSValue error)
{
    if (m_has_active_write) {
        if (m_queue_total_size > m_active_write.size)
            m_queue_total_size -= m_active_write.size;
        else
            m_queue_total_size = 0;
        subtractQueueMemoryCost(m_active_write.memory_cost);
        settleWriteRequest(global_object, m_active_write, error, true);
        m_has_active_write = false;
        m_write_in_flight = false;
    }
    while (m_write_queue_start < m_write_queue.size()) {
        WriteRequest request;
        if (!dequeueWriteRequest(request))
            break;
        if (m_queue_total_size > request.size)
            m_queue_total_size -= request.size;
        else
            m_queue_total_size = 0;
        subtractQueueMemoryCost(request.memory_cost);
        settleWriteRequest(global_object, request, error, true);
    }
    {
        WTF::Locker locker { cellLock() };
        m_write_queue.clear();
        m_write_queue_start = 0;
    }
    m_queue_memory_cost = 0;
    if (auto* current_writer = writer())
        current_writer->settleReady(global_object, error, true);
}

void JSColloWritableStream::finishStart(JSC::JSGlobalObject* global_object)
{
    m_starting = false;
    processQueue(global_object);
}

void JSColloWritableStream::error(JSC::JSGlobalObject* global_object, JSValue error)
{
    if (m_state == WritableState::Erroring || m_state == WritableState::Errored || m_state == WritableState::Closed)
        return;
    m_state = WritableState::Errored;
    m_stored_error.set(global_object->vm(), this, error);
    clearAlgorithms();
    m_close_requested = false;
    m_close_in_flight = false;
    clearWriteQueue(global_object, error);
    settleDeferred(global_object, m_close_deferred, error, true);
    m_close_promise.clear();
    settleDeferred(global_object, m_abort_deferred, JSC::jsUndefined(), false);
    m_abort_promise.clear();
    settleClosed(global_object, error, true);
}

void JSColloWritableStream::finishWrite(JSC::JSGlobalObject* global_object)
{
    if (!m_has_active_write)
        return;
    if (m_queue_total_size > m_active_write.size)
        m_queue_total_size -= m_active_write.size;
    else
        m_queue_total_size = 0;
    subtractQueueMemoryCost(m_active_write.memory_cost);
    settleWriteRequest(global_object, m_active_write, JSC::jsUndefined(), false);
    m_has_active_write = false;
    m_write_in_flight = false;
    resolveReadyIfNeeded(global_object);
    processQueue(global_object);
}

void JSColloWritableStream::rejectWrite(JSC::JSGlobalObject* global_object, JSValue reason)
{
    this->error(global_object, reason);
}

void JSColloWritableStream::finishClose(JSC::JSGlobalObject* global_object)
{
    if (m_state != WritableState::Writable || !m_close_requested) {
        m_close_in_flight = false;
        return;
    }
    m_state = WritableState::Closed;
    clearAlgorithms();
    m_close_in_flight = false;
    m_close_requested = false;
    settleDeferred(global_object, m_close_deferred, JSC::jsUndefined(), false);
    m_close_promise.clear();
    settleClosed(global_object, JSC::jsUndefined(), false);
    if (auto* current_writer = writer())
        current_writer->settleReady(global_object, JSC::jsUndefined(), false);
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
    m_state = WritableState::Errored;
    settleDeferred(global_object, m_abort_deferred, JSC::jsUndefined(), false);
    m_abort_promise.clear();
    // Erroring is now finished: settle any closed promise left pending when a
    // writer was acquired mid-erroring (no-op if it already settled).
    settleClosed(global_object, storedError(), true);
}

void JSColloWritableStream::rejectAbort(JSC::JSGlobalObject* global_object, JSValue error)
{
    m_abort_in_flight = false;
    m_state = WritableState::Errored;
    settleDeferred(global_object, m_abort_deferred, error, true);
    m_abort_promise.clear();
    // Erroring is now finished: settle any closed promise left pending when a
    // writer was acquired mid-erroring (no-op if it already settled).
    settleClosed(global_object, storedError(), true);
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
        if (scope.exception())
            return;
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

    if (!m_has_active_write) {
        if (dequeueWriteRequest(m_active_write))
            m_has_active_write = true;
    }

    if (m_has_active_write) {
        auto* current_controller = controller();
        JSValue write_callback = current_controller ? current_controller->writeCallback() : JSC::jsUndefined();
        if (!valueIsCallable(write_callback)) {
            finishWrite(global_object);
            return;
        }
        auto& vm = global_object->vm();
        auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
        JSC::MarkedArgumentBuffer arguments;
        arguments.append(m_active_write.value.get());
        arguments.append(current_controller);
        if (arguments.hasOverflowed()) {
            rejectWrite(global_object, JSC::createOutOfMemoryError(global_object));
            return;
        }
        auto call_data = JSC::getCallData(write_callback);
        JSValue result = JSC::call(
            global_object, write_callback.getObject(), call_data, current_controller->underlyingSink(), arguments);
        if (scope.exception()) {
            JSValue exception = scope.exception()->value();
            scope.clearExceptionExceptTermination();
            rejectWrite(global_object, exception);
            return;
        }
        if (auto* promise = dynamicDowncast<JSC::JSPromise>(result)) {
            m_write_in_flight = true;
            promise->performPromiseThen(vm, global_object, writeFulfilledFunction(global_object),
                writeRejectedFunction(global_object), JSC::jsUndefined());
            if (scope.exception()) {
                JSValue exception = scope.exception()->value();
                scope.clearExceptionExceptTermination();
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
    auto& vm = global_object->vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    auto call_data = JSC::getCallData(close_callback);
    JSC::MarkedArgumentBuffer arguments;
    JSValue result = JSC::call(
        global_object, close_callback.getObject(), call_data, current_controller->underlyingSink(), arguments);
    if (scope.exception()) {
        JSValue exception = scope.exception()->value();
        scope.clearExceptionExceptTermination();
        rejectClose(global_object, exception);
        return;
    }
    if (auto* promise = dynamicDowncast<JSC::JSPromise>(result)) {
        m_close_in_flight = true;
        promise->performPromiseThen(vm, global_object, closeFulfilledFunction(global_object),
            closeRejectedFunction(global_object), JSC::jsUndefined());
        if (scope.exception()) {
            JSValue exception = scope.exception()->value();
            scope.clearExceptionExceptTermination();
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

    JSValue promise;
    ColloPromiseDeferred* deferred = nullptr;
    if (!createDeferredPromise(global_object, scope, promise, deferred))
        return {};
    DeferredReleaseGuard deferred_guard(deferred);

    double size = 1;
    if (auto* current_controller = controller()) {
        JSValue size_callback = current_controller->sizeCallback();
        if (valueIsCallable(size_callback)) {
            JSC::MarkedArgumentBuffer arguments;
            arguments.append(chunk);
            if (arguments.hasOverflowed()) {
                JSC::throwOutOfMemoryError(global_object, scope);
                if (auto* exception = scope.exception()) {
                    JSValue reason = exception->value();
                    if (scope.tryClearException()) {
                        error(global_object, reason);
                        settleDeferred(global_object, deferred, reason, true);
                        return JSValue::encode(promise);
                    }
                }
                return {};
            }
            auto call_data = JSC::getCallData(size_callback);
            JSValue size_value
                = JSC::call(global_object, size_callback.getObject(), call_data, JSC::jsUndefined(), arguments);
            if (scope.exception()) {
                JSValue reason = scope.exception()->value();
                if (!scope.tryClearException())
                    return {};
                error(global_object, reason);
                settleDeferred(global_object, deferred, reason, true);
                return JSValue::encode(promise);
            }
            size = size_value.toNumber(global_object);
            if (scope.exception()) {
                JSValue reason = scope.exception()->value();
                if (!scope.tryClearException())
                    return {};
                error(global_object, reason);
                settleDeferred(global_object, deferred, reason, true);
                return JSValue::encode(promise);
            }
            if (!std::isfinite(size) || size < 0) {
                JSValue reason = JSC::createRangeError(
                    global_object, "WritableStream chunk size must be a finite non-negative number"_s);
                RETURN_IF_EXCEPTION(scope, {});
                error(global_object, reason);
                settleDeferred(global_object, deferred, reason, true);
                return JSValue::encode(promise);
            }
        }
    }

    // The size callback is script and may have released the writer or closed,
    // aborted or errored the stream, so the checks above run again.
    if (writer && writer->stream() != this) {
        JSValue reason = JSC::createTypeError(global_object, "WritableStreamDefaultWriter has been released"_s);
        RETURN_IF_EXCEPTION(scope, {});
        settleDeferred(global_object, deferred, reason, true);
        return JSValue::encode(promise);
    }
    if (m_state == WritableState::Closed) {
        JSValue reason = JSC::createTypeError(global_object, "WritableStream is closed"_s);
        RETURN_IF_EXCEPTION(scope, {});
        settleDeferred(global_object, deferred, reason, true);
        return JSValue::encode(promise);
    }
    if (m_state == WritableState::Errored || m_state == WritableState::Erroring) {
        settleDeferred(global_object, deferred, storedError(), true);
        return JSValue::encode(promise);
    }
    if (m_close_requested) {
        JSValue reason = JSC::createTypeError(global_object, "WritableStream is closing"_s);
        RETURN_IF_EXCEPTION(scope, {});
        settleDeferred(global_object, deferred, reason, true);
        return JSValue::encode(promise);
    }

    const size_t memory_cost = m_queue_memory_cost_limit ? streamChunkMemoryCost(chunk) : 0;
    if (queueMemoryCostWouldExceed(memory_cost) || queuePendingCountWouldExceed()) {
        // Only createTextCodecTransform in text_codec.cpp sets queue limits on a
        // writable stream, hence the message.
        JSValue reason
            = JSValue(createStreamQueueLimitExceededError(global_object, "Text codec stream queue limit exceeded"_s));
        if (!notifyQueueMemoryLimitExceeded(global_object, scope, reason)) {
            if (!scope.exception())
                JSC::throwOutOfMemoryError(global_object, scope);
            JSValue exception = scope.exception()->value();
            if (!scope.tryClearException())
                return {};
            error(global_object, exception);
            settleDeferred(global_object, deferred, exception, true);
            return JSValue::encode(promise);
        }
        settleDeferred(global_object, deferred, reason, true);
        return JSValue::encode(promise);
    }

    if (!appendWriteRequest(global_object, scope, chunk, size, memory_cost, promise, deferred))
        return {};
    deferred_guard.disarm();
    processQueue(global_object);
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

    JSValue promise;
    ColloPromiseDeferred* deferred = nullptr;
    if (!createDeferredPromise(global_object, scope, promise, deferred))
        return {};
    m_close_promise.set(global_object->vm(), this, promise);
    // The checks above leave a writable stream with no close request, and every
    // path that ends a close request settles its deferred.
    ASSERT(!m_close_deferred);
    m_close_deferred = deferred;
    m_close_requested = true;
    processQueue(global_object);
    return JSValue::encode(promise);
}

EncodedJSValue JSColloWritableStream::abort(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue reason)
{
    // WritableStreamAbort: aborting a closed or errored stream resolves with
    // undefined.
    if (m_state == WritableState::Closed || m_state == WritableState::Errored || m_state == WritableState::Erroring)
        return resolvedPromise(global_object, JSC::jsUndefined());

    JSValue promise;
    ColloPromiseDeferred* deferred = nullptr;
    if (!createDeferredPromise(global_object, scope, promise, deferred))
        return {};
    m_abort_promise.set(global_object->vm(), this, promise);
    // Only a writable stream gets here, and a stream never returns to writable
    // once abort has run, so no earlier abort deferred exists.
    ASSERT(!m_abort_deferred);
    m_abort_deferred = deferred;
    m_state = WritableState::Erroring;
    m_stored_error.set(global_object->vm(), this, reason);
    clearWriteQueue(global_object, reason);
    m_close_requested = false;
    m_close_in_flight = false;
    settleDeferred(global_object, m_close_deferred, reason, true);
    m_close_promise.clear();
    settleClosed(global_object, reason, true);

    // The sink's abort method is the last one the stream calls, so the
    // controller drops them all before calling it.
    auto* current_controller = controller();
    JSValue abort_callback = current_controller ? current_controller->abortCallback() : JSC::jsUndefined();
    JSValue sink = current_controller ? current_controller->underlyingSink() : JSC::jsUndefined();
    clearAlgorithms();
    if (!valueIsCallable(abort_callback)) {
        m_state = WritableState::Errored;
        settleDeferred(global_object, m_abort_deferred, JSC::jsUndefined(), false);
        m_abort_promise.clear();
        return JSValue::encode(promise);
    }

    JSC::MarkedArgumentBuffer arguments;
    arguments.append(reason);
    if (arguments.hasOverflowed()) {
        JSC::throwOutOfMemoryError(global_object, scope);
        if (auto* exception = scope.exception()) {
            JSValue error = exception->value();
            if (scope.tryClearException()) {
                m_state = WritableState::Errored;
                settleDeferred(global_object, m_abort_deferred, error, true);
                m_abort_promise.clear();
                return JSValue::encode(promise);
            }
        }
        return {};
    }
    // FIXME: WritableStreamStartErroring waits until start has finished and no
    // write or close is in flight before WritableStreamFinishErroring calls the
    // sink's abort method. An in-flight write or close settles with the sink's
    // result, and a queued close and the closed promise reject only after the
    // abort method's promise settles. Here the active write, the close promise
    // and the closed promise are already rejected, and the abort method runs at
    // once, even while the sink is still starting, writing or closing.
    //
    // FIXME: a writer acquired while the sink's abort method runs gets a
    // pending closed promise, and only finishAbort or rejectAbort settles it.
    // When the method throws or returns a non-promise, that promise stays
    // pending until the writer is released.
    auto call_data = JSC::getCallData(abort_callback);
    JSValue result = JSC::call(global_object, abort_callback.getObject(), call_data, sink, arguments);
    if (scope.exception()) {
        JSValue error = scope.exception()->value();
        if (!scope.tryClearException())
            return {};
        m_state = WritableState::Errored;
        settleDeferred(global_object, m_abort_deferred, error, true);
        m_abort_promise.clear();
        return JSValue::encode(promise);
    }
    m_state = WritableState::Errored;
    if (auto* result_promise = dynamicDowncast<JSC::JSPromise>(result)) {
        m_abort_in_flight = true;
        result_promise->performPromiseThen(global_object->vm(), global_object, abortFulfilledFunction(global_object),
            abortRejectedFunction(global_object), JSC::jsUndefined());
        if (scope.exception()) {
            JSValue error = scope.exception()->value();
            if (!scope.tryClearException())
                return {};
            m_abort_in_flight = false;
            settleDeferred(global_object, m_abort_deferred, error, true);
            m_abort_promise.clear();
        }
        return JSValue::encode(promise);
    }
    settleDeferred(global_object, m_abort_deferred, JSC::jsUndefined(), false);
    m_abort_promise.clear();
    return JSValue::encode(promise);
}

void JSColloWritableStreamDefaultWriter::release(JSC::JSGlobalObject* global_object)
{
    if (auto* current_stream = stream()) {
        if (current_stream->writer() == this)
            current_stream->unlock();
        auto* error = JSC::createTypeError(global_object, "WritableStreamDefaultWriter lock was released"_s);
        settleReady(global_object, error, true);
        settleClosed(global_object, error, true);
        m_stream.clear();
        // WritableStreamDefaultWriterRelease: afterwards ready and closed are
        // handled promises rejected with a TypeError, even when the earlier
        // promises had already settled.
        auto& vm = global_object->vm();
        auto* rejected_ready = JSC::JSPromise::rejectedPromise(global_object, error);
        rejected_ready->markAsHandled();
        m_ready_promise.set(vm, this, rejected_ready);
        auto* rejected_closed = JSC::JSPromise::rejectedPromise(global_object, error);
        rejected_closed->markAsHandled();
        m_closed_promise.set(vm, this, rejected_closed);
    }
}

JSColloWritableStream* createWritableStreamFromCallbacks(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSValue start, JSValue write, JSValue close, JSValue abort, JSValue size, double high_water_mark,
    JSValue underlying_sink)
{
    auto& vm = global_object->vm();
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto* stream = JSColloWritableStream::create(vm, collo_global);
    RETURN_IF_EXCEPTION(scope, nullptr);
    if (!stream)
        return nullptr;
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
