//! The analytics sink: one JSON Lines file per record kind in the analytics
//! directory, plus the console stream on stderr. Producers hand it encoded
//! records from any thread; each stream holds them in a bounded byte ring
//! until its flusher writes them out in batches, syncing the files on an
//! interval and at close.
//!
//! Ownership and threads: the server opens the sink before the supervisor and
//! closes it after the supervisor's teardown, the last producer
//! (`server/main.zig`). Producers are the ingress metrics thread's drains, the
//! usage drains on the metrics, reaper, lane and exiting threads, a lane that
//! writes the floor usage record for a request its worker could not account
//! for, and worker teardown on whichever thread runs it. A stream's mutex
//! guards its ring cursors and counters and is held only to copy a record in
//! or move a cursor, never across a write.
//!
//! The record files and the console have separate flushers, so a stderr
//! reader that stops reading blocks only the console's. `flush` writes the
//! files under `flush_mutex`: the ingress metrics thread calls it every tick,
//! and a usage drain on a thread that may block (the metrics, reaper and
//! exiting threads) calls it whenever a batch finds the usage stream full
//! (`drainWorkerFlushing` in `server/supervisor/usage_drain.zig`).
//! `flushConsole` writes stderr under `console_flush_mutex`, from the ingress
//! service's console thread. `close` runs both last. A console write holds
//! the process stderr lock for one batch of whole lines at a time, so
//! `std.log` output from other threads lands between batches, never inside a
//! line.
//!
//! Invariants:
//! - A record enters a ring whole or not at all and gains one trailing
//!   newline, so each file holds complete lines in append order. Bytes a
//!   failed write left behind stay buffered and go first on the next flush.
//! - Each record file is opened with O_APPEND, O_CLOEXEC and O_NOFOLLOW and
//!   never truncated: a restart appends to what an earlier run wrote, and a
//!   symlink planted under a record file's name is refused, not followed.
//!   Rotation works two ways. logrotate's `copytruncate` truncates a file in
//!   place, which O_APPEND follows to the new end, with no signal. A rotation
//!   that renames the files asks for a reopen (`requestReopen`, which the
//!   server's SIGHUP calls): the next `flush`, the metrics thread's tick in a
//!   running server, writes what is buffered to the renamed files, syncs them
//!   and opens the names again, with the same flags and under the same
//!   `flush_mutex` as every file write. A file whose last write stopped
//!   inside a line is reopened only once a later flush ends that line in it.
//!   A name that cannot be opened keeps its old descriptor, and the failure
//!   is logged once at `err`.
//! - A record stream with no file (no directory configured) buffers nothing,
//!   counts each record it discards and has nothing to reopen. The console
//!   stream always writes.
//! - A stream that refuses a record (`append`, `appendKeepingFree`) or drops
//!   one (`appendLossy`) is full (`full`, one atomic any thread reads without
//!   the stream's lock) until its flusher has made room again for the
//!   largest record it refused. A full usage stream is logged once at `err`
//!   when it begins: usage records are the server's account of what each
//!   request used, and one the stream refuses is lost for good. A producer
//!   that keeps a record the stream has no room for, and offers it again once
//!   the stream is written out, asks with `tryAppendKeepingFree`, whose
//!   refusal loses nothing and so marks nothing.
//! - Every loss is counted per stream in `Stats`, and drops and refusals are
//!   logged at most once per sync interval.

const std = @import("std");
const fd_mod = @import("collo_os").fd;

/// Where a record goes. `logs`, `access` and `usage` are files in the
/// analytics directory; `console` is stderr.
pub const Stream = enum {
    logs,
    access,
    usage,
    console,
};

const stream_count = @typeInfo(Stream).@"enum".fields.len;

/// Ring capacity of each stream. The ingress metrics thread flushes once per
/// `metrics_drain_interval_ns` (`server/ingress/service_observability.zig`),
/// and a ring holds many intervals of ordinary traffic: about five thousand
/// access or usage records of a few hundred bytes, and console lines at the
/// message cap number about a thousand in `logs` and two hundred and fifty
/// in `console`. A stream that outruns its ring loses records, counted,
/// instead of growing.
pub const logs_buffer_bytes_max: usize = 4 * 1024 * 1024;
pub const access_buffer_bytes_max: usize = 2 * 1024 * 1024;
pub const usage_buffer_bytes_max: usize = 2 * 1024 * 1024;
pub const console_buffer_bytes_max: usize = 1024 * 1024;

/// Longest a written record may wait for fdatasync. Bounds what a crash of
/// the node can lose to roughly one interval of writes.
pub const sync_interval_ns: u64 = std.time.ns_per_s;

/// Most bytes one console write carries, cut back to the end of its last
/// whole line, and so the most a `std.log` caller waits on the stderr lock
/// behind one batch. Larger than any console line the drain encodes
/// (`logs.zig` asserts it), so every batch ends on a line boundary.
pub const console_write_bytes_max: usize = 64 * 1024;

comptime {
    std.debug.assert(console_write_bytes_max <= console_buffer_bytes_max);
}

/// Mode of a record file the sink creates.
pub const file_mode: std.posix.mode_t = 0o640;

pub fn bufferBytesMax(stream: Stream) usize {
    return switch (stream) {
        .logs => logs_buffer_bytes_max,
        .access => access_buffer_bytes_max,
        .usage => usage_buffer_bytes_max,
        .console => console_buffer_bytes_max,
    };
}

/// The file a record stream appends to, inside the analytics directory; null
/// for the console stream.
pub fn fileName(stream: Stream) ?[]const u8 {
    return switch (stream) {
        .logs => "logs.jsonl",
        .access => "access.jsonl",
        .usage => "usage.jsonl",
        .console => null,
    };
}

/// Counters of one stream since `open`.
pub const Stats = struct {
    /// Records buffered.
    appended: u64 = 0,
    /// Records `appendLossy` found no room for, plus records producers lost
    /// before offering them or after the stream refused them (`noteDropped`).
    dropped: u64 = 0,
    /// Calls to `append` and `appendKeepingFree` that found no room, each one
    /// record or one batch of lines. The caller decides what becomes of them
    /// and reports what it loses with `noteDropped`.
    refused: u64 = 0,
    /// Records for a stream with no file.
    discarded: u64 = 0,
    bytes_written: u64 = 0,
    write_errors: u64 = 0,
    syncs: u64 = 0,
    sync_errors: u64 = 0,
};

pub const Options = struct {
    /// Existing directory the record files go to, absolute or relative to the
    /// working directory. null keeps only the console stream.
    directory: ?[]const u8,
    /// Borrowed descriptor the console stream writes to; it must stay open
    /// until `close`.
    console_fd: std.posix.fd_t = std.posix.STDERR_FILENO,
};

pub const Sink = struct {
    allocator: std.mem.Allocator,
    channels: [stream_count]Channel,
    /// The analytics directory as `open` received it, owned by the sink, or
    /// null without one. A reopen opens the directory again by this path.
    directory_path: ?[]u8,
    /// Set by `requestReopen` from any thread; the next `flush` takes it.
    reopen_requested: std.atomic.Value(bool) = .init(false),
    /// Serializes the flushers of the record files.
    flush_mutex: std.Thread.Mutex = .{},
    /// Serializes the flushers of the console stream.
    console_flush_mutex: std.Thread.Mutex = .{},
    /// Monotonic time of the last sync pass. Guarded by `flush_mutex`.
    last_sync_ns: u64 = 0,
    /// Each stream's counters as of the last loss report. Guarded by
    /// `flush_mutex`.
    reported: [stream_count]Stats = @splat(.{}),

    /// Opens every stream: with a directory, creates or opens its three record
    /// files for appending; without one, only the console stream buffers.
    /// Fails with `error.FileNotFound` when the directory does not exist, and
    /// on any failure leaves nothing open.
    pub fn open(target: *Sink, allocator: std.mem.Allocator, options: Options) !void {
        std.debug.assert(options.console_fd >= 0);
        var directory: ?std.fs.Dir = null;
        if (options.directory) |path|
            directory = try std.fs.cwd().openDir(path, .{});
        defer if (directory) |*dir| dir.close();
        const directory_path: ?[]u8 = if (options.directory) |path| try allocator.dupe(u8, path) else null;
        errdefer if (directory_path) |path| allocator.free(path);

        target.* = .{ .allocator = allocator, .channels = undefined, .directory_path = directory_path };
        var opened: usize = 0;
        errdefer {
            for (target.channels[0..opened]) |*opened_channel|
                opened_channel.deinit(allocator);
        }
        for (std.enums.values(Stream)) |stream| {
            target.channels[@intFromEnum(stream)] = try openChannel(
                allocator,
                stream,
                directory,
                options.console_fd,
            );
            opened += 1;
        }
    }

    /// Writes everything still buffered, console included, syncs the files and
    /// closes them. Call it once, after the last producer and the console
    /// flusher have stopped; bytes a write refuses here are lost and logged.
    pub fn close(self: *Sink) void {
        self.flushConsole();
        self.flush_mutex.lock();
        self.writeRecordFiles();
        self.syncAll();
        self.reportLosses();
        self.flush_mutex.unlock();
        for (std.enums.values(Stream)) |stream| {
            const target = self.streamChannel(stream);
            const unwritten = target.head - target.tail;
            if (unwritten != 0) {
                std.log.warn("analytics {s}: {d} buffered bytes lost at close", .{
                    @tagName(stream),
                    unwritten,
                });
            }
            target.deinit(self.allocator);
        }
        if (self.directory_path) |path|
            self.allocator.free(path);
        self.* = undefined;
    }

    /// Whether records of `stream` go anywhere. A producer may skip encoding
    /// a record for a disabled stream and call `noteDiscarded` instead.
    pub fn enabled(self: *const Sink, stream: Stream) bool {
        return self.channels[@intFromEnum(stream)].destination != .none;
    }

    /// Whether `stream` refused or dropped a record and has not had room
    /// for the largest such record since (the header's invariant). One
    /// atomic load, so any thread may ask without the stream's lock.
    pub fn full(self: *const Sink, stream: Stream) bool {
        return self.channels[@intFromEnum(stream)].full.load(.acquire);
    }

    /// Asks the next `flush` to reopen the record files by name, for a
    /// rotation that renamed them. Any thread may call it, the signal
    /// monitor included; a sink with no directory has nothing to reopen.
    pub fn requestReopen(self: *Sink) void {
        self.reopen_requested.store(true, .release);
    }

    /// Buffers one encoded record, or refuses it whole when the stream has
    /// no room, for a caller that decides what a refusal costs it and reports
    /// what it loses (`noteDropped`). `record` is one or more complete lines
    /// joined by newlines, without the final newline the sink adds, so a
    /// batch that must land whole is one call; it is copied before this
    /// returns. A disabled stream discards and counts it and still returns
    /// success.
    pub fn append(self: *Sink, stream: Stream, record: []const u8) error{SinkBufferFull}!void {
        return self.appendKeepingFree(stream, record, 0);
    }

    /// `append` that also refuses unless `keep_free_bytes` stay free after
    /// the record. For a producer whose records matter less when room is
    /// short, so the last bytes of the stream go to one whose records matter
    /// more.
    pub fn appendKeepingFree(
        self: *Sink,
        stream: Stream,
        record: []const u8,
        keep_free_bytes: usize,
    ) error{SinkBufferFull}!void {
        const target = self.streamChannel(stream);
        target.mutex.lock();
        switch (enqueueLocked(target, record, keep_free_bytes)) {
            .buffered, .discarded => target.mutex.unlock(),
            .full => {
                target.stats.refused +|= 1;
                const began = markFullLocked(target, record.len + 1 +| keep_free_bytes);
                target.mutex.unlock();
                // Logged after the unlock, so a slow stderr does not hold the
                // stream's lock.
                if (began)
                    reportFullBegan(stream);
                return error.SinkBufferFull;
            },
        }
    }

    /// `appendKeepingFree` for a producer that keeps a record the stream has
    /// no room for and offers it again once the stream is written out, so a
    /// refusal loses nothing: it is neither counted nor marked full. Returns
    /// whether the stream took the record; a disabled stream discards and
    /// counts it, and takes it.
    pub fn tryAppendKeepingFree(
        self: *Sink,
        stream: Stream,
        record: []const u8,
        keep_free_bytes: usize,
    ) bool {
        const target = self.streamChannel(stream);
        target.mutex.lock();
        defer target.mutex.unlock();
        return switch (enqueueLocked(target, record, keep_free_bytes)) {
            .buffered, .discarded => true,
            .full => false,
        };
    }

    /// `append` for a record its producer cannot keep: one that finds no room
    /// is dropped and counted.
    pub fn appendLossy(self: *Sink, stream: Stream, record: []const u8) void {
        const target = self.streamChannel(stream);
        target.mutex.lock();
        switch (enqueueLocked(target, record, 0)) {
            .buffered, .discarded => target.mutex.unlock(),
            .full => {
                target.stats.dropped +|= 1;
                const began = markFullLocked(target, record.len + 1);
                target.mutex.unlock();
                if (began)
                    reportFullBegan(stream);
            },
        }
    }

    /// Counts records a producer lost, before offering them, such as those a
    /// full lane handoff ring turned away, or after the stream refused them,
    /// such as a usage batch.
    pub fn noteDropped(self: *Sink, stream: Stream, count: u64) void {
        const target = self.streamChannel(stream);
        target.mutex.lock();
        defer target.mutex.unlock();
        target.stats.dropped +|= count;
    }

    /// Counts records a producer did not encode because `enabled` said the
    /// stream goes nowhere.
    pub fn noteDiscarded(self: *Sink, stream: Stream, count: u64) void {
        const target = self.streamChannel(stream);
        target.mutex.lock();
        defer target.mutex.unlock();
        target.stats.discarded +|= count;
    }

    /// Writes the buffered records of every record file, reopens the record
    /// files a requested reopen still waits for, and once `sync_interval_ns`
    /// has passed since the last sync pass, syncs the files and reports every
    /// stream's losses, the console's included. Leaves the console stream to
    /// `flushConsole`. `now_ns` is the caller's monotonic clock.
    pub fn flush(self: *Sink, now_ns: u64) void {
        self.flush_mutex.lock();
        defer self.flush_mutex.unlock();
        self.writeRecordFiles();
        if (self.reopen_requested.swap(false, .acq_rel))
            self.markReopenPending();
        self.reopenPendingRecordFiles();
        if (now_ns -| self.last_sync_ns >= sync_interval_ns) {
            self.syncAll();
            self.reportLosses();
            self.last_sync_ns = now_ns;
        }
    }

    /// Writes the console stream's buffered lines to stderr. Blocks for as
    /// long as the stderr reader does, so call it from a thread no other
    /// stream waits on.
    pub fn flushConsole(self: *Sink) void {
        self.console_flush_mutex.lock();
        defer self.console_flush_mutex.unlock();
        writeOut(self.streamChannel(.console), .console);
    }

    pub fn stats(self: *Sink, stream: Stream) Stats {
        const target = self.streamChannel(stream);
        target.mutex.lock();
        defer target.mutex.unlock();
        return target.stats;
    }

    fn streamChannel(self: *Sink, stream: Stream) *Channel {
        return &self.channels[@intFromEnum(stream)];
    }

    fn writeRecordFiles(self: *Sink) void {
        for (std.enums.values(Stream)) |stream| {
            if (stream != .console)
                writeOut(self.streamChannel(stream), stream);
        }
    }

    /// Caller holds `flush_mutex`. Every record file is to be opened again.
    fn markReopenPending(self: *Sink) void {
        for (&self.channels) |*target| {
            if (target.destination == .file)
                target.reopen_pending = true;
        }
    }

    /// Caller holds `flush_mutex` and has just written the record files, so
    /// what they held is in the files the old descriptors name, renamed or
    /// not. A file whose last write stopped inside a line keeps its
    /// descriptor until a later flush ends that line in it, so every line
    /// ends in the file it began in. Each other pending name opened again
    /// replaces its descriptor once the old file is synced; a name that fails
    /// keeps its old descriptor, logged once, so the records keep landing in
    /// the renamed file. Only the flusher reads a record file's descriptor,
    /// under `flush_mutex`, so the swap needs no other lock.
    fn reopenPendingRecordFiles(self: *Sink) void {
        if (!self.reopenReady())
            return;
        // A pending file exists only in a sink that opened a directory.
        const path = self.directory_path orelse return;
        var directory = std.fs.cwd().openDir(path, .{}) catch |err| {
            std.log.err("analytics: cannot reopen the record files: cannot open the directory {s}: {s}; the files already open stay in use", .{
                path,
                @errorName(err),
            });
            for (&self.channels) |*target|
                target.reopen_pending = false;
            return;
        };
        defer directory.close();
        for (std.enums.values(Stream)) |stream| {
            const name = fileName(stream) orelse continue;
            const target = self.streamChannel(stream);
            if (!target.reopen_pending or target.ends_mid_line)
                continue;
            target.reopen_pending = false;
            const reopened = openRecordFile(directory, name) catch |err| {
                std.log.err("analytics {s}: cannot reopen {s}/{s}: {s}; the file already open stays in use", .{
                    @tagName(stream),
                    path,
                    name,
                    @errorName(err),
                });
                continue;
            };
            syncFile(target, stream);
            var previous = target.destination.file;
            target.destination.file = reopened;
            previous.deinit();
            // Nothing has been written to the file just opened.
            target.unsynced = false;
        }
    }

    /// Whether a record file waits for a reopen and may take it now.
    fn reopenReady(self: *const Sink) bool {
        for (&self.channels) |*target| {
            if (target.reopen_pending and !target.ends_mid_line)
                return true;
        }
        return false;
    }

    fn syncAll(self: *Sink) void {
        for (std.enums.values(Stream)) |stream|
            syncFile(self.streamChannel(stream), stream);
    }

    fn reportLosses(self: *Sink) void {
        for (std.enums.values(Stream)) |stream| {
            const current = self.stats(stream);
            const previous = &self.reported[@intFromEnum(stream)];
            const dropped = current.dropped - previous.dropped;
            const refused = current.refused - previous.refused;
            if (dropped != 0 or refused != 0) {
                std.log.warn("analytics {s}: {d} records dropped and {d} appends refused since the last report", .{
                    @tagName(stream),
                    dropped,
                    refused,
                });
            }
            previous.* = current;
        }
    }
};

const Destination = union(enum) {
    none,
    file: fd_mod.OwnedFd,
    /// Borrowed: `Options.console_fd`.
    console: std.posix.fd_t,

    fn rawFd(self: Destination) ?std.posix.fd_t {
        return switch (self) {
            .none => null,
            .file => |file| file.fd(),
            .console => |raw_fd| raw_fd,
        };
    }
};

/// One stream's byte ring. Producers copy records in at `head` under `mutex`;
/// the stream's flusher writes `[tail, head)` without the lock, because
/// producers only ever write the free space past `head`, and then advances
/// `tail` under the lock. The cursors only grow, and `cursor % ring.len` is
/// the byte index.
const Channel = struct {
    destination: Destination,
    /// Empty for a stream with no destination.
    ring: []u8,
    mutex: std.Thread.Mutex = .{},
    head: usize = 0,
    tail: usize = 0,
    stats: Stats = .{},
    /// The stream refused or dropped a record and has not had room for
    /// `full_needed_bytes` since. Written under `mutex`, so exactly one
    /// refusal sees it begin; read by anyone without it (`Sink.full`).
    full: std.atomic.Value(bool) = .init(false),
    /// The room the largest record refused in the current full episode
    /// needed, its newline and kept-free bytes included, and never more than
    /// the whole ring. Guarded by `mutex`.
    full_needed_bytes: usize = 0,
    /// Bytes reached the file since its last sync. The stream's flusher only.
    unsynced: bool = false,
    /// The last write failed. The stream's flusher only; logs the transitions
    /// once.
    failing: bool = false,
    /// The last write stopped inside a line, whose rest is still buffered.
    /// The stream's flusher only.
    ends_mid_line: bool = false,
    /// A reopen was asked for and has not replaced this record file's
    /// descriptor yet. The record files' flusher only, under `flush_mutex`.
    reopen_pending: bool = false,

    fn deinit(self: *Channel, allocator: std.mem.Allocator) void {
        switch (self.destination) {
            .file => |*file| file.deinit(),
            .none, .console => {},
        }
        if (self.ring.len != 0)
            allocator.free(self.ring);
        self.* = undefined;
    }
};

fn openChannel(
    allocator: std.mem.Allocator,
    stream: Stream,
    directory: ?std.fs.Dir,
    console_fd: std.posix.fd_t,
) !Channel {
    const destination: Destination = switch (stream) {
        .console => .{ .console = console_fd },
        .logs, .access, .usage => if (directory) |dir|
            .{ .file = try openRecordFile(dir, fileName(stream).?) }
        else
            .none,
    };
    errdefer switch (destination) {
        .file => |file| std.posix.close(file.fd()),
        .none, .console => {},
    };
    if (destination == .none)
        return .{ .destination = .none, .ring = &.{} };
    const ring = try allocator.alloc(u8, bufferBytesMax(stream));
    return .{ .destination = destination, .ring = ring };
}

fn openRecordFile(directory: std.fs.Dir, name: []const u8) !fd_mod.OwnedFd {
    const raw_fd = try std.posix.openat(directory.fd, name, .{
        .ACCMODE = .WRONLY,
        .APPEND = true,
        .CREAT = true,
        .CLOEXEC = true,
        .NOFOLLOW = true,
    }, file_mode);
    return fd_mod.OwnedFd.fromRaw(raw_fd);
}

const Enqueued = enum { buffered, discarded, full };

/// Caller holds `target.mutex`.
fn enqueueLocked(target: *Channel, record: []const u8, keep_free_bytes: usize) Enqueued {
    std.debug.assert(record.len != 0);
    if (target.destination == .none) {
        target.stats.discarded +|= 1;
        return .discarded;
    }
    const free = target.ring.len - (target.head - target.tail);
    if (record.len + 1 +| keep_free_bytes > free)
        return .full;
    copyIn(target.ring, target.head, record);
    copyIn(target.ring, target.head + record.len, "\n");
    target.head += record.len + 1;
    target.stats.appended +|= 1;
    return .buffered;
}

/// Caller holds `target.mutex` and the stream just refused a record that
/// needed `needed_bytes` of room. Returns whether this refusal began the
/// stream's full episode.
fn markFullLocked(target: *Channel, needed_bytes: usize) bool {
    target.full_needed_bytes = @max(target.full_needed_bytes, @min(needed_bytes, target.ring.len));
    const began = !target.full.load(.monotonic);
    target.full.store(true, .release);
    return began;
}

/// Caller holds `target.mutex`. Ends the stream's full episode once the
/// stream has room again for the largest record it refused. A record that
/// merely fits, such as a floor usage record in the room batches must keep
/// free, does not end it.
fn clearFullIfRoomLocked(target: *Channel) void {
    if (!target.full.load(.monotonic))
        return;
    const free = target.ring.len - (target.head - target.tail);
    if (free < target.full_needed_bytes)
        return;
    target.full_needed_bytes = 0;
    target.full.store(false, .release);
}

/// The start of a stream's full episode. Only a full usage stream is
/// logged here, at `err`; the other streams' losses are left to the counts
/// `reportLosses` logs.
fn reportFullBegan(stream: Stream) void {
    switch (stream) {
        .usage => std.log.err("analytics usage: the stream is full, so the usage records it refuses are lost until it has room again", .{}),
        .logs, .access, .console => {},
    }
}

fn copyIn(ring: []u8, cursor: usize, bytes: []const u8) void {
    std.debug.assert(bytes.len <= ring.len);
    const start = cursor % ring.len;
    const first = @min(bytes.len, ring.len - start);
    @memcpy(ring[start..][0..first], bytes[0..first]);
    @memcpy(ring[0 .. bytes.len - first], bytes[first..]);
}

/// The stream's flusher only: writes the stream's buffered bytes, then frees
/// the space that reached the destination and ends a full episode the freed
/// space covers.
fn writeOut(target: *Channel, stream: Stream) void {
    const raw_fd = target.destination.rawFd() orelse return;
    target.mutex.lock();
    const tail = target.tail;
    const head = target.head;
    target.mutex.unlock();
    if (tail == head) {
        // Nothing to write. An empty ring has all the room a refused record
        // is owed (`markFullLocked` caps it at the ring), so a full episode
        // still open ends here.
        if (target.full.load(.acquire)) {
            target.mutex.lock();
            clearFullIfRoomLocked(target);
            target.mutex.unlock();
        }
        return;
    }

    const progress = if (target.destination == .console)
        writeConsoleLines(raw_fd, target.ring, tail, head)
    else
        writeSpan(raw_fd, target.ring, tail, head);
    // The written bytes stay the flusher's until `tail` moves past them, so
    // no producer has reused the last one yet.
    if (progress.bytes != 0)
        target.ends_mid_line = target.ring[(tail + progress.bytes - 1) % target.ring.len] != '\n';

    target.mutex.lock();
    target.tail += progress.bytes;
    target.stats.bytes_written +|= progress.bytes;
    if (progress.failure != null)
        target.stats.write_errors +|= 1;
    clearFullIfRoomLocked(target);
    target.mutex.unlock();

    if (progress.bytes != 0)
        target.unsynced = true;
    if (progress.failure) |err| {
        if (!target.failing) {
            std.log.warn("analytics {s}: write failed, records stay buffered for the next flush: {s}", .{
                @tagName(stream),
                @errorName(err),
            });
        }
        target.failing = true;
    } else if (target.failing) {
        std.log.info("analytics {s}: writes recovered", .{@tagName(stream)});
        target.failing = false;
    }
}

const WriteFailure = std.posix.WriteError || error{WriteZero};

const WriteProgress = struct {
    bytes: usize,
    failure: ?WriteFailure,
};

/// Writes ring bytes `[tail, head)`, one contiguous piece per write call,
/// wrapping at the ring's end. Stops at the first failure and reports how far
/// it got.
fn writeSpan(raw_fd: std.posix.fd_t, ring: []const u8, tail: usize, head: usize) WriteProgress {
    std.debug.assert(tail < head);
    std.debug.assert(head - tail <= ring.len);
    var cursor = tail;
    while (cursor < head) {
        const start = cursor % ring.len;
        const contiguous = @min(head - cursor, ring.len - start);
        const amount = std.posix.write(raw_fd, ring[start..][0..contiguous]) catch |err|
            return .{ .bytes = cursor - tail, .failure = err };
        if (amount == 0)
            return .{ .bytes = cursor - tail, .failure = error.WriteZero };
        cursor += amount;
    }
    return .{ .bytes = head - tail, .failure = null };
}

/// Writes ring bytes `[tail, head)` to the console one batch of whole lines
/// at a time, each batch under the process stderr lock. Stops at the first
/// failure and reports how far it got.
fn writeConsoleLines(raw_fd: std.posix.fd_t, ring: []const u8, tail: usize, head: usize) WriteProgress {
    std.debug.assert(tail < head);
    var cursor = tail;
    while (cursor < head) {
        const batch_end = consoleBatchEnd(ring, cursor, head);
        std.debug.lockStdErr();
        const progress = writeSpan(raw_fd, ring, cursor, batch_end);
        std.debug.unlockStdErr();
        cursor += progress.bytes;
        if (progress.failure) |failure|
            return .{ .bytes = cursor - tail, .failure = failure };
    }
    return .{ .bytes = head - tail, .failure = null };
}

/// End of the console batch that starts at `cursor`: `head` when the rest
/// fits `console_write_bytes_max`, otherwise just past the last newline
/// within that reach. A record longer than the reach, which the sink accepts
/// but the log drain never encodes, is written across batches.
fn consoleBatchEnd(ring: []const u8, cursor: usize, head: usize) usize {
    std.debug.assert(cursor < head);
    if (head - cursor <= console_write_bytes_max)
        return head;
    const reach = cursor + console_write_bytes_max;
    var end = reach;
    while (end > cursor) : (end -= 1) {
        if (ring[(end - 1) % ring.len] == '\n')
            return end;
    }
    return reach;
}

/// The stream's flusher only: fdatasync, which also persists the file size an
/// append grew.
fn syncFile(target: *Channel, stream: Stream) void {
    const file = switch (target.destination) {
        .file => |file| file,
        .none, .console => return,
    };
    if (!target.unsynced)
        return;
    std.posix.fdatasync(file.fd()) catch |err| {
        target.mutex.lock();
        target.stats.sync_errors +|= 1;
        target.mutex.unlock();
        std.log.warn("analytics {s}: fdatasync failed: {s}", .{ @tagName(stream), @errorName(err) });
        return;
    };
    target.unsynced = false;
    target.mutex.lock();
    target.stats.syncs +|= 1;
    target.mutex.unlock();
}
