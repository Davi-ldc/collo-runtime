//! Cross-thread cooperative termination of running JavaScript. `Vm.requestTermination` is the
//! only way to stop tenant code stuck in a loop: the worker's deadline sentinel calls it from
//! its own thread while the VM thread is inside a turn (`worker/runtime/sentinel.zig`). The
//! sentinel's own suite (`worker/tests/sentinel.zig`) replaces that call with a hook. This test
//! drives the trap directly through the ABI, and the hung timer tests in
//! `worker/tests/runtime/arbiter.zig` drive it through the sentinel; a broken trap would turn
//! every deadline into a wedged worker. As in a worker, the test thread is the VM thread and
//! spins in JavaScript while another thread requests termination, and the interrupted invoke
//! returns an exception.
//!
//! The VM forbids execution after a termination (`forbidExecutionOnTermination` in
//! `jsc/runtime/vm.cpp`), JSC's mode for a VM that never recovers from a termination exception.
//! A worker stops serving after a termination and its process exits without destroying the VM,
//! but a test has to destroy it, and no ABI function clears a termination request first.
//! Tearing down a terminated VM trips a JSC debug-build assertion that a Release engine compiles
//! out, so the test runs only when `COLLO_VM_TERMINATION_RELEASE_LANE` is set, which
//! `enableReleaseOnlyTests` in `runtime/build/tests.zig` does for runs against a Release engine,
//! and skips otherwise. Against a debug engine the assertion fires at teardown, after the
//! interrupt has happened.

const std = @import("std");
const support = @import("bindings_support");
const bindings = support.bindings;

const release_lane_env = "COLLO_VM_TERMINATION_RELEASE_LANE";

/// How long the watchdog waits, once the test thread signals the invoke, before it requests
/// termination, so the VM thread is inside the loop rather than still entering it.
const watchdog_grace_ns: u64 = 150 * std.time.ns_per_ms;
/// The shortest spin the test accepts; a shorter one means the trap fired before the loop
/// started. It sits well under `watchdog_grace_ns` so scheduler jitter cannot fail the test.
const min_observed_spin_ns: i128 = 50 * std.time.ns_per_ms;

const Watchdog = struct {
    vm: *bindings.Vm,
    invoke_started: *std.atomic.Value(bool),
    request_error: ?anyerror = null,

    fn main(self: *Watchdog) void {
        while (!self.invoke_started.load(.acquire))
            std.Thread.yield() catch {};
        std.Thread.sleep(watchdog_grace_ns);
        self.vm.requestTermination() catch |err| {
            self.request_error = err;
        };
    }
};

test "requestTermination interrupts a spinning turn instead of hanging" {
    // Compiled in every lane and run only against a Release engine, for the reason the file
    // header gives.
    if (std.posix.getenv(release_lane_env) == null)
        return error.SkipZigTest;

    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export default function spin() {
        \\    for (;;) {}
        \\}
    ;
    try support.registerModule(&vm, "/spin.js", source);
    try support.evaluateOk(&vm, "/spin.js");

    var entry = try support.getExportOk(&vm, "/spin.js", "default");
    defer entry.deinit();

    var exec_ctx = support.makeExecCtx(4100);
    try vm.turnEnter(&exec_ctx);
    // Deferred before the watchdog's join, so it runs after the join on every path:
    // `collo_vm_destroy` asserts that no turn is open, and the turn must not close while a
    // termination request is still in flight.
    defer vm.turnExit() catch {};

    var invoke_started = std.atomic.Value(bool).init(false);
    var watchdog = Watchdog{ .vm = &vm, .invoke_started = &invoke_started };
    const watchdog_thread = try std.Thread.spawn(.{}, Watchdog.main, .{&watchdog});
    var watchdog_joined = false;
    // Only an early return reaches this; the normal path joins before the checks, so the
    // termination request has finished by then.
    defer if (!watchdog_joined) watchdog_thread.join();

    const begin_ns = std.time.nanoTimestamp();
    invoke_started.store(true, .release);
    // An interrupted invoke returns an exception; `invokeException` turns a success, which the
    // endless loop cannot produce, into an error.
    var exception = try support.invokeException(&vm, &exec_ctx, &entry, &.{});
    // Only the handle is released, never formatted: `caughtExceptionStatus` in
    // `jsc/runtime/vm.cpp` leaves a termination pending on the VM, and formatting would re-enter
    // JavaScript on a VM that is terminating.
    exception.deinit();
    const elapsed_ns = std.time.nanoTimestamp() - begin_ns;

    watchdog_thread.join();
    watchdog_joined = true;

    try std.testing.expectEqual(@as(?anyerror, null), watchdog.request_error);
    try std.testing.expect(elapsed_ns >= min_observed_spin_ns);
}
