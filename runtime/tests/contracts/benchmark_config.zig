//! The configuration the sandbox benchmark's daemon writes
//! (`writeConfig` in `runtime/bench/sandbox/node.zig`), parsed by the
//! server's own parser for every combination of the `network` and
//! `concurrency` knobs and the fetch origin, so a knob value the server
//! would refuse fails here rather than at a benchmark's boot. Runs in
//! `microbench-test` and `meta-test`; what the server builds from the
//! configuration runs only in a benchmark run.

const std = @import("std");
const config = @import("collo_server_config");
const protocol = @import("benchmark_protocol");
const testing = std.testing;

const node = protocol.node;
const workload = protocol.workload;

const config_path = "/collo-bench/routes/collo.json";

fn writeAndParse(options: node.ConfigOptions) !config.Config {
    var buffer: [node.config_bytes_max]u8 = undefined;
    var output: std.Io.Writer = .fixed(&buffer);
    try node.writeConfig(&output, options);
    var diagnostic: config.Diagnostic = .{};
    return config.parse(testing.allocator, output.buffered(), config_path, &diagnostic) catch |err| {
        std.debug.print("the benchmark's configuration was rejected: {s}\n{s}\n", .{
            diagnostic.message(),
            output.buffered(),
        });
        return err;
    };
}

test "benchmark configuration declares one definition per sampler route with the knobs' limits" {
    for ([_]u8{ 1, node.concurrency_default, node.concurrency_max }) |concurrency| {
        for (std.enums.values(node.Network)) |network| {
            var parsed = try writeAndParse(.{ .network = network, .concurrency = concurrency });
            defer parsed.deinit();
            try testing.expectEqual(@as(usize, protocol.route_count_max), parsed.definitions.len);
            for (parsed.definitions, 0..) |definition, index| {
                var name_buffer: [32]u8 = undefined;
                const name = try std.fmt.bufPrint(&name_buffer, "sandbox-{d}", .{index});
                try testing.expectEqualStrings(name, definition.name);
                try testing.expectEqual(concurrency, definition.settings.limits.concurrency);
                try testing.expectEqual(node.worker_memory_mib, definition.settings.limits.memory_mib);
                try testing.expectEqual(node.request_timeout_ms, definition.settings.limits.timeout_ms);
                try testing.expectEqual(@as(usize, 1), definition.routes.len);
                const route = definition.routes[0];
                var pattern_buffer: [32]u8 = undefined;
                const pattern = try std.fmt.bufPrint(&pattern_buffer, "{s}{d}", .{ protocol.route_prefix, index });
                try testing.expectEqualStrings(pattern, route.pattern);
                try testing.expectEqualStrings("/collo-bench/routes/" ++ node.entry_file_name, route.entry_path);
                try testing.expectEqual(@as(usize, 0), route.bindings.len);
                switch (network) {
                    .granted => {
                        const grant = route.network orelse return error.TestExpectedGrant;
                        try testing.expectEqual(@as(usize, 1), grant.allow.len);
                        try testing.expect(grant.allow[0].host == .any);
                        try testing.expect(!grant.allow_http);
                        try testing.expect(!grant.allow_private_networks);
                    },
                    .none => try testing.expect(route.network == null),
                }
            }
        }
    }
}

test "benchmark configuration grants the origin with exactly the flags its address needs" {
    const cases = [_]struct { origin: node.Origin, private: bool }{
        .{ .origin = .{ .address = .{ 172, 20, 0, 5 }, .port = 41234 }, .private = true },
        .{ .origin = .{ .address = .{ 8, 8, 8, 8 }, .port = 8080 }, .private = false },
    };
    for (cases) |case| {
        var parsed = try writeAndParse(.{
            .network = .granted,
            .concurrency = node.concurrency_default,
            .origin = case.origin,
            .origin_private = case.private,
        });
        defer parsed.deinit();
        var url_buffer: [64]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "http://{f}", .{case.origin});
        for (parsed.definitions) |definition| {
            const route = definition.routes[0];
            const grant = route.network orelse return error.TestExpectedGrant;
            try testing.expectEqual(@as(usize, 2), grant.allow.len);
            try testing.expect(grant.allow[0].host == .any);
            switch (grant.allow[1].host) {
                .ipv4 => |address| try testing.expectEqual(case.origin.address, address),
                else => return error.TestExpectedIpv4Entry,
            }
            try testing.expectEqual(case.origin.port, grant.allow[1].port);
            try testing.expect(grant.allow_http);
            try testing.expectEqual(case.private, grant.allow_private_networks);
            try testing.expectEqual(@as(usize, 1), route.bindings.len);
            try testing.expectEqualStrings(workload.origin_binding_name, route.bindings[0].name);
            try testing.expectEqualStrings(url, route.bindings[0].value.text);
        }
    }
}

test "benchmark configuration refuses an origin without a grant" {
    var buffer: [node.config_bytes_max]u8 = undefined;
    var output: std.Io.Writer = .fixed(&buffer);
    try testing.expectError(error.OriginNeedsGrant, node.writeConfig(&output, .{
        .network = .none,
        .concurrency = node.concurrency_default,
        .origin = .{ .address = .{ 10, 0, 0, 2 }, .port = 80 },
        .origin_private = true,
    }));
}
