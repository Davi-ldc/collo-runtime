//! Request body window tests for the `bindings-gc-stress` lane: the stream of a streamed request
//! body, whose native source answers each pull with a promise, across script that runs and
//! allocates inside the stream's own operations. The handler lets go of its Request, so the
//! stream, through its source, is the only path to it. A cancel settles the pending read, whose
//! `then` lookup runs an allocating getter while the source's cancel is still to come; a pull that
//! completes after its reader was released leaves its chunk in the stream's queue for the next
//! reader; a tee of the body reads it through a tee state that only its branches hold. A cell the
//! collector misses shows up as a lost or wrong chunk, or a crash; the forced profile collects at
//! every allocation slow path, which puts a collection inside every window. Under `bindings-test`,
//! with neither profile, each test runs once as a sanity check. The requests run through an
//! in-process worker runtime on a fake clock, as `timer_windows.zig` runs its own; the streams'
//! semantics are covered by the `webapi` lane's `runtime/tests/webapi/streams/`.

const std = @import("std");
const support = @import("bindings_support");
const ipc = @import("collo_ipc");
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");

/// Far beyond the fake time the timers below take, so the request never meets its deadline.
const request_deadline_ns: u64 = 60 * std.time.ns_per_s;
/// The fake time the loop runs before it gives up on the request.
const request_budget_ns: u64 = 10 * std.time.ns_per_s;
const stream_id: u32 = 1;

/// The body arrives in two chunks: the first with the request's head, the second while the
/// handler runs.
const body_head = "hello ";
const body_tail = "world";
const request_headers = [_]ipc.RequestHeader{
    .{ .name = "host", .value = "demo.test" },
    .{ .name = "content-length", .value = std.fmt.comptimePrint("{d}", .{body_head.len + body_tail.len}) },
};

const prelude =
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
    \\function wait(ms) {
    \\    return new Promise((resolve) => setTimeout(resolve, ms));
    \\}
    \\
    \\async function respond(work) {
    \\    try {
    \\        await work;
    \\        return new Response("ok");
    \\    } catch (error) {
    \\        return new Response(`failed: ${error && error.stack ? error.stack : error}`, { status: 500 });
    \\    }
    \\}
    \\
;

const cancel_source = prelude ++
    \\// Runs in a later turn, when only the reader's stream reaches the Request.
    \\async function cancelWithThenGetter(reader) {
    \\    await wait(1);
    \\    churnGarbage(256);
    \\    const read = reader.read();
    \\    let lookups = 0;
    \\    Object.defineProperty(Object.prototype, "then", {
    \\        configurable: true,
    \\        get() {
    \\            lookups += 1;
    \\            churnGarbage(64);
    \\            return undefined;
    \\        },
    \\    });
    \\    let cancel;
    \\    try {
    \\        // Closing the stream settles the pending read first, which looks up
    \\        // `then` on its result; the source's cancel runs after that.
    \\        cancel = reader.cancel(new Error("stop"));
    \\    } finally {
    \\        delete Object.prototype.then;
    \\    }
    \\    churnGarbage(256);
    \\    const result = await read;
    \\    check(result.done === true && result.value === undefined, `the canceled read gave ${JSON.stringify(result)}`);
    \\    check((await cancel) === undefined, "the cancel did not fulfill with undefined");
    \\    check(lookups > 0, "settling the read looked up no then");
    \\}
    \\
    \\export default function handler(req) {
    \\    return respond(cancelWithThenGetter(req.body.getReader()));
    \\}
;

const release_source = prelude ++
    \\async function readAfterRelease(body) {
    \\    const reader = body.getReader();
    \\    const first = reader.read().then(
    \\        () => "fulfilled",
    \\        (error) => (error instanceof TypeError ? "rejected" : `rejected with ${error}`),
    \\    );
    \\    // The pull the read started is still waiting for the body's last bytes.
    \\    reader.releaseLock();
    \\    check((await first) === "rejected", "the released read did not reject with a TypeError");
    \\    // The last bytes arrive meanwhile, and the pull's chunk waits in the queue.
    \\    await wait(50);
    \\    churnGarbage(256);
    \\    const next = body.getReader();
    \\    const chunk = await next.read();
    \\    check(!chunk.done, "the chunk the pull delivered after the release was lost");
    \\    check(new TextDecoder().decode(chunk.value) === "hello world", `the next reader got ${chunk.value}`);
    \\    check((await next.read()).done === true, "the body did not end after its one chunk");
    \\}
    \\
    \\export default function handler(req) {
    \\    return respond(readAfterRelease(req.body));
    \\}
;

const tee_source = prelude ++
    \\async function teeBody(body) {
    \\    const [left, right] = body.tee();
    \\    churnGarbage(256);
    \\    const texts = await Promise.all([new Response(left).text(), new Response(right).text()]);
    \\    check(texts[0] === "hello world", `the first branch read ${texts[0]}`);
    \\    check(texts[1] === "hello world", `the second branch read ${texts[1]}`);
    \\}
    \\
    \\export default function handler(req) {
    \\    return respond(teeBody(req.body));
    \\}
;

/// Runs one request with the streamed body through `route_source` on a fresh in-process
/// runtime, sending the body's last chunk once the handler has started, and expects "ok".
fn expectBodyRouteOk(route_name: []const u8, route_source: []const u8, request_id: u64) !void {
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

    const route_specifier = try rt.routeSpecifier(std.testing.allocator, route_name);
    defer std.testing.allocator.free(route_specifier);
    const route_index = try rt.registerRoute(&runtime, route_specifier, route_source);

    const request = rt.RequestParts{
        .method = "POST",
        .path = "/body",
        .headers = &request_headers,
        .body_framing = .ingress_channel,
        .body = body_head,
        .body_end_stream = false,
    };
    var dispatch = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .route_index = route_index,
        .deadline_monotonic_ns = request_deadline_ns,
        .request = request,
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, stream_id, request);
    try rt.executeQueuedBegin(&runtime);

    const identity = ipc.ingress_channel.RequestIdentity{
        .request_id = dispatch.request_id,
        .request_generation = dispatch.request_generation,
        .request_lane_id = dispatch.request_lane_id,
        .request_slot = dispatch.request_slot,
    };
    var tail_descriptor = ipc.ingress_channel.Descriptor.requestBodyChunk(
        identity,
        stream_id,
        body_head.len,
        body_tail.len,
        true,
    );
    tail_descriptor.flag_bits |= ipc.ingress_channel.flags.inline_bytes;
    // The runtime takes the payload on every path, failure included.
    try runtime.enqueueIngressDescriptor(.{
        .allocator = std.testing.allocator,
        .descriptor = tail_descriptor,
        .payload = try std.testing.allocator.dupe(u8, body_tail),
    });

    try rt.executeUntilRequestDoneOnFakeClock(&runtime, &now_mono_ns, request_id, .{
        .budget_ns = request_budget_ns,
    });

    var response = try rt.readIngressResponse(&runtime, control_pair[1], request_id);
    defer response.deinit();
    try std.testing.expectEqualStrings("ok", response.body);
    try std.testing.expectEqual(@as(u16, 200), response.status);
}

test "a request body's cancel settles its pending read through an allocating then getter before the source's cancel runs" {
    try expectBodyRouteOk("/gc-stress-request-body-cancel.js", cancel_source, 100);
}

test "a request body's pull that completes after its reader was released leaves its chunk for the next reader" {
    try expectBodyRouteOk("/gc-stress-request-body-release.js", release_source, 200);
}

test "a request body tees by reading, so both branches get the whole body" {
    try expectBodyRouteOk("/gc-stress-request-body-tee.js", tee_source, 300);
}
