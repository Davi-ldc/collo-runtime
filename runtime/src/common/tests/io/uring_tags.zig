//! The io_uring user_data tag registry in `uring_tags.zig`: every reserved
//! high byte is unique, fits in eight bits and stays out of the
//! listener-accept range. The module enforces the same rules in a comptime
//! block, so a colliding tag fails the build before this test can run.

const std = @import("std");
const tags = @import("collo_io_uring_tags");

test "io_uring user_data tag registry has no collisions" {
    try std.testing.expect(tags.highByteTagsAreUnique());
    for (tags.high_byte_tags) |tag| {
        try std.testing.expect(tag <= 0xff);
        try std.testing.expect(!tags.isListenerAcceptHighByteReserved(tag));
    }
}
