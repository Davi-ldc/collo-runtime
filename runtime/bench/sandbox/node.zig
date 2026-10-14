//! The measured node's knobs and the `collo.json` the daemon writes from
//! them. The controller reads each knob from its environment, hands the
//! validated value to the daemon in the daemon's environment, and checks the
//! daemon's `ready` line against it (`protocol.Ready`). Nothing here reads a
//! file or the network, so `runtime/tests/contracts/benchmark_config.zig`
//! parses what `writeConfig` writes with the server's own parser.
//!
//! The configuration declares `protocol.route_count_max` worker definitions,
//! `sandbox-<i>`, each with the one route `protocol.route_prefix ++ <i>` on
//! the shared entry `entry_file_name`. Pools are keyed by definition, so
//! every route gets a pool and a pack of its own while all packs hold the
//! same source under different specifiers. The limits and the `network`
//! grant sit in the top-level `settings` and cascade to every definition.

const std = @import("std");
const protocol = @import("protocol.zig");
const workload = @import("workload.zig");

/// Whether the definitions get a `network` grant.
pub const Network = enum {
    /// Every definition may fetch public HTTPS (`"*"`), so every worker gets
    /// an egress session and the gateway runs: the configuration of the
    /// recorded baselines, which had a session per worker.
    granted,
    /// No definition has a grant: no worker gets an egress session, and the
    /// server spawns no gateway.
    none,

    pub const environment_name = "COLLO_BENCH_NETWORK";

    /// Reads `environment_name`; unset selects `granted`.
    pub fn fromEnvironment() error{InvalidBenchmarkNetwork}!Network {
        const text = std.posix.getenv(environment_name) orelse return .granted;
        return parse(text);
    }

    pub fn parse(text: []const u8) error{InvalidBenchmarkNetwork}!Network {
        return std.meta.stringToEnum(Network, text) orelse error.InvalidBenchmarkNetwork;
    }
};

/// Every definition's `limits.concurrency`.
pub const concurrency_environment_name = "COLLO_BENCH_CONCURRENCY";
/// The configuration's own default, so an unset knob measures what a
/// definition that names no `concurrency` gets.
pub const concurrency_default: u8 = 2;
/// The largest value the configuration accepts, `worker_concurrency_max` in
/// `common/limits/server.zig`; the daemon asserts the two are equal.
pub const concurrency_max: u8 = 16;

/// Reads `concurrency_environment_name`; unset selects
/// `concurrency_default`.
pub fn concurrencyFromEnvironment() error{InvalidBenchmarkConcurrency}!u8 {
    const text = std.posix.getenv(concurrency_environment_name) orelse return concurrency_default;
    return parseConcurrency(text);
}

/// A decimal from 1 to `concurrency_max`.
pub fn parseConcurrency(text: []const u8) error{InvalidBenchmarkConcurrency}!u8 {
    const value = std.fmt.parseUnsigned(u8, text, 10) catch return error.InvalidBenchmarkConcurrency;
    if (value < 1 or value > concurrency_max) return error.InvalidBenchmarkConcurrency;
    return value;
}

/// The plain-HTTP origin a fetching workload reaches (`origin.zig`). The
/// controller hands it to the daemon in `environment_name`, written by
/// `format`.
pub const Origin = struct {
    address: [4]u8,
    port: u16,

    pub const environment_name = "COLLO_BENCH_ORIGIN";
    /// The longest text `format` writes.
    pub const text_bytes_max = "255.255.255.255:65535".len;

    /// Reads `environment_name`, or null when it is unset.
    pub fn fromEnvironment() error{InvalidBenchmarkOrigin}!?Origin {
        const text = std.posix.getenv(environment_name) orelse return null;
        return try parse(text);
    }

    /// Reads `a.b.c.d:port` as `format` writes it: decimal parts with no
    /// sign, separator or leading zero, and a nonzero port.
    pub fn parse(text: []const u8) error{InvalidBenchmarkOrigin}!Origin {
        const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return error.InvalidBenchmarkOrigin;
        var parts = std.mem.splitScalar(u8, text[0..colon], '.');
        var address: [4]u8 = undefined;
        for (&address) |*part| {
            part.* = try parseCanonicalDecimal(u8, parts.next() orelse return error.InvalidBenchmarkOrigin);
        }
        if (parts.next() != null) return error.InvalidBenchmarkOrigin;
        const port = try parseCanonicalDecimal(u16, text[colon + 1 ..]);
        if (port == 0) return error.InvalidBenchmarkOrigin;
        return .{ .address = address, .port = port };
    }

    pub fn format(self: Origin, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d}.{d}.{d}.{d}:{d}", .{
            self.address[0], self.address[1], self.address[2], self.address[3], self.port,
        });
    }
};

/// The entry module every route shares, beside the configuration.
pub const entry_file_name = "sandbox.js";
/// Every worker's memory limit.
pub const worker_memory_mib: u32 = 512;
/// Every request's deadline. The slowest step, `fetch_upload`, must finish
/// within it in an emulated guest, which runs many times slower than native
/// hardware.
pub const request_timeout_ms: u32 = 30_000;
/// Longest configuration `writeConfig` writes.
pub const config_bytes_max: usize = 32 * 1024;

pub const ConfigOptions = struct {
    network: Network,
    /// From 1 to `concurrency_max`.
    concurrency: u8,
    /// Granted beside `"*"` with `allowHttp`, and named to every route's
    /// handler as the text binding `workload.origin_binding_name`. It needs
    /// `network` to be `granted`.
    origin: ?Origin = null,
    /// Whether `origin`'s address is private. The configuration names a
    /// private address only with `allowPrivateNetworks`, and refuses that
    /// flag when no entry can reach a private address.
    origin_private: bool = false,
};

/// Writes the configuration. An origin without a grant fails with
/// `error.OriginNeedsGrant`, since a fetch the configuration does not grant
/// is refused; a full `output` fails with `error.WriteFailed`.
pub fn writeConfig(
    output: *std.Io.Writer,
    options: ConfigOptions,
) (std.Io.Writer.Error || error{OriginNeedsGrant})!void {
    std.debug.assert(options.concurrency >= 1);
    std.debug.assert(options.concurrency <= concurrency_max);
    if (options.origin == null) std.debug.assert(!options.origin_private);
    if (options.origin != null and options.network == .none) return error.OriginNeedsGrant;

    try output.print(
        "{{\"settings\":{{\"limits\":{{\"memoryMiB\":{d},\"timeoutMs\":{d},\"concurrency\":{d}}}",
        .{ worker_memory_mib, request_timeout_ms, options.concurrency },
    );
    switch (options.network) {
        .none => {},
        .granted => {
            try output.writeAll(",\"network\":{\"allow\":[\"*\"");
            if (options.origin) |origin| {
                try output.print(",\"{f}\"],\"allowHttp\":true", .{origin});
                if (options.origin_private) try output.writeAll(",\"allowPrivateNetworks\":true");
                try output.writeByte('}');
            } else {
                try output.writeAll("]}");
            }
        },
    }
    try output.writeAll("},\"workers\":{");
    for (0..protocol.route_count_max) |index| {
        if (index != 0) try output.writeByte(',');
        try output.print(
            "\"sandbox-{d}\":{{\"routes\":{{\"" ++ protocol.route_prefix ++
                "{d}\":{{\"entry\":\"./" ++ entry_file_name ++ "\"",
            .{ index, index },
        );
        if (options.origin) |origin| try output.print(
            ",\"bindings\":{{\"" ++ workload.origin_binding_name ++ "\":{{\"text\":\"http://{f}\"}}}}",
            .{origin},
        );
        try output.writeAll("}}}");
    }
    try output.writeAll("}}\n");
}

fn parseCanonicalDecimal(comptime T: type, digits: []const u8) error{InvalidBenchmarkOrigin}!T {
    if (digits.len == 0) return error.InvalidBenchmarkOrigin;
    if (digits.len > 1 and digits[0] == '0') return error.InvalidBenchmarkOrigin;
    for (digits) |digit| {
        if (!std.ascii.isDigit(digit)) return error.InvalidBenchmarkOrigin;
    }
    return std.fmt.parseUnsigned(T, digits, 10) catch error.InvalidBenchmarkOrigin;
}
