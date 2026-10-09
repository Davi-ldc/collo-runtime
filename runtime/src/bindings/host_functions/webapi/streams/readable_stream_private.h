// The cell classes of the ReadableStream implementation, shared by the stream implementation files: the stream with
// its queue and pending reads, the default and byte controllers, both readers, the BYOB request and the async
// iterator. Everything runs on the VM thread, except visitChildren (readable_stream_objects.cpp), which collector
// threads run concurrently.
//
// Every edge from one of these cells to another cell is a WriteBarrier field, except the ColloPromiseDeferred of a
// pending BYOB read and of a default reader's closed promise. The cell owns that deferred, which roots its promise's
// resolve and reject functions through Strong handles (ColloValue) until settleDeferred settles and releases it or
// the cell's destructor releases one that never settled. A pending BYOB read's promise points back at the stream
// through its owner property, so that stream stays alive until the read settles.
// FIXME: these Strong handles hide cycles from the collector. A stream nothing else references leaks until its
// pending BYOB read settles or the VM is destroyed, and a reaction on a closed promise that captures its reader keeps
// that reader alive the same way. Hold these promises in WriteBarrier fields, as ReadRequest does.
//
// The concurrent marker reads the stream's queue, its two read-request vectors and its native source pointer, so any
// change that can move or free a vector's buffer, or detach the source, happens under cellLock(), and nothing holds
// that lock across a JavaScript allocation or a call into JavaScript or Zig.

#pragma once

#include "host_functions/webapi/streams/stream_common_private.h"

namespace Collo::HostFunctions {

JSC_DECLARE_HOST_FUNCTION(readableStreamConstructorCall);
JSC_DECLARE_HOST_FUNCTION(readableStreamConstructorConstruct);
JSC_DECLARE_HOST_FUNCTION(readableStreamFrom);
JSC_DECLARE_HOST_FUNCTION(defaultReaderConstructorCall);
JSC_DECLARE_HOST_FUNCTION(defaultReaderConstructorConstruct);
JSC_DECLARE_HOST_FUNCTION(byobReaderConstructorCall);
JSC_DECLARE_HOST_FUNCTION(byobReaderConstructorConstruct);
JSC_DECLARE_HOST_FUNCTION(byobReaderRead);
JSC_DECLARE_HOST_FUNCTION(byobReaderCancel);
JSC_DECLARE_HOST_FUNCTION(byobReaderReleaseLock);
JSC_DECLARE_HOST_FUNCTION(byobReaderClosed);
JSC_DECLARE_HOST_FUNCTION(byobRequestConstructorCall);
JSC_DECLARE_HOST_FUNCTION(byobRequestConstructorConstruct);
JSC_DECLARE_HOST_FUNCTION(byobRequestView);
JSC_DECLARE_HOST_FUNCTION(byobRequestRespond);
JSC_DECLARE_HOST_FUNCTION(byobRequestRespondWithNewView);

JSColloReadableStream* requireReadableStream(JSC::JSGlobalObject*, JSC::ThrowScope&, JSValue);
JSColloReadableStreamDefaultReader* requireReadableStreamDefaultReader(JSC::JSGlobalObject*, JSC::ThrowScope&, JSValue);
JSColloReadableStreamDefaultController* requireReadableStreamDefaultController(
    JSC::JSGlobalObject*, JSC::ThrowScope&, JSValue);
JSColloReadableStreamBYOBReader* requireReadableStreamBYOBReader(JSC::JSGlobalObject*, JSC::ThrowScope&, JSValue);
JSColloReadableStreamBYOBRequest* requireReadableStreamBYOBRequest(JSC::JSGlobalObject*, JSC::ThrowScope&, JSValue);
JSColloReadableByteStreamController* requireReadableByteStreamController(
    JSC::JSGlobalObject*, JSC::ThrowScope&, JSValue);
JSColloReadableStreamAsyncIterator* requireReadableStreamAsyncIterator(JSC::JSGlobalObject*, JSC::ThrowScope&, JSValue);

JSC::JSObject* createDefaultTeeState(
    JSC::JSGlobalObject*, JSColloReadableStream*, JSColloReadableStream*, JSColloReadableStream*);
void startDefaultTeePump(JSC::JSGlobalObject*, JSC::JSObject*);

class JSColloReadableStreamDefaultController final : public JSC::JSDestructibleObject {
    using Base = JSC::JSDestructibleObject;

public:
    template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
    {
        return &vm.destructibleObjectSpace();
    }

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSValue prototype)
    {
        return JSC::Structure::create(
            vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

    static JSColloReadableStreamDefaultController* create(
        JSC::VM& vm, JSC::JSGlobalObject* global_object, JSColloReadableStream* stream);
    static void destroy(JSCell* cell)
    {
        static_cast<JSColloReadableStreamDefaultController*>(cell)->~JSColloReadableStreamDefaultController();
    }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    JSColloReadableStream* stream() const { return m_stream.get(); }
    JSValue pullCallback() const { return m_pull.get(); }
    JSValue cancelCallback() const { return m_cancel.get(); }
    JSValue sizeCallback() const { return m_size.get(); }
    JSValue underlyingSource() const { return m_underlying_source.get(); }
    bool starting() const { return m_starting; }
    bool pulling() const { return m_pulling; }
    bool pullAgain() const { return m_pull_again; }
    bool closeRequested() const { return m_close_requested; }
    void setCallbacks(JSC::VM& vm, JSValue pull, JSValue cancel, JSValue size)
    {
        m_pull.set(vm, this, pull);
        m_cancel.set(vm, this, cancel);
        m_size.set(vm, this, size);
    }
    void setUnderlyingSource(JSC::VM& vm, JSValue source) { m_underlying_source.set(vm, this, source); }
    // ReadableStreamDefaultControllerClearAlgorithms. A closed or errored stream never calls its source again, so
    // dropping the callbacks lets the collector reclaim what they close over, often the stream's own consumer.
    void clearAlgorithms()
    {
        m_pull.setUndefined();
        m_cancel.setUndefined();
        m_size.setUndefined();
        m_underlying_source.setUndefined();
    }
    void setStarting(bool value) { m_starting = value; }
    void setPulling(bool value) { m_pulling = value; }
    void setPullAgain(bool value) { m_pull_again = value; }
    void setCloseRequested(bool value) { m_close_requested = value; }
    JSC::JSFunction* pullFulfilledFunction(JSC::JSGlobalObject*);
    JSC::JSFunction* pullRejectedFunction(JSC::JSGlobalObject*);

private:
    explicit JSColloReadableStreamDefaultController(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    void finishCreation(JSC::VM& vm, JSColloReadableStream* stream)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
        m_stream.set(vm, this, stream);
        m_pull.set(vm, this, JSC::jsUndefined());
        m_cancel.set(vm, this, JSC::jsUndefined());
        m_size.set(vm, this, JSC::jsUndefined());
        m_underlying_source.set(vm, this, JSC::jsUndefined());
    }

    JSC::WriteBarrier<JSColloReadableStream> m_stream;
    JSC::WriteBarrier<JSC::Unknown> m_pull;
    JSC::WriteBarrier<JSC::Unknown> m_cancel;
    JSC::WriteBarrier<JSC::Unknown> m_size;
    JSC::WriteBarrier<JSC::Unknown> m_underlying_source;
    JSC::WriteBarrier<JSC::JSFunction> m_pull_fulfilled;
    JSC::WriteBarrier<JSC::JSFunction> m_pull_rejected;
    bool m_starting { false };
    bool m_pulling { false };
    bool m_pull_again { false };
    bool m_close_requested { false };
};

class JSColloReadableStreamBYOBRequest final : public JSC::JSDestructibleObject {
    using Base = JSC::JSDestructibleObject;

public:
    template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
    {
        return &vm.destructibleObjectSpace();
    }

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSValue prototype)
    {
        return JSC::Structure::create(
            vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

    static JSColloReadableStreamBYOBRequest* create(
        JSC::VM&, JSC::JSGlobalObject*, JSColloReadableStream*, JSC::JSArrayBufferView*);
    static void destroy(JSCell* cell)
    {
        static_cast<JSColloReadableStreamBYOBRequest*>(cell)->~JSColloReadableStreamBYOBRequest();
    }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    JSColloReadableStream* stream() const { return m_stream.get(); }
    JSC::JSArrayBufferView* view() const { return m_view.get(); }
    bool active() const { return m_active; }
    // A request goes inactive when its read settles or a fresh request for the same read replaces it, and at once when
    // its read queues behind another BYOB read. respond() and respondWithNewView() on it then throw a TypeError.
    void invalidate()
    {
        m_active = false;
        m_view.clear();
    }

private:
    explicit JSColloReadableStreamBYOBRequest(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    void finishCreation(JSC::VM& vm, JSColloReadableStream* stream, JSC::JSArrayBufferView* view)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
        m_stream.set(vm, this, stream);
        m_view.set(vm, this, view);
        m_active = true;
    }

    JSC::WriteBarrier<JSColloReadableStream> m_stream;
    JSC::WriteBarrier<JSC::JSArrayBufferView> m_view;
    bool m_active { false };
};

class JSColloReadableByteStreamController final : public JSC::JSDestructibleObject {
    using Base = JSC::JSDestructibleObject;

public:
    template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
    {
        return &vm.destructibleObjectSpace();
    }

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSValue prototype)
    {
        return JSC::Structure::create(
            vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

    static JSColloReadableByteStreamController* create(
        JSC::VM& vm, JSC::JSGlobalObject* global_object, JSColloReadableStream* stream);
    static void destroy(JSCell* cell)
    {
        static_cast<JSColloReadableByteStreamController*>(cell)->~JSColloReadableByteStreamController();
    }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    JSColloReadableStream* stream() const { return m_stream.get(); }
    JSValue pullCallback() const { return m_pull.get(); }
    JSValue cancelCallback() const { return m_cancel.get(); }
    JSValue underlyingSource() const { return m_underlying_source.get(); }
    JSColloReadableStreamBYOBRequest* byobRequest() const { return m_byob_request.get(); }
    size_t autoAllocateChunkSize() const { return m_auto_allocate_chunk_size; }
    bool starting() const { return m_starting; }
    bool pulling() const { return m_pulling; }
    bool pullAgain() const { return m_pull_again; }
    bool closeRequested() const { return m_close_requested; }
    void setCallbacks(JSC::VM& vm, JSValue pull, JSValue cancel)
    {
        m_pull.set(vm, this, pull);
        m_cancel.set(vm, this, cancel);
    }
    void setUnderlyingSource(JSC::VM& vm, JSValue source) { m_underlying_source.set(vm, this, source); }
    // ReadableByteStreamControllerClearAlgorithms, for the reason the default controller gives.
    void clearAlgorithms()
    {
        m_pull.setUndefined();
        m_cancel.setUndefined();
        m_underlying_source.setUndefined();
    }
    void setByobRequest(JSC::VM& vm, JSColloReadableStreamBYOBRequest* request)
    {
        m_byob_request.set(vm, this, request);
    }
    void clearByobRequest() { m_byob_request.clear(); }
    void setStarting(bool value) { m_starting = value; }
    void setPulling(bool value) { m_pulling = value; }
    void setPullAgain(bool value) { m_pull_again = value; }
    void setCloseRequested(bool value) { m_close_requested = value; }
    void setAutoAllocateChunkSize(size_t value) { m_auto_allocate_chunk_size = value; }
    JSC::JSFunction* pullFulfilledFunction(JSC::JSGlobalObject*);
    JSC::JSFunction* pullRejectedFunction(JSC::JSGlobalObject*);

private:
    explicit JSColloReadableByteStreamController(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    void finishCreation(JSC::VM& vm, JSColloReadableStream* stream)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
        m_stream.set(vm, this, stream);
        m_pull.set(vm, this, JSC::jsUndefined());
        m_cancel.set(vm, this, JSC::jsUndefined());
        m_underlying_source.set(vm, this, JSC::jsUndefined());
    }

    JSC::WriteBarrier<JSColloReadableStream> m_stream;
    JSC::WriteBarrier<JSC::Unknown> m_pull;
    JSC::WriteBarrier<JSC::Unknown> m_cancel;
    JSC::WriteBarrier<JSC::Unknown> m_underlying_source;
    JSC::WriteBarrier<JSColloReadableStreamBYOBRequest> m_byob_request;
    JSC::WriteBarrier<JSC::JSFunction> m_pull_fulfilled;
    JSC::WriteBarrier<JSC::JSFunction> m_pull_rejected;
    size_t m_auto_allocate_chunk_size { 0 };
    bool m_starting { false };
    bool m_pulling { false };
    bool m_pull_again { false };
    bool m_close_requested { false };
};

class JSColloReadableStream final : public JSC::JSDestructibleObject {
    using Base = JSC::JSDestructibleObject;

    struct QueuedChunk {
        JSC::WriteBarrier<JSC::Unknown> value;
        // Summed into m_queue_total_size: the strategy's size of the chunk, or its byte length on a byte stream.
        double size { 0 };
        // Bytes counted against m_queue_memory_cost_limit; 0 when the stream has no limit.
        size_t memory_cost { 0 };
        // Bytes at the front of a byte chunk already copied into BYOB reads.
        size_t byte_offset { 0 };
    };

    struct ReadRequest {
        JSC::WriteBarrier<JSC::Unknown> promise;
        JSC::WriteBarrier<JSC::Unknown> resolve;
        JSC::WriteBarrier<JSC::Unknown> reject;
    };

    struct ByobReadRequest {
        ColloPromiseDeferred* deferred { nullptr };
        JSC::WriteBarrier<JSC::Unknown> promise;
        // The view being filled, over a buffer transferred from the reader's view when the read was issued or
        // allocated for autoAllocateChunkSize.
        JSC::WriteBarrier<JSC::JSArrayBufferView> view;
        size_t bytes_filled { 0 };
        // In bytes: the read's min option times the view's element size, or 1 for an autoAllocateChunkSize read.
        size_t min_bytes { 1 };
    };

public:
    template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
    {
        return &vm.destructibleObjectSpace();
    }

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSValue prototype)
    {
        return JSC::Structure::create(
            vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

    static JSColloReadableStream* create(JSC::VM& vm, Collo::GlobalObject* global_object)
    {
        return createWithStructure(vm, global_object->readableStreamStructure());
    }

    static JSColloReadableStream* createWithStructure(JSC::VM& vm, JSC::Structure* structure)
    {
        auto* object = new (NotNull, JSC::allocateCell<JSColloReadableStream>(vm)) JSColloReadableStream(vm, structure);
        object->finishCreation(vm);
        return object;
    }

    static JSColloReadableStream* createWithNativeSource(
        JSC::VM& vm, Collo::GlobalObject* global_object, WTF::Ref<ReadableStreamNativeSource>&& source)
    {
        auto* object = new (NotNull, JSC::allocateCell<JSColloReadableStream>(vm))
            JSColloReadableStream(vm, global_object->readableStreamStructure());
        object->finishCreation(vm, WTF::move(source));
        return object;
    }

    static void destroy(JSCell* cell) { static_cast<JSColloReadableStream*>(cell)->~JSColloReadableStream(); }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    bool locked() const { return !!m_reader.get(); }
    bool disturbed() const { return m_disturbed; }
    StreamState state() const { return m_state; }
    JSValue storedError() const { return m_stored_error.get(); }
    JSColloReadableStreamDefaultReader* reader() const { return m_reader.get(); }
    JSColloReadableStreamDefaultController* controller() const { return m_controller.get(); }
    JSColloReadableByteStreamController* byteController() const { return m_byte_controller.get(); }
    double desiredSize() const { return m_high_water_mark - m_queue_total_size; }
    bool isByteStream() const { return m_is_byte_stream; }
    bool hasNativeSource() const { return !!m_native_source; }
    bool hasPendingReadRequests() const { return hasReadRequests(); }
    bool hasPendingByobReadRequests() const { return hasByobReadRequests(); }
    bool firstByobReadRequestHasPartialElement() const;
    double queuedSizeForTee() const { return m_queue_total_size; }
    size_t pendingByobReadPullByteLength(size_t cap) const
    {
        if (!hasByobReadRequests())
            return 0;
        const auto& request = m_byob_read_requests[m_byob_read_request_start];
        auto* view = request.view.get();
        if (arrayBufferViewIsUnavailable(view))
            return 0;
        if (request.bytes_filled >= view->byteLength())
            return 0;
        const size_t remaining = view->byteLength() - request.bytes_filled;
        return std::min(remaining, cap);
    }
    // pipeTo sets this while it drives the stream, around its own reads and while its destination is full, so the
    // stream pulls and a tee reads ahead for it only to serve a pending read.
    void setPipeBackpressure(bool value) { m_pipe_backpressure = value; }
    bool wantsTeeChunk() const
    {
        if (m_state != StreamState::Readable)
            return false;
        if (hasReadRequests() || hasByobReadRequests())
            return true;
        if (m_pipe_backpressure)
            return false;
        if (controller() && controller()->closeRequested())
            return false;
        return desiredSize() > 0;
    }
    void setHighWaterMark(double value) { m_high_water_mark = value; }
    void setQueueMemoryCostLimit(size_t value) { m_queue_memory_cost_limit = value; }
    void setByteStream(bool value) { m_is_byte_stream = value; }

    void setController(JSC::VM& vm, JSColloReadableStreamDefaultController* controller)
    {
        m_controller.set(vm, this, controller);
    }

    void setByteController(JSC::VM& vm, JSColloReadableByteStreamController* controller)
    {
        m_byte_controller.set(vm, this, controller);
    }

    void lock(JSC::VM& vm, JSColloReadableStreamDefaultReader* reader) { m_reader.set(vm, this, reader); }

    void unlock() { m_reader.clear(); }

    JSC::JSObject* defaultTeeState() const { return m_default_tee_state.get(); }
    void setDefaultTeeState(JSC::VM& vm, JSC::JSObject* state) { m_default_tee_state.set(vm, this, state); }
    void clearDefaultTeeState() { m_default_tee_state.clear(); }

    void markDisturbed() { m_disturbed = true; }

    bool enqueue(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue chunk)
    {
        if (!canCloseOrEnqueue(global_object, scope))
            return false;

        if (hasReadRequests()) {
            auto request = takeFirstReadRequest();
            settleReadRequest(global_object, WTF::move(request), createReadResult(global_object, chunk, false), false);
            return true;
        }

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
                            JSC::throwException(global_object, scope, reason);
                        }
                    }
                    return false;
                }
                auto call_data = JSC::getCallData(size_callback);
                JSValue size_value
                    = JSC::call(global_object, size_callback.getObject(), call_data, JSC::jsUndefined(), arguments);
                if (scope.exception()) {
                    JSValue reason = scope.exception()->value();
                    if (!scope.tryClearException())
                        return false;
                    error(global_object, reason);
                    JSC::throwException(global_object, scope, reason);
                    return false;
                }
                size = size_value.toNumber(global_object);
                if (scope.exception()) {
                    JSValue reason = scope.exception()->value();
                    if (!scope.tryClearException())
                        return false;
                    error(global_object, reason);
                    JSC::throwException(global_object, scope, reason);
                    return false;
                }
                if (!std::isfinite(size) || size < 0) {
                    JSValue reason = JSC::createRangeError(
                        global_object, "ReadableStream chunk size must be a finite non-negative number"_s);
                    RETURN_IF_EXCEPTION(scope, false);
                    error(global_object, reason);
                    JSC::throwException(global_object, scope, reason);
                    return false;
                }
            }
        }

        // A reentrant size callback may have closed or errored the stream, and ReadableStreamDefaultControllerEnqueue
        // does not check again. The chunk is still queued while a close is only requested; once the stream has left
        // the readable state nothing can read the chunk, so it is dropped.
        if (m_state != StreamState::Readable)
            return true;
        return enqueueWithSizeUnchecked(global_object, scope, chunk, size);
    }

    bool enqueueNativePullValue(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue chunk)
    {
        if (m_is_byte_stream) {
            auto* view = dynamicDowncast<JSC::JSArrayBufferView>(chunk);
            if (arrayBufferViewIsUnavailable(view)) {
                JSC::throwVMTypeError(
                    global_object, scope, "ReadableStream native byte source returned unavailable byte chunk"_s);
                return false;
            }
            return enqueueByteChunk(global_object, scope, view);
        }
        return enqueueWithSize(global_object, scope, chunk, 1);
    }

    bool enqueueByteChunk(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSArrayBufferView*);
    bool settleByobRequestWithBytes(JSC::JSGlobalObject*, JSC::ThrowScope&, JSColloReadableStreamBYOBRequest*, size_t);
    bool settleByobRequestWithView(
        JSC::JSGlobalObject*, JSC::ThrowScope&, JSColloReadableStreamBYOBRequest*, JSC::JSArrayBufferView*);
    EncodedJSValue readInto(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSArrayBufferView*, size_t min_bytes);
    void rejectByobReadRequests(JSC::JSGlobalObject*, JSValue);

    void callDefaultTeePullIfNeeded(JSC::JSGlobalObject* global_object);
    JSC::JSFunction* nativePullFulfilledFunction(JSC::JSGlobalObject*);
    JSC::JSFunction* nativePullRejectedFunction(JSC::JSGlobalObject*);

    bool canCloseOrEnqueue(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope) const
    {
        if (m_state != StreamState::Readable) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream is not readable"_s);
            return false;
        }
        if (controller() && controller()->closeRequested()) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream is closing"_s);
            return false;
        }
        if (byteController() && byteController()->closeRequested()) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream is closing"_s);
            return false;
        }
        return true;
    }

    bool enqueueWithSize(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue chunk, double size)
    {
        if (!canCloseOrEnqueue(global_object, scope))
            return false;
        return enqueueWithSizeUnchecked(global_object, scope, chunk, size);
    }

    bool enqueueWithSizeUnchecked(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue chunk, double size)
    {
        if (hasReadRequests()) {
            auto request = takeFirstReadRequest();
            settleReadRequest(global_object, WTF::move(request), createReadResult(global_object, chunk, false), false);
            return true;
        }

        QueuedChunk entry;
        entry.value.set(global_object->vm(), this, chunk);
        entry.size = size;
        const size_t memory_cost = m_queue_memory_cost_limit ? streamChunkMemoryCost(chunk) : 0;
        entry.memory_cost = memory_cost;
        if (queueMemoryCostWouldExceed(memory_cost)) {
            auto* exception
                = createStreamQueueLimitExceededError(global_object, "Text codec stream queue limit exceeded"_s);
            JSC::throwException(global_object, scope, exception);
            return false;
        }
        compactQueueIfNeeded();
        bool appended = false;
        {
            // The append may move the buffer the concurrent marker walks; see the file header for the lock rules.
            WTF::Locker locker { cellLock() };
            appended = m_queue.tryAppend(WTF::move(entry));
        }
        if (!appended) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        m_queue_total_size += size;
        m_queue_memory_cost += memory_cost;
        return true;
    }

    void close(JSC::JSGlobalObject* global_object);
    void error(JSC::JSGlobalObject* global_object, JSValue error);
    void rejectReadRequests(JSC::JSGlobalObject* global_object, JSValue error);

    EncodedJSValue read(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope);
    EncodedJSValue cancel(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue reason);
    ReadableStreamDrainResult drainNativeBytes(WTF::Vector<uint8_t>& out, size_t max_size);
    void callPullIfNeeded(JSC::JSGlobalObject* global_object);
    void callNativePullIfNeeded(JSC::JSGlobalObject* global_object);
    void finishNativePull(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue result);
    void rejectNativePull(JSC::JSGlobalObject* global_object, JSValue error);
    bool teeNativeInto(JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::RefPtr<ReadableStreamNativeSource>&,
        WTF::RefPtr<ReadableStreamNativeSource>&);

private:
    JSColloReadableStream(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    ~JSColloReadableStream()
    {
        if (m_native_source)
            m_native_source->release();
        for (auto& request : m_read_requests) {
            request.promise.clear();
            request.resolve.clear();
            request.reject.clear();
        }
        m_read_requests.clear();
        for (auto& request : m_byob_read_requests) {
            request.promise.clear();
            request.view.clear();
            if (request.deferred)
                collo_promise_deferred_release(request.deferred);
        }
        m_byob_read_requests.clear();
    }

    // No marker can have seen the cell before finishCreation returns, so the source is attached without the cell lock.
    void finishCreation(JSC::VM& vm, WTF::RefPtr<ReadableStreamNativeSource>&& native_source = nullptr)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
        m_native_source = WTF::move(native_source);
    }

    // The marker visits m_native_source under the cell lock, so the pointer is cleared under it. The source is
    // released and freed after the lock is dropped, because release() may call into Zig.
    void releaseNativeSource()
    {
        WTF::RefPtr<ReadableStreamNativeSource> source;
        {
            WTF::Locker locker { cellLock() };
            source = WTF::move(m_native_source);
        }
        m_native_pulling = false;
        if (source)
            source->release();
    }

    // Runs when the stream leaves the readable state, after which it never calls its underlying source again.
    void clearAlgorithms()
    {
        if (auto* current_controller = controller())
            current_controller->clearAlgorithms();
        if (auto* current_byte_controller = byteController())
            current_byte_controller->clearAlgorithms();
    }

    void clearQueue()
    {
        WTF::Locker locker { cellLock() };
        m_queue.clear();
        m_queue_start = 0;
        m_queue_total_size = 0;
        m_queue_memory_cost = 0;
    }

    bool queueEmpty() const { return m_queue_start >= m_queue.size(); }

    bool dequeue(JSValue& value)
    {
        if (queueEmpty())
            return false;
        auto& entry = m_queue[m_queue_start++];
        value = entry.value.get();
        entry.value.clear();
        double size = entry.size;
        size_t memory_cost = entry.memory_cost;
        entry.size = 0;
        entry.memory_cost = 0;
        if (m_queue_total_size > size)
            m_queue_total_size -= size;
        else
            m_queue_total_size = 0;
        subtractQueueMemoryCost(memory_cost);
        compactQueueIfNeeded();
        return true;
    }

    bool firstQueuedByteSpan(std::span<const uint8_t>& out)
    {
        out = {};
        if (queueEmpty())
            return false;
        auto& entry = m_queue[m_queue_start];
        auto* view = dynamicDowncast<JSC::JSArrayBufferView>(entry.value.get());
        if (arrayBufferViewIsUnavailable(view))
            return false;
        auto bytes = viewBytes(view);
        if (entry.byte_offset > bytes.size())
            return false;
        out = bytes.subspan(entry.byte_offset);
        return true;
    }

    bool dequeueByteValue(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue& value)
    {
        if (queueEmpty())
            return false;
        auto& entry = m_queue[m_queue_start];
        auto* view = dynamicDowncast<JSC::JSArrayBufferView>(entry.value.get());
        if (arrayBufferViewIsUnavailable(view))
            return false;
        auto bytes = viewBytes(view);
        if (entry.byte_offset > bytes.size())
            return false;
        if (entry.byte_offset == 0) {
            value = entry.value.get();
        } else {
            value
                = createUint8ArrayView(global_object, scope, view, entry.byte_offset, bytes.size() - entry.byte_offset);
            RETURN_IF_EXCEPTION(scope, false);
        }
        entry.value.clear();
        double size = entry.size;
        size_t memory_cost = entry.memory_cost;
        entry.size = 0;
        entry.memory_cost = 0;
        entry.byte_offset = 0;
        ++m_queue_start;
        if (m_queue_total_size > size)
            m_queue_total_size -= size;
        else
            m_queue_total_size = 0;
        subtractQueueMemoryCost(memory_cost);
        compactQueueIfNeeded();
        return true;
    }

    bool consumeFirstQueuedByteSpan(size_t bytes)
    {
        std::span<const uint8_t> source;
        if (!firstQueuedByteSpan(source))
            return false;
        if (bytes > source.size())
            return false;
        auto& entry = m_queue[m_queue_start];
        entry.byte_offset += bytes;
        if (bytes >= source.size()) {
            entry.value.clear();
            double size = entry.size;
            size_t memory_cost = entry.memory_cost;
            entry.size = 0;
            entry.memory_cost = 0;
            entry.byte_offset = 0;
            ++m_queue_start;
            if (m_queue_total_size > size)
                m_queue_total_size -= size;
            else
                m_queue_total_size = 0;
            subtractQueueMemoryCost(memory_cost);
            compactQueueIfNeeded();
        } else {
            const double copied_size = static_cast<double>(bytes);
            if (entry.size > copied_size)
                entry.size -= copied_size;
            else
                entry.size = 0;
            if (m_queue_total_size > copied_size)
                m_queue_total_size -= copied_size;
            else
                m_queue_total_size = 0;
        }
        return true;
    }

    // Consumed slots stay at the front until every slot is consumed, which clears the vector, or until more than 32
    // have built up and fill at least half of it. A compaction then shifts at most as many live entries as it drops.
    // compactReadRequestsIfNeeded and compactByobReadRequestsIfNeeded follow the same rule.
    void compactQueueIfNeeded()
    {
        if (!m_queue_start)
            return;
        if (m_queue_start >= m_queue.size()) {
            WTF::Locker locker { cellLock() };
            m_queue.clear();
            m_queue_start = 0;
            return;
        }
        if (m_queue_start > 32 && m_queue_start * 2 >= m_queue.size()) {
            WTF::Locker locker { cellLock() };
            m_queue.removeAt(0, m_queue_start);
            m_queue_start = 0;
        }
    }

    bool queueMemoryCostWouldExceed(size_t memory_cost) const
    {
        if (!m_queue_memory_cost_limit)
            return false;
        if (m_queue_memory_cost >= m_queue_memory_cost_limit)
            return memory_cost > 0;
        return memory_cost > m_queue_memory_cost_limit - m_queue_memory_cost;
    }

    void subtractQueueMemoryCost(size_t memory_cost)
    {
        if (m_queue_memory_cost > memory_cost)
            m_queue_memory_cost -= memory_cost;
        else
            m_queue_memory_cost = 0;
    }

    bool hasReadRequests() const { return m_read_request_start < m_read_requests.size(); }
    bool hasByobReadRequests() const { return m_byob_read_request_start < m_byob_read_requests.size(); }

    // Until a read settles, its promise refers back to the stream through a non-enumerable property, so a stream
    // reachable only from a pending read's promise stays alive. appendByobReadRequest does the same, and settling
    // either kind of read removes the reference.
    bool appendReadRequest(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const JSDeferredPromise& deferred)
    {
        if (auto* object = deferred.promise.getObject()) {
            object->putDirect(global_object->vm(), readableStreamOwnerIdentifier(global_object), this,
                static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
        }
        ReadRequest request;
        request.promise.set(global_object->vm(), this, deferred.promise);
        request.resolve.set(global_object->vm(), this, deferred.resolve);
        request.reject.set(global_object->vm(), this, deferred.reject);
        compactReadRequestsIfNeeded();
        bool appended = false;
        {
            WTF::Locker locker { cellLock() };
            appended = m_read_requests.tryAppend(WTF::move(request));
        }
        if (appended)
            return true;
        if (auto* object = deferred.promise.getObject()) {
            object->putDirect(global_object->vm(), readableStreamOwnerIdentifier(global_object), JSC::jsUndefined(),
                static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
        }
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }

    ReadRequest takeFirstReadRequest()
    {
        ASSERT(hasReadRequests());
        auto& slot = m_read_requests[m_read_request_start++];
        auto request = WTF::move(slot);
        slot.promise.clear();
        slot.resolve.clear();
        slot.reject.clear();
        compactReadRequestsIfNeeded();
        return request;
    }

    void compactReadRequestsIfNeeded()
    {
        if (!m_read_request_start)
            return;
        if (m_read_request_start >= m_read_requests.size()) {
            WTF::Locker locker { cellLock() };
            m_read_requests.clear();
            m_read_request_start = 0;
            return;
        }
        if (m_read_request_start > 32 && m_read_request_start * 2 >= m_read_requests.size()) {
            WTF::Locker locker { cellLock() };
            m_read_requests.removeAt(0, m_read_request_start);
            m_read_request_start = 0;
        }
    }

    bool appendByobReadRequest(JSC::JSGlobalObject*, JSC::ThrowScope&, JSValue, ColloPromiseDeferred*,
        JSC::JSArrayBufferView*, JSColloReadableStreamBYOBRequest*, size_t min_bytes);
    bool pushFrontQueuedByteChunk(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSArrayBufferView*);
    ByobReadRequest takeFirstByobReadRequest();
    void compactByobReadRequestsIfNeeded();
    void settleByobReadRequest(JSC::JSGlobalObject*, ByobReadRequest&&, JSValue, bool is_rejection);
    bool refreshFirstByobReadRequest(JSC::JSGlobalObject*, JSC::ThrowScope&);
    bool refreshFirstByobReadRequestAndPullIfNeeded(JSC::JSGlobalObject*, JSC::ThrowScope&);
    bool settleFirstByobReadRequestWithFilledBytes(JSC::JSGlobalObject*, JSC::ThrowScope&, bool done);
    bool firstByobReadRequestIsReady() const;
    bool fulfillFirstByobReadRequestWithChunk(
        JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSArrayBufferView*, size_t offset);
    bool drainQueuedBytesIntoByobRequests(JSC::JSGlobalObject*, JSC::ThrowScope&);

    void settleReadRequest(JSC::JSGlobalObject* global_object, ReadRequest&& request, JSValue value, bool is_rejection)
    {
        JSValue callback = is_rejection ? request.reject.get() : request.resolve.get();
        settleJSDeferredPromise(global_object, callback, value);
        if (auto promise = request.promise.get(); promise.isObject()) {
            promise.getObject()->putDirect(global_object->vm(), readableStreamOwnerIdentifier(global_object),
                JSC::jsUndefined(), static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
        }
        request.promise.clear();
        request.resolve.clear();
        request.reject.clear();
    }

    StreamState m_state { StreamState::Readable };
    JSC::WriteBarrier<JSC::Unknown> m_stored_error;
    JSC::WriteBarrier<JSColloReadableStreamDefaultReader> m_reader;
    JSC::WriteBarrier<JSColloReadableStreamDefaultController> m_controller;
    JSC::WriteBarrier<JSColloReadableByteStreamController> m_byte_controller;
    JSC::WriteBarrier<JSC::JSObject> m_default_tee_state;
    JSC::WriteBarrier<JSC::JSFunction> m_native_pull_fulfilled;
    JSC::WriteBarrier<JSC::JSFunction> m_native_pull_rejected;
    WTF::Vector<QueuedChunk> m_queue;
    WTF::Vector<ReadRequest> m_read_requests;
    WTF::Vector<ByobReadRequest> m_byob_read_requests;
    // visitChildren visits the source under the cell lock; see releaseNativeSource.
    WTF::RefPtr<ReadableStreamNativeSource> m_native_source;
    size_t m_queue_start { 0 };
    size_t m_read_request_start { 0 };
    size_t m_byob_read_request_start { 0 };
    size_t m_queue_memory_cost { 0 };
    // Caps the bytes queued chunks may retain, as streamChunkMemoryCost measures them; an enqueue past it throws a
    // QuotaExceededError. Zero means no cap.
    size_t m_queue_memory_cost_limit { 0 };
    double m_queue_total_size { 0 };
    double m_high_water_mark { 1 };
    bool m_disturbed { false };
    bool m_native_pulling { false };
    bool m_pipe_backpressure { false };
    bool m_is_byte_stream { false };
};

class JSColloReadableStreamDefaultReader final : public JSC::JSDestructibleObject {
    using Base = JSC::JSDestructibleObject;

public:
    template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
    {
        return &vm.destructibleObjectSpace();
    }

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSValue prototype)
    {
        return JSC::Structure::create(
            vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

    static JSColloReadableStreamDefaultReader* create(
        JSC::VM& vm, JSC::JSGlobalObject* global_object, JSColloReadableStream* stream);
    static void destroy(JSCell* cell)
    {
        static_cast<JSColloReadableStreamDefaultReader*>(cell)->~JSColloReadableStreamDefaultReader();
    }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    JSColloReadableStream* stream() const { return m_stream.get(); }
    JSValue closedPromise() const { return m_closed_promise.get(); }
    void release(JSC::JSGlobalObject* global_object);
    void resolveClosed(JSC::JSGlobalObject* global_object)
    {
        settleDeferred(global_object, m_closed_deferred, JSC::jsUndefined(), false);
    }
    void rejectClosed(JSC::JSGlobalObject* global_object, JSValue reason)
    {
        settleDeferred(global_object, m_closed_deferred, reason, true);
    }

private:
    JSColloReadableStreamDefaultReader(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    ~JSColloReadableStreamDefaultReader()
    {
        if (m_closed_deferred)
            collo_promise_deferred_release(m_closed_deferred);
    }

    bool finishCreation(
        JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSColloReadableStream* stream)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
        m_stream.set(vm, this, stream);
        JSValue promise;
        if (!createDeferredPromise(global_object, scope, promise, m_closed_deferred))
            return false;
        m_closed_promise.set(vm, this, promise);
        if (stream->state() == StreamState::Closed)
            resolveClosed(global_object);
        else if (stream->state() == StreamState::Errored)
            rejectClosed(global_object, stream->storedError());
        return true;
    }

    JSC::WriteBarrier<JSColloReadableStream> m_stream;
    JSC::WriteBarrier<JSC::Unknown> m_closed_promise;
    ColloPromiseDeferred* m_closed_deferred { nullptr };
};

// A BYOB reader locks its stream through an internal default reader, which also owns the closed promise, so the
// stream's reader() is that default reader.
class JSColloReadableStreamBYOBReader final : public JSC::JSDestructibleObject {
    using Base = JSC::JSDestructibleObject;

public:
    template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
    {
        return &vm.destructibleObjectSpace();
    }

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSValue prototype)
    {
        return JSC::Structure::create(
            vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

    static JSColloReadableStreamBYOBReader* create(
        JSC::VM&, JSC::JSGlobalObject*, JSColloReadableStream*, JSColloReadableStreamDefaultReader*);
    static void destroy(JSCell* cell)
    {
        static_cast<JSColloReadableStreamBYOBReader*>(cell)->~JSColloReadableStreamBYOBReader();
    }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    JSColloReadableStream* stream() const
    {
        auto* reader = m_default_reader.get();
        return reader ? reader->stream() : nullptr;
    }
    JSValue closedPromise() const { return m_closed_promise.get(); }
    void release(JSC::JSGlobalObject* global_object);

private:
    explicit JSColloReadableStreamBYOBReader(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    void finishCreation(JSC::VM& vm, JSColloReadableStreamDefaultReader* default_reader)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
        m_default_reader.set(vm, this, default_reader);
        m_closed_promise.set(vm, this, default_reader->closedPromise());
    }

    JSC::WriteBarrier<JSColloReadableStreamDefaultReader> m_default_reader;
    JSC::WriteBarrier<JSC::Unknown> m_closed_promise;
};

class JSColloReadableStreamAsyncIterator final : public JSC::JSDestructibleObject {
    using Base = JSC::JSDestructibleObject;

public:
    template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
    {
        return &vm.destructibleObjectSpace();
    }

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSValue prototype)
    {
        return JSC::Structure::create(
            vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

    static JSColloReadableStreamAsyncIterator* create(JSC::VM& vm, Collo::GlobalObject* global_object,
        JSColloReadableStreamDefaultReader* reader, bool prevent_cancel)
    {
        auto* structure = global_object->owner().webapi_cache.readable_stream_async_iterator_structure.get();
        RELEASE_ASSERT(structure);
        auto* object = new (NotNull, JSC::allocateCell<JSColloReadableStreamAsyncIterator>(vm))
            JSColloReadableStreamAsyncIterator(vm, structure, prevent_cancel);
        object->finishCreation(vm, reader);
        return object;
    }

    static void destroy(JSCell* cell)
    {
        static_cast<JSColloReadableStreamAsyncIterator*>(cell)->~JSColloReadableStreamAsyncIterator();
    }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    JSColloReadableStreamDefaultReader* reader() const { return m_reader.get(); }
    JSC::JSPromise* returnPending() const { return m_return_pending.get(); }
    bool preventCancel() const { return m_prevent_cancel; }
    void clearReader() { m_reader.clear(); }
    void setReturnPending(JSC::VM& vm, JSC::JSPromise* promise) { m_return_pending.set(vm, this, promise); }
    void clearReturnPendingIfCurrent(JSC::JSPromise* promise)
    {
        if (m_return_pending.get() == promise)
            m_return_pending.clear();
    }
    JSC::JSFunction* nextFulfilledFunction(JSC::JSGlobalObject*);
    JSC::JSFunction* nextRejectedFunction(JSC::JSGlobalObject*);

private:
    JSColloReadableStreamAsyncIterator(JSC::VM& vm, JSC::Structure* structure, bool prevent_cancel)
        : Base(vm, structure)
        , m_prevent_cancel(prevent_cancel)
    {
    }

    void finishCreation(JSC::VM& vm, JSColloReadableStreamDefaultReader* reader)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
        m_reader.set(vm, this, reader);
    }

    JSC::WriteBarrier<JSColloReadableStreamDefaultReader> m_reader;
    JSC::WriteBarrier<JSC::JSFunction> m_next_fulfilled;
    JSC::WriteBarrier<JSC::JSFunction> m_next_rejected;
    JSC::WriteBarrier<JSC::JSPromise> m_return_pending;
    bool m_prevent_cancel { false };
};

} // namespace Collo::HostFunctions
