// The JSC cell classes behind Event, CustomEvent, MessageEvent, ErrorEvent, CloseEvent and EventTarget, private to
// the events module (event_types.cpp and event_target.cpp). VM thread only.
//
// No target has a parent, so a dispatch runs only the AT_TARGET phase: `bubbles` and `composed` are kept for their
// getters and route nothing. Every field that holds a JavaScript value is a WriteBarrier that the class's
// visitChildrenImpl visits, in event_types.cpp for the events and in event_target.cpp for EventTarget.

#pragma once

#include "host_functions/webapi/events/event.h"

#include <JavaScriptCore/CustomGetterSetter.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSDestructibleObject.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <JavaScriptCore/Strong.h>
#include <JavaScriptCore/StrongInlines.h>
#include <wtf/MonotonicTime.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

#include <cstdint>

namespace Collo::HostFunctions {

using JSC::EncodedJSValue;
using JSC::JSValue;
using JSC::JSObject;
using WTF::String;
using namespace JSC;

JSC_DECLARE_CUSTOM_GETTER(eventIsTrustedCustomGetter);

enum class EventPhase : uint8_t {
    None = 0,
    Capturing = 1,
    AtTarget = 2,
    Bubbling = 3,
};

class JSColloEvent : public JSC::JSDestructibleObject {
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

    // `trusted` stays false for events script constructs; createWebApiEvent passes true for events the runtime fires.
    static JSColloEvent* create(JSC::VM& vm, Collo::GlobalObject* global_object, JSC::Structure* structure, String type,
        bool bubbles, bool cancelable, bool composed, bool trusted = false)
    {
        auto* object = new (NotNull, JSC::allocateCell<JSColloEvent>(vm))
            JSColloEvent(vm, structure, WTF::move(type), bubbles, cancelable, composed, trusted);
        object->finishCreation(vm, global_object);
        return object;
    }

    static void destroy(JSC::JSCell* cell) { static_cast<JSColloEvent*>(cell)->~JSColloEvent(); }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    const String& type() const { return m_type; }
    JSC::JSObject* target() const { return m_target.get(); }
    JSC::JSObject* currentTarget() const { return m_current_target.get(); }
    EventPhase phase() const { return m_phase; }
    bool bubbles() const { return m_bubbles; }
    bool cancelable() const { return m_cancelable; }
    bool composed() const { return m_composed; }
    bool defaultPrevented() const { return m_default_prevented; }
    bool propagationStopped() const { return m_propagation_stopped || m_immediate_propagation_stopped; }
    bool immediatePropagationStopped() const { return m_immediate_propagation_stopped; }
    bool dispatching() const { return m_dispatching; }
    double timeStampMs() const { return m_created.secondsSinceEpoch().milliseconds(); }

    void stopPropagation() { m_propagation_stopped = true; }
    void stopImmediatePropagation()
    {
        m_propagation_stopped = true;
        m_immediate_propagation_stopped = true;
    }

    bool cancelBubble() const { return propagationStopped(); }
    void setCancelBubble(bool value)
    {
        if (value)
            m_propagation_stopped = true;
    }

    bool returnValue() const { return !m_default_prevented; }
    bool isTrusted() const { return m_trusted; }
    void setUntrusted() { m_trusted = false; }
    void setReturnValue(bool value)
    {
        if (!value)
            preventDefault();
    }

    void preventDefault()
    {
        if (m_cancelable && !m_in_passive_listener)
            m_default_prevented = true;
    }

    // Set around a passive listener's call, during which preventDefault() has no effect.
    void setPassive(bool passive) { m_in_passive_listener = passive; }

    void initEvent(String type, bool bubbles, bool cancelable)
    {
        if (m_dispatching)
            return;
        m_type = WTF::move(type);
        m_bubbles = bubbles;
        m_cancelable = cancelable;
        m_composed = false;
        // DOM standard, initialize an event: isTrusted becomes false.
        m_trusted = false;
        m_propagation_stopped = false;
        m_immediate_propagation_stopped = false;
        m_default_prevented = false;
        m_target.clear();
        m_current_target.clear();
        m_phase = EventPhase::None;
    }

    void startDispatch(JSC::VM& vm, JSC::JSObject* target)
    {
        m_dispatching = true;
        m_target.set(vm, this, target);
        m_current_target.set(vm, this, target);
        m_phase = EventPhase::AtTarget;
        m_propagation_stopped = false;
        m_immediate_propagation_stopped = false;
    }

    void finishDispatch()
    {
        m_dispatching = false;
        m_current_target.clear();
        m_phase = EventPhase::None;
        m_propagation_stopped = false;
        m_immediate_propagation_stopped = false;
        m_in_passive_listener = false;
    }

protected:
    JSColloEvent(JSC::VM& vm, JSC::Structure* structure, String type, bool bubbles, bool cancelable, bool composed,
        bool trusted = false)
        : Base(vm, structure)
        , m_type(WTF::move(type))
        , m_created(WTF::MonotonicTime::now())
        , m_bubbles(bubbles)
        , m_cancelable(cancelable)
        , m_composed(composed)
        , m_trusted(trusted)
    {
    }

    ~JSColloEvent() = default;

    void finishCreation(JSC::VM& vm, Collo::GlobalObject* global_object)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
        // isTrusted is [LegacyUnforgeable] in the DOM standard's IDL, so it is an own, non-configurable property of
        // each event instead of a prototype accessor.
        putDirectCustomAccessor(vm, JSC::Identifier::fromString(vm, "isTrusted"_s),
            JSC::CustomGetterSetter::create(vm, eventIsTrustedCustomGetter, nullptr),
            static_cast<unsigned>(JSC::PropertyAttribute::CustomAccessor | JSC::PropertyAttribute::DontDelete
                | JSC::PropertyAttribute::ReadOnly));
    }

    String m_type;
    WTF::MonotonicTime m_created;
    JSC::WriteBarrier<JSC::JSObject> m_target;
    JSC::WriteBarrier<JSC::JSObject> m_current_target;
    EventPhase m_phase { EventPhase::None };
    bool m_bubbles { false };
    bool m_cancelable { false };
    bool m_composed { false };
    bool m_trusted { false };
    bool m_default_prevented { false };
    bool m_propagation_stopped { false };
    bool m_immediate_propagation_stopped { false };
    bool m_in_passive_listener { false };
    bool m_dispatching { false };
};

class JSColloCustomEvent final : public JSColloEvent {
    using Base = JSColloEvent;

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

    static JSColloCustomEvent* create(JSC::VM& vm, Collo::GlobalObject* global_object, JSC::Structure* structure,
        String type, bool bubbles, bool cancelable, bool composed, JSValue detail)
    {
        auto* object = new (NotNull, JSC::allocateCell<JSColloCustomEvent>(vm))
            JSColloCustomEvent(vm, structure, WTF::move(type), bubbles, cancelable, composed);
        object->finishCreation(vm, global_object, detail);
        return object;
    }

    static void destroy(JSC::JSCell* cell) { static_cast<JSColloCustomEvent*>(cell)->~JSColloCustomEvent(); }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    JSValue detail() const { return m_detail.get(); }

    void initCustomEvent(JSC::VM& vm, String type, bool bubbles, bool cancelable, JSValue detail)
    {
        if (dispatching())
            return;
        initEvent(WTF::move(type), bubbles, cancelable);
        m_detail.set(vm, this, detail);
    }

private:
    JSColloCustomEvent(
        JSC::VM& vm, JSC::Structure* structure, String type, bool bubbles, bool cancelable, bool composed)
        : Base(vm, structure, WTF::move(type), bubbles, cancelable, composed)
    {
    }

    ~JSColloCustomEvent() = default;

    void finishCreation(JSC::VM& vm, Collo::GlobalObject* global_object, JSValue detail)
    {
        Base::finishCreation(vm, global_object);
        ASSERT(inherits(info()));
        m_detail.set(vm, this, detail);
    }

    JSC::WriteBarrier<JSC::Unknown> m_detail;
};

class JSColloMessageEvent final : public JSColloEvent {
    using Base = JSColloEvent;

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

    static JSColloMessageEvent* create(JSC::VM& vm, Collo::GlobalObject* global_object, JSC::Structure* structure,
        String type, bool bubbles, bool cancelable, bool composed, JSValue data, String origin, String last_event_id,
        JSValue source, JSObject* ports)
    {
        auto* object = new (NotNull, JSC::allocateCell<JSColloMessageEvent>(vm)) JSColloMessageEvent(
            vm, structure, WTF::move(type), bubbles, cancelable, composed, WTF::move(origin), WTF::move(last_event_id));
        object->finishCreation(vm, global_object, data, source, ports);
        return object;
    }

    static void destroy(JSC::JSCell* cell) { static_cast<JSColloMessageEvent*>(cell)->~JSColloMessageEvent(); }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    JSValue data() const { return m_data.get(); }
    const String& origin() const { return m_origin; }
    const String& lastEventId() const { return m_last_event_id; }
    JSValue source() const { return m_source.get(); }
    // The ports attribute: the stored array, or an empty frozen one created and kept on first read. Returns null
    // with an exception thrown into `scope` when that allocation fails.
    JSObject* ensurePorts(JSC::JSGlobalObject*, JSC::ThrowScope&);

    void initMessageEvent(JSC::VM& vm, String type, bool bubbles, bool cancelable, JSValue data, String origin,
        String last_event_id, JSValue source, JSObject* ports)
    {
        if (dispatching())
            return;
        initEvent(WTF::move(type), bubbles, cancelable);
        m_data.set(vm, this, data);
        m_origin = WTF::move(origin);
        m_last_event_id = WTF::move(last_event_id);
        m_source.set(vm, this, source);
        if (ports)
            m_ports.set(vm, this, ports);
        else
            m_ports.clear();
    }

private:
    JSColloMessageEvent(JSC::VM& vm, JSC::Structure* structure, String type, bool bubbles, bool cancelable,
        bool composed, String origin, String last_event_id)
        : Base(vm, structure, WTF::move(type), bubbles, cancelable, composed)
        , m_origin(WTF::move(origin))
        , m_last_event_id(WTF::move(last_event_id))
    {
    }

    ~JSColloMessageEvent() = default;

    void finishCreation(JSC::VM& vm, Collo::GlobalObject* global_object, JSValue data, JSValue source, JSObject* ports)
    {
        Base::finishCreation(vm, global_object);
        ASSERT(inherits(info()));
        m_data.set(vm, this, data);
        m_source.set(vm, this, source);
        if (ports)
            m_ports.set(vm, this, ports);
    }

    JSC::WriteBarrier<JSC::Unknown> m_data;
    String m_origin;
    String m_last_event_id;
    JSC::WriteBarrier<JSC::Unknown> m_source;
    JSC::WriteBarrier<JSC::JSObject> m_ports;
};

class JSColloErrorEvent final : public JSColloEvent {
    using Base = JSColloEvent;

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

    static JSColloErrorEvent* create(JSC::VM& vm, Collo::GlobalObject* global_object, JSC::Structure* structure,
        String type, bool bubbles, bool cancelable, bool composed, String message, String filename, uint32_t lineno,
        uint32_t colno, JSValue error)
    {
        auto* object = new (NotNull, JSC::allocateCell<JSColloErrorEvent>(vm)) JSColloErrorEvent(vm, structure,
            WTF::move(type), bubbles, cancelable, composed, WTF::move(message), WTF::move(filename), lineno, colno);
        object->finishCreation(vm, global_object, error);
        return object;
    }

    static void destroy(JSC::JSCell* cell) { static_cast<JSColloErrorEvent*>(cell)->~JSColloErrorEvent(); }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    const String& message() const { return m_message; }
    const String& filename() const { return m_filename; }
    uint32_t lineno() const { return m_lineno; }
    uint32_t colno() const { return m_colno; }
    JSValue error() const { return m_error.get(); }

private:
    JSColloErrorEvent(JSC::VM& vm, JSC::Structure* structure, String type, bool bubbles, bool cancelable, bool composed,
        String message, String filename, uint32_t lineno, uint32_t colno)
        : Base(vm, structure, WTF::move(type), bubbles, cancelable, composed)
        , m_message(WTF::move(message))
        , m_filename(WTF::move(filename))
        , m_lineno(lineno)
        , m_colno(colno)
    {
    }

    ~JSColloErrorEvent() = default;

    void finishCreation(JSC::VM& vm, Collo::GlobalObject* global_object, JSValue error)
    {
        Base::finishCreation(vm, global_object);
        ASSERT(inherits(info()));
        m_error.set(vm, this, error);
    }

    String m_message;
    String m_filename;
    uint32_t m_lineno { 0 };
    uint32_t m_colno { 0 };
    JSC::WriteBarrier<JSC::Unknown> m_error;
};

class JSColloCloseEvent final : public JSColloEvent {
    using Base = JSColloEvent;

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

    static JSColloCloseEvent* create(JSC::VM& vm, Collo::GlobalObject* global_object, JSC::Structure* structure,
        String type, bool bubbles, bool cancelable, bool composed, bool was_clean, uint16_t code, String reason)
    {
        auto* object = new (NotNull, JSC::allocateCell<JSColloCloseEvent>(vm)) JSColloCloseEvent(
            vm, structure, WTF::move(type), bubbles, cancelable, composed, was_clean, code, WTF::move(reason));
        object->finishCreation(vm, global_object);
        return object;
    }

    static void destroy(JSC::JSCell* cell) { static_cast<JSColloCloseEvent*>(cell)->~JSColloCloseEvent(); }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    bool wasClean() const { return m_was_clean; }
    uint16_t code() const { return m_code; }
    const String& reason() const { return m_reason; }

private:
    JSColloCloseEvent(JSC::VM& vm, JSC::Structure* structure, String type, bool bubbles, bool cancelable, bool composed,
        bool was_clean, uint16_t code, String reason)
        : Base(vm, structure, WTF::move(type), bubbles, cancelable, composed)
        , m_reason(WTF::move(reason))
        , m_code(code)
        , m_was_clean(was_clean)
    {
    }

    ~JSColloCloseEvent() = default;

    String m_reason;
    uint16_t m_code { 0 };
    bool m_was_clean { false };
};

// An EventTarget script constructs, and the cell that holds the global object's listeners.
class JSColloEventTarget final : public JSC::JSDestructibleObject {
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

    static JSColloEventTarget* create(JSC::VM& vm, JSC::Structure* structure)
    {
        auto* object = new (NotNull, JSC::allocateCell<JSColloEventTarget>(vm)) JSColloEventTarget(vm, structure);
        object->finishCreation(vm);
        return object;
    }

    static void destroy(JSC::JSCell* cell) { static_cast<JSColloEventTarget*>(cell)->~JSColloEventTarget(); }

    DECLARE_INFO;
    DECLARE_VISIT_CHILDREN;

    WebApiEventTargetData& eventTargetData() { return m_event_target; }

private:
    JSColloEventTarget(JSC::VM& vm, JSC::Structure* structure)
        : Base(vm, structure)
    {
    }

    ~JSColloEventTarget() = default;

    void finishCreation(JSC::VM& vm)
    {
        Base::finishCreation(vm);
        ASSERT(inherits(info()));
    }

    WebApiEventTargetData m_event_target;
};

JSC_DECLARE_HOST_FUNCTION(eventTargetConstructorCall);
JSC_DECLARE_HOST_FUNCTION(eventTargetConstructorConstruct);
JSC_DECLARE_HOST_FUNCTION(eventTargetAddEventListener);
JSC_DECLARE_HOST_FUNCTION(eventTargetRemoveEventListener);
JSC_DECLARE_HOST_FUNCTION(eventTargetDispatchEvent);
JSC_DECLARE_HOST_FUNCTION(globalAddEventListener);
JSC_DECLARE_HOST_FUNCTION(globalRemoveEventListener);
JSC_DECLARE_HOST_FUNCTION(globalDispatchEvent);
JSC_DECLARE_HOST_FUNCTION(globalGetOnError);
JSC_DECLARE_HOST_FUNCTION(globalSetOnError);
JSC_DECLARE_HOST_FUNCTION(globalGetOnMessage);
JSC_DECLARE_HOST_FUNCTION(globalSetOnMessage);

} // namespace Collo::HostFunctions
