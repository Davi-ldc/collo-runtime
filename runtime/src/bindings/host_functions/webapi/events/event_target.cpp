// EventTarget's interface and methods, the global object's event members, and listener registration, event handler
// attributes, dispatch and exception reporting for every event target the runtime implements, all reached through
// WebApiEventTargetHandle. VM thread only.
//
// The global object stores no listeners of its own; its handle points at the EventTarget cell that
// installEventTargetInterface creates for it and keeps in the realm cache. A dispatch walks a snapshot of the matching
// records and checks each one against the live list by its order before calling it, so a listener removed by an
// earlier one does not run and one added during the dispatch waits for the next event, as the DOM standard's invoke
// and inner invoke require. An event handler record is called with its value at that moment, since replacing a
// handler changes the record in place.

#include "host_functions/webapi/events/event_private.h"

#include "host_functions/webapi/dom/dom_exception.h"
#include "host_functions/webapi/events/abort.h"
#include "host_functions/webapi/messaging/message_channel.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/ErrorInstance.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/MarkedVector.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <wtf/Scope.h>
#include <wtf/Vector.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/WTFString.h>

#include <algorithm>
#include <functional>
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
    this_object->m_event_target.visit(this_object, visitor);
}

DEFINE_VISIT_CHILDREN(JSColloEventTarget);

namespace {

    // The global object is the target script sees, while its listeners live in the cell installEventTargetInterface
    // caches. Returns false when that cell is missing.
    bool globalEventTargetHandle(Collo::GlobalObject* global_object, WebApiEventTargetHandle& handle)
    {
        auto* global_target
            = dynamicDowncast<JSColloEventTarget>(global_object->webApiCache().global_event_target.get());
        if (!global_target)
            return false;
        handle.object = global_object;
        handle.listener_owner = global_target;
        handle.data = &global_target->eventTargetData();
        return true;
    }

    std::optional<WebApiEventTargetHandle> requireEventTargetHandle(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
    {
        WebApiEventTargetHandle handle;
        if (webApiEventTargetHandle(value, handle))
            return handle;
        JSC::throwVMTypeError(global_object, scope, "EventTarget method called on incompatible receiver"_s);
        return std::nullopt;
    }

    // The handle of the realm's own global object, whatever `this` the global event methods were called with.
    std::optional<WebApiEventTargetHandle> requireGlobalEventTargetHandle(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
    {
        WebApiEventTargetHandle handle;
        if (globalEventTargetHandle(uncheckedDowncast<Collo::GlobalObject>(global_object), handle))
            return handle;
        JSC::throwVMTypeError(global_object, scope, "Global event target is unavailable"_s);
        return std::nullopt;
    }

    bool requireArgumentCount(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame,
        unsigned count, WTF::ASCIILiteral message)
    {
        if (call_frame->argumentCount() >= count)
            return true;
        JSC::throwVMTypeError(global_object, scope, message);
        return false;
    }

    JSC::Structure* eventTargetStructureForNewTarget(
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

    std::optional<WebApiEventListenerOptions> parseOptions(
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

    bool isValidListener(JSValue listener)
    {
        if (listener.isUndefinedOrNull())
            return true;
        if (JSC::getCallData(listener).type != JSC::CallData::Type::None)
            return true;
        return listener.isObject();
    }

    bool sameCallback(JSValue left, JSValue right) { return JSC::JSValue::strictEqual(nullptr, left, right); }

    // What a dispatch remembers of each matching record. Its callback sits at the same index in a
    // MarkedArgumentBuffer beside the snapshots, which roots it while the listeners run.
    struct EventListenerDispatchSnapshot {
        String type;
        uint64_t order { 0 };
        bool once { false };
        bool passive { false };
        bool attribute_handler { false };
    };

    void unlinkAbortCleanupForListener(
        JSC::JSObject* target_object, const String& type, const WebApiEventListenerRecord& listener)
    {
        if (!target_object || !listener.has_signal)
            return;
        auto* signal = webApiAbortSignalFromValue(listener.signal.get());
        if (!signal)
            return;
        signal->removeEventTargetCleanup(target_object, type, listener.callback.get(), listener.capture);
    }

    void removeMatchingListener(
        const WebApiEventTargetHandle& target, const String& type, JSValue callback, bool capture)
    {
        const auto& listeners = target.data->listeners();
        for (size_t index = 0; index < listeners.size(); index++) {
            const auto& listener = listeners.at(index);
            if (listener.removed)
                continue;
            if (listener.attribute_handler)
                continue;
            if (listener.capture == capture && listener.type == type
                && sameCallback(listener.callback.get(), callback)) {
                unlinkAbortCleanupForListener(target.object, type, listener);
                target.data->markRemoved(index);
                break;
            }
        }
        target.data->compactRemovedIfIdle(target.owner());
    }

    // The DOM standard's inner invoke for one listener added with addEventListener: a callable gets the event with the
    // target as `this`, and an object gets its handleEvent method called, looked up at each dispatch.
    void callListener(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* target,
        JSValue listener, JSValue event_value)
    {
        auto& vm = global_object->vm();
        auto call_data = JSC::getCallData(listener);
        if (call_data.type != JSC::CallData::Type::None) {
            auto* listener_global_object = listener.getObject()->realm();
            JSC::MarkedArgumentBuffer arguments;
            arguments.append(event_value.toThis(listener_global_object, JSC::ECMAMode::strict()));
            if (arguments.hasOverflowed()) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return;
            }
            JSC::call(listener_global_object, listener, call_data,
                JSValue(target).toThis(listener_global_object, JSC::ECMAMode::strict()), arguments);
            return;
        }

        auto* object = listener.getObject();
        if (!object)
            return;

        auto handle_event = object->get(global_object, JSC::Identifier::fromString(vm, "handleEvent"_s));
        RETURN_IF_EXCEPTION(scope, void());
        auto handle_call_data = JSC::getCallData(handle_event);
        if (handle_call_data.type == JSC::CallData::Type::None)
            return;

        auto* handle_global_object = handle_event.getObject()->realm();
        JSC::MarkedArgumentBuffer arguments;
        arguments.append(event_value.toThis(handle_global_object, JSC::ECMAMode::strict()));
        if (arguments.hasOverflowed()) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return;
        }
        JSC::call(handle_global_object, handle_event, handle_call_data,
            JSValue(object).toThis(handle_global_object, JSC::ECMAMode::strict()), arguments);
    }

    // HTML's event handler processing algorithm for `handler`, an event handler record's value when its turn comes. A
    // non-callable object does nothing ([LegacyTreatNonObjectAsNull]). The global object's onerror receives an
    // ErrorEvent's message, filename, lineno, colno and error and cancels the event by returning true; every other
    // handler receives the event and cancels it by returning false.
    void callEventHandler(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        const WebApiEventTargetHandle& target, JSColloEvent& event, JSValue event_value, JSValue handler)
    {
        auto call_data = JSC::getCallData(handler);
        if (call_data.type == JSC::CallData::Type::None)
            return;

        auto& vm = global_object->vm();
        auto* handler_global_object = handler.getObject()->realm();
        auto* error_event = dynamicDowncast<JSColloErrorEvent>(&event);
        const bool special_error_handling
            = error_event && error_event->type() == "error"_s && dynamicDowncast<Collo::GlobalObject>(target.object);
        JSC::MarkedArgumentBuffer arguments;
        if (special_error_handling) {
            arguments.append(JSC::jsString(vm, error_event->message()));
            arguments.append(JSC::jsString(vm, error_event->filename()));
            arguments.append(JSC::jsNumber(error_event->lineno()));
            arguments.append(JSC::jsNumber(error_event->colno()));
            arguments.append(error_event->error());
        } else
            arguments.append(event_value.toThis(handler_global_object, JSC::ECMAMode::strict()));
        if (arguments.hasOverflowed()) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return;
        }
        auto result = JSC::call(handler_global_object, handler, call_data,
            JSValue(target.object).toThis(handler_global_object, JSC::ECMAMode::strict()), arguments);
        RETURN_IF_EXCEPTION(scope, void());
        if (special_error_handling ? result.isTrue() : result.isFalse())
            event.preventDefault();
    }

    // Clears the exception a listener or event handler threw and reports it to the global object of the callback's
    // realm, as the DOM standard's inner invoke does. Returns false when a termination stays pending, which ends the
    // dispatch.
    bool clearAndReportListenerException(JSC::VM& vm, JSValue callback)
    {
        auto catch_scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
        JSValue thrown = catch_scope.exception()->value();
        if (!catch_scope.clearExceptionExceptTermination())
            return false;
        if (auto* callback_object = callback.getObject())
            reportWebApiException(callback_object->realm(), thrown);
        return !catch_scope.exception();
    }

    // The ErrorEvent message for a reported value, which HTML leaves to the implementation: an Error's message, an
    // empty string for any other object or a symbol, and the string conversion of any other primitive, which runs no
    // script. A conversion that fails yields an empty message; a termination stays pending for the caller to check.
    String reportMessageFor(JSC::JSGlobalObject* global_object, JSValue value)
    {
        if (auto* object = value.getObject()) {
            if (object->isErrorInstance())
                return uncheckedDowncast<JSC::ErrorInstance>(object)->tryGetMessageForDebugging();
            return emptyString();
        }
        if (value.isSymbol())
            return emptyString();

        auto& vm = global_object->vm();
        auto catch_scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
        auto message = value.toWTFString(global_object);
        if (catch_scope.exception()) {
            (void)catch_scope.clearExceptionExceptTermination();
            return emptyString();
        }
        return message;
    }

    EncodedJSValue addEventListenerToTarget(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
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
                return JSC::throwVMTypeError(
                    global_object, scope, "EventTarget signal option must be an AbortSignal"_s);
            if (signal->aborted())
                return JSValue::encode(JSC::jsUndefined());
        }

        for (auto& listener : target.data->listeners()) {
            if (!listener.removed && !listener.attribute_handler && listener.capture == options->capture
                && listener.type == type && sameCallback(listener.callback.get(), listener_value))
                return JSValue::encode(JSC::jsUndefined());
        }

        WebApiEventListenerRecord record;
        record.type = type;
        record.callback.setWithoutWriteBarrier(listener_value);
        record.order = target.data->allocateListenerOrder();
        record.capture = options->capture;
        record.once = options->once;
        record.passive = options->passive;
        if (signal) {
            record.signal.setWithoutWriteBarrier(signal);
            record.has_signal = true;
        }
        switch (target.data->appendListener(vm, target.owner(), WTF::move(record))) {
        case WebApiEventTargetData::AppendResult::Appended:
            break;
        case WebApiEventTargetData::AppendResult::LimitReached: {
            auto* exception = createDOMException(
                global_object, DOMExceptionCode::QuotaExceededError, "EventTarget listener limit exceeded"_s);
            return JSValue::encode(JSC::throwException(global_object, scope, exception));
        }
        case WebApiEventTargetData::AppendResult::OutOfMemory:
            return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
        }
        if (signal && !signal->addEventTargetCleanup(vm, target.object, type, listener_value, options->capture)) {
            // Without its cleanup record the signal's abort could not remove the listener, so the listener is removed
            // again before the out-of-memory error is thrown.
            removeMatchingListener(target, type, listener_value, options->capture);
            return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
        }
        return JSValue::encode(JSC::jsUndefined());
    }

    EncodedJSValue removeEventListenerFromTarget(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
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

    // DOM standard, dispatchEvent() step 2: an event script dispatches is untrusted. Events the runtime dispatches
    // through dispatchWebApiEvent keep their trusted flag.
    void markScriptDispatchUntrusted(JSValue event_value)
    {
        if (auto* event = dynamicDowncast<JSColloEvent>(event_value); event && !event->dispatching())
            event->setUntrusted();
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

    JSC_DEFINE_HOST_FUNCTION(
        eventTargetAddEventListener, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
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
        return removeEventListenerFromTarget(global_object, scope, call_frame, *target,
            "EventTarget.removeEventListener requires a type and listener"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(
        eventTargetDispatchEvent, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
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
        markScriptDispatchUntrusted(event_value);
        return dispatchWebApiEvent(global_object, scope, *target, event_value);
    }

    JSC_DEFINE_HOST_FUNCTION(globalAddEventListener, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto target = requireGlobalEventTargetHandle(global_object, scope);
        RETURN_IF_EXCEPTION(scope, {});
        if (!target)
            return {};
        return addEventListenerToTarget(
            global_object, scope, call_frame, *target, "addEventListener requires a type and listener"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(
        globalRemoveEventListener, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto target = requireGlobalEventTargetHandle(global_object, scope);
        RETURN_IF_EXCEPTION(scope, {});
        if (!target)
            return {};
        return removeEventListenerFromTarget(
            global_object, scope, call_frame, *target, "removeEventListener requires a type and listener"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(globalDispatchEvent, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        if (!requireArgumentCount(global_object, scope, call_frame, 1, "dispatchEvent requires an event"_s))
            return {};
        auto target = requireGlobalEventTargetHandle(global_object, scope);
        RETURN_IF_EXCEPTION(scope, {});
        if (!target)
            return {};
        auto event_value = call_frame->argument(0);
        markScriptDispatchUntrusted(event_value);
        return dispatchWebApiEvent(global_object, scope, *target, event_value);
    }

    JSC_DEFINE_HOST_FUNCTION(globalGetOnError, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto target = requireGlobalEventTargetHandle(global_object, scope);
        RETURN_IF_EXCEPTION(scope, {});
        if (!target)
            return {};
        return JSValue::encode(webApiEventHandler(*target, "error"_s));
    }

    JSC_DEFINE_HOST_FUNCTION(globalSetOnError, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto target = requireGlobalEventTargetHandle(global_object, scope);
        RETURN_IF_EXCEPTION(scope, {});
        if (!target)
            return {};
        auto stored = setWebApiEventHandler(global_object, scope, *target, "error"_s, call_frame->argument(0));
        RETURN_IF_EXCEPTION(scope, {});
        if (!stored)
            return {};
        return JSValue::encode(JSC::jsUndefined());
    }

} // namespace

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
    return webApiMessagePortTargetHandle(value, handle);
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

    // A signal drops every record of this target in one call, so each signal is called once: the signals are gathered,
    // sorted and deduplicated first. When that list cannot grow, each listener's signal is called instead, which
    // repeats the call for a shared signal but drops the same records.
    auto signal_of = [](const WebApiEventListenerRecord& listener) -> JSColloAbortSignal* {
        if (listener.removed || !listener.has_signal)
            return nullptr;
        return webApiAbortSignalFromValue(listener.signal.get());
    };
    JSC::MarkedVector<JSColloAbortSignal*, 8, WTF::RecordOverflow> signals;
    for (auto& listener : target.data->listeners()) {
        if (auto* signal = signal_of(listener))
            signals.append(signal);
    }
    if (signals.hasOverflowed()) {
        for (auto& listener : target.data->listeners()) {
            if (auto* signal = signal_of(listener))
                signal->removeEventTargetCleanupsForTarget(target.object);
        }
    } else {
        std::sort(signals.begin(), signals.end(), std::less<JSColloAbortSignal*>());
        JSColloAbortSignal* previous = nullptr;
        for (auto* signal : signals) {
            if (signal != previous)
                signal->removeEventTargetCleanupsForTarget(target.object);
            previous = signal;
        }
    }
    target.data->clearListeners(target.owner());
}

JSC::JSValue webApiEventHandler(WebApiEventTargetHandle target, const WTF::String& type)
{
    auto index = target.data->findEventHandler(type);
    if (!index)
        return JSC::jsNull();
    return target.data->listeners().at(*index).callback.get();
}

JSC::JSValue setWebApiEventHandler(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    WebApiEventTargetHandle target, const WTF::String& type, JSC::JSValue value)
{
    auto& vm = global_object->vm();
    JSValue handler = value.isObject() ? value : JSC::jsNull();
    auto index = target.data->findEventHandler(type);
    if (handler.isNull()) {
        // HTML deactivates the handler: its listener leaves the list, and a later value starts a new one at the end.
        if (index) {
            target.data->markRemoved(*index);
            target.data->compactRemovedIfIdle(target.owner());
        }
        return handler;
    }
    if (index) {
        target.data->replaceEventHandler(vm, target.owner(), *index, handler);
        return handler;
    }

    WebApiEventListenerRecord record;
    record.type = type;
    record.callback.setWithoutWriteBarrier(handler);
    record.order = target.data->allocateListenerOrder();
    record.attribute_handler = true;
    switch (target.data->appendListener(vm, target.owner(), WTF::move(record))) {
    case WebApiEventTargetData::AppendResult::Appended:
        return handler;
    case WebApiEventTargetData::AppendResult::LimitReached:
        JSC::throwException(global_object, scope,
            createDOMException(
                global_object, DOMExceptionCode::QuotaExceededError, "EventTarget listener limit exceeded"_s));
        return {};
    case WebApiEventTargetData::AppendResult::OutOfMemory:
        JSC::throwOutOfMemoryError(global_object, scope);
        return {};
    }
    return {};
}

void reportWebApiException(JSC::JSGlobalObject* global_object, JSC::JSValue exception)
{
    auto* collo_global = dynamicDowncast<Collo::GlobalObject>(global_object);
    if (!collo_global)
        return;
    WebApiEventTargetHandle target;
    if (!globalEventTargetHandle(collo_global, target))
        return;
    // HTML, report an exception: a global already reporting one does not fire another event, which also ends the
    // recursion of an error listener that throws.
    if (target.data->reportingError())
        return;

    auto& vm = global_object->vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    auto message = reportMessageFor(global_object, exception);
    // reportMessageFor leaves only a termination pending.
    if (scope.exception())
        return;
    auto* event = JSColloErrorEvent::create(vm, collo_global, collo_global->errorEventStructure(), "error"_s, false,
        true, false, WTF::move(message), emptyString(), 0, 0, exception, /* trusted */ true);

    target.data->setReportingError(true);
    auto leave_reporting = WTF::makeScopeExit([&] { target.data->setReportingError(false); });
    {
        auto dispatch_scope = DECLARE_THROW_SCOPE(vm);
        dispatchWebApiEvent(collo_global, dispatch_scope, target, event);
        // The check is the outer scope's, below.
        dispatch_scope.release();
    }
    // The dispatch clears its listeners' exceptions; what can remain is its own OutOfMemoryError, which the report
    // drops as it would a listener's, or a termination, which stays pending.
    if (scope.exception())
        (void)scope.clearExceptionExceptTermination();
}

JSC::EncodedJSValue dispatchWebApiEvent(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    WebApiEventTargetHandle target, JSC::JSValue event_value)
{
    auto& vm = global_object->vm();
    // A termination an earlier call left must not enter a listener.
    if (scope.exception())
        return {};
    auto* event = dynamicDowncast<JSColloEvent>(event_value);
    if (!event)
        return JSC::throwVMTypeError(global_object, scope, "EventTarget.dispatchEvent requires an Event"_s);
    if (event->dispatching()) {
        auto* exception
            = createDOMException(global_object, "Event is already being dispatched"_s, "InvalidStateError"_s);
        return JSC::JSValue::encode(JSC::throwException(global_object, scope, exception));
    }

    event->startDispatch(vm, target.object);
    target.data->enterDispatch();
    auto leave_dispatch = WTF::makeScopeExit([&] {
        event->finishDispatch();
        target.data->leaveDispatch(target.owner());
    });

    WTF::Vector<EventListenerDispatchSnapshot, 8> listeners;
    JSC::MarkedArgumentBuffer callbacks;
    const auto& live_listeners = target.data->listeners();
    if (!listeners.tryReserveInitialCapacity(live_listeners.size()))
        return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
    for (auto& listener : live_listeners) {
        if (listener.removed || listener.type != event->type())
            continue;
        listeners.append(EventListenerDispatchSnapshot {
            listener.type, listener.order, listener.once, listener.passive, listener.attribute_handler });
        callbacks.append(listener.callback.get());
    }
    if (callbacks.hasOverflowed())
        return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));

    // Finds a snapshot's live record by its `order`, which no other record of the target shares, rather than by a
    // captured index, so a listener added or removed by script cannot make a snapshot alias another record. Returns
    // the live index, or npos when the record was removed or no longer matches the snapshot. An event handler record
    // matches whatever its current callback, since replacing the handler keeps the record.
    //
    // The live list and the snapshot are both in ascending order: a new record gets a higher order than any before it
    // and lands at the tail, and compaction keeps the order. A forward cursor that advances with the loop therefore
    // finds most records in O(1), and a record added during the dispatch sits after every snapshot, so the wrapping
    // scan still reaches each live snapshot with a higher order.
    constexpr size_t npos = std::numeric_limits<size_t>::max();
    size_t live_cursor = 0;
    auto findLiveSnapshotListener
        = [&target, &live_cursor](const EventListenerDispatchSnapshot& snapshot, JSValue callback) -> size_t {
        const auto& current_listeners = target.data->listeners();
        const size_t size = current_listeners.size();
        if (live_cursor > size)
            live_cursor = 0;
        for (size_t step = 0; step < size; step++) {
            size_t index = live_cursor + step;
            if (index >= size)
                index -= size;
            const auto& listener = current_listeners.at(index);
            if (listener.order != snapshot.order)
                continue;
            if (listener.removed || listener.type != snapshot.type)
                return npos;
            if (!snapshot.attribute_handler && !sameCallback(listener.callback.get(), callback))
                return npos;
            live_cursor = index + 1;
            return index;
        }
        return npos;
    };

    for (size_t snapshot_index = 0; snapshot_index < listeners.size(); snapshot_index++) {
        const auto& snapshot = listeners[snapshot_index];
        size_t live_index = findLiveSnapshotListener(snapshot, callbacks.at(snapshot_index));
        if (live_index == npos)
            continue;
        const auto& listener = target.data->listeners().at(live_index);
        // Held in a local, which the stack scan roots, because the call may replace the record's value.
        JSValue callback = snapshot.attribute_handler ? listener.callback.get() : callbacks.at(snapshot_index);
        if (snapshot.once) {
            unlinkAbortCleanupForListener(target.object, listener.type, listener);
            target.data->markRemoved(live_index);
        }
        if (snapshot.attribute_handler)
            callEventHandler(global_object, scope, target, *event, event_value, callback);
        else {
            event->setPassive(snapshot.passive);
            callListener(global_object, scope, target.object, callback, event_value);
            event->setPassive(false);
        }
        if (scope.exception()) {
            // A throwing listener must not stop the dispatch (DOM standard, inner invoke); only a termination does.
            if (!clearAndReportListenerException(vm, callback))
                return {};
        }
        if (event->immediatePropagationStopped())
            break;
    }

    return JSC::JSValue::encode(JSC::jsBoolean(!event->defaultPrevented()));
}

EventTargetInterface installEventTargetInterface(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    constexpr unsigned enumerableAccessor = static_cast<unsigned>(JSC::PropertyAttribute::Accessor);
    constexpr unsigned enumerableFunction = static_cast<unsigned>(JSC::PropertyAttribute::None);

    auto* target_prototype = JSC::constructEmptyObject(global_object);
    putWebApiFunction(
        global_object, target_prototype, vm, "addEventListener"_s, 2, eventTargetAddEventListener, enumerableFunction);
    putWebApiFunction(global_object, target_prototype, vm, "removeEventListener"_s, 2, eventTargetRemoveEventListener,
        enumerableFunction);
    putWebApiFunction(
        global_object, target_prototype, vm, "dispatchEvent"_s, 1, eventTargetDispatchEvent, enumerableFunction);
    target_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::makeString("EventTarget"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* target_constructor
        = JSC::JSFunction::create(vm, global_object, 0, "EventTarget"_s, eventTargetConstructorCall,
            JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, eventTargetConstructorConstruct, nullptr);
    RELEASE_ASSERT(target_constructor);
    target_constructor->putDirect(vm, vm.propertyNames->prototype, target_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    target_prototype->putDirect(
        vm, vm.propertyNames->constructor, target_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    JSC::Identifier target_identifier = JSC::Identifier::fromString(vm, "EventTarget"_s);
    global_object->putDirect(
        vm, target_identifier, target_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    RELEASE_ASSERT(global_object->getDirect(vm, target_identifier));

    // The global object has no listener storage of its own, so its listeners and its onerror handler live in this
    // EventTarget cell, which the realm cache roots for the VM's lifetime. Each realm has its own, so one realm's
    // listeners never hear another's events.
    auto* target_structure = JSColloEventTarget::createStructure(vm, global_object, target_prototype);
    global_object->webApiCache().global_event_target.set(vm, JSColloEventTarget::create(vm, target_structure));

    putWebApiFunction(
        global_object, global_object, vm, "addEventListener"_s, 2, globalAddEventListener, enumerableFunction);
    putWebApiFunction(
        global_object, global_object, vm, "removeEventListener"_s, 2, globalRemoveEventListener, enumerableFunction);
    putWebApiFunction(global_object, global_object, vm, "dispatchEvent"_s, 1, globalDispatchEvent, enumerableFunction);
    putWebApiAccessor(
        global_object, global_object, vm, "onerror"_s, globalGetOnError, globalSetOnError, enumerableAccessor);

    return { target_constructor, target_prototype, target_structure };
}

} // namespace Collo::HostFunctions
