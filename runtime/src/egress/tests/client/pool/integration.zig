//! HTTP/2 pool tests against real local TLS origins: two requests
//! multiplexed on one pooled entry whose wire the data driver serves, and
//! TLS session resumption scoped to a security cell. Wires are dialed and
//! handshaken through the data driver as the engine's dials do
//! (`support.zig:dialTlsWire`). A test skips when the kernel or its policy
//! offers no restricted io_uring (`initDataDriver`) and fails on any other
//! setup error. How the engine routes fetches to the pool is covered in
//! all.zig.

const std = @import("std");
const network_policy = @import("../network_policy.zig");
const test_support = @import("support.zig");
const pool = test_support.pool;
const data_io = test_support.data_io;
const transport = test_support.transport;
const http2 = test_support.http2;
const TestH2Origin = test_support.TestH2Origin;
const collo_test_h2_origin_start = test_support.collo_test_h2_origin_start;
const collo_test_h2_origin_stop = test_support.collo_test_h2_origin_stop;
const collo_test_h2_origin_last_error = test_support.collo_test_h2_origin_last_error;
const collo_test_h2_origin_stream_count = test_support.collo_test_h2_origin_stream_count;
const collo_test_h2_origin_selected_alpn = test_support.collo_test_h2_origin_selected_alpn;
const test_h2_origin_alpn_h2 = test_support.test_h2_origin_alpn_h2;
const test_alpn_h2 = test_support.test_alpn_h2;
const routableLocalIpv4 = test_support.routableLocalIpv4;

fn expectPending(start_result: pool.StartResult) !pool.StreamHandle {
    return switch (start_result) {
        .pending => |stream| stream,
        .entry_failed => |failed| failed.err,
        .failed => |err| err,
        .needs_connection => error.UnexpectedHttp2ConnectionMiss,
    };
}

test "http2 pool multiplexes two requests on one entry the data driver serves" {
    var origin: ?*TestH2Origin = null;
    var port: u16 = 0;
    if (collo_test_h2_origin_start(test_h2_origin_alpn_h2, &origin, &port) != 0)
        return error.StartLocalH2OriginFailed;
    defer collo_test_h2_origin_stop(origin.?);

    var data_driver = try test_support.initDataDriver();
    defer data_driver.deinit();
    var hpack_scratch = try http2.HpackScratch.init(std.testing.allocator);
    defer hpack_scratch.deinit(std.testing.allocator);
    var client_pool = pool.Pool.init(std.testing.allocator, .{}, &hpack_scratch);
    defer {
        while (client_pool.entries.items.len != 0)
            client_pool.removeEntry(client_pool.entries.items[0], &data_driver);
        client_pool.deinit();
    }

    var host_buffer: [64]u8 = undefined;
    const host = try routableLocalIpv4(&host_buffer);
    const url_one = try std.fmt.allocPrint(std.testing.allocator, "https://{s}:{d}/one", .{ host, port });
    defer std.testing.allocator.free(url_one);
    const url_two = try std.fmt.allocPrint(std.testing.allocator, "https://{s}:{d}/two", .{ host, port });
    defer std.testing.allocator.free(url_two);
    var origins: network_policy.Origins = .{};
    try origins.init(host, &.{port});
    const config = transport.Config{
        .network = origins.policy(),
        .insecure_tls = true,
        .socket_timeout_ms = 5_000,
        .wire_buffer_bytes = test_support.wire_buffer_bytes,
    };
    var plan_one = try transport.prepareRequest(std.testing.allocator, url_one, "GET", &.{}, config);
    defer plan_one.deinit();
    var plan_two = try transport.prepareRequest(std.testing.allocator, url_two, "GET", &.{}, config);
    defer plan_two.deinit();
    try std.testing.expect(plan_one.origin_key.eql(&plan_two.origin_key));

    switch (try client_pool.startRequest(&plan_one, "", config, &data_driver)) {
        .needs_connection => {},
        else => return error.ExpectedHttp2ConnectionMiss,
    }

    const address = try std.net.Address.parseIp(host, port);
    const wire = try test_support.dialTlsWire(&data_driver, address, .{ .server_name = host });
    try std.testing.expectEqual(transport.ApplicationProtocol.h2, wire.protocol);
    const entry = try client_pool.addEntry(&plan_one.origin_key, wire, config, &data_driver);

    const first_stream = try expectPending(try client_pool.startRequest(&plan_one, "", config, &data_driver));
    const second_stream = try expectPending(try client_pool.startRequest(&plan_two, "", config, &data_driver));
    try std.testing.expectEqual(entry, first_stream.entry);
    try std.testing.expectEqual(entry, second_stream.entry);

    var saw_first_head = false;
    var saw_second_head = false;
    var saw_first_end = false;
    var saw_second_end = false;
    var loops: usize = 0;
    while ((!saw_first_end or !saw_second_end) and loops < 256) : (loops += 1) {
        var context: u8 = 0;
        const result = try data_driver.wait(&.{.{
            .context = &context,
            .io = .{ .wire = entry.wire },
            .deadline_mono_ns = try transport.config.deadlineAfterMs(5_000),
            .want_read = true,
            .want_write = entry.wantsOutgoingWrite(),
        }}, null);
        switch (result) {
            .ready => |ready| {
                try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&context)), ready.context);
                if (ready.writable)
                    try entry.flushOutgoing();
                while (true) {
                    var event = client_pool.readEntryEvent(entry) catch |err| switch (err) {
                        error.Http2WouldBlock => break,
                        else => return err,
                    };
                    defer event.deinit();
                    var ended: ?u32 = null;
                    switch (event) {
                        .head => |head| {
                            if (head.stream_id == first_stream.stream_id) {
                                saw_first_head = true;
                            } else if (head.stream_id == second_stream.stream_id) {
                                saw_second_head = true;
                            } else {
                                return error.UnexpectedHttp2Stream;
                            }
                        },
                        .progress => |progress| {
                            if (progress.stream_id != first_stream.stream_id and progress.stream_id != second_stream.stream_id)
                                return error.UnexpectedHttp2Stream;
                        },
                        .body_chunk => |body| {
                            if (body.stream_id != first_stream.stream_id and body.stream_id != second_stream.stream_id)
                                return error.UnexpectedHttp2Stream;
                            // The consumer takes every chunk at once; the ack
                            // surfaces a deferred end.
                            var maybe_end = try client_pool.ackReceivedData(entry, body.stream_id, body.flow_credit, body.update_stream_window);
                            if (maybe_end) |*end_event| {
                                defer end_event.deinit();
                                switch (end_event.*) {
                                    .end => |end| ended = end.stream_id,
                                    else => return error.UnexpectedHttp2Event,
                                }
                            }
                        },
                        .end => |end| ended = end.stream_id,
                        .failure => |failure| return failure.err,
                    }
                    if (ended) |stream_id| {
                        if (stream_id == first_stream.stream_id) {
                            saw_first_end = true;
                        } else if (stream_id == second_stream.stream_id) {
                            saw_second_end = true;
                        } else {
                            return error.UnexpectedHttp2Stream;
                        }
                    }
                }
            },
            .failed => |failure| return failure.err,
            .expired => return error.Http2PoolIntegrationTimeout,
            .wake, .tick => {},
        }
    }

    if (!saw_first_head or !saw_second_head or !saw_first_end or !saw_second_end) {
        std.debug.print("local h2 origin error: {s}\n", .{std.mem.span(collo_test_h2_origin_last_error(origin.?))});
        return error.Http2PoolIntegrationIncomplete;
    }
    try std.testing.expectEqual(test_alpn_h2, collo_test_h2_origin_selected_alpn(origin.?));
    try std.testing.expectEqual(@as(u32, 2), collo_test_h2_origin_stream_count(origin.?));
}

test "tls session resumption resumes within a security cell and never across" {
    const egress_tls = @import("collo_egress_client").tls;

    var origin: ?*test_support.TestTlsResumptionOrigin = null;
    var port: u16 = 0;
    if (test_support.collo_test_tls_resumption_origin_start(3, &origin, &port) != 0)
        return error.StartLocalTlsResumptionOriginFailed;
    defer test_support.collo_test_tls_resumption_origin_stop(origin.?);

    var data_driver = try test_support.initDataDriver();
    defer data_driver.deinit();

    var host_buffer: [64]u8 = undefined;
    const host = try routableLocalIpv4(&host_buffer);
    const address = try std.net.Address.parseIp(host, port);

    const cell_a: [16]u8 = [_]u8{1} ** 16;
    const cell_b: [16]u8 = [_]u8{2} ** 16;

    const Connect = struct {
        fn once(
            driver: *data_io.Driver,
            addr: std.net.Address,
            server_name: []const u8,
            cell: [16]u8,
            origin_port: u16,
        ) !bool {
            var key_buffer: [egress_tls.max_session_key_bytes]u8 = undefined;
            const session_key = egress_tls.buildSessionKey(&key_buffer, cell, cell, server_name, origin_port);
            const wire = try test_support.dialTlsWire(driver, addr, .{
                .server_name = server_name,
                .session_key = session_key,
                .offer_h2 = false,
            });
            defer test_support.releaseWire(driver, wire);
            // The origin writes one byte after the handshake. Reading it
            // guarantees that the NewSessionTicket messages before it were
            // processed and the session cache insert ran.
            var ready: [1]u8 = undefined;
            var steps: usize = 0;
            while (steps < 64) : (steps += 1) {
                switch (try wire.readStep(&ready)) {
                    .ready => |len| {
                        try std.testing.expectEqual(@as(usize, 1), len);
                        try std.testing.expectEqual(@as(u8, 'r'), ready[0]);
                        return wire.sessionReused();
                    },
                    .wait => |interest| try test_support.waitWire(driver, wire, interest),
                    .eof => return error.TlsResumptionOriginReadFailed,
                }
            }
            return error.TlsResumptionOriginReadStalled;
        }
    };

    try std.testing.expect(!try Connect.once(&data_driver, address, host, cell_a, port));
    try std.testing.expect(try Connect.once(&data_driver, address, host, cell_a, port));
    // A different security cell must not resume from cell A's tickets.
    try std.testing.expect(!try Connect.once(&data_driver, address, host, cell_b, port));

    test_support.collo_test_tls_resumption_origin_join(origin.?);
    const origin_error = std.mem.span(test_support.collo_test_tls_resumption_origin_last_error(origin.?));
    if (origin_error.len != 0) {
        std.debug.print("local tls resumption origin error: {s}\n", .{origin_error});
        return error.TlsResumptionOriginFailed;
    }
    try std.testing.expectEqual(@as(u32, 3), test_support.collo_test_tls_resumption_origin_handshakes(origin.?));
    try std.testing.expectEqual(@as(u32, 1), test_support.collo_test_tls_resumption_origin_resumed_count(origin.?));
}
