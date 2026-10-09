//! Covers how a handler reads its request body in the worker runtime: the
//! text, JSON, form and binary readers over ingress bytes and body chunk
//! descriptors, a pending read that meets the request deadline, single
//! consumption, and a `Request` saved past its request, which keeps its
//! metadata but never reads a later request's body. Runs in `worker-test`,
//! on a real VM with an injected clock.

const std = @import("std");
const support = @import("bindings_support");
const ipc = @import("collo_ipc");
const worker = @import("collo_worker");
const worker_testing = @import("collo_worker_test_support");
const rt = @import("collo_test_harness");

const fakeNow = rt.fakeNow;
const RequestParts = rt.RequestParts;
const initDispatchWork = rt.initDispatchWork;
const socketPairType = rt.socketPairType;
const runRouteAndReadBodyWithRequest = rt.runRouteAndReadBodyWithRequest;
const runRouteAndReadBodyWithRequestCaptures = rt.runRouteAndReadBodyWithRequestCaptures;
const executeNextReady = rt.executeNextReady;
const executeUntilRequestDone = rt.executeUntilRequestDone;

test "request text reads ingress body bytes" {
    var vm = try support.createVm();
    defer vm.deinit();

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

    const response = try runRouteAndReadBodyWithRequest(&runtime, control_pair[1],
        \\export default async function handle(req) {
        \\    const before = req.bodyUsed;
        \\    const body = await req.text();
        \\    return Response.json({ before, after: req.bodyUsed, body });
        \\}
    , 26, "/lazy-text.js", .{
        .method = "POST",
        .path = "/lazy-text",
        .headers = &[_]ipc.RequestHeader{
            .{ .name = "host", .value = "demo.test" },
            .{ .name = "content-length", .value = "5" },
        },
        .body = "hello",
    });
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"before\":false"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"after\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"body\":\"hello\""));
}

test "pending ingress body read observes request deadline without body bytes" {
    var vm = try support.createVm();
    defer vm.deinit();

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

    const route_specifier = try rt.routeSpecifier(std.testing.allocator, "/body-deadline.js");
    defer std.testing.allocator.free(route_specifier);
    try rt.registerRoute(&runtime, route_specifier,
        \\export default async function handle(req) {
        \\    await req.text();
        \\    return "unexpected";
        \\}
    );

    const request = RequestParts{
        .method = "POST",
        .path = "/body-deadline",
        .headers = &[_]ipc.RequestHeader{
            .{ .name = "host", .value = "demo.test" },
            .{ .name = "content-length", .value = "5" },
        },
        .body_framing = .ingress_channel,
        .body_end_stream = false,
    };
    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 28,
        .route_entry_specifier = route_specifier,
        .deadline_monotonic_ns = 5,
        .request = request,
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 1, request);

    const request_item = runtime.scheduler.ready_queue.pop() orelse return error.MissingRequestWork;
    try worker_testing.executeWorkItem(&runtime, request_item);
    try std.testing.expect(runtime.requests.active.contains(28));

    // No body chunk ever arrives, so the read is still pending when the fake
    // clock reaches the deadline.
    now_mono_ns = 5;
    try runtime.collectDueRequestDeadlines();
    try executeNextReady(&runtime);
    try executeUntilRequestDone(&runtime, 28);

    var response = try rt.readIngressResponse(&runtime, control_pair[1], 28);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 504), response.status);
    try std.testing.expectEqual(ipc.RequestDoneStatus.deadline_timeout, response.doneStatus());
}

test "request text waits for body chunk descriptors" {
    var vm = try support.createVm();
    defer vm.deinit();

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

    const route_specifier = try rt.routeSpecifier(std.testing.allocator, "/lazy-body.js");
    defer std.testing.allocator.free(route_specifier);
    try rt.registerRoute(&runtime, route_specifier,
        \\export default async function handle(req) {
        \\    return Response.json({ body: await req.text() });
        \\}
    );

    const request = RequestParts{
        .method = "POST",
        .path = "/lazy-body",
        .headers = &[_]ipc.RequestHeader{
            .{ .name = "host", .value = "demo.test" },
            .{ .name = "content-length", .value = "11" },
        },
        .body_framing = .ingress_channel,
        .body_end_stream = false,
    };
    var dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = 82,
        .route_entry_specifier = route_specifier,
        .request = request,
    });
    defer dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &dispatch, 17, request);
    try executeNextReady(&runtime);
    try std.testing.expect(runtime.requests.active.contains(82));

    const identity = ipc.ingress_channel.RequestIdentity{
        .request_id = dispatch.request_id,
        .request_generation = dispatch.request_generation,
        .request_lane_id = dispatch.request_lane_id,
        .request_slot = dispatch.request_slot,
    };
    var hello_payload = "hello ".*;
    var hello_descriptor = ipc.ingress_channel.Descriptor.requestBodyChunk(identity, 17, 0, 6, false);
    hello_descriptor.flag_bits |= ipc.ingress_channel.flags.inline_bytes;
    try runtime.enqueueIngressDescriptor(.{
        .allocator = std.testing.allocator,
        .descriptor = hello_descriptor,
        .payload = hello_payload[0..],
        .payload_owned = false,
    });

    var world_payload = "world".*;
    var world_descriptor = ipc.ingress_channel.Descriptor.requestBodyChunk(identity, 17, 6, 5, true);
    world_descriptor.flag_bits |= ipc.ingress_channel.flags.inline_bytes;
    try runtime.enqueueIngressDescriptor(.{
        .allocator = std.testing.allocator,
        .descriptor = world_descriptor,
        .payload = world_payload[0..],
        .payload_owned = false,
    });
    try executeUntilRequestDone(&runtime, 82);

    var response = try rt.readIngressResponse(&runtime, control_pair[1], 82);
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expect(std.mem.containsAtLeast(u8, response.body, 1, "\"body\":\"hello world\""));
}

test "request json uses lazy text and second consumption rejects" {
    var vm = try support.createVm();
    defer vm.deinit();

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

    const response = try runRouteAndReadBodyWithRequest(&runtime, control_pair[1],
        \\export default async function handle(req) {
        \\    const parsed = await req.json();
        \\    let secondRejected = false;
        \\    try { await req.text(); } catch (err) { secondRejected = err instanceof TypeError; }
        \\    return Response.json({ value: parsed.value, secondRejected, bodyUsed: req.bodyUsed });
        \\}
    , 29, "/lazy-json.js", .{
        .method = "POST",
        .path = "/json",
        .headers = &[_]ipc.RequestHeader{
            .{ .name = "host", .value = "demo.test" },
            .{ .name = "content-length", .value = "11" },
        },
        .body = "{\"value\":7}",
    });
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"value\":7"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"secondRejected\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"bodyUsed\":true"));
}

test "request formData parses lazy urlencoded body inside request turn" {
    var vm = try support.createVm();
    defer vm.deinit();

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

    const response = try runRouteAndReadBodyWithRequest(&runtime, control_pair[1],
        \\export default async function handle(req) {
        \\    const form = await req.formData();
        \\    return Response.json({ value: form.get("value"), encoded: form.get("encoded"), bodyUsed: req.bodyUsed });
        \\}
    , 309, "/lazy-form-data.js", .{
        .method = "POST",
        .path = "/form",
        .headers = &[_]ipc.RequestHeader{
            .{ .name = "host", .value = "demo.test" },
            .{ .name = "content-length", .value = "34" },
            .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
        },
        .body = "value=hello+world&encoded=hello%21",
    });
    defer std.testing.allocator.free(response);
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"value\":\"hello world\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"encoded\":\"hello!\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, response, 1, "\"bodyUsed\":true"));
}

test "request binary body methods preserve raw bytes" {
    var vm = try support.createVm();
    defer vm.deinit();

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

    const request = RequestParts{
        .method = "POST",
        .path = "/binary",
        .headers = &[_]ipc.RequestHeader{
            .{ .name = "host", .value = "demo.test" },
            .{ .name = "content-length", .value = "3" },
            .{ .name = "content-type", .value = "application/octet-stream" },
        },
        .body = "\x00\xffA",
    };

    const bytes_response = try runRouteAndReadBodyWithRequest(&runtime, control_pair[1],
        \\export default async function handle(req) {
        \\    return Response.json({ bytes: Array.from(await req.bytes()), bodyUsed: req.bodyUsed });
        \\}
    , 306, "/binary-bytes.js", request);
    defer std.testing.allocator.free(bytes_response);
    try std.testing.expect(std.mem.containsAtLeast(u8, bytes_response, 1, "\"bytes\":[0,255,65]"));

    const array_buffer_response = try runRouteAndReadBodyWithRequest(&runtime, control_pair[1],
        \\export default async function handle(req) {
        \\    return Response.json({ bytes: Array.from(new Uint8Array(await req.arrayBuffer())) });
        \\}
    , 307, "/binary-array-buffer.js", request);
    defer std.testing.allocator.free(array_buffer_response);
    try std.testing.expect(std.mem.containsAtLeast(u8, array_buffer_response, 1, "\"bytes\":[0,255,65]"));

    const blob_response = try runRouteAndReadBodyWithRequest(&runtime, control_pair[1],
        \\export default async function handle(req) {
        \\    const blob = await req.blob();
        \\    return Response.json({ bytes: Array.from(await blob.bytes()), type: blob.type });
        \\}
    , 308, "/binary-blob.js", request);
    defer std.testing.allocator.free(blob_response);
    try std.testing.expect(std.mem.containsAtLeast(u8, blob_response, 1, "\"bytes\":[0,255,65]"));
    try std.testing.expect(std.mem.containsAtLeast(u8, blob_response, 1, "\"type\":\"application/octet-stream\""));
}

test "saved Request object cannot consume a later request body" {
    var vm = try support.createVm();
    defer vm.deinit();

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

    const source =
        \\let savedText;
        \\let savedJson;
        \\export default async function handle(req) {
        \\    if (req.path === "/save-text") { savedText = req; return "saved text"; }
        \\    if (req.path === "/save-json") { savedJson = req; return "saved json"; }
        \\    let textPromiseReturned = false, textRejected = false, textSyncThrow = false;
        \\    try {
        \\        const p = savedText.text();
        \\        textPromiseReturned = p instanceof Promise;
        \\        await p.catch((err) => { textRejected = err instanceof TypeError; });
        \\    } catch (err) { textSyncThrow = true; }
        \\    let jsonPromiseReturned = false, jsonRejected = false, jsonSyncThrow = false;
        \\    try {
        \\        const p = savedJson.json();
        \\        jsonPromiseReturned = p instanceof Promise;
        \\        await p.catch((err) => { jsonRejected = err instanceof TypeError; });
        \\    } catch (err) { jsonSyncThrow = true; }
        \\    const currentBody = await req.text();
        \\    return Response.json({ textPromiseReturned, textRejected, textSyncThrow, jsonPromiseReturned, jsonRejected, jsonSyncThrow, currentBody });
        \\}
    ;
    const specifier = "/saved-request-body.js";

    const save_text_response = try runRouteAndReadBodyWithRequest(&runtime, control_pair[1], source, 31, specifier, .{
        .method = "POST",
        .path = "/save-text",
        .headers = &[_]ipc.RequestHeader{ .{ .name = "host", .value = "demo.test" }, .{ .name = "content-length", .value = "5" } },
        .body = "first",
    });
    defer std.testing.allocator.free(save_text_response);
    try std.testing.expect(std.mem.containsAtLeast(u8, save_text_response, 1, "saved text"));

    const save_json_response = try runRouteAndReadBodyWithRequest(&runtime, control_pair[1], source, 33, specifier, .{
        .method = "POST",
        .path = "/save-json",
        .headers = &[_]ipc.RequestHeader{ .{ .name = "host", .value = "demo.test" }, .{ .name = "content-length", .value = "7" } },
        .body = "{\"x\":1}",
    });
    defer std.testing.allocator.free(save_json_response);
    try std.testing.expect(std.mem.containsAtLeast(u8, save_json_response, 1, "saved json"));

    const use_response = try runRouteAndReadBodyWithRequest(&runtime, control_pair[1], source, 32, specifier, .{
        .method = "POST",
        .path = "/use-saved",
        .headers = &[_]ipc.RequestHeader{ .{ .name = "host", .value = "demo.test" }, .{ .name = "content-length", .value = "6" } },
        .body = "second",
    });
    defer std.testing.allocator.free(use_response);
    try std.testing.expect(std.mem.containsAtLeast(u8, use_response, 1, "\"textPromiseReturned\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, use_response, 1, "\"textRejected\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, use_response, 1, "\"textSyncThrow\":false"));
    try std.testing.expect(std.mem.containsAtLeast(u8, use_response, 1, "\"jsonPromiseReturned\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, use_response, 1, "\"jsonRejected\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, use_response, 1, "\"jsonSyncThrow\":false"));
    try std.testing.expect(std.mem.containsAtLeast(u8, use_response, 1, "\"currentBody\":\"second\""));
}

test "saved Request keeps lazy metadata after original request finishes" {
    var vm = try support.createVm();
    defer vm.deinit();

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

    const source =
        \\let saved;
        \\export default function handle(req) {
        \\    if (req.path === "/save/world") { saved = req; return "saved"; }
        \\    const firstHeaders = saved.headers;
        \\    firstHeaders.set("x-added", "yes");
        \\    return Response.json({
        \\        method: saved.method,
        \\        path: saved.path,
        \\        url: saved.url,
        \\        header: saved.headers.get("x-saved"),
        \\        added: saved.headers.get("x-added"),
        \\        headersCached: firstHeaders === saved.headers,
        \\        param: saved.params.name,
        \\        query: saved.query.get("q"),
        \\        current: req.path
        \\    });
        \\}
    ;
    const specifier = "/saved-request-lazy-metadata.js";
    const captures = [_]ipc.RouteCapture{.{ .name = "name", .value = "world" }};

    const save_response = try runRouteAndReadBodyWithRequestCaptures(&runtime, control_pair[1], source, 35, specifier, .{
        .method = "POST",
        .path = "/save/world",
        .raw_query = "q=1",
        .headers = &[_]ipc.RequestHeader{
            .{ .name = "host", .value = "demo.test" },
            .{ .name = "x-saved", .value = "ok" },
        },
    }, &captures);
    defer std.testing.allocator.free(save_response);
    try std.testing.expect(std.mem.containsAtLeast(u8, save_response, 1, "saved"));

    const use_response = try runRouteAndReadBodyWithRequest(&runtime, control_pair[1], source, 36, specifier, .{ .path = "/use-saved" });
    defer std.testing.allocator.free(use_response);
    try std.testing.expect(std.mem.containsAtLeast(u8, use_response, 1, "\"method\":\"POST\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, use_response, 1, "\"path\":\"/save/world\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, use_response, 1, "\"url\":\"https://demo.test/save/world?q=1\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, use_response, 1, "\"header\":\"ok\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, use_response, 1, "\"added\":\"yes\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, use_response, 1, "\"headersCached\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, use_response, 1, "\"param\":\"world\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, use_response, 1, "\"query\":\"1\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, use_response, 1, "\"current\":\"/use-saved\""));
}

test "saved Request rejects when numeric request id is reused without metrics" {
    var vm = try support.createVm();
    defer vm.deinit();

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

    const source =
        \\let saved;
        \\export default async function handle(req) {
        \\    if (req.path === "/save") { saved = req; return "saved"; }
        \\    let stalePromiseReturned = false, staleRejected = false, staleSyncThrow = false;
        \\    try {
        \\        const p = saved.text();
        \\        stalePromiseReturned = p instanceof Promise;
        \\        await p.catch((err) => { staleRejected = err instanceof TypeError; });
        \\    } catch (err) { staleSyncThrow = true; }
        \\    const currentBody = await req.text();
        \\    return Response.json({ stalePromiseReturned, staleRejected, staleSyncThrow, currentBody });
        \\}
    ;
    const specifier = "/saved-request-reused-id.js";
    const reused_request_id: u64 = 7001;

    const save_response = try runRouteAndReadBodyWithRequest(&runtime, control_pair[1], source, reused_request_id, specifier, .{
        .method = "POST",
        .path = "/save",
        .headers = &[_]ipc.RequestHeader{ .{ .name = "host", .value = "demo.test" }, .{ .name = "content-length", .value = "5" } },
        .body = "first",
    });
    defer std.testing.allocator.free(save_response);
    try std.testing.expect(std.mem.containsAtLeast(u8, save_response, 1, "saved"));

    // The id's second use arrives with a generation of its own, as every
    // dispatch carries the server's request generation; that is what makes
    // the saved Request stale.
    const use_request = RequestParts{
        .method = "POST",
        .path = "/use-saved",
        .headers = &[_]ipc.RequestHeader{ .{ .name = "host", .value = "demo.test" }, .{ .name = "content-length", .value = "6" } },
        .body = "second",
    };
    // The first run registered the route's pack.
    const route_specifier = try rt.routeSpecifier(std.testing.allocator, specifier);
    defer std.testing.allocator.free(route_specifier);
    var use_dispatch = try initDispatchWork(std.testing.allocator, .{
        .request_id = reused_request_id,
        .request_generation = 2,
        .route_entry_specifier = route_specifier,
        .request = use_request,
    });
    defer use_dispatch.deinit();
    try rt.enqueueIngressRoute(&runtime, &use_dispatch, 1, use_request);
    try executeNextReady(&runtime);
    try executeUntilRequestDone(&runtime, reused_request_id);
    const use_response = try rt.readIngressResponseBody(&runtime, control_pair[1], reused_request_id);
    defer std.testing.allocator.free(use_response);
    try std.testing.expect(std.mem.containsAtLeast(u8, use_response, 1, "\"stalePromiseReturned\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, use_response, 1, "\"staleRejected\":true"));
    try std.testing.expect(std.mem.containsAtLeast(u8, use_response, 1, "\"staleSyncThrow\":false"));
    try std.testing.expect(std.mem.containsAtLeast(u8, use_response, 1, "\"currentBody\":\"second\""));
}
