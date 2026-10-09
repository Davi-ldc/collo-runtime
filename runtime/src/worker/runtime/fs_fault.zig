//! The runtime's entry points into the fault plane (`worker/fs/fault.zig`
//! says which of its files holds what): the binding's async and sync reads,
//! and the loop's collection of fault responses and completions. `Runtime`
//! declares them as its own, and the fault table they work on is its
//! `fs_fault` field (`root.zig`). They run on the worker's VM thread.

const promise_deferred = @import("collo_worker_js").deferred;
const fs_fault = @import("../fs/fault.zig");
const fs_fault_sync = @import("../fs/fault_sync.zig");
const fs_fault_completion = @import("../fs/fault_completion.zig");

pub fn Methods(comptime Runtime: type) type {
    return struct {
        /// Asynchronous fs fault read (`worker/fs/fault.zig` owns the behavior).
        pub fn scheduleFsFaultRead(
            self: *Runtime,
            request_id: u64,
            normalized_path: []const u8,
            deferred: promise_deferred.DeferredOwned,
        ) !u64 {
            return fs_fault.schedule(self, request_id, normalized_path, deferred);
        }

        /// Synchronous fs fault: blocks the VM thread until the file is
        /// materialized or the request's remaining deadline expires. On success
        /// the caller in `node/fs.cpp` reads the local copy.
        pub fn fsFaultReadSync(self: *Runtime, request_id: u64, normalized_path: []const u8) !void {
            return fs_fault_sync.faultSync(self, request_id, normalized_path);
        }

        pub fn collectFsFaultResponse(self: *Runtime) !void {
            try fs_fault_completion.collectResponse(self);
        }

        pub fn collectFsFaultCompletions(self: *Runtime) void {
            fs_fault_completion.collectCompletions(self);
        }

        pub fn executeFsFaultCompletion(self: *Runtime, fault_id: u64) !void {
            try fs_fault_completion.executeCompletion(self, fault_id);
        }

        pub fn handleFsFaultCompletionFailure(self: *Runtime, fault_id: u64, err: anyerror) void {
            fs_fault_completion.handleCompletionFailure(self, fault_id, err);
        }
    };
}
