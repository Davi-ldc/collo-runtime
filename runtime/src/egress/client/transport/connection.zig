//! One outbound HTTP connection behind the interface the HTTP/1 and HTTP/2
//! paths share: plain TCP, TLS on the socket, memory-BIO TLS driven by the
//! io_uring data driver, or memory-BIO TLS doing its own socket calls.
//!
//! A connection returns to the HTTP/1 keep-alive pool only when
//! `cleanForReuse` finds no unread byte in any layer, because a leftover byte
//! would be read as the head of the next response.

const std = @import("std");
const accounting = @import("collo_egress_accounting");

const tls_bio = @import("tls_bio/root.zig");
const config_mod = @import("config.zig");
const egress_tls = @import("collo_egress_tls");

const IoStep = config_mod.IoStep;
const TlsBioTransport = tls_bio.TlsBioTransport;

const socket_read_buffer_bytes: usize = 8192;
const socket_write_buffer_bytes: usize = 1024;

pub fn setFdNonblocking(fd: std.posix.fd_t, enabled: bool) !void {
    const flags = try std.posix.fcntl(fd, std.posix.F.GETFL, 0);
    const nonblock_flag: usize = 1 << @bitOffsetOf(std.posix.O, "NONBLOCK");
    const next = if (enabled) flags | nonblock_flag else flags & ~nonblock_flag;
    _ = try std.posix.fcntl(fd, std.posix.F.SETFL, next);
}

pub const HttpConnection = union(enum) {
    plain: *HttpPlainConnection,
    fd_tls: *egress_tls.Connection,
    tls_bio: *TlsBioTransport,
    /// A memory-BIO TLS connection that makes its own socket calls instead
    /// of going through the io_uring data driver. The HTTP/2 connector
    /// produces it when ALPN settles on http/1.1, so the HTTP/1 path reuses a
    /// handshake that is already paid for.
    tls_bio_direct: *TlsBioTransport,

    pub fn fd(self: *const HttpConnection) std.posix.fd_t {
        return switch (self.*) {
            .plain => |plain| plain.stream.handle,
            .fd_tls => |tls| tls.stream.handle,
            .tls_bio, .tls_bio_direct => |tls| tls.fd(),
        };
    }

    pub fn applicationProtocol(self: *const HttpConnection) egress_tls.ApplicationProtocol {
        return switch (self.*) {
            .plain => .http_1_1,
            .fd_tls => |tls| tls.protocol,
            .tls_bio, .tls_bio_direct => |tls| tls.protocol,
        };
    }

    pub fn reader(self: *HttpConnection) *std.Io.Reader {
        return switch (self.*) {
            .plain => |plain| plain.stream_reader.interface(),
            .fd_tls => |tls| tls.reader(),
            .tls_bio, .tls_bio_direct => unreachable,
        };
    }

    pub fn readStep(self: *HttpConnection, dest: []u8) !IoStep {
        return switch (self.*) {
            .plain => |plain| blk: {
                const read_len = plain.stream.read(dest) catch |err| switch (err) {
                    error.WouldBlock => break :blk .{ .wait = .read },
                    else => return err,
                };
                break :blk if (read_len == 0) .eof else .{ .ready = read_len };
            },
            .fd_tls => |tls| try tls.readStep(dest),
            .tls_bio => |tls| try tls.readStep(dest),
            .tls_bio_direct => |tls| try tlsBioDirectReadStep(tls, dest),
        };
    }

    pub fn writeStep(self: *HttpConnection, bytes: []const u8) !IoStep {
        if (bytes.len == 0)
            return .{ .ready = 0 };
        return switch (self.*) {
            .plain => |plain| blk: {
                const written = plain.stream.write(bytes) catch |err| switch (err) {
                    error.WouldBlock => break :blk .{ .wait = .write },
                    else => return err,
                };
                break :blk if (written == 0) error.FetchWriteFailed else .{ .ready = written };
            },
            .fd_tls => |tls| try tls.writeStep(bytes),
            .tls_bio => |tls| try tls.writeStep(bytes),
            .tls_bio_direct => |tls| try tlsBioDirectWriteStep(tls, bytes),
        };
    }

    pub fn writer(self: *HttpConnection) *std.Io.Writer {
        return switch (self.*) {
            .plain => |plain| &plain.stream_writer.interface,
            .fd_tls => |tls| tls.writer(),
            .tls_bio, .tls_bio_direct => unreachable,
        };
    }

    pub fn flush(self: *HttpConnection) !void {
        switch (self.*) {
            .plain => |plain| try plain.stream_writer.interface.flush(),
            .fd_tls => |tls| try tls.flush(),
            .tls_bio => |tls| try tls.flushOutgoing(),
            .tls_bio_direct => |tls| {
                try tls.flushOutgoing();
                _ = try tlsBioDirectSendQueued(tls);
            },
        }
    }

    pub fn takeWireBytes(self: *HttpConnection) accounting.Bytes {
        return switch (self.*) {
            .tls_bio, .tls_bio_direct => |tls| tls.takeWireBytes(),
            else => .{},
        };
    }

    pub fn cleanForReuse(self: *HttpConnection) bool {
        return switch (self.*) {
            .plain => |plain| !fdHasReadableBytes(plain.stream.handle),
            // The socket peek sees only ciphertext still on the socket.
            // Surplus plaintext the peer packed into an already consumed TLS
            // record sits inside BoringSSL or the reader buffer and would
            // become the next response's head, so both layers are checked.
            .fd_tls => |tls| !tls.hasBufferedPlaintext() and !fdHasReadableBytes(tls.stream.handle),
            .tls_bio => |tls| tlsBioCleanForReuse(tls),
            .tls_bio_direct => |tls| tlsBioDirectCleanForReuse(tls),
        };
    }

    pub fn deinit(self: *HttpConnection) void {
        switch (self.*) {
            .plain => |plain| plain.deinit(),
            .fd_tls => |tls| tls.deinit(),
            .tls_bio, .tls_bio_direct => |tls| tls.deinit(),
        }
        self.* = undefined;
    }
};

fn fdHasReadableBytes(fd: std.posix.fd_t) bool {
    var probe: [1]u8 = undefined;
    _ = std.posix.recv(
        fd,
        &probe,
        std.posix.MSG.PEEK | std.posix.MSG.DONTWAIT,
    ) catch |err| return err != error.WouldBlock;
    return true;
}

fn tlsBioCleanForReuse(bio: *TlsBioTransport) bool {
    if (bio.pendingCiphertextLen() != 0 or bio.eof or bio.send_broken)
        return false;
    var probe: [1]u8 = undefined;
    return switch (bio.readStep(&probe) catch return false) {
        .ready, .eof => false,
        .wait => |interest| interest == .read and bio.pendingCiphertextLen() == 0,
    };
}

fn tlsBioDirectCleanForReuse(bio: *TlsBioTransport) bool {
    if (bio.pendingCiphertextLen() != 0 or bio.eof or bio.send_broken)
        return false;
    var probe: [1]u8 = undefined;
    return switch (tlsBioDirectReadStep(bio, &probe) catch return false) {
        .ready, .eof => false,
        .wait => |interest| interest == .read and bio.pendingCiphertextLen() == 0,
    };
}

/// Pushes queued TLS records to the socket. Returns true when the queue
/// drained and false when the socket would block, in which case the caller
/// waits for write readiness.
fn tlsBioDirectSendQueued(bio: *TlsBioTransport) !bool {
    while (bio.hasCiphertextToSend()) {
        const pending = bio.sendCiphertextSlice();
        const sent = std.posix.send(
            bio.fd(),
            pending,
            std.posix.MSG.DONTWAIT | std.posix.MSG.NOSIGNAL,
        ) catch |err| switch (err) {
            error.WouldBlock => return false,
            error.BrokenPipe => return error.BrokenPipe,
            error.ConnectionResetByPeer => return error.ConnectionResetByPeer,
            else => return error.FetchWriteFailed,
        };
        if (sent == 0)
            return error.FetchWriteFailed;
        bio.recordCiphertextSent(sent);
        try bio.advanceSentCiphertext(sent);
    }
    return true;
}

fn tlsBioDirectReadStep(bio: *TlsBioTransport, dest: []u8) !IoStep {
    while (true) {
        const step = try bio.readStep(dest);
        // Queued control records and request bytes are sent before waiting
        // for input, so the peer is never left waiting on our output while
        // we wait on its input.
        const drained = try tlsBioDirectSendQueued(bio);
        switch (step) {
            .ready, .eof => return step,
            .wait => |interest| switch (interest) {
                .write => return .{ .wait = .write },
                .read => {
                    if (!drained)
                        return .{ .wait = .write };
                    const received = std.posix.recv(
                        bio.fd(),
                        bio.recv_buffer,
                        std.posix.MSG.DONTWAIT,
                    ) catch |err| switch (err) {
                        error.WouldBlock => return .{ .wait = .read },
                        else => return err,
                    };
                    bio.recordCiphertextReceived(received);
                    _ = try bio.feedReceivedCiphertext(received);
                },
            },
        }
    }
}

fn tlsBioDirectWriteStep(bio: *TlsBioTransport, bytes: []const u8) !IoStep {
    const step = try bio.writeStep(bytes);
    const drained = try tlsBioDirectSendQueued(bio);
    return switch (step) {
        // Ciphertext left queued after a consumed write flushes on the next
        // step; the bounded ciphertext buffer provides the backpressure.
        .ready, .eof => step,
        .wait => |interest| switch (interest) {
            .write => .{ .wait = .write },
            .read => if (drained) .{ .wait = .read } else .{ .wait = .write },
        },
    };
}

pub const HttpPlainConnection = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    read_buffer: []u8,
    write_buffer: []u8,
    stream_reader: std.net.Stream.Reader,
    stream_writer: std.net.Stream.Writer,

    pub fn create(allocator: std.mem.Allocator, stream: std.net.Stream) !*HttpPlainConnection {
        errdefer stream.close();
        const read_buffer = try allocator.alloc(u8, socket_read_buffer_bytes);
        errdefer allocator.free(read_buffer);
        const write_buffer = try allocator.alloc(u8, socket_write_buffer_bytes);
        errdefer allocator.free(write_buffer);
        const plain = try allocator.create(HttpPlainConnection);
        errdefer allocator.destroy(plain);
        plain.* = .{
            .allocator = allocator,
            .stream = stream,
            .read_buffer = read_buffer,
            .write_buffer = write_buffer,
            .stream_reader = stream.reader(read_buffer),
            .stream_writer = stream.writer(write_buffer),
        };
        return plain;
    }

    fn deinit(self: *HttpPlainConnection) void {
        self.stream.close();
        self.allocator.free(self.read_buffer);
        self.allocator.free(self.write_buffer);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }
};
