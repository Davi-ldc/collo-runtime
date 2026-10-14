//! BoringSSL client connections for outbound fetches. Certificate
//! verification, ALPN and session resumption live in the BoringSSL shim.
//!
//! A `BioConnection` only transforms bytes between plaintext and ciphertext;
//! every socket operation belongs to the wire that holds it
//! (`transport/wire.zig`). All connections share one process-wide pair of
//! client contexts, verified and insecure. A step that needs more socket I/O
//! reports the interest to wait for.

const std = @import("std");
const boring = @import("collo_boringssl");

pub const ApplicationProtocol = enum {
    http_1_1,
    h2,
};

pub const IoInterest = enum {
    read,
    write,
};

pub const HandshakeStep = union(enum) {
    done: ApplicationProtocol,
    wait: IoInterest,
};

pub const IoStep = union(enum) {
    ready: usize,
    wait: IoInterest,
    eof,
};

pub const CiphertextStep = union(enum) {
    ready: usize,
    wait,
    eof,
};

/// The protocols a dial offers in ALPN: both by default, http/1.1 alone for
/// a fetch that must not speak HTTP/2.
pub const AlpnOffer = enum(c_int) {
    http_1_1 = boring.alpn_offer_http_1_1,
    h2_http_1_1 = boring.alpn_offer_h2_http_1_1,
};

const ContextStore = struct {
    mutex: std.Thread.Mutex = .{},
    verified: ?*boring.ClientContextHandle = null,
    insecure: ?*boring.ClientContextHandle = null,

    fn get(self: *ContextStore, insecure_skip_verify: bool) !*boring.ClientContextHandle {
        self.mutex.lock();
        defer self.mutex.unlock();

        const selected = if (insecure_skip_verify) &self.insecure else &self.verified;
        if (selected.*) |handle|
            return handle;

        var handle: ?*boring.ClientContextHandle = null;
        if (boring.collo_boringssl_client_ctx_new(@intFromBool(insecure_skip_verify), &handle) != 0)
            return error.TlsContextInitializationFailed;
        selected.* = handle orelse return error.TlsContextInitializationFailed;
        return selected.*.?;
    }
};

var contexts = ContextStore{};

/// Creates the verified context, which loads the trusted root store from the
/// filesystem. The gateway calls this at boot, before its seccomp filter, so
/// no verified fetch reads the filesystem from inside the sandbox and the
/// first one does not pay for the load.
pub fn preloadVerifiedContext() !void {
    _ = try contexts.get(false);
}

/// Session-resumption cache key: security cell, policy cell, origin host and
/// port. The cells keep TLS tickets from linking traffic across tenants or
/// policies, and host and port pin a ticket to its origin. Every dial under
/// one policy cell makes the same ALPN offer, since whether a fetch may speak
/// HTTP/2 is part of the policy the cell names, so the offer needs no key
/// component. The shim keeps one cache per client context, so the verified
/// and insecure split needs none either.
pub const max_session_key_bytes: usize = 16 + 16 + 253 + 2;

pub fn buildSessionKey(
    buffer: *[max_session_key_bytes]u8,
    security_cell_id: [16]u8,
    policy_cell_id: [16]u8,
    host: []const u8,
    port: u16,
) ?[]const u8 {
    if (host.len == 0 or host.len > 253)
        return null;
    @memcpy(buffer[0..16], &security_cell_id);
    @memcpy(buffer[16..32], &policy_cell_id);
    @memcpy(buffer[32..][0..host.len], host);
    const lowered = buffer[32..][0..host.len];
    _ = std.ascii.lowerString(lowered, lowered);
    std.mem.writeInt(u16, buffer[32 + host.len ..][0..2], port, .big);
    return buffer[0 .. 32 + host.len + 2];
}

/// TLS client where BoringSSL only converts between plaintext and
/// ciphertext. Socket I/O stays outside the shim, so the gateway can drive
/// network reads and writes through io_uring without BoringSSL owning an fd.
pub const BioConnection = struct {
    allocator: std.mem.Allocator,
    handle: *boring.ClientHandle,
    /// Always one of `offer`'s protocols once the handshake is done.
    protocol: ApplicationProtocol,
    offer: AlpnOffer,
    handshake_complete: bool,

    pub fn createUnhandshaken(
        allocator: std.mem.Allocator,
        server_name: []const u8,
        insecure_skip_verify: bool,
        offer: AlpnOffer,
        session_key: ?[]const u8,
    ) !*BioConnection {
        const context = try contexts.get(insecure_skip_verify);
        const server_name_z = try allocator.dupeZ(u8, server_name);
        defer allocator.free(server_name_z);

        var handle: ?*boring.ClientHandle = null;
        if (boring.collo_boringssl_client_conn_new_bio(
            context,
            server_name_z.ptr,
            @intFromEnum(offer),
            if (session_key) |key| key.ptr else null,
            if (session_key) |key| key.len else 0,
            &handle,
        ) != 0)
            return error.TlsConnectionInitializationFailed;
        const owned_handle = handle orelse return error.TlsConnectionInitializationFailed;
        errdefer boring.collo_boringssl_client_conn_free(owned_handle);

        const connection = try allocator.create(BioConnection);
        errdefer allocator.destroy(connection);
        connection.* = .{
            .allocator = allocator,
            .handle = owned_handle,
            .protocol = .http_1_1,
            .offer = offer,
            .handshake_complete = false,
        };
        return connection;
    }

    /// Fails with `error.TlsAlpnNotOffered` when the server selected a
    /// protocol the connection did not offer, so a caller may rely on
    /// `.done` naming one of its offer's protocols, such as a dial that
    /// offered http/1.1 alone for a fetch that must not speak HTTP/2.
    pub fn handshakeStep(self: *BioConnection) !HandshakeStep {
        if (self.handshake_complete)
            return .{ .done = self.protocol };

        var raw: boring.RawResult = std.mem.zeroes(boring.RawResult);
        if (boring.collo_boringssl_client_handshake_step(self.handle, &raw) != 0)
            return error.TlsHandshakeFailed;

        switch (raw.status) {
            boring.status_ok => {
                self.protocol = try decodeApplicationProtocol(raw.application_protocol, self.offer);
                self.handshake_complete = true;
                return .{ .done = self.protocol };
            },
            boring.status_want_read => return .{ .wait = .read },
            boring.status_want_write => return .{ .wait = .write },
            else => return error.TlsHandshakeFailed,
        }
    }

    pub fn sessionReused(self: *const BioConnection) bool {
        return boring.collo_boringssl_client_session_reused(self.handle) != 0;
    }

    pub fn readStep(self: *BioConnection, dest: []u8) !IoStep {
        if (dest.len == 0)
            return .{ .ready = 0 };
        var read_len: usize = 0;
        const status = boring.collo_boringssl_client_read(self.handle, dest.ptr, dest.len, &read_len);
        return switch (status) {
            boring.status_ok => if (read_len == 0) .eof else .{ .ready = read_len },
            boring.status_eof => .eof,
            boring.status_want_read => .{ .wait = .read },
            boring.status_want_write => .{ .wait = .write },
            else => error.TlsReadFailed,
        };
    }

    pub fn writeStep(self: *BioConnection, bytes: []const u8) !IoStep {
        if (bytes.len == 0)
            return .{ .ready = 0 };
        var written: usize = 0;
        const status = boring.collo_boringssl_client_write(self.handle, bytes.ptr, bytes.len, &written);
        return switch (status) {
            boring.status_ok => if (written == 0) error.TlsWriteFailed else .{ .ready = written },
            boring.status_want_read => .{ .wait = .read },
            boring.status_want_write => .{ .wait = .write },
            else => error.TlsWriteFailed,
        };
    }

    pub fn feedCiphertext(self: *BioConnection, bytes: []const u8) !CiphertextStep {
        if (bytes.len == 0)
            return .{ .ready = 0 };
        var consumed: usize = 0;
        const status = boring.collo_boringssl_client_feed_ciphertext(self.handle, bytes.ptr, bytes.len, &consumed);
        return switch (status) {
            boring.status_ok => .{ .ready = consumed },
            boring.status_want_write => .wait,
            else => error.TlsCiphertextFeedFailed,
        };
    }

    pub fn drainCiphertext(self: *BioConnection, dest: []u8) !CiphertextStep {
        if (dest.len == 0)
            return .{ .ready = 0 };
        var drained: usize = 0;
        const status = boring.collo_boringssl_client_drain_ciphertext(self.handle, dest.ptr, dest.len, &drained);
        return switch (status) {
            boring.status_ok => if (drained == 0) .wait else .{ .ready = drained },
            boring.status_want_read => .wait,
            boring.status_eof => .eof,
            else => error.TlsCiphertextDrainFailed,
        };
    }

    pub fn pendingCiphertext(self: *BioConnection) !usize {
        var pending: usize = 0;
        if (boring.collo_boringssl_client_pending_ciphertext(self.handle, &pending) != 0)
            return error.TlsCiphertextDrainFailed;
        return pending;
    }

    pub fn deinit(self: *BioConnection) void {
        boring.collo_boringssl_client_shutdown_best_effort(self.handle);
        boring.collo_boringssl_client_conn_free(self.handle);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }
};

/// BoringSSL already refuses an answer outside the offer unless a context
/// allows unknown protocols, which the shim's never do. The check here keeps
/// the guarantee `BioConnection.handshakeStep` gives in this file. A server
/// that answers no ALPN speaks http/1.1, which every offer includes.
fn decodeApplicationProtocol(raw: u8, offer: AlpnOffer) !ApplicationProtocol {
    return switch (raw) {
        boring.alpn_h2 => switch (offer) {
            .h2_http_1_1 => .h2,
            .http_1_1 => error.TlsAlpnNotOffered,
        },
        boring.alpn_http_1_1, boring.alpn_unspecified => .http_1_1,
        else => error.UnsupportedAlpnProtocol,
    };
}
