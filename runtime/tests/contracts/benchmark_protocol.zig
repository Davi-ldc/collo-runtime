//! Command framing and JSONL record output of the sandbox benchmark's
//! sampler protocol (`runtime/bench/sandbox/protocol.zig`). Fixed readers
//! exercise parsing. Regular files exercise the streaming reader's capacity
//! bound and catch a positional writer that restarts at offset 0 on every
//! record, which a pipe would hide. Runs in `microbench-test` and `meta-test`;
//! the exchange between a live sampler and its daemon runs only in
//! `bench-cold-start` and `bench-memory`.

const std = @import("std");
const protocol = @import("benchmark_protocol");
const testing = std.testing;

const snapshot = "{\"op\":\"snapshot\"}";

test "benchmark protocol consumes delimiters between sequential commands" {
    var input: std.Io.Reader = .fixed(snapshot ++ "\n{\"op\":\"prepare\",\"route\":7}\n");
    const first = (try protocol.readCommand(&input, testing.allocator)).?;
    defer first.deinit();
    try testing.expect(first.value.op == .snapshot);
    const second = (try protocol.readCommand(&input, testing.allocator)).?;
    defer second.deinit();
    try testing.expect(second.value.op == .prepare);
    try testing.expectEqual(@as(?u32, 7), second.value.route);
    try testing.expect((try protocol.readCommand(&input, testing.allocator)) == null);
}

test "benchmark protocol distinguishes EOF from empty command lines" {
    var empty: std.Io.Reader = .fixed("");
    try testing.expect((try protocol.readCommand(&empty, testing.allocator)) == null);
    var input: std.Io.Reader = .fixed("\n \t\r\n" ++ snapshot ++ "\n");
    try testing.expectError(error.EmptyCommand, protocol.readCommand(&input, testing.allocator));
    try testing.expectError(error.EmptyCommand, protocol.readCommand(&input, testing.allocator));
    const parsed = (try protocol.readCommand(&input, testing.allocator)).?;
    defer parsed.deinit();
    try testing.expect(parsed.value.op == .snapshot);
    try testing.expect((try protocol.readCommand(&input, testing.allocator)) == null);
}

test "benchmark protocol consumes malformed records without consuming their successor" {
    var input: std.Io.Reader = .fixed("{\n{\"op\":!}\n" ++ snapshot ++ "\n");
    try testing.expectError(
        error.UnexpectedEndOfInput,
        protocol.readCommand(&input, testing.allocator),
    );
    try testing.expectError(error.SyntaxError, protocol.readCommand(&input, testing.allocator));
    const parsed = (try protocol.readCommand(&input, testing.allocator)).?;
    defer parsed.deinit();
    try testing.expect(parsed.value.op == .snapshot);
}

test "benchmark protocol accepts a final complete JSON record without a newline" {
    var input: std.Io.Reader = .fixed(snapshot);
    const parsed = (try protocol.readCommand(&input, testing.allocator)).?;
    defer parsed.deinit();
    try testing.expect(parsed.value.op == .snapshot);
    try testing.expect((try protocol.readCommand(&input, testing.allocator)) == null);
}

test "benchmark protocol rejects oversized commands at both framing boundaries" {
    var bytes: [protocol.command_bytes_max + 2]u8 = @splat(' ');
    @memcpy(bytes[0..snapshot.len], snapshot);
    bytes[protocol.command_bytes_max] = '\n';
    var exact: std.Io.Reader = .fixed(bytes[0 .. protocol.command_bytes_max + 1]);
    const parsed = (try protocol.readCommand(&exact, testing.allocator)).?;
    defer parsed.deinit();
    try testing.expect(parsed.value.op == .snapshot);
    bytes[protocol.command_bytes_max] = ' ';
    bytes[protocol.command_bytes_max + 1] = '\n';
    var oversized: std.Io.Reader = .fixed(&bytes);
    try testing.expectError(
        error.CommandTooLarge,
        protocol.readCommand(&oversized, testing.allocator),
    );

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "commands", .data = &bytes });
    const file = try tmp.dir.openFile("commands", .{});
    defer file.close();
    var buffer: [protocol.command_bytes_max + 1]u8 = undefined;
    var streaming = file.readerStreaming(&buffer);
    try testing.expectError(
        error.CommandTooLarge,
        protocol.readCommand(&streaming.interface, testing.allocator),
    );
}

test "benchmark protocol appends successive JSON records on one regular file descriptor" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("records.jsonl", .{ .read = true });
    defer file.close();
    try protocol.writeRecord(file, .{ .sequence = @as(u32, 1), .label = "first" });
    try protocol.writeRecord(file, .{ .sequence = @as(u32, 2) });
    try protocol.writeRecord(file, .{ .sequence = @as(u32, 3), .label = "line\nbreak" });
    try file.seekTo(0);
    var buffer: [128]u8 = undefined;
    var input = file.readerStreaming(&buffer);
    const contents = try input.interface.allocRemaining(testing.allocator, .limited(1024));
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings(
        "{\"sequence\":1,\"label\":\"first\"}\n" ++
            "{\"sequence\":2}\n" ++
            "{\"sequence\":3,\"label\":\"line\\nbreak\"}\n",
        contents,
    );
}
