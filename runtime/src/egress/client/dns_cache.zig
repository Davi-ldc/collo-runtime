//! DNS cache of one engine: a table of answers in which concurrent lookups of
//! one host and port share a single resolver call.
//!
//! The engine's owner thread asks with `lookup`, which never blocks: it
//! answers an IP literal at once and a name from the table, or starts or
//! joins a lookup and returns a `Ticket`. Resolver threads run the lookups, because `getaddrinfo` cannot be
//! interrupted; the engine starts them (`startResolvers`) before the gateway's
//! seccomp filter forbids new threads, and they are the only threads that
//! block. After each lookup completes, its resolver thread calls the notify
//! function set with `setNotify`, outside the mutex, and the owner collects
//! its tickets again. A ticket holds its entry: the holder either collects
//! the answer or forgets the ticket, so a lookup nobody waits for any more
//! costs only its table entry.
//!
//! An entry is destroyed only when no resolver thread reads it (`job_active`)
//! and no ticket holds it (`waiter_count`). A full table evicts the idle
//! entry closest to expiry and grows past `max_entries` only while every
//! entry is busy. Only negative answers (unknown host, or a host without
//! addresses) are cached as failures; any other failure answers the tickets
//! that waited for it and then leaves the table. `resolveDirect` returns
//! addresses alternating IPv6 and IPv4, starting with IPv6. Expiry runs on
//! the cache's own monotonic clock, which no other deadline is compared with.

const std = @import("std");

pub const Resolver = *const fn (std.mem.Allocator, []const u8, u16) LookupResult;

/// Called by a resolver thread after a lookup completes, with no lock held.
pub const Notify = struct {
    context: ?*anyopaque,
    function: *const fn (?*anyopaque) void,
};

/// The stack each resolver thread reserves: Zig's default, which glibc's
/// resolver runs on. Only the pages a thread touches cost memory.
const resolver_thread_stack_bytes: usize = std.Thread.SpawnConfig.default_stack_size;

pub const Config = struct {
    max_entries: usize = 256,
    ttl_ns: u64 = 30 * std.time.ns_per_s,
    negative_ttl_ns: u64 = std.time.ns_per_s,
    resolver: Resolver = resolveDirect,
    /// Threads that run lookups. Two keep one slow lookup from delaying
    /// every other host's.
    resolver_thread_count: usize = 2,
};

pub const Answer = union(enum) {
    /// Owned by the caller's allocator.
    resolved: []std.net.Address,
    failed: anyerror,
};

pub const Lookup = union(enum) {
    answer: Answer,
    /// The lookup runs on a resolver thread. Collect the ticket after the
    /// next notify, or forget it.
    pending: Ticket,
};

/// A claim on one in-flight lookup, valid until it is collected with an
/// answer or forgotten. Only the thread that took it may use it.
pub const Ticket = struct {
    entry: *Entry,
};

pub const Cache = struct {
    allocator: std.mem.Allocator,
    config: Config,
    mutex: std.Thread.Mutex = .{},
    job_condition: std.Thread.Condition = .{},
    entries: std.array_list.Aligned(*Entry, null) = .empty,
    jobs: std.array_list.Aligned(*Entry, null) = .empty,
    resolvers: []std.Thread = &.{},
    started_resolvers: usize = 0,
    notify: ?Notify = null,
    stopping: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: Config) Cache {
        std.debug.assert(config.max_entries != 0);
        std.debug.assert(config.ttl_ns != 0);
        std.debug.assert(config.resolver_thread_count != 0);
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    /// Joins the resolver threads, so a lookup still inside `getaddrinfo`
    /// delays the caller until it returns. Every ticket must have been
    /// collected or forgotten.
    pub fn deinit(self: *Cache) void {
        self.mutex.lock();
        self.stopping = true;
        self.job_condition.broadcast();
        self.mutex.unlock();

        for (self.resolvers[0..self.started_resolvers]) |thread|
            thread.join();

        self.jobs.deinit(self.allocator);
        for (self.entries.items) |entry| {
            std.debug.assert(entry.waiter_count == 0);
            entry.destroy(self.allocator);
        }
        self.entries.deinit(self.allocator);
        self.allocator.free(self.resolvers);
        self.* = undefined;
    }

    /// Names whom the resolver threads tell about completed lookups. They
    /// read it under the mutex, so it may change at any time; the context
    /// must outlive the resolver threads, which `deinit` joins.
    pub fn setNotify(self: *Cache, notify: Notify) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.notify = notify;
    }

    /// Starts every resolver thread. The gateway's seccomp filter denies
    /// thread creation, so the engine calls this while it starts its own
    /// thread, before the filter; nothing starts a thread later. The threads
    /// keep `self`, so the cache must not move until `deinit` joins them. On
    /// failure the threads already started stay and a later call starts the
    /// rest.
    pub fn startResolvers(self: *Cache) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const count = self.config.resolver_thread_count;
        if (self.resolvers.len == 0)
            self.resolvers = try self.allocator.alloc(std.Thread, count);
        while (self.started_resolvers < count) : (self.started_resolvers += 1)
            self.resolvers[self.started_resolvers] = try std.Thread.spawn(
                .{ .stack_size = resolver_thread_stack_bytes },
                resolverMain,
                .{self},
            );
    }

    /// Answers an IP literal at once and anything else from the table, or
    /// returns a ticket for the lookup of `host` and `port` that a resolver
    /// thread runs. Fails with `error.DnsResolverUnavailable` when a name
    /// needs a resolver before `startResolvers`, and with
    /// `error.OutOfMemory` when the answer, an entry or a job cannot be
    /// allocated.
    pub fn lookup(
        self: *Cache,
        caller_allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
    ) !Lookup {
        // A literal is its own answer: no resolver call, no table entry.
        if (literalAddress(host, port)) |address| {
            const addresses = try caller_allocator.alloc(std.net.Address, 1);
            addresses[0] = address;
            return .{ .answer = .{ .resolved = addresses } };
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.started_resolvers == 0)
            return error.DnsResolverUnavailable;
        const now_ns = monotonicNowNs();
        self.evictExpiredLocked(now_ns);
        if (self.findUsableLocked(host, port, now_ns)) |entry| {
            switch (entry.state) {
                .inflight => {
                    entry.waiter_count += 1;
                    return .{ .pending = .{ .entry = entry } };
                },
                .resolved => return .{ .answer = .{
                    .resolved = try caller_allocator.dupe(std.net.Address, entry.addresses),
                } },
                .failed => return .{ .answer = .{ .failed = entry.err } },
            }
        }

        try self.jobs.ensureUnusedCapacity(self.allocator, 1);
        const entry = try self.createInflightLocked(host, port);
        self.jobs.appendAssumeCapacity(entry);
        entry.job_active = true;
        entry.waiter_count = 1;
        self.job_condition.signal();
        return .{ .pending = .{ .entry = entry } };
    }

    /// The answer of `ticket`'s lookup once it completed, which consumes the
    /// ticket, or null while it still runs. On `error.OutOfMemory` the
    /// ticket is consumed too.
    pub fn collect(self: *Cache, caller_allocator: std.mem.Allocator, ticket: Ticket) !?Answer {
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = ticket.entry;
        std.debug.assert(entry.waiter_count != 0);
        const answer: Answer = switch (entry.state) {
            .inflight => return null,
            .failed => .{ .failed = entry.err },
            .resolved => resolved: {
                const addresses = caller_allocator.dupe(std.net.Address, entry.addresses) catch |err| {
                    self.releaseTicketLocked(entry);
                    return err;
                };
                break :resolved .{ .resolved = addresses };
            },
        };
        self.releaseTicketLocked(entry);
        return answer;
    }

    /// Gives up a ticket whose answer is no longer wanted. The lookup itself
    /// runs to its end; its answer still fills the table.
    pub fn forget(self: *Cache, ticket: Ticket) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(ticket.entry.waiter_count != 0);
        self.releaseTicketLocked(ticket.entry);
    }

    /// Drops the answers for `host` and `port`, so the next lookup asks the
    /// resolver again. A busy entry is only marked expired, and not
    /// cacheable if it failed, which no lookup answers from, and leaves once
    /// idle: a resolver thread reads its host with the mutex released and
    /// tickets hold it.
    pub fn invalidate(self: *Cache, host: []const u8, port: u16) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var index: usize = 0;
        while (index < self.entries.items.len) {
            const entry = self.entries.items[index];
            if (!entry.matches(host, port)) {
                index += 1;
                continue;
            }
            if (entry.isBusy()) {
                entry.expires_mono_ns = 0;
                entry.cache_failure = false;
                index += 1;
                continue;
            }
            self.removeAtLocked(index);
        }
    }

    fn resolverMain(self: *Cache) void {
        while (true) {
            self.mutex.lock();
            while (!self.stopping and self.jobs.items.len == 0)
                self.job_condition.wait(&self.mutex);
            if (self.stopping) {
                self.mutex.unlock();
                return;
            }
            const entry = self.jobs.orderedRemove(0);
            self.mutex.unlock();

            const lookup_result = self.config.resolver(self.allocator, entry.host_lower, entry.port);

            self.mutex.lock();
            entry.job_active = false;
            switch (lookup_result) {
                .success => |addresses| self.completeSuccessLocked(entry, addresses),
                .failure => |err| self.completeFailureLocked(entry, err),
            }
            if (entry.canRemoveFailed())
                self.removeLocked(entry);
            const notify = self.notify;
            self.mutex.unlock();
            if (notify) |target|
                target.function(target.context);
        }
    }

    fn releaseTicketLocked(self: *Cache, entry: *Entry) void {
        entry.waiter_count -= 1;
        if (entry.canRemoveFailed())
            self.removeLocked(entry);
    }

    /// The entry a lookup may answer from or join: one in flight, or a
    /// cached answer that has not expired. An expired entry that tickets
    /// still hold, or a failure kept only for the tickets that waited on it,
    /// answers nobody new, so a lookup starts afresh beside it.
    fn findUsableLocked(self: *Cache, host: []const u8, port: u16, now_ns: u64) ?*Entry {
        for (self.entries.items) |entry| {
            if (!entry.matches(host, port))
                continue;
            switch (entry.state) {
                .inflight => return entry,
                .resolved => if (now_ns < entry.expires_mono_ns) return entry,
                .failed => if (entry.cache_failure and now_ns < entry.expires_mono_ns) return entry,
            }
        }
        return null;
    }

    fn createInflightLocked(self: *Cache, host: []const u8, port: u16) !*Entry {
        while (self.entries.items.len >= self.config.max_entries) {
            if (!self.evictOneIdleLocked())
                break;
        }
        const entry = try Entry.create(self.allocator, host, port);
        errdefer entry.destroy(self.allocator);
        try self.entries.append(self.allocator, entry);
        return entry;
    }

    fn evictExpiredLocked(self: *Cache, now_ns: u64) void {
        var index: usize = 0;
        while (index < self.entries.items.len) {
            const entry = self.entries.items[index];
            if (entry.isBusy() or now_ns < entry.expires_mono_ns) {
                index += 1;
                continue;
            }
            self.removeAtLocked(index);
        }
    }

    fn evictOneIdleLocked(self: *Cache) bool {
        var victim_index: ?usize = null;
        var oldest_expires: u64 = std.math.maxInt(u64);
        for (self.entries.items, 0..) |entry, index| {
            if (entry.isBusy())
                continue;
            if (entry.expires_mono_ns >= oldest_expires)
                continue;
            victim_index = index;
            oldest_expires = entry.expires_mono_ns;
        }
        const index = victim_index orelse return false;
        self.removeAtLocked(index);
        return true;
    }

    fn completeSuccessLocked(self: *Cache, entry: *Entry, addresses: []std.net.Address) void {
        entry.addresses = addresses;
        entry.cache_failure = false;
        entry.expires_mono_ns = monotonicNowNs() +| self.config.ttl_ns;
        entry.state = .resolved;
    }

    fn completeFailureLocked(self: *Cache, entry: *Entry, err: anyerror) void {
        entry.err = err;
        entry.cache_failure = shouldCacheDnsFailure(err);
        entry.expires_mono_ns = if (entry.cache_failure)
            monotonicNowNs() +| self.config.negative_ttl_ns
        else
            0;
        entry.state = .failed;
    }

    fn removeLocked(self: *Cache, target: *Entry) void {
        for (self.entries.items, 0..) |entry, index| {
            if (entry != target)
                continue;
            self.removeAtLocked(index);
            return;
        }
    }

    fn removeAtLocked(self: *Cache, index: usize) void {
        const entry = self.entries.orderedRemove(index);
        std.debug.assert(!entry.isBusy());
        entry.destroy(self.allocator);
    }
};

pub const Entry = struct {
    host_lower: []u8,
    port: u16,
    state: State = .inflight,
    addresses: []std.net.Address = &.{},
    expires_mono_ns: u64 = 0,
    err: anyerror = error.DnsLookupFailed,
    cache_failure: bool = false,
    /// Tickets that hold this entry.
    waiter_count: usize = 0,
    /// A resolver thread will read or is reading this entry: set when its
    /// job is queued, cleared when its answer is published.
    job_active: bool = false,

    const State = enum {
        inflight,
        resolved,
        failed,
    };

    fn create(allocator: std.mem.Allocator, host: []const u8, port: u16) !*Entry {
        const owned_host = try allocator.dupe(u8, host);
        errdefer allocator.free(owned_host);
        _ = std.ascii.lowerString(owned_host, owned_host);
        const entry = try allocator.create(Entry);
        entry.* = .{
            .host_lower = owned_host,
            .port = port,
        };
        return entry;
    }

    fn destroy(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.addresses);
        allocator.free(self.host_lower);
        self.* = undefined;
        allocator.destroy(self);
    }

    fn matches(self: *const Entry, host: []const u8, port: u16) bool {
        return self.port == port and std.ascii.eqlIgnoreCase(self.host_lower, host);
    }

    fn isBusy(self: *const Entry) bool {
        return self.state == .inflight or self.job_active or self.waiter_count != 0;
    }

    fn canRemoveFailed(self: *const Entry) bool {
        return self.state == .failed and !self.cache_failure and !self.isBusy();
    }
};

pub const LookupResult = union(enum) {
    success: []std.net.Address,
    failure: anyerror,
};

/// The address `host` spells when it is an IPv4 or IPv6 literal (without
/// brackets), or null for a name.
fn literalAddress(host: []const u8, port: u16) ?std.net.Address {
    return std.net.Address.parseIp(host, port) catch null;
}

fn shouldCacheDnsFailure(err: anyerror) bool {
    return err == error.UnknownHostName or
        err == error.HostLacksNetworkAddresses;
}

pub fn resolveDirect(allocator: std.mem.Allocator, host: []const u8, port: u16) LookupResult {
    var list = std.net.getAddressList(allocator, host, port) catch |err|
        return .{ .failure = err };
    defer list.deinit();

    const addresses = copyInterleaved(allocator, list.addrs) catch |err|
        return .{ .failure = err };
    return .{ .success = addresses };
}

fn copyInterleaved(allocator: std.mem.Allocator, addresses: []const std.net.Address) ![]std.net.Address {
    const out = try allocator.alloc(std.net.Address, addresses.len);
    errdefer allocator.free(out);

    var out_index: usize = 0;
    var next_v6: usize = 0;
    var next_v4: usize = 0;
    while (true) {
        const wrote_v6 = appendNextFamily(out, &out_index, addresses, &next_v6, std.posix.AF.INET6);
        const wrote_v4 = appendNextFamily(out, &out_index, addresses, &next_v4, std.posix.AF.INET);
        if (!wrote_v6 and !wrote_v4)
            break;
    }
    for (addresses) |address| {
        if (address.any.family == std.posix.AF.INET or address.any.family == std.posix.AF.INET6)
            continue;
        out[out_index] = address;
        out_index += 1;
    }
    std.debug.assert(out_index == out.len);
    return out;
}

fn appendNextFamily(
    out: []std.net.Address,
    out_index: *usize,
    addresses: []const std.net.Address,
    next_index: *usize,
    family: std.posix.sa_family_t,
) bool {
    while (next_index.* < addresses.len) : (next_index.* += 1) {
        const address = addresses[next_index.*];
        if (address.any.family != family)
            continue;
        out[out_index.*] = address;
        out_index.* += 1;
        next_index.* += 1;
        return true;
    }
    return false;
}

/// An unreadable clock reads as the largest instant, which expires every
/// idle entry and keeps nothing stale.
fn monotonicNowNs() u64 {
    const ts = std.posix.clock_gettime(std.posix.CLOCK.MONOTONIC) catch return std.math.maxInt(u64);
    const sec: u64 = @intCast(ts.sec);
    const nsec: u64 = @intCast(ts.nsec);
    return sec * std.time.ns_per_s + nsec;
}
