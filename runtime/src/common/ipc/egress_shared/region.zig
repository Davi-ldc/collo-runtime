//! What every region of an egress session shares, the two packet rings and
//! the two pools alike. A region is four size-sealed memfds: the meta, the
//! producer state, the consumer state and the data. The server writes the
//! meta's `magic`, `version`, `role` and `capacity` when it creates the
//! region, the gateway stamps the session into it, and the worker maps it
//! read-only. A side that finds a fault records a `FatalState` in the state
//! it writes. `Usage` is a region's occupancy against its capacity, which a
//! producer reads for backpressure.

const std = @import("std");

/// Written into every meta at creation with `version` and checked when the
/// meta is mapped, so a descriptor of another kind fails the map.
pub const magic: u32 = 0x45475231; // "EGR1" in ASCII, most significant byte first.
pub const version: u32 = 1;

/// The region a meta describes, checked when the meta is mapped.
pub const Role = enum(u32) {
    command = 1,
    completion = 2,
    body_pool = 3,
    /// The body pool's mirror for request bodies, written by the worker and
    /// read and released by the gateway. Both pools share one geometry and
    /// one pair of state structs, with producer and consumer swapped.
    upload_pool = 4,
};

/// Why a region stopped, recorded by the side that found the fault in the
/// state it writes. Once either side records one, ring writes and reads, pool
/// reservations and release drains fail with `error.EgressSharedRingFatal`.
pub const FatalState = enum(u32) {
    none = 0,
    ring_corrupt = 1,
    writer_overflow = 2,
    reader_closed = 3,
};

/// The meta memfd. The server writes `magic`, `version`, `role` and
/// `capacity` at creation, the gateway stamps the session (`setSession`), and
/// the worker only reads it.
pub const RingMeta = extern struct {
    magic: u32,
    version: u32,
    role: u32,
    capacity: u32,
    worker_session_id: u64 = 0,
    generation: u64 = 0,
    _reserved0: [4]u64 = .{ 0, 0, 0, 0 },
};

comptime {
    std.debug.assert(@sizeOf(RingMeta) == 64);
    std.debug.assert(@offsetOf(RingMeta, "magic") == 0);
    std.debug.assert(@offsetOf(RingMeta, "version") == 4);
    std.debug.assert(@offsetOf(RingMeta, "role") == 8);
    std.debug.assert(@offsetOf(RingMeta, "capacity") == 12);
    std.debug.assert(@offsetOf(RingMeta, "worker_session_id") == 16);
    std.debug.assert(@offsetOf(RingMeta, "generation") == 24);
    std.debug.assert(@offsetOf(RingMeta, "_reserved0") == 32);
}

pub const Usage = struct {
    used: usize,
    capacity: usize,

    pub fn atLeastPercent(self: Usage, percent: u8) bool {
        std.debug.assert(percent <= 100);
        if (self.capacity == 0)
            return false;
        return self.used * 100 >= self.capacity * @as(usize, percent);
    }
};
