//! The egress token: 56 bytes that admit a worker's fetches at the egress gateway for one
//! request, or for the evaluation of its route's modules at boot. Only the server mints tokens:
//! an ingress lane mints one for each dispatch to a worker that has an egress session, and the
//! launcher mints the boot token that WorkerInit carries. The worker never reads a token. It
//! copies the bytes from its `DispatchWork` into every `EgressFetchStart`, and the gateway's loop
//! thread verifies them at fetch admission, so nothing is registered with the gateway per request.
//!
//! The tag is the first `tag_bytes` of HMAC-SHA256 over the first `body_bytes` under a key the
//! server draws at each gateway spawn and sends in its hello (`egress/gateway/control.zig`). The
//! key stays in the server and the gateway, and every gateway gets a new one, so tokens minted for
//! an earlier gateway fail. The zero key verifies nothing, which keeps a gateway that has no key
//! yet from admitting any fetch.
//!
//! A token names the worker session it was minted for, and the gateway admits it only from that
//! session's command ring, so a worker cannot spend another worker's tokens. Inside one worker the
//! process is the boundary, and the tokens of its requests are not kept apart. A token admits
//! fetches until its deadline. The gateway keeps a budget for it from its first verified fetch
//! and drops that budget at `request_ended` at the latest (`egress/gateway/budgets.zig`), and a
//! token that comes back after its budget was dropped starts a new one. A worker that keeps a
//! token after its request, or a `request_ended` that is lost, therefore costs fetches under the
//! token's policy until its deadline, within the session's cap on active fetches, and nothing
//! else.
//!
//! `verify` compares the tag first, in constant time over all of it, and reads the version and the
//! kind only once the tag has vouched for them, so a forged token cannot learn which field it got
//! wrong. Tokens cross sockets and rings as raw native-endian bytes like the other IPC structs, and
//! `fromBytes` copies them out at any alignment. Every function is pure and runs on any thread.

const std = @import("std");

const assert = std.debug.assert;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

/// The layout `mint` writes and `verify` accepts.
pub const version: u8 = 1;

pub const key_bytes: usize = 32;
/// The bytes the tag covers: every field of `Token` before `tag`.
pub const body_bytes: usize = 40;
pub const tag_bytes: usize = 16;
pub const token_bytes: usize = body_bytes + tag_bytes;

/// A token as `DispatchWork`, `WorkerInit` and `EgressFetchStart` carry it.
pub const Bytes = [token_bytes]u8;

/// The bytes that stand for no token: a request of a worker without an egress session, or a boot
/// without a grant. They fail `verify`, and a worker refuses a fetch whose request carries them
/// before the fetch leaves it.
pub const none: Bytes = @splat(0);

/// `Token.kind` on the wire. Zero names no kind, so `none` is no token of either.
pub const kind_request: u8 = 1;
pub const kind_boot: u8 = 2;

pub const Kind = enum {
    /// Admits the fetches of one request.
    request,
    /// Admits the fetches of module top-level code while a worker boots; its request id and
    /// generation are 0.
    boot,
};

/// The wire form of `Fields`, with the version first and the tag over everything before it
/// last. Every field is a plain integer, so any bytes read as some token, and only `verify`
/// says whether the server minted it.
pub const Token = extern struct {
    version: u8,
    kind: u8,
    policy_id: u16,
    budget: u32,
    session_id: u64,
    request_id: u64,
    request_generation: u64,
    deadline_monotonic_ns: u64,
    tag: [tag_bytes]u8,
};

comptime {
    // The token rides inside other pinned headers as `Bytes`, so its size and the offset of
    // every field are wire facts; an edit that moves one edits these pins too.
    assert(@sizeOf(Token) == token_bytes);
    assert(@alignOf(Token) == 8);
    assert(@offsetOf(Token, "version") == 0);
    assert(@offsetOf(Token, "kind") == 1);
    assert(@offsetOf(Token, "policy_id") == 2);
    assert(@offsetOf(Token, "budget") == 4);
    assert(@offsetOf(Token, "session_id") == 8);
    assert(@offsetOf(Token, "request_id") == 16);
    assert(@offsetOf(Token, "request_generation") == 24);
    assert(@offsetOf(Token, "deadline_monotonic_ns") == 32);
    assert(@offsetOf(Token, "tag") == body_bytes);
    assert(tag_bytes <= HmacSha256.mac_length);
}

/// The secret the server and one gateway share. It is extern so the hello can carry it as is.
pub const Key = extern struct {
    bytes: [key_bytes]u8,

    /// A key from the system's random source, drawn by the server for each gateway it spawns.
    /// Panics on a draw of all zeros: that only comes from a broken random source, and the zero
    /// key would leave the gateway admitting no fetch at all.
    pub fn random() Key {
        var key: Key = undefined;
        std.crypto.random.bytes(&key.bytes);
        if (key.isZero())
            @panic("egress token key: the random source returned zeros");
        return key;
    }

    /// Whether every byte is zero, in constant time, since the key is secret.
    pub fn isZero(self: *const Key) bool {
        const zero: [key_bytes]u8 = @splat(0);
        return std.crypto.timing_safe.eql([key_bytes]u8, self.bytes, zero);
    }

    comptime {
        assert(@sizeOf(Key) == key_bytes);
    }
};

/// What a token says, as `mint` takes it and `verify` returns it.
pub const Fields = struct {
    kind: Kind,
    /// The id of the route's network policy in the table the gateway received in its hello.
    policy_id: u16,
    /// Fetches the gateway admits under the token, counted from its first verified fetch.
    budget: u32,
    /// The worker session the token was minted for, the only one whose fetches may present it.
    session_id: u64,
    /// Both nonzero for a request token and both 0 for a boot token.
    request_id: u64,
    request_generation: u64,
    /// Absolute CLOCK_MONOTONIC time from which the token admits nothing, never 0: the request's
    /// deadline for a request token, the end of the worker's init window for a boot token.
    deadline_monotonic_ns: u64,
};

pub const VerifyError = error{ BadTag, BadVersion, BadKind };

/// Mints a token for `fields` under `key`. The server calls it with values it owns, so a field
/// out of shape (a zero session or deadline, a zero budget, request ids that do not match the
/// kind) is a server bug and asserted.
pub fn mint(key: *const Key, fields: Fields) Token {
    assert(!key.isZero());
    assert(fields.session_id != 0);
    assert(fields.budget != 0);
    assert(fields.deadline_monotonic_ns != 0);
    switch (fields.kind) {
        .request => {
            assert(fields.request_id != 0);
            assert(fields.request_generation != 0);
        },
        .boot => {
            assert(fields.request_id == 0);
            assert(fields.request_generation == 0);
        },
    }
    var token = Token{
        .version = version,
        .kind = encodeKind(fields.kind),
        .policy_id = fields.policy_id,
        .budget = fields.budget,
        .session_id = fields.session_id,
        .request_id = fields.request_id,
        .request_generation = fields.request_generation,
        .deadline_monotonic_ns = fields.deadline_monotonic_ns,
        .tag = undefined,
    };
    token.tag = tagOf(key, &token);
    return token;
}

/// Returns the fields of a token the server minted under `key`. A tag that does not match fails
/// with `error.BadTag` whatever else the token holds, and so does every tag under the zero key; a
/// matching tag over another layout fails with `error.BadVersion`, and over a kind this file does
/// not know with `error.BadKind`. The caller still checks the session and the deadline
/// (`expired`).
pub fn verify(key: *const Key, token: *const Token) VerifyError!Fields {
    if (key.isZero())
        return error.BadTag;
    const expected = tagOf(key, token);
    if (!std.crypto.timing_safe.eql([tag_bytes]u8, expected, token.tag))
        return error.BadTag;
    if (token.version != version)
        return error.BadVersion;
    return .{
        .kind = try decodeKind(token.kind),
        .policy_id = token.policy_id,
        .budget = token.budget,
        .session_id = token.session_id,
        .request_id = token.request_id,
        .request_generation = token.request_generation,
        .deadline_monotonic_ns = token.deadline_monotonic_ns,
    };
}

/// Whether a token `verify` accepted admits nothing at `now_monotonic_ns`.
pub fn expired(token: *const Token, now_monotonic_ns: u64) bool {
    return deadlinePassed(token.deadline_monotonic_ns, now_monotonic_ns);
}

/// The one expiry rule: a deadline admits nothing from the instant it names. The gateway applies
/// it to the deadline it keeps beside a token's budget as well.
pub fn deadlinePassed(deadline_monotonic_ns: u64, now_monotonic_ns: u64) bool {
    return now_monotonic_ns >= deadline_monotonic_ns;
}

/// Reads a wire kind; any value other than the two kinds fails with `error.BadKind`.
pub fn decodeKind(raw: u8) error{BadKind}!Kind {
    return switch (raw) {
        kind_request => .request,
        kind_boot => .boot,
        else => error.BadKind,
    };
}

pub fn encodeKind(kind: Kind) u8 {
    return switch (kind) {
        .request => kind_request,
        .boot => kind_boot,
    };
}

/// The token's wire bytes, borrowed from `token`.
pub fn asBytes(token: *const Token) *const Bytes {
    return std.mem.asBytes(token);
}

/// Copies a token out of wire bytes at any alignment.
pub fn fromBytes(bytes: *const Bytes) Token {
    var token: Token = undefined;
    @memcpy(std.mem.asBytes(&token), bytes);
    return token;
}

/// Whether `bytes` are `none`. A minted token never is, since its version byte is not zero.
pub fn isNone(bytes: *const Bytes) bool {
    return std.mem.allEqual(u8, bytes, 0);
}

fn tagOf(key: *const Key, token: *const Token) [tag_bytes]u8 {
    var mac: [HmacSha256.mac_length]u8 = undefined;
    HmacSha256.create(&mac, asBytes(token)[0..body_bytes], &key.bytes);
    return mac[0..tag_bytes].*;
}
