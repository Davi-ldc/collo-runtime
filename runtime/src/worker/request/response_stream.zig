//! The source a request's streamed response pulls from, held in
//! `RequestContext.response_stream` from the moment the response streams
//! until it ends: a fetch body the gateway delivers, or a ReadableStream the
//! handler's Response carried, which the bridge locked at extraction
//! (`collo_response_body_stream_*` in `abi.h`). It also holds the state of
//! the request's one `response_advance` work item, which every response
//! resumes through (`serve/response.zig:executeAdvance`), and the queueing a
//! request-module file may do. It belongs to the worker's VM thread.
//!
//! A body stream is read one chunk at a time, and the next read starts only
//! once every byte of the chunk before it went out. The chunk stays rooted
//! here until then, and its bytes are borrowed again on each try, since a
//! call into the VM may move or detach them.

const bindings = @import("collo_bindings");

/// What a stopped response waits for. A grant ends a `credit` wait
/// (`ingress/runtime.zig:enqueueResponseCredit`), and room in the payload
/// ring or the control socket ends the other two
/// (`serve/response.zig:notifyTransport`).
pub const Wait = enum { none, credit, ring, socket };

/// The request's `response_advance` work item. `unqueued` marks an item
/// that found both scheduler queues full, which the ingress rescan queues
/// (`ingress/runtime.zig:collectReadyRequests`); `ready_since_ns` keeps its
/// first readiness stamp until it runs.
pub const Advance = struct {
    state: enum { idle, unqueued, queued } = .idle,
    ready_since_ns: u64 = 0,
    wait: Wait = .none,
};

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
    /// The last read's result; a chunk stays here until all of it went out.
    result: Result = .none,
    /// A read is in flight and its result has not been reported.
    reading: bool = false,
    /// The previous chunk was sent, so the next advance starts a read.
    read_next: bool = false,
    /// The bytes of the chunk in `result` already sent.
    offset: usize = 0,
    /// The chunk's length when it was first borrowed, which every later
    /// borrow must find again.
    chunk_len: ?usize = null,
    /// The stream has reported neither done nor an error, so an early end of
    /// the response may cancel it.
    open: bool = true,

    pub fn deinit(self: *BodyStream) void {
        self.result.deinit();
        self.stream.deinit();
        self.* = undefined;
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
};

/// Queues the request's `response_advance` item unless it is queued already
/// or the request is finishing or reset, except a finished request whose
/// last packet still waits (`RequestContext.last_packet_done`), which only
/// its advance sends. Returns false when both scheduler queues are full; the
/// item then stays `unqueued` with its first stamp. Call it only for an
/// event that lets the response move: one waiting for credit has nothing to
/// run until a grant arrives.
pub fn queueAdvance(runtime: anytype, request_ctx: anytype) bool {
    if (request_ctx.last_packet_done == null and (request_ctx.finish_started or request_ctx.client_reset))
        return true;
    const advance = &request_ctx.response_advance;
    if (advance.state == .queued)
        return true;
    advance.state = .unqueued;
    if (advance.ready_since_ns == 0)
        advance.ready_since_ns = runtime.nowMonoNs();
    if (!runtime.tryQueueReadyWorkReadySince(.{ .response_advance = request_ctx.exec.request_id }, advance.ready_since_ns))
        return false;
    advance.state = .queued;
    return true;
}

/// Withdraws the request's queued advance and clears its wait, for a
/// response that is dropped.
pub fn discardAdvance(runtime: anytype, request_ctx: anytype) void {
    if (request_ctx.response_advance.state == .queued)
        runtime.withdrawReadyWork(.{ .response_advance = request_ctx.exec.request_id });
    request_ctx.response_advance = .{};
}
