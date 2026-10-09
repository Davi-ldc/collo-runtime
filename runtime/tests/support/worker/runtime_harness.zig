//! The worker runtime harness (`collo_test_harness`): a host for tests that
//! run a worker runtime in process, or talk to a forked worker through the
//! host client (`host.dispatch`). A dispatch names its route by its index in
//! the worker's route table and carries no pack, so the routes and their
//! pack reach the worker first: a forked worker takes them in WorkerInit
//! (`host.launch.LaunchOptions.routes`, which `SingleRoute` builds for one
//! route), and an in-process runtime through `registerRoutePack`, which
//! registers the pack as a worker's boot does, adds the route unless the
//! runtime already has one with that entry, and leaves the entry for the
//! route's first request to evaluate. The harness builds
//! dispatches with test defaults, each carrying an egress token minted under
//! `test_egress_key` for `LocalEgressGateway`'s session, reads responses and
//! completion records back within a bounded budget, and stands in for the
//! egress gateway and for an HTTP/1.1 origin where a test needs them. The
//! worker runtime suites, the zygote integration lane and the web API suites
//! share it.
//!
//! Everything runs on the test's thread except `LocalEgressGateway`, whose
//! packet loop has a thread of its own besides the threads its engine
//! starts, and `LocalOrigin`, which serves from one thread. In-process
//! runtimes read a fake clock through `fakeNow`, and the dispatch defaults
//! here are instants on such a clock; a forked worker reads the real clock
//! and needs a deadline taken from it.

const std = @import("std");
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
const gateway_engine = egress_gateway.engine;

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

/// The key the harness mints egress tokens under. `LocalEgressGateway` submits
/// fetches without admission, so it never checks a tag; a test that reads a
/// recorded token back verifies it with this key (`verifyEgressToken`).
pub const test_egress_key: ipc.egress_token.Key = .{ .bytes = @splat(0x5c) };

/// The worker session `LocalEgressGateway` serves, which every harness token
/// names.
pub const local_egress_session_id: u64 = 1;

/// The network policy of a fetch to a `LocalOrigin`, which serves plain HTTP
/// on a private address of the host.
pub const local_origin_network: egress_gateway.policy.NetworkPolicy = .{
    .kind = .any_host,
    .allow_private_networks = true,
    .allow_http = true,
};

/// The token the server's lane mints for a request dispatched to a worker
/// attached to `LocalEgressGateway`'s session: kind request, the single
/// policy, the production budget, and the request's own id, generation and
/// deadline.
pub fn requestEgressToken(parts: DispatchParts) ipc.egress_token.Bytes {
    const token = ipc.egress_token.mint(&test_egress_key, .{
        .kind = .request,
        .policy_id = egress_gateway.policy.public_https_id,
        .budget = @intCast(egress_gateway.policy.production.max_fetches_per_request),
        .session_id = local_egress_session_id,
        .request_id = parts.request_id,
        .request_generation = parts.request_generation,
        .deadline_monotonic_ns = parts.deadline_monotonic_ns,
    });
    return ipc.egress_token.asBytes(&token).*;
}

/// The boot token a launch with an egress grant hands its worker in
/// WorkerInit, minted as `host/launch.zig` mints it, with
/// `deadline_monotonic_ns` standing for the end of the child window. An
/// in-process runtime takes it through `Runtime.installBootContext`.
pub fn bootEgressToken(deadline_monotonic_ns: u64) ipc.egress_token.Bytes {
    const token = ipc.egress_token.mint(&test_egress_key, .{
        .kind = .boot,
        .policy_id = egress_gateway.policy.public_https_id,
        .budget = @intCast(egress_gateway.policy.production.max_fetches_per_boot),
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
        .policy_id = egress_gateway.policy.public_https_id,
        .budget = @intCast(egress_gateway.policy.production.max_fetches_per_boot),
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
    /// The route's index in the worker's route table: what
    /// `registerRoutePack` returned for an in-process runtime, or the
    /// route's position in the table a forked worker launched with.
    route_index: u16 = 0,
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
    return work;
}

/// A request that is really live in `runtime.requests.active`, with a real
/// `RequestContext` behind its entry; `deinit` removes and frees it.
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
        ctx.* = worker_testing.RequestContext.initOwnedDispatch(
            allocator,
            0,
            dispatch,
            .{ .index = 0, .generation = 0 },
            started_mono_ns,
        );
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

pub fn createModulePackFd(specifier: []const u8, source: []const u8) !std.posix.fd_t {
    return host.dispatch.createModulePackFd(std.testing.allocator, specifier, source);
}

pub fn createModulePackGraphFd(modules: []const ipc.module_pack.Module, entry_index: usize) !std.posix.fd_t {
    return host.dispatch.createModulePackGraphFd(std.testing.allocator, modules, entry_index);
}

/// Registers the pack in `route_fd`, which stays the caller's, with the
/// in-process `runtime` as permanent, as a worker's boot registers its
/// definition's pack (`registerRoutePack` in `worker/modules/routes.zig`),
/// and returns the index of the runtime's route whose entry is `specifier`,
/// added with no bindings when the runtime has none. The entry stays
/// unevaluated: the route's first request evaluates it. Registers nothing
/// when a registered pack already holds `specifier`. Fails as that
/// registration does, for instance on an fd that is not a sealed memfd or a
/// pack that does not hold `specifier`.
pub fn registerRoutePack(runtime: *worker.Runtime, route_fd: std.posix.fd_t, specifier: []const u8) !u16 {
    var modules_ctx = runtime.modulesContext();
    try worker.testing.module_routes.registerRoutePack(&modules_ctx, route_fd, specifier);
    return routeIndex(runtime, specifier) orelse addRoute(runtime, specifier);
}

/// Adds a route whose entry is `specifier`, with no bindings, to the
/// in-process `runtime`, as the route table WorkerInit carries declares a
/// forked worker's routes, and returns its index. Its pack is registered
/// apart: by `registerRoutePack`, or by a boot evaluation
/// (`Runtime.evaluateBootRoutes`).
pub fn addRoute(runtime: *worker.Runtime, specifier: []const u8) !u16 {
    return runtime.modules.state.addRoute(runtime.core.allocator, specifier, &ipc.route_bindings.empty_blob);
}

/// The module state of the first route of `runtime` whose entry is
/// `specifier`, or null when it has none.
pub fn routeModule(runtime: *worker.Runtime, specifier: []const u8) ?*const worker.testing.module_routes.RouteModuleState {
    const index = routeIndex(runtime, specifier) orelse return null;
    return &runtime.modules.state.routes.items[index].module;
}

/// Registers a one-module pack of `source` at `specifier` with `runtime`
/// and returns the route's index (`registerRoutePack`).
pub fn registerRoute(runtime: *worker.Runtime, specifier: []const u8, source: []const u8) !u16 {
    const route_fd = try createModulePackFd(specifier, source);
    defer std.posix.close(route_fd);
    return registerRoutePack(runtime, route_fd, specifier);
}

/// The index of the first route of `runtime` whose entry is `specifier`.
pub fn routeIndex(runtime: *const worker.Runtime, specifier: []const u8) ?u16 {
    for (runtime.modules.state.routes.items, 0..) |route, index| {
        if (std.mem.eql(u8, route.entry_specifier, specifier))
            return @intCast(index);
    }
    return null;
}

/// The routes of a forked worker that serves one route with no bindings:
/// the sealed table of that route, which this owns, and the pack holding
/// its entry, which stays the caller's.
pub const SingleRoute = struct {
    table: ipc.route_table.Sealed,
    pack_fd: std.posix.fd_t,

    pub fn init(pack_fd: std.posix.fd_t, specifier: []const u8) !SingleRoute {
        const table = try ipc.route_table.buildSealed(std.testing.allocator, &.{.{
            .entry_specifier = specifier,
            .bindings = &.{},
        }});
        return .{ .table = table, .pack_fd = pack_fd };
    }

    /// What `host.launch.LaunchOptions.routes` takes; borrows both memfds.
    pub fn launchRoutes(self: *const SingleRoute) host.launch.LaunchRoutes {
        return .{ .table = self.table, .module_pack_fd = self.pack_fd, .isolate_realm = false };
    }

    pub fn deinit(self: *SingleRoute) void {
        self.table.close();
        self.* = undefined;
    }
};

/// `specifier` itself when it already carries a pack hash, otherwise the
/// same path under `/__collo_route/test/`; the caller frees the result.
pub fn routeSpecifier(allocator: std.mem.Allocator, specifier: []const u8) ![]u8 {
    if (ipc.module_pack.deployHashFromSpecifier(specifier) != null)
        return allocator.dupe(u8, specifier);
    const suffix = if (std.mem.startsWith(u8, specifier, "/")) specifier[1..] else specifier;
    return std.fmt.allocPrint(allocator, "/__collo_route/test/{s}", .{suffix});
}

/// Wall budget of the readers that take a runtime. An in-process flow has
/// already run to completion when its reader starts, so the budget only
/// keeps a harness bug from hanging the suite.
pub const default_read_budget_ms: u32 = 10_000;

/// In-process stand-in for the shared state page a host launch builds
/// (`host.launch.Machine`): the memfd and its writer view. Tests hand
/// `&fixture.view` and a fresh eventfd from `createCompletionEventfd()` to
/// `Runtime.init`, the completion channel every forked worker receives too.
pub const CompletionFixture = struct {
    memfd: std.posix.fd_t,
    view: worker_shared_page.WorkerWriterView,

    pub fn init() !CompletionFixture {
        const memfd = try worker_shared_page.createMemfd("collo-test-worker-metrics");
        errdefer std.posix.close(memfd);
        var view = try worker_shared_page.mapReadWrite(memfd);
        errdefer view.deinit();
        view.initializeCrashDefault(@intCast(std.os.linux.getpid()), 512 * 1024 * 1024, 0);
        return .{ .memfd = memfd, .view = view };
    }

    pub fn deinit(self: *CompletionFixture) void {
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

/// The two completion channels of one worker, as the host client reads
/// them; the in-process and the forked topologies share the shape.
pub const CompletionChannels = host.dispatch.CompletionChannels;

pub fn runtimeCompletionChannels(
    runtime: *worker.Runtime,
    server_control_fd: std.posix.fd_t,
) CompletionChannels {
    return .{
        .control_fd = server_control_fd,
        .completion_eventfd = runtime.egress.completion_eventfd,
        .metrics = runtime.observability.metrics_view,
        .ingress_payload = if (runtime.requests.ingress_payload) |*ingress_payload| ingress_payload else null,
    };
}

/// Waits up to `default_read_budget_ms` for the completion record of
/// `request_id` on the metrics page and returns it. The control fd is left
/// unread, so response frames stay queued on it. `host.dispatch.readResponse`
/// owns the read order.
pub fn readWorkerCompletion(
    runtime: *worker.Runtime,
    server_control_fd: std.posix.fd_t,
    request_id: u64,
) !worker_shared_page.WorkerCompletionRecord {
    var channels = runtimeCompletionChannels(runtime, server_control_fd);
    channels.control_fd = -1;
    var response = try readIngressResponseBounded(channels, request_id, default_read_budget_ms);
    defer response.deinit();
    return response.completion;
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

/// Registers `source` as the route at `specifier` (`routeSpecifier`) unless
/// the runtime already holds it, runs one request against it to completion
/// and reads the response; the caller owns the response.
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

    const request_item = runtime.scheduler.ready_queue.pop() orelse return error.MissingRequestWork;
    try worker_testing.executeWorkItem(runtime, request_item);
    try executeUntilRequestDone(runtime, request_id);

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

    const request_item = runtime.scheduler.ready_queue.pop() orelse return error.MissingRequestWork;
    try worker_testing.executeWorkItem(runtime, request_item);
    try executeUntilRequestDone(runtime, request_id);

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

    const request_item = runtime.scheduler.ready_queue.pop() orelse return error.MissingRequestWork;
    try worker_testing.executeWorkItem(runtime, request_item);
    try executeUntilRequestDone(runtime, request_id);

    return readIngressResponseBody(runtime, server_control_fd, request_id);
}

/// Hands `dispatch` to the in-process `runtime` as a request begin with its
/// encoded bytes inline, then `request.body` as one chunk when it is not
/// empty. The runtime must hold the route already (`registerRoutePack`).
/// The caller keeps `dispatch`.
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
/// (`host.dispatch.sendRequest`). The worker took its routes and their pack
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

pub fn readIngressResponse(
    runtime: *worker.Runtime,
    server_control_fd: std.posix.fd_t,
    request_id: u64,
) !IngressResponse {
    return readIngressResponseBounded(
        runtimeCompletionChannels(runtime, server_control_fd),
        request_id,
        default_read_budget_ms,
    );
}

/// Byte caps for the harness readers, set above any response a test streams,
/// so they only stop a runaway worker from exhausting the suite's memory.
pub const default_read_max_body_bytes: usize = 64 * 1024 * 1024;
pub const default_read_max_headers_bytes: usize = 1024 * 1024;

/// The host client's bounded two-channel reader, with the harness allocator.
pub fn readIngressResponseBounded(
    channels: CompletionChannels,
    request_id: u64,
    budget_ms: u32,
) !IngressResponse {
    return host.dispatch.readResponse(std.testing.allocator, channels, request_id, .{
        .wall_ms = budget_ms,
        .max_body_bytes = default_read_max_body_bytes,
        .max_headers_bytes = default_read_max_headers_bytes,
    });
}

/// Registers `source` as the route at `specifier` (`routeSpecifier`) unless
/// the runtime already holds it, and runs one request against it on
/// `stream_id` to completion. The response stays queued for the caller.
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

/// Runs the runtime's collectors and its ready queue until `request_id`
/// leaves `requests.active`. Fails with `error.RequestDidNotComplete` after a
/// fixed number of passes; a pass that finds nothing to run sleeps a
/// millisecond.
pub fn executeUntilRequestDone(runtime: *worker.Runtime, request_id: u64) !void {
    var attempts: usize = 0;
    while (runtime.requests.active.contains(request_id)) : (attempts += 1) {
        if (attempts > 1000)
            return error.RequestDidNotComplete;
        // A worker without a gateway session has no packets to collect.
        _ = try runtime.collectEgressGatewayPacketsBounded(64);
        runtime.collectModuleSettlements();
        try runtime.collectCompletedCryptoJobs();
        try runtime.collectCompletedFetches();
        try runtime.collectReadyFetchBodies();
        try runtime.collectDueTimers();
        try runtime.collectReadyImmediates();
        try runtime.collectDueRequestDeadlines();
        if (runtime.scheduler.ready_queue.pop()) |item| {
            try worker_testing.executeWorkItem(runtime, item);
            continue;
        }
        std.Thread.sleep(std.time.ns_per_ms);
    }
}

/// The identity of one FetchStart a worker sent its gateway, recorded as it
/// crossed the wire. A start names its request only through the egress token
/// it carries, so a test compares these bytes with the token it dispatched and
/// reads the request back with `verifyEgressToken`: a fetch from the boot
/// context, for instance, must arrive under the boot token.
pub const FetchStartIdentity = struct {
    egress_token: ipc.egress_token.Bytes,
};

/// A gateway engine (`egress/gateway/engine.zig`) whose packet loop runs on
/// its own thread in the test process, serving one worker session over a
/// real egress shared session (`ipc.egress_shared`). It runs no admission: it
/// records each start's token and submits the fetch under `Options.network`,
/// as a real gateway does once the token verified and named that policy.
/// `start` returns it heap-allocated; the caller gives the worker the fds
/// `takeWorkerSharedFds` returns and ends the gateway with `deinit`, which
/// panics if that thread failed. Ending it closes the gateway's end of the
/// session's liveness pipe, which a forked worker sees as its gateway gone.
pub const LocalEgressGateway = struct {
    allocator: std.mem.Allocator,
    worker_fds: ?ipc.egress_shared.SessionFds,
    endpoint: ipc.egress_shared.Endpoint,
    publish_mutex: std.Thread.Mutex = .{},
    stop_fd: std.posix.fd_t,
    engine: gateway_engine.Engine,
    network: egress_gateway.policy.NetworkPolicy,
    scratch: []u8,
    /// Where the gateway thread decodes fetch starts; a decoded view points
    /// into it until the next decode. It is on the heap because its arrays,
    /// sized by the protocol's limits, are too large for a stack.
    decode_scratch: *ipc.GatewayEgressDecodeScratch,
    thread: std.Thread,
    thread_error: ?anyerror = null,
    fetch_start_mutex: std.Thread.Mutex = .{},
    fetch_start_log: std.ArrayListUnmanaged(FetchStartIdentity) = .empty,
    /// Body-end packets the engine published, so a test can wait until the
    /// worker has been sent a whole body.
    body_ends_published: std.atomic.Value(usize) = .init(0),

    const worker_session_id: u64 = local_egress_session_id;

    pub const Options = struct {
        /// The engine's limits.
        policy: egress_gateway.policy.Policy = .{},
        /// The policy every fetch runs under. `local_origin_network` reaches
        /// a `LocalOrigin`; the default admits public HTTPS hosts only.
        network: egress_gateway.policy.NetworkPolicy = egress_gateway.policy.public_https,
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
        errdefer endpoint.deinit();
        endpoint.command.setSession(worker_session_id, worker_session_id);
        endpoint.completion.setSession(worker_session_id, worker_session_id);
        endpoint.body_pool.setSession(worker_session_id, worker_session_id);
        endpoint.upload_pool.setSession(worker_session_id, worker_session_id);

        const stop_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        errdefer std.posix.close(stop_fd);
        var engine = try gateway_engine.Engine.init(allocator, .{
            .queue_capacity = 64,
            .h2_connector_count = 1,
            .policy = options.policy,
        });
        errdefer engine.deinit();
        const scratch = try allocator.alloc(u8, ipc.max_message_bytes);
        errdefer allocator.free(scratch);
        const decode_scratch = try allocator.create(ipc.GatewayEgressDecodeScratch);
        errdefer allocator.destroy(decode_scratch);
        decode_scratch.* = .{};

        const self = try allocator.create(LocalEgressGateway);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .worker_fds = worker_fds,
            .endpoint = endpoint,
            .stop_fd = stop_fd,
            .engine = engine,
            .network = options.network,
            .scratch = scratch,
            .decode_scratch = decode_scratch,
            .thread = undefined,
        };
        self.engine.setPacketSender(self, sendPacketCallback);
        self.engine.setBodyChunkBatchSender(publishBodyChunkBatchCallback);
        try self.engine.start();
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
        worker_fds = .{};
        endpoint = undefined;
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
        self.engine.deinit();
        self.endpoint.deinit();
        self.allocator.free(self.scratch);
        self.allocator.destroy(self.decode_scratch);
        self.fetch_start_log.deinit(self.allocator);
        std.posix.close(self.stop_fd);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    /// Copies the recorded FetchStart identities (in arrival order) into
    /// `out`; returns how many were copied. A recording dropped on OOM fails
    /// the fixture's count assertion, so that assertion never passes
    /// vacuously.
    pub fn recordedFetchStarts(self: *LocalEgressGateway, out: []FetchStartIdentity) usize {
        self.fetch_start_mutex.lock();
        defer self.fetch_start_mutex.unlock();
        const count = @min(out.len, self.fetch_start_log.items.len);
        @memcpy(out[0..count], self.fetch_start_log.items[0..count]);
        return count;
    }

    /// The body-end packets the engine has written on the worker's
    /// completion ring so far.
    pub fn publishedBodyEnds(self: *const LocalEgressGateway) usize {
        return self.body_ends_published.load(.acquire);
    }

    /// Writes `bytes` on the worker's completion ring as one packet and wakes
    /// the worker, for a test that plays a gateway breaking the protocol.
    pub fn queueCompletionPacket(self: *LocalEgressGateway, bytes: []const u8) !void {
        const result = try egress_gateway.publisher.queuePacketForTarget(
            self.publisherTarget(),
            bytes,
        );
        self.notifyCompletionIfNeeded(result);
    }

    fn threadMain(self: *LocalEgressGateway) void {
        self.run() catch |err| {
            self.thread_error = err;
        };
    }

    fn run(self: *LocalEgressGateway) !void {
        var pollfds = [_]std.posix.pollfd{
            .{ .fd = self.stop_fd, .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR, .revents = 0 },
            .{ .fd = self.engine.wake_fd, .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR, .revents = 0 },
            .{ .fd = self.endpoint.command_eventfd, .events = std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR, .revents = 0 },
        };
        while (true) {
            for (&pollfds) |*pollfd|
                pollfd.revents = 0;
            _ = try std.posix.poll(&pollfds, -1);

            if ((pollfds[0].revents & (std.posix.POLL.IN | std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
                drainEventFd(self.stop_fd);
                return;
            }
            if ((pollfds[1].revents & std.posix.POLL.IN) != 0)
                try self.engine.collectReady();
            if ((pollfds[2].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0) {
                self.engine.detachWorker(worker_session_id);
                return;
            }
            if ((pollfds[2].revents & std.posix.POLL.IN) != 0) {
                if (!try self.handleWorkerPacket())
                    return;
                try self.engine.collectReady();
            }
        }
    }

    fn handleWorkerPacket(self: *LocalEgressGateway) !bool {
        ipc.egress_shared.drainEventfd(self.endpoint.command_eventfd);
        const bytes = (try self.endpoint.command.readPacket(self.scratch)) orelse return true;
        if (bytes.len < @sizeOf(u32))
            return error.ShortRead;

        const kind = try ipc.decodeMessageKind(ipc.packet.readStruct(u32, bytes[0..@sizeOf(u32)]));
        switch (kind) {
            .egress_fetch_start => {
                const fetch = try ipc.decodeEgressFetchStart(self.decode_scratch, bytes);
                {
                    self.fetch_start_mutex.lock();
                    defer self.fetch_start_mutex.unlock();
                    self.fetch_start_log.append(self.allocator, .{
                        .egress_token = fetch.egress_token,
                    }) catch {};
                }
                // Without admission the token is read unverified: its fields
                // only name the fetch's request inside the engine.
                const token = ipc.egress_token.fromBytes(&fetch.egress_token);
                self.engine.submit(worker_session_id, fetch, .{
                    // One session with one policy: every fetch shares the
                    // zero pool key.
                    .isolation = .{},
                    .network = self.network,
                    .budget_key = .{
                        .session_id = token.session_id,
                        .request_id = token.request_id,
                        .request_generation = token.request_generation,
                    },
                }) catch |err| {
                    try self.sendFetchError(fetch.fetch_id, fetch.body_id, @errorName(err));
                };
            },
            .egress_cancel => {
                if (bytes.len < @sizeOf(ipc.EgressCancel))
                    return error.InvalidEgressPacket;
                const cancel = ipc.packet.readStruct(ipc.EgressCancel, bytes[0..@sizeOf(ipc.EgressCancel)]);
                const expected_len = @sizeOf(ipc.EgressCancel) + @as(usize, @intCast(cancel.reason_len));
                if (expected_len != bytes.len)
                    return error.InvalidEgressPacket;
                self.engine.cancelFetch(worker_session_id, cancel);
            },
            .egress_release_body => {
                if (bytes.len != @sizeOf(ipc.EgressReleaseBody))
                    return error.InvalidEgressPacket;
                const release = ipc.packet.readStruct(ipc.EgressReleaseBody, bytes);
                self.engine.releaseBody(worker_session_id, release);
            },
            else => return error.InvalidEgressPacket,
        }
        return true;
    }

    fn sendFetchError(self: *LocalEgressGateway, fetch_id: u64, body_id: u64, message: []const u8) !void {
        const bytes = try ipc.encodeEgressFetchErrorInto(self.scratch, .{
            .fetch_id = fetch_id,
            .body_id = body_id,
            .message = message,
        });
        const result = try egress_gateway.publisher.queuePacketForTarget(
            self.publisherTarget(),
            bytes,
        );
        self.notifyCompletionIfNeeded(result);
    }

    fn sendPacketCallback(ctx: ?*anyopaque, session_id: u64, bytes: []const u8) !void {
        if (session_id != LocalEgressGateway.worker_session_id)
            return error.InvalidEgressPacket;
        const self: *LocalEgressGateway = @ptrCast(@alignCast(ctx orelse return error.InvalidEgressPacket));
        const result = try egress_gateway.publisher.queuePacketForTarget(
            self.publisherTarget(),
            bytes,
        );
        self.notifyCompletionIfNeeded(result);
        // Counted once the packet is on the ring, so a test that sees the
        // count can collect the end.
        const body_end_kind: u32 = @intFromEnum(ipc.MessageKind.egress_body_end);
        if (bytes.len >= @sizeOf(u32) and ipc.packet.readStruct(u32, bytes[0..@sizeOf(u32)]) == body_end_kind)
            _ = self.body_ends_published.fetchAdd(1, .release);
    }

    fn publishBodyChunkBatchCallback(
        ctx: ?*anyopaque,
        session_id: u64,
        fetch_id: u64,
        body_id: u64,
        chunks: []const gateway_engine.BodyChunkPayload,
        scratch: []u8,
    ) !usize {
        if (session_id != LocalEgressGateway.worker_session_id)
            return error.InvalidEgressPacket;
        const self: *LocalEgressGateway = @ptrCast(@alignCast(ctx orelse return error.InvalidEgressPacket));
        var extents: [ipc.egress_shared.body_pool_slot_count]egress_gateway.publisher.PublishedExtent = undefined;
        const result = try egress_gateway.publisher.publishBodyChunkBatchForTarget(
            self.publisherTarget(),
            fetch_id,
            body_id,
            chunks,
            scratch,
            &extents,
        );
        self.notifyCompletionIfNeeded(result.write);
        return result.extents;
    }

    fn notifyCompletionIfNeeded(
        self: *LocalEgressGateway,
        result: ipc.egress_shared.PacketWriteResult,
    ) void {
        ipc.egress_shared.notifyAfterPacketWrite(self.endpoint.completion_eventfd, result);
    }

    fn publisherTarget(self: *LocalEgressGateway) egress_gateway.publisher.Target {
        return .{
            .endpoint = &self.endpoint,
            .publish_mutex = &self.publish_mutex,
        };
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
