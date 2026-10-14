// ReadableStreamPipeTo, which pipeTo and pipeThrough share, as the state cell of one pipe. Runs on the VM thread; the
// cell's visitChildren, in pipe_to.cpp, runs on collector threads at the same time.
//
// The state holds the locks on its source and destination until it settles, and every edge it has is a WriteBarrier
// field. The reactions to its read, its writes, its shutdown actions and its reader's and writer's promises carry it as
// their context, and its AbortSignal holds it as the context of a native abort algorithm until the pipe settles, so an
// unfinished pipe that nothing can advance is collected with both streams.

#pragma once

#include "host_functions/webapi/events/abort.h"
#include "host_functions/webapi/streams/readable_stream_private.h"
#include "host_functions/webapi/streams/writable_stream_private.h"

namespace Collo::HostFunctions {

// How startReadablePipeTo reports invalid options and a locked stream: as a rejected promise, as Web IDL and the
// standard do for pipeTo, or as a thrown exception, as pipeThrough does.
enum class PipeToErrors : uint8_t {
    Reject,
    Throw,
};

// Converts the options, then locks both streams and starts ReadableStreamPipeTo, returning its promise.
JSC::EncodedJSValue startReadablePipeTo(JSC::JSGlobalObject*, JSC::ThrowScope&, JSColloReadableStream*,
    JSColloWritableStream*, JSC::JSValue options, PipeToErrors);

class JSColloPipeToState final : public JSC::JSNonFinalObject {
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

    static JSColloPipeToState* create(JSC::VM&, JSC::JSGlobalObject*, JSColloReadableStream* source,
        JSColloWritableStream* destination, JSColloReadableStreamDefaultReader*, JSColloWritableStreamDefaultWriter*);

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    JSC::JSValue promise() const { return m_promise.get(); }
    void setOptions(bool prevent_close, bool prevent_abort, bool prevent_cancel)
    {
        m_prevent_close = prevent_close;
        m_prevent_abort = prevent_abort;
        m_prevent_cancel = prevent_cancel;
    }
    void setSignal(JSC::VM& vm, JSColloAbortSignal* signal) { m_signal.set(vm, this, signal); }
    // Applies the shutdown conditions that already hold, then starts piping. The caller has already handled a signal
    // that was aborted.
    void start(JSC::JSGlobalObject*);
    // Applies the shutdown conditions that hold, then reads when the destination has room. The reactions to the
    // reader's closed promise and the writer's closed and ready promises call it.
    void advance(JSC::JSGlobalObject*);
    void readFulfilled(JSC::JSGlobalObject*, JSC::JSValue result);
    void readRejected(JSC::JSGlobalObject*, JSC::JSValue reason);
    // A write the pipe issued settled either way. A rejection needs nothing of its own: while the pipe runs, a write
    // fails only on a destination that has errored or is erroring, which the writer's closed promise reports.
    void writeSettled(JSC::JSGlobalObject*);
    // One of the shutdown action's promises fulfilled, or one rejected.
    void shutdownActionSettled(JSC::JSGlobalObject*);
    void shutdownActionRejected(JSC::JSGlobalObject*, JSC::JSValue reason);
    // The signal aborted: shuts down with its reason, aborting a writable destination and canceling a readable source
    // unless the options prevent it.
    void abortFromSignal(JSC::JSGlobalObject*, JSC::JSValue reason);
    // The abort algorithm the pipe adds to its signal, with the pipe state as `context`. Runs in the pipe's realm.
    static void signalAborted(JSC::JSObject* context);
    // Undoes a start that failed before the pipe ran: releases both locks and forgets the promise.
    void abandonStartFailure(JSC::JSGlobalObject*);

private:
    enum class Phase : uint8_t {
        // Reading from the source and writing to the destination.
        Piping,
        // A shutdown began and waits until the chunks already read are written.
        FinishingWrites,
        // A shutdown waits for its action's promises.
        RunningAction,
        Settled,
    };

    // What a shutdown does once the chunks already read are written, before the pipe settles.
    enum class ShutdownAction : uint8_t {
        None,
        AbortDestination,
        CancelSource,
        // WritableStreamDefaultWriterCloseWithErrorPropagation.
        CloseDestination,
        // The signal's abort algorithm: aborts the destination while it is writable and cancels the source while it is
        // readable, each unless its option prevents it.
        AbortSignal,
    };

    JSColloPipeToState(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    void finishCreation(JSC::VM&, JSC::JSGlobalObject*, JSColloReadableStream*, JSColloWritableStream*,
        JSColloReadableStreamDefaultReader*, JSColloWritableStreamDefaultWriter*);
    // Releases the writer, then the reader, detaches the abort algorithm and drops every edge but the promise.
    void finalize(JSC::JSGlobalObject*);
    void settle(JSC::JSGlobalObject*, JSC::JSValue value, bool is_rejection);
    void detachSignal();
    // The four conditions in the standard's order. Returns true once the pipe is no longer piping.
    bool applyShutdownConditions(JSC::JSGlobalObject*);
    void shutdownForSourceError(JSC::JSGlobalObject*, JSC::JSValue error);
    void shutdownForDestinationError(JSC::JSGlobalObject*, JSC::JSValue error);
    void shutdownForSourceClose(JSC::JSGlobalObject*);
    void shutdownForDestinationClose(JSC::JSGlobalObject*);
    // "Shutdown with an action", or "shutdown" when `action` is None. An empty `error` means the pipe resolves.
    void beginShutdown(JSC::JSGlobalObject*, ShutdownAction, JSC::JSValue error);
    void continueShutdown(JSC::JSGlobalObject*);
    void runShutdownAction(JSC::JSGlobalObject*);
    void finishShutdown(JSC::JSGlobalObject*);
    void awaitReady(JSC::JSGlobalObject*);
    void writeChunk(JSC::JSGlobalObject*, JSC::JSValue chunk);
    // After a read or a write settled: pipes on, or lets a shutdown that waits for writes go on.
    void resume(JSC::JSGlobalObject*);

    // Set until the pipe settles, so every phase but Settled uses them without a check.
    JSC::WriteBarrier<JSColloReadableStream> m_source;
    JSC::WriteBarrier<JSColloWritableStream> m_destination;
    JSC::WriteBarrier<JSColloReadableStreamDefaultReader> m_reader;
    JSC::WriteBarrier<JSColloWritableStreamDefaultWriter> m_writer;
    // The promise pipeTo returned, empty once the pipe settles.
    JSC::WriteBarrier<JSC::JSPromise> m_promise;
    JSC::WriteBarrier<JSColloAbortSignal> m_signal;
    // The pipe's one outstanding read, until its reaction runs. Once it has settled it holds a chunk already taken
    // from the source, or the source's end.
    JSC::WriteBarrier<JSC::JSPromise> m_read_promise;
    // The writer's ready promise the pipe last reacted to, so that each pending one gets one reaction.
    JSC::WriteBarrier<JSC::JSPromise> m_awaited_ready;
    // What the pipe rejects with when its shutdown has an error and no action rejects.
    JSC::WriteBarrier<JSC::Unknown> m_shutdown_error;
    unsigned m_writes_in_flight { 0 };
    // The action promises not yet fulfilled.
    unsigned m_shutdown_pending { 0 };
    Phase m_phase { Phase::Piping };
    ShutdownAction m_shutdown_action { ShutdownAction::None };
    bool m_prevent_close { false };
    bool m_prevent_abort { false };
    bool m_prevent_cancel { false };
    bool m_shutdown_has_error { false };
};

} // namespace Collo::HostFunctions
