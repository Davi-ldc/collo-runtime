//! The zygote's state (`zygote/state.zig`): closing its trace descriptor,
//! as a worker child does before its first tenant code, closes the pipe's
//! write end and forgets the number. The zygote and its children trace in
//! the `zygote-integration` lane.

const std = @import("std");
const zygote = @import("collo_zygote");

test "closing the zygote state's trace closes the pipe's write end and leaves no number to trace into" {
    const pipe = try std.posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
    defer std.posix.close(pipe[0]);
    var zygote_state = zygote.state.Zygote.init(pipe[1]) catch |err| {
        std.posix.close(pipe[1]);
        return err;
    };
    defer zygote_state.deinit();

    zygote_state.closeTrace();
    try std.testing.expectEqual(@as(?std.posix.fd_t, null), zygote_state.trace_fd);
    // The state held the only write end, so the read end now reads the
    // pipe's end rather than finding it empty.
    var buffer: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try std.posix.read(pipe[0], &buffer));
    // A second close, and the deinit after it, find nothing left to close.
    zygote_state.closeTrace();
    try std.testing.expectEqual(@as(?std.posix.fd_t, null), zygote_state.trace_fd);
}
