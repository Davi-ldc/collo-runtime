//! The io_uring wrapper in `uring.zig`, tested without a ring: user_data
//! packing and its field bounds, errno decoding of a CQE result, the
//! cancellation outcomes, and decoding of copied CQEs, which skips and counts
//! a malformed entry. No other module creates the wrapper's `Ring`, so no lane
//! runs it against a kernel ring.

const std = @import("std");
const io_uring = @import("collo_common_io").uring;

const linux = std.os.linux;

test "io_uring user_data round trips request and generation" {
    const encoded = try (io_uring.UserData{
        .kind = .request_hard_timeout,
        .request_id = 0x12_3456_789a,
        .generation = 0xabc,
    }).pack();
    const decoded = try io_uring.UserData.unpack(encoded);
    try std.testing.expectEqual(io_uring.OperationKind.request_hard_timeout, decoded.kind);
    try std.testing.expectEqual(@as(u64, 0x12_3456_789a), decoded.request_id);
    try std.testing.expectEqual(@as(u64, 0xabc), decoded.generation);
}

test "io_uring user_data rejects invalid tag and oversized fields" {
    try std.testing.expectError(error.InvalidUserDataTag, io_uring.UserData.unpack(0));
    try std.testing.expectError(error.RequestIdTooLarge, (io_uring.UserData{
        .kind = .request_hard_timeout,
        .request_id = io_uring.max_supervised_request_id + 1,
    }).pack());
    try std.testing.expectError(error.GenerationTooLarge, (io_uring.UserData{
        .kind = .request_hard_timeout,
        .generation = io_uring.max_supervised_generation + 1,
    }).pack());
}

test "negative CQE result maps without errno side channel" {
    try std.testing.expectEqual(@as(?linux.E, linux.E.TIME), io_uring.errnoFromResult(-@as(i32, @intFromEnum(linux.E.TIME))));
    try std.testing.expectEqual(@as(?linux.E, null), io_uring.errnoFromResult(0));
    try std.testing.expectEqual(@as(?linux.E, null), io_uring.errnoFromResult(-4096));
}

test "cancellation helpers distinguish success from races" {
    const completed = io_uring.Completion{
        .user_data = .{ .kind = .cancel_timeout },
        .res = 0,
        .flags = 0,
    };
    try std.testing.expect(completed.isCancellationCompleted());
    try std.testing.expect(!completed.isCancellationRace());
    try std.testing.expect(completed.isCancellationRaceOrCompleted());

    const raced = io_uring.Completion{
        .user_data = .{ .kind = .cancel_timeout },
        .res = -@as(i32, @intFromEnum(linux.E.NOENT)),
        .flags = 0,
    };
    try std.testing.expect(!raced.isCancellationCompleted());
    try std.testing.expect(raced.isCancellationRace());
    try std.testing.expect(raced.isCancellationRaceOrCompleted());

    const failed = io_uring.Completion{
        .user_data = .{ .kind = .cancel_timeout },
        .res = -@as(i32, @intFromEnum(linux.E.INVAL)),
        .flags = 0,
    };
    try std.testing.expect(!failed.isCancellationCompleted());
    try std.testing.expect(!failed.isCancellationRace());
    try std.testing.expect(!failed.isCancellationRaceOrCompleted());
}

test "decode copied completions skips invalid CQEs without dropping valid peers" {
    const first = try (io_uring.UserData{ .kind = .worker_deadline_command }).pack();
    const third = try (io_uring.UserData{ .kind = .worker_deadline_timeout, .request_id = 42, .generation = 7 }).pack();
    const cqes = [_]linux.io_uring_cqe{
        .{ .user_data = first, .res = 0, .flags = 0 },
        .{ .user_data = 0, .res = -@as(i32, @intFromEnum(linux.E.CANCELED)), .flags = 0 },
        .{ .user_data = third, .res = -@as(i32, @intFromEnum(linux.E.TIME)), .flags = 0 },
    };
    var completions: [3]io_uring.Completion = undefined;
    const malformed_before = io_uring.malformedCqeCount();

    const count = io_uring.decodeCopiedCompletions(&cqes, &completions);

    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(malformed_before + 1, io_uring.malformedCqeCount());
    try std.testing.expectEqual(io_uring.OperationKind.worker_deadline_command, completions[0].user_data.kind);
    try std.testing.expectEqual(io_uring.OperationKind.worker_deadline_timeout, completions[1].user_data.kind);
    try std.testing.expectEqual(@as(u64, 42), completions[1].user_data.request_id);
    try std.testing.expectEqual(@as(u64, 7), completions[1].user_data.generation);
}
