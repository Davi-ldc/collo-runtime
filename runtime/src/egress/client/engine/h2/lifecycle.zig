//! Stateless helpers for the HTTP/2 side of the owner loop: pool entry
//! removal, pending lookups and best-effort cleanup.
//!
//! Every removal here goes through the data driver, so a connection whose
//! io_uring cancel the kernel has not confirmed stays owned by the driver
//! instead of being freed under in-flight kernel operations. The
//! best-effort helpers run on paths that are already failing or abandoning
//! the fetch, so they log and continue.

const std = @import("std");
const bindings = @import("collo_bindings");
const core = @import("collo_egress_core");
const data_io = @import("collo_egress_data_io");
const http2 = @import("collo_egress_http2");
const pool_mod = @import("collo_egress_pool");

const body_credit = core.body_credit;

pub fn Methods(comptime H2Pending: type) type {
    return struct {
        pub fn removeH2Entry(
            pool: *pool_mod.Pool,
            data_driver: *data_io.Driver,
            entry: *pool_mod.Entry,
        ) void {
            pool.removeEntryWithDriver(entry, data_driver);
        }

        pub fn removeH2EntryIfIdle(
            pool: *pool_mod.Pool,
            data_driver: *data_io.Driver,
            entry: *pool_mod.Entry,
        ) void {
            if (!entry.isIdle())
                return;
            removeH2Entry(pool, data_driver, entry);
        }

        pub fn removeH2EntryIfClosingAndIdle(
            pool: *pool_mod.Pool,
            data_driver: *data_io.Driver,
            entry: *pool_mod.Entry,
        ) bool {
            if (!entry.h2.closing or entry.h2.hasActiveStreams() or entry.hasOutgoing())
                return false;
            removeH2Entry(pool, data_driver, entry);
            return true;
        }

        pub fn removeH2EntryIfLifecycleExpired(
            pool: *pool_mod.Pool,
            data_driver: *data_io.Driver,
            entry: *pool_mod.Entry,
            now_ns: u64,
        ) bool {
            if (!entry.isIdle())
                return false;
            if (!entry.h2.closing and pool.entryLifecycleDeadlineNs(entry) > now_ns)
                return false;
            removeH2Entry(pool, data_driver, entry);
            return true;
        }

        pub fn evictExpiredH2Entries(
            pool: *pool_mod.Pool,
            data_driver: *data_io.Driver,
            now_ns: u64,
        ) void {
            var index: usize = 0;
            while (index < pool.entries.items.len) {
                const entry = pool.entries.items[index];
                if (removeH2EntryIfLifecycleExpired(pool, data_driver, entry, now_ns)) {
                    continue;
                }
                index += 1;
            }
        }

        pub fn findH2PendingIndex(
            pending: []const H2Pending,
            entry: *pool_mod.Entry,
            stream_id: u32,
        ) ?usize {
            for (pending, 0..) |item, index| {
                if (item.stream.entry == entry and item.stream.stream_id == stream_id)
                    return index;
            }
            return null;
        }

        pub fn findH2PendingIndexByBodyCredit(
            pending: []const H2Pending,
            credit: body_credit.H2Data,
        ) ?usize {
            return findH2PendingIndexByH2Identity(pending, credit.source_id, credit.stream_id);
        }

        pub fn findH2PendingIndexByH2Identity(
            pending: []const H2Pending,
            source_id: u64,
            stream_id: u32,
        ) ?usize {
            for (pending, 0..) |item, index| {
                if (item.credit_source_id == source_id and item.stream.stream_id == stream_id)
                    return index;
            }
            return null;
        }

        pub fn findH2PendingIndexByBodyIdentity(
            pending: []const H2Pending,
            identity: bindings.FetchBodyIdentity,
        ) ?usize {
            for (pending, 0..) |item, index| {
                if (item.body.identity.request_id == identity.request_id and
                    item.body.identity.request_generation == identity.request_generation and
                    item.body.identity.fetch_id == identity.fetch_id and
                    item.body.identity.body_id == identity.body_id)
                {
                    return index;
                }
            }
            return null;
        }

        pub fn drainH2Wake(fd: std.posix.fd_t) void {
            while (true) {
                var counter: u64 = 0;
                _ = std.posix.read(fd, std.mem.asBytes(&counter)) catch |err| switch (err) {
                    error.WouldBlock => return,
                    else => |unexpected| {
                        std.log.debug(
                            "failed to drain HTTP/2 egress wake fd: {s}",
                            .{@errorName(unexpected)},
                        );
                        return;
                    },
                };
            }
        }

        pub fn cancelH2StreamBestEffort(
            pool: *pool_mod.Pool,
            stream: pool_mod.StreamHandle,
            context: []const u8,
        ) void {
            pool.cancelStream(stream) catch |err|
                std.log.debug(
                    "HTTP/2 egress stream cancel failed in {s}: {s}",
                    .{ context, @errorName(err) },
                );
        }

        pub fn ackH2DataBestEffort(
            pool: *pool_mod.Pool,
            entry: *pool_mod.Entry,
            stream_id: u32,
            encoded_bytes: usize,
            update_stream_window: bool,
            context: []const u8,
        ) void {
            _ = pool.ackReceivedData(entry, stream_id, encoded_bytes, update_stream_window) catch |err|
                std.log.debug(
                    "HTTP/2 egress flow-credit ack failed in {s}: {s}",
                    .{ context, @errorName(err) },
                );
        }

        pub fn failFetchBodyBestEffort(
            body: anytype,
            allocator: std.mem.Allocator,
            message: []const u8,
            context: []const u8,
        ) void {
            _ = body.fail(allocator, message) catch |err| {
                std.log.debug(
                    "egress fetch body failure publication failed in {s}: {s}",
                    .{ context, @errorName(err) },
                );
                _ = body.failNoAlloc();
            };
        }

        pub fn h2LimitsEqual(a: http2.Limits, b: http2.Limits) bool {
            return a.max_active_streams == b.max_active_streams and
                a.stream_receive_window == b.stream_receive_window and
                a.connection_receive_window == b.connection_receive_window and
                a.receive_window_update_threshold == b.receive_window_update_threshold and
                a.max_pending_body_credit_per_stream == b.max_pending_body_credit_per_stream and
                a.max_pending_body_credit_per_connection == b.max_pending_body_credit_per_connection;
        }
    };
}
