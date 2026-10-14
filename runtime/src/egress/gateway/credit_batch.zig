//! Flow-control credits on their way back to the shard engines, merged so that a burst of
//! consumed chunks costs one engine call, and one take of the engine's lock, per stream instead
//! of one per chunk. The body drain (`runtime/body_pump.zig`) and the release drain
//! (`runtime/release_flow.zig`) each fill one batch per pass on the gateway's loop thread and
//! flush it before the pass returns.
//!
//! HTTP/2 credits merge when shard, engine run, source, stream and `update_stream_window` all
//! match, summing `encoded_bytes`, and travel as one `body_credit.H2Data`. A stream never has
//! more bytes acknowledged than it holds as unacknowledged credit, which a merged credit respects
//! because each of its parts was recorded against the stream once; the engine drops a credit
//! worth more than its stream holds, so one that broke this would change nothing. A zero-byte
//! credit, from the empty final DATA frame that surfaces a deferred end of stream, keeps its own
//! slot and so still reaches the engine. HTTP/1 resume credits deduplicate by shard, run and
//! source: a source has at most one resume outstanding, since every later pause comes from a new
//! append that exhausts capacity and attaches its own credit, and the engine ignores a resume
//! whose body is not parked on credit. Each credit keeps the run that issued it until the engine
//! takes it, where a credit of a run that ended is dropped (`engine.zig:Engine.releaseCredit`).
//!
//! A full table flushes before it takes another credit, so batching never fails.

const std = @import("std");

const body_credit = @import("collo_egress_client").body_credit;
const engine_mod = @import("engine.zig");
const shard_mod = @import("shard.zig");

pub const CreditBatch = struct {
    h2: [h2_slot_count]H2Slot = undefined,
    h2_len: usize = 0,
    h1: [h1_slot_count]H1Slot = undefined,
    h1_len: usize = 0,

    pub const h2_slot_count = 8;
    pub const h1_slot_count = 4;

    const H2Slot = struct {
        shard_index: usize,
        run: engine_mod.Run,
        source_id: u64,
        stream_id: u32,
        encoded_bytes: usize,
        update_stream_window: bool,
    };

    const H1Slot = struct {
        shard_index: usize,
        run: engine_mod.Run,
        source_id: u64,
    };

    /// Adds `credit`, which run `run` of shard `shard_index`'s engine issued and which goes back
    /// to that engine.
    pub fn add(
        self: *CreditBatch,
        shards: *shard_mod.Set,
        shard_index: usize,
        run: engine_mod.Run,
        credit: body_credit.Handle,
    ) void {
        switch (credit) {
            .none => {},
            .h1_resume => |h1| {
                for (self.h1[0..self.h1_len]) |slot| {
                    if (slot.shard_index == shard_index and slot.run == run and slot.source_id == h1.source_id)
                        return;
                }
                if (self.h1_len == self.h1.len)
                    self.flush(shards);
                self.h1[self.h1_len] = .{ .shard_index = shard_index, .run = run, .source_id = h1.source_id };
                self.h1_len += 1;
            },
            .h2_data => |h2| {
                for (self.h2[0..self.h2_len]) |*slot| {
                    // The codec clears `update_stream_window` only on a stream's END_STREAM
                    // frame. Folding that credit into a slot whose flag is set would add the final
                    // frame's bytes to the stream receive window and send WINDOW_UPDATE for a
                    // stream the peer has closed. A stream has one such credit, so keeping it apart
                    // costs at most one extra slot.
                    if (slot.shard_index == shard_index and
                        slot.run == run and
                        slot.source_id == h2.source_id and
                        slot.stream_id == h2.stream_id and
                        slot.update_stream_window == h2.update_stream_window)
                    {
                        slot.encoded_bytes +|= h2.encoded_bytes;
                        return;
                    }
                }
                if (self.h2_len == self.h2.len)
                    self.flush(shards);
                self.h2[self.h2_len] = .{
                    .shard_index = shard_index,
                    .run = run,
                    .source_id = h2.source_id,
                    .stream_id = h2.stream_id,
                    .encoded_bytes = h2.encoded_bytes,
                    .update_stream_window = h2.update_stream_window,
                };
                self.h2_len += 1;
            },
        }
    }

    /// Sends every merged credit to its engine and empties the batch.
    pub fn flush(self: *CreditBatch, shards: *shard_mod.Set) void {
        for (self.h2[0..self.h2_len]) |slot| {
            shards.get(slot.shard_index).engine.releaseCredit(slot.run, body_credit.h2Data(
                slot.source_id,
                slot.stream_id,
                slot.encoded_bytes,
                slot.update_stream_window,
            ));
        }
        self.h2_len = 0;
        for (self.h1[0..self.h1_len]) |slot|
            shards.get(slot.shard_index).engine.releaseCredit(slot.run, body_credit.h1Resume(slot.source_id));
        self.h1_len = 0;
    }

    pub fn isEmpty(self: *const CreditBatch) bool {
        return self.h2_len == 0 and self.h1_len == 0;
    }
};

comptime {
    std.debug.assert(CreditBatch.h2_slot_count != 0);
    std.debug.assert(CreditBatch.h1_slot_count != 0);
}
