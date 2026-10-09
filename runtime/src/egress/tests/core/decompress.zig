//! The decoder libraries' loading (`egress/core/decompress.zig`): `load` gives one answer for the
//! life of the process, and the Accept-Encoding the transport sends and the decoders it can build
//! both follow that answer, so a process advertises exactly the codings it decodes. Decoding
//! itself is covered by `encoded_body.zig` and `stream_pump.zig`, and the gateway's load before
//! its sandbox by `egress-gateway-test` (`sandbox.zig`).

const std = @import("std");
const decompress = @import("support.zig").decompress;

test "load gives one answer, and Accept-Encoding and the decoders follow it" {
    const support = decompress.load();
    try std.testing.expectEqual(support, decompress.load());
    try std.testing.expectEqual(support.zlib, decompress.supportsZlib());
    try std.testing.expectEqual(support.brotli, decompress.supportsBrotli());

    const advertised: []const u8 = if (!support.zlib)
        "identity"
    else if (support.brotli)
        "gzip, deflate, br"
    else
        "gzip, deflate";
    try std.testing.expectEqualStrings(advertised, decompress.defaultAcceptEncoding());

    try expectDecoderBuilds(.gzip, support.zlib);
    try expectDecoderBuilds(.deflate, support.zlib);
    try expectDecoderBuilds(.br, support.brotli);
}

fn expectDecoderBuilds(encoding: decompress.Encoding, loaded: bool) !void {
    if (loaded) {
        var decoder = try decompress.StreamDecoder.init(encoding);
        decoder.deinit();
    } else {
        try std.testing.expectError(error.UnsupportedCompressionMethod, decompress.StreamDecoder.init(encoding));
    }
}
