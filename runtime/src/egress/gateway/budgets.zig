//! The fetch budgets of one worker session: for each egress token the session presented, how
//! many more fetches the gateway admits under it. A budget starts at the token's first verified
//! fetch with the token's own budget and deadline, and ends at the token's `request_ended`, at the
//! end of the session, or when the session needs its slot. Budgets a lost `request_ended` left
//! behind therefore never block an honest request, and a token that comes back after its budget
//! ended starts a new one, so a dishonest worker gains fetches only under its own tokens'
//! policies, until their deadlines, within the session's cap on active fetches.
//!
//! The session record holds its budgets (`sessions.Worker.budgets`), and only the gateway's loop
//! thread touches them. Nothing sweeps: a budget whose deadline has passed is a free slot, since
//! admission refuses its token before it looks for a budget.

const std = @import("std");
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");

const control = @import("control.zig");
const sizing = @import("sizing.zig");

const egress_token = ipc.egress_token;

/// Budgets one session holds at once: room for each request the worker can have in flight
/// (`worker_concurrency_max`) and its boot token, four times over for budgets whose
/// `request_ended` was lost. A session that needs another evicts the one with the earliest
/// deadline, which belongs to the oldest request.
pub const per_session_max: usize = 4 * (limits.server.worker_concurrency_max + 1);

/// Budgets one gateway holds at once, every slot of every session it can attach.
pub const per_gateway_max: usize = sizing.workers_max * per_session_max;

/// A token's budget as the rest of the gateway names it: the session that presented it and the
/// request it names. Fetch records keep it so `request_ended` can cancel their request's fetches.
pub const BudgetKey = struct {
    session_id: u64,
    request_id: u64,
    request_generation: u64,

    pub fn ofToken(fields: egress_token.Fields) BudgetKey {
        return .{
            .session_id = fields.session_id,
            .request_id = fields.request_id,
            .request_generation = fields.request_generation,
        };
    }

    pub fn ofEnded(entry: control.RequestEndedEntry) BudgetKey {
        return .{
            .session_id = entry.session_id,
            .request_id = entry.request_id,
            .request_generation = entry.request_generation,
        };
    }

    /// A boot token's key, whose request id and generation are both 0.
    pub fn isBoot(self: BudgetKey) bool {
        return self.request_id == 0;
    }
};

/// One slot; a zero deadline marks it free.
const Budget = struct {
    request_id: u64 = 0,
    request_generation: u64 = 0,
    deadline_monotonic_ns: u64 = 0,
    remaining: u32 = 0,
    /// The token's budget, which a refund never exceeds.
    budget: u32 = 0,
};

pub const Take = enum {
    /// One fetch was taken from the budget.
    taken,
    /// The budget has no fetch left; the worker spent its token's budget.
    exhausted,
    /// A boot token after its `request_ended`.
    boot_ended,
};

pub const SessionBudgets = struct {
    slots: [per_session_max]Budget = @splat(.{}),
    /// Set by the `request_ended` of the session's boot token, after which the session's boot
    /// token admits nothing although its deadline has not passed.
    boot_ended: bool = false,

    /// Takes one fetch under the token `fields` describes, which `verify` accepted for this
    /// session and which has not expired at `now_monotonic_ns`. Finds its budget or starts one,
    /// evicting the budget with the earliest deadline when every slot is live.
    pub fn take(self: *SessionBudgets, fields: egress_token.Fields, now_monotonic_ns: u64) Take {
        const deadline = fields.deadline_monotonic_ns;
        std.debug.assert(!egress_token.deadlinePassed(deadline, now_monotonic_ns));
        if (fields.kind == .boot and self.boot_ended)
            return .boot_ended;
        const found = self.find(fields.request_id, fields.request_generation, now_monotonic_ns);
        const slot = found orelse self.start(fields, now_monotonic_ns);
        if (slot.remaining == 0)
            return .exhausted;
        slot.remaining -= 1;
        return .taken;
    }

    /// Gives back one fetch taken under `key` that never reached an engine. A budget that ended
    /// meanwhile gets nothing back.
    pub fn refund(self: *SessionBudgets, key: BudgetKey, now_monotonic_ns: u64) void {
        const found = self.find(key.request_id, key.request_generation, now_monotonic_ns);
        const slot = found orelse return;
        if (slot.remaining < slot.budget)
            slot.remaining += 1;
    }

    /// Ends the budget `request_ended` names, if the session has one. Ending a boot token's
    /// budget also refuses that token from now on.
    pub fn end(self: *SessionBudgets, key: BudgetKey) void {
        if (key.isBoot())
            self.boot_ended = true;
        for (&self.slots) |*slot| {
            if (slot.deadline_monotonic_ns != 0 and
                slot.request_id == key.request_id and
                slot.request_generation == key.request_generation)
            {
                slot.* = .{};
                return;
            }
        }
    }

    fn find(
        self: *SessionBudgets,
        request_id: u64,
        request_generation: u64,
        now_monotonic_ns: u64,
    ) ?*Budget {
        for (&self.slots) |*slot| {
            if (!isLive(slot, now_monotonic_ns))
                continue;
            if (slot.request_id == request_id and slot.request_generation == request_generation)
                return slot;
        }
        return null;
    }

    fn start(self: *SessionBudgets, fields: egress_token.Fields, now_monotonic_ns: u64) *Budget {
        var target = &self.slots[0];
        for (&self.slots) |*slot| {
            if (!isLive(slot, now_monotonic_ns)) {
                target = slot;
                break;
            }
            if (slot.deadline_monotonic_ns < target.deadline_monotonic_ns)
                target = slot;
        }
        target.* = .{
            .request_id = fields.request_id,
            .request_generation = fields.request_generation,
            .deadline_monotonic_ns = fields.deadline_monotonic_ns,
            .remaining = fields.budget,
            .budget = fields.budget,
        };
        return target;
    }

    fn isLive(slot: *const Budget, now_monotonic_ns: u64) bool {
        if (slot.deadline_monotonic_ns == 0)
            return false;
        return !egress_token.deadlinePassed(slot.deadline_monotonic_ns, now_monotonic_ns);
    }
};

comptime {
    std.debug.assert(per_session_max >= limits.server.worker_concurrency_max + 1);
}
