//! Stand-in for `collo_bindings` in the JSC-free module graph, the `h2_stub`
//! flavor of `runtime/build/modules.zig`. Every module of that graph that
//! imports `collo_bindings` compiles against this file, so it declares the part
//! of `runtime/src/bindings/root.zig` those modules reach, with the same names
//! and the same extern layouts. A declaration nobody in the stub graph
//! references can be left out, since Zig analyzes only what is referenced.
//! It links into the JSC-free test binaries and into the egress benches that
//! `addEgressBenches` in `runtime/build/bench.zig` builds, and runs on the
//! calling thread.

const std = @import("std");

pub const Error = error{
    Internal,
    InvalidJsValue,
};

pub const RawPromiseDeferred = opaque {};
pub const RawValue = opaque {};

pub const RawString = extern struct {
    ptr: ?[*]const u8,
    len: usize,
};

pub const RawBuffer = extern struct {
    ptr: ?[*]const u8,
    len: usize,
};

pub const NameValuePair = extern struct {
    name: RawString,
    value: RawString,
};

pub const FetchInit = extern struct {
    request_id: u64,
    url: RawString,
    method: RawString,
    body: RawBuffer,
    headers: ?[*]const NameValuePair,
    headers_len: usize,
    flags: u32,
    reserved0: u32,
};

pub const ResponseInit = extern struct {
    body: RawBuffer,
    status_text: RawString = .{ .ptr = null, .len = 0 },
    url: RawString = .{ .ptr = null, .len = 0 },
    headers: ?[*]const NameValuePair = null,
    headers_len: usize = 0,
    status: u16 = 200,
    flags: u16 = 0,
    reserved1: u32 = 0,
};

pub const response_init_flag_redirected: u16 = 1 << 0;

pub const FetchBodyIdentity = extern struct {
    request_id: u64,
    request_generation: u64,
    fetch_id: u64,
    body_id: u64,
};

pub const FetchBodyConsumeKind = enum(u8) {
    text = 0,
    json = 1,
    array_buffer = 2,
    bytes = 3,
    blob = 4,
    form_data = 5,
};

pub const FetchBodyConsumeInit = extern struct {
    identity: FetchBodyIdentity,
    content_type: RawString = .{ .ptr = null, .len = 0 },
    kind: u8,
    reserved: [7]u8 = .{ 0, 0, 0, 0, 0, 0, 0 },
};

pub const FetchResponseInit = extern struct {
    response: ResponseInit,
    body_identity: FetchBodyIdentity,
};

pub const TerminationReason = enum(u8) {
    none = 0,
    cpu = 1,
    memory = 2,
    crash = 3,
    init_failed = 4,
    deadline = 5,
};

pub const ExecCtx = extern struct {
    request_id: u64,
    deadline_monotonic_ns: u64,
    cpu_used_ns_total: u64,
    turn_cpu_start_ns: u64,
    termination_reason: u8,
    _reserved: [7]u8,
};

pub const Value = struct {
    handle: ?*RawValue = null,

    pub fn fromRawOwnedNonNull(raw: *RawValue) Value {
        return .{ .handle = raw };
    }

    pub fn deinit(self: *Value) void {
        self.* = .{};
    }

    pub fn retain(self: Value) Error!Value {
        if (self.handle == null)
            return error.InvalidJsValue;
        return self;
    }
};

pub const ValueResult = union(enum) {
    success: Value,
    exception: Value,
};

/// Runs no JavaScript: `invoke`, `invokeWithTiming` and `fetchResponseValue`
/// succeed with an empty value and `isCallable` answers true, so a test in the
/// stub graph can check transport and bookkeeping but never a script's result.
pub const Vm = struct {
    pub fn fetchResponseValue(self: *Vm, init: *const FetchResponseInit) Error!ValueResult {
        _ = self;
        _ = init;
        return .{ .success = .{} };
    }

    pub fn isCallable(self: *Vm, value: *const Value) Error!bool {
        _ = self;
        _ = value;
        return true;
    }

    pub fn invokeWithTiming(
        self: *Vm,
        allocator: std.mem.Allocator,
        exec_ctx: *const ExecCtx,
        callable: *const Value,
        this_value: ?*const Value,
        args: []const *const Value,
        out_call_started_ns: ?*u64,
    ) Error!ValueResult {
        if (out_call_started_ns) |out| out.* = 0;
        return self.invoke(allocator, exec_ctx, callable, this_value, args);
    }

    pub fn invoke(
        self: *Vm,
        allocator: std.mem.Allocator,
        exec_ctx: *const ExecCtx,
        callable: *const Value,
        this_value: ?*const Value,
        args: []const *const Value,
    ) Error!ValueResult {
        _ = self;
        _ = allocator;
        _ = exec_ctx;
        _ = callable;
        _ = this_value;
        _ = args;
        return .{ .success = .{} };
    }
};

pub fn releasePromiseDeferred(raw: *RawPromiseDeferred) void {
    _ = raw;
}

pub fn rawStringSlice(raw: RawString) []const u8 {
    return if (raw.len == 0) "" else raw.ptr.?[0..raw.len];
}

pub fn borrowedBuffer(value: []const u8) RawBuffer {
    return .{
        .ptr = if (value.len == 0) null else value.ptr,
        .len = value.len,
    };
}
