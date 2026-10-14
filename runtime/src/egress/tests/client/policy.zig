//! Tests of the gateway's outbound transport rules: how `parseTarget` reads
//! a hop's URL once, through the host grammar allow entries are written in,
//! and decides it under a network policy; that every host the transport ever
//! refused as unreadable is still refused; the check of every DNS answer
//! against the hop's admission; body and window limits; and the stall and
//! request deadlines. The address classes and the grant matching beneath
//! `parseTarget` are tested in `common/tests/network/`, the DNS cache in
//! `dns_cache.zig`.

const std = @import("std");
const gateway_egress = @import("collo_egress_client");
const network_policy = @import("network_policy.zig");
const egress_transport = gateway_egress.transport;
const network = gateway_egress.network;

/// `api.example.com` and `[2606:4700::1111]`, over HTTPS on port 443.
const listed_grant: network.Grant = .{
    .allow_http = false,
    .allow_private_networks = false,
    .any = false,
    .names = &.{.{ .host = .{ .name = "api.example.com" }, .port = 0 }},
    .suffixes = &.{},
    .ipv4 = &.{},
    .ipv6 = &.{.{ .host = .{ .ipv6 = ipv6Bytes(.{ 0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111 }) }, .port = 0 }},
};
const listed_policy: network.Policy = .{ .grants = &.{&listed_grant} };

/// A setting with allowPrivateNetworks that lists `db.internal` and
/// `10.0.0.5`.
const internal_grant: network.Grant = .{
    .allow_http = false,
    .allow_private_networks = true,
    .any = false,
    .names = &.{.{ .host = .{ .name = "db.internal" }, .port = 0 }},
    .suffixes = &.{},
    .ipv4 = &.{.{ .host = .{ .ipv4 = .{ 10, 0, 0, 5 } }, .port = 0 }},
    .ipv6 = &.{},
};

/// `10.0.0.6` in a setting without allowPrivateNetworks. The configuration
/// parser refuses such a setting, so the transport's own refusal is what
/// this grant tests.
const unflagged_private_grant: network.Grant = .{
    .allow_http = false,
    .allow_private_networks = false,
    .any = false,
    .names = &.{},
    .suffixes = &.{},
    .ipv4 = &.{.{ .host = .{ .ipv4 = .{ 10, 0, 0, 6 } }, .port = 0 }},
    .ipv6 = &.{},
};
const private_policy: network.Policy = .{ .grants = &.{ &internal_grant, &unflagged_private_grant } };

/// `*` beside a setting that allows private networks for its own entries.
const public_and_internal_policy: network.Policy = .{
    .grants = &.{ network.public_https.grants[0], &internal_grant },
};

/// Two metadata addresses named by a setting with allowHttp and
/// allowPrivateNetworks. The configuration parser refuses both entries, so
/// the transport's own refusal is what this grant tests.
const metadata_named_grant: network.Grant = .{
    .allow_http = true,
    .allow_private_networks = true,
    .any = false,
    .names = &.{},
    .suffixes = &.{},
    .ipv4 = &.{.{ .host = .{ .ipv4 = .{ 169, 254, 169, 254 } }, .port = 0 }},
    .ipv6 = &.{.{ .host = .{ .ipv6 = ipv6Bytes(.{ 0xfd00, 0x0ec2, 0, 0, 0, 0, 0, 0x0254 }) }, .port = 0 }},
};
const metadata_named_policy: network.Policy = .{ .grants = &.{&metadata_named_grant} };

/// `[2606:2800:220:1:248:1893:25c8:1946]:8443` over HTTPS.
const ipv6_8443_grant: network.Grant = .{
    .allow_http = false,
    .allow_private_networks = false,
    .any = false,
    .names = &.{},
    .suffixes = &.{},
    .ipv4 = &.{},
    .ipv6 = &.{.{
        .host = .{ .ipv6 = ipv6Bytes(.{ 0x2606, 0x2800, 0x220, 0x1, 0x248, 0x1893, 0x25c8, 0x1946 }) },
        .port = 8443,
    }},
};
const ipv6_8443_policy: network.Policy = .{ .grants = &.{&ipv6_8443_grant} };

/// The network-order bytes of an IPv6 address written as eight groups.
fn ipv6Bytes(groups: [8]u16) [16]u8 {
    var bytes: [16]u8 = undefined;
    for (groups, 0..) |group, index|
        std.mem.writeInt(u16, bytes[index * 2 ..][0..2], group, .big);
    return bytes;
}

test "egress stall deadline is an idle timeout: resets on progress, bounded by the total" {
    const ms = std.time.ns_per_ms;

    // The socket timeout is a stall clock: with no request deadline, the
    // deadline is exactly `socket_timeout_ms` from now.
    const idle_only = egress_transport.Config{ .network = network.public_https, .socket_timeout_ms = 5_000 };
    try std.testing.expectEqual(@as(u64, 1_000_000 + 5_000 * ms), idle_only.stallDeadlineFromNow(1_000_000));

    // A later refresh, as when a chunk arrives, pushes the deadline forward
    // by exactly the elapsed time, so a long transfer that keeps progressing
    // never times out.
    const first = idle_only.stallDeadlineFromNow(1_000_000);
    const later = idle_only.stallDeadlineFromNow(1_000_000 + 4_000 * ms);
    try std.testing.expectEqual(first + 4_000 * ms, later);

    // The request deadline caps every refresh, so the stall clock never
    // pushes the fetch past its total bound.
    const capped = egress_transport.Config{
        .network = network.public_https,
        .socket_timeout_ms = 5_000,
        .request_deadline_mono_ns = 1_000_000 + 2_000 * ms,
    };
    try std.testing.expectEqual(
        @as(u64, 1_000_000 + 2_000 * ms),
        capped.stallDeadlineFromNow(1_000_000),
    );
    // Even refreshing right up against the total never exceeds it.
    try std.testing.expectEqual(
        @as(u64, 1_000_000 + 2_000 * ms),
        capped.stallDeadlineFromNow(1_000_000 + 1_900 * ms),
    );
}

test "egress target reads http and https only, and plain HTTP needs a grant with allowHttp" {
    _ = try egress_transport.parseTarget(network.public_https, "https://example.com/");
    try std.testing.expectError(
        error.EgressSchemeDenied,
        egress_transport.parseTarget(network.public_https, "http://example.com/"),
    );
    _ = try egress_transport.parseTarget(network_policy.public_http_and_https, "http://example.com/");
    try std.testing.expectError(
        error.UnsupportedFetchProtocol,
        egress_transport.parseTarget(network_policy.public_http_and_https, "file:///tmp/x"),
    );
}

test "egress target admits a listed name in any letter case and with a trailing dot" {
    const urls = [_][]const u8{
        "https://api.example.com/v1",
        "https://API.Example.COM/v1",
        "https://api.example.com./v1",
        "https://Api.Example.Com.:443/v1",
    };
    for (urls) |url| {
        const target = try egress_transport.parseTarget(listed_policy, url);
        try std.testing.expectEqual(@as(u16, 443), target.port);
        try std.testing.expect(!target.admission.allow_private_networks);
    }
}

test "egress target refuses a name the policy does not list with EgressHostDenied" {
    const urls = [_][]const u8{
        "https://evil.example.com/",
        "https://api.example.com.evil.net/",
    };
    for (urls) |url|
        try std.testing.expectError(error.EgressHostDenied, egress_transport.parseTarget(listed_policy, url));
}

test "egress target refuses a listed name on a port its entry does not name with EgressPortDenied" {
    try std.testing.expectError(
        error.EgressPortDenied,
        egress_transport.parseTarget(listed_policy, "https://api.example.com:8443/"),
    );
}

test "egress target refuses plain HTTP to a listed name with EgressSchemeDenied when its grant lacks allowHttp" {
    try std.testing.expectError(
        error.EgressSchemeDenied,
        egress_transport.parseTarget(listed_policy, "http://api.example.com/"),
    );
}

test "egress target admits an IPv6 address only when listed, in any spelling" {
    _ = try egress_transport.parseTarget(listed_policy, "https://[2606:4700::1111]/");
    _ = try egress_transport.parseTarget(listed_policy, "https://[2606:4700:0:0:0:0:0:1111]/");
    try std.testing.expectError(
        error.EgressHostDenied,
        egress_transport.parseTarget(listed_policy, "https://[2606:4700::1112]/"),
    );
}

test "egress target admits a private address literal only through an entry whose setting allows private networks" {
    const flagged = try egress_transport.parseTarget(private_policy, "https://10.0.0.5/");
    try std.testing.expect(flagged.admission.allow_private_networks);
    try std.testing.expectError(
        error.EgressPrivateAddressDenied,
        egress_transport.parseTarget(private_policy, "https://10.0.0.6/"),
    );
    try std.testing.expectError(
        error.EgressHostDenied,
        egress_transport.parseTarget(private_policy, "https://10.0.0.7/"),
    );
}

test "egress answer check refuses a private answer for a name * admits, even beside a grant that allows private networks" {
    const private_answer = [_]std.net.Address{try std.net.Address.parseIp4("10.0.0.1", 443)};

    const public_only = try egress_transport.parseTarget(network.public_https, "https://api.example.com/");
    try std.testing.expect(!public_only.admission.allow_private_networks);
    try std.testing.expectError(
        error.EgressPrivateAddressDenied,
        egress_transport.admitResolvedAddresses(public_only.admission, &private_answer),
    );

    const beside = try egress_transport.parseTarget(public_and_internal_policy, "https://api.example.com/");
    try std.testing.expect(!beside.admission.allow_private_networks);
    try std.testing.expectError(
        error.EgressPrivateAddressDenied,
        egress_transport.admitResolvedAddresses(beside.admission, &private_answer),
    );

    // The flag follows the entry that names the host.
    const internal = try egress_transport.parseTarget(public_and_internal_policy, "https://db.internal/");
    try std.testing.expect(internal.admission.allow_private_networks);
    try egress_transport.admitResolvedAddresses(internal.admission, &private_answer);
}

test "egress answer check refuses an answer mixing a public and a loopback address whole with EgressReservedAddressDenied" {
    const target = try egress_transport.parseTarget(network.public_https, "https://api.example.com/");
    const answers = [_]std.net.Address{
        try std.net.Address.parseIp4("93.184.216.34", 443),
        try std.net.Address.parseIp4("127.0.0.1", 443),
    };
    try std.testing.expectError(
        error.EgressReservedAddressDenied,
        egress_transport.admitResolvedAddresses(target.admission, &answers),
    );
    try std.testing.expectError(
        error.EgressReservedAddressDenied,
        egress_transport.admitResolvedAddresses(.{ .allow_private_networks = true }, &answers),
    );
}

test "egress answer check passes an answer once every address passes and refuses an empty one" {
    const target = try egress_transport.parseTarget(network.public_https, "https://api.example.com/");
    const answers = [_]std.net.Address{
        try std.net.Address.parseIp4("93.184.216.34", 443),
        try std.net.Address.parseIp6("2606:2800:220:1:248:1893:25c8:1946", 443),
    };
    try egress_transport.admitResolvedAddresses(target.admission, &answers);
    try std.testing.expectError(
        error.HostLacksNetworkAddresses,
        egress_transport.admitResolvedAddresses(target.admission, &.{}),
    );
}

test "egress target and answer check refuse metadata addresses under every policy and admission" {
    const policies = [_]network.Policy{
        network.public_https,
        network_policy.public_http_and_https,
        private_policy,
        metadata_named_policy,
    };
    const urls = [_][]const u8{
        "https://169.254.169.254/",
        "http://169.254.169.254/latest/meta-data/",
        "https://[fd00:ec2::254]/",
        "http://[fd00:ec2::254]/",
    };
    for (policies) |hop_policy| {
        for (urls) |url|
            try std.testing.expectError(error.EgressReservedAddressDenied, egress_transport.parseTarget(hop_policy, url));
    }

    const answers = [_]std.net.Address{
        try std.net.Address.parseIp4("169.254.169.254", 80),
        try std.net.Address.parseIp6("fd00:ec2::254", 80),
    };
    for ([_]bool{ false, true }) |allow_private_networks| {
        for (answers) |answer| {
            const single = [_]std.net.Address{answer};
            try std.testing.expectError(
                error.EgressReservedAddressDenied,
                egress_transport.admitResolvedAddresses(.{ .allow_private_networks = allow_private_networks }, &single),
            );
        }
    }
}

test "egress target refuses every hop under a policy without grants with EgressNotGranted, before any other check" {
    const urls = [_][]const u8{
        "https://api.example.com/",
        "https://93.184.216.34/",
        "https://localhost/",
        "https://169.254.169.254/",
    };
    for (urls) |url|
        try std.testing.expectError(error.EgressNotGranted, egress_transport.parseTarget(network.deny_all, url));
}

test "egress target refuses localhost in any spelling with EgressReservedAddressDenied" {
    const policies = [_]network.Policy{ network.public_https, listed_policy, private_policy };
    const urls = [_][]const u8{
        "https://localhost/",
        "https://LOCALHOST./",
        "https://demo.localhost./",
        "https://user:pass@localhost./",
    };
    for (policies) |hop_policy| {
        for (urls) |url|
            try std.testing.expectError(error.EgressReservedAddressDenied, egress_transport.parseTarget(hop_policy, url));
    }
}

test "egress target refuses as an invalid URL every host the transport ever refused before the policy" {
    // Each host reaches `parseTarget` intact: std.Uri ends an authority only
    // at `/`, `?` or `#` and splits userinfo at the first `@`, so a host can
    // hold every other byte. Every one of them fails the host grammar
    // (`pattern.parseHost`): a byte outside letters, digits, `-`, `_` and
    // `.`, an empty label, a number other than a strict dotted quad, or a
    // zoned or malformed IPv6 literal.
    const urls = [_][]const u8{
        "https://a b.example/",
        "https://a\x01b.example/",
        "https://a\x7fb.example/",
        "https://ex\xc3\xa4mple.com/",
        "https://%6cocalhost/",
        "https://a\\b.example/",
        "https://user@a@b.example/",
        "https:///path",
        "https://./",
        "https://127.1/",
        "https://010.0.0.1/",
        "https://0177.0.0.1/",
        "https://2130706433/",
        "https://1.2.3.4.5/",
        "https://256.1.1.1/",
        "https://0x7f.1/",
        "https://[fe80::1%25eth0]/",
        "https://[example.com]/",
    };
    for (urls) |url|
        try std.testing.expectError(error.InvalidFetchUrl, egress_transport.parseTarget(network.public_https, url));
}

test "a host the grammar cannot read is an invalid URL, never a policy denial" {
    // These hosts pass every byte check a looser reader would make, so they
    // reach the grammar, which alone refuses them; the tenant learns its URL
    // is wrong rather than that its network setting refused it.
    const urls = [_][]const u8{
        "https://a..b.example/",
        "https://example.com../",
        "https://-lead.example/",
        "https://trail-.example/",
        "https://foo.0xff/",
        "https://" ++ "a" ** 64 ++ ".example/",
    };
    for (urls) |url|
        try std.testing.expectError(error.InvalidFetchUrl, egress_transport.parseTarget(network.public_https, url));
}

test "egress target names DNS and TLS by the URL's host without brackets or one trailing dot" {
    const dotted = try egress_transport.parseTarget(network.public_https, "https://Example.COM./data");
    try std.testing.expectEqualStrings("Example.COM.", dotted.authority_host);
    try std.testing.expectEqualStrings("Example.COM", dotted.tls_server_name);

    const numeric = try egress_transport.parseTarget(network.public_https, "https://93.184.216.34/");
    try std.testing.expectEqualStrings("93.184.216.34", numeric.authority_host);
    try std.testing.expectEqualStrings("93.184.216.34", numeric.tls_server_name);
    try std.testing.expectEqual(@as(u16, 443), numeric.port);

    const bracketed = try egress_transport.parseTarget(
        ipv6_8443_policy,
        "https://[2606:2800:220:1:248:1893:25c8:1946]:8443/",
    );
    try std.testing.expectEqualStrings("[2606:2800:220:1:248:1893:25c8:1946]", bracketed.authority_host);
    try std.testing.expectEqualStrings("2606:2800:220:1:248:1893:25c8:1946", bracketed.tls_server_name);
    try std.testing.expectEqual(@as(u16, 8443), bracketed.port);
}

test "ipv4 policy reads network-order address bytes" {
    const address = try std.net.Address.parseIp4("1.2.3.4", 443);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 1, 2, 3, 4 }, &egress_transport.ipv4Bytes(address));
}

test "binary fetch headers clone to http1 headers" {
    const input = [_]egress_transport.Header{
        .{ .name = "x-collo-test", .value = "yes" },
        .{ .name = "accept", .value = "application/json" },
    };
    var parsed = try egress_transport.parseFetchHeaders(std.testing.allocator, &input);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.headers.items.len);
    try std.testing.expectEqualStrings("x-collo-test", parsed.headers.items[0].name);
    try std.testing.expectEqualStrings("yes", parsed.headers.items[0].value);
}

test "stream pump limits keep the decoded queue watermark separate from the body cap" {
    const config = egress_transport.Config{
        .network = network.public_https,
        .max_response_body_bytes = 4 * 1024 * 1024,
        .max_encoded_response_bytes = 512 * 1024,
        .max_pending_decoded_body_bytes = 256 * 1024,
    };

    const limits = try config.streamPumpLimits().normalized();
    try std.testing.expectEqual(@as(usize, 4 * 1024 * 1024), limits.max_decoded_bytes);
    try std.testing.expectEqual(@as(usize, 256 * 1024), limits.max_pending_decoded_bytes);
    try std.testing.expectEqual(@as(usize, 512 * 1024), limits.max_encoded_bytes);
}

test "http2 advertised receive window respects encoded budget" {
    const config = egress_transport.Config{
        .network = network.public_https,
        .max_response_body_bytes = 4 * 1024 * 1024,
        .max_encoded_response_bytes = 32 * 1024,
        .max_pending_decoded_body_bytes = 256 * 1024,
        .http2_stream_receive_window = 1024 * 1024,
    };
    const limits = try config.http2Limits().normalized();
    try std.testing.expectEqual(@as(u32, 32 * 1024), limits.stream_receive_window);
}
