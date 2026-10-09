//! The arguments of `collo serve` (`server/boot/command_line.zig`): the path
//! that selects a configuration or an entry module, the `--listen` override
//! and every malformed form, each refused with a message that names it. Lane
//! `server-core-test`; the boot that runs an invocation is covered by
//! `zig build smoke`.

const std = @import("std");
const command_line = @import("collo_server_main").boot.command_line;

/// A word list with the `next` the parser reads, as `std.process.ArgIterator`
/// offers it.
const Words = struct {
    items: []const []const u8,
    index: usize = 0,

    pub fn next(self: *Words) ?[]const u8 {
        if (self.index == self.items.len)
            return null;
        const item = self.items[self.index];
        self.index += 1;
        return item;
    }
};

fn parse(items: []const []const u8, diagnostic: *command_line.Diagnostic) command_line.Error!command_line.Invocation {
    var words: Words = .{ .items = items };
    return command_line.parse(&words, diagnostic);
}

fn expectRefused(items: []const []const u8, expected_fragment: []const u8) !void {
    var diagnostic: command_line.Diagnostic = .{};
    try std.testing.expectError(error.InvalidUsage, parse(items, &diagnostic));
    if (std.mem.indexOf(u8, diagnostic.message(), expected_fragment) == null) {
        std.debug.print("message '{s}' lacks '{s}'\n", .{ diagnostic.message(), expected_fragment });
        return error.TestUnexpectedMessage;
    }
}

test "a .json path is a configuration and any other path an entry module" {
    var diagnostic: command_line.Diagnostic = .{};
    const configuration = try parse(&.{"deploy/collo.json"}, &diagnostic);
    try std.testing.expectEqualStrings("deploy/collo.json", configuration.path);
    try std.testing.expectEqual(command_line.Source.configuration, configuration.source);
    try std.testing.expect(configuration.listen == null);

    const entry = try parse(&.{"hello.js"}, &diagnostic);
    try std.testing.expectEqual(command_line.Source.entry_module, entry.source);
    try std.testing.expectEqual(command_line.Source.entry_module, command_line.sourceOf("app.mjs"));
    try std.testing.expectEqual(command_line.Source.entry_module, command_line.sourceOf("collo.json.js"));
}

test "--listen overrides the address before or after the path, port 0 included" {
    var diagnostic: command_line.Diagnostic = .{};
    const after = try parse(&.{ "hello.js", "--listen", "127.0.0.1:0" }, &diagnostic);
    const expected_ip4 = try std.net.Address.parseIp4("127.0.0.1", 0);
    try std.testing.expect(expected_ip4.eql(after.listen orelse return error.TestExpectedListen));

    const before = try parse(&.{ "--listen", "[::1]:8443", "collo.json" }, &diagnostic);
    try std.testing.expectEqual(command_line.Source.configuration, before.source);
    const expected_ip6 = try std.net.Address.parseIp6("::1", 8443);
    try std.testing.expect(expected_ip6.eql(before.listen orelse return error.TestExpectedListen));
}

test "a missing path is refused" {
    try expectRefused(&.{}, "missing the configuration or entry module path");
    try expectRefused(&.{ "--listen", "127.0.0.1:8443" }, "missing the configuration or entry module path");
}

test "a second path is refused with both paths named" {
    try expectRefused(&.{ "a.js", "b.js" }, "'a.js' and 'b.js'");
}

test "an unknown option is refused by name" {
    try expectRefused(&.{ "hello.js", "--port", "8443" }, "'--port'");
}

test "--listen without a value, with an invalid value or given twice is refused" {
    try expectRefused(&.{ "hello.js", "--listen" }, "needs an address");
    try expectRefused(&.{ "hello.js", "--listen", "localhost:8443" }, "'localhost:8443' is not an address");
    try expectRefused(&.{ "hello.js", "--listen", "127.0.0.1" }, "'127.0.0.1' is not an address");
    try expectRefused(&.{ "hello.js", "--listen", "127.0.0.1:70000" }, "'127.0.0.1:70000' is not an address");
    try expectRefused(&.{ "hello.js", "--listen", "127.0.0.1:1", "--listen", "127.0.0.1:2" }, "given twice");
}
