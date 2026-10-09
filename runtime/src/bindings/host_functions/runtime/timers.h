// Declares the hand-off of timers and immediates to the worker's Zig timer runtime, which timers.cpp defines. They run
// on the VM thread. The caller has checked that the callback is callable and supplies the execution context the timer
// belongs to. A schedule that fails throws an Error, or an OutOfMemoryError when the argument list cannot be copied.

#pragma once

#include "host_functions/runtime/bridge.h"

#include <cstddef>
#include <optional>

namespace Collo::HostFunctions::Runtime {

// Schedules the call frame's first argument with the arguments after the delay; returns the timer id as a number.
JSC::EncodedJSValue scheduleTimer(JSC::JSGlobalObject*, JSC::ThrowScope&, const ActiveRequestRuntime&, JSC::CallFrame*,
    uint32_t delay_ms, bool repeats);
// Schedules the call frame's first argument with the arguments after it. `this_value` must be a JSColloImmediate (a
// RELEASE_ASSERT ends the process otherwise); it becomes the callback's receiver and the return value, carrying the
// new id.
JSC::EncodedJSValue scheduleImmediate(
    JSC::JSGlobalObject*, JSC::ThrowScope&, const ActiveRequestRuntime&, JSC::CallFrame*, JSC::JSValue this_value);
// scheduleTimer for a callback and arguments that do not come from a call frame. The caller keeps `args` rooted for
// the call. Returns nullopt with the exception pending on failure.
std::optional<JSC::EncodedJSValue> scheduleTimerValue(JSC::JSGlobalObject*, JSC::ThrowScope&,
    const ActiveRequestRuntime&, JSC::JSValue callback_value, JSC::JSValue* args, size_t args_len, uint32_t delay_ms,
    bool repeats);
// Both return undefined. Outside an execution context they cancel nothing, and the runtime's status is discarded,
// because clearing a timer is best effort (webapi/platform/timers.cpp).
JSC::EncodedJSValue clearTimer(JSC::JSGlobalObject*, uint64_t timer_id);
JSC::EncodedJSValue clearImmediate(JSC::JSGlobalObject*, uint64_t immediate_id);

} // namespace Collo::HostFunctions::Runtime
