//! Byte accounting for streamed bodies and a growable byte queue. A budget
//! never records an amount that would overflow or pass its limit, and a
//! refused amount leaves it unchanged. No type here is thread-safe; each
//! belongs to one owner.

const std = @import("std");

/// Bytes reserved against an optional limit. A null limit still refuses a
/// reservation that would overflow the count.
pub const ByteBudget = struct {
    limit: ?u64,
    used: u64 = 0,

    pub fn init(limit: ?u64) ByteBudget {
        return .{ .limit = limit };
    }

    pub fn tryReserve(self: *ByteBudget, amount: u64) !void {
        self.checkReserve(amount) catch |err| switch (err) {
            error.ByteBudgetExceeded, error.ByteBudgetOverflow => return err,
        };
        self.used += amount;
    }

    pub fn checkReserve(self: *const ByteBudget, amount: u64) !void {
        const next = std.math.add(u64, self.used, amount) catch
            return error.ByteBudgetOverflow;
        if (self.limit) |limit| {
            if (next > limit)
                return error.ByteBudgetExceeded;
        }
    }

    pub fn release(self: *ByteBudget, amount: u64) !void {
        if (amount > self.used)
            return error.ByteBudgetUnderflow;
        self.used -= amount;
    }

    pub fn remaining(self: *const ByteBudget) ?u64 {
        const limit = self.limit orelse return null;
        return limit - self.used;
    }

    pub fn available(self: *const ByteBudget, amount: u64) bool {
        self.checkReserve(amount) catch return false;
        return true;
    }
};

/// A `ByteBudget` for one stream that reports a refusal as
/// `error.MaxBufferExceeded` and records it in `exceeded`.
pub const MaxBuf = struct {
    budget: ByteBudget,
    exceeded: bool = false,

    pub fn init(limit: ?u64) MaxBuf {
        return .{ .budget = .init(limit) };
    }

    pub fn onBytes(self: *MaxBuf, amount: u64) !void {
        self.budget.tryReserve(amount) catch |err| switch (err) {
            error.ByteBudgetExceeded, error.ByteBudgetOverflow => {
                self.exceeded = true;
                return error.MaxBufferExceeded;
            },
        };
    }

    /// Records `amount` that the caller already passed through `checkBytes`
    /// with nothing recorded in between; it only asserts the bound.
    pub fn onBytesAssumeChecked(self: *MaxBuf, amount: u64) void {
        std.debug.assert(amount <= std.math.maxInt(u64) - self.budget.used);
        const next = self.budget.used + amount;
        if (self.budget.limit) |limit|
            std.debug.assert(next <= limit);
        self.budget.used = next;
    }

    pub fn checkBytes(self: *MaxBuf, amount: u64) !void {
        self.budget.checkReserve(amount) catch |err| switch (err) {
            error.ByteBudgetExceeded, error.ByteBudgetOverflow => {
                self.exceeded = true;
                return error.MaxBufferExceeded;
            },
        };
    }

    pub fn remaining(self: *const MaxBuf) ?u64 {
        return self.budget.remaining();
    }

    pub fn used(self: *const MaxBuf) u64 {
        return self.budget.used;
    }
};

/// A byte queue: writes append and `advance` consumes from the front. Once
/// the last byte is consumed the buffer resets, freeing its allocation if it
/// grew past `retain_capacity`, so a drained buffer keeps at most that much.
pub const StreamBuffer = struct {
    allocator: std.mem.Allocator,
    bytes: std.array_list.Aligned(u8, null) = .{},
    cursor: usize = 0,
    retain_capacity: usize,

    pub fn init(allocator: std.mem.Allocator, retain_capacity: usize) StreamBuffer {
        return .{
            .allocator = allocator,
            .retain_capacity = retain_capacity,
        };
    }

    /// Keeps up to one page across resets.
    pub fn initDefault(allocator: std.mem.Allocator) StreamBuffer {
        return init(allocator, std.heap.page_size_min);
    }

    pub fn deinit(self: *StreamBuffer) void {
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn size(self: *const StreamBuffer) usize {
        return self.bytes.items.len - self.cursor;
    }

    pub fn capacity(self: *const StreamBuffer) usize {
        return self.bytes.capacity;
    }

    pub fn memoryCost(self: *const StreamBuffer) usize {
        return self.bytes.capacity;
    }

    pub fn isEmpty(self: *const StreamBuffer) bool {
        return self.size() == 0;
    }

    /// The unconsumed bytes. A write that grows the buffer, `compact`, and an
    /// `advance` or `reset` that empties it all invalidate the slice.
    pub fn slice(self: *const StreamBuffer) []const u8 {
        return self.bytes.items[self.cursor..];
    }

    pub fn mutableSlice(self: *StreamBuffer) []u8 {
        return self.bytes.items[self.cursor..];
    }

    pub fn ensureUnusedCapacity(self: *StreamBuffer, additional_count: usize) !void {
        try self.bytes.ensureUnusedCapacity(self.allocator, additional_count);
    }

    /// Bytes that can be appended without growing the allocation. Growing
    /// moves the bytes, so while another component holds a pointer into the
    /// buffer, a writer must stay within this bound.
    pub fn unusedCapacity(self: *const StreamBuffer) usize {
        return self.bytes.capacity - self.bytes.items.len;
    }

    pub fn write(self: *StreamBuffer, data: []const u8) !void {
        try self.bytes.appendSlice(self.allocator, data);
    }

    pub fn writeAssumeCapacity(self: *StreamBuffer, data: []const u8) void {
        self.bytes.appendSliceAssumeCapacity(data);
    }

    pub fn advance(self: *StreamBuffer, amount: usize) !void {
        if (amount > self.size())
            return error.StreamBufferAdvancePastEnd;
        self.cursor += amount;
        if (self.cursor == self.bytes.items.len)
            self.reset();
    }

    pub fn compact(self: *StreamBuffer) void {
        if (self.cursor == 0)
            return;
        const remaining = self.bytes.items[self.cursor..];
        std.mem.copyForwards(u8, self.bytes.items[0..remaining.len], remaining);
        self.bytes.items.len = remaining.len;
        self.cursor = 0;
    }

    pub fn reset(self: *StreamBuffer) void {
        self.cursor = 0;
        if (self.bytes.capacity > self.retain_capacity) {
            self.bytes.deinit(self.allocator);
            self.bytes = .{};
            return;
        }
        self.bytes.clearRetainingCapacity();
    }
};
