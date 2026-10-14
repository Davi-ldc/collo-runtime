//! Egress target policy: a hop's URL becomes a request target only when the
//! fetch's network policy admits the hop's scheme, host and effective port
//! (`collo_network.admit`), and the addresses DNS returns for that host are
//! then checked against the admission (`collo_network.admitAddress`). Every
//! hop of every fetch, redirects included, passes through `parseTarget`
//! (`request/plan.zig:prepareRequest`), and every dial checks what DNS
//! returned with `admitResolvedAddresses`, so the rule a configuration error
//! states is the rule each hop meets.
//!
//! The host is read once, by the grammar allow entries are written in
//! (`collo_network.Target.init`, `pattern.parseHost`): a host it cannot read,
//! such as one holding a space, a control or non-ASCII byte, any of `%`, `/`,
//! `\`, `@`, an empty label, or a number other than canonical dotted-quad
//! IPv4, is an invalid URL. The address check runs on what DNS returned, not
//! on the host name, and a resolution with any denied address is refused
//! whole, so a name that mixes public and internal addresses cannot reach the
//! internal one.
//!
//! A refusal by the policy is one of the `DenialError`s, one per
//! `collo_network.Denial`, so the gateway can tell the worker why
//! (`denialOf`) without a gateway log line: a denial is the tenant's event.

const std = @import("std");

const config_mod = @import("../config.zig");
const network = @import("collo_network");

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
/// or a host no allow entry could name, and a `DenialError` when the policy
/// refuses the hop.
pub fn parseTarget(policy: network.Policy, url: []const u8) !RequestTarget {
    const uri = try std.Uri.parse(url);
    const protocol = Protocol.fromScheme(uri.scheme) orelse return error.UnsupportedFetchProtocol;
    const host_component = uri.host orelse return error.InvalidFetchUrl;
    const authority_host = host_component.percent_encoded;

    var name_buffer: [network.pattern.name_bytes_max]u8 = undefined;
    const target = network.Target.init(
        schemeOf(protocol),
        authority_host,
        uri.port,
        &name_buffer,
    ) orelse return error.InvalidFetchUrl;
    const admission = switch (network.admit(policy, target)) {
        .admitted => |admitted| admitted,
        .denied => |denial| return denialError(denial),
    };
    return .{
        .uri = uri,
        .authority_host = authority_host,
        .tls_server_name = lookupName(authority_host),
        .port = target.port,
        .protocol = protocol,
        .admission = admission,
    };
}

/// The name DNS resolves and TLS sends: `authority_host` without IPv6
/// brackets or a trailing dot. Only for a host `network.Target.init`
/// accepted, which proves the brackets close and at most one trailing dot
/// ends a non-empty name. DNS and TLS compare names without case, so the
/// URL's spelling serves.
fn lookupName(authority_host: []const u8) []const u8 {
    std.debug.assert(authority_host.len != 0);
    if (authority_host[0] == '[')
        return authority_host[1 .. authority_host.len - 1];
    if (authority_host[authority_host.len - 1] == '.')
        return authority_host[0 .. authority_host.len - 1];
    return authority_host;
}

/// Checks that every one of `addresses` passes `admission`. Fails with
/// `error.HostLacksNetworkAddresses` for an empty answer and with
/// `error.EgressPrivateAddressDenied` or `error.EgressReservedAddressDenied`
/// when any address is refused, so the resolution is refused whole.
pub fn admitResolvedAddresses(admission: network.Admission, addresses: []const std.net.Address) !void {
    if (addresses.len == 0)
        return error.HostLacksNetworkAddresses;
    for (addresses) |address| {
        if (network.admitAddress(admission, address)) |denial|
            return denialError(denial);
    }
}

/// One hop's target. Its slices borrow the URL `parseTarget` read.
pub const RequestTarget = struct {
    uri: std.Uri,
    /// The host as the URL spells it, IPv6 brackets included: the request's
    /// authority.
    authority_host: []const u8,
    /// The name DNS resolves and TLS sends (`lookupName`).
    tls_server_name: []const u8,
    /// The port the hop connects to: the URL's, or the scheme's default.
    port: u16,
    protocol: Protocol,
    /// What the policy granted this hop, which every resolved address must
    /// pass.
    admission: network.Admission,
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
