//! The egress core suite, driven without a transport: the gateway's response
//! queue (`response_queue.zig`), the codings the transport advertises and
//! decodes (`decompress.zig`), and the stream pump with its HTTP/2 sink
//! (`stream_pump.zig`). It runs as the `egress-core` suite of
//! `egress-fast-test` and inside `egress-test`. The HTTP/1 continuation that
//! feeds real bodies is covered by `egress/tests/client/http1/` in
//! `egress-test`, the gateway's body pump and the encoded path end to end by
//! `egress-gateway-test`, and the worker's fetch body and decoder by
//! `worker/tests/egress/` in `worker-test`.

comptime {
    _ = @import("response_queue.zig");
    _ = @import("decompress.zig");
    _ = @import("stream_pump.zig");
}
