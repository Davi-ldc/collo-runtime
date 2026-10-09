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

    /// Claims an empty live slot for the request `identity` names, started
    /// at `started_mono_ns`. Fails with `error.InvalidRequestId` for a zero
    /// request id and with `error.NoFreeLiveSlot` when every slot holds a
    /// request in flight.
    pub fn allocateLiveSlot(
        self: *WorkState,
        identity: page.LifecycleIdentity,
        started_mono_ns: u64,
    ) !LiveSlotHandle {
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
            @atomicStore(u64, &slot.billing_sequence, identity.billing_sequence, .release);
            @atomicStore(u64, &slot.started_mono_ns, started_mono_ns, .release);
            @atomicStore(u64, &slot.cpu_time_ns, 0, .release);
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
        @atomicStore(u64, &slot.billing_sequence, 0, .release);
        @atomicStore(u64, &slot.started_mono_ns, 0, .release);
        @atomicStore(u64, &slot.cpu_time_ns, 0, .release);
        @atomicStore(u32, &slot.request_slot, 0, .release);
        @atomicStore(u16, &slot.request_lane_id, 0, .release);
        @atomicStore(u16, &slot._reserved1, 0, .release);
        @atomicStore(u32, &slot.state, @intFromEnum(page.LiveSlotState.empty), .release);
    }

    /// Publishes the CPU time the request has used so far, which a death
    /// record reports if the worker dies before it finishes. Fails like
    /// `freeLiveSlot`.
    pub fn updateLiveSlotCpu(self: *WorkState, handle: LiveSlotHandle, cpu_time_ns: u64) !void {
        const slot = try self.claimedSlot(handle);
        @atomicStore(u64, &slot.cpu_time_ns, cpu_time_ns, .release);
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

/// Host side. The usage record of a request whose worker died, built from
/// what its live slot measured until then, as `snapshot` copied it. The
/// caller matched the snapshot against the request's identity first
/// (`LiveSlotSnapshot.find`), so the identity copied here is the one the
/// host dispatched, and the caller stamps `flags` from its own state. A live
/// slot holds no byte meters, so they stay zero, and so does
/// `billing_sequence`, which the snapshot does not copy.
pub fn synthesizeDeathRecord(
    snapshot: page.LiveSlotSnapshot,
    death_mono_ns: u64,
    status: page.CompletedStatus,
) page.CompletedRecord {
    return .{
        .request_id = snapshot.request_id,
        .request_generation = snapshot.request_generation,
        .worker_id = snapshot.worker_id,
        .worker_generation = snapshot.worker_generation,
        .started_mono_ns = snapshot.started_mono_ns,
        .finished_mono_ns = death_mono_ns,
        .cpu_time_ns = snapshot.cpu_time_ns,
        .io_time_ns = 0,
        .client_served_bytes = 0,
        .fetch_billed_sent_bytes = 0,
        .fetch_billed_received_bytes = 0,
        .fetch_cost_bytes = 0,
        .request_slot = snapshot.request_slot,
        .request_lane_id = snapshot.request_lane_id,
        .status = @intFromEnum(status),
        .flags = 0,
    };
}

fn storeCompletedRecord(dst: *page.CompletedRecord, record: page.CompletedRecord) void {
    @atomicStore(u64, &dst.request_id, record.request_id, .release);
    @atomicStore(u64, &dst.request_generation, record.request_generation, .release);
    @atomicStore(u64, &dst.worker_id, record.worker_id, .release);
    @atomicStore(u64, &dst.worker_generation, record.worker_generation, .release);
    @atomicStore(u64, &dst.started_mono_ns, record.started_mono_ns, .release);
    @atomicStore(u64, &dst.finished_mono_ns, record.finished_mono_ns, .release);
    @atomicStore(u64, &dst.cpu_time_ns, record.cpu_time_ns, .release);
    @atomicStore(u64, &dst.io_time_ns, record.io_time_ns, .release);
    @atomicStore(u64, &dst.waiting_ns, record.waiting_ns, .release);
    @atomicStore(u64, &dst.queued_ns, record.queued_ns, .release);
    @atomicStore(u64, &dst.max_turn_ns, record.max_turn_ns, .release);
    @atomicStore(u64, &dst.turn_cpu_ns, record.turn_cpu_ns, .release);
    @atomicStore(u64, &dst.client_served_bytes, record.client_served_bytes, .release);
    @atomicStore(u64, &dst.fetch_billed_sent_bytes, record.fetch_billed_sent_bytes, .release);
    @atomicStore(u64, &dst.fetch_billed_received_bytes, record.fetch_billed_received_bytes, .release);
    @atomicStore(u64, &dst.fetch_cost_bytes, record.fetch_cost_bytes, .release);
    @atomicStore(u64, &dst.billing_sequence, record.billing_sequence, .release);
    @atomicStore(u32, &dst.request_slot, record.request_slot, .release);
    @atomicStore(u16, &dst.request_lane_id, record.request_lane_id, .release);
    @atomicStore(u16, &dst._reserved1, record._reserved1, .release);
    @atomicStore(u32, &dst.status, record.status, .release);
    @atomicStore(u32, &dst.flags, record.flags, .release);
}
