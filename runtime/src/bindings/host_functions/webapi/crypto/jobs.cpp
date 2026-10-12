// Creates the promise of a SubtleCrypto method and dispatches its `CryptoJob`, inline or to the worker's crypto pool,
// and implements the bridge side of the crypto job functions in abi.h. Everything here runs on the VM thread except
// `collo_crypto_job_run`, which a crypto pool thread calls. Zig holds a job only after
// `collo_runtime_crypto_job_enqueue` returns OK, which transfers ownership; on any other status the bridge still owns
// the job and destroys it.

#include "jsc/runtime/state.h"

#include "host_functions/runtime/bridge.h"
#include "host_functions/webapi/crypto/jobs.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSObject.h>

namespace Collo::HostFunctions::WebCrypto {

CryptoAsyncContextResult createCryptoAsyncContext(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope)
{
    auto* collo_global = dynamicDowncast<Collo::GlobalObject>(global_object);
    if (!collo_global)
        return { {},
            rejectedPromise(global_object, JSC::createError(global_object, "Collo global object is unavailable."_s)),
            false };

    ColloVm& owner = collo_global->owner();
    JSC::JSValue promise = JSC::jsUndefined();
    ColloPromiseDeferred* deferred = nullptr;
    ColloStatus status = Collo::createPromiseDeferred(&owner, global_object, &promise, &deferred);
    if (scope.exception()) {
        if (deferred)
            collo_promise_deferred_release(deferred);
        JSC::JSValue exception = scope.exception()->value();
        // A termination stays pending, and the empty value lets the method return with it so the VM keeps unwinding.
        if (!scope.clearExceptionExceptTermination())
            return { {}, {}, false };
        return { {}, rejectedPromise(global_object, exception), false };
    }
    if (status != COLLO_STATUS_OK || !deferred) {
        if (deferred)
            collo_promise_deferred_release(deferred);
        return { {},
            rejectedPromise(global_object, JSC::createError(global_object, "Failed to create crypto promise."_s)),
            false };
    }

    return { { &owner, promise, deferred }, {}, true };
}

extern "C" void collo_crypto_job_run(ColloCryptoJob* job)
{
    if (!job)
        return;
    reinterpret_cast<CryptoJob*>(job)->run();
}

extern "C" ColloStatus collo_crypto_job_settle(ColloVm* vm, ColloCryptoJob* job, ColloValue** out_exception)
{
    Collo::clearOutException(out_exception);
    std::unique_ptr<CryptoJob> owned(reinterpret_cast<CryptoJob*>(job));
    if (!vm || !vm->isReady() || !owned)
        return COLLO_STATUS_INVALID_ARGUMENT;
    if (!owned->belongsTo(vm))
        return COLLO_STATUS_INVALID_ARGUMENT;
    return owned->settle(out_exception);
}

extern "C" void collo_crypto_job_destroy(ColloCryptoJob* job) { delete reinterpret_cast<CryptoJob*>(job); }

static JSC::EncodedJSValue runCryptoJobPromiseInline(
    JSC::JSGlobalObject* global_object, const CryptoAsyncContext& context, std::unique_ptr<CryptoJob> job)
{
    // A null job means its allocation failed, so the context still owns the deferred the job would have taken.
    if (!job) {
        collo_promise_deferred_release(context.deferred);
        return rejectedPromise(global_object, JSC::createError(global_object, "Failed to allocate crypto job."_s));
    }

    job->run();
    ColloValue* exception = nullptr;
    ColloStatus status = job->settle(&exception);
    if (exception)
        collo_value_release(exception);
    if (status != COLLO_STATUS_OK)
        return rejectedPromise(global_object, JSC::createError(global_object, "Failed to settle crypto promise."_s));
    return JSC::JSValue::encode(context.promise);
}

static bool activeCryptoRequestTurn(
    const CryptoAsyncContext& context, ColloExecCtx*& out_exec_ctx, void*& out_host_runtime)
{
    // Reads the context through `Runtime::activeExecContext`, not `current_exec_ctx`, so module top-level code, which
    // runs outside any turn, uses the evaluation the worker installed as the turnless context
    // (collo_vm_set_turnless_exec_ctx).
    out_exec_ctx = context.owner ? Runtime::activeExecContext(*context.owner) : nullptr;
    out_host_runtime = context.owner ? context.owner->host_runtime.load(std::memory_order_acquire) : nullptr;
    return out_exec_ctx && out_exec_ctx->request_id != 0 && out_host_runtime;
}

static JSC::EncodedJSValue rejectedWithOperationError(JSC::JSGlobalObject* global_object, WTF::ASCIILiteral message)
{
    return rejectedPromise(
        global_object, Collo::JscSupport::domExceptionValue(global_object, DOMExceptionCode::OperationError, message));
}

JSC::EncodedJSValue enqueueCryptoJobPromise(
    JSC::JSGlobalObject* global_object, const CryptoAsyncContext& context, std::unique_ptr<CryptoJob> job)
{
    if (!job)
        return runCryptoJobPromiseInline(global_object, context, nullptr);

    ColloExecCtx* exec_ctx = nullptr;
    void* host_runtime = nullptr;
    if (!activeCryptoRequestTurn(context, exec_ctx, host_runtime))
        return rejectedWithOperationError(global_object, "WebCrypto operation requires an active request turn."_s);

    if (job->cost() == CryptoJobCost::InlinePreferred)
        return runCryptoJobPromiseInline(global_object, context, WTF::move(job));

    auto* raw_job = reinterpret_cast<ColloCryptoJob*>(job.get());
    ColloStatus status = collo_runtime_crypto_job_enqueue(host_runtime, exec_ctx->request_id, raw_job);
    // The statuses follow `collo_runtime_crypto_job_enqueue` in `worker/host/crypto.zig`: a call outside an active
    // request, an in-flight bound reached, or a pool that is disabled or shutting down.
    switch (status) {
    case COLLO_STATUS_OK:
        job.release();
        return JSC::JSValue::encode(context.promise);
    case COLLO_STATUS_INVALID_ARGUMENT:
        return rejectedWithOperationError(global_object, "WebCrypto operation requires an active request turn."_s);
    case COLLO_STATUS_ERROR:
        return rejectedWithOperationError(global_object, "Too many WebCrypto operations are in flight."_s);
    case COLLO_STATUS_UNSUPPORTED:
        return rejectedWithOperationError(global_object, "The WebCrypto job pool is not running."_s);
    default:
        return rejectedWithOperationError(global_object, "The WebCrypto job pool refused the operation."_s);
    }
}

JSC::JSObject* createCryptoKeyPairObject(
    JSC::JSGlobalObject* global_object, JSC::VM& vm, JSColloCryptoKey* public_key, JSColloCryptoKey* private_key)
{
    auto* result = JSC::constructEmptyObject(global_object, global_object->objectPrototype(), 2);
    result->putDirect(vm, JSC::Identifier::fromString(vm, "publicKey"_s), public_key);
    result->putDirect(vm, JSC::Identifier::fromString(vm, "privateKey"_s), private_key);
    return result;
}

} // namespace Collo::HostFunctions::WebCrypto
