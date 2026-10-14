//! The definition artifact's format (`common/ipc/module_pack.zig`): a round
//! trip of specifiers, sources and routes; how `buildAlloc` stores each
//! source, Latin-1 or aligned UTF-16LE, with a leading byte order mark
//! dropped and every maximal invalid UTF-8 subsequence replaced as the WHATWG
//! decoder does; the builder's refusals; `parse` refusing bytes the builder
//! would never write; and the rules `validateDefinition` adds for a worker.
//! The routes section's own codec is covered by `route_table.zig`, the pinned
//! bytes by `runtime/tests/contracts/module_pack.zig`, the server's artifacts
//! by `server/tests/routes/artifacts.zig`, and the engine wrapping the
//! sources by `bindings/tests/module_loader.zig`.

const std = @import("std");
const ipc = @import("collo_ipc");

const module_pack = ipc.module_pack;
const route_table = ipc.route_table;
const route_bindings = ipc.route_bindings;
const Encoding = module_pack.Encoding;

// Byte offsets of the header fields and record fields, as the format lays
// them out, so a test can corrupt one field of a built pack.
const header_magic = 0;
const header_version = 4;
const header_flags = 6;
const header_module_count = 8;
const header_index_capacity = 12;
const header_route_count = 16;
const header_specifiers_offset = 20;
const header_sources_offset = 24;
const header_total_len = 28;
const record_specifier_offset = 0;
const record_specifier_len = 4;
const record_source_offset = 8;
const record_source_len = 12;
const record_flags = 16;
const route_entry_module = 0;
const route_bindings_offset = 4;

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

fn recordOffset(module_index: usize) usize {
    return @sizeOf(module_pack.Header) + module_index * @sizeOf(module_pack.ModuleRecord);
}

fn indexOffset(bytes: []const u8) usize {
    return recordOffset(readU32(bytes, header_module_count));
}

fn routeRecordOffset(bytes: []const u8, route_index: usize) usize {
    const capacity: usize = readU32(bytes, header_index_capacity);
    return indexOffset(bytes) + capacity * @sizeOf(module_pack.IndexEntry) + route_index * @sizeOf(route_table.RouteRecord);
}

/// The offset of the index slot holding module `module_index`.
fn indexSlotOf(bytes: []const u8, module_index: u32) !usize {
    const capacity: usize = readU32(bytes, header_index_capacity);
    for (0..capacity) |slot| {
        const offset = indexOffset(bytes) + slot * @sizeOf(module_pack.IndexEntry);
        if (readU32(bytes, offset + 4) == module_index)
            return offset;
    }
    return error.TestMissingIndexEntry;
}

/// The UTF-16LE bytes of the UTF-8 text `utf8`.
fn utf16(comptime utf8: []const u8) []const u8 {
    return std.mem.sliceAsBytes(std.unicode.utf8ToUtf16LeStringLiteral(utf8)[0..]);
}

/// `utf8`, packed alone, is stored in `encoding` as exactly `expected`.
fn expectStored(utf8: []const u8, encoding: Encoding, expected: []const u8) !void {
    const pack = try module_pack.buildSingleAlloc(std.testing.allocator, "/m.js", utf8);
    defer std.testing.allocator.free(pack);
    const module = (try module_pack.parse(pack)).moduleAt(0);
    try std.testing.expectEqual(encoding, module.encoding);
    try std.testing.expectEqualSlices(u8, expected, module.source);
}

test "a pack keeps every module's specifier and source and every route's entry and bindings" {
    const modules = [_]module_pack.Module{
        .{ .specifier = "/var/task/index.js", .source = "import './lib/a.js';\nexport default () => 1;\n" },
        .{ .specifier = "/var/task/lib/a.js", .source = "export const s = '\u{03c0}';\n" },
        .{ .specifier = "/var/task/lib/empty.js", .source = "" },
    };
    const routes = [_]route_table.RouteInput{
        .{ .entry_module = 0, .bindings = &.{.{ .name = "NAME", .value = "value" }} },
        .{ .entry_module = 1 },
        .{ .entry_module = 0 },
    };
    const pack = try module_pack.buildAlloc(std.testing.allocator, &modules, &routes);
    defer std.testing.allocator.free(pack);
    const parsed = try module_pack.parse(pack);
    try module_pack.validateDefinition(parsed);

    try std.testing.expectEqual(@as(u32, modules.len), parsed.header.module_count);
    try std.testing.expectEqual(@as(u32, routes.len), parsed.header.route_count);
    // The index stays at most half full.
    try std.testing.expect(std.math.isPowerOfTwo(parsed.header.index_capacity));
    try std.testing.expect(parsed.header.index_capacity >= 2 * modules.len);

    const expected_encodings = [_]Encoding{ .latin1, .utf16le, .latin1 };
    const expected_sources = [_][]const u8{ modules[0].source, utf16("export const s = '\u{03c0}';\n"), "" };
    for (modules, expected_encodings, expected_sources, 0..) |module, encoding, source, index| {
        const stored = parsed.moduleAt(index);
        try std.testing.expectEqualStrings(module.specifier, stored.specifier);
        try std.testing.expectEqual(encoding, stored.encoding);
        try std.testing.expectEqualSlices(u8, source, stored.source);
        try std.testing.expectEqual(@as(?usize, index), parsed.findIndex(module.specifier));
    }
    try std.testing.expect(parsed.findModule("/var/task/missing.js") == null);

    try std.testing.expectEqual(routes.len, parsed.routes.len);
    for (routes, 0..) |route, index| {
        const stored = parsed.routeAt(index);
        try std.testing.expectEqual(route.entry_module, stored.entry_module);
        try std.testing.expectEqualStrings(modules[route.entry_module].specifier, stored.entry_specifier);
        var entries: route_bindings.Entries = undefined;
        const bindings = try route_bindings.decode(stored.bindings, &entries);
        try std.testing.expectEqual(route.bindings.len, bindings.len);
    }
    var entries: route_bindings.Entries = undefined;
    const first = try route_bindings.decode(parsed.routeAt(0).bindings, &entries);
    try std.testing.expectEqualStrings("NAME", first[0].name);
    try std.testing.expectEqualStrings("value", first[0].value);
}

test "a pack without routes, as the warmup's, parses but is no worker definition" {
    const pack = try module_pack.buildSingleAlloc(std.testing.allocator, "/var/task/a.js", "export {};\n");
    defer std.testing.allocator.free(pack);
    const parsed = try module_pack.parse(pack);
    try std.testing.expectEqual(@as(usize, 0), parsed.routes.len);
    try std.testing.expectError(error.InvalidModulePack, module_pack.validateDefinition(parsed));
}

test "text whose code points all fit a byte is stored as Latin-1" {
    try expectStored("export default 1;\n", .latin1, "export default 1;\n");
    try expectStored("caf\xc3\xa9", .latin1, "caf\xe9");
    // U+00FF is the last code point Latin-1 holds.
    try expectStored("\xc3\xbf", .latin1, "\xff");
    try expectStored("", .latin1, "");
}

test "text with a code point above U+00FF is stored as UTF-16LE, an astral one as a surrogate pair" {
    try expectStored("\xc4\x80", .utf16le, "\x00\x01");
    try expectStored("a\xcf\x80", .utf16le, utf16("a\u{03c0}"));
    // U+1F600 is the surrogate pair 0xD83D 0xDE00.
    try expectStored("\xf0\x9f\x98\x80", .utf16le, "\x3d\xd8\x00\xde");
    // Latin-1 characters beside it take two bytes as well.
    try expectStored("caf\xc3\xa9 \xcf\x80", .utf16le, utf16("caf\u{e9} \u{03c0}"));
}

test "a leading byte order mark is dropped and any other one kept" {
    try expectStored("\xef\xbb\xbfexport default 1;", .latin1, "export default 1;");
    try expectStored("\xef\xbb\xbf", .latin1, "");
    try expectStored("\xef\xbb\xbf\xcf\x80", .utf16le, utf16("\u{03c0}"));
    try expectStored("a\xef\xbb\xbf", .utf16le, utf16("a\u{feff}"));
}

test "each maximal invalid UTF-8 subsequence becomes one U+FFFD" {
    // 0xF0 must be followed by 0x90..0xBF, so 0xF0 0x80 is two ill-formed bytes.
    try expectStored("a\xf0\x80b", .utf16le, utf16("a\u{fffd}\u{fffd}b"));
    // ED A0 80 would encode a surrogate.
    try expectStored("\xed\xa0\x80", .utf16le, utf16("\u{fffd}\u{fffd}\u{fffd}"));
    // A sequence cut short by the end of the input is one subsequence.
    try expectStored("x\xe2\x82", .utf16le, utf16("x\u{fffd}"));
    // The byte that cuts a sequence short starts the next read.
    try expectStored("\xe2\x82a", .utf16le, utf16("\u{fffd}a"));
    // C0 AF is an overlong '/'; F4 90 80 80 lies above U+10FFFF.
    try expectStored("\xc0\xaf", .utf16le, utf16("\u{fffd}\u{fffd}"));
    try expectStored("\xf4\x90\x80\x80", .utf16le, utf16("\u{fffd}\u{fffd}\u{fffd}\u{fffd}"));
    try expectStored("\xff", .utf16le, utf16("\u{fffd}"));
    try expectStored("\x80", .utf16le, utf16("\u{fffd}"));
}

test "a UTF-16 source starts at an even offset after an odd-length Latin-1 one" {
    var padded: usize = 0;
    // One of the two specifier lengths leaves the Latin-1 source ending at
    // an odd offset, whatever the rest of the layout adds up to.
    for ([_][]const u8{ "/x.js", "/xy.js" }) |latin_specifier| {
        const modules = [_]module_pack.Module{
            .{ .specifier = latin_specifier, .source = "abc" },
            .{ .specifier = "/w.js", .source = "\xcf\x80" },
        };
        const pack = try module_pack.buildAlloc(std.testing.allocator, &modules, &.{});
        defer std.testing.allocator.free(pack);
        const parsed = try module_pack.parse(pack);
        const latin = parsed.records[0];
        const wide = parsed.records[1];
        try std.testing.expectEqual(@as(u32, 0), wide.source_offset % 2);
        if (wide.source_offset != latin.source_offset + latin.source_len)
            padded += 1;
        try std.testing.expectEqualSlices(u8, utf16("\u{03c0}"), parsed.moduleAt(1).source);
    }
    try std.testing.expectEqual(@as(usize, 1), padded);
}

test "the builder refuses modules and routes parse would refuse" {
    const one = [_]module_pack.Module{.{ .specifier = "/a.js", .source = "x" }};
    try std.testing.expectError(error.InvalidModulePack, module_pack.buildAlloc(std.testing.allocator, &.{}, &.{}));
    for ([_][]const u8{ "", "relative.js", "/a/../b.js", "/a b.js", "/a//b.js", "/a.js?x" }) |specifier| {
        try std.testing.expectError(
            error.InvalidModulePack,
            module_pack.buildAlloc(std.testing.allocator, &.{.{ .specifier = specifier, .source = "x" }}, &.{}),
        );
    }
    try std.testing.expectError(error.InvalidModulePack, module_pack.buildAlloc(std.testing.allocator, &.{
        .{ .specifier = "/a.js", .source = "x" },
        .{ .specifier = "/a.js", .source = "y" },
    }, &.{}));
    try std.testing.expectError(
        error.InvalidModulePack,
        module_pack.buildAlloc(std.testing.allocator, &one, &.{.{ .entry_module = 1 }}),
    );
    try std.testing.expectError(
        error.InvalidModulePack,
        module_pack.buildAlloc(std.testing.allocator, &one, &.{.{ .entry_module = 0, .bindings = &.{.{ .name = "1NAME", .value = "v" }} }}),
    );

    const too_many = try std.testing.allocator.alloc(module_pack.Module, module_pack.max_module_count + 1);
    defer std.testing.allocator.free(too_many);
    @memset(too_many, .{ .specifier = "/a.js", .source = "x" });
    try std.testing.expectError(error.InvalidModulePack, module_pack.buildAlloc(std.testing.allocator, too_many, &.{}));

    const huge = try std.testing.allocator.alloc(u8, module_pack.max_pack_bytes);
    defer std.testing.allocator.free(huge);
    @memset(huge, 'a');
    try std.testing.expectError(error.ModulePackTooLarge, module_pack.buildSingleAlloc(std.testing.allocator, "/a.js", huge));
}

/// A two-module pack, one Latin-1 and one UTF-16 source, with one route that
/// has a binding: the base every refusal below corrupts one field of.
fn buildBase() ![]u8 {
    return module_pack.buildAlloc(std.testing.allocator, &.{
        .{ .specifier = "/a.js", .source = "x" },
        .{ .specifier = "/b.js", .source = "\xcf\x80\xcf\x80" },
    }, &.{.{ .entry_module = 0, .bindings = &.{.{ .name = "NAME", .value = "v" }} }});
}

fn expectRefused(pack: []const u8) !void {
    try std.testing.expectError(error.InvalidModulePack, module_pack.parse(pack));
}

test "parse refuses a header the builder never writes" {
    const base = try buildBase();
    defer std.testing.allocator.free(base);
    _ = try module_pack.parse(base);
    const pack = try std.testing.allocator.dupe(u8, base);
    defer std.testing.allocator.free(pack);

    const sources_offset = readU32(base, header_sources_offset);
    const total_len = readU32(base, header_total_len);
    const cases = [_]struct { offset: usize, value: u32 }{
        .{ .offset = header_magic, .value = 0 },
        .{ .offset = header_module_count, .value = 0 },
        .{ .offset = header_module_count, .value = module_pack.max_module_count + 1 },
        // A capacity of 0 reached `std.math.isPowerOfTwo`, whose argument
        // must be nonzero, before the capacity was checked against the count.
        .{ .offset = header_index_capacity, .value = 0 },
        .{ .offset = header_index_capacity, .value = 3 },
        .{ .offset = header_index_capacity, .value = 1 },
        .{ .offset = header_route_count, .value = route_table.routes_max + 1 },
        // Route records that run into the specifiers.
        .{ .offset = header_route_count, .value = 50 },
        .{ .offset = header_specifiers_offset, .value = sources_offset + 1 },
        .{ .offset = header_sources_offset, .value = total_len + 1 },
        .{ .offset = header_total_len, .value = total_len + 1 },
    };
    for (cases) |case| {
        @memcpy(pack, base);
        writeU32(pack, case.offset, case.value);
        try expectRefused(pack);
    }

    // The version and flags are u16 fields.
    @memcpy(pack, base);
    std.mem.writeInt(u16, pack[header_version..][0..2], module_pack.version - 1, .little);
    try expectRefused(pack);
    @memcpy(pack, base);
    std.mem.writeInt(u16, pack[header_flags..][0..2], 1, .little);
    try expectRefused(pack);

    try expectRefused(base[0 .. @sizeOf(module_pack.Header) - 1]);
}

test "parse refuses a record outside its section, a misaligned UTF-16 source and an unknown flag" {
    const base = try buildBase();
    defer std.testing.allocator.free(base);
    const pack = try std.testing.allocator.dupe(u8, base);
    defer std.testing.allocator.free(pack);

    const latin = recordOffset(0);
    const wide = recordOffset(1);
    const sources_offset = readU32(base, header_sources_offset);
    const total_len = readU32(base, header_total_len);
    const wide_source_offset = readU32(base, wide + record_source_offset);
    const cases = [_]struct { offset: usize, value: u32 }{
        // A specifier inside the sources, and an empty one.
        .{ .offset = latin + record_specifier_offset, .value = sources_offset },
        .{ .offset = latin + record_specifier_len, .value = 0 },
        // A source past the end of the pack, and one that starts in the
        // specifiers.
        .{ .offset = latin + record_source_len, .value = total_len },
        .{ .offset = latin + record_source_offset, .value = sources_offset - 1 },
        // A UTF-16 source with an odd length, and one at an odd offset.
        .{ .offset = wide + record_source_len, .value = 3 },
        .{ .offset = wide + record_source_offset, .value = wide_source_offset + 1 },
        .{ .offset = latin + record_flags, .value = 2 },
    };
    for (cases) |case| {
        @memcpy(pack, base);
        writeU32(pack, case.offset, case.value);
        if (case.offset == wide + record_source_offset)
            writeU32(pack, wide + record_source_len, 2);
        try expectRefused(pack);
    }

    // A specifier that is not a path: "/a.js" becomes "aa.js".
    @memcpy(pack, base);
    pack[readU32(base, latin + record_specifier_offset)] = 'a';
    try expectRefused(pack);
}

test "parse refuses an index that does not find every module at its own position" {
    const base = try buildBase();
    defer std.testing.allocator.free(base);
    const pack = try std.testing.allocator.dupe(u8, base);
    defer std.testing.allocator.free(pack);
    const first_slot = try indexSlotOf(base, 0);
    const second_slot = try indexSlotOf(base, 1);

    // A stale hash.
    writeU32(pack, first_slot, readU32(base, first_slot) ^ 1);
    try expectRefused(pack);

    // An entry naming no module.
    @memcpy(pack, base);
    writeU32(pack, first_slot + 4, 2);
    try expectRefused(pack);

    // An empty slot with a hash.
    @memcpy(pack, base);
    const empty_slot = try indexSlotOf(base, module_pack.empty_index_module);
    writeU32(pack, empty_slot, 1);
    try expectRefused(pack);

    // A duplicate specifier: "/b.js" becomes "/a.js", and its index entry
    // carries the matching hash, so only the position check catches it.
    @memcpy(pack, base);
    pack[readU32(base, recordOffset(1) + record_specifier_offset) + 1] = 'a';
    writeU32(pack, second_slot, module_pack.hashSpecifier("/a.js"));
    try expectRefused(pack);
}

test "parse refuses a route whose entry names no module or whose bindings are invalid" {
    const base = try buildBase();
    defer std.testing.allocator.free(base);
    const pack = try std.testing.allocator.dupe(u8, base);
    defer std.testing.allocator.free(pack);
    const route = routeRecordOffset(base, 0);

    writeU32(pack, route + route_entry_module, 2);
    try expectRefused(pack);

    // The binding's name, "NAME", becomes "1AME".
    @memcpy(pack, base);
    pack[readU32(base, route + route_bindings_offset) + 2 * @sizeOf(u32)] = '1';
    try expectRefused(pack);

    // Bindings that start inside the route records.
    @memcpy(pack, base);
    writeU32(pack, route + route_bindings_offset, @intCast(route));
    try expectRefused(pack);
}

test "parse refuses a pack over the size bound before reading it" {
    const oversized = try std.testing.allocator.alloc(u8, module_pack.max_pack_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 0);
    try std.testing.expectError(error.ModulePackTooLarge, module_pack.parse(oversized));
}

test "a worker definition has a route and keys every module under the task root" {
    const cases = [_]struct { specifier: []const u8, valid: bool }{
        .{ .specifier = "/var/task/a.js", .valid = true },
        .{ .specifier = "/var/task/lib/deep/a.js", .valid = true },
        .{ .specifier = "/srv/a.js", .valid = false },
        .{ .specifier = "/var/taskx/a.js", .valid = false },
        .{ .specifier = "/var/task", .valid = false },
        .{ .specifier = "/__collo/zygote/warmup.js", .valid = false },
    };
    for (cases) |case| {
        const pack = try module_pack.buildSingleRouteAlloc(std.testing.allocator, case.specifier, "export {};\n");
        defer std.testing.allocator.free(pack);
        const parsed = try module_pack.parse(pack);
        if (case.valid) {
            try module_pack.validateDefinition(parsed);
        } else {
            try std.testing.expectError(error.InvalidModulePack, module_pack.validateDefinition(parsed));
        }
    }
}
