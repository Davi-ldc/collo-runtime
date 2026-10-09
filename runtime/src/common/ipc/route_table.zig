//! The route table of one worker definition: every route a worker of the
//! definition serves, in configuration order, as the entry specifier the
//! worker evaluates and the route's bindings, sealed into a read-only memfd
//! that WorkerInit carries to every worker of the definition. The server
//! builds one table per definition at boot (`server/routes/artifacts.zig`),
//! each launch sends its own dup (`host/launch.zig`), and the worker maps it,
//! checks it whole before it evaluates anything, and finds a request's route
//! in it by the route index the dispatch carries (`worker/modules/routes.zig`).
//! Both processes compile this file, so the layout and the rules below are
//! the whole contract. A route's bindings hold secrets: they reach that
//! route's handler `env` alone, never `process.env` or another route.
//!
//! Layout, little-endian: a u32 route count, then for every route a u32
//! entry specifier length and the specifier bytes, and a u32 bindings length
//! and the bindings in the layout of `route_bindings.zig`.
//!
//! A valid table holds at most `routes_max` routes in at most `bytes_max`
//! bytes, every entry specifier passes `module_pack.validateSpecifier` within
//! `entry_specifier_bytes_max` bytes, every bindings section is valid
//! (`route_bindings.decode`), and no byte follows the last route. Two routes
//! may share an entry. The empty table, a count of zero, belongs to a worker
//! that serves no route. `buildSealed` checks its input against these rules
//! and `decode` checks them again on the bytes.
//!
//! Any thread may call these functions; only `buildSealed` and
//! `createEmptySealed` touch the kernel, to create the memfd.

const std = @import("std");
const server_limits = @import("collo_limits").server;
const fd_mod = @import("collo_os").fd;
const module_pack = @import("module_pack.zig");
const route_bindings = @import("route_bindings.zig");

/// Most routes one table holds, the configuration's per-definition bound.
pub const routes_max: usize = server_limits.routes_per_definition_max;

/// Longest entry specifier a table carries.
pub const entry_specifier_bytes_max: usize = 4096;

/// Largest table a worker accepts: `routes_max` routes, each with the longest
/// specifier and the largest bindings section.
pub const bytes_max: usize = @sizeOf(u32) +
    routes_max * (2 * @sizeOf(u32) + entry_specifier_bytes_max + route_bindings.bytes_max);

/// The table of a worker that serves no route: a route count of zero.
pub const empty_blob = [_]u8{0} ** @sizeOf(u32);

pub const Route = struct {
    entry_specifier: []const u8,
    /// The route's bindings section, in the layout of `route_bindings.zig`.
    bindings: []const u8,
};

/// One route of a table to build.
pub const RouteInput = struct {
    entry_specifier: []const u8,
    bindings: []const route_bindings.Entry,
};

/// Caller storage for the routes of one decoded table.
pub const Routes = [routes_max]Route;

pub const Error = error{InvalidRouteTable};

/// A built table: the sealed memfd and the length WorkerInit carries, which
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

/// Serializes `routes` (none gives `empty_blob`) into a memfd sealed
/// read-only, after checking them against the rules in this file's header.
/// The caller owns the result and closes it.
pub fn buildSealed(allocator: std.mem.Allocator, routes: []const RouteInput) !Sealed {
    const blob_len = try encodedLen(routes);
    const buffer = try allocator.alloc(u8, blob_len);
    defer allocator.free(buffer);
    encode(buffer, routes);
    return sealBytes(buffer);
}

/// `empty_blob` in a sealed memfd, without allocating.
pub fn createEmptySealed() !Sealed {
    return sealBytes(&empty_blob);
}

/// The routes of `blob`, borrowing its bytes; fails unless `blob` follows
/// every rule in this file's header.
pub fn decode(blob: []const u8, routes: *Routes) Error![]const Route {
    if (blob.len > bytes_max)
        return error.InvalidRouteTable;
    var reader: Reader = .{ .bytes = blob };
    const count = try reader.length();
    if (count > routes.len)
        return error.InvalidRouteTable;
    var entries: route_bindings.Entries = undefined;
    for (routes[0..count]) |*route| {
        const specifier = try reader.lengthPrefixed();
        if (!validEntrySpecifier(specifier))
            return error.InvalidRouteTable;
        const bindings = try reader.lengthPrefixed();
        _ = route_bindings.decode(bindings, &entries) catch return error.InvalidRouteTable;
        route.* = .{ .entry_specifier = specifier, .bindings = bindings };
    }
    if (reader.offset != blob.len)
        return error.InvalidRouteTable;
    return routes[0..count];
}

fn validEntrySpecifier(specifier: []const u8) bool {
    if (specifier.len > entry_specifier_bytes_max)
        return false;
    module_pack.validateSpecifier(specifier) catch return false;
    return true;
}

fn encodedLen(routes: []const RouteInput) Error!usize {
    if (routes.len > routes_max)
        return error.InvalidRouteTable;
    var len: usize = @sizeOf(u32);
    for (routes) |route| {
        if (!validEntrySpecifier(route.entry_specifier))
            return error.InvalidRouteTable;
        const bindings_len = route_bindings.encodedLen(route.bindings) catch return error.InvalidRouteTable;
        // Each term is bounded, so with at most `routes_max` routes the sum
        // stays within `bytes_max`.
        len += 2 * @sizeOf(u32) + route.entry_specifier.len + bindings_len;
    }
    std.debug.assert(len <= bytes_max);
    return len;
}

fn encode(buffer: []u8, routes: []const RouteInput) void {
    var offset: usize = 0;
    writeU32(buffer, &offset, @intCast(routes.len));
    for (routes) |route| {
        writeU32(buffer, &offset, @intCast(route.entry_specifier.len));
        @memcpy(buffer[offset..][0..route.entry_specifier.len], route.entry_specifier);
        offset += route.entry_specifier.len;
        const bindings_len = route_bindings.encodedLen(route.bindings) catch unreachable;
        writeU32(buffer, &offset, @intCast(bindings_len));
        route_bindings.encode(buffer[offset..][0..bindings_len], route.bindings);
        offset += bindings_len;
    }
    std.debug.assert(offset == buffer.len);
}

fn writeU32(buffer: []u8, offset: *usize, value: u32) void {
    std.debug.assert(buffer.len - offset.* >= @sizeOf(u32));
    std.mem.writeInt(u32, buffer[offset.*..][0..@sizeOf(u32)], value, .little);
    offset.* += @sizeOf(u32);
}

fn sealBytes(bytes: []const u8) !Sealed {
    const fd = try std.posix.memfd_create(
        "collo-route-table",
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
            return error.InvalidRouteTable;
        const value = std.mem.readInt(u32, self.bytes[self.offset..][0..@sizeOf(u32)], .little);
        self.offset += @sizeOf(u32);
        return value;
    }

    fn lengthPrefixed(self: *Reader) Error![]const u8 {
        const len = try self.length();
        if (self.bytes.len - self.offset < len)
            return error.InvalidRouteTable;
        const slice = self.bytes[self.offset..][0..len];
        self.offset += len;
        return slice;
    }
};

comptime {
    // The count and every length fit the u32 fields that hold them.
    std.debug.assert(bytes_max <= std.math.maxInt(u32));
    std.debug.assert(routes_max <= std.math.maxInt(u32));
}
