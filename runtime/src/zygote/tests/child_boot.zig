//! The reason a worker child's failed boot reports (`failureReason` in
//! `zygote/child_boot.zig`): a failed check of the host's input is the
//! host's, the child's own shortage of memory or descriptors is its own,
//! and a missing descriptor or the init deadline names itself. A real
//! child's failed boots, and the page they leave as the host wrote it, are
//! covered by the `zygote-integration` lane.

const std = @import("std");
const zygote = @import("collo_zygote");

const Reason = zygote.ipc.WorkerInitFailedReason;
const failureReason = zygote.child_boot.failureReason;

test "a step that checks the host's input reports a failed check as invalid_worker_init and the child's own shortage as internal_error" {
    // Failures of the checks of the page, the message and the leaf.
    const failed_checks = [_]anyerror{
        error.InvalidMetricsPage,
        error.MissingFdSeals,
        error.InvalidWorkerInitFlags,
        error.InvalidWorkerCgroupDir,
        error.WorkerCgroupNotDedicated,
        error.WorkerCgroupMemoryHighMismatch,
        error.FileNotFound,
    };
    for (failed_checks) |err|
        try std.testing.expectEqual(@as(?Reason, .invalid_worker_init), failureReason(err, true));

    // An mmap, an fstat or an open of the same steps that runs out of
    // memory or descriptors, or meets an errno nothing expects.
    const resource_failures = [_]anyerror{
        error.OutOfMemory,
        error.SystemResources,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.Unexpected,
    };
    for (resource_failures) |err|
        try std.testing.expectEqual(@as(?Reason, .internal_error), failureReason(err, true));
}

test "a failure outside the host's input names its own reason, and a WorkerInit that never came owes none" {
    try std.testing.expectEqual(@as(?Reason, null), failureReason(error.WorkerInitTimeout, false));
    try std.testing.expectEqual(@as(?Reason, .missing_metrics_fd), failureReason(error.MissingMetricsFd, false));
    try std.testing.expectEqual(@as(?Reason, .missing_egress_shared_fd), failureReason(error.MissingEgressSharedFd, false));
    try std.testing.expectEqual(@as(?Reason, .invalid_worker_init), failureReason(error.InvalidFdCount, false));
    try std.testing.expectEqual(@as(?Reason, .init_deadline_exceeded), failureReason(error.WorkerInitDeadlineExceeded, false));
    try std.testing.expectEqual(@as(?Reason, .internal_error), failureReason(error.OutOfMemory, false));
    try std.testing.expectEqual(@as(?Reason, .internal_error), failureReason(error.PermissionDenied, false));
}
