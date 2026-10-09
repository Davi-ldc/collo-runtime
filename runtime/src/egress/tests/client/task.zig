//! Tests of the gateway's fetch task: it owns copies of the request it was
//! given, a body it took as an `OwnedBody` goes back to the allocator that
//! came with it, at the end and at a redirect, `replaceRequest` keeps the
//! previous request when any allocation fails, and the meter totals add
//! billed and cost bytes per attempt. Lane `egress-test`.

const std = @import("std");
const bindings = @import("collo_bindings");
const http = @import("collo_http");
const egress_client = @import("collo_egress_client");

const fetch_body = egress_client.fetch_body;
const task_model = egress_client.task;

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

test "egress task redirect returns an owned body to its allocator and owns the next hop's" {
    var task_counter = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var body_counter = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var task = try ownedBodyTask(&task_counter, &body_counter, "assembled upload body");
    defer task.deinit();

    // A 307 replays the same bytes, which the redirect passes as a slice of the current body.
    const next_headers = [_]http.Header{.{ .name = "x-hop", .value = "2" }};
    try task.replaceRequest("https://example.test/next", "POST", task.body, &next_headers);
    try std.testing.expectEqualStrings("assembled upload body", task.body);
    try std.testing.expectEqual(body_counter.allocated_bytes, body_counter.freed_bytes);
    try std.testing.expectEqual(task.allocator.ptr, task.body_allocator.ptr);
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
            "PUT",
            "new-body",
            &next_headers,
        );
        if (result) |_| {
            try std.testing.expectEqualStrings("https://example.test/new", task.url);
            try std.testing.expectEqualStrings("PUT", task.method);
            try std.testing.expectEqualStrings("new-body", task.body);
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
