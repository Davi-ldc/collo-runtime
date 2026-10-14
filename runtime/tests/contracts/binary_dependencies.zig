//! The installed `collo`'s dynamic dependencies: its `DT_NEEDED` entries are
//! exactly the platform's libraries (libc, libm, libstdc++, libgcc_s, and on
//! x86_64 the dynamic loader), it names no library search path, and the functions of
//! the dynamic loader it imports are exactly `loader_imports`. Every other
//! library it runs, ICU, BoringSSL and the codecs among them, is linked in
//! from a pinned build (`skills/runtime/references/internals/build.md`,
//! Pins), so a shared library cannot join the binary without failing here.
//!
//! Since glibc 2.34 the loader's functions live in libc itself, so linked
//! code reaches them with no library of its own to give it away, and the
//! conventions gate `runtime code loads no native code at run time` reads
//! only Collo's sources. The imports are the one place third-party code that
//! starts to load code shows up. Each one is listed with the code that calls
//! it, and an entry the binary no longer imports fails too, so a new caller
//! of the same function cannot hide behind a caller that went away. Lane:
//! `meta-test`, whose run waits on the install of `collo`.

const std = @import("std");
const builtin = @import("builtin");
const process_options = @import("collo_process_options");

const platform_libraries = [_][]const u8{
    "libc.so.6",
    "libm.so.6",
    "libstdc++.so.6",
    "libgcc_s.so.1",
} ++ loader_library;

/// x86_64 code compiled as position-independent reaches thread-local storage
/// through `__tls_get_addr`, which the dynamic loader exports, so the loader
/// is a needed library there. aarch64 uses TLS descriptors, which the loader
/// resolves without an imported symbol, so its binary needs no loader entry.
const loader_library = switch (builtin.cpu.arch) {
    .x86_64 => [_][]const u8{"ld-linux-x86-64.so.2"},
    .aarch64 => [_][]const u8{},
    else => @compileError("Collo targets x86_64 and aarch64 Linux only"),
};

const LoaderImport = struct {
    name: []const u8,
    /// The code in the binary that calls it, and why that loads nothing.
    caller: []const u8,
};

/// Every function of the dynamic loader the installed binary imports. None
/// of the callers loads a library: glibc's NSS, which `getaddrinfo` runs in
/// the gateway, loads its `hosts` services through libc's internal entry
/// points, which no import shows, and the gateway's root holds no such
/// library (`resolver_files` in `egress/gateway/sandbox.zig`).
const loader_imports = [_]LoaderImport{
    .{
        .name = "dlopen",
        .caller = "bmalloc's sanitizer probe (Source/bmalloc/bmalloc/Environment.cpp), which opens the main program, never a library",
    },
    .{
        .name = "dlsym",
        .caller = "the same probe, which looks up __asan_init and __tsan_init in the main program",
    },
    .{
        .name = "dlclose",
        .caller = "the same probe, which closes its handle to the main program",
    },
    .{
        .name = "dladdr",
        .caller = "WTF's StackTrace (Source/WTF/wtf/StackTrace.cpp), which names the frames of a stack it prints",
    },
    .{
        .name = "dl_iterate_phdr",
        .caller = "Zig's stack traces (std/debug/SelfInfo.zig), which walk the objects already loaded",
    },
};

/// Bounds on what the reader takes from a file, far above any real binary:
/// the runtime's dynamic section holds a few dozen entries, its dynamic
/// symbol table a few hundred, and its string table a few hundred kilobytes.
const section_count_max: u16 = 4096;
const dynamic_section_bytes_max: u64 = 64 * 1024;
const symbol_table_bytes_max: u64 = 4 * 1024 * 1024;
const string_table_bytes_max: u64 = 16 * 1024 * 1024;

test "the installed collo needs exactly the platform libraries, names no search path and imports only the known loader functions" {
    const gpa = std.testing.allocator;
    var dependencies = try readDependencies(gpa, process_options.collo_executable_path);
    defer dependencies.deinit(gpa);

    const problems = try dependencyProblems(gpa, .{
        .needed = dependencies.needed.items,
        .search_paths = dependencies.search_paths.items,
        .loader_imports = dependencies.loader_imports.items,
    });
    defer gpa.free(problems);
    if (problems.len != 0) {
        std.debug.print("{s}: {s}", .{ process_options.collo_executable_path, problems });
        return error.UnexpectedDynamicDependency;
    }
}

test "the dependency check reports an extra library, a missing platform library, a repeat, a search path and a loader import out of the list" {
    const gpa = std.testing.allocator;
    var known_names: [loader_imports.len][]const u8 = undefined;
    for (loader_imports, 0..) |entry, index|
        known_names[index] = entry.name;
    const cases = [_]struct { found: Found, expected: []const u8 }{
        .{
            .found = .{ .needed = &(platform_libraries ++ [_][]const u8{"libz.so.1"}), .loader_imports = &known_names },
            .expected = "needs libz.so.1",
        },
        .{
            .found = .{ .needed = platform_libraries[1..], .loader_imports = &known_names },
            .expected = "does not need libc.so.6",
        },
        .{
            .found = .{ .needed = &(platform_libraries ++ [_][]const u8{"libm.so.6"}), .loader_imports = &known_names },
            .expected = "names libm.so.6 more than once",
        },
        .{
            .found = .{ .needed = &platform_libraries, .search_paths = &.{"/usr/lib/icu"}, .loader_imports = &known_names },
            .expected = "names the search path /usr/lib/icu",
        },
        .{
            .found = .{ .needed = &platform_libraries, .loader_imports = &(known_names ++ [_][]const u8{"dlmopen"}) },
            .expected = "imports dlmopen from the dynamic loader",
        },
        .{
            .found = .{ .needed = &platform_libraries, .loader_imports = known_names[1..] },
            .expected = "no longer imports dlopen",
        },
    };
    for (cases) |case| {
        const problems = try dependencyProblems(gpa, case.found);
        defer gpa.free(problems);
        if (std.mem.indexOf(u8, problems, case.expected) == null) {
            std.debug.print("expected \"{s}\" in: {s}\n", .{ case.expected, problems });
            return error.TestUnexpectedResult;
        }
    }
    const none = try dependencyProblems(gpa, .{ .needed = &platform_libraries, .loader_imports = &known_names });
    defer gpa.free(none);
    try std.testing.expectEqualStrings("", none);
}

test "the reader finds libc among this test executable's needs and its loader imports among its undefined symbols" {
    const gpa = std.testing.allocator;
    var dependencies = try readDependencies(gpa, "/proc/self/exe");
    defer dependencies.deinit(gpa);
    try std.testing.expect(contains(dependencies.needed.items, "libc.so.6"));
    // The test executable links the same engine archives as `collo`.
    try std.testing.expect(contains(dependencies.loader_imports.items, "dlopen"));
    try std.testing.expect(!contains(dependencies.loader_imports.items, "malloc"));
}

test "a loader function is a name in the loader's own prefixes" {
    for ([_][]const u8{ "dlopen", "dlmopen", "dladdr1", "dl_iterate_phdr", "_dl_find_object" }) |name|
        try std.testing.expect(isLoaderFunction(name));
    for ([_][]const u8{ "malloc", "_ZdlPvm", "pthread_rwlock_rdlock", "" }) |name|
        try std.testing.expect(!isLoaderFunction(name));
}

/// What a binary's dynamic section and dynamic symbol table name. Every
/// slice points into `strings`.
const Dependencies = struct {
    strings: []u8,
    needed: std.ArrayList([]const u8) = .empty,
    /// `DT_RPATH` and `DT_RUNPATH` values.
    search_paths: std.ArrayList([]const u8) = .empty,
    /// Undefined dynamic symbols that `isLoaderFunction` names.
    loader_imports: std.ArrayList([]const u8) = .empty,

    fn deinit(dependencies: *Dependencies, gpa: std.mem.Allocator) void {
        dependencies.needed.deinit(gpa);
        dependencies.search_paths.deinit(gpa);
        dependencies.loader_imports.deinit(gpa);
        gpa.free(dependencies.strings);
        dependencies.* = undefined;
    }
};

/// What `dependencyProblems` compares with the platform set and
/// `loader_imports`.
const Found = struct {
    needed: []const []const u8,
    search_paths: []const []const u8 = &.{},
    loader_imports: []const []const u8,
};

/// Whether `name` is a function of the dynamic loader: glibc's `dlfcn.h`
/// functions and `dl_iterate_phdr` start with `dl`, and its loader-internal
/// exports, such as `_dl_find_object`, with `_dl_`. No other libc, libm or
/// libstdc++ export starts with either.
fn isLoaderFunction(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "dl") or std.mem.startsWith(u8, name, "_dl_");
}

/// Reads the dynamic section and the dynamic symbol table of the 64-bit
/// little-endian ELF executable at `path` through its section headers. Every
/// offset and size comes from the file, so each is checked against the file
/// and the bounds above before use.
fn readDependencies(gpa: std.mem.Allocator, path: []const u8) !Dependencies {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const file_size = try file.getEndPos();
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(&buffer);
    const header = try std.elf.Header.read(&reader.interface);
    if (!header.is_64 or header.endian != .little)
        return error.UnexpectedElfClass;
    if (header.shnum > section_count_max)
        return error.TooManySections;

    var dynamic: ?std.elf.Elf64_Shdr = null;
    var symbols: ?std.elf.Elf64_Shdr = null;
    var sections = header.iterateSectionHeaders(&reader);
    while (try sections.next()) |section| {
        if (section.sh_type == std.elf.SHT_DYNAMIC) {
            if (dynamic != null)
                return error.DuplicateDynamicSection;
            dynamic = section;
        }
        if (section.sh_type == std.elf.SHT_DYNSYM) {
            if (symbols != null)
                return error.DuplicateSymbolTable;
            symbols = section;
        }
    }
    const dynamic_section = dynamic orelse return error.NoDynamicSection;
    const symbol_section = symbols orelse return error.NoSymbolTable;
    if (dynamic_section.sh_link >= header.shnum)
        return error.BadStringTableIndex;
    // Both name their strings in `.dynstr`, so one string table serves both.
    if (symbol_section.sh_link != dynamic_section.sh_link)
        return error.BadStringTableIndex;
    var strings_section: ?std.elf.Elf64_Shdr = null;
    var index: u32 = 0;
    sections = header.iterateSectionHeaders(&reader);
    while (try sections.next()) |section| : (index += 1) {
        if (index == dynamic_section.sh_link)
            strings_section = section;
    }
    const strings_header = strings_section orelse return error.BadStringTableIndex;
    if (strings_header.sh_type != std.elf.SHT_STRTAB)
        return error.BadStringTable;

    const dynamic_bytes = try readSection(gpa, file, file_size, dynamic_section, dynamic_section_bytes_max);
    defer gpa.free(dynamic_bytes);
    var dependencies: Dependencies = .{
        .strings = try readSection(gpa, file, file_size, strings_header, string_table_bytes_max),
    };
    errdefer dependencies.deinit(gpa);

    const entry_size = @sizeOf(std.elf.Elf64_Dyn);
    if (dynamic_bytes.len % entry_size != 0)
        return error.MalformedDynamicSection;
    var offset: usize = 0;
    while (offset < dynamic_bytes.len) : (offset += entry_size) {
        const tag = std.mem.readInt(i64, dynamic_bytes[offset..][0..8], .little);
        const value = std.mem.readInt(u64, dynamic_bytes[offset + 8 ..][0..8], .little);
        switch (tag) {
            std.elf.DT_NULL => break,
            std.elf.DT_NEEDED => try dependencies.needed.append(gpa, try stringAt(dependencies.strings, value)),
            std.elf.DT_RPATH, std.elf.DT_RUNPATH => try dependencies.search_paths.append(gpa, try stringAt(dependencies.strings, value)),
            else => {},
        }
    }

    const symbol_bytes = try readSection(gpa, file, file_size, symbol_section, symbol_table_bytes_max);
    defer gpa.free(symbol_bytes);
    const symbol_size = @sizeOf(std.elf.Elf64_Sym);
    if (symbol_bytes.len % symbol_size != 0)
        return error.MalformedSymbolTable;
    offset = 0;
    while (offset < symbol_bytes.len) : (offset += symbol_size) {
        const symbol = std.mem.bytesToValue(std.elf.Elf64_Sym, symbol_bytes[offset..][0..symbol_size]);
        if (symbol.st_shndx != std.elf.SHN_UNDEF or symbol.st_name == 0)
            continue;
        const name = try stringAt(dependencies.strings, symbol.st_name);
        if (isLoaderFunction(name))
            try dependencies.loader_imports.append(gpa, name);
    }
    return dependencies;
}

fn readSection(
    gpa: std.mem.Allocator,
    file: std.fs.File,
    file_size: u64,
    section: std.elf.Elf64_Shdr,
    bytes_max: u64,
) ![]u8 {
    if (section.sh_size > bytes_max)
        return error.SectionTooLarge;
    if (section.sh_offset > file_size or section.sh_size > file_size - section.sh_offset)
        return error.SectionOutsideFile;
    const bytes = try gpa.alloc(u8, @intCast(section.sh_size));
    errdefer gpa.free(bytes);
    if (try file.preadAll(bytes, section.sh_offset) != bytes.len)
        return error.SectionOutsideFile;
    return bytes;
}

/// The NUL-terminated string at `offset` in a string table.
fn stringAt(strings: []const u8, offset: u64) ![]const u8 {
    if (offset >= strings.len)
        return error.StringOutsideTable;
    const start: usize = @intCast(offset);
    const end = std.mem.indexOfScalarPos(u8, strings, start, 0) orelse return error.UnterminatedString;
    return strings[start..end];
}

/// One line per difference from the platform set and `loader_imports`, or an
/// empty string; owned by `gpa`.
fn dependencyProblems(gpa: std.mem.Allocator, found: Found) ![]u8 {
    var report: std.Io.Writer.Allocating = .init(gpa);
    errdefer report.deinit();
    for (found.needed, 0..) |name, position| {
        if (!contains(&platform_libraries, name))
            try report.writer.print("needs {s}, which is not a platform library; link it statically from a pinned build\n", .{name});
        if (contains(found.needed[0..position], name))
            try report.writer.print("names {s} more than once\n", .{name});
    }
    for (platform_libraries) |name| {
        if (!contains(found.needed, name))
            try report.writer.print("does not need {s}; the platform set in this file must change with the link\n", .{name});
    }
    for (found.search_paths) |search_path|
        try report.writer.print("names the search path {s}, from which a library other than the platform's could load\n", .{search_path});
    for (found.loader_imports) |name| {
        if (!isKnownLoaderImport(name))
            try report.writer.print("imports {s} from the dynamic loader; find the code that calls it and list it in loader_imports only if it loads no library\n", .{name});
    }
    for (loader_imports) |entry| {
        if (!contains(found.loader_imports, entry.name))
            try report.writer.print("no longer imports {s}; drop its entry from loader_imports\n", .{entry.name});
    }
    return report.toOwnedSlice();
}

fn isKnownLoaderImport(name: []const u8) bool {
    for (loader_imports) |entry| {
        if (std.mem.eql(u8, entry.name, name))
            return true;
    }
    return false;
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name))
            return true;
    }
    return false;
}
