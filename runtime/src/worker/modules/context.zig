//! The part of the worker runtime that route registration and evaluation may
//! touch, used on the worker's VM thread. `Runtime.modulesContext` in
//! `worker/runtime/modules.zig` builds one for each call: the pointers and
//! slices borrow the runtime's state, and every other field is a copy taken
//! at that moment, so a context serves the call it was built for and is
//! never stored.

const std = @import("std");
const bindings = @import("collo_bindings");
const runtime_types = @import("../runtime/types.zig");
const state = @import("state.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    vm: *bindings.Vm,
    modules: *state.State,
    clock: runtime_types.Clock,
    /// The validated bindings blob of one route, from which that route's
    /// `env` is built when its module becomes ready (`route_env.zig`).
    /// Borrowed: the worker's boot keeps it mapped until the runtime is gone.
    route_bindings_blob: []const u8,
    /// Entry specifier of the route `route_bindings_blob` belongs to.
    route_bindings_route: []const u8,

    pub fn nowMonoNs(self: *const Context) u64 {
        return self.clock.now();
    }
};
