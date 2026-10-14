//! The egress DNS cache (`egress/client/dns_cache.zig`): non-blocking
//! lookups that answer from the table or hand out a ticket, one resolver call
//! shared by every lookup of a host in flight, the notify after each
//! completed lookup, negative caching of definite failures only, forgotten
//! tickets and deferred invalidation. Each test injects a resolver whose
//! calls it counts and can hold, and waits on the notify instead of a clock;
//! only the last test runs the real resolver, on a numeric host. How the
//! engine's dials use the cache is covered by the engine suite in
//! `engine/dial.zig`.

const std = @import("std");
const dns_cache = @import("collo_egress_client").dns_cache;

const port: u16 = 443;

/// Resolver state shared by the tests, reset by `Fake.reset`. A test that
/// holds calls defers `release.set()` after the cache's deinit, so a failed
/// expectation never leaves a resolver thread held while deinit joins it.
const Fake = struct {
    var calls = std.atomic.Value(usize).init(0);
    var outcome: Outcome = .success;
    var hold = false;
    var entered: std.Thread.ResetEvent = .{};
    var release: std.Thread.ResetEvent = .{};

    const Outcome = enum { success, unknown_host, transient };

    /// The longest a test waits for a resolver thread to enter a held call,
    /// and the longest a held call waits for `release`.
    const wait_ns_max: u64 = 5 * std.time.ns_per_s;

    fn reset(next_outcome: Outcome, hold_calls: bool) void {
        calls.store(0, .release);
        outcome = next_outcome;
        hold = hold_calls;
        entered.reset();
        release.reset();
    }

    /// Waits until a resolver thread is inside a held call.
    fn waitEntered() !void {
        entered.timedWait(wait_ns_max) catch return error.ResolverNeverEntered;
    }

    fn resolve(allocator: std.mem.Allocator, host: []const u8, resolve_port: u16) dns_cache.LookupResult {
        _ = host;
        _ = calls.fetchAdd(1, .acq_rel);
        if (hold) {
            entered.set();
            release.timedWait(wait_ns_max) catch return .{ .failure = error.DnsLookupFailed };
        }
        switch (outcome) {
            .unknown_host => return .{ .failure = error.UnknownHostName },
            .transient => return .{ .failure = error.DnsLookupFailed },
            .success => {},
        }
        const addresses = allocator.alloc(std.net.Address, 1) catch |err|
            return .{ .failure = err };
        addresses[0] = std.net.Address.initIp4(.{ 192, 0, 2, 1 }, resolve_port);
        return .{ .success = addresses };
    }
};

/// Counts completed lookups; a test waits for the count it expects.
const Notified = struct {
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    count: usize = 0,

    fn notify(context: ?*anyopaque) void {
        const self: *Notified = @ptrCast(@alignCast(context.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.count += 1;
        self.condition.broadcast();
    }

    fn waitFor(self: *Notified, count: usize) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.count < count)
            try self.condition.timedWait(&self.mutex, 5 * std.time.ns_per_s);
    }
};

/// Initializes and starts `cache` where it lies: its resolver threads keep
/// its address, so it must not move until `deinit` joins them. On failure
/// `cache` is already deinitialized.
fn startCache(cache: *dns_cache.Cache, notified: *Notified, config: dns_cache.Config) !void {
    cache.* = dns_cache.Cache.init(std.testing.allocator, config);
    cache.setNotify(.{ .context = notified, .function = Notified.notify });
    cache.startResolvers() catch |err| {
        cache.deinit();
        return err;
    };
}

fn expectPending(lookup: dns_cache.Lookup) !dns_cache.Ticket {
    return switch (lookup) {
        .pending => |ticket| ticket,
        .answer => error.LookupAnsweredWithoutResolver,
    };
}

fn expectResolved(answer: dns_cache.Answer) !void {
    switch (answer) {
        .resolved => |addresses| {
            defer std.testing.allocator.free(addresses);
            try std.testing.expectEqual(@as(usize, 1), addresses.len);
            try std.testing.expectEqual(port, addresses[0].getPort());
        },
        .failed => |err| return err,
    }
}

fn expectFailed(answer: dns_cache.Answer, expected: anyerror) !void {
    switch (answer) {
        .resolved => |addresses| {
            std.testing.allocator.free(addresses);
            return error.UnexpectedDnsAnswer;
        },
        .failed => |err| try std.testing.expectEqual(expected, err),
    }
}

test "egress DNS cache refuses lookups before its resolver threads start" {
    var cache = dns_cache.Cache.init(std.testing.allocator, .{ .resolver = Fake.resolve });
    defer cache.deinit();
    try std.testing.expectError(error.DnsResolverUnavailable, cache.lookup(std.testing.allocator, "origin.test", port));
}

test "egress DNS cache answers IP literals at once without a resolver call" {
    Fake.reset(.success, false);
    // No resolver thread runs: a literal needs none.
    var cache = dns_cache.Cache.init(std.testing.allocator, .{ .resolver = Fake.resolve });
    defer cache.deinit();

    for ([_][]const u8{ "192.0.2.7", "2001:db8::1" }) |literal| {
        switch (try cache.lookup(std.testing.allocator, literal, port)) {
            .answer => |answer| switch (answer) {
                .resolved => |addresses| {
                    defer std.testing.allocator.free(addresses);
                    try std.testing.expectEqual(@as(usize, 1), addresses.len);
                    try std.testing.expect(addresses[0].eql(try std.net.Address.parseIp(literal, port)));
                },
                .failed => |err| return err,
            },
            .pending => return error.LiteralWentToResolver,
        }
    }
    try std.testing.expectEqual(@as(usize, 0), Fake.calls.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), cache.entries.items.len);
}

test "egress DNS cache shares one resolver call between lookups in flight" {
    Fake.reset(.success, true);
    var notified = Notified{};
    var cache: dns_cache.Cache = undefined;
    try startCache(&cache, &notified, .{ .resolver = Fake.resolve });
    defer cache.deinit();
    defer Fake.release.set();

    const first = try expectPending(try cache.lookup(std.testing.allocator, "origin.test", port));
    const second = try expectPending(try cache.lookup(std.testing.allocator, "ORIGIN.test", port));
    try Fake.waitEntered();
    // Both tickets wait on the one lookup the resolver thread holds.
    try std.testing.expect((try cache.collect(std.testing.allocator, first)) == null);
    Fake.release.set();
    try notified.waitFor(1);

    try expectResolved((try cache.collect(std.testing.allocator, first)).?);
    try expectResolved((try cache.collect(std.testing.allocator, second)).?);
    try std.testing.expectEqual(@as(usize, 1), Fake.calls.load(.acquire));
}

test "egress DNS cache answers from the table until an invalidation" {
    Fake.reset(.success, false);
    var notified = Notified{};
    var cache: dns_cache.Cache = undefined;
    try startCache(&cache, &notified, .{ .resolver = Fake.resolve });
    defer cache.deinit();

    const ticket = try expectPending(try cache.lookup(std.testing.allocator, "origin.test", port));
    try notified.waitFor(1);
    try expectResolved((try cache.collect(std.testing.allocator, ticket)).?);

    switch (try cache.lookup(std.testing.allocator, "origin.test", port)) {
        .answer => |answer| try expectResolved(answer),
        .pending => return error.CachedAnswerMissed,
    }
    try std.testing.expectEqual(@as(usize, 1), Fake.calls.load(.acquire));

    cache.invalidate("origin.test", port);
    const refreshed = try expectPending(try cache.lookup(std.testing.allocator, "origin.test", port));
    try notified.waitFor(2);
    try expectResolved((try cache.collect(std.testing.allocator, refreshed)).?);
    try std.testing.expectEqual(@as(usize, 2), Fake.calls.load(.acquire));
}

test "egress DNS cache keeps an unknown host for the negative TTL and drops it on invalidation" {
    Fake.reset(.unknown_host, false);
    var notified = Notified{};
    var cache: dns_cache.Cache = undefined;
    try startCache(&cache, &notified, .{
        .resolver = Fake.resolve,
        .negative_ttl_ns = std.time.ns_per_hour,
    });
    defer cache.deinit();

    const ticket = try expectPending(try cache.lookup(std.testing.allocator, "missing.test", port));
    try notified.waitFor(1);
    try expectFailed((try cache.collect(std.testing.allocator, ticket)).?, error.UnknownHostName);

    switch (try cache.lookup(std.testing.allocator, "missing.test", port)) {
        .answer => |answer| try expectFailed(answer, error.UnknownHostName),
        .pending => return error.NegativeAnswerNotCached,
    }
    try std.testing.expectEqual(@as(usize, 1), Fake.calls.load(.acquire));

    cache.invalidate("missing.test", port);
    const retried = try expectPending(try cache.lookup(std.testing.allocator, "missing.test", port));
    try notified.waitFor(2);
    try expectFailed((try cache.collect(std.testing.allocator, retried)).?, error.UnknownHostName);
    try std.testing.expectEqual(@as(usize, 2), Fake.calls.load(.acquire));
}

test "egress DNS cache answers every waiting ticket with a transient failure and does not cache it" {
    Fake.reset(.transient, true);
    var notified = Notified{};
    var cache: dns_cache.Cache = undefined;
    try startCache(&cache, &notified, .{
        .resolver = Fake.resolve,
        .negative_ttl_ns = std.time.ns_per_hour,
    });
    defer cache.deinit();
    defer Fake.release.set();

    const first = try expectPending(try cache.lookup(std.testing.allocator, "flaky.test", port));
    const second = try expectPending(try cache.lookup(std.testing.allocator, "flaky.test", port));
    try Fake.waitEntered();
    Fake.release.set();
    try notified.waitFor(1);
    try expectFailed((try cache.collect(std.testing.allocator, first)).?, error.DnsLookupFailed);
    try expectFailed((try cache.collect(std.testing.allocator, second)).?, error.DnsLookupFailed);

    // The failure left the table with its last ticket, so the next lookup
    // asks the resolver again.
    const retried = try expectPending(try cache.lookup(std.testing.allocator, "flaky.test", port));
    try notified.waitFor(2);
    try expectFailed((try cache.collect(std.testing.allocator, retried)).?, error.DnsLookupFailed);
    try std.testing.expectEqual(@as(usize, 2), Fake.calls.load(.acquire));
}

test "egress DNS cache fills the table from a lookup whose ticket was forgotten" {
    Fake.reset(.success, true);
    var notified = Notified{};
    var cache: dns_cache.Cache = undefined;
    try startCache(&cache, &notified, .{ .resolver = Fake.resolve });
    defer cache.deinit();
    defer Fake.release.set();

    const ticket = try expectPending(try cache.lookup(std.testing.allocator, "origin.test", port));
    try Fake.waitEntered();
    cache.forget(ticket);
    Fake.release.set();
    try notified.waitFor(1);

    switch (try cache.lookup(std.testing.allocator, "origin.test", port)) {
        .answer => |answer| try expectResolved(answer),
        .pending => return error.ForgottenLookupAnswerLost,
    }
    try std.testing.expectEqual(@as(usize, 1), Fake.calls.load(.acquire));
}

test "egress DNS cache defers an invalidation while the lookup is in flight" {
    // Destroying a busy entry would be a use-after-free: the resolver thread
    // reads its host with the mutex released, and the ticket holds it.
    Fake.reset(.success, true);
    var notified = Notified{};
    var cache: dns_cache.Cache = undefined;
    try startCache(&cache, &notified, .{ .resolver = Fake.resolve });
    defer cache.deinit();
    defer Fake.release.set();

    const ticket = try expectPending(try cache.lookup(std.testing.allocator, "origin.test", port));
    try Fake.waitEntered();
    cache.invalidate("origin.test", port);
    {
        cache.mutex.lock();
        defer cache.mutex.unlock();
        try std.testing.expectEqual(@as(usize, 1), cache.entries.items.len);
    }
    Fake.release.set();
    try notified.waitFor(1);
    try expectResolved((try cache.collect(std.testing.allocator, ticket)).?);
}

test "egress DNS cache answers no new lookup from an invalidated entry a ticket still holds" {
    Fake.reset(.success, false);
    var notified = Notified{};
    var cache: dns_cache.Cache = undefined;
    try startCache(&cache, &notified, .{ .resolver = Fake.resolve });
    defer cache.deinit();

    const held = try expectPending(try cache.lookup(std.testing.allocator, "origin.test", port));
    try notified.waitFor(1);
    // The ticket is not collected yet, so the entry stays; the invalidation
    // must still keep its answer from every later lookup.
    cache.invalidate("origin.test", port);
    const fresh = try expectPending(try cache.lookup(std.testing.allocator, "origin.test", port));
    try notified.waitFor(2);
    try std.testing.expectEqual(@as(usize, 2), Fake.calls.load(.acquire));
    try expectResolved((try cache.collect(std.testing.allocator, held)).?);
    try expectResolved((try cache.collect(std.testing.allocator, fresh)).?);
}

const ReentrantNotify = struct {
    cache: *dns_cache.Cache,
    notified: Notified = .{},
    reentered: std.atomic.Value(bool) = .init(false),

    fn notify(context: ?*anyopaque) void {
        const self: *ReentrantNotify = @ptrCast(@alignCast(context.?));
        // A lookup from inside the notify takes the cache mutex, so it
        // completes only if the resolver thread released it first.
        if (self.cache.lookup(std.testing.allocator, "origin.test", port)) |lookup| {
            switch (lookup) {
                .answer => |answer| switch (answer) {
                    .resolved => |addresses| std.testing.allocator.free(addresses),
                    .failed => {},
                },
                .pending => |ticket| self.cache.forget(ticket),
            }
            self.reentered.store(true, .release);
        } else |_| {}
        Notified.notify(&self.notified);
    }
};

test "egress DNS cache calls the notify without its mutex held" {
    Fake.reset(.success, false);
    var cache = dns_cache.Cache.init(std.testing.allocator, .{ .resolver = Fake.resolve });
    defer cache.deinit();
    var reentrant = ReentrantNotify{ .cache = &cache };
    cache.setNotify(.{ .context = &reentrant, .function = ReentrantNotify.notify });
    try cache.startResolvers();

    const ticket = try expectPending(try cache.lookup(std.testing.allocator, "origin.test", port));
    try reentrant.notified.waitFor(1);
    try std.testing.expect(reentrant.reentered.load(.acquire));
    try expectResolved((try cache.collect(std.testing.allocator, ticket)).?);
}

test "egress DNS cache resolves a numeric host through the system resolver" {
    const result = dns_cache.resolveDirect(std.testing.allocator, "127.0.0.1", port);
    switch (result) {
        .success => |addresses| {
            defer std.testing.allocator.free(addresses);
            try std.testing.expect(addresses.len != 0);
            try std.testing.expectEqual(@as(std.posix.sa_family_t, std.posix.AF.INET), addresses[0].any.family);
        },
        .failure => |err| return err,
    }
}
