//! The worker's writes to the live request slots and the usage record ring
//! of its shared state page (`page.zig`), through `WorkState`, and the death
//! record the host builds from a live slot's snapshot. The worker claims,
//! updates and frees slots and appends records from its VM thread; the host
//! reads both only through `page/snapshots.zig`.
//!
//! The usage record ring has one producer, the worker's VM thread. The
//! sentinel thread writes only the lifecycle header and never touches the
//! ring. A record is complete before `records_head` moves past it. Every
//! store and load is atomic, because the other process reads and writes the
//! same page at any moment.

const page = @import("page.zig");

/// A claimed live slot: its index and the generation the claim stored there.
pub const LiveSlotHandle = struct {
    index: u32,
    generation: u64,
};

/// The worker's access to the live slots and the usage record ring of its
/// mapped page. It borrows `view`, which must outlive it.
pub const WorkState = struct {
    view: *page.WorkerWriterView,

    pub fn init(view: *page.WorkerWriterView) WorkState {
        return .{ .view = view };
    }

    /// Claims an empty live slot for the request `identity` names. Fails with
    /// `error.InvalidRequestId` for a zero request id and with
    /// `error.NoFreeLiveSlot` when every slot holds a request in flight.
    pub fn allocateLiveSlot(self: *WorkState, identity: page.LifecycleIdentity) !LiveSlotHandle {
        if (identity.external_request_id == 0)
            return error.InvalidRequestId;

        for (self.view.live_slots, 0..) |*slot, index| {
            const state = @atomicLoad(u32, &slot.state, .acquire);
            if (state != @intFromEnum(page.LiveSlotState.empty))
                continue;

            var generation = @atomicLoad(u64, &slot.generation, .acquire) +% 1;
            if (generation == 0)
                generation = 1;
            @atomicStore(u64, &slot.generation, generation, .release);
            @atomicStore(u64, &slot.request_id, identity.external_request_id, .release);
            @atomicStore(u64, &slot.request_generation, identity.request_generation, .release);
            @atomicStore(u64, &slot.worker_id, identity.worker_id, .release);
            @atomicStore(u64, &slot.worker_generation, identity.worker_generation, .release);
            @atomicStore(u64, &slot.cpu_ns, 0, .release);
            @atomicStore(u32, &slot.request_slot, identity.request_slot, .release);
            @atomicStore(u16, &slot.request_lane_id, identity.request_lane_id, .release);
            @atomicStore(u16, &slot._reserved1, 0, .release);
            // `state` is stored last, so a host that loads `active` with
            // acquire ordering then sees every field of this request
            // (`LiveSlotSnapshot.load`).
            @atomicStore(u32, &slot.state, @intFromEnum(page.LiveSlotState.active), .release);
            return .{
                .index = @intCast(index),
                .generation = generation,
            };
        }

        return error.NoFreeLiveSlot;
    }

    /// Clears the slot `handle` claimed and marks it empty. Fails with
    /// `error.InvalidLiveSlot` for an index past the page's slots and with
    /// `error.StaleLiveSlot` when the slot no longer holds this claim.
    pub fn freeLiveSlot(self: *WorkState, handle: LiveSlotHandle) !void {
        const slot = try self.claimedSlot(handle);
        @atomicStore(u64, &slot.request_id, 0, .release);
        @atomicStore(u64, &slot.request_generation, 0, .release);
        @atomicStore(u64, &slot.worker_id, 0, .release);
        @atomicStore(u64, &slot.worker_generation, 0, .release);
        @atomicStore(u64, &slot.cpu_ns, 0, .release);
        @atomicStore(u32, &slot.request_slot, 0, .release);
        @atomicStore(u16, &slot.request_lane_id, 0, .release);
        @atomicStore(u16, &slot._reserved1, 0, .release);
        @atomicStore(u32, &slot.state, @intFromEnum(page.LiveSlotState.empty), .release);
    }

    /// Publishes the CPU the request has used so far, which a record the host
    /// writes for the request reports if the worker never completes it. Fails
    /// like `freeLiveSlot`.
    pub fn updateLiveSlotCpu(self: *WorkState, handle: LiveSlotHandle, cpu_ns: u64) !void {
        const slot = try self.claimedSlot(handle);
        @atomicStore(u64, &slot.cpu_ns, cpu_ns, .release);
    }

    /// Appends `record` to the usage record ring. A full ring marks the
    /// worker dead with reason `crash` and fails with
    /// `error.CompletedRecordRingFull`. A record that cannot be published
    /// must stop the worker, so the caller stops it, and the host then writes
    /// the records of its requests in flight itself.
    pub fn appendCompletedRecord(self: *WorkState, record: page.CompletedRecord) !void {
        const head = @atomicLoad(u64, &self.view.header.records_head, .acquire);
        const tail = @atomicLoad(u64, &self.view.header.records_tail, .acquire);
        if (head -% tail >= page.RECORD_RING_COUNT) {
            self.view.setState(.dead, .crash);
            return error.CompletedRecordRingFull;
        }

        const write_index: usize = @intCast(head % @as(u64, page.RECORD_RING_COUNT));
        storeCompletedRecord(&self.view.completed_records[write_index], record);
        @atomicStore(u64, &self.view.header.records_head, head +% 1, .release);
    }

    /// The slot `handle` names while it still holds that claim.
    fn claimedSlot(self: *WorkState, handle: LiveSlotHandle) !*page.LiveRequestSlot {
        if (handle.index >= self.view.live_slots.len)
            return error.InvalidLiveSlot;
        const slot = &self.view.live_slots[handle.index];
        if (@atomicLoad(u32, &slot.state, .acquire) != @intFromEnum(page.LiveSlotState.active))
            return error.StaleLiveSlot;
        if (@atomicLoad(u64, &slot.generation, .acquire) != handle.generation)
            return error.StaleLiveSlot;
        return slot;
    }
};

/// Host side. The usage record of a request its worker never completed,
/// built from what its live slot measured until then, as `snapshot` copied
/// it: the request key and the CPU. The caller matched the snapshot against
/// the request's identity first (`LiveSlotSnapshot.find`), so the key copied
/// here is the one the host dispatched. A live slot holds no partition of the
/// request's time and no byte meter, so those stay zero.
pub fn synthesizeDeathRecord(
    snapshot: page.LiveSlotSnapshot,
    status: page.CompletedStatus,
) page.CompletedRecord {
    return .{
        .request_id = snapshot.request_id,
        .request_generation = snapshot.request_generation,
        .cpu_ns = snapshot.cpu_ns,
        .request_slot = snapshot.request_slot,
        .request_lane_id = snapshot.request_lane_id,
        .status = @intFromEnum(status),
    };
}

fn storeCompletedRecord(dst: *page.CompletedRecord, record: page.CompletedRecord) void {
    @atomicStore(u64, &dst.request_id, record.request_id, .release);
    @atomicStore(u64, &dst.request_generation, record.request_generation, .release);
    @atomicStore(u64, &dst.exec_ns, record.exec_ns, .release);
    @atomicStore(u64, &dst.waiting_ns, record.waiting_ns, .release);
    @atomicStore(u64, &dst.io_ns, record.io_ns, .release);
    @atomicStore(u64, &dst.cpu_ns, record.cpu_ns, .release);
    @atomicStore(u64, &dst.client_served_bytes, record.client_served_bytes, .release);
    @atomicStore(u64, &dst.fetch_sent_bytes, record.fetch_sent_bytes, .release);
    @atomicStore(u64, &dst.fetch_received_bytes, record.fetch_received_bytes, .release);
    @atomicStore(u64, &dst.fetch_wire_bytes, record.fetch_wire_bytes, .release);
    @atomicStore(u32, &dst.request_slot, record.request_slot, .release);
    @atomicStore(u16, &dst.request_lane_id, record.request_lane_id, .release);
    @atomicStore(u16, &dst._reserved1, record._reserved1, .release);
    @atomicStore(u32, &dst.status, record.status, .release);
    @atomicStore(u32, &dst._reserved2, record._reserved2, .release);
}
