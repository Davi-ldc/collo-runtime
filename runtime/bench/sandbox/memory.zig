//! Readers and parsers for the Linux counters the benchmark's controller
//! samples: a process's `smaps_rollup`, its shared regions from `smaps`, its
//! tasks' context switches, and a cgroup's memory and CPU files. Every read
//! is bounded, and a file longer than its bound is an error, never a
//! truncated value.
//!
//! Process counters describe mapped resident pages; a shared page counts in
//! full toward each mapper's RSS and in proportion toward its PSS. Cgroup
//! counters describe charges to the whole subtree, including accounted kernel
//! memory. Neither is an atomic snapshot across processes or files, and
//! charges already made stay with their cgroup when a process moves to
//! another one. A shared region's pages are charged as shmem to the cgroup of
//! the process that first touched each page, whichever process maps it now.

const std = @import("std");

/// Longest input the parsers accept, and the read bound of `smaps_rollup` and
/// `memory.stat`.
pub const snapshot_file_bytes_max: usize = 64 * 1024;
const scalar_file_bytes_max: usize = 64;
const events_file_bytes_max: usize = 4096;
/// Read bound of a task's `status` and of a cgroup's `cpu.stat`.
const status_file_bytes_max: usize = 8 * 1024;
/// Tasks one measured process may have. A worker starts every thread it
/// will ever have before its seccomp filter, a handful in all.
pub const tasks_max: u32 = 256;

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

/// A cgroup's `cpu.stat` times, in microseconds, over its whole subtree. The
/// file has them whether or not the cpu controller is enabled.
pub const CpuStat = struct {
    usage_usec: u64,
    user_usec: u64,
    system_usec: u64,
};

/// One task's context switches, from its `status`.
pub const TaskSwitches = struct {
    voluntary: u64,
    nonvoluntary: u64,
};

/// The context switches of every task of a process, summed, and how many
/// tasks they came from. A task that exits takes its counts with it, so two
/// readings compare only while the task count holds.
pub const ProcessSwitches = struct {
    tasks: u32,
    voluntary: u64,
    nonvoluntary: u64,

    pub fn total(self: ProcessSwitches) error{Overflow}!u64 {
        return std.math.add(u64, self.voluntary, self.nonvoluntary);
    }
};

/// Parses `cpu.stat`. Unknown keys are ignored; every field of `CpuStat`
/// must appear exactly once.
pub fn parseCpuStat(contents: []const u8) ParseError!CpuStat {
    return parseFields(CpuStat, &cpu_fields, contents, .scalar);
}

/// Parses a task's `status`. Unknown keys are ignored; both switch counters
/// must appear exactly once.
pub fn parseTaskStatus(contents: []const u8) ParseError!TaskSwitches {
    return parseFields(TaskSwitches, &task_fields, contents, .scalar);
}

/// Reads `cpu.stat` of the cgroup directory at `path`.
pub fn readCpuStat(path: []const u8) !CpuStat {
    var dir = try std.fs.cwd().openDir(path, .{});
    defer dir.close();
    var buffer: [status_file_bytes_max + 1]u8 = undefined;
    return parseCpuStat(try readAt(dir, "cpu.stat", &buffer));
}

/// Sums the switch counters of every task in `/proc/<pid>/task`. A task that
/// exits between the listing and its read is gone and is not counted. More
/// than `tasks_max` tasks fail with `error.TooManyTasks`.
pub fn readProcessSwitches(pid: u32) !ProcessSwitches {
    if (pid == 0) return error.InvalidProcessId;
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}/task", .{pid});
    var dir = try std.fs.openDirAbsolute(path, .{ .iterate = true });
    defer dir.close();
    var result: ProcessSwitches = .{ .tasks = 0, .voluntary = 0, .nonvoluntary = 0 };
    var entries = dir.iterate();
    while (try entries.next()) |entry| {
        if (result.tasks == tasks_max) return error.TooManyTasks;
        var status_path: [64]u8 = undefined;
        const status = try std.fmt.bufPrint(&status_path, "{s}/status", .{entry.name});
        var buffer: [status_file_bytes_max + 1]u8 = undefined;
        const contents = readAt(dir, status, &buffer) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        const switches = try parseTaskStatus(contents);
        result.voluntary = try std.math.add(u64, result.voluntary, switches.voluntary);
        result.nonvoluntary = try std.math.add(u64, result.nonvoluntary, switches.nonvoluntary);
        result.tasks += 1;
    }
    return result;
}

/// The mappings `parseRegionMappings` keeps: every memfd the runtime creates
/// is named `collo-<region>`, and the kernel shows a memfd mapping's path as
/// `/memfd:<name>`, followed by ` (deleted)` since a memfd has no directory
/// entry.
pub const region_path_prefix = "/memfd:collo-";
const memfd_path_prefix = "/memfd:";
const deleted_suffix = " (deleted)";
/// Region mappings one process may hold. The server maps the state page and
/// the ingress rings of every worker, and the gateway the egress rings of
/// every session, so the bound leaves room for every sampler route's worker
/// many times over.
pub const region_mappings_max: usize = 4096;
/// Distinct region names one process may map.
pub const region_names_max: usize = 64;
pub const region_name_bytes_max: usize = 64;
/// Longest `smaps` line the reader takes: a mapping header whose path is as
/// long as a path can be, after the fixed columns.
pub const smaps_line_bytes_max: usize = std.fs.max_path_bytes + 128;
/// Lines one `smaps` may hold.
const smaps_lines_max: usize = 1 << 22;

/// A region's memfd name without the `/memfd:` prefix, such as
/// `collo-shared-metrics`; it serializes as a JSON string.
pub const RegionName = struct {
    bytes: [region_name_bytes_max]u8,
    len: u8,

    pub fn init(text: []const u8) error{RegionNameTooLong}!RegionName {
        if (text.len > region_name_bytes_max) return error.RegionNameTooLong;
        var name: RegionName = .{ .bytes = @splat(0), .len = @intCast(text.len) };
        @memcpy(name.bytes[0..text.len], text);
        return name;
    }

    pub fn slice(self: *const RegionName) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn jsonStringify(self: RegionName, writer: anytype) !void {
        try writer.write(self.bytes[0..self.len]);
    }
};

/// One mapping of a region, with its `smaps` counters in bytes.
pub const RegionMapping = struct {
    name: RegionName,
    start: u64,
    end: u64,
    device_major: u32,
    device_minor: u32,
    inode: u64,
    size_bytes: u64,
    rss_bytes: u64,
    pss_bytes: u64,
    shared_dirty_bytes: u64,
    private_dirty_bytes: u64,

    /// Whether both map the same memfd: one region mapped twice, or by two
    /// processes.
    pub fn sameFile(self: RegionMapping, other: RegionMapping) bool {
        return self.inode == other.inode and self.device_major == other.device_major and
            self.device_minor == other.device_minor;
    }
};

/// One region name's mappings in one process, summed per counter. The
/// counters are summed only with themselves: RSS, PSS and the dirty counts
/// answer different questions and are never added together.
pub const RegionTotals = struct {
    name: RegionName,
    mappings: u32,
    /// Distinct memfds behind those mappings.
    files: u32,
    size_bytes: u64,
    rss_bytes: u64,
    pss_bytes: u64,
    shared_dirty_bytes: u64,
    private_dirty_bytes: u64,
    /// The pages the memfds hold, `st_blocks` × 512, whoever touched them,
    /// counted once per memfd however often it is mapped.
    allocated_bytes: u64,
};

/// The per-name totals of one process's region mappings. Keep it in place:
/// `items` points into it.
pub const RegionTable = struct {
    rows: [region_names_max]RegionTotals,
    len: usize,

    pub const empty: RegionTable = .{ .rows = undefined, .len = 0 };

    pub fn items(self: *const RegionTable) []const RegionTotals {
        return self.rows[0..self.len];
    }

    /// Replaces the rows with the totals of `mappings`. `allocated_bytes[i]`
    /// is the allocation of the memfd behind `mappings[i]`
    /// (`readRegionAllocations`). With `within`, only the mappings of a memfd
    /// some mapping of `within` also maps count: the server's or the
    /// gateway's share of one worker's regions.
    pub fn tabulate(
        self: *RegionTable,
        mappings: []const RegionMapping,
        allocated_bytes: []const u64,
        within: ?[]const RegionMapping,
    ) error{ TooManyRegions, Overflow }!void {
        std.debug.assert(allocated_bytes.len == mappings.len);
        self.len = 0;
        for (mappings, 0..) |mapping, index| {
            if (within) |set| {
                if (!mapsFile(set, mapping)) continue;
            }
            const totals = try self.rowOf(mapping.name);
            totals.mappings += 1;
            totals.size_bytes = try std.math.add(u64, totals.size_bytes, mapping.size_bytes);
            totals.rss_bytes = try std.math.add(u64, totals.rss_bytes, mapping.rss_bytes);
            totals.pss_bytes = try std.math.add(u64, totals.pss_bytes, mapping.pss_bytes);
            totals.shared_dirty_bytes = try std.math.add(u64, totals.shared_dirty_bytes, mapping.shared_dirty_bytes);
            totals.private_dirty_bytes = try std.math.add(u64, totals.private_dirty_bytes, mapping.private_dirty_bytes);
            // A memfd mapped twice holds its pages once.
            if (!mapsFile(mappings[0..index], mapping)) {
                totals.files += 1;
                totals.allocated_bytes = try std.math.add(u64, totals.allocated_bytes, allocated_bytes[index]);
            }
        }
    }

    fn rowOf(self: *RegionTable, name: RegionName) error{TooManyRegions}!*RegionTotals {
        for (self.rows[0..self.len]) |*existing| {
            if (std.mem.eql(u8, existing.name.slice(), name.slice())) return existing;
        }
        if (self.len == self.rows.len) return error.TooManyRegions;
        self.rows[self.len] = .{
            .name = name,
            .mappings = 0,
            .files = 0,
            .size_bytes = 0,
            .rss_bytes = 0,
            .pss_bytes = 0,
            .shared_dirty_bytes = 0,
            .private_dirty_bytes = 0,
            .allocated_bytes = 0,
        };
        self.len += 1;
        return &self.rows[self.len - 1];
    }
};

/// Whether some mapping of `mappings` maps the memfd `candidate` maps.
pub fn mapsFile(mappings: []const RegionMapping, candidate: RegionMapping) bool {
    for (mappings) |mapping| {
        if (mapping.sameFile(candidate)) return true;
    }
    return false;
}

pub const RegionParseError = ParseError || error{
    TooManyRegionMappings,
    RegionNameTooLong,
    ReadFailed,
    StreamTooLong,
};

/// Reads `smaps` text from `reader` and writes into `out` every mapping
/// whose path starts with `region_path_prefix`, in file order, returning the
/// filled part. Each such mapping needs `Size`, `Rss`, `Pss`, `Shared_Dirty`
/// and `Private_Dirty` exactly once, in kB; the fields of other mappings are
/// skipped. A mapping header is a line whose first token is not a `Key:`.
pub fn parseRegionMappings(reader: *std.Io.Reader, out: []RegionMapping) RegionParseError![]RegionMapping {
    var count: usize = 0;
    var pending: ?PendingRegion = null;
    var lines: usize = 0;
    while (try reader.takeDelimiter('\n')) |line| {
        if (lines == smaps_lines_max) return error.InputTooLarge;
        lines += 1;
        var tokens = std.mem.tokenizeAny(u8, line, &std.ascii.whitespace);
        const first = tokens.next() orelse continue;
        if (std.mem.endsWith(u8, first, ":")) {
            if (pending) |*region| try region.readField(first, &tokens);
            continue;
        }
        // A header ends the mapping before it.
        if (pending) |*region| {
            if (count == out.len) return error.TooManyRegionMappings;
            out[count] = try region.finish();
            count += 1;
        }
        pending = try parseMappingHeader(first, &tokens);
    }
    if (pending) |*region| {
        if (count == out.len) return error.TooManyRegionMappings;
        out[count] = try region.finish();
        count += 1;
    }
    return out[0..count];
}

/// Reads the region mappings of `/proc/<pid>/smaps` into `out`.
pub fn readRegionMappings(pid: u32, out: []RegionMapping) ![]RegionMapping {
    if (pid == 0) return error.InvalidProcessId;
    var path_buffer: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}/smaps", .{pid});
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    var buffer: [smaps_line_bytes_max + 1]u8 = undefined;
    var reader = file.readerStreaming(&buffer);
    return parseRegionMappings(&reader.interface, out) catch |err| switch (err) {
        error.ReadFailed => return reader.err orelse error.ReadFailed,
        else => |other| return other,
    };
}

/// The allocation of the memfd behind `mapping` of process `pid`, from
/// `fstat` of `/proc/<pid>/map_files/<start>-<end>`, which needs
/// CAP_SYS_ADMIN. A mapping that now names another file fails with
/// `error.RegionFileChanged`.
pub fn readRegionAllocation(pid: u32, mapping: RegionMapping) !u64 {
    if (pid == 0) return error.InvalidProcessId;
    var path_buffer: [96]u8 = undefined;
    // The kernel names these entries `%lx-%lx`: lowercase hex, unpadded.
    const path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}/map_files/{x}-{x}", .{
        pid, mapping.start, mapping.end,
    });
    const stat = try std.posix.fstatat(std.posix.AT.FDCWD, path, 0);
    if (stat.ino != mapping.inode) return error.RegionFileChanged;
    const blocks = std.math.cast(u64, stat.blocks) orelse return error.InvalidValue;
    return std.math.mul(u64, blocks, 512);
}

/// Fills `allocated_bytes[i]` with the allocation of the memfd behind
/// `mappings[i]`, reading each memfd once.
pub fn readRegionAllocations(pid: u32, mappings: []const RegionMapping, allocated_bytes: []u64) !void {
    std.debug.assert(allocated_bytes.len == mappings.len);
    for (mappings, 0..) |mapping, index| {
        allocated_bytes[index] = for (mappings[0..index], 0..) |earlier, earlier_index| {
            if (earlier.sameFile(mapping)) break allocated_bytes[earlier_index];
        } else try readRegionAllocation(pid, mapping);
    }
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

const cpu_fields = [_]Field{
    .{ .key = "usage_usec", .field = "usage_usec" },
    .{ .key = "user_usec", .field = "user_usec" },
    .{ .key = "system_usec", .field = "system_usec" },
};

const task_fields = [_]Field{
    .{ .key = "voluntary_ctxt_switches:", .field = "voluntary" },
    .{ .key = "nonvoluntary_ctxt_switches:", .field = "nonvoluntary" },
};

const region_fields = [_]Field{
    .{ .key = "Size:", .field = "size_bytes" },
    .{ .key = "Rss:", .field = "rss_bytes" },
    .{ .key = "Pss:", .field = "pss_bytes" },
    .{ .key = "Shared_Dirty:", .field = "shared_dirty_bytes" },
    .{ .key = "Private_Dirty:", .field = "private_dirty_bytes" },
};

const Tokens = std.mem.TokenIterator(u8, .any);

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
                @field(result, field.field) = try parseValue(&tokens, unit);
                seen[index] = true;
            }
        }
    }
    for (seen) |present| {
        if (!present) return error.MissingField;
    }
    return result;
}

/// The value after a key: one decimal, then a `kB` unit for `.kib`, and
/// nothing more on the line.
fn parseValue(tokens: *Tokens, comptime unit: Unit) ParseError!u64 {
    const text = tokens.next() orelse return error.InvalidFormat;
    var value = try parseDecimal(text);
    if (unit == .kib) {
        const suffix = tokens.next() orelse return error.InvalidUnit;
        if (!std.mem.eql(u8, suffix, "kB")) return error.InvalidUnit;
        value = try std.math.mul(u64, value, 1024);
    }
    if (tokens.next() != null) return error.InvalidFormat;
    return value;
}

/// A region mapping whose header has been read and whose fields are being
/// read.
const PendingRegion = struct {
    mapping: RegionMapping,
    seen: [region_fields.len]bool = @splat(false),

    fn readField(self: *PendingRegion, key: []const u8, tokens: *Tokens) ParseError!void {
        inline for (region_fields, 0..) |field, index| {
            if (std.mem.eql(u8, key, field.key)) {
                if (self.seen[index]) return error.DuplicateField;
                @field(self.mapping, field.field) = try parseValue(tokens, .kib);
                self.seen[index] = true;
            }
        }
    }

    fn finish(self: *const PendingRegion) ParseError!RegionMapping {
        for (self.seen) |present| {
            if (!present) return error.MissingField;
        }
        return self.mapping;
    }
};

/// Reads a mapping header, `start-end perms offset major:minor inode
/// [path]`, whose first token is `range`. Returns null for a mapping that is
/// not a region.
fn parseMappingHeader(range: []const u8, tokens: *Tokens) (ParseError || error{RegionNameTooLong})!?PendingRegion {
    const dash = std.mem.indexOfScalar(u8, range, '-') orelse return error.InvalidFormat;
    const start = try parseHexadecimal(u64, range[0..dash]);
    const end = try parseHexadecimal(u64, range[dash + 1 ..]);
    if (end <= start) return error.InvalidFormat;
    _ = tokens.next() orelse return error.InvalidFormat; // permissions
    _ = tokens.next() orelse return error.InvalidFormat; // offset
    const device = tokens.next() orelse return error.InvalidFormat;
    const inode = tokens.next() orelse return error.InvalidFormat;
    const path = std.mem.trimRight(u8, tokens.rest(), &std.ascii.whitespace);
    if (!std.mem.startsWith(u8, path, region_path_prefix)) return null;
    var name = path[memfd_path_prefix.len..];
    if (std.mem.endsWith(u8, name, deleted_suffix)) name = name[0 .. name.len - deleted_suffix.len];
    const colon = std.mem.indexOfScalar(u8, device, ':') orelse return error.InvalidFormat;
    return .{ .mapping = .{
        .name = try RegionName.init(name),
        .start = start,
        .end = end,
        .device_major = try parseHexadecimal(u32, device[0..colon]),
        .device_minor = try parseHexadecimal(u32, device[colon + 1 ..]),
        .inode = try parseDecimal(inode),
        .size_bytes = 0,
        .rss_bytes = 0,
        .pss_bytes = 0,
        .shared_dirty_bytes = 0,
        .private_dirty_bytes = 0,
    } };
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

/// Lowercase or uppercase hex digits only, as `smaps` prints addresses and
/// device numbers.
fn parseHexadecimal(comptime T: type, text: []const u8) error{ InvalidValue, Overflow }!T {
    if (text.len == 0) return error.InvalidValue;
    var value: T = 0;
    for (text) |character| {
        const digit = std.fmt.charToDigit(character, 16) catch return error.InvalidValue;
        value = try std.math.mul(T, value, 16);
        value = try std.math.add(T, value, digit);
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
