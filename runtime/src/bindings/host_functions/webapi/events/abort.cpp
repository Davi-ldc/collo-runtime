// AbortController and AbortSignal: their host functions, the AbortController cell, and JSColloAbortSignal's
// implementation, including the DOM standard's signal abort. VM thread only. The ownership and locking rules of the
// signal's lists are in abort.h.

#include "host_functions/webapi/events/abort.h"

#include "host_functions/runtime/bridge.h"
#include "host_functions/runtime/timers.h"
#include "host_functions/webapi/dom/dom_exception.h"
#include "host_functions/webapi/limits.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/IteratorOperations.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <JavaScriptCore/WeakInlines.h>
#include <wtf/Scope.h>
#include <wtf/Vector.h>
#include <wtf/text/MakeString.h>

#include <cmath>
#include <limits>
#include <optional>

namespace Collo::HostFunctions {
namespace {

    using JSC::EncodedJSValue;
    using JSC::JSValue;
    using WTF::String;
    using namespace JSC;

    // Owns one signal, created with the controller and never replaced.
    class JSColloAbortController final : public JSC::JSDestructibleObject {
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

        static JSColloAbortController* create(
            JSC::VM& vm, Collo::GlobalObject* global_object, JSC::Structure* structure)
        {
            auto* object
                = new (NotNull, JSC::allocateCell<JSColloAbortController>(vm)) JSColloAbortController(vm, structure);
            object->finishCreation(vm, global_object);
            return object;
        }

        static void destroy(JSC::JSCell* cell)
        {
            static_cast<JSColloAbortController*>(cell)->~JSColloAbortController();
        }

        DECLARE_INFO;
        DECLARE_VISIT_CHILDREN;

        JSColloAbortSignal* signal() const { return m_signal.get(); }

    private:
        JSColloAbortController(JSC::VM& vm, JSC::Structure* structure)
            : Base(vm, structure)
        {
        }

        ~JSColloAbortController() = default;

        void finishCreation(JSC::VM& vm, Collo::GlobalObject* global_object)
        {
            Base::finishCreation(vm);
            ASSERT(inherits(info()));
            auto* signal = JSColloAbortSignal::create(vm, global_object, global_object->abortSignalStructure());
            m_signal.set(vm, this, signal);
        }

        JSC::WriteBarrier<JSColloAbortSignal> m_signal;
    };

    const JSC::ClassInfo JSColloAbortController::s_info
        = { "AbortController"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloAbortController) };

    template <typename Visitor> void JSColloAbortController::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
    {
        auto* this_object = static_cast<JSColloAbortController*>(cell);
        ASSERT_GC_OBJECT_INHERITS(this_object, info());
        Base::visitChildren(this_object, visitor);
        visitor.append(this_object->m_signal);
    }

    DEFINE_VISIT_CHILDREN(JSColloAbortController);

    static JSColloAbortController* requireAbortController(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
    {
        if (auto* controller = dynamicDowncast<JSColloAbortController>(value))
            return controller;
        JSC::throwVMTypeError(global_object, scope, "AbortController method called on incompatible receiver"_s);
        return nullptr;
    }

    static JSColloAbortSignal* requireAbortSignal(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
    {
        if (auto* signal = webApiAbortSignalFromValue(value))
            return signal;
        JSC::throwVMTypeError(global_object, scope, "AbortSignal method called on incompatible receiver"_s);
        return nullptr;
    }

    static bool requireArgumentCount(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        JSC::CallFrame* call_frame, unsigned count, WTF::ASCIILiteral message)
    {
        if (call_frame->argumentCount() >= count)
            return true;
        JSC::throwVMTypeError(global_object, scope, message);
        return false;
    }

    static JSC::Structure* abortControllerStructureForNewTarget(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame)
    {
        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        auto* new_target = call_frame->newTarget().getObject();
        auto* constructor = call_frame->jsCallee();
        if (!new_target || new_target == constructor)
            return collo_global->abortControllerStructure();
        auto* structure = JSC::InternalFunction::createSubclassStructure(
            global_object, new_target, collo_global->abortControllerStructure());
        RETURN_IF_EXCEPTION(scope, nullptr);
        return structure;
    }

    static std::optional<double> enforceTimeoutDelay(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
    {
        double raw = value.toNumber(global_object);
        RETURN_IF_EXCEPTION(scope, std::nullopt);
        if (!std::isfinite(raw) || raw < 0 || raw > static_cast<double>(std::numeric_limits<uint64_t>::max())) {
            JSC::throwVMTypeError(global_object, scope, "AbortSignal.timeout requires a finite non-negative delay"_s);
            return std::nullopt;
        }
        return std::floor(raw);
    }

    static uint32_t timerDelayMsFromAbortDelay(double delay)
    {
        constexpr double max_timer_delay_ms = 2147483647.0;
        if (delay > max_timer_delay_ms)
            return static_cast<uint32_t>(max_timer_delay_ms);
        return static_cast<uint32_t>(delay);
    }

    JSC_DEFINE_HOST_FUNCTION(
        abortSignalTimeoutCallback, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* callee = call_frame->jsCallee();
        auto signal_value = callee->get(global_object, JSC::Identifier::fromString(vm, "__colloAbortSignal"_s));
        RETURN_IF_EXCEPTION(scope, {});
        auto* signal = webApiAbortSignalFromValue(signal_value);
        if (!signal)
            return JSValue::encode(JSC::jsUndefined());
        // The timer has fired, so the abort below must not try to cancel it.
        signal->clearTimeoutTimerId();
        signal->signalAbort(vm, global_object, createDOMException(global_object, DOMExceptionCode::TimeoutError));
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(abortControllerConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        return JSC::throwVMTypeError(global_object, scope, "AbortController constructor requires 'new'"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(
        abortControllerConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* structure = abortControllerStructureForNewTarget(global_object, scope, call_frame);
        RETURN_IF_EXCEPTION(scope, {});
        if (!structure)
            return {};
        return JSValue::encode(
            JSColloAbortController::create(vm, uncheckedDowncast<Collo::GlobalObject>(global_object), structure));
    }

    JSC_DEFINE_HOST_FUNCTION(abortSignalConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        return JSC::throwVMTypeError(global_object, scope, "AbortSignal constructor is not public"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(abortSignalConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        return JSC::throwVMTypeError(global_object, scope, "AbortSignal constructor is not public"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(
        abortControllerGetSignal, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* controller = requireAbortController(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (!controller)
            return {};
        return JSValue::encode(controller->signal());
    }

    JSC_DEFINE_HOST_FUNCTION(abortControllerAbort, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* controller = requireAbortController(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (!controller)
            return {};
        controller->signal()->signalAbort(vm, global_object, call_frame->argument(0));
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(abortSignalStaticAbort, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        auto reason = call_frame->argument(0);
        // DOM standard, AbortSignal.abort(): the signal is born aborted, so no abort event fires and no listener can
        // have been registered.
        auto* signal = JSColloAbortSignal::create(
            vm, collo_global, collo_global->abortSignalStructure(), /* aborted */ true, reason);
        return JSValue::encode(signal);
    }

    JSC_DEFINE_HOST_FUNCTION(
        abortSignalStaticTimeout, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        if (!requireArgumentCount(global_object, scope, call_frame, 1, "AbortSignal.timeout requires a delay"_s))
            return {};
        auto delay = enforceTimeoutDelay(global_object, scope, call_frame->argument(0));
        RETURN_IF_EXCEPTION(scope, {});
        if (!delay)
            return {};

        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        auto* signal = JSColloAbortSignal::create(vm, collo_global, collo_global->abortSignalStructure());

        auto owner_result = Runtime::requireVmOwner(global_object, scope);
        if (!owner_result.ok)
            return owner_result.error;
        void* runtime_handle = Runtime::hostRuntime(*owner_result.owner);
        ColloExecCtx* exec_ctx = Runtime::activeExecContext(*owner_result.owner);
        if (!runtime_handle || !exec_ctx) {
            auto* exception = createDOMException(
                global_object, DOMExceptionCode::InvalidStateError, "AbortSignal.timeout requires an active request"_s);
            return JSValue::encode(JSC::throwException(global_object, scope, exception));
        }

        auto* callback = JSC::JSFunction::create(vm, global_object, 0, "AbortSignal timeout"_s,
            abortSignalTimeoutCallback, JSC::ImplementationVisibility::Public);
        RELEASE_ASSERT(callback);
        // The timer retains only the callback, so the signal rides on it as a property and lives until the timer
        // fires or is cancelled.
        callback->putDirect(vm, JSC::Identifier::fromString(vm, "__colloAbortSignal"_s), signal,
            static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
        Runtime::ActiveRequestRuntime runtime { owner_result.owner, runtime_handle, exec_ctx };
        // Node and Bun unref this timer so that it never keeps the process alive. The runtime has no unref bit and
        // needs none: request finish cancels every pending timer of the request (cleanupRequestSubresources in
        // worker/serve/response_finish.zig). Only this timer aborts a timeout signal, which has no controller and
        // never becomes a dependent, so the timer holds the callback, the signal and a max_timers_per_worker slot
        // until it fires or its request finishes. The id recorded below serves only collectAbortSteps' cancel branch,
        // which never runs.
        auto scheduled = Runtime::scheduleTimerValue(
            global_object, scope, runtime, callback, nullptr, 0, timerDelayMsFromAbortDelay(*delay), false);
        RETURN_IF_EXCEPTION(scope, {});
        if (!scheduled)
            return {};
        JSValue timer_id_value = JSValue::decode(*scheduled);
        if (timer_id_value.isNumber()) {
            double timer_id = timer_id_value.asNumber();
            if (timer_id >= 1.0)
                signal->setTimeoutTimerId(static_cast<uint64_t>(timer_id));
        }
        return JSValue::encode(signal);
    }

    JSC_DEFINE_HOST_FUNCTION(abortSignalStaticAny, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        if (!requireArgumentCount(global_object, scope, call_frame, 1, "AbortSignal.any requires an iterable"_s))
            return {};
        auto iterable_value = call_frame->argument(0);
        auto* iterable = dynamicDowncast<JSC::JSObject>(iterable_value);
        if (!iterable)
            return JSC::throwVMTypeError(global_object, scope, "AbortSignal.any requires an iterable"_s);
        auto iterator_method = JSC::iteratorMethod(global_object, iterable);
        RETURN_IF_EXCEPTION(scope, {});
        if (iterator_method.isUndefinedOrNull())
            return JSC::throwVMTypeError(global_object, scope, "AbortSignal.any requires an iterable"_s);

        // The iteration runs script that can trigger a collection, so the signals it yields are rooted here. A signal
        // the iterable repeats is kept once, which also bounds the list by the distinct signals.
        JSC::MarkedVector<JSColloAbortSignal*, 8, WTF::RecordOverflow> sources;
        unsigned yielded = 0;
        bool failed = false;
        JSC::forEachInIterable(global_object, iterable_value, [&](JSC::VM&, JSC::JSGlobalObject*, JSValue value) {
            if (failed)
                return;
            auto* source = requireAbortSignal(global_object, scope, value);
            if (!source) {
                failed = true;
                return;
            }
            if (++yielded > WebApiAbortSignalAnySourcesMax) {
                failed = true;
                JSC::throwException(global_object, scope,
                    createDOMException(global_object, DOMExceptionCode::QuotaExceededError,
                        "AbortSignal.any input limit exceeded"_s));
                return;
            }
            for (auto* seen : sources) {
                if (seen == source)
                    return;
            }
            sources.append(source);
            if (sources.hasOverflowed()) {
                failed = true;
                JSC::throwOutOfMemoryError(global_object, scope);
            }
        });
        RETURN_IF_EXCEPTION(scope, {});
        if (failed)
            return {};
        auto* result = createDependentAbortSignal(global_object, scope, sources.span());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(result);
    }

#define COLLO_ABORT_SIGNAL_GETTER(name, expr)                                                                          \
    JSC_DEFINE_HOST_FUNCTION(name, (JSC::JSGlobalObject * global_object, JSC::CallFrame * call_frame))                 \
    {                                                                                                                  \
        auto& vm = global_object->vm();                                                                                \
        auto scope = DECLARE_THROW_SCOPE(vm);                                                                          \
        auto* signal = requireAbortSignal(global_object, scope, call_frame->thisValue());                              \
        RETURN_IF_EXCEPTION(scope, {});                                                                                \
        if (!signal)                                                                                                   \
            return {};                                                                                                 \
        return JSValue::encode(expr);                                                                                  \
    }

    COLLO_ABORT_SIGNAL_GETTER(abortSignalGetAborted, JSC::jsBoolean(signal->aborted()))
    COLLO_ABORT_SIGNAL_GETTER(abortSignalGetReason, signal->reason())
    COLLO_ABORT_SIGNAL_GETTER(abortSignalGetOnAbort, signal->onabort())

#undef COLLO_ABORT_SIGNAL_GETTER

    JSC_DEFINE_HOST_FUNCTION(abortSignalSetOnAbort, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* signal = requireAbortSignal(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (!signal)
            return {};
        if (!signal->setOnAbort(vm, global_object, scope, call_frame->argument(0)))
            return {};
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(
        abortSignalThrowIfAborted, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* signal = requireAbortSignal(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (!signal)
            return {};
        if (signal->aborted())
            return JSValue::encode(JSC::throwException(global_object, scope, signal->reason()));
        return JSValue::encode(JSC::jsUndefined());
    }

} // namespace

const JSC::ClassInfo JSColloAbortSignal::s_info = { "AbortSignal"_s, &JSC::JSDestructibleObject::s_info, nullptr,
    nullptr, CREATE_METHOD_TABLE(JSColloAbortSignal) };

JSC::Structure* JSColloAbortSignal::createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSValue prototype)
{
    return JSC::Structure::create(vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
}

JSColloAbortSignal* JSColloAbortSignal::create(
    JSC::VM& vm, Collo::GlobalObject* global_object, JSC::Structure* structure, bool aborted, JSC::JSValue reason)
{
    auto* object = new (NotNull, JSC::allocateCell<JSColloAbortSignal>(vm)) JSColloAbortSignal(vm, structure, aborted);
    object->finishCreation(vm, global_object, reason);
    return object;
}

void JSColloAbortSignal::destroy(JSC::JSCell* cell) { static_cast<JSColloAbortSignal*>(cell)->~JSColloAbortSignal(); }

JSColloAbortSignal::JSColloAbortSignal(JSC::VM& vm, JSC::Structure* structure, bool aborted)
    : Base(vm, structure)
    , m_aborted(aborted)
{
}

void JSColloAbortSignal::finishCreation(JSC::VM& vm, Collo::GlobalObject* global_object, JSC::JSValue reason)
{
    Base::finishCreation(vm);
    ASSERT(inherits(info()));
    m_reason.set(vm, this, reason);
    m_onabort.set(vm, this, JSC::jsNull());
    if (m_aborted && reason.isUndefined())
        m_reason.set(vm, this, createDOMException(global_object, DOMExceptionCode::AbortError));
}

template <typename Visitor> void JSColloAbortSignal::visitChildrenImpl(JSC::JSCell* cell, Visitor& visitor)
{
    auto* this_object = static_cast<JSColloAbortSignal*>(cell);
    ASSERT_GC_OBJECT_INHERITS(this_object, info());
    Base::visitChildren(this_object, visitor);
    appendWebApiUnknown(visitor, this_object->m_reason);
    appendWebApiUnknown(visitor, this_object->m_onabort);
    this_object->m_event_target.visit(this_object, visitor);
    this_object->m_cleanup_records.visit(this_object, visitor);
    this_object->m_abort_algorithms.visit(this_object, visitor);
    this_object->m_source_signals.visit(this_object, visitor);
}

DEFINE_VISIT_CHILDREN(JSColloAbortSignal);

JSC::JSValue JSColloAbortSignal::normalizedAbortReason(JSC::JSGlobalObject* global_object, JSC::JSValue reason)
{
    if (!reason.isUndefined())
        return reason;
    return createDOMException(global_object, DOMExceptionCode::AbortError);
}

static void removeAbortAttributeHandler(JSColloAbortSignal* signal, JSC::JSValue callback)
{
    auto& data = signal->eventTargetData();
    const auto& listeners = data.listeners();
    for (size_t index = 0; index < listeners.size(); index++) {
        const auto& listener = listeners.at(index);
        if (listener.removed || !listener.attribute_handler || listener.type != "abort"_s)
            continue;
        if (!JSC::JSValue::strictEqual(nullptr, listener.callback.get(), callback))
            continue;
        data.markRemoved(index);
        break;
    }
    data.compactRemovedIfIdle(signal);
}

// The previous handler's record goes before the new one is added, so replacing the handler on a signal at the
// listener cap succeeds; a new record that cannot be stored leaves onabort null.
bool JSColloAbortSignal::setOnAbort(
    JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value)
{
    auto previous = m_onabort.get();
    auto call_data = JSC::getCallData(value);
    JSValue normalized = call_data.type == JSC::CallData::Type::None ? JSC::jsNull() : value;
    if (!previous.isNull())
        removeAbortAttributeHandler(this, previous);
    m_onabort.set(vm, this, JSC::jsNull());
    if (normalized.isNull())
        return true;

    WebApiEventListenerRecord record;
    record.type = "abort"_s;
    record.callback.setWithoutWriteBarrier(normalized);
    record.order = m_event_target.allocateListenerOrder();
    record.attribute_handler = true;
    switch (m_event_target.appendListener(vm, this, WTF::move(record))) {
    case WebApiEventTargetData::AppendResult::Appended:
        m_onabort.set(vm, this, normalized);
        return true;
    case WebApiEventTargetData::AppendResult::LimitReached:
        JSC::throwException(global_object, scope,
            createDOMException(
                global_object, DOMExceptionCode::QuotaExceededError, "AbortSignal listener limit exceeded"_s));
        return false;
    case WebApiEventTargetData::AppendResult::OutOfMemory:
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }
    return false;
}

void JSColloAbortSignal::collectAbortSteps(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::JSValue reason,
    JSC::MarkedVector<JSColloAbortSignal*>& dispatch_targets)
{
    if (m_aborted)
        return;
    m_aborted = true;
    m_reason.set(vm, this, normalizedAbortReason(global_object, reason));
    // FIXME: this branch never runs. Only its own timer aborts a timeout signal, which has no controller and never
    // becomes a dependent, and that timer's callback clears the id first. Runtime::clearTimer would cancel only a
    // timer of the currently active request and does nothing outside a request.
    if (m_timeout_timer_id) {
        uint64_t timer_id = m_timeout_timer_id;
        m_timeout_timer_id = 0;
        Runtime::clearTimer(global_object, timer_id);
    }
    for (auto& source : m_source_signals) {
        if (auto* signal = source.signal.get())
            signal->removeDependentSignal(this);
    }
    m_source_signals.clear(this);

    // Each record leaves the list before its listener is removed, so the removal, which looks for that record on this
    // signal, finds nothing to change in the list being drained.
    while (!m_cleanup_records.isEmpty()) {
        auto cleanup = m_cleanup_records.takeFirst(this);
        removeWebApiEventTargetListener(cleanup.target.get(), cleanup.type, cleanup.callback.get(), cleanup.capture);
    }

    dispatch_targets.append(this);

    auto dependents = WTF::move(m_dependent_signals);
    if (dependents) {
        for (auto& dependent : *dependents) {
            if (auto* signal = dependent.get()) {
                signal->removeSourceSignal(this);
                signal->collectAbortSteps(vm, global_object, m_reason.get(), dispatch_targets);
            }
        }
    }
}

void JSColloAbortSignal::signalAbort(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::JSValue reason)
{
    // A source reaches its dependents only through weak edges, and the abort steps run script that can trigger a
    // collection, so the signals whose steps run are rooted here.
    JSC::MarkedVector<JSColloAbortSignal*> dispatch_targets;
    // DOM standard, signal abort: every dependent is marked aborted before any signal runs its abort steps.
    collectAbortSteps(vm, global_object, reason, dispatch_targets);
    if (dispatch_targets.isEmpty())
        return;

    auto scope = DECLARE_THROW_SCOPE(vm);
    for (auto* signal : dispatch_targets) {
        // runInternalAbortAlgorithms clears every exception except a termination, which ends the walk.
        signal->runInternalAbortAlgorithms(vm, global_object);
        RETURN_IF_EXCEPTION(scope, void());
        auto* event = createWebApiEvent(global_object, "abort"_s);
        WebApiEventTargetHandle target { signal, signal, &signal->m_event_target };
        dispatchWebApiEvent(global_object, scope, target, event);
        if (scope.exception()) {
            // An exception from one signal's abort steps must not keep the remaining dependents from running theirs;
            // only a termination ends the walk, and it stays pending.
            auto catch_scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
            if (!catch_scope.clearExceptionExceptTermination())
                return;
        }
    }
}

bool JSColloAbortSignal::addEventTargetCleanup(
    JSC::VM& vm, JSC::JSObject* target, WTF::String type, JSC::JSValue callback, bool capture)
{
    EventTargetCleanup cleanup;
    cleanup.target.setWithoutWriteBarrier(target);
    cleanup.type = WTF::move(type);
    cleanup.callback.setWithoutWriteBarrier(callback);
    cleanup.capture = capture;
    return m_cleanup_records.tryAppend(vm, this, WTF::move(cleanup));
}

static bool cleanupTargets(const JSC::WriteBarrier<JSC::Unknown>& cleanup_target, const JSC::JSObject* target)
{
    JSC::JSValue value = cleanup_target.get();
    return value && value.isObject() && value.getObject() == target;
}

void JSColloAbortSignal::removeEventTargetCleanup(
    JSC::JSObject* target, const WTF::String& type, JSC::JSValue callback, bool capture)
{
    auto matches = [&](const EventTargetCleanup& cleanup) {
        return cleanup.capture == capture && cleanup.type == type && cleanupTargets(cleanup.target, target)
            && JSC::JSValue::strictEqual(nullptr, cleanup.callback.get(), callback);
    };
    // Listeners are unique per (type, callback, capture) on a target, so at most one record matches.
    bool found = false;
    for (auto& cleanup : m_cleanup_records) {
        if (matches(cleanup)) {
            found = true;
            break;
        }
    }
    if (found)
        m_cleanup_records.removeIf(this, matches);
}

void JSColloAbortSignal::removeEventTargetCleanupsForTarget(JSC::JSObject* target)
{
    if (!target)
        return;
    m_cleanup_records.removeIf(
        this, [target](const EventTargetCleanup& cleanup) { return cleanupTargets(cleanup.target, target); });
}

bool JSColloAbortSignal::addInternalAbortAlgorithm(
    JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue callback)
{
    ASSERT(JSC::getCallData(callback).type != JSC::CallData::Type::None);
    for (auto& algorithm : m_abort_algorithms) {
        if (!algorithm.removed && JSC::JSValue::strictEqual(nullptr, algorithm.callback.get(), callback))
            return true;
    }

    InternalAbortAlgorithm algorithm;
    algorithm.callback.setWithoutWriteBarrier(callback);
    if (!m_abort_algorithms.tryAppend(vm, this, WTF::move(algorithm))) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }
    return true;
}

void JSColloAbortSignal::removeInternalAbortAlgorithm(JSC::JSValue callback)
{
    if (m_dispatching_internal_abort_algorithms) {
        for (auto& algorithm : m_abort_algorithms) {
            if (JSC::JSValue::strictEqual(nullptr, algorithm.callback.get(), callback))
                algorithm.removed = true;
        }
        return;
    }
    m_abort_algorithms.removeIf(this, [callback](const InternalAbortAlgorithm& algorithm) {
        return algorithm.removed || JSC::JSValue::strictEqual(nullptr, algorithm.callback.get(), callback);
    });
}

void JSColloAbortSignal::runInternalAbortAlgorithms(JSC::VM& vm, JSC::JSGlobalObject* global_object)
{
    if (m_abort_algorithms.isEmpty())
        return;
    m_dispatching_internal_abort_algorithms = true;
    auto cleanup = WTF::makeScopeExit([this] {
        m_dispatching_internal_abort_algorithms = false;
        m_abort_algorithms.clear(this);
    });

    // Only the algorithms present when the run starts are invoked; one added during the run is dropped with the list
    // afterwards. That matches the DOM standard, where adding an algorithm to an aborted signal does nothing. The loop
    // indexes the list on every iteration because a re-entrant append may move its storage. During the run entries
    // only join the end, since a removal only marks them, so indices below algorithm_count stay valid.
    const size_t algorithm_count = m_abort_algorithms.size();
    for (size_t index = 0; index < algorithm_count; index++) {
        auto& algorithm = m_abort_algorithms.at(index);
        if (algorithm.removed)
            continue;
        JSValue callback = algorithm.callback.get();
        auto* callback_object = callback.isObject() ? callback.getObject() : nullptr;
        if (!callback_object)
            continue;
        auto call_data = JSC::getCallData(callback_object);
        if (call_data.type == JSC::CallData::Type::None)
            continue;

        auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
        JSC::MarkedArgumentBuffer arguments;
        JSC::call(global_object, callback_object, call_data, this, arguments);
        if (scope.exception() && !scope.clearExceptionExceptTermination())
            return;
    }
}

// The marker never walks m_dependent_signals (abort.h), so the functions that change it take no cell lock; they run on
// the VM thread under the JSC API lock.
bool JSColloAbortSignal::addDependentSignal(JSC::VM& vm, JSColloAbortSignal* signal)
{
    // Dead weak entries are swept each time the length reaches a power of two of at least 64, so the list never
    // doubles without reclaiming them.
    if (m_dependent_signals) {
        unsigned dependent_count = m_dependent_signals->size();
        if (dependent_count >= 64 && !(dependent_count & (dependent_count - 1)))
            compactDependentSignals();
    }
    auto* dependents = ensureDependentSignals();
    if (!dependents)
        return false;
    return dependents->tryAppend(JSC::Weak<JSColloAbortSignal>(vm, signal));
}

bool JSColloAbortSignal::addSourceSignal(JSC::VM& vm, JSColloAbortSignal* signal)
{
    SourceSignal source;
    source.signal.setWithoutWriteBarrier(signal);
    return m_source_signals.tryAppend(vm, this, WTF::move(source));
}

bool JSColloAbortSignal::hasSourceSignal(const JSColloAbortSignal* signal) const
{
    for (auto& source : m_source_signals) {
        if (source.signal.get() == signal)
            return true;
    }
    return false;
}

void JSColloAbortSignal::removeSourceSignal(JSColloAbortSignal* signal)
{
    m_source_signals.removeIf(this, [signal](const SourceSignal& source) { return source.signal.get() == signal; });
}

JSColloAbortSignal::DependentVector* JSColloAbortSignal::ensureDependentSignals()
{
    if (!m_dependent_signals) {
        void* storage = nullptr;
        if (!WTF::tryFastMalloc(sizeof(DependentVector)).getValue(storage))
            return nullptr;
        m_dependent_signals.reset(new (NotNull, storage) DependentVector());
    }
    return m_dependent_signals.get();
}

void JSColloAbortSignal::removeDependentSignal(JSColloAbortSignal* signal)
{
    if (!m_dependent_signals)
        return;
    auto& dependents = *m_dependent_signals;
    unsigned write = 0;
    for (unsigned read = 0; read < dependents.size(); read++) {
        auto* dependent = dependents[read].get();
        if (!dependent || dependent == signal)
            continue;
        if (write != read)
            dependents[write] = WTF::move(dependents[read]);
        write++;
    }
    dependents.shrink(write);
}

void JSColloAbortSignal::compactDependentSignals()
{
    // No cell lock: the marker does not walk m_dependent_signals.
    if (!m_dependent_signals)
        return;
    auto& dependents = *m_dependent_signals;
    unsigned write = 0;
    for (unsigned read = 0; read < dependents.size(); read++) {
        if (!dependents[read].get())
            continue;
        if (write != read)
            dependents[write] = WTF::move(dependents[read]);
        write++;
    }
    dependents.shrink(write);
}

JSColloAbortSignal* webApiAbortSignalFromValue(JSC::JSValue value)
{
    return dynamicDowncast<JSColloAbortSignal>(value);
}

JSColloAbortSignal* createDependentAbortSignal(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<JSColloAbortSignal* const> inputs)
{
    auto& vm = global_object->vm();
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    for (auto* input : inputs) {
        // An input that is already aborted makes the result born aborted with that input's reason, so no abort event
        // fires and no listener can have been registered.
        if (input->aborted()) {
            return JSColloAbortSignal::create(
                vm, collo_global, collo_global->abortSignalStructure(), /* aborted */ true, input->reason());
        }
    }

    auto* result = JSColloAbortSignal::create(vm, collo_global, collo_global->abortSignalStructure());
    // Each link checks the sources linked so far, so the links one result takes are bounded to keep that check cheap.
    unsigned links = 0;
    bool limit_reached = false;
    auto link = [&](JSColloAbortSignal* source) -> bool {
        if (++links > WebApiAbortSignalAnySourcesMax) {
            limit_reached = true;
            return false;
        }
        if (result->hasSourceSignal(source))
            return true;
        // The weak dependent edge goes first. If the strong source edge then fails, the result is dropped and
        // becomes unreachable, and the weak edge clears itself once the result is collected, so no source points at
        // a reachable dependent that does not list it as a source.
        return source->addDependentSignal(vm, result) && result->addSourceSignal(vm, source);
    };
    bool linked = true;
    for (auto* input : inputs) {
        const auto& input_sources = input->sourceSignals();
        if (input_sources.isEmpty()) {
            linked = link(input);
        } else {
            for (size_t index = 0; linked && index < input_sources.size(); index++) {
                if (auto* actual_source = input_sources.at(index).signal.get())
                    linked = link(actual_source);
            }
        }
        if (!linked)
            break;
    }
    if (linked)
        return result;
    if (limit_reached) {
        JSC::throwException(global_object, scope,
            createDOMException(
                global_object, DOMExceptionCode::QuotaExceededError, "AbortSignal.any input limit exceeded"_s));
    } else {
        JSC::throwOutOfMemoryError(global_object, scope);
    }
    return nullptr;
}

void installWebApiAbort(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    constexpr unsigned enumerableAccessor = static_cast<unsigned>(JSC::PropertyAttribute::Accessor);
    constexpr unsigned enumerableFunction = static_cast<unsigned>(JSC::PropertyAttribute::None);

    auto* signal_prototype = JSC::constructEmptyObject(global_object);
    signal_prototype->setPrototype(vm, global_object, global_object->eventTargetPrototype(), true);
    putWebApiAccessor(
        global_object, signal_prototype, vm, "aborted"_s, abortSignalGetAborted, nullptr, enumerableAccessor);
    putWebApiAccessor(
        global_object, signal_prototype, vm, "reason"_s, abortSignalGetReason, nullptr, enumerableAccessor);
    putWebApiAccessor(global_object, signal_prototype, vm, "onabort"_s, abortSignalGetOnAbort, abortSignalSetOnAbort,
        enumerableAccessor);
    putWebApiFunction(
        global_object, signal_prototype, vm, "throwIfAborted"_s, 0, abortSignalThrowIfAborted, enumerableFunction);
    signal_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::makeString("AbortSignal"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* signal_constructor
        = JSC::JSFunction::create(vm, global_object, 0, "AbortSignal"_s, abortSignalConstructorCall,
            JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, abortSignalConstructorConstruct, nullptr);
    RELEASE_ASSERT(signal_constructor);
    signal_constructor->putDirect(vm, vm.propertyNames->prototype, signal_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    signal_prototype->putDirect(
        vm, vm.propertyNames->constructor, signal_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    putWebApiFunction(global_object, signal_constructor, vm, "abort"_s, 0, abortSignalStaticAbort,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    putWebApiFunction(global_object, signal_constructor, vm, "timeout"_s, 1, abortSignalStaticTimeout,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    putWebApiFunction(global_object, signal_constructor, vm, "any"_s, 1, abortSignalStaticAny,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    auto* controller_prototype = JSC::constructEmptyObject(global_object);
    putWebApiAccessor(
        global_object, controller_prototype, vm, "signal"_s, abortControllerGetSignal, nullptr, enumerableAccessor);
    putWebApiFunction(global_object, controller_prototype, vm, "abort"_s, 0, abortControllerAbort, enumerableFunction);
    controller_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::makeString("AbortController"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* controller_constructor
        = JSC::JSFunction::create(vm, global_object, 0, "AbortController"_s, abortControllerConstructorCall,
            JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, abortControllerConstructorConstruct, nullptr);
    RELEASE_ASSERT(controller_constructor);
    controller_constructor->putDirect(vm, vm.propertyNames->prototype, controller_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    controller_prototype->putDirect(vm, vm.propertyNames->constructor, controller_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    JSC::Identifier signal_identifier = JSC::Identifier::fromString(vm, "AbortSignal"_s);
    global_object->putDirect(
        vm, signal_identifier, signal_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    RELEASE_ASSERT(global_object->getDirect(vm, signal_identifier));
    JSC::Identifier controller_identifier = JSC::Identifier::fromString(vm, "AbortController"_s);
    global_object->putDirect(
        vm, controller_identifier, controller_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    RELEASE_ASSERT(global_object->getDirect(vm, controller_identifier));

    global_object->cacheAbortApi(controller_constructor, controller_prototype,
        JSColloAbortController::createStructure(vm, global_object, controller_prototype), signal_constructor,
        signal_prototype, JSColloAbortSignal::createStructure(vm, global_object, signal_prototype));
}

} // namespace Collo::HostFunctions
