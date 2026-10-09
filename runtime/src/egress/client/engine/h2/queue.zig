//! The engine's two bounded rings and the owner's wake. The message queue
//! carries everything producers send the owner (submits, connector outcomes,
//! body credits and cancels); the connect queue carries dial commands from
//! the owner to the connector threads. Both live under `Engine.mutex`, and
//! the owner is woken through `h2_wake_fd` as well as the condition.
//!
//! Only a submit fails when the message queue is full. Every other message
//! blocks its producer until the owner drains: a connector outcome owns a
//! live connection, and a consumer credit is the only wake for a parked
//! body. Blocking cannot deadlock because the owner drains the whole queue
//! every iteration and never waits on a producer.
//!
//! This file also creates and destroys the io_uring drivers: readiness slot
//! i belongs to connector i, data slot 0 to the owner and data slot i + 1 to
//! connector i.

const std = @import("std");
const data_io = @import("collo_egress_data_io");
const readiness = @import("collo_egress_readiness");

pub fn Methods(
    comptime Engine: type,
    comptime Command: type,
    comptime H2Message: type,
    comptime H2Connected: type,
    comptime WakeEvent: type,
    comptime WakeFn: type,
) type {
    _ = WakeEvent;
    _ = WakeFn;
    return struct {
        pub fn enqueueH2MessageLocked(self: *Engine, message: H2Message) !void {
            if (self.h2_len == self.h2_queue.len)
                return error.EgressEngineQueueFull;
            self.enqueueH2MessageAssumeCapacityLocked(message);
        }

        pub fn enqueueH2MessageAssumeCapacityLocked(self: *Engine, message: H2Message) void {
            std.debug.assert(self.h2_len < self.h2_queue.len);
            const index = (self.h2_head + self.h2_len) % self.h2_queue.len;
            self.h2_queue[index] = message;
            self.h2_len += 1;
            self.h2_stats.recordQueueDepthEnqueue(self.h2_len);
        }

        pub fn enqueueH2ConnectLocked(self: *Engine, command: Command) !void {
            if (self.h2_connect_len == self.h2_connect_queue.len)
                return error.EgressEngineQueueFull;
            const index = (self.h2_connect_head + self.h2_connect_len) %
                self.h2_connect_queue.len;
            self.h2_connect_queue[index] = command;
            self.h2_connect_len += 1;
            self.h2_stats.recordConnectQueueDepth(self.h2_connect_len);
            self.h2_connect_condition.signal();
        }

        pub fn enqueueH2Connect(self: *Engine, command: Command) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.stopping)
                return error.EgressEngineStopped;
            try self.enqueueH2ConnectLocked(command);
        }

        pub fn enqueueH2Connected(self: *Engine, connected: H2Connected) !void {
            try enqueueH2MessageBlocking(self, .{ .connected = connected });
        }

        /// Enqueues a message that must not be dropped when the queue is
        /// full, such as a connector outcome that owns a live connection, by
        /// blocking until the owner drains.
        pub fn enqueueH2MessageBlocking(self: *Engine, message: H2Message) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.h2_len == self.h2_queue.len and !self.stopping)
                self.h2_condition.wait(&self.mutex);
            if (self.stopping)
                return error.EgressEngineStopped;
            try self.enqueueH2MessageLocked(message);
            self.h2_condition.signal();
            self.signalH2Wake();
        }

        pub fn waitForH2Command(self: *Engine) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.h2_len == 0 and !self.stopping)
                self.h2_condition.wait(&self.mutex);
            return !self.stopping;
        }

        pub fn drainH2BatchNonBlocking(self: *Engine) ?usize {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.stopping)
                return null;

            self.h2_stats.recordQueueDepthDrain(self.h2_len);
            var batch_len: usize = 0;
            while (self.h2_len != 0) {
                self.h2_batch[batch_len] = self.h2_queue[self.h2_head];
                batch_len += 1;
                self.h2_head = (self.h2_head + 1) % self.h2_queue.len;
                self.h2_len -= 1;
            }
            if (batch_len != 0)
                self.h2_condition.broadcast();
            return batch_len;
        }

        pub fn popH2Connect(self: *Engine) ?Command {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.h2_connect_len == 0 and !self.stopping)
                self.h2_connect_condition.wait(&self.mutex);
            if (self.stopping)
                return null;

            const command = self.h2_connect_queue[self.h2_connect_head];
            self.h2_connect_head = (self.h2_connect_head + 1) % self.h2_connect_queue.len;
            self.h2_connect_len -= 1;
            return command;
        }

        pub fn initH2Drivers(self: *Engine) !void {
            for (self.h2_readiness_drivers) |driver|
                std.debug.assert(driver == null);
            for (self.h2_data_drivers) |driver|
                std.debug.assert(driver == null);

            errdefer self.deinitH2Drivers();

            for (self.h2_readiness_drivers) |*slot|
                slot.* = readiness.Driver.init(self.allocator);

            for (self.h2_data_drivers) |*slot| {
                // prepareForSandbox pins the ring address inside the provided
                // buffer group, so the driver must already sit in its final
                // slot; preparing a local and copying it would leave the
                // buffer group pointing at this stack frame.
                slot.* = try data_io.Driver.init(self.allocator);
                if (self.pre_register_recv_buffers) {
                    const driver = &slot.*.?;
                    _ = driver.prepareForSandbox() catch |err| switch (err) {
                        error.UnsupportedKernel => {
                            std.log.err(
                                "HTTP/2 egress requires io_uring with ring restrictions (Linux kernel >= 5.10); refusing engine start: {s}",
                                .{@errorName(err)},
                            );
                            return error.EgressHttp2IoUringUnsupported;
                        },
                        else => return err,
                    };
                }
            }
        }

        pub fn deinitH2Drivers(self: *Engine) void {
            for (self.h2_data_drivers) |*slot| {
                if (slot.*) |*driver|
                    driver.deinit();
                slot.* = null;
            }
            for (self.h2_readiness_drivers) |*slot| {
                if (slot.*) |*driver|
                    driver.deinit();
                slot.* = null;
            }
        }

        pub fn h2DataDriver(self: *Engine, index: usize) *data_io.Driver {
            return &self.h2_data_drivers[index].?;
        }

        pub fn h2ReadinessDriver(self: *Engine, index: usize) *readiness.Driver {
            return &self.h2_readiness_drivers[index].?;
        }

        /// Owner thread only, so the counter takes no lock.
        pub fn nextH2CreditSourceId(self: *Engine) u64 {
            const id = self.next_h2_credit_source_id;
            self.next_h2_credit_source_id +%= 1;
            if (self.next_h2_credit_source_id == 0)
                self.next_h2_credit_source_id = 1;
            return id;
        }

        pub fn signalH2Wake(self: *Engine) void {
            var one: u64 = 1;
            _ = std.posix.write(self.h2_wake_fd, std.mem.asBytes(&one)) catch |err| switch (err) {
                // The eventfd counter is saturated, so a wake is already
                // pending.
                error.WouldBlock => return,
                else => |unexpected| {
                    std.log.debug(
                        "failed to wake HTTP/2 egress owner: {s}",
                        .{@errorName(unexpected)},
                    );
                    return;
                },
            };
        }
    };
}
