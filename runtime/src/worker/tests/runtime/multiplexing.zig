//! Covers request identity with two live requests in one worker: a
//! continuation that another request's turn resumes still runs under the
//! request that registered it. Concurrent requests may share the VM only
//! because this holds (`ensureRequestTask` in `serve/dispatch.zig`); the
//! WebKit patch `0004-microtask-owner-context` carries the owner from a
//! promise reaction's registration to its execution. Runs in `worker-test`.

const std = @import("std");
const support = @import("bindings_support");
const worker = @import("collo_worker");
const worker_shared_page = @import("collo_worker_state").page;
const rt = @import("collo_test_harness");

// The witness is the request id the log ring stores with each line, rather
// than CPU time: attribution is a discrete fact, and a microsecond delta
// would make the test a coin flip.
//
// The continuation crosses three hops. Carrying the owner on the pending
// reaction alone gets only the first right: the first `await` resumes under
// the waiter, but the continuation then enqueues through paths with no
// pending reaction (an already-settled promise takes the settled arm, and
// `queueMicrotask` has none at all). Those microtasks run after the restore
// has put the settling turn's owner back, so unless the enqueue records the
// owner as well, the identity is lost on the second hop, and a test with one
// hop would pass despite that bug.
//
// Request A awaits a promise held at module scope, the `const ready = init()`
// pattern real apps use. Request B resolves it, so A's continuation is
// enqueued during B's turn and runs there. The identity must not follow: the
// line A logs carries A's id.
test "a continuation resumed by another request keeps its own identity" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    const page_fd = try worker_shared_page.createMemfd("multiplexing-identity");
    defer std.posix.close(page_fd);
    var view = try worker_shared_page.mapReadWrite(page_fd);
    defer view.deinit();
    view.initializeCrashDefault(1, 64 * 1024 * 1024, 1);

    var now_mono_ns: u64 = 9_000;
    var runtime = try worker.Runtime.init(
        std.testing.allocator,
        &vm,
        control_pair[0],
        &view,
        try rt.createCompletionEventfd(),
        .{ .ctx = &now_mono_ns, .now_fn = rt.fakeNow },
    );
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const specifier = "/__collo_route/demo/multiplexing-identity.js";
    try rt.registerRoute(&runtime, specifier,
        \\let release;
        \\const shared = new Promise((resolve) => { release = resolve; });
        \\
        \\export default async function handle(request) {
        \\    if (new URL(request.url).pathname.endsWith("/wait")) {
        \\        await shared;
        \\        await Promise.resolve(1);
        \\        await new Promise((done) => queueMicrotask(done));
        \\        console.log("continuation-of-waiter");
        \\        return new Response("waited");
        \\    }
        \\    release();
        \\    return new Response("released");
        \\}
    );

    const waiter_id: u64 = 101;
    const releaser_id: u64 = 202;

    // A: parks on the module-scope promise and stays alive.
    var waiter = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = waiter_id,
        .route_entry_specifier = specifier,
        .request = .{ .path = "/wait" },
    });
    defer waiter.deinit();
    try rt.enqueueIngressRoute(&runtime, &waiter, 1, .{ .path = "/wait" });
    try rt.executeNextReady(&runtime);
    try std.testing.expect(runtime.requests.active.contains(waiter_id));

    // B: resolves it while A is still alive.
    var releaser = try rt.initDispatchWork(std.testing.allocator, .{
        .request_id = releaser_id,
        .route_entry_specifier = specifier,
        .request_slot = 1,
        .request = .{ .path = "/release" },
    });
    defer releaser.deinit();
    // A client opens only odd-numbered streams (RFC 9113 §5.1.1), and
    // `validateStreamBeginDescriptor` refuses any other.
    try rt.enqueueIngressRoute(&runtime, &releaser, 3, .{ .path = "/release" });
    try rt.executeNextReady(&runtime);

    try rt.executeUntilRequestDone(&runtime, releaser_id);
    try rt.executeUntilRequestDone(&runtime, waiter_id);

    var scratch: [worker_shared_page.LOG_LINE_BYTES_MAX]u8 = undefined;
    var out: [16]worker_shared_page.DrainedLogLine = undefined;
    var found_owner: ?u64 = null;
    while (true) {
        const count = try view.drainLogLinesChecked(&scratch, &out);
        if (count == 0) break;
        for (out[0..count]) |line| {
            if (std.mem.containsAtLeast(u8, line.payload, 1, "continuation-of-waiter"))
                found_owner = line.header.request_id;
        }
    }

    const owner = found_owner orelse return error.ContinuationNeverLogged;
    try std.testing.expectEqual(waiter_id, owner);
}
