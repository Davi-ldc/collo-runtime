//! Covers the request timeline of `RequestContext` (`request/context.zig`):
//! each transition closes the elapsed slice into the total of the state it
//! leaves, so the request's turns, its waiting time and its I/O time
//! partition wall time, whatever order readiness drains in, and nothing
//! moves after the finish seals the timeline. The stamps are derived by
//! hand, with no clock. Runs in `worker-test`.

const std = @import("std");
const worker_request = @import("collo_worker_request");

const RequestContext = worker_request.context.RequestContext;

/// A context with only the seven fields the four `note*` transitions read
/// and write. Leaving the rest undefined is sound because those transitions
/// touch nothing else.
fn timelineCtx(started_ns: u64) RequestContext {
    var ctx: RequestContext = undefined;
    ctx.io_time_ns = 0;
    ctx.waiting_ns = 0;
    ctx.ready_items = 0;
    ctx.executing_turn = false;
    ctx.timeline_sealed = false;
    ctx.nonexec_since_ns = started_ns;
    ctx.state_since_ns = started_ns;
    return ctx;
}

test "io closes at the readiness stamp and waiting runs from stamp to turn begin" {
    var ctx = timelineCtx(0);

    // I/O from 0 to 100: the readiness is stamped at 100 and drained at 150.
    ctx.noteReady(100, 150, true);
    try std.testing.expectEqual(@as(u64, 100), ctx.io_time_ns);
    try std.testing.expectEqual(@as(u64, 0), ctx.waiting_ns);
    try std.testing.expectEqual(@as(u32, 1), ctx.ready_items);

    // Runnable but not running from 100 to 200, which is waiting time.
    ctx.noteTurnBegin(200, true);
    try std.testing.expectEqual(@as(u64, 100), ctx.io_time_ns);
    try std.testing.expectEqual(@as(u64, 100), ctx.waiting_ns);
    try std.testing.expectEqual(@as(u32, 0), ctx.ready_items);

    // Executing from 200 to 300, booked to neither I/O nor waiting.
    ctx.noteTurnEnd(300);
    try std.testing.expectEqual(@as(u64, 100), ctx.io_time_ns);
    try std.testing.expectEqual(@as(u64, 100), ctx.waiting_ns);

    // I/O again from 300 to 350, since nothing was queued, then a finish
    // inside the second turn, which has no open slice to close.
    ctx.noteTurnBegin(350, false);
    try std.testing.expectEqual(@as(u64, 150), ctx.io_time_ns);
    ctx.noteFinish(400);
    try std.testing.expectEqual(@as(u64, 150), ctx.io_time_ns);
    try std.testing.expectEqual(@as(u64, 100), ctx.waiting_ns);
    try std.testing.expect(ctx.timeline_sealed);
}

test "ready_since zero means ready now" {
    var ctx = timelineCtx(0);
    ctx.noteReady(0, 70, true);
    try std.testing.expectEqual(@as(u64, 70), ctx.io_time_ns);
    try std.testing.expectEqual(@as(u64, 70), ctx.state_since_ns);
}

test "a readiness stamp before the slice start clamps to it" {
    // The slice starts at 1000, where a turn just ended. A producer stamp of
    // 500 predates it and must not carve a negative I/O slice out of time
    // already booked.
    var ctx = timelineCtx(1000);
    ctx.noteReady(500, 1500, true);
    try std.testing.expectEqual(@as(u64, 0), ctx.io_time_ns);
    try std.testing.expectEqual(@as(u64, 0), ctx.waiting_ns);
    try std.testing.expectEqual(@as(u64, 1000), ctx.state_since_ns);
    try std.testing.expectEqual(@as(u32, 1), ctx.ready_items);
}

test "an out-of-order drain moves the earlier-readiness window from io into the open runnable slice" {
    var ctx = timelineCtx(0);

    // The later stamp drains first, so 0 to 100 is booked as I/O.
    ctx.noteReady(100, 110, true);
    try std.testing.expectEqual(@as(u64, 100), ctx.io_time_ns);
    try std.testing.expectEqual(@as(u64, 0), ctx.waiting_ns);

    // The earlier readiness, stamped at 50, drains second. The request was
    // runnable from 50 on, so its runnable slice now opens at 50 and the
    // window 50 to 100 leaves I/O: drain order must not decide the split.
    // The window waits in the open slice until a transition closes it.
    ctx.noteReady(50, 110, true);
    try std.testing.expectEqual(@as(u64, 50), ctx.io_time_ns);
    try std.testing.expectEqual(@as(u64, 0), ctx.waiting_ns);
    try std.testing.expectEqual(@as(u64, 50), ctx.state_since_ns);
    try std.testing.expectEqual(@as(u32, 2), ctx.ready_items);
    // At the drain, I/O, waiting and the open slice cover 0 to 110 once.
    try std.testing.expectEqual(
        @as(u64, 110),
        ctx.io_time_ns + ctx.waiting_ns + (110 - ctx.state_since_ns),
    );
}

test "out-of-order drains closed by a turn or a finish partition wall time exactly" {
    // A turn from 20 to 100, then I/O until readiness stamped at 300 drains
    // first. Two earlier stamps drain after it: 200, and 50, which a producer
    // took inside the request's own turn, so the request is runnable from the
    // turn's end at 100 and not before.
    var ctx = timelineCtx(0);
    ctx.noteReady(0, 10, true); // io 0..10
    ctx.noteTurnBegin(20, true); // waiting 10..20
    ctx.noteTurnEnd(100); // turn 20..100
    ctx.noteReady(300, 320, true);
    ctx.noteReady(200, 330, true);
    ctx.noteReady(50, 340, true);
    ctx.noteTurnBegin(400, true); // waiting 100..400, counted once
    ctx.noteFinish(450); // turn 400..450 (finish inside the turn)

    const turn_spans: u64 = (100 - 20) + (450 - 400);
    try std.testing.expectEqual(@as(u64, 10), ctx.io_time_ns);
    try std.testing.expectEqual(@as(u64, 10 + 300), ctx.waiting_ns);
    try std.testing.expectEqual(@as(u64, 450), ctx.io_time_ns + ctx.waiting_ns + turn_spans);

    // A finish outside a turn closes the runnable slice the earlier stamp
    // opened: runnable from 50 to the finish at 200, I/O before.
    var finished = timelineCtx(0);
    finished.noteReady(100, 110, true);
    finished.noteReady(50, 110, true);
    finished.noteFinish(200);
    try std.testing.expectEqual(@as(u64, 50), finished.io_time_ns);
    try std.testing.expectEqual(@as(u64, 150), finished.waiting_ns);
}

test "a fully attributed script partitions wall time exactly" {
    var ctx = timelineCtx(0);

    ctx.noteReady(0, 100, true); // io 0..100
    ctx.noteTurnBegin(150, true); // waiting 100..150
    ctx.noteTurnEnd(250); // turn 150..250
    ctx.noteReady(300, 320, true); // io 250..300
    ctx.noteTurnBegin(340, true); // waiting 300..340
    ctx.noteFinish(400); // turn 340..400 (finish inside the turn)

    const turn_spans: u64 = (250 - 150) + (400 - 340);
    try std.testing.expectEqual(@as(u64, 150), ctx.io_time_ns);
    try std.testing.expectEqual(@as(u64, 90), ctx.waiting_ns);
    // With every boundary stamped, wall time is exactly the turns plus
    // waiting plus I/O: 400 = 160 + 90 + 150.
    try std.testing.expectEqual(
        @as(u64, 400),
        ctx.io_time_ns + ctx.waiting_ns + turn_spans,
    );
}

test "noteFinish seals the timeline against posthumous events" {
    var ctx = timelineCtx(0);
    ctx.noteReady(0, 30, true);
    ctx.noteTurnBegin(40, true);
    ctx.noteTurnEnd(60);
    ctx.noteFinish(100);
    try std.testing.expect(ctx.timeline_sealed);
    const io = ctx.io_time_ns;
    const waiting = ctx.waiting_ns;

    // Late events on a context kept after a failed finish, such as a stale
    // queue pop or a completion for the ended request: past the seal every
    // transition is a no-op, including the `ready_items` increment and the
    // `state_since_ns` restamp.
    ctx.noteReady(0, 200, true);
    ctx.noteTurnBegin(250, true);
    ctx.noteTurnEnd(300);
    ctx.noteFinish(350);
    try std.testing.expectEqual(io, ctx.io_time_ns);
    try std.testing.expectEqual(waiting, ctx.waiting_ns);
    try std.testing.expectEqual(@as(u32, 0), ctx.ready_items);
    try std.testing.expect(!ctx.executing_turn);
    try std.testing.expectEqual(@as(u64, 100), ctx.state_since_ns);
}

test "finish outside a turn closes into waiting when runnable, io when not" {
    // An unconsumed ready item at finish: the open tail was runnable.
    var runnable = timelineCtx(0);
    runnable.noteReady(0, 40, true);
    runnable.noteFinish(100);
    try std.testing.expectEqual(@as(u64, 40), runnable.io_time_ns);
    try std.testing.expectEqual(@as(u64, 60), runnable.waiting_ns);
    try std.testing.expect(runnable.timeline_sealed);

    // Nothing queued at finish, as when a client reset or a deadline ends
    // the request mid-I/O: the tail is I/O.
    var idle = timelineCtx(0);
    idle.noteFinish(80);
    try std.testing.expectEqual(@as(u64, 80), idle.io_time_ns);
    try std.testing.expectEqual(@as(u64, 0), idle.waiting_ns);
    try std.testing.expect(idle.timeline_sealed);
}
