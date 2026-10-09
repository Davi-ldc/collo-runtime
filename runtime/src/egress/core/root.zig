//! `collo_egress_core`: the fetch body and the credit, decoding and streaming
//! primitives that the gateway and the worker share. In the gateway, the
//! transport engine's owner thread feeds bodies and the gateway loop drains
//! them; in the worker, the event loop feeds bodies from gateway packets and
//! reads them.
//!
//! The worker has no network and links this module, so nothing here may
//! import socket, TLS, DNS or io_uring transport modules. Nothing here may
//! import worker request lifecycle code either: the gateway links this module
//! too, and settling a body's promises belongs to `runtime/src/worker/egress/`.
//!
//! `fetch_body.zig` owns `Body`, the decoded byte queue a `Response` reads,
//! with its fields, invariants and meters; its methods live in
//! `body_append.zig` (producers and tee fan-out), `body_settlement.zig`
//! (readers and drains), `body_state.zig` (complete, fail, cancel) and
//! `body_tee.zig` (links between a body and its clones). `body_chunks.zig`
//! holds the queued chunks and the byte leases drains hand out,
//! `body_credit.zig` the flow-control credit a chunk carries, and
//! `body_credits.zig` the latch that shares one credit among tee views.
//! `stream_pump.zig` is the gateway's boundary from wire bytes into a body,
//! `encoded_body.zig` the worker's decoder for bodies the gateway forwards
//! still encoded, and `decompress.zig` the codecs. `accounting.zig` is a
//! separate libc-free module, `collo_egress_accounting`, for the transport's
//! byte counters.

pub const body_credit = @import("body_credit.zig");
pub const encoded_body = @import("encoded_body.zig");
pub const fetch_body = @import("fetch_body.zig");
pub const stream_pump = @import("stream_pump.zig");
pub const decompress = @import("decompress.zig");

pub const FetchBody = fetch_body.Body;
pub const FetchBodyReadKind = fetch_body.ReadKind;
pub const FetchBodyWaiter = fetch_body.Waiter;
pub const FetchBodyPullWaiter = fetch_body.PullWaiter;
pub const ByteLease = fetch_body.ByteLease;
pub const PullCredits = fetch_body.PullCredits;
pub const StreamPump = stream_pump.Pump;
