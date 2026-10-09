//! The bindings of one route: its text bindings as name/value pairs in
//! configuration order, the section a route holds in its definition's route
//! table (`route_table.zig`). The worker builds the route's `env` from it
//! (`worker/modules/route_env.zig`). Both processes compile this file, so the
//! layout and the rules below are the whole contract. Bindings hold secrets
//! and never reach `process.env`, which a worker installs empty.
//!
//! Layout, little-endian: a u32 entry count, then for every entry a u32
//! name length, the name bytes, a u32 value length and the value bytes.
//!
//! A valid section holds at most `entries_max` entries in at most `bytes_max`
//! bytes, every name passes `isBindingName`, no name repeats, every value is
//! UTF-8, and no byte follows the last entry. `encodedLen` checks these on
//! entries about to be encoded and `decode` checks them again on the bytes.
//! The configuration parser (`server/config/parse.zig`) checks `collo.json`
//! against the same rules, so a configuration it accepts never yields
//! bindings a worker refuses.
//!
//! Every function here is pure; any thread may call it.

const std = @import("std");
const server_limits = @import("collo_limits").server;

/// Largest section a worker accepts, the configuration's per-route bound.
pub const bytes_max: usize = server_limits.binding_bytes_per_route_max;

/// Most entries one section holds, the configuration's per-route bound.
pub const entries_max: usize = server_limits.bindings_per_route_max;

/// Longest binding name, the configuration's bound.
pub const name_bytes_max: usize = server_limits.binding_name_bytes_max;

/// The section of a route with no bindings: an entry count of zero.
pub const empty_blob = [_]u8{0} ** @sizeOf(u32);

pub const Entry = struct {
    name: []const u8,
    value: []const u8,
};

/// Caller storage for the entries of one decoded section.
pub const Entries = [entries_max]Entry;

pub const Error = error{InvalidRouteBindings};

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

/// The length of `entries` once encoded (none gives `empty_blob`), after
/// checking them against the rules in this file's header.
pub fn encodedLen(entries: []const Entry) Error!usize {
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

/// Writes `entries`, which passed `encodedLen`, into `buffer`, exactly
/// `encodedLen(entries)` bytes long.
pub fn encode(buffer: []u8, entries: []const Entry) void {
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
