//! The descriptors of a worker's egress sessions, which the server creates and
//! splits between the two sides without mapping any of them. A worker has one
//! wake set for its life (`WakeSet`): the two eventfds that wake the sides and
//! the read ends of the two liveness pipes. Each of its sessions, the one its
//! launch attaches and each one a later gateway gives it, is new region
//! memfds on that wake set (`createSessionForWorker`), because the worker's
//! io_uring registers the completion eventfd and the liveness pipe it watches
//! once, at boot, and can register no other file afterwards
//! (`common/io/restricted_uring.zig`).
//!
//! Every memfd is sized and sealed against growing and shrinking, a meta also
//! gets its magic, version, role and capacity, and each memfd gets a read-only
//! reopen through `/proc`, so a side can be handed a writable descriptor only
//! for what it writes and a read-only one for the rest; the kernel then
//! refuses its writes to the other side's state. `SessionFds.rawForGateway`
//! and `SessionFds.rawForWorker` name each side's half and the access each
//! descriptor grants, and `endpoint.zig` checks that access again when a side
//! maps its half.
//!
//! Both sides share the two eventfds. Each holds the write end of one liveness
//! pipe and the read end of the other, and a read end hangs up once no write
//! end is left, so the pipes carry exits only while each write end has one
//! holder: the wake set keeps no write end, every session opens its two anew
//! from the read ends, and the server closes its copies once each side has
//! its own. A gateway's death then hangs up the worker, and the worker's exit
//! or detach hangs up its gateway. Nothing here keeps state, so any thread
//! may call it.

const std = @import("std");
const fd_mod = @import("collo_os").fd;

const RingMeta = @import("region.zig").RingMeta;
const Role = @import("region.zig").Role;
const magic = @import("region.zig").magic;
const version = @import("region.zig").version;
const RingConsumerState = @import("packet_ring.zig").RingConsumerState;
const RingProducerState = @import("packet_ring.zig").RingProducerState;
const command_ring_capacity = @import("packet_ring.zig").command_ring_capacity;
const completion_ring_capacity = @import("packet_ring.zig").completion_ring_capacity;
const BodyPoolConsumerState = @import("body_pool.zig").BodyPoolConsumerState;
const BodyPoolProducerState = @import("body_pool.zig").BodyPoolProducerState;
const body_pool_capacity = @import("body_pool.zig").body_pool_capacity;

/// Descriptors of the four regions in one side's half: the first
/// `region_fd_count` of `RawFds.asArray`.
pub const region_fd_count: usize = 16;
/// Wake descriptors in one side's half (`WakeFds`): the last `wake_fd_count`
/// of `RawFds.asArray`.
pub const wake_fd_count: usize = 4;
/// Descriptors in one side's half of a session, one per `RawFds` field.
pub const shared_fd_count: usize = region_fd_count + wake_fd_count;

/// The wake descriptors of one side, as plain descriptors, -1 when absent:
/// the eventfd that wakes the gateway, the one that wakes the worker, an end
/// of the liveness pipe the worker watches and an end of the one the gateway
/// watches. The worker holds the read end of the first pipe and the write end
/// of the second, and the gateway the other two ends.
pub const WakeFds = struct {
    command_eventfd: std.posix.fd_t = -1,
    completion_eventfd: std.posix.fd_t = -1,
    liveness_fd: std.posix.fd_t = -1,
    peer_liveness_fd: std.posix.fd_t = -1,

    pub fn isValid(self: WakeFds) bool {
        return self.command_eventfd >= 0 and
            self.completion_eventfd >= 0 and
            self.liveness_fd >= 0 and
            self.peer_liveness_fd >= 0;
    }

    pub fn close(self: *WakeFds) void {
        closeFdSlot(&self.command_eventfd);
        closeFdSlot(&self.completion_eventfd);
        closeFdSlot(&self.liveness_fd);
        closeFdSlot(&self.peer_liveness_fd);
    }

    /// The descriptors in `RawFds.asArray` order.
    pub fn asArray(self: WakeFds) [wake_fd_count]std.posix.fd_t {
        std.debug.assert(self.isValid());
        return .{ self.command_eventfd, self.completion_eventfd, self.liveness_fd, self.peer_liveness_fd };
    }
};

/// One side's half of a session as plain descriptors, -1 when absent, in the
/// order `asArray` lists them, which is the order the gateway's attach packet,
/// `egress_attach` and WorkerInit carry them in: the regions, then the wake
/// descriptors. A worker launched without a session has its wake descriptors
/// and no region (`wakeOnly`).
pub const RawFds = struct {
    command_control_fd: std.posix.fd_t = -1,
    command_producer_fd: std.posix.fd_t = -1,
    command_consumer_fd: std.posix.fd_t = -1,
    command_data_fd: std.posix.fd_t = -1,
    completion_control_fd: std.posix.fd_t = -1,
    completion_producer_fd: std.posix.fd_t = -1,
    completion_consumer_fd: std.posix.fd_t = -1,
    completion_data_fd: std.posix.fd_t = -1,
    body_pool_control_fd: std.posix.fd_t = -1,
    body_pool_producer_fd: std.posix.fd_t = -1,
    body_pool_consumer_fd: std.posix.fd_t = -1,
    body_pool_data_fd: std.posix.fd_t = -1,
    upload_pool_control_fd: std.posix.fd_t = -1,
    upload_pool_producer_fd: std.posix.fd_t = -1,
    upload_pool_consumer_fd: std.posix.fd_t = -1,
    upload_pool_data_fd: std.posix.fd_t = -1,
    command_eventfd: std.posix.fd_t = -1,
    completion_eventfd: std.posix.fd_t = -1,
    liveness_fd: std.posix.fd_t = -1,
    peer_liveness_fd: std.posix.fd_t = -1,

    /// The descriptors of a worker that has no session: `wake` and no region.
    pub fn wakeOnly(wake: WakeFds) RawFds {
        return .{
            .command_eventfd = wake.command_eventfd,
            .completion_eventfd = wake.completion_eventfd,
            .liveness_fd = wake.liveness_fd,
            .peer_liveness_fd = wake.peer_liveness_fd,
        };
    }

    /// The half whose descriptors `fds` lists in `asArray` order.
    pub fn fromArray(fds: [shared_fd_count]std.posix.fd_t) RawFds {
        return .{
            .command_control_fd = fds[0],
            .command_producer_fd = fds[1],
            .command_consumer_fd = fds[2],
            .command_data_fd = fds[3],
            .completion_control_fd = fds[4],
            .completion_producer_fd = fds[5],
            .completion_consumer_fd = fds[6],
            .completion_data_fd = fds[7],
            .body_pool_control_fd = fds[8],
            .body_pool_producer_fd = fds[9],
            .body_pool_consumer_fd = fds[10],
            .body_pool_data_fd = fds[11],
            .upload_pool_control_fd = fds[12],
            .upload_pool_producer_fd = fds[13],
            .upload_pool_consumer_fd = fds[14],
            .upload_pool_data_fd = fds[15],
            .command_eventfd = fds[16],
            .completion_eventfd = fds[17],
            .liveness_fd = fds[18],
            .peer_liveness_fd = fds[19],
        };
    }

    pub fn wakeFds(self: RawFds) WakeFds {
        return .{
            .command_eventfd = self.command_eventfd,
            .completion_eventfd = self.completion_eventfd,
            .liveness_fd = self.liveness_fd,
            .peer_liveness_fd = self.peer_liveness_fd,
        };
    }

    /// How many of the `region_fd_count` region descriptors are present. A
    /// half a sender may send has all of them or, without a session, none.
    pub fn regionCount(self: RawFds) usize {
        const all = self.slots();
        var count: usize = 0;
        for (all[0..region_fd_count]) |fd| {
            if (fd >= 0)
                count += 1;
        }
        return count;
    }

    /// Whether every descriptor is present, the regions included.
    pub fn isValid(self: RawFds) bool {
        for (self.slots()) |fd| {
            if (fd < 0)
                return false;
        }
        return true;
    }

    pub fn close(self: *RawFds) void {
        closeFdSlot(&self.command_control_fd);
        closeFdSlot(&self.command_producer_fd);
        closeFdSlot(&self.command_consumer_fd);
        closeFdSlot(&self.command_data_fd);
        closeFdSlot(&self.completion_control_fd);
        closeFdSlot(&self.completion_producer_fd);
        closeFdSlot(&self.completion_consumer_fd);
        closeFdSlot(&self.completion_data_fd);
        closeFdSlot(&self.body_pool_control_fd);
        closeFdSlot(&self.body_pool_producer_fd);
        closeFdSlot(&self.body_pool_consumer_fd);
        closeFdSlot(&self.body_pool_data_fd);
        closeFdSlot(&self.upload_pool_control_fd);
        closeFdSlot(&self.upload_pool_producer_fd);
        closeFdSlot(&self.upload_pool_consumer_fd);
        closeFdSlot(&self.upload_pool_data_fd);
        closeFdSlot(&self.command_eventfd);
        closeFdSlot(&self.completion_eventfd);
        closeFdSlot(&self.liveness_fd);
        closeFdSlot(&self.peer_liveness_fd);
        self.* = .{};
    }

    pub fn asArray(self: RawFds) [shared_fd_count]std.posix.fd_t {
        std.debug.assert(self.isValid());
        return self.slots();
    }

    /// Every descriptor in `asArray` order, -1 where absent.
    fn slots(self: RawFds) [shared_fd_count]std.posix.fd_t {
        return .{
            self.command_control_fd,
            self.command_producer_fd,
            self.command_consumer_fd,
            self.command_data_fd,
            self.completion_control_fd,
            self.completion_producer_fd,
            self.completion_consumer_fd,
            self.completion_data_fd,
            self.body_pool_control_fd,
            self.body_pool_producer_fd,
            self.body_pool_consumer_fd,
            self.body_pool_data_fd,
            self.upload_pool_control_fd,
            self.upload_pool_producer_fd,
            self.upload_pool_consumer_fd,
            self.upload_pool_data_fd,
            self.command_eventfd,
            self.completion_eventfd,
            self.liveness_fd,
            self.peer_liveness_fd,
        };
    }
};

/// The wake descriptors every session of one worker shares, as the server
/// keeps them for the worker's life: both eventfds and the read ends of both
/// liveness pipes. It never holds a write end, so it keeps no pipe from
/// hanging up: the worker's exit still reaches each gateway it had, and a
/// gateway's death still reaches the worker.
pub const WakeSet = struct {
    command_event: fd_mod.OwnedFd = .{},
    completion_event: fd_mod.OwnedFd = .{},
    /// The read end of the pipe the worker watches, whose write end each
    /// session's gateway holds.
    liveness_read: fd_mod.OwnedFd = .{},
    /// The read end of the pipe each gateway of the worker watches, whose
    /// write end the worker holds while it has a session.
    peer_liveness_read: fd_mod.OwnedFd = .{},

    /// Creates a worker's wake set: both eventfds and both pipes, nonblocking
    /// and close-on-exec. The write ends `pipe2` returns close at once, since
    /// each session opens its own. The caller owns the result; a failure
    /// closes everything created so far.
    pub fn create() !WakeSet {
        var command_event = fd_mod.OwnedFd.fromRaw(try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK));
        errdefer command_event.deinit();
        var completion_event = fd_mod.OwnedFd.fromRaw(try std.posix.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK));
        errdefer completion_event.deinit();
        const liveness_pipe = try std.posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
        std.posix.close(liveness_pipe[1]);
        var liveness_read = fd_mod.OwnedFd.fromRaw(liveness_pipe[0]);
        errdefer liveness_read.deinit();
        const peer_liveness_pipe = try std.posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
        std.posix.close(peer_liveness_pipe[1]);
        return .{
            .command_event = command_event,
            .completion_event = completion_event,
            .liveness_read = liveness_read,
            .peer_liveness_read = fd_mod.OwnedFd.fromRaw(peer_liveness_pipe[0]),
        };
    }

    /// Close-on-exec dups of every descriptor, which the caller owns, for a
    /// holder that may outlive the set's owner. A failure closes the dups made
    /// so far.
    pub fn dup(self: *const WakeSet) !WakeSet {
        std.debug.assert(self.isValid());
        var command_event = try fd_mod.OwnedFd.dupCloexec(self.command_event.fd());
        errdefer command_event.deinit();
        var completion_event = try fd_mod.OwnedFd.dupCloexec(self.completion_event.fd());
        errdefer completion_event.deinit();
        var liveness_read = try fd_mod.OwnedFd.dupCloexec(self.liveness_read.fd());
        errdefer liveness_read.deinit();
        return .{
            .command_event = command_event,
            .completion_event = completion_event,
            .liveness_read = liveness_read,
            .peer_liveness_read = try fd_mod.OwnedFd.dupCloexec(self.peer_liveness_read.fd()),
        };
    }

    pub fn deinit(self: *WakeSet) void {
        self.command_event.deinit();
        self.completion_event.deinit();
        self.liveness_read.deinit();
        self.peer_liveness_read.deinit();
        self.* = .{};
    }

    pub fn isValid(self: WakeSet) bool {
        return self.command_event.isValid() and
            self.completion_event.isValid() and
            self.liveness_read.isValid() and
            self.peer_liveness_read.isValid();
    }

    /// The worker's wake descriptors for a WorkerInit that carries no
    /// session: dups of both eventfds and of the liveness read end, and a new
    /// write end of the pipe the gateways watch (`openPipeWriteEnd`). The
    /// caller owns them and closes them once the worker has its copies. A
    /// failure closes what was opened so far.
    pub fn openWorkerWake(self: *const WakeSet) !WakeFds {
        std.debug.assert(self.isValid());
        var command_event = try fd_mod.OwnedFd.dupCloexec(self.command_event.fd());
        errdefer command_event.deinit();
        var completion_event = try fd_mod.OwnedFd.dupCloexec(self.completion_event.fd());
        errdefer completion_event.deinit();
        var liveness_read = try fd_mod.OwnedFd.dupCloexec(self.liveness_read.fd());
        errdefer liveness_read.deinit();
        const peer_liveness_write = try openPipeWriteEnd(self.peer_liveness_read.fd());
        return .{
            .command_eventfd = command_event.release(),
            .completion_eventfd = completion_event.release(),
            .liveness_fd = liveness_read.release(),
            .peer_liveness_fd = peer_liveness_write,
        };
    }
};

/// Both halves of one session as owned descriptors: every region memfd as its
/// writable original and a read-only reopen (`*_read`), dups of the wake
/// set's two eventfds, which both halves carry, and an end of each liveness
/// pipe for each side, the read ends dups of the wake set's and the write ends
/// new opens. `rawForGateway` and `rawForWorker` name each side's half and the
/// access it gets.
pub const SessionFds = struct {
    command_control: fd_mod.OwnedFd = .{},
    command_control_read: fd_mod.OwnedFd = .{},
    command_producer: fd_mod.OwnedFd = .{},
    command_producer_read: fd_mod.OwnedFd = .{},
    command_consumer: fd_mod.OwnedFd = .{},
    command_consumer_read: fd_mod.OwnedFd = .{},
    command_data: fd_mod.OwnedFd = .{},
    command_data_read: fd_mod.OwnedFd = .{},
    completion_control: fd_mod.OwnedFd = .{},
    completion_control_read: fd_mod.OwnedFd = .{},
    completion_producer: fd_mod.OwnedFd = .{},
    completion_producer_read: fd_mod.OwnedFd = .{},
    completion_consumer: fd_mod.OwnedFd = .{},
    completion_consumer_read: fd_mod.OwnedFd = .{},
    completion_data: fd_mod.OwnedFd = .{},
    completion_data_read: fd_mod.OwnedFd = .{},
    body_pool_control: fd_mod.OwnedFd = .{},
    body_pool_control_read: fd_mod.OwnedFd = .{},
    body_pool_producer: fd_mod.OwnedFd = .{},
    body_pool_producer_read: fd_mod.OwnedFd = .{},
    body_pool_consumer: fd_mod.OwnedFd = .{},
    body_pool_consumer_read: fd_mod.OwnedFd = .{},
    body_pool_data: fd_mod.OwnedFd = .{},
    body_pool_data_read: fd_mod.OwnedFd = .{},
    upload_pool_control: fd_mod.OwnedFd = .{},
    upload_pool_control_read: fd_mod.OwnedFd = .{},
    upload_pool_producer: fd_mod.OwnedFd = .{},
    upload_pool_producer_read: fd_mod.OwnedFd = .{},
    upload_pool_consumer: fd_mod.OwnedFd = .{},
    upload_pool_consumer_read: fd_mod.OwnedFd = .{},
    upload_pool_data: fd_mod.OwnedFd = .{},
    upload_pool_data_read: fd_mod.OwnedFd = .{},
    command_event: fd_mod.OwnedFd = .{},
    completion_event: fd_mod.OwnedFd = .{},
    liveness_read: fd_mod.OwnedFd = .{},
    liveness_write: fd_mod.OwnedFd = .{},
    peer_liveness_read: fd_mod.OwnedFd = .{},
    peer_liveness_write: fd_mod.OwnedFd = .{},

    pub fn deinit(self: *SessionFds) void {
        self.command_control.deinit();
        self.command_control_read.deinit();
        self.command_producer.deinit();
        self.command_producer_read.deinit();
        self.command_consumer.deinit();
        self.command_consumer_read.deinit();
        self.command_data.deinit();
        self.command_data_read.deinit();
        self.completion_control.deinit();
        self.completion_control_read.deinit();
        self.completion_producer.deinit();
        self.completion_producer_read.deinit();
        self.completion_consumer.deinit();
        self.completion_consumer_read.deinit();
        self.completion_data.deinit();
        self.completion_data_read.deinit();
        self.body_pool_control.deinit();
        self.body_pool_control_read.deinit();
        self.body_pool_producer.deinit();
        self.body_pool_producer_read.deinit();
        self.body_pool_consumer.deinit();
        self.body_pool_consumer_read.deinit();
        self.body_pool_data.deinit();
        self.body_pool_data_read.deinit();
        self.upload_pool_control.deinit();
        self.upload_pool_control_read.deinit();
        self.upload_pool_producer.deinit();
        self.upload_pool_producer_read.deinit();
        self.upload_pool_consumer.deinit();
        self.upload_pool_consumer_read.deinit();
        self.upload_pool_data.deinit();
        self.upload_pool_data_read.deinit();
        self.command_event.deinit();
        self.completion_event.deinit();
        self.liveness_read.deinit();
        self.liveness_write.deinit();
        self.peer_liveness_read.deinit();
        self.peer_liveness_write.deinit();
        self.* = .{};
    }

    pub fn isValid(self: SessionFds) bool {
        return self.command_control.isValid() and
            self.command_control_read.isValid() and
            self.command_producer.isValid() and
            self.command_producer_read.isValid() and
            self.command_consumer.isValid() and
            self.command_consumer_read.isValid() and
            self.command_data.isValid() and
            self.command_data_read.isValid() and
            self.completion_control.isValid() and
            self.completion_control_read.isValid() and
            self.completion_producer.isValid() and
            self.completion_producer_read.isValid() and
            self.completion_consumer.isValid() and
            self.completion_consumer_read.isValid() and
            self.completion_data.isValid() and
            self.completion_data_read.isValid() and
            self.body_pool_control.isValid() and
            self.body_pool_control_read.isValid() and
            self.body_pool_producer.isValid() and
            self.body_pool_producer_read.isValid() and
            self.body_pool_consumer.isValid() and
            self.body_pool_consumer_read.isValid() and
            self.body_pool_data.isValid() and
            self.body_pool_data_read.isValid() and
            self.upload_pool_control.isValid() and
            self.upload_pool_control_read.isValid() and
            self.upload_pool_producer.isValid() and
            self.upload_pool_producer_read.isValid() and
            self.upload_pool_consumer.isValid() and
            self.upload_pool_consumer_read.isValid() and
            self.upload_pool_data.isValid() and
            self.upload_pool_data_read.isValid() and
            self.command_event.isValid() and
            self.completion_event.isValid() and
            self.liveness_read.isValid() and
            self.liveness_write.isValid() and
            self.peer_liveness_read.isValid() and
            self.peer_liveness_write.isValid();
    }

    /// The gateway's half, borrowed from `self`. The gateway writes every meta,
    /// where it stamps the session, the command ring's consumer state, the
    /// completion ring's producer state and data, all of the body pool, and
    /// the upload pool's consumer state, where it queues releases; the rest
    /// is read-only. It holds the write end of the liveness pipe the worker
    /// watches and the read end of the one the worker holds open.
    pub fn rawForGateway(self: SessionFds) RawFds {
        std.debug.assert(self.isValid());
        return .{
            .command_control_fd = self.command_control.fd(),
            .command_producer_fd = self.command_producer_read.fd(),
            .command_consumer_fd = self.command_consumer.fd(),
            .command_data_fd = self.command_data_read.fd(),
            .completion_control_fd = self.completion_control.fd(),
            .completion_producer_fd = self.completion_producer.fd(),
            .completion_consumer_fd = self.completion_consumer_read.fd(),
            .completion_data_fd = self.completion_data.fd(),
            .body_pool_control_fd = self.body_pool_control.fd(),
            .body_pool_producer_fd = self.body_pool_producer.fd(),
            .body_pool_consumer_fd = self.body_pool_consumer.fd(),
            .body_pool_data_fd = self.body_pool_data.fd(),
            .upload_pool_control_fd = self.upload_pool_control.fd(),
            .upload_pool_producer_fd = self.upload_pool_producer_read.fd(),
            .upload_pool_consumer_fd = self.upload_pool_consumer.fd(),
            .upload_pool_data_fd = self.upload_pool_data_read.fd(),
            .command_eventfd = self.command_event.fd(),
            .completion_eventfd = self.completion_event.fd(),
            .liveness_fd = self.liveness_write.fd(),
            .peer_liveness_fd = self.peer_liveness_read.fd(),
        };
    }

    /// The worker's half, borrowed from `self`. The worker writes the command
    /// ring's producer state and data, the completion ring's consumer state,
    /// the body pool's consumer state, where it queues releases, and the
    /// upload pool's producer state, consumer state and data, the mirror of
    /// the gateway's body pool; every meta and the rest are read-only. It
    /// holds the read end of the liveness pipe the gateway holds open and the
    /// write end of the one the gateway watches.
    pub fn rawForWorker(self: SessionFds) RawFds {
        std.debug.assert(self.isValid());
        return .{
            .command_control_fd = self.command_control_read.fd(),
            .command_producer_fd = self.command_producer.fd(),
            .command_consumer_fd = self.command_consumer_read.fd(),
            .command_data_fd = self.command_data.fd(),
            .completion_control_fd = self.completion_control_read.fd(),
            .completion_producer_fd = self.completion_producer_read.fd(),
            .completion_consumer_fd = self.completion_consumer.fd(),
            .completion_data_fd = self.completion_data_read.fd(),
            .body_pool_control_fd = self.body_pool_control_read.fd(),
            .body_pool_producer_fd = self.body_pool_producer_read.fd(),
            .body_pool_consumer_fd = self.body_pool_consumer.fd(),
            .body_pool_data_fd = self.body_pool_data_read.fd(),
            .upload_pool_control_fd = self.upload_pool_control_read.fd(),
            .upload_pool_producer_fd = self.upload_pool_producer.fd(),
            .upload_pool_consumer_fd = self.upload_pool_consumer.fd(),
            .upload_pool_data_fd = self.upload_pool_data.fd(),
            .command_eventfd = self.command_event.fd(),
            .completion_eventfd = self.completion_event.fd(),
            .liveness_fd = self.liveness_read.fd(),
            .peer_liveness_fd = self.peer_liveness_write.fd(),
        };
    }

    /// Closes every descriptor outside the worker's half and hands that half
    /// to the caller, who must close it; `self` is left holding nothing. The
    /// gateway's write end of the pipe the worker watches closes here, so the
    /// caller takes the worker's half once the gateway has its own copies.
    pub fn takeWorkerHalf(self: *SessionFds) RawFds {
        self.liveness_write.deinit();
        self.peer_liveness_read.deinit();
        self.command_control.deinit();
        self.command_producer_read.deinit();
        self.command_consumer.deinit();
        self.command_data_read.deinit();
        self.completion_control.deinit();
        self.completion_producer.deinit();
        self.completion_consumer_read.deinit();
        self.completion_data.deinit();
        self.body_pool_control.deinit();
        self.body_pool_producer.deinit();
        self.body_pool_consumer_read.deinit();
        self.body_pool_data.deinit();
        self.upload_pool_control.deinit();
        self.upload_pool_producer_read.deinit();
        self.upload_pool_consumer_read.deinit();
        self.upload_pool_data_read.deinit();
        return .{
            .command_control_fd = self.command_control_read.release(),
            .command_producer_fd = self.command_producer.release(),
            .command_consumer_fd = self.command_consumer_read.release(),
            .command_data_fd = self.command_data.release(),
            .completion_control_fd = self.completion_control_read.release(),
            .completion_producer_fd = self.completion_producer_read.release(),
            .completion_consumer_fd = self.completion_consumer.release(),
            .completion_data_fd = self.completion_data_read.release(),
            .body_pool_control_fd = self.body_pool_control_read.release(),
            .body_pool_producer_fd = self.body_pool_producer_read.release(),
            .body_pool_consumer_fd = self.body_pool_consumer.release(),
            .body_pool_data_fd = self.body_pool_data_read.release(),
            .upload_pool_control_fd = self.upload_pool_control_read.release(),
            .upload_pool_producer_fd = self.upload_pool_producer.release(),
            .upload_pool_consumer_fd = self.upload_pool_consumer.release(),
            .upload_pool_data_fd = self.upload_pool_data.release(),
            .command_eventfd = self.command_event.release(),
            .completion_eventfd = self.completion_event.release(),
            .liveness_fd = self.liveness_read.release(),
            .peer_liveness_fd = self.peer_liveness_write.release(),
        };
    }
};

/// Creates both halves of a new session of the worker whose wake set is
/// `wake_set`: every region memfd sized and size-sealed with its meta written
/// and a read-only reopen of each, dups of the wake set's eventfds and read
/// ends, and a new write end of each liveness pipe (`openPipeWriteEnd`), all
/// close-on-exec. The caller owns the result and closes each half's copies
/// once its side has its own; until then each pipe has the caller's write end
/// as a second writer. A failure closes everything created so far. It reopens
/// through `/proc`, so only a process that has `/proc` can call it.
pub fn createSessionForWorker(wake_set: *const WakeSet) !SessionFds {
    std.debug.assert(wake_set.isValid());
    var command_control = fd_mod.OwnedFd.fromRaw(try createRingControlMemfd("collo-egress-command-control", .command, command_ring_capacity));
    errdefer command_control.deinit();
    var command_control_read = fd_mod.OwnedFd.fromRaw(try reopenReadOnly(command_control.fd()));
    errdefer command_control_read.deinit();
    var command_producer = fd_mod.OwnedFd.fromRaw(try createRingProducerMemfd("collo-egress-command-producer"));
    errdefer command_producer.deinit();
    var command_producer_read = fd_mod.OwnedFd.fromRaw(try reopenReadOnly(command_producer.fd()));
    errdefer command_producer_read.deinit();
    var command_consumer = fd_mod.OwnedFd.fromRaw(try createRingConsumerMemfd("collo-egress-command-consumer"));
    errdefer command_consumer.deinit();
    var command_consumer_read = fd_mod.OwnedFd.fromRaw(try reopenReadOnly(command_consumer.fd()));
    errdefer command_consumer_read.deinit();
    var command_data = fd_mod.OwnedFd.fromRaw(try createRingDataMemfd("collo-egress-command-data", command_ring_capacity));
    errdefer command_data.deinit();
    var command_data_read = fd_mod.OwnedFd.fromRaw(try reopenReadOnly(command_data.fd()));
    errdefer command_data_read.deinit();
    var completion_control = fd_mod.OwnedFd.fromRaw(try createRingControlMemfd("collo-egress-completion-control", .completion, completion_ring_capacity));
    errdefer completion_control.deinit();
    var completion_control_read = fd_mod.OwnedFd.fromRaw(try reopenReadOnly(completion_control.fd()));
    errdefer completion_control_read.deinit();
    var completion_producer = fd_mod.OwnedFd.fromRaw(try createRingProducerMemfd("collo-egress-completion-producer"));
    errdefer completion_producer.deinit();
    var completion_producer_read = fd_mod.OwnedFd.fromRaw(try reopenReadOnly(completion_producer.fd()));
    errdefer completion_producer_read.deinit();
    var completion_consumer = fd_mod.OwnedFd.fromRaw(try createRingConsumerMemfd("collo-egress-completion-consumer"));
    errdefer completion_consumer.deinit();
    var completion_consumer_read = fd_mod.OwnedFd.fromRaw(try reopenReadOnly(completion_consumer.fd()));
    errdefer completion_consumer_read.deinit();
    var completion_data = fd_mod.OwnedFd.fromRaw(try createRingDataMemfd("collo-egress-completion-data", completion_ring_capacity));
    errdefer completion_data.deinit();
    var completion_data_read = fd_mod.OwnedFd.fromRaw(try reopenReadOnly(completion_data.fd()));
    errdefer completion_data_read.deinit();
    var body_pool_control = fd_mod.OwnedFd.fromRaw(try createRingControlMemfd("collo-egress-body-pool-control", .body_pool, body_pool_capacity));
    errdefer body_pool_control.deinit();
    var body_pool_control_read = fd_mod.OwnedFd.fromRaw(try reopenReadOnly(body_pool_control.fd()));
    errdefer body_pool_control_read.deinit();
    var body_pool_producer = fd_mod.OwnedFd.fromRaw(try createBodyPoolProducerMemfd("collo-egress-body-pool-producer"));
    errdefer body_pool_producer.deinit();
    var body_pool_producer_read = fd_mod.OwnedFd.fromRaw(try reopenReadOnly(body_pool_producer.fd()));
    errdefer body_pool_producer_read.deinit();
    var body_pool_consumer = fd_mod.OwnedFd.fromRaw(try createBodyPoolConsumerMemfd("collo-egress-body-pool-consumer"));
    errdefer body_pool_consumer.deinit();
    var body_pool_consumer_read = fd_mod.OwnedFd.fromRaw(try reopenReadOnly(body_pool_consumer.fd()));
    errdefer body_pool_consumer_read.deinit();
    var body_pool_data = fd_mod.OwnedFd.fromRaw(try createRingDataMemfd("collo-egress-body-pool-data", body_pool_capacity));
    errdefer body_pool_data.deinit();
    var body_pool_data_read = fd_mod.OwnedFd.fromRaw(try reopenReadOnly(body_pool_data.fd()));
    errdefer body_pool_data_read.deinit();
    var upload_pool_control = fd_mod.OwnedFd.fromRaw(try createRingControlMemfd("collo-egress-upload-pool-control", .upload_pool, body_pool_capacity));
    errdefer upload_pool_control.deinit();
    var upload_pool_control_read = fd_mod.OwnedFd.fromRaw(try reopenReadOnly(upload_pool_control.fd()));
    errdefer upload_pool_control_read.deinit();
    var upload_pool_producer = fd_mod.OwnedFd.fromRaw(try createBodyPoolProducerMemfd("collo-egress-upload-pool-producer"));
    errdefer upload_pool_producer.deinit();
    var upload_pool_producer_read = fd_mod.OwnedFd.fromRaw(try reopenReadOnly(upload_pool_producer.fd()));
    errdefer upload_pool_producer_read.deinit();
    var upload_pool_consumer = fd_mod.OwnedFd.fromRaw(try createBodyPoolConsumerMemfd("collo-egress-upload-pool-consumer"));
    errdefer upload_pool_consumer.deinit();
    var upload_pool_consumer_read = fd_mod.OwnedFd.fromRaw(try reopenReadOnly(upload_pool_consumer.fd()));
    errdefer upload_pool_consumer_read.deinit();
    var upload_pool_data = fd_mod.OwnedFd.fromRaw(try createRingDataMemfd("collo-egress-upload-pool-data", body_pool_capacity));
    errdefer upload_pool_data.deinit();
    var upload_pool_data_read = fd_mod.OwnedFd.fromRaw(try reopenReadOnly(upload_pool_data.fd()));
    errdefer upload_pool_data_read.deinit();
    var command_event = try fd_mod.OwnedFd.dupCloexec(wake_set.command_event.fd());
    errdefer command_event.deinit();
    var completion_event = try fd_mod.OwnedFd.dupCloexec(wake_set.completion_event.fd());
    errdefer completion_event.deinit();
    var liveness_read = try fd_mod.OwnedFd.dupCloexec(wake_set.liveness_read.fd());
    errdefer liveness_read.deinit();
    var liveness_write = fd_mod.OwnedFd.fromRaw(try openPipeWriteEnd(wake_set.liveness_read.fd()));
    errdefer liveness_write.deinit();
    var peer_liveness_read = try fd_mod.OwnedFd.dupCloexec(wake_set.peer_liveness_read.fd());
    errdefer peer_liveness_read.deinit();
    var peer_liveness_write = fd_mod.OwnedFd.fromRaw(try openPipeWriteEnd(wake_set.peer_liveness_read.fd()));
    errdefer peer_liveness_write.deinit();
    return .{
        .command_control = command_control,
        .command_control_read = command_control_read,
        .command_producer = command_producer,
        .command_producer_read = command_producer_read,
        .command_consumer = command_consumer,
        .command_consumer_read = command_consumer_read,
        .command_data = command_data,
        .command_data_read = command_data_read,
        .completion_control = completion_control,
        .completion_control_read = completion_control_read,
        .completion_producer = completion_producer,
        .completion_producer_read = completion_producer_read,
        .completion_consumer = completion_consumer,
        .completion_consumer_read = completion_consumer_read,
        .completion_data = completion_data,
        .completion_data_read = completion_data_read,
        .body_pool_control = body_pool_control,
        .body_pool_control_read = body_pool_control_read,
        .body_pool_producer = body_pool_producer,
        .body_pool_producer_read = body_pool_producer_read,
        .body_pool_consumer = body_pool_consumer,
        .body_pool_consumer_read = body_pool_consumer_read,
        .body_pool_data = body_pool_data,
        .body_pool_data_read = body_pool_data_read,
        .upload_pool_control = upload_pool_control,
        .upload_pool_control_read = upload_pool_control_read,
        .upload_pool_producer = upload_pool_producer,
        .upload_pool_producer_read = upload_pool_producer_read,
        .upload_pool_consumer = upload_pool_consumer,
        .upload_pool_consumer_read = upload_pool_consumer_read,
        .upload_pool_data = upload_pool_data,
        .upload_pool_data_read = upload_pool_data_read,
        .command_event = command_event,
        .completion_event = completion_event,
        .liveness_read = liveness_read,
        .liveness_write = liveness_write,
        .peer_liveness_read = peer_liveness_read,
        .peer_liveness_write = peer_liveness_write,
    };
}

fn closeFdSlot(fd: *std.posix.fd_t) void {
    if (fd.* >= 0)
        std.posix.close(fd.*);
    fd.* = -1;
}

fn createRingControlMemfd(name: [:0]const u8, role: Role, capacity: usize) !std.posix.fd_t {
    if (capacity == 0 or capacity > std.math.maxInt(u32))
        return error.InvalidEgressSharedRing;
    const fd = try std.posix.memfd_create(name, std.os.linux.MFD.CLOEXEC | std.os.linux.MFD.ALLOW_SEALING);
    errdefer std.posix.close(fd);
    try std.posix.ftruncate(fd, @sizeOf(RingMeta));
    var meta = std.mem.zeroes(RingMeta);
    meta.magic = magic;
    meta.version = version;
    meta.role = @intFromEnum(role);
    meta.capacity = @intCast(capacity);
    const written = try std.posix.pwrite(fd, std.mem.asBytes(&meta), 0);
    if (written != @sizeOf(RingMeta))
        return error.ShortWrite;
    try fd_mod.addSeals(fd, fd_mod.memfd_size_seals);
    return fd;
}

fn createRingProducerMemfd(name: [:0]const u8) !std.posix.fd_t {
    return createStateMemfd(RingProducerState, name);
}

fn createRingConsumerMemfd(name: [:0]const u8) !std.posix.fd_t {
    return createStateMemfd(RingConsumerState, name);
}

fn createBodyPoolProducerMemfd(name: [:0]const u8) !std.posix.fd_t {
    return createStateMemfd(BodyPoolProducerState, name);
}

fn createBodyPoolConsumerMemfd(name: [:0]const u8) !std.posix.fd_t {
    return createStateMemfd(BodyPoolConsumerState, name);
}

fn createStateMemfd(comptime T: type, name: [:0]const u8) !std.posix.fd_t {
    const fd = try std.posix.memfd_create(name, std.os.linux.MFD.CLOEXEC | std.os.linux.MFD.ALLOW_SEALING);
    errdefer std.posix.close(fd);
    // A new memfd reads as zeros after ftruncate, and all zeros is a valid
    // initial state for every state struct (a zero `next_generation` counts
    // as 1), so nothing is written: writing the zeros would commit pages that
    // otherwise stay unallocated until first touched. This holds only because
    // the memfd is new on every call; a reused one would need zeroing.
    try std.posix.ftruncate(fd, @sizeOf(T));
    try fd_mod.addSeals(fd, fd_mod.memfd_size_seals);
    return fd;
}

fn createRingDataMemfd(name: [:0]const u8, capacity: usize) !std.posix.fd_t {
    if (capacity == 0 or capacity > std.math.maxInt(u32))
        return error.InvalidEgressSharedRing;
    const fd = try std.posix.memfd_create(name, std.os.linux.MFD.CLOEXEC | std.os.linux.MFD.ALLOW_SEALING);
    errdefer std.posix.close(fd);
    try std.posix.ftruncate(fd, capacity);
    try fd_mod.addSeals(fd, fd_mod.memfd_size_seals);
    return fd;
}

/// A new read-only open of the memfd behind `fd`, through its `/proc/self/fd`
/// link. A dup would share the writable open, and a peer holding it could map
/// the region writable; mmap refuses a shared writable mapping of this one.
fn reopenReadOnly(fd: std.posix.fd_t) !std.posix.fd_t {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/proc/self/fd/{d}", .{fd});
    return try std.posix.openZ(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
}

/// A new write end, nonblocking and close-on-exec, of the pipe whose read end
/// is `read_fd`, opened through its `/proc/self/fd` link: both ends of a pipe
/// share one inode, so the open reaches that pipe and adds a writer to it,
/// and the read end stops reporting a hang-up until this end closes. A
/// nonblocking write-only open of a pipe with no reader fails with ENXIO, which
/// `read_fd` itself rules out.
fn openPipeWriteEnd(read_fd: std.posix.fd_t) !std.posix.fd_t {
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/proc/self/fd/{d}", .{read_fd});
    return try std.posix.openZ(path, .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true }, 0);
}
