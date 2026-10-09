// Named maximums for state the Web API bridge keeps for tenant code in a worker's VM: message and observer queues,
// structured clone traversal, text codec stream buffering, materialized and cloned bodies, form and URL parameter
// parsing, and the fetch request fields the bridge checks before a request crosses the ABI. Each call site decides
// how an excess fails. WebApiNavigatorHardwareConcurrencyMax is the exception: it caps a reported value.

#pragma once

#include <cstddef>

namespace Collo::HostFunctions {

constexpr unsigned WebApiMessagePortPendingMessagesMax = 1024;
constexpr unsigned WebApiStructuredCloneDepthMax = 512;
constexpr unsigned WebApiStructuredCloneEntriesMax = 100000;
constexpr unsigned WebApiPerformanceObserverPendingEntriesMax = 1024;
constexpr unsigned WebApiNavigatorHardwareConcurrencyMax = 8;
// Bytes a TextEncoderStream or TextDecoderStream may hold queued on its writable side (input) and on its readable
// side (output). text_codec.cpp also rejects a single chunk whose input or decoded output exceeds them.
constexpr size_t WebApiCodecStreamPendingInputBytesMax = 4 * 1024 * 1024;
constexpr size_t WebApiCodecStreamPendingOutputBytesMax = 4 * 1024 * 1024;
// The byte caps above bill a chunk by its payload, so a write of an empty string or an empty buffer costs nothing,
// yet each one still parks a write request holding a promise, a deferred and a queue slot, hundreds of bytes in all.
// This count bounds that overhead near 1 MiB and stays far above the number of writes a caller legitimately leaves
// unawaited.
constexpr size_t WebApiCodecStreamPendingWritesMax = 4096;
// Mirrors MATERIALIZED_BODY_BYTES_MAX in common/limits/http_body.zig, which says what it bounds; no build step
// compares the two.
constexpr size_t WebApiMaterializedBodyBytesMax = 4 * 1024 * 1024;
// Clones of a streaming body (a fetch stream, or a ReadableStream through tee) buffer separately per branch, so each
// clone multiplies the bytes one body can hold resident. The count covers a body's whole clone tree (BodyCloneBudget
// in host_functions/server/fetch/body.h) and sits far above any tee topology a handler needs. Clones of an in-memory
// body share its storage and are not counted.
constexpr unsigned WebApiBodyCloneFanoutMax = 16;
// Each parsed application/x-www-form-urlencoded pair keeps two strings and an entry slot, so the entry count needs a
// cap of its own: a body of repeated "&a=" within WebApiMaterializedBodyBytesMax would otherwise yield over a million
// pairs. The cap equals FormDataMultipartMaxParts, the multipart parser's cap in
// host_functions/webapi/files/formdata.cpp.
constexpr unsigned WebApiFormDataUrlEncodedEntriesMax = 1000;
// RFC 2046 section 5.1.1 allows a multipart boundary of 1 to 70 characters. host_functions/webapi/files/formdata.cpp
// applies the bound before it converts a boundary to UTF-8.
constexpr size_t WebApiFormDataBoundaryBytesMax = 70;
// A request URL within WebApiFetchRequestUrlBytesMax holds at most half that many pairs, one name byte and one
// separator each, so this cap never rejects the parameters of an accepted request URL. It bounds the metadata of
// about 48 bytes per pair that adversarial input, such as a long init string, would otherwise allocate.
constexpr size_t WebApiUrlSearchParamsPairsMax = 8192;
// The fetch limits below mirror common/ipc/fetch_limits.zig, and the header count mirrors max_request_header_count
// in common/ipc/messages.zig. Nothing generates one side from the other, so a change edits both. The bridge checks
// them to throw the Web API's own error before a request crosses the ABI; Zig checks them again because IPC input
// stays untrusted.
constexpr size_t WebApiFetchRequestPacketBytesMax = 1024 * 1024;
constexpr size_t WebApiFetchRequestStartHeaderBytes = 80;
constexpr size_t WebApiFetchRequestMethodBytesMax = 32;
constexpr size_t WebApiFetchRequestUrlBytesMax = 16 * 1024;
constexpr size_t WebApiFetchRequestHeadersBytesMax = 64 * 1024;
constexpr size_t WebApiFetchRequestBodyInlineBytesMax = WebApiFetchRequestPacketBytesMax
    - WebApiFetchRequestStartHeaderBytes - WebApiFetchRequestMethodBytesMax - WebApiFetchRequestUrlBytesMax
    - WebApiFetchRequestHeadersBytesMax;
// A request body that does not ride inline in the start packet streams through the upload pool, up to this ceiling:
// request_body_pooled_bytes_max in fetch_limits.zig, which also says when a body leaves the packet.
constexpr size_t WebApiFetchRequestBodyPooledBytesMax = 32 * 1024 * 1024;
constexpr size_t WebApiFetchRequestHeaderCountMax = 256;

static_assert(WebApiFetchRequestPacketBytesMax > WebApiFetchRequestStartHeaderBytes);
static_assert(WebApiFetchRequestBodyInlineBytesMax > 0);
static_assert(WebApiFetchRequestBodyPooledBytesMax >= WebApiFetchRequestBodyInlineBytesMax);

} // namespace Collo::HostFunctions
