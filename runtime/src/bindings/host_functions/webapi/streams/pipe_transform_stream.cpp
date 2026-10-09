// TransformStream (Streams, "Transform streams") and ReadableStreamPipeTo,
// which pipeTo and pipeThrough share. Runs on the VM thread.
//
// A transform stream is a readable and a writable stream joined by native
// callbacks that find the stream through transformStreamIdentifier. While
// backpressure is set, a write parks its chunk until the readable side pulls.
// A pipe reads only while the destination's desired size is positive, and a
// shutdown waits for the writes the pipe has started before it aborts the
// destination or cancels the source.
#include "host_functions/webapi/streams/pipe_transform_stream_private.h"

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

JSColloTransformStream* JSColloTransformStream::create(JSC::VM& vm, Collo::GlobalObject* global_object)
{
    return createWithStructure(vm, global_object->transformStreamStructure());
}

JSColloTransformStream* JSColloTransformStream::createWithStructure(JSC::VM& vm, JSC::Structure* structure)
{
    auto* object = new (NotNull, JSC::allocateCell<JSColloTransformStream>(vm)) JSColloTransformStream(vm, structure);
    object->finishCreation(vm);
    return object;
}

JSColloTransformStream::~JSColloTransformStream()
{
    if (m_pending_write_deferred)
        collo_promise_deferred_release(m_pending_write_deferred);
}

EncodedJSValue JSColloTransformStream::performTransform(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue chunk)
{
    JSValue transform = transformCallback();
    if (!valueIsCallable(transform)) {
        enqueue(global_object, scope, chunk);
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsUndefined());
    }
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(chunk);
    arguments.append(controller());
    if (arguments.hasOverflowed()) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return {};
    }
    auto call_data = JSC::getCallData(transform);
    return JSValue::encode(JSC::call(global_object, transform.getObject(), call_data, transformer(), arguments));
}

EncodedJSValue JSColloTransformStream::deferWrite(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue chunk)
{
    // The writable side serializes writes, so at most one can be pending.
    RELEASE_ASSERT(!m_has_pending_write);
    JSValue promise;
    ColloPromiseDeferred* deferred = nullptr;
    if (!createDeferredPromise(global_object, scope, promise, deferred))
        return {};
    auto& vm = global_object->vm();
    m_pending_write_chunk.set(vm, this, chunk);
    m_pending_write_promise.set(vm, this, promise);
    m_pending_write_deferred = deferred;
    m_has_pending_write = true;
    return JSValue::encode(promise);
}

void JSColloTransformStream::readablePulled(JSC::JSGlobalObject* global_object)
{
    m_backpressure = false;
    if (!m_has_pending_write)
        return;
    JSValue chunk = m_pending_write_chunk.get();
    auto* deferred = m_pending_write_deferred;
    m_pending_write_deferred = nullptr;
    m_pending_write_chunk.clear();
    m_pending_write_promise.clear();
    m_has_pending_write = false;

    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSValue result = JSValue::decode(performTransform(global_object, scope, chunk));
    if (scope.exception()) {
        JSValue reason = scope.exception()->value();
        if (!scope.tryClearException()) {
            settleDeferred(global_object, deferred, reason, true);
            return;
        }
        error(global_object, reason);
        settleDeferred(global_object, deferred, reason, true);
        return;
    }
    // Resolving with the transform result adopts it when it is a promise,
    // so async transforms keep the writable side waiting.
    settleDeferred(global_object, deferred, result ? result : JSC::jsUndefined(), false);
}

void JSColloTransformStream::rejectPendingWrite(JSC::JSGlobalObject* global_object, JSValue reason)
{
    if (!m_has_pending_write)
        return;
    auto* deferred = m_pending_write_deferred;
    m_pending_write_deferred = nullptr;
    m_pending_write_chunk.clear();
    m_pending_write_promise.clear();
    m_has_pending_write = false;
    settleDeferred(global_object, deferred, reason, true);
}

void JSColloTransformStream::errorWritableAndUnblockWrite(JSC::JSGlobalObject* global_object, JSValue reason)
{
    clearAlgorithms();
    m_backpressure = false;
    if (auto* stream = writable())
        stream->error(global_object, reason);
    rejectPendingWrite(global_object, reason);
}

JSColloPipeToState* JSColloPipeToState::create(JSC::VM& vm, JSC::JSGlobalObject* global_object,
    JSColloReadableStream* source, JSColloWritableStream* destination, JSColloReadableStreamDefaultReader* reader,
    JSColloWritableStreamDefaultWriter* writer)
{
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto* structure = collo_global->webApiCache().pipe_to_state_structure.get();
    RELEASE_ASSERT(structure);
    auto* object = new (NotNull, JSC::allocateCell<JSColloPipeToState>(vm)) JSColloPipeToState(vm, structure);
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (!object->finishCreation(vm, global_object, scope, source, destination, reader, writer))
        return nullptr;
    return object;
}

bool JSColloPipeToState::finishCreation(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSColloReadableStream* source, JSColloWritableStream* destination, JSColloReadableStreamDefaultReader* reader,
    JSColloWritableStreamDefaultWriter* writer)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
    m_source.set(vm, this, source);
    m_destination.set(vm, this, destination);
    m_reader.set(vm, this, reader);
    m_writer.set(vm, this, writer);

    JSDeferredPromise deferred;
    if (!createJSDeferredPromise(global_object, scope, deferred))
        return false;

    // Nothing reads this property: it keeps the state reachable from its
    // promise until clearPromiseOwner overwrites it with undefined, when the
    // pipe settles or its start fails.
    deferred.promise.getObject()->putDirect(
        vm, pipeToStateIdentifier(global_object), this, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    m_promise.set(vm, this, deferred.promise);
    m_resolve.set(vm, this, deferred.resolve);
    m_reject.set(vm, this, deferred.reject);
    return true;
}

void JSColloPipeToState::cleanupLocks(JSC::JSGlobalObject* global_object)
{
    if (auto* reader = m_reader.get()) {
        reader->release(global_object);
        m_reader.clear();
    }
    if (auto* writer = m_writer.get()) {
        writer->release(global_object);
        m_writer.clear();
    }
}

void JSColloPipeToState::detachSignal()
{
    JSValue signal_value = m_signal.get();
    auto* signal = signal_value && signal_value.isObject() ? webApiAbortSignalFromValue(signal_value) : nullptr;
    auto* callback = m_signal_abort.get();
    if (signal && callback)
        signal->removeInternalAbortAlgorithm(callback);
    m_signal.clear();
    m_signal_abort.clear();
}

void JSColloPipeToState::clearPromiseOwner(JSC::JSGlobalObject* global_object)
{
    auto& vm = global_object->vm();
    if (auto* promise_object = dynamicDowncast<JSC::JSObject>(m_promise.get())) {
        promise_object->putDirect(vm, pipeToStateIdentifier(global_object), JSC::jsUndefined(),
            static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    }
}

void JSColloPipeToState::settlePromise(JSC::JSGlobalObject* global_object, JSValue value, bool is_rejection)
{
    JSValue callback = is_rejection ? m_reject.get() : m_resolve.get();
    settleJSDeferredPromise(global_object, callback, value);
    clearPromiseOwner(global_object);
    m_read_fulfilled.clear();
    m_read_rejected.clear();
    m_write_fulfilled.clear();
    m_write_rejected.clear();
    m_shutdown_fulfilled.clear();
    m_shutdown_rejected.clear();
    m_shutdown_reason.clear();
    m_promise.clear();
    m_resolve.clear();
    m_reject.clear();
    m_shutdown_pending = 0;
}

void JSColloPipeToState::settle(JSC::JSGlobalObject* global_object, JSValue value, bool is_rejection)
{
    if (m_settled)
        return;
    m_settled = true;
    if (auto* source = m_source.get())
        source->setPipeBackpressure(false);
    detachSignal();
    cleanupLocks(global_object);
    m_source.clear();
    m_destination.clear();
    settlePromise(global_object, value, is_rejection);
}

void JSColloPipeToState::abandonStartFailure(JSC::JSGlobalObject* global_object)
{
    if (m_settled)
        return;
    m_settled = true;
    if (auto* source = m_source.get())
        source->setPipeBackpressure(false);
    detachSignal();
    cleanupLocks(global_object);
    clearPromiseOwner(global_object);
    m_source.clear();
    m_destination.clear();
    m_promise.clear();
    m_resolve.clear();
    m_reject.clear();
    m_read_fulfilled.clear();
    m_read_rejected.clear();
    m_write_fulfilled.clear();
    m_write_rejected.clear();
    m_shutdown_fulfilled.clear();
    m_shutdown_rejected.clear();
    m_shutdown_reason.clear();
    m_shutdown_pending = 0;
}

void JSColloPipeToState::startShutdownAction(JSC::JSGlobalObject* global_object, JSValue action_value)
{
    auto* promise = dynamicDowncast<JSC::JSPromise>(action_value);
    if (!promise)
        return;

    m_shutdown_pending++;
    auto scope = DECLARE_THROW_SCOPE(global_object->vm());
    promise->performPromiseThen(global_object->vm(), global_object, shutdownFulfilledFunction(global_object),
        shutdownRejectedFunction(global_object), JSC::jsUndefined());
    if (scope.exception()) {
        JSValue exception = scope.exception()->value();
        if (!scope.tryClearException())
            return;
        if (m_shutdown_pending > 0)
            m_shutdown_pending--;
        recordShutdownRejection(global_object, exception);
    }
}

void JSColloPipeToState::shutdownActionRejected(JSC::JSGlobalObject* global_object, JSValue reason)
{
    if (m_shutdown_pending > 0)
        m_shutdown_pending--;
    recordShutdownRejection(global_object, reason);
    finishShutdownIfReady(global_object);
}

void JSColloPipeToState::recordShutdownRejection(JSC::JSGlobalObject* global_object, JSValue reason)
{
    m_shutdown_reason.set(global_object->vm(), this, reason);
    m_shutdown_is_rejection = true;
}

void JSColloPipeToState::shutdownActionSettled(JSC::JSGlobalObject* global_object)
{
    if (m_shutdown_pending > 0)
        m_shutdown_pending--;
    finishShutdownIfReady(global_object);
}

void JSColloPipeToState::finishShutdownIfReady(JSC::JSGlobalObject* global_object)
{
    if (m_shutdown_pending != 0 || m_settled)
        return;
    JSValue reason = m_shutdown_reason.get();
    bool is_rejection = m_shutdown_is_rejection;
    m_shutting_down = false;
    settle(global_object, reason ? reason : JSC::jsUndefined(), is_rejection);
}

void JSColloPipeToState::shutdownAndSettle(
    JSC::JSGlobalObject* global_object, JSValue reason, bool is_rejection, bool abort_destination, bool cancel_source)
{
    if (m_settled)
        return;
    if (m_shutting_down)
        return;

    m_shutting_down = true;
    // ReadableStreamPipeTo, "shutdown with an action": every chunk already
    // read must finish writing before the destination is aborted or the
    // source canceled, so the actions wait until this pipe's writes settle.
    if (m_writes_in_flight != 0) {
        m_deferred_shutdown = true;
        m_shutdown_is_rejection = is_rejection;
        m_shutdown_reason.set(global_object->vm(), this, reason);
        m_deferred_abort_destination = abort_destination;
        m_deferred_cancel_source = cancel_source;
        return;
    }
    performShutdownActions(global_object, reason, is_rejection, abort_destination, cancel_source);
}

void JSColloPipeToState::runDeferredShutdownActions(JSC::JSGlobalObject* global_object)
{
    m_deferred_shutdown = false;
    JSValue reason = m_shutdown_reason.get();
    performShutdownActions(global_object, reason ? reason : JSC::jsUndefined(), m_shutdown_is_rejection,
        m_deferred_abort_destination, m_deferred_cancel_source);
}

void JSColloPipeToState::performShutdownActions(
    JSC::JSGlobalObject* global_object, JSValue reason, bool is_rejection, bool abort_destination, bool cancel_source)
{
    m_shutdown_pending = 0;
    m_shutdown_is_rejection = is_rejection;
    m_shutdown_reason.set(global_object->vm(), this, reason);

    if (abort_destination && !m_prevent_abort) {
        if (auto* destination = m_destination.get()) {
            auto scope = DECLARE_THROW_SCOPE(global_object->vm());
            JSValue action_value = JSValue::decode(destination->abort(global_object, scope, reason));
            if (scope.exception()) {
                JSValue exception = scope.exception()->value();
                if (!scope.tryClearException())
                    return;
                recordShutdownRejection(global_object, exception);
            } else {
                startShutdownAction(global_object, action_value);
            }
        }
    }

    if (cancel_source && !m_prevent_cancel) {
        if (auto* source = m_source.get()) {
            auto scope = DECLARE_THROW_SCOPE(global_object->vm());
            JSValue action_value = JSValue::decode(source->cancel(global_object, scope, reason));
            if (scope.exception()) {
                JSValue exception = scope.exception()->value();
                if (!scope.tryClearException())
                    return;
                recordShutdownRejection(global_object, exception);
            } else {
                startShutdownAction(global_object, action_value);
            }
        }
    }

    finishShutdownIfReady(global_object);
}

void JSColloPipeToState::finishSourceDoneIfReady(JSC::JSGlobalObject* global_object)
{
    if (!m_source_done || m_writes_in_flight != 0 || m_settled || m_shutting_down)
        return;

    if (auto* source = m_source.get())
        source->setPipeBackpressure(false);
    if (m_prevent_close) {
        settle(global_object, JSC::jsUndefined(), false);
        return;
    }
    auto* destination = m_destination.get();
    if (!destination) {
        settle(global_object, JSC::jsUndefined(), false);
        return;
    }

    // Closing the destination is a shutdown: once it starts, a later signal
    // abort must neither abort the destination nor cancel the source, and the
    // pipe settles from the close outcome.
    m_shutting_down = true;
    m_shutdown_pending = 0;
    m_shutdown_is_rejection = false;
    m_shutdown_reason.clear();
    auto scope = DECLARE_THROW_SCOPE(global_object->vm());
    JSValue close_value = JSValue::decode(destination->close(global_object, scope));
    if (scope.exception()) {
        JSValue exception = scope.exception()->value();
        if (!scope.tryClearException())
            return;
        recordShutdownRejection(global_object, exception);
        finishShutdownIfReady(global_object);
        return;
    }
    if (dynamicDowncast<JSC::JSPromise>(close_value))
        startShutdownAction(global_object, close_value);
    finishShutdownIfReady(global_object);
}

void JSColloPipeToState::pump(JSC::JSGlobalObject* global_object)
{
    if (m_settled || m_shutting_down || m_pumping || m_read_in_flight || m_source_done)
        return;
    auto* source = m_source.get();
    if (!source)
        return;
    auto* destination = m_destination.get();
    if (!destination) {
        source->setPipeBackpressure(false);
        settle(global_object, JSC::createTypeError(global_object, "pipeTo destination is unavailable"_s), true);
        return;
    }
    if (destination->state() != WritableState::Writable) {
        source->setPipeBackpressure(false);
        JSValue reason = destination->storedError();
        if (!reason) {
            reason = JSC::createTypeError(global_object, "pipeTo destination is not writable"_s);
        }
        shutdownAndSettle(global_object, reason, true, false, true);
        return;
    }
    if (destination->desiredSize() <= 0) {
        source->setPipeBackpressure(true);
        return;
    }
    m_pumping = true;
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    // With pipe backpressure set, the source pulls only to serve a read
    // request (JSColloReadableStream::callPullIfNeeded), not to refill its
    // queue toward its high-water mark.
    source->setPipeBackpressure(true);
    JSValue read_value = JSValue::decode(source->read(global_object, scope));
    if (scope.exception()) {
        JSValue exception = scope.exception()->value();
        source->setPipeBackpressure(false);
        m_pumping = false;
        if (!scope.tryClearException())
            return;
        shutdownAndSettle(global_object, exception, true, true, false);
        return;
    }
    m_read_in_flight = true;
    auto* read_promise = dynamicDowncast<JSC::JSPromise>(read_value);
    if (!read_promise) {
        m_pumping = false;
        readFulfilled(global_object, read_value);
        return;
    }
    read_promise->performPromiseThen(vm, global_object, readFulfilledFunction(global_object),
        readRejectedFunction(global_object), JSC::jsUndefined());
    if (scope.exception()) {
        JSValue exception = scope.exception()->value();
        source->setPipeBackpressure(false);
        m_pumping = false;
        m_read_in_flight = false;
        if (!scope.tryClearException())
            return;
        shutdownAndSettle(global_object, exception, true, true, false);
    }
}

void JSColloPipeToState::readFulfilled(JSC::JSGlobalObject* global_object, JSValue result)
{
    m_pumping = false;
    m_read_in_flight = false;
    if (m_settled || m_shutting_down) {
        if (auto* source = m_source.get())
            source->setPipeBackpressure(false);
        return;
    }
    bool done = false;
    JSValue error;
    if (!readResultDone(global_object, result, done, error)) {
        if (auto* source = m_source.get())
            source->setPipeBackpressure(false);
        shutdownAndSettle(global_object, error, true, true, false);
        return;
    }
    if (done) {
        if (auto* source = m_source.get())
            source->setPipeBackpressure(false);
        m_source_done = true;
        finishSourceDoneIfReady(global_object);
        return;
    }

    JSValue value = readResultValue(global_object, result);
    if (!value)
        value = JSC::jsUndefined();
    auto* destination = m_destination.get();
    if (!destination) {
        if (auto* source = m_source.get())
            source->setPipeBackpressure(false);
        settle(global_object, JSC::createTypeError(global_object, "pipeTo destination is unavailable"_s), true);
        return;
    }
    auto scope = DECLARE_THROW_SCOPE(global_object->vm());
    JSValue write_value = JSValue::decode(destination->write(global_object, scope, value));
    if (scope.exception()) {
        JSValue exception = scope.exception()->value();
        if (auto* source = m_source.get())
            source->setPipeBackpressure(false);
        if (!scope.tryClearException())
            return;
        shutdownAndSettle(global_object, exception, true, false, true);
        return;
    }
    if (auto* write_promise = dynamicDowncast<JSC::JSPromise>(write_value)) {
        m_writes_in_flight++;
        write_promise->performPromiseThen(global_object->vm(), global_object, writeFulfilledFunction(global_object),
            writeRejectedFunction(global_object), JSC::jsUndefined());
        if (scope.exception()) {
            if (m_writes_in_flight > 0)
                m_writes_in_flight--;
            JSValue exception = scope.exception()->value();
            if (auto* source = m_source.get())
                source->setPipeBackpressure(false);
            if (!scope.tryClearException())
                return;
            shutdownAndSettle(global_object, exception, true, false, true);
            return;
        }
    }
    if (auto* source = m_source.get())
        source->setPipeBackpressure(false);
    pump(global_object);
}

void JSColloPipeToState::readRejected(JSC::JSGlobalObject* global_object, JSValue reason)
{
    m_pumping = false;
    m_read_in_flight = false;
    if (auto* source = m_source.get())
        source->setPipeBackpressure(false);
    if (m_settled || m_shutting_down)
        return;
    shutdownAndSettle(global_object, reason, true, true, false);
}

void JSColloPipeToState::writeFulfilled(JSC::JSGlobalObject* global_object)
{
    if (m_writes_in_flight > 0)
        m_writes_in_flight--;
    if (auto* source = m_source.get())
        source->setPipeBackpressure(false);
    if (m_deferred_shutdown && m_writes_in_flight == 0) {
        runDeferredShutdownActions(global_object);
        return;
    }
    if (m_settled || m_shutting_down)
        return;
    if (m_source_done) {
        finishSourceDoneIfReady(global_object);
        return;
    }
    pump(global_object);
}

void JSColloPipeToState::writeRejected(JSC::JSGlobalObject* global_object, JSValue reason)
{
    if (m_writes_in_flight > 0)
        m_writes_in_flight--;
    if (auto* source = m_source.get())
        source->setPipeBackpressure(false);
    // A shutdown deferred behind this write keeps its own reason: the
    // write rejection only reports how the wait ended.
    if (m_deferred_shutdown && m_writes_in_flight == 0) {
        runDeferredShutdownActions(global_object);
        return;
    }
    if (m_settled || m_shutting_down)
        return;
    shutdownAndSettle(global_object, reason, true, false, true);
}

void JSColloPipeToState::abortFromSignal(JSC::JSGlobalObject* global_object, JSValue reason)
{
    shutdownAndSettle(global_object, reason, true, true, true);
}

static JSColloPipeToState* pipeToStateFromFunction(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSFunction* function)
{
    JSValue value = function->get(global_object, pipeToStateIdentifier(global_object));
    RETURN_IF_EXCEPTION(scope, nullptr);
    auto* state = dynamicDowncast<JSColloPipeToState>(value);
    if (!state)
        JSC::throwVMTypeError(global_object, scope, "ReadableStream pipe state is unavailable"_s);
    return state;
}

JSC_DEFINE_HOST_FUNCTION(pipeToReadFulfilled, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* state
        = pipeToStateFromFunction(global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
    RETURN_IF_EXCEPTION(scope, {});
    state->readFulfilled(global_object, call_frame->argument(0));
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(pipeToReadRejected, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* state
        = pipeToStateFromFunction(global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
    RETURN_IF_EXCEPTION(scope, {});
    state->readRejected(global_object, call_frame->argument(0));
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(pipeToWriteFulfilled, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* state
        = pipeToStateFromFunction(global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
    RETURN_IF_EXCEPTION(scope, {});
    state->writeFulfilled(global_object);
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(pipeToWriteRejected, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* state
        = pipeToStateFromFunction(global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
    RETURN_IF_EXCEPTION(scope, {});
    state->writeRejected(global_object, call_frame->argument(0));
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(pipeToSignalAbort, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* state
        = pipeToStateFromFunction(global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
    RETURN_IF_EXCEPTION(scope, {});
    JSValue reason = JSC::jsUndefined();
    JSValue signal_value = call_frame->thisValue();
    if (signal_value && signal_value.isObject()) {
        if (auto* signal = webApiAbortSignalFromValue(signal_value))
            reason = signal->reason();
    }
    state->abortFromSignal(global_object, reason);
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(pipeToShutdownFulfilled, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* state
        = pipeToStateFromFunction(global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
    RETURN_IF_EXCEPTION(scope, {});
    state->shutdownActionSettled(global_object);
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(pipeToShutdownRejected, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* state
        = pipeToStateFromFunction(global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
    RETURN_IF_EXCEPTION(scope, {});
    state->shutdownActionRejected(global_object, call_frame->argument(0));
    return JSValue::encode(JSC::jsUndefined());
}

JSC::JSFunction* JSColloPipeToState::readFulfilledFunction(JSC::JSGlobalObject* global_object)
{
    return cachedThenCallback(global_object, m_read_fulfilled, this, "ReadableStream pipe read fulfilled"_s,
        pipeToReadFulfilled, pipeToStateIdentifier(global_object), this);
}

JSC::JSFunction* JSColloPipeToState::readRejectedFunction(JSC::JSGlobalObject* global_object)
{
    return cachedThenCallback(global_object, m_read_rejected, this, "ReadableStream pipe read rejected"_s,
        pipeToReadRejected, pipeToStateIdentifier(global_object), this);
}

JSC::JSFunction* JSColloPipeToState::writeFulfilledFunction(JSC::JSGlobalObject* global_object)
{
    return cachedThenCallback(global_object, m_write_fulfilled, this, "ReadableStream pipe write fulfilled"_s,
        pipeToWriteFulfilled, pipeToStateIdentifier(global_object), this);
}

JSC::JSFunction* JSColloPipeToState::writeRejectedFunction(JSC::JSGlobalObject* global_object)
{
    return cachedThenCallback(global_object, m_write_rejected, this, "ReadableStream pipe write rejected"_s,
        pipeToWriteRejected, pipeToStateIdentifier(global_object), this);
}

JSC::JSFunction* JSColloPipeToState::signalAbortFunction(JSC::JSGlobalObject* global_object)
{
    return cachedThenCallback(global_object, m_signal_abort, this, "ReadableStream pipe abort"_s, pipeToSignalAbort,
        pipeToStateIdentifier(global_object), this);
}

JSC::JSFunction* JSColloPipeToState::shutdownFulfilledFunction(JSC::JSGlobalObject* global_object)
{
    return cachedThenCallback(global_object, m_shutdown_fulfilled, this, "ReadableStream pipe shutdown fulfilled"_s,
        pipeToShutdownFulfilled, pipeToStateIdentifier(global_object), this);
}

JSC::JSFunction* JSColloPipeToState::shutdownRejectedFunction(JSC::JSGlobalObject* global_object)
{
    return cachedThenCallback(global_object, m_shutdown_rejected, this, "ReadableStream pipe shutdown rejected"_s,
        pipeToShutdownRejected, pipeToStateIdentifier(global_object), this);
}

static bool pipeToOptionBoolean(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* options, WTF::ASCIILiteral name)
{
    JSValue value = options->getIfPropertyExists(global_object, JSC::Identifier::fromString(global_object->vm(), name));
    RETURN_IF_EXCEPTION(scope, false);
    if (value.isEmpty() || value.isUndefined())
        return false;
    bool result = value.toBoolean(global_object);
    RETURN_IF_EXCEPTION(scope, false);
    return result;
}

struct PipeToOptions {
    JSC::Strong<JSC::Unknown> signal;
    bool has_signal { false };
    bool prevent_close { false };
    bool prevent_abort { false };
    bool prevent_cancel { false };
};

static bool parsePipeToOptions(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value, PipeToOptions& out)
{
    if (value.isUndefined() || value.isNull())
        return true;
    if (!value.isObject()) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream pipeTo options must be an object"_s);
        return false;
    }

    // Web IDL reads StreamPipeOptions members in lexicographic order.
    auto& vm = global_object->vm();
    auto* options = value.getObject();
    out.prevent_abort = pipeToOptionBoolean(global_object, scope, options, "preventAbort"_s);
    RETURN_IF_EXCEPTION(scope, false);
    out.prevent_cancel = pipeToOptionBoolean(global_object, scope, options, "preventCancel"_s);
    RETURN_IF_EXCEPTION(scope, false);
    out.prevent_close = pipeToOptionBoolean(global_object, scope, options, "preventClose"_s);
    RETURN_IF_EXCEPTION(scope, false);

    JSValue signal = options->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "signal"_s));
    RETURN_IF_EXCEPTION(scope, false);
    if (signal.isEmpty() || signal.isUndefined())
        return true;
    auto* abort_signal = webApiAbortSignalFromValue(signal);
    if (!abort_signal) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream pipeTo signal must be an AbortSignal"_s);
        return false;
    }
    out.signal = JSC::Strong<JSC::Unknown>(vm, abort_signal);
    out.has_signal = true;
    return true;
}

EncodedJSValue startReadablePipeTo(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSColloReadableStream* source, JSColloWritableStream* destination, JSValue options, bool reject_option_errors)
{
    auto& vm = global_object->vm();
    if (source->locked())
        return rejectedTypeError(global_object, scope, "ReadableStream is already locked"_s);
    if (destination->locked())
        return rejectedTypeError(global_object, scope, "WritableStream is already locked"_s);

    PipeToOptions parsed_options;
    if (!parsePipeToOptions(global_object, scope, options, parsed_options)) {
        if (reject_option_errors && scope.exception()) {
            JSValue exception = scope.exception()->value();
            if (!scope.tryClearException())
                return {};
            return rejectedPromise(global_object, exception);
        }
        return {};
    }
    RETURN_IF_EXCEPTION(scope, {});

    auto* reader = JSColloReadableStreamDefaultReader::create(vm, global_object, source);
    RETURN_IF_EXCEPTION(scope, {});
    if (!reader)
        return {};
    source->lock(vm, reader);
    auto* writer = JSColloWritableStreamDefaultWriter::create(vm, global_object, scope, destination);
    RETURN_IF_EXCEPTION(scope, {});
    if (!writer) {
        reader->release(global_object);
        return {};
    }

    auto* state = JSColloPipeToState::create(vm, global_object, source, destination, reader, writer);
    if (scope.exception() || !state) {
        reader->release(global_object);
        writer->release(global_object);
        return {};
    }

    state->setOptions(parsed_options.prevent_close, parsed_options.prevent_abort, parsed_options.prevent_cancel);

    auto* signal = parsed_options.has_signal ? webApiAbortSignalFromValue(parsed_options.signal.get()) : nullptr;
    if (signal) {
        state->setSignal(vm, signal);
        if (signal->aborted()) {
            JSValue pipe_promise = state->promise();
            state->abortFromSignal(global_object, signal->reason());
            return JSValue::encode(pipe_promise);
        }

        auto* callback = state->signalAbortFunction(global_object);
        if (!signal->addInternalAbortAlgorithm(vm, global_object, scope, callback)) {
            state->abandonStartFailure(global_object);
            return {};
        }
        RETURN_IF_EXCEPTION(scope, {});
    }

    state->pump(global_object);
    return JSValue::encode(state->promise());
}

void JSColloTransformStream::enqueue(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue chunk)
{
    auto* stream = readable();
    if (!stream) {
        JSC::throwVMTypeError(global_object, scope, "TransformStream readable side is unavailable"_s);
        return;
    }
    stream->enqueue(global_object, scope, chunk);
    if (scope.exception()) {
        // TransformStreamDefaultControllerEnqueue: a failed enqueue errors the
        // writable side and unblocks a parked write before it rethrows.
        JSValue reason = scope.exception()->value();
        if (!scope.tryClearException())
            return;
        errorWritableAndUnblockWrite(global_object, reason);
        JSC::throwException(global_object, scope, reason);
        return;
    }
    if (stream->desiredSize() <= 0 && !stream->hasPendingReadRequests())
        m_backpressure = true;
}

void JSColloTransformStream::error(JSC::JSGlobalObject* global_object, JSValue reason)
{
    clearAlgorithms();
    m_backpressure = false;
    if (auto* stream = readable())
        stream->error(global_object, reason);
    if (auto* stream = writable())
        stream->error(global_object, reason);
    rejectPendingWrite(global_object, reason);
}

void JSColloTransformStream::terminate(JSC::JSGlobalObject* global_object)
{
    if (auto* stream = readable())
        stream->close(global_object);
    JSValue reason = JSC::createTypeError(global_object, "The transform stream has been terminated"_s);
    errorWritableAndUnblockWrite(global_object, reason);
}

static JSColloTransformStream* transformStreamFromFunction(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSFunction* function)
{
    JSValue value = function->get(global_object, transformStreamIdentifier(global_object));
    RETURN_IF_EXCEPTION(scope, nullptr);
    auto* stream = dynamicDowncast<JSColloTransformStream>(value);
    if (!stream)
        JSC::throwVMTypeError(global_object, scope, "TransformStream state is unavailable"_s);
    return stream;
}

static JSC::JSFunction* createTransformCallback(JSC::JSGlobalObject* global_object, JSColloTransformStream* stream,
    WTF::ASCIILiteral name, JSC::NativeFunction callback, unsigned length)
{
    auto& vm = global_object->vm();
    auto* function
        = JSC::JSFunction::create(vm, global_object, length, name, callback, JSC::ImplementationVisibility::Public);
    function->putDirect(
        vm, transformStreamIdentifier(global_object), stream, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    return function;
}

JSC_DEFINE_HOST_FUNCTION(transformStartRejected, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream
        = transformStreamFromFunction(global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
    RETURN_IF_EXCEPTION(scope, {});
    // A rejected start errors the readable side here. Rethrowing rejects the
    // promise the writable side's start waits on, which errors that side.
    if (auto* readable = stream->readable())
        readable->error(global_object, call_frame->argument(0));
    return JSValue::encode(JSC::throwException(global_object, scope, call_frame->argument(0)));
}

JSC_DEFINE_HOST_FUNCTION(transformStartCallback, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream
        = transformStreamFromFunction(global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
    RETURN_IF_EXCEPTION(scope, {});
    JSValue start = stream->takeStartCallback();
    if (!valueIsCallable(start))
        return JSValue::encode(JSC::jsUndefined());
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(stream->controller());
    if (arguments.hasOverflowed()) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return {};
    }
    auto call_data = JSC::getCallData(start);
    JSValue result = JSC::call(global_object, start.getObject(), call_data, stream->transformer(), arguments);
    RETURN_IF_EXCEPTION(scope, {});
    auto* promise = dynamicDowncast<JSC::JSPromise>(result);
    if (!promise)
        return JSValue::encode(result);
    auto* result_promise = JSC::JSPromise::create(vm, global_object->promiseStructure());
    auto* rejected
        = createTransformCallback(global_object, stream, "TransformStream start rejected"_s, transformStartRejected, 1);
    promise->performPromiseThen(vm, global_object, JSC::jsUndefined(), rejected, result_promise);
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(result_promise);
}

JSC_DEFINE_HOST_FUNCTION(transformWriteCallback, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream
        = transformStreamFromFunction(global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
    RETURN_IF_EXCEPTION(scope, {});
    // With backpressure the write parks until the readable side pulls; the
    // writable side waits for the returned promise before its next write.
    if (stream->backpressure())
        return stream->deferWrite(global_object, scope, call_frame->argument(0));
    return stream->performTransform(global_object, scope, call_frame->argument(0));
}

JSC_DEFINE_HOST_FUNCTION(
    transformReadablePullCallback, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream
        = transformStreamFromFunction(global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
    RETURN_IF_EXCEPTION(scope, {});
    stream->readablePulled(global_object);
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(
    transformReadableCancelCallback, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream
        = transformStreamFromFunction(global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
    RETURN_IF_EXCEPTION(scope, {});
    JSValue reason = call_frame->argument(0);
    JSValue cancel_result = JSC::jsUndefined();
    JSValue cancel = stream->cancelCallback();
    JSValue transformer = stream->transformer();
    stream->clearAlgorithms();
    if (valueIsCallable(cancel)) {
        JSC::MarkedArgumentBuffer arguments;
        arguments.append(reason);
        if (arguments.hasOverflowed()) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return {};
        }
        auto call_data = JSC::getCallData(cancel);
        cancel_result = JSC::call(global_object, cancel.getObject(), call_data, transformer, arguments);
        RETURN_IF_EXCEPTION(scope, {});
    }
    stream->errorWritableAndUnblockWrite(global_object, reason);
    return JSValue::encode(cancel_result);
}

JSC_DEFINE_HOST_FUNCTION(transformFlushFulfilled, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream
        = transformStreamFromFunction(global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
    RETURN_IF_EXCEPTION(scope, {});
    if (auto* readable = stream->readable())
        readable->close(global_object);
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(transformFlushRejected, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream
        = transformStreamFromFunction(global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
    RETURN_IF_EXCEPTION(scope, {});
    stream->error(global_object, call_frame->argument(0));
    return JSValue::encode(JSC::throwException(global_object, scope, call_frame->argument(0)));
}

JSC_DEFINE_HOST_FUNCTION(transformCloseCallback, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream
        = transformStreamFromFunction(global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
    RETURN_IF_EXCEPTION(scope, {});
    JSValue flush = stream->flushCallback();
    JSValue transformer = stream->transformer();
    stream->clearAlgorithms();
    if (!valueIsCallable(flush)) {
        if (auto* readable = stream->readable())
            readable->close(global_object);
        return JSValue::encode(JSC::jsUndefined());
    }
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(stream->controller());
    if (arguments.hasOverflowed()) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return {};
    }
    auto call_data = JSC::getCallData(flush);
    JSValue result = JSC::call(global_object, flush.getObject(), call_data, transformer, arguments);
    RETURN_IF_EXCEPTION(scope, {});
    auto* promise = dynamicDowncast<JSC::JSPromise>(result);
    if (!promise) {
        if (auto* readable = stream->readable())
            readable->close(global_object);
        return JSValue::encode(JSC::jsUndefined());
    }
    auto* result_promise = JSC::JSPromise::create(vm, global_object->promiseStructure());
    auto* fulfilled = createTransformCallback(
        global_object, stream, "TransformStream flush fulfilled"_s, transformFlushFulfilled, 1);
    auto* rejected
        = createTransformCallback(global_object, stream, "TransformStream flush rejected"_s, transformFlushRejected, 1);
    promise->performPromiseThen(vm, global_object, fulfilled, rejected, result_promise);
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(result_promise);
}

JSC_DEFINE_HOST_FUNCTION(transformAbortCallback, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream
        = transformStreamFromFunction(global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
    RETURN_IF_EXCEPTION(scope, {});
    JSValue reason = call_frame->argument(0);
    JSValue cancel_result = JSC::jsUndefined();
    JSValue cancel = stream->cancelCallback();
    JSValue transformer = stream->transformer();
    stream->clearAlgorithms();
    if (valueIsCallable(cancel)) {
        JSC::MarkedArgumentBuffer arguments;
        arguments.append(reason);
        if (arguments.hasOverflowed()) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return {};
        }
        auto call_data = JSC::getCallData(cancel);
        cancel_result = JSC::call(global_object, cancel.getObject(), call_data, transformer, arguments);
        RETURN_IF_EXCEPTION(scope, {});
    }
    stream->error(global_object, reason);
    return JSValue::encode(cancel_result);
}

JSC_DEFINE_HOST_FUNCTION(transformStreamConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "TransformStream constructor requires 'new'"_s);
}

JSC_DEFINE_HOST_FUNCTION(
    transformStreamConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    JSValue transformer = call_frame->argument(0);
    if (transformer.isUndefined() || transformer.isNull())
        transformer = JSC::constructEmptyObject(global_object);
    if (!transformer.isObject()) {
        JSC::throwVMTypeError(global_object, scope, "TransformStream transformer must be an object"_s);
        return {};
    }

    // Web IDL argument conversion reads the writable strategy, then the
    // readable strategy, before the constructor steps convert the
    // transformer dictionary, whose members are read in lexicographic
    // order: cancel, flush, readableType, start, transform, writableType.
    // Defined readableType/writableType reject only after the conversion.
    bool has_writable_high_water_mark = false;
    double writable_high_water_mark = 0;
    JSValue writable_size = JSC::jsUndefined();
    if (!parseQueuingStrategy(global_object, scope, call_frame->argument(1), "TransformStream writable"_s,
            has_writable_high_water_mark, writable_high_water_mark, writable_size))
        return {};
    RETURN_IF_EXCEPTION(scope, {});
    bool has_readable_high_water_mark = false;
    double readable_high_water_mark = 0;
    JSValue readable_size = JSC::jsUndefined();
    if (!parseQueuingStrategy(global_object, scope, call_frame->argument(2), "TransformStream readable"_s,
            has_readable_high_water_mark, readable_high_water_mark, readable_size))
        return {};
    RETURN_IF_EXCEPTION(scope, {});

    auto* transformer_object = transformer.getObject();
    JSValue cancel = JSC::jsUndefined();
    if (!strictCallbackPropertyOrUndefined(
            global_object, scope, transformer_object, "cancel"_s, "TransformStream cancel"_s, cancel))
        return {};
    RETURN_IF_EXCEPTION(scope, {});
    JSValue flush = JSC::jsUndefined();
    if (!strictCallbackPropertyOrUndefined(
            global_object, scope, transformer_object, "flush"_s, "TransformStream flush"_s, flush))
        return {};
    RETURN_IF_EXCEPTION(scope, {});
    JSValue readable_type
        = transformer_object->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "readableType"_s));
    RETURN_IF_EXCEPTION(scope, {});
    JSValue start = JSC::jsUndefined();
    if (!strictCallbackPropertyOrUndefined(
            global_object, scope, transformer_object, "start"_s, "TransformStream start"_s, start))
        return {};
    RETURN_IF_EXCEPTION(scope, {});
    JSValue transform = JSC::jsUndefined();
    if (!strictCallbackPropertyOrUndefined(
            global_object, scope, transformer_object, "transform"_s, "TransformStream transform"_s, transform))
        return {};
    RETURN_IF_EXCEPTION(scope, {});
    JSValue writable_type
        = transformer_object->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "writableType"_s));
    RETURN_IF_EXCEPTION(scope, {});

    if (!readable_type.isEmpty() && !readable_type.isUndefined()) {
        JSC::throwException(
            global_object, scope, JSC::createRangeError(global_object, "TransformStream readableType is invalid"_s));
        return {};
    }
    if (!writable_type.isEmpty() && !writable_type.isUndefined()) {
        JSC::throwException(
            global_object, scope, JSC::createRangeError(global_object, "TransformStream writableType is invalid"_s));
        return {};
    }
    if (!validateHighWaterMark(global_object, scope, "TransformStream readable"_s, has_readable_high_water_mark, 0,
            readable_high_water_mark))
        return {};
    if (!validateHighWaterMark(global_object, scope, "TransformStream writable"_s, has_writable_high_water_mark, 1,
            writable_high_water_mark))
        return {};

    auto* transform_structure
        = streamStructureForNewTarget(global_object, scope, call_frame, collo_global->transformStreamStructure());
    RETURN_IF_EXCEPTION(scope, {});
    auto* transform_stream = JSColloTransformStream::createWithStructure(vm, transform_structure);
    auto* transform_controller = JSColloTransformStreamDefaultController::create(vm, global_object, transform_stream);
    transform_stream->setTransformer(vm, transformer);
    transform_stream->setCallbacks(vm, start, transform, flush, cancel);
    transform_stream->setController(vm, transform_controller);

    auto* readable = JSColloReadableStream::create(vm, collo_global);
    auto* readable_controller = JSColloReadableStreamDefaultController::create(vm, global_object, readable);
    readable->setController(vm, readable_controller);
    readable->setHighWaterMark(readable_high_water_mark);
    JSValue readable_pull = createTransformCallback(
        global_object, transform_stream, "TransformStream readable pull"_s, transformReadablePullCallback, 1);
    JSValue readable_cancel = createTransformCallback(
        global_object, transform_stream, "TransformStream readable cancel"_s, transformReadableCancelCallback, 1);
    readable_controller->setCallbacks(vm, readable_pull, readable_cancel, readable_size);
    transform_stream->setReadable(vm, readable);
    // InitializeTransformStream sets backpressure and the readable side's
    // first pull clears it. With a positive readable high-water mark that pull
    // follows start at once, so writes may proceed from the beginning.
    transform_stream->setBackpressure(!(readable_high_water_mark > 0));

    JSValue start_function = createTransformCallback(
        global_object, transform_stream, "TransformStream start"_s, transformStartCallback, 1);
    JSValue write_function = createTransformCallback(
        global_object, transform_stream, "TransformStream write"_s, transformWriteCallback, 2);
    JSValue close_function = createTransformCallback(
        global_object, transform_stream, "TransformStream close"_s, transformCloseCallback, 0);
    JSValue abort_function = createTransformCallback(
        global_object, transform_stream, "TransformStream abort"_s, transformAbortCallback, 1);
    auto* writable = createWritableStreamFromCallbacks(global_object, scope, start_function, write_function,
        close_function, abort_function, writable_size, writable_high_water_mark);
    RETURN_IF_EXCEPTION(scope, {});
    if (!writable)
        return {};
    transform_stream->setWritable(vm, writable);
    return JSValue::encode(transform_stream);
}

JSC_DEFINE_HOST_FUNCTION(transformStreamGetReadable, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream = requireTransformStream(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(stream->readable());
}

JSC_DEFINE_HOST_FUNCTION(transformStreamGetWritable, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream = requireTransformStream(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(stream->writable());
}

JSC_DEFINE_HOST_FUNCTION(transformControllerConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "TransformStreamDefaultController constructor is not public"_s);
}

JSC_DEFINE_HOST_FUNCTION(
    transformControllerConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "TransformStreamDefaultController constructor is not public"_s);
}

JSC_DEFINE_HOST_FUNCTION(transformControllerEnqueue, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* controller = requireTransformStreamDefaultController(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    if (auto* stream = controller->transformStream())
        stream->enqueue(global_object, scope, call_frame->argument(0));
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(transformControllerError, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* controller = requireTransformStreamDefaultController(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    if (auto* stream = controller->transformStream())
        stream->error(global_object, call_frame->argument(0));
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(
    transformControllerTerminate, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* controller = requireTransformStreamDefaultController(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    if (auto* stream = controller->transformStream())
        stream->terminate(global_object);
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(
    transformControllerDesiredSize, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* controller = requireTransformStreamDefaultController(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    auto* stream = controller->transformStream();
    if (!stream || !stream->readable())
        return JSValue::encode(JSC::jsNull());
    if (stream->readable()->state() == StreamState::Errored)
        return JSValue::encode(JSC::jsNull());
    if (stream->readable()->state() == StreamState::Closed)
        return JSValue::encode(JSC::jsNumber(0));
    return JSValue::encode(JSC::jsNumber(stream->readable()->desiredSize()));
}
} // namespace Collo::HostFunctions
