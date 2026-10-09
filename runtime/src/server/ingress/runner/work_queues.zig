//! The lane thread's ready queues, holding the connections and the worker
//! deaths that wait for the event loop's next pass. Each is a FIFO threaded
//! through its slab's links (`slab.Fifo`), so neither can fill, and a place
//! is on its queue at most once. A connection's place stays queued across the
//! release of its slot and the slot's reuse, and the pop then serves the
//! connection that took the place, or none when the place is free. A
//! registration with a death queued is not freed before the pop
//! (`releaseRegistrationIfIdle` in `worker_registration.zig`).

const fault = @import("../fault.zig");

const LaneFault = fault.LaneFault;

pub fn Methods(comptime Self: type) type {
    return struct {
        /// Queues the connection in `slot` for a turn of the event loop.
        pub fn enqueueConnection(self: *Self, slot: u32) void {
            if (self.connections.get(slot) == null)
                return;
            _ = self.ready_connections.push(&self.connections, slot);
        }

        /// The slot of the oldest connection queued; it may hold no
        /// connection any more, which the turn finds.
        pub fn popConnection(self: *Self) ?u32 {
            return self.ready_connections.pop(&self.connections);
        }

        /// Queues the deferred worker fault of registration
        /// `registration_index` for the loop's next pass.
        pub fn enqueueDeath(self: *Self, registration_index: u32) LaneFault!void {
            if (self.registrations.get(registration_index) == null)
                return error.InvalidCompletionRegistration;
            _ = self.deferred_deaths.push(&self.registrations, registration_index);
        }

        pub fn popDeath(self: *Self) ?u32 {
            return self.deferred_deaths.pop(&self.registrations);
        }

        /// Whether registration `registration_index` waits on the death
        /// queue.
        pub fn deathQueued(self: *Self, registration_index: u32) bool {
            return self.registrations.entries[registration_index].slab_link.queued;
        }
    };
}
