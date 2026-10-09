//! BoringSSL client connections for outbound fetches. Certificate
//! verification, ALPN and session resumption live in the BoringSSL shim.
//!
//! Two shapes share one process-wide pair of client contexts, verified and
//! insecure. `Connection` lets BoringSSL read and write the socket fd itself;
//! `BioConnection` only transforms bytes and leaves every socket operation to
//! the caller. Both report a step that needs more socket I/O as the interest
//! to wait for.

const std = @import("std");
const boring = @import("collo_boringssl");

const read_buffer_bytes: usize = 16 * 1024;
const write_buffer_bytes: usize = 8 * 1024;

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

pub const AlpnOffer = enum(c_int) {
    http_1_1 = boring.alpn_offer_http_1_1,
    h2_http_1_1 = boring.alpn_offer_h2_http_1_1,
    h2_only = boring.alpn_offer_h2_only,
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

/// Session-resumption cache key: security cell, policy cell, ALPN offer,
/// origin host and port. The cells keep TLS tickets from linking traffic
/// across tenants or policies, the ALPN offer keeps HTTP/1-only and
/// speculative HTTP/2 tickets apart, and host and port pin a ticket to its
/// origin. The shim keeps one cache per client context, so the verified and
/// insecure split needs no key component.
pub const max_session_key_bytes: usize = 16 + 16 + 1 + 253 + 2;

pub fn buildSessionKey(
    buffer: *[max_session_key_bytes]u8,
    security_cell_id: [16]u8,
    policy_cell_id: [16]u8,
    alpn_offer: AlpnOffer,
    host: []const u8,
    port: u16,
) ?[]const u8 {
    if (host.len == 0 or host.len > 253)
        return null;
    @memcpy(buffer[0..16], &security_cell_id);
    @memcpy(buffer[16..32], &policy_cell_id);
    buffer[32] = @intCast(@intFromEnum(alpn_offer));
    @memcpy(buffer[33..][0..host.len], host);
    const lowered = buffer[33..][0..host.len];
    _ = std.ascii.lowerString(lowered, lowered);
    std.mem.writeInt(u16, buffer[33 + host.len ..][0..2], port, .big);
    return buffer[0 .. 33 + host.len + 2];
}

/// TLS client that owns the socket fd. Its std.Io reader and writer treat a
/// step that would block as a failure, so they need a blocking socket;
/// nonblocking callers use `readStep` and `writeStep`.
pub const Connection = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    handle: *boring.ClientHandle,
    protocol: ApplicationProtocol,
    alpn_offer: AlpnOffer,
    handshake_complete: bool,
    read_buffer: []u8,
    write_buffer: []u8,
    reader_interface: std.Io.Reader,
    writer_interface: std.Io.Writer,

    pub fn create(
        allocator: std.mem.Allocator,
        stream: std.net.Stream,
        server_name: []const u8,
        insecure_skip_verify: bool,
        offer: AlpnOffer,
        session_key: ?[]const u8,
    ) !*Connection {
        const connection = try createUnhandshaken(allocator, stream, server_name, insecure_skip_verify, offer, session_key);
        errdefer connection.deinit();
        switch (try connection.handshakeStep()) {
            .done => return connection,
            .wait => return error.TlsHandshakeWouldBlock,
        }
    }

    pub fn createUnhandshaken(
        allocator: std.mem.Allocator,
        stream: std.net.Stream,
        server_name: []const u8,
        insecure_skip_verify: bool,
        offer: AlpnOffer,
        session_key: ?[]const u8,
    ) !*Connection {
        errdefer stream.close();
        const context = try contexts.get(insecure_skip_verify);
        const server_name_z = try allocator.dupeZ(u8, server_name);
        defer allocator.free(server_name_z);

        var handle: ?*boring.ClientHandle = null;
        if (boring.collo_boringssl_client_conn_new(
            context,
            @intCast(stream.handle),
            server_name_z.ptr,
            @intFromEnum(offer),
            if (session_key) |key| key.ptr else null,
            if (session_key) |key| key.len else 0,
            &handle,
        ) != 0)
            return error.TlsConnectionInitializationFailed;
        const owned_handle = handle orelse return error.TlsConnectionInitializationFailed;
        errdefer boring.collo_boringssl_client_conn_free(owned_handle);

        const read_buffer = try allocator.alloc(u8, read_buffer_bytes);
        errdefer allocator.free(read_buffer);
        const write_buffer = try allocator.alloc(u8, write_buffer_bytes);
        errdefer allocator.free(write_buffer);
        const connection = try allocator.create(Connection);
        errdefer allocator.destroy(connection);

        connection.* = .{
            .allocator = allocator,
            .stream = stream,
            .handle = owned_handle,
            .protocol = .http_1_1,
            .alpn_offer = offer,
            .handshake_complete = false,
            .read_buffer = read_buffer,
            .write_buffer = write_buffer,
            .reader_interface = .{
                .vtable = &.{
                    .stream = readerStream,
                    .readVec = readVec,
                },
                .buffer = read_buffer,
                .seek = 0,
                .end = 0,
            },
            .writer_interface = .{
                .vtable = &.{ .drain = drain },
                .buffer = write_buffer,
            },
        };
        return connection;
    }

    pub fn handshakeStep(self: *Connection) !HandshakeStep {
        return handshakeStepHandle(self.handle, &self.protocol, &self.handshake_complete, self.alpn_offer);
    }

    pub fn sessionReused(self: *const Connection) bool {
        return boring.collo_boringssl_client_session_reused(self.handle) != 0;
    }

    /// True when received bytes are already buffered on this connection,
    /// in the Zig reader buffer or inside BoringSSL (the decrypted surplus of
    /// a record, or a record received but not yet processed). A raw-fd
    /// MSG_PEEK sees neither layer, so a pooled connection's reuse check must
    /// consult this: buffered bytes mean the previous response over-delivered
    /// and the next request would read its leftovers. A probe error counts as
    /// buffered, which discards the connection.
    pub fn hasBufferedPlaintext(self: *Connection) bool {
        if (self.reader_interface.buffered().len != 0)
            return true;
        var has_buffered: c_int = 0;
        if (boring.collo_boringssl_client_has_buffered_input(self.handle, &has_buffered) != boring.status_ok)
            return true;
        return has_buffered != 0;
    }

    pub fn reader(self: *Connection) *std.Io.Reader {
        return &self.reader_interface;
    }

    pub fn writer(self: *Connection) *std.Io.Writer {
        return &self.writer_interface;
    }

    pub fn flush(self: *Connection) !void {
        try self.writer_interface.flush();
    }

    pub fn deinit(self: *Connection) void {
        if (self.stream.handle >= 0)
            boring.collo_boringssl_client_shutdown_best_effort(self.handle);
        boring.collo_boringssl_client_conn_free(self.handle);
        if (self.stream.handle >= 0)
            self.stream.close();
        self.allocator.free(self.read_buffer);
        self.allocator.free(self.write_buffer);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn readStep(self: *Connection, dest: []u8) !IoStep {
        return readStepHandle(self.handle, dest);
    }

    pub fn writeStep(self: *Connection, bytes: []const u8) !IoStep {
        return writeStepHandle(self.handle, bytes);
    }

    fn readerStream(io_reader: *std.Io.Reader, io_writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const dest = limit.slice(try io_writer.writableSliceGreedy(1));
        var bufs: [1][]u8 = .{dest};
        const n = try readVec(io_reader, &bufs);
        io_writer.advance(n);
        return n;
    }

    fn readVec(io_reader: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const self: *Connection = @alignCast(@fieldParentPtr("reader_interface", io_reader));
        const into_reader_buffer = data[0].len == 0;
        const dest = if (into_reader_buffer) io_reader.buffer[io_reader.end..] else data[0];
        if (dest.len == 0)
            return error.ReadFailed;
        switch (self.readStep(dest) catch return error.ReadFailed) {
            .ready => |read_len| {
                if (into_reader_buffer) {
                    io_reader.end += read_len;
                    return 0;
                }
                return read_len;
            },
            .eof => return error.EndOfStream,
            .wait => return error.ReadFailed,
        }
    }

    fn drain(io_writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Connection = @alignCast(@fieldParentPtr("writer_interface", io_writer));
        if (io_writer.end != 0) {
            try self.writeAll(io_writer.buffered());
            io_writer.end = 0;
        }
        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.writeAll(bytes);
            consumed += bytes.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            try self.writeAll(pattern);
            consumed += pattern.len;
        }
        return consumed;
    }

    fn writeAll(self: *Connection, bytes: []const u8) std.Io.Writer.Error!void {
        var remaining = bytes;
        while (remaining.len != 0) {
            switch (self.writeStep(remaining) catch return error.WriteFailed) {
                .ready => |written| remaining = remaining[written..],
                .wait, .eof => return error.WriteFailed,
            }
        }
    }
};

/// TLS client where BoringSSL only converts between plaintext and
/// ciphertext. Socket I/O stays outside the shim, so the gateway can drive
/// network reads and writes through io_uring without BoringSSL owning an fd.
pub const BioConnection = struct {
    allocator: std.mem.Allocator,
    handle: *boring.ClientHandle,
    protocol: ApplicationProtocol,
    alpn_offer: AlpnOffer,
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
            .alpn_offer = offer,
            .handshake_complete = false,
        };
        return connection;
    }

    pub fn handshakeStep(self: *BioConnection) !HandshakeStep {
        return handshakeStepHandle(self.handle, &self.protocol, &self.handshake_complete, self.alpn_offer);
    }

    pub fn sessionReused(self: *const BioConnection) bool {
        return boring.collo_boringssl_client_session_reused(self.handle) != 0;
    }

    pub fn readStep(self: *BioConnection, dest: []u8) !IoStep {
        return readStepHandle(self.handle, dest);
    }

    pub fn writeStep(self: *BioConnection, bytes: []const u8) !IoStep {
        return writeStepHandle(self.handle, bytes);
    }

    pub fn feedCiphertext(self: *BioConnection, bytes: []const u8) !CiphertextStep {
        return feedCiphertextHandle(self.handle, bytes);
    }

    pub fn drainCiphertext(self: *BioConnection, dest: []u8) !CiphertextStep {
        return drainCiphertextHandle(self.handle, dest);
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

fn handshakeStepHandle(
    handle: *boring.ClientHandle,
    protocol_out: *ApplicationProtocol,
    complete: *bool,
    offer: AlpnOffer,
) !HandshakeStep {
    if (complete.*)
        return .{ .done = protocol_out.* };

    var raw: boring.RawResult = std.mem.zeroes(boring.RawResult);
    if (boring.collo_boringssl_client_handshake_step(handle, &raw) != 0)
        return error.TlsHandshakeFailed;

    switch (raw.status) {
        boring.status_ok => {
            const protocol = try decodeApplicationProtocol(raw.application_protocol, offer);
            protocol_out.* = protocol;
            complete.* = true;
            return .{ .done = protocol };
        },
        boring.status_want_read => return .{ .wait = .read },
        boring.status_want_write => return .{ .wait = .write },
        else => return error.TlsHandshakeFailed,
    }
}

fn readStepHandle(handle: *boring.ClientHandle, dest: []u8) !IoStep {
    if (dest.len == 0)
        return .{ .ready = 0 };
    var read_len: usize = 0;
    const status = boring.collo_boringssl_client_read(handle, dest.ptr, dest.len, &read_len);
    return switch (status) {
        boring.status_ok => if (read_len == 0) .eof else .{ .ready = read_len },
        boring.status_eof => .eof,
        boring.status_want_read => .{ .wait = .read },
        boring.status_want_write => .{ .wait = .write },
        else => error.TlsReadFailed,
    };
}

fn writeStepHandle(handle: *boring.ClientHandle, bytes: []const u8) !IoStep {
    if (bytes.len == 0)
        return .{ .ready = 0 };
    var written: usize = 0;
    const status = boring.collo_boringssl_client_write(handle, bytes.ptr, bytes.len, &written);
    return switch (status) {
        boring.status_ok => if (written == 0) error.TlsWriteFailed else .{ .ready = written },
        boring.status_want_read => .{ .wait = .read },
        boring.status_want_write => .{ .wait = .write },
        else => error.TlsWriteFailed,
    };
}

fn feedCiphertextHandle(handle: *boring.ClientHandle, bytes: []const u8) !CiphertextStep {
    if (bytes.len == 0)
        return .{ .ready = 0 };
    var consumed: usize = 0;
    const status = boring.collo_boringssl_client_feed_ciphertext(handle, bytes.ptr, bytes.len, &consumed);
    return switch (status) {
        boring.status_ok => .{ .ready = consumed },
        boring.status_want_write => .wait,
        else => error.TlsCiphertextFeedFailed,
    };
}

fn drainCiphertextHandle(handle: *boring.ClientHandle, dest: []u8) !CiphertextStep {
    if (dest.len == 0)
        return .{ .ready = 0 };
    var drained: usize = 0;
    const status = boring.collo_boringssl_client_drain_ciphertext(handle, dest.ptr, dest.len, &drained);
    return switch (status) {
        boring.status_ok => if (drained == 0) .wait else .{ .ready = drained },
        boring.status_want_read => .wait,
        boring.status_eof => .eof,
        else => error.TlsCiphertextDrainFailed,
    };
}

fn decodeApplicationProtocol(raw: u8, offer: AlpnOffer) !ApplicationProtocol {
    return switch (raw) {
        boring.alpn_h2 => .h2,
        boring.alpn_http_1_1, boring.alpn_unspecified => if (offer == .h2_only)
            error.Http2AlpnNotNegotiated
        else
            .http_1_1,
        else => error.UnsupportedAlpnProtocol,
    };
}
