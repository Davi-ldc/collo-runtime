//! The restriction helpers behind the egress gateway's and the egress
//! client's sandboxed rings. Each ring is created disabled, gets its
//! restriction set and only then is enabled: the kernel takes restrictions
//! only on a disabled ring and only once, and after enabling they allow no
//! register opcode except enabling. Every ring is set up through
//! `initRingParams`, so a kernel or a policy without a usable ring fails each
//! of them with the same two errors, which a caller can skip or fall back on.

const std = @import("std");

const linux = std.os.linux;

pub const RestrictionOpcode = enum(u16) {
    register_op = 0,
    sqe_op = 1,
    sqe_flags_allowed = 2,
    sqe_flags_required = 3,
};

/// The kernel's `struct io_uring_restriction`; the layout is checked below.
pub const Restriction = extern struct {
    opcode: RestrictionOpcode,
    arg: extern union {
        register_op: u8,
        sqe_op: u8,
        sqe_flags: u8,
    },
    resv: u8,
    resv2: [3]u32,
};

comptime {
    std.debug.assert(@sizeOf(Restriction) == 16);
    std.debug.assert(@offsetOf(Restriction, "opcode") == 0);
    std.debug.assert(@offsetOf(Restriction, "arg") == 2);
    std.debug.assert(@offsetOf(Restriction, "resv") == 3);
    std.debug.assert(@offsetOf(Restriction, "resv2") == 4);
}

pub fn enableRing(ring_fd: std.posix.fd_t) !void {
    try registerRaw(ring_fd, .REGISTER_ENABLE_RINGS, null, 0);
}

pub fn registerRestrictions(ring_fd: std.posix.fd_t, restrictions: []Restriction) !void {
    try registerRaw(ring_fd, .REGISTER_RESTRICTIONS, restrictions.ptr, restrictions.len);
}

/// Sets up a ring as `IoUring.init_params` does, naming the failures that
/// mean this kernel or its policy offers no usable ring as `registerRaw`
/// names them: `UnsupportedKernel` for a kernel without io_uring (ENOSYS),
/// without a setup flag the caller asks for (EINVAL) or without the single
/// mapping of both queues (before Linux 5.4), and `PermissionDenied` for the
/// `io_uring_disabled` sysctl or a seccomp filter (EPERM). Every other error
/// passes through, so a caller can skip or fall back on these two alone.
pub fn initRingParams(entries: u16, params: *linux.io_uring_params) !linux.IoUring {
    return linux.IoUring.init_params(entries, params) catch |err| switch (err) {
        error.SystemOutdated, error.ArgumentsInvalid => return error.UnsupportedKernel,
        else => |other| return other,
    };
}

fn registerRaw(ring_fd: std.posix.fd_t, opcode: linux.IORING_REGISTER, arg: ?*const anyopaque, count: usize) !void {
    const res = linux.io_uring_register(ring_fd, opcode, arg, @intCast(count));
    return switch (linux.E.init(res)) {
        .SUCCESS => {},
        .INVAL => error.UnsupportedKernel,
        .OPNOTSUPP => error.UnsupportedKernel,
        .PERM => error.PermissionDenied,
        .NOMEM => error.SystemResources,
        .MFILE => error.UserFdQuotaExceeded,
        .BADF => error.FileDescriptorInvalid,
        .BUSY => error.RingBusy,
        .NXIO => error.RingShuttingDown,
        else => |errno| std.posix.unexpectedErrno(errno),
    };
}

pub fn registerRestriction(op: linux.IORING_REGISTER) Restriction {
    return .{
        .opcode = .register_op,
        .arg = .{ .register_op = @intCast(@intFromEnum(op)) },
        .resv = 0,
        .resv2 = .{ 0, 0, 0 },
    };
}

pub fn sqeRestriction(op: linux.IORING_OP) Restriction {
    return .{
        .opcode = .sqe_op,
        .arg = .{ .sqe_op = @intCast(@intFromEnum(op)) },
        .resv = 0,
        .resv2 = .{ 0, 0, 0 },
    };
}

pub fn sqeFlagsAllowedRestriction(flags: u8) Restriction {
    return .{
        .opcode = .sqe_flags_allowed,
        .arg = .{ .sqe_flags = flags },
        .resv = 0,
        .resv2 = .{ 0, 0, 0 },
    };
}
