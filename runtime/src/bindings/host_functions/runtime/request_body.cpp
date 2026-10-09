// The request body readers request_body.h declares, run on the VM thread. The bridge compares the token's request id
// with the current execution context's, and the runtime checks the token's generation against the active request's.
// Once a `collo_runtime_request_*` call receives the promise's deferred, Zig owns it on every path.

#include "host_functions/runtime/request_body.h"
#include "host_functions/runtime/bridge.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/JSCInlines.h>

using Collo::HostFunctions::throwRuntimeError;

namespace Collo::HostFunctions {

using RequestBodyScheduler = ColloStatus (*)(void* runtime, uint64_t request_id, uint64_t request_generation,
    ColloPromiseDeferred* deferred, uint64_t* out_task_id);

static JSC::EncodedJSValue requestBodyForIdentity(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    const ColloRequestIdentity& token, RequestBodyScheduler scheduler, ASCIILiteral active_turn_message,
    ASCIILiteral original_turn_message, ASCIILiteral failure_message)
{
    auto owner_result = Runtime::requireVmOwner(global_object, scope);
    if (!owner_result.ok)
        return owner_result.error;

    ColloVm& owner = *owner_result.owner;
    ColloExecCtx* exec_ctx = Runtime::activeExecContext(owner);
    if (!exec_ctx)
        return rejectedTypeError(global_object, scope, active_turn_message);

    if (exec_ctx->request_id != token.request_id)
        return rejectedTypeError(global_object, scope, original_turn_message);

    void* host_runtime = Runtime::hostRuntime(owner);
    if (!host_runtime)
        return throwRuntimeError(global_object, scope, "Request body runtime is unavailable."_s);

    auto deferred_promise
        = Runtime::createPromiseDeferred(global_object, scope, owner, "Failed to create request body promise."_s);
    if (!deferred_promise.ok)
        return deferred_promise.error;

    uint64_t task_id = 0;
    ColloStatus status = scheduler(
        host_runtime, token.request_id, token.request_generation, deferred_promise.value.deferred, &task_id);
    if (status != COLLO_STATUS_OK) {
        // Zig took the deferred although the call failed, so a separate rejected promise reports the failure.
        return rejectedTypeError(global_object, scope, failure_message);
    }

    return JSC::JSValue::encode(deferred_promise.value.promise);
}

JSC::EncodedJSValue requestTextForIdentity(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const ColloRequestIdentity& token)
{
    return requestBodyForIdentity(global_object, scope, token, collo_runtime_request_text,
        "Request.text requires an active request turn."_s, "Request.text requires the original request turn."_s,
        "Failed to schedule request body read."_s);
}

JSC::EncodedJSValue requestJsonForIdentity(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const ColloRequestIdentity& token)
{
    return requestBodyForIdentity(global_object, scope, token, collo_runtime_request_json,
        "Request.json requires an active request turn."_s, "Request.json requires the original request turn."_s,
        "Failed to schedule request JSON read."_s);
}

JSC::EncodedJSValue requestArrayBufferForIdentity(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const ColloRequestIdentity& token)
{
    return requestBodyForIdentity(global_object, scope, token, collo_runtime_request_array_buffer,
        "Request.arrayBuffer requires an active request turn."_s,
        "Request.arrayBuffer requires the original request turn."_s, "Failed to schedule request body read."_s);
}

JSC::EncodedJSValue requestBytesForIdentity(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const ColloRequestIdentity& token)
{
    return requestBodyForIdentity(global_object, scope, token, collo_runtime_request_bytes,
        "Request.bytes requires an active request turn."_s, "Request.bytes requires the original request turn."_s,
        "Failed to schedule request body read."_s);
}

JSC::EncodedJSValue requestBlobForIdentity(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const ColloRequestIdentity& token, WTF::String type)
{
    auto owner_result = Runtime::requireVmOwner(global_object, scope);
    if (!owner_result.ok)
        return owner_result.error;

    ColloVm& owner = *owner_result.owner;
    ColloExecCtx* exec_ctx = Runtime::activeExecContext(owner);
    if (!exec_ctx)
        return rejectedTypeError(global_object, scope, "Request.blob requires an active request turn."_s);

    if (exec_ctx->request_id != token.request_id)
        return rejectedTypeError(global_object, scope, "Request.blob requires the original request turn."_s);

    void* host_runtime = Runtime::hostRuntime(owner);
    if (!host_runtime)
        return throwRuntimeError(global_object, scope, "Request body runtime is unavailable."_s);

    auto deferred_promise
        = Runtime::createPromiseDeferred(global_object, scope, owner, "Failed to create request body promise."_s);
    if (!deferred_promise.ok)
        return deferred_promise.error;

    auto utf8 = type.utf8();
    ColloString raw_type {
        utf8.isEmpty() ? nullptr : reinterpret_cast<const uint8_t*>(utf8.data()),
        utf8.length(),
    };

    uint64_t task_id = 0;
    ColloStatus status = collo_runtime_request_blob(
        host_runtime, token.request_id, token.request_generation, raw_type, deferred_promise.value.deferred, &task_id);
    if (status != COLLO_STATUS_OK) {
        // Zig took the deferred although the call failed, so a separate rejected promise reports the failure.
        return rejectedTypeError(global_object, scope, "Failed to schedule request body read."_s);
    }

    return JSC::JSValue::encode(deferred_promise.value.promise);
}

JSC::EncodedJSValue requestFormDataForIdentity(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    const ColloRequestIdentity& token, WTF::String content_type)
{
    auto owner_result = Runtime::requireVmOwner(global_object, scope);
    if (!owner_result.ok)
        return owner_result.error;

    ColloVm& owner = *owner_result.owner;
    ColloExecCtx* exec_ctx = Runtime::activeExecContext(owner);
    if (!exec_ctx)
        return rejectedTypeError(global_object, scope, "Request.formData requires an active request turn."_s);

    if (exec_ctx->request_id != token.request_id)
        return rejectedTypeError(global_object, scope, "Request.formData requires the original request turn."_s);

    void* host_runtime = Runtime::hostRuntime(owner);
    if (!host_runtime)
        return throwRuntimeError(global_object, scope, "Request body runtime is unavailable."_s);

    auto deferred_promise
        = Runtime::createPromiseDeferred(global_object, scope, owner, "Failed to create request body promise."_s);
    if (!deferred_promise.ok)
        return deferred_promise.error;

    auto utf8 = content_type.utf8();
    ColloString raw_type {
        utf8.isEmpty() ? nullptr : reinterpret_cast<const uint8_t*>(utf8.data()),
        utf8.length(),
    };

    uint64_t task_id = 0;
    ColloStatus status = collo_runtime_request_form_data(
        host_runtime, token.request_id, token.request_generation, raw_type, deferred_promise.value.deferred, &task_id);
    if (status != COLLO_STATUS_OK) {
        // Zig took the deferred although the call failed, so a separate rejected promise reports the failure.
        return rejectedTypeError(global_object, scope, "Failed to schedule request form data read."_s);
    }

    return JSC::JSValue::encode(deferred_promise.value.promise);
}

} // namespace Collo::HostFunctions
