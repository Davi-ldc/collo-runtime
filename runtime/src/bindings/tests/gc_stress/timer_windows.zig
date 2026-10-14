//! Timer window test for the `bindings-gc-stress` lane: streams whose controllers only pending
//! timers reach while script allocates. The handler keeps each stream's pending read promise,
//! which references nothing of its stream, so the worker runtime's timer table, through each
//! timer's callback, is the only root of the controller, the stream, its reader and the read it
//! will settle. A stream edge the collector misses shows up as a chunk that never arrives, a
//! wrong or scribbled chunk, or a crash; the forced profile collects at every allocation slow
//! path, which puts a collection inside every window. Under `bindings-test`, with neither
//! profile, the test runs once as a sanity check. The request runs through an in-process worker
//! runtime on a fake clock, as `set_timeout.zig` drives timers; the windows over bridge state
//! alone are in `windows.zig`, and the collection of streams nothing can feed in
//! `stream_promise_roots.zig`.

const std = @import("std");
const support = @import("bindings_support");
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");

const request_id: u64 = 100;
/// Far beyond the fake time the timers below take, so the request never meets its deadline.
const request_deadline_ns: u64 = 60 * std.time.ns_per_s;
/// The fake time the loop runs before it gives up on the request.
const request_budget_ns: u64 = 10 * std.time.ns_per_s;

const source =
    \\const rounds = 4;
    \\const streamsPerRound = 8;
    \\
    \\// Allocates short-lived objects, so a collection can run at this point.
    \\function churnGarbage(count) {
    \\    const garbage = [];
    \\    for (let i = 0; i < count; i++) garbage.push({ i, text: `garbage ${i}` });
    \\    return garbage.length;
    \\}
    \\
    \\function check(condition, message) {
    \\    if (!condition) throw new Error(message);
    \\}
    \\
    \\// A value whose every part is derived from (round, index), so a freed or
    \\// swapped cell cannot pass the check.
    \\function makeItem(round, index) {
    \\    const bytes = new Uint8Array(48 + (index % 5));
    \\    bytes.fill((round * 31 + index) & 0xff);
    \\    return { round, index, text: `item-${round}-${index}`, bytes };
    \\}
    \\
    \\function checkItem(item, round, index) {
    \\    check(item !== null && typeof item === "object", `item ${round}/${index} is ${item}`);
    \\    check(item.round === round && item.index === index, `item ${round}/${index} came back as ${item.round}/${item.index}`);
    \\    check(item.text === `item-${round}-${index}`, `item ${round}/${index} text ${item.text}`);
    \\    check(item.bytes instanceof Uint8Array, `item ${round}/${index} lost its bytes`);
    \\    check(item.bytes.length === 48 + (index % 5), `item ${round}/${index} has ${item.bytes.length} bytes`);
    \\    const expected = (round * 31 + index) & 0xff;
    \\    for (const byte of item.bytes) check(byte === expected, `item ${round}/${index} byte ${byte}`);
    \\}
    \\
    \\// Returns the promise of a read that only the timer's callback can settle:
    \\// the stream, its reader and its controller are garbage to everything but
    \\// that callback. The delay differs per stream, so each callback runs with the
    \\// later ones still pending.
    \\function readThroughTimer(round, index) {
    \\    let controller = null;
    \\    const stream = new ReadableStream(
    \\        {
    \\            start(c) {
    \\                controller = c;
    \\            },
    \\        },
    \\        { highWaterMark: 0 },
    \\    );
    \\    const read = stream.getReader().read();
    \\    setTimeout(() => {
    \\        churnGarbage(64);
    \\        controller.enqueue(makeItem(round, index));
    \\        controller.close();
    \\    }, index);
    \\    return read;
    \\}
    \\
    \\export default async function handler() {
    \\    try {
    \\        for (let round = 0; round < rounds; round++) {
    \\            const reads = [];
    \\            for (let index = 0; index < streamsPerRound; index++) reads.push(readThroughTimer(round, index));
    \\            churnGarbage(256);
    \\            for (let index = 0; index < streamsPerRound; index++) {
    \\                const { value, done } = await reads[index];
    \\                check(!done, `round ${round}: stream ${index} ended without its chunk`);
    \\                checkItem(value, round, index);
    \\            }
    \\        }
    \\        return new Response("ok");
    \\    } catch (error) {
    \\        return new Response(`failed: ${error && error.stack ? error.stack : error}`, { status: 500 });
    \\    }
    \\}
;

test "a stream whose controller only a pending timer holds delivers its chunk to the pending read" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(
        std.testing.allocator,
        &vm,
        control_pair[0],
        &completion_fixture.view,
        try rt.createCompletionEventfd(),
        .{ .ctx = &now_mono_ns, .now_fn = rt.fakeNow },
    );
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const route_specifier = try rt.routeSpecifier(std.testing.allocator, "/gc-stress-timer-windows.js");
    defer std.testing.allocator.free(route_specifier);
    const route_index = try rt.registerRoute(&runtime, route_specifier, source);

    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .route_index = route_index,
        .deadline_monotonic_ns = request_deadline_ns,
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, .{});
    try rt.executeQueuedBegin(&runtime);
    try rt.executeUntilRequestDoneOnFakeClock(&runtime, &now_mono_ns, request_id, .{
        .budget_ns = request_budget_ns,
    });

    var response = try rt.readIngressResponse(&runtime, control_pair[1], request_id);
    defer response.deinit();
    try std.testing.expectEqualStrings("ok", response.body);
    try std.testing.expectEqual(@as(u16, 200), response.status);
}
