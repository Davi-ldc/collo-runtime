//! Tests of the gateway's fetch task: it owns copies of the request it was
//! given, a body it took as an `OwnedBody` goes back to the allocator that
//! came with it, at the end and at a redirect that drops it, a redirect that
//! keeps it leaves it where it is, `replaceRequest` keeps the previous
//! request when any allocation fails, and the meter totals add billed and
//! cost bytes per attempt. The failure the engine publishes on a task
//! (`engine/result.zig:publishFailure`) is tested here too: a network
//! denial names the origin of the task's current URL and what to change,
//! with the `network_denied` cause, and any other error stays
//! `fetch failed: <error name>`. Lane `egress-test`.

const std = @import("std");
const bindings = @import("collo_bindings");
const http = @import("collo_http");
const egress_client = @import("collo_egress_client");

const fetch_body = egress_client.fetch_body;
const task_model = egress_client.task;
const network = egress_client.network;
const publishFailure = egress_client.engine.result.publishFailure;

test "egress task owns request metadata without worker promise state" {
    const identity = bindings.FetchBodyIdentity{
        .request_id = 11,
        .request_generation = 12,
        .fetch_id = 13,
        .body_id = 14,
    };
    const body = try std.testing.allocator.create(fetch_body.Body);
    var body_owned = true;
    errdefer if (body_owned) {
        body.deinitAfterQueuedResourcesReleased(std.testing.allocator);
        std.testing.allocator.destroy(body);
    };
    body.* = fetch_body.Body.initOpen(std.testing.allocator, identity, 4096);

    const header_name = "accept";
    const header_value = "application/json";
    const header = bindings.NameValuePair{
        .name = .{ .ptr = header_name.ptr, .len = header_name.len },
        .value = .{ .ptr = header_value.ptr, .len = header_value.len },
    };
    var task = try task_model.Task.init(
        std.testing.allocator,
        identity.fetch_id,
        identity.request_id,
        "https://example.test/api",
        "GET",
        "",
        &.{header},
        0,
        identity,
        body,
    );
    body_owned = false;
    defer task.deinit();

    try std.testing.expectEqual(identity.fetch_id, task.id);
    try std.testing.expectEqual(identity.request_id, task.request_id);
    try std.testing.expectEqual(@as(usize, 1), task.headers.len);
    try std.testing.expectEqualStrings("accept", task.headers[0].name);
    try std.testing.expectEqualStrings("application/json", task.headers[0].value);
    try std.testing.expect(!task.isCanceled());

    task.markCanceled();
    try std.testing.expect(task.isCanceled());
}

test "egress task frees an owned body with the allocator that came with it" {
    // The task's allocator stands for a gateway shard's and the body's for the gateway's own:
    // each must see exactly its own frees.
    var task_counter = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var body_counter = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var task = try ownedBodyTask(&task_counter, &body_counter, "assembled upload body");

    try std.testing.expectEqualStrings("assembled upload body", task.body);
    task.deinit();
    try std.testing.expectEqual(body_counter.allocated_bytes, body_counter.freed_bytes);
    try std.testing.expectEqual(task_counter.allocated_bytes, task_counter.freed_bytes);
}

test "a redirect that keeps the body keeps the owned buffer and its allocator" {
    // The task's allocator stands for a gateway shard's budgeted one and the body's for the
    // gateway's upload budget: a 307 must charge the shard nothing for the body.
    var task_counter = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var body_counter = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var task = try ownedBodyTask(&task_counter, &body_counter, "assembled upload body");
    const body_bytes = task.body.ptr;

    const next_headers = [_]http.Header{.{ .name = "x-hop", .value = "2" }};
    try task.replaceRequest("https://example.test/next", "POST", .keep, &next_headers);
    try std.testing.expectEqual(body_bytes, task.body.ptr);
    try std.testing.expectEqualStrings("assembled upload body", task.body);
    try std.testing.expectEqual(body_counter.allocator().ptr, task.body_allocator.ptr);
    try std.testing.expectEqual(@as(usize, 0), body_counter.freed_bytes);

    task.deinit();
    try std.testing.expectEqual(body_counter.allocated_bytes, body_counter.freed_bytes);
    try std.testing.expectEqual(task_counter.allocated_bytes, task_counter.freed_bytes);
}

test "a redirect that drops the body returns an owned body to its allocator" {
    var task_counter = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var body_counter = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var task = try ownedBodyTask(&task_counter, &body_counter, "assembled upload body");
    defer task.deinit();

    // A 303 turns the POST into a GET without a body.
    try task.replaceRequest("https://example.test/next", "GET", .drop, &.{});
    try std.testing.expectEqual(@as(usize, 0), task.body.len);
    try std.testing.expectEqual(body_counter.allocated_bytes, body_counter.freed_bytes);
}

test "egress task replace request allocation failures preserve previous request" {
    for (0..8) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const allocator = failing.allocator();

        const identity = bindings.FetchBodyIdentity{
            .request_id = 21,
            .request_generation = 22,
            .fetch_id = 23 + fail_index,
            .body_id = 24 + fail_index,
        };
        const body = try allocator.create(fetch_body.Body);
        var body_owned = true;
        errdefer if (body_owned) {
            body.deinitAfterQueuedResourcesReleased(allocator);
            allocator.destroy(body);
        };
        body.* = fetch_body.Body.initOpen(allocator, identity, 4096);

        const header = bindings.NameValuePair{
            .name = .{ .ptr = "accept".ptr, .len = "accept".len },
            .value = .{ .ptr = "application/json".ptr, .len = "application/json".len },
        };
        var task = try task_model.Task.init(
            allocator,
            identity.fetch_id,
            identity.request_id,
            "https://example.test/old",
            "POST",
            "old-body",
            &.{header},
            0,
            identity,
            body,
        );
        body_owned = false;
        defer task.deinit();

        const next_headers = [_]http.Header{
            .{ .name = "x-next", .value = "yes" },
            .{ .name = "x-extra", .value = "ok" },
        };
        failing.fail_index = failing.alloc_index + fail_index;
        failing.resize_fail_index = failing.resize_index + fail_index;
        const result = task.replaceRequest(
            "https://example.test/new",
            "GET",
            .drop,
            &next_headers,
        );
        if (result) |_| {
            try std.testing.expectEqualStrings("https://example.test/new", task.url);
            try std.testing.expectEqualStrings("GET", task.method);
            try std.testing.expectEqual(@as(usize, 0), task.body.len);
            try std.testing.expectEqual(@as(usize, 2), task.headers.len);
            try std.testing.expectEqualStrings("x-next", task.headers[0].name);
        } else |err| switch (err) {
            error.OutOfMemory => {
                try std.testing.expectEqualStrings("https://example.test/old", task.url);
                try std.testing.expectEqualStrings("POST", task.method);
                try std.testing.expectEqualStrings("old-body", task.body);
                try std.testing.expectEqual(@as(usize, 1), task.headers.len);
                try std.testing.expectEqualStrings("accept", task.headers[0].name);
            },
            else => return err,
        }
    }
}

test "egress task cross-hop egress base sums billed and cost" {
    var body = fetch_body.Body.initOpen(std.testing.allocator, .{
        .request_id = 1,
        .request_generation = 1,
        .fetch_id = 1,
        .body_id = 1,
    }, null);
    defer body.deinitAfterQueuedResourcesReleased(std.testing.allocator);

    var task = try task_model.Task.init(
        std.testing.allocator,
        1,
        1,
        "https://example.test/hop",
        "GET",
        "",
        &.{},
        0,
        body.identity,
        &body,
    );
    body.retain();
    defer task.deinit();

    // A redirect hop adds billed and cost bytes.
    task.addEgressBase(100, 200, 400);
    // A retried attempt adds cost only and leaves billed untouched.
    task.addEgressBase(0, 0, 50);
    const base = task.egressBase();
    try std.testing.expectEqual(@as(u64, 100), base.billed_sent);
    try std.testing.expectEqual(@as(u64, 200), base.billed_received);
    try std.testing.expectEqual(@as(u64, 450), base.cost);
}

test "a denied hop fails with the network_denied cause and the denial's text for the origin of the task's URL" {
    var task = try getTask("https://api.example.com/v1/items?page=2");
    defer task.deinit();

    // The whole text, as the worker shows it to the tenant.
    publishFailure(&task, error.EgressHostDenied, null, ignoreWake);
    try expectFailure(
        &task,
        .network_denied,
        "fetch to https://api.example.com denied by the network setting: the host is not in the allow list",
    );

    const Case = struct { err: anyerror, denial: network.Denial };
    const cases = [_]Case{
        .{ .err = error.EgressNotGranted, .denial = .no_grant },
        .{ .err = error.EgressHostDenied, .denial = .host_not_allowed },
        .{ .err = error.EgressPortDenied, .denial = .port_not_allowed },
        .{ .err = error.EgressSchemeDenied, .denial = .http_not_allowed },
        .{ .err = error.EgressPrivateAddressDenied, .denial = .private_address },
        .{ .err = error.EgressReservedAddressDenied, .denial = .reserved_address },
    };
    try std.testing.expectEqual(std.enums.values(network.Denial).len, cases.len);
    for (cases) |case| {
        publishFailure(&task, case.err, null, ignoreWake);
        const expected = try std.fmt.allocPrint(
            std.testing.allocator,
            "fetch to https://api.example.com denied by the network setting: {s}",
            .{case.denial.describe()},
        );
        defer std.testing.allocator.free(expected);
        try expectFailure(&task, .network_denied, expected);
    }
}

test "a denied redirect names the origin of the URL the redirect moved the task to" {
    var task = try getTask("https://api.example.com/start");
    defer task.deinit();
    try task.replaceRequest("http://10.0.0.7:8080/next", "GET", .drop, &.{});

    publishFailure(&task, error.EgressPrivateAddressDenied, null, ignoreWake);
    const expected = try std.fmt.allocPrint(
        std.testing.allocator,
        "fetch to http://10.0.0.7:8080 denied by the network setting: {s}",
        .{network.Denial.private_address.describe()},
    );
    defer std.testing.allocator.free(expected);
    try expectFailure(&task, .network_denied, expected);
}

test "a failure that is no network denial stays fetch failed with the failed cause" {
    var task = try getTask("https://api.example.com/");
    defer task.deinit();

    publishFailure(&task, error.ConnectionRefused, null, ignoreWake);
    try expectFailure(&task, .failed, "fetch failed: ConnectionRefused");
}

test "a denial names a port other than the scheme's default and omits the default one" {
    const Case = struct { url: []const u8, origin: []const u8 };
    const cases = [_]Case{
        .{ .url = "https://api.example.com:443/x", .origin = "https://api.example.com" },
        .{ .url = "https://api.example.com:8443/x", .origin = "https://api.example.com:8443" },
        .{ .url = "http://api.example.com/x", .origin = "http://api.example.com" },
        .{ .url = "http://api.example.com:443/x", .origin = "http://api.example.com:443" },
        .{ .url = "https://[2606:4700::1111]:8443/x", .origin = "https://[2606:4700::1111]:8443" },
    };
    for (cases) |case| {
        var task = try getTask(case.url);
        defer task.deinit();

        publishFailure(&task, error.EgressPortDenied, null, ignoreWake);
        const expected = try std.fmt.allocPrint(
            std.testing.allocator,
            "fetch to {s} denied by the network setting: {s}",
            .{ case.origin, network.Denial.port_not_allowed.describe() },
        );
        defer std.testing.allocator.free(expected);
        try expectFailure(&task, .network_denied, expected);
    }
}

/// Checks the failure `publishFailure` settled the task with. The message
/// lives in the task's result arena, which `deinit` frees.
fn expectFailure(task: *task_model.Task, cause: task_model.FailureCause, message: []const u8) !void {
    try std.testing.expect(task.done);
    const result = task.result orelse return error.TestExpectedFailure;
    switch (result) {
        .success => return error.TestUnexpectedSuccess,
        .failure => |failure| {
            try std.testing.expectEqual(cause, failure.cause);
            try std.testing.expect(failure.owned);
            try std.testing.expectEqualStrings(message, failure.message);
        },
    }
}

fn ignoreWake(context: ?*anyopaque, event: egress_client.WakeEvent) void {
    _ = context;
    _ = event;
}

/// A GET task to `url` without a request body. The task owns its response
/// body, which `deinit` releases.
fn getTask(url: []const u8) !task_model.Task {
    const identity = bindings.FetchBodyIdentity{
        .request_id = 41,
        .request_generation = 42,
        .fetch_id = 43,
        .body_id = 44,
    };
    const response_body = try std.testing.allocator.create(fetch_body.Body);
    errdefer std.testing.allocator.destroy(response_body);
    response_body.* = fetch_body.Body.initOpen(std.testing.allocator, identity, 4096);
    errdefer response_body.deinitAfterQueuedResourcesReleased(std.testing.allocator);
    return task_model.Task.init(
        std.testing.allocator,
        identity.fetch_id,
        identity.request_id,
        url,
        "GET",
        "",
        &.{},
        0,
        identity,
        response_body,
    );
}

/// A task on `task_counter` whose body is a copy of `bytes` from `body_counter`, handed over as
/// an `OwnedBody`. The task owns its response body, which `deinit` releases.
fn ownedBodyTask(
    task_counter: *std.testing.FailingAllocator,
    body_counter: *std.testing.FailingAllocator,
    bytes: []const u8,
) !task_model.Task {
    const task_allocator = task_counter.allocator();
    const body_allocator = body_counter.allocator();
    const identity = bindings.FetchBodyIdentity{
        .request_id = 31,
        .request_generation = 32,
        .fetch_id = 33,
        .body_id = 34,
    };
    const response_body = try task_allocator.create(fetch_body.Body);
    errdefer task_allocator.destroy(response_body);
    response_body.* = fetch_body.Body.initOpen(task_allocator, identity, 4096);
    errdefer response_body.deinitAfterQueuedResourcesReleased(task_allocator);
    const request_body = try body_allocator.dupe(u8, bytes);
    errdefer body_allocator.free(request_body);
    return task_model.Task.initOwnedBody(
        task_allocator,
        identity.fetch_id,
        identity.request_id,
        "https://example.test/upload",
        "POST",
        .{ .bytes = request_body, .allocator = body_allocator },
        &.{},
        0,
        identity,
        response_body,
    );
}
