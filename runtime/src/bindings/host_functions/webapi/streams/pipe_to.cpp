// ReadableStreamPipeTo, which pipeTo and pipeThrough share, as one JSColloPipeToState per pipe. Runs on the VM thread,
// except visitChildren, which collector threads run concurrently.
//
// The pipe applies the standard's four shutdown conditions in its order (the source errored, the destination errored,
// the source closed, the destination closing or closed) before every read and whenever a stream may have changed: when
// the source reader's closed promise, the destination writer's closed promise or a ready promise it waits on settles,
// and when a read or write it issued settles. It reads only while the destination is writable with a positive desired
// size, waits on the writer's ready promise otherwise, and holds the source back while it pipes so that only its own
// reads pull.
//
// A shutdown first lets the chunks already read reach the destination, while the destination is writable with no close
// queued: it waits for the pipe's writes and for a read whose result has arrived, and writes that chunk too. Only then
// does its action run (an abort, a cancel or a close). The pipe settles once every action promise fulfills, or as soon
// as one rejects, with that rejection's reason. Once a shutdown has begun, later conditions and the signal change
// nothing, so a source that closed before the signal aborted still closes the destination.

#include "host_functions/webapi/streams/pipe_to_private.h"

namespace Collo::HostFunctions {
namespace {

    JSC::JSValue valueOrUndefined(JSC::JSValue value) { return value ? value : JSC::jsUndefined(); }

} // namespace

JSColloPipeToState* JSColloPipeToState::create(JSC::VM& vm, JSC::JSGlobalObject* global_object,
    JSColloReadableStream* source, JSColloWritableStream* destination, JSColloReadableStreamDefaultReader* reader,
    JSColloWritableStreamDefaultWriter* writer)
{
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto* object = new (NotNull, JSC::allocateCell<JSColloPipeToState>(vm))
        JSColloPipeToState(vm, collo_global->pipeToStateStructure());
    object->finishCreation(vm, global_object, source, destination, reader, writer);
    return object;
}

void JSColloPipeToState::finishCreation(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSColloReadableStream* source,
    JSColloWritableStream* destination, JSColloReadableStreamDefaultReader* reader,
    JSColloWritableStreamDefaultWriter* writer)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
    m_source.set(vm, this, source);
    m_destination.set(vm, this, destination);
    m_reader.set(vm, this, reader);
    m_writer.set(vm, this, writer);
    m_promise.set(vm, this, Collo::newPromise(global_object));
}

void JSColloPipeToState::detachSignal()
{
    if (auto* signal = m_signal.get())
        signal->removeInternalAbortAlgorithm(signalAborted, this);
    m_signal.clear();
}

void JSColloPipeToState::finalize(JSC::JSGlobalObject* global_object)
{
    m_phase = Phase::Settled;
    if (auto* source = m_source.get())
        source->setPipeBackpressure(false);
    if (auto* writer = m_writer.get()) {
        m_writer.clear();
        writer->release(global_object);
    }
    if (auto* reader = m_reader.get()) {
        m_reader.clear();
        reader->release(global_object);
    }
    detachSignal();
    m_source.clear();
    m_destination.clear();
    m_read_promise.clear();
    m_awaited_ready.clear();
    m_shutdown_error.clear();
    m_writes_in_flight = 0;
    m_shutdown_pending = 0;
}

void JSColloPipeToState::settle(JSC::JSGlobalObject* global_object, JSC::JSValue value, bool is_rejection)
{
    if (m_phase == Phase::Settled)
        return;
    finalize(global_object);
    settleAndClearPromise(global_object, m_promise, value, is_rejection);
}

void JSColloPipeToState::abandonStartFailure(JSC::JSGlobalObject* global_object)
{
    if (m_phase == Phase::Settled)
        return;
    finalize(global_object);
    m_promise.clear();
}

bool JSColloPipeToState::applyShutdownConditions(JSC::JSGlobalObject* global_object)
{
    if (m_phase != Phase::Piping)
        return true;
    auto* source = m_source.get();
    auto* destination = m_destination.get();
    if (source->state() == StreamState::Errored)
        shutdownForSourceError(global_object, valueOrUndefined(source->storedError()));
    else if (destination->state() == WritableState::Errored)
        shutdownForDestinationError(global_object, valueOrUndefined(destination->storedError()));
    else if (source->state() == StreamState::Closed)
        shutdownForSourceClose(global_object);
    else if (destination->closeRequested() || destination->state() == WritableState::Closed)
        shutdownForDestinationClose(global_object);
    return m_phase != Phase::Piping;
}

void JSColloPipeToState::shutdownForSourceError(JSC::JSGlobalObject* global_object, JSC::JSValue error)
{
    beginShutdown(global_object, m_prevent_abort ? ShutdownAction::None : ShutdownAction::AbortDestination, error);
}

void JSColloPipeToState::shutdownForDestinationError(JSC::JSGlobalObject* global_object, JSC::JSValue error)
{
    beginShutdown(global_object, m_prevent_cancel ? ShutdownAction::None : ShutdownAction::CancelSource, error);
}

void JSColloPipeToState::shutdownForSourceClose(JSC::JSGlobalObject* global_object)
{
    beginShutdown(global_object, m_prevent_close ? ShutdownAction::None : ShutdownAction::CloseDestination, {});
}

void JSColloPipeToState::shutdownForDestinationClose(JSC::JSGlobalObject* global_object)
{
    // Only the pipe's own writer can close the destination while the pipe holds it, and it does so only in a shutdown,
    // so a destination closed or closing means one that was before the pipe started.
    auto* error = JSC::createTypeError(global_object, "pipeTo destination closed before the source finished"_s);
    beginShutdown(global_object, m_prevent_cancel ? ShutdownAction::None : ShutdownAction::CancelSource, error);
}

void JSColloPipeToState::beginShutdown(JSC::JSGlobalObject* global_object, ShutdownAction action, JSC::JSValue error)
{
    if (m_phase != Phase::Piping)
        return;
    m_shutdown_action = action;
    m_shutdown_has_error = !!error;
    if (error)
        m_shutdown_error.set(global_object->vm(), this, error);
    m_source->setPipeBackpressure(false);
    // A destination that can no longer take writes would only reject the chunks already read, so the action runs at
    // once.
    auto* destination = m_destination.get();
    if (destination->state() == WritableState::Writable && !destination->closeRequested()) {
        m_phase = Phase::FinishingWrites;
        continueShutdown(global_object);
        return;
    }
    runShutdownAction(global_object);
}

void JSColloPipeToState::continueShutdown(JSC::JSGlobalObject* global_object)
{
    if (m_phase != Phase::FinishingWrites)
        return;
    // A settled read holds a chunk already taken from the source, which must be written too; its reaction is queued
    // and calls back here. A pending read is not waited for, since only the action may end it.
    auto* read_promise = m_read_promise.get();
    if (m_writes_in_flight || (read_promise && !promiseIsPending(read_promise)))
        return;
    runShutdownAction(global_object);
}

void JSColloPipeToState::runShutdownAction(JSC::JSGlobalObject* global_object)
{
    m_phase = Phase::RunningAction;
    m_shutdown_pending = 0;
    auto scope = DECLARE_THROW_SCOPE(global_object->vm());
    auto* source = m_source.get();
    auto* destination = m_destination.get();
    JSC::JSValue error = valueOrUndefined(m_shutdown_error.get());
    // The pipe waits for every action, as it would for all of their promises, so an action that throws counts as one
    // whose promise rejected with the exception. The first rejection settles the pipe.
    JSC::JSValue failure;
    // Returns false when a termination is pending.
    auto await_action = [&](JSC::EncodedJSValue result) {
        if (scope.exception()) {
            JSC::JSValue exception = scope.exception()->value();
            if (!scope.tryClearException())
                return false;
            if (!failure)
                failure = exception;
            return true;
        }
        if (auto* promise = dynamicDowncast<JSC::JSPromise>(JSC::JSValue::decode(result))) {
            m_shutdown_pending++;
            reactToPromise(global_object, promise, StreamReaction::PipeShutdown, this);
        }
        return true;
    };

    switch (m_shutdown_action) {
    case ShutdownAction::None:
        break;
    case ShutdownAction::AbortDestination:
        if (!await_action(destination->abort(global_object, scope, error)))
            return;
        break;
    case ShutdownAction::CancelSource:
        if (!await_action(source->cancel(global_object, scope, error)))
            return;
        break;
    case ShutdownAction::CloseDestination:
        // A destination already closed or closing counts as closed, and an errored one gives its stored error.
        if (destination->closeRequested() || destination->state() == WritableState::Closed)
            break;
        if (destination->state() == WritableState::Errored) {
            failure = valueOrUndefined(destination->storedError());
            break;
        }
        if (!await_action(destination->close(global_object, scope)))
            return;
        break;
    case ShutdownAction::AbortSignal:
        // Each action checks its stream when it runs, after the action before it has run script.
        if (!m_prevent_abort && destination->state() == WritableState::Writable
            && !await_action(destination->abort(global_object, scope, error)))
            return;
        if (!m_prevent_cancel && source->state() == StreamState::Readable
            && !await_action(source->cancel(global_object, scope, error)))
            return;
        break;
    }

    if (failure)
        settle(global_object, failure, true);
    else if (!m_shutdown_pending)
        finishShutdown(global_object);
}

void JSColloPipeToState::finishShutdown(JSC::JSGlobalObject* global_object)
{
    if (m_shutdown_has_error)
        settle(global_object, valueOrUndefined(m_shutdown_error.get()), true);
    else
        settle(global_object, JSC::jsUndefined(), false);
}

void JSColloPipeToState::shutdownActionSettled(JSC::JSGlobalObject* global_object)
{
    if (m_phase != Phase::RunningAction)
        return;
    if (m_shutdown_pending)
        m_shutdown_pending--;
    if (!m_shutdown_pending)
        finishShutdown(global_object);
}

void JSColloPipeToState::shutdownActionRejected(JSC::JSGlobalObject* global_object, JSC::JSValue reason)
{
    // The first rejection settles the pipe without waiting for the other action.
    if (m_phase == Phase::RunningAction)
        settle(global_object, reason, true);
}

void JSColloPipeToState::start(JSC::JSGlobalObject* global_object)
{
    if (applyShutdownConditions(global_object))
        return;
    // Every condition can come to hold later but the destination closing. A closed promise settles when its stream
    // closes or errors, so the pipe checks again even while it waits on nothing else, such as a source that idles.
    if (auto* closed = dynamicDowncast<JSC::JSPromise>(m_reader->closedPromise()); promiseIsPending(closed))
        reactToPromise(global_object, closed, StreamReaction::PipeStreamChange, this);
    if (auto* closed = dynamicDowncast<JSC::JSPromise>(m_writer->closedPromise()); promiseIsPending(closed))
        reactToPromise(global_object, closed, StreamReaction::PipeStreamChange, this);
    // With pipe backpressure set, the source pulls only to serve a read request
    // (JSColloReadableStreamController::shouldCallPull), not to refill its queue toward its high-water mark.
    m_source->setPipeBackpressure(true);
    advance(global_object);
}

void JSColloPipeToState::advance(JSC::JSGlobalObject* global_object)
{
    if (applyShutdownConditions(global_object) || m_read_promise.get())
        return;
    // An erroring destination has no desired size; its writer's closed promise rejects once it has errored.
    auto* destination = m_destination.get();
    if (destination->state() != WritableState::Writable)
        return;
    if (destination->desiredSize() <= 0) {
        awaitReady(global_object);
        return;
    }

    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSC::JSValue read_value = JSC::JSValue::decode(m_source->read(global_object, scope));
    if (scope.exception()) {
        JSC::JSValue exception = scope.exception()->value();
        if (!scope.tryClearException())
            return;
        shutdownForSourceError(global_object, exception);
        return;
    }
    // The source's pull is script, which may have aborted the signal and so settled the pipe.
    if (m_phase == Phase::Settled)
        return;
    auto* read_promise = dynamicDowncast<JSC::JSPromise>(read_value);
    if (!read_promise) {
        shutdownForSourceError(global_object, JSC::createTypeError(global_object, "pipeTo read failed"_s));
        return;
    }
    m_read_promise.set(vm, this, read_promise);
    reactToPromise(global_object, read_promise, StreamReaction::PipeRead, this);
}

void JSColloPipeToState::awaitReady(JSC::JSGlobalObject* global_object)
{
    // The writer keeps its ready promise pending while the desired size is not positive and fulfills it once the size
    // turns positive again. Each pending promise gets one reaction, and a settled one none, since reacting to it would
    // wake the pipe at once with nothing changed.
    auto* ready = dynamicDowncast<JSC::JSPromise>(m_writer->readyPromise());
    if (!promiseIsPending(ready) || ready == m_awaited_ready.get())
        return;
    m_awaited_ready.set(global_object->vm(), this, ready);
    reactToPromise(global_object, ready, StreamReaction::PipeStreamChange, this);
}

void JSColloPipeToState::writeChunk(JSC::JSGlobalObject* global_object, JSC::JSValue chunk)
{
    auto scope = DECLARE_THROW_SCOPE(global_object->vm());
    JSC::JSValue write_value = JSC::JSValue::decode(m_destination->write(global_object, scope, chunk));
    if (scope.exception()) {
        JSC::JSValue exception = scope.exception()->value();
        if (!scope.tryClearException())
            return;
        shutdownForDestinationError(global_object, exception);
        return;
    }
    if (auto* write_promise = dynamicDowncast<JSC::JSPromise>(write_value)) {
        m_writes_in_flight++;
        reactToPromise(global_object, write_promise, StreamReaction::PipeWrite, this);
    }
}

void JSColloPipeToState::resume(JSC::JSGlobalObject* global_object)
{
    if (m_phase == Phase::FinishingWrites)
        continueShutdown(global_object);
    else
        advance(global_object);
}

void JSColloPipeToState::readFulfilled(JSC::JSGlobalObject* global_object, JSC::JSValue result)
{
    m_read_promise.clear();
    if (m_phase != Phase::Piping && m_phase != Phase::FinishingWrites)
        return;
    bool done = false;
    JSC::JSValue error;
    if (!readResultDone(global_object, result, done, error)) {
        shutdownForSourceError(global_object, error);
    } else if (!done) {
        // The chunk has left the source, so it is written before the conditions are checked again, and a shutdown
        // that began while the read was pending waits for it.
        writeChunk(global_object, readResultValue(global_object, result));
    } else if (!applyShutdownConditions(global_object)) {
        // A done result means the source closed; the reaction to its reader's closed promise normally applied that
        // condition first.
        shutdownForSourceClose(global_object);
    }
    resume(global_object);
}

void JSColloPipeToState::readRejected(JSC::JSGlobalObject* global_object, JSC::JSValue reason)
{
    m_read_promise.clear();
    // A rejected read means the source errored, which the conditions find.
    if (!applyShutdownConditions(global_object))
        shutdownForSourceError(global_object, reason);
    resume(global_object);
}

void JSColloPipeToState::writeSettled(JSC::JSGlobalObject* global_object)
{
    if (m_writes_in_flight)
        m_writes_in_flight--;
    resume(global_object);
}

void JSColloPipeToState::abortFromSignal(JSC::JSGlobalObject* global_object, JSC::JSValue reason)
{
    beginShutdown(global_object, ShutdownAction::AbortSignal, valueOrUndefined(reason));
}

void JSColloPipeToState::signalAborted(JSC::JSObject* context)
{
    auto* pipe = uncheckedDowncast<JSColloPipeToState>(context);
    // A pipe that settled while the signal ran its abort algorithms still gets this call, since a removal during the
    // run takes effect only after it; settling dropped the signal, and nothing is left to shut down.
    auto* signal = pipe->m_signal.get();
    if (!signal)
        return;
    pipe->abortFromSignal(pipe->globalObject(), signal->reason());
}

namespace {

    bool pipeToOptionBoolean(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* options, WTF::ASCIILiteral name)
    {
        JSC::JSValue value
            = options->getIfPropertyExists(global_object, JSC::Identifier::fromString(global_object->vm(), name));
        RETURN_IF_EXCEPTION(scope, false);
        if (value.isEmpty() || value.isUndefined())
            return false;
        bool result = value.toBoolean(global_object);
        RETURN_IF_EXCEPTION(scope, false);
        return result;
    }

    // Lives on the stack, which roots `signal`.
    struct PipeToOptions {
        JSColloAbortSignal* signal { nullptr };
        bool prevent_close { false };
        bool prevent_abort { false };
        bool prevent_cancel { false };
    };

    bool parsePipeToOptions(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value, PipeToOptions& out)
    {
        if (value.isUndefinedOrNull())
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

        JSC::JSValue signal = options->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "signal"_s));
        RETURN_IF_EXCEPTION(scope, false);
        if (signal.isEmpty() || signal.isUndefined())
            return true;
        auto* abort_signal = webApiAbortSignalFromValue(signal);
        if (!abort_signal) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream pipeTo signal must be an AbortSignal"_s);
            return false;
        }
        out.signal = abort_signal;
        return true;
    }

} // namespace

JSC::EncodedJSValue startReadablePipeTo(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSColloReadableStream* source, JSColloWritableStream* destination, JSC::JSValue options, PipeToErrors errors)
{
    auto& vm = global_object->vm();
    // Web IDL converts the options before the method's steps check the locks.
    PipeToOptions parsed_options;
    if (!parsePipeToOptions(global_object, scope, options, parsed_options)) {
        if (errors == PipeToErrors::Throw || !scope.exception())
            return {};
        JSC::JSValue exception = scope.exception()->value();
        if (!scope.tryClearException())
            return {};
        return rejectedPromise(global_object, exception);
    }
    if (source->locked() || destination->locked()) {
        auto message = source->locked() ? "ReadableStream is already locked"_s : "WritableStream is already locked"_s;
        if (errors == PipeToErrors::Reject)
            return rejectedTypeError(global_object, scope, message);
        return JSC::throwVMTypeError(global_object, scope, message);
    }

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
    state->setOptions(parsed_options.prevent_close, parsed_options.prevent_abort, parsed_options.prevent_cancel);
    // ReadableStreamPipeTo marks the source disturbed before anything else, so a pipe that never reads, because its
    // signal has already aborted or its destination never has room, leaves it disturbed too.
    source->markDisturbed();

    // Read before the pipe starts: a pipe that settles at once drops its promise.
    JSC::JSValue pipe_promise = state->promise();
    if (auto* signal = parsed_options.signal) {
        state->setSignal(vm, signal);
        if (signal->aborted()) {
            state->abortFromSignal(global_object, signal->reason());
            RETURN_IF_EXCEPTION(scope, {});
            return JSC::JSValue::encode(pipe_promise);
        }
        if (!signal->addInternalAbortAlgorithm(vm, global_object, scope, JSColloPipeToState::signalAborted, state)) {
            state->abandonStartFailure(global_object);
            return {};
        }
        RETURN_IF_EXCEPTION(scope, {});
    }

    state->start(global_object);
    RETURN_IF_EXCEPTION(scope, {});
    return JSC::JSValue::encode(pipe_promise);
}

const JSC::ClassInfo JSColloPipeToState::s_info
    = { "ReadableStreamPipeToState"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloPipeToState) };

template <typename Visitor> void JSColloPipeToState::visitChildrenImpl(JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloPipeToState*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_source);
    visitor.append(this_object->m_destination);
    visitor.append(this_object->m_reader);
    visitor.append(this_object->m_writer);
    visitor.append(this_object->m_promise);
    visitor.append(this_object->m_signal);
    visitor.append(this_object->m_read_promise);
    visitor.append(this_object->m_awaited_ready);
    visitor.append(this_object->m_shutdown_error);
}

DEFINE_VISIT_CHILDREN(JSColloPipeToState);

} // namespace Collo::HostFunctions
