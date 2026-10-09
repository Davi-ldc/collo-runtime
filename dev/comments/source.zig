//! Language detection and the directory walk, which the guard and the
//! provenance scan share, and the comment iteration the provenance scan reads
//! markers through. Both tools pick files with `languageOf` and `listFiles`, so
//! a change to either one, or to the skipped directories, moves the guard's
//! proof and the gate's counts together.
const std = @import("std");
const cpp_lexer = @import("cpp_lexer.zig");
const zig_lexer = @import("zig_lexer.zig");

pub const Language = enum {
    /// Zig source and ZON, which share a tokenizer.
    zig,
    /// C and C++, which share a preprocessor.
    c_family,
};

/// Null for a file neither lexer understands.
pub fn languageOf(path: []const u8) ?Language {
    const extension = std.fs.path.extension(path);
    const zig_extensions = [_][]const u8{ ".zig", ".zon" };
    const c_family_extensions = [_][]const u8{ ".c", ".cc", ".cpp", ".cxx", ".h", ".hh", ".hpp", ".hxx" };
    for (zig_extensions) |candidate| {
        if (std.mem.eql(u8, extension, candidate)) return .zig;
    }
    for (c_family_extensions) |candidate| {
        if (std.mem.eql(u8, extension, candidate)) return .c_family;
    }
    return null;
}

pub const Comment = struct {
    start: usize,
    end: usize,
};

/// Comments of either language, in source order, delimiters included.
pub const CommentIterator = union(Language) {
    zig: zig_lexer.CommentIterator,
    c_family: cpp_lexer.Lexer,

    pub fn init(language: Language, source: [:0]const u8) CommentIterator {
        return switch (language) {
            .zig => .{ .zig = .init(source) },
            .c_family => .{ .c_family = .init(source) },
        };
    }

    pub fn next(it: *CommentIterator) ?Comment {
        switch (it.*) {
            .zig => |*zig| {
                const comment = zig.next() orelse return null;
                return .{ .start = comment.start, .end = comment.end };
            },
            .c_family => |*lexer| while (true) {
                const token = lexer.next();
                if (token.tag == .eof) return null;
                if (token.tag.isComment()) return .{ .start = token.start, .end = token.end };
            },
        }
    }
};

pub const File = struct {
    /// Relative to the walked root, `/`-separated.
    path: []u8,
    kind: std.fs.File.Kind,
};

pub const FileList = struct {
    /// Sorted by path.
    files: []File,

    pub fn deinit(list: FileList, gpa: std.mem.Allocator) void {
        for (list.files) |file| gpa.free(file.path);
        gpa.free(list.files);
    }
};

/// Build caches, dependency trees and version-control metadata: generated or
/// vendored, never written by hand.
pub fn isSkippedDirectory(name: []const u8) bool {
    const skipped = [_][]const u8{ ".git", ".zig-cache", "zig-cache", "zig-out", "node_modules" };
    for (skipped) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

/// Every non-directory entry under `root`, without descending into skipped
/// directories or following links to directories. The caller frees the list
/// with `FileList.deinit`. A directory that cannot be opened or read fails the
/// whole walk.
pub fn listFiles(gpa: std.mem.Allocator, root: std.fs.Dir) !FileList {
    var files: std.ArrayList(File) = .empty;
    errdefer {
        for (files.items) |file| gpa.free(file.path);
        files.deinit(gpa);
    }
    var pending: std.ArrayList([]u8) = .empty;
    defer {
        for (pending.items) |path| gpa.free(path);
        pending.deinit(gpa);
    }
    try pending.append(gpa, try gpa.dupe(u8, ""));

    while (pending.pop()) |directory_path| {
        defer gpa.free(directory_path);
        var directory = try root.openDir(if (directory_path.len == 0) "." else directory_path, .{ .iterate = true });
        defer directory.close();
        var entries = directory.iterate();
        while (try entries.next()) |entry| {
            if (entry.kind == .directory and isSkippedDirectory(entry.name)) continue;
            const path = if (directory_path.len == 0)
                try gpa.dupe(u8, entry.name)
            else
                try std.fs.path.join(gpa, &.{ directory_path, entry.name });
            errdefer gpa.free(path);
            if (entry.kind == .directory) {
                try pending.append(gpa, path);
            } else {
                try files.append(gpa, .{ .path = path, .kind = entry.kind });
            }
        }
    }

    const sorted = try files.toOwnedSlice(gpa);
    std.mem.sort(File, sorted, {}, fileLessThan);
    return .{ .files = sorted };
}

fn fileLessThan(_: void, a: File, b: File) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}
