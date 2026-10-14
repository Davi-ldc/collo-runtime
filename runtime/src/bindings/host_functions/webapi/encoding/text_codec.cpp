// TextEncoder and TextDecoder from the WHATWG Encoding Standard, and the installer of all four Encoding Standard
// interfaces, run on the VM thread. A TextEncoder holds no state. A TextDecoder holds its TextDecoderCommon by value,
// which owns the decoder's carried bytes and, for an ICU encoding, its converter (`text_decoder_common.h`); the cell's
// destructor releases the converter when the collector sweeps it. The streams live in `codec_streams.cpp`, the
// encodings and labels in `encodings.cpp`, the decoders in `text_decoder_common.cpp` and the UTF-8 encoders in
// `utf8.cpp`.

#include "host_functions/webapi/encoding/text_codec.h"

#include "host_functions/webapi/buffer_source.h"
#include "host_functions/webapi/encoding/text_codec_private.h"
#include "host_functions/webapi/encoding/text_decoder_common.h"
#include "host_functions/webapi/encoding/utf8.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/ExceptionHelpers.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSDestructibleObject.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSGenericTypedArrayViewInlines.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/WTFString.h>

namespace Collo::HostFunctions {
namespace {

    using JSC::EncodedJSValue;
    using JSC::JSValue;
    using WTF::String;
    // CREATE_METHOD_TABLE names JSC's JSCastingHelpers without qualification.
    namespace JSCastingHelpers = JSC::JSCastingHelpers;

    // Holds no state, so the cell needs no destructor and lives in the heap's plain cell space.
    class JSColloTextEncoder final : public JSC::JSNonFinalObject {
        using Base = JSC::JSNonFinalObject;

    public:
        template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
        {
            return &vm.cellSpace();
        }

        static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSValue prototype)
        {
            return JSC::Structure::create(
                vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
        }

        static JSColloTextEncoder* create(JSC::VM& vm, JSC::Structure* structure)
        {
            auto* object = new (NotNull, JSC::allocateCell<JSColloTextEncoder>(vm)) JSColloTextEncoder(vm, structure);
            object->finishCreation(vm);
            return object;
        }

        DECLARE_INFO;

    private:
        JSColloTextEncoder(JSC::VM& vm, JSC::Structure* structure)
            : Base(vm, structure)
        {
        }

        void finishCreation(JSC::VM& vm)
        {
            Base::finishCreation(vm);
            ASSERT(inherits(info()));
        }
    };

    class JSColloTextDecoder final : public JSC::JSDestructibleObject {
        using Base = JSC::JSDestructibleObject;

    public:
        template <typename CellType, JSC::SubspaceAccess> static JSC::CompleteSubspace* subspaceFor(JSC::VM& vm)
        {
            return &vm.destructibleObjectSpace();
        }

        static JSC::Structure* createStructure(JSC::VM& vm, JSC::JSGlobalObject* global_object, JSValue prototype)
        {
            return JSC::Structure::create(
                vm, global_object, prototype, JSC::TypeInfo(JSC::ObjectType, StructureFlags), info());
        }

        static JSColloTextDecoder* create(JSC::VM& vm, JSC::Structure* structure, TextDecoderCommon&& common)
        {
            auto* object = new (NotNull, JSC::allocateCell<JSColloTextDecoder>(vm))
                JSColloTextDecoder(vm, structure, WTF::move(common));
            object->finishCreation(vm);
            return object;
        }

        static void destroy(JSC::JSCell* cell) { static_cast<JSColloTextDecoder*>(cell)->~JSColloTextDecoder(); }

        DECLARE_INFO;

        TextDecoderCommon& common() { return m_common; }

    private:
        JSColloTextDecoder(JSC::VM& vm, JSC::Structure* structure, TextDecoderCommon&& common)
            : Base(vm, structure)
            , m_common(WTF::move(common))
        {
        }

        ~JSColloTextDecoder() = default;

        void finishCreation(JSC::VM& vm)
        {
            Base::finishCreation(vm);
            ASSERT(inherits(info()));
        }

        TextDecoderCommon m_common;
    };

    const JSC::ClassInfo JSColloTextEncoder::s_info
        = { "TextEncoder"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloTextEncoder) };
    const JSC::ClassInfo JSColloTextDecoder::s_info
        = { "TextDecoder"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloTextDecoder) };

    static JSColloTextEncoder* requireTextEncoder(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
    {
        if (auto* encoder = dynamicDowncast<JSColloTextEncoder>(value))
            return encoder;
        JSC::throwVMTypeError(global_object, scope, "TextEncoder method called on incompatible receiver"_s);
        return nullptr;
    }

    static JSColloTextDecoder* requireTextDecoder(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
    {
        if (auto* decoder = dynamicDowncast<JSColloTextDecoder>(value))
            return decoder;
        JSC::throwVMTypeError(global_object, scope, "TextDecoder method called on incompatible receiver"_s);
        return nullptr;
    }

    // The call of every interface object `installTextCodecInterface` defines: an interface object must be constructed.
    JSC_DEFINE_HOST_FUNCTION(
        textCodecConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* constructor = uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee());
        return JSC::throwVMTypeError(
            global_object, scope, WTF::makeString(constructor->name(vm), " constructor requires 'new'"_s));
    }

    JSC_DEFINE_HOST_FUNCTION(
        textEncoderConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* structure = textCodecStructureForNewTarget(global_object, scope, call_frame,
            uncheckedDowncast<Collo::GlobalObject>(global_object)->textEncoderStructure());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSColloTextEncoder::create(vm, structure));
    }

    JSC_DEFINE_HOST_FUNCTION(
        textDecoderConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto common = TextDecoderCommon::create(global_object, scope, call_frame->argument(0), call_frame->argument(1));
        RETURN_IF_EXCEPTION(scope, {});
        ASSERT(common);
        auto* structure = textCodecStructureForNewTarget(global_object, scope, call_frame,
            uncheckedDowncast<Collo::GlobalObject>(global_object)->textDecoderStructure());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSColloTextDecoder::create(vm, structure, WTF::move(*common)));
    }

    JSC_DEFINE_HOST_FUNCTION(textEncoderGetEncoding, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        requireTextEncoder(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsString(vm, String("utf-8"_s)));
    }

    JSC_DEFINE_HOST_FUNCTION(textDecoderGetEncoding, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* decoder = requireTextDecoder(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsString(vm, String(encodingSpec(decoder->common().encoding()).name)));
    }

    JSC_DEFINE_HOST_FUNCTION(textDecoderGetFatal, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* decoder = requireTextDecoder(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsBoolean(decoder->common().fatal()));
    }

    JSC_DEFINE_HOST_FUNCTION(textDecoderGetIgnoreBOM, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* decoder = requireTextDecoder(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsBoolean(decoder->common().ignoreBOM()));
    }

    JSC_DEFINE_HOST_FUNCTION(textEncoderEncode, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        requireTextEncoder(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});

        // `input` defaults to the empty string. It is a USVString, whose conversion replaces every lone surrogate
        // with U+FFFD, which the encoder does by itself.
        String input = emptyString();
        if (!call_frame->argument(0).isUndefined()) {
            input = call_frame->argument(0).toWTFString(global_object);
            RETURN_IF_EXCEPTION(scope, {});
        }
        auto* array = createUninitializedUint8Array(global_object, scope, utf8EncodedLength(input));
        RETURN_IF_EXCEPTION(scope, {});
        encodeUtf8(input, mutableArrayBufferViewBytes(array));
        return JSValue::encode(array);
    }

    JSC_DEFINE_HOST_FUNCTION(textEncoderEncodeInto, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        requireTextEncoder(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        if (call_frame->argumentCount() < 2)
            return JSC::throwVMTypeError(
                global_object, scope, "TextEncoder.encodeInto requires source and destination"_s);

        // The source converts first, and its toString may detach the destination's buffer, so the destination's
        // bytes are read only after it.
        auto* input = call_frame->argument(0).toString(global_object);
        RETURN_IF_EXCEPTION(scope, {});
        auto* destination = dynamicDowncast<JSC::JSUint8Array>(call_frame->argument(1));
        if (!destination)
            return JSC::throwVMTypeError(
                global_object, scope, "TextEncoder.encodeInto destination must be a Uint8Array"_s);

        Utf8EncodeIntoResult result;
        if (!destination->isDetached() && !destination->isOutOfBounds() && destination->byteLength()) {
            auto view = input->view(global_object);
            RETURN_IF_EXCEPTION(scope, {});
            result = encodeUtf8Into(view, mutableArrayBufferViewBytes(destination));
        }

        auto* object = JSC::constructEmptyObject(global_object, global_object->objectPrototype(), 2);
        object->putDirect(vm, JSC::Identifier::fromString(vm, "read"_s), JSC::jsNumber(result.read));
        object->putDirect(vm, JSC::Identifier::fromString(vm, "written"_s), JSC::jsNumber(result.written));
        return JSValue::encode(object);
    }

    JSC_DEFINE_HOST_FUNCTION(textDecoderDecode, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* decoder = requireTextDecoder(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});

        auto options_value = call_frame->argument(1);
        if (!options_value.isUndefinedOrNull() && !options_value.isObject())
            return JSC::throwVMTypeError(global_object, scope, "TextDecoder.decode options must be an object"_s);
        const bool stream = decoderOptionBoolean(global_object, scope, options_value, "stream"_s);
        RETURN_IF_EXCEPTION(scope, {});

        // The bytes are read after the options, whose getters may run JavaScript that detaches the input's buffer.
        WTF::Vector<uint8_t> snapshot;
        std::span<const uint8_t> bytes;
        auto input = call_frame->argument(0);
        if (!input.isUndefinedOrNull()) {
            decoderInputBytes(global_object, scope, input,
                "TextDecoder.decode input must be an ArrayBuffer or ArrayBufferView"_s, snapshot, bytes);
            RETURN_IF_EXCEPTION(scope, {});
        }

        auto decoded = decoder->common().decode(global_object, scope, bytes, stream);
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsString(vm, decoded));
    }

} // namespace

JSC::Structure* textCodecStructureForNewTarget(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame, JSC::Structure* base)
{
    auto* new_target = call_frame->newTarget().getObject();
    if (!new_target || new_target == call_frame->jsCallee())
        return base;
    auto* structure = JSC::InternalFunction::createSubclassStructure(global_object, new_target, base);
    RETURN_IF_EXCEPTION(scope, nullptr);
    return structure;
}

JSC::JSFunction* installTextCodecInterface(Collo::GlobalObject* global_object, JSC::VM& vm, WTF::ASCIILiteral name,
    unsigned length, JSC::NativeFunction construct, JSC::JSObject* prototype)
{
    auto* constructor = JSC::JSFunction::create(vm, global_object, length, name, textCodecConstructorCall,
        JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, construct, nullptr);
    constructor->putDirect(vm, vm.propertyNames->prototype, prototype,
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
    prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol, JSC::jsString(vm, String(name)),
        JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);
    prototype->putDirect(
        vm, vm.propertyNames->constructor, constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    global_object->putDirect(vm, JSC::Identifier::fromString(vm, name), constructor,
        static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
    return constructor;
}

JSC::JSUint8Array* createUninitializedUint8Array(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, size_t length)
{
    auto* structure = global_object->typedArrayStructureWithTypedArrayType<JSC::TypeUint8>();
    auto* array = JSC::JSUint8Array::createUninitialized(global_object, structure, length);
    RETURN_IF_EXCEPTION(scope, nullptr);
    return array;
}

void installWebApiTextCodec(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    constexpr unsigned enumerableAccessor = static_cast<unsigned>(JSC::PropertyAttribute::Accessor);
    constexpr unsigned enumerableFunction = static_cast<unsigned>(JSC::PropertyAttribute::None);

    auto* encoder_prototype = JSC::constructEmptyObject(global_object, global_object->objectPrototype());
    putWebApiAccessor(
        global_object, encoder_prototype, vm, "encoding"_s, textEncoderGetEncoding, nullptr, enumerableAccessor);
    putWebApiFunction(global_object, encoder_prototype, vm, "encode"_s, 0, textEncoderEncode, enumerableFunction);
    putWebApiFunction(
        global_object, encoder_prototype, vm, "encodeInto"_s, 2, textEncoderEncodeInto, enumerableFunction);
    auto* encoder_constructor = installTextCodecInterface(
        global_object, vm, "TextEncoder"_s, 0, textEncoderConstructorConstruct, encoder_prototype);

    auto* decoder_prototype = JSC::constructEmptyObject(global_object, global_object->objectPrototype());
    putWebApiAccessor(
        global_object, decoder_prototype, vm, "encoding"_s, textDecoderGetEncoding, nullptr, enumerableAccessor);
    putWebApiAccessor(
        global_object, decoder_prototype, vm, "fatal"_s, textDecoderGetFatal, nullptr, enumerableAccessor);
    putWebApiAccessor(
        global_object, decoder_prototype, vm, "ignoreBOM"_s, textDecoderGetIgnoreBOM, nullptr, enumerableAccessor);
    putWebApiFunction(global_object, decoder_prototype, vm, "decode"_s, 0, textDecoderDecode, enumerableFunction);
    auto* decoder_constructor = installTextCodecInterface(
        global_object, vm, "TextDecoder"_s, 0, textDecoderConstructorConstruct, decoder_prototype);

    auto streams = installTextCodecStreams(global_object, vm);

    global_object->cacheTextCodecApi(encoder_constructor, encoder_prototype,
        JSColloTextEncoder::createStructure(vm, global_object, encoder_prototype), decoder_constructor,
        decoder_prototype, JSColloTextDecoder::createStructure(vm, global_object, decoder_prototype),
        streams.encoder_stream_constructor, streams.encoder_stream_prototype, streams.encoder_stream_structure,
        streams.decoder_stream_constructor, streams.decoder_stream_prototype, streams.decoder_stream_structure);
}

} // namespace Collo::HostFunctions
