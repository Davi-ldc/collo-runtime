//! Readers and parsers for the Linux memory counters the benchmark's
//! controller samples on its one thread: a process's `smaps_rollup` and a
//! cgroup's memory files. Every read is bounded, and a file longer than its
//! bound is an error, never a truncated value.
//!
//! Process counters describe mapped resident pages; a shared page counts in
//! full toward each mapper's RSS and in proportion toward its PSS. Cgroup
//! counters describe charges to the whole subtree, including accounted kernel
//! memory. Neither is an atomic snapshot across processes or files, and
//! charges already made stay with their cgroup when a process moves to
//! another one.

const std = @import("std");

/// Longest input the parsers accept, and the read bound of `smaps_rollup` and
/// `memory.stat`.
pub const snapshot_file_bytes_max: usize = 64 * 1024;
const scalar_file_bytes_max: usize = 64;
const events_file_bytes_max: usize = 4096;

/// A process's `smaps_rollup` counters, in bytes.
pub const ProcessMemory = struct {
    rss_bytes: u64,
    pss_bytes: u64,
    shared_clean_bytes: u64,
    shared_dirty_bytes: u64,
    private_clean_bytes: u64,
    private_dirty_bytes: u64,
    swap_bytes: u64,

    /// Resident pages other processes also map. They are not unique physical
    /// memory, so summing them across processes counts a page more than once.
    pub fn sharedBytes(self: ProcessMemory) error{Overflow}!u64 {
        return std.math.add(u64, self.shared_clean_bytes, self.shared_dirty_bytes);
    }

    /// The unique set size: resident pages no other process maps.
    pub fn ussBytes(self: ProcessMemory) error{Overflow}!u64 {
        return std.math.add(u64, self.private_clean_bytes, self.private_dirty_bytes);
    }
};

/// The `memory.stat` fields the controller records, in bytes.
pub const MemoryStat = struct {
    anon_bytes: u64,
    file_bytes: u64,
    kernel_bytes: u64,
    shmem_bytes: u64,
    pagetables_bytes: u64,
    kernel_stack_bytes: u64,
    slab_bytes: u64,
};

/// Event counts from a cgroup's `memory.events`.
pub const MemoryEvents = struct {
    low: u64,
    high: u64,
    max: u64,
    oom: u64,
    oom_kill: u64,
};

/// One reading of a cgroup subtree: `memory.current`, `memory.swap.current`,
/// `memory.stat` and `memory.events`, read one file after another.
pub const GroupMemory = struct {
    current_bytes: u64,
    swap_bytes: u64,
    stat: MemoryStat,
    events: MemoryEvents,
};

pub const ParseError = error{
    InputTooLarge,
    MissingField,
    DuplicateField,
    InvalidFormat,
    InvalidUnit,
    InvalidValue,
    Overflow,
};

/// Parses `smaps_rollup`, converting its kB values to bytes. Unknown keys are
/// ignored; every field of `ProcessMemory` must appear exactly once, with a
/// `kB` unit. RSS, PSS and the clean and dirty counters exclude HugeTLB pages,
/// which the file reports on lines of their own.
pub fn parseProcessRollup(contents: []const u8) ParseError!ProcessMemory {
    return parseFields(ProcessMemory, &process_fields, contents, .kib);
}

/// Parses `memory.stat`, whose values are bytes. Unknown keys are ignored;
/// every field of `MemoryStat` must appear exactly once.
pub fn parseMemoryStat(contents: []const u8) ParseError!MemoryStat {
    return parseFields(MemoryStat, &stat_fields, contents, .scalar);
}

/// Parses `memory.events`. Unknown keys are ignored; every field of
/// `MemoryEvents` must appear exactly once.
pub fn parseMemoryEvents(contents: []const u8) ParseError!MemoryEvents {
    return parseFields(MemoryEvents, &events_fields, contents, .scalar);
}

/// Reads `/proc/<pid>/smaps_rollup`. A pid of zero fails with
/// `error.InvalidProcessId`.
pub fn readProcess(pid: u32) !ProcessMemory {
    if (pid == 0) return error.InvalidProcessId;
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}/smaps_rollup", .{pid});
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    var buffer: [snapshot_file_bytes_max + 1]u8 = undefined;
    return parseProcessRollup(try readBounded(file.handle, &buffer));
}

/// Reads the cgroup directory at `path`, whose counters all cover its whole
/// subtree. The stat fields overlap: shmem is part of file, and slab, page
/// tables and kernel stacks are part of kernel, so they must not be summed.
pub fn readGroup(path: []const u8) !GroupMemory {
    var dir = try std.fs.cwd().openDir(path, .{});
    defer dir.close();
    var buffer: [snapshot_file_bytes_max + 1]u8 = undefined;
    return .{
        .current_bytes = try readScalarAt(dir, "memory.current"),
        .swap_bytes = try readScalarAt(dir, "memory.swap.current"),
        .stat = try parseMemoryStat(try readAt(dir, "memory.stat", &buffer)),
        .events = try parseMemoryEvents(try readAt(
            dir,
            "memory.events",
            buffer[0 .. events_file_bytes_max + 1],
        )),
    };
}

/// Owns one open `memory.peak` descriptor. The kernel keeps a reset per open
/// descriptor, so a reset changes what this descriptor reads and nothing else.
pub const PeakCounter = struct {
    fd: std.posix.fd_t,

    /// `path` names the cgroup directory.
    pub fn init(path: []const u8) !PeakCounter {
        var dir = try std.fs.cwd().openDir(path, .{});
        defer dir.close();
        const file = try dir.openFile("memory.peak", .{ .mode = .read_write });
        return .{ .fd = file.handle };
    }

    /// Restarts the peak at the subtree's current usage for later reads
    /// through this descriptor; the kernel takes any non-empty write as a
    /// reset, whatever its value.
    pub fn reset(self: *PeakCounter) !void {
        const written = try std.posix.pwrite(self.fd, "0", 0);
        if (written != 1) return error.ShortWrite;
    }

    /// The subtree's highest usage in bytes since the last `reset`, or since
    /// the cgroup was created when this descriptor was never reset.
    pub fn read(self: *const PeakCounter) !u64 {
        var buffer: [scalar_file_bytes_max + 1]u8 = undefined;
        return parseScalar(try readBounded(self.fd, &buffer));
    }

    pub fn deinit(self: *PeakCounter) void {
        std.posix.close(self.fd);
        self.* = undefined;
    }
};

/// `after - before` as a signed value. The subtraction runs in 128 bits, so
/// two values above the i64 range still give their difference; only a
/// difference outside i64 fails with `error.Overflow`.
pub fn signedDelta(after: u64, before: u64) error{Overflow}!i64 {
    return std.math.cast(i64, @as(i128, after) - @as(i128, before)) orelse error.Overflow;
}

/// `(after - before) / count`, rounded toward zero. The division runs before
/// narrowing to i64, so only a quotient outside i64 fails with
/// `error.Overflow`; a zero `count` fails with `error.InvalidCount`.
pub fn amortizedDelta(after: u64, before: u64, count: u64) error{ Overflow, InvalidCount }!i64 {
    if (count == 0) return error.InvalidCount;
    const delta = @as(i128, after) - @as(i128, before);
    return std.math.cast(i64, @divTrunc(delta, @as(i128, count))) orelse error.Overflow;
}

const Field = struct { key: []const u8, field: []const u8 };
const Unit = enum { scalar, kib };

const process_fields = [_]Field{
    .{ .key = "Rss:", .field = "rss_bytes" },
    .{ .key = "Pss:", .field = "pss_bytes" },
    .{ .key = "Shared_Clean:", .field = "shared_clean_bytes" },
    .{ .key = "Shared_Dirty:", .field = "shared_dirty_bytes" },
    .{ .key = "Private_Clean:", .field = "private_clean_bytes" },
    .{ .key = "Private_Dirty:", .field = "private_dirty_bytes" },
    .{ .key = "Swap:", .field = "swap_bytes" },
};

const stat_fields = [_]Field{
    .{ .key = "anon", .field = "anon_bytes" },
    .{ .key = "file", .field = "file_bytes" },
    .{ .key = "kernel", .field = "kernel_bytes" },
    .{ .key = "shmem", .field = "shmem_bytes" },
    .{ .key = "pagetables", .field = "pagetables_bytes" },
    .{ .key = "kernel_stack", .field = "kernel_stack_bytes" },
    .{ .key = "slab", .field = "slab_bytes" },
};

const events_fields = [_]Field{
    .{ .key = "low", .field = "low" },
    .{ .key = "high", .field = "high" },
    .{ .key = "max", .field = "max" },
    .{ .key = "oom", .field = "oom" },
    .{ .key = "oom_kill", .field = "oom_kill" },
};

fn parseFields(
    comptime T: type,
    comptime fields: []const Field,
    contents: []const u8,
    comptime unit: Unit,
) ParseError!T {
    if (contents.len > snapshot_file_bytes_max) return error.InputTooLarge;
    comptime std.debug.assert(fields.len == @typeInfo(T).@"struct".fields.len);
    var result: T = undefined;
    var seen: [fields.len]bool = @splat(false);
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        var tokens = std.mem.tokenizeAny(u8, line, &std.ascii.whitespace);
        const key = tokens.next() orelse continue;
        inline for (fields, 0..) |field, index| {
            if (std.mem.eql(u8, key, field.key)) {
                if (seen[index]) return error.DuplicateField;
                const text = tokens.next() orelse return error.InvalidFormat;
                var value = try parseDecimal(text);
                if (unit == .kib) {
                    const suffix = tokens.next() orelse return error.InvalidUnit;
                    if (!std.mem.eql(u8, suffix, "kB")) return error.InvalidUnit;
                    value = try std.math.mul(u64, value, 1024);
                }
                if (tokens.next() != null) return error.InvalidFormat;
                @field(result, field.field) = value;
                seen[index] = true;
            }
        }
    }
    for (seen) |present| {
        if (!present) return error.MissingField;
    }
    return result;
}

fn parseDecimal(text: []const u8) error{ InvalidValue, Overflow }!u64 {
    if (text.len == 0) return error.InvalidValue;
    var value: u64 = 0;
    for (text) |character| {
        if (!std.ascii.isDigit(character)) return error.InvalidValue;
        value = try std.math.mul(u64, value, 10);
        value = try std.math.add(u64, value, character - '0');
    }
    return value;
}

fn parseScalar(contents: []const u8) ParseError!u64 {
    if (contents.len > scalar_file_bytes_max) return error.InputTooLarge;
    var tokens = std.mem.tokenizeAny(u8, contents, &std.ascii.whitespace);
    const value = tokens.next() orelse return error.InvalidFormat;
    if (tokens.next() != null) return error.InvalidFormat;
    return parseDecimal(value);
}

fn readScalarAt(dir: std.fs.Dir, name: []const u8) !u64 {
    var buffer: [scalar_file_bytes_max + 1]u8 = undefined;
    return parseScalar(try readAt(dir, name, &buffer));
}

fn readAt(dir: std.fs.Dir, name: []const u8, buffer: []u8) ![]const u8 {
    const file = try dir.openFile(name, .{});
    defer file.close();
    return readBounded(file.handle, buffer);
}

/// Reads the whole file from offset zero into `buffer`, whose last byte only
/// detects a file longer than the caller's bound, even one whose excess starts
/// on a line boundary; such a file fails with `error.InputTooLarge`. Every
/// read is positional, so the long-lived `PeakCounter` descriptor yields the
/// whole value each time instead of the end of file a second sequential read
/// would hit.
fn readBounded(fd: std.posix.fd_t, buffer: []u8) ![]const u8 {
    std.debug.assert(buffer.len > 1);
    var length: usize = 0;
    while (length < buffer.len) {
        const count = try std.posix.pread(fd, buffer[length..], @intCast(length));
        if (count == 0) return buffer[0..length];
        length += count;
    }
    return error.InputTooLarge;
}
