//! The codings `egress/core/decompress.zig` serves: the Accept-Encoding the transport sends names
//! exactly the codings it builds a decoder for. Decoding itself is covered by `encoded_body.zig`
//! and `stream_pump.zig`.

const std = @import("std");
const decompress = @import("support.zig").decompress;

test "the transport advertises gzip, deflate and br, and builds a decoder for each" {
    try std.testing.expectEqualStrings("gzip, deflate, br", decompress.default_accept_encoding);

    const advertised = [_]decompress.Encoding{ .gzip, .deflate, .br };
    for (advertised) |encoding| {
        var decoder = try decompress.StreamDecoder.init(encoding);
        decoder.deinit();
    }
}
