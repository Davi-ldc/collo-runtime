//! The supervisor's small parts on their own: the usage keys that keep a
//! request attempt from being recorded twice, the smaps parser behind the
//! reaper's victim score, the diagnostics flags the launcher puts in every
//! worker's boot options, and the cap on boot-window faults the host launch
//! serves per drain. The supervisor that composes them is covered in
//! `supervisor.zig`, `usage.zig` and `reaper/`, and the launcher in
//! `launcher.zig`. Lane `server-supervisor-test`.

const std = @import("std");

const ipc = @import("collo_ipc");
const lifecycle = @import("collo_server_lifecycle");
const supervision = @import("collo_server_supervisor");
const worker_shared_page = @import("collo_worker_state").page;
const zygote = @import("collo_zygote");
const host = @import("collo_host");

test "usage identity ignores reused external ids with different lifecycle keys" {
    const identity = worker_shared_page.LifecycleIdentity{
        .external_request_id = 7,
        .request_lane_id = 1,
        .request_slot = 2,
        .request_generation = 3,
        .worker_id = 4,
        .worker_generation = 5,
    };
    const worker_key = lifecycle.WorkerKey{ .worker_id = 4, .worker_generation = 5 };
    var record = std.mem.zeroInit(worker_shared_page.CompletedRecord, .{
        .request_id = 7,
        .request_lane_id = 1,
        .request_slot = 2,
        .request_generation = 3,
    });
    try std.testing.expect(supervision.accounting.usage.recordMatchesLifecycle(record, worker_key, identity));
    record.request_generation = 9;
    try std.testing.expect(!supervision.accounting.usage.recordMatchesLifecycle(record, worker_key, identity));
}

test "a record matches only the attempts of the worker whose ring held it" {
    const identity = worker_shared_page.LifecycleIdentity{
        .external_request_id = 7,
        .request_lane_id = 1,
        .request_slot = 2,
        .request_generation = 3,
        .worker_id = 4,
        .worker_generation = 5,
    };
    // The record names the identity's worker, but another worker's ring held
    // it; the key comes from the ring, never from the record.
    const record = std.mem.zeroInit(worker_shared_page.CompletedRecord, .{
        .request_id = 7,
        .request_lane_id = 1,
        .request_slot = 2,
        .request_generation = 3,
        .worker_id = 4,
        .worker_generation = 5,
    });
    const other_worker = lifecycle.WorkerKey{ .worker_id = 8, .worker_generation = 1 };
    try std.testing.expect(!supervision.accounting.usage.recordMatchesLifecycle(record, other_worker, identity));
    const key = supervision.accounting.usage.keyFromRecord(record, other_worker);
    try std.testing.expect(key.worker_key.eql(other_worker));
}

test "worker reaper parses private rss from smaps rollup" {
    const bytes =
        \\Rss:                4096 kB
        \\Pss:                2048 kB
        \\Private_Clean:       512 kB
        \\Private_Dirty:      1536 kB
        \\Private_Hugetlb:       4 kB
        \\Swap:                  0 kB
        \\
    ;
    try std.testing.expectEqual(
        @as(u64, (512 + 1536 + 4) * 1024),
        try supervision.reaper.memory.parseSmapsRollupPrivateRssBytes(bytes),
    );
}

test "worker reaper rejects smaps rollup without private rss fields" {
    try std.testing.expectError(
        error.SmapsRollupMissingPrivateRss,
        supervision.reaper.memory.parseSmapsRollupPrivateRssBytes("Rss: 10 kB\n"),
    );
}

test "worker launch trace flags follow explicit diagnostics flags" {
    const trace_flags = supervision.launcher.resolveTraceRuntimeFlags(true, true);
    try std.testing.expect((trace_flags & ipc.WorkerRuntimeBootOptions.flag_trace_requests) != 0);
    try std.testing.expect((trace_flags & ipc.WorkerRuntimeBootOptions.flag_trace_all_requests) != 0);
    try std.testing.expectEqual(@as(u32, 0), supervision.launcher.resolveTraceRuntimeFlags(false, false));
}

test "worker launch full exception logging follows explicit diagnostics flags" {
    const flag = ipc.WorkerRuntimeBootOptions.flag_log_full_js_exceptions;
    try std.testing.expect((supervision.launcher.resolveFullJsExceptionRuntimeFlags(true, false) & flag) != 0);
    // A Debug build logs them unasked.
    try std.testing.expect((supervision.launcher.resolveFullJsExceptionRuntimeFlags(false, true) & flag) != 0);
    try std.testing.expectEqual(@as(u32, 0), supervision.launcher.resolveFullJsExceptionRuntimeFlags(false, false));
}

/// Boot-window fault answer for a path absent from every index.
fn answerNotFound(
    ctx: ?*anyopaque,
    request: *const ipc.FsFaultRequest,
    deadline_ns: u64,
) host.launch.FaultAnswer {
    _ = ctx;
    _ = request;
    _ = deadline_ns;
    return .not_found;
}

test "boot fault drain stops at the per-drain packet cap and resumes on the next call" {
    const allocator = std.testing.allocator;
    const os_fd = @import("collo_os").fd;

    var pair: [2]std.posix.fd_t = undefined;
    const socketpair_rc = std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.SEQPACKET, 0, &pair);
    try std.testing.expectEqual(@as(usize, 0), socketpair_rc);
    const server_end = pair[0];
    const worker_end = pair[1];
    defer std.posix.close(server_end);
    defer std.posix.close(worker_end);
    try os_fd.setNonblocking(server_end, true);

    // One request beyond the per-drain cap, each with the all-zero identity
    // a worker faults with inside its boot window (`worker/fs/fault.zig`),
    // and each answered `.not_found`.
    const scratch = try allocator.alloc(u8, ipc.max_message_bytes);
    defer allocator.free(scratch);
    const flood_count = host.launch.max_faults_per_drain + 1;
    for (0..flood_count) |index| {
        try ipc.fs_fault.sendRequest(worker_end, scratch, .{
            .fault_id = index + 1,
            .request_id = 0,
            .request_generation = 0,
            .worker_id = 0,
            .worker_generation = 0,
            .path = "data/absent.txt",
        });
    }

    // The drain belongs to the host launch machine; pose one over the host
    // end of the fault channel (`server_end`), with the stub answer as its
    // serve seam.
    var quiet_zygote = zygote.host_client.SpawnedZygote{
        .pid = 0,
        .pidfd = -1,
        .control_fd = null,
        .trace_read_fd = null,
        .trace_write_fd = null,
        .next_fork_job_id = 1,
    };
    // The drain sends no WorkerInit, so the launch's wake set is never read.
    const no_wake_set: ipc.egress_shared.WakeSet = .{};
    var machine = host.launch.Machine{
        .allocator = allocator,
        .zygote_process = &quiet_zygote,
        .memory_limit_bytes = 0,
        .options = .{
            .egress = .{ .detached = &no_wake_set },
            .fault_serve = .{ .serve = .{ .serve = answerNotFound } },
        },
        .fs_fault_server_fd = server_end,
        .serve_faults = true,
    };
    defer if (machine.fault_scratch) |drain_scratch| allocator.free(drain_scratch);

    const far_deadline_ns = std.math.maxInt(u64);
    // First drain: serves exactly the cap, then yields with packets still
    // queued, so the fd stays readable and the poll loop re-arms on it.
    try std.testing.expectEqual(host.launch.DrainOutcome.idle, try machine.runFaultDrain(far_deadline_ns));
    try std.testing.expectEqual(@as(u32, host.launch.max_faults_per_drain), machine.boot_faults_served);

    // Second drain: the remaining packet is served, then WouldBlock.
    try std.testing.expectEqual(host.launch.DrainOutcome.idle, try machine.runFaultDrain(far_deadline_ns));
    try std.testing.expectEqual(@as(u32, flood_count), machine.boot_faults_served);

    // Every flooded fault got a typed response on the worker end.
    var responses: usize = 0;
    try os_fd.setNonblocking(worker_end, true);
    var response_buffer: [256]u8 = undefined;
    while (true) {
        const received = std.posix.recv(worker_end, &response_buffer, 0) catch |err| switch (err) {
            error.WouldBlock => break,
            else => return err,
        };
        if (received == 0)
            break;
        responses += 1;
    }
    try std.testing.expectEqual(flood_count, responses);
}
