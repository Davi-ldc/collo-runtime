//! The allow entry grammar of `collo_network` (`common/network/pattern.zig`):
//! every form it accepts with its canonical form, every refusal with the
//! problem it reports, the WHATWG readings of IPv6 and IPv4 addresses, the
//! reading of URL hosts, the canonical order, and the agreement of its name
//! rules with `collo_dns_name`.

const std = @import("std");
const dns_name = @import("collo_dns_name");
const network = @import("collo_network");
const support = @import("support.zig");

const pattern = network.pattern;
const Pattern = network.Pattern;
const Problem = pattern.Problem;

const label_63 = "a" ** 63;
/// Three labels of 63 bytes and one of 61, with their dots: 253 bytes.
const name_253 = label_63 ++ "." ++ label_63 ++ "." ++ label_63 ++ "." ++ "b" ** 61;
const name_254 = name_253 ++ "c";

comptime {
    std.debug.assert(name_253.len == pattern.name_bytes_max);
}

fn expectPattern(text: []const u8, expected: Pattern) !void {
    var buffer: [pattern.name_bytes_max]u8 = undefined;
    switch (pattern.parse(text, &buffer)) {
        .pattern => |parsed| {
            if (!parsed.eql(expected)) {
                std.debug.print("'{s}' read as {any}, expected {any}\n", .{ text, parsed, expected });
                return error.TestUnexpectedResult;
            }
        },
        .problem => |problem| {
            std.debug.print("'{s}' was refused: {s}\n", .{ text, problem.describe() });
            return error.TestUnexpectedResult;
        },
    }
}

fn expectProblem(text: []const u8, expected: Problem) !void {
    var buffer: [pattern.name_bytes_max]u8 = undefined;
    switch (pattern.parse(text, &buffer)) {
        .pattern => |parsed| {
            std.debug.print("'{s}' was accepted as {any}\n", .{ text, parsed });
            return error.TestUnexpectedResult;
        },
        .problem => |problem| {
            if (problem != expected)
                std.debug.print("'{s}' was refused with {s}\n", .{ text, @tagName(problem) });
            try std.testing.expectEqual(expected, problem);
        },
    }
}

fn nameEntry(text: []const u8) Pattern {
    return .{ .host = .{ .name = text }, .port = 0 };
}

const Accepted = struct {
    text: []const u8,
    expected: Pattern,
};

test "each accepted form reads to its canonical pattern" {
    const public_ipv6 = [16]u8{ 0x26, 0x06, 0x47, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x11, 0x11 };
    const cases = [_]Accepted{
        .{ .text = "*", .expected = .{ .host = .any, .port = 0 } },
        .{ .text = "api.example.com", .expected = nameEntry("api.example.com") },
        .{ .text = "API.Example.COM", .expected = nameEntry("api.example.com") },
        .{ .text = "api.example.com.", .expected = nameEntry("api.example.com") },
        .{ .text = "intranet", .expected = nameEntry("intranet") },
        .{ .text = "_dmarc.example.com", .expected = nameEntry("_dmarc.example.com") },
        .{ .text = "my_service.internal", .expected = nameEntry("my_service.internal") },
        .{ .text = "a-b.example", .expected = nameEntry("a-b.example") },
        .{ .text = "xn--bcher-kva.example", .expected = nameEntry("xn--bcher-kva.example") },
        .{ .text = "localhost.example.com", .expected = nameEntry("localhost.example.com") },
        // A last label that is not a number keeps the host a name.
        .{ .text = "123.example", .expected = nameEntry("123.example") },
        .{ .text = "example.0xg", .expected = nameEntry("example.0xg") },
        .{ .text = name_253, .expected = nameEntry(name_253) },
        .{ .text = "*.example.com", .expected = .{ .host = .{ .suffix = "example.com" }, .port = 0 } },
        .{ .text = "*.Example.com.:8443", .expected = .{ .host = .{ .suffix = "example.com" }, .port = 8443 } },
        .{ .text = "*." ++ name_253 ++ ":65535", .expected = .{ .host = .{ .suffix = name_253 }, .port = 65535 } },
        .{ .text = "api.example.com:8443", .expected = .{ .host = .{ .name = "api.example.com" }, .port = 8443 } },
        .{ .text = "api.example.com:1", .expected = .{ .host = .{ .name = "api.example.com" }, .port = 1 } },
        .{ .text = "api.example.com:65535", .expected = .{ .host = .{ .name = "api.example.com" }, .port = 65535 } },
        .{ .text = "93.184.216.34", .expected = .{ .host = .{ .ipv4 = .{ 93, 184, 216, 34 } }, .port = 0 } },
        .{ .text = "93.184.216.34.", .expected = .{ .host = .{ .ipv4 = .{ 93, 184, 216, 34 } }, .port = 0 } },
        // Only 192.0.0.0/24 of 192.0.0.0/16 is special-purpose.
        .{ .text = "192.0.78.9", .expected = .{ .host = .{ .ipv4 = .{ 192, 0, 78, 9 } }, .port = 0 } },
        // A private address is grammar; whether a setting may name it is
        // the setting's check.
        .{ .text = "10.0.0.5:8080", .expected = .{ .host = .{ .ipv4 = .{ 10, 0, 0, 5 } }, .port = 8080 } },
        .{ .text = "[2606:4700::1111]", .expected = .{ .host = .{ .ipv6 = public_ipv6 }, .port = 0 } },
        .{ .text = "[2606:4700:0:0:0:0:0:1111]", .expected = .{ .host = .{ .ipv6 = public_ipv6 }, .port = 0 } },
        .{ .text = "[2606:4700::1111]:8443", .expected = .{ .host = .{ .ipv6 = public_ipv6 }, .port = 8443 } },
        .{
            .text = "[fd00::1]",
            .expected = .{ .host = .{ .ipv6 = .{ 0xfd, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } }, .port = 0 },
        },
        // An IPv4-mapped address keeps its IPv6 bytes and takes the class of
        // its IPv4 address.
        .{
            .text = "[::ffff:93.184.216.34]",
            .expected = .{ .host = .{ .ipv6 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 93, 184, 216, 34 } }, .port = 0 },
        },
    };
    for (cases) |case|
        try expectPattern(case.text, case.expected);
}

const Refused = struct {
    text: []const u8,
    problem: Problem,
};

test "each refused entry reports the rule it breaks" {
    const cases = [_]Refused{
        .{ .text = "", .problem = .empty },
        .{ .text = ":443", .problem = .empty },
        .{ .text = "*." ++ name_254 ++ ":65535", .problem = .too_long },
        .{ .text = "exämple.com", .problem = .non_ascii },
        .{ .text = "*.bücher.example", .problem = .non_ascii },
        .{ .text = "api.example.com:٤٤٣", .problem = .non_ascii },
        .{ .text = "api example.com", .problem = .invalid_character },
        .{ .text = " api.example.com", .problem = .invalid_character },
        .{ .text = "api.example.com\t", .problem = .invalid_character },
        .{ .text = "api/v1.example.com", .problem = .invalid_character },
        .{ .text = "user@example.com", .problem = .invalid_character },
        .{ .text = "ex%61mple.com", .problem = .invalid_character },
        .{ .text = "a+b.example", .problem = .invalid_character },
        .{ .text = "*.*.example.com", .problem = .misplaced_wildcard },
        .{ .text = "api.*.com", .problem = .misplaced_wildcard },
        .{ .text = "*api.example.com", .problem = .misplaced_wildcard },
        .{ .text = "*.", .problem = .misplaced_wildcard },
        .{ .text = "**", .problem = .misplaced_wildcard },
        .{ .text = "*.*", .problem = .misplaced_wildcard },
        .{ .text = "*.:443", .problem = .misplaced_wildcard },
        .{ .text = "*.93.184.216.34", .problem = .misplaced_wildcard },
        .{ .text = "*.[2606:4700::1111]", .problem = .misplaced_wildcard },
        .{ .text = "*:443", .problem = .wildcard_port },
        .{ .text = "*:8443", .problem = .wildcard_port },
        .{ .text = "*:", .problem = .wildcard_port },
        .{ .text = "api.example.com:", .problem = .invalid_port },
        .{ .text = "api.example.com:0", .problem = .invalid_port },
        .{ .text = "api.example.com:08080", .problem = .invalid_port },
        .{ .text = "api.example.com:65536", .problem = .invalid_port },
        .{ .text = "api.example.com:443x", .problem = .invalid_port },
        .{ .text = "api.example.com:+443", .problem = .invalid_port },
        .{ .text = "[2606:4700::1111]:0", .problem = .invalid_port },
        .{ .text = "2606:4700::1111", .problem = .unbracketed_ipv6 },
        .{ .text = "[2606:4700::1111", .problem = .invalid_ipv6 },
        .{ .text = "[2606:4700::1111]x", .problem = .invalid_ipv6 },
        .{ .text = "[]", .problem = .invalid_ipv6 },
        .{ .text = "[example.com]", .problem = .invalid_ipv6 },
        .{ .text = "[fe80::1%eth0]", .problem = .ipv6_zone },
        .{ .text = "[fe80::1%25eth0]", .problem = .ipv6_zone },
        .{ .text = "a..b", .problem = .empty_label },
        .{ .text = ".example.com", .problem = .empty_label },
        .{ .text = "example.com..", .problem = .empty_label },
        .{ .text = ".", .problem = .empty_label },
        .{ .text = "a" ** 64 ++ ".example", .problem = .label_too_long },
        .{ .text = "-api.example.com", .problem = .label_hyphen },
        .{ .text = "api-.example.com", .problem = .label_hyphen },
        .{ .text = "api.example-", .problem = .label_hyphen },
        .{ .text = name_254, .problem = .name_too_long },
        .{ .text = "127.1", .problem = .numeric_name },
        .{ .text = "0x7f.0.0.1", .problem = .numeric_name },
        .{ .text = "example.0x1F", .problem = .numeric_name },
        .{ .text = "example.0x", .problem = .numeric_name },
        .{ .text = "1.2.3.04", .problem = .numeric_name },
        .{ .text = "01.2.3.4", .problem = .numeric_name },
        .{ .text = "256.1.1.1", .problem = .numeric_name },
        .{ .text = "1.2.3.4.5", .problem = .numeric_name },
        .{ .text = "foo.123", .problem = .numeric_name },
        .{ .text = "3232235777", .problem = .numeric_name },
        .{ .text = "localhost", .problem = .localhost },
        .{ .text = "LOCALHOST.", .problem = .localhost },
        .{ .text = "localhost:8080", .problem = .localhost },
        .{ .text = "api.localhost", .problem = .localhost },
        .{ .text = "*.localhost", .problem = .localhost },
        .{ .text = "127.0.0.1", .problem = .loopback_address },
        .{ .text = "[::1]", .problem = .loopback_address },
        .{ .text = "[::ffff:127.0.0.1]", .problem = .loopback_address },
        .{ .text = "0.0.0.0", .problem = .unspecified_address },
        .{ .text = "[::]", .problem = .unspecified_address },
        .{ .text = "[fe80::1]", .problem = .link_local_address },
        .{ .text = "169.254.169.254", .problem = .metadata_address },
        .{ .text = "[fd00:ec2::254]", .problem = .metadata_address },
        .{ .text = "[fd20:ce::254]", .problem = .metadata_address },
        .{ .text = "168.63.129.16", .problem = .metadata_address },
        .{ .text = "[::a9fe:a9fe]", .problem = .reserved_address },
        .{ .text = "192.0.0.192", .problem = .reserved_address },
        .{ .text = "100.64.0.1", .problem = .shared_carrier_address },
        .{ .text = "198.18.0.1", .problem = .benchmark_address },
        .{ .text = "[2001:2::1]", .problem = .benchmark_address },
        .{ .text = "192.0.2.1", .problem = .documentation_address },
        .{ .text = "[2001:db8::1]", .problem = .documentation_address },
        .{ .text = "224.0.0.1", .problem = .multicast_address },
        .{ .text = "[ff02::1]", .problem = .multicast_address },
        .{ .text = "255.255.255.255", .problem = .broadcast_address },
        .{ .text = "240.0.0.1", .problem = .reserved_address },
        .{ .text = "192.88.99.1", .problem = .reserved_address },
        .{ .text = "[64:ff9b::7f00:1]", .problem = .reserved_address },
    };
    for (cases) |case|
        try expectProblem(case.text, case.problem);
}

/// The canonical name an entry reads to, or null when the grammar refuses
/// it or reads it to another form.
fn canonicalName(text: []const u8, buffer: *[pattern.name_bytes_max]u8) ?[]const u8 {
    return switch (pattern.parse(text, buffer)) {
        .pattern => |parsed| switch (parsed.host) {
            .name => |name| name,
            .any, .suffix, .ipv4, .ipv6 => null,
        },
        .problem => null,
    };
}

test "a name the grammar admits passes the DNS name check in canonical form, and both refuse the same bytes and labels" {
    // Every byte value between two letters compares the character rules.
    var text: [3]u8 = .{ 'a', 0, 'b' };
    for (0..256) |value| {
        text[1] = @intCast(value);
        var buffer: [pattern.name_bytes_max]u8 = undefined;
        const canonical = canonicalName(&text, &buffer);
        if (dns_name.isValidName(&text) != (canonical != null))
            std.debug.print("byte 0x{x:0>2} splits the grammar and the DNS name check\n", .{value});
        try std.testing.expectEqual(dns_name.isValidName(&text), canonical != null);
        if (canonical) |name| try std.testing.expect(dns_name.isValidName(name));
    }

    const label_cases = [_][]const u8{
        "_a",             "a_",              "a-b",    "-a",     "a-",
        "a.-b",           "a..b",            ".a",     "a.b.",   "A.B",
        label_63 ++ ".b", label_63 ++ "a.b", name_253, name_254,
    };
    for (label_cases) |case| {
        var buffer: [pattern.name_bytes_max]u8 = undefined;
        const canonical = canonicalName(case, &buffer);
        // The grammar drops one trailing dot; the DNS name check never sees it.
        const without_dot = if (std.mem.endsWith(u8, case, ".")) case[0 .. case.len - 1] else case;
        if (dns_name.isValidName(without_dot) != (canonical != null))
            std.debug.print("'{s}' splits the grammar and the DNS name check\n", .{case});
        try std.testing.expectEqual(dns_name.isValidName(without_dot), canonical != null);
        if (canonical) |name| try std.testing.expect(dns_name.isValidName(name));
    }
}

test "every problem has a sentence, and the non-ASCII one names the xn-- form" {
    for (std.enums.values(Problem)) |problem|
        try std.testing.expect(problem.describe().len > 0);
    try std.testing.expect(std.mem.indexOf(u8, Problem.non_ascii.describe(), "xn--") != null);
}

fn expectIpv6(text: []const u8, expected: [16]u8) !void {
    var buffer: [pattern.name_bytes_max]u8 = undefined;
    switch (pattern.parseHost(text, &buffer)) {
        .host => |host| switch (host) {
            .ipv6 => |bytes| try std.testing.expectEqualSlices(u8, &expected, &bytes),
            .name, .ipv4 => return error.TestUnexpectedResult,
        },
        .problem => |problem| {
            std.debug.print("'{s}' was refused: {s}\n", .{ text, @tagName(problem) });
            return error.TestUnexpectedResult;
        },
    }
}

fn pieces(groups: [8]u16) [16]u8 {
    var bytes: [16]u8 = undefined;
    for (groups, 0..) |group, index|
        std.mem.writeInt(u16, bytes[index * 2 ..][0..2], group, .big);
    return bytes;
}

test "IPv6 addresses read as the WHATWG URL parser reads them" {
    try expectIpv6("[::]", pieces(.{ 0, 0, 0, 0, 0, 0, 0, 0 }));
    try expectIpv6("[::1]", pieces(.{ 0, 0, 0, 0, 0, 0, 0, 1 }));
    try expectIpv6("[0:0:0:0:0:0:0:1]", pieces(.{ 0, 0, 0, 0, 0, 0, 0, 1 }));
    try expectIpv6("[1::]", pieces(.{ 1, 0, 0, 0, 0, 0, 0, 0 }));
    try expectIpv6("[1::2]", pieces(.{ 1, 0, 0, 0, 0, 0, 0, 2 }));
    try expectIpv6("[1:2:3:4:5:6:7::]", pieces(.{ 1, 2, 3, 4, 5, 6, 7, 0 }));
    try expectIpv6("[::2:3:4:5:6:7:8]", pieces(.{ 0, 2, 3, 4, 5, 6, 7, 8 }));
    try expectIpv6("[1:2:3:4:5:6:7:8]", pieces(.{ 1, 2, 3, 4, 5, 6, 7, 8 }));
    try expectIpv6("[ABCD:ef01::]", pieces(.{ 0xabcd, 0xef01, 0, 0, 0, 0, 0, 0 }));
    try expectIpv6("[1:2:3:4:5:6:1.2.3.4]", pieces(.{ 1, 2, 3, 4, 5, 6, 0x0102, 0x0304 }));
    try expectIpv6("[::1.2.3.4]", pieces(.{ 0, 0, 0, 0, 0, 0, 0x0102, 0x0304 }));
    try expectIpv6("[::ffff:0.0.0.0]", pieces(.{ 0, 0, 0, 0, 0, 0xffff, 0, 0 }));

    const refused = [_][]const u8{
        "[:1]",
        "[1:]",
        "[1:::2]",
        "[1::2::3]",
        "[12345::]",
        "[1:2:3:4:5:6:7:8:9]",
        "[1:2:3:4:5:6:7]",
        "[1:2:3:4:5:6:7:8::]",
        "[::g]",
        "[::1.2.3]",
        "[::1.2.3.4.5]",
        "[::01.2.3.4]",
        "[::1.2.3.256]",
        "[::1.2.3.]",
        "[::.1.2.3]",
        "[::1.2.3.4x]",
        "[::ffff:1.2.3.4:5]",
        "[1:2:3:4:5:6:7:1.2.3.4]",
    };
    for (refused) |text| {
        var buffer: [pattern.name_bytes_max]u8 = undefined;
        switch (pattern.parseHost(text, &buffer)) {
            .host => {
                std.debug.print("'{s}' was accepted\n", .{text});
                return error.TestUnexpectedResult;
            },
            .problem => |problem| try std.testing.expectEqual(Problem.invalid_ipv6, problem),
        }
    }
}

fn expectUrlHost(text: []const u8, expected: network.UrlHost) !void {
    var buffer: [pattern.name_bytes_max]u8 = undefined;
    switch (pattern.parseHost(text, &buffer)) {
        .host => |host| switch (expected) {
            .name => |expected_name| switch (host) {
                .name => |actual| try std.testing.expectEqualStrings(expected_name, actual),
                .ipv4, .ipv6 => return error.TestUnexpectedResult,
            },
            .ipv4, .ipv6 => try std.testing.expectEqual(expected, host),
        },
        .problem => |problem| {
            std.debug.print("'{s}' was refused: {s}\n", .{ text, @tagName(problem) });
            return error.TestUnexpectedResult;
        },
    }
}

test "a URL host reads to a canonical name or address and is not judged" {
    try expectUrlHost("API.Example.com.", .{ .name = "api.example.com" });
    try expectUrlHost("93.184.216.34", .{ .ipv4 = .{ 93, 184, 216, 34 } });
    // `localhost` and reserved addresses are hosts; the policy refuses them.
    try expectUrlHost("localhost", .{ .name = "localhost" });
    try expectUrlHost("127.0.0.1", .{ .ipv4 = .{ 127, 0, 0, 1 } });

    var buffer: [pattern.name_bytes_max]u8 = undefined;
    const refused = [_]Refused{
        .{ .text = "0177.0.0.1", .problem = .numeric_name },
        .{ .text = "127.1", .problem = .numeric_name },
        .{ .text = "exämple.com", .problem = .non_ascii },
        .{ .text = "%6cocalhost", .problem = .invalid_character },
        .{ .text = "[::1%25lo]", .problem = .ipv6_zone },
        .{ .text = "", .problem = .empty },
    };
    for (refused) |case| {
        switch (pattern.parseHost(case.text, &buffer)) {
            .host => return error.TestUnexpectedResult,
            .problem => |problem| try std.testing.expectEqual(case.problem, problem),
        }
    }
}

test "the canonical order sorts by kind, then bytes, then port" {
    const ordered = [_]Pattern{
        .{ .host = .any, .port = 0 },
        .{ .host = .{ .name = "a.example" }, .port = 0 },
        .{ .host = .{ .name = "a.example" }, .port = 8443 },
        .{ .host = .{ .name = "b.example" }, .port = 0 },
        .{ .host = .{ .suffix = "a.example" }, .port = 0 },
        .{ .host = .{ .ipv4 = .{ 1, 1, 1, 1 } }, .port = 0 },
        .{ .host = .{ .ipv4 = .{ 93, 184, 216, 34 } }, .port = 0 },
        .{ .host = .{ .ipv6 = .{ 0x26, 0x06, 0x47, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x11, 0x11 } }, .port = 0 },
    };
    for (ordered[0 .. ordered.len - 1], ordered[1..]) |left, right| {
        try std.testing.expectEqual(std.math.Order.lt, left.order(right));
        try std.testing.expectEqual(std.math.Order.gt, right.order(left));
    }
    for (ordered) |entry|
        try std.testing.expect(entry.eql(entry));
}

test "a canonical name is lowercase, dotless at the end, not numeric and not localhost" {
    try std.testing.expect(pattern.isCanonicalName("api.example.com"));
    try std.testing.expect(pattern.isCanonicalName("my_service.internal"));
    try std.testing.expect(pattern.isCanonicalName(name_253));
    try std.testing.expect(!pattern.isCanonicalName(""));
    try std.testing.expect(!pattern.isCanonicalName("API.example.com"));
    try std.testing.expect(!pattern.isCanonicalName("api.example.com."));
    try std.testing.expect(!pattern.isCanonicalName("127.0.0.1"));
    try std.testing.expect(!pattern.isCanonicalName("localhost"));
    try std.testing.expect(!pattern.isCanonicalName("api.localhost"));
    try std.testing.expect(!pattern.isCanonicalName(name_254));
    try std.testing.expect(!pattern.isCanonicalName("api..example"));
}

test "a pattern says whether it can reach a private address" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const entries = try support.parseAll(arena.allocator(), &.{
        "*", "api.example.com", "*.corp.example", "93.184.216.34", "10.0.0.5", "[fd00::1]",
    });
    const reaches = [_]bool{ false, true, true, false, true, true };
    const private = [_]bool{ false, false, false, false, true, true };
    for (entries, reaches, private) |entry, can_reach, is_private| {
        try std.testing.expectEqual(can_reach, entry.canReachPrivate());
        try std.testing.expectEqual(is_private, entry.isPrivateAddress());
    }
}
