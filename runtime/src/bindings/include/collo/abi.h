/*
 * The C ABI between the Zig runtime and the C++ engine bridge: plain data
 * types and `collo_` functions, nothing else. Zig implements the
 * `collo_runtime_*` functions, which the bridge calls; the bridge implements
 * the rest. Nothing outside the binary links against it, and the Zig side,
 * `bindings/root.zig`, is not compiled against this header, so a change edits
 * the header, root.zig, both implementations and the layout pins together.
 * Struct sizes and offsets are pinned below with COLLO_STATIC_ASSERT, and
 * root.zig checks its mirrors against the same numbers. The header stays
 * valid C, so no C++ or WebKit type, `bool` or named enum appears in it.
 *
 * The zygote, the workers it forks, and the test and benchmark binaries that
 * create a VM call these functions. The egress gateway calls none of them and
 * uses only some of the struct layouts, through the mirrors in root.zig. A
 * function that takes a ColloVm* or a ColloRealm* runs on the thread that
 * owns the VM unless its comment says otherwise. A function that creates an
 * object takes the ColloRealm* the object belongs to; one that reads or calls
 * an object works in that object's own realm. Input handles are borrowed. An
 * output ColloValue* belongs to the caller, who releases it with
 * collo_value_release(); once
 * collo_vm_destroy() has run, that is the only call still valid for it. An
 * output ColloString or ColloBuffer is caller-owned memory, released with
 * collo_free_buffer(ptr). A function with an out_exception parameter reports a
 * JavaScript exception as COLLO_STATUS_JS_EXCEPTION and stores it there as a
 * new handle; no C++ exception crosses the boundary.
 *
 * A function that operates on a value Zig hands it, rather than creating one,
 * takes the ColloRealm* that serves a value with no realm of its own, such as
 * a primitive: an error it raises for that value belongs to the caller's
 * realm, never to the main realm. An object keeps working in its own realm.
 */
#ifndef COLLO_ABI_H
#define COLLO_ABI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
#define COLLO_STATIC_ASSERT static_assert
#else
#define COLLO_STATIC_ASSERT _Static_assert
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef int32_t ColloStatus;

enum {
    COLLO_STATUS_OK = 0,
    COLLO_STATUS_ERROR = 1,
    COLLO_STATUS_INVALID_ARGUMENT = 2,
    COLLO_STATUS_JS_EXCEPTION = 3,
    COLLO_STATUS_UNSUPPORTED = 4,
    COLLO_STATUS_OUT_OF_MEMORY = 5,
    /* The VM already holds a module pack (collo_module_register_pack). */
    COLLO_STATUS_ALREADY_EXISTS = 6,
    COLLO_STATUS_RESPONSE_BODY_TOO_LARGE = 7,
    COLLO_STATUS_RESPONSE_HEADER_COUNT_TOO_LARGE = 8,
    COLLO_STATUS_RESPONSE_HEADER_BYTES_TOO_LARGE = 9,
    /* Module evaluation reached top-level await: the evaluation promise is
       parked and collo_runtime_module_eval_settled reports its settlement. */
    COLLO_STATUS_PENDING = 10,
};

enum {
    /* The largest module pack: `max_pack_bytes` in common/ipc/module_pack.zig,
       which C cannot read, so the two are kept equal by hand and
       runtime/tests/contracts/abi.zig checks root.zig's mirror against it. */
    COLLO_MODULE_PACK_MAX_BYTES = 16 * 1024 * 1024,
    /* The most modules one pack holds: `max_module_count` in
       common/ipc/module_pack.zig, kept equal and checked the same way. The
       bridge refuses a pack that claims more. */
    COLLO_MODULE_PACK_MAX_MODULES = 4096,
};

/* The owners a worker's VM can hold tokens for at once, and the request ids
   they use. The first two equal `worker_concurrency_max` and
   `routes_per_definition_max` in common/limits/server.zig, and root.zig checks
   the values derived from them at compile time. */
enum {
    COLLO_WORKER_CONCURRENCY_MAX = 16,
    COLLO_ROUTES_PER_DEFINITION_MAX = 64,
    /* The microtask owner table: every request a worker runs at once, at most
       one module evaluation per route (routes that share a module instance
       share one), and the worker owner, which owns the JavaScript no request
       or evaluation owns. */
    COLLO_OWNER_SLOT_COUNT = COLLO_WORKER_CONCURRENCY_MAX + COLLO_ROUTES_PER_DEFINITION_MAX + 1,
};

/* The largest id a dispatched request carries. The ids above it name the
   owners that are not requests: one per module evaluation and, at UINT64_MAX,
   the worker owner. The console charges them no per-request budget. */
#define COLLO_REQUEST_ID_MAX (UINT64_MAX - COLLO_ROUTES_PER_DEFINITION_MAX - 1)

/* The flags of collo_vm_create. */
enum {
    /* Creates the VM without the Web API globals. */
    COLLO_VM_CREATE_DISABLE_WEB_APIS = 1u << 0,
};

typedef struct ColloVm ColloVm;
/* One global object of a VM with its own globals, intrinsics and module
   registry. The VM owns every realm until collo_vm_destroy, so a realm pointer
   stays valid as long as its VM. */
typedef struct ColloRealm ColloRealm;
typedef struct ColloValue ColloValue;
typedef struct ColloPromiseDeferred ColloPromiseDeferred;
typedef struct ColloOwnedByteSegments ColloOwnedByteSegments;
typedef struct ColloOwnedHeaderBlock ColloOwnedHeaderBlock;
typedef struct ColloResponseBodyStream ColloResponseBodyStream;

typedef struct {
    const uint8_t* ptr;
    size_t len;
} ColloString;

typedef struct {
    const uint8_t* ptr;
    size_t len;
} ColloBuffer;

/* A read-only private mapping Zig made of a sealed memfd, so its bytes cannot
   change while it exists. Exactly one side owns it at a time, and the owner
   ends it with one collo_runtime_mapping_release. */
typedef struct ColloMapping {
    const uint8_t* ptr;
    size_t len;
} ColloMapping;

typedef struct ColloNameValuePair {
    ColloString name;
    ColloString value;
} ColloNameValuePair;

/* The input of collo_runtime_fetch, with request_id first and no implicit
   padding. */
typedef struct ColloFetchInit {
    uint64_t request_id;
    ColloString url;
    ColloString method;
    ColloBuffer body;
    const ColloNameValuePair* headers;
    size_t headers_len;
    /* bits 0..1: redirect mode (0 follow, 1 error, 2 manual). */
    uint32_t flags;
    uint32_t reserved0;
} ColloFetchInit;

typedef uint8_t ColloTerminationReason;

enum {
    COLLO_TERMINATION_NONE = 0,
    COLLO_TERMINATION_CPU = 1,
    COLLO_TERMINATION_MEMORY = 2,
    COLLO_TERMINATION_CRASH = 3,
    COLLO_TERMINATION_INIT_FAILED = 4,
    COLLO_TERMINATION_DEADLINE = 5,
};

/* The execution context of one owner of JavaScript: a request, a module
   evaluation or the worker itself. The bridge reads only its identity and
   uses its address as the owner's key; it keeps no clock, so the CPU an owner
   spends is counted in Zig, at the turn boundaries and the owner transition
   hook. Everything else about the owner lives in the Zig struct that holds
   this one. */
typedef struct ColloExecCtx {
    /* The owner's id: a dispatched request's, never changed, or one above
       COLLO_REQUEST_ID_MAX. Host calls report it to the collo_runtime_*
       functions, and the console and collo_webapi_cleanup_request key the
       state the owner creates by it. */
    uint64_t request_id;

    /* The owner's absolute CLOCK_MONOTONIC deadline in ns, or 0 for none.
       The worker's sentinel enforces it; the bridge does not read it. */
    uint64_t deadline_monotonic_ns;

    /* Why the request ended, a ColloTerminationReason; NONE while it runs.
       Zig decides and writes it before worker-fatal cleanup; the bridge does
       not read it. */
    uint8_t termination_reason;

    uint8_t reserved0[7];
} ColloExecCtx;

/* The seeds collo_vm_reseed_after_fork gives a forked VM, so a worker's random
   state differs from the zygote's. */
typedef struct ColloRandomSeeds {
    /* Seed for JSC weak random generation. */
    uint32_t weak_random_seed;
    /* Seed for VM-level random state. */
    uint32_t vm_random_seed;
    /* Seed for heap randomization state. */
    uint32_t heap_random_seed;
} ColloRandomSeeds;

/* Names a request task. slot and generation come first because they key the
   worker's request task table; request_id and request_generation confirm the
   task still belongs to the same request. */
typedef struct ColloRequestCompletionToken {
    uint32_t slot;
    uint32_t generation;
    uint64_t request_id;
    uint64_t request_generation;
} ColloRequestCompletionToken;

typedef struct ColloRequestIdentity {
    uint64_t request_id;
    uint64_t request_generation;
} ColloRequestIdentity;

/* The input of collo_request_new, which builds the Request a handler receives.
   Every pointer is borrowed for the call: the bridge copies each string and
   array into the Request. authority is the request's normalized authority,
   the lowercased host or bracketed IPv6 literal followed by :port unless the
   port is 443, and must not be empty; request.url is
   https://<authority><path>, with ?<raw_query> when the query is not empty. */
typedef struct ColloRequestInit {
    ColloString method;
    ColloString path;
    ColloString raw_query;
    ColloString authority;
    const ColloNameValuePair* headers;
    size_t headers_len;
    const ColloNameValuePair* params;
    size_t params_len;
    ColloRequestIdentity identity;
} ColloRequestInit;

typedef struct ColloResponseInit {
    ColloBuffer body;
    ColloString status_text;
    ColloString url;
    const ColloNameValuePair* headers;
    size_t headers_len;
    uint16_t status;
    uint16_t flags;
    uint32_t reserved1;
} ColloResponseInit;

enum {
    COLLO_RESPONSE_INIT_FLAG_REDIRECTED = 1u << 0,
};

typedef struct ColloFetchBodyIdentity {
    uint64_t request_id;
    uint64_t request_generation;
    uint64_t fetch_id;
    uint64_t body_id;
} ColloFetchBodyIdentity;

typedef uint8_t ColloFetchBodyConsumeKind;

enum {
    COLLO_FETCH_BODY_CONSUME_TEXT = 0,
    COLLO_FETCH_BODY_CONSUME_JSON = 1,
    COLLO_FETCH_BODY_CONSUME_ARRAY_BUFFER = 2,
    COLLO_FETCH_BODY_CONSUME_BYTES = 3,
    COLLO_FETCH_BODY_CONSUME_BLOB = 4,
    COLLO_FETCH_BODY_CONSUME_FORM_DATA = 5,
};

typedef struct ColloFetchBodyConsumeInit {
    ColloFetchBodyIdentity identity;
    ColloString content_type;
    ColloFetchBodyConsumeKind kind;
    uint8_t reserved[7];
} ColloFetchBodyConsumeInit;

typedef struct ColloFetchResponseInit {
    ColloResponseInit response;
    ColloFetchBodyIdentity body_identity;
} ColloFetchResponseInit;

enum {
    COLLO_EXTRACTED_RESPONSE_BODY_EMPTY = 0,
    COLLO_EXTRACTED_RESPONSE_BODY_BYTES = 1,
    COLLO_EXTRACTED_RESPONSE_BODY_BYTE_SEGMENTS = 2,
    COLLO_EXTRACTED_RESPONSE_BODY_FETCH_STREAM = 3,
    COLLO_EXTRACTED_RESPONSE_BODY_READABLE_STREAM = 4,
};

typedef struct ColloByteSegment {
    ColloBuffer bytes;
} ColloByteSegment;

typedef struct ColloExtractedResponseBody {
    uint32_t kind;
    uint32_t reserved0;
    size_t total_len;
    const ColloByteSegment* segments;
    size_t segments_len;
    ColloOwnedByteSegments* owner;
    ColloFetchBodyIdentity stream_identity;
    /* For COLLO_EXTRACTED_RESPONSE_BODY_READABLE_STREAM: the Response's
       ReadableStream, locked for the embedder, which reads it through the
       collo_response_body_stream_* functions. Owned like `owner`. */
    ColloResponseBodyStream* body_stream;
} ColloExtractedResponseBody;

typedef struct ColloHeaderView {
    uint32_t name_offset;
    uint32_t name_len;
    uint32_t value_offset;
    uint32_t value_len;
} ColloHeaderView;

typedef struct ColloExtractedHeaderBlock {
    ColloBuffer storage;
    const ColloHeaderView* headers;
    size_t headers_len;
    ColloOwnedHeaderBlock* owner;
} ColloExtractedHeaderBlock;

/* Owned as one extracted-response object. body.owner and headers.owner are
   released only by collo_response_extract_free() unless the embedder takes
   ownership and nulls the corresponding owner pointer. If body.kind is
   COLLO_EXTRACTED_RESPONSE_BODY_FETCH_STREAM, body.stream_identity is
   transferred to the caller and is not released by collo_response_extract_free();
   body.body_stream is released by it unless the embedder takes it and nulls
   the pointer. */
typedef struct ColloExtractedResponse {
    ColloExtractedResponseBody body;
    ColloExtractedHeaderBlock headers;
    uint16_t status;
    uint16_t reserved0;
    uint32_t reserved1;
} ColloExtractedResponse;

typedef struct ColloResponseExtractLimits {
    size_t max_body_bytes;
    size_t max_header_count;
    size_t max_header_bytes;
} ColloResponseExtractLimits;

/* What one read of a ColloResponseBodyStream returned. */
typedef uint32_t ColloResponseBodyStreamResult;
enum {
    COLLO_RESPONSE_BODY_STREAM_RESULT_CHUNK = 0,
    COLLO_RESPONSE_BODY_STREAM_RESULT_DONE = 1,
    COLLO_RESPONSE_BODY_STREAM_RESULT_ERROR = 2,
};

/* The reason collo_response_body_stream_cancel gives the stream, built in its
   realm: an AbortError for a client's reset or a response that ended early, a
   TypeError for a chunk that is not bytes. */
typedef uint32_t ColloResponseBodyStreamCancel;
enum {
    COLLO_RESPONSE_BODY_STREAM_CANCEL_CLIENT_RESET = 0,
    COLLO_RESPONSE_BODY_STREAM_CANCEL_RESPONSE_FAILED = 1,
    COLLO_RESPONSE_BODY_STREAM_CANCEL_INVALID_CHUNK = 2,
};

/* What the engine measures its memory against, from collo_memory_status. */
typedef struct ColloMemoryStatus {
    /* Bytes in use: the decimal the memory status override's descriptor
       holds, or the engine's own resident-size reading without an override. */
    uint64_t footprint_bytes;
    /* footprint_bytes over the override's limit, or over the engine's own
       figure for available memory, capped at 1 and scaled to parts per
       million, rounded to the nearest. */
    uint32_t in_use_per_million;
    uint32_t reserved0;
} ColloMemoryStatus;

/* The VM's heap, from collo_vm_heap_stats. */
typedef struct ColloHeapStats {
    /* JSC's Heap::size(): the bytes of the cells the last collection marked,
       plus extra_memory_bytes. A cell allocated since that collection counts
       only once a later collection marks it, so between collections this
       trails the heap's real size. */
    uint64_t size_bytes;
    /* JSC's Heap::extraMemorySize(): memory outside the heap that cells
       report as theirs, ArrayBuffer contents included. */
    uint64_t extra_memory_bytes;
} ColloHeapStats;

COLLO_STATIC_ASSERT(sizeof(ColloMapping) == 16, "ColloMapping ABI size mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloMapping, ptr) == 0, "ColloMapping.ptr offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloMapping, len) == 8, "ColloMapping.len offset mismatch");

COLLO_STATIC_ASSERT(COLLO_OWNER_SLOT_COUNT == 81, "COLLO_OWNER_SLOT_COUNT mismatch");
COLLO_STATIC_ASSERT(COLLO_REQUEST_ID_MAX == UINT64_MAX - 65, "COLLO_REQUEST_ID_MAX mismatch");

COLLO_STATIC_ASSERT(sizeof(ColloExecCtx) == 24, "ColloExecCtx ABI size mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloExecCtx, request_id) == 0, "ColloExecCtx.request_id offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloExecCtx, deadline_monotonic_ns) == 8, "ColloExecCtx.deadline_monotonic_ns offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloExecCtx, termination_reason) == 16, "ColloExecCtx.termination_reason offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloExecCtx, reserved0) == 17, "ColloExecCtx.reserved0 offset mismatch");

COLLO_STATIC_ASSERT(sizeof(ColloFetchInit) == 80, "ColloFetchInit ABI size mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloFetchInit, request_id) == 0, "ColloFetchInit.request_id offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloFetchInit, url) == 8, "ColloFetchInit.url offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloFetchInit, method) == 24, "ColloFetchInit.method offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloFetchInit, body) == 40, "ColloFetchInit.body offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloFetchInit, headers) == 56, "ColloFetchInit.headers offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloFetchInit, headers_len) == 64, "ColloFetchInit.headers_len offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloFetchInit, flags) == 72, "ColloFetchInit.flags offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloFetchInit, reserved0) == 76, "ColloFetchInit.reserved0 offset mismatch");

COLLO_STATIC_ASSERT(sizeof(ColloRandomSeeds) == 12, "ColloRandomSeeds ABI size mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloRandomSeeds, weak_random_seed) == 0, "ColloRandomSeeds.weak_random_seed offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloRandomSeeds, vm_random_seed) == 4, "ColloRandomSeeds.vm_random_seed offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloRandomSeeds, heap_random_seed) == 8, "ColloRandomSeeds.heap_random_seed offset mismatch");

COLLO_STATIC_ASSERT(sizeof(ColloRequestCompletionToken) == 24, "ColloRequestCompletionToken ABI size mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloRequestCompletionToken, slot) == 0, "ColloRequestCompletionToken.slot offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloRequestCompletionToken, generation) == 4, "ColloRequestCompletionToken.generation offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloRequestCompletionToken, request_id) == 8, "ColloRequestCompletionToken.request_id offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloRequestCompletionToken, request_generation) == 16,
    "ColloRequestCompletionToken.request_generation offset mismatch");

COLLO_STATIC_ASSERT(sizeof(ColloRequestIdentity) == 16, "ColloRequestIdentity ABI size mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloRequestIdentity, request_id) == 0, "ColloRequestIdentity.request_id offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloRequestIdentity, request_generation) == 8, "ColloRequestIdentity.request_generation offset mismatch");

COLLO_STATIC_ASSERT(sizeof(ColloRequestInit) == 112, "ColloRequestInit ABI size mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloRequestInit, method) == 0, "ColloRequestInit.method offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloRequestInit, path) == 16, "ColloRequestInit.path offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloRequestInit, raw_query) == 32, "ColloRequestInit.raw_query offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloRequestInit, authority) == 48, "ColloRequestInit.authority offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloRequestInit, headers) == 64, "ColloRequestInit.headers offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloRequestInit, headers_len) == 72, "ColloRequestInit.headers_len offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloRequestInit, params) == 80, "ColloRequestInit.params offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloRequestInit, params_len) == 88, "ColloRequestInit.params_len offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloRequestInit, identity) == 96, "ColloRequestInit.identity offset mismatch");

COLLO_STATIC_ASSERT(sizeof(ColloResponseInit) == 72, "ColloResponseInit ABI size mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloResponseInit, body) == 0, "ColloResponseInit.body offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloResponseInit, status_text) == 16, "ColloResponseInit.status_text offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloResponseInit, url) == 32, "ColloResponseInit.url offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloResponseInit, headers) == 48, "ColloResponseInit.headers offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloResponseInit, headers_len) == 56, "ColloResponseInit.headers_len offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloResponseInit, status) == 64, "ColloResponseInit.status offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloResponseInit, flags) == 66, "ColloResponseInit.flags offset mismatch");

COLLO_STATIC_ASSERT(sizeof(ColloFetchBodyIdentity) == 32, "ColloFetchBodyIdentity ABI size mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloFetchBodyIdentity, request_id) == 0, "ColloFetchBodyIdentity.request_id offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloFetchBodyIdentity, request_generation) == 8,
    "ColloFetchBodyIdentity.request_generation offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloFetchBodyIdentity, fetch_id) == 16, "ColloFetchBodyIdentity.fetch_id offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloFetchBodyIdentity, body_id) == 24, "ColloFetchBodyIdentity.body_id offset mismatch");

COLLO_STATIC_ASSERT(sizeof(ColloFetchBodyConsumeInit) == 56, "ColloFetchBodyConsumeInit ABI size mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloFetchBodyConsumeInit, identity) == 0, "ColloFetchBodyConsumeInit.identity offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloFetchBodyConsumeInit, content_type) == 32, "ColloFetchBodyConsumeInit.content_type offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloFetchBodyConsumeInit, kind) == 48, "ColloFetchBodyConsumeInit.kind offset mismatch");

COLLO_STATIC_ASSERT(sizeof(ColloFetchResponseInit) == 104, "ColloFetchResponseInit ABI size mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloFetchResponseInit, response) == 0, "ColloFetchResponseInit.response offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloFetchResponseInit, body_identity) == 72, "ColloFetchResponseInit.body_identity offset mismatch");

COLLO_STATIC_ASSERT(sizeof(ColloByteSegment) == 16, "ColloByteSegment ABI size mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloByteSegment, bytes) == 0, "ColloByteSegment.bytes offset mismatch");

COLLO_STATIC_ASSERT(sizeof(ColloExtractedResponseBody) == 80, "ColloExtractedResponseBody ABI size mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloExtractedResponseBody, kind) == 0, "ColloExtractedResponseBody.kind offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloExtractedResponseBody, reserved0) == 4, "ColloExtractedResponseBody.reserved0 offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloExtractedResponseBody, total_len) == 8, "ColloExtractedResponseBody.total_len offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloExtractedResponseBody, segments) == 16, "ColloExtractedResponseBody.segments offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloExtractedResponseBody, segments_len) == 24,
    "ColloExtractedResponseBody.segments_len offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloExtractedResponseBody, owner) == 32, "ColloExtractedResponseBody.owner offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloExtractedResponseBody, stream_identity) == 40,
    "ColloExtractedResponseBody.stream_identity offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloExtractedResponseBody, body_stream) == 72, "ColloExtractedResponseBody.body_stream offset mismatch");

COLLO_STATIC_ASSERT(sizeof(ColloHeaderView) == 16, "ColloHeaderView ABI size mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloHeaderView, name_offset) == 0, "ColloHeaderView.name_offset offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloHeaderView, name_len) == 4, "ColloHeaderView.name_len offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloHeaderView, value_offset) == 8, "ColloHeaderView.value_offset offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloHeaderView, value_len) == 12, "ColloHeaderView.value_len offset mismatch");

COLLO_STATIC_ASSERT(sizeof(ColloExtractedHeaderBlock) == 40, "ColloExtractedHeaderBlock ABI size mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloExtractedHeaderBlock, storage) == 0, "ColloExtractedHeaderBlock.storage offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloExtractedHeaderBlock, headers) == 16, "ColloExtractedHeaderBlock.headers offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloExtractedHeaderBlock, headers_len) == 24, "ColloExtractedHeaderBlock.headers_len offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloExtractedHeaderBlock, owner) == 32, "ColloExtractedHeaderBlock.owner offset mismatch");

COLLO_STATIC_ASSERT(sizeof(ColloExtractedResponse) == 128, "ColloExtractedResponse ABI size mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloExtractedResponse, body) == 0, "ColloExtractedResponse.body offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloExtractedResponse, headers) == 80, "ColloExtractedResponse.headers offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloExtractedResponse, status) == 120, "ColloExtractedResponse.status offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloExtractedResponse, reserved0) == 122, "ColloExtractedResponse.reserved0 offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloExtractedResponse, reserved1) == 124, "ColloExtractedResponse.reserved1 offset mismatch");

COLLO_STATIC_ASSERT(sizeof(ColloResponseExtractLimits) == 24, "ColloResponseExtractLimits ABI size mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloResponseExtractLimits, max_body_bytes) == 0,
    "ColloResponseExtractLimits.max_body_bytes offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloResponseExtractLimits, max_header_count) == 8,
    "ColloResponseExtractLimits.max_header_count offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloResponseExtractLimits, max_header_bytes) == 16,
    "ColloResponseExtractLimits.max_header_bytes offset mismatch");

COLLO_STATIC_ASSERT(sizeof(ColloMemoryStatus) == 16, "ColloMemoryStatus ABI size mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloMemoryStatus, footprint_bytes) == 0, "ColloMemoryStatus.footprint_bytes offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloMemoryStatus, in_use_per_million) == 8, "ColloMemoryStatus.in_use_per_million offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloMemoryStatus, reserved0) == 12, "ColloMemoryStatus.reserved0 offset mismatch");

COLLO_STATIC_ASSERT(sizeof(ColloHeapStats) == 16, "ColloHeapStats ABI size mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloHeapStats, size_bytes) == 0, "ColloHeapStats.size_bytes offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloHeapStats, extra_memory_bytes) == 8, "ColloHeapStats.extra_memory_bytes offset mismatch");

#undef COLLO_STATIC_ASSERT

/* Ends a mapping Zig handed to the bridge; the bridge calls it exactly once per
   mapping it was given. A module pack's mapping ends when the registration and
   the last module source string over it are gone, so this runs on whichever
   thread drops the last of them, not necessarily the VM thread, and possibly
   while the JSC API lock or a bridge mutex is held; it must not call into the
   bridge. A mapping with a null ptr maps nothing and is ignored. */
void collo_runtime_mapping_release(ColloMapping mapping);
/* If value is non-null, runtime consumes it on every call, including non-OK. */
ColloStatus collo_runtime_complete_request_task(void* runtime, uint32_t slot, uint32_t generation, uint64_t request_id,
    uint64_t request_generation, ColloValue* value, uint8_t is_error);
/* Reports the outcome of one read collo_response_body_stream_read started for
   request `request_id`: CHUNK with the read's value, DONE with none, ERROR
   with the rejection reason, or with none when no handle could be made. The
   bridge calls it on the VM thread from a microtask the read registered,
   under that request's owner. `value` is consumed on every call. */
void collo_runtime_response_body_stream_settled(
    void* runtime, uint64_t request_id, ColloResponseBodyStreamResult result, ColloValue* value);
/* Settlement of a module evaluation previously returned as
   COLLO_STATUS_PENDING, called on the VM thread from inside a microtask
   drain. realm_index is the evaluating realm's (collo_realm_index), since one
   specifier evaluates once per realm. specifier is valid only for the
   duration of the call; the runtime copies what it needs and only enqueues,
   so no JS runs. */
void collo_runtime_module_eval_settled(void* runtime, uint32_t realm_index, ColloString specifier, uint8_t resolved);
/* How long native work the bridge cannot interrupt may still keep the VM
   thread, in nanoseconds: the least of every live owner's time to its wall
   deadline and, when the owner whose window is open has a CPU budget, the CPU
   it has left (worker/runtime/owner.zig:nativeTimeLeftNs). UINT64_MAX when
   nothing limits the thread, 0 once a limit is spent. WebCrypto asks it
   before and while it works (bindings/host_functions/webapi/crypto/budget.h).
   VM thread only; runs no JavaScript. */
uint64_t collo_runtime_native_time_left_ns(void* runtime);
/* If deferred is non-null, Zig owns once passed, including non-OK. On OK,
   *out_fetch_id names the fetch for collo_runtime_fetch_cancel, or is 0 when
   Zig refused the fetch and rejected its promise during the call. That promise
   is already settled and nothing is left to cancel, so the caller wires no
   abort signal to it. */
ColloStatus collo_runtime_fetch(
    void* runtime, const ColloFetchInit* init, ColloPromiseDeferred* deferred, uint64_t* out_fetch_id);
/* If reason is non-null, runtime consumes it on every call. */
void collo_runtime_fetch_cancel(void* runtime, uint64_t fetch_id, ColloValue* reason);
/* Fetch response body adapters below: Zig owns deferred once passed, including non-OK. */
ColloStatus collo_runtime_fetch_body_consume(
    void* runtime, const ColloFetchBodyConsumeInit* init, ColloPromiseDeferred* deferred, uint64_t* out_task_id);
ColloStatus collo_runtime_fetch_body_pull(
    void* runtime, const ColloFetchBodyIdentity* identity, ColloPromiseDeferred* deferred, uint64_t* out_task_id);
/* On OK, out_body is borrowed from runtime-owned body storage. The caller must
   not free it, and it is valid only until the body is mutated/released or the
   current request turn exits. */
ColloStatus collo_runtime_fetch_body_borrow(
    void* runtime, const ColloFetchBodyIdentity* identity, ColloBuffer* out_body);
ColloStatus collo_runtime_fetch_body_clone(
    void* runtime, const ColloFetchBodyIdentity* identity, ColloFetchBodyIdentity* out_identity);
void collo_runtime_fetch_body_cancel(void* runtime, const ColloFetchBodyIdentity* identity);
void collo_runtime_fetch_body_release(void* runtime, const ColloFetchBodyIdentity* identity);
/* Request body adapters below: Zig owns deferred once passed, including non-OK. */
ColloStatus collo_runtime_request_text(void* runtime, uint64_t request_id, uint64_t request_generation,
    ColloPromiseDeferred* deferred, uint64_t* out_task_id);
ColloStatus collo_runtime_request_json(void* runtime, uint64_t request_id, uint64_t request_generation,
    ColloPromiseDeferred* deferred, uint64_t* out_task_id);
ColloStatus collo_runtime_request_array_buffer(void* runtime, uint64_t request_id, uint64_t request_generation,
    ColloPromiseDeferred* deferred, uint64_t* out_task_id);
ColloStatus collo_runtime_request_bytes(void* runtime, uint64_t request_id, uint64_t request_generation,
    ColloPromiseDeferred* deferred, uint64_t* out_task_id);
ColloStatus collo_runtime_request_blob(void* runtime, uint64_t request_id, uint64_t request_generation,
    ColloString type, ColloPromiseDeferred* deferred, uint64_t* out_task_id);
ColloStatus collo_runtime_request_form_data(void* runtime, uint64_t request_id, uint64_t request_generation,
    ColloString content_type, ColloPromiseDeferred* deferred, uint64_t* out_task_id);
/* Runtime consumes callback, this_arg, and each args[i] handle on every call,
   including non-OK. this_arg is the callback's receiver: the globalThis of
   the realm whose setTimeout or setInterval scheduled it. The args array
   storage itself is borrowed. */
ColloStatus collo_runtime_set_timer(void* runtime, uint64_t request_id, ColloValue* callback, ColloValue* this_arg,
    ColloValue** args, size_t args_len, uint32_t delay_ms, uint8_t repeats, uint64_t* out_timer_id);
ColloStatus collo_runtime_clear_timeout(void* runtime, uint64_t request_id, uint64_t timer_id);
/* Runtime consumes callback, this_arg, and each args[i] handle on every call,
   including non-OK. this_arg is the callback's receiver: the globalThis of
   the realm whose setImmediate scheduled it, as for timers. The args array
   storage itself is borrowed. */
ColloStatus collo_runtime_set_immediate(void* runtime, uint64_t request_id, ColloValue* callback, ColloValue* this_arg,
    ColloValue** args, size_t args_len, uint64_t* out_immediate_id);
ColloStatus collo_runtime_clear_immediate(void* runtime, uint64_t request_id, uint64_t immediate_id);

/* Builds a handler's Request in `realm` from init (see ColloRequestInit). A
   VM that is not ready, a zero request id, an empty authority, or a nonzero
   length or count with a null pointer fails with
   COLLO_STATUS_INVALID_ARGUMENT. On success *out_value is a new handle the
   caller releases with collo_value_release. */
ColloStatus collo_request_new(
    ColloRealm* realm, const ColloRequestInit* init, ColloValue** out_value, ColloValue** out_exception);
ColloStatus collo_response_new(
    ColloRealm* realm, const ColloResponseInit* init, ColloValue** out_value, ColloValue** out_exception);
ColloStatus collo_fetch_response_new(
    ColloRealm* realm, const ColloFetchResponseInit* init, ColloValue** out_value, ColloValue** out_exception);
/* Converts a handler's result into a native response within `limits`: a
   Response object as it is, any other value as a 200 whose body is its string
   conversion. The conversion and its errors run in `realm` for a value with no
   realm of its own. */
ColloStatus collo_response_extract(ColloRealm* realm, const ColloValue* value, const ColloResponseExtractLimits* limits,
    ColloExtractedResponse* out_response, ColloValue** out_exception);
void collo_response_extract_free(ColloExtractedResponse* response);
/* Starts one read of `stream` for request `request_id`; its result reaches
   collo_runtime_response_body_stream_settled. The first call fixes the
   request, and a later call naming another fails with
   COLLO_STATUS_INVALID_ARGUMENT. Runs the stream's pull, so the caller is
   inside a turn of that request. One read at a time: the caller waits for a
   read's result before it starts the next. */
ColloStatus collo_response_body_stream_read(
    ColloResponseBodyStream* stream, uint64_t request_id, ColloValue** out_exception);
/* The bytes of `chunk`, a value a read of `stream` returned: an ArrayBuffer or
   ArrayBufferView, lent in place until the next call into the VM. Any other
   value, a string included, or a detached or out-of-bounds buffer, fails with
   COLLO_STATUS_JS_EXCEPTION and a TypeError, as the Fetch Standard requires of
   a response body's chunks. `out_bytes` is cleared on entry. */
ColloStatus collo_response_body_stream_chunk(
    ColloResponseBodyStream* stream, const ColloValue* chunk, ColloBuffer* out_bytes, ColloValue** out_exception);
/* Cancels `stream` with the reason `reason` names. Runs the stream's cancel
   algorithm, so the caller is inside a turn of the request that reads it. */
ColloStatus collo_response_body_stream_cancel(
    ColloResponseBodyStream* stream, ColloResponseBodyStreamCancel reason, ColloValue** out_exception);
/* Frees `stream`; safe on any thread and after collo_vm_destroy. */
void collo_response_body_stream_destroy(ColloResponseBodyStream* stream);
void collo_owned_byte_segments_destroy(ColloOwnedByteSegments* owner);
void collo_owned_header_block_destroy(ColloOwnedHeaderBlock* owner);
/* Releases the Web API state request_id owns in the VM: its console budget. */
ColloStatus collo_webapi_cleanup_request(ColloVm* vm, uint64_t request_id);

/* The largest kernel page size the engine runs on: the page size JSC and
   libpas fixed their block, page and granule sizes for when they were
   compiled. A kernel runs the engine only when its page size divides this
   value. Reads a constant and touches no engine state, so any process may call
   it, from any thread, before or without a VM. */
uint64_t collo_engine_page_size_ceiling(void);
/* Creates a fully initialized VM in *out_vm, which the caller owns until
   collo_vm_destroy, with its main realm and its deferred-work wakeup gate.
   `flags` holds COLLO_VM_CREATE_* bits; any other bit fails with
   COLLO_STATUS_UNSUPPORTED, and so does a kernel whose page size does not
   divide collo_engine_page_size_ceiling(), before the engine initializes. */
ColloStatus collo_vm_create(uint32_t flags, ColloVm** out_vm);
/* The realm created with the VM, or null when the VM is not ready. */
ColloRealm* collo_vm_main_realm(ColloVm* vm);
/* Adds a realm to the VM and stores it in *out_realm. The new global gets
   every install the VM made so far: the Web APIs unless the VM was created
   without them, `process`, node:fs, the console client while a sink is
   registered, and a Math.random seed derived from the worker's
   (collo_vm_reseed_after_fork). Realms share the VM's heap, turns, microtask
   queue, module sources and limits: they separate state, not trust. Outside
   any turn; a VM that is not ready or inside a turn fails with
   COLLO_STATUS_INVALID_ARGUMENT, and one a termination stopped with
   COLLO_STATUS_ERROR. */
ColloStatus collo_realm_create(ColloVm* vm, ColloRealm** out_realm);
/* The realm's position in its VM's creation order, 0 for the main realm. */
uint32_t collo_realm_index(const ColloRealm* realm);
/* Invalidates outstanding handles. The caller must serialize destroy against
   every API call that takes this ColloVm*. Calling this while a turn is active
   aborts the process because the VM is already in an unrecoverable teardown
   state. After destroy begins, only collo_value_release() remains valid for
   previously returned ColloValue* handles. */
void collo_vm_destroy(ColloVm* vm);
ColloStatus collo_vm_prepare_for_fork(ColloVm* vm);
ColloStatus collo_vm_post_fork_child(ColloVm* vm);
/* Gives the VM the worker's own random state. The main realm's Math.random
   takes seeds->weak_random_seed as it is, and every other realm, existing or
   created later, a seed derived from it and the realm's index, so neither
   sibling workers nor two realms of one worker share a sequence. */
ColloStatus collo_vm_reseed_after_fork(ColloVm* vm, const ColloRandomSeeds* seeds);
/* Forces every compiler thread the process will use, for the JS tiers and
   wasm, to exist now, without compiling anything. Each thread polls once, finds
   an empty queue and parks. Workers call this after the sandbox's privilege
   drop (no-new-privileges and the capability drop) and before seccomp: a
   worklist thread is otherwise created by the first enqueue, which under
   seccomp is a denied clone that aborts the process. Pin the helper-thread
   timeout override first, or a thread may retire between this call and the
   filter, and a retired thread cannot come back once clone is denied.
   Idempotent. */
ColloStatus collo_vm_prespawn_compiler_threads(ColloVm* vm);
ColloStatus collo_vm_collect_full_gc_and_trim(ColloVm* vm);
/* Runs a synchronous young-generation (Eden) collection and sweeps it, outside
   any turn. Cells that survived an earlier collection are traced again only
   when a write barrier remembered them, so a cell that gained an edge to a new
   cell without the barrier loses that cell here. */
ColloStatus collo_vm_collect_eden_gc(ColloVm* vm);
/* Reads the heap's size and the extra memory its cells report into *out,
   which is cleared on entry. Inside or outside a turn. */
ColloStatus collo_vm_heap_stats(ColloVm* vm, ColloHeapStats* out);
/* Cross-thread cooperative termination trap. The caller must keep the ColloVm
   object alive. If VM destroy has begun, this returns invalid argument. */
ColloStatus collo_vm_request_termination(ColloVm* vm);
ColloStatus collo_vm_set_host_runtime(ColloVm* vm, void* runtime);
/* Owners. JavaScript running on a VM belongs to one ColloExecCtx or to none:
   the context the outermost turn installed, or the one a restored continuation
   installed for its duration (below); else, outside every turn and every
   restored continuation, the turnless context; else none. Host calls report
   that owner's request_id to the collo_runtime_* functions and fail without
   one, the console stamps its lines with it, and a promise reaction records
   it, as a token, when it is registered.

   A reaction runs under the owner that registered it, not under the turn that
   settles its promise: the drain restores the recorded owner around it, and
   around the work it enqueues in turn. The record is a token, never the
   pointer, because a reaction can outlive its owner, as when one request
   awaits a module-scope promise and the next settles it; a token whose owner
   was released restores no owner. */

/* Installs `exec_ctx` as the turnless context, the owner of JavaScript that
   runs outside every turn and every restored continuation: module evaluation
   and the microtask drains inside it. A reaction such code registers records
   this context, so it runs under it whoever settles its promise later. NULL
   uninstalls. The pointer is borrowed until collo_vm_release_exec_ctx
   releases it: replacing or uninstalling it does not end the borrow, since a
   reaction its code registered holds a token that resolves to this pointer
   and installs it when the reaction runs. Inside a turn the call is allowed
   but has no effect until the turn ends. A VM that is not ready fails with
   COLLO_STATUS_INVALID_ARGUMENT. */
ColloStatus collo_vm_set_turnless_exec_ctx(ColloVm* vm, ColloExecCtx* exec_ctx);
/* Required before the ColloExecCtx storage dies: frees its token and
   uninstalls it where it is the current or the turnless context. Every
   reaction still carrying the token then runs with no owner instead of
   reading freed memory. Call it outside JavaScript, between turns: a call
   while a restored continuation runs ends the process, since the
   continuation would put the released pointer back when it ends. Idempotent. */
ColloStatus collo_vm_release_exec_ctx(ColloVm* vm, ColloExecCtx* exec_ctx);
/* Microtasks this VM ran under a restored owner: promise reactions whose
   registrant was not the owner draining the queue. Monotonic and never reset. */
uint64_t collo_vm_owner_crossings(ColloVm* vm);

/* Called in pairs around each restored continuation whose owner differs from
   the owner it interrupts: (interrupted, restored) before it runs and
   (restored, interrupted) after. Both sides are owners as defined above, so a
   turnless drain's side is the turnless context, and a reaction drained under
   the owner that registered it causes no call. NULL means no owner. Runs on
   the VM thread with the JS lock held and must not re-enter the VM.

   The bridge keeps no clock: an embedder that charges CPU or enforces
   deadlines per owner moves its windows here and at the turn boundaries. */
typedef void (*ColloOwnerTransitionHook)(void* ctx, ColloExecCtx* leaving, ColloExecCtx* entering);
ColloStatus collo_vm_set_owner_transition_hook(ColloVm* vm, ColloOwnerTransitionHook hook, void* ctx);

typedef uint8_t ColloConsoleLevel;

enum {
    COLLO_CONSOLE_DEBUG = 0,
    COLLO_CONSOLE_INFO = 1,
    COLLO_CONSOLE_WARN = 2,
    COLLO_CONSOLE_ERROR = 3,
};

/* Console sink: receives one formatted UTF-8 line per console call from user
   JS, and nothing else. It runs synchronously on the VM thread while the turn
   is live, and `bytes` is borrowed for the call only. `level` is a
   ColloConsoleLevel. `flags` bit 0: the line was truncated at the registered
   byte budget. `flags` bit 1: the per-request output budget dropped the line,
   so bytes is null and len 0, a marker to count and never a line. The two bits
   are never set together. `request_id` is the request_id of the owner of the
   JavaScript that logged, or 0 when it has none. The sink must not call back
   into the VM. */
typedef void (*ColloConsoleSink)(
    void* ctx, uint8_t level, uint8_t flags, uint64_t request_id, const uint8_t* bytes, size_t len);

/* Workers only: routes the VM's built-in console (JSC ConsoleObject) into the
   sink. Without a registered sink the console keeps its observable shape but
   emits nothing, as on the zygote's warmup VM, which never registers one.
   `line_bytes_max` is the per-line UTF-8 byte budget the formatter truncates
   at. `request_lines_max` and `request_bytes_max` are the per-request output
   budgets: past either, the formatter stops formatting for that request and
   each suppressed call reaches the sink as a flags bit 1 marker, until
   collo_webapi_cleanup_request clears the request's budget. They apply to the
   ids of dispatched requests only: output with no owner or under an id above
   COLLO_REQUEST_ID_MAX is never charged, and the sink's consumer bounds it
   instead. All three must be
   above 0 when `sink` is non-null. Registration resets every per-request
   budget. A null sink unregisters. */
ColloStatus collo_vm_set_console_sink(ColloVm* vm, ColloConsoleSink sink, void* sink_ctx, size_t line_bytes_max,
    size_t request_lines_max, size_t request_bytes_max);

/* Workers only: installs the global `process` with `platform`, `version`,
   the calling process's `pid` and an empty `env`, on every realm, including
   the ones created later. A route's bindings reach only its handler's `env`
   argument, never `process.env`. Idempotent. */
ColloStatus collo_vm_install_process(ColloVm* vm);
/* Workers only: opens node:fs for the whole process, then installs and
   exposes it on every realm, including the ones created later. Until the
   first call every node:fs operation in the process fails with EPERM,
   whether or not the binding is installed, and nothing closes it again. The
   worker's sandbox is all that confines what node:fs reaches, so call it only
   once the process is inside its chroot and seccomp filter, as the worker's
   child boot does after its filter; the zygote never calls it. Idempotent. */
ColloStatus collo_vm_enable_node_fs_for_worker(ColloVm* vm);
/* The process-global engine settings below are not scoped to a ColloVm and
   take no API lock; each one says which thread may call it. */
ColloStatus collo_prepare_process_for_fork(void);
/* Replaces the idle timeout of every engine helper thread (JSC's compiler and
   collector threads, WTF's AutomaticThread). A short one lets the zygote's
   threads retire before it forks; one longer than the worker's life pins a
   worker's threads, which its seccomp filter would never let it start again.
   Any thread; a change wakes the parked threads so they apply it. */
ColloStatus collo_set_helper_threads_timeout_override_ns(uint64_t timeout_ns);
/* Makes a helper thread that waited `idle_ns` without work release its
   allocator cache once and go on waiting, which a pinned thread needs because
   libpas reclaims another thread's cache only by suspending it with a signal
   the worker's filter denies. Set it, like the timeout, after
   collo_vm_post_fork_child and before collo_vm_prespawn_compiler_threads:
   the post-fork registry reset means a later change never reaches threads
   parked before it. 0 fails with COLLO_STATUS_INVALID_ARGUMENT. Any thread. */
ColloStatus collo_set_helper_threads_cache_release_ns(uint64_t idle_ns);
/* Clears the helper-thread timeout and cache release, so helper threads
   behave as the engine's defaults. collo_vm_post_fork_child calls it too. */
void collo_clear_helper_threads_overrides(void);
/* Stops the calling thread's allocators and returns its cache to the
   allocator, as an idle helper thread does after its cache release. Any
   thread, VM-free. Never called between collo_vm_prepare_for_fork and a fork,
   where the zygote's memory must stay as prepared. */
void collo_allocator_release_thread_cache(void);
/* The engine's GC heap ceiling, which a worker sets from its memory limit. */
ColloStatus collo_set_gc_max_heap_size_override_bytes(uint64_t bytes);
void collo_clear_gc_max_heap_size_override(void);
/* Makes the engine measure its memory as the decimal byte count at offset 0
   of `memory_current_fd`, a cgroup v2 memory.current file, against
   `limit_bytes`, instead of its own resident size against the machine's
   memory; its critical-memory collections then follow the worker's limit. The
   descriptor is borrowed until collo_clear_memory_status_override returns, in
   a worker for its whole life, and each reading costs one pread of it.
   collo_vm_post_fork_child clears it, so a fork child never reads its
   parent's descriptor and sets its own after that call. A zero
   limit, a limit above SIZE_MAX or a negative descriptor fails with
   COLLO_STATUS_INVALID_ARGUMENT. */
ColloStatus collo_set_memory_status_override(uint64_t limit_bytes, int32_t memory_current_fd);
/* Returns the engine to its own memory reading; once it returns, no thread
   reads the override's descriptor. */
void collo_clear_memory_status_override(void);
/* The engine's current memory status into *out, which is cleared on entry.
   A null `out` fails with COLLO_STATUS_INVALID_ARGUMENT. Any thread. */
ColloStatus collo_memory_status(ColloMemoryStatus* out);

/* Modules live in memory only, in the one module pack a VM holds at a time
   (common/ipc/module_pack.zig owns the format). A module that the pack does
   not hold fails to load with an Error that names it. */
/* Registers the pack in `pack`, a mapping of its sealed memfd, as the VM's
   module source. pack is consumed on every call, including non-OK. The
   bridge checks the header and reads each record through bounds-checked
   offsets when a module is first fetched, creating its source provider then;
   a source is wrapped in place as an external string, so every worker of a
   definition shares the pack's page cache and keeps no private copy. A VM
   that already holds a pack fails with COLLO_STATUS_ALREADY_EXISTS, a header
   the format refuses with COLLO_STATUS_INVALID_ARGUMENT, and an allocation
   with COLLO_STATUS_OUT_OF_MEMORY; on every failure the mapping is released
   before the call returns. On OK the mapping stays valid at least until
   collo_module_unregister_pack or collo_vm_destroy, so the caller may keep
   reading the bytes until then, and the bridge releases it once the
   registration and the last source string over it are gone. */
ColloStatus collo_module_register_pack(ColloVm* vm, ColloMapping pack);
/* Drops the VM's pack, its source providers and every realm's cached module
   namespaces; a module evaluated from it stays in JSC's module registry. A
   string a module's source shares, such as a Function.prototype.toString
   result, keeps the mapping alive until it dies. A null or not ready VM, or
   one that holds no pack, fails with COLLO_STATUS_INVALID_ARGUMENT. */
ColloStatus collo_module_unregister_pack(ColloVm* vm);
/* Imports and evaluates the module `specifier` in `realm`'s registry, once
   per realm: the same specifier in another realm is another module instance
   with its own top-level state. A top-level await that needs the worker's
   event loop returns COLLO_STATUS_PENDING, and
   collo_runtime_module_eval_settled reports the settlement under this realm's
   index and the specifier as the caller spelled it. */
ColloStatus collo_module_evaluate(ColloRealm* realm, ColloString specifier, ColloValue** out_exception);
/* Reads an export of the module `specifier` as evaluated in `realm`,
   evaluating it first if needed; a pending top-level await fails with
   COLLO_STATUS_UNSUPPORTED. */
ColloStatus collo_module_get_export(ColloRealm* realm, ColloString specifier, ColloString export_name,
    ColloValue** out_value, ColloValue** out_exception);

/* Enters a turn owned by exec_ctx. The outermost enter installs it as the
   owner, registers its token and holds the microtask drain; a nested enter
   must pass the owner installed at that moment, which inside a restored
   continuation is the continuation's. */
ColloStatus collo_turn_enter(ColloVm* vm, ColloExecCtx* exec_ctx);
/* Calls `callable` inside the turn `expected_ctx` owns. The call runs in the
   callable's realm; `realm` serves a callable with none, a primitive, whose
   TypeError it creates. out_call_started_ns is optional diagnostic output,
   borrowed for this call only. A non-null output exposes
   __colloBenchHandlerEntered for the synchronous invocation; calling it
   records CLOCK_MONOTONIC ns once. The fixture calls it as its first
   statement, so the sample includes JSC preparation and marker dispatch. Zero
   means no marker ran or the clock failed. Null installs no marker and reads
   no clock; an existing application property with that name rejects
   instrumentation. */
ColloStatus collo_invoke(ColloRealm* realm, const ColloExecCtx* expected_ctx, const ColloValue* callable,
    const ColloValue* this_value, const ColloValue* const* argv, size_t argc, ColloValue** out_result,
    ColloValue** out_exception, uint64_t* out_call_started_ns);
/* Leaves the turn; the outermost exit drains the microtask queue first, each
   reaction under the owner that registered it. */
ColloStatus collo_turn_exit_ex(ColloVm* vm, ColloValue** out_exception);

/* The worker never runs a JSC RunLoop, so it drives the VM's DeferredWorkTimer
   itself with the three calls below. Asynchronous wasm settlement
   (WebAssembly.instantiate and compile promises) queues its resolution tasks
   there, and without these calls the ready tasks would never run. */

/* Tickets pending anywhere (compile in flight or settle queued). */
#define COLLO_DEFERRED_WORK_PENDING 0x1u
/* Pending tickets of the imminently-scheduled class (the wasm kind): their
   completion is produced by the wasm worklist thread, so while this bit is
   set the loop must keep a re-check backstop armed instead of sleeping
   unbounded (the wakeup-fd notification is the fast path; the backstop
   covers a doWork pass cut short by termination). */
#define COLLO_DEFERRED_WORK_PENDING_IMMINENT 0x2u

/* Consumes the per-VM pending flag (an exchange with false) that the
   timer-set notification stores, with release ordering, before it writes the
   wakeup fd. That order, store, then eventfd write, then exchange, is what
   makes a lost wake impossible; the implementation carries the argument.
   Returns nonzero when work was scheduled since the last call. Never takes
   the JS lock. */
uint32_t collo_vm_deferred_work_scheduled(ColloVm* vm);
/* Makes the VM's timer-set notification, registered when the VM was created,
   write `wakeup_fd` (an eventfd) after it stores the pending flag whenever
   deferred work is scheduled, including from the wasm worklist thread, which
   is what wakes the blocked worker loop. It only stores the fd, so it
   allocates nothing and may run after the worker's seccomp filter. A new fd
   replaces the old one. `wakeup_fd < 0` unregisters: call it before closing
   the fd, as Runtime.deinit does, so a recycled fd number is never written. */
ColloStatus collo_vm_set_deferred_work_wakeup_fd(ColloVm* vm, int32_t wakeup_fd);
/* Runs every ready deferred task (DeferredWorkTimer::doWork) as one Collo
   turn on `exec_ctx`, then reports what is still pending in `out_state`
   (COLLO_DEFERRED_WORK_* bits). The settle tasks run JS: promise resolution
   happens inside doWork, continuations run in the turn's end-of-turn
   microtask drain, and a drain exception surfaces exactly as from
   collo_turn_exit_ex (COLLO_STATUS_JS_EXCEPTION and out_exception). The JSC
   ticket carries no owner, so the caller decides whose turn it is; a worker
   passes its worker owner's context. Call it outside any turn, on the VM
   thread. */
ColloStatus collo_vm_pump_deferred_work(
    ColloVm* vm, ColloExecCtx* exec_ctx, uint32_t* out_state, ColloValue** out_exception);

ColloStatus collo_value_retain(ColloValue* value, ColloValue** out_value);
void collo_value_release(ColloValue* value);

/* The type of a value as `typeof` names it, except that null has a kind of
   its own. A callable object, a callable proxy included, is a function and
   every other object is an object. */
typedef uint8_t ColloValueKind;

enum {
    COLLO_VALUE_KIND_UNDEFINED = 0,
    COLLO_VALUE_KIND_NULL = 1,
    COLLO_VALUE_KIND_BOOLEAN = 2,
    COLLO_VALUE_KIND_NUMBER = 3,
    COLLO_VALUE_KIND_BIGINT = 4,
    COLLO_VALUE_KIND_STRING = 5,
    COLLO_VALUE_KIND_SYMBOL = 6,
    COLLO_VALUE_KIND_OBJECT = 7,
    COLLO_VALUE_KIND_FUNCTION = 8,
};

/* Writes the ColloValueKind of `value` to *out_kind, which is cleared on
   entry. Runs no JavaScript, so no getter or proxy trap observes it; inside
   or outside a turn. */
ColloStatus collo_value_kind(ColloVm* vm, const ColloValue* value, ColloValueKind* out_kind);
/* Whether `value` is an object with a callable `then`. The read runs in the
   object's realm, or in `realm` for an object with none, and a getter it runs
   can throw. A primitive is not thenable. */
ColloStatus collo_value_is_thenable(
    ColloRealm* realm, const ColloValue* value, uint8_t* out_is_thenable, ColloValue** out_exception);
/* The result of an already-settled promise, outside any turn. A value that is
   not a promise fails with a TypeError of its own realm, or of `realm` for a
   primitive; a pending promise with a TypeError of its realm and
   COLLO_STATUS_UNSUPPORTED. */
ColloStatus collo_promise_await_sync(
    ColloRealm* realm, const ColloValue* promise, ColloValue** out_value, ColloValue** out_exception);
ColloStatus collo_promise_deferred_resolve(
    ColloVm* vm, ColloPromiseDeferred* deferred, const ColloValue* value, ColloValue** out_exception);
ColloStatus collo_promise_deferred_reject(
    ColloVm* vm, ColloPromiseDeferred* deferred, const ColloValue* reason, ColloValue** out_exception);
/* The realm the deferred's promise belongs to, where the caller creates the
   value that settles it. Callable on an unsettled or settled deferred until
   collo_promise_deferred_release. The realm is valid as long as its VM, like
   every realm pointer: after collo_vm_destroy the deferred may still be
   released, but the returned pointer must not be used. */
ColloRealm* collo_promise_deferred_realm(const ColloPromiseDeferred* deferred);
void collo_promise_deferred_release(ColloPromiseDeferred* deferred);
/* Reports `value`, a handler's result, to collo_runtime_complete_request_task
   once it settles: it goes through Promise.resolve of its own realm, or of
   `realm` for a primitive, and the task's settlers are attached to the
   result. */
ColloStatus collo_request_task_settle_thenable(
    ColloRealm* realm, const ColloRequestCompletionToken* token, const ColloValue* value, ColloValue** out_exception);
ColloStatus collo_json_parse_utf8(
    ColloRealm* realm, ColloString source, ColloValue** out_value, ColloValue** out_exception);

ColloStatus collo_undefined(ColloVm* vm, ColloValue** out_value);
ColloStatus collo_null(ColloVm* vm, ColloValue** out_value);
ColloStatus collo_bool_new(ColloVm* vm, uint8_t value, ColloValue** out_value);
ColloStatus collo_number_new(ColloVm* vm, double value, ColloValue** out_value);
ColloStatus collo_string_new_utf8(ColloVm* vm, ColloString utf8, ColloValue** out_value);
/* Creates a TypeError of `realm` whose message is `message`, UTF-8 borrowed
   for the call; the message may be empty. A null pointer with a non-zero
   length or invalid UTF-8 fails with COLLO_STATUS_INVALID_ARGUMENT.
   *out_value is cleared on entry and, on success, holds a new handle the
   caller releases with collo_value_release. Runs no JavaScript, so it works
   inside or outside a turn; takes the API lock. */
ColloStatus collo_type_error_new_utf8(ColloRealm* realm, ColloString message, ColloValue** out_value);
ColloStatus collo_array_buffer_new_copy(
    ColloRealm* realm, ColloBuffer bytes, ColloValue** out_value, ColloValue** out_exception);
ColloStatus collo_uint8_array_new_copy(
    ColloRealm* realm, ColloBuffer bytes, ColloValue** out_value, ColloValue** out_exception);
ColloStatus collo_blob_new_copy(
    ColloRealm* realm, ColloBuffer bytes, ColloString type, ColloValue** out_value, ColloValue** out_exception);
ColloStatus collo_fetch_read_result_new_copy(
    ColloRealm* realm, ColloBuffer bytes, uint8_t done, ColloValue** out_value, ColloValue** out_exception);
ColloStatus collo_form_data_new_from_bytes(
    ColloRealm* realm, ColloBuffer bytes, ColloString content_type, ColloValue** out_value, ColloValue** out_exception);
ColloStatus collo_object_new(ColloRealm* realm, ColloValue** out_value);
ColloStatus collo_array_new(ColloRealm* realm, ColloValue** out_value);
ColloStatus collo_global_this(ColloRealm* realm, ColloValue** out_value);
/* Builds a route's `env` object: an ordinary object whose own enumerable data properties map each entry's name to
   its value as a string, in entry order, frozen before it is returned. It runs no JavaScript: properties are defined
   directly, so no setter on the prototype chain runs, and freezing an ordinary object reaches no trap. `entries` and
   the bytes it points to are borrowed for the call and may be null when `entry_count` is 0. Names and values must be
   UTF-8 and a name must be neither empty nor an array index; an entry that breaks either rule fails the call with
   COLLO_STATUS_INVALID_ARGUMENT. A repeated name keeps its last value. *out_value is cleared on entry and, on
   success, holds a new handle the caller releases with collo_value_release; a pending termination fails the call
   with COLLO_STATUS_ERROR. Takes the API lock; inside or outside a turn. */
ColloStatus collo_env_object_new(
    ColloRealm* realm, const ColloNameValuePair* entries, size_t entry_count, ColloValue** out_value);

/* Property access on an object, run in the object's realm. A value that is
   not an object, or not an array for collo_array_set, fails with a TypeError
   of `realm`, or of its own realm when it is an object. */
ColloStatus collo_object_get_utf8(
    ColloRealm* realm, const ColloValue* object, ColloString key, ColloValue** out_value, ColloValue** out_exception);
ColloStatus collo_object_set_utf8(
    ColloRealm* realm, const ColloValue* object, ColloString key, const ColloValue* value, ColloValue** out_exception);
ColloStatus collo_array_set(
    ColloRealm* realm, const ColloValue* array, size_t index, const ColloValue* value, ColloValue** out_exception);

/* ToString of `value` as UTF-8, run in the value's realm or, for a primitive,
   in `realm`, whose TypeError a Symbol gets. */
ColloStatus collo_value_to_utf8_copy(
    ColloRealm* realm, const ColloValue* value, ColloString* out_string, ColloValue** out_exception);
ColloStatus collo_exception_format(ColloVm* vm, const ColloValue* exception, ColloString* out_string);
void collo_free_buffer(const void* ptr);

#ifdef __cplusplus
}
#endif

#endif
