//! Assembly of the request bodies a worker sends through its upload pool, on the gateway's loop
//! thread. A fetch start with the body-pooled flag is admitted in full (its shape checked, its
//! token verified, its record reserved with its upload bytes; `command_flow.zig`) and then waits
//! here, holding the grant admission chose, while the worker streams its body as upload-pool
//! extents. Each extent is copied into the fetch's assembly buffer and released to the pool at
//! once, so the pool only carries bytes in transit and no fetch holds pool space while it waits.
//! Once the announced length has arrived, the fetch goes to its shard's engine with the buffer
//! handed over without a copy, and the task keeps it, so a redirect that keeps the body replays it
//! as it does an inline one.
//!
//! Three bounds hold the buffers and the copies of the starts. Each session holds at most
//! `ipc.fetch_limits.request_body_pooled_in_flight_bytes_max` of announced lengths and start
//! copies (`ipc.fetch_limits.pooledStartHeldBytes`, admission). Every buffer and every copy comes
//! from the gateway's upload allocator, a counting allocator with `containment.upload_memory`'s
//! budget, so a full budget fails the next pooled start's allocation and that fetch alone; the
//! buffer goes back to it wherever the task that holds it ends, an engine thread included, since
//! the counting allocator is thread safe. And an upload still
//! assembling at its token's deadline fails and frees its buffer at the next loop pass
//! (`expire`), so a worker that never sends its extents holds nothing past the request it belongs
//! to. The shards' counting allocators never see an assembly buffer.
//!
//! Assembly state lives in the fetch's record and goes with it, however the fetch ends
//! (`fetch_flow.zig`). An extent whose running total disagrees with the bytes received fails its
//! fetch, and an extent for a fetch that is no longer assembling goes straight back to the pool;
//! only an extent the pool itself rejects, which means corrupt shared state, removes the session.

const std = @import("std");
const ipc = @import("collo_ipc");

const engine_mod = @import("../engine.zig");
const fetch_table = @import("../fetch_table.zig");
const sessions_mod = @import("../sessions.zig");
const fetch_flow = @import("fetch_flow.zig");
const Gateway = @import("root.zig").Gateway;

const OwnedBody = @import("collo_egress_client").task.OwnedBody;
const Session = sessions_mod.Session;
const Upload = fetch_table.Upload;

/// Gives the admitted pooled fetch `handle` its assembly state: a copy of its start and a buffer
/// of its announced length, all from the upload allocator, linked in deadline order. Fails with
/// `error.OutOfMemory`, which a full upload budget also gives, leaving the record as it was.
pub fn register(
    gateway: *Gateway,
    handle: fetch_table.Handle,
    fetch: ipc.EgressFetchStartView,
    grant: engine_mod.Grant,
) !void {
    std.debug.assert(fetch.pooled_body_len != 0);
    std.debug.assert(fetch.pooled_body_len <= gateway.policy.max_request_body_bytes);
    const allocator = gateway.upload_memory.allocator();
    const upload = try allocator.create(Upload);
    errdefer allocator.destroy(upload);
    const method = try allocator.dupe(u8, fetch.method);
    errdefer allocator.free(method);
    const url = try allocator.dupe(u8, fetch.url);
    errdefer allocator.free(url);
    var header_bytes_len: usize = 0;
    for (fetch.headers) |header|
        header_bytes_len += header.name.len + header.value.len;
    const header_bytes = try allocator.alloc(u8, header_bytes_len);
    errdefer allocator.free(header_bytes);
    const headers = try allocator.alloc(ipc.RequestHeader, fetch.headers.len);
    errdefer allocator.free(headers);
    var offset: usize = 0;
    for (fetch.headers, 0..) |header, index| {
        const name = header_bytes[offset..][0..header.name.len];
        @memcpy(name, header.name);
        offset += header.name.len;
        const value = header_bytes[offset..][0..header.value.len];
        @memcpy(value, header.value);
        offset += header.value.len;
        headers[index] = .{ .name = name, .value = value };
    }
    const buffer = try allocator.alloc(u8, @intCast(fetch.pooled_body_len));

    upload.* = .{
        .grant = grant,
        .flags = fetch.flags & ~ipc.egress_fetch_start_flag_body_pooled,
        .method = method,
        .url = url,
        .header_bytes = header_bytes,
        .headers = headers,
        .buffer = buffer,
        .allocator = allocator,
        .handle = handle,
    };
    insertByDeadline(gateway, upload);
    gateway.fetches.get(handle).?.stage = .{ .assembling = upload };
}

/// Unlinks and frees the assembly state of a fetch whose record is retiring.
pub fn forget(gateway: *Gateway, upload: *Upload) void {
    gateway.uploads_by_deadline.remove(&upload.deadline_node);
    upload.destroy();
}

/// Fails every upload still assembling whose token's deadline has come by `now_ns`: only a slow
/// worker or a slow loop gets there. Each frees its buffer and record, and its worker gets the
/// fetch's error. The loop runs it on every pass, at least once per `readiness.wait_tick_ns`.
pub fn expire(gateway: *Gateway, now_ns: u64) void {
    while (gateway.uploads_by_deadline.first) |node| {
        const upload: *Upload = @fieldParentPtr("deadline_node", node);
        if (upload.deadline() > now_ns)
            return;
        // An assembling record is never left ending: `end` retires it at once, and retirement
        // unlinks the upload (`forget`), so each pass of this loop takes one upload off the list.
        fetch_flow.end(gateway, upload.handle, .{ .failed = .{ .message = "egress upload deadline exceeded" } });
        std.debug.assert(gateway.uploads_by_deadline.first != node);
    }
}

/// Applies a batch of upload extents. Returns false, which removes the session, for a batch that
/// does not decode or an extent the pool rejects.
pub fn handleBatch(gateway: *Gateway, session: *Session, bytes: []const u8) bool {
    const chunks = ipc.decodeEgressUploadChunkBatch(gateway.decode_scratch, bytes) catch return false;
    var released_any = false;
    for (chunks) |chunk| {
        if (!applyChunk(gateway, session, chunk, &released_any))
            return false;
    }
    // Released extents refill the worker's pool, and its upload pump waits on the completion
    // eventfd.
    if (released_any)
        ipc.egress_shared.notify(session.endpoint.completion_eventfd);
    return true;
}

fn applyChunk(
    gateway: *Gateway,
    session: *Session,
    chunk: ipc.EgressUploadChunkView,
    released_any: *bool,
) bool {
    const extent = session.endpoint.upload_pool.borrowContiguousChunk(chunk.upload_pool_offset, chunk.len) catch |err| {
        std.log.warn("egress gateway invalid upload extent session={d} fetch_id={d}: {s}", .{
            session.id,
            chunk.fetch_id,
            @errorName(err),
        });
        return false;
    };
    defer releaseExtent(session, chunk, released_any);
    // Extents can still arrive after a stop or a failure ended the fetch; their space just goes
    // back to the pool.
    const handle = gateway.fetches.find(session.id, chunk.fetch_id) orelse return true;
    const fetch = gateway.fetches.get(handle).?;
    if (fetch.ending != null or fetch.stage != .assembling)
        return true;
    const upload = fetch.stage.assembling;
    if (chunk.body_bytes_total != upload.received + chunk.len or chunk.body_bytes_total > upload.buffer.len) {
        fetch_flow.end(gateway, handle, .{ .failed = .{ .message = "egress upload ledger mismatch" } });
        return true;
    }
    @memcpy(upload.buffer[@intCast(upload.received)..][0..chunk.len], extent);
    upload.received += chunk.len;
    if (upload.received == upload.buffer.len)
        submitAssembled(gateway, handle);
    return true;
}

/// Hands an assembled body to the fetch's engine. The engine owns the buffer from the call on,
/// whether it succeeds or fails, and frees it with the allocator that allocated it.
fn submitAssembled(gateway: *Gateway, handle: fetch_table.Handle) void {
    const fetch = gateway.fetches.get(handle).?;
    const upload = fetch.stage.assembling;
    const owned_body = OwnedBody{ .bytes = upload.buffer, .allocator = upload.allocator };
    upload.buffer = &.{};
    const running = gateway.shards.get(fetch.shard_index).engine.submit(handle, .{
        .fetch_id = fetch.fetch_id,
        // The engine never reads the token: the grant carries what admission decided.
        .egress_token = ipc.egress_token.none,
        .body_id = fetch.body_id,
        .flags = upload.flags,
        .method = upload.method,
        .url = upload.url,
        .headers = upload.headers,
        .body = &.{},
    }, upload.grant, owned_body) catch |err| {
        fetch_flow.end(gateway, handle, .{ .failed = .{ .message = @errorName(err) } });
        return;
    };
    forget(gateway, upload);
    gateway.fetches.get(handle).?.stage = .{ .running = running };
}

/// Links `upload` after the last upload whose deadline is not later than its own, so uploads of
/// one deadline keep their arrival order. Tokens are minted with later deadlines as time passes,
/// so the walk back from the tail usually stops at once.
fn insertByDeadline(gateway: *Gateway, upload: *Upload) void {
    const deadline = upload.deadline();
    var cursor = gateway.uploads_by_deadline.last;
    while (cursor) |node| : (cursor = node.prev) {
        const other: *Upload = @fieldParentPtr("deadline_node", node);
        if (other.deadline() <= deadline) {
            gateway.uploads_by_deadline.insertAfter(node, &upload.deadline_node);
            return;
        }
    }
    gateway.uploads_by_deadline.prepend(&upload.deadline_node);
}

fn releaseExtent(session: *Session, chunk: ipc.EgressUploadChunkView, released_any: *bool) void {
    // The release queue holds one entry per pool slot, so it cannot overflow. A failure means
    // corrupt shared state, and the extent is left for the session's teardown.
    session.endpoint.upload_pool.releaseChunk(chunk.upload_pool_offset, chunk.len) catch |err| {
        std.log.warn("egress gateway upload extent release failed session={d}: {s}", .{
            session.id,
            @errorName(err),
        });
        return;
    };
    released_any.* = true;
}
