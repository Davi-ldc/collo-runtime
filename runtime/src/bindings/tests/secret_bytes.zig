//! `SecretBytes`, the WebCrypto bridge's one container for secret bytes
//! (`host_functions/webapi/crypto/secret_bytes.h`): every buffer it frees is
//! zeroed over its whole capacity, on growth, move assignment, clear and
//! destruction, and is freed at the size it was allocated at. The scenarios
//! run in the C++ shim `runtime/tests/support/bindings/secret_bytes_shim.cc`
//! with an allocator that records each buffer. That the bridge keeps secret
//! bytes in nothing else is the gate "WebCrypto keeps secret bytes only in
//! SecretBytes" in `runtime/tests/conventions.zig`.

const std = @import("std");
const support = @import("bindings_support");

test "every buffer SecretBytes frees is zeroed and freed at its allocated size" {
    const report = support.runSecretBytesScenarios();

    if (report.failed_checks != 0)
        std.debug.print("first failed check: secret_bytes_shim.cc:{d}\n", .{report.first_failed_line});
    try std.testing.expectEqual(@as(u64, 0), report.failed_checks);
    try std.testing.expect(report.allocations > 0);
    try std.testing.expectEqual(report.allocations, report.frees);
    try std.testing.expectEqual(@as(u64, 0), report.nonzero_frees);
    try std.testing.expectEqual(@as(u64, 0), report.mismatched_frees);
}
