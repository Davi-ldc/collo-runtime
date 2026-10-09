// The ReadableStream algorithms of the WHATWG Streams Standard for the cells declared in readable_stream_private.h:
// reads and BYOB reads, cancel, close and error, pulls from an underlying or native source, the tee pump for streams
// without a native source, and ReadableStream.from, with the constructor and BYOB host functions that
// streams_install.cpp registers. Runs on the VM thread.
//
// User code (start, pull, cancel and size callbacks, iterator methods, promise reactions) can re-enter a stream and
// close or error it. close() and error() do nothing once the stream has left the readable state, so code after a call
// into JavaScript may call them without checking again. State that must outlive the current call sits in WriteBarrier
// fields of the owning cell; in the plain state object of a tee or of ReadableStream.from, whose properties are
// non-enumerable; or, for a BYOB read's promise, in a ColloPromiseDeferred whose Strong handles
// readable_stream_private.h describes. A reaction function finds its cell or state object through a non-enumerable
// property of its own. A local Strong here never outlives the call that creates it. Exceptions from user code are
// cleared with tryClearException() or clearExceptionExceptTermination(), which leave a termination pending.

#include "host_functions/webapi/streams/readable_stream_private.h"

namespace Collo::HostFunctions {

JSColloReadableStreamDefaultController* JSColloReadableStreamDefaultController::create(
    JSC::VM& vm, JSC::JSGlobalObject* global_object, JSColloReadableStream* stream)
{
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto* object = new (NotNull, JSC::allocateCell<JSColloReadableStreamDefaultController>(vm))
        JSColloReadableStreamDefaultController(vm, collo_global->readableStreamDefaultControllerStructure());
    object->finishCreation(vm, stream);
    return object;
}

JSColloReadableStreamBYOBRequest* JSColloReadableStreamBYOBRequest::create(
    JSC::VM& vm, JSC::JSGlobalObject* global_object, JSColloReadableStream* stream, JSC::JSArrayBufferView* view)
{
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto* structure = collo_global->webApiCache().readable_stream_byob_request_structure.get();
    RELEASE_ASSERT(structure);
    auto* object = new (NotNull, JSC::allocateCell<JSColloReadableStreamBYOBRequest>(vm))
        JSColloReadableStreamBYOBRequest(vm, structure);
    object->finishCreation(vm, stream, view);
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

JSColloReadableStreamDefaultReader* JSColloReadableStreamDefaultReader::create(
    JSC::VM& vm, JSC::JSGlobalObject* global_object, JSColloReadableStream* stream)
{
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto* object = new (NotNull, JSC::allocateCell<JSColloReadableStreamDefaultReader>(vm))
        JSColloReadableStreamDefaultReader(vm, collo_global->readableStreamDefaultReaderStructure());
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (!object->finishCreation(vm, global_object, scope, stream))
        return nullptr;
    return object;
}

JSColloReadableStreamBYOBReader* JSColloReadableStreamBYOBReader::create(JSC::VM& vm,
    JSC::JSGlobalObject* global_object, JSColloReadableStream*, JSColloReadableStreamDefaultReader* default_reader)
{
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto* object = new (NotNull, JSC::allocateCell<JSColloReadableStreamBYOBReader>(vm))
        JSColloReadableStreamBYOBReader(vm, collo_global->readableStreamBYOBReaderStructure());
    object->finishCreation(vm, default_reader);
    return object;
}

void JSColloReadableStreamDefaultReader::release(JSC::JSGlobalObject* global_object)
{
    auto* current_stream = stream();
    if (!current_stream)
        return;
    JSValue error = JSC::createTypeError(global_object, "ReadableStream reader was released"_s);
    if (current_stream->state() == StreamState::Readable) {
        current_stream->rejectReadRequests(global_object, error);
        rejectClosed(global_object, error);
    }
    current_stream->unlock();
    m_stream.clear();
    // ReadableStreamReaderGenericRelease: after release, closed is a handled promise rejected with a TypeError, even
    // when the previous one had already settled.
    auto* rejected = JSC::JSPromise::rejectedPromise(global_object, error);
    rejected->markAsHandled();
    m_closed_promise.set(global_object->vm(), this, rejected);
}

void JSColloReadableStreamBYOBReader::release(JSC::JSGlobalObject* global_object)
{
    auto* default_reader = m_default_reader.get();
    if (!default_reader)
        return;
    if (auto* current_stream = default_reader->stream()) {
        if (current_stream->state() == StreamState::Readable) {
            JSValue error = JSC::createTypeError(global_object, "ReadableStream BYOB reader was released"_s);
            current_stream->rejectByobReadRequests(global_object, error);
        }
    }
    default_reader->release(global_object);
    m_closed_promise.set(global_object->vm(), this, default_reader->closedPromise());
    m_default_reader.clear();
}

static size_t byobViewElementSize(JSC::JSArrayBufferView*);

void JSColloReadableStream::close(JSC::JSGlobalObject* global_object)
{
    if (m_state != StreamState::Readable)
        return;
    if (!queueEmpty()) {
        if (auto* current_controller = controller())
            current_controller->setCloseRequested(true);
        if (auto* current_byte_controller = byteController())
            current_byte_controller->setCloseRequested(true);
        return;
    }
    if (m_is_byte_stream && hasByobReadRequests()) {
        const auto& pending = m_byob_read_requests[m_byob_read_request_start];
        if (auto* view = pending.view.get();
            !arrayBufferViewIsUnavailable(view) && pending.bytes_filled % byobViewElementSize(view)) {
            // ReadableByteStreamControllerClose: a pending read holding part of an element errors the stream.
            error(global_object,
                JSC::createTypeError(global_object, "ReadableStream closed with a partially filled BYOB element"_s));
            return;
        }
    }
    m_state = StreamState::Closed;
    clearAlgorithms();
    releaseNativeSource();
    while (hasReadRequests()) {
        auto request = takeFirstReadRequest();
        settleReadRequest(
            global_object, WTF::move(request), createReadResult(global_object, JSC::jsUndefined(), true), false);
    }
    while (hasByobReadRequests()) {
        auto scope = DECLARE_THROW_SCOPE(global_object->vm());
        if (!settleFirstByobReadRequestWithFilledBytes(global_object, scope, true)) {
            JSValue error = scope.exception() ? scope.exception()->value() : JSC::createOutOfMemoryError(global_object);
            if (scope.exception() && !scope.tryClearException())
                return;
            auto request = takeFirstByobReadRequest();
            settleByobReadRequest(global_object, WTF::move(request), error, true);
        }
    }
    if (auto* current_controller = byteController())
        current_controller->clearByobRequest();
    if (auto* current_reader = reader())
        current_reader->resolveClosed(global_object);
}

void JSColloReadableStream::error(JSC::JSGlobalObject* global_object, JSValue error)
{
    if (m_state != StreamState::Readable)
        return;
    m_state = StreamState::Errored;
    m_stored_error.set(global_object->vm(), this, error);
    clearQueue();
    clearAlgorithms();
    releaseNativeSource();
    if (auto* current_reader = reader())
        current_reader->rejectClosed(global_object, error);
    while (hasReadRequests()) {
        auto request = takeFirstReadRequest();
        settleReadRequest(global_object, WTF::move(request), error, true);
    }
    rejectByobReadRequests(global_object, error);
}

void JSColloReadableStream::rejectReadRequests(JSC::JSGlobalObject* global_object, JSValue error)
{
    while (hasReadRequests()) {
        auto request = takeFirstReadRequest();
        settleReadRequest(global_object, WTF::move(request), error, true);
    }
}

bool JSColloReadableStream::appendByobReadRequest(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSValue promise, ColloPromiseDeferred* deferred, JSC::JSArrayBufferView* view,
    JSColloReadableStreamBYOBRequest* byob_request, size_t min_bytes)
{
    if (auto* object = promise.getObject()) {
        object->putDirect(global_object->vm(), readableStreamOwnerIdentifier(global_object), this,
            static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    }
    ByobReadRequest request;
    request.deferred = deferred;
    request.promise.set(global_object->vm(), this, promise);
    request.view.set(global_object->vm(), this, view);
    request.min_bytes = std::max<size_t>(1, min_bytes);
    compactByobReadRequestsIfNeeded();
    const bool had_pending_byob_request = hasByobReadRequests();
    bool appended = false;
    {
        WTF::Locker locker { cellLock() };
        appended = m_byob_read_requests.tryAppend(WTF::move(request));
    }
    if (appended) {
        if (had_pending_byob_request)
            byob_request->invalidate();
        else if (auto* current_controller = byteController())
            current_controller->setByobRequest(global_object->vm(), byob_request);
        return true;
    }
    if (auto* object = promise.getObject()) {
        object->putDirect(global_object->vm(), readableStreamOwnerIdentifier(global_object), JSC::jsUndefined(),
            static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    }
    byob_request->invalidate();
    collo_promise_deferred_release(deferred);
    JSC::throwOutOfMemoryError(global_object, scope);
    return false;
}

JSColloReadableStream::ByobReadRequest JSColloReadableStream::takeFirstByobReadRequest()
{
    ASSERT(hasByobReadRequests());
    auto& slot = m_byob_read_requests[m_byob_read_request_start++];
    auto request = WTF::move(slot);
    slot.promise.clear();
    slot.view.clear();
    slot.deferred = nullptr;
    compactByobReadRequestsIfNeeded();
    return request;
}

void JSColloReadableStream::compactByobReadRequestsIfNeeded()
{
    if (!m_byob_read_request_start)
        return;
    if (m_byob_read_request_start >= m_byob_read_requests.size()) {
        WTF::Locker locker { cellLock() };
        m_byob_read_requests.clear();
        m_byob_read_request_start = 0;
        return;
    }
    if (m_byob_read_request_start > 32 && m_byob_read_request_start * 2 >= m_byob_read_requests.size()) {
        WTF::Locker locker { cellLock() };
        m_byob_read_requests.removeAt(0, m_byob_read_request_start);
        m_byob_read_request_start = 0;
    }
}

void JSColloReadableStream::settleByobReadRequest(
    JSC::JSGlobalObject* global_object, ByobReadRequest&& request, JSValue value, bool is_rejection)
{
    if (auto promise = request.promise.get(); promise.isObject()) {
        promise.getObject()->putDirect(global_object->vm(), readableStreamOwnerIdentifier(global_object),
            JSC::jsUndefined(), static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    }
    if (auto* current_controller = byteController()) {
        if (auto* byob_request = current_controller->byobRequest())
            byob_request->invalidate();
        current_controller->clearByobRequest();
    }
    request.promise.clear();
    request.view.clear();
    settleDeferred(global_object, request.deferred, value, is_rejection);
}

void JSColloReadableStream::rejectByobReadRequests(JSC::JSGlobalObject* global_object, JSValue error)
{
    while (hasByobReadRequests()) {
        auto request = takeFirstByobReadRequest();
        settleByobReadRequest(global_object, WTF::move(request), error, true);
    }
    if (auto* current_controller = byteController())
        current_controller->clearByobRequest();
}

static size_t byobViewElementSize(JSC::JSArrayBufferView* view)
{
    const auto type = JSC::typedArrayType(view->type());
    if (type == JSC::NotTypedArray || type == JSC::TypeDataView)
        return 1;
    return JSC::elementSize(type);
}

bool JSColloReadableStream::firstByobReadRequestHasPartialElement() const
{
    if (!hasByobReadRequests())
        return false;
    const auto& pending = m_byob_read_requests[m_byob_read_request_start];
    auto* view = pending.view.get();
    if (arrayBufferViewIsUnavailable(view))
        return false;
    return pending.bytes_filled % byobViewElementSize(view) != 0;
}

bool JSColloReadableStream::pushFrontQueuedByteChunk(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSArrayBufferView* chunk)
{
    if (arrayBufferViewIsUnavailable(chunk)) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream queued byte chunk is unavailable"_s);
        return false;
    }
    const double chunk_size = static_cast<double>(chunk->byteLength());
    const size_t memory_cost = m_queue_memory_cost_limit ? streamChunkMemoryCost(chunk) : 0;
    if (queueMemoryCostWouldExceed(memory_cost)) {
        auto* exception
            = createStreamQueueLimitExceededError(global_object, "Text codec stream queue limit exceeded"_s);
        JSC::throwException(global_object, scope, exception);
        return false;
    }
    QueuedChunk entry;
    entry.value.set(global_object->vm(), this, chunk);
    entry.size = chunk_size;
    entry.memory_cost = memory_cost;
    entry.byte_offset = 0;
    if (m_queue_start > 0) {
        // Slots before m_queue_start were already consumed and cleared; reuse one.
        m_queue[--m_queue_start] = WTF::move(entry);
        m_queue_total_size += chunk_size;
        m_queue_memory_cost += memory_cost;
        return true;
    }
    bool reserved = false;
    {
        WTF::Locker locker { cellLock() };
        reserved = m_queue.tryReserveCapacity(m_queue.size() + 1);
        if (reserved)
            m_queue.insert(0, WTF::move(entry));
    }
    if (!reserved) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }
    m_queue_total_size += chunk_size;
    m_queue_memory_cost += memory_cost;
    return true;
}

bool JSColloReadableStream::refreshFirstByobReadRequest(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    if (!hasByobReadRequests())
        return true;
    auto& pending = m_byob_read_requests[m_byob_read_request_start];
    auto* target = pending.view.get();
    if (arrayBufferViewIsUnavailable(target)) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream BYOB view is detached or out of bounds"_s);
        return false;
    }
    if (pending.bytes_filled >= target->byteLength()) {
        if (auto* current_controller = byteController())
            current_controller->clearByobRequest();
        return true;
    }

    auto* remaining = createUint8ArrayView(
        global_object, scope, target, pending.bytes_filled, target->byteLength() - pending.bytes_filled);
    RETURN_IF_EXCEPTION(scope, false);
    JSC::Strong<JSC::JSArrayBufferView> protected_remaining(global_object->vm(), remaining);
    if (auto* old_request = byteController() ? byteController()->byobRequest() : nullptr)
        old_request->invalidate();
    auto* next_request = JSColloReadableStreamBYOBRequest::create(global_object->vm(), global_object, this, remaining);
    if (auto* current_controller = byteController())
        current_controller->setByobRequest(global_object->vm(), next_request);
    return true;
}

bool JSColloReadableStream::refreshFirstByobReadRequestAndPullIfNeeded(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    if (!refreshFirstByobReadRequest(global_object, scope))
        return false;
    if (hasByobReadRequests() && !firstByobReadRequestIsReady())
        callPullIfNeeded(global_object);
    return true;
}

bool JSColloReadableStream::firstByobReadRequestIsReady() const
{
    if (!hasByobReadRequests())
        return false;
    const auto& pending = m_byob_read_requests[m_byob_read_request_start];
    auto* target = pending.view.get();
    if (arrayBufferViewIsUnavailable(target))
        return true;
    // Only whole elements count toward min_bytes; the bytes of a trailing partial element go back to the queue when
    // the read settles.
    const size_t element_size = byobViewElementSize(target);
    const size_t aligned_filled = pending.bytes_filled - (pending.bytes_filled % element_size);
    return aligned_filled >= pending.min_bytes || pending.bytes_filled >= target->byteLength();
}

bool JSColloReadableStream::settleFirstByobReadRequestWithFilledBytes(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, bool done)
{
    if (!hasByobReadRequests())
        return false;
    auto& pending = m_byob_read_requests[m_byob_read_request_start];
    auto* target = pending.view.get();
    if (arrayBufferViewIsUnavailable(target)) {
        auto request = takeFirstByobReadRequest();
        settleByobReadRequest(global_object, WTF::move(request),
            JSC::createTypeError(global_object, "BYOB view is detached or out of bounds"_s), true);
        if (hasByobReadRequests())
            return refreshFirstByobReadRequest(global_object, scope);
        return true;
    }
    // Only whole elements are delivered. The bytes of a trailing partial element go back to the front of the queue so
    // the next read can complete the element; the final read, with done set, delivers everything.
    const size_t element_size = byobViewElementSize(target);
    const size_t remainder = done ? 0 : pending.bytes_filled % element_size;
    const size_t deliver_bytes = pending.bytes_filled - remainder;
    JSC::JSUint8Array* remainder_chunk = nullptr;
    JSC::Strong<JSC::Unknown> protected_remainder;
    if (remainder) {
        auto remainder_bytes = viewBytes(target).subspan(deliver_bytes, remainder);
        remainder_chunk = createUint8ArrayCopy(global_object, scope, remainder_bytes);
        RETURN_IF_EXCEPTION(scope, false);
        protected_remainder.set(global_object->vm(), remainder_chunk);
    }
    auto* value = transferArrayBufferViewRangeToSameView(
        global_object, scope, target, 0, deliver_bytes, "ReadableStream BYOB view"_s);
    RETURN_IF_EXCEPTION(scope, false);
    JSC::Strong<JSC::Unknown> protected_value(global_object->vm(), value);
    auto request = takeFirstByobReadRequest();
    settleByobReadRequest(global_object, WTF::move(request), createReadResult(global_object, value, done), false);
    if (remainder_chunk && !pushFrontQueuedByteChunk(global_object, scope, remainder_chunk))
        return false;
    if (hasByobReadRequests())
        return refreshFirstByobReadRequestAndPullIfNeeded(global_object, scope);
    return true;
}

bool JSColloReadableStream::fulfillFirstByobReadRequestWithChunk(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSArrayBufferView* chunk, size_t offset)
{
    if (!hasByobReadRequests())
        return false;
    if (arrayBufferViewIsUnavailable(chunk)) {
        JSC::throwVMTypeError(
            global_object, scope, "ReadableByteStreamController chunk is detached or out of bounds"_s);
        return false;
    }
    const size_t chunk_byte_length = chunk->byteLength();
    if (offset > chunk_byte_length) {
        JSC::throwVMTypeError(global_object, scope, "ReadableByteStreamController chunk offset is invalid"_s);
        return false;
    }
    auto& pending = m_byob_read_requests[m_byob_read_request_start];
    auto* target = pending.view.get();
    if (arrayBufferViewIsUnavailable(target)) {
        auto request = takeFirstByobReadRequest();
        settleByobReadRequest(global_object, WTF::move(request),
            JSC::createTypeError(global_object, "BYOB view is detached or out of bounds"_s), true);
        if (hasByobReadRequests())
            return refreshFirstByobReadRequest(global_object, scope);
        return true;
    }
    auto source = viewBytes(chunk).subspan(offset);
    const size_t target_remaining = target->byteLength() - pending.bytes_filled;
    if (source.size() > target_remaining) {
        compactQueueIfNeeded();
        bool reserved = false;
        {
            WTF::Locker locker { cellLock() };
            reserved = m_queue.tryReserveCapacity(m_queue.size() + 1);
        }
        if (!reserved) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
    }

    JSC::JSUint8Array* owned_chunk = nullptr;
    const bool shares_target_buffer = viewSharesBuffer(chunk, target);
    if (shares_target_buffer) {
        if (source.size() > target_remaining) {
            owned_chunk = createUint8ArrayCopy(global_object, scope, source);
            RETURN_IF_EXCEPTION(scope, false);
            JSC::Strong<JSC::Unknown> protected_owned_chunk(global_object->vm(), owned_chunk);
            source = viewBytes(owned_chunk);
        }
    } else {
        owned_chunk
            = transferArrayBufferViewToUint8Array(global_object, scope, chunk, "ReadableByteStreamController chunk"_s);
        RETURN_IF_EXCEPTION(scope, false);
        source = viewBytes(owned_chunk).subspan(offset);
    }

    auto target_bytes = mutableViewBytes(target).subspan(pending.bytes_filled);
    const size_t copied = std::min(source.size(), target_bytes.size());
    if (copied)
        std::memmove(target_bytes.data(), source.data(), copied);
    pending.bytes_filled += copied;
    if (copied < source.size()) {
        if (!owned_chunk) {
            owned_chunk = createUint8ArrayCopy(global_object, scope, source);
            RETURN_IF_EXCEPTION(scope, false);
            source = viewBytes(owned_chunk);
        }
        const size_t memory_cost = m_queue_memory_cost_limit ? streamChunkMemoryCost(owned_chunk) : 0;
        QueuedChunk entry;
        entry.value.set(global_object->vm(), this, owned_chunk);
        entry.size = static_cast<double>(source.size() - copied);
        entry.memory_cost = memory_cost;
        entry.byte_offset = copied;
        if (queueMemoryCostWouldExceed(memory_cost)) {
            auto* exception
                = createStreamQueueLimitExceededError(global_object, "Text codec stream queue limit exceeded"_s);
            JSC::throwException(global_object, scope, exception);
            return false;
        }
        compactQueueIfNeeded();
        {
            WTF::Locker locker { cellLock() };
            m_queue.append(WTF::move(entry));
        }
        m_queue_total_size += static_cast<double>(source.size() - copied);
        m_queue_memory_cost += memory_cost;
    }
    if (shares_target_buffer) {
        // ReadableByteStreamControllerEnqueue transfers the chunk's buffer. Here the chunk aliases the pending view's
        // buffer, so moving that buffer's contents to a fresh one detaches the chunk while the pending view keeps its
        // bytes.
        auto* renewed = transferArrayBufferViewRangeToSameView(
            global_object, scope, target, 0, target->byteLength(), "ReadableStream BYOB view"_s);
        RETURN_IF_EXCEPTION(scope, false);
        pending.view.set(global_object->vm(), this, renewed);
    }
    if (firstByobReadRequestIsReady())
        return settleFirstByobReadRequestWithFilledBytes(global_object, scope, false);
    return refreshFirstByobReadRequestAndPullIfNeeded(global_object, scope);
}

bool JSColloReadableStream::drainQueuedBytesIntoByobRequests(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    while (hasByobReadRequests() && !queueEmpty()) {
        auto& pending = m_byob_read_requests[m_byob_read_request_start];
        auto* target = pending.view.get();
        if (arrayBufferViewIsUnavailable(target)) {
            auto request = takeFirstByobReadRequest();
            settleByobReadRequest(global_object, WTF::move(request),
                JSC::createTypeError(global_object, "BYOB view is detached or out of bounds"_s), true);
            if (hasByobReadRequests() && !refreshFirstByobReadRequest(global_object, scope))
                return false;
            continue;
        }

        std::span<const uint8_t> source;
        if (!firstQueuedByteSpan(source)) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream queued byte chunk is unavailable"_s);
            return false;
        }
        auto target_bytes = mutableViewBytes(target).subspan(pending.bytes_filled);
        const size_t copied = std::min(source.size(), target_bytes.size());
        if (copied)
            std::memcpy(target_bytes.data(), source.data(), copied);
        pending.bytes_filled += copied;
        if (!consumeFirstQueuedByteSpan(copied)) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream queued byte chunk is unavailable"_s);
            return false;
        }
        if (firstByobReadRequestIsReady()) {
            if (!settleFirstByobReadRequestWithFilledBytes(global_object, scope, false))
                return false;
            continue;
        }
        if (queueEmpty() && byteController() && byteController()->closeRequested()) {
            close(global_object);
            return true;
        }
        if (!refreshFirstByobReadRequestAndPullIfNeeded(global_object, scope))
            return false;
    }
    if (queueEmpty() && byteController() && byteController()->closeRequested())
        close(global_object);
    return true;
}

bool JSColloReadableStream::enqueueByteChunk(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSArrayBufferView* chunk)
{
    if (!canCloseOrEnqueue(global_object, scope))
        return false;
    if (arrayBufferViewIsUnavailable(chunk)) {
        JSC::throwVMTypeError(
            global_object, scope, "ReadableByteStreamController chunk is detached or out of bounds"_s);
        return false;
    }
    if (chunk->byteLength() == 0) {
        JSC::throwVMTypeError(global_object, scope, "ReadableByteStreamController chunk must not be empty"_s);
        return false;
    }
    if (hasByobReadRequests()) {
        auto* target = m_byob_read_requests[m_byob_read_request_start].view.get();
        if (arrayBufferViewIsUnavailable(target)) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream BYOB view is detached or out of bounds"_s);
            return false;
        }
        if (!fulfillFirstByobReadRequestWithChunk(global_object, scope, chunk, 0))
            return false;
        return drainQueuedBytesIntoByobRequests(global_object, scope);
    }

    if (hasReadRequests()) {
        auto* owned_chunk
            = transferArrayBufferViewToUint8Array(global_object, scope, chunk, "ReadableByteStreamController chunk"_s);
        RETURN_IF_EXCEPTION(scope, false);
        JSC::Strong<JSC::Unknown> protected_owned_chunk(global_object->vm(), owned_chunk);
        auto request = takeFirstReadRequest();
        settleReadRequest(
            global_object, WTF::move(request), createReadResult(global_object, owned_chunk, false), false);
        return true;
    }

    compactQueueIfNeeded();
    bool reserved = false;
    {
        WTF::Locker locker { cellLock() };
        reserved = m_queue.tryReserveCapacity(m_queue.size() + 1);
    }
    if (!reserved) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }
    auto* owned_chunk
        = transferArrayBufferViewToUint8Array(global_object, scope, chunk, "ReadableByteStreamController chunk"_s);
    RETURN_IF_EXCEPTION(scope, false);
    const size_t memory_cost = m_queue_memory_cost_limit ? streamChunkMemoryCost(owned_chunk) : 0;
    if (queueMemoryCostWouldExceed(memory_cost)) {
        auto* exception
            = createStreamQueueLimitExceededError(global_object, "Text codec stream queue limit exceeded"_s);
        JSC::throwException(global_object, scope, exception);
        return false;
    }

    QueuedChunk entry;
    entry.value.set(global_object->vm(), this, owned_chunk);
    entry.size = static_cast<double>(owned_chunk->byteLength());
    entry.memory_cost = memory_cost;
    entry.byte_offset = 0;
    {
        WTF::Locker locker { cellLock() };
        m_queue.append(WTF::move(entry));
    }
    m_queue_total_size += static_cast<double>(owned_chunk->byteLength());
    m_queue_memory_cost += memory_cost;
    return true;
}

bool JSColloReadableStream::settleByobRequestWithBytes(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSColloReadableStreamBYOBRequest* byob_request, size_t bytes_written)
{
    if (!byob_request || !byob_request->active()) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream BYOB request is no longer active"_s);
        return false;
    }
    auto* current_request = byteController() ? byteController()->byobRequest() : nullptr;
    if (!hasByobReadRequests() || current_request != byob_request) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream BYOB request is no longer current"_s);
        return false;
    }
    auto& pending = m_byob_read_requests[m_byob_read_request_start];
    auto* view = pending.view.get();
    if (arrayBufferViewIsUnavailable(view)) {
        auto request = takeFirstByobReadRequest();
        settleByobReadRequest(global_object, WTF::move(request),
            JSC::createTypeError(global_object, "BYOB view is detached or out of bounds"_s), true);
        if (hasByobReadRequests())
            return refreshFirstByobReadRequest(global_object, scope);
        return true;
    }
    const bool close_requested = byteController() && byteController()->closeRequested();
    if (close_requested && bytes_written != 0) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream BYOB bytesWritten must be zero after close"_s);
        return false;
    }
    if (bytes_written == 0 && !close_requested) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream BYOB bytesWritten must be greater than zero"_s);
        return false;
    }
    const size_t remaining = view->byteLength() - pending.bytes_filled;
    if (bytes_written > remaining) {
        JSC::throwException(global_object, scope,
            JSC::createRangeError(global_object, "ReadableStream BYOB bytesWritten exceeds view length"_s));
        return false;
    }
    pending.bytes_filled += bytes_written;
    if (close_requested) {
        if (!settleFirstByobReadRequestWithFilledBytes(global_object, scope, true))
            return false;
        close(global_object);
        return true;
    }
    if (firstByobReadRequestIsReady())
        return settleFirstByobReadRequestWithFilledBytes(global_object, scope, false);
    return refreshFirstByobReadRequestAndPullIfNeeded(global_object, scope);
}

bool JSColloReadableStream::settleByobRequestWithView(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSColloReadableStreamBYOBRequest* byob_request, JSC::JSArrayBufferView* view)
{
    if (!byob_request || !byob_request->active()) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream BYOB request is no longer active"_s);
        return false;
    }
    if (arrayBufferViewIsUnavailable(view)) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream BYOB response view is detached or out of bounds"_s);
        return false;
    }
    auto* current_request = byteController() ? byteController()->byobRequest() : nullptr;
    if (!hasByobReadRequests() || current_request != byob_request) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream BYOB request is no longer current"_s);
        return false;
    }
    auto* original_view = m_byob_read_requests[m_byob_read_request_start].view.get();
    if (arrayBufferViewIsUnavailable(original_view)) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream BYOB original view is detached or out of bounds"_s);
        return false;
    }
    const bool close_requested = byteController() && byteController()->closeRequested();
    if (close_requested) {
        if (view->byteLength() != 0) {
            JSC::throwVMTypeError(
                global_object, scope, "ReadableStream BYOB response view must be empty after close"_s);
            return false;
        }
        if (!viewSharesBuffer(view, original_view) || view->byteOffset() != original_view->byteOffset()) {
            JSC::throwVMRangeError(
                global_object, scope, "ReadableStream BYOB response view does not match the original view"_s);
            return false;
        }
    } else {
        if (view->byteLength() == 0) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream BYOB response view must not be empty"_s);
            return false;
        }
        if (!viewRangeIsInside(view, original_view)) {
            JSC::throwVMRangeError(
                global_object, scope, "ReadableStream BYOB response view does not match the original view"_s);
            return false;
        }
    }
    if (!viewRangeIsInside(view, original_view)) {
        JSC::throwVMRangeError(
            global_object, scope, "ReadableStream BYOB response view does not match the original view"_s);
        return false;
    }
    const size_t relative_offset = view->byteOffset() - original_view->byteOffset();
    const size_t byte_length = view->byteLength();
    auto& pending = m_byob_read_requests[m_byob_read_request_start];
    if (!close_requested && (pending.bytes_filled > 0 || byte_length < pending.min_bytes)) {
        const size_t target_remaining = original_view->byteLength() - pending.bytes_filled;
        if (byte_length > target_remaining) {
            JSC::throwVMRangeError(
                global_object, scope, "ReadableStream BYOB response view exceeds the pending read view"_s);
            return false;
        }
        auto source = viewBytes(view);
        auto target = mutableViewBytes(original_view).subspan(pending.bytes_filled);
        if (byte_length)
            std::memmove(target.data(), source.data(), byte_length);
        pending.bytes_filled += byte_length;
        // ReadableByteStreamControllerRespondWithNewView transfers view.[[ViewedArrayBuffer]] even when the read stays
        // pending. The response view lies inside the pending view (checked above), so transferring the pending view's
        // buffer to a fresh one detaches the caller's response view while the pending read keeps its bytes for later
        // fills.
        auto* renewed = transferArrayBufferViewRangeToSameView(
            global_object, scope, original_view, 0, original_view->byteLength(), "ReadableStream BYOB view"_s);
        RETURN_IF_EXCEPTION(scope, false);
        pending.view.set(global_object->vm(), this, renewed);
        if (firstByobReadRequestIsReady())
            return settleFirstByobReadRequestWithFilledBytes(global_object, scope, false);
        return refreshFirstByobReadRequestAndPullIfNeeded(global_object, scope);
    }
    auto* value = transferArrayBufferViewRangeToSameView(
        global_object, scope, original_view, relative_offset, byte_length, "ReadableStream BYOB view"_s);
    RETURN_IF_EXCEPTION(scope, false);
    JSC::Strong<JSC::Unknown> protected_value(global_object->vm(), value);
    auto request = takeFirstByobReadRequest();
    settleByobReadRequest(
        global_object, WTF::move(request), createReadResult(global_object, value, close_requested), false);
    if (close_requested)
        close(global_object);
    else if (hasByobReadRequests())
        return refreshFirstByobReadRequest(global_object, scope);
    return true;
}

EncodedJSValue JSColloReadableStream::read(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    markDisturbed();
    if (m_state == StreamState::Closed)
        return resolvedReadResult(global_object, JSC::jsUndefined(), true);
    if (m_state == StreamState::Errored)
        return rejectedPromise(global_object, scope, storedError());

    JSValue value;
    bool has_value = m_is_byte_stream ? dequeueByteValue(global_object, scope, value) : dequeue(value);
    RETURN_IF_EXCEPTION(scope, {});
    if (has_value) {
        callDefaultTeePullIfNeeded(global_object);
        if (queueEmpty()) {
            if (auto* current_controller = controller()) {
                if (current_controller->closeRequested())
                    close(global_object);
                else
                    callPullIfNeeded(global_object);
            } else if (auto* current_byte_controller = byteController()) {
                if (current_byte_controller->closeRequested())
                    close(global_object);
                else
                    callPullIfNeeded(global_object);
            }
        }
        return resolvedReadResult(global_object, value, false);
    }

    if (m_is_byte_stream) {
        auto* current_byte_controller = byteController();
        const size_t allocation_size = current_byte_controller ? current_byte_controller->autoAllocateChunkSize() : 0;
        if (allocation_size > 0) {
            auto* auto_view = createUint8Array(global_object, scope, allocation_size);
            if (!auto_view)
                return {};
            auto* byob_request
                = JSColloReadableStreamBYOBRequest::create(global_object->vm(), global_object, this, auto_view);
            ColloPromiseDeferred* byob_deferred = nullptr;
            JSValue byob_promise;
            if (!createDeferredPromise(global_object, scope, byob_promise, byob_deferred))
                return {};
            if (!appendByobReadRequest(global_object, scope, byob_promise, byob_deferred, auto_view, byob_request, 1))
                return {};
            callPullIfNeeded(global_object);
            return JSValue::encode(byob_promise);
        }
    }
    JSDeferredPromise deferred;
    if (!createJSDeferredPromise(global_object, scope, deferred))
        return {};
    if (!appendReadRequest(global_object, scope, deferred))
        return {};
    if (defaultTeeState())
        callDefaultTeePullIfNeeded(global_object);
    else if (m_native_source)
        callNativePullIfNeeded(global_object);
    else
        callPullIfNeeded(global_object);
    return JSValue::encode(deferred.promise);
}

EncodedJSValue JSColloReadableStream::readInto(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSArrayBufferView* view, size_t min_bytes)
{
    markDisturbed();
    if (!m_is_byte_stream) {
        return rejectedTypeError(global_object, scope, "ReadableStream is not a byte stream"_s);
    }
    if (arrayBufferViewIsUnavailable(view)) {
        return rejectedTypeError(global_object, scope, "ReadableStream BYOB view is detached or out of bounds"_s);
    }
    if (view->byteLength() == 0) {
        return rejectedTypeError(global_object, scope, "ReadableStream BYOB view must not be empty"_s);
    }
    if (m_state == StreamState::Closed) {
        auto* empty
            = transferArrayBufferViewRangeToSameView(global_object, scope, view, 0, 0, "ReadableStream BYOB view"_s);
        RETURN_IF_EXCEPTION(scope, {});
        JSC::Strong<JSC::Unknown> protected_empty(global_object->vm(), empty);
        return resolvedReadResult(global_object, empty, true);
    }
    if (m_state == StreamState::Errored)
        return rejectedPromise(global_object, scope, storedError());

    // ReadableByteStreamControllerPullInto transfers the caller's buffer as soon as the read is issued, and a failed
    // transfer rejects the read. From here on read()'s caller cannot reach the buffer. An underlying source writes
    // into it through byobRequest.view.
    const size_t view_byte_length = view->byteLength();
    auto* transferred_view = transferArrayBufferViewRangeToSameView(
        global_object, scope, view, 0, view_byte_length, "ReadableStream BYOB view"_s);
    if (scope.exception()) {
        JSValue reason = scope.exception()->value();
        if (!scope.tryClearException())
            return {};
        return rejectedPromise(global_object, scope, reason);
    }
    auto* exposed_view = createUint8ArrayView(global_object, scope, transferred_view, 0, view_byte_length);
    RETURN_IF_EXCEPTION(scope, {});
    JSValue promise;
    ColloPromiseDeferred* deferred = nullptr;
    if (!createDeferredPromise(global_object, scope, promise, deferred))
        return {};
    auto* byob_request
        = JSColloReadableStreamBYOBRequest::create(global_object->vm(), global_object, this, exposed_view);
    if (!appendByobReadRequest(global_object, scope, promise, deferred, transferred_view, byob_request, min_bytes))
        return {};
    if (!drainQueuedBytesIntoByobRequests(global_object, scope))
        return {};
    if (!hasByobReadRequests() || m_byob_read_requests[m_byob_read_request_start].deferred != deferred) {
        if (queueEmpty()) {
            if (defaultTeeState())
                callDefaultTeePullIfNeeded(global_object);
            else if (auto* current_controller = byteController()) {
                if (current_controller->closeRequested())
                    close(global_object);
                else
                    callPullIfNeeded(global_object);
            }
        }
        return JSValue::encode(promise);
    }
    if (defaultTeeState())
        callDefaultTeePullIfNeeded(global_object);
    else if (m_native_source)
        callNativePullIfNeeded(global_object);
    else
        callPullIfNeeded(global_object);
    return JSValue::encode(promise);
}

ReadableStreamDrainResult JSColloReadableStream::drainNativeBytes(WTF::Vector<uint8_t>& out, size_t max_size)
{
    if (!m_native_source)
        return ReadableStreamDrainResult::NotAvailable;
    if (m_state != StreamState::Readable)
        return ReadableStreamDrainResult::NotAvailable;
    if (m_disturbed || locked() || !queueEmpty() || hasReadRequests() || m_native_pulling)
        return ReadableStreamDrainResult::NotAvailable;
    bool exceeds_limit = false;
    bool supported = false;
    auto consume_native_source = [&] {
        m_disturbed = true;
        m_state = StreamState::Closed;
        releaseNativeSource();
    };
    if (!m_native_source->appendRemainingBytes(out, max_size, exceeds_limit, supported)) {
        if (!supported)
            return ReadableStreamDrainResult::NotAvailable;
        if (exceeds_limit) {
            consume_native_source();
            return ReadableStreamDrainResult::TooLarge;
        }
        consume_native_source();
        return ReadableStreamDrainResult::OutOfMemory;
    }
    consume_native_source();
    return ReadableStreamDrainResult::Drained;
}

static JSValue cancelDefaultTeeBranch(
    JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSObject*, JSColloReadableStream*, JSValue);

EncodedJSValue JSColloReadableStream::cancel(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue reason)
{
    markDisturbed();
    if (m_state == StreamState::Closed)
        return resolvedPromise(global_object, JSC::jsUndefined());
    if (m_state == StreamState::Errored)
        return rejectedPromise(global_object, scope, storedError());
    if (m_native_source) {
        auto result = m_native_source->cancel(global_object, scope, reason);
        RETURN_IF_EXCEPTION(scope, {});
        clearQueue();
        close(global_object);
        return promiseThenUndefined(global_object, scope, JSValue::decode(result));
    }
    JSValue cancel_result = JSC::jsUndefined();
    if (auto* tee_state = defaultTeeState()) {
        cancel_result = cancelDefaultTeeBranch(global_object, scope, tee_state, this, reason);
        RETURN_IF_EXCEPTION(scope, {});
        clearQueue();
        rejectByobReadRequests(global_object, reason);
        close(global_object);
        return promiseThenUndefined(global_object, scope, cancel_result);
    }
    if (auto* current_controller = controller()) {
        JSValue cancel = current_controller->cancelCallback();
        if (valueIsCallable(cancel)) {
            JSC::MarkedArgumentBuffer arguments;
            arguments.append(reason);
            if (arguments.hasOverflowed()) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return {};
            }
            auto call_data = JSC::getCallData(cancel);
            cancel_result = JSC::call(
                global_object, cancel.getObject(), call_data, current_controller->underlyingSource(), arguments);
            if (scope.exception()) {
                JSValue exception = scope.exception()->value();
                if (!scope.tryClearException())
                    return {};
                clearQueue();
                rejectByobReadRequests(global_object, exception);
                close(global_object);
                return rejectedPromise(global_object, exception);
            }
        }
    } else if (auto* current_byte_controller = byteController()) {
        JSValue cancel = current_byte_controller->cancelCallback();
        if (valueIsCallable(cancel)) {
            JSC::MarkedArgumentBuffer arguments;
            arguments.append(reason);
            if (arguments.hasOverflowed()) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return {};
            }
            auto call_data = JSC::getCallData(cancel);
            cancel_result = JSC::call(
                global_object, cancel.getObject(), call_data, current_byte_controller->underlyingSource(), arguments);
            if (scope.exception()) {
                JSValue exception = scope.exception()->value();
                if (!scope.tryClearException())
                    return {};
                clearQueue();
                rejectByobReadRequests(global_object, exception);
                close(global_object);
                return rejectedPromise(global_object, exception);
            }
        }
    }
    clearQueue();
    rejectByobReadRequests(global_object, reason);
    close(global_object);
    return promiseThenUndefined(global_object, scope, cancel_result);
}

// Reads the done flag of a {value, done} read result from own property storage only, so no getter runs and an
// inherited done does not count. Returns false with out_error set to a TypeError when the result is not an object or
// has no own done property.
bool readResultDone(JSC::JSGlobalObject* global_object, JSValue result, bool& out, JSValue& out_error)
{
    out = false;
    out_error = {};
    auto* object = result.getObject();
    if (!object) {
        out_error
            = JSC::createTypeError(global_object, "ReadableStream native source returned a non-object read result"_s);
        return false;
    }
    JSValue done = object->getDirect(global_object->vm(), global_object->vm().propertyNames->done);
    if (!done) {
        out_error
            = JSC::createTypeError(global_object, "ReadableStream native source returned a malformed read result"_s);
        return false;
    }
    out = done.isBoolean() && done.asBoolean();
    return true;
}

JSValue readResultValue(JSC::JSGlobalObject* global_object, JSValue result);

JSC_DEFINE_HOST_FUNCTION(nativePullFulfilled, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* function = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee());
    JSValue stream_value = function->get(global_object, readableStreamIdentifier(global_object));
    RETURN_IF_EXCEPTION(scope, {});
    auto* stream = requireReadableStream(global_object, scope, stream_value);
    RETURN_IF_EXCEPTION(scope, {});
    stream->finishNativePull(global_object, scope, call_frame->argument(0));
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(nativePullRejected, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* function = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee());
    JSValue stream_value = function->get(global_object, readableStreamIdentifier(global_object));
    RETURN_IF_EXCEPTION(scope, {});
    auto* stream = requireReadableStream(global_object, scope, stream_value);
    RETURN_IF_EXCEPTION(scope, {});
    stream->rejectNativePull(global_object, call_frame->argument(0));
    return JSValue::encode(JSC::jsUndefined());
}

JSC::JSFunction* JSColloReadableStream::nativePullFulfilledFunction(JSC::JSGlobalObject* global_object)
{
    return cachedThenCallback(global_object, m_native_pull_fulfilled, this, "ReadableStream native pull fulfilled"_s,
        nativePullFulfilled, readableStreamIdentifier(global_object), this);
}

JSC::JSFunction* JSColloReadableStream::nativePullRejectedFunction(JSC::JSGlobalObject* global_object)
{
    return cachedThenCallback(global_object, m_native_pull_rejected, this, "ReadableStream native pull rejected"_s,
        nativePullRejected, readableStreamIdentifier(global_object), this);
}

void JSColloReadableStream::finishNativePull(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue result)
{
    m_native_pulling = false;
    if (m_state != StreamState::Readable)
        return;

    bool done = false;
    JSValue read_error;
    if (!readResultDone(global_object, result, done, read_error)) {
        rejectNativePull(global_object, read_error);
        return;
    }

    if (hasReadRequests()) {
        auto request = takeFirstReadRequest();
        settleReadRequest(global_object, WTF::move(request), result, false);
        if (done)
            close(global_object);
        else
            callNativePullIfNeeded(global_object);
        return;
    }

    if (done) {
        close(global_object);
        return;
    }

    JSValue value = readResultValue(global_object, result);
    if (!value)
        value = JSC::jsUndefined();
    if (hasByobReadRequests()) {
        auto* view = dynamicDowncast<JSC::JSArrayBufferView>(value);
        if (arrayBufferViewIsUnavailable(view)) {
            this->error(global_object,
                JSC::createTypeError(
                    global_object, "ReadableStream native byte source returned unavailable byte chunk"_s));
            return;
        }
        if (!fulfillFirstByobReadRequestWithChunk(global_object, scope, view, 0)) {
            JSValue byob_error
                = scope.exception() ? scope.exception()->value() : JSC::createOutOfMemoryError(global_object);
            if (scope.exception() && !scope.tryClearException())
                return;
            this->error(global_object, byob_error);
            return;
        }
        if (!drainQueuedBytesIntoByobRequests(global_object, scope)) {
            JSValue byob_error
                = scope.exception() ? scope.exception()->value() : JSC::createOutOfMemoryError(global_object);
            if (scope.exception() && !scope.tryClearException())
                return;
            this->error(global_object, byob_error);
            return;
        }
        // A BYOB read that is still pending and not yet ready needs another native pull even while bytes remain
        // queued. Nothing else would start one, since callPullIfNeeded ignores streams with a native source, and the
        // read would wait for an unrelated read to arrive. callNativePullIfNeeded checks m_native_pulling and the
        // pending reads again, so this cannot spin into an endless pull loop.
        if (queueEmpty() || (hasByobReadRequests() && !firstByobReadRequestIsReady()))
            callNativePullIfNeeded(global_object);
        return;
    }
    if (!enqueueNativePullValue(global_object, scope, value)) {
        JSValue enqueue_error
            = scope.exception() ? scope.exception()->value() : JSC::createOutOfMemoryError(global_object);
        if (scope.exception() && !scope.tryClearException())
            return;
        this->error(global_object, enqueue_error);
    }
}

void JSColloReadableStream::rejectNativePull(JSC::JSGlobalObject* global_object, JSValue error)
{
    m_native_pulling = false;
    this->error(global_object, error);
}

void JSColloReadableStream::callNativePullIfNeeded(JSC::JSGlobalObject* global_object)
{
    if (m_state != StreamState::Readable)
        return;
    if (!m_native_source)
        return;
    if (m_native_pulling)
        return;
    if (!hasReadRequests() && !hasByobReadRequests())
        return;

    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    m_native_pulling = true;
    JSValue pull_result = JSValue::decode(m_native_source->pull(global_object, scope));
    if (scope.exception()) {
        JSValue exception = scope.exception()->value();
        if (!scope.tryClearException())
            return;
        error(global_object, exception);
        return;
    }

    auto* promise = dynamicDowncast<JSC::JSPromise>(pull_result);
    if (!promise) {
        finishNativePull(global_object, scope, pull_result);
        return;
    }

    promise->performPromiseThen(vm, global_object, nativePullFulfilledFunction(global_object),
        nativePullRejectedFunction(global_object), JSC::jsUndefined());
    if (scope.exception()) {
        JSValue exception = scope.exception()->value();
        if (!scope.tryClearException())
            return;
        error(global_object, exception);
    }
}

JSValue readResultValue(JSC::JSGlobalObject* global_object, JSValue result)
{
    if (auto* object = result.getObject())
        return object->getDirect(global_object->vm(), global_object->vm().propertyNames->value);
    return {};
}

void startDefaultTeePump(JSC::JSGlobalObject*, JSC::JSObject* tee_state);

// The tee of a stream without a native source keeps its state in a plain object with non-enumerable properties: the
// original stream, both branches, whether a read is in flight, each branch's canceled flag and reason, and the cached
// reaction functions, which find the state again through a property of their own. Each branch holds it in
// m_default_tee_state. The pump reads the original one chunk at a time and enqueues each chunk into both readable
// branches, copying a byte chunk for each. finalizeDefaultTeeState ends the tee: it releases the original's reader and
// unlinks both branches.
static JSColloReadableStream* teeStateStream(
    JSC::JSGlobalObject* global_object, JSC::JSObject* tee_state, const JSC::Identifier& identifier)
{
    auto value = tee_state->getDirect(global_object->vm(), identifier);
    if (!value || !value.isObject())
        return nullptr;
    return dynamicDowncast<JSColloReadableStream>(value);
}

static JSColloReadableStream* teeStateOriginal(JSC::JSGlobalObject* global_object, JSC::JSObject* tee_state)
{
    return teeStateStream(global_object, tee_state, teeOriginalIdentifier(global_object));
}

static JSColloReadableStream* teeStateBranchA(JSC::JSGlobalObject* global_object, JSC::JSObject* tee_state)
{
    return teeStateStream(global_object, tee_state, teeBranchAIdentifier(global_object));
}

static JSColloReadableStream* teeStateBranchB(JSC::JSGlobalObject* global_object, JSC::JSObject* tee_state)
{
    return teeStateStream(global_object, tee_state, teeBranchBIdentifier(global_object));
}

static bool teeStateReading(JSC::JSGlobalObject* global_object, JSC::JSObject* tee_state)
{
    auto value = tee_state->getDirect(global_object->vm(), teeReadingIdentifier(global_object));
    return value.isBoolean() && value.asBoolean();
}

static void setTeeStateReading(JSC::JSGlobalObject* global_object, JSC::JSObject* tee_state, bool value)
{
    tee_state->putDirect(global_object->vm(), teeReadingIdentifier(global_object), JSC::jsBoolean(value),
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
}

static bool teeStateFlag(
    JSC::JSGlobalObject* global_object, JSC::JSObject* tee_state, const JSC::Identifier& identifier)
{
    auto value = tee_state->getDirect(global_object->vm(), identifier);
    return value.isBoolean() && value.asBoolean();
}

static void setTeeStateFlag(
    JSC::JSGlobalObject* global_object, JSC::JSObject* tee_state, const JSC::Identifier& identifier, bool value)
{
    tee_state->putDirect(global_object->vm(), identifier, JSC::jsBoolean(value),
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
}

static JSValue teeStateValue(
    JSC::JSGlobalObject* global_object, JSC::JSObject* tee_state, const JSC::Identifier& identifier)
{
    auto value = tee_state->getDirect(global_object->vm(), identifier);
    return value ? value : JSC::jsUndefined();
}

static void setTeeStateValue(
    JSC::JSGlobalObject* global_object, JSC::JSObject* tee_state, const JSC::Identifier& identifier, JSValue value)
{
    tee_state->putDirect(
        global_object->vm(), identifier, value, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
}

static JSC::JSObject* teeStateFromFunction(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSFunction* function)
{
    auto& vm = global_object->vm();
    auto value = function->get(global_object, readableStreamTeeStateIdentifier(global_object));
    RETURN_IF_EXCEPTION(scope, nullptr);
    auto* object = value.getObject();
    if (!object)
        JSC::throwVMTypeError(global_object, scope, "ReadableStream tee state is unavailable"_s);
    return object;
}

static void finalizeDefaultTeeState(JSC::JSGlobalObject* global_object, JSC::JSObject* tee_state)
{
    auto* original = teeStateOriginal(global_object, tee_state);
    auto* branch_a = teeStateBranchA(global_object, tee_state);
    auto* branch_b = teeStateBranchB(global_object, tee_state);
    if (original) {
        if (auto* reader = original->reader())
            reader->release(global_object);
    }
    if (branch_a)
        branch_a->clearDefaultTeeState();
    if (branch_b)
        branch_b->clearDefaultTeeState();
    setTeeStateValue(global_object, tee_state, teeOriginalIdentifier(global_object), JSC::jsUndefined());
    setTeeStateValue(global_object, tee_state, teeBranchAIdentifier(global_object), JSC::jsUndefined());
    setTeeStateValue(global_object, tee_state, teeBranchBIdentifier(global_object), JSC::jsUndefined());
}

static void errorDefaultTeeBranches(JSC::JSGlobalObject* global_object, JSC::JSObject* tee_state, JSValue error)
{
    if (auto* branch_a = teeStateBranchA(global_object, tee_state))
        branch_a->error(global_object, error);
    if (auto* branch_b = teeStateBranchB(global_object, tee_state))
        branch_b->error(global_object, error);
    finalizeDefaultTeeState(global_object, tee_state);
}

static void closeDefaultTeeBranches(JSC::JSGlobalObject* global_object, JSC::JSObject* tee_state)
{
    if (auto* branch_a = teeStateBranchA(global_object, tee_state))
        branch_a->close(global_object);
    if (auto* branch_b = teeStateBranchB(global_object, tee_state))
        branch_b->close(global_object);
    finalizeDefaultTeeState(global_object, tee_state);
}

// The largest read the pump issues on a byte stream on behalf of a branch's pending BYOB read.
static constexpr size_t byteStreamTeePullByteLengthMax = 64 * 1024;
// With no read pending, the pump reads ahead only while every live branch of a non-byte tee holds fewer queued chunks
// than this. A branch has no size callback, so its queue counts each chunk as 1.
static constexpr double defaultTeeQueuedSizeMax = 1024;

static bool defaultTeeBranchCanAccept(JSColloReadableStream* branch, bool canceled)
{
    if (!branch || canceled)
        return true;
    if (branch->state() != StreamState::Readable)
        return true;
    if (branch->hasPendingReadRequests() || branch->hasPendingByobReadRequests())
        return true;
    return branch->queuedSizeForTee() < defaultTeeQueuedSizeMax;
}

static bool defaultTeeShouldPull(JSC::JSGlobalObject* global_object, JSC::JSObject* tee_state)
{
    if (teeStateReading(global_object, tee_state))
        return false;
    auto* original = teeStateOriginal(global_object, tee_state);
    if (!original || original->state() != StreamState::Readable)
        return false;
    auto* branch_a = teeStateBranchA(global_object, tee_state);
    auto* branch_b = teeStateBranchB(global_object, tee_state);
    const bool branch_a_canceled = teeStateFlag(global_object, tee_state, teeBranchACanceledIdentifier(global_object));
    const bool branch_b_canceled = teeStateFlag(global_object, tee_state, teeBranchBCanceledIdentifier(global_object));
    const bool branch_a_has_request = !branch_a_canceled && branch_a
        && (branch_a->hasPendingReadRequests() || branch_a->hasPendingByobReadRequests());
    const bool branch_b_has_request = !branch_b_canceled && branch_b
        && (branch_b->hasPendingReadRequests() || branch_b->hasPendingByobReadRequests());
    // A pending read on either branch is served however much the other branch has queued; waiting for that branch
    // to drain could leave the read pending forever.
    if (branch_a_has_request || branch_b_has_request)
        return true;
    if (original->isByteStream())
        return false;
    // Reading ahead stops at defaultTeeQueuedSizeMax, so read-ahead alone cannot grow an unread branch without bound.
    // Reads served for the other branch still queue every chunk in it, as the standard's tee does.
    if (!defaultTeeBranchCanAccept(branch_a, branch_a_canceled))
        return false;
    if (!defaultTeeBranchCanAccept(branch_b, branch_b_canceled))
        return false;
    const bool branch_a_wants = !branch_a_canceled && branch_a && branch_a->wantsTeeChunk();
    const bool branch_b_wants = !branch_b_canceled && branch_b && branch_b->wantsTeeChunk();
    return branch_a_wants || branch_b_wants;
}

static size_t defaultTeePendingByobReadSize(JSC::JSGlobalObject* global_object, JSC::JSObject* tee_state)
{
    size_t size = 0;
    if (auto* branch_a = teeStateBranchA(global_object, tee_state))
        size = std::max(size, branch_a->pendingByobReadPullByteLength(byteStreamTeePullByteLengthMax));
    if (auto* branch_b = teeStateBranchB(global_object, tee_state))
        size = std::max(size, branch_b->pendingByobReadPullByteLength(byteStreamTeePullByteLengthMax));
    return size;
}

static bool enqueueDefaultTeeChunk(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSColloReadableStream* branch, JSValue value, bool is_byte_stream)
{
    if (!branch || branch->state() != StreamState::Readable)
        return true;
    if (!is_byte_stream)
        return branch->enqueue(global_object, scope, value);

    auto* view = dynamicDowncast<JSC::JSArrayBufferView>(value);
    if (arrayBufferViewIsUnavailable(view)) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream byte tee chunk must be bytes"_s);
        return false;
    }
    auto* copy = createUint8ArrayCopy(global_object, scope, viewBytes(view));
    RETURN_IF_EXCEPTION(scope, false);
    return branch->enqueueByteChunk(global_object, scope, copy);
}

static JSValue composeTeeCancelReason(JSC::JSGlobalObject* global_object, JSC::JSObject* tee_state)
{
    auto* array = JSC::constructEmptyArray(global_object, nullptr, 2);
    array->putDirectIndex(
        global_object, 0, teeStateValue(global_object, tee_state, teeBranchAReasonIdentifier(global_object)));
    array->putDirectIndex(
        global_object, 1, teeStateValue(global_object, tee_state, teeBranchBReasonIdentifier(global_object)));
    return array;
}

static JSValue cancelDefaultTeeBranch(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSC::JSObject* tee_state, JSColloReadableStream* branch, JSValue reason)
{
    auto* branch_a = teeStateBranchA(global_object, tee_state);
    auto* branch_b = teeStateBranchB(global_object, tee_state);
    const bool is_a = branch == branch_a;
    const bool is_b = branch == branch_b;
    if (!is_a && !is_b)
        return JSC::jsUndefined();

    const auto& canceled_identifier
        = is_a ? teeBranchACanceledIdentifier(global_object) : teeBranchBCanceledIdentifier(global_object);
    const auto& reason_identifier
        = is_a ? teeBranchAReasonIdentifier(global_object) : teeBranchBReasonIdentifier(global_object);
    if (teeStateFlag(global_object, tee_state, canceled_identifier))
        return JSC::jsUndefined();

    setTeeStateFlag(global_object, tee_state, canceled_identifier, true);
    setTeeStateValue(global_object, tee_state, reason_identifier, reason);

    const bool a_canceled = teeStateFlag(global_object, tee_state, teeBranchACanceledIdentifier(global_object));
    const bool b_canceled = teeStateFlag(global_object, tee_state, teeBranchBCanceledIdentifier(global_object));
    if (!a_canceled || !b_canceled)
        return JSC::jsUndefined();

    JSValue cancel_result = JSC::jsUndefined();
    if (auto* original = teeStateOriginal(global_object, tee_state)) {
        JSValue composite_reason = composeTeeCancelReason(global_object, tee_state);
        RETURN_IF_EXCEPTION(scope, {});
        cancel_result = JSValue::decode(original->cancel(global_object, scope, composite_reason));
        RETURN_IF_EXCEPTION(scope, {});
    }
    finalizeDefaultTeeState(global_object, tee_state);
    return cancel_result;
}

static void finishDefaultTeeRead(JSC::JSGlobalObject* global_object, JSC::JSObject* tee_state, JSValue result)
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    bool done = false;
    JSValue error;
    if (!readResultDone(global_object, result, done, error)) {
        errorDefaultTeeBranches(global_object, tee_state, error);
        return;
    }
    if (done) {
        closeDefaultTeeBranches(global_object, tee_state);
        return;
    }

    JSValue value = readResultValue(global_object, result);
    if (!value)
        value = JSC::jsUndefined();
    auto* original = teeStateOriginal(global_object, tee_state);
    const bool is_byte_stream = original && original->isByteStream();

    if (auto* branch_a = teeStateBranchA(global_object, tee_state);
        branch_a && branch_a->state() == StreamState::Readable) {
        if (!enqueueDefaultTeeChunk(global_object, scope, branch_a, value, is_byte_stream)) {
            JSValue enqueue_error
                = scope.exception() ? scope.exception()->value() : JSC::createOutOfMemoryError(global_object);
            if (scope.exception() && !scope.tryClearException())
                return;
            errorDefaultTeeBranches(global_object, tee_state, enqueue_error);
            return;
        }
    }

    if (auto* branch_b = teeStateBranchB(global_object, tee_state);
        branch_b && branch_b->state() == StreamState::Readable) {
        if (!enqueueDefaultTeeChunk(global_object, scope, branch_b, value, is_byte_stream)) {
            JSValue enqueue_error
                = scope.exception() ? scope.exception()->value() : JSC::createOutOfMemoryError(global_object);
            if (scope.exception() && !scope.tryClearException())
                return;
            errorDefaultTeeBranches(global_object, tee_state, enqueue_error);
            return;
        }
    }

    if (auto* original = teeStateOriginal(global_object, tee_state);
        original && original->state() == StreamState::Closed) {
        closeDefaultTeeBranches(global_object, tee_state);
        return;
    }

    startDefaultTeePump(global_object, tee_state);
}

JSC_DEFINE_HOST_FUNCTION(defaultTeeFulfilled, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* function = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee());
    auto* tee_state = teeStateFromFunction(global_object, scope, function);
    RETURN_IF_EXCEPTION(scope, {});
    setTeeStateReading(global_object, tee_state, false);
    finishDefaultTeeRead(global_object, tee_state, call_frame->argument(0));
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(defaultTeeRejected, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* function = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee());
    auto* tee_state = teeStateFromFunction(global_object, scope, function);
    RETURN_IF_EXCEPTION(scope, {});
    setTeeStateReading(global_object, tee_state, false);
    errorDefaultTeeBranches(global_object, tee_state, call_frame->argument(0));
    return JSValue::encode(JSC::jsUndefined());
}

static void attachDefaultTeeCallbackState(
    JSC::JSGlobalObject* global_object, JSC::JSFunction* function, JSC::JSObject* tee_state)
{
    auto& vm = global_object->vm();
    function->putDirect(vm, readableStreamTeeStateIdentifier(global_object), tee_state,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
}

static JSC::JSFunction* cachedTeeCallback(JSC::JSGlobalObject* global_object, JSC::JSObject* tee_state,
    const JSC::Identifier& callback_identifier, WTF::ASCIILiteral name, JSC::NativeFunction callback)
{
    auto& vm = global_object->vm();
    auto existing = tee_state->getDirect(vm, callback_identifier);
    if (existing && existing.isObject()) {
        if (auto* function = dynamicDowncast<JSC::JSFunction>(existing))
            return function;
    }
    auto* function
        = JSC::JSFunction::create(vm, global_object, 1, name, callback, JSC::ImplementationVisibility::Public);
    attachDefaultTeeCallbackState(global_object, function, tee_state);
    tee_state->putDirect(vm, callback_identifier, function, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    return function;
}

JSC::JSObject* createDefaultTeeState(JSC::JSGlobalObject* global_object, JSColloReadableStream* original,
    JSColloReadableStream* branch_a, JSColloReadableStream* branch_b)
{
    auto& vm = global_object->vm();
    auto* tee_state = JSC::constructEmptyObject(global_object, global_object->objectPrototype(), 8);
    tee_state->putDirect(
        vm, teeOriginalIdentifier(global_object), original, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    tee_state->putDirect(
        vm, teeBranchAIdentifier(global_object), branch_a, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    tee_state->putDirect(
        vm, teeBranchBIdentifier(global_object), branch_b, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    tee_state->putDirect(vm, teeReadingIdentifier(global_object), JSC::jsBoolean(false),
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    tee_state->putDirect(vm, teeBranchACanceledIdentifier(global_object), JSC::jsBoolean(false),
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    tee_state->putDirect(vm, teeBranchBCanceledIdentifier(global_object), JSC::jsBoolean(false),
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    tee_state->putDirect(vm, teeBranchAReasonIdentifier(global_object), JSC::jsUndefined(),
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    tee_state->putDirect(vm, teeBranchBReasonIdentifier(global_object), JSC::jsUndefined(),
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    return tee_state;
}

void startDefaultTeePump(JSC::JSGlobalObject* global_object, JSC::JSObject* tee_state)
{
    if (!defaultTeeShouldPull(global_object, tee_state))
        return;
    auto* original = teeStateOriginal(global_object, tee_state);
    if (!original)
        return;

    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSValue read_promise;
    const size_t byob_read_size
        = original->isByteStream() ? defaultTeePendingByobReadSize(global_object, tee_state) : 0;
    if (byob_read_size > 0) {
        auto* pull_view = createUint8Array(global_object, scope, byob_read_size);
        if (scope.exception()) {
            JSValue error = scope.exception()->value();
            if (!scope.tryClearException())
                return;
            errorDefaultTeeBranches(global_object, tee_state, error);
            return;
        }
        JSC::Strong<JSC::Unknown> protected_pull_view(vm, pull_view);
        read_promise = JSValue::decode(original->readInto(global_object, scope, pull_view, 1));
    } else {
        read_promise = JSValue::decode(original->read(global_object, scope));
    }
    if (scope.exception()) {
        JSValue error = scope.exception()->value();
        if (!scope.tryClearException())
            return;
        errorDefaultTeeBranches(global_object, tee_state, error);
        return;
    }
    auto* promise = dynamicDowncast<JSC::JSPromise>(read_promise);
    if (!promise) {
        finishDefaultTeeRead(global_object, tee_state, read_promise);
        return;
    }

    setTeeStateReading(global_object, tee_state, true);
    auto* fulfilled = cachedTeeCallback(global_object, tee_state, teeFulfilledIdentifier(global_object),
        "ReadableStream tee fulfilled"_s, defaultTeeFulfilled);
    auto* rejected = cachedTeeCallback(global_object, tee_state, teeRejectedIdentifier(global_object),
        "ReadableStream tee rejected"_s, defaultTeeRejected);
    promise->performPromiseThen(vm, global_object, fulfilled, rejected, JSC::jsUndefined());
    if (scope.exception()) {
        JSValue error = scope.exception()->value();
        if (!scope.tryClearException())
            return;
        setTeeStateReading(global_object, tee_state, false);
        errorDefaultTeeBranches(global_object, tee_state, error);
    }
}

void JSColloReadableStream::callDefaultTeePullIfNeeded(JSC::JSGlobalObject* global_object)
{
    if (auto* tee_state = defaultTeeState())
        startDefaultTeePump(global_object, tee_state);
}

bool JSColloReadableStream::teeNativeInto(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    WTF::RefPtr<ReadableStreamNativeSource>& out_first, WTF::RefPtr<ReadableStreamNativeSource>& out_second)
{
    markDisturbed();
    if (!m_native_source) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream has no native source"_s);
        return false;
    }
    if (m_state != StreamState::Readable) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream is not readable"_s);
        return false;
    }
    if (!m_native_source->tee(global_object, scope, out_first, out_second)) {
        RETURN_IF_EXCEPTION(scope, false);
        JSC::throwVMTypeError(global_object, scope, "native ReadableStream tee is not available"_s);
        return false;
    }
    return true;
}

static EncodedJSValue pullFulfilledCallback(JSC::JSGlobalObject* global_object, JSC::CallFrame* call_frame)
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* function = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee());
    auto controller_value = function->get(global_object, readableStreamControllerIdentifier(global_object));
    RETURN_IF_EXCEPTION(scope, {});
    auto* controller = requireReadableStreamDefaultController(global_object, scope, controller_value);
    RETURN_IF_EXCEPTION(scope, {});
    controller->setPulling(false);
    if (auto* stream = controller->stream()) {
        controller->setPullAgain(false);
        stream->callPullIfNeeded(global_object);
    }
    return JSValue::encode(JSC::jsUndefined());
}

static EncodedJSValue pullRejectedCallback(JSC::JSGlobalObject* global_object, JSC::CallFrame* call_frame)
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* function = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee());
    auto controller_value = function->get(global_object, readableStreamControllerIdentifier(global_object));
    RETURN_IF_EXCEPTION(scope, {});
    auto* controller = requireReadableStreamDefaultController(global_object, scope, controller_value);
    RETURN_IF_EXCEPTION(scope, {});
    controller->setPulling(false);
    if (auto* stream = controller->stream())
        stream->error(global_object, call_frame->argument(0));
    return JSValue::encode(JSC::jsUndefined());
}

JSC::JSFunction* JSColloReadableStreamDefaultController::pullFulfilledFunction(JSC::JSGlobalObject* global_object)
{
    return cachedThenCallback(global_object, m_pull_fulfilled, this, "ReadableStream pull fulfilled"_s,
        pullFulfilledCallback, readableStreamControllerIdentifier(global_object), this);
}

JSC::JSFunction* JSColloReadableStreamDefaultController::pullRejectedFunction(JSC::JSGlobalObject* global_object)
{
    return cachedThenCallback(global_object, m_pull_rejected, this, "ReadableStream pull rejected"_s,
        pullRejectedCallback, readableStreamControllerIdentifier(global_object), this);
}

static EncodedJSValue bytePullFulfilledCallback(JSC::JSGlobalObject* global_object, JSC::CallFrame* call_frame)
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* function = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee());
    auto controller_value = function->get(global_object, readableStreamControllerIdentifier(global_object));
    RETURN_IF_EXCEPTION(scope, {});
    auto* controller = requireReadableByteStreamController(global_object, scope, controller_value);
    RETURN_IF_EXCEPTION(scope, {});
    controller->setPulling(false);
    if (auto* stream = controller->stream()) {
        controller->setPullAgain(false);
        stream->callPullIfNeeded(global_object);
    }
    return JSValue::encode(JSC::jsUndefined());
}

static EncodedJSValue bytePullRejectedCallback(JSC::JSGlobalObject* global_object, JSC::CallFrame* call_frame)
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* function = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee());
    auto controller_value = function->get(global_object, readableStreamControllerIdentifier(global_object));
    RETURN_IF_EXCEPTION(scope, {});
    auto* controller = requireReadableByteStreamController(global_object, scope, controller_value);
    RETURN_IF_EXCEPTION(scope, {});
    controller->setPulling(false);
    if (auto* stream = controller->stream())
        stream->error(global_object, call_frame->argument(0));
    return JSValue::encode(JSC::jsUndefined());
}

JSC::JSFunction* JSColloReadableByteStreamController::pullFulfilledFunction(JSC::JSGlobalObject* global_object)
{
    return cachedThenCallback(global_object, m_pull_fulfilled, this, "ReadableStream byte pull fulfilled"_s,
        bytePullFulfilledCallback, readableStreamControllerIdentifier(global_object), this);
}

JSC::JSFunction* JSColloReadableByteStreamController::pullRejectedFunction(JSC::JSGlobalObject* global_object)
{
    return cachedThenCallback(global_object, m_pull_rejected, this, "ReadableStream byte pull rejected"_s,
        bytePullRejectedCallback, readableStreamControllerIdentifier(global_object), this);
}

void JSColloReadableStream::callPullIfNeeded(JSC::JSGlobalObject* global_object)
{
    if (m_state != StreamState::Readable)
        return;
    if (hasNativeSource())
        return;
    if (m_pipe_backpressure && !hasReadRequests())
        return;
    if (auto* current_byte_controller = byteController()) {
        if (current_byte_controller->starting())
            return;
        if (current_byte_controller->closeRequested())
            return;
        if (!hasByobReadRequests() && !hasReadRequests())
            return;
        if (current_byte_controller->pulling()) {
            current_byte_controller->setPullAgain(true);
            return;
        }
        JSValue pull = current_byte_controller->pullCallback();
        if (!valueIsCallable(pull))
            return;

        auto& vm = global_object->vm();
        auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
        current_byte_controller->setPulling(true);
        JSC::MarkedArgumentBuffer arguments;
        arguments.append(current_byte_controller);
        if (arguments.hasOverflowed()) {
            error(global_object, JSC::createOutOfMemoryError(global_object));
            current_byte_controller->setPulling(false);
            return;
        }
        auto call_data = JSC::getCallData(pull);
        JSValue result = JSC::call(
            global_object, pull.getObject(), call_data, current_byte_controller->underlyingSource(), arguments);
        if (scope.exception()) {
            JSValue exception = scope.exception()->value();
            scope.clearExceptionExceptTermination();
            current_byte_controller->setPulling(false);
            error(global_object, exception);
            return;
        }

        auto* promise = dynamicDowncast<JSC::JSPromise>(result);
        if (!promise) {
            current_byte_controller->setPulling(false);
            if (current_byte_controller->pullAgain()) {
                current_byte_controller->setPullAgain(false);
                callPullIfNeeded(global_object);
            }
            return;
        }

        promise->performPromiseThen(vm, global_object, current_byte_controller->pullFulfilledFunction(global_object),
            current_byte_controller->pullRejectedFunction(global_object), JSC::jsUndefined());
        if (scope.exception()) {
            JSValue exception = scope.exception()->value();
            scope.clearExceptionExceptTermination();
            current_byte_controller->setPulling(false);
            error(global_object, exception);
        }
        return;
    }
    auto* current_controller = controller();
    if (!current_controller)
        return;
    if (current_controller->starting())
        return;
    if (current_controller->closeRequested())
        return;
    if (desiredSize() <= 0 && !hasReadRequests())
        return;
    if (current_controller->pulling()) {
        current_controller->setPullAgain(true);
        return;
    }
    JSValue pull = current_controller->pullCallback();
    if (!valueIsCallable(pull))
        return;

    auto& vm = global_object->vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    current_controller->setPulling(true);
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(current_controller);
    if (arguments.hasOverflowed()) {
        error(global_object, JSC::createOutOfMemoryError(global_object));
        current_controller->setPulling(false);
        return;
    }
    auto call_data = JSC::getCallData(pull);
    JSValue result
        = JSC::call(global_object, pull.getObject(), call_data, current_controller->underlyingSource(), arguments);
    if (scope.exception()) {
        JSValue exception = scope.exception()->value();
        scope.clearExceptionExceptTermination();
        current_controller->setPulling(false);
        error(global_object, exception);
        return;
    }

    auto* promise = dynamicDowncast<JSC::JSPromise>(result);
    if (!promise) {
        current_controller->setPulling(false);
        if (current_controller->pullAgain()) {
            current_controller->setPullAgain(false);
            callPullIfNeeded(global_object);
        }
        return;
    }

    promise->performPromiseThen(vm, global_object, current_controller->pullFulfilledFunction(global_object),
        current_controller->pullRejectedFunction(global_object), JSC::jsUndefined());
    if (scope.exception()) {
        JSValue exception = scope.exception()->value();
        scope.clearExceptionExceptTermination();
        current_controller->setPulling(false);
        error(global_object, exception);
    }
}

static EncodedJSValue startFulfilledCallback(JSC::JSGlobalObject* global_object, JSC::CallFrame* call_frame)
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* function = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee());
    auto controller_value = function->get(global_object, readableStreamControllerIdentifier(global_object));
    RETURN_IF_EXCEPTION(scope, {});
    JSColloReadableStream* stream = nullptr;
    if (auto* controller = dynamicDowncast<JSColloReadableStreamDefaultController>(controller_value)) {
        controller->setStarting(false);
        stream = controller->stream();
    } else if (auto* byte_controller = dynamicDowncast<JSColloReadableByteStreamController>(controller_value)) {
        byte_controller->setStarting(false);
        stream = byte_controller->stream();
    } else {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream start controller is unavailable"_s);
        return {};
    }
    if (stream)
        stream->callPullIfNeeded(global_object);
    return JSValue::encode(JSC::jsUndefined());
}

static EncodedJSValue startRejectedCallback(JSC::JSGlobalObject* global_object, JSC::CallFrame* call_frame)
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* function = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee());
    auto controller_value = function->get(global_object, readableStreamControllerIdentifier(global_object));
    RETURN_IF_EXCEPTION(scope, {});
    JSColloReadableStream* stream = nullptr;
    if (auto* controller = dynamicDowncast<JSColloReadableStreamDefaultController>(controller_value)) {
        controller->setStarting(false);
        stream = controller->stream();
    } else if (auto* byte_controller = dynamicDowncast<JSColloReadableByteStreamController>(controller_value)) {
        byte_controller->setStarting(false);
        stream = byte_controller->stream();
    } else {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream start controller is unavailable"_s);
        return {};
    }
    if (stream)
        stream->error(global_object, call_frame->argument(0));
    return JSValue::encode(JSC::jsUndefined());
}

// ReadableStream.from keeps the iterator, its next method, whether it is async, a done flag, the stream's controller
// and the cached reaction functions in a plain object with non-enumerable properties. The pull and cancel functions
// and every reaction find it through a property of their own. clearReadableStreamFromState marks it done and drops
// its references once the iterator is exhausted, fails or is canceled.
static JSC::JSObject* readableStreamFromStateFromFunction(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSFunction* function)
{
    JSValue state_value = function->getDirect(global_object->vm(), readableStreamFromStateIdentifier(global_object));
    auto* state = state_value.getObject();
    if (!state)
        JSC::throwVMTypeError(global_object, scope, "ReadableStream.from state is unavailable"_s);
    return state;
}

static bool readableStreamFromStateDone(JSC::JSGlobalObject* global_object, JSC::JSObject* state)
{
    JSValue value = state->getDirect(global_object->vm(), readableStreamFromDoneIdentifier(global_object));
    return value.isBoolean() && value.asBoolean();
}

static void readableStreamFromSetDone(JSC::JSGlobalObject* global_object, JSC::JSObject* state, bool value)
{
    state->putDirect(global_object->vm(), readableStreamFromDoneIdentifier(global_object), JSC::jsBoolean(value),
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
}

static void clearReadableStreamFromState(JSC::JSGlobalObject* global_object, JSC::JSObject* state)
{
    auto& vm = global_object->vm();
    constexpr unsigned state_property_attributes = static_cast<unsigned>(JSC::PropertyAttribute::DontEnum);
    readableStreamFromSetDone(global_object, state, true);
    state->putDirect(
        vm, readableStreamFromIteratorIdentifier(global_object), JSC::jsUndefined(), state_property_attributes);
    state->putDirect(
        vm, readableStreamFromNextIdentifier(global_object), JSC::jsUndefined(), state_property_attributes);
    state->putDirect(
        vm, readableStreamControllerIdentifier(global_object), JSC::jsUndefined(), state_property_attributes);
    state->putDirect(
        vm, readableStreamFromNextFulfilledIdentifier(global_object), JSC::jsUndefined(), state_property_attributes);
    state->putDirect(
        vm, readableStreamFromNextRejectedIdentifier(global_object), JSC::jsUndefined(), state_property_attributes);
    state->putDirect(
        vm, readableStreamFromValueFulfilledIdentifier(global_object), JSC::jsUndefined(), state_property_attributes);
    state->putDirect(
        vm, readableStreamFromValueRejectedIdentifier(global_object), JSC::jsUndefined(), state_property_attributes);
    state->putDirect(
        vm, readableStreamFromReturnFulfilledIdentifier(global_object), JSC::jsUndefined(), state_property_attributes);
    state->putDirect(
        vm, readableStreamFromReturnRejectedIdentifier(global_object), JSC::jsUndefined(), state_property_attributes);
}

static JSColloReadableStreamDefaultController* readableStreamFromController(
    JSC::JSGlobalObject* global_object, JSC::JSObject* state)
{
    JSValue value = state->getDirect(global_object->vm(), readableStreamControllerIdentifier(global_object));
    if (!value || !value.isObject())
        return nullptr;
    return dynamicDowncast<JSColloReadableStreamDefaultController>(value);
}

static JSC::JSFunction* cachedReadableStreamFromCallback(JSC::JSGlobalObject* global_object, JSC::JSObject* state,
    const JSC::Identifier& callback_identifier, WTF::ASCIILiteral name, JSC::NativeFunction callback)
{
    auto& vm = global_object->vm();
    JSValue existing = state->getDirect(vm, callback_identifier);
    if (existing && existing.isObject()) {
        if (auto* function = dynamicDowncast<JSC::JSFunction>(existing))
            return function;
    }
    auto* function
        = JSC::JSFunction::create(vm, global_object, 1, name, callback, JSC::ImplementationVisibility::Public);
    function->putDirect(vm, readableStreamFromStateIdentifier(global_object), state,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    state->putDirect(vm, callback_identifier, function, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    return function;
}

static JSValue readableStreamFromProcessValue(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* state, JSValue value)
{
    if (readableStreamFromStateDone(global_object, state))
        return JSC::jsUndefined();
    auto* controller = readableStreamFromController(global_object, state);
    auto* stream = controller ? controller->stream() : nullptr;
    if (!stream || stream->state() != StreamState::Readable)
        return JSC::jsUndefined();
    if (!stream->enqueue(global_object, scope, value)) {
        clearReadableStreamFromState(global_object, state);
        return {};
    }
    RETURN_IF_EXCEPTION(scope, {});
    return JSC::jsUndefined();
}

static JSValue readableStreamFromProcessIteratorResult(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSC::JSObject* state, JSValue result, bool unwrap_sync_value);

// A sync iterator read through ReadableStream.from is wrapped as an async-from-sync iterator, and ECMA-262's
// AsyncFromSyncIteratorContinuation closes the sync iterator when a value it yielded is a promise that rejects.
// Returns the reason the read rejects with. An async iterator is left open.
static JSValue readableStreamFromCloseSyncIteratorOnRejectedValue(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* state, JSValue original_error)
{
    auto& vm = global_object->vm();
    JSValue is_async = state->getDirect(vm, readableStreamFromIsAsyncIdentifier(global_object));
    if (is_async.isBoolean() && is_async.asBoolean())
        return original_error;

    JSValue iterator_value = state->getDirect(vm, readableStreamFromIteratorIdentifier(global_object));
    auto* iterator = iterator_value.getObject();
    if (!iterator)
        return original_error;

    auto catch_scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    JSValue return_method = iterator_value.get(global_object, vm.propertyNames->returnKeyword);
    if (catch_scope.exception()) {
        JSValue error = catch_scope.exception()->value();
        if (!catch_scope.clearExceptionExceptTermination())
            return original_error;
        return error;
    }
    if (!valueIsCallable(return_method))
        return original_error;

    JSC::MarkedArgumentBuffer arguments;
    if (arguments.hasOverflowed()) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return {};
    }
    auto call_data = JSC::getCallData(return_method);
    JSC::call(global_object, return_method.getObject(), call_data, iterator_value, arguments);
    if (catch_scope.exception()) {
        JSValue error = catch_scope.exception()->value();
        if (!catch_scope.clearExceptionExceptTermination())
            return original_error;
        return error;
    }
    return original_error;
}

JSC_DEFINE_HOST_FUNCTION(
    readableStreamFromValueFulfilled, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* function = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee());
    auto* state = readableStreamFromStateFromFunction(global_object, scope, function);
    RETURN_IF_EXCEPTION(scope, {});
    if (readableStreamFromStateDone(global_object, state))
        return JSValue::encode(JSC::jsUndefined());
    JSValue result = readableStreamFromProcessValue(global_object, scope, state, call_frame->argument(0));
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(result);
}

JSC_DEFINE_HOST_FUNCTION(
    readableStreamFromValueRejected, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* function = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee());
    auto* state = readableStreamFromStateFromFunction(global_object, scope, function);
    RETURN_IF_EXCEPTION(scope, {});
    if (readableStreamFromStateDone(global_object, state))
        return JSValue::encode(JSC::jsUndefined());
    JSValue error
        = readableStreamFromCloseSyncIteratorOnRejectedValue(global_object, scope, state, call_frame->argument(0));
    RETURN_IF_EXCEPTION(scope, {});
    clearReadableStreamFromState(global_object, state);
    return JSValue::encode(JSC::throwException(global_object, scope, error));
}

static JSValue readableStreamFromProcessIteratorResult(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSC::JSObject* state, JSValue result, bool unwrap_sync_value)
{
    if (readableStreamFromStateDone(global_object, state))
        return JSC::jsUndefined();

    auto* result_object = result.getObject();
    if (!result_object) {
        clearReadableStreamFromState(global_object, state);
        return JSC::throwException(global_object, scope,
            JSC::createTypeError(global_object, "ReadableStream.from iterator result must be an object"_s));
    }

    auto& vm = global_object->vm();
    JSValue done_value = result.get(global_object, vm.propertyNames->done);
    if (scope.exception()) {
        clearReadableStreamFromState(global_object, state);
        return {};
    }
    const bool done = done_value.toBoolean(global_object);
    if (scope.exception()) {
        clearReadableStreamFromState(global_object, state);
        return {};
    }
    if (done) {
        if (auto* controller = readableStreamFromController(global_object, state)) {
            if (auto* stream = controller->stream())
                stream->close(global_object);
        }
        clearReadableStreamFromState(global_object, state);
        return JSC::jsUndefined();
    }

    JSValue value = result.get(global_object, vm.propertyNames->value);
    if (scope.exception()) {
        clearReadableStreamFromState(global_object, state);
        return {};
    }
    if (!unwrap_sync_value)
        return readableStreamFromProcessValue(global_object, scope, state, value);

    auto* value_promise = JSC::JSPromise::resolvedPromise(global_object, value);
    if (scope.exception()) {
        clearReadableStreamFromState(global_object, state);
        return {};
    }
    auto* output_promise = JSC::JSPromise::create(vm, global_object->promiseStructure());
    auto* fulfilled = cachedReadableStreamFromCallback(global_object, state,
        readableStreamFromValueFulfilledIdentifier(global_object), "ReadableStream.from value fulfilled"_s,
        readableStreamFromValueFulfilled);
    auto* rejected = cachedReadableStreamFromCallback(global_object, state,
        readableStreamFromValueRejectedIdentifier(global_object), "ReadableStream.from value rejected"_s,
        readableStreamFromValueRejected);
    value_promise->performPromiseThen(vm, global_object, fulfilled, rejected, output_promise);
    if (scope.exception()) {
        clearReadableStreamFromState(global_object, state);
        return {};
    }
    return output_promise;
}

JSC_DEFINE_HOST_FUNCTION(
    readableStreamFromNextFulfilled, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* function = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee());
    auto* state = readableStreamFromStateFromFunction(global_object, scope, function);
    RETURN_IF_EXCEPTION(scope, {});
    if (readableStreamFromStateDone(global_object, state))
        return JSValue::encode(JSC::jsUndefined());
    JSValue result
        = readableStreamFromProcessIteratorResult(global_object, scope, state, call_frame->argument(0), false);
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(result);
}

JSC_DEFINE_HOST_FUNCTION(
    readableStreamFromNextRejected, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* function = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee());
    auto* state = readableStreamFromStateFromFunction(global_object, scope, function);
    RETURN_IF_EXCEPTION(scope, {});
    if (readableStreamFromStateDone(global_object, state))
        return JSValue::encode(JSC::jsUndefined());
    clearReadableStreamFromState(global_object, state);
    return JSValue::encode(JSC::throwException(global_object, scope, call_frame->argument(0)));
}

JSC_DEFINE_HOST_FUNCTION(readableStreamFromPull, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* function = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee());
    auto* state = readableStreamFromStateFromFunction(global_object, scope, function);
    RETURN_IF_EXCEPTION(scope, {});
    if (readableStreamFromStateDone(global_object, state))
        return JSValue::encode(JSC::jsUndefined());

    JSValue iterator_value = state->getDirect(vm, readableStreamFromIteratorIdentifier(global_object));
    auto* iterator = iterator_value.getObject();
    if (!iterator) {
        clearReadableStreamFromState(global_object, state);
        JSC::throwVMTypeError(global_object, scope, "ReadableStream.from iterator is unavailable"_s);
        return {};
    }
    JSValue next = state->getDirect(vm, readableStreamFromNextIdentifier(global_object));
    if (!valueIsCallable(next)) {
        clearReadableStreamFromState(global_object, state);
        JSC::throwVMTypeError(global_object, scope, "ReadableStream.from iterator next must be callable"_s);
        return {};
    }

    JSC::MarkedArgumentBuffer arguments;
    if (arguments.hasOverflowed()) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return {};
    }
    auto call_data = JSC::getCallData(next);
    JSValue next_result = JSC::call(global_object, next.getObject(), call_data, iterator_value, arguments);
    if (scope.exception()) {
        clearReadableStreamFromState(global_object, state);
        return {};
    }

    JSValue is_async = state->getDirect(vm, readableStreamFromIsAsyncIdentifier(global_object));
    if (!is_async.isBoolean() || !is_async.asBoolean()) {
        JSValue result = readableStreamFromProcessIteratorResult(global_object, scope, state, next_result, true);
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(result);
    }

    auto* next_promise = JSC::JSPromise::resolvedPromise(global_object, next_result);
    if (scope.exception()) {
        clearReadableStreamFromState(global_object, state);
        return {};
    }
    auto* output_promise = JSC::JSPromise::create(vm, global_object->promiseStructure());
    auto* fulfilled = cachedReadableStreamFromCallback(global_object, state,
        readableStreamFromNextFulfilledIdentifier(global_object), "ReadableStream.from next fulfilled"_s,
        readableStreamFromNextFulfilled);
    auto* rejected = cachedReadableStreamFromCallback(global_object, state,
        readableStreamFromNextRejectedIdentifier(global_object), "ReadableStream.from next rejected"_s,
        readableStreamFromNextRejected);
    next_promise->performPromiseThen(vm, global_object, fulfilled, rejected, output_promise);
    if (scope.exception()) {
        clearReadableStreamFromState(global_object, state);
        return {};
    }
    return JSValue::encode(output_promise);
}

JSC_DEFINE_HOST_FUNCTION(
    readableStreamFromReturnFulfilled, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (!call_frame->argument(0).isObject()) {
        return JSValue::encode(JSC::throwException(global_object, scope,
            JSC::createTypeError(global_object, "ReadableStream.from iterator return result must be an object"_s)));
    }
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(
    readableStreamFromReturnRejected, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSValue::encode(JSC::throwException(global_object, scope, call_frame->argument(0)));
}

JSC_DEFINE_HOST_FUNCTION(readableStreamFromCancel, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* function = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee());
    auto* state = readableStreamFromStateFromFunction(global_object, scope, function);
    RETURN_IF_EXCEPTION(scope, {});
    if (readableStreamFromStateDone(global_object, state))
        return JSValue::encode(JSC::jsUndefined());

    JSValue iterator_value = state->getDirect(vm, readableStreamFromIteratorIdentifier(global_object));
    auto* iterator = iterator_value.getObject();
    if (!iterator) {
        clearReadableStreamFromState(global_object, state);
        JSC::throwVMTypeError(global_object, scope, "ReadableStream.from iterator is unavailable"_s);
        return {};
    }

    readableStreamFromSetDone(global_object, state, true);
    JSValue return_method = iterator_value.get(global_object, vm.propertyNames->returnKeyword);
    if (scope.exception()) {
        clearReadableStreamFromState(global_object, state);
        return {};
    }
    if (return_method.isUndefinedOrNull()) {
        clearReadableStreamFromState(global_object, state);
        return JSValue::encode(JSC::jsUndefined());
    }
    if (!valueIsCallable(return_method)) {
        clearReadableStreamFromState(global_object, state);
        JSC::throwVMTypeError(global_object, scope, "ReadableStream.from iterator return must be callable"_s);
        return {};
    }

    JSC::MarkedArgumentBuffer arguments;
    arguments.append(call_frame->argument(0));
    if (arguments.hasOverflowed()) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return {};
    }
    auto call_data = JSC::getCallData(return_method);
    JSValue return_result = JSC::call(global_object, return_method.getObject(), call_data, iterator_value, arguments);
    if (scope.exception()) {
        clearReadableStreamFromState(global_object, state);
        return {};
    }

    auto* return_promise = JSC::JSPromise::resolvedPromise(global_object, return_result);
    if (scope.exception()) {
        clearReadableStreamFromState(global_object, state);
        return {};
    }
    auto* output_promise = JSC::JSPromise::create(vm, global_object->promiseStructure());
    auto* fulfilled = cachedReadableStreamFromCallback(global_object, state,
        readableStreamFromReturnFulfilledIdentifier(global_object), "ReadableStream.from return fulfilled"_s,
        readableStreamFromReturnFulfilled);
    auto* rejected = cachedReadableStreamFromCallback(global_object, state,
        readableStreamFromReturnRejectedIdentifier(global_object), "ReadableStream.from return rejected"_s,
        readableStreamFromReturnRejected);
    return_promise->performPromiseThen(vm, global_object, fulfilled, rejected, output_promise);
    if (scope.exception()) {
        clearReadableStreamFromState(global_object, state);
        return {};
    }
    clearReadableStreamFromState(global_object, state);
    return JSValue::encode(output_promise);
}

JSC_DEFINE_HOST_FUNCTION(readableStreamConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "ReadableStream constructor requires 'new'"_s);
}

JSC_DEFINE_HOST_FUNCTION(readableStreamFrom, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    JSValue iterable = call_frame->argument(0);

    bool is_async = false;
    JSValue iterator_method = iterable.get(global_object, vm.propertyNames->asyncIteratorSymbol);
    RETURN_IF_EXCEPTION(scope, {});
    if (!iterator_method.isUndefinedOrNull()) {
        if (!valueIsCallable(iterator_method)) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream.from @@asyncIterator must be callable"_s);
            return {};
        }
        is_async = true;
    } else {
        iterator_method = iterable.get(global_object, vm.propertyNames->iteratorSymbol);
        RETURN_IF_EXCEPTION(scope, {});
        if (iterator_method.isUndefinedOrNull()) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream.from input must be iterable"_s);
            return {};
        }
        if (!valueIsCallable(iterator_method)) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream.from @@iterator must be callable"_s);
            return {};
        }
    }

    JSC::MarkedArgumentBuffer iterator_arguments;
    if (iterator_arguments.hasOverflowed()) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return {};
    }
    auto iterator_call_data = JSC::getCallData(iterator_method);
    JSValue iterator_value
        = JSC::call(global_object, iterator_method.getObject(), iterator_call_data, iterable, iterator_arguments);
    RETURN_IF_EXCEPTION(scope, {});
    auto* iterator = iterator_value.getObject();
    if (!iterator) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream.from iterator must be an object"_s);
        return {};
    }

    JSValue next_method = iterator_value.get(global_object, vm.propertyNames->next);
    RETURN_IF_EXCEPTION(scope, {});
    if (!valueIsCallable(next_method)) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream.from iterator next must be callable"_s);
        return {};
    }

    auto* state = JSC::constructEmptyObject(global_object, global_object->objectPrototype(), 10);
    state->putDirect(vm, readableStreamFromIteratorIdentifier(global_object), iterator,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    state->putDirect(vm, readableStreamFromNextIdentifier(global_object), next_method,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    state->putDirect(vm, readableStreamFromIsAsyncIdentifier(global_object), JSC::jsBoolean(is_async),
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    state->putDirect(vm, readableStreamFromDoneIdentifier(global_object), JSC::jsBoolean(false),
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    auto* pull = JSC::JSFunction::create(vm, global_object, 1, "ReadableStream.from pull"_s, readableStreamFromPull,
        JSC::ImplementationVisibility::Public);
    pull->putDirect(vm, readableStreamFromStateIdentifier(global_object), state,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    auto* cancel = JSC::JSFunction::create(vm, global_object, 1, "ReadableStream.from cancel"_s,
        readableStreamFromCancel, JSC::ImplementationVisibility::Public);
    cancel->putDirect(vm, readableStreamFromStateIdentifier(global_object), state,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    auto* stream = JSColloReadableStream::create(vm, collo_global);
    stream->setHighWaterMark(0);
    auto* controller = JSColloReadableStreamDefaultController::create(vm, global_object, stream);
    controller->setCallbacks(vm, pull, cancel, JSC::jsUndefined());
    stream->setController(vm, controller);
    state->putDirect(vm, readableStreamControllerIdentifier(global_object), controller,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    stream->callPullIfNeeded(global_object);
    return JSValue::encode(stream);
}

static bool parseReadableStreamSourceType(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* source_object, bool& out_is_bytes)
{
    out_is_bytes = false;
    auto& vm = global_object->vm();
    JSValue type = source_object->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "type"_s));
    RETURN_IF_EXCEPTION(scope, false);
    if (type.isEmpty() || type.isUndefined())
        return true;

    WTF::String type_string = type.toWTFString(global_object);
    RETURN_IF_EXCEPTION(scope, false);
    if (type_string == "bytes"_s) {
        out_is_bytes = true;
        return true;
    }
    JSC::throwVMTypeError(global_object, scope, "ReadableStream underlying source type is not supported"_s);
    return false;
}

// Converts strategy as a Web IDL QueuingStrategy dictionary. Members are read in lexicographic order (highWaterMark,
// then size), an undefined member counts as absent, and undefined or null converts to an empty dictionary. On success
// out_has_high_water_mark says whether highWaterMark was present, out_high_water_mark holds it as a number, and
// out_size holds the size callback or undefined. The range check is ExtractHighWaterMark, which the constructor steps
// run later through validateHighWaterMark. Throws a TypeError prefixed with context for a strategy that is not an
// object or a size that is not callable, and returns false whenever an exception is pending.
bool parseQueuingStrategy(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue strategy,
    WTF::ASCIILiteral context, bool& out_has_high_water_mark, double& out_high_water_mark, JSValue& out_size)
{
    out_has_high_water_mark = false;
    out_high_water_mark = 0;
    out_size = JSC::jsUndefined();
    if (strategy.isUndefinedOrNull())
        return true;
    if (!strategy.isObject()) {
        JSC::throwException(global_object, scope,
            JSC::createTypeError(global_object, WTF::makeString(context, " strategy must be an object"_s)));
        return false;
    }

    auto& vm = global_object->vm();
    auto* strategy_object = strategy.getObject();
    JSValue high_water_mark
        = strategy_object->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "highWaterMark"_s));
    RETURN_IF_EXCEPTION(scope, false);
    if (!high_water_mark.isEmpty() && !high_water_mark.isUndefined()) {
        out_high_water_mark = high_water_mark.toNumber(global_object);
        RETURN_IF_EXCEPTION(scope, false);
        out_has_high_water_mark = true;
    }

    JSValue size = strategy_object->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "size"_s));
    RETURN_IF_EXCEPTION(scope, false);
    if (!size.isEmpty() && !size.isUndefined()) {
        if (!valueIsCallable(size)) {
            JSC::throwException(global_object, scope,
                JSC::createTypeError(global_object, WTF::makeString(context, " strategy size must be callable"_s)));
            return false;
        }
        out_size = size;
    }
    return true;
}

// ExtractHighWaterMark: the default when the strategy had no highWaterMark, otherwise the given value, unless it is NaN
// or negative, which throws a RangeError prefixed with context and returns false.
bool validateHighWaterMark(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, WTF::ASCIILiteral context,
    bool has_high_water_mark, double default_high_water_mark, double& high_water_mark)
{
    if (!has_high_water_mark) {
        high_water_mark = default_high_water_mark;
        return true;
    }
    if (std::isnan(high_water_mark) || high_water_mark < 0) {
        JSC::throwException(global_object, scope,
            JSC::createRangeError(
                global_object, WTF::makeString(context, " highWaterMark must be a non-negative number"_s)));
        return false;
    }
    return true;
}

// Returns the base structure, or one derived from new.target when a subclass constructs. Returns null with an
// exception pending when deriving throws.
JSC::Structure* streamStructureForNewTarget(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame, JSC::Structure* base)
{
    auto* new_target = call_frame->newTarget().getObject();
    auto* constructor = call_frame->jsCallee();
    if (!new_target || new_target == constructor)
        return base;
    auto* structure = JSC::InternalFunction::createSubclassStructure(global_object, new_target, base);
    RETURN_IF_EXCEPTION(scope, nullptr);
    return structure;
}

JSC_DEFINE_HOST_FUNCTION(
    readableStreamConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    JSValue underlying_source = call_frame->argument(0);
    if (underlying_source.isUndefined())
        underlying_source = JSC::constructEmptyObject(global_object);
    if (!underlying_source.isObject()) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream underlying source must be an object"_s);
        return {};
    }

    auto* stream_structure
        = streamStructureForNewTarget(global_object, scope, call_frame, collo_global->readableStreamStructure());
    RETURN_IF_EXCEPTION(scope, {});
    auto* stream = JSColloReadableStream::createWithStructure(vm, stream_structure);

    // Web IDL argument conversion reads the strategy dictionary before the constructor steps convert the underlying
    // source dictionary, whose members are read in lexicographic order: autoAllocateChunkSize, cancel, pull, start,
    // type. Range validation runs after all members are read.
    bool has_high_water_mark = false;
    double high_water_mark = 0;
    JSValue size_callback = JSC::jsUndefined();
    if (!parseQueuingStrategy(global_object, scope, call_frame->argument(1), "ReadableStream"_s, has_high_water_mark,
            high_water_mark, size_callback))
        return {};
    RETURN_IF_EXCEPTION(scope, {});

    auto* source_object = underlying_source.getObject();
    bool has_auto_allocate = false;
    size_t auto_allocate_chunk_size = 0;
    JSValue auto_allocate
        = source_object->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "autoAllocateChunkSize"_s));
    RETURN_IF_EXCEPTION(scope, {});
    if (!auto_allocate.isEmpty() && !auto_allocate.isUndefined()) {
        // The [EnforceRange] unsigned long long conversion throws a TypeError for a non-finite or negative value as
        // soon as the member is read.
        double value = auto_allocate.toNumber(global_object);
        RETURN_IF_EXCEPTION(scope, {});
        if (std::isnan(value) || !std::isfinite(value) || value < 0
            || value > static_cast<double>(std::numeric_limits<size_t>::max())) {
            JSC::throwException(global_object, scope,
                JSC::createTypeError(global_object, "ReadableStream autoAllocateChunkSize is out of range"_s));
            return {};
        }
        has_auto_allocate = true;
        auto_allocate_chunk_size = static_cast<size_t>(std::trunc(value));
    }
    JSValue cancel = JSC::jsUndefined();
    if (!strictCallbackPropertyOrUndefined(
            global_object, scope, source_object, "cancel"_s, "ReadableStream cancel"_s, cancel))
        return {};
    RETURN_IF_EXCEPTION(scope, {});
    JSValue pull = JSC::jsUndefined();
    if (!strictCallbackPropertyOrUndefined(
            global_object, scope, source_object, "pull"_s, "ReadableStream pull"_s, pull))
        return {};
    RETURN_IF_EXCEPTION(scope, {});
    JSValue start = JSC::jsUndefined();
    if (!strictCallbackPropertyOrUndefined(
            global_object, scope, source_object, "start"_s, "ReadableStream start"_s, start))
        return {};
    RETURN_IF_EXCEPTION(scope, {});
    bool is_bytes = false;
    if (!parseReadableStreamSourceType(global_object, scope, source_object, is_bytes))
        return {};
    RETURN_IF_EXCEPTION(scope, {});

    if (is_bytes && !size_callback.isUndefined()) {
        JSC::throwException(global_object, scope,
            JSC::createRangeError(global_object, "ReadableStream byte stream strategy size is invalid"_s));
        return {};
    }
    if (!validateHighWaterMark(
            global_object, scope, "ReadableStream"_s, has_high_water_mark, is_bytes ? 0 : 1, high_water_mark))
        return {};
    if (is_bytes && has_auto_allocate && !auto_allocate_chunk_size) {
        JSC::throwException(global_object, scope,
            JSC::createTypeError(global_object, "ReadableStream autoAllocateChunkSize must not be zero"_s));
        return {};
    }
    if (!is_bytes)
        auto_allocate_chunk_size = 0;
    stream->setHighWaterMark(high_water_mark);
    stream->setByteStream(is_bytes);

    JSValue controller_value = JSC::jsUndefined();
    JSColloReadableStreamDefaultController* controller = nullptr;
    JSColloReadableByteStreamController* byte_controller = nullptr;
    if (is_bytes) {
        byte_controller = JSColloReadableByteStreamController::create(vm, global_object, stream);
        byte_controller->setCallbacks(vm, pull, cancel);
        byte_controller->setUnderlyingSource(vm, underlying_source);
        byte_controller->setAutoAllocateChunkSize(auto_allocate_chunk_size);
        stream->setByteController(vm, byte_controller);
        controller_value = byte_controller;
    } else {
        controller = JSColloReadableStreamDefaultController::create(vm, global_object, stream);
        controller->setCallbacks(vm, pull, cancel, size_callback);
        controller->setUnderlyingSource(vm, underlying_source);
        stream->setController(vm, controller);
        controller_value = controller;
    }

    if (controller)
        controller->setStarting(true);
    if (byte_controller)
        byte_controller->setStarting(true);

    JSValue start_result = JSC::jsUndefined();
    if (valueIsCallable(start)) {
        JSC::MarkedArgumentBuffer arguments;
        arguments.append(controller_value);
        if (arguments.hasOverflowed()) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return {};
        }
        auto call_data = JSC::getCallData(start);
        start_result = JSC::call(global_object, start.getObject(), call_data, underlying_source, arguments);
        RETURN_IF_EXCEPTION(scope, {});
    }

    auto* start_promise = dynamicDowncast<JSC::JSPromise>(start_result);
    if (!start_promise)
        start_promise = JSC::JSPromise::resolvedPromise(global_object, start_result);
    auto* fulfilled = JSC::JSFunction::create(vm, global_object, 1, "ReadableStream start fulfilled"_s,
        startFulfilledCallback, JSC::ImplementationVisibility::Public);
    auto* rejected = JSC::JSFunction::create(vm, global_object, 1, "ReadableStream start rejected"_s,
        startRejectedCallback, JSC::ImplementationVisibility::Public);
    fulfilled->putDirect(vm, readableStreamControllerIdentifier(global_object), controller_value,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    rejected->putDirect(vm, readableStreamControllerIdentifier(global_object), controller_value,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    start_promise->performPromiseThen(vm, global_object, fulfilled, rejected, JSC::jsUndefined());
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(stream);
}

JSC_DEFINE_HOST_FUNCTION(defaultReaderConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "ReadableStreamDefaultReader constructor requires 'new'"_s);
}

JSC_DEFINE_HOST_FUNCTION(
    defaultReaderConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream = requireReadableStream(global_object, scope, call_frame->argument(0));
    RETURN_IF_EXCEPTION(scope, {});
    if (stream->locked()) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream is already locked"_s);
        return {};
    }
    auto* reader = JSColloReadableStreamDefaultReader::create(vm, global_object, stream);
    RETURN_IF_EXCEPTION(scope, {});
    if (!reader)
        return {};
    stream->lock(vm, reader);
    return JSValue::encode(reader);
}

JSC_DEFINE_HOST_FUNCTION(byobReaderConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "ReadableStreamBYOBReader constructor requires 'new'"_s);
}

JSC_DEFINE_HOST_FUNCTION(
    byobReaderConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream = requireReadableStream(global_object, scope, call_frame->argument(0));
    RETURN_IF_EXCEPTION(scope, {});
    if (!stream->isByteStream()) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream is not a byte stream"_s);
        return {};
    }
    if (stream->locked()) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream is already locked"_s);
        return {};
    }
    auto* default_reader = JSColloReadableStreamDefaultReader::create(vm, global_object, stream);
    RETURN_IF_EXCEPTION(scope, {});
    if (!default_reader)
        return {};
    stream->lock(vm, default_reader);
    auto* reader = JSColloReadableStreamBYOBReader::create(vm, global_object, stream, default_reader);
    return JSValue::encode(reader);
}

JSC_DEFINE_HOST_FUNCTION(byobReaderRead, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* reader = requireReadableStreamBYOBReader(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    auto* stream = reader->stream();
    if (!stream)
        return rejectedTypeError(global_object, scope, "ReadableStream BYOB reader has no stream"_s);
    auto* view = dynamicDowncast<JSC::JSArrayBufferView>(call_frame->argument(0));
    if (!view) {
        return rejectedTypeError(global_object, scope, "ReadableStream BYOB view must be an ArrayBufferView"_s);
    }
    if (arrayBufferViewIsUnavailable(view)) {
        return rejectedTypeError(global_object, scope, "ReadableStream BYOB view is detached or out of bounds"_s);
    }
    if (view->byteLength() == 0) {
        return rejectedTypeError(global_object, scope, "ReadableStream BYOB view must not be empty"_s);
    }
    size_t min_elements = 1;
    JSValue options = call_frame->argument(1);
    if (!options.isUndefined()) {
        auto* options_object = options.getObject();
        if (!options_object)
            return rejectedTypeError(global_object, scope, "ReadableStream BYOB read options must be an object"_s);
        JSValue min_value = options_object->get(global_object, JSC::Identifier::fromString(vm, "min"_s));
        RETURN_IF_EXCEPTION(scope, {});
        if (!min_value.isUndefined()) {
            // [EnforceRange] unsigned long long: a non-finite value, or one out of range after truncation, rejects
            // the read with a TypeError.
            double min_number = min_value.toNumber(global_object);
            RETURN_IF_EXCEPTION(scope, {});
            if (std::isnan(min_number) || std::isinf(min_number))
                return rejectedTypeError(
                    global_object, scope, "ReadableStream BYOB read min must be a finite number"_s);
            min_number = std::trunc(min_number);
            if (min_number < 0 || min_number > static_cast<double>(std::numeric_limits<size_t>::max()))
                return rejectedTypeError(global_object, scope, "ReadableStream BYOB read min is out of range"_s);
            if (min_number == 0)
                return rejectedTypeError(
                    global_object, scope, "ReadableStream BYOB read min must be greater than zero"_s);
            min_elements = static_cast<size_t>(min_number);
        }
    }

    const auto view_type = JSC::typedArrayType(view->type());
    const size_t element_count = view_type == JSC::TypeDataView ? view->byteLength() : view->length();
    if (min_elements > element_count)
        return rejectedPromise(global_object, scope,
            JSC::createRangeError(global_object, "ReadableStream BYOB read min exceeds view length"_s));
    const size_t element_size = JSC::elementSize(view_type);
    if (min_elements > std::numeric_limits<size_t>::max() / element_size)
        return rejectedPromise(
            global_object, scope, JSC::createRangeError(global_object, "ReadableStream BYOB read min is too large"_s));
    return stream->readInto(global_object, scope, view, min_elements * element_size);
}

JSC_DEFINE_HOST_FUNCTION(byobReaderCancel, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* reader = requireReadableStreamBYOBReader(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    auto* stream = reader->stream();
    if (!stream)
        return rejectedTypeError(global_object, scope, "ReadableStream BYOB reader has no stream"_s);
    return stream->cancel(global_object, scope, call_frame->argument(0));
}

JSC_DEFINE_HOST_FUNCTION(byobReaderReleaseLock, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* reader = requireReadableStreamBYOBReader(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    reader->release(global_object);
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(byobReaderClosed, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* reader = requireReadableStreamBYOBReader(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(reader->closedPromise());
}

JSC_DEFINE_HOST_FUNCTION(byobRequestConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "ReadableStreamBYOBRequest constructor is not public"_s);
}

JSC_DEFINE_HOST_FUNCTION(byobRequestConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "ReadableStreamBYOBRequest constructor is not public"_s);
}

JSC_DEFINE_HOST_FUNCTION(byobRequestView, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* request = requireReadableStreamBYOBRequest(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    if (auto* view = request->view())
        return JSValue::encode(view);
    return JSValue::encode(JSC::jsNull());
}

JSC_DEFINE_HOST_FUNCTION(byobRequestRespond, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* request = requireReadableStreamBYOBRequest(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    auto* stream = request->stream();
    if (!stream) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream BYOB request has no stream"_s);
        return {};
    }
    // [EnforceRange] unsigned long long: a non-finite value, or one out of range after truncation, throws a TypeError.
    double number = call_frame->argument(0).toNumber(global_object);
    RETURN_IF_EXCEPTION(scope, {});
    if (std::isnan(number) || std::isinf(number)) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream BYOB bytesWritten must be a finite number"_s);
        return {};
    }
    number = std::trunc(number);
    if (number < 0 || number > static_cast<double>(std::numeric_limits<size_t>::max())) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream BYOB bytesWritten is out of range"_s);
        return {};
    }
    stream->settleByobRequestWithBytes(global_object, scope, request, static_cast<size_t>(number));
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(
    byobRequestRespondWithNewView, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* request = requireReadableStreamBYOBRequest(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    auto* stream = request->stream();
    if (!stream) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream BYOB request has no stream"_s);
        return {};
    }
    auto* view = requireArrayBufferView(global_object, scope, call_frame->argument(0), "view"_s);
    RETURN_IF_EXCEPTION(scope, {});
    stream->settleByobRequestWithView(global_object, scope, request, view);
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(JSC::jsUndefined());
}

} // namespace Collo::HostFunctions
