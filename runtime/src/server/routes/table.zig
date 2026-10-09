//! The route table: one trie built at boot from the configuration's routes
//! that maps a request path to the route serving it, the route's pattern
//! and the path's captures, without allocating. The table has no Host or
//! SNI key; the path alone selects the route.
//!
//! Patterns follow the grammar in `server/config/pattern.zig`. At every
//! level a static child is tried before the parameter child, and the
//! wildcard of the node is the fallback when both fail, so `/users/me` wins
//! over `/users/:id`, which wins over `/users/*`. A wildcard matches the
//! rest of the path including an empty rest, and a node's own route wins
//! over its wildcard at the end of the path, so `/` and `/*` together give
//! the root to `/`.
//!
//! Bounds against adversarial paths:
//! - a request path deeper than `path_segments_max` fails with
//!   `error.PathTooDeep` before the walk starts;
//! - every trie node has one parent and is entered only at the path depth
//!   it sits at, so one lookup enters each node at most once and the walk is
//!   bounded by the node count, at most `node_count_max`. `match_visits_max`
//!   restates that bound as a counter: a walk that reaches it ends as a miss
//!   rather than as a less specific match.
//!
//! The table owns its entries and nodes, allocated from the allocator given
//! to `init` and returned by `deinit`. Entry patterns and the keys of static
//! children borrow the configuration's bytes, so the configuration must
//! outlive the table. Once `init` returns nothing mutates the table, and any
//! number of threads may call `match` at once.

const std = @import("std");
const ipc = @import("collo_ipc");
const config = @import("collo_server_config");
const server_limits = @import("collo_limits").server;

const route_pattern = config.pattern;

/// A capture names its pattern segment and holds the request path segment
/// it matched; it is the dispatch message's own capture type, so a match
/// feeds `DispatchWork` without a copy.
pub const RouteCapture = ipc.RouteCapture;

pub const path_segments_max = server_limits.route_path_segments_max;

/// The root plus at most one node per pattern segment of every route.
pub const node_count_max: usize = 1 + server_limits.routes_max * path_segments_max;

pub const match_visits_max: usize = node_count_max;

/// Caller storage for the captures of one match. A matched pattern has at
/// most one parameter per request path segment, and the path has at most
/// `path_segments_max` segments, so the array always holds them.
pub const Captures = [path_segments_max]RouteCapture;

pub const Entry = struct {
    key: config.RouteKey,
    /// Borrowed from the configuration.
    pattern: []const u8,
};

pub const Match = struct {
    key: config.RouteKey,
    /// The matched route's pattern, borrowed from the configuration; the
    /// access log records it as the route.
    pattern: []const u8,
    /// A prefix of the caller's `Captures`. Names borrow the pattern and
    /// values borrow the request path, so the match is valid while both are.
    captures: []const RouteCapture,
};

pub const InitError = error{
    OutOfMemory,
    InvalidRoutePattern,
    DuplicateRoute,
    TooManyRoutes,
};

pub const MatchError = error{PathTooDeep};

pub const Table = struct {
    entries: []Entry,
    nodes: []Node,

    /// Builds the table from `definitions`, every route of every
    /// definition, with route keys in configuration order. A configuration
    /// the parser accepted never fails here except on memory; the other
    /// errors guard a hand-built definition list.
    pub fn init(
        target: *Table,
        gpa: std.mem.Allocator,
        definitions: []const config.WorkerDefinition,
    ) InitError!void {
        var route_count: usize = 0;
        for (definitions) |definition|
            route_count += definition.routes.len;
        if (definitions.len > server_limits.worker_definitions_max or route_count > server_limits.routes_max)
            return error.TooManyRoutes;

        var nodes: std.ArrayList(Node) = .empty;
        errdefer {
            for (nodes.items) |*node|
                node.deinit(gpa);
            nodes.deinit(gpa);
        }
        try nodes.append(gpa, .{});

        const entries = try gpa.alloc(Entry, route_count);
        errdefer gpa.free(entries);
        var entry_index: u32 = 0;
        for (definitions, 0..) |definition, definition_index| {
            if (definition.routes.len > server_limits.routes_per_definition_max)
                return error.TooManyRoutes;
            for (definition.routes, 0..) |route, route_index| {
                if (route_pattern.validate(route.pattern) != null)
                    return error.InvalidRoutePattern;
                entries[entry_index] = .{
                    .key = .{
                        .definition = @intCast(definition_index),
                        .route = @intCast(route_index),
                    },
                    .pattern = route.pattern,
                };
                try insert(gpa, &nodes, route.pattern, entry_index);
                entry_index += 1;
            }
        }
        std.debug.assert(entry_index == route_count);
        std.debug.assert(nodes.items.len <= node_count_max);
        target.* = .{
            .entries = entries,
            .nodes = try nodes.toOwnedSlice(gpa),
        };
    }

    pub fn deinit(self: *Table, gpa: std.mem.Allocator) void {
        for (self.nodes) |*node|
            node.deinit(gpa);
        gpa.free(self.nodes);
        gpa.free(self.entries);
        self.* = undefined;
    }

    /// The route serving `path`, or null when none matches. `path` is the
    /// request path without its query; empty segments are skipped. The
    /// captures land in `captures`.
    pub fn match(self: *const Table, path: []const u8, captures: *Captures) MatchError!?Match {
        var path_segments: [path_segments_max][]const u8 = undefined;
        var segment_count: usize = 0;
        var tokens = std.mem.tokenizeScalar(u8, path, '/');
        while (tokens.next()) |segment| {
            if (segment_count == path_segments_max)
                return error.PathTooDeep;
            path_segments[segment_count] = segment;
            segment_count += 1;
        }

        var walk: Walk = .{ .segments = path_segments[0..segment_count] };
        const entry_index = self.matchNode(&walk, 0, 0) orelse return null;
        if (walk.exhausted)
            return null;
        const entry = self.entries[entry_index];
        const capture_count = fillCaptures(captures, entry.pattern, walk.segments);
        return .{
            .key = entry.key,
            .pattern = entry.pattern,
            .captures = captures[0..capture_count],
        };
    }

    fn matchNode(self: *const Table, walk: *Walk, node_index: u32, path_index: usize) ?u32 {
        if (walk.visits == match_visits_max) {
            walk.exhausted = true;
            return null;
        }
        walk.visits += 1;

        const node = &self.nodes[node_index];
        if (path_index == walk.segments.len) {
            if (node.terminal_entry) |entry_index|
                return entry_index;
            return node.wildcard_entry;
        }

        const segment = walk.segments[path_index];
        if (node.static_children.get(segment)) |child_index| {
            if (self.matchNode(walk, child_index, path_index + 1)) |entry_index|
                return entry_index;
        }
        if (node.param_child) |child_index| {
            if (self.matchNode(walk, child_index, path_index + 1)) |entry_index|
                return entry_index;
        }
        if (walk.exhausted)
            return null;
        return node.wildcard_entry;
    }
};

const Walk = struct {
    segments: []const []const u8,
    visits: usize = 0,
    exhausted: bool = false,
};

const Node = struct {
    /// Keys borrow pattern bytes from the configuration.
    static_children: std.StringHashMapUnmanaged(u32) = .empty,
    param_child: ?u32 = null,
    wildcard_entry: ?u32 = null,
    terminal_entry: ?u32 = null,

    fn deinit(self: *Node, gpa: std.mem.Allocator) void {
        self.static_children.deinit(gpa);
        self.* = undefined;
    }
};

/// Walks `nodes` by index, never by pointer, because appending a child may
/// move the array.
fn insert(gpa: std.mem.Allocator, nodes: *std.ArrayList(Node), pattern: []const u8, entry_index: u32) InitError!void {
    var node_index: u32 = 0;
    var segments = route_pattern.segments(pattern);
    while (segments.next()) |segment| {
        switch (segment) {
            .wildcard => {
                if (nodes.items[node_index].wildcard_entry != null)
                    return error.DuplicateRoute;
                nodes.items[node_index].wildcard_entry = entry_index;
                return;
            },
            .param => {
                if (nodes.items[node_index].param_child) |child_index| {
                    node_index = child_index;
                } else {
                    const child_index = try appendNode(gpa, nodes);
                    nodes.items[node_index].param_child = child_index;
                    node_index = child_index;
                }
            },
            .static => |text| {
                if (nodes.items[node_index].static_children.get(text)) |child_index| {
                    node_index = child_index;
                } else {
                    const child_index = try appendNode(gpa, nodes);
                    try nodes.items[node_index].static_children.put(gpa, text, child_index);
                    node_index = child_index;
                }
            },
        }
    }
    if (nodes.items[node_index].terminal_entry != null)
        return error.DuplicateRoute;
    nodes.items[node_index].terminal_entry = entry_index;
}

fn appendNode(gpa: std.mem.Allocator, nodes: *std.ArrayList(Node)) error{OutOfMemory}!u32 {
    const index: u32 = @intCast(nodes.items.len);
    try nodes.append(gpa, .{});
    return index;
}

/// Pairs each parameter segment of a matched pattern with the path segment
/// it consumed. The match guarantees one path segment per non-wildcard
/// pattern segment, so the walk never runs past either list.
fn fillCaptures(captures: *Captures, pattern: []const u8, path_segments: []const []const u8) usize {
    var count: usize = 0;
    var path_index: usize = 0;
    var segments = route_pattern.segments(pattern);
    while (segments.next()) |segment| {
        switch (segment) {
            .wildcard => break,
            .param => |name| {
                std.debug.assert(path_index < path_segments.len);
                captures[count] = .{ .name = name, .value = path_segments[path_index] };
                count += 1;
            },
            .static => {},
        }
        path_index += 1;
    }
    return count;
}

comptime {
    std.debug.assert(path_segments_max == ipc.max_route_capture_count);
    std.debug.assert(node_count_max <= std.math.maxInt(u32));
}
