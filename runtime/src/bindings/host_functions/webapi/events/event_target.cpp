// EventTarget's methods, and listener registration and dispatch for every event target the runtime implements, all
// reached through WebApiEventTargetHandle. VM thread only.
//
// The global object stores no listeners of its own; its handle points at the EventTarget cell that installWebApiEvent
// creates for it. A dispatch walks a snapshot of the matching listeners and checks each one against the live vector
// by its order before calling it, so a listener removed by an earlier one does not run and one added during the
// dispatch waits for the next event, as the DOM standard's invoke and inner invoke require.

#include "host_functions/webapi/events/event_private.h"

#include "host_functions/webapi/events/abort.h"
#include "host_functions/webapi/dom/dom_exception.h"
#include "host_functions/webapi/messaging/message_channel.h"
#include "host_functions/webapi/platform/performance.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <wtf/HashSet.h>
#include <wtf/Locker.h>
#include <wtf/Scope.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

#include <limits>
#include <optional>

namespace Collo::HostFunctions {

using JSC::EncodedJSValue;
using JSC::JSValue;
using WTF::String;
using namespace JSC;

const JSC::ClassInfo JSColloEventTarget::s_info
    = { "EventTarget"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloEventTarget) };

template <typename Visitor> void JSColloEventTarget::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloEventTarget*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    // The cell lock keeps the listener vector buffer stable while the
    // concurrent marker walks it; mutators take the same lock around
    // buffer-moving operations (see listenerOwnerCell call sites).
    WTF::Locker locker { this_object->cellLock() };
    this_object->m_event_target.visitChildren(visitor);
}

DEFINE_VISIT_CHILDREN(JSColloEventTarget);

static std::optional<WebApiEventTargetHandle> requireEventTargetHandle(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    WebApiEventTargetHandle handle;
    if (webApiEventTargetHandle(value, handle))
        return handle;
    JSC::throwVMTypeError(global_object, scope, "EventTarget method called on incompatible receiver"_s);
    return std::nullopt;
}

static bool requireArgumentCount(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame,
    unsigned count, WTF::ASCIILiteral message)
{
    if (call_frame->argumentCount() >= count)
        return true;
    JSC::throwVMTypeError(global_object, scope, message);
    return false;
}

static JSC::Structure* eventTargetStructureForNewTarget(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame)
{
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto* new_target = call_frame->newTarget().getObject();
    auto* constructor = call_frame->jsCallee();
    if (!new_target || new_target == constructor)
        return collo_global->eventTargetStructure();
    auto* structure = JSC::InternalFunction::createSubclassStructure(
        global_object, new_target, collo_global->eventTargetStructure());
    RETURN_IF_EXCEPTION(scope, nullptr);
    return structure;
}

static std::optional<WebApiEventListenerOptions> parseOptions(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue options_value, bool include_more)
{
    WebApiEventListenerOptions options;
    if (options_value.isUndefinedOrNull())
        return options;
    if (options_value.isBoolean()) {
        options.capture = options_value.toBoolean(global_object);
        return options;
    }
    auto* object = dynamicDowncast<JSC::JSObject>(options_value);
    if (!object)
        return options;

    auto& vm = global_object->vm();
    auto capture = object->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "capture"_s));
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (capture)
        options.capture = capture.toBoolean(global_object);

    if (!include_more)
        return options;

    auto once = object->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "once"_s));
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (once)
        options.once = once.toBoolean(global_object);

    auto passive = object->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "passive"_s));
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (passive)
        options.passive = passive.toBoolean(global_object);

    auto signal = object->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "signal"_s));
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (signal && !signal.isUndefined()) {
        // Web IDL: the dictionary member is not nullable, so a present null, or any value that is not an
        // AbortSignal, is a TypeError; undefined means the member is absent.
        if (!webApiAbortSignalFromValue(signal)) {
            JSC::throwVMTypeError(global_object, scope, "EventTarget signal option must be an AbortSignal"_s);
            return std::nullopt;
        }
        options.signal = signal;
    }

    return options;
}

static bool isValidListener(JSValue listener)
{
    if (listener.isUndefinedOrNull())
        return true;
    if (JSC::getCallData(listener).type != JSC::CallData::Type::None)
        return true;
    return listener.isObject();
}

static bool sameCallback(JSValue left, JSValue right) { return JSC::JSValue::strictEqual(nullptr, left, right); }

// The cell whose visitChildren walks this handle's listener vector; its
// cellLock() guards the vector buffer against the concurrent marker.
static JSC::JSCell* listenerOwnerCell(const WebApiEventTargetHandle& target)
{
    return target.listener_owner ? target.listener_owner : target.object;
}

struct EventListenerDispatchSnapshot {
    String type;
    // Strong: past eight entries the snapshot buffer is on the heap, out of the conservative stack scan's reach.
    JSC::Strong<JSC::Unknown> callback;
    uint64_t order { 0 };
    bool once { false };
    bool passive { false };
};

static void unlinkAbortCleanupForListener(
    JSC::JSObject* target_object, const String& type, const WebApiEventListenerRecord& listener)
{
    if (!target_object || !listener.has_signal)
        return;
    auto* signal = webApiAbortSignalFromValue(listener.signal.get());
    if (!signal)
        return;
    signal->removeEventTargetCleanup(target_object, type, listener.callback.get(), listener.capture);
}

static void removeMatchingListener(
    const WebApiEventTargetHandle& target, const String& type, JSValue callback, bool capture)
{
    auto& listeners = target.data->listeners();
    for (unsigned index = 0; index < listeners.size(); index++) {
        auto& listener = listeners[index];
        if (listener.removed)
            continue;
        if (listener.attribute_handler)
            continue;
        if (listener.capture == capture && listener.type == type && sameCallback(listener.callback.get(), callback)) {
            unlinkAbortCleanupForListener(target.object, type, listener);
            target.data->markRemoved(index);
            break;
        }
    }
    {
        WTF::Locker locker { listenerOwnerCell(target)->cellLock() };
        target.data->compactRemovedIfIdle();
    }
}

static EncodedJSValue callListener(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* target,
    JSValue listener, JSValue event_value)
{
    auto& vm = global_object->vm();
    auto call_data = JSC::getCallData(listener);
    if (call_data.type != JSC::CallData::Type::None) {
        auto* listener_global_object = listener.getObject()->realm();
        JSC::MarkedArgumentBuffer arguments;
        arguments.append(event_value.toThis(listener_global_object, JSC::ECMAMode::strict()));
        if (arguments.hasOverflowed())
            return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
        JSC::call(listener_global_object, listener, call_data,
            JSValue(target).toThis(listener_global_object, JSC::ECMAMode::strict()), arguments);
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsUndefined());
    }

    auto* object = listener.getObject();
    if (!object)
        return JSValue::encode(JSC::jsUndefined());

    auto handle_event = object->get(global_object, JSC::Identifier::fromString(vm, "handleEvent"_s));
    RETURN_IF_EXCEPTION(scope, {});
    auto handle_call_data = JSC::getCallData(handle_event);
    if (handle_call_data.type == JSC::CallData::Type::None)
        return JSValue::encode(JSC::jsUndefined());

    auto* handle_global_object = handle_event.getObject()->realm();
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(event_value.toThis(handle_global_object, JSC::ECMAMode::strict()));
    if (arguments.hasOverflowed())
        return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
    JSC::call(handle_global_object, handle_event, handle_call_data,
        JSValue(object).toThis(handle_global_object, JSC::ECMAMode::strict()), arguments);
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(eventTargetConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "EventTarget constructor requires 'new'"_s);
}

JSC_DEFINE_HOST_FUNCTION(
    eventTargetConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* structure = eventTargetStructureForNewTarget(global_object, scope, call_frame);
    RETURN_IF_EXCEPTION(scope, {});
    if (!structure)
        return {};
    return JSValue::encode(JSColloEventTarget::create(vm, structure));
}

static EncodedJSValue addEventListenerToTarget(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSC::CallFrame* call_frame, WebApiEventTargetHandle target, WTF::ASCIILiteral missing_message)
{
    auto& vm = global_object->vm();
    if (!requireArgumentCount(global_object, scope, call_frame, 2, missing_message))
        return {};

    auto type = argumentToWebApiString(global_object, scope, call_frame, 0);
    RETURN_IF_EXCEPTION(scope, {});
    auto listener_value = call_frame->argument(1);
    if (!isValidListener(listener_value))
        return JSC::throwVMTypeError(global_object, scope, "EventTarget listener must be an object or function"_s);
    if (listener_value.isUndefinedOrNull())
        return JSValue::encode(JSC::jsUndefined());

    auto options = parseOptions(global_object, scope, call_frame->argument(2), true);
    RETURN_IF_EXCEPTION(scope, {});
    if (!options)
        return {};

    if (webApiMessagePortIsDetached(JSValue(target.object))) {
        auto* exception
            = createDOMException(global_object, DOMExceptionCode::InvalidStateError, "MessagePort is detached"_s);
        return JSValue::encode(JSC::throwException(global_object, scope, exception));
    }

    JSColloAbortSignal* signal = nullptr;
    if (options->signal) {
        signal = webApiAbortSignalFromValue(options->signal);
        if (!signal)
            return JSC::throwVMTypeError(global_object, scope, "EventTarget signal option must be an AbortSignal"_s);
        if (signal->aborted())
            return JSValue::encode(JSC::jsUndefined());
    }

    for (auto& listener : target.data->listeners()) {
        if (!listener.removed && !listener.attribute_handler && listener.capture == options->capture
            && listener.type == type && sameCallback(listener.callback.get(), listener_value))
            return JSValue::encode(JSC::jsUndefined());
    }
    if (target.data->activeListenerCount() >= WebApiEventTargetMaxListeners) {
        auto* exception = createDOMException(
            global_object, DOMExceptionCode::QuotaExceededError, "EventTarget listener limit exceeded"_s);
        return JSValue::encode(JSC::throwException(global_object, scope, exception));
    }

    WebApiEventListenerRecord record;
    record.type = type;
    record.callback.set(vm, target.listener_owner ? target.listener_owner : target.object, listener_value);
    record.order = target.data->allocateListenerOrder();
    record.capture = options->capture;
    record.once = options->once;
    record.passive = options->passive;
    if (signal) {
        record.signal.set(vm, target.listener_owner ? target.listener_owner : target.object, signal);
        record.has_signal = true;
    }
    bool listener_appended = false;
    {
        // The append may move the buffer the concurrent marker walks.
        WTF::Locker locker { listenerOwnerCell(target)->cellLock() };
        listener_appended = target.data->listeners().tryAppend(WTF::move(record));
        if (listener_appended)
            target.data->noteListenerAppended();
    }
    if (!listener_appended)
        return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
    webApiMessagePortDidAddListener(target, type);
    if (signal && !signal->addEventTargetCleanup(vm, target.object, type, listener_value, options->capture)) {
        // Without its cleanup record the signal's abort could not remove the listener, so the listener is removed
        // again before the out-of-memory error is thrown.
        removeMatchingListener(target, type, listener_value, options->capture);
        return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
    }
    return JSValue::encode(JSC::jsUndefined());
}

static EncodedJSValue removeEventListenerFromTarget(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSC::CallFrame* call_frame, WebApiEventTargetHandle target, WTF::ASCIILiteral missing_message)
{
    if (!requireArgumentCount(global_object, scope, call_frame, 2, missing_message))
        return {};

    auto type = argumentToWebApiString(global_object, scope, call_frame, 0);
    RETURN_IF_EXCEPTION(scope, {});
    auto listener_value = call_frame->argument(1);
    if (listener_value.isUndefinedOrNull())
        return JSValue::encode(JSC::jsUndefined());
    if (!isValidListener(listener_value))
        return JSC::throwVMTypeError(global_object, scope, "EventTarget listener must be an object or function"_s);

    auto options = parseOptions(global_object, scope, call_frame->argument(2), false);
    RETURN_IF_EXCEPTION(scope, {});
    if (!options)
        return {};
    removeMatchingListener(target, type, listener_value, options->capture);
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(eventTargetAddEventListener, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto target = requireEventTargetHandle(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    if (!target)
        return {};
    return addEventListenerToTarget(
        global_object, scope, call_frame, *target, "EventTarget.addEventListener requires a type and listener"_s);
}

JSC_DEFINE_HOST_FUNCTION(
    eventTargetRemoveEventListener, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto target = requireEventTargetHandle(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    if (!target)
        return {};
    return removeEventListenerFromTarget(
        global_object, scope, call_frame, *target, "EventTarget.removeEventListener requires a type and listener"_s);
}

JSC_DEFINE_HOST_FUNCTION(eventTargetDispatchEvent, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto target = requireEventTargetHandle(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    if (!target)
        return {};
    if (!requireArgumentCount(global_object, scope, call_frame, 1, "EventTarget.dispatchEvent requires an event"_s))
        return {};
    auto event_value = call_frame->argument(0);
    // DOM standard, dispatchEvent() step 2: an event script dispatches is untrusted. Events the runtime dispatches
    // through dispatchWebApiEvent keep their trusted flag.
    if (auto* event = dynamicDowncast<JSColloEvent>(event_value); event && !event->dispatching())
        event->setUntrusted();
    return dispatchWebApiEvent(global_object, scope, *target, event_value);
}

static bool globalEventTargetHandle(JSC::JSGlobalObject* global_object, WebApiEventTargetHandle& handle);

JSC_DEFINE_HOST_FUNCTION(globalAddEventListener, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    WebApiEventTargetHandle target;
    if (!globalEventTargetHandle(global_object, target))
        return JSC::throwVMTypeError(global_object, scope, "Global event target is unavailable"_s);
    return addEventListenerToTarget(
        global_object, scope, call_frame, target, "addEventListener requires a type and listener"_s);
}

JSC_DEFINE_HOST_FUNCTION(globalRemoveEventListener, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    WebApiEventTargetHandle target;
    if (!globalEventTargetHandle(global_object, target))
        return JSC::throwVMTypeError(global_object, scope, "Global event target is unavailable"_s);
    return removeEventListenerFromTarget(
        global_object, scope, call_frame, target, "removeEventListener requires a type and listener"_s);
}

JSC_DEFINE_HOST_FUNCTION(globalDispatchEvent, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (!requireArgumentCount(global_object, scope, call_frame, 1, "dispatchEvent requires an event"_s))
        return {};
    WebApiEventTargetHandle target;
    if (!globalEventTargetHandle(global_object, target))
        return JSC::throwVMTypeError(global_object, scope, "Global event target is unavailable"_s);
    auto event_value = call_frame->argument(0);
    // DOM standard, dispatchEvent() step 2: an event script dispatches is untrusted.
    if (auto* event = dynamicDowncast<JSColloEvent>(event_value); event && !event->dispatching())
        event->setUntrusted();
    return dispatchWebApiEvent(global_object, scope, target, event_value);
}

static JSValue normalizedGlobalEventHandler(JSValue value)
{
    if (value.isUndefinedOrNull() || !value.isObject())
        return JSC::jsNull();
    return value;
}

// The global object is the target script sees, while its listeners live in the cell installWebApiEvent caches.
// Returns false when that cell is missing.
static bool globalEventTargetHandle(JSC::JSGlobalObject* global_object, WebApiEventTargetHandle& handle)
{
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto* global_target
        = dynamicDowncast<JSColloEventTarget>(collo_global->owner().webapi_cache.global_event_target.get());
    if (!global_target)
        return false;
    handle.object = collo_global;
    handle.listener_owner = global_target;
    handle.data = &global_target->eventTargetData();
    return true;
}

JSC_DEFINE_HOST_FUNCTION(globalGetOnError, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto value = collo_global->owner().webapi_cache.global_on_error.get();
    return JSValue::encode(value ? value : JSC::jsNull());
}

JSC_DEFINE_HOST_FUNCTION(globalSetOnError, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    collo_global->owner().webapi_cache.global_on_error.set(vm, normalizedGlobalEventHandler(call_frame->argument(0)));
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(globalGetOnMessage, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto value = collo_global->owner().webapi_cache.global_on_message.get();
    return JSValue::encode(value ? value : JSC::jsNull());
}

JSC_DEFINE_HOST_FUNCTION(globalSetOnMessage, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    collo_global->owner().webapi_cache.global_on_message.set(vm, normalizedGlobalEventHandler(call_frame->argument(0)));
    return JSValue::encode(JSC::jsUndefined());
}

bool webApiEventTargetHandle(JSC::JSValue value, WebApiEventTargetHandle& handle)
{
    if (auto* global = dynamicDowncast<Collo::GlobalObject>(value))
        return globalEventTargetHandle(global, handle);
    if (auto* target = dynamicDowncast<JSColloEventTarget>(value)) {
        handle.object = target;
        handle.listener_owner = target;
        handle.data = &target->eventTargetData();
        return true;
    }
    if (auto* signal = webApiAbortSignalFromValue(value)) {
        handle.object = signal;
        handle.listener_owner = signal;
        handle.data = &signal->eventTargetData();
        return true;
    }
    if (webApiMessagePortTargetHandle(value, handle))
        return true;
    if (webApiPerformanceTargetHandle(value, handle))
        return true;
    return false;
}

void removeWebApiEventTargetListener(
    WebApiEventTargetHandle target, const WTF::String& type, JSC::JSValue callback, bool capture)
{
    if (!target.data)
        return;
    removeMatchingListener(target, type, callback, capture);
}

void removeWebApiEventTargetListener(
    JSC::JSValue target_value, const WTF::String& type, JSC::JSValue callback, bool capture)
{
    WebApiEventTargetHandle target;
    if (!webApiEventTargetHandle(target_value, target))
        return;
    removeWebApiEventTargetListener(target, type, callback, capture);
}

void clearWebApiEventTargetListeners(WebApiEventTargetHandle target)
{
    if (!target.data)
        return;

    WTF::HashSet<JSColloAbortSignal*> signals;
    for (auto& listener : target.data->listeners()) {
        if (listener.removed || !listener.has_signal)
            continue;
        auto* signal = webApiAbortSignalFromValue(listener.signal.get());
        if (!signal)
            continue;
        auto add_result = signals.add(signal);
        if (add_result.isNewEntry)
            signal->removeEventTargetCleanupsForTarget(target.object);
    }
    WTF::Locker locker { listenerOwnerCell(target)->cellLock() };
    target.data->clearListeners();
}

static JSValue globalEventHandler(JSC::JSGlobalObject* global_object, const String& event_type)
{
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto& cache = collo_global->owner().webapi_cache;
    if (event_type == "error"_s)
        return cache.global_on_error.get() ? cache.global_on_error.get() : JSC::jsNull();
    if (event_type == "message"_s)
        return cache.global_on_message.get() ? cache.global_on_message.get() : JSC::jsNull();
    return JSC::jsNull();
}

// Calls the global object's onerror or onmessage handler for an event of that type; returning false cancels the event.
// FIXME: the HTML standard's event handler processing calls a global onerror for an ErrorEvent with (message,
// filename, lineno, colno, error) and cancels when it returns true. This handler also runs before every listener
// regardless of when it was set, and its exception propagates out of the dispatch instead of being reported.
static EncodedJSValue callGlobalEventHandlerIfNeeded(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSColloEvent* event, JSValue event_value)
{
    auto handler = globalEventHandler(global_object, event->type());
    auto call_data = JSC::getCallData(handler);
    if (call_data.type == JSC::CallData::Type::None)
        return JSValue::encode(JSC::jsUndefined());

    auto* handler_global_object = handler.getObject()->realm();
    JSC::MarkedArgumentBuffer arguments;
    arguments.append(event_value.toThis(handler_global_object, JSC::ECMAMode::strict()));
    if (arguments.hasOverflowed())
        return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
    auto result = JSC::call(handler_global_object, handler, call_data,
        JSValue(global_object).toThis(handler_global_object, JSC::ECMAMode::strict()), arguments);
    RETURN_IF_EXCEPTION(scope, {});
    if (result.isFalse())
        event->preventDefault();
    return JSValue::encode(JSC::jsUndefined());
}

JSC::EncodedJSValue dispatchWebApiEvent(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    WebApiEventTargetHandle target, JSC::JSValue event_value)
{
    auto attribute_handler = target.attribute_handler ? target.attribute_handler : JSC::jsNull();
    return dispatchWebApiEventWithAttributeHandler(global_object, scope, target, event_value, attribute_handler,
        target.attribute_order, target.attribute_event_type);
}

JSC::EncodedJSValue dispatchWebApiEventWithAttributeHandler(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    WebApiEventTargetHandle target, JSC::JSValue event_value, JSC::JSValue attribute_handler, uint64_t attribute_order,
    WTF::String attribute_event_type)
{
    auto& vm = global_object->vm();
    auto* event = dynamicDowncast<JSColloEvent>(event_value);
    if (!event)
        return JSC::throwVMTypeError(global_object, scope, "EventTarget.dispatchEvent requires an Event"_s);
    if (event->dispatching()) {
        auto* exception
            = createDOMException(global_object, "Event is already being dispatched"_s, "InvalidStateError"_s);
        return JSC::JSValue::encode(JSC::throwException(global_object, scope, exception));
    }
    if (!attribute_event_type.isNull() && attribute_event_type != event->type())
        attribute_handler = JSC::jsNull();
    else if (!attribute_handler)
        attribute_handler = JSC::jsNull();

    event->startDispatch(vm, target.object);
    target.data->enterDispatch();
    auto leave_dispatch = WTF::makeScopeExit([&] {
        event->finishDispatch();
        // leaveDispatch may compact the buffer the concurrent marker walks.
        WTF::Locker locker { listenerOwnerCell(target)->cellLock() };
        target.data->leaveDispatch();
    });

    bool attribute_called = attribute_handler.isUndefinedOrNull();
    auto call_attribute_handler = [&]() -> bool {
        if (attribute_called)
            return true;
        attribute_called = true;
        callListener(global_object, scope, target.object, attribute_handler, event_value);
        if (scope.exception()) {
            // A throwing listener must not stop the dispatch (DOM standard, inner invoke); only a termination does.
            // FIXME: inner invoke reports the exception. Here, and in the listener loop below, it is cleared without
            // being reported anywhere.
            auto catch_scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
            if (!catch_scope.clearExceptionExceptTermination())
                return false;
        }
        return true;
    };

    if (target.object == global_object) {
        callGlobalEventHandlerIfNeeded(global_object, scope, event, event_value);
        RETURN_IF_EXCEPTION(scope, {});
        if (event->immediatePropagationStopped())
            return JSC::JSValue::encode(JSC::jsBoolean(!event->defaultPrevented()));
    }

    if (attribute_order == WebApiEventAttributeHandlerBeforeListeners) {
        if (!call_attribute_handler())
            return {};
        if (event->immediatePropagationStopped())
            return JSC::JSValue::encode(JSC::jsBoolean(!event->defaultPrevented()));
    }

    WTF::Vector<EventListenerDispatchSnapshot, 8> listeners;
    auto& live_listeners = target.data->listeners();
    listeners.reserveInitialCapacity(live_listeners.size());
    for (unsigned index = 0; index < live_listeners.size(); index++) {
        auto& listener = live_listeners[index];
        if (listener.removed || listener.type != event->type())
            continue;
        EventListenerDispatchSnapshot snapshot;
        snapshot.type = listener.type;
        snapshot.callback.set(vm, listener.callback.get());
        snapshot.order = listener.order;
        snapshot.once = listener.once;
        snapshot.passive = listener.passive;
        listeners.append(WTF::move(snapshot));
    }

    // Finds a snapshot's live record by its `order`, which no other record of the target shares, rather than by a
    // captured index, so a listener added or removed by script cannot make a snapshot alias another record. Returns
    // the live index, or npos when the record was removed or no longer matches the snapshot's type and callback.
    //
    // The live vector and the snapshot are both in ascending order: a new record gets a higher order than any before
    // it and lands at the tail, and compaction keeps the order. A forward cursor that advances with the loop therefore
    // finds most records in O(1), and a record added during the dispatch sits after every snapshot, so the wrapping
    // scan still reaches each live snapshot with a higher order.
    constexpr unsigned npos = std::numeric_limits<unsigned>::max();
    unsigned live_cursor = 0;
    auto findLiveSnapshotListener = [&target, &live_cursor](const EventListenerDispatchSnapshot& snapshot) -> unsigned {
        auto& current_listeners = target.data->listeners();
        const unsigned size = current_listeners.size();
        if (live_cursor > size)
            live_cursor = 0;
        for (unsigned step = 0; step < size; step++) {
            unsigned index = live_cursor + step;
            if (index >= size)
                index -= size;
            auto& listener = current_listeners[index];
            if (listener.order != snapshot.order)
                continue;
            if (listener.removed || listener.type != snapshot.type
                || !sameCallback(listener.callback.get(), snapshot.callback.get()))
                return npos;
            live_cursor = index + 1;
            return index;
        }
        return npos;
    };

    for (auto& snapshot : listeners) {
        // Between resolving live_index and using it, the only script that can run is the attribute handler, so the
        // index is resolved again only after that handler ran.
        unsigned live_index = findLiveSnapshotListener(snapshot);
        if (live_index == npos)
            continue;
        if (!attribute_called && attribute_order < snapshot.order) {
            if (!call_attribute_handler())
                return {};
            if (event->immediatePropagationStopped())
                break;
            live_index = findLiveSnapshotListener(snapshot);
            if (live_index == npos)
                continue;
        }
        if (snapshot.once) {
            auto& listener = target.data->listeners()[live_index];
            unlinkAbortCleanupForListener(target.object, listener.type, listener);
            target.data->markRemoved(live_index);
        }
        event->setPassive(snapshot.passive);
        callListener(global_object, scope, target.object, snapshot.callback.get(), event_value);
        event->setPassive(false);
        if (scope.exception()) {
            // As for the attribute handler above: the remaining listeners still run, and only a termination stops
            // the dispatch.
            auto catch_scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
            if (!catch_scope.clearExceptionExceptTermination())
                return {};
        }
        if (event->immediatePropagationStopped())
            break;
    }

    if (!attribute_called && !event->immediatePropagationStopped()) {
        if (!call_attribute_handler())
            return {};
    }

    return JSC::JSValue::encode(JSC::jsBoolean(!event->defaultPrevented()));
}

} // namespace Collo::HostFunctions
