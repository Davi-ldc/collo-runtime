// The Event, CustomEvent, MessageEvent, ErrorEvent and CloseEvent interfaces: constructors, init dictionaries,
// accessors and legacy init methods, plus the installer of every event interface, EventTarget and the global object's
// event members. VM thread only.

#include "host_functions/webapi/events/event_private.h"

#include "host_functions/webapi/dom/dom_exception.h"
#include "host_functions/webapi/messaging/message_channel.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/IteratorOperations.h>
#include <JavaScriptCore/JSCInlines.h>
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

const JSC::ClassInfo JSColloEvent::s_info
    = { "Event"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloEvent) };
const JSC::ClassInfo JSColloCustomEvent::s_info
    = { "CustomEvent"_s, &JSColloEvent::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloCustomEvent) };
const JSC::ClassInfo JSColloMessageEvent::s_info
    = { "MessageEvent"_s, &JSColloEvent::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloMessageEvent) };
const JSC::ClassInfo JSColloErrorEvent::s_info
    = { "ErrorEvent"_s, &JSColloEvent::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloErrorEvent) };
const JSC::ClassInfo JSColloCloseEvent::s_info
    = { "CloseEvent"_s, &JSColloEvent::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloCloseEvent) };

template <typename Visitor> void JSColloEvent::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloEvent*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    visitor.append(this_object->m_target);
    visitor.append(this_object->m_current_target);
}

DEFINE_VISIT_CHILDREN(JSColloEvent);

template <typename Visitor> void JSColloCustomEvent::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloCustomEvent*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    appendWebApiUnknown(visitor, this_object->m_detail);
}

DEFINE_VISIT_CHILDREN(JSColloCustomEvent);

template <typename Visitor> void JSColloMessageEvent::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloMessageEvent*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    appendWebApiUnknown(visitor, this_object->m_data);
    appendWebApiUnknown(visitor, this_object->m_source);
    visitor.append(this_object->m_ports);
}

DEFINE_VISIT_CHILDREN(JSColloMessageEvent);

template <typename Visitor> void JSColloErrorEvent::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloErrorEvent*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    appendWebApiUnknown(visitor, this_object->m_error);
}

DEFINE_VISIT_CHILDREN(JSColloErrorEvent);

template <typename Visitor> void JSColloCloseEvent::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloCloseEvent*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
}

DEFINE_VISIT_CHILDREN(JSColloCloseEvent);

static JSColloEvent* requireEvent(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    if (auto* event = dynamicDowncast<JSColloEvent>(value))
        return event;
    JSC::throwVMTypeError(global_object, scope, "Event method called on incompatible receiver"_s);
    return nullptr;
}

static JSColloCustomEvent* requireCustomEvent(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    if (auto* event = dynamicDowncast<JSColloCustomEvent>(value))
        return event;
    JSC::throwVMTypeError(global_object, scope, "CustomEvent method called on incompatible receiver"_s);
    return nullptr;
}

static JSColloMessageEvent* requireMessageEvent(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    if (auto* event = dynamicDowncast<JSColloMessageEvent>(value))
        return event;
    JSC::throwVMTypeError(global_object, scope, "MessageEvent method called on incompatible receiver"_s);
    return nullptr;
}

static JSColloErrorEvent* requireErrorEvent(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    if (auto* event = dynamicDowncast<JSColloErrorEvent>(value))
        return event;
    JSC::throwVMTypeError(global_object, scope, "ErrorEvent method called on incompatible receiver"_s);
    return nullptr;
}

static JSColloCloseEvent* requireCloseEvent(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    if (auto* event = dynamicDowncast<JSColloCloseEvent>(value))
        return event;
    JSC::throwVMTypeError(global_object, scope, "CloseEvent method called on incompatible receiver"_s);
    return nullptr;
}

static bool requireArgumentCount(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame,
    unsigned count, WTF::ASCIILiteral message)
{
    if (call_frame->argumentCount() >= count)
        return true;
    JSC::throwVMTypeError(global_object, scope, message);
    return false;
}

static JSC::Structure* eventStructureForNewTarget(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame)
{
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto* new_target = call_frame->newTarget().getObject();
    auto* constructor = call_frame->jsCallee();
    if (!new_target || new_target == constructor)
        return collo_global->eventStructure();
    auto* structure
        = JSC::InternalFunction::createSubclassStructure(global_object, new_target, collo_global->eventStructure());
    RETURN_IF_EXCEPTION(scope, nullptr);
    return structure;
}

static JSC::Structure* customEventStructureForNewTarget(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame)
{
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto* new_target = call_frame->newTarget().getObject();
    auto* constructor = call_frame->jsCallee();
    if (!new_target || new_target == constructor)
        return collo_global->customEventStructure();
    auto* structure = JSC::InternalFunction::createSubclassStructure(
        global_object, new_target, collo_global->customEventStructure());
    RETURN_IF_EXCEPTION(scope, nullptr);
    return structure;
}

static JSC::Structure* messageEventStructureForNewTarget(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame)
{
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto* new_target = call_frame->newTarget().getObject();
    auto* constructor = call_frame->jsCallee();
    if (!new_target || new_target == constructor)
        return collo_global->messageEventStructure();
    auto* structure = JSC::InternalFunction::createSubclassStructure(
        global_object, new_target, collo_global->messageEventStructure());
    RETURN_IF_EXCEPTION(scope, nullptr);
    return structure;
}

static JSC::Structure* errorEventStructureForNewTarget(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame)
{
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto* new_target = call_frame->newTarget().getObject();
    auto* constructor = call_frame->jsCallee();
    if (!new_target || new_target == constructor)
        return collo_global->errorEventStructure();
    auto* structure = JSC::InternalFunction::createSubclassStructure(
        global_object, new_target, collo_global->errorEventStructure());
    RETURN_IF_EXCEPTION(scope, nullptr);
    return structure;
}

static JSC::Structure* closeEventStructureForNewTarget(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame)
{
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    auto* new_target = call_frame->newTarget().getObject();
    auto* constructor = call_frame->jsCallee();
    if (!new_target || new_target == constructor)
        return collo_global->closeEventStructure();
    auto* structure = JSC::InternalFunction::createSubclassStructure(
        global_object, new_target, collo_global->closeEventStructure());
    RETURN_IF_EXCEPTION(scope, nullptr);
    return structure;
}

struct ParsedEventInit {
    bool bubbles { false };
    bool cancelable { false };
    bool composed { false };
};

static std::optional<ParsedEventInit> parseEventInit(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue init_value, WTF::ASCIILiteral message)
{
    ParsedEventInit parsed;
    if (init_value.isUndefinedOrNull())
        return parsed;

    auto& vm = global_object->vm();
    auto* init = dynamicDowncast<JSC::JSObject>(init_value);
    if (!init) {
        JSC::throwVMTypeError(global_object, scope, message);
        return std::nullopt;
    }

    auto maybe_bubbles = init->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "bubbles"_s));
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (maybe_bubbles)
        parsed.bubbles = maybe_bubbles.toBoolean(global_object);
    auto maybe_cancelable = init->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "cancelable"_s));
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (maybe_cancelable)
        parsed.cancelable = maybe_cancelable.toBoolean(global_object);
    auto maybe_composed = init->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "composed"_s));
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (maybe_composed)
        parsed.composed = maybe_composed.toBoolean(global_object);

    return parsed;
}

struct ParsedMessageEventInit {
    ParsedEventInit event;
    JSValue data { JSC::jsNull() };
    String origin;
    String last_event_id;
    JSValue source { JSC::jsNull() };
    JSC::Strong<JSC::Unknown> ports;
};

static void throwMessageEventSourceTypeError(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    if (value.isNumber()) {
        JSC::throwVMTypeError(global_object, scope,
            WTF::makeString(
                "The \"eventInitDict.source\" property must be of type MessagePort. Received type number ("_s,
                String::number(value.asNumber()), ")"_s));
        return;
    }

    if (value.isObject()) {
        JSC::throwVMTypeError(global_object, scope,
            "The \"eventInitDict.source\" property must be of type MessagePort. Received an instance of Object"_s);
        return;
    }

    JSC::throwVMTypeError(global_object, scope, "MessageEvent source must be null or a MessagePort"_s);
}

static JSObject* frozenEmptyArray(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    // constructEmptyArray returns nullptr after throwing on OOM.
    auto* array = JSC::constructEmptyArray(global_object, nullptr);
    RETURN_IF_EXCEPTION(scope, nullptr);
    if (!array)
        return nullptr;
    JSC::objectConstructorFreeze(global_object, array);
    RETURN_IF_EXCEPTION(scope, nullptr);
    return array;
}

JSObject* JSColloMessageEvent::ensurePorts(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    if (auto* ports = m_ports.get())
        return ports;
    // ports is [SameObject]: event.ports === event.ports must hold, so the frozen empty array is kept on first read.
    // FIXME: every port-less MessageEvent whose ports are read pins its own empty array; one frozen empty array kept
    // in the realm's webapi_cache would serve them all.
    auto* ports = frozenEmptyArray(global_object, scope);
    RETURN_IF_EXCEPTION(scope, nullptr);
    if (!ports)
        return nullptr;
    m_ports.set(global_object->vm(), this, ports);
    return ports;
}

static std::optional<ParsedMessageEventInit> parseMessageEventInit(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue init_value, WTF::ASCIILiteral message)
{
    ParsedMessageEventInit parsed;
    parsed.origin = emptyString();
    parsed.last_event_id = emptyString();
    if (init_value.isUndefinedOrNull())
        return parsed;

    auto event_init = parseEventInit(global_object, scope, init_value, message);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (!event_init)
        return std::nullopt;
    parsed.event = *event_init;

    auto& vm = global_object->vm();
    auto* init = dynamicDowncast<JSC::JSObject>(init_value);
    auto maybe_data = init->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "data"_s));
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (maybe_data)
        parsed.data = maybe_data;

    auto maybe_origin = init->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "origin"_s));
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (maybe_origin) {
        parsed.origin = valueToWebApiString(global_object, scope, maybe_origin);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
    }

    auto maybe_last_event_id
        = init->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "lastEventId"_s));
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (maybe_last_event_id) {
        parsed.last_event_id = valueToWebApiString(global_object, scope, maybe_last_event_id);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
    }

    auto maybe_source = init->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "source"_s));
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (maybe_source && !maybe_source.isUndefined()) {
        if (maybe_source.isNull() || webApiMessagePortIsValue(maybe_source))
            parsed.source = maybe_source;
        else {
            throwMessageEventSourceTypeError(global_object, scope, maybe_source);
            return std::nullopt;
        }
    }

    auto maybe_ports = init->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "ports"_s));
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (maybe_ports) {
        auto* ports = webApiNormalizeMessagePortsArray(global_object, scope, maybe_ports);
        if (!ports)
            return std::nullopt;
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        parsed.ports.set(vm, ports);
    }

    return parsed;
}

struct ParsedErrorEventInit {
    ParsedEventInit event;
    String message;
    String filename;
    uint32_t lineno { 0 };
    uint32_t colno { 0 };
    JSValue error { JSC::jsNull() };
};

static std::optional<ParsedErrorEventInit> parseErrorEventInit(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue init_value, WTF::ASCIILiteral message)
{
    ParsedErrorEventInit parsed;
    if (init_value.isUndefinedOrNull())
        return parsed;

    auto event_init = parseEventInit(global_object, scope, init_value, message);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (!event_init)
        return std::nullopt;
    parsed.event = *event_init;

    auto& vm = global_object->vm();
    auto* init = dynamicDowncast<JSC::JSObject>(init_value);
    auto maybe_message = init->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "message"_s));
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (maybe_message && !maybe_message.isUndefined()) {
        parsed.message = valueToWebApiString(global_object, scope, maybe_message);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
    }

    auto maybe_filename = init->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "filename"_s));
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (maybe_filename && !maybe_filename.isUndefined()) {
        parsed.filename = toWebApiUSVString(valueToWebApiString(global_object, scope, maybe_filename));
        RETURN_IF_EXCEPTION(scope, std::nullopt);
    }

    auto maybe_lineno = init->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "lineno"_s));
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (maybe_lineno && !maybe_lineno.isUndefined()) {
        parsed.lineno = static_cast<uint32_t>(maybe_lineno.toUInt32(global_object));
        RETURN_IF_EXCEPTION(scope, std::nullopt);
    }

    auto maybe_colno = init->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "colno"_s));
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (maybe_colno && !maybe_colno.isUndefined()) {
        parsed.colno = static_cast<uint32_t>(maybe_colno.toUInt32(global_object));
        RETURN_IF_EXCEPTION(scope, std::nullopt);
    }

    auto maybe_error = init->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "error"_s));
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (maybe_error && !maybe_error.isUndefined())
        parsed.error = maybe_error;

    return parsed;
}

struct ParsedCloseEventInit {
    ParsedEventInit event;
    bool was_clean { false };
    uint16_t code { 0 };
    String reason;
};

static std::optional<ParsedCloseEventInit> parseCloseEventInit(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue init_value, WTF::ASCIILiteral message)
{
    ParsedCloseEventInit parsed;
    if (init_value.isUndefinedOrNull())
        return parsed;

    auto event_init = parseEventInit(global_object, scope, init_value, message);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (!event_init)
        return std::nullopt;
    parsed.event = *event_init;

    auto& vm = global_object->vm();
    auto* init = dynamicDowncast<JSC::JSObject>(init_value);
    auto maybe_was_clean = init->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "wasClean"_s));
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (maybe_was_clean)
        parsed.was_clean = maybe_was_clean.toBoolean(global_object);

    auto maybe_code = init->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "code"_s));
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (maybe_code) {
        parsed.code = static_cast<uint16_t>(maybe_code.toUInt32(global_object));
        RETURN_IF_EXCEPTION(scope, std::nullopt);
    }

    auto maybe_reason = init->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "reason"_s));
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (maybe_reason) {
        parsed.reason = valueToWebApiString(global_object, scope, maybe_reason);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
    }

    return parsed;
}

JSC_DEFINE_HOST_FUNCTION(eventConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "Event constructor requires 'new'"_s);
}

JSC_DEFINE_HOST_FUNCTION(eventConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (!requireArgumentCount(global_object, scope, call_frame, 1, "Event constructor requires a type"_s))
        return {};

    auto type = argumentToWebApiString(global_object, scope, call_frame, 0);
    RETURN_IF_EXCEPTION(scope, {});

    auto init = parseEventInit(global_object, scope, call_frame->argument(1), "Event init must be an object"_s);
    RETURN_IF_EXCEPTION(scope, {});
    if (!init)
        return {};

    auto* structure = eventStructureForNewTarget(global_object, scope, call_frame);
    RETURN_IF_EXCEPTION(scope, {});
    if (!structure)
        return {};

    return JSValue::encode(JSColloEvent::create(vm, uncheckedDowncast<Collo::GlobalObject>(global_object), structure,
        WTF::move(type), init->bubbles, init->cancelable, init->composed));
}

JSC_DEFINE_HOST_FUNCTION(customEventConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "CustomEvent constructor requires 'new'"_s);
}

JSC_DEFINE_HOST_FUNCTION(
    customEventConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (!requireArgumentCount(global_object, scope, call_frame, 1, "CustomEvent constructor requires a type"_s))
        return {};

    auto type = argumentToWebApiString(global_object, scope, call_frame, 0);
    RETURN_IF_EXCEPTION(scope, {});
    auto init = parseEventInit(global_object, scope, call_frame->argument(1), "CustomEvent init must be an object"_s);
    RETURN_IF_EXCEPTION(scope, {});
    if (!init)
        return {};

    JSValue detail = JSC::jsNull();
    auto init_value = call_frame->argument(1);
    if (!init_value.isUndefinedOrNull()) {
        auto* init_object = dynamicDowncast<JSC::JSObject>(init_value);
        auto maybe_detail
            = init_object->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "detail"_s));
        RETURN_IF_EXCEPTION(scope, {});
        if (maybe_detail)
            detail = maybe_detail;
    }

    auto* structure = customEventStructureForNewTarget(global_object, scope, call_frame);
    RETURN_IF_EXCEPTION(scope, {});
    if (!structure)
        return {};

    return JSValue::encode(JSColloCustomEvent::create(vm, uncheckedDowncast<Collo::GlobalObject>(global_object),
        structure, WTF::move(type), init->bubbles, init->cancelable, init->composed, detail));
}

JSC_DEFINE_HOST_FUNCTION(messageEventConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "MessageEvent constructor requires 'new'"_s);
}

JSC_DEFINE_HOST_FUNCTION(
    messageEventConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (!requireArgumentCount(global_object, scope, call_frame, 1, "Not enough arguments"_s))
        return {};

    auto type = argumentToWebApiString(global_object, scope, call_frame, 0);
    RETURN_IF_EXCEPTION(scope, {});
    auto init
        = parseMessageEventInit(global_object, scope, call_frame->argument(1), "MessageEvent init must be an object"_s);
    RETURN_IF_EXCEPTION(scope, {});
    if (!init)
        return {};

    auto* structure = messageEventStructureForNewTarget(global_object, scope, call_frame);
    RETURN_IF_EXCEPTION(scope, {});
    if (!structure)
        return {};

    return JSValue::encode(JSColloMessageEvent::create(vm, uncheckedDowncast<Collo::GlobalObject>(global_object),
        structure, WTF::move(type), init->event.bubbles, init->event.cancelable, init->event.composed, init->data,
        WTF::move(init->origin), WTF::move(init->last_event_id), init->source,
        init->ports ? uncheckedDowncast<JSC::JSObject>(init->ports.get()) : nullptr));
}

JSC_DEFINE_HOST_FUNCTION(errorEventConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "ErrorEvent constructor requires 'new'"_s);
}

JSC_DEFINE_HOST_FUNCTION(
    errorEventConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (!requireArgumentCount(global_object, scope, call_frame, 1, "ErrorEvent constructor requires a type"_s))
        return {};

    auto type = argumentToWebApiString(global_object, scope, call_frame, 0);
    RETURN_IF_EXCEPTION(scope, {});
    auto init
        = parseErrorEventInit(global_object, scope, call_frame->argument(1), "ErrorEvent init must be an object"_s);
    RETURN_IF_EXCEPTION(scope, {});
    if (!init)
        return {};

    auto* structure = errorEventStructureForNewTarget(global_object, scope, call_frame);
    RETURN_IF_EXCEPTION(scope, {});
    if (!structure)
        return {};

    return JSValue::encode(JSColloErrorEvent::create(vm, uncheckedDowncast<Collo::GlobalObject>(global_object),
        structure, WTF::move(type), init->event.bubbles, init->event.cancelable, init->event.composed,
        WTF::move(init->message), WTF::move(init->filename), init->lineno, init->colno, init->error));
}

JSC_DEFINE_HOST_FUNCTION(closeEventConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "CloseEvent constructor requires 'new'"_s);
}

JSC_DEFINE_HOST_FUNCTION(
    closeEventConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    if (!requireArgumentCount(global_object, scope, call_frame, 1, "CloseEvent constructor requires a type"_s))
        return {};

    auto type = argumentToWebApiString(global_object, scope, call_frame, 0);
    RETURN_IF_EXCEPTION(scope, {});
    auto init
        = parseCloseEventInit(global_object, scope, call_frame->argument(1), "CloseEvent init must be an object"_s);
    RETURN_IF_EXCEPTION(scope, {});
    if (!init)
        return {};

    auto* structure = closeEventStructureForNewTarget(global_object, scope, call_frame);
    RETURN_IF_EXCEPTION(scope, {});
    if (!structure)
        return {};

    return JSValue::encode(JSColloCloseEvent::create(vm, uncheckedDowncast<Collo::GlobalObject>(global_object),
        structure, WTF::move(type), init->event.bubbles, init->event.cancelable, init->event.composed, init->was_clean,
        init->code, WTF::move(init->reason)));
}

#define COLLO_EVENT_GETTER(name, expr)                                                                                 \
    JSC_DEFINE_HOST_FUNCTION(name, (JSC::JSGlobalObject * global_object, JSC::CallFrame * call_frame))                 \
    {                                                                                                                  \
        auto& vm = global_object->vm();                                                                                \
        auto scope = DECLARE_THROW_SCOPE(vm);                                                                          \
        auto* event = requireEvent(global_object, scope, call_frame->thisValue());                                     \
        RETURN_IF_EXCEPTION(scope, {});                                                                                \
        return JSValue::encode(expr);                                                                                  \
    }

COLLO_EVENT_GETTER(eventGetType, JSC::jsString(vm, event->type()))
COLLO_EVENT_GETTER(eventGetTarget, event->target() ? JSValue(event->target()) : JSC::jsNull())
COLLO_EVENT_GETTER(eventGetCurrentTarget, event->currentTarget() ? JSValue(event->currentTarget()) : JSC::jsNull())
COLLO_EVENT_GETTER(eventGetEventPhase, JSC::jsNumber(static_cast<unsigned>(event->phase())))
COLLO_EVENT_GETTER(eventGetBubbles, JSC::jsBoolean(event->bubbles()))
COLLO_EVENT_GETTER(eventGetCancelable, JSC::jsBoolean(event->cancelable()))
COLLO_EVENT_GETTER(eventGetDefaultPrevented, JSC::jsBoolean(event->defaultPrevented()))
COLLO_EVENT_GETTER(eventGetComposed, JSC::jsBoolean(event->composed()))
COLLO_EVENT_GETTER(eventGetTimeStamp, JSC::jsNumber(event->timeStampMs()))

#undef COLLO_EVENT_GETTER

JSC_DEFINE_HOST_FUNCTION(customEventGetDetail, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* event = requireCustomEvent(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(event->detail());
}

#define COLLO_MESSAGE_EVENT_GETTER(name, expr)                                                                         \
    JSC_DEFINE_HOST_FUNCTION(name, (JSC::JSGlobalObject * global_object, JSC::CallFrame * call_frame))                 \
    {                                                                                                                  \
        auto& vm = global_object->vm();                                                                                \
        auto scope = DECLARE_THROW_SCOPE(vm);                                                                          \
        auto* event = requireMessageEvent(global_object, scope, call_frame->thisValue());                              \
        RETURN_IF_EXCEPTION(scope, {});                                                                                \
        return JSValue::encode(expr);                                                                                  \
    }

COLLO_MESSAGE_EVENT_GETTER(messageEventGetData, event->data())
COLLO_MESSAGE_EVENT_GETTER(messageEventGetOrigin, JSC::jsString(vm, event->origin()))
COLLO_MESSAGE_EVENT_GETTER(messageEventGetLastEventId, JSC::jsString(vm, event->lastEventId()))
COLLO_MESSAGE_EVENT_GETTER(messageEventGetSource, event->source())

#undef COLLO_MESSAGE_EVENT_GETTER

JSC_DEFINE_HOST_FUNCTION(messageEventGetPorts, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* event = requireMessageEvent(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    auto* ports = event->ensurePorts(global_object, scope);
    RETURN_IF_EXCEPTION(scope, {});
    if (!ports)
        return {};
    return JSValue::encode(JSValue(ports));
}

#define COLLO_ERROR_EVENT_GETTER(name, expr)                                                                           \
    JSC_DEFINE_HOST_FUNCTION(name, (JSC::JSGlobalObject * global_object, JSC::CallFrame * call_frame))                 \
    {                                                                                                                  \
        auto& vm = global_object->vm();                                                                                \
        auto scope = DECLARE_THROW_SCOPE(vm);                                                                          \
        auto* event = requireErrorEvent(global_object, scope, call_frame->thisValue());                                \
        RETURN_IF_EXCEPTION(scope, {});                                                                                \
        return JSValue::encode(expr);                                                                                  \
    }

COLLO_ERROR_EVENT_GETTER(errorEventGetMessage, JSC::jsString(vm, event->message()))
COLLO_ERROR_EVENT_GETTER(errorEventGetFilename, JSC::jsString(vm, event->filename()))
COLLO_ERROR_EVENT_GETTER(errorEventGetLineno, JSC::jsNumber(event->lineno()))
COLLO_ERROR_EVENT_GETTER(errorEventGetColno, JSC::jsNumber(event->colno()))
COLLO_ERROR_EVENT_GETTER(errorEventGetError, event->error())

#undef COLLO_ERROR_EVENT_GETTER

#define COLLO_CLOSE_EVENT_GETTER(name, expr)                                                                           \
    JSC_DEFINE_HOST_FUNCTION(name, (JSC::JSGlobalObject * global_object, JSC::CallFrame * call_frame))                 \
    {                                                                                                                  \
        auto& vm = global_object->vm();                                                                                \
        auto scope = DECLARE_THROW_SCOPE(vm);                                                                          \
        auto* event = requireCloseEvent(global_object, scope, call_frame->thisValue());                                \
        RETURN_IF_EXCEPTION(scope, {});                                                                                \
        return JSValue::encode(expr);                                                                                  \
    }

COLLO_CLOSE_EVENT_GETTER(closeEventGetWasClean, JSC::jsBoolean(event->wasClean()))
COLLO_CLOSE_EVENT_GETTER(closeEventGetCode, JSC::jsNumber(event->code()))
COLLO_CLOSE_EVENT_GETTER(closeEventGetReason, JSC::jsString(vm, event->reason()))

#undef COLLO_CLOSE_EVENT_GETTER

JSC_DEFINE_HOST_FUNCTION(eventGetCancelBubble, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* event = requireEvent(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(JSC::jsBoolean(event->cancelBubble()));
}

JSC_DEFINE_HOST_FUNCTION(eventSetCancelBubble, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* event = requireEvent(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    event->setCancelBubble(call_frame->argument(0).toBoolean(global_object));
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(eventGetReturnValue, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* event = requireEvent(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(JSC::jsBoolean(event->returnValue()));
}

JSC_DEFINE_HOST_FUNCTION(eventSetReturnValue, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* event = requireEvent(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    event->setReturnValue(call_frame->argument(0).toBoolean(global_object));
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_CUSTOM_GETTER(eventIsTrustedCustomGetter,
    (JSC::JSGlobalObject * global_object, JSC::EncodedJSValue this_value, JSC::PropertyName))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* event = requireEvent(global_object, scope, JSValue::decode(this_value));
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(JSC::jsBoolean(event->isTrusted()));
}

JSC_DEFINE_HOST_FUNCTION(eventComposedPath, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* event = requireEvent(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    // constructEmptyArray returns nullptr after throwing on OOM.
    auto* result = JSC::constructEmptyArray(global_object, nullptr);
    RETURN_IF_EXCEPTION(scope, {});
    if (!result)
        return {};
    if (event->currentTarget()) {
        result->putDirectIndex(global_object, 0, event->currentTarget());
        RETURN_IF_EXCEPTION(scope, {});
    }
    return JSValue::encode(result);
}

JSC_DEFINE_HOST_FUNCTION(eventStopPropagation, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* event = requireEvent(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    event->stopPropagation();
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(
    eventStopImmediatePropagation, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* event = requireEvent(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    event->stopImmediatePropagation();
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(eventPreventDefault, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* event = requireEvent(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    event->preventDefault();
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(eventInitEvent, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* event = requireEvent(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    if (!requireArgumentCount(global_object, scope, call_frame, 1, "Event.initEvent requires a type"_s))
        return {};
    auto type = argumentToWebApiString(global_object, scope, call_frame, 0);
    RETURN_IF_EXCEPTION(scope, {});
    event->initEvent(WTF::move(type),
        call_frame->argumentCount() > 1 ? call_frame->argument(1).toBoolean(global_object) : false,
        call_frame->argumentCount() > 2 ? call_frame->argument(2).toBoolean(global_object) : false);
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(customEventInitCustomEvent, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* event = requireCustomEvent(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    if (!requireArgumentCount(global_object, scope, call_frame, 1, "CustomEvent.initCustomEvent requires a type"_s))
        return {};
    auto type = argumentToWebApiString(global_object, scope, call_frame, 0);
    RETURN_IF_EXCEPTION(scope, {});
    event->initCustomEvent(vm, WTF::move(type),
        call_frame->argumentCount() > 1 ? call_frame->argument(1).toBoolean(global_object) : false,
        call_frame->argumentCount() > 2 ? call_frame->argument(2).toBoolean(global_object) : false,
        call_frame->argumentCount() > 3 ? call_frame->argument(3) : JSC::jsNull());
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(
    messageEventInitMessageEvent, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* event = requireMessageEvent(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    if (!requireArgumentCount(global_object, scope, call_frame, 1, "MessageEvent.initMessageEvent requires a type"_s))
        return {};
    auto type = argumentToWebApiString(global_object, scope, call_frame, 0);
    RETURN_IF_EXCEPTION(scope, {});

    JSValue source = JSC::jsNull();
    if (call_frame->argumentCount() > 6 && !call_frame->argument(6).isUndefined()) {
        auto value = call_frame->argument(6);
        if (value.isNull() || webApiMessagePortIsValue(value))
            source = value;
        else {
            throwMessageEventSourceTypeError(global_object, scope, value);
            return {};
        }
    }

    JSC::Strong<JSC::Unknown> ports;
    if (call_frame->argumentCount() > 7) {
        auto* normalized_ports = webApiNormalizeMessagePortsArray(global_object, scope, call_frame->argument(7));
        if (!normalized_ports)
            return {};
        RETURN_IF_EXCEPTION(scope, {});
        ports.set(vm, normalized_ports);
    }

    String origin;
    if (call_frame->argumentCount() > 4) {
        origin = valueToWebApiString(global_object, scope, call_frame->argument(4));
        RETURN_IF_EXCEPTION(scope, {});
    } else {
        origin = emptyString();
    }

    String last_event_id;
    if (call_frame->argumentCount() > 5) {
        last_event_id = valueToWebApiString(global_object, scope, call_frame->argument(5));
        RETURN_IF_EXCEPTION(scope, {});
    } else {
        last_event_id = emptyString();
    }

    event->initMessageEvent(vm, WTF::move(type),
        call_frame->argumentCount() > 1 ? call_frame->argument(1).toBoolean(global_object) : false,
        call_frame->argumentCount() > 2 ? call_frame->argument(2).toBoolean(global_object) : false,
        call_frame->argumentCount() > 3 ? call_frame->argument(3) : JSC::jsNull(), WTF::move(origin),
        WTF::move(last_event_id), source, ports ? uncheckedDowncast<JSC::JSObject>(ports.get()) : nullptr);
    return JSValue::encode(JSC::jsUndefined());
}

static void putEventConstants(JSC::VM& vm, JSC::JSObject* object)
{
    constexpr unsigned attributes
        = static_cast<unsigned>(JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontDelete);
    object->putDirect(vm, JSC::Identifier::fromString(vm, "NONE"_s), JSC::jsNumber(0), attributes);
    object->putDirect(vm, JSC::Identifier::fromString(vm, "CAPTURING_PHASE"_s), JSC::jsNumber(1), attributes);
    object->putDirect(vm, JSC::Identifier::fromString(vm, "AT_TARGET"_s), JSC::jsNumber(2), attributes);
    object->putDirect(vm, JSC::Identifier::fromString(vm, "BUBBLING_PHASE"_s), JSC::jsNumber(3), attributes);
}

JSC::JSObject* createWebApiEvent(
    JSC::JSGlobalObject* global_object, WTF::String type, bool bubbles, bool cancelable, bool composed, bool trusted)
{
    auto& vm = global_object->vm();
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    return JSColloEvent::create(
        vm, collo_global, collo_global->eventStructure(), WTF::move(type), bubbles, cancelable, composed, trusted);
}

JSC::JSObject* createWebApiMessageEvent(JSC::JSGlobalObject* global_object, JSC::JSValue data, JSC::JSObject* ports)
{
    auto& vm = global_object->vm();
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    return JSColloMessageEvent::create(vm, collo_global, collo_global->messageEventStructure(), "message"_s, false,
        false, false, data, emptyString(), emptyString(), JSC::jsNull(), ports);
}

JSC::JSObject* createWebApiErrorEvent(JSC::JSGlobalObject* global_object, WTF::String message, WTF::String filename,
    uint32_t lineno, uint32_t colno, JSC::JSValue error)
{
    auto& vm = global_object->vm();
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    return JSColloErrorEvent::create(vm, collo_global, collo_global->errorEventStructure(), "error"_s, false, true,
        false, WTF::move(message), WTF::move(filename), lineno, colno, error);
}

void installWebApiEvent(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    constexpr unsigned enumerableAccessor = static_cast<unsigned>(JSC::PropertyAttribute::Accessor);
    constexpr unsigned enumerableFunction = static_cast<unsigned>(JSC::PropertyAttribute::None);

    auto* event_prototype = JSC::constructEmptyObject(global_object);
    putWebApiAccessor(global_object, event_prototype, vm, "type"_s, eventGetType, nullptr, enumerableAccessor);
    putWebApiAccessor(global_object, event_prototype, vm, "target"_s, eventGetTarget, nullptr, enumerableAccessor);
    putWebApiAccessor(global_object, event_prototype, vm, "srcElement"_s, eventGetTarget, nullptr, enumerableAccessor);
    putWebApiAccessor(
        global_object, event_prototype, vm, "currentTarget"_s, eventGetCurrentTarget, nullptr, enumerableAccessor);
    putWebApiAccessor(
        global_object, event_prototype, vm, "eventPhase"_s, eventGetEventPhase, nullptr, enumerableAccessor);
    putWebApiAccessor(global_object, event_prototype, vm, "cancelBubble"_s, eventGetCancelBubble, eventSetCancelBubble,
        enumerableAccessor);
    putWebApiAccessor(global_object, event_prototype, vm, "bubbles"_s, eventGetBubbles, nullptr, enumerableAccessor);
    putWebApiAccessor(
        global_object, event_prototype, vm, "cancelable"_s, eventGetCancelable, nullptr, enumerableAccessor);
    putWebApiAccessor(global_object, event_prototype, vm, "returnValue"_s, eventGetReturnValue, eventSetReturnValue,
        enumerableAccessor);
    putWebApiAccessor(global_object, event_prototype, vm, "defaultPrevented"_s, eventGetDefaultPrevented, nullptr,
        enumerableAccessor);
    putWebApiAccessor(global_object, event_prototype, vm, "composed"_s, eventGetComposed, nullptr, enumerableAccessor);
    putWebApiAccessor(
        global_object, event_prototype, vm, "timeStamp"_s, eventGetTimeStamp, nullptr, enumerableAccessor);
    putWebApiFunction(global_object, event_prototype, vm, "composedPath"_s, 0, eventComposedPath, enumerableFunction);
    putWebApiFunction(
        global_object, event_prototype, vm, "stopPropagation"_s, 0, eventStopPropagation, enumerableFunction);
    putWebApiFunction(global_object, event_prototype, vm, "stopImmediatePropagation"_s, 0,
        eventStopImmediatePropagation, enumerableFunction);
    putWebApiFunction(
        global_object, event_prototype, vm, "preventDefault"_s, 0, eventPreventDefault, enumerableFunction);
    putWebApiFunction(global_object, event_prototype, vm, "initEvent"_s, 1, eventInitEvent, enumerableFunction);
    putEventConstants(vm, event_prototype);
    event_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol, JSC::jsString(vm, WTF::makeString("Event"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* event_constructor = JSC::JSFunction::create(vm, global_object, 1, "Event"_s, eventConstructorCall,
        JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, eventConstructorConstruct, nullptr);
    RELEASE_ASSERT(event_constructor);
    event_constructor->putDirect(vm, vm.propertyNames->prototype, event_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    putEventConstants(vm, event_constructor);
    event_prototype->putDirect(
        vm, vm.propertyNames->constructor, event_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    JSC::Identifier event_identifier = JSC::Identifier::fromString(vm, "Event"_s);
    global_object->putDirect(
        vm, event_identifier, event_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    RELEASE_ASSERT(global_object->getDirect(vm, event_identifier));

    auto* custom_event_prototype = JSC::constructEmptyObject(global_object);
    custom_event_prototype->setPrototype(vm, global_object, event_prototype, true);
    putWebApiAccessor(
        global_object, custom_event_prototype, vm, "detail"_s, customEventGetDetail, nullptr, enumerableAccessor);
    putWebApiFunction(global_object, custom_event_prototype, vm, "initCustomEvent"_s, 1, customEventInitCustomEvent,
        enumerableFunction);
    custom_event_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::makeString("CustomEvent"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* custom_event_constructor
        = JSC::JSFunction::create(vm, global_object, 1, "CustomEvent"_s, customEventConstructorCall,
            JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, customEventConstructorConstruct, nullptr);
    RELEASE_ASSERT(custom_event_constructor);
    custom_event_constructor->setPrototype(vm, global_object, event_constructor, true);
    custom_event_constructor->putDirect(vm, vm.propertyNames->prototype, custom_event_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    custom_event_prototype->putDirect(vm, vm.propertyNames->constructor, custom_event_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    JSC::Identifier custom_event_identifier = JSC::Identifier::fromString(vm, "CustomEvent"_s);
    global_object->putDirect(
        vm, custom_event_identifier, custom_event_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    RELEASE_ASSERT(global_object->getDirect(vm, custom_event_identifier));

    auto* message_event_prototype = JSC::constructEmptyObject(global_object);
    message_event_prototype->setPrototype(vm, global_object, event_prototype, true);
    putWebApiAccessor(
        global_object, message_event_prototype, vm, "data"_s, messageEventGetData, nullptr, enumerableAccessor);
    putWebApiAccessor(
        global_object, message_event_prototype, vm, "origin"_s, messageEventGetOrigin, nullptr, enumerableAccessor);
    putWebApiAccessor(global_object, message_event_prototype, vm, "lastEventId"_s, messageEventGetLastEventId, nullptr,
        enumerableAccessor);
    putWebApiAccessor(
        global_object, message_event_prototype, vm, "source"_s, messageEventGetSource, nullptr, enumerableAccessor);
    putWebApiAccessor(
        global_object, message_event_prototype, vm, "ports"_s, messageEventGetPorts, nullptr, enumerableAccessor);
    putWebApiFunction(global_object, message_event_prototype, vm, "initMessageEvent"_s, 1, messageEventInitMessageEvent,
        enumerableFunction);
    message_event_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::makeString("MessageEvent"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* message_event_constructor
        = JSC::JSFunction::create(vm, global_object, 1, "MessageEvent"_s, messageEventConstructorCall,
            JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, messageEventConstructorConstruct, nullptr);
    RELEASE_ASSERT(message_event_constructor);
    message_event_constructor->setPrototype(vm, global_object, event_constructor, true);
    message_event_constructor->putDirect(vm, vm.propertyNames->prototype, message_event_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    message_event_prototype->putDirect(vm, vm.propertyNames->constructor, message_event_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    JSC::Identifier message_event_identifier = JSC::Identifier::fromString(vm, "MessageEvent"_s);
    global_object->putDirect(vm, message_event_identifier, message_event_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    RELEASE_ASSERT(global_object->getDirect(vm, message_event_identifier));

    auto* error_event_prototype = JSC::constructEmptyObject(global_object);
    error_event_prototype->setPrototype(vm, global_object, event_prototype, true);
    putWebApiAccessor(
        global_object, error_event_prototype, vm, "message"_s, errorEventGetMessage, nullptr, enumerableAccessor);
    putWebApiAccessor(
        global_object, error_event_prototype, vm, "filename"_s, errorEventGetFilename, nullptr, enumerableAccessor);
    putWebApiAccessor(
        global_object, error_event_prototype, vm, "lineno"_s, errorEventGetLineno, nullptr, enumerableAccessor);
    putWebApiAccessor(
        global_object, error_event_prototype, vm, "colno"_s, errorEventGetColno, nullptr, enumerableAccessor);
    putWebApiAccessor(
        global_object, error_event_prototype, vm, "error"_s, errorEventGetError, nullptr, enumerableAccessor);
    error_event_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::makeString("ErrorEvent"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* error_event_constructor
        = JSC::JSFunction::create(vm, global_object, 1, "ErrorEvent"_s, errorEventConstructorCall,
            JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, errorEventConstructorConstruct, nullptr);
    RELEASE_ASSERT(error_event_constructor);
    error_event_constructor->setPrototype(vm, global_object, event_constructor, true);
    error_event_constructor->putDirect(vm, vm.propertyNames->prototype, error_event_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    error_event_prototype->putDirect(vm, vm.propertyNames->constructor, error_event_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    JSC::Identifier error_event_identifier = JSC::Identifier::fromString(vm, "ErrorEvent"_s);
    global_object->putDirect(
        vm, error_event_identifier, error_event_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    RELEASE_ASSERT(global_object->getDirect(vm, error_event_identifier));

    auto* close_event_prototype = JSC::constructEmptyObject(global_object);
    close_event_prototype->setPrototype(vm, global_object, event_prototype, true);
    putWebApiAccessor(
        global_object, close_event_prototype, vm, "wasClean"_s, closeEventGetWasClean, nullptr, enumerableAccessor);
    putWebApiAccessor(
        global_object, close_event_prototype, vm, "code"_s, closeEventGetCode, nullptr, enumerableAccessor);
    putWebApiAccessor(
        global_object, close_event_prototype, vm, "reason"_s, closeEventGetReason, nullptr, enumerableAccessor);
    close_event_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::makeString("CloseEvent"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* close_event_constructor
        = JSC::JSFunction::create(vm, global_object, 1, "CloseEvent"_s, closeEventConstructorCall,
            JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, closeEventConstructorConstruct, nullptr);
    RELEASE_ASSERT(close_event_constructor);
    close_event_constructor->setPrototype(vm, global_object, event_constructor, true);
    close_event_constructor->putDirect(vm, vm.propertyNames->prototype, close_event_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    close_event_prototype->putDirect(vm, vm.propertyNames->constructor, close_event_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    JSC::Identifier close_event_identifier = JSC::Identifier::fromString(vm, "CloseEvent"_s);
    global_object->putDirect(
        vm, close_event_identifier, close_event_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    RELEASE_ASSERT(global_object->getDirect(vm, close_event_identifier));

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

    // The global object has no listener storage of its own, so its listeners live in this EventTarget cell, which
    // the realm's webapi_cache roots for the VM's lifetime together with the onerror and onmessage handlers. Each
    // realm has its own, so one realm's listeners never hear another's events.
    auto* target_structure = JSColloEventTarget::createStructure(vm, global_object, target_prototype);
    auto* global_event_target = JSColloEventTarget::create(vm, target_structure);
    auto& cache = global_object->webApiCache();
    cache.global_event_target.set(vm, global_event_target);
    cache.global_on_error.set(vm, JSC::jsNull());
    cache.global_on_message.set(vm, JSC::jsNull());

    putWebApiFunction(
        global_object, global_object, vm, "addEventListener"_s, 2, globalAddEventListener, enumerableFunction);
    putWebApiFunction(
        global_object, global_object, vm, "removeEventListener"_s, 2, globalRemoveEventListener, enumerableFunction);
    putWebApiFunction(global_object, global_object, vm, "dispatchEvent"_s, 1, globalDispatchEvent, enumerableFunction);
    putWebApiAccessor(
        global_object, global_object, vm, "onerror"_s, globalGetOnError, globalSetOnError, enumerableAccessor);
    putWebApiAccessor(
        global_object, global_object, vm, "onmessage"_s, globalGetOnMessage, globalSetOnMessage, enumerableAccessor);

    global_object->cacheEventApi(event_constructor, event_prototype,
        JSColloEvent::createStructure(vm, global_object, event_prototype), custom_event_constructor,
        custom_event_prototype, JSColloCustomEvent::createStructure(vm, global_object, custom_event_prototype),
        message_event_constructor, message_event_prototype,
        JSColloMessageEvent::createStructure(vm, global_object, message_event_prototype), error_event_constructor,
        error_event_prototype, JSColloErrorEvent::createStructure(vm, global_object, error_event_prototype),
        close_event_constructor, close_event_prototype,
        JSColloCloseEvent::createStructure(vm, global_object, close_event_prototype), target_constructor,
        target_prototype, target_structure);
}

} // namespace Collo::HostFunctions
