//! The native memory that Web API objects keep outside the JSC heap, as the collector sees it in
//! the extra memory `collo_vm_heap_stats` returns. A Request or Response built from bytes keeps
//! them in a native buffer, so its cell reports them when it is created and again at every full
//! collection, and a body over a Blob's storage counts that storage once however many cells view
//! it. A CompressionStream reports what its codec library holds. Each case holds objects in a
//! module global across the end of a request, collects, reads the extra memory, then drops them
//! and collects again. Lane: `bindings-test`; body and stream semantics are covered by the
//! `webapi` lane's `runtime/tests/webapi/body/` and `runtime/tests/webapi/streams/`.

const std = @import("std");
const support = @import("bindings_support");
const bindings = support.bindings;

const specifier = "/body-memory.js";
const mib = 1024 * 1024;

const source =
    \\let held = [];
    \\
    \\export function release() {
    \\    held = [];
    \\}
    \\
    \\// Each body copies the bytes it is given, so the Uint8Array is garbage once the
    \\// loop moves on and only the bodies keep the bytes.
    \\export function holdByteResponses() {
    \\    held = [];
    \\    for (let i = 0; i < 32; i++) held.push(new Response(new Uint8Array(1024 * 1024)));
    \\}
    \\
    \\export function holdByteRequests() {
    \\    held = [];
    \\    for (let i = 0; i < 32; i++) {
    \\        held.push(new Request("https://example.com/", { method: "POST", body: new Uint8Array(1024 * 1024) }));
    \\    }
    \\}
    \\
    \\// One 4 MiB Blob, kept, and 32 Responses that view its storage.
    \\export function holdBlobViews() {
    \\    const blob = new Blob([new Uint8Array(4 * 1024 * 1024)]);
    \\    held = [blob];
    \\    for (let i = 0; i < 32; i++) held.push(new Response(blob));
    \\}
    \\
    \\// zlib's deflate allocates its window, hash chains and pending buffer when the stream is
    \\// created, about 256 KiB at the default window and memory level.
    \\export function holdGzipCompressionStreams() {
    \\    held = [];
    \\    for (let i = 0; i < 16; i++) held.push(new CompressionStream("gzip"));
    \\}
;

fn createVm() !bindings.Vm {
    var vm = try support.createVm();
    errdefer vm.deinit();
    try support.registerModule(&vm, specifier, source);
    try support.evaluateOk(&vm, specifier);
    return vm;
}

/// Calls export `name` in a turn of request `request_id`, then ends the request.
fn runRequest(vm: *bindings.Vm, request_id: u64, name: []const u8) !void {
    var function = try support.getExportOk(vm, specifier, name);
    defer function.deinit();
    var ctx = support.makeExecCtx(request_id);
    try vm.turnEnter(&ctx);
    {
        errdefer vm.turnExit() catch {};
        var result = try support.invokeOk(vm, &ctx, &function, &.{});
        result.deinit();
    }
    try vm.turnExit();
    try vm.cleanupWebApiRequest(request_id);
}

/// The heap's extra memory right after a full collection, which rebuilds it from what every
/// live cell reports.
fn extraMemoryAfterFullCollection(vm: *bindings.Vm) !u64 {
    try vm.collectFullGCAndTrim();
    const stats = try vm.heapStats();
    return stats.extra_memory_bytes;
}

/// What one case held, as extra memory over the reading before it.
const HeldMemory = struct {
    held_bytes: u64,
    released_bytes: u64,
};

/// Runs `hold` as request `request_id` and `release` as the next request, and measures the
/// extra memory the held objects added and what their release gave back.
fn measureHoldAndRelease(vm: *bindings.Vm, request_id: u64, hold: []const u8) !HeldMemory {
    const before = try extraMemoryAfterFullCollection(vm);
    try runRequest(vm, request_id, hold);
    const held = try extraMemoryAfterFullCollection(vm);
    try runRequest(vm, request_id + 1, "release");
    const after = try extraMemoryAfterFullCollection(vm);
    return .{
        .held_bytes = held -| before,
        .released_bytes = held -| after,
    };
}

test "byte bodies count toward the heap's extra memory until their Response or Request dies" {
    var vm = try createVm();
    defer vm.deinit();

    // 32 bodies of 1 MiB each. A conservative root (a stale stack slot) may keep one cell
    // through a collection, so the release is expected to return all but one body.
    const responses = try measureHoldAndRelease(&vm, 100, "holdByteResponses");
    try std.testing.expect(responses.held_bytes >= 32 * mib);
    try std.testing.expect(responses.released_bytes >= 31 * mib);

    const requests = try measureHoldAndRelease(&vm, 110, "holdByteRequests");
    try std.testing.expect(requests.held_bytes >= 32 * mib);
    try std.testing.expect(requests.released_bytes >= 31 * mib);
}

test "Responses over one Blob count its storage once" {
    var vm = try createVm();
    defer vm.deinit();

    // The Blob and the 32 Responses viewing its 4 MiB storage report it once per collection,
    // where one report per viewer would pass 128 MiB. The upper bound leaves room for a buffer
    // a stale stack slot keeps through the collection.
    const views = try measureHoldAndRelease(&vm, 200, "holdBlobViews");
    try std.testing.expect(views.held_bytes >= 4 * mib);
    try std.testing.expect(views.held_bytes < 16 * mib);
    try std.testing.expect(views.released_bytes >= 4 * mib);
}

test "CompressionStreams count their codec state until they die" {
    var vm = try createVm();
    defer vm.deinit();

    // 16 deflate states of at least 256 KiB each; as above, one stream may survive a collection
    // through a stale stack slot.
    const deflate_state_bytes_min = 256 * 1024;
    const streams = try measureHoldAndRelease(&vm, 300, "holdGzipCompressionStreams");
    try std.testing.expect(streams.held_bytes >= 16 * deflate_state_bytes_min);
    try std.testing.expect(streams.released_bytes >= 15 * deflate_state_bytes_min);
}
