//! Layout pins for the Zig mirrors in `runtime/src/bindings/root.zig` of the
//! structs that `runtime/src/bindings/include/collo/abi.h` defines and that
//! cross the C ABI in both directions between the worker and the engine bridge,
//! for the owner bounds both sides derive from `common/limits/server.zig`, and
//! for the module pack bound the header repeats from
//! `common/ipc/module_pack.zig`. Both files already check every field at
//! compile time; these tests repeat the sizes and some offsets as a third pin,
//! so a layout change edits the header, the mirror and this file together.
//! Runs in `meta-test`.

const std = @import("std");
const worker = @import("collo_worker");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");

// Analyzing the worker facade runs its compile-time block, which reaches every
// `collo_runtime_*` export the bridge calls.
comptime {
    _ = worker;
}

// Each reference analyzes the file it names in this compilation, which runs any
// compile-time layout check declared there; `page.zig`'s are declared in the
// sections under `page/` that it analyzes.
test {
    _ = ipc;
    _ = @import("collo_worker_state").page;
}

test "FetchInit ABI shape carries binary headers as one POD object" {
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(bindings.FetchInit));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(bindings.FetchInit, "headers"));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(bindings.FetchInit, "headers_len"));
    try std.testing.expectEqual(@as(usize, 72), @offsetOf(bindings.FetchInit, "flags"));
}

test "Fetch response stream ABI carries identity separately from headers" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(bindings.FetchBodyIdentity));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(bindings.FetchBodyConsumeInit));
    try std.testing.expectEqual(@as(usize, 104), @sizeOf(bindings.FetchResponseInit));
    try std.testing.expectEqual(@as(usize, 72), @offsetOf(bindings.FetchResponseInit, "body_identity"));
}

test "an exec context carries an owner's identity and no CPU clock" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(bindings.ExecCtx));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(bindings.ExecCtx, "request_id"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(bindings.ExecCtx, "deadline_monotonic_ns"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(bindings.ExecCtx, "termination_reason"));
}

test "the owner table holds every request, evaluation and the worker owner a worker can run at once" {
    const concurrency_max: usize = limits.server.worker_concurrency_max;
    const routes_max: usize = limits.server.routes_per_definition_max;
    try std.testing.expectEqual(@as(usize, 81), bindings.owner_slot_count);
    try std.testing.expectEqual(concurrency_max + routes_max + 1, bindings.owner_slot_count);
    // The ids above `request_id_max` are one per evaluation and the worker owner's.
    try std.testing.expectEqual(@as(u64, routes_max + 1), std.math.maxInt(u64) - bindings.request_id_max);
}

test "extracted headers and bodies carry no growth fields" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(bindings.HeaderView));
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(bindings.ExtractedResponseBody));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(bindings.ExtractedResponseBody, "reserved0"));
    try std.testing.expectEqual(@as(usize, 72), @offsetOf(bindings.ExtractedResponseBody, "body_stream"));
}

test "an extracted response keeps its layout" {
    try std.testing.expectEqual(@as(usize, 128), @sizeOf(bindings.ExtractedResponse));
    try std.testing.expectEqual(@as(usize, 80), @offsetOf(bindings.ExtractedResponse, "headers"));
    try std.testing.expectEqual(@as(usize, 120), @offsetOf(bindings.ExtractedResponse, "status"));
    try std.testing.expectEqual(@as(usize, 122), @offsetOf(bindings.ExtractedResponse, "reserved0"));
    try std.testing.expectEqual(@as(usize, 124), @offsetOf(bindings.ExtractedResponse, "reserved1"));
}

test "memory status and heap statistics keep their layouts" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(bindings.MemoryStatus));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(bindings.MemoryStatus, "in_use_per_million"));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(bindings.HeapStats));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(bindings.HeapStats, "extra_memory_bytes"));
}

// `COLLO_MODULE_PACK_MAX_BYTES` and `COLLO_MODULE_PACK_MAX_MODULES`, with
// their mirrors in `bindings/root.zig`, repeat the pack format's bounds by
// hand, and the bridge refuses a pack past either.
comptime {
    std.debug.assert(bindings.module_pack_max_bytes == ipc.module_pack.max_pack_bytes);
    std.debug.assert(bindings.module_pack_max_modules == ipc.module_pack.max_module_count);
}
