//! HTTP/2 pool tests against real local TLS origins: two requests multiplexed
//! on one memory-BIO TLS connection, wire and billed byte accounting, the
//! HTTP/1 connection returned when ALPN settles on http/1.1, and TLS session
//! resumption scoped to a security cell. A test that needs the io_uring data
//! driver returns early when the kernel refuses a ring.

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

fn writeHttp1FallbackRequest(wire: *transport.HttpConnection, request: []const u8) !void {
    var sent: usize = 0;
    var spins: usize = 0;
    while (sent < request.len) : (spins += 1) {
        if (spins > 512)
            return error.Http1FallbackWriteTimeout;
        switch (try wire.writeStep(request[sent..])) {
            .ready => |amount| {
                if (amount == 0)
                    return error.Http1FallbackWriteStalled;
                sent += amount;
                try wire.flush();
            },
            .wait => |interest| {
                if (interest == .write)
                    try wire.flush();
                std.Thread.sleep(std.time.ns_per_ms);
            },
            .eof => return error.Http1FallbackWriteEof,
        }
    }
    try wire.flush();
}

fn readHttp1FallbackResponse(wire: *transport.HttpConnection, buffer: []u8) ![]const u8 {
    var filled: usize = 0;
    var spins: usize = 0;
    while (spins < 2048) : (spins += 1) {
        if (filled == buffer.len)
            return error.Http1FallbackResponseTooLarge;
        switch (try wire.readStep(buffer[filled..])) {
            .ready => |amount| {
                if (amount == 0)
                    return error.Http1FallbackReadStalled;
                filled += amount;
                if (std.mem.indexOf(u8, buffer[0..filled], "\r\n\r\n")) |body_offset| {
                    const body = buffer[body_offset + 4 .. filled];
                    if (std.mem.eql(u8, body, "fallback"))
                        return buffer[0..filled];
                }
            },
            .wait => |interest| {
                if (interest == .write)
                    try wire.flush();
                std.Thread.sleep(std.time.ns_per_ms);
            },
            .eof => break,
        }
    }
    return error.Http1FallbackReadTimeout;
}

test "http2 pool multiplexes two requests through BIO TLS data path" {
    var origin: ?*TestH2Origin = null;
    var port: u16 = 0;
    if (collo_test_h2_origin_start(test_h2_origin_alpn_h2, &origin, &port) != 0)
        return error.StartLocalH2OriginFailed;
    defer collo_test_h2_origin_stop(origin.?);

    var client_pool = pool.Pool.init(std.testing.allocator, .{});
    defer client_pool.deinit();
    var readiness_driver = readiness.Driver.init(std.testing.allocator);
    defer readiness_driver.deinit();
    var data_driver = data_io.Driver.init(std.testing.allocator) catch return;
    defer data_driver.deinit();

    var host_buffer: [64]u8 = undefined;
    const host = try routableLocalIpv4(&host_buffer);
    const url_one = try std.fmt.allocPrint(std.testing.allocator, "https://{s}:{d}/one", .{ host, port });
    defer std.testing.allocator.free(url_one);
    const url_two = try std.fmt.allocPrint(std.testing.allocator, "https://{s}:{d}/two", .{ host, port });
    defer std.testing.allocator.free(url_two);
    const config = transport.Config{
        .allow_private_networks = true,
        .insecure_tls = true,
        .socket_timeout_ms = 5_000,
        .tls_ciphertext_buffer_bytes = 256 * 1024,
    };
    const first_request = pool.BatchRequest{
        .allocator = std.testing.allocator,
        .url = url_one,
        .method = "GET",
        .body = "",
        .headers = &.{},
        .config = config,
    };
    const second_request = pool.BatchRequest{
        .allocator = std.testing.allocator,
        .url = url_two,
        .method = "GET",
        .body = "",
        .headers = &.{},
        .config = config,
    };

    switch (try client_pool.startRequest(first_request)) {
        .needs_connection => {},
        else => return error.ExpectedHttp2ConnectionMiss,
    }

    var plan = try transport.prepareRequest(
        std.testing.allocator,
        first_request.url,
        first_request.method,
        first_request.headers,
        first_request.config,
    );
    defer plan.deinit();
    var dns_cache = transport.DnsCache.init(std.testing.allocator, .{});
    defer dns_cache.deinit();
    var wire = switch (try pool.Entry.connectBio(std.testing.allocator, &plan, first_request.config, &dns_cache, &readiness_driver, &data_driver)) {
        .h2 => |connected| connected,
        .h1 => |connected| {
            var rejected = connected;
            rejected.deinit();
            return error.ExpectedHttp2Negotiation;
        },
    };
    var wire_owned = true;
    errdefer if (wire_owned)
        wire.deinit();

    const first_start = try client_pool.adoptConnection(first_request, wire);
    const first_stream = switch (first_start) {
        .pending => |stream| blk: {
            wire_owned = false;
            break :blk stream;
        },
        .entry_failed => |failed| return failed.err,
        .failed => |err| return err,
        .needs_connection => return error.UnexpectedSecondHttp2ConnectionMiss,
    };
    const second_start = try client_pool.startRequest(second_request);
    const second_stream = switch (second_start) {
        .pending => |stream| stream,
        .entry_failed => |failed| return failed.err,
        .failed => |err| return err,
        .needs_connection => return error.UnexpectedSecondHttp2ConnectionMiss,
    };
    try std.testing.expectEqual(first_stream.entry, second_stream.entry);

    var saw_first_head = false;
    var saw_second_head = false;
    var saw_first_end = false;
    var saw_second_end = false;
    var reported_ciphertext_bytes: u64 = 0;
    var loops: usize = 0;
    while ((!saw_first_end or !saw_second_end) and loops < 256) : (loops += 1) {
        var context: u8 = 0;
        const bio = first_stream.entry.bioTls() orelse return error.ExpectedBioTlsEntry;
        const result = try data_driver.wait(&.{.{
            .context = &context,
            .connection = bio,
            .deadline_mono_ns = try data_io.deadlineAfterMs(5_000),
            .want_read = true,
            .want_write = first_stream.entry.wantsOutgoingWrite() or bio.hasCiphertextToSend(),
        }}, null);
        switch (result) {
            .ready => |ready| {
                try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&context)), ready.context);
                if (ready.writable)
                    try first_stream.entry.flushOutgoing();
                while (true) {
                    var event = client_pool.readEntryEvent(first_stream.entry) catch |err| switch (err) {
                        error.Http2WouldBlock => break,
                        else => return err,
                    };
                    defer event.deinit();
                    switch (event) {
                        .head => |head| {
                            if (head.stream_id == first_stream.stream_id) {
                                saw_first_head = true;
                            } else if (head.stream_id == second_stream.stream_id) {
                                saw_second_head = true;
                            } else {
                                return error.UnexpectedHttp2StreamCompletion;
                            }
                            reported_ciphertext_bytes += head.result.wire_bytes.total();
                        },
                        .progress => |progress| {
                            if (progress.stream_id != first_stream.stream_id and progress.stream_id != second_stream.stream_id)
                                return error.UnexpectedHttp2StreamCompletion;
                            reported_ciphertext_bytes += progress.wire_bytes.total();
                        },
                        .body_chunk => |body| {
                            if (body.stream_id != first_stream.stream_id and body.stream_id != second_stream.stream_id)
                                return error.UnexpectedHttp2StreamCompletion;
                            reported_ciphertext_bytes += body.wire_bytes.total();
                            var maybe_end = try client_pool.ackReceivedData(first_stream.entry, body.stream_id, body.flow_credit, body.update_stream_window);
                            if (maybe_end) |*end_event| {
                                defer end_event.deinit();
                                switch (end_event.*) {
                                    .end => |end| {
                                        if (end.stream_id == first_stream.stream_id) {
                                            saw_first_end = true;
                                        } else if (end.stream_id == second_stream.stream_id) {
                                            saw_second_end = true;
                                        } else {
                                            return error.UnexpectedHttp2StreamCompletion;
                                        }
                                        reported_ciphertext_bytes += end.wire_bytes.total();
                                    },
                                    else => return error.UnexpectedHttp2StreamCompletion,
                                }
                            }
                        },
                        .end => |end| {
                            if (end.stream_id == first_stream.stream_id) {
                                saw_first_end = true;
                            } else if (end.stream_id == second_stream.stream_id) {
                                saw_second_end = true;
                            } else {
                                return error.UnexpectedHttp2StreamCompletion;
                            }
                            reported_ciphertext_bytes += end.wire_bytes.total();
                        },
                        .failure => |failure| return failure.err,
                    }
                }
            },
            .failed => |failure| return failure.err,
            .expired => return error.Http2BioIntegrationTimeout,
            .wake, .tick => {},
        }
    }

    if (!saw_first_head or !saw_second_head or !saw_first_end or !saw_second_end) {
        std.debug.print("local h2 origin error: {s}\n", .{std.mem.span(collo_test_h2_origin_last_error(origin.?))});
        return error.Http2BioIntegrationIncomplete;
    }
    try std.testing.expect(reported_ciphertext_bytes > 0);
    try std.testing.expectEqual(test_alpn_h2, collo_test_h2_origin_selected_alpn(origin.?));
    try std.testing.expectEqual(@as(u32, 2), collo_test_h2_origin_stream_count(origin.?));
}

test "h2 egress accounting conserves BIO ciphertext (no plaintext double-count)" {
    // The wire bytes the events carry must sum to the ciphertext deltas and
    // nothing else. The codec fills terminal events with its cumulative
    // per-stream plaintext count, and the pool must overwrite it even when
    // the ciphertext delta is zero; a leak bills ciphertext plus plaintext,
    // about twice the body. A known 64 KiB response separates the two cases:
    // a correct count is 64 KiB plus handshake and record overhead (under
    // 32 KiB of slack), a double count is at least 128 KiB.
    const response_body_bytes: usize = 64 * 1024;
    var origin: ?*TestH2Origin = null;
    var port: u16 = 0;
    // The first stream has an empty body, the shape that reliably yields a
    // deferred `.end` with a zero ciphertext delta; the second serves 64 KiB.
    if (test_support.collo_bench_h2_origin_start(2, response_body_bytes, &origin, &port) != 0)
        return error.StartLocalH2OriginFailed;
    defer collo_test_h2_origin_stop(origin.?);

    var client_pool = pool.Pool.init(std.testing.allocator, .{});
    defer client_pool.deinit();
    var readiness_driver = readiness.Driver.init(std.testing.allocator);
    defer readiness_driver.deinit();
    var data_driver = data_io.Driver.init(std.testing.allocator) catch return;
    defer data_driver.deinit();

    var host_buffer: [64]u8 = undefined;
    const host = try routableLocalIpv4(&host_buffer);
    const url_prime = try std.fmt.allocPrint(std.testing.allocator, "https://{s}:{d}/prime", .{ host, port });
    defer std.testing.allocator.free(url_prime);
    const url_body = try std.fmt.allocPrint(std.testing.allocator, "https://{s}:{d}/body", .{ host, port });
    defer std.testing.allocator.free(url_body);
    const config = transport.Config{
        .allow_private_networks = true,
        .insecure_tls = true,
        .socket_timeout_ms = 5_000,
        .tls_ciphertext_buffer_bytes = 256 * 1024,
    };
    const prime_request = pool.BatchRequest{
        .allocator = std.testing.allocator,
        .url = url_prime,
        .method = "GET",
        .body = "",
        .headers = &.{},
        .config = config,
    };
    const body_request = pool.BatchRequest{
        .allocator = std.testing.allocator,
        .url = url_body,
        .method = "GET",
        .body = "",
        .headers = &.{},
        .config = config,
    };

    switch (try client_pool.startRequest(prime_request)) {
        .needs_connection => {},
        else => return error.ExpectedHttp2ConnectionMiss,
    }
    var plan = try transport.prepareRequest(
        std.testing.allocator,
        prime_request.url,
        prime_request.method,
        prime_request.headers,
        prime_request.config,
    );
    defer plan.deinit();
    var dns_cache = transport.DnsCache.init(std.testing.allocator, .{});
    defer dns_cache.deinit();
    var wire = switch (try pool.Entry.connectBio(std.testing.allocator, &plan, prime_request.config, &dns_cache, &readiness_driver, &data_driver)) {
        .h2 => |connected| connected,
        .h1 => |connected| {
            var rejected = connected;
            rejected.deinit();
            return error.ExpectedHttp2Negotiation;
        },
    };
    var wire_owned = true;
    errdefer if (wire_owned)
        wire.deinit();

    const prime_stream = switch (try client_pool.adoptConnection(prime_request, wire)) {
        .pending => |stream| blk: {
            wire_owned = false;
            break :blk stream;
        },
        .entry_failed => |failed| return failed.err,
        .failed => |err| return err,
        .needs_connection => return error.UnexpectedSecondHttp2ConnectionMiss,
    };
    const body_stream = switch (try client_pool.startRequest(body_request)) {
        .pending => |stream| stream,
        .entry_failed => |failed| return failed.err,
        .failed => |err| return err,
        .needs_connection => return error.UnexpectedSecondHttp2ConnectionMiss,
    };
    try std.testing.expectEqual(prime_stream.entry, body_stream.entry);

    var prime_ended = false;
    var body_ended = false;
    var body_bytes_received: usize = 0;
    var reported_ciphertext_bytes: u64 = 0;
    // The billed meter per stream: the final head block length from the head
    // event and the cumulative billed counters from the terminal `.end`.
    var prime_head_billed: u64 = 0;
    var body_head_billed: u64 = 0;
    var prime_billed_sent: u64 = 0;
    var prime_billed_received: u64 = 0;
    var body_billed_sent: u64 = 0;
    var body_billed_received: u64 = 0;
    var loops: usize = 0;
    while ((!prime_ended or !body_ended) and loops < 1024) : (loops += 1) {
        var context: u8 = 0;
        const bio = prime_stream.entry.bioTls() orelse return error.ExpectedBioTlsEntry;
        const result = try data_driver.wait(&.{.{
            .context = &context,
            .connection = bio,
            .deadline_mono_ns = try data_io.deadlineAfterMs(5_000),
            .want_read = true,
            .want_write = prime_stream.entry.wantsOutgoingWrite() or bio.hasCiphertextToSend(),
        }}, null);
        switch (result) {
            .ready => |ready| {
                try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&context)), ready.context);
                if (ready.writable)
                    try prime_stream.entry.flushOutgoing();
                while (true) {
                    var event = client_pool.readEntryEvent(prime_stream.entry) catch |err| switch (err) {
                        error.Http2WouldBlock => break,
                        else => return err,
                    };
                    defer event.deinit();
                    switch (event) {
                        .head => |head| {
                            reported_ciphertext_bytes += head.result.wire_bytes.total();
                            if (head.stream_id == prime_stream.stream_id) {
                                prime_head_billed = head.billed_head_bytes;
                            } else if (head.stream_id == body_stream.stream_id) {
                                body_head_billed = head.billed_head_bytes;
                            }
                        },
                        .progress => |progress| {
                            reported_ciphertext_bytes += progress.wire_bytes.total();
                        },
                        .body_chunk => |body| {
                            reported_ciphertext_bytes += body.wire_bytes.total();
                            if (body.stream_id == body_stream.stream_id)
                                body_bytes_received += body.bytes.len;
                            var maybe_end = try client_pool.ackReceivedData(prime_stream.entry, body.stream_id, body.flow_credit, body.update_stream_window);
                            if (maybe_end) |*end_event| {
                                defer end_event.deinit();
                                switch (end_event.*) {
                                    .end => |end| {
                                        reported_ciphertext_bytes += end.wire_bytes.total();
                                        if (end.stream_id == prime_stream.stream_id) {
                                            prime_ended = true;
                                            prime_billed_sent = end.billed_bytes.sent;
                                            prime_billed_received = end.billed_bytes.received;
                                        } else if (end.stream_id == body_stream.stream_id) {
                                            body_ended = true;
                                            body_billed_sent = end.billed_bytes.sent;
                                            body_billed_received = end.billed_bytes.received;
                                        } else {
                                            return error.UnexpectedHttp2StreamCompletion;
                                        }
                                    },
                                    else => return error.UnexpectedHttp2StreamCompletion,
                                }
                            }
                        },
                        .end => |end| {
                            reported_ciphertext_bytes += end.wire_bytes.total();
                            if (end.stream_id == prime_stream.stream_id) {
                                prime_ended = true;
                                prime_billed_sent = end.billed_bytes.sent;
                                prime_billed_received = end.billed_bytes.received;
                            } else if (end.stream_id == body_stream.stream_id) {
                                body_ended = true;
                                body_billed_sent = end.billed_bytes.sent;
                                body_billed_received = end.billed_bytes.received;
                            } else {
                                return error.UnexpectedHttp2StreamCompletion;
                            }
                        },
                        .failure => |failure| return failure.err,
                    }
                }
            },
            .failed => |failure| return failure.err,
            .expired => return error.Http2BioIntegrationTimeout,
            .wake, .tick => {},
        }
    }

    if (!prime_ended or !body_ended) {
        std.debug.print("local h2 origin error: {s}\n", .{std.mem.span(collo_test_h2_origin_last_error(origin.?))});
        return error.Http2BioIntegrationIncomplete;
    }
    try std.testing.expectEqual(response_body_bytes, body_bytes_received);
    // Floor: the cost includes the 64 KiB body's ciphertext.
    try std.testing.expect(reported_ciphertext_bytes >= response_body_bytes);
    // Ceiling: handshake, TLS record and frame overhead fit well inside
    // 32 KiB of slack, while a plaintext double count starts near twice the
    // body.
    try std.testing.expect(reported_ciphertext_bytes <= response_body_bytes + 32 * 1024);

    // The body stream's billed received bytes are exact: the 64 KiB of DATA
    // payload plus the final head block, without frame headers, window
    // updates or TLS.
    try std.testing.expect(body_head_billed > 0);
    try std.testing.expectEqual(
        @as(u64, response_body_bytes) + body_head_billed,
        body_billed_received,
    );
    // The empty-body primer bills exactly its head block.
    try std.testing.expect(prime_head_billed > 0);
    try std.testing.expectEqual(prime_head_billed, prime_billed_received);
    // Request header blocks were transmitted for both streams.
    try std.testing.expect(prime_billed_sent > 0);
    try std.testing.expect(body_billed_sent > 0);
    // Summed over every stream on the connection, billed bytes (the HTTP
    // payload) never exceed the cost (the ciphertext).
    const billed_total = prime_billed_sent + prime_billed_received +
        body_billed_sent + body_billed_received;
    try std.testing.expect(billed_total <= reported_ciphertext_bytes);
    try std.testing.expectEqual(@as(u32, 2), collo_test_h2_origin_stream_count(origin.?));
}

test "http2 BIO connect reports HTTP/1 ALPN for fallback" {
    var origin: ?*TestH2Origin = null;
    var port: u16 = 0;
    if (collo_test_h2_origin_start(test_h2_origin_alpn_http11, &origin, &port) != 0)
        return error.StartLocalH2OriginFailed;
    defer collo_test_h2_origin_stop(origin.?);

    var readiness_driver = readiness.Driver.init(std.testing.allocator);
    defer readiness_driver.deinit();
    var data_driver = data_io.Driver.init(std.testing.allocator) catch return;
    defer data_driver.deinit();

    var host_buffer: [64]u8 = undefined;
    const host = try routableLocalIpv4(&host_buffer);
    const url = try std.fmt.allocPrint(std.testing.allocator, "https://{s}:{d}/fallback", .{ host, port });
    defer std.testing.allocator.free(url);
    const config = transport.Config{
        .allow_private_networks = true,
        .insecure_tls = true,
        .socket_timeout_ms = 5_000,
        .tls_ciphertext_buffer_bytes = 256 * 1024,
    };
    var plan = try transport.prepareRequest(std.testing.allocator, url, "GET", &.{}, config);
    defer plan.deinit();
    var dns_cache = transport.DnsCache.init(std.testing.allocator, .{});
    defer dns_cache.deinit();

    switch (try pool.Entry.connectBio(std.testing.allocator, &plan, config, &dns_cache, &readiness_driver, &data_driver)) {
        .h2 => |connected| {
            var rejected = connected;
            rejected.deinit();
            return error.ExpectedHttp1Negotiation;
        },
        .h1 => |connected| {
            // The finished handshake comes back as an HTTP/1 connection the
            // caller drives itself, ready for the shared HTTP/1 pool.
            var wire = connected;
            defer wire.deinit();
            try std.testing.expectEqual(transport.ApplicationProtocol.http_1_1, wire.applicationProtocol());
            try std.testing.expect(wire.fd() >= 0);

            const request =
                "GET /fallback HTTP/1.1\r\n" ++
                "host: fallback.example.test\r\n" ++
                "connection: close\r\n" ++
                "\r\n";
            try writeHttp1FallbackRequest(&wire, request);

            var response_buffer: [512]u8 = undefined;
            const response = try readHttp1FallbackResponse(&wire, &response_buffer);
            try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK\r\n"));
            try std.testing.expect(std.mem.indexOf(u8, response, "\r\ncontent-length: 8\r\n") != null);
            const body_offset = (std.mem.indexOf(u8, response, "\r\n\r\n") orelse return error.Http1FallbackMissingBody) + 4;
            try std.testing.expectEqualStrings("fallback", response[body_offset..]);
            try std.testing.expectEqual(@as(u32, 1), collo_test_h2_origin_stream_count(origin.?));
        },
    }
}

test "tls session resumption resumes within a security cell and never across" {
    const egress_tls = @import("collo_egress_client").tls;

    var origin: ?*test_support.TestTlsResumptionOrigin = null;
    var port: u16 = 0;
    if (test_support.collo_test_tls_resumption_origin_start(4, &origin, &port) != 0)
        return error.StartLocalTlsResumptionOriginFailed;
    defer test_support.collo_test_tls_resumption_origin_stop(origin.?);

    var host_buffer: [64]u8 = undefined;
    const host = try routableLocalIpv4(&host_buffer);
    const address = try std.net.Address.parseIp(host, port);

    const cell_a: [16]u8 = [_]u8{1} ** 16;
    const cell_b: [16]u8 = [_]u8{2} ** 16;

    const Connect = struct {
        fn once(
            addr: std.net.Address,
            server_name: []const u8,
            cell: [16]u8,
            origin_port: u16,
            offer: egress_tls.AlpnOffer,
        ) !bool {
            var key_buffer: [egress_tls.max_session_key_bytes]u8 = undefined;
            const session_key = egress_tls.buildSessionKey(
                &key_buffer,
                cell,
                cell,
                offer,
                server_name,
                origin_port,
            );
            const stream = try std.net.tcpConnectToAddress(addr);
            const connection = try egress_tls.Connection.create(
                std.testing.allocator,
                stream,
                server_name,
                true,
                offer,
                session_key,
            );
            defer connection.deinit();
            // The origin writes one byte after the handshake. Reading it
            // guarantees that the NewSessionTicket messages before it were
            // processed and the session cache insert ran.
            var ready: [1]u8 = undefined;
            switch (try connection.readStep(&ready)) {
                .ready => |len| try std.testing.expectEqual(@as(usize, 1), len),
                else => return error.TlsResumptionOriginReadFailed,
            }
            try std.testing.expectEqual(@as(u8, 'r'), ready[0]);
            return connection.sessionReused();
        }
    };

    try std.testing.expect(!try Connect.once(address, host, cell_a, port, .http_1_1));
    try std.testing.expect(try Connect.once(address, host, cell_a, port, .http_1_1));
    // The ALPN offer is part of the cache key: an h2-capable offer must not
    // pick up the HTTP/1-only ticket even when the server negotiates HTTP/1.
    try std.testing.expect(!try Connect.once(address, host, cell_a, port, .h2_http_1_1));
    // A different security cell must not resume from cell A's tickets.
    try std.testing.expect(!try Connect.once(address, host, cell_b, port, .http_1_1));

    test_support.collo_test_tls_resumption_origin_join(origin.?);
    const origin_error = std.mem.span(test_support.collo_test_tls_resumption_origin_last_error(origin.?));
    if (origin_error.len != 0) {
        std.debug.print("local tls resumption origin error: {s}\n", .{origin_error});
        return error.TlsResumptionOriginFailed;
    }
    try std.testing.expectEqual(@as(u32, 4), test_support.collo_test_tls_resumption_origin_handshakes(origin.?));
    try std.testing.expectEqual(@as(u32, 1), test_support.collo_test_tls_resumption_origin_resumed_count(origin.?));
}
