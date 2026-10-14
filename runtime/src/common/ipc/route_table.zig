//! The routes section of a definition artifact (`module_pack.zig`): every
//! route a worker of the definition serves, in configuration order, as its
//! entry module, whose default export gives the route's handler
//! (`worker/modules/routes.zig`), and its bindings. A dispatch names its
//! route by its index here (`DispatchWork.route_index`). Both processes
//! compile this file, so the layout and the rules below are the whole
//! contract. A route's bindings hold
//! secrets: they reach that route's handler `env` alone, never `process.env`
//! or another route.
//!
//! Layout, little-endian: `module_pack.Header.route_count` records of
//! `RouteRecord`, then the bindings sections they point at, each in the
//! layout of `route_bindings.zig`. The section ends where the pack's
//! specifiers begin.
//!
//! A valid section holds at most `routes_max` routes; every record names a
//! module of the pack and a bindings range inside the section, after the
//! records; and every bindings section passes `route_bindings.decode`. Two
//! routes may share an entry module. A pack without routes is the zygote's
//! warmup pack, which a worker refuses (`module_pack.validateDefinition`).
//! `validateInputs` checks routes about to be written against these rules and
//! `validate` checks them again on the bytes.
//!
//! Every function here is pure; any thread may call it.

const std = @import("std");
const server_limits = @import("collo_limits").server;
const route_bindings = @import("route_bindings.zig");

/// Most routes one artifact holds, the configuration's per-definition bound.
pub const routes_max: usize = server_limits.routes_per_definition_max;

/// One route, read in place as an extern struct like the pack's other
/// records.
pub const RouteRecord = extern struct {
    /// The position of the route's entry module in the pack.
    entry_module: u32,
    /// The route's bindings section, counted from the start of the pack.
    bindings_offset: u32,
    bindings_len: u32,
};

/// One route of an artifact to build.
pub const RouteInput = struct {
    /// The position of the route's entry module in the modules the pack is
    /// built from.
    entry_module: u32,
    bindings: []const route_bindings.Entry = &.{},
};

pub const Error = error{InvalidRouteTable};

/// The bytes the bindings sections of `routes` take once written, after
/// checking every route against the rules in this file's header for a pack of
/// `module_count` modules.
pub fn validateInputs(routes: []const RouteInput, module_count: usize) Error!usize {
    if (routes.len > routes_max)
        return error.InvalidRouteTable;
    var len: usize = 0;
    for (routes) |route| {
        if (route.entry_module >= module_count)
            return error.InvalidRouteTable;
        // Each term is at most `route_bindings.bytes_max`, so with at most
        // `routes_max` routes the sum cannot overflow.
        len += route_bindings.encodedLen(route.bindings) catch return error.InvalidRouteTable;
    }
    return len;
}

/// Writes the records of `routes`, which passed `validateInputs`, at
/// `records_offset` of `pack`, and their bindings sections from
/// `bindings_offset` on, exactly the length `validateInputs` returned.
/// Returns where the last bindings section ends.
pub fn write(pack: []u8, records_offset: usize, bindings_offset: usize, routes: []const RouteInput) usize {
    var cursor = bindings_offset;
    for (routes, 0..) |route, index| {
        const bindings_len = route_bindings.encodedLen(route.bindings) catch unreachable;
        const record = pack[records_offset + index * @sizeOf(RouteRecord) ..][0..@sizeOf(RouteRecord)];
        std.mem.writeInt(u32, record[0..4], route.entry_module, .little);
        std.mem.writeInt(u32, record[4..8], @intCast(cursor), .little);
        std.mem.writeInt(u32, record[8..12], @intCast(bindings_len), .little);
        route_bindings.encode(pack[cursor..][0..bindings_len], route.bindings);
        cursor += bindings_len;
    }
    return cursor;
}

/// Checks `records`, read from `pack`, against the rules in this file's
/// header, for bindings that must lie in `[bindings_start, bindings_end)` and
/// a pack of `module_count` modules.
pub fn validate(
    pack: []const u8,
    records: []align(1) const RouteRecord,
    bindings_start: usize,
    bindings_end: usize,
    module_count: usize,
) Error!void {
    if (records.len > routes_max)
        return error.InvalidRouteTable;
    std.debug.assert(bindings_start <= bindings_end);
    std.debug.assert(bindings_end <= pack.len);
    var entries: route_bindings.Entries = undefined;
    for (records) |record| {
        if (record.entry_module >= module_count)
            return error.InvalidRouteTable;
        const offset: usize = record.bindings_offset;
        if (offset < bindings_start or offset > bindings_end)
            return error.InvalidRouteTable;
        if (@as(usize, record.bindings_len) > bindings_end - offset)
            return error.InvalidRouteTable;
        _ = route_bindings.decode(pack[offset..][0..record.bindings_len], &entries) catch
            return error.InvalidRouteTable;
    }
}

comptime {
    // The pack's other records are read in place with the same rule.
    std.debug.assert(@sizeOf(RouteRecord) == 12);
    // A dispatch names a route by a u16 index.
    std.debug.assert(routes_max <= std.math.maxInt(u16) + 1);
}
