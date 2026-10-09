//! Turns what the transport engine produced for one fetch into packets for the worker that
//! asked: the response head, body chunk batches placed in the worker's body pool, body end and
//! error packets. It runs on the gateway's main loop thread, inside a shard's collection pass
//! (`Engine.pumpFetch` in `engine.zig`).
//!
//! The body drain is destructive: a drained chunk has left the fetch body, so a chunk drained
//! without room to publish it would be lost. The drain therefore reserves room in the worker's
//! body pool and completion ring for the largest chunk it can take before it takes one. Every
//! flow-control credit has one owner at a time (`PendingBatch`), and the credit of a published
//! chunk returns to the engine only when the worker releases the pool extent that holds the
//! chunk's last bytes.

const std = @import("std");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const os_process = @import("collo_os").process;

const active_fetch = @import("active_fetch.zig");
const body_credit = @import("collo_egress_client").body_credit;

/// Largest body chunk a single `drainReadyForPull` can return: the engine's
/// pending-decoded watermark, which the gateway never raises above its
/// default. The drain's preflight reserves this much so a drained chunk
/// always fits.
const max_single_drain_bytes: usize = @import("collo_egress_client").stream_pump.default_max_pending_decoded_bytes;

/// Payloads one `PendingBatch` holds before it flushes.
pub const body_chunk_batch_max: usize = 128;

comptime {
    std.debug.assert(body_chunk_batch_max <= ipc.egress.max_body_chunk_batch_count / 2);
}

/// Sends the response head, or the fetch's error packet, once the fetch's task is done, and arms
/// the first body pull after the head; a no-op before then and after the head went out. Fails
/// with what encoding, sending or arming the pull fails with. A worker that cannot take the
/// packet detaches the fetch instead of failing the call (`Fetch.sendPacketOrDetach`).
pub fn publishHeadIfReady(engine: anytype, fetch: *active_fetch.Fetch) !void {
    if (fetch.head_sent or fetch.terminal)
        return;

    fetch.task.mutex.lock();
    var task_locked = true;
    defer if (task_locked)
        fetch.task.mutex.unlock();
    if (!fetch.task.done)
        return;

    const result = fetch.task.result orelse {
        fetch.task.mutex.unlock();
        task_locked = false;
        // A canceled fetch still reports the meters of what the origin
        // delivered; zeros here would let a tenant read a response, abort it
        // before its end and escape the meters. The worker keeps the largest
        // value of each total, so a repeated total can only raise what it
        // recorded, never count bytes twice.
        try fetch.sendError(engine, "fetch canceled", fetch.egressMeters());
        fetch.terminal = true;
        return;
    };

    switch (result) {
        .success => |success| {
            var header_storage: [ipc.max_request_header_count]ipc.RequestHeader = undefined;
            const headers = prepareResponseHeaders(
                success.headers,
                &header_storage,
                engine.policy.max_response_headers,
                engine.policy.max_response_header_bytes,
            ) catch |err| {
                logResponseHeaderLimit(engine, fetch, success.headers.len, responseHeaderErrorMessage(err));
                fetch.task.mutex.unlock();
                task_locked = false;
                try fetch.sendError(engine, responseHeaderErrorMessage(err), fetch.egressMeters());
                fetch.terminal = true;
                return;
            };
            const bytes = ipc.encodeEgressFetchHeadInto(engine.scratch, .{
                .fetch_id = fetch.fetch_id,
                .body_id = fetch.body_id,
                .flags = if (success.redirected) ipc.egress_fetch_head_flag_redirected else 0,
                .status = success.status,
                .body_encoding = bodyEncodingForIpc(success.body_encoding),
                // The worker decodes a non-identity body in its own cgroup,
                // so the head carries the body's resolved decoded limit and
                // the worker enforces the bound the gateway's pump would. The
                // watermark and ratio stay zero, which the worker reads as
                // the stream-pump defaults the gateway also runs with
                // (`encoded_body.limitsFromHeadFields`).
                .max_decoded_body_bytes = fetch.body.maxDecodedBytes() orelse 0,
                .status_text = success.status_text,
                .url = success.url,
                .headers = headers,
                .ready_at_mono_ns = os_process.monotonicNowNsOrZero(),
            }) catch {
                logResponseHeaderLimit(engine, fetch, success.headers.len, "response head too large");
                fetch.task.mutex.unlock();
                task_locked = false;
                try fetch.sendError(engine, "response head too large", fetch.egressMeters());
                fetch.terminal = true;
                return;
            };
            fetch.task.mutex.unlock();
            task_locked = false;
            try fetch.sendPacketOrDetach(engine, bytes);
            if (fetch.terminal)
                return;
            fetch.head_sent = true;
            try fetch.ensurePullArmed(engine);
        },
        .failure => |failure| {
            const message = failure.message;
            fetch.task.mutex.unlock();
            task_locked = false;
            // The error carries the meters the engine folded into the body
            // before the failure.
            const meters = fetch.egressMeters();
            const bytes = try ipc.encodeEgressFetchErrorInto(engine.scratch, .{
                .fetch_id = fetch.fetch_id,
                .body_id = fetch.body_id,
                .message = message,
                .billed_sent_total = meters.billed_sent,
                .billed_received_total = meters.billed_received,
                .cost_total = meters.cost,
                .ready_at_mono_ns = os_process.monotonicNowNsOrZero(),
            });
            try fetch.sendPacketOrDetach(engine, bytes);
            fetch.terminal = true;
        },
    }
}

/// Maps the transport's body coding onto the wire enum here, at the IPC
/// boundary, so the egress client never depends on IPC types.
fn bodyEncodingForIpc(encoding: anytype) ipc.BodyEncoding {
    return switch (encoding) {
        .identity => .identity,
        .gzip => .gzip,
        .deflate => .deflate,
        .br => .br,
    };
}

/// Publishes what the fetch's body has ready, as far as the worker's pressure, body pool and
/// completion ring allow, then body end once the body completes or the error packet once it
/// fails. Call it only after the head went out. When it returns with the fetch not terminal, the
/// rest waits for the next wake.
pub fn drainBody(engine: anytype, fetch: *active_fetch.Fetch) !void {
    if (fetch.terminal)
        return;
    if (fetch.body_end_sent) {
        // Everything was published and the end signal went out; the fetch
        // only waits for the worker to return its outstanding extents (the
        // release path retires it). Draining again would send body end again.
        fetch.terminal = fetch.outstanding_extents == 0;
        return;
    }

    // Drained chunks collect here and publish as one pool transaction and
    // one ring packet per flush rather than one per chunk, which on HTTP/2
    // would be one per DATA frame. The deferred deinit runs on every exit,
    // error paths included, and is what releases each staged credit exactly
    // once (`PendingBatch`).
    var batch = PendingBatch{};
    defer batch.deinit(engine, fetch);

    // Credits released right away collect across the whole drain pass, so
    // the engine gets one `body_credit` message, and its owner thread one
    // wake, per source and stream instead of one per drained chunk
    // (`active_fetch.CreditBatch`). The deferred flush runs on every exit,
    // so no path strands an ack. A zero-byte ack still gets its own message,
    // and delivering it is what surfaces the stream's deferred end.
    var credit_batch = active_fetch.CreditBatch{};
    defer credit_batch.flush(engine, fetch.worker_session_id);

    while (!fetch.terminal) {
        // One pressure probe per drained chunk, reused by every check below.
        const pressure = engine.workerPressure(fetch.worker_session_id);
        if (pressure.pause_pulls)
            break;
        fetch.ensurePullArmedWithPressure(pressure) catch |err| {
            batch.flush(engine, fetch, 0) catch |flush_err|
                std.log.debug("egress body batch flush failed during pull-arm unwind: {s}", .{@errorName(flush_err)});
            return err;
        };

        // The drain below is destructive: each `drainReadyForPull` takes one
        // engine chunk out of the body, as large as `max_single_drain_bytes`
        // on HTTP/1 and at most one DATA frame on HTTP/2, which the client's
        // SETTINGS_MAX_FRAME_SIZE (`h2.default_max_frame_size`) bounds. The pool and
        // the completion ring must hold that worst case on top of everything
        // drained but not yet published: a drained chunk the pool cannot take
        // is lost, and since a fragmented pool fans a chunk out into one ring
        // descriptor per pool block, a ring that fills after the drain loses
        // the drained bytes too. Bytes left queued pause the stream's stall
        // clock and keep its HTTP/2 credit held, and the worker's next pool
        // release wakes this shard again (`drainWorkerPoolReleases` in
        // `runtime/body_release_flow.zig`).
        const drain_quantum = @max(engine.policy.max_body_chunk_bytes, max_single_drain_bytes);
        const reserve_blocks = batch.pending_blocks + poolBlocksForBytes(drain_quantum);
        const pool_fits =
            pressure.pool_free_bytes / ipc.egress_shared.body_pool_block_size >= reserve_blocks;
        const ring_fits =
            pressure.completion_ring_free_bytes >= worstCaseBatchPacketBytes(reserve_blocks);
        if (!pool_fits or !ring_fits) {
            if (batch.isEmpty())
                return;
            // Publish what was already drained, then probe again, so the
            // drain never takes more than the pool and ring can absorb.
            try batch.flush(engine, fetch, 0);
            if (fetch.terminal)
                return;
            continue;
        }

        var drain = fetch.body.drainReadyForPull(engine.allocator) catch |err| {
            batch.flush(engine, fetch, 0) catch |flush_err|
                std.log.debug("egress body batch flush failed during drain unwind: {s}", .{@errorName(flush_err)});
            return err;
        };
        defer drain.deinit(engine.allocator);
        if (drain.waiter == null and !drain.bytes.isPresent() and !drain.done and !drain.failed and drain.credits.slice().len == 0)
            break;
        if (drain.waiter != null)
            fetch.pull_armed = false;

        if (drain.failed) {
            for (drain.credits.slice()) |credit|
                credit_batch.add(engine, fetch.worker_session_id, credit);
            // Chunks drained earlier still go out before the terminal error:
            // their extents are already accounted and the worker discards in
            // order.
            try batch.flush(engine, fetch, 0);
            if (fetch.terminal)
                return;
            const message = fetch.body.failureMessage() orelse "fetch body failed";
            try fetch.sendError(engine, message, fetch.egressMeters());
            fetch.terminal = true;
            return;
        }

        if (drain.bytes.isPresent()) {
            const bytes = drain.bytes.bytes();
            if (bytes.len == 0) {
                // An empty chunk, such as the zero-byte DATA frame some
                // origins send to carry END_STREAM, has no pool extent for its
                // credits to ride, and a zero-byte credit is what surfaces the
                // stream's deferred end. The credits release now; staged on an
                // extent that never exists, they would be dropped and the
                // fetch would hang until its deadline. The pass's credit
                // flush still sends a lone zero-byte credit as its own
                // message.
                for (drain.credits.slice()) |credit|
                    credit_batch.add(engine, fetch.worker_session_id, credit);
            } else {
                // A drain returns at most one non-empty chunk, after the
                // credits of any zero-byte chunks queued ahead of it
                // (`drainReadyForPull` in `egress/core/body_settlement.zig`).
                // The chunk's own credit, the last one, rides the final
                // payload, so it releases only when the worker returns the
                // extent holding the chunk's last bytes. The earlier credits
                // belong to chunks with no extent and release now; the
                // stream's receive window still bounds what the origin sends
                // next.
                var retained_credit: body_credit.Handle = .none;
                for (drain.credits.slice()) |credit| {
                    if (credit.isNone())
                        continue;
                    if (!retained_credit.isNone())
                        credit_batch.add(engine, fetch.worker_session_id, retained_credit);
                    retained_credit = credit;
                }
                // The batch takes the drained bytes, so the drain's deinit
                // must not free them. A gateway body never holds borrowed
                // bytes; a borrowed lease means an invariant between layers
                // broke, and `error.InvalidFetchBodyStorage` is fatal to the
                // shard (`isFetchDemotableError` in `engine.zig`).
                var lease = drain.takeBytes();
                const owned_bytes = switch (lease) {
                    .owned => |owned| owned,
                    .empty => unreachable,
                    .borrowed => {
                        lease.deinit(engine.allocator);
                        return error.InvalidFetchBodyStorage;
                    },
                };
                try batch.appendChunk(
                    engine,
                    fetch,
                    owned_bytes,
                    retained_credit,
                    workerBodyChunkBytesMax(engine, pressure),
                );
                if (fetch.terminal)
                    return;
            }
        } else {
            for (drain.credits.slice()) |credit|
                credit_batch.add(engine, fetch.worker_session_id, credit);
        }

        if (drain.done) {
            try batch.flush(engine, fetch, 0);
            if (fetch.terminal)
                return;
            try fetch.sendBodyEnd(engine);
            fetch.body_end_sent = true;
            fetch.terminal = fetch.outstanding_extents == 0;
            return;
        }
    }

    try batch.flush(engine, fetch, 0);
}

/// Body chunks accumulated across `drainReadyForPull` calls. Payload entries
/// point into the owned drained buffers, and one buffer backs several entries
/// when it is split at the worker's chunk size. A buffer is freed once its
/// entries are published, since the pool then holds the bytes.
///
/// A drained credit has exactly one owner at every moment: the caller until
/// `appendChunk` stages it in a payload slot, the slot until `flush`
/// publishes it, and then the worker's extent ledger, where the worker's
/// release of the extent is the credit's ack. `flush` clears the slots only
/// after a successful hand-off, so `deinit`'s sweep over the remaining slots
/// releases every staged but unpublished credit exactly once, whichever error
/// path dropped the batch. A flush that detaches the fetch is the one
/// asymmetry: it drops its slots' credits with the canceled stream, whose
/// reset returns them to the HTTP/2 connection window
/// (`Connection.cancelStream`), while the sweep would release them. Both are
/// safe because the engine treats a release for a reset or retired stream as
/// a no-op.
///
/// Public for the tests in `egress/tests/gateway/`; only `drainBody` uses it.
pub const PendingBatch = struct {
    payloads: [body_chunk_batch_max]active_fetch.BodyChunkPayload = undefined,
    payload_count: usize = 0,
    owned: [body_chunk_batch_max][]u8 = undefined,
    owned_count: usize = 0,
    /// Pool blocks, and so ring descriptors, the accumulated payloads take
    /// when published at worst; the drain's preflight adds the next drain's
    /// worst case to it.
    pending_blocks: usize = 0,

    pub fn isEmpty(self: *const PendingBatch) bool {
        return self.payload_count == 0;
    }

    /// Releases every credit still staged in a payload slot (a failed flush
    /// left them; see the struct doc) and frees the drained buffers. Runs on
    /// every drainBody exit, so no error path can strand a credit or leak a
    /// buffer.
    pub fn deinit(self: *PendingBatch, engine: anytype, fetch: *active_fetch.Fetch) void {
        for (self.payloads[0..self.payload_count]) |payload| {
            if (!payload.credit.isNone())
                fetch.releaseImmediateCredits(engine, &.{payload.credit});
        }
        for (self.owned[0..self.owned_count]) |buffer|
            engine.allocator.free(buffer);
        self.* = undefined;
    }

    /// Takes ownership of `bytes` (one whole drained engine chunk), splits it
    /// at the worker chunk cap, and rides `credit` on the final split so it
    /// releases only when the worker returns the extent holding the chunk's
    /// last bytes. Flushes mid-chunk when the payload array fills.
    pub fn appendChunk(
        self: *PendingBatch,
        engine: anytype,
        fetch: *active_fetch.Fetch,
        bytes: []u8,
        credit: body_credit.Handle,
        chunk_bytes_max: usize,
    ) !void {
        var batch_owns_bytes = false;
        var credit_staged = false;
        errdefer {
            if (!batch_owns_bytes)
                engine.allocator.free(bytes);
            // Until the credit is staged in a payload slot the deinit sweep
            // cannot see it, so any failure here releases it. That includes
            // a mid-chunk flush that fails after the batch took the bytes but
            // before the final split staged the credit.
            if (!credit_staged and !credit.isNone())
                fetch.releaseImmediateCredits(engine, &.{credit});
        }

        if (self.payload_count == self.payloads.len or self.owned_count == self.owned.len) {
            try self.flush(engine, fetch, 0);
            if (fetch.terminal) {
                engine.allocator.free(bytes);
                if (!credit.isNone())
                    fetch.releaseImmediateCredits(engine, &.{credit});
                return;
            }
        }

        self.owned[self.owned_count] = bytes;
        self.owned_count += 1;
        batch_owns_bytes = true;
        var offset: usize = 0;
        while (offset < bytes.len) {
            if (self.payload_count == self.payloads.len) {
                // Mid-chunk flush: the remaining tail still references this
                // chunk's buffer, so retain it.
                try self.flush(engine, fetch, 1);
                if (fetch.terminal) {
                    if (!credit_staged and !credit.isNone())
                        fetch.releaseImmediateCredits(engine, &.{credit});
                    return;
                }
            }
            const end = @min(offset + chunk_bytes_max, bytes.len);
            const payload_credit: body_credit.Handle = if (end == bytes.len) credit else .none;
            const meters = fetch.egressMeters();
            self.payloads[self.payload_count] = .{
                .bytes = bytes[offset..end],
                .billed_sent_total = meters.billed_sent,
                .billed_received_total = meters.billed_received,
                .cost_total = meters.cost,
                .credit = payload_credit,
            };
            if (!payload_credit.isNone())
                credit_staged = true;
            self.pending_blocks += poolBlocksForBytes(end - offset);
            self.payload_count += 1;
            offset = end;
        }
    }

    /// Publishes everything accumulated as one batch, then frees the drained
    /// buffers except the trailing `retain_owned` (a chunk still being
    /// split). When the fetch detaches, nothing is published and the bytes
    /// drop with the canceled stream. On error the slots and buffers stay:
    /// the deinit sweep owns the credits of a failed publish, and every
    /// caller returns the error instead of flushing again.
    pub fn flush(
        self: *PendingBatch,
        engine: anytype,
        fetch: *active_fetch.Fetch,
        retain_owned: usize,
    ) !void {
        if (self.payload_count != 0) {
            try fetch.sendBodyChunkBatchOrDetach(engine, self.payloads[0..self.payload_count]);
            // The publish handed every staged credit onward, to the worker's
            // extents or, on detach, to the canceled stream. Zeroing the
            // count here is what keeps the deinit sweep from releasing them
            // again.
            self.payload_count = 0;
            self.pending_blocks = 0;
        }
        const keep = @min(retain_owned, self.owned_count);
        const release_count = self.owned_count - keep;
        for (self.owned[0..release_count]) |buffer|
            engine.allocator.free(buffer);
        std.mem.copyForwards([]u8, self.owned[0..keep], self.owned[release_count..self.owned_count]);
        self.owned_count = keep;
    }
};

fn poolBlocksForBytes(bytes_len: usize) usize {
    const block = ipc.egress_shared.body_pool_block_size;
    return (bytes_len + block - 1) / block;
}

/// The ring's per-packet framing in the worst-case batch size below. The
/// ring's frame header (`FrameHeader` in `ipc/egress_shared/packet_ring.zig`) is 8 bytes;
/// the margin keeps this module independent of the ring's private layout.
const ring_packet_overhead_bytes: usize = 16;

/// Completion-ring bytes one batch publication can need in the worst case:
/// the encoded packet for one descriptor per pool block, plus the framing.
fn worstCaseBatchPacketBytes(descriptor_count: usize) usize {
    return @sizeOf(ipc.EgressBodyChunkBatchHeader) +
        descriptor_count * @sizeOf(ipc.EgressBodyChunkBatchDescriptor) +
        ring_packet_overhead_bytes;
}

fn workerBodyChunkBytesMax(engine: anytype, pressure: anytype) usize {
    if (pressure.max_body_chunk_bytes == 0)
        return engine.policy.max_body_chunk_bytes;
    return @max(@as(usize, 1), @min(engine.policy.max_body_chunk_bytes, pressure.max_body_chunk_bytes));
}

fn prepareResponseHeaders(
    headers: []const bindings.NameValuePair,
    storage: *[ipc.max_request_header_count]ipc.RequestHeader,
    max_headers: usize,
    max_header_bytes: usize,
) ![]const ipc.RequestHeader {
    if (headers.len > @min(storage.len, max_headers))
        return error.TooManyResponseHeaders;

    var total: usize = 0;
    for (headers, 0..) |header, index| {
        const name = bindings.rawStringSlice(header.name);
        const value = bindings.rawStringSlice(header.value);
        if (total > max_header_bytes or name.len > max_header_bytes - total)
            return error.ResponseHeadersTooLarge;
        total += name.len;
        if (total > max_header_bytes or value.len > max_header_bytes - total)
            return error.ResponseHeadersTooLarge;
        total += value.len;
        storage[index] = .{
            .name = name,
            .value = value,
        };
    }
    return storage[0..headers.len];
}

fn responseHeaderErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.TooManyResponseHeaders => "too many response headers",
        error.ResponseHeadersTooLarge => "response headers too large",
        else => "invalid response headers",
    };
}

fn logResponseHeaderLimit(
    engine: anytype,
    fetch: *const active_fetch.Fetch,
    header_count: usize,
    message: []const u8,
) void {
    std.log.warn(
        "egress gateway response head rejected session={d} fetch_id={d} body_id={d} header_count={d} max_headers={d} max_header_bytes={d}: {s}",
        .{
            fetch.worker_session_id,
            fetch.fetch_id,
            fetch.body_id,
            header_count,
            engine.policy.max_response_headers,
            engine.policy.max_response_header_bytes,
            message,
        },
    );
}
