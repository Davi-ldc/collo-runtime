//! Test access to the ingress command queue's eventfd, for the queue's tests
//! in `server/tests/ingress/command_queue.zig`: with the eventfd closed, the
//! next post cannot write its wake and fails.

const std = @import("std");

const server_main = @import("collo_server_main");

/// Closes `queue`'s eventfd and stores -1, which the queue's own `deinit`
/// skips, so the descriptor is never closed twice.
pub fn closeCommandEventFd(queue: *server_main.ingress.commands.Queue) void {
    if (queue.event_fd >= 0) {
        std.posix.close(queue.event_fd);
        queue.event_fd = -1;
    }
}
