//! The gateway's fetch task: one outbound request with its redirect chain
//! and published result, shared by the gateway thread and the engine.
//!
//! A task holds no worker or JSC promise state; the worker settles its promise
//! from its own wrapper. Tasks on the heap are reference-counted because the
//! engine keeps using a task after it publishes the result, and the last
//! holder frees it. Everything a task owns comes from its allocator except a
//! body it took as an `OwnedBody`, which goes back to the allocator that came
//! with it, and its response queue, which holds a reference of its own.

const std = @import("std");
const http = @import("collo_http");
const core = @import("collo_egress_core");
const transport = @import("transport/root.zig");

const decompress = core.decompress;

const Header = http.Header;
const cloneHeaders = transport.headers.cloneHeaders;
const freeHeaders = transport.headers.freeHeaders;

pub const Result = union(enum) {
    success: struct {
        status: u16,
        status_text: []const u8 = "",
        url: []u8,
        /// In the task's result arena (`copyResponseHeaders`).
        headers: []const Header = &.{},
        redirected: bool = false,
        /// Content coding of the bytes in this task's response queue. HTTP/2
        /// bodies travel encoded and the worker decodes them; HTTP/1 bodies
        /// are decoded in the gateway and stay `.identity`.
        body_encoding: decompress.Encoding = .identity,
    },
    failure: struct {
        /// In the task's result arena, or static.
        message: []const u8,
        cause: FailureCause = .failed,
    },
};

/// Why a fetch failed, as far as its worker must tell the tenant. The
/// gateway maps it onto the error packet's cause at the IPC boundary
/// (`egress/gateway/runtime/body_pump.zig:failureCauseForIpc`).
pub const FailureCause = enum {
    failed,
    /// The fetch's network policy refused a hop; the message names the
    /// hop's origin and what to change (`collo_network.writeDenial`).
    network_denied,
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
    url: []u8,
    method: []u8,
    body: []u8,
    /// The allocator `body` goes back to: `allocator` for a body the task
    /// copied, or the one an `OwnedBody` came with.
    body_allocator: std.mem.Allocator,
    headers: []Header,
    flags: u32,
    redirect_count: usize,
    /// The task's reference to the queue its body goes into, dropped when
    /// the task is destroyed. The queue's identity names the fetch body.
    response_body: *core.ResponseQueue,
    /// Guards `done` and `result`, which the engine publishes and the
    /// gateway reads.
    mutex: std.Thread.Mutex,
    done: bool,
    result: ?Result,
    result_arena: std.heap.ArenaAllocator,
    /// The engine keeps using the task after it publishes the headers-first
    /// result (the body, cancellation, body credits), while the gateway
    /// drops it as soon as the fetch retires. Each side holds a reference, so
    /// the last holder destroys the task whatever the publication order. A
    /// heap task is released, never deinit'd directly.
    refs: std.atomic.Value(u32),
    engine: EngineLink = .{},

    pub const ReadyToken = struct {
        task: *Task,
        generation: u64,
    };

    /// What the engine keeps with a task it was given
    /// (`engine/root.zig:Engine.submit`). `submit` writes the config and the
    /// ready generation once, before the owner thread can see the task, and
    /// nothing writes them after. The flags and a link into a list the
    /// engine still holds change only under the engine's mutex; the thread
    /// that took a whole list off the engine (the owner, or a stop that
    /// settles what the owner never took) clears its links without it.
    pub const EngineLink = struct {
        config: transport.Config = undefined,
        ready_generation: u64 = 0,
        submitted: bool = false,
        next_submitted: ?*Task = null,
        cancel_queued: bool = false,
        next_canceled: ?*Task = null,
    };

    /// Copies the URL, method, headers and body into `allocator`. The task
    /// takes over the caller's reference to `response_body` on success; on
    /// error the caller keeps it.
    pub fn init(
        allocator: std.mem.Allocator,
        id: u64,
        url: []const u8,
        method: []const u8,
        body: []const u8,
        headers: []const Header,
        flags: u32,
        response_body: *core.ResponseQueue,
    ) !Task {
        const owned_body = try allocator.dupe(u8, body);
        errdefer allocator.free(owned_body);
        return initOwnedBody(
            allocator,
            id,
            url,
            method,
            .{ .bytes = owned_body, .allocator = allocator },
            headers,
            flags,
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
        url: []const u8,
        method: []const u8,
        owned_body: OwnedBody,
        headers: []const Header,
        flags: u32,
        response_body: *core.ResponseQueue,
    ) !Task {
        var result_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer result_arena.deinit();

        const owned_url = try allocator.dupe(u8, url);
        errdefer allocator.free(owned_url);
        const owned_method = try allocator.dupe(u8, method);
        errdefer allocator.free(owned_method);
        const owned_headers = try cloneHeaders(allocator, headers);
        errdefer freeHeaders(allocator, owned_headers);
        return .{
            .allocator = allocator,
            .id = id,
            .url = owned_url,
            .method = owned_method,
            .body = owned_body.bytes,
            .body_allocator = owned_body.allocator,
            .headers = owned_headers,
            .flags = flags,
            .redirect_count = 0,
            .response_body = response_body,
            .mutex = .{},
            .done = false,
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

    /// Copies a response head's fields into the result arena, the bytes of
    /// every name and value in one allocation, for `Result.success.headers`.
    pub fn copyResponseHeaders(self: *Task, headers: []const Header) ![]const Header {
        const arena = self.resultAllocator();
        var total_bytes: usize = 0;
        for (headers) |header| {
            total_bytes = try std.math.add(usize, total_bytes, header.name.len);
            total_bytes = try std.math.add(usize, total_bytes, header.value.len);
        }
        const copies = try arena.alloc(Header, headers.len);
        const bytes = try arena.alloc(u8, total_bytes);
        var offset: usize = 0;
        for (headers, copies) |header, *copy| {
            const name = bytes[offset..][0..header.name.len];
            @memcpy(name, header.name);
            offset += name.len;
            const value = bytes[offset..][0..header.value.len];
            @memcpy(value, header.value);
            offset += value.len;
            copy.* = .{ .name = name, .value = value };
        }
        std.debug.assert(offset == total_bytes);
        return copies;
    }

    pub fn deinit(self: *Task) void {
        const allocator = self.allocator;
        self.response_body.release(allocator);
        self.result_arena.deinit();
        freeHeaders(allocator, self.headers);
        self.body_allocator.free(self.body);
        allocator.free(self.method);
        allocator.free(self.url);
        self.* = undefined;
    }

    /// Replaces the request with a redirect hop's, copying the URL, method
    /// and headers into the task's allocator. A kept body stays as it is,
    /// with the allocator it came with, so no hop copies it and no budget
    /// but its own counts it; a dropped body goes back to that allocator.
    /// On error the task keeps its current request.
    pub fn replaceRequest(
        self: *Task,
        url: []const u8,
        method: []const u8,
        body: transport.RedirectBody,
        headers: []const Header,
    ) !void {
        const allocator = self.allocator;
        const next_url = try allocator.dupe(u8, url);
        errdefer allocator.free(next_url);
        const next_method = try allocator.dupe(u8, method);
        errdefer allocator.free(next_method);
        const next_headers = try cloneHeaders(allocator, headers);
        errdefer freeHeaders(allocator, next_headers);

        allocator.free(self.url);
        allocator.free(self.method);
        freeHeaders(allocator, self.headers);
        self.url = next_url;
        self.method = next_method;
        self.headers = next_headers;
        switch (body) {
            .keep => {},
            .drop => {
                self.body_allocator.free(self.body);
                self.body = &.{};
                self.body_allocator = allocator;
            },
        }
    }

    /// What every wake of the engine for this task carries.
    pub fn readyToken(self: *Task) ReadyToken {
        return .{
            .task = self,
            .generation = self.engine.ready_generation,
        };
    }
};
