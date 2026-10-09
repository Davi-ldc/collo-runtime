// Helpers every stream class shares: receiver checks, the per-VM property
// identifiers, buffer copies and transfers, promise plumbing, and the native
// source that serves a byte buffer as a readable stream. Runs on the VM thread.
//
// A native callback reaches its cell through a DontEnum property of its
// JSFunction, never through a captured pointer, so the collector traces the
// edge. The identifiers are cached in the VM's ColloWebApiCache and live until
// destroyVmContents clears it.
#include "host_functions/webapi/streams/pipe_transform_stream_private.h"

#include "host_functions/webapi/dom/dom_exception.h"

namespace Collo::HostFunctions {

static size_t retainedArrayBufferMemoryCost(JSC::ArrayBuffer* buffer)
{
    if (!buffer || buffer->isDetached())
        return 0;
    if (auto max_byte_length = buffer->maxByteLength())
        return *max_byte_length;
    return buffer->byteLength();
}

size_t streamChunkMemoryCost(JSValue value)
{
    if (auto* view = dynamicDowncast<JSC::JSArrayBufferView>(value)) {
        if (view->isDetached())
            return 0;
        auto buffer = view->possiblySharedBuffer();
        return retainedArrayBufferMemoryCost(buffer);
    }
    if (auto* array_buffer = dynamicDowncast<JSC::JSArrayBuffer>(value)) {
        auto* buffer = array_buffer->impl();
        return retainedArrayBufferMemoryCost(buffer);
    }
    if (auto* string = dynamicDowncast<JSC::JSString>(value)) {
        size_t length = string->length();
        if (length > std::numeric_limits<size_t>::max() / sizeof(char16_t))
            return std::numeric_limits<size_t>::max();
        return length * sizeof(char16_t);
    }
    return 1;
}

JSC::JSObject* createStreamQueueLimitExceededError(JSC::JSGlobalObject* global_object, WTF::ASCIILiteral message)
{
    return createDOMException(global_object, DOMExceptionCode::QuotaExceededError, WTF::String(message));
}

JSColloReadableStream* requireReadableStream(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    if (auto* stream = dynamicDowncast<JSColloReadableStream>(value))
        return stream;
    JSC::throwVMTypeError(global_object, scope, "ReadableStream method called on incompatible receiver"_s);
    return nullptr;
}

JSColloReadableStreamDefaultReader* requireReadableStreamDefaultReader(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    if (auto* reader = dynamicDowncast<JSColloReadableStreamDefaultReader>(value))
        return reader;
    JSC::throwVMTypeError(global_object, scope, "ReadableStreamDefaultReader method called on incompatible receiver"_s);
    return nullptr;
}

JSColloReadableStreamDefaultController* requireReadableStreamDefaultController(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    if (auto* controller = dynamicDowncast<JSColloReadableStreamDefaultController>(value))
        return controller;
    JSC::throwVMTypeError(
        global_object, scope, "ReadableStreamDefaultController method called on incompatible receiver"_s);
    return nullptr;
}

JSColloReadableStreamBYOBReader* requireReadableStreamBYOBReader(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    if (auto* reader = dynamicDowncast<JSColloReadableStreamBYOBReader>(value))
        return reader;
    JSC::throwVMTypeError(global_object, scope, "ReadableStreamBYOBReader method called on incompatible receiver"_s);
    return nullptr;
}

JSColloReadableStreamBYOBRequest* requireReadableStreamBYOBRequest(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    if (auto* request = dynamicDowncast<JSColloReadableStreamBYOBRequest>(value))
        return request;
    JSC::throwVMTypeError(global_object, scope, "ReadableStreamBYOBRequest method called on incompatible receiver"_s);
    return nullptr;
}

JSColloReadableByteStreamController* requireReadableByteStreamController(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    if (auto* controller = dynamicDowncast<JSColloReadableByteStreamController>(value))
        return controller;
    JSC::throwVMTypeError(
        global_object, scope, "ReadableByteStreamController method called on incompatible receiver"_s);
    return nullptr;
}

JSColloReadableStreamAsyncIterator* requireReadableStreamAsyncIterator(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    if (auto* iterator = dynamicDowncast<JSColloReadableStreamAsyncIterator>(value))
        return iterator;
    JSC::throwVMTypeError(
        global_object, scope, "ReadableStream async iterator method called on incompatible receiver"_s);
    return nullptr;
}

JSColloWritableStream* requireWritableStream(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    if (auto* stream = dynamicDowncast<JSColloWritableStream>(value))
        return stream;
    JSC::throwVMTypeError(global_object, scope, "WritableStream method called on incompatible receiver"_s);
    return nullptr;
}

JSColloWritableStreamDefaultWriter* requireWritableStreamDefaultWriter(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    if (auto* writer = dynamicDowncast<JSColloWritableStreamDefaultWriter>(value))
        return writer;
    JSC::throwVMTypeError(global_object, scope, "WritableStreamDefaultWriter method called on incompatible receiver"_s);
    return nullptr;
}

JSColloWritableStreamDefaultController* requireWritableStreamDefaultController(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    if (auto* controller = dynamicDowncast<JSColloWritableStreamDefaultController>(value))
        return controller;
    JSC::throwVMTypeError(
        global_object, scope, "WritableStreamDefaultController method called on incompatible receiver"_s);
    return nullptr;
}

JSColloTransformStream* requireTransformStream(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    if (auto* stream = dynamicDowncast<JSColloTransformStream>(value))
        return stream;
    JSC::throwVMTypeError(global_object, scope, "TransformStream method called on incompatible receiver"_s);
    return nullptr;
}

JSColloTransformStreamDefaultController* requireTransformStreamDefaultController(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    if (auto* controller = dynamicDowncast<JSColloTransformStreamDefaultController>(value))
        return controller;
    JSC::throwVMTypeError(
        global_object, scope, "TransformStreamDefaultController method called on incompatible receiver"_s);
    return nullptr;
}

const JSC::Identifier& cachedReadableStreamIdentifier(
    JSC::JSGlobalObject* global_object, JSC::Identifier ColloWebApiCache::* field, WTF::ASCIILiteral name)
{
    auto& vm = global_object->vm();
    auto& cache = uncheckedDowncast<Collo::GlobalObject>(global_object)->webApiCache();
    auto& identifier = cache.*field;
    if (identifier.isNull())
        identifier = JSC::Identifier::fromString(vm, name);
    return identifier;
}

const JSC::Identifier& readableStreamIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::readable_stream_identifier, "__colloReadableStream"_s);
}

const JSC::Identifier& readableStreamOwnerIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::readable_stream_owner_identifier, "__colloReadableStreamOwner"_s);
}

const JSC::Identifier& readableStreamIteratorIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::readable_stream_iterator_identifier, "__colloReadableStreamIterator"_s);
}

const JSC::Identifier& readableStreamIteratorReturnValueIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(global_object,
        &ColloWebApiCache::readable_stream_iterator_return_value_identifier,
        "__colloReadableStreamIteratorReturnValue"_s);
}

const JSC::Identifier& readableStreamIteratorReturnPendingIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(global_object,
        &ColloWebApiCache::readable_stream_iterator_return_pending_identifier,
        "__colloReadableStreamIteratorReturnPending"_s);
}

const JSC::Identifier& readableStreamControllerIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::readable_stream_controller_identifier, "__colloController"_s);
}

const JSC::Identifier& readableStreamTeeStateIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::readable_stream_tee_state_identifier, "__colloReadableStreamTeeState"_s);
}

const JSC::Identifier& teeOriginalIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::readable_stream_tee_original_identifier, "__colloOriginal"_s);
}

const JSC::Identifier& teeBranchAIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::readable_stream_tee_branch_a_identifier, "__colloBranchA"_s);
}

const JSC::Identifier& teeBranchBIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::readable_stream_tee_branch_b_identifier, "__colloBranchB"_s);
}

const JSC::Identifier& teeReadingIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::readable_stream_tee_reading_identifier, "__colloReading"_s);
}

const JSC::Identifier& teeFulfilledIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::readable_stream_tee_fulfilled_identifier, "__colloTeeFulfilled"_s);
}

const JSC::Identifier& teeRejectedIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::readable_stream_tee_rejected_identifier, "__colloTeeRejected"_s);
}

const JSC::Identifier& teeBranchACanceledIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::readable_stream_tee_branch_a_canceled_identifier, "__colloBranchACanceled"_s);
}

const JSC::Identifier& teeBranchBCanceledIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::readable_stream_tee_branch_b_canceled_identifier, "__colloBranchBCanceled"_s);
}

const JSC::Identifier& teeBranchAReasonIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::readable_stream_tee_branch_a_reason_identifier, "__colloBranchAReason"_s);
}

const JSC::Identifier& teeBranchBReasonIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::readable_stream_tee_branch_b_reason_identifier, "__colloBranchBReason"_s);
}

const JSC::Identifier& readableStreamFromStateIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::readable_stream_from_state_identifier, "__colloReadableStreamFromState"_s);
}

const JSC::Identifier& readableStreamFromIteratorIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::readable_stream_from_iterator_identifier, "__colloIterator"_s);
}

const JSC::Identifier& readableStreamFromNextIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::readable_stream_from_next_identifier, "__colloNext"_s);
}

const JSC::Identifier& readableStreamFromIsAsyncIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::readable_stream_from_is_async_identifier, "__colloIsAsync"_s);
}

const JSC::Identifier& readableStreamFromDoneIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::readable_stream_from_done_identifier, "__colloDone"_s);
}

const JSC::Identifier& readableStreamFromNextFulfilledIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::readable_stream_from_next_fulfilled_identifier, "__colloNextFulfilled"_s);
}

const JSC::Identifier& readableStreamFromNextRejectedIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::readable_stream_from_next_rejected_identifier, "__colloNextRejected"_s);
}

const JSC::Identifier& readableStreamFromValueFulfilledIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::readable_stream_from_value_fulfilled_identifier, "__colloValueFulfilled"_s);
}

const JSC::Identifier& readableStreamFromValueRejectedIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::readable_stream_from_value_rejected_identifier, "__colloValueRejected"_s);
}

const JSC::Identifier& readableStreamFromReturnFulfilledIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::readable_stream_from_return_fulfilled_identifier, "__colloReturnFulfilled"_s);
}

const JSC::Identifier& readableStreamFromReturnRejectedIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::readable_stream_from_return_rejected_identifier, "__colloReturnRejected"_s);
}

const JSC::Identifier& writableStreamIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::writable_stream_identifier, "__colloWritableStream"_s);
}

const JSC::Identifier& writableStreamControllerIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::writable_stream_controller_identifier, "__colloWritableStreamController"_s);
}

const JSC::Identifier& transformStreamIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::transform_stream_identifier, "__colloTransformStream"_s);
}

const JSC::Identifier& pipeToStateIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::pipe_to_state_identifier, "__colloPipeToState"_s);
}

const JSC::Identifier& compressionStreamStateIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::compression_stream_state_identifier, "__colloCompressionStream"_s);
}

const JSC::Identifier& textEncoderStreamStateIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::text_encoder_stream_state_identifier, "__colloTextEncoderStream"_s);
}

const JSC::Identifier& textDecoderStreamStateIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(
        global_object, &ColloWebApiCache::text_decoder_stream_state_identifier, "__colloTextDecoderStream"_s);
}

const JSC::Identifier& byteLengthIdentifier(JSC::JSGlobalObject* global_object)
{
    return cachedReadableStreamIdentifier(global_object, &ColloWebApiCache::byte_length_identifier, "byteLength"_s);
}

JSC::JSFunction* cachedThenCallback(JSC::JSGlobalObject* global_object, JSC::WriteBarrier<JSC::JSFunction>& slot,
    JSC::JSCell* owner, WTF::ASCIILiteral name, JSC::NativeFunction callback, const JSC::Identifier& state_identifier,
    JSC::JSCell* state_cell)
{
    if (auto* function = slot.get())
        return function;
    auto& vm = global_object->vm();
    auto* function
        = JSC::JSFunction::create(vm, global_object, 1, name, callback, JSC::ImplementationVisibility::Public);
    function->putDirect(vm, state_identifier, state_cell, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    slot.set(vm, owner, function);
    return function;
}

JSC::JSUint8Array* createUint8ArrayCopy(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const uint8_t> bytes)
{
    auto* structure = global_object->typedArrayStructureWithTypedArrayType<JSC::TypeUint8>();
    auto* array = JSC::JSUint8Array::createUninitialized(global_object, structure, bytes.size());
    RETURN_IF_EXCEPTION(scope, nullptr);
    if (!bytes.empty())
        std::memcpy(array->vector(), bytes.data(), bytes.size());
    return array;
}

JSC::JSUint8Array* createUint8Array(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, size_t byte_length)
{
    auto* structure = global_object->typedArrayStructureWithTypedArrayType<JSC::TypeUint8>();
    auto* array = JSC::JSUint8Array::createUninitialized(global_object, structure, byte_length);
    RETURN_IF_EXCEPTION(scope, nullptr);
    if (byte_length)
        std::memset(array->vector(), 0, byte_length);
    return array;
}

JSC::JSUint8Array* createUint8ArrayCopy(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<uint8_t> bytes)
{
    return createUint8ArrayCopy(global_object, scope, std::span<const uint8_t> { bytes.data(), bytes.size() });
}

static WTF::RefPtr<JSC::ArrayBuffer> createArrayBufferImplFromExclusiveSharedBytes(JSC::JSGlobalObject* global_object,
    JSC::ThrowScope& scope, WTF::Ref<ColloSharedBytes>&& bytes, size_t offset, size_t byte_length)
{
    ASSERT(bytes->hasOneRef());
    if (offset > bytes->size() || byte_length > bytes->size() - offset) {
        JSC::throwVMRangeError(global_object, scope, "exclusive byte range is out of bounds"_s);
        return nullptr;
    }
    if (!byte_length)
        return JSC::ArrayBuffer::tryCreate(0, 1);

    auto range = bytes->mutableSpan().subspan(offset, byte_length);
    WTF::RefPtr<ColloSharedBytes> retained = WTF::move(bytes);
    return JSC::ArrayBuffer::createFromBytes(range,
        WTF::createSharedTask<void(void*)>([retained = WTF::move(retained)](void*) mutable { retained = nullptr; }));
}

JSC::JSArrayBuffer* createArrayBufferFromExclusiveSharedBytes(JSC::JSGlobalObject* global_object,
    JSC::ThrowScope& scope, WTF::Ref<ColloSharedBytes>&& bytes, size_t offset, size_t byte_length)
{
    auto buffer
        = createArrayBufferImplFromExclusiveSharedBytes(global_object, scope, WTF::move(bytes), offset, byte_length);
    RETURN_IF_EXCEPTION(scope, nullptr);
    if (!buffer) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return nullptr;
    }
    return JSC::JSArrayBuffer::create(global_object->vm(),
        global_object->arrayBufferStructure(JSC::ArrayBufferSharingMode::Default), WTF::move(buffer));
}

JSC::JSUint8Array* createUint8ArrayFromExclusiveSharedBytes(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    WTF::Ref<ColloSharedBytes>&& bytes, size_t offset, size_t byte_length)
{
    auto buffer
        = createArrayBufferImplFromExclusiveSharedBytes(global_object, scope, WTF::move(bytes), offset, byte_length);
    RETURN_IF_EXCEPTION(scope, nullptr);
    if (!buffer) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return nullptr;
    }
    auto* structure = global_object->typedArrayStructureWithTypedArrayType<JSC::TypeUint8>();
    auto* array = JSC::JSUint8Array::create(global_object, structure, WTF::move(buffer), 0, byte_length);
    RETURN_IF_EXCEPTION(scope, nullptr);
    return array;
}

JSC::JSUint8Array* createUint8ArrayView(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSC::JSArrayBufferView* source, size_t relative_byte_offset, size_t byte_length)
{
    if (arrayBufferViewIsUnavailable(source)) {
        JSC::throwVMTypeError(global_object, scope, "ArrayBufferView is detached or out of bounds"_s);
        return nullptr;
    }
    const size_t source_length = source->byteLength();
    if (relative_byte_offset > source_length || byte_length > source_length - relative_byte_offset) {
        JSC::throwVMRangeError(global_object, scope, "ArrayBufferView range is out of bounds"_s);
        return nullptr;
    }
    auto* buffer = source->possiblySharedBuffer();
    if (!buffer) {
        JSC::throwVMTypeError(global_object, scope, "ArrayBufferView buffer is unavailable"_s);
        return nullptr;
    }
    const size_t byte_offset = source->byteOffset() + relative_byte_offset;
    RefPtr<JSC::ArrayBuffer> retained_buffer(buffer);
    auto* structure = global_object->typedArrayStructure(JSC::TypeUint8, source->isResizableOrGrowableShared());
    auto* array = JSC::JSUint8Array::create(
        global_object, structure, WTF::move(retained_buffer), byte_offset, std::optional<size_t> { byte_length });
    RETURN_IF_EXCEPTION(scope, nullptr);
    return array;
}

JSC::JSUint8Array* transferArrayBufferViewToUint8Array(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSArrayBufferView* source, WTF::ASCIILiteral name)
{
    if (arrayBufferViewIsUnavailable(source)) {
        JSC::throwVMTypeError(global_object, scope, WTF::makeString(name, " must not be detached or out of bounds"_s));
        return nullptr;
    }
    return transferArrayBufferViewRangeToUint8Array(global_object, scope, source, 0, source->byteLength(), name);
}

JSC::JSUint8Array* transferArrayBufferViewRangeToUint8Array(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSC::JSArrayBufferView* source, size_t relative_byte_offset, size_t byte_length, WTF::ASCIILiteral name)
{
    if (arrayBufferViewIsUnavailable(source)) {
        JSC::throwVMTypeError(global_object, scope, WTF::makeString(name, " must not be detached or out of bounds"_s));
        return nullptr;
    }
    const size_t source_length = source->byteLength();
    if (relative_byte_offset > source_length || byte_length > source_length - relative_byte_offset) {
        JSC::throwVMRangeError(global_object, scope, WTF::makeString(name, " range is out of bounds"_s));
        return nullptr;
    }
    if (source->isShared() || source->isResizableOrGrowableShared()) {
        JSC::throwVMTypeError(
            global_object, scope, WTF::makeString(name, " must use a fixed-length non-shared ArrayBuffer"_s));
        return nullptr;
    }

    JSC::JSArrayBuffer* js_buffer = source->unsharedJSBuffer(global_object);
    RETURN_IF_EXCEPTION(scope, nullptr);
    auto* buffer = js_buffer ? js_buffer->impl() : nullptr;
    if (!buffer || buffer->isDetached() || !buffer->isDetachable()) {
        JSC::throwVMTypeError(global_object, scope, WTF::makeString(name, " buffer cannot be transferred"_s));
        return nullptr;
    }

    const size_t byte_offset = source->byteOffset() + relative_byte_offset;
    JSC::ArrayBufferContents transferred_contents;
    if (!buffer->transferTo(global_object->vm(), transferred_contents)) {
        JSC::throwVMTypeError(global_object, scope, WTF::makeString(name, " buffer could not be transferred"_s));
        return nullptr;
    }

    RefPtr<JSC::ArrayBuffer> transferred_buffer = JSC::ArrayBuffer::create(WTF::move(transferred_contents));
    auto* array = JSC::JSUint8Array::create(global_object, global_object->typedArrayStructure(JSC::TypeUint8, false),
        WTF::move(transferred_buffer), byte_offset, std::optional<size_t> { byte_length });
    RETURN_IF_EXCEPTION(scope, nullptr);
    return array;
}

template <typename View>
static JSC::JSArrayBufferView* createTransferredTypedArrayView(JSC::JSGlobalObject* global_object,
    JSC::ThrowScope& scope, RefPtr<JSC::ArrayBuffer>&& buffer, size_t byte_offset, size_t byte_length,
    WTF::ASCIILiteral name)
{
    if (byte_length % View::elementSize != 0) {
        JSC::throwVMRangeError(global_object, scope, WTF::makeString(name, " length is not aligned to element size"_s));
        return nullptr;
    }
    auto* view = View::create(global_object, global_object->typedArrayStructure(View::TypedArrayStorageType, false),
        WTF::move(buffer), byte_offset, std::optional<size_t> { byte_length / View::elementSize });
    RETURN_IF_EXCEPTION(scope, nullptr);
    return view;
}

JSC::JSArrayBufferView* transferArrayBufferViewRangeToSameView(JSC::JSGlobalObject* global_object,
    JSC::ThrowScope& scope, JSC::JSArrayBufferView* source, size_t relative_byte_offset, size_t byte_length,
    WTF::ASCIILiteral name)
{
    if (arrayBufferViewIsUnavailable(source)) {
        JSC::throwVMTypeError(global_object, scope, WTF::makeString(name, " must not be detached or out of bounds"_s));
        return nullptr;
    }
    const size_t source_length = source->byteLength();
    if (relative_byte_offset > source_length || byte_length > source_length - relative_byte_offset) {
        JSC::throwVMRangeError(global_object, scope, WTF::makeString(name, " range is out of bounds"_s));
        return nullptr;
    }
    if (source->isShared() || source->isResizableOrGrowableShared()) {
        JSC::throwVMTypeError(
            global_object, scope, WTF::makeString(name, " must use a fixed-length non-shared ArrayBuffer"_s));
        return nullptr;
    }

    const auto type = JSC::typedArrayType(source->type());
    if (type == JSC::NotTypedArray) {
        JSC::throwVMTypeError(global_object, scope, WTF::makeString(name, " must be an ArrayBufferView"_s));
        return nullptr;
    }

    JSC::JSArrayBuffer* js_buffer = source->unsharedJSBuffer(global_object);
    RETURN_IF_EXCEPTION(scope, nullptr);
    auto* raw_buffer = js_buffer ? js_buffer->impl() : nullptr;
    if (!raw_buffer || raw_buffer->isDetached() || !raw_buffer->isDetachable()) {
        JSC::throwVMTypeError(global_object, scope, WTF::makeString(name, " buffer cannot be transferred"_s));
        return nullptr;
    }

    const size_t byte_offset = source->byteOffset() + relative_byte_offset;
    JSC::ArrayBufferContents transferred_contents;
    if (!raw_buffer->transferTo(global_object->vm(), transferred_contents)) {
        JSC::throwVMTypeError(global_object, scope, WTF::makeString(name, " buffer could not be transferred"_s));
        return nullptr;
    }

    RefPtr<JSC::ArrayBuffer> transferred_buffer = JSC::ArrayBuffer::create(WTF::move(transferred_contents));
    switch (type) {
    case JSC::TypeInt8:
        return createTransferredTypedArrayView<JSC::JSInt8Array>(
            global_object, scope, WTF::move(transferred_buffer), byte_offset, byte_length, name);
    case JSC::TypeUint8:
        return createTransferredTypedArrayView<JSC::JSUint8Array>(
            global_object, scope, WTF::move(transferred_buffer), byte_offset, byte_length, name);
    case JSC::TypeUint8Clamped:
        return createTransferredTypedArrayView<JSC::JSUint8ClampedArray>(
            global_object, scope, WTF::move(transferred_buffer), byte_offset, byte_length, name);
    case JSC::TypeInt16:
        return createTransferredTypedArrayView<JSC::JSInt16Array>(
            global_object, scope, WTF::move(transferred_buffer), byte_offset, byte_length, name);
    case JSC::TypeUint16:
        return createTransferredTypedArrayView<JSC::JSUint16Array>(
            global_object, scope, WTF::move(transferred_buffer), byte_offset, byte_length, name);
    case JSC::TypeInt32:
        return createTransferredTypedArrayView<JSC::JSInt32Array>(
            global_object, scope, WTF::move(transferred_buffer), byte_offset, byte_length, name);
    case JSC::TypeUint32:
        return createTransferredTypedArrayView<JSC::JSUint32Array>(
            global_object, scope, WTF::move(transferred_buffer), byte_offset, byte_length, name);
    case JSC::TypeFloat16:
        return createTransferredTypedArrayView<JSC::JSFloat16Array>(
            global_object, scope, WTF::move(transferred_buffer), byte_offset, byte_length, name);
    case JSC::TypeFloat32:
        return createTransferredTypedArrayView<JSC::JSFloat32Array>(
            global_object, scope, WTF::move(transferred_buffer), byte_offset, byte_length, name);
    case JSC::TypeFloat64:
        return createTransferredTypedArrayView<JSC::JSFloat64Array>(
            global_object, scope, WTF::move(transferred_buffer), byte_offset, byte_length, name);
    case JSC::TypeBigInt64:
        return createTransferredTypedArrayView<JSC::JSBigInt64Array>(
            global_object, scope, WTF::move(transferred_buffer), byte_offset, byte_length, name);
    case JSC::TypeBigUint64:
        return createTransferredTypedArrayView<JSC::JSBigUint64Array>(
            global_object, scope, WTF::move(transferred_buffer), byte_offset, byte_length, name);
    case JSC::TypeDataView: {
        auto* view
            = JSC::JSDataView::create(global_object, global_object->typedArrayStructure(JSC::TypeDataView, false),
                WTF::move(transferred_buffer), byte_offset, std::optional<size_t> { byte_length });
        RETURN_IF_EXCEPTION(scope, nullptr);
        return view;
    }
    case JSC::NotTypedArray:
        break;
    }

    JSC::throwVMTypeError(global_object, scope, WTF::makeString(name, " has unsupported view type"_s));
    return nullptr;
}

JSC::JSArrayBufferView* requireArrayBufferView(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue value, WTF::ASCIILiteral name)
{
    auto* view = dynamicDowncast<JSC::JSArrayBufferView>(value);
    if (!view) {
        JSC::throwVMTypeError(global_object, scope, WTF::makeString(name, " must be an ArrayBufferView"_s));
        return nullptr;
    }
    if (arrayBufferViewIsUnavailable(view)) {
        JSC::throwVMTypeError(global_object, scope, WTF::makeString(name, " must not be detached or out of bounds"_s));
        return nullptr;
    }
    return view;
}

std::span<uint8_t> mutableViewBytes(JSC::JSArrayBufferView* view) { return mutableArrayBufferViewBytes(view); }

std::span<const uint8_t> viewBytes(JSC::JSArrayBufferView* view) { return arrayBufferViewBytes(view); }

bool viewRangeIsInside(JSC::JSArrayBufferView* inner, JSC::JSArrayBufferView* outer)
{
    if (arrayBufferViewIsUnavailable(inner) || arrayBufferViewIsUnavailable(outer))
        return false;
    const auto inner_start = reinterpret_cast<uintptr_t>(inner->vector());
    const auto outer_start = reinterpret_cast<uintptr_t>(outer->vector());
    const size_t inner_length = inner->byteLength();
    const size_t outer_length = outer->byteLength();
    if (inner_start < outer_start)
        return false;
    const uintptr_t inner_delta = inner_start - outer_start;
    if (inner_delta > outer_length)
        return false;
    return inner_length <= outer_length - static_cast<size_t>(inner_delta);
}

bool viewSharesBuffer(JSC::JSArrayBufferView* left, JSC::JSArrayBufferView* right)
{
    if (arrayBufferViewIsUnavailable(left) || arrayBufferViewIsUnavailable(right))
        return false;
    auto* left_buffer = left->possiblySharedBuffer();
    auto* right_buffer = right->possiblySharedBuffer();
    return left_buffer && left_buffer == right_buffer;
}

bool valueIsCallable(JSValue value)
{
    if (!value.isCell())
        return false;
    return JSC::getCallData(value).type != JSC::CallData::Type::None;
}

bool createDeferredPromise(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue& out_promise,
    ColloPromiseDeferred*& out_deferred)
{
    out_promise = JSC::jsUndefined();
    out_deferred = nullptr;
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    ColloStatus status
        = Collo::createPromiseDeferred(&collo_global->owner(), global_object, &out_promise, &out_deferred);
    if (status == COLLO_STATUS_OK)
        return true;
    if (status == COLLO_STATUS_OUT_OF_MEMORY)
        JSC::throwOutOfMemoryError(global_object, scope);
    else
        JSC::throwVMTypeError(global_object, scope, "failed to create stream promise"_s);
    return false;
}

void settleDeferred(
    JSC::JSGlobalObject* global_object, ColloPromiseDeferred*& deferred, JSC::JSValue value, bool is_rejection)
{
    if (!deferred)
        return;
    auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
    ColloValue* exception = nullptr;
    Collo::settlePromiseDeferred(&collo_global->owner(), deferred, value, is_rejection, &exception);
    if (exception)
        Collo::releaseValueHandle(exception);
    collo_promise_deferred_release(deferred);
    deferred = nullptr;
}

bool createJSDeferredPromise(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSDeferredPromise& out)
{
    out = {};
    auto data = JSC::JSPromise::createDeferredData(global_object, global_object->promiseConstructor());
    if (data.promise && data.resolve && data.reject) {
        out.promise = data.promise;
        out.resolve = data.resolve;
        out.reject = data.reject;
        return true;
    }
    JSC::throwOutOfMemoryError(global_object, scope);
    return false;
}

void settleJSDeferredPromise(JSC::JSGlobalObject* global_object, JSC::JSValue callback, JSC::JSValue value)
{
    auto* callback_object = callback.isObject() ? callback.getObject() : nullptr;
    RELEASE_ASSERT(callback_object);
    auto call_data = JSC::getCallData(callback_object);
    RELEASE_ASSERT(call_data.type != JSC::CallData::Type::None);

    JSC::MarkedArgumentBuffer arguments;
    arguments.append(value);
    RELEASE_ASSERT(!arguments.hasOverflowed());

    auto& vm = global_object->vm();
    auto scope = DECLARE_TOP_EXCEPTION_SCOPE(vm);
    JSC::call(global_object, callback_object, call_data, JSC::jsUndefined(), arguments);
    if (scope.exception())
        scope.clearExceptionExceptTermination();
}

JSC::JSObject* createReadResult(JSC::JSGlobalObject* global_object, JSC::JSValue value, bool done)
{
    auto& vm = global_object->vm();
    JSC::Strong<JSC::Unknown> protected_value(vm, value);
    auto* object = JSC::constructEmptyObject(global_object, global_object->objectPrototype(), 2);
    object->putDirect(vm, vm.propertyNames->value, value);
    object->putDirect(vm, vm.propertyNames->done, JSC::jsBoolean(done));
    return object;
}

JSC_DEFINE_HOST_FUNCTION(resolveUndefinedCallback, (JSC::JSGlobalObject*, JSC::CallFrame*))
{
    return JSValue::encode(JSC::jsUndefined());
}

JSC_DEFINE_HOST_FUNCTION(rethrowCallback, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
{
    auto& vm = global_object->vm();
    auto scope = DECLARE_THROW_SCOPE(vm);
    return JSValue::encode(JSC::throwException(global_object, scope, call_frame->argument(0)));
}

EncodedJSValue promiseThenUndefined(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
{
    auto* promise = dynamicDowncast<JSC::JSPromise>(value);
    if (!promise)
        return resolvedPromise(global_object, JSC::jsUndefined());

    auto& vm = global_object->vm();
    auto* result_promise = JSC::JSPromise::create(vm, global_object->promiseStructure());
    auto* fulfilled = JSC::JSFunction::create(vm, global_object, 1, "ReadableStream settle undefined"_s,
        resolveUndefinedCallback, JSC::ImplementationVisibility::Public);
    promise->performPromiseThen(vm, global_object, fulfilled, JSC::jsUndefined(), result_promise);
    RETURN_IF_EXCEPTION(scope, {});
    return JSValue::encode(result_promise);
}

EncodedJSValue resolvedReadResult(JSC::JSGlobalObject* global_object, JSC::JSValue value, bool done)
{
    return resolvedPromise(global_object, createReadResult(global_object, value, done));
}

JSValue propertyOrUndefined(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* object, WTF::ASCIILiteral name)
{
    JSValue value = object->getIfPropertyExists(global_object, JSC::Identifier::fromString(global_object->vm(), name));
    RETURN_IF_EXCEPTION(scope, {});
    if (value.isEmpty())
        return JSC::jsUndefined();
    return value;
}

bool normalizeOptionalCallback(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue& value, WTF::ASCIILiteral name)
{
    if (value.isUndefined() || value.isNull()) {
        value = JSC::jsUndefined();
        return true;
    }
    if (valueIsCallable(value))
        return true;
    JSC::throwException(
        global_object, scope, JSC::createTypeError(global_object, WTF::makeString(name, " must be callable"_s)));
    return false;
}

bool strictCallbackPropertyOrUndefined(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSC::JSObject* object, WTF::ASCIILiteral property_name, WTF::ASCIILiteral error_name, JSValue& out)
{
    JSValue value
        = object->getIfPropertyExists(global_object, JSC::Identifier::fromString(global_object->vm(), property_name));
    RETURN_IF_EXCEPTION(scope, false);
    // Web IDL dictionary conversion treats an explicitly-undefined member the
    // same as a missing one.
    if (value.isEmpty() || value.isUndefined()) {
        out = JSC::jsUndefined();
        return true;
    }
    if (valueIsCallable(value)) {
        out = value;
        return true;
    }
    JSC::throwException(
        global_object, scope, JSC::createTypeError(global_object, WTF::makeString(error_name, " must be callable"_s)));
    return false;
}

// Serves a byte range as a readable stream's native source, one chunk_size
// piece per pull. Every pull copies into a new Uint8Array, so script never
// writes the storage and tee branches can share one ColloSharedBytes.
class BufferedBytesSource final : public ReadableStreamNativeSource {
public:
    static constexpr size_t chunk_size = 64 * 1024;

    static WTF::RefPtr<BufferedBytesSource> create(std::span<const uint8_t> bytes)
    {
        auto storage = ColloSharedBytes::copy(bytes);
        if (!storage)
            return nullptr;
        return create(storage.releaseNonNull(), 0, bytes.size());
    }

    static WTF::RefPtr<BufferedBytesSource> create(WTF::Ref<ColloSharedBytes>&& bytes, size_t offset, size_t size)
    {
        void* storage = nullptr;
        if (!WTF::tryFastMalloc(sizeof(BufferedBytesSource)).getValue(storage))
            return nullptr;
        if (offset > bytes->size())
            size = 0;
        else
            size = std::min(size, bytes->size() - offset);
        auto* source = new (NotNull, storage) BufferedBytesSource(WTF::move(bytes), offset, size);
        return adoptRef(*source);
    }

    EncodedJSValue pull(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope) override
    {
        if (!m_bytes || m_position >= m_size)
            return resolvedReadResult(global_object, JSC::jsUndefined(), true);
        size_t length = std::min(chunk_size, m_size - m_position);
        auto* value = createUint8ArrayCopy(global_object, scope, m_bytes->slice(m_offset + m_position, length));
        RETURN_IF_EXCEPTION(scope, {});
        if (!value)
            return {};
        m_position += length;
        if (m_position >= m_size) {
            m_bytes = nullptr;
            m_position = 0;
            m_offset = 0;
            m_size = 0;
        }
        return resolvedReadResult(global_object, value, false);
    }

    EncodedJSValue cancel(JSC::JSGlobalObject* global_object, JSC::ThrowScope&, JSValue) override
    {
        m_bytes = nullptr;
        m_position = 0;
        m_offset = 0;
        m_size = 0;
        return resolvedPromise(global_object, JSC::jsUndefined());
    }

    bool tee(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        WTF::RefPtr<ReadableStreamNativeSource>& out_first,
        WTF::RefPtr<ReadableStreamNativeSource>& out_second) override
    {
        if (!m_bytes || m_position >= m_size) {
            out_first = createReadableStreamNativeSourceFromBytes({});
            out_second = createReadableStreamNativeSourceFromBytes({});
            if (out_first && out_second)
                return true;
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }

        const size_t remaining_offset = m_offset + m_position;
        const size_t remaining_size = m_size - m_position;
        auto first = create(WTF::Ref<ColloSharedBytes> { *m_bytes }, remaining_offset, remaining_size);
        if (!first) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        auto second = create(WTF::Ref<ColloSharedBytes> { *m_bytes }, remaining_offset, remaining_size);
        if (!second) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        out_first = first.releaseNonNull();
        out_second = second.releaseNonNull();
        m_bytes = nullptr;
        m_position = 0;
        m_offset = 0;
        m_size = 0;
        return true;
    }

    bool appendRemainingBytes(WTF::Vector<uint8_t>& out) override
    {
        if (!m_bytes || m_position >= m_size) {
            m_bytes = nullptr;
            m_position = 0;
            m_offset = 0;
            m_size = 0;
            return true;
        }
        if (!m_bytes->appendTo(out, m_offset + m_position, m_size - m_position))
            return false;
        m_bytes = nullptr;
        m_position = 0;
        m_offset = 0;
        m_size = 0;
        return true;
    }

    bool appendRemainingBytes(
        WTF::Vector<uint8_t>& out, size_t max_size, bool& out_exceeds_limit, bool& out_supported) override
    {
        out_exceeds_limit = false;
        out_supported = true;
        if (!m_bytes || m_position >= m_size) {
            m_bytes = nullptr;
            m_position = 0;
            m_offset = 0;
            m_size = 0;
            return true;
        }
        auto remaining = m_bytes->slice(m_offset + m_position, m_size - m_position);
        if (remaining.size() > max_size - std::min(out.size(), max_size)) {
            out_exceeds_limit = true;
            return false;
        }
        if (!out.tryAppend(remaining))
            return false;
        m_bytes = nullptr;
        m_position = 0;
        m_offset = 0;
        m_size = 0;
        return true;
    }

private:
    BufferedBytesSource(WTF::Ref<ColloSharedBytes>&& bytes, size_t offset, size_t size)
        : m_bytes(WTF::move(bytes))
        , m_offset(offset)
        , m_size(size)
    {
    }

    WTF::RefPtr<ColloSharedBytes> m_bytes;
    size_t m_offset { 0 };
    size_t m_size { 0 };
    size_t m_position { 0 };
};

WTF::RefPtr<ReadableStreamNativeSource> createReadableStreamNativeSourceFromBytes(std::span<const uint8_t> bytes)
{
    return BufferedBytesSource::create(bytes);
}

WTF::RefPtr<ReadableStreamNativeSource> createReadableStreamNativeSourceFromSharedBytes(
    WTF::Ref<ColloSharedBytes>&& bytes, size_t offset, size_t size)
{
    return BufferedBytesSource::create(WTF::move(bytes), offset, size);
}

} // namespace Collo::HostFunctions
