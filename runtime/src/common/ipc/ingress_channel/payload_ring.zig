//! The shared payload memfd of one worker: a header and one byte ring per
//! `SharedPayloadDirection`, so large bodies never pass through a socket.
//! The host creates it at launch, the worker receives it in WorkerInit, and
//! both map it read-write. The host writes request body chunks into
//! `server_to_worker` and the worker writes response chunks into
//! `worker_to_server`; each ring has one writer at a time and one reader, and
//! no other operation may use a ring. A ring payload is contiguous: one that
//! does not fit before the end of the ring skips the tail and starts at
//! offset 0, and the skipped bytes stay reserved until the reader releases
//! that payload. The server uses a view on its ingress lanes' threads and the
//! worker on its event loop thread.
//!
//! Each ring's two cursors live in the memfd, where either process can
//! rewrite both. A view therefore knows its side (`SharedPayloadSide`) and
//! keeps privately the cursor that side owns in each ring
//! (`SharedPayloadView.own_cursors`): the write cursor of the ring it writes
//! and the read cursor of the ring it reads. It moves its own cursor there,
//! stores it to the memfd with release ordering for the peer and never loads
//! it back. An operation that needs the peer's cursor loads it once, with
//! acquire ordering, and fails with `error.InvalidIngressSharedPayloadRing`
//! when it contradicts the view's own: a reader past the writer, or more
//! bytes in flight than the ring holds. The server counts that error as the
//! worker's fault. Writing and cancelling a write belong to the side that
//! writes a direction, reading and releasing to the side that reads it, and
//! each of them asserts its side.
//!
//! Own cursors start at zero, so a map refuses a memfd whose cursors moved;
//! the host maps the memfd at launch and the worker at boot, before either
//! side writes. Once a view has moved a cursor, its side reaches it only by
//! pointer: a copy would keep cursors of its own and publish positions that
//! contradict the original's. A borrowed payload stays in the ring, where the
//! writer can still rewrite it. After each release the reader signals the
//! credit eventfd it was given, if any (`SharedPayloadReadRelease`).

const std = @import("std");
const fd_mod = @import("collo_os").fd;

/// The send functions put a chunk payload larger than this in the ring and
/// one at or below it inline, except where a function says otherwise.
pub const shared_payload_threshold: usize = 32 * 1024;
/// Bytes per ring, and so the largest payload one descriptor can put there.
pub const shared_payload_ring_capacity: usize = 1024 * 1024;
/// One ring per `SharedPayloadDirection`.
pub const shared_payload_ring_count: usize = 2;
/// Written into the memfd's header at creation and checked when it is mapped.
pub const shared_payload_version: u32 = 1;

/// A ring's index in the memfd. `server` names the host side, whichever
/// process drives the worker.
pub const SharedPayloadDirection = enum(u32) {
    server_to_worker = 0,
    worker_to_server = 1,
};

/// The process a view belongs to. Each side writes the ring of one direction
/// and reads the other.
pub const SharedPayloadSide = enum {
    server,
    worker,

    /// The direction whose ring this side writes.
    pub fn writes(self: SharedPayloadSide) SharedPayloadDirection {
        return switch (self) {
            .server => .server_to_worker,
            .worker => .worker_to_server,
        };
    }
};

/// One ring's cursors. Both count bytes since creation; the writer advances
/// `write_cursor` and the reader advances `read_cursor`, each storing its own
/// with release ordering and loading the other's with acquire ordering.
pub const SharedPayloadRingHeader = extern struct {
    read_cursor: u64,
    write_cursor: u64,
    capacity: u32,
    _reserved0: u32 = 0,
    _reserved1: [2]u64 = .{ 0, 0 },
};

/// The start of the payload memfd. `version`, `ring_count` and every ring's
/// `capacity` are written at creation and checked on map; the ring data
/// follows from `shared_payload_data_offset`, one ring after another in
/// `SharedPayloadDirection` order.
pub const SharedPayloadHeader = extern struct {
    version: u32,
    ring_count: u32,
    _reserved0: [2]u64 = .{ 0, 0 },
    rings: [shared_payload_ring_count]SharedPayloadRingHeader,
};

pub const shared_payload_data_offset: usize = @sizeOf(SharedPayloadHeader);
pub const shared_payload_byte_size: usize = shared_payload_data_offset + shared_payload_ring_capacity * shared_payload_ring_count;

/// The ring of one direction with the eventfd its reader signals after each
/// release, -1 for none. The send functions take one as the writer's side,
/// and `SharedPayloadReaders.forDescriptor` returns one as the reader's.
pub const SharedPayloadWriter = struct {
    view: *SharedPayloadView,
    direction: SharedPayloadDirection,
    credit_eventfd: std.posix.fd_t = -1,
};

/// Where a written payload starts in its ring and how many ring bytes it
/// took, including a skipped tail.
pub const SharedPayloadWriteReservation = struct {
    offset: u64 = 0,
    reserved_len: usize = 0,
};

const SharedPayloadBorrow = struct {
    bytes: []u8 = &.{},
    reserved_len: u64 = 0,
};

const SharedPayloadReadReservation = struct {
    payload_len: usize = 0,
    reserved_len: u64 = 0,
};

/// One ring's two cursors as a side sees them in one operation, already
/// checked against each other (`SharedPayloadView.loadCursors`).
const Cursors = struct {
    read: u64,
    write: u64,

    fn used(self: Cursors) usize {
        return @intCast(self.write - self.read);
    }
};

/// Ring bytes a reader still holds. `release` advances the ring's read
/// cursor past them and signals the credit eventfd; the default value holds
/// nothing.
pub const SharedPayloadReadRelease = struct {
    view: ?*SharedPayloadView = null,
    direction: SharedPayloadDirection = .server_to_worker,
    byte_len: u64 = 0,
    credit_eventfd: std.posix.fd_t = -1,

    pub fn release(self: *SharedPayloadReadRelease) void {
        const view = self.view orelse return;
        if (self.byte_len != 0) {
            view.releaseRead(self.direction, self.byte_len);
            notifyEventFd(self.credit_eventfd);
        }
        self.* = .{};
    }
};

/// One side's mapping of the payload memfd, both rings writable.
pub const SharedPayloadView = struct {
    bytes: []align(std.heap.page_size_min) u8,
    header: *SharedPayloadHeader,
    side: SharedPayloadSide,
    /// The cursor this side owns in each ring, by `SharedPayloadDirection`:
    /// the write cursor of the ring it writes and the read cursor of the ring
    /// it reads. Only this view moves them. On the server the lanes write
    /// `server_to_worker` under `Record.send_mutex`
    /// (`server/supervisor/worker_table.zig`) and the worker's one reader
    /// lane reads `worker_to_server`, both through the record's copy of the
    /// view; in the worker its event loop thread does both.
    own_cursors: [shared_payload_ring_count]u64 = @splat(0),

    pub fn deinit(self: *SharedPayloadView) void {
        if (self.bytes.len != 0)
            std.posix.munmap(self.bytes);
        self.* = undefined;
    }

    pub fn writer(self: *SharedPayloadView, direction: SharedPayloadDirection) SharedPayloadWriter {
        return .{ .view = self, .direction = direction };
    }

    /// Copies `payload` into the ring of `direction`, which this side writes,
    /// and publishes it, before any descriptor names it; an empty payload
    /// takes nothing. A payload never splits, so one larger than half the
    /// ring can be refused even by an empty ring, depending on where the write
    /// position stands. Fails with `error.IngressSharedPayloadTooLarge` above
    /// `shared_payload_ring_capacity`, `error.IngressSharedPayloadRingFull`
    /// when the reader has not freed enough, and
    /// `error.InvalidIngressSharedPayloadRing` when the reader's cursor
    /// contradicts this side's own.
    pub fn write(self: *SharedPayloadView, direction: SharedPayloadDirection, payload: []const u8) !SharedPayloadWriteReservation {
        std.debug.assert(direction == self.side.writes());
        if (payload.len == 0)
            return .{};
        if (payload.len > shared_payload_ring_capacity)
            return error.IngressSharedPayloadTooLarge;
        const cursors = try self.loadCursors(direction);
        const free = shared_payload_ring_capacity - cursors.used();
        const offset: usize = @intCast(cursors.write % shared_payload_ring_capacity);
        const tail_len = shared_payload_ring_capacity - offset;
        if (payload.len <= tail_len) {
            if (payload.len > free)
                return error.IngressSharedPayloadRingFull;
            self.copyIntoRing(direction, offset, payload);
            self.moveOwnCursor(direction, cursors.write + @as(u64, @intCast(payload.len)));
            return .{
                .offset = @intCast(offset),
                .reserved_len = payload.len,
            };
        }

        const reserved_len = std.math.add(usize, tail_len, payload.len) catch return error.MessageTooLarge;
        if (reserved_len > free)
            return error.IngressSharedPayloadRingFull;

        self.copyIntoRing(direction, 0, payload);
        self.moveOwnCursor(direction, cursors.write + @as(u64, @intCast(reserved_len)));
        return .{
            .offset = 0,
            .reserved_len = reserved_len,
        };
    }

    /// Free bytes in the ring of `direction`, either one: this side's own
    /// cursor against the peer's, loaded once. A payload that must skip the
    /// tail needs the tail's bytes on top of its own.
    pub fn availableCapacity(self: *SharedPayloadView, direction: SharedPayloadDirection) !usize {
        const cursors = try self.loadCursors(direction);
        return shared_payload_ring_capacity - cursors.used();
    }

    /// Takes back the last `len` ring bytes this side wrote in `direction`,
    /// for payloads whose descriptors were never sent, before its next write.
    pub fn cancelLastWrite(self: *SharedPayloadView, direction: SharedPayloadDirection, len: usize) void {
        std.debug.assert(direction == self.side.writes());
        if (len == 0)
            return;
        const write_cursor = self.own_cursors[@intFromEnum(direction)];
        const rewind_by: u64 = @intCast(len);
        // The bytes were written by this side since its last send, so its own
        // cursor stands at least that far along.
        std.debug.assert(rewind_by <= write_cursor);
        self.moveOwnCursor(direction, write_cursor - rewind_by);
    }

    /// The `len` bytes at `offset` in the ring of `direction`, for a consumer
    /// handed a payload that the ring's reader decoded and holds for it
    /// (`SharedPayloadHolds`). The reader checked the payload's position, so
    /// only the ring's bounds are checked here; bytes past the end of the ring
    /// fail with `error.InvalidIngressSharedPayloadRing`. The worker can still
    /// rewrite them, so the consumer copies them once.
    pub fn heldPayload(self: *SharedPayloadView, direction: SharedPayloadDirection, offset: u64, len: u32) ![]u8 {
        if (offset >= shared_payload_ring_capacity)
            return error.InvalidIngressSharedPayloadRing;
        const offset_usize: usize = @intCast(offset);
        if (len > shared_payload_ring_capacity - offset_usize)
            return error.InvalidIngressSharedPayloadRing;
        return self.ringBytes(direction)[offset_usize..][0..len];
    }

    /// This side's read cursor of the ring of `direction`, which it reads.
    pub fn readCursor(self: *const SharedPayloadView, direction: SharedPayloadDirection) u64 {
        std.debug.assert(direction != self.side.writes());
        return self.own_cursors[@intFromEnum(direction)];
    }

    pub fn readBorrowAt(
        self: *SharedPayloadView,
        direction: SharedPayloadDirection,
        cursor: u64,
        offset: u64,
        len: u32,
    ) !SharedPayloadBorrow {
        const reservation = try self.validateReadAt(direction, cursor, offset, len);
        if (reservation.payload_len == 0)
            return .{ .reserved_len = reservation.reserved_len };
        const offset_usize: usize = @intCast(offset);
        return .{
            .bytes = self.ringBytes(direction)[offset_usize..][0..reservation.payload_len],
            .reserved_len = reservation.reserved_len,
        };
    }

    /// Checks that a payload of `len` bytes at `offset` sits where the writer
    /// must have put it after the ring position `cursor`: at that position's
    /// offset, or at 0 when the writer skipped the tail. The writer's cursor
    /// is loaded once and must stand at or past the payload's end. Returns
    /// the payload's length and the ring bytes releasing it frees.
    fn validateReadAt(
        self: *SharedPayloadView,
        direction: SharedPayloadDirection,
        cursor: u64,
        offset: u64,
        len: u32,
    ) !SharedPayloadReadReservation {
        std.debug.assert(direction != self.side.writes());
        const len_usize: usize = @intCast(len);
        if (len_usize == 0)
            return .{};
        if (len_usize > shared_payload_ring_capacity)
            return error.IngressSharedPayloadTooLarge;
        if (offset >= shared_payload_ring_capacity)
            return error.InvalidIngressSharedPayloadRing;
        const offset_usize: usize = @intCast(offset);
        if (len_usize > shared_payload_ring_capacity - offset_usize)
            return error.InvalidIngressSharedPayloadRing;

        const cursors = try self.loadCursors(direction);
        const read_cursor = cursors.read;
        const write_cursor = cursors.write;
        if (cursor < read_cursor or write_cursor < cursor)
            return error.InvalidIngressSharedPayloadRing;
        const expected_offset = cursor % shared_payload_ring_capacity;
        const reserved_len = if (offset == @as(u64, @intCast(expected_offset)))
            @as(u64, @intCast(len_usize))
        else blk: {
            if (offset != 0)
                return error.InvalidIngressSharedPayloadRing;
            if (expected_offset == 0)
                return error.InvalidIngressSharedPayloadRing;
            const padding_len = shared_payload_ring_capacity - expected_offset;
            break :blk std.math.add(
                u64,
                @intCast(padding_len),
                @intCast(len_usize),
            ) catch return error.InvalidIngressSharedPayloadRing;
        };
        const available = write_cursor - cursor;
        if (available < reserved_len)
            return error.ShortRead;
        return .{
            .payload_len = len_usize,
            .reserved_len = reserved_len,
        };
    }

    /// Moves this side's read cursor of `direction` past `len` bytes it
    /// decoded. The bytes lie between the read cursor and a writer's cursor
    /// a decode loaded and checked (`validateReadAt`), so the release loads
    /// nothing and needs no check against the peer.
    fn releaseRead(self: *SharedPayloadView, direction: SharedPayloadDirection, len: u64) void {
        std.debug.assert(direction != self.side.writes());
        std.debug.assert(len <= shared_payload_ring_capacity);
        if (len == 0)
            return;
        self.moveOwnCursor(direction, self.own_cursors[@intFromEnum(direction)] + len);
    }

    /// The ring's cursors as this side sees them: its own, and the peer's
    /// loaded once with acquire ordering. A peer cursor that puts the reader
    /// past the writer, or more bytes in flight than the ring holds, fails
    /// with `error.InvalidIngressSharedPayloadRing`.
    fn loadCursors(self: *SharedPayloadView, direction: SharedPayloadDirection) error{InvalidIngressSharedPayloadRing}!Cursors {
        const ring = self.ringHeader(direction);
        const own = self.own_cursors[@intFromEnum(direction)];
        const cursors: Cursors = if (direction == self.side.writes())
            .{ .read = @atomicLoad(u64, &ring.read_cursor, .acquire), .write = own }
        else
            .{ .read = own, .write = @atomicLoad(u64, &ring.write_cursor, .acquire) };
        if (cursors.read > cursors.write)
            return error.InvalidIngressSharedPayloadRing;
        if (cursors.write - cursors.read > shared_payload_ring_capacity)
            return error.InvalidIngressSharedPayloadRing;
        return cursors;
    }

    /// Sets this side's own cursor of `direction` and stores it to the
    /// memfd for the peer, which loads it with acquire ordering.
    fn moveOwnCursor(self: *SharedPayloadView, direction: SharedPayloadDirection, cursor: u64) void {
        self.own_cursors[@intFromEnum(direction)] = cursor;
        const ring = self.ringHeader(direction);
        if (direction == self.side.writes()) {
            @atomicStore(u64, &ring.write_cursor, cursor, .release);
        } else {
            @atomicStore(u64, &ring.read_cursor, cursor, .release);
        }
    }

    fn ringHeader(self: *SharedPayloadView, direction: SharedPayloadDirection) *SharedPayloadRingHeader {
        return &self.header.rings[@intFromEnum(direction)];
    }

    fn ringBytes(self: *SharedPayloadView, direction: SharedPayloadDirection) []u8 {
        const index: usize = @intFromEnum(direction);
        const start = shared_payload_data_offset + shared_payload_ring_capacity * index;
        return self.bytes[start..][0..shared_payload_ring_capacity];
    }

    fn copyIntoRing(self: *SharedPayloadView, direction: SharedPayloadDirection, offset: usize, payload: []const u8) void {
        const ring = self.ringBytes(direction);
        std.debug.assert(offset <= ring.len);
        std.debug.assert(payload.len <= ring.len - offset);
        @memcpy(ring[offset..][0..payload.len], payload);
    }
};

/// Signals the credit eventfd `fd`, or does nothing when `fd` is -1. A
/// counter too full to take it is already readable, so `error.WouldBlock` is
/// ignored; other failures are logged.
pub fn notifyEventFd(fd: std.posix.fd_t) void {
    if (fd < 0)
        return;
    var one: u64 = 1;
    _ = std.posix.write(fd, std.mem.asBytes(&one)) catch |err| switch (err) {
        error.WouldBlock => return,
        else => |unexpected| {
            std.log.warn("ingress shared payload credit notify failed: {s}", .{
                @errorName(unexpected),
            });
            return;
        },
    };
}

/// Creates the payload memfd for one worker with both rings empty, its header
/// written, size-sealed and close-on-exec; the caller owns the descriptor.
pub fn createSharedPayloadMemfd() !std.posix.fd_t {
    const fd = try std.posix.memfd_create(
        "collo-ingress-payload-ring",
        std.os.linux.MFD.CLOEXEC | std.os.linux.MFD.ALLOW_SEALING,
    );
    errdefer std.posix.close(fd);
    try std.posix.ftruncate(fd, shared_payload_byte_size);

    var header = std.mem.zeroes(SharedPayloadHeader);
    header.version = shared_payload_version;
    header.ring_count = shared_payload_ring_count;
    for (&header.rings) |*ring|
        ring.capacity = shared_payload_ring_capacity;
    const written = try std.posix.pwrite(fd, std.mem.asBytes(&header), 0);
    if (written != @sizeOf(SharedPayloadHeader))
        return error.ShortWrite;
    try fd_mod.addSeals(fd, fd_mod.memfd_size_seals);
    return fd;
}

/// Maps the payload memfd `fd` for `side`, shared and writable, after
/// checking its size seals, size and header. Both rings must still be
/// empty, as `createSharedPayloadMemfd` left them, since the view starts its
/// own cursors there: the host maps the memfd at launch and the worker at
/// boot, before either side writes. `fd` stays the caller's and may be closed
/// once mapped; the view is unmapped by `deinit`. A wrong size, header or
/// cursor fails with `error.InvalidIngressSharedPayloadRing`.
pub fn mapSharedPayloadReadWrite(fd: std.posix.fd_t, side: SharedPayloadSide) !SharedPayloadView {
    try fd_mod.requireSeals(fd, fd_mod.memfd_size_seals);
    const stat = try std.posix.fstat(fd);
    const len: usize = @intCast(stat.size);
    if (len != shared_payload_byte_size)
        return error.InvalidIngressSharedPayloadRing;
    const bytes = try std.posix.mmap(
        null,
        len,
        std.posix.PROT.READ | std.posix.PROT.WRITE,
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    errdefer std.posix.munmap(bytes);
    const header: *SharedPayloadHeader = @ptrCast(@alignCast(bytes.ptr));
    try validateSharedPayloadHeader(header);
    return .{ .bytes = bytes, .header = header, .side = side };
}

fn validateSharedPayloadHeader(header: *const SharedPayloadHeader) !void {
    if (header.version != shared_payload_version or header.ring_count != shared_payload_ring_count)
        return error.InvalidIngressSharedPayloadRing;
    for (&header.rings) |*ring| {
        if (ring.capacity != shared_payload_ring_capacity)
            return error.InvalidIngressSharedPayloadRing;
        if (@atomicLoad(u64, &ring.read_cursor, .acquire) != 0)
            return error.InvalidIngressSharedPayloadRing;
        if (@atomicLoad(u64, &ring.write_cursor, .acquire) != 0)
            return error.InvalidIngressSharedPayloadRing;
    }
}
