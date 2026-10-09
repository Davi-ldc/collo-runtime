// The fetch body adapters fetch_body.h declares, run on the VM thread. The bridge keeps no body state: it compares the
// identity's request id with the current execution context's and leaves everything else about the body to the runtime.

#include "host_functions/runtime/fetch_body.h"

#include "host_functions/runtime/bridge.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/JSCInlines.h>
#include <wtf/text/CString.h>

#include <span>

namespace {

using Collo::HostFunctions::throwRuntimeError;

// Rejects `promise` with a TypeError carrying `message`, releases `deferred` and returns the promise. Only for a
// deferred no ABI call has received yet: once one has, Zig owns it even when the call fails.
JSC::EncodedJSValue rejectUnscheduledDeferredTypeError(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    ColloVm& owner, JSC::JSValue promise, ColloPromiseDeferred* deferred, ASCIILiteral message)
{
    ColloStatus status
        = Collo::settlePromiseDeferred(&owner, deferred, JSC::createTypeError(global_object, message), true, nullptr);
    collo_promise_deferred_release(deferred);
    if (status != COLLO_STATUS_OK)
        return throwRuntimeError(global_object, scope, "Failed to reject fetch body promise."_s);
    return JSC::JSValue::encode(promise);
}

ColloString borrowedString(const WTF::CString& value)
{
    return {
        reinterpret_cast<const uint8_t*>(value.data()),
        value.length(),
    };
}

JSC::EncodedJSValue fetchBodyForIdentity(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    const ColloFetchBodyIdentity& identity, ColloFetchBodyConsumeKind kind, WTF::String content_type,
    ASCIILiteral active_turn_message, ASCIILiteral original_turn_message, ASCIILiteral failure_message)
{
    auto owner_result = Collo::HostFunctions::Runtime::requireVmOwner(global_object, scope);
    if (!owner_result.ok)
        return owner_result.error;

    ColloVm& owner = *owner_result.owner;
    ColloExecCtx* exec_ctx = Collo::HostFunctions::Runtime::activeExecContext(owner);
    if (!exec_ctx)
        return Collo::HostFunctions::rejectedTypeError(global_object, scope, active_turn_message);
    if (exec_ctx->request_id != identity.request_id)
        return Collo::HostFunctions::rejectedTypeError(global_object, scope, original_turn_message);

    void* host_runtime = Collo::HostFunctions::Runtime::hostRuntime(owner);
    if (!host_runtime)
        return throwRuntimeError(global_object, scope, "Fetch body runtime is unavailable."_s);

    auto deferred_promise = Collo::HostFunctions::Runtime::createPromiseDeferred(
        global_object, scope, owner, "Failed to create fetch body promise."_s);
    if (!deferred_promise.ok)
        return deferred_promise.error;

    auto type_utf8 = content_type.tryGetUTF8();
    if (!type_utf8)
        return rejectUnscheduledDeferredTypeError(global_object, scope, owner, deferred_promise.value.promise,
            deferred_promise.value.deferred, failure_message);

    ColloFetchBodyConsumeInit init {
        identity,
        borrowedString(type_utf8.value()),
        kind,
        { 0, 0, 0, 0, 0, 0, 0 },
    };
    uint64_t task_id = 0;
    ColloStatus status
        = collo_runtime_fetch_body_consume(host_runtime, &init, deferred_promise.value.deferred, &task_id);
    if (status != COLLO_STATUS_OK) {
        // Zig took the deferred although the call failed, so a separate rejected promise reports the failure.
        return Collo::HostFunctions::rejectedTypeError(global_object, scope, failure_message);
    }

    return JSC::JSValue::encode(deferred_promise.value.promise);
}

bool borrowFetchBodyBytes(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    const ColloFetchBodyIdentity& identity, ColloBuffer& out)
{
    out = { nullptr, 0 };
    auto owner_result = Collo::HostFunctions::Runtime::requireVmOwner(global_object, scope);
    if (!owner_result.ok)
        return false;

    ColloVm& owner = *owner_result.owner;
    ColloExecCtx* exec_ctx = Collo::HostFunctions::Runtime::activeExecContext(owner);
    if (!exec_ctx) {
        JSC::throwVMTypeError(global_object, scope, "fetch response body requires an active request turn"_s);
        return false;
    }
    if (exec_ctx->request_id != identity.request_id) {
        JSC::throwVMTypeError(global_object, scope, "fetch response body requires the original request turn"_s);
        return false;
    }

    void* host_runtime = Collo::HostFunctions::Runtime::hostRuntime(owner);
    if (!host_runtime) {
        JSC::throwVMTypeError(global_object, scope, "fetch response body runtime is unavailable"_s);
        return false;
    }
    if (collo_runtime_fetch_body_borrow(host_runtime, &identity, &out) != COLLO_STATUS_OK) {
        JSC::throwVMTypeError(global_object, scope, "fetch response body is no longer available"_s);
        return false;
    }
    return true;
}

JSC::EncodedJSValue scheduleFetchBodyPull(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const ColloFetchBodyIdentity& identity)
{
    auto owner_result = Collo::HostFunctions::Runtime::requireVmOwner(global_object, scope);
    if (!owner_result.ok)
        return owner_result.error;

    ColloVm& owner = *owner_result.owner;
    ColloExecCtx* exec_ctx = Collo::HostFunctions::Runtime::activeExecContext(owner);
    if (!exec_ctx)
        return Collo::HostFunctions::rejectedTypeError(
            global_object, scope, "Response.body read requires an active request turn."_s);
    if (exec_ctx->request_id != identity.request_id)
        return Collo::HostFunctions::rejectedTypeError(
            global_object, scope, "Response.body read requires the original request turn."_s);

    void* host_runtime = Collo::HostFunctions::Runtime::hostRuntime(owner);
    if (!host_runtime)
        return throwRuntimeError(global_object, scope, "Fetch body runtime is unavailable."_s);

    auto deferred_promise = Collo::HostFunctions::Runtime::createPromiseDeferred(
        global_object, scope, owner, "Failed to create fetch body read promise."_s);
    if (!deferred_promise.ok)
        return deferred_promise.error;

    uint64_t task_id = 0;
    ColloStatus status
        = collo_runtime_fetch_body_pull(host_runtime, &identity, deferred_promise.value.deferred, &task_id);
    if (status != COLLO_STATUS_OK) {
        // Zig took the deferred although the call failed, so a separate rejected promise reports the failure.
        return Collo::HostFunctions::rejectedTypeError(global_object, scope, "Failed to schedule fetch body read."_s);
    }

    return JSC::JSValue::encode(deferred_promise.value.promise);
}

} // namespace

namespace Collo::HostFunctions {

JSC::EncodedJSValue fetchBodyTextForIdentity(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const ColloFetchBodyIdentity& identity)
{
    return fetchBodyForIdentity(global_object, scope, identity, COLLO_FETCH_BODY_CONSUME_TEXT, WTF::emptyString(),
        "Response.text requires an active request turn."_s, "Response.text requires the original request turn."_s,
        "Failed to schedule fetch body read."_s);
}

JSC::EncodedJSValue fetchBodyJsonForIdentity(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const ColloFetchBodyIdentity& identity)
{
    return fetchBodyForIdentity(global_object, scope, identity, COLLO_FETCH_BODY_CONSUME_JSON, WTF::emptyString(),
        "Response.json requires an active request turn."_s, "Response.json requires the original request turn."_s,
        "Failed to schedule fetch JSON read."_s);
}

JSC::EncodedJSValue fetchBodyArrayBufferForIdentity(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const ColloFetchBodyIdentity& identity)
{
    return fetchBodyForIdentity(global_object, scope, identity, COLLO_FETCH_BODY_CONSUME_ARRAY_BUFFER,
        WTF::emptyString(), "Response.arrayBuffer requires an active request turn."_s,
        "Response.arrayBuffer requires the original request turn."_s, "Failed to schedule fetch body read."_s);
}

JSC::EncodedJSValue fetchBodyBytesForIdentity(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const ColloFetchBodyIdentity& identity)
{
    return fetchBodyForIdentity(global_object, scope, identity, COLLO_FETCH_BODY_CONSUME_BYTES, WTF::emptyString(),
        "Response.bytes requires an active request turn."_s, "Response.bytes requires the original request turn."_s,
        "Failed to schedule fetch body read."_s);
}

JSC::EncodedJSValue fetchBodyBlobForIdentity(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    const ColloFetchBodyIdentity& identity, WTF::String type)
{
    return fetchBodyForIdentity(global_object, scope, identity, COLLO_FETCH_BODY_CONSUME_BLOB, WTF::move(type),
        "Response.blob requires an active request turn."_s, "Response.blob requires the original request turn."_s,
        "Failed to schedule fetch body read."_s);
}

JSC::EncodedJSValue fetchBodyFormDataForIdentity(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    const ColloFetchBodyIdentity& identity, WTF::String content_type)
{
    return fetchBodyForIdentity(global_object, scope, identity, COLLO_FETCH_BODY_CONSUME_FORM_DATA,
        WTF::move(content_type), "Response.formData requires an active request turn."_s,
        "Response.formData requires the original request turn."_s, "Failed to schedule fetch form data read."_s);
}

bool fetchBodyByteLengthForIdentity(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const ColloFetchBodyIdentity& identity, size_t& out)
{
    out = 0;
    ColloBuffer borrowed {};
    if (!borrowFetchBodyBytes(global_object, scope, identity, borrowed))
        return false;
    out = borrowed.len;
    return true;
}

bool fetchBodyAppendBytesForIdentity(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    const ColloFetchBodyIdentity& identity, WTF::Vector<uint8_t>& out)
{
    ColloBuffer borrowed {};
    if (!borrowFetchBodyBytes(global_object, scope, identity, borrowed))
        return false;
    if (!borrowed.len)
        return true;
    if (!out.tryAppend(std::span<const uint8_t> { borrowed.ptr, borrowed.len })) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }
    return true;
}

bool fetchBodyCloneForIdentity(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    const ColloFetchBodyIdentity& identity, ColloFetchBodyIdentity& out_identity)
{
    out_identity = {};
    auto owner_result = Collo::HostFunctions::Runtime::requireVmOwner(global_object, scope);
    if (!owner_result.ok)
        return false;

    ColloVm& owner = *owner_result.owner;
    ColloExecCtx* exec_ctx = Collo::HostFunctions::Runtime::activeExecContext(owner);
    if (!exec_ctx) {
        JSC::throwVMTypeError(global_object, scope, "Response.clone requires an active request turn"_s);
        return false;
    }
    if (exec_ctx->request_id != identity.request_id) {
        JSC::throwVMTypeError(global_object, scope, "Response.clone requires the original request turn"_s);
        return false;
    }

    void* host_runtime = Collo::HostFunctions::Runtime::hostRuntime(owner);
    if (!host_runtime) {
        JSC::throwVMTypeError(global_object, scope, "fetch response body runtime is unavailable"_s);
        return false;
    }
    if (collo_runtime_fetch_body_clone(host_runtime, &identity, &out_identity) != COLLO_STATUS_OK) {
        JSC::throwVMTypeError(global_object, scope, "fetch response body cannot be cloned"_s);
        return false;
    }
    return true;
}

JSC::EncodedJSValue fetchBodyPullForIdentity(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const ColloFetchBodyIdentity& identity)
{
    return scheduleFetchBodyPull(global_object, scope, identity);
}

void fetchBodyCancelForIdentity(JSC::JSGlobalObject* global_object, const ColloFetchBodyIdentity& identity)
{
    auto* collo_global = dynamicDowncast<Collo::GlobalObject>(global_object);
    if (!collo_global)
        return;
    void* host_runtime = Collo::HostFunctions::Runtime::hostRuntime(collo_global->owner());
    if (!host_runtime)
        return;
    collo_runtime_fetch_body_cancel(host_runtime, &identity);
}

void fetchBodyReleaseForIdentity(ColloVm& owner, const ColloFetchBodyIdentity& identity)
{
    void* host_runtime = Collo::HostFunctions::Runtime::hostRuntime(owner);
    if (!host_runtime)
        return;
    collo_runtime_fetch_body_release(host_runtime, &identity);
}

} // namespace Collo::HostFunctions
