//! A promise reaction runs under the request that registered it, not the one that settles the
//! promise. Each test drives two turns over one VM, request A registering and request B
//! settling, and reads the owner back from the console sink, which stamps every line with the
//! request in `current_exec_ctx` when the line was produced. Host APIs resolve their caller
//! through the same field (`activeExecContext` in `host_functions/runtime/bridge.cpp`). The
//! thread-CPU slice moves with the owner too (`ColloRestoredTurnScope` in
//! `jsc/runtime/vm.cpp`), but these tests check only the stamp. Lane: `bindings-test`.
//! Attribution across two live requests in a worker is covered in `worker-test`
//! (`worker/tests/runtime/multiplexing.zig`).

const std = @import("std");
const support = @import("bindings_support");
const bindings = support.bindings;

const request_a: u64 = 11;
const request_b: u64 = 22;

/// Counts console lines per request id and keeps the first `max_kept` lines, each cut to the
/// size of `text`, so a test can name which line it means.
const OwnerCapture = struct {
    const max_kept = 8;
    const Kept = struct {
        request_id: u64,
        text: [64]u8,
        len: usize,
    };

    a_lines: usize = 0,
    b_lines: usize = 0,
    other_lines: usize = 0,
    kept: [max_kept]Kept = undefined,
    kept_count: usize = 0,

    fn sink(
        ctx: ?*anyopaque,
        level: u8,
        flags: u8,
        request_id: u64,
        bytes: ?[*]const u8,
        len: usize,
    ) callconv(.c) void {
        _ = level;
        _ = flags;
        const self: *OwnerCapture = @ptrCast(@alignCast(ctx orelse return));
        switch (request_id) {
            request_a => self.a_lines += 1,
            request_b => self.b_lines += 1,
            else => self.other_lines += 1,
        }
        if (self.kept_count == max_kept) return;
        const slot = &self.kept[self.kept_count];
        slot.request_id = request_id;
        slot.len = @min(len, slot.text.len);
        if (bytes) |ptr|
            @memcpy(slot.text[0..slot.len], ptr[0..slot.len]);
        self.kept_count += 1;
    }

    fn install(self: *OwnerCapture, vm: *bindings.Vm, lines_max: usize) !void {
        try vm.setConsoleSink(OwnerCapture.sink, self, 4096, lines_max, 1 << 20);
    }

    /// The request that produced the first line containing `needle`.
    fn ownerOf(self: *const OwnerCapture, needle: []const u8) ?u64 {
        for (self.kept[0..self.kept_count]) |line| {
            if (std.mem.indexOf(u8, line.text[0..line.len], needle) != null)
                return line.request_id;
        }
        return null;
    }
};

/// Two requests, both alive for the whole test. The owner table is keyed by `ColloExecCtx*`,
/// so two contexts that took turns in one stack slot would be one owner to the engine and the
/// tests could not tell them apart. `deinit` drops both registrations, which
/// `Vm.releaseExecCtx` requires before the storage goes.
const TwoRequests = struct {
    a: bindings.ExecCtx,
    b: bindings.ExecCtx,

    fn init() TwoRequests {
        return .{ .a = support.makeExecCtx(request_a), .b = support.makeExecCtx(request_b) };
    }

    fn deinit(self: *TwoRequests, vm: *bindings.Vm) void {
        vm.releaseExecCtx(&self.a) catch {};
        vm.releaseExecCtx(&self.b) catch {};
    }
};

/// Runs `export_name` inside a turn owned by `exec_ctx`, then leaves the turn so
/// the microtask queue drains. Draining on exit is what makes the settling turn
/// the one that runs the other request's continuation.
fn runTurn(
    vm: *bindings.Vm,
    specifier: []const u8,
    export_name: []const u8,
    exec_ctx: *bindings.ExecCtx,
) !void {
    var callable = try support.getExportOk(vm, specifier, export_name);
    defer callable.deinit();

    try vm.turnEnter(exec_ctx);
    var result = try support.invokeOk(vm, exec_ctx, &callable, &.{});
    result.deinit();
    try vm.turnExit();
}

test "a promise continuation runs under the request that registered it" {
    var vm = try support.createVm();
    defer vm.deinit();

    var capture = OwnerCapture{};
    try capture.install(&vm, 64);
    defer vm.setConsoleSink(null, null, 4096, 64, 1 << 20) catch {};

    const source =
        \\let settle = null;
        \\
        \\export function arm() {
        \\    const pending = new Promise((resolve) => { settle = resolve; });
        \\    pending.then(() => { console.log("continuation-of-a"); });
        \\}
        \\
        \\export function fire() {
        \\    settle(1);
        \\    console.log("settled-by-b");
        \\}
    ;
    try support.registerModule(&vm, "/owner.js", source);
    try support.evaluateOk(&vm, "/owner.js");

    var requests = TwoRequests.init();
    defer requests.deinit(&vm);

    try runTurn(&vm, "/owner.js", "arm", &requests.a);
    // Nothing has settled yet, so A's turn drained without running anything.
    try std.testing.expectEqual(@as(usize, 0), capture.kept_count);

    try runTurn(&vm, "/owner.js", "fire", &requests.b);

    // The line B produced itself belongs to B; the continuation A registered
    // belongs to A even though B's turn is what drained it.
    try std.testing.expectEqual(@as(?u64, request_b), capture.ownerOf("settled-by-b"));
    try std.testing.expectEqual(@as(?u64, request_a), capture.ownerOf("continuation-of-a"));
}

test "every reaction on one promise carries its own registering request" {
    var vm = try support.createVm();
    defer vm.deinit();

    var capture = OwnerCapture{};
    try capture.install(&vm, 64);
    defer vm.setConsoleSink(null, null, 4096, 64, 1 << 20) catch {};

    // The first `.then` finds a promise with no reaction, where the engine would store the
    // reaction inline. The second links onto an existing reaction, and had the first gone
    // inline, `JSPromise::reactionHead` would spill it into a cell that records no owner. Both
    // reactions have to carry A.
    const source =
        \\let settle = null;
        \\export function arm() {
        \\    const pending = new Promise((resolve) => { settle = resolve; });
        \\    pending.then(() => { console.log("first-reaction"); });
        \\    pending.then(() => { console.log("second-reaction"); });
        \\}
        \\export function fire() { settle(1); }
    ;
    try support.registerModule(&vm, "/probe.js", source);
    try support.evaluateOk(&vm, "/probe.js");

    var requests = TwoRequests.init();
    defer requests.deinit(&vm);

    try runTurn(&vm, "/probe.js", "arm", &requests.a);
    try runTurn(&vm, "/probe.js", "fire", &requests.b);

    try std.testing.expectEqual(@as(?u64, request_a), capture.ownerOf("first-reaction"));
    try std.testing.expectEqual(@as(?u64, request_a), capture.ownerOf("second-reaction"));
    try std.testing.expectEqual(@as(usize, 0), capture.b_lines);
}

test "work a restored continuation enqueues keeps the registering request" {
    var vm = try support.createVm();
    defer vm.deinit();

    var capture = OwnerCapture{};
    try capture.install(&vm, 64);
    defer vm.setConsoleSink(null, null, 4096, 64, 1 << 20) catch {};

    // The owner recorded on a reaction covers one hop. The second and third hops are work the
    // restored continuation enqueues itself, which keeps its owner only through the cross-task
    // token installed while a restored continuation runs (`ColloCrossTaskToken` in
    // `jsc/runtime/vm.cpp`).
    const source =
        \\let settle = null;
        \\
        \\export function arm() {
        \\    const pending = new Promise((resolve) => { settle = resolve; });
        \\    pending.then(() => {
        \\        queueMicrotask(() => {
        \\            console.log("second-hop");
        \\            Promise.resolve().then(() => { console.log("third-hop"); });
        \\        });
        \\    });
        \\}
        \\
        \\export function fire() { settle(1); }
    ;
    try support.registerModule(&vm, "/hops.js", source);
    try support.evaluateOk(&vm, "/hops.js");

    var requests = TwoRequests.init();
    defer requests.deinit(&vm);

    try runTurn(&vm, "/hops.js", "arm", &requests.a);
    try runTurn(&vm, "/hops.js", "fire", &requests.b);
    try std.testing.expectEqual(@as(?u64, request_a), capture.ownerOf("second-hop"));
    try std.testing.expectEqual(@as(?u64, request_a), capture.ownerOf("third-hop"));
}

test "a reaction of the draining turn is not re-tagged by a restored continuation" {
    var vm = try support.createVm();
    defer vm.deinit();

    var capture = OwnerCapture{};
    try capture.install(&vm, 64);
    defer vm.setConsoleSink(null, null, 4096, 64, 1 << 20) catch {};

    // B's turn settles A's promise and then drains the queue; A's restored continuation settles
    // a promise B registered on. That reaction's owner is B while A is running, so the engine
    // must enqueue it under B. The ordinary enqueue would stamp the running owner, A, onto work
    // that was never A's.
    const source =
        \\let settleA = null;
        \\let settleB = null;
        \\
        \\export function armA() {
        \\    const pendingA = new Promise((resolve) => { settleA = resolve; });
        \\    pendingA.then(() => { settleB(1); });
        \\}
        \\
        \\export function armAndFireB() {
        \\    const pendingB = new Promise((resolve) => { settleB = resolve; });
        \\    pendingB.then(() => { console.log("reaction-of-b"); });
        \\    settleA(1);
        \\}
    ;
    try support.registerModule(&vm, "/retag.js", source);
    try support.evaluateOk(&vm, "/retag.js");

    var requests = TwoRequests.init();
    defer requests.deinit(&vm);

    try runTurn(&vm, "/retag.js", "armA", &requests.a);
    try runTurn(&vm, "/retag.js", "armAndFireB", &requests.b);

    try std.testing.expectEqual(@as(?u64, request_b), capture.ownerOf("reaction-of-b"));
    try std.testing.expectEqual(@as(usize, 0), capture.a_lines);
}

test "a hot then site keeps the owner once the JIT compiles it" {
    var vm = try support.createVm();
    defer vm.deinit();

    var capture = OwnerCapture{};
    // One line per continuation, so the budget has to clear the loop count.
    try capture.install(&vm, 8192);
    defer vm.setConsoleSink(null, null, 4096, 8192, 1 << 20) catch {};

    // The DFG can lower `.then` on a promise with no reaction into an inline write on the
    // promise itself, which never reaches `performPromiseThen`, where the owner is captured; the
    // microtask owner patch in `runtime/patches/webkit/` makes that classification decline.
    // Reaching the lowering takes a call site hot enough to tier up and a fresh promise on every
    // call. Every registration happens under A and every settle under B, so one continuation
    // attributed to B means the tiered path dropped the owner.
    const source =
        \\const pending = [];
        \\const settles = [];
        \\
        \\function attach(promise) {
        \\    return promise.then(() => { console.log("hot"); });
        \\}
        \\
        \\export function arm() {
        \\    for (let i = 0; i < 4000; i++) {
        \\        const p = new Promise((resolve) => { settles.push(resolve); });
        \\        attach(p);
        \\        pending.push(p);
        \\    }
        \\}
        \\
        \\export function fire() {
        \\    for (const resolve of settles) resolve(1);
        \\}
    ;
    try support.registerModule(&vm, "/hot.js", source);
    try support.evaluateOk(&vm, "/hot.js");

    var requests = TwoRequests.init();
    defer requests.deinit(&vm);

    try runTurn(&vm, "/hot.js", "arm", &requests.a);
    try runTurn(&vm, "/hot.js", "fire", &requests.b);
    try std.testing.expectEqual(@as(usize, 4000), capture.a_lines);
    try std.testing.expectEqual(@as(usize, 0), capture.b_lines);
    try std.testing.expectEqual(@as(usize, 0), capture.other_lines);
}
