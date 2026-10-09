//! Tests of the readiness driver the HTTP/2 pool waits on: a wake through the
//! eventfd, deadline expiry on the poll and io_uring backends, readable and
//! writable reports, and one poll entry per fd when several streams share it.
//! The io_uring tests return early when the kernel refuses a ring.

const std = @import("std");
const test_support = @import("support.zig");
const pool = test_support.pool;
const data_io = test_support.data_io;
const readiness = test_support.readiness;
const transport = test_support.transport;
const TestH2Origin = test_support.TestH2Origin;
const collo_test_h2_origin_start = test_support.collo_test_h2_origin_start;
const collo_test_h2_origin_stop = test_support.collo_test_h2_origin_stop;
const collo_test_h2_origin_last_error = test_support.collo_test_h2_origin_last_error;
const collo_test_h2_origin_stream_count = test_support.collo_test_h2_origin_stream_count;
const collo_test_h2_origin_selected_alpn = test_support.collo_test_h2_origin_selected_alpn;
const test_h2_origin_alpn_h2 = test_support.test_h2_origin_alpn_h2;
const test_h2_origin_alpn_http11 = test_support.test_h2_origin_alpn_http11;
const test_alpn_h2 = test_support.test_alpn_h2;
const routableLocalIpv4 = test_support.routableLocalIpv4;
const FakeWriteTransport = test_support.FakeWriteTransport;

test "http2 egress pool readiness can be woken by owner eventfd" {
    var driver = try readiness.Driver.initWithBackend(std.testing.allocator, .poll);
    defer driver.deinit();
    const wake_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    defer std.posix.close(wake_fd);

    var one: u64 = 1;
    _ = try std.posix.write(wake_fd, std.mem.asBytes(&one));
    try std.testing.expectEqual(
        readiness.Result.wake,
        try driver.wait(&.{}, wake_fd),
    );
}

test "http2 egress readiness can use io_uring when supported" {
    var driver = readiness.Driver.initWithBackend(std.testing.allocator, .io_uring) catch return;
    defer driver.deinit();
    try std.testing.expectEqual(readiness.Backend.io_uring, driver.backendKind());
    const fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    defer std.posix.close(fd);
    var context: u8 = 1;
    var one: u64 = 1;
    _ = try std.posix.write(fd, std.mem.asBytes(&one));

    const result = try driver.wait(&.{.{
        .context = &context,
        .handle = .{ .fd = fd },
        .deadline_mono_ns = try readiness.deadlineAfterMs(1000),
    }}, null);
    switch (result) {
        .ready => |ready| {
            try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&context)), ready.context);
            try std.testing.expect(ready.readable);
        },
        else => return error.ExpectedReadyReadiness,
    }
}

test "http2 egress io_uring readiness expires without falling back to poll" {
    var driver = readiness.Driver.initWithBackend(std.testing.allocator, .io_uring) catch return;
    defer driver.deinit();
    var context: u8 = 0;
    const now = try readiness.monotonicNowNs();

    const result = try driver.wait(&.{.{
        .context = &context,
        .handle = .{ .fd = -1 },
        .deadline_mono_ns = now,
    }}, null);
    switch (result) {
        .expired => |expired| try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&context)), expired),
        else => return error.ExpectedExpiredReadiness,
    }
    try std.testing.expectEqual(readiness.Backend.io_uring, driver.backendKind());
}

test "http2 egress readiness expires streams on monotonic deadlines" {
    var driver = try readiness.Driver.initWithBackend(std.testing.allocator, .poll);
    defer driver.deinit();
    var context: u8 = 0;
    const now = try readiness.monotonicNowNs();

    const result = try driver.wait(&.{.{
        .context = &context,
        .handle = .{ .fd = -1 },
        .deadline_mono_ns = now,
    }}, null);
    switch (result) {
        .expired => |expired| try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&context)), expired),
        else => return error.ExpectedExpiredReadiness,
    }
}

test "http2 egress readiness keeps duplicate fd deadlines per stream" {
    var driver = try readiness.Driver.initWithBackend(std.testing.allocator, .poll);
    defer driver.deinit();
    var first_context: u8 = 1;
    var second_context: u8 = 2;
    const now = try readiness.monotonicNowNs();

    const result = try driver.wait(&.{
        .{
            .context = &first_context,
            .handle = .{ .fd = -1 },
            .deadline_mono_ns = now + std.time.ns_per_s,
        },
        .{
            .context = &second_context,
            .handle = .{ .fd = -1 },
            .deadline_mono_ns = now,
        },
    }, null);
    switch (result) {
        .expired => |expired| try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&second_context)), expired),
        else => return error.ExpectedExpiredReadiness,
    }
}

test "http2 egress readiness polls duplicate stream fds once" {
    var driver = try readiness.Driver.initWithBackend(std.testing.allocator, .poll);
    defer driver.deinit();
    const fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    defer std.posix.close(fd);
    var first_context: u8 = 1;
    var second_context: u8 = 2;
    var one: u64 = 1;
    _ = try std.posix.write(fd, std.mem.asBytes(&one));

    const deadline = try readiness.deadlineAfterMs(1000);
    const result = try driver.wait(&.{
        .{
            .context = &first_context,
            .handle = .{ .fd = fd },
            .deadline_mono_ns = deadline,
        },
        .{
            .context = &second_context,
            .handle = .{ .fd = fd },
            .deadline_mono_ns = deadline,
        },
    }, null);
    switch (result) {
        .ready => |ready| {
            try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&first_context)), ready.context);
            try std.testing.expect(ready.readable);
        },
        else => return error.ExpectedReadyReadiness,
    }
    try std.testing.expectEqual(@as(usize, 1), driver.pollBackendFdCount() orelse return error.ExpectedPollReadinessBackend);
}

test "http2 egress readiness reports writable streams" {
    var driver = try readiness.Driver.initWithBackend(std.testing.allocator, .poll);
    defer driver.deinit();
    const fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    defer std.posix.close(fd);
    var context: u8 = 1;

    const result = try driver.wait(&.{.{
        .context = &context,
        .handle = .{ .fd = fd },
        .deadline_mono_ns = try readiness.deadlineAfterMs(1000),
        .want_read = false,
        .want_write = true,
    }}, null);
    switch (result) {
        .ready => |ready| {
            try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&context)), ready.context);
            try std.testing.expect(!ready.readable);
            try std.testing.expect(ready.writable);
        },
        else => return error.ExpectedWritableReadiness,
    }
}

test "http2 egress readiness merges duplicate read and write interests" {
    var driver = try readiness.Driver.initWithBackend(std.testing.allocator, .poll);
    defer driver.deinit();
    const fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    defer std.posix.close(fd);
    var first_context: u8 = 1;
    var second_context: u8 = 2;
    var one: u64 = 1;
    _ = try std.posix.write(fd, std.mem.asBytes(&one));

    const deadline = try readiness.deadlineAfterMs(1000);
    const result = try driver.wait(&.{
        .{
            .context = &first_context,
            .handle = .{ .fd = fd },
            .deadline_mono_ns = deadline,
            .want_read = true,
            .want_write = false,
        },
        .{
            .context = &second_context,
            .handle = .{ .fd = fd },
            .deadline_mono_ns = deadline,
            .want_read = false,
            .want_write = true,
        },
    }, null);
    switch (result) {
        .ready => |ready| {
            try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&first_context)), ready.context);
            try std.testing.expect(ready.readable);
            try std.testing.expect(ready.writable);
        },
        else => return error.ExpectedReadyReadiness,
    }
    try std.testing.expectEqual(
        std.posix.POLL.IN | std.posix.POLL.OUT | std.posix.POLL.HUP | std.posix.POLL.ERR,
        driver.pollBackendFdEvents(0) orelse return error.ExpectedPollReadinessBackend,
    );
}
