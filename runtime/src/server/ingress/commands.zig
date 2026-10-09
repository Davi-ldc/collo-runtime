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
//! `lane_commands.zig` says for that command. The queue has ordinary places
//! and reserved ones, and each command's `Command.placement` says which it
//! may take:
//! - Worker output, a descriptor a reader forwards and the answer for its
//!   ring payload, takes only reserved places, so no worker's bytes can take
//!   a place the lane's own exchanges need.
//! - Three obligations take a reserved place, or an ordinary one once the
//!   reserve is full, because a refusal would cost more than the command: a
//!   worker's death, which the lane's requests on that worker would otherwise
//!   wait out to their deadlines; a slot whose grant makes the lane the
//!   worker's reader, which a refused post would hand back with the slot,
//!   leaving its waiting request to its deadline; and a completion a reader
//!   forwards, whose loss would leave a worker that answered in time to the
//!   grace backstop's fault.
//! - Every other command takes only ordinary places.
//!
//! A lane serving the configuration reserves, per worker table entry of every
//! pool, one place for a death, one for a reader grant, one per slot for a
//! completion, and the entry's forwarding window (`lane.obligationReserve`):
//! a worker dies once, the pool grants its reader role to one lane at a time,
//! a reader forwards at most one completion per request it was sent
//! (`RequestTable.claimCompletion`), and an entry's forwarded descriptors and
//! answers waiting in all lanes' queues together never pass
//! `limits.ingress.forwarded_commands_per_worker_max`
//! (`runner/h2_worker_ipc.zig`). So the reserve holds every obligation and
//! all worker output at once, and an obligation takes it first, leaving the
//! ordinary places to the commands that can take nothing else. The
//! obligations pass their share only when one entry's worker is launched,
//! dies and is retired again while the lane leaves an earlier command of that
//! entry unprocessed. The excess then fills ordinary places once the reserve
//! is full, and a forwarded descriptor that finds the reserve full meanwhile
//! is refused.
//!
//! The queue's places are a fault-in slab of nodes threaded on a FIFO
//! (`slab.zig`), so its memory follows the most commands it ever held at
//! once, not its capacity.

const std = @import("std");
const lifecycle = @import("collo_server_lifecycle");
const fault = @import("fault.zig");
const lane_commands = @import("lane_commands.zig");
const slab = @import("slab.zig");

pub const WorkerDied = struct {
    worker_key: lifecycle.WorkerKey,
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

    /// The places the command may take (the file header says why each kind
    /// is bounded).
    pub fn placement(self: *const Command) Placement {
        return switch (self.*) {
            .forwarded_descriptor,
            .payload_consumed,
            => .reserved_only,
            .worker_died,
            .forwarded_completion,
            => .reserved_first,
            .dispatch_ready => |*ready| switch (ready.reader) {
                .you_become_reader => .reserved_first,
                .already, .transfer_from => .ordinary_only,
            },
            .empty,
            .dispatch_failed,
            .release_worker,
            .shutdown,
            => .ordinary_only,
        };
    }
};

pub const Placement = enum {
    /// Worker output: a reserved place or none.
    reserved_only,
    /// An obligation: a reserved place, else an ordinary one.
    reserved_first,
    ordinary_only,
};

const PlaceKind = enum { ordinary, reserved };

/// One place of a queue.
const Node = struct {
    slab_link: slab.Link = .{},
    command: Command = .empty,
    /// The command counts against the reserved places.
    reserved: bool = false,
};

/// The memory one queued command costs, for the lane plan's charge.
pub const node_bytes: usize = @sizeOf(Node);

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
    mutex: std.Thread.Mutex = .{},
    /// Every place, `capacity + reserve` of them.
    nodes: slab.FaultInSlab(Node),
    /// The queued commands' places, oldest first.
    fifo: slab.Fifo(Node) = .{},
    /// The reserved places, which only worker output and obligations fill
    /// (`Command.placement`); the rest of `nodes` are ordinary places.
    reserve: usize,
    /// Queued commands in ordinary and in reserved places.
    ordinary_used: usize = 0,
    reserved_used: usize = 0,
    counters: Counters = .{},
    event_fd: std.posix.fd_t,

    /// Reserves `ordinary` places plus `reserve` reserved places, and creates
    /// the eventfd. Fails with
    /// `error.InvalidCommandQueueCapacity` for zero ordinary places, and with
    /// the mapping's or the eventfd's error, leaving nothing behind.
    pub fn init(ordinary: usize, reserve: usize) !Queue {
        if (ordinary == 0)
            return error.InvalidCommandQueueCapacity;
        const total = std.math.cast(u32, ordinary + reserve) orelse return error.InvalidCommandQueueCapacity;
        var nodes = try slab.FaultInSlab(Node).init(total);
        errdefer nodes.deinit();
        const event_fd = try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
        return .{
            .nodes = nodes,
            .reserve = reserve,
            .event_fd = event_fd,
        };
    }

    pub fn deinit(self: *Queue) void {
        while (self.fifo.pop(&self.nodes)) |index| {
            self.nodes.entries[index].command.deinit();
            self.nodes.release(index);
        }
        if (self.event_fd >= 0)
            std.posix.close(self.event_fd);
        self.nodes.deinit();
        self.* = undefined;
    }

    /// The places of the queue, ordinary and reserved.
    pub fn capacity(self: *const Queue) usize {
        return self.nodes.capacity();
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
        const index = self.fifo.pop(&self.nodes) orelse return null;
        const node = &self.nodes.entries[index];
        const command = node.command;
        node.command = .empty;
        if (node.reserved) {
            self.reserved_used -= 1;
        } else {
            self.ordinary_used -= 1;
        }
        self.nodes.release(index);
        self.counters.dequeued += 1;
        return command;
    }

    /// The commands queued now, which bounds one drain: a command posted
    /// during the drain has written its own wake.
    pub fn pending(self: *Queue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.fifo.len;
    }

    /// Writes a wake without queueing a command, for a lane whose wake bits
    /// changed (`LaneWorker.raiseWake` in `runner/root.zig`).
    pub fn wake(self: *Queue) error{CommandEventfdCorrupt}!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.signalLocked();
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

    /// Pushes `command` under the mutex unless every place it may take is
    /// taken. Leaves freeing a refused command to `post`, outside the mutex.
    fn push(self: *Queue, command: Command) error{CommandEventfdCorrupt}!bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const reserved_free = self.reserved_used < self.reserve;
        const ordinary_free = self.ordinary_used < self.nodes.capacity() - self.reserve;
        const place: ?PlaceKind = switch (command.placement()) {
            .reserved_only => if (reserved_free) .reserved else null,
            .reserved_first => if (reserved_free) .reserved else if (ordinary_free) .ordinary else null,
            .ordinary_only => if (ordinary_free) .ordinary else null,
        };
        if (place == null) {
            self.counters.refused_full += 1;
            return false;
        }
        const reserved = place.? == .reserved;
        const used = if (reserved) &self.reserved_used else &self.ordinary_used;
        try self.signalLocked();
        // Fewer places are queued than the queue has, and a place is free
        // exactly while it is not queued.
        const acquired = self.nodes.acquire().?;
        acquired.entry.command = command;
        acquired.entry.reserved = reserved;
        _ = self.fifo.push(&self.nodes, acquired.index);
        used.* += 1;
        self.counters.posted += 1;
        return true;
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
