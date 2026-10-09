//! TLS transport where BoringSSL only transforms bytes and the caller moves
//! ciphertext between the socket and BoringSSL's memory BIOs. In the gateway,
//! a connector thread drives it through the handshake and then hands it to
//! the engine owner thread; one thread touches it at a time.
//!
//! Ciphertext held on this side, staged incoming plus queued outgoing, is
//! capped at `max_ciphertext_bytes`. While a kernel send is in flight the
//! outgoing buffer's memory must not move, so it is neither compacted nor
//! grown, and ciphertext that does not fit stays in BoringSSL's write BIO
//! until the send completes. A caller's receive buffer can be reused as soon
//! as a feed call returns.

const std = @import("std");
const accounting = @import("collo_egress_accounting");
const common_io = @import("collo_common_io");
const egress_io = @import("collo_egress_io");

pub const config = @import("config.zig");
pub const lease_queue = @import("lease_queue.zig");

const transport_config = @import("../config.zig");
const egress_tls = @import("collo_egress_tls");

pub const TlsRxMode = config.TlsRxMode;

const IoStep = transport_config.IoStep;

const tls_ciphertext_io_buffer_bytes: usize = 16 * 1024;
const tls_ciphertext_retain_bytes: usize = 16 * 1024;

/// The io_uring data driver (`io/bio_data.zig`) owns this transport's socket
/// I/O: recv completions hand received ciphertext (an io_uring provided
/// buffer or `recv_buffer`) to `feedCiphertext` or `feedReceivedCiphertext`,
/// which write the bytes straight into BoringSSL's memory read BIO; SSL_write
/// output drains into `outgoing_ciphertext`, and send completions advance
/// that queue. An HTTP/1 connection inherited from the HTTP/2 connector
/// (`HttpConnection.tls_bio_direct`) makes the same calls around its own
/// nonblocking syscalls. `incoming_ciphertext` is off the hot path: it only
/// stages bytes the read BIO did not take at once (a stall or a partial
/// consume), so callers can always recycle their receive buffer when the
/// feed call returns.
pub const TlsBioTransport = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    tls: *egress_tls.BioConnection,
    protocol: egress_tls.ApplicationProtocol = .http_1_1,
    recv_buffer: []u8,
    drain_buffer: []u8,
    incoming_ciphertext: common_io.buffer.StreamBuffer,
    outgoing_ciphertext: common_io.buffer.StreamBuffer,
    max_ciphertext_bytes: usize,
    wire_bytes: accounting.Bytes = .{},
    ciphertext_limit_hit: bool = false,
    recv_in_flight: bool = false,
    send_in_flight: bool = false,
    eof: bool = false,
    send_broken: bool = false,

    pub fn createUnhandshaken(
        allocator: std.mem.Allocator,
        stream: std.net.Stream,
        server_name: []const u8,
        insecure_tls: bool,
        offer: egress_tls.AlpnOffer,
        max_ciphertext_bytes: usize,
        session_key: ?[]const u8,
    ) !*TlsBioTransport {
        errdefer stream.close();
        const recv_buffer = try allocator.alloc(u8, tls_ciphertext_io_buffer_bytes);
        errdefer allocator.free(recv_buffer);
        const drain_buffer = try allocator.alloc(u8, tls_ciphertext_io_buffer_bytes);
        errdefer allocator.free(drain_buffer);
        const tls = try egress_tls.BioConnection.createUnhandshaken(
            allocator,
            server_name,
            insecure_tls,
            offer,
            session_key,
        );
        errdefer tls.deinit();
        const transport = try allocator.create(TlsBioTransport);
        errdefer allocator.destroy(transport);
        transport.* = .{
            .allocator = allocator,
            .stream = stream,
            .tls = tls,
            .recv_buffer = recv_buffer,
            .drain_buffer = drain_buffer,
            .incoming_ciphertext = .init(allocator, @min(max_ciphertext_bytes, tls_ciphertext_retain_bytes)),
            .outgoing_ciphertext = .init(allocator, @min(max_ciphertext_bytes, tls_ciphertext_retain_bytes)),
            .max_ciphertext_bytes = max_ciphertext_bytes,
        };
        return transport;
    }

    pub fn fd(self: *const TlsBioTransport) std.posix.fd_t {
        return self.stream.handle;
    }

    pub fn waitHandle(self: *const TlsBioTransport) egress_io.WaitHandle {
        return .{ .fd = self.fd() };
    }

    pub fn recvSlice(self: *TlsBioTransport) []u8 {
        return self.recv_buffer;
    }

    pub fn handshakeStep(self: *TlsBioTransport) !egress_tls.HandshakeStep {
        _ = try self.pumpIncomingCiphertext();
        const step = try self.tls.handshakeStep();
        try self.drainCiphertextIntoQueue();
        switch (step) {
            .done => |protocol| self.protocol = protocol,
            .wait => {},
        }
        return step;
    }

    pub fn sessionReused(self: *const TlsBioTransport) bool {
        return self.tls.sessionReused();
    }

    pub fn readStep(self: *TlsBioTransport, dest: []u8) !IoStep {
        _ = try self.pumpIncomingCiphertext();
        const step = try self.tls.readStep(dest);
        // SSL_read can emit post-handshake TLS control records, such as an
        // acknowledgement for a key update. The owner must see those bytes.
        try self.drainCiphertextIntoQueue();
        return step;
    }

    pub fn writeStep(self: *TlsBioTransport, bytes: []const u8) !IoStep {
        if (self.send_broken)
            return .{ .ready = bytes.len };
        // While a kernel send pins the outgoing buffer and either its tail is
        // full or the ciphertext budget is spent, accepting more plaintext
        // would pile ciphertext into BoringSSL's write BIO, C heap that
        // neither the budget nor the shard's counting allocator sees, or
        // make the next drain fail with TlsCiphertextBufferExceeded on bytes
        // the budget has no room for. The buffer's allocated capacity can
        // exceed the budget, so tail space alone does not permit a write.
        // Wait for writability instead: the send completion advances the
        // queue, frees budget, drains again and re-arms write interest. When
        // both checks pass, the write BIO holds at most one caller chunk
        // beyond what the queue takes.
        if (self.send_in_flight and
            (self.outgoing_ciphertext.unusedCapacity() == 0 or
                self.pendingCiphertextLen() >= self.max_ciphertext_bytes))
            return .{ .wait = .write };
        _ = try self.pumpIncomingCiphertext();
        const step = try self.tls.writeStep(bytes);
        try self.drainCiphertextIntoQueue();
        return step;
    }

    pub fn flushOutgoing(self: *TlsBioTransport) !void {
        try self.drainCiphertextIntoQueue();
    }

    pub fn feedReceivedCiphertext(self: *TlsBioTransport, received_len: usize) !usize {
        if (received_len > self.recv_buffer.len)
            return error.TlsCiphertextFeedOverflow;
        if (received_len == 0) {
            self.eof = true;
            return 0;
        }
        return try self.feedCiphertext(self.recv_buffer[0..received_len]);
    }

    /// Feeds received ciphertext to BoringSSL straight from the caller's
    /// buffer. The read BIO is a memory BIO, so accepted bytes are copied
    /// into BoringSSL before this returns and the caller may recycle the
    /// buffer at once. Bytes the BIO does not accept are staged in
    /// `incoming_ciphertext` under the ciphertext budget, so a partial
    /// consume never needs the caller's buffer to outlive this call.
    pub fn feedCiphertext(self: *TlsBioTransport, bytes: []const u8) !usize {
        // Older staged bytes must reach BoringSSL before the new ones.
        var consumed_total = try self.pumpIncomingCiphertext();
        if (!self.incoming_ciphertext.isEmpty()) {
            // The BIO is stalled behind staged bytes, so the new chunk is
            // staged too, under the budget, to keep TLS records in order.
            try self.queueIncomingCiphertext(bytes);
            return consumed_total;
        }
        if (bytes.len > self.max_ciphertext_bytes -| self.pendingCiphertextLen()) {
            self.ciphertext_limit_hit = true;
            return error.TlsCiphertextBufferExceeded;
        }
        var remaining = bytes;
        while (remaining.len != 0) {
            switch (try self.tls.feedCiphertext(remaining)) {
                .ready => |consumed| {
                    if (consumed == 0)
                        return error.TlsCiphertextFeedFailed;
                    consumed_total += consumed;
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
            try self.incoming_ciphertext.write(remaining);
        return consumed_total;
    }

    pub fn queuedReceivedCiphertextLen(self: *const TlsBioTransport) usize {
        return self.incoming_ciphertext.size();
    }

    pub fn pendingCiphertextLen(self: *const TlsBioTransport) usize {
        return self.incoming_ciphertext.size() + self.outgoing_ciphertext.size();
    }

    fn pumpIncomingCiphertext(self: *TlsBioTransport) !usize {
        var consumed_total: usize = 0;
        while (!self.incoming_ciphertext.isEmpty()) {
            const remaining = self.incoming_ciphertext.slice();
            switch (try self.tls.feedCiphertext(remaining)) {
                .ready => |consumed| {
                    if (consumed == 0)
                        return error.TlsCiphertextFeedFailed;
                    consumed_total += consumed;
                    try self.incoming_ciphertext.advance(consumed);
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

    fn queueIncomingCiphertext(self: *TlsBioTransport, bytes: []const u8) !void {
        if (bytes.len > self.max_ciphertext_bytes -| self.pendingCiphertextLen()) {
            self.ciphertext_limit_hit = true;
            return error.TlsCiphertextBufferExceeded;
        }
        try self.incoming_ciphertext.write(bytes);
    }

    pub fn sendCiphertextSlice(self: *const TlsBioTransport) []const u8 {
        return self.outgoing_ciphertext.slice();
    }

    pub fn queuedCiphertextLen(self: *const TlsBioTransport) usize {
        return self.outgoing_ciphertext.size();
    }

    pub fn hasCiphertextToSend(self: *const TlsBioTransport) bool {
        return self.queuedCiphertextLen() != 0;
    }

    pub fn advanceSentCiphertext(self: *TlsBioTransport, sent_len: usize) !void {
        try self.outgoing_ciphertext.advance(sent_len);
        // The send completion has already released the buffer pin
        // (markSendComplete runs before this call), so ciphertext BoringSSL
        // kept while the kernel owned the buffer must be pulled now:
        // hasCiphertextToSend is the only signal that arms the next send,
        // and it never looks inside the write BIO.
        try self.drainCiphertextIntoQueue();
    }

    pub fn recordCiphertextReceived(self: *TlsBioTransport, received_len: usize) void {
        self.wire_bytes.addReceived(received_len);
    }

    pub fn recordCiphertextSent(self: *TlsBioTransport, sent_len: usize) void {
        self.wire_bytes.addSent(sent_len);
    }

    pub fn takeWireBytes(self: *TlsBioTransport) accounting.Bytes {
        const out = self.wire_bytes;
        self.wire_bytes = .{};
        return out;
    }

    pub fn markRecvSubmitted(self: *TlsBioTransport) void {
        self.recv_in_flight = true;
    }

    pub fn markRecvComplete(self: *TlsBioTransport) void {
        self.recv_in_flight = false;
    }

    pub fn markSendSubmitted(self: *TlsBioTransport) void {
        self.send_in_flight = true;
    }

    pub fn markSendComplete(self: *TlsBioTransport) void {
        self.send_in_flight = false;
    }

    /// Half-close after a socket write failure: the peer already shut its
    /// read side, so queued and future outgoing ciphertext is discarded
    /// while reads keep draining whatever arrived before its FIN or RST.
    pub fn markSendBroken(self: *TlsBioTransport) void {
        self.send_broken = true;
        self.outgoing_ciphertext.advance(self.outgoing_ciphertext.size()) catch |err|
            std.log.debug("egress TLS BIO send-broken discard failed: {s}", .{@errorName(err)});
    }

    pub fn networkWantsRead(self: *const TlsBioTransport) bool {
        return !self.recv_in_flight and !self.eof and self.incoming_ciphertext.isEmpty();
    }

    pub fn networkWantsWrite(self: *const TlsBioTransport) bool {
        return !self.send_in_flight and self.hasCiphertextToSend();
    }

    pub fn shutdownSocketForCancel(self: *TlsBioTransport) void {
        if (self.stream.handle < 0)
            return;
        std.posix.shutdown(self.stream.handle, .both) catch |err|
            std.log.debug("egress TLS BIO cancel shutdown failed: {s}", .{@errorName(err)});
        std.posix.close(self.stream.handle);
        self.stream.handle = -1;
    }

    pub fn deinit(self: *TlsBioTransport) void {
        self.incoming_ciphertext.deinit();
        self.outgoing_ciphertext.deinit();
        self.tls.deinit();
        if (self.stream.handle >= 0)
            self.stream.close();
        self.allocator.free(self.recv_buffer);
        self.allocator.free(self.drain_buffer);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    fn drainCiphertextIntoQueue(self: *TlsBioTransport) !void {
        while (true) {
            // An in-flight send SQE captured outgoing_ciphertext's base
            // pointer at submit time and the kernel reads it until the CQE
            // lands, so while send_in_flight the backing memory must not
            // move: no compaction and no growing append. Ciphertext that does
            // not fit the allocated tail stays in BoringSSL's write BIO, and
            // advanceSentCiphertext drains it once the completion releases
            // the pin.
            if (!self.send_in_flight)
                self.outgoing_ciphertext.compact();
            const queued = self.pendingCiphertextLen();
            const remaining_budget = self.max_ciphertext_bytes -| queued;
            if (remaining_budget == 0) {
                if ((try self.tls.pendingCiphertext()) == 0)
                    return;
                self.ciphertext_limit_hit = true;
                return error.TlsCiphertextBufferExceeded;
            }
            var writable = remaining_budget;
            if (self.send_in_flight) {
                writable = @min(writable, self.outgoing_ciphertext.unusedCapacity());
                if (writable == 0)
                    return;
            }
            const scratch = self.drain_buffer[0..@min(self.drain_buffer.len, writable)];
            switch (try self.tls.drainCiphertext(scratch)) {
                .ready => |drained| {
                    if (drained == 0)
                        return;
                    // SSL_read can emit control records (key-update acks)
                    // after the send side broke; they are dropped with the
                    // rest.
                    if (!self.send_broken) {
                        if (self.send_in_flight)
                            self.outgoing_ciphertext.writeAssumeCapacity(scratch[0..drained])
                        else
                            try self.outgoing_ciphertext.write(scratch[0..drained]);
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
