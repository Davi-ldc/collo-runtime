//! Module root of `collo_worker_request`: a worker's state for each request
//! and its reading of what the host sends for one. Its code runs in the
//! worker on the VM thread.
//!
//! Under `request/`, `context.zig` holds the per-request state and `task.zig`
//! the table of requests whose handler is running or settling. `head.zig`
//! checks a dispatched head, `incoming_body/pipe.zig` buffers the body, and
//! `body_read.zig` serves the lazy body reads of the handler's `Request`.
//! `completion.zig` queues a handler's settled result, and
//! `response_model.zig` defines the response the serve side writes, with its
//! bounds and checks. In `ingress/`, `runtime.zig` turns the host's
//! ingress-channel packets into live requests and `response_outbox.zig`
//! keeps response bytes that wait for room in the payload region; `http2/`
//! validates and plans the channel's descriptors.
//!
//! The `worker` module imports this one, so nothing reachable from here may
//! import a worker file by path: Zig refuses a file that two modules reach.
//! That is why the serve side (dispatch, response writing, finish) lives in
//! `worker/serve/`, and why the functions here that act on the runtime take
//! it as `anytype`.

pub const body_read = @import("request/body_read.zig");
pub const completion = @import("request/completion.zig");
pub const context = @import("request/context.zig");
pub const head = @import("request/head.zig");
pub const incoming_body_pipe = @import("request/incoming_body/pipe.zig");
pub const response_model = @import("request/response_model.zig");
pub const task = @import("request/task.zig");

pub const http2 = struct {
    pub const ingress = @import("request/http2/ingress.zig");
    pub const response = @import("request/http2/response.zig");
};

pub const ingress = struct {
    pub const response_outbox = @import("request/ingress/response_outbox.zig");
    pub const runtime = @import("request/ingress/runtime.zig");
};
