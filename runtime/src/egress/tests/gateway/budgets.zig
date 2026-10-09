//! The fetch budgets of one worker session (`egress/gateway/budgets.zig`): a budget starts at its
//! token's first fetch with the token's own budget and deadline, runs out, takes refunds up to that
//! budget and no further, and ends at its token's `request_ended`, after which the same token starts
//! a new one; once the boot token's budget ends, the session refuses that token although its
//! deadline has not passed; a session whose slots are all live evicts the budget with the earliest
//! deadline, and reuses an expired slot before it evicts any. Admission, which verifies a token and
//! checks its deadline before it takes from a budget, is covered in `worker_flow.zig`, and
//! `request_ended` as the control socket delivers it in `control_flow.zig`. Lane:
//! egress-gateway-test.

const std = @import("std");
const ipc = @import("collo_ipc");
const limits = @import("collo_limits");
const gateway = @import("collo_egress_gateway");

const budgets = gateway.budgets;
const egress_token = ipc.egress_token;
const Take = budgets.Take;

const session_id: u64 = 3;
/// The clock every case reads unless it says otherwise; deadlines below lie after it.
const now_ns: u64 = 10;

const RequestOptions = struct {
    request_id: u64,
    request_generation: u64 = 1,
    budget: u32 = 2,
    deadline_monotonic_ns: u64 = 1_000,
};

fn requestFields(options: RequestOptions) egress_token.Fields {
    return .{
        .kind = .request,
        .policy_id = 0,
        .budget = options.budget,
        .session_id = session_id,
        .request_id = options.request_id,
        .request_generation = options.request_generation,
        .deadline_monotonic_ns = options.deadline_monotonic_ns,
    };
}

fn bootFields(deadline_monotonic_ns: u64) egress_token.Fields {
    return .{
        .kind = .boot,
        .policy_id = 0,
        .budget = 2,
        .session_id = session_id,
        .request_id = 0,
        .request_generation = 0,
        .deadline_monotonic_ns = deadline_monotonic_ns,
    };
}

const boot_key: budgets.BudgetKey = .{
    .session_id = session_id,
    .request_id = 0,
    .request_generation = 0,
};

test "a budget starts at its token's first fetch with the token's budget and runs out after it" {
    var session: budgets.SessionBudgets = .{};
    const fields = requestFields(.{ .request_id = 10, .budget = 3 });
    for (0..3) |_|
        try std.testing.expectEqual(Take.taken, session.take(fields, now_ns));
    try std.testing.expectEqual(Take.exhausted, session.take(fields, now_ns));
    try std.testing.expectEqual(Take.exhausted, session.take(fields, now_ns));
}

test "a budget lives until the deadline of the token that started it" {
    var session: budgets.SessionBudgets = .{};
    const first = requestFields(.{ .request_id = 10, .budget = 1, .deadline_monotonic_ns = 100 });
    try std.testing.expectEqual(Take.taken, session.take(first, now_ns));
    try std.testing.expectEqual(Take.exhausted, session.take(first, 99));

    // A token for the same request with a later deadline finds the spent budget while it lives,
    // and from the first budget's deadline on finds none and starts its own.
    const later = requestFields(.{ .request_id = 10, .budget = 1, .deadline_monotonic_ns = 200 });
    try std.testing.expectEqual(Take.exhausted, session.take(later, 99));
    try std.testing.expectEqual(Take.taken, session.take(later, 100));
    try std.testing.expectEqual(Take.exhausted, session.take(later, 150));
}

test "each request generation has a budget of its own" {
    var session: budgets.SessionBudgets = .{};
    const first = requestFields(.{ .request_id = 10, .request_generation = 1, .budget = 1 });
    const second = requestFields(.{ .request_id = 10, .request_generation = 2, .budget = 1 });
    try std.testing.expectEqual(Take.taken, session.take(first, now_ns));
    try std.testing.expectEqual(Take.exhausted, session.take(first, now_ns));
    try std.testing.expectEqual(Take.taken, session.take(second, now_ns));
    try std.testing.expectEqual(Take.exhausted, session.take(second, now_ns));
}

test "a refund gives one fetch back and never lifts a budget above its token's budget" {
    var session: budgets.SessionBudgets = .{};
    const fields = requestFields(.{ .request_id = 10, .budget = 2 });
    const key = budgets.BudgetKey.ofToken(fields);
    try std.testing.expectEqual(Take.taken, session.take(fields, now_ns));
    try std.testing.expectEqual(Take.taken, session.take(fields, now_ns));
    try std.testing.expectEqual(Take.exhausted, session.take(fields, now_ns));

    session.refund(key, now_ns);
    try std.testing.expectEqual(Take.taken, session.take(fields, now_ns));
    try std.testing.expectEqual(Take.exhausted, session.take(fields, now_ns));

    // Three refunds against an empty budget of two leave two fetches, not three.
    for (0..3) |_|
        session.refund(key, now_ns);
    try std.testing.expectEqual(Take.taken, session.take(fields, now_ns));
    try std.testing.expectEqual(Take.taken, session.take(fields, now_ns));
    try std.testing.expectEqual(Take.exhausted, session.take(fields, now_ns));
}

test "a refund after the budget ended gives nothing back" {
    var session: budgets.SessionBudgets = .{};
    const spent = requestFields(.{ .request_id = 10, .budget = 1 });
    const other = requestFields(.{ .request_id = 11, .budget = 1 });
    try std.testing.expectEqual(Take.taken, session.take(spent, now_ns));
    try std.testing.expectEqual(Take.taken, session.take(other, now_ns));

    session.end(budgets.BudgetKey.ofToken(spent));
    session.refund(budgets.BudgetKey.ofToken(spent), now_ns);
    // The refund neither revived the ended budget nor reached another request's budget.
    try std.testing.expectEqual(Take.exhausted, session.take(other, now_ns));
    try std.testing.expectEqual(Take.taken, session.take(spent, now_ns));
    try std.testing.expectEqual(Take.exhausted, session.take(spent, now_ns));
}

test "a request's token starts a new budget after its request ended" {
    var session: budgets.SessionBudgets = .{};
    const fields = requestFields(.{ .request_id = 10, .budget = 1 });
    try std.testing.expectEqual(Take.taken, session.take(fields, now_ns));
    try std.testing.expectEqual(Take.exhausted, session.take(fields, now_ns));

    session.end(budgets.BudgetKey.ofToken(fields));
    try std.testing.expectEqual(Take.taken, session.take(fields, now_ns));
    try std.testing.expectEqual(Take.exhausted, session.take(fields, now_ns));

    // Ending the budget again, or ending one the session never had, touches no other budget,
    // which is what makes a replayed `request_ended` harmless.
    const other = requestFields(.{ .request_id = 11, .budget = 1 });
    try std.testing.expectEqual(Take.taken, session.take(other, now_ns));
    session.end(budgets.BudgetKey.ofToken(fields));
    session.end(budgets.BudgetKey.ofToken(fields));
    session.end(.{ .session_id = session_id, .request_id = 99, .request_generation = 1 });
    try std.testing.expect(!session.boot_ended);
    try std.testing.expectEqual(Take.exhausted, session.take(other, now_ns));
}

test "once the boot token's budget ends the session refuses every boot token" {
    var session: budgets.SessionBudgets = .{};
    const boot = bootFields(5_000);
    try std.testing.expectEqual(Take.taken, session.take(boot, now_ns));
    try std.testing.expect(!session.boot_ended);

    session.end(boot_key);
    try std.testing.expect(session.boot_ended);
    try std.testing.expectEqual(Take.boot_ended, session.take(boot, now_ns));
    // A boot token whose budget never started is refused too, with its deadline still ahead.
    try std.testing.expectEqual(Take.boot_ended, session.take(bootFields(9_000), now_ns));

    // Request tokens keep their budgets.
    const request = requestFields(.{ .request_id = 10 });
    try std.testing.expectEqual(Take.taken, session.take(request, now_ns));
}

test "ending a request's budget leaves the boot token and the other requests alone" {
    var session: budgets.SessionBudgets = .{};
    const boot = bootFields(5_000);
    const ended = requestFields(.{ .request_id = 10, .budget = 1 });
    const kept = requestFields(.{ .request_id = 11, .budget = 1 });
    try std.testing.expectEqual(Take.taken, session.take(boot, now_ns));
    try std.testing.expectEqual(Take.taken, session.take(ended, now_ns));
    try std.testing.expectEqual(Take.taken, session.take(kept, now_ns));

    session.end(budgets.BudgetKey.ofToken(ended));
    try std.testing.expect(!session.boot_ended);
    try std.testing.expectEqual(Take.taken, session.take(boot, now_ns));
    try std.testing.expectEqual(Take.exhausted, session.take(boot, now_ns));
    try std.testing.expectEqual(Take.exhausted, session.take(kept, now_ns));
}

test "a session whose slots are all live evicts the budget with the earliest deadline" {
    var session: budgets.SessionBudgets = .{};
    // Every slot holds a spent budget. Deadlines fall as request ids rise, so the earliest
    // deadline sits in the last slot, not the first.
    const count = budgets.per_session_max;
    for (0..count) |index| {
        const fields = requestFields(.{
            .request_id = index + 1,
            .budget = 1,
            .deadline_monotonic_ns = 1_000 + (count - index) * 10,
        });
        try std.testing.expectEqual(Take.taken, session.take(fields, now_ns));
    }
    const earliest = requestFields(.{
        .request_id = count,
        .budget = 1,
        .deadline_monotonic_ns = 1_000 + 10,
    });
    const next_earliest = requestFields(.{
        .request_id = count - 1,
        .budget = 1,
        .deadline_monotonic_ns = 1_000 + 20,
    });
    const latest = requestFields(.{
        .request_id = 1,
        .budget = 1,
        .deadline_monotonic_ns = 1_000 + count * 10,
    });

    const newcomer = requestFields(.{ .request_id = 500, .budget = 1, .deadline_monotonic_ns = 9_000 });
    try std.testing.expectEqual(Take.taken, session.take(newcomer, now_ns));
    // The newcomer took the earliest budget's slot, so that token starts over, and doing so
    // evicts the next earliest; the latest budget was never touched.
    try std.testing.expectEqual(Take.taken, session.take(earliest, now_ns));
    try std.testing.expectEqual(Take.taken, session.take(next_earliest, now_ns));
    try std.testing.expectEqual(Take.exhausted, session.take(latest, now_ns));
    try std.testing.expectEqual(Take.exhausted, session.take(newcomer, now_ns));
}

test "an expired slot is reused before any live budget is evicted" {
    var session: budgets.SessionBudgets = .{};
    const count = budgets.per_session_max;
    const short_lived_request_id: u64 = 6;
    for (0..count) |index| {
        const request_id = index + 1;
        const deadline: u64 = if (request_id == short_lived_request_id) 50 else 1_000 + index * 10;
        const fields = requestFields(.{
            .request_id = request_id,
            .budget = 1,
            .deadline_monotonic_ns = deadline,
        });
        try std.testing.expectEqual(Take.taken, session.take(fields, now_ns));
    }

    // At 60 only the short-lived budget has expired. The newcomer takes its slot, and the live
    // budget with the earliest deadline, request 1's, stays spent.
    const later_ns: u64 = 60;
    const newcomer = requestFields(.{ .request_id = 500, .budget = 1, .deadline_monotonic_ns = 9_000 });
    try std.testing.expectEqual(Take.taken, session.take(newcomer, later_ns));
    for (0..count) |index| {
        const request_id = index + 1;
        if (request_id == short_lived_request_id)
            continue;
        const fields = requestFields(.{
            .request_id = request_id,
            .budget = 1,
            .deadline_monotonic_ns = 1_000 + index * 10,
        });
        try std.testing.expectEqual(Take.exhausted, session.take(fields, later_ns));
    }
}

test "a budget key names the session, the request id and the generation, and only the boot key is boot" {
    const fields = requestFields(.{ .request_id = 10, .request_generation = 7 });
    const from_token = budgets.BudgetKey.ofToken(fields);
    try std.testing.expectEqual(budgets.BudgetKey{
        .session_id = session_id,
        .request_id = 10,
        .request_generation = 7,
    }, from_token);
    try std.testing.expect(!from_token.isBoot());

    const from_ended = budgets.BudgetKey.ofEnded(.{
        .session_id = session_id,
        .request_id = 10,
        .request_generation = 7,
    });
    try std.testing.expectEqual(from_token, from_ended);

    const boot = budgets.BudgetKey.ofToken(bootFields(5_000));
    try std.testing.expectEqual(boot_key, boot);
    try std.testing.expect(boot.isBoot());
}

test "a session holds a budget for every request in flight and its boot token, four times over" {
    try std.testing.expectEqual(
        4 * (limits.server.worker_concurrency_max + 1),
        budgets.per_session_max,
    );
    try std.testing.expectEqual(
        gateway.sizing.workers_max * budgets.per_session_max,
        budgets.per_gateway_max,
    );
}
