//! Matching one hop of a fetch against the grants of its policy, and the
//! text of a refusal. A grant is one `network` setting compiled: its entries
//! in canonical order, split by kind so that a lookup is a binary search,
//! and the setting's two flags. A policy is a list of grants and admits a
//! hop when any of them does. A route's policy holds its one grant, and a
//! worker definition's boot policy holds the distinct grants of its routes,
//! so module top-level code reaches the union of what the routes reach and
//! one route's flags never apply to another route's entries. Policy 0 holds
//! no grant and admits nothing.
//!
//! The transport checks each hop twice. `admit` runs before DNS, on the
//! scheme, the host and the effective port. An entry matches the host when
//! it is `*`, the same name, a `*.suffix` the name ends under, or the same
//! address bytes; it matches the port when it names that port, or names
//! none and the port is the scheme's default (80 or 443). A matching entry
//! admits `https`, and `http` only when its setting has `allowHttp`. The
//! admission allows a private address when an admitting entry other than
//! `*` belongs to a setting with `allowPrivateNetworks`. `admitAddress` then
//! checks every address DNS returned against that admission. A host given
//! as an address is checked against its own class inside `admit`, so its
//! verdict never depends on the resolver.
//!
//! A denial says what to change (`Denial.describe`), which is why `admit`
//! tells near misses apart: a host no entry names, a plain HTTP fetch that
//! no setting naming the host allows, and a host named only for other
//! ports.
//!
//! Grants and policies are views into memory their owner keeps alive: the
//! gateway's decoded table (`table.zig`) for the gateway's life, or the
//! constants below. Matching allocates nothing; any thread may call it.

const std = @import("std");
const address = @import("address.zig");
const pattern = @import("pattern.zig");

const Pattern = pattern.Pattern;
const Host = pattern.Host;
const UrlHost = pattern.UrlHost;

pub const Scheme = enum {
    http,
    https,

    pub fn defaultPort(scheme: Scheme) u16 {
        return switch (scheme) {
            .http => 80,
            .https => 443,
        };
    }

    pub fn text(scheme: Scheme) []const u8 {
        return switch (scheme) {
            .http => "http",
            .https => "https",
        };
    }
};

pub const Grant = struct {
    allow_http: bool,
    allow_private_networks: bool,
    /// The setting lists `*`.
    any: bool,
    /// The rules of each kind, each slice in canonical order
    /// (`Pattern.order`).
    names: []const Pattern,
    suffixes: []const Pattern,
    ipv4: []const Pattern,
    ipv6: []const Pattern,
};

pub const Policy = struct {
    grants: []const *const Grant,
};

/// The hop a fetch is about to make.
pub const Target = struct {
    scheme: Scheme,
    host: UrlHost,
    /// The port the hop connects to: the URL's, or the scheme's default.
    /// No entry matches port 0, which an entry cannot name.
    port: u16,

    /// The target of a hop to `host`, as the URL spells it with an IPv6
    /// address in brackets, and `port`, the URL's explicit port or null for
    /// the scheme's default. The canonical name is written into `buffer`,
    /// which the target borrows. Null when the host is not one an allow
    /// entry could name (`pattern.parseHost`); the transport refuses such a
    /// URL.
    pub fn init(
        scheme: Scheme,
        host: []const u8,
        port: ?u16,
        buffer: *[pattern.name_bytes_max]u8,
    ) ?Target {
        const parsed = switch (pattern.parseHost(host, buffer)) {
            .host => |value| value,
            .problem => return null,
        };
        return .{ .scheme = scheme, .host = parsed, .port = port orelse scheme.defaultPort() };
    }
};

pub const Admission = struct {
    /// Whether the hop may reach a private address. It holds only when an
    /// admitting entry other than `*` belongs to a setting with
    /// `allowPrivateNetworks`.
    allow_private_networks: bool,
};

pub const Decision = union(enum) {
    admitted: Admission,
    denied: Denial,
};

/// Why a hop was refused. The transport raises one error per denial, and
/// the gateway sends the denial's text to the worker (`writeDenial`).
pub const Denial = enum {
    no_grant,
    host_not_allowed,
    port_not_allowed,
    http_not_allowed,
    private_address,
    reserved_address,

    pub fn describe(denial: Denial) []const u8 {
        return switch (denial) {
            .no_grant => "no network setting grants access to this route",
            .host_not_allowed => "the host is not in the allow list",
            .port_not_allowed => "the host is allowed only on other ports; list it as host:port",
            .http_not_allowed => "plain HTTP needs allowHttp",
            .private_address => "the host is or resolves to a private address, which needs allowPrivateNetworks and an entry that names the host",
            .reserved_address => "the host is or resolves to a loopback, link-local, metadata or other reserved address, which is never reachable",
        };
    }
};

/// The policy with no grant, policy 0 of every table.
pub const deny_all: Policy = .{ .grants = &.{} };

const public_https_grant: Grant = .{
    .allow_http = false,
    .allow_private_networks = false,
    .any = true,
    .names = &.{},
    .suffixes = &.{},
    .ipv4 = &.{},
    .ipv6 = &.{},
};

/// The setting `"allow": ["*"]` alone: any public host over HTTPS on port
/// 443. For transport callers that run without a gateway's table, such as
/// benchmarks.
pub const public_https: Policy = .{ .grants = &.{&public_https_grant} };

/// Decides a hop before DNS. A localhost name and an address of a class no
/// entry may name are refused before any grant is consulted; a policy
/// without grants is refused first of all.
pub fn admit(policy: Policy, target: Target) Decision {
    if (policy.grants.len == 0)
        return .{ .denied = .no_grant };

    var literal_class: ?address.AddressClass = null;
    switch (target.host) {
        .name => |name| {
            if (pattern.isLocalhost(name))
                return .{ .denied = .reserved_address };
        },
        .ipv4 => |bytes| literal_class = address.classifyIpv4(bytes),
        .ipv6 => |bytes| literal_class = address.classifyIpv6(bytes),
    }
    if (literal_class) |class| {
        if (!address.permitted(class, true))
            return .{ .denied = .reserved_address };
    }

    var admitted = false;
    var admitted_private = false;
    var host_named = false;
    var scheme_allowed = false;
    for (policy.grants) |grant| {
        const match = matchGrant(grant, target);
        if (!match.host)
            continue;
        host_named = true;
        if (target.scheme == .http and !grant.allow_http)
            continue;
        scheme_allowed = true;
        if (!match.port)
            continue;
        admitted = true;
        if (match.private)
            admitted_private = true;
    }

    if (admitted) {
        if (literal_class) |class| {
            if (!address.permitted(class, admitted_private))
                return .{ .denied = .private_address };
        }
        return .{ .admitted = .{ .allow_private_networks = admitted_private } };
    }
    if (!host_named)
        return .{ .denied = .host_not_allowed };
    if (!scheme_allowed)
        return .{ .denied = .http_not_allowed };
    return .{ .denied = .port_not_allowed };
}

/// Decides one address DNS returned for an admitted hop: null when the
/// hop may connect to it.
pub fn admitAddress(admission: Admission, resolved: std.net.Address) ?Denial {
    const class = address.classify(resolved);
    if (address.permitted(class, admission.allow_private_networks))
        return null;
    if (class == .private_routable)
        return .private_address;
    return .reserved_address;
}

/// The origin a denial names: the hop's scheme, its host as the URL spells
/// it, with an IPv6 address in brackets, and its effective port.
pub const Origin = struct {
    scheme: Scheme,
    host: []const u8,
    port: u16,
};

const denial_prefix = "fetch to ";
const denial_infix = " denied by the network setting: ";
const host_ellipsis = "...";

/// The longest host a denial shows; a longer one is cut and ends in `...`.
/// No entry can name a longer host.
pub const denial_host_bytes_max: usize = pattern.entry_bytes_max;

/// The longest text `writeDenial` writes, for callers that size a buffer
/// for it.
pub const denial_bytes_max: usize = blk: {
    var reason_bytes_max: usize = 0;
    for (std.enums.values(Denial)) |denial|
        reason_bytes_max = @max(reason_bytes_max, denial.describe().len);
    break :blk denial_prefix.len + "https://".len + denial_host_bytes_max + host_ellipsis.len +
        ":65535".len + denial_infix.len + reason_bytes_max;
};

/// Writes `fetch to <origin> denied by the network setting: <reason>`. The
/// origin is `scheme://host`, with `:port` when the port is not the
/// scheme's default. The host comes from a tenant's URL, so every byte that
/// is not a visible ASCII character is written as `?`, and a host past
/// `denial_host_bytes_max` is cut.
pub fn writeDenial(writer: *std.Io.Writer, origin: Origin, denial: Denial) std.Io.Writer.Error!void {
    try writer.writeAll(denial_prefix);
    try writer.writeAll(origin.scheme.text());
    try writer.writeAll("://");
    const shown = origin.host[0..@min(origin.host.len, denial_host_bytes_max)];
    for (shown) |byte| {
        const printable = byte > 0x20 and byte < 0x7f;
        try writer.writeByte(if (printable) byte else '?');
    }
    if (shown.len < origin.host.len)
        try writer.writeAll(host_ellipsis);
    if (origin.port != origin.scheme.defaultPort())
        try writer.print(":{d}", .{origin.port});
    try writer.writeAll(denial_infix);
    try writer.writeAll(denial.describe());
}

const GrantMatch = struct {
    /// Some entry names the host.
    host: bool = false,
    /// Some entry names the host and the port.
    port: bool = false,
    /// Some entry other than `*` names the host and the port, and the
    /// setting allows private networks.
    private: bool = false,
};

fn matchGrant(grant: *const Grant, target: Target) GrantMatch {
    var match: GrantMatch = .{};
    if (grant.any) {
        match.host = true;
        if (target.port == target.scheme.defaultPort())
            match.port = true;
    }
    switch (target.host) {
        .name => |name| {
            matchRules(grant, equalRun(grant.names, .{ .name = name }), target, &match);
            // Every proper suffix that starts at a label boundary. A name has
            // at most `name_bytes_max` bytes, which bounds the lookups.
            var start: usize = 0;
            while (std.mem.indexOfScalarPos(u8, name, start, '.')) |dot| {
                const suffix = name[dot + 1 ..];
                matchRules(grant, equalRun(grant.suffixes, .{ .suffix = suffix }), target, &match);
                start = dot + 1;
            }
        },
        .ipv4 => |bytes| matchRules(grant, equalRun(grant.ipv4, .{ .ipv4 = bytes }), target, &match),
        .ipv6 => |bytes| matchRules(grant, equalRun(grant.ipv6, .{ .ipv6 = bytes }), target, &match),
    }
    return match;
}

/// Records what `rules`, which all name the target's host, match.
fn matchRules(grant: *const Grant, rules: []const Pattern, target: Target, match: *GrantMatch) void {
    for (rules) |rule| {
        match.host = true;
        if (portMatches(rule.port, target)) {
            match.port = true;
            if (grant.allow_private_networks)
                match.private = true;
        }
    }
}

fn portMatches(rule_port: u16, target: Target) bool {
    if (rule_port == 0)
        return target.port == target.scheme.defaultPort();
    return rule_port == target.port;
}

/// The rules of `rules`, sorted in canonical order, whose host equals
/// `host`: one binary search, then the run of equal hosts, which differ
/// only in their ports.
fn equalRun(rules: []const Pattern, host: Host) []const Pattern {
    var low: usize = 0;
    var high: usize = rules.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (pattern.hostOrder(rules[middle].host, host) == .lt) {
            low = middle + 1;
        } else {
            high = middle;
        }
    }
    var end = low;
    while (end < rules.len and pattern.hostOrder(rules[end].host, host) == .eq)
        end += 1;
    return rules[low..end];
}
