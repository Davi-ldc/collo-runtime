//! Adoption and removal of the cgroup leaf a worker was cloned into.

const std = @import("std");
const common = @import("collo_cgroup");
const process = @import("collo_os").process;
const cgroup_root = @import("cgroup_root.zig");

pub const cpu = common.cpu;
pub const memory = common.memory;
pub const path = common.path;
pub const worker = common.worker;

/// Where an adoption spent its time. The three steps have different
/// natures (a read, blocking writes that can drive reclaim, a path
/// resolution), so one aggregate number could not say which to attack.
pub const AdoptSpans = struct {
    probe_ns: u64 = 0,
    rewrite_ns: u64 = 0,
    resolve_ns: u64 = 0,
    rewrote: bool = false,
};

/// Adopts the leaf the host pre-created and the worker was cloned into, and
/// returns the owned directory path resolved from the fd. The caller keeps
/// ownership of `cgroup_dir_fd`.
///
/// The launcher creates each leaf with the limits its launch later passes
/// here, the worker definition's memory limit and the fixed CPU limit
/// (`startFork` in `server/supervisor/launcher.zig`), so the common path is
/// one read that confirms the match; a leaf created with other limits gets
/// the rewrite here. Membership and limit read-back are not validated on
/// this side: the child checks, fail-closed and on this same fd, that its
/// own pid is the cgroup's only member, that `memory.high`, `memory.max` and
/// the `cpu.max` quota match the WorkerInit values, and that `pids.max` and
/// the `cpu.max` period match the defaults (`pids.DEFAULT_MAX` and
/// `cpu.DEFAULT_PERIOD_US` in `common/cgroup.zig`); the zygote refuses to
/// clone into a non-empty cgroup; a child dead before init surfaces through
/// the pidfd.
pub fn adoptPreparedWorkerDir(
    allocator: std.mem.Allocator,
    cgroup_dir_fd: std.posix.fd_t,
    memory_limit_bytes: u64,
    cpu_max_cores: u32,
    out_spans: ?*AdoptSpans,
) ![]u8 {
    const limits = common.worker.Limits{
        .memory_limit_bytes = memory_limit_bytes,
        .cpu_max_cores = cpu_max_cores,
    };
    try common.worker.validateLimitsConfig(limits);

    var cursor_ns = process.monotonicNowNsOrZero();
    // Both limits are probed: a leaf born with the defaults can match on
    // memory while differing on CPU, and adopting it as-is would serve under
    // limits nobody asked for.
    const matches = try memoryHighMatchesAt(cgroup_dir_fd, memory_limit_bytes) and
        cpuMaxMatchesAt(cgroup_dir_fd, cpu_max_cores);
    if (out_spans) |spans| spans.probe_ns = stepDelta(&cursor_ns);
    if (!matches) {
        try common.worker.configureLimitsAt(cgroup_dir_fd, limits);
        if (out_spans) |spans| {
            spans.rewrote = true;
            spans.rewrite_ns = stepDelta(&cursor_ns);
        }
    }
    const dir_path = try resolveDirPath(allocator, cgroup_dir_fd);
    if (out_spans) |spans| spans.resolve_ns = stepDelta(&cursor_ns);
    return dir_path;
}

/// Kills any lingering member, then removes the leaf with bounded retry: a
/// worker that just exited may still be listed until reaped.
pub fn cleanupWorker(cgroup_dir: []const u8) void {
    cgroup_root.reapWorkerCgroupByPath(cgroup_dir);
}

fn stepDelta(cursor_ns: *u64) u64 {
    const now_ns = process.monotonicNowNsOrZero();
    const delta = now_ns -| cursor_ns.*;
    cursor_ns.* = now_ns;
    return delta;
}

/// A read failure reads as "does not match" so the caller rewrites the whole
/// limit set; an unreadable cpu.max is exactly what a rewrite fixes.
fn cpuMaxMatchesAt(cgroup_dir_fd: std.posix.fd_t, cpu_max_cores: u32) bool {
    const fd = common.openReadOnlyAt(cgroup_dir_fd, "cpu.max") catch return false;
    defer std.posix.close(fd);
    var buffer: [64]u8 = undefined;
    const read_len = std.posix.read(fd, &buffer) catch return false;
    if (read_len == buffer.len)
        return false;
    const configured = common.cpu.parseMax(buffer[0..read_len]) catch return false;
    const quota = configured.quota_us orelse return false;
    return configured.period_us == common.cpu.DEFAULT_PERIOD_US and
        quota == common.cpu.quotaForCores(cpu_max_cores, configured.period_us);
}

/// memory.high carries the limit verbatim (the child validator relies on the
/// same exact round-trip) and memory.max derives from it, so one read decides
/// the memory limit. Unreadable, unset or foreign content reports a mismatch.
fn memoryHighMatchesAt(cgroup_dir_fd: std.posix.fd_t, memory_limit_bytes: u64) !bool {
    const fd = try common.openReadOnlyAt(cgroup_dir_fd, "memory.high");
    defer std.posix.close(fd);
    var buffer: [64]u8 = undefined;
    const read_len = try std.posix.read(fd, &buffer);
    if (read_len == buffer.len)
        return false;
    const trimmed = std.mem.trim(u8, buffer[0..read_len], &std.ascii.whitespace);
    if (std.mem.eql(u8, trimmed, "max"))
        return false;
    const configured = std.fmt.parseUnsigned(u64, trimmed, 10) catch return false;
    return configured == memory_limit_bytes;
}

fn resolveDirPath(allocator: std.mem.Allocator, dir_fd: std.posix.fd_t) ![]u8 {
    var link_buffer: [64]u8 = undefined;
    const link = std.fmt.bufPrint(&link_buffer, "/proc/self/fd/{d}", .{dir_fd}) catch unreachable;
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = try std.posix.readlink(link, &path_buffer);
    return allocator.dupe(u8, resolved);
}
