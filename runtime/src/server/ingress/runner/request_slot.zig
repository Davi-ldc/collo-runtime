//! The slot an ingress lane holds for each request it admits, an entry of the
//! lane's request slab (`slab.zig`) whose index and generation make the
//! request's key, on the lane thread that owns it. Admission fills it
//! (`admission.zig`) and `finishRequest` in `request_finish.zig` gives it
//! back, once.
//!
//! Invariants:
//! - A live slot is waiting while `worker` is null and dispatched once it
//!   is set. A waiting request is this lane's own state in its pool's waiter
//!   FIFO and owns a copy of its head (`head`), because the HTTP/2 decoder's
//!   buffers are gone by the time a worker slot reaches it. A dispatched
//!   request holds one slot of `worker` (`worker_slot`) until its finish gives
//!   the slot back to the pool, and that slot keeps the record valid.
//! - `route`, `request_id`, the request key and the access facts' identity
//!   are the lane's own, assigned at admission; nothing a worker sends
//!   changes them.
//! - The request's one deadline is `deadline_ns`, fixed at admission. Its
//!   wheel entry (`deadline`) fires there while the request waits for a
//!   worker slot or for room to send its begin, and at the deadline plus
//!   `hard_timeout_grace_ns` once the begin reached the worker.
//! - Sends toward the worker keep the request's order: while `send_blocked`
//!   waits for room, the parked begin, then a parked reset, then the
//!   stream's buffered body go out in that order before anything later.
//!   Once a send fails for the worker's doing (`send_blocked == .failed`),
//!   nothing more goes out, and the worker's death path ends the request.
//! - `begin_sent` is set once the request's `request_begin` is in the
//!   worker's socket. Until then the worker cannot have run the request, so
//!   its finish writes no usage floor for it.

const std = @import("std");

const ipc = @import("collo_ipc");
const lifecycle = @import("collo_server_lifecycle");
const server_config = @import("collo_server_config");
const supervision = @import("collo_server_supervisor");
const access_log = @import("collo_server_analytics").access;
const worker_shared_page = @import("collo_worker_state").page;
const slab = @import("../slab.zig");
const timer_wheel = @import("../timer_wheel.zig");

const pool = supervision.pool;
const WorkerRecord = supervision.worker_table.Record;

/// The lane's requests.
pub const RequestSlab = slab.FaultInSlab(RequestSlot);

pub const RequestSlot = struct {
    slab_link: slab.Link = .{},
    request_key: lifecycle.RequestKey = .{ .lane_id = 0, .slot = 0, .generation = 0 },
    /// The server's id for the request (`Service.allocateRequestId`), never 0
    /// on a live slot.
    request_id: u64 = 0,
    connection_key: lifecycle.ConnectionKey = .{ .lane_id = 0, .slot = 0, .generation = 0 },
    /// The client's HTTP/2 stream.
    ingress_channel_id: u32 = 0,
    route: server_config.RouteKey = .{ .definition = 0, .route = 0 },
    /// The request's deadline (CLOCK_MONOTONIC): admission plus its
    /// definition's `timeoutMs`.
    deadline_ns: u64 = 0,
    /// When the lane admitted the request (CLOCK_MONOTONIC).
    admitted_ns: u64 = 0,
    /// The request's entry in the lane's deadline wheel, while it has one.
    deadline: ?timer_wheel.Handle = null,
    /// The head of a request that waits. A request dispatched at admission
    /// sends its head straight from the decoder and never has one.
    head: ?OwnedHead = null,
    worker: ?*WorkerRecord = null,
    worker_slot: pool.Slot = 0,
    /// `worker.key()` at dispatch; zero while the request waits.
    worker_key: lifecycle.WorkerKey = .{ .worker_id = 0, .worker_generation = 0 },
    /// The gateway generation and the worker session the request's egress
    /// token was minted for, both 0 when its dispatch carried
    /// `egress_token.none` or it was never dispatched. Its finish owes that
    /// gateway a `request_ended` entry (`Lease.noteEnded` in
    /// `server/gateway/lease.zig`).
    egress_gateway_generation: u64 = 0,
    egress_gateway_session_id: u64 = 0,
    /// The client reset the stream, or the lane answered it alone and
    /// detached it: the worker's descriptors for it are dropped and the lane
    /// writes nothing more on it.
    h2_client_reset: bool = false,
    /// What the request's next send toward the worker waits for, or `.none`.
    send_blocked: SendBlock = .none,
    /// The request's `request_begin` reached the worker's socket.
    begin_sent: bool = false,
    /// The grace backstop once moved out by another grace for this request,
    /// because its worker kept the control socket filling past the
    /// backstop's read (`deadline_driver.expireDispatchedRequest`).
    backstop_deferred: bool = false,
    /// The request's begin, when its send would have blocked.
    parked_begin: ?ParkedBegin = null,
    /// The error code of a request reset whose send would have blocked.
    parked_reset: ?u32 = null,
    /// A worker completion that arrived after the request's response head
    /// went out and before its end did. It finishes the request when the
    /// response ends, when the stream goes away, or at the deadline, whose
    /// wheel entry stays armed (`worker_completions.zig`).
    pending_worker_completion: ?worker_shared_page.WorkerCompletionRecord = null,
    /// Stamped at admission and emitted once, when the slot finishes.
    /// `request_id` 0 means nothing to emit.
    access: access_log.AccessFacts = .{},

    pub fn isLive(self: *const RequestSlot) bool {
        return self.slab_link.live;
    }

    pub fn waiting(self: *const RequestSlot) bool {
        return self.slab_link.live and self.worker == null;
    }

    pub fn dispatched(self: *const RequestSlot) bool {
        return self.slab_link.live and self.worker != null;
    }

    /// The identity every descriptor of the request carries toward its
    /// worker.
    pub fn identity(self: *const RequestSlot) ipc.ingress_channel.RequestIdentity {
        return .{
            .request_id = self.request_id,
            .request_generation = self.request_key.generation,
            .request_lane_id = self.request_key.lane_id,
            .request_slot = self.request_key.slot,
        };
    }
};

/// What a blocked send of a request waits for.
pub const SendBlock = enum {
    none,
    /// The worker's control socket was full: a writability poll on it.
    socket,
    /// The worker's payload ring was full: its credit eventfd.
    ring,
    /// A send failed for the worker's doing. Nothing more is sent, and the
    /// worker's death path, queued by the failure, ends the request.
    failed,
};

/// A `request_begin` whose send would have blocked. The payload holds the
/// request's egress token, so `deinit` zeroes it before the free.
pub const ParkedBegin = struct {
    descriptor: ipc.ingress_channel.Descriptor,
    payload: []u8,
    allocator: std.mem.Allocator,

    /// Copies `payload`; the caller keeps its own bytes.
    pub fn init(
        allocator: std.mem.Allocator,
        descriptor: ipc.ingress_channel.Descriptor,
        payload: []const u8,
    ) error{OutOfMemory}!ParkedBegin {
        return .{
            .descriptor = descriptor,
            .payload = try allocator.dupe(u8, payload),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ParkedBegin) void {
        std.crypto.secureZero(u8, self.payload);
        self.allocator.free(self.payload);
        self.* = undefined;
    }
};

/// The parts of a request's head that its dispatch carries. Every slice is
/// borrowed: from the parsed head (`request_head.ParsedHead`) and the route
/// match during an inline dispatch, or from an `OwnedHead`.
pub const DispatchHead = struct {
    /// The request's normalized authority (`ParsedHead.authority`), which the
    /// dispatch carries as `authority` and as the `host` header
    /// (`h2HeadersForIpc`).
    authority: []const u8,
    method: []const u8,
    path: []const u8,
    raw_query: []const u8,
    request_headers: []const ipc.RequestHeader,
    route_captures: []const ipc.RouteCapture,
    body_framing: ipc.RequestBodyFraming,
};

/// A copy of a `DispatchHead` in one allocation: the header and capture
/// arrays first, then every string they and the head point at.
pub const OwnedHead = struct {
    bytes: []align(@alignOf(ipc.RequestHeader)) u8,
    allocator: std.mem.Allocator,
    head: DispatchHead,

    /// Copies `source`, which the caller may free afterwards.
    pub fn init(allocator: std.mem.Allocator, source: DispatchHead) error{OutOfMemory}!OwnedHead {
        const headers_bytes = source.request_headers.len * @sizeOf(ipc.RequestHeader);
        const captures_offset = std.mem.alignForward(usize, headers_bytes, @alignOf(ipc.RouteCapture));
        const strings_offset = captures_offset + source.route_captures.len * @sizeOf(ipc.RouteCapture);
        var strings_len = source.authority.len + source.method.len + source.path.len + source.raw_query.len;
        for (source.request_headers) |header|
            strings_len += header.name.len + header.value.len;
        for (source.route_captures) |capture|
            strings_len += capture.name.len + capture.value.len;

        const bytes = try allocator.alignedAlloc(
            u8,
            std.mem.Alignment.of(ipc.RequestHeader),
            strings_offset + strings_len,
        );
        const headers_ptr: [*]ipc.RequestHeader = @ptrCast(bytes.ptr);
        const headers = headers_ptr[0..source.request_headers.len];
        const captures_ptr: [*]ipc.RouteCapture = @ptrCast(@alignCast(bytes.ptr + captures_offset));
        const captures = captures_ptr[0..source.route_captures.len];

        var cursor = strings_offset;
        const authority = copyInto(bytes, &cursor, source.authority);
        const method = copyInto(bytes, &cursor, source.method);
        const path = copyInto(bytes, &cursor, source.path);
        const raw_query = copyInto(bytes, &cursor, source.raw_query);
        for (source.request_headers, headers) |header, *owned| {
            owned.* = .{
                .name = copyInto(bytes, &cursor, header.name),
                .value = copyInto(bytes, &cursor, header.value),
            };
        }
        for (source.route_captures, captures) |capture, *owned| {
            owned.* = .{
                .name = copyInto(bytes, &cursor, capture.name),
                .value = copyInto(bytes, &cursor, capture.value),
            };
        }
        std.debug.assert(cursor == bytes.len);

        return .{
            .bytes = bytes,
            .allocator = allocator,
            .head = .{
                .authority = authority,
                .method = method,
                .path = path,
                .raw_query = raw_query,
                .request_headers = headers,
                .route_captures = captures,
                .body_framing = source.body_framing,
            },
        };
    }

    pub fn deinit(self: *OwnedHead) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    fn copyInto(bytes: []u8, cursor: *usize, source: []const u8) []const u8 {
        const start = cursor.*;
        cursor.* += source.len;
        @memcpy(bytes[start..cursor.*], source);
        return bytes[start..cursor.*];
    }
};
