//! Covers the process CPU baseline of `serve/process_cpu.zig`: a peek
//! returns the CPU the process used since the baseline without moving it,
//! and only a commit consumes that delta. The finish path commits once the
//! completed record is in the ring (`serve/response_finish.zig`), so a record
//! that fails to append leaves its delta uncommitted. The clock is the real
//! `CLOCK_PROCESS_CPUTIME_ID`. Runs in `worker-test`.

const std = @import("std");
const worker = @import("collo_worker");

const process_cpu = worker.testing.process_cpu;

test "billed process-cpu baseline only advances on commit" {
    const first = process_cpu.peekBilledDeltaNs();

    // Spend real CPU without a commit: the peeked delta must grow.
    var acc: u64 = 0;
    for (0..2_000_000) |i| acc +%= i *% 31;
    std.mem.doNotOptimizeAway(&acc);

    const second = process_cpu.peekBilledDeltaNs();
    try std.testing.expect(second > first);

    // Committing the peeked delta, as the finish path does once its record
    // is in the ring, consumes it, so the next peek starts near zero and
    // does not count the same span again.
    process_cpu.commitBilledDeltaNs(second);
    const after_commit = process_cpu.peekBilledDeltaNs();
    try std.testing.expect(after_commit < second);
}
