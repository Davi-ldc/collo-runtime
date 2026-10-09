//! Owned handles to the deferreds through which the worker settles a promise
//! the bridge created, the one an async host function returned. Runs in the
//! worker on the VM thread.
//!
//! Once Zig owns a deferred, it releases it exactly once on every path,
//! settling it first when it can; `abi.h` states when each bridge call hands
//! one over. Settling does not free a deferred, only releasing does, and
//! releasing one without settling it leaves its promise pending for good.

const bindings = @import("collo_bindings");

/// A promise deferred from an async host function. `turn.resolvePromise` and
/// `turn.rejectPromise` take it out to settle it.
pub const DeferredOwned = struct {
    raw: ?*bindings.RawPromiseDeferred = null,

    /// Takes ownership of `raw`.
    pub fn fromRawOwnedNonNull(raw: *bindings.RawPromiseDeferred) DeferredOwned {
        return .{ .raw = raw };
    }

    /// Releases the deferred if the handle still holds one.
    pub fn deinit(self: *DeferredOwned) void {
        if (self.raw) |raw|
            bindings.releasePromiseDeferred(raw);
        self.* = .{};
    }

    /// Moves the deferred to the caller and leaves the handle empty. The
    /// caller must release it, settling it first when it can. Fails with
    /// `error.InvalidPromiseDeferred` when the handle is already empty.
    pub fn take(self: *DeferredOwned) !*bindings.RawPromiseDeferred {
        const raw = self.raw orelse return error.InvalidPromiseDeferred;
        self.raw = null;
        return raw;
    }
};
