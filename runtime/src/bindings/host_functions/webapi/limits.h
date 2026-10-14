// Named maximums for state the Web API bridge keeps for tenant code in a worker's VM: event listeners, message and
// observer queues, the performance timeline, the ports of a MessageEvent and the links of a dependent AbortSignal,
// structured clone traversal, compression output and Blob stream chunks, materialized and cloned bodies, form and URL
// parameter parsing, and the fetch request fields the bridge checks before a request crosses the ABI. Each call site
// decides how an excess fails.

#pragma once

#include <cstddef>

namespace Collo::HostFunctions {

// Active listeners one event target may hold, event handler attributes included; addEventListener beyond it throws a
// QuotaExceededError DOMException (WebApiEventTargetData::appendListener in events/event_target_data.h).
constexpr unsigned WebApiEventTargetListenersMax = 1u << 14;
constexpr unsigned WebApiMessagePortPendingMessagesMax = 1024;
constexpr unsigned WebApiStructuredCloneDepthMax = 512;
constexpr unsigned WebApiStructuredCloneEntriesMax = 100000;
constexpr unsigned WebApiPerformanceObserverPendingEntriesMax = 1024;
// Entries a realm's performance timeline buffers; a new mark or measure past it drops the oldest. The timeline lives
// as long as its realm, across requests, so this bound is memory a long-lived worker keeps (User Timing in a handler
// records per request, far below it).
constexpr unsigned WebApiPerformanceEntriesMax = 1000;
// Ports one MessageEvent may carry when script builds it (the constructor's and initMessageEvent's ports); a message a
// port delivers carries only what its transfer list held, which the structured clone bounds.
constexpr unsigned WebApiMessageEventPortsMax = 1024;
// Signals one dependent AbortSignal may be linked to: AbortSignal.any's inputs, counted with repeats, and the sources a
// dependent input contributes. createDependentAbortSignal (events/abort.cpp) checks each link against the links made
// so far, so the bound keeps that check below a million comparisons; a handler combines two or three signals.
constexpr unsigned WebApiAbortSignalAnySourcesMax = 1024;
// The most output a CompressionStream or DecompressionStream produces before it delivers it: the size of the
// largest chunk its readable side receives, and of the output it holds while it waits for a read.
constexpr size_t WebApiCompressionStreamOutputChunkBytes = 64 * 1024;
// Mirrors MATERIALIZED_BODY_BYTES_MAX in common/limits/http_body.zig, which says what it bounds; no build step
// compares the two.
constexpr size_t WebApiMaterializedBodyBytesMax = 4 * 1024 * 1024;
// The most clones one body's clone tree may make. Branches of a streaming source (a fetch stream, a JavaScript
// stream) buffer separately, so each clone multiplies the bytes one body can hold resident. The count is per tree,
// whatever the source: every tee() counts, of a Blob's or an in-memory body's stream too, as does Response.clone() or
// Request.clone() of a fetch stream or stream body; only the clone of an in-memory body itself, which takes one more
// reference to the same storage, counts nothing. One budget serves the bodies and streams of a tree
// (StreamCloneBudget in host_functions/webapi/streams/readable_stream.h), and the cap sits far above any tee topology
// a handler needs.
constexpr unsigned WebApiBodyCloneFanoutMax = 16;
// The most bytes one chunk carries when a readable stream serves bytes the runtime already holds: Blob.stream(), and
// the buffered byte source of a body stream (streams/stream_common.cpp). A large Blob or body reaches its reader in
// pieces rather than as one copy of the whole.
constexpr size_t WebApiReadableStreamChunkBytes = 64 * 1024;
// Entries one parsed form body may yield, application/x-www-form-urlencoded pairs or multipart/form-data parts. Each
// entry keeps strings or a Blob and a slot, so the count needs a cap beside WebApiMaterializedBodyBytesMax: a body of
// repeated "a&" within that byte cap holds about two million pairs. Both parsers check the cap at each entry they
// parse, so such a body costs at most the cap's worth of entries before it is refused.
constexpr unsigned WebApiFormDataEntriesMax = 1000;
// Header lines the multipart parser decodes in one part, so a part of thousands of tiny header lines costs no more
// than a few real ones.
constexpr unsigned WebApiFormDataPartHeadersMax = 32;
// RFC 2046 section 5.1.1 allows a multipart boundary of 1 to 70 characters, all ASCII, so its characters are its
// bytes. The multipart parser (host_functions/webapi/files/multipart.cpp) applies the bound before it reads a
// boundary's characters.
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
