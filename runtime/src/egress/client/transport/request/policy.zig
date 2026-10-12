//! Egress target policy: a hop's URL becomes a request target only when the
//! fetch's network policy admits the hop's scheme, host and effective port
//! (`collo_network.admit`), and the addresses DNS returns for that host are
//! then checked against the admission (`collo_network.admitAddress`). Every
//! hop of every fetch, redirects included, passes through `parseTarget`
//! (`request/plan.zig:prepareRequest`), and every connector resolves through
//! `resolveRequestTargetUntil`, so the rule a configuration error states is
//! the rule each hop meets.
//!
//! Before the policy sees a host, hosts holding a space, a control or
//! non-ASCII byte or any of `%`, `/`, `\`, `@`, and numeric hosts other than
//! canonical dotted-quad IPv4 are refused as invalid URLs. The address check
//! runs on what DNS returned, not on the host name, and a resolution with any
//! denied address is refused whole, so a name that mixes public and internal
//! addresses cannot reach the internal one.
//!
//! A refusal by the policy is one of the `DenialError`s, one per
//! `collo_network.Denial`, so the gateway can tell the worker why
//! (`denialOf`) without a gateway log line: a denial is the tenant's event.

const std = @import("std");

const config_mod = @import("../config.zig");
const dns_cache = @import("collo_egress_dns_cache");
const network = @import("collo_network");

pub const DnsCache = dns_cache.Cache;
pub const DnsCacheConfig = dns_cache.Config;
const Protocol = config_mod.Protocol;

/// The errors a hop the network policy refuses fails with, one per
/// `network.Denial` (`denialError`, `denialOf`).
pub const DenialError = error{
    EgressNotGranted,
    EgressHostDenied,
    EgressPortDenied,
    EgressSchemeDenied,
    EgressPrivateAddressDenied,
    EgressReservedAddressDenied,
};

pub fn denialError(denial: network.Denial) DenialError {
    return switch (denial) {
        .no_grant => error.EgressNotGranted,
        .host_not_allowed => error.EgressHostDenied,
        .port_not_allowed => error.EgressPortDenied,
        .http_not_allowed => error.EgressSchemeDenied,
        .private_address => error.EgressPrivateAddressDenied,
        .reserved_address => error.EgressReservedAddressDenied,
    };
}

/// The denial `err` reports, or null for an error that is no denial.
pub fn denialOf(err: anyerror) ?network.Denial {
    return switch (err) {
        error.EgressNotGranted => .no_grant,
        error.EgressHostDenied => .host_not_allowed,
        error.EgressPortDenied => .port_not_allowed,
        error.EgressSchemeDenied => .http_not_allowed,
        error.EgressPrivateAddressDenied => .private_address,
        error.EgressReservedAddressDenied => .reserved_address,
        else => null,
    };
}

comptime {
    // Every denial has its own error, and the error maps back to it.
    for (std.enums.values(network.Denial)) |denial|
        std.debug.assert(denialOf(denialError(denial)).? == denial);
}

/// Parses `url` into the target of one hop and decides it under `policy`
/// before any DNS query. Fails with `error.UnsupportedFetchProtocol` for a
/// scheme other than `http` and `https`, `error.InvalidFetchUrl` for a URL
/// or host the transport refuses on its own, and a `DenialError` when the
/// policy refuses the hop; a host no allow entry could name is
/// `error.EgressHostDenied`.
pub fn parseTarget(policy: network.Policy, url: []const u8) !RequestTarget {
    const uri = try std.Uri.parse(url);
    const protocol = Protocol.fromScheme(uri.scheme) orelse return error.UnsupportedFetchProtocol;
    const host_component = uri.host orelse return error.InvalidFetchUrl;
    const authority_host = host_component.percent_encoded;
    if (authority_host.len == 0)
        return error.InvalidFetchUrl;
    const lookup_host = uriHostForLookup(authority_host) orelse return error.InvalidFetchUrl;
    const security_host = normalizeHostForEgressPolicy(lookup_host) orelse return error.InvalidFetchUrl;

    var name_buffer: [network.pattern.name_bytes_max]u8 = undefined;
    const target = network.Target.init(
        schemeOf(protocol),
        authority_host,
        uri.port,
        &name_buffer,
    ) orelse return error.EgressHostDenied;
    const admission = switch (network.admit(policy, target)) {
        .admitted => |admitted| admitted,
        .denied => |denial| return denialError(denial),
    };
    return .{
        .uri = uri,
        .authority_host = authority_host,
        .tls_server_name = security_host,
        .port = target.port,
        .protocol = protocol,
        .admission = admission,
    };
}

/// Resolves an admitted target and checks every address DNS returned
/// against its admission (`selectResolvedAddress`).
pub fn resolveRequestTargetUntil(
    allocator: std.mem.Allocator,
    cache: *DnsCache,
    target: RequestTarget,
    request_deadline_mono_ns: u64,
) !ResolvedTarget {
    const addresses = try cache.resolveUntil(
        allocator,
        target.tls_server_name,
        target.port,
        request_deadline_mono_ns,
    );
    errdefer allocator.free(addresses);
    const selected_address = try selectResolvedAddress(target.admission, addresses);
    return .{
        .uri = target.uri,
        .authority_host = target.authority_host,
        .tls_server_name = target.tls_server_name,
        .connect_host = try addressHostAlloc(allocator, selected_address),
        .connect_addresses = addresses,
        .port = target.port,
        .protocol = target.protocol,
    };
}

/// The first of `addresses`, once every one of them passes `admission`.
/// Fails with `error.HostLacksNetworkAddresses` for an empty answer and
/// with `error.EgressPrivateAddressDenied` or
/// `error.EgressReservedAddressDenied` when any address is refused, so the
/// resolution is refused whole.
pub fn selectResolvedAddress(admission: network.Admission, addresses: []const std.net.Address) !std.net.Address {
    if (addresses.len == 0)
        return error.HostLacksNetworkAddresses;
    for (addresses) |address| {
        if (network.admitAddress(admission, address)) |denial|
            return denialError(denial);
    }
    return addresses[0];
}

pub const RequestTarget = struct {
    uri: std.Uri,
    authority_host: []const u8,
    tls_server_name: []const u8,
    /// The port the hop connects to: the URL's, or the scheme's default.
    port: u16,
    protocol: Protocol,
    /// What the policy granted this hop, which every resolved address must
    /// pass.
    admission: network.Admission,
};

pub const ResolvedTarget = struct {
    uri: std.Uri,
    authority_host: []const u8,
    tls_server_name: []const u8,
    connect_host: []u8,
    connect_addresses: []std.net.Address,
    port: u16,
    protocol: Protocol,

    pub fn deinit(self: *ResolvedTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.connect_addresses);
        allocator.free(self.connect_host);
        self.* = undefined;
    }
};

pub const ipv4Bytes = network.address.ipv4Bytes;

pub fn defaultPort(protocol: Protocol) u16 {
    return schemeOf(protocol).defaultPort();
}

fn schemeOf(protocol: Protocol) network.Scheme {
    return switch (protocol) {
        .plain => .http,
        .tls => .https,
    };
}

fn uriHostForLookup(authority_host: []const u8) ?[]const u8 {
    if (authority_host.len == 0)
        return null;
    if (authority_host[0] != '[')
        return authority_host;
    if (authority_host[authority_host.len - 1] != ']')
        return null;
    const inner = authority_host[1 .. authority_host.len - 1];
    if (inner.len == 0)
        return null;
    _ = std.net.Address.parseIp6(inner, 0) catch return null;
    return inner;
}

fn normalizeHostForEgressPolicy(host: []const u8) ?[]const u8 {
    var end = host.len;
    while (end > 0 and host[end - 1] == '.')
        end -= 1;
    if (end == 0)
        return null;
    const normalized = host[0..end];
    if (!isSafeAsciiHost(normalized))
        return null;
    if (looksLikeNonCanonicalIpv4Literal(normalized))
        return null;
    return normalized;
}

fn isSafeAsciiHost(host: []const u8) bool {
    for (host) |byte| {
        if (byte <= 0x20 or byte >= 0x7f)
            return false;
        switch (byte) {
            '%', '/', '\\', '@' => return false,
            else => {},
        }
    }
    return true;
}

fn looksLikeNonCanonicalIpv4Literal(host: []const u8) bool {
    var has_dot = false;
    for (host) |byte| {
        if (byte == '.') {
            has_dot = true;
            continue;
        }
        if (byte < '0' or byte > '9')
            return false;
    }
    if (!has_dot)
        return true;

    var segments = std.mem.splitScalar(u8, host, '.');
    var count: usize = 0;
    while (segments.next()) |segment| {
        count += 1;
        if (segment.len == 0 or segment.len > 3)
            return true;
        if (segment.len > 1 and segment[0] == '0')
            return true;
        const value = std.fmt.parseUnsigned(u16, segment, 10) catch return true;
        if (value > 255)
            return true;
    }
    return count != 4;
}

fn addressHostAlloc(allocator: std.mem.Allocator, address: std.net.Address) ![]u8 {
    var scratch: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&scratch);
    try address.format(&writer);
    const formatted = writer.buffered();

    return switch (address.any.family) {
        std.posix.AF.INET => blk: {
            const colon = std.mem.lastIndexOfScalar(u8, formatted, ':') orelse return error.InvalidFetchAddress;
            break :blk try allocator.dupe(u8, formatted[0..colon]);
        },
        std.posix.AF.INET6 => blk: {
            if (formatted.len < 3 or formatted[0] != '[')
                return error.InvalidFetchAddress;
            const close = std.mem.indexOfScalar(u8, formatted, ']') orelse return error.InvalidFetchAddress;
            break :blk try allocator.dupe(u8, formatted[1..close]);
        },
        else => error.InvalidFetchAddress,
    };
}
