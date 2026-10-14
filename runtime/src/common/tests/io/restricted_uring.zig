//! The restriction helpers of `restricted_uring.zig`: each builder encodes
//! the kernel's `struct io_uring_restriction` for its opcode with every
//! reserved byte zero, and a ring setup the kernel refuses fails with one of
//! the two errors that name an unusable ring (`initRingParams`). The
//! gateway's own restriction sets are covered by the egress suites
//! (`egress/tests/gateway/readiness.zig`).

const std = @import("std");
const common_io = @import("collo_common_io");
const linux = std.os.linux;

const restricted_uring = common_io.restricted_uring;

test "each restriction builder encodes its opcode and argument with the reserved bytes zero" {
    const register = restricted_uring.registerRestriction(.REGISTER_ENABLE_RINGS);
    try std.testing.expectEqual(restricted_uring.RestrictionOpcode.register_op, register.opcode);
    try std.testing.expectEqual(@as(u8, @intCast(@intFromEnum(linux.IORING_REGISTER.REGISTER_ENABLE_RINGS))), register.arg.register_op);

    const sqe = restricted_uring.sqeRestriction(.POLL_ADD);
    try std.testing.expectEqual(restricted_uring.RestrictionOpcode.sqe_op, sqe.opcode);
    try std.testing.expectEqual(@as(u8, @intFromEnum(linux.IORING_OP.POLL_ADD)), sqe.arg.sqe_op);

    const flags_allowed = restricted_uring.sqeFlagsAllowedRestriction(@intCast(linux.IOSQE_BUFFER_SELECT));
    try std.testing.expectEqual(restricted_uring.RestrictionOpcode.sqe_flags_allowed, flags_allowed.opcode);
    try std.testing.expectEqual(@as(u8, @intCast(linux.IOSQE_BUFFER_SELECT)), flags_allowed.arg.sqe_flags);

    for ([_]restricted_uring.Restriction{ register, sqe, flags_allowed }) |restriction| {
        try std.testing.expectEqual(@as(u8, 0), restriction.resv);
        try std.testing.expectEqual([3]u32{ 0, 0, 0 }, restriction.resv2);
    }
}

test "a ring setup the kernel refuses for a flag it does not know fails as an unsupported kernel, never as another error" {
    // No kernel defines setup flag bit 31, so the setup fails with EINVAL,
    // the same refusal a kernel gives for a flag it predates.
    var params = std.mem.zeroInit(linux.io_uring_params, .{ .flags = @as(u32, 1) << 31 });
    if (restricted_uring.initRingParams(4, &params)) |ring| {
        var unexpected = ring;
        unexpected.deinit();
        return error.TestUnexpectedRing;
    } else |err| switch (err) {
        error.UnsupportedKernel => {},
        // The `io_uring_disabled` sysctl or a seccomp filter refuses every
        // setup before the kernel reads its flags; the caller skips on it
        // the same way.
        error.PermissionDenied => {},
        else => return err,
    }
}
