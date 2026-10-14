//! Pins the bytes of a definition artifact as `module_pack.buildAlloc`
//! (`runtime/src/common/ipc/module_pack.zig`) writes it, for the worker's
//! parse and the engine bridge's `module_loader.cpp` to read. Any change to
//! the header, the records, the index, the routes section, the section order
//! or how a source is stored changes the digest, so a layout change cannot
//! land unnoticed: it updates this vector in the same change as the builder,
//! the parser and the loader's copy of the layout. Runs in `meta-test`; parse
//! and validation behavior is covered in
//! `runtime/src/common/tests/ipc/module_pack.zig`.

const std = @import("std");
const module_pack = @import("collo_ipc").module_pack;

const Sha256 = std.crypto.hash.sha2.Sha256;

test "a one-module, one-route artifact keeps its pinned bytes" {
    comptime std.debug.assert(module_pack.version == 3);
    const pack = try module_pack.buildSingleRouteAlloc(
        std.testing.allocator,
        "/var/task/api/hi.js",
        "export default () => new Response(\"hi\");\n",
    );
    defer std.testing.allocator.free(pack);

    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(pack, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(
        "02d327742a6fb7cb51b1876a065de1741109592608fef74755620c01abc7ea2b",
        &digest_hex,
    );
}
