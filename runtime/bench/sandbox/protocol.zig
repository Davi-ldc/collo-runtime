//! The line protocol between the benchmark's controller and its runtime
//! daemon: one bounded JSON value per line, commands on the daemon's stdin and
//! replies on its stdout. The exchange is sequential: the controller sends a
//! command only after the reply to the previous one. The only worker
//! identities the daemon returns are the ones it reads from the supervisor.
//! The file also holds the record writer of the controller's own output and
//! the C ABI of the loopback HTTP/2 client in `client.cc`.

const std = @import("std");
const Workload = @import("workload.zig").Workload;

/// Sampler routes, one worker definition each in the daemon's configuration;
/// the daemon never reports more workers than this.
pub const route_count_max: u32 = 64;
/// Longest command line, newline excluded.
pub const command_bytes_max: usize = 4096;
/// Longest reply line, newline included.
pub const reply_bytes_max: usize = 64 * 1024;
/// The name the client sends as SNI and `:authority`. The server routes by
/// path alone, so the name selects nothing; the handler sees it only as its
/// `host` header and the host of its request's URL.
pub const hostname = "demo.example.test";
/// Route `i` is the path `route_prefix ++ i`.
pub const route_prefix = "/sandbox/";

/// One controller request. `prepare` and `collect` name a `route`; `drop`
/// names a worker by `worker_id` or by `route`, exactly one of the two; and
/// `collect` also names the measured request by `stream_id` and `sent_ns`.
pub const Command = struct {
    op: enum { snapshot, collect, prepare, drop, shutdown },
    route: ?u32 = null,
    worker_id: ?u64 = null,
    stream_id: ?u32 = null,
    /// The client's send time for the request on `stream_id`. Every
    /// connection opens its first measured request on stream 3, after the
    /// `/__collo/healthz` preflight on stream 1, so the daemon also requires the
    /// trace to have arrived after this time.
    sent_ns: ?u64 = null,
};

/// The daemon's first line, sent once its server runs and before any worker
/// exists.
pub const Ready = struct {
    port: u16,
    zygote_pid: u32,
    gateway_pid: u32,
    /// The fixture every route installed; the controller rejects a mismatch.
    workload: Workload,
    /// Recorded in the run's metadata: every route's pack is built at boot
    /// and stays resident, and the packs hold the same source under distinct
    /// specifiers (`writeConfig` in `daemon.zig`).
    resident_pack_count: u32 = route_count_max,
    artifact_topology: enum { equivalent_source_distinct_route_packs } =
        .equivalent_source_distinct_route_packs,
};

/// A worker as the supervisor records it; `route` is its worker definition
/// index, which is also its sampler route.
pub const Worker = struct {
    route: u32,
    pid: u32,
    worker_id: u64,
    worker_generation: u64,
};

/// The host's record of one cold sample, which the daemon assembles from the
/// launcher's `LaunchTrace` (`server/supervisor/launcher.zig`), the worker's
/// record and the handler mark; `coldTrace` in `daemon.zig` says where each
/// field comes from.
pub const ColdTrace = struct {
    request_id: u64,
    request_stream_id: u32,
    request_lane_id: u16,
    connection_slot: u32,
    connection_generation: u64,
    worker_id: u64,
    worker_generation: u64,
    worker_pid: u32,
    launched_worker_pid: u32,
    /// The sampler's route: the daemon configures one worker definition per
    /// route, so this is the definition index the server traced.
    route_index: u32,
    arrived_ns: u64,
    ready_received_ns: u64,
    ready_ns: u64,
    publish_ns: u64,
    delivered_ns: u64,
};

/// The handler-entry record a worker publishes on its shared page when the
/// marker runs (`publishBenchHandler` in `common/worker_state/page/mapping.zig`).
pub const Handler = struct {
    request_id: u64,
    worker_id: u64,
    worker_generation: u64,
    handler_started_ns: u64,
};

/// One daemon line. A failed command answers `failed` with `error_name`, and
/// any other reply echoes the command's `op`. The replies to `snapshot`,
/// `prepare`, `drop` and `collect` carry the worker inventory as it stands
/// after the command.
pub const Reply = struct {
    op: enum { ready, snapshot, collect, prepare, drop, shutdown, failed },
    ready: ?Ready = null,
    workers: []const Worker = &.{},
    trace: ?ColdTrace = null,
    handler: ?Handler = null,
    error_name: ?[]const u8 = null,
};

/// Reads one command line, consuming its newline, and parses it with `allocator`;
/// a last line without a newline is read at end of input, and end of input
/// itself returns null. The caller owns the result. A streaming reader needs
/// a buffer of `command_bytes_max + 1` bytes. `error.CommandTooLarge` ends the
/// stream, since the rest of that line may still be unread; a blank line
/// (`error.EmptyCommand`) or malformed JSON leaves the next line readable.
pub fn readCommand(
    reader: *std.Io.Reader,
    allocator: std.mem.Allocator,
) !?std.json.Parsed(Command) {
    const line = (reader.takeDelimiter('\n') catch |err| switch (err) {
        error.StreamTooLong => return error.CommandTooLarge,
        else => return err,
    }) orelse return null;
    if (line.len > command_bytes_max) return error.CommandTooLarge;
    if (std.mem.trim(u8, line, &std.ascii.whitespace).len == 0) return error.EmptyCommand;
    return try std.json.parseFromSlice(Command, allocator, line, .{
        .allocate = .alloc_always,
        .max_value_len = command_bytes_max,
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    });
}

/// Writes `value` as one JSON line at the descriptor's current offset and
/// flushes it before returning. A record longer than the internal buffer takes
/// several writes, so calls on one descriptor must not overlap, on a regular
/// file as on a pipe.
pub fn writeRecord(file: std.fs.File, value: anytype) !void {
    var buffer: [4096]u8 = undefined;
    var output = file.writerStreaming(&buffer);
    try output.interface.print("{f}\n", .{std.json.fmt(value, .{})});
    try output.interface.flush();
}

/// The loopback HTTP/2 client of `client.cc`; `client.h` states its
/// ownership, threading and failure rules.
pub const Client = opaque {};
/// `ColloBenchReply` in `client.h`, field for field.
pub const ClientReply = extern struct {
    sent_ns: u64,
    response_ns: u64,
    stream_id: u32,
    status: u32,
    body_len: u32,
    reserved: u32,
};

pub extern "c" fn collo_bench_client_open(
    port: u16,
    server_name: [*:0]const u8,
    out: *?*Client,
) c_int;
pub extern "c" fn collo_bench_client_get(
    client: *Client,
    path: [*:0]const u8,
    body: [*:0]const u8,
    out: *ClientReply,
) c_int;
pub extern "c" fn collo_bench_client_close(client: ?*Client) void;
