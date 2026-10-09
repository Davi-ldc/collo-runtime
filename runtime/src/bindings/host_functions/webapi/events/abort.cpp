// AbortController and AbortSignal: their host functions, the AbortController cell, and JSColloAbortSignal's
// implementation, including the DOM standard's signal abort. VM thread only. The ownership and locking rules of the
// signal's lists are in abort.h.

#include "host_functions/webapi/events/abort.h"

#include "host_functions/runtime/bridge.h"
#include "host_functions/runtime/timers.h"
#include "host_functions/webapi/dom/dom_exception.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/IteratorOperations.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <JavaScriptCore/WeakInlines.h>
#include <wtf/HashSet.h>
#include <wtf/Locker.h>
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

        // Strong: past eight entries the buffer is on the heap, out of the conservative stack scan's reach, and the
        // iteration runs script that can trigger a collection.
        WTF::Vector<Strong<Unknown>, 8> sources;
        bool failed = false;
        JSC::forEachInIterable(global_object, iterable_value, [&](JSC::VM&, JSC::JSGlobalObject*, JSValue value) {
            if (failed)
                return;
            auto* source = requireAbortSignal(global_object, scope, value);
            if (!source) {
                failed = true;
                return;
            }
            sources.append(Strong<Unknown>(vm, source));
        });
        RETURN_IF_EXCEPTION(scope, {});

        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        JSValue first_abort_reason = JSC::jsUndefined();
        bool first_aborted = false;
        for (auto& source_handle : sources) {
            auto* source = uncheckedDowncast<JSColloAbortSignal>(source_handle.get().asCell());
            if (source->aborted()) {
                first_abort_reason = source->reason();
                first_aborted = true;
                break;
            }
        }

        if (first_aborted) {
            // DOM standard, create a dependent abort signal: an input that is already aborted makes the result born
            // aborted with that input's reason, so no abort event fires and no listener can have been registered.
            auto* result = JSColloAbortSignal::create(
                vm, collo_global, collo_global->abortSignalStructure(), /* aborted */ true, first_abort_reason);
            return JSValue::encode(result);
        }

        auto* result = JSColloAbortSignal::create(vm, collo_global, collo_global->abortSignalStructure());
        // DOM standard, create a dependent abort signal: a dependent input contributes its sources rather than
        // itself, and the source and dependent lists are ordered sets, so each actual source is linked once even when
        // the iterable repeats a signal or two inputs share a source. A signal counts as dependent here when it has
        // sources.
        WTF::HashSet<JSColloAbortSignal*> linked_sources;
        auto linkSource = [&](JSColloAbortSignal* actual_source) -> bool {
            if (!linked_sources.add(actual_source).isNewEntry)
                return true;
            // The weak dependent edge goes first. If the strong source edge then fails, the result is dropped with an
            // OutOfMemoryError and becomes unreachable, and the weak edge clears itself once the result is collected,
            // so no source points at a reachable dependent that does not list it as a source.
            if (!actual_source->addDependentSignal(vm, result))
                return false;
            return result->addSourceSignal(vm, actual_source);
        };
        bool linked = true;
        for (auto& source_handle : sources) {
            if (!linked)
                break;
            auto* source = uncheckedDowncast<JSColloAbortSignal>(source_handle.get().asCell());
            ASSERT(!source->aborted());
            auto& source_signals = source->sourceSignals();
            if (source_signals.isEmpty()) {
                linked = linkSource(source);
                continue;
            }
            for (auto& source_signal : source_signals) {
                if (auto* actual_source = source_signal.get()) {
                    if (!linkSource(actual_source)) {
                        linked = false;
                        break;
                    }
                }
            }
        }
        if (!linked)
            return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
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
    // The cell lock keeps these vector buffers stable while the concurrent
    // marker walks them; mutators take the same lock around buffer-moving
    // operations.
    WTF::Locker locker { this_object->cellLock() };
    this_object->m_event_target.visitChildren(visitor);
    if (this_object->m_cleanup_records) {
        for (auto& cleanup : *this_object->m_cleanup_records) {
            appendWebApiUnknown(visitor, cleanup.target);
            appendWebApiUnknown(visitor, cleanup.callback);
        }
    }
    if (this_object->m_abort_algorithms) {
        for (auto& algorithm : *this_object->m_abort_algorithms)
            appendWebApiUnknown(visitor, algorithm.callback);
    }
    if (this_object->m_source_signals) {
        for (auto& source : *this_object->m_source_signals)
            visitor.append(source);
    }
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
    auto& listeners = data.listeners();
    for (unsigned index = 0; index < listeners.size(); index++) {
        auto& listener = listeners[index];
        if (listener.removed || !listener.attribute_handler || listener.type != "abort"_s)
            continue;
        if (!JSC::JSValue::strictEqual(nullptr, listener.callback.get(), callback))
            continue;
        data.markRemoved(index);
        break;
    }
    WTF::Locker locker { signal->cellLock() };
    data.compactRemovedIfIdle();
}

bool JSColloAbortSignal::setOnAbort(
    JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value)
{
    auto previous = m_onabort.get();
    auto call_data = JSC::getCallData(value);
    JSValue normalized = call_data.type == JSC::CallData::Type::None ? JSC::jsNull() : value;
    if (!normalized.isNull()) {
        WebApiEventListenerRecord record;
        record.type = "abort"_s;
        record.callback.set(vm, this, normalized);
        record.attribute_handler = true;
        WTF::Locker locker { cellLock() };
        record.order = eventTargetData().allocateListenerOrder();
        if (!eventTargetData().listeners().tryAppend(WTF::move(record))) {
            throwException(global_object, scope, createOutOfMemoryError(global_object));
            return false;
        }
        eventTargetData().noteListenerAppended();
    }
    if (!previous.isNull())
        removeAbortAttributeHandler(this, previous);
    m_onabort.set(vm, this, normalized);
    return true;
}

void JSColloAbortSignal::collectAbortSteps(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::JSValue reason,
    WTF::Vector<JSC::Strong<JSC::Unknown>, 8>& dispatch_targets)
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
    // The lists the marker walks are moved out under the cell lock, so the marker never walks a vector being freed.
    // m_dependent_signals is not walked and moves without it.
    std::unique_ptr<SourceSignalVector> sources;
    std::unique_ptr<CleanupVector> cleanup_records;
    {
        WTF::Locker locker { cellLock() };
        sources = WTF::move(m_source_signals);
        cleanup_records = WTF::move(m_cleanup_records);
    }
    if (sources) {
        for (auto& source : *sources) {
            if (auto* signal = source.get())
                signal->removeDependentSignal(this);
        }
    }

    if (cleanup_records) {
        for (auto& cleanup : *cleanup_records)
            removeWebApiEventTargetListener(
                cleanup.target.get(), cleanup.type, cleanup.callback.get(), cleanup.capture);
    }

    dispatch_targets.append(JSC::Strong<JSC::Unknown>(vm, this));

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
    // Strong, because a source reaches its dependents only through weak edges, and the abort steps run script that
    // can trigger a collection.
    WTF::Vector<JSC::Strong<JSC::Unknown>, 8> dispatch_targets;
    // DOM standard, signal abort: every dependent is marked aborted before any signal runs its abort steps.
    collectAbortSteps(vm, global_object, reason, dispatch_targets);
    if (dispatch_targets.isEmpty())
        return;

    auto scope = DECLARE_THROW_SCOPE(vm);
    for (auto& target_value : dispatch_targets) {
        auto* signal = dynamicDowncast<JSColloAbortSignal>(target_value.get());
        if (!signal)
            continue;
        signal->runInternalAbortAlgorithms(vm, global_object);
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
    cleanup.target.set(vm, this, target);
    cleanup.type = WTF::move(type);
    cleanup.callback.set(vm, this, callback);
    cleanup.capture = capture;
    // The marker walks m_cleanup_records, so a move of its buffer happens under the cell lock.
    WTF::Locker locker { cellLock() };
    auto* records = ensureCleanupRecords();
    if (!records)
        return false;
    return records->tryAppend(WTF::move(cleanup));
}

void JSColloAbortSignal::removeEventTargetCleanup(
    JSC::JSObject* target, const WTF::String& type, JSC::JSValue callback, bool capture)
{
    if (!m_cleanup_records)
        return;
    auto& records = *m_cleanup_records;
    for (unsigned index = 0; index < records.size(); index++) {
        auto& cleanup = records[index];
        if (cleanup.capture != capture || cleanup.type != type)
            continue;
        JSC::JSValue cleanup_target = cleanup.target.get();
        if (!cleanup_target || !cleanup_target.isObject() || cleanup_target.getObject() != target)
            continue;
        if (!JSC::JSValue::strictEqual(nullptr, cleanup.callback.get(), callback))
            continue;
        WTF::Locker locker { cellLock() };
        records.removeAt(index);
        return;
    }
}

void JSColloAbortSignal::removeEventTargetCleanupsForTarget(JSC::JSObject* target)
{
    if (!target || !m_cleanup_records)
        return;

    WTF::Locker locker { cellLock() };
    auto& records = *m_cleanup_records;
    unsigned write = 0;
    for (unsigned read = 0; read < records.size(); read++) {
        auto& cleanup = records[read];
        JSC::JSValue cleanup_target = cleanup.target.get();
        const bool remove = cleanup_target && cleanup_target.isObject() && cleanup_target.getObject() == target;
        if (remove)
            continue;
        if (write != read)
            records[write] = WTF::move(cleanup);
        write++;
    }
    records.shrink(write);
}

bool JSColloAbortSignal::addInternalAbortAlgorithm(
    JSC::VM& vm, JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue callback)
{
    ASSERT(JSC::getCallData(callback).type != JSC::CallData::Type::None);
    if (m_abort_algorithms) {
        for (auto& algorithm : *m_abort_algorithms) {
            if (algorithm.removed)
                continue;
            if (JSC::JSValue::strictEqual(nullptr, algorithm.callback.get(), callback))
                return true;
        }
    }

    InternalAbortAlgorithm algorithm;
    algorithm.callback.set(vm, this, callback);
    bool appended = false;
    {
        WTF::Locker locker { cellLock() };
        if (auto* algorithms = ensureAbortAlgorithms())
            appended = algorithms->tryAppend(WTF::move(algorithm));
    }
    if (!appended) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }
    return true;
}

void JSColloAbortSignal::removeInternalAbortAlgorithm(JSC::JSValue callback)
{
    if (!m_abort_algorithms)
        return;
    auto& algorithms = *m_abort_algorithms;
    if (m_dispatching_internal_abort_algorithms) {
        for (auto& algorithm : algorithms) {
            if (JSC::JSValue::strictEqual(nullptr, algorithm.callback.get(), callback))
                algorithm.removed = true;
        }
        return;
    }

    WTF::Locker locker { cellLock() };
    unsigned write = 0;
    for (unsigned read = 0; read < algorithms.size(); read++) {
        auto& algorithm = algorithms[read];
        if (algorithm.removed || JSC::JSValue::strictEqual(nullptr, algorithm.callback.get(), callback))
            continue;
        if (write != read)
            algorithms[write] = WTF::move(algorithm);
        write++;
    }
    algorithms.shrink(write);
}

void JSColloAbortSignal::runInternalAbortAlgorithms(JSC::VM& vm, JSC::JSGlobalObject* global_object)
{
    if (!m_abort_algorithms)
        return;
    m_dispatching_internal_abort_algorithms = true;
    auto cleanup = WTF::makeScopeExit([this] {
        m_dispatching_internal_abort_algorithms = false;
        // Freeing the buffer must not race the concurrent marker.
        WTF::Locker locker { cellLock() };
        m_abort_algorithms = nullptr;
    });

    // Only the algorithms present when the run starts are invoked; one added during the run is dropped with the list
    // afterwards. That matches the DOM standard, where adding an algorithm to an aborted signal does nothing. The loop
    // indexes the live buffer on every iteration because a re-entrant append may reallocate it. The buffer only grows
    // during the run, so indices below algorithm_count stay valid, and m_abort_algorithms stays non-null until the
    // scope exit runs after the loop.
    const unsigned algorithm_count = m_abort_algorithms->size();
    for (unsigned index = 0; index < algorithm_count; index++) {
        auto& algorithm = (*m_abort_algorithms)[index];
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
    JSC::WriteBarrier<JSColloAbortSignal> barrier;
    barrier.set(vm, this, signal);
    // The marker walks m_source_signals, so a move of its buffer happens under the cell lock.
    WTF::Locker locker { cellLock() };
    auto* sources = ensureSourceSignals();
    if (!sources)
        return false;
    return sources->tryAppend(WTF::move(barrier));
}

void JSColloAbortSignal::removeSourceSignal(JSColloAbortSignal* signal)
{
    if (!m_source_signals)
        return;
    WTF::Locker locker { cellLock() };
    auto& sources = *m_source_signals;
    unsigned write = 0;
    for (unsigned read = 0; read < sources.size(); read++) {
        if (sources[read].get() == signal)
            continue;
        if (write != read)
            sources[write] = WTF::move(sources[read]);
        write++;
    }
    sources.shrink(write);
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
