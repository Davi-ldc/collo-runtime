// The ABI constructors for an ArrayBuffer, a Uint8Array or a Blob holding a copy of bytes from Zig, which settles
// the arrayBuffer(), bytes() and blob() promises of fetch response bodies and lazy request bodies with them. The
// bytes are borrowed only for the call, and the returned handle follows abi.h's ownership rules. Runs on the VM
// thread.

#include "host_functions/server/fetch/body_utils.h"

#include <JavaScriptCore/JSCInlines.h>

namespace Collo::HostFunctions {
namespace {

    std::span<const uint8_t> bufferSpan(ColloBuffer buffer)
    {
        if (!buffer.ptr || buffer.len == 0)
            return {};
        return { buffer.ptr, buffer.len };
    }

    ColloStatus makeCopiedBodyValue(ColloVm* vm, ColloBuffer bytes, ColloString type, BodyByteConsumer consumer,
        ColloValue** out_value, ColloValue** out_exception)
    {
        if (out_value)
            *out_value = nullptr;
        Collo::clearOutException(out_exception);
        if (!vm || !vm->isReady() || !out_value || !out_exception || (bytes.len != 0 && !bytes.ptr))
            return COLLO_STATUS_INVALID_ARGUMENT;

        JSC::JSLockHolder locker(*vm->vm);
        auto scope = DECLARE_THROW_SCOPE(*vm->vm);
        JSC::JSValue value;
        switch (consumer) {
        case BodyByteConsumer::ArrayBuffer:
            value = createArrayBufferCopy(vm->global_object, scope, bufferSpan(bytes));
            break;
        case BodyByteConsumer::Bytes:
            value = createBodyUint8ArrayCopy(vm->global_object, scope, bufferSpan(bytes));
            break;
        case BodyByteConsumer::Blob: {
            WTF::String blob_type;
            if (Collo::stringToWTFString(type, blob_type) != COLLO_STATUS_OK)
                return COLLO_STATUS_INVALID_ARGUMENT;
            WTF::Vector<uint8_t> copied;
            if (!copied.tryAppend(bufferSpan(bytes)))
                return COLLO_STATUS_OUT_OF_MEMORY;
            value = JSColloBlob::create(*vm->vm, vm->global_object->blobStructure(), WTF::move(copied),
                normalizeBlobType(WTF::move(blob_type)));
            break;
        }
        }
        if (scope.exception())
            return consumeExceptionStatus(vm, scope, out_exception);
        if (!value)
            return COLLO_STATUS_OUT_OF_MEMORY;
        return Collo::makeValueHandle(vm, value, out_value);
    }

} // namespace

extern "C" ColloStatus collo_array_buffer_new_copy(
    ColloVm* vm, ColloBuffer bytes, ColloValue** out_value, ColloValue** out_exception)
{
    return makeCopiedBodyValue(vm, bytes, {}, BodyByteConsumer::ArrayBuffer, out_value, out_exception);
}

extern "C" ColloStatus collo_uint8_array_new_copy(
    ColloVm* vm, ColloBuffer bytes, ColloValue** out_value, ColloValue** out_exception)
{
    return makeCopiedBodyValue(vm, bytes, {}, BodyByteConsumer::Bytes, out_value, out_exception);
}

extern "C" ColloStatus collo_blob_new_copy(
    ColloVm* vm, ColloBuffer bytes, ColloString type, ColloValue** out_value, ColloValue** out_exception)
{
    return makeCopiedBodyValue(vm, bytes, type, BodyByteConsumer::Blob, out_value, out_exception);
}

} // namespace Collo::HostFunctions
