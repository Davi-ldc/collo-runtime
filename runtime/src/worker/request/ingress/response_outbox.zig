//! A request's response steps that wait to be sent to the host: for room in
//! the shared payload ring, or for room in the control socket, whose worker
//! end does not block. Each request holds at most one pending item and sends
//! nothing else while it does: the rest of a buffered response, its head
//! included when the head has not gone out, or the next step of a streamed
//! one. A send that found no room sent nothing, so the item resumes at the
//! step it holds. A response completes only after its pending item is sent,
//! and request cleanup releases an item that never was. It belongs to the
//! worker's VM thread.

const std = @import("std");
const ipc = @import("collo_ipc");
const egress_core = @import("collo_egress_core");

pub const Credit = egress_core.body_credit.Handle;
pub const ByteLease = egress_core.ByteLease;
pub const PullCredits = egress_core.PullCredits;

/// A response head the worker decided and has not sent: its encoded payload,
/// owned by the worker's base allocator, and the fields of its descriptor.
pub const PendingHead = struct {
    payload: []u8,
    status: u16,
    header_count: u16,
    end_stream: bool,

    pub fn deinit(self: *PendingHead, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        self.* = undefined;
    }
};

/// The rest of a buffered response: its head when `head` is set, then
/// `body` from `offset`. `body` is owned by the worker's base allocator, and
/// the two statuses are what the request finishes with once all is sent.
pub const BufferedBody = struct {
    head: ?PendingHead = null,
    body: []u8,
    offset: usize = 0,
    done_status: ipc.RequestDoneStatus,
    http_status: u16,
};

/// One chunk of a streamed fetch body, with the credits that return to the
/// gateway once the chunk is sent.
pub const StreamChunk = struct {
    bytes: ByteLease = .empty,
    credits: PullCredits = .{},
    done: bool,

    pub fn deinit(self: *StreamChunk, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.credits.deinit(allocator);
        self.* = undefined;
    }
};

pub const Pending = union(enum) {
    none,
    buffered_body: BufferedBody,
    /// A streamed response's head; its first pull starts once it is sent.
    stream_head: PendingHead,
    stream_chunk: StreamChunk,
    /// A streamed response's end; the request finishes once it is sent.
    stream_end,
    /// The reset of a committed response that cannot go on, with its HTTP/2
    /// error code. Once it is sent, the request finishes with
    /// `internal_error` and the status in `RequestContext.response_http_status`.
    stream_reset: u32,
};

pub const Outbox = struct {
    pending: Pending = .none,

    pub fn isEmpty(self: *const Outbox) bool {
        return switch (self.pending) {
            .none => true,
            else => false,
        };
    }

    /// Parks `pending`, the step that found no room and everything after it.
    /// Fails with `error.ResponseOutboxBusy` when an item is parked already:
    /// a request sends nothing while its outbox holds one.
    pub fn park(self: *Outbox, pending: Pending) !void {
        std.debug.assert(pending != .none);
        if (!self.isEmpty())
            return error.ResponseOutboxBusy;
        self.pending = pending;
    }

    /// Takes the parked item out and leaves the outbox empty; the caller owns
    /// the item.
    pub fn take(self: *Outbox) Pending {
        const pending = self.pending;
        self.pending = .none;
        return pending;
    }

    pub fn assertEmpty(self: *const Outbox) void {
        std.debug.assert(self.isEmpty());
    }
};
