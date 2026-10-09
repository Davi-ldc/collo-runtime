//! The fault plane in one process: readers of one path sharing a fault, the
//! full fault table, the rescan after a full ready queue, dropping unknown
//! fault ids and stale generations, idle eviction followed by a fresh
//! fault, the space budget, the ledger matching the copies, and the
//! encoding of read results. One test checks that a mismatched egress
//! completion takes the graceful gateway disconnect. A real Runtime and fs
//! binding run against a fault channel whose other end the test answers,
//! with copies under a directory in /tmp. The zygote-integration lane
//! (`runtime/tests/integration/zygote.zig`) covers copies under /var/task in
//! a worker's chroot and local reads of them.

const std = @import("std");
const support = @import("bindings_support");
const fault_limits = @import("collo_limits").fs_fault;
const fd_mod = @import("collo_os").fd;
const ipc = @import("collo_ipc");
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");

const fs = worker.fs;
const fault = fs.fault;

const fakeNow = rt.fakeNow;
const initDispatchWork = rt.initDispatchWork;
const socketPairType = rt.socketPairType;
const createModulePackFd = rt.createModulePackFd;
const executeNextReady = rt.executeNextReady;
const executeUntilRequestDone = rt.executeUntilRequestDone;

const fault_file_content = "hello from the fault plane";

// Bytes that no lossy string round trip preserves: NUL, 0xff and 0xfe (never
// valid in UTF-8), a lone continuation byte, and a lead byte 0xc3 with no
// continuation at the very end. Routing them through a string and
// TextEncoder would turn 0xff into EF BF BD while every ASCII-only assertion
// still passed; only the byte-for-byte checks in the two encoding tests
// below catch that.
const binary_fixture = [_]u8{ 0x00, 0xff, 0xc3, 0x41, 0x00, 0xfe, 0x80, 0xc3 };
// `binary_fixture` as `Array.from(bytes).join(",")` prints it, for the checks
// on the JavaScript side; it must change with the bytes above.
const binary_fixture_joined = "0,255,195,65,0,254,128,195";

fn expectReadable(fd: std.posix.fd_t, timeout_ms: i32, err: anyerror) !void {
    var pollfds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try std.posix.poll(&pollfds, timeout_ms);
    if (ready == 0 or (pollfds[0].revents & std.posix.POLL.IN) == 0)
        return err;
}

fn expectNotReadable(fd: std.posix.fd_t, timeout_ms: i32, err: anyerror) !void {
    var pollfds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try std.posix.poll(&pollfds, timeout_ms);
    if (ready != 0 and (pollfds[0].revents & std.posix.POLL.IN) != 0)
        return err;
}

fn recvFsFaultRequest(fd: std.posix.fd_t) !ipc.FsFaultRequest {
    try expectReadable(fd, 1000, error.MissingFsFaultRequest);
    var scratch: [ipc.max_message_bytes]u8 = undefined;
    var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, fd, &scratch);
    defer packet.deinit();
    try std.testing.expectEqual(@as(usize, 0), packet.fd_count);
    return try ipc.fs_fault.decodeRequest(std.testing.allocator, packet.bytes);
}

fn respondFsFaultOk(fd: std.posix.fd_t, fault_id: u64, bytes: []const u8) !void {
    // Sealed read-only, as the fault contract requires: the worker's
    // requireSeals rejects unsealed bytes.
    const memfd = try std.posix.memfd_create(
        "collo-test-fault-bytes",
        std.os.linux.MFD.CLOEXEC | std.os.linux.MFD.ALLOW_SEALING,
    );
    defer std.posix.close(memfd);
    try fd_mod.writeAllRaw(memfd, bytes);
    try fd_mod.addSeals(memfd, fd_mod.memfd_readonly_seals);
    try ipc.sendFsFaultResponse(
        fd,
        .{ .fault_id = fault_id, .status = .ok },
        fd_mod.FdRef.fromRaw(memfd),
    );
}

const IndexFile = struct {
    path: []const u8,
    content: []const u8,
};

const default_index_files = [_]IndexFile{
    .{ .path = "data/hello.txt", .content = fault_file_content },
};

fn buildFaultFixtureIndexBytes(allocator: std.mem.Allocator, files: []const IndexFile) ![]u8 {
    const entries = try allocator.alloc(fs.fs_index.File, files.len);
    defer allocator.free(entries);
    for (files, entries) |file, *entry| {
        entry.* = .{ .path = file.path, .size = file.content.len, .sha256 = undefined };
        std.crypto.hash.sha2.Sha256.hash(file.content, &entry.sha256, .{});
    }
    return fs.fs_index.buildIndexBytes(allocator, 1_730_000_000_123, entries);
}

const FaultFixture = struct {
    index_bytes: []u8,
    /// [0] is the worker end, installed as the fault channel; [1] is the end
    /// the test answers on.
    pair: [2]std.posix.fd_t,
    tmp_root: []u8,

    fn init(allocator: std.mem.Allocator) !FaultFixture {
        return initWithFiles(allocator, &default_index_files);
    }

    fn initWithFiles(allocator: std.mem.Allocator, files: []const IndexFile) !FaultFixture {
        const index_bytes = try buildFaultFixtureIndexBytes(allocator, files);
        errdefer allocator.free(index_bytes);
        const pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
        errdefer {
            std.posix.close(pair[0]);
            std.posix.close(pair[1]);
        }
        const tmp_root = try std.fmt.allocPrint(allocator, "/tmp/collo-fs-fault-test-{d}-{d}", .{
            std.os.linux.getpid(),
            std.time.nanoTimestamp(),
        });
        errdefer allocator.free(tmp_root);
        try std.fs.makeDirAbsolute(tmp_root);
        errdefer std.fs.deleteTreeAbsolute(tmp_root) catch {};
        try fs.installForTestWithFault(index_bytes, fs.deploy_root, pair[0], tmp_root);
        return .{
            .index_bytes = index_bytes,
            .pair = pair,
            .tmp_root = tmp_root,
        };
    }

    fn deinit(self: *FaultFixture, allocator: std.mem.Allocator) void {
        fs.uninstallForTest();
        std.posix.close(self.pair[0]);
        std.posix.close(self.pair[1]);
        std.fs.deleteTreeAbsolute(self.tmp_root) catch {};
        allocator.free(self.tmp_root);
        allocator.free(self.index_bytes);
        self.* = undefined;
    }
};

/// Registers the pack in `route_fd` as the runtime's route at
/// `route_entry_specifier`, unless the runtime holds it already, and
/// enqueues one request for it.
fn registerAndEnqueueRoute(
    runtime: *worker.Runtime,
    request_id: u64,
    route_entry_specifier: []const u8,
    route_fd: std.posix.fd_t,
    path: []const u8,
    deadline_monotonic_ns: u64,
) !void {
    const route_index = try rt.registerRoutePack(runtime, route_fd, route_entry_specifier);
    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .route_index = route_index,
        .deadline_monotonic_ns = deadline_monotonic_ns,
        .request = .{ .path = path },
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(runtime, &dispatch, 1, .{ .path = path });
}

fn completeRequestResponse(runtime: *worker.Runtime, control_fd: std.posix.fd_t, request_id: u64) ![]u8 {
    try executeUntilRequestDone(runtime, request_id);
    return rt.readIngressResponseBody(runtime, control_fd, request_id);
}

fn readModuleSource(comptime deploy_path: []const u8) []const u8 {
    return "import fs from \"node:fs\";\n" ++
        "export default async function handle() {\n" ++
        "    const content = await fs.promises.readFile(\"" ++ deploy_path ++ "\");\n" ++
        "    return new Response(content);\n" ++
        "}\n";
}

// Reads with "utf8" because readFile without an encoding resolves a
// Uint8Array, and the callers check the "resolved:" prefix joined to the
// text. Reads without an encoding have their own test below.
fn readModuleSourceCatching(comptime deploy_path: []const u8) []const u8 {
    return "import fs from \"node:fs\";\n" ++
        "export default async function handle() {\n" ++
        "    try {\n" ++
        "        const content = await fs.promises.readFile(\"" ++ deploy_path ++ "\", \"utf8\");\n" ++
        "        return new Response(\"resolved:\" + content);\n" ++
        "    } catch (e) {\n" ++
        "        return new Response(\"code:\" + e.code);\n" ++
        "    }\n" ++
        "}\n";
}

/// One async fault from end to end: registers and enqueues the route
/// (`registerAndEnqueueRoute`), runs the loop until the fault is in flight,
/// answers it with `content`, settles it, and returns the response body,
/// which the caller frees. A read that sends no fault fails here with
/// `error.MissingFsFaultRequest`, so a successful round trip proves a fault
/// was sent.
fn faultRoundTrip(
    runtime: *worker.Runtime,
    server_fd: std.posix.fd_t,
    control_fd: std.posix.fd_t,
    request_id: u64,
    route_entry_specifier: []const u8,
    route_fd: std.posix.fd_t,
    path: []const u8,
    deadline_monotonic_ns: u64,
    content: []const u8,
) ![]u8 {
    try registerAndEnqueueRoute(runtime, request_id, route_entry_specifier, route_fd, path, deadline_monotonic_ns);
    try pumpUntilFaultTasks(runtime, 1);
    var request = try recvFsFaultRequest(server_fd);
    defer request.deinit();
    try respondFsFaultOk(server_fd, request.fault_id, content);
    try runtime.collectFsFaultResponse();
    return completeRequestResponse(runtime, control_fd, request_id);
}

/// Runs the loop until `count` faults are in flight. The first `.request`
/// work item only evaluates the route module; its settlement queues the
/// request again, and the second item runs the handler, where readFile sends
/// the fault. The pump therefore alternates settlement collection with work
/// items.
fn pumpUntilFaultTasks(runtime: *worker.Runtime, count: usize) !void {
    var attempts: usize = 0;
    while (runtime.fs_fault.tasks.count() < count) : (attempts += 1) {
        if (attempts > 1_000)
            return error.FsFaultNeverScheduled;
        runtime.collectModuleSettlements();
        try executeNextReady(runtime);
    }
}

/// Runs every ready item. The parked request queues nothing more until its
/// promise settles, so a later step that fills the queue discards only its
/// own filler items.
fn drainReadyQueue(runtime: *worker.Runtime) !void {
    while (!runtime.scheduler.ready_queue.isEmpty())
        try executeNextReady(runtime);
}

test "T1 fs fault coalesces two async readers of one path into one wire fault" {
    var fixture = try FaultFixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);

    var vm = try support.createVm();
    defer vm.deinit();
    // A worker child enables node:fs at boot (`zygote/child_boot.zig`); in
    // one process the test enables it.
    try vm.enableNodeFsForWorker();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    // Both reads use "utf8" so that `a === b` compares text: Uint8Arrays
    // compare by identity, and each waiter gets its own array, as in Node.
    // The coalescing itself is checked below: one task, two waiters, one
    // request sent.
    const specifier = "/__collo_route/demo/fs-fault-coalesce.js";
    const route_fd = try createModulePackFd(specifier,
        \\import fs from "node:fs";
        \\export default async function handle() {
        \\    const [a, b] = await Promise.all([
        \\        fs.promises.readFile("data/hello.txt", "utf8"),
        \\        fs.promises.readFile("data/hello.txt", "utf8"),
        \\    ]);
        \\    return new Response(JSON.stringify({ same: a === b, content: a }));
        \\}
    );
    defer std.posix.close(route_fd);

    try registerAndEnqueueRoute(&runtime, 601, specifier, route_fd, "/fs-fault-coalesce", 10_000);
    try pumpUntilFaultTasks(&runtime, 1);

    // Two readers share one task with two waiters, and one request is sent.
    try std.testing.expectEqual(@as(usize, 1), runtime.fs_fault.tasks.count());
    var request = try recvFsFaultRequest(fixture.pair[1]);
    defer request.deinit();
    try std.testing.expectEqualStrings("data/hello.txt", request.path);
    try std.testing.expectEqual(@as(u64, 601), request.request_id);
    const task = runtime.fs_fault.tasks.getPtr(request.fault_id) orelse
        return error.MissingFsFaultTask;
    try std.testing.expectEqual(@as(usize, 2), task.waiters.items.len);
    try expectNotReadable(fixture.pair[1], 100, error.UnexpectedSecondFsFaultRequest);

    try respondFsFaultOk(fixture.pair[1], request.fault_id, fault_file_content);
    try runtime.collectFsFaultResponse();

    const response = try completeRequestResponse(&runtime, control_pair[1], 601);
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"same\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, fault_file_content));

    // Settled: the table is empty and the copy is under the materialize root.
    try std.testing.expectEqual(@as(usize, 0), runtime.fs_fault.tasks.count());
    const physical = try std.fmt.allocPrint(std.testing.allocator, "{s}/data/hello.txt", .{fixture.tmp_root});
    defer std.testing.allocator.free(physical);
    const materialized = try std.fs.openFileAbsolute(physical, .{});
    defer materialized.close();
    const pinned = try materialized.readToEndAlloc(std.testing.allocator, 4096);
    defer std.testing.allocator.free(pinned);
    try std.testing.expectEqualStrings(fault_file_content, pinned);
}

test "T2 fs fault full table rejects cleanly and full queue re-arms via rescan" {
    var fixture = try FaultFixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);

    var vm = try support.createVm();
    defer vm.deinit();
    // A worker child enables node:fs at boot (`zygote/child_boot.zig`); in
    // one process the test enables it.
    try vm.enableNodeFsForWorker();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const specifier = "/__collo_route/demo/fs-fault-backpressure.js";
    const route_fd = try createModulePackFd(specifier,
        \\import fs from "node:fs";
        \\export default async function handle() {
        \\    try {
        \\        const content = await fs.promises.readFile("data/hello.txt", "utf8");
        \\        return new Response("resolved:" + content);
        \\    } catch (e) {
        \\        return new Response("code:" + e.code);
        \\    }
        \\}
    );
    defer std.posix.close(route_fd);

    // First, with the table full, a new fault rejects the read's promise,
    // sending nothing and leaving no state behind.
    const filler_base: u64 = 1_000_000;
    var filler_id: u64 = filler_base;
    while (runtime.fs_fault.tasks.count() < fault.max_faults_per_worker) : (filler_id += 1) {
        const filler_path = try std.fmt.allocPrint(std.testing.allocator, "filler/{d}", .{filler_id});
        errdefer std.testing.allocator.free(filler_path);
        try runtime.fs_fault.tasks.putNoClobber(std.testing.allocator, filler_id, .{
            .id = filler_id,
            .path = filler_path,
            .entry = 0,
            .waiters = .empty,
            .outcome = .pending,
            .done = false,
            .queued = false,
        });
    }

    try registerAndEnqueueRoute(&runtime, 611, specifier, route_fd, "/fs-fault-cap", 10_000);
    const cap_response = try completeRequestResponse(&runtime, control_pair[1], 611);
    defer std.testing.allocator.free(cap_response);
    try std.testing.expect(std.mem.containsAtLeast(u8, cap_response, 1, "code:EIO"));
    // The read failed before anything was sent.
    try expectNotReadable(fixture.pair[1], 100, error.UnexpectedFsFaultRequestAtCap);

    var drain_id: u64 = filler_base;
    while (drain_id < filler_id) : (drain_id += 1) {
        var removed = runtime.fs_fault.tasks.fetchRemove(drain_id) orelse continue;
        removed.value.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 0), runtime.fs_fault.tasks.count());

    // Then a response arrives while the ready queue and its backlog are full.
    // The completion waits, with the rescan flag set and the task done but
    // not queued, until collectFsFaultCompletions queues it once there is
    // room.
    try registerAndEnqueueRoute(&runtime, 612, specifier, route_fd, "/fs-fault-rescan", 10_000);
    try pumpUntilFaultTasks(&runtime, 1);
    var request = try recvFsFaultRequest(fixture.pair[1]);
    defer request.deinit();
    try respondFsFaultOk(fixture.pair[1], request.fault_id, fault_file_content);

    try drainReadyQueue(&runtime);
    while (runtime.scheduler.ready_queue.tryPush(.{ .timer_callback = 987_654 })) {}
    while (runtime.scheduler.ready_backlog.tryPush(.{ .timer_callback = 987_654 })) {}

    try runtime.collectFsFaultResponse();
    try std.testing.expect(runtime.fs_fault.rescan_needed);
    const parked = runtime.fs_fault.tasks.getPtr(request.fault_id) orelse
        return error.MissingFsFaultTask;
    try std.testing.expect(parked.done);
    try std.testing.expect(!parked.queued);

    // Room opens: the filler items are discarded, not run.
    while (runtime.scheduler.ready_queue.pop()) |_| {}
    while (runtime.scheduler.ready_backlog.pop()) |_| {}
    runtime.collectFsFaultCompletions();
    try std.testing.expect(!runtime.fs_fault.rescan_needed);

    const response = try completeRequestResponse(&runtime, control_pair[1], 612);
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "resolved:"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, fault_file_content));
}

test "T3 fs fault correlation drops unknown fault ids and stale generations fail-closed" {
    var fixture = try FaultFixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);

    var vm = try support.createVm();
    defer vm.deinit();
    // A worker child enables node:fs at boot (`zygote/child_boot.zig`); in
    // one process the test enables it.
    try vm.enableNodeFsForWorker();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const specifier = "/__collo_route/demo/fs-fault-correlation.js";
    const route_fd = try createModulePackFd(specifier,
        \\import fs from "node:fs";
        \\export default async function handle() {
        \\    const content = await fs.promises.readFile("data/hello.txt");
        \\    return new Response(content);
        \\}
    );
    defer std.posix.close(route_fd);

    try registerAndEnqueueRoute(&runtime, 701, specifier, route_fd, "/fs-fault-correlation", 10_000);
    try pumpUntilFaultTasks(&runtime, 1);
    try drainReadyQueue(&runtime);
    var request = try recvFsFaultRequest(fixture.pair[1]);
    defer request.deinit();

    // A response with an unknown fault id is dropped with its fd; nothing
    // settles and the task is untouched.
    try respondFsFaultOk(fixture.pair[1], request.fault_id + 12_345, fault_file_content);
    try runtime.collectFsFaultResponse();
    try std.testing.expectEqual(@as(usize, 1), runtime.fs_fault.tasks.count());
    const pending = runtime.fs_fault.tasks.getPtr(request.fault_id) orelse
        return error.MissingFsFaultTask;
    try std.testing.expect(!pending.done);
    try std.testing.expect(runtime.scheduler.ready_queue.isEmpty());
    try std.testing.expect(runtime.requests.active.contains(701));

    // The request moves to a new generation before the settle, so its
    // waiter is skipped and the table empties.
    const request_ctx = runtime.requests.active.get(701) orelse
        return error.MissingRequestContext;
    request_ctx.request_generation += 1;

    try respondFsFaultOk(fixture.pair[1], request.fault_id, fault_file_content);
    try runtime.collectFsFaultResponse();
    try executeNextReady(&runtime);
    try std.testing.expectEqual(@as(usize, 0), runtime.fs_fault.tasks.count());
    // The waiter never settled, so the request stays active until its
    // deadline.
    try std.testing.expect(runtime.requests.active.contains(701));
}

test "T4 F2-2 egress completion id mismatch detaches the worker and keeps its loop running" {
    var vm = try support.createVm();
    defer vm.deinit();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    // Both ends of a real shared egress session; this test plays the gateway.
    var wake_set = try ipc.egress_shared.WakeSet.create();
    defer wake_set.deinit();
    var session = try ipc.egress_shared.createSessionForWorker(&wake_set);
    defer session.deinit();
    var gateway_raw = try rt.dupSharedFds(session.rawForGateway());
    errdefer gateway_raw.close();
    var gateway_endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
    defer gateway_endpoint.deinit();
    gateway_endpoint.command.setSession(1, 1);
    gateway_endpoint.completion.setSession(1, 1);
    gateway_endpoint.body_pool.setSession(1, 1);
    gateway_endpoint.upload_pool.setSession(1, 1);
    var worker_raw = session.takeWorkerHalf();
    defer worker_raw.close();

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
        .egress_shared_fds = &worker_raw,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    // A parked request owning a live fetch body under fetch_id 7.
    const specifier = "/__collo_route/demo/fs-fault-f22.js";
    const route_fd = try createModulePackFd(specifier,
        \\export default function handle() {
        \\    return new Promise(() => {});
        \\}
    );
    defer std.posix.close(route_fd);
    try registerAndEnqueueRoute(&runtime, 801, specifier, route_fd, "/f22", 10_000);
    try executeNextReady(&runtime);
    try std.testing.expect(runtime.requests.active.contains(801));
    const request_ctx = runtime.requests.active.get(801) orelse
        return error.MissingRequestContext;
    const identity = try runtime.registerFetchBodyOpen(request_ctx, 7, null);

    // The gateway sends a completion whose ids do not match: the body exists
    // under fetch_id 7, but the packet claims fetch_id 8.
    var end_message = ipc.EgressBodyEnd.init(8, identity.body_id);
    _ = try gateway_endpoint.completion.writePacket(std.mem.asBytes(&end_message));

    // The malformed packet detaches the worker: its fetches settle and its
    // endpoint is released, while the loop keeps serving requests until the
    // server attaches a new session.
    _ = try runtime.collectEgressGatewayPacketsBounded(8);
    try std.testing.expect(runtime.egress.state.shared == null);
    try std.testing.expect(runtime.core.running);
    try std.testing.expect(runtime.requests.active.contains(801));
}

test "D3 idle materialized deploy file is unlinked at a turn boundary and the next read re-faults" {
    var fixture = try FaultFixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);

    var vm = try support.createVm();
    defer vm.deinit();
    // A worker child enables node:fs at boot (`zygote/child_boot.zig`); in
    // one process the test enables it.
    try vm.enableNodeFsForWorker();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const read_specifier = "/__collo_route/demo/fs-fault-idle-read.js";
    const read_fd = try createModulePackFd(read_specifier, readModuleSource("data/hello.txt"));
    defer std.posix.close(read_fd);
    const tick_specifier = "/__collo_route/demo/fs-fault-idle-tick.js";
    const tick_fd = try createModulePackFd(tick_specifier,
        \\export default function handle() {
        \\    return new Response("tick");
        \\}
    );
    defer std.posix.close(tick_fd);

    // A first read faults the file in, and the ledger records it.
    const first_response = try faultRoundTrip(&runtime, fixture.pair[1], control_pair[1], 901, read_specifier, read_fd, "/idle-1", 10_000, fault_file_content);
    defer std.testing.allocator.free(first_response);
    try std.testing.expect(std.mem.containsAtLeast(u8, first_response, 1, fault_file_content));

    const ledger = fs.materializedLedger() orelse return error.MissingLedger;
    try std.testing.expectEqual(@as(usize, 1), ledger.count());
    try std.testing.expectEqual(@as(u64, fault_file_content.len), ledger.total_bytes);
    const physical = try std.fmt.allocPrint(std.testing.allocator, "{s}/data/hello.txt", .{fixture.tmp_root});
    defer std.testing.allocator.free(physical);
    (try std.fs.openFileAbsolute(physical, .{})).close();

    // Past the idle threshold, the next finished request's sweep
    // (`finishRequest` calls `sweepIdleMaterialized`) deletes the copy and
    // empties the ledger.
    now_mono_ns = fault_limits.materialized_idle_eviction_ns + std.time.ns_per_s;
    try registerAndEnqueueRoute(&runtime, 902, tick_specifier, tick_fd, "/idle-tick", now_mono_ns + 10 * std.time.ns_per_s);
    const tick_response = try completeRequestResponse(&runtime, control_pair[1], 902);
    defer std.testing.allocator.free(tick_response);
    try std.testing.expect(std.mem.containsAtLeast(u8, tick_response, 1, "tick"));
    try std.testing.expectEqual(@as(usize, 0), ledger.count());
    try std.testing.expectEqual(@as(u64, 0), ledger.total_bytes);
    try std.testing.expectError(error.FileNotFound, std.fs.openFileAbsolute(physical, .{}));

    // The next read faults again, which the round trip requires, and
    // returns the same bytes; the copy and its ledger entry are back.
    const second_response = try faultRoundTrip(&runtime, fixture.pair[1], control_pair[1], 903, read_specifier, read_fd, "/idle-2", now_mono_ns + 10 * std.time.ns_per_s, fault_file_content);
    defer std.testing.allocator.free(second_response);
    try std.testing.expect(std.mem.containsAtLeast(u8, second_response, 1, fault_file_content));
    try std.testing.expectEqual(@as(usize, 1), ledger.count());
    (try std.fs.openFileAbsolute(physical, .{})).close();
}

test "D3 space guard evicts LRU materializations until a new fault fits and rejects over-budget files" {
    const content_a = "A" ** 26;
    const content_b = "B" ** 26;
    const content_c = "C" ** 60;
    var fixture = try FaultFixture.initWithFiles(std.testing.allocator, &.{
        .{ .path = "data/a.txt", .content = content_a },
        .{ .path = "data/b.txt", .content = content_b },
        .{ .path = "data/c.txt", .content = content_c },
    });
    defer fixture.deinit(std.testing.allocator);
    // An 80-byte tmpfs with `materialize_budget_percent` leaves a 40-byte
    // budget: room for either 26-byte file but not both, and less than the
    // 60 bytes of c.
    fs.setTmpfsSizeForTest(80);

    var vm = try support.createVm();
    defer vm.deinit();
    // A worker child enables node:fs at boot (`zygote/child_boot.zig`); in
    // one process the test enables it.
    try vm.enableNodeFsForWorker();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const read_a_specifier = "/__collo_route/demo/fs-fault-budget-a.js";
    const read_a_fd = try createModulePackFd(read_a_specifier, readModuleSource("data/a.txt"));
    defer std.posix.close(read_a_fd);
    const read_b_specifier = "/__collo_route/demo/fs-fault-budget-b.js";
    const read_b_fd = try createModulePackFd(read_b_specifier, readModuleSource("data/b.txt"));
    defer std.posix.close(read_b_fd);
    const read_c_specifier = "/__collo_route/demo/fs-fault-budget-c.js";
    const read_c_fd = try createModulePackFd(read_c_specifier, readModuleSourceCatching("data/c.txt"));
    defer std.posix.close(read_c_fd);

    // a is copied and takes 26 of the 40 bytes.
    const a_response = try faultRoundTrip(&runtime, fixture.pair[1], control_pair[1], 921, read_a_specifier, read_a_fd, "/budget-a", 10_000, content_a);
    defer std.testing.allocator.free(a_response);
    try std.testing.expect(std.mem.containsAtLeast(u8, a_response, 1, content_a));

    const ledger = fs.materializedLedger() orelse return error.MissingLedger;
    try std.testing.expectEqual(@as(usize, 1), ledger.count());
    try std.testing.expectEqual(@as(u64, content_a.len), ledger.total_bytes);
    const physical_a = try std.fmt.allocPrint(std.testing.allocator, "{s}/data/a.txt", .{fixture.tmp_root});
    defer std.testing.allocator.free(physical_a);
    (try std.fs.openFileAbsolute(physical_a, .{})).close();

    // a keeps its last read at time 0, so it is the least recently read
    // copy.
    now_mono_ns = std.time.ns_per_s;

    // a and b together would need 52 bytes, so a is evicted before b is
    // copied.
    const b_response = try faultRoundTrip(&runtime, fixture.pair[1], control_pair[1], 922, read_b_specifier, read_b_fd, "/budget-b", now_mono_ns + 10 * std.time.ns_per_s, content_b);
    defer std.testing.allocator.free(b_response);
    try std.testing.expect(std.mem.containsAtLeast(u8, b_response, 1, content_b));
    try std.testing.expectEqual(@as(usize, 1), ledger.count());
    try std.testing.expectEqual(@as(u64, content_b.len), ledger.total_bytes);
    try std.testing.expectError(error.FileNotFound, std.fs.openFileAbsolute(physical_a, .{}));
    const physical_b = try std.fmt.allocPrint(std.testing.allocator, "{s}/data/b.txt", .{fixture.tmp_root});
    defer std.testing.allocator.free(physical_b);
    (try std.fs.openFileAbsolute(physical_b, .{})).close();

    // c is larger than the whole budget, which no eviction could fix, so
    // its read is rejected before anything is sent.
    try registerAndEnqueueRoute(&runtime, 923, read_c_specifier, read_c_fd, "/budget-c", now_mono_ns + 10 * std.time.ns_per_s);
    const c_response = try completeRequestResponse(&runtime, control_pair[1], 923);
    defer std.testing.allocator.free(c_response);
    try std.testing.expect(std.mem.containsAtLeast(u8, c_response, 1, "code:EIO"));
    try expectNotReadable(fixture.pair[1], 100, error.UnexpectedFsFaultRequestOverBudget);
    try std.testing.expectEqual(@as(usize, 1), ledger.count());
}

test "D3 ledger matches materialized bytes and tenant files are never evicted" {
    const content_a = "A" ** 26;
    const content_b = "B" ** 30;
    var fixture = try FaultFixture.initWithFiles(std.testing.allocator, &.{
        .{ .path = "data/a.txt", .content = content_a },
        .{ .path = "data/b.txt", .content = content_b },
    });
    defer fixture.deinit(std.testing.allocator);

    var vm = try support.createVm();
    defer vm.deinit();
    // A worker child enables node:fs at boot (`zygote/child_boot.zig`); in
    // one process the test enables it.
    try vm.enableNodeFsForWorker();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const read_a_specifier = "/__collo_route/demo/fs-fault-ledger-a.js";
    const read_a_fd = try createModulePackFd(read_a_specifier, readModuleSource("data/a.txt"));
    defer std.posix.close(read_a_fd);
    const read_b_specifier = "/__collo_route/demo/fs-fault-ledger-b.js";
    const read_b_fd = try createModulePackFd(read_b_specifier, readModuleSource("data/b.txt"));
    defer std.posix.close(read_b_fd);
    const tick_specifier = "/__collo_route/demo/fs-fault-ledger-tick.js";
    const tick_fd = try createModulePackFd(tick_specifier,
        \\export default function handle() {
        \\    return new Response("tick");
        \\}
    );
    defer std.posix.close(tick_fd);
    // The tenant writes through the real router. The materialize root is
    // under /tmp, so the write lands in the same directory as the copies,
    // the hardest case for eviction deleting only what the ledger lists.
    const tenant_specifier = "/__collo_route/demo/fs-fault-ledger-tenant.js";
    const tenant_source = try std.fmt.allocPrint(std.testing.allocator,
        \\import fs from "node:fs";
        \\export default function handle() {{
        \\    fs.writeFileSync("{s}/data/tenant-note.txt", "tenant bytes");
        \\    return new Response("wrote");
        \\}}
    , .{fixture.tmp_root});
    defer std.testing.allocator.free(tenant_source);
    const tenant_fd = try createModulePackFd(tenant_specifier, tenant_source);
    defer std.posix.close(tenant_fd);

    // After two copies, the ledger's count and byte total match the index
    // sizes.
    const a_response = try faultRoundTrip(&runtime, fixture.pair[1], control_pair[1], 941, read_a_specifier, read_a_fd, "/ledger-a", 10_000, content_a);
    defer std.testing.allocator.free(a_response);
    const b_response = try faultRoundTrip(&runtime, fixture.pair[1], control_pair[1], 942, read_b_specifier, read_b_fd, "/ledger-b", 10_000, content_b);
    defer std.testing.allocator.free(b_response);
    const ledger = fs.materializedLedger() orelse return error.MissingLedger;
    try std.testing.expectEqual(@as(usize, 2), ledger.count());
    try std.testing.expectEqual(@as(u64, content_a.len + content_b.len), ledger.total_bytes);

    try registerAndEnqueueRoute(&runtime, 943, tenant_specifier, tenant_fd, "/ledger-tenant", 10_000);
    const tenant_response = try completeRequestResponse(&runtime, control_pair[1], 943);
    defer std.testing.allocator.free(tenant_response);
    try std.testing.expect(std.mem.containsAtLeast(u8, tenant_response, 1, "wrote"));
    const tenant_physical = try std.fmt.allocPrint(std.testing.allocator, "{s}/data/tenant-note.txt", .{fixture.tmp_root});
    defer std.testing.allocator.free(tenant_physical);
    (try std.fs.openFileAbsolute(tenant_physical, .{})).close();

    // The idle sweep evicts both copies and nothing else: the tenant's file
    // in the same directory survives.
    now_mono_ns = fault_limits.materialized_idle_eviction_ns + std.time.ns_per_s;
    try registerAndEnqueueRoute(&runtime, 944, tick_specifier, tick_fd, "/ledger-tick", now_mono_ns + 10 * std.time.ns_per_s);
    const tick_response = try completeRequestResponse(&runtime, control_pair[1], 944);
    defer std.testing.allocator.free(tick_response);
    try std.testing.expect(std.mem.containsAtLeast(u8, tick_response, 1, "tick"));

    try std.testing.expectEqual(@as(usize, 0), ledger.count());
    try std.testing.expectEqual(@as(u64, 0), ledger.total_bytes);
    const physical_a = try std.fmt.allocPrint(std.testing.allocator, "{s}/data/a.txt", .{fixture.tmp_root});
    defer std.testing.allocator.free(physical_a);
    try std.testing.expectError(error.FileNotFound, std.fs.openFileAbsolute(physical_a, .{}));
    const physical_b = try std.fmt.allocPrint(std.testing.allocator, "{s}/data/b.txt", .{fixture.tmp_root});
    defer std.testing.allocator.free(physical_b);
    try std.testing.expectError(error.FileNotFound, std.fs.openFileAbsolute(physical_b, .{}));

    const tenant_file = try std.fs.openFileAbsolute(tenant_physical, .{});
    defer tenant_file.close();
    const tenant_bytes = try tenant_file.readToEndAlloc(std.testing.allocator, 4096);
    defer std.testing.allocator.free(tenant_bytes);
    try std.testing.expectEqualStrings("tenant bytes", tenant_bytes);
}

// On the async fault path, readFile without an encoding resolves a
// Uint8Array holding the copy's bytes, which the binding's chained read in
// `fs.cpp` returns, and TextDecoder turns it into text. A second, binary
// file in the same request checks the bytes one by one (`binary_fixture`).
test "F5 async readFile without encoding resolves the faulted bytes as a Uint8Array" {
    var fixture = try FaultFixture.initWithFiles(std.testing.allocator, &.{
        .{ .path = "data/blob.bin", .content = &binary_fixture },
        .{ .path = "data/hello.txt", .content = fault_file_content },
    });
    defer fixture.deinit(std.testing.allocator);

    var vm = try support.createVm();
    defer vm.deinit();
    // A worker child enables node:fs at boot (`zygote/child_boot.zig`); in
    // one process the test enables it.
    try vm.enableNodeFsForWorker();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    const specifier = "/__collo_route/demo/fs-fault-f5-bytes.js";
    const route_fd = try createModulePackFd(specifier,
        \\import fs from "node:fs";
        \\export default async function handle() {
        \\    const [content, blob] = await Promise.all([
        \\        fs.promises.readFile("data/hello.txt"),
        \\        fs.promises.readFile("data/blob.bin"),
        \\    ]);
        \\    const text = new TextDecoder().decode(content);
        \\    return new Response(JSON.stringify({
        \\        isU8: content instanceof Uint8Array,
        \\        text,
        \\        blobIsU8: blob instanceof Uint8Array,
        \\        blobBytes: Array.from(blob).join(","),
        \\    }));
        \\}
    );
    defer std.posix.close(route_fd);

    // Two distinct paths send two faults from one handler turn, since
    // coalescing is per path. Their order on the channel is not fixed; both
    // are answered and one response is collected per packet.
    try registerAndEnqueueRoute(&runtime, 951, specifier, route_fd, "/f5-bytes", 10_000);
    try pumpUntilFaultTasks(&runtime, 2);
    var first_request = try recvFsFaultRequest(fixture.pair[1]);
    defer first_request.deinit();
    var second_request = try recvFsFaultRequest(fixture.pair[1]);
    defer second_request.deinit();
    const hello_first = std.mem.eql(u8, first_request.path, "data/hello.txt");
    const hello_request = if (hello_first) &first_request else &second_request;
    const blob_request = if (hello_first) &second_request else &first_request;
    try std.testing.expectEqualStrings("data/hello.txt", hello_request.path);
    try std.testing.expectEqualStrings("data/blob.bin", blob_request.path);
    try respondFsFaultOk(fixture.pair[1], hello_request.fault_id, fault_file_content);
    try respondFsFaultOk(fixture.pair[1], blob_request.fault_id, &binary_fixture);
    try runtime.collectFsFaultResponse();
    try runtime.collectFsFaultResponse();

    const response = try completeRequestResponse(&runtime, control_pair[1], 951);
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"isU8\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"text\":\"" ++ fault_file_content ++ "\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"blobIsU8\":true"));
    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        response,
        1,
        "\"blobBytes\":\"" ++ binary_fixture_joined ++ "\"",
    ));
}

// The sync surface on the /tmp scratch: no encoding gives a Uint8Array,
// "utf8" or { encoding: "utf-8" } gives a string, a Uint8Array written with
// writeFileSync reads back byte for byte (checked on `binary_fixture`), and
// any other encoding throws ERR_INVALID_ARG_VALUE, because Buffer is outside
// the supported surface and TextDecoder covers text. A path that is a
// number or a Symbol, and data that is neither a string nor a Uint8Array,
// throw ERR_INVALID_ARG_TYPE instead of being coerced into a lookup.
test "F5 readFileSync encoding contract and Uint8Array write round trip on the scratch" {
    var fixture = try FaultFixture.init(std.testing.allocator);
    defer fixture.deinit(std.testing.allocator);

    var vm = try support.createVm();
    defer vm.deinit();
    // A worker child enables node:fs at boot (`zygote/child_boot.zig`); in
    // one process the test enables it.
    try vm.enableNodeFsForWorker();

    const control_pair = try socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);

    var now_mono_ns: u64 = 0;
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    // Scratch writes go through the real router into the fixture's
    // directory under /tmp, as in the tenant-file test above.
    const specifier = "/__collo_route/demo/fs-f5-sync-encoding.js";
    const source = try std.fmt.allocPrint(std.testing.allocator,
        \\import fs from "node:fs";
        \\export default function handle() {{
        \\    const dir = "{s}";
        \\    fs.writeFileSync(dir + "/f5.txt", "caf\u{{00e9}}");
        \\    const bytes = fs.readFileSync(dir + "/f5.txt");
        \\    const text = fs.readFileSync(dir + "/f5.txt", "utf8");
        \\    const optText = fs.readFileSync(dir + "/f5.txt", {{ encoding: "utf-8" }});
        \\    fs.writeFileSync(dir + "/f5-copy.bin", bytes);
        \\    const copy = fs.readFileSync(dir + "/f5-copy.bin");
        \\    let badCode = "none";
        \\    try {{
        \\        fs.readFileSync(dir + "/f5.txt", "latin1");
        \\        badCode = "read";
        \\    }} catch (e) {{
        \\        badCode = e.code;
        \\    }}
        \\    const sameBytes = copy.length === bytes.length && copy.every((v, i) => v === bytes[i]);
        \\    const raw = new Uint8Array([{s}]);
        \\    fs.writeFileSync(dir + "/f5-raw.bin", raw);
        \\    const rawBack = fs.readFileSync(dir + "/f5-raw.bin");
        \\    const rawExact = rawBack instanceof Uint8Array && rawBack.length === raw.length
        \\        && rawBack.every((v, i) => v === raw[i]);
        \\    const rawBytes = Array.from(rawBack).join(",");
        \\    let pathCode = "none";
        \\    try {{
        \\        fs.statSync(123);
        \\        pathCode = "stat";
        \\    }} catch (e) {{
        \\        pathCode = e.code;
        \\    }}
        \\    let symbolCode = "none";
        \\    try {{
        \\        fs.statSync(Symbol("x"));
        \\        symbolCode = "stat";
        \\    }} catch (e) {{
        \\        symbolCode = e.code;
        \\    }}
        \\    let dataCode = "none";
        \\    try {{
        \\        fs.writeFileSync(dir + "/f5-bad.bin", 123);
        \\        dataCode = "write";
        \\    }} catch (e) {{
        \\        dataCode = e.code;
        \\    }}
        \\    return new Response(JSON.stringify({{
        \\        isU8: bytes instanceof Uint8Array,
        \\        byteLen: bytes.length,
        \\        text,
        \\        optText,
        \\        copyIsU8: copy instanceof Uint8Array,
        \\        sameBytes,
        \\        badCode,
        \\        rawExact,
        \\        rawBytes,
        \\        pathCode,
        \\        symbolCode,
        \\        dataCode,
        \\    }}));
        \\}}
    , .{ fixture.tmp_root, binary_fixture_joined });
    defer std.testing.allocator.free(source);
    const route_fd = try createModulePackFd(specifier, source);
    defer std.posix.close(route_fd);

    try registerAndEnqueueRoute(&runtime, 952, specifier, route_fd, "/f5-sync-encoding", 10_000);
    const response = try completeRequestResponse(&runtime, control_pair[1], 952);
    defer std.testing.allocator.free(response);
    // "café" is 5 UTF-8 bytes (é = 2).
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"isU8\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"byteLen\":5"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"text\":\"café\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"optText\":\"café\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"copyIsU8\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"sameBytes\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"badCode\":\"ERR_INVALID_ARG_VALUE\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"rawExact\":true"));
    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        response,
        1,
        "\"rawBytes\":\"" ++ binary_fixture_joined ++ "\"",
    ));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"pathCode\":\"ERR_INVALID_ARG_TYPE\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"symbolCode\":\"ERR_INVALID_ARG_TYPE\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"dataCode\":\"ERR_INVALID_ARG_TYPE\""));
}
