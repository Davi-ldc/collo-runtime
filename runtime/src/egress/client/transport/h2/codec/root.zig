//! HTTP/2 client codec for outbound fetch: request encoding (`request.zig`),
//! response validation (`response.zig`), connection-wide session state
//! (`session.zig`) and the multiplexed connection with its flow control
//! (`client.zig`). The codec performs no I/O: callers hand it the frames they
//! read and the writer that receives the frames it sends.

pub const request = @import("request.zig");
pub const response = @import("response.zig");
pub const session = @import("session.zig");
pub const client = @import("client.zig");

pub const RequestHead = request.RequestHead;
pub const EncodedRequest = request.EncodedRequest;
pub const encodeRequest = request.encodeRequest;
pub const validateRequestHead = request.validateRequestHead;

pub const ResponseAccumulator = response.ResponseAccumulator;
pub const ResponseHead = response.ResponseHead;
pub const parseResponseHead = response.parseResponseHead;

pub const Session = session.Session;
pub const ClientSettings = session.ClientSettings;
pub const Connection = client.Connection;
pub const Event = client.Event;
pub const FrameReader = client.FrameReader;
pub const FrameReadStep = client.FrameReadStep;
pub const Limits = client.Limits;
pub const default_limits = client.default_limits;
pub const max_frames_without_event_per_read = client.max_frames_without_event_per_read;
