//! The identities and states that several server modules share: the HTTP/2
//! ingress (`collo_server_h2`), the supervisor, the gateway client and the
//! server itself are built as separate modules, so these types live in
//! `collo_server_lifecycle`, which imports only `collo_os`.
//!
//! A key names a lane slot or a worker together with its generation, so a
//! message about a slot or worker id that has been reused since no longer
//! matches. `nextGeneration` never returns 0, which only an unassigned key
//! holds.

const std = @import("std");
const fd_mod = @import("collo_os").fd;

pub const invalid_slot: u32 = std.math.maxInt(u32);

pub const ConnectionKey = struct {
    lane_id: u16,
    slot: u32,
    generation: u64,

    pub fn eql(self: ConnectionKey, other: ConnectionKey) bool {
        return self.lane_id == other.lane_id and
            self.slot == other.slot and
            self.generation == other.generation;
    }
};

pub const RequestKey = struct {
    lane_id: u16,
    slot: u32,
    generation: u64,

    pub fn eql(self: RequestKey, other: RequestKey) bool {
        return self.lane_id == other.lane_id and
            self.slot == other.slot and
            self.generation == other.generation;
    }
};

pub const WorkerKey = struct {
    worker_id: u64,
    worker_generation: u64,

    pub fn eql(self: WorkerKey, other: WorkerKey) bool {
        return self.worker_id == other.worker_id and
            self.worker_generation == other.worker_generation;
    }
};

pub const RequestOwnershipState = enum {
    server_owned,
    handoff_pending,
    worker_owned,
    terminal,
};

/// The worker's half of one gateway session, as WorkerInit and
/// `egress_attach` carry it; `deinit` closes the server's copies once the
/// worker has its own. `generation` and `session_id` name the session.
/// `isValid` holds only when every descriptor is open and the session id is
/// nonzero.
pub const EgressGatewayAttachment = struct {
    command_control: fd_mod.OwnedFd = .{},
    command_producer: fd_mod.OwnedFd = .{},
    command_consumer: fd_mod.OwnedFd = .{},
    command_data: fd_mod.OwnedFd = .{},
    completion_control: fd_mod.OwnedFd = .{},
    completion_producer: fd_mod.OwnedFd = .{},
    completion_consumer: fd_mod.OwnedFd = .{},
    completion_data: fd_mod.OwnedFd = .{},
    body_pool_control: fd_mod.OwnedFd = .{},
    body_pool_producer: fd_mod.OwnedFd = .{},
    body_pool_consumer: fd_mod.OwnedFd = .{},
    body_pool_data: fd_mod.OwnedFd = .{},
    upload_pool_control: fd_mod.OwnedFd = .{},
    upload_pool_producer: fd_mod.OwnedFd = .{},
    upload_pool_consumer: fd_mod.OwnedFd = .{},
    upload_pool_data: fd_mod.OwnedFd = .{},
    command_event: fd_mod.OwnedFd = .{},
    completion_event: fd_mod.OwnedFd = .{},
    liveness: fd_mod.OwnedFd = .{},
    peer_liveness: fd_mod.OwnedFd = .{},
    generation: u64 = 0,
    session_id: u64 = 0,

    pub fn deinit(self: *EgressGatewayAttachment) void {
        self.command_control.deinit();
        self.command_producer.deinit();
        self.command_consumer.deinit();
        self.command_data.deinit();
        self.completion_control.deinit();
        self.completion_producer.deinit();
        self.completion_consumer.deinit();
        self.completion_data.deinit();
        self.body_pool_control.deinit();
        self.body_pool_producer.deinit();
        self.body_pool_consumer.deinit();
        self.body_pool_data.deinit();
        self.upload_pool_control.deinit();
        self.upload_pool_producer.deinit();
        self.upload_pool_consumer.deinit();
        self.upload_pool_data.deinit();
        self.command_event.deinit();
        self.completion_event.deinit();
        self.liveness.deinit();
        self.peer_liveness.deinit();
        self.* = .{};
    }

    pub fn isValid(self: EgressGatewayAttachment) bool {
        return self.command_control.isValid() and
            self.command_producer.isValid() and
            self.command_consumer.isValid() and
            self.command_data.isValid() and
            self.completion_control.isValid() and
            self.completion_producer.isValid() and
            self.completion_consumer.isValid() and
            self.completion_data.isValid() and
            self.body_pool_control.isValid() and
            self.body_pool_producer.isValid() and
            self.body_pool_consumer.isValid() and
            self.body_pool_data.isValid() and
            self.upload_pool_control.isValid() and
            self.upload_pool_producer.isValid() and
            self.upload_pool_consumer.isValid() and
            self.upload_pool_data.isValid() and
            self.command_event.isValid() and
            self.completion_event.isValid() and
            self.liveness.isValid() and
            self.peer_liveness.isValid() and
            self.session_id != 0;
    }
};

pub fn nextGeneration(generation: u64) u64 {
    const next = generation +% 1;
    return if (next == 0) 1 else next;
}
