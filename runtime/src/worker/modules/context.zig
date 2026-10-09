//! The part of the worker runtime that route registration and evaluation may
//! touch, used on the worker's VM thread. `Runtime.modulesContext` in
//! `worker/runtime/modules.zig` builds one for each call: the pointers
//! borrow the runtime's state, and every other field is a copy taken at that
//! moment, so a context serves the call it was built for and is never
//! stored.

const std = @import("std");
const bindings = @import("collo_bindings");
const runtime_types = @import("../runtime/types.zig");
const state = @import("state.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    vm: *bindings.Vm,
    modules: *state.State,
    clock: runtime_types.Clock,

    pub fn nowMonoNs(self: *const Context) u64 {
        return self.clock.now();
    }
};
