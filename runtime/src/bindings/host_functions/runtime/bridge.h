// The lookups a host function makes before it calls into the worker's Zig runtime, run on the VM thread: the ColloVm
// behind a global, the host runtime attached to it, the execution context of the current call, and promise deferreds
// for the runtime to settle. The host runtime pointer is borrowed: Zig sets and clears it on the VM thread and keeps it
// alive while a host function runs, so nothing stores it beyond its own call. A VM without a worker runtime, such as
// the zygote's, has no host runtime, and code outside both a turn and the boot context has no execution context.

#pragma once

#include "host_functions/support.h"

namespace Collo::HostFunctions::Runtime {

// Which absence requireActiveRequestRuntime reports when both the host runtime and the execution context are missing.
enum class RuntimeCheckOrder : uint8_t {
    RuntimeFirst,
    ActiveTurnFirst,
};

// Borrowed for the current host function call.
struct ActiveRequestRuntime {
    ColloVm* owner { nullptr };
    void* host_runtime { nullptr };
    ColloExecCtx* exec_ctx { nullptr };
};

struct ActiveRequestRuntimeResult {
    ActiveRequestRuntime value {};
    JSC::EncodedJSValue error {};
    bool ok { false };
};

struct VmOwnerResult {
    ColloVm* owner { nullptr };
    JSC::EncodedJSValue error {};
    bool ok { false };
};

struct DeferredPromise {
    JSC::JSValue promise { JSC::jsUndefined() };
    ColloPromiseDeferred* deferred { nullptr };
};

struct DeferredPromiseResult {
    DeferredPromise value {};
    JSC::EncodedJSValue error {};
    bool ok { false };
};

// Each `require` lookup that fails has thrown into the scope and returns the thrown value in `error`: an Error when
// the global is not a Collo global, an Error carrying `runtime_unavailable_message` when no host runtime is attached,
// and a TypeError carrying `active_turn_message` when there is no execution context.
ActiveRequestRuntimeResult requireActiveRequestRuntime(JSC::JSGlobalObject*, JSC::ThrowScope&,
    WTF::ASCIILiteral runtime_unavailable_message, WTF::ASCIILiteral active_turn_message,
    RuntimeCheckOrder = RuntimeCheckOrder::RuntimeFirst);

VmOwnerResult requireVmOwner(JSC::JSGlobalObject*, JSC::ThrowScope&);
// The attached host runtime, or null.
void* hostRuntime(ColloVm&);
// The current turn's execution context, else the worker's boot context, else null.
ColloExecCtx* activeExecContext(ColloVm&);
// Fills `out` and returns true when the global is a Collo global with both a host runtime and an execution context;
// throws nothing.
bool optionalActiveRequestRuntime(JSC::JSGlobalObject*, ActiveRequestRuntime& out);

// Creates a pending promise and the deferred that settles it. On success the caller owns `value.deferred` and either
// passes it to a `collo_runtime_*` call that takes it, or releases it with collo_promise_deferred_release. On failure
// nothing is owned and an exception is pending in the scope, a thrown Error carrying `failure_message` unless one was
// already pending.
DeferredPromiseResult createPromiseDeferred(
    JSC::JSGlobalObject*, JSC::ThrowScope&, ColloVm&, WTF::ASCIILiteral failure_message);

} // namespace Collo::HostFunctions::Runtime
