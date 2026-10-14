//! Tests of the engine's credit source table
//! (`egress/client/engine/credit_sources.zig`, lane `egress-test`), on the
//! table alone, without an engine or threads: ids never repeat, a credit that
//! names no live source of its kind changes nothing, credits of one source
//! merge into one entry, a slot freed and given to a new source while listed
//! or while the owner walks a take hands over only the new source's credit,
//! and the table allocates only the slots that ran at once. The engine's use
//! of the table is tested in `h2.zig` and `root.zig`.

const std = @import("std");
const egress_client = @import("collo_egress_client");

const credit_sources = egress_client.engine.credit_sources;
const body_credit = egress_client.body_credit;
const CreditSources = credit_sources.CreditSources;
const Stream = @typeInfo(@FieldType(credit_sources.Target, "h2")).pointer.child;
const Fetch = @typeInfo(@FieldType(credit_sources.Target, "h1")).pointer.child;

/// Distinct addresses the table stores and hands back but never follows.
fn fakeStream(comptime n: usize) *Stream {
    return @ptrFromInt(@alignOf(Stream) * (n + 1) * 4096);
}

fn fakeFetch(comptime n: usize) *Fetch {
    return @ptrFromInt(@alignOf(Fetch) * (n + 1) * 4096);
}

/// How many credits `taken` still hands out.
fn countClaims(sources: *CreditSources, taken: credit_sources.Taken) usize {
    var walk = taken;
    var count: usize = 0;
    while (sources.claimNext(&walk)) |_|
        count += 1;
    return count;
}

test "egress credit source ids never repeat when a slot is reused" {
    var sources = CreditSources.init(std.testing.allocator, 1);
    defer sources.deinit();

    const first = try sources.acquire(.{ .h2 = fakeStream(0) }, 1);
    sources.retire(first);
    const second = try sources.acquire(.{ .h2 = fakeStream(1) }, 1);
    defer sources.retire(second);
    try std.testing.expect(first != second);
    // Same slot, same stream id: only the id tells them apart.
    try std.testing.expect(!sources.release(body_credit.h2Data(first, 1, 10, true)));
    try std.testing.expectEqual(@as(usize, 0), countClaims(&sources, sources.take()));
}

test "egress credit source ids run on past the sequence's end without naming a live source again" {
    var sources = CreditSources.init(std.testing.allocator, 1);
    defer sources.deinit();

    sources.next_sequence = (1 << credit_sources.sequence_bits) - 1;
    const last = try sources.acquire(.{ .h1 = fakeFetch(0) }, 0);
    sources.retire(last);
    const wrapped = try sources.acquire(.{ .h1 = fakeFetch(0) }, 0);
    defer sources.retire(wrapped);
    try std.testing.expect(last != wrapped);
    try std.testing.expect(wrapped >> credit_sources.slot_bits != 0);
    try std.testing.expect(!sources.release(body_credit.h1Resume(last)));
}

test "egress credit sources drop a credit that names no live source of its kind" {
    var sources = CreditSources.init(std.testing.allocator, 8);
    defer sources.deinit();

    const stream = try sources.acquire(.{ .h2 = fakeStream(0) }, 3);
    defer sources.retire(stream);
    const fetch = try sources.acquire(.{ .h1 = fakeFetch(0) }, 0);
    defer sources.retire(fetch);

    try std.testing.expect(!sources.release(.none));
    try std.testing.expect(!sources.release(body_credit.h2Data(0, 3, 10, true)));
    // Another stream id, the other kind, a slot never handed out, and one
    // past the table's capacity.
    try std.testing.expect(!sources.release(body_credit.h2Data(stream, 5, 10, true)));
    try std.testing.expect(!sources.release(body_credit.h1Resume(stream)));
    try std.testing.expect(!sources.release(body_credit.h2Data(fetch, 0, 10, true)));
    const sequence = fetch >> credit_sources.slot_bits << credit_sources.slot_bits;
    try std.testing.expect(!sources.release(body_credit.h1Resume(sequence | 4)));
    try std.testing.expect(!sources.release(body_credit.h1Resume(sequence | 8)));
    try std.testing.expectEqual(@as(usize, 0), countClaims(&sources, sources.take()));
}

test "egress credit sources merge one source's credits into one entry" {
    var sources = CreditSources.init(std.testing.allocator, 2);
    defer sources.deinit();

    const stream = try sources.acquire(.{ .h2 = fakeStream(0) }, 1);
    defer sources.retire(stream);
    try std.testing.expect(sources.release(body_credit.h2Data(stream, 1, 100, true)));
    try std.testing.expect(!sources.release(body_credit.h2Data(stream, 1, 50, true)));
    try std.testing.expect(!sources.release(body_credit.h2Data(stream, 1, 7, false)));

    var taken = sources.take();
    const claim = sources.claimNext(&taken).?;
    try std.testing.expect(sources.claimNext(&taken) == null);
    try std.testing.expectEqual(fakeStream(0), claim.target.h2);
    try std.testing.expectEqual(@as(usize, 150), claim.credit.window_bytes);
    try std.testing.expect(claim.credit.window);
    try std.testing.expectEqual(@as(usize, 7), claim.credit.final_bytes);
    try std.testing.expect(claim.credit.final);

    // Taken, the source is listed again by its next credit.
    try std.testing.expect(sources.release(body_credit.h2Data(stream, 1, 0, false)));
    var again = sources.take();
    const final_only = sources.claimNext(&again).?;
    try std.testing.expect(final_only.credit.final);
    try std.testing.expectEqual(@as(usize, 0), final_only.credit.final_bytes);
    try std.testing.expect(!final_only.credit.window);
}

test "egress credit sources list each source at most once however many credits arrive" {
    var sources = CreditSources.init(std.testing.allocator, 4);
    defer sources.deinit();

    var ids: [4]u64 = undefined;
    for (&ids, 0..) |*id, index|
        id.* = try sources.acquire(.{ .h2 = fakeStream(0) }, @intCast(2 * index + 1));
    defer for (ids) |id| sources.retire(id);
    for (0..1000) |round| {
        for (ids, 0..) |id, index|
            _ = sources.release(body_credit.h2Data(id, @intCast(2 * index + 1), round, true));
    }
    try std.testing.expectEqual(@as(usize, 4), countClaims(&sources, sources.take()));
}

test "egress credit sources hand a reused slot only its new source's credit" {
    var sources = CreditSources.init(std.testing.allocator, 1);
    defer sources.deinit();

    const old = try sources.acquire(.{ .h1 = fakeFetch(0) }, 0);
    try std.testing.expect(sources.release(body_credit.h1Resume(old)));
    sources.retire(old);
    const new = try sources.acquire(.{ .h2 = fakeStream(1) }, 1);
    defer sources.retire(new);
    // The slot is still listed from the old source, so the new credit rides
    // that entry.
    try std.testing.expect(!sources.release(body_credit.h2Data(new, 1, 9, true)));

    var taken = sources.take();
    const claim = sources.claimNext(&taken).?;
    try std.testing.expect(sources.claimNext(&taken) == null);
    try std.testing.expectEqual(fakeStream(1), claim.target.h2);
    try std.testing.expect(!claim.credit.resumed);
    try std.testing.expectEqual(@as(usize, 9), claim.credit.window_bytes);
}

test "egress credit sources skip a source that retired, or was replaced, while the owner walks a take" {
    var sources = CreditSources.init(std.testing.allocator, 2);
    defer sources.deinit();

    const first = try sources.acquire(.{ .h1 = fakeFetch(0) }, 0);
    const second = try sources.acquire(.{ .h1 = fakeFetch(1) }, 0);
    defer sources.retire(second);
    try std.testing.expect(sources.release(body_credit.h1Resume(first)));
    try std.testing.expect(sources.release(body_credit.h1Resume(second)));
    var taken = sources.take();

    // Applying one credit can end the other fetch and start another in its
    // slot; the walk goes on to the end of the chain and skips that slot.
    sources.retire(first);
    const replacement = try sources.acquire(.{ .h1 = fakeFetch(2) }, 0);
    defer sources.retire(replacement);
    const claim = sources.claimNext(&taken).?;
    try std.testing.expectEqual(fakeFetch(1), claim.target.h1);
    try std.testing.expect(sources.claimNext(&taken) == null);
}

test "egress credit sources allocate only the slots that ran at once and refuse one past their capacity" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var sources = CreditSources.init(failing.allocator(), 64);
    defer sources.deinit();
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);

    var ids: [64]u64 = undefined;
    for (&ids) |*id| {
        id.* = try sources.acquire(.{ .h1 = fakeFetch(0) }, 0);
        sources.retire(id.*);
    }
    // One source at a time reuses one slot.
    try std.testing.expectEqual(@as(usize, 1), sources.slots.items.len);

    for (&ids) |*id|
        id.* = try sources.acquire(.{ .h1 = fakeFetch(0) }, 0);
    defer for (ids) |id| sources.retire(id);
    try std.testing.expectEqual(@as(usize, 64), sources.slots.items.len);
    try std.testing.expectError(error.EgressEngineSourcesExhausted, sources.acquire(.{ .h1 = fakeFetch(1) }, 0));
}

test "egress credit sources fail a source whose slot cannot be allocated and stay usable" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var sources = CreditSources.init(failing.allocator(), 4);
    defer sources.deinit();

    try std.testing.expectError(error.OutOfMemory, sources.acquire(.{ .h1 = fakeFetch(0) }, 0));
    failing.fail_index = std.math.maxInt(usize);
    const id = try sources.acquire(.{ .h1 = fakeFetch(0) }, 0);
    sources.retire(id);
}

test "egress credit sources drop what was listed when a run ends" {
    var sources = CreditSources.init(std.testing.allocator, 1);
    defer sources.deinit();

    const old = try sources.acquire(.{ .h1 = fakeFetch(0) }, 0);
    try std.testing.expect(sources.release(body_credit.h1Resume(old)));
    sources.retire(old);
    sources.clear();
    try std.testing.expectEqual(@as(usize, 0), countClaims(&sources, sources.take()));
    const new = try sources.acquire(.{ .h1 = fakeFetch(0) }, 0);
    defer sources.retire(new);
    try std.testing.expect(sources.release(body_credit.h1Resume(new)));
}
