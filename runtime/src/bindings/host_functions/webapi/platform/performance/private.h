// The cells behind `performance`, shared by the files under `performance/`: Performance, PerformanceEntry with its
// Mark and Measure subclasses, PerformanceTiming, PerformanceObserver and PerformanceObserverEntryList. They run on
// the VM thread, except visitChildren, which the concurrent marker runs. The VM's one Performance cell, found through
// the global `performance` property (`performanceSingleton`), holds the structures of the cells it creates, the entry
// buffer and the registered observers. Like Node's per-process `performance`, that timeline belongs to the worker
// rather than to a request: entries, observers, listeners and the time origin persist across requests, and requests
// co-scheduled on one worker share them, so nothing may reset them when a request ends. Resource timing is not
// implemented: no resource entry is ever recorded, and the buffer size and buffer-full handler are only stored.

#pragma once

#include "host_functions/webapi/platform/performance.h"

#include "host_functions/runtime/bridge.h"
#include "host_functions/webapi/limits.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/JSDestructibleObject.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <wtf/MonotonicTime.h>
#include <wtf/Vector.h>
#include <wtf/WallTime.h>
#include <wtf/text/WTFString.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <optional>

namespace Collo::HostFunctions {

using JSC::EncodedJSValue;
using JSC::JSValue;
using WTF::String;
using namespace JSC;

class JSColloPerformanceObserver;
class JSColloPerformanceTiming;

enum class PerformanceEntryKind : uint8_t {
    Mark,
    Measure,
};

enum PerformanceObserverTypeMask : uint8_t {
    PerformanceObserverTypeNone = 0,
    PerformanceObserverTypeMark = 1 << 0,
    PerformanceObserverTypeMeasure = 1 << 1,
    PerformanceObserverTypeResource = 1 << 2,
};

constexpr unsigned PerformanceMaxEntries = 10000;
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
JSColloPerformance* performanceSingleton(JSC::JSGlobalObject*);

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
inline JSColloPerformance* requirePerformance(JSC::JSGlobalObject*, JSC::ThrowScope&, JSValue);

JSC_DECLARE_HOST_FUNCTION(performanceConstructorCall);
JSC_DECLARE_HOST_FUNCTION(performanceConstructorConstruct);
JSC_DECLARE_HOST_FUNCTION(performanceEntryConstructorCall);
JSC_DECLARE_HOST_FUNCTION(performanceEntryConstructorConstruct);
JSC_DECLARE_HOST_FUNCTION(performanceMarkConstructorCall);
JSC_DECLARE_HOST_FUNCTION(performanceMarkConstructorConstruct);
JSC_DECLARE_HOST_FUNCTION(performanceMeasureConstructorCall);
JSC_DECLARE_HOST_FUNCTION(performanceMeasureConstructorConstruct);
JSC_DECLARE_HOST_FUNCTION(performanceObserverConstructorCall);
JSC_DECLARE_HOST_FUNCTION(performanceObserverConstructorConstruct);
JSC_DECLARE_HOST_FUNCTION(performanceObserverScheduleMicrotask);
JSC_DECLARE_HOST_FUNCTION(performanceObserverDeliverMicrotask);
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
JSC_DECLARE_HOST_FUNCTION(performanceTimingConstructorCall);
JSC_DECLARE_HOST_FUNCTION(performanceTimingConstructorConstruct);
JSC_DECLARE_HOST_FUNCTION(performanceTimingZero);
JSC_DECLARE_HOST_FUNCTION(performanceTimingToJSON);
JSC_DECLARE_HOST_FUNCTION(performanceNow);
JSC_DECLARE_HOST_FUNCTION(performanceGetTimeOrigin);
JSC_DECLARE_HOST_FUNCTION(performanceGetTiming);
JSC_DECLARE_HOST_FUNCTION(performanceToJSON);
JSC_DECLARE_HOST_FUNCTION(performanceGetOnResourceTimingBufferFull);
JSC_DECLARE_HOST_FUNCTION(performanceSetOnResourceTimingBufferFull);
JSC_DECLARE_HOST_FUNCTION(performanceClearResourceTimings);
JSC_DECLARE_HOST_FUNCTION(performanceSetResourceTimingBufferSize);
JSC_DECLARE_HOST_FUNCTION(performanceMarkResourceTiming);
JSC_DECLARE_HOST_FUNCTION(performanceMark);
JSC_DECLARE_HOST_FUNCTION(performanceMeasure);
JSC_DECLARE_HOST_FUNCTION(performanceGetEntries);
JSC_DECLARE_HOST_FUNCTION(performanceGetEntriesByName);
JSC_DECLARE_HOST_FUNCTION(performanceGetEntriesByType);
JSC_DECLARE_HOST_FUNCTION(performanceClearMarks);
JSC_DECLARE_HOST_FUNCTION(performanceClearMeasures);

class JSColloPerformanceEntry : public JSC::JSDestructibleObject {
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

    static void destroy(JSC::JSCell* cell) { static_cast<JSColloPerformanceEntry*>(cell)->~JSColloPerformanceEntry(); }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    const String& name() const { return m_name; }
    PerformanceEntryKind kind() const { return m_kind; }
    double startTime() const { return m_start_time; }
    double duration() const { return m_duration; }
    JSValue detail() const { return m_detail.get(); }

    String entryType() const { return m_kind == PerformanceEntryKind::Mark ? "mark"_s : "measure"_s; }

protected:
    JSColloPerformanceEntry(JSC::VM& vm, JSC::Structure* structure, String name, PerformanceEntryKind kind,
        double start_time, double duration)
        : Base(vm, structure)
        , m_name(WTF::move(name))
        , m_kind(kind)
        , m_start_time(start_time)
        , m_duration(duration)
    {
    }

    ~JSColloPerformanceEntry() = default;

    void finishCreation(JSC::VM& vm, JSValue detail)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
        m_detail.set(vm, this, detail);
    }

private:
    String m_name;
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

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSValue prototype)
    {
        return JSC::Structure::create(
            vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

    static JSColloPerformanceMark* create(
        JSC::VM& vm, JSC::Structure* structure, String name, double start_time, JSValue detail)
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
    JSColloPerformanceMark(JSC::VM& vm, JSC::Structure* structure, String name, double start_time)
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

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSValue prototype)
    {
        return JSC::Structure::create(
            vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

    static JSColloPerformanceMeasure* create(
        JSC::VM& vm, JSC::Structure* structure, String name, double start_time, double duration, JSValue detail)
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
    JSColloPerformanceMeasure(JSC::VM& vm, JSC::Structure* structure, String name, double start_time, double duration)
        : Base(vm, structure, WTF::move(name), PerformanceEntryKind::Measure, start_time, duration)
    {
    }

    ~JSColloPerformanceMeasure() = default;
};

class JSColloPerformanceTiming final : public JSC::JSDestructibleObject {
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

    static JSColloPerformanceTiming* create(JSC::VM& vm, JSC::Structure* structure)
    {
        auto* object
            = new (NotNull, JSC::allocateCell<JSColloPerformanceTiming>(vm)) JSColloPerformanceTiming(vm, structure);
        object->finishCreation(vm);
        return object;
    }

    static void destroy(JSC::JSCell* cell)
    {
        static_cast<JSColloPerformanceTiming*>(cell)->~JSColloPerformanceTiming();
    }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

private:
    JSColloPerformanceTiming(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    ~JSColloPerformanceTiming() = default;

    void finishCreation(JSC::VM& vm)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
    }
};

class JSColloPerformance final : public JSC::JSDestructibleObject {
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

    static JSColloPerformance* create(JSC::VM& vm, JSC::Structure* structure, JSC::Structure* mark_structure,
        JSC::Structure* measure_structure, JSC::Structure* observer_structure,
        JSC::Structure* observer_entry_list_structure, JSColloPerformanceTiming* timing)
    {
        auto* object = new (NotNull, JSC::allocateCell<JSColloPerformance>(vm)) JSColloPerformance(vm, structure);
        object->finishCreation(
            vm, mark_structure, measure_structure, observer_structure, observer_entry_list_structure, timing);
        return object;
    }

    static void destroy(JSC::JSCell* cell) { static_cast<JSColloPerformance*>(cell)->~JSColloPerformance(); }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    WebApiEventTargetData& eventTargetData() { return m_event_target; }

    // Coarsened milliseconds since the time origin.
    double nowMs(JSC::JSGlobalObject* global_object)
    {
        ensureTimeOriginForAccess();
        ensureOrigin();
        return coarsenPerformanceNow((WTF::MonotonicTime::now() - m_origin_monotonic).milliseconds());
    }

    // The wall-clock time of the time origin, in milliseconds since the Unix epoch.
    double timeOriginMs(JSC::JSGlobalObject* global_object)
    {
        ensureTimeOriginForAccess();
        ensureOrigin();
        return m_origin_wall_ms;
    }

    JSC::Structure* markStructure() const { return m_mark_structure.get(); }
    JSC::Structure* measureStructure() const { return m_measure_structure.get(); }
    JSC::Structure* observerStructure() const { return m_observer_structure.get(); }
    JSC::Structure* observerEntryListStructure() const { return m_observer_entry_list_structure.get(); }
    JSColloPerformanceTiming* timing() const { return m_timing.get(); }
    JSValue onResourceTimingBufferFull() const { return m_on_resource_timing_buffer_full.get(); }

    // Stores a callable or other object and turns any other value into null, as an event handler attribute does.
    // Nothing invokes it, since no resource entry is ever buffered.
    void setOnResourceTimingBufferFull(JSC::VM& vm, JSValue value)
    {
        if (value.isUndefinedOrNull()) {
            m_on_resource_timing_buffer_full.set(vm, this, JSC::jsNull());
            return;
        }
        auto call_data = JSC::getCallData(value);
        m_on_resource_timing_buffer_full.set(
            vm, this, call_data.type == JSC::CallData::Type::None && !value.isObject() ? JSC::jsNull() : value);
    }

    // Buffers `entry`, dropping the oldest once PerformanceMaxEntries are held, and queues it for every observer
    // that watches its type.
    void appendEntry(JSC::JSGlobalObject* global_object, JSC::VM& vm, JSColloPerformanceEntry* entry)
    {
        ensureTimeOriginForAccess();
        if (entryCount() >= PerformanceMaxEntries) {
            m_entries[m_entries_head].clear();
            m_entries_head++;
            compactEntriesIfNeeded();
        }
        JSC::WriteBarrier<JSColloPerformanceEntry> barrier;
        barrier.set(vm, this, entry);
        m_entries.append(WTF::move(barrier));
        notifyPerformanceObservers(global_object, vm, *this, entry);
    }

    // Fixes the time origin at the first access. It resets nothing: the timeline is the worker's, and a reset keyed
    // on the current request would wipe the entries, observers and listeners of a request co-scheduled on the same
    // worker while it is still running.
    void ensureTimeOriginForAccess() { ensureOrigin(); }

    void setResourceTimingBufferSize(unsigned size)
    {
        m_resource_timing_buffer_size = std::min(size, PerformanceMaxEntries);
    }

    // Adds `observer` unless it is already registered.
    void registerObserver(JSC::VM& vm, JSC::JSObject* observer)
    {
        for (auto& existing : m_observers) {
            if (existing.get() == observer)
                return;
        }
        JSC::WriteBarrier<JSC::JSObject> barrier;
        barrier.set(vm, this, observer);
        m_observers.append(WTF::move(barrier));
    }

    void unregisterObserver(JSC::JSObject* observer)
    {
        unsigned write = 0;
        for (unsigned read = 0; read < m_observers.size(); read++) {
            if (m_observers[read].get() == observer)
                continue;
            if (write != read)
                m_observers[write] = WTF::move(m_observers[read]);
            write++;
        }
        m_observers.shrink(write);
    }

    // Removes the buffered entries that match both filters; a nullopt filter matches every entry.
    void clearEntries(std::optional<String> name, std::optional<PerformanceEntryKind> kind)
    {
        compactEntries();
        unsigned write = 0;
        for (unsigned read = 0; read < m_entries.size(); read++) {
            auto* entry = m_entries[read].get();
            if (!entry)
                continue;
            if ((!kind || entry->kind() == *kind) && (!name || entry->name() == *name))
                continue;
            if (write != read)
                m_entries[write] = WTF::move(m_entries[read]);
            write++;
        }
        m_entries.shrink(write);
    }

    // The most recently buffered mark named `name`, or null. User Timing resolves a mark name in measure() to its
    // most recent occurrence.
    JSColloPerformanceEntry* findLatestMark(const String& name)
    {
        for (auto index = m_entries.size(); index > m_entries_head; index--) {
            auto* entry = m_entries[index - 1].get();
            if (entry && entry->kind() == PerformanceEntryKind::Mark && entry->name() == name)
                return entry;
        }
        return nullptr;
    }

    // A new array of the buffered entries that satisfy `predicate`, ordered by startTime and stable for equal times.
    template <typename Predicate> JSC::JSObject* entriesArray(JSC::JSGlobalObject* global_object, Predicate predicate)
    {
        ensureTimeOriginForAccess();
        WTF::Vector<JSColloPerformanceEntry*> matches;
        for (unsigned index = m_entries_head; index < m_entries.size(); index++) {
            auto& barrier = m_entries[index];
            auto* entry = barrier.get();
            if (entry && predicate(*entry))
                matches.append(entry);
        }
        std::stable_sort(matches.begin(), matches.end(),
            [](auto* left, auto* right) { return left->startTime() < right->startTime(); });

        auto* result = JSC::constructEmptyArray(global_object, nullptr, matches.size());
        for (unsigned index = 0; index < matches.size(); index++)
            result->putDirectIndex(global_object, index, matches[index]);
        return result;
    }

    template <typename Visitor> void forEachEntry(Visitor visitor)
    {
        for (unsigned index = m_entries_head; index < m_entries.size(); index++) {
            auto& barrier = m_entries[index];
            if (auto* entry = barrier.get())
                visitor(entry);
        }
    }

    template <typename Visitor> void forEachObserver(Visitor visitor)
    {
        for (auto& barrier : m_observers) {
            if (auto* observer = barrier.get())
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
        JSC::Structure* observer_structure, JSC::Structure* observer_entry_list_structure,
        JSColloPerformanceTiming* timing)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
        m_mark_structure.set(vm, this, mark_structure);
        m_measure_structure.set(vm, this, measure_structure);
        m_observer_structure.set(vm, this, observer_structure);
        m_observer_entry_list_structure.set(vm, this, observer_entry_list_structure);
        m_timing.set(vm, this, timing);
        m_on_resource_timing_buffer_full.set(vm, this, JSC::jsNull());
    }

    unsigned entryCount() const { return m_entries.size() - m_entries_head; }

    void compactEntries()
    {
        if (!m_entries_head)
            return;
        if (m_entries_head >= m_entries.size()) {
            m_entries.clear();
            m_entries_head = 0;
            return;
        }

        unsigned write = 0;
        for (unsigned read = m_entries_head; read < m_entries.size(); read++) {
            if (write != read)
                m_entries[write] = WTF::move(m_entries[read]);
            write++;
        }
        m_entries.shrink(write);
        m_entries_head = 0;
    }

    // Compacting once the dropped prefix reaches half the vector keeps dropping the oldest entry amortized O(1).
    void compactEntriesIfNeeded()
    {
        if (!m_entries_head)
            return;
        if (m_entries_head >= m_entries.size() || (m_entries_head >= 256 && m_entries_head * 2 >= m_entries.size()))
            compactEntries();
    }

    void ensureOrigin()
    {
        if (m_origin_monotonic)
            return;

        resetOrigin();
    }

    void resetOrigin()
    {
        m_origin_monotonic = WTF::MonotonicTime::now();
        m_origin_wall_ms = WTF::WallTime::now().secondsSinceEpoch().milliseconds();
    }

    WebApiEventTargetData m_event_target;
    JSC::WriteBarrier<JSC::Structure> m_mark_structure;
    JSC::WriteBarrier<JSC::Structure> m_measure_structure;
    JSC::WriteBarrier<JSC::Structure> m_observer_structure;
    JSC::WriteBarrier<JSC::Structure> m_observer_entry_list_structure;
    JSC::WriteBarrier<JSColloPerformanceTiming> m_timing;
    JSC::WriteBarrier<JSC::Unknown> m_on_resource_timing_buffer_full;
    // Live entries start at m_entries_head; the slots before it were dropped and are cleared.
    // FIXME: visitChildren walks m_entries and m_observers under cellLock(), but appendEntry, clearEntries,
    // registerObserver, unregisterObserver and the compaction helpers reallocate them without taking it, so the
    // concurrent marker can read a freed buffer.
    WTF::Vector<JSC::WriteBarrier<JSColloPerformanceEntry>> m_entries;
    WTF::Vector<JSC::WriteBarrier<JSC::JSObject>> m_observers;
    WTF::MonotonicTime m_origin_monotonic;
    double m_origin_wall_ms { 0 };
    unsigned m_entries_head { 0 };
    unsigned m_resource_timing_buffer_size { PerformanceMaxEntries };
};

inline JSColloPerformance* requirePerformance(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
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

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSValue prototype)
    {
        return JSC::Structure::create(
            vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
    }

    static JSColloPerformanceObserverEntryList* create(
        JSC::VM& vm, JSC::Structure* structure, WTF::Vector<JSColloPerformanceEntry*>&& entries)
    {
        std::stable_sort(entries.begin(), entries.end(),
            [](auto* left, auto* right) { return left->startTime() < right->startTime(); });

        auto* object = new (NotNull, JSC::allocateCell<JSColloPerformanceObserverEntryList>(vm))
            JSColloPerformanceObserverEntryList(vm, structure);
        object->finishCreation(vm, WTF::move(entries));
        return object;
    }

    static void destroy(JSC::JSCell* cell)
    {
        static_cast<JSColloPerformanceObserverEntryList*>(cell)->~JSColloPerformanceObserverEntryList();
    }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    template <typename Predicate> JSC::JSObject* entriesArray(JSC::JSGlobalObject* global_object, Predicate predicate)
    {
        auto* result = JSC::constructEmptyArray(global_object, nullptr, 0);
        unsigned out_index = 0;
        for (auto& barrier : m_entries) {
            auto* entry = barrier.get();
            if (!entry || !predicate(*entry))
                continue;
            result->putDirectIndex(global_object, out_index++, entry);
        }
        return result;
    }

private:
    JSColloPerformanceObserverEntryList(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    ~JSColloPerformanceObserverEntryList() = default;

    void finishCreation(JSC::VM& vm, WTF::Vector<JSColloPerformanceEntry*>&& entries)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
        m_entries.reserveInitialCapacity(entries.size());
        for (auto* entry : entries) {
            JSC::WriteBarrier<JSColloPerformanceEntry> barrier;
            barrier.set(vm, this, entry);
            m_entries.append(WTF::move(barrier));
        }
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

    static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSValue prototype)
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
    // WebApiPerformanceObserverPendingEntriesMax are pending, and schedules a delivery unless one is scheduled.
    void queueEntry(JSC::JSGlobalObject* global_object, JSC::VM& vm, JSColloPerformanceEntry* entry)
    {
        if (pendingEntryCount() >= WebApiPerformanceObserverPendingEntriesMax) {
            m_entries_to_deliver[m_entries_to_deliver_head].clear();
            m_entries_to_deliver_head++;
            compactPendingEntriesIfNeeded();
        }
        JSC::WriteBarrier<JSColloPerformanceEntry> barrier;
        barrier.set(vm, this, entry);
        m_entries_to_deliver.append(WTF::move(barrier));
        scheduleDeliveryIfNeeded(global_object, vm);
    }

    void observe(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue options_value);
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
    WTF::Vector<JSColloPerformanceEntry*> pendingRecordsVector();
    unsigned pendingEntryCount() const { return m_entries_to_deliver.size() - m_entries_to_deliver_head; }
    void clearPendingEntries()
    {
        m_entries_to_deliver.clear();
        m_entries_to_deliver_head = 0;
    }
    void compactPendingEntries()
    {
        if (!m_entries_to_deliver_head)
            return;
        if (m_entries_to_deliver_head >= m_entries_to_deliver.size()) {
            clearPendingEntries();
            return;
        }

        unsigned write = 0;
        for (unsigned read = m_entries_to_deliver_head; read < m_entries_to_deliver.size(); read++) {
            if (write != read)
                m_entries_to_deliver[write] = WTF::move(m_entries_to_deliver[read]);
            write++;
        }
        m_entries_to_deliver.shrink(write);
        m_entries_to_deliver_head = 0;
    }
    // Compacting once the dropped prefix reaches half the vector keeps dropping the oldest pending entry
    // amortized O(1).
    void compactPendingEntriesIfNeeded()
    {
        if (!m_entries_to_deliver_head)
            return;
        if (m_entries_to_deliver_head >= m_entries_to_deliver.size()
            || (m_entries_to_deliver_head >= 64 && m_entries_to_deliver_head * 2 >= m_entries_to_deliver.size()))
            compactPendingEntries();
    }

    JSC::WriteBarrier<JSColloPerformance> m_performance;
    JSC::WriteBarrier<JSC::JSObject> m_callback;
    // FIXME: visitChildren walks this vector without cellLock(), while queueEntry and the pending-entry helpers
    // reallocate it, so the concurrent marker can read a freed buffer.
    WTF::Vector<JSC::WriteBarrier<JSColloPerformanceEntry>> m_entries_to_deliver;
    unsigned m_entries_to_deliver_head { 0 };
    uint8_t m_type_mask { PerformanceObserverTypeNone };
    bool m_registered { false };
    bool m_is_type_observer { false };
    bool m_delivery_scheduled { false };
};

} // namespace Collo::HostFunctions
