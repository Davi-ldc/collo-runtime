//! The shared state page of one worker: a memfd the host creates and maps,
//! and the worker maps read-write at boot. It holds the worker's lifecycle
//! header with its owner section, one live slot per pool slot, the console
//! line ring, the boot phase stamps and the first-handler benchmark record.
//! A request's completion and measures never ride the page: they travel as
//! its `request_done` on the worker's control socket
//! (`common/ipc/ingress_channel/framing.zig`).
//!
//! The worker writes the page from its VM thread through its
//! `WorkerWriterView`. Its sentinel thread writes the lifecycle header only
//! for the running owner's CPU, and the state and reason right before it
//! ends the process. The console ring takes lines from any of the worker's
//! threads, the runtime's `std.log` lines included (`zygote/log_sink.zig`),
//! which serialize on its lock (`console_ring.zig`), and has one consumer at
//! a time on the host side. The worker can write any byte of the page at any
//! moment, so every value the host loads from it is hostile input: the host
//! maps the page as a `HostReaderView`, whose every read loads each field
//! once into a private copy that the caller validates and uses alone, and
//! which keeps the cursor the host owns in host memory.
//!
//! The sections live under `page/`, one file each: `lifecycle.zig` holds the
//! lifecycle header, `live_slots.zig` the live slots, `console_ring.zig` the
//! console line ring, and `boot_stamps.zig` the boot phase stamps and the
//! benchmark record; `snapshots.zig` holds the host's copies of the header
//! and the live slots, and `mapping.zig` holds the page as a whole, its
//! memfd and the two views that map it. This file re-exports their public
//! declarations, so callers reach all of them through `page`.

const lifecycle = @import("page/lifecycle.zig");
const live_slots = @import("page/live_slots.zig");
const console_ring = @import("page/console_ring.zig");
const boot_stamps = @import("page/boot_stamps.zig");
const snapshots = @import("page/snapshots.zig");
const mapping = @import("page/mapping.zig");

pub const State = lifecycle.State;
pub const TerminationReason = lifecycle.TerminationReason;
pub const Header = lifecycle.Header;

pub const LIVE_SLOT_COUNT = live_slots.LIVE_SLOT_COUNT;
pub const live_slot_count_page_zero_max = live_slots.live_slot_count_page_zero_max;
pub const LiveRequestSlot = live_slots.LiveRequestSlot;

pub const LOG_RING_BYTES = console_ring.LOG_RING_BYTES;
pub const LOG_LINE_BYTES_MAX = console_ring.LOG_LINE_BYTES_MAX;
pub const LogLevel = console_ring.LogLevel;
pub const LogLineFlags = console_ring.LogLineFlags;
pub const LogFrameHeader = console_ring.LogFrameHeader;
pub const LogRingHeader = console_ring.LogRingHeader;
pub const DrainedLogLine = console_ring.DrainedLogLine;
/// The lock every console-ring producer of this process takes
/// (`console_ring.zig:producer_mutex`).
pub const log_producer_mutex = &console_ring.producer_mutex;

pub const BootPhase = boot_stamps.BootPhase;
pub const BOOT_PHASE_COUNT = boot_stamps.BOOT_PHASE_COUNT;
pub const BenchHandlerRecord = boot_stamps.BenchHandlerRecord;

pub const LifecycleSnapshot = snapshots.LifecycleSnapshot;
pub const OwnerSnapshot = snapshots.OwnerSnapshot;
pub const RunningOwnerSnapshot = snapshots.RunningOwnerSnapshot;
pub const LiveSlotSnapshot = snapshots.LiveSlotSnapshot;

pub const VERSION = mapping.VERSION;
pub const Page = mapping.Page;
pub const HostCursors = mapping.HostCursors;
pub const HostReaderView = mapping.HostReaderView;
pub const WorkerWriterView = mapping.WorkerWriterView;
pub const byteSize = mapping.byteSize;
pub const validateInitialized = mapping.validateInitialized;
pub const createMemfd = mapping.createMemfd;
pub const validateMemfd = mapping.validateMemfd;
pub const mapHostReader = mapping.mapHostReader;
pub const mapWorkerWriter = mapping.mapWorkerWriter;

// Analyzing this file analyzes every section, so each section's layout
// checks run wherever the page is referenced.
comptime {
    _ = lifecycle;
    _ = live_slots;
    _ = console_ring;
    _ = boot_stamps;
    _ = snapshots;
    _ = mapping;
}
