// The runtime lookups bridge.h declares, run on the VM thread.

#include "host_functions/runtime/bridge.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/JSCInlines.h>

namespace Collo::HostFunctions::Runtime {
namespace {

    ActiveRequestRuntimeResult fail(JSC::EncodedJSValue error) { return { {}, error, false }; }

    bool loadGlobalOwner(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, ColloVm*& out_owner, JSC::EncodedJSValue& out_error)
    {
        auto* collo_global = dynamicDowncast<Collo::GlobalObject>(global_object);
        if (!collo_global) {
            out_error = Collo::HostFunctions::throwRuntimeError(
                global_object, scope, "Collo global object is unavailable."_s);
            return false;
        }
        out_owner = &collo_global->owner();
        return true;
    }

    bool loadRuntime(ColloVm& owner, void*& out_runtime)
    {
        out_runtime = hostRuntime(owner);
        return out_runtime != nullptr;
    }

    bool loadActiveTurn(ColloVm& owner, ColloExecCtx*& out_exec_ctx)
    {
        out_exec_ctx = activeExecContext(owner);
        return out_exec_ctx != nullptr;
    }

} // namespace

VmOwnerResult requireVmOwner(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
{
    ColloVm* owner = nullptr;
    JSC::EncodedJSValue error {};
    if (!loadGlobalOwner(global_object, scope, owner, error))
        return { nullptr, error, false };
    return { owner, {}, true };
}

void* hostRuntime(ColloVm& owner) { return owner.host_runtime.load(std::memory_order_acquire); }

ColloExecCtx* activeExecContext(ColloVm& owner)
{
    if (owner.current_exec_ctx)
        return owner.current_exec_ctx;
    // Turnless JS, meaning module evaluation and its microtask drains, gets the worker's boot context when one is
    // installed; `boot_exec_ctx` in jsc/runtime/state.h describes it. Code that needs the turn itself, such as the turn
    // checks in invoke.cpp and vm.cpp and the turnless precondition of awaitModulePromiseSync, reads current_exec_ctx
    // directly instead of calling this.
    if (owner.boot_exec_ctx_installed)
        return &owner.boot_exec_ctx;
    return nullptr;
}

ActiveRequestRuntimeResult requireActiveRequestRuntime(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    WTF::ASCIILiteral runtime_unavailable_message, WTF::ASCIILiteral active_turn_message, RuntimeCheckOrder order)
{
    ColloVm* owner = nullptr;
    JSC::EncodedJSValue error {};
    if (!loadGlobalOwner(global_object, scope, owner, error))
        return fail(error);

    void* host_runtime = nullptr;
    ColloExecCtx* exec_ctx = nullptr;
    const auto require_runtime = [&]() -> bool {
        if (loadRuntime(*owner, host_runtime))
            return true;
        error = Collo::HostFunctions::throwRuntimeError(global_object, scope, runtime_unavailable_message);
        return false;
    };
    const auto require_active_turn = [&]() -> bool {
        if (loadActiveTurn(*owner, exec_ctx))
            return true;
        error = JSC::throwVMTypeError(global_object, scope, active_turn_message);
        return false;
    };

    if (order == RuntimeCheckOrder::RuntimeFirst) {
        if (!require_runtime() || !require_active_turn())
            return fail(error);
    } else {
        if (!require_active_turn() || !require_runtime())
            return fail(error);
    }

    return { { owner, host_runtime, exec_ctx }, {}, true };
}

bool optionalActiveRequestRuntime(JSC::JSGlobalObject* global_object, ActiveRequestRuntime& out)
{
    auto* collo_global = dynamicDowncast<Collo::GlobalObject>(global_object);
    if (!collo_global)
        return false;
    ColloVm& owner = collo_global->owner();
    void* host_runtime = nullptr;
    ColloExecCtx* exec_ctx = nullptr;
    if (!loadActiveTurn(owner, exec_ctx) || !loadRuntime(owner, host_runtime))
        return false;
    out = { &owner, host_runtime, exec_ctx };
    return true;
}

DeferredPromiseResult createPromiseDeferred(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, ColloVm& owner, WTF::ASCIILiteral failure_message)
{
    JSC::JSValue promise = JSC::jsUndefined();
    ColloPromiseDeferred* deferred = nullptr;
    ColloStatus status = Collo::createPromiseDeferred(&owner, global_object, &promise, &deferred);
    if (scope.exception())
        return { {}, {}, false };
    if (status != COLLO_STATUS_OK || !deferred)
        return { {}, Collo::HostFunctions::throwRuntimeError(global_object, scope, failure_message), false };
    return { { promise, deferred }, {}, true };
}

} // namespace Collo::HostFunctions::Runtime
