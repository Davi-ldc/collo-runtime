//! Byte counters, sent and received, for the gateway's outbound transport.
//! One `Bytes` value counts one kind of byte at one boundary: plaintext HTTP
//! bytes, which an HTTP/1 exchange or an HTTP/2 stream reports as a fetch
//! body's `billed_sent` and `billed_received` (`fetch_body.EgressMeters`),
//! or TLS ciphertext crossing a memory BIO, which is a connection's cost.
//! TCP/IP headers, retransmits and other kernel bookkeeping are never counted.
//! A `Bytes` has no synchronization, and additions saturate at the u64
//! maximum instead of wrapping.
//!
//! This file is its own libc-free module, `collo_egress_accounting`, so the
//! HTTP/2 codec, which links without libc, can count bytes.

const std = @import("std");

pub const Bytes = struct {
    sent: u64 = 0,
    received: u64 = 0,

    pub fn addSent(self: *Bytes, amount: usize) void {
        self.sent = addSaturating(self.sent, amount);
    }

    pub fn addReceived(self: *Bytes, amount: usize) void {
        self.received = addSaturating(self.received, amount);
    }

    pub fn add(self: *Bytes, other: Bytes) void {
        self.sent = addU64Saturating(self.sent, other.sent);
        self.received = addU64Saturating(self.received, other.received);
    }

    pub fn total(self: Bytes) u64 {
        return addU64Saturating(self.sent, self.received);
    }
};

/// Meters summed over the hops of an HTTP/1 redirect chain: `billed` counts
/// plaintext HTTP bytes per direction, which on HTTP/1 are the serialized
/// head and body, and `cost` counts TLS ciphertext.
pub const ChainMeters = struct {
    billed: Bytes = .{},
    cost: u64 = 0,
};

fn addSaturating(current: u64, amount: usize) u64 {
    return addU64Saturating(current, @intCast(amount));
}

fn addU64Saturating(lhs: u64, rhs: u64) u64 {
    return std.math.add(u64, lhs, rhs) catch std.math.maxInt(u64);
}
