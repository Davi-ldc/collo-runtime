//! The worker's side of fetch response bodies: the `fetch_body.Body` views a
//! worker's JavaScript reads, fed from gateway packets and settled back into
//! JS promises. Everything here runs on the worker's event loop thread, which
//! is also the VM thread. The gateway reaches this code only as body-pool
//! extents and credit handles; decoding its packets belongs to
//! `gateway_runtime.zig`.
//!
//! `register.zig` creates bodies and ends them, `ingest.zig` feeds them
//! gateway body-pool extents, `consume.zig` registers JS readers and clones,
//! `ready.zig` settles readers from the ready queue, `cleanup.zig` cancels and
//! releases, and `common.zig` holds the lookups they share.
//!
//! `State.bodies` holds one reference on each body, keyed by body id. Before
//! that reference goes, every queued chunk is released and every tee link
//! detached, as `fetch_body.zig` asserts, and the body's decoder in
//! `State.body_decoders` is removed in the same step. Releasing a body-pool
//! extent only queues it; whoever drives the pass then calls
//! `gateway_control.flushBodyPoolReleases`, so the gateway gets one wake per
//! pass and never misses one. A caller whose `claimReadyForQueue` succeeds
//! must queue the body or call `clearReadyQueued`, or the body is never
//! settled.

const common = @import("common.zig");
const register = @import("register.zig");
const consume = @import("consume.zig");
const cleanup = @import("cleanup.zig");
const ready = @import("ready.zig");
const ingest = @import("ingest.zig");

pub const ResponseStreamDrain = common.ResponseStreamDrain;

pub const registerComplete = register.registerComplete;
pub const registerOpen = register.registerOpen;
pub const appendBytes = register.appendBytes;
pub const complete = register.complete;
pub const fail = register.fail;

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
pub const collectReady = ready.collectReady;

pub const appendGatewayBodyPoolChunk = ingest.appendGatewayBodyPoolChunk;
pub const pushGatewayBodyPoolChunkToDecoder = ingest.pushGatewayBodyPoolChunkToDecoder;

pub const ptr = common.ptr;
pub const accountEgress = common.accountEgress;
