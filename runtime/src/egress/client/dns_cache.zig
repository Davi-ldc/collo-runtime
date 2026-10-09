//! DNS cache for the gateway's outbound connections: a table of answers in
//! which concurrent lookups of one host and port share a single resolver
//! call.
//!
//! Lookups run on dedicated resolver threads unless `resolver_worker_count`
//! is zero, and the gateway starts those threads before its seccomp filter
//! forbids new ones. An entry is destroyed only when no lookup, resolver
//! thread or waiter still refers to it, so a full table evicts the idle entry
//! closest to expiry and grows past `max_entries` only while every entry is
//! busy. Only negative answers (unknown host, or a host without addresses)
//! are cached as failures; any other failure is dropped once its lookup and
//! waiters finish. `resolveDirect` returns addresses alternating IPv6 and
//! IPv4, starting with IPv6.

const std = @import("std");
const readiness = @import("collo_egress_readiness");

pub const Resolver = *const fn (std.mem.Allocator, []const u8, u16) LookupResult;

pub const Config = struct {
    max_entries: usize = 256,
    ttl_ns: u64 = 30 * std.time.ns_per_s,
    negative_ttl_ns: u64 = std.time.ns_per_s,
    /// Bounds a caller's wait for an in-flight lookup when the caller has no
    /// request deadline (zero), so a stuck lookup cannot leave its coalesced
    /// waiters asleep forever. The timeout fails the entry with
    /// `error.DnsLookupTimeout`.
    resolver_stall_timeout_ns: u64 = 5 * std.time.ns_per_s,
    resolver: Resolver = resolveDirect,
    /// Threads that run cache misses. getaddrinfo cannot be interrupted, so a
    /// caller waits on a condition its deadline bounds while a resolver
    /// thread blocks in the lookup. Zero runs the lookup on the caller's
    /// thread, which checks its deadline only after the lookup returns.
    resolver_worker_count: usize = 2,
};

pub const Cache = struct {
    allocator: std.mem.Allocator,
    config: Config,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},
    job_condition: std.Thread.Condition = .{},
    entries: std.array_list.Aligned(*Entry, null) = .empty,
    jobs: std.array_list.Aligned(*Entry, null) = .empty,
    workers: []std.Thread = &.{},
    started_workers: usize = 0,
    stopping: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: Config) Cache {
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *Cache) void {
        self.mutex.lock();
        self.stopping = true;
        self.job_condition.broadcast();
        self.condition.broadcast();
        self.mutex.unlock();

        for (self.workers[0..self.started_workers]) |worker|
            worker.join();

        self.mutex.lock();
        self.jobs.deinit(self.allocator);
        for (self.entries.items) |entry|
            entry.destroy(self.allocator);
        self.entries.deinit(self.allocator);
        self.allocator.free(self.workers);
        self.mutex.unlock();
        self.* = undefined;
    }

    pub fn resolve(
        self: *Cache,
        caller_allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
    ) ![]std.net.Address {
        return self.resolveUntil(caller_allocator, host, port, 0);
    }

    pub fn resolveUntil(
        self: *Cache,
        caller_allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        request_deadline_mono_ns: u64,
    ) ![]std.net.Address {
        if (deadlineExpired(request_deadline_mono_ns))
            return error.FetchRequestDeadlineExceeded;

        if (self.config.max_entries == 0 or self.config.ttl_ns == 0)
            return self.resolveDirectUntil(
                caller_allocator,
                host,
                port,
                request_deadline_mono_ns,
            );

        while (true) {
            if (deadlineExpired(request_deadline_mono_ns))
                return error.FetchRequestDeadlineExceeded;

            const now_ns = monotonicNowNs();
            self.mutex.lock();
            self.evictExpiredLocked(now_ns);
            if (self.findLocked(host, port)) |entry| {
                switch (entry.state) {
                    .inflight => {
                        self.waitForResolutionLocked(entry, request_deadline_mono_ns) catch |err| {
                            self.mutex.unlock();
                            return err;
                        };
                        self.mutex.unlock();
                        continue;
                    },
                    .resolved => {
                        const addresses = caller_allocator.dupe(std.net.Address, entry.addresses) catch |err| {
                            self.mutex.unlock();
                            return err;
                        };
                        self.mutex.unlock();
                        return addresses;
                    },
                    .failed => {
                        const err = entry.err;
                        if (entry.canRemoveFailed())
                            self.removeLocked(entry);
                        self.mutex.unlock();
                        return err;
                    },
                }
            }

            const entry = self.createInflightLocked(host, port) catch |err| {
                self.mutex.unlock();
                return err;
            };

            if (self.config.resolver_worker_count != 0) {
                self.enqueueLookupLocked(entry) catch |err| {
                    _ = self.entries.orderedRemove(self.entries.items.len - 1);
                    entry.destroy(self.allocator);
                    self.mutex.unlock();
                    return err;
                };
                self.waitForResolutionLocked(entry, request_deadline_mono_ns) catch |err| {
                    self.mutex.unlock();
                    return err;
                };
                self.mutex.unlock();
                continue;
            }

            self.mutex.unlock();
            const lookup_result = self.config.resolver(self.allocator, host, port);
            self.mutex.lock();
            defer self.mutex.unlock();
            switch (lookup_result) {
                .success => |addresses| {
                    self.completeLookupSuccessLocked(entry, addresses);
                    self.condition.broadcast();
                    if (deadlineExpired(request_deadline_mono_ns))
                        return error.FetchRequestDeadlineExceeded;
                    return try caller_allocator.dupe(std.net.Address, addresses);
                },
                .failure => |err| {
                    self.completeLookupFailureLocked(entry, err);
                    self.condition.broadcast();
                    if (deadlineExpired(request_deadline_mono_ns))
                        return error.FetchRequestDeadlineExceeded;
                    if (entry.canRemoveFailed())
                        self.removeLocked(entry);
                    return err;
                },
            }
        }
    }

    fn resolveDirectUntil(
        self: *Cache,
        caller_allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
        request_deadline_mono_ns: u64,
    ) ![]std.net.Address {
        if (deadlineExpired(request_deadline_mono_ns))
            return error.FetchRequestDeadlineExceeded;

        return switch (self.config.resolver(caller_allocator, host, port)) {
            .success => |addresses| {
                if (deadlineExpired(request_deadline_mono_ns)) {
                    caller_allocator.free(addresses);
                    return error.FetchRequestDeadlineExceeded;
                }
                return addresses;
            },
            .failure => |err| {
                if (deadlineExpired(request_deadline_mono_ns))
                    return error.FetchRequestDeadlineExceeded;
                return err;
            },
        };
    }

    fn waitForResolutionLocked(
        self: *Cache,
        entry: *Entry,
        request_deadline_mono_ns: u64,
    ) !void {
        const now_ns = monotonicNowNs();
        const deadline_ns = if (request_deadline_mono_ns != 0)
            request_deadline_mono_ns
        else
            now_ns +| self.config.resolver_stall_timeout_ns;
        if (now_ns >= deadline_ns)
            return error.FetchRequestDeadlineExceeded;

        entry.waiter_count += 1;
        defer {
            entry.waiter_count -= 1;
            if (entry.state == .failed and entry.canRemoveFailed())
                self.removeLocked(entry);
        }

        self.condition.timedWait(&self.mutex, deadline_ns - now_ns) catch |err| switch (err) {
            error.Timeout => {
                if (request_deadline_mono_ns != 0)
                    return error.FetchRequestDeadlineExceeded;
                if (entry.state == .inflight) {
                    self.completeLookupFailureLocked(entry, error.DnsLookupTimeout);
                    self.condition.broadcast();
                }
                return error.DnsLookupTimeout;
            },
        };

        if (entry.state == .failed)
            return entry.err;
    }

    /// Starts the resolver threads now. The gateway's seccomp filter denies
    /// thread creation, so the engine calls this while it starts its own
    /// threads, before the filter, and the lazy start in
    /// `enqueueLookupLocked` finds them already running.
    pub fn prestartWorkers(self: *Cache) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.startWorkersLocked();
    }

    fn enqueueLookupLocked(self: *Cache, entry: *Entry) !void {
        try self.startWorkersLocked();
        try self.jobs.append(self.allocator, entry);
        entry.job_active = true;
        self.job_condition.signal();
    }

    fn startWorkersLocked(self: *Cache) !void {
        const count = self.config.resolver_worker_count;
        if (count == 0 or self.started_workers == count)
            return;
        if (self.workers.len == 0)
            self.workers = try self.allocator.alloc(std.Thread, count);
        while (self.started_workers < self.workers.len) : (self.started_workers += 1)
            self.workers[self.started_workers] = try std.Thread.spawn(.{}, resolverMain, .{self});
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
            if (entry.state == .inflight) {
                switch (lookup_result) {
                    .success => |addresses| self.completeLookupSuccessLocked(entry, addresses),
                    .failure => |err| self.completeLookupFailureLocked(entry, err),
                }
            } else switch (lookup_result) {
                .success => |addresses| self.allocator.free(addresses),
                .failure => {},
            }
            if (entry.state == .failed and entry.canRemoveFailed())
                self.removeLocked(entry);
            self.condition.broadcast();
            self.mutex.unlock();
        }
    }

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
            // A busy entry cannot be destroyed here: the resolver thread
            // reads `entry.host_lower` with the mutex released and clears
            // `job_active` when it finishes, and parked waiters touch the
            // entry after they wake. Like every other remover, this defers:
            // the entry is marked expired, and not cacheable if it failed, so
            // the eviction scans remove it once it is idle. An in-flight
            // lookup keeps coalescing and publishes a fresh answer.
            if (entry.state == .inflight or entry.job_active or entry.waiter_count != 0) {
                entry.expires_mono_ns = 0;
                entry.cache_failure = false;
                return;
            }
            self.removeAtLocked(index);
            self.condition.broadcast();
            return;
        }
    }

    fn findLocked(self: *Cache, host: []const u8, port: u16) ?*Entry {
        for (self.entries.items) |entry| {
            if (entry.matches(host, port))
                return entry;
        }
        return null;
    }

    fn createInflightLocked(self: *Cache, host: []const u8, port: u16) !*Entry {
        while (self.entries.items.len >= self.config.max_entries) {
            if (!self.evictOneResolvedLocked())
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
            // `waiter_count` covers the wake window: a waiter that has been
            // signaled but has not reacquired the mutex still touches the
            // entry, so the entry must outlive every waiter.
            if (entry.state == .inflight or entry.job_active or entry.waiter_count != 0 or now_ns < entry.expires_mono_ns) {
                index += 1;
                continue;
            }
            self.removeAtLocked(index);
        }
    }

    fn evictOneResolvedLocked(self: *Cache) bool {
        var victim_index: ?usize = null;
        var oldest_expires: u64 = std.math.maxInt(u64);
        for (self.entries.items, 0..) |entry, index| {
            if (entry.state == .inflight)
                continue;
            if (entry.job_active)
                continue;
            if (entry.waiter_count != 0)
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

    fn completeLookupSuccessLocked(self: *Cache, entry: *Entry, addresses: []std.net.Address) void {
        entry.addresses = addresses;
        entry.err = error.DnsLookupFailed;
        entry.cache_failure = false;
        entry.expires_mono_ns = monotonicNowNs() +| self.config.ttl_ns;
        entry.state = .resolved;
    }

    fn completeLookupFailureLocked(self: *Cache, entry: *Entry, err: anyerror) void {
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
        entry.destroy(self.allocator);
    }
};

const Entry = struct {
    host_lower: []u8,
    port: u16,
    state: State = .inflight,
    addresses: []std.net.Address = &.{},
    expires_mono_ns: u64 = 0,
    err: anyerror = error.DnsLookupFailed,
    cache_failure: bool = false,
    waiter_count: usize = 0,
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

    fn matches(self: Entry, host: []const u8, port: u16) bool {
        return self.port == port and std.ascii.eqlIgnoreCase(self.host_lower, host);
    }

    fn canRemoveFailed(self: Entry) bool {
        return self.state == .failed and
            !self.cache_failure and
            !self.job_active and
            self.waiter_count == 0;
    }
};

pub const LookupResult = union(enum) {
    success: []std.net.Address,
    failure: anyerror,
};

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
    appendRemainingFamily(out, &out_index, addresses, &next_v6, std.posix.AF.INET6);
    appendRemainingFamily(out, &out_index, addresses, &next_v4, std.posix.AF.INET);
    for (addresses) |address| {
        if (address.any.family == std.posix.AF.INET or address.any.family == std.posix.AF.INET6)
            continue;
        out[out_index] = address;
        out_index += 1;
    }
    std.debug.assert(out_index == out.len);
    return out;
}

fn appendRemainingFamily(
    out: []std.net.Address,
    out_index: *usize,
    addresses: []const std.net.Address,
    next_index: *usize,
    family: std.posix.sa_family_t,
) void {
    while (appendNextFamily(out, out_index, addresses, next_index, family)) {}
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

fn monotonicNowNs() u64 {
    return readiness.monotonicNowNs() catch std.math.maxInt(u64);
}

fn deadlineExpired(request_deadline_mono_ns: u64) bool {
    return request_deadline_mono_ns != 0 and monotonicNowNs() >= request_deadline_mono_ns;
}
