// Converts a fetch request snapshot to a ColloFetchInit and passes it to collo_runtime_fetch, on the VM thread. The
// init's URL, method and header pairs point into scheduleFetch's locals and its body into the snapshot the caller
// passes, so all of them are valid only for the call. The bridge checks the WebApiFetchRequest limits in
// webapi/limits.h before anything crosses the ABI, and that file says why Zig checks them again. Once
// collo_runtime_fetch receives the promise's deferred, Zig owns it on every path, including a failed schedule.

#include "host_functions/runtime/fetch.h"

#include "host_functions/runtime/bridge.h"
#include "host_functions/webapi/dom/dom_exception.h"
#include "host_functions/webapi/limits.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/JSCInlines.h>
#include <wtf/text/CString.h>

namespace {

ColloString borrowedString(const WTF::CString& value)
{
    return {
        reinterpret_cast<const uint8_t*>(value.data()),
        value.length(),
    };
}

ColloBuffer borrowedBuffer(const WTF::Vector<uint8_t>& value)
{
    return {
        value.isEmpty() ? nullptr : value.span().data(),
        value.size(),
    };
}

bool tryGetUtf8(const WTF::String& string, WTF::CString& out)
{
    auto converted = string.tryGetUTF8();
    if (!converted)
        return false;
    out = converted.value();
    return true;
}

// Fills `out` with UTF-8 name and value pairs that borrow from `storage`. The byte limit counts every name and value
// byte across all headers. Returns false with a QuotaExceededError or OutOfMemoryError thrown, or with nothing thrown
// when a UTF-8 conversion fails, which the caller reports itself.
bool encodeHeaders(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    const WTF::Vector<Collo::HostFunctions::ColloHeaderPair>& headers, WTF::Vector<WTF::CString>& storage,
    WTF::Vector<ColloNameValuePair>& out)
{
    using namespace Collo::HostFunctions;
    if (headers.size() > WebApiFetchRequestHeaderCountMax) {
        JSC::throwException(global_object, scope,
            createDOMException(global_object, DOMExceptionCode::QuotaExceededError,
                "Fetch request headers exceed the serverless header count limit"_s));
        return false;
    }
    if (!storage.tryReserveInitialCapacity(headers.size() * 2) || !out.tryReserveInitialCapacity(headers.size())) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }
    size_t aggregate_header_bytes = 0;
    for (const auto& header : headers) {
        auto name = header.name.tryGetUTF8();
        auto value = header.value.tryGetUTF8();
        if (!name || !value)
            return false;
        size_t name_length = name.value().length();
        size_t value_length = value.value().length();
        if (name_length > WebApiFetchRequestHeadersBytesMax
            || aggregate_header_bytes > WebApiFetchRequestHeadersBytesMax - name_length) {
            JSC::throwException(global_object, scope,
                createDOMException(global_object, DOMExceptionCode::QuotaExceededError,
                    "Fetch request headers exceed the serverless header byte limit"_s));
            return false;
        }
        aggregate_header_bytes += name_length;
        if (value_length > WebApiFetchRequestHeadersBytesMax
            || aggregate_header_bytes > WebApiFetchRequestHeadersBytesMax - value_length) {
            JSC::throwException(global_object, scope,
                createDOMException(global_object, DOMExceptionCode::QuotaExceededError,
                    "Fetch request headers exceed the serverless header byte limit"_s));
            return false;
        }
        aggregate_header_bytes += value_length;
        storage.append(name.value());
        storage.append(value.value());
        auto& stored_name = storage[storage.size() - 2];
        auto& stored_value = storage[storage.size() - 1];
        ColloNameValuePair pair {
            borrowedString(stored_name),
            borrowedString(stored_value),
        };
        out.append(WTF::move(pair));
    }
    return true;
}

} // namespace

namespace Collo::HostFunctions::Runtime {

void cancelFetch(JSC::JSGlobalObject* global_object, uint64_t fetch_id, JSC::JSValue reason)
{
    if (fetch_id == 0)
        return;
    auto* collo_global = dynamicDowncast<Collo::GlobalObject>(global_object);
    if (!collo_global)
        return;
    void* runtime_handle = hostRuntime(collo_global->owner());
    if (!runtime_handle)
        return;

    ColloValue* reason_handle = nullptr;
    if (reason && !reason.isEmpty()
        && Collo::makeValueHandle(&collo_global->owner(), reason, &reason_handle) != COLLO_STATUS_OK)
        reason_handle = nullptr;
    collo_runtime_fetch_cancel(runtime_handle, fetch_id, reason_handle);
}

ScheduledFetch scheduleFetch(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    const ActiveRequestRuntime& runtime, FetchRequestSnapshot&& request)
{
    WTF::CString url_utf8;
    WTF::CString method_utf8;
    WTF::Vector<WTF::CString> header_storage;
    WTF::Vector<ColloNameValuePair> header_pairs;
    if (!tryGetUtf8(request.url, url_utf8) || !tryGetUtf8(request.method, method_utf8))
        return { Collo::HostFunctions::throwRuntimeError(
                     global_object, scope, "Failed to encode fetch arguments as UTF-8."_s),
            0, false };
    if (!encodeHeaders(global_object, scope, request.headers, header_storage, header_pairs)) {
        if (scope.exception())
            return { {}, 0, false };
        return { Collo::HostFunctions::throwRuntimeError(
                     global_object, scope, "Failed to encode fetch arguments as UTF-8."_s),
            0, false };
    }
    if (method_utf8.length() > WebApiFetchRequestMethodBytesMax || url_utf8.length() > WebApiFetchRequestUrlBytesMax
        || request.body.size() > WebApiFetchRequestBodyPooledBytesMax) {
        auto* exception = createDOMException(global_object, DOMExceptionCode::QuotaExceededError,
            "Fetch request exceeds the serverless request body limit"_s);
        return { JSC::JSValue::encode(JSC::throwException(global_object, scope, exception)), 0, false };
    }

    auto deferred_promise
        = createPromiseDeferred(global_object, scope, *runtime.owner, "Failed to create fetch promise."_s);
    if (!deferred_promise.ok)
        return { deferred_promise.error, 0, false };

    ColloFetchInit init = {
        runtime.exec_ctx->request_id,
        borrowedString(url_utf8),
        borrowedString(method_utf8),
        borrowedBuffer(request.body),
        header_pairs.isEmpty() ? nullptr : header_pairs.span().data(),
        header_pairs.size(),
        request.flags,
        0,
    };
    uint64_t fetch_id = 0;
    ColloStatus status = collo_runtime_fetch(runtime.host_runtime, &init, deferred_promise.value.deferred, &fetch_id);
    if (status != COLLO_STATUS_OK) {
        // collo_runtime_fetch took the deferred although it failed, so the promise is left unsettled and unreferenced.
        return { Collo::HostFunctions::throwRuntimeError(global_object, scope, "Failed to schedule fetch."_s), 0,
            false };
    }

    // Zig reports a fetch it refused and already rejected as OK with fetch id 0 (collo_runtime_fetch in abi.h). Its
    // promise is returned like any other, and the 0 names nothing for cancelFetch.
    return { JSC::JSValue::encode(deferred_promise.value.promise), fetch_id, true };
}

} // namespace Collo::HostFunctions::Runtime
