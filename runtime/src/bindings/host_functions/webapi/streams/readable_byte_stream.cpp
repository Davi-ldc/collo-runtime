// The byte stream half of the ReadableStream algorithms: ReadableByteStreamControllerEnqueue, BYOB reads and their
// pending pull-intos, the BYOB request's respond and respondWithNewView, and the byte queue a BYOB read drains. Runs
// on the VM thread.
//
// A pending BYOB read is a pull-into descriptor and its read request in one ByobReadRequest: the view it fills, over a
// buffer transferred from the caller's view when the read was issued, and how many bytes it holds. Only the first
// pending read has a BYOB request, which a fresh one replaces each time the read's remaining view changes. The
// allocations here run no script, so the first pending read stays first between them; a settlement can run script, so
// the state is read again after each.

#include "host_functions/webapi/streams/readable_stream_private.h"

namespace Collo::HostFunctions {

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
    const auto& pending = m_byob_read_requests.first();
    auto* view = pending.view.get();
    if (arrayBufferViewIsUnavailable(view))
        return false;
    return pending.bytes_filled % byobViewElementSize(view) != 0;
}

size_t JSColloReadableStream::pendingByobReadPullByteLength(size_t cap) const
{
    if (!hasByobReadRequests())
        return 0;
    const auto& request = m_byob_read_requests.first();
    auto* view = request.view.get();
    if (arrayBufferViewIsUnavailable(view) || request.bytes_filled >= view->byteLength())
        return 0;
    return std::min(view->byteLength() - request.bytes_filled, cap);
}

bool JSColloReadableStream::appendByobReadRequest(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSC::JSPromise* promise, JSC::JSArrayBufferView* view, JSColloReadableStreamBYOBRequest* byob_request,
    size_t min_bytes)
{
    auto& vm = global_object->vm();
    ByobReadRequest request;
    request.promise.setWithoutWriteBarrier(promise);
    request.view.setWithoutWriteBarrier(view);
    request.min_bytes = std::max<size_t>(1, min_bytes);
    const bool had_pending_byob_request = hasByobReadRequests();
    if (!m_byob_read_requests.tryAppend(vm, this, WTF::move(request))) {
        byob_request->invalidate();
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }
    if (had_pending_byob_request)
        byob_request->invalidate();
    else if (auto* current_controller = byteController())
        current_controller->setByobRequest(vm, byob_request);
    return true;
}

bool JSColloReadableStream::settleByobReadRequest(ByobReadRequest&& request, JSC::JSValue value, bool is_rejection)
{
    if (auto* current_controller = byteController()) {
        if (auto* byob_request = current_controller->byobRequest())
            byob_request->invalidate();
        current_controller->clearByobRequest();
    }
    return Collo::settlePromise(request.promise.get(), value, is_rejection);
}

bool JSColloReadableStream::rejectByobReadRequests(JSC::JSGlobalObject*, JSC::JSValue error)
{
    while (hasByobReadRequests()) {
        auto request = takeFirstByobReadRequest();
        if (!settleByobReadRequest(WTF::move(request), error, true))
            return false;
    }
    if (auto* current_controller = byteController())
        current_controller->clearByobRequest();
    return true;
}

bool JSColloReadableStream::closeByobReadRequestsForCancel(JSC::JSGlobalObject* global_object)
{
    while (hasByobReadRequests()) {
        auto request = takeFirstByobReadRequest();
        if (!settleByobReadRequest(WTF::move(request), readResult(global_object, JSC::jsUndefined(), true), false))
            return false;
    }
    if (auto* current_controller = byteController())
        current_controller->clearByobRequest();
    return true;
}

bool JSColloReadableStream::pushFrontQueuedByteChunk(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSArrayBufferView* chunk)
{
    if (arrayBufferViewIsUnavailable(chunk)) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream queued byte chunk is unavailable"_s);
        return false;
    }
    const double chunk_size = static_cast<double>(chunk->byteLength());
    QueuedChunk entry;
    entry.value.setWithoutWriteBarrier(chunk);
    entry.size = chunk_size;
    if (!m_queue.tryPrepend(global_object->vm(), this, WTF::move(entry))) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }
    m_queue_total_size += chunk_size;
    return true;
}

// Queues the bytes of `chunk` from `byte_offset` on. The caller reserved room when a failure here would lose a
// transferred buffer.
bool JSColloReadableStream::appendQueuedByteChunk(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSUint8Array* chunk, size_t byte_offset)
{
    const double size = static_cast<double>(chunk->byteLength() - byte_offset);
    QueuedChunk entry;
    entry.value.setWithoutWriteBarrier(chunk);
    entry.size = size;
    entry.byte_offset = byte_offset;
    if (!m_queue.tryAppend(global_object->vm(), this, WTF::move(entry))) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }
    m_queue_total_size += size;
    return true;
}

bool JSColloReadableStream::refreshFirstByobReadRequest(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    if (!hasByobReadRequests())
        return true;
    const auto& pending = m_byob_read_requests.first();
    auto* target = pending.view.get();
    if (arrayBufferViewIsUnavailable(target)) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream BYOB view is detached or out of bounds"_s);
        return false;
    }
    const size_t bytes_filled = pending.bytes_filled;
    auto* current_controller = byteController();
    if (bytes_filled >= target->byteLength()) {
        if (current_controller)
            current_controller->clearByobRequest();
        return true;
    }

    auto* remaining
        = createUint8ArrayView(global_object, scope, target, bytes_filled, target->byteLength() - bytes_filled);
    RETURN_IF_EXCEPTION(scope, false);
    current_controller = byteController();
    if (!current_controller)
        return true;
    if (auto* old_request = current_controller->byobRequest())
        old_request->invalidate();
    auto* next_request = JSColloReadableStreamBYOBRequest::create(global_object->vm(), global_object, this, remaining);
    current_controller->setByobRequest(global_object->vm(), next_request);
    return true;
}

bool JSColloReadableStream::refreshFirstByobReadRequestAndPullIfNeeded(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    if (!refreshFirstByobReadRequest(global_object, scope))
        return false;
    // Only a controller's source is asked here: a native source's own pump pulls again for a read still waiting.
    if (hasByobReadRequests() && !firstByobReadRequestIsReady()) {
        if (auto* current_controller = controller())
            current_controller->callPullIfNeeded(global_object);
    }
    return true;
}

bool JSColloReadableStream::firstByobReadRequestIsReady() const
{
    if (!hasByobReadRequests())
        return false;
    const auto& pending = m_byob_read_requests.first();
    auto* target = pending.view.get();
    if (arrayBufferViewIsUnavailable(target))
        return true;
    // Only whole elements count toward min_bytes; the bytes of a trailing partial element go back to the queue when
    // the read settles.
    const size_t element_size = byobViewElementSize(target);
    const size_t aligned_filled = pending.bytes_filled - (pending.bytes_filled % element_size);
    return aligned_filled >= pending.min_bytes || pending.bytes_filled >= target->byteLength();
}

bool JSColloReadableStream::rejectFirstByobReadRequestWithUnavailableView(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    auto request = takeFirstByobReadRequest();
    if (!settleByobReadRequest(
            WTF::move(request), JSC::createTypeError(global_object, "BYOB view is detached or out of bounds"_s), true))
        return false;
    if (hasByobReadRequests())
        return refreshFirstByobReadRequest(global_object, scope);
    return true;
}

bool JSColloReadableStream::settleFirstByobReadRequestWithFilledBytes(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, bool done)
{
    if (!hasByobReadRequests())
        return false;
    const auto& pending = m_byob_read_requests.first();
    auto* target = pending.view.get();
    if (arrayBufferViewIsUnavailable(target))
        return rejectFirstByobReadRequestWithUnavailableView(global_object, scope);
    // Only whole elements are delivered. The bytes of a trailing partial element go back to the front of the queue so
    // the next read can complete the element; the final read, with done set, delivers everything. The remainder is
    // queued before the read settles, as ReadableByteStreamControllerRespondInReadableState queues it before it commits
    // the descriptor: settling can run script (a `then` getter) that reads again, and that read must find it.
    const size_t element_size = byobViewElementSize(target);
    const size_t bytes_filled = pending.bytes_filled;
    const size_t remainder = done ? 0 : bytes_filled % element_size;
    const size_t deliver_bytes = bytes_filled - remainder;
    JSC::JSUint8Array* remainder_chunk = nullptr;
    if (remainder) {
        // Room is reserved first, so queueing the remainder cannot fail once the view's buffer is transferred. Nothing
        // between here and the push runs script or removes a queued chunk.
        if (!m_queue.tryReserveAdditional(this, 1)) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        remainder_chunk = createUint8ArrayCopy(
            global_object, scope, arrayBufferViewBytes(target).subspan(deliver_bytes, remainder));
        RETURN_IF_EXCEPTION(scope, false);
    }
    auto* value = transferArrayBufferViewRangeToSameView(
        global_object, scope, target, 0, deliver_bytes, "ReadableStream BYOB view"_s);
    RETURN_IF_EXCEPTION(scope, false);
    if (remainder_chunk && !pushFrontQueuedByteChunk(global_object, scope, remainder_chunk))
        return false;
    auto request = takeFirstByobReadRequest();
    if (!settleByobReadRequest(WTF::move(request), readResult(global_object, value, done), false))
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
    auto* target = m_byob_read_requests.first().view.get();
    if (arrayBufferViewIsUnavailable(target))
        return rejectFirstByobReadRequestWithUnavailableView(global_object, scope);
    auto& vm = global_object->vm();
    auto source = arrayBufferViewBytes(chunk).subspan(offset);
    const size_t target_remaining = target->byteLength() - m_byob_read_requests.first().bytes_filled;
    // The queue's room is reserved before the chunk's buffer is transferred, so the append below cannot fail after
    // the transfer.
    if (source.size() > target_remaining && !m_queue.tryReserveAdditional(this, 1)) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }

    JSC::JSUint8Array* owned_chunk = nullptr;
    const bool shares_target_buffer = viewSharesBuffer(chunk, target);
    if (shares_target_buffer) {
        if (source.size() > target_remaining) {
            owned_chunk = createUint8ArrayCopy(global_object, scope, source);
            RETURN_IF_EXCEPTION(scope, false);
            source = arrayBufferViewBytes(owned_chunk);
        }
    } else {
        owned_chunk
            = transferArrayBufferViewToUint8Array(global_object, scope, chunk, "ReadableByteStreamController chunk"_s);
        RETURN_IF_EXCEPTION(scope, false);
        source = arrayBufferViewBytes(owned_chunk).subspan(offset);
    }

    auto& pending = m_byob_read_requests.first();
    auto target_bytes = mutableArrayBufferViewBytes(target).subspan(pending.bytes_filled);
    const size_t copied = std::min(source.size(), target_bytes.size());
    if (copied)
        std::memmove(target_bytes.data(), source.data(), copied);
    pending.bytes_filled += copied;
    if (copied < source.size()) {
        size_t queued_offset = copied;
        if (!owned_chunk) {
            owned_chunk = createUint8ArrayCopy(global_object, scope, source);
            RETURN_IF_EXCEPTION(scope, false);
        } else if (shares_target_buffer) {
            // owned_chunk is the copy of `source` made above, so its own offset starts at 0.
            queued_offset = copied;
        } else {
            queued_offset = offset + copied;
        }
        if (!appendQueuedByteChunk(global_object, scope, owned_chunk, queued_offset))
            return false;
    }
    if (shares_target_buffer) {
        // ReadableByteStreamControllerEnqueue transfers the chunk's buffer. Here the chunk aliases the pending view's
        // buffer, so moving that buffer's contents to a fresh one detaches the chunk while the pending view keeps its
        // bytes.
        auto* renewed = transferArrayBufferViewRangeToSameView(
            global_object, scope, target, 0, target->byteLength(), "ReadableStream BYOB view"_s);
        RETURN_IF_EXCEPTION(scope, false);
        m_byob_read_requests.first().view.set(vm, this, renewed);
    }
    if (firstByobReadRequestIsReady())
        return settleFirstByobReadRequestWithFilledBytes(global_object, scope, false);
    return refreshFirstByobReadRequestAndPullIfNeeded(global_object, scope);
}

bool JSColloReadableStream::drainQueuedBytesIntoByobRequests(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    while (hasByobReadRequests() && !queueEmpty()) {
        auto& pending = m_byob_read_requests.first();
        auto* target = pending.view.get();
        if (arrayBufferViewIsUnavailable(target)) {
            if (!rejectFirstByobReadRequestWithUnavailableView(global_object, scope))
                return false;
            continue;
        }

        std::span<const uint8_t> source;
        if (!firstQueuedByteSpan(source)) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream queued byte chunk is unavailable"_s);
            return false;
        }
        auto target_bytes = mutableArrayBufferViewBytes(target).subspan(pending.bytes_filled);
        const size_t copied = std::min(source.size(), target_bytes.size());
        if (copied)
            memcpySpan(target_bytes, source.first(copied));
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
        if (queueEmpty() && m_close_requested) {
            close(global_object);
            return true;
        }
        if (!refreshFirstByobReadRequestAndPullIfNeeded(global_object, scope))
            return false;
    }
    if (queueEmpty() && m_close_requested)
        close(global_object);
    return true;
}

bool JSColloReadableStream::enqueueByteChunk(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSArrayBufferView* chunk)
{
    if (m_state != StreamState::Readable) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream is not readable"_s);
        return false;
    }
    if (m_close_requested) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream is closing"_s);
        return false;
    }
    if (arrayBufferViewIsUnavailable(chunk)) {
        JSC::throwVMTypeError(
            global_object, scope, "ReadableByteStreamController chunk is detached or out of bounds"_s);
        return false;
    }
    if (!chunk->byteLength()) {
        JSC::throwVMTypeError(global_object, scope, "ReadableByteStreamController chunk must not be empty"_s);
        return false;
    }
    if (auto* current_controller = controller())
        current_controller->notePullProgress();
    if (hasByobReadRequests()) {
        auto* target = m_byob_read_requests.first().view.get();
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
        return fulfillReadRequest(global_object, owned_chunk, false);
    }

    // The queue's room is reserved before the chunk's buffer is transferred, so the append below cannot fail after
    // the transfer.
    if (!m_queue.tryReserveAdditional(this, 1)) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }
    auto* owned_chunk
        = transferArrayBufferViewToUint8Array(global_object, scope, chunk, "ReadableByteStreamController chunk"_s);
    RETURN_IF_EXCEPTION(scope, false);
    return appendQueuedByteChunk(global_object, scope, owned_chunk, 0);
}

bool JSColloReadableStream::settleByobRequestWithBytes(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSColloReadableStreamBYOBRequest* byob_request, size_t bytes_written)
{
    if (!byob_request || !byob_request->active()) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream BYOB request is no longer active"_s);
        return false;
    }
    auto* current_controller = byteController();
    auto* current_request = current_controller ? current_controller->byobRequest() : nullptr;
    if (!hasByobReadRequests() || current_request != byob_request) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream BYOB request is no longer current"_s);
        return false;
    }
    auto& pending = m_byob_read_requests.first();
    auto* view = pending.view.get();
    if (arrayBufferViewIsUnavailable(view))
        return rejectFirstByobReadRequestWithUnavailableView(global_object, scope);
    const bool close_requested = m_close_requested;
    if (close_requested && bytes_written) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream BYOB bytesWritten must be zero after close"_s);
        return false;
    }
    if (!bytes_written && !close_requested) {
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
    auto* current_controller = byteController();
    auto* current_request = current_controller ? current_controller->byobRequest() : nullptr;
    if (!hasByobReadRequests() || current_request != byob_request) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream BYOB request is no longer current"_s);
        return false;
    }
    auto* original_view = m_byob_read_requests.first().view.get();
    if (arrayBufferViewIsUnavailable(original_view)) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream BYOB original view is detached or out of bounds"_s);
        return false;
    }
    const bool close_requested = m_close_requested;
    if (close_requested && view->byteLength()) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream BYOB response view must be empty after close"_s);
        return false;
    }
    if (!close_requested && !view->byteLength()) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream BYOB response view must not be empty"_s);
        return false;
    }
    // ReadableByteStreamControllerRespondWithNewView refuses, before it transfers anything, a view that does not start
    // where the pending read's filled bytes end or that runs past the read's view. A view inside the pending view lies
    // in its buffer, so one that starts at bytes_filled already holds its bytes where the read collects them.
    auto& pending = m_byob_read_requests.first();
    if (!viewRangeIsInside(view, original_view)
        || view->byteOffset() - original_view->byteOffset() != pending.bytes_filled) {
        JSC::throwVMRangeError(
            global_object, scope, "ReadableStream BYOB response view does not match the original view"_s);
        return false;
    }
    pending.bytes_filled += view->byteLength();
    // RespondWithNewView transfers view.[[ViewedArrayBuffer]] whether or not the read completes. Transferring the
    // pending view's buffer to a fresh one detaches the caller's view while the read keeps its bytes.
    auto* renewed = transferArrayBufferViewRangeToSameView(
        global_object, scope, original_view, 0, original_view->byteLength(), "ReadableStream BYOB view"_s);
    RETURN_IF_EXCEPTION(scope, false);
    m_byob_read_requests.first().view.set(global_object->vm(), this, renewed);
    // ReadableByteStreamControllerRespondInternal: after a close, the read ends done with the whole elements it holds.
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

JSC::EncodedJSValue JSColloReadableStream::readInto(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSArrayBufferView* view, size_t min_bytes)
{
    m_disturbed = true;
    if (!m_is_byte_stream)
        return rejectedTypeError(global_object, scope, "ReadableStream is not a byte stream"_s);
    if (arrayBufferViewIsUnavailable(view))
        return rejectedTypeError(global_object, scope, "ReadableStream BYOB view is detached or out of bounds"_s);
    if (!view->byteLength())
        return rejectedTypeError(global_object, scope, "ReadableStream BYOB view must not be empty"_s);
    if (m_state == StreamState::Closed) {
        auto* empty
            = transferArrayBufferViewRangeToSameView(global_object, scope, view, 0, 0, "ReadableStream BYOB view"_s);
        RETURN_IF_EXCEPTION(scope, {});
        return readResultPromise(global_object, empty, true);
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
        JSC::JSValue reason = scope.exception()->value();
        if (!scope.tryClearException())
            return {};
        return rejectedPromise(global_object, scope, reason);
    }
    auto* exposed_view = createUint8ArrayView(global_object, scope, transferred_view, 0, view_byte_length);
    RETURN_IF_EXCEPTION(scope, {});
    auto* promise = Collo::newPromise(global_object);
    auto* byob_request
        = JSColloReadableStreamBYOBRequest::create(global_object->vm(), global_object, this, exposed_view);
    if (!appendByobReadRequest(global_object, scope, promise, transferred_view, byob_request, min_bytes))
        return {};
    if (!drainQueuedBytesIntoByobRequests(global_object, scope))
        return {};
    const bool still_pending = hasByobReadRequests() && m_byob_read_requests.first().promise.get() == promise;
    if (!still_pending && queueEmpty() && m_close_requested)
        close(global_object);
    else if (still_pending || queueEmpty())
        pullIfNeeded(global_object);
    RETURN_IF_EXCEPTION(scope, {});
    return JSC::JSValue::encode(promise);
}

bool JSColloReadableStream::firstQueuedByteSpan(std::span<const uint8_t>& out)
{
    out = {};
    if (queueEmpty())
        return false;
    auto& entry = m_queue.first();
    auto* view = dynamicDowncast<JSC::JSArrayBufferView>(entry.value.get());
    if (arrayBufferViewIsUnavailable(view))
        return false;
    auto bytes = arrayBufferViewBytes(view);
    if (entry.byte_offset > bytes.size())
        return false;
    out = bytes.subspan(entry.byte_offset);
    return true;
}

bool JSColloReadableStream::dequeueByteValue(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue& value)
{
    if (queueEmpty())
        return false;
    auto& entry = m_queue.first();
    auto* view = dynamicDowncast<JSC::JSArrayBufferView>(entry.value.get());
    if (arrayBufferViewIsUnavailable(view))
        return false;
    const size_t byte_length = view->byteLength();
    const size_t byte_offset = entry.byte_offset;
    if (byte_offset > byte_length)
        return false;
    if (!byte_offset) {
        value = view;
    } else {
        value = createUint8ArrayView(global_object, scope, view, byte_offset, byte_length - byte_offset);
        RETURN_IF_EXCEPTION(scope, false);
    }
    auto taken = m_queue.takeFirst(this);
    subtractQueueSize(taken.size);
    return true;
}

bool JSColloReadableStream::consumeFirstQueuedByteSpan(size_t bytes)
{
    std::span<const uint8_t> source;
    if (!firstQueuedByteSpan(source))
        return false;
    if (bytes > source.size())
        return false;
    if (bytes == source.size()) {
        auto taken = m_queue.takeFirst(this);
        subtractQueueSize(taken.size);
        return true;
    }
    auto& entry = m_queue.first();
    entry.byte_offset += bytes;
    const double copied_size = static_cast<double>(bytes);
    entry.size = entry.size > copied_size ? entry.size - copied_size : 0;
    subtractQueueSize(copied_size);
    return true;
}

} // namespace Collo::HostFunctions
