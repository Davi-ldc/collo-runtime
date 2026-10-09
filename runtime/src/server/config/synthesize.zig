//! The configuration `collo serve <entry>` runs when it is given an entry
//! module instead of a configuration file: one worker named after the
//! file's stem, with one route `/*` that matches every path, the entry's
//! absolute path, no bindings, and every global default. It is the same
//! `Config` the parser would build from the equivalent `collo.json`, so the
//! two forms boot and serve the same way.

const std = @import("std");
const server_limits = @import("collo_limits").server;
const model = @import("model.zig");
const parse = @import("parse.zig");
const Diagnostic = @import("diagnostic.zig").Diagnostic;

pub const Error = parse.Error;

/// The pattern of the synthesized route.
pub const route_pattern = "/*";

/// The name a stem with no usable byte falls back to.
pub const fallback_worker_name = "worker";

/// `entry_path` resolves against the working directory when relative; the
/// file is not opened here. The caller owns the result and calls `deinit`.
/// Fails with `error.InvalidConfig`, the reason in `diagnostic`, when the
/// path is empty or the working directory cannot be read.
pub fn synthesize(gpa: std.mem.Allocator, entry_path: []const u8, diagnostic: *Diagnostic) Error!model.Config {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    const absolute_entry = parse.absolutePath(allocator, entry_path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EmptyPath => {
            diagnostic.set("the entry module path is empty", .{});
            return error.InvalidConfig;
        },
        else => {
            diagnostic.set("{s}: cannot resolve the working directory: {s}", .{ entry_path, @errorName(err) });
            return error.InvalidConfig;
        },
    };

    const routes = try allocator.alloc(model.Route, 1);
    routes[0] = .{
        .pattern = try allocator.dupe(u8, route_pattern),
        .entry_path = absolute_entry,
        .bindings = &.{},
    };
    const definitions = try allocator.alloc(model.WorkerDefinition, 1);
    definitions[0] = .{
        .name = try workerName(allocator, absolute_entry),
        .settings = model.default_settings,
        .routes = routes,
    };
    return .{
        .arena = arena,
        .path = absolute_entry,
        .listen = parse.parseListen(model.default_listen) catch unreachable,
        .tls = null,
        .analytics = null,
        .defaults = model.default_settings,
        .definitions = definitions,
        .route_count = 1,
    };
}

/// The file's stem (its name without the last extension), lowercased, with
/// every byte outside `[a-z0-9-]` replaced by `-` and cut to
/// `worker_name_bytes_max`; `fallback_worker_name` when nothing is left.
pub fn workerName(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const base = std.fs.path.basename(path);
    const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot|
        (if (dot == 0) base else base[0..dot])
    else
        base;
    const length = @min(stem.len, server_limits.worker_name_bytes_max);
    if (length == 0)
        return allocator.dupe(u8, fallback_worker_name);
    const name = try allocator.alloc(u8, length);
    for (stem[0..length], name) |byte, *out| {
        const lower = std.ascii.toLower(byte);
        const valid = (lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9') or lower == '-';
        out.* = if (valid) lower else '-';
    }
    std.debug.assert(parse.isWorkerName(name));
    return name;
}
