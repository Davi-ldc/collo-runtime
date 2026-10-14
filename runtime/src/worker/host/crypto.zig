//! The `collo_runtime_native_time_left_ns` export, which the bridge's
//! WebCrypto operations (`bindings/host_functions/webapi/crypto/budget.cpp`)
//! ask before and while they do native work nothing can interrupt: how long
//! that work may still keep the VM thread
//! (`runtime/owner.zig:nativeTimeLeftNs`). Runs on the worker's VM thread.

const std = @import("std");
const host_adapter = @import("adapter.zig");
const runtime_owner = @import("../runtime/owner.zig");

/// No runtime, which the bridge never passes while one is attached, places
/// no limit.
pub export fn collo_runtime_native_time_left_ns(runtime_ptr: ?*anyopaque) u64 {
    const runtime = host_adapter.fromOpaque(runtime_ptr) orelse return std.math.maxInt(u64);
    return runtime_owner.nativeTimeLeftNs(runtime);
}
