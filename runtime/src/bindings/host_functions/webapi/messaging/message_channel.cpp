// MessageChannel and MessagePort: the two cells, delivery, transfer, and the constructors and methods. Runs on the
// VM thread, except visitChildren, which marking threads run concurrently.
//
// Each port holds its peer and its queued messages through WriteBarrier fields owned by the port, and its onmessage
// and onmessageerror handlers as event handler records in its listener list (event.h). The queue and the listener
// list are Collo::CellEdgeList (jsc/runtime/cell_edges.h), which owns the lock and barrier protocol visitChildren
// relies on. A started port with queued messages has one delivery microtask pending at a time, and each task
// dispatches one message. Closing a port drops its queue, listeners and handlers; transferring one moves its queue to
// the new port and drops the rest.

#include "host_functions/webapi/messaging/message_channel.h"

#include "host_functions/support.h"
#include "host_functions/webapi/dom/dom_exception.h"
#include "host_functions/webapi/events/event.h"
#include "host_functions/webapi/limits.h"
#include "host_functions/webapi/messaging/structured_clone.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/IteratorOperations.h>
#include <JavaScriptCore/JSArray.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSDestructibleObject.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/MarkedVector.h>
#include <JavaScriptCore/MicrotaskQueue.h>
#include <JavaScriptCore/MicrotaskQueueInlines.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <wtf/Scope.h>
#include <wtf/ScopedLambda.h>
#include <wtf/Vector.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/WTFString.h>

namespace Collo::HostFunctions {
namespace {

    using JSC::EncodedJSValue;
    using JSC::JSValue;
    using WTF::String;
    using namespace JSC;

    class JSColloMessagePort;
    class JSColloMessageChannel;

    static JSC_DECLARE_HOST_FUNCTION(messagePortDeliveryTask);

    // A message waiting in a port's queue. The port that owns the queue is the owner of both barriers.
    struct QueuedPortMessage {
        JSC::WriteBarrier<JSC::Unknown> data;
        JSC::WriteBarrier<JSC::JSObject> ports;

        template <typename Visitor> void visitEdges(Visitor& visitor) const
        {
            visitor.append(data);
            visitor.append(ports);
        }
    };

    class JSColloMessagePort final : public JSC::JSDestructibleObject {
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

        static JSColloMessagePort* create(JSC::VM& vm, JSC::Structure* structure)
        {
            auto* object = new (NotNull, JSC::allocateCell<JSColloMessagePort>(vm)) JSColloMessagePort(vm, structure);
            object->finishCreation(vm);
            return object;
        }

        static void destroy(JSC::JSCell* cell) { static_cast<JSColloMessagePort*>(cell)->~JSColloMessagePort(); }

        DECLARE_INFO;
        DECLARE_VISIT_CHILDREN;

        WebApiEventTargetHandle eventTargetHandle() { return { this, this, &m_event_target }; }
        JSColloMessagePort* peer() const { return m_peer.get(); }
        bool isTransferable() const { return !m_detached && !m_closed && m_peer.get(); }
        bool detached() const { return m_detached; }

        bool hasPendingMessageCapacity() const
        {
            return m_detached || m_closed || m_queue.size() < WebApiMessagePortPendingMessagesMax;
        }

        void entangle(JSC::VM& vm, JSColloMessagePort* peer) { m_peer.set(vm, this, peer); }

        void start()
        {
            if (m_detached || m_closed)
                return;
            m_started = true;
            scheduleDeliveryIfNeeded();
        }

        void close()
        {
            if (m_closed)
                return;
            m_closed = true;
            m_started = false;
            m_delivery_scheduled = false;
            m_queue.clear(this);
            clearWebApiEventTargetListeners(eventTargetHandle());

            if (auto* peer = m_peer.get()) {
                if (peer->m_peer.get() == this)
                    peer->m_peer.clear();
            }
            m_peer.clear();
        }

        // Checks the queue's bound and makes room for one message, so that an enqueue that follows with no other
        // change to this queue cannot fail. Throws a QuotaExceededError or an OutOfMemoryError and returns false
        // otherwise.
        bool reserveMessage(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
        {
            if (!hasPendingMessageCapacity()) {
                auto* exception = createDOMException(
                    global_object, DOMExceptionCode::QuotaExceededError, "MessagePort queue limit exceeded"_s);
                throwException(global_object, scope, exception);
                return false;
            }
            if (!m_queue.tryReserveAdditional(this, 1)) {
                throwOutOfMemoryError(global_object, scope);
                return false;
            }
            return true;
        }

        bool enqueue(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue data, JSC::JSObject* ports)
        {
            if (m_detached || m_closed)
                return true;
            if (!hasPendingMessageCapacity()) {
                auto* exception = createDOMException(
                    global_object, DOMExceptionCode::QuotaExceededError, "MessagePort queue limit exceeded"_s);
                throwException(global_object, scope, exception);
                return false;
            }
            QueuedPortMessage message;
            message.data.setWithoutWriteBarrier(data);
            if (ports)
                message.ports.setWithoutWriteBarrier(ports);
            if (!m_queue.tryAppend(global_object->vm(), this, WTF::move(message))) {
                throwOutOfMemoryError(global_object, scope);
                return false;
            }

            scheduleDeliveryIfNeeded();
            return true;
        }

        bool transferTo(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSColloMessagePort* clone)
        {
            if (!isTransferable()) {
                throwException(global_object, scope,
                    createDOMException(
                        global_object, DOMExceptionCode::DataCloneError, "MessagePort could not be transferred"_s));
                return false;
            }

            auto& vm = global_object->vm();
            auto* peer = m_peer.get();

            // The clone is new and its queue empty, so the queue moves without allocating.
            if (!clone->m_queue.tryAdoptAllFrom(vm, clone, m_queue, this)) {
                throwOutOfMemoryError(global_object, scope);
                return false;
            }

            clone->m_peer.set(vm, clone, peer);
            clone->m_started = false;
            clone->m_closed = false;
            clone->m_detached = false;
            clone->m_delivery_scheduled = false;

            if (peer && peer->m_peer.get() == this)
                peer->m_peer.set(vm, peer, clone);

            clearWebApiEventTargetListeners(eventTargetHandle());
            m_peer.clear();
            m_detached = true;
            m_started = false;
            m_delivery_scheduled = false;
            return true;
        }

        void scheduleDeliveryIfNeeded()
        {
            if (!m_started || m_delivery_scheduled || queueIsEmpty() || m_detached || m_closed)
                return;
            auto* global_object = this->realm();
            auto& vm = global_object->vm();
            m_delivery_scheduled = true;

            // The microtask holds only the callback, so the port rides on it as a property, which also keeps the port
            // alive until the task runs.
            auto* callback = JSC::JSFunction::create(vm, global_object, 0, "MessagePort delivery"_s,
                messagePortDeliveryTask, JSC::ImplementationVisibility::Public);
            RELEASE_ASSERT(callback);
            callback->putDirect(vm, JSC::Identifier::fromString(vm, "__colloMessagePort"_s), this,
                static_cast<unsigned>(JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::ReadOnly
                    | JSC::PropertyAttribute::DontDelete));
            global_object->queueMicrotask(
                vm, JSC::QueuedTask { nullptr, JSC::InternalMicrotask::InvokeFunctionJob, 0, global_object, callback });
        }

        EncodedJSValue deliverOne(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
        {
            m_delivery_scheduled = false;
            if (!m_started || m_queue.isEmpty() || m_detached || m_closed)
                return JSValue::encode(JSC::jsUndefined());

            auto message = m_queue.takeFirst(this);
            auto* event = createWebApiMessageEvent(global_object, message.data.get(), message.ports.get());
            dispatchWebApiEvent(global_object, scope, eventTargetHandle(), event);
            RETURN_IF_EXCEPTION(scope, {});

            // The next delivery is queued after the microtasks the handlers queued, so those run between two messages.
            scheduleDeliveryIfNeeded();
            return JSValue::encode(JSC::jsUndefined());
        }

    private:
        JSColloMessagePort(JSC::VM& vm, JSC::Structure* structure)
            : Base(vm, structure)
        {
        }

        ~JSColloMessagePort() = default;

        void finishCreation(JSC::VM& vm)
        {
            Base::finishCreation(vm);
            ASSERT(inherits(info()));
        }

        bool queueIsEmpty() const { return m_queue.isEmpty(); }

        WebApiEventTargetData m_event_target;
        JSC::WriteBarrier<JSColloMessagePort> m_peer;
        Collo::CellEdgeList<QueuedPortMessage> m_queue;
        bool m_started { false };
        bool m_closed { false };
        bool m_detached { false };
        bool m_delivery_scheduled { false };
    };

    // Holds its two ports through WriteBarriers only, so the cell needs no destructor and lives in the heap's plain
    // cell space.
    class JSColloMessageChannel final : public JSC::JSNonFinalObject {
        using Base = JSC::JSNonFinalObject;

    public:
        template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
        {
            return &vm.cellSpace();
        }

        static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSValue prototype)
        {
            return JSC::Structure::create(
                vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
        }

        static JSColloMessageChannel* create(JSC::VM& vm, JSC::Structure* structure, JSC::Structure* port_structure)
        {
            auto* object
                = new (NotNull, JSC::allocateCell<JSColloMessageChannel>(vm)) JSColloMessageChannel(vm, structure);
            object->finishCreation(vm, port_structure);
            return object;
        }

        DECLARE_INFO;
        DECLARE_VISIT_CHILDREN;

        JSColloMessagePort* port1() const { return m_port1.get(); }
        JSColloMessagePort* port2() const { return m_port2.get(); }

    private:
        JSColloMessageChannel(JSC::VM& vm, JSC::Structure* structure)
            : Base(vm, structure)
        {
        }

        void finishCreation(JSC::VM& vm, JSC::Structure* port_structure)
        {
            Base::finishCreation(vm);
            ASSERT(inherits(info()));
            auto* p1 = JSColloMessagePort::create(vm, port_structure);
            auto* p2 = JSColloMessagePort::create(vm, port_structure);
            p1->entangle(vm, p2);
            p2->entangle(vm, p1);
            m_port1.set(vm, this, p1);
            m_port2.set(vm, this, p2);
        }

        JSC::WriteBarrier<JSColloMessagePort> m_port1;
        JSC::WriteBarrier<JSColloMessagePort> m_port2;
    };

    const JSC::ClassInfo JSColloMessagePort::s_info
        = { "MessagePort"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloMessagePort) };
    const JSC::ClassInfo JSColloMessageChannel::s_info
        = { "MessageChannel"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloMessageChannel) };

    template <typename Visitor> void JSColloMessagePort::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
    {
        auto* this_object = static_cast<JSColloMessagePort*>(cell);
        ASSERT_GC_OBJECT_INHERITS(this_object, info());
        Base::visitChildren(this_object, visitor);
        visitor.append(this_object->m_peer);
        this_object->m_queue.visit(this_object, visitor);
        this_object->m_event_target.visit(this_object, visitor);
    }

    DEFINE_VISIT_CHILDREN(JSColloMessagePort);

    template <typename Visitor> void JSColloMessageChannel::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
    {
        auto* this_object = static_cast<JSColloMessageChannel*>(cell);
        ASSERT_GC_OBJECT_INHERITS(this_object, info());
        Base::visitChildren(this_object, visitor);
        visitor.append(this_object->m_port1);
        visitor.append(this_object->m_port2);
    }

    DEFINE_VISIT_CHILDREN(JSColloMessageChannel);

    static JSColloMessagePort* requireMessagePort(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value, WTF::ASCIILiteral operation)
    {
        if (auto* port = dynamicDowncast<JSColloMessagePort>(value))
            return port;
        JSC::throwVMTypeError(global_object, scope,
            WTF::makeString("Can only call MessagePort."_s, operation, " on instances of MessagePort"_s));
        return nullptr;
    }

    static JSColloMessageChannel* requireMessageChannel(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value, WTF::ASCIILiteral operation)
    {
        if (auto* channel = dynamicDowncast<JSColloMessageChannel>(value))
            return channel;
        JSC::throwVMTypeError(global_object, scope,
            WTF::makeString("Can only call MessageChannel."_s, operation, " on instances of MessageChannel"_s));
        return nullptr;
    }

    static JSC::Structure* messageChannelStructureForNewTarget(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame)
    {
        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        auto* new_target = call_frame->newTarget().getObject();
        auto* constructor = call_frame->jsCallee();
        auto* base = collo_global->webApiCache().message_channel_structure.get();
        RELEASE_ASSERT(base);
        if (!new_target || new_target == constructor)
            return base;
        auto* structure = JSC::InternalFunction::createSubclassStructure(global_object, new_target, base);
        RETURN_IF_EXCEPTION(scope, nullptr);
        return structure;
    }

    static JSValue transferListArgument(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
    {
        if (value.isUndefined())
            return JSC::jsUndefined();
        if (!value.isObject()) {
            JSC::throwVMTypeError(
                global_object, scope, "MessagePort.postMessage transfer must be an object or iterable"_s);
            return {};
        }

        auto& vm = global_object->vm();
        auto* object = value.getObject();
        auto maybe_transfer = object->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "transfer"_s));
        RETURN_IF_EXCEPTION(scope, {});
        if (maybe_transfer)
            return maybe_transfer;
        auto iterator_method = JSC::iteratorMethod(global_object, object);
        RETURN_IF_EXCEPTION(scope, {});
        if (iterator_method.isUndefinedOrNull())
            return JSC::jsUndefined();
        return value;
    }

    JSC_DEFINE_HOST_FUNCTION(messagePortDeliveryTask, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* callee = call_frame->jsCallee();
        auto value = callee->getDirect(vm, JSC::Identifier::fromString(vm, "__colloMessagePort"_s));
        auto* port = dynamicDowncast<JSColloMessagePort>(value);
        if (!port)
            return JSC::throwVMTypeError(global_object, scope, "Invalid MessagePort delivery task"_s);
        return port->deliverOne(global_object, scope);
    }

    JSC_DEFINE_HOST_FUNCTION(messageChannelConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        return JSC::throwVMTypeError(
            global_object, scope, "Use `new MessageChannel(...)` instead of `MessageChannel(...)`"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(
        messageChannelConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* structure = messageChannelStructureForNewTarget(global_object, scope, call_frame);
        RETURN_IF_EXCEPTION(scope, {});
        auto* port_structure
            = uncheckedDowncast<Collo::GlobalObject>(global_object)->webApiCache().message_port_structure.get();
        RELEASE_ASSERT(port_structure);
        return JSValue::encode(JSColloMessageChannel::create(vm, structure, port_structure));
    }

    JSC_DEFINE_HOST_FUNCTION(messagePortConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        return JSC::throwVMTypeError(
            global_object, scope, "Use `new MessagePort(...)` instead of `MessagePort(...)`"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(messagePortConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        return JSC::throwVMTypeError(
            global_object, scope, "Use `new MessagePort(...)` instead of `MessagePort(...)`"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(messageChannelGetPort1, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* channel = requireMessageChannel(global_object, scope, call_frame->thisValue(), "port1"_s);
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(channel->port1());
    }

    JSC_DEFINE_HOST_FUNCTION(messageChannelGetPort2, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* channel = requireMessageChannel(global_object, scope, call_frame->thisValue(), "port2"_s);
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(channel->port2());
    }

    JSC_DEFINE_HOST_FUNCTION(messagePortGetOnMessage, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* port = requireMessagePort(global_object, scope, call_frame->thisValue(), "onmessage"_s);
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(webApiEventHandler(port->eventTargetHandle(), "message"_s));
    }

    JSC_DEFINE_HOST_FUNCTION(messagePortSetOnMessage, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* port = requireMessagePort(global_object, scope, call_frame->thisValue(), "onmessage"_s);
        RETURN_IF_EXCEPTION(scope, {});
        auto stored = setWebApiEventHandler(
            global_object, scope, port->eventTargetHandle(), "message"_s, call_frame->argument(0));
        RETURN_IF_EXCEPTION(scope, {});
        if (!stored)
            return {};
        // HTML: setting onmessage enables the port message queue, as if start() had been called.
        if (!stored.isNull())
            port->start();
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(
        messagePortGetOnMessageError, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* port = requireMessagePort(global_object, scope, call_frame->thisValue(), "onmessageerror"_s);
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(webApiEventHandler(port->eventTargetHandle(), "messageerror"_s));
    }

    JSC_DEFINE_HOST_FUNCTION(
        messagePortSetOnMessageError, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* port = requireMessagePort(global_object, scope, call_frame->thisValue(), "onmessageerror"_s);
        RETURN_IF_EXCEPTION(scope, {});
        auto stored = setWebApiEventHandler(
            global_object, scope, port->eventTargetHandle(), "messageerror"_s, call_frame->argument(0));
        RETURN_IF_EXCEPTION(scope, {});
        if (!stored)
            return {};
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(messagePortPostMessage, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* port = requireMessagePort(global_object, scope, call_frame->thisValue(), "postMessage"_s);
        RETURN_IF_EXCEPTION(scope, {});
        if (call_frame->argumentCount() < 1)
            return JSC::throwVMTypeError(global_object, scope, "Not enough arguments"_s);

        // FIXME: HTML's message port post message steps serialize the message with its transfer list before they
        // return for a port without a peer, so the listed buffers and ports should still be detached.
        if (!port->peer())
            return JSValue::encode(JSC::jsUndefined());

        auto transfer_value = transferListArgument(global_object, scope, call_frame->argument(1));
        RETURN_IF_EXCEPTION(scope, {});

        auto* peer = port->peer();
        if (!peer)
            return JSValue::encode(JSC::jsUndefined());
        if (!peer->hasPendingMessageCapacity()) {
            auto* exception = createDOMException(
                global_object, DOMExceptionCode::QuotaExceededError, "MessagePort queue limit exceeded"_s);
            return JSValue::encode(JSC::throwException(global_object, scope, exception));
        }

        // The clone ran script (getters, the transfer iterator) that may have closed this port or filled the peer's
        // queue, so the peer is read again and its slot reserved before the commits: they detach their sources for
        // good, so enqueue must not fail after them.
        auto reserve_peer = [&] {
            peer = port->peer();
            return peer && peer->reserveMessage(global_object, scope);
        };
        JSC::JSValue cloned;
        JSC::JSObject* transferred_ports = nullptr;
        if (!structuredCloneAndCommitForWebApiMessage(global_object, scope, call_frame->argument(0), transfer_value,
                port, reserve_peer, cloned, transferred_ports)) {
            RETURN_IF_EXCEPTION(scope, {});
            // The port lost its peer while the message was cloned, so the message goes nowhere.
            return JSValue::encode(JSC::jsUndefined());
        }
        RETURN_IF_EXCEPTION(scope, {});

        if (!peer->enqueue(global_object, scope, cloned, transferred_ports))
            return {};
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(messagePortStart, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* port = requireMessagePort(global_object, scope, call_frame->thisValue(), "start"_s);
        RETURN_IF_EXCEPTION(scope, {});
        port->start();
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(messagePortClose, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* port = requireMessagePort(global_object, scope, call_frame->thisValue(), "close"_s);
        RETURN_IF_EXCEPTION(scope, {});
        port->close();
        return JSValue::encode(JSC::jsUndefined());
    }

} // namespace

bool webApiMessagePortTargetHandle(JSC::JSValue value, WebApiEventTargetHandle& handle)
{
    if (auto* port = dynamicDowncast<JSColloMessagePort>(value)) {
        handle = port->eventTargetHandle();
        return true;
    }
    return false;
}

bool webApiMessagePortIsValue(JSC::JSValue value) { return dynamicDowncast<JSColloMessagePort>(value); }

bool webApiMessagePortIsDetached(JSC::JSValue value)
{
    auto* port = dynamicDowncast<JSColloMessagePort>(value);
    return port && port->detached();
}

JSC::JSObject* webApiNormalizeMessagePortsArray(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue ports_value)
{
    if (ports_value.isUndefined()) {
        auto* empty = JSC::constructEmptyArray(global_object, nullptr);
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!empty) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return nullptr;
        }
        JSC::objectConstructorFreeze(global_object, empty);
        RETURN_IF_EXCEPTION(scope, nullptr);
        return empty;
    }
    if (ports_value.isNull()) {
        JSC::throwVMTypeError(global_object, scope, "MessageEvent constructor: eventInitDict.ports is not iterable."_s);
        return nullptr;
    }
    if (!ports_value.isObject()) {
        JSC::throwVMTypeError(global_object, scope, "MessageEvent constructor: eventInitDict.ports is not iterable."_s);
        return nullptr;
    }

    // The iterable runs script that can trigger a collection, so the ports it yields are rooted here until the array
    // holds them.
    JSC::MarkedVector<JSColloMessagePort*, 8, WTF::RecordOverflow> ports;
    JSC::forEachInIterable(global_object, ports_value, [&](JSC::VM&, JSC::JSGlobalObject*, JSValue value) {
        if (scope.exception())
            return;
        auto* port = dynamicDowncast<JSColloMessagePort>(value);
        if (!port) {
            JSC::throwVMTypeError(global_object, scope,
                "MessageEvent constructor: Expected every item of eventInitDict.ports to be an instance of MessagePort."_s);
            return;
        }
        if (ports.size() >= WebApiMessageEventPortsMax) {
            JSC::throwException(global_object, scope,
                createDOMException(
                    global_object, DOMExceptionCode::QuotaExceededError, "MessageEvent ports limit exceeded"_s));
            return;
        }
        ports.append(port);
        if (ports.hasOverflowed())
            JSC::throwOutOfMemoryError(global_object, scope);
    });
    RETURN_IF_EXCEPTION(scope, nullptr);

    auto* array = JSC::constructEmptyArray(global_object, nullptr, ports.size());
    RETURN_IF_EXCEPTION(scope, nullptr);
    if (!array) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return nullptr;
    }
    for (unsigned index = 0; index < ports.size(); index++) {
        array->putDirectIndex(global_object, index, ports[index]);
        RETURN_IF_EXCEPTION(scope, nullptr);
    }
    JSC::objectConstructorFreeze(global_object, array);
    RETURN_IF_EXCEPTION(scope, nullptr);
    return array;
}

JSC::JSObject* webApiCreateMessagePortTransferClone(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value)
{
    auto* source = dynamicDowncast<JSColloMessagePort>(value);
    if (!source || !source->isTransferable()) {
        JSC::throwException(global_object, scope,
            createDOMException(
                global_object, DOMExceptionCode::DataCloneError, "MessagePort could not be transferred"_s));
        return nullptr;
    }
    auto* structure = uncheckedDowncast<Collo::GlobalObject>(global_object)->webApiCache().message_port_structure.get();
    RELEASE_ASSERT(structure);
    return JSColloMessagePort::create(global_object->vm(), structure);
}

bool webApiValidateMessagePortTransfers(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const WTF::Vector<WebApiMessagePortTransfer>& transfers)
{
    for (auto& transfer : transfers) {
        auto* source = dynamicDowncast<JSColloMessagePort>(transfer.source);
        auto* clone = dynamicDowncast<JSColloMessagePort>(transfer.clone);
        if (!source || !clone || !source->isTransferable()) {
            throwException(global_object, scope,
                createDOMException(
                    global_object, DOMExceptionCode::DataCloneError, "MessagePort could not be transferred"_s));
            return false;
        }
        RETURN_IF_EXCEPTION(scope, false);
    }
    return true;
}

bool webApiCommitMessagePortTransfers(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, WTF::Vector<WebApiMessagePortTransfer>& transfers)
{
    if (!webApiValidateMessagePortTransfers(global_object, scope, transfers))
        return false;
    RETURN_IF_EXCEPTION(scope, false);

    for (auto& transfer : transfers) {
        auto* source = dynamicDowncast<JSColloMessagePort>(transfer.source);
        auto* clone = dynamicDowncast<JSColloMessagePort>(transfer.clone);
        RELEASE_ASSERT(source);
        RELEASE_ASSERT(clone);
        if (!source->transferTo(global_object, scope, clone))
            return false;
        RETURN_IF_EXCEPTION(scope, false);
    }
    return true;
}

// FIXME: HTML throws a DataCloneError only when the transfer list holds the sending port. When it holds the peer,
// HTML serializes the message with its transfers and then drops it without throwing; returning true for the peer
// makes that case throw.
bool webApiMessagePortTransferConflictsWith(JSC::JSObject* source_object, JSC::JSObject* sender_object)
{
    auto* source = dynamicDowncast<JSColloMessagePort>(source_object);
    auto* sender = dynamicDowncast<JSColloMessagePort>(sender_object);
    if (!source || !sender)
        return false;
    return source == sender || source == sender->peer();
}

void installWebApiMessageChannel(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    constexpr unsigned enumerableAccessor = static_cast<unsigned>(JSC::PropertyAttribute::Accessor);
    constexpr unsigned enumerableFunction = static_cast<unsigned>(JSC::PropertyAttribute::None);

    auto* channel_prototype = JSC::constructEmptyObject(global_object);
    auto* channel_constructor
        = JSC::JSFunction::create(vm, global_object, 0, "MessageChannel"_s, messageChannelConstructorCall,
            JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, messageChannelConstructorConstruct, nullptr);
    RELEASE_ASSERT(channel_constructor);
    channel_constructor->putDirect(vm, vm.propertyNames->prototype, channel_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    channel_prototype->putDirect(vm, vm.propertyNames->constructor, channel_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    putWebApiAccessor(
        global_object, channel_prototype, vm, "port1"_s, messageChannelGetPort1, nullptr, enumerableAccessor);
    putWebApiAccessor(
        global_object, channel_prototype, vm, "port2"_s, messageChannelGetPort2, nullptr, enumerableAccessor);
    channel_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::String("MessageChannel"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* port_prototype = JSC::constructEmptyObject(global_object);
    port_prototype->setPrototype(vm, global_object, global_object->eventTargetPrototype(), true);
    auto* port_constructor = JSC::JSFunction::create(vm, global_object, 0, "MessagePort"_s, messagePortConstructorCall,
        JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, messagePortConstructorConstruct, nullptr);
    RELEASE_ASSERT(port_constructor);
    port_constructor->setPrototype(vm, global_object, global_object->eventTargetConstructor(), true);
    port_constructor->putDirect(vm, vm.propertyNames->prototype, port_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    port_prototype->putDirect(
        vm, vm.propertyNames->constructor, port_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    putWebApiAccessor(global_object, port_prototype, vm, "onmessage"_s, messagePortGetOnMessage,
        messagePortSetOnMessage, enumerableAccessor);
    putWebApiAccessor(global_object, port_prototype, vm, "onmessageerror"_s, messagePortGetOnMessageError,
        messagePortSetOnMessageError, enumerableAccessor);
    putWebApiFunction(
        global_object, port_prototype, vm, "postMessage"_s, 1, messagePortPostMessage, enumerableFunction);
    putWebApiFunction(global_object, port_prototype, vm, "start"_s, 0, messagePortStart, enumerableFunction);
    putWebApiFunction(global_object, port_prototype, vm, "close"_s, 0, messagePortClose, enumerableFunction);
    port_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol, JSC::jsString(vm, WTF::String("MessagePort"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* channel_structure = JSColloMessageChannel::createStructure(vm, global_object, channel_prototype);
    auto* port_structure = JSColloMessagePort::createStructure(vm, global_object, port_prototype);
    auto& cache = global_object->webApiCache();
    cache.message_channel_constructor.set(vm, channel_constructor);
    cache.message_channel_prototype.set(vm, channel_prototype);
    cache.message_channel_structure.set(vm, channel_structure);
    cache.message_port_constructor.set(vm, port_constructor);
    cache.message_port_prototype.set(vm, port_prototype);
    cache.message_port_structure.set(vm, port_structure);

    // Web IDL defines interface objects as non-enumerable properties of the global object.
    global_object->putDirect(vm, JSC::Identifier::fromString(vm, "MessageChannel"_s), channel_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    global_object->putDirect(vm, JSC::Identifier::fromString(vm, "MessagePort"_s), port_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    RELEASE_ASSERT(global_object->getDirect(vm, JSC::Identifier::fromString(vm, "MessageChannel"_s)));
    RELEASE_ASSERT(global_object->getDirect(vm, JSC::Identifier::fromString(vm, "MessagePort"_s)));
}

} // namespace Collo::HostFunctions
