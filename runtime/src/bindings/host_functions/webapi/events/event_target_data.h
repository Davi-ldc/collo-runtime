// Listener storage that every event target cell embeds by value, and the handle through which event_target.cpp
// registers and dispatches listeners for all of them. JSColloAbortSignal::setOnAbort and fetch's abort listener in
// server/fetch/request.cpp add records through appendListener too. VM thread only, except visit.
//
// The records are a Collo::CellEdgeList owned by the cell that embeds this storage (jsc/runtime/cell_edges.h), which
// runs the lock and barrier protocol the concurrent marker needs; that cell's visitChildren calls visit. Records stay
// in ascending `order`, and while a dispatch on the target is in progress the list neither shrinks nor restarts its
// orders, because the dispatch matches its snapshot to live records by order: a removal during a dispatch only marks
// the record, and the next idle compaction drops it.

#pragma once

#include "jsc/runtime/cell_edges.h"

#include <JavaScriptCore/JSCJSValue.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/WriteBarrier.h>
#include <wtf/text/WTFString.h>

namespace Collo::HostFunctions {

// Most active listeners one target may hold; addEventListener beyond it throws a QuotaExceededError DOMException.
constexpr unsigned WebApiEventTargetMaxListeners = 1u << 14;

// addEventListener's options after conversion. `signal` is empty or an AbortSignal.
struct WebApiEventListenerOptions {
    bool capture { false };
    bool once { false };
    bool passive { false };
    JSC::JSValue signal;
};

// One registered listener. Its WriteBarrier fields name the target's listener owner cell as their owner.
struct WebApiEventListenerRecord {
    WTF::String type;
    JSC::WriteBarrier<JSC::Unknown> callback;
    // The AbortSignal from the `signal` option; empty unless `has_signal` is set.
    JSC::WriteBarrier<JSC::Unknown> signal;
    // From allocateListenerOrder: unique within the target and ascending along the list.
    uint64_t order { 0 };
    bool capture { false };
    bool once { false };
    bool passive { false };
    bool has_signal { false };
    // Set on removal; the record leaves the list at the next compaction with no dispatch in progress.
    bool removed { false };
    // The listener of an event handler attribute (AbortSignal's onabort). addEventListener and removeEventListener
    // never match it; only replacing the attribute removes it.
    bool attribute_handler { false };

    template <typename Visitor> void visitEdges(Visitor& visitor) const
    {
        visitor.append(callback);
        visitor.append(signal);
    }
};

template <typename Visitor> inline void appendWebApiJSValue(Visitor& visitor, JSC::JSValue value)
{
    if (value.isCell())
        visitor.appendUnbarriered(value.asCell());
}

template <typename Visitor>
inline void appendWebApiUnknown(Visitor& visitor, const JSC::WriteBarrier<JSC::Unknown>& slot)
{
    appendWebApiJSValue(visitor, slot.get());
}

class WebApiEventTargetData {
public:
    using Listeners = Collo::CellEdgeList<WebApiEventListenerRecord>;

    // Every record, removed ones included, in ascending order. Valid until the next change to the list or call into
    // JavaScript.
    const Listeners& listeners() const { return m_listeners; }

    // The order for a new listener or an attribute handler's slot. Orders restart at 1 only when clearListeners
    // empties the list with no dispatch in progress.
    uint64_t allocateListenerOrder() { return m_next_listener_order++; }

    enum class AppendResult : uint8_t {
        Appended,
        LimitReached,
        OutOfMemory,
    };
    // The one way a record joins the list: refuses it once WebApiEventTargetMaxListeners records are active, and
    // otherwise appends and counts it. `record` has its WriteBarrier fields set without barriers; `owner` is the cell
    // that embeds this storage.
    AppendResult appendListener(JSC::VM& vm, const JSC::JSCell* owner, WebApiEventListenerRecord&& record)
    {
        if (m_active_listener_count >= WebApiEventTargetMaxListeners)
            return AppendResult::LimitReached;
        if (!m_listeners.tryAppend(vm, owner, WTF::move(record)))
            return AppendResult::OutOfMemory;
        m_active_listener_count++;
        return AppendResult::Appended;
    }

    // Records appended and not yet marked removed, counted incrementally so the listener cap costs O(1).
    unsigned activeListenerCount() const { return m_active_listener_count; }

    // Marks the record removed and uncounts it, once. Moves nothing.
    void markRemoved(size_t index)
    {
        if (index >= m_listeners.size())
            return;
        auto& record = m_listeners.at(index);
        if (record.removed)
            return;
        record.removed = true;
        m_has_removed = true;
        ASSERT(m_active_listener_count);
        m_active_listener_count--;
    }

    // Drops removed records unless a dispatch is in progress.
    void compactRemovedIfIdle(const JSC::JSCell* owner)
    {
        if (m_dispatch_depth || !m_has_removed)
            return;
        m_listeners.removeIf(owner, [](const WebApiEventListenerRecord& record) { return record.removed; });
        m_has_removed = false;
        ASSERT(m_active_listener_count == m_listeners.size());
    }

    // Removes every listener. During a dispatch on this target it only marks the records removed and they leave at
    // the next idle compaction, so MessagePort's close and transfer can run from a listener. Otherwise it empties the
    // list and restarts orders at 1.
    void clearListeners(const JSC::JSCell* owner)
    {
        if (m_dispatch_depth) {
            for (auto& record : m_listeners) {
                if (!record.removed) {
                    record.removed = true;
                    m_has_removed = true;
                }
            }
            m_active_listener_count = 0;
            return;
        }
        m_listeners.clear(owner);
        m_next_listener_order = 1;
        m_has_removed = false;
        m_active_listener_count = 0;
    }

    // Bracket a dispatch on this target.
    void enterDispatch() { m_dispatch_depth++; }
    void leaveDispatch(const JSC::JSCell* owner)
    {
        ASSERT(m_dispatch_depth);
        m_dispatch_depth--;
        compactRemovedIfIdle(owner);
    }

    // Called by the owner cell's visitChildren.
    template <typename Visitor> void visit(const JSC::JSCell* owner, Visitor& visitor) const
    {
        m_listeners.visit(owner, visitor);
    }

private:
    Listeners m_listeners;
    uint64_t m_next_listener_order { 1 };
    unsigned m_dispatch_depth { 0 };
    unsigned m_active_listener_count { 0 };
    bool m_has_removed { false };
};

// A borrowed view of one event target. It points at cells and into a cell's storage, so the caller keeps the target
// reachable while it uses the handle, as a call frame does for `this`.
struct WebApiEventTargetHandle {
    // The target script sees: event.target, and `this` for function listeners.
    JSC::JSObject* object { nullptr };
    // The cell that embeds `data`: listener barriers name it as their owner, and its cellLock() guards the list. It
    // differs from `object` only for the global object, whose listeners live in a separate EventTarget cell. Null
    // means `object`.
    JSC::JSObject* listener_owner { nullptr };
    WebApiEventTargetData* data { nullptr };
    // An event handler attribute dispatched among the listeners (MessagePort's onmessage). It runs only for events of
    // `attribute_event_type` when that is set, at `attribute_order`: an order from allocateListenerOrder places it
    // among the listeners, and WebApiEventAttributeHandlerBeforeListeners places it before all of them.
    JSC::JSValue attribute_handler;
    WTF::String attribute_event_type;
    uint64_t attribute_order { 0 };

    JSC::JSObject* owner() const { return listener_owner ? listener_owner : object; }
};

} // namespace Collo::HostFunctions
