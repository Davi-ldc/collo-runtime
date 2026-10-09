//! The fork loop's child reaping (`fork_loop.zig`) over a real fork: SIGCHLD
//! auto-reap leaves no zombies. The fork loop itself runs in a real zygote
//! in `zygote-integration`.

const std = @import("std");
const zygote = @import("collo_zygote");

const fork_loop = zygote.fork_loop;

test "SIGCHLD auto reap prevents worker zombies" {
    const linux = std.os.linux;
    var old_action: linux.Sigaction = undefined;
    const get_rc = linux.sigaction(linux.SIG.CHLD, null, &old_action);
    switch (linux.E.init(get_rc)) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }
    defer {
        _ = linux.sigaction(linux.SIG.CHLD, &old_action, null);
    }

    try fork_loop.installWorkerChildAutoReap();
    const pid = try std.posix.fork();
    if (pid == 0)
        std.c._exit(0);

    std.Thread.sleep(20 * std.time.ns_per_ms);
    var status: c_int = 0;
    while (true) {
        const rc = std.c.waitpid(@intCast(pid), &status, 0);
        switch (std.posix.errno(rc)) {
            .SUCCESS => return error.ExpectedAutoReap,
            .INTR => continue,
            .CHILD => return,
            else => |err| return std.posix.unexpectedErrno(err),
        }
    }
}
