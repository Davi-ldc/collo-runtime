//! Maps the sealed module-pack memfds a worker registers, on its VM thread.
//! The mapping made here is the one the bridge keeps: registration consumes
//! it, so a caller reads the bytes (parse, validation, bookkeeping) only
//! before `MappedPack.take`.

const std = @import("std");
const bindings = @import("collo_bindings");
const fd_mod = @import("collo_os").fd;

/// A pack mapping the worker still owns until `take` hands it to
/// `Vm.registerModulePackMapping`; `deinit` releases one never taken.
pub const MappedPack = struct {
    mapping: ?bindings.Mapping,

    /// Valid until `take` or `deinit`.
    pub fn bytes(self: *const MappedPack) []const u8 {
        return self.mapping.?.bytes();
    }

    /// Hands the mapping to the caller, who passes it to a call that consumes
    /// it; `bytes` is invalid afterwards.
    pub fn take(self: *MappedPack) bindings.Mapping {
        const mapping = self.mapping.?;
        self.mapping = null;
        return mapping;
    }

    pub fn deinit(self: *MappedPack) void {
        if (self.mapping) |mapping|
            mapping.release();
        self.* = undefined;
    }
};

/// Refuses an fd that is not a memfd sealed against writes and resizes before
/// mapping it, because the bridge reads the mapping long after validation and
/// another holder of the file must not be able to change the bytes under it.
/// The caller may close `fd` once this returns. Fails with
/// `error.MissingFdSeals` for a memfd without those seals, with
/// `error.Unexpected` for an fd whose file cannot carry seals, with
/// `error.InvalidModulePack` for an empty file and with `error.FileTooLarge`
/// for one larger than `max_bytes`.
pub fn mapFdReadOnly(fd: std.posix.fd_t, max_bytes: usize) !MappedPack {
    try fd_mod.requireSeals(fd, fd_mod.memfd_readonly_seals);
    const stat = try std.posix.fstat(fd);
    if (stat.size <= 0)
        return error.InvalidModulePack;
    const len: usize = @intCast(stat.size);
    if (len > max_bytes)
        return error.FileTooLarge;
    return .{ .mapping = try bindings.Mapping.map(fd, len) };
}
