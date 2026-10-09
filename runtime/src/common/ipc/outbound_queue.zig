//! FIFO queues of whole packets for a nonblocking IPC writer: a packet that
//! met a full socket waits here, copied, until the socket drains. Each queue
//! owns a copy of every packet it holds and frees it on pop, clear or
//! deinit. Neither queue locks, so one thread owns a queue, and neither
//! bounds itself: a caller passes its packet and byte limits on every
//! limited push.

const std = @import("std");

/// One queue under one packet budget and one byte budget.
pub const PacketQueue = struct {
    packets: std.array_list.Aligned([]u8, null) = .empty,
    head: usize = 0,
    bytes: usize = 0,

    pub fn deinit(self: *PacketQueue, allocator: std.mem.Allocator) void {
        for (self.packets.items[self.head..]) |packet|
            allocator.free(packet);
        self.packets.deinit(allocator);
        self.* = undefined;
    }

    pub fn count(self: PacketQueue) usize {
        return self.packets.items.len - self.head;
    }

    pub fn hasPackets(self: PacketQueue) bool {
        return self.count() != 0;
    }

    /// Whether one more packet of `next_len` bytes stays within both limits.
    /// The byte check subtracts instead of adding, so it cannot overflow.
    pub fn canFit(self: PacketQueue, packet_limit: usize, byte_limit: usize, next_len: usize) bool {
        if (self.count() >= packet_limit)
            return false;
        if (next_len > byte_limit)
            return false;
        return self.bytes <= byte_limit - next_len;
    }

    /// Appends a copy of `bytes` with no limit; the caller keeps `bytes`.
    pub fn push(self: *PacketQueue, allocator: std.mem.Allocator, bytes: []const u8) !void {
        const owned = try allocator.dupe(u8, bytes);
        errdefer allocator.free(owned);
        try self.packets.append(allocator, owned);
        self.bytes += owned.len;
    }

    /// Appends a copy of `bytes`, or fails with `error.PacketQueueFull` when
    /// it would break either limit, leaving the queue unchanged.
    pub fn pushWithLimit(
        self: *PacketQueue,
        allocator: std.mem.Allocator,
        bytes: []const u8,
        packet_limit: usize,
        byte_limit: usize,
    ) !void {
        if (!self.canFit(packet_limit, byte_limit, bytes.len))
            return error.PacketQueueFull;
        try self.push(allocator, bytes);
    }

    /// The oldest packet, still owned by the queue and valid until it is
    /// popped or the queue is cleared.
    pub fn front(self: *PacketQueue) ?[]u8 {
        if (!self.hasPackets())
            return null;
        return self.packets.items[self.head];
    }

    pub fn popFront(self: *PacketQueue, allocator: std.mem.Allocator) void {
        const packet = self.front() orelse return;
        self.bytes -= packet.len;
        allocator.free(packet);
        self.head += 1;
        self.compactIfUseful();
    }

    pub fn clearRetainingCapacity(self: *PacketQueue, allocator: std.mem.Allocator) void {
        for (self.packets.items[self.head..]) |packet|
            allocator.free(packet);
        self.packets.clearRetainingCapacity();
        self.head = 0;
        self.bytes = 0;
    }

    /// Reclaims popped slots lazily, so a pop costs O(1) amortized: the list
    /// resets when it empties, and otherwise shifts down only once the
    /// popped prefix is both long and at least half of the list.
    fn compactIfUseful(self: *PacketQueue) void {
        if (self.head == 0)
            return;
        if (self.head == self.packets.items.len) {
            self.packets.clearRetainingCapacity();
            self.head = 0;
            return;
        }
        if (self.head < 64 or self.head * 2 < self.packets.items.len)
            return;
        const remaining = self.packets.items[self.head..];
        std.mem.copyForwards([]u8, self.packets.items[0..remaining.len], remaining);
        self.packets.shrinkRetainingCapacity(remaining.len);
        self.head = 0;
    }
};

/// Which budget of a `ReservedPacketQueue` a packet counts against. It
/// never changes the send order.
pub const Priority = enum {
    normal,
    high,
};

/// The two budgets of a `ReservedPacketQueue`, each a packet count and a
/// byte count.
pub const PriorityLimits = struct {
    normal_packets: usize,
    normal_bytes: usize,
    high_packets: usize,
    high_bytes: usize,
};

const ReservedPacket = struct {
    bytes: []u8,
    priority: Priority,
};

/// One FIFO with a separate budget per priority, so a high-priority packet,
/// such as a control packet, still fits after normal traffic has used up its
/// own budget. Packets leave in push order whatever their priority.
pub const ReservedPacketQueue = struct {
    packets: std.array_list.Aligned(ReservedPacket, null) = .empty,
    head: usize = 0,
    bytes: usize = 0,
    normal_packets: usize = 0,
    normal_bytes: usize = 0,
    high_packets: usize = 0,
    high_bytes: usize = 0,

    pub fn deinit(self: *ReservedPacketQueue, allocator: std.mem.Allocator) void {
        for (self.packets.items[self.head..]) |packet|
            allocator.free(packet.bytes);
        self.packets.deinit(allocator);
        self.* = undefined;
    }

    pub fn count(self: ReservedPacketQueue) usize {
        return self.packets.items.len - self.head;
    }

    pub fn hasPackets(self: ReservedPacketQueue) bool {
        return self.count() != 0;
    }

    /// Whether one more packet of `next_len` bytes stays within the budget
    /// of `priority`; the other budget does not matter.
    pub fn canFit(self: ReservedPacketQueue, priority: Priority, limits: PriorityLimits, next_len: usize) bool {
        const packet_count = switch (priority) {
            .normal => self.normal_packets,
            .high => self.high_packets,
        };
        const byte_count = switch (priority) {
            .normal => self.normal_bytes,
            .high => self.high_bytes,
        };
        const packet_limit = switch (priority) {
            .normal => limits.normal_packets,
            .high => limits.high_packets,
        };
        const byte_limit = switch (priority) {
            .normal => limits.normal_bytes,
            .high => limits.high_bytes,
        };

        if (packet_count >= packet_limit)
            return false;
        if (next_len > byte_limit)
            return false;
        return byte_count <= byte_limit - next_len;
    }

    /// The oldest packet of either priority, still owned by the queue and
    /// valid until it is popped or the queue is cleared.
    pub fn front(self: *ReservedPacketQueue) ?[]u8 {
        if (!self.hasPackets())
            return null;
        return self.packets.items[self.head].bytes;
    }

    pub fn popFront(self: *ReservedPacketQueue, allocator: std.mem.Allocator) void {
        const packet = if (self.hasPackets()) self.packets.items[self.head] else return;
        self.bytes -= packet.bytes.len;
        switch (packet.priority) {
            .normal => {
                self.normal_packets -= 1;
                self.normal_bytes -= packet.bytes.len;
            },
            .high => {
                self.high_packets -= 1;
                self.high_bytes -= packet.bytes.len;
            },
        }
        allocator.free(packet.bytes);
        self.head += 1;
        self.compactIfUseful();
    }

    /// Appends a copy of `bytes` under `priority`'s budget, or fails with
    /// `error.PacketQueueFull` when it would break that budget, leaving the
    /// queue unchanged.
    pub fn pushWithLimit(
        self: *ReservedPacketQueue,
        allocator: std.mem.Allocator,
        bytes: []const u8,
        priority: Priority,
        limits: PriorityLimits,
    ) !void {
        if (!self.canFit(priority, limits, bytes.len))
            return error.PacketQueueFull;
        const owned = try allocator.dupe(u8, bytes);
        errdefer allocator.free(owned);
        try self.packets.append(allocator, .{ .bytes = owned, .priority = priority });
        self.bytes += owned.len;
        switch (priority) {
            .normal => {
                self.normal_packets += 1;
                self.normal_bytes += owned.len;
            },
            .high => {
                self.high_packets += 1;
                self.high_bytes += owned.len;
            },
        }
    }

    pub fn clearRetainingCapacity(self: *ReservedPacketQueue, allocator: std.mem.Allocator) void {
        for (self.packets.items[self.head..]) |packet|
            allocator.free(packet.bytes);
        self.packets.clearRetainingCapacity();
        self.head = 0;
        self.bytes = 0;
        self.normal_packets = 0;
        self.normal_bytes = 0;
        self.high_packets = 0;
        self.high_bytes = 0;
    }

    /// The same lazy reclamation as `PacketQueue.compactIfUseful`.
    fn compactIfUseful(self: *ReservedPacketQueue) void {
        if (self.head == 0)
            return;
        if (self.head == self.packets.items.len) {
            self.packets.clearRetainingCapacity();
            self.head = 0;
            return;
        }
        if (self.head < 64 or self.head * 2 < self.packets.items.len)
            return;
        const remaining = self.packets.items[self.head..];
        std.mem.copyForwards(ReservedPacket, self.packets.items[0..remaining.len], remaining);
        self.packets.shrinkRetainingCapacity(remaining.len);
        self.head = 0;
    }
};
