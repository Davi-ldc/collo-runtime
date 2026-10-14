//! What the gateway does with its shards, on its loop thread: collecting a shard's ready fetches,
//! pumping each into packets for its worker (`body_pump.zig`), and supervising a shard that failed.
//!
//! An error confined to one fetch's publication fails that fetch (`isFetchDemotableError`). Any
//! other error out of a collection pass, a hung-up shard wake eventfd or an owner-loop fault the
//! engine latched belongs to the whole shard: the shard stops, every fetch it ran ends with an
//! error, and the engine runs again on the threads and rings it booted with, the only restart the
//! gateway's seccomp filter allows. The gateway process ends only when the restart fails or the
//! shard exceeds the backstop in `containment.shard_restart`, and the server then spawns another
//! gateway.

const std = @import("std");
const os_process = @import("collo_os").process;

const containment = @import("../containment.zig");
const fetch_table = @import("../fetch_table.zig");
const ready_scan = @import("../ready_scan.zig");
const body_pump = @import("body_pump.zig");
const fetch_flow = @import("fetch_flow.zig");
const Gateway = @import("root.zig").Gateway;
const session_flow = @import("session_flow.zig");

// One collection pass takes at most `ready_event_collect_max` ready tokens, in batches of
// `ready_event_batch_max`. Whatever remains signals the shard's wake eventfd again for the next
// pass, so one busy shard cannot hold the main loop.
const ready_event_batch_max: usize = 256;
const ready_event_collect_max: usize = 1024;

/// Handles one readiness completion of shard `shard_index`'s wake eventfd. Fails, which ends the
/// gateway, when the shard's failure cannot be contained (`superviseShardFailure`).
pub fn handleShardReady(gateway: *Gateway, shard_index: usize, revents: i16) !void {
    if ((revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0)
        return superviseShardFailure(gateway, shard_index, error.EgressGatewayShardFailed);
    if ((revents & std.posix.POLL.IN) != 0) {
        collectShardReady(gateway, shard_index) catch |err|
            try superviseShardFailure(gateway, shard_index, err);
    }
}

/// Pumps the fetches whose tasks the shard's engine reported ready, and every fetch of the shard
/// when the engine asked for that. An error is the shard's and may follow fetches the pass
/// already published and retired.
pub fn collectShardReady(gateway: *Gateway, shard_index: usize) !void {
    const engine = &gateway.shards.get(shard_index).engine;
    gateway.coalesce_completion_notifies = true;
    defer {
        gateway.coalesce_completion_notifies = false;
        session_flow.flushCompletionNotifies(gateway);
    }
    var batch: [ready_event_batch_max]ready_scan.Event = undefined;
    var processed: usize = 0;
    var scan_required = false;
    var has_more = false;
    while (processed < ready_event_collect_max) {
        const drained = engine.drainReady(&batch);
        scan_required = scan_required or drained.scan_required;
        has_more = drained.has_more;
        for (batch[0..drained.len]) |event|
            try pumpReadyEvent(gateway, shard_index, event);
        processed += drained.len;
        if (drained.len < batch.len)
            break;
    }
    if (has_more)
        engine.signalWake();
    if (scan_required)
        try pumpShard(gateway, shard_index);
    // A fatal error that escaped the engine's owner loop is returned only after the pass
    // published whatever had already settled.
    if (engine.takeOwnerFault()) |err|
        return err;
}

/// Pumps the fetch `handle` names, which runs on a shard, and supervises that shard when the pump
/// fails with an error that is not the fetch's alone. Returns whether the shard restarted, which
/// ended every fetch it ran. Fails, which ends the gateway, as `superviseShardFailure` does.
pub fn pumpOrSupervise(gateway: *Gateway, handle: fetch_table.Handle) !bool {
    const shard_index = gateway.fetches.get(handle).?.shard_index;
    pumpFetch(gateway, handle) catch |err| {
        try superviseShardFailure(gateway, shard_index, err);
        return true;
    };
    return false;
}

/// Contains a shard-scoped failure to its shard: stops its engine, ends every fetch it ran with
/// an error and runs the engine again on its threads and rings. Returns `cause`, which ends the
/// gateway process, when the shard has restarted `containment.shard_restart.max_restarts_in_window`
/// times inside its window, or the restart's own error when it fails.
pub fn superviseShardFailure(gateway: *Gateway, shard_index: usize, cause: anyerror) anyerror!void {
    const shard = gateway.shards.get(shard_index);
    // The backstop comes first: a shard that keeps failing is not recovering, and each restart
    // already cost it its fetches. The propagated cause ends the process and is reported there.
    if (!shard.restart_backstop.admitRestartAt(os_process.monotonicNowNsOrZero())) {
        std.log.warn("egress gateway shard {d} exceeded {d} restarts in {d}s: {s}", .{
            shard_index,
            containment.shard_restart.max_restarts_in_window,
            containment.shard_restart.window_ns / std.time.ns_per_s,
            @errorName(cause),
        });
        return cause;
    }
    std.log.warn("egress gateway restarting shard {d}: {s}", .{ shard_index, @errorName(cause) });
    // Once `stop` returns, the engine has settled every task and no engine thread touches one,
    // so the records can go.
    shard.engine.stop();
    fetch_flow.endShardFetches(gateway, shard_index, .{ .message = "egress internal error" });
    shard.engine.clearForRestart();
    try shard.engine.start();
}

fn pumpReadyEvent(gateway: *Gateway, shard_index: usize, event: ready_scan.Event) !void {
    const fetch = gateway.fetches.get(event.handle) orelse return;
    if (fetch.shard_index != shard_index)
        return;
    switch (fetch.stage) {
        .running => |running| if (running.task != event.task) return,
        .admitting, .assembling => return,
    }
    try pumpFetch(gateway, event.handle);
}

/// Pumps every running fetch of the shard. Pumping never adds a record, so the walk over the
/// table's slots stays valid while records retire.
fn pumpShard(gateway: *Gateway, shard_index: usize) !void {
    var index: usize = 0;
    while (index < gateway.fetches.slotCount()) : (index += 1) {
        const fetch = gateway.fetches.liveAt(index) orelse continue;
        if (fetch.shard_index != shard_index or fetch.stage != .running)
            continue;
        try pumpFetch(gateway, gateway.fetches.handleAt(@intCast(index)));
    }
}

/// Moves what the fetch's task produced into packets, or retires the fetch once it is ending and
/// the engine let go of it (`fetch_flow.retireIfSettled`). An error confined to this fetch fails
/// it alone; any other is returned.
fn pumpFetch(gateway: *Gateway, handle: fetch_table.Handle) !void {
    const fetch = gateway.fetches.get(handle) orelse return;
    if (fetch.ending != null)
        return fetch_flow.retireIfSettled(gateway, handle);
    body_pump.pump(gateway, handle) catch |err| {
        if (!isFetchDemotableError(err))
            return err;
        std.log.warn("egress gateway failing fetch session={d} fetch_id={d}: {s}", .{
            fetch.session_id,
            fetch.fetch_id,
            @errorName(err),
        });
        fetch_flow.end(gateway, handle, .{ .failed = .{ .message = "egress internal error" } });
    };
}

/// Errors proven confined to one fetch's publication path, which fail that fetch instead of the
/// shard. The only one is `OutOfMemory` from the publish path (the session's extent ledger):
/// every allocation site unwinds through errdefers and the body drain's batch, which leave the
/// fetch releasable, and no pool or ring was touched. The pump turns its own encoding and
/// publication failures into the fetch's end (`body_pump.zig`), so every other error that reaches
/// here is a fault in shared state and stays fatal to the shard.
fn isFetchDemotableError(err: anyerror) bool {
    return err == error.OutOfMemory;
}
