// ReadableStreamTee, for every kind of ReadableStream: a readable stream whose native source holds every unread byte
// splits the source, and any other stream gets a tee state that both branches' controllers hold as their source. Every
// tee counts against the clone budget the stream shares with its clone tree. Runs on the VM thread.
//
// The tee state reads the original one chunk at a time, only while a branch wants a chunk: a branch with a pending
// read, or one below its high-water mark that no pipe holds back, while no branch of a default stream holds
// defaultTeeQueuedSizeMax chunks. Reads served for one branch still queue every chunk in the other, as the standard's
// tee does. A byte chunk is copied for each branch, so neither branch can write into the other's bytes. A stream with a
// native source that has bytes queued or a pull in flight, or whose source cannot split, is teed this way too, so the
// branches read the queued bytes first.
//
// Script can run while the tee reads the original (the source's pull, a `then` getter reached while settling the read)
// and while it hands a chunk to the branches (settling a branch's pending read reaches a `then` getter too). Such
// script may read a branch, which asks the tee for another chunk, so the read stays in flight from just before it is
// issued until its chunk has reached both branches; a second read would take the original's next chunk, and with it
// possibly its close, ahead of this one. Once the chunk is delivered with the original closed, the branches close at
// once; otherwise the next read's done result closes them. An error of the original reaches the branches as soon as its
// reader's closed promise rejects, read in flight or not. Both branches' cancel algorithms return one promise, settled
// as ReadableStreamDefaultTee and ReadableByteStreamTee settle their cancelPromise.

#include "host_functions/webapi/streams/readable_stream_private.h"

namespace Collo::HostFunctions {

namespace {

    // The largest read the tee issues on a byte stream on behalf of a branch's pending BYOB read.
    constexpr size_t byteStreamTeePullByteLengthMax = 64 * 1024;
    // With no read pending, the tee reads ahead only while every live branch of a default stream holds fewer queued
    // chunks than this. A branch has no size callback, so its queue counts each chunk as 1.
    constexpr double defaultTeeQueuedSizeMax = 1024;

    bool branchCanAcceptReadAhead(JSColloReadableStream* branch, bool canceled)
    {
        if (!branch || canceled || branch->state() != StreamState::Readable)
            return true;
        if (branch->hasPendingReadRequests() || branch->hasPendingByobReadRequests())
            return true;
        return branch->queuedSize() < defaultTeeQueuedSizeMax;
    }

    bool branchHasPendingRead(JSColloReadableStream* branch, bool canceled)
    {
        return !canceled && branch && (branch->hasPendingReadRequests() || branch->hasPendingByobReadRequests());
    }

    // Returns false with an exception pending.
    bool enqueueTeeChunk(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSColloReadableStream* branch,
        JSC::JSValue value, bool is_byte_stream)
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
        auto* copy = createUint8ArrayCopy(global_object, scope, arrayBufferViewBytes(view));
        RETURN_IF_EXCEPTION(scope, false);
        return branch->enqueueByteChunk(global_object, scope, copy);
    }

} // namespace

JSColloReadableStreamTeeState* JSColloReadableStreamTeeState::create(JSC::VM& vm, Collo::GlobalObject* global_object,
    JSColloReadableStream* original, JSColloReadableStream* branch_a, JSColloReadableStream* branch_b)
{
    auto* object = new (NotNull, JSC::allocateCell<JSColloReadableStreamTeeState>(vm))
        JSColloReadableStreamTeeState(vm, global_object->readableStreamTeeStateStructure());
    object->finishCreation(vm, original, branch_a, branch_b);
    return object;
}

void JSColloReadableStreamTeeState::finishCreation(
    JSC::VM& vm, JSColloReadableStream* original, JSColloReadableStream* branch_a, JSColloReadableStream* branch_b)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
    m_original.set(vm, this, original);
    m_branch_a.set(vm, this, branch_a);
    m_branch_b.set(vm, this, branch_b);
    m_reason_a.set(vm, this, JSC::jsUndefined());
    m_reason_b.set(vm, this, JSC::jsUndefined());
}

bool JSColloReadableStreamTeeState::shouldPull() const
{
    if (m_reading)
        return false;
    auto* original = m_original.get();
    if (!original || original->state() == StreamState::Errored)
        return false;
    auto* branch_a = m_branch_a.get();
    auto* branch_b = m_branch_b.get();
    // A pending read on either branch is served however much the other branch has queued; waiting for that branch to
    // drain could leave the read pending forever.
    if (branchHasPendingRead(branch_a, m_canceled_a) || branchHasPendingRead(branch_b, m_canceled_b))
        return true;
    if (original->isByteStream())
        return false;
    // Reading ahead stops at defaultTeeQueuedSizeMax, so read-ahead alone cannot grow an unread branch without bound.
    if (!branchCanAcceptReadAhead(branch_a, m_canceled_a) || !branchCanAcceptReadAhead(branch_b, m_canceled_b))
        return false;
    const bool branch_a_wants = !m_canceled_a && branch_a && branch_a->wantsTeeChunk();
    const bool branch_b_wants = !m_canceled_b && branch_b && branch_b->wantsTeeChunk();
    return branch_a_wants || branch_b_wants;
}

size_t JSColloReadableStreamTeeState::pendingByobReadSize() const
{
    size_t size = 0;
    if (auto* branch_a = m_branch_a.get())
        size = std::max(size, branch_a->pendingByobReadPullByteLength(byteStreamTeePullByteLengthMax));
    if (auto* branch_b = m_branch_b.get())
        size = std::max(size, branch_b->pendingByobReadPullByteLength(byteStreamTeePullByteLengthMax));
    return size;
}

void JSColloReadableStreamTeeState::pump(JSC::JSGlobalObject* global_object)
{
    if (!shouldPull())
        return;
    auto* original = m_original.get();
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    m_reading = true;
    JSC::JSValue read_value;
    const size_t byob_read_size = original->isByteStream() ? pendingByobReadSize() : 0;
    if (byob_read_size) {
        auto* pull_view = createUint8Array(global_object, scope, byob_read_size);
        if (!scope.exception())
            read_value = JSC::JSValue::decode(original->readInto(global_object, scope, pull_view, 1));
    } else {
        read_value = JSC::JSValue::decode(original->read(global_object, scope));
    }
    if (scope.exception()) {
        m_reading = false;
        JSC::JSValue error = scope.exception()->value();
        if (!scope.tryClearException())
            return;
        errorBranches(global_object, error);
        return;
    }
    auto* promise = dynamicDowncast<JSC::JSPromise>(read_value);
    if (!promise) {
        m_reading = false;
        errorBranches(global_object, JSC::createTypeError(global_object, "ReadableStream tee read failed"_s));
        return;
    }
    reactToPromise(global_object, promise, StreamReaction::TeeRead, this);
}

void JSColloReadableStreamTeeState::readFulfilled(JSC::JSGlobalObject* global_object, JSC::JSValue result)
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    bool done = false;
    JSC::JSValue error;
    if (!readResultDone(global_object, result, done, error)) {
        m_reading = false;
        errorBranches(global_object, error);
        return;
    }
    if (done) {
        m_reading = false;
        closeBranches(global_object);
        return;
    }

    // The read stays in flight while its chunk reaches the branches (see the header), as the chunk steps of
    // ReadableStreamDefaultTee keep reading set until they finish.
    JSC::JSValue value = readResultValue(global_object, result);
    auto* original = m_original.get();
    const bool is_byte_stream = original && original->isByteStream();
    for (auto* branch : { m_branch_a.get(), m_branch_b.get() }) {
        if (enqueueTeeChunk(global_object, scope, branch, value, is_byte_stream))
            continue;
        m_reading = false;
        JSC::JSValue enqueue_error
            = scope.exception() ? scope.exception()->value() : JSC::createOutOfMemoryError(global_object);
        if (scope.exception() && !scope.tryClearException())
            return;
        errorBranches(global_object, enqueue_error);
        return;
    }
    m_reading = false;

    original = m_original.get();
    if (original && original->state() == StreamState::Closed) {
        closeBranches(global_object);
        return;
    }
    pump(global_object);
}

void JSColloReadableStreamTeeState::readRejected(JSC::JSGlobalObject* global_object, JSC::JSValue reason)
{
    m_reading = false;
    // An error of the original has already ended the tee through the closed promise, which the original rejects
    // before its pending reads, and a reader released by finish() leaves no original behind. Any other rejection
    // ends the tee here.
    auto* original = m_original.get();
    if (original && original->state() == StreamState::Readable)
        errorBranches(global_object, reason);
}

JSC::JSValue JSColloReadableStreamTeeState::cancelBranch(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSColloReadableStream* branch, JSC::JSValue reason)
{
    auto& vm = global_object->vm();
    const bool is_a = branch && branch == m_branch_a.get();
    const bool is_b = branch && branch == m_branch_b.get();
    if (!is_a && !is_b)
        return JSC::jsUndefined();
    if (!m_cancel_promise)
        m_cancel_promise.set(vm, this, Collo::newPromise(global_object));
    auto* cancel_promise = m_cancel_promise.get();
    if (is_a) {
        m_canceled_a = true;
        m_reason_a.set(vm, this, reason);
    } else {
        m_canceled_b = true;
        m_reason_b.set(vm, this, reason);
    }
    if (!m_canceled_a || !m_canceled_b)
        return cancel_promise;

    // Both branches are canceled: the original is canceled with both reasons, and the shared promise follows it.
    JSC::JSValue cancel_result = JSC::jsUndefined();
    if (auto* original = m_original.get()) {
        auto* reasons = JSC::constructEmptyArray(global_object, nullptr, 2);
        RETURN_IF_EXCEPTION(scope, {});
        reasons->putDirectIndex(global_object, 0, m_reason_a.get());
        RETURN_IF_EXCEPTION(scope, {});
        reasons->putDirectIndex(global_object, 1, m_reason_b.get());
        RETURN_IF_EXCEPTION(scope, {});
        cancel_result = JSC::JSValue::decode(original->cancel(global_object, scope, reasons));
        RETURN_IF_EXCEPTION(scope, {});
    }
    finish(global_object, cancel_result);
    RETURN_IF_EXCEPTION(scope, {});
    return cancel_promise;
}

void JSColloReadableStreamTeeState::finish(JSC::JSGlobalObject* global_object, JSC::JSValue cancel_value)
{
    auto* original = m_original.get();
    auto* branch_a = m_branch_a.get();
    auto* branch_b = m_branch_b.get();
    auto* cancel_promise = m_cancel_promise.get();
    m_original.clear();
    m_branch_a.clear();
    m_branch_b.clear();
    m_cancel_promise.clear();
    m_reason_a.setUndefined();
    m_reason_b.setUndefined();
    // Unlinking each branch's controller drops the branch's path to this state, so a branch read no longer pumps.
    if (branch_a) {
        if (auto* controller = branch_a->controller())
            controller->clearAlgorithms();
    }
    if (branch_b) {
        if (auto* controller = branch_b->controller())
            controller->clearAlgorithms();
    }
    if (original) {
        if (auto* reader = original->reader())
            reader->release(global_object);
    }
    // Last, since resolving with the original's cancel promise looks up its `then`, which can run script.
    if (cancel_promise)
        Collo::settlePromise(cancel_promise, cancel_value, false);
}

void JSColloReadableStreamTeeState::errorBranches(JSC::JSGlobalObject* global_object, JSC::JSValue error)
{
    if (auto* branch_a = m_branch_a.get())
        branch_a->error(global_object, error);
    if (auto* branch_b = m_branch_b.get())
        branch_b->error(global_object, error);
    finish(global_object, JSC::jsUndefined());
}

void JSColloReadableStreamTeeState::closeBranches(JSC::JSGlobalObject* global_object)
{
    if (auto* branch_a = m_branch_a.get())
        branch_a->close(global_object);
    if (auto* branch_b = m_branch_b.get())
        branch_b->close(global_object);
    finish(global_object, JSC::jsUndefined());
}

bool readableStreamTee(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* stream_object,
    JSC::JSObject*& out_first, JSC::JSObject*& out_second)
{
    out_first = nullptr;
    out_second = nullptr;
    auto* stream = requireReadableStream(global_object, scope, stream_object);
    RETURN_IF_EXCEPTION(scope, false);
    if (stream->locked()) {
        JSC::throwVMTypeError(global_object, scope, "ReadableStream is already locked"_s);
        return false;
    }
    // The clone counts only once both branches exist, so a tee that throws leaves the budget and the stream as they
    // were.
    auto& budget = stream->cloneBudget();
    if (!StreamCloneBudget::ensure(global_object, scope, budget) || !budget->checkRoom(global_object, scope))
        return false;

    auto& vm = global_object->vm();
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    JSColloReadableStream* branch_a = nullptr;
    JSColloReadableStream* branch_b = nullptr;
    // Only a readable stream whose source holds every unread byte splits it. A canceled one still holds its source
    // while the source's cancel runs, and like any closed stream is teed by reading it, which closes both branches.
    WTF::RefPtr<ReadableStreamNativeSource> source_a;
    WTF::RefPtr<ReadableStreamNativeSource> source_b;
    if (!stream->trySplitNativeSource(global_object, scope, source_a, source_b))
        return false;
    const bool split_native_source = source_a && source_b;
    if (split_native_source) {
        branch_a = JSColloReadableStream::createWithNativeSource(vm, collo_global, source_a.releaseNonNull());
        branch_b = JSColloReadableStream::createWithNativeSource(vm, collo_global, source_b.releaseNonNull());
    } else {
        branch_a = JSColloReadableStream::create(vm, collo_global);
        branch_b = JSColloReadableStream::create(vm, collo_global);
        for (auto* branch : { branch_a, branch_b }) {
            JSColloReadableStreamController* controller = nullptr;
            if (stream->isByteStream()) {
                branch->setByteStream(true);
                controller = JSColloReadableByteStreamController::create(vm, global_object, branch);
            } else {
                controller = JSColloReadableStreamDefaultController::create(vm, global_object, branch);
            }
            branch->setController(vm, controller);
        }
    }
    budget->countClone();
    branch_a->cloneBudget() = budget;
    branch_b->cloneBudget() = budget;

    auto* reader = JSColloReadableStreamDefaultReader::create(vm, global_object, stream);
    RETURN_IF_EXCEPTION(scope, false);
    if (!reader)
        return false;
    stream->lock(vm, reader);

    if (!split_native_source) {
        auto* tee_state = JSColloReadableStreamTeeState::create(vm, collo_global, stream, branch_a, branch_b);
        branch_a->controller()->setNativeSource(vm, JSColloReadableStreamController::SourceKind::Tee, tee_state);
        branch_b->controller()->setNativeSource(vm, JSColloReadableStreamController::SourceKind::Tee, tee_state);
        if (auto* closed = dynamicDowncast<JSC::JSPromise>(reader->closedPromise()))
            reactToPromise(global_object, closed, StreamReaction::TeeClosed, tee_state);
        tee_state->pump(global_object);
        RETURN_IF_EXCEPTION(scope, false);
    }
    out_first = branch_a;
    out_second = branch_b;
    return true;
}

} // namespace Collo::HostFunctions
