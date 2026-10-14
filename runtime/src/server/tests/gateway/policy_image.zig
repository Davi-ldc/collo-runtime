//! A compiled policy image for the gateway suites, built the way the server builds its own: a
//! configuration whose one route grants any public host is parsed and compiled by
//! `server/routes/network.zig`, which seals the image in a memfd. Support for `manager.zig` and
//! `process.zig`; it holds no tests.

const std = @import("std");
const config = @import("collo_server_config");
const routes = @import("collo_server_routes");
const gateway = @import("collo_server_gateway");

const source =
    \\{"settings": {"network": {"allow": ["*"]}},
    \\ "workers": {"app": {"routes": {"/*": {"entry": "app.js"}}}}}
;

pub const CompiledImage = struct {
    parsed: config.Config,
    policies: routes.NetworkPolicies,

    pub fn init(target: *CompiledImage, allocator: std.mem.Allocator) !void {
        var diagnostic: config.Diagnostic = .{};
        target.parsed = try config.parse(allocator, source, "/srv/app/collo.json", &diagnostic);
        errdefer target.parsed.deinit();
        try target.policies.init(allocator, target.parsed.definitions, &diagnostic);
    }

    pub fn deinit(self: *CompiledImage, allocator: std.mem.Allocator) void {
        self.policies.deinit(allocator);
        self.parsed.deinit();
        self.* = undefined;
    }

    /// The image as the manager borrows it; valid until `deinit`.
    pub fn image(self: *const CompiledImage) gateway.PolicyImage {
        return .{ .fd = self.policies.imageFd(), .bytes = self.policies.image_bytes };
    }

    /// The policy the one route's tokens name.
    pub fn routePolicy(self: *const CompiledImage) routes.PolicyId {
        return self.policies.routePolicy(.{ .definition = 0, .route = 0 });
    }
};
