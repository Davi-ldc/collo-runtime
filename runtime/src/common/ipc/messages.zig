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
//! and WorkerInit), `egress.zig`, `egress_attach.zig` and
//! `worker_retiring.zig`. A request's completion, `request_done`, is an
//! operation of the ingress channel (`ingress_channel/framing.zig`) and
//! carries a `RequestDoneStatus`. An egress token rides in these headers as
//! `egress_token.Bytes`, whose layout `egress_token.zig` owns and pins. The
//! file holds only types and pure functions, callable from any thread.

const std = @import("std");
const limits = @import("collo_limits");
const egress_token = @import("egress_token.zig");

pub const max_message_bytes: usize = 1024 * 1024;
pub const max_route_capture_count: usize = 64;
pub const max_request_header_count: usize = 256;
/// Sized by the packet with the most descriptors, a WorkerInit with an
/// egress session, whose descriptor table `zygote_worker.zig` defines and
/// holds equal to this bound at compile time.
pub const max_fds_per_message: usize = 26;

/// Values 8, 9, 10, 13, 15, 21, 22, 24 and 25 name no message, and
/// `decodeMessageKind` refuses them.
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
    egress_stop = 14,
    egress_fetch_head = 16,
    egress_body_chunk_batch = 17,
    egress_body_end = 18,
    egress_fetch_error = 19,
    egress_abort_ack = 20,
    egress_upload_chunk_batch = 23,
    /// Server to worker on the worker's control socket, after the gateway the worker was attached
    /// to was replaced: the worker half of its new egress session (`EgressAttach`,
    /// `egress_attach.zig`).
    egress_attach = 26,
    /// Worker to server on the worker's control socket, after WorkerReady: the
    /// worker asks to be retired (`WorkerRetiring`, `worker_retiring.zig`).
    worker_retiring = 27,
    /// Server to worker on the worker's control socket: the cumulative body
    /// chunk credit of one response (`ResponseCredit`, `response_credit.zig`).
    response_credit = 28,
};

/// Why a worker asks to be retired. A worker never exits on its own for any
/// of them: it sends `worker_retiring` once and keeps answering every
/// request that reaches it until the server, which alone knows whether a
/// request is still on its way, retires it.
pub const WorkerRetiringReason = enum(u32) {
    /// Every route of the worker failed its evaluation, so a fresh worker may
    /// serve where this one cannot.
    routes_failed = 1,
    /// A termination poisoned the worker's VM, which runs no JavaScript
    /// again.
    vm_terminated = 2,
    /// The worker detached from its egress session on its own, on a packet
    /// or a pool state only a gateway defect produces, and no session will
    /// replace it, so a fresh worker can fetch where this one cannot
    /// (`worker/egress/gateway_runtime.zig`).
    egress_detached = 3,
};

/// Value 7 names no reason, and `decodeWorkerInitFailedReason` refuses it.
pub const WorkerInitFailedReason = enum(u32) {
    invalid_worker_init = 1,
    missing_metrics_fd = 2,
    internal_error = 3,
    missing_ingress_payload_fd = 4,
    missing_egress_shared_fd = 5,
    missing_ingress_payload_credit_fd = 6,
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

/// How a worker ended a request, as its `request_done` names it
/// (`ingress_channel/framing.zig:RequestDone.status`); the decoder refuses a
/// value this enum does not name. The only vocabulary of a request's end that
/// crosses from a worker to the server.
pub const RequestDoneStatus = enum(u8) {
    ok = 0,
    bad_request = 1,
    js_exception = 2,
    internal_error = 3,
    deadline_timeout = 4,
    worker_crash = 5,
    client_closed = 6,
    /// The request used up its CPU budget (`WorkerInit.request_cpu_budget_ns`).
    cpu_exceeded = 7,
    /// The request reached a worker that had already sent `worker_retiring`,
    /// which ran none of its JavaScript.
    worker_retiring = 8,
    /// A termination that another owner of the VM caused stopped the request,
    /// which did nothing wrong.
    worker_stopped = 9,
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
    /// The worker's pool slot the request holds (`server/supervisor/pool.zig`),
    /// the index of the live slot the worker writes for it on its page
    /// (`common/worker_state/page/live_slots.zig`). Below
    /// `limits.server.worker_concurrency_max`; the decoder refuses any other
    /// value. The server dispatches another request on the slot only after
    /// the worker's `request_done` for this one, so no two requests a worker
    /// runs name one slot.
    worker_slot: u8,
    /// The request's egress token (`egress_token.zig`), which the worker copies into every
    /// fetch the request makes and never reads; `egress_token.none` when the worker has no
    /// egress session.
    egress_token: egress_token.Bytes = egress_token.none,
    worker_id: u64 = 0,
    worker_generation: u64 = 0,
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
    /// The request's route: its position in the routes section of the
    /// worker's definition artifact (`module_pack.zig`), which WorkerInit
    /// delivered.
    route_index: u16,
};

pub const ZygoteReady = extern struct {
    kind: u32,

    pub fn init() ZygoteReady {
        return .{ .kind = @intFromEnum(MessageKind.zygote_ready) };
    }
};

/// Host to zygote: fork one worker. The packet is this struct with exactly
/// one descriptor, the worker's cgroup leaf, which the launch created with
/// its limits and the zygote clones the child into (CLONE_INTO_CGROUP), so
/// no worker runs a moment outside its leaf. The job id is the caller's, and
/// the reply repeats it. The reserved field names the struct's padding, and
/// the decoder refuses it nonzero.
pub const ForkRequest = extern struct {
    kind: u32,
    _reserved0: u32 = 0,
    fork_job_id: u64,

    pub fn init(fork_job_id: u64) ForkRequest {
        return .{
            .kind = @intFromEnum(MessageKind.fork_request),
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

/// Host to child, once, on the init socket of a fresh fork: what varies
/// between the workers one binary launches. The packet is this struct alone,
/// with the descriptor table `zygote_worker.zig` defines; every limit that
/// does not vary is a constant of `common/limits/worker.zig`, which both ends
/// compile.
pub const WorkerInit = extern struct {
    kind: u32,
    flags: u32 = 0,
    /// The memory limit the launch wrote to the worker's leaf, which the
    /// child reads back from it.
    memory_limit_bytes: u64,
    /// The size of the tmpfs the child mounts over its `/tmp`; nonzero and at
    /// most `memory_limit_bytes`.
    tmpfs_size_bytes: u64,
    /// The boot token (`egress_token.zig`, kind boot) that fetches made while
    /// route modules evaluate present, with the deadline
    /// `host/launch.zig:bootEgressDeadline` gives it. `egress_token.none`
    /// means no egress grant, and those fetches are denied.
    boot_egress_token: egress_token.Bytes = egress_token.none,
    /// Absolute CLOCK_MONOTONIC deadline of the whole init window. Host and
    /// child read the same clock, so the raw value crosses the socket: the
    /// host fixes it when it sends WorkerInit and waits for ready against it,
    /// and the child arms its evaluation watchdog at this value less
    /// `limits.process.WORKER_INIT_CLEANUP_RESERVE_NS`, so a stopped VM can
    /// report `init_deadline_exceeded` before the host kills the child.
    /// Required nonzero; senders set it explicitly.
    init_deadline_mono_ns: u64 = 0,
    /// The CPU budget of each request the worker serves, its definition's
    /// `cpuMs` in nanoseconds: the VM thread's CPU while the request owns it.
    /// 0 for a definition that sets none; at most `request_cpu_budget_ns_max`.
    request_cpu_budget_ns: u64 = 0,
    /// The wall-clock limit of each stretch of JavaScript that no request and
    /// no module evaluation owns, which the worker runs as its own owner: its
    /// definition's `timeoutMs` in nanoseconds, so no JavaScript in the worker
    /// runs longer than `timeoutMs` without an owner's deadline. Nonzero and
    /// at most `unowned_time_limit_ns_max`; `init` sets
    /// `default_unowned_time_limit_ns`, which a launch for a definition
    /// replaces.
    unowned_time_limit_ns: u64 = default_unowned_time_limit_ns,

    /// Each route of the definition runs in a realm of its own, with its own
    /// globals, intrinsics and module registry; clear, every route shares the
    /// VM's main realm. Fixed for the worker's life.
    pub const flag_isolate_realm: u32 = 1 << 0;
    /// The packet carries the worker's egress wake descriptors, so the worker
    /// can be attached to a gateway and fetch through it. Without the flag it
    /// carries no egress descriptor at all. A boot token needs the flag
    /// (`validate`). The sender in `zygote_worker.zig` owns the bit: it sets
    /// it exactly when the wake descriptors travel, whatever the caller's
    /// message says.
    pub const flag_egress: u32 = 1 << 1;
    /// The worker records its first handler call on its page
    /// (`WorkerWriterView.publishBenchHandler`), for the cold-start bench.
    pub const flag_bench_handler: u32 = 1 << 2;
    pub const valid_flags: u32 = flag_isolate_realm | flag_egress | flag_bench_handler;
    pub const default_tmpfs_size_bytes: u64 = 256 * 1024 * 1024;
    pub const request_cpu_budget_ns_max: u64 =
        @as(u64, limits.server.request_cpu_ms_max) * std.time.ns_per_ms;
    pub const unowned_time_limit_ns_max: u64 =
        @as(u64, limits.server.request_timeout_ms_max) * std.time.ns_per_ms;
    /// The unowned limit of a launch made without a worker definition, such
    /// as a test's: the `timeoutMs` a definition gets when it sets none
    /// (`default_settings` in `server/config/model.zig`), which
    /// `runtime/tests/contracts/limits.zig` holds equal.
    pub const default_unowned_time_limit_ns: u64 = 30 * std.time.ns_per_s;

    /// A message with no flag, no boot token and no init deadline, the
    /// default tmpfs size and the default unowned limit; the launch sets the
    /// rest before it sends.
    pub fn init(memory_limit_bytes: u64) WorkerInit {
        return .{
            .kind = @intFromEnum(MessageKind.worker_init),
            .memory_limit_bytes = memory_limit_bytes,
            .tmpfs_size_bytes = defaultTmpfsSizeBytes(memory_limit_bytes),
        };
    }

    pub fn defaultTmpfsSizeBytes(memory_limit_bytes: u64) u64 {
        return @min(default_tmpfs_size_bytes, memory_limit_bytes);
    }

    pub fn isolatesRealms(self: *const WorkerInit) bool {
        return (self.flags & flag_isolate_realm) != 0;
    }

    pub fn hasEgress(self: *const WorkerInit) bool {
        return (self.flags & flag_egress) != 0;
    }

    pub fn recordsBenchHandler(self: *const WorkerInit) bool {
        return (self.flags & flag_bench_handler) != 0;
    }

    /// The child's check of the fields, before it uses any of them
    /// (`zygote_worker.recvWorkerInit` checked the kind and the descriptor
    /// table). Every value is the host's, so a failure is a host bug the
    /// child reports, not an attack it repels.
    pub fn validate(self: *const WorkerInit) !void {
        if ((self.flags & ~valid_flags) != 0)
            return error.InvalidWorkerInitFlags;
        // A boot token is spent through the session's descriptors, which a
        // packet without the wake descriptors never carries.
        if (!egress_token.isNone(&self.boot_egress_token) and !self.hasEgress())
            return error.InvalidWorkerInitFlags;
        if (self.memory_limit_bytes == 0)
            return error.ZeroMemoryLimit;
        if (self.tmpfs_size_bytes == 0 or self.tmpfs_size_bytes > self.memory_limit_bytes)
            return error.InvalidWorkerInitTmpfsSize;
        if (self.request_cpu_budget_ns > request_cpu_budget_ns_max)
            return error.InvalidWorkerInitTimeLimit;
        if (self.unowned_time_limit_ns == 0 or self.unowned_time_limit_ns > unowned_time_limit_ns_max)
            return error.InvalidWorkerInitTimeLimit;
        if (self.init_deadline_mono_ns == 0)
            return error.InvalidWorkerInitDeadline;
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

/// Worker to server on the worker's control socket, at most once, after
/// WorkerReady: the whole packet, with no descriptor (`worker_retiring.zig`).
/// The server takes the worker out of service and retires it once no lane
/// holds one of its slots, so no request can be sent into its exit.
pub const WorkerRetiring = extern struct {
    kind: u32,
    /// `WorkerRetiringReason`, validated on decode.
    reason: u32,

    pub fn init(reason: WorkerRetiringReason) WorkerRetiring {
        return .{
            .kind = @intFromEnum(MessageKind.worker_retiring),
            .reason = @intFromEnum(reason),
        };
    }
};

/// Server to worker, on its control socket: the cumulative number of body
/// chunks the request's response may have published
/// (`response_credit.zig:Window.granted`). The socket identifies the worker;
/// every request identity field must match before the worker uses the grant.
pub const ResponseCredit = extern struct {
    kind: u32 = @intFromEnum(MessageKind.response_credit),
    request_lane_id: u16,
    reserved0: u16 = 0,
    request_slot: u32,
    stream_id: u32,
    request_id: u64,
    request_generation: u64,
    grant_chunks_total: u64,
};

/// Fixed head of a DispatchWork packet. `dispatch.zig` owns the variable
/// sections after it, their order and the bounds the decoder checks. The
/// reserved fields name the struct's padding, and the decoder refuses a
/// header where one is nonzero.
pub const DispatchPacketHeader = extern struct {
    kind: u32,
    request_slot: u32,
    request_id: u64,
    request_generation: u64,
    egress_token: egress_token.Bytes,
    worker_id: u64,
    worker_generation: u64,
    deadline_monotonic_ns: u64,
    _reserved0: u32,
    request_lane_id: u16,
    route_index: u16,
    authority_len: u32,
    method_len: u32,
    path_len: u32,
    raw_query_len: u32,
    route_capture_count: u32,
    route_captures_bytes_len: u32,
    /// `DispatchWorkView.worker_slot`.
    worker_slot: u8,
    _reserved1: u8,
    _reserved2: u16,
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

/// Fixed head of a fetch's start packet; `egress.zig` owns the sections after it. The token is
/// the only identity a fetch carries: the gateway takes the request id, generation, session,
/// policy and deadline from it once it verifies the tag, and nothing else in the packet names a
/// request. The gateway resolves the response's byte limit from its own policy.
pub const EgressFetchStartHeader = extern struct {
    kind: u32,
    flags: u32,
    fetch_id: u64,
    body_id: u64,
    method_len: u32,
    url_len: u32,
    request_header_count: u32,
    request_headers_bytes_len: u32,
    body_len: u64,
    /// The request's token, copied from its `DispatchWork` (`egress_token.zig`).
    egress_token: egress_token.Bytes,
};

/// Worker to gateway: stop fetch `fetch_id`, whatever it is doing. The gateway answers it once
/// with `egress_abort_ack` and ignores a stop for a fetch it no longer holds, which a worker
/// cannot see; the worker sends at most one per fetch (`worker/egress/task_runtime.zig:stopFetch`).
pub const EgressStop = extern struct {
    kind: u32,
    _reserved0: u32 = 0,
    fetch_id: u64,

    pub fn init(fetch_id: u64) EgressStop {
        return .{
            .kind = @intFromEnum(MessageKind.egress_stop),
            .fetch_id = fetch_id,
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
    /// names; the worker counts them as the fetch's received bytes.
    len: u32,
    _reserved0: u32 = 0,
    body_pool_offset: u64,
};

pub const EgressBodyEnd = extern struct {
    kind: u32,
    _reserved0: u32 = 0,
    fetch_id: u64,
    body_id: u64,
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

/// Why a fetch failed, as its `egress_fetch_error` names it. The decoder
/// refuses any other value.
pub const EgressFetchErrorCause = enum(u32) {
    /// The fetch failed on its way: a connection, the origin's answer, a
    /// limit or the gateway itself.
    failed = 0,
    /// The `network` setting of the request's route denied the fetch: its
    /// host, port or scheme, or the address its host resolved to.
    network_denied = 1,
};

pub const EgressFetchErrorHeader = extern struct {
    kind: u32,
    message_len: u32,
    fetch_id: u64,
    body_id: u64,
    /// Readiness stamp, as `EgressFetchHeadHeader.ready_at_mono_ns`.
    ready_at_mono_ns: u64 = 0,
    /// `EgressFetchErrorCause`, validated on decode.
    cause: u32 = @intFromEnum(EgressFetchErrorCause.failed),
    _reserved0: u32 = 0,
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
        14 => .egress_stop,
        16 => .egress_fetch_head,
        17 => .egress_body_chunk_batch,
        18 => .egress_body_end,
        19 => .egress_fetch_error,
        20 => .egress_abort_ack,
        23 => .egress_upload_chunk_batch,
        26 => .egress_attach,
        27 => .worker_retiring,
        28 => .response_credit,
        else => error.InvalidMessageKind,
    };
}

pub fn decodeWorkerRetiringReason(raw: u32) !WorkerRetiringReason {
    return switch (raw) {
        1 => .routes_failed,
        2 => .vm_terminated,
        3 => .egress_detached,
        else => error.InvalidWorkerRetiringReason,
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
    if (@sizeOf(WorkerInit) != 104)
        @compileError("ipc.WorkerInit size mismatch");
    if (@offsetOf(WorkerInit, "boot_egress_token") != 24)
        @compileError("ipc.WorkerInit boot_egress_token offset mismatch");
    if (@offsetOf(WorkerInit, "init_deadline_mono_ns") != 80)
        @compileError("ipc.WorkerInit init_deadline_mono_ns offset mismatch");
    if (@offsetOf(WorkerInit, "unowned_time_limit_ns") != 96)
        @compileError("ipc.WorkerInit unowned_time_limit_ns offset mismatch");
    if (WorkerInit.default_unowned_time_limit_ns > WorkerInit.unowned_time_limit_ns_max)
        @compileError("ipc.WorkerInit default unowned limit must pass validate");
    if (@sizeOf(WorkerRetiring) != 8)
        @compileError("ipc.WorkerRetiring size mismatch");
    if (@sizeOf(ResponseCredit) != 40 or @alignOf(ResponseCredit) != 8)
        @compileError("ipc.ResponseCredit layout mismatch");
    for (.{
        .{ "kind", 0 },
        .{ "request_lane_id", 4 },
        .{ "reserved0", 6 },
        .{ "request_slot", 8 },
        .{ "stream_id", 12 },
        .{ "request_id", 16 },
        .{ "request_generation", 24 },
        .{ "grant_chunks_total", 32 },
    }) |field| {
        if (@offsetOf(ResponseCredit, field[0]) != field[1])
            @compileError("ipc.ResponseCredit field offset mismatch");
    }
    if (@sizeOf(DispatchPacketHeader) != 152)
        @compileError("ipc.DispatchPacketHeader size mismatch");
    if (@sizeOf(EgressAttach) != 4)
        @compileError("ipc.EgressAttach size mismatch");
    if (@sizeOf(EgressFetchStartHeader) != 104)
        @compileError("ipc.EgressFetchStartHeader size mismatch");
    if (@offsetOf(EgressFetchStartHeader, "kind") != 0)
        @compileError("ipc.EgressFetchStartHeader.kind offset mismatch");
    if (@offsetOf(EgressFetchStartHeader, "flags") != 4)
        @compileError("ipc.EgressFetchStartHeader.flags offset mismatch");
    if (@offsetOf(EgressFetchStartHeader, "fetch_id") != 8)
        @compileError("ipc.EgressFetchStartHeader.fetch_id offset mismatch");
    if (@offsetOf(EgressFetchStartHeader, "body_id") != 16)
        @compileError("ipc.EgressFetchStartHeader.body_id offset mismatch");
    if (@offsetOf(EgressFetchStartHeader, "method_len") != 24)
        @compileError("ipc.EgressFetchStartHeader.method_len offset mismatch");
    if (@offsetOf(EgressFetchStartHeader, "url_len") != 28)
        @compileError("ipc.EgressFetchStartHeader.url_len offset mismatch");
    if (@offsetOf(EgressFetchStartHeader, "request_header_count") != 32)
        @compileError("ipc.EgressFetchStartHeader.request_header_count offset mismatch");
    if (@offsetOf(EgressFetchStartHeader, "request_headers_bytes_len") != 36)
        @compileError("ipc.EgressFetchStartHeader.request_headers_bytes_len offset mismatch");
    if (@offsetOf(EgressFetchStartHeader, "body_len") != 40)
        @compileError("ipc.EgressFetchStartHeader.body_len offset mismatch");
    if (@offsetOf(EgressFetchStartHeader, "egress_token") != 48)
        @compileError("ipc.EgressFetchStartHeader.egress_token offset mismatch");
    if (@sizeOf(EgressStop) != 16)
        @compileError("ipc.EgressStop size mismatch");
    if (@sizeOf(EgressFetchHeadHeader) != 80)
        @compileError("ipc.EgressFetchHeadHeader size mismatch");
    if (@sizeOf(EgressBodyChunkBatchHeader) != 16)
        @compileError("ipc.EgressBodyChunkBatchHeader size mismatch");
    if (@sizeOf(EgressBodyChunkBatchDescriptor) != 32)
        @compileError("ipc.EgressBodyChunkBatchDescriptor size mismatch");
    if (@sizeOf(EgressUploadChunkBatchHeader) != 8)
        @compileError("ipc.EgressUploadChunkBatchHeader size mismatch");
    if (@sizeOf(EgressUploadChunkBatchDescriptor) != 32)
        @compileError("ipc.EgressUploadChunkBatchDescriptor size mismatch");
    if (@sizeOf(EgressBodyEnd) != 32)
        @compileError("ipc.EgressBodyEnd size mismatch");
    if (@sizeOf(EgressFetchErrorHeader) != 40)
        @compileError("ipc.EgressFetchErrorHeader size mismatch");
    if (@offsetOf(EgressFetchErrorHeader, "cause") != 32)
        @compileError("ipc.EgressFetchErrorHeader.cause offset mismatch");
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
    if (@offsetOf(DispatchPacketHeader, "_reserved0") != 104)
        @compileError("ipc.DispatchPacketHeader._reserved0 offset mismatch");
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
    if (@offsetOf(DispatchPacketHeader, "worker_slot") != 136 or
        @offsetOf(DispatchPacketHeader, "_reserved1") != 137 or
        @offsetOf(DispatchPacketHeader, "_reserved2") != 138)
        @compileError("ipc.DispatchPacketHeader worker slot offset mismatch");
    if (limits.server.worker_concurrency_max > std.math.maxInt(u8) + 1)
        @compileError("ipc.DispatchPacketHeader.worker_slot must name every pool slot");
    if (@offsetOf(DispatchPacketHeader, "request_header_count") != 140)
        @compileError("ipc.DispatchPacketHeader.request_header_count offset mismatch");
    if (@offsetOf(DispatchPacketHeader, "request_headers_bytes_len") != 144)
        @compileError("ipc.DispatchPacketHeader.request_headers_bytes_len offset mismatch");
    if (@offsetOf(DispatchPacketHeader, "body_framing") != 148)
        @compileError("ipc.DispatchPacketHeader.body_framing offset mismatch");
    if (@sizeOf(NameValuePacket) != 8)
        @compileError("ipc.NameValuePacket size mismatch");
}
