// The form body codec behind FormData, private to files/: the Content-Type check that picks a form encoding, the
// multipart/form-data parser behind Body.formData() and Blob.formData(), and the multipart/form-data serializer behind
// a FormData request or response body. Both sides exchange plain data, and formdata.cpp turns parsed parts into
// FormData entries and entries into serializer input, so this codec never touches a FormData cell and never builds a
// DOMException. VM thread only: the parser allocates WTF strings and throws allocation failures into a ThrowScope; the
// serializer reports every failure as a result for formdata.cpp to throw.

#pragma once

#include "host_functions/webapi/files/blob.h"

#include <wtf/RefPtr.h>
#include <wtf/Vector.h>
#include <wtf/text/ASCIILiteral.h>
#include <wtf/text/WTFString.h>

#include <cstddef>
#include <cstdint>
#include <optional>
#include <span>

namespace Collo::HostFunctions {

// The parse errors that report an exceeded cap rather than malformed input, which isFormDataQuotaParseError
// (formdata.h) recognizes.
inline constexpr WTF::ASCIILiteral FormDataEntriesExceeded = "form data entry count exceeded"_s;
inline constexpr WTF::ASCIILiteral FormDataPartHeadersExceeded = "multipart part header count exceeded"_s;

enum class FormBodyEncoding : uint8_t {
    UrlEncoded,
    Multipart,
};

struct FormBodyContentType {
    FormBodyEncoding encoding { FormBodyEncoding::UrlEncoded };
    // The multipart boundary's bytes, all ASCII and none CR or LF; empty for UrlEncoded.
    WTF::Vector<uint8_t> boundary;
};

// Reads the encoding, and for multipart/form-data the boundary parameter, from a Content-Type. Returns nullopt for a
// type that is not a form type, and for a multipart type with a missing or invalid boundary, which also sets
// `parse_error`. Throws only on allocation failure.
std::optional<FormBodyContentType> parseFormBodyContentType(JSC::JSGlobalObject*, JSC::ThrowScope&,
    const WTF::String& content_type, std::optional<WTF::ASCIILiteral>& parse_error);

// One part of a parsed multipart body. A file part's bytes stay in the body, at `offset` and `size`.
struct MultipartParsedPart {
    WTF::String name;
    // A text part's value, decoded as UTF-8 with a leading BOM kept.
    WTF::String value;
    WTF::String filename;
    WTF::String content_type;
    size_t offset { 0 };
    size_t size { 0 };
    bool is_file { false };
};

// Parses `body` as multipart/form-data framed by `boundary`, which parseFormBodyContentType returned, and appends its
// parts to `out`. The body must start with the first delimiter; no preamble is accepted. A malformed body, or one past
// WebApiFormDataEntriesMax parts or WebApiFormDataPartHeadersMax header lines in one part, returns false with
// `parse_error` set and nothing thrown; the caps report FormDataEntriesExceeded and FormDataPartHeadersExceeded.
// Allocation failure throws and returns false.
bool parseMultipartFormBody(JSC::JSGlobalObject*, JSC::ThrowScope&, std::span<const uint8_t> body,
    std::span<const uint8_t> boundary, WTF::Vector<MultipartParsedPart>& out,
    std::optional<WTF::ASCIILiteral>& parse_error);

// One FormData entry as the serializer reads it: owning string copies and, for a File or Blob entry, a reference to
// its storage with the entry's range, so the serializer holds nothing that points into the FormData.
struct MultipartSerializedEntry {
    WTF::String name;
    WTF::String string_value;
    WTF::String filename;
    WTF::String content_type;
    WTF::RefPtr<BlobStorage> storage;
    size_t offset { 0 };
    size_t size { 0 };
    bool is_file { false };
};

enum class MultipartSerializeResult : uint8_t {
    Serialized,
    // The body would exceed WebApiMaterializedBodyBytesMax; nothing was copied.
    Exceeded,
    OutOfMemory,
    // RAND_bytes could not draw the boundary.
    EntropyFailure,
};

struct MultipartSerializedBody {
    // Owns the headers, the text values and the framing, and shares the bytes of each File or Blob part.
    WTF::RefPtr<BlobStorage> storage;
    size_t size { 0 };
    // `multipart/form-data; boundary=...`, with a fresh boundary carrying 128 random bits.
    WTF::String content_type;
};

// The most entries a serialized body can hold within WebApiMaterializedBodyBytesMax, counting each as the smallest
// part (a text entry with an empty name and value). A FormData with more entries can only fail with Exceeded, so its
// caller may refuse it before copying its entries.
size_t multipartSerializableEntriesMax();

// Serializes `entries` with the HTML Standard's multipart/form-data encoding algorithm, which Fetch runs to extract a
// body from a FormData. On Serialized, `out` holds the body; on any other result it is empty. Throws nothing.
MultipartSerializeResult serializeMultipartFormBody(
    std::span<const MultipartSerializedEntry> entries, MultipartSerializedBody& out);

} // namespace Collo::HostFunctions
