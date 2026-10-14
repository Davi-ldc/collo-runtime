// TextEncoderStream and TextDecoderStream from the WHATWG Encoding Standard, run on the VM thread. Each is a transform
// stream cell of its own kind (`streams/transform_stream.h`) whose native transformer holds the codec state; neither
// class keeps a cell, controller or JavaScript function of its own. The stream calls a transformer one method at a
// time, a write only once the previous write's output has all been produced, and close only after the last write's,
// so at most one chunk's output is ever pending, and the transformer holds no cell.
//
// A TextEncoderStream keeps a chunk as text and encodes it when the readable side asks for output, carrying a lead
// surrogate that ends a chunk into the next. A TextDecoderStream decodes each chunk as it is written, so a fatal
// decoder throws for the chunk that holds the error, and keeps the decoded text until it is read.

#include "host_functions/webapi/encoding/text_codec_private.h"

#include "host_functions/webapi/buffer_source.h"
#include "host_functions/webapi/encoding/text_decoder_common.h"
#include "host_functions/webapi/encoding/utf8.h"
#include "host_functions/webapi/streams/transform_stream.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/ExceptionHelpers.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSGenericTypedArrayViewInlines.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/ObjectConstructor.h>
#include <wtf/StdLibExtras.h>
#include <wtf/text/StringView.h>
#include <wtf/text/WTFString.h>

#include <unicode/utf16.h>
#include <unicode/utf8.h>

#include <array>
#include <optional>
#include <utility>

namespace Collo::HostFunctions {
namespace {

    using JSC::EncodedJSValue;
    using JSC::JSValue;
    using WTF::String;

    class TextEncoderStreamTransformer final : public TransformStreamNativeTransformer {
    public:
        static WTF::RefPtr<TextEncoderStreamTransformer> create()
        {
            void* storage = nullptr;
            if (!WTF::tryFastMalloc(sizeof(TextEncoderStreamTransformer)).getValue(storage))
                return nullptr;
            auto* transformer = new (NotNull, storage) TextEncoderStreamTransformer;
            return adoptRef(*transformer);
        }

        // The Encoding Standard's "encode and enqueue a chunk" up to the encoding itself: the chunk converts to a
        // string, a lead surrogate carried from the previous chunk pairs with a leading trail surrogate or becomes
        // U+FFFD, and a lead surrogate that ends the chunk is carried to the next.
        bool write(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue chunk) override
        {
            ASSERT(!hasPendingOutput());
            auto* input = chunk.toString(global_object);
            RETURN_IF_EXCEPTION(scope, false);
            String text = input->value(global_object);
            RETURN_IF_EXCEPTION(scope, false);

            unsigned start = 0;
            unsigned end = text.length();
            if (m_lead_surrogate && end) {
                UChar32 code_point = 0xfffd;
                if (U16_IS_TRAIL(text[0])) {
                    code_point = U16_GET_SUPPLEMENTARY(*m_lead_surrogate, text[0]);
                    start = 1;
                }
                size_t prefix_length = 0;
                U8_APPEND_UNSAFE(m_prefix.data(), prefix_length, code_point);
                m_prefix_length = static_cast<uint8_t>(prefix_length);
                m_lead_surrogate.reset();
            }
            if (end > start && U16_IS_LEAD(text[end - 1])) {
                m_lead_surrogate = text[end - 1];
                --end;
            }
            if (start < end) {
                m_text = WTF::move(text);
                m_text_start = start;
                m_text_end = end;
            }
            return true;
        }

        // A lead surrogate still carried when the writable side closes encodes as U+FFFD.
        bool close(JSC::JSGlobalObject*, JSC::ThrowScope&) override
        {
            ASSERT(!hasPendingOutput());
            if (m_lead_surrogate) {
                m_lead_surrogate.reset();
                m_prefix = { 0xef, 0xbf, 0xbd, 0 };
                m_prefix_length = 3;
            }
            return true;
        }

        bool hasPendingOutput() const override { return m_prefix_length || m_text_start < m_text_end; }

        // The whole chunk's bytes as one Uint8Array, as the standard enqueues them.
        JSValue produce(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope) override
        {
            auto text = WTF::StringView(m_text).substring(m_text_start, m_text_end - m_text_start);
            auto* array
                = createUninitializedUint8Array(global_object, scope, m_prefix_length + utf8EncodedLength(text));
            RETURN_IF_EXCEPTION(scope, {});
            auto bytes = mutableArrayBufferViewBytes(array);
            memcpySpan(bytes, std::span { m_prefix }.first(m_prefix_length));
            encodeUtf8(text, bytes.subspan(m_prefix_length));
            dropOutput();
            return array;
        }

        void release() override
        {
            dropOutput();
            m_lead_surrogate.reset();
        }

        size_t memoryCost() const override { return m_text.length() * (m_text.is8Bit() ? 1 : sizeof(char16_t)); }

    private:
        TextEncoderStreamTransformer() = default;

        void dropOutput()
        {
            m_text = String();
            m_text_start = 0;
            m_text_end = 0;
            m_prefix_length = 0;
        }

        // The pending output: the UTF-8 bytes of the code point a carried lead surrogate began, then code units
        // m_text_start to m_text_end of m_text, which hold no lead surrogate at their end.
        std::array<uint8_t, 4> m_prefix {};
        uint8_t m_prefix_length { 0 };
        String m_text;
        unsigned m_text_start { 0 };
        unsigned m_text_end { 0 };
        std::optional<char16_t> m_lead_surrogate;
    };

    class TextDecoderStreamTransformer final : public TransformStreamNativeTransformer {
    public:
        static WTF::RefPtr<TextDecoderStreamTransformer> create(TextDecoderCommon&& common)
        {
            void* storage = nullptr;
            if (!WTF::tryFastMalloc(sizeof(TextDecoderStreamTransformer)).getValue(storage))
                return nullptr;
            auto* transformer = new (NotNull, storage) TextDecoderStreamTransformer(WTF::move(common));
            return adoptRef(*transformer);
        }

        const TextDecoderCommon& common() const { return m_common; }

        bool write(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue chunk) override
        {
            ASSERT(!hasPendingOutput());
            WTF::Vector<uint8_t> snapshot;
            std::span<const uint8_t> bytes;
            if (!decoderInputBytes(global_object, scope, chunk,
                    "TextDecoderStream chunk must be an ArrayBuffer or ArrayBufferView"_s, snapshot, bytes))
                return false;
            auto decoded = m_common.decode(global_object, scope, bytes, true);
            RETURN_IF_EXCEPTION(scope, false);
            keepOutput(WTF::move(decoded));
            return true;
        }

        // Flushes the decoder: a sequence cut off at the end of the last chunk decodes as an error.
        bool close(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope) override
        {
            ASSERT(!hasPendingOutput());
            auto decoded = m_common.decode(global_object, scope, {}, false);
            RETURN_IF_EXCEPTION(scope, false);
            keepOutput(WTF::move(decoded));
            return true;
        }

        bool hasPendingOutput() const override { return !m_output.isNull(); }

        JSValue produce(JSC::JSGlobalObject* global_object, JSC::ThrowScope&) override
        {
            return JSC::jsString(global_object->vm(), std::exchange(m_output, String()));
        }

        void release() override
        {
            m_output = String();
            m_common.release();
        }

        size_t memoryCost() const override { return m_output.length() * (m_output.is8Bit() ? 1 : sizeof(char16_t)); }

    private:
        explicit TextDecoderStreamTransformer(TextDecoderCommon&& common)
            : m_common(WTF::move(common))
        {
        }

        // The standard enqueues decoded text only when it is not empty.
        void keepOutput(String&& decoded)
        {
            if (!decoded.isEmpty())
                m_output = WTF::move(decoded);
        }

        TextDecoderCommon m_common;
        // Null while no output is pending; never empty otherwise.
        String m_output;
    };

    static JSC::JSObject* requireCodecStream(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value,
        TransformStreamKind kind, WTF::ASCIILiteral message)
    {
        if (auto* stream = transformStreamOfKind(value, kind))
            return stream;
        JSC::throwVMTypeError(global_object, scope, message);
        return nullptr;
    }

    static JSC::JSObject* requireTextEncoderStream(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
    {
        return requireCodecStream(global_object, scope, value, TransformStreamKind::TextEncoderStream,
            "TextEncoderStream method called on incompatible receiver"_s);
    }

    static JSC::JSObject* requireTextDecoderStream(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
    {
        return requireCodecStream(global_object, scope, value, TransformStreamKind::TextDecoderStream,
            "TextDecoderStream method called on incompatible receiver"_s);
    }

    // The transformer's class is fixed by the stream's kind, which requireTextDecoderStream checked.
    static const TextDecoderCommon& textDecoderStreamCommon(JSC::JSObject* stream)
    {
        return static_cast<TextDecoderStreamTransformer*>(transformStreamNativeTransformer(stream))->common();
    }

    JSC_DEFINE_HOST_FUNCTION(
        textEncoderStreamConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* structure = textCodecStructureForNewTarget(global_object, scope, call_frame,
            uncheckedDowncast<Collo::GlobalObject>(global_object)->textEncoderStreamStructure());
        RETURN_IF_EXCEPTION(scope, {});
        auto transformer = TextEncoderStreamTransformer::create();
        if (!transformer)
            return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
        auto* stream = createNativeTransformStream(
            global_object, scope, structure, TransformStreamKind::TextEncoderStream, transformer.releaseNonNull());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(stream);
    }

    JSC_DEFINE_HOST_FUNCTION(
        textDecoderStreamConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto common = TextDecoderCommon::create(global_object, scope, call_frame->argument(0), call_frame->argument(1));
        RETURN_IF_EXCEPTION(scope, {});
        ASSERT(common);
        auto* structure = textCodecStructureForNewTarget(global_object, scope, call_frame,
            uncheckedDowncast<Collo::GlobalObject>(global_object)->textDecoderStreamStructure());
        RETURN_IF_EXCEPTION(scope, {});
        auto transformer = TextDecoderStreamTransformer::create(WTF::move(*common));
        if (!transformer)
            return JSValue::encode(JSC::throwOutOfMemoryError(global_object, scope));
        auto* stream = createNativeTransformStream(
            global_object, scope, structure, TransformStreamKind::TextDecoderStream, transformer.releaseNonNull());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(stream);
    }

    JSC_DEFINE_HOST_FUNCTION(
        textEncoderStreamGetEncoding, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        requireTextEncoderStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsString(vm, String("utf-8"_s)));
    }

    JSC_DEFINE_HOST_FUNCTION(
        textEncoderStreamGetReadable, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireTextEncoderStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(transformStreamReadable(stream));
    }

    JSC_DEFINE_HOST_FUNCTION(
        textEncoderStreamGetWritable, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireTextEncoderStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(transformStreamWritable(stream));
    }

    JSC_DEFINE_HOST_FUNCTION(
        textDecoderStreamGetEncoding, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireTextDecoderStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(
            JSC::jsString(vm, String(encodingSpec(textDecoderStreamCommon(stream).encoding()).name)));
    }

    JSC_DEFINE_HOST_FUNCTION(
        textDecoderStreamGetFatal, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireTextDecoderStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsBoolean(textDecoderStreamCommon(stream).fatal()));
    }

    JSC_DEFINE_HOST_FUNCTION(
        textDecoderStreamGetIgnoreBOM, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireTextDecoderStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsBoolean(textDecoderStreamCommon(stream).ignoreBOM()));
    }

    JSC_DEFINE_HOST_FUNCTION(
        textDecoderStreamGetReadable, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireTextDecoderStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(transformStreamReadable(stream));
    }

    JSC_DEFINE_HOST_FUNCTION(
        textDecoderStreamGetWritable, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireTextDecoderStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(transformStreamWritable(stream));
    }

} // namespace

TextCodecStreamsApi installTextCodecStreams(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    constexpr unsigned enumerableAccessor = static_cast<unsigned>(JSC::PropertyAttribute::Accessor);

    auto* encoder_prototype = JSC::constructEmptyObject(global_object, global_object->objectPrototype());
    putWebApiAccessor(
        global_object, encoder_prototype, vm, "encoding"_s, textEncoderStreamGetEncoding, nullptr, enumerableAccessor);
    putWebApiAccessor(
        global_object, encoder_prototype, vm, "readable"_s, textEncoderStreamGetReadable, nullptr, enumerableAccessor);
    putWebApiAccessor(
        global_object, encoder_prototype, vm, "writable"_s, textEncoderStreamGetWritable, nullptr, enumerableAccessor);
    auto* encoder_constructor = installTextCodecInterface(
        global_object, vm, "TextEncoderStream"_s, 0, textEncoderStreamConstructorConstruct, encoder_prototype);

    auto* decoder_prototype = JSC::constructEmptyObject(global_object, global_object->objectPrototype());
    putWebApiAccessor(
        global_object, decoder_prototype, vm, "encoding"_s, textDecoderStreamGetEncoding, nullptr, enumerableAccessor);
    putWebApiAccessor(
        global_object, decoder_prototype, vm, "fatal"_s, textDecoderStreamGetFatal, nullptr, enumerableAccessor);
    putWebApiAccessor(global_object, decoder_prototype, vm, "ignoreBOM"_s, textDecoderStreamGetIgnoreBOM, nullptr,
        enumerableAccessor);
    putWebApiAccessor(
        global_object, decoder_prototype, vm, "readable"_s, textDecoderStreamGetReadable, nullptr, enumerableAccessor);
    putWebApiAccessor(
        global_object, decoder_prototype, vm, "writable"_s, textDecoderStreamGetWritable, nullptr, enumerableAccessor);
    auto* decoder_constructor = installTextCodecInterface(
        global_object, vm, "TextDecoderStream"_s, 0, textDecoderStreamConstructorConstruct, decoder_prototype);

    return {
        encoder_constructor,
        encoder_prototype,
        createTransformStreamStructure(vm, global_object, encoder_prototype),
        decoder_constructor,
        decoder_prototype,
        createTransformStreamStructure(vm, global_object, decoder_prototype),
    };
}

} // namespace Collo::HostFunctions
