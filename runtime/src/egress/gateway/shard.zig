//! The egress gateway's shards and the choice of shard for a fetch. A shard is an `engine.Engine`
//! with what outlives the engine's restarts: its budgeted allocator and its restart backstop. A
//! shard owns everything the transport keeps for the origins that hash to it (DNS cache, HTTP/1
//! pools, HTTP/2 sessions, timers), so a fetch's shard (`hashFetch`) depends only on its pool key
//! (its security cell and its policy's pool id) and its origin. The gateway's main loop thread
//! owns the shards; the engine's threads write a shard's counting allocator, which is why the
//! allocator lives on the heap at a fixed address while `Shard` moves by value.
//!
//! A restart reuses the engine's threads, rings and counting allocator, because the gateway's
//! seccomp filter forbids creating new ones (`runtime/shard_flow.zig`).

const std = @import("std");
const ipc = @import("collo_ipc");

const containment = @import("containment.zig");
const counting_allocator = @import("counting_allocator.zig");
const engine_mod = @import("engine.zig");
const policy_mod = @import("policy.zig");

/// The restart backstop of one shard (`containment.shard_restart`). It decides from the instants
/// the caller passes, so tests drive it without a clock.
pub const RestartBackstop = struct {
    /// Monotonic instants of the most recent restarts, used as a ring; 0 marks an empty slot.
    recent: [containment.shard_restart.max_restarts_in_window]u64 = @splat(0),
    next: usize = 0,

    /// Decides one failure: returns false when the window already holds the most restarts it
    /// allows, and the caller must then give up and return the failure. Otherwise records
    /// `now_ns` as a restart and returns true.
    pub fn admitRestartAt(self: *RestartBackstop, now_ns: u64) bool {
        var in_window: usize = 0;
        for (self.recent) |instant| {
            if (instant != 0 and now_ns -| instant <= containment.shard_restart.window_ns)
                in_window += 1;
        }
        if (in_window >= containment.shard_restart.max_restarts_in_window)
            return false;
        // A failed monotonic read (0) becomes 1 so the slot still counts as occupied: a bad
        // clock errs toward giving up, never toward unlimited restarts.
        self.recent[self.next] = if (now_ns == 0) 1 else now_ns;
        self.next = (self.next + 1) % self.recent.len;
        return true;
    }
};

pub const Shard = struct {
    /// The shard's counting allocator, which measures its live bytes and enforces its budget. It
    /// lives on the heap because the engine keeps a copy of its `std.mem.Allocator`, whose
    /// pointer engine threads dereference for the shard's whole life, while `Shard` itself moves
    /// by value. `memory.child` is the parent allocator, which also owns this allocation.
    memory: *counting_allocator.CountingAllocator,
    engine: engine_mod.Engine,
    restart_backstop: RestartBackstop = .{},

    pub fn init(allocator: std.mem.Allocator, config: engine_mod.Config, memory_budget_bytes: u64) !Shard {
        const memory = try allocator.create(counting_allocator.CountingAllocator);
        errdefer allocator.destroy(memory);
        memory.* = .{ .child = allocator };
        memory.setBudget(memory_budget_bytes);
        return .{
            .memory = memory,
            .engine = try engine_mod.Engine.init(memory.allocator(), config),
        };
    }

    pub fn deinit(self: *Shard) void {
        // The engine's teardown frees through the counting allocator, so the allocator itself
        // goes only after it.
        const parent = self.memory.child;
        self.engine.deinit();
        parent.destroy(self.memory);
        self.* = undefined;
    }
};

pub const Set = struct {
    list: []Shard = &.{},

    /// Builds `shard_count` shards, each engine's allocator capped at `memory_budget_bytes` (0
    /// for no cap). The gateway passes `containment.shard_memory.budget_bytes`; tests pass what
    /// their scenario needs.
    pub fn init(
        allocator: std.mem.Allocator,
        shard_count: usize,
        engine_config: engine_mod.Config,
        memory_budget_bytes: u64,
    ) !Set {
        std.debug.assert(shard_count >= 1);
        const list = try allocator.alloc(Shard, shard_count);
        var built: usize = 0;
        errdefer {
            for (list[0..built]) |*shard|
                shard.deinit();
            allocator.free(list);
        }
        for (list) |*shard| {
            shard.* = try Shard.init(allocator, engine_config, memory_budget_bytes);
            built += 1;
        }
        return .{ .list = list };
    }

    pub fn deinit(self: *Set, allocator: std.mem.Allocator) void {
        for (self.list) |*shard|
            shard.deinit();
        allocator.free(self.list);
        self.* = undefined;
    }

    pub fn len(self: *const Set) usize {
        return self.list.len;
    }

    pub fn get(self: *Set, index: usize) *Shard {
        return &self.list[index];
    }

    /// Creates every shard's threads and rings. The gateway calls it before its seccomp filter,
    /// which denies creating either afterwards. On failure, the shards already started are
    /// stopped again.
    pub fn startAll(self: *Set) !void {
        var started: usize = 0;
        errdefer {
            for (self.list[0..started]) |*shard|
                shard.engine.stop();
        }
        for (self.list) |*shard| {
            try shard.engine.start();
            started += 1;
        }
    }

    /// The shard for a fetch to `url` under `isolation`, the pool key its submit passes
    /// (`hashFetch`).
    pub fn selectIndex(self: *const Set, isolation: policy_mod.PoolIsolation, url: []const u8) usize {
        return hashFetch(isolation, url, self.list.len);
    }
};

pub const ProtocolClass = enum {
    http,
    https,
    other,
};

/// The shard for a fetch, from its pool key (`isolation`, which the submit passes to the engine
/// unchanged), its scheme class and its canonical origin (lowercased scheme and host, default
/// port dropped, userinfo, path and query ignored). Every fetch of one cell to one origin under
/// one policy therefore reaches the shard that holds its pooled connections.
pub fn hashFetch(isolation: policy_mod.PoolIsolation, url: []const u8, shard_count: usize) usize {
    if (shard_count <= 1)
        return 0;
    var hasher = std.hash.Wyhash.init(0x434f4c4c4f454752);
    hasher.update(&isolation.security_cell_id);
    hasher.update(&isolation.policy_id);
    hasher.update(@tagName(protocolClass(url)));
    updateCanonicalOriginHash(&hasher, url);
    return @intCast(hasher.final() % shard_count);
}

fn protocolClass(url: []const u8) ProtocolClass {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return .other;
    const scheme = url[0..scheme_end];
    if (std.ascii.eqlIgnoreCase(scheme, "http"))
        return .http;
    if (std.ascii.eqlIgnoreCase(scheme, "https"))
        return .https;
    return .other;
}

fn updateCanonicalOriginHash(hasher: *std.hash.Wyhash, url: []const u8) void {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse {
        updateAsciiLower(hasher, url);
        return;
    };
    const authority_start = scheme_end + 3;
    const authority_tail = url[authority_start..];
    const authority_len = std.mem.indexOfAny(u8, authority_tail, "/?#") orelse authority_tail.len;
    const authority = authority_tail[0..authority_len];
    const userinfo_end = std.mem.lastIndexOfScalar(u8, authority, '@');
    const host_port = if (userinfo_end) |index| authority[index + 1 ..] else authority;

    updateAsciiLower(hasher, url[0..scheme_end]);
    hasher.update("://");
    const default_port: []const u8 = if (std.ascii.eqlIgnoreCase(url[0..scheme_end], "http"))
        "80"
    else if (std.ascii.eqlIgnoreCase(url[0..scheme_end], "https"))
        "443"
    else
        "";

    if (host_port.len != 0 and host_port[0] == '[') {
        const close = std.mem.indexOfScalar(u8, host_port, ']') orelse {
            updateAsciiLower(hasher, host_port);
            return;
        };
        updateAsciiLower(hasher, host_port[0 .. close + 1]);
        const port = if (close + 1 < host_port.len and host_port[close + 1] == ':') host_port[close + 2 ..] else "";
        if (port.len != 0 and !std.mem.eql(u8, port, default_port)) {
            hasher.update(":");
            hasher.update(port);
        }
        return;
    }

    const colon = std.mem.lastIndexOfScalar(u8, host_port, ':');
    const host = if (colon) |index| host_port[0..index] else host_port;
    const port = if (colon) |index| host_port[index + 1 ..] else "";
    updateAsciiLower(hasher, host);
    if (port.len != 0 and !std.mem.eql(u8, port, default_port)) {
        hasher.update(":");
        hasher.update(port);
    }
}

fn updateAsciiLower(hasher: *std.hash.Wyhash, bytes: []const u8) void {
    var buffer: [ipc.fetch_limits.request_url_bytes_max]u8 = undefined;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const chunk_len = @min(buffer.len, bytes.len - offset);
        for (bytes[offset..][0..chunk_len], 0..) |byte, index|
            buffer[index] = std.ascii.toLower(byte);
        hasher.update(buffer[0..chunk_len]);
        offset += chunk_len;
    }
}
