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
 * FIXME: Some functions cross the boundary without a declaration here, so no
 * shared prototype checks them: collo_tool_generate_module_bytecode and
 * collo_tool_bytecode_release (jsc/runtime/tooling_bytecode.cpp), and the
 * collo_worker_fs_* and collo_runtime_fs_fault_* functions that
 * host_functions/node/fs.cpp declares in an extern "C" block of its own.
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
    COLLO_STATUS_ALREADY_EXISTS = 6,
    COLLO_STATUS_RESPONSE_BODY_TOO_LARGE = 7,
    COLLO_STATUS_RESPONSE_HEADER_COUNT_TOO_LARGE = 8,
    COLLO_STATUS_RESPONSE_HEADER_BYTES_TOO_LARGE = 9,
    /* Module evaluation reached top-level await: the evaluation promise is
       parked and collo_runtime_module_eval_settled reports its settlement. */
    COLLO_STATUS_PENDING = 10,
};

enum {
    COLLO_ABI_VERSION = 1,
    COLLO_MODULE_PACK_MAX_BYTES = 16 * 1024 * 1024,
    /* The largest file an fs fault materializes. It equals
       `max_fault_file_bytes` in common/limits/fs_fault.zig, as
       COLLO_MODULE_PACK_MAX_BYTES equals `max_pack_bytes` in
       common/ipc/module_pack.zig. C cannot read the Zig constants, so each
       pair is kept equal by hand; runtime/tests/contracts/limits.zig pins how
       the Zig constants relate. */
    COLLO_FS_FAULT_MAX_FILE_BYTES = 256 * 1024 * 1024,
};

enum {
    COLLO_VM_OPTION_DISABLE_WEBAPIS = 1u << 0,
};

typedef struct ColloVm ColloVm;
/* One global object of a VM with its own globals, intrinsics and module
   registry. The VM owns every realm until collo_vm_destroy, so a realm pointer
   stays valid as long as its VM. */
typedef struct ColloRealm ColloRealm;
typedef struct ColloValue ColloValue;
typedef struct ColloPromiseDeferred ColloPromiseDeferred;
typedef struct ColloCryptoJob ColloCryptoJob;
typedef struct ColloOwnedByteSegments ColloOwnedByteSegments;
typedef struct ColloOwnedHeaderBlock ColloOwnedHeaderBlock;

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

/* A request's execution context as the bridge sees it: identity, deadline,
   CPU time and termination reason. Everything else about the request lives in
   the Zig request context that holds this struct. */
typedef struct ColloExecCtx {
    /* The request's id, set from its dispatch and never changed. */
    uint64_t request_id;

    /* The request's absolute CLOCK_MONOTONIC deadline in ns, or 0 for none.
       The worker's sentinel enforces it; the bridge does not read it. */
    uint64_t deadline_monotonic_ns;

    /* CPU ns the request's turns used, which the bridge adds at each turn
       exit or owner hand-over as CLOCK_THREAD_CPUTIME_ID minus
       turn_cpu_start_ns. */
    uint64_t cpu_used_ns_total;

    /* CLOCK_THREAD_CPUTIME_ID when the current turn started, or 0 outside a
       turn. */
    uint64_t turn_cpu_start_ns;

    /* Why the request ended, a ColloTerminationReason; NONE while it runs.
       Zig decides and writes it before worker-fatal cleanup. */
    uint8_t termination_reason;

    uint8_t _reserved[7];
} ColloExecCtx;

typedef struct {
    uint32_t abi_version;
    uint32_t flags;
} ColloVmOptions;

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

typedef uint8_t ColloModuleLifetime;

enum {
    COLLO_MODULE_LIFETIME_EVICTABLE = 0,
    COLLO_MODULE_LIFETIME_PERMANENT = 1,
};

typedef uint8_t ColloModuleType;

enum {
    COLLO_MODULE_TYPE_ESM = 0,
};

typedef struct ColloModuleRegisterOptions {
    uint32_t abi_size;
    uint8_t lifetime;
    uint8_t module_type;
    uint16_t reserved0;
    uint32_t flags;
} ColloModuleRegisterOptions;

typedef struct ColloModuleEvictStats {
    size_t sources_removed;
    size_t namespaces_removed;
} ColloModuleEvictStats;

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
};

typedef struct ColloByteSegment {
    ColloBuffer bytes;
} ColloByteSegment;

typedef struct ColloExtractedResponseBody {
    uint32_t kind;
    uint32_t flags;
    size_t total_len;
    const ColloByteSegment* segments;
    size_t segments_len;
    ColloOwnedByteSegments* owner;
    ColloFetchBodyIdentity stream_identity;
} ColloExtractedResponseBody;

typedef struct ColloHeaderView {
    uint32_t name_offset;
    uint32_t name_len;
    uint32_t value_offset;
    uint32_t value_len;
    uint32_t flags;
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
   transferred to the caller and is not released by collo_response_extract_free(). */
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

COLLO_STATIC_ASSERT(sizeof(ColloMapping) == 16, "ColloMapping ABI size mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloMapping, ptr) == 0, "ColloMapping.ptr offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloMapping, len) == 8, "ColloMapping.len offset mismatch");

COLLO_STATIC_ASSERT(sizeof(ColloExecCtx) == 40, "ColloExecCtx ABI size mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloExecCtx, request_id) == 0, "ColloExecCtx.request_id offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloExecCtx, deadline_monotonic_ns) == 8, "ColloExecCtx.deadline_monotonic_ns offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloExecCtx, cpu_used_ns_total) == 16, "ColloExecCtx.cpu_used_ns_total offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloExecCtx, turn_cpu_start_ns) == 24, "ColloExecCtx.turn_cpu_start_ns offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloExecCtx, termination_reason) == 32, "ColloExecCtx.termination_reason offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloExecCtx, _reserved) == 33, "ColloExecCtx._reserved offset mismatch");

COLLO_STATIC_ASSERT(sizeof(ColloVmOptions) == 8, "ColloVmOptions ABI size mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloVmOptions, abi_version) == 0, "ColloVmOptions.abi_version offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloVmOptions, flags) == 4, "ColloVmOptions.flags offset mismatch");

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

COLLO_STATIC_ASSERT(sizeof(ColloModuleRegisterOptions) == 12, "ColloModuleRegisterOptions ABI size mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloModuleRegisterOptions, abi_size) == 0, "ColloModuleRegisterOptions.abi_size offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloModuleRegisterOptions, lifetime) == 4, "ColloModuleRegisterOptions.lifetime offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloModuleRegisterOptions, module_type) == 5, "ColloModuleRegisterOptions.module_type offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloModuleRegisterOptions, reserved0) == 6, "ColloModuleRegisterOptions.reserved0 offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloModuleRegisterOptions, flags) == 8, "ColloModuleRegisterOptions.flags offset mismatch");

COLLO_STATIC_ASSERT(sizeof(ColloModuleEvictStats) == 16, "ColloModuleEvictStats ABI size mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloModuleEvictStats, sources_removed) == 0, "ColloModuleEvictStats.sources_removed offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloModuleEvictStats, namespaces_removed) == 8,
    "ColloModuleEvictStats.namespaces_removed offset mismatch");

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

COLLO_STATIC_ASSERT(sizeof(ColloExtractedResponseBody) == 72, "ColloExtractedResponseBody ABI size mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloExtractedResponseBody, kind) == 0, "ColloExtractedResponseBody.kind offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloExtractedResponseBody, flags) == 4, "ColloExtractedResponseBody.flags offset mismatch");
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

COLLO_STATIC_ASSERT(sizeof(ColloHeaderView) == 20, "ColloHeaderView ABI size mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloHeaderView, name_offset) == 0, "ColloHeaderView.name_offset offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloHeaderView, name_len) == 4, "ColloHeaderView.name_len offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloHeaderView, value_offset) == 8, "ColloHeaderView.value_offset offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloHeaderView, value_len) == 12, "ColloHeaderView.value_len offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloHeaderView, flags) == 16, "ColloHeaderView.flags offset mismatch");

COLLO_STATIC_ASSERT(sizeof(ColloExtractedHeaderBlock) == 40, "ColloExtractedHeaderBlock ABI size mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloExtractedHeaderBlock, storage) == 0, "ColloExtractedHeaderBlock.storage offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloExtractedHeaderBlock, headers) == 16, "ColloExtractedHeaderBlock.headers offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloExtractedHeaderBlock, headers_len) == 24, "ColloExtractedHeaderBlock.headers_len offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloExtractedHeaderBlock, owner) == 32, "ColloExtractedHeaderBlock.owner offset mismatch");

COLLO_STATIC_ASSERT(sizeof(ColloExtractedResponse) == 120, "ColloExtractedResponse ABI size mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloExtractedResponse, body) == 0, "ColloExtractedResponse.body offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloExtractedResponse, headers) == 72, "ColloExtractedResponse.headers offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloExtractedResponse, status) == 112, "ColloExtractedResponse.status offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloExtractedResponse, reserved0) == 114, "ColloExtractedResponse.reserved0 offset mismatch");
COLLO_STATIC_ASSERT(
    offsetof(ColloExtractedResponse, reserved1) == 116, "ColloExtractedResponse.reserved1 offset mismatch");

COLLO_STATIC_ASSERT(sizeof(ColloResponseExtractLimits) == 24, "ColloResponseExtractLimits ABI size mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloResponseExtractLimits, max_body_bytes) == 0,
    "ColloResponseExtractLimits.max_body_bytes offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloResponseExtractLimits, max_header_count) == 8,
    "ColloResponseExtractLimits.max_header_count offset mismatch");
COLLO_STATIC_ASSERT(offsetof(ColloResponseExtractLimits, max_header_bytes) == 16,
    "ColloResponseExtractLimits.max_header_bytes offset mismatch");

#undef COLLO_STATIC_ASSERT

/* Ends a mapping Zig handed to the bridge; the bridge calls it exactly once per
   mapping it was given. JSC SourceProviders are thread-safe refcounted, so this
   runs on whichever thread drops the last reference, not necessarily the VM
   thread, and possibly while the JSC API lock or a bridge mutex is held; it
   must not call into the bridge. A mapping with a null ptr maps nothing and is
   ignored. */
void collo_runtime_mapping_release(ColloMapping mapping);
/* If value is non-null, runtime consumes it on every call, including non-OK. */
ColloStatus collo_runtime_complete_request_task(void* runtime, uint32_t slot, uint32_t generation, uint64_t request_id,
    uint64_t request_generation, ColloValue* value, uint8_t is_error);
/* Settlement of a module evaluation previously returned as
   COLLO_STATUS_PENDING, called on the VM thread from inside a microtask
   drain. realm_index is the evaluating realm's (collo_realm_index), since one
   specifier evaluates once per realm. specifier is valid only for the
   duration of the call; the runtime copies what it needs and only enqueues,
   so no JS runs. */
void collo_runtime_module_eval_settled(void* runtime, uint32_t realm_index, ColloString specifier, uint8_t resolved);
/* Runtime owns job on OK. On non-OK, caller still owns job. */
ColloStatus collo_runtime_crypto_job_enqueue(void* runtime, uint64_t request_id, ColloCryptoJob* job);
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
   including non-OK. The args array storage itself is borrowed. */
ColloStatus collo_runtime_set_immediate(void* runtime, uint64_t request_id, ColloValue* callback, ColloValue* this_arg,
    ColloValue** args, size_t args_len, uint64_t* out_immediate_id);
ColloStatus collo_runtime_clear_immediate(void* runtime, uint64_t request_id, uint64_t immediate_id);
ColloStatus collo_webapi_immediate_mark_destroyed(ColloVm* vm, const ColloValue* value);
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
ColloStatus collo_response_extract(ColloVm* vm, const ColloValue* value, const ColloResponseExtractLimits* limits,
    ColloExtractedResponse* out_response, ColloValue** out_exception);
void collo_response_extract_free(ColloExtractedResponse* response);
void collo_owned_byte_segments_destroy(ColloOwnedByteSegments* owner);
void collo_owned_header_block_destroy(ColloOwnedHeaderBlock* owner);
/* Clears request-scoped Web API state held by worker-global singletons. */
ColloStatus collo_webapi_cleanup_request(ColloVm* vm, uint64_t request_id);

/* Creates a fully initialized VM in *out_vm, which the caller owns until
   collo_vm_destroy, with its main realm. */
ColloStatus collo_vm_create(const ColloVmOptions* options, ColloVm** out_vm);
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
/* Cross-thread cooperative termination trap. The caller must keep the ColloVm
   object alive. If VM destroy has begun, this returns invalid argument. */
ColloStatus collo_vm_request_termination(ColloVm* vm);
ColloStatus collo_vm_set_host_runtime(ColloVm* vm, void* runtime);
/* Workers only: installs the boot exec context, the identity turnless JS
   (module evaluation and its microtask drains) resolves to when no request
   turn is active. It is never turn-entered and its deadline stays 0; the
   worker runtime enforces the evaluation budget. The zygote's warmup VM never
   calls this, so evaluation on a bare VM finds no context. */
ColloStatus collo_vm_set_boot_exec_ctx(ColloVm* vm, uint64_t request_id);
/* Workers only: uninstalls the boot exec context when the boot context closes,
   once the evaluation of every route's entry settled. From then on turnless
   JS finds no context, and the dynamic-import fallback and the console's boot
   exemption close with it. Idempotent: clearing a context never installed is
   OK. */
ColloStatus collo_vm_clear_boot_exec_ctx(ColloVm* vm);
/* Registers exec_ctx as a microtask owner and returns its token, or 0 if the
   table is full. Idempotent: the same pointer always maps to the same live
   token. collo_turn_enter registers on its own, so the worker only needs this
   if it wants a token before the first turn.

   A promise reaction registered by this request can outlive it, as when one
   request awaits a module-scope promise and the next settles it, so the
   reaction stores this token, never the pointer. */
uint64_t collo_vm_acquire_exec_ctx(ColloVm* vm, ColloExecCtx* exec_ctx);
/* Required before the ColloExecCtx storage dies: frees the slot and drops
   current_exec_ctx if it still points there. A microtask still carrying the
   released token then resolves to "no owner", the fallback turnless JS takes,
   instead of reading freed memory. Idempotent. */
ColloStatus collo_vm_release_exec_ctx(ColloVm* vm, ColloExecCtx* exec_ctx);
/* Microtasks this VM ran under a restored owner: promise reactions whose
   registrant was not the request draining the queue. Monotonic and never
   reset. */
uint64_t collo_vm_owner_crossings(ColloVm* vm);

/* Called in pairs whenever a microtask drain hands execution from one request
   to another and back: `leaving` gives up the turn, `entering` takes it. Either
   may be NULL, which means turnless execution: module evaluation, or an owner
   whose request already ended. Runs on the VM thread with the JS lock held and
   must not re-enter the VM.

   The hook reports only the identity change, for the deadline arbiter and the
   request timeline, which live outside this ABI. CPU time is not reported:
   `cpu_used_ns_total` and `turn_cpu_start_ns` are fields of this ABI, and the
   bridge moves the slice itself. */
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
   are never set together. `request_id` is the live turn's identity: the boot
   identity for turnless JS, 0 on a bare VM. The sink must not call back into
   the VM. */
typedef void (*ColloConsoleSink)(
    void* ctx, uint8_t level, uint8_t flags, uint64_t request_id, const uint8_t* bytes, size_t len);

/* Workers only: routes the VM's built-in console (JSC ConsoleObject) into the
   sink. Without a registered sink the console keeps its observable shape but
   emits nothing, as on the zygote's warmup VM, which never registers one.
   `line_bytes_max` is the per-line UTF-8 byte budget the formatter truncates
   at. `request_lines_max` and `request_bytes_max` are the per-request output
   budgets: past either, the formatter stops formatting for that request and
   each suppressed call reaches the sink as a flags bit 1 marker, until
   collo_webapi_cleanup_request clears the request's budget. All three must be
   above 0 when `sink` is non-null. Registration resets every per-request
   budget. A null sink unregisters. */
ColloStatus collo_vm_set_console_sink(ColloVm* vm, ColloConsoleSink sink, void* sink_ctx, size_t line_bytes_max,
    size_t request_lines_max, size_t request_bytes_max);

/* Workers only: installs the global `process` with `platform`, `version`,
   the calling process's `pid` and an empty `env`, on every realm, including
   the ones created later. A route's bindings reach only its handler's `env`
   argument, never `process.env`. Idempotent. */
ColloStatus collo_vm_install_process(ColloVm* vm);
/* Workers only: installs and exposes node:fs, on every realm, once the
   worker is inside its chroot and seccomp confinement. No other VM calls it.
   Idempotent. */
ColloStatus collo_vm_enable_node_fs_for_worker(ColloVm* vm);
ColloStatus collo_prepare_process_for_fork(void);
ColloStatus collo_set_helper_threads_timeout_override_ns(uint64_t timeout_ns);
void collo_clear_helper_threads_timeout_override(void);
/* Process-global WebKit GC heap override, not scoped to a single ColloVm. */
ColloStatus collo_set_gc_max_heap_size_override_bytes(uint64_t bytes);
void collo_clear_gc_max_heap_size_override(void);

/* Modules live in memory only and are registered a pack at a time. A module
   that no registered pack holds fails to load with an Error that names it. */
/* Registers the modules of a pack from a mapping of its sealed memfd. The
   SourceProviders read the mapping in place, so every worker of a definition
   shares the pack's page cache instead of keeping a private copy.
   pack is consumed on every call, including non-OK: the bridge validates the
   bytes in place, then releases the mapping before returning unless a
   registered module keeps it, in which case the release comes when the last
   SourceProvider pointing into it dies. The caller must not read pack.ptr
   after the call. options is borrowed for the call; null means an evictable
   ESM pack. */
ColloStatus collo_module_register_pack(ColloVm* vm, ColloMapping pack, const ColloModuleRegisterOptions* options);
/* Removes Collo-owned module providers and cached namespaces only. JSC may keep
   already-fetched/evaluated module records alive until the VM is recycled. */
ColloStatus collo_module_evict_specifier(ColloVm* vm, ColloString specifier, ColloModuleEvictStats* out_stats);
ColloStatus collo_module_evict_lifetime(ColloVm* vm, ColloModuleLifetime lifetime, ColloModuleEvictStats* out_stats);
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

ColloStatus collo_turn_enter(ColloVm* vm, ColloExecCtx* exec_ctx);
/* Optional diagnostic output, borrowed for this call only. A non-null output
   exposes __colloBenchHandlerEntered for the synchronous invocation; calling it
   records CLOCK_MONOTONIC ns once. The fixture calls it as its first statement,
   so the sample includes JSC preparation and marker dispatch. Zero means no
   marker ran or the clock failed. Null installs no marker and reads no clock;
   an existing application property with that name rejects instrumentation. */
ColloStatus collo_invoke(ColloVm* vm, const ColloExecCtx* expected_ctx, const ColloValue* callable,
    const ColloValue* this_value, const ColloValue* const* argv, size_t argc, ColloValue** out_result,
    ColloValue** out_exception, uint64_t* out_call_started_ns);
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
/* Registers a per-VM timer-set notification that stores the pending flag and
   then writes `wakeup_fd` (an eventfd) whenever deferred work is scheduled,
   including from the wasm worklist thread, which is what wakes the blocked
   worker loop. A new registration supersedes the old one, which goes inert
   before the new fd is installed. `wakeup_fd < 0` unregisters: call it before
   closing the fd, as Runtime.deinit does, so a recycled fd number is never
   written. */
ColloStatus collo_vm_set_deferred_work_wakeup_fd(ColloVm* vm, int32_t wakeup_fd);
/* Runs every ready deferred task (DeferredWorkTimer::doWork) as one Collo
   turn on `exec_ctx`, then reports what is still pending in `out_state`
   (COLLO_DEFERRED_WORK_* bits). The settle tasks run JS: promise resolution
   happens inside doWork, continuations run in the turn's end-of-turn
   microtask drain, and a drain exception surfaces exactly as from
   collo_turn_exit_ex (COLLO_STATUS_JS_EXCEPTION and out_exception). The JSC
   ticket carries no request identity, so the caller decides whose turn it is.
   Call it outside any turn, on the VM thread. */
ColloStatus collo_vm_pump_deferred_work(
    ColloVm* vm, ColloExecCtx* exec_ctx, uint32_t* out_state, ColloValue** out_exception);

ColloStatus collo_value_retain(ColloValue* value, ColloValue** out_value);
void collo_value_release(ColloValue* value);
ColloStatus collo_value_is_callable(ColloVm* vm, const ColloValue* value, uint8_t* out_is_callable);
ColloStatus collo_value_is_thenable(
    ColloVm* vm, const ColloValue* value, uint8_t* out_is_thenable, ColloValue** out_exception);
ColloStatus collo_promise_await_sync(
    ColloVm* vm, const ColloValue* promise, ColloValue** out_value, ColloValue** out_exception);
ColloStatus collo_promise_deferred_resolve(
    ColloVm* vm, ColloPromiseDeferred* deferred, const ColloValue* value, ColloValue** out_exception);
ColloStatus collo_promise_deferred_reject(
    ColloVm* vm, ColloPromiseDeferred* deferred, const ColloValue* reason, ColloValue** out_exception);
/* The realm the deferred's promise belongs to, where the caller creates the
   value that settles it. Valid for an unsettled or settled deferred until
   collo_promise_deferred_release. */
ColloRealm* collo_promise_deferred_realm(const ColloPromiseDeferred* deferred);
void collo_promise_deferred_release(ColloPromiseDeferred* deferred);
ColloStatus collo_request_task_settle_thenable(
    ColloVm* vm, const ColloRequestCompletionToken* token, const ColloValue* value, ColloValue** out_exception);
/* Runs the job's native work. A crypto pool thread calls it, off the VM
   thread, so the job carries only native data; collo_crypto_job_settle later
   settles its promise on the VM thread. */
void collo_crypto_job_run(ColloCryptoJob* job);
/* Consumes job on every call, including non-OK. The result is built in the
   realm of the job's promise. */
ColloStatus collo_crypto_job_settle(ColloVm* vm, ColloCryptoJob* job, ColloValue** out_exception);
/* Must run on the VM thread because jobs may own JSC Strong handles. */
void collo_crypto_job_destroy(ColloCryptoJob* job);
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
ColloStatus collo_form_data_new_from_bytes(ColloRealm* realm, ColloBuffer bytes, ColloString content_type,
    ColloValue** out_value, ColloValue** out_exception);
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

ColloStatus collo_object_get_utf8(
    ColloVm* vm, const ColloValue* object, ColloString key, ColloValue** out_value, ColloValue** out_exception);
ColloStatus collo_object_set_utf8(
    ColloVm* vm, const ColloValue* object, ColloString key, const ColloValue* value, ColloValue** out_exception);
ColloStatus collo_array_set(
    ColloVm* vm, const ColloValue* array, size_t index, const ColloValue* value, ColloValue** out_exception);

ColloStatus collo_value_to_utf8_copy(
    ColloVm* vm, const ColloValue* value, ColloString* out_string, ColloValue** out_exception);
ColloStatus collo_exception_format(ColloVm* vm, const ColloValue* exception, ColloString* out_string);
void collo_free_buffer(const void* ptr);

#ifdef __cplusplus
}
#endif

#endif
