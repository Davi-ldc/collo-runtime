//! The egress token (`common/ipc/egress_token.zig`): its pinned layout, the mint and verify
//! round trip for both kinds, the tag checked against HMAC-SHA256 computed here, every single-byte
//! change to the body and to the tag, other and zero keys, the version and kind checks that only
//! run behind a matching tag, expiry at the deadline, and the byte round trip at any alignment.
//! The gateway's admission, which binds a token to its session and keeps its budget, is covered by
//! the egress-gateway lane.

const std = @import("std");
const ipc = @import("collo_ipc");

const egress_token = ipc.egress_token;
const Key = egress_token.Key;
const Kind = egress_token.Kind;
const Token = egress_token.Token;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

const key_a = keyFrom(0x11);
const key_b = keyFrom(0xc4);
const zero_key: Key = .{ .bytes = @splat(0) };

const request_fields: egress_token.Fields = .{
    .kind = .request,
    .policy_id = 3,
    .budget = 16,
    .session_id = 0x0102_0304_0506_0708,
    .request_id = 0x1112_1314_1516_1718,
    .request_generation = 0x2122_2324_2526_2728,
    .deadline_monotonic_ns = 5_000_000_000,
};

const boot_fields: egress_token.Fields = .{
    .kind = .boot,
    .policy_id = 0,
    .budget = 16,
    .session_id = 0x0102_0304_0506_0708,
    .request_id = 0,
    .request_generation = 0,
    .deadline_monotonic_ns = 7_000_000_000,
};

/// A fixed key whose bytes all differ, so a key that is read shifted or truncated would differ.
fn keyFrom(seed: u8) Key {
    var key: Key = undefined;
    for (&key.bytes, 0..) |*byte, index|
        byte.* = seed +% @as(u8, @intCast(index * 7));
    return key;
}

/// The tag as the file header defines it, computed here with the standard library alone.
fn referenceTag(
    key: *const Key,
    body: *const [egress_token.body_bytes]u8,
) [egress_token.tag_bytes]u8 {
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, body, &key.bytes);
    return mac[0..egress_token.tag_bytes].*;
}

/// `bytes` with the tag recomputed over its body, so the token passes the tag check whatever its
/// version and kind bytes say.
fn retagged(key: *const Key, bytes: egress_token.Bytes) Token {
    var copy = bytes;
    copy[egress_token.body_bytes..].* = referenceTag(key, copy[0..egress_token.body_bytes]);
    return egress_token.fromBytes(&copy);
}

test "the token keeps its pinned size and field offsets" {
    try std.testing.expectEqual(@as(usize, 56), egress_token.token_bytes);
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(Token));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(egress_token.Bytes));
    try std.testing.expectEqual(@as(usize, 40), egress_token.body_bytes);
    try std.testing.expectEqual(@as(usize, 16), egress_token.tag_bytes);
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Key));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Token, "version"));
    try std.testing.expectEqual(@as(usize, 1), @offsetOf(Token, "kind"));
    try std.testing.expectEqual(@as(usize, 2), @offsetOf(Token, "policy_id"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(Token, "budget"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Token, "session_id"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Token, "request_id"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(Token, "request_generation"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(Token, "deadline_monotonic_ns"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(Token, "tag"));
}

test "a minted request token verifies to the fields it was minted with" {
    const token = egress_token.mint(&key_a, request_fields);
    try std.testing.expectEqual(egress_token.version, token.version);
    try std.testing.expectEqual(egress_token.kind_request, token.kind);
    try std.testing.expectEqual(request_fields, try egress_token.verify(&key_a, &token));
}

test "a boot token verifies to its fields and its kind tells it from a request token" {
    const boot = egress_token.mint(&key_a, boot_fields);
    const request = egress_token.mint(&key_a, request_fields);
    const boot_verified = try egress_token.verify(&key_a, &boot);
    const request_verified = try egress_token.verify(&key_a, &request);
    try std.testing.expectEqual(boot_fields, boot_verified);
    try std.testing.expectEqual(Kind.boot, boot_verified.kind);
    try std.testing.expectEqual(Kind.request, request_verified.kind);
    try std.testing.expectEqual(egress_token.kind_boot, boot.kind);
    try std.testing.expect(boot.kind != request.kind);
}

test "the tag is the first 16 bytes of HMAC-SHA256 over the 40-byte body" {
    const token = egress_token.mint(&key_a, request_fields);
    const bytes = egress_token.asBytes(&token);
    const expected = referenceTag(&key_a, bytes[0..egress_token.body_bytes]);
    try std.testing.expectEqualSlices(u8, &expected, &token.tag);
    try std.testing.expectEqualSlices(u8, &expected, bytes[egress_token.body_bytes..]);
}

test "every single-byte change to the body fails with BadTag" {
    const token = egress_token.mint(&key_a, request_fields);
    const original = egress_token.asBytes(&token).*;
    // Each delta from 1 to 255 at each body offset is every value the byte can take other than
    // its own; the version and kind bytes are among them and still fail on the tag.
    for (0..egress_token.body_bytes) |offset| {
        for (1..256) |delta| {
            var tampered = original;
            tampered[offset] ^= @intCast(delta);
            const candidate = egress_token.fromBytes(&tampered);
            try std.testing.expectError(error.BadTag, egress_token.verify(&key_a, &candidate));
        }
    }
}

test "every single-byte change to the tag fails with BadTag" {
    const token = egress_token.mint(&key_a, request_fields);
    const original = egress_token.asBytes(&token).*;
    for (egress_token.body_bytes..egress_token.token_bytes) |offset| {
        for (1..256) |delta| {
            var tampered = original;
            tampered[offset] ^= @intCast(delta);
            const candidate = egress_token.fromBytes(&tampered);
            try std.testing.expectError(error.BadTag, egress_token.verify(&key_a, &candidate));
        }
    }
}

test "a token verified under another key fails with BadTag" {
    const token = egress_token.mint(&key_a, request_fields);
    try std.testing.expectError(error.BadTag, egress_token.verify(&key_b, &token));
    const boot = egress_token.mint(&key_b, boot_fields);
    try std.testing.expectError(error.BadTag, egress_token.verify(&key_a, &boot));
}

test "two keys give two tags for the same fields and one key always gives the same tag" {
    const under_a = egress_token.mint(&key_a, request_fields);
    const under_a_again = egress_token.mint(&key_a, request_fields);
    const under_b = egress_token.mint(&key_b, request_fields);
    try std.testing.expectEqualSlices(u8, &under_a.tag, &under_a_again.tag);
    try std.testing.expect(!std.mem.eql(u8, &under_a.tag, &under_b.tag));
    try std.testing.expectEqualSlices(
        u8,
        egress_token.asBytes(&under_a)[0..egress_token.body_bytes],
        egress_token.asBytes(&under_b)[0..egress_token.body_bytes],
    );
}

test "the zero key verifies nothing, not even a token tagged under it" {
    try std.testing.expect(zero_key.isZero());
    try std.testing.expect(!key_a.isZero());
    // One nonzero byte anywhere is enough for a key to count.
    var last_byte_set = zero_key;
    last_byte_set.bytes[egress_token.key_bytes - 1] = 1;
    try std.testing.expect(!last_byte_set.isZero());

    const minted = egress_token.mint(&key_a, request_fields);
    const under_zero = retagged(&zero_key, egress_token.asBytes(&minted).*);
    try std.testing.expectError(error.BadTag, egress_token.verify(&zero_key, &under_zero));
    try std.testing.expectError(error.BadTag, egress_token.verify(&zero_key, &minted));
}

test "a tagged token with another version fails with BadVersion, and an untagged one with BadTag" {
    const minted = egress_token.mint(&key_a, request_fields);
    for ([_]u8{ 0, egress_token.version + 1, 0xff }) |other_version| {
        var bytes = egress_token.asBytes(&minted).*;
        bytes[@offsetOf(Token, "version")] = other_version;
        const tagged = retagged(&key_a, bytes);
        try std.testing.expectError(error.BadVersion, egress_token.verify(&key_a, &tagged));
        const untagged = egress_token.fromBytes(&bytes);
        try std.testing.expectError(error.BadTag, egress_token.verify(&key_a, &untagged));
    }
}

test "a tagged token with an unknown kind fails with BadKind" {
    const minted = egress_token.mint(&key_a, request_fields);
    for ([_]u8{ 0, egress_token.kind_boot + 1, 0xff }) |other_kind| {
        var bytes = egress_token.asBytes(&minted).*;
        bytes[@offsetOf(Token, "kind")] = other_kind;
        const tagged = retagged(&key_a, bytes);
        try std.testing.expectError(error.BadKind, egress_token.verify(&key_a, &tagged));
        try std.testing.expectError(error.BadKind, egress_token.decodeKind(other_kind));
    }
    const request_kind = try egress_token.decodeKind(egress_token.kind_request);
    const boot_kind = try egress_token.decodeKind(egress_token.kind_boot);
    try std.testing.expectEqual(Kind.request, request_kind);
    try std.testing.expectEqual(Kind.boot, boot_kind);
    try std.testing.expectEqual(egress_token.kind_request, egress_token.encodeKind(.request));
    try std.testing.expectEqual(egress_token.kind_boot, egress_token.encodeKind(.boot));
}

test "a token is live before its deadline and expired at it and after it" {
    const token = egress_token.mint(&key_a, request_fields);
    const deadline = request_fields.deadline_monotonic_ns;
    try std.testing.expect(!egress_token.expired(&token, 0));
    try std.testing.expect(!egress_token.expired(&token, deadline - 1));
    try std.testing.expect(egress_token.expired(&token, deadline));
    try std.testing.expect(egress_token.expired(&token, deadline + 1));
    try std.testing.expect(egress_token.expired(&token, std.math.maxInt(u64)));
    try std.testing.expect(egress_token.deadlinePassed(deadline, deadline));
    try std.testing.expect(!egress_token.deadlinePassed(deadline, deadline - 1));
}

test "fromBytes reads a token at any alignment and asBytes gives back the same bytes" {
    const minted = egress_token.mint(&key_a, request_fields);
    const wire = egress_token.asBytes(&minted).*;
    var buffer: [egress_token.token_bytes + 8]u8 align(8) = undefined;
    for (0..8) |offset| {
        @memset(&buffer, 0xee);
        @memcpy(buffer[offset..][0..egress_token.token_bytes], &wire);
        const read = egress_token.fromBytes(buffer[offset..][0..egress_token.token_bytes]);
        try std.testing.expectEqualSlices(u8, &wire, egress_token.asBytes(&read));
        try std.testing.expectEqual(request_fields, try egress_token.verify(&key_a, &read));
    }
}

test "the none token is all zeros, fails verification and is never minted" {
    try std.testing.expect(egress_token.isNone(&egress_token.none));
    const none_token = egress_token.fromBytes(&egress_token.none);
    try std.testing.expectError(error.BadTag, egress_token.verify(&key_a, &none_token));
    const minted = egress_token.mint(&key_a, boot_fields);
    try std.testing.expect(!egress_token.isNone(egress_token.asBytes(&minted)));
}
