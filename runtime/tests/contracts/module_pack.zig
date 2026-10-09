//! Pins the bytes of a CLOM module pack as `module_pack.buildAlloc`
//! (`runtime/src/common/ipc/module_pack.zig`) writes it, for the worker's
//! loader and the engine bridge's `module_loader.cpp` to parse. Any change to
//! the header, the records, the index or the segment order changes the digest,
//! so a layout change cannot land unnoticed: it updates this vector in the same
//! change as the builder and both parsers. Runs in `meta-test`; parse and
//! validation behavior is covered in `runtime/src/common/tests/ipc.zig`.

const std = @import("std");
const module_pack = @import("collo_ipc").module_pack;

const Sha256 = std.crypto.hash.sha2.Sha256;

test "a single-module pack keeps its pinned bytes" {
    comptime std.debug.assert(module_pack.version == 2);
    const pack = try module_pack.buildAlloc(std.testing.allocator, &.{.{
        .specifier = "/__collo_route/golden/api/hi.js",
        .source = "export default () => new Response(\"hi\");\n",
    }}, 0);
    defer std.testing.allocator.free(pack);

    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(pack, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(
        "715603e674a06415fb99d53a8f7a2dea6007e5518b2ddb139a33d5ec6785c93a",
        &digest_hex,
    );
}
