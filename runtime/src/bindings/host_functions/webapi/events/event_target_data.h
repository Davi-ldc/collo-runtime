// Listener storage that every event target cell embeds by value, and the handle through which event_target.cpp
// registers and dispatches listeners for all of them. Fetch's abort listener in server/fetch/request.cpp adds its
// record through appendListener too. VM thread only, except visit.
//
// The records are a Collo::CellEdgeList owned by the cell that embeds this storage (jsc/runtime/cell_edges.h), which
// runs the lock and barrier protocol the concurrent marker needs; that cell's visitChildren calls visit. Records stay
// in ascending `order`, and while a dispatch on the target is in progress the list neither shrinks nor restarts its
// orders, because the dispatch matches its snapshot to live records by order: a removal during a dispatch only marks
// the record, and the next idle compaction drops it.
//
// An event handler attribute (onabort, onmessage, the global object's onerror) is a record like any listener, flagged
// `attribute_handler`, as HTML's event handlers are: its first non-null value appends it, a later value replaces its
// callback in place so it keeps its position, and null removes it. At most one live handler record exists per type.

#pragma once

#include "host_functions/webapi/limits.h"
#include "jsc/runtime/cell_edges.h"

#include <JavaScriptCore/JSCJSValue.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/WriteBarrier.h>
#include <wtf/text/WTFString.h>

#include <optional>

namespace Collo::HostFunctions {

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
    // The record of an event handler attribute, whose `callback` is the handler's current value. addEventListener and
    // removeEventListener never match it; only setting the attribute changes or removes it.
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

    // The order for a new record. Orders restart at 1 only when clearListeners empties the list with no dispatch in
    // progress.
    uint64_t allocateListenerOrder() { return m_next_listener_order++; }

    enum class AppendResult : uint8_t {
        Appended,
        LimitReached,
        OutOfMemory,
    };
    // The one way a record joins the list: refuses it once WebApiEventTargetListenersMax records are active, and
    // otherwise appends and counts it. `record` has its WriteBarrier fields set without barriers; `owner` is the cell
    // that embeds this storage.
    AppendResult appendListener(JSC::VM& vm, const JSC::JSCell* owner, WebApiEventListenerRecord&& record)
    {
        if (m_active_listener_count >= WebApiEventTargetListenersMax)
            return AppendResult::LimitReached;
        if (!m_listeners.tryAppend(vm, owner, WTF::move(record)))
            return AppendResult::OutOfMemory;
        m_active_listener_count++;
        return AppendResult::Appended;
    }

    // The index of the live event handler record for `type`, if the attribute has a value.
    std::optional<size_t> findEventHandler(const WTF::String& type) const
    {
        for (size_t index = 0; index < m_listeners.size(); index++) {
            const auto& record = m_listeners.at(index);
            if (record.attribute_handler && !record.removed && record.type == type)
                return index;
        }
        return std::nullopt;
    }

    // Replaces the callback of the handler record at `index`, which findEventHandler returned, in place: the record
    // keeps its order, so the handler keeps its position among the listeners.
    void replaceEventHandler(JSC::VM& vm, const JSC::JSCell* owner, size_t index, JSC::JSValue handler)
    {
        auto& record = m_listeners.at(index);
        ASSERT(record.attribute_handler);
        record.callback.set(vm, owner, handler);
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

    // HTML's error reporting mode, which only the global object's target uses: set while that global dispatches the
    // error event reporting an exception, so an exception thrown during it is not reported again
    // (reportWebApiException in event_target.cpp).
    bool reportingError() const { return m_reporting_error; }
    void setReportingError(bool reporting) { m_reporting_error = reporting; }

private:
    Listeners m_listeners;
    uint64_t m_next_listener_order { 1 };
    unsigned m_dispatch_depth { 0 };
    unsigned m_active_listener_count { 0 };
    bool m_has_removed { false };
    bool m_reporting_error { false };
};

// A borrowed view of one event target. It points at cells and into a cell's storage, so the caller keeps the target
// reachable while it uses the handle, as a call frame does for `this`.
struct WebApiEventTargetHandle {
    // The target script sees: event.target, and `this` for listeners and event handlers.
    JSC::JSObject* object { nullptr };
    // The cell that embeds `data`: listener barriers name it as their owner, and its cellLock() guards the list. It
    // differs from `object` only for the global object, whose listeners live in a separate EventTarget cell. Null
    // means `object`.
    JSC::JSObject* listener_owner { nullptr };
    WebApiEventTargetData* data { nullptr };

    JSC::JSObject* owner() const { return listener_owner ? listener_owner : object; }
};

} // namespace Collo::HostFunctions
