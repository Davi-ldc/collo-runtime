//! The DispatchWork payload: one request as the host sends it to a worker,
//! and the worker's owned copy of it. The codec holds no state, so any thread
//! may call it.
//!
//! An encoded packet is a `messages.DispatchPacketHeader` followed by, in
//! order, the authority, method, path and raw query, and the request headers
//! and the route captures as `NameValuePacket` sections. The header names the
//! request's route by its index in the route table of the worker's
//! definition, which the worker checks against its table. The decoder treats
//! the bytes as hostile: it checks every length against the packet before
//! reading the section, and refuses a packet with bytes after the route
//! captures, a header whose reserved field is not zero, and an empty
//! authority. The header's egress token is copied unread: the worker never
//! interprets it and only the gateway can verify it, and `egress_token.none`
//! is valid here, for a worker without an egress session.

const std = @import("std");
const packet = @import("packet.zig");
const messages = @import("messages.zig");
const egress_token = @import("egress_token.zig");

const DispatchPacketHeader = messages.DispatchPacketHeader;
const DispatchWorkView = messages.DispatchWorkView;
const NameValuePacket = messages.NameValuePacket;
const RequestHeader = messages.RequestHeader;
const RouteCapture = messages.RouteCapture;

const Range = struct {
    start: usize,
    end: usize,

    fn slice(self: Range, storage: []u8) []u8 {
        return storage[self.start..self.end];
    }
};

const DispatchLayout = struct {
    header: DispatchPacketHeader,
    body_framing: messages.RequestBodyFraming,
    authority: Range,
    method: Range,
    path: Range,
    raw_query: Range,
    request_headers: Range,
    route_captures: Range,
};

/// A dispatch that owns its bytes: every slice points into `storage` or into
/// the header and capture arrays, all from `allocator`, until `deinit`.
pub const DispatchWork = struct {
    allocator: std.mem.Allocator,
    storage: []u8 = &.{},
    request_id: u64,
    request_lane_id: u16 = 0,
    request_slot: u32 = 0,
    request_generation: u64 = 0,
    /// As `messages.DispatchWorkView.egress_token`.
    egress_token: egress_token.Bytes = egress_token.none,
    worker_id: u64 = 0,
    worker_generation: u64 = 0,
    accounting_flags: u32 = 0,
    authority: []const u8,
    deadline_monotonic_ns: u64,
    method: []const u8,
    path: []const u8,
    raw_query: []const u8,
    request_headers: []RequestHeader,
    body_framing: messages.RequestBodyFraming,
    route_captures: []RouteCapture,
    /// As `messages.DispatchWorkView.route_index`.
    route_index: u16,

    /// Copies `input` into one allocation. The caller keeps `input` and owns
    /// the result.
    pub fn initOwned(allocator: std.mem.Allocator, input: DispatchWorkView) !DispatchWork {
        try messages.validateRequestBodyFraming(input.body_framing);

        const storage_len = try dispatchWorkStorageLen(
            input.authority,
            input.method,
            input.path,
            input.raw_query,
            input.request_headers,
            input.route_captures,
        );
        const storage = try allocator.alloc(u8, storage_len);
        errdefer if (storage.len != 0) allocator.free(storage);

        const owned_headers = try allocator.alloc(RequestHeader, input.request_headers.len);
        errdefer allocator.free(owned_headers);
        const owned_captures = try allocator.alloc(RouteCapture, input.route_captures.len);
        errdefer allocator.free(owned_captures);

        var cursor: usize = 0;
        const owned_authority = copyDispatchStorageSlice(storage, &cursor, input.authority);
        const owned_method = copyDispatchStorageSlice(storage, &cursor, input.method);
        const owned_path = copyDispatchStorageSlice(storage, &cursor, input.path);
        const owned_raw_query = copyDispatchStorageSlice(storage, &cursor, input.raw_query);
        for (input.request_headers, 0..) |header, index| {
            owned_headers[index] = .{
                .name = copyDispatchStorageSlice(storage, &cursor, header.name),
                .value = copyDispatchStorageSlice(storage, &cursor, header.value),
            };
        }
        for (input.route_captures, 0..) |capture, index| {
            owned_captures[index] = .{
                .name = copyDispatchStorageSlice(storage, &cursor, capture.name),
                .value = copyDispatchStorageSlice(storage, &cursor, capture.value),
            };
        }
        std.debug.assert(cursor == storage.len);

        return .{
            .allocator = allocator,
            .storage = storage,
            .request_id = input.request_id,
            .request_lane_id = input.request_lane_id,
            .request_slot = input.request_slot,
            .request_generation = input.request_generation,
            .egress_token = input.egress_token,
            .worker_id = input.worker_id,
            .worker_generation = input.worker_generation,
            .accounting_flags = input.accounting_flags,
            .authority = owned_authority,
            .deadline_monotonic_ns = input.deadline_monotonic_ns,
            .method = owned_method,
            .path = owned_path,
            .raw_query = owned_raw_query,
            .request_headers = owned_headers,
            .body_framing = input.body_framing,
            .route_captures = owned_captures,
            .route_index = input.route_index,
        };
    }

    /// The identity of a worker's boot context, which module top-level code
    /// of every route runs under for its fetches and timers. `request_id` is
    /// the boot context's id inside the worker (`boot_request_id` in
    /// `worker/request/context.zig`). It carries nothing a real dispatch reads
    /// from the wire: the boot context never dispatches and names no route,
    /// and its fetches present `boot_egress_token`, WorkerInit's boot token,
    /// whose request id and generation are 0.
    pub fn initBoot(
        allocator: std.mem.Allocator,
        request_id: u64,
        boot_egress_token: *const egress_token.Bytes,
    ) !DispatchWork {
        const owned_headers = try allocator.alloc(RequestHeader, 0);
        errdefer allocator.free(owned_headers);
        const owned_captures = try allocator.alloc(RouteCapture, 0);
        errdefer allocator.free(owned_captures);
        return .{
            .allocator = allocator,
            .request_id = request_id,
            .egress_token = boot_egress_token.*,
            .authority = "",
            .deadline_monotonic_ns = 0,
            .method = "",
            .path = "",
            .raw_query = "",
            .request_headers = owned_headers,
            .body_framing = .none,
            .route_captures = owned_captures,
            .route_index = 0,
        };
    }

    pub fn deinit(self: *DispatchWork) void {
        self.allocator.free(self.request_headers);
        self.allocator.free(self.route_captures);
        if (self.storage.len != 0)
            self.allocator.free(self.storage);
        self.* = undefined;
    }

    /// Borrows every slice from `self`, which must outlive the view.
    pub fn view(self: *const DispatchWork) DispatchWorkView {
        return .{
            .request_id = self.request_id,
            .request_lane_id = self.request_lane_id,
            .request_slot = self.request_slot,
            .request_generation = self.request_generation,
            .egress_token = self.egress_token,
            .worker_id = self.worker_id,
            .worker_generation = self.worker_generation,
            .accounting_flags = self.accounting_flags,
            .authority = self.authority,
            .deadline_monotonic_ns = self.deadline_monotonic_ns,
            .method = self.method,
            .path = self.path,
            .raw_query = self.raw_query,
            .request_headers = self.request_headers,
            .body_framing = self.body_framing,
            .route_captures = self.route_captures,
            .route_index = self.route_index,
        };
    }
};

/// Encodes `message` into `scratch`, which must hold `messages.max_message_bytes`,
/// and returns the encoded prefix. Fails with `error.DispatchScratchTooSmall`
/// for a shorter scratch, `error.MessageTooLarge` for a packet above
/// `messages.max_message_bytes`, and `error.TooManyRouteCaptures` or
/// `error.TooManyRequestHeaders` above their counts in `messages.zig`.
pub fn encodeDispatchWorkInto(scratch: []u8, message: *const DispatchWorkView) ![]u8 {
    if (scratch.len < messages.max_message_bytes)
        return error.DispatchScratchTooSmall;
    if (message.route_captures.len > messages.max_route_capture_count)
        return error.TooManyRouteCaptures;
    if (message.request_headers.len > messages.max_request_header_count)
        return error.TooManyRequestHeaders;
    try messages.validateRequestBodyFraming(message.body_framing);

    const captures_bytes_len = try capturesByteLenChecked(message.route_captures);
    const request_headers_bytes_len = try requestHeadersByteLenChecked(message.request_headers);
    var total_len: usize = 0;
    try addMessageLen(&total_len, @sizeOf(DispatchPacketHeader));
    try addMessageLen(&total_len, message.authority.len);
    try addMessageLen(&total_len, message.method.len);
    try addMessageLen(&total_len, message.path.len);
    try addMessageLen(&total_len, message.raw_query.len);
    try addMessageLen(&total_len, request_headers_bytes_len);
    try addMessageLen(&total_len, captures_bytes_len);

    const encoded = scratch[0..total_len];

    var header = std.mem.zeroes(DispatchPacketHeader);
    header.kind = @intFromEnum(messages.MessageKind.dispatch_work);
    header.request_id = message.request_id;
    header.request_lane_id = message.request_lane_id;
    header.request_slot = message.request_slot;
    header.request_generation = message.request_generation;
    header.egress_token = message.egress_token;
    header.worker_id = message.worker_id;
    header.worker_generation = message.worker_generation;
    header.deadline_monotonic_ns = message.deadline_monotonic_ns;
    header.accounting_flags = message.accounting_flags;
    header.route_index = message.route_index;
    header.authority_len = @intCast(message.authority.len);
    header.method_len = @intCast(message.method.len);
    header.path_len = @intCast(message.path.len);
    header.raw_query_len = @intCast(message.raw_query.len);
    header.request_header_count = @intCast(message.request_headers.len);
    header.request_headers_bytes_len = @intCast(request_headers_bytes_len);
    header.body_framing = @intFromEnum(message.body_framing);
    header.route_capture_count = @intCast(message.route_captures.len);
    header.route_captures_bytes_len = @intCast(captures_bytes_len);

    var cursor: usize = 0;
    cursor += packet.writeStruct(encoded[cursor..], &header);
    cursor += packet.writeSlice(encoded[cursor..], message.authority);
    cursor += packet.writeSlice(encoded[cursor..], message.method);
    cursor += packet.writeSlice(encoded[cursor..], message.path);
    cursor += packet.writeSlice(encoded[cursor..], message.raw_query);
    cursor += writeNameValues(encoded[cursor..], message.request_headers);
    cursor += writeNameValues(encoded[cursor..], message.route_captures);
    std.debug.assert(cursor == encoded.len);
    return encoded;
}

/// Decodes a packet into a `DispatchWork` that owns a copy of it, checked
/// as the file header describes. `encoded` stays the caller's.
pub fn decodeDispatchWork(allocator: std.mem.Allocator, encoded: []const u8) !DispatchWork {
    const layout = try parseDispatchLayout(encoded);
    const storage = try allocator.dupe(u8, encoded);
    errdefer allocator.free(storage);
    return materializeDispatchWorkFromStorage(allocator, storage, &layout);
}

fn materializeDispatchWorkFromStorage(allocator: std.mem.Allocator, storage: []u8, layout: *const DispatchLayout) !DispatchWork {
    const request_headers = try readRequestHeaders(allocator, storage, layout);
    errdefer allocator.free(request_headers);
    const route_captures = try readRouteCaptures(allocator, storage, layout);
    errdefer allocator.free(route_captures);

    return .{
        .allocator = allocator,
        .storage = storage,
        .request_id = layout.header.request_id,
        .request_lane_id = layout.header.request_lane_id,
        .request_slot = layout.header.request_slot,
        .request_generation = layout.header.request_generation,
        .egress_token = layout.header.egress_token,
        .worker_id = layout.header.worker_id,
        .worker_generation = layout.header.worker_generation,
        .accounting_flags = layout.header.accounting_flags,
        .authority = layout.authority.slice(storage),
        .deadline_monotonic_ns = layout.header.deadline_monotonic_ns,
        .method = layout.method.slice(storage),
        .path = layout.path.slice(storage),
        .raw_query = layout.raw_query.slice(storage),
        .request_headers = request_headers,
        .body_framing = layout.body_framing,
        .route_captures = route_captures,
        .route_index = layout.header.route_index,
    };
}

fn parseDispatchLayout(encoded: []const u8) !DispatchLayout {
    if (encoded.len < @sizeOf(DispatchPacketHeader))
        return error.ShortRead;

    const header = packet.readStruct(DispatchPacketHeader, encoded[0..@sizeOf(DispatchPacketHeader)]);
    if (try messages.decodeMessageKind(header.kind) != .dispatch_work)
        return error.InvalidMessageKind;
    if (header._reserved0 != 0)
        return error.InvalidPacket;

    var cursor: usize = @sizeOf(DispatchPacketHeader);
    const authority = try readRange(encoded, &cursor, header.authority_len);
    const method = try readRange(encoded, &cursor, header.method_len);
    const path = try readRange(encoded, &cursor, header.path_len);
    const raw_query = try readRange(encoded, &cursor, header.raw_query_len);
    const request_headers = try validateNameValueSection(
        encoded,
        cursor,
        header.request_header_count,
        header.request_headers_bytes_len,
        messages.max_request_header_count,
        error.TooManyRequestHeaders,
    );
    cursor = request_headers.end;
    const route_captures = try validateNameValueSection(
        encoded,
        cursor,
        header.route_capture_count,
        header.route_captures_bytes_len,
        messages.max_route_capture_count,
        error.InvalidPacket,
    );
    cursor = route_captures.end;
    if (cursor != encoded.len)
        return error.InvalidPacket;
    if (authority.start == authority.end)
        return error.MissingAuthority;
    const body_framing = try messages.decodeRequestBodyFraming(header.body_framing);
    try messages.validateRequestBodyFraming(body_framing);

    return .{
        .header = header,
        .body_framing = body_framing,
        .authority = authority,
        .method = method,
        .path = path,
        .raw_query = raw_query,
        .request_headers = request_headers,
        .route_captures = route_captures,
    };
}

fn readRange(encoded: []const u8, cursor: *usize, len: u32) !Range {
    const start = cursor.*;
    const end = std.math.add(usize, start, @as(usize, len)) catch return error.InvalidPacket;
    if (end > encoded.len)
        return error.ShortRead;
    cursor.* = end;
    return .{ .start = start, .end = end };
}

fn validateNameValueSection(
    encoded: []const u8,
    start: usize,
    count_raw: u32,
    bytes_len_raw: u32,
    max_count: usize,
    too_many_error: anyerror,
) !Range {
    const count: usize = @intCast(count_raw);
    const bytes_len: usize = @intCast(bytes_len_raw);
    if (count > max_count)
        return too_many_error;
    const min_bytes = std.math.mul(usize, count, @sizeOf(NameValuePacket)) catch return error.InvalidPacket;
    if (bytes_len < min_bytes)
        return error.InvalidPacket;
    const end = std.math.add(usize, start, bytes_len) catch return error.InvalidPacket;
    if (end > encoded.len)
        return error.ShortRead;

    var validate_cursor = start;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        if (validate_cursor + @sizeOf(NameValuePacket) > end)
            return error.InvalidPacket;
        const descriptor = packet.readStruct(NameValuePacket, encoded[validate_cursor .. validate_cursor + @sizeOf(NameValuePacket)]);
        validate_cursor += @sizeOf(NameValuePacket);
        const name_end = std.math.add(usize, validate_cursor, @as(usize, descriptor.name_len)) catch return error.InvalidPacket;
        if (name_end > end)
            return error.InvalidPacket;
        const value_end = std.math.add(usize, name_end, @as(usize, descriptor.value_len)) catch return error.InvalidPacket;
        if (value_end > end)
            return error.InvalidPacket;
        validate_cursor = value_end;
    }
    if (validate_cursor != end)
        return error.InvalidPacket;
    return .{ .start = start, .end = end };
}

fn readRequestHeaders(allocator: std.mem.Allocator, storage: []u8, layout: *const DispatchLayout) ![]RequestHeader {
    const count: usize = @intCast(layout.header.request_header_count);
    const headers = try allocator.alloc(RequestHeader, count);
    errdefer allocator.free(headers);

    var cursor = layout.request_headers.start;
    for (headers) |*header| {
        const descriptor = packet.readStruct(NameValuePacket, storage[cursor .. cursor + @sizeOf(NameValuePacket)]);
        cursor += @sizeOf(NameValuePacket);
        header.* = .{
            .name = try packet.readSlice(storage, &cursor, descriptor.name_len),
            .value = try packet.readSlice(storage, &cursor, descriptor.value_len),
        };
    }

    std.debug.assert(cursor == layout.request_headers.end);
    return headers;
}

fn readRouteCaptures(allocator: std.mem.Allocator, storage: []u8, layout: *const DispatchLayout) ![]RouteCapture {
    const count: usize = @intCast(layout.header.route_capture_count);
    const captures = try allocator.alloc(RouteCapture, count);
    errdefer allocator.free(captures);

    var cursor = layout.route_captures.start;
    for (captures) |*capture| {
        const descriptor = packet.readStruct(NameValuePacket, storage[cursor .. cursor + @sizeOf(NameValuePacket)]);
        cursor += @sizeOf(NameValuePacket);
        capture.* = .{
            .name = try packet.readSlice(storage, &cursor, descriptor.name_len),
            .value = try packet.readSlice(storage, &cursor, descriptor.value_len),
        };
    }

    std.debug.assert(cursor == layout.route_captures.end);
    return captures;
}

fn dispatchWorkStorageLen(
    authority: []const u8,
    method: []const u8,
    path: []const u8,
    raw_query: []const u8,
    request_headers: []const RequestHeader,
    route_captures: []const RouteCapture,
) !usize {
    var total: usize = 0;
    try addMessageLen(&total, authority.len);
    try addMessageLen(&total, method.len);
    try addMessageLen(&total, path.len);
    try addMessageLen(&total, raw_query.len);
    for (request_headers) |header| {
        try addMessageLen(&total, header.name.len);
        try addMessageLen(&total, header.value.len);
    }
    for (route_captures) |capture| {
        try addMessageLen(&total, capture.name.len);
        try addMessageLen(&total, capture.value.len);
    }
    return total;
}

fn copyDispatchStorageSlice(storage: []u8, cursor: *usize, value: []const u8) []u8 {
    const start = cursor.*;
    cursor.* += value.len;
    const dest = storage[start..cursor.*];
    @memcpy(dest, value);
    return dest;
}

fn capturesByteLenChecked(captures: []const RouteCapture) !usize {
    var total: usize = 0;
    for (captures) |capture| {
        try addMessageLen(&total, @sizeOf(NameValuePacket));
        try addMessageLen(&total, capture.name.len);
        try addMessageLen(&total, capture.value.len);
    }
    return total;
}

fn requestHeadersByteLenChecked(headers: []const RequestHeader) !usize {
    var total: usize = 0;
    for (headers) |header| {
        try addMessageLen(&total, @sizeOf(NameValuePacket));
        try addMessageLen(&total, header.name.len);
        try addMessageLen(&total, header.value.len);
    }
    return total;
}

fn addMessageLen(total: *usize, amount: usize) !void {
    const next = std.math.add(usize, total.*, amount) catch return error.MessageTooLarge;
    if (next > messages.max_message_bytes)
        return error.MessageTooLarge;
    total.* = next;
}

fn writeNameValues(dest: []u8, pairs: anytype) usize {
    var cursor: usize = 0;
    for (pairs) |pair| {
        const descriptor = NameValuePacket{
            .name_len = @intCast(pair.name.len),
            .value_len = @intCast(pair.value.len),
        };
        cursor += packet.writeStruct(dest[cursor..], &descriptor);
        cursor += packet.writeSlice(dest[cursor..], pair.name);
        cursor += packet.writeSlice(dest[cursor..], pair.value);
    }
    return cursor;
}
