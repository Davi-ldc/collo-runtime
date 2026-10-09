//! HTTP/1 routing state of the owner loop: the origin-hint table that sends
//! https origins known to speak only http/1.1 straight to HTTP/1, the
//! resume-source id counter for h1 body credits, and the adapter that turns
//! a body-ready event into the engine's wake. The hint table holds at most
//! `max_http1_origin_hints` entries and evicts the oldest when full; an
//! evicted origin only goes through the HTTP/2 connect path once more,
//! where ALPN learns it again.

const std = @import("std");
const transport = @import("collo_egress_transport");
const origin_mod = @import("origin.zig");

const isHttpsUrl = origin_mod.isHttpsUrl;
const parseHttpsOrigin = origin_mod.parseHttpsOrigin;

const max_http1_origin_hints: usize = 128;

pub fn Methods(
    comptime Engine: type,
    comptime Command: type,
) type {
    return struct {
        pub fn shouldUseHttp2OwnerLocked(self: *Engine, command: Command) bool {
            if (!command.config.enable_http2 or !isHttpsUrl(command.task.url))
                return false;
            return !knowsOriginLocked(self, command);
        }

        /// Owner-thread routing decision; holds `Engine.mutex` only for the
        /// origin-hint lookup.
        pub fn shouldUseHttp2Owner(self: *Engine, command: Command) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return shouldUseHttp2OwnerLocked(self, command);
        }

        pub fn rememberOrigin(self: *Engine, command: Command) void {
            const origin = parseHttpsOrigin(command.task.url) orelse return;
            const owned_host = self.allocator.dupe(u8, origin.host) catch |err| {
                std.log.debug("failed to remember HTTP/1 egress origin: {s}", .{@errorName(err)});
                return;
            };
            _ = std.ascii.lowerString(owned_host, owned_host);

            self.mutex.lock();
            defer self.mutex.unlock();
            if (knowsOriginPartsLocked(
                self,
                origin.host,
                origin.port,
                command.config.insecure_tls,
                command.config.allow_private_networks,
                command.config.pool_security_cell_id,
                command.config.pool_policy_id,
            )) {
                self.allocator.free(owned_host);
                return;
            }
            if (self.http1_origins.items.len >= max_http1_origin_hints) {
                var oldest = self.http1_origins.orderedRemove(0);
                oldest.deinit(self.allocator);
            }
            self.http1_origins.append(self.allocator, .{
                .authority_host_lower = owned_host,
                .port = origin.port,
                .insecure_tls = command.config.insecure_tls,
                .allow_private_networks = command.config.allow_private_networks,
                .pool_security_cell_id = command.config.pool_security_cell_id,
                .pool_policy_id = command.config.pool_policy_id,
            }) catch |err| {
                self.allocator.free(owned_host);
                std.log.debug("failed to store HTTP/1 egress origin: {s}", .{@errorName(err)});
            };
        }

        pub fn nextResumeSourceId(self: *Engine) u64 {
            self.mutex.lock();
            defer self.mutex.unlock();
            const id = self.next_http1_resume_source_id;
            self.next_http1_resume_source_id +%= 1;
            if (self.next_http1_resume_source_id == 0)
                self.next_http1_resume_source_id = 1;
            return id;
        }

        fn knowsOriginLocked(self: *const Engine, command: Command) bool {
            const origin = parseHttpsOrigin(command.task.url) orelse return false;
            return knowsOriginPartsLocked(
                self,
                origin.host,
                origin.port,
                command.config.insecure_tls,
                command.config.allow_private_networks,
                command.config.pool_security_cell_id,
                command.config.pool_policy_id,
            );
        }

        fn knowsOriginPartsLocked(
            self: *const Engine,
            host: []const u8,
            port: u16,
            insecure_tls: bool,
            allow_private_networks: bool,
            pool_security_cell_id: transport.PoolIsolationId,
            pool_policy_id: transport.PoolIsolationId,
        ) bool {
            for (self.http1_origins.items) |hint| {
                if (hint.port == port and
                    hint.insecure_tls == insecure_tls and
                    hint.allow_private_networks == allow_private_networks and
                    std.mem.eql(u8, &hint.pool_security_cell_id, &pool_security_cell_id) and
                    std.mem.eql(u8, &hint.pool_policy_id, &pool_policy_id) and
                    std.ascii.eqlIgnoreCase(hint.authority_host_lower, host))
                    return true;
            }
            return false;
        }

        pub fn wakeBodyGeneric(ctx: ?*anyopaque, event: transport.BodyReadyEvent) void {
            const engine: *Engine = @ptrCast(@alignCast(ctx orelse return));
            switch (event) {
                .generic => engine.wake_fn.?(engine.wake_ctx, .generic),
                .token => |ready| engine.wake_fn.?(engine.wake_ctx, .{ .task_ready = .{
                    .task = @ptrCast(@alignCast(ready.ptr)),
                    .generation = ready.generation,
                } }),
            }
        }
    };
}
