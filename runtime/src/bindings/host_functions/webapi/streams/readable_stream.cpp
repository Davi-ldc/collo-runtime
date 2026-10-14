// The core ReadableStream algorithms of the WHATWG Streams Standard for the cells in readable_stream_private.h: the
// controllers' pull and cancel dispatch, default reads, cancel, close and error, the readers, and the pump of a native
// source. BYOB reads live in readable_byte_stream.cpp, the tee in readable_stream_tee.cpp and ReadableStream.from in
// readable_stream_from.cpp. Runs on the VM thread.
//
// Exceptions from user code are cleared with tryClearException() or clearExceptionExceptTermination(), which leave a
// termination pending; a failed clear, or a false result from a settle, returns at once without entering JavaScript.
// The pull timing keeps the bridge's established order: a source is pulled after start, when a read finds the queue
// empty, and again only when a read asked for more during a pull or an asynchronous pull produced something; an
// enqueue never pulls by itself. An object a pull returns is converted as Web IDL converts a Promise<undefined>
// result, so a thenable is adopted and the pull completes when it settles. Any other result completes the pull at once
// rather than a microtask later, so a synchronous pull that enqueues does not pull again to fill the queue, and a pull
// a read asked for meanwhile starts from callPullIfNeeded's loop, never from inside the pull that completed.
//
// Every call into a native source holds a protecting reference to it: a call that runs script can cancel or error the
// stream, which releases the source. A canceled stream keeps its source attached, and so visited by the collector,
// until the source's cancel returns, because closing the stream first settles pending reads, which can run script and
// collect, and the source's cancel may still use the cells it holds.

#include "host_functions/webapi/streams/readable_stream_private.h"

#include "host_functions/webapi/streams/transform_stream_private.h"

#include <wtf/Scope.h>

namespace Collo::HostFunctions {

void JSColloReadableStreamController::finishCreation(JSC::VM& vm, JSColloReadableStream* stream)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
    m_stream.set(vm, this, stream);
    m_source.set(vm, this, JSC::jsUndefined());
    m_pull.set(vm, this, JSC::jsUndefined());
    m_cancel.set(vm, this, JSC::jsUndefined());
}

void JSColloReadableStreamController::setJavaScriptSource(
    JSC::VM& vm, JSC::JSValue source, JSC::JSValue pull, JSC::JSValue cancel)
{
    m_source_kind = SourceKind::JavaScript;
    m_source.set(vm, this, source);
    m_pull.set(vm, this, pull);
    m_cancel.set(vm, this, cancel);
}

void JSColloReadableStreamController::setNativeSource(JSC::VM& vm, SourceKind kind, JSC::JSCell* owner)
{
    ASSERT(kind != SourceKind::JavaScript);
    m_source_kind = kind;
    m_source.set(vm, this, owner);
}

void JSColloReadableStreamController::clearAlgorithms()
{
    m_source.setUndefined();
    m_pull.setUndefined();
    m_cancel.setUndefined();
    if (auto* default_controller = dynamicDowncast<JSColloReadableStreamDefaultController>(this))
        default_controller->clearSizeCallback();
}

void JSColloReadableStreamController::startWith(JSC::JSGlobalObject* global_object, JSC::JSPromise* start_promise)
{
    m_starting = true;
    reactToPromise(global_object, start_promise, StreamReaction::ReadableStart, this);
}

void JSColloReadableStreamController::startFinished(JSC::JSGlobalObject* global_object)
{
    m_starting = false;
    callPullIfNeeded(global_object);
}

void JSColloReadableStreamController::startFailed(JSC::JSGlobalObject* global_object, JSC::JSValue reason)
{
    m_starting = false;
    if (auto* current_stream = stream())
        current_stream->error(global_object, reason);
}

bool JSColloReadableStreamController::shouldCallPull() const
{
    auto* current_stream = stream();
    if (!current_stream || current_stream->state() != StreamState::Readable)
        return false;
    if (m_starting || current_stream->closeRequested())
        return false;
    // pipeTo holds its source back so that only its own reads pull.
    if (current_stream->pipeBackpressure() && !current_stream->hasPendingReadRequests())
        return false;
    if (current_stream->isByteStream())
        return current_stream->hasPendingReadRequests() || current_stream->hasPendingByobReadRequests();
    return current_stream->hasPendingReadRequests() || current_stream->desiredSize() > 0;
}

void JSColloReadableStreamController::callPullIfNeeded(JSC::JSGlobalObject* global_object)
{
    if (m_source_kind == SourceKind::Tee) {
        // The tee reads for both branches and keeps its own in-flight flag.
        if (auto* tee = dynamicDowncast<JSColloReadableStreamTeeState>(m_source.get()))
            tee->pump(global_object);
        return;
    }
    // Each iteration is one pull that completed before it returned; a source that answers every pull at once, such
    // as a byte source responding a byte at a time to a large read, loops here instead of nesting a call per pull.
    while (shouldCallPull()) {
        if (m_source_kind == SourceKind::JavaScript && !valueIsCallable(m_pull.get()))
            return;
        if (m_pulling) {
            m_pull_again = true;
            return;
        }
        m_pulling = true;
        m_pull_made_progress = false;
        if (callSourcePull(global_object) != PullOutcome::Returned)
            return;
        m_pulling = false;
        m_pull_made_progress = false;
        if (!m_pull_again)
            return;
        m_pull_again = false;
    }
}

JSColloReadableStreamController::PullOutcome JSColloReadableStreamController::callSourcePull(
    JSC::JSGlobalObject* global_object)
{
    switch (m_source_kind) {
    case SourceKind::JavaScript:
        return callJavaScriptPull(global_object);
    case SourceKind::Transform:
        if (auto* transform = dynamicDowncast<JSColloTransformStream>(m_source.get()))
            transform->sourcePull(global_object);
        return noExceptionPending(global_object->vm()) ? PullOutcome::Returned : PullOutcome::Ended;
    case SourceKind::From:
        if (auto* from = dynamicDowncast<JSColloReadableStreamFromState>(m_source.get())) {
            from->pull(global_object);
            return PullOutcome::Pending;
        }
        break;
    case SourceKind::Tee:
        break;
    }
    m_pulling = false;
    return PullOutcome::Ended;
}

JSColloReadableStreamController::PullOutcome JSColloReadableStreamController::callJavaScriptPull(
    JSC::JSGlobalObject* global_object)
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    JSC::JSValue pull = m_pull.get();
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(this);
    if (arguments.hasOverflowed()) {
        pullFailed(global_object, JSC::createOutOfMemoryError(global_object));
        return PullOutcome::Ended;
    }
    auto call_data = JSC::getCallData(pull);
    JSC::JSValue result = JSC::call(global_object, pull.getObject(), call_data, m_source.get(), arguments);
    if (scope.exception()) {
        JSC::JSValue exception = scope.exception()->value();
        if (!scope.clearExceptionExceptTermination())
            return PullOutcome::Ended;
        pullFailed(global_object, exception);
        return PullOutcome::Ended;
    }
    // A result that is not an object cannot be a thenable, so the pull completes here (see the header).
    if (!result.isObject())
        return PullOutcome::Returned;
    auto* promise = promiseResolvedWith(global_object, result);
    if (scope.exception()) {
        JSC::JSValue exception = scope.exception()->value();
        if (!scope.clearExceptionExceptTermination())
            return PullOutcome::Ended;
        pullFailed(global_object, exception);
        return PullOutcome::Ended;
    }
    reactToPromise(global_object, promise, StreamReaction::ReadablePull, this);
    return PullOutcome::Pending;
}

void JSColloReadableStreamController::pullSettled(JSC::JSGlobalObject* global_object)
{
    const bool pull_again = m_pull_again || m_pull_made_progress;
    m_pulling = false;
    m_pull_again = false;
    m_pull_made_progress = false;
    if (pull_again)
        callPullIfNeeded(global_object);
}

void JSColloReadableStreamController::pullFailed(JSC::JSGlobalObject* global_object, JSC::JSValue reason)
{
    m_pulling = false;
    m_pull_again = false;
    m_pull_made_progress = false;
    if (auto* current_stream = stream())
        current_stream->error(global_object, reason);
}

JSC::JSValue JSColloReadableStreamController::cancelSource(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue reason)
{
    JSC::JSValue result = JSC::jsUndefined();
    switch (m_source_kind) {
    case SourceKind::JavaScript: {
        JSC::JSValue cancel = m_cancel.get();
        if (!valueIsCallable(cancel))
            break;
        JSC::MarkedArgumentBuffer arguments;
        arguments.append(reason);
        if (arguments.hasOverflowed()) {
            clearAlgorithms();
            JSC::throwOutOfMemoryError(global_object, scope);
            return {};
        }
        auto call_data = JSC::getCallData(cancel);
        result = JSC::call(global_object, cancel.getObject(), call_data, m_source.get(), arguments);
        break;
    }
    case SourceKind::Transform:
        if (auto* transform = dynamicDowncast<JSColloTransformStream>(m_source.get()))
            result = transform->sourceCancel(global_object, scope, reason);
        break;
    case SourceKind::Tee:
        if (auto* tee = dynamicDowncast<JSColloReadableStreamTeeState>(m_source.get()))
            result = tee->cancelBranch(global_object, scope, stream(), reason);
        break;
    case SourceKind::From:
        if (auto* from = dynamicDowncast<JSColloReadableStreamFromState>(m_source.get()))
            result = from->cancel(global_object, scope, reason);
        break;
    }
    clearAlgorithms();
    RETURN_IF_EXCEPTION(scope, {});
    return result;
}

JSColloReadableStreamDefaultController* JSColloReadableStreamDefaultController::create(
    JSC::VM& vm, JSC::JSGlobalObject* global_object, JSColloReadableStream* stream)
{
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto* object = new (NotNull, JSC::allocateCell<JSColloReadableStreamDefaultController>(vm))
        JSColloReadableStreamDefaultController(vm, collo_global->readableStreamDefaultControllerStructure());
    object->finishCreation(vm, stream);
    return object;
}

JSColloReadableByteStreamController* JSColloReadableByteStreamController::create(
    JSC::VM& vm, JSC::JSGlobalObject* global_object, JSColloReadableStream* stream)
{
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto* object = new (NotNull, JSC::allocateCell<JSColloReadableByteStreamController>(vm))
        JSColloReadableByteStreamController(vm, collo_global->readableByteStreamControllerStructure());
    object->finishCreation(vm, stream);
    return object;
}

JSColloReadableStreamBYOBRequest* JSColloReadableStreamBYOBRequest::create(
    JSC::VM& vm, JSC::JSGlobalObject* global_object, JSColloReadableStream* stream, JSC::JSArrayBufferView* view)
{
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto* object = new (NotNull, JSC::allocateCell<JSColloReadableStreamBYOBRequest>(vm))
        JSColloReadableStreamBYOBRequest(vm, collo_global->readableStreamBYOBRequestStructure());
    object->finishCreation(vm, stream, view);
    return object;
}

JSColloReadableStreamDefaultReader* JSColloReadableStreamDefaultReader::create(
    JSC::VM& vm, JSC::JSGlobalObject* global_object, JSColloReadableStream* stream)
{
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto* object = new (NotNull, JSC::allocateCell<JSColloReadableStreamDefaultReader>(vm))
        JSColloReadableStreamDefaultReader(vm, collo_global->readableStreamDefaultReaderStructure());
    if (!object->finishCreation(vm, global_object, stream))
        return nullptr;
    return object;
}

bool JSColloReadableStreamDefaultReader::finishCreation(
    JSC::VM& vm, JSC::JSGlobalObject* global_object, JSColloReadableStream* stream)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
    m_stream.set(vm, this, stream);
    m_closed_promise.set(vm, this, Collo::newPromise(global_object));
    if (stream->state() == StreamState::Closed)
        return resolveClosed();
    if (stream->state() == StreamState::Errored)
        return rejectClosed(stream->storedError());
    return true;
}

void JSColloReadableStreamDefaultReader::release(JSC::JSGlobalObject* global_object)
{
    auto* current_stream = stream();
    if (!current_stream)
        return;
    current_stream->unlock();
    m_stream.clear();
    JSC::JSValue error = JSC::createTypeError(global_object, "ReadableStream reader was released"_s);
    if (!ensurePromiseRejected(global_object, this, m_closed_promise, error))
        return;
    current_stream->rejectReadRequests(global_object, error);
}

JSColloReadableStreamBYOBReader* JSColloReadableStreamBYOBReader::create(
    JSC::VM& vm, JSC::JSGlobalObject* global_object, JSColloReadableStreamDefaultReader* default_reader)
{
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto* object = new (NotNull, JSC::allocateCell<JSColloReadableStreamBYOBReader>(vm))
        JSColloReadableStreamBYOBReader(vm, collo_global->readableStreamBYOBReaderStructure());
    object->finishCreation(vm, default_reader);
    return object;
}

void JSColloReadableStreamBYOBReader::release(JSC::JSGlobalObject* global_object)
{
    auto* default_reader = m_default_reader.get();
    if (!default_reader)
        return;
    if (auto* current_stream = default_reader->stream()) {
        if (current_stream->state() == StreamState::Readable) {
            JSC::JSValue error = JSC::createTypeError(global_object, "ReadableStream BYOB reader was released"_s);
            if (!current_stream->rejectByobReadRequests(global_object, error))
                return;
        }
    }
    default_reader->release(global_object);
    m_closed_promise.set(global_object->vm(), this, default_reader->closedPromise());
    m_default_reader.clear();
}

JSColloReadableStreamAsyncIterator* JSColloReadableStreamAsyncIterator::create(
    JSC::VM& vm, Collo::GlobalObject* global_object, JSColloReadableStreamDefaultReader* reader, bool prevent_cancel)
{
    auto* object = new (NotNull, JSC::allocateCell<JSColloReadableStreamAsyncIterator>(vm))
        JSColloReadableStreamAsyncIterator(vm, global_object->readableStreamAsyncIteratorStructure(), prevent_cancel);
    object->finishCreation(vm, reader);
    return object;
}

void JSColloReadableStreamAsyncIterator::releaseReader(JSC::JSGlobalObject* global_object)
{
    auto* current_reader = m_reader.get();
    if (!current_reader)
        return;
    m_reader.clear();
    current_reader->release(global_object);
}

JSColloReadableStreamDefaultController* JSColloReadableStream::defaultController() const
{
    return dynamicDowncast<JSColloReadableStreamDefaultController>(m_controller.get());
}

JSColloReadableByteStreamController* JSColloReadableStream::byteController() const
{
    return dynamicDowncast<JSColloReadableByteStreamController>(m_controller.get());
}

bool JSColloReadableStream::wantsTeeChunk() const
{
    if (m_state != StreamState::Readable)
        return false;
    if (hasReadRequests() || hasByobReadRequests())
        return true;
    if (m_pipe_backpressure || m_close_requested)
        return false;
    return desiredSize() > 0;
}

bool JSColloReadableStream::closeStream(JSC::JSGlobalObject* global_object)
{
    ASSERT(m_state == StreamState::Readable);
    m_state = StreamState::Closed;
    if (auto* current_reader = reader(); current_reader && !current_reader->resolveClosed())
        return false;
    while (hasReadRequests()) {
        if (!fulfillReadRequest(global_object, JSC::jsUndefined(), true))
            return false;
    }
    return true;
}

void JSColloReadableStream::close(JSC::JSGlobalObject* global_object)
{
    if (m_state != StreamState::Readable)
        return;
    if (!queueEmpty()) {
        m_close_requested = true;
        return;
    }
    if (m_is_byte_stream && firstByobReadRequestHasPartialElement()) {
        // ReadableByteStreamControllerClose: a pending read holding part of an element errors the stream.
        error(global_object,
            JSC::createTypeError(global_object, "ReadableStream closed with a partially filled BYOB element"_s));
        return;
    }
    finishClose(global_object);
}

void JSColloReadableStream::finishClose(JSC::JSGlobalObject* global_object)
{
    if (m_state != StreamState::Readable)
        return;
    if (auto* current_controller = controller())
        current_controller->clearAlgorithms();
    releaseNativeSource();
    if (!closeStream(global_object))
        return;
    // Each pending BYOB read ends with the bytes it holds, done.
    while (hasByobReadRequests()) {
        auto scope = DECLARE_THROW_SCOPE(global_object->vm());
        if (settleFirstByobReadRequestWithFilledBytes(global_object, scope, true))
            continue;
        JSC::JSValue error
            = scope.exception() ? scope.exception()->value() : JSC::createOutOfMemoryError(global_object);
        if (scope.exception() && !scope.tryClearException())
            return;
        if (!hasByobReadRequests())
            break;
        auto request = takeFirstByobReadRequest();
        if (!settleByobReadRequest(WTF::move(request), error, true))
            return;
    }
    if (auto* current_controller = byteController())
        current_controller->clearByobRequest();
}

void JSColloReadableStream::error(JSC::JSGlobalObject* global_object, JSC::JSValue error)
{
    if (m_state != StreamState::Readable)
        return;
    clearQueue();
    if (auto* current_controller = controller())
        current_controller->clearAlgorithms();
    m_state = StreamState::Errored;
    m_stored_error.set(global_object->vm(), this, error);
    releaseNativeSource();
    if (auto* current_reader = reader(); current_reader && !current_reader->rejectClosed(error))
        return;
    if (!rejectReadRequests(global_object, error))
        return;
    rejectByobReadRequests(global_object, error);
}

bool JSColloReadableStream::rejectReadRequests(JSC::JSGlobalObject*, JSC::JSValue error)
{
    while (hasReadRequests()) {
        auto request = takeFirstReadRequest();
        if (!settleReadRequest(WTF::move(request), error, true))
            return false;
    }
    return true;
}

bool JSColloReadableStream::fulfillReadRequest(JSC::JSGlobalObject* global_object, JSC::JSValue chunk, bool done)
{
    auto request = takeFirstReadRequest();
    return settleReadRequest(WTF::move(request), readResult(global_object, chunk, done), false);
}

bool JSColloReadableStream::appendReadRequest(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSPromise* promise)
{
    ReadRequest request;
    request.promise.setWithoutWriteBarrier(promise);
    if (!m_read_requests.tryAppend(global_object->vm(), this, WTF::move(request))) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }
    return true;
}

bool JSColloReadableStream::enqueue(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue chunk)
{
    if (m_state != StreamState::Readable) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream is not readable"_s);
        return false;
    }
    if (m_close_requested) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream is closing"_s);
        return false;
    }
    if (auto* current_controller = controller())
        current_controller->notePullProgress();
    if (hasReadRequests())
        return fulfillReadRequest(global_object, chunk, false);

    double size = 1;
    if (auto* current_controller = defaultController()) {
        JSC::JSValue size_callback = current_controller->sizeCallback();
        if (valueIsCallable(size_callback)) {
            JSC::JSValue size_error;
            JSC::MarkedArgumentBuffer arguments;
            arguments.append(chunk);
            if (arguments.hasOverflowed()) {
                size_error = JSC::createOutOfMemoryError(global_object);
            } else {
                auto call_data = JSC::getCallData(size_callback);
                JSC::JSValue size_value
                    = JSC::call(global_object, size_callback.getObject(), call_data, JSC::jsUndefined(), arguments);
                if (scope.exception()) {
                    size_error = scope.exception()->value();
                    if (!scope.tryClearException())
                        return false;
                } else {
                    size = size_value.toNumber(global_object);
                    if (scope.exception()) {
                        size_error = scope.exception()->value();
                        if (!scope.tryClearException())
                            return false;
                    } else if (!std::isfinite(size) || size < 0) {
                        size_error = JSC::createRangeError(
                            global_object, "ReadableStream chunk size must be a finite non-negative number"_s);
                    }
                }
            }
            if (size_error) {
                // ReadableStreamDefaultControllerEnqueue: an invalid size errors the stream and rethrows.
                error(global_object, size_error);
                RETURN_IF_EXCEPTION(scope, false);
                JSC::throwException(global_object, scope, size_error);
                return false;
            }
        }
    }

    // A reentrant size callback may have closed or errored the stream, and ReadableStreamDefaultControllerEnqueue does
    // not check again. The chunk is still queued while a close is only requested; once the stream has left the readable
    // state nothing can read the chunk, so it is dropped.
    if (m_state != StreamState::Readable)
        return true;
    if (hasReadRequests())
        return fulfillReadRequest(global_object, chunk, false);
    return enqueueWithSize(global_object, scope, chunk, size);
}

bool JSColloReadableStream::enqueueWithSize(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue chunk, double size)
{
    QueuedChunk entry;
    entry.value.setWithoutWriteBarrier(chunk);
    entry.size = size;
    if (!m_queue.tryAppend(global_object->vm(), this, WTF::move(entry))) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }
    m_queue_total_size += size;
    return true;
}

bool JSColloReadableStream::dequeue(JSC::JSValue& value)
{
    if (queueEmpty())
        return false;
    auto entry = m_queue.takeFirst(this);
    value = entry.value.get();
    subtractQueueSize(entry.size);
    return true;
}

void JSColloReadableStream::afterDequeue(JSC::JSGlobalObject* global_object)
{
    if (m_close_requested && queueEmpty()) {
        finishClose(global_object);
        return;
    }
    // A tee branch reads ahead for itself while it is below its high-water mark, so it asks after every read.
    auto* current_controller = controller();
    if (queueEmpty()
        || (current_controller && current_controller->sourceKind() == JSColloReadableStreamController::SourceKind::Tee))
        pullIfNeeded(global_object);
}

JSC::EncodedJSValue JSColloReadableStream::read(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    m_disturbed = true;
    if (m_state == StreamState::Closed)
        return readResultPromise(global_object, JSC::jsUndefined(), true);
    if (m_state == StreamState::Errored)
        return rejectedPromise(global_object, scope, storedError());

    JSC::JSValue value;
    const bool has_value = m_is_byte_stream ? dequeueByteValue(global_object, scope, value) : dequeue(value);
    RETURN_IF_EXCEPTION(scope, {});
    if (has_value) {
        afterDequeue(global_object);
        RETURN_IF_EXCEPTION(scope, {});
        return readResultPromise(global_object, value, false);
    }

    if (auto* current_controller = byteController();
        current_controller && current_controller->autoAllocateChunkSize()) {
        // ReadableByteStreamControllerPullSteps with autoAllocateChunkSize: the read becomes a BYOB read into a fresh
        // buffer, which the source fills through byobRequest.
        auto* auto_view = createUint8Array(global_object, scope, current_controller->autoAllocateChunkSize());
        RETURN_IF_EXCEPTION(scope, {});
        auto* byob_request
            = JSColloReadableStreamBYOBRequest::create(global_object->vm(), global_object, this, auto_view);
        auto* byob_promise = Collo::newPromise(global_object);
        if (!appendByobReadRequest(global_object, scope, byob_promise, auto_view, byob_request, 1))
            return {};
        pullIfNeeded(global_object);
        RETURN_IF_EXCEPTION(scope, {});
        return JSC::JSValue::encode(byob_promise);
    }

    auto* promise = Collo::newPromise(global_object);
    if (!appendReadRequest(global_object, scope, promise))
        return {};
    pullIfNeeded(global_object);
    RETURN_IF_EXCEPTION(scope, {});
    return JSC::JSValue::encode(promise);
}

JSC::EncodedJSValue JSColloReadableStream::cancel(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue reason)
{
    m_disturbed = true;
    if (m_state == StreamState::Closed)
        return resolvedPromise(global_object, JSC::jsUndefined());
    if (m_state == StreamState::Errored)
        return rejectedPromise(global_object, scope, storedError());

    // ReadableStreamCancel closes the stream, and ends its pending BYOB reads, before the source's cancel algorithm
    // runs. A native source is released only once its cancel has returned (see the header); the closed state keeps
    // it from being pulled meanwhile.
    auto release_native_source = WTF::makeScopeExit([this] { releaseNativeSource(); });
    m_native_pulling = false;
    clearQueue();
    if (!closeStream(global_object))
        return {};
    if (!closeByobReadRequestsForCancel(global_object))
        return {};

    JSC::JSValue result = JSC::jsUndefined();
    if (WTF::RefPtr<ReadableStreamNativeSource> native_source = m_native_source.get()) {
        result = JSC::JSValue::decode(native_source->cancel(global_object, scope, reason));
    } else if (auto* current_controller = controller()) {
        result = current_controller->cancelSource(global_object, scope, reason);
    }
    if (scope.exception()) {
        JSC::JSValue exception = scope.exception()->value();
        if (!scope.tryClearException())
            return {};
        return rejectedPromise(global_object, scope, exception);
    }
    auto* promise = promiseThenUndefined(global_object, result, this);
    RETURN_IF_EXCEPTION(scope, {});
    return JSC::JSValue::encode(promise);
}

void JSColloReadableStream::pullIfNeeded(JSC::JSGlobalObject* global_object)
{
    if (m_native_source) {
        callNativePullIfNeeded(global_object);
        return;
    }
    if (auto* current_controller = controller())
        current_controller->callPullIfNeeded(global_object);
}

ReadableStreamDrainResult JSColloReadableStream::drainNativeBytes(WTF::Vector<uint8_t>& out, size_t max_size)
{
    if (!m_native_source || m_state != StreamState::Readable)
        return ReadableStreamDrainResult::NotAvailable;
    if (m_disturbed || locked() || !queueEmpty() || hasReadRequests() || m_native_pulling)
        return ReadableStreamDrainResult::NotAvailable;
    bool exceeds_limit = false;
    bool supported = false;
    WTF::RefPtr<ReadableStreamNativeSource> source = m_native_source.get();
    const bool drained = source->appendRemainingBytes(out, max_size, exceeds_limit, supported);
    if (!drained && !supported)
        return ReadableStreamDrainResult::NotAvailable;
    m_disturbed = true;
    m_state = StreamState::Closed;
    releaseNativeSource();
    if (drained)
        return ReadableStreamDrainResult::Drained;
    return exceeds_limit ? ReadableStreamDrainResult::TooLarge : ReadableStreamDrainResult::OutOfMemory;
}

// Pulls while reads wait and the source answers at once. A synchronous source fulfills each pending read in the same
// call, one pull per read; an asynchronous source's promise ends the loop and the NativePull reaction resumes it.
void JSColloReadableStream::callNativePullIfNeeded(JSC::JSGlobalObject* global_object)
{
    auto& vm = global_object->vm();
    while (m_state == StreamState::Readable && m_native_source && !m_native_pulling
        && (hasReadRequests() || hasByobReadRequests())) {
        auto scope = DECLARE_THROW_SCOPE(vm);
        m_native_pulling = true;
        WTF::RefPtr<ReadableStreamNativeSource> source = m_native_source.get();
        ReadableStreamPull pull = source->pull(global_object, scope);
        if (scope.exception() || pull.kind == ReadableStreamPull::Kind::Threw) {
            JSC::JSValue reason = scope.exception()
                ? scope.exception()->value()
                : JSC::createTypeError(global_object, "ReadableStream native source failed to produce a chunk"_s);
            if (scope.exception() && !scope.tryClearException())
                return;
            m_native_pulling = false;
            error(global_object, reason);
            return;
        }
        switch (pull.kind) {
        case ReadableStreamPull::Kind::Pending:
            reactToPromise(global_object, pull.promise, StreamReaction::NativePull, this);
            return;
        case ReadableStreamPull::Kind::Done:
            m_native_pulling = false;
            close(global_object);
            return;
        case ReadableStreamPull::Kind::Chunk:
            m_native_pulling = false;
            if (!deliverNativeChunk(global_object, pull.chunk))
                return;
            break;
        case ReadableStreamPull::Kind::Threw:
            return;
        }
    }
}

void JSColloReadableStream::finishNativePull(JSC::JSGlobalObject* global_object, JSC::JSValue result)
{
    m_native_pulling = false;
    if (m_state != StreamState::Readable)
        return;
    bool done = false;
    JSC::JSValue read_error;
    if (!readResultDone(global_object, result, done, read_error)) {
        error(global_object, read_error);
        return;
    }
    if (done) {
        close(global_object);
        return;
    }
    if (!deliverNativeChunk(global_object, readResultValue(global_object, result)))
        return;
    callNativePullIfNeeded(global_object);
}

void JSColloReadableStream::rejectNativePull(JSC::JSGlobalObject* global_object, JSC::JSValue reason)
{
    m_native_pulling = false;
    error(global_object, reason);
}

bool JSColloReadableStream::deliverNativeChunk(JSC::JSGlobalObject* global_object, JSC::JSValue chunk)
{
    auto& vm = global_object->vm();
    auto* view = dynamicDowncast<JSC::JSArrayBufferView>(chunk);
    if (arrayBufferViewIsUnavailable(view)) {
        error(global_object,
            JSC::createTypeError(global_object, "ReadableStream native byte source returned unavailable byte chunk"_s));
        return noExceptionPending(vm);
    }
    // A chunk a source produced is its own, so a waiting read takes it as it is.
    if (hasReadRequests())
        return fulfillReadRequest(global_object, view, false);

    auto scope = DECLARE_THROW_SCOPE(vm);
    bool delivered = false;
    if (hasByobReadRequests()) {
        delivered = fulfillFirstByobReadRequestWithChunk(global_object, scope, view, 0)
            && drainQueuedBytesIntoByobRequests(global_object, scope);
    } else {
        delivered = enqueueByteChunk(global_object, scope, view);
    }
    if (delivered)
        return true;
    JSC::JSValue reason = scope.exception() ? scope.exception()->value() : JSC::createOutOfMemoryError(global_object);
    if (scope.exception() && !scope.tryClearException())
        return false;
    error(global_object, reason);
    return noExceptionPending(vm);
}

bool JSColloReadableStream::trySplitNativeSource(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    WTF::RefPtr<ReadableStreamNativeSource>& out_first, WTF::RefPtr<ReadableStreamNativeSource>& out_second)
{
    out_first = nullptr;
    out_second = nullptr;
    // Bytes already queued, or the chunk of a pull in flight, which lands in this stream's queue, are not the source's
    // to split: the branches would never see them.
    if (!m_native_source || m_state != StreamState::Readable || !queueEmpty() || m_native_pulling)
        return true;
    WTF::RefPtr<ReadableStreamNativeSource> source = m_native_source.get();
    WTF::RefPtr<ReadableStreamNativeSource> first;
    WTF::RefPtr<ReadableStreamNativeSource> second;
    if (!source->tee(global_object, scope, first, second)) {
        RETURN_IF_EXCEPTION(scope, false);
        return true;
    }
    if (!first || !second) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }
    // Only a split that happened disturbs the stream: one the source refused leaves the source where it was.
    m_disturbed = true;
    out_first = WTF::move(first);
    out_second = WTF::move(second);
    return true;
}

JSColloReadableStream* requireReadableStream(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value)
{
    if (auto* stream = dynamicDowncast<JSColloReadableStream>(value))
        return stream;
    JSC::throwVMTypeError(global_object, scope, "ReadableStream method called on incompatible receiver"_s);
    return nullptr;
}

JSC::JSObject* readableStreamFromValue(JSC::JSValue value)
{
    if (!value || !value.isObject())
        return nullptr;
    return dynamicDowncast<JSColloReadableStream>(value);
}

bool readableStreamIsDisturbed(JSC::JSObject* stream)
{
    auto* readable_stream = dynamicDowncast<JSColloReadableStream>(stream);
    return readable_stream && readable_stream->disturbed();
}

bool readableStreamIsLocked(JSC::JSObject* stream)
{
    auto* readable_stream = dynamicDowncast<JSColloReadableStream>(stream);
    return readable_stream && readable_stream->locked();
}

JSC::JSObject* createReadableStreamFromNativeSource(JSC::JSGlobalObject* global_object, JSC::ThrowScope&,
    WTF::Ref<ReadableStreamNativeSource>&& source, WTF::RefPtr<StreamCloneBudget>&& clone_budget)
{
    auto* stream = JSColloReadableStream::createWithNativeSource(
        global_object->vm(), uncheckedDowncast<Collo::GlobalObject>(global_object), WTF::move(source));
    stream->cloneBudget() = WTF::move(clone_budget);
    return stream;
}

JSC::JSObject* createReadableStreamFromBytes(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const uint8_t> bytes)
{
    auto source = createReadableStreamNativeSourceFromBytes(bytes);
    if (!source) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return nullptr;
    }
    return createReadableStreamFromNativeSource(global_object, scope, source.releaseNonNull());
}

JSC::JSObject* createReadableStreamReadResult(JSC::JSGlobalObject* global_object, JSC::JSValue value, bool done)
{
    return readResult(global_object, value, done);
}

} // namespace Collo::HostFunctions
