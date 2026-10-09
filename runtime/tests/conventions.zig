//! The convention gates: tests that read the repository's source as text and
//! fail when it breaks a rule of `skills/runtime/references/conventions.md`,
//! with self-tests of the comment provenance matcher the gates share with the
//! `provenance-baseline` step. Lane: `meta-test`, and the aggregate
//! `zig build test`. Rules that are not text, such as struct layouts and
//! limits, are pinned in `runtime/tests/contracts/`.
//!
//! Every path is relative to the repository root, so the gates must run from
//! there; a scan root that does not open fails its gate instead of passing
//! with nothing read. Each gate reads text without parsing it, so it catches
//! only the exact shapes its code searches for. When a gate and its rule
//! disagree, conventions.md requires fixing one of them in the same change.

const std = @import("std");
const provenance = @import("collo_comments").provenance;

/// Production source and benchmarks, for the checks that hold both to the
/// same rule. `runtime/patches/` and `skills/` lie outside every scan root.
/// The checks for rules only production code must keep scan `runtime/src`
/// alone, because a benchmark may keep a shape production may not, such as
/// an empty `catch` on a best-effort eventfd write. Module suites under
/// `runtime/src/<module>/tests/` and `runtime/build/tests/` are exempt from
/// the test-placement checks, and cross-module suites, this file among them,
/// live in `runtime/tests/`.
const source_roots = [_][]const u8{
    "runtime/src",
    "runtime/bench",
};

/// The build system's own source, scanned only by the test-placement checks;
/// its suites under `runtime/build/tests/` are exempt (`isModuleTestPath`).
/// The other checks keep roots without it, because build code names
/// `zig-out`, `WebKitBuild` and vendored paths on purpose and has error
/// handling of its own.
const build_source_roots = [_][]const u8{
    "runtime/build",
};

/// Files under `runtime/build` that still hold inline `test` declarations,
/// with their count. No compilation root runs those tests:
/// `runtime/build/tests/` reaches build code through the named module
/// `collo_buildtool`, and Zig collects tests only from the files of the root
/// module. FIXME: each suite belongs under `runtime/build/tests/` or behind a
/// root registered there. The counts are exact, so a listed file whose count
/// changes, or any other file's first test, fails the gate.
const known_orphaned_build_tests = [_]struct {
    path: []const u8,
    tests: usize,
}{
    .{ .path = "runtime/build/cachefs.zig", .tests = 1 },
    .{ .path = "runtime/build/buildtool.zig", .tests = 6 },
};

/// The roots of the checks that tests must pass as well as production code.
const scan_roots = [_][]const u8{
    "runtime/src",
    "runtime/bench",
    "runtime/tests",
};

test "production source keeps tests out — module suites live only under <module>/tests/" {
    var failures: FailureList = .empty;
    defer deinitFailures(&failures);

    for (source_roots) |root|
        try scanTree(root, &failures, checkNoTestDeclarations);
    try scanTree("runtime/src", &failures, checkNoTestOnlySourceFiles);
    for (build_source_roots) |root| {
        try scanTree(root, &failures, checkBuildNoTestDeclarations);
        try scanTree(root, &failures, checkNoTestOnlySourceFiles);
    }

    try expectNoFailures(&failures, error.SourceInlineTest);
}

test "production error handling stays explicit" {
    var failures: FailureList = .empty;
    defer deinitFailures(&failures);

    try scanTree("runtime/src", &failures, checkProductionSource);

    try expectNoFailures(&failures, error.ProductionConventionViolation);
}

// `std.debug.assert(ok)` is `if (!ok) unreachable`, and the production binary
// is ReleaseFast, where `unreachable` is a promise to the optimizer, not a
// check. An assert that negates the guard around it therefore proves the
// branch dead, and the compiler may delete the branch's body along with the
// `return` that made it a guard, so control falls through with the very value
// the guard rejected. The code reads as defensive and compiles to the
// opposite, which is easy to miss in review.
test "a guard branch never asserts the negation of its own condition" {
    var failures: FailureList = .empty;
    defer deinitFailures(&failures);

    try scanTree("runtime/src", &failures, checkAssertDoesNotNegateGuard);

    try expectNoFailures(&failures, error.ProductionConventionViolation);
}

fn checkAssertDoesNotNegateGuard(path: []const u8, bytes: []const u8, failures: *FailureList) !void {
    if (!std.mem.endsWith(u8, path, ".zig"))
        return;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var line_no: usize = 0;
    var pending_guard: ?[]const u8 = null;
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "//"))
            continue;
        if (assertArgument(line)) |argument| {
            // The gate rejects `assert(false)` wherever it stands, inside a
            // guard or not. Under ReleaseFast it is `unreachable`, so every
            // statement after it in its block is dead, and a function that
            // ends in one tells the optimizer no call reaches it, which lets
            // the callers' defensive branches go as well. Truly unreachable
            // code says `unreachable`; code meant to recover would lose the
            // recovery.
            if (std.mem.eql(u8, argument, "false")) {
                try appendLineFailure(failures, path, line_no, "assert(false) is unreachable under ReleaseFast and takes the recovery after it; log or count the event instead");
            } else if (pending_guard) |condition| {
                if (conditionsAreOpposite(argument, condition))
                    try appendLineFailure(failures, path, line_no, "assert negates the guard containing it; ReleaseFast may delete the branch and its return");
            }
            pending_guard = null;
            continue;
        }
        pending_guard = openedGuardCondition(line);
    }
}

/// The condition of the guard `line` opens, or null when it opens none: the
/// text inside `if (...) {` or `} else if (...) {`, or an empty condition for
/// `orelse {` and `catch {`. The empty condition matches no assert, so only
/// the unconditional `assert(false)` rule applies inside those branches.
fn openedGuardCondition(line: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, line, "orelse {") or std.mem.endsWith(u8, line, "catch {"))
        return "";
    const after_if = if (std.mem.startsWith(u8, line, "if ("))
        line["if (".len..]
    else if (std.mem.startsWith(u8, line, "} else if ("))
        line["} else if (".len..]
    else
        return null;
    if (!std.mem.endsWith(u8, after_if, ") {"))
        return null;
    return std.mem.trim(u8, after_if[0 .. after_if.len - ") {".len], " ");
}

fn assertArgument(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "std.debug.assert("))
        return null;
    if (!std.mem.endsWith(u8, line, ");"))
        return null;
    const inner = line["std.debug.assert(".len .. line.len - ");".len];
    return std.mem.trim(u8, inner, " ");
}

fn withoutLeadingNot(expression: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, expression, "!"))
        return null;
    var bare = std.mem.trim(u8, expression[1..], " ");
    if (std.mem.startsWith(u8, bare, "(") and std.mem.endsWith(u8, bare, ")"))
        bare = std.mem.trim(u8, bare[1 .. bare.len - 1], " ");
    return bare;
}

/// Whether two condition texts negate each other in one of two forms: a
/// leading `!` added or dropped, or a comparison flipped to its complement
/// over identical operands. A looser match would also fire on the legitimate
/// use, an assert of a different fact than the guard's, as in
/// `if (removed) assert(n > 0)`.
fn conditionsAreOpposite(argument: []const u8, condition: []const u8) bool {
    if (withoutLeadingNot(argument)) |bare| {
        if (std.mem.eql(u8, bare, condition))
            return true;
    }
    if (withoutLeadingNot(condition)) |bare| {
        if (std.mem.eql(u8, bare, argument))
            return true;
    }
    const complements = [_][2][]const u8{
        .{ " >= ", " < " },
        .{ " <= ", " > " },
        .{ " > ", " <= " },
        .{ " < ", " >= " },
        .{ " == ", " != " },
        .{ " != ", " == " },
    };
    for (complements) |pair| {
        const split = std.mem.indexOf(u8, condition, pair[0]) orelse continue;
        const left = condition[0..split];
        const right = condition[split + pair[0].len ..];
        if (!std.mem.startsWith(u8, argument, left))
            continue;
        const after_left = argument[left.len..];
        if (!std.mem.startsWith(u8, after_left, pair[1]))
            continue;
        if (std.mem.eql(u8, after_left[pair[1].len..], right))
            return true;
    }
    return false;
}

test "debug allocator declarations use explicit init" {
    var failures: FailureList = .empty;
    defer deinitFailures(&failures);

    for (scan_roots) |root|
        try scanTree(root, &failures, checkDebugAllocatorInit);

    try expectNoFailures(&failures, error.DeprecatedDebugAllocatorInit);
}

test "runtime code does not import reference trees" {
    var failures: FailureList = .empty;
    defer deinitFailures(&failures);

    for (source_roots) |root|
        try scanTree(root, &failures, checkForbiddenRuntimeImports);

    try expectNoFailures(&failures, error.ForbiddenRuntimeImport);
}

test "workers do not regain a direct gateway fd field" {
    var failures: FailureList = .empty;
    defer deinitFailures(&failures);

    for (source_roots) |root|
        try scanTree(root, &failures, checkNoDirectGatewayFdField);

    try expectNoFailures(&failures, error.DirectGatewayFdConventionViolation);
}

test "egress client does not import worker runtime" {
    var failures: FailureList = .empty;
    defer deinitFailures(&failures);

    try scanTree("runtime/src/egress", &failures, checkNoWorkerImportsFromEgress);

    try expectNoFailures(&failures, error.EgressWorkerImportConventionViolation);
}

test "egress ownership boundaries stay one-way" {
    var failures: FailureList = .empty;
    defer deinitFailures(&failures);

    try scanRequiredTree("runtime/src/worker/egress", &failures, checkNoGatewayOrClientImportsFromWorkerEgress);
    try scanRequiredTree("runtime/src/egress/core", &failures, checkNoRuntimeOwnerImportsFromEgressCore);

    const gateway_root = try readFile("runtime/src/egress/gateway/root.zig", 64 * 1024);
    defer std.testing.allocator.free(gateway_root);
    if (std.mem.indexOf(u8, gateway_root, "pub const egress =") != null) {
        try appendFailure(
            &failures,
            "runtime/src/egress/gateway/root.zig",
            "gateway root must not reexport egress client",
        );
    }
    try scanRequiredTree("runtime/src/egress/gateway", &failures, checkNoServerImportsFromGateway);
    try scanRequiredTree("runtime/src/server", &failures, checkServerReadsOnlyGatewayContract);

    try expectNoFailures(&failures, error.EgressOwnershipBoundaryViolation);
}

test "TCP socket options stay centralized in the common socket helper" {
    var failures: FailureList = .empty;
    defer deinitFailures(&failures);

    for (scan_roots) |root|
        try scanTree(root, &failures, checkTcpSocketOptionsCentralized);

    try expectNoFailures(&failures, error.TcpNoDelayConventionViolation);
}

test "the socket option gate catches a listener option set outside the helper and passes the helper calls" {
    const path = "runtime/src/server/net/listener.zig";
    const bypasses = [_][]const u8{
        \\try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        ,
        \\std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1))) catch return error.ReusePortUnavailable;
        ,
        \\try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.INCOMING_CPU, std.mem.asBytes(&cpu_id_c));
    };
    for (bypasses) |source| {
        var failures: FailureList = .empty;
        defer deinitFailures(&failures);
        try checkTcpSocketOptionsCentralized(path, source, &failures);
        if (failures.items.len == 0) {
            std.debug.print("the gate passed a socket option set outside the helper:\n{s}\n", .{source});
            return error.TestUnexpectedResult;
        }
    }

    const calls = [_][]const u8{
        \\try os_socket.setReuseAddress(fd);
        \\os_socket.setReusePort(fd) catch return error.ReusePortUnavailable;
        \\os_socket.setIncomingCpu(fd, cpu_id) catch |err| {}
        ,
        \\// The sockets share the port through SO_REUSEPORT and an SO_INCOMING_CPU hint.
        ,
        \\return @hasDecl(std.posix.SO, "REUSEPORT");
    };
    for (calls) |source| {
        var failures: FailureList = .empty;
        defer deinitFailures(&failures);
        try checkTcpSocketOptionsCentralized(path, source, &failures);
        try expectNoFailures(&failures, error.TestUnexpectedResult);
    }
}

test "fetch body release paths stay callback-only" {
    var failures: FailureList = .empty;
    defer deinitFailures(&failures);

    const path = "runtime/src/egress/core/fetch_body.zig";
    const bytes = try readFile(path, 512 * 1024);
    defer std.testing.allocator.free(bytes);

    try checkFetchBodyReleaseSource(path, bytes, &failures);

    try expectNoFailures(&failures, error.FetchBodyReleaseConventionViolation);
}

test "server code reads a worker's page only through its snapshots and drains" {
    var failures: FailureList = .empty;
    defer deinitFailures(&failures);

    try scanRequiredTree("runtime/src/server", &failures, checkWorkerPageReads);

    try expectNoFailures(&failures, error.WorkerPageReadConventionViolation);
}

test "the worker page gate catches a loop over the live slots and a load of the page, and passes the snapshot reads" {
    const path = "runtime/src/server/supervisor/page_reader.zig";
    const bypasses = [_][]const u8{
        \\for (metrics.live_slots) |*slot| {
        \\    if (@atomicLoad(u32, &slot.state, .acquire) == 1) return true;
        \\}
        ,
        \\for (metrics.live_slots) |slot| {
        \\    if (slot.state == 1) return true;
        \\}
        ,
        \\const raw = @atomicLoad(u32, &view.header.state, .acquire);
        ,
        \\const state = view.header.state;
        ,
        \\const fatal = view.log_header.fatal;
        ,
        \\const record = metrics.completed_records[0];
    };
    for (bypasses) |source| {
        var failures: FailureList = .empty;
        defer deinitFailures(&failures);
        try checkWorkerPageReads(path, source, &failures);
        if (failures.items.len == 0) {
            std.debug.print("the gate passed a read past the snapshots:\n{s}\n", .{source});
            return error.TestUnexpectedResult;
        }
    }

    const reads = [_][]const u8{
        \\if (worker_shared_page.LiveSlotSnapshot.find(metrics.live_slots, identity)) |snapshot| {}
        ,
        \\if (worker_shared_page.LiveSlotSnapshot.find(
        \\    worker.handle.metrics.?.live_slots,
        \\    identity,
        \\)) |snapshot| {}
        ,
        \\const count = peeked.copy(metrics.completed_records, 0, records[0..limit]);
        ,
        \\const snapshot = worker_shared_page.LifecycleSnapshot.load(metrics.header);
        ,
        \\// `metrics.live_slots` and `view.log_header` named in a comment.
    };
    for (reads) |source| {
        var failures: FailureList = .empty;
        defer deinitFailures(&failures);
        try checkWorkerPageReads(path, source, &failures);
        try expectNoFailures(&failures, error.WorkerPageReadConventionViolation);
    }
}

test "zygote fork loop stays VM-free and allocation-free after prepare" {
    var failures: FailureList = .empty;
    defer deinitFailures(&failures);

    const path = "runtime/src/zygote/fork_loop.zig";
    const bytes = try readFile(path, 512 * 1024);
    defer std.testing.allocator.free(bytes);

    const body = try extractFunctionBody(bytes, "fn serveForkRequests(");
    try expectContains(body, "assertPreparedForkBaseline(zygote)");
    try expectContains(body, "process.assertSingleThreadedSelf()");

    const forbidden = [_][]const u8{
        ".vm.",
        "prepareForFork",
        "postForkChild",
        "boot_allocator",
        "std.heap",
        ".alloc(",
        ".free(",
        "allocPrint",
        "ArrayList",
        "HashMap",
    };
    for (forbidden) |needle| {
        if (std.mem.indexOf(u8, body, needle) != null)
            try appendFailure(&failures, path, "zygote fork loop must not touch VM/JSC or allocator after prepare");
    }

    try expectNoFailures(&failures, error.ZygoteForkLoopConventionViolation);
}

test "C ABI surface stays POD-shaped" {
    const abi = try readFile("runtime/src/bindings/include/collo/abi.h", 256 * 1024);
    defer std.testing.allocator.free(abi);

    try expectNotContains(abi, "std::");
    try expectNotContains(abi, "WTF::");
    try expectNotContains(abi, "Vector<");
    try expectNotContains(abi, "bool ");
    try expectNotContains(abi, "collo__");
}

test "C++ bindings keep allocation and IO policy explicit" {
    var failures: FailureList = .empty;
    defer deinitFailures(&failures);

    try scanTree("runtime/src/bindings", &failures, checkBindingSource);

    try expectNoFailures(&failures, error.BindingConventionViolation);
}

test "raw syscall returns are not decoded with std.posix.errno" {
    var failures: FailureList = .empty;
    defer deinitFailures(&failures);

    for (scan_roots) |root|
        try scanTree(root, &failures, checkRawSyscallErrnoDecode);

    try expectNoFailures(&failures, error.RawSyscallErrnoDecode);
}

// A comment states what the code guarantees; plan identifiers, dates, section
// numbers of other documents and review bookkeeping stop meaning anything once
// the plan closes. The history already in comments is pinned per file by
// runtime/tests/comment_provenance.zon, so a count may fall but never rise.
// The markers and their exclusions live in dev/comments/provenance.zig, shared
// with the `provenance-baseline` step that lowers the baseline.
test "comments gain no plan provenance beyond runtime/tests/comment_provenance.zon" {
    const gpa = std.testing.allocator;
    const repository = std.fs.cwd();
    var report: std.Io.Writer.Allocating = .init(gpa);
    defer report.deinit();

    const current = try provenance.countRepository(gpa, repository);
    defer current.deinit(gpa);
    const baseline = provenance.readBaseline(gpa, repository, &report.writer) catch |err| {
        std.debug.print("{s}", .{report.written()});
        return err;
    };
    defer baseline.deinit(gpa);
    const excess = try provenance.findExcess(gpa, baseline.files, current.files);
    defer gpa.free(excess);
    if (excess.len == 0) return;

    for (excess) |file| {
        try report.writer.print("{s}: {d} provenance {s} in comments, the baseline allows {d}:\n", .{
            file.path, file.markers, provenance.noun(file.markers, "marker"), file.allowed,
        });
        try provenance.writeFileMarkers(gpa, repository, file.path, &report.writer);
    }
    try report.writer.writeAll(
        \\A comment states the constraint or invariant the code keeps; plan and
        \\review history belongs in git and the ledgers (conventions.md, "Comments
        \\and documentation"). Rewrite the new marker out of the comment. If a
        \\match is ordinary technical vocabulary, teach dev/comments/provenance.zig
        \\to skip it and add the case to the vocabulary test in this file. After
        \\removing markers anywhere, `zig build provenance-baseline` lowers the
        \\baseline; nothing raises it except a hand edit.
        \\
    );
    std.debug.print("{s}", .{report.written()});
    return error.CommentProvenanceAboveBaseline;
}

test "provenance markers catch plan history and leave technical vocabulary alone" {
    const History = struct { text: []const u8, markers: u32 };
    const history = [_]History{
        .{ .text = "// W1a: split the ring", .markers = 1 },
        .{ .text = "// F5-b keeps the drain order (T2/T3)", .markers = 3 },
        .{ .text = "// O0-CONTRATO-2026-07-23 \u{a7}6", .markers = 3 },
        .{ .text = "// ledger D-9, findings MED-1", .markers = 2 },
        .{ .text = "// measured 2026-07-26 in the 2026-07 sweep", .markers = 2 },
        .{ .text = "// fix-wave follow-up, Onda DoS, fase 5", .markers = 3 },
        .{ .text = "// the concurrency arc", .markers = 1 },
        .{ .text = "// (review finding 8; review HIGH-M rider)", .markers = 2 },
        .{ .text = "// Review fix (finding 4)", .markers = 2 },
        .{ .text = "// #7: acks aggregate (the #12 rule)", .markers = 2 },
        .{ .text = "// see todo/egress-dto.md", .markers = 1 },
        .{ .text = "// Sol MED, ratification pending; Codex-requested", .markers = 3 },
    };
    for (history) |case| {
        const markers = provenance.countText(case.text);
        if (markers != case.markers) {
            std.debug.print("expected {d} markers, found {d}: {s}\n", .{ case.markers, markers, case.text });
            return error.TestUnexpectedMarkerCount;
        }
    }

    const technical = [_][]const u8{
        "// the ingress lane drains its ring under the W^X policy",
        "// speculative H2, HTTP/1-only ALPN, H2-capable origins",
        "// UTF-8 and UTF-16 code units; SHA-256, SHA-1 and P-521",
        "// RFC 9113 \u{a7}8.1.1 makes it a stream error; ECMA-262 \u{a7}7.1.6 too",
        "/// If-None-Match per RFC 9110\n/// \u{a7}13.1.2: weak comparison",
        "// IPv4-mapped IPv6, SigV4 signing, the S3-compatible API, Uint8Array",
        "// x86_64 and ARM64 hosts, the L2 header, C0 controls, WSL2, V8 isolates, Ampere A4",
        "// \u{e9} is C3 A9 in UTF-8",
        "// \"T1\" marks Tor exit nodes",
        "// the 2015-08-30 suite vector, signed at 2026-01-01T00:00:00Z",
        "// a COLLOFS1 index, E2BIG, H1TurnBudget, F2_SIZE, 0xF0, u8, i64",
        "// ARC counts references; a reviewer reading the table; review the queue",
        "// the orchestrator phase, Phase 2 of the install, the fault ledger, Stage 1",
        "// O(1) lookup, 1'000 entries, &#39; escapes, \"#1/<len>\" names, slot#3",
    };
    for (technical) |text| {
        var matches: provenance.TextMatches = .init(text);
        if (matches.next()) |match| {
            std.debug.print("{s} matched `{s}` in: {s}\n", .{ match.marker.label(), text[match.start..match.end], text });
            return error.TestTechnicalVocabularyMatched;
        }
    }
}

test "the provenance gate reads comments, never string literals" {
    const zig_source =
        \\const label = "W1a"; // the ring
        \\const text =
        \\    \\F2b in a multiline string
        \\;
        \\/// Doc comments count: O1.
        \\// Plain comments count: T3.
        \\
    ;
    try std.testing.expectEqual(@as(u32, 2), provenance.countSource(.zig, zig_source));

    const cpp_source =
        \\auto label = "// W1a"; auto raw = R"(/* F2b */)"; // O1
        \\/* T3 */ char hash = '#'; // #7
        \\
    ;
    try std.testing.expectEqual(@as(u32, 3), provenance.countSource(.c_family, cpp_source));
}

test "the provenance baseline lets a count fall and stops it rising" {
    const gpa = std.testing.allocator;
    const baseline = [_]provenance.FileCount{
        .{ .path = "runtime/src/a.zig", .markers = 3 },
        .{ .path = "runtime/src/b.zig", .markers = 1 },
    };

    const lowered = [_]provenance.FileCount{.{ .path = "runtime/src/a.zig", .markers = 2 }};
    const none = try provenance.findExcess(gpa, &baseline, &lowered);
    defer gpa.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);

    const raised = [_]provenance.FileCount{
        .{ .path = "runtime/src/a.zig", .markers = 4 },
        .{ .path = "runtime/src/c.zig", .markers = 1 },
    };
    const excess = try provenance.findExcess(gpa, &baseline, &raised);
    defer gpa.free(excess);
    try std.testing.expectEqual(@as(usize, 2), excess.len);
    try std.testing.expectEqualStrings("runtime/src/a.zig", excess[0].path);
    try std.testing.expectEqual(@as(u32, 4), excess[0].markers);
    try std.testing.expectEqual(@as(u32, 3), excess[0].allowed);
    try std.testing.expectEqualStrings("runtime/src/c.zig", excess[1].path);
    try std.testing.expectEqual(@as(u32, 0), excess[1].allowed);

    const duplicated = [_]provenance.FileCount{ baseline[0], baseline[0] };
    try std.testing.expectError(error.DuplicateBaselineEntry, provenance.findExcess(gpa, &duplicated, &lowered));
}

test "the provenance baseline file reads back what was written and carries no marker itself" {
    const gpa = std.testing.allocator;
    const samples = [_][]const provenance.FileCount{
        &.{
            .{ .path = "dev/comments/x.zig", .markers = 2 },
            .{ .path = "runtime/src/\"quoted\".zig", .markers = 1 },
        },
        &.{},
    };
    for (samples) |files| {
        var written: std.Io.Writer.Allocating = .init(gpa);
        defer written.deinit();
        try provenance.writeBaseline(&written.writer, files);
        const text = try gpa.dupeZ(u8, written.written());
        defer gpa.free(text);
        try std.testing.expectEqual(@as(u32, 0), provenance.countSource(.zig, text));

        var diagnostics: std.zon.parse.Diagnostics = .{};
        defer diagnostics.deinit(gpa);
        const parsed = try provenance.parseBaseline(gpa, text, &diagnostics);
        defer parsed.deinit(gpa);
        try std.testing.expectEqual(files.len, parsed.files.len);
        for (files, parsed.files) |want, got| {
            try std.testing.expectEqualStrings(want.path, got.path);
            try std.testing.expectEqual(want.markers, got.markers);
        }
    }
}

// A test file that no compilation root reaches never runs, and nothing
// reports it. Reachability is therefore the closure of the path-import graph
// over the real compilation roots: `runtime/all_tests.zig`, whose imports are
// parsed from the file itself, and the build-registered roots below. Every
// file under `runtime/tests/` or a module test tree (`runtime/src/<module>/tests/`,
// `runtime/build/tests/`) that declares a test must land in that closure. An
// import counts only from a file already in the closure, so an aggregator
// that nothing reaches cannot vouch for its subtree.
//
// The table lists each compilation root that `runtime/build/tests.zig`
// registers and `runtime/all_tests.zig` does not import directly. A root that
// `all_tests.zig` imports, such as a module aggregator, enters the closure
// through it and is not listed. The gate "registered test roots mirror the
// build's compilation roots" keeps the table and the build in step.
const registered_test_roots = [_][]const u8{
    // The JSC-linked kernel lane roots (addZygoteIntegration, addLocalE2e).
    "runtime/tests/integration/zygote.zig",
    "runtime/tests/integration/all.zig",
    // The JSC-free gateway control suite (addGatewayControlSuite) and the
    // smoke root the ASan and Valgrind lanes share (addSanitizedSmoke,
    // addValgrindSmoke).
    "runtime/src/server/tests/gateway/control_plane.zig",
    "runtime/src/bindings/tests/smoke.zig",
    // Stub suite roots (the stub_suites table).
    "runtime/src/common/tests/http.zig",
    "runtime/src/common/tests/ipc.zig",
    "runtime/src/server/tests/http2/request.zig",
    "runtime/src/server/tests/http2/connection.zig",
    "runtime/src/server/tests/http2/frame_reader.zig",
    "runtime/src/server/tests/analytics/all.zig",
    "runtime/src/server/tests/config/all.zig",
    "runtime/src/server/tests/routes/all.zig",
    "runtime/src/server/tests/supervisor/all.zig",
    "runtime/src/worker/tests/request/transport.zig",
    // A module the build creates from a file inside a suite tree.
    // `collectBuildTestRoots` cannot tell it from a suite root, so it is
    // listed to keep the mirror exact; seeding the closure from it costs
    // nothing.
    "runtime/src/server/tests/support/supervisor_fixture.zig",
    // The egress client and core entries of `stub_suites`.
    "runtime/src/egress/tests/client/http2/all.zig",
    "runtime/src/egress/tests/client/tls.zig",
    "runtime/src/egress/tests/client/http1.zig",
    "runtime/src/egress/tests/client/data_io.zig",
    "runtime/src/egress/tests/client/pool.zig",
    "runtime/src/egress/tests/core/all.zig",
};

test "every test file is reachable from a registered root" {
    const allocator = std.testing.allocator;
    var candidates: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var candidate_keys = candidates.keyIterator();
        while (candidate_keys.next()) |key| allocator.free(key.*);
        candidates.deinit(allocator);
    }
    try collectCandidateTestFiles("runtime/tests", &candidates);
    // Module test trees are listed directly rather than found by walking all
    // of `runtime/src`: a test declared in production source already fails
    // "production source keeps tests out", so the walk would only cost time.
    try collectModuleTestCandidates(&candidates);

    var closure: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var closure_keys = closure.keyIterator();
        while (closure_keys.next()) |key| allocator.free(key.*);
        closure.deinit(allocator);
    }
    try computeRootImportClosure(&closure);

    var failures: FailureList = .empty;
    defer deinitFailures(&failures);
    var it = candidates.keyIterator();
    while (it.next()) |key| {
        const path = key.*;
        if (closure.contains(path)) continue;
        // Support files are imported by suites as needed; only a file that
        // declares a test must be in the closure.
        if (!hasTestDeclaration(path)) continue;
        try appendFailureMessage(
            &failures,
            "{s}: test file is outside every compilation root's import closure — wire it into its domain aggregator (or register the root in runtime/build/tests.zig AND registered_test_roots)",
            .{path},
        );
    }
    try expectNoFailures(&failures, error.UnreachableTestFile);
}

// `registered_test_roots` seeds the reachability closure, so drift from the
// build fails open both ways: an entry whose registration was deleted keeps
// seeding a suite the build no longer compiles, and a registration without an
// entry leaves its subtree unproven. This gate extracts the test roots from
// the text of `runtime/build/tests.zig`, which registers every test
// compilation under `runtime/`, and requires, as sets, that the extracted
// roots minus `runtime/all_tests.zig` and its direct path imports equal
// `registered_test_roots`.
test "registered test roots mirror the build's compilation roots" {
    const allocator = std.testing.allocator;

    var build_roots: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var root_keys = build_roots.keyIterator();
        while (root_keys.next()) |key| allocator.free(key.*);
        build_roots.deinit(allocator);
    }
    try collectBuildTestRoots(&build_roots);

    var origin_imports: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var import_keys = origin_imports.keyIterator();
        while (import_keys.next()) |key| allocator.free(key.*);
        origin_imports.deinit(allocator);
    }
    try collectDirectPathImports("runtime/all_tests.zig", &origin_imports);

    var failures: FailureList = .empty;
    defer deinitFailures(&failures);

    var it = build_roots.keyIterator();
    while (it.next()) |key| {
        const path = key.*;
        if (std.mem.eql(u8, path, "runtime/all_tests.zig")) continue;
        if (origin_imports.contains(path)) continue;
        if (containsPath(&registered_test_roots, path)) continue;
        try appendFailureMessage(
            &failures,
            "runtime/build/tests.zig registers test root {s} but registered_test_roots lacks it — add the entry so the reachability closure can seed it",
            .{path},
        );
    }
    for (registered_test_roots) |entry| {
        if (build_roots.contains(entry)) continue;
        try appendFailureMessage(
            &failures,
            "registered_test_roots lists {s} but runtime/build/tests.zig registers no such test root — stale entry; the closure would keep seeding a suite the build no longer compiles",
            .{entry},
        );
    }
    try expectNoFailures(&failures, error.TestRootTableDrift);
}

/// Adds to `roots` the test compilation roots `runtime/build/tests.zig`
/// registers, read from its text. Three shapes cover every registration, each
/// on one line as `zig fmt` keeps it: `addJscTest(b, ctx, "...")` calls,
/// `.root = "..."` entries of `stub_suites`, and
/// `.root_source_file = b.path("...")`. The last shape also appears where the
/// build creates fixture modules, executables and benchmark modules, so only
/// test-tree paths count (`isTestTreeRootPath`), and the bindings smoke root
/// that the ASan and Valgrind lanes both register counts once. `//` tails are
/// stripped first, as the closure walk does, so a registration commented out
/// drops out here too.
fn collectBuildTestRoots(roots: *std.StringHashMapUnmanaged(void)) !void {
    const bytes = try readFile("runtime/build/tests.zig", 8 * 1024 * 1024);
    defer std.testing.allocator.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const code = if (std.mem.indexOf(u8, line, "//")) |comment| line[0..comment] else line;
        if (matchQuotedZigPath(code, "addJscTest(b, ctx, \"")) |path|
            try putOwnedPath(roots, path);
        if (matchQuotedZigPath(code, ".root = \"")) |path|
            try putOwnedPath(roots, path);
        if (matchQuotedZigPath(code, ".root_source_file = b.path(\"")) |path| {
            if (isTestTreeRootPath(path))
                try putOwnedPath(roots, path);
        }
    }
    // Extracting nothing means the registration shapes changed. One error
    // says so, where the gate would otherwise report every table entry as
    // stale.
    if (roots.count() == 0) return error.NoBuildTestRootsExtracted;
}

fn matchQuotedZigPath(code: []const u8, prefix: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, code, prefix) orelse return null;
    const rest = code[start + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    const spec = rest[0..end];
    if (!std.mem.endsWith(u8, spec, ".zig")) return null;
    return spec;
}

fn putOwnedPath(set: *std.StringHashMapUnmanaged(void), path: []const u8) !void {
    const allocator = std.testing.allocator;
    if (set.contains(path)) return;
    const owned = try allocator.dupe(u8, path);
    errdefer allocator.free(owned);
    try set.putNoClobber(allocator, owned, {});
}

/// Whether a `.root_source_file` path can be a test compilation root: a path
/// in a test tree, but not under `runtime/tests/support/`, whose files suites
/// import and the build never compiles as roots.
fn isTestTreeRootPath(path: []const u8) bool {
    if (std.mem.startsWith(u8, path, "runtime/tests/support/")) return false;
    return isModuleTestPath(path) or
        std.mem.startsWith(u8, path, "runtime/tests/");
}

/// Adds to `imports` the files `path` imports by path, read line by line with
/// `//` tails stripped as the closure walk does, without following them
/// further: for `runtime/all_tests.zig`, the roots it contributes itself.
fn collectDirectPathImports(path: []const u8, imports: *std.StringHashMapUnmanaged(void)) !void {
    const allocator = std.testing.allocator;
    const bytes = try readFile(path, 1024 * 1024);
    defer allocator.free(bytes);
    const importer_dir = std.fs.path.dirname(path) orelse ".";
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const code = if (std.mem.indexOf(u8, line, "//")) |comment| line[0..comment] else line;
        var rest = code;
        while (std.mem.indexOf(u8, rest, "@import(\"")) |start| {
            rest = rest[start + "@import(\"".len ..];
            const end = std.mem.indexOfScalar(u8, rest, '"') orelse break;
            const spec = rest[0..end];
            rest = rest[end..];
            if (!std.mem.endsWith(u8, spec, ".zig")) continue;
            const resolved = try std.fs.path.resolve(allocator, &.{ importer_dir, spec });
            defer allocator.free(resolved);
            try putOwnedPath(imports, repoRelativePath(resolved));
        }
    }
}

/// Adds to `closure`, which owns the paths, every file reachable through path
/// imports from `runtime/all_tests.zig` and the `registered_test_roots`
/// entries; the work list borrows the paths. The origin is parsed, so
/// dropping an aggregator's import from it reports the aggregator's whole
/// subtree as unreachable. A spec that names no readable file is a leaf. The
/// lexical scan admits false edges from string literals, and a false edge
/// can only widen the closure, never hide a file from it.
fn computeRootImportClosure(closure: *std.StringHashMapUnmanaged(void)) !void {
    const allocator = std.testing.allocator;

    // A missing `runtime/all_tests.zig` fails the gate here. The walk below
    // would take it for a leaf and shrink the closure to the registered roots.
    const origin_probe = try readFile("runtime/all_tests.zig", 1024 * 1024);
    allocator.free(origin_probe);

    var queue: FailureList = .empty;
    defer queue.deinit(allocator);

    try enqueueClosurePath(closure, &queue, "runtime/all_tests.zig");
    for (registered_test_roots) |root|
        try enqueueClosurePath(closure, &queue, root);

    while (queue.pop()) |path| {
        const bytes = readFile(path, 8 * 1024 * 1024) catch continue;
        defer allocator.free(bytes);
        const importer_dir = std.fs.path.dirname(path) orelse ".";
        // `//` tails are stripped, so a commented-out import cannot keep a
        // subtree in the closure. A `//` inside a string literal cuts its line
        // short, which can only drop an edge and fail the gate, never invent
        // one.
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            const code = if (std.mem.indexOf(u8, line, "//")) |comment| line[0..comment] else line;
            var rest = code;
            while (std.mem.indexOf(u8, rest, "@import(\"")) |start| {
                rest = rest[start + "@import(\"".len ..];
                const end = std.mem.indexOfScalar(u8, rest, '"') orelse break;
                const spec = rest[0..end];
                rest = rest[end..];
                if (!std.mem.endsWith(u8, spec, ".zig")) continue; // module imports
                const resolved = try std.fs.path.resolve(allocator, &.{ importer_dir, spec });
                defer allocator.free(resolved);
                try enqueueClosurePath(closure, &queue, repoRelativePath(resolved));
            }
        }
    }
}

fn enqueueClosurePath(
    closure: *std.StringHashMapUnmanaged(void),
    queue: *FailureList,
    path: []const u8,
) !void {
    const allocator = std.testing.allocator;
    if (closure.contains(path)) return;
    const owned = try allocator.dupe(u8, path);
    {
        errdefer allocator.free(owned);
        try closure.putNoClobber(allocator, owned, {});
    }
    try queue.append(allocator, owned);
}

/// The suffix of `resolved` that starts at the first tree holding test roots,
/// the form `registered_test_roots` spells; a path outside those trees comes
/// back unchanged. `std.fs.path.resolve` keeps relative input relative on
/// POSIX, so this trims only a path that arrived with a prefix.
fn repoRelativePath(resolved: []const u8) []const u8 {
    return for ([_][]const u8{ "runtime/tests/", "runtime/src/", "runtime/build/" }) |anchor| {
        if (std.mem.indexOf(u8, resolved, anchor)) |idx| break resolved[idx..];
    } else resolved;
}

fn containsPath(paths: []const []const u8, path: []const u8) bool {
    for (paths) |candidate| {
        if (std.mem.eql(u8, candidate, path)) return true;
    }
    return false;
}

/// Adds the files of every module test tree to `candidates`:
/// `runtime/src/<module>/tests/` for each top-level module that has one, and
/// `runtime/build/tests/`. The production source around them is not walked.
fn collectModuleTestCandidates(candidates: *std.StringHashMapUnmanaged(void)) !void {
    const allocator = std.testing.allocator;
    var src = try std.fs.cwd().openDir("runtime/src", .{ .iterate = true });
    defer src.close();
    var it = src.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const tests_root = try std.fs.path.join(allocator, &.{ "runtime/src", entry.name, "tests" });
        defer allocator.free(tests_root);
        var probe = std.fs.cwd().openDir(tests_root, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => return err,
        };
        probe.close();
        try collectCandidateTestFiles(tests_root, candidates);
    }
    var build_probe = std.fs.cwd().openDir("runtime/build/tests", .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    build_probe.close();
    try collectCandidateTestFiles("runtime/build/tests", candidates);
}

/// Adds to `candidates`, the files the closure may have to reach, every
/// `.zig` file under `root` that `isPrunedReachabilityPath` does not exempt
/// and, outside `runtime/tests`, that lies in a module test tree.
/// `candidates` owns the paths. Import edges come only from the closure walk.
fn collectCandidateTestFiles(
    root: []const u8,
    candidates: *std.StringHashMapUnmanaged(void),
) !void {
    const allocator = std.testing.allocator;
    var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (isPrunedReachabilityPath(entry.path)) continue;
        const full = try std.fs.path.join(allocator, &.{ root, entry.path });
        errdefer allocator.free(full);
        // Outside `runtime/tests` only module test trees count. The callers
        // pass no other root, so this guards only against a new caller.
        if (!std.mem.eql(u8, root, "runtime/tests") and !isModuleTestPath(full)) {
            allocator.free(full);
            continue;
        }
        const put = try candidates.getOrPut(allocator, full);
        if (put.found_existing) allocator.free(full);
    }
}

/// Whether a path relative to a test root is exempt from reachability: a
/// `support/` directory directly under that root, whose files suites import as
/// needed, or a build cache. An import from a reached file still adds such a
/// file to the closure.
fn isPrunedReachabilityPath(rel: []const u8) bool {
    return std.mem.startsWith(u8, rel, "support/") or
        std.mem.indexOf(u8, rel, ".zig-cache") != null;
}

/// Whether `path` lies in a module test tree, `runtime/src/<module>/tests/` or
/// `runtime/build/tests/`, which holds that module's suites. Only a module's
/// top-level `tests/` qualifies; a `tests/` directory deeper inside a module
/// is production source.
fn isModuleTestPath(path: []const u8) bool {
    if (std.mem.startsWith(u8, path, "runtime/build/tests/")) return true;
    const src_root = "runtime/src/";
    if (!std.mem.startsWith(u8, path, src_root)) return false;
    const rest = path[src_root.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
    return std.mem.startsWith(u8, rest[slash + 1 ..], "tests/");
}

fn hasTestDeclaration(path: []const u8) bool {
    const bytes = readFile(path, 8 * 1024 * 1024) catch return false;
    defer std.testing.allocator.free(bytes);
    return std.mem.indexOf(u8, bytes, "\ntest \"") != null or
        std.mem.startsWith(u8, bytes, "test \"") or
        std.mem.indexOf(u8, bytes, "\ntest {") != null;
}

fn appendFailureMessage(
    failures: *FailureList,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const message = try std.fmt.allocPrint(std.testing.allocator, fmt, args);
    errdefer std.testing.allocator.free(message);
    try failures.append(std.testing.allocator, message);
}

const FailureList = std.array_list.Aligned([]const u8, null);

fn deinitFailures(failures: *FailureList) void {
    for (failures.items) |failure|
        std.testing.allocator.free(failure);
    failures.deinit(std.testing.allocator);
}

fn scanTree(
    root: []const u8,
    failures: *FailureList,
    comptime check: fn ([]const u8, []const u8, *FailureList) anyerror!void,
) !void {
    // A missing root fails the gate instead of scanning nothing. The roots are
    // relative to the repository root, so from any other directory none of
    // them opens, and a check that sees no file reports no violation: every
    // gate in this file would pass without reading anything.
    var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer dir.close();
    try walkChecked(dir, root, "", failures, check, 8 * 1024 * 1024);
}

fn scanRequiredTree(
    root: []const u8,
    failures: *FailureList,
    comptime check: fn ([]const u8, []const u8, *FailureList) anyerror!void,
) !void {
    var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer dir.close();
    try walkChecked(dir, root, "", failures, check, 1024 * 1024);
}

/// Runs `check` on every checked source file under `dir`, never entering a
/// directory `isPrunedDir` names. `std.fs.Dir.Walker` cannot prune: it
/// descends into every subtree and only lets the caller skip files. `rel` is
/// the path from `root` to `dir`, empty at the top, and `check` receives each
/// file's path joined to `root`.
fn walkChecked(
    dir: std.fs.Dir,
    root: []const u8,
    rel: []const u8,
    failures: *FailureList,
    comptime check: fn ([]const u8, []const u8, *FailureList) anyerror!void,
    max_bytes: usize,
) !void {
    var it = dir.iterate();
    while (try it.next()) |entry| {
        const entry_rel = if (rel.len == 0)
            try std.testing.allocator.dupe(u8, entry.name)
        else
            try std.fs.path.join(std.testing.allocator, &.{ rel, entry.name });
        defer std.testing.allocator.free(entry_rel);

        switch (entry.kind) {
            .directory => {
                if (isPrunedDir(entry_rel))
                    continue;
                var sub = dir.openDir(entry.name, .{ .iterate = true }) catch |err| switch (err) {
                    error.FileNotFound => continue,
                    else => return err,
                };
                defer sub.close();
                try walkChecked(sub, root, entry_rel, failures, check, max_bytes);
            },
            .file => {
                if (!isCheckedSource(entry_rel))
                    continue;
                const path = try std.fs.path.join(std.testing.allocator, &.{ root, entry_rel });
                defer std.testing.allocator.free(path);
                const bytes = try readFile(path, max_bytes);
                defer std.testing.allocator.free(bytes);
                try check(path, bytes, failures);
            },
            else => {},
        }
    }
}

/// Directories a scan never enters: a `docs` directory, whose documents may
/// quote forbidden code as an example, and version-control, dependency and
/// build-output trees.
fn isPrunedDir(rel: []const u8) bool {
    const name = std.fs.path.basename(rel);
    return std.mem.eql(u8, name, "docs") or
        std.mem.eql(u8, name, ".git") or
        std.mem.eql(u8, name, "node_modules") or
        std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, ".zig-cache") or
        std.mem.eql(u8, name, "zig-cache");
}

fn checkNoTestDeclarations(path: []const u8, bytes: []const u8, failures: *FailureList) !void {
    if (isModuleTestPath(path)) return;
    if (!std.mem.endsWith(u8, path, ".zig"))
        return;
    if (std.mem.startsWith(u8, bytes, "test \"") or
        std.mem.startsWith(u8, bytes, "test {") or
        std.mem.indexOf(u8, bytes, "\ntest \"") != null or
        std.mem.indexOf(u8, bytes, "\ntest {") != null)
    {
        try appendFailure(failures, path, "test declarations belong under tests/");
    }
}

/// `checkNoTestDeclarations` for `runtime/build`: it counts the same
/// column-zero declarations, and a file listed in `known_orphaned_build_tests`
/// must hold exactly its pinned count while any other file holds none.
fn checkBuildNoTestDeclarations(path: []const u8, bytes: []const u8, failures: *FailureList) !void {
    if (isModuleTestPath(path)) return;
    if (!std.mem.endsWith(u8, path, ".zig"))
        return;
    const count = countTestDeclarations(bytes);
    for (known_orphaned_build_tests) |known| {
        if (!std.mem.eql(u8, path, known.path)) continue;
        if (count != known.tests)
            try appendFailureMessage(
                failures,
                "{s}: known-orphaned inline test count drifted ({d} pinned, {d} found) — these tests run NOWHERE; move the suite under runtime/build/tests/ (or re-pin known_orphaned_build_tests with the buildtool arc)",
                .{ path, known.tests, count },
            );
        return;
    }
    if (count != 0)
        try appendFailureMessage(
            failures,
            "{s}: {d} inline test declaration(s) in runtime/build run NOWHERE — no addTest root compiles this file; put the suite under runtime/build/tests/ (see known_orphaned_build_tests)",
            .{ path, count },
        );
}

fn countTestDeclarations(bytes: []const u8) usize {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "test \"") or std.mem.startsWith(u8, line, "test {"))
            count += 1;
    }
    return count;
}

fn checkNoTestOnlySourceFiles(path: []const u8, bytes: []const u8, failures: *FailureList) !void {
    if (isModuleTestPath(path)) return;
    _ = bytes;
    if (std.mem.indexOf(u8, path, "test_stub") != null or
        std.mem.indexOf(u8, path, "/test_") != null or
        std.mem.indexOf(u8, path, "_test.") != null)
        try appendFailure(failures, path, "test-only source belongs under tests/");
}

fn checkProductionSource(path: []const u8, bytes: []const u8, failures: *FailureList) !void {
    if (isModuleTestPath(path)) return;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var line_no: usize = 1;
    var in_catch_switch = false;
    while (lines.next()) |line| : (line_no += 1) {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.indexOf(u8, line, "catch {}") != null or
            std.mem.indexOf(u8, line, "catch { }") != null)
            try appendLineFailure(failures, path, line_no, "empty catch block");

        if (std.mem.indexOf(u8, line, "std.testing") != null)
            try appendLineFailure(failures, path, line_no, "std.testing leaked into production source");

        if (std.mem.indexOf(u8, line, "catch |") != null and std.mem.indexOf(u8, line, "switch") != null)
            in_catch_switch = true;

        if (in_catch_switch and isSilentCatchAll(trimmed))
            try appendLineFailure(failures, path, line_no, "catch switch has silent catch-all");

        if (in_catch_switch and std.mem.indexOf(u8, line, "};") != null)
            in_catch_switch = false;
    }
}

fn checkDebugAllocatorInit(path: []const u8, bytes: []const u8, failures: *FailureList) !void {
    if (!std.mem.endsWith(u8, path, ".zig"))
        return;
    if (try hasDeprecatedDebugAllocatorInit(bytes))
        try appendFailure(failures, path, "DebugAllocator must be initialized with .init");
}

fn checkForbiddenRuntimeImports(path: []const u8, bytes: []const u8, failures: *FailureList) !void {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        if (!isImportOrIncludeLine(line))
            continue;
        if (containsForbiddenImportTarget(line))
            try appendLineFailure(failures, path, line_no, "runtime code must not import reference or generated build trees");
    }
}

fn checkBindingSource(path: []const u8, bytes: []const u8, failures: *FailureList) !void {
    if (!std.mem.endsWith(u8, path, ".cpp") and
        !std.mem.endsWith(u8, path, ".cc") and
        !std.mem.endsWith(u8, path, ".h"))
        return;
    const is_jsc_runtime = std.mem.indexOf(u8, path, "runtime/src/bindings/jsc/runtime/") != null;
    if (std.mem.indexOf(u8, bytes, "std::make_unique") != null)
        try appendFailure(failures, path, "binding allocations must use checked nothrow paths");
    if (std.mem.indexOf(u8, bytes, "adoptRef(new") != null)
        try appendFailure(failures, path, "binding RefCounted allocation must use a checked factory");
    if (std.mem.indexOf(u8, bytes, "adoptRef(*new") != null and
        std.mem.indexOf(u8, path, "/webcore_port/") == null)
        try appendFailure(failures, path, "binding RefCounted allocation must use a checked factory");
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        if (std.mem.indexOf(u8, line, "= new ") == null)
            continue;
        if (std.mem.indexOf(u8, line, "new (std::nothrow)") != null)
            continue;
        if (std.mem.indexOf(u8, line, "new (NotNull,") != null)
            continue;
        try appendLineFailure(failures, path, line_no, "binding allocation must be explicit nothrow or JSC cell allocation");
    }
    var runtime_lines = std.mem.splitScalar(u8, bytes, '\n');
    var runtime_line_no: usize = 1;
    while (runtime_lines.next()) |line| : (runtime_line_no += 1) {
        if (is_jsc_runtime and
            std.mem.indexOf(u8, line, ".reserveInitialCapacity(") != null and
            std.mem.indexOf(u8, line, "tryReserveInitialCapacity") == null)
        {
            try appendLineFailure(failures, path, runtime_line_no, "JSC runtime reserves must be checked");
        }
        if (is_jsc_runtime and
            (std.mem.indexOf(u8, line, "module_sources.set(") != null or
                std.mem.indexOf(u8, line, "module_sources.add(") != null or
                std.mem.indexOf(u8, line, "module_sources.insert(") != null or
                std.mem.indexOf(u8, line, "module_sources.append(") != null or
                std.mem.indexOf(u8, line, "module_sources.tryAppend(") != null or
                std.mem.indexOf(u8, line, "module_sources.reserve") != null))
        {
            try appendLineFailure(failures, path, runtime_line_no, "module source registry insertion must be checked");
        }
    }
    if (is_jsc_runtime) {
        var exception_search_start: usize = 0;
        while (std.mem.indexOfPos(u8, bytes, exception_search_start, "scope.exception()->value()")) |offset| {
            const window = bytes[offset..@min(bytes.len, offset + 512)];
            if (std.mem.indexOf(u8, window, "clearExceptionExceptTermination()") == null)
                try appendLineFailure(failures, path, lineNumberAt(bytes, offset), "caught JS exceptions must be cleared before ABI return");
            exception_search_start = offset + 1;
        }
    }
    const is_node_fs_facade = std.mem.eql(u8, path, "runtime/src/bindings/host_functions/node/fs.cpp");
    if (std.mem.indexOf(u8, bytes, "mmap(") != null or
        (!is_node_fs_facade and std.mem.indexOf(u8, bytes, "fstat(") != null))
    {
        try appendFailure(failures, path, "binding layer must not own fd mapping policy");
    }
}

fn checkNoDirectGatewayFdField(path: []const u8, bytes: []const u8, failures: *FailureList) !void {
    if (std.mem.indexOf(u8, bytes, "egress_" ++ "gateway_fd") != null)
        try appendFailure(failures, path, "workers must use shared rings/eventfds, not a direct gateway fd field");
}

// The worker runtime is the `collo_worker` module and the `runtime/src/worker/`
// tree. The gateway's own `worker_registry.zig` and `runtime/worker_flow.zig`
// share the prefix, so a relative import counts only when it enters a
// `worker/` directory.
fn checkNoWorkerImportsFromEgress(path: []const u8, bytes: []const u8, failures: *FailureList) !void {
    if (std.mem.indexOf(u8, bytes, "@import(\"collo_" ++ "worker") != null or
        std.mem.indexOf(u8, bytes, "@import(\"../worker/") != null or
        std.mem.indexOf(u8, bytes, "@import(\"../../worker/") != null or
        std.mem.indexOf(u8, bytes, "@import(\"runtime/src/worker") != null)
        try appendFailure(failures, path, "egress transport must not import worker runtime");
}

fn checkNoGatewayOrClientImportsFromWorkerEgress(
    path: []const u8,
    bytes: []const u8,
    failures: *FailureList,
) !void {
    if (std.mem.indexOf(u8, bytes, "@import(\"collo_" ++ "egress_client") != null or
        std.mem.indexOf(u8, bytes, "@import(\"collo_" ++ "egress_gateway") != null or
        std.mem.indexOf(u8, bytes, "@import(\"collo_" ++ "server") != null)
    {
        try appendFailure(failures, path, "worker egress must use egress core plus IPC, not gateway/client");
    }
}

fn checkNoRuntimeOwnerImportsFromEgressCore(
    path: []const u8,
    bytes: []const u8,
    failures: *FailureList,
) !void {
    if (std.mem.indexOf(u8, bytes, "@import(\"collo_" ++ "egress_client") != null or
        std.mem.indexOf(u8, bytes, "@import(\"collo_" ++ "egress_gateway") != null or
        std.mem.indexOf(u8, bytes, "@import(\"collo_" ++ "server") != null or
        std.mem.indexOf(u8, bytes, "@import(\"collo_" ++ "worker") != null)
    {
        try appendFailure(failures, path, "egress core must not import runtime owners");
    }
}

// The gateway is a process of its own and the server's peer, so it compiles
// no server module; the server reaches the files both processes compile
// through `collo_egress_gateway`, never the reverse.
fn checkNoServerImportsFromGateway(path: []const u8, bytes: []const u8, failures: *FailureList) !void {
    if (std.mem.indexOf(u8, bytes, "@import(\"collo_" ++ "server") != null)
        try appendFailure(failures, path, "the egress gateway must not import server modules");
}

// The gateway module also holds the gateway process's loop, shards and engines,
// which the server must never call. Server code therefore binds only the files
// both processes compile, each straight off the import, so no alias of the
// whole module can reach the rest.
fn checkServerReadsOnlyGatewayContract(path: []const u8, bytes: []const u8, failures: *FailureList) !void {
    const gateway_import = "@import(\"collo_" ++ "egress_gateway\")";
    const shared_files = [_][]const u8{ ".control;", ".launch;", ".policy;", ".sizing;" };
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, start, gateway_import)) |at| {
        start = at + gateway_import.len;
        const after = bytes[start..];
        for (shared_files) |shared| {
            if (std.mem.startsWith(u8, after, shared))
                break;
        } else {
            try appendFailure(
                failures,
                path,
                "server code reads only control, launch, policy and sizing from the egress gateway",
            );
        }
    }
}

fn checkFetchBodyReleaseSource(path: []const u8, bytes: []const u8, failures: *FailureList) !void {
    const forbidden_old_drain = "drainQueued" ++ "CreditsForRelease";
    if (std.mem.indexOf(u8, bytes, forbidden_old_drain) != null) {
        try appendFailure(failures, path, "queued-credit release must not return allocated slices");
    }

    const forbidden_release_chunks = "pub fn releaseQueued" ++ "Chunks(";
    if (std.mem.indexOf(u8, bytes, forbidden_release_chunks) != null) {
        try appendFailure(failures, path, "releaseQueuedChunks must use a Callback suffix");
    }
    const forbidden_release_preserving = "pub fn releaseQueued" ++ "ChunksPreservingWaiters(";
    if (std.mem.indexOf(u8, bytes, forbidden_release_preserving) != null) {
        try appendFailure(failures, path, "preserving-waiters release must use a Callback suffix");
    }

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        if (std.mem.indexOf(u8, line, "pub fn releaseQueued") == null)
            continue;
        if (std.mem.indexOf(u8, line, "Callback") == null) {
            try appendLineFailure(failures, path, line_no, "queued release API must be callback-only");
        }
        if (std.mem.indexOf(u8, line, "[]Credit") != null) {
            try appendLineFailure(failures, path, line_no, "queued release API must not return credit slices");
        }
    }
}

/// Server code reaches a worker's page only through
/// `common/worker_state/page/snapshots.zig` and the page's ring drains, which
/// load each field once. It loads no shared memory itself, so it holds no
/// `@atomicLoad`; it lends the page view's live slots only to
/// `LiveSlotSnapshot.find` and its usage records only to
/// `RecordCursor.Peeked.copy`, and it never names the page's other parts.
/// Comment lines are not read.
fn checkWorkerPageReads(path: []const u8, bytes: []const u8, failures: *FailureList) !void {
    if (!std.mem.endsWith(u8, path, ".zig"))
        return;
    if (std.mem.indexOf(u8, path, "/tests/") != null)
        return;
    const forbidden = [_][]const u8{
        "@atomicLoad(",
        "records_head",
        "records_tail",
        ".termination_reason",
        ".header.state",
        ".completion_header",
        ".completion_records",
        ".log_header",
        ".log_bytes",
    };
    const lent = [_]LentPageSlice{
        .{ .field = ".live_slots", .reader = "LiveSlotSnapshot.find(" },
        .{ .field = ".completed_records", .reader = ".copy(" },
    };
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var line_no: usize = 0;
    while (lines.next()) |line| {
        line_no += 1;
        if (std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " \t"), "//"))
            continue;
        for (forbidden) |token| {
            if (std.mem.indexOf(u8, line, token) != null)
                try appendWorkerPageReadFailure(failures, path, line_no, token);
        }
        const line_offset = @intFromPtr(line.ptr) - @intFromPtr(bytes.ptr);
        for (lent) |slice| {
            var search: usize = 0;
            while (std.mem.indexOfPos(u8, line, search, slice.field)) |at| : (search = at + slice.field.len) {
                const after = at + slice.field.len;
                if (after < line.len and isIdentifierByte(line[after]))
                    continue;
                if (!lentOnlyTo(bytes[0 .. line_offset + at], slice.reader))
                    try appendWorkerPageReadFailure(failures, path, line_no, slice.field);
            }
        }
    }
}

/// A slice of the page view that server code may name only as the argument
/// of `reader`.
const LentPageSlice = struct {
    field: []const u8,
    reader: []const u8,
};

/// Whether the text before a field access ends in `reader` once the access's
/// receiver and the whitespace before it are stripped, as in
/// `LiveSlotSnapshot.find(metrics.live_slots` or the same call `zig fmt`
/// wrapped onto several lines.
fn lentOnlyTo(before_field: []const u8, reader: []const u8) bool {
    var end = before_field.len;
    while (end > 0 and isReceiverByte(before_field[end - 1]))
        end -= 1;
    while (end > 0 and std.ascii.isWhitespace(before_field[end - 1]))
        end -= 1;
    return std.mem.endsWith(u8, before_field[0..end], reader);
}

fn isIdentifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn isReceiverByte(byte: u8) bool {
    return isIdentifierByte(byte) or byte == '.' or byte == '?';
}

fn appendWorkerPageReadFailure(failures: *FailureList, path: []const u8, line_no: usize, token: []const u8) !void {
    try appendFailureMessage(
        failures,
        "{s}:{d}: `{s}`: server code reads a worker's page only through page/snapshots.zig and the ring drains",
        .{ path, line_no, token },
    );
}

fn checkTcpSocketOptionsCentralized(path: []const u8, bytes: []const u8, failures: *FailureList) !void {
    const helper_path = "runtime/src/common/os.zig";
    const test_path = "runtime/src/common/tests/os.zig";
    if (std.mem.eql(u8, path, helper_path) or
        std.mem.eql(u8, path, test_path) or
        std.mem.eql(u8, path, "runtime/tests/conventions.zig"))
    {
        return;
    }

    if (std.mem.indexOf(u8, bytes, "TCP.NODELAY") != null or
        std.mem.indexOf(u8, bytes, "TCP_NODELAY") != null)
    {
        try appendFailure(failures, path, "TCP_NODELAY must go through collo_os.socket.setTcpNoDelay");
    }
    if (std.mem.indexOf(u8, bytes, "TCP.NOTSENT_LOWAT") != null) {
        try appendFailure(
            failures,
            path,
            "TCP_NOTSENT_LOWAT must go through collo_os.socket.setTcpNotSentLowAt",
        );
    }
    // The socket-level options of a listening socket. Comments name them in
    // their C spelling, so only the Zig one counts.
    const listener_options = [_]struct { token: []const u8, helper: []const u8 }{
        .{ .token = "SO.REUSEADDR", .helper = "setReuseAddress" },
        .{ .token = "SO.REUSEPORT", .helper = "setReusePort" },
        .{ .token = "SO.INCOMING_CPU", .helper = "setIncomingCpu" },
    };
    for (listener_options) |option| {
        if (std.mem.indexOf(u8, bytes, option.token) != null) {
            try appendFailureMessage(failures, "{s}: {s} must go through collo_os.socket.{s}", .{
                path,
                option.token,
                option.helper,
            });
        }
    }
}

fn isImportOrIncludeLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    return std.mem.indexOf(u8, trimmed, "@import(") != null or
        std.mem.startsWith(u8, trimmed, "#include");
}

fn containsForbiddenImportTarget(line: []const u8) bool {
    const forbidden = [_][]const u8{
        "reference/",
        // The control plane's TypeScript tree. A bare `platform/` would also
        // match the bindings' own `host_functions/webapi/platform/` headers.
        "platform/services",
        "platform/apps",
        "platform/packages",
        "platform/sdk",
        ".zig-cache",
        "zig-out",
        "/tmp/collo-cache",
        "WebKitBuild",
    };
    for (forbidden) |needle| {
        if (std.mem.indexOf(u8, line, needle) != null)
            return true;
    }
    return false;
}

fn hasDeprecatedDebugAllocatorInit(bytes: []const u8) !bool {
    const debug_allocator_type = "Debug" ++ "Allocator" ++ "(.{})";
    const compact = try compactAsciiWhitespace(bytes);
    defer std.testing.allocator.free(compact);

    if (std.mem.indexOf(u8, compact, debug_allocator_type ++ "{}") != null)
        return true;

    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, bytes, search_from, debug_allocator_type)) |found| {
        search_from = found + debug_allocator_type.len;
        const declaration_end = declarationTerminator(bytes, search_from);
        const window = bytes[search_from..declaration_end];
        const equals = std.mem.indexOfScalar(u8, window, '=') orelse continue;
        if (std.mem.indexOf(u8, window[equals + 1 ..], ".{}") != null)
            return true;
    }
    return false;
}

fn declarationTerminator(bytes: []const u8, start: usize) usize {
    var cursor = start;
    while (cursor < bytes.len) : (cursor += 1) {
        switch (bytes[cursor]) {
            ';', ',' => return cursor,
            else => {},
        }
    }
    return bytes.len;
}

fn compactAsciiWhitespace(bytes: []const u8) ![]u8 {
    var compact = try std.testing.allocator.alloc(u8, bytes.len);
    errdefer std.testing.allocator.free(compact);

    var len: usize = 0;
    for (bytes) |byte| {
        switch (byte) {
            ' ', '\t', '\n', '\r' => {},
            else => {
                compact[len] = byte;
                len += 1;
            },
        }
    }
    return std.testing.allocator.realloc(compact, len);
}

fn isCheckedSource(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".zig") or
        std.mem.endsWith(u8, path, ".cpp") or
        std.mem.endsWith(u8, path, ".h") or
        std.mem.endsWith(u8, path, ".js") or
        std.mem.endsWith(u8, path, ".md");
}

fn isSilentCatchAll(trimmed_line: []const u8) bool {
    return std.mem.eql(u8, trimmed_line, "else => return,") or
        std.mem.eql(u8, trimmed_line, "else => {},") or
        std.mem.eql(u8, trimmed_line, "else => {}");
}

fn lineNumberAt(bytes: []const u8, offset: usize) usize {
    var line_no: usize = 1;
    for (bytes[0..@min(offset, bytes.len)]) |byte| {
        if (byte == '\n')
            line_no += 1;
    }
    return line_no;
}

/// With libc linked, `std.posix.errno` reads the libc `errno` only when the
/// return equals -1 and reports success otherwise. A raw `std.os.linux`
/// syscall returns the negated error as a `usize`, never -1, and never sets
/// `errno`, so every raw failure decodes as success and the error branch
/// never runs. Raw returns go through `collo_os.linux.syscallErrno` or
/// `std.os.linux.E.init`; `std.posix.errno` is accepted only within
/// `libc_context_window` lines after a libc (`std.c.*`) call.
fn checkRawSyscallErrnoDecode(path: []const u8, bytes: []const u8, failures: *FailureList) !void {
    if (!std.mem.endsWith(u8, path, ".zig"))
        return;
    // Wide enough for a libc call split over several lines, as a
    // `std.c.socketpair` call in a test helper is, while still tying the
    // decode to its call.
    const libc_context_window: usize = 10;
    var recent: [libc_context_window][]const u8 = @splat("");
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        defer recent[(line_no - 1) % libc_context_window] = line;
        if (std.mem.indexOf(u8, line, "std.posix.errno(") == null)
            continue;
        if (std.mem.indexOf(u8, line, "std.c.") != null)
            continue;
        var has_libc_context = false;
        for (recent) |previous| {
            if (std.mem.indexOf(u8, previous, "std.c.") != null) {
                has_libc_context = true;
                break;
            }
        }
        if (!has_libc_context)
            try appendLineFailure(failures, path, line_no, "raw syscall return decoded with std.posix.errno; use collo_os.linux.syscallErrno or std.os.linux.E.init");
    }
}

fn appendLineFailure(failures: *FailureList, path: []const u8, line_no: usize, reason: []const u8) !void {
    const message = try std.fmt.allocPrint(std.testing.allocator, "{s}:{d}: {s}", .{ path, line_no, reason });
    try failures.append(std.testing.allocator, message);
}

fn appendFailure(failures: *FailureList, path: []const u8, reason: []const u8) !void {
    const message = try std.fmt.allocPrint(std.testing.allocator, "{s}: {s}", .{ path, reason });
    try failures.append(std.testing.allocator, message);
}

fn expectNoFailures(failures: *FailureList, err: anyerror) !void {
    if (failures.items.len == 0)
        return;
    for (failures.items) |failure|
        std.debug.print("{s}\n", .{failure});
    return err;
}

fn readFile(path: []const u8, max_bytes: usize) ![]u8 {
    return std.fs.cwd().readFileAlloc(std.testing.allocator, path, max_bytes);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) != null) {
        std.debug.print("unexpected text remains: {s}\n", .{needle});
        return error.UnexpectedText;
    }
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("expected text is missing: {s}\n", .{needle});
        return error.ExpectedTextMissing;
    }
}

fn extractFunctionBody(bytes: []const u8, signature: []const u8) ![]const u8 {
    const signature_start = std.mem.indexOf(u8, bytes, signature) orelse return error.ExpectedTextMissing;
    const open_offset = std.mem.indexOfScalarPos(u8, bytes, signature_start, '{') orelse return error.ExpectedTextMissing;

    var depth: usize = 0;
    var cursor = open_offset;
    while (cursor < bytes.len) : (cursor += 1) {
        switch (bytes[cursor]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0)
                    return bytes[open_offset + 1 .. cursor];
            },
            else => {},
        }
    }
    return error.ExpectedTextMissing;
}
