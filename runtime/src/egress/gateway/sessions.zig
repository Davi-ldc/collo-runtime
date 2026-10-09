//! One worker session attached to the gateway: its shared-memory endpoint, the security cell the
//! server attached it under, the fetch budgets of the egress tokens it presented, the invalid
//! commands it sent in the current window, its backpressure state, and the slot ledger that maps
//! each body-pool extent it holds back to a fetch and a flow-control credit.
//! `worker_registry.zig` owns sessions, and only the gateway's loop thread touches them.
//!
//! A session's budgets live and die with its record (`budgets.zig`), so removing the session
//! frees them and nothing else holds a budget to clean up.
//!
//! The pool authenticates a released extent by the generation in its handle, but only the slot
//! ledger knows which fetch and credit the extent belongs to. A release the ledger cannot match is
//! the session's fault, and the gateway drops the session (`runtime/body_release_flow.zig`).

const std = @import("std");
const ipc = @import("collo_ipc");

const backpressure = @import("backpressure.zig");
const body_credit = @import("collo_egress_client").body_credit;
const budgets = @import("budgets.zig");
const policy_mod = @import("policy.zig");

/// One slot ledger entry, indexed by body-pool slot: written when the gateway publishes body
/// bytes into the slot, consumed when the worker returns the extent. An all-zero entry is empty.
pub const SlotCredit = struct {
    generation: u32 = 0,
    len: u32 = 0,
    fetch_id: u64 = 0,
    body_id: u64 = 0,
    credit: body_credit.Handle = .none,
};

pub const SlotCreditResult = union(enum) {
    ok: SlotCredit,
    empty,
    mismatch,
};

/// A worker may send `max_invalid_commands_per_window` invalid commands in a window of
/// `invalid_command_window_ns` that opens with the first of them; the next one ends its session.
pub const invalid_command_window_ns: u64 = 60 * std.time.ns_per_s;
pub const max_invalid_commands_per_window: u32 = 1024;

pub const InvalidCommandWindow = struct {
    count: u32 = 0,
    start_monotonic_ns: u64 = 0,

    /// Counts one invalid command at `now_ns` and returns whether the worker is still within its
    /// budget.
    pub fn record(self: *InvalidCommandWindow, now_ns: u64) bool {
        if (self.start_monotonic_ns == 0 or
            now_ns < self.start_monotonic_ns or
            now_ns - self.start_monotonic_ns >= invalid_command_window_ns)
        {
            self.start_monotonic_ns = now_ns;
            self.count = 0;
        }
        self.count +|= 1;
        return self.count <= max_invalid_commands_per_window;
    }
};

pub const Worker = struct {
    session_id: u64,
    security_cell_id: policy_mod.PoolIsolationId,
    endpoint: ipc.egress_shared.Endpoint,
    /// Serializes publications into `endpoint` (`publisher.zig`).
    publish_mutex: std.Thread.Mutex = .{},
    /// A completion-eventfd write owed to this worker, held until the end of the gateway's
    /// current shard-ready pass so that the pass costs the worker one wake instead of one per
    /// packet (`runtime/shard_flow.zig`). The worker coalesces its own release notifications the
    /// same way (`releases_need_notify`).
    completion_notify_pending: bool = false,
    /// What each token this session presented still admits, from its first verified fetch
    /// (`SessionBudgets.take` in `runtime/worker_flow.zig`) to its `request_ended`
    /// (`runtime/control_flow.zig`).
    budgets: budgets.SessionBudgets = .{},
    invalid_commands: InvalidCommandWindow = .{},
    backpressure_level: backpressure.Level = .normal,
    /// When the worker reached `hard`, or 0 while it is below.
    hard_pressure_since_ns: u64 = 0,
    /// Whether the current stay at `hard` has already canceled the worker's fetches.
    hard_pressure_cancel_sent: bool = false,
    /// The command ring's `dropped_packets` at the last drain (`wakeWorkerAfterCommandDrops` in
    /// `runtime/worker_flow.zig`).
    last_seen_command_drops: u64 = 0,
    /// The slot ledger.
    body_slot_credits: [ipc.egress_shared.body_pool_slot_count]SlotCredit = @splat(.{}),

    pub fn deinit(self: *Worker, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.endpoint.deinit();
        self.* = undefined;
    }

    pub fn pressure(self: *const Worker) policy_mod.WorkerPressure {
        return backpressure.pressureForLevel(self.backpressure_level);
    }

    pub fn recordInvalidCommandAt(self: *Worker, now_ns: u64) bool {
        return self.invalid_commands.record(now_ns);
    }

    pub fn recordSlotCredit(
        self: *Worker,
        handle: ipc.egress_shared.BodyPoolHandle,
        len: u32,
        fetch_id: u64,
        body_id: u64,
        credit: body_credit.Handle,
    ) void {
        const index = ipc.egress_shared.slotIndexForHandle(handle) catch {
            // Our own freshly published handle cannot be malformed.
            unreachable;
        };
        self.body_slot_credits[index] = .{
            .generation = @intCast(handle >> 32),
            .len = len,
            .fetch_id = fetch_id,
            .body_id = body_id,
            .credit = credit,
        };
    }

    /// Takes and clears the ledger entry of an extent the worker released. `.empty` and
    /// `.mismatch` mean the worker released something the gateway never published to it in that
    /// slot, and the caller drops the session.
    pub fn takeSlotCredit(
        self: *Worker,
        extent: ipc.egress_shared.BodyPoolView.ReleasedExtent,
    ) SlotCreditResult {
        const index = ipc.egress_shared.slotIndexForHandle(extent.handle) catch return .mismatch;
        const entry = self.body_slot_credits[index];
        if (slotCreditIsEmpty(entry))
            return .empty;
        self.body_slot_credits[index] = .{};
        if (entry.generation != @as(u32, @intCast(extent.handle >> 32)) or entry.len != extent.len)
            return .mismatch;
        return .{ .ok = entry };
    }
};

fn slotCreditIsEmpty(entry: SlotCredit) bool {
    return entry.generation == 0 and
        entry.len == 0 and
        entry.fetch_id == 0 and
        entry.body_id == 0 and
        entry.credit.isNone();
}
