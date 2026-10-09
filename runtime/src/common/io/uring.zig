//! A tagged io_uring wrapper for absolute deadline timeouts, fd readiness
//! polls and their cancellation. user_data packs, from the top, the
//! `shared_supervision_high_byte` tag of `collo_io_uring_tags`, an operation
//! kind, a generation and a request id; `pack` refuses a generation above
//! `max_supervised_generation` or an id above `max_supervised_request_id`
//! instead of truncating it, so a caller must wrap its ids below that bound.
//! A completion that does not decode is dropped and counted in
//! `malformedCqeCount`, the only process-wide state here. A `Ring` belongs to
//! one thread.

const std = @import("std");

const linux = std.os.linux;
const tags = @import("collo_io_uring_tags");

const user_data_tag: u64 = tags.shared_supervision_high_byte;
const tag_shift: u6 = tags.high_byte_shift;
const kind_shift: u6 = 52;
const generation_shift: u6 = 40;
const kind_mask: u64 = (1 << (tag_shift - kind_shift)) - 1;
const request_id_mask: u64 = (1 << generation_shift) - 1;
const generation_mask: u64 = (1 << (kind_shift - generation_shift)) - 1;
var malformed_cqe_count = std.atomic.Value(u64).init(0);

pub const max_supervised_request_id: u64 = request_id_mask;
pub const max_supervised_generation: u64 = generation_mask;

// Kind 0 stays unassigned so a zeroed kind field fails to decode. The values
// above the last kind, up to the field's 4-bit maximum, take new kinds
// without changing the layout.
pub const OperationKind = enum(u4) {
    worker_request_done_ready = 1,
    worker_request_done_read = 2,
    worker_pidfd_ready = 3,
    request_hard_timeout = 4,
    worker_deadline_timeout = 5,
    worker_deadline_command = 6,
    cancel_timeout = 7,
    cancel_poll = 8,
    shutdown = 9,
    worker_memory_events = 10,
};

pub const UserData = struct {
    kind: OperationKind,
    request_id: u64 = 0,
    generation: u64 = 0,

    pub fn pack(self: UserData) !u64 {
        if (self.request_id > request_id_mask)
            return error.RequestIdTooLarge;
        if (self.generation > generation_mask)
            return error.GenerationTooLarge;

        return (user_data_tag << tag_shift) |
            (@as(u64, @intFromEnum(self.kind)) << kind_shift) |
            (self.generation << generation_shift) |
            self.request_id;
    }

    pub fn unpack(value: u64) !UserData {
        if ((value >> tag_shift) != user_data_tag)
            return error.InvalidUserDataTag;

        const kind_raw: u4 = @intCast((value >> kind_shift) & kind_mask);
        const kind = std.meta.intToEnum(OperationKind, kind_raw) catch return error.InvalidUserDataKind;

        return .{
            .kind = kind,
            .request_id = value & request_id_mask,
            .generation = (value >> generation_shift) & generation_mask,
        };
    }
};

pub const Completion = struct {
    user_data: UserData,
    res: i32,
    flags: u32,

    pub fn errno(self: Completion) ?linux.E {
        return errnoFromResult(self.res);
    }

    pub fn isCancellationCompleted(self: Completion) bool {
        return self.errno() == null;
    }

    /// A cancel that found its target already completed, already being
    /// cancelled, or gone, none of which is a failure for the caller.
    pub fn isCancellationRace(self: Completion) bool {
        const err = self.errno() orelse return false;
        return switch (err) {
            .NOENT, .ALREADY, .BUSY, .CANCELED => true,
            else => false,
        };
    }

    pub fn isCancellationRaceOrCompleted(self: Completion) bool {
        return self.isCancellationCompleted() or self.isCancellationRace();
    }
};

/// The errno of a negative CQE result; null for a success or a value outside
/// the errno range.
pub fn errnoFromResult(res: i32) ?linux.E {
    if (res >= 0 or res < -4095)
        return null;
    const errno_code: u16 = @intCast(-res);
    return @enumFromInt(errno_code);
}

pub fn malformedCqeCount() u64 {
    return malformed_cqe_count.load(.monotonic);
}

pub const Ring = struct {
    allocator: std.mem.Allocator,
    ring: linux.IoUring,
    timeout_storage: []linux.kernel_timespec,
    timeout_storage_len: usize = 0,

    pub fn initWithAllocator(allocator: std.mem.Allocator, entries: u16, flags: u32) !Ring {
        const timeout_storage = try allocator.alloc(linux.kernel_timespec, entries);
        errdefer allocator.free(timeout_storage);
        return .{
            .allocator = allocator,
            .ring = try linux.IoUring.init(entries, flags),
            .timeout_storage = timeout_storage,
        };
    }

    pub fn deinit(self: *Ring) void {
        self.ring.deinit();
        self.allocator.free(self.timeout_storage);
        self.* = undefined;
    }

    pub fn submit(self: *Ring) !u32 {
        const submitted = try self.ring.submit();
        // A timeout SQE points into `timeout_storage`, and the kernel copies
        // the timespec while io_uring_enter consumes the SQE, so the storage
        // is free once the SQEs are submitted.
        self.timeout_storage_len = 0;
        return submitted;
    }

    pub fn wait(self: *Ring, out: []Completion, wait_nr: u32) !usize {
        if (out.len == 0)
            return 0;

        var cqes: [32]linux.io_uring_cqe = undefined;
        const count = try self.ring.copy_cqes(cqes[0..@min(cqes.len, out.len)], wait_nr);
        return decodeCopiedCompletions(cqes[0..count], out);
    }

    pub fn drain(self: *Ring, out: []Completion) !usize {
        return self.wait(out, 0);
    }

    /// `deadline_ns` is absolute CLOCK_MONOTONIC, the clock
    /// IORING_TIMEOUT_ABS uses by default. Fails with
    /// `error.TimeoutStorageFull` once as many timeouts as the ring has
    /// entries are queued since the last submit.
    pub fn queueTimeoutAbsMonotonicNs(self: *Ring, user_data: UserData, deadline_ns: u64) !void {
        if (self.timeout_storage_len >= self.timeout_storage.len)
            return error.TimeoutStorageFull;
        const index = self.timeout_storage_len;
        self.timeout_storage[index] = timespecFromNs(deadline_ns);
        _ = try self.ring.timeout(try user_data.pack(), &self.timeout_storage[index], 0, linux.IORING_TIMEOUT_ABS);
        self.timeout_storage_len += 1;
    }

    pub fn queueTimeoutRemove(self: *Ring, user_data: UserData, timeout_user_data: UserData) !void {
        _ = try self.ring.timeout_remove(try user_data.pack(), try timeout_user_data.pack(), 0);
    }

    pub fn queueFdReadiness(self: *Ring, user_data: UserData, fd: std.posix.fd_t, events: u32) !void {
        _ = try self.ring.poll_add(try user_data.pack(), fd, events);
    }

    pub fn queueCancelByUserData(self: *Ring, user_data: UserData, target_user_data: UserData) !void {
        _ = try self.ring.cancel(try user_data.pack(), try target_user_data.pack(), 0);
    }

    pub fn queuePollRemove(self: *Ring, user_data: UserData, target_user_data: UserData) !void {
        _ = try self.ring.poll_remove(try user_data.pack(), try target_user_data.pack());
    }

    pub fn queueNop(self: *Ring, user_data: UserData) !void {
        _ = try self.ring.nop(try user_data.pack());
    }
};

fn decodeCompletion(cqe: linux.io_uring_cqe) !Completion {
    return .{
        .user_data = try UserData.unpack(cqe.user_data),
        .res = cqe.res,
        .flags = cqe.flags,
    };
}

/// Decodes `cqes` into `out`, which must be at least as long, dropping and
/// counting the ones that do not decode. Returns how many it wrote.
pub fn decodeCopiedCompletions(cqes: []const linux.io_uring_cqe, out: []Completion) usize {
    var written: usize = 0;
    for (cqes) |cqe| {
        const completion = decodeCompletion(cqe) catch {
            _ = malformed_cqe_count.fetchAdd(1, .monotonic);
            continue;
        };
        out[written] = completion;
        written += 1;
    }
    return written;
}

fn timespecFromNs(ns: u64) linux.kernel_timespec {
    return .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
}
