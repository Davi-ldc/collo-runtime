//! Turns what a shard's engine produced for one fetch into packets for the worker that asked: the
//! response head, body chunk batches placed in the worker's body pool, and the fetch's end, which
//! `fetch_flow.zig` writes as body end or an error packet. It runs on the gateway's loop thread,
//! inside a shard's collection pass or a session's rescan (`shard_flow.zig`, `session_flow.zig`).
//!
//! A pull from the response queue is destructive: a chunk pulled without room to publish it
//! would be lost. The drain therefore checks the worker's body pool and completion ring for the
//! largest chunk a pull can return, on top of what it holds unpublished, before it pulls. A drain
//! that finds no room stops with the queue armed: the worker's next release of pool extents
//! brings the fetch back (`release_flow.zig`), a session whose ring lacked room stays watched
//! until the ring has room (`session_flow.awaitRingRoom`), and a worker that stops reading its
//! completion ring loses its session (`session_flow.zig`). A head waits for ring room the same
//! way (`session_flow.queueHead`). Every flow-control credit has one
//! owner at a time (`PendingBatch`), and the credit of a published chunk returns to the engine
//! only when the worker releases the pool extent that holds the chunk's last bytes.

const std = @import("std");
const ipc = @import("collo_ipc");
const os_process = @import("collo_os").process;

const egress = @import("collo_egress_client");
const credit_batch = @import("../credit_batch.zig");
const engine_mod = @import("../engine.zig");
const fetch_table = @import("../fetch_table.zig");
const publisher = @import("../publisher.zig");
const sessions_mod = @import("../sessions.zig");
const fetch_flow = @import("fetch_flow.zig");
const Gateway = @import("root.zig").Gateway;
const session_flow = @import("session_flow.zig");

const body_credit = egress.body_credit;
const task_model = egress.task;
const Session = sessions_mod.Session;

/// The largest chunk one pull can return: the engine's pending-decoded watermark, which the
/// gateway never raises above its default. The drain's room check reserves this much so a pulled
/// chunk always fits.
const max_single_pull_bytes: usize = egress.stream_pump.default_max_pending_decoded_bytes;

/// Payloads one `PendingBatch` holds before it flushes.
const body_chunk_batch_max: usize = 128;

/// The bytes the room check reserves for one more pull: the larger of a published chunk and the
/// largest pull.
fn drainQuantum(gateway: *const Gateway) usize {
    return @max(gateway.policy.max_body_chunk_bytes, max_single_pull_bytes);
}

/// Completion-ring bytes a drain that holds nothing unpublished needs before it pulls. A session
/// whose drain stopped short of ring room is pumped again once its ring has this much free
/// (`session_flow.zig`).
pub fn drainRingReserveBytes(gateway: *const Gateway) usize {
    return publisher.worstCaseBatchPacketBytes(publisher.blockCountForBytes(drainQuantum(gateway)));
}

comptime {
    std.debug.assert(body_chunk_batch_max <= ipc.egress.max_body_chunk_batch_count / 2);
}

/// Publishes what the running fetch `handle` names has ready: its head once its task is done,
/// then as much of its body as the worker's pool and ring take, then its end. A fetch that ends
/// here goes through `fetch_flow.end`. Fails only with errors `shard_flow.zig` sorts into the
/// fetch's and the shard's.
pub fn pump(gateway: *Gateway, handle: fetch_table.Handle) !void {
    try publishHeadIfReady(gateway, handle);
    const fetch = gateway.fetches.get(handle) orelse return;
    if (fetch.ending == null and fetch.head_sent)
        try drainBody(gateway, handle);
}

/// Sends the response head, or ends the fetch with its error, once the fetch's task is done, and
/// arms the response queue after the head; a no-op before then and after the head went out.
fn publishHeadIfReady(gateway: *Gateway, handle: fetch_table.Handle) !void {
    const fetch = gateway.fetches.get(handle).?;
    if (fetch.head_sent)
        return;
    const running = fetch.stage.running;
    const task = running.task;
    task.mutex.lock();
    var task_locked = true;
    defer if (task_locked) task.mutex.unlock();
    if (!task.done)
        return;

    const result = task.result orelse {
        task.mutex.unlock();
        task_locked = false;
        // The engine settled the task as canceled without the gateway asking, as its stop does.
        return fetch_flow.end(gateway, handle, .{ .failed = .{ .message = "fetch canceled" } });
    };
    switch (result) {
        .success => |success| {
            var header_storage: [ipc.max_request_header_count]ipc.RequestHeader = undefined;
            const headers = prepareResponseHeaders(
                success.headers,
                &header_storage,
                gateway.policy.max_response_headers,
                gateway.policy.max_response_header_bytes,
            ) catch |err| {
                const message = responseHeaderErrorMessage(err);
                logResponseHeadRefused(gateway, fetch, success.headers.len, message);
                task.mutex.unlock();
                task_locked = false;
                return fetch_flow.end(gateway, handle, .{ .failed = .{ .message = message } });
            };
            const bytes = ipc.encodeEgressFetchHeadInto(gateway.encode_scratch, .{
                .fetch_id = fetch.fetch_id,
                .body_id = fetch.body_id,
                .flags = if (success.redirected) ipc.egress_fetch_head_flag_redirected else 0,
                .status = success.status,
                .body_encoding = bodyEncodingForIpc(success.body_encoding),
                // The worker decodes a non-identity body in its own cgroup, so the head carries
                // the body's resolved decoded limit and the worker enforces it. The watermark and
                // ratio stay zero, which the worker reads as the stream-pump defaults
                // (`worker/egress/body/decoder.zig:limitsFromHeadFields`).
                .max_decoded_body_bytes = running.queue.maxBytes() orelse 0,
                .status_text = success.status_text,
                .url = success.url,
                .headers = headers,
                .ready_at_mono_ns = os_process.monotonicNowNsOrZero(),
            }) catch {
                logResponseHeadRefused(gateway, fetch, success.headers.len, "response head too large");
                task.mutex.unlock();
                task_locked = false;
                return fetch_flow.end(gateway, handle, .{ .failed = .{ .message = "response head too large" } });
            };
            task.mutex.unlock();
            task_locked = false;
            const session = gateway.sessions.byId(fetch.session_id).?;
            switch (session_flow.queueHead(gateway, session, bytes)) {
                .written => {},
                // The task stays done, so the pump the attention pass runs once the ring has room
                // encodes the head again.
                .waits => {
                    fetch.head_waits_room = true;
                    return;
                },
                .unwritable => return fetch_flow.end(gateway, handle, .silent),
            }
            fetch.head_waits_room = false;
            fetch.head_sent = true;
        },
        .failure => |failure| {
            const ending = fetch_table.Ending{ .failed = .{
                .message = failure.message,
                .cause = failureCauseForIpc(failure.cause),
            } };
            task.mutex.unlock();
            task_locked = false;
            // The message lives in the task's result arena until the record releases the task,
            // which retirement does after the packet left.
            fetch_flow.end(gateway, handle, ending);
        },
    }
}

/// Publishes what the fetch's response queue holds, as far as the worker's body pool and
/// completion ring allow, then ends the fetch once the queue completes or fails. Call it only
/// after the head went out. When it returns with the fetch not ending, the rest waits for the
/// engine's next wake or the worker's next release.
fn drainBody(gateway: *Gateway, handle: fetch_table.Handle) !void {
    // `fetch` stays valid until the fetch ends: nothing below adds a record, and every path that
    // ends the fetch returns at once.
    const fetch = gateway.fetches.get(handle).?;
    const shard_index = fetch.shard_index;
    const engine = &gateway.shards.get(shard_index).engine;
    const session = gateway.sessions.byId(fetch.session_id).?;
    const queue = fetch.stage.running.queue;
    const run = fetch.stage.running.run;

    // Pulled chunks collect here and publish as one pool transaction and one ring packet per
    // flush rather than one per chunk, which on HTTP/2 would be one per DATA frame. The deferred
    // deinit runs on every exit and returns each staged credit exactly once.
    var batch = PendingBatch{ .shard_index = shard_index, .run = run };
    defer batch.deinit(engine);
    // Credits of chunks without bytes return at once, merged across the pass so the engine gets
    // one message per stream. A zero-byte credit still gets its own message, and delivering it is
    // what surfaces the stream's deferred end.
    var credits = credit_batch.CreditBatch{};
    defer credits.flush(&gateway.shards);

    const drain_quantum = drainQuantum(gateway);
    while (true) {
        if (!fetch.pull_armed) {
            fetch.pull_armed = true;
            _ = queue.armPull();
        }
        // A fragmented pool fans a chunk out into one ring descriptor per pool block, so the ring
        // must hold the worst case of everything pulled but not yet published plus one more pull.
        const reserve_blocks = batch.pending_blocks + publisher.blockCountForBytes(drain_quantum);
        const ring_usage = session.endpoint.completion.usage() catch |err| {
            session_flow.markForDrop(gateway, session, @errorName(err));
            return fetch_flow.end(gateway, handle, .silent);
        };
        const pool_fits = session.endpoint.body_pool.freeBlocks() >= reserve_blocks;
        const ring_fits = ring_usage.capacity - ring_usage.used >= publisher.worstCaseBatchPacketBytes(reserve_blocks);
        if (!pool_fits or !ring_fits) {
            if (batch.isEmpty()) {
                // The worker's next pool release brings a drain short of pool room back
                // (`release_flow.zig`); reading the ring announces nothing, so a drain short of
                // ring room has the session watched until the ring has room again.
                if (!ring_fits)
                    session_flow.awaitRingRoom(gateway, session);
                return;
            }
            // Publish what was already pulled, then look at the room again.
            if (!try batch.flush(gateway, session, handle, 0))
                return;
            continue;
        }

        const pulled = queue.pull(engine.allocator);
        if (pulled.isEmpty())
            break;
        if (pulled.disarmed)
            fetch.pull_armed = false;
        if (pulled.failed) {
            credits.add(&gateway.shards, shard_index, run, pulled.credit);
            // Chunks pulled earlier still go out before the error: the worker discards in order.
            if (!try batch.flush(gateway, session, handle, 0))
                return;
            const message = queue.failureMessage() orelse "fetch body failed";
            return fetch_flow.end(gateway, handle, .{ .failed = .{ .message = message } });
        }
        if (pulled.bytes) |bytes| {
            if (!try batch.appendChunk(gateway, session, handle, bytes, pulled.credit))
                return;
        } else {
            credits.add(&gateway.shards, shard_index, run, pulled.credit);
        }
        if (pulled.done) {
            if (!try batch.flush(gateway, session, handle, 0))
                return;
            return fetch_flow.end(gateway, handle, .body_end);
        }
    }
    _ = try batch.flush(gateway, session, handle, 0);
}

/// Body chunks accumulated across pulls. Payload entries point into the owned pulled buffers, and
/// one buffer backs several entries when it is split at `Policy.max_body_chunk_bytes`. A buffer is
/// freed once its entries are published, since the pool then holds the bytes.
///
/// A pulled credit has exactly one owner at every moment: the caller until `appendChunk` stages
/// it in a payload slot, the slot until `flush` publishes it, and then the worker's extent ledger,
/// where the worker's release of the extent is the credit's acknowledgement. `flush` clears the
/// slots only after the publication, so `deinit`'s sweep over the remaining slots returns every
/// staged but unpublished credit exactly once, whichever path dropped the batch; the engine
/// treats a credit for a stream the fetch's end reset as a no-op.
const PendingBatch = struct {
    shard_index: usize,
    /// The engine run of the fetch whose chunks the batch holds, which issued their credits.
    run: engine_mod.Run,
    payloads: [body_chunk_batch_max]publisher.BodyChunkPayload = undefined,
    payload_count: usize = 0,
    owned: [body_chunk_batch_max][]u8 = undefined,
    owned_count: usize = 0,
    /// Pool blocks, and so ring descriptors, the accumulated payloads take when published at
    /// worst; the drain's room check adds the next pull's worst case to it.
    pending_blocks: usize = 0,

    fn isEmpty(self: *const PendingBatch) bool {
        return self.payload_count == 0;
    }

    /// Returns every credit still staged in a payload slot and frees the pulled buffers.
    fn deinit(self: *PendingBatch, engine: *engine_mod.Engine) void {
        for (self.payloads[0..self.payload_count]) |payload|
            engine.releaseCredit(self.run, payload.credit);
        for (self.owned[0..self.owned_count]) |buffer|
            engine.allocator.free(buffer);
        self.* = undefined;
    }

    /// Takes ownership of `bytes`, one whole pulled chunk, splits it at the policy's chunk size,
    /// and rides `credit` on the final split, so it returns only when the worker returns the
    /// extent holding the chunk's last bytes. Flushes when the payload array fills. Returns false
    /// when a flush ended the fetch, after which the caller returns.
    fn appendChunk(
        self: *PendingBatch,
        gateway: *Gateway,
        session: *Session,
        handle: fetch_table.Handle,
        bytes: []u8,
        credit: body_credit.Handle,
    ) !bool {
        const engine = &gateway.shards.get(self.shard_index).engine;
        var bytes_owned = false;
        var credit_staged = false;
        errdefer {
            if (!bytes_owned)
                engine.allocator.free(bytes);
            // Until the credit is staged in a payload slot the deinit sweep cannot see it.
            if (!credit_staged)
                engine.releaseCredit(self.run, credit);
        }

        if (self.payload_count == self.payloads.len or self.owned_count == self.owned.len) {
            if (!try self.flush(gateway, session, handle, 0)) {
                engine.allocator.free(bytes);
                engine.releaseCredit(self.run, credit);
                return false;
            }
        }
        self.owned[self.owned_count] = bytes;
        self.owned_count += 1;
        bytes_owned = true;

        const chunk_bytes_max = gateway.policy.max_body_chunk_bytes;
        var offset: usize = 0;
        while (offset < bytes.len) {
            if (self.payload_count == self.payloads.len) {
                // The rest of this chunk still points into its buffer, so the flush keeps it.
                if (!try self.flush(gateway, session, handle, 1)) {
                    engine.releaseCredit(self.run, credit);
                    return false;
                }
            }
            const end = @min(offset + chunk_bytes_max, bytes.len);
            const payload_credit: body_credit.Handle = if (end == bytes.len) credit else .none;
            self.payloads[self.payload_count] = .{
                .bytes = bytes[offset..end],
                .credit = payload_credit,
            };
            self.payload_count += 1;
            if (end == bytes.len)
                credit_staged = true;
            self.pending_blocks += publisher.blockCountForBytes(end - offset);
            offset = end;
        }
        return true;
    }

    /// Publishes everything accumulated as one batch, then frees the pulled buffers except the
    /// trailing `retain_owned` (a chunk still being split). Returns false when the publication
    /// ended the fetch: a full pool or ring, which the room check makes a bookkeeping bug, fails
    /// it, and a session that cannot take the packet ends it silently. The staged credits then
    /// stay for `deinit`. Any other error leaves the slots and buffers for `deinit` as well.
    fn flush(
        self: *PendingBatch,
        gateway: *Gateway,
        session: *Session,
        handle: fetch_table.Handle,
        retain_owned: usize,
    ) !bool {
        if (self.payload_count != 0) {
            const fetch = gateway.fetches.get(handle).?;
            _ = session_flow.publishBody(gateway, session, fetch, self.run, self.payloads[0..self.payload_count]) catch |err| switch (err) {
                error.EgressSharedRingFull => {
                    std.log.warn("egress gateway body pool or ring full session={d} fetch_id={d}", .{ session.id, fetch.fetch_id });
                    fetch_flow.end(gateway, handle, .{ .failed = .{ .message = "egress body publication failed" } });
                    return false;
                },
                error.EgressGatewaySessionUnwritable => {
                    fetch_flow.end(gateway, handle, .silent);
                    return false;
                },
                else => return err,
            };
            // The publication handed every staged credit to the session's extent ledger.
            self.payload_count = 0;
            self.pending_blocks = 0;
        }
        const engine = &gateway.shards.get(self.shard_index).engine;
        const keep = @min(retain_owned, self.owned_count);
        const release_count = self.owned_count - keep;
        for (self.owned[0..release_count]) |buffer|
            engine.allocator.free(buffer);
        std.mem.copyForwards([]u8, self.owned[0..keep], self.owned[release_count..self.owned_count]);
        self.owned_count = keep;
        return true;
    }
};

/// Maps the task's failure cause onto the wire enum at the IPC boundary. A denial is the
/// tenant's event, so the gateway logs nothing for it; the worker tells the tenant.
fn failureCauseForIpc(cause: task_model.FailureCause) ipc.EgressFetchErrorCause {
    return switch (cause) {
        .failed => .failed,
        .network_denied => .network_denied,
    };
}

/// Maps the transport's body coding onto the wire enum at the IPC boundary, so the egress client
/// never depends on IPC types.
fn bodyEncodingForIpc(encoding: anytype) ipc.BodyEncoding {
    return switch (encoding) {
        .identity => .identity,
        .gzip => .gzip,
        .deflate => .deflate,
        .br => .br,
    };
}

/// Copies the response's header views into `storage` within the policy's count and byte limits.
/// `headers` is any slice of name and value byte slices, as the task's result holds them.
fn prepareResponseHeaders(
    headers: anytype,
    storage: *[ipc.max_request_header_count]ipc.RequestHeader,
    max_headers: usize,
    max_header_bytes: usize,
) ![]const ipc.RequestHeader {
    if (headers.len > @min(storage.len, max_headers))
        return error.TooManyResponseHeaders;
    var total: usize = 0;
    for (headers, 0..) |header, index| {
        if (total > max_header_bytes or header.name.len > max_header_bytes - total)
            return error.ResponseHeadersTooLarge;
        total += header.name.len;
        if (total > max_header_bytes or header.value.len > max_header_bytes - total)
            return error.ResponseHeadersTooLarge;
        total += header.value.len;
        storage[index] = .{ .name = header.name, .value = header.value };
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

fn logResponseHeadRefused(
    gateway: *const Gateway,
    fetch: *const fetch_table.Fetch,
    header_count: usize,
    message: []const u8,
) void {
    std.log.warn(
        "egress gateway response head refused session={d} fetch_id={d} header_count={d} max_headers={d} max_header_bytes={d}: {s}",
        .{
            fetch.session_id,
            fetch.fetch_id,
            header_count,
            gateway.policy.max_response_headers,
            gateway.policy.max_response_header_bytes,
            message,
        },
    );
}
