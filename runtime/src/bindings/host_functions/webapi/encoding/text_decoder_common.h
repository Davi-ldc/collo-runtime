// The state of the Encoding Standard's TextDecoderCommon mixin, which TextDecoder and TextDecoderStream both hold by
// value: an encoding, the fatal and ignoreBOM flags, whether the stream's BOM is settled, and what the encoding's
// decoder carries between streaming calls. Runs on the VM thread.
//
// Between streaming calls a decoder carries at most three bytes (an incomplete UTF-8 sequence, or an unfinished UTF-16
// code unit with the lead surrogate before it) and, for an ICU encoding, the converter's own state. A decode that
// flushes or throws resets all of it, so the next call starts a new stream. A decoder of an ICU encoding owns the one
// converter create() opened and closes it in release() or when destroyed; every other encoding decodes natively and
// opens none.

#pragma once

#include "jsc/runtime/state.h"

#include "host_functions/webapi/encoding/encodings.h"

#include <JavaScriptCore/JSGlobalObject.h>
#include <JavaScriptCore/ThrowScope.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

#include <array>
#include <cstdint>
#include <memory>
#include <optional>
#include <span>

struct UConverter;

namespace Collo::HostFunctions {

class TextDecoderCommon {
public:
    // The constructor steps TextDecoder and TextDecoderStream share. `label` converts to a string unless it is
    // undefined, which means "utf-8"; `options`, unless undefined or null, must be an object, whose `fatal` and
    // `ignoreBOM` members are read in that order. Only then is the label looked up. Throws a TypeError for options
    // that are not an object and a RangeError for an unknown label, returning nullopt with the exception pending.
    static std::optional<TextDecoderCommon> create(
        JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue label, JSC::JSValue options);

    TextDecoderCommon(TextDecoderCommon&&) = default;
    TextDecoderCommon& operator=(TextDecoderCommon&&) = default;
    TextDecoderCommon(const TextDecoderCommon&) = delete;
    TextDecoderCommon& operator=(const TextDecoderCommon&) = delete;
    ~TextDecoderCommon() = default;

    TextEncoding encoding() const { return m_encoding; }
    bool fatal() const { return m_fatal; }
    bool ignoreBOM() const { return m_ignore_bom; }

    // Decodes `bytes` after whatever the previous streaming call carried. With `stream`, a sequence cut off at the end
    // is carried to the next call; without it, the call flushes, so a cut-off sequence decodes as an error, and the
    // decoder starts over. A fatal decoder throws a TypeError for the first error; a replacing one emits U+FFFD. A
    // decode that throws, for an error or an allocation, also starts over. `bytes` must stay unchanged during the
    // call, which runs no JavaScript.
    // FIXME: The Encoding Standard's decode() starts over only after a call without `stream`. After a fatal error in
    // a call with `stream`, it keeps the stream: the BOM state stays, and the bytes the decoder handed back at the
    // error (the byte that broke a UTF-8 sequence, the unit after a lone UTF-16 lead) are decoded again first by the
    // next call.
    WTF::String decode(JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<const uint8_t> bytes, bool stream);

    // Closes the converter and drops the carried state, keeping what encoding(), fatal() and ignoreBOM() read. No
    // decode follows; a stream calls it once it finished, errored or was canceled.
    void release();

private:
    struct IcuConverterCloser {
        void operator()(UConverter*) const;
    };
    using IcuConverter = std::unique_ptr<UConverter, IcuConverterCloser>;

    TextDecoderCommon(TextEncoding encoding, IcuConverter converter, bool fatal, bool ignore_bom)
        : m_converter(WTF::move(converter))
        , m_encoding(encoding)
        , m_fatal(fatal)
        , m_ignore_bom(ignore_bom)
    {
    }

    WTF::String decodeChunk(JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<const uint8_t>, bool stream);
    WTF::String decodeUtf8(JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<const uint8_t>, bool stream);
    WTF::String decodeUtf8Run(JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<const uint8_t>);
    size_t consumeUtf8Bom(std::span<const uint8_t> stream_prefix);
    template <bool big_endian>
    WTF::String decodeUtf16(JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<const uint8_t>, bool stream);
    WTF::String utf16Output(JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<const char16_t> units);
    WTF::String decodeSingleByte(
        JSC::JSGlobalObject*, JSC::ThrowScope&, const SingleByteIndex&, std::span<const uint8_t>);
    WTF::String decodeXUserDefined(JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<const uint8_t>);
    WTF::String decodeIcu(JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<const uint8_t>, bool stream);
    bool appendDecodeError(JSC::JSGlobalObject*, JSC::ThrowScope&, WTF::Vector<char16_t>& units);

    std::span<const uint8_t> pending() const { return { m_pending.data(), m_pending_length }; }
    void setPending(std::span<const uint8_t>);
    void reset();

    IcuConverter m_converter;
    std::array<uint8_t, 3> m_pending {};
    uint8_t m_pending_length { 0 };
    TextEncoding m_encoding;
    bool m_fatal;
    bool m_ignore_bom;
    bool m_bom_seen { false };
};

// Reads the boolean member `name` of a TextDecoderOptions or TextDecodeOptions dictionary: false when `dictionary` is
// not an object or the member is absent or undefined, else its ToBoolean. The read may run a getter, so the caller
// checks the scope afterwards.
bool decoderOptionBoolean(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue dictionary, WTF::ASCIILiteral name);

// Borrows the bytes of an ArrayBuffer or ArrayBufferView for decode(). A detached buffer or an out-of-bounds view has
// no bytes. Bytes held in a SharedArrayBuffer are copied into `snapshot` first, because shared memory can change while
// the decoder reads it; other bytes are borrowed in place until the caller next runs JavaScript, which could detach
// the buffer. Any other value throws a TypeError carrying `type_error`; a failed copy throws an OutOfMemoryError.
bool decoderInputBytes(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue, WTF::ASCIILiteral type_error,
    WTF::Vector<uint8_t>& snapshot, std::span<const uint8_t>& out);

} // namespace Collo::HostFunctions
