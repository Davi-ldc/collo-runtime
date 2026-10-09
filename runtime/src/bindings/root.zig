//! The Zig side of the C ABI in `include/collo/abi.h`, used by every process
//! that runs JavaScript: the zygote, the workers it forks, and the test and
//! benchmark binaries. It holds an `extern struct` mirror of each struct the
//! header declares and the `Vm`, `Realm` and `Value` wrappers the rest of the
//! runtime calls instead of the raw functions; the egress gateway uses only
//! some of the mirrors. This file and `abi.h` are never compiled against each
//! other: the `comptime` block below and the header's pins check each side
//! against the same sizes and offsets, and nothing compares the function
//! declarations, so an ABI change edits both in one change.
//!
//! A `Vm` and its realms are used on the thread that owns the VM;
//! `requestTermination` is the one call made from another thread. A `Realm`
//! creates objects in its own globals and lives as long as its VM, while
//! operations on an existing value run in that value's realm through the
//! `Vm`. A `Value` owns its handle and releases it once with `deinit`. A
//! JavaScript exception, and on some calls an unsupported operation, comes
//! back as a result variant that owns its value; `turnExit` is the one
//! wrapper that releases the exception and returns `error.JsException`
//! instead. Any other failing status becomes a Zig error through
//! `statusToError`. The worker exports the `collo_runtime_*` functions the
//! bridge calls (`worker/host/`), except `collo_runtime_mapping_release`,
//! which lives here with the mappings it ends.

const std = @import("std");

/// Equals `COLLO_ABI_VERSION` in `abi.h`; `collo_vm_create` refuses options
/// that carry another version.
pub const ABI_VERSION: u32 = 1;

pub const RawStatus = i32;
pub const Error = error{
    Internal,
    InvalidArgument,
    InvalidJsValue,
    JsException,
    Unsupported,
    OutOfMemory,
    AlreadyExists,
    ResponseBodyTooLarge,
    ResponseHeaderCountTooLarge,
    ResponseHeaderBytesTooLarge,
};

// The `COLLO_STATUS_*` values of `abi.h`.
const status_ok: RawStatus = 0;
const status_error: RawStatus = 1;
const status_invalid_argument: RawStatus = 2;
const status_js_exception: RawStatus = 3;
const status_unsupported: RawStatus = 4;
const status_out_of_memory: RawStatus = 5;
const status_already_exists: RawStatus = 6;
const status_response_body_too_large: RawStatus = 7;
const status_response_header_count_too_large: RawStatus = 8;
const status_response_header_bytes_too_large: RawStatus = 9;
/// Module evaluation reached a top-level await: the bridge keeps the
/// evaluation promise and reports its settlement through
/// `collo_runtime_module_eval_settled`.
const status_pending: RawStatus = 10;

pub const vm_option_disable_webapis: u32 = 1 << 0;

/// The `COLLO_TERMINATION_*` values that `ExecCtx.termination_reason` holds.
pub const TerminationReason = enum(u8) {
    none = 0,
    cpu = 1,
    memory = 2,
    crash = 3,
    init_failed = 4,
    deadline = 5,
};

pub const RawVm = opaque {};
pub const RawRealm = opaque {};
pub const RawValue = opaque {};
pub const RawPromiseDeferred = opaque {};
pub const RawCryptoJob = opaque {};
pub const RawOwnedByteSegments = opaque {};
pub const RawOwnedHeaderBlock = opaque {};

pub const RawString = extern struct {
    ptr: ?[*]const u8,
    len: usize,
};

pub const RawBuffer = extern struct {
    ptr: ?[*]const u8,
    len: usize,
};

/// Mirror of `ColloMapping`: a read-only private mapping of a sealed memfd.
/// Each one made by `map` ends exactly once, either by `release` while Zig
/// still owns it or by the bridge through `collo_runtime_mapping_release`
/// after a call that consumes it.
pub const Mapping = extern struct {
    ptr: ?[*]align(std.heap.page_size_min) const u8,
    len: usize,

    pub const MapError = std.posix.MMapError || error{EmptyMapping};

    /// Maps `len` bytes of `fd`. The caller has checked that `fd` is sealed
    /// against writes and resizes and holds `len` bytes, so the pages cannot
    /// change under the mapping. The mapping keeps the file alive, so `fd` may
    /// be closed as soon as this returns.
    pub fn map(fd: std.posix.fd_t, len: usize) MapError!Mapping {
        if (len == 0) return error.EmptyMapping;
        const mapped = try std.posix.mmap(null, len, std.posix.PROT.READ, .{ .TYPE = .PRIVATE }, fd, 0);
        _ = live_mappings.fetchAdd(1, .monotonic);
        return .{ .ptr = mapped.ptr, .len = mapped.len };
    }

    pub fn bytes(self: Mapping) []const u8 {
        return if (self.ptr) |ptr| ptr[0..self.len] else "";
    }

    /// Ends a mapping Zig still owns.
    pub fn release(self: Mapping) void {
        collo_runtime_mapping_release(self);
    }
};

/// Mappings made by `Mapping.map` and not yet released, in this process.
/// Workers inherit the zygote's count with its mappings.
var live_mappings = std.atomic.Value(usize).init(0);

pub fn liveMappingCount() usize {
    return live_mappings.load(.monotonic);
}

/// abi.h owns the contract: called once per mapping, from any thread, possibly
/// under the JSC API lock or a bridge mutex. munmap and the atomic counter are
/// safe there, and nothing here calls back into the bridge.
export fn collo_runtime_mapping_release(mapping: Mapping) callconv(.c) void {
    const ptr = mapping.ptr orelse return;
    std.posix.munmap(ptr[0..mapping.len]);
    _ = live_mappings.fetchSub(1, .monotonic);
}

pub const NameValuePair = extern struct {
    name: RawString,
    value: RawString,
};

/// Mirror of `ColloFetchInit`, with `request_id` first and no implicit
/// padding; the offsets are pinned below.
pub const FetchInit = extern struct {
    request_id: u64,
    url: RawString,
    method: RawString,
    body: RawBuffer,
    headers: ?[*]const NameValuePair,
    headers_len: usize,
    /// bits 0..1: redirect mode (0 follow, 1 error, 2 manual).
    flags: u32,
    reserved0: u32,
};

/// Mirror of `ColloExecCtx`; `abi.h` documents each field.
pub const ExecCtx = extern struct {
    request_id: u64,
    deadline_monotonic_ns: u64,
    cpu_used_ns_total: u64,
    turn_cpu_start_ns: u64,
    termination_reason: u8,
    _reserved: [7]u8,

    pub fn init(request_id: u64) ExecCtx {
        return .{
            .request_id = request_id,
            .deadline_monotonic_ns = 0,
            .cpu_used_ns_total = 0,
            .turn_cpu_start_ns = 0,
            .termination_reason = @intFromEnum(TerminationReason.none),
            ._reserved = .{ 0, 0, 0, 0, 0, 0, 0 },
        };
    }
};

pub const VmOptions = extern struct {
    abi_version: u32 = ABI_VERSION,
    flags: u32 = 0,

    pub fn init() VmOptions {
        return .{};
    }

    pub fn withoutWebApis() VmOptions {
        return .{ .flags = vm_option_disable_webapis };
    }
};

pub const RandomSeeds = extern struct {
    weak_random_seed: u32,
    vm_random_seed: u32,
    heap_random_seed: u32,
};

pub const RequestCompletionToken = extern struct {
    slot: u32,
    generation: u32,
    request_id: u64,
    request_generation: u64,
};

pub const RequestIdentity = extern struct {
    request_id: u64,
    request_generation: u64,
};

pub const ModuleLifetime = enum(u8) {
    evictable = 0,
    permanent = 1,
};

pub const ModuleType = enum(u8) {
    esm = 0,
};

pub const ModuleRegisterOptions = extern struct {
    abi_size: u32 = @sizeOf(ModuleRegisterOptions),
    lifetime: u8 = @intFromEnum(ModuleLifetime.evictable),
    module_type: u8 = @intFromEnum(ModuleType.esm),
    reserved0: u16 = 0,
    flags: u32 = 0,
};

pub const ModuleEvictStats = extern struct {
    sources_removed: usize = 0,
    namespaces_removed: usize = 0,
};

/// Mirror of `ColloRequestInit`, the input of `Realm.requestValue`. Every
/// string and array is borrowed for the call; the bridge copies them.
/// `authority` is the request's normalized authority, which `request.url`
/// is built from.
pub const RequestInit = extern struct {
    method: RawString,
    path: RawString,
    raw_query: RawString,
    authority: RawString,
    headers: ?[*]const NameValuePair,
    headers_len: usize,
    params: ?[*]const NameValuePair,
    params_len: usize,
    identity: RequestIdentity,
};

pub const ResponseInit = extern struct {
    body: RawBuffer,
    status_text: RawString = .{ .ptr = null, .len = 0 },
    url: RawString = .{ .ptr = null, .len = 0 },
    headers: ?[*]const NameValuePair = null,
    headers_len: usize = 0,
    status: u16 = 200,
    flags: u16 = 0,
    reserved1: u32 = 0,
};

pub const response_init_flag_redirected: u16 = 1 << 0;

pub const FetchBodyIdentity = extern struct {
    request_id: u64,
    request_generation: u64,
    fetch_id: u64,
    body_id: u64,
};

pub const FetchBodyConsumeKind = enum(u8) {
    text = 0,
    json = 1,
    array_buffer = 2,
    bytes = 3,
    blob = 4,
    form_data = 5,
};

pub const FetchBodyConsumeInit = extern struct {
    identity: FetchBodyIdentity,
    content_type: RawString = .{ .ptr = null, .len = 0 },
    kind: u8,
    reserved: [7]u8 = .{ 0, 0, 0, 0, 0, 0, 0 },
};

pub const FetchResponseInit = extern struct {
    response: ResponseInit,
    body_identity: FetchBodyIdentity,
};

pub const extracted_response_body_empty: u32 = 0;
pub const extracted_response_body_bytes: u32 = 1;
pub const extracted_response_body_byte_segments: u32 = 2;
pub const extracted_response_body_fetch_stream: u32 = 3;

pub const ByteSegment = extern struct {
    bytes: RawBuffer = .{ .ptr = null, .len = 0 },

    pub fn slice(self: ByteSegment) []const u8 {
        return rawBufferSlice(self.bytes);
    }
};

pub const ExtractedResponseBody = extern struct {
    kind: u32 = extracted_response_body_empty,
    flags: u32 = 0,
    total_len: usize = 0,
    segments: ?[*]const ByteSegment = null,
    segments_len: usize = 0,
    owner: ?*RawOwnedByteSegments = null,
    stream_identity: FetchBodyIdentity = .{
        .request_id = 0,
        .request_generation = 0,
        .fetch_id = 0,
        .body_id = 0,
    },

    pub fn deinit(self: *ExtractedResponseBody) void {
        if (self.owner) |owner| {
            collo_owned_byte_segments_destroy(owner);
        }
        self.* = .{};
    }

    pub fn segmentsSlice(self: ExtractedResponseBody) []const ByteSegment {
        return if (self.segments) |ptr| ptr[0..self.segments_len] else &.{};
    }

    pub fn firstContiguousSlice(self: ExtractedResponseBody) []const u8 {
        const segments_slice = self.segmentsSlice();
        if (segments_slice.len == 0) return "";
        if (segments_slice.len == 1) return segments_slice[0].slice();
        return "";
    }

    pub fn hasFetchBodyStream(self: ExtractedResponseBody) bool {
        return self.kind == extracted_response_body_fetch_stream;
    }
};

pub const HeaderView = extern struct {
    name_offset: u32 = 0,
    name_len: u32 = 0,
    value_offset: u32 = 0,
    value_len: u32 = 0,
    flags: u32 = 0,
};

pub const ExtractedHeaderBlock = extern struct {
    storage: RawBuffer = .{ .ptr = null, .len = 0 },
    headers: ?[*]const HeaderView = null,
    headers_len: usize = 0,
    owner: ?*RawOwnedHeaderBlock = null,

    pub fn deinit(self: *ExtractedHeaderBlock) void {
        if (self.owner) |owner| {
            collo_owned_header_block_destroy(owner);
        }
        self.* = .{};
    }

    pub fn storageSlice(self: ExtractedHeaderBlock) []const u8 {
        return rawBufferSlice(self.storage);
    }

    pub fn headersSlice(self: ExtractedHeaderBlock) []const HeaderView {
        return if (self.headers) |ptr| ptr[0..self.headers_len] else &.{};
    }

    pub fn nameSlice(self: ExtractedHeaderBlock, view: HeaderView) []const u8 {
        const storage_slice = self.storageSlice();
        const offset: usize = @intCast(view.name_offset);
        const len: usize = @intCast(view.name_len);
        return storage_slice[offset..][0..len];
    }

    pub fn valueSlice(self: ExtractedHeaderBlock, view: HeaderView) []const u8 {
        const storage_slice = self.storageSlice();
        const offset: usize = @intCast(view.value_offset);
        const len: usize = @intCast(view.value_len);
        return storage_slice[offset..][0..len];
    }
};

pub const ExtractedResponse = extern struct {
    body: ExtractedResponseBody = .{},
    headers: ExtractedHeaderBlock = .{},
    status: u16 = 0,
    reserved0: u16 = 0,
    reserved1: u32 = 0,

    pub fn deinit(self: *ExtractedResponse) void {
        collo_response_extract_free(self);
    }

    pub fn bodySlice(self: ExtractedResponse) []const u8 {
        return self.body.firstContiguousSlice();
    }

    pub fn bodySegmentsSlice(self: ExtractedResponse) []const ByteSegment {
        return self.body.segmentsSlice();
    }

    pub fn headersSlice(self: ExtractedResponse) []const HeaderView {
        return self.headers.headersSlice();
    }

    pub fn hasFetchBodyStream(self: ExtractedResponse) bool {
        return self.body.hasFetchBodyStream();
    }

    pub fn takeBody(self: *ExtractedResponse) ExtractedResponseBody {
        const body = self.body;
        self.body = .{};
        return body;
    }

    pub fn takeHeaders(self: *ExtractedResponse) ExtractedHeaderBlock {
        const headers = self.headers;
        self.headers = .{};
        return headers;
    }
};

pub const ResponseExtractLimits = extern struct {
    max_body_bytes: usize,
    max_header_count: usize,
    max_header_bytes: usize,
};

extern fn collo_vm_create(options: *const VmOptions, out_vm: *?*RawVm) RawStatus;
extern fn collo_vm_destroy(vm: *RawVm) void;
extern fn collo_vm_main_realm(vm: *RawVm) ?*RawRealm;
extern fn collo_realm_create(vm: *RawVm, out_realm: *?*RawRealm) RawStatus;
extern fn collo_realm_index(realm: *const RawRealm) u32;
extern fn collo_vm_prepare_for_fork(vm: *RawVm) RawStatus;
extern fn collo_vm_post_fork_child(vm: *RawVm) RawStatus;
extern fn collo_vm_reseed_after_fork(vm: *RawVm, seeds: *const RandomSeeds) RawStatus;
extern fn collo_vm_prespawn_compiler_threads(vm: *RawVm) RawStatus;
extern fn collo_vm_collect_full_gc_and_trim(vm: *RawVm) RawStatus;
extern fn collo_vm_collect_eden_gc(vm: *RawVm) RawStatus;
extern fn collo_vm_request_termination(vm: *RawVm) RawStatus;
extern fn collo_vm_set_host_runtime(vm: *RawVm, runtime: ?*anyopaque) RawStatus;
extern fn collo_vm_set_boot_exec_ctx(vm: *RawVm, request_id: u64) RawStatus;
extern fn collo_vm_clear_boot_exec_ctx(vm: *RawVm) RawStatus;
extern fn collo_vm_release_exec_ctx(vm: *RawVm, exec_ctx: *ExecCtx) RawStatus;
extern fn collo_vm_owner_crossings(vm: *RawVm) u64;
extern fn collo_vm_set_owner_transition_hook(
    vm: *RawVm,
    hook: ?OwnerTransitionHook,
    ctx: ?*anyopaque,
) RawStatus;
extern fn collo_vm_set_console_sink(
    vm: *RawVm,
    sink: ?ConsoleSink,
    sink_ctx: ?*anyopaque,
    line_bytes_max: usize,
    request_lines_max: usize,
    request_bytes_max: usize,
) RawStatus;
extern fn collo_vm_install_process(vm: *RawVm) RawStatus;
extern fn collo_vm_enable_node_fs_for_worker(vm: *RawVm) RawStatus;
extern fn collo_prepare_process_for_fork() RawStatus;
extern fn collo_set_helper_threads_timeout_override_ns(timeout_ns: u64) RawStatus;
extern fn collo_clear_helper_threads_timeout_override() void;
extern fn collo_set_gc_max_heap_size_override_bytes(bytes: u64) RawStatus;
extern fn collo_clear_gc_max_heap_size_override() void;

extern fn collo_tool_generate_module_bytecode(
    source: RawBuffer,
    specifier: RawString,
    out_bytes: *?[*]u8,
    out_len: *usize,
) RawStatus;
extern fn collo_tool_bytecode_release(bytes: ?[*]u8) void;

extern fn collo_module_register_pack(vm: *RawVm, pack: Mapping, options: *const ModuleRegisterOptions) RawStatus;
extern fn collo_module_evict_specifier(vm: *RawVm, specifier: RawString, out_stats: *ModuleEvictStats) RawStatus;
extern fn collo_module_evict_lifetime(vm: *RawVm, lifetime: u8, out_stats: *ModuleEvictStats) RawStatus;
extern fn collo_module_evaluate(realm: *RawRealm, specifier: RawString, out_exception: *?*RawValue) RawStatus;
extern fn collo_module_get_export(realm: *RawRealm, specifier: RawString, export_name: RawString, out_value: *?*RawValue, out_exception: *?*RawValue) RawStatus;

extern fn collo_turn_enter(vm: *RawVm, exec_ctx: *ExecCtx) RawStatus;
extern fn collo_invoke(vm: *RawVm, expected_ctx: *const ExecCtx, callable: *const RawValue, this_value: ?*const RawValue, argv: ?[*]const ?*const RawValue, argc: usize, out_result: *?*RawValue, out_exception: *?*RawValue, out_call_started_ns: ?*u64) RawStatus;
extern fn collo_turn_exit_ex(vm: *RawVm, out_exception: *?*RawValue) RawStatus;
extern fn collo_vm_deferred_work_scheduled(vm: *RawVm) u32;
extern fn collo_vm_set_deferred_work_wakeup_fd(vm: *RawVm, wakeup_fd: i32) RawStatus;
extern fn collo_vm_pump_deferred_work(vm: *RawVm, exec_ctx: *ExecCtx, out_state: *u32, out_exception: *?*RawValue) RawStatus;

extern fn collo_value_retain(value: *RawValue, out_value: *?*RawValue) RawStatus;
extern fn collo_value_release(value: *RawValue) void;
extern fn collo_value_is_callable(vm: *RawVm, value: *const RawValue, out_is_callable: *u8) RawStatus;
extern fn collo_value_is_thenable(vm: *RawVm, value: *const RawValue, out_is_thenable: *u8, out_exception: *?*RawValue) RawStatus;
extern fn collo_promise_await_sync(vm: *RawVm, promise: *const RawValue, out_value: *?*RawValue, out_exception: *?*RawValue) RawStatus;
extern fn collo_promise_deferred_resolve(vm: *RawVm, deferred: *RawPromiseDeferred, value: *const RawValue, out_exception: *?*RawValue) RawStatus;
extern fn collo_promise_deferred_reject(vm: *RawVm, deferred: *RawPromiseDeferred, reason: *const RawValue, out_exception: *?*RawValue) RawStatus;
extern fn collo_promise_deferred_realm(deferred: *const RawPromiseDeferred) ?*RawRealm;
extern fn collo_promise_deferred_release(deferred: *RawPromiseDeferred) void;
extern fn collo_request_task_settle_thenable(vm: *RawVm, token: *const RequestCompletionToken, value: *const RawValue, out_exception: *?*RawValue) RawStatus;
extern fn collo_crypto_job_run(job: *RawCryptoJob) void;
extern fn collo_crypto_job_settle(vm: *RawVm, job: *RawCryptoJob, out_exception: *?*RawValue) RawStatus;
extern fn collo_crypto_job_destroy(job: *RawCryptoJob) void;
extern fn collo_json_parse_utf8(realm: *RawRealm, source: RawString, out_value: *?*RawValue, out_exception: *?*RawValue) RawStatus;

extern fn collo_undefined(vm: *RawVm, out_value: *?*RawValue) RawStatus;
extern fn collo_null(vm: *RawVm, out_value: *?*RawValue) RawStatus;
extern fn collo_bool_new(vm: *RawVm, value: u8, out_value: *?*RawValue) RawStatus;
extern fn collo_number_new(vm: *RawVm, value: f64, out_value: *?*RawValue) RawStatus;
extern fn collo_string_new_utf8(vm: *RawVm, utf8: RawString, out_value: *?*RawValue) RawStatus;
extern fn collo_type_error_new_utf8(realm: *RawRealm, message: RawString, out_value: *?*RawValue) RawStatus;
extern fn collo_array_buffer_new_copy(
    realm: *RawRealm,
    bytes: RawBuffer,
    out_value: *?*RawValue,
    out_exception: *?*RawValue,
) RawStatus;
extern fn collo_uint8_array_new_copy(
    realm: *RawRealm,
    bytes: RawBuffer,
    out_value: *?*RawValue,
    out_exception: *?*RawValue,
) RawStatus;
extern fn collo_blob_new_copy(
    realm: *RawRealm,
    bytes: RawBuffer,
    content_type: RawString,
    out_value: *?*RawValue,
    out_exception: *?*RawValue,
) RawStatus;
extern fn collo_fetch_read_result_new_copy(realm: *RawRealm, bytes: RawBuffer, done: u8, out_value: *?*RawValue, out_exception: *?*RawValue) RawStatus;
extern fn collo_form_data_new_from_bytes(realm: *RawRealm, bytes: RawBuffer, content_type: RawString, out_value: *?*RawValue, out_exception: *?*RawValue) RawStatus;
extern fn collo_object_new(realm: *RawRealm, out_value: *?*RawValue) RawStatus;
extern fn collo_array_new(realm: *RawRealm, out_value: *?*RawValue) RawStatus;
extern fn collo_global_this(realm: *RawRealm, out_value: *?*RawValue) RawStatus;
extern fn collo_env_object_new(realm: *RawRealm, entries: ?[*]const NameValuePair, entry_count: usize, out_value: *?*RawValue) RawStatus;

extern fn collo_object_get_utf8(vm: *RawVm, object: *const RawValue, key: RawString, out_value: *?*RawValue, out_exception: *?*RawValue) RawStatus;
extern fn collo_object_set_utf8(vm: *RawVm, object: *const RawValue, key: RawString, value: *const RawValue, out_exception: *?*RawValue) RawStatus;
extern fn collo_array_set(vm: *RawVm, array: *const RawValue, index: usize, value: *const RawValue, out_exception: *?*RawValue) RawStatus;

extern fn collo_value_to_utf8_copy(vm: *RawVm, value: *const RawValue, out_string: *RawString, out_exception: *?*RawValue) RawStatus;
extern fn collo_exception_format(vm: *RawVm, exception: *const RawValue, out_string: *RawString) RawStatus;
extern fn collo_free_buffer(ptr: ?*const anyopaque) void;
extern fn collo_request_new(realm: *RawRealm, init: *const RequestInit, out_value: *?*RawValue, out_exception: *?*RawValue) RawStatus;
extern fn collo_response_new(realm: *RawRealm, init: *const ResponseInit, out_value: *?*RawValue, out_exception: *?*RawValue) RawStatus;
extern fn collo_fetch_response_new(realm: *RawRealm, init: *const FetchResponseInit, out_value: *?*RawValue, out_exception: *?*RawValue) RawStatus;
extern fn collo_response_extract(vm: *RawVm, value: *const RawValue, limits: *const ResponseExtractLimits, out_response: *ExtractedResponse, out_exception: *?*RawValue) RawStatus;
extern fn collo_response_extract_free(response: *ExtractedResponse) void;
extern fn collo_owned_byte_segments_destroy(owner: *RawOwnedByteSegments) void;
extern fn collo_owned_header_block_destroy(owner: *RawOwnedHeaderBlock) void;
extern fn collo_webapi_cleanup_request(vm: *RawVm, request_id: u64) RawStatus;
extern fn collo_webapi_immediate_mark_destroyed(vm: *RawVm, value: *const RawValue) RawStatus;

comptime {
    if (@sizeOf(Mapping) != 16)
        @compileError("Mapping ABI size mismatch");
    if (@offsetOf(Mapping, "ptr") != 0)
        @compileError("Mapping.ptr offset mismatch");
    if (@offsetOf(Mapping, "len") != 8)
        @compileError("Mapping.len offset mismatch");
    if (@sizeOf(ExecCtx) != 40)
        @compileError("ExecCtx ABI size mismatch");
    if (@offsetOf(ExecCtx, "request_id") != 0)
        @compileError("ExecCtx.request_id offset mismatch");
    if (@offsetOf(ExecCtx, "deadline_monotonic_ns") != 8)
        @compileError("ExecCtx.deadline_monotonic_ns offset mismatch");
    if (@offsetOf(ExecCtx, "cpu_used_ns_total") != 16)
        @compileError("ExecCtx.cpu_used_ns_total offset mismatch");
    if (@offsetOf(ExecCtx, "turn_cpu_start_ns") != 24)
        @compileError("ExecCtx.turn_cpu_start_ns offset mismatch");
    if (@offsetOf(ExecCtx, "termination_reason") != 32)
        @compileError("ExecCtx.termination_reason offset mismatch");
    if (@offsetOf(ExecCtx, "_reserved") != 33)
        @compileError("ExecCtx._reserved offset mismatch");
    if (@sizeOf(VmOptions) != 8)
        @compileError("VmOptions ABI size mismatch");
    if (@offsetOf(VmOptions, "abi_version") != 0)
        @compileError("VmOptions.abi_version offset mismatch");
    if (@offsetOf(VmOptions, "flags") != 4)
        @compileError("VmOptions.flags offset mismatch");
    if (@sizeOf(RandomSeeds) != 12)
        @compileError("RandomSeeds ABI size mismatch");
    if (@sizeOf(RequestCompletionToken) != 24)
        @compileError("RequestCompletionToken ABI size mismatch");
    if (@offsetOf(RequestCompletionToken, "slot") != 0)
        @compileError("RequestCompletionToken.slot offset mismatch");
    if (@offsetOf(RequestCompletionToken, "generation") != 4)
        @compileError("RequestCompletionToken.generation offset mismatch");
    if (@offsetOf(RequestCompletionToken, "request_id") != 8)
        @compileError("RequestCompletionToken.request_id offset mismatch");
    if (@offsetOf(RequestCompletionToken, "request_generation") != 16)
        @compileError("RequestCompletionToken.request_generation offset mismatch");
    if (@sizeOf(RequestIdentity) != 16)
        @compileError("RequestIdentity ABI size mismatch");
    if (@offsetOf(RequestIdentity, "request_id") != 0)
        @compileError("RequestIdentity.request_id offset mismatch");
    if (@offsetOf(RequestIdentity, "request_generation") != 8)
        @compileError("RequestIdentity.request_generation offset mismatch");
    if (@sizeOf(ModuleRegisterOptions) != 12)
        @compileError("ModuleRegisterOptions ABI size mismatch");
    if (@offsetOf(ModuleRegisterOptions, "abi_size") != 0)
        @compileError("ModuleRegisterOptions.abi_size offset mismatch");
    if (@offsetOf(ModuleRegisterOptions, "lifetime") != 4)
        @compileError("ModuleRegisterOptions.lifetime offset mismatch");
    if (@offsetOf(ModuleRegisterOptions, "module_type") != 5)
        @compileError("ModuleRegisterOptions.module_type offset mismatch");
    if (@offsetOf(ModuleRegisterOptions, "reserved0") != 6)
        @compileError("ModuleRegisterOptions.reserved0 offset mismatch");
    if (@offsetOf(ModuleRegisterOptions, "flags") != 8)
        @compileError("ModuleRegisterOptions.flags offset mismatch");
    if (@sizeOf(ModuleEvictStats) != 16)
        @compileError("ModuleEvictStats ABI size mismatch");
    if (@offsetOf(ModuleEvictStats, "sources_removed") != 0)
        @compileError("ModuleEvictStats.sources_removed offset mismatch");
    if (@offsetOf(ModuleEvictStats, "namespaces_removed") != 8)
        @compileError("ModuleEvictStats.namespaces_removed offset mismatch");
    if (@sizeOf(NameValuePair) != 32)
        @compileError("NameValuePair ABI size mismatch");
    if (@offsetOf(NameValuePair, "name") != 0)
        @compileError("NameValuePair.name offset mismatch");
    if (@offsetOf(NameValuePair, "value") != 16)
        @compileError("NameValuePair.value offset mismatch");
    if (@sizeOf(RequestInit) != 112)
        @compileError("RequestInit ABI size mismatch");
    if (@offsetOf(RequestInit, "method") != 0)
        @compileError("RequestInit.method offset mismatch");
    if (@offsetOf(RequestInit, "path") != 16)
        @compileError("RequestInit.path offset mismatch");
    if (@offsetOf(RequestInit, "raw_query") != 32)
        @compileError("RequestInit.raw_query offset mismatch");
    if (@offsetOf(RequestInit, "authority") != 48)
        @compileError("RequestInit.authority offset mismatch");
    if (@offsetOf(RequestInit, "headers") != 64)
        @compileError("RequestInit.headers offset mismatch");
    if (@offsetOf(RequestInit, "headers_len") != 72)
        @compileError("RequestInit.headers_len offset mismatch");
    if (@offsetOf(RequestInit, "params") != 80)
        @compileError("RequestInit.params offset mismatch");
    if (@offsetOf(RequestInit, "params_len") != 88)
        @compileError("RequestInit.params_len offset mismatch");
    if (@offsetOf(RequestInit, "identity") != 96)
        @compileError("RequestInit.identity offset mismatch");
    if (@sizeOf(FetchInit) != 80)
        @compileError("FetchInit ABI size mismatch");
    if (@offsetOf(FetchInit, "request_id") != 0)
        @compileError("FetchInit.request_id offset mismatch");
    if (@offsetOf(FetchInit, "url") != 8)
        @compileError("FetchInit.url offset mismatch");
    if (@offsetOf(FetchInit, "method") != 24)
        @compileError("FetchInit.method offset mismatch");
    if (@offsetOf(FetchInit, "body") != 40)
        @compileError("FetchInit.body offset mismatch");
    if (@offsetOf(FetchInit, "headers") != 56)
        @compileError("FetchInit.headers offset mismatch");
    if (@offsetOf(FetchInit, "headers_len") != 64)
        @compileError("FetchInit.headers_len offset mismatch");
    if (@offsetOf(FetchInit, "flags") != 72)
        @compileError("FetchInit.flags offset mismatch");
    if (@offsetOf(FetchInit, "reserved0") != 76)
        @compileError("FetchInit.reserved0 offset mismatch");
    if (@sizeOf(ResponseInit) != 72)
        @compileError("ResponseInit ABI size mismatch");
    if (@offsetOf(ResponseInit, "body") != 0)
        @compileError("ResponseInit.body offset mismatch");
    if (@offsetOf(ResponseInit, "status_text") != 16)
        @compileError("ResponseInit.status_text offset mismatch");
    if (@offsetOf(ResponseInit, "url") != 32)
        @compileError("ResponseInit.url offset mismatch");
    if (@offsetOf(ResponseInit, "headers") != 48)
        @compileError("ResponseInit.headers offset mismatch");
    if (@offsetOf(ResponseInit, "headers_len") != 56)
        @compileError("ResponseInit.headers_len offset mismatch");
    if (@offsetOf(ResponseInit, "status") != 64)
        @compileError("ResponseInit.status offset mismatch");
    if (@offsetOf(ResponseInit, "flags") != 66)
        @compileError("ResponseInit.flags offset mismatch");
    if (@sizeOf(FetchBodyIdentity) != 32)
        @compileError("FetchBodyIdentity ABI size mismatch");
    if (@offsetOf(FetchBodyIdentity, "request_id") != 0)
        @compileError("FetchBodyIdentity.request_id offset mismatch");
    if (@offsetOf(FetchBodyIdentity, "request_generation") != 8)
        @compileError("FetchBodyIdentity.request_generation offset mismatch");
    if (@offsetOf(FetchBodyIdentity, "fetch_id") != 16)
        @compileError("FetchBodyIdentity.fetch_id offset mismatch");
    if (@offsetOf(FetchBodyIdentity, "body_id") != 24)
        @compileError("FetchBodyIdentity.body_id offset mismatch");
    if (@sizeOf(FetchBodyConsumeInit) != 56)
        @compileError("FetchBodyConsumeInit ABI size mismatch");
    if (@offsetOf(FetchBodyConsumeInit, "identity") != 0)
        @compileError("FetchBodyConsumeInit.identity offset mismatch");
    if (@offsetOf(FetchBodyConsumeInit, "content_type") != 32)
        @compileError("FetchBodyConsumeInit.content_type offset mismatch");
    if (@offsetOf(FetchBodyConsumeInit, "kind") != 48)
        @compileError("FetchBodyConsumeInit.kind offset mismatch");
    if (@sizeOf(FetchResponseInit) != 104)
        @compileError("FetchResponseInit ABI size mismatch");
    if (@offsetOf(FetchResponseInit, "response") != 0)
        @compileError("FetchResponseInit.response offset mismatch");
    if (@offsetOf(FetchResponseInit, "body_identity") != 72)
        @compileError("FetchResponseInit.body_identity offset mismatch");
    if (@sizeOf(ByteSegment) != 16)
        @compileError("ByteSegment ABI size mismatch");
    if (@offsetOf(ByteSegment, "bytes") != 0)
        @compileError("ByteSegment.bytes offset mismatch");
    if (@sizeOf(ExtractedResponseBody) != 72)
        @compileError("ExtractedResponseBody ABI size mismatch");
    if (@offsetOf(ExtractedResponseBody, "kind") != 0)
        @compileError("ExtractedResponseBody.kind offset mismatch");
    if (@offsetOf(ExtractedResponseBody, "flags") != 4)
        @compileError("ExtractedResponseBody.flags offset mismatch");
    if (@offsetOf(ExtractedResponseBody, "total_len") != 8)
        @compileError("ExtractedResponseBody.total_len offset mismatch");
    if (@offsetOf(ExtractedResponseBody, "segments") != 16)
        @compileError("ExtractedResponseBody.segments offset mismatch");
    if (@offsetOf(ExtractedResponseBody, "segments_len") != 24)
        @compileError("ExtractedResponseBody.segments_len offset mismatch");
    if (@offsetOf(ExtractedResponseBody, "owner") != 32)
        @compileError("ExtractedResponseBody.owner offset mismatch");
    if (@offsetOf(ExtractedResponseBody, "stream_identity") != 40)
        @compileError("ExtractedResponseBody.stream_identity offset mismatch");
    if (@sizeOf(HeaderView) != 20)
        @compileError("HeaderView ABI size mismatch");
    if (@offsetOf(HeaderView, "name_offset") != 0)
        @compileError("HeaderView.name_offset offset mismatch");
    if (@offsetOf(HeaderView, "name_len") != 4)
        @compileError("HeaderView.name_len offset mismatch");
    if (@offsetOf(HeaderView, "value_offset") != 8)
        @compileError("HeaderView.value_offset offset mismatch");
    if (@offsetOf(HeaderView, "value_len") != 12)
        @compileError("HeaderView.value_len offset mismatch");
    if (@offsetOf(HeaderView, "flags") != 16)
        @compileError("HeaderView.flags offset mismatch");
    if (@sizeOf(ExtractedHeaderBlock) != 40)
        @compileError("ExtractedHeaderBlock ABI size mismatch");
    if (@offsetOf(ExtractedHeaderBlock, "storage") != 0)
        @compileError("ExtractedHeaderBlock.storage offset mismatch");
    if (@offsetOf(ExtractedHeaderBlock, "headers") != 16)
        @compileError("ExtractedHeaderBlock.headers offset mismatch");
    if (@offsetOf(ExtractedHeaderBlock, "headers_len") != 24)
        @compileError("ExtractedHeaderBlock.headers_len offset mismatch");
    if (@offsetOf(ExtractedHeaderBlock, "owner") != 32)
        @compileError("ExtractedHeaderBlock.owner offset mismatch");
    if (@sizeOf(ExtractedResponse) != 120)
        @compileError("ExtractedResponse ABI size mismatch");
    if (@offsetOf(ExtractedResponse, "body") != 0)
        @compileError("ExtractedResponse.body offset mismatch");
    if (@offsetOf(ExtractedResponse, "headers") != 72)
        @compileError("ExtractedResponse.headers offset mismatch");
    if (@offsetOf(ExtractedResponse, "status") != 112)
        @compileError("ExtractedResponse.status offset mismatch");
    if (@offsetOf(ExtractedResponse, "reserved0") != 114)
        @compileError("ExtractedResponse.reserved0 offset mismatch");
    if (@offsetOf(ExtractedResponse, "reserved1") != 116)
        @compileError("ExtractedResponse.reserved1 offset mismatch");
    if (@sizeOf(ResponseExtractLimits) != 24)
        @compileError("ResponseExtractLimits ABI size mismatch");
    if (@offsetOf(ResponseExtractLimits, "max_body_bytes") != 0)
        @compileError("ResponseExtractLimits.max_body_bytes offset mismatch");
    if (@offsetOf(ResponseExtractLimits, "max_header_count") != 8)
        @compileError("ResponseExtractLimits.max_header_count offset mismatch");
    if (@offsetOf(ResponseExtractLimits, "max_header_bytes") != 16)
        @compileError("ResponseExtractLimits.max_header_bytes offset mismatch");
}

pub const OwnedString = struct {
    raw: RawString = .{ .ptr = null, .len = 0 },

    pub fn deinit(self: *OwnedString) void {
        if (self.raw.ptr) |ptr|
            collo_free_buffer(@ptrCast(ptr));
        self.* = .{};
    }

    pub fn slice(self: OwnedString) []const u8 {
        return if (self.raw.ptr) |ptr| ptr[0..self.raw.len] else "";
    }
};

pub const OwnedBuffer = struct {
    raw: RawBuffer = .{ .ptr = null, .len = 0 },

    pub fn deinit(self: *OwnedBuffer) void {
        if (self.raw.ptr) |ptr|
            collo_free_buffer(@ptrCast(ptr));
        self.* = .{};
    }

    pub fn slice(self: OwnedBuffer) []const u8 {
        return if (self.raw.ptr) |ptr| ptr[0..self.raw.len] else "";
    }
};

pub const Value = struct {
    handle: ?*RawValue = null,

    pub fn fromRawOwned(raw: ?*RawValue) Error!Value {
        return .{ .handle = raw orelse return error.Internal };
    }

    pub fn fromRawOwnedNonNull(raw: *RawValue) Value {
        return .{ .handle = raw };
    }

    pub fn deinit(self: *Value) void {
        if (self.handle) |raw_value|
            collo_value_release(raw_value);
        self.* = .{};
    }

    pub fn retain(self: Value) Error!Value {
        var retained: ?*RawValue = null;
        try statusToError(collo_value_retain(try self.ptr(), &retained));
        return try Value.fromRawOwned(retained);
    }

    fn ptr(self: Value) Error!*RawValue {
        return self.handle orelse error.InvalidJsValue;
    }

    fn ptrConst(self: *const Value) Error!*const RawValue {
        return self.handle orelse error.InvalidJsValue;
    }
};

pub const EvalResult = union(enum) {
    success,
    exception: Value,
    unsupported: Value,
    /// A top-level await is in flight. Exports are live bindings and must
    /// not be read until the settlement callback fires.
    pending,
};

pub const ValueResult = union(enum) {
    success: Value,
    exception: Value,
};

pub const ExtractResponseResult = union(enum) {
    success: ExtractedResponse,
    exception: Value,
};

pub const PromiseResult = union(enum) {
    success: Value,
    exception: Value,
    unsupported: Value,
};

pub const VoidResult = union(enum) {
    success,
    exception: Value,
};

/// What the engine's DeferredWorkTimer still holds after a pump pass, from
/// the `COLLO_DEFERRED_WORK_*` bits.
pub const DeferredWorkState = struct {
    /// Tickets pending anywhere: a compile in flight or a settlement queued.
    pending_any: bool,
    /// Pending tickets whose completion comes from the wasm worklist thread.
    /// While set, the loop keeps a re-check armed instead of sleeping without
    /// a bound; the wakeup fd is the fast path.
    pending_imminent: bool,

    pub const none = DeferredWorkState{ .pending_any = false, .pending_imminent = false };

    fn fromRaw(raw: u32) DeferredWorkState {
        return .{
            .pending_any = (raw & 0x1) != 0,
            .pending_imminent = (raw & 0x2) != 0,
        };
    }
};

pub const BoolResult = union(enum) {
    success: bool,
    exception: Value,
};

pub const StringResult = union(enum) {
    success: OwnedString,
    exception: Value,
};

/// Console line levels, the `COLLO_CONSOLE_*` values of `ColloConsoleLevel`.
pub const ConsoleLevel = enum(u8) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,
};

/// Flags the console sink receives. Bit 0: the line was truncated at the
/// registered byte budget. Bit 1: the per-request output budget dropped the
/// line, and the call is only a marker to count (bytes null, len 0). The two
/// bits are never set together.
pub const console_line_flag_truncated: u8 = 1 << 0;
pub const console_line_flag_budget_dropped: u8 = 1 << 1;

/// Called in pairs whenever a microtask drain hands execution from one
/// request to another and back. Either side may be null, which is turnless
/// execution: module evaluation, or an owner whose request already ended.
/// Runs on the VM thread with the JS lock held and must not re-enter the VM.
pub const OwnerTransitionHook = *const fn (
    ctx: ?*anyopaque,
    leaving: ?*ExecCtx,
    entering: ?*ExecCtx,
) callconv(.c) void;

/// Receives one formatted UTF-8 console line, synchronously on the VM thread
/// while the turn is live. `bytes` is borrowed for the call only; the sink
/// must not call back into the VM.
pub const ConsoleSink = *const fn (
    ctx: ?*anyopaque,
    level: u8,
    flags: u8,
    request_id: u64,
    bytes: ?[*]const u8,
    len: usize,
) callconv(.c) void;

pub const Vm = struct {
    raw: ?*RawVm = null,

    pub fn create(options: VmOptions) Error!Vm {
        var raw_vm: ?*RawVm = null;
        try statusToError(collo_vm_create(&options, &raw_vm));
        return .{ .raw = raw_vm orelse return error.Internal };
    }

    pub fn createDefault() Error!Vm {
        return create(VmOptions.init());
    }

    pub fn deinit(self: *Vm) void {
        if (self.raw) |raw_vm|
            collo_vm_destroy(raw_vm);
        self.* = .{};
    }

    /// The realm created with the VM.
    pub fn mainRealm(self: *Vm) Realm {
        return .{ .raw = collo_vm_main_realm(self.ptr()).? };
    }

    /// Adds a realm with every install the VM made so far, outside any turn
    /// (`collo_realm_create` in `abi.h`). It lives as long as the VM.
    pub fn createRealm(self: *Vm) Error!Realm {
        var raw_realm: ?*RawRealm = null;
        try statusToError(collo_realm_create(self.ptr(), &raw_realm));
        return .{ .raw = raw_realm orelse return error.Internal };
    }

    pub fn prepareForFork(self: *Vm) Error!void {
        try statusToError(collo_vm_prepare_for_fork(self.ptr()));
    }

    pub fn postForkChild(self: *Vm) Error!void {
        try statusToError(collo_vm_post_fork_child(self.ptr()));
    }

    pub fn reseedAfterFork(self: *Vm, seeds: RandomSeeds) Error!void {
        try statusToError(collo_vm_reseed_after_fork(self.ptr(), &seeds));
    }

    /// Creates every compiler thread the process will use, for the
    /// JavaScript tiers and wasm, without compiling anything; each polls
    /// once, finds nothing and parks. A worker calls it after the sandbox's
    /// privilege drop and before seccomp, with the helper-thread timeout
    /// override pinned so no thread retires in between. Idempotent.
    pub fn prespawnCompilerThreads(self: *Vm) Error!void {
        try statusToError(collo_vm_prespawn_compiler_threads(self.ptr()));
    }

    pub fn collectFullGCAndTrim(self: *Vm) Error!void {
        try statusToError(collo_vm_collect_full_gc_and_trim(self.ptr()));
    }

    /// Collects only the cells allocated since the last collection. Outside a
    /// turn; see `collo_vm_collect_eden_gc` in abi.h.
    pub fn collectEdenGC(self: *Vm) Error!void {
        try statusToError(collo_vm_collect_eden_gc(self.ptr()));
    }

    /// Asks the VM to stop running JavaScript, from any thread. The caller
    /// keeps the VM alive across the call; once its destruction began, the
    /// call fails with `error.InvalidArgument`.
    pub fn requestTermination(self: *Vm) Error!void {
        try statusToError(collo_vm_request_termination(self.ptr()));
    }

    pub fn setHostRuntime(self: *Vm, runtime: ?*anyopaque) Error!void {
        try statusToError(collo_vm_set_host_runtime(self.ptr(), runtime));
    }

    /// Installs the boot identity that turnless JavaScript, module evaluation
    /// and its drains, resolves to. Workers only; the zygote's warmup VM
    /// never calls it.
    pub fn setBootExecCtx(self: *Vm, request_id: u64) Error!void {
        try statusToError(collo_vm_set_boot_exec_ctx(self.ptr(), request_id));
    }

    /// Uninstalls the boot identity when the boot context closes, so turnless
    /// JavaScript finds no context from then on. Idempotent, so it is safe
    /// after an install that failed.
    pub fn clearBootExecCtx(self: *Vm) Error!void {
        try statusToError(collo_vm_clear_boot_exec_ctx(self.ptr()));
    }

    /// Drops the microtask-owner registration for `exec_ctx`, which must
    /// happen before its storage dies: a promise reaction this request
    /// registered can outlive it, as when a later request settles a
    /// module-scope promise, and a released token resolves to "no owner"
    /// instead of reading freed memory. Idempotent.
    pub fn releaseExecCtx(self: *Vm, exec_ctx: *ExecCtx) Error!void {
        try statusToError(collo_vm_release_exec_ctx(self.ptr(), exec_ctx));
    }

    pub fn setOwnerTransitionHook(
        self: *Vm,
        hook: ?OwnerTransitionHook,
        ctx: ?*anyopaque,
    ) Error!void {
        try statusToError(collo_vm_set_owner_transition_hook(self.ptr(), hook, ctx));
    }

    /// Microtasks this VM ran under a restored owner: promise reactions whose
    /// registrant was not the request draining the queue. Monotonic and
    /// never reset, it counts how often the owner hand-over runs.
    pub fn ownerCrossings(self: *Vm) u64 {
        return collo_vm_owner_crossings(self.ptr());
    }

    /// Stable opaque identity of the underlying VM, for registrations that
    /// must match "the same VM" without holding the wrapper by pointer.
    pub fn rawIdentity(self: *const Vm) ?*const anyopaque {
        return self.raw;
    }

    /// Routes the VM's built-in console into `sink`. Workers only: the
    /// zygote's warmup VM never registers one, so its console prints
    /// nothing. `line_bytes_max` is the per-line UTF-8 budget the bridge's
    /// formatter truncates at; `request_lines_max` and `request_bytes_max`
    /// are the per-request output budgets, past which further lines of that
    /// request arrive only as `console_line_flag_budget_dropped` markers. All
    /// three must be above 0 with a sink. A null sink unregisters.
    pub fn setConsoleSink(
        self: *Vm,
        sink: ?ConsoleSink,
        sink_ctx: ?*anyopaque,
        line_bytes_max: usize,
        request_lines_max: usize,
        request_bytes_max: usize,
    ) Error!void {
        try statusToError(collo_vm_set_console_sink(
            self.ptr(),
            sink,
            sink_ctx,
            line_bytes_max,
            request_lines_max,
            request_bytes_max,
        ));
    }

    /// Installs the worker's `process` global with an empty `env`.
    pub fn installProcess(self: *Vm) Error!void {
        try statusToError(collo_vm_install_process(self.ptr()));
    }

    pub fn enableNodeFsForWorker(self: *Vm) Error!void {
        try statusToError(collo_vm_enable_node_fs_for_worker(self.ptr()));
    }

    pub fn registerModulePack(self: *Vm, pack: []const u8) Error!void {
        try self.registerModulePackWithOptions(pack, .{});
    }

    /// Registers the modules of a pack mapping and consumes `pack` on every
    /// path, error included: the bridge keeps it while any registered module
    /// reads from it and releases it otherwise, so the caller must not read
    /// `pack` afterwards. Workers load their definition's pack this way: every
    /// worker of a definition maps the same sealed memfd, and providers that
    /// read the mapping in place keep those pages in the shared page cache. The
    /// `local-e2e` benchmark "private bytes per byte of module pack" measures
    /// what a worker pays per pack byte.
    pub fn registerModulePackMapping(self: *Vm, pack: Mapping, options: ModuleRegisterOptions) Error!void {
        var raw_options = options;
        raw_options.abi_size = @sizeOf(ModuleRegisterOptions);
        try statusToError(collo_module_register_pack(self.ptr(), pack, &raw_options));
    }

    /// Registers a pack held in memory by sealing it into a memfd and mapping
    /// that, so the bridge sees one representation of a pack wherever it came
    /// from. For callers that own bytes rather than an fd: the zygote's warmup
    /// pack and tests.
    pub fn registerModulePackWithOptions(self: *Vm, pack: []const u8, options: ModuleRegisterOptions) Error!void {
        if (pack.len == 0) return error.InvalidArgument;
        const fd = try sealedMemfdFromBytes(pack);
        defer std.posix.close(fd);
        const mapping = Mapping.map(fd, pack.len) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Internal,
        };
        try self.registerModulePackMapping(mapping, options);
    }

    pub fn evictModuleSpecifier(self: *Vm, specifier: []const u8) Error!ModuleEvictStats {
        var stats: ModuleEvictStats = .{};
        try statusToError(collo_module_evict_specifier(self.ptr(), borrowedString(specifier), &stats));
        return stats;
    }

    pub fn evictModulesByLifetime(self: *Vm, lifetime: ModuleLifetime) Error!ModuleEvictStats {
        var stats: ModuleEvictStats = .{};
        try statusToError(collo_module_evict_lifetime(self.ptr(), @intFromEnum(lifetime), &stats));
        return stats;
    }

    pub fn turnEnter(self: *Vm, exec_ctx: *ExecCtx) Error!void {
        try statusToError(collo_turn_enter(self.ptr(), exec_ctx));
    }

    pub fn turnExitResult(self: *Vm) Error!VoidResult {
        var exception: ?*RawValue = null;
        return switch (collo_turn_exit_ex(self.ptr(), &exception)) {
            status_ok => .success,
            status_js_exception => .{ .exception = try Value.fromRawOwned(exception) },
            else => |status| {
                try statusToError(status);
                unreachable;
            },
        };
    }

    /// Exits the turn and turns a JavaScript exception into
    /// `error.JsException`, releasing the value; `turnExitResult` returns it
    /// instead.
    pub fn turnExit(self: *Vm) Error!void {
        switch (try self.turnExitResult()) {
            .success => {},
            .exception => |exception| {
                var owned = exception;
                owned.deinit();
                return error.JsException;
            },
        }
    }

    /// Consumes the per-VM pending flag, which the wake notification sets
    /// before it writes the eventfd. True when deferred work was scheduled
    /// since the last call. Never takes the JS lock, so the scheduler calls
    /// it on every tick.
    pub fn deferredWorkScheduled(self: *Vm) bool {
        return collo_vm_deferred_work_scheduled(self.ptr()) != 0;
    }

    /// Registers `wakeup_fd`, which the VM writes after setting the pending
    /// flag whenever deferred work is scheduled, including from the wasm
    /// worklist thread. It wakes a worker loop blocked in its ring wait, the
    /// job a RunLoop does elsewhere. A new registration replaces the old
    /// one; a negative fd unregisters, and must come before the fd is closed,
    /// as `Runtime.deinit` does.
    pub fn setDeferredWorkWakeupFd(self: *Vm, wakeup_fd: std.posix.fd_t) Error!void {
        try statusToError(collo_vm_set_deferred_work_wakeup_fd(self.ptr(), wakeup_fd));
    }

    /// Runs every ready deferred task, such as a wasm promise settlement, as
    /// one turn on `exec_ctx`, and reports what remains pending. The engine's
    /// ticket carries no request identity, so the caller decides whose turn
    /// it is. An exception from the end-of-turn microtask drain comes back as
    /// from `turnExitResult`.
    pub fn pumpDeferredWork(
        self: *Vm,
        exec_ctx: *ExecCtx,
        out_state: *DeferredWorkState,
    ) Error!VoidResult {
        var raw_state: u32 = 0;
        var exception: ?*RawValue = null;
        const status = collo_vm_pump_deferred_work(self.ptr(), exec_ctx, &raw_state, &exception);
        out_state.* = DeferredWorkState.fromRaw(raw_state);
        return switch (status) {
            status_ok => .success,
            status_js_exception => .{ .exception = try Value.fromRawOwned(exception) },
            else => {
                try statusToError(status);
                unreachable;
            },
        };
    }

    pub fn invoke(
        self: *Vm,
        allocator: std.mem.Allocator,
        exec_ctx: *const ExecCtx,
        callable: *const Value,
        this_value: ?*const Value,
        args: []const *const Value,
    ) Error!ValueResult {
        return self.invokeWithTiming(allocator, exec_ctx, callable, this_value, args, null);
    }

    /// `invoke` that can also record when the handler started: a non-null
    /// `out_call_started_ns` receives the monotonic stamp the benchmark
    /// fixture's first-statement marker takes, which includes the engine's
    /// call preparation and the marker's own dispatch, or 0 when no marker
    /// ran (`collo_invoke` in `abi.h`).
    pub fn invokeWithTiming(
        self: *Vm,
        allocator: std.mem.Allocator,
        exec_ctx: *const ExecCtx,
        callable: *const Value,
        this_value: ?*const Value,
        args: []const *const Value,
        out_call_started_ns: ?*u64,
    ) Error!ValueResult {
        if (out_call_started_ns) |out| out.* = 0;
        var stack_args: [8]?*const RawValue = undefined;
        var heap_args: ?[]?*const RawValue = null;
        const raw_args = if (args.len <= stack_args.len)
            stack_args[0..args.len]
        else blk: {
            const allocated = try allocator.alloc(?*const RawValue, args.len);
            heap_args = allocated;
            break :blk allocated;
        };
        defer if (heap_args) |allocated| allocator.free(allocated);

        for (args, 0..) |arg, index|
            raw_args[index] = try arg.ptrConst();

        const raw_this_value = if (this_value) |value| try value.ptrConst() else null;

        var result: ?*RawValue = null;
        var exception: ?*RawValue = null;
        return switch (collo_invoke(
            self.ptr(),
            exec_ctx,
            try callable.ptrConst(),
            raw_this_value,
            if (raw_args.len == 0) null else raw_args.ptr,
            raw_args.len,
            &result,
            &exception,
            out_call_started_ns,
        )) {
            status_ok => .{ .success = try Value.fromRawOwned(result) },
            status_js_exception => .{ .exception = try Value.fromRawOwned(exception) },
            else => |status| {
                try statusToError(status);
                unreachable;
            },
        };
    }

    pub fn isCallable(self: *Vm, value: *const Value) Error!bool {
        var out_is_callable: u8 = 0;
        try statusToError(collo_value_is_callable(self.ptr(), try value.ptrConst(), &out_is_callable));
        return out_is_callable != 0;
    }

    pub fn isThenable(self: *Vm, value: *const Value) Error!BoolResult {
        var out_is_thenable: u8 = 0;
        var exception: ?*RawValue = null;
        return switch (collo_value_is_thenable(self.ptr(), try value.ptrConst(), &out_is_thenable, &exception)) {
            status_ok => .{ .success = out_is_thenable != 0 },
            status_js_exception => .{ .exception = try Value.fromRawOwned(exception) },
            else => |status| {
                try statusToError(status);
                unreachable;
            },
        };
    }

    pub fn promiseAwaitSync(self: *Vm, promise: *const Value) Error!PromiseResult {
        var value: ?*RawValue = null;
        var exception: ?*RawValue = null;
        return switch (collo_promise_await_sync(self.ptr(), try promise.ptrConst(), &value, &exception)) {
            status_ok => .{ .success = try Value.fromRawOwned(value) },
            status_js_exception => .{ .exception = try Value.fromRawOwned(exception) },
            status_unsupported => .{ .unsupported = Value.fromRawOwnedNonNull(exception orelse return error.Unsupported) },
            else => |status| {
                try statusToError(status);
                unreachable;
            },
        };
    }

    pub fn promiseDeferredResolve(self: *Vm, deferred: *RawPromiseDeferred, value: *const Value) Error!VoidResult {
        var exception: ?*RawValue = null;
        return switch (collo_promise_deferred_resolve(self.ptr(), deferred, try value.ptrConst(), &exception)) {
            status_ok => .success,
            status_js_exception => .{ .exception = try Value.fromRawOwned(exception) },
            else => |status| {
                try statusToError(status);
                unreachable;
            },
        };
    }

    pub fn promiseDeferredReject(self: *Vm, deferred: *RawPromiseDeferred, reason: *const Value) Error!VoidResult {
        var exception: ?*RawValue = null;
        return switch (collo_promise_deferred_reject(self.ptr(), deferred, try reason.ptrConst(), &exception)) {
            status_ok => .success,
            status_js_exception => .{ .exception = try Value.fromRawOwned(exception) },
            else => |status| {
                try statusToError(status);
                unreachable;
            },
        };
    }

    pub fn requestTaskSettleThenable(self: *Vm, token: RequestCompletionToken, value: *const Value) Error!VoidResult {
        var exception: ?*RawValue = null;
        return switch (collo_request_task_settle_thenable(self.ptr(), &token, try value.ptrConst(), &exception)) {
            status_ok => .success,
            status_js_exception => .{ .exception = try Value.fromRawOwned(exception) },
            else => |status| {
                try statusToError(status);
                unreachable;
            },
        };
    }

    pub fn cryptoJobSettle(self: *Vm, job: *RawCryptoJob) Error!VoidResult {
        var exception: ?*RawValue = null;
        return switch (collo_crypto_job_settle(self.ptr(), job, &exception)) {
            status_ok => .success,
            status_js_exception => .{ .exception = try Value.fromRawOwned(exception) },
            else => |status| {
                try statusToError(status);
                unreachable;
            },
        };
    }

    pub fn undefinedValue(self: *Vm) Error!Value {
        var raw_value: ?*RawValue = null;
        return outValueNoException(collo_undefined(self.ptr(), &raw_value), raw_value);
    }

    pub fn nullValue(self: *Vm) Error!Value {
        var raw_value: ?*RawValue = null;
        return outValueNoException(collo_null(self.ptr(), &raw_value), raw_value);
    }

    pub fn boolValue(self: *Vm, value: bool) Error!Value {
        var raw_value: ?*RawValue = null;
        try statusToError(collo_bool_new(self.ptr(), if (value) 1 else 0, &raw_value));
        return try Value.fromRawOwned(raw_value);
    }

    pub fn numberValue(self: *Vm, value: f64) Error!Value {
        var raw_value: ?*RawValue = null;
        try statusToError(collo_number_new(self.ptr(), value, &raw_value));
        return try Value.fromRawOwned(raw_value);
    }

    pub fn stringValueUtf8(self: *Vm, utf8: []const u8) Error!Value {
        var raw_value: ?*RawValue = null;
        try statusToError(collo_string_new_utf8(self.ptr(), borrowedString(utf8), &raw_value));
        return try Value.fromRawOwned(raw_value);
    }

    pub fn extractResponse(self: *Vm, value: *const Value, limits: ResponseExtractLimits) Error!ExtractResponseResult {
        var extracted = ExtractedResponse{};
        var exception: ?*RawValue = null;
        return switch (collo_response_extract(self.ptr(), try value.ptrConst(), &limits, &extracted, &exception)) {
            status_ok => .{ .success = extracted },
            status_js_exception => .{ .exception = try Value.fromRawOwned(exception) },
            else => |status| {
                try statusToError(status);
                unreachable;
            },
        };
    }

    pub fn cleanupWebApiRequest(self: *Vm, request_id: u64) Error!void {
        try statusToError(collo_webapi_cleanup_request(self.ptr(), request_id));
    }

    pub fn markImmediateDestroyed(self: *Vm, value: *const Value) Error!void {
        try statusToError(collo_webapi_immediate_mark_destroyed(self.ptr(), try value.ptrConst()));
    }

    pub fn objectGetUtf8(self: *Vm, object: *const Value, key: []const u8) Error!ValueResult {
        var value: ?*RawValue = null;
        var exception: ?*RawValue = null;
        return switch (collo_object_get_utf8(self.ptr(), try object.ptrConst(), borrowedString(key), &value, &exception)) {
            status_ok => .{ .success = try Value.fromRawOwned(value) },
            status_js_exception => .{ .exception = try Value.fromRawOwned(exception) },
            else => |status| {
                try statusToError(status);
                unreachable;
            },
        };
    }

    pub fn objectSetUtf8(self: *Vm, object: *const Value, key: []const u8, value: *const Value) Error!VoidResult {
        var exception: ?*RawValue = null;
        return switch (collo_object_set_utf8(self.ptr(), try object.ptrConst(), borrowedString(key), try value.ptrConst(), &exception)) {
            status_ok => .success,
            status_js_exception => .{ .exception = try Value.fromRawOwned(exception) },
            else => |status| {
                try statusToError(status);
                unreachable;
            },
        };
    }

    pub fn arraySet(self: *Vm, array: *const Value, index: usize, value: *const Value) Error!VoidResult {
        var exception: ?*RawValue = null;
        return switch (collo_array_set(self.ptr(), try array.ptrConst(), index, try value.ptrConst(), &exception)) {
            status_ok => .success,
            status_js_exception => .{ .exception = try Value.fromRawOwned(exception) },
            else => |status| {
                try statusToError(status);
                unreachable;
            },
        };
    }

    pub fn valueToUtf8Copy(self: *Vm, value: *const Value) Error!StringResult {
        var out_string = OwnedString{};
        var exception: ?*RawValue = null;
        return switch (collo_value_to_utf8_copy(self.ptr(), try value.ptrConst(), &out_string.raw, &exception)) {
            status_ok => .{ .success = out_string },
            status_js_exception => .{ .exception = try Value.fromRawOwned(exception) },
            else => |status| {
                if (out_string.raw.ptr) |raw_ptr|
                    collo_free_buffer(@ptrCast(raw_ptr));
                try statusToError(status);
                unreachable;
            },
        };
    }

    pub fn exceptionFormat(self: *Vm, exception: *const Value) Error!OwnedString {
        var out_string = OwnedString{};
        try statusToError(collo_exception_format(self.ptr(), try exception.ptrConst(), &out_string.raw));
        return out_string;
    }

    fn ptr(self: *Vm) *RawVm {
        std.debug.assert(self.raw != null);
        return self.raw.?;
    }
};

/// One realm of a `Vm`: a global object with its own globals, intrinsics and
/// module registry. Everything a realm creates belongs to its globals, so a
/// value meant for one route's code comes from that route's realm. A copy of
/// the handle names the same realm; the VM owns it.
pub const Realm = struct {
    raw: *RawRealm,

    /// The realm's position in its VM's creation order, 0 for the main realm.
    pub fn index(self: Realm) u32 {
        return collo_realm_index(self.raw);
    }

    /// Imports and evaluates `specifier` in this realm's registry, once per
    /// realm. `.pending` means a top-level await is in flight, and
    /// `collo_runtime_module_eval_settled` reports its settlement under this
    /// realm's index.
    pub fn evaluateModule(self: Realm, specifier: []const u8) Error!EvalResult {
        var exception: ?*RawValue = null;
        return switch (collo_module_evaluate(self.raw, borrowedString(specifier), &exception)) {
            status_ok => .success,
            status_js_exception => .{ .exception = try Value.fromRawOwned(exception) },
            status_unsupported => .{ .unsupported = Value.fromRawOwnedNonNull(exception orelse return error.Unsupported) },
            status_pending => .pending,
            else => |status| {
                try statusToError(status);
                unreachable;
            },
        };
    }

    pub fn moduleGetExport(self: Realm, specifier: []const u8, export_name: []const u8) Error!ValueResult {
        var value: ?*RawValue = null;
        var exception: ?*RawValue = null;
        return switch (collo_module_get_export(self.raw, borrowedString(specifier), borrowedString(export_name), &value, &exception)) {
            status_ok => .{ .success = try Value.fromRawOwned(value) },
            status_js_exception => .{ .exception = try Value.fromRawOwned(exception) },
            else => |status| {
                try statusToError(status);
                unreachable;
            },
        };
    }

    pub fn jsonParseUtf8(self: Realm, source: []const u8) Error!ValueResult {
        var value: ?*RawValue = null;
        var exception: ?*RawValue = null;
        return switch (collo_json_parse_utf8(self.raw, borrowedString(source), &value, &exception)) {
            status_ok => .{ .success = try Value.fromRawOwned(value) },
            status_js_exception => .{ .exception = try Value.fromRawOwned(exception) },
            else => |status| {
                try statusToError(status);
                unreachable;
            },
        };
    }

    /// A TypeError whose message is `message`, which may be empty. The caller
    /// owns the value. Runs no JavaScript, so it works outside a turn; invalid
    /// UTF-8 fails with `error.InvalidArgument`.
    pub fn typeErrorValueUtf8(self: Realm, message: []const u8) Error!Value {
        var raw_value: ?*RawValue = null;
        try statusToError(collo_type_error_new_utf8(self.raw, borrowedString(message), &raw_value));
        return try Value.fromRawOwned(raw_value);
    }

    pub fn arrayBufferValueCopy(self: Realm, bytes: []const u8) Error!ValueResult {
        var raw_value: ?*RawValue = null;
        var exception: ?*RawValue = null;
        return switch (collo_array_buffer_new_copy(
            self.raw,
            borrowedBuffer(bytes),
            &raw_value,
            &exception,
        )) {
            status_ok => .{ .success = try Value.fromRawOwned(raw_value) },
            status_js_exception => .{ .exception = try Value.fromRawOwned(exception) },
            else => |status| {
                try statusToError(status);
                unreachable;
            },
        };
    }

    pub fn uint8ArrayValueCopy(self: Realm, bytes: []const u8) Error!ValueResult {
        var raw_value: ?*RawValue = null;
        var exception: ?*RawValue = null;
        return switch (collo_uint8_array_new_copy(
            self.raw,
            borrowedBuffer(bytes),
            &raw_value,
            &exception,
        )) {
            status_ok => .{ .success = try Value.fromRawOwned(raw_value) },
            status_js_exception => .{ .exception = try Value.fromRawOwned(exception) },
            else => |status| {
                try statusToError(status);
                unreachable;
            },
        };
    }

    pub fn fetchReadResultValueCopy(self: Realm, bytes: ?[]const u8, done: bool) Error!ValueResult {
        var raw_value: ?*RawValue = null;
        var exception: ?*RawValue = null;
        const raw_bytes = if (bytes) |chunk| borrowedBuffer(chunk) else borrowedBuffer(&.{});
        return switch (collo_fetch_read_result_new_copy(
            self.raw,
            raw_bytes,
            if (done) 1 else 0,
            &raw_value,
            &exception,
        )) {
            status_ok => .{ .success = try Value.fromRawOwned(raw_value) },
            status_js_exception => .{ .exception = try Value.fromRawOwned(exception) },
            else => |status| {
                try statusToError(status);
                unreachable;
            },
        };
    }

    pub fn blobValueCopy(self: Realm, bytes: []const u8, content_type: []const u8) Error!ValueResult {
        var raw_value: ?*RawValue = null;
        var exception: ?*RawValue = null;
        return switch (collo_blob_new_copy(
            self.raw,
            borrowedBuffer(bytes),
            borrowedString(content_type),
            &raw_value,
            &exception,
        )) {
            status_ok => .{ .success = try Value.fromRawOwned(raw_value) },
            status_js_exception => .{ .exception = try Value.fromRawOwned(exception) },
            else => |status| {
                try statusToError(status);
                unreachable;
            },
        };
    }

    pub fn formDataValueFromBytes(self: Realm, bytes: []const u8, content_type: []const u8) Error!ValueResult {
        var raw_value: ?*RawValue = null;
        var exception: ?*RawValue = null;
        return switch (collo_form_data_new_from_bytes(self.raw, borrowedBuffer(bytes), borrowedString(content_type), &raw_value, &exception)) {
            status_ok => .{ .success = try Value.fromRawOwned(raw_value) },
            status_js_exception => .{ .exception = try Value.fromRawOwned(exception) },
            else => |status| {
                try statusToError(status);
                unreachable;
            },
        };
    }

    pub fn objectValue(self: Realm) Error!Value {
        var raw_value: ?*RawValue = null;
        return outValueNoException(collo_object_new(self.raw, &raw_value), raw_value);
    }

    pub fn arrayValue(self: Realm) Error!Value {
        var raw_value: ?*RawValue = null;
        return outValueNoException(collo_array_new(self.raw, &raw_value), raw_value);
    }

    pub fn globalThisValue(self: Realm) Error!Value {
        var raw_value: ?*RawValue = null;
        return outValueNoException(collo_global_this(self.raw, &raw_value), raw_value);
    }

    /// A frozen object mapping each entry's name to its value as a string,
    /// built without running JavaScript (`collo_env_object_new` in `abi.h`
    /// owns the rules). `entries` is borrowed for the call; the caller owns
    /// the returned value. Fails with `error.InvalidArgument` for an empty or
    /// index-like name or for bytes that are not UTF-8.
    pub fn envObjectValue(self: Realm, entries: []const NameValuePair) Error!Value {
        var raw_value: ?*RawValue = null;
        return outValueNoException(collo_env_object_new(
            self.raw,
            if (entries.len == 0) null else entries.ptr,
            entries.len,
            &raw_value,
        ), raw_value);
    }

    pub fn requestValue(self: Realm, init: *const RequestInit) Error!ValueResult {
        var value: ?*RawValue = null;
        var exception: ?*RawValue = null;
        return switch (collo_request_new(self.raw, init, &value, &exception)) {
            status_ok => .{ .success = try Value.fromRawOwned(value) },
            status_js_exception => .{ .exception = try Value.fromRawOwned(exception) },
            else => |status| {
                try statusToError(status);
                unreachable;
            },
        };
    }

    pub fn responseValue(self: Realm, init: *const ResponseInit) Error!ValueResult {
        var value: ?*RawValue = null;
        var exception: ?*RawValue = null;
        return switch (collo_response_new(self.raw, init, &value, &exception)) {
            status_ok => .{ .success = try Value.fromRawOwned(value) },
            status_js_exception => .{ .exception = try Value.fromRawOwned(exception) },
            else => |status| {
                try statusToError(status);
                unreachable;
            },
        };
    }

    pub fn fetchResponseValue(self: Realm, init: *const FetchResponseInit) Error!ValueResult {
        var value: ?*RawValue = null;
        var exception: ?*RawValue = null;
        return switch (collo_fetch_response_new(self.raw, init, &value, &exception)) {
            status_ok => .{ .success = try Value.fromRawOwned(value) },
            status_js_exception => .{ .exception = try Value.fromRawOwned(exception) },
            else => |status| {
                try statusToError(status);
                unreachable;
            },
        };
    }
};

/// The realm the deferred's promise belongs to, where the value that settles
/// it is created. Like every `Realm`, it is valid only while its VM lives,
/// even when the deferred outlives the VM (`collo_promise_deferred_realm`).
pub fn promiseDeferredRealm(raw: *const RawPromiseDeferred) Realm {
    return .{ .raw = collo_promise_deferred_realm(raw).? };
}

pub fn releasePromiseDeferred(raw: *RawPromiseDeferred) void {
    collo_promise_deferred_release(raw);
}

pub fn runCryptoJob(raw: *RawCryptoJob) void {
    collo_crypto_job_run(raw);
}

pub fn destroyCryptoJob(raw: *RawCryptoJob) void {
    collo_crypto_job_destroy(raw);
}

pub fn setHelperThreadsTimeoutOverrideNs(timeout_ns: u64) Error!void {
    try statusToError(collo_set_helper_threads_timeout_override_ns(timeout_ns));
}

pub fn prepareProcessForFork() Error!void {
    try statusToError(collo_prepare_process_for_fork());
}

pub fn clearHelperThreadsTimeoutOverride() void {
    collo_clear_helper_threads_timeout_override();
}

pub fn setGcMaxHeapSizeOverrideBytes(bytes: u64) Error!void {
    try statusToError(collo_set_gc_max_heap_size_override_bytes(bytes));
}

pub fn clearGcMaxHeapSizeOverride() void {
    collo_clear_gc_max_heap_size_override();
}

/// Serializes one ESM module's CachedBytecode blob, for a module pack's
/// bytecode segment, through the process-wide tooling VM
/// (`jsc/runtime/tooling_bytecode.cpp`). `specifier` must be the exact pack
/// specifier the worker's loader registers the module under, because the
/// blob is built from a source provider that mirrors the loader's;
/// `tooling_bytecode.cpp` lists what has to match. The caller owns the
/// returned bytes, allocated with `allocator`. Fails with
/// `error.InvalidArgument` for an empty source or specifier, with
/// `error.Internal` when parsing or serialization fails, and with
/// `error.OutOfMemory`.
pub fn generateModuleBytecodeAlloc(
    allocator: std.mem.Allocator,
    specifier: []const u8,
    source: []const u8,
) Error![]u8 {
    var out_ptr: ?[*]u8 = null;
    var out_len: usize = 0;
    try statusToError(collo_tool_generate_module_bytecode(
        borrowedBuffer(source),
        borrowedString(specifier),
        &out_ptr,
        &out_len,
    ));
    const bytes = out_ptr orelse return error.Internal;
    defer collo_tool_bytecode_release(bytes);
    const copy = try allocator.alloc(u8, out_len);
    @memcpy(copy, bytes[0..out_len]);
    return copy;
}

fn borrowedString(value: []const u8) RawString {
    return .{
        .ptr = if (value.len == 0) null else value.ptr,
        .len = value.len,
    };
}

pub fn borrowedBuffer(value: []const u8) RawBuffer {
    return .{
        .ptr = if (value.len == 0) null else value.ptr,
        .len = value.len,
    };
}

pub fn rawStringSlice(value: RawString) []const u8 {
    return if (value.ptr) |ptr| ptr[0..value.len] else "";
}

pub fn rawBufferSlice(value: RawBuffer) []const u8 {
    return if (value.ptr) |ptr| ptr[0..value.len] else "";
}

/// Seals `bytes` into a read-only memfd with the seal set route packs travel
/// with (`F_SEAL_WRITE|SHRINK|GROW|SEAL`), so a mapping of it carries the
/// same guarantee as a route pack's: its bytes cannot change.
fn sealedMemfdFromBytes(bytes: []const u8) Error!std.posix.fd_t {
    const linux = std.os.linux;
    const fd = std.posix.memfd_create(
        "collo-module-pack-inline",
        linux.MFD.CLOEXEC | linux.MFD.ALLOW_SEALING,
    ) catch return error.Internal;
    errdefer std.posix.close(fd);

    var written: usize = 0;
    while (written < bytes.len) {
        const n = std.posix.pwrite(fd, bytes[written..], written) catch return error.Internal;
        if (n == 0) return error.Internal;
        written += n;
    }

    // `f_add_seals` and `memfd_readonly_seals` of `common/os.zig`, repeated
    // because this module does not import `collo_os`: F_SEAL_SEAL,
    // F_SEAL_SHRINK, F_SEAL_GROW and F_SEAL_WRITE.
    const f_add_seals: i32 = 1033;
    const readonly_seals: usize = 0x0001 | 0x0002 | 0x0004 | 0x0008;
    if (linux.fcntl(fd, f_add_seals, readonly_seals) != 0)
        return error.Internal;
    return fd;
}

/// The one mapping from `ColloStatus` to Zig errors. `COLLO_STATUS_PENDING`
/// and unknown values become `error.Internal`, so a call that can return
/// pending checks for it first.
fn statusToError(status: RawStatus) Error!void {
    switch (status) {
        status_ok => return,
        status_error => return error.Internal,
        status_invalid_argument => return error.InvalidArgument,
        status_js_exception => return error.JsException,
        status_unsupported => return error.Unsupported,
        status_out_of_memory => return error.OutOfMemory,
        status_already_exists => return error.AlreadyExists,
        status_response_body_too_large => return error.ResponseBodyTooLarge,
        status_response_header_count_too_large => return error.ResponseHeaderCountTooLarge,
        status_response_header_bytes_too_large => return error.ResponseHeaderBytesTooLarge,
        else => return error.Internal,
    }
}

fn outValueNoException(status: RawStatus, out_value: ?*RawValue) Error!Value {
    try statusToError(status);
    return try Value.fromRawOwned(out_value);
}
