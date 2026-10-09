//! The worker's view of its read-only file tree: the binary fs index
//! (`common/ipc/fs_index.zig`), the path routing the C++ fs binding
//! (`bindings/host_functions/node/fs.cpp`) calls through the
//! `collo_worker_fs_*` C ABI, and the worker-global state `fault.zig` uses
//! to copy files of the tree into the tmpfs. Everything runs on the worker's
//! VM thread, and the state is one process global installed per worker child.
//!
//! `initWorker` runs in the worker child after the chroot, so the directories
//! it creates and the cwd it captures are the sandbox's, and before seccomp,
//! which denies the chdir, getcwd and fstatfs it needs. Nothing here may
//! need those calls later. An index that does not parse fails the worker's
//! init; there is no unindexed mode.
//!
//! A path is normalized lexically against the cwd, `deploy_root`, and falls
//! in one namespace:
//! - `/tmp` and below: the writable tmpfs scratch, where the binding issues
//!   the real syscalls.
//! - `deploy_root` and below: the read-only tree, answered from the index.
//!   An index entry is a file, a proper prefix of an entry is a directory,
//!   and `deploy_root` itself always exists. A stat reports the entry's size
//!   with the index's `mtime_ms`, a listing comes from the index, a read
//!   of a file not yet copied into the tmpfs faults it in through
//!   `fault.zig`, and the binding answers every mutation with EROFS.
//! - `/` and `/var`: virtual read-only directories listing only the
//!   namespace roots, so the cwd's ancestors stat and list without exposing
//!   the chroot root.
//! - anything else: invisible, ENOENT on a read and EROFS on a mutation.
//!
//! The binding declares its own copies of the route constants, of
//! `readdir_cursor_start` and of `RouteInfo`, so a change to any of them
//! edits `fs.cpp` too.

const std = @import("std");
const builtin = @import("builtin");
const fd_mod = @import("collo_os").fd;
const ipc = @import("collo_ipc");
const copies = @import("copies.zig");

pub const fs_index = ipc.fs_index;
pub const IndexView = fs_index.IndexView;

/// Faults files of the tree into the tmpfs on first read; it shares this
/// file's global state.
pub const fault = @import("fault.zig");

/// Capacity of a normalized path buffer, including the trailing NUL the
/// binding's syscalls need, so a normalized path holds at most
/// `PATH_MAX - 1` bytes.
pub const max_normalized_bytes: usize = std.posix.PATH_MAX;

/// Root of the read-only tree and the worker's cwd, the directory AWS Lambda
/// and Vercel use. `/tmp` lies outside it, so the scratch and the tree are
/// disjoint: an index entry `tmp/x` is `/var/task/tmp/x`, never `/tmp/x`.
pub const deploy_root = "/var/task";

comptime {
    // Every index path, joined under the root with a separator and the NUL
    // the binding's syscalls need, fits a normalized path buffer.
    std.debug.assert(deploy_root.len + 1 + fs_index.path_bytes_max + 1 <= max_normalized_bytes);
}

// Return values of `collo_worker_fs_route` and `collo_worker_fs_readdir_next`.
// The binding's copies are the `routeClass*` and `routeError*` constants in
// `fs.cpp`.
pub const route_class_tmp: i32 = 0;
pub const route_class_deploy_file: i32 = 1;
pub const route_class_deploy_dir: i32 = 2;
pub const route_class_none: i32 = 3;
pub const route_error_too_long: i32 = -1;
pub const route_error_internal: i32 = -2;

/// Initial cursor of `collo_worker_fs_readdir_next`, `readdirCursorStart` in
/// the binding. A cursor the call returns is an index position or a virtual
/// directory's ordinal, both far below it.
pub const readdir_cursor_start: u64 = std.math.maxInt(u64);

/// Out-parameter of `collo_worker_fs_route`, laid out like
/// `ColloWorkerFsRouteInfo` in `fs.cpp`.
pub const RouteInfo = extern struct {
    size: u64 = 0,
    mtime_ms: u64 = 0,
    normalized_len: u32 = 0,
    reserved: u32 = 0,
};

const GlobalState = struct {
    /// The private mapping of the index memfd made by `initWorker`; null
    /// when a test installed borrowed bytes.
    mapped: ?[]align(std.heap.page_size_min) const u8,
    view: IndexView,
    /// Worker end of the fault SEQPACKET pair, delivered with WorkerInit,
    /// nonblocking, and registered as the ring's `fs_fault` fixed file.
    /// `fault.zig` speaks `ipc.fs_fault` on it with sendmsg and recvmsg.
    /// Negative when a test installs no fault channel.
    fault_fd: std.posix.fd_t,
    cwd_buf: [max_normalized_bytes]u8,
    cwd_len: usize,
    /// Directory that faulted files are copied under. In a worker it is
    /// `deploy_root`, inside the chroot whose root is the tmpfs; in-process
    /// tests point it under the machine's /tmp because they cannot write
    /// /var/task.
    materialize_root_buf: [max_normalized_bytes]u8,
    materialize_root_len: usize,
    /// Size of the worker's tmpfs. WorkerInit carries it
    /// (`WorkerInit.tmpfs_size_bytes`), `zygote/worker_boot/sandbox.zig`
    /// mounts the chroot root with it, and `initWorker` reads it back from
    /// the mounted filesystem. `copies.zig` budgets its copies as
    /// `fs_fault.materialize_budget_percent` of it. Test installs start at
    /// `WorkerInit.default_tmpfs_size_bytes` and may override it with
    /// `setTmpfsSizeForTest`.
    tmpfs_size_bytes: u64,
    /// The files `copies.zig` has copied into the tmpfs, with their sizes and
    /// last reads. It lives here, beside the materialize root it accounts
    /// for, so that `deinitWorker` tears it down with the rest of the
    /// worker-global state; its behavior is in `copies.zig`.
    ledger: copies.Ledger,

    fn cwd(self: *const GlobalState) []const u8 {
        return self.cwd_buf[0..self.cwd_len];
    }

    fn materializeRoot(self: *const GlobalState) []const u8 {
        return self.materialize_root_buf[0..self.materialize_root_len];
    }
};

// glibc's `struct statfs` on 64-bit Linux, which `zygote/worker_boot/cgroup.zig`
// declares too. `initWorker` calls fstatfs before seccomp, which denies it.
const Statfs = extern struct {
    f_type: c_long,
    f_bsize: c_long,
    f_blocks: c_ulong,
    f_bfree: c_ulong,
    f_bavail: c_ulong,
    f_files: c_ulong,
    f_ffree: c_ulong,
    f_fsid: [2]c_int,
    f_namelen: c_long,
    f_frsize: c_long,
    f_flags: c_long,
    f_spare: [4]c_long,
};

extern fn fstatfs(fd: c_int, buf: *Statfs) c_int;

var global_state: ?GlobalState = null;

/// Installs the index once per worker child, after the chroot and before
/// seccomp. Takes both fds on every path: the index fd is closed once
/// mapped, since the mapping keeps the sealed bytes alive, and the fault fd
/// is held until `deinitWorker`. Fails with `error.InvalidFsIndex` when the
/// bytes do not parse, `error.InvalidWorkerTmpfs` when the chroot root
/// reports no size, or the error of the seal check, mmap, mkdir or chdir
/// that failed.
pub fn initWorker(index_fd: std.posix.fd_t, fault_fd: std.posix.fd_t) !void {
    return initWorkerImpl(index_fd, fault_fd, true);
}

/// `initWorker` for unit tests: the same seal check, mapping, parse and fd
/// ownership, without the namespace setup, which needs the chrooted tmpfs
/// only a forked worker has. The cwd is `deploy_root`, so routing behaves as
/// in a booted worker, and the tmpfs size stays at the WorkerInit default.
pub fn initWorkerForTest(index_fd: std.posix.fd_t, fault_fd: std.posix.fd_t) !void {
    comptime std.debug.assert(builtin.is_test);
    return initWorkerImpl(index_fd, fault_fd, false);
}

fn initWorkerImpl(index_fd: std.posix.fd_t, fault_fd: std.posix.fd_t, setup_namespace: bool) !void {
    std.debug.assert(global_state == null);
    var fault_owned = true;
    defer if (fault_owned and fault_fd >= 0) std.posix.close(fault_fd);
    var index_owned = true;
    defer if (index_owned) std.posix.close(index_fd);

    // The fault channel must never block the VM thread. A sync fault
    // (`faultSync` in `fault_sync.zig`) reads responses inside a turn, which
    // leaves the ring's one-shot poll completion stale: the loop's next read
    // finds the channel empty, and a blocking recv would hang the worker. With a
    // nonblocking end, every reader treats WouldBlock as a spurious wake. A
    // full socket buffer fails the send, and with it the read, instead of
    // blocking. Unanswered requests are bounded by `fault.max_faults_per_worker`
    // async faults plus the one sync fault the VM thread waits on, each with a
    // path of at most `ipc.fs_fault.max_path_bytes`. That bound has not been
    // measured against the default SEQPACKET send buffer, and a sync fault
    // that timed out leaves an unanswered request outside it.
    if (fault_fd >= 0)
        try fd_mod.setNonblocking(fault_fd, true);

    // The host seals the index before handing it over. Unsealed bytes could
    // change under the mapping after the parse validated them.
    try fd_mod.requireSeals(index_fd, fd_mod.memfd_readonly_seals);
    const stat = try std.posix.fstat(index_fd);
    if (stat.size <= 0)
        return error.InvalidFsIndex;
    if (stat.size > std.math.maxInt(usize))
        return error.InvalidFsIndex;
    const size: usize = @intCast(stat.size);
    // Before Linux 6.7, a shared mapping of a write-sealed memfd fails with
    // EPERM while the fd is open read-write, because mprotect could later
    // make it writable. A private read-only mapping works on every kernel and
    // shows the same bytes, as for the route bindings blob in
    // `zygote/child_boot.zig`.
    const mapped = try std.posix.mmap(
        null,
        size,
        std.posix.PROT.READ,
        .{ .TYPE = .PRIVATE },
        index_fd,
        0,
    );
    errdefer std.posix.munmap(mapped);
    std.posix.close(index_fd);
    index_owned = false;

    const view = IndexView.parse(mapped[0..size]) catch return error.InvalidFsIndex;

    var state = GlobalState{
        .mapped = mapped,
        .view = view,
        .fault_fd = fault_fd,
        .cwd_buf = undefined,
        .cwd_len = 0,
        .materialize_root_buf = undefined,
        .materialize_root_len = deploy_root.len,
        .tmpfs_size_bytes = ipc.messages.WorkerInit.default_tmpfs_size_bytes,
        .ledger = .{},
    };
    @memcpy(state.materialize_root_buf[0..deploy_root.len], deploy_root);
    if (setup_namespace) {
        // The chroot root is the worker tmpfs, mounted with WorkerInit's size
        // by `zygote/worker_boot/sandbox.zig`. The fault budget derives from
        // that size, so it is read back from the mounted filesystem; a root
        // that reports no size would zero the budget and reject every fault,
        // so it fails the init instead.
        const root_fd = try std.posix.openat(
            std.posix.AT.FDCWD,
            "/",
            .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .DIRECTORY = true },
            0,
        );
        defer std.posix.close(root_fd);
        var root_statfs: Statfs = undefined;
        if (fstatfs(root_fd, &root_statfs) != 0)
            return error.InvalidWorkerTmpfs;
        if (root_statfs.f_bsize <= 0)
            return error.InvalidWorkerTmpfs;
        state.tmpfs_size_bytes =
            @as(u64, root_statfs.f_blocks) * @as(u64, @intCast(root_statfs.f_bsize));
        if (state.tmpfs_size_bytes == 0)
            return error.InvalidWorkerTmpfs;
        // The tmpfs starts empty. The worker enters `deploy_root` before the
        // cwd is captured, so relative paths resolve inside the tree and a
        // relative `tmp/x` never reaches the scratch.
        std.posix.mkdir("/var", 0o755) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        std.posix.mkdir(deploy_root, 0o755) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        try std.posix.chdir(deploy_root);
        const cwd_slice = try std.posix.getcwd(&state.cwd_buf);
        state.cwd_len = cwd_slice.len;

        std.posix.mkdir("/tmp", 0o700) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    } else {
        @memcpy(state.cwd_buf[0..deploy_root.len], deploy_root);
        state.cwd_len = deploy_root.len;
    }

    fault_owned = false;
    global_state = state;
}

pub fn deinitWorker() void {
    const state = &(global_state orelse return);
    state.ledger.deinit();
    if (state.mapped) |mapped|
        std.posix.munmap(mapped);
    if (state.fault_fd >= 0)
        std.posix.close(state.fault_fd);
    global_state = null;
}

pub fn isInitialized() bool {
    return global_state != null;
}

/// The worker end of the fault channel; null without an installed index or
/// without a fault channel.
pub fn faultFd() ?std.posix.fd_t {
    const state = &(global_state orelse return null);
    if (state.fault_fd < 0)
        return null;
    return state.fault_fd;
}

/// The installed index, or null before install. The pointer stays valid
/// until `deinitWorker` or `uninstallForTest`.
pub fn indexView() ?*const IndexView {
    const state = &(global_state orelse return null);
    return &state.view;
}

/// The directory faulted files are copied under (see `GlobalState`), or
/// null before install.
pub fn materializeRoot() ?[]const u8 {
    const state = &(global_state orelse return null);
    return state.materializeRoot();
}

/// The worker tmpfs size (see `GlobalState.tmpfs_size_bytes`), or null
/// before install.
pub fn tmpfsSizeBytes() ?u64 {
    const state = &(global_state orelse return null);
    return state.tmpfs_size_bytes;
}

/// The ledger of copied files (see `GlobalState.ledger`), or null before
/// install.
pub fn materializedLedger() ?*copies.Ledger {
    const state = &(global_state orelse return null);
    return &state.ledger;
}

/// The mtime every file and directory of the tree reports (the index's
/// `mtime_ms`), or null before install.
pub fn mtimeMs() ?u64 {
    const state = &(global_state orelse return null);
    return state.view.mtime_ms;
}

/// Installs borrowed index bytes for a unit test, with `cwd` as the cwd, no
/// mapping and no fault channel. The caller keeps `index_bytes` alive until
/// `uninstallForTest`.
pub fn installForTest(index_bytes: []const u8, cwd: []const u8) !void {
    comptime std.debug.assert(builtin.is_test);
    return installForTestWithFault(index_bytes, cwd, -1, deploy_root);
}

/// `installForTest` with a fault channel. `fault_fd` is borrowed and set
/// nonblocking; the test closes it after `uninstallForTest`. Faulted files
/// are copied under `materialize_root`, since `deploy_root` is writable only
/// inside a worker's chroot.
pub fn installForTestWithFault(
    index_bytes: []const u8,
    cwd: []const u8,
    fault_fd: std.posix.fd_t,
    materialize_root: []const u8,
) !void {
    comptime std.debug.assert(builtin.is_test);
    std.debug.assert(global_state == null);
    // Nonblocking for the same reason as in `initWorkerImpl`. The flag
    // belongs to this end's open file description, so the test's peer end
    // is unaffected.
    if (fault_fd >= 0)
        try fd_mod.setNonblocking(fault_fd, true);
    std.debug.assert(cwd.len <= max_normalized_bytes);
    std.debug.assert(materialize_root.len <= max_normalized_bytes);
    const view = try IndexView.parse(index_bytes);
    var state = GlobalState{
        .mapped = null,
        .view = view,
        .fault_fd = fault_fd,
        .cwd_buf = undefined,
        .cwd_len = cwd.len,
        .materialize_root_buf = undefined,
        .materialize_root_len = materialize_root.len,
        .tmpfs_size_bytes = ipc.messages.WorkerInit.default_tmpfs_size_bytes,
        .ledger = .{},
    };
    @memcpy(state.cwd_buf[0..cwd.len], cwd);
    @memcpy(state.materialize_root_buf[0..materialize_root.len], materialize_root);
    global_state = state;
}

/// Overrides the tmpfs size the fault budget derives from. A worker reads it
/// from its mounted tmpfs; test installs start at the WorkerInit default.
pub fn setTmpfsSizeForTest(bytes: u64) void {
    comptime std.debug.assert(builtin.is_test);
    const state = &(global_state.?);
    state.tmpfs_size_bytes = bytes;
}

/// Drops a test install and its ledger. The index bytes and the fault fd
/// stay the caller's.
pub fn uninstallForTest() void {
    comptime std.debug.assert(builtin.is_test);
    if (global_state) |*state|
        state.ledger.deinit();
    global_state = null;
}

pub const NormalizeError = error{PathTooLong};

/// Resolves `path` against `cwd`, an absolute path where only the root ends
/// in '/', into `out`. It folds `.`, `..`, empty segments and trailing
/// slashes, and `..` at the root stays at the root as in the kernel. Lexical
/// resolution matches the kernel's inside a worker because no symlink can
/// exist there: seccomp denies symlinkat, and the tree exists only in the
/// index. Fails with `error.PathTooLong` when `path` or the result reaches
/// `max_normalized_bytes` or the result does not fit `out`.
pub fn normalizePath(cwd: []const u8, path: []const u8, out: []u8) NormalizeError![]const u8 {
    if (path.len >= max_normalized_bytes)
        return error.PathTooLong;
    var len: usize = 0;
    if (path.len == 0 or path[0] != '/') {
        const seed = std.mem.trimRight(u8, cwd, "/");
        if (seed.len > out.len)
            return error.PathTooLong;
        @memcpy(out[0..seed.len], seed);
        len = seed.len;
    }
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, "."))
            continue;
        if (std.mem.eql(u8, segment, "..")) {
            len = std.mem.lastIndexOfScalar(u8, out[0..len], '/') orelse 0;
            continue;
        }
        const next_len = len + 1 + segment.len;
        if (next_len > max_normalized_bytes - 1 or next_len > out.len)
            return error.PathTooLong;
        out[len] = '/';
        @memcpy(out[len + 1 ..][0..segment.len], segment);
        len = next_len;
    }
    if (len == 0) {
        if (out.len < 1)
            return error.PathTooLong;
        out[0] = '/';
        len = 1;
    }
    return out[0..len];
}

pub const Class = enum { tmp, deploy_file, deploy_dir, none };

pub const Routed = struct {
    class: Class,
    /// Index position of the file; meaningful only for `deploy_file`.
    entry: usize = 0,
};

/// Places a normalized absolute path in one of the namespaces the file
/// header lists. `deploy_root` itself is always a directory, so
/// `process.cwd()` stats even with an empty index.
pub fn classify(view: *const IndexView, normalized: []const u8) Routed {
    std.debug.assert(normalized.len >= 1 and normalized[0] == '/');
    if (std.mem.eql(u8, normalized, "/tmp") or std.mem.startsWith(u8, normalized, "/tmp/"))
        return .{ .class = .tmp };
    if (deployKey(normalized)) |key| {
        if (key.len == 0)
            return .{ .class = .deploy_dir };
        if (key.len <= fs_index.path_bytes_max) {
            if (view.lookup(key)) |entry|
                return .{ .class = .deploy_file, .entry = entry };
            if (dirExists(view, key))
                return .{ .class = .deploy_dir };
        }
        return .{ .class = .none };
    }
    if (virtualDirEntries(normalized) != null)
        return .{ .class = .deploy_dir };
    return .{ .class = .none };
}

/// The index key of a normalized absolute path under `deploy_root`: "" for
/// `deploy_root` itself, "a/b" for `/var/task/a/b`, and null outside the
/// tree. The prefix must end at a segment boundary, so `/var/taskx` is
/// outside.
pub fn deployKey(normalized: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, normalized, deploy_root))
        return null;
    if (normalized.len == deploy_root.len)
        return normalized[deploy_root.len..];
    if (normalized[deploy_root.len] != '/')
        return null;
    return normalized[deploy_root.len + 1 ..];
}

// Listings of the virtual ancestors of `deploy_root`: namespace roots, all
// directories `initWorker` creates, in byte order like an index listing.
const virtual_root_entries = [_][]const u8{ "tmp", "var" };
const virtual_var_entries = [_][]const u8{"task"};

fn virtualDirEntries(normalized: []const u8) ?[]const []const u8 {
    if (std.mem.eql(u8, normalized, "/"))
        return &virtual_root_entries;
    if (std.mem.eql(u8, normalized, "/var"))
        return &virtual_var_entries;
    return null;
}

/// The first index position whose path is not below `bound` in byte order.
/// The index is sorted by path bytes, so every prefix range is contiguous.
fn lowerBound(view: *const IndexView, bound: []const u8) usize {
    var low: usize = 0;
    var high: usize = view.entry_count;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (std.mem.order(u8, view.entryPathAt(mid), bound) == .lt) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return low;
}

fn dirExists(view: *const IndexView, key: []const u8) bool {
    var prefix_buf: [fs_index.path_bytes_max + 1]u8 = undefined;
    if (key.len + 1 > prefix_buf.len)
        return false;
    @memcpy(prefix_buf[0..key.len], key);
    prefix_buf[key.len] = '/';
    const prefix = prefix_buf[0 .. key.len + 1];
    const start = lowerBound(view, prefix);
    if (start >= view.entry_count)
        return false;
    return std.mem.startsWith(u8, view.entryPathAt(start), prefix);
}

pub const DirEntry = struct {
    /// Points into the index and stays valid while it is installed.
    name: []const u8,
    is_dir: bool,
};

/// Iterates the immediate children of a directory of the tree in index
/// order, yielding each subdirectory once by skipping its subtree. A path
/// that is not a directory yields nothing, so callers classify it first.
pub const DirIter = struct {
    view: *const IndexView,
    prefix_buf: [fs_index.path_bytes_max + 1]u8,
    prefix_len: usize,
    cursor: usize,

    /// `dir_normalized` is relative to `deploy_root` with a leading '/': "/"
    /// for the root of the tree, "/a/b" below it.
    /// `collo_worker_fs_readdir_next` strips `deploy_root` before iterating.
    pub fn init(view: *const IndexView, dir_normalized: []const u8) DirIter {
        var self = initAt(view, dir_normalized, 0);
        self.cursor = lowerBound(view, self.prefix());
        return self;
    }

    /// `init` resuming at an index position, for the stateless C ABI
    /// iterator.
    pub fn initAt(view: *const IndexView, dir_normalized: []const u8, cursor: usize) DirIter {
        std.debug.assert(dir_normalized.len >= 1 and dir_normalized[0] == '/');
        var self = DirIter{
            .view = view,
            .prefix_buf = undefined,
            .prefix_len = 0,
            .cursor = cursor,
        };
        const key = dir_normalized[1..];
        if (key.len != 0) {
            if (key.len + 1 > self.prefix_buf.len) {
                // Longer than any legal index path: nothing to iterate.
                self.cursor = view.entry_count;
                return self;
            }
            @memcpy(self.prefix_buf[0..key.len], key);
            self.prefix_buf[key.len] = '/';
            self.prefix_len = key.len + 1;
        }
        return self;
    }

    fn prefix(self: *const DirIter) []const u8 {
        return self.prefix_buf[0..self.prefix_len];
    }

    pub fn next(self: *DirIter) ?DirEntry {
        if (self.cursor >= self.view.entry_count)
            return null;
        const path = self.view.entryPathAt(self.cursor);
        if (!std.mem.startsWith(u8, path, self.prefix()))
            return null;
        const rest = path[self.prefix_len..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |separator| {
            const child_prefix_len = self.prefix_len + separator + 1;
            self.cursor += 1;
            // Skip the whole child subtree so the dir is emitted once.
            while (self.cursor < self.view.entry_count) : (self.cursor += 1) {
                const candidate = self.view.entryPathAt(self.cursor);
                if (candidate.len < child_prefix_len)
                    break;
                if (!std.mem.eql(u8, candidate[0..child_prefix_len], path[0..child_prefix_len]))
                    break;
            }
            return .{ .name = rest[0..separator], .is_dir = true };
        }
        self.cursor += 1;
        return .{ .name = rest, .is_dir = false };
    }
};

/// Normalizes and classifies one path for the binding. Writes the
/// NUL-terminated normalized path into `out_path`, whose capacity must be at
/// least `max_normalized_bytes`, for the binding's own syscalls, and fills
/// `out_info`: the normalized length always, the size for `deploy_file`, and
/// the index's `mtime_ms` for `deploy_file` and `deploy_dir`. Returns a
/// `route_class_*` value, `route_error_too_long`, or `route_error_internal`
/// for a null argument, a short buffer or no installed index.
pub export fn collo_worker_fs_route(
    path_ptr: ?[*]const u8,
    path_len: usize,
    out_path: ?[*]u8,
    out_path_cap: usize,
    out_info: ?*RouteInfo,
) i32 {
    const state = if (global_state) |*existing| existing else return route_error_internal;
    const info = out_info orelse return route_error_internal;
    const out = out_path orelse return route_error_internal;
    if (out_path_cap < max_normalized_bytes)
        return route_error_internal;
    const path = (path_ptr orelse return route_error_internal)[0..path_len];
    info.* = .{};

    const normalized = normalizePath(state.cwd(), path, out[0 .. out_path_cap - 1]) catch
        return route_error_too_long;
    out[normalized.len] = 0;
    info.normalized_len = @intCast(normalized.len);

    const routed = classify(&state.view, normalized);
    switch (routed.class) {
        .tmp => return route_class_tmp,
        .deploy_file => {
            info.size = state.view.entrySizeAt(routed.entry);
            info.mtime_ms = state.view.mtime_ms;
            return route_class_deploy_file;
        },
        .deploy_dir => {
            info.mtime_ms = state.view.mtime_ms;
            return route_class_deploy_dir;
        },
        .none => return route_class_none,
    }
}

/// Stateless iterator over the immediate children of a directory that
/// `collo_worker_fs_route` classified as `deploy_dir`; `dir` is its
/// normalized path. The binding starts `cursor` at `readdir_cursor_start`
/// and calls until 0. Returns 1 with one name copied into `out_name` without
/// a NUL, its length in `out_name_len`; 0 when exhausted; or
/// `route_error_internal` for a null argument, a path outside the tree, a
/// cursor out of range or a name longer than `out_name_cap`.
pub export fn collo_worker_fs_readdir_next(
    dir_ptr: ?[*]const u8,
    dir_len: usize,
    cursor: ?*u64,
    out_name: ?[*]u8,
    out_name_cap: usize,
    out_name_len: ?*u32,
    out_is_dir: ?*u8,
) i32 {
    const state = if (global_state) |*existing| existing else return route_error_internal;
    const cursor_ptr = cursor orelse return route_error_internal;
    const name_out = out_name orelse return route_error_internal;
    const name_len_out = out_name_len orelse return route_error_internal;
    const is_dir_out = out_is_dir orelse return route_error_internal;
    const dir = (dir_ptr orelse return route_error_internal)[0..dir_len];
    if (dir.len == 0 or dir[0] != '/')
        return route_error_internal;

    // A virtual ancestor of `deploy_root` lists the namespace roots; its
    // cursor is the ordinal of the next entry.
    if (virtualDirEntries(dir)) |entries| {
        const ordinal: u64 = if (cursor_ptr.* == readdir_cursor_start) 0 else cursor_ptr.*;
        if (ordinal > entries.len)
            return route_error_internal;
        if (ordinal >= entries.len) {
            cursor_ptr.* = ordinal;
            return 0;
        }
        const entry_name = entries[@intCast(ordinal)];
        cursor_ptr.* = ordinal + 1;
        if (entry_name.len > out_name_cap)
            return route_error_internal;
        @memcpy(name_out[0..entry_name.len], entry_name);
        name_len_out.* = @intCast(entry_name.len);
        is_dir_out.* = 1;
        return 1;
    }

    // A directory of the tree iterates the index relative to `deploy_root`.
    // Any other path never classifies as `deploy_dir`, so reaching here with
    // one is a misuse of the ABI.
    const key = deployKey(dir) orelse return route_error_internal;
    const iter_dir: []const u8 = if (key.len == 0) "/" else dir[deploy_root.len..];

    var iter = if (cursor_ptr.* == readdir_cursor_start)
        DirIter.init(&state.view, iter_dir)
    else if (cursor_ptr.* <= state.view.entry_count)
        DirIter.initAt(&state.view, iter_dir, @intCast(cursor_ptr.*))
    else
        return route_error_internal;

    const entry = iter.next() orelse {
        cursor_ptr.* = iter.cursor;
        return 0;
    };
    cursor_ptr.* = iter.cursor;
    if (entry.name.len > out_name_cap)
        return route_error_internal;
    @memcpy(name_out[0..entry.name.len], entry.name);
    name_len_out.* = @intCast(entry.name.len);
    is_dir_out.* = @intFromBool(entry.is_dir);
    return 1;
}

/// Writes where a file's faulted bytes are copied, the materialize root
/// joined with the index key as `physicalPath` in `copies.zig` builds it,
/// into `out_path` with a trailing NUL, and returns its length without the
/// NUL. `path` is a normalized absolute path under `deploy_root`. Returns
/// `route_error_internal` for a null argument, a path outside the tree or
/// equal to its root, or a short buffer. In a worker the materialize root is
/// `deploy_root`, so the result equals `path`; only the in-process test
/// install copies files elsewhere, which is why the binding's read after an
/// async fault settles resolves the copy through this call.
pub export fn collo_worker_fs_materialized_path(
    path_ptr: ?[*]const u8,
    path_len: usize,
    out_path: ?[*]u8,
    out_path_cap: usize,
) i32 {
    const state = if (global_state) |*existing| existing else return route_error_internal;
    const out = out_path orelse return route_error_internal;
    const path = (path_ptr orelse return route_error_internal)[0..path_len];
    if (path.len == 0 or path[0] != '/')
        return route_error_internal;
    const key = deployKey(path) orelse return route_error_internal;
    if (key.len == 0)
        return route_error_internal;
    const root = state.materializeRoot();
    const total = root.len + 1 + key.len;
    if (total + 1 > out_path_cap or total > std.math.maxInt(i32))
        return route_error_internal;
    @memcpy(out[0..root.len], root);
    out[root.len] = '/';
    @memcpy(out[root.len + 1 ..][0..key.len], key);
    out[total] = 0;
    return @intCast(total);
}
