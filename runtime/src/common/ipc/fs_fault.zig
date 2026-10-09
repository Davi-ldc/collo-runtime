//! The fs fault IPC between a worker and the side that serves its read-only
//! file tree: a request for one file, the fixed `FsFaultRequestHeader`
//! followed by the file's path, on the dedicated SEQPACKET pair WorkerInit
//! carries (`zygote_worker.zig`). The host answers faults while the worker
//! boots (`host/launch.zig`), and an ingress lane of the server once it is
//! ready (`server/ingress/runner/fs_fault_control.zig`). Faults never share
//! the worker control channel, and each side registers and drains the fault
//! fd on its own. The codec holds no state, so any thread may call it.
//!
//! This file checks the shape of an identity; the serving side and the
//! worker enforce the policy. A fault carries an active request's identity,
//! request id and generation both nonzero with a nonzero worker pair, or the
//! request-less boot permit that covers module evaluation: the request pair
//! 0/0, which the boot egress token names too
//! (`messages.WorkerInit.boot_egress_token`), with the worker pair also 0/0
//! while the worker evaluates its modules and knows no identity yet. A
//! half-zero pair, or a zero worker pair beside a nonzero request pair, is
//! malformed. A request-less fault after ready decodes here and both ends'
//! state checks refuse it, because the wire cannot see the evaluation window.

const std = @import("std");
const fd_mod = @import("collo_os").fd;
const messages = @import("messages.zig");
const packet = @import("packet.zig");
const fs_index = @import("fs_index.zig");

/// Byte cap on the tree-relative fault path, which has no leading slash. A
/// fault names a path of the worker's fs index, so the cap is the index's own
/// path bound.
pub const max_path_bytes: usize = fs_index.path_bytes_max;

comptime {
    std.debug.assert(@sizeOf(messages.FsFaultRequestHeader) + max_path_bytes <= messages.max_message_bytes);
}

pub const RequestView = struct {
    fault_id: u64,
    request_id: u64,
    request_generation: u64,
    worker_id: u64,
    worker_generation: u64,
    path: []const u8,
};

pub const Request = struct {
    allocator: std.mem.Allocator,
    storage: []u8,
    fault_id: u64,
    request_id: u64,
    request_generation: u64,
    worker_id: u64,
    worker_generation: u64,
    path: []const u8,

    pub fn deinit(self: *Request) void {
        self.allocator.free(self.storage);
        self.* = undefined;
    }
};

pub const Response = struct {
    fault_id: u64,
    status: messages.FsFaultResponseStatus,
};

/// A response and its file: an `ok` status carries exactly one file fd as
/// SCM_RIGHTS beside the fixed header, and any other status carries none.
/// `sendResponse` and `decodeResponseFromPacket` both enforce it.
pub const ResponseWithFd = struct {
    response: Response,
    file_fd: ?fd_mod.OwnedFd,

    pub fn deinit(self: *ResponseWithFd) void {
        if (self.file_fd) |*fd|
            fd.deinit();
        self.* = undefined;
    }

    pub fn takeFileFd(self: *ResponseWithFd) ?std.posix.fd_t {
        if (self.file_fd) |*fd| {
            const raw = fd.release();
            self.file_fd = null;
            return raw;
        }
        return null;
    }
};

pub fn sendRequest(fd: std.posix.fd_t, scratch: []u8, request: RequestView) !void {
    const encoded = try encodeRequestInto(scratch, request);
    try packet.sendWithFds(fd, encoded, &.{});
}

pub fn sendResponse(fd: std.posix.fd_t, response: Response, file_fd: ?fd_mod.FdRef) !void {
    var header = messages.FsFaultResponseHeader{
        .kind = @intFromEnum(messages.MessageKind.fs_fault_response),
        .status = @intFromEnum(response.status),
        .fault_id = response.fault_id,
    };
    if (response.status == .ok and file_fd == null)
        return error.MissingFsFaultFd;
    if (response.status != .ok and file_fd != null)
        return error.UnexpectedFsFaultFd;
    if (file_fd) |fd_ref| {
        try packet.sendWithFds(fd, std.mem.asBytes(&header), &.{fd_ref.fd()});
    } else {
        try packet.sendWithFds(fd, std.mem.asBytes(&header), &.{});
    }
}

pub fn encodeRequestInto(scratch: []u8, request: RequestView) ![]u8 {
    if (scratch.len < messages.max_message_bytes)
        return error.DispatchScratchTooSmall;
    if (request.fault_id == 0)
        return error.InvalidFsFaultRequest;
    // The identity shapes in the file header; the decoder checks the same.
    if ((request.request_id == 0) != (request.request_generation == 0))
        return error.InvalidFsFaultRequest;
    if ((request.worker_id == 0) != (request.worker_generation == 0))
        return error.InvalidFsFaultRequest;
    if (request.worker_id == 0 and request.request_id != 0)
        return error.InvalidFsFaultRequest;
    if (request.path.len == 0 or request.path.len > max_path_bytes)
        return error.InvalidFsFaultRequest;

    var total_len: usize = @sizeOf(messages.FsFaultRequestHeader);
    total_len = try addChecked(total_len, request.path.len);
    if (total_len > messages.max_message_bytes)
        return error.MessageTooLarge;

    const encoded = scratch[0..total_len];
    var header = messages.FsFaultRequestHeader{
        .kind = @intFromEnum(messages.MessageKind.fs_fault_request),
        ._reserved0 = 0,
        .fault_id = request.fault_id,
        .request_id = request.request_id,
        .request_generation = request.request_generation,
        .worker_id = request.worker_id,
        .worker_generation = request.worker_generation,
        .path_len = @intCast(request.path.len),
        ._reserved1 = 0,
    };
    var cursor: usize = 0;
    cursor += packet.writeStruct(encoded[cursor..], &header);
    cursor += packet.writeSlice(encoded[cursor..], request.path);
    std.debug.assert(cursor == encoded.len);
    return encoded;
}

pub fn decodeRequest(allocator: std.mem.Allocator, encoded: []const u8) !Request {
    if (encoded.len < @sizeOf(messages.FsFaultRequestHeader))
        return error.ShortRead;
    const header = packet.readStruct(messages.FsFaultRequestHeader, encoded[0..@sizeOf(messages.FsFaultRequestHeader)]);
    if (try messages.decodeMessageKind(header.kind) != .fs_fault_request)
        return error.InvalidMessageKind;
    if (header._reserved0 != 0 or header._reserved1 != 0)
        return error.InvalidFsFaultRequest;
    if (header.fault_id == 0)
        return error.InvalidFsFaultRequest;
    if ((header.request_id == 0) != (header.request_generation == 0))
        return error.InvalidFsFaultRequest;
    if ((header.worker_id == 0) != (header.worker_generation == 0))
        return error.InvalidFsFaultRequest;
    if (header.worker_id == 0 and header.request_id != 0)
        return error.InvalidFsFaultRequest;
    if (header.path_len == 0 or header.path_len > max_path_bytes)
        return error.InvalidFsFaultRequest;

    var cursor: usize = @sizeOf(messages.FsFaultRequestHeader);
    const path = try readRange(encoded, &cursor, header.path_len);
    if (cursor != encoded.len)
        return error.InvalidPacket;

    const storage = try allocator.dupe(u8, encoded);
    errdefer allocator.free(storage);
    return .{
        .allocator = allocator,
        .storage = storage,
        .fault_id = header.fault_id,
        .request_id = header.request_id,
        .request_generation = header.request_generation,
        .worker_id = header.worker_id,
        .worker_generation = header.worker_generation,
        .path = storage[path.start..path.end],
    };
}

pub fn decodeResponseFromPacket(received: *packet.ReceivedPacket) !ResponseWithFd {
    defer received.deinit();
    if (received.bytes.len != @sizeOf(messages.FsFaultResponseHeader))
        return error.InvalidPacket;
    const header = packet.readStruct(messages.FsFaultResponseHeader, received.bytes);
    if (try messages.decodeMessageKind(header.kind) != .fs_fault_response)
        return error.InvalidMessageKind;
    const status = try messages.decodeFsFaultResponseStatus(header.status);
    if (header.fault_id == 0)
        return error.InvalidFsFaultResponse;
    const expected_fds: usize = if (status == .ok) 1 else 0;
    if (received.fd_count != expected_fds)
        return error.InvalidFdCount;
    const file_fd = if (status == .ok) received.takeFd(0) else null;
    return .{
        .response = .{ .fault_id = header.fault_id, .status = status },
        .file_fd = file_fd,
    };
}

fn readRange(encoded: []const u8, cursor: *usize, len: u32) !struct { start: usize, end: usize } {
    const start = cursor.*;
    const end = std.math.add(usize, start, @as(usize, len)) catch return error.InvalidPacket;
    if (end > encoded.len)
        return error.ShortRead;
    cursor.* = end;
    return .{ .start = start, .end = end };
}

fn addChecked(lhs: usize, rhs: usize) !usize {
    return std.math.add(usize, lhs, rhs) catch error.MessageTooLarge;
}
