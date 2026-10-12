//! Support for the worker tests that watch a runtime ask to retire
//! (`runtime/retirement.zig`): reads the `worker_retiring` notice from the
//! server's end of the control socket pair, or checks that none came. It
//! holds no tests; `arbiter.zig`, `boot_eval.zig` and `routes.zig` import it.

const std = @import("std");
const ipc = @import("collo_ipc");

/// How long a test waits for a notice the runtime should already have sent.
const notice_wait_ms: i32 = 1000;

/// Reads the next packet on `server_control_fd`, which must be the worker's
/// retirement notice, and returns the reason it names. Fails with
/// `error.RetirementNoticeMissing` when nothing arrives in time, and with
/// the decoder's error for any other packet.
pub fn read(server_control_fd: std.posix.fd_t) !ipc.WorkerRetiringReason {
    var pollfds = [_]std.posix.pollfd{.{
        .fd = server_control_fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    if (try std.posix.poll(&pollfds, notice_wait_ms) == 0)
        return error.RetirementNoticeMissing;
    var scratch: [64]u8 = undefined;
    var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, server_control_fd, &scratch);
    defer packet.deinit();
    return ipc.worker_retiring.decode(&packet);
}

/// Fails unless `server_control_fd` has nothing to read.
pub fn expectNone(server_control_fd: std.posix.fd_t) !void {
    var pollfds = [_]std.posix.pollfd{.{
        .fd = server_control_fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    try std.testing.expectEqual(@as(usize, 0), try std.posix.poll(&pollfds, 25));
}
