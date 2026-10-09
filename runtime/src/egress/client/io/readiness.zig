//! Fd readiness driver for the egress connector threads: TCP connects and,
//! through `CancelProbe`, the TLS handshake of HTTP/1 connections. One wait
//! returns one result: a ready source, a source whose deadline passed, or the
//! wake fd.
//!
//! The driver prefers an io_uring restricted to poll and timeout opcodes and
//! falls back to poll(2) when the ring cannot be created or fails at run
//! time; the one-result contract above holds on both. Deadlines are absolute
//! CLOCK_BOOTTIME nanoseconds from `monotonicNowNs`, the clock the ring's
//! absolute timeouts use.

const std = @import("std");
const io = @import("collo_egress_io");
const tags = @import("collo_io_uring_tags");
const restricted_uring = @import("collo_common_io").restricted_uring;

const linux = std.os.linux;
const ns_per_ms: u64 = std.time.ns_per_ms;
const ring_entries: u16 = 256;
const max_cqes_per_copy: usize = 64;

pub const Source = io.Source;
pub const Ready = io.Ready;

pub const Backend = enum {
    poll,
    io_uring,
};

pub const Result = union(enum) {
    ready: Ready,
    expired: *anyopaque,
    wake,
};

pub const Driver = struct {
    allocator: std.mem.Allocator,
    backend: Backend,
    poll: PollDriver,
    uring: ?UringDriver = null,

    pub fn init(allocator: std.mem.Allocator) Driver {
        if (UringDriver.init(allocator)) |uring| {
            return .{
                .allocator = allocator,
                .backend = .io_uring,
                .poll = PollDriver.init(allocator),
                .uring = uring,
            };
        } else |_| {
            return .{
                .allocator = allocator,
                .backend = .poll,
                .poll = PollDriver.init(allocator),
            };
        }
    }

    pub fn initWithBackend(allocator: std.mem.Allocator, backend: Backend) !Driver {
        return switch (backend) {
            .poll => .{
                .allocator = allocator,
                .backend = .poll,
                .poll = PollDriver.init(allocator),
            },
            .io_uring => .{
                .allocator = allocator,
                .backend = .io_uring,
                .poll = PollDriver.init(allocator),
                .uring = try UringDriver.init(allocator),
            },
        };
    }

    pub fn deinit(self: *Driver) void {
        if (self.uring) |*uring|
            uring.deinit();
        self.poll.deinit();
        self.* = undefined;
    }

    pub fn backendKind(self: *const Driver) Backend {
        return self.backend;
    }

    pub fn pollBackendFdCount(self: *const Driver) ?usize {
        if (self.backend != .poll)
            return null;
        return self.poll.pollfds.items.len;
    }

    pub fn pollBackendFdEvents(self: *const Driver, index: usize) ?i16 {
        if (self.backend != .poll or index >= self.poll.pollfds.items.len)
            return null;
        return self.poll.pollfds.items[index].events;
    }

    /// Sources that share an fd are polled once with their interests merged,
    /// and readiness reports under the first such source's context.
    pub fn wait(self: *Driver, sources: []const Source, wake_fd: ?std.posix.fd_t) !Result {
        switch (self.backend) {
            .poll => return self.poll.wait(sources, wake_fd),
            .io_uring => {
                if (self.uring) |*uring|
                    return uring.wait(sources, wake_fd) catch |err| {
                        // A ring that fails at run time is dropped, and this
                        // wait and every later one run on poll, so the
                        // connector keeps working.
                        std.log.debug("HTTP/2 egress io_uring readiness fell back to poll: {s}", .{@errorName(err)});
                        uring.deinit();
                        self.uring = null;
                        self.backend = .poll;
                        return self.poll.wait(sources, wake_fd);
                    };
                self.backend = .poll;
                return self.poll.wait(sources, wake_fd);
            },
        }
    }
};

const PollDriver = struct {
    allocator: std.mem.Allocator,
    pollfds: std.array_list.Aligned(std.posix.pollfd, null) = .empty,
    contexts: std.array_list.Aligned(?*anyopaque, null) = .empty,

    fn init(allocator: std.mem.Allocator) PollDriver {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *PollDriver) void {
        self.contexts.deinit(self.allocator);
        self.pollfds.deinit(self.allocator);
        self.* = undefined;
    }

    fn wait(self: *PollDriver, sources: []const Source, wake_fd: ?std.posix.fd_t) !Result {
        if (sources.len == 0 and wake_fd == null)
            return error.NoReadinessSources;

        while (true) {
            const now_ns = try monotonicNowNs();
            var next_deadline_ns: u64 = std.math.maxInt(u64);
            for (sources) |source| {
                if (source.deadline_mono_ns <= now_ns)
                    return .{ .expired = source.context };
                next_deadline_ns = @min(next_deadline_ns, source.deadline_mono_ns);
            }

            self.pollfds.clearRetainingCapacity();
            self.contexts.clearRetainingCapacity();
            const wake_count: usize = if (wake_fd == null) 0 else 1;
            try self.pollfds.ensureTotalCapacity(self.allocator, sources.len + wake_count);
            try self.contexts.ensureTotalCapacity(self.allocator, sources.len + wake_count);

            if (wake_fd) |fd| {
                self.pollfds.appendAssumeCapacity(.{
                    .fd = fd,
                    .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR,
                    .revents = 0,
                });
                self.contexts.appendAssumeCapacity(null);
            }

            for (sources) |source| {
                const events = pollEvents(source);
                const fd = sourceFd(source.handle);
                if (findFdIndex(self.pollfds.items, fd)) |index| {
                    self.pollfds.items[index].events |= events;
                    continue;
                }
                self.contexts.appendAssumeCapacity(source.context);
                self.pollfds.appendAssumeCapacity(.{ .fd = fd, .events = events, .revents = 0 });
            }

            const timeout_ms: i32 = if (sources.len == 0)
                -1
            else
                timeoutMs(now_ns, next_deadline_ns);
            const ready = try std.posix.poll(self.pollfds.items, timeout_ms);
            if (ready == 0)
                continue;

            for (self.pollfds.items, self.contexts.items) |pollfd, maybe_context| {
                if (maybe_context) |context| {
                    const fault = (pollfd.revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0;
                    const readable = (pollfd.revents & std.posix.POLL.IN) != 0 or fault;
                    const writable = (pollfd.revents & std.posix.POLL.OUT) != 0 or fault;
                    if (readable or writable)
                        return .{ .ready = .{
                            .context = context,
                            .readable = readable,
                            .writable = writable,
                        } };
                } else if ((pollfd.revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
                    return .wake;
                }
            }
        }
    }
};

/// Each wait arms one-shot polls, plus a timeout when a source has a
/// deadline, under a fresh generation, returns the first completion of that
/// generation and cancels the rest. Completions from older generations are
/// discarded.
const UringDriver = struct {
    allocator: std.mem.Allocator,
    ring: linux.IoUring,
    registrations: std.array_list.Aligned(Registration, null) = .empty,
    generation: u16 = 0,
    timeout_storage: linux.kernel_timespec = undefined,
    timeout_context: ?*anyopaque = null,
    timeout_queued: bool = false,

    fn init(allocator: std.mem.Allocator) !UringDriver {
        return .{
            .allocator = allocator,
            .ring = try initRestrictedReadinessRing(),
        };
    }

    fn deinit(self: *UringDriver) void {
        self.registrations.deinit(self.allocator);
        self.ring.deinit();
        self.* = undefined;
    }

    fn wait(self: *UringDriver, sources: []const Source, wake_fd: ?std.posix.fd_t) !Result {
        if (sources.len == 0 and wake_fd == null)
            return error.NoReadinessSources;

        while (true) {
            self.drainStaleCompletions();
            const now_ns = try monotonicNowNs();
            if (expiredSourceContext(sources, now_ns)) |context|
                return .{ .expired = context };
            const generation = self.nextGeneration();
            try self.queueWait(generation, sources, wake_fd);
            _ = try self.ring.submit_and_wait(1);
            const result = try self.nextRelevantCompletion(generation);
            self.cancelQueued(generation);
            return result;
        }
    }

    fn nextGeneration(self: *UringDriver) u16 {
        self.generation +%= 1;
        if (self.generation == 0)
            self.generation = 1;
        return self.generation;
    }

    fn queueWait(
        self: *UringDriver,
        generation: u16,
        sources: []const Source,
        wake_fd: ?std.posix.fd_t,
    ) !void {
        self.registrations.clearRetainingCapacity();
        self.timeout_context = null;
        self.timeout_queued = false;

        var next_deadline_ns: u64 = std.math.maxInt(u64);
        for (sources) |source| {
            if (source.deadline_mono_ns < next_deadline_ns) {
                next_deadline_ns = source.deadline_mono_ns;
                self.timeout_context = source.context;
            }
            try self.addRegistration(source);
        }

        // Every registration plus the wake poll and the timeout must fit in
        // one SQ.
        if (self.registrations.items.len + 2 > ring_entries)
            return error.TooManyEgressReadinessSources;

        for (self.registrations.items, 0..) |registration, index| {
            _ = try self.ring.poll_add(
                try UserData.pack(.{ .kind = .source, .generation = generation, .index = @intCast(index) }),
                registration.fd,
                registration.events,
            );
        }

        if (wake_fd) |fd| {
            _ = try self.ring.poll_add(
                try UserData.pack(.{ .kind = .wake, .generation = generation }),
                fd,
                @intCast(std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR),
            );
        }

        if (sources.len != 0 and next_deadline_ns != std.math.maxInt(u64)) {
            self.timeout_storage = timespecFromNs(next_deadline_ns);
            _ = try self.ring.timeout(
                try UserData.pack(.{ .kind = .timeout, .generation = generation }),
                &self.timeout_storage,
                0,
                linux.IORING_TIMEOUT_ABS | linux.IORING_TIMEOUT_BOOTTIME,
            );
            self.timeout_queued = true;
        }
    }

    fn addRegistration(self: *UringDriver, source: Source) !void {
        const fd = sourceFd(source.handle);
        const events: u32 = @intCast(pollEvents(source));
        for (self.registrations.items) |*registration| {
            if (registration.fd != fd)
                continue;
            registration.events |= events;
            return;
        }
        try self.registrations.append(self.allocator, .{
            .context = source.context,
            .fd = fd,
            .events = events,
        });
    }

    fn nextRelevantCompletion(self: *UringDriver, generation: u16) !Result {
        while (true) {
            var cqes: [max_cqes_per_copy]linux.io_uring_cqe = undefined;
            const count = try self.ring.copy_cqes(&cqes, 1);
            for (cqes[0..count]) |cqe| {
                const user_data = UserData.unpack(cqe.user_data) catch continue;
                if (user_data.generation != generation or user_data.kind == .cancel)
                    continue;
                switch (user_data.kind) {
                    .source => {
                        const index: usize = @intCast(user_data.index);
                        if (index >= self.registrations.items.len)
                            continue;
                        return .{ .ready = readyFromPollResult(
                            self.registrations.items[index].context,
                            cqe.res,
                        ) };
                    },
                    .wake => return .wake,
                    .timeout => return .{ .expired = self.timeout_context orelse continue },
                    .cancel => unreachable,
                }
            }
        }
    }

    fn cancelQueued(self: *UringDriver, generation: u16) void {
        for (self.registrations.items, 0..) |_, index| {
            _ = self.ring.poll_remove(
                UserData.pack(.{ .kind = .cancel, .generation = generation, .index = @intCast(index) }) catch continue,
                UserData.pack(.{ .kind = .source, .generation = generation, .index = @intCast(index) }) catch continue,
            ) catch |err| std.log.debug("egress readiness source cancel failed: {s}", .{@errorName(err)});
        }
        _ = self.ring.poll_remove(
            UserData.pack(.{ .kind = .cancel, .generation = generation, .index = std.math.maxInt(u32) - 1 }) catch return,
            UserData.pack(.{ .kind = .wake, .generation = generation }) catch return,
        ) catch |err| std.log.debug("egress readiness wake cancel failed: {s}", .{@errorName(err)});
        if (self.timeout_queued) {
            _ = self.ring.timeout_remove(
                UserData.pack(.{ .kind = .cancel, .generation = generation, .index = std.math.maxInt(u32) }) catch return,
                UserData.pack(.{ .kind = .timeout, .generation = generation }) catch return,
                0,
            ) catch |err| std.log.debug("egress readiness timeout cancel failed: {s}", .{@errorName(err)});
        }
        _ = self.ring.submit() catch |err| std.log.debug("egress readiness cancel submit failed: {s}", .{@errorName(err)});
        self.drainStaleCompletions();
    }

    fn drainStaleCompletions(self: *UringDriver) void {
        var cqes: [max_cqes_per_copy]linux.io_uring_cqe = undefined;
        while (true) {
            const count = self.ring.copy_cqes(&cqes, 0) catch return;
            if (count == 0)
                return;
        }
    }
};

fn initRestrictedReadinessRing() !linux.IoUring {
    var ring = try linux.IoUring.init(ring_entries, linux.IORING_SETUP_R_DISABLED);
    errdefer ring.deinit();
    var restrictions = [_]restricted_uring.Restriction{
        restricted_uring.registerRestriction(.REGISTER_ENABLE_RINGS),
        restricted_uring.sqeRestriction(.POLL_ADD),
        restricted_uring.sqeRestriction(.POLL_REMOVE),
        restricted_uring.sqeRestriction(.TIMEOUT),
        restricted_uring.sqeRestriction(.TIMEOUT_REMOVE),
        restricted_uring.sqeFlagsAllowedRestriction(0),
    };
    try restricted_uring.registerRestrictions(ring.fd, &restrictions);
    try restricted_uring.enableRing(ring.fd);
    return ring;
}

const Registration = struct {
    context: *anyopaque,
    fd: std.posix.fd_t,
    events: u32,
};

const CompletionKind = enum(u8) {
    source = 1,
    wake = 2,
    timeout = 3,
    cancel = 4,
};

/// CQE user_data layout `{tag:8, kind:8, generation:16, index:32}`. The tag
/// is the egress reservation in `collo_io_uring_tags`, and generation 0 is
/// never packed.
const UserData = struct {
    kind: CompletionKind,
    generation: u16,
    index: u32 = 0,

    const tag_shift: u6 = tags.high_byte_shift;
    const kind_shift: u6 = 48;
    const generation_shift: u6 = 32;
    const kind_mask: u64 = 0xff;
    const generation_mask: u64 = 0xffff;
    const index_mask: u64 = 0xffff_ffff;

    fn pack(self: UserData) !u64 {
        if (self.generation == 0)
            return error.InvalidEgressReadinessGeneration;
        return (tags.egress_high_byte << tag_shift) |
            (@as(u64, @intFromEnum(self.kind)) << kind_shift) |
            (@as(u64, self.generation) << generation_shift) |
            self.index;
    }

    fn unpack(value: u64) !UserData {
        if ((value >> tag_shift) != tags.egress_high_byte)
            return error.InvalidEgressReadinessTag;
        const kind_raw: u8 = @intCast((value >> kind_shift) & kind_mask);
        return .{
            .kind = std.meta.intToEnum(CompletionKind, kind_raw) catch return error.InvalidEgressReadinessKind,
            .generation = @intCast((value >> generation_shift) & generation_mask),
            .index = @intCast(value & index_mask),
        };
    }
};

pub fn deadlineAfterMs(timeout_ms: u32) !u64 {
    return (try monotonicNowNs()) + @as(u64, timeout_ms) * ns_per_ms;
}

/// Reads CLOCK_BOOTTIME, the clock the ring's absolute
/// IORING_TIMEOUT_BOOTTIME timeouts compare against.
pub fn monotonicNowNs() !u64 {
    const ts = try std.posix.clock_gettime(std.posix.CLOCK.BOOTTIME);
    const sec: u64 = @intCast(ts.sec);
    const nsec: u64 = @intCast(ts.nsec);
    return sec * std.time.ns_per_s + nsec;
}

fn timeoutMs(now_ns: u64, deadline_ns: u64) i32 {
    if (deadline_ns == std.math.maxInt(u64))
        return std.math.maxInt(i32);
    if (deadline_ns <= now_ns)
        return 0;
    const remaining_ns = deadline_ns - now_ns;
    const rounded_ms = (remaining_ns + ns_per_ms - 1) / ns_per_ms;
    return @intCast(@min(rounded_ms, @as(u64, @intCast(std.math.maxInt(i32)))));
}

fn pollEvents(source: Source) i16 {
    var events: i16 = std.posix.POLL.HUP | std.posix.POLL.ERR;
    if (source.want_read)
        events |= std.posix.POLL.IN;
    if (source.want_write)
        events |= std.posix.POLL.OUT;
    return events;
}

fn sourceFd(handle: io.WaitHandle) std.posix.fd_t {
    return switch (handle) {
        .fd => |fd| fd,
    };
}

fn findFdIndex(pollfds: []const std.posix.pollfd, fd: std.posix.fd_t) ?usize {
    for (pollfds, 0..) |pollfd, index|
        if (pollfd.fd == fd)
            return index;
    return null;
}

fn expiredSourceContext(sources: []const Source, now_ns: u64) ?*anyopaque {
    var earliest_context: ?*anyopaque = null;
    var earliest_deadline: u64 = std.math.maxInt(u64);
    for (sources) |source| {
        if (source.deadline_mono_ns > now_ns or source.deadline_mono_ns >= earliest_deadline)
            continue;
        earliest_deadline = source.deadline_mono_ns;
        earliest_context = source.context;
    }
    return earliest_context;
}

/// A failed or faulted poll reports ready in both directions, so the caller's
/// own syscall surfaces the real errno.
fn readyFromPollResult(context: *anyopaque, res: i32) Ready {
    if (res < 0) {
        return .{
            .context = context,
            .readable = true,
            .writable = true,
        };
    }
    const events: i16 = @intCast(res);
    const fault = (events & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0;
    return .{
        .context = context,
        .readable = (events & std.posix.POLL.IN) != 0 or fault,
        .writable = (events & std.posix.POLL.OUT) != 0 or fault,
    };
}

fn timespecFromNs(ns: u64) linux.kernel_timespec {
    return .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
}
