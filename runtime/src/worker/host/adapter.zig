//! The `Runtime` behind the opaque pointer that every `collo_runtime_*`
//! export in this directory receives. The bridge passes back the pointer
//! `Runtime.attachHostRuntime` registered on the VM, and `Runtime.deinit`
//! clears the registration, so the pointer is either null, which every
//! export refuses, or a live `Runtime`. The exports run on the worker's VM
//! thread.

const state = @import("../runtime/root.zig");

pub const Runtime = state.Runtime;

/// The runtime behind `runtime_ptr`, or null. Nothing here can check the
/// pointer, so it must come from the bridge's registration.
pub fn fromOpaque(runtime_ptr: ?*anyopaque) ?*Runtime {
    const ptr = runtime_ptr orelse return null;
    return @ptrCast(@alignCast(ptr));
}
