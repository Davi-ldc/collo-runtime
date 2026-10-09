//! The fixed-layout messages of the IPC between the node's processes:
//! message kinds, status vocabularies, packet headers, their decoders and
//! their layout pins.
//!
//! Every process runs the same binary, so a layout changes on both ends in one
//! edit, and the extern structs cross a socket or a shared ring as raw
//! native-endian bytes (`packet.readStruct`). The pins at the bottom catch an edit that shears a
//! struct; they do not keep older peers working, and nothing else does.
//! The codecs that add variable data or descriptors to these headers live
//! beside this file: `dispatch.zig` (DispatchWork), `zygote_worker.zig` (fork
//! and WorkerInit), `egress.zig`, `egress_attach.zig` and `fs_fault.zig`. An
//! egress token rides in these headers as `egress_token.Bytes`, whose layout
//! `egress_token.zig` owns and pins. The file holds only types and pure
//! functions, callable from any thread.

const std = @import("std");
const limits = @import("collo_limits");
const route_table = @import("route_table.zig");
const egress_token = @import("egress_token.zig");

pub const max_message_bytes: usize = 1024 * 1024;
pub const max_route_capture_count: usize = 64;
pub const max_request_header_count: usize = 256;
/// Sized by the packet with the most descriptors, a WorkerInit of a worker
/// that serves routes, whose descriptor table `zygote_worker.zig` defines and
/// checks against this bound at compile time.
pub const max_fds_per_message: usize = 30;

/// Values 8, 9, 10, 13, 21 and 22 name no message, and `decodeMessageKind`
/// refuses them.
pub const MessageKind = enum(u32) {
    zygote_ready = 1,
    fork_request = 2,
    fork_reply = 3,
    worker_init = 4,
    worker_ready = 5,
    worker_init_failed = 6,
    dispatch_work = 7,
    ingress_channel = 11,
    egress_fetch_start = 12,
    egress_cancel = 14,
    egress_release_body = 15,
    egress_fetch_head = 16,
    egress_body_chunk_batch = 17,
    egress_body_end = 18,
    egress_fetch_error = 19,
    egress_abort_ack = 20,
    egress_upload_chunk_batch = 23,
    /// A file request and its answer travel on the fs fault SEQPACKET pair
    /// WorkerInit hands the child, never on the worker control channel.
    fs_fault_request = 24,
    fs_fault_response = 25,
    /// Server to worker on the worker's control socket, after the gateway the worker was attached
    /// to was replaced: the worker half of its new egress session (`EgressAttach`,
    /// `egress_attach.zig`).
    egress_attach = 26,
};

pub const WorkerInitFailedReason = enum(u32) {
    invalid_worker_init = 1,
    missing_metrics_fd = 2,
    internal_error = 3,
    missing_ingress_payload_fd = 4,
    missing_egress_shared_fd = 5,
    missing_ingress_payload_credit_fd = 6,
    /// The fs index memfd failed to map or parse in the child. The worker has
    /// no fallback index, so the init fails.
    invalid_fs_index = 7,
    /// The child's evaluation watchdog, armed at
    /// `WorkerInit.init_deadline_mono_ns` less
    /// `limits.process.WORKER_INIT_CLEANUP_RESERVE_NS`, stopped the VM while
    /// it evaluated the route entries. The child reports this and exits by
    /// itself before the init deadline. The server's launcher does not wait
    /// for that exit: it hands the child to the reaper, which kills it at
    /// once. Only the synchronous driver (`runToReady` in `host/launch.zig`)
    /// waits for the exit, up to `PROCESS_EXIT_WAIT_MS`, before it kills.
    init_deadline_exceeded = 8,
};

/// Status of an fs fault response. An `ok` response carries exactly one file
/// descriptor as SCM_RIGHTS ancillary data, and its packet body is the fixed
/// header alone; every other status carries none. `fs_fault.zig` enforces
/// this on send and on decode.
pub const FsFaultResponseStatus = enum(u32) {
    ok = 0,
    /// The path is not in the worker's fs index.
    not_found = 1,
    /// The identity matches no request the host has in flight on this worker
    /// and no boot permit, such as a request-less fault after ready.
    refused = 2,
    /// The host could not produce the file.
    fetch_failed = 3,
};

pub const RequestDoneStatus = enum(u32) {
    ok = 0,
    bad_request = 1,
    js_exception = 2,
    internal_error = 3,
    deadline_timeout = 4,
    worker_crash = 5,
    client_closed = 6,
};

pub const RouteCapture = struct {
    name: []const u8,
    value: []const u8,
};

pub const RequestHeader = struct {
    name: []const u8,
    value: []const u8,
};

/// Whether a request body follows the dispatch. With `ingress_channel` the
/// body arrives as request-body chunks on the ingress channel, in stream
/// order; with `none` the request has no body.
pub const RequestBodyFraming = enum(u32) {
    none = 0,
    ingress_channel = 1,
};

pub fn decodeRequestBodyFraming(raw: u32) !RequestBodyFraming {
    return switch (raw) {
        0 => .none,
        1 => .ingress_channel,
        else => error.InvalidRequestBodyFraming,
    };
}

pub fn validateRequestBodyFraming(framing: RequestBodyFraming) !void {
    switch (framing) {
        .none,
        .ingress_channel,
        => {},
    }
}

/// One request as the host hands it to a worker, borrowing every slice;
/// `dispatch.zig` encodes it, and decodes it into a `DispatchWork` that owns
/// its bytes. Every identity field is the host's: the request id, lane slot
/// and generation the host assigned, and the worker record it dispatched to.
pub const DispatchWorkView = struct {
    request_id: u64,
    request_lane_id: u16 = 0,
    request_slot: u32 = 0,
    request_generation: u64 = 0,
    /// The request's egress token (`egress_token.zig`), which the worker copies into every
    /// fetch the request makes and never reads; `egress_token.none` when the worker has no
    /// egress session.
    egress_token: egress_token.Bytes = egress_token.none,
    worker_id: u64 = 0,
    worker_generation: u64 = 0,
    accounting_flags: u32 = 0,
    /// The request's authority, which the worker uses as the host of
    /// `request.url`. The decoder refuses an empty one.
    authority: []const u8,
    deadline_monotonic_ns: u64,
    method: []const u8,
    path: []const u8,
    raw_query: []const u8,
    request_headers: []const RequestHeader,
    body_framing: RequestBodyFraming,
    route_captures: []const RouteCapture,
    /// The request's route: its position in the route table of the worker's
    /// definition (`route_table.zig`), which WorkerInit delivered.
    route_index: u16,
};

pub const ZygoteReady = extern struct {
    kind: u32,

    pub fn init() ZygoteReady {
        return .{ .kind = @intFromEnum(MessageKind.zygote_ready) };
    }
};

pub const ForkRequest = extern struct {
    kind: u32,
    flags: u32,
    fork_job_id: u64,

    pub const Flags = struct {
        /// The request carries the worker's pre-created cgroup directory fd as
        /// SCM_RIGHTS ancillary data; the zygote clones the child directly into
        /// that cgroup (CLONE_INTO_CGROUP).
        pub const cgroup_fd: u32 = 1 << 0;
        pub const valid_mask: u32 = cgroup_fd;
    };

    pub fn init(fork_job_id: u64, flags: u32) ForkRequest {
        return .{
            .kind = @intFromEnum(MessageKind.fork_request),
            .flags = flags,
            .fork_job_id = fork_job_id,
        };
    }
};

pub const ForkReply = extern struct {
    kind: u32,
    pid: u32,
    fork_job_id: u64,

    pub fn init(fork_job_id: u64, pid: u32) ForkReply {
        return .{
            .kind = @intFromEnum(MessageKind.fork_reply),
            .pid = pid,
            .fork_job_id = fork_job_id,
        };
    }
};

pub const WorkerRuntimeBootOptions = extern struct {
    runtime_flags: u32 = 0,
    _reserved0: u32 = 0,
    max_fetches_per_request: u64 = 16,
    max_fetches_per_worker: u64 = 64,
    max_timers_per_worker: u64 = 256,
    ready_queue_capacity: u64 = 256,
    request_task_capacity: u64 = 64,
    crypto_thread_count: u64 = default_crypto_thread_count,
    /// Stack of each crypto pool thread (`start` in `worker/js/crypto/jobs.zig`).
    /// glibc places static TLS inside each thread's stack and fails thread
    /// creation when the stack cannot hold static TLS, the guard page and
    /// PTHREAD_STACK_MIN, so an override must leave room for the binary's
    /// static TLS.
    crypto_thread_stack_bytes: u64 = 4 * 1024 * 1024,
    crypto_max_in_flight_per_request: u64 = default_crypto_max_in_flight_per_request,
    crypto_max_in_flight_per_worker: u64 = default_crypto_max_in_flight_per_worker,

    pub const max_crypto_thread_count: u64 = 2;
    pub const default_crypto_thread_count: u64 = 2;
    pub const default_crypto_max_in_flight_per_request: u64 = 6;
    pub const default_crypto_max_in_flight_per_worker: u64 =
        64 * default_crypto_max_in_flight_per_request;
    pub const flag_trace_requests: u32 = 1 << 0;
    pub const flag_trace_all_requests: u32 = 1 << 1;
    pub const flag_log_full_js_exceptions: u32 = 1 << 2;
    /// Records the first handler call's timestamp, independent of request
    /// tracing.
    pub const flag_bench_handler: u32 = 1 << 3;
    pub const valid_flags: u32 =
        flag_trace_requests |
        flag_trace_all_requests |
        flag_log_full_js_exceptions |
        flag_bench_handler;

    pub fn default() WorkerRuntimeBootOptions {
        return .{};
    }

    pub fn deriveCryptoMaxInFlightPerWorker(self: *const WorkerRuntimeBootOptions) u64 {
        return std.math.mul(
            u64,
            self.request_task_capacity,
            self.crypto_max_in_flight_per_request,
        ) catch std.math.maxInt(u64);
    }

    pub fn validate(self: *const WorkerRuntimeBootOptions) !void {
        if ((self.runtime_flags & ~valid_flags) != 0)
            return error.InvalidWorkerRuntimeOptions;
        if (self.max_fetches_per_request == 0 or
            self.max_fetches_per_worker == 0 or
            self.max_timers_per_worker == 0 or
            self.ready_queue_capacity == 0 or
            self.request_task_capacity == 0 or
            self.crypto_thread_count == 0 or
            self.crypto_thread_count > max_crypto_thread_count or
            self.crypto_thread_stack_bytes == 0 or
            self.crypto_max_in_flight_per_request == 0 or
            self.crypto_max_in_flight_per_worker == 0)
        {
            return error.InvalidWorkerRuntimeOptions;
        }
    }
};

/// Host to child, once, on the init socket of a fresh fork: the limits and
/// descriptors the child boots with. The packet is this struct alone, with
/// the descriptor table `zygote_worker.zig` defines. The reserved field names
/// the struct's padding, and `validate` refuses it nonzero.
pub const WorkerInit = extern struct {
    kind: u32,
    flags: u32 = 0,
    memory_limit_bytes: u64,
    tmpfs_size_bytes: u64,
    /// Length of the route table of the worker's definition
    /// (`route_table.zig`), the sealed memfd in the descriptor table; at least
    /// the empty table and at most `route_table.bytes_max`.
    route_table_len: u64,
    /// The `cpu.max` quota, in cores over the cgroup period, the child must
    /// find on its own cgroup. It travels beside the memory limit so the child
    /// checks the limits it was actually given.
    cpu_max_cores: u32 = limits.worker.cpu_max_cores,
    _reserved0: u32 = 0,
    /// The boot token (`egress_token.zig`, kind boot) that fetches made while the route's
    /// modules evaluate present, minted when this message is sent with `init_deadline_mono_ns`
    /// as its deadline. `egress_token.none` means no egress grant, and those fetches are denied.
    boot_egress_token: egress_token.Bytes = egress_token.none,
    /// Absolute CLOCK_MONOTONIC deadline of the whole init window. Host and
    /// child read the same clock, so the raw value crosses the socket: the
    /// host fixes it when it sends WorkerInit and waits for ready against it,
    /// and the child arms its evaluation watchdog at this value less
    /// `limits.process.WORKER_INIT_CLEANUP_RESERVE_NS`, so a stopped VM can
    /// report `init_deadline_exceeded` before the host kills the child.
    /// Required nonzero; senders set it explicitly.
    init_deadline_mono_ns: u64 = 0,
    runtime: WorkerRuntimeBootOptions,

    pub const flag_isolated_network: u32 = 1 << 0;
    pub const flag_deny_direct_egress: u32 = 1 << 1;
    /// The child serves the routes of its route table: the packet's last
    /// descriptor is the definition's module pack, the child registers it and
    /// evaluates every route's entry before it reports ready, and module
    /// top-level code gets timers, and fetch when `boot_egress_token` is not
    /// `egress_token.none`. Set exactly when the route table holds a route
    /// (`validate`): the host sets it on every launch that carries routes,
    /// and a harness that wants a VM without them sends the empty table.
    pub const flag_serves_routes: u32 = 1 << 2;
    /// Each route of the table runs in a realm of its own, with its own
    /// globals, intrinsics and module registry; clear, every route shares the
    /// VM's main realm. Fixed for the worker's life, and set only beside
    /// `flag_serves_routes` (`validate`).
    pub const flag_isolate_realm: u32 = 1 << 3;
    pub const valid_flags: u32 = flag_isolated_network | flag_deny_direct_egress | flag_serves_routes |
        flag_isolate_realm;
    pub const default_tmpfs_size_bytes: u64 = 256 * 1024 * 1024;
    /// Keeps a corrupt value from becoming a cgroup quota; far above the
    /// core count of any machine Collo runs on.
    pub const max_cpu_max_cores: u32 = 256;

    pub fn init(memory_limit_bytes: u64, runtime: WorkerRuntimeBootOptions) !WorkerInit {
        var message = std.mem.zeroes(WorkerInit);
        message.kind = @intFromEnum(MessageKind.worker_init);
        message.memory_limit_bytes = memory_limit_bytes;
        // `zeroes` cleared the field default; a caller with another CPU limit
        // overwrites it.
        message.cpu_max_cores = limits.worker.cpu_max_cores;
        message.tmpfs_size_bytes = defaultTmpfsSizeBytes(memory_limit_bytes);
        message.route_table_len = route_table.empty_blob.len;
        message.runtime = runtime;
        return message;
    }

    pub fn defaultTmpfsSizeBytes(memory_limit_bytes: u64) u64 {
        return @min(default_tmpfs_size_bytes, memory_limit_bytes);
    }

    pub fn enableEgressGatewaySandbox(self: *WorkerInit) void {
        self.flags |= flag_isolated_network | flag_deny_direct_egress;
    }

    pub fn wantsIsolatedNetwork(self: *const WorkerInit) bool {
        return (self.flags & flag_isolated_network) != 0;
    }

    pub fn wantsDenyDirectEgress(self: *const WorkerInit) bool {
        return (self.flags & flag_deny_direct_egress) != 0;
    }

    pub fn servesRoutes(self: *const WorkerInit) bool {
        return (self.flags & flag_serves_routes) != 0;
    }

    pub fn isolatesRealms(self: *const WorkerInit) bool {
        return (self.flags & flag_isolate_realm) != 0;
    }

    pub fn validate(self: *const WorkerInit) !void {
        if ((self.flags & ~valid_flags) != 0)
            return error.InvalidWorkerInitFlags;
        if (self._reserved0 != 0)
            return error.InvalidWorkerInitFlags;
        if (self.wantsDenyDirectEgress() and !self.wantsIsolatedNetwork())
            return error.InvalidWorkerInitFlags;
        if (self.memory_limit_bytes == 0)
            return error.ZeroMemoryLimit;
        if (self.tmpfs_size_bytes == 0)
            return error.InvalidWorkerInitFlags;
        if (self.tmpfs_size_bytes > self.memory_limit_bytes)
            return error.InvalidWorkerInitFlags;
        if (self.route_table_len < route_table.empty_blob.len)
            return error.InvalidWorkerInitFlags;
        if (self.route_table_len > route_table.bytes_max)
            return error.InvalidWorkerInitFlags;
        // A valid table that holds a route is longer than the empty one, and
        // a worker serves routes exactly when its table holds some.
        if (self.servesRoutes() != (self.route_table_len != route_table.empty_blob.len))
            return error.InvalidWorkerInitFlags;
        if (self.isolatesRealms() and !self.servesRoutes())
            return error.InvalidWorkerInitFlags;
        if (self.cpu_max_cores == 0 or self.cpu_max_cores > max_cpu_max_cores)
            return error.InvalidWorkerInitCpuQuota;
        try self.runtime.validate();
        // Checked last so a probe of any other field fails on that field,
        // not on a missing deadline.
        if (self.init_deadline_mono_ns == 0)
            return error.InvalidWorkerInitFlags;
    }
};

pub const WorkerReady = extern struct {
    kind: u32,

    pub fn init() WorkerReady {
        return .{ .kind = @intFromEnum(MessageKind.worker_ready) };
    }
};

pub const WorkerInitFailed = extern struct {
    kind: u32,
    reason: u32,

    pub fn init(reason: WorkerInitFailedReason) WorkerInitFailed {
        return .{
            .kind = @intFromEnum(MessageKind.worker_init_failed),
            .reason = @intFromEnum(reason),
        };
    }
};

/// Fixed head of a DispatchWork packet. `dispatch.zig` owns the variable
/// sections after it, their order and the bounds the decoder checks. The
/// reserved field names the struct's padding, and the decoder refuses a
/// header where it is nonzero.
pub const DispatchPacketHeader = extern struct {
    kind: u32,
    request_slot: u32,
    request_id: u64,
    request_generation: u64,
    egress_token: egress_token.Bytes,
    worker_id: u64,
    worker_generation: u64,
    deadline_monotonic_ns: u64,
    accounting_flags: u32,
    request_lane_id: u16,
    route_index: u16,
    authority_len: u32,
    method_len: u32,
    path_len: u32,
    raw_query_len: u32,
    route_capture_count: u32,
    route_captures_bytes_len: u32,
    _reserved0: u32,
    request_header_count: u32,
    request_headers_bytes_len: u32,
    body_framing: u32,
};

/// Server to worker on the worker's control socket: the worker half of a new egress session as
/// `egress_shared.shared_fd_count` descriptors, in `egress_shared.RawFds.asArray` order, the
/// order WorkerInit carries them in. The packet body is this struct alone (`egress_attach.zig`).
pub const EgressAttach = extern struct {
    kind: u32,

    pub fn init() EgressAttach {
        return .{ .kind = @intFromEnum(MessageKind.egress_attach) };
    }
};

/// Request header on the fs fault channel. `path_len` bytes of tree-relative
/// path follow it: the bytes of an fs index entry, at most
/// `fs_fault.max_path_bytes`. `fs_fault.zig` owns the identity shapes the
/// decoder accepts.
pub const FsFaultRequestHeader = extern struct {
    kind: u32,
    _reserved0: u32,
    fault_id: u64,
    request_id: u64,
    request_generation: u64,
    worker_id: u64,
    worker_generation: u64,
    path_len: u32,
    _reserved1: u32,
};

/// Response header on the fs fault channel, which is the whole packet body.
/// The file descriptor of an `ok` response travels as SCM_RIGHTS ancillary
/// data (`FsFaultResponseStatus`).
pub const FsFaultResponseHeader = extern struct {
    kind: u32,
    status: u32,
    fault_id: u64,
};

/// Fixed head of a fetch's start packet; `egress.zig` owns the sections after it. The token is
/// the only identity a fetch carries: the gateway takes the request id, generation, session,
/// policy and deadline from it once it verifies the tag, and nothing else in the packet names a
/// request.
pub const EgressFetchStartHeader = extern struct {
    kind: u32,
    flags: u32,
    fetch_id: u64,
    body_id: u64,
    max_body_bytes: u64,
    method_len: u32,
    url_len: u32,
    request_header_count: u32,
    request_headers_bytes_len: u32,
    body_len: u64,
    /// The request's token, copied from its `DispatchWork` (`egress_token.zig`).
    egress_token: egress_token.Bytes,
};

pub const EgressCancel = extern struct {
    kind: u32,
    reason_len: u32,
    fetch_id: u64,

    pub fn init(fetch_id: u64, reason_len: u32) EgressCancel {
        return .{
            .kind = @intFromEnum(MessageKind.egress_cancel),
            .reason_len = reason_len,
            .fetch_id = fetch_id,
        };
    }
};

pub const EgressReleaseBody = extern struct {
    kind: u32,
    _reserved0: u32 = 0,
    fetch_id: u64,
    body_id: u64,

    pub fn init(fetch_id: u64, body_id: u64) EgressReleaseBody {
        return .{
            .kind = @intFromEnum(MessageKind.egress_release_body),
            .fetch_id = fetch_id,
            .body_id = body_id,
        };
    }
};

/// Coding of a fetch's body bytes in the body pool, stamped by the gateway on
/// the head. h2 bodies travel encoded and the worker decodes them inside its
/// own cgroup; h1 bodies are decoded by the gateway's engine and travel as
/// identity. The content-encoding header is forwarded unchanged and is
/// visible to the worker's code, so the pool bytes are read by this field
/// alone.
pub const BodyEncoding = enum(u8) {
    identity = 0,
    gzip = 1,
    deflate = 2,
    br = 3,
};

pub const EgressFetchHeadHeader = extern struct {
    kind: u32,
    flags: u32,
    fetch_id: u64,
    body_id: u64,
    status: u16,
    /// `BodyEncoding`, validated on decode.
    body_encoding: u8,
    _reserved0: u8,
    status_text_len: u32,
    url_len: u32,
    response_header_count: u32,
    response_headers_bytes_len: u32,
    /// Bounds the worker applies while it decodes a non-identity body.
    max_decoded_body_bytes: u64,
    max_pending_decoded_bytes: u64,
    max_decoded_to_encoded_ratio: u64,
    /// The gateway's CLOCK_MONOTONIC reading when it published this packet;
    /// one machine shares the clock. The worker sees completions only between
    /// JavaScript turns, so closing a fetch's I/O interval at this stamp
    /// instead of at drain time keeps co-scheduling delay out of
    /// `io_time_ns`. 0 means no physical readiness instant.
    ready_at_mono_ns: u64,
};

/// The request body travels as upload-pool extents announced by
/// egress_upload_chunk_batch packets; the start packet carries no inline
/// body bytes, and body_len is the total the gateway collects before it
/// starts the fetch.
pub const egress_fetch_start_flag_body_pooled: u32 = 1 << 0;
pub const valid_egress_fetch_start_flags: u32 = egress_fetch_start_flag_body_pooled;
pub const egress_fetch_head_flag_redirected: u32 = 1 << 0;
pub const valid_egress_fetch_head_flags: u32 = egress_fetch_head_flag_redirected;

pub const EgressBodyChunkBatchHeader = extern struct {
    kind: u32,
    count: u32,
    /// Readiness stamp for every chunk in the batch, as
    /// `EgressFetchHeadHeader.ready_at_mono_ns`.
    ready_at_mono_ns: u64,
};

pub const EgressUploadChunkBatchHeader = extern struct {
    kind: u32,
    count: u32,
};

/// A request-body extent the worker placed in the upload pool, the reverse
/// of `EgressBodyChunkBatchDescriptor`. A fetch has one request body, so
/// `fetch_id` alone scopes the upload.
pub const EgressUploadChunkBatchDescriptor = extern struct {
    fetch_id: u64,
    /// Bytes of this extent in the upload pool.
    len: u32,
    _reserved0: u32 = 0,
    /// Packed upload-pool handle (slot and generation), the convention of the
    /// response path's `body_pool_offset`.
    upload_pool_offset: u64,
    /// Request-body bytes through this extent; the upload completes when it
    /// reaches the start packet's `body_len`. A fetch's extents arrive in
    /// order on the single command ring, so the total only grows.
    body_bytes_total: u64,
};

pub const EgressBodyChunkBatchDescriptor = extern struct {
    fetch_id: u64,
    body_id: u64,
    /// Bytes as placed in the pool, in the coding the head's `body_encoding`
    /// names.
    len: u32,
    _reserved0: u32 = 0,
    body_pool_offset: u64,
    /// The fetch's byte meters, cumulative; the worker keeps the largest
    /// value of each (`fetch_body.EgressMeters`).
    billed_sent_total: u64 = 0,
    billed_received_total: u64 = 0,
    cost_total: u64 = 0,
};

pub const EgressBodyEnd = extern struct {
    kind: u32,
    _reserved0: u32 = 0,
    fetch_id: u64,
    body_id: u64,
    /// The fetch's byte meters, cumulative.
    billed_sent_total: u64 = 0,
    billed_received_total: u64 = 0,
    cost_total: u64 = 0,
    /// Readiness stamp, as `EgressFetchHeadHeader.ready_at_mono_ns`.
    ready_at_mono_ns: u64 = 0,

    pub fn init(fetch_id: u64, body_id: u64) EgressBodyEnd {
        return .{
            .kind = @intFromEnum(MessageKind.egress_body_end),
            .fetch_id = fetch_id,
            .body_id = body_id,
        };
    }
};

pub const EgressFetchErrorHeader = extern struct {
    kind: u32,
    message_len: u32,
    fetch_id: u64,
    body_id: u64,
    /// The fetch's byte meters, cumulative.
    billed_sent_total: u64 = 0,
    billed_received_total: u64 = 0,
    cost_total: u64 = 0,
    /// Readiness stamp, as `EgressFetchHeadHeader.ready_at_mono_ns`.
    ready_at_mono_ns: u64 = 0,
};

pub const EgressAbortAck = extern struct {
    kind: u32,
    _reserved0: u32 = 0,
    fetch_id: u64,
    body_id: u64,

    pub fn init(fetch_id: u64, body_id: u64) EgressAbortAck {
        return .{
            .kind = @intFromEnum(MessageKind.egress_abort_ack),
            .fetch_id = fetch_id,
            .body_id = body_id,
        };
    }
};

/// Length prefix of one name/value pair in a packet section, such as a
/// request header or a route capture; the name bytes and then the value
/// bytes follow it.
pub const NameValuePacket = extern struct {
    name_len: u32,
    value_len: u32,
};

/// The child's answer to WorkerInit (`zygote_worker.recvInitOutcome`).
pub const InitOutcome = union(enum) {
    ready,
    failed: WorkerInitFailedReason,
};

pub fn decodeMessageKind(raw: u32) !MessageKind {
    return switch (raw) {
        1 => .zygote_ready,
        2 => .fork_request,
        3 => .fork_reply,
        4 => .worker_init,
        5 => .worker_ready,
        6 => .worker_init_failed,
        7 => .dispatch_work,
        11 => .ingress_channel,
        12 => .egress_fetch_start,
        14 => .egress_cancel,
        15 => .egress_release_body,
        16 => .egress_fetch_head,
        17 => .egress_body_chunk_batch,
        18 => .egress_body_end,
        19 => .egress_fetch_error,
        20 => .egress_abort_ack,
        23 => .egress_upload_chunk_batch,
        24 => .fs_fault_request,
        25 => .fs_fault_response,
        26 => .egress_attach,
        else => error.InvalidMessageKind,
    };
}

pub fn decodeFsFaultResponseStatus(raw: u32) !FsFaultResponseStatus {
    return switch (raw) {
        0 => .ok,
        1 => .not_found,
        2 => .refused,
        3 => .fetch_failed,
        else => error.InvalidFsFaultResponseStatus,
    };
}

pub fn decodeWorkerInitFailedReason(raw: u32) !WorkerInitFailedReason {
    return switch (raw) {
        1 => .invalid_worker_init,
        2 => .missing_metrics_fd,
        3 => .internal_error,
        4 => .missing_ingress_payload_fd,
        5 => .missing_egress_shared_fd,
        6 => .missing_ingress_payload_credit_fd,
        7 => .invalid_fs_index,
        8 => .init_deadline_exceeded,
        else => error.InvalidWorkerInitFailedReason,
    };
}

comptime {
    if (@sizeOf(ZygoteReady) != 4)
        @compileError("ipc.ZygoteReady size mismatch");
    if (@sizeOf(ForkRequest) != 16)
        @compileError("ipc.ForkRequest size mismatch");
    if (@sizeOf(ForkReply) != 16)
        @compileError("ipc.ForkReply size mismatch");
    if (@sizeOf(WorkerRuntimeBootOptions) != 80)
        @compileError("ipc.WorkerRuntimeBootOptions size mismatch");
    if (@sizeOf(WorkerInit) != 184)
        @compileError("ipc.WorkerInit size mismatch");
    if (@offsetOf(WorkerInit, "route_table_len") != 24)
        @compileError("ipc.WorkerInit route_table_len offset mismatch");
    if (@offsetOf(WorkerInit, "cpu_max_cores") != 32)
        @compileError("ipc.WorkerInit cpu_max_cores offset mismatch");
    if (@offsetOf(WorkerInit, "_reserved0") != 36)
        @compileError("ipc.WorkerInit _reserved0 offset mismatch");
    if (@offsetOf(WorkerInit, "boot_egress_token") != 40)
        @compileError("ipc.WorkerInit boot_egress_token offset mismatch");
    if (@offsetOf(WorkerInit, "init_deadline_mono_ns") != 96)
        @compileError("ipc.WorkerInit init_deadline_mono_ns offset mismatch");
    if (@offsetOf(WorkerInit, "runtime") != 104)
        @compileError("ipc.WorkerInit runtime offset mismatch");
    if (@sizeOf(DispatchPacketHeader) != 152)
        @compileError("ipc.DispatchPacketHeader size mismatch");
    if (@sizeOf(EgressAttach) != 4)
        @compileError("ipc.EgressAttach size mismatch");
    if (@sizeOf(FsFaultRequestHeader) != 56)
        @compileError("ipc.FsFaultRequestHeader size mismatch");
    if (@sizeOf(FsFaultResponseHeader) != 16)
        @compileError("ipc.FsFaultResponseHeader size mismatch");
    if (@sizeOf(EgressFetchStartHeader) != 112)
        @compileError("ipc.EgressFetchStartHeader size mismatch");
    if (@offsetOf(EgressFetchStartHeader, "kind") != 0)
        @compileError("ipc.EgressFetchStartHeader.kind offset mismatch");
    if (@offsetOf(EgressFetchStartHeader, "flags") != 4)
        @compileError("ipc.EgressFetchStartHeader.flags offset mismatch");
    if (@offsetOf(EgressFetchStartHeader, "fetch_id") != 8)
        @compileError("ipc.EgressFetchStartHeader.fetch_id offset mismatch");
    if (@offsetOf(EgressFetchStartHeader, "body_id") != 16)
        @compileError("ipc.EgressFetchStartHeader.body_id offset mismatch");
    if (@offsetOf(EgressFetchStartHeader, "max_body_bytes") != 24)
        @compileError("ipc.EgressFetchStartHeader.max_body_bytes offset mismatch");
    if (@offsetOf(EgressFetchStartHeader, "method_len") != 32)
        @compileError("ipc.EgressFetchStartHeader.method_len offset mismatch");
    if (@offsetOf(EgressFetchStartHeader, "url_len") != 36)
        @compileError("ipc.EgressFetchStartHeader.url_len offset mismatch");
    if (@offsetOf(EgressFetchStartHeader, "request_header_count") != 40)
        @compileError("ipc.EgressFetchStartHeader.request_header_count offset mismatch");
    if (@offsetOf(EgressFetchStartHeader, "request_headers_bytes_len") != 44)
        @compileError("ipc.EgressFetchStartHeader.request_headers_bytes_len offset mismatch");
    if (@offsetOf(EgressFetchStartHeader, "body_len") != 48)
        @compileError("ipc.EgressFetchStartHeader.body_len offset mismatch");
    if (@offsetOf(EgressFetchStartHeader, "egress_token") != 56)
        @compileError("ipc.EgressFetchStartHeader.egress_token offset mismatch");
    if (@sizeOf(EgressCancel) != 16)
        @compileError("ipc.EgressCancel size mismatch");
    if (@sizeOf(EgressReleaseBody) != 24)
        @compileError("ipc.EgressReleaseBody size mismatch");
    if (@sizeOf(EgressFetchHeadHeader) != 80)
        @compileError("ipc.EgressFetchHeadHeader size mismatch");
    if (@sizeOf(EgressBodyChunkBatchHeader) != 16)
        @compileError("ipc.EgressBodyChunkBatchHeader size mismatch");
    if (@sizeOf(EgressBodyChunkBatchDescriptor) != 56)
        @compileError("ipc.EgressBodyChunkBatchDescriptor size mismatch");
    if (@sizeOf(EgressUploadChunkBatchHeader) != 8)
        @compileError("ipc.EgressUploadChunkBatchHeader size mismatch");
    if (@sizeOf(EgressUploadChunkBatchDescriptor) != 32)
        @compileError("ipc.EgressUploadChunkBatchDescriptor size mismatch");
    if (@sizeOf(EgressBodyEnd) != 56)
        @compileError("ipc.EgressBodyEnd size mismatch");
    if (@sizeOf(EgressFetchErrorHeader) != 56)
        @compileError("ipc.EgressFetchErrorHeader size mismatch");
    if (@sizeOf(EgressAbortAck) != 24)
        @compileError("ipc.EgressAbortAck size mismatch");
    if (@offsetOf(DispatchPacketHeader, "kind") != 0)
        @compileError("ipc.DispatchPacketHeader.kind offset mismatch");
    if (@offsetOf(DispatchPacketHeader, "request_slot") != 4)
        @compileError("ipc.DispatchPacketHeader.request_slot offset mismatch");
    if (@offsetOf(DispatchPacketHeader, "request_id") != 8)
        @compileError("ipc.DispatchPacketHeader.request_id offset mismatch");
    if (@offsetOf(DispatchPacketHeader, "request_generation") != 16)
        @compileError("ipc.DispatchPacketHeader.request_generation offset mismatch");
    if (@offsetOf(DispatchPacketHeader, "egress_token") != 24)
        @compileError("ipc.DispatchPacketHeader.egress_token offset mismatch");
    if (@offsetOf(DispatchPacketHeader, "worker_id") != 80)
        @compileError("ipc.DispatchPacketHeader.worker_id offset mismatch");
    if (@offsetOf(DispatchPacketHeader, "worker_generation") != 88)
        @compileError("ipc.DispatchPacketHeader.worker_generation offset mismatch");
    if (@offsetOf(DispatchPacketHeader, "deadline_monotonic_ns") != 96)
        @compileError("ipc.DispatchPacketHeader.deadline_monotonic_ns offset mismatch");
    if (@offsetOf(DispatchPacketHeader, "accounting_flags") != 104)
        @compileError("ipc.DispatchPacketHeader.accounting_flags offset mismatch");
    if (@offsetOf(DispatchPacketHeader, "request_lane_id") != 108)
        @compileError("ipc.DispatchPacketHeader.request_lane_id offset mismatch");
    if (@offsetOf(DispatchPacketHeader, "route_index") != 110)
        @compileError("ipc.DispatchPacketHeader.route_index offset mismatch");
    if (@offsetOf(DispatchPacketHeader, "authority_len") != 112)
        @compileError("ipc.DispatchPacketHeader.authority_len offset mismatch");
    if (@offsetOf(DispatchPacketHeader, "method_len") != 116)
        @compileError("ipc.DispatchPacketHeader.method_len offset mismatch");
    if (@offsetOf(DispatchPacketHeader, "path_len") != 120)
        @compileError("ipc.DispatchPacketHeader.path_len offset mismatch");
    if (@offsetOf(DispatchPacketHeader, "raw_query_len") != 124)
        @compileError("ipc.DispatchPacketHeader.raw_query_len offset mismatch");
    if (@offsetOf(DispatchPacketHeader, "route_capture_count") != 128)
        @compileError("ipc.DispatchPacketHeader.route_capture_count offset mismatch");
    if (@offsetOf(DispatchPacketHeader, "route_captures_bytes_len") != 132)
        @compileError("ipc.DispatchPacketHeader.route_captures_bytes_len offset mismatch");
    if (@offsetOf(DispatchPacketHeader, "_reserved0") != 136)
        @compileError("ipc.DispatchPacketHeader._reserved0 offset mismatch");
    if (@offsetOf(DispatchPacketHeader, "request_header_count") != 140)
        @compileError("ipc.DispatchPacketHeader.request_header_count offset mismatch");
    if (@offsetOf(DispatchPacketHeader, "request_headers_bytes_len") != 144)
        @compileError("ipc.DispatchPacketHeader.request_headers_bytes_len offset mismatch");
    if (@offsetOf(DispatchPacketHeader, "body_framing") != 148)
        @compileError("ipc.DispatchPacketHeader.body_framing offset mismatch");
    if (@sizeOf(NameValuePacket) != 8)
        @compileError("ipc.NameValuePacket size mismatch");
}
