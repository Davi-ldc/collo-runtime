//! The worker's side of fetch response bodies: the `Body` views a worker's
//! JavaScript reads, fed from gateway packets and settled back into
//! JavaScript promises. Everything here runs on the worker's VM thread. The
//! gateway reaches this code only as body-pool extents; decoding its packets
//! belongs to `gateway_runtime.zig`, and the gateway's own queue of a fetch's
//! chunks is `egress/core/response_queue.zig`.
//!
//! `body.zig` holds the body type with its chunks (`chunk.zig`) and its
//! decoder (`decoder.zig`); `register.zig` creates bodies, `ingest.zig` feeds
//! them gateway extents, `consume.zig` registers JavaScript readers and
//! clones, `ready.zig` settles readers from the ready queue, `cleanup.zig`
//! cancels and releases, and `common.zig` holds the lookups and queueing they
//! share.
//!
//! `State.bodies` holds one reference on each body it lists, keyed by body
//! id. A fetch's task holds another on its response body until the task goes
//! (`task.zig`), and a tee link one on each side until it is detached
//! (`body.zig`); a reader stored on a body takes none, and the settlement
//! that runs a reader's JavaScript holds one of its own for its run
//! (`ready.zig`). A body leaves the table with its decoder, its queued chunks
//! and its tee links (`cleanup.zig:removeFromTable`), and only a body in the
//! table takes chunks, readers or ready items. Releasing a body-pool extent
//! only queues it; whoever drives the pass then calls
//! `gateway_control.flushBodyPoolReleases`, so the gateway gets one wake per
//! pass and never misses one. Every change that can ready a reader is
//! followed by `common.queueReadyViews` or `queueIfReady`, which queue each
//! ready view's one item (`register.zig` bounds the items).

const common = @import("common.zig");
const register = @import("register.zig");
const consume = @import("consume.zig");
const cleanup = @import("cleanup.zig");
const ready = @import("ready.zig");
const ingest = @import("ingest.zig");
const body_mod = @import("body.zig");
const decoder_mod = @import("decoder.zig");

pub const Body = body_mod.Body;
pub const State = body_mod.State;
pub const Identity = body_mod.Identity;
pub const ReadKind = body_mod.ReadKind;
pub const Waiter = body_mod.Waiter;
pub const PullWaiter = body_mod.PullWaiter;
pub const BorrowedChunk = body_mod.BorrowedChunk;
pub const BorrowedRelease = body_mod.BorrowedRelease;
pub const ByteLease = body_mod.ByteLease;
pub const Decoder = body_mod.Decoder;
pub const limitsFromHeadFields = decoder_mod.limitsFromHeadFields;
pub const ResponseStreamDrain = consume.ResponseStreamDrain;

pub const registerOpen = register.registerOpen;

pub const scheduleConsume = consume.scheduleConsume;
pub const schedulePull = consume.schedulePull;
pub const beginResponseStreamPull = consume.beginResponseStreamPull;
pub const drainResponseStreamReady = consume.drainResponseStreamReady;
pub const borrow = consume.borrow;
pub const clone = consume.clone;

pub const cancel = cleanup.cancel;
pub const cancelForFetch = cleanup.cancelForFetch;
pub const handleReadyFailure = cleanup.handleReadyFailure;
pub const release = cleanup.release;
pub const releaseInternal = cleanup.releaseInternal;
pub const releaseAllForShutdown = cleanup.releaseAllForShutdown;
pub const cleanupForRequest = cleanup.cleanupForRequest;

pub const executeReady = ready.executeReady;

pub const appendGatewayBodyPoolChunk = ingest.appendGatewayBodyPoolChunk;
pub const pushGatewayBodyPoolChunkToDecoder = ingest.pushGatewayBodyPoolChunkToDecoder;

pub const ptr = common.ptr;
pub const queueReadyViews = common.queueReadyViews;
pub const queueIfReady = common.queueIfReady;
