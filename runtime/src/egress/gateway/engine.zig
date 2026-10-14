//! One shard's transport engine in the egress gateway: the outbound engine
//! (`collo_egress_client`) whose threads run the shard's fetches, the eventfd
//! they wake the gateway's loop with, and the ring of ready tasks
//! (`ready_scan.zig`). It keeps no record of the fetches it runs: the gateway's
//! fetch table does (`fetch_table.zig`), and each task carries its record's
//! handle, which the engine's threads copy into the wake tokens they queue.
//!
//! The engine never reads the token in a start packet. The loop admits each
//! fetch under its verified token and passes what the token grants with the
//! submit (`Grant`): the request the fetch belongs to, its deadline, its pool
//! key and its network policy. The transport takes that policy as the fetch's
//! own configuration and checks the scheme, host and port before DNS and every
//! resolved address after it, on every hop, redirects included.
//!
//! The gateway's loop thread owns the `Engine`. The inner engine's threads
//! touch only tasks, response queues and `wake`, which queues a ready task and
//! writes `wake_fd`. A restart runs the inner engine again on the threads and
//! rings it booted with, since the gateway's seccomp filter forbids creating
//! new ones (`runtime/shard_flow.zig`).

const std = @import("std");
const http = @import("collo_http");
const ipc = @import("collo_ipc");
const egress = @import("collo_egress_client");

const policy_mod = @import("policy.zig");
const ready_scan = @import("ready_scan.zig");
const sizing = @import("sizing.zig");

const body_credit = egress.body_credit;
const ResponseQueue = egress.core.ResponseQueue;
const task_model = egress.task;
const transport = egress.transport;

pub const Config = struct {
    /// The most HTTP/2 streams and HTTP/1 fetches the inner engine runs at once, each holding one
    /// credit source (`egress/client/engine/credit_sources.zig`). The default is what admission
    /// lets every session run (`production_sources_max`); a fetch past it fails alone with
    /// `error.EgressEngineSourcesExhausted`, which only the canceled fetches of a removed session
    /// that the owner has not dropped yet can bring about.
    sources_max: usize = production_sources_max,
    policy: policy_mod.Policy = policy_mod.production,
    /// Capacity of the ready-task ring. A full ring drops no token, it asks for a scan of the
    /// shard instead (`ready_scan.zig`), so the capacity bounds the ring's memory, not what a
    /// pass sees.
    ready_event_capacity: usize = 1024,
};

/// Fetches every session of one gateway may run at once, all of which may hash to one shard.
pub const production_sources_max: usize =
    policy_mod.production.max_active_fetches_per_worker_session * sizing.sessions_max;

comptime {
    std.debug.assert(production_sources_max <= egress.engine.credit_sources.capacity_max);
}

/// What admission granted a fetch. Every field decides what the fetch may reach, whose request
/// it serves or how long it may run, so none has a default.
pub const Grant = struct {
    /// The pool key: the fetch's security cell and its policy's pool id.
    isolation: policy_mod.PoolIsolation,
    /// The policy the fetch's token names, checked on every hop. It points into the gateway's
    /// decoded table, which outlives every fetch.
    network: egress.network.Policy,
    /// The request the token names, which the response body's identity carries.
    request_id: u64,
    request_generation: u64,
    /// The token's deadline, which bounds the whole fetch; 0 for none, which only tests use.
    deadline_mono_ns: u64,
    /// The response body cap admission resolved (`policy.checkStart`).
    max_response_body_bytes: usize,
};

/// What `submit` hands the gateway's record: the task with the reference the record holds, the
/// response queue with the record's reference, and the engine run the task belongs to, which
/// every credit of the fetch carries back (`Engine.releaseCredit`).
pub const Running = struct {
    task: *task_model.Task,
    queue: *ResponseQueue,
    run: Run,
};

/// An engine run's number: the first `start` begins run 1, and each later one the next. A
/// credit names the run that issued it, and a credit of a run that ended reaches nothing of the
/// run that follows. The count wraps after 2^32 starts, which the restart backstop
/// (`containment.shard_restart`) keeps beyond any gateway's life.
pub const Run = u32;

pub const Engine = struct {
    /// The shard's counting allocator; everything the engine and its tasks allocate counts
    /// against the shard's budget (`containment.shard_memory`).
    allocator: std.mem.Allocator,
    inner: egress.Engine,
    wake_fd: std.posix.fd_t,
    policy: policy_mod.Policy,
    ready: ready_scan.Scan,
    /// The current run, or the last one while the engine is stopped; 0 before the first start.
    run: Run = 0,
    /// Credits handed to the inner engine, and the HTTP/2 window bytes they carried, counted on
    /// the gateway's loop thread, which alone returns credits.
    credits_returned: u64 = 0,
    credit_bytes_returned: u64 = 0,
    /// Credits of a run that ended, which `releaseCredit` dropped.
    stale_credits_dropped: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Engine {
        const wake_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        errdefer std.posix.close(wake_fd);
        var inner = try egress.Engine.init(allocator, config.sources_max);
        errdefer inner.deinit();
        var ready = try ready_scan.Scan.init(allocator, config.ready_event_capacity);
        errdefer ready.deinit(allocator);
        return .{
            .allocator = allocator,
            .inner = inner,
            .wake_fd = wake_fd,
            .policy = config.policy,
            .ready = ready,
        };
    }

    /// Stops the inner engine, joins its threads and frees the engine. The gateway has released
    /// every record's task and queue before, so the engine's own references are the last.
    pub fn deinit(self: *Engine) void {
        self.inner.stop();
        self.inner.deinit();
        self.ready.deinit(self.allocator);
        std.posix.close(self.wake_fd);
        self.* = undefined;
    }

    /// Begins the next run of a stopped inner engine. Only the first call creates threads and
    /// rings, so a restart under the gateway's seccomp filter creates neither.
    pub fn start(self: *Engine) !void {
        try self.inner.start(self, wake);
        self.run +%= 1;
    }

    /// Ends the current run. Once it returns, the inner engine has settled every task it held and
    /// no engine thread touches a task or queue until the next `start`.
    pub fn stop(self: *Engine) void {
        self.inner.stop();
    }

    /// Empties a stopped engine for its next run: drops the ready ring, whose tokens name tasks
    /// of the run that ended, and any pending wake.
    pub fn clearForRestart(self: *Engine) void {
        self.ready.clear();
        drainWakeFd(self.wake_fd);
    }

    /// Creates the fetch's response queue and task and submits the task to the inner engine.
    /// `handle` is the fetch's record in the gateway's table, which every wake token of the task
    /// carries; it is never 0. The engine owns `owned_body`, an assembled pooled-upload body
    /// with its allocator, from the call on: the task takes it without a copy, and every error
    /// path frees it with that allocator, so the shard's counting allocator never frees bytes it
    /// did not count. `fetch.body` must be empty when `owned_body` is set. Fails with
    /// `error.OutOfMemory` at the shard's budget, with what the inner engine's submit fails with,
    /// or with `error.TooManyFetchHeaders` for more headers than the IPC carries; nothing is
    /// left behind.
    pub fn submit(
        self: *Engine,
        handle: u64,
        fetch: ipc.EgressFetchStartView,
        grant: Grant,
        owned_body: ?task_model.OwnedBody,
    ) !Running {
        std.debug.assert(handle != 0);
        std.debug.assert(owned_body == null or fetch.body.len == 0);
        var owned_body_transferred = false;
        errdefer if (owned_body) |owned| {
            if (!owned_body_transferred)
                owned.allocator.free(owned.bytes);
        };
        if (fetch.headers.len > ipc.max_request_header_count)
            return error.TooManyFetchHeaders;
        var header_storage: [ipc.max_request_header_count]http.Header = undefined;
        for (fetch.headers, 0..) |header, index|
            header_storage[index] = .{ .name = header.name, .value = header.value };

        const identity = egress.core.FetchBodyIdentity{
            .request_id = grant.request_id,
            .request_generation = grant.request_generation,
            .fetch_id = fetch.fetch_id,
            .body_id = fetch.body_id,
        };
        const queue = try self.allocator.create(ResponseQueue);
        queue.* = ResponseQueue.init(identity, @as(u64, grant.max_response_body_bytes));
        // The record's reference, which the gateway drops when the fetch ends.
        errdefer queue.release(self.allocator);

        const task = try self.allocator.create(task_model.Task);
        var task_initialized = false;
        errdefer if (!task_initialized) self.allocator.destroy(task);
        // The task's reference: the task takes it over when its init succeeds, and its last
        // release drops it.
        queue.retain();
        errdefer if (!task_initialized) queue.release(self.allocator);
        task.* = if (owned_body) |owned|
            try task_model.Task.initOwnedBody(
                self.allocator,
                fetch.fetch_id,
                fetch.url,
                fetch.method,
                owned,
                header_storage[0..fetch.headers.len],
                fetch.flags,
                queue,
            )
        else
            try task_model.Task.init(
                self.allocator,
                fetch.fetch_id,
                fetch.url,
                fetch.method,
                fetch.body,
                header_storage[0..fetch.headers.len],
                fetch.flags,
                queue,
            );
        task_initialized = true;
        owned_body_transferred = true;
        errdefer task.release();

        const config = transport.Config{
            .network = grant.network,
            .max_response_body_bytes = grant.max_response_body_bytes,
            .max_encoded_response_bytes = @min(self.policy.max_encoded_response_bytes, grant.max_response_body_bytes),
            .socket_timeout_ms = self.policy.socket_timeout_ms,
            .request_deadline_mono_ns = grant.deadline_mono_ns,
            .enable_http2 = self.policy.enable_http2,
            .max_redirects = self.policy.max_redirects,
            .max_redirect_drain_bytes = self.policy.max_redirect_drain_bytes,
            .pool_security_cell_id = grant.isolation.security_cell_id,
            .pool_policy_id = grant.isolation.policy_id,
        };
        std.debug.assert(!config.insecure_tls);
        try self.inner.submit(.{ .task = task, .config = config, .ready_generation = handle });
        return .{ .task = task, .queue = queue, .run = self.run };
    }

    /// Cancels a running fetch: the inner engine's owner closes whatever holds it (a dial, a
    /// stream, an exchange) and lets go of it, settling the task before its head or ending the
    /// response queue after it, and either wakes the gateway. A fetch the engine already let go
    /// of is left alone (`runtime/fetch_flow.zig` reads when it has).
    pub fn cancel(self: *Engine, task: *task_model.Task) void {
        self.inner.cancel(task);
    }

    /// Returns a flow-control credit of run `run` to the inner engine, which reopens the window
    /// or resumes the body read it names. A credit of a run that ended is dropped here, and
    /// counted: it names no live credit source of the inner engine, which would drop it too, so
    /// neither guard relies on the other. Within a run, the inner engine drops a credit whose
    /// stream or HTTP/1 fetch ended, and one worth more than its stream holds.
    pub fn releaseCredit(self: *Engine, run: Run, credit: body_credit.Handle) void {
        if (credit.isNone())
            return;
        if (run != self.run) {
            self.stale_credits_dropped += 1;
            return;
        }
        self.credits_returned += 1;
        switch (credit) {
            .h2_data => |h2| self.credit_bytes_returned += h2.encoded_bytes,
            .none, .h1_resume => {},
        }
        self.inner.releaseFetchBodyCredit(credit);
    }

    /// Drains the wake eventfd and moves up to `out.len` ready tokens into `out`
    /// (`ready_scan.Scan.drain`). The caller writes the eventfd again when it leaves tokens
    /// behind (`signalWake`).
    pub fn drainReady(self: *Engine, out: []ready_scan.Event) ready_scan.Drain {
        drainWakeFd(self.wake_fd);
        return self.ready.drain(out);
    }

    /// A fatal error that escaped the inner engine's owner loop since the last call, such as an
    /// allocation that failed at the shard's budget while it rebuilt its watch list.
    pub fn takeOwnerFault(self: *Engine) ?anyerror {
        return self.inner.takeOwnerFault();
    }

    /// Brings the gateway's loop back to this shard on its next pass.
    pub fn signalWake(self: *Engine) void {
        signalWakeFd(self.wake_fd);
    }
};

/// The inner engine's wake callback, which its threads call when a task becomes ready or every
/// fetch of the shard needs a look.
fn wake(ctx: ?*anyopaque, event: egress.WakeEvent) void {
    const engine: *Engine = @ptrCast(@alignCast(ctx orelse return));
    // Only the transition from empty to non-empty writes the eventfd. A non-empty ring already
    // has a wake pending, or a drain pass running that will take the entry, so a write per event
    // would only add syscalls.
    const should_signal = switch (event) {
        .generic => engine.ready.requestScan(),
        .task_ready => |task| engine.ready.enqueueTask(task),
    };
    if (should_signal)
        signalWakeFd(engine.wake_fd);
}

fn signalWakeFd(fd: std.posix.fd_t) void {
    var one: u64 = 1;
    _ = std.posix.write(fd, std.mem.asBytes(&one)) catch |err| switch (err) {
        // A full counter already wakes the loop.
        error.WouldBlock => return,
        else => |unexpected| {
            std.log.warn("egress gateway wake write failed: {s}", .{@errorName(unexpected)});
            return;
        },
    };
}

fn drainWakeFd(fd: std.posix.fd_t) void {
    var value: u64 = 0;
    _ = std.posix.read(fd, std.mem.asBytes(&value)) catch |err| switch (err) {
        // An empty counter has nothing to drain.
        error.WouldBlock => return,
        else => |unexpected| {
            std.log.warn("egress gateway wake drain failed: {s}", .{@errorName(unexpected)});
            return;
        },
    };
}
