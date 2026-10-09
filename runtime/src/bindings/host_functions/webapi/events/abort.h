// AbortSignal's cell and the abort machinery other bridge code relies on: dependent signals (AbortSignal.any, a fetch
// Request's signal), abort algorithms (stream piping), and the cleanup records that remove listeners added with a
// `signal` option. VM thread only.
//
// A dependent signal holds its sources through WriteBarriers that visitChildren visits, while a source holds its
// dependents through JSC::Weak entries that visitChildren never reads, so a source never keeps a dependent alive. The
// lists the concurrent marker walks (cleanup records, abort algorithms, sources and the event target's listeners)
// change under cellLock() whenever their buffer can move or be freed; the dependent list is not walked and takes no
// lock.

#pragma once

#include "host_functions/webapi/events/event.h"

#include <JavaScriptCore/JSDestructibleObject.h>
#include <JavaScriptCore/Strong.h>
#include <JavaScriptCore/Weak.h>
#include <wtf/FastMalloc.h>
#include <wtf/NeverDestroyed.h>
#include <wtf/Vector.h>

#include <memory>

namespace Collo::HostFunctions {

class JSColloAbortSignal final : public JSC::JSDestructibleObject {
    using Base = JSC::JSDestructibleObject;

public:
    template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
    {
        return &vm.destructibleObjectSpace();
    }

    static JSC::Structure* createStructure(JSC::VM&, JSC::JSGlobalObject*, JSC::JSValue prototype);
    // With `aborted`, the signal is born aborted with `reason`, or with an AbortError DOMException when `reason` is
    // undefined, and no abort event fires.
    static JSColloAbortSignal* create(JSC::VM&, Collo::GlobalObject*, JSC::Structure*, bool aborted = false,
        JSC::JSValue reason = JSC::jsUndefined());
    static void destroy(JSC::JSCell*);

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    WebApiEventTargetData& eventTargetData() { return m_event_target; }
    bool aborted() const { return m_aborted; }
    JSC::JSValue reason() const { return m_reason.get(); }
    JSC::JSValue onabort() const { return m_onabort.get(); }
    using SourceSignalVector = WTF::Vector<JSC::WriteBarrier<JSColloAbortSignal>>;
    // This signal's sources, empty unless it is a dependent signal that has not aborted. A signal with sources is
    // never linked as a source itself, since callers link its sources instead, so the list never chains.
    const SourceSignalVector& sourceSignals() const
    {
        // A signal without sources has no vector, so read-only callers get a shared empty one.
        // FIXME: this function-local static is first touched inside a worker, which costs the worker a private page;
        // the bridge allows only statics the zygote initializes before the first fork.
        static WTF::NeverDestroyed<SourceSignalVector> empty;
        return m_source_signals ? *m_source_signals : empty.get();
    }

    // Replaces the onabort handler; a value that is not callable clears it. Returns false, with an OutOfMemoryError
    // thrown into the scope, when the handler's listener record cannot be stored.
    bool setOnAbort(JSC::VM&, JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue);
    // Aborts this signal and its dependents (DOM standard, signal abort); a no-op on a signal already aborted. An
    // undefined `reason` becomes an AbortError DOMException. An exception thrown while one signal runs its abort steps
    // does not stop the others; a termination stops the walk and stays pending for the caller to check.
    void signalAbort(JSC::VM&, JSC::JSGlobalObject*, JSC::JSValue reason);
    // Records that the listener (target, type, callback, capture) was added with this signal as its `signal` option,
    // so the abort removes it. Returns false on allocation failure; the caller then removes the listener and throws.
    bool addEventTargetCleanup(JSC::VM&, JSC::JSObject* target, WTF::String type, JSC::JSValue callback, bool capture);
    // Drops the record for a listener that was removed some other way.
    void removeEventTargetCleanup(JSC::JSObject* target, const WTF::String& type, JSC::JSValue callback, bool capture);
    // Drops every record for `target`, whose listeners were all cleared.
    void removeEventTargetCleanupsForTarget(JSC::JSObject* target);
    // Adds an abort algorithm: `callback`, which must be callable, runs with the signal as `this` and no arguments
    // before the abort event fires. A callback already present is not added again. Returns false, with an
    // OutOfMemoryError thrown into the scope, on allocation failure.
    bool addInternalAbortAlgorithm(JSC::VM&, JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue callback);
    // Removes `callback`; while the algorithms are running it is only marked, and skipped.
    void removeInternalAbortAlgorithm(JSC::JSValue callback);
    // Runs the abort algorithms present when the run starts, in insertion order, then drops the list. An exception
    // from one is cleared and the next runs; a termination ends the run and stays pending.
    void runInternalAbortAlgorithms(JSC::VM&, JSC::JSGlobalObject*);
    // Links `signal` as a dependent of this source through a JSC::Weak. Returns false on allocation failure. Add this
    // edge before the matching addSourceSignal call: if that one fails, the caller drops the dependent and the weak
    // edge clears itself once the dependent is collected.
    bool addDependentSignal(JSC::VM&, JSColloAbortSignal*);
    // Links `signal` as a source of this dependent signal, held strongly. Returns false on allocation failure.
    bool addSourceSignal(JSC::VM&, JSColloAbortSignal*);

    // The id of AbortSignal.timeout()'s pending timer, or 0 for none: the scheduler numbers timers from 1. The timer
    // callback clears the id before it aborts the signal.
    void setTimeoutTimerId(uint64_t timer_id) { m_timeout_timer_id = timer_id; }
    uint64_t timeoutTimerId() const { return m_timeout_timer_id; }
    void clearTimeoutTimerId() { m_timeout_timer_id = 0; }

private:
    // A listener added with this signal as its `signal` option, removed from `target` when the signal aborts.
    struct EventTargetCleanup {
        JSC::WriteBarrier<JSC::Unknown> target;
        WTF::String type;
        JSC::WriteBarrier<JSC::Unknown> callback;
        bool capture { false };
    };

    struct InternalAbortAlgorithm {
        JSC::WriteBarrier<JSC::Unknown> callback;
        // Marks a removal made while the algorithms run, since the run indexes the list.
        bool removed { false };
    };

    JSColloAbortSignal(JSC::VM&, JSC::Structure*, bool aborted);
    ~JSColloAbortSignal() = default;

    void finishCreation(JSC::VM&, Collo::GlobalObject*, JSC::JSValue reason);
    JSC::JSValue normalizedAbortReason(JSC::JSGlobalObject*, JSC::JSValue reason);
    // Marks this signal and, recursively, its live dependents aborted, and appends each to `dispatch_targets` in the
    // order their abort steps run. Runs no script.
    void collectAbortSteps(JSC::VM&, JSC::JSGlobalObject*, JSC::JSValue reason,
        WTF::Vector<JSC::Strong<JSC::Unknown>, 8>& dispatch_targets);
    void removeSourceSignal(JSColloAbortSignal*);
    void removeDependentSignal(JSColloAbortSignal*);
    void compactDependentSignals();

    using CleanupVector = WTF::Vector<EventTargetCleanup>;
    using AlgorithmVector = WTF::Vector<InternalAbortAlgorithm>;
    using DependentVector = WTF::Vector<JSC::Weak<JSColloAbortSignal>>;

    // Each list stays null until its first mutation, so a signal that never uses one pays a null pointer instead of a
    // Vector header; most signals never use any of the four. Returns null when allocating the header fails, and a
    // mutating caller must report that as out of memory.
    template <typename Vector> static Vector* ensureVector(std::unique_ptr<Vector>& slot)
    {
        if (!slot) {
            void* storage = nullptr;
            if (!WTF::tryFastMalloc(sizeof(Vector)).getValue(storage))
                return nullptr;
            slot.reset(new (NotNull, storage) Vector());
        }
        return slot.get();
    }
    CleanupVector* ensureCleanupRecords() { return ensureVector(m_cleanup_records); }
    AlgorithmVector* ensureAbortAlgorithms() { return ensureVector(m_abort_algorithms); }
    SourceSignalVector* ensureSourceSignals() { return ensureVector(m_source_signals); }
    DependentVector* ensureDependentSignals() { return ensureVector(m_dependent_signals); }

    WebApiEventTargetData m_event_target;
    JSC::WriteBarrier<JSC::Unknown> m_reason;
    JSC::WriteBarrier<JSC::Unknown> m_onabort;
    std::unique_ptr<CleanupVector> m_cleanup_records;
    std::unique_ptr<AlgorithmVector> m_abort_algorithms;
    std::unique_ptr<SourceSignalVector> m_source_signals;
    std::unique_ptr<DependentVector> m_dependent_signals;
    uint64_t m_timeout_timer_id { 0 };
    bool m_aborted { false };
    bool m_dispatching_internal_abort_algorithms { false };
};

JSColloAbortSignal* webApiAbortSignalFromValue(JSC::JSValue);
void installWebApiAbort(Collo::GlobalObject*, JSC::VM&);

} // namespace Collo::HostFunctions
