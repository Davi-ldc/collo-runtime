//! WebCrypto on a VM with no worker runtime, as in a bindings test or the zygote: a SubtleCrypto
//! method needs no request and no pool, runs its operation before it returns and settles its
//! promise there (`promiseFromThrowingSteps` in `jsc/runtime/js_support.h`), so module top-level
//! code with no turn gets a result. A termination that arrives while a method reads its
//! arguments stays the invoke's exception and makes no promise. WebCrypto inside a request,
//! with its time guard, is covered by `worker/tests/runtime/crypto.zig`, and its Web behavior by
//! the `webapi` lane's `runtime/tests/webapi/crypto/`.

const std = @import("std");
const support = @import("bindings_support");
const bindings = support.bindings;

test "a SubtleCrypto call with no active request settles with its result" {
    var vm = try support.createVm();
    defer vm.deinit();

    const source =
        \\export const promise = crypto.subtle.digest("SHA-256", new Uint8Array([1, 2, 3]))
        \\    .then((digest) => digest.byteLength);
    ;
    try support.registerModule(&vm, "/webcrypto-outside-turn.js", source);
    try support.evaluateOk(&vm, "/webcrypto-outside-turn.js");

    var promise = try support.getExportOk(&vm, "/webcrypto-outside-turn.js", "promise");
    defer promise.deinit();

    var value = switch (try vm.mainRealm().promiseAwaitSync(&promise)) {
        .success => |settled| settled,
        .exception => |exception_value| {
            var owned_exception = exception_value;
            defer owned_exception.deinit();
            return error.UnexpectedWebCryptoRejection;
        },
        .unsupported => |unsupported_value| {
            var owned_value = unsupported_value;
            defer owned_value.deinit();
            return error.UnexpectedWebCryptoRejection;
        },
    };
    defer value.deinit();
    try support.expectValueString(&vm, &value, "32");
}

/// How long the watchdog waits, once the test thread signals the invoke, before it requests
/// termination, so the VM thread is spinning in the getter rather than still entering it.
const watchdog_grace_ns: u64 = 150 * std.time.ns_per_ms;

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

test "a termination inside a SubtleCrypto argument getter stays the invoke's exception" {
    var vm = try support.createVm();
    defer vm.deinit();

    // The method's normalization reads `name`, which spins until the termination arrives.
    const source =
        \\export default function digestWithSpinningName() {
        \\    return crypto.subtle.digest({ get name() { for (;;) {} } }, new Uint8Array(1));
        \\}
    ;
    try support.registerModule(&vm, "/webcrypto-termination.js", source);
    try support.evaluateOk(&vm, "/webcrypto-termination.js");

    var entry = try support.getExportOk(&vm, "/webcrypto-termination.js", "default");
    defer entry.deinit();

    var exec_ctx = support.makeExecCtx(4200);
    try vm.turnEnter(&exec_ctx);
    // Deferred before the watchdog's join, so it runs after the join on every path: the turn
    // must not close while a termination request is in flight.
    var turn_open = true;
    defer if (turn_open) vm.turnExit() catch {};

    var invoke_started = std.atomic.Value(bool).init(false);
    var watchdog = Watchdog{ .vm = &vm, .invoke_started = &invoke_started };
    const watchdog_thread = try std.Thread.spawn(.{}, Watchdog.main, .{&watchdog});
    var watchdog_joined = false;
    defer if (!watchdog_joined) watchdog_thread.join();

    invoke_started.store(true, .release);
    // A method that turned the termination into a rejection would return its promise here
    // instead; `invokeException` fails on a success.
    var exception = try support.invokeException(&vm, &exec_ctx, &entry, &.{});
    // Released, never formatted: the termination stays pending on the VM, and formatting would
    // re-enter JavaScript.
    exception.deinit();

    watchdog_thread.join();
    watchdog_joined = true;
    try std.testing.expectEqual(@as(?anyerror, null), watchdog.request_error);

    // The termination stayed pending through the method, so the VM refuses to run anything more.
    turn_open = false;
    vm.turnExit() catch {};
    try std.testing.expectError(error.Internal, vm.createRealm());
}
