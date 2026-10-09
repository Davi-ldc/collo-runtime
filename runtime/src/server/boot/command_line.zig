//! The arguments of `collo serve <path> [--listen <host:port>]`. A path that
//! ends in `.json` names a configuration file and any other path an entry
//! module, from which the configuration is synthesized
//! (`server/config/synthesize.zig`). `--listen` replaces
//! `globalSettings.listen` in both forms, in the address grammar the
//! configuration uses (`parseListen` in `server/config/parse.zig`), and port 0
//! binds an ephemeral port.
//!
//! Parsing reads only its arguments and runs on the main thread before the
//! boot starts. An `Invocation` borrows the argument strings, which live for
//! the whole process.

const std = @import("std");
const config = @import("collo_server_config");

pub const usage = "usage: collo serve <collo.json | entry.js> [--listen <host:port>]\n";

pub const listen_option = "--listen";
pub const configuration_extension = ".json";

pub const Invocation = struct {
    /// As given; the loader resolves a relative path against the working
    /// directory.
    path: []const u8,
    source: Source,
    /// Replaces the configuration's listen address when set.
    listen: ?std.net.Address,
};

pub const Source = enum { configuration, entry_module };

pub const Error = error{InvalidUsage};
pub const Diagnostic = config.Diagnostic;

/// `arguments` yields the words after `serve`: a pointer to anything with
/// `next() ?[]const u8`, such as `std.process.ArgIterator`. On
/// `error.InvalidUsage` the diagnostic says what was wrong, without the
/// usage line.
pub fn parse(arguments: anytype, diagnostic: *config.Diagnostic) Error!Invocation {
    var path: ?[]const u8 = null;
    var listen: ?std.net.Address = null;
    while (arguments.next()) |argument| {
        if (std.mem.eql(u8, argument, listen_option)) {
            if (listen != null)
                return fail(diagnostic, listen_option ++ " is given twice", .{});
            const value = arguments.next() orelse
                return fail(diagnostic, listen_option ++ " needs an address such as 127.0.0.1:8443", .{});
            listen = config.parseListen(value) catch
                return fail(diagnostic, listen_option ++ ": '{s}' is not an address such as 127.0.0.1:8443 or [::1]:8443", .{value});
        } else if (std.mem.startsWith(u8, argument, "-")) {
            return fail(diagnostic, "unknown option '{s}'", .{argument});
        } else if (path) |earlier| {
            return fail(diagnostic, "one path is expected, found '{s}' and '{s}'", .{ earlier, argument });
        } else {
            path = argument;
        }
    }
    const chosen = path orelse
        return fail(diagnostic, "missing the configuration or entry module path", .{});
    return .{ .path = chosen, .source = sourceOf(chosen), .listen = listen };
}

pub fn sourceOf(path: []const u8) Source {
    if (std.mem.endsWith(u8, path, configuration_extension))
        return .configuration;
    return .entry_module;
}

fn fail(diagnostic: *config.Diagnostic, comptime format: []const u8, args: anytype) Error {
    diagnostic.set(format, args);
    return error.InvalidUsage;
}
