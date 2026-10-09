//! COLLOFS1, the binary index of a worker's read-only file tree. The host
//! seals an index into a memfd that WorkerInit carries: `buildIndexBytes`
//! serializes a tree, and `placeholder_bytes` is the index of a tree with
//! no files (`createPlaceholderFsIndexMemfd` in `zygote_worker.zig`). The
//! worker maps and parses it once at boot (`worker/fs/index.zig`) and then
//! looks paths up in it without parsing or allocating. Both processes
//! compile this file, so the layout below is the whole contract.
//!
//! Layout, all integers little-endian and written field by field:
//!
//!   offset 0             header, `header_bytes`
//!     [0..8)   magic                "COLLOFS1"
//!     [8..12)  version              u32 = `version`
//!     [12..16) entry_count          u32, at most `entries_max`
//!     [16..24) mtime_ms             u64, the mtime the worker reports for
//!                                   every file and directory of the tree
//!     [24..32) entries_offset       u64 = `header_bytes`
//!     [32..40) string_table_offset  u64 = entries_offset + entry_count * `entry_bytes`
//!     [40..48) total_bytes          u64 = the length of the whole index
//!   entries_offset       entry_count entries of `entry_bytes`
//!     [0..4)   path_offset          u32, relative to string_table_offset
//!     [4..8)   path_len             u32
//!     [8..16)  size                 u64
//!     [16..48) sha256               raw digest of the file's bytes
//!   string_table_offset  the paths, concatenated without separators
//!
//! Every index keeps these invariants. The builder checks them on its input,
//! and `IndexView.parse` checks them again on the bytes, because the worker
//! parses the index only once, at boot before its seccomp filter is
//! installed, and answers file calls from it for the rest of its life, so a
//! host bug must fail the worker's boot rather than open a routing hole:
//! - entries are sorted strictly ascending by path bytes, which makes paths
//!   unique and is what the binary search needs;
//! - every path passes `validatePath`;
//! - no path names a file at an ancestor directory of another path (`a` next
//!   to `a/b`), a tree no filesystem can hold;
//! - there are at most `entries_max` entries.
//!
//! Everything here is a pure function of its arguments, callable from any
//! thread.

const std = @import("std");

/// Longest path of the tree, in bytes, relative to the tree root. It is a
/// policy bound well inside what a worker can resolve: joined under the
/// worker's tree root, a path this long still fits one Linux path
/// (`worker/fs/index.zig` asserts it). `AncestorConflictChecker` keeps one
/// stack slot per byte of it, so the bound also sizes the stack the check
/// takes in the worker at every boot and in the host when it builds an index.
pub const path_bytes_max: usize = 1024;

/// Most entries one index holds. With `path_bytes_max` it bounds an index to
/// `entries_max * (entry_bytes + path_bytes_max)` bytes plus the header,
/// about 51 MiB, which the worker maps and validates at every boot.
pub const entries_max: usize = 50_000;

pub const magic = [8]u8{ 'C', 'O', 'L', 'L', 'O', 'F', 'S', '1' };
pub const version: u32 = 1;
pub const header_bytes: usize = 48;
pub const entry_bytes: usize = 48;

/// The index of a tree with no files: the header alone, with a zero mtime.
/// Every route shares it until a route can carry a file tree.
pub const placeholder_bytes: [header_bytes]u8 = placeholder: {
    var bytes = [_]u8{0} ** header_bytes;
    @memcpy(bytes[0..8], &magic);
    std.mem.writeInt(u32, bytes[8..12], version, .little);
    std.mem.writeInt(u64, bytes[24..32], header_bytes, .little);
    std.mem.writeInt(u64, bytes[32..40], header_bytes, .little);
    std.mem.writeInt(u64, bytes[40..48], header_bytes, .little);
    break :placeholder bytes;
};

/// The header and an entry as extern structs, for a reader that maps the
/// index page-aligned and reinterprets it in place.
pub const Header = extern struct {
    magic: [8]u8,
    version: u32,
    entry_count: u32,
    mtime_ms: u64,
    entries_offset: u64,
    string_table_offset: u64,
    total_bytes: u64,
};

pub const Entry = extern struct {
    path_offset: u32,
    path_len: u32,
    size: u64,
    sha256: [32]u8,
};

comptime {
    std.debug.assert(@sizeOf(Header) == header_bytes);
    std.debug.assert(@sizeOf(Entry) == entry_bytes);
    std.debug.assert(@offsetOf(Header, "mtime_ms") == 16);
    std.debug.assert(@offsetOf(Entry, "size") == 8);
    std.debug.assert(@offsetOf(Entry, "sha256") == 16);
    // Offsets and lengths of a maximal index fit the u32 fields that hold
    // them.
    std.debug.assert(entries_max <= std.math.maxInt(u32));
    std.debug.assert(entries_max * path_bytes_max <= std.math.maxInt(u32));
}

/// One file of the tree, as the builder takes it.
pub const File = struct {
    /// Relative to the tree root; see `validatePath`.
    path: []const u8,
    size: u64,
    sha256: [32]u8,
};

pub const BuildError = error{
    OutOfMemory,
    TooManyFsIndexEntries,
    InvalidFsPath,
    UnorderedFsIndex,
    FsIndexAncestorConflict,
};

/// The rules every indexed path follows: 1 to `path_bytes_max` bytes of
/// valid UTF-8, relative (no leading '/'), no NUL, CR, LF or backslash, and
/// no empty, `.` or `..` segment. The worker joins a path under its tree root
/// and resolves it lexically, so these are what keep every entry inside the
/// tree and one entry from naming another.
pub fn validatePath(path: []const u8) error{InvalidFsPath}!void {
    if (path.len == 0 or path.len > path_bytes_max)
        return error.InvalidFsPath;
    if (path[0] == '/')
        return error.InvalidFsPath;
    if (std.mem.indexOfAny(u8, path, "\x00\r\n\\") != null)
        return error.InvalidFsPath;
    if (!std.unicode.utf8ValidateSlice(path))
        return error.InvalidFsPath;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0)
            return error.InvalidFsPath;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, ".."))
            return error.InvalidFsPath;
    }
}

/// Serializes `files` into index bytes the caller owns and frees. `files`
/// must already be in index order, strictly ascending by path bytes; the
/// call checks every invariant in the header and fails on the first input
/// that breaks one.
pub fn buildIndexBytes(allocator: std.mem.Allocator, mtime_ms: u64, files: []const File) BuildError![]u8 {
    if (files.len > entries_max)
        return error.TooManyFsIndexEntries;
    var ancestor_checker: AncestorConflictChecker = .{};
    var string_table_len: u64 = 0;
    for (files, 0..) |file, index| {
        try validatePath(file.path);
        if (index != 0) {
            if (std.mem.order(u8, files[index - 1].path, file.path) != .lt)
                return error.UnorderedFsIndex;
        }
        ancestor_checker.feed(file.path) catch return error.FsIndexAncestorConflict;
        string_table_len += file.path.len;
    }

    const entry_count: u32 = @intCast(files.len);
    const entries_offset: u64 = header_bytes;
    const string_table_offset: u64 = entries_offset + @as(u64, entry_count) * entry_bytes;
    const total_bytes: u64 = string_table_offset + string_table_len;

    const bytes = try allocator.alloc(u8, @intCast(total_bytes));
    errdefer allocator.free(bytes);

    @memcpy(bytes[0..8], &magic);
    std.mem.writeInt(u32, bytes[8..12], version, .little);
    std.mem.writeInt(u32, bytes[12..16], entry_count, .little);
    std.mem.writeInt(u64, bytes[16..24], mtime_ms, .little);
    std.mem.writeInt(u64, bytes[24..32], entries_offset, .little);
    std.mem.writeInt(u64, bytes[32..40], string_table_offset, .little);
    std.mem.writeInt(u64, bytes[40..48], total_bytes, .little);

    var path_offset: u32 = 0;
    var string_cursor: usize = @intCast(string_table_offset);
    for (files, 0..) |file, index| {
        const entry_start: usize = @intCast(entries_offset + index * entry_bytes);
        const entry = bytes[entry_start..][0..entry_bytes];
        std.mem.writeInt(u32, entry[0..4], path_offset, .little);
        std.mem.writeInt(u32, entry[4..8], @intCast(file.path.len), .little);
        std.mem.writeInt(u64, entry[8..16], file.size, .little);
        @memcpy(entry[16..48], &file.sha256);
        @memcpy(bytes[string_cursor..][0..file.path.len], file.path);
        path_offset += @intCast(file.path.len);
        string_cursor += file.path.len;
    }
    std.debug.assert(string_cursor == bytes.len);
    return bytes;
}

/// A validated, zero-copy view over index bytes. Reads go through explicit
/// little-endian loads, so the bytes need no alignment: a private mapping of
/// the memfd and a heap slice work alike. The view borrows the bytes for its
/// whole life.
pub const IndexView = struct {
    bytes: []const u8,
    entry_count: u32,
    mtime_ms: u64,
    string_table_offset: u64,

    /// Checks the whole layout and every invariant in the file header before
    /// the first lookup, and fails with `error.InvalidFsIndex` on any
    /// violation.
    pub fn parse(bytes: []const u8) error{InvalidFsIndex}!IndexView {
        if (bytes.len < header_bytes)
            return error.InvalidFsIndex;
        if (!std.mem.eql(u8, bytes[0..8], &magic))
            return error.InvalidFsIndex;
        if (std.mem.readInt(u32, bytes[8..12], .little) != version)
            return error.InvalidFsIndex;
        const entry_count = std.mem.readInt(u32, bytes[12..16], .little);
        if (entry_count > entries_max)
            return error.InvalidFsIndex;
        const mtime_ms = std.mem.readInt(u64, bytes[16..24], .little);
        const entries_offset = std.mem.readInt(u64, bytes[24..32], .little);
        const string_table_offset = std.mem.readInt(u64, bytes[32..40], .little);
        const total_bytes = std.mem.readInt(u64, bytes[40..48], .little);
        if (entries_offset != header_bytes)
            return error.InvalidFsIndex;
        if (string_table_offset != entries_offset + @as(u64, entry_count) * entry_bytes)
            return error.InvalidFsIndex;
        if (total_bytes != bytes.len or total_bytes < string_table_offset)
            return error.InvalidFsIndex;
        const string_table_len = total_bytes - string_table_offset;

        const view = IndexView{
            .bytes = bytes,
            .entry_count = entry_count,
            .mtime_ms = mtime_ms,
            .string_table_offset = string_table_offset,
        };
        var ancestor_checker: AncestorConflictChecker = .{};
        var previous: ?[]const u8 = null;
        for (0..entry_count) |index| {
            const entry = view.entrySlice(index);
            const path_offset = std.mem.readInt(u32, entry[0..4], .little);
            const path_len = std.mem.readInt(u32, entry[4..8], .little);
            if (path_len == 0 or path_len > path_bytes_max)
                return error.InvalidFsIndex;
            if (@as(u64, path_offset) + path_len > string_table_len)
                return error.InvalidFsIndex;
            const path = view.entryPathAt(index);
            validatePath(path) catch return error.InvalidFsIndex;
            if (previous) |earlier| {
                if (std.mem.order(u8, earlier, path) != .lt)
                    return error.InvalidFsIndex;
            }
            previous = path;
            ancestor_checker.feed(path) catch return error.InvalidFsIndex;
        }
        return view;
    }

    fn entrySlice(self: *const IndexView, index: usize) *const [entry_bytes]u8 {
        const start = header_bytes + index * entry_bytes;
        return self.bytes[start..][0..entry_bytes];
    }

    pub fn entryPathAt(self: *const IndexView, index: usize) []const u8 {
        const entry = self.entrySlice(index);
        const path_offset = std.mem.readInt(u32, entry[0..4], .little);
        const path_len = std.mem.readInt(u32, entry[4..8], .little);
        const start: usize = @intCast(self.string_table_offset + path_offset);
        return self.bytes[start..][0..path_len];
    }

    pub fn entrySizeAt(self: *const IndexView, index: usize) u64 {
        return std.mem.readInt(u64, self.entrySlice(index)[8..16], .little);
    }

    pub fn entrySha256At(self: *const IndexView, index: usize) [32]u8 {
        return self.entrySlice(index)[16..48].*;
    }

    /// The entry index of `path`, by binary search over the path bytes.
    pub fn lookup(self: *const IndexView, path: []const u8) ?usize {
        var low: usize = 0;
        var high: usize = self.entry_count;
        while (low < high) {
            const mid = low + (high - low) / 2;
            switch (std.mem.order(u8, self.entryPathAt(mid), path)) {
                .lt => low = mid + 1,
                .gt => high = mid,
                .eq => return mid,
            }
        }
        return null;
    }
};

/// Finds a file at an ancestor directory of another path (`a` next to
/// `a/b`) over paths fed strictly ascending by bytes, in O(total path bytes)
/// for the whole feed, which keeps an index at the caps cheap to validate at
/// every worker boot. Pairwise checks of neighbors are not enough: `a`,
/// `a!x`, `a/b` sort in that order, so the conflicting pair is not adjacent.
///
/// The stack always holds a chain of byte prefixes of the last fed path,
/// each a strict prefix of the one above it. Ascending order keeps an
/// ancestor stacked until every path below it has been fed: a path between
/// a prefix A and a later path with prefix A shares prefix A too. A fed path
/// P conflicts exactly when a stacked A ends on a '/' boundary of P
/// (`P[A.len] == '/'`): A is then a file at an ancestor directory of P.
/// Stacked lengths strictly increase, so the depth never exceeds
/// `path_bytes_max`. Fed slices must stay alive while feeding.
const AncestorConflictChecker = struct {
    stack: [path_bytes_max][]const u8 = undefined,
    depth: usize = 0,

    fn feed(self: *AncestorConflictChecker, path: []const u8) error{AncestorConflict}!void {
        while (self.depth != 0 and !std.mem.startsWith(u8, path, self.stack[self.depth - 1]))
            self.depth -= 1;
        for (self.stack[0..self.depth]) |ancestor| {
            // Strict order rules out duplicates, so every stacked path is a
            // strict prefix and the boundary byte exists.
            if (path[ancestor.len] == '/')
                return error.AncestorConflict;
        }
        std.debug.assert(self.depth < self.stack.len);
        self.stack[self.depth] = path;
        self.depth += 1;
    }
};
