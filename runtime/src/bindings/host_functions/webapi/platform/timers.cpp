// The timer globals on the VM thread. They validate arguments and pass the callback to the worker's Zig timer runtime
// through `host_functions/runtime/timers.cpp`; from then on the runtime owns the retained callback, its arguments and
// an immediate's receiver (`collo_runtime_set_timer` and `collo_runtime_set_immediate` in abi.h). Scheduling requires
// an active request turn and ties the timer to that request. Outside a turn, or for an id the runtime does not know,
// a clear call cancels nothing, and the runtime's status is discarded because HTML's clear steps are best effort.
// setTimeout and setInterval draw from one id space, so either clear function cancels either kind of timer.

#include "host_functions/webapi/platform/timers.h"

#include "host_functions/runtime/timers.h"
#include "host_functions/webapi/platform/timer_handle.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/JSCInlines.h>
#include <cmath>
#include <limits>
#include <optional>

namespace {

// The largest WebIDL `long`, the type HTML gives the timeout argument.
constexpr double maxTimerDelayMs = 2147483647.0;

// Truncates the delay toward zero. NaN and non-positive delays become 0, and a delay above maxTimerDelayMs saturates
// there, where WebIDL's `long` conversion would wrap a finite delay modulo 2^32 and turn an infinite one into 0. The
// conversion can run script.
uint32_t timerDelayMs(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value)
{
    double raw_delay = value.toNumber(global_object);
    RETURN_IF_EXCEPTION(scope, 0);
    if (!(raw_delay > 0))
        return 0;
    if (raw_delay > maxTimerDelayMs)
        return static_cast<uint32_t>(maxTimerDelayMs);
    return static_cast<uint32_t>(raw_delay);
}

// The timer id `value` names after a number conversion, which can run script, or nullopt for a value no timer can
// have: not positive, not finite, or beyond uint64_t.
// FIXME: the bound compares against double(UINT64_MAX), which rounds up to 2^64, so 2^64 itself passes and its cast to
// uint64_t is undefined behavior. immediateIdFromArgument has the same bound.
std::optional<uint64_t> timerIdFromValue(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value)
{
    double raw_timer_id = value.toNumber(global_object);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (!(raw_timer_id > 0) || !std::isfinite(raw_timer_id)
        || raw_timer_id > static_cast<double>(std::numeric_limits<uint64_t>::max()))
        return std::nullopt;
    return static_cast<uint64_t>(raw_timer_id);
}

JSC::EncodedJSValue setTimer(JSC::JSGlobalObject* global_object, JSC::CallFrame* call_frame, bool repeats)
{
    JSC::VM& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto owner_result = Collo::HostFunctions::Runtime::requireVmOwner(global_object, scope);
    if (!owner_result.ok)
        return owner_result.error;
    void* runtime_handle = Collo::HostFunctions::Runtime::hostRuntime(*owner_result.owner);
    if (!runtime_handle)
        return Collo::HostFunctions::throwRuntimeError(global_object, scope, "Timer runtime is unavailable."_s);

    JSC::JSValue callback_value = call_frame->argument(0);
    auto* callback_object = dynamicDowncast<JSC::JSObject>(callback_value);
    if (!callback_object)
        return JSC::throwVMTypeError(global_object, scope, "First argument must be callable."_s);

    JSC::CallData call_data = JSC::getCallData(callback_object);
    if (call_data.type == JSC::CallData::Type::None)
        return JSC::throwVMTypeError(global_object, scope, "First argument must be callable."_s);

    ColloExecCtx* exec_ctx = Collo::HostFunctions::Runtime::activeExecContext(*owner_result.owner);
    if (!exec_ctx)
        return JSC::throwVMTypeError(global_object, scope, "setTimeout requires an active request turn."_s);

    const uint32_t delay_ms = timerDelayMs(global_object, scope, call_frame->argument(1));
    RETURN_IF_EXCEPTION(scope, {});

    Collo::HostFunctions::Runtime::ActiveRequestRuntime runtime {
        owner_result.owner,
        runtime_handle,
        exec_ctx,
    };
    return Collo::HostFunctions::Runtime::scheduleTimer(global_object, scope, runtime, call_frame, delay_ms, repeats);
}

JSC::EncodedJSValue setImmediateCallback(JSC::JSGlobalObject* global_object, JSC::CallFrame* call_frame)
{
    JSC::VM& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto owner_result = Collo::HostFunctions::Runtime::requireVmOwner(global_object, scope);
    if (!owner_result.ok)
        return owner_result.error;
    void* runtime_handle = Collo::HostFunctions::Runtime::hostRuntime(*owner_result.owner);
    if (!runtime_handle)
        return Collo::HostFunctions::throwRuntimeError(global_object, scope, "Timer runtime is unavailable."_s);

    JSC::JSValue callback_value = call_frame->argument(0);
    auto* callback_object = dynamicDowncast<JSC::JSObject>(callback_value);
    if (!callback_object)
        return JSC::throwVMTypeError(global_object, scope, "First argument must be callable."_s);

    JSC::CallData call_data = JSC::getCallData(callback_object);
    if (call_data.type == JSC::CallData::Type::None)
        return JSC::throwVMTypeError(global_object, scope, "First argument must be callable."_s);

    ColloExecCtx* exec_ctx = Collo::HostFunctions::Runtime::activeExecContext(*owner_result.owner);
    if (!exec_ctx)
        return JSC::throwVMTypeError(global_object, scope, "setImmediate requires an active request turn."_s);

    auto* handle = Collo::HostFunctions::createImmediateHandle(global_object);
    Collo::HostFunctions::Runtime::ActiveRequestRuntime runtime {
        owner_result.owner,
        runtime_handle,
        exec_ctx,
    };
    return Collo::HostFunctions::Runtime::scheduleImmediate(global_object, scope, runtime, call_frame, handle);
}

// Accepts an Immediate handle or a number. Unlike clearTimeout, it converts no other value, so it never runs script.
std::optional<uint64_t> immediateIdFromArgument(JSC::JSValue value)
{
    if (auto id = Collo::HostFunctions::immediateIdFromValue(value))
        return id;
    if (value.isUndefinedOrNull())
        return std::nullopt;
    if (!value.isNumber())
        return std::nullopt;

    double raw_timer_id = value.asNumber();
    if (!(raw_timer_id > 0) || !std::isfinite(raw_timer_id)
        || raw_timer_id > static_cast<double>(std::numeric_limits<uint64_t>::max()))
        return std::nullopt;
    return static_cast<uint64_t>(raw_timer_id);
}

} // namespace

namespace Collo::HostFunctions {

JSC_DEFINE_HOST_FUNCTION(setTimeout, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    return setTimer(global_object, call_frame, false);
}

JSC_DEFINE_HOST_FUNCTION(setInterval, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    return setTimer(global_object, call_frame, true);
}

JSC_DEFINE_HOST_FUNCTION(setImmediate, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    return setImmediateCallback(global_object, call_frame);
}

JSC_DEFINE_HOST_FUNCTION(clearTimeout, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    JSC::VM& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto timer_id = timerIdFromValue(global_object, scope, call_frame->argument(0));
    RETURN_IF_EXCEPTION(scope, {});
    if (!timer_id)
        return JSC::JSValue::encode(JSC::jsUndefined());

    return Runtime::clearTimer(global_object, *timer_id);
}

JSC_DEFINE_HOST_FUNCTION(clearInterval, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    return clearTimeout(global_object, call_frame);
}

JSC_DEFINE_HOST_FUNCTION(clearImmediate, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto value = call_frame->argument(0);
    auto timer_id = immediateIdFromArgument(value);
    if (!timer_id)
        return JSC::JSValue::encode(JSC::jsUndefined());

    if (auto* handle = immediateHandleFromValue(value))
        handle->markDestroyed();
    return Runtime::clearImmediate(global_object, *timer_id);
}

} // namespace Collo::HostFunctions
