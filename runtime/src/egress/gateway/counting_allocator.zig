//! The allocator of one shard's engine: a `std.mem.Allocator` that forwards to its child and
//! keeps an atomic count of live bytes. With a budget it also refuses any growth past it, so a
//! runaway shard fails its own allocations with `error.OutOfMemory` instead of leaving the kernel
//! to pick an out-of-memory victim. The engine handles that error like any other: the fetch whose
//! publication allocated is demoted, and any other failure restarts the shard (`engine.zig`,
//! `runtime/shard_flow.zig`). The budget is `supervisor_limits.shard_memory`.
//!
//! The shard's engine threads and the gateway's loop thread allocate through it concurrently, so
//! the count and the budget are atomics and no lock is taken. The cost is one or two atomic
//! operations per allocator call, which the shard-count research found to be noise next to the
//! owner-loop serialization the gateway is bound by.

const std = @import("std");

pub const CountingAllocator = struct {
    /// The backing allocator, which also owns this struct's heap cell (`shard.Shard.init`). The
    /// cell must never move: the engine copies the `std.mem.Allocator`, pointer included, and
    /// every engine thread dereferences that pointer for the shard's whole lifetime.
    child: std.mem.Allocator,
    /// Bytes allocated and not yet freed, counted by requested length. The allocator interface
    /// passes that same length back to resize, remap and free, so every addition meets its exact
    /// subtraction. Monotonic ordering suffices: the count orders no other memory access.
    live_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// The shard's budget in bytes, or 0 for none. Production sets it once when the shard is
    /// built, and it survives engine restarts because a restart reuses this cell
    /// (`shard.Shard.restart`). It is atomic so tests can change it while engine threads
    /// allocate.
    budget_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn liveBytes(self: *const CountingAllocator) u64 {
        return self.live_bytes.load(.monotonic);
    }

    pub fn budgetBytes(self: *const CountingAllocator) u64 {
        return self.budget_bytes.load(.monotonic);
    }

    /// Replaces the budget; 0 removes it. Only tests call this, possibly while engine threads
    /// allocate: a reservation already in flight is judged against whichever budget it loaded.
    pub fn setBudget(self: *CountingAllocator, budget: u64) void {
        self.budget_bytes.store(budget, .monotonic);
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    /// Admits `delta` new bytes against the budget. It adds first and backs out on refusal
    /// instead of looping on compare-exchange, so the common, admitted case is one wait-free
    /// atomic. The back-out subtracts exactly the delta this call added, so it can neither
    /// underflow the count nor let a reservation past the budget: whichever reservation pushes the
    /// sum over the budget removes itself again. Until it does, the count overshoots; a
    /// concurrent stats read may see that, and a concurrent reservation may be refused because of
    /// it, but admitted memory never exceeds the budget. The comparison saturates so a huge
    /// `delta` cannot wrap the check, and the wrapping add and subtract still cancel exactly.
    fn tryReserve(self: *CountingAllocator, delta: usize) bool {
        if (delta == 0)
            return true;
        const budget = self.budget_bytes.load(.monotonic);
        const prior = self.live_bytes.fetchAdd(delta, .monotonic);
        if (budget != 0 and prior +| delta > budget) {
            _ = self.live_bytes.fetchSub(delta, .monotonic);
            return false;
        }
        return true;
    }

    // The atomic subtraction wraps instead of trapping, so freeing memory this
    // allocator never counted shows up under a budget as a shard that refuses
    // every allocation, instead of undefined behavior here.
    fn release(self: *CountingAllocator, delta: usize) void {
        if (delta == 0)
            return;
        _ = self.live_bytes.fetchSub(delta, .monotonic);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        // Reserve before delegating: checking after the child allocation
        // would let two racing threads both obtain memory past the budget.
        if (!self.tryReserve(len))
            return null;
        const result = self.child.rawAlloc(len, alignment, ret_addr) orelse {
            self.release(len);
            return null;
        };
        return result;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) {
            const delta = new_len - memory.len;
            if (!self.tryReserve(delta))
                return false;
            if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) {
                self.release(delta);
                return false;
            }
            return true;
        }
        // A shrink or a same-length resize never consults the budget: it only
        // returns headroom, and refusing it would wedge cleanup at the budget.
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr))
            return false;
        self.release(memory.len - new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) {
            const delta = new_len - memory.len;
            if (!self.tryReserve(delta))
                return null;
            const result = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse {
                self.release(delta);
                return null;
            };
            return result;
        }
        const result = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.release(memory.len - new_len);
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
        self.release(memory.len);
    }
};
