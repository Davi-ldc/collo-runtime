// The storage behind a Headers cell and the Fetch Standard's header rules: name and value validation, the guards,
// Set-Cookie's separate value list, and the name-sorted keys that iteration and serialization read. Only headers.cpp
// includes this file; its functions are static, so each includer compiles a copy of its own. Only the VM thread
// mutates a list.
//
// A HeadersList keeps names, lowercased, and values as UTF-8 in one byte vector that entries address by offset and
// length, which caps it at UINT32_MAX bytes. A name covered by KnownHeader is stored as the enum alone. A name has at
// most one entry, holding its values combined with ", "; Set-Cookie values never combine and live in a list of their
// own. Every mutation bumps update_counter, which tells a live iterator to re-sort. Bytes that an overwrite or a
// removal orphans stay counted in dead_bytes until a compaction reclaims them.

#pragma once

#include "host_functions/server/fetch/headers.h"

#include <JavaScriptCore/Error.h>
#include <JavaScriptCore/IteratorOperations.h>
#include <JavaScriptCore/JSCInlines.h>
#include <JavaScriptCore/JSObject.h>
#include <JavaScriptCore/JSString.h>
#include <wtf/Vector.h>
#include <wtf/text/CString.h>
#include <wtf/text/StringBuilder.h>
#include <wtf/text/WTFString.h>

#include <algorithm>
#include <cstring>
#include <limits>
#include <optional>
#include <span>

namespace Collo::HostFunctions::FetchHeadersInternal {

using JSC::EncodedJSValue;
using JSC::JSValue;
using WTF::String;
using namespace JSC;

// The header names an entry records as this enum alone, with no name bytes in storage; Unknown marks an entry whose
// name is in storage. Set-Cookie values live in set_cookie_values, so no entry holds SetCookie.
enum class KnownHeader : uint8_t {
    Unknown,
    SetCookie,
    ContentType,
    ContentLength,
    TransferEncoding,
    Connection,
    Host,
    Accept,
    Authorization,
    Range,
};

struct HeaderSlice {
    uint32_t offset { 0 };
    uint32_t length { 0 };
};

// `name` is empty exactly when `known` names the header.
struct HeaderEntry {
    HeaderSlice name;
    HeaderSlice value;
    KnownHeader known { KnownHeader::Unknown };
};

// Indexes `entries`, or `set_cookie_values` when `set_cookie` is set.
struct HeaderSortKey {
    bool set_cookie { false };
    unsigned index { 0 };
};

// A tchar of RFC 9110 §5.6.2, the characters a header name may use.
static bool isHTTPTokenCode(char16_t ch)
{
    return (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '!' || ch == '#'
        || ch == '$' || ch == '%' || ch == '&' || ch == '\'' || ch == '*' || ch == '+' || ch == '-' || ch == '.'
        || ch == '^' || ch == '_' || ch == '`' || ch == '|' || ch == '~';
}

static bool isValidHeaderName(const String& value)
{
    if (value.isEmpty())
        return false;
    for (unsigned index = 0; index < value.length(); index++) {
        if (!isHTTPTokenCode(value[index]))
            return false;
    }
    return true;
}

// The Fetch Standard's HTTP whitespace, which normalizing a header value strips from both ends.
static bool isHeaderValueTrimByte(char16_t ch) { return ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n'; }

static String trimHeaderValue(const String& value)
{
    unsigned start = 0;
    unsigned end = value.length();
    while (start < end && isHeaderValueTrimByte(value[start]))
        start++;
    while (end > start && isHeaderValueTrimByte(value[end - 1]))
        end--;
    if (start == 0 && end == value.length())
        return value;
    return value.substring(start, end - start);
}

static bool isValidHeaderValue(const String& value)
{
    for (unsigned index = 0; index < value.length(); index++) {
        auto ch = value[index];
        if (ch == '\0' || ch == '\r' || ch == '\n')
            return false;
    }
    return true;
}

static std::optional<String> normalizeHeaderName(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue name_value)
{
    auto name = valueToWebApiString(global_object, scope, name_value);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (!isValidHeaderName(name)) {
        JSC::throwVMTypeError(global_object, scope, "invalid header name"_s);
        return std::nullopt;
    }
    return name.convertToASCIILowercase();
}

static std::optional<String> normalizeHeaderValue(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue value_value)
{
    auto value = trimHeaderValue(valueToWebApiString(global_object, scope, value_value));
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (!isValidHeaderValue(value)) {
        JSC::throwVMTypeError(global_object, scope, "invalid header value"_s);
        return std::nullopt;
    }
    return value;
}

static std::optional<std::pair<String, String>> normalizeHeaderPair(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, JSValue name_value, JSValue value_value)
{
    auto name = normalizeHeaderName(global_object, scope, name_value);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (!name)
        return std::nullopt;
    auto value = normalizeHeaderValue(global_object, scope, value_value);
    RETURN_IF_EXCEPTION(scope, std::nullopt);
    if (!value)
        return std::nullopt;
    return { { WTF::move(*name), WTF::move(*value) } };
}

static std::optional<std::pair<String, String>> normalizeRawHeaderPair(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const ColloNameValuePair& pair)
{
    String name;
    String value;
    if (Collo::stringToWTFString(pair.name, name) != COLLO_STATUS_OK
        || Collo::stringToWTFString(pair.value, value) != COLLO_STATUS_OK) {
        JSC::throwVMTypeError(global_object, scope, "invalid header encoding"_s);
        return std::nullopt;
    }

    value = trimHeaderValue(value);
    if (!isValidHeaderName(name)) {
        JSC::throwVMTypeError(global_object, scope, "invalid header name"_s);
        return std::nullopt;
    }
    if (!isValidHeaderValue(value)) {
        JSC::throwVMTypeError(global_object, scope, "invalid header value"_s);
        return std::nullopt;
    }

    return { { name.convertToASCIILowercase(), WTF::move(value) } };
}

static bool isSetCookieName(const String& name) { return name == "set-cookie"_s; }

static KnownHeader knownHeaderForName(const String& name)
{
    if (name == "set-cookie"_s)
        return KnownHeader::SetCookie;
    if (name == "content-type"_s)
        return KnownHeader::ContentType;
    if (name == "content-length"_s)
        return KnownHeader::ContentLength;
    if (name == "transfer-encoding"_s)
        return KnownHeader::TransferEncoding;
    if (name == "connection"_s)
        return KnownHeader::Connection;
    if (name == "host"_s)
        return KnownHeader::Host;
    if (name == "accept"_s)
        return KnownHeader::Accept;
    if (name == "authorization"_s)
        return KnownHeader::Authorization;
    if (name == "range"_s)
        return KnownHeader::Range;
    return KnownHeader::Unknown;
}

static std::span<const uint8_t> bytesForCString(const WTF::CString& value)
{
    return { reinterpret_cast<const uint8_t*>(value.data()), value.length() };
}

static bool bytesEqual(std::span<const uint8_t> left, std::span<const uint8_t> right)
{
    return left.size() == right.size() && (!left.size() || std::memcmp(left.data(), right.data(), left.size()) == 0);
}

static bool bytesLess(std::span<const uint8_t> left, std::span<const uint8_t> right)
{
    size_t common = std::min(left.size(), right.size());
    if (common) {
        int compare = std::memcmp(left.data(), right.data(), common);
        if (compare)
            return compare < 0;
    }
    return left.size() < right.size();
}

static bool isForbiddenMethodName(const String& method)
{
    return method == "connect"_s || method == "trace"_s || method == "track"_s;
}

static String trimHeaderSegment(const String& value, unsigned start, unsigned end)
{
    while (start < end && isHeaderValueTrimByte(value[start]))
        start++;
    while (end > start && isHeaderValueTrimByte(value[end - 1]))
        end--;
    return value.substring(start, end - start);
}

static bool hasForbiddenMethodOverrideValue(const String& value)
{
    unsigned start = 0;
    for (unsigned index = 0; index <= value.length(); index++) {
        if (index != value.length() && value[index] != ',')
            continue;
        if (isForbiddenMethodName(trimHeaderSegment(value, start, index).convertToASCIILowercase()))
            return true;
        start = index + 1;
    }
    return false;
}

static bool isForbiddenRequestHeaderName(const String& name)
{
    return name == "accept-charset"_s || name == "accept-encoding"_s || name == "access-control-request-headers"_s
        || name == "access-control-request-method"_s || name == "connection"_s || name == "content-length"_s
        || name == "cookie"_s || name == "cookie2"_s || name == "date"_s || name == "dnt"_s || name == "expect"_s
        || name == "host"_s || name == "keep-alive"_s || name == "origin"_s || name == "referer"_s
        || name == "set-cookie"_s || name == "te"_s || name == "trailer"_s || name == "transfer-encoding"_s
        || name == "upgrade"_s || name == "via"_s || name.startsWith("sec-"_s) || name.startsWith("proxy-"_s);
}

// The Fetch Standard's forbidden request-header: a forbidden name, or a method-override header that names a forbidden
// method.
static bool isForbiddenRequestHeader(const String& name, const String& value)
{
    if (isForbiddenRequestHeaderName(name))
        return true;
    if (name == "x-http-method-override"_s || name == "x-http-method"_s || name == "x-method-override"_s)
        return hasForbiddenMethodOverrideValue(value);
    return false;
}

static bool isForbiddenResponseHeaderName(const String& name)
{
    return name == "set-cookie"_s || name == "set-cookie2"_s;
}

static bool isNoCorsSafelistedHeaderName(const String& name)
{
    return name == "accept"_s || name == "accept-language"_s || name == "content-language"_s
        || name == "content-type"_s;
}

static bool isNoCorsSafelistedContentType(const String& value)
{
    String lower = value.convertToASCIILowercase();
    unsigned end = 0;
    while (end < lower.length() && lower[end] != ';')
        end++;
    String mime = trimHeaderSegment(lower, 0, end);
    return mime == "application/x-www-form-urlencoded"_s || mime == "multipart/form-data"_s || mime == "text/plain"_s;
}

// The Fetch Standard's no-CORS-safelisted request-header.
// FIXME: The value checks are incomplete. The standard also rejects CORS-unsafe request-header bytes in Accept and
// Content-Type values, limits Accept-Language and Content-Language values to a small byte set, and measures its
// 128-byte value limit in bytes, where this check counts UTF-16 code units.
static bool isSimpleNoCorsHeader(const String& name, const String& combined_value)
{
    if (combined_value.length() > 128)
        return false;
    if (!isNoCorsSafelistedHeaderName(name))
        return false;
    if (name == "content-type"_s)
        return isNoCorsSafelistedContentType(combined_value);
    return true;
}

// Whether `guard` lets a write store `name`: nullopt after throwing for an immutable guard, false to drop the write
// silently, true to store it. `combined_value` is the value the entry would hold after the write, which the no-CORS
// check reads.
static std::optional<bool> canWriteHeader(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope,
    const String& name, const String& value, const String& combined_value, HeaderGuard guard)
{
    if (guard == HeaderGuard::Immutable) {
        JSC::throwVMTypeError(global_object, scope, "Headers object's guard is 'immutable'"_s);
        return std::nullopt;
    }
    if (guard == HeaderGuard::Request && isForbiddenRequestHeader(name, value))
        return false;
    if (guard == HeaderGuard::RequestNoCors && !isSimpleNoCorsHeader(name, combined_value))
        return false;
    if (guard == HeaderGuard::Response && isForbiddenResponseHeaderName(name))
        return false;
    return true;
}

// The guard check set() and append() run for set-cookie instead of canWriteHeader: an immutable guard throws, a
// Response guard drops the write because set-cookie is a forbidden response-header name, and every other guard stores
// it. Returns nullopt after throwing, false to drop the write silently and true to store it.
// FIXME: The Fetch Standard also lists Set-Cookie as a forbidden request-header, so the Request and RequestNoCors
// guards should drop it too. remove() and cloneHeadersList already treat it as forbidden under those guards.
static std::optional<bool> canWriteSetCookie(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, HeaderGuard guard)
{
    if (guard == HeaderGuard::Immutable) {
        JSC::throwVMTypeError(global_object, scope, "Headers object's guard is 'immutable'"_s);
        return std::nullopt;
    }
    if (guard == HeaderGuard::Response)
        return false;
    return true;
}

struct HeadersList {
    HeaderGuard guard { HeaderGuard::None };
    WTF::Vector<uint8_t, 256> storage;
    WTF::Vector<HeaderEntry, 4> entries;
    WTF::Vector<HeaderSlice, 2> set_cookie_values;
    uint64_t update_counter { 0 };
    // Bytes of `storage` that no entry or Set-Cookie slice references any more; maybeCompact reclaims them.
    uint32_t dead_bytes { 0 };

    // maybeCompact never reclaims fewer dead bytes than this, so a small list does not rebuild its buffer on every
    // overwrite.
    static constexpr uint32_t kCompactionFloorBytes = 4096;

    explicit HeadersList(HeaderGuard guard = HeaderGuard::None)
        : guard(guard)
    {
    }

    static std::span<const uint8_t> setCookieNameBytes()
    {
        static constexpr char name[] = "set-cookie";
        return { reinterpret_cast<const uint8_t*>(name), sizeof(name) - 1 };
    }

    template <size_t length> static std::span<const uint8_t> literalBytes(const char (&value)[length])
    {
        return { reinterpret_cast<const uint8_t*>(value), length - 1 };
    }

    static std::span<const uint8_t> knownHeaderNameBytes(KnownHeader known)
    {
        switch (known) {
        case KnownHeader::SetCookie:
            return literalBytes("set-cookie");
        case KnownHeader::ContentType:
            return literalBytes("content-type");
        case KnownHeader::ContentLength:
            return literalBytes("content-length");
        case KnownHeader::TransferEncoding:
            return literalBytes("transfer-encoding");
        case KnownHeader::Connection:
            return literalBytes("connection");
        case KnownHeader::Host:
            return literalBytes("host");
        case KnownHeader::Accept:
            return literalBytes("accept");
        case KnownHeader::Authorization:
            return literalBytes("authorization");
        case KnownHeader::Range:
            return literalBytes("range");
        case KnownHeader::Unknown:
            return {};
        }
        return {};
    }

    static String knownHeaderNameString(KnownHeader known)
    {
        switch (known) {
        case KnownHeader::SetCookie:
            return "set-cookie"_s;
        case KnownHeader::ContentType:
            return "content-type"_s;
        case KnownHeader::ContentLength:
            return "content-length"_s;
        case KnownHeader::TransferEncoding:
            return "transfer-encoding"_s;
        case KnownHeader::Connection:
            return "connection"_s;
        case KnownHeader::Host:
            return "host"_s;
        case KnownHeader::Accept:
            return "accept"_s;
        case KnownHeader::Authorization:
            return "authorization"_s;
        case KnownHeader::Range:
            return "range"_s;
        case KnownHeader::Unknown:
            return emptyString();
        }
        return emptyString();
    }

    std::span<const uint8_t> bytes(HeaderSlice slice) const
    {
        if (!slice.length)
            return {};
        return storage.span().subspan(slice.offset, slice.length);
    }

    String string(HeaderSlice slice) const
    {
        if (!slice.length)
            return emptyString();
        return String::fromUTF8(bytes(slice));
    }

    // Appends `value` to storage and returns its slice, or nullopt when storage would pass UINT32_MAX bytes. A failed
    // allocation crashes, since Vector::grow does not report it.
    std::optional<HeaderSlice> appendBytes(std::span<const uint8_t> value)
    {
        if (value.size() > std::numeric_limits<uint32_t>::max())
            return std::nullopt;
        if (storage.size() > std::numeric_limits<uint32_t>::max() - value.size())
            return std::nullopt;

        HeaderSlice slice {
            static_cast<uint32_t>(storage.size()),
            static_cast<uint32_t>(value.size()),
        };
        if (value.empty())
            return slice;

        size_t old_size = storage.size();
        storage.grow(old_size + value.size());
        std::memcpy(storage.mutableSpan().data() + old_size, value.data(), value.size());
        return slice;
    }

    void reserveStorage(size_t bytes)
    {
        storage.reserveInitialCapacity(
            static_cast<unsigned>(std::min(bytes, static_cast<size_t>(std::numeric_limits<unsigned>::max()))));
    }

    std::optional<HeaderSlice> appendString(const String& value)
    {
        auto utf8 = value.utf8();
        return appendBytes(bytesForCString(utf8));
    }

    size_t liveBytes() const
    {
        // dead_bytes counts bytes inside storage, each at most once, so it never exceeds storage.size().
        return storage.size() - dead_bytes;
    }

    // Moves the bytes that entries and Set-Cookie values reference into a new buffer of liveBytes() and repoints
    // every slice, which invalidates any span into storage. Returns false, leaving the list unchanged, only when that
    // buffer cannot be allocated.
    bool compactStorage()
    {
        size_t live = liveBytes();
        WTF::Vector<uint8_t, 256> rebuilt;
        if (live) {
            if (!rebuilt.tryReserveCapacity(live))
                return false;
        }

        auto relocate = [&](HeaderSlice& slice) {
            if (!slice.length) {
                slice.offset = 0;
                return;
            }
            auto src = storage.span().subspan(slice.offset, slice.length);
            slice.offset = static_cast<uint32_t>(rebuilt.size());
            rebuilt.append(src);
        };

        for (auto& entry : entries) {
            relocate(entry.name);
            relocate(entry.value);
        }
        for (auto& cookie : set_cookie_values)
            relocate(cookie);

        storage = WTF::move(rebuilt);
        dead_bytes = 0;
        return true;
    }

    // Compacts once the dead bytes reach both kCompactionFloorBytes and the live byte count. A compaction copies no
    // more bytes than were orphaned since the previous one, so reclaiming costs O(1) per byte written, and right after
    // a check storage stays under about twice the live bytes plus the floor. An in-place overwrite in
    // storeValueInSlice adds dead bytes without growing storage and runs no check. A failed compaction leaves the
    // dead bytes for the next check.
    void maybeCompact()
    {
        if (dead_bytes < kCompactionFloorBytes)
            return;
        if (dead_bytes < liveBytes())
            return;
        compactStorage();
    }

    void markDead(uint32_t length) { dead_bytes += length; }

    bool entryNameEquals(const HeaderEntry& entry, const String& name, KnownHeader known) const
    {
        if (known != KnownHeader::Unknown)
            return entry.known == known;
        if (entry.known != KnownHeader::Unknown)
            return false;

        auto utf8 = name.utf8();
        return bytesEqual(bytes(entry.name), bytesForCString(utf8));
    }

    std::optional<unsigned> find(const String& name) const
    {
        auto known = knownHeaderForName(name);
        for (unsigned index = 0; index < entries.size(); index++) {
            if (entryNameEquals(entries[index], name, known))
                return index;
        }
        return std::nullopt;
    }

    // FIXME: Under the Fetch Standard, has() and get() see Set-Cookie, get() joining its values with ", ", and
    // iteration lists each Set-Cookie value. Here only getSetCookie() returns them: has() and get() report set-cookie
    // absent, and headers.cpp iterates and runs forEach over keys built without Set-Cookie values.
    bool has(const String& name) const
    {
        if (isSetCookieName(name))
            return false;
        return find(name).has_value();
    }

    bool get(const String& name, String& out) const
    {
        if (isSetCookieName(name))
            return false;
        if (auto index = find(name)) {
            out = string(entries[*index].value);
            return true;
        }
        return false;
    }

    String nameForKey(HeaderSortKey key) const
    {
        if (key.set_cookie)
            return "set-cookie"_s;
        if (entries[key.index].known != KnownHeader::Unknown)
            return knownHeaderNameString(entries[key.index].known);
        return string(entries[key.index].name);
    }

    String valueForKey(HeaderSortKey key) const
    {
        if (key.set_cookie)
            return string(set_cookie_values[key.index]);
        return string(entries[key.index].value);
    }

    std::span<const uint8_t> nameBytesForKey(HeaderSortKey key) const
    {
        if (key.set_cookie)
            return setCookieNameBytes();
        if (entries[key.index].known != KnownHeader::Unknown)
            return knownHeaderNameBytes(entries[key.index].known);
        return bytes(entries[key.index].name);
    }

    std::span<const uint8_t> valueBytesForKey(HeaderSortKey key) const
    {
        if (key.set_cookie)
            return bytes(set_cookie_values[key.index]);
        return bytes(entries[key.index].value);
    }

    bool less(HeaderSortKey left, HeaderSortKey right) const
    {
        return bytesLess(nameBytesForKey(left), nameBytesForKey(right));
    }

    bool appendStoredSetCookie(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const String& value)
    {
        auto slice = appendString(value);
        if (!slice) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        set_cookie_values.append(*slice);
        update_counter++;
        return true;
    }

    bool appendSetCookie(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, String value)
    {
        auto can_write = canWriteSetCookie(global_object, scope, guard);
        RETURN_IF_EXCEPTION(scope, false);
        if (!can_write)
            return false;
        if (!*can_write)
            return true;
        return appendStoredSetCookie(global_object, scope, value);
    }

    bool appendStoredEntry(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const String& name,
        const String& value, KnownHeader known)
    {
        std::optional<HeaderSlice> name_slice;
        if (known == KnownHeader::Unknown)
            name_slice = appendString(name);
        else
            name_slice = HeaderSlice {};
        auto value_slice = appendString(value);
        if (!name_slice || !value_slice) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        entries.append({ *name_slice, *value_slice, known });
        update_counter++;
        return true;
    }

    // Stores `value`'s UTF-8 bytes in `slot`, which must belong to this list. Bytes that fit the slot's length
    // overwrite it in place and orphan the freed tail; longer bytes are appended, orphaning the old ones, and may
    // trigger a compaction, which invalidates any span into storage. Throws an OutOfMemoryError and returns false when
    // storage would pass UINT32_MAX bytes.
    bool storeValueInSlice(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, HeaderSlice& slot, const String& value)
    {
        auto utf8 = value.utf8();
        auto bytes = bytesForCString(utf8);
        if (bytes.size() > std::numeric_limits<uint32_t>::max()) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }

        if (bytes.size() <= slot.length) {
            uint32_t new_length = static_cast<uint32_t>(bytes.size());
            if (new_length)
                std::memcpy(storage.mutableSpan().data() + slot.offset, bytes.data(), new_length);
            markDead(slot.length - new_length);
            slot.length = new_length;
            slot.offset = new_length ? slot.offset : 0;
            update_counter++;
            return true;
        }

        auto new_slice = appendBytes(bytes);
        if (!new_slice) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }
        uint32_t old_length = slot.length;
        slot = *new_slice;
        markDead(old_length);
        maybeCompact();
        update_counter++;
        return true;
    }

    bool replaceEntryValue(
        JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, unsigned index, const String& value)
    {
        return storeValueInSlice(global_object, scope, entries[index].value, value);
    }

    // Appends `addition` to the value of entry `index` after a ", " separator. When that value ends storage, only the
    // separator and `addition` are written, extending the slice; otherwise `combined`, the whole combined value, goes
    // through storeValueInSlice.
    bool extendEntryValue(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, unsigned index,
        const String& addition, const String& combined)
    {
        HeaderSlice& slot = entries[index].value;
        bool at_tail = static_cast<size_t>(slot.offset) + slot.length == storage.size();
        if (!at_tail)
            return storeValueInSlice(global_object, scope, slot, combined);

        auto delta = WTF::makeString(", "_s, addition);
        auto utf8 = delta.utf8();
        auto delta_bytes = bytesForCString(utf8);
        if (delta_bytes.size() > std::numeric_limits<uint32_t>::max() - slot.length
            || storage.size() > std::numeric_limits<uint32_t>::max() - delta_bytes.size()) {
            JSC::throwOutOfMemoryError(global_object, scope);
            return false;
        }

        if (!delta_bytes.empty()) {
            size_t old_size = storage.size();
            if (!storage.tryGrow(old_size + delta_bytes.size())) {
                JSC::throwOutOfMemoryError(global_object, scope);
                return false;
            }
            std::memcpy(storage.mutableSpan().data() + old_size, delta_bytes.data(), delta_bytes.size());
            slot.length += static_cast<uint32_t>(delta_bytes.size());
        }
        update_counter++;
        return true;
    }

    bool append(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, String name, String value)
    {
        if (isSetCookieName(name))
            return appendSetCookie(global_object, scope, WTF::move(value));

        String combined_value = value;
        auto index = find(name);
        if (index)
            combined_value = WTF::makeString(string(entries[*index].value), ", "_s, value);
        auto can_write = canWriteHeader(global_object, scope, name, value, combined_value, guard);
        RETURN_IF_EXCEPTION(scope, false);
        if (!can_write)
            return false;
        if (!*can_write)
            return true;

        if (index)
            return extendEntryValue(global_object, scope, *index, value, combined_value);
        return appendStoredEntry(global_object, scope, name, value, knownHeaderForName(name));
    }

    bool set(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, String name, String value)
    {
        // Set-Cookie goes through canWriteSetCookie, as in append(), so the two agree under every guard.
        if (isSetCookieName(name)) {
            auto can_write = canWriteSetCookie(global_object, scope, guard);
            RETURN_IF_EXCEPTION(scope, false);
            if (!can_write)
                return false;
            if (!*can_write)
                return true;

            for (auto& cookie : set_cookie_values)
                markDead(cookie.length);
            set_cookie_values.clear();
            if (!appendStoredSetCookie(global_object, scope, value))
                return false;
            maybeCompact();
            return true;
        }

        auto can_write = canWriteHeader(global_object, scope, name, value, value, guard);
        RETURN_IF_EXCEPTION(scope, false);
        if (!can_write)
            return false;
        if (!*can_write)
            return true;

        if (auto index = find(name))
            return replaceEntryValue(global_object, scope, *index, value);
        return appendStoredEntry(global_object, scope, name, value, knownHeaderForName(name));
    }

    bool remove(JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, const String& name)
    {
        if (guard == HeaderGuard::Immutable) {
            JSC::throwVMTypeError(global_object, scope, "Headers object's guard is 'immutable'"_s);
            return false;
        }
        if (guard == HeaderGuard::Request && isForbiddenRequestHeaderName(name))
            return true;
        if (guard == HeaderGuard::RequestNoCors && !isNoCorsSafelistedHeaderName(name) && name != "range"_s)
            return true;
        if (guard == HeaderGuard::Response && isForbiddenResponseHeaderName(name))
            return true;

        if (isSetCookieName(name)) {
            if (!set_cookie_values.isEmpty()) {
                for (auto& cookie : set_cookie_values)
                    markDead(cookie.length);
                set_cookie_values.clear();
                update_counter++;
                maybeCompact();
            }
            return true;
        }
        if (auto index = find(name)) {
            markDead(entries[*index].name.length);
            markDead(entries[*index].value.length);
            entries.removeAt(*index);
            update_counter++;
            maybeCompact();
        }
        return true;
    }
};

// Copies `source` into a new list under `guard`, copying only the bytes of the entries `guard` keeps, plus the
// Set-Cookie values when `guard` is None or Immutable. A copy of the whole buffer would hold every entry before the
// guard dropped any, and would carry the source's dead bytes into a list whose dead_bytes starts at zero, so they would
// never be counted or compacted.
static HeadersList cloneHeadersList(const HeadersList& source, HeaderGuard guard)
{
    HeadersList list { guard };
    const bool filtered
        = guard == HeaderGuard::Request || guard == HeaderGuard::RequestNoCors || guard == HeaderGuard::Response;
    list.reserveStorage(source.liveBytes());
    list.entries.reserveInitialCapacity(source.entries.size());

    for (unsigned index = 0; index < source.entries.size(); index++) {
        const auto& entry = source.entries[index];
        if (filtered) {
            HeaderSortKey key { false, index };
            const auto name = source.nameForKey(key);
            const auto value = source.valueForKey(key);
            if (guard == HeaderGuard::Request && isForbiddenRequestHeader(name, value))
                continue;
            if (guard == HeaderGuard::RequestNoCors && !isSimpleNoCorsHeader(name, value))
                continue;
            if (guard == HeaderGuard::Response && isForbiddenResponseHeaderName(name))
                continue;
        }
        std::optional<HeaderSlice> name_slice { HeaderSlice {} };
        if (entry.known == KnownHeader::Unknown)
            name_slice = list.appendBytes(source.bytes(entry.name));
        auto value_slice = list.appendBytes(source.bytes(entry.value));
        // appendBytes fails only past UINT32_MAX bytes, and the kept bytes are a subset of the source's, which fit.
        ASSERT(name_slice && value_slice);
        if (!name_slice || !value_slice)
            continue;
        list.entries.append({ *name_slice, *value_slice, entry.known });
    }

    if (!filtered) {
        list.set_cookie_values.reserveInitialCapacity(source.set_cookie_values.size());
        for (const auto& cookie : source.set_cookie_values) {
            auto slice = list.appendBytes(source.bytes(cookie));
            ASSERT(slice);
            if (slice)
                list.set_cookie_values.append(*slice);
        }
    }
    return list;
}

static bool appendNormalizedPair(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, HeadersList& list, String name, String value)
{
    return list.append(global_object, scope, WTF::move(name), WTF::move(value));
}

static bool appendIterableHeaderPair(
    JSC::JSGlobalObject* global_object, JSC::ThrowScope& scope, HeadersList& list, JSValue pair_value)
{
    WTF::Vector<JSValue, 2> values;
    bool too_many = false;

    JSC::forEachInIterable(global_object, pair_value, [&](JSC::VM&, JSC::JSGlobalObject*, JSValue next_value) {
        if (values.size() >= 2) {
            too_many = true;
            return;
        }
        values.append(next_value);
    });
    RETURN_IF_EXCEPTION(scope, false);

    if (too_many || values.size() != 2) {
        JSC::throwVMTypeError(global_object, scope, "Headers init pair must contain exactly two items"_s);
        return false;
    }

    auto normalized = normalizeHeaderPair(global_object, scope, values[0], values[1]);
    RETURN_IF_EXCEPTION(scope, false);
    if (!normalized)
        return false;
    return appendNormalizedPair(
        global_object, scope, list, WTF::move(normalized->first), WTF::move(normalized->second));
}

// Keys for every entry, and for every Set-Cookie value when `include_set_cookie` is set, stably sorted by name bytes,
// so Set-Cookie values keep their insertion order.
static WTF::Vector<HeaderSortKey> sortedHeaderKeys(const HeadersList& list, bool include_set_cookie)
{
    WTF::Vector<HeaderSortKey> keys;
    keys.reserveInitialCapacity(list.entries.size() + (include_set_cookie ? list.set_cookie_values.size() : 0));
    for (unsigned index = 0; index < list.entries.size(); index++)
        keys.append({ false, index });
    if (include_set_cookie) {
        for (unsigned index = 0; index < list.set_cookie_values.size(); index++)
            keys.append({ true, index });
    }
    std::stable_sort(keys.begin(), keys.end(), [&list](auto left, auto right) { return list.less(left, right); });
    return keys;
}

} // namespace Collo::HostFunctions::FetchHeadersInternal
