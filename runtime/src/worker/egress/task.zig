//! The record of one fetch a worker's JavaScript started: a copy of the
//! request, its upload progress toward the gateway, the result once the
//! gateway answers, and the promise to settle. Runs on the worker's event loop
//! thread.
//!
//! A task holds one reference on its response body and owns its deferred;
//! `deinit` releases both. `done` turns true once, when
//! `task_runtime.publishResult` stores the result, and a later result is
//! dropped. The result's strings live in `result_arena` or are static
//! literals, so a `Result` frees nothing itself.

const std = @import("std");
const bindings = @import("collo_bindings");
const http = @import("collo_http");
const ipc = @import("collo_ipc");
const fetch_body = @import("collo_egress_core").fetch_body;
const promise_deferred = @import("collo_worker_js").deferred;

const Header = http.Header;

pub const Result = union(enum) {
    success: struct {
        status: u16,
        status_text: []const u8 = "",
        url: []u8,
        body_identity: bindings.FetchBodyIdentity,
        headers: []const bindings.NameValuePair = &.{},
        redirected: bool = false,
    },
    failure: struct {
        message: []const u8,
        owned: bool = true,
    },

    pub fn deinit(self: *Result) void {
        self.* = undefined;
    }
};

pub const Task = struct {
    id: u64,
    request_id: u64,
    url: []u8,
    method: []u8,
    body: []u8,
    headers: []Header,
    flags: u32,
    redirect_count: usize,
    response_body_identity: bindings.FetchBodyIdentity,
    response_body: *fetch_body.Body,
    deferred: promise_deferred.DeferredOwned,
    done: bool,
    queued: bool,
    canceled: bool,
    /// True once the start packet is in the command ring. A full ring is not
    /// fatal: a parked task with `start_sent` false sends the whole start
    /// again on the next upload pass.
    start_sent: bool,
    /// Request-body bytes already placed in the upload pool and announced;
    /// `body` is the staging buffer the remaining extents copy from.
    upload_bytes_sent: u64,
    /// True while the task sits in `State.pending_uploads`, still owing the
    /// gateway its start or body bytes.
    upload_parked: bool,
    abort_reason: ?bindings.Value,
    result: ?Result,
    result_arena: std.heap.ArenaAllocator,
    /// CLOCK_MONOTONIC time at which the gateway published the head or error
    /// packet that settled this task, or 0 when something else settled it: a
    /// disconnect, an abort acknowledgment or an upload failure. The
    /// `fetch_completion` enqueue carries it, so the request's io interval
    /// closes when the answer arrived rather than when the loop got to it.
    ready_at_mono_ns: u64 = 0,

    /// Copies the request and takes ownership of `deferred` on every path: on
    /// error it is released here, so the caller must not use its handle
    /// again. Once this succeeds, the caller retains `response_body` for the
    /// task, and `deinit` drops that reference.
    pub fn init(
        allocator: std.mem.Allocator,
        id: u64,
        request_id: u64,
        url: []const u8,
        method: []const u8,
        body: []const u8,
        headers: []const bindings.NameValuePair,
        flags: u32,
        response_body_identity: bindings.FetchBodyIdentity,
        response_body: *fetch_body.Body,
        deferred: promise_deferred.DeferredOwned,
    ) !Task {
        var owned_deferred = deferred;
        errdefer owned_deferred.deinit();
        var result_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer result_arena.deinit();

        const owned_url = try allocator.dupe(u8, url);
        errdefer allocator.free(owned_url);
        const owned_method = try allocator.dupe(u8, method);
        errdefer allocator.free(owned_method);
        const owned_body = try allocator.dupe(u8, body);
        errdefer allocator.free(owned_body);
        const owned_headers = try cloneBindingHeaders(allocator, headers);
        errdefer freeHeaders(allocator, owned_headers);
        return .{
            .id = id,
            .request_id = request_id,
            .url = owned_url,
            .method = owned_method,
            .body = owned_body,
            .headers = owned_headers,
            .flags = flags,
            .redirect_count = 0,
            .response_body_identity = response_body_identity,
            .response_body = response_body,
            .deferred = owned_deferred,
            .done = false,
            .queued = false,
            .canceled = false,
            .start_sent = false,
            .upload_bytes_sent = 0,
            .upload_parked = false,
            .abort_reason = null,
            .result = null,
            .result_arena = result_arena,
        };
    }

    /// Whether the body travels as upload-pool extents rather than inline in
    /// the start packet.
    pub fn bodyPooled(self: *const Task) bool {
        return self.body.len > ipc.fetch_limits.request_body_inline_preferred_bytes_max;
    }

    /// The request-body bytes the gateway still expects from this task.
    pub fn uploadRemaining(self: *const Task) u64 {
        if (!self.bodyPooled())
            return 0;
        return @as(u64, self.body.len) - self.upload_bytes_sent;
    }

    /// The allocator for the result's strings, which live as long as the task.
    pub fn resultAllocator(self: *Task) std.mem.Allocator {
        return self.result_arena.allocator();
    }

    pub fn deinit(self: *Task, allocator: std.mem.Allocator) void {
        if (self.result) |*result|
            result.deinit();
        if (self.abort_reason) |*reason|
            reason.deinit();
        self.response_body.releaseAfterQueuedResourcesReleased(allocator);
        self.result_arena.deinit();
        self.deferred.deinit();
        freeHeaders(allocator, self.headers);
        allocator.free(self.body);
        allocator.free(self.method);
        allocator.free(self.url);
        self.* = undefined;
    }

    pub fn replaceRequest(
        self: *Task,
        allocator: std.mem.Allocator,
        url: []const u8,
        method: []const u8,
        body: []const u8,
        headers: []const Header,
    ) !void {
        const next_url = try allocator.dupe(u8, url);
        errdefer allocator.free(next_url);
        const next_method = try allocator.dupe(u8, method);
        errdefer allocator.free(next_method);
        const next_body = try allocator.dupe(u8, body);
        errdefer allocator.free(next_body);
        const next_headers = try cloneHttpHeaders(allocator, headers);
        errdefer freeHeaders(allocator, next_headers);

        allocator.free(self.url);
        allocator.free(self.method);
        allocator.free(self.body);
        freeHeaders(allocator, self.headers);
        self.url = next_url;
        self.method = next_method;
        self.body = next_body;
        self.headers = next_headers;
    }

    pub fn markCanceled(self: *Task) void {
        self.canceled = true;
    }

    pub fn setAbortReason(self: *Task, reason: *bindings.Value) void {
        if (self.abort_reason) |*old|
            old.deinit();
        self.abort_reason = reason.*;
        reason.* = .{};
    }

    pub fn isCanceled(self: *Task) bool {
        return self.canceled;
    }

    pub fn takeAbortReason(self: *Task) ?bindings.Value {
        const reason = self.abort_reason orelse return null;
        self.abort_reason = null;
        return reason;
    }
};

fn cloneBindingHeaders(allocator: std.mem.Allocator, headers: []const bindings.NameValuePair) ![]Header {
    const out = try allocator.alloc(Header, headers.len);
    errdefer allocator.free(out);
    var initialized: usize = 0;
    errdefer freeHeaderFields(allocator, out[0..initialized]);
    for (headers, 0..) |header, index| {
        out[index] = try cloneBindingHeader(allocator, header);
        initialized += 1;
    }
    return out;
}

pub fn cloneHttpHeaders(allocator: std.mem.Allocator, headers: []const Header) ![]Header {
    const out = try allocator.alloc(Header, headers.len);
    errdefer allocator.free(out);
    var initialized: usize = 0;
    errdefer freeHeaderFields(allocator, out[0..initialized]);
    for (headers, 0..) |header, index| {
        out[index] = try cloneHttpHeader(allocator, header);
        initialized += 1;
    }
    return out;
}

fn cloneBindingHeader(allocator: std.mem.Allocator, header: bindings.NameValuePair) !Header {
    const name = try cloneRawString(allocator, header.name);
    errdefer allocator.free(name);
    const value = try cloneRawString(allocator, header.value);
    errdefer allocator.free(value);
    return .{ .name = name, .value = value };
}

fn cloneHttpHeader(allocator: std.mem.Allocator, header: Header) !Header {
    const name = try allocator.dupe(u8, header.name);
    errdefer allocator.free(name);
    const value = try allocator.dupe(u8, header.value);
    errdefer allocator.free(value);
    return .{ .name = name, .value = value };
}

pub fn freeHeaders(allocator: std.mem.Allocator, headers: []Header) void {
    freeHeaderFields(allocator, headers);
    allocator.free(headers);
}

fn freeHeaderFields(allocator: std.mem.Allocator, headers: []Header) void {
    for (headers) |header| {
        allocator.free(header.name);
        allocator.free(header.value);
    }
}

fn cloneRawString(allocator: std.mem.Allocator, raw: bindings.RawString) ![]u8 {
    if (raw.len == 0)
        return try allocator.dupe(u8, "");
    const ptr = raw.ptr orelse return error.InvalidFetchHeader;
    return try allocator.dupe(u8, ptr[0..raw.len]);
}

pub fn bindResponseHeaders(allocator: std.mem.Allocator, headers: anytype) ![]bindings.NameValuePair {
    const pairs = try allocator.alloc(bindings.NameValuePair, headers.len);
    for (headers, 0..) |header, index| {
        pairs[index] = .{
            .name = .{ .ptr = if (header.name.len == 0) null else header.name.ptr, .len = header.name.len },
            .value = .{ .ptr = if (header.value.len == 0) null else header.value.ptr, .len = header.value.len },
        };
    }
    return pairs;
}

pub fn cloneBindResponseHeaders(allocator: std.mem.Allocator, headers: anytype) ![]bindings.NameValuePair {
    const pairs = try allocator.alloc(bindings.NameValuePair, headers.len);
    errdefer allocator.free(pairs);
    var total_bytes: usize = 0;
    for (headers) |header| {
        total_bytes = try std.math.add(usize, total_bytes, header.name.len);
        total_bytes = try std.math.add(usize, total_bytes, header.value.len);
    }
    var bytes: []u8 = &.{};
    if (total_bytes != 0)
        bytes = try allocator.alloc(u8, total_bytes);
    errdefer if (total_bytes != 0) allocator.free(bytes);
    var offset: usize = 0;
    for (headers, 0..) |header, index| {
        const name = bytes[offset .. offset + header.name.len];
        offset += header.name.len;
        const value = bytes[offset .. offset + header.value.len];
        offset += header.value.len;
        @memcpy(name, header.name);
        @memcpy(value, header.value);
        pairs[index] = .{
            .name = .{ .ptr = if (name.len == 0) null else name.ptr, .len = name.len },
            .value = .{ .ptr = if (value.len == 0) null else value.ptr, .len = value.len },
        };
    }
    std.debug.assert(offset == total_bytes);
    return pairs;
}
