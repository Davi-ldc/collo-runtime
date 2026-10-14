// The script-facing surface of WritableStream, WritableStreamDefaultWriter and WritableStreamDefaultController:
// argument conversion and receiver checks in front of the state machine in writable_stream.cpp, and the installer
// that defines the three interfaces on a realm. Runs on the VM thread.
//
// A method that returns a promise reports a locked stream or a released writer as a promise rejected with a TypeError;
// getWriter, the writer constructor and the desiredSize getter throw it.

#include "host_functions/webapi/streams/writable_stream_private.h"

namespace Collo::HostFunctions {
namespace {

    JSC_DEFINE_HOST_FUNCTION(writableStreamConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        JSC::JSValue underlying_sink = call_frame->argument(0);
        if (underlying_sink.isUndefined())
            underlying_sink = JSC::constructEmptyObject(global_object);
        if (!underlying_sink.isObject()) {
            JSC::throwVMTypeError(global_object, scope, "WritableStream underlying sink must be an object"_s);
            return {};
        }

        // Web IDL argument conversion reads the strategy dictionary before the constructor steps convert the
        // underlying sink dictionary, whose members are read in lexicographic order: abort, close, start, type, write.
        // A defined type rejects only after the full conversion.
        bool has_high_water_mark = false;
        double high_water_mark = 0;
        JSC::JSValue size_callback = JSC::jsUndefined();
        if (!parseQueuingStrategy(global_object, scope, call_frame->argument(1), "WritableStream"_s,
                has_high_water_mark, high_water_mark, size_callback))
            return {};

        auto* sink_object = underlying_sink.getObject();
        JSC::JSValue abort = JSC::jsUndefined();
        if (!strictCallbackPropertyOrUndefined(
                global_object, scope, sink_object, "abort"_s, "WritableStream abort"_s, abort))
            return {};
        JSC::JSValue close = JSC::jsUndefined();
        if (!strictCallbackPropertyOrUndefined(
                global_object, scope, sink_object, "close"_s, "WritableStream close"_s, close))
            return {};
        JSC::JSValue start = JSC::jsUndefined();
        if (!strictCallbackPropertyOrUndefined(
                global_object, scope, sink_object, "start"_s, "WritableStream start"_s, start))
            return {};
        JSC::JSValue type = sink_object->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "type"_s));
        RETURN_IF_EXCEPTION(scope, {});
        JSC::JSValue write = JSC::jsUndefined();
        if (!strictCallbackPropertyOrUndefined(
                global_object, scope, sink_object, "write"_s, "WritableStream write"_s, write))
            return {};

        if (!type.isEmpty() && !type.isUndefined()) {
            JSC::throwException(global_object, scope,
                JSC::createRangeError(global_object, "WritableStream underlying sink type is invalid"_s));
            return {};
        }
        if (!validateHighWaterMark(global_object, scope, "WritableStream"_s, has_high_water_mark, 1, high_water_mark))
            return {};

        auto* stream_structure = streamStructureForNewTarget(global_object, scope, call_frame,
            uncheckedDowncast<Collo::GlobalObject>(global_object)->writableStreamStructure());
        RETURN_IF_EXCEPTION(scope, {});
        auto* stream = JSColloWritableStream::create(vm, global_object, stream_structure);
        auto* controller = stream->controller();
        controller->setJavaScriptSink(vm, underlying_sink, write, close, abort);
        controller->setSizeCallback(vm, size_callback);
        stream->setHighWaterMark(high_water_mark);

        // SetUpWritableStreamDefaultController: start runs now, and the stream starts once a promise resolved with its
        // result fulfills, however start returned.
        JSC::JSValue start_result = JSC::jsUndefined();
        if (valueIsCallable(start)) {
            JSC::MarkedArgumentBuffer arguments;
            arguments.append(controller);
            if (arguments.hasOverflowed()) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return {};
            }
            auto call_data = JSC::getCallData(start);
            start_result = JSC::call(global_object, start.getObject(), call_data, underlying_sink, arguments);
            RETURN_IF_EXCEPTION(scope, {});
        }
        auto* start_promise = promiseResolvedWith(global_object, start_result);
        RETURN_IF_EXCEPTION(scope, {});
        stream->startWith(global_object, start_promise);
        return JSC::JSValue::encode(stream);
    }

    JSC_DEFINE_HOST_FUNCTION(writableStreamAbort, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireWritableStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (stream->locked())
            return rejectedTypeError(global_object, scope, "WritableStream is locked"_s);
        RELEASE_AND_RETURN(scope, stream->abort(global_object, scope, call_frame->argument(0)));
    }

    JSC_DEFINE_HOST_FUNCTION(writableStreamClose, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireWritableStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (stream->locked())
            return rejectedTypeError(global_object, scope, "WritableStream is locked"_s);
        RELEASE_AND_RETURN(scope, stream->close(global_object, scope));
    }

    JSC::EncodedJSValue createWriter(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value)
    {
        auto* stream = requireWritableStream(global_object, scope, value);
        RETURN_IF_EXCEPTION(scope, {});
        if (stream->locked()) {
            JSC::throwVMTypeError(global_object, scope, "WritableStream is already locked"_s);
            return {};
        }
        auto* writer = JSColloWritableStreamDefaultWriter::create(global_object->vm(), global_object, scope, stream);
        RETURN_IF_EXCEPTION(scope, {});
        if (!writer)
            return {};
        return JSC::JSValue::encode(writer);
    }

    JSC_DEFINE_HOST_FUNCTION(writableStreamGetWriter, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        RELEASE_AND_RETURN(scope, createWriter(global_object, scope, call_frame->thisValue()));
    }

    JSC_DEFINE_HOST_FUNCTION(writableStreamGetLocked, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireWritableStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSC::JSValue::encode(JSC::jsBoolean(stream->locked()));
    }

    JSC_DEFINE_HOST_FUNCTION(writerConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        RELEASE_AND_RETURN(scope, createWriter(global_object, scope, call_frame->argument(0)));
    }

    JSColloWritableStreamDefaultWriter* requireWriter(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value)
    {
        return requireStreamCell<JSColloWritableStreamDefaultWriter>(
            global_object, scope, value, "WritableStreamDefaultWriter"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(writerWrite, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* writer = requireWriter(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* stream = writer->stream();
        if (!stream)
            return rejectedTypeError(global_object, scope, "WritableStreamDefaultWriter has been released"_s);
        RELEASE_AND_RETURN(scope, stream->write(global_object, scope, writer, call_frame->argument(0)));
    }

    JSC_DEFINE_HOST_FUNCTION(writerClose, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* writer = requireWriter(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* stream = writer->stream();
        if (!stream)
            return rejectedTypeError(global_object, scope, "WritableStreamDefaultWriter has been released"_s);
        RELEASE_AND_RETURN(scope, stream->close(global_object, scope));
    }

    JSC_DEFINE_HOST_FUNCTION(writerAbort, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* writer = requireWriter(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* stream = writer->stream();
        if (!stream)
            return rejectedTypeError(global_object, scope, "WritableStreamDefaultWriter has been released"_s);
        RELEASE_AND_RETURN(scope, stream->abort(global_object, scope, call_frame->argument(0)));
    }

    JSC_DEFINE_HOST_FUNCTION(writerReleaseLock, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* writer = requireWriter(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        writer->release(global_object);
        return JSC::JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(writerClosed, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* writer = requireWriter(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSC::JSValue::encode(writer->closedPromise());
    }

    JSC_DEFINE_HOST_FUNCTION(writerReady, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* writer = requireWriter(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSC::JSValue::encode(writer->readyPromise());
    }

    JSC_DEFINE_HOST_FUNCTION(writerDesiredSize, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* writer = requireWriter(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* stream = writer->stream();
        if (!stream) {
            JSC::throwVMTypeError(global_object, scope, "WritableStreamDefaultWriter has been released"_s);
            return {};
        }
        if (stream->state() == WritableState::Errored || stream->state() == WritableState::Erroring)
            return JSC::JSValue::encode(JSC::jsNull());
        if (stream->state() == WritableState::Closed)
            return JSC::JSValue::encode(JSC::jsNumber(0));
        return JSC::JSValue::encode(JSC::jsNumber(stream->desiredSize()));
    }

    JSC_DEFINE_HOST_FUNCTION(writableControllerError, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* controller = requireStreamCell<JSColloWritableStreamDefaultController>(
            global_object, scope, call_frame->thisValue(), "WritableStreamDefaultController"_s);
        RETURN_IF_EXCEPTION(scope, {});
        if (auto* stream = controller->stream())
            stream->error(global_object, call_frame->argument(0));
        return JSC::JSValue::encode(JSC::jsUndefined());
    }

    constexpr unsigned methodAttributes = static_cast<unsigned>(JSC::PropertyAttribute::None);
    constexpr unsigned accessorAttributes = static_cast<unsigned>(JSC::PropertyAttribute::Accessor);

} // namespace

void installWritableStreamClasses(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    auto& cache = global_object->webApiCache();

    auto* stream_prototype = JSC::constructEmptyObject(global_object);
    putWebApiFunction(global_object, stream_prototype, vm, "getWriter"_s, 0, writableStreamGetWriter, methodAttributes);
    putWebApiFunction(global_object, stream_prototype, vm, "abort"_s, 1, writableStreamAbort, methodAttributes);
    putWebApiFunction(global_object, stream_prototype, vm, "close"_s, 0, writableStreamClose, methodAttributes);
    putWebApiAccessor(
        global_object, stream_prototype, vm, "locked"_s, writableStreamGetLocked, nullptr, accessorAttributes);
    installStreamInterface(global_object, vm, "WritableStream"_s, 0, stream_prototype, writableStreamConstruct);
    cache.writable_stream_structure.set(
        vm, JSColloWritableStream::createStructure(vm, global_object, stream_prototype));

    auto* writer_prototype = JSC::constructEmptyObject(global_object);
    putWebApiFunction(global_object, writer_prototype, vm, "write"_s, 1, writerWrite, methodAttributes);
    putWebApiFunction(global_object, writer_prototype, vm, "close"_s, 0, writerClose, methodAttributes);
    putWebApiFunction(global_object, writer_prototype, vm, "abort"_s, 1, writerAbort, methodAttributes);
    putWebApiFunction(global_object, writer_prototype, vm, "releaseLock"_s, 0, writerReleaseLock, methodAttributes);
    putWebApiAccessor(global_object, writer_prototype, vm, "closed"_s, writerClosed, nullptr, accessorAttributes);
    putWebApiAccessor(global_object, writer_prototype, vm, "ready"_s, writerReady, nullptr, accessorAttributes);
    putWebApiAccessor(
        global_object, writer_prototype, vm, "desiredSize"_s, writerDesiredSize, nullptr, accessorAttributes);
    installStreamInterface(global_object, vm, "WritableStreamDefaultWriter"_s, 1, writer_prototype, writerConstruct);
    cache.writable_stream_default_writer_structure.set(
        vm, JSColloWritableStreamDefaultWriter::createStructure(vm, global_object, writer_prototype));

    auto* controller_prototype = JSC::constructEmptyObject(global_object);
    putWebApiFunction(global_object, controller_prototype, vm, "error"_s, 1, writableControllerError, methodAttributes);
    installStreamInterface(global_object, vm, "WritableStreamDefaultController"_s, 0, controller_prototype, nullptr);
    cache.writable_stream_default_controller_structure.set(
        vm, JSColloWritableStreamDefaultController::createStructure(vm, global_object, controller_prototype));
}

} // namespace Collo::HostFunctions
