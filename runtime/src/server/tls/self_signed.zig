//! The certificate the server presents when its configuration names none (`globalSettings.tls`):
//! an EC P-256 key and a certificate signed by that same key, valid for `validity_days` from the
//! moment of generation. The BoringSSL shim generates both at boot
//! (`collo_boringssl_self_signed_generate`), and neither is ever written to disk, so every start
//! presents a new key. The certificate names `localhost`, `127.0.0.1` and `::1`, plus the address
//! the server listens on unless that address is one of those or the unspecified address, which no
//! client dials. A server that runs past the validity period keeps presenting the expired
//! certificate.
//!
//! The server's boot owns a `SelfSignedCertificate` and uses it from one thread. It keeps both PEM
//! texts in fixed buffers of its own, so generating one allocates nothing. `certificateConfig`
//! lends those buffers, and `BoringSslContext.init` copies what it reads, so the certificate may be
//! released as soon as the context exists. `deinit` zeroes the private key.

const std = @import("std");
const boring = @import("collo_boringssl");
const tls = @import("root.zig");

/// How long a generated certificate stays valid.
pub const validity_days: u32 = 30;
/// Room for the certificate's PEM text. With every name it can carry, the generator's
/// certificate stays under 1 KiB of PEM.
pub const cert_pem_bytes_max: usize = 2048;
/// Room for the PEM text of the PKCS8 private key, about 240 bytes for a P-256 key.
pub const key_pem_bytes_max: usize = 512;
/// Names every generated certificate carries, in the order the warning lists them.
pub const fixed_names = [_][]const u8{ "localhost", "127.0.0.1", "::1" };

const names_max: usize = fixed_names.len + 1;
const validity_seconds: i64 = @as(i64, validity_days) * std.time.s_per_day;
/// The text of any IPv6 address with brackets and a port, the longest form
/// `std.net.Address.format` writes.
const address_text_bytes_max: usize = 64;

const loopback_ipv4 = [4]u8{ 127, 0, 0, 1 };
const loopback_ipv6 = [16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };

comptime {
    std.debug.assert(names_max <= boring.self_signed_names_max);
    std.debug.assert(cert_pem_bytes_max <= tls.max_cert_chain_pem_bytes);
    std.debug.assert(key_pem_bytes_max <= tls.max_private_key_pem_bytes);
}

pub const SelfSignedCertificate = struct {
    cert_pem_buffer: [cert_pem_bytes_max]u8,
    cert_pem_len: usize,
    key_pem_buffer: [key_pem_bytes_max]u8,
    key_pem_len: usize,
    /// Text of the listen address when the certificate names it; empty when it does not.
    listen_name_buffer: [address_text_bytes_max]u8,
    listen_name_len: usize,

    /// Generates a new key and a certificate for it into `target`, valid from `now_unix_seconds`
    /// for `validity_days`. On failure `target` holds no key material and needs no `deinit`; the
    /// shim's reason is logged.
    pub fn generate(target: *SelfSignedCertificate, listen: std.net.Address, now_unix_seconds: i64) !void {
        target.* = .{
            .cert_pem_buffer = undefined,
            .cert_pem_len = 0,
            .key_pem_buffer = undefined,
            .key_pem_len = 0,
            .listen_name_buffer = undefined,
            .listen_name_len = 0,
        };

        var names: [names_max]boring.SubjectAltName = undefined;
        names[0] = dnsName(fixed_names[0]);
        names[1] = ipName(&loopback_ipv4);
        names[2] = ipName(&loopback_ipv6);
        var name_count: usize = fixed_names.len;
        var listen_bytes: [16]u8 = undefined;
        if (listenAddressBytes(listen, &listen_bytes)) |bytes| {
            names[name_count] = ipName(bytes);
            name_count += 1;
            target.listen_name_len = addressText(listen, &target.listen_name_buffer).len;
        }

        if (boring.collo_boringssl_self_signed_generate(
            &names,
            name_count,
            now_unix_seconds,
            now_unix_seconds + validity_seconds,
            &target.cert_pem_buffer,
            target.cert_pem_buffer.len,
            &target.cert_pem_len,
            &target.key_pem_buffer,
            target.key_pem_buffer.len,
            &target.key_pem_len,
        ) != 0) {
            tls.logBoringSslLastError("self-signed certificate generation failed");
            target.deinit();
            return error.SelfSignedCertificateFailed;
        }
        std.debug.assert(target.cert_pem_len != 0);
        std.debug.assert(target.cert_pem_len <= target.cert_pem_buffer.len);
        std.debug.assert(target.key_pem_len != 0);
        std.debug.assert(target.key_pem_len <= target.key_pem_buffer.len);
    }

    /// Zeroes the private key. The certificate stays readable, but a configuration taken from
    /// `certificateConfig` must not be used afterwards.
    pub fn deinit(self: *SelfSignedCertificate) void {
        std.crypto.secureZero(u8, &self.key_pem_buffer);
        self.key_pem_len = 0;
        self.cert_pem_len = 0;
    }

    pub fn certPem(self: *const SelfSignedCertificate) []const u8 {
        return self.cert_pem_buffer[0..self.cert_pem_len];
    }

    pub fn keyPem(self: *const SelfSignedCertificate) []const u8 {
        return self.key_pem_buffer[0..self.key_pem_len];
    }

    /// The certificate as the server's TLS configuration. It borrows this certificate's buffers,
    /// so `self` must stay in place and alive until the configuration has been loaded.
    pub fn certificateConfig(self: *const SelfSignedCertificate) tls.CertificateConfig {
        std.debug.assert(self.cert_pem_len != 0);
        std.debug.assert(self.key_pem_len != 0);
        return .{
            .cert_chain = .{ .inline_pem = self.certPem() },
            .private_key = .{ .inline_pem = self.keyPem() },
        };
    }

    /// Writes the warning the server prints when it presents this certificate: that it is
    /// self-signed, which names it covers and for how long, and what a client must do to
    /// connect.
    pub fn writeWarning(self: *const SelfSignedCertificate, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(
            "collo: warning: no certificate is configured (globalSettings.tls), so the server " ++
                "presents a self-signed certificate generated at startup for ",
        );
        const listen_name = self.listen_name_buffer[0..self.listen_name_len];
        const name_count = fixed_names.len + @intFromBool(listen_name.len != 0);
        for (0..name_count) |index| {
            if (index != 0) {
                const separator = if (index + 1 == name_count) " and " else ", ";
                try writer.writeAll(separator);
            }
            const name = if (index < fixed_names.len) fixed_names[index] else listen_name;
            try writer.writeAll(name);
        }
        try writer.print(
            ", valid for {d} days. Clients must skip certificate verification (for example " ++
                "curl --insecure) or trust this certificate, which changes every time the server " ++
                "starts.\n",
            .{validity_days},
        );
    }
};

fn dnsName(name: []const u8) boring.SubjectAltName {
    return .{
        .value = name.ptr,
        .value_len = name.len,
        .kind = boring.subject_alt_name_dns,
        .reserved0 = @splat(0),
    };
}

fn ipName(bytes: []const u8) boring.SubjectAltName {
    std.debug.assert(bytes.len == 4 or bytes.len == 16);
    return .{
        .value = bytes.ptr,
        .value_len = bytes.len,
        .kind = boring.subject_alt_name_ip,
        .reserved0 = @splat(0),
    };
}

/// The bytes of `listen` in network order when the certificate should name it: not the
/// unspecified address, which a client never dials, and not a loopback address the fixed names
/// already cover.
fn listenAddressBytes(listen: std.net.Address, out: *[16]u8) ?[]const u8 {
    const bytes: []const u8 = switch (listen.any.family) {
        std.posix.AF.INET => blk: {
            const ipv4: [4]u8 = @bitCast(listen.in.sa.addr);
            @memcpy(out[0..4], &ipv4);
            break :blk out[0..4];
        },
        std.posix.AF.INET6 => blk: {
            @memcpy(out[0..16], &listen.in6.sa.addr);
            break :blk out[0..16];
        },
        else => return null,
    };
    if (std.mem.allEqual(u8, bytes, 0))
        return null;
    if (std.mem.eql(u8, bytes, &loopback_ipv4))
        return null;
    if (std.mem.eql(u8, bytes, &loopback_ipv6))
        return null;
    return bytes;
}

/// The address part of `listen` as text, without brackets or port.
fn addressText(listen: std.net.Address, out: *[address_text_bytes_max]u8) []const u8 {
    const formatted = std.fmt.bufPrint(out, "{f}", .{listen}) catch unreachable;
    if (formatted.len != 0 and formatted[0] == '[') {
        const close = std.mem.lastIndexOfScalar(u8, formatted, ']') orelse unreachable;
        std.mem.copyForwards(u8, out[0 .. close - 1], formatted[1..close]);
        return out[0 .. close - 1];
    }
    const colon = std.mem.lastIndexOfScalar(u8, formatted, ':') orelse unreachable;
    return formatted[0..colon];
}
