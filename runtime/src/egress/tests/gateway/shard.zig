//! The gateway's shards (`egress/gateway/shard.zig`): the shard a fetch hashes to, from its pool
//! key and canonical origin alone; the restart backstop's window; a shard's engine allocating
//! through the shard's counting allocator and starting again on its own threads at a full budget;
//! and a set that frees every shard it built when construction fails partway. The shard
//! supervision that stops, restarts and fails a shard's fetches is covered in `shard_flow.zig`,
//! and the counting allocator itself in `counting_allocator.zig`. Lane: egress-gateway-test.

const std = @import("std");
const gateway = @import("collo_egress_gateway");

const containment = gateway.containment;
const policy = gateway.policy;
const shard = gateway.shard;

const isolation = policy.PoolIsolation{
    .security_cell_id = [_]u8{10} ** 16,
    .policy_id = [_]u8{20} ** 16,
};

test "a fetch's shard is deterministic, within the shard count, and the only shard of a one-shard set" {
    var other_cell = isolation;
    other_cell.security_cell_id[0] = 11;
    var other_policy = isolation;
    other_policy.policy_id[0] = 21;

    try std.testing.expectEqual(@as(usize, 0), shard.hashFetch(isolation, "https://api.example.test/v1", 1));
    try std.testing.expectEqual(@as(usize, 0), shard.hashFetch(isolation, "https://api.example.test/v1", 0));

    const first = shard.hashFetch(isolation, "https://api.example.test/v1", 8);
    try std.testing.expect(first < 8);
    try std.testing.expectEqual(first, shard.hashFetch(isolation, "https://api.example.test/v1", 8));
    try std.testing.expect(shard.hashFetch(other_cell, "https://api.example.test/v1", 8) < 8);
    try std.testing.expect(shard.hashFetch(other_policy, "https://api.example.test/v1", 8) < 8);
}

test "fetches of one pool key to one origin share a shard whatever their path, case, default port or userinfo" {
    const base = shard.hashFetch(isolation, "https://api.example.test/v1", 8);
    const same_origin = [_][]const u8{
        "https://api.example.test/v2?x=1",
        "https://api.example.test",
        "https://API.Example.TEST/v1",
        "HTTPS://api.example.test/v1",
        "https://api.example.test:443/v1",
        "https://user:secret@api.example.test/v1",
        "https://api.example.test#fragment",
    };
    for (same_origin) |url|
        try std.testing.expectEqual(base, shard.hashFetch(isolation, url, 8));

    const v6 = shard.hashFetch(isolation, "https://[2001:db8::1]/a", 8);
    try std.testing.expectEqual(v6, shard.hashFetch(isolation, "https://[2001:DB8::1]:443/b", 8));
    const plain = shard.hashFetch(isolation, "http://api.example.test/", 8);
    try std.testing.expectEqual(plain, shard.hashFetch(isolation, "http://api.example.test:80/x", 8));
}

test "fetches of many security cells to one origin spread over the shards" {
    // The pool key leads the hash, so one origin's fetches of distinct cells do not all land on
    // one shard.
    var seen: [8]bool = @splat(false);
    for (0..64) |index| {
        var cell = isolation;
        cell.security_cell_id[0] = @intCast(index);
        seen[shard.hashFetch(cell, "https://api.example.test/v1", seen.len)] = true;
    }
    var shards_used: usize = 0;
    for (seen) |used| shards_used += @intFromBool(used);
    try std.testing.expect(shards_used > 1);
}

test "the restart backstop refuses a restart past the windowed maximum and admits restarts again past the window" {
    const window = containment.shard_restart.window_ns;
    try std.testing.expectEqual(@as(usize, 3), containment.shard_restart.max_restarts_in_window);
    var backstop = shard.RestartBackstop{};
    const base: u64 = 1_000;

    // Three restarts, `max_restarts_in_window`, fit inside the window.
    try std.testing.expect(backstop.admitRestartAt(base));
    try std.testing.expect(backstop.admitRestartAt(base + window / 4));
    try std.testing.expect(backstop.admitRestartAt(base + window / 2));
    // The next failure inside it is refused.
    try std.testing.expect(!backstop.admitRestartAt(base + (3 * window) / 4));
    // A refused failure records no restart: once the first restart leaves the window, one more
    // fits, and the one after it does not.
    try std.testing.expect(backstop.admitRestartAt(base + window + 1));
    try std.testing.expect(!backstop.admitRestartAt(base + window + 1));
    // Once the window slides past every recorded restart, restarting resumes.
    var recovered = shard.RestartBackstop{};
    try std.testing.expect(recovered.admitRestartAt(base));
    try std.testing.expect(recovered.admitRestartAt(base + window / 4));
    try std.testing.expect(recovered.admitRestartAt(base + window / 2));
    try std.testing.expect(recovered.admitRestartAt(base + window + window / 2 + 1));

    // A failed monotonic read (0) still occupies a slot, so a bad clock errs toward giving up,
    // never toward unlimited restarts.
    var degenerate = shard.RestartBackstop{};
    try std.testing.expect(degenerate.admitRestartAt(0));
    try std.testing.expect(degenerate.admitRestartAt(0));
    try std.testing.expect(degenerate.admitRestartAt(0));
    try std.testing.expect(!degenerate.admitRestartAt(0));
}

test "a shard's engine allocates through the shard's counting allocator under the shard's budget" {
    const budget = containment.shard_memory.budget_bytes;
    var built = try shard.Shard.init(std.testing.allocator, .{ .sources_max = 16, .ready_event_capacity = 16 }, budget);
    defer built.deinit();

    // The engine allocated its queues through the counting allocator when it was built, so the
    // gauge is nonzero before any fetch.
    try std.testing.expect(built.memory.liveBytes() > 0);
    try std.testing.expectEqual(budget, built.memory.budgetBytes());
}

test "a stopped shard's engine starts again on its threads and rings at a full memory budget" {
    const budget = containment.shard_memory.budget_bytes;
    var built = try shard.Shard.init(std.testing.allocator, .{ .sources_max = 16, .ready_event_capacity = 16 }, budget);
    defer built.deinit();
    try built.engine.start();

    // Stands in for whatever the shard held when it failed, which stays counted against its
    // budget across the restart.
    const carryover = try built.memory.allocator().alloc(u8, 4096);
    defer built.memory.allocator().free(carryover);

    // A shard usually restarts because it hit its budget, so the restart gets no headroom at all:
    // any allocation on its path would fail it.
    built.engine.stop();
    built.engine.clearForRestart();
    built.memory.setBudget(built.memory.liveBytes());
    const restarted = built.engine.start();
    built.memory.setBudget(budget);
    try restarted;
}

test "a shard set whose construction fails at any allocation frees every shard it built" {
    var fail_index: usize = 0;
    while (fail_index < 100_000) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var set = shard.Set.init(
            failing.allocator(),
            2,
            .{ .sources_max = 16, .ready_event_capacity = 16 },
            containment.shard_memory.budget_bytes,
        ) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        // Construction succeeded with no failure left to inject, so every earlier index failed
        // partway and the testing allocator found nothing left behind.
        try std.testing.expectEqual(@as(usize, 2), set.len());
        set.deinit(failing.allocator());
        try std.testing.expect(!failing.has_induced_failure);
        return;
    }
    return error.TestUnexpectedResult;
}

test "a set starts every shard's engine, picks shards by hashFetch over its count, and stops them at deinit" {
    var set = try shard.Set.init(std.testing.allocator, 3, .{ .sources_max = 16, .ready_event_capacity = 16 }, 0);
    defer set.deinit(std.testing.allocator);
    try set.startAll();
    for ([_][]const u8{ "https://a.test/", "https://b.test/", "http://c.test:8080/" }) |url|
        try std.testing.expectEqual(shard.hashFetch(isolation, url, 3), set.selectIndex(isolation, url));
}
