//! The slabs of one ingress lane: fixed arrays of connection and request
//! slots handed out by key, owned and used by the lane thread.
//!
//! Invariants:
//! - A key names a lane, a slot and the slot's generation. Releasing a slot
//!   advances its generation, so a key kept past the release looks up as
//!   `vacant` until the slot is reused and as `stale_generation` after, and
//!   acts on nothing.
//! - A slab never grows after init; a full slab refuses the allocation.
//! - The connection slab owns each connection's socket. The runner's
//!   per-connection state (`runner/connection_slot.zig`) sits at the same
//!   slot index and borrows the descriptor, and a slot is released only after
//!   the socket is closed. The runner's admitted-request slots
//!   (`runner/request_slot.zig`) likewise sit at the request slab's indices.

const std = @import("std");
const fd_mod = @import("collo_os").fd;
const lifecycle = @import("collo_server_lifecycle");

pub const invalid_slot = lifecycle.invalid_slot;
pub const ConnectionKey = lifecycle.ConnectionKey;
pub const RequestKey = lifecycle.RequestKey;
pub const WorkerKey = lifecycle.WorkerKey;

pub const LookupTag = enum {
    live,
    stale_generation,
    vacant,
    out_of_range,
};

pub fn LookupResult(comptime Slot: type) type {
    return union(LookupTag) {
        live: *Slot,
        stale_generation,
        vacant,
        out_of_range,
    };
}

pub const ConnectionLifecycleState = enum {
    vacant,
    accepting,
    tls_handshake,
    http2_connection,
    server_writing,
    worker_owned,
    closing,
};

pub const RequestTerminalState = enum {
    active,
    completed_by_worker,
    failed_before_handoff,
    failed_by_deadline,
    failed_by_worker_death,
    failed_by_handoff_error,
    closed_during_shutdown,
};

pub const RequestOwnership = lifecycle.RequestOwnershipState;

pub const ConnectionSlot = struct {
    fd: fd_mod.OwnedFd = .{},
    generation: u64 = 1,
    active: bool = false,
    next_free: u32 = invalid_slot,
    state: ConnectionLifecycleState = .vacant,
    request_state: RequestOwnership = .server_owned,
    read_buffer_id: u32 = invalid_slot,
    read_len: usize = 0,
    header_scan_offset: usize = 0,
    active_request_key: ?RequestKey = null,
    close_after_write: bool = false,
    terminal_owner: bool = false,
    read_op_generation: u64 = 0,
    write_op_generation: u64 = 0,
    tls_op_generation: u64 = 0,
    timer_op_generation: u64 = 0,
    tls_handle: ?*anyopaque = null,
    cold_debug: []u8 = &.{},

    pub fn key(self: *const ConnectionSlot, lane_id: u16, slot: u32) ConnectionKey {
        return .{ .lane_id = lane_id, .slot = slot, .generation = self.generation };
    }
};

pub const RequestSlot = struct {
    generation: u64 = 1,
    active: bool = false,
    next_free: u32 = invalid_slot,
    external_request_id: u64 = 0,
    connection_key: ConnectionKey = .{ .lane_id = 0, .slot = 0, .generation = 0 },
    worker_key: WorkerKey = .{ .worker_id = 0, .worker_generation = 0 },
    started_monotonic_ns: u64 = 0,
    deadline_monotonic_ns: u64 = 0,
    deadline_slot: u32 = invalid_slot,
    deadline_generation: u64 = 0,
    dispatch_state: RequestOwnership = .server_owned,
    terminal: RequestTerminalState = .active,
    cold_debug: []u8 = &.{},

    pub fn key(self: *const RequestSlot, lane_id: u16, slot: u32) RequestKey {
        return .{ .lane_id = lane_id, .slot = slot, .generation = self.generation };
    }

    pub fn isTerminal(self: *const RequestSlot) bool {
        return self.terminal != .active;
    }

    pub fn markTerminal(self: *RequestSlot, terminal: RequestTerminalState) bool {
        if (self.terminal != .active)
            return false;
        self.terminal = terminal;
        return true;
    }
};

pub const SlabCounters = struct {
    connection_allocations: u64 = 0,
    connection_heap_allocations: u64 = 0,
    connection_lookup_stale_generation: u64 = 0,
    connection_lookup_vacant: u64 = 0,
    connection_lookup_out_of_range: u64 = 0,
    request_allocations: u64 = 0,
    request_heap_allocations: u64 = 0,
    request_lookup_stale_generation: u64 = 0,
    request_lookup_vacant: u64 = 0,
    request_lookup_out_of_range: u64 = 0,
    external_request_id_mismatch: u64 = 0,
    connection_close_calls: u64 = 0,
    connection_release_fd_open_failures: u64 = 0,
};

pub const ConnectionSlab = struct {
    allocator: std.mem.Allocator,
    lane_id: u16,
    slots: []ConnectionSlot,
    free_head: u32,
    free_len: usize,
    counters: *SlabCounters,

    pub fn init(allocator: std.mem.Allocator, lane_id: u16, capacity: usize, counters: *SlabCounters) !ConnectionSlab {
        if (capacity == 0 or capacity > std.math.maxInt(u32))
            return error.InvalidSlabCapacity;
        const slots = try allocator.alloc(ConnectionSlot, capacity);
        errdefer allocator.free(slots);
        for (slots, 0..) |*slot, index| {
            slot.* = .{
                .generation = 1,
                .next_free = if (index + 1 < capacity) @intCast(index + 1) else invalid_slot,
            };
        }
        return .{
            .allocator = allocator,
            .lane_id = lane_id,
            .slots = slots,
            .free_head = 0,
            .free_len = capacity,
            .counters = counters,
        };
    }

    pub fn deinit(self: *ConnectionSlab) void {
        // An occupied slot is not asserted here, because the slab frees what
        // it owns either way. It means another structure still holds the key,
        // which lane teardown asserts (`deinitRuntime` in
        // `runner/ring_driver.zig`).
        for (self.slots) |*slot| {
            slot.fd.deinit();
            self.releaseCold(slot);
        }
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    /// Moves `fd` into the slot on success; on error the caller still owns it.
    pub fn alloc(self: *ConnectionSlab, fd: fd_mod.OwnedFd) !ConnectionKey {
        if (self.free_head == invalid_slot)
            return error.ConnectionSlabFull;
        const slot_index = self.free_head;
        const slot = &self.slots[slot_index];
        self.free_head = slot.next_free;
        self.free_len -= 1;
        slot.* = .{
            .fd = fd,
            .generation = slot.generation,
            .active = true,
            .state = .accepting,
            .terminal_owner = !fd.isValid(),
            .next_free = invalid_slot,
        };
        self.counters.connection_allocations += 1;
        return slot.key(self.lane_id, slot_index);
    }

    /// `releaseConnectionSlot`, except that a refusal because the socket is
    /// still open also reads as `.live`.
    pub fn release(self: *ConnectionSlab, key: ConnectionKey) LookupTag {
        return self.releaseConnectionSlot(key) catch |err| switch (err) {
            error.ConnectionFdStillOpen => .live,
        };
    }

    /// Closes the slot's socket and marks the slot closing; the slot stays
    /// allocated until it is released. The lane is the socket's only holder,
    /// so the close ends the connection.
    pub fn closeConnection(self: *ConnectionSlab, key: ConnectionKey) LookupTag {
        return switch (self.lookup(key)) {
            .live => |slot| blk: {
                if (slot.fd.isValid())
                    slot.fd.deinit();
                slot.state = .closing;
                slot.terminal_owner = true;
                self.counters.connection_close_calls += 1;
                break :blk .live;
            },
            .stale_generation => .stale_generation,
            .vacant => .vacant,
            .out_of_range => .out_of_range,
        };
    }

    /// Returns a live slot to the free list under its next generation. Fails
    /// with `error.ConnectionFdStillOpen` while the slot still owns an open
    /// socket; any other key returns its lookup tag and changes nothing.
    pub fn releaseConnectionSlot(self: *ConnectionSlab, key: ConnectionKey) !LookupTag {
        return switch (self.lookup(key)) {
            .live => |slot| blk: {
                if (slot.fd.isValid()) {
                    self.counters.connection_release_fd_open_failures += 1;
                    return error.ConnectionFdStillOpen;
                }
                self.releaseCold(slot);
                const next_generation = nextGeneration(slot.generation);
                slot.* = .{
                    .generation = next_generation,
                    .active = false,
                    .state = .vacant,
                    .next_free = self.free_head,
                };
                self.free_head = key.slot;
                self.free_len += 1;
                break :blk .live;
            },
            .stale_generation => .stale_generation,
            .vacant => .vacant,
            .out_of_range => .out_of_range,
        };
    }

    /// Moves the slot's socket to the caller, which owns it afterwards, and
    /// marks the slot closing.
    pub fn transferConnectionToTerminalOwner(self: *ConnectionSlab, key: ConnectionKey) !fd_mod.OwnedFd {
        const slot = switch (self.lookup(key)) {
            .live => |slot| slot,
            .stale_generation => return error.StaleConnectionGeneration,
            .vacant => return error.ConnectionSlotVacant,
            .out_of_range => return error.ConnectionSlotOutOfRange,
        };
        if (!slot.fd.isValid())
            return error.ConnectionFdNotOpen;
        const fd = slot.fd;
        slot.fd = .{};
        slot.terminal_owner = true;
        slot.state = .closing;
        return fd;
    }

    pub fn lookup(self: *ConnectionSlab, key: ConnectionKey) LookupResult(ConnectionSlot) {
        if (key.lane_id != self.lane_id or key.slot >= self.slots.len) {
            self.counters.connection_lookup_out_of_range += 1;
            return .out_of_range;
        }
        const slot = &self.slots[key.slot];
        if (!slot.active) {
            self.counters.connection_lookup_vacant += 1;
            return .vacant;
        }
        if (slot.generation != key.generation) {
            self.counters.connection_lookup_stale_generation += 1;
            return .stale_generation;
        }
        return .{ .live = slot };
    }

    /// Copies `text` onto the slot, replacing any earlier copy; the release
    /// frees it.
    pub fn attachColdDebug(self: *ConnectionSlab, key: ConnectionKey, text: []const u8) !void {
        const slot = switch (self.lookup(key)) {
            .live => |slot| slot,
            else => return error.ConnectionSlotNotLive,
        };
        self.releaseCold(slot);
        slot.cold_debug = try self.allocator.dupe(u8, text);
        self.counters.connection_heap_allocations += 1;
    }

    fn releaseCold(self: *ConnectionSlab, slot: *ConnectionSlot) void {
        if (slot.cold_debug.len != 0) {
            self.allocator.free(slot.cold_debug);
            slot.cold_debug = &.{};
        }
    }
};

pub const RequestSlab = struct {
    allocator: std.mem.Allocator,
    lane_id: u16,
    slots: []RequestSlot,
    free_head: u32,
    free_len: usize,
    counters: *SlabCounters,

    pub fn init(allocator: std.mem.Allocator, lane_id: u16, capacity: usize, counters: *SlabCounters) !RequestSlab {
        if (capacity == 0 or capacity > std.math.maxInt(u32))
            return error.InvalidSlabCapacity;
        const slots = try allocator.alloc(RequestSlot, capacity);
        errdefer allocator.free(slots);
        for (slots, 0..) |*slot, index| {
            slot.* = .{
                .generation = 1,
                .next_free = if (index + 1 < capacity) @intCast(index + 1) else invalid_slot,
            };
        }
        return .{
            .allocator = allocator,
            .lane_id = lane_id,
            .slots = slots,
            .free_head = 0,
            .free_len = capacity,
            .counters = counters,
        };
    }

    pub fn deinit(self: *RequestSlab) void {
        // As in ConnectionSlab.deinit, lane teardown asserts that no slot is
        // still occupied.
        for (self.slots) |*slot|
            self.releaseCold(slot);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    pub fn alloc(
        self: *RequestSlab,
        external_request_id: u64,
        connection_key: ConnectionKey,
        worker_key: WorkerKey,
        started_monotonic_ns: u64,
        deadline_monotonic_ns: u64,
    ) !RequestKey {
        if (self.free_head == invalid_slot)
            return error.RequestSlabFull;
        const slot_index = self.free_head;
        const slot = &self.slots[slot_index];
        self.free_head = slot.next_free;
        self.free_len -= 1;
        slot.* = .{
            .generation = slot.generation,
            .active = true,
            .next_free = invalid_slot,
            .external_request_id = external_request_id,
            .connection_key = connection_key,
            .worker_key = worker_key,
            .started_monotonic_ns = started_monotonic_ns,
            .deadline_monotonic_ns = deadline_monotonic_ns,
            .terminal = .active,
            .dispatch_state = .server_owned,
        };
        self.counters.request_allocations += 1;
        return slot.key(self.lane_id, slot_index);
    }

    pub fn release(self: *RequestSlab, key: RequestKey) LookupTag {
        return switch (self.lookup(key)) {
            .live => |slot| blk: {
                self.releaseCold(slot);
                const next_generation = nextGeneration(slot.generation);
                slot.* = .{
                    .generation = next_generation,
                    .active = false,
                    .next_free = self.free_head,
                };
                self.free_head = key.slot;
                self.free_len += 1;
                break :blk .live;
            },
            .stale_generation => .stale_generation,
            .vacant => .vacant,
            .out_of_range => .out_of_range,
        };
    }

    pub fn setDeadlineHandle(self: *RequestSlab, key: RequestKey, handle: anytype) !void {
        const slot = switch (self.lookup(key)) {
            .live => |slot| slot,
            .stale_generation => return error.StaleRequestGeneration,
            .vacant => return error.RequestSlotVacant,
            .out_of_range => return error.RequestSlotOutOfRange,
        };
        slot.deadline_slot = handle.slot;
        slot.deadline_generation = handle.generation;
    }

    pub fn clearDeadlineHandle(self: *RequestSlab, key: RequestKey) !void {
        const slot = switch (self.lookup(key)) {
            .live => |slot| slot,
            .stale_generation => return error.StaleRequestGeneration,
            .vacant => return error.RequestSlotVacant,
            .out_of_range => return error.RequestSlotOutOfRange,
        };
        slot.deadline_slot = invalid_slot;
        slot.deadline_generation = 0;
    }

    pub fn lookup(self: *RequestSlab, key: RequestKey) LookupResult(RequestSlot) {
        if (key.lane_id != self.lane_id or key.slot >= self.slots.len) {
            self.counters.request_lookup_out_of_range += 1;
            return .out_of_range;
        }
        const slot = &self.slots[key.slot];
        if (!slot.active) {
            self.counters.request_lookup_vacant += 1;
            return .vacant;
        }
        if (slot.generation != key.generation) {
            self.counters.request_lookup_stale_generation += 1;
            return .stale_generation;
        }
        return .{ .live = slot };
    }

    /// Marks the request completed by its worker when `external_request_id`
    /// is the slot's. Fails on a key that is not live, a different id or a
    /// request that is already terminal.
    pub fn completeByExternalId(self: *RequestSlab, key: RequestKey, external_request_id: u64) !void {
        const slot = switch (self.lookup(key)) {
            .live => |slot| slot,
            .stale_generation => return error.StaleRequestGeneration,
            .vacant => return error.RequestSlotVacant,
            .out_of_range => return error.RequestSlotOutOfRange,
        };
        if (slot.external_request_id != external_request_id) {
            self.counters.external_request_id_mismatch += 1;
            return error.ExternalRequestIdMismatch;
        }
        if (!slot.markTerminal(.completed_by_worker))
            return error.RequestAlreadyTerminal;
    }

    /// Copies `text` onto the slot, replacing any earlier copy; the release
    /// frees it.
    pub fn attachColdDebug(self: *RequestSlab, key: RequestKey, text: []const u8) !void {
        const slot = switch (self.lookup(key)) {
            .live => |slot| slot,
            else => return error.RequestSlotNotLive,
        };
        self.releaseCold(slot);
        slot.cold_debug = try self.allocator.dupe(u8, text);
        self.counters.request_heap_allocations += 1;
    }

    fn releaseCold(self: *RequestSlab, slot: *RequestSlot) void {
        if (slot.cold_debug.len != 0) {
            self.allocator.free(slot.cold_debug);
            slot.cold_debug = &.{};
        }
    }
};

pub const LaneState = struct {
    allocator: std.mem.Allocator,
    lane_id: u16,
    counters: *SlabCounters,
    connections: ConnectionSlab,
    requests: RequestSlab,

    pub fn init(
        allocator: std.mem.Allocator,
        lane_id: u16,
        max_connections: usize,
        max_requests: usize,
    ) !LaneState {
        const counters = try allocator.create(SlabCounters);
        errdefer allocator.destroy(counters);
        counters.* = .{};

        var self = LaneState{
            .allocator = allocator,
            .lane_id = lane_id,
            .counters = counters,
            .connections = undefined,
            .requests = undefined,
        };
        self.connections = try ConnectionSlab.init(allocator, lane_id, max_connections, self.counters);
        errdefer self.connections.deinit();
        self.requests = try RequestSlab.init(allocator, lane_id, max_requests, self.counters);
        return self;
    }

    pub fn deinit(self: *LaneState) void {
        self.requests.deinit();
        self.connections.deinit();
        self.allocator.destroy(self.counters);
        self.* = undefined;
    }
};

/// The generation after `generation`, skipping zero on wrap.
pub fn nextGeneration(generation: u64) u64 {
    return lifecycle.nextGeneration(generation);
}
