//! The `collo serve` boot's refusal to run as root (`rootRefusal` in
//! `server/boot/root.zig`), with the effective user injected: root is refused
//! with the status for invalid usage, and any other user goes on. The rest of
//! the boot is covered by `zig build smoke`, which runs `collo serve` as an
//! unprivileged user. Lane `server-core-test`.

const std = @import("std");
const boot = @import("collo_server_main").boot;

test "root is refused with exit status 2 and any other user goes on" {
    // The refusal also writes its one line to stderr.
    const refused = boot.rootRefusal(0) orelse return error.TestExpectedRefusal;
    try std.testing.expectEqual(boot.ExitStatus.invalid, refused);
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(refused));

    try std.testing.expectEqual(@as(?boot.ExitStatus, null), boot.rootRefusal(1000));
    try std.testing.expectEqual(@as(?boot.ExitStatus, null), boot.rootRefusal(std.math.maxInt(std.posix.uid_t)));
}
