// The script-facing methods of WritableStream, WritableStreamDefaultWriter and
// WritableStreamDefaultController: argument conversion and receiver checks in
// front of the state machine in writable_stream.cpp. Runs on the VM thread.
//
// A method that returns a promise reports a locked stream or a released writer
// as a promise rejected with a TypeError; getWriter, the writer constructor and
// the desiredSize getter throw it.
#include "host_functions/webapi/streams/writable_stream_private.h"

namespace Collo::HostFunctions {

JSC_DEFINE_HOST_FUNCTION(writableStreamConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "WritableStream constructor requires 'new'"_s);
}

JSC_DEFINE_HOST_FUNCTION(
    writableStreamConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    JSValue underlying_sink = call_frame->argument(0);
    if (underlying_sink.isUndefined())
        underlying_sink = JSC::constructEmptyObject(global_object);
    if (!underlying_sink.isObject()) {
        JSC::throwVMTypeError(global_object, scope, "WritableStream underlying sink must be an object"_s);
        return {};
    }

    // Web IDL argument conversion reads the strategy dictionary before the
    // constructor steps convert the underlying sink dictionary, whose
    // members are read in lexicographic order: abort, close, start, type,
    // write. A defined type rejects only after the full conversion.
    bool has_high_water_mark = false;
    double high_water_mark = 0;
    JSValue size_callback = JSC::jsUndefined();
    if (!parseQueuingStrategy(global_object, scope, call_frame->argument(1), "WritableStream"_s, has_high_water_mark,
            high_water_mark, size_callback))
        return {};
    RETURN_IF_EXCEPTION(scope, {});

    auto* sink_object = underlying_sink.getObject();
    JSValue abort = JSC::jsUndefined();
    if (!strictCallbackPropertyOrUndefined(
            global_object, scope, sink_object, "abort"_s, "WritableStream abort"_s, abort))
        return {};
    RETURN_IF_EXCEPTION(scope, {});
    JSValue close = JSC::jsUndefined();
    if (!strictCallbackPropertyOrUndefined(
            global_object, scope, sink_object, "close"_s, "WritableStream close"_s, close))
        return {};
    RETURN_IF_EXCEPTION(scope, {});
    JSValue start = JSC::jsUndefined();
    if (!strictCallbackPropertyOrUndefined(
            global_object, scope, sink_object, "start"_s, "WritableStream start"_s, start))
        return {};
    RETURN_IF_EXCEPTION(scope, {});
    JSValue type = sink_object->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "type"_s));
    RETURN_IF_EXCEPTION(scope, {});
    JSValue write = JSC::jsUndefined();
    if (!strictCallbackPropertyOrUndefined(
            global_object, scope, sink_object, "write"_s, "WritableStream write"_s, write))
        return {};
    RETURN_IF_EXCEPTION(scope, {});

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
    auto* stream = JSColloWritableStream::createWithStructure(
        vm, uncheckedDowncast<Collo::GlobalObject>(global_object), stream_structure);
    RETURN_IF_EXCEPTION(scope, {});
    if (!stream)
        return {};
    auto* controller = JSColloWritableStreamDefaultController::create(vm, global_object, stream);
    stream->setController(vm, controller);
    stream->setHighWaterMark(high_water_mark);
    controller->setCallbacks(vm, write, close, abort, size_callback);
    controller->setUnderlyingSink(vm, underlying_sink);
    stream->start(global_object, scope, start);
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(stream);
}

JSC_DEFINE_HOST_FUNCTION(writableStreamAbort, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream = requireWritableStream(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    if (stream->locked())
        return rejectedTypeError(global_object, scope, "WritableStream is locked"_s);
    return stream->abort(global_object, scope, call_frame->argument(0));
}

JSC_DEFINE_HOST_FUNCTION(writableStreamClose, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream = requireWritableStream(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    if (stream->locked())
        return rejectedTypeError(global_object, scope, "WritableStream is locked"_s);
    return stream->close(global_object, scope);
}

JSC_DEFINE_HOST_FUNCTION(writableStreamGetWriter, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream = requireWritableStream(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    if (stream->locked()) {
        JSC::throwVMTypeError(global_object, scope, "WritableStream is already locked"_s);
        return {};
    }
    auto* writer = JSColloWritableStreamDefaultWriter::create(vm, global_object, scope, stream);
    RETURN_IF_EXCEPTION(scope, {});
    if (!writer)
        return {};
    return JSValue::encode(writer);
}

JSC_DEFINE_HOST_FUNCTION(writableStreamGetLocked, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream = requireWritableStream(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(JSC::jsBoolean(stream->locked()));
}

JSC_DEFINE_HOST_FUNCTION(defaultWriterConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "WritableStreamDefaultWriter constructor requires 'new'"_s);
}

JSC_DEFINE_HOST_FUNCTION(
    defaultWriterConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* stream = requireWritableStream(global_object, scope, call_frame->argument(0));
    RETURN_IF_EXCEPTION(scope, {});
    if (stream->locked()) {
        JSC::throwVMTypeError(global_object, scope, "WritableStream is already locked"_s);
        return {};
    }
    auto* writer = JSColloWritableStreamDefaultWriter::create(vm, global_object, scope, stream);
    RETURN_IF_EXCEPTION(scope, {});
    if (!writer)
        return {};
    return JSValue::encode(writer);
}

JSC_DEFINE_HOST_FUNCTION(writerWrite, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* writer = requireWritableStreamDefaultWriter(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    auto* stream = writer->stream();
    if (!stream)
        return rejectedTypeError(global_object, scope, "WritableStreamDefaultWriter has been released"_s);
    return stream->write(global_object, scope, writer, call_frame->argument(0));
}

JSC_DEFINE_HOST_FUNCTION(writerClose, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* writer = requireWritableStreamDefaultWriter(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    auto* stream = writer->stream();
    if (!stream)
        return rejectedTypeError(global_object, scope, "WritableStreamDefaultWriter has been released"_s);
    return stream->close(global_object, scope);
}

JSC_DEFINE_HOST_FUNCTION(writerAbort, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* writer = requireWritableStreamDefaultWriter(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    auto* stream = writer->stream();
    if (!stream)
        return rejectedTypeError(global_object, scope, "WritableStreamDefaultWriter has been released"_s);
    return stream->abort(global_object, scope, call_frame->argument(0));
}

JSC_DEFINE_HOST_FUNCTION(writerReleaseLock, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* writer = requireWritableStreamDefaultWriter(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    writer->release(global_object);
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(writerClosed, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* writer = requireWritableStreamDefaultWriter(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(writer->closedPromise());
}

JSC_DEFINE_HOST_FUNCTION(writerReady, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* writer = requireWritableStreamDefaultWriter(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(writer->readyPromise());
}

JSC_DEFINE_HOST_FUNCTION(writerDesiredSize, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* writer = requireWritableStreamDefaultWriter(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    auto* stream = writer->stream();
    if (!stream) {
        JSC::throwVMTypeError(global_object, scope, "WritableStreamDefaultWriter has been released"_s);
        return {};
    }
    if (stream->state() == WritableState::Errored || stream->state() == WritableState::Erroring)
        return JSValue::encode(JSC::jsNull());
    if (stream->state() == WritableState::Closed)
        return JSValue::encode(JSC::jsNumber(0));
    return JSValue::encode(JSC::jsNumber(stream->desiredSize()));
}

JSC_DEFINE_HOST_FUNCTION(defaultWriterControllerCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "WritableStreamDefaultController constructor is not public"_s);
}

JSC_DEFINE_HOST_FUNCTION(defaultWriterControllerConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSC::throwVMTypeError(global_object, scope, "WritableStreamDefaultController constructor is not public"_s);
}

JSC_DEFINE_HOST_FUNCTION(writableControllerError, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    auto* controller = requireWritableStreamDefaultController(global_object, scope, call_frame->thisValue());
    RETURN_IF_EXCEPTION(scope, {});
    if (auto* stream = controller->stream())
        stream->error(global_object, call_frame->argument(0));
    return JSValue::encode(JSC::jsUndefined());
}

} // namespace Collo::HostFunctions
