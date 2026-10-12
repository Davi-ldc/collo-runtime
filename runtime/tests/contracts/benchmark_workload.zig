//! The sandbox benchmark's workloads and node knobs
//! (`runtime/bench/sandbox/workload.zig`, `node.zig`), reached through the
//! protocol module that carries them: what each workload's load sends and
//! expects back, the knob parsers, the daemon's `ready` line that echoes the
//! knobs, and the client exchange's layout. Runs in `microbench-test` and
//! `meta-test`; `benchmark_config.zig` parses the configuration the knobs
//! produce, and only a benchmark run executes the fixtures.

const std = @import("std");
const protocol = @import("benchmark_protocol");
const testing = std.testing;

const workload = protocol.workload;
const node = protocol.node;
const Workload = workload.Workload;
const Exchange = workload.Exchange;

test "benchmark single-step workloads load one exchange with a default the knob replaces" {
    const cases = [_]struct { workload: Workload, exchange: Exchange, requests: u32 }{
        .{ .workload = .hello, .exchange = .hello, .requests = 10 },
        .{ .workload = .crypto, .exchange = .crypto, .requests = 1 },
        .{ .workload = .upload, .exchange = .upload, .requests = 1 },
        .{ .workload = .stream, .exchange = .stream, .requests = 1 },
        .{ .workload = .fetch, .exchange = .fetch, .requests = 1 },
        .{ .workload = .fetch_upload, .exchange = .fetch_upload, .requests = 1 },
        .{ .workload = .webcrypto, .exchange = .webcrypto, .requests = 1 },
    };
    for (cases) |case| {
        const default = try case.workload.load(null);
        try testing.expectEqual(@as(usize, 1), default.steps().len);
        try testing.expectEqual(case.exchange, default.steps()[0].exchange);
        try testing.expectEqual(case.requests, default.steps()[0].requests);
        const chosen = try case.workload.load(workload.load_requests_max);
        try testing.expectEqual(@as(u64, workload.load_requests_max), chosen.requestCount());
    }
}

test "benchmark sequence runs every step on one worker and refuses a request count" {
    const plan = try Workload.sequence.load(null);
    const expected = [_]Exchange{ .hello, .upload, .stream, .fetch, .fetch_upload };
    try testing.expectEqual(expected.len, plan.steps().len);
    for (expected, plan.steps()) |exchange, step| try testing.expectEqual(exchange, step.exchange);
    try testing.expectEqual(@as(u32, 10), plan.steps()[0].requests);
    try testing.expectEqual(@as(u64, 14), plan.requestCount());
    try testing.expectError(error.FixedLoadRequests, Workload.sequence.load(2));
}

test "benchmark workloads that fetch are exactly the ones that need the origin" {
    for (std.enums.values(Workload)) |value| {
        const expected = switch (value) {
            .fetch, .fetch_upload, .sequence => true,
            .hello, .crypto, .upload, .stream, .webcrypto => false,
        };
        try testing.expectEqual(expected, value.needsOrigin());
    }
}

test "benchmark exchanges promise the bodies their fixture writes" {
    try testing.expectEqualStrings("sandbox benchmark\n", Exchange.hello.response().exact);
    try testing.expectEqualStrings("upload 1048576\n", Exchange.upload.response().exact);
    try testing.expectEqualStrings("fetch 200 4194304\n", Exchange.fetch.response().exact);
    try testing.expectEqualStrings("fetch_upload 16777216\n", Exchange.fetch_upload.response().exact);
    try testing.expectEqualStrings(
        "webcrypto 30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58\n",
        Exchange.webcrypto.response().exact,
    );
    try testing.expectEqual(@as(u64, 4 * 1024 * 1024), Exchange.stream.response().byteCount());
    try testing.expectEqual(@as(u32, workload.upload_body_bytes), Exchange.upload.requestBodyBytes());
    for (std.enums.values(Exchange)) |exchange| {
        if (exchange != .upload) try testing.expectEqual(@as(u32, 0), exchange.requestBodyBytes());
    }
    try testing.expectEqualStrings("", Exchange.hello.query());
    try testing.expectEqualStrings("?step=fetch_upload", Exchange.fetch_upload.query());
    // The steps fixture reads its sizes and the binding from constants the
    // controller and the origin share, and answers a plain GET as hello does.
    const source = Workload.sequence.entrySource();
    const constants = [_][]const u8{
        "const blockBytes = 65536;",
        "const streamBlocks = 64;",
        "const fetchUploadBodies = 4;",
        "const fetchUploadBodyBytes = 4194304;",
        "const webcryptoDigestBytes = 1048576;",
        "const originBinding = \"" ++ workload.origin_binding_name ++ "\";",
        "const downloadPath = \"" ++ workload.download_path ++ "\";",
        "const uploadPath = \"" ++ workload.upload_path ++ "\";",
        "if (step === null) return text(\"sandbox benchmark\\n\");",
        "  globalThis.__colloBenchHandlerEntered?.();\n  const step",
    };
    for (constants) |line| {
        errdefer std.debug.print("the steps fixture lacks: {s}\n", .{line});
        try testing.expect(std.mem.indexOf(u8, source, line) != null);
    }
    try testing.expectEqual(Exchange.hello, Workload.sequence.coldExchange());
    try testing.expectEqual(Exchange.crypto, Workload.crypto.coldExchange());
}

test "benchmark node knobs accept their documented values only" {
    try testing.expectEqual(node.Network.granted, try node.Network.parse("granted"));
    try testing.expectEqual(node.Network.none, try node.Network.parse("none"));
    for ([_][]const u8{ "", "Granted", "off", "granted " }) |text|
        try testing.expectError(error.InvalidBenchmarkNetwork, node.Network.parse(text));
    try testing.expectEqual(@as(u8, 1), try node.parseConcurrency("1"));
    try testing.expectEqual(node.concurrency_max, try node.parseConcurrency("16"));
    for ([_][]const u8{ "0", "17", "", "-1", "two", "256" }) |text|
        try testing.expectError(error.InvalidBenchmarkConcurrency, node.parseConcurrency(text));
}

test "benchmark origin text round-trips and rejects every other spelling" {
    const origin = node.Origin{ .address = .{ 172, 20, 0, 5 }, .port = 41234 };
    var buffer: [node.Origin.text_bytes_max]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{f}", .{origin});
    try testing.expectEqualStrings("172.20.0.5:41234", text);
    try testing.expectEqual(origin, try node.Origin.parse(text));
    const widest = node.Origin{ .address = .{ 255, 255, 255, 255 }, .port = 65535 };
    try testing.expectEqualStrings("255.255.255.255:65535", try std.fmt.bufPrint(&buffer, "{f}", .{widest}));
    const malformed = [_][]const u8{
        "172.20.0.5",      "172.20.0:80",    "172.20.0.5.1:80", "172.20.0.05:80",
        "172.20.0.256:80", "172.20.0.5:0",   "172.20.0.5:+80",  "172.20.0.5:65536",
        "[::1]:80",        "172.20.0.5:080", ":80",             "172.20..5:80",
    };
    for (malformed) |spelling| {
        errdefer std.debug.print("origin '{s}' did not fail\n", .{spelling});
        try testing.expectError(error.InvalidBenchmarkOrigin, node.Origin.parse(spelling));
    }
}

test "benchmark ready line carries the knobs and no gateway when nothing is granted" {
    const line =
        \\{"port":4433,"zygote_pid":10,"gateway_pid":null,"workload":"sequence","network":"none",
        \\"concurrency":16,"resident_pack_count":64,"artifact_topology":"equivalent_source_distinct_route_packs"}
    ;
    const parsed = try std.json.parseFromSlice(protocol.Ready, testing.allocator, line, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(?u32, null), parsed.value.gateway_pid);
    try testing.expectEqual(Workload.sequence, parsed.value.workload);
    try testing.expectEqual(node.Network.none, parsed.value.network);
    try testing.expectEqual(@as(u8, 16), parsed.value.concurrency);
    // A ready line from a daemon that does not report its knobs is refused.
    try testing.expectError(error.MissingField, std.json.parseFromSlice(
        protocol.Ready,
        testing.allocator,
        "{\"port\":4433,\"zygote_pid\":10,\"gateway_pid\":11,\"workload\":\"hello\"}",
        .{},
    ));
}

test "benchmark client exchange keeps the layout client.h declares" {
    try testing.expectEqual(@as(usize, 40), @sizeOf(protocol.ClientExchange));
    try testing.expectEqual(@as(usize, 8), @offsetOf(protocol.ClientExchange, "expected_body"));
    try testing.expectEqual(@as(usize, 24), @offsetOf(protocol.ClientExchange, "request_body_len"));
    try testing.expectEqual(@as(usize, 32), @offsetOf(protocol.ClientExchange, "pattern_block_bytes"));
    try testing.expectEqual(@as(usize, 36), @offsetOf(protocol.ClientExchange, "reserved"));
}
