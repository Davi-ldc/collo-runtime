//! Tests for the egress io_uring data driver (client/io/bio_data.zig): BIO
//! TLS connections whose recv and send SQEs the driver owns, and persistent
//! one-shot fd watches that `syncSources` reconciles and `wait` serves one
//! result at a time. They check readiness and deadline delivery, that a
//! retired token never delivers stale readiness, the armed-watch admission
//! cap, bounded and preemptible CQE ingestion, recovery of provided-buffer
//! multishot recv after NOBUFS, and connection cancels on full, failing and
//! dead rings. Each test drives a real ring against Unix socketpairs and
//! unhandshaken `TlsBioTransport`s. A dead ring is simulated by dup2-ing an
//! eventfd over the ring fd, and transient flush failures are injected
//! through `test_flush_failures`. A NOBUFS suspension is read from
//! `provided_multishot_suspensions`, because the drain that ingests it can
//! lift it before the wait returns. When the kernel refuses to create a ring,
//! a test returns without checking anything; tests that need provided-buffer
//! rings skip when the kernel lacks them. How the engine's owner loop uses
//! the driver is tested in all.zig.

const std = @import("std");
const data_io = @import("collo_egress_client").data_io;
const transport = data_io.transport;

fn socketPair() ![2]std.posix.fd_t {
    var fds: [2]i32 = undefined;
    const rc = std.c.socketpair(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
        0,
        &fds,
    );
    switch (std.posix.errno(rc)) {
        .SUCCESS => return .{ fds[0], fds[1] },
        else => |err| return std.posix.unexpectedErrno(err),
    }
}

/// Teardown for a transport the driver has seen. A confirmed cancel leaves
/// the transport with the caller, which deinits it. An unconfirmed cancel
/// quarantines the registration and hands the transport to the driver,
/// which frees it in its final sweep; deiniting it here as well would
/// double-free whenever a transient io_uring_enter EAGAIN hits teardown.
fn cancelAndDeinit(driver: *data_io.Driver, bio: *transport.TlsBioTransport) void {
    if (driver.cancelConnectionForClose(bio))
        bio.deinit();
}

test "egress data io wakes from eventfd without sources" {
    var driver = data_io.Driver.init(std.testing.allocator) catch return;
    defer driver.deinit();
    const wake_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
    defer std.posix.close(wake_fd);

    var one: u64 = 1;
    _ = try std.posix.write(wake_fd, std.mem.asBytes(&one));
    try std.testing.expectEqual(data_io.Result.wake, try driver.wait(&.{}, wake_fd));
}

test "egress data io can force one-shot recv fallback" {
    var driver = data_io.Driver.initWithConfig(std.testing.allocator, .{ .recv_strategy = .one_shot }) catch return;
    defer driver.deinit();

    try std.testing.expect(!driver.usingProvidedMultishot());
    const sandbox_ready = driver.prepareForSandbox() catch |err| switch (err) {
        error.UnsupportedKernel => return error.SkipZigTest,
        else => return err,
    };
    try std.testing.expect(!sandbox_ready);
    try std.testing.expect(!driver.usingProvidedMultishot());
}

test "egress data io exposes provided multishot when kernel supports buffer rings" {
    var driver = data_io.Driver.initWithConfig(std.testing.allocator, .{
        .recv_strategy = .provided_multishot,
        .provided_buffer_count = 2,
        .provided_buffer_size = 1024,
    }) catch return error.SkipZigTest;
    defer driver.deinit();

    try std.testing.expect(try driver.ensureProvidedMultishot());
    try std.testing.expect(driver.usingProvidedMultishot());
}

test "egress data io sends BIO handshake ciphertext" {
    var driver = data_io.Driver.init(std.testing.allocator) catch return;
    defer driver.deinit();

    const fds = try socketPair();
    defer std.posix.close(fds[1]);

    var bio = try transport.TlsBioTransport.createUnhandshaken(
        std.testing.allocator,
        .{ .handle = fds[0] },
        "example.com",
        true,
        .h2_http_1_1,
        64 * 1024,
        null,
    );
    defer cancelAndDeinit(&driver, bio);

    switch (try bio.handshakeStep()) {
        .wait => {},
        .done => return error.ExpectedTlsBioHandshakeReadinessWait,
    }
    const queued = bio.queuedCiphertextLen();
    try std.testing.expect(queued > 0);

    var context: u8 = 0;
    switch (try driver.wait(&.{.{
        .context = &context,
        .connection = bio,
        .deadline_mono_ns = try data_io.deadlineAfterMs(1000),
        .want_read = false,
        .want_write = true,
    }}, null)) {
        .ready => |ready| {
            try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&context)), ready.context);
            try std.testing.expect(ready.writable);
        },
        else => return error.ExpectedEgressDataWritable,
    }

    var scratch: [256]u8 = undefined;
    const read_len = try std.posix.read(fds[1], &scratch);
    try std.testing.expect(read_len > 0);
    try std.testing.expect(read_len <= queued);
}

test "egress data io preserves ciphertext after a partial socket send" {
    var driver = data_io.Driver.init(std.testing.allocator) catch return;
    defer driver.deinit();

    const fds = try socketPair();
    defer std.posix.close(fds[1]);

    var send_buffer_bytes: c_int = 4096;
    try std.posix.setsockopt(
        fds[0],
        std.posix.SOL.SOCKET,
        std.posix.SO.SNDBUF,
        std.mem.asBytes(&send_buffer_bytes),
    );

    var bio = try transport.TlsBioTransport.createUnhandshaken(
        std.testing.allocator,
        .{ .handle = fds[0] },
        "example.com",
        true,
        .h2_http_1_1,
        256 * 1024,
        null,
    );
    defer cancelAndDeinit(&driver, bio);

    const ciphertext = try std.testing.allocator.alloc(u8, 128 * 1024);
    defer std.testing.allocator.free(ciphertext);
    @memset(ciphertext, 0xa5);
    try bio.outgoing_ciphertext.write(ciphertext);
    const before = bio.queuedCiphertextLen();

    var context: u8 = 0;
    switch (try driver.wait(&.{.{
        .context = &context,
        .connection = bio,
        .deadline_mono_ns = try data_io.deadlineAfterMs(1000),
        .want_read = false,
        .want_write = true,
    }}, null)) {
        .ready => |ready| try std.testing.expect(ready.writable),
        else => return error.ExpectedEgressDataWritable,
    }

    const after = bio.queuedCiphertextLen();
    try std.testing.expect(after > 0);
    try std.testing.expect(after < before);
    const wire = bio.takeWireBytes();
    try std.testing.expectEqual(@as(u64, @intCast(before - after)), wire.sent);
    try std.testing.expectEqual(@as(u64, 0), wire.received);
}

test "egress data io keeps one recv and one send in flight per BIO connection" {
    var driver = data_io.Driver.init(std.testing.allocator) catch return;
    defer driver.deinit();

    const fds = try socketPair();
    defer std.posix.close(fds[1]);

    var bio = try transport.TlsBioTransport.createUnhandshaken(
        std.testing.allocator,
        .{ .handle = fds[0] },
        "example.com",
        true,
        .h2_http_1_1,
        64 * 1024,
        null,
    );
    defer cancelAndDeinit(&driver, bio);

    try bio.outgoing_ciphertext.write("hello");
    var context: u8 = 0;
    switch (try driver.wait(&.{.{
        .context = &context,
        .connection = bio,
        .deadline_mono_ns = try data_io.deadlineAfterMs(1000),
        .want_read = true,
        .want_write = true,
    }}, null)) {
        .ready => |ready| {
            try std.testing.expect(ready.writable);
            try std.testing.expect(!bio.send_in_flight);
            try std.testing.expect(bio.recv_in_flight);
        },
        else => return error.ExpectedEgressDataWritable,
    }
}

test "egress data io expires BIO read deadlines" {
    var driver = data_io.Driver.init(std.testing.allocator) catch return;
    defer driver.deinit();

    const fds = try socketPair();
    defer std.posix.close(fds[1]);

    const bio = try transport.TlsBioTransport.createUnhandshaken(
        std.testing.allocator,
        .{ .handle = fds[0] },
        "example.com",
        true,
        .h2_http_1_1,
        64 * 1024,
        null,
    );
    defer cancelAndDeinit(&driver, bio);

    var context: u8 = 0;
    switch (try driver.wait(&.{.{
        .context = &context,
        .connection = bio,
        .deadline_mono_ns = try data_io.monotonicNowNs(),
        .want_read = true,
        .want_write = false,
    }}, null)) {
        .expired => |expired| try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&context)), expired),
        else => return error.ExpectedEgressDataExpired,
    }
}

test "egress data io expires deadline-only sources without arming io" {
    var driver = data_io.Driver.init(std.testing.allocator) catch return;
    defer driver.deinit();

    var context: u8 = 0;
    switch (try driver.wait(&.{.{
        .context = &context,
        .deadline_mono_ns = try data_io.deadlineAfterMs(30),
    }}, null)) {
        .expired => |expired| try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&context)), expired),
        else => return error.ExpectedDeadlineOnlyExpiry,
    }
}

test "egress data io coalesces fd readiness and serves one result per wait" {
    var driver = data_io.Driver.init(std.testing.allocator) catch return;
    defer driver.deinit();

    const pair_a = try socketPair();
    defer std.posix.close(pair_a[0]);
    defer std.posix.close(pair_a[1]);
    const pair_b = try socketPair();
    defer std.posix.close(pair_b[0]);
    defer std.posix.close(pair_b[1]);

    _ = try std.posix.write(pair_a[1], "a");
    _ = try std.posix.write(pair_b[1], "b");

    var context_a: u8 = 0;
    var context_b: u8 = 0;
    const sources = [_]data_io.Source{
        .{
            .context = &context_a,
            .source_id = 51,
            .fd = pair_a[0],
            .deadline_mono_ns = try data_io.deadlineAfterMs(2_000),
        },
        .{
            .context = &context_b,
            .source_id = 52,
            .fd = pair_b[0],
            .deadline_mono_ns = try data_io.deadlineAfterMs(2_000),
        },
    };

    var seen_a: usize = 0;
    var seen_b: usize = 0;
    var round: usize = 0;
    while (round < 2) : (round += 1) {
        // As in the owner, the reconcile runs before the wait, because
        // `wait` never arms fd polls itself.
        try driver.syncSources(&sources);
        switch (try driver.wait(&sources, null)) {
            .ready => |ready| {
                try std.testing.expect(ready.readable);
                if (ready.context == @as(*anyopaque, @ptrCast(&context_a))) {
                    seen_a += 1;
                } else if (ready.context == @as(*anyopaque, @ptrCast(&context_b))) {
                    seen_b += 1;
                } else return error.UnexpectedReadyContext;
            },
            else => return error.ExpectedFdReadiness,
        }
    }
    // Both completions were ingested eagerly, each wait served exactly one
    // coalesced result, and neither source starved the other.
    try std.testing.expectEqual(@as(usize, 1), seen_a);
    try std.testing.expectEqual(@as(usize, 1), seen_b);
}

test "egress data io re-arms persistent polls across interest mask changes" {
    var driver = data_io.Driver.init(std.testing.allocator) catch return;
    defer driver.deinit();

    const pair = try socketPair();
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);

    var context: u8 = 0;
    // Park on read interest with nothing to read; the wait expires while the
    // one-shot poll stays armed across the return.
    const read_sources = [_]data_io.Source{.{
        .context = &context,
        .source_id = 41,
        .fd = pair[0],
        .want_read = true,
        .want_write = false,
        .deadline_mono_ns = try data_io.deadlineAfterMs(50),
    }};
    try driver.syncSources(&read_sources);
    switch (try driver.wait(&read_sources, null)) {
        .expired => {},
        else => return error.ExpectedReadParkExpiry,
    }
    // The same source re-parks wanting write, as a TLS read can want
    // POLLOUT. The sync must cancel the read arm and re-arm for write under a
    // fresh token, and the writable socket completes immediately.
    const write_sources = [_]data_io.Source{.{
        .context = &context,
        .source_id = 41,
        .fd = pair[0],
        .want_read = false,
        .want_write = true,
        .deadline_mono_ns = try data_io.deadlineAfterMs(2_000),
    }};
    try driver.syncSources(&write_sources);
    switch (try driver.wait(&write_sources, null)) {
        .ready => |ready| {
            try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&context)), ready.context);
            try std.testing.expect(ready.writable);
        },
        else => return error.ExpectedWritableAfterMaskChange,
    }
}

test "egress data io drops readiness that races a departed watch" {
    var driver = data_io.Driver.init(std.testing.allocator) catch return;
    defer driver.deinit();

    const pair = try socketPair();
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);

    var context_a: u8 = 0;
    const armed_sources = [_]data_io.Source{.{
        .context = &context_a,
        .source_id = 31,
        .fd = pair[0],
        .deadline_mono_ns = try data_io.deadlineAfterMs(50),
    }};
    try driver.syncSources(&armed_sources);
    switch (try driver.wait(&armed_sources, null)) {
        .expired => {},
        else => return error.ExpectedReadParkExpiry,
    }
    // Readiness arrives while the armed watch is still parked in the kernel.
    _ = try std.posix.write(pair[1], "x");
    // The source departs before the next wait and the reconcile retires its
    // token, so the late CQE must be dropped instead of reaching the
    // departed context.
    var gate_context: u8 = 0;
    const gate_sources = [_]data_io.Source{.{
        .context = &gate_context,
        .deadline_mono_ns = try data_io.deadlineAfterMs(50),
    }};
    try driver.syncSources(&gate_sources);
    switch (try driver.wait(&gate_sources, null)) {
        .expired => |expired| try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&gate_context)), expired),
        else => return error.StaleReadinessDelivered,
    }
    // POLL is level-triggered, so a fresh park on the same fd redelivers the
    // readiness under its own token and the drop lost nothing.
    var context_b: u8 = 0;
    const fresh_sources = [_]data_io.Source{.{
        .context = &context_b,
        .source_id = 32,
        .fd = pair[0],
        .deadline_mono_ns = try data_io.deadlineAfterMs(2_000),
    }};
    try driver.syncSources(&fresh_sources);
    switch (try driver.wait(&fresh_sources, null)) {
        .ready => |ready| {
            try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&context_b)), ready.context);
            try std.testing.expect(ready.readable);
        },
        else => return error.ExpectedFreshReadiness,
    }
}

test "egress data io drops stale fd poll completions after fd reuse" {
    var driver = data_io.Driver.init(std.testing.allocator) catch return;
    defer driver.deinit();

    const pair_first = try socketPair();
    var context_a: u8 = 0;
    const first_sources = [_]data_io.Source{.{
        .context = &context_a,
        .source_id = 21,
        .fd = pair_first[0],
        .deadline_mono_ns = try data_io.deadlineAfterMs(50),
    }};
    try driver.syncSources(&first_sources);
    switch (try driver.wait(&first_sources, null)) {
        .expired => {},
        else => return error.ExpectedReadParkExpiry,
    }
    // Post readiness for the still-armed watch, then close and reopen so the
    // fd number is reused by an unrelated socket.
    _ = try std.posix.write(pair_first[1], "x");
    std.posix.close(pair_first[1]);
    std.posix.close(pair_first[0]);
    const pair_second = try socketPair();
    defer std.posix.close(pair_second[0]);
    defer std.posix.close(pair_second[1]);

    // The new source has the reused fd number and nothing to read. The
    // retired token of the first socket's readiness must not leak into it,
    // so this wait has to expire instead of reporting a phantom readable.
    var context_b: u8 = 0;
    const second_sources = [_]data_io.Source{.{
        .context = &context_b,
        .source_id = 22,
        .fd = pair_second[0],
        .deadline_mono_ns = try data_io.deadlineAfterMs(150),
    }};
    try driver.syncSources(&second_sources);
    switch (try driver.wait(&second_sources, null)) {
        .expired => |expired| try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&context_b)), expired),
        else => return error.StaleFdPollDeliveredAfterReuse,
    }
}

test "egress data io accepts more than 127 mixed sources and chunks SQ submission" {
    var driver = data_io.Driver.init(std.testing.allocator) catch return;
    defer driver.deinit();

    const pair = try socketPair();
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);
    _ = try std.posix.write(pair[1], "x");

    const bio_pair = try socketPair();
    defer std.posix.close(bio_pair[1]);
    var bio = try transport.TlsBioTransport.createUnhandshaken(
        std.testing.allocator,
        .{ .handle = bio_pair[0] },
        "example.com",
        true,
        .h2_http_1_1,
        64 * 1024,
        null,
    );
    defer cancelAndDeinit(&driver, bio);
    switch (try bio.handshakeStep()) {
        .wait => {},
        .done => return error.ExpectedTlsBioHandshakeReadinessWait,
    }
    try std.testing.expect(bio.queuedCiphertextLen() > 0);

    // 300 level-ready fd watches overflow the 256-entry SQ in a single sync,
    // so the submission must go out in chunks; one BIO connection makes the
    // set mixed h1 and h2.
    const fd_source_count = 300;
    var contexts: [fd_source_count]u32 = undefined;
    var bio_context: u8 = 0;
    var sources: [fd_source_count + 1]data_io.Source = undefined;
    const deadline_mono_ns = try data_io.deadlineAfterMs(10_000);
    for (0..fd_source_count) |index| {
        contexts[index] = @intCast(index);
        sources[index] = .{
            .context = &contexts[index],
            .source_id = 1_000 + @as(u64, index),
            .fd = pair[0],
            .deadline_mono_ns = deadline_mono_ns,
        };
    }
    sources[fd_source_count] = .{
        .context = &bio_context,
        .connection = bio,
        .deadline_mono_ns = deadline_mono_ns,
        .want_read = false,
        .want_write = true,
    };

    var round: usize = 0;
    while (round < 8) : (round += 1) {
        try driver.syncSources(&sources);
        switch (try driver.wait(&sources, null)) {
            .ready => {},
            else => return error.ExpectedReadyFromMixedHerd,
        }
    }
}

// A herd of 128 silent h1 watches, armed one-shot polls that never complete,
// shares one driver with a live BIO connection. The h2 side must keep making
// progress round after round, since the parked herd adds no SQE churn, and
// once the herd's stall deadlines pass every one of them must fire.
test "egress data io serves BIO progress under 128 silent armed fd watches" {
    var driver = data_io.Driver.init(std.testing.allocator) catch return;
    defer driver.deinit();

    const silent_pair = try socketPair();
    defer std.posix.close(silent_pair[0]);
    defer std.posix.close(silent_pair[1]);

    const bio_pair = try socketPair();
    defer std.posix.close(bio_pair[1]);
    var bio = try transport.TlsBioTransport.createUnhandshaken(
        std.testing.allocator,
        .{ .handle = bio_pair[0] },
        "example.com",
        true,
        .h2_http_1_1,
        64 * 1024,
        null,
    );
    defer cancelAndDeinit(&driver, bio);
    switch (try bio.handshakeStep()) {
        .wait => {},
        .done => return error.ExpectedTlsBioHandshakeReadinessWait,
    }
    try std.testing.expect(bio.queuedCiphertextLen() > 0);

    const herd_count = 128;
    var herd_contexts: [herd_count]u32 = undefined;
    var bio_context: u8 = 0;
    var sources = std.array_list.Aligned(data_io.Source, null).empty;
    defer sources.deinit(std.testing.allocator);
    const herd_deadline_ns = try data_io.deadlineAfterMs(1_000);
    for (0..herd_count) |index| {
        herd_contexts[index] = @intCast(index);
        try sources.append(std.testing.allocator, .{
            .context = &herd_contexts[index],
            .source_id = 2_000 + @as(u64, index),
            .fd = silent_pair[0],
            .deadline_mono_ns = herd_deadline_ns,
        });
    }
    try sources.append(std.testing.allocator, .{
        .context = &bio_context,
        .connection = bio,
        .deadline_mono_ns = try data_io.deadlineAfterMs(10_000),
        .want_read = false,
        .want_write = true,
    });

    // Several send rounds, each with freshly queued ciphertext that must go
    // writable while all 128 polls stay armed and silent.
    var drain_scratch: [64 * 1024]u8 = undefined;
    var round: usize = 0;
    while (round < 4) : (round += 1) {
        try driver.syncSources(sources.items);
        switch (try driver.wait(sources.items, null)) {
            .ready => |ready| {
                try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&bio_context)), ready.context);
                try std.testing.expect(ready.writable);
            },
            else => return error.ExpectedBioProgressUnderHerd,
        }
        _ = std.posix.read(bio_pair[1], &drain_scratch) catch {};
        try bio.outgoing_ciphertext.write("ping");
    }
    try std.testing.expectEqual(@as(usize, herd_count), driver.liveArmedWatchCount());

    // Every herd source then expires. The test removes each expired source
    // as the owner fails its pending, and the next sync retires the departed
    // arm.
    var expired_count: usize = 0;
    while (expired_count < herd_count) {
        // As in the owner, every removal is reconciled before the next wait.
        try driver.syncSources(sources.items);
        switch (try driver.wait(sources.items, null)) {
            .expired => |context| {
                const index = for (sources.items, 0..) |source, source_index| {
                    if (source.context == context) break source_index;
                } else return error.UnexpectedExpiredContext;
                try std.testing.expect(sources.items[index].connection == null);
                _ = sources.orderedRemove(index);
                expired_count += 1;
            },
            // The BIO source may interleave readiness; drain it and go on.
            .ready => {
                _ = std.posix.read(bio_pair[1], &drain_scratch) catch {};
            },
            else => return error.ExpectedHerdExpiry,
        }
    }
    // The last removal was never reconciled. The trailing sync, which the
    // owner runs before going idle, retires it so no armed poll survives.
    try driver.syncSources(sources.items);
    try std.testing.expectEqual(@as(usize, 0), driver.liveArmedWatchCount());
}

// Serving must not outpace ingestion. While an always-ready h1 backlog is
// served one result per wait, every pass must still drain the CQ so h2
// provided buffers return to their ring, two buffers deep here, at once.
// Otherwise the buffers sit in unread CQEs for the whole backlog window and
// the kernel ends the multishot recv with NOBUFS. The end state cannot show
// that: the drain that ingests the NOBUFS usually lifts the suspension too,
// and a fresh recv delivers the same bytes. So every pass is checked as it
// returns.
test "egress data io releases provided h2 buffers while serving an h1 ready backlog" {
    var driver = data_io.Driver.initWithConfig(std.testing.allocator, .{
        .recv_strategy = .provided_multishot,
        .provided_buffer_count = 2,
        .provided_buffer_size = 1024,
    }) catch return error.SkipZigTest;
    defer driver.deinit();
    const provided = driver.ensureProvidedMultishot() catch return error.SkipZigTest;
    if (!provided) return error.SkipZigTest;

    // Four watches on one readable fd keep a coalesced ready backlog alive
    // across every round: each serve re-arms, and each re-arm completes
    // immediately.
    const h1_pair = try socketPair();
    defer std.posix.close(h1_pair[0]);
    defer std.posix.close(h1_pair[1]);
    _ = try std.posix.write(h1_pair[1], "x");

    const bio_pair = try socketPair();
    defer std.posix.close(bio_pair[1]);
    var bio = try transport.TlsBioTransport.createUnhandshaken(
        std.testing.allocator,
        .{ .handle = bio_pair[0] },
        "example.com",
        true,
        .h2_http_1_1,
        64 * 1024,
        null,
    );
    defer cancelAndDeinit(&driver, bio);
    switch (try bio.handshakeStep()) {
        .wait => {},
        .done => return error.ExpectedTlsBioHandshakeReadinessWait,
    }

    const herd_count = 4;
    var herd_contexts: [herd_count]u32 = undefined;
    var bio_context: u8 = 0;
    var sources: [herd_count + 1]data_io.Source = undefined;
    const deadline_mono_ns = try data_io.deadlineAfterMs(10_000);
    for (0..herd_count) |index| {
        herd_contexts[index] = @intCast(index);
        sources[index] = .{
            .context = &herd_contexts[index],
            .source_id = 61 + @as(u64, index),
            .fd = h1_pair[0],
            .deadline_mono_ns = deadline_mono_ns,
        };
    }
    sources[herd_count] = .{
        .context = &bio_context,
        .connection = bio,
        .deadline_mono_ns = deadline_mono_ns,
        .want_read = true,
        .want_write = false,
    };

    // Arm the herd, flush the handshake hello, build the backlog and arm the
    // multishot recv that must carry every chunk.
    try driver.syncSources(&sources);
    switch (try driver.wait(&sources, null)) {
        .ready => {},
        else => return error.ExpectedPrimedReadiness,
    }
    // The only connection holds registration 0.
    const primed = driver.registrations.items[0];
    try std.testing.expect(primed.recv_queued);
    try std.testing.expect(primed.recv_submission == .provided_multishot);

    // One 1024-byte ciphertext chunk per round against 2 provided buffers.
    // The write returns only after the kernel has posted the chunk's CQE:
    // the recv's task work runs on the thread that submitted it, which is
    // also the writer here, before the write returns to user space. With
    // the backlog still pending, the wait serves without blocking, so only
    // its own pass-start ingestion can take the chunk in. The primed recv
    // can take a third chunk only if earlier buffers went back to the ring;
    // had it ended with NOBUFS, a new recv would carry a new user_data.
    const chunk = [_]u8{0xa5} ** 1024;
    const rounds = 5;
    var received: u64 = 0;
    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        try std.testing.expectEqual(@as(usize, chunk.len), try std.posix.write(bio_pair[1], &chunk));
        try driver.syncSources(&sources);
        try std.testing.expect(driver.fd_ready_count != 0);
        switch (try driver.wait(&sources, null)) {
            .ready => {},
            else => return error.ExpectedReadyUnderBacklog,
        }
        received += bio.takeWireBytes().received;
        try std.testing.expectEqual(@as(u64, (round + 1) * chunk.len), received);
        const registration = driver.registrations.items[0];
        try std.testing.expect(registration.recv_queued);
        try std.testing.expectEqual(primed.recv_user_data, registration.recv_user_data);
        try std.testing.expectEqual(@as(u64, 0), driver.provided_multishot_suspensions);
    }
}

// Admission past the armed-watch cap fails only the source being admitted,
// as a named `.failed` result, while the `max_armed_fd_watches` watches
// already armed stay serviceable. An error from syncSources would instead
// make the owner fail every fetch on the shard.
test "egress data io contains watch admission past the cap to the offending source" {
    var driver = data_io.Driver.init(std.testing.allocator) catch return;
    defer driver.deinit();

    const pair = try socketPair();
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);

    const over_count = data_io.max_armed_fd_watches + 1;
    var contexts = try std.testing.allocator.alloc(u32, over_count);
    defer std.testing.allocator.free(contexts);
    var sources = std.array_list.Aligned(data_io.Source, null).empty;
    defer sources.deinit(std.testing.allocator);
    const deadline_mono_ns = try data_io.deadlineAfterMs(10_000);
    for (0..over_count) |index| {
        contexts[index] = @intCast(index);
        try sources.append(std.testing.allocator, .{
            .context = &contexts[index],
            .source_id = 10_000 + @as(u64, index),
            .fd = pair[0],
            .deadline_mono_ns = deadline_mono_ns,
        });
    }

    // The admission one past the cap fails against its own context only.
    try driver.syncSources(sources.items);
    switch (try driver.wait(sources.items, null)) {
        .failed => |failure| {
            try std.testing.expectEqual(
                @as(*anyopaque, @ptrCast(&contexts[over_count - 1])),
                failure.context,
            );
            try std.testing.expect(failure.err == error.EgressFdWatchLimitExceeded);
        },
        else => return error.ExpectedAdmissionFailure,
    }
    try std.testing.expectEqual(
        @as(usize, data_io.max_armed_fd_watches),
        driver.liveArmedWatchCount(),
    );

    // The admitted herd still delivers readiness after the rejected source
    // departs, as it does once the owner fails that fetch.
    _ = sources.pop();
    _ = try std.posix.write(pair[1], "y");
    try driver.syncSources(sources.items);
    switch (try driver.wait(sources.items, null)) {
        .ready => |ready| try std.testing.expect(ready.readable),
        else => return error.ExpectedHerdAliveAfterContainedFailure,
    }
}

// The armed count includes completed arms whose terminal CQEs are still
// unread in the CQ; the cap check must reap those before rejecting an
// admission, or cancel/re-arm churn inflates the count into spurious
// failures at the cap.
test "egress data io reaps completed arms before rejecting admission at the cap" {
    var driver = data_io.Driver.init(std.testing.allocator) catch return;
    defer driver.deinit();

    const pair_old = try socketPair();
    defer std.posix.close(pair_old[0]);
    defer std.posix.close(pair_old[1]);
    const pair_new = try socketPair();
    defer std.posix.close(pair_new[0]);
    defer std.posix.close(pair_new[1]);

    const watch_count = data_io.max_armed_fd_watches;
    var contexts = try std.testing.allocator.alloc(u32, watch_count);
    defer std.testing.allocator.free(contexts);
    var sources = std.array_list.Aligned(data_io.Source, null).empty;
    defer sources.deinit(std.testing.allocator);
    const deadline_mono_ns = try data_io.deadlineAfterMs(50);
    for (0..watch_count) |index| {
        contexts[index] = @intCast(index);
        try sources.append(std.testing.allocator, .{
            .context = &contexts[index],
            .source_id = 20_000 + @as(u64, index),
            .fd = pair_old[0],
            .deadline_mono_ns = deadline_mono_ns,
        });
    }
    // Fill the cap with armed watches on the silent fd.
    try driver.syncSources(sources.items);
    switch (try driver.wait(sources.items, null)) {
        .expired => {},
        else => return error.ExpectedSilentHerdExpiry,
    }
    try std.testing.expectEqual(@as(usize, watch_count), driver.liveArmedWatchCount());

    // Complete every arm but leave the terminals unread in the CQ, since no
    // wait runs in between. The sleep loop gives the kernel's completion
    // task work time to post them all.
    _ = try std.posix.write(pair_old[1], "z");
    var tries: usize = 0;
    while (driver.ring.cq_ready() < watch_count and tries < 2_000) : (tries += 1)
        std.Thread.sleep(std.time.ns_per_ms);
    // The check is `>=` because control terminals, such as the expired
    // wait's timeout cancel, may share the CQ with the herd's readiness
    // completions.
    try std.testing.expect(driver.ring.cq_ready() >= watch_count);

    // A full replacement set would trip the cap on its first admission if
    // the check trusted the stale count; reaping first must admit all of it
    // without a single contained failure.
    const new_deadline_ns = try data_io.deadlineAfterMs(10_000);
    for (sources.items, 0..) |*source, index| {
        source.* = .{
            .context = &contexts[index],
            .source_id = 30_000 + @as(u64, index),
            .fd = pair_new[0],
            .deadline_mono_ns = new_deadline_ns,
        };
    }
    try driver.syncSources(sources.items);
    try std.testing.expectEqual(@as(usize, watch_count), driver.liveArmedWatchCount());
}

// When the ring itself dies, the owner's teardown after the failed wait
// (failAllOwnerWork) removes every pooled entry and cancels its connection.
// Each cancel must abandon the registration instead of blocking forever on a
// CQE that will never come, or panicking when the drain's enter fails.
test "egress data io abandons teardown drains on a dead ring" {
    var driver = data_io.Driver.init(std.testing.allocator) catch return;
    defer driver.deinit();

    const fds = try socketPair();
    defer std.posix.close(fds[1]);

    var bio = try transport.TlsBioTransport.createUnhandshaken(
        std.testing.allocator,
        .{ .handle = fds[0] },
        "example.com",
        true,
        .h2_http_1_1,
        64 * 1024,
        null,
    );
    // Ownership follows the one cancel verdict below. An unconfirmed cancel
    // (false) quarantines the transport, and the driver frees it in its
    // final sweep. An unwind before the explicit cancel must still cancel
    // exactly once, because a recv parked in the kernel may reference the
    // transport's buffers and the driver requires a cancel before deinit;
    // the defer issues that cancel when no verdict was recorded.
    var cancel_verdict: ?bool = null;
    defer {
        const bio_owned = cancel_verdict orelse driver.cancelConnection(bio);
        if (bio_owned) bio.deinit();
    }

    // Park a recv in flight; the wait expires while the silent socket's
    // one-shot recv stays queued in the kernel.
    var context: u8 = 0;
    switch (try driver.wait(&.{.{
        .context = &context,
        .connection = bio,
        .deadline_mono_ns = try data_io.deadlineAfterMs(50),
        .want_read = true,
        .want_write = false,
    }}, null)) {
        .expired => {},
        else => return error.ExpectedRecvParkExpiry,
    }

    // Kill the ring under the driver: dup2 swaps an eventfd over the ring
    // fd, so every later enter fails at the ring level while the ring memory
    // and the in-flight recv stay alive through its mmaps.
    const fake = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC);
    defer std.posix.close(fake);
    try std.posix.dup2(fake, driver.ring.fd);

    // The wait discovers the dead ring and fails, which in the owner starts
    // the teardown.
    try std.testing.expectError(error.OpcodeNotSupported, driver.wait(&.{.{
        .context = &context,
        .connection = bio,
        .deadline_mono_ns = try data_io.deadlineAfterMs(5_000),
        .want_read = true,
        .want_write = false,
    }}, null));
    // The cancel must return promptly and release the connection, since a
    // dead ring abandons and never quarantines. The verdict is recorded
    // before the assertion so a failure neither cancels twice nor deinits a
    // quarantined transport.
    const cancel_confirmed = driver.cancelConnection(bio);
    cancel_verdict = cancel_confirmed;
    try std.testing.expect(cancel_confirmed);
}

// An expired deadline preempts ingestion. A completion backlog far beyond
// one pass's drain budget must not delay the expiry the caller is owed, and
// the unread CQEs stay in the CQ for the passes that follow, where they
// coalesce per slot.
test "egress data io serves an expired deadline before draining a completion backlog" {
    var driver = data_io.Driver.init(std.testing.allocator) catch return;
    defer driver.deinit();

    const pair = try socketPair();
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);

    const herd_count = 1024;
    var contexts: [herd_count]u32 = undefined;
    var sources = std.array_list.Aligned(data_io.Source, null).empty;
    defer sources.deinit(std.testing.allocator);
    const herd_deadline_ns = try data_io.deadlineAfterMs(10_000);
    for (0..herd_count) |index| {
        contexts[index] = @intCast(index);
        try sources.append(std.testing.allocator, .{
            .context = &contexts[index],
            .source_id = 70_000 + @as(u64, index),
            .fd = pair[0],
            .deadline_mono_ns = herd_deadline_ns,
        });
    }
    try driver.syncSources(sources.items);
    try std.testing.expectEqual(@as(usize, herd_count), driver.liveArmedWatchCount());

    // Complete every arm and leave the CQEs unread, so the next wait faces a
    // backlog far past one ingestion budget.
    _ = try std.posix.write(pair[1], "x");
    var tries: usize = 0;
    while (driver.ring.cq_ready() < herd_count and tries < 2_000) : (tries += 1)
        std.Thread.sleep(std.time.ns_per_ms);
    try std.testing.expect(driver.ring.cq_ready() >= herd_count);

    // An already expired deadline-only source outranks the whole backlog,
    // so the wait must serve the expiry without ingesting a single batch.
    var expired_context: u8 = 0;
    try sources.append(std.testing.allocator, .{
        .context = &expired_context,
        .deadline_mono_ns = try data_io.monotonicNowNs(),
    });
    switch (try driver.wait(sources.items, null)) {
        .expired => |context| try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&expired_context)), context),
        else => return error.ExpectedExpiryOverBacklog,
    }
    try std.testing.expect(driver.ring.cq_ready() >= herd_count);

    // The preemption lost nothing: with the expiry settled, every herd
    // completion is still served, one coalesced result per wait.
    _ = sources.pop();
    var served: usize = 0;
    while (served < herd_count) : (served += 1) {
        switch (try driver.wait(sources.items, null)) {
            .ready => |ready| try std.testing.expect(ready.readable),
            else => return error.ExpectedBacklogReadiness,
        }
    }
}

fn floodWriter(fd: std.posix.fd_t, stop: *std.atomic.Value(bool)) void {
    var chunk: [4096]u8 = undefined;
    @memset(&chunk, 0xa5);
    while (!stop.load(.acquire)) {
        _ = std.posix.send(fd, &chunk, std.os.linux.MSG.DONTWAIT | std.os.linux.MSG.NOSIGNAL) catch |err| switch (err) {
            error.WouldBlock => {
                std.Thread.sleep(200 * std.time.ns_per_us);
                continue;
            },
            else => return,
        };
    }
}

// Under provided-multishot recv a flooding peer keeps the CQ replenishing,
// with F_MORE completions arriving as fast as they are ingested, so a drain
// that ran until the CQ was empty could be captured indefinitely. The
// bounded drain must still let the deadline-only source fire on time.
test "egress data io fires deadlines under a continuous provided-multishot flood" {
    var driver = data_io.Driver.initWithConfig(std.testing.allocator, .{
        .recv_strategy = .provided_multishot,
        .provided_buffer_count = 4,
        .provided_buffer_size = 1024,
    }) catch return error.SkipZigTest;
    defer driver.deinit();
    const provided = driver.ensureProvidedMultishot() catch return error.SkipZigTest;
    if (!provided) return error.SkipZigTest;

    const bio_pair = try socketPair();
    defer std.posix.close(bio_pair[1]);
    var bio = try transport.TlsBioTransport.createUnhandshaken(
        std.testing.allocator,
        .{ .handle = bio_pair[0] },
        "example.com",
        true,
        .h2_http_1_1,
        64 * 1024,
        null,
    );
    defer cancelAndDeinit(&driver, bio);
    switch (try bio.handshakeStep()) {
        .wait => {},
        .done => return error.ExpectedTlsBioHandshakeReadinessWait,
    }

    var deadline_context: u8 = 0;
    var bio_context: u8 = 0;
    const sources = [_]data_io.Source{
        .{
            .context = &bio_context,
            .connection = bio,
            .deadline_mono_ns = try data_io.deadlineAfterMs(10_000),
            .want_read = true,
            .want_write = false,
        },
        .{
            .context = &deadline_context,
            .deadline_mono_ns = try data_io.deadlineAfterMs(150),
        },
    };

    var stop = std.atomic.Value(bool).init(false);
    const writer = try std.Thread.spawn(.{}, floodWriter, .{ bio_pair[1], &stop });

    const start_ns = try data_io.monotonicNowNs();
    var saw_expired = false;
    while ((try data_io.monotonicNowNs()) - start_ns < 5 * std.time.ns_per_s) {
        switch (driver.wait(&sources, null) catch |err| {
            stop.store(true, .release);
            writer.join();
            return err;
        }) {
            .expired => |context| {
                try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&deadline_context)), context);
                saw_expired = true;
                break;
            },
            .ready => {
                // Keep the transport wanting reads so the flood never stalls
                // on a full staging buffer.
                const staged = bio.incoming_ciphertext.size();
                if (staged != 0)
                    try bio.incoming_ciphertext.advance(staged);
            },
            .tick => {},
            else => {
                stop.store(true, .release);
                writer.join();
                return error.UnexpectedFloodWaitResult;
            },
        }
    }
    stop.store(true, .release);
    writer.join();
    try std.testing.expect(saw_expired);
}

// A cancel that meets a full SQ must flush the queued entries and retry, and
// the teardown may block on terminal CQEs only once the kernel confirmably
// owns the cancel; waiting on a cancel the kernel never received would park
// it forever against the silent peer.
test "egress data io cancels a parked connection through a full SQ without hanging" {
    var driver = data_io.Driver.init(std.testing.allocator) catch return;
    defer driver.deinit();

    const fds = try socketPair();
    defer std.posix.close(fds[1]);

    var bio = try transport.TlsBioTransport.createUnhandshaken(
        std.testing.allocator,
        .{ .handle = fds[0] },
        "example.com",
        true,
        .h2_http_1_1,
        64 * 1024,
        null,
    );
    // Ownership follows the one cancel verdict below, as in the dead-ring
    // test: an unconfirmed cancel quarantines the transport to the driver.
    // An unwind before the explicit cancel still cancels exactly once
    // through the defer, because a parked recv references the transport's
    // buffers and an uncancelled registration must never be deinited.
    var cancel_verdict: ?bool = null;
    defer {
        const bio_owned = cancel_verdict orelse driver.cancelConnectionForClose(bio);
        if (bio_owned) bio.deinit();
    }

    // Park a recv in flight against the silent peer.
    var context: u8 = 0;
    switch (try driver.wait(&.{.{
        .context = &context,
        .connection = bio,
        .deadline_mono_ns = try data_io.deadlineAfterMs(50),
        .want_read = true,
        .want_write = false,
    }}, null)) {
        .expired => {},
        else => return error.ExpectedRecvParkExpiry,
    }

    // Fill the SQ with polls on an eventfd that never fires. Their user_data
    // carries no egress tag, so ingestion drops any stray completion.
    const dummy = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC);
    defer std.posix.close(dummy);
    var filled: usize = 0;
    while (true) {
        _ = driver.ring.poll_add(0, dummy, @intCast(std.posix.POLL.IN)) catch break;
        filled += 1;
    }
    try std.testing.expect(filled > 0);

    // The cancel must flush the full SQ, retry, drain its terminals and
    // return promptly; a confirmed cancel hands the connection back to the
    // caller. The verdict is recorded before the assertion so a failure
    // neither cancels twice nor deinits a quarantined transport.
    const cancel_confirmed = driver.cancelConnectionForClose(bio);
    cancel_verdict = cancel_confirmed;
    try std.testing.expect(cancel_confirmed);

    // The driver survives, and a fresh deadline-only wait still serves.
    var gate_context: u8 = 0;
    switch (try driver.wait(&.{.{
        .context = &gate_context,
        .deadline_mono_ns = try data_io.deadlineAfterMs(30),
    }}, null)) {
        .expired => |expired| try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&gate_context)), expired),
        else => return error.ExpectedPostCancelExpiry,
    }
}

// Replacing every watch at the cap in one sync must admit the whole
// replacement set: departures retire before admissions, so a dying arm
// stops counting against the cap when it is retired, not when its terminal
// CQE arrives. A cap's worth of removes and adds goes through the 256-entry
// SQ in chunks, and the flush must submit every SQE (`sq_ready() == 0` on
// return). A real oversubscription must be rejected without allocating a
// slot or map entry for the rejected source.
test "egress data io retires a departing herd before admitting its replacement at the cap" {
    var driver = data_io.Driver.init(std.testing.allocator) catch return;
    defer driver.deinit();

    const pair_old = try socketPair();
    defer std.posix.close(pair_old[0]);
    defer std.posix.close(pair_old[1]);
    const pair_new = try socketPair();
    defer std.posix.close(pair_new[0]);
    defer std.posix.close(pair_new[1]);

    const watch_count = data_io.max_armed_fd_watches;
    var contexts = try std.testing.allocator.alloc(u32, watch_count + 1);
    defer std.testing.allocator.free(contexts);
    var sources = std.array_list.Aligned(data_io.Source, null).empty;
    defer sources.deinit(std.testing.allocator);
    const deadline_mono_ns = try data_io.deadlineAfterMs(10_000);
    for (0..watch_count) |index| {
        contexts[index] = @intCast(index);
        try sources.append(std.testing.allocator, .{
            .context = &contexts[index],
            .source_id = 40_000 + @as(u64, index),
            .fd = pair_old[0],
            .deadline_mono_ns = deadline_mono_ns,
        });
    }
    try driver.syncSources(sources.items);
    try std.testing.expectEqual(@as(usize, watch_count), driver.liveArmedWatchCount());
    try std.testing.expectEqual(@as(u32, 0), driver.ring.sq_ready());

    // Replace every watch with a new identity on a new fd in a single
    // reconcile.
    for (sources.items, 0..) |*source, index| {
        source.* = .{
            .context = &contexts[index],
            .source_id = 50_000 + @as(u64, index),
            .fd = pair_new[0],
            .deadline_mono_ns = deadline_mono_ns,
        };
    }
    try driver.syncSources(sources.items);
    try std.testing.expectEqual(@as(usize, watch_count), driver.liveArmedWatchCount());
    try std.testing.expectEqual(@as(u32, 0), driver.ring.sq_ready());
    try std.testing.expectEqual(@as(usize, watch_count), driver.fd_slots_by_source.count());

    // No rejection was recorded, so a gated wait expires instead of failing;
    // its passes also reap the tombstone terminals.
    var gate_context: u8 = 0;
    try sources.append(std.testing.allocator, .{
        .context = &gate_context,
        .deadline_mono_ns = try data_io.deadlineAfterMs(50),
    });
    switch (try driver.wait(sources.items, null)) {
        .expired => |expired| try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&gate_context)), expired),
        else => return error.ExpectedTurnoverGateExpiry,
    }
    _ = sources.pop();

    // Oversubscribe by one: the rejection is contained and allocates
    // nothing.
    const slots_len_before = driver.fd_slots.items.len;
    contexts[watch_count] = watch_count;
    try sources.append(std.testing.allocator, .{
        .context = &contexts[watch_count],
        .source_id = 60_000,
        .fd = pair_new[0],
        .deadline_mono_ns = deadline_mono_ns,
    });
    try driver.syncSources(sources.items);
    try std.testing.expectEqual(slots_len_before, driver.fd_slots.items.len);
    try std.testing.expectEqual(@as(usize, watch_count), driver.fd_slots_by_source.count());
    try std.testing.expectEqual(@as(usize, watch_count), driver.liveArmedWatchCount());
    switch (try driver.wait(sources.items, null)) {
        .failed => |failure| {
            try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&contexts[watch_count])), failure.context);
            try std.testing.expect(failure.err == error.EgressFdWatchLimitExceeded);
        },
        else => return error.ExpectedOversubscriptionFailure,
    }
}

// An arm whose SQE the kernel never consumed, because the flush failed
// mid-sync, must be rolled back: the table must not claim a watch the kernel
// does not hold, and the count must stay right across repeated failed
// reconciles.
test "egress data io rolls back arms a failed flush never handed the kernel" {
    var driver = data_io.Driver.init(std.testing.allocator) catch return;
    defer driver.deinit();

    const pair = try socketPair();
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);

    var context_a: u8 = 0;
    var context_b: u8 = 0;
    const deadline_mono_ns = try data_io.deadlineAfterMs(10_000);
    const first = [_]data_io.Source{.{
        .context = &context_a,
        .source_id = 81,
        .fd = pair[0],
        .deadline_mono_ns = deadline_mono_ns,
    }};
    try driver.syncSources(&first);
    try std.testing.expectEqual(@as(usize, 1), driver.liveArmedWatchCount());
    try std.testing.expectEqual(@as(u32, 0), driver.ring.sq_ready());

    // Kill the ring under the driver by dup2-ing an eventfd over the ring
    // fd. The next flush fails at the enter, and the freshly queued arm must
    // not survive in the table.
    const fake = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC);
    defer std.posix.close(fake);
    try std.posix.dup2(fake, driver.ring.fd);

    const both = [_]data_io.Source{ first[0], .{
        .context = &context_b,
        .source_id = 82,
        .fd = pair[0],
        .deadline_mono_ns = deadline_mono_ns,
    } };
    try std.testing.expectError(error.OpcodeNotSupported, driver.syncSources(&both));
    try std.testing.expectEqual(@as(usize, 1), driver.liveArmedWatchCount());

    // Repeated reconciles keep failing cleanly, retrying the leftover SQE
    // first, without ever counting the rolled-back arm twice.
    try std.testing.expectError(error.OpcodeNotSupported, driver.syncSources(&both));
    try std.testing.expectEqual(@as(usize, 1), driver.liveArmedWatchCount());
}

// Per-slot epochs wrap. A slot whose epoch sits at maxInt re-arms across the
// wrap, where epoch 0 is a valid arm token, and still delivers readiness
// under the wrapped token.
test "egress data io delivers readiness across a per-slot epoch wrap" {
    var driver = data_io.Driver.init(std.testing.allocator) catch return;
    defer driver.deinit();

    const pair = try socketPair();
    defer std.posix.close(pair[0]);
    defer std.posix.close(pair[1]);

    var context_a: u8 = 0;
    const first = [_]data_io.Source{.{
        .context = &context_a,
        .source_id = 91,
        .fd = pair[0],
        .deadline_mono_ns = try data_io.deadlineAfterMs(10_000),
    }};
    try driver.syncSources(&first);
    const slot_index = driver.fd_slots_by_source.get(91) orelse return error.MissingWatchSlot;

    // Depart the watch and reap its terminal so the slot returns to the
    // free list, keeping its epoch for the next occupant.
    var gate_context: u8 = 0;
    var freed = false;
    var tries: usize = 0;
    while (tries < 100) : (tries += 1) {
        const gate_sources = [_]data_io.Source{.{
            .context = &gate_context,
            .deadline_mono_ns = try data_io.deadlineAfterMs(20),
        }};
        try driver.syncSources(&gate_sources);
        switch (try driver.wait(&gate_sources, null)) {
            .expired => {},
            else => return error.UnexpectedGateResult,
        }
        if (driver.fd_slots.items[slot_index].state == .empty) {
            freed = true;
            break;
        }
    }
    try std.testing.expect(freed);

    // Inject the wrap: the next arm on this slot carries epoch maxInt + 1,
    // which wraps to 0.
    driver.fd_slots.items[slot_index].epoch = std.math.maxInt(u32);

    var context_b: u8 = 0;
    const wrapped = [_]data_io.Source{.{
        .context = &context_b,
        .source_id = 92,
        .fd = pair[0],
        .deadline_mono_ns = try data_io.deadlineAfterMs(2_000),
    }};
    try driver.syncSources(&wrapped);
    const reused = driver.fd_slots_by_source.get(92) orelse return error.MissingWrapSlot;
    try std.testing.expectEqual(slot_index, reused);
    try std.testing.expectEqual(@as(u32, 0), driver.fd_slots.items[slot_index].armed_epoch);

    _ = try std.posix.write(pair[1], "w");
    switch (try driver.wait(&wrapped, null)) {
        .ready => |ready| {
            try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&context_b)), ready.context);
            try std.testing.expect(ready.readable);
        },
        else => return error.ExpectedWrappedEpochReadiness,
    }
}

// A cancel left unconfirmed on a live ring, by transient EAGAIN through
// every flush retry, must not abandon the registration: the kernel still
// owns the original recv SQE, which references the transport's buffers. The
// driver quarantines the registration instead. The connection stays pinned
// and the driver takes ownership of it, the cancel is retried on later wait
// passes, and only after the terminal CQE is consumed, when the kernel no
// longer touches the buffers, are the registration released and the
// transport deinited.
test "egress data io quarantines an unconfirmed cancel on a live ring until terminals arrive" {
    var driver = data_io.Driver.init(std.testing.allocator) catch return;
    defer driver.deinit();

    const fds = try socketPair();
    defer std.posix.close(fds[1]);

    var bio = try transport.TlsBioTransport.createUnhandshaken(
        std.testing.allocator,
        .{ .handle = fds[0] },
        "example.com",
        true,
        .h2_http_1_1,
        64 * 1024,
        null,
    );
    var bio_owned = true;
    defer if (bio_owned) bio.deinit();

    // Park a recv in flight against the silent peer, so the kernel owns a
    // recv SQE that reads into the transport's recv buffer.
    var context: u8 = 0;
    switch (try driver.wait(&.{.{
        .context = &context,
        .connection = bio,
        .deadline_mono_ns = try data_io.deadlineAfterMs(50),
        .want_read = true,
        .want_write = false,
    }}, null)) {
        .expired => {},
        else => return error.ExpectedRecvParkExpiry,
    }
    try std.testing.expect(driver.registrations.items[0].recv_queued);

    // 32 injected EAGAIN-shaped failures outlast the cancel's flush and its
    // 16 bounded retries, so the cancel cannot be confirmed while the ring
    // stays live.
    driver.test_flush_failures = 32;
    try std.testing.expect(!driver.cancelConnection(bio));
    // Ownership transferred to the driver; the caller must not deinit.
    bio_owned = false;

    // Nothing was abandoned: the quarantined registration still tracks the
    // kernel-owned recv and pins the connection.
    const registration = &driver.registrations.items[0];
    try std.testing.expect(registration.quarantined);
    try std.testing.expect(registration.recv_queued);
    try std.testing.expect(registration.connection != null);
    driver.test_flush_failures = 0;

    // Later wait passes retry the cancel, consume the terminal CQE, and
    // release the registration, deiniting the pinned transport.
    var released = false;
    var tries: usize = 0;
    while (tries < 200) : (tries += 1) {
        var gate_context: u8 = 0;
        switch (try driver.wait(&.{.{
            .context = &gate_context,
            .deadline_mono_ns = try data_io.deadlineAfterMs(20),
        }}, null)) {
            .expired, .tick => {},
            else => return error.UnexpectedQuarantineGateResult,
        }
        const slot = &driver.registrations.items[0];
        if (!slot.quarantined and !slot.recv_queued and !slot.send_queued and slot.connection == null) {
            released = true;
            break;
        }
    }
    try std.testing.expect(released);

    // The driver stays healthy after the release.
    var after_context: u8 = 0;
    switch (try driver.wait(&.{.{
        .context = &after_context,
        .deadline_mono_ns = try data_io.deadlineAfterMs(30),
    }}, null)) {
        .expired => |expired| try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&after_context)), expired),
        else => return error.ExpectedPostQuarantineExpiry,
    }
}

// A large fd-watch CQE backlog queued ahead of provided-buffer recv CQEs can
// hold every provided buffer in unread CQEs past the per-pass ingestion
// budget until the kernel reports NOBUFS. The resulting drop to one-shot
// recv must only suspend provided multishot: once a drain observes the CQ
// empty, it is restored instead of the shard paying for one-shot recv
// forever.
test "egress data io recovers provided multishot after a NOBUFS under a readiness-heavy flood" {
    var driver = data_io.Driver.initWithConfig(std.testing.allocator, .{
        .recv_strategy = .provided_multishot,
        .provided_buffer_count = 2,
        .provided_buffer_size = 1024,
    }) catch return error.SkipZigTest;
    defer driver.deinit();
    const provided = driver.ensureProvidedMultishot() catch return error.SkipZigTest;
    if (!provided) return error.SkipZigTest;

    // 600 armed one-shot polls on a level-ready fd all complete at once,
    // parking 600 CQEs ahead of anything the transport posts, more than one
    // 512-CQE ingestion budget.
    const h1_pair = try socketPair();
    defer std.posix.close(h1_pair[0]);
    defer std.posix.close(h1_pair[1]);
    _ = try std.posix.write(h1_pair[1], "x");

    const bio_pair = try socketPair();
    defer std.posix.close(bio_pair[1]);
    var bio = try transport.TlsBioTransport.createUnhandshaken(
        std.testing.allocator,
        .{ .handle = bio_pair[0] },
        "example.com",
        true,
        .h2_http_1_1,
        64 * 1024,
        null,
    );
    defer cancelAndDeinit(&driver, bio);
    switch (try bio.handshakeStep()) {
        .wait => {},
        .done => return error.ExpectedTlsBioHandshakeReadinessWait,
    }

    const herd_count = 600;
    var herd_contexts: [herd_count]u32 = undefined;
    var bio_context: u8 = 0;
    var sources = std.array_list.Aligned(data_io.Source, null).empty;
    defer sources.deinit(std.testing.allocator);
    const deadline_mono_ns = try data_io.deadlineAfterMs(10_000);
    for (0..herd_count) |index| {
        herd_contexts[index] = @intCast(index);
        try sources.append(std.testing.allocator, .{
            .context = &herd_contexts[index],
            .source_id = 80_000 + @as(u64, index),
            .fd = h1_pair[0],
            .deadline_mono_ns = deadline_mono_ns,
        });
    }
    try sources.append(std.testing.allocator, .{
        .context = &bio_context,
        .connection = bio,
        .deadline_mono_ns = deadline_mono_ns,
        .want_read = true,
        .want_write = false,
    });
    try driver.syncSources(sources.items);
    try std.testing.expectEqual(@as(usize, herd_count), driver.liveArmedWatchCount());

    // Prime one pass so the multishot recv is armed while the herd backlog
    // already fills the CQ.
    switch (try driver.wait(sources.items, null)) {
        .ready => {},
        else => return error.ExpectedPrimedFloodReadiness,
    }

    // Three 1024-byte chunks against 2 provided buffers: the kernel consumes
    // both buffers into CQEs nothing has ingested yet and terminates the
    // multishot with NOBUFS for the third.
    const chunk = [_]u8{0xa5} ** 1024;
    for (0..3) |_|
        try std.testing.expectEqual(@as(usize, chunk.len), try std.posix.write(bio_pair[1], &chunk));

    // Keep serving. The passes ingest the herd backlog and the two buffered
    // chunks, which returns both buffers, then the NOBUFS terminal, which
    // suspends multishot. The suspension lifts once a drain observes the CQ
    // empty, often the same drain; until then recv falls back to one-shot.
    // Either way a fresh recv picks up the third chunk.
    var received: u64 = 0;
    var recovered = false;
    var tries: usize = 0;
    while (tries < 5_000) : (tries += 1) {
        try driver.syncSources(sources.items);
        switch (try driver.wait(sources.items, null)) {
            .ready => {},
            .tick => {},
            else => return error.UnexpectedFloodServeResult,
        }
        // Keep the transport hungry so the fallback recv gets re-armed.
        const staged = bio.incoming_ciphertext.size();
        if (staged != 0)
            try bio.incoming_ciphertext.advance(staged);
        received += bio.takeWireBytes().received;
        if (received >= 3 * chunk.len and driver.usingProvidedMultishot()) {
            recovered = true;
            break;
        }
    }
    // Every byte arrived and provided multishot is back. The count is the
    // only proof that it was ever suspended, since the drain that lifted
    // the suspension left no other trace.
    try std.testing.expect(recovered);
    try std.testing.expect(driver.provided_multishot_suspensions != 0);
}

test "egress data io reports socket EOF to BIO transport" {
    var driver = data_io.Driver.init(std.testing.allocator) catch return;
    defer driver.deinit();

    const fds = try socketPair();
    std.posix.close(fds[1]);

    const bio = try transport.TlsBioTransport.createUnhandshaken(
        std.testing.allocator,
        .{ .handle = fds[0] },
        "example.com",
        true,
        .h2_http_1_1,
        64 * 1024,
        null,
    );
    defer cancelAndDeinit(&driver, bio);

    var context: u8 = 0;
    switch (try driver.wait(&.{.{
        .context = &context,
        .connection = bio,
        .deadline_mono_ns = try data_io.deadlineAfterMs(1000),
        .want_read = true,
        .want_write = false,
    }}, null)) {
        .ready => |ready| {
            try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&context)), ready.context);
            try std.testing.expect(ready.readable);
            try std.testing.expect(bio.eof);
        },
        else => return error.ExpectedEgressDataEof,
    }
}
