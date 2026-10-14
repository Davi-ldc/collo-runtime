//! The supervisor's small parts on their own: the smaps parser behind the
//! reaper's victim score, and how the launcher reads the boot inputs every
//! launch sends from the server's environment. The supervisor that composes
//! them is covered in `supervisor.zig`, `usage.zig` and `reaper/`, and the
//! launcher in `launcher.zig`. Lane `server-supervisor-test`.

const std = @import("std");

const supervision = @import("collo_server_supervisor");

test "worker reaper parses private rss from smaps rollup" {
    const bytes =
        \\Rss:                4096 kB
        \\Pss:                2048 kB
        \\Private_Clean:       512 kB
        \\Private_Dirty:      1536 kB
        \\Private_Hugetlb:       4 kB
        \\Swap:                  0 kB
        \\
    ;
    try std.testing.expectEqual(
        @as(u64, (512 + 1536 + 4) * 1024),
        try supervision.reaper.memory.parseSmapsRollupPrivateRssBytes(bytes),
    );
}

test "worker reaper rejects smaps rollup without private rss fields" {
    try std.testing.expectError(
        error.SmapsRollupMissingPrivateRss,
        supervision.reaper.memory.parseSmapsRollupPrivateRssBytes("Rss: 10 kB\n"),
    );
}

test "the tmpfs size a launch sends is the MiB the environment names, and the launch's default for anything else" {
    const launcher = supervision.launcher;
    try std.testing.expectEqual(@as(?u64, 64 * 1024 * 1024), launcher.tmpfsSizeBytes("64"));
    try std.testing.expectEqual(@as(?u64, 64 * 1024 * 1024), launcher.tmpfsSizeBytes(" 64\n"));
    try std.testing.expectEqual(@as(?u64, null), launcher.tmpfsSizeBytes(null));
    try std.testing.expectEqual(@as(?u64, null), launcher.tmpfsSizeBytes("0"));
    try std.testing.expectEqual(@as(?u64, null), launcher.tmpfsSizeBytes("64MiB"));
    // A MiB count whose bytes do not fit in 64 bits.
    try std.testing.expectEqual(@as(?u64, null), launcher.tmpfsSizeBytes("18446744073709551615"));
}

test "the benchmark's handler stamp is asked for by the value 1 alone" {
    const launcher = supervision.launcher;
    try std.testing.expect(launcher.envFlagEnabled("1"));
    try std.testing.expect(launcher.envFlagEnabled(" 1\n"));
    try std.testing.expect(!launcher.envFlagEnabled(null));
    try std.testing.expect(!launcher.envFlagEnabled("0"));
    try std.testing.expect(!launcher.envFlagEnabled("true"));
}
