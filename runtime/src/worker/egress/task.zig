//! The record of one fetch a worker's JavaScript started: a copy of the
//! request, its upload progress toward the gateway, the result once the
//! gateway answers, and the promise to settle. Runs on the worker's VM
//! thread.
//!
//! A task holds one reference on its response body and owns its deferred;
//! `deinit` releases both. `done` turns true once, when
//! `task_runtime.publishResult` stores the result, and a later result is
//! dropped. The result's strings live in `result_arena` or are static
//! literals, so a `Result` owns nothing.

const std = @import("std");
const bindings = @import("collo_bindings");
const http = @import("collo_http");
const ipc = @import("collo_ipc");
const promise_deferred = @import("collo_worker_js").deferred;
const body_mod = @import("body/body.zig");

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
        /// `network_denied` when the network setting of the fetch's route
        /// refused it at the gateway, whose message then names the origin
        /// and what to change; the rejection also goes to the tenant's log
        /// (`completion_runtime.deliver`).
        cause: ipc.EgressFetchErrorCause = .failed,
    },
};

pub const Task = struct {
    id: u64,
    request_id: u64,
    url: []u8,
    method: []u8,
    body: []u8,
    headers: []Header,
    flags: u32,
    response_body_identity: bindings.FetchBodyIdentity,
    response_body: *body_mod.Body,
    deferred: promise_deferred.DeferredOwned,
    /// The task has its answer, and its `fetch_completion` was queued.
    done: bool = false,
    /// The task's `fetch_completion` item is in the ready queue: set with
    /// `done` (`task_runtime.publishResult`) and cleared when the item pops
    /// (`State.noteReadyItemPopped`). A task destroyed while it is set hands
    /// its item to `State.completion_ready_orphans`.
    ready_queued: bool = false,
    /// JavaScript aborted the fetch or its request ended, so the completion
    /// rejects (`completion_runtime.execute`).
    canceled: bool = false,
    /// True once the start packet is in the command ring. A full ring is not
    /// fatal: a parked task with `start_sent` false sends the whole start
    /// again on the next upload pass.
    start_sent: bool = false,
    /// Request-body bytes already placed in the upload pool and announced;
    /// `body` is the staging buffer the remaining extents copy from.
    upload_bytes_sent: u64 = 0,
    /// True while the task sits in `State.pending_uploads`, still owing the
    /// gateway its start or body bytes.
    upload_parked: bool = false,
    abort_reason: ?bindings.Value = null,
    result: ?Result = null,
    result_arena: std.heap.ArenaAllocator,
    /// CLOCK_MONOTONIC time at which the gateway published the head or error
    /// packet that settled this task, or 0 when something else settled it: a
    /// detach, a stop's acknowledgment or an upload failure. The
    /// `fetch_completion` enqueue carries it, so the request's I/O interval
    /// closes when the answer arrived rather than when the loop got to it.
    ready_at_mono_ns: u64 = 0,

    pub const Request = struct {
        url: []const u8,
        method: []const u8,
        body: []const u8,
        headers: []const bindings.NameValuePair,
        flags: u32,
    };

    /// Copies `request` and takes ownership of `deferred` on every path: on
    /// error it is released here. Once this succeeds, the caller retains
    /// `response_body` for the task, and `deinit` drops that reference.
    pub fn init(
        allocator: std.mem.Allocator,
        id: u64,
        request_id: u64,
        request: Request,
        response_body_identity: bindings.FetchBodyIdentity,
        response_body: *body_mod.Body,
        deferred: promise_deferred.DeferredOwned,
    ) !Task {
        var owned_deferred = deferred;
        errdefer owned_deferred.deinit();
        var result_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer result_arena.deinit();

        const owned_url = try allocator.dupe(u8, request.url);
        errdefer allocator.free(owned_url);
        const owned_method = try allocator.dupe(u8, request.method);
        errdefer allocator.free(owned_method);
        const owned_body = try allocator.dupe(u8, request.body);
        errdefer allocator.free(owned_body);
        const owned_headers = try cloneBindingHeaders(allocator, request.headers);
        return .{
            .id = id,
            .request_id = request_id,
            .url = owned_url,
            .method = owned_method,
            .body = owned_body,
            .headers = owned_headers,
            .flags = request.flags,
            .response_body_identity = response_body_identity,
            .response_body = response_body,
            .deferred = owned_deferred,
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

    /// Notes that the task's `fetch_completion` item left the ready queue,
    /// whether or not it runs (`State.noteReadyItemPopped`).
    pub fn noteReadyItemPopped(self: *Task) void {
        std.debug.assert(self.done);
        std.debug.assert(self.ready_queued);
        self.ready_queued = false;
    }

    pub fn deinit(self: *Task, allocator: std.mem.Allocator) void {
        if (self.abort_reason) |*reason|
            reason.deinit();
        self.response_body.release(allocator);
        self.result_arena.deinit();
        self.deferred.deinit();
        freeHeaders(allocator, self.headers);
        allocator.free(self.body);
        allocator.free(self.method);
        allocator.free(self.url);
        self.* = undefined;
    }

    /// Keeps `reason`, taking it over, for the rejection of a canceled task.
    pub fn setAbortReason(self: *Task, reason: *bindings.Value) void {
        if (self.abort_reason) |*old|
            old.deinit();
        self.abort_reason = reason.*;
        reason.* = .{};
    }

    pub fn takeAbortReason(self: *Task) ?bindings.Value {
        const reason = self.abort_reason orelse return null;
        self.abort_reason = null;
        return reason;
    }
};

/// Copies `headers` into one allocation, names and values back to back, as
/// the ABI pairs the bridge reads. The strings of a pair with an empty name
/// or value are null. The caller frees the pairs and the bytes, which share
/// the result arena in practice.
pub fn cloneBindResponseHeaders(allocator: std.mem.Allocator, headers: []const ipc.RequestHeader) ![]bindings.NameValuePair {
    const pairs = try allocator.alloc(bindings.NameValuePair, headers.len);
    errdefer allocator.free(pairs);
    var total_bytes: usize = 0;
    for (headers) |header| {
        total_bytes = try std.math.add(usize, total_bytes, header.name.len);
        total_bytes = try std.math.add(usize, total_bytes, header.value.len);
    }
    const bytes = try allocator.alloc(u8, total_bytes);
    errdefer allocator.free(bytes);
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

fn cloneBindingHeaders(allocator: std.mem.Allocator, headers: []const bindings.NameValuePair) ![]Header {
    const out = try allocator.alloc(Header, headers.len);
    errdefer allocator.free(out);
    var initialized: usize = 0;
    errdefer freeHeaderFields(allocator, out[0..initialized]);
    for (headers, 0..) |header, index| {
        const name = try cloneRawString(allocator, header.name);
        errdefer allocator.free(name);
        out[index] = .{ .name = name, .value = try cloneRawString(allocator, header.value) };
        initialized += 1;
    }
    return out;
}

fn freeHeaders(allocator: std.mem.Allocator, headers: []Header) void {
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
