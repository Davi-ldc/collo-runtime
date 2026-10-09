// TransformStream, its default controller, and the state of one pipeTo, as JSC
// cells. They run on the VM thread; their visitChildren, in
// pipe_transform_stream_objects.cpp, runs on collector threads at the same time.
//
// The cells reference each other, the transformer and its methods only through
// WriteBarrier fields. A transform stream owns the ColloPromiseDeferred of its
// one parked write until that write settles or the destructor releases it. A
// pipe state holds the locks on its source and destination until it settles.
#pragma once

#include "host_functions/webapi/streams/readable_stream_private.h"
#include "host_functions/webapi/streams/writable_stream_private.h"

namespace Collo::HostFunctions {

JSC_DECLARE_HOST_FUNCTION(transformStreamConstructorCall);
JSC_DECLARE_HOST_FUNCTION(transformStreamConstructorConstruct);
JSC_DECLARE_HOST_FUNCTION(transformStreamGetReadable);
JSC_DECLARE_HOST_FUNCTION(transformStreamGetWritable);
JSC_DECLARE_HOST_FUNCTION(transformControllerConstructorCall);
JSC_DECLARE_HOST_FUNCTION(transformControllerConstructorConstruct);
JSC_DECLARE_HOST_FUNCTION(transformControllerEnqueue);
JSC_DECLARE_HOST_FUNCTION(transformControllerError);
JSC_DECLARE_HOST_FUNCTION(transformControllerTerminate);
JSC_DECLARE_HOST_FUNCTION(transformControllerDesiredSize);

// Each returns the value as the named class, or throws a TypeError and returns
// null.
JSColloTransformStream* requireTransformStream(JSC::JSGlobalObject*, JSC::ThrowScope&, JSValue);
JSColloTransformStreamDefaultController* requireTransformStreamDefaultController(
    JSC::JSGlobalObject*, JSC::ThrowScope&, JSValue);
// Locks both streams and starts ReadableStreamPipeTo, returning its promise. A
// locked stream yields a promise rejected with a TypeError. Invalid options
// become a rejected promise when reject_option_errors is set, as Web IDL does
// for the promise-returning pipeTo, and a thrown exception otherwise, as
// pipeThrough needs.
EncodedJSValue startReadablePipeTo(JSC::JSGlobalObject*, JSC::ThrowScope&, JSColloReadableStream*,
    JSColloWritableStream*, JSValue, bool reject_option_errors);

class JSColloTransformStreamDefaultController final : public JSC::JSDestructibleObject {
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

    static JSColloTransformStreamDefaultController* create(
        JSC::VM& vm, JSC::JSGlobalObject* global_object, JSColloTransformStream* stream);
    static void destroy(JSCell* cell)
    {
        static_cast<JSColloTransformStreamDefaultController*>(cell)->~JSColloTransformStreamDefaultController();
    }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    JSColloTransformStream* transformStream() const { return m_stream.get(); }

private:
    JSColloTransformStreamDefaultController(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    void finishCreation(JSC::VM& vm, JSColloTransformStream* stream)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
        m_stream.set(vm, this, stream);
    }

    JSC::WriteBarrier<JSColloTransformStream> m_stream;
};

class JSColloTransformStream final : public JSC::JSDestructibleObject {
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

    static JSColloTransformStream* create(JSC::VM& vm, Collo::GlobalObject* global_object);
    static JSColloTransformStream* createWithStructure(JSC::VM& vm, JSC::Structure* structure);
    static void destroy(JSCell* cell) { static_cast<JSColloTransformStream*>(cell)->~JSColloTransformStream(); }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    JSColloReadableStream* readable() const { return m_readable.get(); }
    JSColloWritableStream* writable() const { return m_writable.get(); }
    JSColloTransformStreamDefaultController* controller() const { return m_controller.get(); }
    JSValue transformer() const { return m_transformer.get(); }
    JSValue transformCallback() const { return m_transform.get(); }
    JSValue flushCallback() const { return m_flush.get(); }
    JSValue cancelCallback() const { return m_cancel.get(); }
    void setTransformer(JSC::VM& vm, JSValue transformer) { m_transformer.set(vm, this, transformer); }
    void setCallbacks(JSC::VM& vm, JSValue start, JSValue transform, JSValue flush, JSValue cancel)
    {
        m_start.set(vm, this, start);
        m_transform.set(vm, this, transform);
        m_flush.set(vm, this, flush);
        m_cancel.set(vm, this, cancel);
    }
    // The transformer's start method runs once, from the writable side's
    // start, so the stream drops it when it is taken.
    JSValue takeStartCallback()
    {
        JSValue start = m_start.get();
        m_start.setUndefined();
        return start;
    }
    // TransformStreamDefaultControllerClearAlgorithms. Once the stream errors,
    // terminates, or calls the transformer's flush or cancel, it never calls
    // the transformer again, and dropping it lets the collector reclaim the
    // transformer and what its methods capture while the stream itself stays
    // reachable.
    void clearAlgorithms()
    {
        m_transformer.setUndefined();
        m_start.setUndefined();
        m_transform.setUndefined();
        m_flush.setUndefined();
        m_cancel.setUndefined();
    }
    void setReadable(JSC::VM& vm, JSColloReadableStream* readable) { m_readable.set(vm, this, readable); }
    void setWritable(JSC::VM& vm, JSColloWritableStream* writable) { m_writable.set(vm, this, writable); }
    void setController(JSC::VM& vm, JSColloTransformStreamDefaultController* controller)
    {
        m_controller.set(vm, this, controller);
    }
    void enqueue(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue chunk);
    void error(JSC::JSGlobalObject* global_object, JSValue reason);
    void terminate(JSC::JSGlobalObject* global_object);

    bool backpressure() const { return m_backpressure; }
    void setBackpressure(bool value) { m_backpressure = value; }
    EncodedJSValue performTransform(JSC::JSGlobalObject*, JSC::ThrowScope&, JSValue chunk);
    EncodedJSValue deferWrite(JSC::JSGlobalObject*, JSC::ThrowScope&, JSValue chunk);
    void readablePulled(JSC::JSGlobalObject*);
    void errorWritableAndUnblockWrite(JSC::JSGlobalObject*, JSValue reason);
    void rejectPendingWrite(JSC::JSGlobalObject*, JSValue reason);

private:
    JSColloTransformStream(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    ~JSColloTransformStream();

    void finishCreation(JSC::VM& vm)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
    }

    JSC::WriteBarrier<JSColloReadableStream> m_readable;
    JSC::WriteBarrier<JSColloWritableStream> m_writable;
    JSC::WriteBarrier<JSColloTransformStreamDefaultController> m_controller;
    JSC::WriteBarrier<JSC::Unknown> m_transformer;
    JSC::WriteBarrier<JSC::Unknown> m_start;
    JSC::WriteBarrier<JSC::Unknown> m_transform;
    JSC::WriteBarrier<JSC::Unknown> m_flush;
    JSC::WriteBarrier<JSC::Unknown> m_cancel;
    JSC::WriteBarrier<JSC::Unknown> m_pending_write_chunk;
    JSC::WriteBarrier<JSC::Unknown> m_pending_write_promise;
    // Can keep this cell alive until VM teardown: see the FIXME in stream_common_private.h.
    ColloPromiseDeferred* m_pending_write_deferred { nullptr };
    bool m_has_pending_write { false };
    bool m_backpressure { false };
};

class JSColloPipeToState final : public JSC::JSDestructibleObject {
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

    static JSColloPipeToState* create(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSColloReadableStream* source,
        JSColloWritableStream* destination, JSColloReadableStreamDefaultReader* reader,
        JSColloWritableStreamDefaultWriter* writer);
    static void destroy(JSCell* cell) { static_cast<JSColloPipeToState*>(cell)->~JSColloPipeToState(); }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    bool finishCreation(JSC::VM&, JSC::JSGlobalObject*, JSC::ThrowScope&, JSColloReadableStream*,
        JSColloWritableStream*, JSColloReadableStreamDefaultReader*, JSColloWritableStreamDefaultWriter*);
    JSValue promise() const { return m_promise.get(); }
    void setOptions(bool prevent_close, bool prevent_abort, bool prevent_cancel)
    {
        m_prevent_close = prevent_close;
        m_prevent_abort = prevent_abort;
        m_prevent_cancel = prevent_cancel;
    }
    void setSignal(JSC::VM& vm, JSColloAbortSignal* signal) { m_signal.set(vm, this, signal); }
    void pump(JSC::JSGlobalObject*);
    void readFulfilled(JSC::JSGlobalObject*, JSValue result);
    void readRejected(JSC::JSGlobalObject*, JSValue reason);
    void writeFulfilled(JSC::JSGlobalObject*);
    void writeRejected(JSC::JSGlobalObject*, JSValue reason);
    void settle(JSC::JSGlobalObject*, JSValue value, bool is_rejection);
    void abortFromSignal(JSC::JSGlobalObject*, JSValue reason);
    JSC::JSFunction* readFulfilledFunction(JSC::JSGlobalObject*);
    JSC::JSFunction* readRejectedFunction(JSC::JSGlobalObject*);
    JSC::JSFunction* writeFulfilledFunction(JSC::JSGlobalObject*);
    JSC::JSFunction* writeRejectedFunction(JSC::JSGlobalObject*);
    JSC::JSFunction* signalAbortFunction(JSC::JSGlobalObject*);
    JSC::JSFunction* shutdownFulfilledFunction(JSC::JSGlobalObject*);
    JSC::JSFunction* shutdownRejectedFunction(JSC::JSGlobalObject*);
    void shutdownActionRejected(JSC::JSGlobalObject*, JSValue reason);
    void shutdownActionSettled(JSC::JSGlobalObject*);
    void abandonStartFailure(JSC::JSGlobalObject*);

private:
    explicit JSColloPipeToState(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    ~JSColloPipeToState() = default;
    void cleanupLocks(JSC::JSGlobalObject*);
    void detachSignal();
    void clearPromiseOwner(JSC::JSGlobalObject*);
    void settlePromise(JSC::JSGlobalObject*, JSValue value, bool is_rejection);
    void shutdownAndSettle(
        JSC::JSGlobalObject*, JSValue reason, bool is_rejection, bool abort_destination, bool cancel_source);
    void performShutdownActions(
        JSC::JSGlobalObject*, JSValue reason, bool is_rejection, bool abort_destination, bool cancel_source);
    void runDeferredShutdownActions(JSC::JSGlobalObject*);
    void finishSourceDoneIfReady(JSC::JSGlobalObject*);
    void startShutdownAction(JSC::JSGlobalObject*, JSValue action_value);
    void recordShutdownRejection(JSC::JSGlobalObject*, JSValue reason);
    void finishShutdownIfReady(JSC::JSGlobalObject*);

    JSC::WriteBarrier<JSColloReadableStream> m_source;
    JSC::WriteBarrier<JSColloWritableStream> m_destination;
    JSC::WriteBarrier<JSColloReadableStreamDefaultReader> m_reader;
    JSC::WriteBarrier<JSColloWritableStreamDefaultWriter> m_writer;
    JSC::WriteBarrier<JSC::Unknown> m_promise;
    JSC::WriteBarrier<JSC::Unknown> m_resolve;
    JSC::WriteBarrier<JSC::Unknown> m_reject;
    JSC::WriteBarrier<JSC::Unknown> m_signal;
    JSC::WriteBarrier<JSC::JSFunction> m_read_fulfilled;
    JSC::WriteBarrier<JSC::JSFunction> m_read_rejected;
    JSC::WriteBarrier<JSC::JSFunction> m_write_fulfilled;
    JSC::WriteBarrier<JSC::JSFunction> m_write_rejected;
    JSC::WriteBarrier<JSC::JSFunction> m_signal_abort;
    JSC::WriteBarrier<JSC::JSFunction> m_shutdown_fulfilled;
    JSC::WriteBarrier<JSC::JSFunction> m_shutdown_rejected;
    JSC::WriteBarrier<JSC::Unknown> m_shutdown_reason;
    unsigned m_shutdown_pending { 0 };
    bool m_prevent_close { false };
    bool m_prevent_abort { false };
    bool m_prevent_cancel { false };
    bool m_settled { false };
    bool m_pumping { false };
    bool m_read_in_flight { false };
    bool m_shutting_down { false };
    bool m_shutdown_is_rejection { false };
    unsigned m_writes_in_flight { 0 };
    bool m_source_done { false };
    bool m_deferred_shutdown { false };
    bool m_deferred_abort_destination { false };
    bool m_deferred_cancel_source { false };
};

} // namespace Collo::HostFunctions
