//! Covers the statuses `collo_runtime_crypto_job_enqueue` returns
//! (`worker/host/crypto.zig`), through the rejection each one becomes in the
//! bridge: a crypto pool that is not running rejects a WebCrypto call with
//! its own OperationError, not the one for a full in-flight bound. Runs in
//! `worker-test`; the pool's admission is covered by `runtime/crypto_pool.zig`
//! and `runtime/limits.zig`, WebCrypto's Web behavior by the `webapi` lane.

const std = @import("std");
const support = @import("bindings_support");
const worker = @import("collo_worker");
const rt = @import("collo_test_harness");

test "a WebCrypto call to a crypto pool that is not running rejects as a pool that is not running" {
    var vm = try support.createVm();
    defer vm.deinit();
    const control_pair = try rt.socketPairType(std.posix.SOCK.SEQPACKET | std.posix.SOCK.CLOEXEC);
    defer std.posix.close(control_pair[0]);
    defer std.posix.close(control_pair[1]);
    var completion_fixture = try rt.CompletionFixture.init();
    defer completion_fixture.deinit();
    var now_mono_ns: u64 = 0;
    var runtime = try worker.Runtime.init(std.testing.allocator, &vm, control_pair[0], &completion_fixture.view, try rt.createCompletionEventfd(), .{
        .ctx = &now_mono_ns,
        .now_fn = rt.fakeNow,
    });
    defer runtime.deinit();
    try runtime.attachHostRuntime();

    // A pool with no thread accepts no job (`jobs.zig:Pool.submit`).
    runtime.crypto.jobs.deinit();
    runtime.crypto.jobs = .{};

    // A key pair is always generated on the pool (`subtle/generate.cpp`); a
    // short digest or a secret key would be made on the VM thread and never
    // reach it.
    try rt.runRouteAndExpectBody(&runtime, control_pair[1],
        \\export default async function handle() {
        \\    try {
        \\        await crypto.subtle.generateKey({ name: "Ed25519" }, true, ["sign", "verify"]);
        \\        return Response.json({ generated: true });
        \\    } catch (err) {
        \\        return Response.json({ name: err.name, message: err.message });
        \\    }
        \\}
    , 1101, "/crypto-pool-stopped.js", "\"name\":\"OperationError\",\"message\":\"The WebCrypto job pool is not running.\"");
}
