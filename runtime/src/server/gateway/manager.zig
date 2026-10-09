//! The server's manager for its one egress gateway process. It spawns the gateway with a token key
//! drawn for that gateway alone and the network policy table built at `init`, attaches worker
//! sessions under their security cell, and hands each ingress lane what it mints tokens with
//! (`lease.zig`). Nothing is registered with the gateway per request: a lane mints a token from its
//! lease, and the gateway verifies it at fetch admission.
//!
//! The security cell of a worker session is its worker definition (`securityCellIdForDefinition`):
//! workers of one definition share egress pools and the per-cell fetch cap, and never another
//! definition's.
//!
//! A `Record` is one gateway process with its control client, generation and key. The current
//! record's generation is published in `current_generation`, 0 while none is current, and the lanes
//! load it once per loop pass. Any failure of the control channel retires the record. The client's
//! `failed` callback takes it out of `current`, kills the gateway without waiting, which hangs up
//! the liveness descriptor of every worker attached to it so the worker detaches, and tells the
//! launcher (`Deps.gatewayLost`), which spawns the next gateway and reattaches the live workers.
//! Only a refused attach fails one call and leaves the gateway current. A session the gateway
//! removes on its own detaches that worker alone; the gateway reports it, and the manager passes
//! the report to the launcher (`Deps.sessionLost`), which gives the worker a new session.
//!
//! A retired record waits in `retired` until the next spawn or `deinit` destroys it, joining its
//! reader first, so no reader destroys its own record. Only the current record is retired, and
//! every spawn first destroys the retired one, so at most one waits.
//!
//! `prewarm`, `attachWorker` and `deinit` hold `serial` for their whole run, so spawns never overlap
//! and no record is destroyed while an attach uses it outside `mutex`. In a server the boot thread
//! may prewarm before the launcher exists, the launcher makes every later call, and `deinit` runs
//! after it joined, so `serial` is never contended. `mutex` guards `current`, `retired`, `ended`
//! and the counters, and a lane takes it only to renew its lease. `deps_mutex` guards `deps` and is
//! held across each `Deps.gatewayLost` call. The lock order is `serial`, a client's
//! `attach_mutex`, then `mutex` or `deps_mutex`, and no thread holds those last two together.

const std = @import("std");
const fd_mod = @import("collo_os").fd;
const ipc = @import("collo_ipc");
const lifecycle = @import("collo_server_lifecycle");
const control = @import("collo_egress_gateway").control;
const policy = @import("collo_egress_gateway").policy;
const control_client = @import("control_client.zig");
const lease_mod = @import("lease.zig");
const process_mod = @import("process.zig");

const egress_shared = ipc.egress_shared;
const egress_token = ipc.egress_token;

/// The key of a lease that holds no gateway.
const no_key: egress_token.Key = .{ .bytes = @splat(0) };

pub const Config = struct {
    executable_path: ?[]const u8 = null,
    /// The single entry of every gateway's policy table until the configuration accepts
    /// `network`. A server keeps `policy.public_https`; a test harness whose origins are plain
    /// HTTP on a private address of the host loosens it.
    network_policy: policy.NetworkPolicy = policy.public_https,
};

/// What the manager calls when a gateway it held, or one session of it, is gone. Set with
/// `setDeps` while a launcher can take the loss and cleared with `clearDeps` before it goes; a
/// gateway lost while none is set is retired without a call, and the next `prewarm` or
/// `attachWorker` spawns its successor, while a session lost then has no worker to reattach.
pub const Deps = struct {
    ctx: *anyopaque,
    /// Called once per retired gateway, after its control channel failed or its process exited,
    /// from the thread that saw it (the control reader, or the launcher when its own attach
    /// failed), with no manager lock held but `deps_mutex`, which lets `clearDeps` wait for a call
    /// in flight. The callee wakes the launcher (`Launcher.gatewayLost`) and returns at once. It
    /// never calls into the manager: the reattach waits for attach acks, which only a control
    /// reader receives.
    gatewayLost: *const fn (ctx: *anyopaque, generation: u64) void,
    /// Called once per session that gateway `generation` reported removed
    /// (`control.SessionRemoved`), on that gateway's control reader, under the same rules as
    /// `gatewayLost`. The callee hands it to the launcher (`Launcher.egressSessionLost`) and
    /// returns at once.
    sessionLost: *const fn (ctx: *anyopaque, generation: u64, session_id: u64) void,
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    config: Config,
    /// Every gateway's network policies, built once from `config` and sent in each hello; a
    /// token names its route's entry by id.
    policy_table: policy.PolicyTable,
    serial: std.Thread.Mutex = .{},
    mutex: std.Thread.Mutex = .{},
    /// The gateway new sessions attach to; null before the first spawn and after a retire.
    current: ?*Record = null,
    /// The record retired since the last spawn; never set while `current` is.
    retired: ?*Record = null,
    /// `current`'s generation, 0 while it is null: stored under `mutex`, loaded without it.
    current_generation: std.atomic.Value(u64) = .init(0),
    /// The generation of the next gateway; only the spawn path, under `serial`, touches it.
    next_gateway_generation: u64 = 1,
    /// The one-entry packets of `requestEnded`, built here so the wire stays `control.zig`'s.
    ended: control.RequestEndedBatch = .{},
    /// `requestEnded` packets the socket refused, full or with the gateway gone.
    ended_batches_dropped_full: u64 = 0,
    ended_batches_dropped_closed: u64 = 0,
    /// `renewLease` calls that could not dup the control socket. Each leaves the lease empty, so
    /// its lane mints `egress_token.none` until a later pass renews it.
    lease_renewals_failed: u64 = 0,
    /// The generation whose failed renewal was logged last, so each gateway logs once.
    lease_renewal_failure_logged_generation: u64 = 0,
    deps_mutex: std.Thread.Mutex = .{},
    deps: ?Deps = null,

    /// Builds the policy table from `config` and spawns nothing; the first `prewarm` or
    /// `attachWorker` does. Each gateway's record points back to the manager, so the manager
    /// stays in place from the first spawn until `deinit`.
    pub fn init(self: *Manager, allocator: std.mem.Allocator, config: Config) void {
        self.* = .{
            .allocator = allocator,
            .config = config,
            .policy_table = policy.PolicyTable.single(config.network_policy),
        };
    }

    /// Stops every gateway: the current one gets the shutdown request and up to
    /// `PROCESS_EXIT_WAIT_MS` to exit, and a retired one is reaped. The caller has stopped every
    /// thread that calls the manager and cleared `Deps`.
    pub fn deinit(self: *Manager) void {
        self.serial.lock();
        self.mutex.lock();
        const current = self.current;
        const retired = self.retired;
        self.current = null;
        self.retired = null;
        self.current_generation.store(0, .release);
        self.mutex.unlock();

        // A reader that fails from here on finds its record no longer current and calls nothing.
        if (retired) |record|
            self.destroyRecord(record, .no_wait);
        if (current) |record|
            self.destroyRecord(record, .wait);
        self.serial.unlock();
        self.* = undefined;
    }

    pub fn setDeps(self: *Manager, deps: Deps) void {
        self.deps_mutex.lock();
        defer self.deps_mutex.unlock();
        self.deps = deps;
    }

    /// Removes the `Deps` that `setDeps` set; once this returns, no call reaches their context.
    pub fn clearDeps(self: *Manager) void {
        self.deps_mutex.lock();
        defer self.deps_mutex.unlock();
        self.deps = null;
    }

    /// Spawns a gateway when none is current: draws its key (`egress_token.Key.random`), has
    /// `process.spawn` send the hello with the table right after `gateway_ready`, starts the control
    /// reader and publishes the generation. It also destroys the record retired since the last
    /// spawn, joining its reader. The launcher calls it to start each reattach pass
    /// (`prewarmForPass` in `server/supervisor/launcher.zig`), and `Server.prewarmEgressGateway`
    /// calls it before `Server.run` for the sandbox benchmark and local-e2e; the `collo serve` boot
    /// does not, so there the first `attachWorker` spawns the gateway. Fails with the spawn's
    /// error, and nothing stays behind.
    pub fn prewarm(self: *Manager) !void {
        self.serial.lock();
        defer self.serial.unlock();
        _ = try self.currentRecord();
    }

    /// One attach round trip for a new session of a worker of the named definition, spawning a
    /// gateway first when none is current. The session is built on the worker's wake set
    /// (`egress_shared.createSessionForWorker`), at its launch and at every reattach alike, since
    /// the worker's io_uring registers that set's completion eventfd and liveness pipe at boot and
    /// no other file afterwards. Only the launcher thread calls it, so one attach waits at a time.
    /// A nack fails this call alone with `error.EgressGatewayAttachRejected`; any other failure
    /// fails the channel: the gateway is retired, `Deps.gatewayLost` runs, and the call fails with
    /// `error.EgressGatewayUnavailable`. A spawn that fails, or session descriptors the server
    /// cannot create, fail the call with their own error and leave the gateway alone. The
    /// attachment owns the worker's half of the session, as WorkerInit and `egress_attach` carry
    /// it.
    pub fn attachWorker(
        self: *Manager,
        definition_name: []const u8,
        wake_set: *const egress_shared.WakeSet,
    ) !lifecycle.EgressGatewayAttachment {
        std.debug.assert(definition_name.len != 0);
        self.serial.lock();
        defer self.serial.unlock();
        const record = try self.currentRecord();
        var session = try egress_shared.createSessionForWorker(wake_set);
        defer session.deinit();
        const session_id = try attachSession(
            record,
            securityCellIdForDefinition(definition_name),
            session.rawForGateway(),
        );
        // The gateway holds its own copies of its half by its ack, so the server keeps only the
        // worker's: taking it closes the server's copy of the gateway's end of the pipe the
        // worker watches, which leaves the gateway's the only one, and the gateway's death hangs
        // the worker up.
        return workerAttachment(session.takeWorkerHalf(), record.generation, session_id);
    }

    /// The current gateway's generation, 0 while none is current: an atomic load, which a lane
    /// compares with its lease once per loop pass.
    pub fn currentGeneration(self: *const Manager) u64 {
        return self.current_generation.load(.acquire);
    }

    /// Hands `lease` the current gateway's generation, a copy of its key and a dup of its control
    /// socket made with `F_DUPFD_CLOEXEC` (`Lease.replace`), or generation 0 and no descriptor when
    /// none is current. It takes the mutex, so a lane calls it only when `currentGeneration` moved.
    /// A lease that already holds the current gateway keeps its descriptor and pending entries. A
    /// dup that fails leaves the lease empty, so the lane asks again on its next pass.
    pub fn renewLease(self: *Manager, lease: *lease_mod.Lease) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const record = self.current orelse {
            if (lease.generation != 0)
                lease.replace(0, no_key, .{});
            return;
        };
        if (lease.generation == record.generation)
            return;
        const control_fd = fd_mod.OwnedFd.dupCloexec(record.process.control_fd) catch |err| {
            self.lease_renewals_failed += 1;
            if (self.lease_renewal_failure_logged_generation != record.generation) {
                self.lease_renewal_failure_logged_generation = record.generation;
                std.log.warn("egress gateway lease renewal failed generation={d}: {s}; fetches go without tokens until a renewal succeeds", .{
                    record.generation,
                    @errorName(err),
                });
            }
            lease.replace(0, no_key, .{});
            return;
        };
        lease.replace(record.generation, record.key, control_fd);
    }

    /// Copies the key of gateway `generation` into `out` and returns true, or returns false when
    /// that gateway is no longer current. The launcher's boot tokens are minted with it.
    pub fn keyFor(self: *Manager, generation: u64, out: *egress_token.Key) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const record = self.current orelse return false;
        if (record.generation != generation)
            return false;
        out.* = record.key;
        return true;
    }

    /// Sends one `request_ended` entry to gateway `generation` now, under the mutex, best effort:
    /// nothing goes out when that gateway is gone, and a refused send is counted. The launcher ends
    /// each boot token with it at `WorkerReady`.
    pub fn requestEnded(self: *Manager, generation: u64, entry: control.RequestEndedEntry) void {
        // The gateway's decoder refuses a packet with an entry of any other shape
        // (`control.RequestEndedEntry`), so one is a server bug.
        std.debug.assert(entry.session_id != 0);
        if (entry.request_id == 0) std.debug.assert(entry.request_generation == 0);
        if (entry.request_id != 0) std.debug.assert(entry.request_generation != 0);

        self.mutex.lock();
        defer self.mutex.unlock();
        const record = self.current orelse return;
        if (record.generation != generation)
            return;
        // `sendAndClear` empties the batch whatever the send does.
        std.debug.assert(self.ended.isEmpty());
        const appended = self.ended.append(entry);
        std.debug.assert(appended);
        self.ended.sendAndClear(record.process.control_fd) catch |err| switch (err) {
            error.WouldBlock => self.ended_batches_dropped_full += 1,
            else => self.ended_batches_dropped_closed += 1,
        };
    }

    /// The current record, after destroying the retired one and spawning a gateway when none is
    /// current. The caller holds `serial`.
    fn currentRecord(self: *Manager) !*Record {
        self.mutex.lock();
        if (self.current) |record| {
            std.debug.assert(self.retired == null);
            self.mutex.unlock();
            return record;
        }
        const retired = self.retired;
        self.retired = null;
        self.mutex.unlock();

        if (retired) |record|
            self.destroyRecord(record, .no_wait);
        return self.spawnRecord();
    }

    /// Spawns a gateway and makes its record current. The caller holds `serial`.
    fn spawnRecord(self: *Manager) !*Record {
        const record = try self.allocator.create(Record);
        errdefer self.allocator.destroy(record);
        record.* = .{
            .manager = self,
            .process = undefined,
            .generation = 0,
            .key = egress_token.Key.random(),
        };
        errdefer std.crypto.secureZero(u8, &record.key.bytes);
        record.process = try process_mod.spawn(self.allocator, .{
            .executable_path = self.config.executable_path,
            .key = record.key,
            .table = &self.policy_table,
        });
        errdefer record.process.deinit();
        record.generation = self.nextGatewayGeneration();

        // Current before its reader starts, so a failure the reader sees always finds the record
        // current and retires it.
        self.mutex.lock();
        std.debug.assert(self.current == null);
        std.debug.assert(self.retired == null);
        self.current = record;
        self.current_generation.store(record.generation, .release);
        self.mutex.unlock();
        errdefer {
            self.mutex.lock();
            std.debug.assert(self.current == record);
            self.current = null;
            self.current_generation.store(0, .release);
            self.mutex.unlock();
        }

        try record.control.init(self.allocator, record.process.control_fd, .{
            .ctx = record,
            .failed = controlFailedCallback,
            .session_removed = sessionRemovedCallback,
        });
        return record;
    }

    /// The control client's `session_removed` callback: passes the report of `record`'s gateway
    /// to the launcher, on the record's reader thread.
    fn reportSessionLost(self: *Manager, record: *Record, session_id: u64) void {
        self.deps_mutex.lock();
        defer self.deps_mutex.unlock();
        if (self.deps) |deps|
            deps.sessionLost(deps.ctx, record.generation, session_id);
    }

    /// The control client's `failed` callback: retires `record` and tells the launcher, on the
    /// reader thread or the thread whose attach failed.
    fn retireAfterFailure(self: *Manager, record: *Record, err: anyerror) void {
        self.mutex.lock();
        if (self.current != record) {
            // `deinit` took the record and destroys it.
            self.mutex.unlock();
            return;
        }
        std.debug.assert(self.retired == null);
        self.current = null;
        self.retired = record;
        self.current_generation.store(0, .release);
        record.process.kill();
        self.mutex.unlock();

        std.log.warn("egress gateway generation={d} pid={d} retired: {s}", .{
            record.generation,
            record.process.pid,
            @errorName(err),
        });
        self.deps_mutex.lock();
        defer self.deps_mutex.unlock();
        if (self.deps) |deps|
            deps.gatewayLost(deps.ctx, record.generation);
    }

    /// Joins the record's reader, stops its gateway as `mode` says and frees the record, which is
    /// in neither `current` nor `retired`. The caller holds `serial`, so no attach uses it.
    fn destroyRecord(self: *Manager, record: *Record, mode: enum { wait, no_wait }) void {
        // The join comes before the socket the reader polls closes.
        record.control.deinit();
        switch (mode) {
            .wait => record.process.deinit(),
            .no_wait => record.process.deinitNoWait(),
        }
        std.crypto.secureZero(u8, &record.key.bytes);
        self.allocator.destroy(record);
    }

    fn nextGatewayGeneration(self: *Manager) u64 {
        const generation = self.next_gateway_generation;
        self.next_gateway_generation +%= 1;
        if (self.next_gateway_generation == 0)
            self.next_gateway_generation = 1;
        return generation;
    }
};

/// One gateway process with its control client, generation and token key. Heap-allocated, because
/// its reader and the client's `failed` callback point at it.
const Record = struct {
    manager: *Manager,
    process: process_mod.GatewayProcess,
    control: control_client.Client = .{},
    generation: u64,
    key: egress_token.Key,
};

fn controlFailedCallback(ctx: *anyopaque, err: anyerror) void {
    const record: *Record = @ptrCast(@alignCast(ctx));
    record.manager.retireAfterFailure(record, err);
}

fn sessionRemovedCallback(ctx: *anyopaque, session_id: u64) void {
    const record: *Record = @ptrCast(@alignCast(ctx));
    record.manager.reportSessionLost(record, session_id);
}

/// The attach round trip of a session whose gateway half is `gateway_half`, returning the session
/// id the gateway assigned. A nack stays `error.EgressGatewayAttachRejected`; any other error
/// failed the channel, the client's `failed` callback retires the record, and the call fails
/// with `error.EgressGatewayUnavailable`.
fn attachSession(
    record: *Record,
    security_cell_id: control.SecurityCellId,
    gateway_half: egress_shared.RawFds,
) !u64 {
    return record.control.attachWorker(security_cell_id, gateway_half) catch |err| switch (err) {
        error.EgressGatewayAttachRejected => return err,
        else => return error.EgressGatewayUnavailable,
    };
}

/// The worker's half `half` of session `session_id` of gateway `generation` as an attachment,
/// which takes every descriptor: the ones `SessionFds.rawForWorker` in
/// `common/ipc/egress_shared/session_fds.zig` names, with the access each one grants.
fn workerAttachment(half: egress_shared.RawFds, generation: u64, session_id: u64) lifecycle.EgressGatewayAttachment {
    std.debug.assert(half.isValid());
    return .{
        .command_control = fd_mod.OwnedFd.fromRaw(half.command_control_fd),
        .command_producer = fd_mod.OwnedFd.fromRaw(half.command_producer_fd),
        .command_consumer = fd_mod.OwnedFd.fromRaw(half.command_consumer_fd),
        .command_data = fd_mod.OwnedFd.fromRaw(half.command_data_fd),
        .completion_control = fd_mod.OwnedFd.fromRaw(half.completion_control_fd),
        .completion_producer = fd_mod.OwnedFd.fromRaw(half.completion_producer_fd),
        .completion_consumer = fd_mod.OwnedFd.fromRaw(half.completion_consumer_fd),
        .completion_data = fd_mod.OwnedFd.fromRaw(half.completion_data_fd),
        .body_pool_control = fd_mod.OwnedFd.fromRaw(half.body_pool_control_fd),
        .body_pool_producer = fd_mod.OwnedFd.fromRaw(half.body_pool_producer_fd),
        .body_pool_consumer = fd_mod.OwnedFd.fromRaw(half.body_pool_consumer_fd),
        .body_pool_data = fd_mod.OwnedFd.fromRaw(half.body_pool_data_fd),
        .upload_pool_control = fd_mod.OwnedFd.fromRaw(half.upload_pool_control_fd),
        .upload_pool_producer = fd_mod.OwnedFd.fromRaw(half.upload_pool_producer_fd),
        .upload_pool_consumer = fd_mod.OwnedFd.fromRaw(half.upload_pool_consumer_fd),
        .upload_pool_data = fd_mod.OwnedFd.fromRaw(half.upload_pool_data_fd),
        .command_event = fd_mod.OwnedFd.fromRaw(half.command_eventfd),
        .completion_event = fd_mod.OwnedFd.fromRaw(half.completion_eventfd),
        .liveness = fd_mod.OwnedFd.fromRaw(half.liveness_fd),
        .peer_liveness = fd_mod.OwnedFd.fromRaw(half.peer_liveness_fd),
        .generation = generation,
        .session_id = session_id,
    };
}

/// The security cell of every worker of the named definition: the first
/// 16 bytes of SHA-256 over a domain-separation label and the name. A
/// definition's name is unique in the configuration and fixed for the life
/// of the process, so the cell is too.
pub fn securityCellIdForDefinition(definition_name: []const u8) control.SecurityCellId {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("collo-egress-security-cell-v2");
    hasher.update(definition_name);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    var id: control.SecurityCellId = undefined;
    @memcpy(id[0..], digest[0..id.len]);
    return id;
}

// The supervisor's egress gateway hooks (`EgressGatewayHooks` in `server/supervisor/supervisor.zig`),
// each taking the `*Manager` as `ctx`.

pub fn attachWorkerCallback(
    ctx: *anyopaque,
    definition_name: []const u8,
    wake_set: *const egress_shared.WakeSet,
) anyerror!lifecycle.EgressGatewayAttachment {
    const manager: *Manager = @ptrCast(@alignCast(ctx));
    return manager.attachWorker(definition_name, wake_set);
}

pub fn currentGenerationCallback(ctx: *anyopaque) u64 {
    const manager: *const Manager = @ptrCast(@alignCast(ctx));
    return manager.currentGeneration();
}

pub fn keyForCallback(ctx: *anyopaque, generation: u64, out: *egress_token.Key) bool {
    const manager: *Manager = @ptrCast(@alignCast(ctx));
    return manager.keyFor(generation, out);
}

pub fn prewarmCallback(ctx: *anyopaque) anyerror!void {
    const manager: *Manager = @ptrCast(@alignCast(ctx));
    try manager.prewarm();
}

/// Ends the boot token of session `session_id` of gateway `generation`, whose `request_ended`
/// entry has request id and generation 0.
pub fn bootEndedCallback(ctx: *anyopaque, generation: u64, session_id: u64) void {
    const manager: *Manager = @ptrCast(@alignCast(ctx));
    manager.requestEnded(generation, .{
        .session_id = session_id,
        .request_id = 0,
        .request_generation = 0,
    });
}
