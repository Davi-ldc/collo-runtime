// AbortSignal's cell and the abort machinery other bridge code relies on: dependent signals (AbortSignal.any, a fetch
// Request's signal), abort algorithms (stream piping), and the cleanup records that remove listeners added with a
// `signal` option. VM thread only, except visitChildren.
//
// A dependent signal holds its sources through WriteBarriers that visitChildren visits, while a source holds its
// dependents through JSC::Weak entries that visitChildren never reads, so a source never keeps a dependent alive. The
// lists the concurrent marker walks (cleanup records, abort algorithms, sources and the event target's listeners,
// onabort's record among them) are Collo::CellEdgeList, which owns their lock and barrier protocol
// (jsc/runtime/cell_edges.h); the dependent list is not walked and takes no lock.

#pragma once

#include "host_functions/webapi/events/event.h"
#include "jsc/runtime/cell_edges.h"

#include <JavaScriptCore/JSDestructibleObject.h>
#include <JavaScriptCore/MarkedVector.h>
#include <JavaScriptCore/Weak.h>
#include <wtf/FastMalloc.h>
#include <wtf/Vector.h>

#include <memory>
#include <span>

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

    // One source of a dependent signal.
    struct SourceSignal {
        JSC::WriteBarrier<JSColloAbortSignal> signal;

        template <typename Visitor> void visitEdges(Visitor& visitor) const { visitor.append(signal); }
    };
    using SourceSignals = Collo::CellEdgeList<SourceSignal>;

    WebApiEventTargetData& eventTargetData() { return m_event_target; }
    bool aborted() const { return m_aborted; }
    JSC::JSValue reason() const { return m_reason.get(); }
    // This signal's sources, empty unless it is a dependent signal that has not aborted. A signal with sources is
    // never linked as a source itself, since callers link its sources instead, so the list never chains.
    const SourceSignals& sourceSignals() const { return m_source_signals; }

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
    // An abort algorithm (DOM standard): native steps that run with the context they were added with, before the abort
    // event fires. They run in the context's realm, which they find through context->globalObject(), and may run
    // script.
    using AbortAlgorithm = void (*)(JSC::JSObject* context);
    // Adds `algorithm` with `context`, which the signal keeps alive until the algorithm runs or is removed. A pair
    // already present is not added again. Returns false, with an OutOfMemoryError thrown into the scope, on allocation
    // failure.
    bool addInternalAbortAlgorithm(
        JSC::VM&, JSC::JSGlobalObject*, JSC::ThrowScope&, AbortAlgorithm, JSC::JSObject* context);
    // Removes the pair added with exactly this algorithm and context. During a run it does nothing, since the run calls
    // every algorithm present when it started and drops the list afterwards; an algorithm removed by another during
    // the run therefore still runs once, so its steps check their own state.
    void removeInternalAbortAlgorithm(AbortAlgorithm, JSC::JSObject* context);
    // Runs the abort algorithms present when the run starts, once each in insertion order, then drops the list. One
    // added during the run never runs, as the DOM standard ignores an algorithm added to an aborted signal. An
    // exception from one is cleared and the next runs; a termination ends the run and stays pending.
    void runInternalAbortAlgorithms(JSC::VM&);
    // Links `signal` as a dependent of this source through a JSC::Weak. Returns false on allocation failure. Add this
    // edge before the matching addSourceSignal call: if that one fails, the caller drops the dependent and the weak
    // edge clears itself once the dependent is collected.
    bool addDependentSignal(JSC::VM&, JSColloAbortSignal*);
    // Links `signal` as a source of this dependent signal, held strongly. Returns false on allocation failure.
    bool addSourceSignal(JSC::VM&, JSColloAbortSignal*);
    bool hasSourceSignal(const JSColloAbortSignal*) const;

private:
    // A listener added with this signal as its `signal` option, removed from `target` when the signal aborts.
    struct EventTargetCleanup {
        JSC::WriteBarrier<JSC::Unknown> target;
        WTF::String type;
        JSC::WriteBarrier<JSC::Unknown> callback;
        bool capture { false };

        template <typename Visitor> void visitEdges(Visitor& visitor) const
        {
            visitor.append(target);
            visitor.append(callback);
        }
    };

    struct InternalAbortAlgorithm {
        AbortAlgorithm algorithm { nullptr };
        JSC::WriteBarrier<JSC::JSObject> context;

        template <typename Visitor> void visitEdges(Visitor& visitor) const { visitor.append(context); }
    };

    JSColloAbortSignal(JSC::VM&, JSC::Structure*, bool aborted);
    ~JSColloAbortSignal() = default;

    void finishCreation(JSC::VM&, Collo::GlobalObject*, JSC::JSValue reason);
    JSC::JSValue normalizedAbortReason(JSC::JSGlobalObject*, JSC::JSValue reason);
    // Marks this signal and, recursively, its live dependents aborted, and appends each to `dispatch_targets` in the
    // order their abort steps run. Runs no script.
    void collectAbortSteps(
        JSC::VM&, JSC::JSGlobalObject*, JSC::JSValue reason, JSC::MarkedVector<JSColloAbortSignal*>& dispatch_targets);
    void removeSourceSignal(JSColloAbortSignal*);
    void removeDependentSignal(JSColloAbortSignal*);
    void compactDependentSignals();

    using DependentVector = WTF::Vector<JSC::Weak<JSColloAbortSignal>>;

    // The dependent list stays null until its first use, so a signal that never becomes a source pays a null pointer
    // instead of a Vector header. Returns null when allocating the header fails, which a mutating caller reports as
    // out of memory.
    DependentVector* ensureDependentSignals();

    WebApiEventTargetData m_event_target;
    JSC::WriteBarrier<JSC::Unknown> m_reason;
    Collo::CellEdgeList<EventTargetCleanup> m_cleanup_records;
    Collo::CellEdgeList<InternalAbortAlgorithm> m_abort_algorithms;
    SourceSignals m_source_signals;
    std::unique_ptr<DependentVector> m_dependent_signals;
    bool m_aborted { false };
    bool m_dispatching_internal_abort_algorithms { false };
};

JSColloAbortSignal* webApiAbortSignalFromValue(JSC::JSValue);
// DOM standard, create a dependent abort signal: a new signal of the caller's realm that aborts when any of `inputs`
// aborts. It is born aborted with the first aborted input's reason; otherwise a dependent input contributes its
// sources instead of itself, and each actual source is linked once even when the inputs repeat a signal or share a
// source. The caller keeps `inputs` rooted. Returns null with an OutOfMemoryError thrown into `scope` when a link
// cannot be stored.
JSColloAbortSignal* createDependentAbortSignal(
    JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<JSColloAbortSignal* const> inputs);
void installWebApiAbort(Collo::GlobalObject*, JSC::VM&);

} // namespace Collo::HostFunctions
