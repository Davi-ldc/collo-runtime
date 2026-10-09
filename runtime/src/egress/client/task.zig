//! The gateway's fetch task: one outbound request with its redirect chain,
//! meter totals and published result, shared by the gateway thread and the
//! engine.
//!
//! A task holds no worker or JSC promise state; the worker settles its promise
//! from its own wrapper. Tasks on the heap are reference-counted because the
//! engine keeps using a task after it publishes the result, and the last
//! holder frees it. Everything a task owns comes from its allocator except a
//! body it took as an `OwnedBody`, which goes back to the allocator that came
//! with it.

const std = @import("std");
const bindings = @import("collo_bindings");
const http = @import("collo_http");
const fetch_body = @import("collo_egress_core").fetch_body;
const decompress = @import("collo_egress_core").decompress;

const Header = http.Header;

pub const Result = union(enum) {
    success: struct {
        status: u16,
        status_text: []const u8 = "",
        url: []u8,
        body_identity: bindings.FetchBodyIdentity,
        headers: []const bindings.NameValuePair = &.{},
        redirected: bool = false,
        /// Content coding of the bytes in this task's fetch body. HTTP/2
        /// bodies travel encoded and the worker decodes them; HTTP/1 bodies
        /// are decoded in the gateway and stay `.identity`.
        body_encoding: decompress.Encoding = .identity,
    },
    failure: struct {
        message: []const u8,
        owned: bool = true,
    },

    pub fn deinit(self: *Result) void {
        self.* = undefined;
    }
};

/// A request body allocated elsewhere, handed to a task with the allocator
/// that allocated it, which the task frees it with. The task's last holder may
/// run on any engine thread, so that allocator must accept frees from them.
pub const OwnedBody = struct {
    bytes: []u8,
    allocator: std.mem.Allocator,
};

pub const Task = struct {
    allocator: std.mem.Allocator,
    id: u64,
    request_id: u64,
    url: []u8,
    method: []u8,
    body: []u8,
    /// The allocator `body` goes back to: `allocator` for a body the task
    /// copied, or the one an `OwnedBody` came with.
    body_allocator: std.mem.Allocator,
    headers: []Header,
    flags: u32,
    redirect_count: usize,
    response_body_identity: bindings.FetchBodyIdentity,
    response_body: *fetch_body.Body,
    mutex: std.Thread.Mutex,
    done: bool,
    queued: bool,
    canceled: bool,
    /// Atomic because its writers share no lock with its readers: the gateway
    /// assigns it when it indexes the fetch and zeroes it when the fetch
    /// retires, while engine threads copy it into wake tokens at any time. A
    /// zero token makes the gateway scan its active fetches, and a stale one
    /// no longer matches and is dropped. Monotonic ordering is enough because
    /// the value is a routing hint, never a synchronization edge.
    ready_generation: std.atomic.Value(u64),
    /// Meter totals of the transport attempts this task has finished. The
    /// live attempt adds its own meters and reports the sums to the fetch
    /// body as absolute totals. A redirect hop adds billed and cost bytes,
    /// since the client asked for the chain; a retried attempt adds cost
    /// only, since the client never asked for the retry. The totals live on
    /// the task because each attempt's meters restart at zero (an HTTP/2 hop
    /// frees its pending entry, an HTTP/1 hop starts a fresh exchange), and
    /// the body's monotonic-max fold would otherwise lose earlier hops.
    /// The gateway thread adds a redispatched fetch's cost before submitting
    /// it and the engine's owner thread adds later hops; no two accesses
    /// overlap within one attempt, so monotonic ordering suffices.
    egress_billed_sent_base: std.atomic.Value(u64),
    egress_billed_received_base: std.atomic.Value(u64),
    egress_cost_base: std.atomic.Value(u64),
    result: ?Result,
    result_arena: std.heap.ArenaAllocator,
    /// The engine keeps using the task after it publishes the headers-first
    /// result (cancel probes, body-credit bookkeeping), while the gateway
    /// drops it as soon as the fetch retires. Each side holds a reference, so
    /// the last holder destroys the task whatever the publication order. A
    /// heap task is released, never deinit'd directly.
    refs: std.atomic.Value(u32),

    pub const ReadyToken = struct {
        task: *Task,
        generation: u64,
    };

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
    ) !Task {
        const owned_body = try allocator.dupe(u8, body);
        errdefer allocator.free(owned_body);
        return initOwnedBody(
            allocator,
            id,
            request_id,
            url,
            method,
            .{ .bytes = owned_body, .allocator = allocator },
            headers,
            flags,
            response_body_identity,
            response_body,
        );
    }

    /// Like `init`, but takes ownership of `owned_body` instead of copying
    /// it, so an upload body the gateway assembled moves into the task
    /// without a copy and goes back to its own allocator. On error the caller
    /// still owns the body.
    pub fn initOwnedBody(
        allocator: std.mem.Allocator,
        id: u64,
        request_id: u64,
        url: []const u8,
        method: []const u8,
        owned_body: OwnedBody,
        headers: []const bindings.NameValuePair,
        flags: u32,
        response_body_identity: bindings.FetchBodyIdentity,
        response_body: *fetch_body.Body,
    ) !Task {
        var result_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer result_arena.deinit();

        const owned_url = try allocator.dupe(u8, url);
        errdefer allocator.free(owned_url);
        const owned_method = try allocator.dupe(u8, method);
        errdefer allocator.free(owned_method);
        const owned_headers = try cloneBindingHeaders(allocator, headers);
        errdefer freeHeaders(allocator, owned_headers);
        return .{
            .allocator = allocator,
            .id = id,
            .request_id = request_id,
            .url = owned_url,
            .method = owned_method,
            .body = owned_body.bytes,
            .body_allocator = owned_body.allocator,
            .headers = owned_headers,
            .flags = flags,
            .redirect_count = 0,
            .response_body_identity = response_body_identity,
            .response_body = response_body,
            .mutex = .{},
            .done = false,
            .queued = false,
            .canceled = false,
            .ready_generation = .init(0),
            .egress_billed_sent_base = .init(0),
            .egress_billed_received_base = .init(0),
            .egress_cost_base = .init(0),
            .result = null,
            .result_arena = result_arena,
            .refs = .init(1),
        };
    }

    pub fn retain(self: *Task) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    /// Drops one reference; the last holder deinits and destroys the task.
    /// Valid only for a task created with `allocator.create` and initialized
    /// with the same allocator.
    pub fn release(self: *Task) void {
        const previous = self.refs.fetchSub(1, .acq_rel);
        std.debug.assert(previous != 0);
        if (previous != 1)
            return;
        const allocator = self.allocator;
        self.deinit();
        allocator.destroy(self);
    }

    pub fn resultAllocator(self: *Task) std.mem.Allocator {
        return self.result_arena.allocator();
    }

    pub fn deinit(self: *Task) void {
        const allocator = self.allocator;
        if (self.result) |*result|
            result.deinit();
        self.response_body.releaseAfterQueuedResourcesReleased(allocator);
        self.result_arena.deinit();
        freeHeaders(allocator, self.headers);
        self.body_allocator.free(self.body);
        allocator.free(self.method);
        allocator.free(self.url);
        self.* = undefined;
    }

    /// Replaces the request with a redirect hop's, copying everything into
    /// the task's allocator; `body` may be a slice of the current body. On
    /// error the task keeps its current request.
    pub fn replaceRequest(
        self: *Task,
        url: []const u8,
        method: []const u8,
        body: []const u8,
        headers: []const Header,
    ) !void {
        const allocator = self.allocator;
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
        self.body_allocator.free(self.body);
        freeHeaders(allocator, self.headers);
        self.url = next_url;
        self.method = next_method;
        self.body = next_body;
        self.body_allocator = allocator;
        self.headers = next_headers;
    }

    pub fn markCanceled(self: *Task) void {
        self.mutex.lock();
        self.canceled = true;
        self.mutex.unlock();
    }

    pub fn isCanceled(self: *Task) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.canceled;
    }

    pub fn readyToken(self: *Task) ReadyToken {
        return .{
            .task = self,
            .generation = self.ready_generation.load(.monotonic),
        };
    }

    pub const EgressBase = struct {
        billed_sent: u64 = 0,
        billed_received: u64 = 0,
        cost: u64 = 0,
    };

    /// Adds a finished attempt's meters to the task's totals. A retried
    /// attempt passes zero billed bytes; its cost is real either way.
    pub fn addEgressBase(self: *Task, billed_sent: u64, billed_received: u64, cost: u64) void {
        if (billed_sent != 0)
            _ = self.egress_billed_sent_base.fetchAdd(billed_sent, .monotonic);
        if (billed_received != 0)
            _ = self.egress_billed_received_base.fetchAdd(billed_received, .monotonic);
        if (cost != 0)
            _ = self.egress_cost_base.fetchAdd(cost, .monotonic);
    }

    pub fn egressBase(self: *const Task) EgressBase {
        return .{
            .billed_sent = self.egress_billed_sent_base.load(.monotonic),
            .billed_received = self.egress_billed_received_base.load(.monotonic),
            .cost = self.egress_cost_base.load(.monotonic),
        };
    }
};

fn cloneBindingHeaders(allocator: std.mem.Allocator, headers: []const bindings.NameValuePair) ![]Header {
    const out = try allocator.alloc(Header, headers.len);
    var initialized: usize = 0;
    errdefer {
        freeHeaderFields(allocator, out[0..initialized]);
        allocator.free(out);
    }
    for (headers, 0..) |header, index| {
        out[index] = try cloneBindingHeader(allocator, header);
        initialized += 1;
    }
    return out;
}

pub fn cloneHttpHeaders(allocator: std.mem.Allocator, headers: []const Header) ![]Header {
    const out = try allocator.alloc(Header, headers.len);
    var initialized: usize = 0;
    errdefer {
        freeHeaderFields(allocator, out[0..initialized]);
        allocator.free(out);
    }
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
