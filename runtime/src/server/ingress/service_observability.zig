//! What the ingress service (`service.zig`) reports about itself: its
//! lanes' counters summed, the traces of the launches that finished, and the
//! records that leave the server through the analytics sink. Two of the
//! service's threads run here: the metrics thread drains usage records and
//! runs the analytics tick (`analytics_drain.zig`) every
//! `metrics_drain_interval_ns`, and the console thread writes console lines
//! to stderr on the same cadence. The lane that answers the health path
//! reads the server's state itself (`healthState` in `runner/admission.zig`).
//!
//! `Methods(Service)` holds what runs on the service itself, and each part
//! has its thread: `metricsThreadMain` and `consoleThreadMain` are the bodies
//! of those two threads, `countersSnapshot` and `takeLaunchTraces` run on
//! any thread, and `finalObservabilityFold` runs on the service's thread (the
//! one in `Service.run`) once every other thread of the service has joined.
//!
//! Invariants:
//! - The analytics drain state (`Service.analytics_drain`) belongs to the
//!   metrics thread; only the final fold, after that thread has joined,
//!   touches it from another.
//! - `takeLaunchTraces` reaches the launcher only under `launcher_mutex`
//!   while `launcher_live` holds, so it never meets a launcher that `run` is
//!   setting up or tearing down.

const std = @import("std");
const supervision = @import("collo_server_supervisor");
const analytics_drain = @import("analytics_drain.zig");
const lane_mod = @import("lane.zig");

const launcher_mod = supervision.launcher;

/// How often the metrics and console threads drain.
const metrics_drain_interval_ns: u64 = 100 * std.time.ns_per_ms;
/// The longest a waiting service thread goes without checking for a stop.
pub const metrics_drain_stop_poll_ns: u64 = 5 * std.time.ns_per_ms;

pub fn Methods(comptime Self: type) type {
    return struct {
        pub fn countersSnapshot(self: *const Self) lane_mod.CounterSnapshot {
            var snapshot = lane_mod.CounterSnapshot{};
            for (self.lanes) |*lane|
                snapshot.add(lane.countersSnapshot());
            return snapshot;
        }

        /// Moves up to `out.len` finished launches into `out`, oldest first
        /// (`Launcher.takeTraces`), and returns how many; 0 while `run` has no
        /// launcher.
        pub fn takeLaunchTraces(self: *Self, out: []launcher_mod.LaunchTrace) usize {
            self.launcher_mutex.lock();
            defer self.launcher_mutex.unlock();
            if (!self.launcher_live)
                return 0;
            return self.launcher.takeTraces(out);
        }

        pub fn metricsThreadMain(self: *Self) void {
            while (!self.shouldStop()) {
                // A full usage stream is written out and offered the batch
                // again, and drops and counts only what a write-out leaves no
                // room for (`usage_drain.zig`), so nothing here is fatal.
                supervision.usage_drain.drainAll(self.supervisor.usageDrain(), self.supervisor.records);
                // Console lines and access records, then the record files are
                // flushed with this tick's usage records too. A loss here is
                // counted by the sink.
                analytics_drain.tick(self);
                sleepUntilStop(self, metrics_drain_interval_ns);
            }
            // No final drain here: at stop-signal time the lanes are still
            // draining and their finishes keep pushing access records, so a
            // drain now would strand that tail with no consumer left.
            // `finalObservabilityFold` (`stopAndDrainForExit`) runs it after every
            // producer joined.
        }

        /// Writes console lines to stderr every tick. Kept off the metrics thread
        /// because stderr blocks for as long as its reader stops reading: a
        /// stalled reader then holds only this thread, while usage, access and
        /// log records keep flowing and console lines past the console buffer are
        /// dropped and counted. The lines left at stop are written when `Server`
        /// closes the sink.
        pub fn consoleThreadMain(self: *Self) void {
            while (!self.shouldStop()) {
                self.analytics.flushConsole();
                sleepUntilStop(self, metrics_drain_interval_ns);
            }
        }

        /// One last drain of usage records and analytics, from the exiting thread
        /// after the lanes, the launcher, the reaper and the metrics and console
        /// threads have all joined. Nothing else runs then, which keeps the
        /// metrics thread's ownership of the drain state, and only then is every
        /// ring complete. Worker teardown in `Supervisor.deinit` still appends
        /// after this, and `Server`'s close of the sink writes that last tail,
        /// console lines included.
        pub fn finalObservabilityFold(self: *Self) void {
            self.supervisor.drainAllWorkerUsage();
            analytics_drain.drainFinal(self);
        }

        fn sleepUntilStop(self: *Self, duration_ns: u64) void {
            var slept: u64 = 0;
            while (slept < duration_ns and !self.shouldStop()) {
                const chunk = @min(metrics_drain_stop_poll_ns, duration_ns - slept);
                std.Thread.sleep(chunk);
                slept += chunk;
            }
        }
    };
}
