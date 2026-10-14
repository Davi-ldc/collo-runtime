//! `collo_egress_core`: the response-body primitives the gateway's transport
//! and the worker's decoder share. It imports no engine binding, socket, TLS,
//! DNS or io_uring module, and no worker or gateway code, so the worker links
//! it without a network and the gateway without JavaScript.
//!
//! `response_queue.zig` owns `ResponseQueue`, the gateway's queue of one
//! fetch's body chunks between the engine's owner thread and the gateway loop,
//! and `FetchBodyIdentity`, the name both processes give a fetch body.
//! `body_credit.zig` holds the flow-control credit a queued chunk returns to
//! the engine. `stream_pump.zig` is the gateway's boundary from wire bytes
//! into a queue, and `decompress.zig` the codecs, which the worker's decoder
//! (`worker/egress/body/decoder.zig`) runs too.

pub const body_credit = @import("body_credit.zig");
pub const response_queue = @import("response_queue.zig");
pub const stream_pump = @import("stream_pump.zig");
pub const decompress = @import("decompress.zig");

pub const FetchBodyIdentity = response_queue.FetchBodyIdentity;
pub const ResponseQueue = response_queue.ResponseQueue;
pub const StreamPump = stream_pump.Pump;
