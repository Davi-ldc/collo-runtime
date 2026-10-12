//! The fs index without a worker: lexical path normalization, namespace
//! classification, listings from the index, the route, listing and
//! copy-path exports the binding calls through abi.h, and the seal and parse
//! checks of `initWorkerForTest`. The namespace setup `initWorker` does
//! inside a worker's chroot, the binding's EROFS and ENOENT answers and
//! faulted reads are covered by the zygote-integration lane
//! (`runtime/tests/integration/zygote.zig`).

const std = @import("std");
const bindings = @import("collo_bindings");
const worker = @import("collo_worker");
const fd_mod = @import("collo_os").fd;

const fs = worker.fs;
const fs_index = fs.fs_index;

fn abiString(bytes: []const u8) bindings.RawString {
    return .{ .ptr = bytes.ptr, .len = bytes.len };
}

/// Routes `path` through `collo_runtime_fs_route` and expects OK with the
/// route class `expected`.
fn expectRouteClass(
    expected: bindings.FsRouteClass,
    path: []const u8,
    out_path: []u8,
    route: *bindings.FsRoute,
) !void {
    try std.testing.expectEqual(
        bindings.status_ok,
        fs.collo_runtime_fs_route(abiString(path), out_path.ptr, out_path.len, route),
    );
    try std.testing.expectEqual(@intFromEnum(expected), route.route_class);
}

/// Lists one entry of `dir` through `collo_runtime_fs_readdir_next`.
fn readdirNext(
    dir: []const u8,
    cursor: *u64,
    name: []u8,
    name_len: *u32,
    is_dir: *u8,
) bindings.RawStatus {
    return fs.collo_runtime_fs_readdir_next(abiString(dir), cursor, name.ptr, name.len, name_len, is_dir);
}

// Canonical fixture: byte-ascending paths, one root file, one nested tree,
// one deep chain proving immediate-children dedup.
const fixture_files = [_]fs_index.File{
    .{ .path = "assets/logo.svg", .size = 512, .sha256 = @splat(0x11) },
    .{ .path = "data/config.json", .size = 42, .sha256 = @splat(0x22) },
    .{ .path = "data/nested/deep.txt", .size = 7, .sha256 = @splat(0x33) },
    .{ .path = "data/other.txt", .size = 9, .sha256 = @splat(0x44) },
    .{ .path = "index.js", .size = 100, .sha256 = @splat(0x55) },
};

const fixture_mtime_ms: u64 = 1_730_000_000_123;

fn buildFixtureIndexBytes(allocator: std.mem.Allocator) ![]u8 {
    return fs_index.buildIndexBytes(allocator, fixture_mtime_ms, &fixture_files);
}

test "normalizePath resolves relative paths against the cwd" {
    var buffer: [fs.max_normalized_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/var/task/data/config.json",
        try fs.normalizePath("/var/task", "data/config.json", &buffer),
    );
    try std.testing.expectEqualStrings(
        "/var/task/data/config.json",
        try fs.normalizePath("/var/task", "./data//config.json", &buffer),
    );
    // A relative path starting with `tmp` stays inside the tree; only the
    // absolute /tmp reaches the scratch.
    try std.testing.expectEqualStrings(
        "/var/task/tmp/config.json",
        try fs.normalizePath("/var/task", "./tmp/config.json", &buffer),
    );
    try std.testing.expectEqualStrings(
        "/tmp/x",
        try fs.normalizePath("/tmp/work", "../x", &buffer),
    );
    try std.testing.expectEqualStrings(
        "/var",
        try fs.normalizePath("/var/task", "..", &buffer),
    );
    try std.testing.expectEqualStrings(
        "/var/task",
        try fs.normalizePath("/var/task", ".", &buffer),
    );
    try std.testing.expectEqualStrings(
        "/",
        try fs.normalizePath("/", ".", &buffer),
    );
}

test "normalizePath keeps absolute paths and folds dot segments" {
    var buffer: [fs.max_normalized_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/tmp/a/b",
        try fs.normalizePath("/", "/tmp//./a/c/../b/", &buffer),
    );
    try std.testing.expectEqualStrings(
        "/",
        try fs.normalizePath("/", "/..", &buffer),
    );
}

test "normalizePath clamps dot-dot escapes at the root" {
    var buffer: [fs.max_normalized_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/etc/passwd",
        try fs.normalizePath("/", "../../../../etc/passwd", &buffer),
    );
}

test "normalizePath rejects paths beyond PATH_MAX" {
    var buffer: [fs.max_normalized_bytes]u8 = undefined;
    const long_input = "a" ** fs.max_normalized_bytes;
    try std.testing.expectError(
        error.PathTooLong,
        fs.normalizePath("/", long_input, &buffer),
    );
    // Short input growing past the limit through the cwd seed.
    const long_cwd = "/" ++ ("b" ** (fs.max_normalized_bytes - 8));
    try std.testing.expectError(
        error.PathTooLong,
        fs.normalizePath(long_cwd, "ccccccccccc", &buffer),
    );
}

test "classify splits tmp, deploy files, derived dirs, virtual ancestors, and nothing" {
    const bytes = try buildFixtureIndexBytes(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    const view = try fs.IndexView.parse(bytes);

    try std.testing.expectEqual(fs.Class.tmp, fs.classify(&view, "/tmp").class);
    try std.testing.expectEqual(fs.Class.tmp, fs.classify(&view, "/tmp/anything/at/all").class);
    // "/tmpx" is not the scratch: the prefix must end at a segment boundary.
    try std.testing.expectEqual(fs.Class.none, fs.classify(&view, "/tmpx").class);

    // `deploy_root` always exists as a directory, and the cwd's ancestors
    // "/" and "/var" are virtual directories.
    try std.testing.expectEqual(fs.Class.deploy_dir, fs.classify(&view, "/var/task").class);
    try std.testing.expectEqual(fs.Class.deploy_dir, fs.classify(&view, "/var/task/data").class);
    try std.testing.expectEqual(fs.Class.deploy_dir, fs.classify(&view, "/var/task/data/nested").class);
    try std.testing.expectEqual(fs.Class.deploy_dir, fs.classify(&view, "/").class);
    try std.testing.expectEqual(fs.Class.deploy_dir, fs.classify(&view, "/var").class);
    // The `deploy_root` prefix must end at a segment boundary too.
    try std.testing.expectEqual(fs.Class.none, fs.classify(&view, "/var/taskx").class);

    const routed = fs.classify(&view, "/var/task/data/config.json");
    try std.testing.expectEqual(fs.Class.deploy_file, routed.class);
    try std.testing.expectEqual(@as(u64, 42), view.entrySizeAt(routed.entry));

    // Index paths exist only under `deploy_root`, not under "/".
    try std.testing.expectEqual(fs.Class.none, fs.classify(&view, "/data/config.json").class);
    // A file is not a dir and a dir is not a file.
    try std.testing.expectEqual(fs.Class.none, fs.classify(&view, "/var/task/data/config.json/inner").class);
    try std.testing.expectEqual(fs.Class.none, fs.classify(&view, "/var/task/missing").class);
    try std.testing.expectEqual(fs.Class.none, fs.classify(&view, "/var/task/data/nested/missing.txt").class);
    // Outside all namespaces: invisible.
    try std.testing.expectEqual(fs.Class.none, fs.classify(&view, "/etc/passwd").class);
    try std.testing.expectEqual(fs.Class.none, fs.classify(&view, "/var/other").class);
}

test "deploy tmp/ entry is not shadowed by the /tmp scratch (FW1 finding 3 regression)" {
    // An index entry whose first segment is `tmp` must stay a visible,
    // read-only file of the tree. Relative to the cwd, `./tmp/config.json`
    // names that file, while the absolute `/tmp/config.json` is an unrelated
    // scratch path.
    const bytes = try fs_index.buildIndexBytes(std.testing.allocator, fixture_mtime_ms, &.{
        .{ .path = "index.js", .size = 100, .sha256 = @splat(0x55) },
        .{ .path = "tmp/config.json", .size = 9, .sha256 = @splat(0x66) },
    });
    defer std.testing.allocator.free(bytes);
    try fs.installForTest(bytes, fs.deploy_root);
    defer fs.uninstallForTest();

    var out_path: [fs.max_normalized_bytes]u8 = undefined;
    var route: bindings.FsRoute = undefined;

    // The relative path is the file of the tree. The binding answers EROFS
    // to a mutation of any class other than tmp.
    try expectRouteClass(.deploy_file, "./tmp/config.json", &out_path, &route);
    try std.testing.expectEqualStrings("/var/task/tmp/config.json", out_path[0..route.normalized_len]);
    try std.testing.expectEqual(@as(u64, 9), route.size);

    // The tree's `tmp` directory is a directory of the tree, not the scratch.
    try expectRouteClass(.deploy_dir, "tmp", &out_path, &route);
    try std.testing.expectEqualStrings("/var/task/tmp", out_path[0..route.normalized_len]);

    // The absolute path is scratch, whatever the index holds under the same
    // name.
    try expectRouteClass(.tmp, "/tmp/config.json", &out_path, &route);
    try std.testing.expectEqualStrings("/tmp/config.json", out_path[0..route.normalized_len]);
}

test "DirIter lists immediate children with dedup, in index order" {
    const bytes = try buildFixtureIndexBytes(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    const view = try fs.IndexView.parse(bytes);

    var root_iter = fs.DirIter.init(&view, "/");
    const first = root_iter.next().?;
    try std.testing.expectEqualStrings("assets", first.name);
    try std.testing.expect(first.is_dir);
    const second = root_iter.next().?;
    try std.testing.expectEqualStrings("data", second.name);
    try std.testing.expect(second.is_dir);
    const third = root_iter.next().?;
    try std.testing.expectEqualStrings("index.js", third.name);
    try std.testing.expect(!third.is_dir);
    try std.testing.expectEqual(@as(?fs.DirEntry, null), root_iter.next());

    var data_iter = fs.DirIter.init(&view, "/data");
    const config = data_iter.next().?;
    try std.testing.expectEqualStrings("config.json", config.name);
    try std.testing.expect(!config.is_dir);
    const nested = data_iter.next().?;
    try std.testing.expectEqualStrings("nested", nested.name);
    try std.testing.expect(nested.is_dir);
    const other = data_iter.next().?;
    try std.testing.expectEqualStrings("other.txt", other.name);
    try std.testing.expect(!other.is_dir);
    try std.testing.expectEqual(@as(?fs.DirEntry, null), data_iter.next());
}

test "collo_runtime_fs_route classifies and synthesizes deploy metadata" {
    const bytes = try buildFixtureIndexBytes(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try fs.installForTest(bytes, fs.deploy_root);
    defer fs.uninstallForTest();

    var out_path: [fs.max_normalized_bytes]u8 = undefined;
    var route: bindings.FsRoute = undefined;

    // A relative path of a file in the tree reports its size, with the
    // index's `mtime_ms`.
    try expectRouteClass(.deploy_file, "data/config.json", &out_path, &route);
    try std.testing.expectEqual(@as(u64, 42), route.size);
    try std.testing.expectEqual(fixture_mtime_ms, route.mtime_ms);
    try std.testing.expectEqualStrings("/var/task/data/config.json", out_path[0..route.normalized_len]);
    try std.testing.expectEqual(@as(u8, 0), out_path[route.normalized_len]);

    // A directory derived from the entries' prefixes.
    try expectRouteClass(.deploy_dir, "data", &out_path, &route);
    try std.testing.expectEqual(fixture_mtime_ms, route.mtime_ms);

    // An absolute path under `deploy_root`.
    try expectRouteClass(.deploy_file, "/var/task/index.js", &out_path, &route);
    try std.testing.expectEqual(@as(u64, 100), route.size);

    // /tmp passthrough with a normalized escape attempt folded inside it.
    try expectRouteClass(.tmp, "/tmp/a/../b", &out_path, &route);
    try std.testing.expectEqualStrings("/tmp/b", out_path[0..route.normalized_len]);

    // Climbing above the root stops at "/", and the result lies outside
    // every namespace.
    try expectRouteClass(.none, "../../../etc/passwd", &out_path, &route);
    try std.testing.expectEqualStrings("/etc/passwd", out_path[0..route.normalized_len]);

    // The cwd ancestor chain stats as virtual read-only dirs.
    try expectRouteClass(.deploy_dir, "..", &out_path, &route);
    try std.testing.expectEqualStrings("/var", out_path[0..route.normalized_len]);
    try expectRouteClass(.deploy_dir, "/", &out_path, &route);

    // A path of `max_normalized_bytes` bytes is too long.
    const long_input = "x" ** fs.max_normalized_bytes;
    try std.testing.expectEqual(
        bindings.status_invalid_argument,
        fs.collo_runtime_fs_route(abiString(long_input), &out_path, out_path.len, &route),
    );
}

test "collo_runtime_fs_route fails and clears its route without an installed index" {
    var out_path: [fs.max_normalized_bytes]u8 = undefined;
    // A stale route from an earlier call, which the failing call clears.
    var route: bindings.FsRoute = .{
        .size = 1,
        .mtime_ms = 1,
        .normalized_len = 1,
        .route_class = @intFromEnum(bindings.FsRouteClass.tmp),
    };
    try std.testing.expect(!fs.isInitialized());
    try std.testing.expectEqual(
        bindings.status_error,
        fs.collo_runtime_fs_route(abiString("x"), &out_path, out_path.len, &route),
    );
    try std.testing.expectEqual(bindings.FsRoute{}, route);
}

test "collo_runtime_fs_readdir_next walks a deploy dir statelessly" {
    const bytes = try buildFixtureIndexBytes(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try fs.installForTest(bytes, fs.deploy_root);
    defer fs.uninstallForTest();

    var cursor: u64 = bindings.fs_readdir_cursor_start;
    var name: [bindings.fs_name_bytes_max]u8 = undefined;
    var name_len: u32 = 0;
    var is_dir: u8 = 0;

    const Expected = struct { name: []const u8, is_dir: bool };
    const expected = [_]Expected{
        .{ .name = "config.json", .is_dir = false },
        .{ .name = "nested", .is_dir = true },
        .{ .name = "other.txt", .is_dir = false },
    };
    const data_dir = "/var/task/data";
    for (expected) |entry| {
        try std.testing.expectEqual(
            bindings.status_ok,
            readdirNext(data_dir, &cursor, &name, &name_len, &is_dir),
        );
        try std.testing.expectEqualStrings(entry.name, name[0..name_len]);
        try std.testing.expectEqual(@intFromBool(entry.is_dir), is_dir);
    }
    try std.testing.expectEqual(
        bindings.status_not_found,
        readdirNext(data_dir, &cursor, &name, &name_len, &is_dir),
    );

    // `deploy_root` lists the top level of the index.
    cursor = bindings.fs_readdir_cursor_start;
    const anchor = fs.deploy_root;
    const anchor_expected = [_]Expected{
        .{ .name = "assets", .is_dir = true },
        .{ .name = "data", .is_dir = true },
        .{ .name = "index.js", .is_dir = false },
    };
    for (anchor_expected) |entry| {
        try std.testing.expectEqual(
            bindings.status_ok,
            readdirNext(anchor, &cursor, &name, &name_len, &is_dir),
        );
        try std.testing.expectEqualStrings(entry.name, name[0..name_len]);
        try std.testing.expectEqual(@intFromBool(entry.is_dir), is_dir);
    }
    try std.testing.expectEqual(
        bindings.status_not_found,
        readdirNext(anchor, &cursor, &name, &name_len, &is_dir),
    );

    // "/" is a virtual directory listing the namespace roots, not the index,
    // and "/var" lists only "task".
    cursor = bindings.fs_readdir_cursor_start;
    const root_expected = [_][]const u8{ "tmp", "var" };
    for (root_expected) |entry_name| {
        try std.testing.expectEqual(
            bindings.status_ok,
            readdirNext("/", &cursor, &name, &name_len, &is_dir),
        );
        try std.testing.expectEqualStrings(entry_name, name[0..name_len]);
        try std.testing.expectEqual(@as(u8, 1), is_dir);
    }
    try std.testing.expectEqual(
        bindings.status_not_found,
        readdirNext("/", &cursor, &name, &name_len, &is_dir),
    );

    cursor = bindings.fs_readdir_cursor_start;
    try std.testing.expectEqual(
        bindings.status_ok,
        readdirNext("/var", &cursor, &name, &name_len, &is_dir),
    );
    try std.testing.expectEqualStrings("task", name[0..name_len]);
    try std.testing.expectEqual(@as(u8, 1), is_dir);
    try std.testing.expectEqual(
        bindings.status_not_found,
        readdirNext("/var", &cursor, &name, &name_len, &is_dir),
    );

    // Neither a directory outside every namespace nor a file of the tree
    // classifies as deploy_dir, so listing either is a misuse of the ABI.
    cursor = bindings.fs_readdir_cursor_start;
    try std.testing.expectEqual(
        bindings.status_error,
        readdirNext("/data", &cursor, &name, &name_len, &is_dir),
    );
    cursor = bindings.fs_readdir_cursor_start;
    try std.testing.expectEqual(
        bindings.status_error,
        readdirNext("/var/task/index.js", &cursor, &name, &name_len, &is_dir),
    );
}

test "collo_runtime_fs_materialized_path joins the materialize root with the index key" {
    const bytes = try buildFixtureIndexBytes(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try fs.installForTest(bytes, fs.deploy_root);
    defer fs.uninstallForTest();

    var out_path: [fs.max_normalized_bytes]u8 = undefined;
    var out_len: usize = 0;

    // `installForTest` copies under `deploy_root`, as a worker does, so the
    // copy's path is the normalized path itself.
    const config = "/var/task/data/config.json";
    try std.testing.expectEqual(
        bindings.status_ok,
        fs.collo_runtime_fs_materialized_path(abiString(config), &out_path, out_path.len, &out_len),
    );
    try std.testing.expectEqualStrings(config, out_path[0..out_len]);
    try std.testing.expectEqual(@as(u8, 0), out_path[out_len]);

    // The root of the tree and paths outside it have no copy, and a buffer
    // without room for the NUL fails with the length cleared.
    try std.testing.expectEqual(
        bindings.status_error,
        fs.collo_runtime_fs_materialized_path(abiString(fs.deploy_root), &out_path, out_path.len, &out_len),
    );
    try std.testing.expectEqual(
        bindings.status_error,
        fs.collo_runtime_fs_materialized_path(abiString("/tmp/x"), &out_path, out_path.len, &out_len),
    );
    out_len = config.len;
    try std.testing.expectEqual(
        bindings.status_error,
        fs.collo_runtime_fs_materialized_path(abiString(config), &out_path, config.len, &out_len),
    );
    try std.testing.expectEqual(@as(usize, 0), out_len);
}

test "placeholder index: anchor exists, everything else is none, tmp still routes" {
    try fs.installForTest(&fs_index.placeholder_bytes, fs.deploy_root);
    defer fs.uninstallForTest();

    var out_path: [fs.max_normalized_bytes]u8 = undefined;
    var route: bindings.FsRoute = undefined;

    // process.cwd(), which is `deploy_root`, must stat even with an empty
    // index.
    try expectRouteClass(.deploy_dir, ".", &out_path, &route);
    try std.testing.expectEqualStrings("/var/task", out_path[0..route.normalized_len]);
    try expectRouteClass(.none, "anything.txt", &out_path, &route);
    try expectRouteClass(.tmp, "/tmp/scratch", &out_path, &route);

    // Listing `deploy_root` of an empty index ends at once.
    var cursor: u64 = bindings.fs_readdir_cursor_start;
    var name: [bindings.fs_name_bytes_max]u8 = undefined;
    var name_len: u32 = 0;
    var is_dir: u8 = 0;
    try std.testing.expectEqual(
        bindings.status_not_found,
        readdirNext(fs.deploy_root, &cursor, &name, &name_len, &is_dir),
    );

    // The virtual root still lists the namespace roots.
    cursor = bindings.fs_readdir_cursor_start;
    try std.testing.expectEqual(
        bindings.status_ok,
        readdirNext("/", &cursor, &name, &name_len, &is_dir),
    );
    try std.testing.expectEqualStrings("tmp", name[0..name_len]);
}

fn createSealedMemfd(bytes: []const u8) !std.posix.fd_t {
    const fd = try std.posix.memfd_create(
        "collo-fs-index-test",
        std.os.linux.MFD.CLOEXEC | std.os.linux.MFD.ALLOW_SEALING,
    );
    errdefer std.posix.close(fd);
    try fd_mod.writeAllRaw(fd, bytes);
    try std.posix.lseek_SET(fd, 0);
    try fd_mod.addSeals(fd, fd_mod.memfd_readonly_seals);
    return fd;
}

test "initWorker maps a sealed valid index and fails closed on garbage" {
    // `initWorkerForTest` runs the seal check, mapping, parse and fd handling
    // of `initWorker`, which also creates and enters `deploy_root` inside a
    // chroot; the zygote-integration lane covers that part. Both failures
    // below happen before the namespace setup.

    // Sealed bytes that are not an index fail with `error.InvalidFsIndex`,
    // which fails a worker's init.
    const garbage_fd = try createSealedMemfd("this is not a COLLOFS1 index");
    try std.testing.expectError(error.InvalidFsIndex, fs.initWorkerForTest(garbage_fd, -1));
    try std.testing.expect(!fs.isInitialized());

    // An unsealed memfd is rejected before any mapping.
    const unsealed_fd = try std.posix.memfd_create("collo-fs-index-unsealed", std.os.linux.MFD.CLOEXEC);
    try fd_mod.writeAllRaw(unsealed_fd, "COLLOFS1");
    try std.testing.expectError(error.MissingFdSeals, fs.initWorkerForTest(unsealed_fd, -1));
    try std.testing.expect(!fs.isInitialized());

    // A valid index installs with `deploy_root` as the cwd and tears down
    // cleanly.
    const bytes = try buildFixtureIndexBytes(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    const valid_fd = try createSealedMemfd(bytes);
    try fs.initWorkerForTest(valid_fd, -1);
    defer fs.deinitWorker();
    try std.testing.expect(fs.isInitialized());
    try std.testing.expectEqual(@as(?u64, fixture_mtime_ms), fs.mtimeMs());

    var out_path: [fs.max_normalized_bytes]u8 = undefined;
    var route: bindings.FsRoute = undefined;
    try expectRouteClass(.deploy_file, "index.js", &out_path, &route);
    try std.testing.expectEqualStrings("/var/task/index.js", out_path[0..route.normalized_len]);
    try std.testing.expectEqual(@as(u64, 100), route.size);
}
