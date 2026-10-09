//! The production stack the local-e2e suites of this directory drive, and
//! what they drive it with. `Harness` is one stack per test: TLS material, a
//! zygote that forks fully sandboxed workers, the delegated cgroup root, an
//! analytics directory, and a server on a thread of the test process serving
//! the routes of `fixtures/local_e2e/collo.json` on one lane or two. Requests
//! go out through the h2 client of the TLS test shim
//! (`runtime/tests/support/tls/`), one GET per connection (`h2Get`) or on a
//! connection held across requests (`Client`), placed on a chosen lane when
//! the server runs two (`openClientOnLane`). What the server leaves behind
//! is read back here too: the analytics records, the live workers of a pool
//! and the launches that made them, and the egress gateway it runs, whose
//! process a test can kill as it kills a worker.
//!
//! Everything here runs on the test thread, or on a client thread a test
//! starts; the zygote, its workers and the gateway are processes of their
//! own. The lane runs from the repository root, which anchors the fixture
//! paths, and a harness skips its test when the machine lacks what the stack
//! needs (`skills/runtime/references/e2e.md`).

const std = @import("std");
const server_main = @import("collo_server_main");
const config = @import("collo_server_config");
const routes_mod = @import("collo_server_routes");
const hpack = @import("collo_hpack");
const host = @import("collo_host");
const supervision = @import("collo_server_supervisor");
const process = @import("collo_os").process;
const gateway_launch = @import("collo_egress_gateway").launch;
const zygote_support = @import("zygote_support");
const local_server_options = @import("local_server_options");
const tls_shim = @import("collo_test_tls_shim");

pub const LaunchTrace = supervision.launcher.LaunchTrace;
const WorkerRecord = supervision.worker_table.Record;
const WorkerKey = server_main.lifecycle.WorkerKey;

const local_cgroup_root = "/sys/fs/cgroup/collo-dev";

/// The configuration every test serves unless it writes its own.
pub const fixture_config_path = "runtime/tests/integration/fixtures/local_e2e/collo.json";
pub const fixture_api_directory = "runtime/tests/integration/fixtures/local_e2e/api";

/// The `:authority` and SNI of every request the shim's harness calls send.
const harness_authority = "demo.example.test";

extern fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern fn unsetenv(name: [*:0]const u8) c_int;

pub const HarnessOptions = struct {
    /// The configuration to serve; a relative path resolves against the
    /// repository root, where the lane runs.
    config_path: []const u8 = fixture_config_path,
    /// Spawns the gateway before traffic. Spawning it lazily would put its
    /// exec, shard threads, Landlock and seccomp, milliseconds in all, inside
    /// the first launch, where the benchmarks would measure them.
    prewarm_gateway: bool = true,
    /// Ingress lanes the server runs. One keeps every connection on the same
    /// lane; two let a test place connections on different lanes
    /// (`openClientOnLane`). A host that allows the server fewer CPUs than
    /// this skips the test.
    lane_count: usize = 1,
};

/// One production stack: TLS material, a zygote, the delegated cgroup root,
/// the server serving the routes of a configuration with an analytics
/// directory, and the thread that runs it. A test initializes it in place,
/// because the server keeps pointers into these fields; `init` releases what
/// it acquired on failure and `deinit` releases everything in reverse order.
pub const Harness = struct {
    tls_material: tls_shim.TlsMaterial,
    spawned: zygote_support.zygote.host_client.SpawnedZygote,
    cgroup_environment: CgroupEnvironment,
    /// The analytics directory the server appends `usage.jsonl`,
    /// `access.jsonl` and `logs.jsonl` to.
    analytics_root: []const u8,
    /// Every worker is born inside a leaf of this subtree. The server borrows
    /// it, as it does under `collo serve`.
    worker_cgroup_root: host.WorkerCgroupRoot,
    /// Owns the routes built from the configuration (`Server.routes`).
    runtime_server: server_main.Server,
    server_thread: std.Thread,
    server_thread_joined: bool,

    pub fn init(self: *Harness, options: HarnessOptions) !void {
        if (tls_shim.collo_test_tls_material_create(&self.tls_material) != 0) {
            printShimError("create the TLS material");
            return error.TlsMaterialCreateFailed;
        }
        errdefer tls_shim.collo_test_tls_material_cleanup(&self.tls_material);

        _ = server_main.tls.KtlsNegotiationPolicy.fromCapabilities(server_main.ktls_mod.KernelCapabilities.probe()) catch |err| switch (err) {
            error.NoUsableKtlsCipher => return error.SkipZigTest,
            else => return err,
        };

        self.spawned = try zygote_support.spawnZygote();
        errdefer self.spawned.deinit();

        self.cgroup_environment = try CgroupEnvironment.init(std.testing.allocator);
        errdefer self.cgroup_environment.deinit(std.testing.allocator);

        self.analytics_root = try zygote_support.makeTempPath(
            std.testing.allocator,
            "collo-local-h2-e2e-analytics",
        );
        errdefer std.testing.allocator.free(self.analytics_root);
        try std.fs.makeDirAbsolute(self.analytics_root);
        errdefer std.fs.deleteTreeAbsolute(self.analytics_root) catch {};

        // The host claims a directory of its own under the delegated root and
        // creates one leaf there per fork (`host/cgroup_root.zig`).
        self.worker_cgroup_root = host.WorkerCgroupRoot.init(
            std.testing.allocator,
            .{ .env_root = local_cgroup_root },
        ) catch |err| switch (err) {
            error.WorkerCgroupDelegationUnavailable => return error.SkipZigTest,
            else => return err,
        };
        errdefer self.worker_cgroup_root.deinit(std.testing.allocator);

        var diagnostic: config.Diagnostic = .{};
        const loaded = config.load(std.testing.allocator, options.config_path, &diagnostic) catch |err| {
            std.debug.print("configuration rejected: {s}\n", .{diagnostic.message()});
            return err;
        };
        var routes: routes_mod.Routes = undefined;
        routes.init(std.testing.allocator, loaded, &diagnostic) catch |err| {
            std.debug.print("routes failed to build: {s}\n", .{diagnostic.message()});
            return err;
        };

        // `Server.init` owns the routes from here on, failure included.
        self.runtime_server = server_main.Server.init(std.testing.allocator, &self.spawned, .{
            .worker_cgroup_root = &self.worker_cgroup_root,
            .routes = routes,
            .analytics_directory = self.analytics_root,
            // The lanes the test asks for, whatever the host, so the
            // benchmarks measure the same topology everywhere and each
            // harness boot stays small.
            .ingress_lane_override = options.lane_count,
            .tls_certificate = .{
                .cert_chain = .{ .path = nulTerminatedPath(self.tls_material.server_cert[0..]) },
                .private_key = .{ .path = nulTerminatedPath(self.tls_material.server_key[0..]) },
            },
            .egress_gateway = .{
                .executable_path = local_server_options.egress_gateway_executable_path,
                // The test origin is plain HTTP on this host's private
                // address (`GzipOrigin` in `e2e.zig`), so every gateway's one
                // policy admits both. Loopback stays denied whatever the
                // flags say.
                .network_policy = .{
                    .kind = .any_host,
                    .allow_private_networks = true,
                    .allow_http = true,
                },
            },
        }) catch |err| switch (err) {
            error.NoUsableKtlsCipher => return error.SkipZigTest,
            else => return err,
        };
        errdefer self.runtime_server.deinit();
        // The lane plan caps an explicit lane count at the CPUs the host
        // allows the server (`lane_plan.resolveStaticLaneCount`).
        if (self.runtime_server.lane_cpu_ids.len != options.lane_count) {
            std.debug.print("the host allows the server {d} CPUs, fewer than the {d} lanes the test needs\n", .{
                self.runtime_server.lane_cpu_ids.len,
                options.lane_count,
            });
            return error.SkipZigTest;
        }
        if (options.prewarm_gateway)
            try self.runtime_server.prewarmEgressGateway();

        self.server_thread = try std.Thread.spawn(.{}, runServerThread, .{&self.runtime_server});
        self.server_thread_joined = false;
    }

    pub fn deinit(self: *Harness) void {
        if (!self.server_thread_joined)
            stopServerThread(&self.runtime_server, self.server_thread);
        self.runtime_server.deinit();
        // After the server, which borrows it.
        self.worker_cgroup_root.deinit(std.testing.allocator);
        self.cgroup_environment.deinit(std.testing.allocator);
        self.spawned.deinit();
        std.fs.deleteTreeAbsolute(self.analytics_root) catch {};
        std.testing.allocator.free(self.analytics_root);
        tls_shim.collo_test_tls_material_cleanup(&self.tls_material);
        self.* = undefined;
    }

    pub fn port(self: *const Harness) u16 {
        return self.runtime_server.port();
    }

    /// The server as the shim's held clients reach it: 127.0.0.1 on the
    /// harness's port, verified against the test CA.
    pub fn peer(self: *const Harness) tls_shim.H2Peer {
        return .{
            .material = &self.tls_material,
            .authority = harness_authority,
            .port = self.port(),
            .trust = .test_ca,
        };
    }

    /// The index of the configuration's worker definition `name`.
    pub fn definitionIndex(self: *const Harness, name: []const u8) !config.DefinitionIndex {
        return self.runtime_server.routes.config.findDefinition(name) orelse error.MissingFixtureWorker;
    }

    /// Moves the traces of the launches the launcher finished since the last
    /// call into `out`, oldest first (`Server.takeLaunchTraces`), and
    /// returns them.
    pub fn takeLaunches(self: *Harness, out: []LaunchTrace) []LaunchTrace {
        return out[0..self.runtime_server.takeLaunchTraces(out)];
    }

    /// The generation of the gateway the server holds now, 0 while it holds
    /// none (`Manager.currentGeneration`). A respawned gateway has a higher
    /// one.
    pub fn gatewayGeneration(self: *const Harness) u64 {
        return self.runtime_server.egress_gateways.currentGeneration();
    }
};

/// The outcomes of a definition's launches among some launch traces.
pub const LaunchCount = struct {
    published: usize = 0,
    failed: usize = 0,
};

pub fn countLaunches(traces: []const LaunchTrace, definition: config.DefinitionIndex) LaunchCount {
    var count: LaunchCount = .{};
    for (traces) |trace| {
        if (trace.definition != definition) continue;
        if (trace.failure == null) {
            count.published += 1;
        } else {
            count.failed += 1;
        }
    }
    return count;
}

fn runServerThread(runtime_server: *server_main.Server) void {
    runtime_server.run() catch |err|
        std.log.err("local server harness thread failed: {s}", .{@errorName(err)});
}

fn stopServerThread(runtime_server: *server_main.Server, thread: std.Thread) void {
    runtime_server.requestStop();
    const address = std.net.Address.parseIp4("127.0.0.1", runtime_server.port()) catch {
        thread.join();
        return;
    };
    const wake = std.net.tcpConnectToAddress(address) catch null;
    if (wake) |stream|
        stream.close();
    thread.join();
}

/// The local cgroup root exported under its test and production names for
/// one harness, with the previous values restored afterwards. Nothing the
/// harness starts reads either name: the server takes `Harness`'s
/// `WorkerCgroupRoot` directly, the zygote gets only the environment
/// `spawnZygote` builds (`zygote/host_client.zig`), and the gateway inherits
/// only `inherited_environment` (`server/gateway/process.zig`).
/// FIXME: the exports therefore have no effect; only the skip check in
/// `init` does.
const CgroupEnvironment = struct {
    /// `COLLO_TEST_WORKER_CGROUP_ROOT`, which the zygote test support reads
    /// first (`cgroupPlacement`).
    worker_cgroup_root: ?ScopedEnv,
    /// `COLLO_WORKER_CGROUP_ROOT`, which `collo serve` reads
    /// (`worker_cgroup_root_env` in `server/boot/root.zig`) and
    /// `cgroupPlacement` falls back to.
    server_cgroup_root: ?ScopedEnv,

    /// Skips the test when the local cgroup root is not usable.
    fn init(allocator: std.mem.Allocator) !CgroupEnvironment {
        if (!localCgroupRootUsable(allocator))
            return error.SkipZigTest;
        var worker_cgroup_root = try ScopedEnv.setRuntime(
            allocator,
            "COLLO_TEST_WORKER_CGROUP_ROOT",
            local_cgroup_root,
        );
        errdefer worker_cgroup_root.deinit(allocator);
        const server_cgroup_root = try ScopedEnv.setRuntime(
            allocator,
            "COLLO_WORKER_CGROUP_ROOT",
            local_cgroup_root,
        );
        return .{
            .worker_cgroup_root = worker_cgroup_root,
            .server_cgroup_root = server_cgroup_root,
        };
    }

    fn deinit(self: *CgroupEnvironment, allocator: std.mem.Allocator) void {
        if (self.server_cgroup_root) |*server_cgroup_root|
            server_cgroup_root.deinit(allocator);
        if (self.worker_cgroup_root) |*worker_cgroup_root|
            worker_cgroup_root.deinit(allocator);
        self.* = undefined;
    }
};

const ScopedEnv = struct {
    name: [:0]const u8,
    owned_name: ?[:0]u8 = null,
    previous: ?[:0]u8,

    fn setRuntime(
        allocator: std.mem.Allocator,
        name_raw: []const u8,
        value_raw: []const u8,
    ) !ScopedEnv {
        const name = try allocator.dupeZ(u8, name_raw);
        errdefer allocator.free(name);
        const value = try allocator.dupeZ(u8, value_raw);
        defer allocator.free(value);
        const previous = if (std.posix.getenv(name)) |raw|
            try allocator.dupeZ(u8, raw)
        else
            null;
        errdefer if (previous) |owned| allocator.free(owned);

        if (setenv(name.ptr, value.ptr, 1) != 0)
            return error.SetEnvironmentFailed;

        return .{
            .name = name,
            .owned_name = name,
            .previous = previous,
        };
    }

    fn deinit(self: *ScopedEnv, allocator: std.mem.Allocator) void {
        if (self.previous) |previous| {
            _ = setenv(self.name.ptr, previous.ptr, 1);
            allocator.free(previous);
        } else {
            _ = unsetenv(self.name.ptr);
        }
        if (self.owned_name) |owned_name|
            allocator.free(owned_name);
        self.* = undefined;
    }
};

/// Whether the delegated directory exists with its cgroup files and this
/// process sits in its subtree, as `wsl-config run` places it: in a runner
/// cgroup below it (`collo-dev/runner` by default), which leaves the
/// directory itself process-free.
fn localCgroupRootUsable(allocator: std.mem.Allocator) bool {
    std.fs.accessAbsolute(local_cgroup_root ++ "/cgroup.procs", .{}) catch return false;
    std.fs.accessAbsolute(local_cgroup_root ++ "/cgroup.subtree_control", .{}) catch return false;
    var file = std.fs.openFileAbsolute("/proc/self/cgroup", .{}) catch return false;
    defer file.close();
    const contents = file.readToEndAlloc(allocator, 4096) catch return false;
    defer allocator.free(contents);
    return std.mem.containsAtLeast(u8, contents, 1, ":/collo-dev");
}

pub fn waitForCompletedRequests(runtime_server: *server_main.Server, minimum: u64) !void {
    for (0..200) |_| {
        if (runtime_server.countersSnapshot().completed_requests >= minimum)
            return;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    return error.ServerCompletedRequestsNotObserved;
}

fn nulTerminatedPath(bytes: []const u8) []const u8 {
    return bytes[0..(std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len)];
}

pub fn dumpZygoteTrace(spawned: *const zygote_support.zygote.host_client.SpawnedZygote) void {
    var trace = zygote_support.drainTrace(spawned, std.testing.allocator) catch |err| {
        std.debug.print("zygote trace unavailable: {s}\n", .{@errorName(err)});
        return;
    };
    defer trace.deinit();

    std.debug.print("zygote trace:\n", .{});
    for (trace.messages) |message| {
        std.debug.print("  {s}\n", .{message});
    }
}

fn printShimError(action: []const u8) void {
    std.debug.print("{s} failed: {s}\n", .{ action, std.mem.span(tls_shim.collo_test_tls_last_error()) });
}

pub const H2GetReply = struct {
    body: []const u8,
    header_block: []const u8,
};

/// One h2 GET through the ingress on a fresh TLS connection. Returns the
/// response body and the raw HPACK block of the response HEADERS frame, both
/// slices of the caller's buffers.
pub fn h2Get(
    harness: *Harness,
    path: []const u8,
    body_buf: []u8,
    header_block_buf: []u8,
) !H2GetReply {
    const path_z = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(path_z);
    var body_len: u64 = 0;
    var header_block_len: u64 = 0;
    if (tls_shim.collo_test_h2_server_get(
        harness.port(),
        &harness.tls_material,
        path_z.ptr,
        body_buf.ptr,
        body_buf.len,
        &body_len,
        header_block_buf.ptr,
        header_block_buf.len,
        &header_block_len,
    ) != 0) {
        std.debug.print("HTTP/2 GET helper failed for {s}: {s}\n", .{
            path,
            std.mem.span(tls_shim.collo_test_tls_last_error()),
        });
        return error.H2ServerGetFailed;
    }
    // The shim counts body bytes past the buffer instead of failing; these
    // tests compare exact bodies, so a cut sample is an error.
    if (body_len > body_buf.len)
        return error.H2ResponseBodyTruncated;
    return .{
        .body = body_buf[0..@intCast(body_len)],
        .header_block = header_block_buf[0..@intCast(header_block_len)],
    };
}

/// Decodes a response header block with the production HPACK decoder. Every
/// client of the shim sets the server's header table size to 0, so the
/// server's encoder keeps no dynamic table and any block decodes with a fresh
/// decoder.
pub fn decodeResponseHeaders(block: []const u8) !hpack.DecodedBlock {
    var decoder = try hpack.Decoder.init();
    defer decoder.deinit();
    return decoder.decodeBlock(std.testing.allocator, block, 64, 16 * 1024);
}

pub fn headerValue(decoded: *const hpack.DecodedBlock, name: []const u8) ?[]const u8 {
    for (decoded.headers) |header| {
        if (std.mem.eql(u8, header.name, name))
            return header.value;
    }
    return null;
}

pub fn responseStatus(decoded: *const hpack.DecodedBlock) !u16 {
    const value = headerValue(decoded, ":status") orelse return error.MissingStatusPseudoHeader;
    return std.fmt.parseUnsigned(u16, value, 10);
}

/// A client connection a test holds across requests, opening one stream after
/// another (`collo_test_h2_client_*` in the TLS test shim). Two of them stay
/// open at once, and one carries a steady load or a request body under the
/// server's flow control. One thread at a time uses a client.
pub const Client = struct {
    handle: *tls_shim.TestH2Client,
    next_stream_id: u32 = 1,

    /// Opens a connection to the harness's server, on whichever lane the
    /// kernel picks.
    pub fn open(harness: *const Harness) !Client {
        const server_peer = harness.peer();
        var handle: ?*tls_shim.TestH2Client = null;
        if (tls_shim.collo_test_h2_client_open(&server_peer, &handle) != 0) {
            printShimError("open an HTTP/2 client connection");
            return error.H2ClientOpenFailed;
        }
        return .{ .handle = handle.? };
    }

    pub fn close(self: *Client) void {
        tls_shim.collo_test_h2_client_close(self.handle);
        self.* = undefined;
    }

    /// Sends a bodiless GET of `path` on the next stream and returns that
    /// stream.
    pub fn sendGet(self: *Client, path: []const u8) !u32 {
        return self.sendRequest("GET", path, -1, true);
    }

    /// Sends the HEADERS of a POST of `path` announcing `content_length` body
    /// bytes on the next stream and returns that stream; `sendBody` sends the
    /// body, and an empty one ends with the HEADERS.
    pub fn sendPost(self: *Client, path: []const u8, content_length: u64) !u32 {
        return self.sendRequest("POST", path, @intCast(content_length), content_length == 0);
    }

    fn sendRequest(self: *Client, method: [:0]const u8, path: []const u8, content_length: i64, end_stream: bool) !u32 {
        var path_buffer: [512]u8 = undefined;
        const path_z = try std.fmt.bufPrintZ(&path_buffer, "{s}", .{path});
        const stream_id = self.next_stream_id;
        if (tls_shim.collo_test_h2_client_send_request(
            self.handle,
            stream_id,
            method.ptr,
            path_z.ptr,
            content_length,
            @intFromBool(end_stream),
        ) != 0) {
            printShimError("send an HTTP/2 request");
            return error.H2ClientSendFailed;
        }
        self.next_stream_id += 2;
        return stream_id;
    }

    /// Sends `bytes` body bytes on `stream_id` in DATA frames of at most
    /// `frame_bytes`, ending the stream after the last one when `end_stream`,
    /// and returns the bytes sent: fewer than `bytes` only when the stream's
    /// response ended first.
    pub fn sendBody(self: *Client, stream_id: u32, bytes: u64, frame_bytes: u32, end_stream: bool) !u64 {
        var sent: u64 = 0;
        if (tls_shim.collo_test_h2_client_send_body(
            self.handle,
            stream_id,
            bytes,
            frame_bytes,
            @intFromBool(end_stream),
            &sent,
        ) != 0) {
            printShimError("send an HTTP/2 request body");
            return error.H2ClientSendFailed;
        }
        return sent;
    }

    /// Waits for the response of `stream_id`.
    pub fn readResponse(self: *Client, stream_id: u32) !Response {
        var response: Response = .{ .raw = undefined, .status = 0 };
        if (tls_shim.collo_test_h2_client_read_response(self.handle, stream_id, &response.raw) != 0) {
            printShimError("read an HTTP/2 response");
            return error.H2ClientReadFailed;
        }
        if (response.raw.header_block_len != 0) {
            const block_len: usize = @intCast(response.raw.header_block_len);
            var headers = try decodeResponseHeaders(response.raw.header_block[0..block_len]);
            defer headers.deinit(std.testing.allocator);
            response.status = try responseStatus(&headers);
        }
        return response;
    }

    /// One GET of `path` and its response.
    pub fn get(self: *Client, path: []const u8) !Response {
        return self.readResponse(try self.sendGet(path));
    }
};

/// How one request of a held connection ended.
pub const Response = struct {
    raw: tls_shim.H2Response,
    /// The response's `:status`, 0 when the stream was reset before any
    /// HEADERS arrived.
    status: u16,

    /// The body's first bytes, all of it unless `raw.body_len` says more came.
    pub fn body(self: *const Response) []const u8 {
        return self.raw.body[0..@intCast(@min(self.raw.body_len, self.raw.body.len))];
    }
};

/// The token `api/token.js` and `api/upload.js` draw once per worker process:
/// two responses carry the same token exactly when one worker answered both.
pub const Token = struct {
    bytes: [bytes_max]u8,
    len: usize,

    const bytes_max = 64;

    pub fn eql(a: Token, b: Token) bool {
        return std.mem.eql(u8, a.bytes[0..a.len], b.bytes[0..b.len]);
    }
};

/// What `api/upload.js` answers: the length of the body it read, and its
/// worker's token.
pub const UploadReply = struct {
    length: u64,
    token: Token,
};

/// The token of a 200 response of a route that reports one; any other status
/// fails the test with the response's body printed.
pub fn tokenOf(response: *const Response) !Token {
    const parsed = try parseReply(struct { token: []const u8 }, response);
    defer parsed.deinit();
    return tokenFrom(parsed.value.token);
}

/// The reply of a 200 response of `/upload`.
pub fn uploadReplyOf(response: *const Response) !UploadReply {
    const parsed = try parseReply(struct { length: u64, token: []const u8 }, response);
    defer parsed.deinit();
    return .{ .length = parsed.value.length, .token = try tokenFrom(parsed.value.token) };
}

/// The JSON reply of a 200 response, parsed into `Reply`, which names only
/// the fields a test reads; any other status fails the test with the
/// response's body printed.
pub fn parseReply(comptime Reply: type, response: *const Response) !std.json.Parsed(Reply) {
    if (response.status != 200) {
        std.debug.print("expected 200, got status {d} (reset {d}, code {d}): {s}\n", .{
            response.status,
            response.raw.reset,
            response.raw.reset_code,
            response.body(),
        });
        return error.UnexpectedResponseStatus;
    }
    return std.json.parseFromSlice(Reply, std.testing.allocator, response.body(), .{ .ignore_unknown_fields = true });
}

fn tokenFrom(value: []const u8) !Token {
    if (value.len == 0 or value.len > Token.bytes_max)
        return error.InvalidWorkerToken;
    var token: Token = .{ .bytes = undefined, .len = value.len };
    @memcpy(token.bytes[0..value.len], value);
    return token;
}

/// Tries before `openClientOnLane` gives up on a connection reaching its
/// lane.
const lane_placement_attempts_max: usize = 16;

/// Opens a client connection that the server accepted on lane `lane_index`.
/// The calling thread connects pinned to that lane's CPU, and each lane's
/// listener carries its CPU as SO_INCOMING_CPU, which the kernel's reuseport
/// selection, or the lane selector when it is attached, honors for a
/// connection received on that CPU (`server/net/listener.zig`). The lane's
/// accept counter confirms where the connection went; one that went to
/// another lane is closed and tried again.
pub fn openClientOnLane(harness: *Harness, lane_index: usize) !Client {
    const lane_cpu_ids = harness.runtime_server.lane_cpu_ids;
    if (lane_index >= lane_cpu_ids.len)
        return error.NoSuchLane;
    const saved_affinity = try std.posix.sched_getaffinity(0);
    for (0..lane_placement_attempts_max) |_| {
        const accepted_before = laneAcceptedConnections(harness, lane_index);
        try server_main.lane_plan.pinCurrentThreadToCpu(lane_cpu_ids[lane_index]);
        const opened = Client.open(harness);
        const restored = std.os.linux.sched_setaffinity(0, &saved_affinity);
        var client = try opened;
        restored catch |err| {
            client.close();
            return err;
        };
        if (waitForLaneAccept(harness, lane_index, accepted_before))
            return client;
        client.close();
    }
    return error.ConnectionNotPlacedOnLane;
}

/// Whether lane `lane_index` accepted a connection since its count was
/// `accepted_before`. The lane counts a connection when it accepts it, before
/// the TLS handshake a client's open waits for, so the count is final once
/// the read below sees it; the poll covers only the snapshot's lag.
fn waitForLaneAccept(harness: *Harness, lane_index: usize, accepted_before: u64) bool {
    for (0..50) |_| {
        if (laneAcceptedConnections(harness, lane_index) > accepted_before)
            return true;
        std.Thread.sleep(2 * std.time.ns_per_ms);
    }
    return false;
}

/// Connections lane `lane_index` of the running service accepted, from that
/// lane's counters (`Server.active_service`, `Service.lanes`); 0 when no
/// service runs.
pub fn laneAcceptedConnections(harness: *Harness, lane_index: usize) u64 {
    const runtime_server = &harness.runtime_server;
    runtime_server.active_service_mutex.lock();
    defer runtime_server.active_service_mutex.unlock();
    const service = runtime_server.active_service orelse return 0;
    if (lane_index >= service.lanes.len)
        return 0;
    return service.lanes[lane_index].countersSnapshot().accepted_connections;
}

/// A live worker of one pool, as the supervisor records it.
pub const LiveWorker = struct {
    record: *WorkerRecord,
    key: WorkerKey,
    slots_held: u8,
};

/// The one live worker of `definition`'s pool. Fails with
/// `error.NoLiveWorker` when the pool has none and with
/// `error.SeveralLiveWorkers` when it has more. The pool says which of the
/// definition's records hold a worker (`WorkerPool.inspect`); a record it
/// calls live stays as it is while the test reads it.
pub fn soleLiveWorker(harness: *Harness, definition: config.DefinitionIndex) !LiveWorker {
    const supervisor = &harness.runtime_server.supervisor;
    const worker_pool = supervisor.poolFor(definition);
    var found: ?LiveWorker = null;
    for (supervisor.recordsOf(definition)) |*record| {
        const view = worker_pool.inspect(record) orelse continue;
        if (view.state != .live) continue;
        if (found != null) return error.SeveralLiveWorkers;
        found = .{ .record = record, .key = record.key(), .slots_held = view.slots_held };
    }
    return found orelse error.NoLiveWorker;
}

/// Waits until the one live worker of `definition` holds `slots` request
/// slots, which it does once the requests a test sent were admitted to it.
pub fn waitForSlotsHeld(harness: *Harness, definition: config.DefinitionIndex, slots: u8) !LiveWorker {
    for (0..500) |_| {
        if (soleLiveWorker(harness, definition)) |worker| {
            if (worker.slots_held == slots) return worker;
        } else |err| switch (err) {
            error.NoLiveWorker => {},
            else => return err,
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    return error.WorkerSlotsNotHeld;
}

/// Ends `worker`'s process with SIGKILL through the server's own pidfd of
/// it: the server runs in this process, and the pidfd cannot name a reused
/// pid. The kernel counts no `oom_kill` for a signal sent from outside, so
/// the server classifies the death as `crash` (`classifyWorkerDeath` in
/// `server/supervisor/usage_drain.zig`), where a kernel OOM kill reads as
/// `memory`.
pub fn killWorker(worker: LiveWorker) !void {
    try process.pidFdSendSignal(worker.record.handle.pidfd, std.posix.SIG.KILL);
}

/// The egress gateway process the server runs, held through a pidfd of the
/// test's own, so no signal can reach a process that took its pid later.
pub const GatewayProcess = struct {
    pid: u32,
    pidfd: std.posix.fd_t,

    pub fn deinit(self: *GatewayProcess) void {
        std.posix.close(self.pidfd);
        self.* = undefined;
    }

    /// Ends the gateway with SIGKILL, as a crash or the kernel's OOM killer
    /// ends it, and returns once it has exited, so what the test sees next
    /// follows its death.
    pub fn kill(self: *const GatewayProcess) !void {
        try process.pidFdSendSignal(self.pidfd, std.posix.SIG.KILL);
        if (!try process.waitForPidFdExit(self.pidfd, gateway_exit_wait_ms))
            return error.GatewayDidNotExit;
    }
};

/// Bound on the wait for a killed gateway to exit. SIGKILL leaves the process
/// nothing to run, so only an overloaded host comes near it.
const gateway_exit_wait_ms: i32 = 5_000;
/// Bytes of `/proc/<pid>/status` read for its `PPid` line, which comes within
/// the first few lines.
const proc_status_bytes_max: usize = 4096;
/// Bytes of `/proc/<pid>/cmdline` read for its first argument, far longer
/// than the gateway's process name.
const proc_cmdline_bytes_max: usize = 256;

/// The gateway process the server runs now. The server spawns each gateway
/// from this process, as a direct child whose first argument is the
/// gateway's process name (`server/gateway/process.zig`), so the gateway is
/// the one child of this process with that name. A child that exited and is
/// not reaped yet has an empty command line and does not count. Fails with
/// `error.GatewayProcessNotFound` when there is no such child and with
/// `error.SeveralGatewayProcesses` when there is more than one.
pub fn currentGatewayProcess() !GatewayProcess {
    const self_pid: u32 = @intCast(std.os.linux.getpid());
    var found: ?u32 = null;
    var proc_dir = try std.fs.openDirAbsolute("/proc", .{ .iterate = true });
    defer proc_dir.close();
    var entries = proc_dir.iterate();
    while (try entries.next()) |entry| {
        const pid = std.fmt.parseUnsigned(u32, entry.name, 10) catch continue;
        if (!isGatewayChild(pid, self_pid))
            continue;
        if (found != null)
            return error.SeveralGatewayProcesses;
        found = pid;
    }
    const pid = found orelse return error.GatewayProcessNotFound;
    const pidfd = try process.openPidFd(pid);
    errdefer std.posix.close(pidfd);
    // The scan and the pidfd read the pid at two moments; checking again
    // once the pidfd holds a process rules out a pid that another process
    // took in between.
    if (!isGatewayChild(pid, self_pid))
        return error.GatewayProcessNotFound;
    return .{ .pid = pid, .pidfd = pidfd };
}

/// Whether `pid` is a child of `parent_pid` whose first argument is the
/// gateway's process name. A process that is gone reads as neither.
fn isGatewayChild(pid: u32, parent_pid: u32) bool {
    const parent = parentPid(pid) orelse return false;
    if (parent != parent_pid)
        return false;
    return firstArgumentIs(pid, gateway_launch.process_name);
}

/// The `PPid` line of `/proc/<pid>/status`, or null when the process is gone.
fn parentPid(pid: u32) ?u32 {
    var path_buffer: [32]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "/proc/{d}/status", .{pid}) catch return null;
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    var buffer: [proc_status_bytes_max]u8 = undefined;
    const len = file.readAll(&buffer) catch return null;
    var lines = std.mem.splitScalar(u8, buffer[0..len], '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "PPid:"))
            continue;
        const value = std.mem.trim(u8, line["PPid:".len..], " \t");
        return std.fmt.parseUnsigned(u32, value, 10) catch null;
    }
    return null;
}

/// Whether the base name of the first argument in `/proc/<pid>/cmdline` is
/// `name`, the rule the binary's `main` dispatches its processes by.
fn firstArgumentIs(pid: u32, name: []const u8) bool {
    var path_buffer: [32]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "/proc/{d}/cmdline", .{pid}) catch return false;
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();
    var buffer: [proc_cmdline_bytes_max]u8 = undefined;
    const len = file.readAll(&buffer) catch return false;
    const first_end = std.mem.indexOfScalar(u8, buffer[0..len], 0) orelse len;
    if (first_end == 0)
        return false;
    return std.mem.eql(u8, std.fs.path.basename(buffer[0..first_end]), name);
}

/// The fields of a `usage.jsonl` record the suites check.
pub const UsageLine = struct {
    worker: []const u8,
    worker_id: u64,
    worker_generation: u64,
    origin: []const u8,
    request_id: u64,
    error_code: []const u8,
    wall_time_ns: u64,
};

/// The fields of an `access.jsonl` record the suites check.
pub const AccessLine = struct {
    request_id: u64,
    worker_id: u64,
    worker_generation: u64,
    status: u16,
    client_ip: []const u8,
};

/// The fields of an `access.jsonl` record of a request the server answered
/// itself.
pub const LocalAccessLine = struct {
    status: u16,
    answered_by: []const u8,
    worker: []const u8,
    route: []const u8,
    worker_id: u64,
};

/// Records parsed from one analytics file, owned by `arena`.
pub fn RecordLines(comptime Line: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        items: []const Line,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
        }
    };
}

/// Polls `file_name` in the harness's analytics directory until it holds at
/// least `minimum` complete lines, and parses each into `Line`, ignoring the
/// fields `Line` does not name. The metrics thread writes the files every
/// tick, so a line without its newline yet is left for the next poll.
pub fn waitForRecordLines(
    comptime Line: type,
    harness: *Harness,
    file_name: []const u8,
    minimum: usize,
) !RecordLines(Line) {
    var dir = try std.fs.openDirAbsolute(harness.analytics_root, .{});
    defer dir.close();
    for (0..500) |_| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        var arena_owned = true;
        defer if (arena_owned) arena.deinit();
        const arena_allocator = arena.allocator();
        const contents = try dir.readFileAlloc(arena_allocator, file_name, 16 * 1024 * 1024);
        const complete_len = if (std.mem.lastIndexOfScalar(u8, contents, '\n')) |last| last + 1 else 0;
        var items: std.array_list.Aligned(Line, null) = .empty;
        var lines = std.mem.splitScalar(u8, contents[0..complete_len], '\n');
        while (lines.next()) |line| {
            if (line.len == 0)
                continue;
            try items.append(arena_allocator, try std.json.parseFromSliceLeaky(
                Line,
                arena_allocator,
                line,
                .{ .ignore_unknown_fields = true },
            ));
        }
        if (items.items.len >= minimum) {
            arena_owned = false;
            return .{ .arena = arena, .items = items.items };
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    return error.AnalyticsRecordsNotObserved;
}
