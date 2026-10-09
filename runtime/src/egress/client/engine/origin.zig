//! Origin parsing for engine routing, and the HTTP/1 origin hint: an https
//! origin whose ALPN chose http/1.1, remembered so later fetches skip the
//! HTTP/2 connect. A hint is scoped by both pool isolation ids as well as
//! host, port and the TLS and private-network settings, so a downgrade
//! learned in one security cell never changes routing in another.

const std = @import("std");
const transport = @import("collo_egress_transport");

pub const Http1OriginHint = struct {
    authority_host_lower: []u8,
    port: u16,
    insecure_tls: bool,
    allow_private_networks: bool,
    pool_security_cell_id: transport.PoolIsolationId,
    pool_policy_id: transport.PoolIsolationId,

    pub fn deinit(self: *Http1OriginHint, allocator: std.mem.Allocator) void {
        allocator.free(self.authority_host_lower);
        self.* = undefined;
    }
};

pub const ParsedHttpsOrigin = struct {
    host: []const u8,
    port: u16,
};

pub fn parseHttpsOrigin(url: []const u8) ?ParsedHttpsOrigin {
    const uri = std.Uri.parse(url) catch return null;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https"))
        return null;
    const host = uri.host orelse return null;
    if (host.percent_encoded.len == 0)
        return null;
    return .{
        .host = host.percent_encoded,
        .port = uri.port orelse 443,
    };
}

pub fn isHttpsUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    return std.ascii.eqlIgnoreCase(uri.scheme, "https");
}
