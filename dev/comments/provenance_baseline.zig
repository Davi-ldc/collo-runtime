//! `provenance-baseline` keeps the baseline of the comment provenance gate in
//! step with the comments it guards. It runs from the repository root, which
//! `zig build provenance-baseline` arranges, and replaces the baseline through
//! an atomic rename, so the gate never reads a partly written file.
//!
//!   (no argument)  Rewrites the baseline with the current marker counts and
//!                  drops files that reached zero. When any file holds more
//!                  markers than its entry allows, it lists them and writes
//!                  nothing: the baseline only goes down.
//!   --list         Prints every marker under the scan roots with its location.
//!   --init         Writes the first baseline; refuses when one exists.
//!
//! Exit status: 0 on success, 1 when a count would rise or a baseline already
//! exists, 2 on bad usage, a missing or malformed baseline, one that lists a
//! path twice, or any other error such as failed I/O or exhausted memory.
const std = @import("std");
const comments = @import("root.zig");
const provenance = comments.provenance;

const usage =
    \\usage: provenance-baseline [--list | --init]
    \\  Run from the repository root. Without arguments, lowers the baseline to
    \\  the current marker counts and refuses to raise any count.
    \\
;

const Mode = enum { lower, list, init };

const Status = enum(u8) {
    done = 0,
    refused = 1,
    failed = 2,
};

pub fn main() !u8 {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const out = &stdout_writer.interface;
    const status = run(gpa, args, out) catch |err| status: {
        try out.print("provenance-baseline: {s}\n", .{@errorName(err)});
        break :status .failed;
    };
    try out.flush();
    return @intFromEnum(status);
}

fn run(gpa: std.mem.Allocator, args: []const []const u8, out: *std.Io.Writer) !Status {
    const mode = parseMode(args) orelse {
        try out.writeAll(usage);
        return .failed;
    };
    const repository = std.fs.cwd();
    const current = try provenance.countRepository(gpa, repository);
    defer current.deinit(gpa);
    return switch (mode) {
        .list => list(gpa, repository, current, out),
        .init => initialize(repository, current, out),
        .lower => lower(gpa, repository, current, out),
    };
}

fn parseMode(args: []const []const u8) ?Mode {
    if (args.len == 1) return .lower;
    if (args.len != 2) return null;
    if (std.mem.eql(u8, args[1], "--list")) return .list;
    if (std.mem.eql(u8, args[1], "--init")) return .init;
    return null;
}

fn list(gpa: std.mem.Allocator, repository: std.fs.Dir, current: provenance.Counts, out: *std.Io.Writer) !Status {
    for (current.files) |file| try provenance.writeFileMarkers(gpa, repository, file.path, out);
    try out.print("{f}\n", .{provenance.Totals.of(current.files)});
    return .done;
}

fn initialize(repository: std.fs.Dir, current: provenance.Counts, out: *std.Io.Writer) !Status {
    if (repository.access(provenance.baseline_path, .{})) {
        try out.print("{s} exists; run without arguments to lower it\n", .{provenance.baseline_path});
        return .refused;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    try writeBaselineFile(repository, current.files);
    try out.print("wrote {s}: {f}\n", .{ provenance.baseline_path, provenance.Totals.of(current.files) });
    return .done;
}

fn lower(gpa: std.mem.Allocator, repository: std.fs.Dir, current: provenance.Counts, out: *std.Io.Writer) !Status {
    const baseline = provenance.readBaseline(gpa, repository, out) catch |err| switch (err) {
        error.ParseZon => return .failed,
        error.FileNotFound => {
            try out.print("{s} does not exist; --init writes the first one\n", .{provenance.baseline_path});
            return .failed;
        },
        else => return err,
    };
    defer baseline.deinit(gpa);
    const excess = provenance.findExcess(gpa, baseline.files, current.files) catch |err| switch (err) {
        error.DuplicateBaselineEntry => {
            try out.print("{s} lists a path twice; keep one entry per path\n", .{provenance.baseline_path});
            return .failed;
        },
        else => return err,
    };
    defer gpa.free(excess);

    if (excess.len > 0) {
        for (excess) |file| {
            try out.print("{s}: {d} {s}, the baseline allows {d}\n", .{
                file.path, file.markers, provenance.noun(file.markers, "marker"), file.allowed,
            });
            try provenance.writeFileMarkers(gpa, repository, file.path, out);
        }
        try out.writeAll(
            \\refused: the baseline only goes down. Rewrite the comments listed above
            \\so they state constraints and invariants, then run this step again.
            \\
        );
        return .refused;
    }

    const previous = provenance.Totals.of(baseline.files);
    const now = provenance.Totals.of(current.files);
    if (previous.markers == now.markers and previous.files == now.files) {
        try out.print("{s} already matches: {f}\n", .{ provenance.baseline_path, now });
        return .done;
    }
    try writeBaselineFile(repository, current.files);
    try out.print("lowered {s} from {f} to {f}\n", .{ provenance.baseline_path, previous, now });
    return .done;
}

fn writeBaselineFile(repository: std.fs.Dir, files: []const provenance.FileCount) !void {
    var buffer: [4096]u8 = undefined;
    var atomic = try repository.atomicFile(provenance.baseline_path, .{ .write_buffer = &buffer });
    defer atomic.deinit();
    try provenance.writeBaseline(&atomic.file_writer.interface, files);
    try atomic.finish();
}
