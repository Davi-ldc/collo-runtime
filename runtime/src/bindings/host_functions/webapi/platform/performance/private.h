// The cells behind `performance`, shared by the files under `performance/`: Performance, PerformanceEntry with its
// Mark and Measure subclasses, PerformanceObserver and PerformanceObserverEntryList. They run on the VM thread, except
// visitChildren, which the concurrent marker runs. Each realm has one Performance cell, which installation stores in
// the realm's Web API cache (`realmPerformance`) and on its global `performance` property; it holds the structures of
// the cells it creates, the entry buffer and the registered observers. That timeline belongs to the realm rather than
// to a request: entries, observers and the time origin persist across requests, and requests co-scheduled on that
// realm share them, so nothing may reset them when a request ends. Another realm of the same VM has a timeline of its
// own. The timeline records User Timing only: marks and measures.
//
// The time origin is fixed by the first reading of the clock (now(), timeOrigin, toJSON(), or a mark or measure), not
// at installation: realms are installed in the zygote, and every worker forked from it must start its own timeline.
//
// The entry buffer, the observer list and each observer's pending entries are Collo::CellEdgeList, which owns the
// lock and barrier protocol the concurrent marker needs (jsc/runtime/cell_edges.h). A list of entries collected to
// build an array is a MarkedVector, since building the array allocates.

#pragma once

#include "host_functions/webapi/platform/performance.h"

#include "host_functions/runtime/bridge.h"
#include "host_functions/webapi/limits.h"
#include "jsc/runtime/cell_edges.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSDestructibleObject.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/MarkedVector.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <wtf/MonotonicTime.h>
#include <wtf/Vector.h>
#include <wtf/WallTime.h>
#include <wtf/text/WTFString.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <optional>
#include <span>

namespace Collo::HostFunctions {

class JSColloPerformanceObserver;

enum class PerformanceEntryKind : uint8_t {
    Mark,
    Measure,
};

enum PerformanceObserverTypeMask : uint8_t {
    PerformanceObserverTypeNone = 0,
    PerformanceObserverTypeMark = 1 << 0,
    PerformanceObserverTypeMeasure = 1 << 1,
};

constexpr double PerformanceNowResolutionMs = 0.005;

inline double coarsenPerformanceNow(double milliseconds)
{
    // High Resolution Time's coarsen time step: flooring to PerformanceNowResolutionMs limits how precisely script
    // can time an operation.
    return std::floor(milliseconds / PerformanceNowResolutionMs) * PerformanceNowResolutionMs;
}

inline uint8_t maskForEntryKind(PerformanceEntryKind kind)
{
    return kind == PerformanceEntryKind::Mark ? PerformanceObserverTypeMark : PerformanceObserverTypeMeasure;
}

class JSColloPerformance;
class JSColloPerformanceEntry;

void notifyPerformanceObservers(JSC::JSGlobalObject*, JSC::VM&, JSColloPerformance&, JSColloPerformanceEntry*);
// The Performance cell installed on `global_object`'s realm, which every PerformanceMark and PerformanceObserver that
// realm's constructors create records into or observes. Null only on a global whose Web APIs were not installed.
JSColloPerformance* realmPerformance(JSC::JSGlobalObject*);

inline bool requireArgumentCount(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame,
    unsigned count, WTF::ASCIILiteral message)
{
    if (call_frame->argumentCount() >= count)
        return true;
    JSC::throwVMTypeError(global_object, scope, message);
    return false;
}

// Returns the Performance cell `value` holds, or throws a TypeError and returns null. It is defined after
// JSColloPerformance because `dynamicDowncast` needs the complete type: with an incomplete one, the JSValue overloads
// constrained on `T::info()` drop out and the call does not compile.
inline JSColloPerformance* requirePerformance(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue);

// Host functions defined in entry.cpp and observer.cpp that performance.cpp's installer puts on the prototypes.
JSC_DECLARE_HOST_FUNCTION(performanceEntryConstructorCall);
JSC_DECLARE_HOST_FUNCTION(performanceEntryConstructorConstruct);
JSC_DECLARE_HOST_FUNCTION(performanceMarkConstructorCall);
JSC_DECLARE_HOST_FUNCTION(performanceMarkConstructorConstruct);
JSC_DECLARE_HOST_FUNCTION(performanceMeasureConstructorCall);
JSC_DECLARE_HOST_FUNCTION(performanceMeasureConstructorConstruct);
JSC_DECLARE_HOST_FUNCTION(performanceObserverConstructorCall);
JSC_DECLARE_HOST_FUNCTION(performanceObserverConstructorConstruct);
JSC_DECLARE_HOST_FUNCTION(performanceObserverObserve);
JSC_DECLARE_HOST_FUNCTION(performanceObserverDisconnect);
JSC_DECLARE_HOST_FUNCTION(performanceObserverTakeRecords);
JSC_DECLARE_HOST_FUNCTION(performanceObserverSupportedEntryTypes);
JSC_DECLARE_HOST_FUNCTION(performanceObserverEntryListConstructorCall);
JSC_DECLARE_HOST_FUNCTION(performanceObserverEntryListConstructorConstruct);
JSC_DECLARE_HOST_FUNCTION(performanceObserverEntryListGetEntries);
JSC_DECLARE_HOST_FUNCTION(performanceObserverEntryListGetEntriesByType);
JSC_DECLARE_HOST_FUNCTION(performanceObserverEntryListGetEntriesByName);
JSC_DECLARE_HOST_FUNCTION(performanceEntryGetName);
JSC_DECLARE_HOST_FUNCTION(performanceEntryGetEntryType);
JSC_DECLARE_HOST_FUNCTION(performanceEntryGetStartTime);
JSC_DECLARE_HOST_FUNCTION(performanceEntryGetDuration);
JSC_DECLARE_HOST_FUNCTION(performanceEntryGetDetail);
JSC_DECLARE_HOST_FUNCTION(performanceEntryToJSON);
JSC_DECLARE_HOST_FUNCTION(performanceMark);
JSC_DECLARE_HOST_FUNCTION(performanceMeasure);
JSC_DECLARE_HOST_FUNCTION(performanceClearMarks);
JSC_DECLARE_HOST_FUNCTION(performanceClearMeasures);

class JSColloPerformanceEntry : public JSC::JSDestructibleObject {
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

    static void destroy(JSC::JSCell* cell) { static_cast<JSColloPerformanceEntry*>(cell)->~JSColloPerformanceEntry(); }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    const WTF::String& name() const { return m_name; }
    PerformanceEntryKind kind() const { return m_kind; }
    double startTime() const { return m_start_time; }
    double duration() const { return m_duration; }
    JSC::JSValue detail() const { return m_detail.get(); }

    WTF::String entryType() const { return m_kind == PerformanceEntryKind::Mark ? "mark"_s : "measure"_s; }

protected:
    JSColloPerformanceEntry(JSC::VM& vm, JSC::Structure* structure, WTF::String name, PerformanceEntryKind kind,
        double start_time, double duration)
        : Base(vm, structure)
        , m_name(WTF::move(name))
        , m_kind(kind)
        , m_start_time(start_time)
        , m_duration(duration)
    {
    }

    ~JSColloPerformanceEntry() = default;

    void finishCreation(JSC::VM& vm, JSC::JSValue detail)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
        m_detail.set(vm, this, detail);
    }

private:
    WTF::String m_name;
    JSC::WriteBarrier<JSC::Unknown> m_detail;
    PerformanceEntryKind m_kind;
    double m_start_time { 0 };
    double m_duration { 0 };
};

class JSColloPerformanceMark final : public JSColloPerformanceEntry {
    using Base = JSColloPerformanceEntry;

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

    static JSColloPerformanceMark* create(
        JSC::VM& vm, JSC::Structure* structure, WTF::String name, double start_time, JSC::JSValue detail)
    {
        auto* object = new (NotNull, JSC::allocateCell<JSColloPerformanceMark>(vm))
            JSColloPerformanceMark(vm, structure, WTF::move(name), start_time);
        object->finishCreation(vm, detail);
        return object;
    }

    static void destroy(JSC::JSCell* cell) { static_cast<JSColloPerformanceMark*>(cell)->~JSColloPerformanceMark(); }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

private:
    JSColloPerformanceMark(JSC::VM& vm, JSC::Structure* structure, WTF::String name, double start_time)
        : Base(vm, structure, WTF::move(name), PerformanceEntryKind::Mark, start_time, 0)
    {
    }

    ~JSColloPerformanceMark() = default;
};

class JSColloPerformanceMeasure final : public JSColloPerformanceEntry {
    using Base = JSColloPerformanceEntry;

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

    static JSColloPerformanceMeasure* create(JSC::VM& vm, JSC::Structure* structure, WTF::String name,
        double start_time, double duration, JSC::JSValue detail)
    {
        auto* object = new (NotNull, JSC::allocateCell<JSColloPerformanceMeasure>(vm))
            JSColloPerformanceMeasure(vm, structure, WTF::move(name), start_time, duration);
        object->finishCreation(vm, detail);
        return object;
    }

    static void destroy(JSC::JSCell* cell)
    {
        static_cast<JSColloPerformanceMeasure*>(cell)->~JSColloPerformanceMeasure();
    }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

private:
    JSColloPerformanceMeasure(
        JSC::VM& vm, JSC::Structure* structure, WTF::String name, double start_time, double duration)
        : Base(vm, structure, WTF::move(name), PerformanceEntryKind::Measure, start_time, duration)
    {
    }

    ~JSColloPerformanceMeasure() = default;
};

// One entry in the buffer or in an observer's pending list.
struct PerformanceEntrySlot {
    JSC::WriteBarrier<JSColloPerformanceEntry> entry;

    template <typename Visitor> void visitEdges(Visitor& visitor) const { visitor.append(entry); }
};

// Entries collected to build an array, rooted while the array is allocated.
using PerformanceEntryRoots = JSC::MarkedVector<JSColloPerformanceEntry*, 8, WTF::RecordOverflow>;

// The entries in `entries` ordered by startTime and stable for equal times, as a new array. Returns null with the
// exception pending when the array cannot be built.
JSC::JSObject* performanceEntriesArray(JSC::JSGlobalObject*, PerformanceEntryRoots& entries);

class JSColloPerformance final : public JSC::JSDestructibleObject {
    using Base = JSC::JSDestructibleObject;

    struct ObserverSlot {
        JSC::WriteBarrier<JSC::JSObject> observer;

        template <typename Visitor> void visitEdges(Visitor& visitor) const { visitor.append(observer); }
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

    static JSColloPerformance* create(JSC::VM& vm, JSC::Structure* structure, JSC::Structure* mark_structure,
        JSC::Structure* measure_structure, JSC::Structure* observer_structure,
        JSC::Structure* observer_entry_list_structure)
    {
        auto* object = new (NotNull, JSC::allocateCell<JSColloPerformance>(vm)) JSColloPerformance(vm, structure);
        object->finishCreation(
            vm, mark_structure, measure_structure, observer_structure, observer_entry_list_structure);
        return object;
    }

    static void destroy(JSC::JSCell* cell) { static_cast<JSColloPerformance*>(cell)->~JSColloPerformance(); }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    // Coarsened milliseconds since the time origin.
    double nowMs()
    {
        ensureOrigin();
        return coarsenPerformanceNow((WTF::MonotonicTime::now() - m_origin_monotonic).milliseconds());
    }

    // The wall-clock time of the time origin, in milliseconds since the Unix epoch.
    double timeOriginMs()
    {
        ensureOrigin();
        return m_origin_wall_ms;
    }

    JSC::Structure* markStructure() const { return m_mark_structure.get(); }
    JSC::Structure* measureStructure() const { return m_measure_structure.get(); }
    JSC::Structure* observerStructure() const { return m_observer_structure.get(); }
    JSC::Structure* observerEntryListStructure() const { return m_observer_entry_list_structure.get(); }

    // Buffers `entry`, dropping the oldest once WebApiPerformanceEntriesMax are held, and queues it for every observer
    // that watches its type. Returns false, with an OutOfMemoryError thrown into the scope, when the buffer cannot
    // grow.
    bool appendEntry(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::VM& vm, JSColloPerformanceEntry* entry)
    {
        if (m_entries.size() >= WebApiPerformanceEntriesMax)
            m_entries.takeFirst(this);
        PerformanceEntrySlot slot;
        slot.entry.setWithoutWriteBarrier(entry);
        if (!m_entries.tryAppend(vm, this, WTF::move(slot))) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        notifyPerformanceObservers(global_object, vm, *this, entry);
        return true;
    }

    // Adds `observer` unless it is already registered. Returns false when the list cannot grow.
    bool registerObserver(JSC::VM& vm, JSC::JSObject* observer)
    {
        for (auto& existing : m_observers) {
            if (existing.observer.get() == observer)
                return true;
        }
        ObserverSlot slot;
        slot.observer.setWithoutWriteBarrier(observer);
        return m_observers.tryAppend(vm, this, WTF::move(slot));
    }

    void unregisterObserver(JSC::JSObject* observer)
    {
        m_observers.removeIf(this, [observer](const ObserverSlot& slot) { return slot.observer.get() == observer; });
    }

    // Removes the buffered entries that match both filters; a nullopt filter matches every entry.
    void clearEntries(std::optional<WTF::String> name, std::optional<PerformanceEntryKind> kind)
    {
        m_entries.removeIf(this, [&](const PerformanceEntrySlot& slot) {
            auto* entry = slot.entry.get();
            return !entry || ((!kind || entry->kind() == *kind) && (!name || entry->name() == *name));
        });
    }

    // The most recently buffered mark named `name`, or null. User Timing resolves a mark name in measure() to its
    // most recent occurrence.
    JSColloPerformanceEntry* findLatestMark(const WTF::String& name)
    {
        for (auto index = m_entries.size(); index > 0; index--) {
            auto* entry = m_entries.at(index - 1).entry.get();
            if (entry && entry->kind() == PerformanceEntryKind::Mark && entry->name() == name)
                return entry;
        }
        return nullptr;
    }

    // A new array of the buffered entries that satisfy `predicate`, ordered by startTime and stable for equal times.
    // Returns null with the exception pending when the array cannot be built.
    template <typename Predicate> JSC::JSObject* entriesArray(JSC::JSGlobalObject* global_object, Predicate predicate)
    {
        PerformanceEntryRoots matches;
        forEachEntry([&](JSColloPerformanceEntry* entry) {
            if (predicate(*entry))
                matches.append(entry);
        });
        return performanceEntriesArray(global_object, matches);
    }

    template <typename Visitor> void forEachEntry(Visitor visitor)
    {
        for (auto& slot : m_entries) {
            if (auto* entry = slot.entry.get())
                visitor(entry);
        }
    }

    template <typename Visitor> void forEachObserver(Visitor visitor)
    {
        for (auto& slot : m_observers) {
            if (auto* observer = slot.observer.get())
                visitor(observer);
        }
    }

private:
    JSColloPerformance(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    ~JSColloPerformance() = default;

    void finishCreation(JSC::VM& vm, JSC::Structure* mark_structure, JSC::Structure* measure_structure,
        JSC::Structure* observer_structure, JSC::Structure* observer_entry_list_structure)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
        m_mark_structure.set(vm, this, mark_structure);
        m_measure_structure.set(vm, this, measure_structure);
        m_observer_structure.set(vm, this, observer_structure);
        m_observer_entry_list_structure.set(vm, this, observer_entry_list_structure);
    }

    void ensureOrigin()
    {
        if (m_origin_monotonic)
            return;
        m_origin_monotonic = WTF::MonotonicTime::now();
        m_origin_wall_ms = WTF::WallTime::now().secondsSinceEpoch().milliseconds();
    }

    JSC::WriteBarrier<JSC::Structure> m_mark_structure;
    JSC::WriteBarrier<JSC::Structure> m_measure_structure;
    JSC::WriteBarrier<JSC::Structure> m_observer_structure;
    JSC::WriteBarrier<JSC::Structure> m_observer_entry_list_structure;
    Collo::CellEdgeList<PerformanceEntrySlot> m_entries;
    Collo::CellEdgeList<ObserverSlot> m_observers;
    WTF::MonotonicTime m_origin_monotonic;
    double m_origin_wall_ms { 0 };
};

inline JSColloPerformance* requirePerformance(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value)
{
    if (auto* performance = dynamicDowncast<JSColloPerformance>(value))
        return performance;
    JSC::throwVMTypeError(global_object, scope, "Performance method called on incompatible receiver"_s);
    return nullptr;
}

class JSColloPerformanceObserverEntryList final : public JSC::JSDestructibleObject {
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

    // Holds `entries`, which the caller roots, ordered by startTime and stable for equal times.
    static JSColloPerformanceObserverEntryList* create(
        JSC::VM& vm, JSC::Structure* structure, std::span<JSColloPerformanceEntry* const> entries)
    {
        auto* object = new (NotNull, JSC::allocateCell<JSColloPerformanceObserverEntryList>(vm))
            JSColloPerformanceObserverEntryList(vm, structure);
        object->finishCreation(vm, entries);
        return object;
    }

    static void destroy(JSC::JSCell* cell)
    {
        static_cast<JSColloPerformanceObserverEntryList*>(cell)->~JSColloPerformanceObserverEntryList();
    }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    // A new array of the held entries that satisfy `predicate`, in the list's order. Returns null with the exception
    // pending when the array cannot be built.
    template <typename Predicate> JSC::JSObject* entriesArray(JSC::JSGlobalObject* global_object, Predicate predicate)
    {
        auto scope = DECLARE_THROW_SCOPE(global_object->vm());
        auto* result = JSC::constructEmptyArray(global_object, nullptr, 0);
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!result) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return nullptr;
        }
        unsigned out_index = 0;
        for (auto& barrier : m_entries) {
            auto* entry = barrier.get();
            if (!entry || !predicate(*entry))
                continue;
            result->putDirectIndex(global_object, out_index++, entry);
            RETURN_IF_EXCEPTION(scope, nullptr);
        }
        return result;
    }

private:
    JSColloPerformanceObserverEntryList(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    ~JSColloPerformanceObserverEntryList() = default;

    // The list is filled before the cell is published and never changes afterwards, so visitChildren reads it without
    // a lock.
    void finishCreation(JSC::VM& vm, std::span<JSColloPerformanceEntry* const> entries)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
        m_entries.reserveInitialCapacity(entries.size());
        for (auto* entry : entries)
            m_entries.append(JSC::WriteBarrier<JSColloPerformanceEntry>(vm, this, entry));
        std::stable_sort(m_entries.begin(), m_entries.end(),
            [](const auto& left, const auto& right) { return left->startTime() < right->startTime(); });
    }

    WTF::Vector<JSC::WriteBarrier<JSColloPerformanceEntry>> m_entries;
};

class JSColloPerformanceObserver final : public JSC::JSDestructibleObject {
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

    static JSColloPerformanceObserver* create(
        JSC::VM& vm, JSC::Structure* structure, JSColloPerformance* performance, JSC::JSObject* callback)
    {
        auto* object = new (NotNull, JSC::allocateCell<JSColloPerformanceObserver>(vm))
            JSColloPerformanceObserver(vm, structure);
        object->finishCreation(vm, performance, callback);
        return object;
    }

    static void destroy(JSC::JSCell* cell)
    {
        static_cast<JSColloPerformanceObserver*>(cell)->~JSColloPerformanceObserver();
    }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    JSColloPerformance* performance() const { return m_performance.get(); }

    bool observes(JSColloPerformanceEntry& entry) const
    {
        return m_registered && (m_type_mask & maskForEntryKind(entry.kind()));
    }

    // Queues `entry` for the next delivery, dropping the oldest pending entry once
    // WebApiPerformanceObserverPendingEntriesMax are pending, and schedules a delivery unless one is scheduled. An
    // entry the list has no room for is dropped like the oldest one.
    void queueEntry(JSC::JSGlobalObject* global_object, JSC::VM& vm, JSColloPerformanceEntry* entry)
    {
        if (m_entries_to_deliver.size() >= WebApiPerformanceObserverPendingEntriesMax)
            m_entries_to_deliver.takeFirst(this);
        PerformanceEntrySlot slot;
        slot.entry.setWithoutWriteBarrier(entry);
        if (!m_entries_to_deliver.tryAppend(vm, this, WTF::move(slot)))
            return;
        scheduleDeliveryIfNeeded(global_object, vm);
    }

    void observe(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue options_value);
    void disconnect();
    JSC::JSObject* takeRecordsArray(JSC::JSGlobalObject*);
    void queueDeliveryMicrotask(JSC::JSGlobalObject*, JSC::VM&);
    JSC::EncodedJSValue deliver(JSC::JSGlobalObject*, JSC::ThrowScope&);

private:
    JSColloPerformanceObserver(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    ~JSColloPerformanceObserver() = default;

    void finishCreation(JSC::VM& vm, JSColloPerformance* performance, JSC::JSObject* callback)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
        m_performance.set(vm, this, performance);
        m_callback.set(vm, this, callback);
    }

    void scheduleDeliveryIfNeeded(JSC::JSGlobalObject*, JSC::VM&);
    // Appends the pending entries to `out`, which the caller roots.
    void pendingRecords(PerformanceEntryRoots& out);
    unsigned pendingEntryCount() const { return m_entries_to_deliver.size(); }
    void clearPendingEntries() { m_entries_to_deliver.clear(this); }

    JSC::WriteBarrier<JSColloPerformance> m_performance;
    JSC::WriteBarrier<JSC::JSObject> m_callback;
    Collo::CellEdgeList<PerformanceEntrySlot> m_entries_to_deliver;
    uint8_t m_type_mask { PerformanceObserverTypeNone };
    bool m_registered { false };
    bool m_is_type_observer { false };
    bool m_delivery_scheduled { false };
};

} // namespace Collo::HostFunctions
