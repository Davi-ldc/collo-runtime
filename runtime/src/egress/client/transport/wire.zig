//! One outbound connection's bytes, for HTTP/1 and HTTP/2 alike: a socket,
//! the buffer its receives land in, the queue its sends leave from, and an
//! optional TLS transform in which BoringSSL only transforms bytes through
//! memory BIOs. A plain-HTTP wire is the identity transform.
//!
//! The engine's io_uring data driver (`io/bio_data.zig`) moves every byte
//! between the socket and the wire, with at most one receive and one send in
//! flight: a receive lands in `recvBuffer()` and `feedReceived` takes it, and
//! a send carries `sendSlice()` until `advanceSent` drops what went out. The
//! protocols read and write plaintext through `readStep` and `writeStep`,
//! which never touch the socket and answer `.wait` with what the wire needs
//! from the network first. One thread touches a wire at a time: the owner of
//! the engine shard that dialed it.
//!
//! Bytes held on this side, queued for sending plus TLS ciphertext the read
//! BIO did not take yet, are capped at `max_buffered_bytes`. While a send is
//! in flight the kernel reads the send queue's memory, so the queue is
//! neither compacted nor grown, and ciphertext that does not fit stays in
//! BoringSSL's write BIO until the send completes. A plain wire receives no
//! further bytes until the protocol has read the last receive, since the
//! kernel writes the next one into the same buffer.
//!
//! The end of the stream is the socket's EOF on both kinds of wire. A TLS
//! wire reports it once every byte received before it has gone through
//! BoringSSL, whether or not a close_notify came first, since BoringSSL's
//! memory read BIO never reports an end by itself. What a truncation costs
//! is the protocol's to decide, as for plain HTTP.
//!
//! A wire is clean for reuse when it holds no unread byte and has seen
//! neither EOF nor a failed receive or send: any leftover byte would be read
//! as the next response's head. The data driver marks every receive or send
//! failure here as it learns of it. The pool keeps a receive armed on an idle
//! wire, and the driver brings a wire up to date with its socket before the
//! pool leases it (`io/bio_data.zig:Driver.refreshIdleWire`), so a close, a
//! TLS close_notify or a stray byte that arrives while it idles lands here
//! and makes it unclean.

const std = @import("std");
const common_io = @import("collo_common_io");
const egress_tls = @import("../tls.zig");

const IoStep = egress_tls.IoStep;

/// The receive buffer of every wire, and the drain buffer of a TLS wire.
/// 16 KiB holds one full TLS record.
const io_buffer_bytes: usize = 16 * 1024;
/// Capacity a queue keeps after it drains.
const retain_bytes: usize = 16 * 1024;

pub const Wire = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    /// Null for plain HTTP.
    tls: ?*egress_tls.BioConnection,
    /// What the peer agreed to speak: ALPN's answer once a TLS handshake is
    /// done, http/1.1 for plain HTTP.
    protocol: egress_tls.ApplicationProtocol = .http_1_1,
    recv_buffer: []u8,
    /// Plain wires only: the unread part of the last receive is
    /// `recv_buffer[plain_start..plain_end]`.
    plain_start: usize = 0,
    plain_end: usize = 0,
    /// TLS wires only: room for the ciphertext BoringSSL emits; empty on a
    /// plain wire.
    drain_buffer: []u8,
    /// TLS wires only: received ciphertext the read BIO did not take at once
    /// (a stall or a partial consume), so `recv_buffer` is free again as
    /// soon as `feedReceived` returns.
    incoming: common_io.buffer.StreamBuffer,
    /// Bytes waiting to go to the socket: ciphertext on a TLS wire,
    /// plaintext on a plain one.
    outgoing: common_io.buffer.StreamBuffer,
    max_buffered_bytes: usize,
    recv_in_flight: bool = false,
    send_in_flight: bool = false,
    eof: bool = false,
    /// A receive failed: nothing more arrives, and bytes received before the
    /// failure stay readable.
    recv_failed: bool = false,
    send_broken: bool = false,

    pub const TlsOptions = struct {
        server_name: []const u8,
        insecure_tls: bool,
        /// Resumption ticket key (`tls.buildSessionKey`), null for none.
        session_key: ?[]const u8,
        /// False offers http/1.1 alone, for a fetch that must not speak
        /// HTTP/2.
        offer_h2: bool = true,
    };

    /// A TLS wire over `stream`, a connected nonblocking socket, before its
    /// handshake: the caller steps `handshakeStep` as receives and sends
    /// complete. Takes `stream` on every path, closing it on error.
    pub fn createTls(
        allocator: std.mem.Allocator,
        stream: std.net.Stream,
        options: TlsOptions,
        max_buffered_bytes: usize,
    ) !*Wire {
        errdefer stream.close();
        const drain_buffer = try allocator.alloc(u8, io_buffer_bytes);
        errdefer allocator.free(drain_buffer);
        const tls = try egress_tls.BioConnection.createUnhandshaken(
            allocator,
            options.server_name,
            options.insecure_tls,
            if (options.offer_h2) .h2_http_1_1 else .http_1_1,
            options.session_key,
        );
        errdefer tls.deinit();
        return create(allocator, stream, tls, drain_buffer, max_buffered_bytes);
    }

    /// A plain-HTTP wire over `stream`, a connected nonblocking socket,
    /// ready at once. Takes `stream` on every path, closing it on error.
    pub fn createPlain(
        allocator: std.mem.Allocator,
        stream: std.net.Stream,
        max_buffered_bytes: usize,
    ) !*Wire {
        errdefer stream.close();
        return create(allocator, stream, null, &.{}, max_buffered_bytes);
    }

    fn create(
        allocator: std.mem.Allocator,
        stream: std.net.Stream,
        tls: ?*egress_tls.BioConnection,
        drain_buffer: []u8,
        max_buffered_bytes: usize,
    ) !*Wire {
        const recv_buffer = try allocator.alloc(u8, io_buffer_bytes);
        errdefer allocator.free(recv_buffer);
        const wire = try allocator.create(Wire);
        const retain = @min(max_buffered_bytes, retain_bytes);
        wire.* = .{
            .allocator = allocator,
            .stream = stream,
            .tls = tls,
            .recv_buffer = recv_buffer,
            .drain_buffer = drain_buffer,
            .incoming = .init(allocator, if (tls != null) retain else 0),
            .outgoing = .init(allocator, retain),
            .max_buffered_bytes = max_buffered_bytes,
        };
        return wire;
    }

    /// Valid only once the data driver has released the wire (every receive
    /// and send it submitted has completed or been canceled), or for a wire
    /// it never saw.
    pub fn deinit(self: *Wire) void {
        self.incoming.deinit();
        self.outgoing.deinit();
        if (self.tls) |tls|
            tls.deinit();
        if (self.stream.handle >= 0)
            self.stream.close();
        self.allocator.free(self.recv_buffer);
        if (self.drain_buffer.len != 0)
            self.allocator.free(self.drain_buffer);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    pub fn fd(self: *const Wire) std.posix.fd_t {
        return self.stream.handle;
    }

    /// Steps the TLS handshake over the bytes the wire holds. Fails with
    /// `error.TlsHandshakeFailed` when the handshake breaks, or when it waits
    /// for a record after the socket's EOF, which nothing can deliver.
    pub fn handshakeStep(self: *Wire) !egress_tls.HandshakeStep {
        const tls = self.tls.?;
        _ = try self.pumpIncomingCiphertext(tls);
        const step = try tls.handshakeStep();
        try self.drainCiphertextIntoQueue(tls);
        switch (step) {
            .done => |protocol| self.protocol = protocol,
            .wait => |interest| {
                if (interest == .read and self.ciphertextExhausted())
                    return error.TlsHandshakeFailed;
            },
        }
        return step;
    }

    pub fn sessionReused(self: *const Wire) bool {
        const tls = self.tls orelse return false;
        return tls.sessionReused();
    }

    /// Reads plaintext the wire already holds into `dest`. `.wait = .read`
    /// means the wire needs another receive; `.wait = .write` means TLS must
    /// send first; `.eof` comes once every byte before the socket's EOF was
    /// read.
    pub fn readStep(self: *Wire, dest: []u8) !IoStep {
        const tls = self.tls orelse {
            const unread = self.recv_buffer[self.plain_start..self.plain_end];
            if (unread.len != 0) {
                const len = @min(unread.len, dest.len);
                @memcpy(dest[0..len], unread[0..len]);
                self.plain_start += len;
                if (self.plain_start == self.plain_end) {
                    self.plain_start = 0;
                    self.plain_end = 0;
                }
                return .{ .ready = len };
            }
            if (self.eof)
                return .eof;
            return .{ .wait = .read };
        };
        _ = try self.pumpIncomingCiphertext(tls);
        const step = try tls.readStep(dest);
        // SSL_read can emit post-handshake TLS control records, such as an
        // acknowledgement for a key update. The owner must see those bytes.
        try self.drainCiphertextIntoQueue(tls);
        switch (step) {
            // A close_notify ends the stream inside BoringSSL. Many servers
            // close without one, and then the stream ends once no ciphertext
            // is left to arrive.
            .wait => |interest| {
                if (interest == .read and self.ciphertextExhausted())
                    return .eof;
            },
            .ready, .eof => {},
        }
        return step;
    }

    /// Queues plaintext for sending, transformed on a TLS wire. Returns how
    /// much it took, or `.wait = .write` while the send queue has no room.
    pub fn writeStep(self: *Wire, bytes: []const u8) !IoStep {
        if (bytes.len == 0)
            return .{ .ready = 0 };
        if (self.send_broken)
            return .{ .ready = bytes.len };
        // While a kernel send pins the send queue and either its tail is full
        // or the budget is spent, accepting more would pile ciphertext into
        // BoringSSL's write BIO, C heap that neither the budget nor the
        // shard's counting allocator sees, or make the next drain fail with
        // WireBufferExceeded on bytes the budget has no room for. The queue's
        // allocated capacity can exceed the budget, so tail space alone does
        // not permit a write. The send completion advances the queue, frees
        // budget and re-arms write interest. When both checks pass, the
        // write BIO holds at most one caller chunk beyond what the queue
        // takes.
        if (self.send_in_flight and
            (self.outgoing.unusedCapacity() == 0 or self.bufferedNetworkBytes() >= self.max_buffered_bytes))
            return .{ .wait = .write };
        const tls = self.tls orelse {
            if (!self.send_in_flight)
                self.outgoing.compact();
            var room = self.max_buffered_bytes -| self.bufferedNetworkBytes();
            if (self.send_in_flight)
                room = @min(room, self.outgoing.unusedCapacity());
            if (room == 0)
                return .{ .wait = .write };
            const taken = bytes[0..@min(room, bytes.len)];
            if (self.send_in_flight)
                self.outgoing.writeAssumeCapacity(taken)
            else
                try self.outgoing.write(taken);
            return .{ .ready = taken.len };
        };
        _ = try self.pumpIncomingCiphertext(tls);
        const step = try tls.writeStep(bytes);
        try self.drainCiphertextIntoQueue(tls);
        return step;
    }

    /// Moves ciphertext BoringSSL produced into the send queue; nothing on a
    /// plain wire.
    pub fn flushOutgoing(self: *Wire) !void {
        const tls = self.tls orelse return;
        try self.drainCiphertextIntoQueue(tls);
    }

    pub fn recvBuffer(self: *Wire) []u8 {
        return self.recv_buffer;
    }

    /// Takes the `received_len` bytes a receive put in `recvBuffer()`; zero
    /// means EOF. On a TLS wire the bytes go straight into BoringSSL's read
    /// BIO, and what it does not take is staged under the budget, so the
    /// buffer is free when this returns.
    pub fn feedReceived(self: *Wire, received_len: usize) !void {
        if (received_len > self.recv_buffer.len)
            return error.WireFeedOverflow;
        if (received_len == 0) {
            self.eof = true;
            return;
        }
        const tls = self.tls orelse {
            std.debug.assert(self.plain_start == self.plain_end);
            self.plain_start = 0;
            self.plain_end = received_len;
            return;
        };
        try self.feedCiphertext(tls, self.recv_buffer[0..received_len]);
    }

    pub fn sendSlice(self: *const Wire) []const u8 {
        return self.outgoing.slice();
    }

    pub fn hasBytesToSend(self: *const Wire) bool {
        return self.outgoing.size() != 0;
    }

    /// Drops the `sent_len` bytes a send completed. Called after
    /// `markSendComplete`, which released the queue's pin, so ciphertext
    /// BoringSSL kept meanwhile moves into the queue now: `hasBytesToSend`
    /// is the only signal that arms the next send, and it never looks inside
    /// the write BIO.
    pub fn advanceSent(self: *Wire, sent_len: usize) !void {
        try self.outgoing.advance(sent_len);
        const tls = self.tls orelse return;
        try self.drainCiphertextIntoQueue(tls);
    }

    pub fn markRecvSubmitted(self: *Wire) void {
        self.recv_in_flight = true;
    }

    pub fn markRecvComplete(self: *Wire) void {
        self.recv_in_flight = false;
    }

    pub fn markSendSubmitted(self: *Wire) void {
        self.send_in_flight = true;
    }

    pub fn markSendComplete(self: *Wire) void {
        self.send_in_flight = false;
    }

    /// Half-close after a socket write failure: the peer already shut its
    /// read side, so queued and future outgoing bytes are discarded while
    /// reads keep draining whatever arrived before its FIN or RST.
    pub fn markSendBroken(self: *Wire) void {
        self.send_broken = true;
        self.outgoing.advance(self.outgoing.size()) catch |err|
            std.log.debug("egress wire send-broken discard failed: {s}", .{@errorName(err)});
    }

    /// A receive failed, or the bytes it brought could not be taken: the
    /// wire asks for no further receive and is never clean again. Bytes
    /// received before stay readable.
    pub fn markReceiveFailed(self: *Wire) void {
        self.recv_failed = true;
    }

    pub fn networkWantsRead(self: *const Wire) bool {
        if (self.recv_in_flight or self.eof or self.recv_failed)
            return false;
        if (self.tls != null)
            return self.incoming.isEmpty();
        return self.plain_start == self.plain_end;
    }

    pub fn networkWantsWrite(self: *const Wire) bool {
        return !self.send_in_flight and self.hasBytesToSend();
    }

    pub fn cleanForReuse(self: *Wire) bool {
        if (self.eof or self.recv_failed or self.send_broken or self.bufferedNetworkBytes() != 0)
            return false;
        if (self.tls == null)
            return self.plain_start == self.plain_end;
        // Surplus plaintext the peer packed into an already consumed TLS
        // record sits inside BoringSSL; a probe read that finds any, or a
        // close_notify, makes the wire unclean.
        var probe: [1]u8 = undefined;
        return switch (self.readStep(&probe) catch return false) {
            .ready, .eof => false,
            .wait => |interest| interest == .read and self.bufferedNetworkBytes() == 0,
        };
    }

    /// Closes the socket at once, so a receive or send in flight on it
    /// completes; the data driver still owns the wire until both have.
    pub fn shutdownSocketForCancel(self: *Wire) void {
        if (self.stream.handle < 0)
            return;
        std.posix.shutdown(self.stream.handle, .both) catch |err|
            std.log.debug("egress wire cancel shutdown failed: {s}", .{@errorName(err)});
        std.posix.close(self.stream.handle);
        self.stream.handle = -1;
    }

    /// Bytes this side holds against `max_buffered_bytes`.
    fn bufferedNetworkBytes(self: *const Wire) usize {
        return self.incoming.size() + self.outgoing.size();
    }

    /// TLS wires: the socket reached EOF and BoringSSL took every byte
    /// received before it, so no ciphertext is left to arrive. BoringSSL's
    /// memory read BIO reports an empty buffer as a retry, never as an end,
    /// so a step that still waits for a read then waits forever.
    fn ciphertextExhausted(self: *const Wire) bool {
        return self.eof and self.incoming.isEmpty();
    }

    fn feedCiphertext(self: *Wire, tls: *egress_tls.BioConnection, bytes: []const u8) !void {
        // Older staged bytes must reach BoringSSL before the new ones.
        _ = try self.pumpIncomingCiphertext(tls);
        if (!self.incoming.isEmpty()) {
            // The BIO is stalled behind staged bytes, so the new chunk is
            // staged too, under the budget, to keep TLS records in order.
            try self.stageIncoming(bytes);
            return;
        }
        if (bytes.len > self.max_buffered_bytes -| self.bufferedNetworkBytes())
            return error.WireBufferExceeded;
        var remaining = bytes;
        while (remaining.len != 0) {
            switch (try tls.feedCiphertext(remaining)) {
                .ready => |consumed| {
                    if (consumed == 0)
                        return error.TlsCiphertextFeedFailed;
                    remaining = remaining[consumed..];
                },
                .wait => break,
                .eof => {
                    self.eof = true;
                    break;
                },
            }
        }
        // On a stall or partial consume only the unconsumed remainder is
        // staged, within the budget checked above.
        if (remaining.len != 0)
            try self.incoming.write(remaining);
    }

    fn pumpIncomingCiphertext(self: *Wire, tls: *egress_tls.BioConnection) !usize {
        var consumed_total: usize = 0;
        while (!self.incoming.isEmpty()) {
            switch (try tls.feedCiphertext(self.incoming.slice())) {
                .ready => |consumed| {
                    if (consumed == 0)
                        return error.TlsCiphertextFeedFailed;
                    consumed_total += consumed;
                    try self.incoming.advance(consumed);
                },
                .wait => break,
                .eof => {
                    self.eof = true;
                    break;
                },
            }
        }
        return consumed_total;
    }

    fn stageIncoming(self: *Wire, bytes: []const u8) !void {
        if (bytes.len > self.max_buffered_bytes -| self.bufferedNetworkBytes())
            return error.WireBufferExceeded;
        try self.incoming.write(bytes);
    }

    fn drainCiphertextIntoQueue(self: *Wire, tls: *egress_tls.BioConnection) !void {
        while (true) {
            // An in-flight send captured the queue's base pointer at submit
            // time and the kernel reads it until the completion lands, so
            // while a send is in flight the memory must not move: no
            // compaction and no growing append. Ciphertext that does not fit
            // the allocated tail stays in BoringSSL's write BIO, and
            // `advanceSent` drains it once the completion releases the pin.
            if (!self.send_in_flight)
                self.outgoing.compact();
            const remaining_budget = self.max_buffered_bytes -| self.bufferedNetworkBytes();
            if (remaining_budget == 0) {
                if ((try tls.pendingCiphertext()) == 0)
                    return;
                return error.WireBufferExceeded;
            }
            var writable = remaining_budget;
            if (self.send_in_flight) {
                writable = @min(writable, self.outgoing.unusedCapacity());
                if (writable == 0)
                    return;
            }
            const scratch = self.drain_buffer[0..@min(self.drain_buffer.len, writable)];
            switch (try tls.drainCiphertext(scratch)) {
                .ready => |drained| {
                    if (drained == 0)
                        return;
                    // SSL_read can emit control records (key-update acks)
                    // after the send side broke; they are dropped with the
                    // rest.
                    if (!self.send_broken) {
                        if (self.send_in_flight)
                            self.outgoing.writeAssumeCapacity(scratch[0..drained])
                        else
                            try self.outgoing.write(scratch[0..drained]);
                    }
                },
                .wait => return,
                .eof => {
                    self.eof = true;
                    return;
                },
            }
        }
    }
};
