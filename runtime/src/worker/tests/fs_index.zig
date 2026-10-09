//! The fs index without a worker: lexical path normalization, namespace
//! classification, listings from the index, the `collo_worker_fs_*` C ABI
//! the binding calls, and the seal and parse checks of `initWorkerForTest`.
//! The namespace setup `initWorker` does inside a worker's chroot, the
//! binding's EROFS and ENOENT answers and faulted reads are covered by the
//! zygote-integration lane (`runtime/tests/integration/zygote.zig`).

const std = @import("std");
const worker = @import("collo_worker");
const fd_mod = @import("collo_os").fd;

const fs = worker.fs;
const fs_index = fs.fs_index;

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
    var info: fs.RouteInfo = undefined;

    // The relative path is the file of the tree. The binding answers EROFS
    // to a mutation of any class other than tmp.
    try std.testing.expectEqual(
        fs.route_class_deploy_file,
        fs.collo_worker_fs_route(
            "./tmp/config.json",
            "./tmp/config.json".len,
            &out_path,
            out_path.len,
            &info,
        ),
    );
    try std.testing.expectEqualStrings("/var/task/tmp/config.json", out_path[0..info.normalized_len]);
    try std.testing.expectEqual(@as(u64, 9), info.size);

    // The tree's `tmp` directory is a directory of the tree, not the scratch.
    try std.testing.expectEqual(
        fs.route_class_deploy_dir,
        fs.collo_worker_fs_route("tmp", "tmp".len, &out_path, out_path.len, &info),
    );
    try std.testing.expectEqualStrings("/var/task/tmp", out_path[0..info.normalized_len]);

    // The absolute path is scratch, whatever the index holds under the same
    // name.
    try std.testing.expectEqual(
        fs.route_class_tmp,
        fs.collo_worker_fs_route(
            "/tmp/config.json",
            "/tmp/config.json".len,
            &out_path,
            out_path.len,
            &info,
        ),
    );
    try std.testing.expectEqualStrings("/tmp/config.json", out_path[0..info.normalized_len]);
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

test "collo_worker_fs_route classifies and synthesizes deploy metadata" {
    const bytes = try buildFixtureIndexBytes(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try fs.installForTest(bytes, fs.deploy_root);
    defer fs.uninstallForTest();

    var out_path: [fs.max_normalized_bytes]u8 = undefined;
    var info: fs.RouteInfo = undefined;

    // A relative path of a file in the tree reports its size, with the
    // index's `mtime_ms`.
    try std.testing.expectEqual(
        fs.route_class_deploy_file,
        fs.collo_worker_fs_route("data/config.json", "data/config.json".len, &out_path, out_path.len, &info),
    );
    try std.testing.expectEqual(@as(u64, 42), info.size);
    try std.testing.expectEqual(fixture_mtime_ms, info.mtime_ms);
    try std.testing.expectEqualStrings("/var/task/data/config.json", out_path[0..info.normalized_len]);
    try std.testing.expectEqual(@as(u8, 0), out_path[info.normalized_len]);

    // A directory derived from the entries' prefixes.
    try std.testing.expectEqual(
        fs.route_class_deploy_dir,
        fs.collo_worker_fs_route("data", "data".len, &out_path, out_path.len, &info),
    );
    try std.testing.expectEqual(fixture_mtime_ms, info.mtime_ms);

    // An absolute path under `deploy_root`.
    try std.testing.expectEqual(
        fs.route_class_deploy_file,
        fs.collo_worker_fs_route(
            "/var/task/index.js",
            "/var/task/index.js".len,
            &out_path,
            out_path.len,
            &info,
        ),
    );
    try std.testing.expectEqual(@as(u64, 100), info.size);

    // /tmp passthrough with a normalized escape attempt folded inside it.
    try std.testing.expectEqual(
        fs.route_class_tmp,
        fs.collo_worker_fs_route("/tmp/a/../b", "/tmp/a/../b".len, &out_path, out_path.len, &info),
    );
    try std.testing.expectEqualStrings("/tmp/b", out_path[0..info.normalized_len]);

    // Climbing above the root stops at "/", and the result lies outside
    // every namespace.
    try std.testing.expectEqual(
        fs.route_class_none,
        fs.collo_worker_fs_route("../../../etc/passwd", "../../../etc/passwd".len, &out_path, out_path.len, &info),
    );
    try std.testing.expectEqualStrings("/etc/passwd", out_path[0..info.normalized_len]);

    // The cwd ancestor chain stats as virtual read-only dirs.
    try std.testing.expectEqual(
        fs.route_class_deploy_dir,
        fs.collo_worker_fs_route("..", "..".len, &out_path, out_path.len, &info),
    );
    try std.testing.expectEqualStrings("/var", out_path[0..info.normalized_len]);
    try std.testing.expectEqual(
        fs.route_class_deploy_dir,
        fs.collo_worker_fs_route("/", "/".len, &out_path, out_path.len, &info),
    );

    // A path of `max_normalized_bytes` bytes is too long.
    const long_input = "x" ** fs.max_normalized_bytes;
    try std.testing.expectEqual(
        fs.route_error_too_long,
        fs.collo_worker_fs_route(long_input, long_input.len, &out_path, out_path.len, &info),
    );
}

test "collo_worker_fs_route fails internal without an installed index" {
    var out_path: [fs.max_normalized_bytes]u8 = undefined;
    var info: fs.RouteInfo = undefined;
    try std.testing.expect(!fs.isInitialized());
    try std.testing.expectEqual(
        fs.route_error_internal,
        fs.collo_worker_fs_route("x", 1, &out_path, out_path.len, &info),
    );
}

test "collo_worker_fs_readdir_next walks a deploy dir statelessly" {
    const bytes = try buildFixtureIndexBytes(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    try fs.installForTest(bytes, fs.deploy_root);
    defer fs.uninstallForTest();

    var cursor: u64 = fs.readdir_cursor_start;
    var name: [fs_index.path_bytes_max + 1]u8 = undefined;
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
            @as(i32, 1),
            fs.collo_worker_fs_readdir_next(data_dir, data_dir.len, &cursor, &name, name.len, &name_len, &is_dir),
        );
        try std.testing.expectEqualStrings(entry.name, name[0..name_len]);
        try std.testing.expectEqual(@intFromBool(entry.is_dir), is_dir);
    }
    try std.testing.expectEqual(
        @as(i32, 0),
        fs.collo_worker_fs_readdir_next(data_dir, data_dir.len, &cursor, &name, name.len, &name_len, &is_dir),
    );

    // `deploy_root` lists the top level of the index.
    cursor = fs.readdir_cursor_start;
    const anchor = fs.deploy_root;
    const anchor_expected = [_]Expected{
        .{ .name = "assets", .is_dir = true },
        .{ .name = "data", .is_dir = true },
        .{ .name = "index.js", .is_dir = false },
    };
    for (anchor_expected) |entry| {
        try std.testing.expectEqual(
            @as(i32, 1),
            fs.collo_worker_fs_readdir_next(anchor, anchor.len, &cursor, &name, name.len, &name_len, &is_dir),
        );
        try std.testing.expectEqualStrings(entry.name, name[0..name_len]);
        try std.testing.expectEqual(@intFromBool(entry.is_dir), is_dir);
    }
    try std.testing.expectEqual(
        @as(i32, 0),
        fs.collo_worker_fs_readdir_next(anchor, anchor.len, &cursor, &name, name.len, &name_len, &is_dir),
    );

    // "/" is a virtual directory listing the namespace roots, not the index,
    // and "/var" lists only "task".
    cursor = fs.readdir_cursor_start;
    const root_expected = [_][]const u8{ "tmp", "var" };
    for (root_expected) |entry_name| {
        try std.testing.expectEqual(
            @as(i32, 1),
            fs.collo_worker_fs_readdir_next("/", "/".len, &cursor, &name, name.len, &name_len, &is_dir),
        );
        try std.testing.expectEqualStrings(entry_name, name[0..name_len]);
        try std.testing.expectEqual(@as(u8, 1), is_dir);
    }
    try std.testing.expectEqual(
        @as(i32, 0),
        fs.collo_worker_fs_readdir_next("/", "/".len, &cursor, &name, name.len, &name_len, &is_dir),
    );

    cursor = fs.readdir_cursor_start;
    try std.testing.expectEqual(
        @as(i32, 1),
        fs.collo_worker_fs_readdir_next("/var", "/var".len, &cursor, &name, name.len, &name_len, &is_dir),
    );
    try std.testing.expectEqualStrings("task", name[0..name_len]);
    try std.testing.expectEqual(@as(u8, 1), is_dir);
    try std.testing.expectEqual(
        @as(i32, 0),
        fs.collo_worker_fs_readdir_next("/var", "/var".len, &cursor, &name, name.len, &name_len, &is_dir),
    );

    // A directory outside every namespace never classifies as deploy_dir,
    // so the iterator treats it as a misuse of the ABI.
    cursor = fs.readdir_cursor_start;
    try std.testing.expectEqual(
        fs.route_error_internal,
        fs.collo_worker_fs_readdir_next("/data", "/data".len, &cursor, &name, name.len, &name_len, &is_dir),
    );
}

test "placeholder index: anchor exists, everything else is none, tmp still routes" {
    try fs.installForTest(&fs_index.placeholder_bytes, fs.deploy_root);
    defer fs.uninstallForTest();

    var out_path: [fs.max_normalized_bytes]u8 = undefined;
    var info: fs.RouteInfo = undefined;

    // process.cwd(), which is `deploy_root`, must stat even with an empty
    // index.
    try std.testing.expectEqual(
        fs.route_class_deploy_dir,
        fs.collo_worker_fs_route(".", ".".len, &out_path, out_path.len, &info),
    );
    try std.testing.expectEqualStrings("/var/task", out_path[0..info.normalized_len]);
    try std.testing.expectEqual(
        fs.route_class_none,
        fs.collo_worker_fs_route("anything.txt", "anything.txt".len, &out_path, out_path.len, &info),
    );
    try std.testing.expectEqual(
        fs.route_class_tmp,
        fs.collo_worker_fs_route("/tmp/scratch", "/tmp/scratch".len, &out_path, out_path.len, &info),
    );

    // Listing `deploy_root` of an empty index ends at once.
    var cursor: u64 = fs.readdir_cursor_start;
    var name: [fs_index.path_bytes_max + 1]u8 = undefined;
    var name_len: u32 = 0;
    var is_dir: u8 = 0;
    try std.testing.expectEqual(
        @as(i32, 0),
        fs.collo_worker_fs_readdir_next(fs.deploy_root, fs.deploy_root.len, &cursor, &name, name.len, &name_len, &is_dir),
    );

    // The virtual root still lists the namespace roots.
    cursor = fs.readdir_cursor_start;
    try std.testing.expectEqual(
        @as(i32, 1),
        fs.collo_worker_fs_readdir_next("/", "/".len, &cursor, &name, name.len, &name_len, &is_dir),
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
    var info: fs.RouteInfo = undefined;
    try std.testing.expectEqual(
        fs.route_class_deploy_file,
        fs.collo_worker_fs_route("index.js", "index.js".len, &out_path, out_path.len, &info),
    );
    try std.testing.expectEqualStrings("/var/task/index.js", out_path[0..info.normalized_len]);
    try std.testing.expectEqual(@as(u64, 100), info.size);
}
