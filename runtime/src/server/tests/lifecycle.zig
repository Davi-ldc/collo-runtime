//! The server's lifecycle identities (`server/lifecycle.zig`): a worker key
//! equals one with the same id and generation and differs from one that
//! changes only the generation, and the next generation after the largest one
//! is 1, never 0. Lane `server-core-test`.

const std = @import("std");
const lifecycle = @import("collo_server_lifecycle");

test "lifecycle keys compare by full generation identity" {
    const worker = lifecycle.WorkerKey{ .worker_id = 1, .worker_generation = 2 };
    try std.testing.expect(worker.eql(.{ .worker_id = 1, .worker_generation = 2 }));
    try std.testing.expect(!worker.eql(.{ .worker_id = 1, .worker_generation = 3 }));
    try std.testing.expectEqual(@as(u64, 1), lifecycle.nextGeneration(std.math.maxInt(u64)));
}
