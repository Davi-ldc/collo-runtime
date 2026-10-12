// WritableStream, its default writer and its default controller as JSC cells.
// They run on the VM thread; their visitChildren, in writable_stream_objects.cpp,
// runs on collector threads at the same time.
//
// The cells reference each other, the sink, the sink's methods and every promise
// they will settle only through WriteBarrier fields, and settle those promises
// with Collo::settlePromise. The write queue is a Collo::CellEdgeList, which owns
// the lock and barrier protocol (jsc/runtime/cell_edges.h); the active write sits
// in plain fields of the stream, written with their barriers.
#pragma once

#include "host_functions/webapi/streams/stream_common_private.h"

namespace Collo::HostFunctions {

JSC_DECLARE_HOST_FUNCTION(writableStreamConstructorCall);
JSC_DECLARE_HOST_FUNCTION(writableStreamConstructorConstruct);
JSC_DECLARE_HOST_FUNCTION(writableStreamGetWriter);
JSC_DECLARE_HOST_FUNCTION(writableStreamGetLocked);
JSC_DECLARE_HOST_FUNCTION(writableStreamAbort);
JSC_DECLARE_HOST_FUNCTION(writableStreamClose);
JSC_DECLARE_HOST_FUNCTION(defaultWriterConstructorCall);
JSC_DECLARE_HOST_FUNCTION(defaultWriterConstructorConstruct);
JSC_DECLARE_HOST_FUNCTION(writerWrite);
JSC_DECLARE_HOST_FUNCTION(writerClose);
JSC_DECLARE_HOST_FUNCTION(writerAbort);
JSC_DECLARE_HOST_FUNCTION(writerReleaseLock);
JSC_DECLARE_HOST_FUNCTION(writerClosed);
JSC_DECLARE_HOST_FUNCTION(writerReady);
JSC_DECLARE_HOST_FUNCTION(writerDesiredSize);
JSC_DECLARE_HOST_FUNCTION(defaultWriterControllerCall);
JSC_DECLARE_HOST_FUNCTION(defaultWriterControllerConstruct);
JSC_DECLARE_HOST_FUNCTION(writableControllerError);

// Each returns the value as the named class, or throws a TypeError and returns
// null.
JSColloWritableStream* requireWritableStream(JSC::JSGlobalObject*, JSC::ThrowScope&, JSValue);
JSColloWritableStreamDefaultWriter* requireWritableStreamDefaultWriter(JSC::JSGlobalObject*, JSC::ThrowScope&, JSValue);
JSColloWritableStreamDefaultController* requireWritableStreamDefaultController(
    JSC::JSGlobalObject*, JSC::ThrowScope&, JSValue);
// Creates a stream whose sink methods are start, write, close and abort, each
// called with underlying_sink as this, and runs start before returning. size is
// the queuing strategy's size callback and is called with undefined as this.
// The caller passes a validated high-water mark. Returns null with the
// exception pending when start throws.
JSColloWritableStream* createWritableStreamFromCallbacks(JSC::JSGlobalObject*, JSC::ThrowScope&, JSValue start,
    JSValue write, JSValue close, JSValue abort, JSValue size, double high_water_mark,
    JSValue underlying_sink = JSC::jsUndefined());

class JSColloWritableStreamDefaultController final : public JSC::JSDestructibleObject {
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

    static JSColloWritableStreamDefaultController* create(
        JSC::VM& vm, JSC::JSGlobalObject* global_object, JSColloWritableStream* stream);
    static void destroy(JSCell* cell)
    {
        static_cast<JSColloWritableStreamDefaultController*>(cell)->~JSColloWritableStreamDefaultController();
    }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    JSColloWritableStream* stream() const { return m_stream.get(); }
    JSValue writeCallback() const { return m_write.get(); }
    JSValue closeCallback() const { return m_close.get(); }
    JSValue abortCallback() const { return m_abort.get(); }
    JSValue sizeCallback() const { return m_size.get(); }
    JSValue underlyingSink() const { return m_underlying_sink.get(); }
    void setCallbacks(JSC::VM& vm, JSValue write, JSValue close, JSValue abort, JSValue size)
    {
        m_write.set(vm, this, write);
        m_close.set(vm, this, close);
        m_abort.set(vm, this, abort);
        m_size.set(vm, this, size);
    }
    void setUnderlyingSink(JSC::VM& vm, JSValue sink) { m_underlying_sink.set(vm, this, sink); }
    // WritableStreamDefaultControllerClearAlgorithms. A closed or errored
    // stream never calls its sink again, and dropping the sink lets the
    // collector reclaim it and what its methods capture while the stream
    // itself stays reachable.
    void clearAlgorithms()
    {
        m_write.setUndefined();
        m_close.setUndefined();
        m_abort.setUndefined();
        m_size.setUndefined();
        m_underlying_sink.setUndefined();
    }
    JSC::JSFunction* startFulfilledFunction(JSC::JSGlobalObject*);
    JSC::JSFunction* startRejectedFunction(JSC::JSGlobalObject*);

private:
    explicit JSColloWritableStreamDefaultController(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    void finishCreation(JSC::VM& vm, JSColloWritableStream* stream)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
        m_stream.set(vm, this, stream);
        m_write.set(vm, this, JSC::jsUndefined());
        m_close.set(vm, this, JSC::jsUndefined());
        m_abort.set(vm, this, JSC::jsUndefined());
        m_size.set(vm, this, JSC::jsUndefined());
        m_underlying_sink.set(vm, this, JSC::jsUndefined());
    }

    JSC::WriteBarrier<JSColloWritableStream> m_stream;
    JSC::WriteBarrier<JSC::Unknown> m_write;
    JSC::WriteBarrier<JSC::Unknown> m_close;
    JSC::WriteBarrier<JSC::Unknown> m_abort;
    JSC::WriteBarrier<JSC::Unknown> m_size;
    JSC::WriteBarrier<JSC::Unknown> m_underlying_sink;
    JSC::WriteBarrier<JSC::JSFunction> m_start_fulfilled;
    JSC::WriteBarrier<JSC::JSFunction> m_start_rejected;
};

class JSColloWritableStream final : public JSC::JSDestructibleObject {
    using Base = JSC::JSDestructibleObject;

    // One queued write: the chunk, and the promise write() returned, which
    // settles when the sink finishes the chunk.
    struct WriteRequest {
        JSC::WriteBarrier<JSC::Unknown> value;
        JSC::WriteBarrier<JSC::JSPromise> promise;
        double size { 0 };
        size_t memory_cost { 0 };

        template <typename Visitor> void visitEdges(Visitor& visitor) const
        {
            visitor.append(value);
            visitor.append(promise);
        }
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

    static JSColloWritableStream* create(JSC::VM& vm, Collo::GlobalObject* global_object);
    static JSColloWritableStream* createWithStructure(
        JSC::VM& vm, Collo::GlobalObject* global_object, JSC::Structure* structure);
    static void destroy(JSCell* cell) { static_cast<JSColloWritableStream*>(cell)->~JSColloWritableStream(); }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    WritableState state() const { return m_state; }
    JSValue storedError() const { return m_stored_error.get(); }
    bool locked() const { return !!m_writer.get(); }
    bool starting() const { return m_starting; }
    bool closeRequested() const { return m_close_requested; }
    JSColloWritableStreamDefaultWriter* writer() const { return m_writer.get(); }
    JSColloWritableStreamDefaultController* controller() const { return m_controller.get(); }
    double desiredSize() const { return m_high_water_mark - m_queue_total_size; }

    void setHighWaterMark(double value) { m_high_water_mark = value; }
    // Optional bounds on queued writes, in streamChunkMemoryCost bytes and in
    // requests, where 0 means unbounded. A write past either passes a
    // QuotaExceededError to the queue-limit callback, or errors the stream with
    // it when none is set, and is rejected with it; a callback that throws
    // errors the stream with its exception instead. A chunk that costs no
    // bytes, such as an empty string or a view of an empty buffer, passes the
    // byte limit even when it is reached, so only the count limit bounds a run
    // of them. Each queued write holds a promise and a queue slot, so an
    // unbounded run grows memory the byte limit never counts.
    void setQueueMemoryCostLimit(size_t value) { m_queue_memory_cost_limit = value; }
    void setQueuePendingCountLimit(size_t value) { m_write_queue_pending_limit = value; }
    void setQueueMemoryLimitExceededCallback(JSC::VM& vm, JSValue callback)
    {
        m_queue_memory_limit_exceeded.set(vm, this, callback);
    }
    void setController(JSC::VM& vm, JSColloWritableStreamDefaultController* controller)
    {
        m_controller.set(vm, this, controller);
    }
    void lock(JSC::VM& vm, JSColloWritableStreamDefaultWriter* writer) { m_writer.set(vm, this, writer); }
    void unlock() { m_writer.clear(); }
    void setStarting(bool value) { m_starting = value; }
    // Runs the sink's start method once, after the controller is attached;
    // the stream keeps no reference to it.
    void start(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue start_callback);
    void processQueue(JSC::JSGlobalObject* global_object);
    void finishStart(JSC::JSGlobalObject* global_object);
    void finishWrite(JSC::JSGlobalObject* global_object);
    void rejectWrite(JSC::JSGlobalObject* global_object, JSValue error);
    void finishClose(JSC::JSGlobalObject* global_object);
    void rejectClose(JSC::JSGlobalObject* global_object, JSValue error);
    void finishAbort(JSC::JSGlobalObject* global_object);
    void rejectAbort(JSC::JSGlobalObject* global_object, JSValue error);
    void error(JSC::JSGlobalObject* global_object, JSValue error);

    EncodedJSValue write(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        JSColloWritableStreamDefaultWriter* writer, JSValue chunk);
    EncodedJSValue write(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue chunk)
    {
        return write(global_object, scope, nullptr, chunk);
    }
    EncodedJSValue close(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope);
    EncodedJSValue abort(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue reason);

    JSC::JSFunction* writeFulfilledFunction(JSC::JSGlobalObject*);
    JSC::JSFunction* writeRejectedFunction(JSC::JSGlobalObject*);
    JSC::JSFunction* closeFulfilledFunction(JSC::JSGlobalObject*);
    JSC::JSFunction* closeRejectedFunction(JSC::JSGlobalObject*);
    JSC::JSFunction* abortFulfilledFunction(JSC::JSGlobalObject*);
    JSC::JSFunction* abortRejectedFunction(JSC::JSGlobalObject*);

private:
    JSColloWritableStream(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    ~JSColloWritableStream() = default;
    void finishCreation(JSC::VM& vm);
    bool queueMemoryCostWouldExceed(size_t memory_cost) const;
    bool queuePendingCountWouldExceed() const;
    void subtractQueueSize(double size, size_t memory_cost);
    bool notifyQueueMemoryLimitExceeded(JSC::JSGlobalObject*, JSC::ThrowScope&, JSValue reason);
    // Moves the first queued write into the active write's fields.
    void activateFirstWrite(JSC::VM&);
    // Settles the active write's promise and empties its fields. Returns false
    // when a termination is pending.
    bool settleActiveWrite(JSC::JSGlobalObject* global_object, JSValue value, bool is_rejection);
    void resolveReadyIfNeeded(JSC::JSGlobalObject* global_object);
    // Rejects the active and every queued write with `error`. Returns false
    // when a termination is pending.
    bool clearWriteQueue(JSC::JSGlobalObject* global_object, JSValue error);
    bool settleClosed(JSC::JSGlobalObject* global_object, JSValue value, bool is_rejection);
    // The end of WritableStreamFinishErroring: settles the abort request with
    // `value` and rejects the closed promise of the current writer, which may
    // have been acquired while the sink's abort method ran.
    void finishErroring(JSC::JSGlobalObject* global_object, JSValue value, bool is_rejection);
    // Runs once the stream can no longer call its sink: it is closed or
    // errored, or abort has taken the sink's abort method.
    void clearAlgorithms()
    {
        if (auto* current_controller = controller())
            current_controller->clearAlgorithms();
    }

    WritableState m_state { WritableState::Writable };
    JSC::WriteBarrier<JSC::Unknown> m_stored_error;
    JSC::WriteBarrier<JSColloWritableStreamDefaultWriter> m_writer;
    JSC::WriteBarrier<JSColloWritableStreamDefaultController> m_controller;
    // The promises of a pending close and a pending abort request, empty once
    // the request settles.
    JSC::WriteBarrier<JSC::JSPromise> m_close_promise;
    JSC::WriteBarrier<JSC::JSPromise> m_abort_promise;
    JSC::WriteBarrier<JSC::JSFunction> m_write_fulfilled;
    JSC::WriteBarrier<JSC::JSFunction> m_write_rejected;
    JSC::WriteBarrier<JSC::JSFunction> m_close_fulfilled;
    JSC::WriteBarrier<JSC::JSFunction> m_close_rejected;
    JSC::WriteBarrier<JSC::JSFunction> m_abort_fulfilled;
    JSC::WriteBarrier<JSC::JSFunction> m_abort_rejected;
    JSC::WriteBarrier<JSC::Unknown> m_queue_memory_limit_exceeded;
    Collo::CellEdgeList<WriteRequest> m_write_queue;
    // The write the sink holds or is about to receive, out of the queue. Its
    // barriers name this stream as their owner.
    WriteRequest m_active_write;
    size_t m_write_queue_pending_limit { 0 };
    size_t m_queue_memory_cost { 0 };
    size_t m_queue_memory_cost_limit { 0 };
    double m_queue_total_size { 0 };
    double m_high_water_mark { 1 };
    bool m_starting { false };
    // Set from WritableStreamMarkFirstWriteRequestInFlight, before the sink's
    // write runs, until the write settles, so a write the sink issues through
    // the stream's own writer queues instead of reaching the sink again.
    bool m_write_in_flight { false };
    bool m_has_active_write { false };
    bool m_close_requested { false };
    // Set before the sink's close runs, for the same reason.
    bool m_close_in_flight { false };
    bool m_abort_in_flight { false };
};

class JSColloWritableStreamDefaultWriter final : public JSC::JSDestructibleObject {
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

    // Returns null with the exception pending when settling the writer's
    // first promises meets a termination.
    static JSColloWritableStreamDefaultWriter* create(
        JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSColloWritableStream* stream);
    static void destroy(JSCell* cell)
    {
        static_cast<JSColloWritableStreamDefaultWriter*>(cell)->~JSColloWritableStreamDefaultWriter();
    }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    JSColloWritableStream* stream() const { return m_stream.get(); }
    JSValue readyPromise() const { return m_ready_promise.get(); }
    JSValue closedPromise() const { return m_closed_promise.get(); }
    // WritableStreamUpdateBackpressure with backpressure: a settled ready
    // promise is replaced by a pending one.
    void ensureReadyPending(JSC::JSGlobalObject*);
    void resolveReadyIfNeeded(JSC::JSGlobalObject*, JSColloWritableStream*);
    // Each returns false when a termination is pending.
    bool settleReady(JSC::JSGlobalObject*, JSValue, bool is_rejection);
    bool settleClosed(JSC::JSGlobalObject*, JSValue, bool is_rejection);
    // WritableStreamDefaultWriterRelease: both promises end rejected with a
    // TypeError and handled, a pending one rejected in place.
    void release(JSC::JSGlobalObject* global_object);

private:
    JSColloWritableStreamDefaultWriter(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    ~JSColloWritableStreamDefaultWriter() = default;
    bool finishCreation(JSC::VM&, JSC::JSGlobalObject*, JSColloWritableStream*);

    JSC::WriteBarrier<JSColloWritableStream> m_stream;
    JSC::WriteBarrier<JSC::JSPromise> m_ready_promise;
    JSC::WriteBarrier<JSC::JSPromise> m_closed_promise;
};

} // namespace Collo::HostFunctions
