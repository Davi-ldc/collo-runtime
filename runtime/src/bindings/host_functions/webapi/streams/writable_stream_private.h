// WritableStream, its default writer and its default controller as JSC cells. They run on the VM thread; their
// visitChildren, in writable_stream_objects.cpp, runs on collector threads at the same time.
//
// The cells reference each other, the sink, the sink's methods and every promise they will settle only through
// WriteBarrier fields, and settle those promises with Collo::settlePromise. The write queue is a Collo::CellEdgeList,
// which owns the lock and barrier protocol (jsc/runtime/cell_edges.h); the active write sits in plain fields of the
// stream, written with their barriers.
//
// The sink is JavaScript (an underlying sink dictionary with its write, close and abort methods) or the TransformStream
// whose writable side this is, whose sink algorithms are C++.

#pragma once

#include "host_functions/webapi/streams/stream_common_private.h"

namespace Collo::HostFunctions {

JSColloWritableStream* requireWritableStream(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue);

class JSColloWritableStreamDefaultController final : public JSC::JSNonFinalObject {
    using Base = JSC::JSNonFinalObject;

public:
    enum class SinkKind : uint8_t {
        JavaScript,
        Transform,
    };

    template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
    {
        static_assert(CellType::needsDestruction == JSC::DoesNotNeedDestruction);
        return &vm.cellSpace();
    }

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::JSValue prototype)
    {
        return JSC::Structure::create(
            vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

    static JSColloWritableStreamDefaultController* create(JSC::VM&, JSC::JSGlobalObject*, JSColloWritableStream*);

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    JSColloWritableStream* stream() const { return m_stream.get(); }
    SinkKind sinkKind() const { return m_sink_kind; }
    // The underlying sink dictionary, or the TransformStream of a Transform sink.
    JSC::JSValue sink() const { return m_sink.get(); }
    JSC::JSValue writeCallback() const { return m_write.get(); }
    JSC::JSValue closeCallback() const { return m_close.get(); }
    JSC::JSValue abortCallback() const { return m_abort.get(); }
    // The strategy's size callback, or undefined to count each chunk as 1.
    JSC::JSValue sizeCallback() const { return m_size.get(); }
    void setJavaScriptSink(JSC::VM& vm, JSC::JSValue sink, JSC::JSValue write, JSC::JSValue close, JSC::JSValue abort)
    {
        m_sink_kind = SinkKind::JavaScript;
        m_sink.set(vm, this, sink);
        m_write.set(vm, this, write);
        m_close.set(vm, this, close);
        m_abort.set(vm, this, abort);
    }
    void setTransformSink(JSC::VM& vm, JSColloTransformStream*);
    void setSizeCallback(JSC::VM& vm, JSC::JSValue size) { m_size.set(vm, this, size); }
    // WritableStreamDefaultControllerClearAlgorithms. Once its close has reached the sink, or it has errored, a stream
    // never calls its sink or size callback again, and dropping them lets the collector reclaim the sink and what its
    // methods capture while the stream itself stays reachable.
    void clearAlgorithms()
    {
        m_sink.setUndefined();
        m_write.setUndefined();
        m_close.setUndefined();
        m_abort.setUndefined();
        m_size.setUndefined();
    }

private:
    JSColloWritableStreamDefaultController(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    void finishCreation(JSC::VM& vm, JSColloWritableStream* stream)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
        m_stream.set(vm, this, stream);
        m_sink.set(vm, this, JSC::jsUndefined());
        m_write.set(vm, this, JSC::jsUndefined());
        m_close.set(vm, this, JSC::jsUndefined());
        m_abort.set(vm, this, JSC::jsUndefined());
        m_size.set(vm, this, JSC::jsUndefined());
    }

    JSC::WriteBarrier<JSColloWritableStream> m_stream;
    JSC::WriteBarrier<JSC::Unknown> m_sink;
    JSC::WriteBarrier<JSC::Unknown> m_write;
    JSC::WriteBarrier<JSC::Unknown> m_close;
    JSC::WriteBarrier<JSC::Unknown> m_abort;
    JSC::WriteBarrier<JSC::Unknown> m_size;
    SinkKind m_sink_kind { SinkKind::JavaScript };
};

class JSColloWritableStream final : public JSC::JSDestructibleObject {
    using Base = JSC::JSDestructibleObject;

    // One queued write: the chunk, and the promise write() returned, which settles when the sink finishes the chunk.
    struct WriteRequest {
        JSC::WriteBarrier<JSC::Unknown> value;
        JSC::WriteBarrier<JSC::JSPromise> promise;
        double size { 0 };

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

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::JSValue prototype)
    {
        return JSC::Structure::create(
            vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

    // A stream with its controller attached and no sink yet. The caller sets the sink and the high-water mark, then
    // starts the stream with startWith.
    static JSColloWritableStream* create(JSC::VM&, JSC::JSGlobalObject*, JSC::Structure*);
    static void destroy(JSCell* cell) { static_cast<JSColloWritableStream*>(cell)->~JSColloWritableStream(); }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    WritableState state() const { return m_state; }
    JSC::JSValue storedError() const { return m_stored_error.get(); }
    bool locked() const { return !!m_writer.get(); }
    bool closeRequested() const { return m_close_requested; }
    JSColloWritableStreamDefaultWriter* writer() const { return m_writer.get(); }
    JSColloWritableStreamDefaultController* controller() const { return m_controller.get(); }
    double desiredSize() const { return m_high_water_mark - m_queue_total_size; }

    void setHighWaterMark(double value) { m_high_water_mark = value; }
    void lock(JSC::VM& vm, JSColloWritableStreamDefaultWriter* writer) { m_writer.set(vm, this, writer); }
    void unlock() { m_writer.clear(); }
    // The start algorithm: the stream calls its sink only once `start_promise` fulfills, and errors when it rejects,
    // even when the sink's start returned synchronously.
    void startWith(JSC::JSGlobalObject*, JSC::JSPromise* start_promise);
    void finishStart(JSC::JSGlobalObject*);
    // The start promise rejected: start has settled, and the stream errors with `reason`.
    void startFailed(JSC::JSGlobalObject*, JSC::JSValue reason);
    void finishWrite(JSC::JSGlobalObject*);
    void rejectWrite(JSC::JSGlobalObject*, JSC::JSValue error);
    void finishClose(JSC::JSGlobalObject*);
    void rejectClose(JSC::JSGlobalObject*, JSC::JSValue error);
    void finishAbort(JSC::JSGlobalObject*);
    void rejectAbort(JSC::JSGlobalObject*, JSC::JSValue error);
    void error(JSC::JSGlobalObject*, JSC::JSValue error);

    JSC::EncodedJSValue write(
        JSC::JSGlobalObject*, JSC::ThrowScope&, JSColloWritableStreamDefaultWriter*, JSC::JSValue chunk);
    JSC::EncodedJSValue write(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue chunk)
    {
        return write(global_object, scope, nullptr, chunk);
    }
    JSC::EncodedJSValue close(JSC::JSGlobalObject*, JSC::ThrowScope&);
    JSC::EncodedJSValue abort(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue reason);

private:
    JSColloWritableStream(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    ~JSColloWritableStream() = default;
    void finishCreation(JSC::VM&);
    // WritableStreamDefaultControllerGetChunkSize: the size callback's result for `chunk`, which may be any number, or
    // 1 when the stream has no size callback (none was given, or clearAlgorithms dropped it) or the callback threw,
    // which errors the stream with what it threw. Returns false when a termination is pending.
    bool chunkSize(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue chunk, double& out_size);
    void processQueue(JSC::JSGlobalObject*);
    // Hand the active write, or the close, to the sink, and wait on the promise its result or exception becomes.
    void writeToSink(JSC::JSGlobalObject*);
    void closeSink(JSC::JSGlobalObject*);
    void subtractQueueSize(double size)
    {
        m_queue_total_size = m_queue_total_size > size ? m_queue_total_size - size : 0;
    }
    // Moves the first queued write into the active write's fields.
    void activateFirstWrite(JSC::VM&);
    // Settles the active write's promise and empties its fields. Returns false when a termination is pending.
    bool settleActiveWrite(JSC::JSGlobalObject*, JSC::JSValue value, bool is_rejection);
    void resolveReadyIfNeeded(JSC::JSGlobalObject*);
    // Rejects the active and every queued write with `error`. Returns false when a termination is pending.
    bool clearWriteQueue(JSC::JSGlobalObject*, JSC::JSValue error);
    bool settleClosed(JSC::JSGlobalObject*, JSC::JSValue value, bool is_rejection);
    // The end of WritableStreamFinishErroring: settles the abort request with `value` and rejects the closed promise
    // of the current writer, which may have been acquired while the sink's abort method ran.
    void finishErroring(JSC::JSGlobalObject*, JSC::JSValue value, bool is_rejection);
    // Runs once the stream calls its sink no more: its close has reached the sink, it errored, or abort has taken the
    // sink's abort method.
    void clearAlgorithms()
    {
        if (auto* current_controller = controller())
            current_controller->clearAlgorithms();
    }

    WritableState m_state { WritableState::Writable };
    JSC::WriteBarrier<JSC::Unknown> m_stored_error;
    JSC::WriteBarrier<JSColloWritableStreamDefaultWriter> m_writer;
    JSC::WriteBarrier<JSColloWritableStreamDefaultController> m_controller;
    // The promises of a pending close and a pending abort request, empty once the request settles.
    JSC::WriteBarrier<JSC::JSPromise> m_close_promise;
    JSC::WriteBarrier<JSC::JSPromise> m_abort_promise;
    Collo::CellEdgeList<WriteRequest> m_write_queue;
    // The write the sink holds or is about to receive, out of the queue. Its barriers name this stream as their owner.
    WriteRequest m_active_write;
    double m_queue_total_size { 0 };
    double m_high_water_mark { 1 };
    // True until the reaction to the sink's start promise runs, however the promise settled.
    bool m_starting { true };
    // Set from WritableStreamMarkFirstWriteRequestInFlight, before the sink's write runs, until the write settles, so a
    // write the sink issues through the stream's own writer queues instead of reaching the sink again.
    bool m_write_in_flight { false };
    bool m_has_active_write { false };
    bool m_close_requested { false };
    // Set before the sink's close runs, for the same reason.
    bool m_close_in_flight { false };
    bool m_abort_in_flight { false };
};

class JSColloWritableStreamDefaultWriter final : public JSC::JSNonFinalObject {
    using Base = JSC::JSNonFinalObject;

public:
    template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
    {
        static_assert(CellType::needsDestruction == JSC::DoesNotNeedDestruction);
        return &vm.cellSpace();
    }

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::JSValue prototype)
    {
        return JSC::Structure::create(
            vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

    // SetUpWritableStreamDefaultWriter, which also locks the stream. Returns null with the exception pending when
    // settling the writer's first promises meets a termination.
    static JSColloWritableStreamDefaultWriter* create(
        JSC::VM&, JSC::JSGlobalObject*, JSC::ThrowScope&, JSColloWritableStream*);

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    JSColloWritableStream* stream() const { return m_stream.get(); }
    JSC::JSValue readyPromise() const { return m_ready_promise.get(); }
    JSC::JSValue closedPromise() const { return m_closed_promise.get(); }
    // WritableStreamUpdateBackpressure with backpressure: a settled ready promise is replaced by a pending one.
    void ensureReadyPending(JSC::JSGlobalObject*);
    void resolveReadyIfNeeded(JSC::JSGlobalObject*, JSColloWritableStream*);
    // Each returns false when a termination is pending.
    bool settleReady(JSC::JSGlobalObject*, JSC::JSValue, bool is_rejection);
    bool settleClosed(JSC::JSValue, bool is_rejection);
    // WritableStreamDefaultWriterRelease: both promises end rejected with a TypeError and handled, a pending one
    // rejected in place.
    void release(JSC::JSGlobalObject*);

private:
    JSColloWritableStreamDefaultWriter(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    bool finishCreation(JSC::VM&, JSC::JSGlobalObject*, JSColloWritableStream*);

    JSC::WriteBarrier<JSColloWritableStream> m_stream;
    JSC::WriteBarrier<JSC::JSPromise> m_ready_promise;
    JSC::WriteBarrier<JSC::JSPromise> m_closed_promise;
};

} // namespace Collo::HostFunctions
