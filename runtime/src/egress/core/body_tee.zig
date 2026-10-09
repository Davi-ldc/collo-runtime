//! Tee links between a fetch body and the branches cloned from it, as methods
//! `fetch_body.Body` delegates to; only the worker clones bodies. A root lists
//! its branches in `tee_branches` and each branch points back through
//! `tee_root`. A link holds one reference on each side, and `detachLinks`
//! drops both. A root keeps feeding its branches after its own view is
//! released, and the source fetch is canceled only once no view can read it.

const std = @import("std");
const bindings = @import("collo_bindings");

pub fn Methods(comptime Body: type) type {
    return struct {
        pub fn isBranch(self: *Body) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.tee_root != null;
        }

        /// Severs every link of this body, from either side, and drops the
        /// references those links held. A body must be detached before its
        /// last release.
        pub fn detachLinks(self: *Body, allocator: std.mem.Allocator) void {
            self.mutex.lock();
            if (self.tee_root) |root| {
                self.tee_root = null;
                self.mutex.unlock();
                removeBranch(root, allocator, self);
                root.releaseAfterQueuedResourcesReleased(allocator);
                return;
            }

            var branches = self.tee_branches;
            self.tee_branches = .empty;
            self.mutex.unlock();

            for (branches.items) |branch| {
                branch.mutex.lock();
                if (branch.tee_root == self)
                    branch.tee_root = null;
                branch.mutex.unlock();
                // Each link held one reference on the branch and one on the
                // root.
                branch.releaseAfterQueuedResourcesReleased(allocator);
                self.releaseAfterQueuedResourcesReleased(allocator);
            }
            branches.deinit(allocator);
        }

        pub fn hasBranches(self: *Body) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.tee_branches.items.len != 0;
        }

        /// Whether this released root must stay because it is open and still
        /// feeds branches.
        pub fn shouldKeepReleasedSource(self: *Body) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.tee_root == null and
                self.state == .open and
                self.tee_branches.items.len != 0;
        }

        /// Whether this root's view is released with no branch and no reader
        /// left, so it can be removed.
        pub fn canRemoveReleasedSource(self: *Body) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.tee_root == null and
                self.view_released and
                self.tee_branches.items.len == 0 and
                self.waiter == null and
                self.pull_waiter == null;
        }

        pub fn isRootView(self: *Body) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.tee_root == null;
        }

        /// The identity of the source fetch to cancel now that this view was
        /// released, or null while this view has a reader, another view is
        /// still active, or the source already settled.
        pub fn sourceCancelIdentityAfterViewRelease(self: *Body) ?bindings.FetchBodyIdentity {
            self.mutex.lock();
            if (self.waiter != null or self.pull_waiter != null) {
                self.mutex.unlock();
                return null;
            }
            if (self.tee_root) |root| {
                self.mutex.unlock();
                root.mutex.lock();
                defer root.mutex.unlock();
                if (root.state != .open or !root.view_released or root.waiter != null or root.pull_waiter != null)
                    return null;
                for (root.tee_branches.items) |branch| {
                    if (branch == self)
                        continue;
                    branch.mutex.lock();
                    const active = !branch.view_released or branch.waiter != null or branch.pull_waiter != null;
                    branch.mutex.unlock();
                    if (active)
                        return null;
                }
                return root.identity;
            }
            defer self.mutex.unlock();
            if (self.state != .open)
                return null;
            for (self.tee_branches.items) |branch| {
                branch.mutex.lock();
                const active = !branch.view_released or branch.waiter != null or branch.pull_waiter != null;
                branch.mutex.unlock();
                if (active)
                    return null;
            }
            return self.identity;
        }

        pub fn sourceIdentity(self: *Body) bindings.FetchBodyIdentity {
            self.mutex.lock();
            if (self.tee_root) |root| {
                self.mutex.unlock();
                root.mutex.lock();
                defer root.mutex.unlock();
                return root.identity;
            }
            defer self.mutex.unlock();
            return self.identity;
        }

        fn removeBranch(self: *Body, allocator: std.mem.Allocator, branch: *Body) void {
            self.mutex.lock();
            var removed = false;
            for (self.tee_branches.items, 0..) |item, index| {
                if (item == branch) {
                    _ = self.tee_branches.orderedRemove(index);
                    removed = true;
                    break;
                }
            }
            self.mutex.unlock();
            if (removed)
                branch.releaseAfterQueuedResourcesReleased(allocator);
        }
    };
}
