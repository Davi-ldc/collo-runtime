//! Test access to a shard engine's internals for the gateway suites: it puts fetches straight
//! into the active table, queues body chunks and ready events, and reads engine state, so
//! `engine.Engine` carries no testing API beyond the `test_collect_fault` hook that
//! `armCollectFault` arms. Every helper runs on the test's thread, which stands in for the
//! gateway's loop thread. An injected fetch is never submitted to the inner engine, so no
//! engine thread settles its task; a test settles it with `markActiveTaskDone` or
//! `markActiveTerminalDone`.

const std = @import("std");
const bindings = @import("collo_bindings");
const limits = @import("collo_limits");
const egress = @import("collo_egress_client");
const gateway = @import("collo_egress_gateway");

const active_fetch = gateway.active_fetch;
const budgets = gateway.budgets;
const engine_mod = gateway.engine;

const body_credit = egress.body_credit;
const fetch_body = egress.fetch_body;
const task_model = egress.task;

pub fn injectActive(
    engine: *engine_mod.Engine,
    worker_session_id: u64,
    fetch_id: u64,
    body_id: u64,
) !void {
    return injectActiveRequest(engine, worker_session_id, fetch_id, body_id, .{});
}

pub const InjectRequestOptions = struct {
    method: []const u8 = "GET",
    url: []const u8 = "https://example.test/",
    body: []const u8 = "",
    request_deadline_mono_ns: u64 = 0,
    /// The request the fetch serves, as its token names it within the fetch's session. Its
    /// budget key is the session's and these two, and its response body carries both.
    request_id: u64 = 1,
    request_generation: u64 = 1,
};

/// `injectActive` with a caller-shaped request: teardown tests control the
/// method and body, which decide replay safety, and the admission deadline
/// and request a redispatch must carry. The policy entry a redispatch runs
/// under comes from the fetch's route, which the test records.
pub fn injectActiveRequest(
    engine: *engine_mod.Engine,
    worker_session_id: u64,
    fetch_id: u64,
    body_id: u64,
    options: InjectRequestOptions,
) !void {
    if (worker_session_id == 0 or fetch_id == 0 or body_id == 0)
        return error.InvalidEgressGatewayFetchIdentity;
    if (engine.active.hasWorkerIdentity(worker_session_id, fetch_id, body_id))
        return error.EgressGatewayDuplicateFetchIdentity;

    const identity = bindings.FetchBodyIdentity{
        .request_id = options.request_id,
        .request_generation = options.request_generation,
        .fetch_id = fetch_id,
        .body_id = body_id,
    };

    const body = try engine.allocator.create(fetch_body.Body);
    var body_owned = true;
    var body_initialized = false;
    errdefer {
        if (body_owned and body_initialized)
            body.deinitAfterQueuedResourcesReleased(engine.allocator);
        if (body_owned)
            engine.allocator.destroy(body);
    }
    body.* = fetch_body.Body.initOpen(
        engine.allocator,
        identity,
        limits.http_body.MATERIALIZED_BODY_BYTES_MAX,
    );
    body_initialized = true;

    const task = try engine.allocator.create(task_model.Task);
    var task_owned = true;
    var task_initialized = false;
    errdefer {
        if (task_owned and task_initialized)
            task.deinit();
        if (task_owned)
            engine.allocator.destroy(task);
    }
    task.* = try task_model.Task.init(
        engine.allocator,
        fetch_id,
        options.request_id,
        options.url,
        options.method,
        options.body,
        &.{},
        0,
        identity,
        body,
    );
    task_initialized = true;
    body_owned = false;

    _ = try engine.active.append(engine.allocator, .{
        .worker_session_id = worker_session_id,
        .budget_key = .{
            .session_id = worker_session_id,
            .request_id = options.request_id,
            .request_generation = options.request_generation,
        },
        .worker_attached = true,
        .task = task,
        .body = body,
        .fetch_id = fetch_id,
        .body_id = body_id,
        .request_deadline_mono_ns = options.request_deadline_mono_ns,
    }, engine.ready.nextGeneration());
    task_owned = false;
}

/// Folds absolute egress meter totals into the fetch's body, as the transport
/// does while an attempt runs, so teardown tests can check the cost a replayed
/// fetch carries over without a live transport.
pub fn setActiveBodyEgressMeters(
    engine: *engine_mod.Engine,
    worker_session_id: u64,
    fetch_id: u64,
    body_id: u64,
    meters: fetch_body.EgressMeters,
) !void {
    const fetch = findActive(engine, worker_session_id, fetch_id, body_id) orelse
        return error.MissingEgressGatewayFetch;
    fetch.body.setEgressMeters(meters);
}

pub fn appendReadyBodyChunk(
    engine: *engine_mod.Engine,
    worker_session_id: u64,
    fetch_id: u64,
    body_id: u64,
    bytes: []const u8,
) !void {
    try appendReadyBodyChunkWithCredit(engine, worker_session_id, fetch_id, body_id, bytes, .none);
}

pub fn appendReadyBodyChunkWithCredit(
    engine: *engine_mod.Engine,
    worker_session_id: u64,
    fetch_id: u64,
    body_id: u64,
    bytes: []const u8,
    credit: body_credit.Handle,
) !void {
    const fetch = findActive(engine, worker_session_id, fetch_id, body_id) orelse
        return error.MissingEgressGatewayFetch;
    const owned = try engine.allocator.dupe(u8, bytes);
    var owned_moved = false;
    errdefer if (!owned_moved)
        engine.allocator.free(owned);
    _ = try fetch.body.appendOwnedChunk(engine.allocator, owned, credit);
    owned_moved = true;
    // A body chunk follows the head, so the fetch counts as having sent it.
    fetch.head_sent = true;
}

/// Marks the fetch's body complete, as the transport does on an HTTP/2
/// END_STREAM or at the end of an HTTP/1 body; the next drain sees `done` and
/// publishes body end.
pub fn markActiveBodyComplete(
    engine: *engine_mod.Engine,
    worker_session_id: u64,
    fetch_id: u64,
    body_id: u64,
) !void {
    const fetch = findActive(engine, worker_session_id, fetch_id, body_id) orelse
        return error.MissingEgressGatewayFetch;
    _ = fetch.body.complete();
}

/// Pool extents published for the fetch that the worker has not returned yet,
/// or 0 when no such fetch is in the table. A fetch past body end stays in the
/// table until this reaches zero; a failed or canceled one retires anyway.
pub fn outstandingExtents(
    engine: *engine_mod.Engine,
    worker_session_id: u64,
    fetch_id: u64,
    body_id: u64,
) usize {
    const fetch = findActive(engine, worker_session_id, fetch_id, body_id) orelse return 0;
    return fetch.outstanding_extents;
}

/// Counts extents as published without running the publish path, as
/// `Fetch.sendBodyChunkBatchOrDetach` does after a publication, for tests of
/// the release and retirement side only.
pub fn notePublishedExtents(
    engine: *engine_mod.Engine,
    worker_session_id: u64,
    fetch_id: u64,
    body_id: u64,
    count: usize,
) !void {
    const fetch = findActive(engine, worker_session_id, fetch_id, body_id) orelse
        return error.MissingEgressGatewayFetch;
    fetch.noteExtentsPublished(count);
}

pub fn activeFetchBodyEndSent(
    engine: *engine_mod.Engine,
    worker_session_id: u64,
    fetch_id: u64,
    body_id: u64,
) bool {
    const fetch = findActive(engine, worker_session_id, fetch_id, body_id) orelse return false;
    return fetch.body_end_sent;
}

pub fn activeFetchCanceled(engine: *engine_mod.Engine, worker_session_id: u64, fetch_id: u64) bool {
    const index = engine.active.indexByFetch(worker_session_id, fetch_id) orelse return false;
    const fetch = engine.active.get(index);
    fetch.task.mutex.lock();
    defer fetch.task.mutex.unlock();
    return fetch.task.canceled;
}

pub fn activeFetchTerminal(engine: *engine_mod.Engine, worker_session_id: u64, fetch_id: u64) bool {
    const index = engine.active.indexByFetch(worker_session_id, fetch_id) orelse return false;
    const fetch = engine.active.get(index);
    return fetch.terminal;
}

pub fn activeFetchCount(engine: *const engine_mod.Engine) usize {
    return engine.active.len();
}

/// The request deadline recorded on an admitted fetch, the deadline of the
/// token admission verified, or null when no such fetch is in the table. The
/// worker-flow admission tests read it, and the three readers below, to check
/// what admission passed to `Engine.submit` without a live transport.
pub fn activeFetchRequestDeadline(
    engine: *engine_mod.Engine,
    worker_session_id: u64,
    fetch_id: u64,
    body_id: u64,
) ?u64 {
    const fetch = findActive(engine, worker_session_id, fetch_id, body_id) orelse return null;
    return fetch.request_deadline_mono_ns;
}

/// The request an admitted fetch serves, as its token named it, or null when
/// no such fetch is in the table.
pub fn activeFetchBudgetKey(
    engine: *engine_mod.Engine,
    worker_session_id: u64,
    fetch_id: u64,
    body_id: u64,
) ?budgets.BudgetKey {
    const fetch = findActive(engine, worker_session_id, fetch_id, body_id) orelse return null;
    return fetch.budget_key;
}

pub fn readyOverflowScanTotal(engine: *const engine_mod.Engine) u64 {
    return engine.ready.overflowScanTotal();
}

pub fn readyPendingEventCount(engine: *const engine_mod.Engine) usize {
    return engine.ready.len;
}

pub fn readyWorkerScanPendingCount(engine: *const engine_mod.Engine) usize {
    return engine.ready.worker_scan_len;
}

pub fn readyScanPending(engine: *const engine_mod.Engine) bool {
    return engine.ready.scan_required;
}

pub fn wakeActiveTask(
    engine: *engine_mod.Engine,
    worker_session_id: u64,
    fetch_id: u64,
    body_id: u64,
) !void {
    const fetch = findActive(engine, worker_session_id, fetch_id, body_id) orelse
        return error.MissingEgressGatewayFetch;
    _ = engine.ready.enqueueTask(.{
        .task = fetch.task,
        .generation = fetch.task.ready_generation.load(.monotonic),
    });
    signalWakeFd(engine.wake_fd);
}

pub fn wakeGeneric(engine: *engine_mod.Engine) void {
    _ = engine.ready.requestScan(false);
    signalWakeFd(engine.wake_fd);
}

/// Enqueues the fetch's ready token without writing the wake eventfd and
/// returns whether the queue asked for that write, so a test can check that
/// only an enqueue into an empty queue asks.
pub fn enqueueReadyTaskWake(
    engine: *engine_mod.Engine,
    worker_session_id: u64,
    fetch_id: u64,
    body_id: u64,
) !bool {
    const fetch = findActive(engine, worker_session_id, fetch_id, body_id) orelse
        return error.MissingEgressGatewayFetch;
    return engine.ready.enqueueTask(.{
        .task = fetch.task,
        .generation = fetch.task.ready_generation.load(.monotonic),
    });
}

pub fn markActiveTaskDone(engine: *engine_mod.Engine, worker_session_id: u64, fetch_id: u64) !void {
    const index = engine.active.indexByFetch(worker_session_id, fetch_id) orelse
        return error.MissingEgressGatewayFetch;
    const fetch = engine.active.get(index);
    fetch.task.mutex.lock();
    fetch.task.done = true;
    fetch.task.result = .{ .failure = .{
        .message = "test done",
        .owned = false,
    } };
    fetch.task.mutex.unlock();
}

pub fn markActiveTerminalDone(
    engine: *engine_mod.Engine,
    worker_session_id: u64,
    fetch_id: u64,
    body_id: u64,
) !void {
    const fetch = findActive(engine, worker_session_id, fetch_id, body_id) orelse
        return error.MissingEgressGatewayFetch;
    fetch.task.mutex.lock();
    fetch.task.done = true;
    fetch.task.result = .{ .failure = .{
        .message = "test terminal",
        .owned = false,
    } };
    fetch.task.mutex.unlock();
    fetch.terminal = true;
}

pub fn bodyCreditReleaseFailures(engine: *const engine_mod.Engine) u64 {
    return engine.body_credit_release_failed_total;
}

pub fn demotedFetchErrors(engine: *const engine_mod.Engine) u64 {
    return engine.demoted_fetch_errors_total;
}

/// Arms `Engine.test_collect_fault`: the next collection pass returns `err`
/// when it reaches this fetch, before pumping it and ahead of the demotion
/// check, so any `err` leaves the pass and drives the shard supervisor.
/// Fetches the same pass already completed keep their completion, and the
/// route-removal defer in `shard_flow.collectShardReady` removes their routes.
pub fn armCollectFault(
    engine: *engine_mod.Engine,
    worker_session_id: u64,
    fetch_id: u64,
    err: anyerror,
) void {
    engine.test_collect_fault = .{
        .worker_session_id = worker_session_id,
        .fetch_id = fetch_id,
        .err = err,
    };
}

/// Sets the inner engine's owner-fault latch directly. It models a fatal
/// error escaping the owner loop, such as a watch-list allocation that keeps
/// failing at the shard's memory budget, without killing a real owner thread.
/// The next collection pass returns the error, which must drive the shard
/// supervisor.
pub fn injectOwnerFault(engine: *engine_mod.Engine, err: anyerror) void {
    engine.inner.noteOwnerFault(err);
}

pub fn leakedBodyCreditBytes(engine: *const engine_mod.Engine) u64 {
    return engine.body_credit_leaked_bytes;
}

pub fn workerForceDetachTotal(engine: *const engine_mod.Engine) u64 {
    return engine.worker_session_force_detach_total;
}

fn findActive(
    engine: *engine_mod.Engine,
    worker_session_id: u64,
    fetch_id: u64,
    body_id: u64,
) ?*active_fetch.Fetch {
    return engine.active.find(worker_session_id, fetch_id, body_id);
}

fn signalWakeFd(fd: std.posix.fd_t) void {
    var one: u64 = 1;
    _ = std.posix.write(fd, std.mem.asBytes(&one)) catch |err| switch (err) {
        error.WouldBlock => return,
        else => |unexpected| {
            std.log.warn("egress gateway test wake write failed: {s}", .{@errorName(unexpected)});
            return;
        },
    };
}
