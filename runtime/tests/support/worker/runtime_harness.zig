//! The worker runtime harness (`collo_test_harness`): a host for tests that
//! run a worker runtime in process, or talk to a forked worker through the
//! host client (`host.dispatch`). A dispatch names its route by its index in
//! the routes section of the worker's definition artifact and carries no
//! pack, so the artifact reaches the worker first: a forked worker takes it
//! in WorkerInit (`host.launch.LaunchOptions.routes`, which `launchRoutes`
//! builds), and an in-process runtime boots it once, as a worker's boot does
//! (`bootDefinition`, or `registerRoute` for a one-route artifact). The
//! harness builds dispatches with test defaults, each carrying an egress
//! token minted under `test_egress_key` for `LocalEgressGateway`'s session
//! and a pool slot of its own, reads each response back through its
//! `request_done` within a bounded budget, and runs the real egress gateway
//! in process and an HTTP/1.1 origin where a test needs them. The worker
//! runtime suites, the zygote integration lane and the web API suites share
//! it.
//!
//! Everything runs on the test's thread except `LocalEgressGateway`, whose
//! loop has a thread of its own besides the threads its shard's engine
//! starts, and `LocalOrigin`, which serves from one thread. In-process
//! runtimes read a fake clock through `fakeNow`, and the dispatch defaults
//! here are instants on such a clock; a forked worker reads the real clock
//! and needs a deadline taken from it.

const std = @import("std");
const bindings = @import("collo_bindings");
const collo_network = @import("collo_network");
const fd_mod = @import("collo_os").fd;
const host = @import("collo_host");
const http1_common = @import("collo_http").framing;
const ipc = @import("collo_ipc");
const egress_client = @import("collo_egress_client");
const local_address = @import("collo_test_net");
const egress_gateway = @import("collo_egress_gateway");
const worker = @import("collo_worker");
const worker_shared_page = @import("collo_worker_state").page;
const worker_testing = @import("collo_worker_test_support");

const egress_transport = egress_client.transport;
const gateway_runtime = egress_gateway.runtime;
const os_process = @import("collo_os").process;

/// The `now_fn` of a fake `worker.Clock`: `ctx` points at a `u64` that the
/// test sets to the current monotonic time in nanoseconds.
pub fn fakeNow(ctx: ?*anyopaque) u64 {
    return @as(*u64, @ptrCast(@alignCast(ctx.?))).*;
}

// Re-exported for suites whose module graph lacks these modules, such as
// zygote-integration, which imports neither `collo_test_net` nor
// `collo_worker_state`. A worker reaches a local origin at the routable
// address `test_net` finds, because the egress policy denies loopback even
// when it allows private networks.
pub const test_net = local_address;
pub const shared_page = worker_shared_page;

pub const default_request_headers = [_]ipc.RequestHeader{.{ .name = "host", .value = "demo.test" }};

/// The key the harness mints egress tokens under, which `LocalEgressGateway`'s
/// hello hands its gateway, so the gateway verifies every token under it; a
/// test that reads a recorded token back verifies it with the same key
/// (`verifyEgressToken`).
pub const test_egress_key: ipc.egress_token.Key = .{ .bytes = @splat(0x5c) };

/// The worker session `LocalEgressGateway` serves, which every harness token
/// names.
pub const local_egress_session_id: u64 = 1;

/// What a `LocalEgressGateway` lets its fetches reach.
pub const LocalNetwork = enum {
    /// Public HTTPS hosts on the default port, as a `"*"` grant admits them.
    public_https,
    /// Besides those, plain HTTP to an IPv4 literal on the port its URL
    /// names, private addresses included, as a grant naming that literal and
    /// port with both flags admits it: how a fetch reaches a `LocalOrigin`
    /// or any other origin a test starts on this host's routable address.
    /// Loopback, link-local and metadata addresses stay refused, as under
    /// every grant.
    local_origins,
};

/// The network of a `LocalEgressGateway` whose fetches reach a `LocalOrigin`,
/// which serves plain HTTP on a private address of the host.
pub const local_origin_network: LocalNetwork = .local_origins;

/// The policy id every token the harness mints names: the first id a policy
/// image's builder gives a granted policy (`collo_network.table.Builder`),
/// which a configuration with one granted route mints for it, and the policy
/// `LocalEgressGateway`'s hello grants.
pub const harness_policy_id: collo_network.PolicyId = 1;

/// The deadline of every request token the harness mints: an instant on the
/// real monotonic clock, which `LocalEgressGateway`'s admission reads, that
/// no test outlives. A dispatch's own deadline cannot serve: an in-process
/// runtime's deadlines are instants on a fake clock the gateway never sees.
/// The worker copies a token without reading it.
pub const live_token_deadline_ns: u64 = std.math.maxInt(u64) / 2;

/// The token the server's lane mints for a request dispatched to a worker
/// attached to `LocalEgressGateway`'s session: kind request, the harness's
/// policy, the request's own id and generation, and
/// `live_token_deadline_ns`.
pub fn requestEgressToken(parts: DispatchParts) ipc.egress_token.Bytes {
    const token = ipc.egress_token.mint(&test_egress_key, .{
        .kind = .request,
        .policy_id = harness_policy_id,
        .session_id = local_egress_session_id,
        .request_id = parts.request_id,
        .request_generation = parts.request_generation,
        .deadline_monotonic_ns = live_token_deadline_ns,
    });
    return ipc.egress_token.asBytes(&token).*;
}

/// The boot token a launch with an egress grant hands its worker in
/// WorkerInit, minted as `host/launch.zig` mints it, with
/// `deadline_monotonic_ns` standing for the end of the child window on the
/// real monotonic clock, which `LocalEgressGateway`'s admission reads; an
/// in-process test that has no window passes `live_token_deadline_ns`. An
/// in-process runtime takes the token as `RuntimeOptions.boot_egress_token`,
/// and every evaluation presents it.
pub fn bootEgressToken(deadline_monotonic_ns: u64) ipc.egress_token.Bytes {
    const token = ipc.egress_token.mint(&test_egress_key, .{
        .kind = .boot,
        .policy_id = harness_policy_id,
        .session_id = local_egress_session_id,
        .request_id = 0,
        .request_generation = 0,
        .deadline_monotonic_ns = deadline_monotonic_ns,
    });
    return ipc.egress_token.asBytes(&token).*;
}

/// What a forked launch attached to `LocalEgressGateway` passes as the boot
/// egress of its session (`host.launch.LaunchEgress.Attached.boot`), so the host
/// mints the worker's boot token under `test_egress_key` with the child
/// window as its deadline.
pub fn localBootEgress() host.launch.BootEgress {
    return .{
        .key = test_egress_key,
        .session_id = local_egress_session_id,
        .policy_id = harness_policy_id,
    };
}

/// The fields of a token the harness minted, read back from bytes a gateway
/// recorded. Fails as `ipc.egress_token.verify` does for any other bytes.
pub fn verifyEgressToken(
    bytes: *const ipc.egress_token.Bytes,
) ipc.egress_token.VerifyError!ipc.egress_token.Fields {
    const token = ipc.egress_token.fromBytes(bytes);
    return ipc.egress_token.verify(&test_egress_key, &token);
}

pub const RequestParts = struct {
    method: []const u8 = "GET",
    path: []const u8 = "/async",
    raw_query: []const u8 = "",
    headers: []const ipc.RequestHeader = &default_request_headers,
    body_framing: ipc.RequestBodyFraming = .none,
    body: []const u8 = "",
    body_end_stream: bool = true,
};

pub const DispatchParts = struct {
    request_id: u64,
    /// The route's index in the routes section of the worker's artifact:
    /// what `registerRoute` returned for an in-process runtime, or the
    /// route's position in the artifact a forked worker launched with.
    route_index: u16 = 0,
    /// The worker's pool slot the request holds, which names its live slot
    /// on the page (`DispatchWork.worker_slot`). null picks
    /// `request_id % LIVE_SLOT_COUNT`, so requests with consecutive ids hold
    /// slots of their own, as the server's pool gives them.
    worker_slot: ?u8 = null,
    request_generation: u64 = 1,
    worker_id: u64 = 1,
    worker_generation: u64 = 1,
    request_lane_id: u16 = 0,
    request_slot: u32 = 0,
    authority: []const u8 = "demo.test",
    deadline_monotonic_ns: u64 = 10_000,
    request: RequestParts = .{},
    route_captures: []const ipc.RouteCapture = &.{},
    /// The request's egress token. null mints one for this request
    /// (`requestEgressToken`), as the server's lane does for a worker attached
    /// to `LocalEgressGateway`'s session; `ipc.egress_token.none` dispatches
    /// the request as to a worker without an egress session, whose fetches
    /// the worker refuses itself.
    egress_token: ?ipc.egress_token.Bytes = null,
};

/// The harness request as the host client takes it. The harness keeps its
/// own defaults (the `host` header in `RequestParts`, the fake-clock deadline
/// in `DispatchParts`), so the host types stay free of test values.
fn toHostRequest(request: RequestParts) host.dispatch.Request {
    return .{
        .method = request.method,
        .path = request.path,
        .raw_query = request.raw_query,
        .headers = request.headers,
        .body = request.body,
        .body_framing = request.body_framing,
        .body_end_stream = request.body_end_stream,
    };
}

pub fn initDispatchWork(allocator: std.mem.Allocator, parts: DispatchParts) !ipc.DispatchWork {
    var work = try host.dispatch.initDispatchWork(allocator, .{
        .request_id = parts.request_id,
        .route_index = parts.route_index,
        .deadline_monotonic_ns = parts.deadline_monotonic_ns,
        .authority = parts.authority,
        .request_generation = parts.request_generation,
        .worker_id = parts.worker_id,
        .worker_generation = parts.worker_generation,
        .request_lane_id = parts.request_lane_id,
        .request_slot = parts.request_slot,
        .route_captures = parts.route_captures,
        .request = toHostRequest(parts.request),
    });
    work.egress_token = parts.egress_token orelse requestEgressToken(parts);
    work.worker_slot = parts.worker_slot orelse
        @intCast(parts.request_id % worker_shared_page.LIVE_SLOT_COUNT);
    return work;
}

/// A request that is really live in `runtime.requests.active`, with a real
/// `RequestContext` behind its entry and its live slot begun on the page;
/// `deinit` removes and frees the context and leaves the slot naming it, as
/// a finished request's does.
///
/// Every entry of that map must point at a usable context: each work item
/// queued as ready is booked against its owner (`Runtime.noteOwnerReady`
/// calls `RequestContext.noteReady`), so a placeholder pointer registered
/// only to pass an "is this request active" check faults the first time a
/// work item of that request is queued.
pub const ActiveRequest = struct {
    allocator: std.mem.Allocator,
    runtime: *worker.Runtime,
    request_id: u64,
    ctx: *worker_testing.RequestContext,

    pub fn init(
        allocator: std.mem.Allocator,
        runtime: *worker.Runtime,
        request_id: u64,
        started_mono_ns: u64,
    ) !ActiveRequest {
        var dispatch = try initDispatchWork(allocator, .{ .request_id = request_id });
        var dispatch_owned = true;
        errdefer if (dispatch_owned) dispatch.deinit();

        const ctx = try allocator.create(worker_testing.RequestContext);
        errdefer allocator.destroy(ctx);
        runtime.observability.metrics_view.beginLiveSlot(dispatch.worker_slot, request_id, dispatch.request_generation);
        ctx.* = worker_testing.RequestContext.initOwnedDispatch(allocator, 0, dispatch, started_mono_ns);
        dispatch_owned = false;
        errdefer ctx.deinit();

        try runtime.requests.active.putNoClobber(allocator, request_id, ctx);
        return .{ .allocator = allocator, .runtime = runtime, .request_id = request_id, .ctx = ctx };
    }

    pub fn deinit(self: ActiveRequest) void {
        if (self.runtime.requests.active.fetchRemove(self.request_id)) |removed| {
            removed.value.deinit();
            self.allocator.destroy(removed.value);
        }
    }
};

pub const socketPairType = fd_mod.socketPairType;

pub fn writeAllFd(fd: std.posix.fd_t, bytes: []const u8) !void {
    try fd_mod.writeAllRaw(fd, bytes);
}

/// A sealed memfd holding a definition artifact with one module, `source`
/// at `specifier`, and one route to it with no bindings
/// (`module_pack.buildSingleRouteAlloc`). The caller owns the fd.
pub fn createModulePackFd(specifier: []const u8, source: []const u8) !std.posix.fd_t {
    const pack = try ipc.module_pack.buildSingleRouteAlloc(std.testing.allocator, specifier, source);
    defer std.testing.allocator.free(pack);
    return createSealedPackFd(pack);
}

/// A sealed memfd holding a definition artifact with `modules` and `routes`
/// (`module_pack.buildAlloc`). The caller owns the fd.
pub fn createDefinitionFd(
    modules: []const ipc.module_pack.Module,
    routes: []const ipc.route_table.RouteInput,
) !std.posix.fd_t {
    const pack = try ipc.module_pack.buildAlloc(std.testing.allocator, modules, routes);
    defer std.testing.allocator.free(pack);
    return createSealedPackFd(pack);
}

fn createSealedPackFd(pack: []const u8) !std.posix.fd_t {
    const fd = try std.posix.memfd_create("collo-test-definition", std.os.linux.MFD.CLOEXEC | std.os.linux.MFD.ALLOW_SEALING);
    errdefer std.posix.close(fd);
    try fd_mod.writeAllRaw(fd, pack);
    try std.posix.lseek_SET(fd, 0);
    try fd_mod.addSeals(fd, fd_mod.memfd_readonly_seals);
    return fd;
}

/// Boots the in-process `runtime` on the artifact in `pack_fd`, which stays
/// the caller's, as a worker's boot does: registers it and evaluates every
/// route's entry (`Runtime.evaluateBootRoutes`). A runtime boots once.
pub fn bootDefinition(runtime: *worker.Runtime, pack_fd: std.posix.fd_t) !void {
    try runtime.evaluateBootRoutes(pack_fd, 0, null);
}

/// One route of a definition a test boots: the source of its one module and
/// the specifier `routeSpecifier` keys it under.
pub const RouteSource = struct {
    specifier: []const u8,
    source: []const u8,
};

/// Boots `runtime` on one artifact with a module and a route per entry of
/// `routes`, in order, so route `i` serves `routes[i]` and the run helpers
/// find it by its specifier. A runtime boots once, so a test that runs
/// several routes on one runtime boots them all here first.
pub fn bootRoutes(runtime: *worker.Runtime, routes: []const RouteSource) !void {
    std.debug.assert(routes.len <= ipc.route_table.routes_max);
    var keys: [ipc.route_table.routes_max][]u8 = undefined;
    var key_count: usize = 0;
    defer for (keys[0..key_count]) |key| std.testing.allocator.free(key);
    var modules: [ipc.route_table.routes_max]ipc.module_pack.Module = undefined;
    var route_inputs: [ipc.route_table.routes_max]ipc.route_table.RouteInput = undefined;
    for (routes, 0..) |route, index| {
        keys[index] = try routeSpecifier(std.testing.allocator, route.specifier);
        key_count += 1;
        modules[index] = .{ .specifier = keys[index], .source = route.source };
        route_inputs[index] = .{ .entry_module = @intCast(index) };
    }
    const pack_fd = try createDefinitionFd(modules[0..routes.len], route_inputs[0..routes.len]);
    defer std.posix.close(pack_fd);
    try bootDefinition(runtime, pack_fd);
}

/// The module state of the first route of `runtime` whose entry is
/// `specifier`, or null when it has none.
pub fn routeModule(runtime: *worker.Runtime, specifier: []const u8) ?*const worker.testing.module_routes.RouteModuleState {
    const index = routeIndex(runtime, specifier) orelse return null;
    return &runtime.modules.state.routes.items[index].module;
}

/// Boots `runtime` on a one-route artifact of `source` at `specifier` and
/// returns the route's index, 0; a runtime that already serves a route with
/// that entry returns its index and boots nothing. Fails with
/// `error.AlreadyExists` for a runtime that booted another artifact, since a
/// VM holds one, or as `bootDefinition` does.
pub fn registerRoute(runtime: *worker.Runtime, specifier: []const u8, source: []const u8) !u16 {
    if (routeIndex(runtime, specifier)) |index|
        return index;
    const route_fd = try createModulePackFd(specifier, source);
    defer std.posix.close(route_fd);
    try bootDefinition(runtime, route_fd);
    return routeIndex(runtime, specifier) orelse error.TestRouteMissing;
}

/// The index of the first route of `runtime` whose entry is `specifier`.
pub fn routeIndex(runtime: *const worker.Runtime, specifier: []const u8) ?u16 {
    for (runtime.modules.state.routes.items, 0..) |route, index| {
        if (std.mem.eql(u8, route.entry_specifier, specifier))
            return @intCast(index);
    }
    return null;
}

/// What `host.launch.LaunchOptions.routes` takes for a forked worker that
/// serves the routes of the artifact in `pack_fd`, which stays the caller's,
/// all in the VM's main realm.
pub fn launchRoutes(pack_fd: std.posix.fd_t) host.launch.LaunchRoutes {
    return .{ .module_pack_fd = pack_fd, .isolate_realm = false };
}

/// `specifier` itself when it already lies under `module_pack.task_root`,
/// otherwise the same path below it, as the server keys a definition's
/// modules; the caller frees the result.
pub fn routeSpecifier(allocator: std.mem.Allocator, specifier: []const u8) ![]u8 {
    const task_prefix = ipc.module_pack.task_root ++ "/";
    if (std.mem.startsWith(u8, specifier, task_prefix))
        return allocator.dupe(u8, specifier);
    const suffix = if (std.mem.startsWith(u8, specifier, "/")) specifier[1..] else specifier;
    return std.fmt.allocPrint(allocator, task_prefix ++ "{s}", .{suffix});
}

/// Wall budget of the readers that take a runtime. An in-process flow has
/// already run to completion when its reader starts, so the budget only
/// keeps a harness bug from hanging the suite.
pub const default_read_budget_ms: u32 = 10_000;

/// In-process stand-in for the shared state page a host launch builds
/// (`host.launch.Machine`): the memfd, the worker's writer view of it, which
/// holds the live slots, and the host's reader view, which drains the
/// console ring and reads the benchmark record. Tests hand `&fixture.view`
/// and a fresh eventfd from `createCompletionEventfd()` to `Runtime.init`,
/// as every forked worker receives both in WorkerInit. The fixture must not
/// move once a drain ran, since the reader keeps the host's console cursor.
pub const CompletionFixture = struct {
    memfd: std.posix.fd_t,
    view: worker_shared_page.WorkerWriterView,
    reader: worker_shared_page.HostReaderView,

    pub fn init() !CompletionFixture {
        const memfd = try worker_shared_page.createMemfd("collo-test-worker-metrics");
        errdefer std.posix.close(memfd);
        var view = try worker_shared_page.mapWorkerWriter(memfd);
        errdefer view.deinit();
        return .{ .memfd = memfd, .view = view, .reader = try worker_shared_page.mapHostReader(memfd) };
    }

    pub fn deinit(self: *CompletionFixture) void {
        self.reader.deinit();
        self.view.deinit();
        std.posix.close(self.memfd);
        self.* = undefined;
    }
};

/// A fresh, non-blocking completion eventfd. The caller owns it until it
/// hands it to `Runtime.init`, whose teardown closes it, as a forked worker
/// owns the one WorkerInit hands it (`host/launch.zig`).
pub fn createCompletionEventfd() !std.posix.fd_t {
    return std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
}

/// Where the host client reads one worker's responses; the in-process and
/// the forked topologies share the shape.
pub const ResponseChannels = host.dispatch.ResponseChannels;

pub fn runtimeResponseChannels(
    runtime: *worker.Runtime,
    server_control_fd: std.posix.fd_t,
) ResponseChannels {
    return .{
        .control_fd = server_control_fd,
        .ingress_payload = if (runtime.requests.ingress_payload) |*ingress_payload| ingress_payload else null,
    };
}

/// A `request_done` the server's end of a control socket read: the
/// descriptor that carried it, with the identity the worker sent it under,
/// and the record.
pub const ReadRequestDone = struct {
    descriptor: ipc.ingress_channel.Descriptor,
    done: ipc.RequestDone,
};

/// Reads packets from `server_fd`, the server's end of a worker's control
/// socket, until it holds the `request_done` of every request in
/// `request_ids`, and writes each into `out` at the index of its id. Every
/// other descriptor is read and dropped, so responses that interleave come
/// out in any order. The runtime is not driven meanwhile: the requests ran
/// to their finish before the call. Fails with `error.RequestDoneMissing`
/// when the socket stays empty for `default_read_budget_ms` before every
/// one came.
pub fn readRequestDones(server_fd: std.posix.fd_t, request_ids: []const u64, out: []ReadRequestDone) !void {
    std.debug.assert(request_ids.len == out.len);
    std.debug.assert(request_ids.len <= worker_shared_page.LIVE_SLOT_COUNT);
    var seen = [_]bool{false} ** worker_shared_page.LIVE_SLOT_COUNT;
    var seen_count: usize = 0;
    const scratch = try std.testing.allocator.alloc(u8, ipc.max_message_bytes);
    defer std.testing.allocator.free(scratch);
    while (seen_count < request_ids.len) {
        var polls = [_]std.posix.pollfd{.{ .fd = server_fd, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&polls, @intCast(default_read_budget_ms)) == 0)
            return error.RequestDoneMissing;
        var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, server_fd, scratch);
        if (ipc.ingress_channel.isDescriptorBatchPacket(packet.bytes)) {
            var batch = try ipc.ingress_channel.decodeReceivedBatchPacket(std.testing.allocator, &packet);
            defer batch.deinit();
            for (batch.items) |item|
                seen_count += try noteRequestDone(item.descriptor, item.payload, request_ids, out, &seen);
        } else {
            var single = try ipc.ingress_channel.decodeReceivedPacket(std.testing.allocator, &packet);
            defer single.deinit();
            seen_count += try noteRequestDone(single.descriptor, single.payload, request_ids, out, &seen);
        }
    }
}

/// `readRequestDones` for the one request `request_id`.
pub fn readRequestDoneOf(server_fd: std.posix.fd_t, request_id: u64) !ReadRequestDone {
    var out: [1]ReadRequestDone = undefined;
    try readRequestDones(server_fd, &.{request_id}, &out);
    return out[0];
}

/// 1 when `descriptor` is the first `request_done` of one of `request_ids`,
/// which it writes into `out`; 0 for any other descriptor. A second
/// `request_done` of one request fails the test.
fn noteRequestDone(
    descriptor: ipc.ingress_channel.Descriptor,
    payload: []const u8,
    request_ids: []const u64,
    out: []ReadRequestDone,
    seen: []bool,
) !usize {
    if (descriptor.op != @intFromEnum(ipc.ingress_channel.Op.request_done))
        return 0;
    const index = std.mem.indexOfScalar(u64, request_ids, descriptor.request_id) orelse return 0;
    try std.testing.expect(!seen[index]);
    seen[index] = true;
    out[index] = .{ .descriptor = descriptor, .done = try ipc.ingress_channel.decodeRequestDone(payload) };
    return 1;
}

/// Reads the response of `request_id` from the server's end of the control
/// socket up to its `request_done`, within `default_read_budget_ms`, and
/// returns the record: the status the worker ended the request with and
/// what it measured. The response's frames are read and dropped
/// (`host.dispatch.readResponse` owns the read order, which needs the
/// request's response first on the socket; `readRequestDones` reads
/// interleaved ones).
pub fn readRequestDone(
    runtime: *worker.Runtime,
    server_control_fd: std.posix.fd_t,
    request_id: u64,
) !ipc.RequestDone {
    var response = try readIngressResponse(runtime, server_control_fd, request_id);
    defer response.deinit();
    return response.done;
}

pub fn runRouteAndExpectBody(
    runtime: *worker.Runtime,
    server_control_fd: std.posix.fd_t,
    source: []const u8,
    request_id: u64,
    specifier: []const u8,
    expected: []const u8,
) !void {
    const body = try runRouteAndReadBody(runtime, server_control_fd, source, request_id, specifier);
    defer std.testing.allocator.free(body);
    if (!std.mem.containsAtLeast(u8, body, 1, expected)) {
        std.debug.print("expected response body to contain: {s}\nactual body:\n{s}\n", .{ expected, body });
        return error.TestUnexpectedResult;
    }
}

pub fn runRouteAndReadBody(
    runtime: *worker.Runtime,
    server_control_fd: std.posix.fd_t,
    source: []const u8,
    request_id: u64,
    specifier: []const u8,
) ![]u8 {
    return runRouteAndReadBodyWithRequest(
        runtime,
        server_control_fd,
        source,
        request_id,
        specifier,
        .{},
    );
}

pub fn runRouteAndReadBodyWithRequest(
    runtime: *worker.Runtime,
    server_control_fd: std.posix.fd_t,
    source: []const u8,
    request_id: u64,
    specifier: []const u8,
    request: RequestParts,
) ![]u8 {
    return runRouteAndReadBodyWithRequestCaptures(
        runtime,
        server_control_fd,
        source,
        request_id,
        specifier,
        request,
        &.{},
    );
}

pub fn runRouteAndReadIngressResponse(
    runtime: *worker.Runtime,
    server_control_fd: std.posix.fd_t,
    source: []const u8,
    request_id: u64,
    specifier: []const u8,
) !IngressResponse {
    return runRouteAndReadIngressResponseWithRequest(
        runtime,
        server_control_fd,
        source,
        request_id,
        specifier,
        .{},
    );
}

/// Boots `runtime` on `source` as the route at `specifier`
/// (`routeSpecifier`) unless it already serves that route
/// (`registerRoute`), runs one request against it to completion and reads
/// the response; the caller owns the response.
pub fn runRouteAndReadIngressResponseWithRequest(
    runtime: *worker.Runtime,
    server_control_fd: std.posix.fd_t,
    source: []const u8,
    request_id: u64,
    specifier: []const u8,
    request: RequestParts,
) !IngressResponse {
    const route_specifier = try routeSpecifier(std.testing.allocator, specifier);
    defer std.testing.allocator.free(route_specifier);
    const route_index = try registerRoute(runtime, route_specifier, source);

    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .route_index = route_index,
        .request = request,
    });
    defer dispatch.deinit();
    try enqueueIngressRoute(runtime, &dispatch, 1, request);

    try executeQueuedBegin(runtime);

    return readIngressResponse(runtime, server_control_fd, request_id);
}

/// As `runRouteAndReadIngressResponseWithRequest` with route captures,
/// returning the response body, which the caller owns.
pub fn runRouteAndReadBodyWithRequestCaptures(
    runtime: *worker.Runtime,
    server_control_fd: std.posix.fd_t,
    source: []const u8,
    request_id: u64,
    specifier: []const u8,
    request: RequestParts,
    captures: []const ipc.RouteCapture,
) ![]u8 {
    const route_specifier = try routeSpecifier(std.testing.allocator, specifier);
    defer std.testing.allocator.free(route_specifier);
    const route_index = try registerRoute(runtime, route_specifier, source);

    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .route_index = route_index,
        .route_captures = captures,
        .request = request,
    });
    defer dispatch.deinit();
    try enqueueIngressRoute(runtime, &dispatch, 1, request);

    try executeQueuedBegin(runtime);

    return readIngressResponseBody(runtime, server_control_fd, request_id);
}

/// Runs one request against the runtime's route whose entry is
/// `specifier`, which it holds already, to completion and returns the
/// response body, which the caller owns. Fails with `error.TestRouteMissing`
/// when the runtime has no such route.
pub fn runRegisteredRouteAndReadBody(
    runtime: *worker.Runtime,
    server_control_fd: std.posix.fd_t,
    request_id: u64,
    specifier: []const u8,
    request: RequestParts,
) ![]u8 {
    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .route_index = routeIndex(runtime, specifier) orelse return error.TestRouteMissing,
        .request = request,
    });
    defer dispatch.deinit();
    try enqueueIngressRoute(runtime, &dispatch, 1, request);

    try executeQueuedBegin(runtime);

    return readIngressResponseBody(runtime, server_control_fd, request_id);
}

/// Hands `dispatch` to the in-process `runtime` as a request begin with its
/// encoded bytes inline, then `request.body` as one chunk when it is not
/// empty. The runtime must serve the route already (`registerRoute`). The
/// caller keeps `dispatch`.
pub fn enqueueIngressRoute(
    runtime: *worker.Runtime,
    dispatch: *ipc.DispatchWork,
    stream_id: u32,
    request: RequestParts,
) !void {
    var payload_scratch: [ipc.max_message_bytes]u8 = undefined;
    var view = dispatch.view();
    const payload = try ipc.encodeDispatchWorkInto(&payload_scratch, &view);
    const identity = ipc.ingress_channel.RequestIdentity{
        .request_id = dispatch.request_id,
        .request_generation = dispatch.request_generation,
        .request_lane_id = dispatch.request_lane_id,
        .request_slot = dispatch.request_slot,
    };
    const body = request.body;
    var descriptor = ipc.ingress_channel.Descriptor.requestBegin(
        identity,
        stream_id,
        0,
        @intCast(payload.len),
        @intCast(dispatch.request_headers.len),
        body.len == 0 and request.body_end_stream,
    );
    descriptor.flag_bits |= ipc.ingress_channel.flags.inline_bytes;

    // The runtime takes each payload on every path, failure included.
    try runtime.enqueueIngressDescriptor(.{
        .allocator = std.testing.allocator,
        .descriptor = descriptor,
        .payload = try std.testing.allocator.dupe(u8, payload),
    });

    if (body.len != 0) {
        var body_descriptor = ipc.ingress_channel.Descriptor.requestBodyChunk(
            identity,
            stream_id,
            0,
            @intCast(body.len),
            request.body_end_stream,
        );
        body_descriptor.flag_bits |= ipc.ingress_channel.flags.inline_bytes;
        try runtime.enqueueIngressDescriptor(.{
            .allocator = std.testing.allocator,
            .descriptor = body_descriptor,
            .payload = try std.testing.allocator.dupe(u8, body),
        });
    }
}

/// Sends `dispatch` and `request.body` on a forked worker's control socket
/// (`host.dispatch.sendRequest`). The worker took its definition's artifact
/// in WorkerInit.
pub fn sendIngressRoute(
    control_fd: std.posix.fd_t,
    dispatch: *ipc.DispatchWork,
    stream_id: u32,
    request: RequestParts,
) !void {
    try host.dispatch.sendRequest(control_fd, dispatch, stream_id, toHostRequest(request));
}

pub fn readIngressResponseBody(
    runtime: *worker.Runtime,
    server_control_fd: std.posix.fd_t,
    request_id: u64,
) ![]u8 {
    var response = try readIngressResponse(runtime, server_control_fd, request_id);
    defer response.deinit();
    return response.takeBody();
}

pub const IngressResponse = host.dispatch.Response;
pub const ResponseReadCredit = host.dispatch.ResponseReadCredit;

pub fn readIngressResponse(
    runtime: *worker.Runtime,
    server_control_fd: std.posix.fd_t,
    request_id: u64,
) !IngressResponse {
    return host.dispatch.readResponse(std.testing.allocator, runtimeResponseChannels(runtime, server_control_fd), request_id, .{
        .wall_ms = default_read_budget_ms,
        .max_body_bytes = default_read_max_body_bytes,
        .max_headers_bytes = default_read_max_headers_bytes,
        .progress_context = runtime,
        .progress_fn = progressResponse,
    });
}

/// One pass of the in-process worker for `host.dispatch.readResponse`, which
/// grants the response's credit itself. The harness polls neither the
/// control socket nor the payload ring, so every pass retries what waits
/// for them, the `request_done` packets first, and a retry that still finds
/// no room waits again.
fn progressResponse(context: ?*anyopaque) !void {
    const runtime: *worker.Runtime = @ptrCast(@alignCast(context.?));
    try worker.testing.response_finish.flushPendingRequestDones(runtime);
    worker.testing.response_flow.notifyTransport(runtime, .socket);
    worker.testing.response_flow.notifyTransport(runtime, .ring);
    try pumpOnce(runtime);
}

/// One pass of the in-process worker, as one turn of its loop: reads the
/// control packets its socket holds, collects what became ready and runs
/// one work item.
pub fn pumpOnce(runtime: *worker.Runtime) !void {
    if (runtime.core.control_fd) |fd| {
        for (0..32) |_| {
            var polls = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
            if (try std.posix.poll(&polls, 0) == 0 or (polls[0].revents & std.posix.POLL.IN) == 0)
                break;
            try worker.testing.scheduler.loop.collectControlPacket(runtime);
        }
    }
    try collectReadyWork(runtime);
    try executeNextReady(runtime);
}

/// Byte caps for the harness readers, set above any response a test streams,
/// so they only stop a runaway worker from exhausting the suite's memory.
pub const default_read_max_body_bytes: usize = 64 * 1024 * 1024;
pub const default_read_max_headers_bytes: usize = 1024 * 1024;

/// The host client's bounded reader, with the harness allocator.
pub fn readIngressResponseBounded(
    channels: ResponseChannels,
    request_id: u64,
    budget_ms: u32,
) !IngressResponse {
    return host.dispatch.readResponse(std.testing.allocator, channels, request_id, .{
        .wall_ms = budget_ms,
        .max_body_bytes = default_read_max_body_bytes,
        .max_headers_bytes = default_read_max_headers_bytes,
    });
}

/// Boots `runtime` on `source` as the route at `specifier`
/// (`routeSpecifier`) unless it already serves that route, and runs one
/// request against it on `stream_id` to completion. The response and its
/// `request_done` stay queued for the caller.
pub fn runH2Route(
    runtime: *worker.Runtime,
    source: []const u8,
    request_id: u64,
    stream_id: u32,
    specifier: []const u8,
    request: RequestParts,
) !void {
    const route_specifier = try routeSpecifier(std.testing.allocator, specifier);
    defer std.testing.allocator.free(route_specifier);
    const route_index = try registerRoute(runtime, route_specifier, source);

    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = request_id,
        .route_index = route_index,
        .request = request,
    });
    defer dispatch.deinit();

    try enqueueIngressRoute(runtime, &dispatch, stream_id, request);

    try executeNextReady(runtime);
    try executeUntilRequestDone(runtime, request_id);
}

pub fn executeNextReady(runtime: *worker.Runtime) !void {
    const item = runtime.scheduler.ready_queue.pop() orelse return;
    try worker_testing.executeWorkItem(runtime, item);
}

/// Runs the work item of the request begin just enqueued, the next in the
/// ready queue. Fails with `error.MissingRequestWork` when the queue is
/// empty, so a begin that never queued fails where it happened instead of
/// as a request that never completes.
pub fn executeQueuedBegin(runtime: *worker.Runtime) !void {
    const item = runtime.scheduler.ready_queue.pop() orelse return error.MissingRequestWork;
    try worker_testing.executeWorkItem(runtime, item);
}

/// Runs the runtime's collectors and its ready queue until `request_id`
/// leaves `requests.active`. Fails with `error.RequestDidNotComplete` after a
/// fixed number of passes; a pass that finds nothing to run sleeps a
/// millisecond.
pub fn executeUntilRequestDone(runtime: *worker.Runtime, request_id: u64) !void {
    var attempts: usize = 0;
    while (runtime.requests.active.contains(request_id)) : (attempts += 1) {
        if (attempts > 1000)
            return error.RequestDidNotComplete;
        try collectReadyWork(runtime);
        if (runtime.scheduler.ready_queue.pop()) |item| {
            try worker_testing.executeWorkItem(runtime, item);
            continue;
        }
        std.Thread.sleep(std.time.ns_per_ms);
    }
}

/// How `executeUntilRequestDoneOnFakeClock` moves a fake clock.
pub const FakeClockPace = struct {
    /// What one work item costs. Code that keeps the loop busy without
    /// waiting on a timer still reaches its timers, a JavaScript test
    /// timeout among them.
    work_item_ns: u64 = 10 * std.time.ns_per_us,
    /// The fake time the loop runs before it gives up. The request's own
    /// deadline should lie beyond it, so the code under test decides how the
    /// request ends.
    budget_ns: u64,
};

/// As `executeUntilRequestDone`, for a runtime that reads the fake clock at
/// `now_mono_ns`, which the loop moves: by `pace.work_item_ns` for each work
/// item it runs, and while nothing is ready, by the millisecond it sleeps.
/// Idle time therefore passes at the real rate, so work another thread
/// finishes in real time (a gateway packet) is never overtaken
/// by a fake timer, and a timer still fires however long its delay. Fails with
/// `error.RequestDidNotComplete` once `pace.budget_ns` of fake time passed: a
/// request that neither finishes nor is ended by its own timers, such as
/// work that keeps the ready queue full or a wait on something that never
/// arrives.
pub fn executeUntilRequestDoneOnFakeClock(
    runtime: *worker.Runtime,
    now_mono_ns: *u64,
    request_id: u64,
    pace: FakeClockPace,
) !void {
    const give_up_mono_ns = now_mono_ns.* + pace.budget_ns;
    while (runtime.requests.active.contains(request_id)) {
        if (now_mono_ns.* > give_up_mono_ns)
            return error.RequestDidNotComplete;
        try collectReadyWork(runtime);
        if (runtime.scheduler.ready_queue.pop()) |item| {
            try worker_testing.executeWorkItem(runtime, item);
            now_mono_ns.* += pace.work_item_ns;
            continue;
        }
        std.Thread.sleep(std.time.ns_per_ms);
        now_mono_ns.* += std.time.ns_per_ms;
    }
}

/// Moves everything that became ready into the ready queue, as one pass of
/// the worker's loop does before it runs work.
fn collectReadyWork(runtime: *worker.Runtime) !void {
    runtime.drainReadyBacklog();
    runtime.collectReadyIngressRequests();
    runtime.collectReadyRequestCompletions();
    // A worker without a gateway session has no packets to collect.
    _ = try runtime.collectEgressGatewayPacketsBounded(64);
    runtime.collectModuleSettlements();
    try runtime.collectDueTimers();
    try runtime.collectReadyImmediates();
    try runtime.collectDueRequestDeadlines();
}

/// The identity of one FetchStart a worker sent its gateway, recorded as it
/// crossed the wire. A start names its request only through the egress token
/// it carries, so a test compares these bytes with the token it dispatched and
/// reads the request back with `verifyEgressToken`: a fetch from the boot
/// context, for instance, must arrive under the boot token.
pub const FetchStartIdentity = struct {
    egress_token: ipc.egress_token.Bytes,
};

/// Both ends of a real egress session with no gateway thread: the test plays
/// the gateway, so it decides which completions the worker gets, and the
/// worker's command ring is never drained. `worker_raw` is the half a
/// runtime takes at init or from an `egress_attach`.
pub const RawSession = struct {
    session: ipc.egress_shared.SessionFds,
    gateway: ipc.egress_shared.Endpoint,
    worker_raw: ipc.egress_shared.RawFds,

    /// A session `local_egress_session_id` names, on a wake set of its own;
    /// the session keeps copies of the wake set's descriptors.
    pub fn init(self: *RawSession) !void {
        var wake_set = try ipc.egress_shared.WakeSet.create();
        defer wake_set.deinit();
        try self.initOnWakeSet(&wake_set, local_egress_session_id);
    }

    /// A session `session_id` names, on `wake_set`, which the caller keeps.
    pub fn initOnWakeSet(self: *RawSession, wake_set: *const ipc.egress_shared.WakeSet, session_id: u64) !void {
        self.session = try ipc.egress_shared.createSessionForWorker(wake_set);
        errdefer self.session.deinit();
        var gateway_raw = try dupSharedFds(self.session.rawForGateway());
        errdefer gateway_raw.close();
        self.gateway = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
        self.gateway.command.setSession(session_id, session_id);
        self.gateway.completion.setSession(session_id, session_id);
        self.gateway.body_pool.setSession(session_id, session_id);
        self.gateway.upload_pool.setSession(session_id, session_id);
        self.worker_raw = self.session.takeWorkerHalf();
    }

    pub fn deinit(self: *RawSession) void {
        self.worker_raw.close();
        self.gateway.deinit();
        self.session.deinit();
    }

    /// Answers the runtime's only fetch with a 200 head and leaves its body open.
    pub fn sendOpenHead(self: *RawSession, runtime: *worker.Runtime) !void {
        try std.testing.expectEqual(@as(usize, 1), runtime.egress.state.tasks.count());
        var tasks = runtime.egress.state.tasks.valueIterator();
        const task = tasks.next().?.*;
        var buffer: [4096]u8 = undefined;
        const head = try ipc.encodeEgressFetchHeadInto(&buffer, .{
            .fetch_id = task.id,
            .body_id = task.response_body_identity.body_id,
            .status = 200,
            .status_text = "OK",
            .url = "https://origin.test/open",
            .headers = &.{},
        });
        _ = try self.gateway.completion.writePacket(head);
        _ = try runtime.collectEgressGatewayPacketsBounded(8);
    }

    /// Ends the named body and lets the runtime read the packet.
    pub fn sendBodyEnd(self: *RawSession, runtime: *worker.Runtime, identity: bindings.FetchBodyIdentity) !void {
        const end = ipc.EgressBodyEnd.init(identity.fetch_id, identity.body_id);
        _ = try self.gateway.completion.writePacket(std.mem.asBytes(&end));
        _ = try runtime.collectEgressGatewayPacketsBounded(8);
    }

    /// Fails the runtime's only fetch before its head with `message`, for
    /// `cause`.
    pub fn sendError(self: *RawSession, runtime: *worker.Runtime, cause: ipc.EgressFetchErrorCause, message: []const u8) !void {
        try std.testing.expectEqual(@as(usize, 1), runtime.egress.state.tasks.count());
        var tasks = runtime.egress.state.tasks.valueIterator();
        try self.sendErrorFor(runtime, tasks.next().?.*.id, cause, message);
    }

    /// Fails a fetch before its head and lets the runtime read the packet.
    pub fn sendErrorFor(self: *RawSession, runtime: *worker.Runtime, fetch_id: u64, cause: ipc.EgressFetchErrorCause, message: []const u8) !void {
        const task = runtime.egress.state.tasks.get(fetch_id) orelse return error.TestExpectedFetchTask;
        var buffer: [4096]u8 = undefined;
        const packet = try ipc.encodeEgressFetchErrorInto(&buffer, .{
            .fetch_id = fetch_id,
            .body_id = task.response_body_identity.body_id,
            .message = message,
            .cause = cause,
        });
        _ = try self.gateway.completion.writePacket(packet);
        _ = try runtime.collectEgressGatewayPacketsBounded(8);
    }
};

/// The real egress gateway (`egress/gateway/runtime/root.zig:Gateway`) in
/// the test process, with one shard, serving one worker session over a real
/// egress shared session (`ipc.egress_shared`) from a thread of its own. Its
/// hello carries `test_egress_key` and a policy image whose policy
/// `harness_policy_id` grants what `Options.network` names, so every fetch
/// start passes the gateway's own admission, and the transport checks every
/// hop as in production. The thread runs the gateway's loop pass for pass,
/// except that it reads the worker's command ring itself and hands each
/// packet to `command_flow.handlePacket`, recording the token of each fetch
/// start on the way (`recordedFetchStarts`). `start` returns it
/// heap-allocated; the caller gives the worker the fds `takeWorkerSharedFds`
/// returns and ends the gateway with `deinit`, which panics if that thread
/// failed. Ending it closes the gateway's end of the session's liveness
/// pipe, which a forked worker sees as its gateway gone.
pub const LocalEgressGateway = struct {
    allocator: std.mem.Allocator,
    worker_fds: ?ipc.egress_shared.SessionFds,
    /// Touched only by the gateway thread between `start` and `deinit`.
    gateway: *gateway_runtime.Gateway,
    /// The server's end of the gateway's control socket. It sends the hello,
    /// and the gateway's removal reports wait there unread.
    server_fd: std.posix.fd_t,
    stop_fd: std.posix.fd_t,
    network: LocalNetwork,
    /// Policy `harness_policy_id` under `.local_origins`: the public HTTPS
    /// grant, then one grant per IPv4 origin a fetch start named, oldest
    /// first. Only the gateway thread adds one, before the admission that
    /// copies the policy into that fetch, and none changes afterwards, so a
    /// fetch keeps the prefix it was admitted under.
    local_members: [local_grants_max + 1]*const collo_network.Grant = undefined,
    local_member_count: usize = 0,
    local_grants: [local_grants_max]LocalGrant = undefined,
    thread: std.Thread,
    thread_error: ?anyerror = null,
    fetch_start_mutex: std.Thread.Mutex = .{},
    fetch_starts: [fetch_starts_recorded_max]FetchStartIdentity = undefined,
    /// Every fetch start the worker sent, the recorded ones and any past
    /// `fetch_starts_recorded_max`.
    fetch_start_count: usize = 0,
    mailbox: Mailbox,

    /// Distinct IPv4 origins one gateway grants under `.local_origins`; a
    /// test starts a handful. A fetch to one more is refused by the
    /// transport.
    const local_grants_max: usize = 32;
    /// Fetch starts whose tokens `recordedFetchStarts` keeps, above any
    /// test's count. A start past them is counted but not kept, so a test
    /// that expects more sees too few.
    const fetch_starts_recorded_max: usize = 256;
    /// How long `queueCompletionPacket` waits for the gateway thread, which
    /// answers within one pass of its loop.
    const mailbox_timeout_ns: u64 = 5 * std.time.ns_per_s;
    const wait_tick_ms: i32 = @intCast(egress_gateway.readiness.wait_tick_ns / std.time.ns_per_ms);
    const security_cell_id: egress_gateway.policy.SecurityCellId = @splat(1);

    /// The grant of one IPv4 literal on one port with both flags. Policy
    /// members point into it, so it lives in the harness's heap allocation,
    /// which never moves, until `deinit`.
    const LocalGrant = struct {
        rule: [1]collo_network.Pattern,
        grant: collo_network.Grant,
    };

    /// A completion packet the test thread hands the gateway thread, which
    /// is the ring's only producer, as in production.
    const Mailbox = struct {
        mutex: std.Thread.Mutex = .{},
        condition: std.Thread.Condition = .{},
        /// Written by the test thread once `packet` is set; the gateway
        /// thread polls it.
        fd: std.posix.fd_t,
        packet: ?[]const u8 = null,
        done: bool = false,
        failure: ?anyerror = null,
    };

    pub const Options = struct {
        /// The gateway's limits.
        policy: egress_gateway.policy.Policy = .{},
        /// What the fetches may reach. `local_origin_network` reaches a
        /// `LocalOrigin`; the default admits public HTTPS hosts only.
        network: LocalNetwork = .public_https,
    };

    /// Starts a gateway on a session of a wake set of its own, for a worker
    /// that never changes gateway.
    pub fn start(allocator: std.mem.Allocator, options: Options) !*LocalEgressGateway {
        var wake_set = try ipc.egress_shared.WakeSet.create();
        defer wake_set.deinit();
        return startOnWakeSet(allocator, options, &wake_set);
    }

    /// As `start`, on a new session of the worker whose wake set is
    /// `wake_set` (`ipc.egress_shared.createSessionForWorker`): a test that
    /// moves a worker to a new gateway starts both gateways on the worker's
    /// one wake set, whose descriptors the worker's ring registered at boot.
    /// Each gateway's first session has id `local_egress_session_id`, which
    /// every harness token names.
    pub fn startOnWakeSet(
        allocator: std.mem.Allocator,
        options: Options,
        wake_set: *const ipc.egress_shared.WakeSet,
    ) !*LocalEgressGateway {
        var worker_fds = try ipc.egress_shared.createSessionForWorker(wake_set);
        errdefer worker_fds.deinit();
        var gateway_raw = try dupSharedFds(worker_fds.rawForGateway());
        errdefer gateway_raw.close();
        var endpoint = try ipc.egress_shared.mapEndpointTakeForGateway(&gateway_raw);
        var endpoint_owned = true;
        errdefer if (endpoint_owned) endpoint.deinit();

        const self = try allocator.create(LocalEgressGateway);
        errdefer allocator.destroy(self);
        const stop_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        errdefer std.posix.close(stop_fd);
        const mailbox_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        errdefer std.posix.close(mailbox_fd);
        const control_pair = try fd_mod.socketPairType(
            std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
        );
        errdefer std.posix.close(control_pair[1]);
        const gateway = allocator.create(gateway_runtime.Gateway) catch |err| {
            std.posix.close(control_pair[0]);
            return err;
        };
        errdefer allocator.destroy(gateway);
        // The gateway owns its end of the control socket from this call on.
        try gateway.init(allocator, control_pair[0], .{
            .shard_count = 1,
            .sessions_max = 1,
            .policy = options.policy,
        });
        errdefer gateway.deinit();

        self.* = .{
            .allocator = allocator,
            .worker_fds = worker_fds,
            .gateway = gateway,
            .server_fd = control_pair[1],
            .stop_fd = stop_fd,
            .network = options.network,
            .thread = undefined,
            .mailbox = .{ .fd = mailbox_fd },
        };
        try self.sendHello();
        const attached = try gateway_runtime.session_flow.attachSession(gateway, &endpoint, security_cell_id);
        endpoint_owned = false;
        if (attached.session_id != local_egress_session_id)
            return error.UnexpectedLocalEgressSession;
        switch (options.network) {
            .public_https => {},
            .local_origins => self.installLocalPolicy(),
        }
        try gateway.startShards();
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
        return self;
    }

    /// The worker's end of the session, which the caller then owns and
    /// closes. It can be taken only once.
    pub fn takeWorkerSharedFds(self: *LocalEgressGateway) ipc.egress_shared.RawFds {
        var fds = self.worker_fds orelse unreachable;
        self.worker_fds = null;
        return fds.takeWorkerHalf();
    }

    pub fn deinit(self: *LocalEgressGateway) void {
        if (self.worker_fds) |*fds|
            fds.deinit();
        signalEventFd(self.stop_fd);
        self.thread.join();
        if (self.thread_error) |err|
            std.debug.panic("local egress gateway test thread exited with {s}", .{@errorName(err)});
        // Ends the session's fetches, stops the shard and closes the gateway's control end.
        self.gateway.deinit();
        self.allocator.destroy(self.gateway);
        std.posix.close(self.server_fd);
        std.posix.close(self.stop_fd);
        std.posix.close(self.mailbox.fd);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    /// Copies the tokens of the fetch starts the worker sent, in arrival
    /// order, into `out` and returns how many it copied.
    pub fn recordedFetchStarts(self: *LocalEgressGateway, out: []FetchStartIdentity) usize {
        self.fetch_start_mutex.lock();
        defer self.fetch_start_mutex.unlock();
        const kept = @min(self.fetch_start_count, self.fetch_starts.len);
        const count = @min(out.len, kept);
        @memcpy(out[0..count], self.fetch_starts[0..count]);
        return count;
    }

    /// Writes `bytes` on the worker's completion ring as one packet and wakes
    /// the worker, for a test that plays a gateway breaking the protocol.
    /// The gateway thread writes it, so the ring keeps one producer, and the
    /// call returns once it did. Fails with the ring's error, or when the
    /// gateway thread no longer answers or holds no session.
    pub fn queueCompletionPacket(self: *LocalEgressGateway, bytes: []const u8) !void {
        self.mailbox.mutex.lock();
        defer self.mailbox.mutex.unlock();
        self.mailbox.packet = bytes;
        self.mailbox.done = false;
        self.mailbox.failure = null;
        defer self.mailbox.packet = null;
        signalEventFd(self.mailbox.fd);
        while (!self.mailbox.done) {
            self.mailbox.condition.timedWait(&self.mailbox.mutex, mailbox_timeout_ns) catch |err| switch (err) {
                error.Timeout => return error.LocalEgressGatewayUnresponsive,
            };
        }
        if (self.mailbox.failure) |err|
            return err;
    }

    fn threadMain(self: *LocalEgressGateway) void {
        self.run() catch |err| {
            self.thread_error = err;
        };
    }

    /// The gateway's loop (`Gateway.step`) on a `poll` of the descriptors one
    /// session and one shard bring, with the tap of `handleCommands`. Returns
    /// when `deinit` asks; fails, which `deinit` reports, where the
    /// gateway's own loop would end the process.
    fn run(self: *LocalEgressGateway) !void {
        const gateway = self.gateway;
        const shard_wake_fd = gateway.shards.get(0).engine.wake_fd;
        const watched = std.posix.POLL.IN;
        while (true) {
            var pollfds: [5]std.posix.pollfd = .{
                .{ .fd = self.stop_fd, .events = watched, .revents = 0 },
                .{ .fd = self.mailbox.fd, .events = watched, .revents = 0 },
                .{ .fd = shard_wake_fd, .events = watched, .revents = 0 },
                undefined,
                undefined,
            };
            var watched_count: usize = 3;
            if (gateway.sessions.byId(local_egress_session_id)) |session| {
                pollfds[3] = .{ .fd = session.endpoint.command_eventfd, .events = watched, .revents = 0 };
                // The liveness descriptor reports only its hang-up.
                pollfds[4] = .{ .fd = session.endpoint.peer_liveness_fd, .events = 0, .revents = 0 };
                watched_count = 5;
            }
            _ = try std.posix.poll(pollfds[0..watched_count], wait_tick_ms);
            if (pollfds[0].revents != 0)
                return;

            if (pollfds[2].revents != 0)
                try gateway_runtime.shard_flow.handleShardReady(gateway, 0, pollfds[2].revents);
            // A shard pass marks a session for drop and never removes it, so the session the poll
            // watched is still registered.
            if (watched_count == 5) {
                const index = gateway.sessions.indexOf(local_egress_session_id).?;
                if ((pollfds[4].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
                    try gateway_runtime.session_flow.removeSession(gateway, index, .liveness_closed);
                } else if ((pollfds[3].revents & std.posix.POLL.IN) != 0) {
                    if (!self.handleCommands(gateway.sessions.byIndex(index)))
                        try gateway_runtime.session_flow.removeSession(gateway, index, .command_ring_failed);
                }
            }
            if (pollfds[1].revents != 0)
                self.answerMailbox();

            gateway_runtime.upload_flow.expire(gateway, os_process.monotonicNowNsOrZero());
            try gateway_runtime.session_flow.processAttention(gateway, os_process.monotonicNowNsOrZero());
            try gateway_runtime.session_flow.removeDroppedSessions(gateway);
        }
    }

    /// `command_flow.handleCommands`, step for step, with each fetch start
    /// noted before the gateway handles it (`noteCommand`). Returns false
    /// when the session must be removed.
    fn handleCommands(self: *LocalEgressGateway, session: *egress_gateway.sessions.Session) bool {
        const gateway = self.gateway;
        ipc.egress_shared.drainEventfd(session.endpoint.command_eventfd);
        gateway_runtime.release_flow.drainReleases(gateway, session);
        defer gateway_runtime.session_flow.wakeWorkerAfterCommandDrops(session);
        var drained: usize = 0;
        while (drained < gateway_runtime.command_flow.command_drain_batch) : (drained += 1) {
            // A ring that fails its checks breaks the protocol, as in `command_flow.handleCommands`.
            const read = session.endpoint.command.readPacket(gateway.read_scratch) catch return false;
            const packet = read orelse return true;
            self.noteCommand(packet);
            if (!gateway_runtime.command_flow.handlePacket(gateway, session, packet))
                return false;
        }
        ipc.egress_shared.notify(session.endpoint.command_eventfd);
        return true;
    }

    /// Records the token of a fetch start and, under `.local_origins`,
    /// grants the origin its URL names before admission reads the policy. A
    /// packet that is no fetch start, or does not decode, is left to the
    /// gateway, which removes the session for one it cannot decode.
    fn noteCommand(self: *LocalEgressGateway, packet: []const u8) void {
        if (packet.len < @sizeOf(u32))
            return;
        const kind = ipc.decodeMessageKind(ipc.packet.readStruct(u32, packet[0..@sizeOf(u32)])) catch return;
        if (kind != .egress_fetch_start)
            return;
        const fetch = ipc.decodeEgressFetchStart(self.gateway.decode_scratch, packet) catch return;
        self.grantLocalOrigin(fetch.url);
        self.fetch_start_mutex.lock();
        defer self.fetch_start_mutex.unlock();
        if (self.fetch_start_count < self.fetch_starts.len)
            self.fetch_starts[self.fetch_start_count] = .{ .egress_token = fetch.egress_token };
        self.fetch_start_count += 1;
    }

    /// Writes the packet the test thread handed over, if any, and wakes the
    /// test thread with the outcome.
    fn answerMailbox(self: *LocalEgressGateway) void {
        drainEventFd(self.mailbox.fd);
        self.mailbox.mutex.lock();
        defer self.mailbox.mutex.unlock();
        const bytes = self.mailbox.packet orelse return;
        if (self.mailbox.done)
            return;
        self.mailbox.failure = self.writeCompletion(bytes);
        self.mailbox.done = true;
        self.mailbox.condition.signal();
    }

    fn writeCompletion(self: *LocalEgressGateway, bytes: []const u8) ?anyerror {
        const session = self.gateway.sessions.byId(local_egress_session_id) orelse
            return error.LocalEgressSessionRemoved;
        const result = egress_gateway.publisher.queuePacket(&session.endpoint, bytes) catch |err|
            return err;
        ipc.egress_shared.notifyAfterPacketWrite(session.endpoint.completion_eventfd, result);
        return null;
    }

    /// Sends the hello a server sends, carrying `test_egress_key` and
    /// `helloImage`, and has the gateway take it.
    fn sendHello(self: *LocalEgressGateway) !void {
        const image = try helloImage(self.allocator);
        defer self.allocator.free(image);
        var memfd = fd_mod.OwnedFd.fromRaw(try std.posix.memfd_create(
            "collo-test-policy-image",
            std.os.linux.MFD.CLOEXEC | std.os.linux.MFD.ALLOW_SEALING,
        ));
        defer memfd.deinit();
        try fd_mod.writeAllRaw(memfd.fd(), image);
        try fd_mod.addSeals(memfd.fd(), fd_mod.memfd_readonly_seals);
        try egress_gateway.control.sendHello(self.server_fd, &test_egress_key, memfd.fd(), @intCast(image.len));
        if (try gateway_runtime.control_flow.drainControl(self.gateway))
            return error.LocalEgressGatewayStopped;
        if (!self.gateway.hello.received)
            return error.LocalEgressGatewayHelloLost;
    }

    /// The hello's policy image, built as a server builds one: policy
    /// `harness_policy_id` grants any public host over HTTPS on the default
    /// port, as a `"*"` grant does.
    fn helloImage(allocator: std.mem.Allocator) ![]u8 {
        var builder = collo_network.Builder.init(allocator);
        defer builder.deinit();
        const any_host = [_]collo_network.Pattern{.{ .host = .any, .port = 0 }};
        const grant = try builder.addGrant(.{ .allow = &any_host });
        const policy_id = try builder.addPolicy(&[_]collo_network.table.GrantId{grant});
        if (policy_id != harness_policy_id)
            return error.UnexpectedLocalEgressPolicyId;
        return builder.encode(allocator);
    }

    /// Makes policy `harness_policy_id` the public HTTPS grant alone, the
    /// start of what `.local_origins` extends.
    fn installLocalPolicy(self: *LocalEgressGateway) void {
        self.local_members[0] = collo_network.public_https.grants[0];
        self.local_member_count = 1;
        self.publishLocalPolicy();
    }

    /// Puts the members so far in the gateway's decoded table, where
    /// admission finds the policy a token names and copies it into the
    /// fetch.
    fn publishLocalPolicy(self: *LocalEgressGateway) void {
        self.gateway.hello.table.?.policies[harness_policy_id] = .{
            .grants = self.local_members[0..self.local_member_count],
        };
    }

    /// Under `.local_origins`, adds the grant of `url`'s IPv4 literal on its
    /// port to policy `harness_policy_id` unless it holds one. A URL whose
    /// host is no IPv4 literal gets nothing, nor does one origin past
    /// `local_grants_max`, and the transport judges it on the grants there
    /// are.
    fn grantLocalOrigin(self: *LocalEgressGateway, url: []const u8) void {
        switch (self.network) {
            .public_https => return,
            .local_origins => {},
        }
        const origin = ipv4OriginOf(url) orelse return;
        const granted = self.local_member_count - 1;
        for (self.local_grants[0..granted]) |*slot| {
            const rule = slot.rule[0];
            if (std.mem.eql(u8, &rule.host.ipv4, &origin.bytes) and rule.port == origin.port)
                return;
        }
        if (granted == local_grants_max)
            return;
        const slot = &self.local_grants[granted];
        slot.rule = .{.{ .host = .{ .ipv4 = origin.bytes }, .port = origin.port }};
        slot.grant = .{
            .allow_http = true,
            .allow_private_networks = true,
            .any = false,
            .names = &.{},
            .suffixes = &.{},
            .ipv4 = &slot.rule,
            .ipv6 = &.{},
        };
        self.local_members[self.local_member_count] = &slot.grant;
        self.local_member_count += 1;
        self.publishLocalPolicy();
    }

    const Ipv4Origin = struct { bytes: [4]u8, port: u16 };

    /// The IPv4 literal and the port of an `http` or `https` URL, or null for
    /// any other URL, which the transport judges on its own.
    fn ipv4OriginOf(url: []const u8) ?Ipv4Origin {
        const uri = std.Uri.parse(url) catch return null;
        const default_port: u16 = if (std.ascii.eqlIgnoreCase(uri.scheme, "http"))
            80
        else if (std.ascii.eqlIgnoreCase(uri.scheme, "https"))
            443
        else
            return null;
        var host_buffer: [std.Uri.host_name_max]u8 = undefined;
        const host_text = uri.getHost(&host_buffer) catch return null;
        const address = std.net.Address.parseIp4(host_text, 0) catch return null;
        return .{ .bytes = collo_network.address.ipv4Bytes(address), .port = uri.port orelse default_port };
    }
};

/// Duplicates every descriptor of `fds` with close-on-exec. The caller owns
/// the copies; on failure none is left open.
pub fn dupSharedFds(fds: ipc.egress_shared.RawFds) !ipc.egress_shared.RawFds {
    var command_control = try fd_mod.OwnedFd.dupCloexec(fds.command_control_fd);
    errdefer command_control.deinit();
    var command_producer = try fd_mod.OwnedFd.dupCloexec(fds.command_producer_fd);
    errdefer command_producer.deinit();
    var command_consumer = try fd_mod.OwnedFd.dupCloexec(fds.command_consumer_fd);
    errdefer command_consumer.deinit();
    var command_data = try fd_mod.OwnedFd.dupCloexec(fds.command_data_fd);
    errdefer command_data.deinit();
    var completion_control = try fd_mod.OwnedFd.dupCloexec(fds.completion_control_fd);
    errdefer completion_control.deinit();
    var completion_producer = try fd_mod.OwnedFd.dupCloexec(fds.completion_producer_fd);
    errdefer completion_producer.deinit();
    var completion_consumer = try fd_mod.OwnedFd.dupCloexec(fds.completion_consumer_fd);
    errdefer completion_consumer.deinit();
    var completion_data = try fd_mod.OwnedFd.dupCloexec(fds.completion_data_fd);
    errdefer completion_data.deinit();
    var body_pool_control = try fd_mod.OwnedFd.dupCloexec(fds.body_pool_control_fd);
    errdefer body_pool_control.deinit();
    var body_pool_producer = try fd_mod.OwnedFd.dupCloexec(fds.body_pool_producer_fd);
    errdefer body_pool_producer.deinit();
    var body_pool_consumer = try fd_mod.OwnedFd.dupCloexec(fds.body_pool_consumer_fd);
    errdefer body_pool_consumer.deinit();
    var body_pool_data = try fd_mod.OwnedFd.dupCloexec(fds.body_pool_data_fd);
    errdefer body_pool_data.deinit();
    var upload_pool_control = try fd_mod.OwnedFd.dupCloexec(fds.upload_pool_control_fd);
    errdefer upload_pool_control.deinit();
    var upload_pool_producer = try fd_mod.OwnedFd.dupCloexec(fds.upload_pool_producer_fd);
    errdefer upload_pool_producer.deinit();
    var upload_pool_consumer = try fd_mod.OwnedFd.dupCloexec(fds.upload_pool_consumer_fd);
    errdefer upload_pool_consumer.deinit();
    var upload_pool_data = try fd_mod.OwnedFd.dupCloexec(fds.upload_pool_data_fd);
    errdefer upload_pool_data.deinit();
    var command_event = try fd_mod.OwnedFd.dupCloexec(fds.command_eventfd);
    errdefer command_event.deinit();
    var completion_event = try fd_mod.OwnedFd.dupCloexec(fds.completion_eventfd);
    errdefer completion_event.deinit();
    var liveness = try fd_mod.OwnedFd.dupCloexec(fds.liveness_fd);
    errdefer liveness.deinit();
    var peer_liveness = try fd_mod.OwnedFd.dupCloexec(fds.peer_liveness_fd);
    errdefer peer_liveness.deinit();
    return .{
        .command_control_fd = command_control.release(),
        .command_producer_fd = command_producer.release(),
        .command_consumer_fd = command_consumer.release(),
        .command_data_fd = command_data.release(),
        .completion_control_fd = completion_control.release(),
        .completion_producer_fd = completion_producer.release(),
        .completion_consumer_fd = completion_consumer.release(),
        .completion_data_fd = completion_data.release(),
        .body_pool_control_fd = body_pool_control.release(),
        .body_pool_producer_fd = body_pool_producer.release(),
        .body_pool_consumer_fd = body_pool_consumer.release(),
        .body_pool_data_fd = body_pool_data.release(),
        .upload_pool_control_fd = upload_pool_control.release(),
        .upload_pool_producer_fd = upload_pool_producer.release(),
        .upload_pool_consumer_fd = upload_pool_consumer.release(),
        .upload_pool_data_fd = upload_pool_data.release(),
        .command_eventfd = command_event.release(),
        .completion_eventfd = completion_event.release(),
        .liveness_fd = liveness.release(),
        .peer_liveness_fd = peer_liveness.release(),
    };
}

fn signalEventFd(fd: std.posix.fd_t) void {
    var one: u64 = 1;
    _ = std.posix.write(fd, std.mem.asBytes(&one)) catch |err|
        std.debug.panic("failed to signal test eventfd: {s}", .{@errorName(err)});
}

fn drainEventFd(fd: std.posix.fd_t) void {
    while (true) {
        var counter: u64 = 0;
        // Only an empty counter is benign: a harness reader that swallowed
        // a real channel failure would let a broken test pass.
        _ = std.posix.read(fd, std.mem.asBytes(&counter)) catch |err| switch (err) {
            error.WouldBlock => return,
            else => std.debug.panic("failed to drain test eventfd: {s}", .{@errorName(err)}),
        };
    }
}

/// A one-connection HTTP/1.1 origin, served by its own thread, that a worker
/// fetches at `host()`, the routable local address `test_net` finds. It
/// answers `GET /binary` with three raw bytes, and `POST /data` with
/// `post ok` only when the request carries `x-collo-test: yes`, the body
/// `payload` and no cookie header; anything else gets `bad`. Every response
/// sets two cookies. `stop` connects once itself, so a thread still in
/// accept returns.
pub const LocalOrigin = struct {
    server: std.net.Server,
    host_buffer: [64]u8,
    host_len: usize,
    port: u16,
    thread: std.Thread,
    accepted: std.atomic.Value(usize),

    pub fn start(allocator: std.mem.Allocator) !*LocalOrigin {
        var host_buffer: [64]u8 = undefined;
        const host_len = try routableLocalIpv4(&host_buffer);
        var address = try std.net.Address.parseIp4("0.0.0.0", 0);
        var server = try address.listen(.{ .reuse_address = true });
        errdefer server.deinit();
        const origin = try allocator.create(LocalOrigin);
        errdefer allocator.destroy(origin);
        origin.* = .{
            .server = server,
            .host_buffer = host_buffer,
            .host_len = host_len,
            .port = server.listen_address.getPort(),
            .thread = undefined,
            .accepted = std.atomic.Value(usize).init(0),
        };
        origin.thread = try std.Thread.spawn(.{}, LocalOrigin.threadMain, .{origin});
        return origin;
    }

    pub fn host(self: *const LocalOrigin) []const u8 {
        return self.host_buffer[0..self.host_len];
    }

    pub fn stop(self: *LocalOrigin, allocator: std.mem.Allocator) void {
        const address = std.net.Address.parseIp(self.host(), self.port) catch null;
        if (address) |addr| {
            if (std.net.tcpConnectToAddress(addr)) |stream| {
                stream.close();
            } else |_| {}
        }
        self.thread.join();
        self.server.deinit();
        allocator.destroy(self);
    }

    fn threadMain(self: *LocalOrigin) void {
        var connection = self.server.accept() catch return;
        defer connection.stream.close();
        _ = self.accepted.fetchAdd(1, .acq_rel);

        var buffer: [2048]u8 = undefined;
        const received = readHttpRequest(connection.stream, &buffer) catch return;
        const binary = std.mem.containsAtLeast(u8, received, 1, "GET /binary HTTP/1.1");
        const ok = std.mem.containsAtLeast(u8, received, 1, "POST /data HTTP/1.1") and
            std.mem.containsAtLeast(u8, received, 1, "x-collo-test: yes") and
            !std.mem.containsAtLeast(u8, received, 1, "\r\ncookie:") and
            std.mem.containsAtLeast(u8, received, 1, "\r\n\r\npayload");
        const body: []const u8 = if (binary) &.{ 0, 255, 65 } else if (ok) "post ok" else "bad";
        var head: [256]u8 = undefined;
        const response_head = std.fmt.bufPrint(
            &head,
            "HTTP/1.1 200 OK\r\ncontent-length: {d}\r\nx-collo-origin: local\r\nset-cookie: session=abc\r\nset-cookie: theme=dark\r\nconnection: close\r\n\r\n",
            .{body.len},
        ) catch return;
        connection.stream.writeAll(response_head) catch return;
        connection.stream.writeAll(body) catch return;
    }

    fn readHttpRequest(stream: std.net.Stream, buffer: []u8) ![]const u8 {
        var received_len: usize = 0;
        while (received_len < buffer.len) {
            const amount = try stream.read(buffer[received_len..]);
            if (amount == 0)
                break;
            received_len += amount;

            if (std.mem.indexOf(u8, buffer[0..received_len], "\r\n\r\n")) |header_end| {
                const header_bytes = buffer[0..header_end];
                const body_start = header_end + 4;
                const content_length = try http1_common.parseUniqueContentLengthHeader(header_bytes) orelse 0;
                if (received_len >= body_start + content_length)
                    break;
            }
        }
        return buffer[0..received_len];
    }
};

fn routableLocalIpv4(out: *[64]u8) !usize {
    const address = try local_address.routableLocalIpv4(out);
    return address.len;
}
