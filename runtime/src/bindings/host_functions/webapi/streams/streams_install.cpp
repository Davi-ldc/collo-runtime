// Installs the stream classes of this directory on the global object
// (constructors, prototypes and structures), defines the script-facing methods
// of ReadableStream, its default reader, its controllers and its async
// iterator, and implements the helpers readable_stream.h exports except the two
// native-source factories, createReadableStreamNativeSourceFromBytes and
// createReadableStreamNativeSourceFromSharedBytes, which stream_common.cpp
// defines. TextEncoderStream and TextDecoderStream are installed by
// text_codec.cpp. Runs on the VM thread.
//
// Installation runs once per VM, when collo_vm_create installs the Web APIs; a
// worker's VM was created and installed in the zygote before the fork. The
// structures and functions cached on the global object and in ColloWebApiCache
// live until destroyVmContents.
#include "host_functions/webapi/streams/compression_stream_private.h"
#include "host_functions/webapi/streams/pipe_transform_stream_private.h"
#include "host_functions/webapi/streams/queuing_strategy_private.h"
#include "host_functions/webapi/streams/readable_stream_consume.h"

#include <JavaScriptCore/AsyncIteratorPrototype.h>

namespace Collo::HostFunctions {
namespace {

    JSC_DEFINE_HOST_FUNCTION(defaultControllerConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        return JSC::throwVMTypeError(
            global_object, scope, "ReadableStreamDefaultController constructor is not public"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(
        defaultControllerConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        return JSC::throwVMTypeError(
            global_object, scope, "ReadableStreamDefaultController constructor is not public"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(byteControllerConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        return JSC::throwVMTypeError(global_object, scope, "ReadableByteStreamController constructor is not public"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(byteControllerConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        return JSC::throwVMTypeError(global_object, scope, "ReadableByteStreamController constructor is not public"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(byteControllerEnqueue, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* controller = requireReadableByteStreamController(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* stream = controller->stream();
        if (!stream)
            return JSValue::encode(JSC::jsUndefined());
        auto* view = requireArrayBufferView(global_object, scope, call_frame->argument(0), "chunk"_s);
        RETURN_IF_EXCEPTION(scope, {});
        stream->enqueueByteChunk(global_object, scope, view);
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(byteControllerClose, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* controller = requireReadableByteStreamController(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* stream = controller->stream();
        if (!stream)
            return JSValue::encode(JSC::jsUndefined());
        if (stream->state() != StreamState::Readable || controller->closeRequested()) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream is not readable"_s);
            return {};
        }
        if (stream->firstByobReadRequestHasPartialElement()) {
            // ReadableByteStreamControllerClose: closing with a partially
            // filled BYOB element errors the stream and throws the same
            // TypeError to the caller.
            auto* error
                = JSC::createTypeError(global_object, "ReadableStream closed with a partially filled BYOB element"_s);
            stream->error(global_object, error);
            return JSValue::encode(JSC::throwException(global_object, scope, error));
        }
        if (stream->hasPendingReadRequests()) {
            stream->close(global_object);
            return JSValue::encode(JSC::jsUndefined());
        }
        controller->setCloseRequested(true);
        if (stream->hasPendingByobReadRequests())
            return JSValue::encode(JSC::jsUndefined());
        stream->close(global_object);
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(byteControllerError, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* controller = requireReadableByteStreamController(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (auto* stream = controller->stream())
            stream->error(global_object, call_frame->argument(0));
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(
        byteControllerDesiredSize, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* controller = requireReadableByteStreamController(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* stream = controller->stream();
        if (!stream || stream->state() == StreamState::Errored)
            return JSValue::encode(JSC::jsNull());
        if (stream->state() == StreamState::Closed)
            return JSValue::encode(JSC::jsNumber(0));
        return JSValue::encode(JSC::jsNumber(stream->desiredSize()));
    }

    JSC_DEFINE_HOST_FUNCTION(
        byteControllerByobRequest, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* controller = requireReadableByteStreamController(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (auto* request = controller->byobRequest())
            return JSValue::encode(request);
        return JSValue::encode(JSC::jsNull());
    }

    JSC_DEFINE_HOST_FUNCTION(readableStreamGetReader, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireReadableStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        bool wants_byob = false;
        JSValue options = call_frame->argument(0);
        if (!options.isUndefined() && !options.isNull() && !options.isObject()) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream getReader options must be an object"_s);
            return {};
        }
        if (options.isObject()) {
            JSValue mode
                = options.getObject()->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "mode"_s));
            RETURN_IF_EXCEPTION(scope, {});
            if (!mode.isEmpty() && !mode.isUndefined()) {
                WTF::String mode_string = mode.toWTFString(global_object);
                RETURN_IF_EXCEPTION(scope, {});
                if (mode_string == "byob"_s) {
                    wants_byob = true;
                } else {
                    JSC::throwVMTypeError(global_object, scope, "ReadableStream reader mode is not supported"_s);
                    return {};
                }
            }
        }
        if (stream->locked()) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream is already locked"_s);
            return {};
        }
        if (wants_byob) {
            if (!stream->isByteStream()) {
                JSC::throwVMTypeError(global_object, scope, "ReadableStream is not a byte stream"_s);
                return {};
            }
            auto* default_reader = JSColloReadableStreamDefaultReader::create(vm, global_object, stream);
            RETURN_IF_EXCEPTION(scope, {});
            if (!default_reader)
                return {};
            stream->lock(vm, default_reader);
            auto* reader = JSColloReadableStreamBYOBReader::create(vm, global_object, stream, default_reader);
            return JSValue::encode(reader);
        }
        auto* reader = JSColloReadableStreamDefaultReader::create(vm, global_object, stream);
        RETURN_IF_EXCEPTION(scope, {});
        if (!reader)
            return {};
        stream->lock(vm, reader);
        return JSValue::encode(reader);
    }

    JSC_DEFINE_HOST_FUNCTION(readableStreamCancel, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireReadableStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (stream->locked())
            return rejectedTypeError(global_object, scope, "ReadableStream is locked"_s);
        return stream->cancel(global_object, scope, call_frame->argument(0));
    }

    JSC_DEFINE_HOST_FUNCTION(readableStreamBlob, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireReadableStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return consumeReadableStreamBodyWithNativeFastPath(
            global_object, scope, stream, ReadableStreamBodyConsumer::Blob, WTF::emptyString());
    }

    JSC_DEFINE_HOST_FUNCTION(readableStreamBytes, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireReadableStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return consumeReadableStreamBodyWithNativeFastPath(
            global_object, scope, stream, ReadableStreamBodyConsumer::Bytes, WTF::emptyString());
    }

    JSC_DEFINE_HOST_FUNCTION(readableStreamJson, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireReadableStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return consumeReadableStreamBodyWithNativeFastPath(
            global_object, scope, stream, ReadableStreamBodyConsumer::Json, WTF::emptyString());
    }

    JSC_DEFINE_HOST_FUNCTION(readableStreamText, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireReadableStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return consumeReadableStreamBodyWithNativeFastPath(
            global_object, scope, stream, ReadableStreamBodyConsumer::Text, WTF::emptyString());
    }

    JSC_DEFINE_HOST_FUNCTION(readableStreamPipeTo, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* source = requireReadableStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* destination = requireWritableStream(global_object, scope, call_frame->argument(0));
        RETURN_IF_EXCEPTION(scope, {});
        return startReadablePipeTo(global_object, scope, source, destination, call_frame->argument(1), true);
    }

    JSC_DEFINE_HOST_FUNCTION(
        readableStreamPipeThrough, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* source = requireReadableStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        JSValue transform = call_frame->argument(0);
        if (!transform.isObject()) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream pipeThrough transform must be an object"_s);
            return {};
        }
        auto* transform_object = transform.getObject();
        JSValue writable_value
            = transform_object->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "writable"_s));
        RETURN_IF_EXCEPTION(scope, {});
        JSValue readable_value
            = transform_object->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "readable"_s));
        RETURN_IF_EXCEPTION(scope, {});
        auto* writable = requireWritableStream(global_object, scope, writable_value);
        RETURN_IF_EXCEPTION(scope, {});
        auto* readable = requireReadableStream(global_object, scope, readable_value);
        RETURN_IF_EXCEPTION(scope, {});
        JSValue pipe_promise = JSValue::decode(
            startReadablePipeTo(global_object, scope, source, writable, call_frame->argument(1), false));
        RETURN_IF_EXCEPTION(scope, {});
        // pipeThrough marks the pipe's promise as handled; this no-op rejection
        // handler does that, so a failed pipe reports no unhandled rejection.
        if (auto* promise = dynamicDowncast<JSC::JSPromise>(pipe_promise)) {
            auto* rejected = JSC::JSFunction::create(vm, global_object, 1, "ReadableStream pipeThrough rejected"_s,
                resolveUndefinedCallback, JSC::ImplementationVisibility::Public);
            promise->performPromiseThen(vm, global_object, JSC::jsUndefined(), rejected, JSC::jsUndefined());
            RETURN_IF_EXCEPTION(scope, {});
        }
        return JSValue::encode(readable);
    }

    JSC_DEFINE_HOST_FUNCTION(readableStreamTee, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireReadableStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (stream->locked()) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream is already locked"_s);
            return {};
        }

        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        JSColloReadableStream* branch_a = nullptr;
        JSColloReadableStream* branch_b = nullptr;
        bool needs_default_tee_pump = false;

        if (stream->hasNativeSource()) {
            WTF::RefPtr<ReadableStreamNativeSource> source_a;
            WTF::RefPtr<ReadableStreamNativeSource> source_b;
            if (!stream->teeNativeInto(global_object, scope, source_a, source_b))
                return {};
            RETURN_IF_EXCEPTION(scope, {});
            if (!source_a || !source_b) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return {};
            }
            branch_a = JSColloReadableStream::createWithNativeSource(vm, collo_global, source_a.releaseNonNull());
            branch_b = JSColloReadableStream::createWithNativeSource(vm, collo_global, source_b.releaseNonNull());
            branch_a->setByteStream(true);
            branch_b->setByteStream(true);
        } else {
            branch_a = JSColloReadableStream::create(vm, collo_global);
            branch_b = JSColloReadableStream::create(vm, collo_global);
            if (stream->isByteStream()) {
                branch_a->setByteStream(true);
                branch_b->setByteStream(true);
                auto* controller_a = JSColloReadableByteStreamController::create(vm, global_object, branch_a);
                auto* controller_b = JSColloReadableByteStreamController::create(vm, global_object, branch_b);
                branch_a->setByteController(vm, controller_a);
                branch_b->setByteController(vm, controller_b);
            } else {
                auto* controller_a = JSColloReadableStreamDefaultController::create(vm, global_object, branch_a);
                auto* controller_b = JSColloReadableStreamDefaultController::create(vm, global_object, branch_b);
                branch_a->setController(vm, controller_a);
                branch_b->setController(vm, controller_b);
            }
            needs_default_tee_pump = true;
        }

        auto* reader = JSColloReadableStreamDefaultReader::create(vm, global_object, stream);
        RETURN_IF_EXCEPTION(scope, {});
        if (!reader)
            return {};
        stream->lock(vm, reader);
        if (needs_default_tee_pump) {
            auto* tee_state = createDefaultTeeState(global_object, stream, branch_a, branch_b);
            branch_a->setDefaultTeeState(vm, tee_state);
            branch_b->setDefaultTeeState(vm, tee_state);
            startDefaultTeePump(global_object, tee_state);
        }

        auto* array = JSC::constructEmptyArray(global_object, nullptr, 2);
        array->putDirectIndex(global_object, 0, branch_a);
        array->putDirectIndex(global_object, 1, branch_b);
        return JSValue::encode(array);
    }

    JSC_DEFINE_HOST_FUNCTION(readableStreamValues, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireReadableStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (stream->locked()) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream is already locked"_s);
            return {};
        }
        bool prevent_cancel = false;
        JSValue options = call_frame->argument(0);
        if (options.isObject()) {
            JSValue value = options.getObject()->getIfPropertyExists(
                global_object, JSC::Identifier::fromString(vm, "preventCancel"_s));
            RETURN_IF_EXCEPTION(scope, {});
            if (!value.isEmpty() && !value.isUndefined()) {
                prevent_cancel = value.toBoolean(global_object);
                RETURN_IF_EXCEPTION(scope, {});
            }
        }
        auto* reader = JSColloReadableStreamDefaultReader::create(vm, global_object, stream);
        RETURN_IF_EXCEPTION(scope, {});
        if (!reader)
            return {};
        stream->lock(vm, reader);
        return JSValue::encode(JSColloReadableStreamAsyncIterator::create(
            vm, uncheckedDowncast<Collo::GlobalObject>(global_object), reader, prevent_cancel));
    }

    JSC_DEFINE_HOST_FUNCTION(readableStreamGetLocked, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireReadableStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsBoolean(stream->locked()));
    }

    JSC_DEFINE_HOST_FUNCTION(readerRead, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* reader = requireReadableStreamDefaultReader(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* stream = reader->stream();
        if (!stream)
            return rejectedTypeError(global_object, scope, "ReadableStreamDefaultReader has been released"_s);
        return stream->read(global_object, scope);
    }

    JSC_DEFINE_HOST_FUNCTION(readerCancel, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* reader = requireReadableStreamDefaultReader(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* stream = reader->stream();
        if (!stream)
            return rejectedTypeError(global_object, scope, "ReadableStreamDefaultReader has been released"_s);
        return stream->cancel(global_object, scope, call_frame->argument(0));
    }

    JSC_DEFINE_HOST_FUNCTION(readerReleaseLock, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* reader = requireReadableStreamDefaultReader(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        reader->release(global_object);
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(readerClosed, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* reader = requireReadableStreamDefaultReader(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(reader->closedPromise());
    }

    JSC_DEFINE_HOST_FUNCTION(controllerEnqueue, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* controller = requireReadableStreamDefaultController(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* stream = controller->stream();
        if (!stream)
            return JSValue::encode(JSC::jsUndefined());
        if (!stream->enqueue(global_object, scope, call_frame->argument(0)))
            return {};
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(controllerClose, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* controller = requireReadableStreamDefaultController(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (auto* stream = controller->stream()) {
            if (stream->state() != StreamState::Readable || controller->closeRequested()) {
                JSC::throwVMTypeError(global_object, scope, "ReadableStream controller cannot close this stream"_s);
                return {};
            }
            stream->close(global_object);
        }
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(controllerError, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* controller = requireReadableStreamDefaultController(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (auto* stream = controller->stream())
            stream->error(global_object, call_frame->argument(0));
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(controllerDesiredSize, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* controller = requireReadableStreamDefaultController(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* stream = controller->stream();
        if (!stream)
            return JSValue::encode(JSC::jsNull());
        if (stream->state() == StreamState::Closed)
            return JSValue::encode(JSC::jsNumber(0));
        if (stream->state() == StreamState::Errored)
            return JSValue::encode(JSC::jsNull());
        return JSValue::encode(JSC::jsNumber(stream->desiredSize()));
    }

    static void releaseIteratorReader(JSC::JSGlobalObject* global_object, JSColloReadableStreamAsyncIterator* iterator)
    {
        if (auto* reader = iterator->reader()) {
            reader->release(global_object);
            iterator->clearReader();
        }
    }

    JSC_DEFINE_HOST_FUNCTION(iteratorNextFulfilled, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* function = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee());
        JSValue iterator_value = function->get(global_object, readableStreamIteratorIdentifier(global_object));
        RETURN_IF_EXCEPTION(scope, {});
        auto* iterator = requireReadableStreamAsyncIterator(global_object, scope, iterator_value);
        RETURN_IF_EXCEPTION(scope, {});

        bool done = false;
        JSValue error;
        JSValue result = call_frame->argument(0);
        if (!readResultDone(global_object, result, done, error)) {
            releaseIteratorReader(global_object, iterator);
            return JSValue::encode(JSC::throwException(global_object, scope, error));
        }
        if (done)
            releaseIteratorReader(global_object, iterator);
        return JSValue::encode(result);
    }

    JSC_DEFINE_HOST_FUNCTION(iteratorRejectedRelease, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* function = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee());
        JSValue iterator_value = function->get(global_object, readableStreamIteratorIdentifier(global_object));
        RETURN_IF_EXCEPTION(scope, {});
        auto* iterator = requireReadableStreamAsyncIterator(global_object, scope, iterator_value);
        RETURN_IF_EXCEPTION(scope, {});
        releaseIteratorReader(global_object, iterator);
        return JSValue::encode(JSC::throwException(global_object, scope, call_frame->argument(0)));
    }

} // namespace

JSC::JSFunction* JSColloReadableStreamAsyncIterator::nextFulfilledFunction(JSC::JSGlobalObject* global_object)
{
    return cachedThenCallback(global_object, m_next_fulfilled, this, "ReadableStream async iterator fulfilled"_s,
        iteratorNextFulfilled, readableStreamIteratorIdentifier(global_object), this);
}

JSC::JSFunction* JSColloReadableStreamAsyncIterator::nextRejectedFunction(JSC::JSGlobalObject* global_object)
{
    return cachedThenCallback(global_object, m_next_rejected, this, "ReadableStream async iterator rejected"_s,
        iteratorRejectedRelease, readableStreamIteratorIdentifier(global_object), this);
}

namespace {

    JSC_DEFINE_HOST_FUNCTION(iteratorReturnFulfilled, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* function = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee());
        JSValue iterator_value = function->get(global_object, readableStreamIteratorIdentifier(global_object));
        RETURN_IF_EXCEPTION(scope, {});
        JSValue pending_value
            = function->get(global_object, readableStreamIteratorReturnPendingIdentifier(global_object));
        RETURN_IF_EXCEPTION(scope, {});
        auto* iterator = requireReadableStreamAsyncIterator(global_object, scope, iterator_value);
        RETURN_IF_EXCEPTION(scope, {});
        if (auto* pending = dynamicDowncast<JSC::JSPromise>(pending_value))
            iterator->clearReturnPendingIfCurrent(pending);
        JSValue value = function->get(global_object, readableStreamIteratorReturnValueIdentifier(global_object));
        RETURN_IF_EXCEPTION(scope, {});
        if (!value)
            value = JSC::jsUndefined();
        return JSValue::encode(createReadResult(global_object, value, true));
    }

    JSC_DEFINE_HOST_FUNCTION(iteratorReturnRejected, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* function = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee());
        JSValue iterator_value = function->get(global_object, readableStreamIteratorIdentifier(global_object));
        RETURN_IF_EXCEPTION(scope, {});
        JSValue pending_value
            = function->get(global_object, readableStreamIteratorReturnPendingIdentifier(global_object));
        RETURN_IF_EXCEPTION(scope, {});
        auto* iterator = requireReadableStreamAsyncIterator(global_object, scope, iterator_value);
        RETURN_IF_EXCEPTION(scope, {});
        if (auto* pending = dynamicDowncast<JSC::JSPromise>(pending_value))
            iterator->clearReturnPendingIfCurrent(pending);
        return JSValue::encode(JSC::throwException(global_object, scope, call_frame->argument(0)));
    }

    static JSC::JSPromise* createIteratorDoneAfterPromise(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        JSColloReadableStreamAsyncIterator* iterator, JSC::JSPromise* dependency, JSValue value)
    {
        auto& vm = global_object->vm();
        auto* result_promise = JSC::JSPromise::create(vm, global_object->promiseStructure());
        auto* fulfilled
            = JSC::JSFunction::create(vm, global_object, 1, "ReadableStream async iterator return fulfilled"_s,
                iteratorReturnFulfilled, JSC::ImplementationVisibility::Public);
        fulfilled->putDirect(vm, readableStreamIteratorIdentifier(global_object), iterator,
            static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
        fulfilled->putDirect(vm, readableStreamIteratorReturnValueIdentifier(global_object), value,
            static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
        auto* rejected
            = JSC::JSFunction::create(vm, global_object, 1, "ReadableStream async iterator return rejected"_s,
                iteratorReturnRejected, JSC::ImplementationVisibility::Public);
        rejected->putDirect(vm, readableStreamIteratorIdentifier(global_object), iterator,
            static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
        fulfilled->putDirect(vm, readableStreamIteratorReturnPendingIdentifier(global_object), result_promise,
            static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
        rejected->putDirect(vm, readableStreamIteratorReturnPendingIdentifier(global_object), result_promise,
            static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
        dependency->performPromiseThen(vm, global_object, fulfilled, rejected, result_promise);
        RETURN_IF_EXCEPTION(scope, nullptr);
        return result_promise;
    }

    JSC_DEFINE_HOST_FUNCTION(iteratorNext, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* iterator = requireReadableStreamAsyncIterator(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* reader = iterator->reader();
        if (!reader) {
            if (auto* pending = iterator->returnPending()) {
                auto* chained
                    = createIteratorDoneAfterPromise(global_object, scope, iterator, pending, JSC::jsUndefined());
                RETURN_IF_EXCEPTION(scope, {});
                if (!chained)
                    return {};
                return JSValue::encode(chained);
            }
            return resolvedReadResult(global_object, JSC::jsUndefined(), true);
        }
        auto* stream = reader->stream();
        if (!stream)
            return resolvedReadResult(global_object, JSC::jsUndefined(), true);

        JSValue read_value = JSValue::decode(stream->read(global_object, scope));
        RETURN_IF_EXCEPTION(scope, {});
        auto* read_promise = dynamicDowncast<JSC::JSPromise>(read_value);
        if (!read_promise)
            return JSValue::encode(read_value);

        auto* result_promise = JSC::JSPromise::create(vm, global_object->promiseStructure());
        read_promise->performPromiseThen(vm, global_object, iterator->nextFulfilledFunction(global_object),
            iterator->nextRejectedFunction(global_object), result_promise);
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(result_promise);
    }

    JSC_DEFINE_HOST_FUNCTION(iteratorReturn, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* iterator = requireReadableStreamAsyncIterator(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        JSValue return_value = call_frame->argument(0);
        auto* reader = iterator->reader();
        if (!reader) {
            if (auto* pending = iterator->returnPending()) {
                auto* chained = createIteratorDoneAfterPromise(global_object, scope, iterator, pending, return_value);
                RETURN_IF_EXCEPTION(scope, {});
                if (!chained)
                    return {};
                iterator->setReturnPending(vm, chained);
                return JSValue::encode(chained);
            }
            return resolvedReadResult(global_object, return_value, true);
        }
        if (reader) {
            JSValue cancel_result = JSC::jsUndefined();
            if (!iterator->preventCancel()) {
                if (auto* stream = reader->stream())
                    cancel_result = JSValue::decode(stream->cancel(global_object, scope, return_value));
                RETURN_IF_EXCEPTION(scope, {});
            }
            reader->release(global_object);
            iterator->clearReader();
            if (auto* cancel_promise = dynamicDowncast<JSC::JSPromise>(cancel_result)) {
                auto* result_promise
                    = createIteratorDoneAfterPromise(global_object, scope, iterator, cancel_promise, return_value);
                RETURN_IF_EXCEPTION(scope, {});
                if (!result_promise)
                    return {};
                iterator->setReturnPending(vm, result_promise);
                return JSValue::encode(result_promise);
            }
        }
        return resolvedReadResult(global_object, return_value, true);
    }

    JSC_DEFINE_HOST_FUNCTION(iteratorAsyncIterator, (JSC::JSGlobalObject*, JSC::CallFrame* call_frame))
    {
        return JSValue::encode(call_frame->thisValue());
    }

} // namespace

JSC::JSObject* createReadableStreamReadResult(JSC::JSGlobalObject* global_object, JSValue value, bool done)
{
    return createReadResult(global_object, value, done);
}

JSC::JSObject* readableStreamFromValue(JSC::JSValue value)
{
    if (!value || !value.isObject())
        return nullptr;
    return dynamicDowncast<JSColloReadableStream>(value);
}

bool readableStreamIsDisturbed(JSC::JSObject* stream)
{
    auto* readable_stream = dynamicDowncast<JSColloReadableStream>(stream);
    return readable_stream && readable_stream->disturbed();
}

bool readableStreamIsLocked(JSC::JSObject* stream)
{
    auto* readable_stream = dynamicDowncast<JSColloReadableStream>(stream);
    return readable_stream && readable_stream->locked();
}

ReadableStreamDrainResult readableStreamDrainNativeBytes(
    JSC::JSGlobalObject*, JSC::JSObject* stream, WTF::Vector<uint8_t>& out, size_t max_size)
{
    auto* readable_stream = dynamicDowncast<JSColloReadableStream>(stream);
    if (!readable_stream)
        return ReadableStreamDrainResult::NotAvailable;
    return readable_stream->drainNativeBytes(out, max_size);
}

JSC::JSObject* createReadableStreamFromNativeSource(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope&, WTF::Ref<ReadableStreamNativeSource>&& source)
{
    auto* stream = JSColloReadableStream::createWithNativeSource(
        global_object->vm(), uncheckedDowncast<Collo::GlobalObject>(global_object), WTF::move(source));
    stream->setByteStream(true);
    return stream;
}

JSC::JSObject* createReadableStreamFromBytes(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const uint8_t> bytes)
{
    auto source = createReadableStreamNativeSourceFromBytes(bytes);
    if (!source) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return nullptr;
    }
    return createReadableStreamFromNativeSource(global_object, scope, source.releaseNonNull());
}

void installWebApiReadableStream(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    // Loads zlib and Brotli during installation, which for a worker's VM runs
    // in the zygote, so no worker needs dlopen (sharedZlibLibrary in
    // compression_stream.cpp).
    preloadCompressionLibraries();

    auto* stream_prototype = JSC::constructEmptyObject(global_object);
    putWebApiFunction(global_object, stream_prototype, vm, "getReader"_s, 0, readableStreamGetReader,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, stream_prototype, vm, "cancel"_s, 1, readableStreamCancel,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, stream_prototype, vm, "blob"_s, 0, readableStreamBlob,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, stream_prototype, vm, "bytes"_s, 0, readableStreamBytes,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, stream_prototype, vm, "json"_s, 0, readableStreamJson,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, stream_prototype, vm, "text"_s, 0, readableStreamText,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, stream_prototype, vm, "pipeTo"_s, 1, readableStreamPipeTo,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, stream_prototype, vm, "pipeThrough"_s, 1, readableStreamPipeThrough,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, stream_prototype, vm, "tee"_s, 0, readableStreamTee,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiAccessor(global_object, stream_prototype, vm, "locked"_s, readableStreamGetLocked, nullptr,
        static_cast<unsigned>(JSC::PropertyAttribute::Accessor));
    auto* stream_values_function = JSC::JSFunction::create(
        vm, global_object, 0, "values"_s, readableStreamValues, JSC::ImplementationVisibility::Public);
    stream_prototype->putDirect(vm, JSC::Identifier::fromString(vm, "values"_s), stream_values_function,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    stream_prototype->putDirect(vm, vm.propertyNames->asyncIteratorSymbol, stream_values_function,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    stream_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::makeString("ReadableStream"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* stream_constructor
        = JSC::JSFunction::create(vm, global_object, 0, "ReadableStream"_s, readableStreamConstructorCall,
            JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, readableStreamConstructorConstruct, nullptr);
    stream_constructor->putDirect(vm, vm.propertyNames->prototype, stream_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    putWebApiFunction(global_object, stream_constructor, vm, "from"_s, 1, readableStreamFrom,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    stream_prototype->putDirect(
        vm, vm.propertyNames->constructor, stream_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    auto* reader_prototype = JSC::constructEmptyObject(global_object);
    putWebApiFunction(global_object, reader_prototype, vm, "read"_s, 0, readerRead,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, reader_prototype, vm, "cancel"_s, 1, readerCancel,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, reader_prototype, vm, "releaseLock"_s, 0, readerReleaseLock,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiAccessor(global_object, reader_prototype, vm, "closed"_s, readerClosed, nullptr,
        static_cast<unsigned>(JSC::PropertyAttribute::Accessor));
    reader_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::makeString("ReadableStreamDefaultReader"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* reader_constructor
        = JSC::JSFunction::create(vm, global_object, 1, "ReadableStreamDefaultReader"_s, defaultReaderConstructorCall,
            JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, defaultReaderConstructorConstruct, nullptr);
    reader_constructor->putDirect(vm, vm.propertyNames->prototype, reader_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    reader_prototype->putDirect(
        vm, vm.propertyNames->constructor, reader_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    auto* controller_prototype = JSC::constructEmptyObject(global_object);
    putWebApiFunction(global_object, controller_prototype, vm, "enqueue"_s, 1, controllerEnqueue,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, controller_prototype, vm, "close"_s, 0, controllerClose,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, controller_prototype, vm, "error"_s, 1, controllerError,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiAccessor(global_object, controller_prototype, vm, "desiredSize"_s, controllerDesiredSize, nullptr,
        static_cast<unsigned>(JSC::PropertyAttribute::Accessor));
    controller_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::makeString("ReadableStreamDefaultController"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* controller_constructor = JSC::JSFunction::create(vm, global_object, 0, "ReadableStreamDefaultController"_s,
        defaultControllerConstructorCall, JSC::ImplementationVisibility::Public, JSC::NoIntrinsic,
        defaultControllerConstructorConstruct, nullptr);
    controller_constructor->putDirect(vm, vm.propertyNames->prototype, controller_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    controller_prototype->putDirect(vm, vm.propertyNames->constructor, controller_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    auto* byob_reader_prototype = JSC::constructEmptyObject(global_object);
    putWebApiFunction(global_object, byob_reader_prototype, vm, "read"_s, 1, byobReaderRead,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, byob_reader_prototype, vm, "cancel"_s, 1, byobReaderCancel,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, byob_reader_prototype, vm, "releaseLock"_s, 0, byobReaderReleaseLock,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiAccessor(global_object, byob_reader_prototype, vm, "closed"_s, byobReaderClosed, nullptr,
        static_cast<unsigned>(JSC::PropertyAttribute::Accessor));
    byob_reader_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::makeString("ReadableStreamBYOBReader"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* byob_reader_constructor
        = JSC::JSFunction::create(vm, global_object, 1, "ReadableStreamBYOBReader"_s, byobReaderConstructorCall,
            JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, byobReaderConstructorConstruct, nullptr);
    byob_reader_constructor->putDirect(vm, vm.propertyNames->prototype, byob_reader_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    byob_reader_prototype->putDirect(vm, vm.propertyNames->constructor, byob_reader_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    auto* byob_request_prototype = JSC::constructEmptyObject(global_object);
    putWebApiAccessor(global_object, byob_request_prototype, vm, "view"_s, byobRequestView, nullptr,
        static_cast<unsigned>(JSC::PropertyAttribute::Accessor));
    putWebApiFunction(global_object, byob_request_prototype, vm, "respond"_s, 1, byobRequestRespond,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, byob_request_prototype, vm, "respondWithNewView"_s, 1,
        byobRequestRespondWithNewView, static_cast<unsigned>(JSC::PropertyAttribute::None));
    byob_request_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::makeString("ReadableStreamBYOBRequest"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* byob_request_constructor
        = JSC::JSFunction::create(vm, global_object, 0, "ReadableStreamBYOBRequest"_s, byobRequestConstructorCall,
            JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, byobRequestConstructorConstruct, nullptr);
    byob_request_constructor->putDirect(vm, vm.propertyNames->prototype, byob_request_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    byob_request_prototype->putDirect(vm, vm.propertyNames->constructor, byob_request_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    auto* byte_controller_prototype = JSC::constructEmptyObject(global_object);
    putWebApiFunction(global_object, byte_controller_prototype, vm, "enqueue"_s, 1, byteControllerEnqueue,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, byte_controller_prototype, vm, "close"_s, 0, byteControllerClose,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, byte_controller_prototype, vm, "error"_s, 1, byteControllerError,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiAccessor(global_object, byte_controller_prototype, vm, "desiredSize"_s, byteControllerDesiredSize, nullptr,
        static_cast<unsigned>(JSC::PropertyAttribute::Accessor));
    putWebApiAccessor(global_object, byte_controller_prototype, vm, "byobRequest"_s, byteControllerByobRequest, nullptr,
        static_cast<unsigned>(JSC::PropertyAttribute::Accessor));
    byte_controller_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::makeString("ReadableByteStreamController"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* byte_controller_constructor
        = JSC::JSFunction::create(vm, global_object, 0, "ReadableByteStreamController"_s, byteControllerConstructorCall,
            JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, byteControllerConstructorConstruct, nullptr);
    byte_controller_constructor->putDirect(vm, vm.propertyNames->prototype, byte_controller_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    byte_controller_prototype->putDirect(vm, vm.propertyNames->constructor, byte_controller_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    auto* iterator_prototype = JSC::constructEmptyObject(global_object, global_object->asyncIteratorPrototype());
    putWebApiFunction(global_object, iterator_prototype, vm, "next"_s, 0, iteratorNext,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, iterator_prototype, vm, "return"_s, 1, iteratorReturn,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    auto* iterator_self_function = JSC::JSFunction::create(
        vm, global_object, 0, "[Symbol.asyncIterator]"_s, iteratorAsyncIterator, JSC::ImplementationVisibility::Public);
    iterator_prototype->putDirect(vm, vm.propertyNames->asyncIteratorSymbol, iterator_self_function,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    auto* writable_stream_prototype = JSC::constructEmptyObject(global_object);
    putWebApiFunction(global_object, writable_stream_prototype, vm, "getWriter"_s, 0, writableStreamGetWriter,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, writable_stream_prototype, vm, "abort"_s, 1, writableStreamAbort,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, writable_stream_prototype, vm, "close"_s, 0, writableStreamClose,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiAccessor(global_object, writable_stream_prototype, vm, "locked"_s, writableStreamGetLocked, nullptr,
        static_cast<unsigned>(JSC::PropertyAttribute::Accessor));
    writable_stream_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::makeString("WritableStream"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* writable_stream_constructor
        = JSC::JSFunction::create(vm, global_object, 0, "WritableStream"_s, writableStreamConstructorCall,
            JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, writableStreamConstructorConstruct, nullptr);
    writable_stream_constructor->putDirect(vm, vm.propertyNames->prototype, writable_stream_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    writable_stream_prototype->putDirect(vm, vm.propertyNames->constructor, writable_stream_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    auto* writer_prototype = JSC::constructEmptyObject(global_object);
    putWebApiFunction(global_object, writer_prototype, vm, "write"_s, 1, writerWrite,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, writer_prototype, vm, "close"_s, 0, writerClose,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, writer_prototype, vm, "abort"_s, 1, writerAbort,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, writer_prototype, vm, "releaseLock"_s, 0, writerReleaseLock,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiAccessor(global_object, writer_prototype, vm, "closed"_s, writerClosed, nullptr,
        static_cast<unsigned>(JSC::PropertyAttribute::Accessor));
    putWebApiAccessor(global_object, writer_prototype, vm, "ready"_s, writerReady, nullptr,
        static_cast<unsigned>(JSC::PropertyAttribute::Accessor));
    putWebApiAccessor(global_object, writer_prototype, vm, "desiredSize"_s, writerDesiredSize, nullptr,
        static_cast<unsigned>(JSC::PropertyAttribute::Accessor));
    writer_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::makeString("WritableStreamDefaultWriter"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* writer_constructor
        = JSC::JSFunction::create(vm, global_object, 1, "WritableStreamDefaultWriter"_s, defaultWriterConstructorCall,
            JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, defaultWriterConstructorConstruct, nullptr);
    writer_constructor->putDirect(vm, vm.propertyNames->prototype, writer_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    writer_prototype->putDirect(
        vm, vm.propertyNames->constructor, writer_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    auto* writable_controller_prototype = JSC::constructEmptyObject(global_object);
    putWebApiFunction(global_object, writable_controller_prototype, vm, "error"_s, 1, writableControllerError,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    writable_controller_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::makeString("WritableStreamDefaultController"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* writable_controller_constructor = JSC::JSFunction::create(vm, global_object, 0,
        "WritableStreamDefaultController"_s, defaultWriterControllerCall, JSC::ImplementationVisibility::Public,
        JSC::NoIntrinsic, defaultWriterControllerConstruct, nullptr);
    writable_controller_constructor->putDirect(vm, vm.propertyNames->prototype, writable_controller_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    writable_controller_prototype->putDirect(vm, vm.propertyNames->constructor, writable_controller_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    auto* transform_stream_prototype = JSC::constructEmptyObject(global_object);
    putWebApiAccessor(global_object, transform_stream_prototype, vm, "readable"_s, transformStreamGetReadable, nullptr,
        static_cast<unsigned>(JSC::PropertyAttribute::Accessor));
    putWebApiAccessor(global_object, transform_stream_prototype, vm, "writable"_s, transformStreamGetWritable, nullptr,
        static_cast<unsigned>(JSC::PropertyAttribute::Accessor));
    transform_stream_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::makeString("TransformStream"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* transform_stream_constructor
        = JSC::JSFunction::create(vm, global_object, 0, "TransformStream"_s, transformStreamConstructorCall,
            JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, transformStreamConstructorConstruct, nullptr);
    transform_stream_constructor->putDirect(vm, vm.propertyNames->prototype, transform_stream_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    transform_stream_prototype->putDirect(vm, vm.propertyNames->constructor, transform_stream_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    auto* transform_controller_prototype = JSC::constructEmptyObject(global_object);
    putWebApiFunction(global_object, transform_controller_prototype, vm, "enqueue"_s, 1, transformControllerEnqueue,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, transform_controller_prototype, vm, "error"_s, 1, transformControllerError,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiFunction(global_object, transform_controller_prototype, vm, "terminate"_s, 0, transformControllerTerminate,
        static_cast<unsigned>(JSC::PropertyAttribute::None));
    putWebApiAccessor(global_object, transform_controller_prototype, vm, "desiredSize"_s,
        transformControllerDesiredSize, nullptr, static_cast<unsigned>(JSC::PropertyAttribute::Accessor));
    transform_controller_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::makeString("TransformStreamDefaultController"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* transform_controller_constructor = JSC::JSFunction::create(vm, global_object, 0,
        "TransformStreamDefaultController"_s, transformControllerConstructorCall, JSC::ImplementationVisibility::Public,
        JSC::NoIntrinsic, transformControllerConstructorConstruct, nullptr);
    transform_controller_constructor->putDirect(vm, vm.propertyNames->prototype, transform_controller_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    transform_controller_prototype->putDirect(vm, vm.propertyNames->constructor, transform_controller_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    auto* compression_stream_prototype = JSC::constructEmptyObject(global_object);
    putWebApiAccessor(global_object, compression_stream_prototype, vm, "readable"_s, compressionStreamGetReadable,
        nullptr, static_cast<unsigned>(JSC::PropertyAttribute::Accessor));
    putWebApiAccessor(global_object, compression_stream_prototype, vm, "writable"_s, compressionStreamGetWritable,
        nullptr, static_cast<unsigned>(JSC::PropertyAttribute::Accessor));
    compression_stream_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::makeString("CompressionStream"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* compression_stream_constructor
        = JSC::JSFunction::create(vm, global_object, 1, "CompressionStream"_s, compressionStreamConstructorCall,
            JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, compressionStreamConstructorConstruct, nullptr);
    compression_stream_constructor->putDirect(vm, vm.propertyNames->prototype, compression_stream_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    compression_stream_prototype->putDirect(vm, vm.propertyNames->constructor, compression_stream_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    auto* decompression_stream_prototype = JSC::constructEmptyObject(global_object);
    putWebApiAccessor(global_object, decompression_stream_prototype, vm, "readable"_s, decompressionStreamGetReadable,
        nullptr, static_cast<unsigned>(JSC::PropertyAttribute::Accessor));
    putWebApiAccessor(global_object, decompression_stream_prototype, vm, "writable"_s, decompressionStreamGetWritable,
        nullptr, static_cast<unsigned>(JSC::PropertyAttribute::Accessor));
    decompression_stream_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::makeString("DecompressionStream"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* decompression_stream_constructor
        = JSC::JSFunction::create(vm, global_object, 1, "DecompressionStream"_s, decompressionStreamConstructorCall,
            JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, decompressionStreamConstructorConstruct, nullptr);
    decompression_stream_constructor->putDirect(vm, vm.propertyNames->prototype, decompression_stream_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    decompression_stream_prototype->putDirect(vm, vm.propertyNames->constructor, decompression_stream_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    auto* byte_length_strategy_prototype = JSC::constructEmptyObject(global_object);
    putWebApiAccessor(global_object, byte_length_strategy_prototype, vm, "highWaterMark"_s,
        byteLengthQueuingStrategyHighWaterMark, nullptr, static_cast<unsigned>(JSC::PropertyAttribute::Accessor));
    auto* byte_length_size_function = JSC::JSFunction::create(
        vm, global_object, 1, "size"_s, byteLengthQueuingStrategySize, JSC::ImplementationVisibility::Public);
    global_object->owner().webapi_cache.byte_length_queuing_strategy_size_function.set(vm, byte_length_size_function);
    // The strategies' IDL declares size as a readonly attribute, so it is an
    // accessor whose getter returns the cached function above.
    putWebApiAccessor(global_object, byte_length_strategy_prototype, vm, "size"_s, byteLengthQueuingStrategySizeGetter,
        nullptr, static_cast<unsigned>(JSC::PropertyAttribute::Accessor));
    byte_length_strategy_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::makeString("ByteLengthQueuingStrategy"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* byte_length_strategy_constructor = JSC::JSFunction::create(vm, global_object, 1,
        "ByteLengthQueuingStrategy"_s, byteLengthQueuingStrategyConstructorCall, JSC::ImplementationVisibility::Public,
        JSC::NoIntrinsic, byteLengthQueuingStrategyConstructorConstruct, nullptr);
    byte_length_strategy_constructor->putDirect(vm, vm.propertyNames->prototype, byte_length_strategy_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    byte_length_strategy_prototype->putDirect(vm, vm.propertyNames->constructor, byte_length_strategy_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    auto* count_strategy_prototype = JSC::constructEmptyObject(global_object);
    putWebApiAccessor(global_object, count_strategy_prototype, vm, "highWaterMark"_s, countQueuingStrategyHighWaterMark,
        nullptr, static_cast<unsigned>(JSC::PropertyAttribute::Accessor));
    auto* count_size_function = JSC::JSFunction::create(
        vm, global_object, 0, "size"_s, countQueuingStrategySize, JSC::ImplementationVisibility::Public);
    global_object->owner().webapi_cache.count_queuing_strategy_size_function.set(vm, count_size_function);
    putWebApiAccessor(global_object, count_strategy_prototype, vm, "size"_s, countQueuingStrategySizeGetter, nullptr,
        static_cast<unsigned>(JSC::PropertyAttribute::Accessor));
    count_strategy_prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol,
        JSC::jsString(vm, WTF::makeString("CountQueuingStrategy"_s)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

    auto* count_strategy_constructor
        = JSC::JSFunction::create(vm, global_object, 1, "CountQueuingStrategy"_s, countQueuingStrategyConstructorCall,
            JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, countQueuingStrategyConstructorConstruct, nullptr);
    count_strategy_constructor->putDirect(vm, vm.propertyNames->prototype, count_strategy_prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    count_strategy_prototype->putDirect(vm, vm.propertyNames->constructor, count_strategy_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    JSC::Identifier stream_identifier = JSC::Identifier::fromString(vm, "ReadableStream"_s);
    JSC::Identifier reader_identifier = JSC::Identifier::fromString(vm, "ReadableStreamDefaultReader"_s);
    JSC::Identifier controller_identifier = JSC::Identifier::fromString(vm, "ReadableStreamDefaultController"_s);
    JSC::Identifier byob_reader_identifier = JSC::Identifier::fromString(vm, "ReadableStreamBYOBReader"_s);
    JSC::Identifier byob_request_identifier = JSC::Identifier::fromString(vm, "ReadableStreamBYOBRequest"_s);
    JSC::Identifier byte_controller_identifier = JSC::Identifier::fromString(vm, "ReadableByteStreamController"_s);
    JSC::Identifier writable_stream_identifier = JSC::Identifier::fromString(vm, "WritableStream"_s);
    JSC::Identifier writer_identifier = JSC::Identifier::fromString(vm, "WritableStreamDefaultWriter"_s);
    JSC::Identifier writable_controller_identifier
        = JSC::Identifier::fromString(vm, "WritableStreamDefaultController"_s);
    JSC::Identifier transform_stream_identifier = JSC::Identifier::fromString(vm, "TransformStream"_s);
    JSC::Identifier transform_controller_identifier
        = JSC::Identifier::fromString(vm, "TransformStreamDefaultController"_s);
    JSC::Identifier compression_stream_identifier = JSC::Identifier::fromString(vm, "CompressionStream"_s);
    JSC::Identifier decompression_stream_identifier = JSC::Identifier::fromString(vm, "DecompressionStream"_s);
    JSC::Identifier byte_length_strategy_identifier = JSC::Identifier::fromString(vm, "ByteLengthQueuingStrategy"_s);
    JSC::Identifier count_strategy_identifier = JSC::Identifier::fromString(vm, "CountQueuingStrategy"_s);
    global_object->putDirect(
        vm, stream_identifier, stream_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    global_object->putDirect(
        vm, reader_identifier, reader_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    global_object->putDirect(
        vm, controller_identifier, controller_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    global_object->putDirect(
        vm, byob_reader_identifier, byob_reader_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    global_object->putDirect(
        vm, byob_request_identifier, byob_request_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    global_object->putDirect(vm, byte_controller_identifier, byte_controller_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    global_object->putDirect(vm, writable_stream_identifier, writable_stream_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    global_object->putDirect(
        vm, writer_identifier, writer_constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    global_object->putDirect(vm, writable_controller_identifier, writable_controller_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    global_object->putDirect(vm, transform_stream_identifier, transform_stream_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    global_object->putDirect(vm, transform_controller_identifier, transform_controller_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    global_object->putDirect(vm, compression_stream_identifier, compression_stream_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    global_object->putDirect(vm, decompression_stream_identifier, decompression_stream_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    global_object->putDirect(vm, byte_length_strategy_identifier, byte_length_strategy_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    global_object->putDirect(vm, count_strategy_identifier, count_strategy_constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));

    global_object->cacheReadableStreamApi(stream_constructor, stream_prototype,
        JSColloReadableStream::createStructure(vm, global_object, stream_prototype), reader_constructor,
        reader_prototype, JSColloReadableStreamDefaultReader::createStructure(vm, global_object, reader_prototype),
        controller_constructor, controller_prototype,
        JSColloReadableStreamDefaultController::createStructure(vm, global_object, controller_prototype),
        byob_reader_constructor, byob_reader_prototype,
        JSColloReadableStreamBYOBReader::createStructure(vm, global_object, byob_reader_prototype),
        byob_request_constructor, byob_request_prototype,
        JSColloReadableStreamBYOBRequest::createStructure(vm, global_object, byob_request_prototype),
        byte_controller_constructor, byte_controller_prototype,
        JSColloReadableByteStreamController::createStructure(vm, global_object, byte_controller_prototype),
        iterator_prototype, JSColloReadableStreamAsyncIterator::createStructure(vm, global_object, iterator_prototype));
    global_object->cacheWritableStreamApi(writable_stream_constructor, writable_stream_prototype,
        JSColloWritableStream::createStructure(vm, global_object, writable_stream_prototype), writer_constructor,
        writer_prototype, JSColloWritableStreamDefaultWriter::createStructure(vm, global_object, writer_prototype),
        writable_controller_constructor, writable_controller_prototype,
        JSColloWritableStreamDefaultController::createStructure(vm, global_object, writable_controller_prototype));
    global_object->cacheTransformStreamApi(transform_stream_constructor, transform_stream_prototype,
        JSColloTransformStream::createStructure(vm, global_object, transform_stream_prototype),
        transform_controller_constructor, transform_controller_prototype,
        JSColloTransformStreamDefaultController::createStructure(vm, global_object, transform_controller_prototype));
    global_object->owner().webapi_cache.compression_stream_constructor.set(vm, compression_stream_constructor);
    global_object->owner().webapi_cache.compression_stream_prototype.set(vm, compression_stream_prototype);
    global_object->owner().webapi_cache.compression_stream_structure.set(
        vm, JSColloCompressionStream::createStructure(vm, global_object, compression_stream_prototype));
    global_object->owner().webapi_cache.decompression_stream_constructor.set(vm, decompression_stream_constructor);
    global_object->owner().webapi_cache.decompression_stream_prototype.set(vm, decompression_stream_prototype);
    global_object->owner().webapi_cache.decompression_stream_structure.set(
        vm, JSColloCompressionStream::createStructure(vm, global_object, decompression_stream_prototype));
    global_object->owner().webapi_cache.byte_length_queuing_strategy_constructor.set(
        vm, byte_length_strategy_constructor);
    global_object->owner().webapi_cache.byte_length_queuing_strategy_prototype.set(vm, byte_length_strategy_prototype);
    global_object->owner().webapi_cache.byte_length_queuing_strategy_structure.set(
        vm, JSColloQueuingStrategy::createStructure(vm, global_object, byte_length_strategy_prototype));
    global_object->owner().webapi_cache.count_queuing_strategy_constructor.set(vm, count_strategy_constructor);
    global_object->owner().webapi_cache.count_queuing_strategy_prototype.set(vm, count_strategy_prototype);
    global_object->owner().webapi_cache.count_queuing_strategy_structure.set(
        vm, JSColloQueuingStrategy::createStructure(vm, global_object, count_strategy_prototype));
    global_object->owner().webapi_cache.pipe_to_state_structure.set(
        vm, JSColloPipeToState::createStructure(vm, global_object, global_object->objectPrototype()));
}
} // namespace Collo::HostFunctions
