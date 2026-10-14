//! The gateway process's boot and event loop. The server spawns the process
//! (`server/gateway/process.zig`), and the loop runs on its main thread, which owns the `Gateway`:
//! the worker sessions, the fetch table, the shards, the control socket and what the server's
//! hello brings, the key that verifies egress tokens and the network policy table. The loop's work
//! is plain functions over the one `Gateway` in the files beside this one: `control_flow.zig` (the
//! control socket), `session_flow.zig` (sessions, the packets the gateway writes to them, their
//! backpressure), `command_flow.zig` (worker commands and fetch admission), `upload_flow.zig`
//! (pooled request bodies), `fetch_flow.zig` (how a fetch ends), `shard_flow.zig` (shard
//! collection and supervision), `body_pump.zig` (a fetch's head and body into packets) and
//! `release_flow.zig` (body-pool releases).
//!
//! Boot order is fixed (`run`). The sizing plan is computed before the sandbox hides /proc; the
//! trust store loads before any engine thread exists; the shards' threads and the readiness ring
//! exist before seccomp, which forbids creating either; and gateway-ready is the last step. A test
//! or an in-process stand-in builds a `Gateway`, starts its shards and calls `serve` without the
//! sandbox.
//!
//! Dependencies run one way: the loop routes worker commands to shards, a shard owns an engine,
//! and only the engine calls the outbound transport. The gateway holds the network capability,
//! so every worker command is hostile input, even from a worker of the same definition. A new
//! command path must pass the checks the existing ones do: the token verification in
//! `command_flow.zig`, the session-scoped fetch table (`fetch_table.zig`), and the network policy
//! the token names, which the egress transport enforces on every hop against server-side request
//! forgery (SSRF). Isolation is keyed by worker session, security cell and policy, and a worker's
//! fetch ids mean nothing outside its session.

const std = @import("std");
const egress_client = @import("collo_egress_client");
const ipc = @import("collo_ipc");
const os_process = @import("collo_os").process;

const containment = @import("../containment.zig");
const control = @import("../control.zig");
const counting_allocator = @import("../counting_allocator.zig");
const engine_mod = @import("../engine.zig");
const fetch_table = @import("../fetch_table.zig");
const policy_mod = @import("../policy.zig");
const readiness_mod = @import("../readiness.zig");
const sandbox = @import("../sandbox.zig");
const sessions_mod = @import("../sessions.zig");
const shard_mod = @import("../shard.zig");
const sizing = @import("../sizing.zig");

pub const body_pump = @import("body_pump.zig");
pub const command_flow = @import("command_flow.zig");
pub const control_flow = @import("control_flow.zig");
pub const fetch_flow = @import("fetch_flow.zig");
pub const release_flow = @import("release_flow.zig");
pub const session_flow = @import("session_flow.zig");
pub const shard_flow = @import("shard_flow.zig");
pub const upload_flow = @import("upload_flow.zig");

/// Boots the gateway on `control_fd`, the control socket it inherits from the server
/// (`launch.zig`), and runs its loop until the server shuts it down. The gateway owns
/// `control_fd` from the call on. Once the gateway is built, nothing is torn down on return:
/// the caller exits the process at once (`root.zig:runFromInheritedControlFd`), and the kernel
/// releases the gateway's memory, descriptors and threads.
pub fn run(allocator: std.mem.Allocator, control_fd: std.posix.fd_t) !void {
    // The plan reads the cgroup's CPU quota through /proc and /sys, which the sandbox hides, and
    // the sandbox applies the plan's open-file limit (`sizing.zig`).
    const plan = sizing.Plan.compute() catch |err| {
        std.posix.close(control_fd);
        return err;
    };
    sandbox.applyProcessBaseline(plan) catch |err| {
        std.posix.close(control_fd);
        return err;
    };
    // The trust store loads now, before any engine thread exists and before seccomp, so no
    // verified fetch reads the filesystem and the first one does not pay for the load.
    egress_client.tls.preloadVerifiedContext() catch |err| {
        std.posix.close(control_fd);
        return err;
    };
    const gateway = allocator.create(Gateway) catch |err| {
        std.posix.close(control_fd);
        return err;
    };
    try gateway.init(allocator, control_fd, .{
        .shard_count = plan.shard_count,
        .sessions_max = plan.sessions_max,
    });
    try gateway.startShards();
    try sandbox.applySeccompAfterThreadsStarted();
    // Gateway-ready must be the last boot step: the server's spawn waits for it, and the gateway
    // the server then records must be fully sandboxed, with no boot step left for an attach to
    // race. Nothing has been sent on the control socket yet, so this nonblocking send cannot find
    // the buffer full.
    try control.sendGatewayReady(control_fd);
    try gateway.serve();
}

pub const Gateway = struct {
    allocator: std.mem.Allocator,
    control_fd: std.posix.fd_t,
    /// The limits every fetch runs under, `policy.production` outside tests.
    policy: policy_mod.Policy,
    /// Sessions the gateway holds at once (`sizing.Plan.sessions_max`); an attach past it is
    /// refused.
    sessions_max: usize,
    sessions: sessions_mod.Registry = .{},
    fetches: fetch_table.Table = .{},
    shards: shard_mod.Set,
    readiness: readiness_mod.Backend,
    /// The token key and the decoded network policies, which only the server's hello writes
    /// (`control_flow.zig`).
    hello: control_flow.HelloState = .{},
    /// Where the loop receives control packets and copies worker commands out of their rings; a
    /// decoded command's slices point into it until the next read.
    read_scratch: []u8,
    /// Where the loop encodes the packets it writes to workers, apart from `read_scratch`, so no
    /// encoding can overwrite a command whose decoded view is still in use.
    encode_scratch: []u8,
    /// Scratch for decoding worker commands. It lives on the heap: its arrays are sized by the
    /// protocol's limits, too large for a stack, and as a thread-local it would be copied into
    /// every thread of the binary.
    decode_scratch: *ipc.GatewayEgressDecodeScratch,
    pending_control_packets: control_flow.PendingControlPackets = .{},
    /// Every pooled upload still assembling, earliest deadline first (`upload_flow.zig`).
    uploads_by_deadline: std.DoublyLinkedList = .{},
    /// The allocator of every pooled upload's assembly buffer, budgeted at
    /// `containment.upload_memory`. Tasks on engine threads copy its `std.mem.Allocator` and free
    /// through it, so the cell lives on the heap and never moves, and it outlives the shards
    /// whose tasks hold its buffers.
    upload_memory: *counting_allocator.CountingAllocator,
    /// Ids of the sessions the loop looks at again before its next wait (`session_flow.zig`):
    /// each at most once, which `Session.attention_queued` records, so the capacity reserved at
    /// attach covers every session.
    attention: std.ArrayListUnmanaged(u64) = .empty,
    /// The ids `session_flow.processAttention` took out of `attention` for its pass, so the
    /// sessions it writes to meanwhile queue again in `attention`. Reserved like `attention`.
    attention_pass: std.ArrayListUnmanaged(u64) = .empty,
    /// True while a shard's collection pass runs, so that completion-eventfd writes wait for the
    /// end of the pass and each worker gets one instead of one per packet.
    coalesce_completion_notifies: bool = false,

    pub const Options = struct {
        shard_count: usize,
        sessions_max: usize,
        policy: policy_mod.Policy = policy_mod.production,
        engine: engine_mod.Config = .{},
        shard_memory_budget_bytes: u64 = containment.shard_memory.budget_bytes,
    };

    /// Builds the gateway's state, its shards and its readiness ring in place on `control_fd`,
    /// which it owns from the call on and closes on failure. Starts no thread. Fails with
    /// `error.OutOfMemory`, or with what the shards' or the ring's setup fails with, freeing
    /// everything it took.
    pub fn init(
        target: *Gateway,
        allocator: std.mem.Allocator,
        control_fd: std.posix.fd_t,
        options: Options,
    ) !void {
        errdefer std.posix.close(control_fd);
        std.debug.assert(options.sessions_max >= 1);
        const read_scratch = try allocator.alloc(u8, ipc.max_message_bytes);
        errdefer allocator.free(read_scratch);
        const encode_scratch = try allocator.alloc(u8, ipc.max_message_bytes);
        errdefer allocator.free(encode_scratch);
        const decode_scratch = try allocator.create(ipc.GatewayEgressDecodeScratch);
        errdefer allocator.destroy(decode_scratch);
        decode_scratch.* = .{};
        const upload_memory = try allocator.create(counting_allocator.CountingAllocator);
        errdefer allocator.destroy(upload_memory);
        upload_memory.* = .{ .child = allocator };
        upload_memory.setBudget(containment.upload_memory.budget_bytes);
        var engine_config = options.engine;
        engine_config.policy = options.policy;
        var shards = try shard_mod.Set.init(
            allocator,
            options.shard_count,
            engine_config,
            options.shard_memory_budget_bytes,
        );
        errdefer shards.deinit(allocator);
        var readiness = try readiness_mod.Backend.init(allocator, options.shard_count, options.sessions_max);
        errdefer readiness.deinit();
        target.* = .{
            .allocator = allocator,
            .control_fd = control_fd,
            .policy = options.policy,
            .sessions_max = options.sessions_max,
            .shards = shards,
            .readiness = readiness,
            .read_scratch = read_scratch,
            .encode_scratch = encode_scratch,
            .decode_scratch = decode_scratch,
            .upload_memory = upload_memory,
        };
    }

    /// Ends every session's fetches, stops the shards and frees everything, the control socket
    /// included.
    pub fn deinit(self: *Gateway) void {
        while (self.sessions.len() != 0)
            session_flow.discardSession(self, self.sessions.len() - 1);
        self.sessions.deinit(self.allocator);
        self.fetches.deinit(self.allocator);
        // The shards' tasks may still hold upload buffers, which go back to the upload allocator
        // as the engines release them, so the shards go before it.
        self.shards.deinit(self.allocator);
        self.readiness.deinit();
        self.hello.deinit(self.allocator);
        self.attention.deinit(self.allocator);
        self.attention_pass.deinit(self.allocator);
        self.allocator.free(self.read_scratch);
        self.allocator.free(self.encode_scratch);
        self.allocator.destroy(self.decode_scratch);
        self.allocator.destroy(self.upload_memory);
        std.posix.close(self.control_fd);
        self.* = undefined;
    }

    /// Starts every shard's threads and polls their wake eventfds. Call it before the seccomp
    /// filter, which forbids creating threads.
    pub fn startShards(self: *Gateway) !void {
        try self.shards.startAll();
        for (self.shards.list, 0..) |*shard, index|
            try self.readiness.addShard(index, shard.engine.wake_fd);
    }

    /// Runs the loop until the server sends shutdown or closes its end of the control socket.
    /// Fails, which ends the gateway, on a control packet that does not decode, on a removal
    /// report it can neither send nor queue, on a shard failure past the restart backstop, and
    /// on a readiness ring that fails.
    pub fn serve(self: *Gateway) !void {
        while (true) {
            if (try self.step()) return;
        }
    }

    /// One pass of the loop: wait, then handle what woke it. Returns true once the server asked
    /// for shutdown or hung up.
    pub fn step(self: *Gateway) !bool {
        try self.readiness.armControl(self.control_fd, control_flow.controlEvents(self));
        try self.readiness.rearm();
        var ready_events: [readiness_mod.wait_ready_max]readiness_mod.Ready = undefined;
        const ready_count = try self.readiness.wait(&ready_events);

        // The control socket first, so a shutdown ends the pass before anything else runs.
        for (ready_events[0..ready_count]) |event| {
            switch (event) {
                .control => |revents| {
                    if ((revents & (std.posix.POLL.HUP | std.posix.POLL.ERR)) != 0)
                        return true;
                    if ((revents & std.posix.POLL.OUT) != 0)
                        try control_flow.flushPendingControlPackets(self);
                    if ((revents & std.posix.POLL.IN) != 0) {
                        if (try control_flow.drainControl(self))
                            return true;
                        try control_flow.flushPendingControlPackets(self);
                    }
                },
                .shard, .session => {},
            }
        }
        for (ready_events[0..ready_count]) |event| {
            switch (event) {
                .control => {},
                .shard => |shard_ready| try shard_flow.handleShardReady(self, shard_ready.index, shard_ready.revents),
                .session => |session_ready| try session_flow.handleSessionReady(self, session_ready),
            }
        }
        upload_flow.expire(self, os_process.monotonicNowNsOrZero());
        try session_flow.processAttention(self, os_process.monotonicNowNsOrZero());
        try session_flow.removeDroppedSessions(self);
        return false;
    }
};
