//! The worker's io_uring and the restriction helpers that the runtime's other
//! sandboxed rings use. The worker ring is created disabled, gets its whole
//! fixed-file table and a restriction set, and only then is enabled. The
//! kernel takes restrictions only on a disabled ring and only once, and after
//! enabling they allow no register opcode except enabling, so the fixed-file
//! table must be complete before `enableRing`. The set limits the ring to
//! POLL_ADD on registered slots. The worker's seccomp filter then denies
//! io_uring_setup and io_uring_register and lets io_uring_enter reach only
//! this ring (`zygote/worker_boot/sandbox.zig`), so after boot no worker code
//! can create another ring or change this one. Its user_data carries the
//! `worker_scheduler_high_byte` tag of `collo_io_uring_tags`, and
//! `WorkerRing.wait` drops any completion that does not decode.

const std = @import("std");
const tags = @import("collo_io_uring_tags");

const linux = std.os.linux;

pub const entries_default: u16 = 64;
pub const worker_restriction_count: usize = 4;

const tag_shift: u6 = tags.high_byte_shift;
const kind_shift: u6 = 52;
const generation_shift: u6 = 32;
const kind_mask: u64 = (1 << (tag_shift - kind_shift)) - 1;
const generation_mask: u64 = (1 << (kind_shift - generation_shift)) - 1;
const value_mask: u64 = (1 << generation_shift) - 1;

pub const max_user_data_generation: u64 = generation_mask;

pub const FixedFile = enum(u32) {
    control = 0,
    wakeup = 1,
    egress_completion = 2,
    egress_liveness = 3,
    timer = 4,
    ingress_payload_credit = 5,
    /// Worker end of the fs-fault SEQPACKET socket pair. The ring only polls
    /// it, as it polls every slot; the fault messages go through sendmsg and
    /// recvmsg on the raw fd.
    fs_fault = 6,

    pub const count: usize = 7;
};

pub const OperationKind = enum(u4) {
    control_poll = 1,
    wakeup_poll = 2,
    egress_completion_poll = 3,
    egress_liveness_poll = 4,
    timer_poll = 6,
    ingress_payload_credit_poll = 7,
    fs_fault_poll = 8,
    /// POLLOUT on the `control` slot. It can be in flight beside the slot's
    /// read poll (`control_poll`), and only the kind tells their completions
    /// apart.
    control_writable_poll = 9,
};

pub const UserData = struct {
    kind: OperationKind,
    generation: u64 = 0,
    value: u64 = 0,

    pub fn pack(self: UserData) !u64 {
        if (self.generation > generation_mask)
            return error.GenerationTooLarge;
        if (self.value > value_mask)
            return error.UserDataValueTooLarge;
        return (tags.worker_scheduler_high_byte << tag_shift) |
            (@as(u64, @intFromEnum(self.kind)) << kind_shift) |
            (self.generation << generation_shift) |
            self.value;
    }

    pub fn unpack(value: u64) !UserData {
        if ((value >> tag_shift) != tags.worker_scheduler_high_byte)
            return error.InvalidUserDataTag;
        const kind_raw: u4 = @intCast((value >> kind_shift) & kind_mask);
        const kind = std.meta.intToEnum(OperationKind, kind_raw) catch return error.InvalidUserDataKind;
        return .{
            .kind = kind,
            .generation = (value >> generation_shift) & generation_mask,
            .value = value & value_mask,
        };
    }
};

pub const Completion = struct {
    user_data: UserData,
    res: i32,
    flags: u32,

    pub fn errno(self: Completion) ?linux.E {
        if (self.res >= 0 or self.res < -4095)
            return null;
        return @enumFromInt(@as(u16, @intCast(-self.res)));
    }
};

pub const WorkerRingConfig = struct {
    entries: u16 = entries_default,
    files: [FixedFile.count]std.posix.fd_t,
};

pub const RestrictionOpcode = enum(u16) {
    register_op = 0,
    sqe_op = 1,
    sqe_flags_allowed = 2,
    sqe_flags_required = 3,
};

/// The kernel's `struct io_uring_restriction`; the layout is checked below.
pub const Restriction = extern struct {
    opcode: RestrictionOpcode,
    arg: extern union {
        register_op: u8,
        sqe_op: u8,
        sqe_flags: u8,
    },
    resv: u8,
    resv2: [3]u32,
};

comptime {
    std.debug.assert(@sizeOf(Restriction) == 16);
    std.debug.assert(@offsetOf(Restriction, "opcode") == 0);
    std.debug.assert(@offsetOf(Restriction, "arg") == 2);
    std.debug.assert(@offsetOf(Restriction, "resv") == 3);
    std.debug.assert(@offsetOf(Restriction, "resv2") == 4);
}

/// Checks that every slot holds a distinct open fd of the kind its
/// `FixedFile` names, failing with `error.InvalidWorkerRingFixedFile`
/// otherwise. It works without /proc, because the worker calls it after its
/// chroot.
pub fn validateWorkerFixedFiles(files: *const [FixedFile.count]std.posix.fd_t) !void {
    for (files.*, 0..) |fd, index| {
        validateOneWorkerFixedFile(files, fd, index) catch |err| {
            // A rejected fixed file fails worker init. The log names the slot
            // and fd so a boot-time mismatch can be diagnosed without strace.
            // It warns rather than errs because the caller reports the
            // failure, and negative tests take this path on purpose.
            std.log.warn("worker ring fixed file rejected index={d} fd={d}: {s}", .{ index, fd, @errorName(err) });
            return err;
        };
    }
}

fn validateOneWorkerFixedFile(files: *const [FixedFile.count]std.posix.fd_t, fd: std.posix.fd_t, index: usize) !void {
    if (fd < 0)
        return error.InvalidWorkerRingFixedFile;
    for (files.*[0..index]) |previous_fd| {
        if (previous_fd == fd)
            return error.InvalidWorkerRingFixedFile;
    }
    const stat = std.posix.fstat(fd) catch return error.InvalidWorkerRingFixedFile;
    const file_type = stat.mode & linux.S.IFMT;
    const fixed_file: FixedFile = @enumFromInt(@as(u32, @intCast(index)));
    switch (fixed_file) {
        .control,
        .fs_fault,
        => {
            if (file_type != linux.S.IFSOCK)
                return error.InvalidWorkerRingFixedFile;
            if (try socketOptionInt(fd, linux.SO.DOMAIN) != std.posix.AF.UNIX)
                return error.InvalidWorkerRingFixedFile;
            if (try socketOptionInt(fd, linux.SO.TYPE) != std.posix.SOCK.SEQPACKET)
                return error.InvalidWorkerRingFixedFile;
        },
        .wakeup,
        .egress_completion,
        .ingress_payload_credit,
        => {
            if (file_type != 0)
                return error.InvalidWorkerRingFixedFile;
            validateEventFd(fd) catch return error.InvalidWorkerRingFixedFile;
        },
        .egress_liveness => {
            if (file_type != 0 and file_type != linux.S.IFIFO)
                return error.InvalidWorkerRingFixedFile;
        },
        .timer => {
            if (file_type != 0)
                return error.InvalidWorkerRingFixedFile;
            try validateTimerFd(fd);
        },
    }
}

fn socketOptionInt(fd: std.posix.fd_t, optname: u32) !i32 {
    var value: i32 = 0;
    var len: linux.socklen_t = @sizeOf(i32);
    const rc = linux.getsockopt(fd, std.posix.SOL.SOCKET, optname, std.mem.asBytes(&value).ptr, &len);
    return switch (linux.E.init(rc)) {
        .SUCCESS => if (len == @sizeOf(i32)) value else error.InvalidWorkerRingFixedFile,
        else => error.InvalidWorkerRingFixedFile,
    };
}

fn validateTimerFd(fd: std.posix.fd_t) !void {
    var spec: linux.itimerspec = undefined;
    const rc = linux.timerfd_gettime(fd, &spec);
    return switch (linux.E.init(rc)) {
        .SUCCESS => {},
        .BADF,
        .INVAL,
        => error.InvalidWorkerRingFixedFile,
        else => error.InvalidWorkerRingFixedFile,
    };
}

fn validateEventFd(fd: std.posix.fd_t) !void {
    var path_buffer: [64]u8 = undefined;
    const proc_fd_path = try std.fmt.bufPrintZ(&path_buffer, "/proc/self/fd/{d}", .{
        fd,
    });
    var target_buffer: [128]u8 = undefined;
    const target = std.posix.readlinkZ(proc_fd_path.ptr, &target_buffer) catch |err| switch (err) {
        // The fd is open (the caller's fstat succeeded), so a missing /proc
        // entry means /proc is absent, as it is after the worker's chroot.
        // The behavioral check stands in there. The eventfds that come with
        // WorkerInit already passed the name check before the chroot
        // (`validateWorkerInitFds` in `zygote/child_boot.zig`).
        error.FileNotFound => return validateEventFdWithoutProc(fd),
        else => return error.InvalidWorkerRingFixedFile,
    };
    if (!std.mem.eql(u8, target, "anon_inode:[eventfd]"))
        return error.InvalidWorkerRingFixedFile;
}

/// A zero-length read consumes nothing, and an eventfd fails it with EINVAL
/// because its reads need 8 bytes. This is weaker than the name check. The
/// caller's file-type check admits any fd whose mode has no file type, and
/// among those timerfd and signalfd fail a short read with EINVAL too, as do
/// fds with no read operation such as epoll, pidfd and io_uring fds. After
/// the chroot this rejects only typeless fds whose zero-length read does not
/// fail with EINVAL, such as a nonblocking inotify fd; pipes, sockets and
/// regular files never reach it. The eventfds that come with WorkerInit got
/// the name check before the chroot.
fn validateEventFdWithoutProc(fd: std.posix.fd_t) !void {
    var buffer: [1]u8 = undefined;
    const rc = linux.read(fd, &buffer, 0);
    return switch (linux.E.init(rc)) {
        .INVAL => {},
        else => error.InvalidWorkerRingFixedFile,
    };
}

pub const WorkerRing = struct {
    ring: linux.IoUring,

    pub fn init(config: WorkerRingConfig) !WorkerRing {
        var ring = try linux.IoUring.init(config.entries, linux.IORING_SETUP_R_DISABLED);
        errdefer ring.deinit();
        try ring.register_files(&config.files);
        try registerWorkerRestrictions(ring.fd);
        try enableRing(ring.fd);
        return .{ .ring = ring };
    }

    pub fn deinit(self: *WorkerRing) void {
        self.ring.deinit();
        self.* = undefined;
    }

    pub fn fd(self: *const WorkerRing) std.posix.fd_t {
        return self.ring.fd;
    }

    pub fn submit(self: *WorkerRing) !u32 {
        return self.ring.submit();
    }

    pub fn submitAndWait(self: *WorkerRing, wait_nr: u32) !u32 {
        return self.ring.submit_and_wait(wait_nr);
    }

    pub fn wait(self: *WorkerRing, out: []Completion, wait_nr: u32) !usize {
        if (out.len == 0)
            return 0;
        var cqes: [32]linux.io_uring_cqe = undefined;
        const count = try self.ring.copy_cqes(cqes[0..@min(cqes.len, out.len)], wait_nr);
        var written: usize = 0;
        for (cqes[0..count]) |cqe| {
            out[written] = .{
                .user_data = UserData.unpack(cqe.user_data) catch continue,
                .res = cqe.res,
                .flags = cqe.flags,
            };
            written += 1;
        }
        return written;
    }

    pub fn drain(self: *WorkerRing, out: []Completion) !usize {
        return self.wait(out, 0);
    }

    pub fn pollFixed(self: *WorkerRing, user_data: UserData, file: FixedFile, events: u32) !void {
        const sqe = try self.ring.poll_add(try user_data.pack(), @intCast(@intFromEnum(file)), events);
        sqe.flags |= linux.IOSQE_FIXED_FILE;
    }
};

/// The worker ring's restriction set: REGISTER_ENABLE_RINGS, POLL_ADD, and
/// IOSQE_FIXED_FILE as both the only allowed and a required SQE flag, so
/// every SQE must target a registered slot.
pub fn workerRestrictions() [worker_restriction_count]Restriction {
    return .{
        registerRestriction(.REGISTER_ENABLE_RINGS),
        sqeRestriction(.POLL_ADD),
        sqeFlagsAllowedRestriction(@intCast(linux.IOSQE_FIXED_FILE)),
        sqeFlagsRequiredRestriction(@intCast(linux.IOSQE_FIXED_FILE)),
    };
}

fn registerWorkerRestrictions(ring_fd: std.posix.fd_t) !void {
    var restrictions = workerRestrictions();
    try registerRaw(ring_fd, .REGISTER_RESTRICTIONS, &restrictions, restrictions.len);
}

pub fn enableRing(ring_fd: std.posix.fd_t) !void {
    try registerRaw(ring_fd, .REGISTER_ENABLE_RINGS, null, 0);
}

pub fn registerRestrictions(ring_fd: std.posix.fd_t, restrictions: []Restriction) !void {
    try registerRaw(ring_fd, .REGISTER_RESTRICTIONS, restrictions.ptr, restrictions.len);
}

pub fn registerRaw(ring_fd: std.posix.fd_t, opcode: linux.IORING_REGISTER, arg: ?*const anyopaque, count: usize) !void {
    const res = linux.io_uring_register(ring_fd, opcode, arg, @intCast(count));
    return switch (linux.E.init(res)) {
        .SUCCESS => {},
        .INVAL => error.UnsupportedKernel,
        .OPNOTSUPP => error.UnsupportedKernel,
        .PERM => error.PermissionDenied,
        .NOMEM => error.SystemResources,
        .MFILE => error.UserFdQuotaExceeded,
        .BADF => error.FileDescriptorInvalid,
        .BUSY => error.RingBusy,
        .NXIO => error.RingShuttingDown,
        else => |errno| std.posix.unexpectedErrno(errno),
    };
}

pub fn registerRestriction(op: linux.IORING_REGISTER) Restriction {
    return .{
        .opcode = .register_op,
        .arg = .{ .register_op = @intCast(@intFromEnum(op)) },
        .resv = 0,
        .resv2 = .{ 0, 0, 0 },
    };
}

pub fn sqeRestriction(op: linux.IORING_OP) Restriction {
    return .{
        .opcode = .sqe_op,
        .arg = .{ .sqe_op = @intCast(@intFromEnum(op)) },
        .resv = 0,
        .resv2 = .{ 0, 0, 0 },
    };
}

pub fn sqeFlagsAllowedRestriction(flags: u8) Restriction {
    return .{
        .opcode = .sqe_flags_allowed,
        .arg = .{ .sqe_flags = flags },
        .resv = 0,
        .resv2 = .{ 0, 0, 0 },
    };
}

pub fn sqeFlagsRequiredRestriction(flags: u8) Restriction {
    return .{
        .opcode = .sqe_flags_required,
        .arg = .{ .sqe_flags = flags },
        .resv = 0,
        .resv2 = .{ 0, 0, 0 },
    };
}
