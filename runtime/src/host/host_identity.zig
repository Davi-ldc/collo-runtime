//! The names under which a host claims directories in a parent other hosts
//! share, and the proof that the host behind such a name is gone, which every
//! boot-time sweep of a host's leftovers uses: the worker cgroup directories
//! under an env root (`cgroup_root.zig`) and the tmpfs mount points under
//! /tmp (`tmp_mount.zig`). A claimed name is `<prefix><pid>-<start>-<n>`:
//! the host's pid, its start time in clock ticks since boot (field 22 of
//! `/proc/<pid>/stat`) and a claim number that separates several directories
//! one process holds under one parent, as a test binary does.
//!
//! Within one boot a (pid, start) pair names exactly one process
//! incarnation, because a reused pid starts later, so a pair recorded by a
//! process that is since gone never matches a live one; a pid that cannot be
//! inspected counts as alive, since it may still serve workers. A directory
//! that outlives a reboot, as one on a disk-backed /tmp does, is judged gone
//! unless a process of the new boot holds its pid and started at the same
//! tick, which only keeps it. The proof reads `/proc` of this pid namespace,
//! so hosts that share a parent must share the pid namespace: a live host in
//! another one would have no visible pid and be judged gone. Stateless, and
//! no function here allocates.

const std = @import("std");
const process = @import("collo_os").process;

/// Upper bound on the directories one process can hold under one parent with
/// one prefix; a claim tries `<n>` = 1, 2, ... until the parent accepts the
/// name.
pub const claim_max_attempts: u32 = 4096;
/// The longest name after its prefix: a u32 pid, a u64 start time and a u32
/// claim number in decimal, with two dashes.
pub const name_suffix_bytes_max: usize = 10 + 1 + 20 + 1 + 10;

pub const HostIdentity = struct {
    pid: u32,
    start_ticks: u64,

    /// The calling process.
    pub fn current() !HostIdentity {
        return .{
            .pid = @intCast(std.os.linux.getpid()),
            .start_ticks = try process.selfStartTicks(),
        };
    }

    /// True only when the process that claimed a name is certainly gone: no
    /// process has its pid, or the pid belongs to a later incarnation.
    pub fn isGone(self: HostIdentity) bool {
        const start_ticks = process.processStartTicks(self.pid) catch |err| switch (err) {
            error.ProcessNotFound => return true,
            else => {
                std.log.debug("cannot inspect host pid {d} for a sweep: {s}", .{
                    self.pid,
                    @errorName(err),
                });
                return false;
            },
        };
        return start_ticks != self.start_ticks;
    }
};

/// `<prefix><pid>-<start>-<claim>` in `buffer`, which must hold
/// `prefix.len + name_suffix_bytes_max` bytes.
pub fn formatName(buffer: []u8, comptime prefix: []const u8, owner: HostIdentity, claim: u32) []const u8 {
    std.debug.assert(buffer.len >= prefix.len + name_suffix_bytes_max);
    return std.fmt.bufPrint(buffer, prefix ++ "{d}-{d}-{d}", .{
        owner.pid,
        owner.start_ticks,
        claim,
    }) catch unreachable;
}

/// The owner a `<prefix><pid>-<start>-<n>` name records; null for any other
/// name, which a sweep leaves in place.
pub fn parseName(comptime prefix: []const u8, name: []const u8) ?HostIdentity {
    if (!std.mem.startsWith(u8, name, prefix))
        return null;
    var fields = std.mem.splitScalar(u8, name[prefix.len..], '-');
    const pid_field = fields.next() orelse return null;
    const start_field = fields.next() orelse return null;
    const claim_field = fields.next() orelse return null;
    if (fields.next() != null)
        return null;
    const pid = std.fmt.parseUnsigned(u32, pid_field, 10) catch return null;
    const start_ticks = std.fmt.parseUnsigned(u64, start_field, 10) catch return null;
    _ = std.fmt.parseUnsigned(u32, claim_field, 10) catch return null;
    return .{ .pid = pid, .start_ticks = start_ticks };
}

/// Creates the first free `<prefix><pid>-<start>-<n>` directory of the
/// calling process under `parent_fd` with `mode`, exclusively, and returns
/// its name in `buffer`. The caller sweeps the dead hosts' names first
/// (`sweepDeadAt`), so a name in the way belongs to another claim of this
/// very process or to someone who planted it; either way the claim moves on.
pub fn claimDirAt(
    parent_fd: std.posix.fd_t,
    comptime prefix: []const u8,
    mode: std.posix.mode_t,
    buffer: *[prefix.len + name_suffix_bytes_max]u8,
) ![]const u8 {
    const owner = try HostIdentity.current();
    var claim: u32 = 1;
    while (claim <= claim_max_attempts) : (claim += 1) {
        const name = formatName(buffer, prefix, owner, claim);
        std.posix.mkdirat(parent_fd, name, mode) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        // A sweep must read back exactly the identity written here.
        const parsed = parseName(prefix, name) orelse unreachable;
        std.debug.assert(parsed.pid == owner.pid);
        std.debug.assert(parsed.start_ticks == owner.start_ticks);
        return name;
    }
    return error.HostDirClaimExhausted;
}

/// Calls `reap(parent_fd, name)` for every directory under `parent_fd` that
/// the calling user owns, whose name has `prefix` and records a host that is
/// provably gone. Directories of live hosts or of other users, and names
/// this cannot attribute, stay. A parent it cannot read is a warning: the
/// next boot sweeps again.
pub fn sweepDeadAt(
    parent_fd: std.posix.fd_t,
    comptime prefix: []const u8,
    comptime reap: fn (parent_fd: std.posix.fd_t, name: []const u8) void,
) void {
    // The caller's descriptor may be O_PATH, which cannot be read, so the
    // directory is reopened through it for the iteration.
    const iterator_fd = std.posix.openat(parent_fd, ".", .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
        .DIRECTORY = true,
    }, 0) catch |err| {
        std.log.warn("cannot read a directory to sweep dead hosts' {s}* entries: {s}", .{
            prefix,
            @errorName(err),
        });
        return;
    };
    defer std.posix.close(iterator_fd);

    const own_uid = std.os.linux.getuid();
    var dir = std.fs.Dir{ .fd = iterator_fd };
    var iterator = dir.iterate();
    while (true) {
        const entry = iterator.next() catch |err| {
            std.log.warn("a sweep of dead hosts' {s}* entries stopped reading its directory: {s}", .{
                prefix,
                @errorName(err),
            });
            return;
        } orelse return;
        if (entry.kind != .directory)
            continue;
        const owner = parseName(prefix, entry.name) orelse continue;
        // A directory another user made is that user's to remove, and a
        // sticky parent such as /tmp would refuse the removal anyway.
        const stat = std.posix.fstatat(iterator_fd, entry.name, std.posix.AT.SYMLINK_NOFOLLOW) catch continue;
        if (stat.uid != own_uid)
            continue;
        if (owner.isGone())
            reap(parent_fd, entry.name);
    }
}
