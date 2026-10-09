//! Tests of the generated certificate (`server/tls/self_signed.zig`): its names, validity period,
//! key type and signature read back with the standard library's X.509 parser, the leaf extensions
//! read from its DER, a fresh key and serial on every generation, a handshake between the server
//! context and the egress client over a socket pair, the warning text, and the private key zeroed
//! on release. Lane `server-core-test`.

const std = @import("std");
const server_main = @import("collo_server_main");
const tls = server_main.tls;
const boring = tls.boringssl;
const self_signed = tls.self_signed;
const SelfSignedCertificate = self_signed.SelfSignedCertificate;
const Certificate = std.crypto.Certificate;
const der = Certificate.der;

/// A fixed instant in January 2027, so the validity checks need no wall clock.
const now_unix_seconds: i64 = 1_800_000_000;
const validity_seconds: u64 = @as(u64, self_signed.validity_days) * std.time.s_per_day;
/// Rounds of a handshake driven by alternating steps; a TLS 1.3 handshake takes three.
const handshake_rounds_max: usize = 16;

test "a generated certificate names the fixed names and the listen address for thirty days" {
    var certificate: SelfSignedCertificate = undefined;
    try certificate.generate(try std.net.Address.parseIp("192.0.2.10", 8443), now_unix_seconds);
    defer certificate.deinit();

    var der_buffer: [self_signed.cert_pem_bytes_max]u8 = undefined;
    const parsed = try (Certificate{ .buffer = try certificateDer(certificate.certPem(), &der_buffer), .index = 0 }).parse();

    try std.testing.expectEqual(@as(u64, @intCast(now_unix_seconds)), parsed.validity.not_before);
    try std.testing.expectEqual(@as(u64, @intCast(now_unix_seconds)) + validity_seconds, parsed.validity.not_after);
    try std.testing.expectEqual(Certificate.Version.v3, parsed.version);
    try std.testing.expectEqual(Certificate.Algorithm.ecdsa_with_SHA256, parsed.signature_algorithm);
    switch (parsed.pub_key_algo) {
        .X9_62_id_ecPublicKey => |curve| try std.testing.expectEqual(Certificate.NamedCurve.X9_62_prime256v1, curve),
        else => return error.UnexpectedPublicKeyAlgorithm,
    }
    // Signed by its own key, and valid at the instant it was generated.
    try parsed.verify(parsed, now_unix_seconds);
    try std.testing.expectError(
        error.CertificateExpired,
        parsed.verify(parsed, now_unix_seconds + @as(i64, @intCast(validity_seconds)) + 1),
    );
    try parsed.verifyHostName("localhost");

    const names = try subjectAltNames(parsed);
    try std.testing.expectEqual(@as(usize, 1), names.dns_count);
    try std.testing.expectEqualStrings("localhost", names.dns[0]);
    try std.testing.expectEqual(@as(usize, 3), names.ip_count);
    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, names.ip[0]);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 15 ++ [_]u8{1}), names.ip[1]);
    try std.testing.expectEqualSlices(u8, &.{ 192, 0, 2, 10 }, names.ip[2]);
}

test "a generated certificate is a server leaf that cannot act as a CA" {
    var certificate: SelfSignedCertificate = undefined;
    try certificate.generate(try std.net.Address.parseIp("127.0.0.1", 8443), now_unix_seconds);
    defer certificate.deinit();

    var der_buffer: [self_signed.cert_pem_bytes_max]u8 = undefined;
    const certificate_der = try certificateDer(certificate.certPem(), &der_buffer);
    var extensions: [extensions_max]Extension = undefined;
    const found = try readExtensions(certificate_der, &extensions);

    // Exactly the subject alternative names and the three leaf extensions, in this order.
    try std.testing.expectEqual(@as(usize, 4), found.len);
    try std.testing.expectEqualSlices(u8, &oid_subject_alt_name, found[0].id);
    try std.testing.expect(!found[0].critical);
    // basicConstraints, critical, with cA left at its default FALSE: an empty SEQUENCE.
    try std.testing.expectEqualSlices(u8, &oid_basic_constraints, found[1].id);
    try std.testing.expect(found[1].critical);
    try std.testing.expectEqualSlices(u8, &.{ 0x30, 0x00 }, found[1].value);
    // keyUsage, critical: a one-byte BIT STRING whose seven unused bits leave digitalSignature,
    // bit 0, as the only usage.
    try std.testing.expectEqualSlices(u8, &oid_key_usage, found[2].id);
    try std.testing.expect(found[2].critical);
    try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x02, 0x07, 0x80 }, found[2].value);
    // extKeyUsage: a SEQUENCE holding serverAuth (1.3.6.1.5.5.7.3.1) alone.
    try std.testing.expectEqualSlices(u8, &oid_ext_key_usage, found[3].id);
    try std.testing.expect(!found[3].critical);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x30, 0x0a, 0x06, 0x08, 0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01 },
        found[3].value,
    );
}

test "a listen address the fixed names cover, or the unspecified address, adds no name" {
    const covered = [_][]const u8{ "127.0.0.1", "::1", "0.0.0.0", "::" };
    for (covered) |text| {
        var certificate: SelfSignedCertificate = undefined;
        try certificate.generate(try std.net.Address.parseIp(text, 8443), now_unix_seconds);
        defer certificate.deinit();

        try std.testing.expectEqual(@as(usize, 0), certificate.listen_name_len);
        var der_buffer: [self_signed.cert_pem_bytes_max]u8 = undefined;
        const parsed = try (Certificate{ .buffer = try certificateDer(certificate.certPem(), &der_buffer), .index = 0 }).parse();
        const names = try subjectAltNames(parsed);
        try std.testing.expectEqual(@as(usize, 1), names.dns_count);
        try std.testing.expectEqual(@as(usize, 2), names.ip_count);
    }
}

test "every generation draws a new key and a positive full-length random serial" {
    var first: SelfSignedCertificate = undefined;
    try first.generate(try std.net.Address.parseIp("127.0.0.1", 8443), now_unix_seconds);
    defer first.deinit();
    var second: SelfSignedCertificate = undefined;
    try second.generate(try std.net.Address.parseIp("127.0.0.1", 8443), now_unix_seconds);
    defer second.deinit();

    try std.testing.expect(!std.mem.eql(u8, first.keyPem(), second.keyPem()));
    var first_der: [self_signed.cert_pem_bytes_max]u8 = undefined;
    var second_der: [self_signed.cert_pem_bytes_max]u8 = undefined;
    const first_serial = try serialNumber(try certificateDer(first.certPem(), &first_der));
    const second_serial = try serialNumber(try certificateDer(second.certPem(), &second_der));
    try std.testing.expect(!std.mem.eql(u8, first_serial, second_serial));
    for ([_][]const u8{ first_serial, second_serial }) |serial| {
        try std.testing.expectEqual(@as(usize, 16), serial.len);
        try std.testing.expectEqual(@as(u8, 0x40), serial[0] & 0xc0);
    }
}

test "the server context loads a generated certificate and completes a handshake over a socket pair" {
    var certificate: SelfSignedCertificate = undefined;
    try certificate.generate(try std.net.Address.parseIp("127.0.0.1", 8443), now_unix_seconds);
    defer certificate.deinit();

    var context = try tls.BoringSslContext.init(std.testing.allocator, certificate.certificateConfig());
    defer context.deinit();

    var fds: [2]std.c.fd_t = undefined;
    const rc = std.c.socketpair(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
        0,
        &fds,
    );
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => |err| return std.posix.unexpectedErrno(err),
    }
    defer std.posix.close(fds[0]);
    defer std.posix.close(fds[1]);

    var server = try context.start(fds[0]);
    defer server.deinit();

    // The egress client skips verification here, as a client of this certificate must, and offers
    // only h2, which the server requires.
    var client_context: ?*boring.ClientContextHandle = null;
    try std.testing.expectEqual(@as(c_int, 0), boring.collo_boringssl_client_ctx_new(1, &client_context));
    defer boring.collo_boringssl_client_ctx_free(client_context.?);
    var client: ?*boring.ClientHandle = null;
    try std.testing.expectEqual(@as(c_int, 0), boring.collo_boringssl_client_conn_new(
        client_context.?,
        fds[1],
        "localhost",
        boring.alpn_offer_h2_only,
        null,
        0,
        &client,
    ));
    defer boring.collo_boringssl_client_conn_free(client.?);

    var server_done = false;
    var client_protocol: ?u8 = null;
    var round: usize = 0;
    while (round < handshake_rounds_max) : (round += 1) {
        if (client_protocol == null) {
            var raw = std.mem.zeroes(boring.RawResult);
            try std.testing.expectEqual(@as(c_int, 0), boring.collo_boringssl_client_handshake_step(client.?, &raw));
            switch (raw.status) {
                boring.status_ok => client_protocol = raw.application_protocol,
                boring.status_want_read, boring.status_want_write => {},
                else => {
                    std.debug.print("client handshake failed: {s}\n", .{boring.lastErrorSlice()});
                    return error.ClientHandshakeFailed;
                },
            }
        }
        if (!server_done) {
            switch (try server.step()) {
                .done => server_done = true,
                .want_read, .want_write => {},
            }
        }
        if (server_done and client_protocol != null)
            break;
    }
    try std.testing.expect(server_done);
    try std.testing.expectEqual(@as(?u8, boring.alpn_h2), client_protocol);
}

test "the warning says the certificate is self-signed and lists what it covers" {
    const cases = [_]struct { listen: []const u8, names: []const u8 }{
        .{ .listen = "127.0.0.1", .names = "for localhost, 127.0.0.1 and ::1, valid for 30 days." },
        .{ .listen = "192.0.2.10", .names = "for localhost, 127.0.0.1, ::1 and 192.0.2.10, valid for 30 days." },
        .{ .listen = "2001:db8::1", .names = "for localhost, 127.0.0.1, ::1 and 2001:db8::1, valid for 30 days." },
    };
    for (cases) |case| {
        var certificate: SelfSignedCertificate = undefined;
        try certificate.generate(try std.net.Address.parseIp(case.listen, 8443), now_unix_seconds);
        defer certificate.deinit();

        var buffer: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try certificate.writeWarning(&writer);
        const warning = writer.buffered();
        try std.testing.expect(std.mem.indexOf(u8, warning, "self-signed certificate") != null);
        try std.testing.expect(std.mem.indexOf(u8, warning, case.names) != null);
        try std.testing.expect(std.mem.indexOf(u8, warning, "skip certificate verification") != null);
        try std.testing.expect(std.mem.indexOf(u8, warning, "trust this certificate") != null);
        try std.testing.expect(std.mem.endsWith(u8, warning, "\n"));
    }
}

test "releasing a generated certificate zeroes its private key" {
    var certificate: SelfSignedCertificate = undefined;
    try certificate.generate(try std.net.Address.parseIp("127.0.0.1", 8443), now_unix_seconds);
    try std.testing.expect(std.mem.startsWith(u8, certificate.keyPem(), "-----BEGIN PRIVATE KEY-----"));

    certificate.deinit();

    try std.testing.expectEqual(@as(usize, 0), certificate.key_pem_len);
    try std.testing.expect(std.mem.allEqual(u8, &certificate.key_pem_buffer, 0));
}

/// Decodes the DER of the first certificate in `pem` into `out`.
fn certificateDer(pem: []const u8, out: []u8) ![]const u8 {
    const begin = "-----BEGIN CERTIFICATE-----";
    const end = "-----END CERTIFICATE-----";
    const body_start = (std.mem.indexOf(u8, pem, begin) orelse return error.MissingPemHeader) + begin.len;
    const body_end = std.mem.indexOfPos(u8, pem, body_start, end) orelse return error.MissingPemFooter;
    var base64_buffer: [self_signed.cert_pem_bytes_max]u8 = undefined;
    var base64_len: usize = 0;
    for (pem[body_start..body_end]) |byte| {
        if (byte == '\n' or byte == '\r')
            continue;
        base64_buffer[base64_len] = byte;
        base64_len += 1;
    }
    const decoder = std.base64.standard.Decoder;
    const der_len = try decoder.calcSizeForSlice(base64_buffer[0..base64_len]);
    if (der_len > out.len)
        return error.NoSpaceLeft;
    try decoder.decode(out[0..der_len], base64_buffer[0..base64_len]);
    return out[0..der_len];
}

/// The content bytes of the serial number: the element after the explicit version of a v3
/// certificate's to-be-signed part.
fn serialNumber(certificate_der: []const u8) ![]const u8 {
    const certificate = try der.Element.parse(certificate_der, 0);
    const to_be_signed = try der.Element.parse(certificate_der, certificate.slice.start);
    const version = try der.Element.parse(certificate_der, to_be_signed.slice.start);
    const serial = try der.Element.parse(certificate_der, version.slice.end);
    try std.testing.expectEqual(der.Tag.integer, serial.identifier.tag);
    return certificate_der[serial.slice.start..serial.slice.end];
}

/// The DER contents of the extension identifiers, under 2.5.29.
const oid_subject_alt_name = [_]u8{ 0x55, 0x1d, 0x11 };
const oid_basic_constraints = [_]u8{ 0x55, 0x1d, 0x13 };
const oid_key_usage = [_]u8{ 0x55, 0x1d, 0x0f };
const oid_ext_key_usage = [_]u8{ 0x55, 0x1d, 0x25 };
/// More than a generated certificate carries, so an extra extension shows up in the count.
const extensions_max: usize = 8;

const Extension = struct {
    id: []const u8,
    critical: bool,
    /// The DER inside the extension's OCTET STRING.
    value: []const u8,
};

/// The extensions of a v3 certificate, in order: the `[3]` element that closes its to-be-signed
/// part holds a SEQUENCE of `{ extnID, critical BOOLEAN DEFAULT FALSE, extnValue OCTET STRING }`.
fn readExtensions(certificate_der: []const u8, out: []Extension) ![]Extension {
    const certificate = try der.Element.parse(certificate_der, 0);
    const to_be_signed = try der.Element.parse(certificate_der, certificate.slice.start);
    var index = to_be_signed.slice.start;
    var explicit: ?der.Element = null;
    while (index < to_be_signed.slice.end) {
        const element = try der.Element.parse(certificate_der, index);
        index = element.slice.end;
        if (element.identifier.class == .context_specific and @intFromEnum(element.identifier.tag) == 3)
            explicit = element;
    }
    const extensions_wrapper = explicit orelse return error.MissingExtensions;
    const extensions = try der.Element.parse(certificate_der, extensions_wrapper.slice.start);
    try std.testing.expectEqual(der.Tag.sequence, extensions.identifier.tag);

    var count: usize = 0;
    index = extensions.slice.start;
    while (index < extensions.slice.end) {
        if (count == out.len)
            return error.TooManyExtensions;
        const extension = try der.Element.parse(certificate_der, index);
        index = extension.slice.end;
        const id = try der.Element.parse(certificate_der, extension.slice.start);
        try std.testing.expectEqual(der.Tag.object_identifier, id.identifier.tag);
        var next = try der.Element.parse(certificate_der, id.slice.end);
        var critical = false;
        if (next.identifier.tag == .boolean) {
            try std.testing.expectEqual(@as(u32, 1), next.slice.end - next.slice.start);
            critical = certificate_der[next.slice.start] == 0xff;
            next = try der.Element.parse(certificate_der, next.slice.end);
        }
        try std.testing.expectEqual(der.Tag.octetstring, next.identifier.tag);
        try std.testing.expectEqual(extension.slice.end, next.slice.end);
        out[count] = .{
            .id = certificate_der[id.slice.start..id.slice.end],
            .critical = critical,
            .value = certificate_der[next.slice.start..next.slice.end],
        };
        count += 1;
    }
    return out[0..count];
}

const SubjectAltNames = struct {
    dns: [4][]const u8 = undefined,
    dns_count: usize = 0,
    ip: [4][]const u8 = undefined,
    ip_count: usize = 0,
};

fn subjectAltNames(parsed: Certificate.Parsed) !SubjectAltNames {
    var names: SubjectAltNames = .{};
    const extension = parsed.subjectAltName();
    const general_names = try der.Element.parse(extension, 0);
    var index = general_names.slice.start;
    while (index < general_names.slice.end) {
        const general_name = try der.Element.parse(extension, index);
        index = general_name.slice.end;
        const value = extension[general_name.slice.start..general_name.slice.end];
        switch (@as(Certificate.GeneralNameTag, @enumFromInt(@intFromEnum(general_name.identifier.tag)))) {
            .dNSName => {
                if (names.dns_count == names.dns.len)
                    return error.TooManySubjectAltNames;
                names.dns[names.dns_count] = value;
                names.dns_count += 1;
            },
            .iPAddress => {
                if (names.ip_count == names.ip.len)
                    return error.TooManySubjectAltNames;
                names.ip[names.ip_count] = value;
                names.ip_count += 1;
            },
            else => return error.UnexpectedSubjectAltName,
        }
    }
    return names;
}
