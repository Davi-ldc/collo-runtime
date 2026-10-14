//! The live slots, one per pool slot of the worker
//! (`server/supervisor/pool.zig`). A dispatch names the pool slot its request
//! holds (`DispatchWork.worker_slot`), and the worker's VM thread writes the
//! request's live slot at that index through `WorkerWriterView`
//! (`beginLiveSlot`, `storeLiveSlotCpu` in `mapping.zig`). The host reads a
//! slot only through `HostReaderView.liveSlot` (`LiveSlotSnapshot.at` in
//! `snapshots.zig`): one copy of the slot, which it matches against the
//! identity of the request it ends.
//!
//! A slot holds the last request begun on its pool slot, with that request's
//! last CPU, until the next begin on the pool slot replaces it; nothing
//! empties it. The server dispatches another request on a pool slot only
//! after the worker's `request_done` for the one holding it, so while the
//! host reads a request's slot, before it gives the pool slot back, no later
//! begin lands there. A CPU store for a request the slot no longer holds
//! changes nothing.

const limits = @import("collo_limits");

/// Pool slots a worker has, one live slot each: the largest `concurrency` a
/// definition may set, whatever the worker's own definition sets, so every
/// worker's page has one layout.
pub const LIVE_SLOT_COUNT: usize = limits.server.worker_concurrency_max;

/// The largest `LIVE_SLOT_COUNT` the layout is proven to keep in the page's
/// first 4 KiB, which the host's launch writes anyway, together with every
/// other section before the console bytes (`mapping.zig`): a concurrency
/// maximum up to this costs no page a worker touches. A design ceiling, not
/// the most slots that would fit.
pub const live_slot_count_page_zero_max: usize = 64;

/// The last request begun on one pool slot. A zero-filled slot names no
/// request, since request ids are never 0. Every field is the worker's claim.
pub const LiveRequestSlot = extern struct {
    request_id: u64,
    request_generation: u64,
    /// The request's CPU so far (`RequestDone.cpu_ns` in
    /// `common/ipc/ingress_channel/framing.zig`), as the VM thread last
    /// stored it.
    cpu_ns: u64,
};

comptime {
    if (@sizeOf(LiveRequestSlot) != 24)
        @compileError("worker_state.page.LiveRequestSlot size mismatch");
    if (@offsetOf(LiveRequestSlot, "request_generation") != 8)
        @compileError("worker_state.page.LiveRequestSlot request_generation offset mismatch");
    if (@offsetOf(LiveRequestSlot, "cpu_ns") != 16)
        @compileError("worker_state.page.LiveRequestSlot cpu_ns offset mismatch");
    if (LIVE_SLOT_COUNT > live_slot_count_page_zero_max)
        @compileError("worker_state.page the live slots must stay within the first 4 KiB page");
}
