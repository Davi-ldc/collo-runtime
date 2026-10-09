//! A fixed-capacity FIFO of control packets the gateway could not send yet because the control
//! socket was full: attach acks and session removal reports. The gateway's loop thread owns it
//! (`runtime/control_flow.zig`), and packets leave in the order they were queued.

/// `push` fails with `error.EgressGatewayControlBackpressure` once `capacity` packets are
/// waiting; nothing is dropped silently.
pub fn Queue(comptime Packet: type, comptime capacity: usize) type {
    return struct {
        items: [capacity]Packet = undefined,
        head: usize = 0,
        count: usize = 0,

        const Self = @This();

        pub fn isEmpty(self: *const Self) bool {
            return self.count == 0;
        }

        pub fn len(self: *const Self) usize {
            return self.count;
        }

        pub fn push(self: *Self, packet: Packet) !void {
            if (self.count == self.items.len)
                return error.EgressGatewayControlBackpressure;
            const index = (self.head + self.count) % self.items.len;
            self.items[index] = packet;
            self.count += 1;
        }

        pub fn peek(self: *const Self) ?Packet {
            if (self.count == 0)
                return null;
            return self.items[self.head];
        }

        pub fn pop(self: *Self) void {
            if (self.count == 0)
                return;
            self.head = (self.head + 1) % self.items.len;
            self.count -= 1;
            if (self.count == 0)
                self.head = 0;
        }
    };
}
