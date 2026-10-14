//! The requests the server dispatched to one worker, as the server checks
//! what that worker names: each request's identity and route from its
//! dispatch until the lane ends it, and the routes of the last requests that
//! ended. Every supervisor worker record holds one
//! (`worker_table.Record.requests`).
//!
//! A worker names requests in messages and memory it controls, so the server
//! acts on such a name only when this table vouches for it. The worker's
//! reader forwards a descriptor to the lane that owns its request only while
//! the request is in flight under the descriptor's key (`forwardCheck`), and
//! forwards the request's `request_done`, the last descriptor a worker sends
//! for a request, once (`markDoneForwarded`): a worker can reach no other
//! request's lane, the descriptors one request sends through its owner's
//! queue end with its `request_done`, and the owner's queue holds at most one
//! `request_done` per request in flight (`server/ingress/commands.zig`). The
//! console drain keeps a line's request id only for a request the table
//! holds or ended recently (`routeOfRecent`), so a worker files lines only
//! under requests it was dispatched.
//!
//! An entry is free, with request id 0, or holds one request in flight: the
//! lane records it before the worker can hear of the request (`record`) and
//! frees it when the request ends, before the request's pool slot goes back
//! (`end`, or `remove` for a request whose begin never reached the worker).
//! A worker's pool gives it at most its definition's `concurrency` slots, so
//! `entries_max` entries always suffice and recording never allocates.
//!
//! Every request the worker heard of leaves its route in a ring of the last
//! `ended_requests_max` when its entry goes (`end`). A request `remove`d
//! leaves nothing: its begin never reached the worker, which therefore has
//! no request to name, so a console line naming it is forged. The console
//! drain finds a line's request among the entries, then in the ring, so a
//! line a worker wrote after its request ended still names the request's
//! route.
//!
//! Locks: `mutex` is a leaf, held only inside these methods. The lanes record
//! and end requests, the worker's reader checks what it forwards, and the
//! metrics thread and the worker's teardown look up console lines.

const std = @import("std");
const server_limits = @import("collo_limits").server;
const lifecycle = @import("collo_server_lifecycle");
const config = @import("collo_server_config");

/// Requests one worker can have in flight: one per pool slot it can have.
pub const entries_max: usize = server_limits.worker_concurrency_max;
/// Requests whose route the console drain can still find after their entry
/// left the table. The metrics thread drains console lines every
/// `metrics_drain_interval_ns` (`server/ingress/service_observability.zig`),
/// so this covers a worker that ends this many requests between two drains.
pub const ended_requests_max: usize = 256;

/// A request the server dispatched to the table's worker, as the lane
/// records it before it sends the request.
pub const Dispatched = struct {
    /// Never 0: the server allocates no request id 0
    /// (`Service.allocateRequestId` in `server/ingress/service.zig`).
    request_id: u64,
    /// The lane request slot the dispatch names, the key every descriptor
    /// the worker sends for the request must carry.
    request_key: lifecycle.RequestKey,
    /// The route the lane matched, within the worker's definition. Console
    /// lines of the request carry its pattern.
    route: config.RouteIndex,
};

pub const Entry = struct {
    /// The request the entry holds; a request id of 0 marks the entry free.
    dispatched: Dispatched = unused,
    /// The worker's reader forwarded the request's `request_done`
    /// (`markDoneForwarded`), after which nothing more of the request goes
    /// on.
    done_forwarded: bool = false,

    const unused: Dispatched = .{
        .request_id = 0,
        .request_key = .{ .lane_id = 0, .slot = 0, .generation = 0 },
        .route = 0,
    };

    fn isFree(entry: *const Entry) bool {
        return entry.dispatched.request_id == 0;
    }
};

/// A request whose entry left the table, as the console drain looks it up.
pub const EndedRequest = struct {
    request_id: u64,
    route: config.RouteIndex,
};

/// What `forwardCheck` found for a descriptor a worker addressed to a request
/// of another lane.
pub const ForwardCheck = enum {
    /// The request is in flight under the descriptor's key and its
    /// `request_done` was not forwarded: the reader forwards the descriptor.
    live,
    /// The request has no entry, or its `request_done` went on already. Its
    /// owner would drop the descriptor, so the reader drops it instead of
    /// taking a place in the owner's queue.
    absent,
    /// The table holds the request id under another request key, which only
    /// a worker that rewrote the identity of a request it was sent names.
    mismatch,
};

pub const RequestTable = struct {
    entries: [entries_max]Entry = @splat(.{}),
    /// A ring of `ended_len` requests ending at `ended_next`, the newest
    /// last; the slots past `ended_len` are never read.
    ended: [ended_requests_max]EndedRequest = undefined,
    ended_next: usize = 0,
    ended_len: usize = 0,
    mutex: std.Thread.Mutex = .{},

    /// Records a request dispatched to this table's worker.
    /// `error.RequestTableFull` means a caller broke the bound in the header:
    /// a request recorded twice, or one whose lane never ended it. The
    /// dispatch fails rather than overwrite another request's entry.
    pub fn record(self: *RequestTable, dispatched: Dispatched) error{RequestTableFull}!void {
        std.debug.assert(dispatched.request_id != 0);
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.entries) |*entry| {
            if (entry.isFree()) {
                entry.* = .{ .dispatched = dispatched };
                return;
            }
        }
        return error.RequestTableFull;
    }

    /// Frees the entry of a request whose begin never reached the worker,
    /// which no descriptor or console line of the worker can name, and
    /// remembers nothing of it. A request with no entry is left alone.
    pub fn remove(self: *RequestTable, request_id: u64) void {
        std.debug.assert(request_id != 0);
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = findLocked(self, request_id) orelse return;
        entry.* = .{};
    }

    /// Frees the entry of a request the lane ended after its begin reached
    /// the worker, and remembers its route among the ended requests for the
    /// console drain. Every later descriptor that names it finds no entry. A
    /// request with no entry is left alone.
    pub fn end(self: *RequestTable, request_id: u64) void {
        std.debug.assert(request_id != 0);
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = findLocked(self, request_id) orelse return;
        self.ended[self.ended_next] = .{
            .request_id = entry.dispatched.request_id,
            .route = entry.dispatched.route,
        };
        self.ended_next = (self.ended_next + 1) % ended_requests_max;
        if (self.ended_len < ended_requests_max)
            self.ended_len += 1;
        entry.* = .{};
    }

    /// Checks a descriptor the worker's reader is about to forward to the
    /// lane that owns its request (`server/ingress/runner/h2_worker_ipc.zig`):
    /// the request `request_id` names must be in flight under `request_key`,
    /// with no `request_done` forwarded before, so everything the worker
    /// sends for a request after its `request_done` drops at the reader
    /// instead of taking a place in the owner's queue.
    pub fn forwardCheck(self: *RequestTable, request_id: u64, request_key: lifecycle.RequestKey) ForwardCheck {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = findLocked(self, request_id) orelse return .absent;
        if (!entry.dispatched.request_key.eql(request_key))
            return .mismatch;
        if (entry.done_forwarded)
            return .absent;
        return .live;
    }

    /// Marks the `request_done` of the request `request_id` names under
    /// `request_key` forwarded, once the reader's post of it went in, so the
    /// reader forwards at most one per request in flight, the bound the
    /// owner lane's command reserve counts on (`server/ingress/commands.zig`).
    /// A request that ended since the check has no entry, and the mark finds
    /// nothing; request ids are never reused, so it never marks another
    /// request.
    pub fn markDoneForwarded(self: *RequestTable, request_id: u64, request_key: lifecycle.RequestKey) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = findLocked(self, request_id) orelse return;
        if (!entry.dispatched.request_key.eql(request_key))
            return;
        entry.done_forwarded = true;
    }

    /// The route of the request `request_id` names, from its entry or from
    /// the ring of ended requests; null for id 0 and for any request the
    /// worker never heard of or ended too long ago.
    pub fn routeOfRecent(self: *RequestTable, request_id: u64) ?config.RouteIndex {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (findLocked(self, request_id)) |entry|
            return entry.dispatched.route;
        for (0..self.ended_len) |offset| {
            // Newest first: a request id is never reused, so order only
            // shortens the usual search, a line of a request just ended.
            const index = (self.ended_next + ended_requests_max - 1 - offset) % ended_requests_max;
            if (self.ended[index].request_id == request_id)
                return self.ended[index].route;
        }
        return null;
    }

    /// Caller holds `mutex`. Id 0 matches nothing, so a worker-written 0
    /// cannot reach a free entry.
    fn findLocked(self: *RequestTable, request_id: u64) ?*Entry {
        if (request_id == 0)
            return null;
        for (&self.entries) |*entry| {
            if (entry.dispatched.request_id == request_id)
                return entry;
        }
        return null;
    }
};
