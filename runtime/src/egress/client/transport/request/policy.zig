//! Egress target policy: parses a fetch URL into a request target and checks
//! resolved addresses, so a fetch reaches only public addresses, plus private
//! ranges when the configuration allows them. Plain http URLs are refused
//! unless `allow_plain_http` is set.
//!
//! The address check runs on what DNS returned, not on the host name, and a
//! resolution with any denied address is refused whole, so a name that mixes
//! public and internal addresses cannot reach the internal one. Before
//! resolution, `localhost` names, hosts holding a space, a control or
//! non-ASCII byte or any of `%`, `/`, `\`, `@`, and numeric hosts other than
//! canonical dotted-quad IPv4 are refused.

const std = @import("std");

const config_mod = @import("../config.zig");
const dns_cache = @import("collo_egress_dns_cache");

pub const DnsCache = dns_cache.Cache;
pub const DnsCacheConfig = dns_cache.Config;
const Protocol = config_mod.Protocol;

pub const EgressPolicy = struct {
    allow_plain_http: bool = false,
    allow_private_networks: bool = false,

    pub fn validateUrl(self: EgressPolicy, url: []const u8) !void {
        _ = try self.parseTarget(url);
    }

    pub fn validateResolvedAddress(self: EgressPolicy, address: std.net.Address) !void {
        const classification = classifyEgressAddress(address);
        if (self.permitsAddressClass(classification))
            return;
        return error.EgressDenied;
    }

    pub fn parseTarget(self: EgressPolicy, url: []const u8) !RequestTarget {
        try validateProtocol(url, self.allow_plain_http);

        const uri = try std.Uri.parse(url);
        const host_component = uri.host orelse return error.InvalidFetchUrl;
        const authority_host = host_component.percent_encoded;
        if (authority_host.len == 0)
            return error.InvalidFetchUrl;
        const lookup_host = uriHostForLookup(authority_host) orelse return error.InvalidFetchUrl;
        const security_host = normalizeHostForEgressPolicy(lookup_host) orelse return error.InvalidFetchUrl;
        if (std.ascii.eqlIgnoreCase(security_host, "localhost") or
            std.ascii.endsWithIgnoreCase(security_host, ".localhost"))
        {
            return error.EgressDenied;
        }

        const protocol = Protocol.fromScheme(uri.scheme) orelse return error.UnsupportedFetchProtocol;
        return .{
            .uri = uri,
            .authority_host = authority_host,
            .tls_server_name = security_host,
            .port = uri.port orelse defaultPort(protocol),
            .protocol = protocol,
        };
    }

    pub fn resolveRequestTarget(
        self: EgressPolicy,
        allocator: std.mem.Allocator,
        cache: *DnsCache,
        target: RequestTarget,
    ) !ResolvedTarget {
        return self.resolveRequestTargetUntil(allocator, cache, target, 0);
    }

    pub fn resolveRequestTargetUntil(
        self: EgressPolicy,
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
        return try self.resolvedTargetFromAddresses(allocator, target, addresses);
    }

    fn resolvedTargetFromAddresses(self: EgressPolicy, allocator: std.mem.Allocator, target: RequestTarget, addresses: []std.net.Address) !ResolvedTarget {
        const selected_address = try self.selectResolvedAddress(addresses);

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

    pub fn selectResolvedAddress(self: EgressPolicy, addresses: []const std.net.Address) !std.net.Address {
        if (addresses.len == 0)
            return error.HostLacksNetworkAddresses;

        var selected: ?std.net.Address = null;
        for (addresses) |address| {
            if (!self.permitsAddressClass(classifyEgressAddress(address)))
                return error.EgressDenied;
            if (selected == null)
                selected = address;
        }
        return selected.?;
    }

    fn permitsAddressClass(self: EgressPolicy, classification: AddressClass) bool {
        return switch (classification) {
            .public => true,
            .private_routable => self.allow_private_networks,
            .loopback,
            .unspecified,
            .link_local,
            .metadata,
            .shared_carrier,
            .benchmark,
            .documentation,
            .multicast,
            .broadcast,
            .reserved,
            .unknown,
            => false,
        };
    }
};

pub const RequestTarget = struct {
    uri: std.Uri,
    authority_host: []const u8,
    tls_server_name: []const u8,
    port: u16,
    protocol: Protocol,
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

pub fn validateProtocol(url: []const u8, allow_plain_http: bool) !void {
    const uri = std.Uri.parse(url) catch return error.UnsupportedFetchProtocol;
    const protocol = Protocol.fromScheme(uri.scheme) orelse return error.UnsupportedFetchProtocol;
    if (protocol == .plain and !allow_plain_http)
        return error.PlainHttpFetchDisabled;
}

const AddressClass = enum {
    public,
    private_routable,
    loopback,
    unspecified,
    link_local,
    metadata,
    shared_carrier,
    benchmark,
    documentation,
    multicast,
    broadcast,
    reserved,
    unknown,
};

fn classifyEgressAddress(address: std.net.Address) AddressClass {
    return switch (address.any.family) {
        std.posix.AF.INET => blk: {
            const bytes = ipv4Bytes(address);
            break :blk classifyIpv4Bytes(bytes);
        },
        std.posix.AF.INET6 => classifyIp6(address.in6.sa.addr),
        else => .unknown,
    };
}

pub fn ipv4Bytes(address: std.net.Address) [4]u8 {
    var bytes: [4]u8 = undefined;
    @memcpy(&bytes, std.mem.asBytes(&address.in.sa.addr));
    return bytes;
}

fn classifyIpv4Bytes(bytes: [4]u8) AddressClass {
    const b0 = bytes[0];
    const b1 = bytes[1];
    const b2 = bytes[2];
    if (b0 == 0)
        return .unspecified;
    if (b0 == 10)
        return .private_routable;
    if (b0 == 100 and (b1 & 0xc0) == 0x40)
        return .shared_carrier;
    if (b0 == 127)
        return .loopback;
    if (b0 == 169 and b1 == 254)
        return .metadata;
    if (b0 == 172 and b1 >= 16 and b1 <= 31)
        return .private_routable;
    if (b0 == 192 and b1 == 0 and b2 == 2)
        return .documentation;
    if (b0 == 192 and b1 == 0)
        return .reserved;
    if (b0 == 192 and b1 == 88 and b2 == 99)
        return .reserved;
    if (b0 == 192 and b1 == 168)
        return .private_routable;
    if (b0 == 198 and (b1 == 18 or b1 == 19))
        return .benchmark;
    if (b0 == 198 and b1 == 51 and b2 == 100)
        return .documentation;
    if (b0 == 203 and b1 == 0 and b2 == 113)
        return .documentation;
    if ((b0 & 0xf0) == 0xe0)
        return .multicast;
    if (std.mem.eql(u8, &bytes, &[_]u8{ 255, 255, 255, 255 }))
        return .broadcast;
    if ((b0 & 0xf0) == 0xf0)
        return .reserved;
    return .public;
}

fn classifyIp6(bytes: [16]u8) AddressClass {
    const all_zero = std.mem.eql(u8, &bytes, &([1]u8{0} ** 16));
    if (all_zero)
        return .unspecified;
    if (bytes[0] == 0xff)
        return .multicast;
    if (std.mem.eql(u8, bytes[0..15], &([1]u8{0} ** 15)) and bytes[15] == 1)
        return .loopback;
    if (isCloudMetadataIpv6(bytes))
        return .metadata;
    if ((bytes[0] & 0xfe) == 0xfc)
        return .private_routable;
    if (bytes[0] == 0xfe and (bytes[1] & 0xc0) == 0x80)
        return .link_local;
    if (std.mem.eql(u8, bytes[0..12], &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff })) {
        const mapped = std.net.Address.initIp4(bytes[12..16].*, 0);
        return classifyEgressAddress(mapped);
    }
    if (isWellKnownNat64Address(bytes))
        return .reserved;
    if (bytes[0] == 0x01 and bytes[1] == 0x00 and std.mem.eql(u8, bytes[2..8], &([1]u8{0} ** 6)))
        return .reserved;
    if (bytes[0] == 0x20 and bytes[1] == 0x01 and bytes[2] == 0x00 and bytes[3] == 0x02)
        return .benchmark;
    if (bytes[0] == 0x20 and bytes[1] == 0x01 and bytes[2] == 0x00 and bytes[3] <= 0x02)
        return .reserved;
    if (bytes[0] == 0x20 and bytes[1] == 0x01 and bytes[2] == 0x0d and bytes[3] == 0xb8)
        return .documentation;
    if (bytes[0] == 0x20 and bytes[1] == 0x02)
        return .reserved;
    return .public;
}

fn isWellKnownNat64Address(bytes: [16]u8) bool {
    if (std.mem.eql(u8, bytes[0..12], &[_]u8{ 0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0 }))
        return true;
    return std.mem.eql(u8, bytes[0..6], &[_]u8{ 0x00, 0x64, 0xff, 0x9b, 0, 0x01 });
}

/// The AWS instance metadata endpoint over IPv6, fd00:ec2::254.
fn isCloudMetadataIpv6(bytes: [16]u8) bool {
    return std.mem.eql(
        u8,
        &bytes,
        &[_]u8{ 0xfd, 0x00, 0x0e, 0xc2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02, 0x54 },
    );
}

pub fn defaultPort(protocol: Protocol) u16 {
    return switch (protocol) {
        .plain => 80,
        .tls => 443,
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
