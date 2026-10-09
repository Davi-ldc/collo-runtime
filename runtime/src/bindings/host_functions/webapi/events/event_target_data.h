// Listener storage that every event target cell embeds by value, and the handle through which event_target.cpp
// registers and dispatches listeners for all of them. JSColloAbortSignal::setOnAbort and fetch's abort listener in
// server/fetch/request.cpp append records directly and must follow the same rules. VM thread only.
//
// The concurrent marker reads the listener records: the owning cell's visitChildren calls
// WebApiEventTargetData::visitChildren while holding the cell's cellLock(), and every mutation that can move or free
// the listener buffer (an append, a compaction, a clear) holds the same lock. Flag changes such as markRemoved move
// nothing and need no lock. Records stay in ascending `order`, and while a dispatch on the target is in progress the
// vector neither shrinks nor restarts its orders, because the dispatch matches its snapshot to live records by order.

#pragma once

#include <JavaScriptCore/JSCJSValue.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/WriteBarrier.h>
#include <wtf/Vector.h>
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

// One registered listener. `callback` and `signal` are written with the barrier of the target's listener owner cell,
// which marks them through WebApiEventTargetData::visitChildren.
struct WebApiEventListenerRecord {
    WTF::String type;
    JSC::WriteBarrier<JSC::Unknown> callback;
    // The AbortSignal from the `signal` option, marked only when `has_signal` is set.
    JSC::WriteBarrier<JSC::Unknown> signal;
    // From allocateListenerOrder: unique within the target and ascending along the vector.
    uint64_t order { 0 };
    bool capture { false };
    bool once { false };
    bool passive { false };
    bool has_signal { false };
    // Set on removal; the record leaves the vector at the next compaction with no dispatch in progress.
    bool removed { false };
    // The listener of an event handler attribute (AbortSignal's onabort). addEventListener and removeEventListener
    // never match it; only replacing the attribute removes it.
    bool attribute_handler { false };
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
    WTF::Vector<WebApiEventListenerRecord>& listeners() { return m_listeners; }

    // The order for a new listener or an attribute handler's slot. Orders restart at 1 only when clearListeners
    // empties the vector with no dispatch in progress.
    uint64_t allocateListenerOrder() { return m_next_listener_order++; }

    // Counts the live record the caller just appended. Every append of a live record must call it within the same
    // cellLock() hold as the append, or activeListenerCount drifts from the vector.
    void noteListenerAppended() { m_active_listener_count++; }

    // Removes every listener; the caller holds the owner's cellLock(). During a dispatch on this target it only marks
    // the records removed and they leave at the next idle compaction, so MessagePort's close and transfer can run from
    // a listener. Otherwise it empties the vector and restarts orders at 1.
    void clearListeners()
    {
        if (m_dispatch_depth) {
            for (auto& listener : m_listeners) {
                if (!listener.removed) {
                    listener.removed = true;
                    m_has_removed = true;
                }
            }
            m_active_listener_count = 0;
            return;
        }
        m_listeners.clear();
        m_next_listener_order = 1;
        m_has_removed = false;
        m_active_listener_count = 0;
    }

    // Records appended and not yet marked removed, counted incrementally so the listener cap costs O(1).
    unsigned activeListenerCount() const { return m_active_listener_count; }

    // Moves nothing, so it needs no lock.
    void markRemoved(unsigned index)
    {
        if (index < m_listeners.size() && !m_listeners[index].removed) {
            m_listeners[index].removed = true;
            m_has_removed = true;
            ASSERT(m_active_listener_count);
            m_active_listener_count--;
        }
    }

    // Drops removed records unless a dispatch is in progress. It moves records, so the caller holds the owner's
    // cellLock().
    void compactRemovedIfIdle()
    {
        if (m_dispatch_depth || !m_has_removed)
            return;

        unsigned write = 0;
        for (unsigned read = 0; read < m_listeners.size(); read++) {
            if (m_listeners[read].removed)
                continue;
            if (write != read)
                m_listeners[write] = WTF::move(m_listeners[read]);
            write++;
        }
        m_listeners.shrink(write);
        m_has_removed = false;
        ASSERT(m_active_listener_count == write);
    }

    // Bracket a dispatch on this target. leaveDispatch may compact, so it runs under the owner's cellLock().
    void enterDispatch() { m_dispatch_depth++; }
    void leaveDispatch()
    {
        ASSERT(m_dispatch_depth);
        m_dispatch_depth--;
        compactRemovedIfIdle();
    }

    // Called by the owning cell's visitChildren while it holds that cell's cellLock().
    template <typename Visitor> void visitChildren(Visitor& visitor)
    {
        for (auto& listener : m_listeners) {
            appendWebApiUnknown(visitor, listener.callback);
            if (listener.has_signal)
                appendWebApiUnknown(visitor, listener.signal);
        }
    }

private:
    WTF::Vector<WebApiEventListenerRecord> m_listeners;
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
    // The cell that owns `data`: listener barriers name it as their owner, and its cellLock() guards the buffer. It
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
};

} // namespace Collo::HostFunctions
