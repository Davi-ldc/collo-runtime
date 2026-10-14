//! The `collo serve` boot (`server/boot/root.zig`): its refusal to run as
//! root, with the effective user injected (root is refused with the status
//! for invalid usage, and any other user goes on), its refusal of a kernel
//! page size the engine does not run on, with both sizes injected, and the
//! exit status a failed route build ends it with. The rest of the boot is covered by
//! `zig build smoke`, which runs `collo serve` as an unprivileged user. Lane
//! `server-core-test`.

const std = @import("std");
const config = @import("collo_server_config");
const boot = @import("collo_server_main").boot;

test "root is refused with exit status 2 and any other user goes on" {
    // The refusal also writes its one line to stderr.
    const refused = boot.rootRefusal(0) orelse return error.TestExpectedRefusal;
    try std.testing.expectEqual(boot.ExitStatus.invalid, refused);
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(refused));

    try std.testing.expectEqual(@as(?boot.ExitStatus, null), boot.rootRefusal(1000));
    try std.testing.expectEqual(@as(?boot.ExitStatus, null), boot.rootRefusal(std.math.maxInt(std.posix.uid_t)));
}

test "a kernel page size that divides the engine's page ceiling goes on and any other exits 1" {
    const kib: usize = 1024;
    // An x86_64 engine, an aarch64 engine of the default geometry and one of the 64 KiB geometry.
    try std.testing.expectEqual(@as(?boot.ExitStatus, null), boot.pageSizeRefusal(4 * kib, 4 * kib));
    try std.testing.expectEqual(@as(?boot.ExitStatus, null), boot.pageSizeRefusal(4 * kib, 16 * kib));
    try std.testing.expectEqual(@as(?boot.ExitStatus, null), boot.pageSizeRefusal(16 * kib, 16 * kib));
    try std.testing.expectEqual(@as(?boot.ExitStatus, null), boot.pageSizeRefusal(64 * kib, 64 * kib));

    // Each refusal also writes its one line to stderr.
    const larger = boot.pageSizeRefusal(64 * kib, 16 * kib) orelse return error.TestExpectedRefusal;
    try std.testing.expectEqual(boot.ExitStatus.failure, larger);
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(larger));
    try std.testing.expectEqual(boot.ExitStatus.failure, boot.pageSizeRefusal(16 * kib, 4 * kib).?);
    try std.testing.expectEqual(boot.ExitStatus.failure, boot.pageSizeRefusal(12 * kib, 16 * kib).?);
    try std.testing.expectEqual(boot.ExitStatus.failure, boot.pageSizeRefusal(0, 16 * kib).?);
}

test "the OOM order holds for a server scored below the zygote and breaks at or above it" {
    const zygote_score = @import("collo_limits").process.OOM_SCORE_ADJ_ZYGOTE;
    // The default score of a process nobody adjusted, and systemd's floor.
    try std.testing.expect(boot.oomOrderHolds(0));
    try std.testing.expect(boot.oomOrderHolds(-1000));
    try std.testing.expect(boot.oomOrderHolds(zygote_score - 1));
    try std.testing.expect(!boot.oomOrderHolds(zygote_score));
    try std.testing.expect(!boot.oomOrderHolds(1000));
}

test "a route resource failure exits 1 and an invalid route exits 2" {
    // Each mapping also writes the diagnostic as its one line to stderr.
    var diagnostic: config.Diagnostic = .{};
    diagnostic.set("worker 'api': cannot seal the module pack: ProcessFdQuotaExceeded", .{});
    const unavailable = boot.routesFailure(error.RouteResourcesUnavailable, &diagnostic);
    try std.testing.expectEqual(boot.ExitStatus.failure, unavailable);
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(unavailable));

    diagnostic.set("worker 'api' route '/*': cannot read module /srv/app.js: FileNotFound", .{});
    const invalid = boot.routesFailure(error.RoutesInvalid, &diagnostic);
    try std.testing.expectEqual(boot.ExitStatus.invalid, invalid);
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(invalid));

    try std.testing.expectEqual(boot.ExitStatus.failure, boot.routesFailure(error.OutOfMemory, &diagnostic));
}
