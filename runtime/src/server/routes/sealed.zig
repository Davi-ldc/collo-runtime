//! The one way the server's routes hand a blob built at boot to other
//! processes: a memfd written once, rewound and sealed read-only
//! (`memfd_readonly_seals`), as the convention for read-only data shared
//! with workers and the gateway requires. Once sealed, the bytes a reader
//! maps or reads are the bytes written here, whoever holds a duplicate.
//!
//! Every failure here is the kernel's refusal of a resource (a memfd, its
//! pages, a seal), never a fault of the configuration, which is how the
//! callers in this module classify it. Boot calls it on one thread.

const std = @import("std");
const fd_mod = @import("collo_os").fd;

/// A new memfd named `name` holding `bytes`, sealed read-only with its
/// offset at 0. The caller owns the result.
pub fn sealBytes(name: []const u8, bytes: []const u8) !fd_mod.OwnedFd {
    const raw = try std.posix.memfd_create(name, std.os.linux.MFD.CLOEXEC | std.os.linux.MFD.ALLOW_SEALING);
    var owned = fd_mod.OwnedFd.fromRaw(raw);
    errdefer owned.deinit();
    try fd_mod.writeAllRaw(raw, bytes);
    try std.posix.lseek_SET(raw, 0);
    try fd_mod.addSeals(raw, fd_mod.memfd_readonly_seals);
    return owned;
}
