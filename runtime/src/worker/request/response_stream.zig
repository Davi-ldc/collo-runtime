//! The body source a request's streamed response pulls from, held in
//! `RequestContext.response_stream` from the moment the response streams
//! until it ends: a fetch body the gateway delivers, or a ReadableStream the
//! handler's Response carried, which the bridge locked at extraction
//! (`collo_response_body_stream_*` in `abi.h`). `serve/response.zig` drives
//! the first and `serve/response_body_stream.zig` the second; this file holds
//! their state and the queueing a request-module file may do. It belongs to
//! the worker's VM thread.
//!
//! A body stream is read one chunk at a time. A read's result arrives from the
//! bridge during a microtask drain, parks here and queues the request's
//! `response_body_stream` work item, which takes it in the request's own
//! window; the next read starts only once the chunk before it went out whole,
//! so the stream advances at the pace the payload ring and the client allow.

const bindings = @import("collo_bindings");

pub const Source = union(enum) {
    none,
    fetch: Fetch,
    body_stream: BodyStream,

    /// Releases what a body stream holds without running JavaScript; a fetch
    /// body goes back to the runtime, which owns it, through its own path.
    pub fn deinit(self: *Source) void {
        switch (self.*) {
            .none, .fetch => {},
            .body_stream => |*body_stream| body_stream.deinit(),
        }
        self.* = .none;
    }

    /// Whether the response still needs the tenant's JavaScript to reach its
    /// end: a body stream that has not reported done or an error. A fetch
    /// body and a stream whose end is known finish without it.
    pub fn needsJavaScript(self: *const Source) bool {
        return switch (self.*) {
            .none, .fetch => false,
            .body_stream => |body_stream| body_stream.open,
        };
    }
};

pub const Fetch = struct {
    identity: bindings.FetchBodyIdentity,
    /// A pull is in flight; `executeFetchBodyStreamReady` moves its bytes.
    pull_pending: bool = false,
};

pub const BodyStream = struct {
    /// The locked stream, owned.
    stream: bindings.ResponseBodyStream,
    /// A read's result the bridge reported that the work item has not taken.
    result: Result = .none,
    /// A read is in flight and its result has not been reported.
    reading: bool = false,
    /// The last chunk went out from the loop's flush, so the work item starts
    /// the next read.
    read_next: bool = false,
    /// The request's `response_body_stream` work item is in the ready queue.
    advance_queued: bool = false,
    /// The stream has reported neither done nor an error, so an early end of
    /// the response may cancel it.
    open: bool = true,

    pub fn deinit(self: *BodyStream) void {
        self.result.deinit();
        self.stream.deinit();
        self.* = undefined;
    }

    /// Whether the work item has something to do: a result to take, or the
    /// next read once nothing is in flight.
    pub fn wantsAdvance(self: *const BodyStream) bool {
        if (self.advance_queued)
            return false;
        if (self.result != .none)
            return true;
        if (self.read_next)
            return !self.reading;
        return false;
    }
};

/// One read's outcome, as `collo_runtime_response_body_stream_settled`
/// reports it. `chunk` holds the read's value and `failed` the rejection
/// reason, null when the bridge could not hand it over.
pub const Result = union(enum) {
    none,
    chunk: bindings.Value,
    done,
    failed: ?bindings.Value,

    pub fn deinit(self: *Result) void {
        switch (self.*) {
            .none, .done => {},
            .chunk => |*value| value.deinit(),
            .failed => |*reason| if (reason.*) |*value| value.deinit(),
        }
        self.* = .none;
    }

    /// Moves the result out and leaves `.none`; the caller owns what it took.
    pub fn take(self: *Result) Result {
        const taken = self.*;
        self.* = .none;
        return taken;
    }
};

/// Queues the `response_body_stream` work item of request `request_id`
/// unless one is queued already or `source` is not a body stream. Returns
/// false when the ready queue and its backlog are both full; the ingress
/// rescan (`ingress/runtime.zig:collectReadyRequests`) then queues it from
/// `wantsAdvance`.
pub fn queueAdvance(runtime: anytype, request_id: u64, source: *Source) bool {
    const body_stream = switch (source.*) {
        .body_stream => |*held| held,
        .none, .fetch => return true,
    };
    if (body_stream.advance_queued)
        return true;
    if (!runtime.tryQueueReadyWork(.{ .response_body_stream = request_id }))
        return false;
    body_stream.advance_queued = true;
    return true;
}

/// Whether `source` is a body stream whose work item has something to do and
/// is not queued (`BodyStream.wantsAdvance`).
pub fn wantsAdvance(source: *const Source) bool {
    return switch (source.*) {
        .body_stream => |body_stream| body_stream.wantsAdvance(),
        .none, .fetch => false,
    };
}
