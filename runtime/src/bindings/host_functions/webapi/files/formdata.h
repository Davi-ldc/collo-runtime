// The FormData surface the rest of the bridge uses: recognizing a FormData, parsing a form body into one, and
// serializing one into a multipart body. The Body methods of Request and Response, Blob.formData(), ReadableStream
// consumption and fetch's BodyInit extraction call these on the VM thread; formdata.cpp holds the FormData cell and
// multipart.cpp the multipart codec.

#pragma once

#include "host_functions/support.h"
#include "host_functions/webapi/files/blob.h"

#include <wtf/RefPtr.h>
#include <wtf/text/ASCIILiteral.h>

#include <span>

namespace Collo::HostFunctions {

// True when the parse error, as createFormDataFromBodyBytes stores it, reports an exceeded cap (body size, entry
// count or headers per part). The caller then rejects with a QuotaExceededError DOMException carrying that text,
// instead of a TypeError.
bool isFormDataQuotaParseError(WTF::ASCIILiteral);

// The QuotaExceededError for a form body over WebApiMaterializedBodyBytesMax, parsed or serialized. Blob.formData()
// rejects with it before copying an oversized blob, so that early rejection matches the one the parser produces after
// the copy, and serializeFormDataToMultipartBody throws it for a FormData whose body would not fit.
JSC::JSObject* createFormDataBodyQuotaExceeded(JSC::JSGlobalObject*);

// True for a FormData instance. Fetch's BodyInit extraction (body_init.cpp) uses it to pick the multipart serializer,
// since the cell class is private to formdata.cpp.
bool isColloFormData(JSC::JSValue);

// Parses `bytes` as a form body into a new FormData. `content_type` picks the parser:
// application/x-www-form-urlencoded, or multipart/form-data with a boundary parameter; any other type is a parse
// error. Returns null on failure. When `out_parse_error` is given, a malformed body or an exceeded cap stores its
// message there and throws nothing, so the caller can reject a promise; isFormDataQuotaParseError tells the two cases
// apart. Without it, those failures throw a TypeError or a QuotaExceededError DOMException. Allocation failure always
// throws.
JSC::JSObject* createFormDataFromBodyBytes(JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<const uint8_t> bytes,
    WTF::String content_type, WTF::ASCIILiteral* out_parse_error = nullptr);

// Serializes a FormData into a multipart/form-data body (serializeMultipartFormBody in multipart.h says how). A File or
// Blob part shares the bytes of its entry's BlobStorage. On success `out_size` is the body's length and
// `out_content_type` is `multipart/form-data; boundary=...`. Returns null and throws when the body would exceed
// WebApiMaterializedBodyBytesMax (createFormDataBodyQuotaExceeded's error, before any byte is copied), and on
// allocation or entropy failure. Returns null without throwing when `form_data_value` is not a FormData.
WTF::RefPtr<BlobStorage> serializeFormDataToMultipartBody(JSC::JSGlobalObject*, JSC::ThrowScope&,
    JSC::JSValue form_data_value, size_t& out_size, WTF::String& out_content_type);

void installWebApiFormData(Collo::GlobalObject*, JSC::VM&);

} // namespace Collo::HostFunctions
