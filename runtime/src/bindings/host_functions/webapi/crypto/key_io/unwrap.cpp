// Import of a key that unwrapKey decrypted, under the contract in key_io.h. normalizeUnwrappedKeyImportSpec reads the
// key's algorithm, extractable flag and usages when unwrapKey is called, so the job carries only native data, and the
// import runs on the VM thread when the job settles. The decrypted bytes never become JavaScript values: a JWK is
// parsed natively where the spec's "parse a JWK" step would run JSON.parse, and every buffer that holds decrypted
// bytes is zeroed before it is freed, except the gaps marked FIXME below. The JWK checks follow jwk.cpp's importKey
// path member for member, but the native parser fails some input that JSON.parse and the JsonWebKey conversion
// accept: a lone surrogate, a non-string value in any string member it knows (even one the algorithm ignores), a
// string over maxNativeJwkStringBytes, and nesting deeper than skipValue allows. A non-string key_ops element is a
// TypeError here where importKey reports a DataError, and parseExt notes where "ext" departs from ToBoolean.

#include "jsc/runtime/state.h"

#include "host_functions/webapi/crypto/key_io/key_io.h"

#include "host_functions/webapi/crypto/keys.h"
#include "host_functions/webapi/crypto/ops/symmetric.h"
#include "jsc/runtime/js_support.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/IdentifierInlines.h>
#include <JavaScriptCore/JSCInlines.h>
#include <openssl/bn.h>
#include <openssl/ec.h>
#include <openssl/ec_key.h>
#include <openssl/evp.h>
#include <openssl/nid.h>
#include <openssl/pkcs8.h>
#include <openssl/rsa.h>
#include <openssl/x509.h>
#include <wtf/text/Base64.h>
#include <wtf/text/WTFString.h>

#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <optional>

namespace Collo::HostFunctions::WebCrypto {

using JSC::JSValue;
using WTF::String;
using namespace Collo::JscSupport;

static bool isUncompressedEcPoint(std::span<const uint8_t> bytes, size_t coordinate_bytes)
{
    if (!coordinate_bytes)
        return false;
    return bytes.size() == 1 + 2 * coordinate_bytes && bytes[0] == 0x04;
}

class ClearBnGuard {
public:
    explicit ClearBnGuard(bssl::UniquePtr<BIGNUM>& value)
        : m_value(&value)
    {
    }

    ClearBnGuard(const ClearBnGuard&) = delete;
    ClearBnGuard& operator=(const ClearBnGuard&) = delete;

    ~ClearBnGuard()
    {
        if (m_value && m_value->get())
            BN_clear_free(m_value->release());
    }

private:
    bssl::UniquePtr<BIGNUM>* m_value { nullptr };
};

bool normalizeUnwrappedKeyImportSpec(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope,
    const String& format, JSValue algorithm_value, JSValue extractable_value, JSValue usages_value,
    UnwrappedKeyImportSpec& out, JSC::JSValue& out_error)
{
    String algorithm_name;
    if (!algorithmName(global_object, scope, algorithm_value, algorithm_name, out_error))
        return false;

    uint8_t usages = 0;
    if (!parseKeyUsages(global_object, scope, usages_value, usages, out_error))
        return false;

    out.extractable = extractable_value.toBoolean(global_object);
    out.usages = usages;

    if (WTF::equalIgnoringASCIICase(algorithm_name, "HMAC"_s)) {
        const HashSpec* hash = nullptr;
        std::optional<size_t> length_bits;
        if (!normalizeHmacAlgorithmAfterName(
                global_object, scope, algorithm_value, algorithm_name, hash, length_bits, out_error))
            return false;
        out.algorithm = CryptoKeyAlgorithm::Hmac;
        out.hash = hash->id;
        out.has_length_bits = length_bits.has_value();
        out.length_bits = length_bits.value_or(0);
        return true;
    }

    if (auto aes_algorithm = aesAlgorithmFromName(algorithm_name)) {
        JSC::JSObject* object = nullptr;
        if (!normalizeAesNameAfterName(
                algorithm_value, algorithm_name, *aes_algorithm, object, out_error, global_object))
            return false;
        // AES import takes a plain Algorithm dictionary, so a "length" member is ignored.
        out.algorithm = *aes_algorithm;
        return true;
    }

    if (auto rsa_algorithm = rsaAlgorithmFromName(algorithm_name)) {
        out.algorithm = *rsa_algorithm;
        if (*rsa_algorithm == CryptoKeyAlgorithm::RsaEsPkcs1V15) {
            out.hash = WebCryptoHash::SHA1;
            return true;
        }

        const HashSpec* hash = nullptr;
        if (!normalizeRsaHashedAlgorithmAfterName(
                global_object, scope, algorithm_value, algorithm_name, *rsa_algorithm, hash, out_error))
            return false;
        out.hash = hash->id;
        return true;
    }

    if (auto ec_algorithm = ecAlgorithmFromName(algorithm_name)) {
        EcKeyParams params;
        if (!parseEcKeyParamsAfterName(
                global_object, scope, algorithm_value, algorithm_name, *ec_algorithm, params, out_error))
            return false;
        out.algorithm = *ec_algorithm;
        out.curve = params.named_curve;
        return true;
    }

    if (auto okp_algorithm = okpAlgorithmFromName(algorithm_name)) {
        out.algorithm = *okp_algorithm;
        out.curve = okpCurveForAlgorithm(*okp_algorithm);
        return true;
    }

    if (WTF::equalIgnoringASCIICase(algorithm_name, "PBKDF2"_s)) {
        out.algorithm = CryptoKeyAlgorithm::Pbkdf2;
        return true;
    }

    if (WTF::equalIgnoringASCIICase(algorithm_name, "HKDF"_s)) {
        out.algorithm = CryptoKeyAlgorithm::Hkdf;
        return true;
    }

    out_error = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError);
    return false;
}

// Bounds on the decrypted JWK text and on each string the parser copies out, a member name or a value it reads, which
// keep the parse small on the VM thread. Strings inside skipped values have only the text bound. A private RSA key at
// maxWebCryptoRsaModulusLengthBits fits well within both. An HMAC key over 12 KiB, whose "k" exceeds the string bound,
// fails here although importKey accepts it.
static constexpr size_t maxNativeUnwrappedJwkBytes = 64 * 1024;
static constexpr size_t maxNativeJwkStringBytes = 16 * 1024;

enum class NativeJwkParseError : uint8_t {
    Json,
    Type,
    OutOfMemory,
};

static bool equalAscii(std::span<const uint8_t> bytes, WTF::ASCIILiteral text)
{
    auto text_span = text.span8();
    return bytes.size() == text_span.size()
        && (!bytes.size() || !std::memcmp(bytes.data(), text_span.data(), bytes.size()));
}

struct NativeJwkString {
    ~NativeJwkString() { secureZeroVector(bytes); }

    bool equals(WTF::ASCIILiteral text) const { return present && equalAscii(bytes.span(), text); }

    bool isEmpty() const { return bytes.isEmpty(); }

    WTF::Vector<uint8_t> bytes;
    bool present { false };
};

struct NativeJwk {
    NativeJwkString kty;
    NativeJwkString k;
    NativeJwkString alg;
    NativeJwkString use;
    NativeJwkString n;
    NativeJwkString e;
    NativeJwkString d;
    NativeJwkString p;
    NativeJwkString q;
    NativeJwkString dp;
    NativeJwkString dq;
    NativeJwkString qi;
    NativeJwkString crv;
    NativeJwkString x;
    NativeJwkString y;
    bool has_ext { false };
    bool ext { false };
    bool has_key_ops { false };
    uint8_t key_ops { 0 };
};

static uint8_t usageBitFromAscii(std::span<const uint8_t> usage)
{
    if (equalAscii(usage, "encrypt"_s))
        return CryptoKeyUsageEncrypt;
    if (equalAscii(usage, "decrypt"_s))
        return CryptoKeyUsageDecrypt;
    if (equalAscii(usage, "sign"_s))
        return CryptoKeyUsageSign;
    if (equalAscii(usage, "verify"_s))
        return CryptoKeyUsageVerify;
    if (equalAscii(usage, "deriveBits"_s))
        return CryptoKeyUsageDeriveBits;
    if (equalAscii(usage, "deriveKey"_s))
        return CryptoKeyUsageDeriveKey;
    if (equalAscii(usage, "wrapKey"_s))
        return CryptoKeyUsageWrapKey;
    if (equalAscii(usage, "unwrapKey"_s))
        return CryptoKeyUsageUnwrapKey;
    return 0;
}

class NativeJwkParser {
public:
    explicit NativeJwkParser(std::span<const uint8_t> input)
        : m_input(input)
    {
    }

    bool parse(NativeJwk& out, NativeJwkParseError& error)
    {
        skipWhitespace();
        if (!consume('{')) {
            error = NativeJwkParseError::Json;
            return false;
        }

        skipWhitespace();
        if (consume('}')) {
            skipWhitespace();
            if (m_offset == m_input.size())
                return true;
            error = NativeJwkParseError::Json;
            return false;
        }

        for (;;) {
            WTF::Vector<uint8_t> name;
            SecureVectorGuard name_guard(name);
            if (!parseString(&name, error))
                return false;
            skipWhitespace();
            if (!consume(':')) {
                error = NativeJwkParseError::Json;
                return false;
            }
            if (!parseKnownField(name.span(), out, error))
                return false;

            skipWhitespace();
            if (consume('}'))
                break;
            if (!consume(',')) {
                error = NativeJwkParseError::Json;
                return false;
            }
            skipWhitespace();
        }

        skipWhitespace();
        if (m_offset != m_input.size()) {
            error = NativeJwkParseError::Json;
            return false;
        }
        return true;
    }

private:
    void skipWhitespace()
    {
        while (m_offset < m_input.size()) {
            switch (m_input[m_offset]) {
            case ' ':
            case '\n':
            case '\r':
            case '\t':
                ++m_offset;
                continue;
            default:
                return;
            }
        }
    }

    bool consume(uint8_t byte)
    {
        skipWhitespace();
        if (m_offset >= m_input.size() || m_input[m_offset] != byte)
            return false;
        ++m_offset;
        return true;
    }

    bool consumeLiteral(const char* literal)
    {
        skipWhitespace();
        auto length = std::strlen(literal);
        if (m_offset + length > m_input.size())
            return false;
        if (std::memcmp(m_input.data() + m_offset, literal, length))
            return false;
        m_offset += length;
        return true;
    }

    static std::optional<uint8_t> hexValue(uint8_t byte)
    {
        if (byte >= '0' && byte <= '9')
            return byte - '0';
        if (byte >= 'a' && byte <= 'f')
            return byte - 'a' + 10;
        if (byte >= 'A' && byte <= 'F')
            return byte - 'A' + 10;
        return std::nullopt;
    }

    // FIXME: each tryAppend that grows *out frees the previous buffer without zeroing it, and that buffer holds a
    // prefix of a decrypted member such as "d" or "k".
    bool appendByte(WTF::Vector<uint8_t>* out, uint8_t byte, NativeJwkParseError& error)
    {
        if (!out)
            return true;
        if (out->size() >= maxNativeJwkStringBytes) {
            error = NativeJwkParseError::Json;
            return false;
        }
        if (!out->tryAppend(std::span<const uint8_t> { &byte, 1 })) {
            error = NativeJwkParseError::OutOfMemory;
            return false;
        }
        return true;
    }

    // Reads the four hex digits of a \u escape at the current offset as one UTF-16 code unit.
    bool readHex4(unsigned& out_codeunit, NativeJwkParseError& error)
    {
        if (m_offset + 4 > m_input.size()) {
            error = NativeJwkParseError::Json;
            return false;
        }
        unsigned codeunit = 0;
        for (unsigned index = 0; index < 4; ++index) {
            auto value = hexValue(m_input[m_offset++]);
            if (!value) {
                error = NativeJwkParseError::Json;
                return false;
            }
            codeunit = (codeunit << 4) | *value;
        }
        out_codeunit = codeunit;
        return true;
    }

    // Appends a Unicode scalar value as UTF-8, so a string holds the text JSON.parse would produce, encoded as UTF-8
    // like the unescaped bytes around it.
    bool appendCodepointUtf8(WTF::Vector<uint8_t>* out, unsigned codepoint, NativeJwkParseError& error)
    {
        if (codepoint <= 0x7f)
            return appendByte(out, static_cast<uint8_t>(codepoint), error);
        if (codepoint <= 0x7ff) {
            return appendByte(out, static_cast<uint8_t>(0xc0 | (codepoint >> 6)), error)
                && appendByte(out, static_cast<uint8_t>(0x80 | (codepoint & 0x3f)), error);
        }
        if (codepoint <= 0xffff) {
            return appendByte(out, static_cast<uint8_t>(0xe0 | (codepoint >> 12)), error)
                && appendByte(out, static_cast<uint8_t>(0x80 | ((codepoint >> 6) & 0x3f)), error)
                && appendByte(out, static_cast<uint8_t>(0x80 | (codepoint & 0x3f)), error);
        }
        return appendByte(out, static_cast<uint8_t>(0xf0 | (codepoint >> 18)), error)
            && appendByte(out, static_cast<uint8_t>(0x80 | ((codepoint >> 12) & 0x3f)), error)
            && appendByte(out, static_cast<uint8_t>(0x80 | ((codepoint >> 6) & 0x3f)), error)
            && appendByte(out, static_cast<uint8_t>(0x80 | (codepoint & 0x3f)), error);
    }

    bool parseString(WTF::Vector<uint8_t>* out, NativeJwkParseError& error)
    {
        skipWhitespace();
        if (m_offset >= m_input.size() || m_input[m_offset++] != '"') {
            error = NativeJwkParseError::Json;
            return false;
        }

        while (m_offset < m_input.size()) {
            uint8_t byte = m_input[m_offset++];
            if (byte == '"')
                return true;
            if (byte < 0x20) {
                error = NativeJwkParseError::Json;
                return false;
            }
            if (byte != '\\') {
                if (!appendByte(out, byte, error))
                    return false;
                continue;
            }

            if (m_offset >= m_input.size()) {
                error = NativeJwkParseError::Json;
                return false;
            }
            uint8_t escaped = m_input[m_offset++];
            switch (escaped) {
            case '"':
            case '\\':
            case '/':
                if (!appendByte(out, escaped, error))
                    return false;
                break;
            case 'b':
                if (!appendByte(out, '\b', error))
                    return false;
                break;
            case 'f':
                if (!appendByte(out, '\f', error))
                    return false;
                break;
            case 'n':
                if (!appendByte(out, '\n', error))
                    return false;
                break;
            case 'r':
                if (!appendByte(out, '\r', error))
                    return false;
                break;
            case 't':
                if (!appendByte(out, '\t', error))
                    return false;
                break;
            case 'u': {
                unsigned codeunit = 0;
                if (!readHex4(codeunit, error))
                    return false;
                unsigned codepoint = codeunit;
                if (codeunit >= 0xd800 && codeunit <= 0xdbff) {
                    // A high surrogate must be followed by an escaped low surrogate, and the pair becomes one
                    // supplementary-plane scalar value. A lone surrogate of either kind fails the parse, although
                    // JSON.parse would keep it in the string.
                    if (m_offset + 2 > m_input.size() || m_input[m_offset] != '\\' || m_input[m_offset + 1] != 'u') {
                        error = NativeJwkParseError::Json;
                        return false;
                    }
                    m_offset += 2;
                    unsigned low = 0;
                    if (!readHex4(low, error))
                        return false;
                    if (low < 0xdc00 || low > 0xdfff) {
                        error = NativeJwkParseError::Json;
                        return false;
                    }
                    codepoint = 0x10000 + ((codeunit - 0xd800) << 10) + (low - 0xdc00);
                } else if (codeunit >= 0xdc00 && codeunit <= 0xdfff) {
                    error = NativeJwkParseError::Json;
                    return false;
                }
                if (!appendCodepointUtf8(out, codepoint, error))
                    return false;
                break;
            }
            default:
                error = NativeJwkParseError::Json;
                return false;
            }
        }

        error = NativeJwkParseError::Json;
        return false;
    }

    // A repeated member replaces the earlier one, as in JSON.parse, which keeps the last.
    bool parseStringField(NativeJwkString& field, NativeJwkParseError& error)
    {
        secureZeroVector(field.bytes);
        field.bytes.clear();
        field.present = true;
        return parseString(&field.bytes, error);
    }

    bool parseKeyOps(NativeJwk& out, NativeJwkParseError& error)
    {
        skipWhitespace();
        if (m_offset >= m_input.size() || m_input[m_offset] != '[') {
            error = NativeJwkParseError::Type;
            return false;
        }
        ++m_offset;

        uint8_t usages = 0;
        skipWhitespace();
        if (consume(']')) {
            out.has_key_ops = true;
            out.key_ops = 0;
            return true;
        }

        for (;;) {
            WTF::Vector<uint8_t> usage;
            SecureVectorGuard usage_guard(usage);
            if (!parseString(&usage, error)) {
                if (error == NativeJwkParseError::Json)
                    error = NativeJwkParseError::Type;
                return false;
            }
            auto bit = usageBitFromAscii(usage.span());
            if (!bit) {
                // An unknown key_ops value makes the JWK invalid, a DataError, as parseJwkKeyOps reports it for
                // importKey.
                error = NativeJwkParseError::Json;
                return false;
            }
            usages |= bit;

            skipWhitespace();
            if (consume(']'))
                break;
            if (!consume(',')) {
                error = NativeJwkParseError::Json;
                return false;
            }
        }

        out.has_key_ops = true;
        out.key_ops = usages;
        return true;
    }

    bool parseNumberIsZero(bool& out_is_zero, NativeJwkParseError& error)
    {
        skipWhitespace();
        size_t start = m_offset;
        if (m_offset < m_input.size() && m_input[m_offset] == '-')
            ++m_offset;
        if (m_offset >= m_input.size()) {
            error = NativeJwkParseError::Json;
            return false;
        }

        if (m_input[m_offset] == '0')
            ++m_offset;
        else if (m_input[m_offset] >= '1' && m_input[m_offset] <= '9') {
            do {
                ++m_offset;
            } while (m_offset < m_input.size() && m_input[m_offset] >= '0' && m_input[m_offset] <= '9');
        } else {
            error = NativeJwkParseError::Json;
            return false;
        }

        if (m_offset < m_input.size() && m_input[m_offset] == '.') {
            ++m_offset;
            if (m_offset >= m_input.size() || m_input[m_offset] < '0' || m_input[m_offset] > '9') {
                error = NativeJwkParseError::Json;
                return false;
            }
            do {
                ++m_offset;
            } while (m_offset < m_input.size() && m_input[m_offset] >= '0' && m_input[m_offset] <= '9');
        }

        if (m_offset < m_input.size() && (m_input[m_offset] == 'e' || m_input[m_offset] == 'E')) {
            ++m_offset;
            if (m_offset < m_input.size() && (m_input[m_offset] == '+' || m_input[m_offset] == '-'))
                ++m_offset;
            if (m_offset >= m_input.size() || m_input[m_offset] < '0' || m_input[m_offset] > '9') {
                error = NativeJwkParseError::Json;
                return false;
            }
            do {
                ++m_offset;
            } while (m_offset < m_input.size() && m_input[m_offset] >= '0' && m_input[m_offset] <= '9');
        }

        out_is_zero = true;
        for (size_t index = start; index < m_offset; ++index) {
            uint8_t byte = m_input[index];
            if (byte >= '1' && byte <= '9') {
                out_is_zero = false;
                break;
            }
        }
        return true;
    }

    // Skips a value the import does not read. Nesting deeper than 16 levels fails the parse, which bounds the
    // recursion.
    bool skipValue(NativeJwkParseError& error, unsigned depth = 0)
    {
        if (depth > 16) {
            error = NativeJwkParseError::Json;
            return false;
        }
        skipWhitespace();
        if (m_offset >= m_input.size()) {
            error = NativeJwkParseError::Json;
            return false;
        }

        uint8_t byte = m_input[m_offset];
        if (byte == '"')
            return parseString(nullptr, error);
        if (byte == '{') {
            ++m_offset;
            skipWhitespace();
            if (consume('}'))
                return true;
            for (;;) {
                if (!parseString(nullptr, error))
                    return false;
                if (!consume(':')) {
                    error = NativeJwkParseError::Json;
                    return false;
                }
                if (!skipValue(error, depth + 1))
                    return false;
                skipWhitespace();
                if (consume('}'))
                    return true;
                if (!consume(',')) {
                    error = NativeJwkParseError::Json;
                    return false;
                }
            }
        }
        if (byte == '[') {
            ++m_offset;
            skipWhitespace();
            if (consume(']'))
                return true;
            for (;;) {
                if (!skipValue(error, depth + 1))
                    return false;
                skipWhitespace();
                if (consume(']'))
                    return true;
                if (!consume(',')) {
                    error = NativeJwkParseError::Json;
                    return false;
                }
            }
        }
        if (consumeLiteral("true") || consumeLiteral("false") || consumeLiteral("null"))
            return true;
        bool unused = false;
        return parseNumberIsZero(unused, error);
    }

    // "ext" reads false for false, null, "" and a number literal with no digit from 1 to 9, and true for anything
    // else, which approximates the ToBoolean importKey applies to the member.
    // FIXME: ToBoolean is also false for a zero with a nonzero exponent (0e5) and for a literal that underflows to zero
    // (1e-400). The digit test reads both as true, so with extractable set they pass here where importKey rejects them
    // with a DataError.
    bool parseExt(NativeJwk& out, NativeJwkParseError& error)
    {
        out.has_ext = true;
        skipWhitespace();
        if (consumeLiteral("false") || consumeLiteral("null")) {
            out.ext = false;
            return true;
        }
        if (consumeLiteral("true")) {
            out.ext = true;
            return true;
        }
        if (m_offset < m_input.size() && m_input[m_offset] == '"') {
            WTF::Vector<uint8_t> value;
            SecureVectorGuard value_guard(value);
            if (!parseString(&value, error))
                return false;
            out.ext = !value.isEmpty();
            return true;
        }
        if (m_offset < m_input.size()
            && (m_input[m_offset] == '-' || (m_input[m_offset] >= '0' && m_input[m_offset] <= '9'))) {
            bool is_zero = false;
            if (!parseNumberIsZero(is_zero, error))
                return false;
            out.ext = !is_zero;
            return true;
        }
        if (!skipValue(error))
            return false;
        out.ext = true;
        return true;
    }

    bool parseKnownField(std::span<const uint8_t> name, NativeJwk& out, NativeJwkParseError& error)
    {
        if (equalAscii(name, "kty"_s))
            return parseStringField(out.kty, error);
        if (equalAscii(name, "k"_s))
            return parseStringField(out.k, error);
        if (equalAscii(name, "alg"_s))
            return parseStringField(out.alg, error);
        if (equalAscii(name, "use"_s))
            return parseStringField(out.use, error);
        if (equalAscii(name, "key_ops"_s))
            return parseKeyOps(out, error);
        if (equalAscii(name, "n"_s))
            return parseStringField(out.n, error);
        if (equalAscii(name, "e"_s))
            return parseStringField(out.e, error);
        if (equalAscii(name, "d"_s))
            return parseStringField(out.d, error);
        if (equalAscii(name, "p"_s))
            return parseStringField(out.p, error);
        if (equalAscii(name, "q"_s))
            return parseStringField(out.q, error);
        if (equalAscii(name, "dp"_s))
            return parseStringField(out.dp, error);
        if (equalAscii(name, "dq"_s))
            return parseStringField(out.dq, error);
        if (equalAscii(name, "qi"_s))
            return parseStringField(out.qi, error);
        if (equalAscii(name, "crv"_s))
            return parseStringField(out.crv, error);
        if (equalAscii(name, "x"_s))
            return parseStringField(out.x, error);
        if (equalAscii(name, "y"_s))
            return parseStringField(out.y, error);
        if (equalAscii(name, "ext"_s))
            return parseExt(out, error);
        return skipValue(error);
    }

    std::span<const uint8_t> m_input;
    size_t m_offset { 0 };
};

static void setNativeJwkParseError(
    JSC::JSGlobalObject* global_object, NativeJwkParseError error, JSC::JSValue& out_error)
{
    if (error == NativeJwkParseError::OutOfMemory) {
        out_error = JSC::createOutOfMemoryError(global_object);
        return;
    }
    if (error == NativeJwkParseError::Type) {
        out_error = typeErrorValue(global_object, "value must be enumeration (string)"_s);
        return;
    }
    out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
}

static bool decodeNativeBase64Url(JSC::JSGlobalObject* global_object, const NativeJwkString& field,
    WTF::Vector<uint8_t>& out, JSC::JSValue& out_error)
{
    if (!field.present || field.bytes.size() > maxNativeJwkStringBytes) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    // jwk.cpp decodes with the same WTF::base64URLDecode and the same options, so both front ends accept the same
    // alphabet and padding and both reject whitespace.
    auto decoded = WTF::base64URLDecode(field.bytes.span());
    if (!decoded) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    // The decoded bytes can be private key material, so they are copied into the caller's guarded output and zeroed
    // here before the buffer is freed.
    // FIXME: base64URLDecode decodes into a buffer as long as its input and shrinks it to the decoded length, so the
    // capacity past size() still holds the last quarter of the decoded sextets, which secureZeroVector does not reach.
    bool ok = out.tryAppend(decoded->span());
    secureZeroVector(*decoded);
    if (!ok) {
        out_error = JSC::createOutOfMemoryError(global_object);
        return false;
    }
    return true;
}

static bool getNativeJwkBytes(JSC::JSGlobalObject* global_object, const NativeJwkString& field,
    WTF::Vector<uint8_t>& out, JSC::JSValue& out_error)
{
    if (!decodeNativeBase64Url(global_object, field, out, out_error))
        return false;
    if (out.isEmpty()) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    return true;
}

static bool getNativeRsaInteger(JSC::JSGlobalObject* global_object, const NativeJwkString& field,
    WTF::Vector<uint8_t>& out, bool trim_leading_zero, JSC::JSValue& out_error)
{
    if (!getNativeJwkBytes(global_object, field, out, out_error))
        return false;
    if (trim_leading_zero && out.size() > 1 && out[0] == 0)
        out.removeAt(0);
    return true;
}

static bool validateNativeJwkExt(
    JSC::JSGlobalObject* global_object, const NativeJwk& jwk, bool extractable, JSC::JSValue& out_error)
{
    if (jwk.has_ext && !jwk.ext && extractable) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    return true;
}

static bool validateNativeJwkKeyOps(
    JSC::JSGlobalObject* global_object, const NativeJwk& jwk, uint8_t usages, JSC::JSValue& out_error)
{
    if (jwk.has_key_ops && (jwk.key_ops & usages) != usages) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    return true;
}

static bool validateNativeJwkUse(JSC::JSGlobalObject* global_object, const NativeJwk& jwk, uint8_t usages,
    WTF::ASCIILiteral expected, JSC::JSValue& out_error)
{
    if (usages && jwk.use.present && !jwk.use.isEmpty() && !jwk.use.equals(expected)) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    return true;
}

static bool validateNativeJwkAlg(
    JSC::JSGlobalObject* global_object, const NativeJwk& jwk, WTF::ASCIILiteral expected, JSC::JSValue& out_error)
{
    if (jwk.alg.present && !jwk.alg.isEmpty() && !jwk.alg.equals(expected)) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    return true;
}

static bool importNativeHmacJwkWithSpec(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope,
    const NativeJwk& jwk, const UnwrappedKeyImportSpec& spec, JSColloCryptoKey*& out_key, JSC::JSValue& out_error)
{
    if (!validateRequestedUsages(spec.usages, CryptoKeyUsageSign | CryptoKeyUsageVerify, out_error, global_object)
        || !validateRequiredUsages(spec.usages, out_error, global_object))
        return false;
    if (!jwk.kty.equals("oct"_s) || !jwk.k.present) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    if (!validateNativeJwkAlg(global_object, jwk, hashSpec(spec.hash).jwk_alg, out_error)
        || !validateNativeJwkUse(global_object, jwk, spec.usages, "sig"_s, out_error)
        || !validateNativeJwkExt(global_object, jwk, spec.extractable, out_error)
        || !validateNativeJwkKeyOps(global_object, jwk, spec.usages, out_error))
        return false;

    WTF::Vector<uint8_t> material;
    SecureVectorGuard material_guard(material);
    if (!getNativeJwkBytes(global_object, jwk.k, material, out_error))
        return false;
    // Web Crypto HMAC import requires a declared length to satisfy data_bits - 8 < length <= data_bits.
    if (spec.has_length_bits
        && (spec.length_bits > material.size() * 8 || spec.length_bits + 8 <= material.size() * 8)) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    out_key = createHmacKey(global_object, spec.hash, WTF::move(material), spec.extractable, spec.usages,
        spec.has_length_bits ? spec.length_bits : 0);
    if (out_key)
        material_guard.dismiss();
    return !takePendingException(scope, out_error);
}

static bool importNativeAesJwkWithSpec(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope,
    const NativeJwk& jwk, const UnwrappedKeyImportSpec& spec, JSColloCryptoKey*& out_key, JSC::JSValue& out_error)
{
    if (!validateRequestedUsages(spec.usages, allowedUsagesForAes(spec.algorithm), out_error, global_object)
        || !validateRequiredUsages(spec.usages, out_error, global_object))
        return false;
    if (!jwk.kty.equals("oct"_s) || !jwk.k.present) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    WTF::Vector<uint8_t> material;
    SecureVectorGuard material_guard(material);
    if (!getNativeJwkBytes(global_object, jwk.k, material, out_error))
        return false;
    if (!isValidAesKeyLength(material.size())) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    if (!validateNativeJwkAlg(global_object, jwk, aesJwkAlgorithm(spec.algorithm, material.size()), out_error)
        || !validateNativeJwkUse(global_object, jwk, spec.usages, "enc"_s, out_error)
        || !validateNativeJwkExt(global_object, jwk, spec.extractable, out_error)
        || !validateNativeJwkKeyOps(global_object, jwk, spec.usages, out_error))
        return false;

    out_key = createAesKey(global_object, spec.algorithm, WTF::move(material), spec.extractable, spec.usages);
    if (out_key)
        material_guard.dismiss();
    return !takePendingException(scope, out_error);
}

static bool importNativeRsaJwkWithSpec(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope,
    const NativeJwk& jwk, const UnwrappedKeyImportSpec& spec, JSColloCryptoKey*& out_key, JSC::JSValue& out_error)
{
    auto type = jwk.d.present ? CryptoKeyType::Private : CryptoKeyType::Public;
    if (!validateRequestedUsages(spec.usages,
            type == CryptoKeyType::Private ? allowedPrivateUsagesForRsa(spec.algorithm)
                                           : allowedPublicUsagesForRsa(spec.algorithm),
            out_error, global_object))
        return false;
    if (type == CryptoKeyType::Private && !validateRequiredUsages(spec.usages, out_error, global_object))
        return false;
    const bool expects_encryption_use
        = spec.algorithm == CryptoKeyAlgorithm::RsaOaep || spec.algorithm == CryptoKeyAlgorithm::RsaEsPkcs1V15;
    if (!jwk.kty.equals("RSA"_s)
        || !validateNativeJwkAlg(global_object, jwk, rsaJwkAlgorithm(spec.algorithm, spec.hash), out_error)
        || !validateNativeJwkUse(global_object, jwk, spec.usages, expects_encryption_use ? "enc"_s : "sig"_s, out_error)
        || !validateNativeJwkExt(global_object, jwk, spec.extractable, out_error)
        || !validateNativeJwkKeyOps(global_object, jwk, spec.usages, out_error)) {
        if (!out_error)
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    WTF::Vector<uint8_t> n;
    WTF::Vector<uint8_t> e;
    if (!getNativeRsaInteger(global_object, jwk.n, n, true, out_error)
        || !getNativeRsaInteger(global_object, jwk.e, e, false, out_error))
        return false;
    if (n.size() > (maxWebCryptoRsaModulusLengthBits + 7) / 8) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    auto bn_n = bytesToBn(n.span());
    auto bn_e = bytesToBn(e.span());
    if (!bn_n || !bn_e) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    bssl::UniquePtr<RSA> rsa;
    if (type == CryptoKeyType::Public)
        rsa.reset(RSA_new_public_key_large_e(bn_n.get(), bn_e.get()));
    else {
        WTF::Vector<uint8_t> d;
        WTF::Vector<uint8_t> p;
        WTF::Vector<uint8_t> q;
        WTF::Vector<uint8_t> dp;
        WTF::Vector<uint8_t> dq;
        WTF::Vector<uint8_t> qi;
        SecureVectorGuard d_guard(d);
        SecureVectorGuard p_guard(p);
        SecureVectorGuard q_guard(q);
        SecureVectorGuard dp_guard(dp);
        SecureVectorGuard dq_guard(dq);
        SecureVectorGuard qi_guard(qi);
        if (!getNativeRsaInteger(global_object, jwk.d, d, false, out_error)
            || !getNativeRsaInteger(global_object, jwk.p, p, false, out_error)
            || !getNativeRsaInteger(global_object, jwk.q, q, false, out_error)
            || !getNativeRsaInteger(global_object, jwk.dp, dp, false, out_error)
            || !getNativeRsaInteger(global_object, jwk.dq, dq, false, out_error)
            || !getNativeRsaInteger(global_object, jwk.qi, qi, false, out_error))
            return false;
        auto bn_d = bytesToBn(d.span());
        auto bn_p = bytesToBn(p.span());
        auto bn_q = bytesToBn(q.span());
        auto bn_dp = bytesToBn(dp.span());
        auto bn_dq = bytesToBn(dq.span());
        auto bn_qi = bytesToBn(qi.span());
        ClearBnGuard bn_d_guard(bn_d);
        ClearBnGuard bn_p_guard(bn_p);
        ClearBnGuard bn_q_guard(bn_q);
        ClearBnGuard bn_dp_guard(bn_dp);
        ClearBnGuard bn_dq_guard(bn_dq);
        ClearBnGuard bn_qi_guard(bn_qi);
        if (!bn_d || !bn_p || !bn_q || !bn_dp || !bn_dq || !bn_qi) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
        rsa.reset(RSA_new_private_key_large_e(
            bn_n.get(), bn_e.get(), bn_d.get(), bn_p.get(), bn_q.get(), bn_dp.get(), bn_dq.get(), bn_qi.get()));
    }

    if (!rsa) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    auto pkey = pkeyFromRsa(rsa.get());
    if (!pkey) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    out_key
        = createRsaKey(global_object, spec.algorithm, spec.hash, type, WTF::move(pkey), spec.extractable, spec.usages);
    if (!out_key) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    return !takePendingException(scope, out_error);
}

static bool importNativeEcJwkWithSpec(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope,
    const NativeJwk& jwk, const UnwrappedKeyImportSpec& spec, JSColloCryptoKey*& out_key, JSC::JSValue& out_error)
{
    auto type = jwk.d.present ? CryptoKeyType::Private : CryptoKeyType::Public;
    if (!validateRequestedUsages(spec.usages,
            type == CryptoKeyType::Private ? allowedPrivateUsagesForEc(spec.algorithm)
                                           : allowedPublicUsagesForEc(spec.algorithm),
            out_error, global_object))
        return false;
    if (type == CryptoKeyType::Private && !validateRequiredUsages(spec.usages, out_error, global_object))
        return false;
    if (!jwk.kty.equals("EC"_s) || !jwk.crv.equals(namedCurveName(spec.curve))
        || !validateNativeJwkUse(
            global_object, jwk, spec.usages, spec.algorithm == CryptoKeyAlgorithm::Ecdh ? "enc"_s : "sig"_s, out_error)
        || !validateNativeJwkExt(global_object, jwk, spec.extractable, out_error)
        || !validateNativeJwkKeyOps(global_object, jwk, spec.usages, out_error)) {
        if (!out_error)
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    auto coordinate_bytes = coordinateBytesForNamedCurve(spec.curve);
    WTF::Vector<uint8_t> x;
    WTF::Vector<uint8_t> y;
    if (!getNativeJwkBytes(global_object, jwk.x, x, out_error)
        || !getNativeJwkBytes(global_object, jwk.y, y, out_error))
        return false;
    if (x.size() != coordinate_bytes || y.size() != coordinate_bytes) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    auto bn_x = bytesToBn(x.span());
    auto bn_y = bytesToBn(y.span());
    bssl::UniquePtr<EC_KEY> ec(EC_KEY_new_by_curve_name(nidForNamedCurve(spec.curve)));
    if (!bn_x || !bn_y || !ec || EC_KEY_set_public_key_affine_coordinates(ec.get(), bn_x.get(), bn_y.get()) != 1) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    if (type == CryptoKeyType::Private) {
        WTF::Vector<uint8_t> d;
        SecureVectorGuard d_guard(d);
        if (!getNativeJwkBytes(global_object, jwk.d, d, out_error))
            return false;
        if (d.size() != coordinate_bytes) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
        auto bn_d = bytesToBn(d.span());
        ClearBnGuard bn_d_guard(bn_d);
        if (!bn_d || EC_KEY_set_private_key(ec.get(), bn_d.get()) != 1) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
    }
    if (EC_KEY_check_key(ec.get()) != 1) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    auto pkey = pkeyFromEc(ec.get());
    if (!pkey) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    out_key
        = createEcKey(global_object, spec.algorithm, type, spec.curve, WTF::move(pkey), spec.extractable, spec.usages);
    if (!out_key) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    return !takePendingException(scope, out_error);
}

static bool importNativeOkpJwkWithSpec(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope,
    const NativeJwk& jwk, const UnwrappedKeyImportSpec& spec, JSColloCryptoKey*& out_key, JSC::JSValue& out_error)
{
    auto type = jwk.d.present ? CryptoKeyType::Private : CryptoKeyType::Public;
    if (!validateRequestedUsages(spec.usages,
            type == CryptoKeyType::Private ? allowedPrivateUsagesForOkp(spec.algorithm)
                                           : allowedPublicUsagesForOkp(spec.algorithm),
            out_error, global_object))
        return false;
    if (type == CryptoKeyType::Private && !validateRequiredUsages(spec.usages, out_error, global_object))
        return false;
    if (!jwk.kty.equals("OKP"_s) || !jwk.crv.equals(namedCurveName(okpCurveForAlgorithm(spec.algorithm)))
        || !validateNativeJwkUse(global_object, jwk, spec.usages,
            spec.algorithm == CryptoKeyAlgorithm::X25519 ? "enc"_s : "sig"_s, out_error)
        || !validateNativeJwkExt(global_object, jwk, spec.extractable, out_error)
        || !validateNativeJwkKeyOps(global_object, jwk, spec.usages, out_error)) {
        if (!out_error)
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    if (spec.algorithm == CryptoKeyAlgorithm::Ed25519 && jwk.alg.present && !jwk.alg.isEmpty()
        && !jwk.alg.equals("Ed25519"_s) && !jwk.alg.equals("EdDSA"_s)) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    WTF::Vector<uint8_t> material;
    SecureVectorGuard material_guard(material);
    WTF::Vector<uint8_t> declared_public;
    if (!getNativeJwkBytes(global_object, type == CryptoKeyType::Private ? jwk.d : jwk.x, material, out_error))
        return false;
    if (material.size() != 32) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    if (type == CryptoKeyType::Private) {
        // RFC 8037 requires "x" in a private OKP JWK too, and the import rejects one that differs from the public
        // key derived from "d".
        if (!getNativeJwkBytes(global_object, jwk.x, declared_public, out_error))
            return false;
        if (declared_public.size() != 32) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
    }
    bssl::UniquePtr<EVP_PKEY> pkey(type == CryptoKeyType::Private
            ? EVP_PKEY_new_raw_private_key(
                  evpTypeForOkp(spec.algorithm), nullptr, material.span().data(), material.size())
            : EVP_PKEY_new_raw_public_key(
                  evpTypeForOkp(spec.algorithm), nullptr, material.span().data(), material.size()));
    if (!pkey) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    if (type == CryptoKeyType::Private) {
        WTF::Vector<uint8_t> derived_public;
        if (!evpGetRawPublic(pkey.get(), derived_public) || derived_public.size() != declared_public.size()
            || std::memcmp(derived_public.span().data(), declared_public.span().data(), declared_public.size())) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
    }
    out_key = createOkpKey(global_object, spec.algorithm, type, WTF::move(pkey), spec.extractable, spec.usages);
    if (!out_key) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }
    return !takePendingException(scope, out_error);
}

static bool importUnwrappedJwkWithSpec(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope,
    std::span<const uint8_t> bytes, const UnwrappedKeyImportSpec& spec, JSColloCryptoKey*& out_key,
    JSC::JSValue& out_error)
{
    if (bytes.size() > maxNativeUnwrappedJwkBytes) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
        return false;
    }

    NativeJwk jwk;
    NativeJwkParseError parse_error { NativeJwkParseError::Json };
    NativeJwkParser parser(bytes);
    if (!parser.parse(jwk, parse_error)) {
        setNativeJwkParseError(global_object, parse_error, out_error);
        return false;
    }

    if (!jwk.kty.present) {
        out_error = typeErrorValue(global_object, "JsonWebKey.kty is required"_s);
        return false;
    }

    if (spec.algorithm == CryptoKeyAlgorithm::Hmac)
        return importNativeHmacJwkWithSpec(global_object, scope, jwk, spec, out_key, out_error);
    if (isAesAlgorithm(spec.algorithm))
        return importNativeAesJwkWithSpec(global_object, scope, jwk, spec, out_key, out_error);
    if (isRsaAlgorithm(spec.algorithm))
        return importNativeRsaJwkWithSpec(global_object, scope, jwk, spec, out_key, out_error);
    if (isEcAlgorithm(spec.algorithm))
        return importNativeEcJwkWithSpec(global_object, scope, jwk, spec, out_key, out_error);
    if (isOkpAlgorithm(spec.algorithm))
        return importNativeOkpJwkWithSpec(global_object, scope, jwk, spec, out_key, out_error);

    out_error = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError);
    return false;
}

static bool importUnwrappedRawWithSpec(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope,
    WTF::Vector<uint8_t>&& material, const UnwrappedKeyImportSpec& spec, JSColloCryptoKey*& out_key,
    JSC::JSValue& out_error)
{
    SecureVectorGuard material_guard(material);

    if (spec.algorithm == CryptoKeyAlgorithm::Hmac) {
        if (!validateRequestedUsages(spec.usages, CryptoKeyUsageSign | CryptoKeyUsageVerify, out_error, global_object)
            || !validateRequiredUsages(spec.usages, out_error, global_object))
            return false;
        if (material.isEmpty()) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
        // Web Crypto HMAC import requires a declared length to satisfy data_bits - 8 < length <= data_bits.
        if (spec.has_length_bits
            && (spec.length_bits > material.size() * 8 || spec.length_bits + 8 <= material.size() * 8)) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
        out_key = createHmacKey(global_object, spec.hash, WTF::move(material), spec.extractable, spec.usages,
            spec.has_length_bits ? spec.length_bits : 0);
        if (out_key)
            material_guard.dismiss();
        return !takePendingException(scope, out_error);
    }

    if (isAesAlgorithm(spec.algorithm)) {
        if (!validateRequestedUsages(spec.usages, allowedUsagesForAes(spec.algorithm), out_error, global_object)
            || !validateRequiredUsages(spec.usages, out_error, global_object))
            return false;
        if (!isValidAesKeyLength(material.size())) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
        out_key = createAesKey(global_object, spec.algorithm, WTF::move(material), spec.extractable, spec.usages);
        if (out_key)
            material_guard.dismiss();
        return !takePendingException(scope, out_error);
    }

    if (spec.algorithm == CryptoKeyAlgorithm::Pbkdf2 || spec.algorithm == CryptoKeyAlgorithm::Hkdf) {
        if (!validateRequestedUsages(
                spec.usages, CryptoKeyUsageDeriveBits | CryptoKeyUsageDeriveKey, out_error, global_object)
            || !validateRequiredUsages(spec.usages, out_error, global_object))
            return false;
        if (spec.extractable) {
            out_error = domExceptionValue(
                global_object, DOMExceptionCode::SyntaxError, "A required parameter was missing or out-of-range"_s);
            return false;
        }
        out_key = createRawDeriveKey(global_object, spec.algorithm, WTF::move(material), spec.usages);
        if (out_key)
            material_guard.dismiss();
        return !takePendingException(scope, out_error);
    }

    if (isEcAlgorithm(spec.algorithm)) {
        if (!validateRequestedUsages(spec.usages, allowedPublicUsagesForEc(spec.algorithm), out_error, global_object))
            return false;
        // Only uncompressed points are accepted, as in makeEcKeyFromRaw in raw.cpp.
        if (!isUncompressedEcPoint(material.span(), coordinateBytesForNamedCurve(spec.curve))) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
        bssl::UniquePtr<EC_KEY> ec(EC_KEY_new_by_curve_name(nidForNamedCurve(spec.curve)));
        auto* group = ec ? EC_KEY_get0_group(ec.get()) : nullptr;
        bssl::UniquePtr<EC_POINT> point(group ? EC_POINT_new(group) : nullptr);
        if (!group || !point
            || EC_POINT_oct2point(group, point.get(), material.span().data(), material.size(), nullptr) != 1
            || EC_KEY_set_public_key(ec.get(), point.get()) != 1 || EC_KEY_check_key(ec.get()) != 1) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
        auto pkey = pkeyFromEc(ec.get());
        if (!pkey) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
        out_key = createEcKey(global_object, spec.algorithm, CryptoKeyType::Public, spec.curve, WTF::move(pkey),
            spec.extractable, spec.usages);
        if (!out_key) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
        return !takePendingException(scope, out_error);
    }

    if (isOkpAlgorithm(spec.algorithm)) {
        if (!validateRequestedUsages(spec.usages, allowedPublicUsagesForOkp(spec.algorithm), out_error, global_object))
            return false;
        if (material.size() != 32) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
        bssl::UniquePtr<EVP_PKEY> pkey(EVP_PKEY_new_raw_public_key(
            evpTypeForOkp(spec.algorithm), nullptr, material.span().data(), material.size()));
        if (!pkey) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
        out_key = createOkpKey(
            global_object, spec.algorithm, CryptoKeyType::Public, WTF::move(pkey), spec.extractable, spec.usages);
        if (!out_key) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
        return !takePendingException(scope, out_error);
    }

    out_error = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError);
    return false;
}

static bool importUnwrappedAsymmetricDerWithSpec(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope,
    const String& format, std::span<const uint8_t> bytes, const UnwrappedKeyImportSpec& spec,
    JSColloCryptoKey*& out_key, JSC::JSValue& out_error)
{
    const bool is_spki = format == "spki"_s;
    const bool is_pkcs8 = format == "pkcs8"_s;
    if (!is_spki && !is_pkcs8) {
        out_error = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError);
        return false;
    }

    const uint8_t* ptr = bytes.data();
    const uint8_t* end = bytes.empty() ? ptr : ptr + bytes.size();

    if (isRsaAlgorithm(spec.algorithm)) {
        if (is_spki) {
            if (!validateRequestedUsages(
                    spec.usages, allowedPublicUsagesForRsa(spec.algorithm), out_error, global_object))
                return false;
            bssl::UniquePtr<EVP_PKEY> pkey(d2i_PUBKEY(nullptr, &ptr, bytes.size()));
            if (!pkey || ptr != end || EVP_PKEY_id(pkey.get()) != EVP_PKEY_RSA) {
                out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
                return false;
            }
            out_key = createRsaKey(global_object, spec.algorithm, spec.hash, CryptoKeyType::Public, WTF::move(pkey),
                spec.extractable, spec.usages);
        } else {
            if (!validateRequestedUsages(
                    spec.usages, allowedPrivateUsagesForRsa(spec.algorithm), out_error, global_object)
                || !validateRequiredUsages(spec.usages, out_error, global_object))
                return false;
            bssl::UniquePtr<PKCS8_PRIV_KEY_INFO> pkcs8(d2i_PKCS8_PRIV_KEY_INFO(nullptr, &ptr, bytes.size()));
            if (!pkcs8 || ptr != end) {
                out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
                return false;
            }
            bssl::UniquePtr<EVP_PKEY> pkey(EVP_PKCS82PKEY(pkcs8.get()));
            if (!pkey || EVP_PKEY_id(pkey.get()) != EVP_PKEY_RSA) {
                out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
                return false;
            }
            out_key = createRsaKey(global_object, spec.algorithm, spec.hash, CryptoKeyType::Private, WTF::move(pkey),
                spec.extractable, spec.usages);
        }
        if (!out_key) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
        return !takePendingException(scope, out_error);
    }

    if (isEcAlgorithm(spec.algorithm)) {
        if (is_spki) {
            if (!validateRequestedUsages(
                    spec.usages, allowedPublicUsagesForEc(spec.algorithm), out_error, global_object))
                return false;
            bssl::UniquePtr<EVP_PKEY> pkey(d2i_PUBKEY(nullptr, &ptr, bytes.size()));
            if (!pkey || ptr != end || EVP_PKEY_id(pkey.get()) != EVP_PKEY_EC) {
                out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
                return false;
            }
            out_key = createEcKey(global_object, spec.algorithm, CryptoKeyType::Public, spec.curve, WTF::move(pkey),
                spec.extractable, spec.usages);
        } else {
            if (!validateRequestedUsages(
                    spec.usages, allowedPrivateUsagesForEc(spec.algorithm), out_error, global_object)
                || !validateRequiredUsages(spec.usages, out_error, global_object))
                return false;
            bssl::UniquePtr<PKCS8_PRIV_KEY_INFO> pkcs8(d2i_PKCS8_PRIV_KEY_INFO(nullptr, &ptr, bytes.size()));
            if (!pkcs8 || ptr != end) {
                out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
                return false;
            }
            bssl::UniquePtr<EVP_PKEY> pkey(EVP_PKCS82PKEY(pkcs8.get()));
            if (!pkey || EVP_PKEY_id(pkey.get()) != EVP_PKEY_EC) {
                out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
                return false;
            }
            out_key = createEcKey(global_object, spec.algorithm, CryptoKeyType::Private, spec.curve, WTF::move(pkey),
                spec.extractable, spec.usages);
        }
        if (!out_key) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
        return !takePendingException(scope, out_error);
    }

    if (isOkpAlgorithm(spec.algorithm)) {
        if (is_spki) {
            if (!validateRequestedUsages(
                    spec.usages, allowedPublicUsagesForOkp(spec.algorithm), out_error, global_object))
                return false;
            bssl::UniquePtr<EVP_PKEY> pkey(d2i_PUBKEY(nullptr, &ptr, bytes.size()));
            if (!pkey || ptr != end || EVP_PKEY_id(pkey.get()) != evpTypeForOkp(spec.algorithm)) {
                out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
                return false;
            }
            out_key = createOkpKey(
                global_object, spec.algorithm, CryptoKeyType::Public, WTF::move(pkey), spec.extractable, spec.usages);
        } else {
            if (!validateRequestedUsages(
                    spec.usages, allowedPrivateUsagesForOkp(spec.algorithm), out_error, global_object)
                || !validateRequiredUsages(spec.usages, out_error, global_object))
                return false;
            bssl::UniquePtr<PKCS8_PRIV_KEY_INFO> pkcs8(d2i_PKCS8_PRIV_KEY_INFO(nullptr, &ptr, bytes.size()));
            if (!pkcs8 || ptr != end) {
                out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
                return false;
            }
            bssl::UniquePtr<EVP_PKEY> pkey(EVP_PKCS82PKEY(pkcs8.get()));
            if (!pkey || EVP_PKEY_id(pkey.get()) != evpTypeForOkp(spec.algorithm)) {
                out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
                return false;
            }
            out_key = createOkpKey(
                global_object, spec.algorithm, CryptoKeyType::Private, WTF::move(pkey), spec.extractable, spec.usages);
        }
        if (!out_key) {
            out_error = domExceptionValue(global_object, DOMExceptionCode::DataError);
            return false;
        }
        return !takePendingException(scope, out_error);
    }

    out_error = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError);
    return false;
}

bool importUnwrappedKeyBytesWithSpec(JSC::JSGlobalObject* global_object, JSC::TopExceptionScope& scope,
    const String& format, WTF::Vector<uint8_t>&& bytes, const UnwrappedKeyImportSpec& spec, JSColloCryptoKey*& out_key,
    JSC::JSValue& out_error)
{
    SecureVectorGuard bytes_guard(bytes);
    if (format == "raw"_s)
        return importUnwrappedRawWithSpec(global_object, scope, WTF::move(bytes), spec, out_key, out_error);
    if (format == "spki"_s || format == "pkcs8"_s)
        return importUnwrappedAsymmetricDerWithSpec(
            global_object, scope, format, bytes.span(), spec, out_key, out_error);
    if (format == "jwk"_s)
        return importUnwrappedJwkWithSpec(global_object, scope, bytes.span(), spec, out_key, out_error);

    out_error = domExceptionValue(global_object, DOMExceptionCode::NotSupportedError);
    return false;
}

} // namespace Collo::HostFunctions::WebCrypto
