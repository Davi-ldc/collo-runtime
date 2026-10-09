//! The egress core suite, driven without a transport: the fetch body's
//! reads, settlement, tees and meters (`body.zig`), the decoder libraries'
//! loading (`decompress.zig`), the worker's encoded-body decoder
//! (`encoded_body.zig`), and the stream pump with its HTTP/2 sink
//! (`stream_pump.zig`). It runs as the `egress-core` suite of
//! `egress-fast-test` and inside `egress-test`. The HTTP/1 continuation that
//! feeds real bodies is covered by `egress/tests/client/http1/` in
//! `egress-test`, and the gateway's body pump and the encoded path end to end
//! by `egress-gateway-test`.

comptime {
    _ = @import("body.zig");
    _ = @import("decompress.zig");
    _ = @import("encoded_body.zig");
    _ = @import("stream_pump.zig");
}
