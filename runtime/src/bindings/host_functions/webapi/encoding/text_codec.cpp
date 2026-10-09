// TextEncoder, TextDecoder, TextEncoderStream and TextDecoderStream from the WHATWG Encoding Standard, run on the VM
// thread. A TextDecoder cell owns the ICU converter of its encoding, when the encoding uses one. The constructor opens
// it and closes it again if it throws before the cell exists; from then on the cell closes it in its destructor and
// closes the old one when UTF-16 BOM sniffing switches converters. Between streaming calls a decoder keeps a carried
// partial sequence of at most three bytes, its BOM flag and the converter's state; a decode that throws resets all
// three, so the next call starts clean.
//
// A stream cell reaches its transform stream, and a TextDecoderStream its decoder, through write barriers that
// visitChildren traces. A stream's JavaScript callbacks reach their owner through a non-enumerable property of the
// callback function, so no Strong roots anything here. Input held in a SharedArrayBuffer is copied before decoding,
// because shared memory can change while the decoder reads it; other input is decoded in place, since decoding runs
// no JavaScript that could detach the buffer. The WebApiCodecStream limits in limits.h bound each stream's buffering,
// and a write past them errors the stream with a QuotaExceededError.

#include "host_functions/webapi/encoding/text_codec.h"

#include "host_functions/support.h"
#include "host_functions/webapi/limits.h"
#include "host_functions/webapi/streams/pipe_transform_stream_private.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/InternalFunction.h>
#include <JavaScriptCore/JSArrayBuffer.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSDestructibleObject.h>
#include <JavaScriptCore/JSFunction.h>
#include <JavaScriptCore/JSGenericTypedArrayViewInlines.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSString.h>
#include <JavaScriptCore/JSTypedArrays.h>
#include <JavaScriptCore/SlotVisitorMacros.h>
#include <wtf/ASCIICType.h>
#include <wtf/SIMDUTF.h>
#include <wtf/StdLibExtras.h>
#include <wtf/Vector.h>
#include <wtf/text/Latin1Character.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringImpl.h>
#include <wtf/text/StringView.h>
#include <wtf/text/WTFString.h>

#include <unicode/ucnv.h>

#include <algorithm>
#include <array>
#include <cstring>
#include <limits>
#include <optional>
#include <span>

namespace Collo::HostFunctions {
namespace {

    using JSC::EncodedJSValue;
    using JSC::JSValue;
    using WTF::String;
    using namespace JSC;

    static_assert(sizeof(UChar) == sizeof(char16_t));

    enum class TextDecoderEncoding : uint8_t {
        Utf8,
        IBM866,
        ISO88592,
        ISO88593,
        ISO88594,
        ISO88595,
        ISO88596,
        ISO88597,
        ISO88598,
        ISO88598I,
        ISO885910,
        ISO885913,
        ISO885914,
        ISO885915,
        ISO885916,
        KOI8R,
        KOI8U,
        Windows874,
        Windows1250,
        Windows1251,
        Windows1252,
        Windows1253,
        Windows1254,
        Windows1255,
        Windows1256,
        Windows1257,
        Windows1258,
        Utf16,
        Utf16BE,
        Utf16LE,
        XUserDefined,
        Big5,
        EUCJP,
        ISO2022JP,
        ShiftJIS,
        EUCKR,
        GBK,
        GB18030,
        Macintosh,
        XMacCyrillic,
    };

    class JSColloTextEncoder final : public JSC::JSDestructibleObject {
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

        static JSColloTextEncoder* create(JSC::VM& vm, JSC::Structure* structure)
        {
            auto* object = new (NotNull, JSC::allocateCell<JSColloTextEncoder>(vm)) JSColloTextEncoder(vm, structure);
            object->finishCreation(vm);
            return object;
        }

        static void destroy(JSC::JSCell* cell) { static_cast<JSColloTextEncoder*>(cell)->~JSColloTextEncoder(); }

        DECLARE_INFO;

    private:
        JSColloTextEncoder(JSC::VM& vm, JSC::Structure* structure)
            : Base(vm, structure)
        {
        }

        ~JSColloTextEncoder() = default;

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

        static JSColloTextDecoder* create(JSC::VM& vm, JSC::Structure* structure, TextDecoderEncoding encoding,
            UConverter* converter, bool fatal, bool ignore_bom)
        {
            auto* object = new (NotNull, JSC::allocateCell<JSColloTextDecoder>(vm))
                JSColloTextDecoder(vm, structure, encoding, converter, fatal, ignore_bom);
            object->finishCreation(vm);
            return object;
        }

        static void destroy(JSC::JSCell* cell) { static_cast<JSColloTextDecoder*>(cell)->~JSColloTextDecoder(); }

        DECLARE_INFO;

        TextDecoderEncoding encoding() const { return m_encoding; }
        UConverter* converter() const { return m_converter; }
        void replaceConverter(UConverter* converter)
        {
            if (m_converter)
                ucnv_close(m_converter);
            m_converter = converter;
        }
        bool fatal() const { return m_fatal; }
        bool ignoreBOM() const { return m_ignore_bom; }
        bool bomSeen() const { return m_bom_seen; }
        bool streaming() const { return m_streaming; }

        std::span<const uint8_t> pending() const { return { m_pending.data(), m_pending_length }; }
        void clearPending() { m_pending_length = 0; }
        void resetDecodeState()
        {
            clearPending();
            m_bom_seen = false;
            if (m_converter)
                ucnv_resetToUnicode(m_converter);
        }
        void markBOMSeen() { m_bom_seen = true; }
        void setStreaming(bool streaming) { m_streaming = streaming; }
        void setPending(std::span<const uint8_t> bytes)
        {
            RELEASE_ASSERT(bytes.size() <= m_pending.size());
            if (!bytes.empty())
                std::memcpy(m_pending.data(), bytes.data(), bytes.size());
            m_pending_length = bytes.size();
        }

    private:
        JSColloTextDecoder(JSC::VM& vm, JSC::Structure* structure, TextDecoderEncoding encoding, UConverter* converter,
            bool fatal, bool ignore_bom)
            : Base(vm, structure)
            , m_encoding(encoding)
            , m_converter(converter)
            , m_fatal(fatal)
            , m_ignore_bom(ignore_bom)
        {
        }

        ~JSColloTextDecoder()
        {
            if (m_converter)
                ucnv_close(m_converter);
        }

        void finishCreation(JSC::VM& vm)
        {
            Base::finishCreation(vm);
            ASSERT(inherits(info()));
        }

        std::array<uint8_t, 3> m_pending { 0, 0, 0 };
        size_t m_pending_length { 0 };
        TextDecoderEncoding m_encoding { TextDecoderEncoding::Utf8 };
        UConverter* m_converter { nullptr };
        bool m_fatal { false };
        bool m_ignore_bom { false };
        bool m_bom_seen { false };
        bool m_streaming { false };
    };

    class JSColloTextEncoderStream final : public JSC::JSDestructibleObject {
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

        static JSColloTextEncoderStream* create(JSC::VM& vm, JSC::Structure* structure)
        {
            auto* object = new (NotNull, JSC::allocateCell<JSColloTextEncoderStream>(vm))
                JSColloTextEncoderStream(vm, structure);
            object->finishCreation(vm);
            return object;
        }

        static void destroy(JSC::JSCell* cell)
        {
            static_cast<JSColloTextEncoderStream*>(cell)->~JSColloTextEncoderStream();
        }

        DECLARE_INFO;
        DECLARE_VISIT_CHILDREN;

        bool initialize(JSC::JSGlobalObject*, JSC::ThrowScope&);
        JSColloReadableStream* readable() const;
        JSColloWritableStream* writable() const;
        EncodedJSValue write(JSC::JSGlobalObject*, JSC::ThrowScope&, JSValue);
        EncodedJSValue close(JSC::JSGlobalObject*, JSC::ThrowScope&);
        void abort(JSC::JSGlobalObject*, JSValue);

    private:
        JSColloTextEncoderStream(JSC::VM& vm, JSC::Structure* structure)
            : Base(vm, structure)
        {
        }

        ~JSColloTextEncoderStream() = default;

        void finishCreation(JSC::VM& vm)
        {
            Base::finishCreation(vm);
            ASSERT(inherits(info()));
        }

        JSC::WriteBarrier<JSColloTransformStream> m_transform;
        char16_t m_pending_leading_surrogate { 0 };
        bool m_has_pending_leading_surrogate { false };
    };

    class JSColloTextDecoderStream final : public JSC::JSDestructibleObject {
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

        static JSColloTextDecoderStream* create(JSC::VM& vm, JSC::Structure* structure, JSColloTextDecoder* decoder)
        {
            auto* object = new (NotNull, JSC::allocateCell<JSColloTextDecoderStream>(vm))
                JSColloTextDecoderStream(vm, structure);
            object->finishCreation(vm, decoder);
            return object;
        }

        static void destroy(JSC::JSCell* cell)
        {
            static_cast<JSColloTextDecoderStream*>(cell)->~JSColloTextDecoderStream();
        }

        DECLARE_INFO;
        DECLARE_VISIT_CHILDREN;

        bool initialize(JSC::JSGlobalObject*, JSC::ThrowScope&);
        JSColloTextDecoder* decoder() const { return m_decoder.get(); }
        JSColloReadableStream* readable() const;
        JSColloWritableStream* writable() const;
        EncodedJSValue write(JSC::JSGlobalObject*, JSC::ThrowScope&, JSValue);
        EncodedJSValue close(JSC::JSGlobalObject*, JSC::ThrowScope&);
        void abort(JSC::JSGlobalObject*, JSValue);

    private:
        JSColloTextDecoderStream(JSC::VM& vm, JSC::Structure* structure)
            : Base(vm, structure)
        {
        }

        ~JSColloTextDecoderStream() = default;

        void finishCreation(JSC::VM& vm, JSColloTextDecoder* decoder)
        {
            Base::finishCreation(vm);
            ASSERT(inherits(info()));
            m_decoder.set(vm, this, decoder);
        }

        JSC::WriteBarrier<JSColloTransformStream> m_transform;
        JSC::WriteBarrier<JSColloTextDecoder> m_decoder;
    };

    const JSC::ClassInfo JSColloTextEncoder::s_info
        = { "TextEncoder"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloTextEncoder) };
    const JSC::ClassInfo JSColloTextDecoder::s_info
        = { "TextDecoder"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloTextDecoder) };
    const JSC::ClassInfo JSColloTextEncoderStream::s_info
        = { "TextEncoderStream"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloTextEncoderStream) };
    const JSC::ClassInfo JSColloTextDecoderStream::s_info
        = { "TextDecoderStream"_s, &Base::s_info, nullptr, nullptr, CREATE_METHOD_TABLE(JSColloTextDecoderStream) };

    template <typename Visitor> void JSColloTextEncoderStream::visitChildrenImpl(JSCell* cell, Visitor& visitor)
    {
        auto* this_object = static_cast<JSColloTextEncoderStream*>(cell);
        ASSERT_GC_OBJECT_INHERITS(this_object, info());
        Base::visitChildren(this_object, visitor);
        visitor.append(this_object->m_transform);
    }

    template <typename Visitor> void JSColloTextDecoderStream::visitChildrenImpl(JSCell* cell, Visitor& visitor)
    {
        auto* this_object = static_cast<JSColloTextDecoderStream*>(cell);
        ASSERT_GC_OBJECT_INHERITS(this_object, info());
        Base::visitChildren(this_object, visitor);
        visitor.append(this_object->m_transform);
        visitor.append(this_object->m_decoder);
    }

    DEFINE_VISIT_CHILDREN(JSColloTextEncoderStream);
    DEFINE_VISIT_CHILDREN(JSColloTextDecoderStream);

    struct EncodeIntoResult {
        size_t read { 0 };
        size_t written { 0 };
    };

    struct ByteSpan {
        const uint8_t* data { nullptr };
        size_t size { 0 };
    };

    static bool snapshotSharedByteSpan(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, ByteSpan bytes,
        bool is_shared, WTF::Vector<uint8_t>& snapshot, ByteSpan& out)
    {
        out = bytes;
        if (!is_shared || bytes.size == 0)
            return true;
        if (!snapshot.tryAppend(std::span<const uint8_t> { bytes.data, bytes.size })) {
            JSC::throwOutOfMemoryError(global_object, scope);
            out = {};
            return false;
        }
        out = { snapshot.span().data(), snapshot.size() };
        return true;
    }

    static bool checkedAddSize(size_t left, size_t right, size_t& out)
    {
        if (left > std::numeric_limits<size_t>::max() - right)
            return false;
        out = left + right;
        return true;
    }

    static bool checkedAddInPlace(size_t& left, size_t right)
    {
        size_t result = 0;
        if (!checkedAddSize(left, right, result))
            return false;
        left = result;
        return true;
    }

    static bool isTooLargeForWTFString(size_t length) { return length > WTF::String::MaxLength; }

    static void throwTextCodecOutOfMemory(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
    {
        JSC::throwOutOfMemoryError(global_object, scope);
    }

    template <typename CharacterType>
    static bool tryCreateUninitializedTextCodecString(size_t length, std::span<CharacterType>& output, String& string)
    {
        output = {};
        if (length == 0) {
            string = emptyString();
            return true;
        }
        if (isTooLargeForWTFString(length))
            return false;

        auto impl = WTF::StringImpl::tryCreateUninitialized(length, output);
        if (!impl)
            return false;
        string = String(WTF::move(impl));
        return true;
    }

    static bool isUtf16LeadingSurrogate(char16_t code_unit) { return code_unit >= 0xd800 && code_unit <= 0xdbff; }

    static bool isUtf16TrailingSurrogate(char16_t code_unit) { return code_unit >= 0xdc00 && code_unit <= 0xdfff; }

    static uint32_t utf16SurrogatePairCodePoint(char16_t leading, char16_t trailing)
    {
        return 0x10000u + ((static_cast<uint32_t>(leading) - 0xd800u) << 10)
            + (static_cast<uint32_t>(trailing) - 0xdc00u);
    }

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

    static JSColloTextEncoderStream* requireTextEncoderStream(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
    {
        if (auto* stream = dynamicDowncast<JSColloTextEncoderStream>(value))
            return stream;
        JSC::throwVMTypeError(global_object, scope, "TextEncoderStream method called on incompatible receiver"_s);
        return nullptr;
    }

    static JSColloTextDecoderStream* requireTextDecoderStream(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value)
    {
        if (auto* stream = dynamicDowncast<JSColloTextDecoderStream>(value))
            return stream;
        JSC::throwVMTypeError(global_object, scope, "TextDecoderStream method called on incompatible receiver"_s);
        return nullptr;
    }

    static bool requireArgumentCount(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        JSC::CallFrame* call_frame, unsigned count, WTF::ASCIILiteral message)
    {
        if (call_frame->argumentCount() >= count)
            return true;
        JSC::throwVMTypeError(global_object, scope, message);
        return false;
    }

    static JSC::Structure* textEncoderStructureForNewTarget(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame)
    {
        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        auto* new_target = call_frame->newTarget().getObject();
        auto* constructor = call_frame->jsCallee();
        if (!new_target || new_target == constructor)
            return collo_global->textEncoderStructure();
        auto* structure = JSC::InternalFunction::createSubclassStructure(
            global_object, new_target, collo_global->textEncoderStructure());
        RETURN_IF_EXCEPTION(scope, nullptr);
        return structure;
    }

    static JSC::Structure* textDecoderStructureForNewTarget(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame)
    {
        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        auto* new_target = call_frame->newTarget().getObject();
        auto* constructor = call_frame->jsCallee();
        if (!new_target || new_target == constructor)
            return collo_global->textDecoderStructure();
        auto* structure = JSC::InternalFunction::createSubclassStructure(
            global_object, new_target, collo_global->textDecoderStructure());
        RETURN_IF_EXCEPTION(scope, nullptr);
        return structure;
    }

    static JSC::Structure* textEncoderStreamStructureForNewTarget(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame)
    {
        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        auto* new_target = call_frame->newTarget().getObject();
        auto* constructor = call_frame->jsCallee();
        if (!new_target || new_target == constructor)
            return collo_global->textEncoderStreamStructure();
        auto* structure = JSC::InternalFunction::createSubclassStructure(
            global_object, new_target, collo_global->textEncoderStreamStructure());
        RETURN_IF_EXCEPTION(scope, nullptr);
        return structure;
    }

    static JSC::Structure* textDecoderStreamStructureForNewTarget(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame)
    {
        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        auto* new_target = call_frame->newTarget().getObject();
        auto* constructor = call_frame->jsCallee();
        if (!new_target || new_target == constructor)
            return collo_global->textDecoderStreamStructure();
        auto* structure = JSC::InternalFunction::createSubclassStructure(
            global_object, new_target, collo_global->textDecoderStreamStructure());
        RETURN_IF_EXCEPTION(scope, nullptr);
        return structure;
    }

    static String optionalWebApiString(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::CallFrame* call_frame, unsigned index)
    {
        if (call_frame->argumentCount() <= index || call_frame->argument(index).isUndefined())
            return emptyString();
        auto string = call_frame->argument(index).toWTFString(global_object);
        RETURN_IF_EXCEPTION(scope, {});
        return string;
    }

    static bool isAsciiWhitespace(UChar character) { return WTF::isASCIIWhitespace(character); }

    struct TextDecoderLabel {
        WTF::ASCIILiteral label;
        TextDecoderEncoding encoding;
    };

    static constexpr std::array textDecoderLabels {
        TextDecoderLabel { "utf-8"_s, TextDecoderEncoding::Utf8 },
        TextDecoderLabel { "utf8"_s, TextDecoderEncoding::Utf8 },
        TextDecoderLabel { "unicode-1-1-utf-8"_s, TextDecoderEncoding::Utf8 },
        TextDecoderLabel { "unicode11utf8"_s, TextDecoderEncoding::Utf8 },
        TextDecoderLabel { "unicode20utf8"_s, TextDecoderEncoding::Utf8 },
        TextDecoderLabel { "x-unicode20utf8"_s, TextDecoderEncoding::Utf8 },
        TextDecoderLabel { "ibm866"_s, TextDecoderEncoding::IBM866 },
        TextDecoderLabel { "866"_s, TextDecoderEncoding::IBM866 },
        TextDecoderLabel { "cp866"_s, TextDecoderEncoding::IBM866 },
        TextDecoderLabel { "csibm866"_s, TextDecoderEncoding::IBM866 },
        TextDecoderLabel { "iso-8859-2"_s, TextDecoderEncoding::ISO88592 },
        TextDecoderLabel { "iso8859-2"_s, TextDecoderEncoding::ISO88592 },
        TextDecoderLabel { "iso88592"_s, TextDecoderEncoding::ISO88592 },
        TextDecoderLabel { "iso_8859-2"_s, TextDecoderEncoding::ISO88592 },
        TextDecoderLabel { "iso_8859-2:1987"_s, TextDecoderEncoding::ISO88592 },
        TextDecoderLabel { "iso-ir-101"_s, TextDecoderEncoding::ISO88592 },
        TextDecoderLabel { "latin2"_s, TextDecoderEncoding::ISO88592 },
        TextDecoderLabel { "l2"_s, TextDecoderEncoding::ISO88592 },
        TextDecoderLabel { "csisolatin2"_s, TextDecoderEncoding::ISO88592 },
        TextDecoderLabel { "iso-8859-3"_s, TextDecoderEncoding::ISO88593 },
        TextDecoderLabel { "iso8859-3"_s, TextDecoderEncoding::ISO88593 },
        TextDecoderLabel { "iso88593"_s, TextDecoderEncoding::ISO88593 },
        TextDecoderLabel { "iso_8859-3"_s, TextDecoderEncoding::ISO88593 },
        TextDecoderLabel { "iso_8859-3:1988"_s, TextDecoderEncoding::ISO88593 },
        TextDecoderLabel { "latin3"_s, TextDecoderEncoding::ISO88593 },
        TextDecoderLabel { "iso-ir-109"_s, TextDecoderEncoding::ISO88593 },
        TextDecoderLabel { "l3"_s, TextDecoderEncoding::ISO88593 },
        TextDecoderLabel { "csisolatin3"_s, TextDecoderEncoding::ISO88593 },
        TextDecoderLabel { "iso-8859-4"_s, TextDecoderEncoding::ISO88594 },
        TextDecoderLabel { "iso8859-4"_s, TextDecoderEncoding::ISO88594 },
        TextDecoderLabel { "iso88594"_s, TextDecoderEncoding::ISO88594 },
        TextDecoderLabel { "iso_8859-4"_s, TextDecoderEncoding::ISO88594 },
        TextDecoderLabel { "iso_8859-4:1988"_s, TextDecoderEncoding::ISO88594 },
        TextDecoderLabel { "iso-ir-110"_s, TextDecoderEncoding::ISO88594 },
        TextDecoderLabel { "latin4"_s, TextDecoderEncoding::ISO88594 },
        TextDecoderLabel { "l4"_s, TextDecoderEncoding::ISO88594 },
        TextDecoderLabel { "csisolatin4"_s, TextDecoderEncoding::ISO88594 },
        TextDecoderLabel { "iso-8859-5"_s, TextDecoderEncoding::ISO88595 },
        TextDecoderLabel { "iso8859-5"_s, TextDecoderEncoding::ISO88595 },
        TextDecoderLabel { "iso88595"_s, TextDecoderEncoding::ISO88595 },
        TextDecoderLabel { "iso_8859-5"_s, TextDecoderEncoding::ISO88595 },
        TextDecoderLabel { "iso_8859-5:1988"_s, TextDecoderEncoding::ISO88595 },
        TextDecoderLabel { "cyrillic"_s, TextDecoderEncoding::ISO88595 },
        TextDecoderLabel { "iso-ir-144"_s, TextDecoderEncoding::ISO88595 },
        TextDecoderLabel { "csisolatincyrillic"_s, TextDecoderEncoding::ISO88595 },
        TextDecoderLabel { "iso-8859-6"_s, TextDecoderEncoding::ISO88596 },
        TextDecoderLabel { "iso-8859-6-e"_s, TextDecoderEncoding::ISO88596 },
        TextDecoderLabel { "iso-8859-6-i"_s, TextDecoderEncoding::ISO88596 },
        TextDecoderLabel { "iso8859-6"_s, TextDecoderEncoding::ISO88596 },
        TextDecoderLabel { "iso88596"_s, TextDecoderEncoding::ISO88596 },
        TextDecoderLabel { "iso_8859-6"_s, TextDecoderEncoding::ISO88596 },
        TextDecoderLabel { "iso_8859-6:1987"_s, TextDecoderEncoding::ISO88596 },
        TextDecoderLabel { "arabic"_s, TextDecoderEncoding::ISO88596 },
        TextDecoderLabel { "asmo-708"_s, TextDecoderEncoding::ISO88596 },
        TextDecoderLabel { "csiso88596e"_s, TextDecoderEncoding::ISO88596 },
        TextDecoderLabel { "csiso88596i"_s, TextDecoderEncoding::ISO88596 },
        TextDecoderLabel { "csisolatinarabic"_s, TextDecoderEncoding::ISO88596 },
        TextDecoderLabel { "ecma-114"_s, TextDecoderEncoding::ISO88596 },
        TextDecoderLabel { "iso-ir-127"_s, TextDecoderEncoding::ISO88596 },
        TextDecoderLabel { "iso-8859-7"_s, TextDecoderEncoding::ISO88597 },
        TextDecoderLabel { "iso8859-7"_s, TextDecoderEncoding::ISO88597 },
        TextDecoderLabel { "iso88597"_s, TextDecoderEncoding::ISO88597 },
        TextDecoderLabel { "iso_8859-7"_s, TextDecoderEncoding::ISO88597 },
        TextDecoderLabel { "iso_8859-7:1987"_s, TextDecoderEncoding::ISO88597 },
        TextDecoderLabel { "greek"_s, TextDecoderEncoding::ISO88597 },
        TextDecoderLabel { "greek8"_s, TextDecoderEncoding::ISO88597 },
        TextDecoderLabel { "iso-ir-126"_s, TextDecoderEncoding::ISO88597 },
        TextDecoderLabel { "elot_928"_s, TextDecoderEncoding::ISO88597 },
        TextDecoderLabel { "ecma-118"_s, TextDecoderEncoding::ISO88597 },
        TextDecoderLabel { "csisolatingreek"_s, TextDecoderEncoding::ISO88597 },
        TextDecoderLabel { "sun_eu_greek"_s, TextDecoderEncoding::ISO88597 },
        TextDecoderLabel { "iso-8859-8"_s, TextDecoderEncoding::ISO88598 },
        TextDecoderLabel { "iso-8859-8-e"_s, TextDecoderEncoding::ISO88598 },
        TextDecoderLabel { "iso8859-8"_s, TextDecoderEncoding::ISO88598 },
        TextDecoderLabel { "iso88598"_s, TextDecoderEncoding::ISO88598 },
        TextDecoderLabel { "iso_8859-8"_s, TextDecoderEncoding::ISO88598 },
        TextDecoderLabel { "iso_8859-8:1988"_s, TextDecoderEncoding::ISO88598 },
        TextDecoderLabel { "csiso88598e"_s, TextDecoderEncoding::ISO88598 },
        TextDecoderLabel { "hebrew"_s, TextDecoderEncoding::ISO88598 },
        TextDecoderLabel { "iso-ir-138"_s, TextDecoderEncoding::ISO88598 },
        TextDecoderLabel { "csisolatinhebrew"_s, TextDecoderEncoding::ISO88598 },
        TextDecoderLabel { "visual"_s, TextDecoderEncoding::ISO88598 },
        TextDecoderLabel { "iso-8859-8-i"_s, TextDecoderEncoding::ISO88598I },
        TextDecoderLabel { "csiso88598i"_s, TextDecoderEncoding::ISO88598I },
        TextDecoderLabel { "logical"_s, TextDecoderEncoding::ISO88598I },
        TextDecoderLabel { "iso-8859-10"_s, TextDecoderEncoding::ISO885910 },
        TextDecoderLabel { "iso8859-10"_s, TextDecoderEncoding::ISO885910 },
        TextDecoderLabel { "iso885910"_s, TextDecoderEncoding::ISO885910 },
        TextDecoderLabel { "iso-ir-157"_s, TextDecoderEncoding::ISO885910 },
        TextDecoderLabel { "latin6"_s, TextDecoderEncoding::ISO885910 },
        TextDecoderLabel { "l6"_s, TextDecoderEncoding::ISO885910 },
        TextDecoderLabel { "csisolatin6"_s, TextDecoderEncoding::ISO885910 },
        TextDecoderLabel { "iso-8859-13"_s, TextDecoderEncoding::ISO885913 },
        TextDecoderLabel { "iso8859-13"_s, TextDecoderEncoding::ISO885913 },
        TextDecoderLabel { "iso885913"_s, TextDecoderEncoding::ISO885913 },
        TextDecoderLabel { "iso-8859-14"_s, TextDecoderEncoding::ISO885914 },
        TextDecoderLabel { "iso8859-14"_s, TextDecoderEncoding::ISO885914 },
        TextDecoderLabel { "iso885914"_s, TextDecoderEncoding::ISO885914 },
        TextDecoderLabel { "iso-8859-15"_s, TextDecoderEncoding::ISO885915 },
        TextDecoderLabel { "iso8859-15"_s, TextDecoderEncoding::ISO885915 },
        TextDecoderLabel { "iso885915"_s, TextDecoderEncoding::ISO885915 },
        TextDecoderLabel { "iso_8859-15"_s, TextDecoderEncoding::ISO885915 },
        TextDecoderLabel { "csisolatin9"_s, TextDecoderEncoding::ISO885915 },
        TextDecoderLabel { "l9"_s, TextDecoderEncoding::ISO885915 },
        TextDecoderLabel { "iso-8859-16"_s, TextDecoderEncoding::ISO885916 },
        TextDecoderLabel { "koi8-r"_s, TextDecoderEncoding::KOI8R },
        TextDecoderLabel { "koi"_s, TextDecoderEncoding::KOI8R },
        TextDecoderLabel { "koi8"_s, TextDecoderEncoding::KOI8R },
        TextDecoderLabel { "koi8_r"_s, TextDecoderEncoding::KOI8R },
        TextDecoderLabel { "cskoi8r"_s, TextDecoderEncoding::KOI8R },
        TextDecoderLabel { "koi8-u"_s, TextDecoderEncoding::KOI8U },
        TextDecoderLabel { "koi8-ru"_s, TextDecoderEncoding::KOI8U },
        TextDecoderLabel { "windows-874"_s, TextDecoderEncoding::Windows874 },
        TextDecoderLabel { "dos-874"_s, TextDecoderEncoding::Windows874 },
        TextDecoderLabel { "iso-8859-11"_s, TextDecoderEncoding::Windows874 },
        TextDecoderLabel { "iso8859-11"_s, TextDecoderEncoding::Windows874 },
        TextDecoderLabel { "iso885911"_s, TextDecoderEncoding::Windows874 },
        TextDecoderLabel { "tis-620"_s, TextDecoderEncoding::Windows874 },
        TextDecoderLabel { "windows-1252"_s, TextDecoderEncoding::Windows1252 },
        TextDecoderLabel { "cp1252"_s, TextDecoderEncoding::Windows1252 },
        TextDecoderLabel { "x-cp1252"_s, TextDecoderEncoding::Windows1252 },
        TextDecoderLabel { "ansi_x3.4-1968"_s, TextDecoderEncoding::Windows1252 },
        TextDecoderLabel { "ascii"_s, TextDecoderEncoding::Windows1252 },
        TextDecoderLabel { "cp819"_s, TextDecoderEncoding::Windows1252 },
        TextDecoderLabel { "csisolatin1"_s, TextDecoderEncoding::Windows1252 },
        TextDecoderLabel { "ibm819"_s, TextDecoderEncoding::Windows1252 },
        TextDecoderLabel { "iso-8859-1"_s, TextDecoderEncoding::Windows1252 },
        TextDecoderLabel { "iso-ir-100"_s, TextDecoderEncoding::Windows1252 },
        TextDecoderLabel { "iso8859-1"_s, TextDecoderEncoding::Windows1252 },
        TextDecoderLabel { "iso88591"_s, TextDecoderEncoding::Windows1252 },
        TextDecoderLabel { "iso_8859-1"_s, TextDecoderEncoding::Windows1252 },
        TextDecoderLabel { "iso_8859-1:1987"_s, TextDecoderEncoding::Windows1252 },
        TextDecoderLabel { "l1"_s, TextDecoderEncoding::Windows1252 },
        TextDecoderLabel { "latin1"_s, TextDecoderEncoding::Windows1252 },
        TextDecoderLabel { "us-ascii"_s, TextDecoderEncoding::Windows1252 },
        TextDecoderLabel { "windows-1250"_s, TextDecoderEncoding::Windows1250 },
        TextDecoderLabel { "cp1250"_s, TextDecoderEncoding::Windows1250 },
        TextDecoderLabel { "x-cp1250"_s, TextDecoderEncoding::Windows1250 },
        TextDecoderLabel { "windows-1251"_s, TextDecoderEncoding::Windows1251 },
        TextDecoderLabel { "cp1251"_s, TextDecoderEncoding::Windows1251 },
        TextDecoderLabel { "x-cp1251"_s, TextDecoderEncoding::Windows1251 },
        TextDecoderLabel { "windows-1253"_s, TextDecoderEncoding::Windows1253 },
        TextDecoderLabel { "cp1253"_s, TextDecoderEncoding::Windows1253 },
        TextDecoderLabel { "x-cp1253"_s, TextDecoderEncoding::Windows1253 },
        TextDecoderLabel { "windows-1254"_s, TextDecoderEncoding::Windows1254 },
        TextDecoderLabel { "cp1254"_s, TextDecoderEncoding::Windows1254 },
        TextDecoderLabel { "x-cp1254"_s, TextDecoderEncoding::Windows1254 },
        TextDecoderLabel { "csisolatin5"_s, TextDecoderEncoding::Windows1254 },
        TextDecoderLabel { "iso-8859-9"_s, TextDecoderEncoding::Windows1254 },
        TextDecoderLabel { "iso-ir-148"_s, TextDecoderEncoding::Windows1254 },
        TextDecoderLabel { "iso8859-9"_s, TextDecoderEncoding::Windows1254 },
        TextDecoderLabel { "iso88599"_s, TextDecoderEncoding::Windows1254 },
        TextDecoderLabel { "iso_8859-9"_s, TextDecoderEncoding::Windows1254 },
        TextDecoderLabel { "iso_8859-9:1989"_s, TextDecoderEncoding::Windows1254 },
        TextDecoderLabel { "l5"_s, TextDecoderEncoding::Windows1254 },
        TextDecoderLabel { "latin5"_s, TextDecoderEncoding::Windows1254 },
        TextDecoderLabel { "windows-1255"_s, TextDecoderEncoding::Windows1255 },
        TextDecoderLabel { "cp1255"_s, TextDecoderEncoding::Windows1255 },
        TextDecoderLabel { "x-cp1255"_s, TextDecoderEncoding::Windows1255 },
        TextDecoderLabel { "windows-1256"_s, TextDecoderEncoding::Windows1256 },
        TextDecoderLabel { "cp1256"_s, TextDecoderEncoding::Windows1256 },
        TextDecoderLabel { "x-cp1256"_s, TextDecoderEncoding::Windows1256 },
        TextDecoderLabel { "windows-1257"_s, TextDecoderEncoding::Windows1257 },
        TextDecoderLabel { "cp1257"_s, TextDecoderEncoding::Windows1257 },
        TextDecoderLabel { "x-cp1257"_s, TextDecoderEncoding::Windows1257 },
        TextDecoderLabel { "windows-1258"_s, TextDecoderEncoding::Windows1258 },
        TextDecoderLabel { "cp1258"_s, TextDecoderEncoding::Windows1258 },
        TextDecoderLabel { "x-cp1258"_s, TextDecoderEncoding::Windows1258 },
        TextDecoderLabel { "utf-16be"_s, TextDecoderEncoding::Utf16BE },
        TextDecoderLabel { "unicodefffe"_s, TextDecoderEncoding::Utf16BE },
        TextDecoderLabel { "utf-16le"_s, TextDecoderEncoding::Utf16LE },
        TextDecoderLabel { "utf-16"_s, TextDecoderEncoding::Utf16 },
        TextDecoderLabel { "csunicode"_s, TextDecoderEncoding::Utf16 },
        TextDecoderLabel { "iso-10646-ucs-2"_s, TextDecoderEncoding::Utf16 },
        TextDecoderLabel { "ucs-2"_s, TextDecoderEncoding::Utf16 },
        TextDecoderLabel { "unicode"_s, TextDecoderEncoding::Utf16 },
        TextDecoderLabel { "unicodefeff"_s, TextDecoderEncoding::Utf16 },
        TextDecoderLabel { "x-user-defined"_s, TextDecoderEncoding::XUserDefined },
        // Labels of the replacement encoding ("replacement", "csiso2022kr", "hz-gb-2312", "iso-2022-cn",
        // "iso-2022-cn-ext", "iso-2022-kr") are left out: the TextDecoder and TextDecoderStream constructors must
        // throw a RangeError for them, and an unknown label already does.
        TextDecoderLabel { "big5"_s, TextDecoderEncoding::Big5 },
        TextDecoderLabel { "big5-hkscs"_s, TextDecoderEncoding::Big5 },
        TextDecoderLabel { "cn-big5"_s, TextDecoderEncoding::Big5 },
        TextDecoderLabel { "csbig5"_s, TextDecoderEncoding::Big5 },
        TextDecoderLabel { "x-x-big5"_s, TextDecoderEncoding::Big5 },
        TextDecoderLabel { "euc-jp"_s, TextDecoderEncoding::EUCJP },
        TextDecoderLabel { "cseucpkdfmtjapanese"_s, TextDecoderEncoding::EUCJP },
        TextDecoderLabel { "x-euc-jp"_s, TextDecoderEncoding::EUCJP },
        TextDecoderLabel { "iso-2022-jp"_s, TextDecoderEncoding::ISO2022JP },
        TextDecoderLabel { "csiso2022jp"_s, TextDecoderEncoding::ISO2022JP },
        TextDecoderLabel { "shift_jis"_s, TextDecoderEncoding::ShiftJIS },
        TextDecoderLabel { "shift-jis"_s, TextDecoderEncoding::ShiftJIS },
        TextDecoderLabel { "csshiftjis"_s, TextDecoderEncoding::ShiftJIS },
        TextDecoderLabel { "ms932"_s, TextDecoderEncoding::ShiftJIS },
        TextDecoderLabel { "ms_kanji"_s, TextDecoderEncoding::ShiftJIS },
        TextDecoderLabel { "sjis"_s, TextDecoderEncoding::ShiftJIS },
        TextDecoderLabel { "windows-31j"_s, TextDecoderEncoding::ShiftJIS },
        TextDecoderLabel { "x-sjis"_s, TextDecoderEncoding::ShiftJIS },
        TextDecoderLabel { "euc-kr"_s, TextDecoderEncoding::EUCKR },
        TextDecoderLabel { "cseuckr"_s, TextDecoderEncoding::EUCKR },
        TextDecoderLabel { "csksc56011987"_s, TextDecoderEncoding::EUCKR },
        TextDecoderLabel { "iso-ir-149"_s, TextDecoderEncoding::EUCKR },
        TextDecoderLabel { "korean"_s, TextDecoderEncoding::EUCKR },
        TextDecoderLabel { "ks_c_5601-1987"_s, TextDecoderEncoding::EUCKR },
        TextDecoderLabel { "ks_c_5601-1989"_s, TextDecoderEncoding::EUCKR },
        TextDecoderLabel { "ksc5601"_s, TextDecoderEncoding::EUCKR },
        TextDecoderLabel { "ksc_5601"_s, TextDecoderEncoding::EUCKR },
        TextDecoderLabel { "windows-949"_s, TextDecoderEncoding::EUCKR },
        TextDecoderLabel { "gbk"_s, TextDecoderEncoding::GBK },
        TextDecoderLabel { "chinese"_s, TextDecoderEncoding::GBK },
        TextDecoderLabel { "csgb2312"_s, TextDecoderEncoding::GBK },
        TextDecoderLabel { "csiso58gb231280"_s, TextDecoderEncoding::GBK },
        TextDecoderLabel { "gb2312"_s, TextDecoderEncoding::GBK },
        TextDecoderLabel { "gb_2312"_s, TextDecoderEncoding::GBK },
        TextDecoderLabel { "gb_2312-80"_s, TextDecoderEncoding::GBK },
        TextDecoderLabel { "iso-ir-58"_s, TextDecoderEncoding::GBK },
        TextDecoderLabel { "x-gbk"_s, TextDecoderEncoding::GBK },
        TextDecoderLabel { "gb18030"_s, TextDecoderEncoding::GB18030 },
        TextDecoderLabel { "macintosh"_s, TextDecoderEncoding::Macintosh },
        TextDecoderLabel { "mac"_s, TextDecoderEncoding::Macintosh },
        TextDecoderLabel { "csmacintosh"_s, TextDecoderEncoding::Macintosh },
        TextDecoderLabel { "x-mac-roman"_s, TextDecoderEncoding::Macintosh },
        TextDecoderLabel { "x-mac-cyrillic"_s, TextDecoderEncoding::XMacCyrillic },
        TextDecoderLabel { "x-mac-ukrainian"_s, TextDecoderEncoding::XMacCyrillic },
    };

    template <typename CharacterType>
    static bool equalLabelIgnoringASCIICase(std::span<const CharacterType> label, WTF::ASCIILiteral expected)
    {
        if (label.size() != expected.length())
            return false;
        for (size_t index = 0; index < label.size(); ++index) {
            auto character = label[index];
            if (character > 0x7f)
                return false;
            if (toASCIILower(character) != static_cast<CharacterType>(expected[index]))
                return false;
        }
        return true;
    }

    // The Encoding Standard's get an encoding: strips leading and trailing ASCII whitespace, then matches the label
    // ASCII case-insensitively against the table above. Returns nullopt for an unknown label.
    template <typename CharacterType>
    static std::optional<TextDecoderEncoding> parseTextDecoderEncodingSpan(std::span<const CharacterType> raw_label)
    {
        size_t start = 0;
        size_t end = raw_label.size();
        while (start < end && isAsciiWhitespace(raw_label[start]))
            ++start;
        while (end > start && isAsciiWhitespace(raw_label[end - 1]))
            --end;

        const size_t label_length = end - start;
        if (label_length == 0)
            return std::nullopt;

        // A label longer than every entry fails each length comparison, so the label needs no length cap of its own.
        auto label = raw_label.subspan(start, label_length);
        for (const auto& entry : textDecoderLabels) {
            if (entry.label.length() == label_length && equalLabelIgnoringASCIICase(label, entry.label))
                return entry.encoding;
        }
        return std::nullopt;
    }

    static std::optional<TextDecoderEncoding> parseTextDecoderEncoding(const String& raw_label)
    {
        if (raw_label.is8Bit())
            return parseTextDecoderEncodingSpan(raw_label.span8());
        return parseTextDecoderEncodingSpan(raw_label.span16());
    }

    static WTF::ASCIILiteral canonicalTextDecoderEncoding(TextDecoderEncoding encoding)
    {
        switch (encoding) {
        case TextDecoderEncoding::Utf8:
            return "utf-8"_s;
        case TextDecoderEncoding::IBM866:
            return "ibm866"_s;
        case TextDecoderEncoding::ISO88592:
            return "iso-8859-2"_s;
        case TextDecoderEncoding::ISO88593:
            return "iso-8859-3"_s;
        case TextDecoderEncoding::ISO88594:
            return "iso-8859-4"_s;
        case TextDecoderEncoding::ISO88595:
            return "iso-8859-5"_s;
        case TextDecoderEncoding::ISO88596:
            return "iso-8859-6"_s;
        case TextDecoderEncoding::ISO88597:
            return "iso-8859-7"_s;
        case TextDecoderEncoding::ISO88598:
            return "iso-8859-8"_s;
        case TextDecoderEncoding::ISO88598I:
            return "iso-8859-8-i"_s;
        case TextDecoderEncoding::ISO885910:
            return "iso-8859-10"_s;
        case TextDecoderEncoding::ISO885913:
            return "iso-8859-13"_s;
        case TextDecoderEncoding::ISO885914:
            return "iso-8859-14"_s;
        case TextDecoderEncoding::ISO885915:
            return "iso-8859-15"_s;
        case TextDecoderEncoding::ISO885916:
            return "iso-8859-16"_s;
        case TextDecoderEncoding::KOI8R:
            return "koi8-r"_s;
        case TextDecoderEncoding::KOI8U:
            return "koi8-u"_s;
        case TextDecoderEncoding::Windows874:
            return "windows-874"_s;
        case TextDecoderEncoding::Windows1250:
            return "windows-1250"_s;
        case TextDecoderEncoding::Windows1251:
            return "windows-1251"_s;
        case TextDecoderEncoding::Windows1252:
            return "windows-1252"_s;
        case TextDecoderEncoding::Windows1253:
            return "windows-1253"_s;
        case TextDecoderEncoding::Windows1254:
            return "windows-1254"_s;
        case TextDecoderEncoding::Windows1255:
            return "windows-1255"_s;
        case TextDecoderEncoding::Windows1256:
            return "windows-1256"_s;
        case TextDecoderEncoding::Windows1257:
            return "windows-1257"_s;
        case TextDecoderEncoding::Windows1258:
            return "windows-1258"_s;
        case TextDecoderEncoding::Utf16:
        case TextDecoderEncoding::Utf16LE:
            return "utf-16le"_s;
        case TextDecoderEncoding::Utf16BE:
            return "utf-16be"_s;
        case TextDecoderEncoding::XUserDefined:
            return "x-user-defined"_s;
        case TextDecoderEncoding::Big5:
            return "big5"_s;
        case TextDecoderEncoding::EUCJP:
            return "euc-jp"_s;
        case TextDecoderEncoding::ISO2022JP:
            return "iso-2022-jp"_s;
        case TextDecoderEncoding::ShiftJIS:
            return "shift_jis"_s;
        case TextDecoderEncoding::EUCKR:
            return "euc-kr"_s;
        case TextDecoderEncoding::GBK:
            return "gbk"_s;
        case TextDecoderEncoding::GB18030:
            return "gb18030"_s;
        case TextDecoderEncoding::Macintosh:
            return "macintosh"_s;
        case TextDecoderEncoding::XMacCyrillic:
            return "x-mac-cyrillic"_s;
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

    static const char* icuConverterName(TextDecoderEncoding encoding)
    {
        switch (encoding) {
        case TextDecoderEncoding::ISO88592:
            return "ISO-8859-2";
        case TextDecoderEncoding::ISO88593:
            return "ISO-8859-3";
        case TextDecoderEncoding::ISO88594:
            return "ISO-8859-4";
        case TextDecoderEncoding::ISO88595:
            return "ISO-8859-5";
        case TextDecoderEncoding::ISO88596:
            return "ISO-8859-6";
        case TextDecoderEncoding::ISO88597:
            return "ISO-8859-7";
        case TextDecoderEncoding::ISO88598:
        case TextDecoderEncoding::ISO88598I:
            return "ISO-8859-8";
        case TextDecoderEncoding::ISO885910:
            return "ISO-8859-10";
        case TextDecoderEncoding::ISO885913:
            return "ISO-8859-13";
        case TextDecoderEncoding::ISO885914:
            return "ISO-8859-14";
        case TextDecoderEncoding::ISO885915:
            return "ISO-8859-15";
        case TextDecoderEncoding::KOI8R:
            return "KOI8-R";
        case TextDecoderEncoding::Windows1250:
            return "windows-1250";
        case TextDecoderEncoding::Windows1251:
            return "windows-1251";
        case TextDecoderEncoding::Windows1252:
            return "windows-1252";
        case TextDecoderEncoding::Windows1254:
            return "windows-1254";
        case TextDecoderEncoding::Windows1256:
            return "windows-1256";
        case TextDecoderEncoding::Windows1257:
            return "windows-1257";
        case TextDecoderEncoding::Windows1258:
            return "windows-1258";
        case TextDecoderEncoding::Utf16BE:
            return "UTF-16BE";
        case TextDecoderEncoding::Utf16:
        case TextDecoderEncoding::Utf16LE:
            return "UTF-16LE";
        case TextDecoderEncoding::Big5:
            return "Big5";
        case TextDecoderEncoding::EUCJP:
            return "EUC-JP";
        case TextDecoderEncoding::ISO2022JP:
            return "ISO-2022-JP";
        case TextDecoderEncoding::ShiftJIS:
            return "Shift_JIS";
        case TextDecoderEncoding::EUCKR:
            // The Encoding Standard's euc-kr is the full windows-949 (UHC) repertoire, with lead bytes 0x81 to 0xFE.
            // ICU resolves "EUC-KR" to ibm-970, which covers only the KS X 1001 subset, so the decoder opens ICU's
            // windows-949 converter, as WebKit does.
            return "windows-949";
        case TextDecoderEncoding::GBK:
            return "GBK";
        case TextDecoderEncoding::GB18030:
            return "GB18030";
        case TextDecoderEncoding::Macintosh:
            return "macintosh";
        case TextDecoderEncoding::XMacCyrillic:
            return "x-mac-cyrillic";
        case TextDecoderEncoding::Utf8:
        case TextDecoderEncoding::IBM866:
        case TextDecoderEncoding::ISO885916:
        case TextDecoderEncoding::KOI8U:
        case TextDecoderEncoding::Windows874:
        case TextDecoderEncoding::Windows1253:
        case TextDecoderEncoding::Windows1255:
        case TextDecoderEncoding::XUserDefined:
            return nullptr;
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

    static bool usesBomHandling(TextDecoderEncoding encoding)
    {
        return encoding == TextDecoderEncoding::Utf8 || encoding == TextDecoderEncoding::Utf16
            || encoding == TextDecoderEncoding::Utf16LE || encoding == TextDecoderEncoding::Utf16BE;
    }

    static UConverter* createIcuConverter(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, TextDecoderEncoding encoding, bool fatal)
    {
        const char* converter_name = icuConverterName(encoding);
        if (!converter_name)
            return nullptr;

        UErrorCode status = U_ZERO_ERROR;
        UConverter* converter = ucnv_open(converter_name, &status);
        if (U_FAILURE(status) || !converter) {
            JSC::throwException(global_object, scope,
                JSC::createRangeError(global_object, "TextDecoder label is not supported by ICU"_s));
            return nullptr;
        }

        status = U_ZERO_ERROR;
        ucnv_setToUCallBack(converter, fatal ? UCNV_TO_U_CALLBACK_STOP : UCNV_TO_U_CALLBACK_SUBSTITUTE, nullptr,
            nullptr, nullptr, &status);
        if (U_FAILURE(status)) {
            ucnv_close(converter);
            JSC::throwException(global_object, scope,
                JSC::createRangeError(global_object, "TextDecoder failed to initialize converter"_s));
            return nullptr;
        }

        return converter;
    }

    static constexpr uint32_t invalidSingleByteCodePoint = 0xffffffffu;

    static constexpr uint32_t ibm866Index[128] = {
        1040u,
        1041u,
        1042u,
        1043u,
        1044u,
        1045u,
        1046u,
        1047u,
        1048u,
        1049u,
        1050u,
        1051u,
        1052u,
        1053u,
        1054u,
        1055u,
        1056u,
        1057u,
        1058u,
        1059u,
        1060u,
        1061u,
        1062u,
        1063u,
        1064u,
        1065u,
        1066u,
        1067u,
        1068u,
        1069u,
        1070u,
        1071u,
        1072u,
        1073u,
        1074u,
        1075u,
        1076u,
        1077u,
        1078u,
        1079u,
        1080u,
        1081u,
        1082u,
        1083u,
        1084u,
        1085u,
        1086u,
        1087u,
        9617u,
        9618u,
        9619u,
        9474u,
        9508u,
        9569u,
        9570u,
        9558u,
        9557u,
        9571u,
        9553u,
        9559u,
        9565u,
        9564u,
        9563u,
        9488u,
        9492u,
        9524u,
        9516u,
        9500u,
        9472u,
        9532u,
        9566u,
        9567u,
        9562u,
        9556u,
        9577u,
        9574u,
        9568u,
        9552u,
        9580u,
        9575u,
        9576u,
        9572u,
        9573u,
        9561u,
        9560u,
        9554u,
        9555u,
        9579u,
        9578u,
        9496u,
        9484u,
        9608u,
        9604u,
        9612u,
        9616u,
        9600u,
        1088u,
        1089u,
        1090u,
        1091u,
        1092u,
        1093u,
        1094u,
        1095u,
        1096u,
        1097u,
        1098u,
        1099u,
        1100u,
        1101u,
        1102u,
        1103u,
        1025u,
        1105u,
        1028u,
        1108u,
        1031u,
        1111u,
        1038u,
        1118u,
        176u,
        8729u,
        183u,
        8730u,
        8470u,
        164u,
        9632u,
        160u,
    };

    static constexpr uint32_t koi8uIndex[128] = {
        9472u,
        9474u,
        9484u,
        9488u,
        9492u,
        9496u,
        9500u,
        9508u,
        9516u,
        9524u,
        9532u,
        9600u,
        9604u,
        9608u,
        9612u,
        9616u,
        9617u,
        9618u,
        9619u,
        8992u,
        9632u,
        8729u,
        8730u,
        8776u,
        8804u,
        8805u,
        160u,
        8993u,
        176u,
        178u,
        183u,
        247u,
        9552u,
        9553u,
        9554u,
        1105u,
        1108u,
        9556u,
        1110u,
        1111u,
        9559u,
        9560u,
        9561u,
        9562u,
        9563u,
        1169u,
        1118u,
        9566u,
        9567u,
        9568u,
        9569u,
        1025u,
        1028u,
        9571u,
        1030u,
        1031u,
        9574u,
        9575u,
        9576u,
        9577u,
        9578u,
        1168u,
        1038u,
        169u,
        1102u,
        1072u,
        1073u,
        1094u,
        1076u,
        1077u,
        1092u,
        1075u,
        1093u,
        1080u,
        1081u,
        1082u,
        1083u,
        1084u,
        1085u,
        1086u,
        1087u,
        1103u,
        1088u,
        1089u,
        1090u,
        1091u,
        1078u,
        1074u,
        1100u,
        1099u,
        1079u,
        1096u,
        1101u,
        1097u,
        1095u,
        1098u,
        1070u,
        1040u,
        1041u,
        1062u,
        1044u,
        1045u,
        1060u,
        1043u,
        1061u,
        1048u,
        1049u,
        1050u,
        1051u,
        1052u,
        1053u,
        1054u,
        1055u,
        1071u,
        1056u,
        1057u,
        1058u,
        1059u,
        1046u,
        1042u,
        1068u,
        1067u,
        1047u,
        1064u,
        1069u,
        1065u,
        1063u,
        1066u,
    };

    static constexpr uint32_t windows874Index[128] = {
        8364u,
        129u,
        130u,
        131u,
        132u,
        8230u,
        134u,
        135u,
        136u,
        137u,
        138u,
        139u,
        140u,
        141u,
        142u,
        143u,
        144u,
        8216u,
        8217u,
        8220u,
        8221u,
        8226u,
        8211u,
        8212u,
        152u,
        153u,
        154u,
        155u,
        156u,
        157u,
        158u,
        159u,
        160u,
        3585u,
        3586u,
        3587u,
        3588u,
        3589u,
        3590u,
        3591u,
        3592u,
        3593u,
        3594u,
        3595u,
        3596u,
        3597u,
        3598u,
        3599u,
        3600u,
        3601u,
        3602u,
        3603u,
        3604u,
        3605u,
        3606u,
        3607u,
        3608u,
        3609u,
        3610u,
        3611u,
        3612u,
        3613u,
        3614u,
        3615u,
        3616u,
        3617u,
        3618u,
        3619u,
        3620u,
        3621u,
        3622u,
        3623u,
        3624u,
        3625u,
        3626u,
        3627u,
        3628u,
        3629u,
        3630u,
        3631u,
        3632u,
        3633u,
        3634u,
        3635u,
        3636u,
        3637u,
        3638u,
        3639u,
        3640u,
        3641u,
        3642u,
        invalidSingleByteCodePoint,
        invalidSingleByteCodePoint,
        invalidSingleByteCodePoint,
        invalidSingleByteCodePoint,
        3647u,
        3648u,
        3649u,
        3650u,
        3651u,
        3652u,
        3653u,
        3654u,
        3655u,
        3656u,
        3657u,
        3658u,
        3659u,
        3660u,
        3661u,
        3662u,
        3663u,
        3664u,
        3665u,
        3666u,
        3667u,
        3668u,
        3669u,
        3670u,
        3671u,
        3672u,
        3673u,
        3674u,
        3675u,
        invalidSingleByteCodePoint,
        invalidSingleByteCodePoint,
        invalidSingleByteCodePoint,
        invalidSingleByteCodePoint,
    };

    static constexpr uint32_t windows1253Index[128] = {
        8364u,
        129u,
        8218u,
        402u,
        8222u,
        8230u,
        8224u,
        8225u,
        136u,
        8240u,
        138u,
        8249u,
        140u,
        141u,
        142u,
        143u,
        144u,
        8216u,
        8217u,
        8220u,
        8221u,
        8226u,
        8211u,
        8212u,
        152u,
        8482u,
        154u,
        8250u,
        156u,
        157u,
        158u,
        159u,
        160u,
        901u,
        902u,
        163u,
        164u,
        165u,
        166u,
        167u,
        168u,
        169u,
        invalidSingleByteCodePoint,
        171u,
        172u,
        173u,
        174u,
        8213u,
        176u,
        177u,
        178u,
        179u,
        900u,
        181u,
        182u,
        183u,
        904u,
        905u,
        906u,
        187u,
        908u,
        189u,
        910u,
        911u,
        912u,
        913u,
        914u,
        915u,
        916u,
        917u,
        918u,
        919u,
        920u,
        921u,
        922u,
        923u,
        924u,
        925u,
        926u,
        927u,
        928u,
        929u,
        invalidSingleByteCodePoint,
        931u,
        932u,
        933u,
        934u,
        935u,
        936u,
        937u,
        938u,
        939u,
        940u,
        941u,
        942u,
        943u,
        944u,
        945u,
        946u,
        947u,
        948u,
        949u,
        950u,
        951u,
        952u,
        953u,
        954u,
        955u,
        956u,
        957u,
        958u,
        959u,
        960u,
        961u,
        962u,
        963u,
        964u,
        965u,
        966u,
        967u,
        968u,
        969u,
        970u,
        971u,
        972u,
        973u,
        974u,
        invalidSingleByteCodePoint,
    };

    static constexpr uint32_t windows1255Index[128] = {
        8364u,
        129u,
        8218u,
        402u,
        8222u,
        8230u,
        8224u,
        8225u,
        710u,
        8240u,
        138u,
        8249u,
        140u,
        141u,
        142u,
        143u,
        144u,
        8216u,
        8217u,
        8220u,
        8221u,
        8226u,
        8211u,
        8212u,
        732u,
        8482u,
        154u,
        8250u,
        156u,
        157u,
        158u,
        159u,
        160u,
        161u,
        162u,
        163u,
        8362u,
        165u,
        166u,
        167u,
        168u,
        169u,
        215u,
        171u,
        172u,
        173u,
        174u,
        175u,
        176u,
        177u,
        178u,
        179u,
        180u,
        181u,
        182u,
        183u,
        184u,
        185u,
        247u,
        187u,
        188u,
        189u,
        190u,
        191u,
        1456u,
        1457u,
        1458u,
        1459u,
        1460u,
        1461u,
        1462u,
        1463u,
        1464u,
        1465u,
        1466u,
        1467u,
        1468u,
        1469u,
        1470u,
        1471u,
        1472u,
        1473u,
        1474u,
        1475u,
        1520u,
        1521u,
        1522u,
        1523u,
        1524u,
        invalidSingleByteCodePoint,
        invalidSingleByteCodePoint,
        invalidSingleByteCodePoint,
        invalidSingleByteCodePoint,
        invalidSingleByteCodePoint,
        invalidSingleByteCodePoint,
        invalidSingleByteCodePoint,
        1488u,
        1489u,
        1490u,
        1491u,
        1492u,
        1493u,
        1494u,
        1495u,
        1496u,
        1497u,
        1498u,
        1499u,
        1500u,
        1501u,
        1502u,
        1503u,
        1504u,
        1505u,
        1506u,
        1507u,
        1508u,
        1509u,
        1510u,
        1511u,
        1512u,
        1513u,
        1514u,
        invalidSingleByteCodePoint,
        invalidSingleByteCodePoint,
        8206u,
        8207u,
        invalidSingleByteCodePoint,
    };

    static const uint32_t* whatwgSingleByteIndex(TextDecoderEncoding encoding)
    {
        switch (encoding) {
        case TextDecoderEncoding::IBM866:
            return ibm866Index;
        case TextDecoderEncoding::KOI8U:
            return koi8uIndex;
        case TextDecoderEncoding::Windows874:
            return windows874Index;
        case TextDecoderEncoding::Windows1253:
            return windows1253Index;
        case TextDecoderEncoding::Windows1255:
            return windows1255Index;
        default:
            return nullptr;
        }
    }

    static JSValue getPropertyIfPresent(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSObject* object, WTF::ASCIILiteral name)
    {
        auto value = object->getIfPropertyExists(global_object, JSC::Identifier::fromString(global_object->vm(), name));
        RETURN_IF_EXCEPTION(scope, {});
        return value;
    }

    static bool optionBoolean(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue options_value, WTF::ASCIILiteral name)
    {
        if (!options_value.isObject())
            return false;
        auto* object = options_value.getObject();
        auto value = getPropertyIfPresent(global_object, scope, object, name);
        RETURN_IF_EXCEPTION(scope, false);
        if (value.isEmpty() || value.isUndefined())
            return false;
        return value.toBoolean(global_object);
    }

    static JSC::JSUint8Array* createTextCodecUint8Array(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, size_t byte_length)
    {
        auto* structure = global_object->typedArrayStructureWithTypedArrayType<JSC::TypeUint8>();
        auto* array = JSC::JSUint8Array::createUninitialized(global_object, structure, byte_length);
        RETURN_IF_EXCEPTION(scope, nullptr);
        return array;
    }

    static size_t utf8LengthForCodePoint(uint32_t code_point)
    {
        if (code_point <= 0x7f)
            return 1;
        if (code_point <= 0x7ff)
            return 2;
        if (code_point <= 0xffff)
            return 3;
        return 4;
    }

    static bool appendUtf8ToSpan(uint32_t code_point, std::span<uint8_t> destination, size_t& written)
    {
        if (code_point <= 0x7f) {
            if (written + 1 > destination.size())
                return false;
            destination[written++] = static_cast<uint8_t>(code_point);
            return true;
        }
        if (code_point <= 0x7ff) {
            if (written + 2 > destination.size())
                return false;
            destination[written++] = static_cast<uint8_t>(0xc0 | (code_point >> 6));
            destination[written++] = static_cast<uint8_t>(0x80 | (code_point & 0x3f));
            return true;
        }
        if (code_point <= 0xffff) {
            if (written + 3 > destination.size())
                return false;
            destination[written++] = static_cast<uint8_t>(0xe0 | (code_point >> 12));
            destination[written++] = static_cast<uint8_t>(0x80 | ((code_point >> 6) & 0x3f));
            destination[written++] = static_cast<uint8_t>(0x80 | (code_point & 0x3f));
            return true;
        }
        if (written + 4 > destination.size())
            return false;
        destination[written++] = static_cast<uint8_t>(0xf0 | (code_point >> 18));
        destination[written++] = static_cast<uint8_t>(0x80 | ((code_point >> 12) & 0x3f));
        destination[written++] = static_cast<uint8_t>(0x80 | ((code_point >> 6) & 0x3f));
        destination[written++] = static_cast<uint8_t>(0x80 | (code_point & 0x3f));
        return true;
    }

    template <typename CharacterType>
    static bool utf8LengthReplacingInvalid(std::span<const CharacterType> source, size_t& out)
    {
        size_t length = 0;
        for (size_t index = 0; index < source.size();) {
            uint32_t code_point = source[index];
            size_t read_units = 1;
            if constexpr (sizeof(CharacterType) == 2) {
                char16_t current = static_cast<char16_t>(source[index]);
                if (isUtf16LeadingSurrogate(current)) {
                    if (index + 1 < source.size()
                        && isUtf16TrailingSurrogate(static_cast<char16_t>(source[index + 1]))) {
                        code_point = utf16SurrogatePairCodePoint(current, static_cast<char16_t>(source[index + 1]));
                        read_units = 2;
                    } else
                        code_point = 0xfffdu;
                } else if (isUtf16TrailingSurrogate(current))
                    code_point = 0xfffdu;
            }
            if (!checkedAddInPlace(length, utf8LengthForCodePoint(code_point)))
                return false;
            index += read_units;
        }
        out = length;
        return true;
    }

    template <typename CharacterType>
    static size_t encodeUtf8ReplacingInvalid(std::span<const CharacterType> source, std::span<uint8_t> destination)
    {
        size_t written = 0;
        for (size_t index = 0; index < source.size();) {
            uint32_t code_point = source[index];
            size_t read_units = 1;
            if constexpr (sizeof(CharacterType) == 2) {
                char16_t current = static_cast<char16_t>(source[index]);
                if (isUtf16LeadingSurrogate(current)) {
                    if (index + 1 < source.size()
                        && isUtf16TrailingSurrogate(static_cast<char16_t>(source[index + 1]))) {
                        code_point = utf16SurrogatePairCodePoint(current, static_cast<char16_t>(source[index + 1]));
                        read_units = 2;
                    } else
                        code_point = 0xfffdu;
                } else if (isUtf16TrailingSurrogate(current))
                    code_point = 0xfffdu;
            }
            RELEASE_ASSERT(appendUtf8ToSpan(code_point, destination, written));
            index += read_units;
        }
        return written;
    }

    static JSC::JSUint8Array* createUtf8ArrayFromString(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const String& input)
    {
        if (input.isEmpty())
            return createTextCodecUint8Array(global_object, scope, 0);

        if (input.is8Bit()) {
            auto characters = input.span8();
            const size_t byte_length
                = simdutf::utf8_length_from_latin1(reinterpret_cast<const char*>(characters.data()), characters.size());
            auto* array = createTextCodecUint8Array(global_object, scope, byte_length);
            if (!array)
                return nullptr;
            auto output = std::span<uint8_t> { static_cast<uint8_t*>(array->vector()), byte_length };
            if (characters.empty())
                return array;
            if (byte_length == characters.size())
                std::memcpy(output.data(), characters.data(), characters.size());
            else {
                const size_t written = simdutf::convert_latin1_to_utf8(reinterpret_cast<const char*>(characters.data()),
                    characters.size(), reinterpret_cast<char*>(output.data()));
                RELEASE_ASSERT(written == byte_length);
            }
            return array;
        }

        auto characters = input.span16();
        const bool valid_utf16 = simdutf::validate_utf16(characters.data(), characters.size());
        size_t byte_length = 0;
        if (valid_utf16)
            byte_length = simdutf::utf8_length_from_utf16(characters.data(), characters.size());
        else if (!utf8LengthReplacingInvalid<char16_t>(characters, byte_length)) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return nullptr;
        }

        auto* array = createTextCodecUint8Array(global_object, scope, byte_length);
        if (!array)
            return nullptr;
        auto output = std::span<uint8_t> { static_cast<uint8_t*>(array->vector()), byte_length };
        if (characters.empty())
            return array;

        if (valid_utf16) {
            const size_t written = simdutf::convert_valid_utf16_to_utf8(
                characters.data(), characters.size(), reinterpret_cast<char*>(output.data()));
            RELEASE_ASSERT(written == byte_length);
        } else {
            const size_t written = encodeUtf8ReplacingInvalid<char16_t>(characters, output);
            RELEASE_ASSERT(written == byte_length);
        }
        return array;
    }

    static bool appendUtf8(uint32_t code_point, uint8_t* destination, size_t capacity, size_t& written)
    {
        if (code_point <= 0x7f) {
            if (written + 1 > capacity)
                return false;
            destination[written++] = static_cast<uint8_t>(code_point);
            return true;
        }
        if (code_point <= 0x7ff) {
            if (written + 2 > capacity)
                return false;
            destination[written++] = static_cast<uint8_t>(0xc0 | (code_point >> 6));
            destination[written++] = static_cast<uint8_t>(0x80 | (code_point & 0x3f));
            return true;
        }
        if (code_point <= 0xffff) {
            if (written + 3 > capacity)
                return false;
            destination[written++] = static_cast<uint8_t>(0xe0 | (code_point >> 12));
            destination[written++] = static_cast<uint8_t>(0x80 | ((code_point >> 6) & 0x3f));
            destination[written++] = static_cast<uint8_t>(0x80 | (code_point & 0x3f));
            return true;
        }
        if (written + 4 > capacity)
            return false;
        destination[written++] = static_cast<uint8_t>(0xf0 | (code_point >> 18));
        destination[written++] = static_cast<uint8_t>(0x80 | ((code_point >> 12) & 0x3f));
        destination[written++] = static_cast<uint8_t>(0x80 | ((code_point >> 6) & 0x3f));
        destination[written++] = static_cast<uint8_t>(0x80 | (code_point & 0x3f));
        return true;
    }

    template <typename CharacterType>
    static EncodeIntoResult encodeIntoCharacters(std::span<const CharacterType> source, std::span<uint8_t> destination)
    {
        EncodeIntoResult result;
        for (size_t i = 0; i < source.size();) {
            if (source[i] <= 0x7f) {
                const size_t start = i;
                const size_t available = destination.size() - result.written;
                if (available == 0)
                    break;

                size_t run_length = 0;
                while (
                    start + run_length < source.size() && run_length < available && source[start + run_length] <= 0x7f)
                    ++run_length;

                if constexpr (sizeof(CharacterType) == 1)
                    std::memcpy(destination.data() + result.written, source.data() + start, run_length);
                else {
                    for (size_t offset = 0; offset < run_length; ++offset)
                        destination[result.written + offset] = static_cast<uint8_t>(source[start + offset]);
                }

                result.read += run_length;
                result.written += run_length;
                i += run_length;
                continue;
            }

            uint32_t code_point = source[i];
            size_t read_units = 1;
            if constexpr (sizeof(CharacterType) == 2) {
                if (code_point >= 0xd800 && code_point <= 0xdbff) {
                    if (i + 1 < source.size()) {
                        uint32_t trail = source[i + 1];
                        if (trail >= 0xdc00 && trail <= 0xdfff) {
                            code_point = 0x10000 + ((code_point - 0xd800) << 10) + (trail - 0xdc00);
                            read_units = 2;
                        } else
                            code_point = 0xfffd;
                    } else
                        code_point = 0xfffd;
                } else if (code_point >= 0xdc00 && code_point <= 0xdfff)
                    code_point = 0xfffd;
            }

            size_t next_written = result.written;
            if (!appendUtf8(code_point, destination.data(), destination.size(), next_written))
                break;
            result.written = next_written;
            result.read += read_units;
            i += read_units;
        }
        return result;
    }

    static EncodeIntoResult encodeIntoString(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        JSC::JSString* input, std::span<uint8_t> destination)
    {
        if (destination.empty())
            return {};

        auto view = input->view(global_object);
        RETURN_IF_EXCEPTION(scope, {});
        if (view->is8Bit())
            return encodeIntoCharacters<Latin1Character>(view->span8(), destination);
        return encodeIntoCharacters<char16_t>(view->span16(), destination);
    }

    static JSC::JSObject* createEncodeIntoResultObject(
        JSC::JSGlobalObject* global_object, JSC::VM& vm, EncodeIntoResult result)
    {
        auto* object = JSC::constructEmptyObject(global_object, global_object->objectPrototype(), 2);
        object->putDirect(vm, JSC::Identifier::fromString(vm, "read"_s), JSC::jsNumber(result.read));
        object->putDirect(vm, JSC::Identifier::fromString(vm, "written"_s), JSC::jsNumber(result.written));
        return object;
    }

    static bool inputBytes(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value,
        WTF::Vector<uint8_t>& snapshot, ByteSpan& out)
    {
        if (value.isUndefined() || value.isNull()) {
            out = { nullptr, 0 };
            return true;
        }
        if (!value.isObject()) {
            JSC::throwVMTypeError(
                global_object, scope, "TextDecoder.decode input must be an ArrayBuffer or ArrayBufferView"_s);
            return false;
        }

        if (auto* view = dynamicDowncast<JSC::JSArrayBufferView>(value)) {
            if (view->isDetached() || view->isOutOfBounds()) {
                out = { nullptr, 0 };
                return true;
            }
            return snapshotSharedByteSpan(global_object, scope,
                { static_cast<const uint8_t*>(view->vector()), view->byteLength() }, view->isShared(), snapshot, out);
        }

        if (auto* array_buffer = dynamicDowncast<JSC::JSArrayBuffer>(value)) {
            auto* buffer = array_buffer->impl();
            if (!buffer || buffer->isDetached()) {
                out = { nullptr, 0 };
                return true;
            }
            return snapshotSharedByteSpan(global_object, scope,
                { static_cast<const uint8_t*>(buffer->data()), buffer->byteLength() }, buffer->isShared(), snapshot,
                out);
        }

        JSC::throwVMTypeError(
            global_object, scope, "TextDecoder.decode input must be an ArrayBuffer or ArrayBufferView"_s);
        return false;
    }

    static bool isUtf8Continuation(uint8_t byte) { return (byte & 0xc0) == 0x80; }

    static bool isUtf8ContinuationInRange(uint8_t byte, uint8_t minimum, uint8_t maximum)
    {
        return byte >= minimum && byte <= maximum;
    }

    static size_t utf8SequenceLength(uint8_t lead)
    {
        if (lead < 0x80)
            return 1;
        if (lead >= 0xc2 && lead <= 0xdf)
            return 2;
        if (lead >= 0xe0 && lead <= 0xef)
            return 3;
        if (lead >= 0xf0 && lead <= 0xf4)
            return 4;
        return 0;
    }

    static bool isValidIncompleteTrailingUtf8(std::span<const uint8_t> bytes, size_t start, size_t expected)
    {
        const size_t available = bytes.size() - start;
        ASSERT(expected > 1);
        ASSERT(available < expected);
        ASSERT(available > 0);

        if (available == 1)
            return true;

        const uint8_t lead = bytes[start];
        const uint8_t second = bytes[start + 1];
        bool second_valid = false;
        if (lead >= 0xc2 && lead <= 0xdf)
            second_valid = isUtf8Continuation(second);
        else if (lead == 0xe0)
            second_valid = isUtf8ContinuationInRange(second, 0xa0, 0xbf);
        else if (lead >= 0xe1 && lead <= 0xec)
            second_valid = isUtf8Continuation(second);
        else if (lead == 0xed)
            second_valid = isUtf8ContinuationInRange(second, 0x80, 0x9f);
        else if (lead >= 0xee && lead <= 0xef)
            second_valid = isUtf8Continuation(second);
        else if (lead == 0xf0)
            second_valid = isUtf8ContinuationInRange(second, 0x90, 0xbf);
        else if (lead >= 0xf1 && lead <= 0xf3)
            second_valid = isUtf8Continuation(second);
        else if (lead == 0xf4)
            second_valid = isUtf8ContinuationInRange(second, 0x80, 0x8f);

        if (!second_valid)
            return false;
        if (available == 2)
            return true;

        ASSERT(expected == 4);
        return isUtf8Continuation(bytes[start + 2]);
    }

    static bool hasIncompleteTrailingUtf8(std::span<const uint8_t> bytes, size_t& split)
    {
        split = bytes.size();
        if (bytes.empty())
            return false;

        size_t start = bytes.size() - 1;
        size_t continuation_count = 0;
        while (start > 0 && isUtf8Continuation(bytes[start])) {
            continuation_count++;
            start--;
            if (continuation_count == 3)
                break;
        }

        size_t expected = utf8SequenceLength(bytes[start]);
        if (expected == 0 || expected == 1)
            return false;
        size_t available = bytes.size() - start;
        if (available >= expected)
            return false;
        if (!isValidIncompleteTrailingUtf8(bytes, start, expected))
            return false;
        split = start;
        return true;
    }

    static String finishDecodedString(JSColloTextDecoder* decoder, String&& string)
    {
        if (usesBomHandling(decoder->encoding()) && !decoder->bomSeen() && !string.isEmpty()) {
            const bool strip_bom = !decoder->ignoreBOM() && string[0] == 0xfeff;
            decoder->markBOMSeen();
            if (strip_bom)
                return string.substringSharingImpl(1);
        }
        return WTF::move(string);
    }

    // Decodes one contiguous UTF-8 span whose BOM, if any, the caller already dropped. Both WTF conversions first scan
    // for all-ASCII input and copy it into a Latin-1 string without transcoding, so a scan here would read the bytes
    // twice. On the fatal path String::fromUTF8 transcodes with simdutf and returns a null string for invalid UTF-8,
    // which becomes a TypeError. On the replacing path fromUTF8ReplacingInvalidSequences emits one U+FFFD per maximal
    // invalid subsequence, as the Encoding Standard's UTF-8 decoder does.
    // FIXME: Both conversions RELEASE_ASSERT that the span is at most WTF::String::MaxLength bytes, and
    // TextDecoder.decode passes its input through unchecked, so a larger buffer ends the worker instead of throwing.
    static String decodeUtf8Span(JSColloTextDecoder* decoder, JSC::JSGlobalObject* global_object,
        JSC::ThrowScope& scope, std::span<const uint8_t> bytes)
    {
        if (bytes.empty())
            return emptyString();
        auto char_span = std::span<const char8_t> { reinterpret_cast<const char8_t*>(bytes.data()), bytes.size() };
        if (decoder->fatal()) {
            auto decoded = String::fromUTF8(char_span);
            if (decoded.isNull()) {
                JSC::throwVMTypeError(global_object, scope, "The encoded data was not valid UTF-8"_s);
                return {};
            }
            return decoded;
        }
        auto decoded = String::fromUTF8ReplacingInvalidSequences(char_span);
        if (decoded.isNull()) {
            // The converter sizes its output at one UTF-16 unit per input byte, which every input fits, and returns
            // null only when that output runs short; an allocation failure ends the process inside WTF instead. The
            // check keeps a null string from reaching JavaScript should either change.
            throwTextCodecOutOfMemory(global_object, scope);
            return {};
        }
        return decoded;
    }

    // Returns how many leading bytes to drop as a UTF-8 BOM: 3 when `stream_prefix` starts with EF BB BF and
    // ignoreBOM is off, otherwise 0. Only the first non-empty prefix of a stream is checked, and checking it marks the
    // BOM as seen. The prefix is the logical start of the stream, which may straddle pending() and the new chunk, so
    // the caller assembles it.
    static size_t consumeUtf8Bom(JSColloTextDecoder* decoder, std::span<const uint8_t> stream_prefix)
    {
        if (decoder->bomSeen() || stream_prefix.empty())
            return 0;
        decoder->markBOMSeen();
        if (!decoder->ignoreBOM() && stream_prefix.size() >= 3 && stream_prefix[0] == 0xef && stream_prefix[1] == 0xbb
            && stream_prefix[2] == 0xbf)
            return 3;
        return 0;
    }

    // Decodes one UTF-8 chunk. With `stream` set, an incomplete sequence at the end is carried in pending() to the
    // next call; on a flush, a carried or trailing incomplete sequence decodes as an error. The concatenated output of
    // a stream's calls equals decoding all of its bytes as one buffer.
    static String decodeUtf8String(JSColloTextDecoder* decoder, JSC::JSGlobalObject* global_object,
        JSC::ThrowScope& scope, ByteSpan input, bool stream)
    {
        std::span<const uint8_t> chunk { input.data, input.size };

        // Nothing is carried from the previous call, as in a whole-buffer decode or a stream split on sequence
        // boundaries. The chunk is decoded in place: the BOM is cut off as a subspan, and only a trailing incomplete
        // sequence of at most three bytes is copied into pending().
        if (decoder->pending().empty()) {
            size_t split = chunk.size();
            if (stream && hasIncompleteTrailingUtf8(chunk, split)) {
                decoder->setPending(chunk.subspan(split));
                chunk = chunk.first(split);
            }
            size_t bom = consumeUtf8Bom(decoder, chunk);
            return decodeUtf8Span(decoder, global_object, scope, chunk.subspan(bom));
        }

        // A previous streaming call left an incomplete sequence of one to three bytes in pending(). Only the boundary
        // sequence is resolved, in a small stack buffer, and the rest of the chunk is decoded in place.
        std::array<uint8_t, 4> boundary;
        size_t boundary_len = decoder->pending().size();
        ASSERT(boundary_len >= 1 && boundary_len <= 3);
        std::memcpy(boundary.data(), decoder->pending().data(), boundary_len);
        decoder->clearPending();

        const size_t expected = utf8SequenceLength(boundary[0]);
        ASSERT(expected >= 2 && expected <= 4 && expected > boundary_len);
        const size_t need = expected - boundary_len;

        // Continuation bytes join the boundary until the sequence reaches its expected length, the chunk runs out, or
        // another byte appears. No UTF-8 sequence, valid or not, continues across a byte that is not a continuation
        // byte, so decoding the boundary and the rest of the chunk separately gives the output of decoding pending()
        // and the chunk as one buffer.
        size_t take = 0;
        while (take < need && take < chunk.size() && isUtf8Continuation(chunk[take])) {
            boundary[boundary_len + take] = chunk[take];
            ++take;
        }
        boundary_len += take;
        std::span<const uint8_t> chunk_tail = chunk.subspan(take);
        std::span<const uint8_t> boundary_bytes { boundary.data(), boundary_len };

        // The chunk ran out before the sequence did, with only continuation bytes seen, so the whole chunk is in the
        // boundary. A streaming call carries the boundary to the next call; a flush decodes it as an error.
        // FIXME: The carried bytes need not be a valid prefix: after a carried 0xE0, a chunk holding only 0x80 leaves
        // both bytes in pending(), so their U+FFFD output, or the fatal TypeError, arrives one call late.
        const bool boundary_incomplete = take == need ? false : (take == chunk.size());
        if (boundary_incomplete) {
            ASSERT(chunk_tail.empty());
            if (stream) {
                decoder->setPending(boundary_bytes);
                // The BOM flag stays unset: the carried bytes may be the start of a BOM.
                return emptyString();
            }
            // On a flush the carried bytes still go through the BOM check, which a partial BOM never passes, and then
            // decode as an error.
            size_t bom = consumeUtf8Bom(decoder, boundary_bytes);
            return decodeUtf8Span(decoder, global_object, scope, boundary_bytes.subspan(bom));
        }

        // The boundary sequence is resolved, complete or broken. A BOM may straddle pending() and the chunk, so the
        // BOM check reads the stream's first three bytes from the boundary and then from the rest of the chunk.
        size_t bom = 0;
        if (!decoder->bomSeen()) {
            std::array<uint8_t, 3> prefix;
            size_t prefix_len = std::min<size_t>(3, boundary_len);
            std::memcpy(prefix.data(), boundary_bytes.data(), prefix_len);
            if (prefix_len < 3) {
                size_t extra = std::min<size_t>(3 - prefix_len, chunk_tail.size());
                std::memcpy(prefix.data() + prefix_len, chunk_tail.data(), extra);
                prefix_len += extra;
            }
            bom = consumeUtf8Bom(decoder, std::span<const uint8_t> { prefix.data(), prefix_len });
        }

        // A streaming chunk may end in another incomplete sequence, which is carried to the next call.
        if (stream) {
            size_t tail_split = chunk_tail.size();
            if (hasIncompleteTrailingUtf8(chunk_tail, tail_split)) {
                decoder->setPending(chunk_tail.subspan(tail_split));
                chunk_tail = chunk_tail.first(tail_split);
            }
        }

        // Drops the BOM bytes from whichever side of the split they fell on.
        std::span<const uint8_t> boundary_decode = boundary_bytes;
        if (bom) {
            const size_t from_boundary = std::min(bom, boundary_len);
            boundary_decode = boundary_bytes.subspan(from_boundary);
            if (bom > from_boundary)
                chunk_tail = chunk_tail.subspan(bom - from_boundary);
        }

        String boundary_string = decodeUtf8Span(decoder, global_object, scope, boundary_decode);
        RETURN_IF_EXCEPTION(scope, {});
        if (chunk_tail.empty())
            return boundary_string;
        String tail_string = decodeUtf8Span(decoder, global_object, scope, chunk_tail);
        RETURN_IF_EXCEPTION(scope, {});
        if (boundary_string.isEmpty())
            return tail_string;
        auto joined = tryMakeString(boundary_string, tail_string);
        if (joined.isNull()) {
            throwException(global_object, scope, createOutOfMemoryError(global_object));
            return emptyString();
        }
        return joined;
    }

    static String stringFromDecodedUnits(JSColloTextDecoder* decoder, std::span<const char16_t> units)
    {
        size_t start = 0;
        if (usesBomHandling(decoder->encoding()) && !decoder->bomSeen() && !units.empty()) {
            if (!decoder->ignoreBOM() && units[0] == 0xfeff)
                start = 1;
            decoder->markBOMSeen();
        }
        if (start >= units.size())
            return emptyString();
        return String(units.subspan(start));
    }

    static bool createDecodedLatin1String(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, size_t length,
        std::span<Latin1Character>& output, String& string)
    {
        if (tryCreateUninitializedTextCodecString(length, output, string))
            return true;
        throwTextCodecOutOfMemory(global_object, scope);
        return false;
    }

    static bool createDecodedUtf16String(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, size_t length,
        std::span<char16_t>& output, String& string)
    {
        if (tryCreateUninitializedTextCodecString(length, output, string))
            return true;
        throwTextCodecOutOfMemory(global_object, scope);
        return false;
    }

    static String decodeWhatwgSingleByteString(
        JSColloTextDecoder* decoder, JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, ByteSpan input)
    {
        const uint32_t* index = whatwgSingleByteIndex(decoder->encoding());
        RELEASE_ASSERT(index);

        bool needs_utf16 = false;
        for (size_t offset = 0; offset < input.size; ++offset) {
            uint32_t code_point = input.data[offset];
            if (input.data[offset] >= 0x80)
                code_point = index[input.data[offset] - 0x80];
            if (code_point == invalidSingleByteCodePoint) {
                if (decoder->fatal()) {
                    JSC::throwVMTypeError(
                        global_object, scope, "The encoded data was not valid for this TextDecoder"_s);
                    return {};
                }
                code_point = 0xfffdu;
            }
            RELEASE_ASSERT(code_point <= 0xffffu);
            if (code_point > 0xffu)
                needs_utf16 = true;
        }

        if (!needs_utf16) {
            std::span<Latin1Character> output;
            String decoded;
            if (!createDecodedLatin1String(global_object, scope, input.size, output, decoded))
                return {};
            for (size_t offset = 0; offset < input.size; ++offset) {
                uint32_t code_point = input.data[offset];
                if (input.data[offset] >= 0x80)
                    code_point = index[input.data[offset] - 0x80];
                output[offset] = static_cast<Latin1Character>(code_point);
            }
            return finishDecodedString(decoder, WTF::move(decoded));
        }

        std::span<char16_t> output;
        String decoded;
        if (!createDecodedUtf16String(global_object, scope, input.size, output, decoded))
            return {};
        for (size_t offset = 0; offset < input.size; ++offset) {
            uint32_t code_point = input.data[offset];
            if (input.data[offset] >= 0x80)
                code_point = index[input.data[offset] - 0x80];
            if (code_point == invalidSingleByteCodePoint)
                code_point = 0xfffdu;
            output[offset] = static_cast<char16_t>(code_point);
        }
        return finishDecodedString(decoder, WTF::move(decoded));
    }

    static String decodeXUserDefinedString(
        JSColloTextDecoder* decoder, JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, ByteSpan input)
    {
        bool needs_utf16 = false;
        for (size_t i = 0; i < input.size; ++i) {
            if (input.data[i] >= 0x80) {
                needs_utf16 = true;
                break;
            }
        }

        if (!needs_utf16) {
            std::span<Latin1Character> output;
            String decoded;
            if (!createDecodedLatin1String(global_object, scope, input.size, output, decoded))
                return {};
            if (input.size)
                std::memcpy(output.data(), input.data, input.size);
            return finishDecodedString(decoder, WTF::move(decoded));
        }

        std::span<char16_t> output;
        String decoded;
        if (!createDecodedUtf16String(global_object, scope, input.size, output, decoded))
            return {};
        for (size_t i = 0; i < input.size; ++i) {
            uint8_t byte = input.data[i];
            output[i] = byte < 0x80 ? byte : static_cast<char16_t>(0xf780 + byte - 0x80);
        }
        return finishDecodedString(decoder, WTF::move(decoded));
    }

    static String decodeIso885916String(
        JSColloTextDecoder* decoder, JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, ByteSpan input)
    {
        static constexpr std::array<char16_t, 96> upper = {
            0x00a0,
            0x0104,
            0x0105,
            0x0141,
            0x20ac,
            0x201e,
            0x0160,
            0x00a7,
            0x0161,
            0x00a9,
            0x0218,
            0x00ab,
            0x0179,
            0x00ad,
            0x017a,
            0x017b,
            0x00b0,
            0x00b1,
            0x010c,
            0x0142,
            0x017d,
            0x201d,
            0x00b6,
            0x00b7,
            0x017e,
            0x010d,
            0x0219,
            0x00bb,
            0x0152,
            0x0153,
            0x0178,
            0x017c,
            0x00c0,
            0x00c1,
            0x00c2,
            0x0102,
            0x00c4,
            0x0106,
            0x00c6,
            0x00c7,
            0x00c8,
            0x00c9,
            0x00ca,
            0x00cb,
            0x00cc,
            0x00cd,
            0x00ce,
            0x00cf,
            0x0110,
            0x0143,
            0x00d2,
            0x00d3,
            0x00d4,
            0x0150,
            0x00d6,
            0x015a,
            0x0170,
            0x00d9,
            0x00da,
            0x00db,
            0x00dc,
            0x0118,
            0x021a,
            0x00df,
            0x00e0,
            0x00e1,
            0x00e2,
            0x0103,
            0x00e4,
            0x0107,
            0x00e6,
            0x00e7,
            0x00e8,
            0x00e9,
            0x00ea,
            0x00eb,
            0x00ec,
            0x00ed,
            0x00ee,
            0x00ef,
            0x0111,
            0x0144,
            0x00f2,
            0x00f3,
            0x00f4,
            0x0151,
            0x00f6,
            0x015b,
            0x0171,
            0x00f9,
            0x00fa,
            0x00fb,
            0x00fc,
            0x0119,
            0x021b,
            0x00ff,
        };

        auto code_point_for_byte
            = [&](uint8_t byte) -> char16_t { return byte < 0xa0 ? static_cast<char16_t>(byte) : upper[byte - 0xa0]; };

        bool needs_utf16 = false;
        for (size_t i = 0; i < input.size; ++i) {
            if (code_point_for_byte(input.data[i]) > 0xff) {
                needs_utf16 = true;
                break;
            }
        }

        if (!needs_utf16) {
            std::span<Latin1Character> output;
            String decoded;
            if (!createDecodedLatin1String(global_object, scope, input.size, output, decoded))
                return {};
            for (size_t i = 0; i < input.size; ++i)
                output[i] = static_cast<Latin1Character>(code_point_for_byte(input.data[i]));
            return finishDecodedString(decoder, WTF::move(decoded));
        }

        std::span<char16_t> output;
        String decoded;
        if (!createDecodedUtf16String(global_object, scope, input.size, output, decoded))
            return {};
        for (size_t i = 0; i < input.size; ++i) {
            output[i] = code_point_for_byte(input.data[i]);
        }
        return finishDecodedString(decoder, WTF::move(decoded));
    }

    static String decodeIcuString(JSColloTextDecoder* decoder, JSC::JSGlobalObject* global_object,
        JSC::ThrowScope& scope, ByteSpan input, bool stream)
    {
        auto* converter = decoder->converter();
        RELEASE_ASSERT(converter);

        static constexpr char empty_source = 0;
        const char* source = input.size ? reinterpret_cast<const char*>(input.data) : &empty_source;
        const char* source_limit = source + input.size;
        WTF::Vector<char16_t, 256> units;
        size_t initial_capacity = 0;
        if (!checkedAddSize(input.size, 8, initial_capacity))
            initial_capacity = WTF::String::MaxLength;
        initial_capacity = std::min(initial_capacity, static_cast<size_t>(WTF::String::MaxLength));
        initial_capacity = std::min<size_t>(initial_capacity, 64 * 1024);
        if (!units.tryReserveInitialCapacity(initial_capacity)) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return {};
        }

        for (;;) {
            const size_t old_size = units.size();
            const size_t remaining = static_cast<size_t>(source_limit - source);
            if (old_size >= WTF::String::MaxLength) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return {};
            }
            size_t desired_growth = 0;
            if (!checkedAddSize(remaining, 8, desired_growth))
                desired_growth = WTF::String::MaxLength - old_size;
            desired_growth = std::max<size_t>(64, desired_growth);
            desired_growth = std::min(desired_growth, static_cast<size_t>(WTF::String::MaxLength) - old_size);
            if (desired_growth == 0 || !units.tryGrow(old_size + desired_growth)) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return {};
            }

            auto* target_start = reinterpret_cast<UChar*>(units.mutableSpan().data() + old_size);
            auto* target = target_start;
            auto* target_limit = reinterpret_cast<UChar*>(units.mutableSpan().data() + units.size());
            UErrorCode status = U_ZERO_ERROR;
            ucnv_toUnicode(converter, &target, target_limit, &source, source_limit, nullptr, !stream, &status);
            units.shrink(old_size + static_cast<size_t>(target - target_start));

            if (status == U_BUFFER_OVERFLOW_ERROR)
                continue;
            if (U_FAILURE(status)) {
                JSC::throwVMTypeError(global_object, scope, "The encoded data was not valid for this TextDecoder"_s);
                return {};
            }
            break;
        }

        return stringFromDecodedUnits(decoder, units.span());
    }

    // Decodes UTF-16LE bytes by copying them into char16_t storage, which matches the encoding only on little-endian
    // targets. x86_64 and ARM64, the runtime's targets, are little-endian, and WTF makes the same assumption when
    // StringImpl hands its char16_t storage to simdutf's UTF-16LE functions. The copy serves only a call that needs no
    // state across calls: pending() is empty, this call flushes, the previous call flushed too, the byte count is even,
    // and simdutf validates the units as well-formed UTF-16, the input for which ICU would emit the same units without
    // substituting U+FFFD. The previous call matters because the ICU converter may still hold an odd byte from a
    // streaming call: the converter is reset after every flush and after a throw, never between streaming calls, so
    // decoder->streaming() is true exactly when that byte may exist. Any other input returns nullopt, and the caller
    // falls back to ICU for surrogate replacement, fatal errors and streaming carry.
    static std::optional<String> tryDecodeUtf16LeFast(JSColloTextDecoder* decoder, JSC::JSGlobalObject* global_object,
        JSC::ThrowScope& scope, std::span<const uint8_t> bytes, bool stream)
    {
        if (stream || decoder->streaming() || !decoder->pending().empty())
            return std::nullopt;
        if (bytes.size() % 2 != 0)
            return std::nullopt;

        // bytes.data() may sit at any offset into an ArrayBuffer, so it can be misaligned for char16_t. The BOM check
        // and the copy below read through the byte span.
        // FIXME: simdutf documents no alignment requirement for validate_utf16le, but its scalar loop dereferences
        // this possibly misaligned char16_t pointer, which is undefined behavior in C++ even though x86_64 and ARM64
        // tolerate unaligned 16-bit loads.
        const size_t unit_count = bytes.size() / 2;
        if (!simdutf::validate_utf16le(reinterpret_cast<const char16_t*>(bytes.data()), unit_count))
            return std::nullopt;

        // A leading U+FEFF, the bytes FF FE, is dropped once per stream unless ignoreBOM is set, as
        // stringFromDecodedUnits does on the ICU path. Dropping it from the source span lets the result be allocated
        // once.
        size_t byte_start = 0;
        if (!decoder->bomSeen() && unit_count) {
            if (!decoder->ignoreBOM() && bytes[0] == 0xff && bytes[1] == 0xfe)
                byte_start = 2;
            decoder->markBOMSeen();
        }
        std::span<const uint8_t> payload = bytes.subspan(byte_start);
        if (payload.empty())
            return emptyString();

        std::span<char16_t> output;
        String decoded;
        if (!tryCreateUninitializedTextCodecString(payload.size() / 2, output, decoded)) {
            throwTextCodecOutOfMemory(global_object, scope);
            return String {};
        }
        std::memcpy(output.data(), payload.data(), payload.size());
        return decoded;
    }

    static bool switchUtf16Converter(JSColloTextDecoder* decoder, JSC::JSGlobalObject* global_object,
        JSC::ThrowScope& scope, TextDecoderEncoding encoding)
    {
        auto* converter = createIcuConverter(global_object, scope, encoding, decoder->fatal());
        RETURN_IF_EXCEPTION(scope, false);
        if (!converter)
            return false;
        decoder->replaceConverter(converter);
        return true;
    }

    static String decodeUtf16String(JSColloTextDecoder* decoder, JSC::JSGlobalObject* global_object,
        JSC::ThrowScope& scope, ByteSpan input, bool stream)
    {
        WTF::Vector<uint8_t, 16> joined;
        std::span<const uint8_t> bytes { input.data, input.size };
        if (!decoder->pending().empty()) {
            size_t joined_size = 0;
            if (!checkedAddSize(decoder->pending().size(), bytes.size(), joined_size)
                || !joined.tryReserveInitialCapacity(joined_size)) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return {};
            }
            joined.append(decoder->pending());
            joined.append(bytes);
            bytes = joined.span();
            decoder->clearPending();
        }

        // The fast path below needs to know that this call resolved little-endian, which is certain only when this
        // call did the BOM sniff, as a whole-buffer decode does. A streaming call after the sniff goes to ICU.
        // FIXME: The Encoding Standard maps "utf-16" and the other labels of this encoding to UTF-16LE and gives
        // TextDecoder no BOM sniffing, so leading FE FF bytes should decode as U+FFFE instead of switching this
        // decoder to UTF-16BE.
        bool resolved_le = false;
        if (!decoder->bomSeen()) {
            if (bytes.size() < 2 && stream) {
                decoder->setPending(bytes);
                return emptyString();
            }

            if (bytes.size() >= 2) {
                if (bytes[0] == 0xfe && bytes[1] == 0xff) {
                    if (!switchUtf16Converter(decoder, global_object, scope, TextDecoderEncoding::Utf16BE))
                        return {};
                    if (!decoder->ignoreBOM())
                        bytes = bytes.subspan(2);
                } else {
                    if (!switchUtf16Converter(decoder, global_object, scope, TextDecoderEncoding::Utf16LE))
                        return {};
                    if (!decoder->ignoreBOM() && bytes[0] == 0xff && bytes[1] == 0xfe)
                        bytes = bytes.subspan(2);
                    resolved_le = true;
                }
                decoder->markBOMSeen();
            } else if (!bytes.empty()) {
                if (!switchUtf16Converter(decoder, global_object, scope, TextDecoderEncoding::Utf16LE))
                    return {};
                decoder->markBOMSeen();
                resolved_le = true;
            }
        }

        // The sniff above consumed any BOM and set bomSeen(), so the fast path only validates and copies.
        if (resolved_le) {
            auto fast = tryDecodeUtf16LeFast(decoder, global_object, scope, bytes, stream);
            RETURN_IF_EXCEPTION(scope, {});
            if (fast)
                return WTF::move(*fast);
        }

        ByteSpan adjusted { bytes.data(), bytes.size() };
        return decodeIcuString(decoder, global_object, scope, adjusted, stream);
    }

    static String decodeTextDecoderString(JSColloTextDecoder* decoder, JSC::JSGlobalObject* global_object,
        JSC::ThrowScope& scope, ByteSpan input, bool stream)
    {
        if (whatwgSingleByteIndex(decoder->encoding()))
            return decodeWhatwgSingleByteString(decoder, global_object, scope, input);

        switch (decoder->encoding()) {
        case TextDecoderEncoding::Utf8:
            return decodeUtf8String(decoder, global_object, scope, input, stream);
        case TextDecoderEncoding::XUserDefined:
            return decodeXUserDefinedString(decoder, global_object, scope, input);
        case TextDecoderEncoding::Utf16:
            return decodeUtf16String(decoder, global_object, scope, input, stream);
        case TextDecoderEncoding::IBM866:
        case TextDecoderEncoding::ISO88592:
        case TextDecoderEncoding::ISO88593:
        case TextDecoderEncoding::ISO88594:
        case TextDecoderEncoding::ISO88595:
        case TextDecoderEncoding::ISO88596:
        case TextDecoderEncoding::ISO88597:
        case TextDecoderEncoding::ISO88598:
        case TextDecoderEncoding::ISO88598I:
        case TextDecoderEncoding::ISO885910:
        case TextDecoderEncoding::ISO885913:
        case TextDecoderEncoding::ISO885914:
        case TextDecoderEncoding::ISO885915:
            return decodeIcuString(decoder, global_object, scope, input, stream);
        case TextDecoderEncoding::ISO885916:
            return decodeIso885916String(decoder, global_object, scope, input);
        case TextDecoderEncoding::KOI8R:
        case TextDecoderEncoding::KOI8U:
        case TextDecoderEncoding::Windows874:
        case TextDecoderEncoding::Windows1250:
        case TextDecoderEncoding::Windows1251:
        case TextDecoderEncoding::Windows1252:
        case TextDecoderEncoding::Windows1253:
        case TextDecoderEncoding::Windows1254:
        case TextDecoderEncoding::Windows1255:
        case TextDecoderEncoding::Windows1256:
        case TextDecoderEncoding::Windows1257:
        case TextDecoderEncoding::Windows1258:
        case TextDecoderEncoding::Utf16LE: {
            // The "utf-16le" label has no BOM sniffing: tryDecodeUtf16LeFast or stringFromDecodedUnits drops a leading
            // U+FEFF, and ICU handles what the fast path declines.
            // FIXME: koi8-r and windows-1250, 1251, 1252, 1254, 1256, 1257 and 1258 share this block, so their
            // even-length input that validates as UTF-16LE is decoded as UTF-16LE instead of by their converter.
            std::span<const uint8_t> bytes { input.data, input.size };
            auto fast = tryDecodeUtf16LeFast(decoder, global_object, scope, bytes, stream);
            RETURN_IF_EXCEPTION(scope, {});
            if (fast)
                return WTF::move(*fast);
            return decodeIcuString(decoder, global_object, scope, input, stream);
        }
        case TextDecoderEncoding::Utf16BE:
        case TextDecoderEncoding::Big5:
        case TextDecoderEncoding::EUCJP:
        case TextDecoderEncoding::ISO2022JP:
        case TextDecoderEncoding::ShiftJIS:
        case TextDecoderEncoding::EUCKR:
        case TextDecoderEncoding::GBK:
        case TextDecoderEncoding::GB18030:
        case TextDecoderEncoding::Macintosh:
        case TextDecoderEncoding::XMacCyrillic:
            return decodeIcuString(decoder, global_object, scope, input, stream);
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

    static void resetTextDecoderAfterException(JSColloTextDecoder* decoder)
    {
        decoder->setStreaming(false);
        decoder->resetDecodeState();
    }

    struct TextEncoderStreamChunkPlan {
        size_t byte_length { 0 };
        char16_t pending { 0 };
        bool has_pending { false };
    };

    static bool addTextEncoderStreamCodePointLength(size_t& byte_length, uint32_t code_point)
    {
        return checkedAddInPlace(byte_length, utf8LengthForCodePoint(code_point));
    }

    template <typename CharacterType>
    static bool measureTextEncoderStreamChunk(
        std::span<const CharacterType> input, bool has_pending, char16_t pending, TextEncoderStreamChunkPlan& out)
    {
        out.byte_length = 0;
        out.has_pending = has_pending;
        out.pending = pending;
        if (input.empty())
            return true;

        size_t index = 0;
        if constexpr (sizeof(CharacterType) == 2) {
            if (out.has_pending) {
                if (isUtf16TrailingSurrogate(static_cast<char16_t>(input[0]))) {
                    if (!addTextEncoderStreamCodePointLength(
                            out.byte_length, utf16SurrogatePairCodePoint(out.pending, static_cast<char16_t>(input[0]))))
                        return false;
                    index = 1;
                } else if (!addTextEncoderStreamCodePointLength(out.byte_length, 0xfffd))
                    return false;
                out.has_pending = false;
                out.pending = 0;
            }
        } else if (out.has_pending) {
            if (!addTextEncoderStreamCodePointLength(out.byte_length, 0xfffd))
                return false;
            out.has_pending = false;
            out.pending = 0;
        }

        while (index < input.size()) {
            uint32_t code_point = input[index];
            if constexpr (sizeof(CharacterType) == 2) {
                char16_t current = static_cast<char16_t>(input[index]);
                if (isUtf16LeadingSurrogate(current)) {
                    if (index + 1 == input.size()) {
                        out.has_pending = true;
                        out.pending = current;
                        return true;
                    }
                    char16_t next = static_cast<char16_t>(input[index + 1]);
                    if (isUtf16TrailingSurrogate(next)) {
                        if (!addTextEncoderStreamCodePointLength(
                                out.byte_length, utf16SurrogatePairCodePoint(current, next)))
                            return false;
                        index += 2;
                        continue;
                    }
                    code_point = 0xfffd;
                } else if (isUtf16TrailingSurrogate(current))
                    code_point = 0xfffd;
            }
            if (!addTextEncoderStreamCodePointLength(out.byte_length, code_point))
                return false;
            ++index;
        }
        return true;
    }

    template <typename CharacterType>
    static size_t fillTextEncoderStreamChunk(std::span<const CharacterType> input, std::span<uint8_t> output,
        bool has_pending, char16_t pending, bool& out_has_pending, char16_t& out_pending)
    {
        out_has_pending = has_pending;
        out_pending = pending;
        if (input.empty())
            return 0;

        size_t written = 0;
        size_t index = 0;
        if constexpr (sizeof(CharacterType) == 2) {
            if (out_has_pending) {
                if (isUtf16TrailingSurrogate(static_cast<char16_t>(input[0]))) {
                    RELEASE_ASSERT(appendUtf8ToSpan(
                        utf16SurrogatePairCodePoint(out_pending, static_cast<char16_t>(input[0])), output, written));
                    index = 1;
                } else
                    RELEASE_ASSERT(appendUtf8ToSpan(0xfffd, output, written));
                out_has_pending = false;
                out_pending = 0;
            }
        } else if (out_has_pending) {
            RELEASE_ASSERT(appendUtf8ToSpan(0xfffd, output, written));
            out_has_pending = false;
            out_pending = 0;
        }

        while (index < input.size()) {
            uint32_t code_point = input[index];
            if constexpr (sizeof(CharacterType) == 2) {
                char16_t current = static_cast<char16_t>(input[index]);
                if (isUtf16LeadingSurrogate(current)) {
                    if (index + 1 == input.size()) {
                        out_has_pending = true;
                        out_pending = current;
                        return written;
                    }
                    char16_t next = static_cast<char16_t>(input[index + 1]);
                    if (isUtf16TrailingSurrogate(next)) {
                        RELEASE_ASSERT(appendUtf8ToSpan(utf16SurrogatePairCodePoint(current, next), output, written));
                        index += 2;
                        continue;
                    }
                    code_point = 0xfffd;
                } else if (isUtf16TrailingSurrogate(current))
                    code_point = 0xfffd;
            }
            RELEASE_ASSERT(appendUtf8ToSpan(code_point, output, written));
            ++index;
        }
        return written;
    }

    static JSColloTransformStream* textCodecTransformFromFunction(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSFunction* function)
    {
        JSValue value = function->get(global_object, transformStreamIdentifier(global_object));
        RETURN_IF_EXCEPTION(scope, nullptr);
        auto* stream = dynamicDowncast<JSColloTransformStream>(value);
        if (!stream)
            JSC::throwVMTypeError(global_object, scope, "Text codec transform state is unavailable"_s);
        return stream;
    }

    JSC_DEFINE_HOST_FUNCTION(
        textCodecTransformWriteCallback, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* transform = textCodecTransformFromFunction(
            global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
        RETURN_IF_EXCEPTION(scope, {});
        if (transform->backpressure())
            return transform->deferWrite(global_object, scope, call_frame->argument(0));
        return transform->performTransform(global_object, scope, call_frame->argument(0));
    }

    JSC_DEFINE_HOST_FUNCTION(
        textCodecReadablePullCallback, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* transform = textCodecTransformFromFunction(
            global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
        RETURN_IF_EXCEPTION(scope, {});
        transform->readablePulled(global_object);
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(
        textCodecReadableCancelCallback, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* transform = textCodecTransformFromFunction(
            global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
        RETURN_IF_EXCEPTION(scope, {});

        JSValue reason = call_frame->argument(0);
        JSValue cancel_result = JSC::jsUndefined();
        JSValue cancel = transform->cancelCallback();
        if (valueIsCallable(cancel)) {
            JSC::MarkedArgumentBuffer arguments;
            arguments.append(reason);
            if (arguments.hasOverflowed()) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return {};
            }
            auto call_data = JSC::getCallData(cancel);
            cancel_result
                = JSC::call(global_object, cancel.getObject(), call_data, transform->transformer(), arguments);
            RETURN_IF_EXCEPTION(scope, {});
        }
        transform->errorWritableAndUnblockWrite(global_object, reason);
        return JSValue::encode(cancel_result);
    }

    static void throwTextCodecQueueLimitExceeded(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
    {
        JSC::throwException(global_object, scope,
            createStreamQueueLimitExceededError(global_object, "Text codec stream queue limit exceeded"_s));
    }

    static bool queuedStringOutputWouldExceedLimit(size_t code_units)
    {
        return code_units > WebApiCodecStreamPendingOutputBytesMax / sizeof(char16_t);
    }

    static bool textEncoderStreamInputWouldExceedQueueLimit(size_t code_units)
    {
        return queuedStringOutputWouldExceedLimit(code_units);
    }

    static bool textDecoderStreamOutputMayExceedQueueLimit(JSColloTextDecoder* decoder, ByteSpan input)
    {
        size_t total_input_size = input.size;
        if (!checkedAddInPlace(total_input_size, decoder->pending().size()))
            return true;

        switch (decoder->encoding()) {
        case TextDecoderEncoding::Utf16:
        case TextDecoderEncoding::Utf16BE:
        case TextDecoderEncoding::Utf16LE:
            return total_input_size > WebApiCodecStreamPendingOutputBytesMax;
        default:
            return queuedStringOutputWouldExceedLimit(total_input_size);
        }
    }

    static JSColloTransformStream* createTextCodecTransform(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
        JSC::JSCell* owner, const JSC::Identifier& state_identifier, JSC::NativeFunction write_callback,
        JSC::NativeFunction close_callback, JSC::NativeFunction abort_callback, WTF::ASCIILiteral write_name,
        WTF::ASCIILiteral close_name, WTF::ASCIILiteral abort_name, JSC::NativeFunction queue_limit_callback,
        WTF::ASCIILiteral queue_limit_name)
    {
        auto& vm = global_object->vm();
        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        auto* transform = JSColloTransformStream::create(vm, collo_global);
        auto* transform_controller = JSColloTransformStreamDefaultController::create(vm, global_object, transform);
        transform->setController(vm, transform_controller);
        auto* readable = JSColloReadableStream::create(vm, collo_global);
        auto* readable_controller = JSColloReadableStreamDefaultController::create(vm, global_object, readable);
        readable->setController(vm, readable_controller);
        readable->setHighWaterMark(0);
        readable->setQueueMemoryCostLimit(WebApiCodecStreamPendingOutputBytesMax);

        auto make_transform_callback
            = [&](WTF::ASCIILiteral callback_name, JSC::NativeFunction callback, unsigned length) -> JSValue {
            auto* function = JSC::JSFunction::create(
                vm, global_object, length, callback_name, callback, JSC::ImplementationVisibility::Public);
            function->putDirect(vm, transformStreamIdentifier(global_object), transform,
                static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
            return function;
        };

        JSValue readable_pull_function
            = make_transform_callback("Text codec stream readable pull"_s, textCodecReadablePullCallback, 0);
        JSValue readable_cancel_function
            = make_transform_callback("Text codec stream readable cancel"_s, textCodecReadableCancelCallback, 1);
        readable_controller->setCallbacks(vm, readable_pull_function, readable_cancel_function, JSC::jsUndefined());
        transform->setReadable(vm, readable);
        transform->setBackpressure(true);

        auto make_callback
            = [&](WTF::ASCIILiteral callback_name, JSC::NativeFunction callback, unsigned length) -> JSValue {
            auto* function = JSC::JSFunction::create(
                vm, global_object, length, callback_name, callback, JSC::ImplementationVisibility::Public);
            function->putDirect(vm, state_identifier, owner, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
            return function;
        };

        JSValue write_function = make_callback(write_name, write_callback, 1);
        JSValue close_function = make_callback(close_name, close_callback, 0);
        JSValue abort_function = make_callback(abort_name, abort_callback, 1);
        JSValue queue_limit_function = make_callback(queue_limit_name, queue_limit_callback, 1);
        transform->setTransformer(vm, JSValue(owner));
        transform->setCallbacks(vm, JSC::jsUndefined(), write_function, close_function, abort_function);

        JSValue writable_write_function
            = make_transform_callback("Text codec stream write"_s, textCodecTransformWriteCallback, 1);
        auto* writable = createWritableStreamFromCallbacks(global_object, scope, JSC::jsUndefined(),
            writable_write_function, close_function, abort_function, JSC::jsUndefined(), 1);
        RETURN_IF_EXCEPTION(scope, nullptr);
        if (!writable)
            return nullptr;
        writable->setQueueMemoryCostLimit(WebApiCodecStreamPendingInputBytesMax);
        // The memory cost limit bills chunk payload only; WebApiCodecStreamPendingWritesMax in limits.h bounds the
        // writes that bill nothing. Either limit errors the stream through the same queue-limit callback.
        writable->setQueuePendingCountLimit(WebApiCodecStreamPendingWritesMax);
        writable->setQueueMemoryLimitExceededCallback(vm, queue_limit_function);
        transform->setWritable(vm, writable);
        return transform;
    }

    static JSColloTextEncoderStream* textEncoderStreamFromFunction(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSFunction* function)
    {
        JSValue value = function->get(global_object, textEncoderStreamStateIdentifier(global_object));
        RETURN_IF_EXCEPTION(scope, nullptr);
        auto* stream = dynamicDowncast<JSColloTextEncoderStream>(value);
        if (!stream)
            JSC::throwVMTypeError(global_object, scope, "TextEncoderStream state is unavailable"_s);
        return stream;
    }

    static JSColloTextDecoderStream* textDecoderStreamFromFunction(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSC::JSFunction* function)
    {
        JSValue value = function->get(global_object, textDecoderStreamStateIdentifier(global_object));
        RETURN_IF_EXCEPTION(scope, nullptr);
        auto* stream = dynamicDowncast<JSColloTextDecoderStream>(value);
        if (!stream)
            JSC::throwVMTypeError(global_object, scope, "TextDecoderStream state is unavailable"_s);
        return stream;
    }

    template <typename Stream>
    static EncodedJSValue finishTextCodecStreamCallback(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, Stream* stream, EncodedJSValue result)
    {
        auto* exception = scope.exception();
        if (!exception)
            return result;
        JSValue reason = exception->value();
        if (!scope.tryClearException())
            return result;
        stream->abort(global_object, reason);
        return JSValue::encode(JSC::throwException(global_object, scope, reason));
    }

    JSC_DEFINE_HOST_FUNCTION(
        textEncoderStreamWriteCallback, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = textEncoderStreamFromFunction(
            global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
        RETURN_IF_EXCEPTION(scope, {});
        auto result = stream->write(global_object, scope, call_frame->argument(0));
        return finishTextCodecStreamCallback(global_object, scope, stream, result);
    }

    JSC_DEFINE_HOST_FUNCTION(
        textEncoderStreamCloseCallback, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = textEncoderStreamFromFunction(
            global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
        RETURN_IF_EXCEPTION(scope, {});
        auto result = stream->close(global_object, scope);
        return finishTextCodecStreamCallback(global_object, scope, stream, result);
    }

    JSC_DEFINE_HOST_FUNCTION(
        textEncoderStreamAbortCallback, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = textEncoderStreamFromFunction(
            global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
        RETURN_IF_EXCEPTION(scope, {});
        stream->abort(global_object, call_frame->argument(0));
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(
        textEncoderStreamQueueLimitCallback, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = textEncoderStreamFromFunction(
            global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
        RETURN_IF_EXCEPTION(scope, {});
        stream->abort(global_object, call_frame->argument(0));
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(
        textDecoderStreamWriteCallback, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = textDecoderStreamFromFunction(
            global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
        RETURN_IF_EXCEPTION(scope, {});
        auto result = stream->write(global_object, scope, call_frame->argument(0));
        return finishTextCodecStreamCallback(global_object, scope, stream, result);
    }

    JSC_DEFINE_HOST_FUNCTION(
        textDecoderStreamCloseCallback, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = textDecoderStreamFromFunction(
            global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
        RETURN_IF_EXCEPTION(scope, {});
        auto result = stream->close(global_object, scope);
        return finishTextCodecStreamCallback(global_object, scope, stream, result);
    }

    JSC_DEFINE_HOST_FUNCTION(
        textDecoderStreamAbortCallback, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = textDecoderStreamFromFunction(
            global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
        RETURN_IF_EXCEPTION(scope, {});
        stream->abort(global_object, call_frame->argument(0));
        return JSValue::encode(JSC::jsUndefined());
    }

    JSC_DEFINE_HOST_FUNCTION(
        textDecoderStreamQueueLimitCallback, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = textDecoderStreamFromFunction(
            global_object, scope, uncheckedDowncast<JSC::JSFunction>(call_frame->jsCallee()));
        RETURN_IF_EXCEPTION(scope, {});
        stream->abort(global_object, call_frame->argument(0));
        return JSValue::encode(JSC::jsUndefined());
    }

    bool JSColloTextEncoderStream::initialize(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
    {
        auto* transform
            = createTextCodecTransform(global_object, scope, this, textEncoderStreamStateIdentifier(global_object),
                textEncoderStreamWriteCallback, textEncoderStreamCloseCallback, textEncoderStreamAbortCallback,
                "TextEncoderStream write"_s, "TextEncoderStream close"_s, "TextEncoderStream abort"_s,
                textEncoderStreamQueueLimitCallback, "TextEncoderStream queue limit"_s);
        RETURN_IF_EXCEPTION(scope, false);
        if (!transform)
            return false;
        m_transform.set(global_object->vm(), this, transform);
        return true;
    }

    JSColloReadableStream* JSColloTextEncoderStream::readable() const
    {
        auto* transform = m_transform.get();
        return transform ? transform->readable() : nullptr;
    }

    JSColloWritableStream* JSColloTextEncoderStream::writable() const
    {
        auto* transform = m_transform.get();
        return transform ? transform->writable() : nullptr;
    }

    EncodedJSValue JSColloTextEncoderStream::write(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue chunk)
    {
        auto* input = chunk.toString(global_object);
        RETURN_IF_EXCEPTION(scope, {});
        auto view = input->view(global_object);
        RETURN_IF_EXCEPTION(scope, {});
        if (textEncoderStreamInputWouldExceedQueueLimit(view->length())) {
            throwTextCodecQueueLimitExceeded(global_object, scope);
            return {};
        }

        TextEncoderStreamChunkPlan plan;
        if (view->is8Bit()) {
            if (!measureTextEncoderStreamChunk<Latin1Character>(
                    view->span8(), m_has_pending_leading_surrogate, m_pending_leading_surrogate, plan)) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return {};
            }
        } else if (!measureTextEncoderStreamChunk<char16_t>(
                       view->span16(), m_has_pending_leading_surrogate, m_pending_leading_surrogate, plan)) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return {};
        }

        auto* transform = m_transform.get();
        if (plan.byte_length > WebApiCodecStreamPendingOutputBytesMax) {
            throwTextCodecQueueLimitExceeded(global_object, scope);
            return {};
        }

        JSC::JSUint8Array* chunk_value = nullptr;
        if (plan.byte_length > 0) {
            chunk_value = createTextCodecUint8Array(global_object, scope, plan.byte_length);
            RETURN_IF_EXCEPTION(scope, {});
            if (!chunk_value)
                return {};
            auto output = std::span<uint8_t> { static_cast<uint8_t*>(chunk_value->vector()), plan.byte_length };
            bool next_has_pending = false;
            char16_t next_pending = 0;
            size_t written = 0;
            if (view->is8Bit())
                written = fillTextEncoderStreamChunk<Latin1Character>(view->span8(), output,
                    m_has_pending_leading_surrogate, m_pending_leading_surrogate, next_has_pending, next_pending);
            else
                written = fillTextEncoderStreamChunk<char16_t>(view->span16(), output, m_has_pending_leading_surrogate,
                    m_pending_leading_surrogate, next_has_pending, next_pending);
            RELEASE_ASSERT(written == plan.byte_length);
            m_has_pending_leading_surrogate = next_has_pending;
            m_pending_leading_surrogate = next_pending;
        } else {
            m_has_pending_leading_surrogate = plan.has_pending;
            m_pending_leading_surrogate = plan.pending;
        }

        if (chunk_value) {
            if (transform)
                transform->enqueue(global_object, scope, chunk_value);
            RETURN_IF_EXCEPTION(scope, {});
        }

        return JSValue::encode(JSC::jsUndefined());
    }

    EncodedJSValue JSColloTextEncoderStream::close(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
    {
        if (m_has_pending_leading_surrogate) {
            auto* chunk_value = createTextCodecUint8Array(global_object, scope, 3);
            RETURN_IF_EXCEPTION(scope, {});
            if (!chunk_value)
                return {};
            auto output = std::span<uint8_t> { static_cast<uint8_t*>(chunk_value->vector()), 3 };
            size_t written = 0;
            RELEASE_ASSERT(appendUtf8ToSpan(0xfffd, output, written));
            RELEASE_ASSERT(written == 3);
            m_has_pending_leading_surrogate = false;
            m_pending_leading_surrogate = 0;
            if (auto* transform = m_transform.get())
                transform->enqueue(global_object, scope, chunk_value);
            RETURN_IF_EXCEPTION(scope, {});
        }
        if (auto* readable_stream = readable())
            readable_stream->close(global_object);
        return JSValue::encode(JSC::jsUndefined());
    }

    void JSColloTextEncoderStream::abort(JSC::JSGlobalObject* global_object, JSValue reason)
    {
        m_has_pending_leading_surrogate = false;
        m_pending_leading_surrogate = 0;
        if (auto* transform = m_transform.get())
            transform->error(global_object, reason);
    }

    static bool streamInputBytes(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value,
        WTF::Vector<uint8_t>& snapshot, ByteSpan& out)
    {
        out = { nullptr, 0 };
        if (!value.isObject()) {
            JSC::throwVMTypeError(
                global_object, scope, "TextDecoderStream chunk must be an ArrayBuffer or ArrayBufferView"_s);
            return false;
        }

        if (auto* view = dynamicDowncast<JSC::JSArrayBufferView>(value)) {
            if (view->isDetached() || view->isOutOfBounds()) {
                out = { nullptr, 0 };
                return true;
            }
            const size_t byte_length = view->byteLength();
            if (byte_length > WebApiCodecStreamPendingInputBytesMax) {
                throwTextCodecQueueLimitExceeded(global_object, scope);
                return false;
            }
            return snapshotSharedByteSpan(global_object, scope,
                { static_cast<const uint8_t*>(view->vector()), byte_length }, view->isShared(), snapshot, out);
        }

        if (auto* array_buffer = dynamicDowncast<JSC::JSArrayBuffer>(value)) {
            auto* buffer = array_buffer->impl();
            if (!buffer || buffer->isDetached()) {
                out = { nullptr, 0 };
                return true;
            }
            const size_t byte_length = buffer->byteLength();
            if (byte_length > WebApiCodecStreamPendingInputBytesMax) {
                throwTextCodecQueueLimitExceeded(global_object, scope);
                return false;
            }
            return snapshotSharedByteSpan(global_object, scope,
                { static_cast<const uint8_t*>(buffer->data()), byte_length }, buffer->isShared(), snapshot, out);
        }

        JSC::throwVMTypeError(
            global_object, scope, "TextDecoderStream chunk must be an ArrayBuffer or ArrayBufferView"_s);
        return false;
    }

    bool JSColloTextDecoderStream::initialize(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
    {
        auto* transform
            = createTextCodecTransform(global_object, scope, this, textDecoderStreamStateIdentifier(global_object),
                textDecoderStreamWriteCallback, textDecoderStreamCloseCallback, textDecoderStreamAbortCallback,
                "TextDecoderStream write"_s, "TextDecoderStream close"_s, "TextDecoderStream abort"_s,
                textDecoderStreamQueueLimitCallback, "TextDecoderStream queue limit"_s);
        RETURN_IF_EXCEPTION(scope, false);
        if (!transform)
            return false;
        m_transform.set(global_object->vm(), this, transform);
        return true;
    }

    JSColloReadableStream* JSColloTextDecoderStream::readable() const
    {
        auto* transform = m_transform.get();
        return transform ? transform->readable() : nullptr;
    }

    JSColloWritableStream* JSColloTextDecoderStream::writable() const
    {
        auto* transform = m_transform.get();
        return transform ? transform->writable() : nullptr;
    }

    EncodedJSValue JSColloTextDecoderStream::write(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue chunk)
    {
        auto* current_decoder = decoder();
        if (!current_decoder)
            return JSC::throwVMTypeError(global_object, scope, "TextDecoderStream decoder is unavailable"_s);

        WTF::Vector<uint8_t> input_snapshot;
        ByteSpan bytes;
        if (!streamInputBytes(global_object, scope, chunk, input_snapshot, bytes))
            return {};
        RETURN_IF_EXCEPTION(scope, {});
        auto* transform = m_transform.get();
        if (textDecoderStreamOutputMayExceedQueueLimit(current_decoder, bytes)) {
            throwTextCodecQueueLimitExceeded(global_object, scope);
            return {};
        }
        auto decoded = decodeTextDecoderString(current_decoder, global_object, scope, bytes, true);
        if (scope.exception()) {
            resetTextDecoderAfterException(current_decoder);
            return {};
        }
        current_decoder->setStreaming(true);
        if (!decoded.isEmpty()) {
            if (transform)
                transform->enqueue(global_object, scope, JSC::jsString(global_object->vm(), decoded));
            RETURN_IF_EXCEPTION(scope, {});
        }
        return JSValue::encode(JSC::jsUndefined());
    }

    EncodedJSValue JSColloTextDecoderStream::close(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope)
    {
        auto* current_decoder = decoder();
        if (!current_decoder)
            return JSC::throwVMTypeError(global_object, scope, "TextDecoderStream decoder is unavailable"_s);

        ByteSpan empty { nullptr, 0 };
        auto decoded = decodeTextDecoderString(current_decoder, global_object, scope, empty, false);
        if (scope.exception()) {
            resetTextDecoderAfterException(current_decoder);
            return {};
        }
        current_decoder->setStreaming(false);
        current_decoder->resetDecodeState();
        if (!decoded.isEmpty()) {
            if (auto* transform = m_transform.get())
                transform->enqueue(global_object, scope, JSC::jsString(global_object->vm(), decoded));
            RETURN_IF_EXCEPTION(scope, {});
        }
        if (auto* readable_stream = readable())
            readable_stream->close(global_object);
        return JSValue::encode(JSC::jsUndefined());
    }

    void JSColloTextDecoderStream::abort(JSC::JSGlobalObject* global_object, JSValue reason)
    {
        if (auto* current_decoder = decoder()) {
            current_decoder->setStreaming(false);
            current_decoder->resetDecodeState();
        }
        if (auto* transform = m_transform.get())
            transform->error(global_object, reason);
    }

    JSC_DEFINE_HOST_FUNCTION(textEncoderConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        return JSC::throwVMTypeError(global_object, scope, "TextEncoder constructor requires 'new'"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(
        textEncoderConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* structure = textEncoderStructureForNewTarget(global_object, scope, call_frame);
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSColloTextEncoder::create(vm, structure));
    }

    JSC_DEFINE_HOST_FUNCTION(textDecoderConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        return JSC::throwVMTypeError(global_object, scope, "TextDecoder constructor requires 'new'"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(
        textDecoderConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        String label = "utf-8"_s;
        if (call_frame->argumentCount() > 0 && !call_frame->argument(0).isUndefined()) {
            label = call_frame->argument(0).toWTFString(global_object);
            RETURN_IF_EXCEPTION(scope, {});
        }
        auto encoding = parseTextDecoderEncoding(label);
        if (!encoding)
            return JSValue::encode(JSC::throwException(
                global_object, scope, JSC::createRangeError(global_object, "TextDecoder label is not supported"_s)));

        bool fatal = false;
        bool ignore_bom = false;
        auto options_value = call_frame->argument(1);
        if (!options_value.isUndefined() && !options_value.isNull()) {
            if (!options_value.isObject())
                return JSC::throwVMTypeError(global_object, scope, "TextDecoder options must be an object"_s);
            fatal = optionBoolean(global_object, scope, options_value, "fatal"_s);
            RETURN_IF_EXCEPTION(scope, {});
            ignore_bom = optionBoolean(global_object, scope, options_value, "ignoreBOM"_s);
            RETURN_IF_EXCEPTION(scope, {});
        }

        auto* converter = createIcuConverter(global_object, scope, *encoding, fatal);
        RETURN_IF_EXCEPTION(scope, {});

        auto* structure = textDecoderStructureForNewTarget(global_object, scope, call_frame);
        if (scope.exception()) {
            if (converter)
                ucnv_close(converter);
            return {};
        }
        return JSValue::encode(JSColloTextDecoder::create(vm, structure, *encoding, converter, fatal, ignore_bom));
    }

    static JSColloTextDecoder* createTextDecoderForStream(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue label_value, JSValue options_value)
    {
        auto& vm = global_object->vm();
        auto* collo_global = uncheckedDowncast<Collo::GlobalObject>(global_object);
        String label = "utf-8"_s;
        if (!label_value.isUndefined()) {
            label = label_value.toWTFString(global_object);
            RETURN_IF_EXCEPTION(scope, nullptr);
        }
        auto encoding = parseTextDecoderEncoding(label);
        if (!encoding) {
            JSC::throwException(
                global_object, scope, JSC::createRangeError(global_object, "TextDecoder label is not supported"_s));
            return nullptr;
        }

        bool fatal = false;
        bool ignore_bom = false;
        if (!options_value.isUndefined() && !options_value.isNull()) {
            if (!options_value.isObject()) {
                JSC::throwVMTypeError(global_object, scope, "TextDecoder options must be an object"_s);
                return nullptr;
            }
            fatal = optionBoolean(global_object, scope, options_value, "fatal"_s);
            RETURN_IF_EXCEPTION(scope, nullptr);
            ignore_bom = optionBoolean(global_object, scope, options_value, "ignoreBOM"_s);
            RETURN_IF_EXCEPTION(scope, nullptr);
        }

        auto* converter = createIcuConverter(global_object, scope, *encoding, fatal);
        RETURN_IF_EXCEPTION(scope, nullptr);
        return JSColloTextDecoder::create(
            vm, collo_global->textDecoderStructure(), *encoding, converter, fatal, ignore_bom);
    }

    JSC_DEFINE_HOST_FUNCTION(textEncoderStreamConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        return JSC::throwVMTypeError(global_object, scope, "TextEncoderStream constructor requires 'new'"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(
        textEncoderStreamConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* structure = textEncoderStreamStructureForNewTarget(global_object, scope, call_frame);
        RETURN_IF_EXCEPTION(scope, {});
        auto* stream = JSColloTextEncoderStream::create(vm, structure);
        if (!stream->initialize(global_object, scope))
            return {};
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(stream);
    }

    JSC_DEFINE_HOST_FUNCTION(textDecoderStreamConstructorCall, (JSC::JSGlobalObject * global_object, JSC::CallFrame*))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        return JSC::throwVMTypeError(global_object, scope, "TextDecoderStream constructor requires 'new'"_s);
    }

    JSC_DEFINE_HOST_FUNCTION(
        textDecoderStreamConstructorConstruct, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* structure = textDecoderStreamStructureForNewTarget(global_object, scope, call_frame);
        RETURN_IF_EXCEPTION(scope, {});
        auto* decoder
            = createTextDecoderForStream(global_object, scope, call_frame->argument(0), call_frame->argument(1));
        RETURN_IF_EXCEPTION(scope, {});
        if (!decoder)
            return {};
        auto* stream = JSColloTextDecoderStream::create(vm, structure, decoder);
        if (!stream->initialize(global_object, scope))
            return {};
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(stream);
    }

    JSC_DEFINE_HOST_FUNCTION(textEncoderGetEncoding, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        if (!requireTextEncoder(global_object, scope, call_frame->thisValue()))
            return {};
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsString(vm, String("utf-8"_s)));
    }

    JSC_DEFINE_HOST_FUNCTION(textDecoderGetEncoding, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* decoder = requireTextDecoder(global_object, scope, call_frame->thisValue());
        if (!decoder)
            return {};
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsString(vm, String(canonicalTextDecoderEncoding(decoder->encoding()))));
    }

    JSC_DEFINE_HOST_FUNCTION(
        textEncoderStreamGetEncoding, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        if (!requireTextEncoderStream(global_object, scope, call_frame->thisValue()))
            return {};
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
        return JSValue::encode(stream->readable());
    }

    JSC_DEFINE_HOST_FUNCTION(
        textEncoderStreamGetWritable, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireTextEncoderStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(stream->writable());
    }

    JSC_DEFINE_HOST_FUNCTION(
        textDecoderStreamGetEncoding, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireTextDecoderStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* decoder = stream->decoder();
        if (!decoder)
            return JSC::throwVMTypeError(global_object, scope, "TextDecoderStream decoder is unavailable"_s);
        return JSValue::encode(JSC::jsString(vm, String(canonicalTextDecoderEncoding(decoder->encoding()))));
    }

    JSC_DEFINE_HOST_FUNCTION(textDecoderGetFatal, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* decoder = requireTextDecoder(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsBoolean(decoder->fatal()));
    }

    JSC_DEFINE_HOST_FUNCTION(
        textDecoderStreamGetFatal, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireTextDecoderStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* decoder = stream->decoder();
        if (!decoder)
            return JSC::throwVMTypeError(global_object, scope, "TextDecoderStream decoder is unavailable"_s);
        return JSValue::encode(JSC::jsBoolean(decoder->fatal()));
    }

    JSC_DEFINE_HOST_FUNCTION(textDecoderGetIgnoreBOM, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* decoder = requireTextDecoder(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(JSC::jsBoolean(decoder->ignoreBOM()));
    }

    JSC_DEFINE_HOST_FUNCTION(
        textDecoderStreamGetIgnoreBOM, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireTextDecoderStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        auto* decoder = stream->decoder();
        if (!decoder)
            return JSC::throwVMTypeError(global_object, scope, "TextDecoderStream decoder is unavailable"_s);
        return JSValue::encode(JSC::jsBoolean(decoder->ignoreBOM()));
    }

    JSC_DEFINE_HOST_FUNCTION(
        textDecoderStreamGetReadable, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireTextDecoderStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(stream->readable());
    }

    JSC_DEFINE_HOST_FUNCTION(
        textDecoderStreamGetWritable, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* stream = requireTextDecoderStream(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(stream->writable());
    }

    JSC_DEFINE_HOST_FUNCTION(textEncoderEncode, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        if (!requireTextEncoder(global_object, scope, call_frame->thisValue()))
            return {};
        RETURN_IF_EXCEPTION(scope, {});

        auto input = optionalWebApiString(global_object, scope, call_frame, 0);
        RETURN_IF_EXCEPTION(scope, {});
        auto* array = createUtf8ArrayFromString(global_object, scope, input);
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(array);
    }

    JSC_DEFINE_HOST_FUNCTION(textEncoderEncodeInto, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        if (!requireTextEncoder(global_object, scope, call_frame->thisValue()))
            return {};
        RETURN_IF_EXCEPTION(scope, {});
        if (!requireArgumentCount(
                global_object, scope, call_frame, 2, "TextEncoder.encodeInto requires source and destination"_s))
            return {};
        RETURN_IF_EXCEPTION(scope, {});

        auto* input = call_frame->argument(0).toString(global_object);
        RETURN_IF_EXCEPTION(scope, {});
        auto* destination = dynamicDowncast<JSC::JSUint8Array>(call_frame->argument(1));
        if (!destination)
            return JSC::throwVMTypeError(
                global_object, scope, "TextEncoder.encodeInto destination must be a Uint8Array"_s);

        std::span<uint8_t> destination_bytes;
        if (!destination->isDetached() && !destination->isOutOfBounds())
            destination_bytes = { static_cast<uint8_t*>(destination->vector()), destination->byteLength() };

        auto result = encodeIntoString(global_object, scope, input, destination_bytes);
        RETURN_IF_EXCEPTION(scope, {});
        return JSValue::encode(createEncodeIntoResultObject(global_object, vm, result));
    }

    JSC_DEFINE_HOST_FUNCTION(textDecoderDecode, (JSC::JSGlobalObject * global_object, JSC::CallFrame* call_frame))
    {
        auto& vm = global_object->vm();
        auto scope = DECLARE_THROW_SCOPE(vm);
        auto* decoder = requireTextDecoder(global_object, scope, call_frame->thisValue());
        RETURN_IF_EXCEPTION(scope, {});

        bool stream = false;
        auto options_value = call_frame->argument(1);
        if (!options_value.isUndefinedOrNull() && !options_value.isObject())
            return JSC::throwVMTypeError(global_object, scope, "TextDecoder.decode options must be an object"_s);
        if (options_value.isObject()) {
            stream = optionBoolean(global_object, scope, options_value, "stream"_s);
            RETURN_IF_EXCEPTION(scope, {});
        }

        if (!decoder->streaming())
            decoder->resetDecodeState();

        WTF::Vector<uint8_t> input_snapshot;
        ByteSpan bytes;
        if (!inputBytes(global_object, scope, call_frame->argument(0), input_snapshot, bytes))
            return {};
        RETURN_IF_EXCEPTION(scope, {});

        auto decoded = decodeTextDecoderString(decoder, global_object, scope, bytes, stream);
        if (scope.exception()) {
            resetTextDecoderAfterException(decoder);
            return {};
        }
        decoder->setStreaming(stream);
        if (!stream)
            decoder->resetDecodeState();
        return JSValue::encode(JSC::jsString(vm, decoded));
    }

    static JSC::JSFunction* createConstructor(JSC::JSGlobalObject* global_object, JSC::VM& vm, WTF::ASCIILiteral name,
        unsigned length, JSC::NativeFunction call, JSC::NativeFunction construct)
    {
        auto* constructor = JSC::JSFunction::create(vm, global_object, length, name, call,
            JSC::ImplementationVisibility::Public, JSC::NoIntrinsic, construct, nullptr);
        RELEASE_ASSERT(constructor);
        return constructor;
    }

    static void installConstructor(Collo::GlobalObject* global_object, JSC::VM& vm, JSC::JSObject* prototype,
        JSC::JSFunction* constructor, WTF::ASCIILiteral name)
    {
        constructor->putDirect(vm, vm.propertyNames->prototype, prototype,
            JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum | JSC::PropertyAttribute::DontDelete);
        prototype->putDirect(
            vm, vm.propertyNames->constructor, constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
        JSC::Identifier identifier = JSC::Identifier::fromString(vm, name);
        global_object->putDirect(vm, identifier, constructor, static_cast<unsigned>(JSC::PropertyAttribute::DontEnum));
        RELEASE_ASSERT(global_object->getDirect(vm, identifier));
    }

    void installTextEncoder(Collo::GlobalObject* global_object, JSC::VM& vm, JSC::JSObject*& constructor,
        JSC::JSObject*& prototype, JSC::Structure*& structure)
    {
        constexpr unsigned enumerableAccessor = static_cast<unsigned>(JSC::PropertyAttribute::Accessor);
        constexpr unsigned enumerableFunction = static_cast<unsigned>(JSC::PropertyAttribute::None);
        prototype = JSC::constructEmptyObject(global_object, global_object->objectPrototype());
        putWebApiAccessor(
            global_object, prototype, vm, "encoding"_s, textEncoderGetEncoding, nullptr, enumerableAccessor);
        putWebApiFunction(global_object, prototype, vm, "encode"_s, 0, textEncoderEncode, enumerableFunction);
        putWebApiFunction(global_object, prototype, vm, "encodeInto"_s, 2, textEncoderEncodeInto, enumerableFunction);
        prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol, JSC::jsString(vm, String("TextEncoder"_s)),
            JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

        auto* function = createConstructor(
            global_object, vm, "TextEncoder"_s, 0, textEncoderConstructorCall, textEncoderConstructorConstruct);
        installConstructor(global_object, vm, prototype, function, "TextEncoder"_s);

        constructor = function;
        structure = JSColloTextEncoder::createStructure(vm, global_object, prototype);
    }

    void installTextDecoder(Collo::GlobalObject* global_object, JSC::VM& vm, JSC::JSObject*& constructor,
        JSC::JSObject*& prototype, JSC::Structure*& structure)
    {
        constexpr unsigned enumerableAccessor = static_cast<unsigned>(JSC::PropertyAttribute::Accessor);
        constexpr unsigned enumerableFunction = static_cast<unsigned>(JSC::PropertyAttribute::None);
        prototype = JSC::constructEmptyObject(global_object, global_object->objectPrototype());
        putWebApiAccessor(
            global_object, prototype, vm, "encoding"_s, textDecoderGetEncoding, nullptr, enumerableAccessor);
        putWebApiAccessor(global_object, prototype, vm, "fatal"_s, textDecoderGetFatal, nullptr, enumerableAccessor);
        putWebApiAccessor(
            global_object, prototype, vm, "ignoreBOM"_s, textDecoderGetIgnoreBOM, nullptr, enumerableAccessor);
        putWebApiFunction(global_object, prototype, vm, "decode"_s, 0, textDecoderDecode, enumerableFunction);
        prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol, JSC::jsString(vm, String("TextDecoder"_s)),
            JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

        auto* function = createConstructor(
            global_object, vm, "TextDecoder"_s, 0, textDecoderConstructorCall, textDecoderConstructorConstruct);
        installConstructor(global_object, vm, prototype, function, "TextDecoder"_s);

        constructor = function;
        structure = JSColloTextDecoder::createStructure(vm, global_object, prototype);
    }

    void installTextEncoderStream(Collo::GlobalObject* global_object, JSC::VM& vm, JSC::JSObject*& constructor,
        JSC::JSObject*& prototype, JSC::Structure*& structure)
    {
        constexpr unsigned enumerableAccessor = static_cast<unsigned>(JSC::PropertyAttribute::Accessor);
        prototype = JSC::constructEmptyObject(global_object, global_object->objectPrototype());
        putWebApiAccessor(
            global_object, prototype, vm, "encoding"_s, textEncoderStreamGetEncoding, nullptr, enumerableAccessor);
        putWebApiAccessor(
            global_object, prototype, vm, "readable"_s, textEncoderStreamGetReadable, nullptr, enumerableAccessor);
        putWebApiAccessor(
            global_object, prototype, vm, "writable"_s, textEncoderStreamGetWritable, nullptr, enumerableAccessor);
        prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol, JSC::jsString(vm, String("TextEncoderStream"_s)),
            JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

        auto* function = createConstructor(global_object, vm, "TextEncoderStream"_s, 0,
            textEncoderStreamConstructorCall, textEncoderStreamConstructorConstruct);
        installConstructor(global_object, vm, prototype, function, "TextEncoderStream"_s);

        constructor = function;
        structure = JSColloTextEncoderStream::createStructure(vm, global_object, prototype);
    }

    void installTextDecoderStream(Collo::GlobalObject* global_object, JSC::VM& vm, JSC::JSObject*& constructor,
        JSC::JSObject*& prototype, JSC::Structure*& structure)
    {
        constexpr unsigned enumerableAccessor = static_cast<unsigned>(JSC::PropertyAttribute::Accessor);
        prototype = JSC::constructEmptyObject(global_object, global_object->objectPrototype());
        putWebApiAccessor(
            global_object, prototype, vm, "encoding"_s, textDecoderStreamGetEncoding, nullptr, enumerableAccessor);
        putWebApiAccessor(
            global_object, prototype, vm, "fatal"_s, textDecoderStreamGetFatal, nullptr, enumerableAccessor);
        putWebApiAccessor(
            global_object, prototype, vm, "ignoreBOM"_s, textDecoderStreamGetIgnoreBOM, nullptr, enumerableAccessor);
        putWebApiAccessor(
            global_object, prototype, vm, "readable"_s, textDecoderStreamGetReadable, nullptr, enumerableAccessor);
        putWebApiAccessor(
            global_object, prototype, vm, "writable"_s, textDecoderStreamGetWritable, nullptr, enumerableAccessor);
        prototype->putDirect(vm, vm.propertyNames->toStringTagSymbol, JSC::jsString(vm, String("TextDecoderStream"_s)),
            JSC::PropertyAttribute::ReadOnly | JSC::PropertyAttribute::DontEnum);

        auto* function = createConstructor(global_object, vm, "TextDecoderStream"_s, 0,
            textDecoderStreamConstructorCall, textDecoderStreamConstructorConstruct);
        installConstructor(global_object, vm, prototype, function, "TextDecoderStream"_s);

        constructor = function;
        structure = JSColloTextDecoderStream::createStructure(vm, global_object, prototype);
    }

} // namespace

void installWebApiTextCodec(Collo::GlobalObject* global_object, JSC::VM& vm)
{
    JSC::JSObject* encoder_constructor = nullptr;
    JSC::JSObject* encoder_prototype = nullptr;
    JSC::Structure* encoder_structure = nullptr;
    installTextEncoder(global_object, vm, encoder_constructor, encoder_prototype, encoder_structure);

    JSC::JSObject* decoder_constructor = nullptr;
    JSC::JSObject* decoder_prototype = nullptr;
    JSC::Structure* decoder_structure = nullptr;
    installTextDecoder(global_object, vm, decoder_constructor, decoder_prototype, decoder_structure);

    JSC::JSObject* encoder_stream_constructor = nullptr;
    JSC::JSObject* encoder_stream_prototype = nullptr;
    JSC::Structure* encoder_stream_structure = nullptr;
    installTextEncoderStream(
        global_object, vm, encoder_stream_constructor, encoder_stream_prototype, encoder_stream_structure);

    JSC::JSObject* decoder_stream_constructor = nullptr;
    JSC::JSObject* decoder_stream_prototype = nullptr;
    JSC::Structure* decoder_stream_structure = nullptr;
    installTextDecoderStream(
        global_object, vm, decoder_stream_constructor, decoder_stream_prototype, decoder_stream_structure);

    global_object->cacheTextCodecApi(encoder_constructor, encoder_prototype, encoder_structure, decoder_constructor,
        decoder_prototype, decoder_structure, encoder_stream_constructor, encoder_stream_prototype,
        encoder_stream_structure, decoder_stream_constructor, decoder_stream_prototype, decoder_stream_structure);
}

} // namespace Collo::HostFunctions
