//! The `collo_runtime_module_eval_settled` export: the bridge reports here
//! that a module evaluation it returned as `COLLO_STATUS_PENDING`, a
//! top-level await, has settled. It is called on the worker's VM thread from
//! the evaluation promise's reaction, inside a JSC microtask drain that may
//! belong to a request turn or to another module evaluation.

const std = @import("std");
const bindings = @import("collo_bindings");
const host_adapter = @import("adapter.zig");

/// Only records the settlement and wakes the loop. Settling reads the
/// module's exports, which runs JavaScript, so it waits for
/// `Runtime.collectModuleSettlements` in the loop's collect pass instead of
/// running inside the drain that reported it. `realm_index` names the realm
/// that evaluated the module, and `specifier`, borrowed for the call, is
/// copied.
///
/// A settlement dropped for lack of memory leaves the module evaluating: its
/// waiting requests run into their deadlines, and the first deadline that
/// finds the evaluation past `module_eval_budget_ns` pins its route failed
/// (`expireEvaluation` in `worker/modules/routes.zig`).
pub export fn collo_runtime_module_eval_settled(
    runtime_ptr: ?*anyopaque,
    realm_index: u32,
    specifier: bindings.RawString,
    resolved: u8,
) void {
    const runtime = host_adapter.fromOpaque(runtime_ptr) orelse return;
    const bytes = stringSlice(specifier) orelse return;
    const owned = runtime.core.allocator.dupe(u8, bytes) catch {
        std.log.err("module settlement dropped (out of memory) specifier={s}", .{bytes});
        return;
    };
    runtime.modules.state.pending_settlements.append(runtime.core.allocator, .{
        .realm_index = realm_index,
        .specifier = owned,
        .resolved = resolved != 0,
    }) catch {
        runtime.core.allocator.free(owned);
        std.log.err("module settlement dropped (out of memory) specifier={s}", .{bytes});
        return;
    };
    // A drain under `executeWorkItem` is followed by the loop's collect pass,
    // but one inside `handleEvent`, such as a fetch completion that settles
    // a module's top-level `await`, can be followed by the blocking ring wait
    // with this entry still queued (`scheduler/loop.zig`). The wake makes
    // that wait return `wakeup_ready`, whose handler runs the collect pass,
    // as `tryQueueReadyWorkReadySince` does for its backlog.
    runtime.wake();
}

fn stringSlice(raw: bindings.RawString) ?[]const u8 {
    if (raw.len == 0)
        return "";
    const ptr = raw.ptr orelse return null;
    return ptr[0..raw.len];
}
