//! The shared state page of one worker: a memfd the host creates and maps,
//! and the worker maps read-write at boot. It holds the worker's lifecycle
//! header, one live slot per request in flight, the usage record ring, the
//! completion ring, the console line ring, the boot phase stamps and the
//! first-handler benchmark record.
//!
//! The worker writes the page from its VM thread. Its sentinel thread writes
//! only the lifecycle header, right before it ends the process under memory
//! pressure. Each ring has one producer, the VM thread, and one consumer at a
//! time on the host side. The worker can write any byte of the page at any
//! moment, so every value the host loads from it is hostile input: a host
//! reader loads each field once into a private copy, validates the copy and
//! uses only the copy, and keeps the cursors it owns in its own memory.
//! `snapshots.zig` holds those reads for the header, the live slots and the
//! usage record ring; the completion and console rings keep the same rule in
//! their drains.
//!
//! The sections live under `page/`, one file each: `lifecycle.zig` holds the
//! lifecycle header, `live_slots.zig` the live slots, `usage_records.zig` the
//! usage record ring, `completion_ring.zig` the completion ring,
//! `console_ring.zig` the console line ring, and `boot_stamps.zig` the boot
//! phase stamps and the benchmark record; `snapshots.zig` holds the host's
//! reads, and `mapping.zig` holds the page as a whole, its memfd and the view
//! that maps it. This file re-exports their public declarations, so callers
//! reach all of them through `page`.

const lifecycle = @import("page/lifecycle.zig");
const live_slots = @import("page/live_slots.zig");
const usage_records = @import("page/usage_records.zig");
const completion_ring = @import("page/completion_ring.zig");
const console_ring = @import("page/console_ring.zig");
const boot_stamps = @import("page/boot_stamps.zig");
const snapshots = @import("page/snapshots.zig");
const mapping = @import("page/mapping.zig");

pub const State = lifecycle.State;
pub const TerminationReason = lifecycle.TerminationReason;
pub const Header = lifecycle.Header;

pub const LIVE_SLOT_COUNT = live_slots.LIVE_SLOT_COUNT;
pub const LiveSlotState = live_slots.LiveSlotState;
pub const LiveRequestSlot = live_slots.LiveRequestSlot;
pub const LifecycleIdentity = live_slots.LifecycleIdentity;

pub const RECORD_RING_COUNT = usage_records.RECORD_RING_COUNT;
pub const CompletedStatus = usage_records.CompletedStatus;
pub const CompletedRecord = usage_records.CompletedRecord;
pub const CompletedRecordFlags = usage_records.CompletedRecordFlags;
pub const completedRecordHasFlag = usage_records.completedRecordHasFlag;

pub const COMPLETION_RING_COUNT = completion_ring.COMPLETION_RING_COUNT;
pub const worker_completion_status_max = completion_ring.worker_completion_status_max;
pub const WorkerCompletionRecord = completion_ring.WorkerCompletionRecord;
pub const WorkerCompletionPublish = completion_ring.WorkerCompletionPublish;
pub const WorkerCompletionRingHeader = completion_ring.WorkerCompletionRingHeader;
pub const CompletionDrainError = completion_ring.DrainError;
pub const signalCompletionEventfd = completion_ring.signalCompletionEventfd;
pub const drainCompletionEventfd = completion_ring.drainCompletionEventfd;

pub const LOG_RING_BYTES = console_ring.LOG_RING_BYTES;
pub const LOG_LINE_BYTES_MAX = console_ring.LOG_LINE_BYTES_MAX;
pub const LogLevel = console_ring.LogLevel;
pub const LogLineFlags = console_ring.LogLineFlags;
pub const LogFrameHeader = console_ring.LogFrameHeader;
pub const LogRingHeader = console_ring.LogRingHeader;
pub const DrainedLogLine = console_ring.DrainedLogLine;

pub const BootPhase = boot_stamps.BootPhase;
pub const BOOT_PHASE_COUNT = boot_stamps.BOOT_PHASE_COUNT;
pub const BenchHandlerRecord = boot_stamps.BenchHandlerRecord;

pub const LifecycleSnapshot = snapshots.LifecycleSnapshot;
pub const LiveSlotSnapshot = snapshots.LiveSlotSnapshot;
pub const RecordCursor = snapshots.RecordCursor;

pub const VERSION = mapping.VERSION;
pub const Page = mapping.Page;
pub const HostCursors = mapping.HostCursors;
pub const WorkerWriterView = mapping.WorkerWriterView;
pub const byteSize = mapping.byteSize;
pub const validateInitialized = mapping.validateInitialized;
pub const createMemfd = mapping.createMemfd;
pub const validateMemfd = mapping.validateMemfd;
pub const mapReadWrite = mapping.mapReadWrite;

// Analyzing this file analyzes every section, so each section's layout
// checks run wherever the page is referenced.
comptime {
    _ = lifecycle;
    _ = live_slots;
    _ = usage_records;
    _ = completion_ring;
    _ = console_ring;
    _ = boot_stamps;
    _ = snapshots;
    _ = mapping;
}
