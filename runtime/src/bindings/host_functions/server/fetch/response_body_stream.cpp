// How the worker reads a Response's ReadableStream body once the handler returned it. Extraction locks the stream and
// hands Zig a ColloResponseBodyStream; Zig then starts one read at a time, each inside a turn of the request that owns
// the response, borrows each chunk's bytes, and cancels or destroys the handle when the response ends. Runs on the VM
// thread, and every ABI call takes the JSC lock.
//
// A ColloResponseBodyStream belongs to Zig from extraction until collo_response_body_stream_destroy. It roots the
// locked stream and its two read reactions through ColloValue handles, which the VM's destruction empties, so the
// handle can be destroyed at any time. Nothing it roots reaches back to it: each reaction captures only the request id
// it reports under, and the runtime that receives the report (collo_runtime_response_body_stream_settled) checks that
// the request still waits for a read of this body, so a result that outlives its request, or its handle, is dropped.
// The reactions are made at the first read and serve every read after it.
//
// A read registers its reactions inside the caller's turn, so the microtask owner hook (WebKit patch 0004) runs each
// reaction under the request that started the read, whoever settles it: the pull that produced the chunk and the
// report of it are that request's work, under its deadline and CPU budget.

#include "host_functions/server/fetch/response_body_stream.h"

#include "host_functions/server/fetch/body_utils.h"
#include "host_functions/server/fetch/extracted_response.h"
#include "host_functions/webapi/buffer_source.h"
#include "host_functions/webapi/dom/dom_exception.h"
#include "host_functions/webapi/streams/readable_stream_private.h"

#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSNativeStdFunction.h>
#include <JavaScriptCore/JSPromise.h>

#include <memory>
#include <new>

struct ColloResponseBodyStream {
    ColloResponseBodyStream() = default;
    ColloResponseBodyStream(const ColloResponseBodyStream&) = delete;
    ColloResponseBodyStream& operator=(const ColloResponseBodyStream&) = delete;

    // releaseValueHandle is safe from any thread and after the VM is destroyed.
    ~ColloResponseBodyStream()
    {
        if (read_rejected)
            Collo::releaseValueHandle(read_rejected);
        if (read_fulfilled)
            Collo::releaseValueHandle(read_fulfilled);
        if (stream)
            Collo::releaseValueHandle(stream);
    }

    ColloVm* owner { nullptr };
    // The ReadableStream, locked by a reader of the bridge's own.
    ColloValue* stream { nullptr };
    // Null until the first read creates both.
    ColloValue* read_fulfilled { nullptr };
    ColloValue* read_rejected { nullptr };
    // The request the reactions report under, fixed by the first read.
    uint64_t request_id { 0 };
};

namespace Collo::HostFunctions {
namespace {

    using JSC::EncodedJSValue;
    using JSC::JSValue;

    constexpr WTF::ASCIILiteral chunk_type_message
        = "Response body stream chunks must be an ArrayBuffer, an ArrayBufferView or a string"_s;

    // Reports one read's outcome to the runtime attached to the reaction's VM, under the request the read was started
    // for. `value` is the chunk for CHUNK and the reason for ERROR; DONE carries none.
    void reportReadResult(
        JSC::JSGlobalObject* global_object, uint64_t request_id, ColloResponseBodyStreamResult result, JSValue value)
    {
        auto* collo_global = dynamicDowncast<Collo::GlobalObject>(global_object);
        if (!collo_global)
            return;
        ColloVm& owner = collo_global->owner();
        // No runtime is attached in a bindings test or once the worker's runtime detached at teardown, and then nobody
        // waits for the result.
        void* host_runtime = owner.host_runtime.load(std::memory_order_acquire);
        if (!host_runtime)
            return;

        ColloValue* handle = nullptr;
        if (result != COLLO_RESPONSE_BODY_STREAM_RESULT_DONE
            && Collo::makeValueHandle(&owner, value, &handle) != COLLO_STATUS_OK) {
            // A chunk that cannot reach the runtime must not be skipped, so the read reports a failure without a
            // reason and the response ends instead of losing bytes in its middle.
            handle = nullptr;
            result = COLLO_RESPONSE_BODY_STREAM_RESULT_ERROR;
        }
        // The runtime takes the handle on every call.
        collo_runtime_response_body_stream_settled(host_runtime, request_id, result, handle);
    }

    JSC::JSNativeStdFunction* createReadFulfilledReaction(
        JSC::VM& vm, JSC::JSGlobalObject* global_object, uint64_t request_id)
    {
        return JSC::JSNativeStdFunction::create(vm, global_object, 1, "ColloResponseBodyStreamReadFulfilled"_s,
            [request_id](JSC::JSGlobalObject* global_object, JSC::CallFrame* call_frame) -> EncodedJSValue {
                auto& vm = global_object->vm();
                auto scope = DECLARE_THROW_SCOPE(vm);
                // The stream itself made this {value, done} object, with both as own data properties, so reading them
                // runs no script.
                auto* read_result = call_frame->argument(0).getObject();
                if (!read_result) {
                    reportReadResult(global_object, request_id, COLLO_RESPONSE_BODY_STREAM_RESULT_ERROR,
                        JSC::createTypeError(global_object, "ReadableStream read returned a non-object"_s));
                    return JSValue::encode(JSC::jsUndefined());
                }
                JSValue done = read_result->get(global_object, vm.propertyNames->done);
                RETURN_IF_EXCEPTION(scope, {});
                if (done.toBoolean(global_object)) {
                    reportReadResult(global_object, request_id, COLLO_RESPONSE_BODY_STREAM_RESULT_DONE, JSValue());
                    return JSValue::encode(JSC::jsUndefined());
                }
                JSValue chunk = read_result->get(global_object, vm.propertyNames->value);
                RETURN_IF_EXCEPTION(scope, {});
                reportReadResult(global_object, request_id, COLLO_RESPONSE_BODY_STREAM_RESULT_CHUNK, chunk);
                return JSValue::encode(JSC::jsUndefined());
            });
    }

    JSC::JSNativeStdFunction* createReadRejectedReaction(
        JSC::VM& vm, JSC::JSGlobalObject* global_object, uint64_t request_id)
    {
        return JSC::JSNativeStdFunction::create(vm, global_object, 1, "ColloResponseBodyStreamReadRejected"_s,
            [request_id](JSC::JSGlobalObject* global_object, JSC::CallFrame* call_frame) -> EncodedJSValue {
                reportReadResult(
                    global_object, request_id, COLLO_RESPONSE_BODY_STREAM_RESULT_ERROR, call_frame->argument(0));
                return JSValue::encode(JSC::jsUndefined());
            });
    }

    ColloStatus createReadReactions(
        ColloResponseBodyStream& body_stream, JSC::VM& vm, JSC::JSGlobalObject* global_object, uint64_t request_id)
    {
        auto* fulfilled = createReadFulfilledReaction(vm, global_object, request_id);
        auto* rejected = createReadRejectedReaction(vm, global_object, request_id);
        if (!fulfilled || !rejected)
            return COLLO_STATUS_OUT_OF_MEMORY;

        ColloValue* fulfilled_handle = nullptr;
        if (Collo::makeValueHandle(body_stream.owner, fulfilled, &fulfilled_handle) != COLLO_STATUS_OK
            || !fulfilled_handle)
            return COLLO_STATUS_OUT_OF_MEMORY;
        ColloValue* rejected_handle = nullptr;
        if (Collo::makeValueHandle(body_stream.owner, rejected, &rejected_handle) != COLLO_STATUS_OK
            || !rejected_handle) {
            Collo::releaseValueHandle(fulfilled_handle);
            return COLLO_STATUS_OUT_OF_MEMORY;
        }
        body_stream.read_fulfilled = fulfilled_handle;
        body_stream.read_rejected = rejected_handle;
        body_stream.request_id = request_id;
        return COLLO_STATUS_OK;
    }

    // Null for a reason the ABI does not define.
    JSC::JSObject* createCancelReason(JSC::JSGlobalObject* global_object, ColloResponseBodyStreamCancel reason)
    {
        switch (reason) {
        case COLLO_RESPONSE_BODY_STREAM_CANCEL_CLIENT_RESET:
            return createDOMException(
                global_object, DOMExceptionCode::AbortError, "The client reset the response stream"_s);
        case COLLO_RESPONSE_BODY_STREAM_CANCEL_RESPONSE_FAILED:
            return createDOMException(
                global_object, DOMExceptionCode::AbortError, "The response ended before its body stream closed"_s);
        case COLLO_RESPONSE_BODY_STREAM_CANCEL_INVALID_CHUNK:
            return JSC::createTypeError(global_object, chunk_type_message);
        default:
            return nullptr;
        }
    }

    bool cancelReasonIsDefined(ColloResponseBodyStreamCancel reason)
    {
        return reason == COLLO_RESPONSE_BODY_STREAM_CANCEL_CLIENT_RESET
            || reason == COLLO_RESPONSE_BODY_STREAM_CANCEL_RESPONSE_FAILED
            || reason == COLLO_RESPONSE_BODY_STREAM_CANCEL_INVALID_CHUNK;
    }

    // False for no handle, a VM that is not ready or a stream handle of another VM. Reads no cell, so it runs before
    // the JSC lock is taken.
    bool bodyStreamIsUsable(const ColloResponseBodyStream* body_stream)
    {
        if (!body_stream || !body_stream->owner || !body_stream->owner->isReady())
            return false;
        return Collo::valueBelongsToVm(body_stream->owner, body_stream->stream);
    }

    // The locked stream a usable handle roots. Call it under the JSC lock.
    JSColloReadableStream* lockedStream(const ColloResponseBodyStream& body_stream)
    {
        return dynamicDowncast<JSColloReadableStream>(Collo::toJSValue(body_stream.stream));
    }

} // namespace

ColloStatus extractResponseBodyStream(ColloVm* owner, JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSC::JSObject* body_stream, ColloExtractedResponseBody& out)
{
    auto* stream = dynamicDowncast<JSColloReadableStream>(body_stream);
    if (!stream)
        return COLLO_STATUS_ERROR;
    if (stream->locked() || stream->disturbed()) {
        JSC::throwVMTypeError(global_object, scope, "Response body is already used."_s);
        return COLLO_STATUS_JS_EXCEPTION;
    }
    switch (stream->state()) {
    case StreamState::Closed:
        resetExtractedResponseBody(out);
        return COLLO_STATUS_OK;
    case StreamState::Errored:
        JSC::throwException(global_object, scope, stream->storedError());
        return COLLO_STATUS_JS_EXCEPTION;
    case StreamState::Readable:
        break;
    }

    std::unique_ptr<ColloResponseBodyStream> handle { new (std::nothrow) ColloResponseBodyStream };
    if (!handle)
        return COLLO_STATUS_OUT_OF_MEMORY;
    handle->owner = owner;
    if (Collo::makeValueHandle(owner, stream, &handle->stream) != COLLO_STATUS_OK || !handle->stream)
        return COLLO_STATUS_OUT_OF_MEMORY;

    auto& vm = global_object->vm();
    auto* reader = JSColloReadableStreamDefaultReader::create(vm, global_object, stream);
    RETURN_IF_EXCEPTION(scope, COLLO_STATUS_JS_EXCEPTION);
    if (!reader)
        return COLLO_STATUS_ERROR;
    stream->lock(vm, reader);

    resetExtractedResponseBody(out);
    out.kind = COLLO_EXTRACTED_RESPONSE_BODY_READABLE_STREAM;
    out.body_stream = handle.release();
    return COLLO_STATUS_OK;
}

extern "C" ColloStatus collo_response_body_stream_read(
    ColloResponseBodyStream* body_stream, uint64_t request_id, ColloValue** out_exception)
{
    Collo::clearOutException(out_exception);
    if (!request_id || request_id > COLLO_REQUEST_ID_MAX)
        return COLLO_STATUS_INVALID_ARGUMENT;
    if (!bodyStreamIsUsable(body_stream))
        return COLLO_STATUS_INVALID_ARGUMENT;
    if (body_stream->request_id && body_stream->request_id != request_id)
        return COLLO_STATUS_INVALID_ARGUMENT;

    ColloVm* owner = body_stream->owner;
    JSC::JSLockHolder locker(*owner->vm);
    auto& vm = *owner->vm;
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream = lockedStream(*body_stream);
    if (!stream)
        return COLLO_STATUS_INVALID_ARGUMENT;
    auto* global_object = stream->globalObject();
    if (!body_stream->read_fulfilled) {
        if (auto status = createReadReactions(*body_stream, vm, global_object, request_id); status != COLLO_STATUS_OK)
            return status;
        if (auto status = consumeExceptionStatus(owner, scope, out_exception); status != COLLO_STATUS_OK)
            return status;
    }

    // The stream's own read, as pipeTo uses: the reader that locks the stream is the bridge's and never escapes it.
    JSValue read_value = JSValue::decode(stream->read(global_object, scope));
    if (auto status = consumeExceptionStatus(owner, scope, out_exception); status != COLLO_STATUS_OK)
        return status;
    auto* read_promise = dynamicDowncast<JSC::JSPromise>(read_value);
    if (!read_promise)
        return COLLO_STATUS_ERROR;
    read_promise->performPromiseThen(vm, global_object, Collo::toJSValue(body_stream->read_fulfilled),
        Collo::toJSValue(body_stream->read_rejected), JSC::jsUndefined());
    return consumeExceptionStatus(owner, scope, out_exception);
}

extern "C" ColloStatus collo_response_body_stream_chunk(ColloResponseBodyStream* body_stream, const ColloValue* chunk,
    ColloResponseBodyChunk* out_chunk, ColloValue** out_exception)
{
    if (out_chunk)
        *out_chunk = {};
    Collo::clearOutException(out_exception);
    if (!out_chunk || !bodyStreamIsUsable(body_stream) || !Collo::valueBelongsToVm(body_stream->owner, chunk))
        return COLLO_STATUS_INVALID_ARGUMENT;

    ColloVm* owner = body_stream->owner;
    JSC::JSLockHolder locker(*owner->vm);
    auto scope = DECLARE_THROW_SCOPE(*owner->vm);
    auto* stream = lockedStream(*body_stream);
    if (!stream)
        return COLLO_STATUS_INVALID_ARGUMENT;
    auto* global_object = stream->globalObject();
    JSValue value = Collo::toJSValue(chunk);

    // A buffer's bytes are lent in place. The chunk's handle keeps its storage alive, and the storage changes or
    // detaches only when script runs, which the next ABI call on this VM may do.
    if (auto* view = dynamicDowncast<JSC::JSArrayBufferView>(value)) {
        if (!validateArrayBufferViewForCopy(
                global_object, scope, view, "Response body stream chunk is detached or out of bounds"_s))
            return consumeExceptionStatus(owner, scope, out_exception);
        auto bytes = arrayBufferViewBytes(view);
        out_chunk->bytes = { bytes.empty() ? nullptr : bytes.data(), bytes.size() };
        return COLLO_STATUS_OK;
    }
    if (auto* array_buffer = dynamicDowncast<JSC::JSArrayBuffer>(value)) {
        if (!validateArrayBufferForCopy(global_object, scope, array_buffer,
                "Response body stream chunk must be a fixed-length attached ArrayBuffer"_s))
            return consumeExceptionStatus(owner, scope, out_exception);
        auto bytes = arrayBufferBytes(array_buffer);
        out_chunk->bytes = { bytes.empty() ? nullptr : bytes.data(), bytes.size() };
        return COLLO_STATUS_OK;
    }
    if (value.isString()) {
        WTF::String text = value.toWTFString(global_object);
        if (auto status = consumeExceptionStatus(owner, scope, out_exception); status != COLLO_STATUS_OK)
            return status;
        std::unique_ptr<ColloOwnedByteSegments> encoded { new (std::nothrow) ColloOwnedByteSegments };
        if (!encoded)
            return COLLO_STATUS_OUT_OF_MEMORY;
        if (!appendStringBytes(global_object, scope, encoded->owned_bytes, text))
            return statusOr(consumeExceptionStatus(owner, scope, out_exception), COLLO_STATUS_OUT_OF_MEMORY);
        out_chunk->bytes = { encoded->owned_bytes.isEmpty() ? nullptr : encoded->owned_bytes.span().data(),
            encoded->owned_bytes.size() };
        out_chunk->owner = encoded.release();
        return COLLO_STATUS_OK;
    }

    JSC::throwVMTypeError(global_object, scope, chunk_type_message);
    return consumeExceptionStatus(owner, scope, out_exception);
}

extern "C" ColloStatus collo_response_body_stream_cancel(
    ColloResponseBodyStream* body_stream, ColloResponseBodyStreamCancel reason, ColloValue** out_exception)
{
    Collo::clearOutException(out_exception);
    if (!bodyStreamIsUsable(body_stream) || !cancelReasonIsDefined(reason))
        return COLLO_STATUS_INVALID_ARGUMENT;

    ColloVm* owner = body_stream->owner;
    JSC::JSLockHolder locker(*owner->vm);
    auto scope = DECLARE_THROW_SCOPE(*owner->vm);
    auto* stream = lockedStream(*body_stream);
    if (!stream)
        return COLLO_STATUS_INVALID_ARGUMENT;
    auto* global_object = stream->globalObject();
    auto* reason_value = createCancelReason(global_object, reason);
    if (auto status = consumeExceptionStatus(owner, scope, out_exception); status != COLLO_STATUS_OK)
        return status;
    if (!reason_value)
        return COLLO_STATUS_OUT_OF_MEMORY;

    JSValue cancel_value = JSValue::decode(stream->cancel(global_object, scope, reason_value));
    if (auto status = consumeExceptionStatus(owner, scope, out_exception); status != COLLO_STATUS_OK)
        return status;
    // No script holds this promise, so its rejection, as when the tenant's cancel algorithm throws, is nobody's to
    // handle.
    if (auto* cancel_promise = dynamicDowncast<JSC::JSPromise>(cancel_value))
        cancel_promise->markAsHandled();
    return COLLO_STATUS_OK;
}

extern "C" void collo_response_body_stream_destroy(ColloResponseBodyStream* body_stream) { delete body_stream; }

} // namespace Collo::HostFunctions
