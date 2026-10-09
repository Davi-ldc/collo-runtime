//! The gateway's boundary from a response's wire bytes into its fetch body.
//! `Pump` decodes an HTTP/1 body; enforces the encoded budget, the decoded
//! budget, the decoded watermark and the compression-ratio guard; and decides
//! which appended chunk carries the continuation's resume credit.
//! `H2EncodedSink` appends HTTP/2 DATA payloads still encoded, each with its
//! flow-control credit, for the worker to decode. Both run on the transport
//! engine's owner thread, which must never block, so the `Available` paths
//! return `paused` at the watermark; the `Backpressured` paths block in
//! `Body.waitForDecodedCapacity` and suit only a producer that may block.
//! The capacity helpers at the end also serve `encoded_body.Decoder` in the
//! worker.

const std = @import("std");
const body_credit = @import("body_credit.zig");
const decompress = @import("decompress.zig");
const fetch_body = @import("fetch_body.zig");

/// Decoded bytes a body may queue before its producer pauses, unless the
/// transport configures otherwise. The gateway's body pump sizes its largest
/// single drain by it.
pub const default_max_pending_decoded_bytes: usize = 256 * 1024;
/// Largest decoded-to-encoded ratio the guard allows.
pub const default_max_decoded_to_encoded_ratio: u64 = 128;
/// Encoded bytes seen before the ratio guard starts checking.
pub const default_ratio_guard_min_encoded_bytes: u64 = 1024;

/// `consumed` input bytes were taken; with `paused`, the rest waits for
/// decoded capacity, which the resume credit signals.
pub const Http1AppendResult = struct {
    ready: bool = false,
    consumed: usize = 0,
    paused: bool = false,
};

pub const Http1FinishResult = struct {
    ready: bool = false,
    complete: bool = false,
};

pub const Limits = struct {
    max_decoded_bytes: usize,
    /// Maximum encoded bytes accepted from the network for this response.
    /// Zero means "inherit max_decoded_bytes" during normalization.
    max_encoded_bytes: usize = 0,
    max_pending_decoded_bytes: usize,
    max_decoded_to_encoded_ratio: u64 = default_max_decoded_to_encoded_ratio,
    ratio_guard_min_encoded_bytes: u64 = default_ratio_guard_min_encoded_bytes,

    pub fn init(max_decoded_bytes: usize) Limits {
        return .{
            .max_decoded_bytes = max_decoded_bytes,
            .max_pending_decoded_bytes = @min(max_decoded_bytes, default_max_pending_decoded_bytes),
        };
    }

    /// Validates the limits and fills defaults: a zero encoded budget
    /// inherits the decoded budget, and the watermark is capped at the
    /// decoded budget. Fails with `error.InvalidStreamPumpLimits` when the
    /// decoded budget, the watermark or the ratio is zero.
    pub fn normalized(self: Limits) !Limits {
        if (self.max_decoded_bytes == 0 or
            self.max_pending_decoded_bytes == 0 or
            self.max_decoded_to_encoded_ratio == 0)
            return error.InvalidStreamPumpLimits;
        var out = self;
        if (out.max_encoded_bytes == 0)
            out.max_encoded_bytes = out.max_decoded_bytes;
        out.max_pending_decoded_bytes = @min(out.max_pending_decoded_bytes, out.max_decoded_bytes);
        return out;
    }
};

/// The engine's entry point for HTTP/2 body bytes. Every DATA payload is
/// appended to the fetch body exactly as received, encoded or identity, with
/// its flow-control credit, and the worker decodes it in its own cgroup. Only
/// the encoded byte cap is enforced here; it protects the shared engine from
/// unbounded responses whatever the coding.
pub const H2EncodedSink = struct {
    /// Normalized transport encoded cap; stamped at response-head time,
    /// which always precedes DATA (body-before-headers is a protocol error).
    max_encoded_bytes: usize = 0,
    encoded_bytes_seen: u64 = 0,

    /// Appends `bytes`, allocated with `allocator`, with an `h2Data` credit
    /// for `encoded_bytes`. The sink owns `bytes` either way: queued on
    /// success, freed on error. Fails with
    /// `error.FetchResponseEncodedTooLarge` past the encoded cap, or with the
    /// errors of `Body.appendOwnedChunk`. Returns whether a reader became
    /// ready.
    pub fn appendH2DataOwned(
        self: *H2EncodedSink,
        allocator: std.mem.Allocator,
        body: *fetch_body.Body,
        credit_source_id: u64,
        stream_id: u32,
        bytes: []u8,
        encoded_bytes: usize,
        update_stream_window: bool,
    ) !bool {
        std.debug.assert(self.max_encoded_bytes != 0);
        var owned = bytes;
        errdefer if (owned.len != 0) allocator.free(owned);
        self.encoded_bytes_seen += encoded_bytes;
        if (self.encoded_bytes_seen > self.max_encoded_bytes)
            return error.FetchResponseEncodedTooLarge;
        // Empty final DATA frames still append: their credit is what
        // surfaces the stream's deferred `.end` at the engine.
        const credit = body_credit.h2Data(credit_source_id, stream_id, encoded_bytes, update_stream_window);
        const chunk = owned;
        const ready = try body.appendOwnedChunk(allocator, chunk, credit);
        owned = &.{};
        return ready;
    }
};

pub const Pump = struct {
    encoding: decompress.Encoding,
    decoder: ?decompress.StreamDecoder = null,
    limits: Limits,
    encoded_bytes_seen: u64 = 0,
    decoded_bytes_seen: u64 = 0,
    compressed_needs_output: bool = false,

    pub fn init(encoding: decompress.Encoding, max_decoded_bytes: usize) !Pump {
        return initWithLimits(encoding, Limits.init(max_decoded_bytes));
    }

    pub fn initWithLimits(encoding: decompress.Encoding, limits: Limits) !Pump {
        const normalized_limits = try limits.normalized();
        return .{
            .encoding = encoding,
            .decoder = if (encoding == .identity) null else try decompress.StreamDecoder.init(encoding),
            .limits = normalized_limits,
        };
    }

    pub fn deinit(self: *Pump, allocator: std.mem.Allocator) void {
        _ = allocator;
        if (self.decoder) |*decoder|
            decoder.deinit();
        self.* = undefined;
    }

    // Every append and finish bounds each decode step by the free watermark
    // space before it allocates. Checking the watermark only after decoding
    // a push against the whole remaining budget would let one push allocate
    // up to that budget, a transient decompression bomb.

    /// Appends `bytes`, decoding them when the body is encoded, and blocks
    /// while the watermark is full. The pump copies what it keeps, so the
    /// caller keeps `bytes`. Fails with the budget, ratio and decode errors,
    /// or with `error.FetchAborted` from `cancel_probe`.
    pub fn appendHttp1DataBackpressured(
        self: *Pump,
        allocator: std.mem.Allocator,
        body_pipe: anytype,
        bytes: []const u8,
        cancel_probe: anytype,
    ) !bool {
        try self.recordEncodedBytes(bytes.len);
        if (bytes.len == 0)
            return false;

        if (self.encoding == .identity) {
            try self.beforeAppendDecodedBackpressured(body_pipe, bytes.len, cancel_probe);
            const owned = try allocator.dupe(u8, bytes);
            errdefer allocator.free(owned);
            return try body_pipe.appendOwnedChunk(allocator, owned, .none);
        }

        const decoder = if (self.decoder) |*decoder|
            decoder
        else
            return error.InvalidCompressedResponse;
        _ = decoder;
        return try self.appendCompressedHttp1Backpressured(allocator, body_pipe, bytes, cancel_probe);
    }

    // The resume credit of the `Available` paths rides only on an append
    // that exhausts the decoded capacity it was offered. A credit is needed
    // for liveness only when the producer can pause next, and a credit on
    // every chunk would cost the owner a wasted unpark, step and park per
    // release. Liveness: capacity shrinks only through this pump's own
    // appends, so whenever a step sees zero capacity and pauses, even without
    // appending, the append that took capacity to zero carried the credit,
    // and its release wakes the continuation. Deciding from the queue depth
    // read before the append is conservative: a consumer draining in between
    // can only make the credit unnecessary, never missing.
    fn resumeCreditFor(exhausted_capacity: bool, resume_credit: body_credit.Handle) body_credit.Handle {
        return if (exhausted_capacity) resume_credit else .none;
    }

    /// Appends as much of `bytes` as the decoded capacity allows, without
    /// blocking. The pump copies what it takes, so the caller keeps `bytes`
    /// and offers the unconsumed rest again once the resume credit wakes it.
    /// Fails with `error.FetchResponseTooLarge` past the decoded budget,
    /// `error.FetchResponseEncodedTooLarge` past the encoded budget,
    /// `error.FetchCompressionRatioExceeded`, a decode error, or
    /// `error.OutOfMemory`.
    pub fn appendHttp1DataAvailable(
        self: *Pump,
        allocator: std.mem.Allocator,
        body_pipe: anytype,
        bytes: []const u8,
        resume_credit: body_credit.Handle,
    ) !Http1AppendResult {
        if (bytes.len == 0 and !self.compressed_needs_output)
            return .{};

        if (self.encoding == .identity) {
            const available = availableDecodedCapacityFor(
                body_pipe,
                self.limits.max_pending_decoded_bytes,
                self.remainingDecodedBudget(),
            );
            if (available == 0 and self.remainingDecodedBudget() == 0)
                return error.FetchResponseTooLarge;
            if (available == 0)
                return .{ .paused = true };
            const consumed = @min(bytes.len, available);
            try self.recordEncodedBytes(consumed);
            try self.acceptDecodedBytes(consumed);
            if (consumed == 0)
                return .{ .paused = bytes.len != 0 };
            const owned = try allocator.dupe(u8, bytes[0..consumed]);
            errdefer allocator.free(owned);
            const ready = try body_pipe.appendOwnedChunk(
                allocator,
                owned,
                resumeCreditFor(consumed == available, resume_credit),
            );
            return .{
                .ready = ready,
                .consumed = consumed,
                .paused = consumed < bytes.len,
            };
        }

        return try self.appendCompressedHttp1Available(allocator, body_pipe, bytes, resume_credit);
    }

    /// Capacity for the identity direct-read path, where the HTTP/1
    /// continuation reads straight into an allocation of the right size
    /// instead of copying out of its read buffer.
    pub const IdentityCapacity = union(enum) {
        /// Identity bytes an `appendHttp1IdentityOwned` can accept right now.
        available: usize,
        /// The pending watermark is full, so pause. A queued chunk carries
        /// the resume credit (see `resumeCreditFor`), so the pause ends.
        paused,
        /// The decoded budget is spent. The caller must not fail yet: a body
        /// that ends exactly at the budget is legal, so the next read goes
        /// through the buffered pending-input path, which tells a clean EOF
        /// from excess bytes.
        budget_exhausted,
    };

    pub fn identityCapacity(self: *const Pump, body_pipe: anytype) IdentityCapacity {
        std.debug.assert(self.encoding == .identity);
        if (self.remainingDecodedBudget() == 0)
            return .budget_exhausted;
        const available = availableDecodedCapacityFor(
            body_pipe,
            self.limits.max_pending_decoded_bytes,
            self.remainingDecodedBudget(),
        );
        if (available == 0)
            return .paused;
        return .{ .available = available };
    }

    /// Appends identity bytes the caller read straight into `owned`, an
    /// allocation sized by a prior `identityCapacity` probe; capacity can
    /// only grow between probe and append, because this pump is the body's
    /// only producer. Ownership follows `Body.appendOwnedChunk`: on success
    /// the body owns `owned`, on error the caller still does.
    pub fn appendHttp1IdentityOwned(
        self: *Pump,
        allocator: std.mem.Allocator,
        body_pipe: anytype,
        owned: []u8,
        resume_credit: body_credit.Handle,
    ) !Http1AppendResult {
        std.debug.assert(self.encoding == .identity);
        if (owned.len == 0)
            return .{};
        const available = availableDecodedCapacityFor(
            body_pipe,
            self.limits.max_pending_decoded_bytes,
            self.remainingDecodedBudget(),
        );
        std.debug.assert(owned.len <= available);
        try self.recordEncodedBytes(owned.len);
        try self.acceptDecodedBytes(owned.len);
        const ready = try body_pipe.appendOwnedChunk(
            allocator,
            owned,
            resumeCreditFor(owned.len == available, resume_credit),
        );
        return .{ .ready = ready, .consumed = owned.len, .paused = false };
    }

    /// Flushes the codec trailer within the decoded capacity and completes
    /// the body. `complete` false means call again once the resume credit
    /// wakes the continuation.
    pub fn finishHttp1Available(
        self: *Pump,
        allocator: std.mem.Allocator,
        body_pipe: anytype,
        resume_credit: body_credit.Handle,
    ) !Http1FinishResult {
        if (self.encoding != .identity)
            return try self.finishCompressedHttp1Available(allocator, body_pipe, resume_credit);
        const ready = body_pipe.complete();
        return .{ .ready = ready, .complete = true };
    }

    /// Flushes the codec trailer and completes the body, blocking while the
    /// watermark is full.
    pub fn finishBackpressured(self: *Pump, allocator: std.mem.Allocator, body_pipe: anytype, cancel_probe: anytype) !bool {
        if (self.encoding != .identity)
            return try self.finishCompressedHttp1Backpressured(allocator, body_pipe, cancel_probe);

        var ready = false;
        if (self.decoder) |*decoder| {
            var decoded = try decoder.finishToOwnedSlice(allocator, self.remainingDecodedBudget());
            errdefer allocator.free(decoded);
            try self.beforeAppendDecodedBackpressured(body_pipe, decoded.len, cancel_probe);
            if (decoded.len != 0) {
                ready = try body_pipe.appendOwnedChunk(allocator, decoded, .none);
                decoded = &.{};
            } else {
                allocator.free(decoded);
            }
        }
        return body_pipe.complete() or ready;
    }

    fn appendCompressedHttp1Backpressured(
        self: *Pump,
        allocator: std.mem.Allocator,
        body_pipe: anytype,
        bytes: []const u8,
        cancel_probe: anytype,
    ) !bool {
        var offset: usize = 0;
        var ready = false;
        while (offset < bytes.len or self.compressed_needs_output) {
            const decoder = if (self.decoder) |*decoder|
                decoder
            else
                return error.InvalidCompressedResponse;
            if (decoder.finished) {
                if (offset < bytes.len)
                    return error.InvalidCompressedResponse;
                self.compressed_needs_output = false;
                break;
            }

            var available = availableDecodedCapacityForActiveCodec(
                body_pipe,
                self.limits.max_pending_decoded_bytes,
                self.remainingDecodedBudget(),
            );
            while (available == 0) {
                try waitForDecodedCapacity(body_pipe, 1, self.limits.max_pending_decoded_bytes, cancel_probe);
                available = availableDecodedCapacityForActiveCodec(
                    body_pipe,
                    self.limits.max_pending_decoded_bytes,
                    self.remainingDecodedBudget(),
                );
            }

            var decoded = try decoder.pushToOwnedSliceLimited(
                allocator,
                bytes[offset..],
                self.remainingDecodedBudget(),
                available,
            );
            defer decoded.deinit(allocator);
            offset += decoded.consumed;
            self.compressed_needs_output = decoded.needs_output;
            try self.acceptDecodedBytesForCodec(decoded.bytes.len, decoded.needs_output);
            if (decoded.bytes.len != 0) {
                const owned = decoded.takeBytes();
                errdefer allocator.free(owned);
                ready = (try body_pipe.appendOwnedChunk(allocator, owned, .none)) or ready;
            }
            if (decoded.consumed == 0 and decoded.bytes.len == 0 and decoded.needs_output)
                continue;
            if (decoded.consumed == 0 and decoded.bytes.len == 0 and !decoded.needs_output and offset < bytes.len)
                return error.InvalidCompressedResponse;
        }
        return ready;
    }

    fn appendCompressedHttp1Available(
        self: *Pump,
        allocator: std.mem.Allocator,
        body_pipe: anytype,
        bytes: []const u8,
        resume_credit: body_credit.Handle,
    ) !Http1AppendResult {
        var offset: usize = 0;
        var ready = false;
        while (offset < bytes.len or self.compressed_needs_output) {
            const decoder = if (self.decoder) |*decoder|
                decoder
            else
                return error.InvalidCompressedResponse;
            if (decoder.finished) {
                if (offset < bytes.len)
                    return error.InvalidCompressedResponse;
                self.compressed_needs_output = false;
                break;
            }

            const available = availableDecodedCapacityForActiveCodec(
                body_pipe,
                self.limits.max_pending_decoded_bytes,
                self.remainingDecodedBudget(),
            );
            if (available == 0)
                return .{
                    .ready = ready,
                    .consumed = offset,
                    .paused = true,
                };

            var decoded = try decoder.pushToOwnedSliceLimited(
                allocator,
                bytes[offset..],
                self.remainingDecodedBudget(),
                available,
            );
            defer decoded.deinit(allocator);
            if (decoded.consumed != 0)
                try self.recordEncodedBytes(decoded.consumed);
            offset += decoded.consumed;
            self.compressed_needs_output = decoded.needs_output;
            try self.acceptDecodedBytesForCodec(decoded.bytes.len, decoded.needs_output);
            if (decoded.bytes.len != 0) {
                // The resume credit rides only on a decode that filled the
                // capacity it was offered, the only append after which a
                // later step can pause. It keys on the produced length, not
                // `needs_output`: a gzip member can end exactly at the
                // capacity boundary with `needs_output` false, and the next
                // step then pauses with nothing new appended.
                const chunk_credit = resumeCreditFor(decoded.bytes.len == available, resume_credit);
                const owned = decoded.takeBytes();
                errdefer allocator.free(owned);
                ready = (try body_pipe.appendOwnedChunk(allocator, owned, chunk_credit)) or ready;
            }
            if (decoded.consumed == 0 and decoded.bytes.len == 0 and decoded.needs_output)
                continue;
            if (decoded.consumed == 0 and decoded.bytes.len == 0 and !decoded.needs_output and offset < bytes.len)
                return error.InvalidCompressedResponse;
        }
        return .{
            .ready = ready,
            .consumed = offset,
            .paused = false,
        };
    }

    fn finishCompressedHttp1Backpressured(
        self: *Pump,
        allocator: std.mem.Allocator,
        body_pipe: anytype,
        cancel_probe: anytype,
    ) !bool {
        var ready = false;
        while (true) {
            const decoder = if (self.decoder) |*decoder|
                decoder
            else
                return body_pipe.complete() or ready;
            if (decoder.finished)
                return body_pipe.complete() or ready;

            var available = availableDecodedCapacityForActiveCodec(
                body_pipe,
                self.limits.max_pending_decoded_bytes,
                self.remainingDecodedBudget(),
            );
            while (available == 0) {
                try waitForDecodedCapacity(body_pipe, 1, self.limits.max_pending_decoded_bytes, cancel_probe);
                available = availableDecodedCapacityForActiveCodec(
                    body_pipe,
                    self.limits.max_pending_decoded_bytes,
                    self.remainingDecodedBudget(),
                );
            }

            var decoded = try decoder.finishToOwnedSliceLimited(
                allocator,
                self.remainingDecodedBudget(),
                available,
            );
            defer decoded.deinit(allocator);
            self.compressed_needs_output = decoded.needs_output;
            try self.acceptDecodedBytesForCodec(decoded.bytes.len, decoded.needs_output);
            if (decoded.bytes.len != 0) {
                const owned = decoded.takeBytes();
                errdefer allocator.free(owned);
                ready = (try body_pipe.appendOwnedChunk(allocator, owned, .none)) or ready;
            }
            if (decoded.finished)
                return body_pipe.complete() or ready;
            if (!decoded.needs_output)
                return error.FetchResponseTruncated;
        }
    }

    fn finishCompressedHttp1Available(
        self: *Pump,
        allocator: std.mem.Allocator,
        body_pipe: anytype,
        resume_credit: body_credit.Handle,
    ) !Http1FinishResult {
        var ready = false;
        while (true) {
            const decoder = if (self.decoder) |*decoder|
                decoder
            else {
                ready = body_pipe.complete() or ready;
                return .{ .ready = ready, .complete = true };
            };
            if (decoder.finished) {
                ready = body_pipe.complete() or ready;
                return .{ .ready = ready, .complete = true };
            }

            const available = availableDecodedCapacityForActiveCodec(
                body_pipe,
                self.limits.max_pending_decoded_bytes,
                self.remainingDecodedBudget(),
            );
            if (available == 0)
                return .{ .ready = ready, .complete = false };

            var decoded = try decoder.finishToOwnedSliceLimited(
                allocator,
                self.remainingDecodedBudget(),
                available,
            );
            defer decoded.deinit(allocator);
            self.compressed_needs_output = decoded.needs_output;
            try self.acceptDecodedBytesForCodec(decoded.bytes.len, decoded.needs_output);
            if (decoded.bytes.len != 0) {
                // The append path's capacity rule; a finished trailer flush
                // needs no resume.
                const chunk_credit = if (decoded.finished)
                    body_credit.Handle.none
                else
                    resumeCreditFor(decoded.bytes.len == available, resume_credit);
                const owned = decoded.takeBytes();
                errdefer allocator.free(owned);
                ready = (try body_pipe.appendOwnedChunk(allocator, owned, chunk_credit)) or ready;
            }
            if (decoded.finished) {
                ready = body_pipe.complete() or ready;
                return .{ .ready = ready, .complete = true };
            }
            if (decoded.needs_output)
                return .{ .ready = ready, .complete = false };
            return error.FetchResponseTruncated;
        }
    }

    fn recordEncodedBytes(self: *Pump, bytes: usize) !void {
        if (bytes > self.limits.max_encoded_bytes -| self.encoded_bytes_seen)
            return error.FetchResponseEncodedTooLarge;
        self.encoded_bytes_seen += bytes;
    }

    fn remainingDecodedBudget(self: *const Pump) usize {
        return self.limits.max_decoded_bytes -| self.decoded_bytes_seen;
    }

    fn beforeAppendDecodedBackpressured(self: *Pump, body_pipe: anytype, bytes: usize, cancel_probe: anytype) !void {
        if (bytes == 0)
            return;
        const proposed_decoded = try self.validateDecodedBytes(bytes);
        try waitForDecodedCapacity(body_pipe, bytes, self.limits.max_pending_decoded_bytes, cancel_probe);
        self.decoded_bytes_seen = proposed_decoded;
    }

    fn acceptDecodedBytes(self: *Pump, bytes: usize) !void {
        if (bytes == 0)
            return;
        self.decoded_bytes_seen = try self.validateDecodedBytes(bytes);
    }

    fn acceptDecodedBytesForCodec(self: *Pump, bytes: usize, needs_output: bool) !void {
        if (bytes == 0) {
            if (needs_output and self.remainingDecodedBudget() == 0)
                return error.FetchResponseTooLarge;
            return;
        }

        const proposed_decoded = try self.validateDecodedBytes(bytes);
        self.decoded_bytes_seen = proposed_decoded;
    }

    fn validateDecodedBytes(self: *const Pump, bytes: usize) !u64 {
        const proposed_decoded = try self.checkDecodedBudget(bytes);
        if (self.encoding != .identity and self.encoded_bytes_seen >= self.limits.ratio_guard_min_encoded_bytes) {
            const allowed = self.encoded_bytes_seen *| self.limits.max_decoded_to_encoded_ratio;
            if (proposed_decoded > allowed)
                return error.FetchCompressionRatioExceeded;
        }
        return proposed_decoded;
    }

    fn checkDecodedBudget(self: *const Pump, bytes: usize) !u64 {
        if (bytes > self.remainingDecodedBudget())
            return error.FetchResponseTooLarge;
        return self.decoded_bytes_seen + @as(u64, @intCast(bytes));
    }
};

/// The pipe's queued decoded bytes, or 0 for a pipe that does not report
/// them.
pub fn queuedDecodedBytes(body_pipe: anytype) usize {
    const pointer_info = switch (@typeInfo(@TypeOf(body_pipe))) {
        .pointer => |info| info,
        else => return 0,
    };
    if (!@hasDecl(pointer_info.child, "queuedDecodedBytes"))
        return 0;
    return body_pipe.queuedDecodedBytes();
}

/// Decoded bytes that may be appended now: the free watermark space, capped
/// by the remaining decoded budget.
pub fn availableDecodedCapacityFor(body_pipe: anytype, max_pending_decoded_bytes: usize, remaining_decoded_budget: usize) usize {
    const queued = queuedDecodedBytes(body_pipe);
    if (queued >= max_pending_decoded_bytes)
        return 0;
    return @min(max_pending_decoded_bytes - queued, remaining_decoded_budget);
}

/// As `availableDecodedCapacityFor`, but 1 once the budget is spent, so the
/// codec still runs: a stream that ends exactly at the budget finishes, and
/// any further output fails the body.
pub fn availableDecodedCapacityForActiveCodec(
    body_pipe: anytype,
    max_pending_decoded_bytes: usize,
    remaining_decoded_budget: usize,
) usize {
    if (remaining_decoded_budget == 0)
        return 1;
    return availableDecodedCapacityFor(body_pipe, max_pending_decoded_bytes, remaining_decoded_budget);
}

/// Waits through the pipe's own `waitForDecodedCapacity` when it has one; a
/// pipe without it fails with `error.FetchBodyDecodedQueueFull` when the
/// bytes do not fit.
fn waitForDecodedCapacity(
    body_pipe: anytype,
    bytes: usize,
    max_pending_decoded_bytes: usize,
    cancel_probe: anytype,
) !void {
    const pointer_info = switch (@typeInfo(@TypeOf(body_pipe))) {
        .pointer => |info| info,
        else => {
            const needed_capacity = @min(bytes, max_pending_decoded_bytes);
            if (queuedDecodedBytes(body_pipe) > max_pending_decoded_bytes -| needed_capacity)
                return error.FetchBodyDecodedQueueFull;
            return;
        },
    };
    if (@hasDecl(pointer_info.child, "waitForDecodedCapacity"))
        return try body_pipe.waitForDecodedCapacity(bytes, max_pending_decoded_bytes, cancel_probe);
    const needed_capacity = @min(bytes, max_pending_decoded_bytes);
    if (queuedDecodedBytes(body_pipe) > max_pending_decoded_bytes -| needed_capacity)
        return error.FetchBodyDecodedQueueFull;
}
