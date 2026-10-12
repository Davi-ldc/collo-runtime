//! The directory every worker of one host mounts its private tmpfs over. A
//! worker mounts its tmpfs in its own mount namespace, after it made every
//! mount private (`zygote/worker_boot/sandbox.zig:rootfs`), so the host never
//! sees what a worker writes there, and every worker of the host mounts over
//! the same empty directory. The host claims one per `TmpMountPoint` under
//! /tmp, `collo-mounts-<pid>-<start>-<n>` (`host_identity.zig`), with the mode
//! the child requires (`tmp_root.required_mode`), sends its descriptor in
//! every WorkerInit (`launch.zig:LaunchOptions.tmp_mount_point_fd`), and
//! removes it at `deinit`. A claim first removes the mount points of hosts
//! that are provably gone, which a crash or a second signal left behind; a
//! live host's stays, and a removal that finds a directory someone wrote into
//! leaves it with a warning, since a mount point holds nothing. Removing the
//! directory while workers live leaves each on its tmpfs: in its namespace the
//! mount detaches from the removed directory (Linux 3.18 and later), so
//! `deinit` need not wait for the workers.
//!
//! The process's thread that boots and stops the host owns a `TmpMountPoint`;
//! the launches only borrow its descriptor.

const std = @import("std");
const fd_mod = @import("collo_os").fd;
const zygote = @import("collo_zygote");

const host_identity = @import("host_identity.zig");

/// Where a host claims its mount point by default.
pub const default_parent_dir = "/tmp";
const mount_point_prefix = "collo-mounts-";
const required_mode: u32 = zygote.worker_boot.sandbox.tmp_root.required_mode;

pub const TmpMountPoint = struct {
    /// The claimed directory, opened once with O_NOFOLLOW and checked for
    /// mode and owner. SCM_RIGHTS gives each child its own copy.
    dir_fd: fd_mod.OwnedFd,
    /// The directory the claim was made in, kept open so `deinit` removes the
    /// claimed name relative to it.
    parent_fd: fd_mod.OwnedFd,
    name_buffer: [mount_point_prefix.len + host_identity.name_suffix_bytes_max]u8,
    name_len: usize,

    /// Sweeps the dead hosts' mount points under `parent_dir`, then claims
    /// this one. Fails with `error.InvalidWorkerTmpRootMode` or
    /// `error.InvalidWorkerTmpRootOwner` when the directory it opened is not
    /// the one it made: a planted path never becomes a mount point.
    pub fn init(self: *TmpMountPoint, parent_dir: []const u8) !void {
        const parent_fd = try std.posix.open(parent_dir, .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .CLOEXEC = true,
        }, 0);
        self.parent_fd = fd_mod.OwnedFd.fromRaw(parent_fd);
        errdefer self.parent_fd.deinit();

        host_identity.sweepDeadAt(parent_fd, mount_point_prefix, removeDeadMountPoint);
        const name = try host_identity.claimDirAt(
            parent_fd,
            mount_point_prefix,
            required_mode,
            &self.name_buffer,
        );
        self.name_len = name.len;
        errdefer removeMountPoint(parent_fd, name);
        // mkdir applies the umask, so the mode is set again explicitly.
        const dir_fd = try std.posix.openat(parent_fd, name, .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .CLOEXEC = true,
            .NOFOLLOW = true,
        }, 0);
        self.dir_fd = fd_mod.OwnedFd.fromRaw(dir_fd);
        errdefer self.dir_fd.deinit();
        try std.posix.fchmod(dir_fd, required_mode);
        const stat = try std.posix.fstat(dir_fd);
        if ((stat.mode & 0o7777) != required_mode)
            return error.InvalidWorkerTmpRootMode;
        if (stat.uid != std.os.linux.getuid())
            return error.InvalidWorkerTmpRootOwner;
    }

    /// The descriptor each WorkerInit carries, borrowed.
    pub fn fd(self: *const TmpMountPoint) std.posix.fd_t {
        return self.dir_fd.fd();
    }

    pub fn dirName(self: *const TmpMountPoint) []const u8 {
        return self.name_buffer[0..self.name_len];
    }

    pub fn deinit(self: *TmpMountPoint) void {
        self.dir_fd.deinit();
        removeMountPoint(self.parent_fd.fd(), self.dirName());
        self.parent_fd.deinit();
        self.* = undefined;
    }
};

fn removeDeadMountPoint(parent_fd: std.posix.fd_t, name: []const u8) void {
    removeMountPoint(parent_fd, name);
}

/// A mount point holds nothing the host made, so a plain rmdir removes it;
/// anything else is left for its owner with a warning.
fn removeMountPoint(parent_fd: std.posix.fd_t, name: []const u8) void {
    std.posix.unlinkat(parent_fd, name, std.posix.AT.REMOVEDIR) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.log.warn("cannot remove the worker tmpfs mount point {s}: {s}", .{
            name,
            @errorName(err),
        }),
    };
}
