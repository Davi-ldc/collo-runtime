// Retains a timer's or immediate's callback, receiver and arguments as value handles and passes them to
// collo_runtime_set_timer or collo_runtime_set_immediate, on the VM thread. A timer's receiver is the globalThis of the
// realm whose setTimeout or setInterval ran, an immediate's its Immediate object. The runtime consumes every handle it
// receives, also when it fails; a handle that cannot be made releases the ones made before it, so no handle outlives a
// failed schedule.

#include "host_functions/runtime/timers.h"

#include "host_functions/runtime/bridge.h"
#include "host_functions/webapi/platform/timer_handle.h"

#include <JavaScriptCore/JSCInlines.h>

#include <iterator>
#include <memory>
#include <new>

namespace Collo::HostFunctions::Runtime {

enum class ScheduleKind {
    Timer,
    Immediate,
};

WTF::ASCIILiteral scheduleMessage(
    ScheduleKind kind, WTF::ASCIILiteral timer_message, WTF::ASCIILiteral immediate_message)
{
    return kind == ScheduleKind::Timer ? timer_message : immediate_message;
}

std::optional<JSC::EncodedJSValue> scheduleCallbackValue(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    const ActiveRequestRuntime& runtime, JSC::JSValue callback_value, JSC::JSValue* args_values, size_t args_len,
    uint32_t delay_ms, bool repeats, ScheduleKind kind, JSC::JSValue this_value = JSC::JSValue())
{
    ColloValue* callback_handle = nullptr;
    if (Collo::makeValueHandle(runtime.owner, callback_value, &callback_handle) != COLLO_STATUS_OK
        || !callback_handle) {
        Collo::HostFunctions::throwRuntimeError(global_object, scope,
            scheduleMessage(kind, "Failed to retain timer callback."_s, "Failed to retain immediate callback."_s));
        return std::nullopt;
    }

    ColloValue* stack_args[8];
    std::unique_ptr<ColloValue*[]> heap_args;
    ColloValue** args = nullptr;
    if (args_len != 0) {
        if (args_len <= std::size(stack_args)) {
            args = stack_args;
        } else {
            heap_args.reset(new (std::nothrow) ColloValue*[args_len]);
            if (!heap_args) {
                Collo::releaseValueHandle(callback_handle);
                JSC::throwOutOfMemoryError(global_object, scope);
                return std::nullopt;
            }
            args = heap_args.get();
        }
        for (size_t index = 0; index < args_len; ++index)
            args[index] = nullptr;
    }

    size_t retained_args = 0;
    for (; retained_args < args_len; ++retained_args) {
        if (Collo::makeValueHandle(runtime.owner, args_values[retained_args], &args[retained_args]) != COLLO_STATUS_OK
            || !args[retained_args]) {
            for (size_t release_index = 0; release_index < retained_args; ++release_index)
                Collo::releaseValueHandle(args[release_index]);
            Collo::releaseValueHandle(callback_handle);
            Collo::HostFunctions::throwRuntimeError(global_object, scope,
                scheduleMessage(
                    kind, "Failed to retain timer arguments."_s, "Failed to retain immediate arguments."_s));
            return std::nullopt;
        }
    }

    ColloValue* this_handle = nullptr;
    JSC::JSValue receiver = kind == ScheduleKind::Timer ? global_object->globalThis() : this_value;
    if (Collo::makeValueHandle(runtime.owner, receiver, &this_handle) != COLLO_STATUS_OK || !this_handle) {
        for (size_t release_index = 0; release_index < retained_args; ++release_index)
            Collo::releaseValueHandle(args[release_index]);
        Collo::releaseValueHandle(callback_handle);
        Collo::HostFunctions::throwRuntimeError(global_object, scope,
            scheduleMessage(kind, "Failed to retain timer receiver."_s, "Failed to retain immediate receiver."_s));
        return std::nullopt;
    }

    uint64_t callback_id = 0;
    // From here the runtime owns every handle, including on a failed status.
    ColloStatus status = kind == ScheduleKind::Timer
        ? collo_runtime_set_timer(runtime.host_runtime, runtime.exec_ctx->request_id, callback_handle, this_handle,
              args, args_len, delay_ms, repeats ? 1 : 0, &callback_id)
        : collo_runtime_set_immediate(runtime.host_runtime, runtime.exec_ctx->request_id, callback_handle, this_handle,
              args, args_len, &callback_id);
    if (status != COLLO_STATUS_OK) {
        Collo::HostFunctions::throwRuntimeError(global_object, scope,
            scheduleMessage(kind, "Failed to schedule timer callback."_s, "Failed to schedule immediate callback."_s));
        return std::nullopt;
    }

    if (kind == ScheduleKind::Immediate) {
        auto* handle = immediateHandleFromValue(this_value);
        RELEASE_ASSERT(handle);
        handle->setId(callback_id);
        return JSC::JSValue::encode(handle);
    }

    return JSC::JSValue::encode(JSC::jsNumber(static_cast<double>(callback_id)));
}

JSC::EncodedJSValue scheduleCallback(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    const ActiveRequestRuntime& runtime, JSC::CallFrame* call_frame, unsigned first_argument_index, uint32_t delay_ms,
    bool repeats, ScheduleKind kind)
{
    JSC::JSValue callback_value = call_frame->argument(0);
    const size_t args_len
        = call_frame->argumentCount() > first_argument_index ? call_frame->argumentCount() - first_argument_index : 0;
    // The collector does not scan a heap copy, but every value in it stays rooted by the call frame it was copied
    // from until scheduleCallbackValue turns it into a handle.
    JSC::JSValue stack_args[8];
    std::unique_ptr<JSC::JSValue[]> heap_args;
    JSC::JSValue* args = nullptr;
    if (args_len != 0) {
        if (args_len <= std::size(stack_args)) {
            args = stack_args;
        } else {
            heap_args.reset(new (std::nothrow) JSC::JSValue[args_len]);
            if (!heap_args)
                return JSC::JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
            args = heap_args.get();
        }
        for (size_t index = 0; index < args_len; ++index)
            args[index] = call_frame->argument(static_cast<unsigned>(index + first_argument_index));
    }

    auto result
        = scheduleCallbackValue(global_object, scope, runtime, callback_value, args, args_len, delay_ms, repeats, kind);
    RETURN_IF_EXCEPTION(scope, {});
    if (!result)
        return {};
    return *result;
}

std::optional<JSC::EncodedJSValue> scheduleTimerValue(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    const ActiveRequestRuntime& runtime, JSC::JSValue callback_value, JSC::JSValue* args_values, size_t args_len,
    uint32_t delay_ms, bool repeats)
{
    return scheduleCallbackValue(
        global_object, scope, runtime, callback_value, args_values, args_len, delay_ms, repeats, ScheduleKind::Timer);
}

JSC::EncodedJSValue scheduleTimer(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    const ActiveRequestRuntime& runtime, JSC::CallFrame* call_frame, uint32_t delay_ms, bool repeats)
{
    return scheduleCallback(global_object, scope, runtime, call_frame, 2, delay_ms, repeats, ScheduleKind::Timer);
}

JSC::EncodedJSValue scheduleImmediate(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    const ActiveRequestRuntime& runtime, JSC::CallFrame* call_frame, JSC::JSValue this_value)
{
    JSC::JSValue callback_value = call_frame->argument(0);
    const unsigned first_argument_index = 1;
    const size_t args_len
        = call_frame->argumentCount() > first_argument_index ? call_frame->argumentCount() - first_argument_index : 0;
    // Rooted by the call frame, as in scheduleCallback.
    JSC::JSValue stack_args[8];
    std::unique_ptr<JSC::JSValue[]> heap_args;
    JSC::JSValue* args = nullptr;
    if (args_len != 0) {
        if (args_len <= std::size(stack_args)) {
            args = stack_args;
        } else {
            heap_args.reset(new (std::nothrow) JSC::JSValue[args_len]);
            if (!heap_args)
                return JSC::JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
            args = heap_args.get();
        }
        for (size_t index = 0; index < args_len; ++index)
            args[index] = call_frame->argument(static_cast<unsigned>(index + first_argument_index));
    }

    auto result = scheduleCallbackValue(
        global_object, scope, runtime, callback_value, args, args_len, 0, false, ScheduleKind::Immediate, this_value);
    RETURN_IF_EXCEPTION(scope, {});
    if (!result)
        return {};
    return *result;
}

JSC::EncodedJSValue clearTimer(JSC::JSGlobalObject* global_object, uint64_t timer_id)
{
    ActiveRequestRuntime runtime;
    if (!optionalActiveRequestRuntime(global_object, runtime))
        return JSC::JSValue::encode(JSC::jsUndefined());
    (void)collo_runtime_clear_timeout(runtime.host_runtime, runtime.exec_ctx->request_id, timer_id);
    return JSC::JSValue::encode(JSC::jsUndefined());
}

JSC::EncodedJSValue clearImmediate(JSC::JSGlobalObject* global_object, uint64_t immediate_id)
{
    ActiveRequestRuntime runtime;
    if (!optionalActiveRequestRuntime(global_object, runtime))
        return JSC::JSValue::encode(JSC::jsUndefined());
    (void)collo_runtime_clear_immediate(runtime.host_runtime, runtime.exec_ctx->request_id, immediate_id);
    return JSC::JSValue::encode(JSC::jsUndefined());
}

} // namespace Collo::HostFunctions::Runtime
