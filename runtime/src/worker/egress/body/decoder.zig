//! The worker's streaming decoder for a fetch body the gateway forwards still
//! encoded. The gateway sends HTTP/2 response bodies as they arrived (gzip,
//! deflate or br), so decompression spends CPU and memory inside the tenant
//! worker's cgroup rather than on the gateway's shared engine thread. A
//! decoder belongs to the source body of its fetch (`Body.decoder`) and runs
//! on the worker's VM thread. Its input is borrowed body-pool extents and its
//! output owned chunks appended to that body.
//!
//! An extent's release fires only once the decoder consumed all of it. The
//! release refills the gateway's HTTP/2 window, so releasing early would let
//! the origin send encoded bytes faster than the worker decodes them and
//! break end-to-end flow control. A partly consumed extent stays in `pending`
//! across watermark pauses and is released exactly once, on full consumption
//! or by `deinit`.
//!
//! The fetch head carries the decoded budget, the decoded watermark and the
//! compression-ratio guard, and this decoder enforces them. The gateway's
//! engine enforces the encoded byte budget before bytes reach the pool;
//! `encoded_bytes_seen` only feeds the ratio guard.

const std = @import("std");
const egress_core = @import("collo_egress_core");
const limits = @import("collo_limits");
const body_mod = @import("body.zig");
const chunk = @import("chunk.zig");

const decompress = egress_core.decompress;
const stream_pump = egress_core.stream_pump;

pub const Limits = stream_pump.Limits;
pub const Encoding = decompress.Encoding;

pub const Decoder = struct {
    decoder: decompress.StreamDecoder,
    /// Normalized at init (`Limits.normalized`).
    limits: Limits,
    encoded_bytes_seen: u64 = 0,
    decoded_bytes_seen: u64 = 0,
    pending: std.ArrayListUnmanaged(PendingExtent) = .empty,
    /// Latched by `finish`, so the resume path knows to run the trailer flush
    /// again after a decoded-watermark pause.
    end_seen: bool = false,
    /// The codec holds output it could not emit within the decoded
    /// watermark; drain again once the reader frees room.
    needs_output: bool = false,

    pub const PendingExtent = struct {
        borrowed: chunk.BorrowedChunk,
        offset: usize = 0,

        fn remaining(self: *const PendingExtent) []const u8 {
            return self.borrowed.bytes[self.offset..];
        }
    };

    /// A decoder for `encoding`, which must not be identity. Fails with
    /// `error.InvalidStreamPumpLimits` for a zero limit or as the codec's
    /// init does.
    pub fn init(encoding: Encoding, decoder_limits: Limits) !Decoder {
        std.debug.assert(encoding != .identity);
        const normalized = try decoder_limits.normalized();
        return .{
            .decoder = try decompress.StreamDecoder.init(encoding),
            .limits = normalized,
        };
    }

    /// Releases every pending extent, each exactly once, and tears down the
    /// codec. Safe after any error.
    pub fn deinit(self: *Decoder, allocator: std.mem.Allocator) void {
        for (self.pending.items) |extent|
            extent.borrowed.release.release();
        self.pending.deinit(allocator);
        self.decoder.deinit();
        self.* = undefined;
    }

    /// Takes `borrowed` whatever the outcome: it is queued in `pending`,
    /// released on full consumption or by `deinit`, or released here when it
    /// cannot be queued or is empty.
    pub fn pushBorrowed(
        self: *Decoder,
        allocator: std.mem.Allocator,
        body: *body_mod.Body,
        borrowed: chunk.BorrowedChunk,
    ) !void {
        self.encoded_bytes_seen +|= borrowed.bytes.len;
        if (borrowed.bytes.len == 0) {
            // An empty extent gives the codec nothing to consume, so its
            // offset could never advance; it refills no window either. The
            // gateway never publishes one (`gateway_runtime.handleBodyChunk`
            // refuses it), but a direct caller may pass one.
            borrowed.release.release();
            return self.drainPending(allocator, body);
        }
        self.pending.append(allocator, .{ .borrowed = borrowed }) catch |err| {
            borrowed.release.release();
            return err;
        };
        return self.drainPending(allocator, body);
    }

    /// Decodes queued extents toward the decoded watermark into `body`. It
    /// pauses, without error, once the watermark is reached, leaving partly
    /// consumed extents queued.
    pub fn drainPending(self: *Decoder, allocator: std.mem.Allocator, body: *body_mod.Body) !void {
        while (self.pending.items.len != 0 or self.needs_output) {
            if (self.decoder.finished) {
                // Encoded bytes after the end of the stream are invalid.
                if (self.pending.items.len != 0)
                    return error.InvalidCompressedResponse;
                self.needs_output = false;
                break;
            }

            const available = self.availableDecodedCapacity(body);
            if (available == 0)
                return;

            const input: []const u8 = if (self.pending.items.len != 0) self.pending.items[0].remaining() else "";
            var decoded = try self.decoder.pushToOwnedSliceLimited(
                allocator,
                input,
                self.remainingDecodedBudget(),
                available,
            );
            defer decoded.deinit(allocator);

            if (self.pending.items.len != 0 and decoded.consumed != 0) {
                const first = &self.pending.items[0];
                first.offset += decoded.consumed;
                std.debug.assert(first.offset <= first.borrowed.bytes.len);
                if (first.offset == first.borrowed.bytes.len) {
                    // Full consumption is the only release point on the data
                    // path; the release refills the gateway's window.
                    const release = first.borrowed.release;
                    _ = self.pending.orderedRemove(0);
                    release.release();
                }
            }

            self.needs_output = decoded.needs_output;
            try self.acceptDecodedBytes(decoded.bytes.len, decoded.needs_output);

            if (decoded.bytes.len == 0) {
                if (decoded.consumed == 0 and decoded.needs_output)
                    return;
                if (decoded.consumed == 0 and self.pending.items.len != 0)
                    return error.InvalidCompressedResponse;
                continue;
            }

            const owned = decoded.takeBytes();
            errdefer allocator.free(owned);
            try body.appendOwnedChunk(allocator, owned);
        }
    }

    /// Drains pending input, then runs the codec's trailer flush within the
    /// decoded watermark, and returns true only once the codec finished and
    /// every pending extent was consumed, and so released. Safe to call
    /// again: the resume path calls it after watermark pauses, and a
    /// finished decoder keeps answering true. Fails with
    /// `error.FetchResponseTruncated` when the stream ended early.
    pub fn finish(self: *Decoder, allocator: std.mem.Allocator, body: *body_mod.Body) !bool {
        self.end_seen = true;
        try self.drainPending(allocator, body);
        if (self.pending.items.len != 0)
            return false;

        if (self.decoder.finished)
            return true;
        const available = self.availableDecodedCapacity(body);
        if (available == 0)
            return false;
        var decoded = try self.decoder.finishToOwnedSliceLimited(
            allocator,
            self.remainingDecodedBudget(),
            available,
        );
        defer decoded.deinit(allocator);
        self.needs_output = decoded.needs_output;
        try self.acceptDecodedBytes(decoded.bytes.len, decoded.needs_output);
        if (decoded.bytes.len != 0) {
            const owned = decoded.takeBytes();
            errdefer allocator.free(owned);
            try body.appendOwnedChunk(allocator, owned);
        }
        if (decoded.finished)
            return true;
        if (decoded.needs_output)
            return false;
        return error.FetchResponseTruncated;
    }

    /// Decoded bytes the codec may emit now: the free watermark room, capped
    /// by the remaining decoded budget, and 1 once the budget is spent, so the
    /// codec still runs and a stream that ends exactly at the budget
    /// finishes while any further output fails the body.
    fn availableDecodedCapacity(self: *const Decoder, body: *const body_mod.Body) usize {
        const remaining_budget = self.remainingDecodedBudget();
        if (remaining_budget == 0)
            return 1;
        const queued = body.queuedBytes();
        if (queued >= self.limits.max_pending_decoded_bytes)
            return 0;
        return @min(self.limits.max_pending_decoded_bytes - queued, remaining_budget);
    }

    fn remainingDecodedBudget(self: *const Decoder) usize {
        return self.limits.max_decoded_bytes -| self.decoded_bytes_seen;
    }

    /// Charges decoded output to the decoded budget and the ratio guard.
    /// Fails with `error.FetchResponseTooLarge` past the budget, a codec that
    /// needs output when none is left included, or
    /// `error.FetchCompressionRatioExceeded`.
    fn acceptDecodedBytes(self: *Decoder, bytes: usize, needs_output: bool) !void {
        if (bytes == 0) {
            if (needs_output and self.remainingDecodedBudget() == 0)
                return error.FetchResponseTooLarge;
            return;
        }
        if (bytes > self.remainingDecodedBudget())
            return error.FetchResponseTooLarge;
        const proposed_decoded = self.decoded_bytes_seen + @as(u64, @intCast(bytes));
        if (self.encoded_bytes_seen >= self.limits.ratio_guard_min_encoded_bytes) {
            const allowed = self.encoded_bytes_seen *| self.limits.max_decoded_to_encoded_ratio;
            if (proposed_decoded > allowed)
                return error.FetchCompressionRatioExceeded;
        }
        self.decoded_bytes_seen = proposed_decoded;
    }
};

/// Decoder limits from the three fields a fetch head carries. A zero field
/// means the gateway set none and falls back to the default, so a half-filled
/// head never yields a decoder with a zero budget.
pub fn limitsFromHeadFields(
    max_decoded_body_bytes: u64,
    max_pending_decoded_bytes: u64,
    max_decoded_to_encoded_ratio: u64,
) Limits {
    // The default of the transport's `Config.max_response_body_bytes`.
    const max_decoded: usize = if (max_decoded_body_bytes == 0)
        limits.http_body.MATERIALIZED_BODY_BYTES_MAX
    else
        std.math.cast(usize, max_decoded_body_bytes) orelse std.math.maxInt(usize);
    const max_pending: usize = if (max_pending_decoded_bytes == 0)
        stream_pump.default_max_pending_decoded_bytes
    else
        std.math.cast(usize, max_pending_decoded_bytes) orelse std.math.maxInt(usize);
    const ratio: u64 = if (max_decoded_to_encoded_ratio == 0)
        stream_pump.default_max_decoded_to_encoded_ratio
    else
        max_decoded_to_encoded_ratio;
    return .{
        .max_decoded_bytes = max_decoded,
        .max_pending_decoded_bytes = max_pending,
        .max_decoded_to_encoded_ratio = ratio,
    };
}
