// The Headers API the rest of the fetch bridge uses: building a Headers cell from a JavaScript init or from ABI pairs,
// cloning one, reading or defaulting a single header, and flattening one into pairs for an outbound fetch or a host
// response. The cell and its storage live in headers.cpp and headers_list.h. VM thread only.
//
// A JSObject* parameter named headers must be a Headers cell; anything else throws a TypeError. Every JSGlobalObject
// parameter must be a Collo::GlobalObject, which these functions downcast without checking. A function that returns
// null or false has thrown into its scope, except where its comment says otherwise. A Headers cell returned here is
// new and rooted only by the caller's stack until the caller stores it.

#pragma once

#include "host_functions/support.h"

#include <wtf/Vector.h>

namespace Collo::HostFunctions {

// One header as it leaves a Headers cell: a lowercase name and its value. Each Set-Cookie value is a pair of its own;
// any other name appears once, with its values combined by ", ".
struct ColloHeaderPair {
    WTF::String name;
    WTF::String value;
};

// The pair count and the name and value bytes that collectHeadersToPairs would produce. The byte total saturates at
// SIZE_MAX.
struct HeaderExtractionStats {
    size_t count { 0 };
    size_t aggregate_bytes { 0 };
};

// The Fetch Standard's headers guard. Immutable throws on every write. Request silently drops forbidden
// request-headers, RequestNoCors drops whatever is not a no-CORS-safelisted request-header, and Response drops
// forbidden response-header names. Set-Cookie writes follow canWriteSetCookie in headers_list.h instead. None accepts
// every valid header.
enum class HeaderGuard : uint8_t {
    None,
    Immutable,
    Request,
    RequestNoCors,
    Response,
};

// Builds a Headers cell from a HeadersInit: undefined or null for an empty list, another Headers cell, an iterable of
// name and value pairs, or a record of own enumerable string properties. Every header passes through `guard`, so a
// Headers init is copied without the entries `guard` forbids. With a non-empty init other than a Headers cell, an
// Immutable guard throws on the first header.
JSC::JSObject* createHeadersFromJS(
    JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSValue init, HeaderGuard guard = HeaderGuard::None);
// Builds a Headers cell from `pairs_len` borrowed ABI pairs. A pair that is not UTF-8 or not a valid header name and
// value throws a TypeError. Names are lowercased and values trimmed. An Immutable guard takes effect once every pair
// is in; any other guard filters the pairs as they are appended.
JSC::JSObject* createHeadersFromRawPairs(JSC::JSGlobalObject*, JSC::ThrowScope&, const ColloNameValuePair* pairs,
    size_t pairs_len, HeaderGuard guard = HeaderGuard::None);
// Copies a Headers cell under its own guard, so the clone of an immutable Headers stays immutable.
JSC::JSObject* cloneHeadersPreservingGuard(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSObject* headers);
// Fills `pairs`, which must be empty with no reserved capacity, with every header sorted by name, Set-Cookie values in
// insertion order. Throws a QuotaExceededError DOMException past the outbound fetch request limits,
// WebApiFetchRequestHeaderCountMax pairs or WebApiFetchRequestHeadersBytesMax name and value bytes, and an
// OutOfMemoryError when `pairs` cannot grow.
bool collectHeadersToPairs(
    JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSObject* headers, WTF::Vector<ColloHeaderPair>& pairs);
// Fills `out` without applying any limit, so the caller can check its own before collecting the pairs.
bool inspectHeadersForExtraction(
    JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSObject* headers, HeaderExtractionStats& out);
// Sets `name` to `value` unless the Headers already has `name`, as a body's Content-Type or a redirect's Location is
// defaulted. `name` must be a valid header name other than set-cookie, which HeadersList::has never reports; it is
// lowercased here. `value` is trimmed but not checked for NUL, CR or LF, so the caller passes a valid header value.
// The Headers guard still applies.
bool setHeaderDefault(
    JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSObject* headers, WTF::String name, WTF::String value);
// Stores the value of `name`, lowercased here, in `out`. Returns false without throwing when the header is absent,
// and always for set-cookie, whose values only getSetCookie() returns.
bool getHeaderValue(JSC::JSGlobalObject*, JSC::ThrowScope&, JSC::JSObject* headers, WTF::String name, WTF::String& out);
// Installs the Headers constructor and its prototype on the global object, creates the Headers Iterator prototype,
// and stores the constructor, both prototypes and their structures in the VM's Web API cache. Host function
// installation calls it once per VM.
void installServerHeaders(Collo::GlobalObject*, JSC::VM&);

} // namespace Collo::HostFunctions
