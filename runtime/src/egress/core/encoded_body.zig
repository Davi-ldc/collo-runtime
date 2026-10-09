//! The worker's streaming decoder for fetch bodies that the gateway forwards
//! still encoded. The gateway sends HTTP/2 response bodies as they arrived
//! (gzip, deflate or br), so decompression spends CPU inside the tenant
//! worker's cgroup rather than on the gateway's shared engine thread. A
//! decoder runs on the worker's event loop thread. Input arrives as borrowed
//! body-pool extents (`fetch_body.BorrowedChunk`), and decoded output goes to
//! the body as allocator-owned chunks with credit `.none`.
//!
//! An extent's release fires only once the decoder has consumed all of it.
//! The release refills the gateway's HTTP/2 window, so releasing early would
//! let the origin send encoded bytes faster than the worker decodes them and
//! break end-to-end flow control. A partly consumed extent stays in `pending`
//! across watermark pauses and is released exactly once, on full consumption
//! or by `deinit`. `stream_pump.Pump` is not reused: it copies its input and
//! attaches the engine's resume credit to the chunks it queues, while this
//! input is borrowed memory whose release, after full consumption, is the
//! flow-control signal.
//!
//! The fetch head carries the decoded budget (`max_decoded_bytes`), the
//! decoded watermark (`max_pending_decoded_bytes`) and the compression-ratio
//! guard, and this decoder enforces them. The gateway's engine enforces the
//! encoded byte budget before bytes reach the pool
//! (`stream_pump.H2EncodedSink`); `encoded_bytes_seen` only feeds the ratio
//! guard.

const std = @import("std");
const decompress = @import("decompress.zig");
const fetch_body = @import("fetch_body.zig");
const collo_limits = @import("collo_limits");
const stream_pump = @import("stream_pump.zig");

pub const Decoder = struct {
    decoder: decompress.StreamDecoder,
    /// Normalized at init; see `limitsFromHeadFields` for head-driven setup.
    limits: stream_pump.Limits,
    encoded_bytes_seen: u64 = 0,
    decoded_bytes_seen: u64 = 0,
    pending: std.ArrayListUnmanaged(PendingExtent) = .empty,
    /// Latched by `finish`; lets the resume path know it must re-run the
    /// trailer flush after a decoded-watermark pause.
    end_seen: bool = false,
    /// The codec has buffered output it could not emit within the decoded
    /// watermark; drain again once the consumer frees capacity.
    needs_output: bool = false,

    pub const PendingExtent = struct {
        borrowed: fetch_body.BorrowedChunk,
        offset: usize = 0,

        fn remaining(self: *const PendingExtent) []const u8 {
            return self.borrowed.bytes[self.offset..];
        }
    };

    pub const FinishResult = struct {
        ready: bool,
        complete: bool,
    };

    /// A decoder for `encoding`, which must not be identity. Fails with
    /// `error.InvalidStreamPumpLimits` for a zero limit,
    /// `error.UnsupportedCompressionMethod` when the codec's library cannot
    /// be loaded, or `error.OutOfMemory`.
    pub fn init(encoding: decompress.Encoding, limits: stream_pump.Limits) !Decoder {
        std.debug.assert(encoding != .identity);
        const normalized_limits = try limits.normalized();
        return .{
            .decoder = try decompress.StreamDecoder.init(encoding),
            .limits = normalized_limits,
        };
    }

    /// Releases every pending extent (each exactly once) and tears down the
    /// codec. Safe after errors: extents not yet fully consumed are still
    /// queued and get released here.
    pub fn deinit(self: *Decoder, allocator: std.mem.Allocator) void {
        for (self.pending.items) |extent|
            extent.borrowed.release.release();
        self.pending.deinit(allocator);
        self.decoder.deinit();
        self.* = undefined;
    }

    /// Whether input or codec output still waits for decoded capacity.
    pub fn hasPendingEncoded(self: *const Decoder) bool {
        return self.pending.items.len != 0 or self.needs_output;
    }

    /// Takes `borrowed` whatever the outcome: the extent is queued in
    /// `pending`, to be released on full consumption or by `deinit`, or
    /// released here when it cannot be queued. The caller must never release
    /// it afterwards. Returns true when the body became ready for a waiter.
    pub fn pushBorrowed(
        self: *Decoder,
        allocator: std.mem.Allocator,
        body: *fetch_body.Body,
        borrowed: fetch_body.BorrowedChunk,
    ) !bool {
        // Feeds the ratio guard only; the engine enforces the encoded byte
        // budget before bytes reach the pool.
        self.encoded_bytes_seen +|= borrowed.bytes.len;
        if (borrowed.bytes.len == 0) {
            // An empty extent gives the codec nothing to consume, so its
            // offset could never advance and it would wedge the drain. It
            // refills no window either, so it is released at once.
            borrowed.release.release();
            return self.drainPending(allocator, body);
        }
        self.pending.append(allocator, .{ .borrowed = borrowed }) catch |err| {
            borrowed.release.release();
            return err;
        };
        return self.drainPending(allocator, body);
    }

    /// Decodes queued extents toward the decoded watermark. Returns true when
    /// the body became ready for a waiter; pauses (without error) once the
    /// watermark is hit, leaving partially consumed extents queued and
    /// unreleased.
    pub fn drainPending(
        self: *Decoder,
        allocator: std.mem.Allocator,
        body: *fetch_body.Body,
    ) !bool {
        var ready = false;
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
                return ready;

            const input: []const u8 = if (self.pending.items.len != 0)
                self.pending.items[0].remaining()
            else
                "";
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
                    // path; this release, a write to the pool release queue,
                    // refills the HTTP/2 window.
                    const release = first.borrowed.release;
                    _ = self.pending.orderedRemove(0);
                    release.release();
                }
            }

            self.needs_output = decoded.needs_output;
            try self.acceptDecodedBytes(decoded.bytes.len, decoded.needs_output);

            if (decoded.bytes.len == 0) {
                if (decoded.consumed == 0 and decoded.needs_output)
                    return ready;
                if (decoded.consumed == 0 and self.pending.items.len != 0)
                    return error.InvalidCompressedResponse;
                continue;
            }

            const owned = decoded.takeBytes();
            errdefer allocator.free(owned);
            ready = (try body.appendOwnedChunk(allocator, owned, .none)) or ready;
        }
        return ready;
    }

    /// Drains pending input, then runs the codec trailer flush within the
    /// decoded watermark. `complete` is true only once the codec finished
    /// and every pending extent was consumed, and so released. Safe to call
    /// repeatedly: the resume path calls it again after watermark pauses,
    /// and a finished decoder keeps returning `complete`. Fails with
    /// `error.FetchResponseTruncated` when the stream ended early.
    pub fn finish(
        self: *Decoder,
        allocator: std.mem.Allocator,
        body: *fetch_body.Body,
    ) !FinishResult {
        self.end_seen = true;
        var ready = try self.drainPending(allocator, body);
        if (self.pending.items.len != 0)
            return .{ .ready = ready, .complete = false };

        while (true) {
            if (self.decoder.finished)
                return .{ .ready = ready, .complete = true };
            const available = self.availableDecodedCapacity(body);
            if (available == 0)
                return .{ .ready = ready, .complete = false };
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
                ready = (try body.appendOwnedChunk(allocator, owned, .none)) or ready;
            }
            if (decoded.finished)
                return .{ .ready = ready, .complete = true };
            if (decoded.needs_output)
                return .{ .ready = ready, .complete = false };
            return error.FetchResponseTruncated;
        }
    }

    fn availableDecodedCapacity(self: *const Decoder, body: *fetch_body.Body) usize {
        return stream_pump.availableDecodedCapacityForActiveCodec(
            body,
            self.limits.max_pending_decoded_bytes,
            self.remainingDecodedBudget(),
        );
    }

    fn remainingDecodedBudget(self: *const Decoder) usize {
        return self.limits.max_decoded_bytes -| self.decoded_bytes_seen;
    }

    /// Charges decoded output to the decoded budget and the compression-ratio
    /// guard, by the rules of `stream_pump.Pump.acceptDecodedBytesForCodec`.
    /// Fails with `error.FetchResponseTooLarge` past the budget, including a
    /// codec that needs output when none is left, or
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

/// Builds decoder limits from the three u64s carried by the fetch head.
/// Zeroed fields mean "not provisioned by the gateway" and fall back to the
/// defaults, so a half-filled head can never produce a zero-budget decoder
/// (`Limits.normalized()` rejects explicit zeros instead of defaulting them).
pub fn limitsFromHeadFields(
    max_decoded_body_bytes: u64,
    max_pending_decoded_bytes: u64,
    max_decoded_to_encoded_ratio: u64,
) stream_pump.Limits {
    // The same default as the transport's `Config.max_response_body_bytes`.
    const max_decoded: usize = if (max_decoded_body_bytes == 0)
        collo_limits.http_body.MATERIALIZED_BODY_BYTES_MAX
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
