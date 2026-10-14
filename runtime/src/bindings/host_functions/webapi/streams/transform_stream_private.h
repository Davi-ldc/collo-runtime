// TransformStream and its default controller as JSC cells. They run on the VM thread; their visitChildren, in
// transform_stream.cpp, runs on collector threads at the same time.
//
// A transform stream joins a readable and a writable stream: it is the readable side's source and the writable side's
// sink, through C++ algorithms with no function in between. Its transformer is JavaScript, for the TransformStream
// constructor, or native (transform_stream.h) for the GenericTransformStream classes. The cells reference each other,
// the transformer, its methods and the promises they will settle only through WriteBarrier fields; a native
// transformer is a Collo::CellNativeRef. The writable side waits on each sink promise before its next call, so at most
// one write or close reaches the transformer at a time.

#pragma once

#include "host_functions/webapi/streams/readable_stream_private.h"
#include "host_functions/webapi/streams/transform_stream.h"
#include "host_functions/webapi/streams/writable_stream_private.h"

#include <atomic>

namespace Collo::HostFunctions {

class JSColloTransformStreamDefaultController final : public JSC::JSNonFinalObject {
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

    static JSColloTransformStreamDefaultController* create(JSC::VM&, JSC::JSGlobalObject*, JSColloTransformStream*);

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

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::JSValue prototype)
    {
        return JSC::Structure::create(
            vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

    static JSColloTransformStream* create(JSC::VM&, JSC::Structure*, TransformStreamKind);
    static void destroy(JSCell* cell) { static_cast<JSColloTransformStream*>(cell)->~JSColloTransformStream(); }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    TransformStreamKind kind() const { return m_kind; }
    JSColloReadableStream* readable() const { return m_readable.get(); }
    JSColloWritableStream* writable() const { return m_writable.get(); }
    JSColloTransformStreamDefaultController* controller() const { return m_controller.get(); }
    TransformStreamNativeTransformer* nativeTransformer() const { return m_native_transformer.get(); }

    // InitializeTransformStream: creates both sides with this stream as their source and sink, both starting once
    // `start_promise` fulfills. Runs no script.
    void initializeSides(JSC::JSGlobalObject*, JSC::JSPromise* start_promise, double writable_high_water_mark,
        JSC::JSValue writable_size, double readable_high_water_mark, JSC::JSValue readable_size);
    void setJavaScriptTransformer(JSC::VM&, JSColloTransformStreamDefaultController*, JSC::JSValue transformer,
        JSC::JSValue transform, JSC::JSValue flush, JSC::JSValue cancel);
    void setNativeTransformer(JSC::VM&, WTF::Ref<TransformStreamNativeTransformer>&&);

    // TransformStreamDefaultControllerEnqueue, Error and Terminate, for the JavaScript transformer's controller.
    void enqueue(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue chunk);
    void error(JSC::JSGlobalObject*, JSC::JSValue reason);
    void terminate(JSC::JSGlobalObject*);

    // The readable side's source algorithms. A pull lifts the backpressure and resumes a waiting write; a cancel ends
    // the writable side. sourceCancel returns the transformer's cancel result, or the empty value with its exception
    // pending.
    void sourcePull(JSC::JSGlobalObject*);
    JSC::JSValue sourceCancel(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue reason);
    // The writable side's sink algorithms. Each returns a value or a promise the writable side waits on, or the empty
    // value with its exception pending.
    JSC::EncodedJSValue sinkWrite(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue chunk);
    JSC::EncodedJSValue sinkClose(JSC::JSGlobalObject*, JSC::ThrowScope&);
    JSC::EncodedJSValue sinkAbort(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue reason);
    // The reactions to a JavaScript transform's and flush's promises. Each returns the value the result promise
    // fulfills with, or throws its rejection into the scope.
    JSC::JSValue transformSettled(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue, bool fulfilled);
    JSC::JSValue flushSettled(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue, bool fulfilled);

private:
    enum class NativeOperation : uint8_t {
        None,
        Write,
        Close,
    };

    enum class PumpResult : uint8_t {
        // The operation's output is all enqueued.
        Complete,
        // The write waits for the readable side to want output.
        Blocked,
        // Script settled the operation during an enqueue, by canceling the readable side.
        Superseded,
        // An exception is pending.
        Threw,
    };

    JSColloTransformStream(JSC::VM& vm, JSC::Structure* structure, TransformStreamKind kind)
        : Base(vm, structure)
        , m_kind(kind)
    {
    }

    ~JSColloTransformStream() = default;

    void finishCreation(JSC::VM& vm)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
    }

    // TransformStreamDefaultControllerClearAlgorithms. Once the stream errors, terminates, or calls the transformer's
    // flush or cancel, it never calls the transformer again, and dropping it lets the collector reclaim the
    // transformer and what its methods capture while the stream itself stays reachable.
    void clearAlgorithms();
    // TransformStreamDefaultControllerPerformTransform for the JavaScript transformer.
    JSC::EncodedJSValue performTransform(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue chunk);
    // Parks a write while backpressure holds and returns the promise the writable side waits on, which sourcePull
    // settles once the readable side pulls.
    JSC::EncodedJSValue deferWrite(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue chunk);
    // Takes the parked write once the readable side pulled. Returns false when none is parked, or when the writable
    // side stopped being writable meanwhile, which rejects the write with that side's stored error without the
    // transformer seeing its chunk (TransformStreamDefaultSinkWriteAlgorithm).
    bool takeParkedWrite(JSC::JSPromise*& out_promise, JSC::JSValue& out_chunk);
    void errorWritableAndUnblockWrite(JSC::JSGlobalObject*, JSC::JSValue reason);
    // Returns false when a termination is pending.
    bool rejectPendingWrite(JSC::JSGlobalObject*, JSC::JSValue reason);
    // The end of TransformStreamDefaultSinkCloseAlgorithm once flush succeeded: closes the readable side, or throws its
    // stored error when it errored meanwhile.
    JSC::JSValue finishFlush(JSC::JSGlobalObject*, JSC::ThrowScope&);

    // Whether the readable side wants output: it is readable, and a read waits or its queue is below its high-water
    // mark. The pump produces a write's output only while it holds, and its negation is
    // ReadableStreamDefaultControllerHasBackpressure, which sets m_backpressure after an enqueue.
    bool readableWantsOutput() const;
    // Makes `promise` the one the writable side waits on for the native transformer's `operation`.
    void beginNativeOperation(JSC::VM&, JSC::JSPromise*, NativeOperation);
    // Feeds `chunk` to the native transformer for the pending write and drives it. Every outcome settles the
    // operation's promise or leaves it pending for the pump; only a termination stays pending in the scope.
    void runNativeWrite(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue chunk);
    // A native transformer's write() or close() failed: errors both sides and rejects the pending operation with what
    // it threw. A termination stays pending and settles nothing.
    void failTransformerCall(JSC::JSGlobalObject*, JSC::ThrowScope&);
    // Pumps the pending operation and completes it once its output is enqueued. A failure errors both sides and
    // rejects the operation; only a termination stays pending in the scope.
    void driveNativeOperation(JSC::JSGlobalObject*, JSC::ThrowScope&);
    PumpResult pumpNative(JSC::JSGlobalObject*, JSC::ThrowScope&);
    void completeNativeOperation(JSC::JSGlobalObject*);
    JSC::JSPromise* takeNativeOperation();
    void rejectNativeOperation(JSC::JSValue reason);
    // Errors the readable side, releases the transformer and rejects the pending operation or parked write, whose
    // rejection errors the writable side when it reaches it.
    void failNative(JSC::JSGlobalObject*, JSC::JSValue reason);
    void releaseNativeTransformer();
    void noteNativeMemoryCost();

    TransformStreamKind m_kind;
    JSC::WriteBarrier<JSColloReadableStream> m_readable;
    JSC::WriteBarrier<JSColloWritableStream> m_writable;
    JSC::WriteBarrier<JSColloTransformStreamDefaultController> m_controller;
    JSC::WriteBarrier<JSC::Unknown> m_transformer;
    JSC::WriteBarrier<JSC::Unknown> m_transform;
    JSC::WriteBarrier<JSC::Unknown> m_flush;
    JSC::WriteBarrier<JSC::Unknown> m_cancel;
    // The write parked while backpressure holds: its chunk, and the promise the writable side waits on, empty while no
    // write is parked.
    JSC::WriteBarrier<JSC::Unknown> m_pending_write_chunk;
    JSC::WriteBarrier<JSC::JSPromise> m_pending_write_promise;
    // The promise the writable side waits on for the native transformer's pending write or close.
    JSC::WriteBarrier<JSC::JSPromise> m_native_promise;
    Collo::CellNativeRef<TransformStreamNativeTransformer> m_native_transformer;
    // The native bytes the transformer holds, for visitChildren, which runs on collector threads and reads only this.
    std::atomic<size_t> m_native_memory_cost { 0 };
    // The most this cell has reported as allocated. Only growth past it is reported again, so output that is handed to
    // the readable side and then replaced does not count as new allocation each time.
    size_t m_native_memory_cost_reported { 0 };
    NativeOperation m_native_operation { NativeOperation::None };
    // The standard's [[backpressure]], for both kinds of transformer: set from the start when the readable side's
    // high-water mark is 0 and by an enqueue that leaves the readable side wanting no more, cleared by its pull. A
    // write parks while it is set.
    bool m_backpressure { false };
    // True while pumpNative runs. A pull that script triggers during an enqueue returns at once, since the pump
    // checks demand again after every enqueue.
    bool m_pumping { false };
    // True while a call into the native transformer is on the stack, so a release that script run by write()
    // requests waits for it, as does reading its memory cost; m_release_deferred records that request.
    bool m_transformer_busy { false };
    bool m_release_deferred { false };
    // The transformer was released; the object stays for the class's accessors, and no write or close reaches it.
    bool m_native_released { false };
};

} // namespace Collo::HostFunctions
