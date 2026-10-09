// The Performance object and PerformanceTiming on the VM thread, the installer for every interface under
// `performance/`, and `collo_webapi_cleanup_request`. PerformanceTiming is a legacy stub whose attributes are all 0.
// `performance` inherits from EventTarget.prototype and reaches the shared event code through
// `webApiPerformanceTargetHandle`.

#include "host_functions/webapi/platform/performance/private.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSString.h>
#include <wtf/Locker.h>
#include <wtf/text/WTFString.h>

namespace Collo::HostFunctions {

using JSC::EncodedJSValue;
using JSC::JSValue;
using WTF::String;
using namespace JSC;

constexpr std::array<WTF::ASCIILiteral, 21> performance_timing_keys {
    "navigationStart"_s,
    "unloadEventStart"_s,
    "unloadEventEnd"_s,
    "redirectStart"_s,
    "redirectEnd"_s,
    "fetchStart"_s,
    "domainLookupStart"_s,
    "domainLookupEnd"_s,
    "connectStart"_s,
    "connectEnd"_s,
    "secureConnectionStart"_s,
    "requestStart"_s,
    "responseStart"_s,
    "responseEnd"_s,
    "domLoading"_s,
    "domInteractive"_s,
    "domContentLoadedEventStart"_s,
    "domContentLoadedEventEnd"_s,
    "domComplete"_s,
    "loadEventStart"_s,
    "loadEventEnd"_s,
};

const JSC::ClassInfo JSColloPerformanceTiming::s_info
    = { "PerformanceTiming"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloPerformanceTiming) };
const JSC::ClassInfo JSColloPerformance::s_info
    = { "Performance"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloPerformance) };

template <typename Visitor> void JSColloPerformanceTiming::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloPerformanceTiming*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
}

DEFINE_VISIT_CHILDREN(JSColloPerformanceTiming);

template <typename Visitor> void JSColloPerformance::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloPerformance*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    // The cell lock keeps the listener vectors from being reallocated while the concurrent marker walks them; the
    // mutators in `event_target.cpp` take the owning cell's lock around every reallocation.
    WTF::Locker locker { this_object->cellLock() };
    this_object->m_event_target.visitChildren(visitor);
    visitor.append(this_object->m_mark_structure);
    visitor.append(this_object->m_measure_structure);
    visitor.append(this_object->m_observer_structure);
    visitor.append(this_object->m_observer_entry_list_structure);
    visitor.append(this_object->m_timing);
    visitor.append(this_object->m_on_resource_timing_buffer_full);
    for (unsigned index = this_object->m_entries_head; index < this_object->m_entries.size(); index++) {
        auto& entry = this_object->m_entries[index];
        visitor.append(entry);
    }
    for (auto& observer : this_object->m_observers)
        visitor.append(observer);
}

DEFINE_VISIT_CHILDREN(JSColloPerformance);

static JSColloPerformanceTiming* requirePerformanceTiming(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    if (auto* timing = dynamicDowncast<JSColloPerformanceTiming>(value))
        return timing;
    JSC::throwVMTypeError(global_object, scope, "PerformanceTiming method called on incompatible receiver"_s);
    return nullptr;
}

// The Performance cell the global `performance` property holds, or null.
// FIXME: that property is configurable, so script can delete or redefine it, and the PerformanceMark and
// PerformanceObserver constructors then reach RELEASE_ASSERT on the null this returns, ending the worker.
JSColloPerformance* performanceSingleton(JSC::JSGlobalObject* global_object)
{
    auto& vm = global_object->vm();
    auto value = global_object->getDirect(vm, JSC::Identifier::fromString(vm, "performance"_s));
    return dynamicDowncast<JSColloPerformance>(value);
}

JSC_DEFINE_HOST_FUNCTION(performanceConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "Performance is not constructable"_s);
}

JSC_DEFINE_HOST_FUNCTION(performanceConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "Performance is not constructable"_s);
}

JSC_DEFINE_HOST_FUNCTION(performanceTimingConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "PerformanceTiming is not constructable"_s);
}

JSC_DEFINE_HOST_FUNCTION(performanceTimingConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "PerformanceTiming is not constructable"_s);
}

JSC_DEFINE_HOST_FUNCTION(performanceTimingZero, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    requirePerformanceTiming(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(JSC::jsNumber(0));
}

JSC_DEFINE_HOST_FUNCTION(performanceTimingToJSON, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    requirePerformanceTiming(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    auto* result
        = JSC::constructEmptyObject(global_object, global_object->objectPrototype(), performance_timing_keys.size());
    for (auto key : performance_timing_keys)
        result->putDirect(vm, JSC::Identifier::fromString(vm, key), JSC::jsNumber(0));
    return JSValue::encode(result);
}

JSC_DEFINE_HOST_FUNCTION(performanceNow, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* performance = requirePerformance(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(JSC::jsNumber(performance->nowMs(global_object)));
}

JSC_DEFINE_HOST_FUNCTION(performanceGetTimeOrigin, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* performance = requirePerformance(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(JSC::jsNumber(performance->timeOriginMs(global_object)));
}

JSC_DEFINE_HOST_FUNCTION(performanceGetTiming, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* performance = requirePerformance(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(performance->timing());
}

JSC_DEFINE_HOST_FUNCTION(performanceToJSON, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* performance = requirePerformance(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});

    auto* result = JSC::constructEmptyObject(global_object, global_object->objectPrototype(), 1);
    result->putDirect(
        vm, JSC::Identifier::fromString(vm, "timeOrigin"_s), JSC::jsNumber(performance->timeOriginMs(global_object)));
    return JSValue::encode(result);
}

JSC_DEFINE_HOST_FUNCTION(
    performanceGetOnResourceTimingBufferFull, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* performance = requirePerformance(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    if (!performance)
        return {};
    return JSValue::encode(performance->onResourceTimingBufferFull());
}

JSC_DEFINE_HOST_FUNCTION(
    performanceSetOnResourceTimingBufferFull, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* performance = requirePerformance(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    if (!performance)
        return {};
    performance->ensureTimeOriginForAccess();
    performance->setOnResourceTimingBufferFull(vm, call_frame->argument(0));
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(
    performanceClearResourceTimings, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* performance = requirePerformance(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    if (!performance)
        return {};
    performance->ensureTimeOriginForAccess();
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(
    performanceSetResourceTimingBufferSize, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* performance = requirePerformance(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    if (!performance)
        return {};
    performance->ensureTimeOriginForAccess();
    if (!call_frame->argument(0).isUndefined()) {
        auto size = call_frame->argument(0).toIntegerOrInfinity(global_object);
        RETURN_IF_EXCEPTION(scope, {});
        if (std::isnan(size) || size <= 0)
            performance->setResourceTimingBufferSize(0);
        else if (size >= PerformanceMaxEntries)
            performance->setResourceTimingBufferSize(PerformanceMaxEntries);
        else
            performance->setResourceTimingBufferSize(static_cast<unsigned>(size));
    }
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(
    performanceMarkResourceTiming, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* performance = requirePerformance(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    if (!performance)
        return {};
    performance->ensureTimeOriginForAccess();
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(performanceGetEntries, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* performance = requirePerformance(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    if (!performance)
        return {};
    return JSValue::encode(
        performance->entriesArray(global_object, [](const JSColloPerformanceEntry&) { return true; }));
}

JSC_DEFINE_HOST_FUNCTION(performanceGetEntriesByName, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* performance = requirePerformance(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    if (!performance)
        return {};
    if (!requireArgumentCount(global_object, scope, call_frame, 1, "performance.getEntriesByName requires a name"_s))
        return {};

    auto name = argumentToWebApiString(global_object, scope, call_frame, 0);
    RETURN_IF_EXCEPTION(scope, {});
    std::optional<String> type;
    if (!call_frame->argument(1).isUndefined()) {
        type = valueToWebApiString(global_object, scope, call_frame->argument(1));
        RETURN_IF_EXCEPTION(scope, {});
    }
    return JSValue::encode(performance->entriesArray(global_object, [&](const JSColloPerformanceEntry& entry) {
        return entry.name() == name && (!type || entry.entryType() == *type);
    }));
}

JSC_DEFINE_HOST_FUNCTION(performanceGetEntriesByType, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* performance = requirePerformance(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    if (!performance)
        return {};
    if (!requireArgumentCount(
            global_object, scope, call_frame, 1, "performance.getEntriesByType requires an entry type"_s))
        return {};

    auto type = argumentToWebApiString(global_object, scope, call_frame, 0);
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(performance->entriesArray(
        global_object, [&](const JSColloPerformanceEntry& entry) { return entry.entryType() == type; }));
}

static JSC::JSFunction* createPerformanceConstructor(JSC::JSGlobalObject* global_object, JSC::VM& vm)
{
    auto* constructor = JSC::JSFunction::create(vm, global_object, 0, "Performance"_s, performanceConstructorCall,
        JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, performanceConstructorConstruct, nullptr);
    RELEASE_ASSERT(constructor);
    return constructor;
}

static JSC::JSFunction* createPerformanceEntryConstructor(JSC::JSGlobalObject* global_object, JSC::VM& vm,
    WTF::ASCIILiteral name, unsigned length, JSC::NativeFunction call, JSC::NativeFunction construct)
{
    auto* constructor = JSC::JSFunction::create(vm, global_object, length, name, call,
        JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, construct, nullptr);
    RELEASE_ASSERT(constructor);
    return constructor;
}

bool webApiPerformanceTargetHandle(JSC::JSValue value, WebApiEventTargetHandle& handle)
{
    if (auto* performance = dynamicDowncast<JSColloPerformance>(value)) {
        if (auto* global_object = performance->realm())
            performance->ensureTimeOriginForAccess();
        handle.object = performance;
        handle.listener_owner = performance;
        handle.data = &performance->eventTargetData();
        return true;
    }
    return false;
}

// Releases what worker-wide objects hold for `request_id` once that request ends: the object URLs it created, the GC
// roots of its native holders and its console output budget. Each step touches only this request's share, because a
// request co-scheduled on the same worker may still be running. The performance timeline is the worker's, so nothing
// in it is released here.
extern "C" ColloStatus collo_webapi_cleanup_request(ColloVm* vm, uint64_t request_id)
{
    if (!vm || !vm->isReady() || !request_id)
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    vm->blob_object_urls.removeOwnedBy(request_id);
    // Native objects that root this request's JS graphs, such as a body consumer whose ReadableStream never settled,
    // cannot be reclaimed by the collector; without this they would live as long as the worker.
    // ColloRequestScopedRoots in state.h explains why.
    vm->request_scoped_roots.clearOwnedBy(request_id);
    // The budget is the `request_lines_max` and `request_bytes_max` pair given to `collo_vm_set_console_sink`.
    if (vm->console_client)
        vm->console_client->clearRequestOutputBudget(request_id);
    return COLLO_STATUS_OK;
}

void installWebApiPerformance(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    constexpr unsigned enumerableAccessor = static_cast<unsigned>(JSC::PropertyAttribute::Accessor);
    constexpr unsigned enumerableFunction = static_cast<unsigned>(JSC::PropertyAttribute::None);

    auto* entry_prototype = JSC::constructEmptyObject(global_object);
    putWebApiAccessor(
        global_object, entry_prototype, vm, "name"_s, performanceEntryGetName, nullptr, enumerableAccessor);
    putWebApiAccessor(
        global_object, entry_prototype, vm, "entryType"_s, performanceEntryGetEntryType, nullptr, enumerableAccessor);
    putWebApiAccessor(
        global_object, entry_prototype, vm, "startTime"_s, performanceEntryGetStartTime, nullptr, enumerableAccessor);
    putWebApiAccessor(
        global_object, entry_prototype, vm, "duration"_s, performanceEntryGetDuration, nullptr, enumerableAccessor);
    putWebApiFunction(global_object, entry_prototype, vm, "toJSON"_s, 0, performanceEntryToJSON, enumerableFunction);
    entry_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::String("PerformanceEntry"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* entry_constructor = createPerformanceEntryConstructor(global_object, vm, "PerformanceEntry"_s, 0,
        performanceEntryConstructorCall, performanceEntryConstructorConstruct);
    entry_constructor->putDirect(vm, vm.propertyNames->prototype, entry_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    entry_prototype->putDirect(
        vm, vm.propertyNames->constructor, entry_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    auto* mark_prototype = JSC::constructEmptyObject(global_object);
    mark_prototype->setPrototype(vm, global_object, entry_prototype, true);
    putWebApiAccessor(
        global_object, mark_prototype, vm, "detail"_s, performanceEntryGetDetail, nullptr, enumerableAccessor);
    mark_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::String("PerformanceMark"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* mark_constructor = createPerformanceEntryConstructor(
        global_object, vm, "PerformanceMark"_s, 1, performanceMarkConstructorCall, performanceMarkConstructorConstruct);
    mark_constructor->setPrototype(vm, global_object, entry_constructor, true);
    mark_constructor->putDirect(vm, vm.propertyNames->prototype, mark_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    mark_prototype->putDirect(
        vm, vm.propertyNames->constructor, mark_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    auto* measure_prototype = JSC::constructEmptyObject(global_object);
    measure_prototype->setPrototype(vm, global_object, entry_prototype, true);
    putWebApiAccessor(
        global_object, measure_prototype, vm, "detail"_s, performanceEntryGetDetail, nullptr, enumerableAccessor);
    measure_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::String("PerformanceMeasure"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* measure_constructor = createPerformanceEntryConstructor(global_object, vm, "PerformanceMeasure"_s, 0,
        performanceMeasureConstructorCall, performanceMeasureConstructorConstruct);
    measure_constructor->setPrototype(vm, global_object, entry_constructor, true);
    measure_constructor->putDirect(vm, vm.propertyNames->prototype, measure_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    measure_prototype->putDirect(vm, vm.propertyNames->constructor, measure_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    auto* observer_entry_list_prototype = JSC::constructEmptyObject(global_object);
    putWebApiFunction(global_object, observer_entry_list_prototype, vm, "getEntries"_s, 0,
        performanceObserverEntryListGetEntries, enumerableFunction);
    putWebApiFunction(global_object, observer_entry_list_prototype, vm, "getEntriesByType"_s, 1,
        performanceObserverEntryListGetEntriesByType, enumerableFunction);
    putWebApiFunction(global_object, observer_entry_list_prototype, vm, "getEntriesByName"_s, 1,
        performanceObserverEntryListGetEntriesByName, enumerableFunction);
    observer_entry_list_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::String("PerformanceObserverEntryList"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* observer_entry_list_constructor
        = createPerformanceEntryConstructor(global_object, vm, "PerformanceObserverEntryList"_s, 0,
            performanceObserverEntryListConstructorCall, performanceObserverEntryListConstructorConstruct);
    observer_entry_list_constructor->putDirect(vm, vm.propertyNames->prototype, observer_entry_list_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    observer_entry_list_prototype->putDirect(vm, vm.propertyNames->constructor, observer_entry_list_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    auto* observer_prototype = JSC::constructEmptyObject(global_object);
    putWebApiFunction(
        global_object, observer_prototype, vm, "observe"_s, 0, performanceObserverObserve, enumerableFunction);
    putWebApiFunction(
        global_object, observer_prototype, vm, "disconnect"_s, 0, performanceObserverDisconnect, enumerableFunction);
    putWebApiFunction(
        global_object, observer_prototype, vm, "takeRecords"_s, 0, performanceObserverTakeRecords, enumerableFunction);
    observer_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::String("PerformanceObserver"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* observer_constructor = createPerformanceEntryConstructor(global_object, vm, "PerformanceObserver"_s, 1,
        performanceObserverConstructorCall, performanceObserverConstructorConstruct);
    observer_constructor->putDirect(vm, vm.propertyNames->prototype, observer_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    observer_prototype->putDirect(vm, vm.propertyNames->constructor, observer_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    putWebApiAccessor(global_object, observer_constructor, vm, "supportedEntryTypes"_s,
        performanceObserverSupportedEntryTypes, nullptr, static_cast<unsigned>(JSC::PropertyAttribute::Accessor));

    auto* timing_prototype = JSC::constructEmptyObject(global_object);
    for (auto key : performance_timing_keys)
        putWebApiAccessor(global_object, timing_prototype, vm, key, performanceTimingZero, nullptr, enumerableAccessor);
    putWebApiFunction(global_object, timing_prototype, vm, "toJSON"_s, 0, performanceTimingToJSON, enumerableFunction);
    timing_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::String("PerformanceTiming"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* timing_constructor = createPerformanceEntryConstructor(global_object, vm, "PerformanceTiming"_s, 0,
        performanceTimingConstructorCall, performanceTimingConstructorConstruct);
    timing_constructor->putDirect(vm, vm.propertyNames->prototype, timing_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    timing_prototype->putDirect(
        vm, vm.propertyNames->constructor, timing_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    auto* timing_structure = JSColloPerformanceTiming::createStructure(vm, global_object, timing_prototype);
    auto* timing = JSColloPerformanceTiming::create(vm, timing_structure);

    auto* prototype = JSC::constructEmptyObject(global_object, global_object->eventTargetPrototype());
    putWebApiAccessor(
        global_object, prototype, vm, "timeOrigin"_s, performanceGetTimeOrigin, nullptr, enumerableAccessor);
    putWebApiAccessor(global_object, prototype, vm, "timing"_s, performanceGetTiming, nullptr, enumerableAccessor);
    putWebApiAccessor(global_object, prototype, vm, "onresourcetimingbufferfull"_s,
        performanceGetOnResourceTimingBufferFull, performanceSetOnResourceTimingBufferFull, enumerableAccessor);
    putWebApiFunction(global_object, prototype, vm, "now"_s, 0, performanceNow, enumerableFunction);
    putWebApiFunction(global_object, prototype, vm, "toJSON"_s, 0, performanceToJSON, enumerableFunction);
    putWebApiFunction(global_object, prototype, vm, "getEntries"_s, 0, performanceGetEntries, enumerableFunction);
    putWebApiFunction(
        global_object, prototype, vm, "getEntriesByType"_s, 1, performanceGetEntriesByType, enumerableFunction);
    putWebApiFunction(
        global_object, prototype, vm, "getEntriesByName"_s, 1, performanceGetEntriesByName, enumerableFunction);
    putWebApiFunction(
        global_object, prototype, vm, "clearResourceTimings"_s, 0, performanceClearResourceTimings, enumerableFunction);
    putWebApiFunction(global_object, prototype, vm, "setResourceTimingBufferSize"_s, 1,
        performanceSetResourceTimingBufferSize, enumerableFunction);
    putWebApiFunction(global_object, prototype, vm, "mark"_s, 1, performanceMark, enumerableFunction);
    putWebApiFunction(global_object, prototype, vm, "clearMarks"_s, 0, performanceClearMarks, enumerableFunction);
    putWebApiFunction(global_object, prototype, vm, "measure"_s, 1, performanceMeasure, enumerableFunction);
    putWebApiFunction(global_object, prototype, vm, "clearMeasures"_s, 0, performanceClearMeasures, enumerableFunction);
    putWebApiFunction(
        global_object, prototype, vm, "markResourceTiming"_s, 7, performanceMarkResourceTiming, enumerableFunction);
    prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol, JSC::jsString(vm, WTF::String("Performance"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* constructor = createPerformanceConstructor(global_object, vm);
    constructor->putDirect(vm, vm.propertyNames->prototype, prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    prototype->putDirect(
        vm, vm.propertyNames->constructor, constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    auto* mark_structure = JSColloPerformanceMark::createStructure(vm, global_object, mark_prototype);
    auto* measure_structure = JSColloPerformanceMeasure::createStructure(vm, global_object, measure_prototype);
    auto* observer_structure = JSColloPerformanceObserver::createStructure(vm, global_object, observer_prototype);
    auto* observer_entry_list_structure
        = JSColloPerformanceObserverEntryList::createStructure(vm, global_object, observer_entry_list_prototype);
    auto* structure = JSColloPerformance::createStructure(vm, global_object, prototype);
    auto* performance = JSColloPerformance::create(
        vm, structure, mark_structure, measure_structure, observer_structure, observer_entry_list_structure, timing);

    global_object->putDirect(vm, JSC::Identifier::fromString(vm, "PerformanceEntry"_s), entry_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    global_object->putDirect(vm, JSC::Identifier::fromString(vm, "PerformanceMark"_s), mark_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    global_object->putDirect(vm, JSC::Identifier::fromString(vm, "PerformanceMeasure"_s), measure_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    global_object->putDirect(vm, JSC::Identifier::fromString(vm, "PerformanceTiming"_s), timing_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    global_object->putDirect(vm, JSC::Identifier::fromString(vm, "PerformanceObserverEntryList"_s),
        observer_entry_list_constructor, static_cast<unsigned>(JSC::PropertyAttribute::None));
    global_object->putDirect(vm, JSC::Identifier::fromString(vm, "PerformanceObserver"_s), observer_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    global_object->putDirect(vm, JSC::Identifier::fromString(vm, "Performance"_s), constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    global_object->putDirect(vm, JSC::Identifier::fromString(vm, "performance"_s), performance,
        static_cast<unsigned>(JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum));
    RELEASE_ASSERT(global_object->getDirect(vm, JSC::Identifier::fromString(vm, "PerformanceEntry"_s)));
    RELEASE_ASSERT(global_object->getDirect(vm, JSC::Identifier::fromString(vm, "PerformanceMark"_s)));
    RELEASE_ASSERT(global_object->getDirect(vm, JSC::Identifier::fromString(vm, "PerformanceMeasure"_s)));
    RELEASE_ASSERT(global_object->getDirect(vm, JSC::Identifier::fromString(vm, "PerformanceTiming"_s)));
    RELEASE_ASSERT(global_object->getDirect(vm, JSC::Identifier::fromString(vm, "PerformanceObserverEntryList"_s)));
    RELEASE_ASSERT(global_object->getDirect(vm, JSC::Identifier::fromString(vm, "PerformanceObserver"_s)));
    RELEASE_ASSERT(global_object->getDirect(vm, JSC::Identifier::fromString(vm, "Performance"_s)));
    RELEASE_ASSERT(global_object->getDirect(vm, JSC::Identifier::fromString(vm, "performance"_s)));
}

} // namespace Collo::HostFunctions
