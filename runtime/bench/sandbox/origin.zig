//! The plain HTTP/1.1 origin the fetching steps reach through the gateway
//! (`Exchange.fetch` and `Exchange.fetch_upload` in `workload.zig`). The
//! controller starts it once per run, before any trial, on the default
//! route's source address (`runtime/bench/local_origin.zig`), since every
//! grant refuses loopback, and the configuration grants exactly that address
//! and port with `allowHttp` (`writeConfig` in `node.zig`). It runs on a
//! thread of the controller, outside every measured cgroup.
//!
//! One connection is served at a time and carries one exchange, answered
//! with `connection: close`, so a connection the gateway opens while another
//! is served waits in the listen backlog instead of on a reply that cannot
//! come. `GET workload.download_path` answers `workload.fetch_download_bytes`
//! of the block pattern. `POST workload.upload_path` takes a `content-length`
//! body of exactly `workload.fetch_upload_body_bytes` whose bytes all equal
//! the first, and answers its length in decimal. Any other request answers
//! 400 or 404 and counts as a failure, which fails the run at its end.

const std = @import("std");
const os = @import("collo_os");
const workload = @import("workload.zig");

/// Longest request head the origin reads.
const head_bytes_max: usize = 16 * 1024;
/// How long one read or write on a connection may block. A gateway that
/// stalls a connection longer than a request's deadline has failed the
/// fetch already.
const io_timeout_ms: u32 = 30_000;
/// How often the accept loop looks for a stop.
const accept_poll_ms: i32 = 50;
const listen_backlog: u31 = 64;

/// What the origin served. A failure is a request it refused or a
/// connection that broke.
pub const Counts = struct {
    downloads: u64,
    uploads: u64,
    upload_bytes: u64,
    failures: u64,
};

pub const Origin = struct {
    address: [4]u8,
    port: u16,
    listener: std.posix.socket_t,
    thread: ?std.Thread,
    stopping: std.atomic.Value(bool),
    downloads: std.atomic.Value(u64),
    uploads: std.atomic.Value(u64),
    upload_bytes: std.atomic.Value(u64),
    failures: std.atomic.Value(u64),

    /// Listens on `address` at an ephemeral port and starts serving. The
    /// serving thread holds `self`, which must stay in place until `stop`.
    pub fn start(self: *Origin, address: [4]u8) !void {
        const listener = try std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC,
            0,
        );
        errdefer std.posix.close(listener);
        const local = std.net.Address.initIp4(address, 0);
        try std.posix.bind(listener, &local.any, local.getOsSockLen());
        try std.posix.listen(listener, listen_backlog);
        var bound: std.posix.sockaddr.in = undefined;
        var bound_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
        try std.posix.getsockname(listener, @ptrCast(&bound), &bound_len);
        self.* = .{
            .address = address,
            .port = std.mem.bigToNative(u16, bound.port),
            .listener = listener,
            .thread = null,
            .stopping = .init(false),
            .downloads = .init(0),
            .uploads = .init(0),
            .upload_bytes = .init(0),
            .failures = .init(0),
        };
        self.thread = try std.Thread.spawn(.{}, serveMain, .{self});
    }

    /// Stops serving, closes the listener and returns what was served. A
    /// second call only returns the counts.
    pub fn stop(self: *Origin) Counts {
        if (self.thread) |thread| {
            self.stopping.store(true, .release);
            thread.join();
            self.thread = null;
            std.posix.close(self.listener);
        }
        return self.counts();
    }

    pub fn counts(self: *const Origin) Counts {
        return .{
            .downloads = self.downloads.load(.acquire),
            .uploads = self.uploads.load(.acquire),
            .upload_bytes = self.upload_bytes.load(.acquire),
            .failures = self.failures.load(.acquire),
        };
    }

    fn acceptOne(self: *Origin) !void {
        var descriptors = [_]std.posix.pollfd{.{
            .fd = self.listener,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&descriptors, accept_poll_ms) == 0) return;
        const connection = try std.posix.accept(self.listener, null, null, std.posix.SOCK.CLOEXEC);
        defer std.posix.close(connection);
        try os.socket.setReadWriteTimeouts(connection, io_timeout_ms);
        try self.serveConnection(connection);
    }

    fn serveConnection(self: *Origin, connection: std.posix.socket_t) !void {
        var head_buffer: [head_bytes_max]u8 = undefined;
        const head = try readHead(connection, &head_buffer);
        const request = parseRequest(head.head) catch |err| {
            try respondStatus(connection, "400 Bad Request");
            return err;
        };
        if (request.method == .get and std.mem.eql(u8, request.target, workload.download_path)) {
            if ((request.content_length orelse 0) != 0) {
                try respondStatus(connection, "400 Bad Request");
                return error.DownloadWithBody;
            }
            try sendDownload(connection);
            _ = self.downloads.fetchAdd(1, .release);
            return;
        }
        if (request.method == .post and std.mem.eql(u8, request.target, workload.upload_path)) {
            const length = request.content_length orelse {
                try respondStatus(connection, "400 Bad Request");
                return error.UploadWithoutLength;
            };
            if (length != workload.fetch_upload_body_bytes) {
                try respondStatus(connection, "400 Bad Request");
                return error.UnexpectedUploadLength;
            }
            receiveUpload(connection, head.rest, length) catch |err| {
                try respondStatus(connection, "400 Bad Request");
                return err;
            };
            var digits: [20]u8 = undefined;
            const body = std.fmt.bufPrint(&digits, "{d}", .{length}) catch unreachable;
            try respond(connection, "200 OK", body);
            _ = self.uploads.fetchAdd(1, .release);
            _ = self.upload_bytes.fetchAdd(length, .release);
            return;
        }
        try respondStatus(connection, "404 Not Found");
        return error.UnknownOriginRequest;
    }
};

fn serveMain(self: *Origin) void {
    // The loop ends only when `stop` asks it to.
    while (!self.stopping.load(.acquire)) {
        self.acceptOne() catch |err| {
            _ = self.failures.fetchAdd(1, .release);
            std.debug.print("benchmark origin: {s}\n", .{@errorName(err)});
        };
    }
}

const Head = struct {
    /// The request line and headers, through the blank line.
    head: []const u8,
    /// Body bytes read with the head.
    rest: []const u8,
};

fn readHead(connection: std.posix.socket_t, buffer: []u8) !Head {
    var length: usize = 0;
    while (length < buffer.len) {
        const count = try std.posix.recv(connection, buffer[length..], 0);
        if (count == 0) return error.ConnectionClosed;
        length += count;
        if (std.mem.indexOf(u8, buffer[0..length], "\r\n\r\n")) |blank| {
            return .{ .head = buffer[0 .. blank + 4], .rest = buffer[blank + 4 .. length] };
        }
    }
    return error.RequestHeadTooLarge;
}

const Request = struct {
    method: enum { get, post },
    target: []const u8,
    content_length: ?u64,
};

/// Reads the request line and the one header the origin needs. A body
/// framed by anything but `content-length` is refused: the gateway frames a
/// fetch body it holds whole with `content-length`.
fn parseRequest(head: []const u8) !Request {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const request_line = lines.next() orelse return error.MalformedRequest;
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method = parts.next() orelse return error.MalformedRequest;
    const target = parts.next() orelse return error.MalformedRequest;
    const version = parts.next() orelse return error.MalformedRequest;
    if (parts.next() != null) return error.MalformedRequest;
    if (!std.mem.eql(u8, version, "HTTP/1.1")) return error.UnsupportedHttpVersion;
    var result: Request = .{
        .method = if (std.mem.eql(u8, method, "GET"))
            .get
        else if (std.mem.eql(u8, method, "POST"))
            .post
        else
            return error.UnsupportedMethod,
        .target = target,
        .content_length = null,
    };
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.MalformedRequest;
        const name = line[0..colon];
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            if (result.content_length != null) return error.DuplicateContentLength;
            result.content_length = std.fmt.parseUnsigned(u64, value, 10) catch
                return error.MalformedRequest;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            return error.UnsupportedTransferEncoding;
        }
    }
    return result;
}

/// Writes the download one block at a time; block `k` is
/// `workload.pattern_block_bytes` bytes of `k % 256`.
fn sendDownload(connection: std.posix.socket_t) !void {
    var head_buffer: [256]u8 = undefined;
    const head = std.fmt.bufPrint(
        &head_buffer,
        "HTTP/1.1 200 OK\r\ncontent-type: application/octet-stream\r\n" ++
            "content-length: {d}\r\nconnection: close\r\n\r\n",
        .{workload.fetch_download_bytes},
    ) catch unreachable;
    try writeAll(connection, head);
    var block: [workload.pattern_block_bytes]u8 = undefined;
    const blocks = @divExact(workload.fetch_download_bytes, workload.pattern_block_bytes);
    for (0..blocks) |index| {
        @memset(&block, @truncate(index));
        try writeAll(connection, &block);
    }
}

/// Reads `length` body bytes, `already` first, and checks that every byte
/// equals the first, as the fetch upload fills each body.
fn receiveUpload(connection: std.posix.socket_t, already: []const u8, length: u64) !void {
    if (already.len > length) return error.UploadLongerThanDeclared;
    var fill: ?u8 = null;
    try checkFill(&fill, already);
    var received: u64 = already.len;
    var buffer: [workload.pattern_block_bytes]u8 = undefined;
    while (received < length) {
        const wanted: usize = @intCast(@min(buffer.len, length - received));
        const count = try std.posix.recv(connection, buffer[0..wanted], 0);
        if (count == 0) return error.ConnectionClosed;
        try checkFill(&fill, buffer[0..count]);
        received += count;
    }
}

fn checkFill(fill: *?u8, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    const expected = fill.* orelse bytes[0];
    fill.* = expected;
    for (bytes) |byte| {
        if (byte != expected) return error.UploadBodyMismatch;
    }
}

fn respondStatus(connection: std.posix.socket_t, status: []const u8) !void {
    try respond(connection, status, "");
}

fn respond(connection: std.posix.socket_t, status: []const u8, body: []const u8) !void {
    var head_buffer: [256]u8 = undefined;
    const head = try std.fmt.bufPrint(
        &head_buffer,
        "HTTP/1.1 {s}\r\ncontent-type: text/plain\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n",
        .{ status, body.len },
    );
    try writeAll(connection, head);
    try writeAll(connection, body);
}

fn writeAll(connection: std.posix.socket_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        written += try std.posix.send(connection, bytes[written..], std.posix.MSG.NOSIGNAL);
    }
}
