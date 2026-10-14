// The form body codec declared in multipart.h, which owns its contract: the form Content-Type check, the
// multipart/form-data parser and the multipart/form-data serializer. Runs on the VM thread.
//
// The parser checks the opening delimiter at offset 0 and finds each later one with a Knuth-Morris-Pratt search whose
// restarts never overlap (findMultipartDelimiter), so a hostile body costs time linear in its length.
//
// The serializer makes two passes over the same pieces in the same order (writeMultipartBody). The first sums them
// against WebApiMaterializedBodyBytesMax, so an oversized FormData is refused before anything is copied, and records
// the size of each run of owned bytes between shared file ranges. The second writes each run into a buffer of exactly
// that size, so the body keeps no spare capacity for as long as it lives. Its boundary carries 128 bits from RAND_bytes
// drawn after the entries are fixed, so no entry can be prepared to contain it, and the content is not scanned for it.

#include "host_functions/webapi/files/multipart.h"

#include "host_functions/webapi/encoding/utf8.h"
#include "host_functions/webapi/limits.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/JSCInlines.h>
#include <openssl/rand.h>
#include <wtf/StdLibExtras.h>
#include <wtf/text/Latin1Character.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/StringView.h>

#include <algorithm>
#include <array>
#include <cstring>
#include <limits>
#include <utility>

namespace Collo::HostFunctions {
namespace {

    using WTF::String;

    bool isAsciiWhitespace(char16_t character)
    {
        return character == ' ' || character == '\t' || character == '\n' || character == '\r' || character == 0x0b
            || character == 0x0c;
    }

    String trimAscii(const String& value)
    {
        unsigned start = 0;
        unsigned end = value.length();
        while (start < end && isAsciiWhitespace(value[start]))
            start++;
        while (end > start && isAsciiWhitespace(value[end - 1]))
            end--;
        return value.substring(start, end - start);
    }

    bool containsHeaderLineBreak(const String& value)
    {
        return value.find('\r') != notFound || value.find('\n') != notFound;
    }

    // A header parameter's value: a token as written, or a quoted string with its backslash escapes resolved and
    // nothing but whitespace after the closing quote. A line break anywhere, or an unclosed quote, fails.
    bool parseHeaderParameterValue(const String& raw_value, String& out)
    {
        auto value = trimAscii(raw_value);
        if (containsHeaderLineBreak(value))
            return false;
        if (value.isEmpty() || value[0] != '"') {
            out = WTF::move(value);
            return true;
        }

        WTF::StringBuilder builder;
        for (unsigned index = 1; index < value.length(); index++) {
            auto character = value[index];
            if (character == '"') {
                for (unsigned tail = index + 1; tail < value.length(); tail++) {
                    if (!isAsciiWhitespace(value[tail]))
                        return false;
                }
                out = builder.toString();
                return true;
            }
            if (character == '\\' && index + 1 < value.length())
                character = value[++index];
            builder.append(character);
        }
        return false;
    }

    constexpr unsigned headerParameterSeparatorNotFound = std::numeric_limits<unsigned>::max();

    // The next ';' at or after `start` outside a quoted string.
    unsigned findHeaderParameterSeparator(const String& value, unsigned start)
    {
        bool in_quote = false;
        bool escaped = false;
        for (unsigned index = start; index < value.length(); index++) {
            auto character = value[index];
            if (escaped) {
                escaped = false;
                continue;
            }
            if (in_quote && character == '\\') {
                escaped = true;
                continue;
            }
            if (character == '"') {
                in_quote = !in_quote;
                continue;
            }
            if (!in_quote && character == ';')
                return index;
        }
        return headerParameterSeparatorNotFound;
    }

    // Calls `visit(name, raw_value)` for each `name=value` parameter after the first ';' of a header value, with the
    // name trimmed and lowercased and the value as written. A parameter without '=' goes to `visit` with a null value.
    // Stops, returning false, as soon as `visit` returns false.
    template <typename Visitor> bool forEachHeaderParameter(const String& header_value, Visitor visit)
    {
        auto semicolon = header_value.find(';');
        if (semicolon == notFound)
            return true;
        unsigned cursor = semicolon + 1;
        while (cursor <= header_value.length()) {
            auto next = findHeaderParameterSeparator(header_value, cursor);
            auto segment
                = trimAscii(next == headerParameterSeparatorNotFound ? header_value.substring(cursor)
                                                                     : header_value.substring(cursor, next - cursor));
            if (!segment.isEmpty()) {
                auto equals = segment.find('=');
                bool keep_going = equals == notFound
                    ? visit(segment.convertToASCIILowercase(), String())
                    : visit(trimAscii(segment.substring(0, equals)).convertToASCIILowercase(),
                          segment.substring(equals + 1));
                if (!keep_going)
                    return false;
            }
            if (next == headerParameterSeparatorNotFound)
                break;
            cursor = next + 1;
        }
        return true;
    }

    // RFC 2046 section 5.1.1: a boundary is 1 to 70 characters from bcharsnospace, plus spaces that do not end it.
    // Every such character is ASCII, so a valid boundary's characters are its bytes. No character is CR or LF, which
    // findMultipartDelimiter relies on.
    bool isValidBoundary(WTF::StringView boundary)
    {
        if (boundary.isEmpty() || boundary.length() > WebApiFormDataBoundaryBytesMax)
            return false;
        for (unsigned index = 0; index < boundary.length(); index++) {
            char16_t character = boundary[index];
            bool is_final = index + 1 == boundary.length();
            bool is_boundary_character = (character >= '0' && character <= '9')
                || (character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z') || character == '\''
                || character == '(' || character == ')' || character == '+' || character == '_' || character == ','
                || character == '-' || character == '.' || character == '/' || character == ':' || character == '='
                || character == '?' || (character == ' ' && !is_final);
            if (!is_boundary_character)
                return false;
        }
        return true;
    }

    std::optional<uint8_t> hexValue(uint8_t character)
    {
        if (character >= '0' && character <= '9')
            return static_cast<uint8_t>(character - '0');
        if (character >= 'a' && character <= 'f')
            return static_cast<uint8_t>(character - 'a' + 10);
        if (character >= 'A' && character <= 'F')
            return static_cast<uint8_t>(character - 'A' + 10);
        return std::nullopt;
    }

    bool isRFC5987AttributeChar(char16_t character)
    {
        if ((character >= '0' && character <= '9') || (character >= 'A' && character <= 'Z')
            || (character >= 'a' && character <= 'z'))
            return true;
        switch (character) {
        case '!':
        case '#':
        case '$':
        case '&':
        case '+':
        case '-':
        case '.':
        case '^':
        case '_':
        case '`':
        case '|':
        case '~':
            return true;
        default:
            return false;
        }
    }

    enum class RFC5987DecodeResult : uint8_t {
        Decoded,
        Invalid,
        OutOfMemory,
    };

    // RFC 5987's ext-value with the UTF-8 charset: `UTF-8'language'percent-encoded-bytes`. Any other charset, an
    // invalid escape or bytes that are not UTF-8 make the value invalid, and the caller ignores the parameter.
    RFC5987DecodeResult decodeRFC5987Value(const String& value, String& out)
    {
        auto first_quote = value.find('\'');
        if (first_quote == notFound)
            return RFC5987DecodeResult::Invalid;
        auto second_quote = value.find('\'', first_quote + 1);
        if (second_quote == notFound)
            return RFC5987DecodeResult::Invalid;
        if (value.substring(0, first_quote).convertToASCIILowercase() != "utf-8"_s)
            return RFC5987DecodeResult::Invalid;

        WTF::Vector<uint8_t> decoded;
        for (unsigned index = second_quote + 1; index < value.length(); index++) {
            auto character = value[index];
            if (character == '%') {
                if (index + 2 >= value.length())
                    return RFC5987DecodeResult::Invalid;
                auto high = value[index + 1] < 0x80 ? hexValue(value[index + 1]) : std::nullopt;
                auto low = value[index + 2] < 0x80 ? hexValue(value[index + 2]) : std::nullopt;
                if (!high || !low)
                    return RFC5987DecodeResult::Invalid;
                if (!decoded.tryAppend(static_cast<uint8_t>((*high << 4) | *low)))
                    return RFC5987DecodeResult::OutOfMemory;
                index += 2;
                continue;
            }
            if (!isRFC5987AttributeChar(character))
                return RFC5987DecodeResult::Invalid;
            if (!decoded.tryAppend(static_cast<uint8_t>(character)))
                return RFC5987DecodeResult::OutOfMemory;
        }
        switch (decodeUtf8Fatal(decoded.span(), out)) {
        case Utf8DecodeResult::Decoded:
            return RFC5987DecodeResult::Decoded;
        case Utf8DecodeResult::Invalid:
            return RFC5987DecodeResult::Invalid;
        case Utf8DecodeResult::OutOfMemory:
            return RFC5987DecodeResult::OutOfMemory;
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

    // A part's Content-Type, trimmed and lowercased, or empty when it holds a character outside printable ASCII, as
    // the File API normalizes a type.
    String normalizePartContentType(const String& input)
    {
        auto trimmed = trimAscii(input);
        WTF::StringBuilder builder;
        builder.reserveCapacity(trimmed.length());
        for (unsigned index = 0; index < trimmed.length(); index++) {
            char16_t character = trimmed[index];
            if (character < 0x20 || character > 0x7e)
                return emptyString();
            if (character >= 'A' && character <= 'Z')
                character = static_cast<char16_t>(character + 0x20);
            builder.append(character);
        }
        return builder.toString();
    }

    struct PartHeaders {
        String name;
        String filename;
        String filename_star;
        String content_type;
        bool has_name { false };
        bool has_filename { false };
        bool has_filename_star { false };
    };

    bool parseContentDisposition(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const String& value,
        PartHeaders& out, std::optional<WTF::ASCIILiteral>& parse_error)
    {
        auto semicolon = value.find(';');
        auto disposition
            = trimAscii(semicolon == notFound ? value : value.substring(0, semicolon)).convertToASCIILowercase();
        if (disposition != "form-data"_s) {
            parse_error = "invalid multipart content disposition"_s;
            return false;
        }

        bool parameters_valid = forEachHeaderParameter(value, [&](const String& name, const String& raw_value) {
            if (raw_value.isNull())
                return !name.startsWith("filename*"_s);
            String parameter_value;
            if (!parseHeaderParameterValue(raw_value, parameter_value))
                return false;
            if (name == "name"_s) {
                out.name = WTF::move(parameter_value);
                out.has_name = true;
            } else if (name == "filename"_s) {
                out.filename = WTF::move(parameter_value);
                out.has_filename = true;
            } else if (name == "filename*"_s) {
                String decoded;
                switch (decodeRFC5987Value(parameter_value, decoded)) {
                case RFC5987DecodeResult::Decoded:
                    out.filename_star = WTF::move(decoded);
                    out.has_filename = true;
                    out.has_filename_star = true;
                    break;
                case RFC5987DecodeResult::Invalid:
                    break;
                case RFC5987DecodeResult::OutOfMemory:
                    JSC::throwOutOfMemoryError(global_object, scope);
                    return false;
                }
            }
            return true;
        });
        if (!parameters_valid) {
            if (!scope.exception())
                parse_error = "invalid multipart content disposition"_s;
            return false;
        }

        if (!out.has_name) {
            parse_error = "multipart part missing name"_s;
            return false;
        }
        return true;
    }

    bool parsePartHeaders(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const uint8_t> bytes,
        PartHeaders& out, std::optional<WTF::ASCIILiteral>& parse_error)
    {
        size_t line_start = 0;
        unsigned header_count = 0;
        bool saw_disposition = false;
        while (line_start < bytes.size()) {
            size_t line_end = line_start;
            while (line_end + 1 < bytes.size() && !(bytes[line_end] == '\r' && bytes[line_end + 1] == '\n'))
                line_end++;
            const bool has_line_terminator
                = line_end + 1 < bytes.size() && bytes[line_end] == '\r' && bytes[line_end + 1] == '\n';
            if (!has_line_terminator)
                line_end = bytes.size();
            auto line = bytes.subspan(line_start, line_end - line_start);
            auto colon = std::find(line.begin(), line.end(), static_cast<uint8_t>(':'));
            if (colon == line.end()) {
                parse_error = "invalid multipart header"_s;
                return false;
            }
            if (++header_count > WebApiFormDataPartHeadersMax) {
                parse_error = FormDataPartHeadersExceeded;
                return false;
            }

            String name;
            if (!decodeUtf8BytesPreservingBom(global_object, scope, line.subspan(0, colon - line.begin()), name))
                return false;
            name = trimAscii(name).convertToASCIILowercase();
            String value;
            if (!decodeUtf8BytesPreservingBom(global_object, scope, line.subspan((colon - line.begin()) + 1), value))
                return false;
            if (name == "content-disposition"_s) {
                saw_disposition = true;
                if (!parseContentDisposition(global_object, scope, trimAscii(value), out, parse_error))
                    return false;
            } else if (name == "content-type"_s)
                out.content_type = normalizePartContentType(value);

            if (!has_line_terminator)
                break;
            line_start = line_end + 2;
        }

        if (!saw_disposition) {
            parse_error = "multipart part missing content disposition"_s;
            return false;
        }
        return true;
    }

    // The Knuth-Morris-Pratt failure table of `needle`. Returns false when it cannot be allocated.
    bool buildByteSearchTable(std::span<const uint8_t> needle, WTF::Vector<size_t>& table)
    {
        table.clear();
        if (!table.tryReserveInitialCapacity(needle.size()))
            return false;
        if (needle.empty())
            return true;
        table.append(0);

        size_t prefix_size = 0;
        for (size_t index = 1; index < needle.size();) {
            if (needle[index] == needle[prefix_size]) {
                prefix_size++;
                table.append(prefix_size);
                index++;
                continue;
            }
            if (prefix_size) {
                prefix_size = table[prefix_size - 1];
                continue;
            }
            table.append(0);
            index++;
        }
        return true;
    }

    // A needle with its search table, which findBytes walks in time linear in the haystack.
    struct ByteSearch {
        std::span<const uint8_t> needle;
        WTF::Vector<size_t> table;
    };

    size_t findBytes(std::span<const uint8_t> haystack, const ByteSearch& search, size_t start)
    {
        auto needle = search.needle;
        if (needle.empty() || haystack.size() < needle.size() || start > haystack.size() - needle.size())
            return notFound;

        size_t matched = 0;
        for (size_t index = start; index < haystack.size(); index++) {
            while (matched && haystack[index] != needle[matched])
                matched = search.table[matched - 1];
            if (haystack[index] != needle[matched])
                continue;
            matched++;
            if (matched == needle.size())
                return index + 1 - needle.size();
        }
        return notFound;
    }

    bool startsWithBytes(std::span<const uint8_t> bytes, size_t offset, std::span<const uint8_t> prefix)
    {
        return offset <= bytes.size() && prefix.size() <= bytes.size() - offset
            && std::memcmp(bytes.data() + offset, prefix.data(), prefix.size()) == 0;
    }

    constexpr uint8_t crlf_bytes[] = { '\r', '\n' };

    // After a delimiter, `--` then optional transport padding and CRLF, or the end of the body, closes the body.
    bool isMultipartCloseDelimiterSuffix(std::span<const uint8_t> body, size_t offset)
    {
        constexpr uint8_t close_bytes[] = { '-', '-' };
        if (!startsWithBytes(body, offset, close_bytes))
            return false;
        size_t cursor = offset + sizeof(close_bytes);
        if (cursor == body.size())
            return true;
        while (cursor < body.size() && (body[cursor] == ' ' || body[cursor] == '\t'))
            cursor++;
        return startsWithBytes(body, cursor, crlf_bytes);
    }

    // After a delimiter, optional transport padding then CRLF starts the next part, at the returned offset.
    std::optional<size_t> multipartRegularDelimiterSuffixEnd(std::span<const uint8_t> body, size_t offset)
    {
        size_t cursor = offset;
        while (cursor < body.size() && (body[cursor] == ' ' || body[cursor] == '\t'))
            cursor++;
        if (!startsWithBytes(body, cursor, crlf_bytes))
            return std::nullopt;
        return cursor + sizeof(crlf_bytes);
    }

    // The next occurrence of `delimiter` (CRLF, `--` and the boundary) at or after `start` that a valid suffix
    // follows, so delimiter-like bytes inside a part's data are skipped. A candidate without a valid suffix restarts
    // the search one byte later, which keeps the whole search linear: the needle's only CR is its first byte, since a
    // boundary holds no CR (isValidBoundary), so the next candidate starts past the end of this one, and the restart
    // rescans fewer than delimiter.needle.size() bytes that no other candidate covers.
    size_t findMultipartDelimiter(std::span<const uint8_t> body, const ByteSearch& delimiter, size_t start)
    {
        size_t search_start = start;
        while (search_start < body.size()) {
            auto candidate = findBytes(body, delimiter, search_start);
            if (candidate == notFound)
                return notFound;
            size_t suffix = candidate + delimiter.needle.size();
            if (multipartRegularDelimiterSuffixEnd(body, suffix) || isMultipartCloseDelimiterSuffix(body, suffix))
                return candidate;
            search_start = candidate + 1;
        }
        return notFound;
    }

    // The serialized body's boundary: a fixed prefix, then the 128 random bits in lowercase hex.
    constexpr WTF::ASCIILiteral boundary_prefix = "----ColloFormBoundary"_s;
    constexpr size_t boundary_random_bytes = 16;
    constexpr size_t boundary_length = boundary_prefix.length() + 2 * boundary_random_bytes;
    using MultipartBoundary = std::array<uint8_t, boundary_length>;

    // The framing HTML's multipart/form-data encoding algorithm writes around each part.
    constexpr WTF::ASCIILiteral delimiter_dashes = "--"_s;
    constexpr WTF::ASCIILiteral disposition_start = "\r\nContent-Disposition: form-data; name=\""_s;
    constexpr WTF::ASCIILiteral filename_start = "\"; filename=\""_s;
    constexpr WTF::ASCIILiteral content_type_start = "\"\r\nContent-Type: "_s;
    // A file part without a type is labeled application/octet-stream, as RFC 7578 (section 4.4) advises.
    constexpr WTF::ASCIILiteral default_content_type = "application/octet-stream"_s;
    constexpr WTF::ASCIILiteral file_headers_end = "\r\n\r\n"_s;
    constexpr WTF::ASCIILiteral text_headers_end = "\"\r\n\r\n"_s;
    constexpr WTF::ASCIILiteral part_end = "\r\n"_s;
    constexpr WTF::ASCIILiteral body_end = "--\r\n"_s;

    // The smallest part, a text entry with an empty name and value, and the closing delimiter written once.
    constexpr size_t smallest_part_length = delimiter_dashes.length() + boundary_length + disposition_start.length()
        + text_headers_end.length() + part_end.length();
    constexpr size_t closing_delimiter_length = delimiter_dashes.length() + boundary_length + body_end.length();
    static_assert(closing_delimiter_length < WebApiMaterializedBodyBytesMax);

    bool generateMultipartBoundary(MultipartBoundary& out)
    {
        constexpr char hex[] = "0123456789abcdef";
        uint8_t random[boundary_random_bytes];
        if (RAND_bytes(random, sizeof(random)) != 1)
            return false;
        memcpySpan(std::span { out }, boundary_prefix.span8());
        size_t cursor = boundary_prefix.length();
        for (auto byte : random) {
            out[cursor++] = static_cast<uint8_t>(hex[byte >> 4]);
            out[cursor++] = static_cast<uint8_t>(hex[byte & 0x0f]);
        }
        return true;
    }

    // A field name or filename as HTML's multipart/form-data encoding algorithm writes it: its UTF-8, with CR, LF and
    // '"' written as %0D, %0A and %22. Each of the three is one ASCII code unit and one UTF-8 byte, so each adds two
    // bytes to the plain encoding.
    struct HeaderParameterLength {
        size_t utf8 { 0 };
        size_t escaped { 0 };
    };

    template <typename CharacterType> size_t countHeaderParameterEscapes(std::span<const CharacterType> characters)
    {
        return static_cast<size_t>(std::count_if(characters.begin(), characters.end(),
            [](CharacterType character) { return character == '\r' || character == '\n' || character == '"'; }));
    }

    HeaderParameterLength headerParameterLength(WTF::StringView value)
    {
        const size_t escapes
            = value.is8Bit() ? countHeaderParameterEscapes(value.span8()) : countHeaderParameterEscapes(value.span16());
        // A WTF string holds at most WTF::String::MaxLength code units, so neither sum nears SIZE_MAX.
        const size_t utf8 = utf8EncodedLength(value);
        return { utf8, utf8 + 2 * escapes };
    }

    enum class WriteResult : uint8_t {
        Written,
        Exceeded,
        OutOfMemory,
    };

    // The first pass: sums every piece against WebApiMaterializedBodyBytesMax and records the size of each run of
    // owned bytes (framing, headers and text values) that a shared file range or the end of the body closes.
    class MultipartBodyMeasure {
    public:
        WriteResult literal(WTF::ASCIILiteral literal) { return owned(literal.length()); }
        WriteResult bytes(std::span<const uint8_t> bytes) { return owned(bytes.size()); }
        WriteResult utf8(const String& value) { return owned(utf8EncodedLength(value)); }
        WriteResult headerParameter(const String& value) { return owned(headerParameterLength(value).escaped); }

        WriteResult shared(const BlobStorage&, size_t, size_t size)
        {
            if (!size)
                return WriteResult::Written;
            if (auto result = add(size); result != WriteResult::Written)
                return result;
            return closeRun();
        }

        WriteResult finish() { return closeRun(); }

        size_t size() const { return m_size; }
        std::span<const size_t> runSizes() const LIFETIME_BOUND { return m_run_sizes.span(); }

    private:
        WriteResult add(size_t size)
        {
            if (size > WebApiMaterializedBodyBytesMax - m_size)
                return WriteResult::Exceeded;
            m_size += size;
            return WriteResult::Written;
        }

        WriteResult owned(size_t size)
        {
            auto result = add(size);
            if (result == WriteResult::Written)
                m_run_size += size;
            return result;
        }

        // An empty run is not recorded, and MultipartBodyWriter opens no buffer for one.
        WriteResult closeRun()
        {
            if (!m_run_size)
                return WriteResult::Written;
            if (!m_run_sizes.tryAppend(std::exchange(m_run_size, 0)))
                return WriteResult::OutOfMemory;
            return WriteResult::Written;
        }

        WTF::Vector<size_t> m_run_sizes;
        size_t m_size { 0 };
        size_t m_run_size { 0 };
    };

    // The second pass: writes the same pieces, each run of owned bytes into one buffer of the size the first pass
    // recorded for it, and each file range as segments that share the file's bytes. It never refuses a piece for size,
    // since the first pass already summed them.
    class MultipartBodyWriter {
    public:
        explicit MultipartBodyWriter(std::span<const size_t> run_sizes)
            : m_run_sizes(run_sizes)
        {
        }

        WriteResult literal(WTF::ASCIILiteral literal) { return bytes(literal.span8()); }

        WriteResult bytes(std::span<const uint8_t> bytes)
        {
            auto out = take(bytes.size());
            if (!out)
                return WriteResult::OutOfMemory;
            memcpySpan(*out, bytes);
            return WriteResult::Written;
        }

        WriteResult utf8(const String& value)
        {
            WTF::StringView view { value };
            auto out = take(utf8EncodedLength(view));
            if (!out)
                return WriteResult::OutOfMemory;
            encodeUtf8(view, *out);
            return WriteResult::Written;
        }

        // Encodes the plain UTF-8 into the end of the piece, then moves it to the front, widening each escaped byte to
        // three. Ahead of an escape the write position trails the read position by two bytes per escape not yet
        // written, this one included, so the three bytes written never reach a byte still to be read.
        WriteResult headerParameter(const String& value)
        {
            WTF::StringView view { value };
            const auto length = headerParameterLength(view);
            auto out = take(length.escaped);
            if (!out)
                return WriteResult::OutOfMemory;
            auto piece = *out;
            const size_t plain_start = length.escaped - length.utf8;
            encodeUtf8(view, piece.subspan(plain_start));
            size_t write = 0;
            for (size_t read = plain_start; read < piece.size(); read++) {
                const uint8_t byte = piece[read];
                WTF::ASCIILiteral escape;
                switch (byte) {
                case '\r':
                    escape = "%0D"_s;
                    break;
                case '\n':
                    escape = "%0A"_s;
                    break;
                case '"':
                    escape = "%22"_s;
                    break;
                default:
                    piece[write++] = byte;
                    continue;
                }
                memcpySpan(piece.subspan(write, escape.length()), escape.span8());
                write += escape.length();
            }
            ASSERT(write == piece.size());
            return WriteResult::Written;
        }

        // `size` bytes of `storage` from `offset`, shared rather than copied.
        WriteResult shared(const BlobStorage& storage, size_t offset, size_t size)
        {
            if (!size)
                return WriteResult::Written;
            if (!closeRun() || !storage.appendSegmentsTo(m_segments, offset, size))
                return WriteResult::OutOfMemory;
            return WriteResult::Written;
        }

        // The finished body of `size` bytes, the first pass's total; null when its last allocation fails.
        WTF::RefPtr<BlobStorage> finish(size_t size)
        {
            if (!closeRun())
                return nullptr;
            RELEASE_ASSERT(m_next_run == m_run_sizes.size());
            return BlobStorage::create(WTF::move(m_segments), size);
        }

    private:
        // The next `size` bytes of the open run, opening the next recorded run when none is open. Returns nullopt
        // when that run's buffer cannot be allocated.
        std::optional<std::span<uint8_t>> take(size_t size)
        {
            if (!size)
                return std::span<uint8_t> {};
            if (m_run.isEmpty()) {
                // The first pass recorded a run for every non-empty stretch of owned pieces, in this order.
                RELEASE_ASSERT(m_next_run < m_run_sizes.size());
                const size_t run_size = m_run_sizes[m_next_run++];
                if (!m_run.tryReserveInitialCapacity(run_size) || !m_run.tryGrow(run_size))
                    return std::nullopt;
                m_cursor = 0;
            }
            // Both passes see the same pieces, so a piece past the run's end means the passes disagree, and writing
            // it would overrun the buffer.
            RELEASE_ASSERT(size <= m_run.size() - m_cursor);
            auto out = m_run.mutableSpan().subspan(m_cursor, size);
            m_cursor += size;
            return out;
        }

        bool closeRun()
        {
            if (m_run.isEmpty())
                return true;
            RELEASE_ASSERT(m_cursor == m_run.size());
            const size_t size = m_run.size();
            auto bytes = BlobBytes::create(std::exchange(m_run, {}));
            return bytes && m_segments.tryAppend(BlobSegment(bytes.releaseNonNull(), 0, size));
        }

        std::span<const size_t> m_run_sizes;
        size_t m_next_run { 0 };
        WTF::Vector<uint8_t> m_run;
        size_t m_cursor { 0 };
        WTF::Vector<BlobSegment> m_segments;
    };

    // One part: its delimiter line, Content-Disposition and, for a file, Content-Type, then its value and CRLF.
    // FIXME: HTML's multipart/form-data encoding algorithm first replaces every CR not followed by LF and every LF not
    // preceded by CR with CRLF, in each name and in each string value. Names and values are written as they are. When
    // that lands, MultipartBodyMeasure must count the replaced text.
    template <typename Sink>
    WriteResult writeMultipartPart(Sink& sink, std::span<const uint8_t> boundary, const MultipartSerializedEntry& entry)
    {
        WriteResult result = WriteResult::Written;
        auto written = [&](WriteResult step) {
            result = step;
            return step == WriteResult::Written;
        };
        if (!written(sink.literal(delimiter_dashes)) || !written(sink.bytes(boundary))
            || !written(sink.literal(disposition_start)) || !written(sink.headerParameter(entry.name)))
            return result;
        if (entry.is_file) {
            if (!written(sink.literal(filename_start)) || !written(sink.headerParameter(entry.filename))
                || !written(sink.literal(content_type_start))
                || !written(
                    entry.content_type.isEmpty() ? sink.literal(default_content_type) : sink.utf8(entry.content_type))
                || !written(sink.literal(file_headers_end)))
                return result;
            if (entry.storage && !written(sink.shared(*entry.storage, entry.offset, entry.size)))
                return result;
        } else {
            if (!written(sink.literal(text_headers_end)) || !written(sink.utf8(entry.string_value)))
                return result;
        }
        written(sink.literal(part_end));
        return result;
    }

    // Every piece of the body in order: each part, then the closing delimiter. Both passes run it, so the order the
    // first pass measures is the order the second writes.
    template <typename Sink>
    WriteResult writeMultipartBody(
        Sink& sink, std::span<const uint8_t> boundary, std::span<const MultipartSerializedEntry> entries)
    {
        for (const auto& entry : entries) {
            if (auto result = writeMultipartPart(sink, boundary, entry); result != WriteResult::Written)
                return result;
        }
        if (auto result = sink.literal(delimiter_dashes); result != WriteResult::Written)
            return result;
        if (auto result = sink.bytes(boundary); result != WriteResult::Written)
            return result;
        return sink.literal(body_end);
    }

    MultipartSerializeResult serializeResult(WriteResult result)
    {
        switch (result) {
        case WriteResult::Written:
            return MultipartSerializeResult::Serialized;
        case WriteResult::Exceeded:
            return MultipartSerializeResult::Exceeded;
        case WriteResult::OutOfMemory:
            return MultipartSerializeResult::OutOfMemory;
        }
        RELEASE_ASSERT_NOT_REACHED();
    }

} // namespace

std::optional<FormBodyContentType> parseFormBodyContentType(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    const WTF::String& content_type, std::optional<WTF::ASCIILiteral>& parse_error)
{
    auto semicolon = content_type.find(';');
    auto media = trimAscii(semicolon == notFound ? content_type : content_type.substring(0, semicolon))
                     .convertToASCIILowercase();
    if (media == "application/x-www-form-urlencoded"_s)
        return FormBodyContentType { .encoding = FormBodyEncoding::UrlEncoded };
    if (media != "multipart/form-data"_s)
        return std::nullopt;

    FormBodyContentType parsed { .encoding = FormBodyEncoding::Multipart };
    bool found = false;
    bool valid = true;
    forEachHeaderParameter(content_type, [&](const String& name, const String& raw_value) {
        if (name != "boundary"_s || raw_value.isNull())
            return true;
        found = true;
        String value;
        if (!parseHeaderParameterValue(raw_value, value) || !isValidBoundary(value)) {
            valid = false;
            return false;
        }
        valid = parsed.boundary.tryReserveInitialCapacity(value.length());
        if (!valid) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        // isValidBoundary admitted only ASCII characters, which are the boundary's bytes.
        for (unsigned index = 0; index < value.length(); index++)
            parsed.boundary.append(static_cast<uint8_t>(value[index]));
        return false;
    });
    if (scope.exception())
        return std::nullopt;
    if (!found) {
        parse_error = "missing multipart boundary"_s;
        return std::nullopt;
    }
    if (!valid) {
        parse_error = "invalid multipart boundary"_s;
        return std::nullopt;
    }
    return parsed;
}

bool parseMultipartFormBody(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, std::span<const uint8_t> body,
    std::span<const uint8_t> boundary, WTF::Vector<MultipartParsedPart>& out,
    std::optional<WTF::ASCIILiteral>& parse_error)
{
    ASSERT(std::find(boundary.begin(), boundary.end(), static_cast<uint8_t>('\r')) == boundary.end());
    // The first delimiter starts the body: `--boundary`. Each later one follows the previous part's data after a CRLF,
    // which belongs to the delimiter rather than to the data.
    WTF::Vector<uint8_t> delimiter_bytes;
    if (!delimiter_bytes.tryReserveInitialCapacity(boundary.size() + 4)) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }
    delimiter_bytes.append(std::span<const uint8_t> { crlf_bytes });
    delimiter_bytes.append(static_cast<uint8_t>('-'));
    delimiter_bytes.append(static_cast<uint8_t>('-'));
    delimiter_bytes.append(boundary);
    constexpr uint8_t header_end_bytes[] = { '\r', '\n', '\r', '\n' };
    auto first_delimiter = delimiter_bytes.span().subspan(sizeof(crlf_bytes));
    ByteSearch next_delimiter { delimiter_bytes.span(), {} };
    ByteSearch header_end { std::span<const uint8_t> { header_end_bytes }, {} };
    if (!buildByteSearchTable(next_delimiter.needle, next_delimiter.table)
        || !buildByteSearchTable(header_end.needle, header_end.table)) {
        JSC::throwOutOfMemoryError(global_object, scope);
        return false;
    }

    if (!startsWithBytes(body, 0, first_delimiter)) {
        parse_error = "multipart body does not start with its boundary"_s;
        return false;
    }
    size_t cursor = first_delimiter.size();
    if (isMultipartCloseDelimiterSuffix(body, cursor))
        return true;
    auto next_cursor = multipartRegularDelimiterSuffixEnd(body, cursor);
    if (!next_cursor) {
        parse_error = "invalid multipart boundary framing"_s;
        return false;
    }
    cursor = *next_cursor;

    while (cursor < body.size()) {
        if (out.size() >= WebApiFormDataEntriesMax) {
            parse_error = FormDataEntriesExceeded;
            return false;
        }
        auto headers_end = findBytes(body, header_end, cursor);
        if (headers_end == notFound) {
            parse_error = "multipart part missing header terminator"_s;
            return false;
        }
        PartHeaders headers;
        if (!parsePartHeaders(global_object, scope, body.subspan(cursor, headers_end - cursor), headers, parse_error))
            return false;

        size_t data_start = headers_end + sizeof(header_end_bytes);
        auto boundary_position = findMultipartDelimiter(body, next_delimiter, data_start);
        if (boundary_position == notFound) {
            parse_error = "multipart body missing final boundary"_s;
            return false;
        }

        MultipartParsedPart part;
        part.name = WTF::move(headers.name);
        if (headers.has_filename) {
            part.is_file = true;
            part.filename = headers.has_filename_star ? WTF::move(headers.filename_star) : WTF::move(headers.filename);
            part.content_type = WTF::move(headers.content_type);
            part.offset = data_start;
            part.size = boundary_position - data_start;
        } else if (!decodeUtf8BytesPreservingBom(
                       global_object, scope, body.subspan(data_start, boundary_position - data_start), part.value))
            return false;
        if (!out.tryAppend(WTF::move(part))) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }

        cursor = boundary_position + next_delimiter.needle.size();
        if (isMultipartCloseDelimiterSuffix(body, cursor))
            return true;
        next_cursor = multipartRegularDelimiterSuffixEnd(body, cursor);
        if (!next_cursor) {
            parse_error = "invalid multipart boundary framing"_s;
            return false;
        }
        cursor = *next_cursor;
    }

    parse_error = "multipart body missing final boundary"_s;
    return false;
}

size_t multipartSerializableEntriesMax()
{
    return (WebApiMaterializedBodyBytesMax - closing_delimiter_length) / smallest_part_length;
}

MultipartSerializeResult serializeMultipartFormBody(
    std::span<const MultipartSerializedEntry> entries, MultipartSerializedBody& out)
{
    out = {};

    MultipartBoundary boundary;
    if (!generateMultipartBoundary(boundary))
        return MultipartSerializeResult::EntropyFailure;

    MultipartBodyMeasure measure;
    auto measured = writeMultipartBody(measure, boundary, entries);
    if (measured == WriteResult::Written)
        measured = measure.finish();
    if (measured != WriteResult::Written)
        return serializeResult(measured);

    MultipartBodyWriter writer(measure.runSizes());
    if (auto result = writeMultipartBody(writer, boundary, entries); result != WriteResult::Written)
        return serializeResult(result);
    auto storage = writer.finish(measure.size());
    if (!storage)
        return MultipartSerializeResult::OutOfMemory;

    // The boundary is ASCII (a fixed prefix and lowercase hex), so its bytes are its Latin-1 characters.
    auto content_type = WTF::tryMakeString(
        "multipart/form-data; boundary="_s, std::span<const Latin1Character> { boundary.data(), boundary.size() });
    if (content_type.isNull())
        return MultipartSerializeResult::OutOfMemory;

    out.storage = WTF::move(storage);
    out.size = measure.size();
    out.content_type = WTF::move(content_type);
    return MultipartSerializeResult::Serialized;
}

} // namespace Collo::HostFunctions
