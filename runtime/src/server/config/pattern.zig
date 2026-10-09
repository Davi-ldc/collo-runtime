//! The grammar of a route pattern, the key of a route in `collo.json`, and
//! the segment classification the route table (`server/routes/table.zig`)
//! builds its trie from, so the parser and the matcher read patterns the
//! same way.
//!
//! A pattern starts with `/` and splits on `/` into segments:
//! - a static segment matches the same request path segment byte for byte;
//! - `:name` matches any one segment and captures it under `name`;
//! - `*`, allowed only as the last segment, matches the rest of the path,
//!   including an empty rest, and captures nothing.
//!
//! `/` alone has no segments and matches only the root path, so `/*` is the
//! pattern that matches every path. Request paths are split on `/` with
//! empty segments dropped, which is why a pattern with an empty segment
//! (`//`, a trailing `/`) is rejected: it would match paths it does not
//! spell. Two patterns that differ only in parameter names match the same
//! paths, and `sameShape` is how the parser rejects the second one.
//!
//! The server keeps every path under `reserved_prefix` for itself
//! (`isReserved`). It answers such a path before it consults the route table
//! (`streamTarget` in `server/ingress/runner/admission.zig`): `health_path`
//! from its own state, every other one as not found. A pattern whose first
//! segment is the prefix's is rejected, so a configured route never names
//! one of those paths. A broader pattern such as `/*` stays valid and serves
//! every path outside the prefix, so a path the server answers later under
//! the prefix never takes one a route served.
//!
//! Pure functions over borrowed bytes; any thread may call them.

const std = @import("std");
const server_limits = @import("collo_limits").server;

/// The paths the server keeps for itself: no route pattern may start with
/// this segment, and no request under it reaches a route.
pub const reserved_prefix = "/__collo/";
/// The request path the server answers itself with its own state, with no
/// route involved.
pub const health_path = reserved_prefix ++ "healthz";

/// `reserved_prefix` without its slashes.
const reserved_segment = reserved_prefix[1 .. reserved_prefix.len - 1];

comptime {
    std.debug.assert(reserved_prefix[0] == '/');
    std.debug.assert(reserved_prefix[reserved_prefix.len - 1] == '/');
    std.debug.assert(std.mem.indexOfScalar(u8, reserved_segment, '/') == null);
}

pub const Segment = union(enum) {
    /// The segment's bytes, compared as they are.
    static: []const u8,
    /// The capture name, without the leading `:`.
    param: []const u8,
    wildcard,
};

/// Why `validate` rejected a pattern.
pub const Problem = enum {
    missing_leading_slash,
    too_long,
    empty_segment,
    too_many_segments,
    wildcard_not_last,
    partial_wildcard,
    invalid_param_name,
    duplicate_param_name,
    dot_segment,
    invalid_character,
    reserved_prefix,

    pub fn describe(problem: Problem) []const u8 {
        return switch (problem) {
            .missing_leading_slash => "a route pattern must start with '/'",
            .too_long => "the route pattern is too long",
            .empty_segment => "a route pattern cannot contain an empty segment ('//' or a trailing '/')",
            .too_many_segments => "the route pattern has too many segments",
            .wildcard_not_last => "'*' is allowed only as the last segment",
            .partial_wildcard => "'*' must be a whole segment",
            .invalid_param_name => "a parameter segment must be ':' followed by a name matching [A-Za-z_][A-Za-z0-9_]*",
            .duplicate_param_name => "two parameter segments share a name",
            .dot_segment => "'.' and '..' are not valid route segments",
            .invalid_character => "a route segment may hold only printable ASCII other than '?', '#' and '\\'",
            .reserved_prefix => "the server keeps the paths under " ++ reserved_prefix ++ " for itself, such as " ++ health_path ++ ", so no route may use them",
        };
    }
};

pub const SegmentIterator = struct {
    tokens: std.mem.TokenIterator(u8, .scalar),

    pub fn next(self: *SegmentIterator) ?Segment {
        const raw = self.tokens.next() orelse return null;
        return classify(raw);
    }
};

/// Segments of a pattern `validate` accepted. On other input the
/// classification is still defined but means nothing.
pub fn segments(pattern: []const u8) SegmentIterator {
    return .{ .tokens = std.mem.tokenizeScalar(u8, pattern, '/') };
}

pub fn classify(raw: []const u8) Segment {
    std.debug.assert(raw.len != 0);
    if (raw.len == 1 and raw[0] == '*')
        return .wildcard;
    if (raw[0] == ':')
        return .{ .param = raw[1..] };
    return .{ .static = raw };
}

/// Null when `pattern` follows the grammar in this file's header.
pub fn validate(pattern: []const u8) ?Problem {
    if (pattern.len == 0 or pattern[0] != '/')
        return .missing_leading_slash;
    if (pattern.len > server_limits.route_pattern_bytes_max)
        return .too_long;
    if (pattern.len == 1)
        return null;
    if (isReserved(pattern))
        return .reserved_prefix;

    var param_names: [server_limits.route_path_segments_max][]const u8 = undefined;
    var param_count: usize = 0;
    var segment_count: usize = 0;
    var wildcard_seen = false;
    var raw_segments = std.mem.splitScalar(u8, pattern[1..], '/');
    while (raw_segments.next()) |raw| {
        if (raw.len == 0)
            return .empty_segment;
        if (segment_count == server_limits.route_path_segments_max)
            return .too_many_segments;
        segment_count += 1;
        if (wildcard_seen)
            return .wildcard_not_last;
        if (invalidSegmentByte(raw))
            return .invalid_character;
        switch (classify(raw)) {
            .wildcard => wildcard_seen = true,
            .param => |name| {
                if (!isParamName(name))
                    return .invalid_param_name;
                for (param_names[0..param_count]) |previous| {
                    if (std.mem.eql(u8, previous, name))
                        return .duplicate_param_name;
                }
                param_names[param_count] = name;
                param_count += 1;
            },
            .static => |text| {
                if (std.mem.indexOfScalar(u8, text, '*') != null)
                    return .partial_wildcard;
                if (std.mem.eql(u8, text, ".") or std.mem.eql(u8, text, ".."))
                    return .dot_segment;
            },
        }
    }
    return null;
}

/// True when two valid patterns match exactly the same request paths: the
/// same segments in the same order, with parameter names ignored.
pub fn sameShape(left: []const u8, right: []const u8) bool {
    var left_segments = segments(left);
    var right_segments = segments(right);
    while (true) {
        const left_segment = left_segments.next();
        const right_segment = right_segments.next();
        if (left_segment == null or right_segment == null)
            return left_segment == null and right_segment == null;
        switch (left_segment.?) {
            .static => |left_text| switch (right_segment.?) {
                .static => |right_text| if (!std.mem.eql(u8, left_text, right_text)) return false,
                .param, .wildcard => return false,
            },
            .param => if (right_segment.? != .param) return false,
            .wildcard => if (right_segment.? != .wildcard) return false,
        }
    }
}

/// True when the first segment of `path`, a request path or a pattern, is
/// the one `reserved_prefix` names. Segments split the way the route table
/// splits a request path, with empty segments dropped (`Table.match` in
/// `server/routes/table.zig`), so the prefix without its trailing `/` and a
/// path such as `//__collo/x` are reserved too.
pub fn isReserved(path: []const u8) bool {
    var path_segments = std.mem.tokenizeScalar(u8, path, '/');
    const first = path_segments.next() orelse return false;
    return std.mem.eql(u8, first, reserved_segment);
}

fn isParamName(name: []const u8) bool {
    if (name.len == 0)
        return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_')
        return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_')
            return false;
    }
    return true;
}

fn invalidSegmentByte(raw: []const u8) bool {
    for (raw) |byte| {
        if (byte < 0x21 or byte > 0x7e)
            return true;
        switch (byte) {
            '?', '#', '\\' => return true,
            else => {},
        }
    }
    return false;
}
