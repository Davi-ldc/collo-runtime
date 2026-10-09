//! The buffer behind one request's body: bytes from the ingress channel
//! accumulate up to a byte bound, and a single read consumes them once the
//! body is complete. The pipe also holds that read's waiter until the body
//! completes or fails, and the reason it failed. It belongs to its request
//! context on the worker's VM thread.
//!
//! A body is read once: `used` turns true when a read begins and stays true
//! after the read settles, until `reset`. Only a read whose scheduling failed
//! is undone (`rollbackPendingConsume`). A pipe made by `init` owns its bytes
//! and its waiter, and `deinit` releases both; a default pipe owns nothing.

const std = @import("std");
const common_io = @import("collo_common_io");
const deferred = @import("collo_worker_js").deferred;

pub const ReadKind = enum {
    text,
    json,
    array_buffer,
    bytes,
    blob,
    form_data,
};

pub const State = enum {
    /// No bytes so far. A reader sees a complete, empty body, and the first
    /// pushed byte moves the pipe to `open`.
    empty,
    /// Bytes may still arrive.
    open,
    complete,
    /// The body failed; `error_message` says why.
    errored,
};

/// A read waiting for the body. `content_type` is set only for a blob or
/// form-data read, allocated by the allocator `deinit` later receives.
pub const Waiter = struct {
    task_id: u64,
    kind: ReadKind = .text,
    content_type: []const u8 = "",
    deferred: deferred.DeferredOwned,

    pub fn deinit(self: *Waiter, allocator: std.mem.Allocator) void {
        if (self.kind == .blob or self.kind == .form_data) {
            allocator.free(self.content_type);
        }
        self.deferred.deinit();
        self.* = undefined;
    }
};

pub const Pipe = struct {
    allocator: ?std.mem.Allocator = null,
    state: State = .empty,
    used: bool = false,
    waiter: ?Waiter = null,
    bytes: common_io.buffer.StreamBuffer = .{ .allocator = undefined, .retain_capacity = 0 },
    max_buf: common_io.buffer.MaxBuf = .{ .budget = .{ .limit = null } },
    max_bytes: ?u64 = null,
    error_message: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, max_bytes: ?u64, state: State) Pipe {
        return .{
            .allocator = allocator,
            .state = state,
            .bytes = common_io.buffer.StreamBuffer.initDefault(allocator),
            .max_buf = common_io.buffer.MaxBuf.init(max_bytes),
            .max_bytes = max_bytes,
        };
    }

    pub fn deinit(self: *Pipe) void {
        if (self.waiter) |*waiter| {
            waiter.deinit(self.allocator.?);
            self.waiter = null;
        }
        if (self.allocator != null)
            self.bytes.deinit();
        self.* = .{};
    }

    pub fn reset(self: *Pipe, state: State) void {
        std.debug.assert(self.allocator != null);
        if (self.waiter) |*waiter| {
            waiter.deinit(self.allocator.?);
            self.waiter = null;
        }
        self.bytes.reset();
        self.max_buf = common_io.buffer.MaxBuf.init(self.max_bytes);
        self.state = state;
        self.used = false;
        self.error_message = null;
    }

    pub fn beginConsume(self: *Pipe, waiter: Waiter) !void {
        std.debug.assert(self.allocator != null);
        if (self.used or self.waiter != null)
            return error.RequestBodyAlreadyUsed;
        self.used = true;
        self.waiter = waiter;
    }

    pub fn rollbackPendingConsume(self: *Pipe) void {
        if (self.waiter) |*stored| {
            const allocator = self.allocator.?;
            stored.deinit(allocator);
            self.waiter = null;
        }
        self.used = false;
    }

    pub fn takeWaiter(self: *Pipe) ?Waiter {
        if (self.waiter == null)
            return null;
        const waiter = self.waiter.?;
        self.waiter = null;
        return waiter;
    }

    pub fn pushBytes(self: *Pipe, bytes: []const u8) !void {
        std.debug.assert(self.allocator != null);
        if (bytes.len == 0)
            return;
        try self.ensureWritable();
        try self.max_buf.checkBytes(bytes.len);
        try self.bytes.ensureUnusedCapacity(bytes.len);
        try self.accountBytes(bytes.len);
        self.bytes.writeAssumeCapacity(bytes);
        if (self.state == .empty)
            self.state = .open;
    }

    /// Charges `amount` bytes against the pipe's bound without storing them;
    /// `pushBytes` charges its own bytes here, and `pushPreAccountedBytes`
    /// stores bytes charged earlier. Fails when the body is no longer
    /// writable or the bound is exceeded.
    pub fn accountBytes(self: *Pipe, amount: usize) !void {
        std.debug.assert(self.allocator != null);
        if (amount == 0)
            return;
        try self.ensureWritable();
        try self.max_buf.onBytes(amount);
    }

    pub fn pushPreAccountedBytes(self: *Pipe, bytes: []const u8) !void {
        std.debug.assert(self.allocator != null);
        if (bytes.len == 0)
            return;
        try self.ensureWritable();
        try self.bytes.ensureUnusedCapacity(bytes.len);
        self.bytes.writeAssumeCapacity(bytes);
        if (self.state == .empty)
            self.state = .open;
    }

    pub fn discardBufferedBytes(self: *Pipe) void {
        std.debug.assert(self.allocator != null);
        self.bytes.reset();
    }

    fn ensureWritable(self: *const Pipe) !void {
        switch (self.state) {
            .empty, .open => {},
            .complete => return error.RequestBodyAlreadyComplete,
            .errored => return error.RequestBodyErrored,
        }
    }

    pub fn finish(self: *Pipe) void {
        std.debug.assert(self.allocator != null);
        if (self.state == .errored)
            return;
        self.state = if (self.bytes.isEmpty() and self.max_buf.used() == 0) .empty else .complete;
    }

    /// The pipe keeps `message` without copying it, so it must outlive the
    /// pipe; callers pass string literals and error names.
    pub fn fail(self: *Pipe, message: []const u8) void {
        std.debug.assert(self.allocator != null);
        self.state = .errored;
        self.error_message = message;
    }

    pub fn isComplete(self: *const Pipe) bool {
        return self.state == .empty or self.state == .complete;
    }

    pub fn hasPendingWaiter(self: *const Pipe) bool {
        return self.waiter != null;
    }

    pub fn bufferedLen(self: *const Pipe) usize {
        if (self.allocator == null)
            return 0;
        return self.bytes.size();
    }

    pub fn textSlice(self: *const Pipe) []const u8 {
        std.debug.assert(self.isComplete());
        if (self.allocator == null)
            return "";
        return self.bytes.slice();
    }
};
