//! The definition artifact: the immutable file that carries one worker
//! definition's ES modules and routes to its workers. The server builds one
//! per definition at boot (`server/routes/artifacts.zig`) and seals it into a
//! memfd that every launch passes in WorkerInit. A worker maps it read-only,
//! checks it once with `parse`, takes its routes from it and registers the
//! mapping with the engine, whose loader
//! (`bindings/jsc/runtime/module_loader.cpp`) wraps each module's source in
//! place as an external string, with no copy and no decode in the worker.
//! The zygote's warmup corpus travels in a pack of the same format without
//! routes. Everything here is a pure function of its arguments, callable from
//! any thread.
//!
//! Layout, in this order: the header, the module records, the index, the
//! routes section (`route_table.zig`), the specifiers, then the sources.
//! Offsets count bytes from the start of the pack. Integers are
//! little-endian: the header is read field by field, while records and index
//! entries are read in place as extern structs, which is correct only on a
//! little-endian host, as x86_64 and ARM64 both are.
//!
//! A module's key is its public specifier: `<task_root>/<path>` in a
//! definition's pack, `/__collo/zygote/<name>` in the warmup's. Its source is
//! stored ready to wrap: Latin-1 when every code point is at most U+00FF,
//! UTF-16LE otherwise (`module_flag_utf16`), at an even offset so the engine
//! reads 16-bit units in place. `buildAlloc` transcodes from UTF-8 as a UTF-8
//! decode does: it drops a leading byte order mark and replaces each maximal
//! invalid subsequence with U+FFFD, so the engine sees the text a decode of
//! the file gives. A source with non-Latin-1 text takes twice its character
//! count in bytes, shared by every worker of the definition and charged to
//! the server (`pack_bytes_total_max`).
//!
//! The index is open addressing with linear probing over a power-of-two
//! capacity, keyed by `hashSpecifier`; an empty slot holds
//! `empty_index_module` and hash 0.
//!
//! `parse` accepts a pack only when every section lies where the header puts
//! it, every record's specifier and source lie inside their sections, every
//! UTF-16 source is aligned and holds whole units, every specifier passes
//! `validateSpecifier`, the index finds every module at its own position, so
//! no specifier repeats, and the routes section is valid
//! (`route_table.validate`). A parsed pack is then read without further
//! checks. The engine's loader keeps its own copies of `magic`, `version`,
//! the header, record and index layouts, `module_flag_utf16`,
//! `empty_index_module` and `hashSpecifier`, and checks every offset it reads
//! instead of trusting this parse, so a change to any of them edits the loader
//! too. `runtime/tests/contracts/module_pack.zig` pins the bytes `buildAlloc`
//! writes, so a layout change edits that test as well.

const std = @import("std");
const route_bindings = @import("route_bindings.zig");
const route_table = @import("route_table.zig");

pub const magic: u32 = 0x4d4f4c43; // "CLOM" little-endian.
/// The only version `parse` accepts.
pub const version: u16 = 3;
/// Most modules one pack holds; the server refuses a definition whose import
/// graph holds more (`Graph.read` in `server/routes/module_graph.zig`).
/// `COLLO_MODULE_PACK_MAX_MODULES` in `bindings/include/collo/abi.h` repeats
/// it by hand.
pub const max_module_count: usize = 4096;
/// Largest pack `buildAlloc` writes and `parse` accepts, routes included.
/// `COLLO_MODULE_PACK_MAX_BYTES` in `bindings/include/collo/abi.h` repeats
/// it by hand.
pub const max_pack_bytes: usize = 16 * 1024 * 1024;
/// The directory every module of a definition's pack is keyed under, which is
/// also the worker's working directory, so `import.meta.dirname` and stack
/// frames name the paths tenant code sees.
pub const task_root = "/var/task";
/// `ModuleRecord.flags` bit of a source stored as UTF-16LE; clear, it is
/// Latin-1. No other bit is defined.
pub const module_flag_utf16: u32 = 1 << 0;
/// `module_index` of an empty index slot, whose hash is 0.
pub const empty_index_module: u32 = std.math.maxInt(u32);

/// Read and written field by field (`readHeader`, `writeHeader`), and
/// `@sizeOf(Header)` is the header's length in the pack. The module records
/// start right after it, the index right after them, and the routes section
/// right after the index; `specifiers_offset` ends the routes section.
pub const Header = extern struct {
    magic: u32,
    version: u16,
    /// Zero.
    flags: u16,
    module_count: u32,
    index_capacity: u32,
    route_count: u32,
    specifiers_offset: u32,
    sources_offset: u32,
    total_len: u32,
};

/// One module. A Latin-1 source may be empty; a UTF-16 one sits at an even
/// offset and has an even length.
pub const ModuleRecord = extern struct {
    specifier_offset: u32,
    specifier_len: u32,
    source_offset: u32,
    source_len: u32,
    flags: u32,
};

pub const IndexEntry = extern struct {
    specifier_hash: u32,
    module_index: u32,
};

/// How a module's source bytes encode its text.
pub const Encoding = enum {
    latin1,
    utf16le,
};

/// One module as `buildAlloc` takes it, with its source as UTF-8.
pub const Module = struct {
    specifier: []const u8,
    source: []const u8,
};

/// A module of a parsed pack, borrowing the pack's bytes.
pub const ParsedModule = struct {
    specifier: []const u8,
    /// The stored text in `encoding`: one byte per character for Latin-1,
    /// two little-endian bytes per UTF-16 unit.
    source: []const u8,
    encoding: Encoding,
};

/// A route of a parsed pack, borrowing the pack's bytes.
pub const Route = struct {
    /// The position of the route's entry module.
    entry_module: u32,
    entry_specifier: []const u8,
    /// The route's bindings section, valid for `route_bindings.decode`.
    bindings: []const u8,
};

pub const ParseError = error{ InvalidModulePack, ModulePackTooLarge };
pub const BuildError = error{ InvalidModulePack, ModulePackTooLarge, OutOfMemory };

/// A pack that passed `parse`, borrowing its bytes for its whole life.
pub const Parsed = struct {
    bytes: []const u8,
    header: Header,
    records: []align(1) const ModuleRecord,
    index: []align(1) const IndexEntry,
    routes: []align(1) const route_table.RouteRecord,

    pub fn moduleAt(self: Parsed, index: usize) ParsedModule {
        std.debug.assert(index < self.records.len);
        const record = self.records[index];
        return .{
            .specifier = sliceAt(self.bytes, record.specifier_offset, record.specifier_len),
            .source = sliceAt(self.bytes, record.source_offset, record.source_len),
            .encoding = if (record.flags & module_flag_utf16 != 0) .utf16le else .latin1,
        };
    }

    pub fn routeAt(self: Parsed, index: usize) Route {
        std.debug.assert(index < self.routes.len);
        const record = self.routes[index];
        return .{
            .entry_module = record.entry_module,
            .entry_specifier = self.moduleAt(record.entry_module).specifier,
            .bindings = sliceAt(self.bytes, record.bindings_offset, record.bindings_len),
        };
    }

    /// The position of the module named `specifier`, or null. The probe
    /// visits at most the index's capacity, so a full index still ends it.
    pub fn findIndex(self: Parsed, specifier: []const u8) ?usize {
        std.debug.assert(self.index.len != 0);
        const hash = hashSpecifier(specifier);
        var slot = @as(usize, hash) & (self.index.len - 1);
        var probes: usize = 0;
        while (probes < self.index.len) : (probes += 1) {
            const entry = self.index[slot];
            if (entry.module_index == empty_index_module)
                return null;
            if (entry.specifier_hash == hash and entry.module_index < self.records.len) {
                const candidate = self.moduleAt(entry.module_index);
                if (std.mem.eql(u8, candidate.specifier, specifier))
                    return entry.module_index;
            }
            slot = (slot + 1) & (self.index.len - 1);
        }
        return null;
    }

    pub fn findModule(self: Parsed, specifier: []const u8) ?ParsedModule {
        const index = self.findIndex(specifier) orelse return null;
        return self.moduleAt(index);
    }
};

/// A pack holding one module and no route, as the zygote's warmup corpus
/// travels.
pub fn buildSingleAlloc(allocator: std.mem.Allocator, specifier: []const u8, source: []const u8) BuildError![]u8 {
    return buildAlloc(allocator, &.{.{ .specifier = specifier, .source = source }}, &.{});
}

/// A pack holding one module and one route to it without bindings: the
/// smallest worker definition.
pub fn buildSingleRouteAlloc(allocator: std.mem.Allocator, specifier: []const u8, source: []const u8) BuildError![]u8 {
    return buildAlloc(allocator, &.{.{ .specifier = specifier, .source = source }}, &.{.{ .entry_module = 0 }});
}

/// Serializes `modules`, with each source transcoded from UTF-8 as the file
/// header says, and `routes`, whose `entry_module` indexes `modules`, into a
/// pack the caller owns and frees. Fails with `error.InvalidModulePack` for
/// input `parse` would refuse: no modules or more than `max_module_count`, an
/// invalid or repeated specifier, or a route `route_table.validateInputs`
/// refuses. Fails with `error.ModulePackTooLarge` above `max_pack_bytes`.
pub fn buildAlloc(
    allocator: std.mem.Allocator,
    modules: []const Module,
    routes: []const route_table.RouteInput,
) BuildError![]u8 {
    if (modules.len == 0 or modules.len > max_module_count)
        return error.InvalidModulePack;
    for (modules) |module|
        validateSpecifier(module.specifier) catch return error.InvalidModulePack;
    const bindings_len = route_table.validateInputs(routes, modules.len) catch return error.InvalidModulePack;

    const shapes = try allocator.alloc(SourceShape, modules.len);
    defer allocator.free(shapes);
    var specifiers_len: usize = 0;
    for (modules, shapes) |module, *shape| {
        specifiers_len = try addChecked(specifiers_len, module.specifier.len);
        shape.* = measureSource(module.source);
    }

    const records_offset: usize = @sizeOf(Header);
    const index_offset = records_offset + modules.len * @sizeOf(ModuleRecord);
    const index_capacity = indexCapacity(modules.len);
    const route_records_offset = index_offset + index_capacity * @sizeOf(IndexEntry);
    const bindings_offset = route_records_offset + routes.len * @sizeOf(route_table.RouteRecord);
    const specifiers_offset = try addChecked(bindings_offset, bindings_len);
    const sources_offset = try addChecked(specifiers_offset, specifiers_len);
    var total_len = sources_offset;
    for (shapes) |*shape| {
        total_len = try addChecked(total_len, sourcePadding(total_len, shape.encoding));
        shape.offset = total_len;
        total_len = try addChecked(total_len, shape.len);
    }
    if (total_len > max_pack_bytes)
        return error.ModulePackTooLarge;

    const bytes = try allocator.alloc(u8, total_len);
    errdefer allocator.free(bytes);
    @memset(bytes, 0);

    writeHeader(bytes[0..@sizeOf(Header)], .{
        .magic = magic,
        .version = version,
        .flags = 0,
        .module_count = @intCast(modules.len),
        .index_capacity = @intCast(index_capacity),
        .route_count = @intCast(routes.len),
        .specifiers_offset = @intCast(specifiers_offset),
        .sources_offset = @intCast(sources_offset),
        .total_len = @intCast(total_len),
    });

    const index_entries: []align(1) IndexEntry = std.mem.bytesAsSlice(
        IndexEntry,
        bytes[index_offset..route_records_offset],
    );
    for (index_entries) |*entry|
        entry.* = .{ .specifier_hash = 0, .module_index = empty_index_module };

    var specifier_cursor = specifiers_offset;
    for (modules, shapes, 0..) |module, shape, module_index| {
        writeRecord(bytes[records_offset + module_index * @sizeOf(ModuleRecord) ..][0..@sizeOf(ModuleRecord)], .{
            .specifier_offset = @intCast(specifier_cursor),
            .specifier_len = @intCast(module.specifier.len),
            .source_offset = @intCast(shape.offset),
            .source_len = @intCast(shape.len),
            .flags = switch (shape.encoding) {
                .latin1 => 0,
                .utf16le => module_flag_utf16,
            },
        });
        @memcpy(bytes[specifier_cursor..][0..module.specifier.len], module.specifier);
        specifier_cursor += module.specifier.len;
        writeSource(module.source, shape.encoding, bytes[shape.offset..][0..shape.len]);
        try putIndexEntry(index_entries, modules, @intCast(module_index));
    }
    std.debug.assert(specifier_cursor == sources_offset);

    const bindings_end = route_table.write(bytes, route_records_offset, bindings_offset, routes);
    std.debug.assert(bindings_end == specifiers_offset);
    return bytes;
}

/// Checks `bytes` against every rule in the file header and returns a view
/// that borrows them. Fails with `error.ModulePackTooLarge` above
/// `max_pack_bytes` and `error.InvalidModulePack` for any other violation.
pub fn parse(bytes: []const u8) ParseError!Parsed {
    if (bytes.len < @sizeOf(Header))
        return error.InvalidModulePack;
    if (bytes.len > max_pack_bytes)
        return error.ModulePackTooLarge;

    const header = readHeader(bytes[0..@sizeOf(Header)]);
    if (header.magic != magic or header.version != version or header.flags != 0)
        return error.InvalidModulePack;
    if (header.module_count == 0 or header.module_count > max_module_count)
        return error.InvalidModulePack;
    // Checked before the power-of-two test, which requires a nonzero value.
    if (header.index_capacity < header.module_count)
        return error.InvalidModulePack;
    if (!std.math.isPowerOfTwo(header.index_capacity))
        return error.InvalidModulePack;
    if (header.route_count > route_table.routes_max)
        return error.InvalidModulePack;
    if (@as(usize, header.total_len) != bytes.len)
        return error.InvalidModulePack;

    const module_count: usize = header.module_count;
    const specifiers_offset: usize = header.specifiers_offset;
    const sources_offset: usize = header.sources_offset;
    const total_len: usize = header.total_len;
    // Each term is bounded (`max_module_count`, a u32 capacity, `routes_max`),
    // so on a 64-bit host the sums cannot overflow.
    const records_offset: usize = @sizeOf(Header);
    const index_offset = records_offset + module_count * @sizeOf(ModuleRecord);
    const route_records_offset = index_offset + @as(usize, header.index_capacity) * @sizeOf(IndexEntry);
    const route_records_end = route_records_offset + @as(usize, header.route_count) * @sizeOf(route_table.RouteRecord);
    if (route_records_end > specifiers_offset)
        return error.InvalidModulePack;
    if (specifiers_offset > sources_offset)
        return error.InvalidModulePack;
    if (sources_offset > total_len)
        return error.InvalidModulePack;

    const records: []align(1) const ModuleRecord = std.mem.bytesAsSlice(
        ModuleRecord,
        bytes[records_offset..index_offset],
    );
    const index: []align(1) const IndexEntry = std.mem.bytesAsSlice(
        IndexEntry,
        bytes[index_offset..route_records_offset],
    );
    const routes: []align(1) const route_table.RouteRecord = std.mem.bytesAsSlice(
        route_table.RouteRecord,
        bytes[route_records_offset..route_records_end],
    );

    for (records) |record| {
        if (record.flags & ~module_flag_utf16 != 0)
            return error.InvalidModulePack;
        if (record.specifier_len == 0)
            return error.InvalidModulePack;
        try requireInside(record.specifier_offset, record.specifier_len, specifiers_offset, sources_offset);
        try requireInside(record.source_offset, record.source_len, sources_offset, total_len);
        if (record.flags & module_flag_utf16 != 0) {
            if (record.source_offset % 2 != 0 or record.source_len % 2 != 0)
                return error.InvalidModulePack;
        }
        validateSpecifier(sliceAt(bytes, record.specifier_offset, record.specifier_len)) catch
            return error.InvalidModulePack;
    }

    var live_index_entries: usize = 0;
    for (index) |entry| {
        if (entry.module_index == empty_index_module) {
            if (entry.specifier_hash != 0)
                return error.InvalidModulePack;
            continue;
        }
        if (entry.module_index >= records.len)
            return error.InvalidModulePack;
        const record = records[entry.module_index];
        if (entry.specifier_hash != hashSpecifier(sliceAt(bytes, record.specifier_offset, record.specifier_len)))
            return error.InvalidModulePack;
        live_index_entries += 1;
    }
    if (live_index_entries != records.len)
        return error.InvalidModulePack;

    route_table.validate(bytes, routes, route_records_end, specifiers_offset, module_count) catch
        return error.InvalidModulePack;

    const parsed: Parsed = .{
        .bytes = bytes,
        .header = header,
        .records = records,
        .index = index,
        .routes = routes,
    };
    for (records, 0..) |record, expected_index| {
        const specifier = sliceAt(bytes, record.specifier_offset, record.specifier_len);
        if (parsed.findIndex(specifier) != expected_index)
            return error.InvalidModulePack;
    }
    return parsed;
}

/// The rules a worker definition's artifact adds to `parse`: at least one
/// route, and every module keyed below `task_root`, so no tenant module can
/// take a key of the zygote's own namespace. Fails with
/// `error.InvalidModulePack`.
pub fn validateDefinition(parsed: Parsed) error{InvalidModulePack}!void {
    if (parsed.routes.len == 0)
        return error.InvalidModulePack;
    for (0..parsed.records.len) |index| {
        if (!std.mem.startsWith(u8, parsed.moduleAt(index).specifier, task_root ++ "/"))
            return error.InvalidModulePack;
    }
}

/// The rules every module specifier follows: it starts with '/', holds no
/// NUL, CR, LF, tab, space, backslash, '?' or '#', and has no empty, `.` or
/// `..` segment. `buildAlloc`, `parse` and the server's key builder
/// (`server/routes/artifacts.zig`) all apply them.
pub fn validateSpecifier(specifier: []const u8) error{InvalidModuleSpecifier}!void {
    if (specifier.len == 0 or specifier[0] != '/')
        return error.InvalidModuleSpecifier;
    if (std.mem.indexOfAny(u8, specifier, "\x00\r\n\t \\?#") != null)
        return error.InvalidModuleSpecifier;
    var segments = std.mem.splitScalar(u8, specifier[1..], '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, ".."))
            return error.InvalidModuleSpecifier;
    }
}

/// Wyhash with seed 0, folded to 32 bits by xoring its halves.
/// `modulePackHashSpecifier` in `bindings/jsc/runtime/module_loader.cpp`
/// computes the same value.
pub fn hashSpecifier(specifier: []const u8) u32 {
    const hash = std.hash.Wyhash.hash(0, specifier);
    return @truncate(hash ^ (hash >> 32));
}

/// A source's stored form, decided before the pack is laid out.
const SourceShape = struct {
    encoding: Encoding,
    /// Stored bytes.
    len: usize,
    /// Where the source starts in the pack, set by the layout.
    offset: usize = 0,
};

const replacement_character: u21 = 0xFFFD;
const utf8_byte_order_mark = "\xEF\xBB\xBF";

/// The stored form of the UTF-8 text `utf8`: Latin-1 when every decoded code
/// point fits a byte, UTF-16LE otherwise. A source held in memory has fewer
/// than `maxInt(isize)` bytes, and a UTF-16 unit never stands for fewer than
/// one of them, so the doubled count fits a `usize`.
fn measureSource(utf8: []const u8) SourceShape {
    const text = withoutByteOrderMark(utf8);
    var character_count: usize = 0;
    var unit_count: usize = 0;
    var wide = false;
    var cursor: usize = 0;
    while (cursor < text.len) {
        const code_point = decodeNext(text, &cursor);
        character_count += 1;
        unit_count += if (code_point >= 0x10000) 2 else 1;
        if (code_point > 0xFF)
            wide = true;
    }
    if (wide)
        return .{ .encoding = .utf16le, .len = unit_count * 2 };
    return .{ .encoding = .latin1, .len = character_count };
}

/// Writes `utf8` in `encoding` into `dest`, which `measureSource` sized.
fn writeSource(utf8: []const u8, encoding: Encoding, dest: []u8) void {
    const text = withoutByteOrderMark(utf8);
    var cursor: usize = 0;
    var written: usize = 0;
    switch (encoding) {
        .latin1 => while (cursor < text.len) {
            dest[written] = @intCast(decodeNext(text, &cursor));
            written += 1;
        },
        .utf16le => while (cursor < text.len) {
            const code_point = decodeNext(text, &cursor);
            if (code_point >= 0x10000) {
                const offset = code_point - 0x10000;
                writeUnit(dest, &written, @intCast(0xD800 + (offset >> 10)));
                writeUnit(dest, &written, @intCast(0xDC00 + (offset & 0x3FF)));
            } else {
                writeUnit(dest, &written, @intCast(code_point));
            }
        },
    }
    std.debug.assert(written == dest.len);
}

fn writeUnit(dest: []u8, written: *usize, unit: u16) void {
    std.mem.writeInt(u16, dest[written.*..][0..2], unit, .little);
    written.* += 2;
}

fn withoutByteOrderMark(utf8: []const u8) []const u8 {
    if (std.mem.startsWith(u8, utf8, utf8_byte_order_mark))
        return utf8[utf8_byte_order_mark.len..];
    return utf8;
}

/// The code point at `cursor.*`, advancing past it, as the WHATWG UTF-8
/// decoder reads it: a byte that cannot start a sequence, or a sequence cut
/// short by a byte outside its allowed range, yields U+FFFD, and the byte
/// that cut it short starts the next read. Overlong forms, surrogates and
/// code points above U+10FFFF are refused by the ranges.
fn decodeNext(text: []const u8, cursor: *usize) u21 {
    const lead = text[cursor.*];
    cursor.* += 1;
    if (lead < 0x80)
        return lead;
    var code_point: u21 = 0;
    var needed: u8 = 0;
    var lower: u8 = 0x80;
    var upper: u8 = 0xBF;
    switch (lead) {
        0xC2...0xDF => {
            needed = 1;
            code_point = lead & 0x1F;
        },
        0xE0...0xEF => {
            if (lead == 0xE0) lower = 0xA0;
            if (lead == 0xED) upper = 0x9F;
            needed = 2;
            code_point = lead & 0x0F;
        },
        0xF0...0xF4 => {
            if (lead == 0xF0) lower = 0x90;
            if (lead == 0xF4) upper = 0x8F;
            needed = 3;
            code_point = lead & 0x07;
        },
        else => return replacement_character,
    }
    var seen: u8 = 0;
    while (seen < needed) : (seen += 1) {
        if (cursor.* == text.len)
            return replacement_character;
        const byte = text[cursor.*];
        if (byte < lower or byte > upper)
            return replacement_character;
        code_point = (code_point << 6) | (byte & 0x3F);
        lower = 0x80;
        upper = 0xBF;
        cursor.* += 1;
    }
    return code_point;
}

/// The byte that keeps a UTF-16 source at an even offset.
fn sourcePadding(offset: usize, encoding: Encoding) usize {
    return switch (encoding) {
        .latin1 => 0,
        .utf16le => offset % 2,
    };
}

/// The smallest power of two at least twice `module_count`, which keeps the
/// index at most half full.
fn indexCapacity(module_count: usize) usize {
    std.debug.assert(module_count <= max_module_count);
    return std.math.ceilPowerOfTwoAssert(usize, module_count * 2);
}

/// Inserts module `module_index` of `modules`; fails with
/// `error.InvalidModulePack` when an earlier module has the same specifier.
fn putIndexEntry(index: []align(1) IndexEntry, modules: []const Module, module_index: u32) error{InvalidModulePack}!void {
    const specifier = modules[module_index].specifier;
    const hash = hashSpecifier(specifier);
    var slot = @as(usize, hash) & (index.len - 1);
    while (index[slot].module_index != empty_index_module) {
        const existing = index[slot];
        if (existing.specifier_hash == hash and std.mem.eql(u8, modules[existing.module_index].specifier, specifier))
            return error.InvalidModulePack;
        slot = (slot + 1) & (index.len - 1);
    }
    index[slot] = .{ .specifier_hash = hash, .module_index = module_index };
}

/// Fails unless `[offset, offset + len)` lies within `[start, end)`.
fn requireInside(offset: u32, len: u32, start: usize, end: usize) error{InvalidModulePack}!void {
    const first: usize = offset;
    if (first < start or first > end)
        return error.InvalidModulePack;
    if (@as(usize, len) > end - first)
        return error.InvalidModulePack;
}

fn sliceAt(bytes: []const u8, offset: u32, len: u32) []const u8 {
    return bytes[@as(usize, offset)..][0..@as(usize, len)];
}

fn addChecked(lhs: usize, rhs: usize) error{ModulePackTooLarge}!usize {
    return std.math.add(usize, lhs, rhs) catch error.ModulePackTooLarge;
}

fn readHeader(bytes: *const [@sizeOf(Header)]u8) Header {
    return .{
        .magic = std.mem.readInt(u32, bytes[0..4], .little),
        .version = std.mem.readInt(u16, bytes[4..6], .little),
        .flags = std.mem.readInt(u16, bytes[6..8], .little),
        .module_count = std.mem.readInt(u32, bytes[8..12], .little),
        .index_capacity = std.mem.readInt(u32, bytes[12..16], .little),
        .route_count = std.mem.readInt(u32, bytes[16..20], .little),
        .specifiers_offset = std.mem.readInt(u32, bytes[20..24], .little),
        .sources_offset = std.mem.readInt(u32, bytes[24..28], .little),
        .total_len = std.mem.readInt(u32, bytes[28..32], .little),
    };
}

fn writeHeader(dest: *[@sizeOf(Header)]u8, header: Header) void {
    std.mem.writeInt(u32, dest[0..4], header.magic, .little);
    std.mem.writeInt(u16, dest[4..6], header.version, .little);
    std.mem.writeInt(u16, dest[6..8], header.flags, .little);
    std.mem.writeInt(u32, dest[8..12], header.module_count, .little);
    std.mem.writeInt(u32, dest[12..16], header.index_capacity, .little);
    std.mem.writeInt(u32, dest[16..20], header.route_count, .little);
    std.mem.writeInt(u32, dest[20..24], header.specifiers_offset, .little);
    std.mem.writeInt(u32, dest[24..28], header.sources_offset, .little);
    std.mem.writeInt(u32, dest[28..32], header.total_len, .little);
}

fn writeRecord(dest: *[@sizeOf(ModuleRecord)]u8, record: ModuleRecord) void {
    std.mem.writeInt(u32, dest[0..4], record.specifier_offset, .little);
    std.mem.writeInt(u32, dest[4..8], record.specifier_len, .little);
    std.mem.writeInt(u32, dest[8..12], record.source_offset, .little);
    std.mem.writeInt(u32, dest[12..16], record.source_len, .little);
    std.mem.writeInt(u32, dest[16..20], record.flags, .little);
}

comptime {
    // The loader in `bindings/jsc/runtime/module_loader.cpp` reads these
    // sizes as literals.
    std.debug.assert(@sizeOf(Header) == 32);
    std.debug.assert(@sizeOf(ModuleRecord) == 20);
    std.debug.assert(@sizeOf(IndexEntry) == 8);
    // Every offset and length fits the u32 fields that hold it.
    std.debug.assert(max_pack_bytes <= std.math.maxInt(u32));
    std.debug.assert(max_module_count * 2 <= std.math.maxInt(u32));
}
