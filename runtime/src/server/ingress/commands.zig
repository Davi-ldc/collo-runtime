//! The command queue of one ingress lane and the commands it carries: a
//! worker's death, a slot handed to a waiting request, the failure of a
//! request no worker can serve, the worker output a worker's reader forwards
//! to the lane that owns a request, the answers that let a reader free ring
//! bytes and give its role up, and shutdown. Producers are other lanes, the
//! launcher, the reaper and the stopping service, on any thread; the lane
//! thread alone dequeues. The payloads and the protocol of each exchange are
//! in `lane_commands.zig`, and the lane's handlers in
//! `runner/command_flow.zig`.
//!
//! Every push follows a successful write to the queue's eventfd under the
//! queue mutex, so a queued command always has a wake pending for the lane's
//! poll. The mutex is a leaf: a producer takes it with no pool mutex held,
//! and no other lock is taken under it (`server/supervisor/pool.zig` gives
//! the order).
//!
//! A full queue refuses a command, and its producer acts on the refusal as
//! `lane_commands.zig` says for that command. Three commands may also fill a
//! reserve the other commands cannot reach, because a refusal would cost
//! more than the command: a worker's death, which the lane's requests on that
//! worker would otherwise wait out to their deadlines; a slot whose grant
//! makes the lane the worker's reader, which a refused post would hand back
//! with the slot, leaving its waiting request to its deadline; and a
//! completion a reader forwards, whose loss would leave a worker that
//! answered in time to the grace backstop's fault. A lane serving the
//! configuration reserves, per worker table entry of every pool, one place
//! for a death, one for a reader grant and one per slot for a completion
//! (`lane.obligationReserve`): a worker dies once, the pool grants its
//! reader role to one lane at a time, and a reader forwards at most one
//! completion per request it was sent (`RequestTable.claimCompletion`). The
//! reserve runs out only if one entry's worker is launched, dies and is
//! retired again while the lane leaves an earlier command of that entry
//! unprocessed.

const std = @import("std");
const ingress_state = @import("state.zig");
const fault = @import("fault.zig");
const lane_commands = @import("lane_commands.zig");

pub const WorkerDied = struct {
    worker_key: ingress_state.WorkerKey,
    /// Why the worker is dead, as the access records and usage floors of the
    /// requests its death ends carry it.
    reason: fault.WorkerFaultReason,
};

pub const Command = union(enum) {
    /// A vacant queue slot; never enqueued.
    empty,
    /// A worker this lane holds a slot of, or reads, died.
    worker_died: WorkerDied,
    dispatch_ready: lane_commands.DispatchReady,
    dispatch_failed: lane_commands.DispatchFailed,
    forwarded_descriptor: lane_commands.ForwardedDescriptor,
    forwarded_completion: lane_commands.ForwardedCompletion,
    payload_consumed: lane_commands.PayloadConsumed,
    release_worker: lane_commands.ReleaseWorker,
    /// Wakes the lane once the service is stopping; the stop flag itself is
    /// the service's.
    shutdown,

    /// Frees the memory a command still owns. It gives nothing back to a
    /// pool: a lane runs every `dispatch_ready` it accepted before its queue
    /// goes, or returns its slot (`command_flow.returnQueuedHandoffs`).
    pub fn deinit(self: *Command) void {
        switch (self.*) {
            .forwarded_descriptor => |*forwarded| forwarded.deinit(),
            .empty,
            .worker_died,
            .dispatch_ready,
            .dispatch_failed,
            .forwarded_completion,
            .payload_consumed,
            .release_worker,
            .shutdown,
            => {},
        }
        self.* = .empty;
    }

    /// Whether the command may fill the queue's reserve: it hands the lane
    /// an obligation no other lane or thread can discharge (the file header
    /// says why each one is bounded).
    pub fn takesReserve(self: *const Command) bool {
        return switch (self.*) {
            .worker_died, .forwarded_completion => true,
            .dispatch_ready => |*ready| ready.reader == .you_become_reader,
            .empty,
            .dispatch_failed,
            .forwarded_descriptor,
            .payload_consumed,
            .release_worker,
            .shutdown,
            => false,
        };
    }
};

pub const Counters = struct {
    posted: u64 = 0,
    dequeued: u64 = 0,
    /// Commands a full queue refused.
    refused_full: u64 = 0,
    eventfd_wakes: u64 = 0,
    eventfd_signal_failures: u64 = 0,
    eventfd_drain_failures: u64 = 0,
};

pub const Queue = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    /// A ring of `len` commands from `head`, oldest first.
    items: []Command,
    head: usize = 0,
    len: usize = 0,
    /// The places at the end of `items` that only `Command.takesReserve`
    /// commands may fill.
    reserve: usize,
    counters: Counters = .{},
    event_fd: std.posix.fd_t,

    /// Allocates `capacity` places for every command plus `reserve` places
    /// for the commands that may take the reserve, and the eventfd. Fails
    /// with `error.InvalidCommandQueueCapacity` for a zero `capacity`, and
    /// with the allocation's or the eventfd's error, leaving nothing
    /// allocated.
    pub fn init(allocator: std.mem.Allocator, capacity: usize, reserve: usize) !Queue {
        if (capacity == 0)
            return error.InvalidCommandQueueCapacity;
        const items = try allocator.alloc(Command, capacity + reserve);
        errdefer allocator.free(items);
        @memset(items, .empty);
        const event_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        return .{
            .allocator = allocator,
            .items = items,
            .reserve = reserve,
            .event_fd = event_fd,
        };
    }

    pub fn deinit(self: *Queue) void {
        var remaining = self.len;
        var index = self.head;
        while (remaining != 0) : (remaining -= 1) {
            self.items[index].deinit();
            index = (index + 1) % self.items.len;
        }
        if (self.event_fd >= 0)
            std.posix.close(self.event_fd);
        self.allocator.free(self.items);
        self.* = undefined;
    }

    pub fn commandEventFd(self: *const Queue) std.posix.fd_t {
        return self.event_fd;
    }

    /// Queues `command` and wakes the lane, and returns true; returns false
    /// when the queue is full for it. Consumes `command` on every path: a
    /// command that is not queued is freed (`Command.deinit`), and the caller
    /// keeps only the plain values it read before the call. Fails with
    /// `error.CommandEventfdCorrupt` when the wake cannot be written.
    pub fn post(self: *Queue, command: Command) error{CommandEventfdCorrupt}!bool {
        var refused = command;
        const queued = self.push(command) catch |err| {
            refused.deinit();
            return err;
        };
        if (!queued)
            refused.deinit();
        return queued;
    }

    pub fn dequeue(self: *Queue) ?Command {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len == 0)
            return null;
        const command = self.items[self.head];
        self.items[self.head] = .empty;
        self.head = (self.head + 1) % self.items.len;
        self.len -= 1;
        self.counters.dequeued += 1;
        return command;
    }

    /// The commands queued now, which bounds one drain: a command posted
    /// during the drain has written its own wake.
    pub fn pending(self: *Queue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.len;
    }

    /// Reads and clears the eventfd's count. A read that fails for any reason
    /// but an empty count, or returns a partial count, fails with
    /// `error.CommandEventfdCorrupt`.
    pub fn drainWake(self: *Queue) error{CommandEventfdCorrupt}!u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var value: u64 = 0;
        const read_len = std.posix.read(self.event_fd, std.mem.asBytes(&value)) catch |err| switch (err) {
            error.WouldBlock => return 0,
            else => {
                self.counters.eventfd_drain_failures += 1;
                return error.CommandEventfdCorrupt;
            },
        };
        if (read_len != @sizeOf(u64)) {
            self.counters.eventfd_drain_failures += 1;
            return error.CommandEventfdCorrupt;
        }
        if (value != 0)
            self.counters.eventfd_wakes += 1;
        return value;
    }

    /// Pushes `command` under the mutex unless the queue is full for it.
    /// Leaves freeing a refused command to `post`, outside the mutex.
    fn push(self: *Queue, command: Command) error{CommandEventfdCorrupt}!bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const limit = if (command.takesReserve()) self.items.len else self.items.len - self.reserve;
        if (self.len < limit) {
            try self.signalLocked();
            self.pushLocked(command);
            return true;
        } else {
            self.counters.refused_full += 1;
            return false;
        }
    }

    fn pushLocked(self: *Queue, command: Command) void {
        std.debug.assert(self.len < self.items.len);
        const index = (self.head + self.len) % self.items.len;
        std.debug.assert(std.meta.activeTag(self.items[index]) == .empty);
        self.items[index] = command;
        self.len += 1;
        self.counters.posted += 1;
    }

    fn signalLocked(self: *Queue) error{CommandEventfdCorrupt}!void {
        const value: u64 = 1;
        const written = std.posix.write(self.event_fd, std.mem.asBytes(&value)) catch {
            self.counters.eventfd_signal_failures += 1;
            return error.CommandEventfdCorrupt;
        };
        if (written != @sizeOf(u64)) {
            self.counters.eventfd_signal_failures += 1;
            return error.CommandEventfdCorrupt;
        }
    }
};
