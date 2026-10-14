//! A thread's lease on the current egress gateway: the gateway's generation and a copy of the key
//! it mints tokens with. Each ingress lane owns one and renews it from `Manager.renewLease` when
//! `currentGeneration` moves, once per loop pass, so the request path takes no lock and sends the
//! gateway nothing: the lease holds no descriptor of it at all.
//!
//! Only the owning thread touches a lease.

const std = @import("std");
const ipc = @import("collo_ipc");

const egress_token = ipc.egress_token;

pub const Lease = struct {
    /// The gateway the key belongs to, or 0 while the lease holds none.
    generation: u64 = 0,
    key: egress_token.Key = .{ .bytes = @splat(0) },

    /// Scrubs the key.
    pub fn deinit(self: *Lease) void {
        std.crypto.secureZero(u8, &self.key.bytes);
        self.* = undefined;
    }

    /// Takes over the generation and key `Manager.renewLease` hands out, generation 0 and the zero
    /// key when no gateway is current. The previous key is scrubbed before the new one takes its
    /// place.
    pub fn replace(self: *Lease, generation: u64, key: egress_token.Key) void {
        std.crypto.secureZero(u8, &self.key.bytes);
        self.generation = generation;
        self.key = key;
    }

    /// The token of a request dispatched to a worker whose egress session belongs to gateway
    /// `session_generation`. When the lease holds another gateway's key the worker is detached
    /// or waiting for its reattach, so it gets `egress_token.none` and refuses the request's
    /// fetches itself.
    pub fn mint(
        self: *const Lease,
        session_generation: u64,
        fields: egress_token.Fields,
    ) egress_token.Bytes {
        if (self.generation == 0 or self.generation != session_generation)
            return egress_token.none;
        const token = egress_token.mint(&self.key, fields);
        return egress_token.asBytes(&token).*;
    }
};
