// The Performance object on the VM thread, the installer for every interface under `performance/`, and
// `collo_webapi_cleanup_request`. `performance` is a plain object, not an EventTarget: no event is ever dispatched at
// it.

#include "host_functions/webapi/platform/performance/private.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSString.h>
#include <wtf/text/WTFString.h>

namespace Collo::HostFunctions {

using JSC::EncodedJSValue;
using JSC::JSValue;
using WTF::String;
using namespace JSC;

const JSC::ClassInfo JSColloPerformance::s_info
    = { "Performance"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloPerformance) };

template <typename Visitor> void JSColloPerformance::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloPerformance*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_mark_structure);
    visitor.append(this_object->m_measure_structure);
    visitor.append(this_object->m_observer_structure);
    visitor.append(this_object->m_observer_entry_list_structure);
    this_object->m_entries.visit(this_object, visitor);
    this_object->m_observers.visit(this_object, visitor);
}

DEFINE_VISIT_CHILDREN(JSColloPerformance);

JSColloPerformance* realmPerformance(JSC::JSGlobalObject* global_object)
{
    auto* collo_global = dynamicDowncast<Collo::GlobalObject>(global_object);
    if (!collo_global)
        return nullptr;
    return dynamicDowncast<JSColloPerformance>(collo_global->webApiCache().performance.get());
}

namespace {

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

    JSC_DEFINE_HOST_FUNCTION(performanceNow, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* performance = requirePerformance(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsNumber(performance->nowMs()));
    }

    JSC_DEFINE_HOST_FUNCTION(
        performanceGetTimeOrigin, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* performance = requirePerformance(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsNumber(performance->timeOriginMs()));
    }

    JSC_DEFINE_HOST_FUNCTION(performanceToJSON, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* performance = requirePerformance(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});

        auto* result = JSC::constructEmptyObject(global_object, global_object->objectPrototype(), 1);
        result->putDirect(
            vm, JSC::Identifier::fromString(vm, "timeOrigin"_s), JSC::jsNumber(performance->timeOriginMs()));
        return JSValue::encode(result);
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

    JSC_DEFINE_HOST_FUNCTION(
        performanceGetEntriesByName, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* performance = requirePerformance(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (!performance)
            return {};
        if (!requireArgumentCount(
                global_object, scope, call_frame, 1, "performance.getEntriesByName requires a name"_s))
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

    JSC_DEFINE_HOST_FUNCTION(
        performanceGetEntriesByType, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
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

    JSC::JSFunction* createPerformanceConstructor(JSC::JSGlobalObject* global_object, JSC::VM& vm,
        WTF::ASCIILiteral name, unsigned length, JSC::NativeFunction call, JSC::NativeFunction construct)
    {
        auto* constructor = JSC::JSFunction::create(vm, global_object, length, name, call,
            JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, construct, nullptr);
        RELEASE_ASSERT(constructor);
        return constructor;
    }

} // namespace

// Releases what the VM holds for `request_id` once that request ends: its console output budget. A request
// co-scheduled on the same worker may still be running, so only this request's share is touched. A realm's
// performance timeline belongs to the realm rather than to a request, so nothing in it is released here.
extern "C" ColloStatus collo_webapi_cleanup_request(ColloVm* vm, uint64_t request_id)
{
    if (!vm || !vm->isReady() || !request_id)
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
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

    auto* entry_constructor = createPerformanceConstructor(global_object, vm, "PerformanceEntry"_s, 0,
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

    auto* mark_constructor = createPerformanceConstructor(
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

    auto* measure_constructor = createPerformanceConstructor(global_object, vm, "PerformanceMeasure"_s, 0,
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
        = createPerformanceConstructor(global_object, vm, "PerformanceObserverEntryList"_s, 0,
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

    auto* observer_constructor = createPerformanceConstructor(global_object, vm, "PerformanceObserver"_s, 1,
        performanceObserverConstructorCall, performanceObserverConstructorConstruct);
    observer_constructor->putDirect(vm, vm.propertyNames->prototype, observer_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    observer_prototype->putDirect(vm, vm.propertyNames->constructor, observer_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    putWebApiAccessor(global_object, observer_constructor, vm, "supportedEntryTypes"_s,
        performanceObserverSupportedEntryTypes, nullptr, static_cast<unsigned>(JSC::PropertyAttribute::Accessor));

    auto* prototype = JSC::constructEmptyObject(global_object);
    putWebApiAccessor(
        global_object, prototype, vm, "timeOrigin"_s, performanceGetTimeOrigin, nullptr, enumerableAccessor);
    putWebApiFunction(global_object, prototype, vm, "now"_s, 0, performanceNow, enumerableFunction);
    putWebApiFunction(global_object, prototype, vm, "toJSON"_s, 0, performanceToJSON, enumerableFunction);
    putWebApiFunction(global_object, prototype, vm, "getEntries"_s, 0, performanceGetEntries, enumerableFunction);
    putWebApiFunction(
        global_object, prototype, vm, "getEntriesByType"_s, 1, performanceGetEntriesByType, enumerableFunction);
    putWebApiFunction(
        global_object, prototype, vm, "getEntriesByName"_s, 1, performanceGetEntriesByName, enumerableFunction);
    putWebApiFunction(global_object, prototype, vm, "mark"_s, 1, performanceMark, enumerableFunction);
    putWebApiFunction(global_object, prototype, vm, "clearMarks"_s, 0, performanceClearMarks, enumerableFunction);
    putWebApiFunction(global_object, prototype, vm, "measure"_s, 1, performanceMeasure, enumerableFunction);
    putWebApiFunction(global_object, prototype, vm, "clearMeasures"_s, 0, performanceClearMeasures, enumerableFunction);
    prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol, JSC::jsString(vm, WTF::String("Performance"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* constructor = createPerformanceConstructor(
        global_object, vm, "Performance"_s, 0, performanceConstructorCall, performanceConstructorConstruct);
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
        vm, structure, mark_structure, measure_structure, observer_structure, observer_entry_list_structure);

    // Web IDL defines interface objects as non-enumerable properties of the global object.
    constexpr unsigned interface_attributes = static_cast<unsigned>(JSC::PropertyAttribute::DontEnum);
    global_object->putDirect(
        vm, JSC::Identifier::fromString(vm, "PerformanceEntry"_s), entry_constructor, interface_attributes);
    global_object->putDirect(
        vm, JSC::Identifier::fromString(vm, "PerformanceMark"_s), mark_constructor, interface_attributes);
    global_object->putDirect(
        vm, JSC::Identifier::fromString(vm, "PerformanceMeasure"_s), measure_constructor, interface_attributes);
    global_object->putDirect(vm, JSC::Identifier::fromString(vm, "PerformanceObserverEntryList"_s),
        observer_entry_list_constructor, interface_attributes);
    global_object->putDirect(
        vm, JSC::Identifier::fromString(vm, "PerformanceObserver"_s), observer_constructor, interface_attributes);
    global_object->putDirect(vm, JSC::Identifier::fromString(vm, "Performance"_s), constructor, interface_attributes);
    global_object->putDirect(vm, JSC::Identifier::fromString(vm, "performance"_s), performance,
        static_cast<unsigned>(JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum));
    // Script can delete or redefine the configurable `performance` property, so the constructors that record into
    // this realm's timeline find it through the cache, never through the property.
    global_object->webApiCache().performance.set(vm, performance);
    RELEASE_ASSERT(global_object->getDirect(vm, JSC::Identifier::fromString(vm, "PerformanceEntry"_s)));
    RELEASE_ASSERT(global_object->getDirect(vm, JSC::Identifier::fromString(vm, "PerformanceMark"_s)));
    RELEASE_ASSERT(global_object->getDirect(vm, JSC::Identifier::fromString(vm, "PerformanceMeasure"_s)));
    RELEASE_ASSERT(global_object->getDirect(vm, JSC::Identifier::fromString(vm, "PerformanceObserverEntryList"_s)));
    RELEASE_ASSERT(global_object->getDirect(vm, JSC::Identifier::fromString(vm, "PerformanceObserver"_s)));
    RELEASE_ASSERT(global_object->getDirect(vm, JSC::Identifier::fromString(vm, "Performance"_s)));
    RELEASE_ASSERT(global_object->getDirect(vm, JSC::Identifier::fromString(vm, "performance"_s)));
}

} // namespace Collo::HostFunctions
