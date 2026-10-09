//! The module pack, the immutable file that carries ES modules to a worker:
//! the sources, optional bytecode and static dependencies of a set of
//! modules, one of them the entry, with an index from specifier to module.
//! Packs are built with `buildAlloc`, and the host seals them into memfds
//! (`host/dispatch.zig`); a worker maps one read-only, checks it with
//! `parse` and registers the mapping with the engine, whose loader
//! (`bindings/jsc/runtime/module_loader.cpp`) reads it in place. Everything
//! here is a pure function of its arguments, callable from any thread.
//!
//! Layout, in this order and without gaps: the header, the module records,
//! the dependency records, the index, then the specifier bytes (each
//! module's specifier followed by its dependencies' specifiers), the sources
//! and the bytecode. Offsets count bytes from the start of the pack, except
//! a record's `dependency_offset`, which counts dependency records.
//! Integers are little-endian: the header is read field by field, while
//! records and index entries are read in place as extern structs, which is
//! correct only on a little-endian host, as x86_64 and ARM64 both are. The
//! index is open addressing with linear probing over a power-of-two
//! capacity, keyed by `hashSpecifier`; an empty slot holds
//! `empty_index_module` and hash 0.
//!
//! `parse` accepts a pack only when every offset lies inside its own
//! section, every specifier passes `validateSpecifier` and matches its
//! stored hash, the index finds every module at its own position, so no
//! specifier repeats, and every dependency names a module of the pack. A
//! parsed pack is then read without further checks. The engine's loader
//! keeps its own copies of `magic`, `version`, `max_module_count`,
//! `empty_index_module`, `route_specifier_prefix`, the struct sizes and
//! `hashSpecifier`, so a change to any of them edits the loader too.
//! `runtime/tests/contracts/module_pack.zig` pins the bytes `buildAlloc`
//! writes, so a layout change edits that test as well.

const std = @import("std");

pub const magic: u32 = 0x4d4f4c43; // "CLOM" little-endian.
/// The only version `parse` accepts.
pub const version: u16 = 2;
/// Most modules one pack holds; the server refuses a route whose import
/// graph holds more (`Graph.read` in `server/routes/module_graph.zig`).
pub const max_module_count: usize = 4096;
/// Largest pack `buildAlloc` writes and `parse` accepts.
/// `COLLO_MODULE_PACK_MAX_BYTES` in `bindings/include/collo/abi.h` repeats
/// it by hand.
pub const max_pack_bytes: usize = 16 * 1024 * 1024;
/// Prefix of every module key in a definition's pack: the server keys each
/// module `<prefix><worker>/<path>` (`moduleKey` in
/// `server/routes/artifacts.zig`), and `<worker>` is the scope segment
/// `deployHashFromSpecifier` returns.
pub const route_specifier_prefix = "/__collo_route/";

/// `module_index` of an empty index slot, whose hash is 0.
pub const empty_index_module: u32 = std.math.maxInt(u32);

/// Read and written field by field (`readHeader`, `writeHeader`), and
/// `@sizeOf(Header)` is the header's length in the pack, so a new field
/// changes the format.
pub const Header = extern struct {
    magic: u32,
    version: u16,
    flags: u16,
    module_count: u32,
    entry_index: u32,
    records_offset: u32,
    dependencies_offset: u32,
    dependency_count: u32,
    index_offset: u32,
    index_capacity: u32,
    specifiers_offset: u32,
    sources_offset: u32,
    bytecode_offset: u32,
    total_len: u32,
    reserved0: u32,
    reserved1: u32,
};

/// One module. `flags` and the reserved fields are zero, and a zero
/// `bytecode_len` means the module has no bytecode.
pub const ModuleRecord = extern struct {
    specifier_offset: u32,
    specifier_len: u32,
    source_offset: u32,
    source_len: u32,
    dependency_offset: u32,
    dependency_count: u32,
    bytecode_offset: u32,
    bytecode_len: u32,
    specifier_hash: u32,
    flags: u32,
    reserved0: u32,
    reserved1: u32,
};

/// One static import of a module, by specifier, which must name a module of
/// the same pack.
pub const DependencyRecord = extern struct {
    specifier_offset: u32,
    specifier_len: u32,
    specifier_hash: u32,
    reserved0: u32,
};

pub const IndexEntry = extern struct {
    specifier_hash: u32,
    module_index: u32,
};

pub const Dependency = struct {
    specifier: []const u8,
};

/// One module as `buildAlloc` takes it. `flags` must be zero.
pub const Module = struct {
    specifier: []const u8,
    source: []const u8,
    dependencies: []const Dependency = &.{},
    bytecode: []const u8 = "",
    flags: u32 = 0,
};

/// A module of a parsed pack, borrowing the pack's bytes; `bytecode` is
/// empty when the module has none.
pub const ParsedModule = struct {
    specifier: []const u8,
    source: []const u8,
    bytecode: []const u8,
    dependency_count: usize,
    flags: u32 = 0,
};

/// A pack that passed `parse`, borrowing its bytes for its whole life.
pub const Parsed = struct {
    bytes: []const u8,
    header: Header,
    records: []align(1) const ModuleRecord,
    dependencies: []align(1) const DependencyRecord,
    index: []align(1) const IndexEntry,

    pub fn entrySpecifier(self: Parsed) []const u8 {
        return self.moduleAt(self.header.entry_index).specifier;
    }

    pub fn moduleAt(self: Parsed, index: usize) ParsedModule {
        std.debug.assert(index < self.records.len);
        const record = self.records[index];
        const specifier_offset: usize = @intCast(record.specifier_offset);
        const specifier_len: usize = @intCast(record.specifier_len);
        const source_offset: usize = @intCast(record.source_offset);
        const source_len: usize = @intCast(record.source_len);
        const bytecode_offset: usize = @intCast(record.bytecode_offset);
        const bytecode_len: usize = @intCast(record.bytecode_len);
        return .{
            .specifier = self.bytes[specifier_offset..][0..specifier_len],
            .source = self.bytes[source_offset..][0..source_len],
            .bytecode = if (bytecode_len == 0) "" else self.bytes[bytecode_offset..][0..bytecode_len],
            .dependency_count = @intCast(record.dependency_count),
            .flags = record.flags,
        };
    }

    pub fn dependencyAt(self: Parsed, module_index: usize, dependency_index: usize) Dependency {
        std.debug.assert(module_index < self.records.len);
        const record = self.records[module_index];
        std.debug.assert(dependency_index < @as(usize, @intCast(record.dependency_count)));
        const dependency_offset: usize = @intCast(record.dependency_offset);
        const dependency = self.dependencies[dependency_offset + dependency_index];
        return .{
            .specifier = self.bytes[@as(usize, @intCast(dependency.specifier_offset))..][0..@as(usize, @intCast(dependency.specifier_len))],
        };
    }

    /// The position of the module named `specifier`, or null. The probe
    /// visits at most the index's capacity, so a full index still ends it.
    pub fn findIndex(self: Parsed, specifier: []const u8) ?usize {
        if (self.index.len == 0)
            return null;
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

pub fn containsSpecifier(parsed: Parsed, specifier: []const u8) bool {
    return parsed.findIndex(specifier) != null;
}

/// A pack holding one module with no dependencies, as `buildAlloc` builds it.
pub fn buildSingleAlloc(allocator: std.mem.Allocator, entry_specifier: []const u8, source: []const u8) ![]u8 {
    return buildAlloc(allocator, &.{.{ .specifier = entry_specifier, .source = source }}, 0);
}

/// Serializes `modules`, with `modules[entry_index]` as the entry, into a
/// pack the caller owns and frees. Fails with `error.InvalidModulePack` for
/// input `parse` would refuse: no modules or more than `max_module_count`,
/// an entry index out of range, an empty source, nonzero flags, an invalid
/// or repeated specifier, or a dependency that names no module of the list.
/// Fails with `error.ModulePackTooLarge` above `max_pack_bytes`.
pub fn buildAlloc(allocator: std.mem.Allocator, modules: []const Module, entry_index: usize) ![]u8 {
    validateModuleList(modules, entry_index) catch return error.InvalidModulePack;

    var specifiers_len: usize = 0;
    var sources_len: usize = 0;
    var bytecode_len: usize = 0;
    var dependency_count: usize = 0;
    for (modules) |module| {
        specifiers_len = try addChecked(specifiers_len, module.specifier.len);
        sources_len = try addChecked(sources_len, module.source.len);
        bytecode_len = try addChecked(bytecode_len, module.bytecode.len);
        dependency_count = try addChecked(dependency_count, module.dependencies.len);
        for (module.dependencies) |dependency|
            specifiers_len = try addChecked(specifiers_len, dependency.specifier.len);
    }

    const records_offset = @sizeOf(Header);
    const records_len = try std.math.mul(usize, modules.len, @sizeOf(ModuleRecord));
    const dependencies_offset = try addChecked(records_offset, records_len);
    const dependencies_len = try std.math.mul(usize, dependency_count, @sizeOf(DependencyRecord));
    const index_offset = try addChecked(dependencies_offset, dependencies_len);
    const index_capacity = try indexCapacity(modules.len);
    const index_len = try std.math.mul(usize, index_capacity, @sizeOf(IndexEntry));
    const specifiers_offset = try addChecked(index_offset, index_len);
    const sources_offset = try addChecked(specifiers_offset, specifiers_len);
    const bytecode_offset = try addChecked(sources_offset, sources_len);
    const total_len = try addChecked(bytecode_offset, bytecode_len);
    if (total_len > max_pack_bytes)
        return error.ModulePackTooLarge;

    const bytes = try allocator.alloc(u8, total_len);
    errdefer allocator.free(bytes);
    @memset(bytes, 0);

    const header = Header{
        .magic = magic,
        .version = version,
        .flags = 0,
        .module_count = @intCast(modules.len),
        .entry_index = @intCast(entry_index),
        .records_offset = @intCast(records_offset),
        .dependencies_offset = @intCast(dependencies_offset),
        .dependency_count = @intCast(dependency_count),
        .index_offset = @intCast(index_offset),
        .index_capacity = @intCast(index_capacity),
        .specifiers_offset = @intCast(specifiers_offset),
        .sources_offset = @intCast(sources_offset),
        .bytecode_offset = @intCast(bytecode_offset),
        .total_len = @intCast(total_len),
        .reserved0 = 0,
        .reserved1 = 0,
    };
    writeHeader(bytes[0..@sizeOf(Header)], header);

    const index_entries: []align(1) IndexEntry = std.mem.bytesAsSlice(IndexEntry, bytes[index_offset..specifiers_offset]);
    for (index_entries) |*entry| {
        entry.* = .{
            .specifier_hash = 0,
            .module_index = empty_index_module,
        };
    }

    var specifier_cursor = specifiers_offset;
    var source_cursor = sources_offset;
    var bytecode_cursor = bytecode_offset;
    var dependency_cursor: usize = 0;
    for (modules, 0..) |module, index| {
        const record_offset = records_offset + index * @sizeOf(ModuleRecord);
        const specifier_hash = hashSpecifier(module.specifier);
        const record = ModuleRecord{
            .specifier_offset = @intCast(specifier_cursor),
            .specifier_len = @intCast(module.specifier.len),
            .source_offset = @intCast(source_cursor),
            .source_len = @intCast(module.source.len),
            .dependency_offset = @intCast(dependency_cursor),
            .dependency_count = @intCast(module.dependencies.len),
            .bytecode_offset = @intCast(bytecode_cursor),
            .bytecode_len = @intCast(module.bytecode.len),
            .specifier_hash = specifier_hash,
            .flags = module.flags,
            .reserved0 = 0,
            .reserved1 = 0,
        };
        writeRecord(bytes[record_offset..][0..@sizeOf(ModuleRecord)], record);
        @memcpy(bytes[specifier_cursor..][0..module.specifier.len], module.specifier);
        specifier_cursor += module.specifier.len;
        @memcpy(bytes[source_cursor..][0..module.source.len], module.source);
        source_cursor += module.source.len;
        if (module.bytecode.len != 0) {
            @memcpy(bytes[bytecode_cursor..][0..module.bytecode.len], module.bytecode);
            bytecode_cursor += module.bytecode.len;
        }
        for (module.dependencies) |dependency| {
            const dependency_record_offset = dependencies_offset + dependency_cursor * @sizeOf(DependencyRecord);
            const dependency_record = DependencyRecord{
                .specifier_offset = @intCast(specifier_cursor),
                .specifier_len = @intCast(dependency.specifier.len),
                .specifier_hash = hashSpecifier(dependency.specifier),
                .reserved0 = 0,
            };
            writeDependencyRecord(bytes[dependency_record_offset..][0..@sizeOf(DependencyRecord)], dependency_record);
            @memcpy(bytes[specifier_cursor..][0..dependency.specifier.len], dependency.specifier);
            specifier_cursor += dependency.specifier.len;
            dependency_cursor += 1;
        }
        putIndexEntry(index_entries, specifier_hash, @intCast(index));
    }

    std.debug.assert(specifier_cursor == sources_offset);
    std.debug.assert(source_cursor == bytecode_offset);
    std.debug.assert(bytecode_cursor == total_len);
    std.debug.assert(dependency_cursor == dependency_count);
    return bytes;
}

/// Checks `bytes` against every rule in the file header and returns a view
/// that borrows them. Fails with `error.ModulePackTooLarge` above
/// `max_pack_bytes` and `error.InvalidModulePack` for any other violation.
pub fn parse(bytes: []const u8) !Parsed {
    if (bytes.len < @sizeOf(Header))
        return error.InvalidModulePack;
    if (bytes.len > max_pack_bytes)
        return error.ModulePackTooLarge;

    const header = readHeader(bytes[0..@sizeOf(Header)]);
    if (header.magic != magic or header.version != version)
        return error.InvalidModulePack;
    if (header.flags != 0 or header.reserved0 != 0 or header.reserved1 != 0)
        return error.InvalidModulePack;
    if (header.module_count == 0 or header.module_count > max_module_count)
        return error.InvalidModulePack;
    if (header.entry_index >= header.module_count)
        return error.InvalidModulePack;
    if (@as(usize, @intCast(header.total_len)) != bytes.len)
        return error.InvalidModulePack;
    if (header.records_offset != @sizeOf(Header))
        return error.InvalidModulePack;
    if (!std.math.isPowerOfTwo(header.index_capacity))
        return error.InvalidModulePack;
    if (header.index_capacity < header.module_count)
        return error.InvalidModulePack;

    const records_offset: usize = @intCast(header.records_offset);
    const dependencies_offset: usize = @intCast(header.dependencies_offset);
    const index_offset: usize = @intCast(header.index_offset);
    const specifiers_offset: usize = @intCast(header.specifiers_offset);
    const sources_offset: usize = @intCast(header.sources_offset);
    const bytecode_offset: usize = @intCast(header.bytecode_offset);
    const total_len: usize = @intCast(header.total_len);
    const module_count: usize = @intCast(header.module_count);
    const dependency_count: usize = @intCast(header.dependency_count);
    const header_index_capacity: usize = @intCast(header.index_capacity);

    const records_len = try std.math.mul(usize, module_count, @sizeOf(ModuleRecord));
    const records_end = try std.math.add(usize, records_offset, records_len);
    const dependencies_len = try std.math.mul(usize, dependency_count, @sizeOf(DependencyRecord));
    const dependencies_end = try std.math.add(usize, dependencies_offset, dependencies_len);
    const index_len = try std.math.mul(usize, header_index_capacity, @sizeOf(IndexEntry));
    const index_end = try std.math.add(usize, index_offset, index_len);
    if (records_end != dependencies_offset)
        return error.InvalidModulePack;
    if (dependencies_end != index_offset)
        return error.InvalidModulePack;
    if (index_end != specifiers_offset)
        return error.InvalidModulePack;
    if (specifiers_offset > sources_offset or sources_offset > bytecode_offset or bytecode_offset > total_len)
        return error.InvalidModulePack;

    const records_bytes = bytes[records_offset..records_end];
    const records: []align(1) const ModuleRecord = std.mem.bytesAsSlice(ModuleRecord, records_bytes);
    const dependencies_bytes = bytes[dependencies_offset..dependencies_end];
    const dependencies: []align(1) const DependencyRecord = std.mem.bytesAsSlice(DependencyRecord, dependencies_bytes);
    const index_bytes = bytes[index_offset..index_end];
    const index: []align(1) const IndexEntry = std.mem.bytesAsSlice(IndexEntry, index_bytes);
    for (records) |record| {
        if (record.reserved0 != 0 or record.reserved1 != 0 or record.specifier_len == 0 or record.source_len == 0)
            return error.InvalidModulePack;
        if (record.flags != 0)
            return error.InvalidModulePack;
        try validateRange(bytes.len, record.specifier_offset, record.specifier_len);
        try validateRange(bytes.len, record.source_offset, record.source_len);
        try validateRange(bytes.len, record.bytecode_offset, record.bytecode_len);
        const record_specifier_offset: usize = @intCast(record.specifier_offset);
        const record_specifier_len: usize = @intCast(record.specifier_len);
        const record_source_offset: usize = @intCast(record.source_offset);
        const record_source_len: usize = @intCast(record.source_len);
        const record_bytecode_offset: usize = @intCast(record.bytecode_offset);
        const record_bytecode_len: usize = @intCast(record.bytecode_len);
        if (record_specifier_offset < specifiers_offset or record_specifier_offset + record_specifier_len > sources_offset)
            return error.InvalidModulePack;
        if (record_source_offset < sources_offset or record_source_offset + record_source_len > bytecode_offset)
            return error.InvalidModulePack;
        if (record_bytecode_offset < bytecode_offset or record_bytecode_offset + record_bytecode_len > total_len)
            return error.InvalidModulePack;
        const dependency_end = try std.math.add(usize, @as(usize, @intCast(record.dependency_offset)), @as(usize, @intCast(record.dependency_count)));
        if (dependency_end > dependencies.len)
            return error.InvalidModulePack;

        const specifier = sliceRecordSpecifier(bytes, record);
        if (record.specifier_hash != hashSpecifier(specifier))
            return error.InvalidModulePack;
        validateSpecifier(specifier) catch return error.InvalidModulePack;
    }

    for (dependencies) |dependency| {
        if (dependency.reserved0 != 0 or dependency.specifier_len == 0)
            return error.InvalidModulePack;
        try validateRange(bytes.len, dependency.specifier_offset, dependency.specifier_len);
        const dependency_specifier_offset: usize = @intCast(dependency.specifier_offset);
        const dependency_specifier_len: usize = @intCast(dependency.specifier_len);
        if (dependency_specifier_offset < specifiers_offset or dependency_specifier_offset + dependency_specifier_len > sources_offset)
            return error.InvalidModulePack;
        const specifier = sliceDependencySpecifier(bytes, dependency);
        if (dependency.specifier_hash != hashSpecifier(specifier))
            return error.InvalidModulePack;
        validateSpecifier(specifier) catch return error.InvalidModulePack;
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
        if (entry.specifier_hash != record.specifier_hash)
            return error.InvalidModulePack;
        live_index_entries += 1;
    }
    if (live_index_entries != records.len)
        return error.InvalidModulePack;

    const parsed = Parsed{
        .bytes = bytes,
        .header = header,
        .records = records,
        .dependencies = dependencies,
        .index = index,
    };
    for (records, 0..) |record, expected_index| {
        const specifier = sliceRecordSpecifier(bytes, record);
        if (parsed.findIndex(specifier) != expected_index)
            return error.InvalidModulePack;
    }
    for (dependencies) |dependency| {
        const specifier = sliceDependencySpecifier(bytes, dependency);
        if (parsed.findIndex(specifier) == null)
            return error.InvalidModulePack;
    }

    return parsed;
}

fn validateModuleList(modules: []const Module, entry_index: usize) !void {
    if (modules.len == 0 or modules.len > max_module_count)
        return error.InvalidModulePack;
    if (entry_index >= modules.len)
        return error.InvalidModulePack;
    for (modules, 0..) |module, index| {
        if (module.source.len == 0)
            return error.InvalidModulePack;
        try validateSpecifier(module.specifier);
        if (module.flags != 0)
            return error.InvalidModulePack;
        for (module.dependencies) |dependency| {
            try validateSpecifier(dependency.specifier);
            var found = false;
            for (modules) |candidate| {
                if (std.mem.eql(u8, candidate.specifier, dependency.specifier)) {
                    found = true;
                    break;
                }
            }
            if (!found)
                return error.InvalidModulePack;
        }
        for (modules[0..index]) |previous| {
            if (std.mem.eql(u8, previous.specifier, module.specifier))
                return error.InvalidModulePack;
        }
    }
}

/// The rules every module and dependency specifier follows: it starts with
/// '/', holds no NUL, CR, LF, tab, space, backslash, '?' or '#', and has no
/// empty, `.` or `..` segment. `buildAlloc`, `parse` and the server's key
/// builder (`server/routes/artifacts.zig`) all apply them.
pub fn validateSpecifier(specifier: []const u8) !void {
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

/// Checks that `specifier` is valid, carries `route_specifier_prefix`, has
/// `hash_deploy` as its scope segment (`deployHashFromSpecifier`) and names
/// something below it.
pub fn validateDeployScopedSpecifier(hash_deploy: []const u8, specifier: []const u8) !void {
    try validateSpecifier(specifier);
    if (!std.mem.startsWith(u8, specifier, route_specifier_prefix))
        return error.InvalidModuleSpecifier;
    const rest = specifier[route_specifier_prefix.len..];
    const slash_index = std.mem.indexOfScalar(u8, rest, '/') orelse return error.InvalidModuleSpecifier;
    if (!std.mem.eql(u8, rest[0..slash_index], hash_deploy))
        return error.InvalidModuleSpecifier;
    if (rest[slash_index + 1 ..].len == 0)
        return error.InvalidModuleSpecifier;
}

/// Checks that every module of `parsed` lies in the scope `hash_deploy`.
pub fn validateDeployScopedPack(parsed: Parsed, hash_deploy: []const u8) !void {
    for (0..parsed.records.len) |index|
        try validateDeployScopedSpecifier(hash_deploy, parsed.moduleAt(index).specifier);
}

/// Checks that every module of `parsed` shares the scope of
/// `anchor_specifier`, such as the route's entry.
pub fn validateSameDeployScopedPack(parsed: Parsed, anchor_specifier: []const u8) !void {
    const hash_deploy = deployHashFromSpecifier(anchor_specifier) orelse return error.InvalidModuleSpecifier;
    try validateDeployScopedPack(parsed, hash_deploy);
}

/// The scope segment of `specifier`: its first segment after
/// `route_specifier_prefix`, which the server sets to the name of the
/// route's definition (`moduleKey` in `server/routes/artifacts.zig`). Null
/// without the prefix, or when no nonempty segment followed by '/' comes
/// after it.
pub fn deployHashFromSpecifier(specifier: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, specifier, route_specifier_prefix))
        return null;
    const rest = specifier[route_specifier_prefix.len..];
    const slash_index = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    if (slash_index == 0)
        return null;
    return rest[0..slash_index];
}

fn sliceRecordSpecifier(bytes: []const u8, record: ModuleRecord) []const u8 {
    return bytes[@as(usize, @intCast(record.specifier_offset))..][0..@as(usize, @intCast(record.specifier_len))];
}

fn sliceDependencySpecifier(bytes: []const u8, record: DependencyRecord) []const u8 {
    return bytes[@as(usize, @intCast(record.specifier_offset))..][0..@as(usize, @intCast(record.specifier_len))];
}

/// Wyhash with seed 0, folded to 32 bits by xoring its halves.
/// `modulePackHashSpecifier` in `bindings/jsc/runtime/module_loader.cpp`
/// computes the same value.
pub fn hashSpecifier(specifier: []const u8) u32 {
    const hash = std.hash.Wyhash.hash(0, specifier);
    return @truncate(hash ^ (hash >> 32));
}

/// The smallest power of two at least twice `module_count`, which keeps the
/// index at most half full.
fn indexCapacity(module_count: usize) !usize {
    const target = std.math.mul(usize, module_count, 2) catch return error.ModulePackTooLarge;
    var capacity: usize = 1;
    while (capacity < target)
        capacity = std.math.mul(usize, capacity, 2) catch return error.ModulePackTooLarge;
    return capacity;
}

fn putIndexEntry(index: []align(1) IndexEntry, hash: u32, module_index: u32) void {
    var slot = @as(usize, hash) & (index.len - 1);
    while (index[slot].module_index != empty_index_module)
        slot = (slot + 1) & (index.len - 1);
    index[slot] = .{
        .specifier_hash = hash,
        .module_index = module_index,
    };
}

fn validateRange(total_len: usize, offset_raw: u32, len_raw: u32) !void {
    const offset: usize = @intCast(offset_raw);
    const len: usize = @intCast(len_raw);
    const end = try std.math.add(usize, offset, len);
    if (end > total_len)
        return error.InvalidModulePack;
}

fn addChecked(lhs: usize, rhs: usize) !usize {
    return std.math.add(usize, lhs, rhs) catch error.ModulePackTooLarge;
}

fn readHeader(bytes: []const u8) Header {
    return .{
        .magic = std.mem.readInt(u32, bytes[0..4], .little),
        .version = std.mem.readInt(u16, bytes[4..6], .little),
        .flags = std.mem.readInt(u16, bytes[6..8], .little),
        .module_count = std.mem.readInt(u32, bytes[8..12], .little),
        .entry_index = std.mem.readInt(u32, bytes[12..16], .little),
        .records_offset = std.mem.readInt(u32, bytes[16..20], .little),
        .dependencies_offset = std.mem.readInt(u32, bytes[20..24], .little),
        .dependency_count = std.mem.readInt(u32, bytes[24..28], .little),
        .index_offset = std.mem.readInt(u32, bytes[28..32], .little),
        .index_capacity = std.mem.readInt(u32, bytes[32..36], .little),
        .specifiers_offset = std.mem.readInt(u32, bytes[36..40], .little),
        .sources_offset = std.mem.readInt(u32, bytes[40..44], .little),
        .bytecode_offset = std.mem.readInt(u32, bytes[44..48], .little),
        .total_len = std.mem.readInt(u32, bytes[48..52], .little),
        .reserved0 = std.mem.readInt(u32, bytes[52..56], .little),
        .reserved1 = std.mem.readInt(u32, bytes[56..60], .little),
    };
}

fn writeHeader(dest: []u8, header: Header) void {
    std.mem.writeInt(u32, dest[0..4], header.magic, .little);
    std.mem.writeInt(u16, dest[4..6], header.version, .little);
    std.mem.writeInt(u16, dest[6..8], header.flags, .little);
    std.mem.writeInt(u32, dest[8..12], header.module_count, .little);
    std.mem.writeInt(u32, dest[12..16], header.entry_index, .little);
    std.mem.writeInt(u32, dest[16..20], header.records_offset, .little);
    std.mem.writeInt(u32, dest[20..24], header.dependencies_offset, .little);
    std.mem.writeInt(u32, dest[24..28], header.dependency_count, .little);
    std.mem.writeInt(u32, dest[28..32], header.index_offset, .little);
    std.mem.writeInt(u32, dest[32..36], header.index_capacity, .little);
    std.mem.writeInt(u32, dest[36..40], header.specifiers_offset, .little);
    std.mem.writeInt(u32, dest[40..44], header.sources_offset, .little);
    std.mem.writeInt(u32, dest[44..48], header.bytecode_offset, .little);
    std.mem.writeInt(u32, dest[48..52], header.total_len, .little);
    std.mem.writeInt(u32, dest[52..56], header.reserved0, .little);
    std.mem.writeInt(u32, dest[56..60], header.reserved1, .little);
}

fn writeRecord(dest: []u8, record: ModuleRecord) void {
    std.mem.writeInt(u32, dest[0..4], record.specifier_offset, .little);
    std.mem.writeInt(u32, dest[4..8], record.specifier_len, .little);
    std.mem.writeInt(u32, dest[8..12], record.source_offset, .little);
    std.mem.writeInt(u32, dest[12..16], record.source_len, .little);
    std.mem.writeInt(u32, dest[16..20], record.dependency_offset, .little);
    std.mem.writeInt(u32, dest[20..24], record.dependency_count, .little);
    std.mem.writeInt(u32, dest[24..28], record.bytecode_offset, .little);
    std.mem.writeInt(u32, dest[28..32], record.bytecode_len, .little);
    std.mem.writeInt(u32, dest[32..36], record.specifier_hash, .little);
    std.mem.writeInt(u32, dest[36..40], record.flags, .little);
    std.mem.writeInt(u32, dest[40..44], record.reserved0, .little);
    std.mem.writeInt(u32, dest[44..48], record.reserved1, .little);
}

fn writeDependencyRecord(dest: []u8, record: DependencyRecord) void {
    std.mem.writeInt(u32, dest[0..4], record.specifier_offset, .little);
    std.mem.writeInt(u32, dest[4..8], record.specifier_len, .little);
    std.mem.writeInt(u32, dest[8..12], record.specifier_hash, .little);
    std.mem.writeInt(u32, dest[12..16], record.reserved0, .little);
}
