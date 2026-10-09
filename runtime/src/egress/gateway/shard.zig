//! One shard of the egress gateway: an `engine.Engine` with the per-shard state that outlives
//! its restarts, plus the default shard count and the choice of shard for a fetch. A shard owns
//! everything the transport keeps for the origins that hash to it (DNS resolver, HTTP/1 pools,
//! HTTP/2 sessions, timers), so a fetch's shard (`hashFetch`) depends only on its pool key (its
//! security cell and the isolation id of its policy entry) and its origin. The gateway's main
//! loop thread owns each `Shard`; the engine's threads write its counting allocator, which is
//! why the allocator lives on the heap at a fixed address while `Shard` moves by value.
//!
//! A restart reuses the engine's threads, rings and counting allocator, because the gateway's
//! seccomp filter forbids creating new ones, and every counter stays cumulative for the life of
//! the gateway process.

const std = @import("std");

const counting_allocator = @import("counting_allocator.zig");
const engine_mod = @import("engine.zig");
const ipc = @import("collo_ipc");
const policy_mod = @import("policy.zig");
const supervisor_limits = @import("supervisor_limits.zig");

/// The most shards a gateway runs; `sizing.Plan.compute` never exceeds it.
pub const default_max_shards: usize = 64;

pub const Config = struct {
    id: usize,
    engine: engine_mod.Config,
    /// Memory budget set on the counting allocator at construction; 0 means
    /// no cap. It holds across restarts because the allocator and the engine
    /// are both reused (see `restart`), so task bytes retained for replay
    /// stay counted against the cap the restarted engine runs under.
    memory_budget_bytes: u64 = supervisor_limits.shard_memory.budget_bytes,
};

/// The restart backstop of one shard (`supervisor_limits.shard_restart`). It decides from the
/// timestamps the caller passes, so tests drive it without a clock.
pub const RestartBackstop = struct {
    /// Monotonic instants of the most recent restarts, used as a ring; 0
    /// marks an empty slot.
    recent: [supervisor_limits.shard_restart.max_restarts_in_window]u64 =
        @splat(0),
    next: usize = 0,
    /// Cumulative backstop trips. A trip is followed at once by the end of
    /// the gateway process, so the value serves logs and tests.
    trips: u64 = 0,

    /// Decides one failure: returns false, and counts the trip, when the
    /// window already holds the most restarts it allows, and the caller must
    /// then give up and return the failure. Otherwise records `now_ns` as a
    /// restart and returns true.
    pub fn admitRestartAt(self: *RestartBackstop, now_ns: u64) bool {
        var in_window: usize = 0;
        for (self.recent) |instant| {
            if (instant != 0 and now_ns -| instant <= supervisor_limits.shard_restart.window_ns)
                in_window += 1;
        }
        if (in_window >= supervisor_limits.shard_restart.max_restarts_in_window) {
            self.trips += 1;
            return false;
        }
        // A failed monotonic read (0) becomes 1 so the slot still counts as
        // occupied: a bad clock errs toward tripping, never toward unlimited
        // restarts.
        self.recent[self.next] = if (now_ns == 0) 1 else now_ns;
        self.next = (self.next + 1) % self.recent.len;
        return true;
    }
};

pub const Shard = struct {
    id: usize,
    /// The shard's counting allocator, which measures its live bytes and
    /// enforces `Config.memory_budget_bytes`. It lives on the heap because
    /// the engine keeps a copy of its `std.mem.Allocator`, whose pointer
    /// engine threads dereference for the shard's whole life, while `Shard`
    /// itself moves by value. `memory.child` is the parent allocator, which
    /// also owns this allocation.
    memory: *counting_allocator.CountingAllocator,
    engine: engine_mod.Engine,
    /// Cumulative engine restarts of this shard, counted by `restart`.
    restarts: u64 = 0,
    /// True while the supervisor tears this shard down: the admission path
    /// refuses new fetches that hash here instead of queueing them. Restarts
    /// run synchronously on the gateway's main loop, so no command can see
    /// the flag set; it keeps admission correct should teardown ever run
    /// asynchronously.
    quarantined: bool = false,
    /// Gives up on the shard after
    /// `supervisor_limits.shard_restart.max_restarts_in_window` restarts
    /// inside its window.
    restart_backstop: RestartBackstop = .{},

    pub fn init(allocator: std.mem.Allocator, config: Config) !Shard {
        const memory = try allocator.create(counting_allocator.CountingAllocator);
        errdefer allocator.destroy(memory);
        memory.* = .{
            .child = allocator,
            .budget_bytes = std.atomic.Value(u64).init(config.memory_budget_bytes),
        };
        return .{
            .id = config.id,
            .memory = memory,
            .engine = try engine_mod.Engine.init(memory.allocator(), config.engine),
        };
    }

    pub fn deinit(self: *Shard) void {
        // The engine's teardown frees through the counting allocator, so the
        // allocator itself goes only after it.
        const parent = self.memory.child;
        self.engine.deinit();
        parent.destroy(self.memory);
        self.* = undefined;
    }

    /// Runs the stopped engine again on the threads, rings and counting
    /// allocator it booted with. The gateway's seccomp filter denies clone,
    /// clone3, io_uring_setup and io_uring_register, so a replacement engine
    /// could not be built, and the restart allocates nothing, so a shard at
    /// its memory budget still restarts. Tasks retained for replay keep
    /// freeing through the same allocator, and the engine's counters stay
    /// cumulative from gateway boot. Counts the restart.
    ///
    /// The caller must have stopped the engine and partitioned its actives
    /// (`Engine.partitionActivesForTeardown`). An error, such as a dead
    /// ring that only a new process can replace, leaves the shard unable to
    /// serve; the caller escalates to process death.
    pub fn restart(self: *Shard) !void {
        self.engine.clearForRestart();
        try self.engine.start();
        self.restarts += 1;
    }

    pub fn start(
        self: *Shard,
        callback_ctx: ?*anyopaque,
        packet_sender: engine_mod.PacketSender,
        body_sender: engine_mod.BodyChunkBatchSender,
        worker_pressure_probe: engine_mod.WorkerPressureProbe,
        worker_fault_reporter: engine_mod.WorkerFaultReporter,
    ) !void {
        self.engine.setPacketSender(callback_ctx, packet_sender);
        self.engine.setBodyChunkBatchSender(body_sender);
        self.engine.setWorkerPressureProbe(worker_pressure_probe);
        self.engine.setWorkerFaultReporter(worker_fault_reporter);
        try self.engine.start();
    }

    pub fn stop(self: *Shard) void {
        self.engine.stop();
    }

    pub fn wakeFd(self: *const Shard) std.posix.fd_t {
        return self.engine.wake_fd;
    }
};

pub const ProtocolClass = enum {
    http,
    https,
    other,
};

pub fn defaultShardCount() usize {
    return defaultShardCountForCpus(effectiveCpuCount());
}

/// Half the cores, at least 2 and at most 8: the shape the shard-count
/// research measured end-to-end (cpuset-pinned ReleaseFast runs of the
/// mixed-traffic egress bench). The owner thread is serialization-limited,
/// not CPU-limited (2 owners beat 1 even sharing one physical core), measured
/// optima were 2@2cpus, 2@4cpus, and 4@8cpus, and past ~cpus/2 owners
/// throughput dips while only tails improve. The cap bounds the per-shard
/// thread, ring and descriptor cost; `sizing.Plan.compute` also lowers the
/// default to fit the open-file budget it shares with worker endpoints.
pub fn defaultShardCountForCpus(cpus: usize) usize {
    if (cpus <= 1)
        return 1;
    return @max(@as(usize, 2), @min(cpus / 2, @as(usize, 8)));
}

/// Affinity-visible CPUs bounded by this process's cgroup v2 cpu.max quota:
/// a gateway limited to 4 cores on a 64-cpu machine must size for 4, where
/// affinity alone reports 64. Any read or parse failure falls back to the
/// affinity count.
fn effectiveCpuCount() usize {
    const affinity = std.Thread.getCpuCount() catch 1;
    const quota_cores = ownCgroupCpuQuotaCores() orelse return affinity;
    return @max(@as(usize, 1), @min(affinity, quota_cores));
}

fn ownCgroupCpuQuotaCores() ?usize {
    var path_buffer: [4096]u8 = undefined;
    const cgroup_path = ownCgroupV2Path(&path_buffer) orelse return null;
    return cgroupCpuQuotaCoresForPath(cgroup_path);
}

/// This process's cgroup v2 path: the "0::<path>" line of /proc/self/cgroup.
fn ownCgroupV2Path(buffer: []u8) ?[]const u8 {
    var file_buffer: [4096]u8 = undefined;
    const contents = std.fs.cwd().readFile("/proc/self/cgroup", &file_buffer) catch return null;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "0::"))
            continue;
        const path = line["0::".len..];
        if (path.len == 0 or path.len > buffer.len)
            return null;
        @memcpy(buffer[0..path.len], path);
        return buffer[0..path.len];
    }
    return null;
}

/// Tightest cpu.max quota across the cgroup and its ancestors, in whole
/// cores (rounded up). null means no quota anywhere ("max"/unreadable).
fn cgroupCpuQuotaCoresForPath(cgroup_path: []const u8) ?usize {
    var tightest: ?usize = null;
    var remaining = cgroup_path;
    while (true) {
        var file_path_buffer: [4096 + 32]u8 = undefined;
        const file_path = std.fmt.bufPrint(
            &file_path_buffer,
            "/sys/fs/cgroup{s}/cpu.max",
            .{remaining},
        ) catch return tightest;
        var contents_buffer: [128]u8 = undefined;
        if (std.fs.cwd().readFile(file_path, &contents_buffer)) |contents| {
            if (parseCpuMaxCores(contents)) |cores|
                tightest = if (tightest) |current| @min(current, cores) else cores;
        } else |_| {}
        if (remaining.len == 0)
            return tightest;
        const cut = std.mem.lastIndexOfScalar(u8, remaining, '/') orelse return tightest;
        remaining = remaining[0..cut];
    }
}

/// Parses a cgroup v2 cpu.max file ("max <period>" or "<quota_us> <period_us>")
/// into whole cores, rounding up; null when unlimited or malformed.
pub fn parseCpuMaxCores(contents: []const u8) ?usize {
    var parts = std.mem.tokenizeAny(u8, contents, " \t\r\n");
    const quota_text = parts.next() orelse return null;
    if (std.mem.eql(u8, quota_text, "max"))
        return null;
    const quota_us = std.fmt.parseUnsigned(u64, quota_text, 10) catch return null;
    const period_text = parts.next() orelse return null;
    const period_us = std.fmt.parseUnsigned(u64, period_text, 10) catch return null;
    if (quota_us == 0 or period_us == 0)
        return null;
    return @intCast((quota_us + period_us - 1) / period_us);
}

/// The shard for a fetch, from its pool key (`isolation`, which the submit passes to the engine
/// unchanged), its scheme class and its canonical origin (lowercased scheme and host, default
/// port dropped, userinfo, path and query ignored). Every fetch of one cell to one origin under
/// one policy entry therefore reaches the shard that holds its pooled connections.
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
    if (bytes.len <= buffer.len) {
        for (bytes, 0..) |byte, index| {
            buffer[index] = std.ascii.toLower(byte);
        }
        hasher.update(buffer[0..bytes.len]);
        return;
    }

    var offset: usize = 0;
    while (offset < bytes.len) {
        const chunk_len = @min(buffer.len, bytes.len - offset);
        for (bytes[offset..][0..chunk_len], 0..) |byte, index| {
            buffer[index] = std.ascii.toLower(byte);
        }
        hasher.update(buffer[0..chunk_len]);
        offset += chunk_len;
    }
}
