//! The on/off switch parser the benches share
//! (`runtime/bench/common.zig:parseSwitch`), through which the ReleaseFast
//! gate in `runtime/bench/metadata.zig` reads
//! COLLO_BENCH_REQUIRE_RELEASEFAST. The environment read around it is not
//! covered, since unit tests leave the process environment alone. Lanes
//! `microbench-test` and `meta-test`.

const std = @import("std");
const bench_common = @import("collo_bench_common");

test "a bench switch reads 1 as on, and 0 or an empty value as off" {
    try std.testing.expect(try bench_common.parseSwitch("1"));
    try std.testing.expect(!try bench_common.parseSwitch("0"));
    try std.testing.expect(!try bench_common.parseSwitch(""));
}

test "a malformed bench switch fails instead of reading as off" {
    const malformed = [_][]const u8{ " ", "1\n", " 0", "true", "yes", "on", "2", "01", "-1" };
    for (malformed) |raw| {
        errdefer std.debug.print("bench switch '{s}' did not fail\n", .{raw});
        try std.testing.expectError(error.InvalidEnvironmentSwitch, bench_common.parseSwitch(raw));
    }
}
