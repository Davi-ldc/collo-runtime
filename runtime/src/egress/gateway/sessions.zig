//! The worker sessions attached to the gateway: each session's record and the registry that
//! assigns session ids and holds the records. Only the gateway's loop thread touches them.
//!
//! A session is one attach of one worker. The registry assigns its id from a counter that starts
//! at 1 and skips 0. An egress token names its session by id (`common/ipc/egress_token.zig`), so no
//! id may come back within one gateway's life, or a later session would be admitted under an
//! earlier one's tokens; a 64-bit counter that counts attaches cannot wrap that soon.
//!
//! What one session can make the gateway hold is bounded by the session's own caps, whatever the
//! worker sends: at most `Policy.max_active_fetches_per_worker_session` fetch records
//! (`fetch_table.zig`), each with at most one task and its response queue in its shard's budgeted
//! allocator, which the engine holds only until it lets go of a fetch the gateway canceled
//! (`runtime/fetch_flow.zig`); at most `ipc.fetch_limits.request_body_pooled_in_flight_bytes_max`
//! of pooled upload buffers with the copies of their starts, out of the gateway's upload budget
//! (`containment.zig`); and one extent ledger of `ipc.egress_shared.body_pool_slot_count` entries
//! while any extent is outstanding. A refused command allocates nothing, so a worker that sends
//! only refused commands holds the record alone.
//!
//! The extent ledger maps each body-pool extent the worker still holds to the shard, the engine
//! run and the flow-control credit it carries, so the credit goes back to that shard's engine when
//! the worker returns the extent, after the fetch that published it may have ended, unless the
//! shard restarted since, which drops it. The pool authenticates a
//! release by the generation and length in its own slot table; the ledger is the gateway's
//! private copy of the same facts, and a release it cannot match removes the session
//! (`runtime/release_flow.zig`). The ledger's entries exist only while an extent is outstanding,
//! so an idle session holds none.

const std = @import("std");
const ipc = @import("collo_ipc");

const body_credit = @import("collo_egress_client").body_credit;
const engine_mod = @import("engine.zig");
const fetch_table = @import("fetch_table.zig");
const policy_mod = @import("policy.zig");

pub const Session = struct {
    id: u64,
    security_cell_id: policy_mod.SecurityCellId,
    endpoint: ipc.egress_shared.Endpoint,
    /// The session's fetches, from admission to the terminal packet the worker reads; the list's
    /// length is the count `Policy.max_active_fetches_per_worker_session` caps.
    fetches: fetch_table.List = .{},
    /// Bytes the session's pooled fetches hold in the gateway, each its body's announced length
    /// plus the copies of its start (`ipc.fetch_limits.pooledStartHeldBytes`), from admission to
    /// each fetch's end (`runtime/fetch_flow.zig`). Admission refuses a pooled start that would
    /// take it past `ipc.fetch_limits.request_body_pooled_in_flight_bytes_max`.
    upload_bytes_in_flight: u64 = 0,
    /// Set by the server's `boot_ended`, after which the session's boot token admits nothing
    /// although its deadline has not passed.
    boot_ended: bool = false,
    extents: ExtentLedger = .{},
    /// A completion-eventfd write owed to this worker, held until the end of the gateway's
    /// current shard-ready pass so that the pass costs the worker one wake instead of one per
    /// packet (`runtime/shard_flow.zig`).
    completion_notify_pending: bool = false,
    /// The command ring's `dropped_packets` at the last drain (`wakeWorkerAfterCommandDrops` in
    /// `runtime/session_flow.zig`).
    last_seen_command_drops: u64 = 0,
    /// When the session's completion ring reached the `hard` mark, or 0 while it is below
    /// (`runtime/session_flow.zig`).
    hard_since_ns: u64 = 0,
    /// Whether the session is in the gateway's attention list (`runtime/session_flow.zig`).
    attention_queued: bool = false,
    /// Whether the session's fetches must be pumped again because its body pool gained room.
    rescan_pending: bool = false,
    /// Whether a body drain stopped because the completion ring lacked room, so the session stays
    /// in the attention list until the ring has room (`runtime/session_flow.zig:awaitRingRoom`).
    ring_room_pending: bool = false,
    /// Set by `Registry.markForDrop`; the loop removes the session at the end of its pass.
    drop_pending: bool = false,

    /// Frees what the session owns once the caller has ended its fetches.
    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        std.debug.assert(self.fetches.len == 0);
        self.extents.deinit(allocator);
        self.endpoint.deinit();
        self.* = undefined;
    }
};

/// One extent the worker holds: what the gateway published in its slot and the credit that goes
/// back to the engine of shard `shard_index` when the worker returns it, if that engine is still
/// in run `run`, which issued the credit. A worker may hold an extent across a restart of its
/// shard, and a credit of the run that ended must not reach a stream of the next.
pub const Extent = struct {
    generation: u32,
    /// Never 0 for a published extent, so 0 marks an empty entry.
    len: u32,
    shard_index: u32,
    run: engine_mod.Run,
    credit: body_credit.Handle,
};

const empty_extent = Extent{ .generation = 0, .len = 0, .shard_index = 0, .run = 0, .credit = .none };

pub const ExtentLedger = struct {
    /// Indexed by body-pool slot; allocated with the first outstanding extent and freed with the
    /// last, so an idle session holds none.
    entries: ?*[ipc.egress_shared.body_pool_slot_count]Extent = null,
    outstanding: u32 = 0,

    pub fn deinit(self: *ExtentLedger, allocator: std.mem.Allocator) void {
        if (self.entries) |entries|
            allocator.destroy(entries);
        self.* = undefined;
    }

    /// Makes sure the next `record` calls cannot fail, which a publication needs before it makes
    /// extents visible to the worker. Fails with `error.OutOfMemory`.
    pub fn reserve(self: *ExtentLedger, allocator: std.mem.Allocator) !void {
        if (self.entries != null)
            return;
        const entries = try allocator.create([ipc.egress_shared.body_pool_slot_count]Extent);
        entries.* = @splat(empty_extent);
        self.entries = entries;
    }

    /// Records an extent the gateway has just published, after `reserve`, with the credit run
    /// `run` of shard `shard_index`'s engine issued.
    pub fn record(
        self: *ExtentLedger,
        handle: ipc.egress_shared.BodyPoolHandle,
        len: u32,
        shard_index: usize,
        run: engine_mod.Run,
        credit: body_credit.Handle,
    ) void {
        std.debug.assert(len != 0);
        const entries = self.entries.?;
        // The gateway's own freshly published handle cannot be malformed.
        const index = ipc.egress_shared.slotIndexForHandle(handle) catch unreachable;
        std.debug.assert(entries[index].len == 0);
        entries[index] = .{
            .generation = @intCast(handle >> 32),
            .len = len,
            .shard_index = @intCast(shard_index),
            .run = run,
            .credit = credit,
        };
        self.outstanding += 1;
    }

    /// Takes the entry of an extent the worker released and frees the entries once none is
    /// outstanding. Returns null when the ledger holds no extent of that handle and length, which
    /// means the worker released something the gateway never published to it.
    pub fn take(
        self: *ExtentLedger,
        allocator: std.mem.Allocator,
        released: ipc.egress_shared.BodyPoolView.ReleasedExtent,
    ) ?Extent {
        const entries = self.entries orelse return null;
        const index = ipc.egress_shared.slotIndexForHandle(released.handle) catch return null;
        const entry = entries[index];
        if (entry.len == 0)
            return null;
        if (entry.generation != @as(u32, @intCast(released.handle >> 32)) or entry.len != released.len)
            return null;
        entries[index] = empty_extent;
        self.outstanding -= 1;
        if (self.outstanding == 0) {
            allocator.destroy(entries);
            self.entries = null;
        }
        return entry;
    }
};

pub const Attached = struct {
    index: usize,
    session_id: u64,
};

pub const Registry = struct {
    list: std.ArrayListUnmanaged(Session) = .empty,
    index_by_id: std.AutoHashMapUnmanaged(u64, usize) = .empty,
    next_session_id: u64 = 1,
    /// Sessions whose `drop_pending` is set.
    drops_pending: usize = 0,

    /// Frees every session; the caller has ended their fetches.
    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        for (self.list.items) |*session|
            session.deinit(allocator);
        self.list.deinit(allocator);
        self.index_by_id.deinit(allocator);
        self.* = undefined;
    }

    pub fn len(self: *const Registry) usize {
        return self.list.items.len;
    }

    /// Attaches a new session that takes over `endpoint`, leaving it undefined, and stamps the
    /// session id into each of its rings and pools. On error the caller still owns `endpoint`.
    pub fn attach(
        self: *Registry,
        allocator: std.mem.Allocator,
        endpoint: *ipc.egress_shared.Endpoint,
        security_cell_id: policy_mod.SecurityCellId,
    ) !Attached {
        try self.index_by_id.ensureUnusedCapacity(allocator, 1);
        try self.list.ensureUnusedCapacity(allocator, 1);
        const session_id = self.nextSessionId();

        endpoint.command.setSession(session_id, session_id);
        endpoint.completion.setSession(session_id, session_id);
        endpoint.body_pool.setSession(session_id, session_id);
        endpoint.upload_pool.setSession(session_id, session_id);

        const index = self.list.items.len;
        self.index_by_id.putAssumeCapacityNoClobber(session_id, index);
        self.list.appendAssumeCapacity(.{
            .id = session_id,
            .security_cell_id = security_cell_id,
            .endpoint = endpoint.*,
        });
        endpoint.* = undefined;
        return .{ .index = index, .session_id = session_id };
    }

    /// Removes the session in slot `index` and returns it; the caller ends its fetches and then
    /// calls `deinit`. The last session moves into `index`.
    pub fn removeAt(self: *Registry, index: usize) Session {
        std.debug.assert(index < self.list.items.len);
        const removed = self.list.swapRemove(index);
        const was_indexed = self.index_by_id.remove(removed.id);
        std.debug.assert(was_indexed);
        if (removed.drop_pending)
            self.drops_pending -= 1;
        if (index < self.list.items.len) {
            const moved = self.index_by_id.getPtr(self.list.items[index].id).?;
            moved.* = index;
        }
        return removed;
    }

    pub fn byIndex(self: *Registry, index: usize) *Session {
        std.debug.assert(index < self.list.items.len);
        return &self.list.items[index];
    }

    pub fn byId(self: *Registry, session_id: u64) ?*Session {
        const index = self.index_by_id.get(session_id) orelse return null;
        return &self.list.items[index];
    }

    pub fn indexOf(self: *const Registry, session_id: u64) ?usize {
        return self.index_by_id.get(session_id);
    }

    /// Marks `session` for removal at the end of the loop's pass. Marking never fails and never
    /// allocates, so every path that finds a session broken can mark it.
    pub fn markForDrop(self: *Registry, session: *Session) void {
        if (session.drop_pending)
            return;
        session.drop_pending = true;
        self.drops_pending += 1;
    }

    /// The slot of a session marked for drop, or null when none is. The caller removes it before
    /// asking again.
    pub fn nextDrop(self: *const Registry) ?usize {
        if (self.drops_pending == 0)
            return null;
        for (self.list.items, 0..) |session, index| {
            if (session.drop_pending)
                return index;
        }
        unreachable;
    }

    fn nextSessionId(self: *Registry) u64 {
        const session_id = self.next_session_id;
        self.next_session_id +%= 1;
        if (self.next_session_id == 0)
            self.next_session_id = 1;
        return session_id;
    }
};
