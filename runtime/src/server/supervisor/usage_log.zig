//! The usage log: the supervisor's producer side of `usage.jsonl`. Which
//! record of a request the server keeps is decided by the worker's request
//! table (`request_table.zig`), not here.
//!
//! Records arrive from every thread that drains a worker ring (the metrics
//! thread's periodic drain, a lane's drain when it settles or synthesizes,
//! the reaper's final drains, the exiting thread's last drains) and from a
//! lane that synthesizes a floor record for a request its worker could not
//! account for. `append` encodes a drained batch and hands it to the
//! analytics sink as one append (`server/analytics/sink.zig`), which takes it
//! whole or refuses it whole.
//!
//! A full usage stream holds up no request. A drain on a thread that may
//! block on writing the stream out holds a batch the stream has no room for
//! (`OnFull.hold`): the batch stays in the worker's ring while that thread
//! writes the stream out and offers it again (`drainWorkerFlushing` in
//! `usage_drain.zig`), so a stream that a write-out empties loses nothing.
//! Any other batch the sink refuses, and any floor, is dropped and reported
//! to the sink as lost, which counts it in the usage stream's
//! `Stats.dropped` and logs the counts once per sync interval. The sink also
//! logs the start of the full episode once at `err`, and its `full` flag
//! stays up until the stream has room again, which the server's health
//! answer reports. The drain still moves the worker's ring past a dropped
//! batch and settles its requests in their request table, so a worker's
//! ring never fills behind a stream that does not take records, and no
//! request waits for a record the ring no longer holds. The sink writes,
//! syncs and closes the file; this log never touches it.
//!
//! When room is short, floors are the records that still land: drained
//! batches stop `synthesis_reserve_bytes` short of a full stream, and
//! `appendFloor` may spend that reserve.
//!
//! Without an analytics directory the sink discards usage records and counts
//! them.
//!
//! Locks: `encode_mutex` guards the shared encode buffer and is held across
//! the sink's append, which takes the usage stream's own lock inside it. No
//! other lock is taken under it.

const std = @import("std");
const analytics = @import("collo_server_analytics");

const usage = analytics.usage;

/// Records one drain pass appends at once. `usage_drain.zig` peeks a worker
/// ring in batches of this size, and a batch is accepted whole or not at all.
pub const batch_records_max: usize = 128;
/// Bytes one worst-case batch encodes to: every record at its largest, joined
/// by newlines.
pub const batch_bytes_max: usize = batch_records_max * (usage.json_record_bytes_max + 1);

/// Floor records the usage stream keeps room for once it refuses drained
/// batches: a burst allowance against floors arriving faster than flushes
/// free the stream, such as the requests in flight on several dying workers
/// ending in one flush interval. Not a bound, since nothing bounds how many
/// requests end together; a floor past it is dropped and counted.
pub const synthesis_reserve_records: usize = 64;
pub const synthesis_reserve_bytes: usize = synthesis_reserve_records * (usage.json_record_bytes_max + 1);

comptime {
    // A worst-case batch fits above the reserve in an empty usage stream;
    // otherwise every large batch would be dropped however often the stream
    // is written out.
    std.debug.assert(batch_bytes_max + synthesis_reserve_bytes < analytics.sink.usage_buffer_bytes_max);
}

/// What `append` does with a batch the usage stream has no room for.
pub const OnFull = enum {
    /// Drop it and report it lost, so the caller's ring may move past it:
    /// for a thread that may not block on writing the stream out, such as a
    /// lane.
    drop,
    /// Leave it with the caller, lost to nobody: for a thread that writes the
    /// stream out (`Sink.flush`) and then offers the batch again.
    hold,
};

/// What became of the records handed to `append`.
pub const AppendOutcome = enum {
    /// The sink holds them, or counted them as discarded because it keeps
    /// no usage file.
    taken,
    /// The usage stream had no room: they are lost, and counted in the
    /// stream's `Stats.dropped`.
    dropped,
    /// `OnFull.hold` only: the usage stream had no room and took nothing, and
    /// the records are still the caller's.
    held,
};

/// What became of the floor handed to `appendFloor`. A floor has no ring to
/// wait in, so it is never held.
pub const FloorOutcome = enum {
    /// The sink holds it, or counted it as discarded because it keeps no
    /// usage file.
    taken,
    /// Even the synthesis reserve was spent: it is lost, and counted in the
    /// stream's `Stats.dropped`.
    dropped,
};

pub const UsageLog = struct {
    allocator: std.mem.Allocator,
    /// Borrowed: the server opens the sink before the supervisor and closes it
    /// after the supervisor's teardown (`server/main.zig`).
    sink: *analytics.Sink,

    /// Guards `encode_buffer`.
    encode_mutex: std.Thread.Mutex = .{},
    /// `batch_bytes_max` bytes, allocated once. Empty while the sink keeps no
    /// usage file, since nothing is encoded then.
    encode_buffer: []u8,

    pub fn init(allocator: std.mem.Allocator, sink: *analytics.Sink) error{OutOfMemory}!UsageLog {
        const encode_buffer: []u8 = if (sink.enabled(.usage))
            try allocator.alloc(u8, batch_bytes_max)
        else
            &.{};
        return .{
            .allocator = allocator,
            .sink = sink,
            .encode_buffer = encode_buffer,
        };
    }

    pub fn deinit(self: *UsageLog) void {
        self.allocator.free(self.encode_buffer);
        self.* = undefined;
    }

    // --- records -------------------------------------------------------------

    /// Hands drained `records` to the sink whole or not at all, leaving the
    /// synthesis reserve free. A batch the stream has no room for is dropped
    /// and counted, or with `.hold` left with the caller. Once the records
    /// are taken or dropped, the caller's ring may move past them. Any thread
    /// may call it.
    pub fn append(self: *UsageLog, records: []const usage.UsageRecord, on_full: OnFull) AppendOutcome {
        std.debug.assert(records.len <= batch_records_max);
        if (records.len == 0)
            return .taken;
        if (!self.sink.enabled(.usage)) {
            self.sink.noteDiscarded(.usage, records.len);
            return .taken;
        }
        self.encode_mutex.lock();
        defer self.encode_mutex.unlock();
        var writer: std.Io.Writer = .fixed(self.encode_buffer);
        for (records, 0..) |*usage_record, index| {
            // The buffer holds a worst-case batch, so the writer cannot run out.
            if (index != 0)
                writer.writeByte('\n') catch unreachable;
            usage.writeRecordJson(&writer, usage_record) catch unreachable;
        }
        const batch = writer.buffered();
        switch (on_full) {
            .drop => self.sink.appendKeepingFree(.usage, batch, synthesis_reserve_bytes) catch |err| switch (err) {
                error.SinkBufferFull => {
                    self.noteDropped(records.len);
                    return .dropped;
                },
            },
            .hold => {
                if (!self.sink.tryAppendKeepingFree(.usage, batch, synthesis_reserve_bytes))
                    return .held;
            },
        }
        return .taken;
    }

    /// Hands one synthesized floor record to the sink, which may spend the
    /// synthesis reserve on it. A floor that finds even the reserve gone is
    /// dropped and counted. Any thread may call it.
    pub fn appendFloor(self: *UsageLog, floor: *const usage.UsageRecord) FloorOutcome {
        if (!self.sink.enabled(.usage)) {
            self.sink.noteDiscarded(.usage, 1);
            return .taken;
        }
        var buffer: [usage.json_record_bytes_max]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        // The buffer holds a worst-case record, so the writer cannot run out.
        usage.writeRecordJson(&writer, floor) catch unreachable;
        self.sink.append(.usage, writer.buffered()) catch |err| switch (err) {
            error.SinkBufferFull => {
                self.noteDropped(1);
                return .dropped;
            },
        };
        return .taken;
    }

    /// Reports `count` records the stream refused as lost, so the sink counts
    /// them and logs the count with its other losses. The sink already logged
    /// the start of the full episode they belong to, once.
    fn noteDropped(self: *UsageLog, count: usize) void {
        self.sink.noteDropped(.usage, count);
    }
};
