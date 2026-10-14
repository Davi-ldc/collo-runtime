// The timer globals on the VM thread. They validate arguments and pass the callback to the worker's Zig timer runtime
// through `host_functions/runtime/timers.cpp`; from then on the runtime owns the retained callback, its receiver and
// its arguments (`collo_runtime_set_timer` and `collo_runtime_set_immediate` in abi.h). Scheduling requires an active
// request turn and ties the timer to that request. Every schedule returns the numeric id the runtime assigned, and
// the three set functions draw ids from one counter, so no two callbacks share one. clearTimeout and clearInterval
// cancel either kind of timer, clearImmediate only an immediate. Outside a turn, or for an id the runtime does not
// know, a clear call cancels nothing, and the runtime's status is discarded because HTML's clear steps are best effort.

#include "host_functions/webapi/platform/timers.h"

#include "host_functions/runtime/timers.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/JSCInlines.h>
#include <optional>

namespace {

// HTML's timeout is a WebIDL `long`: ToInt32 wraps a finite delay modulo 2^32 and maps NaN and the infinities to 0,
// then HTML clamps a negative timeout to 0. The conversion can run script.
uint32_t timerDelayMs(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value)
{
    const int32_t delay = value.toInt32(global_object);
    RETURN_IF_EXCEPTION(scope, 0);
    return delay > 0 ? static_cast<uint32_t>(delay) : 0;
}

// The id a number names, or nullopt for a number no timer can have: not positive, NaN, or at least 2^64.
// double(UINT64_MAX) rounds up to 2^64, so the bound is the exact 0x1p64.
std::optional<uint64_t> timerIdFromNumber(double raw_timer_id)
{
    if (!(raw_timer_id > 0) || !(raw_timer_id < 0x1p64))
        return std::nullopt;
    return static_cast<uint64_t>(raw_timer_id);
}

// The timer id `value` names after a number conversion, which can run script, or nullopt for a value no timer can
// have.
std::optional<uint64_t> timerIdFromValue(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value)
{
    double raw_timer_id = value.toNumber(global_object);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    return timerIdFromNumber(raw_timer_id);
}

enum class TimerKind {
    Timeout,
    Interval,
    Immediate,
};

JSC::EncodedJSValue startTimer(JSC::JSGlobalObject* global_object, JSC::CallFrame* call_frame, TimerKind kind)
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
    if (!exec_ctx) {
        switch (kind) {
        case TimerKind::Timeout:
            return JSC::throwVMTypeError(global_object, scope, "setTimeout requires an active request turn."_s);
        case TimerKind::Interval:
            return JSC::throwVMTypeError(global_object, scope, "setInterval requires an active request turn."_s);
        case TimerKind::Immediate:
            return JSC::throwVMTypeError(global_object, scope, "setImmediate requires an active request turn."_s);
        }
    }

    Collo::HostFunctions::Runtime::ActiveRequestRuntime runtime {
        owner_result.owner,
        runtime_handle,
        exec_ctx,
    };
    if (kind == TimerKind::Immediate)
        return Collo::HostFunctions::Runtime::scheduleImmediate(global_object, scope, runtime, call_frame);

    const uint32_t delay_ms = timerDelayMs(global_object, scope, call_frame->argument(1));
    RETURN_IF_EXCEPTION(scope, {});
    return Collo::HostFunctions::Runtime::scheduleTimer(
        global_object, scope, runtime, call_frame, delay_ms, kind == TimerKind::Interval);
}

} // namespace

namespace Collo::HostFunctions {

JSC_DEFINE_HOST_FUNCTION(setTimeout, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    return startTimer(global_object, call_frame, TimerKind::Timeout);
}

JSC_DEFINE_HOST_FUNCTION(setInterval, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    return startTimer(global_object, call_frame, TimerKind::Interval);
}

JSC_DEFINE_HOST_FUNCTION(setImmediate, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    return startTimer(global_object, call_frame, TimerKind::Immediate);
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
    JSC::VM& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto immediate_id = timerIdFromValue(global_object, scope, call_frame->argument(0));
    RETURN_IF_EXCEPTION(scope, {});
    if (!immediate_id)
        return JSC::JSValue::encode(JSC::jsUndefined());

    return Runtime::clearImmediate(global_object, *immediate_id);
}

} // namespace Collo::HostFunctions
