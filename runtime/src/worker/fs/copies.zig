//! The copies the fault plane (`fault.zig`) makes of the tree's files in the
//! worker's tmpfs, the ledger that lists them, and their eviction. It runs
//! on the worker's VM thread, at response time, in the idle sweep after a
//! request and when the binding stamps a local read, and never runs
//! JavaScript.
//!
//! An `ok` response carries a sealed memfd whose size and sha256 must match
//! the index entry before any byte is copied; a mismatch copies nothing.
//! The copy goes under the materialize root with mode 0444, read with pread
//! in `copy_chunk_bytes` chunks and never mapped, and later reads of it are
//! local syscalls in the binding, which stamp the read in the ledger
//! through `recordLocalHit`. Copies are tmpfs memory charged to the
//! worker's cgroup, so none is meant to stay for the worker's lifetime (the
//! FIXME at `evictMaterialized` covers the exception): the idle sweep after
//! each request deletes a copy unread for
//! `fs_fault.materialized_idle_eviction_ns`, and before each new copy the
//! least recently read copies are evicted until it fits
//! `fs_fault.materialize_budget_percent` of the tmpfs, so copies alone
//! never push the worker's /tmp writes into ENOSPC. Eviction deletes only
//! what the ledger lists, never a file the tenant wrote, and an ENOSPC
//! caused by the tenant's own writes still fails the fault.

const std = @import("std");
const fd_mod = @import("collo_os").fd;
const fault_limits = @import("collo_limits").fs_fault;
const worker_fs = @import("index.zig");

const copy_chunk_bytes: usize = 16 * 1024;

// ---------------------------------------------------------------------------
// The ledger of copies. Its instance lives in `index.zig`'s global state,
// beside the materialize root it accounts for; its behavior lives here with
// the copier that feeds it.

/// Allocator of the ledger's keys and table. `deinitWorker` and
/// `uninstallForTest` in `index.zig` free the ledger without an allocator
/// argument, so it uses a process allocator, as the worker's boot does
/// (`boot_allocator` in `zygote/child_boot.zig`).
const ledger_allocator: std.mem.Allocator = std.heap.smp_allocator;

pub const LedgerEntry = struct {
    bytes: u64,
    last_access_mono_ns: u64,
};

/// One entry per copy under the materialize root, keyed by an owned index
/// key, plus the byte total the budget is checked against. Eviction, by the
/// idle sweep or by the budget, deletes only what the ledger lists, so a
/// file the tenant wrote is never deleted.
pub const Ledger = struct {
    entries: std.StringHashMapUnmanaged(LedgerEntry) = .{},
    /// Sum of the entries' `bytes`, so the budget check needs no walk.
    total_bytes: u64 = 0,
    /// Monotonic time of the last idle sweep, which limits sweeps to one per
    /// `fs_fault.materialized_sweep_interval_ns`.
    last_sweep_mono_ns: u64 = 0,

    pub fn count(self: *const Ledger) usize {
        return self.entries.count();
    }

    pub fn deinit(self: *Ledger) void {
        var it = self.entries.keyIterator();
        while (it.next()) |key|
            ledger_allocator.free(key.*);
        self.entries.deinit(ledger_allocator);
        self.* = undefined;
    }
};

/// Bytes the copies may occupy: `fs_fault.materialize_budget_percent` of the
/// tmpfs size `index.zig` read back at init, or zero without an installed
/// index.
pub fn materializeBudgetBytes() u64 {
    const tmpfs_size = worker_fs.tmpfsSizeBytes() orelse 0;
    return tmpfs_size * fault_limits.materialize_budget_percent / 100;
}

/// Records a copy, or refreshes its last read when the ledger already lists
/// it. `writeMaterialized` calls it for a new copy and for a copy that
/// already exists, which re-adopts a file the ledger lost, such as one whose
/// eviction failed to delete it. Fails only with OutOfMemory.
fn ledgerRecord(key: []const u8, bytes: u64, now_mono_ns: u64) !void {
    const ledger = worker_fs.materializedLedger() orelse return;
    if (ledger.entries.getPtr(key)) |existing| {
        // The index does not change for the worker's lifetime, so the size
        // recorded for a key never changes either.
        existing.last_access_mono_ns = now_mono_ns;
        return;
    }
    const owned_key = try ledger_allocator.dupe(u8, key);
    errdefer ledger_allocator.free(owned_key);
    try ledger.entries.putNoClobber(ledger_allocator, owned_key, .{
        .bytes = bytes,
        .last_access_mono_ns = now_mono_ns,
    });
    ledger.total_bytes += bytes;
}

/// Called through `host/fs_fault.zig` when the binding reads an existing
/// copy locally. It traces `worker.fs_fault.hit_local`, which the
/// integration tests assert on, and stamps the copy's last read so the idle
/// sweep keeps it. A copy the ledger does not list stays unlisted.
pub fn recordLocalHit(runtime: anytype, normalized: []const u8) void {
    runtime.traceRuntimeEvent("worker.fs_fault.hit_local={s}", .{normalized});
    const key = worker_fs.deployKey(normalized) orelse return;
    const ledger = worker_fs.materializedLedger() orelse return;
    const entry = ledger.entries.getPtr(key) orelse return;
    entry.last_access_mono_ns = runtime.nowMonoNs();
}

/// Deletes every copy unread for `fs_fault.materialized_idle_eviction_ns`
/// and forgets it, so the next read faults the file in again.
/// `finishRequest` in `serve/response_finish.zig` calls it after each
/// request, and it walks the ledger at most once per
/// `fs_fault.materialized_sweep_interval_ns`, so it needs no thread of its
/// own.
pub fn sweepIdleMaterialized(runtime: anytype) void {
    const ledger = worker_fs.materializedLedger() orelse return;
    const now = runtime.nowMonoNs();
    if (now -| ledger.last_sweep_mono_ns < fault_limits.materialized_sweep_interval_ns)
        return;
    ledger.last_sweep_mono_ns = now;
    // An eviction removes from the map and invalidates the iterator, so the
    // walk restarts after each one instead of collecting victims into an
    // allocation. Each restart follows an eviction, and the interval keeps
    // walks rare.
    sweep: while (true) {
        var it = ledger.entries.iterator();
        while (it.next()) |kv| {
            if (now -| kv.value_ptr.last_access_mono_ns < fault_limits.materialized_idle_eviction_ns)
                continue;
            runtime.traceRuntimeEvent("worker.fs_fault.evicted={s}", .{kv.key_ptr.*});
            evictMaterialized(ledger, kv.key_ptr.*);
            continue :sweep;
        }
        break;
    }
}

/// Evicts the least recently read copies until `incoming_bytes` fits the
/// budget. A copy can be faulted in again while a file the tenant wrote
/// could not be recovered, so only copies the ledger lists are evicted.
/// Fails with `error.FsFaultFileTooLarge` for a file larger than the whole
/// budget, which `schedule` and `faultSync` already reject before sending.
fn ensureMaterializeBudget(incoming_bytes: u64) error{FsFaultFileTooLarge}!void {
    const budget = materializeBudgetBytes();
    if (incoming_bytes > budget)
        return error.FsFaultFileTooLarge;
    const ledger = worker_fs.materializedLedger() orelse return;
    while (ledger.total_bytes + incoming_bytes > budget) {
        const victim = lruLedgerKey(ledger) orelse break;
        evictMaterialized(ledger, victim);
    }
}

fn lruLedgerKey(ledger: *Ledger) ?[]const u8 {
    var oldest: ?[]const u8 = null;
    var oldest_ns: u64 = std.math.maxInt(u64);
    var it = ledger.entries.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.last_access_mono_ns <= oldest_ns) {
            oldest_ns = kv.value_ptr.last_access_mono_ns;
            oldest = kv.key_ptr.*;
        }
    }
    return oldest;
}

/// Deletes one listed copy and drops its entry whatever the unlink returns,
/// so a refused unlink never wedges the ledger. The failure logs at warn,
/// because the test runner fails any test that logs at err without declaring
/// it (`expect_log_errors`).
/// FIXME: a copy whose unlink failed is re-adopted only if another fault of
/// its path settles (`ledgerRecord`). Local reads find the file, so no fault
/// comes, and `recordLocalHit` does not re-adopt it: the copy stays outside
/// the ledger and the budget for the worker's lifetime.
fn evictMaterialized(ledger: *Ledger, key: []const u8) void {
    var path_buffer: [worker_fs.max_normalized_bytes]u8 = undefined;
    if (physicalPath(key, &path_buffer)) |physical| {
        std.posix.unlinkat(std.posix.AT.FDCWD, physical, 0) catch |err| switch (err) {
            error.FileNotFound => {},
            else => std.log.warn("failed to evict materialized deploy file {s}: {s}", .{
                physical,
                @errorName(err),
            }),
        };
    } else |err| {
        std.log.warn("failed to resolve materialized deploy file path {s}: {s}", .{
            key,
            @errorName(err),
        });
    }
    const removed = ledger.entries.fetchRemove(key) orelse return;
    ledger.total_bytes -|= removed.value.bytes;
    ledger_allocator.free(removed.key);
}

// ---------------------------------------------------------------------------
// Copying. Nothing below runs JavaScript; it is syscalls at response time.

/// Checks one response's memfd against index entry `entry`, its seals, size
/// and sha256, then copies it into the tmpfs; shared by `materialize` and
/// `faultSync`. Returns null on success or a static message, the rejection
/// reason of the fault.
pub fn materializeEntry(entry: usize, key: []const u8, memfd: std.posix.fd_t, now_mono_ns: u64) ?[]const u8 {
    const view = worker_fs.indexView() orelse
        return "fs index unavailable";
    // A file memfd must arrive with `fd.memfd_readonly_seals` from
    // `common/os.zig`. Requiring them before the hash and the copy below
    // means the bytes cannot change between the two reads; an unsealed fd
    // fails like a sha256 mismatch.
    fd_mod.requireSeals(memfd, fd_mod.memfd_readonly_seals) catch
        return "fs fault bytes not sealed (fail-closed)";
    const expected_size = view.entrySizeAt(entry);
    const expected_sha256 = view.entrySha256At(entry);

    const stat = std.posix.fstat(memfd) catch
        return "fs fault bytes unreadable";
    if (stat.size < 0 or @as(u64, @intCast(stat.size)) != expected_size)
        return "fs fault bytes size mismatch (fail-closed)";

    // Hashed with pread in `copy_chunk_bytes` chunks, without mapping the
    // received fd.
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var chunk: [copy_chunk_bytes]u8 = undefined;
    var offset: u64 = 0;
    while (offset < expected_size) {
        const want: usize = @intCast(@min(expected_size - offset, chunk.len));
        const got = std.posix.pread(memfd, chunk[0..want], offset) catch
            return "fs fault bytes unreadable";
        if (got == 0)
            return "fs fault bytes size mismatch (fail-closed)";
        hasher.update(chunk[0..got]);
        offset += got;
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    if (!std.mem.eql(u8, &digest, &expected_sha256))
        return "fs fault sha256 mismatch (fail-closed)";

    writeMaterialized(key, memfd, expected_size, now_mono_ns) catch |err| {
        return switch (err) {
            error.NoSpaceLeft => "no space left materializing deploy file",
            error.FsFaultFileTooLarge => "deploy file exceeds the materialization budget",
            else => "deploy file materialization failed",
        };
    };
    return null;
}

fn physicalPath(key: []const u8, buffer: []u8) ![]const u8 {
    const root = worker_fs.materializeRoot() orelse return error.FsFaultUnavailable;
    if (root.len + 1 + key.len > buffer.len)
        return error.NameTooLong;
    @memcpy(buffer[0..root.len], root);
    buffer[root.len] = '/';
    @memcpy(buffer[root.len + 1 ..][0..key.len], key);
    return buffer[0 .. root.len + 1 + key.len];
}

fn writeMaterialized(key: []const u8, memfd: std.posix.fd_t, size: u64, now_mono_ns: u64) !void {
    var path_buffer: [worker_fs.max_normalized_bytes]u8 = undefined;
    const physical = try physicalPath(key, &path_buffer);

    // An earlier fault of the same path already copied the file. The
    // response was still validated, so nothing is copied; the record stamps
    // the read and re-adopts the file if the ledger lost it.
    if (std.posix.fstatat(std.posix.AT.FDCWD, physical, 0)) |_| {
        try ledgerRecord(key, size, now_mono_ns);
        return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    // Evict before copying until this copy fits the budget, so copies alone
    // can never push the tmpfs into ENOSPC.
    try ensureMaterializeBudget(size);

    try makeAncestors(physical);

    // Mode 0444: this fd keeps write access, and every later open sees a
    // read-only file. seccomp rejects O_EXCL on openat
    // (`zygote/worker_boot/sandbox.zig`), so the single VM thread and
    // per-path coalescing are what keep two creations from racing.
    const out_fd = try std.posix.openat(
        std.posix.AT.FDCWD,
        physical,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .CLOEXEC = true },
        0o444,
    );
    var out_open = true;
    defer if (out_open) std.posix.close(out_fd);
    // A partial copy that survived would be a truncated file every later
    // read trusts, so a failure to remove it logs at err.
    errdefer std.posix.unlinkat(std.posix.AT.FDCWD, physical, 0) catch |unlink_err|
        std.log.err("failed to remove partial materialization {s}: {s}", .{
            physical,
            @errorName(unlink_err),
        });

    var chunk: [copy_chunk_bytes]u8 = undefined;
    var offset: u64 = 0;
    while (offset < size) {
        const want: usize = @intCast(@min(size - offset, chunk.len));
        const got = try std.posix.pread(memfd, chunk[0..want], offset);
        if (got == 0)
            return error.UnexpectedEndOfFile;
        var written: usize = 0;
        while (written < got)
            written += try std.posix.write(out_fd, chunk[written..got]);
        offset += got;
    }
    std.posix.close(out_fd);
    out_open = false;
    // Recording is part of the copy: if it fails, the errdefer above deletes
    // the file, so the file and the ledger always agree.
    try ledgerRecord(key, size, now_mono_ns);
}

fn makeAncestors(physical: []const u8) !void {
    const root_len = (worker_fs.materializeRoot() orelse return error.FsFaultUnavailable).len;
    var index: usize = root_len + 1;
    while (index < physical.len) : (index += 1) {
        if (physical[index] != '/')
            continue;
        std.posix.mkdirat(std.posix.AT.FDCWD, physical[0..index], 0o755) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
}

pub fn readMaterialized(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    var path_buffer: [worker_fs.max_normalized_bytes]u8 = undefined;
    const physical = try physicalPath(key, &path_buffer);
    const fd = try std.posix.openat(
        std.posix.AT.FDCWD,
        physical,
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
        0,
    );
    defer std.posix.close(fd);
    const stat = try std.posix.fstat(fd);
    if (stat.size < 0)
        return error.Unexpected;
    const size: u64 = @intCast(stat.size);
    if (size > fault_limits.max_fault_file_bytes)
        return error.FileTooBig;

    // One exact allocation sized by fstat. The cgroup charges it, and running
    // out of memory here is an ordinary failure that needs no special case.
    const content = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(content);
    var read_total: usize = 0;
    while (read_total < content.len) {
        const got = try std.posix.pread(fd, content[read_total..], read_total);
        if (got == 0)
            return error.UnexpectedEndOfFile;
        read_total += got;
    }
    return content;
}
