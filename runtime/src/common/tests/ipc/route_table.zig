//! The routes section of a definition artifact (`common/ipc/route_table.zig`):
//! the checks on routes about to be written, the records and bindings
//! sections `write` lays out, and `validate` re-checking every rule on bytes
//! the writer would refuse. Sections are laid out here at offset 0 of a
//! buffer, records first, as `module_pack.buildAlloc` lays them out after the
//! index; the section inside a whole artifact is covered by `module_pack.zig`,
//! and the worker serving the routes by `worker/tests/runtime/routes.zig`.

const std = @import("std");
const ipc = @import("collo_ipc");

const route_table = ipc.route_table;
const route_bindings = ipc.route_bindings;
const RouteRecord = route_table.RouteRecord;

/// A routes section for `routes`, written at offset 0 of a buffer the caller
/// frees, for a pack of `module_count` modules.
const Section = struct {
    bytes: []u8,
    route_count: usize,

    fn init(routes: []const route_table.RouteInput, module_count: usize) !Section {
        const bindings_len = try route_table.validateInputs(routes, module_count);
        const records_len = routes.len * @sizeOf(RouteRecord);
        const bytes = try std.testing.allocator.alloc(u8, records_len + bindings_len);
        errdefer std.testing.allocator.free(bytes);
        @memset(bytes, 0);
        const end = route_table.write(bytes, 0, records_len, routes);
        try std.testing.expectEqual(bytes.len, end);
        return .{ .bytes = bytes, .route_count = routes.len };
    }

    fn deinit(self: Section) void {
        std.testing.allocator.free(self.bytes);
    }

    fn recordsEnd(self: Section) usize {
        return self.route_count * @sizeOf(RouteRecord);
    }

    fn records(self: Section) []align(1) const RouteRecord {
        return std.mem.bytesAsSlice(RouteRecord, self.bytes[0..self.recordsEnd()]);
    }

    fn validate(self: Section, module_count: usize) route_table.Error!void {
        return route_table.validate(self.bytes, self.records(), self.recordsEnd(), self.bytes.len, module_count);
    }

    fn setField(self: Section, route_index: usize, field_offset: usize, value: u32) void {
        const at = route_index * @sizeOf(RouteRecord) + field_offset;
        std.mem.writeInt(u32, self.bytes[at..][0..4], value, .little);
    }
};

const record_entry_module = 0;
const record_bindings_offset = 4;
const record_bindings_len = 8;

test "written routes validate and keep their entries and bindings in order" {
    const routes = [_]route_table.RouteInput{
        .{ .entry_module = 1, .bindings = &.{
            .{ .name = "SECRET", .value = "s3cr3t" },
            .{ .name = "GREETING", .value = "olá" },
        } },
        .{ .entry_module = 0 },
        // Two routes may share an entry, each with bindings of its own.
        .{ .entry_module = 1, .bindings = &.{.{ .name = "SECRET", .value = "other" }} },
    };
    const section = try Section.init(&routes, 2);
    defer section.deinit();
    try section.validate(2);

    for (routes, section.records()) |expected, record| {
        try std.testing.expectEqual(expected.entry_module, record.entry_module);
        // Every bindings section lies after the records.
        try std.testing.expect(record.bindings_offset >= section.recordsEnd());
        const bytes = section.bytes[record.bindings_offset..][0..record.bindings_len];
        var entries: route_bindings.Entries = undefined;
        const bindings = try route_bindings.decode(bytes, &entries);
        try std.testing.expectEqual(expected.bindings.len, bindings.len);
        for (expected.bindings, bindings) |expected_binding, binding| {
            try std.testing.expectEqualStrings(expected_binding.name, binding.name);
            try std.testing.expectEqualStrings(expected_binding.value, binding.value);
        }
    }
}

test "a route without bindings carries the empty bindings section" {
    const section = try Section.init(&.{.{ .entry_module = 0 }}, 1);
    defer section.deinit();
    const record = section.records()[0];
    try std.testing.expectEqualSlices(
        u8,
        &route_bindings.empty_blob,
        section.bytes[record.bindings_offset..][0..record.bindings_len],
    );
}

test "a section holds every route a definition may declare" {
    var routes: [route_table.routes_max]route_table.RouteInput = undefined;
    for (&routes, 0..) |*route, index|
        route.* = .{ .entry_module = @intCast(index), .bindings = &.{.{ .name = "INDEX", .value = "v" }} };
    const section = try Section.init(&routes, routes.len);
    defer section.deinit();
    try section.validate(routes.len);
    try std.testing.expectEqual(@as(u32, route_table.routes_max - 1), section.records()[routes.len - 1].entry_module);
}

test "validateInputs counts the bindings bytes and refuses routes a worker would refuse" {
    const one = [_]route_table.RouteInput{.{ .entry_module = 0, .bindings = &.{.{ .name = "A", .value = "b" }} }};
    try std.testing.expectEqual(
        try route_bindings.encodedLen(one[0].bindings),
        try route_table.validateInputs(&one, 1),
    );
    try std.testing.expectEqual(@as(usize, 0), try route_table.validateInputs(&.{}, 1));

    var too_many: [route_table.routes_max + 1]route_table.RouteInput = undefined;
    for (&too_many) |*route|
        route.* = .{ .entry_module = 0 };
    const cases = [_][]const route_table.RouteInput{
        &too_many,
        // The entry names no module of the pack.
        &.{.{ .entry_module = 1 }},
        &.{.{ .entry_module = 0, .bindings = &.{.{ .name = "1NAME", .value = "v" }} }},
        &.{.{ .entry_module = 0, .bindings = &.{
            .{ .name = "TWICE", .value = "a" },
            .{ .name = "TWICE", .value = "b" },
        } }},
        &.{.{ .entry_module = 0, .bindings = &.{.{ .name = "BYTES", .value = "\xff\xfe" }} }},
    };
    for (cases) |routes|
        try std.testing.expectError(error.InvalidRouteTable, route_table.validateInputs(routes, 1));
}

test "validate refuses a record that names no module or bindings outside the section" {
    const routes = [_]route_table.RouteInput{
        .{ .entry_module = 0, .bindings = &.{.{ .name = "NAME", .value = "value" }} },
        .{ .entry_module = 1 },
    };

    {
        const section = try Section.init(&routes, 2);
        defer section.deinit();
        section.setField(1, record_entry_module, 2);
        try std.testing.expectError(error.InvalidRouteTable, section.validate(2));
    }
    {
        // Bindings that start inside the records.
        const section = try Section.init(&routes, 2);
        defer section.deinit();
        section.setField(0, record_bindings_offset, 0);
        try std.testing.expectError(error.InvalidRouteTable, section.validate(2));
    }
    {
        // Bindings that start past the end of the section.
        const section = try Section.init(&routes, 2);
        defer section.deinit();
        section.setField(1, record_bindings_offset, @intCast(section.bytes.len + 1));
        try std.testing.expectError(error.InvalidRouteTable, section.validate(2));
    }
    {
        // Bindings that run past the end of the section.
        const section = try Section.init(&routes, 2);
        defer section.deinit();
        const record = section.records()[1];
        section.setField(1, record_bindings_len, record.bindings_len + 1);
        try std.testing.expectError(error.InvalidRouteTable, section.validate(2));
    }
}

test "validate refuses bindings a worker would refuse and more than routes_max records" {
    {
        // The first name, "NAME", becomes "1AME", outside the grammar.
        const section = try Section.init(&.{.{ .entry_module = 0, .bindings = &.{.{ .name = "NAME", .value = "v" }} }}, 1);
        defer section.deinit();
        const record = section.records()[0];
        section.bytes[record.bindings_offset + 2 * @sizeOf(u32)] = '1';
        try std.testing.expectError(error.InvalidRouteTable, section.validate(1));
    }
    {
        // A bindings section cut one byte short.
        const section = try Section.init(&.{.{ .entry_module = 0, .bindings = &.{.{ .name = "NAME", .value = "v" }} }}, 1);
        defer section.deinit();
        const record = section.records()[0];
        section.setField(0, record_bindings_len, record.bindings_len - 1);
        try std.testing.expectError(error.InvalidRouteTable, section.validate(1));
    }

    var bytes: [(route_table.routes_max + 1) * @sizeOf(RouteRecord)]u8 = @splat(0);
    const records: []align(1) const RouteRecord = std.mem.bytesAsSlice(RouteRecord, bytes[0..]);
    try std.testing.expectError(
        error.InvalidRouteTable,
        route_table.validate(&bytes, records, bytes.len, bytes.len, 1),
    );
}
