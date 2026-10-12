//! The dependencies Collo builds from source at a pinned commit: where each
//! one's version file and pristine tree live under `runtime/deps/`, how the
//! tree is fetched, and the parser of the version file. The build script
//! reads a pin at configure time and the buildtool reads the same file when
//! it runs, so a commit is written in exactly one place.
//!
//! A version file opens with `Key: value` lines up to its first blank line:
//! `Source` (the git URL), `Tag` (omitted for a commit pinned without one),
//! `Commit` (the full lowercase SHA-1, which the tag must resolve to) and
//! `Patches` (the series directory relative to `runtime/`, or `none`). Prose
//! follows the blank line and is never read.
//!
//! A pristine tree is input: it is fetched once at its pin and never edited
//! or removed by any tool. A change to a dependency is a patch series applied
//! to a generated copy, so the tree stays byte for byte what upstream
//! published.

const std = @import("std");

/// Every pinned tree and version file lives directly under this directory,
/// relative to the repository root.
pub const deps_relative = "runtime/deps";

pub const Dependency = enum {
    webkit,
    boringssl,
    ls_hpack,
    icu,
    zlib,
    brotli,
    zstd,
};

pub const Spec = struct {
    /// The pristine tree's directory under `deps_relative`.
    tree: []const u8,
    /// The version file under `deps_relative`.
    version_file: []const u8,
    /// A path every checkout of the tree holds, relative to the tree. A tree
    /// without it is not the dependency, whatever its HEAD says.
    marker: []const u8,
    /// The directories a cone-mode sparse checkout materializes; empty
    /// materializes the whole tree.
    sparse_cone: []const []const u8 = &.{},
    /// Fetch commits and trees only; git fetches the blobs a checkout needs
    /// and leaves the rest on the server.
    blobless: bool = false,
    /// The build reads the tree's own files instead of a worktree of its
    /// commit, so a provisioned tree must also hold no edited, staged,
    /// untracked or ignored file: anything there would reach the binary
    /// unreviewed.
    read_in_place: bool,
};

/// The directories of WebKit that a JSCOnly build and its readers open.
/// `Tools/Scripts` holds the header-map tool the engine build extracts and
/// the style checkers, which resolve their paths only inside a checkout.
pub const webkit_cone = [_][]const u8{
    "Source/cmake",               "Source/JavaScriptCore",
    "Source/WTF",                 "Source/bmalloc",
    "Source/ThirdParty/capstone", "Source/ThirdParty/unifdef",
    "Source/ThirdParty/gtest",    "Tools/Scripts",
};

pub fn spec(dependency: Dependency) Spec {
    return switch (dependency) {
        .webkit => .{
            .tree = "WebKit",
            .version_file = "webkit.version",
            .marker = "Source/JavaScriptCore",
            .sparse_cone = &webkit_cone,
            .blobless = true,
            .read_in_place = false,
        },
        .boringssl => .{
            .tree = "boringssl",
            .version_file = "boringssl.version",
            .marker = "include/openssl/ssl.h",
            .read_in_place = false,
        },
        .ls_hpack => .{
            .tree = "ls-hpack",
            .version_file = "ls-hpack.version",
            .marker = "lshpack.c",
            .read_in_place = true,
        },
        .icu => .{
            .tree = "icu",
            .version_file = "icu.version",
            .marker = "icu4c/source/configure",
            .sparse_cone = &.{"icu4c/source"},
            .blobless = true,
            .read_in_place = true,
        },
        .zlib => .{
            .tree = "zlib",
            .version_file = "zlib.version",
            .marker = "zlib.h",
            .read_in_place = true,
        },
        .brotli => .{
            .tree = "brotli",
            .version_file = "brotli.version",
            .marker = "c/include/brotli/decode.h",
            .read_in_place = true,
        },
        .zstd => .{
            .tree = "zstd",
            .version_file = "zstd.version",
            .marker = "lib/zstd.h",
            .read_in_place = true,
        },
    };
}

/// A version file's header. Every slice points into the text it was parsed
/// from.
pub const Pin = struct {
    source: []const u8,
    tag: ?[]const u8,
    commit: []const u8,
    /// The series directory relative to `runtime/`; null for `Patches: none`.
    patches: ?[]const u8,
};

/// A version file is a few hundred bytes; anything near this bound is not one.
pub const version_file_bytes_max: usize = 64 * 1024;

pub const ParseError = error{
    MalformedLine,
    UnknownField,
    DuplicateField,
    EmptyValue,
    MissingField,
    MalformedCommit,
};

/// Parses the header of a version file. The header ends at the first empty
/// line or at the end of `text`; a carriage return, an unknown key, a
/// repeated key and a commit that is not 40 lowercase hex digits are errors,
/// because a pin that parses loosely can name the wrong tree.
pub fn parse(text: []const u8) ParseError!Pin {
    var source: ?[]const u8 = null;
    var tag: ?[]const u8 = null;
    var commit: ?[]const u8 = null;
    var patches: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0)
            break;
        if (std.mem.indexOfAny(u8, line, "\r\x00") != null)
            return error.MalformedLine;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.MalformedLine;
        const key = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (value.len == 0)
            return error.EmptyValue;
        const field: *?[]const u8 = if (std.mem.eql(u8, key, "Source"))
            &source
        else if (std.mem.eql(u8, key, "Tag"))
            &tag
        else if (std.mem.eql(u8, key, "Commit"))
            &commit
        else if (std.mem.eql(u8, key, "Patches"))
            &patches
        else
            return error.UnknownField;
        if (field.* != null)
            return error.DuplicateField;
        field.* = value;
    }
    const commit_value = commit orelse return error.MissingField;
    if (!isFullCommit(commit_value))
        return error.MalformedCommit;
    const patches_value = patches orelse return error.MissingField;
    return .{
        .source = source orelse return error.MissingField,
        .tag = tag,
        .commit = commit_value,
        .patches = if (std.mem.eql(u8, patches_value, "none")) null else patches_value,
    };
}

/// A full SHA-1 object name as git prints it: 40 lowercase hex digits.
pub fn isFullCommit(value: []const u8) bool {
    if (value.len != 40)
        return false;
    for (value) |byte| {
        const lower_hex = std.ascii.isDigit(byte) or (byte >= 'a' and byte <= 'f');
        if (!lower_hex)
            return false;
    }
    return true;
}

/// A loaded version file: its bytes, owned by the caller's allocator, and
/// the pin that points into them.
pub const Loaded = struct {
    text: []u8,
    pin: Pin,

    pub fn deinit(loaded: *Loaded, allocator: std.mem.Allocator) void {
        allocator.free(loaded.text);
        loaded.* = undefined;
    }
};

/// Reads and parses the version file of `dependency` from `repository`, the
/// repository root. Fails with the file's open or read error, or a
/// `ParseError`.
pub fn load(
    allocator: std.mem.Allocator,
    repository: std.fs.Dir,
    dependency: Dependency,
) !Loaded {
    const path = try std.fs.path.join(allocator, &.{ deps_relative, spec(dependency).version_file });
    defer allocator.free(path);
    const text = try repository.readFileAlloc(allocator, path, version_file_bytes_max);
    errdefer allocator.free(text);
    return .{ .text = text, .pin = try parse(text) };
}
