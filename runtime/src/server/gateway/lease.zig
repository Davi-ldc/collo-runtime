//! A thread's lease on the current egress gateway: a copy of the key it mints tokens with, a dup
//! of the gateway's control socket it sends `request_ended` batches on, and the batch. Each
//! ingress lane owns one and renews it from `Manager.renewLease` when `currentGeneration` moves,
//! once per loop pass, so the request path takes no lock and makes no call to the gateway. The
//! descriptor is the lane's own, so a gateway retired meanwhile can neither close it under the
//! lane nor have its number reused for another file; sends on it then fail and are counted.
//!
//! Only the owning thread touches a lease.

const std = @import("std");
const fd_mod = @import("collo_os").fd;
const ipc = @import("collo_ipc");
const control = @import("collo_egress_gateway").control;

const egress_token = ipc.egress_token;

pub const Lease = struct {
    /// The gateway the key and the descriptor belong to, or 0 while the lease holds none.
    generation: u64 = 0,
    key: egress_token.Key = .{ .bytes = @splat(0) },
    control: fd_mod.OwnedFd = .{},
    ended: control.RequestEndedBatch = .{},
    /// Batches lost because the gateway's socket was full or the gateway was gone; each costs its
    /// requests' fetches until their tokens' deadlines.
    ended_batches_dropped_full: u64 = 0,
    ended_batches_dropped_closed: u64 = 0,

    /// Closes the descriptor and scrubs the key.
    pub fn deinit(self: *Lease) void {
        self.control.deinit();
        std.crypto.secureZero(u8, &self.key.bytes);
        self.* = undefined;
    }

    /// Takes over the generation, key and descriptor `Manager.renewLease` hands out, generation 0
    /// with no descriptor when no gateway is current. Entries still pending belong to the
    /// previous gateway, which is gone with their budgets, so they are dropped, and the previous
    /// key is scrubbed before the new one takes its place.
    pub fn replace(
        self: *Lease,
        generation: u64,
        key: egress_token.Key,
        control_fd: fd_mod.OwnedFd,
    ) void {
        self.control.deinit();
        self.ended.clear();
        std.crypto.secureZero(u8, &self.key.bytes);
        self.generation = generation;
        self.key = key;
        self.control = control_fd;
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

    /// Notes that a request which carried a token of gateway `session_generation` ended. An
    /// entry for another gateway is dropped, since that gateway is gone and its budgets with it.
    /// A full batch goes out at once.
    pub fn noteEnded(self: *Lease, session_generation: u64, entry: control.RequestEndedEntry) void {
        if (self.generation == 0 or self.generation != session_generation)
            return;
        if (self.ended.append(entry))
            return;
        self.flush();
        const appended = self.ended.append(entry);
        std.debug.assert(appended);
    }

    /// Sends the pending entries as one packet, at the end of each loop pass. It never waits and
    /// never fails: a batch the socket refuses is counted and dropped.
    pub fn flush(self: *Lease) void {
        if (self.ended.isEmpty())
            return;
        if (!self.control.isValid()) {
            self.ended.clear();
            return;
        }
        self.ended.sendAndClear(self.control.fd()) catch |err| switch (err) {
            error.WouldBlock => self.ended_batches_dropped_full += 1,
            else => self.ended_batches_dropped_closed += 1,
        };
    }
};
