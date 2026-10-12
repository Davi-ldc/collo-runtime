//! The grammar of one entry of a `network` setting's `allow` list, and the
//! canonical form both the server and the gateway compare. The
//! configuration parser reads each entry with `parse`, the policy image
//! (`table.zig`) carries the canonical patterns to the gateway, and the
//! gateway's transport reads each hop's URL host with `parseHost`, so an
//! entry and a URL host follow the same rules.
//!
//! An entry is one of these forms:
//! - `*` alone: any public host on the default port of each scheme the
//!   setting allows. It takes no port; another port needs an entry that
//!   names the host.
//! - A name: ASCII labels of letters, digits, `-` and `_`, each 1 to
//!   `label_bytes_max` bytes and neither starting nor ending with `-`, at
//!   most `name_bytes_max` bytes once one trailing dot is dropped. The
//!   canonical form is lowercase without the trailing dot. `_` is accepted
//!   because URL hosts carry it.
//! - `*.` before a name: every name with at least one more label in front,
//!   never the name itself, as a TLS wildcard certificate matches.
//! - An IPv4 address as four decimal numbers from 0 to 255 without leading
//!   zeros. A name whose last label is a decimal number, or `0x` and hex
//!   digits, is refused: a URL parser reads such a host as an IPv4 address
//!   (the WHATWG URL standard's "ends in a number" rule), so the entry would
//!   name some other address than the one it spells.
//! - An IPv6 address in brackets, without a zone, read with the WHATWG URL
//!   standard's parser and held as its 16 bytes, so every spelling of one
//!   address is one pattern.
//! Every form but `*` may end in `:port`, a decimal number from 1 to 65535
//! without leading zeros; an entry without one allows the default port of
//! the scheme.
//!
//! Refused in any spelling: a byte outside ASCII (an internationalized name
//! is written in its `xn--` form, which is what the worker's URL parser
//! sends), `localhost` and its subdomains, and an IP address of a class
//! other than public or private (`address.zig`). Whether a setting may name
//! a private address depends on its `allowPrivateNetworks`, which
//! `setting.zig` checks.
//!
//! Pure functions over borrowed bytes; any thread may call them.

const std = @import("std");
const server_limits = @import("collo_limits").server;
const address = @import("address.zig");

/// The longest name in dotted text form without a trailing dot: the
/// 255-octet wire limit of RFC 1035 written as text. It equals
/// `max_name_bytes` in `common/dns_name.zig`.
pub const name_bytes_max: usize = 253;

/// The longest label of a name (RFC 1035).
pub const label_bytes_max: usize = 63;

/// The longest entry: `*.`, a name of `name_bytes_max` bytes and `:65535`.
pub const entry_bytes_max: usize = server_limits.network_allow_entry_bytes_max;

comptime {
    std.debug.assert(entry_bytes_max == "*.".len + name_bytes_max + ":65535".len);
    // The longest IPv6 entry, with every group spelled out and a port, is
    // shorter than the longest name entry.
    std.debug.assert("[ffff:ffff:ffff:ffff:ffff:ffff:255.255.255.255]:65535".len < entry_bytes_max);
}

/// The forms of a pattern's host. The order is the canonical order of
/// `Pattern.order`, and the values are the kinds the policy image stores.
pub const Kind = enum(u8) {
    any = 0,
    name = 1,
    suffix = 2,
    ipv4 = 3,
    ipv6 = 4,
};

pub const Host = union(Kind) {
    /// `*`.
    any,
    /// A canonical name, matched whole.
    name: []const u8,
    /// The canonical name after `*.`; it matches the names that end in `.`
    /// followed by it.
    suffix: []const u8,
    ipv4: [4]u8,
    ipv6: [16]u8,
};

/// A URL's host in canonical form: a name or an IP address.
pub const UrlHost = union(enum) {
    name: []const u8,
    ipv4: [4]u8,
    ipv6: [16]u8,
};

/// One allow entry in canonical form. A name or suffix borrows the buffer
/// `parse` wrote it into.
pub const Pattern = struct {
    host: Host,
    /// The port the entry names, or 0 for the default port of the scheme.
    port: u16,

    /// The canonical order: by kind, then by name or address bytes, then by
    /// port. The policy image keeps each grant's rules in this order, and
    /// the gateway finds a host's rules by binary search over it.
    pub fn order(left: Pattern, right: Pattern) std.math.Order {
        const host_order = hostOrder(left.host, right.host);
        if (host_order != .eq)
            return host_order;
        return std.math.order(left.port, right.port);
    }

    pub fn eql(left: Pattern, right: Pattern) bool {
        return order(left, right) == .eq;
    }

    /// For sorting into the canonical order.
    pub fn lessThan(context: void, left: Pattern, right: Pattern) bool {
        _ = context;
        return order(left, right) == .lt;
    }

    /// Whether `parse` could have produced the pattern. The policy image
    /// builder takes patterns from another module, so it checks them again.
    pub fn isCanonical(entry: Pattern) bool {
        return switch (entry.host) {
            .any => entry.port == 0,
            .name, .suffix => |name| isCanonicalName(name),
            .ipv4 => |bytes| literalProblem(address.classifyIpv4(bytes)) == null,
            .ipv6 => |bytes| literalProblem(address.classifyIpv6(bytes)) == null,
        };
    }

    /// Whether a fetch the entry admits can end at a private address: a
    /// name or a suffix, which DNS may resolve to one, or a private address
    /// itself. `*` covers public addresses only.
    pub fn canReachPrivate(entry: Pattern) bool {
        return switch (entry.host) {
            .any => false,
            .name, .suffix => true,
            .ipv4, .ipv6 => entry.isPrivateAddress(),
        };
    }

    /// Whether the entry is a private IP address, which a setting may name
    /// only with `allowPrivateNetworks`.
    pub fn isPrivateAddress(entry: Pattern) bool {
        return switch (entry.host) {
            .any, .name, .suffix => false,
            .ipv4 => |bytes| address.classifyIpv4(bytes) == .private_routable,
            .ipv6 => |bytes| address.classifyIpv6(bytes) == .private_routable,
        };
    }
};

/// Orders two hosts by kind, then by their name or address bytes.
pub fn hostOrder(left: Host, right: Host) std.math.Order {
    const kind_order = std.math.order(
        @intFromEnum(std.meta.activeTag(left)),
        @intFromEnum(std.meta.activeTag(right)),
    );
    if (kind_order != .eq)
        return kind_order;
    return switch (left) {
        .any => .eq,
        .name => |name| std.mem.order(u8, name, right.name),
        .suffix => |suffix| std.mem.order(u8, suffix, right.suffix),
        .ipv4 => |bytes| std.mem.order(u8, &bytes, &right.ipv4),
        .ipv6 => |bytes| std.mem.order(u8, &bytes, &right.ipv6),
    };
}

/// Why `parse` or `parseHost` refused an entry or a host.
pub const Problem = enum {
    empty,
    too_long,
    non_ascii,
    invalid_character,
    misplaced_wildcard,
    wildcard_port,
    invalid_port,
    unbracketed_ipv6,
    invalid_ipv6,
    ipv6_zone,
    empty_label,
    label_too_long,
    label_hyphen,
    name_too_long,
    numeric_name,
    localhost,
    loopback_address,
    unspecified_address,
    link_local_address,
    metadata_address,
    shared_carrier_address,
    benchmark_address,
    documentation_address,
    multicast_address,
    broadcast_address,
    reserved_address,

    /// The sentence the configuration parser reports after the entry's key
    /// path and the entry itself.
    pub fn describe(problem: Problem) []const u8 {
        return switch (problem) {
            .empty => "an allow entry cannot be empty",
            .too_long => std.fmt.comptimePrint("an allow entry is at most {d} bytes", .{entry_bytes_max}),
            .non_ascii => "a host must be ASCII; write an internationalized name in its xn-- form",
            .invalid_character => "a host name holds only ASCII letters, digits, '-', '_' and '.'",
            .misplaced_wildcard => "a wildcard is \"*\" alone or a leading \"*.\" before a host name",
            .wildcard_port => "\"*\" takes no port; to allow another port, name the host, as in api.example.com:8443",
            .invalid_port => "a port is a decimal number from 1 to 65535 without leading zeros",
            .unbracketed_ipv6 => "an IPv6 address goes in brackets, as in [2001:db8::1]:8443",
            .invalid_ipv6 => "the text in brackets is not an IPv6 address",
            .ipv6_zone => "an IPv6 address cannot carry a zone ('%')",
            .empty_label => "a host name cannot hold an empty label, as in a..b or a leading '.'",
            .label_too_long => std.fmt.comptimePrint("a host name label is at most {d} bytes", .{label_bytes_max}),
            .label_hyphen => "a host name label cannot start or end with '-'",
            .name_too_long => std.fmt.comptimePrint("a host name is at most {d} bytes", .{name_bytes_max}),
            .numeric_name => "a host whose last label is a number reads as an IPv4 address; write the address as four decimal numbers from 0 to 255 without leading zeros",
            .localhost => "localhost and its subdomains are never reachable",
            .loopback_address => "a loopback address is never reachable",
            .unspecified_address => "an unspecified address is never reachable",
            .link_local_address => "a link-local address is never reachable",
            .metadata_address => "a link-local or cloud metadata address is never reachable",
            .shared_carrier_address => "a shared carrier-grade NAT address is never reachable",
            .benchmark_address => "a benchmarking address is never reachable",
            .documentation_address => "a documentation address is never reachable",
            .multicast_address => "a multicast address is never reachable",
            .broadcast_address => "the broadcast address is never reachable",
            .reserved_address => "a reserved address is never reachable",
        };
    }
};

pub const Parsed = union(enum) {
    pattern: Pattern,
    problem: Problem,
};

pub const ParsedHost = union(enum) {
    host: UrlHost,
    problem: Problem,
};

/// Reads one allow entry. A name or suffix in the result borrows `buffer`,
/// which holds its canonical form.
pub fn parse(text: []const u8, buffer: *[name_bytes_max]u8) Parsed {
    if (text.len == 0)
        return .{ .problem = .empty };
    if (text.len > entry_bytes_max)
        return .{ .problem = .too_long };
    // Checked before every other rule, so a Unicode name always gets the
    // hint about its `xn--` form.
    if (!isAscii(text))
        return .{ .problem = .non_ascii };
    if (std.mem.eql(u8, text, "*"))
        return .{ .pattern = .{ .host = .any, .port = 0 } };

    // The wildcard comes off first, so the rest splits like any other entry.
    const wildcard = std.mem.startsWith(u8, text, "*.");
    const rest = if (wildcard) text[2..] else text;
    if (rest.len == 0)
        return .{ .problem = .misplaced_wildcard };
    const split = switch (splitPort(rest)) {
        .split => |value| value,
        .problem => |problem| return .{ .problem = problem },
    };
    if (!wildcard and std.mem.eql(u8, split.host, "*"))
        return .{ .problem = .wildcard_port };
    var port: u16 = 0;
    if (split.port) |port_text| {
        port = parsePort(port_text) orelse return .{ .problem = .invalid_port };
    }
    if (std.mem.indexOfScalar(u8, split.host, '*') != null)
        return .{ .problem = .misplaced_wildcard };

    if (wildcard) {
        if (split.host.len == 0)
            return .{ .problem = .misplaced_wildcard };
        return switch (parseHost(split.host, buffer)) {
            .problem => |problem| .{ .problem = problem },
            .host => |host| suffixPattern(host, port),
        };
    }
    return switch (parseHost(split.host, buffer)) {
        .problem => |problem| .{ .problem = problem },
        .host => |host| hostPattern(host, port),
    };
}

/// Reads a host as a URL carries it, a name or a bracketed IPv6 address,
/// into canonical form. A name in the result borrows `buffer`. It does not
/// judge the host: `localhost` and every address class pass, since the
/// caller decides what they mean.
pub fn parseHost(text: []const u8, buffer: *[name_bytes_max]u8) ParsedHost {
    if (text.len == 0)
        return .{ .problem = .empty };
    if (text[0] == '[') {
        if (text.len < 2 or text[text.len - 1] != ']')
            return .{ .problem = .invalid_ipv6 };
        const inner = text[1 .. text.len - 1];
        if (std.mem.indexOfScalar(u8, inner, '%') != null)
            return .{ .problem = .ipv6_zone };
        const bytes = parseIpv6(inner) orelse return .{ .problem = .invalid_ipv6 };
        return .{ .host = .{ .ipv6 = bytes } };
    }
    if (!isAscii(text))
        return .{ .problem = .non_ascii };
    for (text) |byte| {
        if (!isNameByte(byte))
            return .{ .problem = .invalid_character };
    }

    const name = if (text[text.len - 1] == '.') text[0 .. text.len - 1] else text;
    if (name.len == 0)
        return .{ .problem = .empty_label };
    if (name.len > name_bytes_max)
        return .{ .problem = .name_too_long };
    const canonical = buffer[0..name.len];
    for (name, canonical) |byte, *out|
        out.* = std.ascii.toLower(byte);
    if (labelProblem(canonical)) |problem|
        return .{ .problem = problem };
    if (endsInNumber(canonical)) {
        const bytes = parseIpv4(canonical) orelse return .{ .problem = .numeric_name };
        return .{ .host = .{ .ipv4 = bytes } };
    }
    return .{ .host = .{ .name = canonical } };
}

/// Whether `name` is a name `parseHost` returns and an entry may name:
/// lowercase, without a trailing dot, within the label and length rules,
/// not ending in a number and not `localhost` or under it.
pub fn isCanonicalName(name: []const u8) bool {
    if (name.len == 0 or name.len > name_bytes_max)
        return false;
    for (name) |byte| {
        if (!isNameByte(byte) or std.ascii.isUpper(byte))
            return false;
    }
    if (labelProblem(name) != null)
        return false;
    if (endsInNumber(name))
        return false;
    return !isLocalhost(name);
}

/// `localhost` itself or any name under it, which resolvers answer with a
/// loopback address whatever DNS says.
pub fn isLocalhost(name: []const u8) bool {
    if (std.mem.eql(u8, name, "localhost"))
        return true;
    return std.mem.endsWith(u8, name, ".localhost");
}

/// The problem that refuses an address literal of `class` in an entry, or
/// null for the two classes an entry may name.
pub fn literalProblem(class: address.AddressClass) ?Problem {
    return switch (class) {
        .public, .private_routable => null,
        .loopback => .loopback_address,
        .unspecified => .unspecified_address,
        .link_local => .link_local_address,
        .metadata => .metadata_address,
        .shared_carrier => .shared_carrier_address,
        .benchmark => .benchmark_address,
        .documentation => .documentation_address,
        .multicast => .multicast_address,
        .broadcast => .broadcast_address,
        .reserved, .unknown => .reserved_address,
    };
}

fn hostPattern(host: UrlHost, port: u16) Parsed {
    switch (host) {
        .name => |name| {
            if (isLocalhost(name))
                return .{ .problem = .localhost };
            return .{ .pattern = .{ .host = .{ .name = name }, .port = port } };
        },
        .ipv4 => |bytes| {
            if (literalProblem(address.classifyIpv4(bytes))) |problem|
                return .{ .problem = problem };
            return .{ .pattern = .{ .host = .{ .ipv4 = bytes }, .port = port } };
        },
        .ipv6 => |bytes| {
            if (literalProblem(address.classifyIpv6(bytes))) |problem|
                return .{ .problem = problem };
            return .{ .pattern = .{ .host = .{ .ipv6 = bytes }, .port = port } };
        },
    }
}

fn suffixPattern(host: UrlHost, port: u16) Parsed {
    switch (host) {
        .name => |name| {
            if (isLocalhost(name))
                return .{ .problem = .localhost };
            return .{ .pattern = .{ .host = .{ .suffix = name }, .port = port } };
        },
        // A wildcard covers names; an address has no labels to add.
        .ipv4, .ipv6 => return .{ .problem = .misplaced_wildcard },
    }
}

const HostPort = struct {
    host: []const u8,
    port: ?[]const u8,
};

const Split = union(enum) {
    split: HostPort,
    problem: Problem,
};

/// Splits `host:port`. Only a bracketed IPv6 address may hold a colon of
/// its own, so a second colon outside brackets means an unbracketed one.
fn splitPort(text: []const u8) Split {
    if (text[0] == '[') {
        const close = std.mem.indexOfScalar(u8, text, ']') orelse return .{ .problem = .invalid_ipv6 };
        const rest = text[close + 1 ..];
        if (rest.len == 0)
            return .{ .split = .{ .host = text, .port = null } };
        if (rest[0] != ':')
            return .{ .problem = .invalid_ipv6 };
        return .{ .split = .{ .host = text[0 .. close + 1], .port = rest[1..] } };
    }
    const colon = std.mem.indexOfScalar(u8, text, ':') orelse
        return .{ .split = .{ .host = text, .port = null } };
    if (std.mem.indexOfScalarPos(u8, text, colon + 1, ':') != null)
        return .{ .problem = .unbracketed_ipv6 };
    return .{ .split = .{ .host = text[0..colon], .port = text[colon + 1 ..] } };
}

fn parsePort(text: []const u8) ?u16 {
    if (text.len == 0 or text.len > "65535".len)
        return null;
    if (text[0] == '0')
        return null;
    var value: u32 = 0;
    for (text) |byte| {
        if (!std.ascii.isDigit(byte))
            return null;
        value = value * 10 + (byte - '0');
    }
    if (value > std.math.maxInt(u16))
        return null;
    return @intCast(value);
}

fn isAscii(text: []const u8) bool {
    for (text) |byte| {
        if (byte >= 0x80)
            return false;
    }
    return true;
}

fn isNameByte(byte: u8) bool {
    if (std.ascii.isAlphanumeric(byte))
        return true;
    return byte == '-' or byte == '_' or byte == '.';
}

fn labelProblem(name: []const u8) ?Problem {
    var labels = std.mem.splitScalar(u8, name, '.');
    while (labels.next()) |label| {
        if (label.len == 0)
            return .empty_label;
        if (label.len > label_bytes_max)
            return .label_too_long;
        if (label[0] == '-' or label[label.len - 1] == '-')
            return .label_hyphen;
    }
    return null;
}

/// The WHATWG URL standard's "ends in a number" test on a lowercase name
/// without a trailing dot: its last label is all decimal digits, or `0x`
/// followed by hex digits only.
fn endsInNumber(name: []const u8) bool {
    const start = if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| dot + 1 else 0;
    const last = name[start..];
    if (last.len == 0)
        return false;
    if (allDigits(last, 10))
        return true;
    if (std.mem.startsWith(u8, last, "0x"))
        return allDigits(last[2..], 16);
    return false;
}

fn allDigits(text: []const u8, base: u8) bool {
    for (text) |byte| {
        if (digitValue(byte, base) == null)
            return false;
    }
    return true;
}

fn digitValue(byte: u8, base: u8) ?u8 {
    const value: u8 = switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => return null,
    };
    if (value < base)
        return value;
    return null;
}

/// Four decimal numbers from 0 to 255 separated by dots, without leading
/// zeros: the one IPv4 spelling that every parser reads the same way.
fn parseIpv4(text: []const u8) ?[4]u8 {
    var bytes: [4]u8 = undefined;
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, text, '.');
    while (parts.next()) |part| {
        if (count == bytes.len)
            return null;
        if (part.len == 0 or part.len > 3)
            return null;
        if (part.len > 1 and part[0] == '0')
            return null;
        var value: u16 = 0;
        for (part) |byte| {
            const digit = digitValue(byte, 10) orelse return null;
            value = value * 10 + digit;
        }
        if (value > 255)
            return null;
        bytes[count] = @intCast(value);
        count += 1;
    }
    if (count != bytes.len)
        return null;
    return bytes;
}

/// The WHATWG URL standard's IPv6 parser, so an entry and the worker's URL
/// read one address the same way: up to eight groups of one to four hex
/// digits, one `::` standing for one or more zero groups, and an optional
/// IPv4 address in the last two groups, written without leading zeros.
fn parseIpv6(text: []const u8) ?[16]u8 {
    var pieces: [8]u16 = @splat(0);
    var piece_index: usize = 0;
    var compress: ?usize = null;
    var cursor: usize = 0;

    if (text.len > 0 and text[0] == ':') {
        if (text.len < 2 or text[1] != ':')
            return null;
        cursor = 2;
        piece_index = 1;
        compress = piece_index;
    }
    while (cursor < text.len) {
        if (piece_index == pieces.len)
            return null;
        if (text[cursor] == ':') {
            if (compress != null)
                return null;
            cursor += 1;
            piece_index += 1;
            compress = piece_index;
            continue;
        }
        var value: u16 = 0;
        var length: usize = 0;
        while (length < 4 and cursor < text.len) {
            const digit = digitValue(text[cursor], 16) orelse break;
            value = value * 16 + digit;
            cursor += 1;
            length += 1;
        }
        if (cursor < text.len and text[cursor] == '.') {
            if (length == 0)
                return null;
            if (piece_index > pieces.len - 2)
                return null;
            cursor -= length;
            if (!parseEmbeddedIpv4(text[cursor..], &pieces, piece_index))
                return null;
            piece_index += 2;
            break;
        }
        if (cursor < text.len) {
            if (text[cursor] != ':')
                return null;
            cursor += 1;
            if (cursor == text.len)
                return null;
        }
        pieces[piece_index] = value;
        piece_index += 1;
    }

    if (compress) |start| {
        var swaps = piece_index - start;
        var index: usize = pieces.len - 1;
        while (index != 0 and swaps > 0) {
            std.mem.swap(u16, &pieces[index], &pieces[start + swaps - 1]);
            index -= 1;
            swaps -= 1;
        }
    } else if (piece_index != pieces.len) {
        return null;
    }

    var bytes: [16]u8 = undefined;
    for (pieces, 0..) |piece, index|
        std.mem.writeInt(u16, bytes[index * 2 ..][0..2], piece, .big);
    return bytes;
}

/// Reads the rest of an IPv6 text as a dotted IPv4 address into the two
/// pieces at `piece_index`. Each number has no leading zero, as the WHATWG
/// parser requires, and nothing may follow the fourth.
fn parseEmbeddedIpv4(text: []const u8, pieces: *[8]u16, piece_index: usize) bool {
    var numbers_seen: usize = 0;
    var cursor: usize = 0;
    while (cursor < text.len) {
        if (numbers_seen > 0) {
            if (text[cursor] != '.' or numbers_seen == 4)
                return false;
            cursor += 1;
        }
        if (cursor == text.len or !std.ascii.isDigit(text[cursor]))
            return false;
        var part: u16 = 0;
        var digits: usize = 0;
        while (cursor < text.len and std.ascii.isDigit(text[cursor])) {
            if (digits == 1 and part == 0)
                return false;
            part = part * 10 + (text[cursor] - '0');
            if (part > 255)
                return false;
            digits += 1;
            cursor += 1;
        }
        const target = piece_index + numbers_seen / 2;
        pieces[target] = pieces[target] * 0x100 + part;
        numbers_seen += 1;
    }
    return numbers_seen == 4;
}
