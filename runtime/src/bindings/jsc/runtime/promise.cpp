// Promise deferreds for the ABI and host functions, the thenable check, and collo_request_task_settle_thenable, which
// reports a handler's result to the Zig runtime once it settles. Runs on the VM thread.
//
// A ColloPromiseDeferred holds a value handle to each of its promise's resolve and reject functions until it settles;
// collo_promise_deferred_release frees it, settled or not, also after collo_vm_destroy, since releasing a value handle
// is safe then. It also names its promise's realm, where the value that settles it is created; the VM owns that realm,
// so the pointer is valid only while the VM lives, however long the deferred does. The settler functions capture the
// request's completion token by value, and the Zig runtime checks its slot and generations, so a settlement that
// arrives after its request ended cannot complete a later one.

#include "host_functions/internal.h"
#include "jsc/runtime/state.h"

#include <JavaScriptCore/JSNativeStdFunction.h>

using namespace JSC;

struct ColloPromiseDeferred {
    ColloVm* owner;
    ColloRealm* realm;
    ColloValue* resolve;
    ColloValue* reject;

    ColloPromiseDeferred(ColloRealm* promise_realm, ColloValue* resolve_handle, ColloValue* reject_handle)
        : owner(promise_realm->vm)
        , realm(promise_realm)
        , resolve(resolve_handle)
        , reject(reject_handle)
    {
    }

    void clear()
    {
        if (reject) {
            Collo::releaseValueHandle(reject);
            reject = nullptr;
        }
        if (resolve) {
            Collo::releaseValueHandle(resolve);
            resolve = nullptr;
        }
        owner = nullptr;
    }
};

namespace {

JSC::EncodedJSValue throwRuntimeError(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, ASCIILiteral message)
{
    return JSC::JSValue::encode(JSC::throwException(global_object, scope, JSC::createError(global_object, message)));
}

JSC::EncodedJSValue completeRequestTask(
    JSC::JSGlobalObject* global_object, JSC::CallFrame* call_frame, ColloRequestCompletionToken token, bool is_error)
{
    JSC::VM& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);

    auto* collo_global = dynamicDowncast<Collo::GlobalObject>(global_object);
    if (!collo_global)
        return throwRuntimeError(global_object, scope, "Collo global object is unavailable."_s);

    ColloVm& owner = collo_global->owner();
    void* host_runtime = owner.host_runtime.load(std::memory_order_acquire);
    if (!host_runtime)
        return throwRuntimeError(global_object, scope, "Request runtime is unavailable."_s);

    ColloValue* value_handle = nullptr;
    if (Collo::makeValueHandle(&owner, call_frame->argument(0), &value_handle) != COLLO_STATUS_OK || !value_handle)
        return throwRuntimeError(global_object, scope, "Failed to retain request completion value."_s);

    // The Zig runtime owns value_handle after this call, even when scheduling fails because the request already
    // completed or the command queue rejects it.
    ColloStatus status = collo_runtime_complete_request_task(host_runtime, token.slot, token.generation,
        token.request_id, token.request_generation, value_handle, is_error ? 1 : 0);
    if (status != COLLO_STATUS_OK)
        return throwRuntimeError(global_object, scope, "Failed to schedule request task completion."_s);

    return JSC::JSValue::encode(JSC::jsUndefined());
}

JSC::JSNativeStdFunction* requestTaskSettlerFunction(
    ColloVm& owner, JSC::JSGlobalObject* global_object, const ColloRequestCompletionToken& token, bool is_error)
{
    return JSC::JSNativeStdFunction::create(*owner.vm, global_object, 1,
        is_error ? "ColloRequestTaskReject"_s : "ColloRequestTaskResolve"_s,
        [token, is_error](JSC::JSGlobalObject* global_object, JSC::CallFrame* call_frame) -> JSC::EncodedJSValue {
            return completeRequestTask(global_object, call_frame, token, is_error);
        });
}

} // namespace

namespace Collo {

ColloStatus createPromiseDeferred(
    ColloVm* vm, JSC::JSGlobalObject* global_object, JSC::JSValue* out_promise, ColloPromiseDeferred** out_deferred)
{
    if (out_promise)
        *out_promise = JSC::jsUndefined();
    if (out_deferred)
        *out_deferred = nullptr;
    if (!vm || !vm->isReady() || !global_object || !out_promise || !out_deferred)
        return COLLO_STATUS_INVALID_ARGUMENT;
    auto* collo_global = dynamicDowncast<Collo::GlobalObject>(global_object);
    if (!collo_global || &collo_global->owner() != vm)
        return COLLO_STATUS_INVALID_ARGUMENT;

    auto data = JSC::JSPromise::createDeferredData(global_object, global_object->promiseConstructor());
    if (!data.promise || !data.resolve || !data.reject)
        return COLLO_STATUS_OUT_OF_MEMORY;

    ColloValue* resolve_handle = nullptr;
    ColloValue* reject_handle = nullptr;
    if (Collo::makeValueHandle(vm, data.resolve, &resolve_handle) != COLLO_STATUS_OK || !resolve_handle)
        return COLLO_STATUS_OUT_OF_MEMORY;
    if (Collo::makeValueHandle(vm, data.reject, &reject_handle) != COLLO_STATUS_OK || !reject_handle) {
        Collo::releaseValueHandle(resolve_handle);
        return COLLO_STATUS_OUT_OF_MEMORY;
    }

    auto* deferred = new (std::nothrow) ColloPromiseDeferred(&collo_global->realm(), resolve_handle, reject_handle);
    if (!deferred) {
        Collo::releaseValueHandle(reject_handle);
        Collo::releaseValueHandle(resolve_handle);
        return COLLO_STATUS_OUT_OF_MEMORY;
    }

    *out_promise = data.promise;
    *out_deferred = deferred;
    return COLLO_STATUS_OK;
}

ColloStatus settlePromiseDeferred(
    ColloVm* vm, ColloPromiseDeferred* deferred, JSC::JSValue value, bool is_rejection, ColloValue** out_exception)
{
    Collo::clearOutException(out_exception);
    if (!vm || !vm->isReady() || !deferred || deferred->owner != vm || !deferred->resolve || !deferred->reject)
        return COLLO_STATUS_INVALID_ARGUMENT;

    ColloValue* callback_handle = is_rejection ? deferred->reject : deferred->resolve;
    if (!Collo::valueBelongsToVm(vm, callback_handle))
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSValue callback_value = Collo::toJSValue(callback_handle);
    auto* callback_object = dynamicDowncast<JSC::JSObject>(callback_value);
    if (!callback_object)
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::CallData call_data = JSC::getCallData(callback_object);
    if (call_data.type == JSC::CallData::Type::None)
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::MarkedArgumentBuffer arguments;
    arguments.append(value);
    if (arguments.hasOverflowed())
        return COLLO_STATUS_OUT_OF_MEMORY;

    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(*vm->vm);
    JSC::call(deferred->realm->global_object, callback_object, call_data, JSC::jsUndefined(), arguments);
    if (scope.exception()) {
        ColloStatus status = Collo::caughtExceptionStatus(vm, scope, out_exception);
        deferred->clear();
        return status;
    }
    deferred->clear();
    return COLLO_STATUS_OK;
}

} // namespace Collo

extern "C" ColloStatus collo_value_is_thenable(
    ColloVm* vm, const ColloValue* value, uint8_t* out_is_thenable, ColloValue** out_exception)
{
    if (out_is_thenable)
        *out_is_thenable = 0;
    Collo::clearOutException(out_exception);
    if (!vm || !vm->isReady() || !Collo::valueBelongsToVm(vm, value) || !out_is_thenable)
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    JSC::JSValue js_value = Collo::toJSValue(value);
    auto* object = dynamicDowncast<JSC::JSObject>(js_value);
    if (!object)
        return COLLO_STATUS_OK;

    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(*vm->vm);
    JSC::JSValue then_value
        = object->get(Collo::globalObjectForValue(vm, object), JSC::Identifier::fromString(*vm->vm, "then"_s));
    if (scope.exception())
        return Collo::caughtExceptionStatus(vm, scope, out_exception);

    JSC::CallData call_data = JSC::getCallData(then_value);
    *out_is_thenable = call_data.type == JSC::CallData::Type::None ? 0 : 1;
    return COLLO_STATUS_OK;
}

extern "C" ColloStatus collo_promise_deferred_resolve(
    ColloVm* vm, ColloPromiseDeferred* deferred, const ColloValue* value, ColloValue** out_exception)
{
    if (!vm || !vm->isReady() || !Collo::valueBelongsToVm(vm, value))
        return COLLO_STATUS_INVALID_ARGUMENT;
    JSC::JSLockHolder locker(*vm->vm);
    return Collo::settlePromiseDeferred(vm, deferred, Collo::toJSValue(value), false, out_exception);
}

extern "C" ColloStatus collo_promise_deferred_reject(
    ColloVm* vm, ColloPromiseDeferred* deferred, const ColloValue* reason, ColloValue** out_exception)
{
    if (!vm || !vm->isReady() || !Collo::valueBelongsToVm(vm, reason))
        return COLLO_STATUS_INVALID_ARGUMENT;
    JSC::JSLockHolder locker(*vm->vm);
    return Collo::settlePromiseDeferred(vm, deferred, Collo::toJSValue(reason), true, out_exception);
}

extern "C" ColloRealm* collo_promise_deferred_realm(const ColloPromiseDeferred* deferred)
{
    return deferred ? deferred->realm : nullptr;
}

extern "C" void collo_promise_deferred_release(ColloPromiseDeferred* deferred)
{
    if (!deferred)
        return;
    deferred->clear();
    delete deferred;
}

extern "C" ColloStatus collo_request_task_settle_thenable(
    ColloVm* vm, const ColloRequestCompletionToken* token, const ColloValue* value, ColloValue** out_exception)
{
    Collo::clearOutException(out_exception);
    if (!vm || !vm->isReady() || !token || token->request_id == 0 || token->generation == 0
        || token->request_generation == 0 || !Collo::valueBelongsToVm(vm, value))
        return COLLO_STATUS_INVALID_ARGUMENT;

    JSC::JSLockHolder locker(*vm->vm);
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(*vm->vm);

    // The handler's own realm, so a promise it returned is adopted as it is: PromiseResolve wraps a promise whose
    // constructor is another realm's, which would cost the settlement an extra round of microtasks.
    JSC::JSValue js_value = Collo::toJSValue(value);
    auto* global_object = Collo::globalObjectForValue(vm, js_value);
    auto* resolve_function = requestTaskSettlerFunction(*vm, global_object, *token, false);
    auto* reject_function = requestTaskSettlerFunction(*vm, global_object, *token, true);
    if (!resolve_function || !reject_function)
        return COLLO_STATUS_OUT_OF_MEMORY;

    JSC::JSObject* promise_object
        = JSC::JSPromise::promiseResolve(global_object, global_object->promiseConstructor(), js_value);
    if (scope.exception())
        return Collo::caughtExceptionStatus(vm, scope, out_exception);

    auto* promise = dynamicDowncast<JSC::JSPromise>(promise_object);
    if (!promise)
        return COLLO_STATUS_ERROR;
    promise->performPromiseThen(*vm->vm, global_object, resolve_function, reject_function, JSC::jsUndefined());
    if (scope.exception())
        return Collo::caughtExceptionStatus(vm, scope, out_exception);
    return COLLO_STATUS_OK;
}
