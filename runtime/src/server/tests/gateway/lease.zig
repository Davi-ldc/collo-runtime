//! The lease an ingress lane holds on the current egress gateway (`server/gateway/lease.zig`),
//! driven over a socket pair whose far end plays the gateway and counts the packets that reach
//! it. Minting a request's token and noting the request's end touch no socket, so a dispatch
//! sends the gateway nothing; the ended requests leave together as one datagram per `flush`, and a
//! batch that fills up leaves on its own. A flush never waits: a gateway whose socket is full or
//! gone loses the batch, and the lease counts the loss. The manager that hands leases out is
//! covered in `manager.zig` and the batch's wire format in `egress/tests/gateway/control.zig`.
//! Lane: server-gateway.

const std = @import("std");
const os = @import("collo_os");
const ipc = @import("collo_ipc");
const gateway = @import("collo_server_gateway");
const control = @import("collo_egress_gateway").control;

const egress_token = ipc.egress_token;
const Lease = gateway.lease.Lease;

const lease_key: egress_token.Key = .{ .bytes = @splat(0x5a) };
const other_key: egress_token.Key = .{ .bytes = @splat(0xa5) };
const zero_key: egress_token.Key = .{ .bytes = @splat(0) };
const generation: u64 = 7;
const session_id: u64 = 41;

/// Packets a test writes at most while filling a socket; the kernel refuses far fewer.
const filler_packets_max: usize = 1 << 16;
const filler_bytes: usize = 8;

test "minting tokens and noting request ends sends nothing until the pass flushes (#31)" {
    var fake = try FakeGateway.init();
    defer fake.deinit();
    const lease = try createLease();
    defer destroyLease(lease);
    lease.replace(generation, lease_key, fake.takeLeaseEnd());

    var scratch: [control.request_ended_bytes_max]u8 = undefined;
    const request_count: usize = 64;
    for (1..request_count + 1) |request_id| {
        const token = lease.mint(generation, requestFields(request_id));
        try expectToken(&token, &lease_key, requestFields(request_id));
        lease.noteEnded(generation, endedEntry(request_id));
        try fake.expectNothing(&scratch);
    }

    lease.flush();
    try fake.expectBatch(&scratch, 1, request_count);
    try fake.expectNothing(&scratch);
    // A pass that ended no request sends nothing.
    lease.flush();
    try fake.expectNothing(&scratch);
    try std.testing.expectEqual(@as(u64, 0), lease.ended_batches_dropped_full);
    try std.testing.expectEqual(@as(u64, 0), lease.ended_batches_dropped_closed);
}

test "a lease mints tokens only for workers of the gateway it holds" {
    const lease = try createLease();
    defer destroyLease(lease);
    // A lease that holds no gateway mints nothing.
    try expectNone(&lease.mint(0, requestFields(1)));
    try expectNone(&lease.mint(generation, requestFields(1)));

    var fake = try FakeGateway.init();
    defer fake.deinit();
    lease.replace(generation, lease_key, fake.takeLeaseEnd());
    // A worker whose session belongs to another gateway is detached or waiting for its
    // reattach, so its request carries no token and the worker refuses the fetch itself.
    try expectNone(&lease.mint(generation - 1, requestFields(1)));
    try expectNone(&lease.mint(generation + 1, requestFields(1)));
    try expectNone(&lease.mint(0, requestFields(1)));

    const minted = lease.mint(generation, requestFields(1));
    try expectToken(&minted, &lease_key, requestFields(1));
    const token = egress_token.fromBytes(&minted);
    try std.testing.expectError(error.BadTag, egress_token.verify(&other_key, &token));
}

test "request ends of workers of another gateway are dropped" {
    var fake = try FakeGateway.init();
    defer fake.deinit();
    const lease = try createLease();
    defer destroyLease(lease);
    lease.replace(generation, lease_key, fake.takeLeaseEnd());

    lease.noteEnded(generation - 1, endedEntry(1));
    lease.noteEnded(generation + 1, endedEntry(2));
    lease.noteEnded(0, endedEntry(3));
    lease.noteEnded(generation, endedEntry(4));
    lease.flush();

    var scratch: [control.request_ended_bytes_max]u8 = undefined;
    try fake.expectBatch(&scratch, 4, 1);
    try fake.expectNothing(&scratch);
}

test "renewing the lease drops its pending entries and closes the old descriptor" {
    var first = try FakeGateway.init();
    defer first.deinit();
    var second = try FakeGateway.init();
    defer second.deinit();
    const lease = try createLease();
    defer destroyLease(lease);

    lease.replace(generation, lease_key, first.takeLeaseEnd());
    lease.noteEnded(generation, endedEntry(1));
    lease.replace(generation + 1, other_key, second.takeLeaseEnd());

    // The earlier gateway's end saw no packet before its socket closed, and its pending entry
    // went with it: that gateway is gone with its budgets.
    var scratch: [control.request_ended_bytes_max]u8 = undefined;
    try first.expectClosed(&scratch);
    lease.flush();
    try second.expectNothing(&scratch);

    try expectNone(&lease.mint(generation, requestFields(2)));
    const minted = lease.mint(generation + 1, requestFields(2));
    try expectToken(&minted, &other_key, requestFields(2));
    lease.noteEnded(generation + 1, endedEntry(2));
    lease.flush();
    try second.expectBatch(&scratch, 2, 1);
}

test "a lease renewed while no gateway is current mints nothing and sends nothing" {
    var fake = try FakeGateway.init();
    defer fake.deinit();
    const lease = try createLease();
    defer destroyLease(lease);
    lease.replace(generation, lease_key, fake.takeLeaseEnd());
    lease.noteEnded(generation, endedEntry(1));

    // With no gateway current the manager hands out generation 0 and no descriptor.
    lease.replace(0, zero_key, .{});
    var scratch: [control.request_ended_bytes_max]u8 = undefined;
    try fake.expectClosed(&scratch);

    try expectNone(&lease.mint(0, requestFields(2)));
    try expectNone(&lease.mint(generation, requestFields(2)));
    lease.noteEnded(0, endedEntry(2));
    lease.noteEnded(generation, endedEntry(3));
    try std.testing.expect(lease.ended.isEmpty());
    lease.flush();
    try std.testing.expect(lease.ended.isEmpty());
    try std.testing.expectEqual(@as(u64, 0), lease.ended_batches_dropped_full);
    try std.testing.expectEqual(@as(u64, 0), lease.ended_batches_dropped_closed);
}

test "a flush into a full gateway socket loses the batch at once and counts it" {
    var fake = try FakeGateway.init();
    defer fake.deinit();
    const filler_count = try fake.fillLeaseEnd();
    const lease = try createLease();
    defer destroyLease(lease);
    lease.replace(generation, lease_key, fake.takeLeaseEnd());

    lease.noteEnded(generation, endedEntry(1));
    lease.noteEnded(generation, endedEntry(2));
    // The test thread is the only reader of the gateway's end, so a flush that waited for room
    // would never return.
    lease.flush();
    try std.testing.expectEqual(@as(u64, 1), lease.ended_batches_dropped_full);
    try std.testing.expectEqual(@as(u64, 0), lease.ended_batches_dropped_closed);
    try std.testing.expect(lease.ended.isEmpty());

    // Only the filler waits on the gateway's end, and the lost batch does not come back once
    // there is room.
    var scratch: [control.request_ended_bytes_max]u8 = undefined;
    try std.testing.expectEqual(filler_count, try fake.drainFiller(&scratch));
    lease.flush();
    try fake.expectNothing(&scratch);
    lease.noteEnded(generation, endedEntry(3));
    lease.flush();
    try fake.expectBatch(&scratch, 3, 1);
    try std.testing.expectEqual(@as(u64, 1), lease.ended_batches_dropped_full);
}

test "a flush to a gateway that is gone loses the batch and counts it" {
    var fake = try FakeGateway.init();
    defer fake.deinit();
    const lease = try createLease();
    defer destroyLease(lease);
    lease.replace(generation, lease_key, fake.takeLeaseEnd());

    fake.closeGatewayEnd();
    lease.noteEnded(generation, endedEntry(1));
    lease.flush();
    try std.testing.expectEqual(@as(u64, 1), lease.ended_batches_dropped_closed);
    try std.testing.expectEqual(@as(u64, 0), lease.ended_batches_dropped_full);
    try std.testing.expect(lease.ended.isEmpty());
}

test "a full batch leaves from noteEnded before the next entry is kept" {
    var fake = try FakeGateway.init();
    defer fake.deinit();
    const lease = try createLease();
    defer destroyLease(lease);
    lease.replace(generation, lease_key, fake.takeLeaseEnd());

    const entries_max = control.request_ended_entries_max;
    var scratch: [control.request_ended_bytes_max]u8 = undefined;
    for (1..entries_max + 1) |request_id|
        lease.noteEnded(generation, endedEntry(request_id));
    try fake.expectNothing(&scratch);

    lease.noteEnded(generation, endedEntry(entries_max + 1));
    try fake.expectBatch(&scratch, 1, entries_max);
    try fake.expectNothing(&scratch);
    lease.flush();
    try fake.expectBatch(&scratch, entries_max + 1, 1);
    try fake.expectNothing(&scratch);
}

/// The two ends of a control socket: the lease sends on `lease_end`, which `takeLeaseEnd` hands
/// to it, and the test reads what reaches `gateway_end`. Both are nonblocking, as the manager's
/// control socket is.
const FakeGateway = struct {
    gateway_end: std.posix.fd_t,
    lease_end: std.posix.fd_t,

    fn init() !FakeGateway {
        const pair = try os.fd.socketPairType(
            std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
        );
        return .{ .gateway_end = pair[0], .lease_end = pair[1] };
    }

    fn deinit(self: *FakeGateway) void {
        if (self.lease_end >= 0)
            std.posix.close(self.lease_end);
        self.closeGatewayEnd();
        self.* = undefined;
    }

    fn takeLeaseEnd(self: *FakeGateway) os.fd.OwnedFd {
        std.debug.assert(self.lease_end >= 0);
        const taken = self.lease_end;
        self.lease_end = -1;
        return os.fd.OwnedFd.fromRaw(taken);
    }

    fn closeGatewayEnd(self: *FakeGateway) void {
        if (self.gateway_end >= 0)
            std.posix.close(self.gateway_end);
        self.gateway_end = -1;
    }

    /// Sends filler packets on the lease's end until the socket refuses one, and returns how
    /// many it took.
    fn fillLeaseEnd(self: *FakeGateway) !usize {
        const filler: [filler_bytes]u8 = @splat(0);
        for (0..filler_packets_max) |sent| {
            ipc.packet.sendExact(self.lease_end, &filler) catch |err| switch (err) {
                error.WouldBlock => {
                    try std.testing.expect(sent > 0);
                    return sent;
                },
                else => return err,
            };
        }
        return error.TestSocketNeverFilled;
    }

    /// Reads the filler waiting on the gateway's end and returns how many packets it was.
    fn drainFiller(self: *const FakeGateway, scratch: []u8) !usize {
        for (0..filler_packets_max + 1) |drained| {
            var packet = ipc.recvPacketWithFdsScratch(
                std.testing.allocator,
                self.gateway_end,
                scratch,
            ) catch |err| switch (err) {
                error.WouldBlock => return drained,
                else => return err,
            };
            defer packet.deinit();
            try std.testing.expectEqual(filler_bytes, packet.bytes.len);
        }
        return error.TestFillerNeverDrained;
    }

    /// Reads one `request_ended` packet and checks that it names `count` requests in order,
    /// from `first_request_id` on.
    fn expectBatch(
        self: *const FakeGateway,
        scratch: []u8,
        first_request_id: usize,
        count: usize,
    ) !void {
        var packet = try ipc.recvPacketWithFdsScratch(std.testing.allocator, self.gateway_end, scratch);
        defer packet.deinit();
        const ended = switch (try control.decode(&packet)) {
            .request_ended => |ended| ended,
            else => return error.TestUnexpectedControlMessage,
        };
        try std.testing.expectEqual(count, ended.count);
        for (0..count) |index|
            try std.testing.expectEqual(endedEntry(first_request_id + index), ended.entry(index));
    }

    fn expectNothing(self: *const FakeGateway, scratch: []u8) !void {
        try std.testing.expectError(
            error.WouldBlock,
            ipc.recvPacketWithFdsScratch(std.testing.allocator, self.gateway_end, scratch),
        );
    }

    /// Checks that the lease's end is closed and nothing was left on the way.
    fn expectClosed(self: *const FakeGateway, scratch: []u8) !void {
        try std.testing.expectError(
            error.PeerClosed,
            ipc.recvPacketWithFdsScratch(std.testing.allocator, self.gateway_end, scratch),
        );
    }
};

/// A lease holds a whole `request_ended` packet, so tests keep it on the heap.
fn createLease() !*Lease {
    const lease = try std.testing.allocator.create(Lease);
    lease.* = .{};
    return lease;
}

fn destroyLease(lease: *Lease) void {
    lease.deinit();
    std.testing.allocator.destroy(lease);
}

fn requestFields(request_id: u64) egress_token.Fields {
    return .{
        .kind = .request,
        .policy_id = 0,
        .budget = 16,
        .session_id = session_id,
        .request_id = request_id,
        .request_generation = request_id + 1_000,
        .deadline_monotonic_ns = 5_000_000_000 + request_id,
    };
}

fn endedEntry(request_id: u64) control.RequestEndedEntry {
    return .{
        .session_id = session_id,
        .request_id = request_id,
        .request_generation = request_id + 1_000,
    };
}

fn expectToken(
    bytes: *const egress_token.Bytes,
    key: *const egress_token.Key,
    expected: egress_token.Fields,
) !void {
    try std.testing.expect(!egress_token.isNone(bytes));
    const token = egress_token.fromBytes(bytes);
    try std.testing.expectEqual(expected, try egress_token.verify(key, &token));
}

fn expectNone(bytes: *const egress_token.Bytes) !void {
    try std.testing.expect(egress_token.isNone(bytes));
}
