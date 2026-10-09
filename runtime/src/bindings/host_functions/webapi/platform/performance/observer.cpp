// PerformanceObserver and PerformanceObserverEntryList on the VM thread. An observer registers with the Performance
// cell on its first successful observe() and stays registered until disconnect(); only a registered observer
// receives entries. Delivery takes two microtask hops: the first, queued with the first pending entry, queues the
// second at the back of the microtask queue, and the second calls the callback once with every entry pending by then,
// in a new PerformanceObserverEntryList and with the observer as `this`. Each hop is a JSFunction that carries its
// observer in a non-enumerable property, so a queued hop keeps the observer alive.

#include "host_functions/webapi/platform/performance/private.h"

#include "host_functions/webapi/dom/dom_exception.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/IteratorOperations.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/MicrotaskQueueInlines.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/WTFString.h>

#include <optional>

namespace Collo::HostFunctions {

using JSC::EncodedJSValue;
using JSC::JSValue;
using WTF::String;
using namespace JSC;

static uint8_t maskForEntryType(const String& type)
{
    if (type == "mark"_s)
        return PerformanceObserverTypeMark;
    if (type == "measure"_s)
        return PerformanceObserverTypeMeasure;
    if (type == "resource"_s)
        return PerformanceObserverTypeResource;
    return PerformanceObserverTypeNone;
}

const JSC::ClassInfo JSColloPerformanceObserverEntryList::s_info = { "PerformanceObserverEntryList"_s, &Base::s_info,
    nullptr, nullptr, CREATE_METHOD_TABLE(JSColloPerformanceObserverEntryList) };
const JSC::ClassInfo JSColloPerformanceObserver::s_info
    = { "PerformanceObserver"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloPerformanceObserver) };

template <typename Visitor>
void JSColloPerformanceObserverEntryList::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloPerformanceObserverEntryList*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    for (auto& entry : this_object->m_entries)
        visitor.append(entry);
}

DEFINE_VISIT_CHILDREN(JSColloPerformanceObserverEntryList);

template <typename Visitor> void JSColloPerformanceObserver::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloPerformanceObserver*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_performance);
    visitor.append(this_object->m_callback);
    for (unsigned index = this_object->m_entries_to_deliver_head; index < this_object->m_entries_to_deliver.size();
        index++) {
        auto& entry = this_object->m_entries_to_deliver[index];
        visitor.append(entry);
    }
}

DEFINE_VISIT_CHILDREN(JSColloPerformanceObserver);

static JSColloPerformanceObserver* requirePerformanceObserver(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value, WTF::ASCIILiteral operation)
{
    if (auto* observer = dynamicDowncast<JSColloPerformanceObserver>(value))
        return observer;
    JSC::throwVMTypeError(global_object, scope,
        WTF::makeString("Can only call PerformanceObserver."_s, operation, " on instances of PerformanceObserver"_s));
    return nullptr;
}

static JSColloPerformanceObserverEntryList* requirePerformanceObserverEntryList(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value, WTF::ASCIILiteral operation)
{
    if (auto* list = dynamicDowncast<JSColloPerformanceObserverEntryList>(value))
        return list;
    JSC::throwVMTypeError(global_object, scope,
        WTF::makeString("Can only call PerformanceObserverEntryList."_s, operation,
            " on instances of PerformanceObserverEntryList"_s));
    return nullptr;
}

static JSC::JSObject* frozenSupportedEntryTypes(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    auto& vm = global_object->vm();
    auto* result = JSC::constructEmptyArray(global_object, nullptr, 3);
    result->putDirectIndex(global_object, 0, JSC::jsString(vm, WTF::String("mark"_s)));
    result->putDirectIndex(global_object, 1, JSC::jsString(vm, WTF::String("measure"_s)));
    result->putDirectIndex(global_object, 2, JSC::jsString(vm, WTF::String("resource"_s)));
    JSC::objectConstructorFreeze(global_object, result);
    RETURN_IF_EXCEPTION(scope, nullptr);
    return result;
}

static std::optional<uint8_t> entryTypeSequenceMask(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    auto* object = dynamicDowncast<JSC::JSObject>(value);
    if (!object) {
        JSC::throwVMTypeError(global_object, scope, "Value is not a sequence"_s);
        return std::nullopt;
    }

    auto iterator_method = JSC::iteratorMethod(global_object, object);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (iterator_method.isUndefinedOrNull()) {
        JSC::throwVMTypeError(global_object, scope, "Value is not a sequence"_s);
        return std::nullopt;
    }

    uint8_t mask = PerformanceObserverTypeNone;
    JSC::forEachInIterable(global_object, value, [&](JSC::VM&, JSC::JSGlobalObject*, JSValue next_value) {
        auto type = valueToWebApiString(global_object, scope, next_value);
        if (scope.exception())
            return;
        mask |= maskForEntryType(type);
    });
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    return mask;
}

void JSColloPerformanceObserver::observe(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue options_value)
{
    auto& vm = global_object->vm();
    if (auto* performance = m_performance.get())
        performance->ensureTimeOriginForAccess();

    JSValue entry_types_value;
    JSValue type_value;
    bool buffered = false;

    if (!options_value.isUndefinedOrNull()) {
        auto* options = dynamicDowncast<JSC::JSObject>(options_value);
        if (!options) {
            JSC::throwVMTypeError(global_object, scope, "Type error"_s);
            return;
        }

        entry_types_value
            = options->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "entryTypes"_s));
        RETURN_IF_EXCEPTION(scope, );
        type_value = options->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "type"_s));
        RETURN_IF_EXCEPTION(scope, );
        auto buffered_value
            = options->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "buffered"_s));
        RETURN_IF_EXCEPTION(scope, );
        if (buffered_value && !buffered_value.isUndefined())
            buffered = buffered_value.toBoolean(global_object);
    }

    const bool has_entry_types = entry_types_value && !entry_types_value.isUndefined();
    const bool has_type = type_value && !type_value.isUndefined();
    if (has_entry_types && has_type) {
        JSC::throwVMTypeError(global_object, scope, "either entryTypes or type must be provided"_s);
        return;
    }

    uint8_t mask = PerformanceObserverTypeNone;
    bool is_type_observer = false;
    String type;
    if (has_entry_types) {
        if (m_registered && m_is_type_observer) {
            auto* exception = createDOMException(global_object, DOMExceptionCode::InvalidModificationError,
                "observer type can't be changed once registered"_s);
            JSC::throwException(global_object, scope, exception);
            return;
        }
        auto parsed_mask = entryTypeSequenceMask(global_object, scope, entry_types_value);
        if (!parsed_mask)
            return;
        mask = *parsed_mask;
        if (mask == PerformanceObserverTypeNone)
            return;
    } else {
        if (!has_type) {
            JSC::throwVMTypeError(global_object, scope, "no type or entryTypes were provided"_s);
            return;
        }
        if (m_registered && !m_is_type_observer) {
            auto* exception = createDOMException(global_object, DOMExceptionCode::InvalidModificationError,
                "observer type can't be changed once registered"_s);
            JSC::throwException(global_object, scope, exception);
            return;
        }
        type = valueToWebApiString(global_object, scope, type_value);
        RETURN_IF_EXCEPTION(scope, );
        mask = maskForEntryType(type);
        if (mask == PerformanceObserverTypeNone)
            return;
        is_type_observer = true;
    }

    // FIXME: the Performance Timeline's observe() replaces an entryTypes observer's types on each call, but the mask
    // keeps the types of earlier calls.
    m_type_mask |= mask;
    m_is_type_observer = is_type_observer;
    if (!m_registered) {
        if (auto* performance = m_performance.get())
            performance->registerObserver(vm, this);
        m_registered = true;
    }

    if (buffered && is_type_observer) {
        if (auto* performance = m_performance.get()) {
            performance->forEachEntry([&](JSColloPerformanceEntry* entry) {
                if (maskForEntryKind(entry->kind()) & mask)
                    queueEntry(global_object, vm, entry);
            });
        }
    }
}

void JSColloPerformanceObserver::disconnect()
{
    if (auto* performance = m_performance.get())
        performance->unregisterObserver(this);
    m_registered = false;
    m_type_mask = PerformanceObserverTypeNone;
    m_is_type_observer = false;
    clearPendingEntries();
}

WTF::Vector<JSColloPerformanceEntry*> JSColloPerformanceObserver::pendingRecordsVector()
{
    WTF::Vector<JSColloPerformanceEntry*> entries;
    entries.reserveInitialCapacity(pendingEntryCount());
    for (unsigned index = m_entries_to_deliver_head; index < m_entries_to_deliver.size(); index++) {
        auto& barrier = m_entries_to_deliver[index];
        if (auto* entry = barrier.get())
            entries.append(entry);
    }
    return entries;
}

JSC::JSObject* JSColloPerformanceObserver::takeRecordsArray(JSC::JSGlobalObject* global_object)
{
    auto entries = pendingRecordsVector();
    std::stable_sort(
        entries.begin(), entries.end(), [](auto* left, auto* right) { return left->startTime() < right->startTime(); });
    auto* result = JSC::constructEmptyArray(global_object, nullptr, entries.size());
    for (unsigned index = 0; index < entries.size(); index++)
        result->putDirectIndex(global_object, index, entries[index]);
    clearPendingEntries();
    return result;
}

static JSC::JSFunction* observerMicrotaskFunction(JSC::JSGlobalObject* global_object, JSC::VM& vm,
    WTF::ASCIILiteral name, JSC::NativeFunction function, JSColloPerformanceObserver* observer)
{
    auto* callback
        = JSC::JSFunction::create(vm, global_object, 0, name, function, JSC::ImplementationVisibility::Public);
    RELEASE_ASSERT(callback);
    callback->putDirect(vm, JSC::Identifier::fromString(vm, "__colloPerformanceObserver"_s), observer,
        static_cast<unsigned>(
            JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontDelete));
    return callback;
}

static JSColloPerformanceObserver* observerFromMicrotaskFunction(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame)
{
    auto& vm = global_object->vm();
    auto* callee = call_frame->jsCallee();
    auto value = callee->getDirect(vm, JSC::Identifier::fromString(vm, "__colloPerformanceObserver"_s));
    auto* observer = dynamicDowncast<JSColloPerformanceObserver>(value);
    if (!observer)
        JSC::throwVMTypeError(global_object, scope, "Invalid PerformanceObserver delivery task"_s);
    return observer;
}

void JSColloPerformanceObserver::scheduleDeliveryIfNeeded(JSC::JSGlobalObject* global_object, JSC::VM& vm)
{
    if (m_delivery_scheduled)
        return;
    m_delivery_scheduled = true;
    auto* schedule = observerMicrotaskFunction(
        global_object, vm, "PerformanceObserver schedule"_s, performanceObserverScheduleMicrotask, this);
    global_object->queueMicrotask(
        vm, JSC::QueuedTask { nullptr, JSC::InternalMicrotask::InvokeFunctionJob, 0, global_object, schedule });
}

void JSColloPerformanceObserver::queueDeliveryMicrotask(JSC::JSGlobalObject* global_object, JSC::VM& vm)
{
    auto* deliver = observerMicrotaskFunction(
        global_object, vm, "PerformanceObserver delivery"_s, performanceObserverDeliverMicrotask, this);
    global_object->queueMicrotask(
        vm, JSC::QueuedTask { nullptr, JSC::InternalMicrotask::InvokeFunctionJob, 0, global_object, deliver });
}

JSC::EncodedJSValue JSColloPerformanceObserver::deliver(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    m_delivery_scheduled = false;
    if (!pendingEntryCount())
        return JSValue::encode(JSC::jsUndefined());

    auto* performance = m_performance.get();
    if (!performance)
        return JSValue::encode(JSC::jsUndefined());

    auto entries = pendingRecordsVector();
    auto* list = JSColloPerformanceObserverEntryList::create(
        global_object->vm(), performance->observerEntryListStructure(), WTF::move(entries));
    clearPendingEntries();
    auto* callback = m_callback.get();
    auto call_data = JSC::getCallData(callback);
    if (call_data.type == JSC::CallData::Type::None)
        return JSValue::encode(JSC::jsUndefined());

    auto* callback_global = callback->realm();
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(list);
    arguments.append(this);
    if (arguments.hasOverflowed())
        return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
    JSC::call(callback_global, callback, call_data, JSValue(this).toThis(callback_global, JSC::ECMAMode::strict()),
        arguments);
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(JSC::jsUndefined());
}

void notifyPerformanceObservers(
    JSC::JSGlobalObject* global_object, JSC::VM& vm, JSColloPerformance& performance, JSColloPerformanceEntry* entry)
{
    performance.forEachObserver([&](JSC::JSObject* object) {
        auto* observer = dynamicDowncast<JSColloPerformanceObserver>(object);
        if (observer && observer->observes(*entry))
            observer->queueEntry(global_object, vm, entry);
    });
}

static JSC::Structure* performanceObserverStructureForNewTarget(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame)
{
    auto* performance = realmPerformance(global_object);
    RELEASE_ASSERT(performance);
    auto* new_target = call_frame->newTarget().getObject();
    auto* constructor = call_frame->jsCallee();
    if (!new_target || new_target == constructor)
        return performance->observerStructure();
    auto* structure
        = JSC::InternalFunction::createSubclassStructure(global_object, new_target, performance->observerStructure());
    RETURN_IF_EXCEPTION(scope, nullptr);
    return structure;
}

JSC_DEFINE_HOST_FUNCTION(performanceObserverConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(
        global_object, scope, "Use `new PerformanceObserver(...)` instead of `PerformanceObserver(...)`"_s);
}

JSC_DEFINE_HOST_FUNCTION(
    performanceObserverConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (!requireArgumentCount(global_object, scope, call_frame, 1, "Not enough arguments"_s))
        return {};

    auto callback_value = call_frame->argument(0);
    auto* callback = dynamicDowncast<JSC::JSObject>(callback_value);
    if (!callback || JSC::getCallData(callback).type == JSC::CallData::Type::None)
        return JSC::throwVMTypeError(global_object, scope,
            "Argument 1 ('callback') to the PerformanceObserver constructor must be a function"_s);

    auto* performance = realmPerformance(global_object);
    RELEASE_ASSERT(performance);
    auto* structure = performanceObserverStructureForNewTarget(global_object, scope, call_frame);
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(JSColloPerformanceObserver::create(vm, structure, performance, callback));
}

JSC_DEFINE_HOST_FUNCTION(
    performanceObserverScheduleMicrotask, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* observer = observerFromMicrotaskFunction(global_object, scope, call_frame);
    RETURN_IF_EXCEPTION(scope, {});
    if (observer)
        observer->queueDeliveryMicrotask(global_object, vm);
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(
    performanceObserverDeliverMicrotask, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* observer = observerFromMicrotaskFunction(global_object, scope, call_frame);
    RETURN_IF_EXCEPTION(scope, {});
    if (!observer)
        return JSValue::encode(JSC::jsUndefined());
    return observer->deliver(global_object, scope);
}

JSC_DEFINE_HOST_FUNCTION(performanceObserverObserve, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* observer = requirePerformanceObserver(global_object, scope, call_frame->thisValue(), "observe"_s);
    RETURN_IF_EXCEPTION(scope, {});
    if (!observer)
        return {};
    observer->observe(global_object, scope, call_frame->argument(0));
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(
    performanceObserverDisconnect, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* observer = requirePerformanceObserver(global_object, scope, call_frame->thisValue(), "disconnect"_s);
    RETURN_IF_EXCEPTION(scope, {});
    if (observer)
        observer->disconnect();
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(
    performanceObserverTakeRecords, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* observer = requirePerformanceObserver(global_object, scope, call_frame->thisValue(), "takeRecords"_s);
    RETURN_IF_EXCEPTION(scope, {});
    if (!observer)
        return {};
    return JSValue::encode(observer->takeRecordsArray(global_object));
}

JSC_DEFINE_HOST_FUNCTION(performanceObserverSupportedEntryTypes, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* result = frozenSupportedEntryTypes(global_object, scope);
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(result);
}

JSC_DEFINE_HOST_FUNCTION(
    performanceObserverEntryListConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope,
        "Use `new PerformanceObserverEntryList(...)` instead of `PerformanceObserverEntryList(...)`"_s);
}

JSC_DEFINE_HOST_FUNCTION(
    performanceObserverEntryListConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope,
        "Use `new PerformanceObserverEntryList(...)` instead of `PerformanceObserverEntryList(...)`"_s);
}

JSC_DEFINE_HOST_FUNCTION(
    performanceObserverEntryListGetEntries, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* list = requirePerformanceObserverEntryList(global_object, scope, call_frame->thisValue(), "getEntries"_s);
    RETURN_IF_EXCEPTION(scope, {});
    if (!list)
        return {};
    return JSValue::encode(list->entriesArray(global_object, [](const JSColloPerformanceEntry&) { return true; }));
}

JSC_DEFINE_HOST_FUNCTION(
    performanceObserverEntryListGetEntriesByType, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* list
        = requirePerformanceObserverEntryList(global_object, scope, call_frame->thisValue(), "getEntriesByType"_s);
    RETURN_IF_EXCEPTION(scope, {});
    if (!list)
        return {};
    if (!requireArgumentCount(global_object, scope, call_frame, 1,
            "PerformanceObserverEntryList.getEntriesByType requires an entry type"_s))
        return {};
    auto type = argumentToWebApiString(global_object, scope, call_frame, 0);
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(list->entriesArray(
        global_object, [&](const JSColloPerformanceEntry& entry) { return entry.entryType() == type; }));
}

JSC_DEFINE_HOST_FUNCTION(
    performanceObserverEntryListGetEntriesByName, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* list
        = requirePerformanceObserverEntryList(global_object, scope, call_frame->thisValue(), "getEntriesByName"_s);
    RETURN_IF_EXCEPTION(scope, {});
    if (!list)
        return {};
    if (!requireArgumentCount(
            global_object, scope, call_frame, 1, "PerformanceObserverEntryList.getEntriesByName requires a name"_s))
        return {};
    auto name = argumentToWebApiString(global_object, scope, call_frame, 0);
    RETURN_IF_EXCEPTION(scope, {});
    std::optional<String> type;
    if (!call_frame->argument(1).isUndefined()) {
        type = valueToWebApiString(global_object, scope, call_frame->argument(1));
        RETURN_IF_EXCEPTION(scope, {});
    }
    return JSValue::encode(list->entriesArray(global_object, [&](const JSColloPerformanceEntry& entry) {
        return entry.name() == name && (!type || entry.entryType() == *type);
    }));
}

} // namespace Collo::HostFunctions
