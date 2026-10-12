//! The address classes that decide where an outbound fetch may connect. A
//! public address passes under any grant that admits the fetch's host, a
//! private one only under a grant whose setting has `allowPrivateNetworks`
//! and whose entry names the host, and every other class never passes. The
//! gateway's transport classifies each address DNS returns, and the
//! configuration parser each address an allow entry names, with this one
//! table, so an entry the parser accepts is one the gateway can reach.
//!
//! The ranges follow the IANA special-purpose address registries. All of
//! 169.254.0.0/16 counts as metadata, since cloud providers serve instance
//! metadata and other host services from several addresses in it. The
//! host-service addresses a provider documents outside that range count as
//! metadata one by one (`cloud_metadata_ipv4`, `cloud_metadata_ipv6`): the
//! IPv6 ones sit inside unique-local space where a tenant's private hosts
//! also live, so no wider prefix can be carved out. An IPv4-mapped IPv6
//! address takes the class of its IPv4 address. Every other IPv6 address
//! outside the global unicast 2000::/3 is reserved: that space holds the
//! IPv4-compatible and IPv4-translated prefixes and the well-known prefixes
//! of IPv6 to IPv4 translation, which a translator or tunnel would carry to
//! an embedded IPv4 address of any class, along with the discard prefix,
//! deprecated site-local space and unassigned space, none of which reaches
//! a public host.
//!
//! Pure functions; any thread may call them.

const std = @import("std");

pub const AddressClass = enum {
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
    /// A socket address of a family other than IPv4 and IPv6.
    unknown,
};

/// Whether a fetch may connect to an address of `class`: a public one
/// always, a private one only when the admission allowed private networks,
/// and any other class never.
pub fn permitted(class: AddressClass, allow_private_networks: bool) bool {
    return switch (class) {
        .public => true,
        .private_routable => allow_private_networks,
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

pub fn classify(address: std.net.Address) AddressClass {
    return switch (address.any.family) {
        std.posix.AF.INET => classifyIpv4(ipv4Bytes(address)),
        std.posix.AF.INET6 => classifyIpv6(address.in6.sa.addr),
        else => .unknown,
    };
}

/// The four bytes of an IPv4 socket address in network order, as written.
pub fn ipv4Bytes(address: std.net.Address) [4]u8 {
    var bytes: [4]u8 = undefined;
    @memcpy(&bytes, std.mem.asBytes(&address.in.sa.addr));
    return bytes;
}

pub fn classifyIpv4(bytes: [4]u8) AddressClass {
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
    if (isCloudMetadataIpv4(bytes))
        return .metadata;
    if (b0 == 172 and b1 >= 16 and b1 <= 31)
        return .private_routable;
    if (b0 == 192 and b1 == 0 and b2 == 0)
        return .reserved;
    if (b0 == 192 and b1 == 0 and b2 == 2)
        return .documentation;
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

pub fn classifyIpv6(bytes: [16]u8) AddressClass {
    const all_zero = std.mem.eql(u8, &bytes, &([1]u8{0} ** 16));
    if (all_zero)
        return .unspecified;
    if (std.mem.eql(u8, bytes[0..15], &([1]u8{0} ** 15)) and bytes[15] == 1)
        return .loopback;
    if (std.mem.eql(u8, bytes[0..12], &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff }))
        return classifyIpv4(bytes[12..16].*);
    if (bytes[0] == 0xff)
        return .multicast;
    // The host-service addresses lie inside fc00::/7, so they are matched
    // before the private class.
    if (isCloudMetadataIpv6(bytes))
        return .metadata;
    if ((bytes[0] & 0xfe) == 0xfc)
        return .private_routable;
    if (bytes[0] == 0xfe and (bytes[1] & 0xc0) == 0x80)
        return .link_local;
    if ((bytes[0] & 0xe0) != 0x20)
        return .reserved;
    if (bytes[0] == 0x20 and bytes[1] == 0x01 and bytes[2] == 0x00 and bytes[3] == 0x02)
        return .benchmark;
    if (bytes[0] == 0x20 and bytes[1] == 0x01 and bytes[2] == 0x00 and bytes[3] <= 0x02)
        return .reserved;
    if (bytes[0] == 0x20 and bytes[1] == 0x01 and bytes[2] == 0x0d and bytes[3] == 0xb8)
        return .documentation;
    if (bytes[0] == 0x20 and bytes[1] == 0x02)
        return .reserved;
    if (bytes[0] == 0x3f and bytes[1] == 0xff and (bytes[2] & 0xf0) == 0)
        return .documentation;
    return .public;
}

/// Host-service addresses a cloud provider serves to the node itself from
/// public IPv4 space, each from the provider's documentation: Azure's
/// WireServer at 168.63.129.16 (guest agent, extension settings, DNS and
/// DHCP for the VM).
const cloud_metadata_ipv4 = [_][4]u8{
    .{ 168, 63, 129, 16 },
};

/// Host-service addresses cloud providers serve to the node itself over
/// IPv6, each from the provider's documentation. A tenant that reaches one
/// reads the node's credentials or talks to its resolver as the node.
const cloud_metadata_ipv6 = [_][16]u8{
    // AWS instance metadata, Route 53 Resolver and Time Sync, on Nitro.
    ipv6Groups(.{ 0xfd00, 0x0ec2, 0, 0, 0, 0, 0, 0x0254 }),
    ipv6Groups(.{ 0xfd00, 0x0ec2, 0, 0, 0, 0, 0, 0x0253 }),
    ipv6Groups(.{ 0xfd00, 0x0ec2, 0, 0, 0, 0, 0, 0x0123 }),
    // Google Cloud's metadata server for IPv6-only instances.
    ipv6Groups(.{ 0xfd20, 0x00ce, 0, 0, 0, 0, 0, 0x0254 }),
    // Akamai Linode's metadata service.
    ipv6Groups(.{ 0xfd00, 0xa9fe, 0xa9fe, 0, 0, 0, 0, 0x0001 }),
    // Scaleway's metadata service.
    ipv6Groups(.{ 0xfd00, 0x0042, 0, 0, 0, 0, 0, 0x0042 }),
};

fn isCloudMetadataIpv4(bytes: [4]u8) bool {
    for (cloud_metadata_ipv4) |entry| {
        if (std.mem.eql(u8, &entry, &bytes))
            return true;
    }
    return false;
}

fn isCloudMetadataIpv6(bytes: [16]u8) bool {
    for (cloud_metadata_ipv6) |entry| {
        if (std.mem.eql(u8, &entry, &bytes))
            return true;
    }
    return false;
}

/// The network-order bytes of an IPv6 address written as eight groups.
fn ipv6Groups(groups: [8]u16) [16]u8 {
    var bytes: [16]u8 = undefined;
    for (groups, 0..) |group, index| {
        std.mem.writeInt(u16, bytes[index * 2 ..][0..2], group, .big);
    }
    return bytes;
}
