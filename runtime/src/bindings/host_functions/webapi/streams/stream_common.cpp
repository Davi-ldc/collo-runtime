// Helpers every stream family shares: interface installation, buffer copies and transfers, promise and read-result
// plumbing, Web IDL argument conversion, the clone budget, the bytes of one chunk, and the native source that serves a
// byte buffer as a readable stream. Runs on the VM thread.

#include "host_functions/webapi/streams/stream_common_private.h"

#include "host_functions/webapi/dom/dom_exception.h"
#include "host_functions/webapi/limits.h"

namespace Collo::HostFunctions {

namespace {

    // Every stream interface's constructor called without new, and every construction of an interface without a public
    // constructor, ends here; the callee's name says which interface it was.
    JSC_DEFINE_HOST_FUNCTION(
        streamConstructorRequiresNew, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto name = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee())->name(vm);
        return JSC::throwVMTypeError(global_object, scope, WTF::makeString(name, " constructor requires 'new'"_s));
    }

    JSC_DEFINE_HOST_FUNCTION(
        streamConstructorNotPublic, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto name = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee())->name(vm);
        return JSC::throwVMTypeError(global_object, scope, WTF::makeString(name, " constructor is not public"_s));
    }

} // namespace

JSC::JSFunction* installStreamInterface(Collo::GlobalObject* global_object, JSC::VM& vm, WTF::ASCIILiteral name,
    unsigned length, JSC::JSObject* prototype, JSC::NativeFunction construct)
{
    auto* constructor = JSC::JSFunction::create(vm, global_object, length, WTF::String(name),
        construct ? streamConstructorRequiresNew : streamConstructorNotPublic, JSC::ImplementationVisibility::Public,
        JSC::NoIntrinsic, construct ? construct : streamConstructorNotPublic, nullptr);
    constructor->putDirect(vm, vm.propertyNames->prototype, prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    prototype->putDirect(
        vm, vm.propertyNames->constructor, constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol, JSC::jsString(vm, WTF::String(name)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);
    global_object->putDirect(vm, JSC::Identifier::fromString(vm, name), constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    return constructor;
}

JSC::JSUint8Array* createUint8ArrayCopy(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const uint8_t> bytes)
{
    auto* structure = global_object->typedArrayStructureWithTypedArrayType<JSC::TypeUint8>();
    auto* array = JSC::JSUint8Array::createUninitialized(global_object, structure, bytes.size());
    RETURN_IF_EXCEPTION(scope, nullptr);
    if (!bytes.empty())
        memcpySpan(mutableArrayBufferViewBytes(array), bytes);
    return array;
}

JSC::JSUint8Array* createUint8Array(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, size_t byte_length)
{
    auto* structure = global_object->typedArrayStructureWithTypedArrayType<JSC::TypeUint8>();
    auto* array = JSC::JSUint8Array::createUninitialized(global_object, structure, byte_length);
    RETURN_IF_EXCEPTION(scope, nullptr);
    if (byte_length)
        std::ranges::fill(mutableArrayBufferViewBytes(array), 0);
    return array;
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
    WTF::RefPtr<JSC::ArrayBuffer> retained_buffer(buffer);
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

// Detaches the source view's buffer and returns the transferred buffer, or throws as the transfer helpers describe.
static WTF::RefPtr<JSC::ArrayBuffer> transferViewBuffer(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
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

    JSC::ArrayBufferContents transferred_contents;
    if (!buffer->transferTo(global_object->vm(), transferred_contents)) {
        JSC::throwVMTypeError(global_object, scope, WTF::makeString(name, " buffer could not be transferred"_s));
        return nullptr;
    }
    return JSC::ArrayBuffer::create(WTF::move(transferred_contents));
}

JSC::JSUint8Array* transferArrayBufferViewRangeToUint8Array(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSC::JSArrayBufferView* source, size_t relative_byte_offset, size_t byte_length, WTF::ASCIILiteral name)
{
    // The view's offset is read before the transfer detaches it.
    const size_t byte_offset = arrayBufferViewIsUnavailable(source) ? 0 : source->byteOffset() + relative_byte_offset;
    auto transferred_buffer = transferViewBuffer(global_object, scope, source, relative_byte_offset, byte_length, name);
    RETURN_IF_EXCEPTION(scope, nullptr);
    auto* array = JSC::JSUint8Array::create(global_object, global_object->typedArrayStructure(JSC::TypeUint8, false),
        WTF::move(transferred_buffer), byte_offset, std::optional<size_t> { byte_length });
    RETURN_IF_EXCEPTION(scope, nullptr);
    return array;
}

template <typename View>
static JSC::JSArrayBufferView* createTransferredTypedArrayView(JSC::JSGlobalObject* global_object,
    JSC::ThrowScope& scope, WTF::RefPtr<JSC::ArrayBuffer>&& buffer, size_t byte_offset, size_t byte_length,
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
    const auto type = JSC::typedArrayType(source->type());
    if (type == JSC::NotTypedArray) {
        JSC::throwVMTypeError(global_object, scope, WTF::makeString(name, " must be an ArrayBufferView"_s));
        return nullptr;
    }
    // The view's offset is read before the transfer detaches it.
    const size_t byte_offset = source->byteOffset() + relative_byte_offset;
    auto transferred_buffer = transferViewBuffer(global_object, scope, source, relative_byte_offset, byte_length, name);
    RETURN_IF_EXCEPTION(scope, nullptr);
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

bool valueIsCallable(JSC::JSValue value)
{
    if (!value.isCell())
        return false;
    return JSC::getCallData(value).type != JSC::CallData::Type::None;
}

bool settleAndClearPromise(
    JSC::JSGlobalObject* global_object, JSC::WriteBarrier<JSC::JSPromise>& slot, JSC::JSValue value, bool is_rejection)
{
    auto* promise = slot.get();
    if (!promise)
        return noExceptionPending(global_object->vm());
    slot.clear();
    return Collo::settlePromise(promise, value, is_rejection);
}

bool ensurePromiseRejected(JSC::JSGlobalObject* global_object, const JSC::JSCell* owner,
    JSC::WriteBarrier<JSC::JSPromise>& slot, JSC::JSValue reason)
{
    auto* promise = slot.get();
    if (!promiseIsPending(promise)) {
        promise = Collo::newPromise(global_object);
        slot.set(global_object->vm(), owner, promise);
    }
    // Marked before the rejection, so the rejection tracker never reports it.
    promise->markAsHandled();
    return Collo::settlePromise(promise, reason, true);
}

JSC::JSPromise* promiseForCallbackCompletion(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue result)
{
    if (auto* exception = scope.exception()) {
        JSC::JSValue reason = exception->value();
        if (!scope.tryClearException())
            return nullptr;
        return JSC::JSPromise::rejectedPromise(global_object, reason);
    }
    auto* promise = promiseResolvedWith(global_object, result ? result : JSC::jsUndefined());
    RETURN_IF_EXCEPTION(scope, nullptr);
    return promise;
}

JSC::EncodedJSValue readResultPromise(JSC::JSGlobalObject* global_object, JSC::JSValue value, bool done)
{
    return resolvedPromise(global_object, readResult(global_object, value, done));
}

namespace {

    // An own data property, read from property storage so that no getter runs; the empty value when there is none.
    // Script can redefine a read result's property as an accessor before the stream reads it (a `then` getter on
    // Object.prototype runs while the read promise resolves). Such a slot holds the engine's GetterSetter or
    // CustomGetterSetter cell, which must never reach script, so it counts as absent.
    JSC::JSValue ownDataProperty(JSC::VM& vm, JSC::JSObject* object, JSC::PropertyName name)
    {
        unsigned attributes = 0;
        JSC::JSValue value = object->getDirect(vm, name, attributes);
        if (!value || (attributes & JSC::PropertyAttribute::AccessorOrCustomAccessorOrValue))
            return {};
        return value;
    }

} // namespace

bool readResultDone(JSC::JSGlobalObject* global_object, JSC::JSValue result, bool& out_done, JSC::JSValue& out_error)
{
    out_done = false;
    out_error = {};
    auto* object = result.getObject();
    if (!object) {
        out_error = JSC::createTypeError(global_object, "ReadableStream read result is not an object"_s);
        return false;
    }
    JSC::JSValue done = ownDataProperty(global_object->vm(), object, global_object->vm().propertyNames->done);
    if (!done) {
        out_error = JSC::createTypeError(global_object, "ReadableStream read result has no done property"_s);
        return false;
    }
    out_done = done.isBoolean() && done.asBoolean();
    return true;
}

JSC::JSValue readResultValue(JSC::JSGlobalObject* global_object, JSC::JSValue result)
{
    auto* object = result.getObject();
    if (!object)
        return JSC::jsUndefined();
    JSC::JSValue value = ownDataProperty(global_object->vm(), object, global_object->vm().propertyNames->value);
    return value ? value : JSC::jsUndefined();
}

bool strictCallbackPropertyOrUndefined(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    JSC::JSObject* object, WTF::ASCIILiteral property_name, WTF::ASCIILiteral error_name, JSC::JSValue& out)
{
    JSC::JSValue value
        = object->getIfPropertyExists(global_object, JSC::Identifier::fromString(global_object->vm(), property_name));
    RETURN_IF_EXCEPTION(scope, false);
    // Web IDL dictionary conversion treats an explicitly undefined member the same as a missing one.
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

// Members are read in lexicographic order (highWaterMark, then size), an undefined member counts as absent, and
// undefined or null converts to an empty dictionary. On success out_has_high_water_mark says whether highWaterMark was
// present, out_high_water_mark holds it as a number, and out_size holds the size callback or undefined. The range check
// is ExtractHighWaterMark, which the constructor steps run later through validateHighWaterMark. Throws a TypeError
// prefixed with context for a strategy that is not an object or a size that is not callable.
bool parseQueuingStrategy(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue strategy,
    WTF::ASCIILiteral context, bool& out_has_high_water_mark, double& out_high_water_mark, JSC::JSValue& out_size)
{
    out_has_high_water_mark = false;
    out_high_water_mark = 0;
    out_size = JSC::jsUndefined();
    if (strategy.isUndefinedOrNull())
        return true;
    if (!strategy.isObject()) {
        JSC::throwException(global_object, scope,
            JSC::createTypeError(global_object, WTF::makeString(context, " strategy must be an object"_s)));
        return false;
    }

    auto& vm = global_object->vm();
    auto* strategy_object = strategy.getObject();
    JSC::JSValue high_water_mark
        = strategy_object->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "highWaterMark"_s));
    RETURN_IF_EXCEPTION(scope, false);
    if (!high_water_mark.isEmpty() && !high_water_mark.isUndefined()) {
        out_high_water_mark = high_water_mark.toNumber(global_object);
        RETURN_IF_EXCEPTION(scope, false);
        out_has_high_water_mark = true;
    }

    JSC::JSValue size = strategy_object->getIfPropertyExists(global_object, JSC::Identifier::fromString(vm, "size"_s));
    RETURN_IF_EXCEPTION(scope, false);
    if (!size.isEmpty() && !size.isUndefined()) {
        if (!valueIsCallable(size)) {
            JSC::throwException(global_object, scope,
                JSC::createTypeError(global_object, WTF::makeString(context, " strategy size must be callable"_s)));
            return false;
        }
        out_size = size;
    }
    return true;
}

bool validateHighWaterMark(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, WTF::ASCIILiteral context,
    bool has_high_water_mark, double default_high_water_mark, double& high_water_mark)
{
    if (!has_high_water_mark) {
        high_water_mark = default_high_water_mark;
        return true;
    }
    if (std::isnan(high_water_mark) || high_water_mark < 0) {
        JSC::throwException(global_object, scope,
            JSC::createRangeError(
                global_object, WTF::makeString(context, " highWaterMark must be a non-negative number"_s)));
        return false;
    }
    return true;
}

JSC::Structure* streamStructureForNewTarget(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame, JSC::Structure* base)
{
    auto* new_target = call_frame->newTarget().getObject();
    auto* constructor = call_frame->jsCallee();
    if (!new_target || new_target == constructor)
        return base;
    auto* structure = JSC::InternalFunction::createSubclassStructure(global_object, new_target, base);
    RETURN_IF_EXCEPTION(scope, nullptr);
    return structure;
}

bool StreamCloneBudget::ensure(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, WTF::RefPtr<StreamCloneBudget>& budget)
{
    if (budget)
        return true;
    void* storage = nullptr;
    if (!WTF::tryFastMalloc(sizeof(StreamCloneBudget)).getValue(storage)) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }
    auto* created = new (NotNull, storage) StreamCloneBudget;
    budget = WTF::adoptRef(*created);
    return true;
}

bool StreamCloneBudget::checkRoom(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope) const
{
    if (m_clone_count < WebApiBodyCloneFanoutMax)
        return true;
    JSC::throwException(global_object, scope,
        createDOMException(global_object, DOMExceptionCode::QuotaExceededError,
            "clone count exceeds the limit for one body and its streams"_s));
    return false;
}

bool readableStreamChunkBytes(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSValue chunk, std::span<const uint8_t>& out)
{
    out = {};
    if (auto* view = dynamicDowncast<JSC::JSArrayBufferView>(chunk)) {
        if (!validateArrayBufferViewForCopy(
                global_object, scope, view, "ReadableStream chunk ArrayBufferView is detached or out of bounds"_s))
            return false;
        out = arrayBufferViewBytes(view);
        return true;
    }
    if (auto* array_buffer = dynamicDowncast<JSC::JSArrayBuffer>(chunk)) {
        if (!validateArrayBufferForCopy(global_object, scope, array_buffer,
                "ReadableStream chunk must be a fixed-length attached ArrayBuffer"_s))
            return false;
        out = arrayBufferBytes(array_buffer);
        return true;
    }
    JSC::throwVMTypeError(global_object, scope, readable_stream_chunk_type_message);
    return false;
}

// Serves a byte range as a readable stream's native source, one WebApiReadableStreamChunkBytes piece per pull. Each
// pull copies into a new Uint8Array, so script never writes the storage and tee branches share one ColloSharedBytes.
class BufferedBytesSource final : public ReadableStreamNativeSource {
public:
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

    ReadableStreamPull pull(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope) override
    {
        if (!m_bytes || m_position >= m_size)
            return ReadableStreamPull::done();
        const size_t length = std::min(WebApiReadableStreamChunkBytes, m_size - m_position);
        auto* value = createUint8ArrayCopy(global_object, scope, m_bytes->slice(m_offset + m_position, length));
        RETURN_IF_EXCEPTION(scope, ReadableStreamPull::threw());
        m_position += length;
        if (m_position >= m_size)
            drop();
        return ReadableStreamPull::withChunk(value);
    }

    JSC::EncodedJSValue cancel(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue) override
    {
        drop();
        return JSC::JSValue::encode(JSC::jsUndefined());
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
        auto second = create(WTF::Ref<ColloSharedBytes> { *m_bytes }, remaining_offset, remaining_size);
        if (!first || !second) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        out_first = first.releaseNonNull();
        out_second = second.releaseNonNull();
        drop();
        return true;
    }

    bool appendRemainingBytes(
        WTF::Vector<uint8_t>& out, size_t max_size, bool& out_exceeds_limit, bool& out_supported) override
    {
        out_exceeds_limit = false;
        out_supported = true;
        if (!m_bytes || m_position >= m_size) {
            drop();
            return true;
        }
        auto remaining = m_bytes->slice(m_offset + m_position, m_size - m_position);
        if (remaining.size() > max_size - std::min(out.size(), max_size)) {
            out_exceeds_limit = true;
            return false;
        }
        if (!out.tryAppend(remaining))
            return false;
        drop();
        return true;
    }

private:
    BufferedBytesSource(WTF::Ref<ColloSharedBytes>&& bytes, size_t offset, size_t size)
        : m_bytes(WTF::move(bytes))
        , m_offset(offset)
        , m_size(size)
    {
    }

    void drop()
    {
        m_bytes = nullptr;
        m_position = 0;
        m_offset = 0;
        m_size = 0;
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
