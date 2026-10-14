//! The gateway's fetches: one record per fetch, from its admission to the terminal packet the
//! worker reads, in one table the gateway's loop thread owns. A record names its session, the ids
//! the worker chose, the shard it runs on and what it holds: the assembly state of a pooled
//! request body (`Upload`) or the task and response queue the shard's engine runs. Nothing else in
//! the gateway describes a fetch, so admission reserves one record and every way a fetch ends
//! frees that one record (`runtime/fetch_flow.zig`).
//!
//! A record is addressed by a handle, its slot index and the slot's generation, which is never 0.
//! A freed slot's generation moves on, so a handle kept after its fetch ended, such as the one a
//! queued wake token carries, resolves to nothing. Within a session a fetch id names at most one
//! record, and every lookup by id keys on the session as well, so one worker's ids never resolve
//! to another worker's fetch. Each session links its records in a list whose head and length the
//! session record holds (`sessions.Session.fetches`), and the table counts each security cell's
//! records, so the caps admission applies are the lengths of what the table holds.
//!
//! The slots grow to the most records the gateway held at once and never shrink; pointers into
//! them are valid only until the next `insert`.

const std = @import("std");
const ipc = @import("collo_ipc");

const engine_mod = @import("engine.zig");
const policy_mod = @import("policy.zig");

pub const Index = u32;
pub const null_index: Index = std.math.maxInt(Index);

/// A record's name outside the table: the generation in the high 32 bits and the slot index in
/// the low 32. Never 0, since generations skip 0.
pub const Handle = u64;

pub fn handleOf(index: Index, generation: u32) Handle {
    std.debug.assert(generation != 0);
    return (@as(u64, generation) << 32) | index;
}

fn indexOf(handle: Handle) Index {
    return @truncate(handle);
}

fn generationOf(handle: Handle) u32 {
    return @intCast(handle >> 32);
}

/// One session's records, linked through `Fetch.prev` and `Fetch.next`.
pub const List = struct {
    first: Index = null_index,
    len: u32 = 0,
};

/// What a fetch whose request body travels through the upload pool holds while the body arrives
/// (`runtime/upload_flow.zig`): a copy of its start and the assembly buffer. It lives on the heap,
/// so its deadline node stays put while the table's slots move. The record, the copies and the
/// buffer all come from the gateway's upload allocator, and the session counts them with the
/// body's length in its upload bytes (`ipc.fetch_limits.pooledStartHeldBytes`).
pub const Upload = struct {
    /// What admission granted the fetch, which its submission passes on.
    grant: engine_mod.Grant,
    /// The start's wire flags without the pooled bit, so the task stores the flags an inline
    /// start would carry.
    flags: u32,
    method: []u8,
    url: []u8,
    /// Flat name and value bytes that `headers` slices point into.
    header_bytes: []u8,
    headers: []ipc.RequestHeader,
    /// Sized to the announced length. Submission hands it to the engine with `allocator` and
    /// empties this field.
    buffer: []u8,
    /// The gateway's upload allocator, budgeted at `containment.upload_memory`, which allocated
    /// the record and everything it holds.
    allocator: std.mem.Allocator,
    /// Bytes assembled so far. Extents arrive in order, each announcing the running total.
    received: u64 = 0,
    /// The record this upload belongs to, for the expiry pass that finds it by deadline.
    handle: Handle,
    /// Links every upload in deadline order (`runtime/upload_flow.zig`).
    deadline_node: std.DoublyLinkedList.Node = .{},

    comptime {
        // The record allowance both ends count for a pooled start holds the record.
        std.debug.assert(@sizeOf(Upload) <= ipc.fetch_limits.pooled_start_record_bytes);
    }

    /// Frees what the upload holds, the buffer if it still does, and the record itself.
    pub fn destroy(self: *Upload) void {
        const allocator = self.allocator;
        allocator.free(self.method);
        allocator.free(self.url);
        allocator.free(self.headers);
        allocator.free(self.header_bytes);
        if (self.buffer.len != 0)
            allocator.free(self.buffer);
        self.* = undefined;
        allocator.destroy(self);
    }

    /// The instant from which the upload's token admits nothing; no deadline, which only a test's
    /// token has, sorts last.
    pub fn deadline(self: *const Upload) u64 {
        const value = self.grant.deadline_mono_ns;
        return if (value == 0) std.math.maxInt(u64) else value;
    }
};

pub const Stage = union(enum) {
    /// Reserved by admission, which hands the fetch over before it returns: to the upload
    /// assembler or to the shard's engine. A handover that fails ends the record from here.
    admitting,
    /// A pooled request body still arriving.
    assembling: *Upload,
    /// Submitted to the shard's engine; the record holds one reference to each.
    running: engine_mod.Running,
};

/// How a fetch ends, which decides its terminal packet. The record keeps it from the moment the
/// gateway decided until the fetch retires, which waits for the engine to let go of a running
/// fetch (`runtime/fetch_flow.zig`).
pub const Ending = union(enum) {
    /// `egress_body_end`: the worker received the whole body.
    body_end,
    /// `egress_fetch_error` with this message, which stays valid until the record's task is
    /// released: a constant, or text the task's result or queue owns.
    failed: Failure,
    /// `egress_abort_ack`, the answer to the worker's stop.
    stopped,
    /// No packet: the session is gone, or its completion ring could not take one and the session
    /// is marked for drop.
    silent,
};

pub const Failure = struct {
    message: []const u8,
    cause: ipc.EgressFetchErrorCause = .failed,
};

pub const Fetch = struct {
    session_id: u64,
    fetch_id: u64,
    /// Chosen by the worker and echoed in every packet about the fetch; nothing keys on it.
    body_id: u64,
    shard_index: usize,
    /// The announced length of a pooled request body plus the copies of its start
    /// (`ipc.fetch_limits.pooledStartHeldBytes`), which the session's `upload_bytes_in_flight`
    /// holds until the fetch ends; 0 for an inline body.
    upload_bytes: u64,
    /// Admitted under the session's boot token, whose end ends the fetch
    /// (`runtime/fetch_flow.zig:endBootFetches`).
    boot: bool = false,
    stage: Stage,
    head_sent: bool = false,
    /// The head found the completion ring short of room and waits for the session's attention
    /// pass to find room (`runtime/session_flow.zig:queueHead`).
    head_waits_room: bool = false,
    /// Whether the response queue is armed, so the engine wakes the loop when it has something.
    pull_armed: bool = false,
    ending: ?Ending = null,
    prev: Index = null_index,
    next: Index = null_index,
};

pub const Table = struct {
    slots: std.ArrayListUnmanaged(Slot) = .empty,
    free_head: Index = null_index,
    by_fetch: std.AutoHashMapUnmanaged(Key, Index) = .empty,
    /// Records per security cell; a cell with none has no entry.
    cells: std.AutoHashMapUnmanaged(policy_mod.SecurityCellId, u32) = .empty,

    const Key = struct {
        session_id: u64,
        fetch_id: u64,
    };

    const Slot = struct {
        generation: u32 = 1,
        entry: union(enum) {
            free: Index,
            live: Fetch,
        },
    };

    /// Frees the table's storage. Every record must have retired first, which frees what it held.
    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        std.debug.assert(self.by_fetch.count() == 0);
        self.slots.deinit(allocator);
        self.by_fetch.deinit(allocator);
        self.cells.deinit(allocator);
        self.* = undefined;
    }

    pub fn count(self: *const Table) usize {
        return self.by_fetch.count();
    }

    pub fn cellCount(self: *const Table, cell: policy_mod.SecurityCellId) u32 {
        return self.cells.get(cell) orelse 0;
    }

    /// Whether the session already has a record of `fetch_id`.
    pub fn contains(self: *const Table, session_id: u64, fetch_id: u64) bool {
        return self.by_fetch.contains(.{ .session_id = session_id, .fetch_id = fetch_id });
    }

    /// Adds `fetch`, links it at the head of its session's `list` and counts it in `cell`, and
    /// returns its handle. The caller has checked that the session holds no record of the fetch
    /// id. Fails with `error.OutOfMemory`, leaving the table, the list and the count unchanged.
    pub fn insert(
        self: *Table,
        allocator: std.mem.Allocator,
        list: *List,
        cell: policy_mod.SecurityCellId,
        fetch: Fetch,
    ) !Handle {
        const key = Key{ .session_id = fetch.session_id, .fetch_id = fetch.fetch_id };
        std.debug.assert(!self.by_fetch.contains(key));
        try self.by_fetch.ensureUnusedCapacity(allocator, 1);
        try self.cells.ensureUnusedCapacity(allocator, 1);
        if (self.free_head == null_index) {
            if (self.slots.items.len == null_index)
                return error.OutOfMemory;
            const index: Index = @intCast(self.slots.items.len);
            try self.slots.append(allocator, .{ .entry = .{ .free = null_index } });
            self.free_head = index;
        }

        const index = self.free_head;
        const slot = &self.slots.items[index];
        self.free_head = slot.entry.free;
        slot.entry = .{ .live = fetch };
        const record = &slot.entry.live;
        record.prev = null_index;
        record.next = list.first;
        if (list.first != null_index)
            self.at(list.first).prev = index;
        list.first = index;
        list.len += 1;
        self.by_fetch.putAssumeCapacityNoClobber(key, index);
        const cell_count = self.cells.getOrPutAssumeCapacity(cell);
        cell_count.value_ptr.* = if (cell_count.found_existing) cell_count.value_ptr.* + 1 else 1;
        return handleOf(index, slot.generation);
    }

    /// The live record `handle` names, or null when its fetch has ended.
    pub fn get(self: *Table, handle: Handle) ?*Fetch {
        const index = indexOf(handle);
        if (index >= self.slots.items.len)
            return null;
        const slot = &self.slots.items[index];
        if (slot.generation != generationOf(handle))
            return null;
        return switch (slot.entry) {
            .live => |*fetch| fetch,
            .free => null,
        };
    }

    /// The handle of the session's record of `fetch_id`, or null when it has none.
    pub fn find(self: *const Table, session_id: u64, fetch_id: u64) ?Handle {
        const index = self.by_fetch.get(.{ .session_id = session_id, .fetch_id = fetch_id }) orelse
            return null;
        return handleOf(index, self.slots.items[index].generation);
    }

    /// The live record in slot `index`, which a session list or a handle named.
    pub fn at(self: *Table, index: Index) *Fetch {
        return &self.slots.items[index].entry.live;
    }

    pub fn handleAt(self: *const Table, index: Index) Handle {
        std.debug.assert(self.slots.items[index].entry == .live);
        return handleOf(index, self.slots.items[index].generation);
    }

    /// Slots to walk with `liveAt` when the caller needs every record, such as a shard's.
    pub fn slotCount(self: *const Table) usize {
        return self.slots.items.len;
    }

    /// The record in slot `index`, or null for a free slot.
    pub fn liveAt(self: *Table, index: usize) ?*Fetch {
        return switch (self.slots.items[index].entry) {
            .live => |*fetch| fetch,
            .free => null,
        };
    }

    /// Takes the record `handle` names out of the table, its session's `list` and the count of
    /// `cell`, and returns it; the caller frees what it held. The slot's generation moves on, so
    /// `handle` resolves to nothing from now on.
    pub fn remove(
        self: *Table,
        list: *List,
        cell: policy_mod.SecurityCellId,
        handle: Handle,
    ) Fetch {
        const index = indexOf(handle);
        const slot = &self.slots.items[index];
        std.debug.assert(slot.generation == generationOf(handle));
        const removed = slot.entry.live;
        if (removed.prev != null_index)
            self.at(removed.prev).next = removed.next
        else
            list.first = removed.next;
        if (removed.next != null_index)
            self.at(removed.next).prev = removed.prev;
        list.len -= 1;
        const was_indexed = self.by_fetch.remove(.{ .session_id = removed.session_id, .fetch_id = removed.fetch_id });
        std.debug.assert(was_indexed);
        const cell_count = self.cells.getPtr(cell).?;
        if (cell_count.* == 1) {
            _ = self.cells.remove(cell);
        } else {
            cell_count.* -= 1;
        }
        slot.generation +%= 1;
        if (slot.generation == 0)
            slot.generation = 1;
        slot.entry = .{ .free = self.free_head };
        self.free_head = index;
        return removed;
    }
};
