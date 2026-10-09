// collo_invoke: calls a JavaScript function inside a turn the caller has already entered, plus the benchmark marker
// that records when a handler's first statement runs. Runs on the VM thread; abi.h owns the call's contract.
//
// The marker is a global function, __colloBenchHandlerEntered, that exists only for the duration of one
// instrumented call and is never installed over a property the application owns. The pointer it writes through is
// borrowed from the caller and valid only during that call.

#include "jsc/runtime/state.h"
#include <JavaScriptCore/DeletePropertySlot.h>
#include <time.h>

namespace {

struct BenchTarget {
    JSC::JSGlobalObject* global;
    uint64_t* started_ns;
    bool marker_installed;
};

// The innermost collo_invoke on this thread that set up a marker scope, or null.
thread_local BenchTarget* active_bench_target = nullptr;

// Records CLOCK_MONOTONIC into the active target's output when that target belongs to the calling global, then
// forgets the output so a second call records nothing.
JSC_DEFINE_HOST_FUNCTION(benchHandlerEntered, (JSC::JSGlobalObject * global, JSC::CallFrame*))
{
    auto* target = active_bench_target;
    if (!target || target->global != global || !target->started_ns)
        return JSC::JSValue::encode(JSC::jsUndefined());
    auto* out = target->started_ns;
    target->started_ns = nullptr;
    struct timespec now;
    if (!clock_gettime(CLOCK_MONOTONIC, &now))
        *out = static_cast<uint64_t>(now.tv_sec) * 1000000000ULL + now.tv_nsec;
    return JSC::JSValue::encode(JSC::jsUndefined());
}

// Makes one collo_invoke the marker's target for its duration and restores the enclosing target afterwards. A nested
// call without an output masks the enclosing target, so the marker records nothing until that call returns. A nested
// call on the same global reuses the marker the enclosing call installed.
class BenchInvocationScope {
public:
    BenchInvocationScope(JSC::JSGlobalObject* global, uint64_t* out)
        : m_previous(active_bench_target)
        , m_target { global, out, m_previous && m_previous->global == global && m_previous->marker_installed }
    {
        active_bench_target = &m_target;
    }

    BenchInvocationScope(const BenchInvocationScope&) = delete;
    BenchInvocationScope& operator=(const BenchInvocationScope&) = delete;

    // Returns false when an application property already has the marker's name.
    bool install()
    {
        if (!m_target.started_ns || m_target.marker_installed)
            return true;
        auto& vm = m_target.global->vm();
        m_name = JSC::Identifier::fromString(vm, "__colloBenchHandlerEntered"_s);
        // An application property, a global var included, is never overwritten.
        if (m_target.global->hasOwnProperty(m_target.global, m_name))
            return false;
        auto* marker = JSC::JSFunction::create(vm, m_target.global, 0, "__colloBenchHandlerEntered"_s,
            benchHandlerEntered, JSC::ImplementationVisibility::Public);
        m_owns_property
            = m_target.global->putDirect(vm, m_name, marker, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
        m_target.marker_installed = m_owns_property;
        return m_owns_property;
    }

    ~BenchInvocationScope()
    {
        active_bench_target = m_previous;
        if (!m_owns_property)
            return;
        auto& vm = m_target.global->vm();
        // A direct delete runs no JS, which matters while an exception is unwinding. IgnoreConfigurable removes the
        // marker even from a global the handler froze.
        JSC::VM::DeletePropertyModeScope mode(vm, JSC::VM::DeletePropertyMode::IgnoreConfigurable);
        JSC::DeletePropertySlot slot;
        bool removed = JSC::JSObject::deleteProperty(m_target.global, m_target.global, m_name, slot);
        RELEASE_ASSERT(removed);
    }

private:
    BenchTarget* m_previous;
    BenchTarget m_target;
    JSC::Identifier m_name;
    bool m_owns_property { false };
};

} // namespace

extern "C" ColloStatus collo_invoke(ColloVm* vm, const ColloExecCtx* expected_ctx, const ColloValue* callable,
    const ColloValue* this_value, const ColloValue* const* argv, size_t argc, ColloValue** out_result,
    ColloValue** out_exception, uint64_t* out_call_started_ns)
{
    if (out_call_started_ns)
        *out_call_started_ns = 0;
    if (out_result)
        *out_result = nullptr;
    Collo::clearOutException(out_exception);

    if (!vm || !vm->isReady() || !expected_ctx || !callable || !out_result || (argc && !argv))
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    if (!vm->entered_count || vm->current_exec_ctx != expected_ctx)
        return COLLO_STATUS_INVALID_ARGUMENT;
    if (!Collo::valueBelongsToVm(vm, callable))
        return COLLO_STATUS_INVALID_ARGUMENT;
    if (this_value && !Collo::valueBelongsToVm(vm, this_value))
        return COLLO_STATUS_INVALID_ARGUMENT;

    // The callee's realm: where its errors are created and the marker is installed.
    JSC::JSValue callable_value = Collo::toJSValue(callable);
    auto* global_object = Collo::globalObjectForValue(vm, callable_value);
    auto* callable_object = dynamicDowncast<JSC::JSObject>(callable_value);
    if (!callable_object)
        return Collo::statusOr(
            Collo::setJsException(
                vm, JSC::createTypeError(global_object, "collo_invoke expects a callable value."_s), out_exception),
            COLLO_STATUS_JS_EXCEPTION);

    JSC::CallData call_data = JSC::getCallData(callable_object);
    if (call_data.type == JSC::CallData::Type::None)
        return Collo::statusOr(
            Collo::setJsException(vm, JSC::createTypeError(global_object, "Value is not callable."_s), out_exception),
            COLLO_STATUS_JS_EXCEPTION);

    JSC::MarkedArgumentBuffer arguments;
    for (size_t index = 0; index < argc; ++index) {
        const ColloValue* argument = argv[index];
        if (!Collo::valueBelongsToVm(vm, argument))
            return COLLO_STATUS_INVALID_ARGUMENT;
        arguments.append(Collo::toJSValue(argument));
    }

    if (arguments.hasOverflowed())
        return COLLO_STATUS_OUT_OF_MEMORY;

    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(*vm->vm);
    JSC::JSValue receiver = Collo::borrowedThisValue(this_value);
    std::optional<BenchInvocationScope> marker;
    if (out_call_started_ns || active_bench_target) {
        marker.emplace(global_object, out_call_started_ns);
        bool installed = marker->install();
        if (scope.exception())
            return Collo::caughtExceptionStatus(vm, scope, out_exception);
        if (!installed)
            return COLLO_STATUS_INVALID_ARGUMENT;
    }
    JSC::JSValue result = JSC::call(global_object, callable_object, call_data, receiver, arguments);
    marker.reset();
    if (scope.exception())
        return Collo::caughtExceptionStatus(vm, scope, out_exception);

    return Collo::makeValueHandle(vm, result, out_result);
}
