//! The bindings blob of one route: its text bindings as name/value pairs in
//! configuration order, sealed into a read-only memfd that WorkerInit
//! carries to every worker of the route. The server builds one blob per
//! route at boot (`server/routes/artifacts.zig`), each launch sends its own
//! dup (`host/launch.zig`), and the worker maps it once and builds the
//! route's `env` from it (`worker/modules/route_env.zig`). Both processes
//! compile this file, so the layout and the rules below are the whole
//! contract. The blob holds secrets and never reaches `process.env`, which a
//! worker installs empty.
//!
//! Layout, little-endian: a u32 entry count, then for every entry a u32
//! name length, the name bytes, a u32 value length and the value bytes.
//!
//! A valid blob holds at most `entries_max` entries in at most `bytes_max`
//! bytes, every name passes `isBindingName`, no name repeats, every value is
//! UTF-8, and no byte follows the last entry. `buildSealed` checks these on
//! its input and `decode` checks them again on the bytes. The configuration
//! parser (`server/config/parse.zig`) checks `collo.json` against the same
//! rules, so a configuration it accepts never yields a blob a worker
//! refuses.
//!
//! Any thread may call these functions; only `buildSealed` and
//! `createEmptySealed` touch the kernel, to create the memfd.

const std = @import("std");
const server_limits = @import("collo_limits").server;
const fd_mod = @import("collo_os").fd;

/// Largest blob a worker accepts, the configuration's per-route bound.
pub const bytes_max: usize = server_limits.binding_bytes_per_route_max;

/// Most entries one blob holds, the configuration's per-route bound.
pub const entries_max: usize = server_limits.bindings_per_route_max;

/// Longest binding name, the configuration's bound.
pub const name_bytes_max: usize = server_limits.binding_name_bytes_max;

/// The blob of a route with no bindings: an entry count of zero.
pub const empty_blob = [_]u8{0} ** @sizeOf(u32);

pub const Entry = struct {
    name: []const u8,
    value: []const u8,
};

/// Caller storage for the entries of one decoded blob.
pub const Entries = [entries_max]Entry;

pub const Error = error{InvalidRouteBindings};

/// A built blob: the sealed memfd and the length WorkerInit carries, which
/// is exactly what the worker maps.
pub const Sealed = struct {
    fd: std.posix.fd_t,
    blob_len: u64,

    /// A close-on-exec dup with its own lifetime. Seals live on the inode,
    /// so the copy is read-only too, and the shared file offset is harmless
    /// because every reader maps at offset 0.
    pub fn dupCloexec(self: Sealed) !Sealed {
        var owned = try fd_mod.OwnedFd.dupCloexec(self.fd);
        return .{ .fd = owned.release(), .blob_len = self.blob_len };
    }

    pub fn close(self: Sealed) void {
        if (self.fd >= 0)
            std.posix.close(self.fd);
    }
};

/// True for a name `[A-Za-z_][A-Za-z0-9_]*` of at most `name_bytes_max`
/// bytes. Such a name is never an array index, which the bridge's `env`
/// builder (`collo_env_object_new`) also refuses.
pub fn isBindingName(name: []const u8) bool {
    if (name.len == 0 or name.len > name_bytes_max)
        return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_')
        return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_')
            return false;
    }
    return true;
}

/// Serializes `entries` (none gives `empty_blob`) into a memfd sealed
/// read-only, after checking them against the rules in this file's header.
/// The caller owns the result and closes it.
pub fn buildSealed(allocator: std.mem.Allocator, entries: []const Entry) !Sealed {
    const blob_len = try encodedLen(entries);
    const buffer = try allocator.alloc(u8, blob_len);
    defer allocator.free(buffer);
    encode(buffer, entries);
    return sealBytes(buffer);
}

/// `empty_blob` in a sealed memfd, without allocating.
pub fn createEmptySealed() !Sealed {
    return sealBytes(&empty_blob);
}

/// The entries of `blob`, borrowing its bytes; fails unless `blob` follows
/// every rule in this file's header.
pub fn decode(blob: []const u8, entries: *Entries) Error![]const Entry {
    if (blob.len > bytes_max)
        return error.InvalidRouteBindings;
    var reader: Reader = .{ .bytes = blob };
    const count = try reader.length();
    if (count > entries.len)
        return error.InvalidRouteBindings;
    for (entries[0..count], 0..) |*entry, index| {
        const name = try reader.lengthPrefixed();
        const value = try reader.lengthPrefixed();
        if (!validEntry(entries[0..index], name, value))
            return error.InvalidRouteBindings;
        entry.* = .{ .name = name, .value = value };
    }
    if (reader.offset != blob.len)
        return error.InvalidRouteBindings;
    return entries[0..count];
}

fn encodedLen(entries: []const Entry) Error!usize {
    if (entries.len > entries_max)
        return error.InvalidRouteBindings;
    var len: usize = @sizeOf(u32);
    for (entries, 0..) |entry, index| {
        if (!validEntry(entries[0..index], entry.name, entry.value))
            return error.InvalidRouteBindings;
        // Every term is bounded by `bytes_max` before the next is added, so
        // the sum cannot overflow.
        if (entry.value.len > bytes_max)
            return error.InvalidRouteBindings;
        len += 2 * @sizeOf(u32) + entry.name.len + entry.value.len;
        if (len > bytes_max)
            return error.InvalidRouteBindings;
    }
    return len;
}

/// One entry's rules: a valid name that no earlier entry holds, and a UTF-8
/// value.
fn validEntry(earlier: []const Entry, name: []const u8, value: []const u8) bool {
    if (!isBindingName(name))
        return false;
    for (earlier) |previous| {
        if (std.mem.eql(u8, previous.name, name))
            return false;
    }
    return std.unicode.utf8ValidateSlice(value);
}

fn encode(buffer: []u8, entries: []const Entry) void {
    var offset: usize = 0;
    writeU32(buffer, &offset, @intCast(entries.len));
    for (entries) |entry| {
        writeLengthPrefixed(buffer, &offset, entry.name);
        writeLengthPrefixed(buffer, &offset, entry.value);
    }
    std.debug.assert(offset == buffer.len);
}

fn writeLengthPrefixed(buffer: []u8, offset: *usize, bytes: []const u8) void {
    writeU32(buffer, offset, @intCast(bytes.len));
    @memcpy(buffer[offset.*..][0..bytes.len], bytes);
    offset.* += bytes.len;
}

fn writeU32(buffer: []u8, offset: *usize, value: u32) void {
    std.debug.assert(buffer.len - offset.* >= @sizeOf(u32));
    std.mem.writeInt(u32, buffer[offset.*..][0..@sizeOf(u32)], value, .little);
    offset.* += @sizeOf(u32);
}

fn sealBytes(bytes: []const u8) !Sealed {
    const fd = try std.posix.memfd_create(
        "collo-route-bindings",
        std.os.linux.MFD.CLOEXEC | std.os.linux.MFD.ALLOW_SEALING,
    );
    errdefer std.posix.close(fd);
    try fd_mod.writeAllRaw(fd, bytes);
    try std.posix.lseek_SET(fd, 0);
    try fd_mod.addSeals(fd, fd_mod.memfd_readonly_seals);
    return .{ .fd = fd, .blob_len = bytes.len };
}

/// Little-endian u32 lengths and the bytes they announce, never past the end.
const Reader = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn length(self: *Reader) Error!usize {
        if (self.bytes.len - self.offset < @sizeOf(u32))
            return error.InvalidRouteBindings;
        const value = std.mem.readInt(u32, self.bytes[self.offset..][0..@sizeOf(u32)], .little);
        self.offset += @sizeOf(u32);
        return value;
    }

    fn lengthPrefixed(self: *Reader) Error![]const u8 {
        const len = try self.length();
        if (self.bytes.len - self.offset < len)
            return error.InvalidRouteBindings;
        const slice = self.bytes[self.offset..][0..len];
        self.offset += len;
        return slice;
    }
};

comptime {
    // The count and every length fit the u32 fields that hold them.
    std.debug.assert(bytes_max <= std.math.maxInt(u32));
    std.debug.assert(entries_max <= std.math.maxInt(u32));
}
