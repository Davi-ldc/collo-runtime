//! Fixtures shared by the egress core suite: "hello world" compressed in each
//! wire shape, body identities and waiters, and helpers that build, collect
//! and check HTTP/2 credits.

const std = @import("std");
pub const bindings = @import("collo_bindings");
pub const body_credit = @import("collo_egress_client").core.body_credit;
pub const fetch_body = @import("collo_egress_client").core.fetch_body;
pub const decompress = @import("collo_egress_client").core.decompress;
pub const stream_pump = @import("collo_egress_client").core.stream_pump;
pub const transport = @import("collo_egress_client").transport;

/// "hello world" as one gzip member.
pub const gzip_hello_world = [_]u8{
    0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x03, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57,
    0x28, 0xcf, 0x2f, 0xca, 0x49, 0x01, 0x00, 0x85,
    0x11, 0x4a, 0x0d, 0x0b, 0x00, 0x00, 0x00,
};

/// "hello world" as a bare RFC 1951 DEFLATE stream, the deflate core of the
/// gzip vector above without a wrapper, which a long tail of non-conformant
/// origins sends under `Content-Encoding: deflate`.
pub const raw_deflate_hello_world = [_]u8{
    0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xcf,
    0x2f, 0xca, 0x49, 0x01, 0x00,
};

/// "hello world" as an RFC 1950 zlib-wrapped DEFLATE stream: the 0x78 0x9c
/// header, the raw stream and a big-endian Adler-32. This is the conformant
/// wire shape.
pub const zlib_deflate_hello_world = [_]u8{
    0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57,
    0x28, 0xcf, 0x2f, 0xca, 0x49, 0x01, 0x00, 0x1a,
    0x0b, 0x04, 0x5d,
};

/// A body identity with fixed request and fetch ids (fetch id 30), told
/// apart by `body_id`.
pub fn identity(body_id: u64) bindings.FetchBodyIdentity {
    return .{
        .request_id = 10,
        .request_generation = 20,
        .fetch_id = 30,
        .body_id = body_id,
    };
}

pub fn waiter(allocator: std.mem.Allocator) !fetch_body.Waiter {
    return .{
        .kind = .bytes,
        .content_type = try allocator.dupe(u8, ""),
        .deferred = null,
    };
}

pub fn h2Credit(source_id: u64, stream_id: u32, encoded_bytes: usize, update_stream_window: bool) body_credit.Handle {
    return body_credit.h2Data(source_id, stream_id, encoded_bytes, update_stream_window);
}

pub fn expectH2Credit(handle: body_credit.Handle, source_id: u64, stream_id: u32, encoded_bytes: usize, update_stream_window: bool) !void {
    switch (handle) {
        .h2_data => |credit| {
            try std.testing.expectEqual(source_id, credit.source_id);
            try std.testing.expectEqual(stream_id, credit.stream_id);
            try std.testing.expectEqual(encoded_bytes, credit.encoded_bytes);
            try std.testing.expectEqual(update_stream_window, credit.update_stream_window);
        },
        .none, .h1_resume => return error.ExpectedH2Credit,
    }
}

pub const ReleasedCredits = struct {
    items: [8]body_credit.Handle = undefined,
    len: usize = 0,

    pub fn slice(self: *const ReleasedCredits) []const body_credit.Handle {
        return self.items[0..self.len];
    }
};

/// Releases every queued chunk of `body` and returns the credits that came
/// out, at most the capacity of `ReleasedCredits`.
pub fn collectReleasedCredits(body: *fetch_body.Body) ReleasedCredits {
    var released = ReleasedCredits{};
    body.releaseQueuedChunksCallback(std.testing.allocator, &released, collectReleasedCreditForTest);
    return released;
}

pub fn collectReleasedCreditForTest(released: *ReleasedCredits, credit: body_credit.Handle) void {
    std.debug.assert(released.len < released.items.len);
    released.items[released.len] = credit;
    released.len += 1;
}
