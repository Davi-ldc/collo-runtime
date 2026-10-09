//! Terminal transitions of a fetch body, as methods `fetch_body.Body`
//! delegates to. A body leaves `open` for `complete` or `failed`; only the
//! cancel variants (`cancel`, `cancelNoAlloc`, `cancelViewOnly` and
//! `cancelViewOnlyNoAlloc`) move it again, from `complete` to `failed`,
//! because a user abort overrides everything. `fail` applies only to an open
//! body, so bytes that fully arrived stay readable and the first failure
//! stays. A tee root applies each transition to its branches as well, except
//! the view-only cancels, which settle this view alone.
//!
//! `fail` and `cancel` allocate every message and retain every reason before
//! they change any view, so an allocation failure leaves the whole tee as it
//! was; the `NoAlloc` variants change state without a message for callers
//! that cannot allocate. Every transition returns whether a view now has a
//! ready reader, which the caller must queue.

const std = @import("std");
const bindings = @import("collo_bindings");

pub fn Methods(comptime Body: type) type {
    return struct {
        pub fn complete(self: *Body) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.state != .failed) {
                self.state = .complete;
            }
            self.queue_condition.broadcast();
            var any_ready = shouldQueueReadyLocked(self);
            if (self.tee_root == null) {
                for (self.tee_branches.items) |branch| {
                    branch.mutex.lock();
                    if (branch.state != .failed) {
                        branch.state = .complete;
                    }
                    branch.queue_condition.broadcast();
                    any_ready = any_ready or shouldQueueReadyLocked(branch);
                    branch.mutex.unlock();
                }
            }
            return any_ready;
        }

        pub fn fail(self: *Body, allocator: std.mem.Allocator, message: []const u8) !bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Only an open body fails. A complete body keeps its bytes, so a
            // gateway disconnect after END_STREAM cannot make `.text()`
            // reject data the worker already holds, and a failed body keeps
            // its first failure. A user abort goes through `cancel`, which
            // overrides both.
            if (self.state != .open)
                return shouldQueueReadyLocked(self);

            const branch_count = if (self.tee_root == null) self.tee_branches.items.len else 0;
            const self_message = try allocator.dupe(u8, message);
            var self_message_moved = false;
            errdefer if (!self_message_moved) {
                allocator.free(self_message);
            };
            var branch_messages: [][]u8 = &.{};
            var branch_messages_initialized: usize = 0;
            var branch_messages_moved = false;
            // Declared at function scope and guarded by the moved flag, like
            // `self_message`: an errdefer inside the `if` below would expire
            // when the block exits, and any later fallible step would leak the
            // array and every duplicated message. `cancel` keeps the same
            // shape for the same reason.
            errdefer if (branch_count != 0 and !branch_messages_moved) {
                for (branch_messages[0..branch_messages_initialized]) |branch_message| {
                    allocator.free(branch_message);
                }
                allocator.free(branch_messages);
            };
            if (branch_count != 0) {
                branch_messages = try allocator.alloc([]u8, branch_count);
                for (branch_messages) |*branch_message| {
                    branch_message.* = try allocator.dupe(u8, message);
                    branch_messages_initialized += 1;
                }
            }
            defer if (branch_count != 0 and branch_messages_moved) allocator.free(branch_messages);

            if (self.error_message) |old| {
                allocator.free(old);
            }
            self.error_message = self_message;
            self_message_moved = true;
            self.state = .failed;
            self.queue_condition.broadcast();
            var any_ready = shouldQueueReadyLocked(self);
            if (self.tee_root == null) {
                for (self.tee_branches.items, 0..) |branch, index| {
                    branch.mutex.lock();
                    // The same open-only rule per branch: a branch that
                    // already completed or failed keeps its own settlement.
                    if (branch.state != .open) {
                        any_ready = any_ready or shouldQueueReadyLocked(branch);
                        branch.mutex.unlock();
                        allocator.free(branch_messages[index]);
                        continue;
                    }
                    if (branch.error_message) |old| {
                        allocator.free(old);
                    }
                    branch.error_message = branch_messages[index];
                    branch.state = .failed;
                    branch.queue_condition.broadcast();
                    any_ready = any_ready or shouldQueueReadyLocked(branch);
                    branch.mutex.unlock();
                }
                branch_messages_moved = true;
            }
            return any_ready;
        }

        pub fn failNoAlloc(self: *Body) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            // Open only, like `fail`, so a complete body keeps its bytes.
            if (self.state != .open)
                return shouldQueueReadyLocked(self);
            self.state = .failed;
            self.queue_condition.broadcast();
            var any_ready = shouldQueueReadyLocked(self);
            if (self.tee_root == null) {
                for (self.tee_branches.items) |branch| {
                    branch.mutex.lock();
                    if (branch.state == .open) {
                        branch.state = .failed;
                        branch.queue_condition.broadcast();
                    }
                    any_ready = any_ready or shouldQueueReadyLocked(branch);
                    branch.mutex.unlock();
                }
            }
            return any_ready;
        }

        pub fn cancel(
            self: *Body,
            allocator: std.mem.Allocator,
            message: []const u8,
            reason: ?bindings.Value,
        ) !bool {
            var owned_reason = reason;
            var reason_moved = false;
            errdefer if (!reason_moved) {
                if (owned_reason) |*value| {
                    value.deinit();
                }
            };

            self.mutex.lock();
            defer self.mutex.unlock();

            const branch_count = if (self.tee_root == null) self.tee_branches.items.len else 0;
            const self_message = try allocator.dupe(u8, message);
            var self_message_moved = false;
            errdefer if (!self_message_moved) {
                allocator.free(self_message);
            };
            var branch_messages: [][]u8 = &.{};
            var branch_messages_initialized: usize = 0;
            var branch_messages_moved = false;
            // Declared at function scope and guarded by the moved flag, like
            // `self_message`: the `branch_reasons` allocation and the reason
            // retains below can still fail after the `if` block exits, when an
            // errdefer inside it would have expired, leaking the array and
            // every duplicated message under memory pressure.
            errdefer if (branch_count != 0 and !branch_messages_moved) {
                for (branch_messages[0..branch_messages_initialized]) |branch_message| {
                    allocator.free(branch_message);
                }
                allocator.free(branch_messages);
            };
            if (branch_count != 0) {
                branch_messages = try allocator.alloc([]u8, branch_count);
                for (branch_messages) |*branch_message| {
                    branch_message.* = try allocator.dupe(u8, message);
                    branch_messages_initialized += 1;
                }
            }
            defer if (branch_count != 0 and branch_messages_moved) allocator.free(branch_messages);

            var branch_reasons: []?bindings.Value = &.{};
            var branch_reasons_initialized: usize = 0;
            if (branch_count != 0 and owned_reason != null) {
                branch_reasons = try allocator.alloc(?bindings.Value, branch_count);
                @memset(branch_reasons, null);
                errdefer allocator.free(branch_reasons);
                errdefer {
                    for (branch_reasons[0..branch_reasons_initialized]) |*branch_reason| {
                        if (branch_reason.*) |*value| {
                            value.deinit();
                        }
                    }
                }
                for (branch_reasons) |*branch_reason| {
                    branch_reason.* = try owned_reason.?.retain();
                    branch_reasons_initialized += 1;
                }
            }
            var branch_reasons_moved = false;
            defer if (branch_reasons.len != 0 and branch_reasons_moved) allocator.free(branch_reasons);

            if (self.error_message) |old| {
                allocator.free(old);
            }
            self.error_message = self_message;
            self_message_moved = true;
            if (owned_reason) |*value| {
                if (self.abort_reason) |*old| {
                    old.deinit();
                }
                self.abort_reason = value.*;
                value.* = .{};
                reason_moved = true;
            }
            self.state = .failed;
            self.canceled.store(true, .monotonic);
            self.queue_condition.broadcast();
            var any_ready = shouldQueueReadyLocked(self);
            if (self.tee_root == null) {
                for (self.tee_branches.items, 0..) |branch, index| {
                    branch.mutex.lock();
                    if (branch.error_message) |old| {
                        allocator.free(old);
                    }
                    branch.error_message = branch_messages[index];
                    if (branch_reasons.len != 0) {
                        if (branch.abort_reason) |*old| {
                            old.deinit();
                        }
                        branch.abort_reason = branch_reasons[index].?;
                        branch_reasons[index] = null;
                    }
                    branch.state = .failed;
                    branch.canceled.store(true, .monotonic);
                    branch.queue_condition.broadcast();
                    any_ready = any_ready or shouldQueueReadyLocked(branch);
                    branch.mutex.unlock();
                }
                branch_messages_moved = true;
                branch_reasons_moved = true;
            }
            return any_ready;
        }

        pub fn cancelNoAlloc(self: *Body) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.state = .failed;
            self.canceled.store(true, .monotonic);
            self.queue_condition.broadcast();
            var any_ready = shouldQueueReadyLocked(self);
            if (self.tee_root == null) {
                for (self.tee_branches.items) |branch| {
                    branch.mutex.lock();
                    branch.state = .failed;
                    branch.canceled.store(true, .monotonic);
                    branch.queue_condition.broadcast();
                    any_ready = any_ready or shouldQueueReadyLocked(branch);
                    branch.mutex.unlock();
                }
            }
            return any_ready;
        }

        pub fn cancelViewOnly(
            self: *Body,
            allocator: std.mem.Allocator,
            message: []const u8,
            reason: ?bindings.Value,
        ) !bool {
            var owned_reason = reason;
            var reason_moved = false;
            errdefer if (!reason_moved) {
                if (owned_reason) |*value| {
                    value.deinit();
                }
            };

            self.mutex.lock();
            defer self.mutex.unlock();
            const self_message = try allocator.dupe(u8, message);
            var self_message_moved = false;
            errdefer if (!self_message_moved) {
                allocator.free(self_message);
            };
            if (self.error_message) |old| {
                allocator.free(old);
            }
            self.error_message = self_message;
            self_message_moved = true;
            if (owned_reason) |*value| {
                if (self.abort_reason) |*old| {
                    old.deinit();
                }
                self.abort_reason = value.*;
                value.* = .{};
                reason_moved = true;
            }
            self.state = .failed;
            self.canceled.store(true, .monotonic);
            self.view_released = true;
            self.queue_condition.broadcast();
            return isReadyForWaiterLocked(self);
        }

        pub fn cancelViewOnlyNoAlloc(self: *Body) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.state = .failed;
            self.canceled.store(true, .monotonic);
            self.view_released = true;
            self.queue_condition.broadcast();
            return isReadyForWaiterLocked(self);
        }

        pub fn isFailed(self: *Body) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.state == .failed;
        }

        /// Reads the cancel flag without the mutex, because the engine owner
        /// thread polls it for every HTTP/2 stream and HTTP/1 exchange whose
        /// head it has published, in its cancel scans (`cancelH2Pending` and
        /// `cancelH1Pending` in `egress/client/engine/h2_engine.zig`).
        /// Writers store it under the body mutex. A stale read delays one
        /// cancel by at most a wake, which the `.body_cancel` message and the
        /// driver's watchdog tick bound.
        pub fn isCanceled(self: *Body) bool {
            return self.canceled.load(.monotonic);
        }

        /// The message of a failed body, or null. The slice is borrowed and
        /// stays valid until a later `cancel` or `cancelViewOnly` replaces it
        /// or the body is freed.
        pub fn failureMessage(self: *Body) ?[]const u8 {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.state != .failed) {
                return null;
            }
            return self.error_message;
        }

        /// A new reference to a failed body's abort reason, which the caller
        /// releases with `deinit`; null when there is none or the retain
        /// fails.
        pub fn failureReasonRetained(self: *Body) ?bindings.Value {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.state != .failed) {
                return null;
            }
            const reason = self.abort_reason orelse return null;
            return reason.retain() catch null;
        }

        fn isReadyForWaiterLocked(self: *const Body) bool {
            return isReadyForConsumeLocked(self) or isReadyForPullLocked(self);
        }

        fn shouldQueueReadyLocked(self: *const Body) bool {
            if (!isReadyForWaiterLocked(self)) {
                return false;
            }
            return !self.view_released or self.waiter != null or self.pull_waiter != null;
        }

        fn isReadyForConsumeLocked(self: *const Body) bool {
            if (self.waiter == null) {
                return false;
            }
            return switch (self.state) {
                .open => self.chunks.items.len != 0,
                .complete, .failed => true,
            };
        }

        fn isReadyForPullLocked(self: *const Body) bool {
            if (self.pull_waiter == null) {
                return false;
            }
            return switch (self.state) {
                .open => self.chunks.items.len != 0,
                .complete, .failed => true,
            };
        }
    };
}
