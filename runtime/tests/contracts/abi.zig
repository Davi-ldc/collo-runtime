//! Layout pins for the Zig mirrors in `runtime/src/bindings/root.zig` of the fetch
//! structs that `runtime/src/bindings/include/collo/abi.h` defines and that cross
//! the C ABI in both directions between the worker and the engine bridge. Both
//! files already check every field at compile time; these tests repeat the sizes
//! and some offsets as a third pin, so a layout change edits the header, the
//! mirror and this file together. Runs in `meta-test`.

const worker = @import("collo_worker");
const bindings = @import("collo_bindings");
const ipc = @import("collo_ipc");

// Analyzing the worker facade runs its compile-time block, which reaches every
// `collo_runtime_*` export the bridge calls.
comptime {
    _ = worker;
}

// Each reference analyzes the file it names in this compilation, which runs any
// compile-time layout check declared there. Of the three, only `page.zig` has
// any today, declared in the sections under `page/` that it analyzes.
test {
    _ = ipc;
    _ = @import("collo_worker_state").page;
    _ = @import("collo_worker_state").metrics;
}

test "FetchInit ABI shape carries binary headers as one POD object" {
    try @import("std").testing.expectEqual(@as(usize, 80), @sizeOf(bindings.FetchInit));
    try @import("std").testing.expectEqual(@as(usize, 56), @offsetOf(bindings.FetchInit, "headers"));
    try @import("std").testing.expectEqual(@as(usize, 64), @offsetOf(bindings.FetchInit, "headers_len"));
    try @import("std").testing.expectEqual(@as(usize, 72), @offsetOf(bindings.FetchInit, "flags"));
}

test "Fetch response stream ABI carries identity separately from headers" {
    try @import("std").testing.expectEqual(@as(usize, 32), @sizeOf(bindings.FetchBodyIdentity));
    try @import("std").testing.expectEqual(@as(usize, 56), @sizeOf(bindings.FetchBodyConsumeInit));
    try @import("std").testing.expectEqual(@as(usize, 104), @sizeOf(bindings.FetchResponseInit));
    try @import("std").testing.expectEqual(@as(usize, 72), @offsetOf(bindings.FetchResponseInit, "body_identity"));
}
