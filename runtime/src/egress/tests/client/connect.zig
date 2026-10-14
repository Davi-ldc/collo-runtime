//! Happy Eyeballs ordering and timing (`egress/client/transport/connect.zig`)
//! on a fake clock: the order candidates are tried in, when the next attempt
//! is due, the cap on attempts in flight, and when a dial has run out. The
//! last tests race real connects to listeners and closed ports on 127.0.0.1,
//! with the schedule's clock standing still, so the attempts' outcomes alone
//! decide what starts next. The data driver tests cover the driver's connect
//! watch, and the engine suite in engine/ covers dials end to end.

const std = @import("std");
const connect = @import("collo_egress_client").transport.connect;

const delay = connect.attempt_delay_ns;
/// Bound on the rounds of one real race: each launches what is due, then
/// waits for a pending attempt to end.
const max_race_rounds: usize = 16;
/// The longest one round waits for a pending attempt to end.
const race_wait_ms: i32 = 5_000;

fn ip6(last: u8) std.net.Address {
    var bytes = [_]u8{0} ** 16;
    bytes[0] = 0x20;
    bytes[1] = 0x01;
    bytes[2] = 0x0d;
    bytes[3] = 0xb8;
    bytes[15] = last;
    return std.net.Address.initIp6(bytes, 443, 0, 0);
}

fn ip4(last: u8) std.net.Address {
    return std.net.Address.initIp4(.{ 192, 0, 2, last }, 443);
}

fn expectAddress(expected: std.net.Address, actual: ?std.net.Address) !void {
    const got = actual orelse return error.CandidateMissing;
    try std.testing.expect(expected.eql(got));
}

test "egress connect candidates alternate IPv6 and IPv4 starting with IPv6" {
    const addresses = [_]std.net.Address{ ip4(1), ip4(2), ip4(3), ip6(1), ip6(2) };
    var cursor = connect.CandidateCursor.init(&addresses);
    try expectAddress(ip6(1), cursor.next());
    try expectAddress(ip4(1), cursor.next());
    try expectAddress(ip6(2), cursor.next());
    try expectAddress(ip4(2), cursor.next());
    // IPv6 ran out, so IPv4 continues alone.
    try expectAddress(ip4(3), cursor.next());
    try std.testing.expect(!cursor.hasMore());
    try std.testing.expect(cursor.next() == null);
}

test "egress connect schedule launches at once and the next attempt only after the delay" {
    const addresses = [_]std.net.Address{ ip6(1), ip4(1), ip6(2) };
    var schedule = connect.Schedule.init(&addresses);
    const start_ns: u64 = 1_000_000;

    const first = schedule.launchDue(start_ns) orelse return error.FirstAttemptNotDue;
    try std.testing.expect(ip6(1).eql(first.address));
    schedule.markPending(first.slot, start_ns);

    try std.testing.expect(schedule.launchDue(start_ns + delay - 1) == null);
    try std.testing.expectEqual(@as(?u64, start_ns + delay), schedule.launchDeadlineNs());

    const second = schedule.launchDue(start_ns + delay) orelse return error.SecondAttemptNotDue;
    try std.testing.expect(ip4(1).eql(second.address));
    try std.testing.expect(second.slot != first.slot);
}

test "egress connect schedule launches the next candidate at once when the pending attempt failed" {
    const addresses = [_]std.net.Address{ ip6(1), ip4(1) };
    var schedule = connect.Schedule.init(&addresses);
    const start_ns: u64 = 5_000;

    const first = schedule.launchDue(start_ns).?;
    schedule.markPending(first.slot, start_ns);
    schedule.markDone(first.slot);

    const second = schedule.launchDue(start_ns + 1) orelse return error.NextAttemptNotDue;
    try std.testing.expect(ip4(1).eql(second.address));
}

test "egress connect schedule hands a failed start's turn to the next candidate" {
    const addresses = [_]std.net.Address{ ip6(1), ip4(1) };
    var schedule = connect.Schedule.init(&addresses);
    // The caller could not start the first attempt and asks again without
    // marking it pending.
    _ = schedule.launchDue(0).?;
    const next = schedule.launchDue(0) orelse return error.NextAttemptNotDue;
    try std.testing.expect(ip4(1).eql(next.address));
}

test "egress connect schedule keeps at most the attempt cap in flight" {
    var addresses: [connect.max_parallel_attempts + 2]std.net.Address = undefined;
    for (&addresses, 0..) |*address, index|
        address.* = ip4(@intCast(index + 1));
    var schedule = connect.Schedule.init(&addresses);

    var now_ns: u64 = 0;
    for (0..connect.max_parallel_attempts) |_| {
        const launch = schedule.launchDue(now_ns) orelse return error.AttemptNotDue;
        schedule.markPending(launch.slot, now_ns);
        now_ns += delay;
    }
    // Every slot is pending: nothing is due however late, and no launch
    // deadline is armed.
    try std.testing.expect(schedule.launchDue(now_ns + 10 * delay) == null);
    try std.testing.expectEqual(@as(?u64, null), schedule.launchDeadlineNs());

    schedule.markDone(0);
    const refill = schedule.launchDue(now_ns) orelse return error.FreedSlotNotReused;
    try std.testing.expectEqual(@as(usize, 0), refill.slot);
}

test "egress connect schedule is exhausted only once every candidate launched and ended" {
    const addresses = [_]std.net.Address{ ip6(1), ip4(1) };
    var schedule = connect.Schedule.init(&addresses);
    try std.testing.expect(!schedule.exhausted());

    const first = schedule.launchDue(0).?;
    schedule.markPending(first.slot, 0);
    const second = schedule.launchDue(delay).?;
    schedule.markPending(second.slot, delay);
    // No candidate is left, so no launch deadline either.
    try std.testing.expectEqual(@as(?u64, null), schedule.launchDeadlineNs());
    try std.testing.expect(!schedule.exhausted());

    schedule.markDone(first.slot);
    try std.testing.expect(!schedule.exhausted());
    schedule.markDone(second.slot);
    try std.testing.expect(schedule.exhausted());
    try std.testing.expect(schedule.launchDue(10 * delay) == null);
}

/// A listener on 127.0.0.1 whose accept never blocks, so a test can tell
/// whether a connection reached it.
fn loopbackListener() !std.net.Server {
    const address = try std.net.Address.parseIp4("127.0.0.1", 0);
    return address.listen(.{ .force_nonblocking = true });
}

/// A 127.0.0.1 address nothing listens on: the port of a listener that was
/// just closed, so a connect to it is refused.
fn closedLoopbackAddress() !std.net.Address {
    var listener = try loopbackListener();
    const address = listener.listen_address;
    listener.deinit();
    return address;
}

/// How many connections reached `listener` so far.
fn acceptedCount(listener: *std.net.Server) !usize {
    var count: usize = 0;
    while (count < connect.max_parallel_attempts) : (count += 1) {
        const connection = listener.accept() catch |err| switch (err) {
            error.WouldBlock => return count,
            else => |other| return other,
        };
        connection.stream.close();
    }
    return count;
}

/// Expects exactly one connection at `listener`. A connect ends on the
/// client before its last ACK reaches the listener's queue, so this waits up
/// to `race_wait_ms` for the first.
fn expectOneConnection(listener: *std.net.Server) !void {
    var polled = [_]std.posix.pollfd{.{
        .fd = listener.stream.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    if (try std.posix.poll(&polled, race_wait_ms) == 0)
        return error.ConnectionNeverArrived;
    try std.testing.expectEqual(@as(usize, 1), try acceptedCount(listener));
}

/// Races real connects over `addresses` as a dial does (`engine/dial.zig`),
/// with the schedule's clock standing still at 0: an attempt that fails to
/// start or ends without connecting hands its turn on, and nothing waits on
/// the attempt delay. Returns the index in `addresses` of the attempt that
/// connected; every socket is closed on return.
fn raceToConnect(addresses: []const std.net.Address) !usize {
    const now_ns: u64 = 0;
    var schedule = connect.Schedule.init(addresses);
    var fds: [connect.max_parallel_attempts]std.posix.fd_t = @splat(-1);
    var targets: [connect.max_parallel_attempts]usize = undefined;
    defer for (fds) |fd| {
        if (fd >= 0) std.posix.close(fd);
    };
    for (0..max_race_rounds) |_| {
        for (0..addresses.len) |_| {
            const launch = schedule.launchDue(now_ns) orelse break;
            const target = try indexOfAddress(addresses, launch.address);
            const started = connect.startAttempt(launch.address) catch |err| {
                std.log.debug("egress connect race attempt {d} did not start: {s}", .{ target, @errorName(err) });
                continue;
            };
            if (started.connected) {
                std.posix.close(started.fd);
                return target;
            }
            fds[launch.slot] = started.fd;
            targets[launch.slot] = target;
            schedule.markPending(launch.slot, now_ns);
        }
        if (schedule.exhausted())
            return error.EveryAttemptFailed;

        var polled: [connect.max_parallel_attempts]std.posix.pollfd = undefined;
        for (&polled, fds) |*entry, fd|
            entry.* = .{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 };
        if (try std.posix.poll(&polled, race_wait_ms) == 0)
            return error.AttemptNeverEnded;
        for (polled, 0..) |entry, slot| {
            if (entry.revents == 0)
                continue;
            connect.finishAttempt(fds[slot]) catch |err| {
                std.log.debug("egress connect race attempt {d} failed: {s}", .{ targets[slot], @errorName(err) });
                std.posix.close(fds[slot]);
                fds[slot] = -1;
                schedule.markDone(slot);
                continue;
            };
            return targets[slot];
        }
    }
    return error.RaceRunaway;
}

fn indexOfAddress(addresses: []const std.net.Address, address: std.net.Address) !usize {
    for (addresses, 0..) |candidate, index| {
        if (candidate.eql(address))
            return index;
    }
    return error.LaunchedAddressNotACandidate;
}

// The first candidate's port is closed. Its refusal ends the attempt, and
// the next candidate starts at once on the same clock instant and connects.
test "egress connect race over real sockets hands a refused attempt's turn on at once" {
    var listener = try loopbackListener();
    defer listener.deinit();
    const addresses = [_]std.net.Address{ try closedLoopbackAddress(), listener.listen_address };

    try std.testing.expectEqual(@as(usize, 1), try raceToConnect(&addresses));
    try expectOneConnection(&listener);
}

// Both candidates listen. The first connects before the attempt delay
// passes, so the second never starts.
test "egress connect race over real sockets starts no second attempt when the first connects within the delay" {
    var first = try loopbackListener();
    defer first.deinit();
    var second = try loopbackListener();
    defer second.deinit();
    const addresses = [_]std.net.Address{ first.listen_address, second.listen_address };

    try std.testing.expectEqual(@as(usize, 0), try raceToConnect(&addresses));
    try expectOneConnection(&first);
    try std.testing.expectEqual(@as(usize, 0), try acceptedCount(&second));
}
