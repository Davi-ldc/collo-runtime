//! `collo.json` into a `Config` (`model.zig`): JSON with `//` and `/* */`
//! comments outside strings and no trailing commas.
//!
//! The parser checks everything a configuration can get wrong before boot
//! goes on: unknown keys (named by their key path), value types and ranges,
//! worker names, binding names and sizes (by the rules of
//! `common/ipc/route_bindings.zig`, which the worker enforces too), the route
//! pattern grammar (`pattern.zig`), two routes that match the same paths,
//! the path prefix the server reserves, the bounds in `common/limits/server.zig`,
//! and the features the runtime does not implement yet (`network`, binding
//! kinds other than `text`, `cpuMs`). A
//! limit with no enforcing mechanism is rejected rather than ignored: the
//! worker's sentinel (`worker/runtime/sentinel.zig`) arms a wall-clock
//! deadline per request, which `timeoutMs` sets, and the worker measures a
//! request's CPU time without bounding it, so `cpuMs` fails as not
//! supported yet.
//!
//! Relative paths resolve against the configuration file's directory. The
//! JSON tree and the comment-free copy of the text live in a scratch arena
//! freed before the constructor returns; the `Config` arena holds only the
//! result. Every failure returns `error.InvalidConfig` with the file, the key
//! path and the reason in the caller's `Diagnostic`.

const std = @import("std");
const server_limits = @import("collo_limits").server;
const route_bindings = @import("collo_ipc").route_bindings;
const model = @import("model.zig");
const pattern = @import("pattern.zig");
const Diagnostic = @import("diagnostic.zig").Diagnostic;

const Config = model.Config;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

pub const Error = error{ OutOfMemory, InvalidConfig };

/// Reads the configuration file at `path`, resolved against the working
/// directory when relative, and parses it. The caller owns the result and
/// calls `deinit`.
pub fn load(gpa: std.mem.Allocator, path: []const u8, diagnostic: *Diagnostic) Error!Config {
    var scratch_state: std.heap.ArenaAllocator = .init(gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    const absolute_path = absolutePath(scratch, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.EmptyPath => {
            diagnostic.set("the configuration path is empty", .{});
            return error.InvalidConfig;
        },
        else => {
            diagnostic.set("{s}: cannot resolve the working directory: {s}", .{ path, @errorName(err) });
            return error.InvalidConfig;
        },
    };
    const source = std.fs.cwd().readFileAlloc(scratch, absolute_path, server_limits.config_file_bytes_max) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileTooBig => {
            diagnostic.set("{s}: the configuration exceeds {d} bytes", .{ absolute_path, server_limits.config_file_bytes_max });
            return error.InvalidConfig;
        },
        else => {
            diagnostic.set("{s}: cannot read the configuration: {s}", .{ absolute_path, @errorName(err) });
            return error.InvalidConfig;
        },
    };
    return parse(gpa, source, absolute_path, diagnostic);
}

/// Parses configuration text. `config_path` must be absolute: messages name
/// it and its directory anchors relative paths. The caller owns the result
/// and calls `deinit`; `source` is not referenced after the call.
pub fn parse(
    gpa: std.mem.Allocator,
    source: []const u8,
    config_path: []const u8,
    diagnostic: *Diagnostic,
) Error!Config {
    std.debug.assert(std.fs.path.isAbsolute(config_path));
    if (source.len > server_limits.config_file_bytes_max) {
        diagnostic.set("{s}: the configuration exceeds {d} bytes", .{ config_path, server_limits.config_file_bytes_max });
        return error.InvalidConfig;
    }

    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = .init(gpa);
    errdefer arena.deinit();
    var scratch_state: std.heap.ArenaAllocator = .init(gpa);
    defer scratch_state.deinit();

    const owned_path = try arena.allocator().dupe(u8, config_path);
    var parser: Parser = .{
        .arena = arena.allocator(),
        .scratch = scratch_state.allocator(),
        .config_path = owned_path,
        .directory = std.fs.path.dirname(owned_path) orelse "/",
        .diagnostic = diagnostic,
    };
    const text = try parser.stripComments(source);
    const root = try parser.parseJson(text);
    var config = try parser.readRoot(root);
    config.arena = arena;
    return config;
}

/// Parses `host:port` for IPv4 or `[host]:port` for IPv6. Port 0 is valid
/// and asks for an ephemeral port.
pub fn parseListen(text: []const u8) error{InvalidListenAddress}!std.net.Address {
    if (text.len == 0)
        return error.InvalidListenAddress;
    if (text[0] == '[') {
        const close = std.mem.indexOfScalar(u8, text, ']') orelse return error.InvalidListenAddress;
        if (close + 1 >= text.len or text[close + 1] != ':')
            return error.InvalidListenAddress;
        const port = parsePort(text[close + 2 ..]) orelse return error.InvalidListenAddress;
        return std.net.Address.parseIp6(text[1..close], port) catch error.InvalidListenAddress;
    }
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return error.InvalidListenAddress;
    const port = parsePort(text[colon + 1 ..]) orelse return error.InvalidListenAddress;
    return std.net.Address.parseIp4(text[0..colon], port) catch error.InvalidListenAddress;
}

/// `path` made absolute against the working directory and lexically
/// normalized: `.` and `..` resolve without touching the filesystem, so a
/// symlink in the path is kept as written.
pub fn absolutePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0)
        return error.EmptyPath;
    if (std.fs.path.isAbsolute(path))
        return std.fs.path.resolvePosix(allocator, &.{path});
    const working_directory = try std.process.getCwdAlloc(allocator);
    defer allocator.free(working_directory);
    return std.fs.path.resolvePosix(allocator, &.{ working_directory, path });
}

/// True for a name `[a-z0-9-]{1,worker_name_bytes_max}`.
pub fn isWorkerName(name: []const u8) bool {
    if (name.len == 0 or name.len > server_limits.worker_name_bytes_max)
        return false;
    for (name) |byte| {
        const valid = (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '-';
        if (!valid)
            return false;
    }
    return true;
}

fn parsePort(text: []const u8) ?u16 {
    if (text.len == 0 or text.len > 5)
        return null;
    var port: u32 = 0;
    for (text) |byte| {
        if (byte < '0' or byte > '9')
            return null;
        port = port * 10 + (byte - '0');
    }
    return std.math.cast(u16, port);
}

/// The key path of the value being read, for messages: object keys joined
/// with `.`, and a key quoted when it holds anything but `[A-Za-z0-9_-]`.
const KeyPath = struct {
    keys: [depth_max][]const u8 = undefined,
    len: usize = 0,

    /// Deeper than any key the schema defines
    /// (`workers.<name>.routes.<pattern>.bindings.<name>.text`).
    const depth_max = 8;

    fn push(self: *KeyPath, key: []const u8) void {
        std.debug.assert(self.len < depth_max);
        self.keys[self.len] = key;
        self.len += 1;
    }

    fn pop(self: *KeyPath) void {
        std.debug.assert(self.len > 0);
        self.len -= 1;
    }

    pub fn format(self: KeyPath, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.keys[0..self.len], 0..) |key, index| {
            if (index != 0)
                try writer.writeByte('.');
            try writeKey(writer, key);
        }
    }
};

fn writeKey(writer: *std.Io.Writer, key: []const u8) std.Io.Writer.Error!void {
    for (key) |byte| {
        const plain = std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
        if (!plain) {
            try writer.print("\"{s}\"", .{key});
            return;
        }
    }
    try writer.writeAll(key);
}

const Parser = struct {
    /// The `Config` arena: everything the result keeps.
    arena: std.mem.Allocator,
    /// Freed when the constructor returns: the JSON tree and its text.
    scratch: std.mem.Allocator,
    config_path: []const u8,
    directory: []const u8,
    diagnostic: *Diagnostic,
    path: KeyPath = .{},

    fn fail(self: *Parser, comptime format: []const u8, args: anytype) Error {
        if (self.path.len == 0) {
            self.diagnostic.set("{s}: " ++ format, .{self.config_path} ++ args);
        } else {
            self.diagnostic.set("{s}: {f}: " ++ format, .{ self.config_path, self.path } ++ args);
        }
        return error.InvalidConfig;
    }

    fn failAtLine(self: *Parser, line: u64, column: u64, comptime format: []const u8, args: anytype) Error {
        self.diagnostic.set("{s}:{d}:{d}: " ++ format, .{ self.config_path, line, column } ++ args);
        return error.InvalidConfig;
    }

    /// A copy of `source` with every comment outside a string replaced by
    /// spaces. Newlines stay, so JSON error positions still point at the
    /// original lines.
    fn stripComments(self: *Parser, source: []const u8) Error![]u8 {
        const text = try self.scratch.dupe(u8, source);
        var index: usize = 0;
        var line: u64 = 1;
        var line_start: usize = 0;
        while (index < text.len) {
            switch (text[index]) {
                '"' => index = skipString(text, index),
                '\n' => {
                    index += 1;
                    line += 1;
                    line_start = index;
                },
                '/' => {
                    if (index + 1 < text.len and text[index + 1] == '/') {
                        while (index < text.len and text[index] != '\n') : (index += 1)
                            text[index] = ' ';
                    } else if (index + 1 < text.len and text[index + 1] == '*') {
                        const comment_start = index;
                        const comment_line = line;
                        const comment_column = index - line_start + 1;
                        const close = std.mem.indexOfPos(u8, text, index + 2, "*/") orelse
                            return self.failAtLine(comment_line, comment_column, "unterminated /* comment", .{});
                        for (text[comment_start .. close + 2], comment_start..) |*byte, position| {
                            if (byte.* == '\n') {
                                line += 1;
                                line_start = position + 1;
                            } else {
                                byte.* = ' ';
                            }
                        }
                        index = close + 2;
                    } else {
                        // Not a comment; the JSON parser reports the byte.
                        index += 1;
                    }
                },
                else => index += 1,
            }
        }
        return text;
    }

    fn parseJson(self: *Parser, text: []const u8) Error!Value {
        var scanner = std.json.Scanner.initCompleteInput(self.scratch, text);
        defer scanner.deinit();
        var json_diagnostics: std.json.Diagnostics = .{};
        scanner.enableDiagnostics(&json_diagnostics);
        return std.json.parseFromTokenSourceLeaky(Value, self.scratch, &scanner, .{
            .duplicate_field_behavior = .@"error",
            .allocate = .alloc_always,
            .max_value_len = text.len,
            .parse_numbers = true,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateField => return self.failAtLine(
                json_diagnostics.getLine(),
                json_diagnostics.getColumn(),
                "duplicate key in the object that ends here",
                .{},
            ),
            error.UnexpectedEndOfInput => return self.failAtLine(
                json_diagnostics.getLine(),
                json_diagnostics.getColumn(),
                "unexpected end of the configuration",
                .{},
            ),
            else => return self.failAtLine(
                json_diagnostics.getLine(),
                json_diagnostics.getColumn(),
                "invalid JSON ({s}); comments are allowed, trailing commas are not",
                .{@errorName(err)},
            ),
        };
    }

    fn readRoot(self: *Parser, root: Value) Error!Config {
        const object = try self.expectObject(root);
        try self.rejectUnknownKeys(object, &.{ "globalSettings", "workers" });

        var listen = parseListen(model.default_listen) catch unreachable;
        var tls: ?model.Tls = null;
        var analytics: ?model.Analytics = null;
        var defaults = model.default_settings;
        if (object.get("globalSettings")) |global_value| {
            self.path.push("globalSettings");
            const global = try self.expectObject(global_value);
            try self.rejectUnknownKeys(global, &.{ "listen", "tls", "analytics", "isolateRealm", "limits", "network" });
            if (global.get("listen")) |listen_value| {
                self.path.push("listen");
                const text = try self.expectString(listen_value);
                listen = parseListen(text) catch
                    return self.fail("'{s}' is not an address such as 127.0.0.1:8443 or [::1]:8443", .{text});
                self.path.pop();
            }
            if (global.get("tls")) |tls_value| {
                self.path.push("tls");
                tls = try self.readTls(tls_value);
                self.path.pop();
            }
            if (global.get("analytics")) |analytics_value| {
                self.path.push("analytics");
                analytics = try self.readAnalytics(analytics_value);
                self.path.pop();
            }
            defaults = try self.readSettings(global, defaults);
            self.path.pop();
        }

        const workers_value = object.get("workers") orelse return self.fail("missing key 'workers'", .{});
        self.path.push("workers");
        const definitions = try self.readWorkers(workers_value, defaults);
        self.path.pop();

        var route_count: usize = 0;
        for (definitions) |definition|
            route_count += definition.routes.len;
        if (route_count > server_limits.routes_max)
            return self.fail("the configuration declares {d} routes; at most {d} are allowed", .{ route_count, server_limits.routes_max });
        try self.rejectSameShapes(definitions);

        return .{
            .arena = undefined,
            .path = self.config_path,
            .listen = listen,
            .tls = tls,
            .analytics = analytics,
            .defaults = defaults,
            .definitions = definitions,
            .route_count = @intCast(route_count),
        };
    }

    fn readTls(self: *Parser, value: Value) Error!model.Tls {
        const object = try self.expectObject(value);
        try self.rejectUnknownKeys(object, &.{ "certificate", "privateKey" });
        return .{
            .certificate_path = try self.readRequiredPath(object, "certificate"),
            .private_key_path = try self.readRequiredPath(object, "privateKey"),
        };
    }

    fn readAnalytics(self: *Parser, value: Value) Error!model.Analytics {
        const object = try self.expectObject(value);
        try self.rejectUnknownKeys(object, &.{"directory"});
        return .{ .directory_path = try self.readRequiredPath(object, "directory") };
    }

    /// The settings keys of `object` (`isolateRealm`, `limits`, `network`)
    /// applied over `base`. The caller already rejected the other keys.
    fn readSettings(self: *Parser, object: ObjectMap, base: model.Settings) Error!model.Settings {
        var settings = base;
        if (object.get("network") != null) {
            self.path.push("network");
            return self.fail("network access is not supported yet; remove the key", .{});
        }
        if (object.get("isolateRealm")) |isolate_value| {
            self.path.push("isolateRealm");
            settings.isolate_realm = try self.expectBool(isolate_value);
            self.path.pop();
        }
        if (object.get("limits")) |limits_value| {
            self.path.push("limits");
            settings.limits = try self.readLimits(limits_value, base.limits);
            self.path.pop();
        }
        return settings;
    }

    fn readLimits(self: *Parser, value: Value, base: model.Limits) Error!model.Limits {
        const object = try self.expectObject(value);
        try self.rejectUnknownKeys(object, &.{ "memoryMiB", "concurrency", "cpuMs", "timeoutMs" });
        var limits = base;
        if (object.get("cpuMs") != null) {
            self.path.push("cpuMs");
            return self.fail("a per-request CPU budget is not supported yet; remove the key (timeoutMs bounds wall-clock time)", .{});
        }
        if (object.get("memoryMiB")) |memory_value| {
            self.path.push("memoryMiB");
            limits.memory_mib = @intCast(try self.expectInteger(
                memory_value,
                server_limits.worker_memory_mib_min,
                server_limits.worker_memory_mib_max,
            ));
            self.path.pop();
        }
        if (object.get("concurrency")) |concurrency_value| {
            self.path.push("concurrency");
            limits.concurrency = @intCast(try self.expectInteger(concurrency_value, 1, server_limits.worker_concurrency_max));
            self.path.pop();
        }
        if (object.get("timeoutMs")) |timeout_value| {
            self.path.push("timeoutMs");
            limits.timeout_ms = @intCast(try self.expectInteger(timeout_value, 1, server_limits.request_timeout_ms_max));
            self.path.pop();
        }
        return limits;
    }

    fn readWorkers(self: *Parser, value: Value, defaults: model.Settings) Error![]model.WorkerDefinition {
        const object = try self.expectObject(value);
        const count = object.count();
        if (count == 0)
            return self.fail("declare at least one worker", .{});
        if (count > server_limits.worker_definitions_max)
            return self.fail("{d} workers are declared; at most {d} are allowed", .{ count, server_limits.worker_definitions_max });

        const definitions = try self.arena.alloc(model.WorkerDefinition, count);
        var entries = object.iterator();
        var index: usize = 0;
        while (entries.next()) |entry| : (index += 1) {
            const name = entry.key_ptr.*;
            self.path.push(name);
            if (!isWorkerName(name))
                return self.fail("a worker name must match [a-z0-9-] and hold 1 to {d} bytes", .{server_limits.worker_name_bytes_max});
            definitions[index] = try self.readWorker(name, entry.value_ptr.*, defaults);
            self.path.pop();
        }
        return definitions;
    }

    fn readWorker(self: *Parser, name: []const u8, value: Value, defaults: model.Settings) Error!model.WorkerDefinition {
        const object = try self.expectObject(value);
        try self.rejectUnknownKeys(object, &.{ "routes", "settings" });
        var settings = defaults;
        if (object.get("settings")) |settings_value| {
            self.path.push("settings");
            const settings_object = try self.expectObject(settings_value);
            try self.rejectUnknownKeys(settings_object, &.{ "isolateRealm", "limits", "network" });
            settings = try self.readSettings(settings_object, defaults);
            self.path.pop();
        }
        const routes_value = object.get("routes") orelse return self.fail("missing key 'routes'", .{});
        self.path.push("routes");
        const routes = try self.readRoutes(routes_value);
        self.path.pop();
        return .{
            .name = try self.arena.dupe(u8, name),
            .settings = settings,
            .routes = routes,
        };
    }

    fn readRoutes(self: *Parser, value: Value) Error![]model.Route {
        const object = try self.expectObject(value);
        const count = object.count();
        if (count == 0)
            return self.fail("declare at least one route", .{});
        if (count > server_limits.routes_per_definition_max)
            return self.fail("{d} routes are declared; at most {d} are allowed per worker", .{ count, server_limits.routes_per_definition_max });

        const routes = try self.arena.alloc(model.Route, count);
        var entries = object.iterator();
        var index: usize = 0;
        while (entries.next()) |entry| : (index += 1) {
            const route_pattern = entry.key_ptr.*;
            self.path.push(route_pattern);
            if (pattern.validate(route_pattern)) |problem|
                return self.fail("{s}", .{problem.describe()});
            routes[index] = try self.readRoute(route_pattern, entry.value_ptr.*);
            self.path.pop();
        }
        return routes;
    }

    fn readRoute(self: *Parser, route_pattern: []const u8, value: Value) Error!model.Route {
        const object = try self.expectObject(value);
        try self.rejectUnknownKeys(object, &.{ "entry", "bindings", "network" });
        if (object.get("network") != null) {
            self.path.push("network");
            return self.fail("network access is not supported yet; remove the key", .{});
        }
        const entry_path = try self.readRequiredPath(object, "entry");
        var bindings: []model.Binding = &.{};
        if (object.get("bindings")) |bindings_value| {
            self.path.push("bindings");
            bindings = try self.readBindings(bindings_value);
            self.path.pop();
        }
        return .{
            .pattern = try self.arena.dupe(u8, route_pattern),
            .entry_path = entry_path,
            .bindings = bindings,
        };
    }

    fn readBindings(self: *Parser, value: Value) Error![]model.Binding {
        const object = try self.expectObject(value);
        const count = object.count();
        if (count > server_limits.bindings_per_route_max)
            return self.fail("{d} bindings are declared; at most {d} are allowed per route", .{ count, server_limits.bindings_per_route_max });

        const bindings = try self.arena.alloc(model.Binding, count);
        // The size of the serialized blob as `common/ipc/route_bindings.zig`
        // lays it out: a u32 count, then a u32 length before every name and
        // every value.
        var blob_bytes: usize = @sizeOf(u32);
        var entries = object.iterator();
        var index: usize = 0;
        while (entries.next()) |entry| : (index += 1) {
            const name = entry.key_ptr.*;
            self.path.push(name);
            if (!route_bindings.isBindingName(name))
                return self.fail("a binding name must match [A-Za-z_][A-Za-z0-9_]* and hold at most {d} bytes", .{server_limits.binding_name_bytes_max});
            const binding_object = try self.expectObject(entry.value_ptr.*);
            var kinds = binding_object.iterator();
            const kind = kinds.next() orelse return self.fail("a binding needs a kind, such as {{ \"text\": \"...\" }}", .{});
            if (binding_object.count() != 1)
                return self.fail("a binding has exactly one kind", .{});
            const kind_name = kind.key_ptr.*;
            if (!std.mem.eql(u8, kind_name, "text")) {
                self.path.push(kind_name);
                return self.fail("binding kind '{s}' is not supported yet; only text bindings are", .{kind_name});
            }
            self.path.push("text");
            const text = try self.expectString(kind.value_ptr.*);
            self.path.pop();
            blob_bytes += 2 * @sizeOf(u32) + name.len + text.len;
            if (blob_bytes > server_limits.binding_bytes_per_route_max) {
                self.path.pop();
                return self.fail("the route's bindings exceed {d} bytes", .{server_limits.binding_bytes_per_route_max});
            }
            bindings[index] = .{
                .name = try self.arena.dupe(u8, name),
                .value = .{ .text = try self.arena.dupe(u8, text) },
            };
            self.path.pop();
        }
        return bindings;
    }

    /// Two routes that match the same paths, in one worker or in two, cannot
    /// both be reached; the second is rejected.
    fn rejectSameShapes(self: *Parser, definitions: []const model.WorkerDefinition) Error!void {
        for (definitions, 0..) |definition, definition_index| {
            for (definition.routes, 0..) |route, route_index| {
                for (definitions[0 .. definition_index + 1], 0..) |earlier_definition, earlier_definition_index| {
                    const earlier_routes = if (earlier_definition_index == definition_index)
                        earlier_definition.routes[0..route_index]
                    else
                        earlier_definition.routes;
                    for (earlier_routes) |earlier| {
                        if (!pattern.sameShape(earlier.pattern, route.pattern))
                            continue;
                        self.path.push("workers");
                        self.path.push(definition.name);
                        self.path.push("routes");
                        self.path.push(route.pattern);
                        return self.fail("matches the same paths as route '{s}' of worker '{s}'", .{
                            earlier.pattern,
                            earlier_definition.name,
                        });
                    }
                }
            }
        }
    }

    fn rejectUnknownKeys(self: *Parser, object: ObjectMap, comptime known: []const []const u8) Error!void {
        var keys = object.iterator();
        while (keys.next()) |entry| {
            const key = entry.key_ptr.*;
            const is_known = inline for (known) |candidate| {
                if (std.mem.eql(u8, key, candidate))
                    break true;
            } else false;
            if (!is_known) {
                self.path.push(key);
                return self.fail("unknown key", .{});
            }
        }
    }

    fn readRequiredPath(self: *Parser, object: ObjectMap, comptime key: []const u8) Error![]const u8 {
        const value = object.get(key) orelse return self.fail("missing key '" ++ key ++ "'", .{});
        self.path.push(key);
        const text = try self.expectString(value);
        if (text.len == 0)
            return self.fail("the path is empty", .{});
        if (std.mem.indexOfScalar(u8, text, 0) != null)
            return self.fail("the path holds a NUL byte", .{});
        const resolved = try std.fs.path.resolvePosix(self.arena, &.{ self.directory, text });
        self.path.pop();
        return resolved;
    }

    /// The map by value: it is a handle to entries the scratch arena owns.
    fn expectObject(self: *Parser, value: Value) Error!ObjectMap {
        switch (value) {
            .object => |object| return object,
            else => return self.fail("expected an object, found {s}", .{kindName(value)}),
        }
    }

    fn expectString(self: *Parser, value: Value) Error![]const u8 {
        switch (value) {
            .string => |text| return text,
            else => return self.fail("expected a string, found {s}", .{kindName(value)}),
        }
    }

    fn expectBool(self: *Parser, value: Value) Error!bool {
        switch (value) {
            .bool => |flag| return flag,
            else => return self.fail("expected true or false, found {s}", .{kindName(value)}),
        }
    }

    fn expectInteger(self: *Parser, value: Value, min: u32, max: u32) Error!u32 {
        switch (value) {
            .integer => |number| {
                if (number < min or number > max)
                    return self.fail("{d} is out of range; expected {d} to {d}", .{ number, min, max });
                return @intCast(number);
            },
            .number_string => return self.fail("the number is out of range; expected {d} to {d}", .{ min, max }),
            .float => return self.fail("expected a whole number", .{}),
            else => return self.fail("expected an integer, found {s}", .{kindName(value)}),
        }
    }
};

fn kindName(value: Value) []const u8 {
    return switch (value) {
        .null => "null",
        .bool => "a boolean",
        .integer, .float, .number_string => "a number",
        .string => "a string",
        .array => "an array",
        .object => "an object",
    };
}

/// Index just past the string that opens at `start`, or the end of `text`
/// when it never closes (the JSON parser then reports it).
fn skipString(text: []const u8, start: usize) usize {
    std.debug.assert(text[start] == '"');
    var index = start + 1;
    while (index < text.len) {
        switch (text[index]) {
            '\\' => index += 2,
            '"' => return index + 1,
            // JSON strings never span lines; the parser reports this one.
            '\n' => return index,
            else => index += 1,
        }
    }
    return text.len;
}
