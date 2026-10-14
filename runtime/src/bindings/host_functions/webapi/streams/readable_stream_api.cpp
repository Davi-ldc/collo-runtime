// The script-facing surface of the readable stream family: the ReadableStream constructor and ReadableStream.from, the
// methods and accessors of ReadableStream, both readers, both controllers, the BYOB request and the async iterator,
// and the installer that defines them on a realm. Argument conversion and receiver checks sit here in front of the
// algorithms in readable_stream.cpp. Runs on the VM thread.
//
// A method that returns a promise reports a locked stream or a released reader as a promise rejected with a TypeError;
// the constructors, getReader and the controllers' methods throw.

#include "host_functions/webapi/streams/pipe_to_private.h"
#include "host_functions/webapi/streams/readable_stream_consume.h"

#include <JavaScriptCore/AsyncIteratorPrototype.h>

namespace Collo::HostFunctions {
namespace {

    // Web IDL's [EnforceRange] unsigned long long: false for a value that is NaN, infinite, or outside 0 to 2^53 - 1
    // after truncation. Every value in that range is a double exactly and fits size_t on the 64-bit targets.
    constexpr double enforce_range_unsigned_long_long_max = 9007199254740991.0;
    static_assert(enforce_range_unsigned_long_long_max <= static_cast<double>(std::numeric_limits<size_t>::max()));

    bool enforceRangeSize(double value, size_t& out)
    {
        if (std::isnan(value) || std::isinf(value))
            return false;
        value = std::trunc(value);
        if (value < 0 || value > enforce_range_unsigned_long_long_max)
            return false;
        out = static_cast<size_t>(value);
        return true;
    }

    bool parseReadableStreamSourceType(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* source_object, bool& out_is_bytes)
    {
        out_is_bytes = false;
        auto& vm = global_object->vm();
        JSC::JSValue type
            = source_object->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "type"_s));
        RETURN_IF_EXCEPTION(scope, false);
        if (type.isEmpty() || type.isUndefined())
            return true;
        WTF::String type_string = type.toWTFString(global_object);
        RETURN_IF_EXCEPTION(scope, false);
        if (type_string == "bytes"_s) {
            out_is_bytes = true;
            return true;
        }
        JSC::throwVMTypeError(global_object, scope, "ReadableStream underlying source type is not supported"_s);
        return false;
    }

    JSC_DEFINE_HOST_FUNCTION(readableStreamConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        JSC::JSValue underlying_source = call_frame->argument(0);
        if (underlying_source.isUndefined())
            underlying_source = JSC::constructEmptyObject(global_object);
        if (!underlying_source.isObject()) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream underlying source must be an object"_s);
            return {};
        }

        auto* stream_structure
            = streamStructureForNewTarget(global_object, scope, call_frame, collo_global->readableStreamStructure());
        RETURN_IF_EXCEPTION(scope, {});

        // Web IDL argument conversion reads the strategy dictionary before the constructor steps convert the
        // underlying source dictionary, whose members are read in lexicographic order: autoAllocateChunkSize, cancel,
        // pull, start, type. Range validation runs after all members are read.
        bool has_high_water_mark = false;
        double high_water_mark = 0;
        JSC::JSValue size_callback = JSC::jsUndefined();
        if (!parseQueuingStrategy(global_object, scope, call_frame->argument(1), "ReadableStream"_s,
                has_high_water_mark, high_water_mark, size_callback))
            return {};

        auto* source_object = underlying_source.getObject();
        bool has_auto_allocate = false;
        size_t auto_allocate_chunk_size = 0;
        JSC::JSValue auto_allocate = source_object->getIfPropertyExists(
            global_object, JSC::Identifier::fromString(vm, "autoAllocateChunkSize"_s));
        RETURN_IF_EXCEPTION(scope, {});
        if (!auto_allocate.isEmpty() && !auto_allocate.isUndefined()) {
            // The [EnforceRange] conversion throws as soon as the member is read.
            double value = auto_allocate.toNumber(global_object);
            RETURN_IF_EXCEPTION(scope, {});
            if (!enforceRangeSize(value, auto_allocate_chunk_size)) {
                JSC::throwVMTypeError(global_object, scope, "ReadableStream autoAllocateChunkSize is out of range"_s);
                return {};
            }
            has_auto_allocate = true;
        }
        JSC::JSValue cancel = JSC::jsUndefined();
        if (!strictCallbackPropertyOrUndefined(
                global_object, scope, source_object, "cancel"_s, "ReadableStream cancel"_s, cancel))
            return {};
        JSC::JSValue pull = JSC::jsUndefined();
        if (!strictCallbackPropertyOrUndefined(
                global_object, scope, source_object, "pull"_s, "ReadableStream pull"_s, pull))
            return {};
        JSC::JSValue start = JSC::jsUndefined();
        if (!strictCallbackPropertyOrUndefined(
                global_object, scope, source_object, "start"_s, "ReadableStream start"_s, start))
            return {};
        bool is_bytes = false;
        if (!parseReadableStreamSourceType(global_object, scope, source_object, is_bytes))
            return {};

        if (is_bytes && !size_callback.isUndefined()) {
            JSC::throwException(global_object, scope,
                JSC::createRangeError(global_object, "ReadableStream byte stream strategy size is invalid"_s));
            return {};
        }
        if (!validateHighWaterMark(
                global_object, scope, "ReadableStream"_s, has_high_water_mark, is_bytes ? 0 : 1, high_water_mark))
            return {};
        if (is_bytes && has_auto_allocate && !auto_allocate_chunk_size) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream autoAllocateChunkSize must not be zero"_s);
            return {};
        }

        auto* stream = JSColloReadableStream::createWithStructure(vm, stream_structure);
        stream->setHighWaterMark(high_water_mark);
        stream->setByteStream(is_bytes);
        JSColloReadableStreamController* controller = nullptr;
        if (is_bytes) {
            auto* byte_controller = JSColloReadableByteStreamController::create(vm, global_object, stream);
            byte_controller->setAutoAllocateChunkSize(auto_allocate_chunk_size);
            controller = byte_controller;
        } else {
            auto* default_controller = JSColloReadableStreamDefaultController::create(vm, global_object, stream);
            default_controller->setSizeCallback(vm, size_callback);
            controller = default_controller;
        }
        controller->setJavaScriptSource(vm, underlying_source, pull, cancel);
        stream->setController(vm, controller);

        controller->markStarting();
        JSC::JSValue start_result = JSC::jsUndefined();
        if (valueIsCallable(start)) {
            JSC::MarkedArgumentBuffer arguments;
            arguments.append(controller);
            if (arguments.hasOverflowed()) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return {};
            }
            auto call_data = JSC::getCallData(start);
            start_result = JSC::call(global_object, start.getObject(), call_data, underlying_source, arguments);
            RETURN_IF_EXCEPTION(scope, {});
        }
        auto* start_promise = dynamicDowncast<JSC::JSPromise>(start_result);
        if (!start_promise) {
            start_promise = JSC::JSPromise::resolvedPromise(global_object, start_result);
            RETURN_IF_EXCEPTION(scope, {});
        }
        controller->startWith(global_object, start_promise);
        return JSC::JSValue::encode(stream);
    }

    JSC_DEFINE_HOST_FUNCTION(readableStreamFrom, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        JSC::JSValue iterable = call_frame->argument(0);

        bool is_async = false;
        JSC::JSValue iterator_method = iterable.get(global_object, vm.propertyNames->asyncIteratorSymbol);
        RETURN_IF_EXCEPTION(scope, {});
        if (!iterator_method.isUndefinedOrNull()) {
            if (!valueIsCallable(iterator_method)) {
                JSC::throwVMTypeError(global_object, scope, "ReadableStream.from @@asyncIterator must be callable"_s);
                return {};
            }
            is_async = true;
        } else {
            iterator_method = iterable.get(global_object, vm.propertyNames->iteratorSymbol);
            RETURN_IF_EXCEPTION(scope, {});
            if (iterator_method.isUndefinedOrNull()) {
                JSC::throwVMTypeError(global_object, scope, "ReadableStream.from input must be iterable"_s);
                return {};
            }
            if (!valueIsCallable(iterator_method)) {
                JSC::throwVMTypeError(global_object, scope, "ReadableStream.from @@iterator must be callable"_s);
                return {};
            }
        }

        JSC::MarkedArgumentBuffer iterator_arguments;
        auto iterator_call_data = JSC::getCallData(iterator_method);
        JSC::JSValue iterator_value
            = JSC::call(global_object, iterator_method.getObject(), iterator_call_data, iterable, iterator_arguments);
        RETURN_IF_EXCEPTION(scope, {});
        auto* iterator = iterator_value.getObject();
        if (!iterator) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream.from iterator must be an object"_s);
            return {};
        }
        JSC::JSValue next_method = iterator_value.get(global_object, vm.propertyNames->next);
        RETURN_IF_EXCEPTION(scope, {});
        if (!valueIsCallable(next_method)) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream.from iterator next must be callable"_s);
            return {};
        }

        auto* stream = JSColloReadableStream::create(vm, collo_global);
        stream->setHighWaterMark(0);
        auto* controller = JSColloReadableStreamDefaultController::create(vm, global_object, stream);
        auto* state
            = JSColloReadableStreamFromState::create(vm, collo_global, iterator, next_method, is_async, controller);
        controller->setNativeSource(vm, JSColloReadableStreamController::SourceKind::From, state);
        stream->setController(vm, controller);
        // ReadableStreamFromIterable sets up its controller with a start algorithm that returns undefined, so the first
        // pull, and with it the first next(), waits for that start's promise even when a read comes at once.
        controller->markStarting();
        auto* start_promise = JSC::JSPromise::resolvedPromise(global_object, JSC::jsUndefined());
        RETURN_IF_EXCEPTION(scope, {});
        controller->startWith(global_object, start_promise);
        return JSC::JSValue::encode(stream);
    }

    JSC_DEFINE_HOST_FUNCTION(readableStreamGetReader, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireReadableStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        bool wants_byob = false;
        JSC::JSValue options = call_frame->argument(0);
        if (!options.isUndefinedOrNull() && !options.isObject()) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream getReader options must be an object"_s);
            return {};
        }
        if (options.isObject()) {
            JSC::JSValue mode
                = options.getObject()->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "mode"_s));
            RETURN_IF_EXCEPTION(scope, {});
            if (!mode.isEmpty() && !mode.isUndefined()) {
                WTF::String mode_string = mode.toWTFString(global_object);
                RETURN_IF_EXCEPTION(scope, {});
                if (mode_string != "byob"_s) {
                    JSC::throwVMTypeError(global_object, scope, "ReadableStream reader mode is not supported"_s);
                    return {};
                }
                wants_byob = true;
            }
        }
        if (stream->locked()) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream is already locked"_s);
            return {};
        }
        if (wants_byob && !stream->isByteStream()) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream is not a byte stream"_s);
            return {};
        }
        auto* reader = JSColloReadableStreamDefaultReader::create(vm, global_object, stream);
        RETURN_IF_EXCEPTION(scope, {});
        if (!reader)
            return {};
        stream->lock(vm, reader);
        if (wants_byob)
            return JSC::JSValue::encode(JSColloReadableStreamBYOBReader::create(vm, global_object, reader));
        return JSC::JSValue::encode(reader);
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

    JSC::EncodedJSValue consumeThisStream(
        JSC::JSGlobalObject* global_object, JSC::CallFrame* call_frame, ReadableStreamBodyConsumer consumer)
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireReadableStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        RELEASE_AND_RETURN(scope,
            consumeReadableStreamBodyWithNativeFastPath(global_object, scope, stream, consumer, WTF::emptyString()));
    }

    JSC_DEFINE_HOST_FUNCTION(readableStreamBlob, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        return consumeThisStream(global_object, call_frame, ReadableStreamBodyConsumer::Blob);
    }

    JSC_DEFINE_HOST_FUNCTION(readableStreamBytes, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        return consumeThisStream(global_object, call_frame, ReadableStreamBodyConsumer::Bytes);
    }

    JSC_DEFINE_HOST_FUNCTION(readableStreamJson, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        return consumeThisStream(global_object, call_frame, ReadableStreamBodyConsumer::Json);
    }

    JSC_DEFINE_HOST_FUNCTION(readableStreamText, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        return consumeThisStream(global_object, call_frame, ReadableStreamBodyConsumer::Text);
    }

    JSC_DEFINE_HOST_FUNCTION(readableStreamPipeTo, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* source = requireReadableStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* destination = requireWritableStream(global_object, scope, call_frame->argument(0));
        RETURN_IF_EXCEPTION(scope, {});
        RELEASE_AND_RETURN(scope,
            startReadablePipeTo(
                global_object, scope, source, destination, call_frame->argument(1), PipeToErrors::Reject));
    }

    // Web IDL converts the ReadableWritablePair members in lexicographic order, readable before writable, then the
    // options; a locked source or destination throws, unlike pipeTo, whose promise rejects.
    JSC_DEFINE_HOST_FUNCTION(
        readableStreamPipeThrough, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* source = requireReadableStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        JSC::JSValue transform = call_frame->argument(0);
        if (!transform.isObject()) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream pipeThrough transform must be an object"_s);
            return {};
        }
        auto* transform_object = transform.getObject();
        JSC::JSValue readable_value
            = transform_object->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "readable"_s));
        RETURN_IF_EXCEPTION(scope, {});
        auto* readable = requireReadableStream(global_object, scope, readable_value);
        RETURN_IF_EXCEPTION(scope, {});
        JSC::JSValue writable_value
            = transform_object->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "writable"_s));
        RETURN_IF_EXCEPTION(scope, {});
        auto* writable = requireWritableStream(global_object, scope, writable_value);
        RETURN_IF_EXCEPTION(scope, {});
        JSC::JSValue pipe_promise = JSC::JSValue::decode(
            startReadablePipeTo(global_object, scope, source, writable, call_frame->argument(1), PipeToErrors::Throw));
        RETURN_IF_EXCEPTION(scope, {});
        // A failed pipe reports no unhandled rejection.
        if (auto* promise = dynamicDowncast<JSC::JSPromise>(pipe_promise))
            promise->markAsHandled();
        return JSC::JSValue::encode(readable);
    }

    JSC_DEFINE_HOST_FUNCTION(readableStreamTeeMethod, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireReadableStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        JSC::JSObject* branch_a = nullptr;
        JSC::JSObject* branch_b = nullptr;
        if (!readableStreamTee(global_object, scope, stream, branch_a, branch_b))
            return {};
        auto* array = JSC::constructEmptyArray(global_object, nullptr, 2);
        RETURN_IF_EXCEPTION(scope, {});
        array->putDirectIndex(global_object, 0, branch_a);
        RETURN_IF_EXCEPTION(scope, {});
        array->putDirectIndex(global_object, 1, branch_b);
        RETURN_IF_EXCEPTION(scope, {});
        return JSC::JSValue::encode(array);
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
        JSC::JSValue options = call_frame->argument(0);
        if (options.isObject()) {
            JSC::JSValue value = options.getObject()->getIfPropertyExists(
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
        return JSC::JSValue::encode(JSColloReadableStreamAsyncIterator::create(
            vm, uncheckedDowncast<Collo::GlobalObject>(global_object), reader, prevent_cancel));
    }

    JSC_DEFINE_HOST_FUNCTION(readableStreamGetLocked, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireReadableStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSC::JSValue::encode(JSC::jsBoolean(stream->locked()));
    }

    JSC_DEFINE_HOST_FUNCTION(defaultReaderConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireReadableStream(global_object, scope, call_frame->argument(0));
        RETURN_IF_EXCEPTION(scope, {});
        if (stream->locked()) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream is already locked"_s);
            return {};
        }
        auto* reader = JSColloReadableStreamDefaultReader::create(vm, global_object, stream);
        RETURN_IF_EXCEPTION(scope, {});
        if (!reader)
            return {};
        stream->lock(vm, reader);
        return JSC::JSValue::encode(reader);
    }

    JSColloReadableStreamDefaultReader* requireDefaultReader(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value)
    {
        return requireStreamCell<JSColloReadableStreamDefaultReader>(
            global_object, scope, value, "ReadableStreamDefaultReader"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(readerRead, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* reader = requireDefaultReader(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* stream = reader->stream();
        if (!stream)
            return rejectedTypeError(global_object, scope, "ReadableStreamDefaultReader has been released"_s);
        RELEASE_AND_RETURN(scope, stream->read(global_object, scope));
    }

    JSC_DEFINE_HOST_FUNCTION(readerCancel, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* reader = requireDefaultReader(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* stream = reader->stream();
        if (!stream)
            return rejectedTypeError(global_object, scope, "ReadableStreamDefaultReader has been released"_s);
        RELEASE_AND_RETURN(scope, stream->cancel(global_object, scope, call_frame->argument(0)));
    }

    JSC_DEFINE_HOST_FUNCTION(readerReleaseLock, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* reader = requireDefaultReader(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        reader->release(global_object);
        return JSC::JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(readerClosed, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* reader = requireDefaultReader(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSC::JSValue::encode(reader->closedPromise());
    }

    JSC_DEFINE_HOST_FUNCTION(byobReaderConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireReadableStream(global_object, scope, call_frame->argument(0));
        RETURN_IF_EXCEPTION(scope, {});
        if (!stream->isByteStream()) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream is not a byte stream"_s);
            return {};
        }
        if (stream->locked()) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream is already locked"_s);
            return {};
        }
        auto* default_reader = JSColloReadableStreamDefaultReader::create(vm, global_object, stream);
        RETURN_IF_EXCEPTION(scope, {});
        if (!default_reader)
            return {};
        stream->lock(vm, default_reader);
        return JSC::JSValue::encode(JSColloReadableStreamBYOBReader::create(vm, global_object, default_reader));
    }

    JSColloReadableStreamBYOBReader* requireByobReader(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value)
    {
        return requireStreamCell<JSColloReadableStreamBYOBReader>(
            global_object, scope, value, "ReadableStreamBYOBReader"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(byobReaderRead, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* reader = requireByobReader(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* stream = reader->stream();
        if (!stream)
            return rejectedTypeError(global_object, scope, "ReadableStream BYOB reader has no stream"_s);
        auto* view = dynamicDowncast<JSC::JSArrayBufferView>(call_frame->argument(0));
        if (!view)
            return rejectedTypeError(global_object, scope, "ReadableStream BYOB view must be an ArrayBufferView"_s);
        if (arrayBufferViewIsUnavailable(view))
            return rejectedTypeError(global_object, scope, "ReadableStream BYOB view is detached or out of bounds"_s);
        if (!view->byteLength())
            return rejectedTypeError(global_object, scope, "ReadableStream BYOB view must not be empty"_s);
        size_t min_elements = 1;
        JSC::JSValue options = call_frame->argument(1);
        if (!options.isUndefined()) {
            auto* options_object = options.getObject();
            if (!options_object)
                return rejectedTypeError(global_object, scope, "ReadableStream BYOB read options must be an object"_s);
            JSC::JSValue min_value = options_object->get(global_object, JSC::Identifier::fromString(vm, "min"_s));
            RETURN_IF_EXCEPTION(scope, {});
            if (!min_value.isUndefined()) {
                double min_number = min_value.toNumber(global_object);
                RETURN_IF_EXCEPTION(scope, {});
                if (!enforceRangeSize(min_number, min_elements))
                    return rejectedTypeError(global_object, scope, "ReadableStream BYOB read min is out of range"_s);
                if (!min_elements)
                    return rejectedTypeError(
                        global_object, scope, "ReadableStream BYOB read min must be greater than zero"_s);
            }
        }
        const auto view_type = JSC::typedArrayType(view->type());
        const size_t element_count = view_type == JSC::TypeDataView ? view->byteLength() : view->length();
        if (min_elements > element_count)
            return rejectedPromise(global_object, scope,
                JSC::createRangeError(global_object, "ReadableStream BYOB read min exceeds view length"_s));
        const size_t element_size = JSC::elementSize(view_type);
        if (min_elements > std::numeric_limits<size_t>::max() / element_size)
            return rejectedPromise(global_object, scope,
                JSC::createRangeError(global_object, "ReadableStream BYOB read min is too large"_s));
        RELEASE_AND_RETURN(scope, stream->readInto(global_object, scope, view, min_elements * element_size));
    }

    JSC_DEFINE_HOST_FUNCTION(byobReaderCancel, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* reader = requireByobReader(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* stream = reader->stream();
        if (!stream)
            return rejectedTypeError(global_object, scope, "ReadableStream BYOB reader has no stream"_s);
        RELEASE_AND_RETURN(scope, stream->cancel(global_object, scope, call_frame->argument(0)));
    }

    JSC_DEFINE_HOST_FUNCTION(byobReaderReleaseLock, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* reader = requireByobReader(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        reader->release(global_object);
        return JSC::JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(byobReaderClosed, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* reader = requireByobReader(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSC::JSValue::encode(reader->closedPromise());
    }

    JSColloReadableStreamDefaultController* requireDefaultController(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value)
    {
        return requireStreamCell<JSColloReadableStreamDefaultController>(
            global_object, scope, value, "ReadableStreamDefaultController"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(controllerEnqueue, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* controller = requireDefaultController(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (auto* stream = controller->stream()) {
            if (!stream->enqueue(global_object, scope, call_frame->argument(0)))
                return {};
        }
        return JSC::JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(controllerClose, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* controller = requireDefaultController(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (auto* stream = controller->stream()) {
            if (stream->state() != StreamState::Readable || stream->closeRequested()) {
                JSC::throwVMTypeError(global_object, scope, "ReadableStream controller cannot close this stream"_s);
                return {};
            }
            stream->close(global_object);
        }
        return JSC::JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(controllerError, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* controller = requireDefaultController(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (auto* stream = controller->stream())
            stream->error(global_object, call_frame->argument(0));
        return JSC::JSValue::encode(JSC::jsUndefined());
    }

    JSC::JSValue controllerDesiredSizeValue(JSColloReadableStream* stream)
    {
        if (!stream || stream->state() == StreamState::Errored)
            return JSC::jsNull();
        if (stream->state() == StreamState::Closed)
            return JSC::jsNumber(0);
        return JSC::jsNumber(stream->desiredSize());
    }

    JSC_DEFINE_HOST_FUNCTION(controllerDesiredSize, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* controller = requireDefaultController(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSC::JSValue::encode(controllerDesiredSizeValue(controller->stream()));
    }

    JSColloReadableByteStreamController* requireByteController(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value)
    {
        return requireStreamCell<JSColloReadableByteStreamController>(
            global_object, scope, value, "ReadableByteStreamController"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(byteControllerEnqueue, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* controller = requireByteController(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* stream = controller->stream();
        if (!stream)
            return JSC::JSValue::encode(JSC::jsUndefined());
        auto* view = requireArrayBufferView(global_object, scope, call_frame->argument(0), "chunk"_s);
        RETURN_IF_EXCEPTION(scope, {});
        stream->enqueueByteChunk(global_object, scope, view);
        RETURN_IF_EXCEPTION(scope, {});
        return JSC::JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(byteControllerClose, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* controller = requireByteController(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* stream = controller->stream();
        if (!stream)
            return JSC::JSValue::encode(JSC::jsUndefined());
        if (stream->state() != StreamState::Readable || stream->closeRequested()) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream is not readable"_s);
            return {};
        }
        if (stream->firstByobReadRequestHasPartialElement()) {
            // ReadableByteStreamControllerClose: closing with a partially filled BYOB element errors the stream and
            // throws the same TypeError to the caller.
            auto* error
                = JSC::createTypeError(global_object, "ReadableStream closed with a partially filled BYOB element"_s);
            stream->error(global_object, error);
            RETURN_IF_EXCEPTION(scope, {});
            return JSC::JSValue::encode(JSC::throwException(global_object, scope, error));
        }
        // A pending BYOB read keeps the close requested until the source responds to it.
        if (!stream->hasPendingReadRequests() && stream->hasPendingByobReadRequests()) {
            stream->requestClose();
            return JSC::JSValue::encode(JSC::jsUndefined());
        }
        stream->close(global_object);
        RETURN_IF_EXCEPTION(scope, {});
        return JSC::JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(byteControllerError, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* controller = requireByteController(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (auto* stream = controller->stream())
            stream->error(global_object, call_frame->argument(0));
        return JSC::JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(
        byteControllerDesiredSize, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* controller = requireByteController(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSC::JSValue::encode(controllerDesiredSizeValue(controller->stream()));
    }

    JSC_DEFINE_HOST_FUNCTION(
        byteControllerByobRequest, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* controller = requireByteController(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (auto* request = controller->byobRequest())
            return JSC::JSValue::encode(request);
        return JSC::JSValue::encode(JSC::jsNull());
    }

    JSColloReadableStreamBYOBRequest* requireByobRequest(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value)
    {
        return requireStreamCell<JSColloReadableStreamBYOBRequest>(
            global_object, scope, value, "ReadableStreamBYOBRequest"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(byobRequestView, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* request = requireByobRequest(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (auto* view = request->view())
            return JSC::JSValue::encode(view);
        return JSC::JSValue::encode(JSC::jsNull());
    }

    JSC_DEFINE_HOST_FUNCTION(byobRequestRespond, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* request = requireByobRequest(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* stream = request->stream();
        if (!stream) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream BYOB request has no stream"_s);
            return {};
        }
        double number = call_frame->argument(0).toNumber(global_object);
        RETURN_IF_EXCEPTION(scope, {});
        size_t bytes_written = 0;
        if (!enforceRangeSize(number, bytes_written)) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream BYOB bytesWritten is out of range"_s);
            return {};
        }
        stream->settleByobRequestWithBytes(global_object, scope, request, bytes_written);
        RETURN_IF_EXCEPTION(scope, {});
        return JSC::JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(
        byobRequestRespondWithNewView, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* request = requireByobRequest(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* stream = request->stream();
        if (!stream) {
            JSC::throwVMTypeError(global_object, scope, "ReadableStream BYOB request has no stream"_s);
            return {};
        }
        auto* view = requireArrayBufferView(global_object, scope, call_frame->argument(0), "view"_s);
        RETURN_IF_EXCEPTION(scope, {});
        stream->settleByobRequestWithView(global_object, scope, request, view);
        RETURN_IF_EXCEPTION(scope, {});
        return JSC::JSValue::encode(JSC::jsUndefined());
    }

    JSColloReadableStreamAsyncIterator* requireAsyncIterator(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value)
    {
        return requireStreamCell<JSColloReadableStreamAsyncIterator>(
            global_object, scope, value, "ReadableStream async iterator"_s);
    }

    // A promise that fulfills with {value, done: true} once `dependency` fulfills, and rejects as it does.
    JSC::JSPromise* resultAfter(JSC::JSGlobalObject* global_object, JSC::JSPromise* dependency, JSC::JSValue value)
    {
        auto* result = Collo::newPromise(global_object);
        reactToPromise(
            global_object, dependency, StreamReaction::IteratorReturn, readResult(global_object, value, true), result);
        return result;
    }

    JSC_DEFINE_HOST_FUNCTION(iteratorNext, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* iterator = requireAsyncIterator(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* reader = iterator->reader();
        auto* stream = reader ? reader->stream() : nullptr;
        if (!stream) {
            // After return(), a next() resolves done once that return has.
            if (auto* pending = iterator->pendingReturn())
                return JSC::JSValue::encode(resultAfter(global_object, pending, JSC::jsUndefined()));
            return readResultPromise(global_object, JSC::jsUndefined(), true);
        }
        JSC::JSValue read_value = JSC::JSValue::decode(stream->read(global_object, scope));
        RETURN_IF_EXCEPTION(scope, {});
        auto* read_promise = dynamicDowncast<JSC::JSPromise>(read_value);
        if (!read_promise)
            return JSC::JSValue::encode(read_value);
        auto* result = Collo::newPromise(global_object);
        reactToPromise(global_object, read_promise, StreamReaction::IteratorNext, iterator, result);
        return JSC::JSValue::encode(result);
    }

    JSC_DEFINE_HOST_FUNCTION(iteratorReturn, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* iterator = requireAsyncIterator(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        JSC::JSValue return_value = call_frame->argument(0);
        auto* reader = iterator->reader();
        if (!reader) {
            if (auto* pending = iterator->pendingReturn()) {
                auto* chained = resultAfter(global_object, pending, return_value);
                iterator->setReturnPromise(vm, chained);
                return JSC::JSValue::encode(chained);
            }
            return readResultPromise(global_object, return_value, true);
        }
        JSC::JSValue cancel_result = JSC::jsUndefined();
        if (!iterator->preventCancel()) {
            if (auto* stream = reader->stream())
                cancel_result = JSC::JSValue::decode(stream->cancel(global_object, scope, return_value));
            RETURN_IF_EXCEPTION(scope, {});
        }
        iterator->releaseReader(global_object);
        RETURN_IF_EXCEPTION(scope, {});
        if (auto* cancel_promise = dynamicDowncast<JSC::JSPromise>(cancel_result)) {
            auto* result = resultAfter(global_object, cancel_promise, return_value);
            iterator->setReturnPromise(vm, result);
            return JSC::JSValue::encode(result);
        }
        return readResultPromise(global_object, return_value, true);
    }

    JSC_DEFINE_HOST_FUNCTION(iteratorSelf, (JSC::JSGlobalObject*, JSC::CallFrame* call_frame))
    {
        return JSC::JSValue::encode(call_frame->thisValue());
    }

    constexpr unsigned methodAttributes = static_cast<unsigned>(JSC::PropertyAttribute::None);
    constexpr unsigned accessorAttributes = static_cast<unsigned>(JSC::PropertyAttribute::Accessor);

} // namespace

void installReadableStreamClasses(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    auto& cache = global_object->webApiCache();

    auto* stream_prototype = JSC::constructEmptyObject(global_object);
    putWebApiFunction(global_object, stream_prototype, vm, "getReader"_s, 0, readableStreamGetReader, methodAttributes);
    putWebApiFunction(global_object, stream_prototype, vm, "cancel"_s, 1, readableStreamCancel, methodAttributes);
    putWebApiFunction(global_object, stream_prototype, vm, "blob"_s, 0, readableStreamBlob, methodAttributes);
    putWebApiFunction(global_object, stream_prototype, vm, "bytes"_s, 0, readableStreamBytes, methodAttributes);
    putWebApiFunction(global_object, stream_prototype, vm, "json"_s, 0, readableStreamJson, methodAttributes);
    putWebApiFunction(global_object, stream_prototype, vm, "text"_s, 0, readableStreamText, methodAttributes);
    putWebApiFunction(global_object, stream_prototype, vm, "pipeTo"_s, 1, readableStreamPipeTo, methodAttributes);
    putWebApiFunction(
        global_object, stream_prototype, vm, "pipeThrough"_s, 1, readableStreamPipeThrough, methodAttributes);
    putWebApiFunction(global_object, stream_prototype, vm, "tee"_s, 0, readableStreamTeeMethod, methodAttributes);
    putWebApiAccessor(
        global_object, stream_prototype, vm, "locked"_s, readableStreamGetLocked, nullptr, accessorAttributes);
    auto* values_function = JSC::JSFunction::create(
        vm, global_object, 0, "values"_s, readableStreamValues, JSC::ImplementationVisibility::Public);
    stream_prototype->putDirect(vm, JSC::Identifier::fromString(vm, "values"_s), values_function, methodAttributes);
    stream_prototype->putDirect(vm, vm.propertyNames->asyncIteratorSymbol, values_function,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    auto* stream_constructor
        = installStreamInterface(global_object, vm, "ReadableStream"_s, 0, stream_prototype, readableStreamConstruct);
    putWebApiFunction(global_object, stream_constructor, vm, "from"_s, 1, readableStreamFrom, methodAttributes);
    cache.readable_stream_structure.set(
        vm, JSColloReadableStream::createStructure(vm, global_object, stream_prototype));

    auto* reader_prototype = JSC::constructEmptyObject(global_object);
    putWebApiFunction(global_object, reader_prototype, vm, "read"_s, 0, readerRead, methodAttributes);
    putWebApiFunction(global_object, reader_prototype, vm, "cancel"_s, 1, readerCancel, methodAttributes);
    putWebApiFunction(global_object, reader_prototype, vm, "releaseLock"_s, 0, readerReleaseLock, methodAttributes);
    putWebApiAccessor(global_object, reader_prototype, vm, "closed"_s, readerClosed, nullptr, accessorAttributes);
    installStreamInterface(
        global_object, vm, "ReadableStreamDefaultReader"_s, 1, reader_prototype, defaultReaderConstruct);
    cache.readable_stream_default_reader_structure.set(
        vm, JSColloReadableStreamDefaultReader::createStructure(vm, global_object, reader_prototype));

    auto* controller_prototype = JSC::constructEmptyObject(global_object);
    putWebApiFunction(global_object, controller_prototype, vm, "enqueue"_s, 1, controllerEnqueue, methodAttributes);
    putWebApiFunction(global_object, controller_prototype, vm, "close"_s, 0, controllerClose, methodAttributes);
    putWebApiFunction(global_object, controller_prototype, vm, "error"_s, 1, controllerError, methodAttributes);
    putWebApiAccessor(
        global_object, controller_prototype, vm, "desiredSize"_s, controllerDesiredSize, nullptr, accessorAttributes);
    installStreamInterface(global_object, vm, "ReadableStreamDefaultController"_s, 0, controller_prototype, nullptr);
    cache.readable_stream_default_controller_structure.set(
        vm, JSColloReadableStreamDefaultController::createStructure(vm, global_object, controller_prototype));

    auto* byob_reader_prototype = JSC::constructEmptyObject(global_object);
    putWebApiFunction(global_object, byob_reader_prototype, vm, "read"_s, 1, byobReaderRead, methodAttributes);
    putWebApiFunction(global_object, byob_reader_prototype, vm, "cancel"_s, 1, byobReaderCancel, methodAttributes);
    putWebApiFunction(
        global_object, byob_reader_prototype, vm, "releaseLock"_s, 0, byobReaderReleaseLock, methodAttributes);
    putWebApiAccessor(
        global_object, byob_reader_prototype, vm, "closed"_s, byobReaderClosed, nullptr, accessorAttributes);
    installStreamInterface(
        global_object, vm, "ReadableStreamBYOBReader"_s, 1, byob_reader_prototype, byobReaderConstruct);
    cache.readable_stream_byob_reader_structure.set(
        vm, JSColloReadableStreamBYOBReader::createStructure(vm, global_object, byob_reader_prototype));

    auto* byob_request_prototype = JSC::constructEmptyObject(global_object);
    putWebApiAccessor(
        global_object, byob_request_prototype, vm, "view"_s, byobRequestView, nullptr, accessorAttributes);
    putWebApiFunction(global_object, byob_request_prototype, vm, "respond"_s, 1, byobRequestRespond, methodAttributes);
    putWebApiFunction(global_object, byob_request_prototype, vm, "respondWithNewView"_s, 1,
        byobRequestRespondWithNewView, methodAttributes);
    installStreamInterface(global_object, vm, "ReadableStreamBYOBRequest"_s, 0, byob_request_prototype, nullptr);
    cache.readable_stream_byob_request_structure.set(
        vm, JSColloReadableStreamBYOBRequest::createStructure(vm, global_object, byob_request_prototype));

    auto* byte_controller_prototype = JSC::constructEmptyObject(global_object);
    putWebApiFunction(
        global_object, byte_controller_prototype, vm, "enqueue"_s, 1, byteControllerEnqueue, methodAttributes);
    putWebApiFunction(
        global_object, byte_controller_prototype, vm, "close"_s, 0, byteControllerClose, methodAttributes);
    putWebApiFunction(
        global_object, byte_controller_prototype, vm, "error"_s, 1, byteControllerError, methodAttributes);
    putWebApiAccessor(global_object, byte_controller_prototype, vm, "desiredSize"_s, byteControllerDesiredSize, nullptr,
        accessorAttributes);
    putWebApiAccessor(global_object, byte_controller_prototype, vm, "byobRequest"_s, byteControllerByobRequest, nullptr,
        accessorAttributes);
    installStreamInterface(global_object, vm, "ReadableByteStreamController"_s, 0, byte_controller_prototype, nullptr);
    cache.readable_byte_stream_controller_structure.set(
        vm, JSColloReadableByteStreamController::createStructure(vm, global_object, byte_controller_prototype));

    auto* iterator_prototype = JSC::constructEmptyObject(global_object, global_object->asyncIteratorPrototype());
    putWebApiFunction(global_object, iterator_prototype, vm, "next"_s, 0, iteratorNext, methodAttributes);
    putWebApiFunction(global_object, iterator_prototype, vm, "return"_s, 1, iteratorReturn, methodAttributes);
    auto* iterator_self_function = JSC::JSFunction::create(
        vm, global_object, 0, "[Symbol.asyncIterator]"_s, iteratorSelf, JSC::ImplementationVisibility::Public);
    iterator_prototype->putDirect(vm, vm.propertyNames->asyncIteratorSymbol, iterator_self_function,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    cache.readable_stream_async_iterator_structure.set(
        vm, JSColloReadableStreamAsyncIterator::createStructure(vm, global_object, iterator_prototype));

    // Cells script never sees take Object.prototype; only their ClassInfo matters.
    auto* object_prototype = global_object->objectPrototype();
    cache.readable_stream_tee_state_structure.set(
        vm, JSColloReadableStreamTeeState::createStructure(vm, global_object, object_prototype));
    cache.readable_stream_from_state_structure.set(
        vm, JSColloReadableStreamFromState::createStructure(vm, global_object, object_prototype));
    cache.body_consumer_structure.set(vm, JSColloBodyConsumer::createStructure(vm, global_object, object_prototype));
}

} // namespace Collo::HostFunctions
