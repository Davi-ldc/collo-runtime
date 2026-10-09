//! Owner-loop state types, generic over the engine's `Command`: the HTTP/2
//! and HTTP/1 pendings with their deadline policy, the watch context the
//! data driver hands back, the owner's message union, and the key and group
//! that coalesce HTTP/2 connects.
//!
//! A pending runs two clocks. The stall clock (`socket_timeout_ms`) measures
//! only time spent waiting on the origin and restarts on origin progress;
//! the total request deadline (`request_deadline_mono_ns`, 0 when the fetch
//! has none) caps the whole fetch. While the engine waits on its own
//! consumer instead of the origin, the stall clock is suspended and only the
//! total deadline applies. Every pending holds a reference to its task and
//! its response body, because it outlives the headers-first publication and
//! the gateway may retire the fetch once it observes `done`.

const std = @import("std");
const accounting = @import("collo_egress_accounting");
const bindings = @import("collo_bindings");
const core = @import("collo_egress_core");
const http2 = @import("collo_egress_http2");
const pool_mod = @import("collo_egress_pool");
const transport = @import("collo_egress_transport");
const origin_mod = @import("origin.zig");

const fetch_body = core.fetch_body;
const stream_pump = core.stream_pump;
const body_credit = core.body_credit;
const parseHttpsOrigin = origin_mod.parseHttpsOrigin;

pub fn Types(comptime Command: type) type {
    return struct {
        pub const Pending = struct {
            command: Command,
            stream: pool_mod.StreamHandle,
            /// The stall (idle) deadline: `socket_timeout_ms` from the last
            /// origin progress, bounded by the total request deadline. Every
            /// response head, body chunk and unpause restarts it, so a long
            /// transfer that keeps progressing keeps pushing it forward and
            /// only an origin silence of `socket_timeout_ms` fires
            /// FetchReadTimeout. `effectiveDeadlineMonoNs` suspends it,
            /// returning the total deadline, while the consumer is the
            /// bottleneck. Set with `Config.stallDeadlineFromNow`.
            deadline_mono_ns: u64,
            headers_published: bool = false,
            body: *fetch_body.Body,
            /// Sink for the body's encoded chunks: the engine forwards h2
            /// response bytes undecoded. Configured at response-head time.
            body_sink: stream_pump.H2EncodedSink = .{},
            /// Flow-control credit delivered to the consumer and not yet
            /// acked back. While nonzero the response is in the consumer's
            /// hands, so the read deadline stays paused: the gateway drains
            /// the body queue long before the worker releases its pool
            /// extents, and an unpaused deadline would fail slow workers with
            /// FetchReadTimeout.
            unacked_h2_credit: usize = 0,
            credit_source_id: u64,
            /// Transport cost of this attempt: the ciphertext deltas the pool
            /// charged to this stream's events. It is one of three meters;
            /// never mix it with `billed_bytes` (HTTP payload) or the codec's
            /// per-stream plaintext counter.
            cost_bytes: u64 = 0,
            /// Billed bytes of this attempt: request header block and upload
            /// payload sent, final head, trailers and DATA payload received.
            /// Seeded with the open's billed_sent, grown by events and
            /// reconciled with the terminal event's cumulative codec counter.
            /// Redirect hops move this into the task's cross-hop base before
            /// the pending dies; retried attempts do not, because the client
            /// did not ask for the retry.
            billed_bytes: accounting.Bytes = .{},
            /// The origin sent END_STREAM: the response is complete and
            /// nothing more will arrive from the origin. Any remaining wait
            /// is for the consumer's terminal ack, so the stall clock stops;
            /// otherwise a fully received response could fail with
            /// FetchReadTimeout while a slow consumer drains the last
            /// (zero-credit) frame.
            origin_finished: bool = false,
            end_stream_seen: bool = false,

            pub fn init(
                command: Command,
                stream: pool_mod.StreamHandle,
                deadline_mono_ns: u64,
                credit_source_id: u64,
            ) Pending {
                const body = command.task.response_body;
                body.retain();
                // The pending outlives the headers-first publication; hold
                // the task so cancel probes stay valid after the gateway
                // observes `done` and retires the fetch.
                command.task.retain();
                return .{
                    .command = command,
                    .stream = stream,
                    .deadline_mono_ns = deadline_mono_ns,
                    .body = body,
                    .credit_source_id = credit_source_id,
                    .billed_bytes = .{ .sent = stream.billed_sent },
                };
            }

            pub fn deinit(self: *Pending, allocator: std.mem.Allocator) void {
                self.body.releaseAfterQueuedResourcesReleased(allocator);
                self.command.task.release();
                self.* = undefined;
            }

            pub fn addCostBytes(self: *Pending, bytes: u64) void {
                self.cost_bytes = self.cost_bytes +| bytes;
            }

            /// Reconcile with the codec's cumulative per-stream billed
            /// counter carried by `.end`/`.failure`. Element-wise max: both
            /// sides grow monotonically over the same quantities, but only
            /// the codec sees window-driven upload writes after open.
            pub fn mergeCumulativeBilled(self: *Pending, cumulative: anytype) void {
                self.billed_bytes.sent = @max(self.billed_bytes.sent, cumulative.sent);
                self.billed_bytes.received = @max(self.billed_bytes.received, cumulative.received);
            }

            pub fn effectiveDeadlineMonoNs(self: *const Pending) u64 {
                if (self.stallClockSuspended()) {
                    if (self.command.config.request_deadline_mono_ns != 0)
                        return self.command.config.request_deadline_mono_ns;
                    return std.math.maxInt(u64);
                }
                return self.deadline_mono_ns;
            }

            /// The stall clock measures only time spent waiting on the origin.
            /// It is suspended while the engine waits on its own consumer
            /// instead: while the consumer holds delivered body bytes
            /// (backpressure), or once the origin has sent END_STREAM and the
            /// only remaining wait is the consumer's terminal ack. The total
            /// request deadline still applies in both cases.
            pub fn stallClockSuspended(self: *const Pending) bool {
                return self.origin_finished or self.pausedByBodyBackpressure();
            }

            pub fn expiredErrorAt(self: *const Pending, now_mono_ns: u64) anyerror {
                if (self.command.config.requestDeadlineExpiredAt(now_mono_ns))
                    return error.FetchRequestDeadlineExceeded;
                return error.FetchReadTimeout;
            }

            pub fn pausedByBodyBackpressure(self: *const Pending) bool {
                if (!self.headers_published)
                    return false;
                return self.body.queuedDecodedBytes() != 0 or self.unacked_h2_credit != 0;
            }
        };

        pub const Watch = struct {
            pending: ?*Pending,
            /// HTTP/2 pool entry (null for HTTP/1 watches).
            entry: ?*pool_mod.Entry,
            /// HTTP/1 owner-loop pending (null for HTTP/2 watches).
            h1: ?*H1Pending = null,
            /// Effective deadline of the watched h2 or h1 pending, cached at
            /// watch-list build time so the single-pass builder evaluates
            /// each pending's deadline exactly once.
            deadline_mono_ns: u64 = std.math.maxInt(u64),
        };

        pub const Message = union(enum) {
            request: Command,
            connected: Connected,
            h1_connected: H1Connected,
            /// h1 body-credit release: the consumer freed decoded capacity
            /// for the continuation with this resume source id.
            h1_resume: u64,
            body_credit: body_credit.H2Data,
            body_cancel: bindings.FetchBodyIdentity,
        };

        /// Connector-thread outcome for an owner-dispatched HTTP/1 dial.
        /// Unlike `Connected`, this targets one pending, matched by task
        /// identity, because h1 connections are never shared.
        pub const H1Connected = struct {
            command: Command,
            outcome: H1ConnectOutcome,
        };

        pub const H1ConnectOutcome = union(enum) {
            wire: transport.HttpConnection,
            failure: anyerror,
        };

        /// An HTTP/1 fetch executing on the owner loop. The exchange and body
        /// state machines live on the heap, stable across list moves; the
        /// pending records how the owner is waiting on them. It follows the
        /// same two-clock model as `Pending`: an io park carries a stall
        /// deadline renewed at every park, a credit park suspends the stall
        /// clock and keeps only the total request deadline, and a connector
        /// wait arms no owner deadline because the connector's own timeouts
        /// bound it.
        pub const H1Pending = struct {
            command: Command,
            body_pipe: *fetch_body.Body,
            source_id: u64,
            headers_published: bool = false,
            phase: Phase,
            park: Park,

            pub const Phase = union(enum) {
                exchange: *transport.Http1Exchange,
                body: *transport.Http1BodyContinuation,
            };

            pub const Park = union(enum) {
                /// Step it in this iteration's drive pass.
                runnable,
                /// A connector thread owns the wait; its own connect and
                /// handshake timeouts bound it, so the owner arms no deadline,
                /// as for HTTP/2 connect groups.
                awaiting_connect,
                /// Parked on socket readiness.
                io: Io,
                /// Consumer backpressure: woken by an `.h1_resume` credit.
                credit,
                /// The connector queue was full at dial dispatch. The pending
                /// parks on a short retry tick, a deadline-only watch source
                /// like `.credit`, because there is no fd to poll and no wake
                /// for a drained queue. Expiry re-runs the dispatch instead of
                /// failing, unless the total request deadline is what fired.
                /// Staying runnable with a self-wake would make no progress
                /// while the queue stays full and re-run the owner's whole
                /// dirty pass in a busy loop, endless for a fetch without a
                /// request deadline (`request_deadline_mono_ns == 0`, which
                /// fetches under the boot permit have).
                dial_retry: DialRetry,

                pub const DialRetry = struct {
                    /// `dialRetryParkDeadline` at park time: one retry tick
                    /// from now, capped by the total request deadline.
                    deadline_mono_ns: u64,
                };

                pub const Io = struct {
                    fd: std.posix.fd_t,
                    interest: transport.IoInterest,
                    /// Stage error if the stall deadline fires first.
                    timeout_err: anyerror,
                    /// stallDeadlineFromNow at park time (capped by the total
                    /// request deadline).
                    deadline_mono_ns: u64,
                    /// Redirect-drain parks: expiry abandons connection reuse
                    /// instead of failing the fetch.
                    abandon_reuse_on_expire: bool = false,
                };
            };

            pub fn init(command: Command, exchange: *transport.Http1Exchange, source_id: u64) H1Pending {
                const body = command.task.response_body;
                body.retain();
                // The pending outlives the headers-first publication; hold
                // the task so cancel probes stay valid after the gateway
                // observes `done` and retires the fetch.
                command.task.retain();
                return .{
                    .command = command,
                    .body_pipe = body,
                    .source_id = source_id,
                    .phase = .{ .exchange = exchange },
                    .park = .runnable,
                };
            }

            /// Drops the pending's references. The owner must already have
            /// settled the phase resources (exchange or continuation).
            pub fn deinit(self: *H1Pending, allocator: std.mem.Allocator) void {
                self.body_pipe.releaseAfterQueuedResourcesReleased(allocator);
                self.command.task.release();
                self.* = undefined;
            }

            /// How long a queue-full dial parks before retrying the connector
            /// dispatch. Short enough to be negligible against a real dial
            /// (blocking DNS, TCP and TLS, tens of ms at best) and the
            /// queue-full episode it waits out; long enough that retrying
            /// costs about 100 cheap passes per second instead of a self-wake
            /// loop at full CPU.
            pub const dial_retry_tick_ns: u64 = 10 * std.time.ns_per_ms;

            pub fn effectiveDeadlineMonoNs(self: *const H1Pending) u64 {
                return switch (self.park) {
                    .io => |io| io.deadline_mono_ns,
                    .credit => requestDeadlineOrUnbounded(self.command.config.request_deadline_mono_ns),
                    .dial_retry => |retry| retry.deadline_mono_ns,
                    .awaiting_connect, .runnable => std.math.maxInt(u64),
                };
            }

            /// Deadline for a queue-full dial-retry park: one retry tick
            /// from now, capped by the total request deadline so the total
            /// clock still fires on time. The tick decides only how soon the
            /// dispatch is retried, never when the fetch fails.
            pub fn dialRetryParkDeadline(self: *const H1Pending, now_mono_ns: u64) u64 {
                return @min(
                    now_mono_ns +| dial_retry_tick_ns,
                    requestDeadlineOrUnbounded(self.command.config.request_deadline_mono_ns),
                );
            }

            pub fn expiredErrorAt(self: *const H1Pending, now_mono_ns: u64) anyerror {
                if (self.command.config.requestDeadlineExpiredAt(now_mono_ns))
                    return error.FetchRequestDeadlineExceeded;
                return switch (self.park) {
                    .io => |io| io.timeout_err,
                    else => error.FetchReadTimeout,
                };
            }

            fn requestDeadlineOrUnbounded(request_deadline_mono_ns: u64) u64 {
                if (request_deadline_mono_ns != 0)
                    return request_deadline_mono_ns;
                return std.math.maxInt(u64);
            }
        };

        pub const Connected = struct {
            command: Command,
            outcome: ConnectOutcome,
        };

        pub const ConnectOutcome = union(enum) {
            h2: transport.HttpConnection,
            /// ALPN negotiated http/1.1: the engine hands this already paid
            /// handshake to the shared HTTP/1 pool instead of reconnecting.
            h1: transport.HttpConnection,
            failure: anyerror,
        };

        /// A command coalesced onto an in-flight connect, stamped with its
        /// join time so a leader timeout can grant late joiners their own
        /// connect budget instead of failing them early.
        pub const ConnectWaiter = struct {
            command: Command,
            joined_mono_ns: u64,
        };

        pub const ConnectGroup = struct {
            key: ConnectKey,
            /// The one command handed to the connector queue when this group
            /// was created (the leader). While the group lives, from
            /// enqueueH2ConnectOrWait until startConnectedH2Command removes
            /// it, a connector may be executing this command and
            /// dereferencing its task at any moment, so owner-exit settlement
            /// (failAllH2Connecting) must never publish it; the connector's
            /// own completion delivery settles it instead.
            dispatched: Command,
            commands: std.array_list.Aligned(ConnectWaiter, null) = .empty,

            pub fn deinit(self: *ConnectGroup, allocator: std.mem.Allocator) void {
                self.commands.deinit(allocator);
                self.key.deinit(allocator);
                self.* = undefined;
            }
        };

        pub const ConnectKey = struct {
            authority_host_lower: []u8,
            port: u16,
            insecure_tls: bool,
            allow_private_networks: bool,
            h2_limits: http2.Limits,
            max_outgoing_buffer_bytes: usize,
            tls_ciphertext_buffer_bytes: usize,
            pool_security_cell_id: transport.PoolIsolationId,
            pool_policy_id: transport.PoolIsolationId,

            pub fn init(allocator: std.mem.Allocator, command: Command) !ConnectKey {
                const origin = parseHttpsOrigin(command.task.url) orelse return error.InvalidFetchUrl;
                const host = try allocator.dupe(u8, origin.host);
                errdefer allocator.free(host);
                _ = std.ascii.lowerString(host, host);
                const h2_limits = try command.config.http2Limits().normalized();
                return .{
                    .authority_host_lower = host,
                    .port = origin.port,
                    .insecure_tls = command.config.insecure_tls,
                    .allow_private_networks = command.config.allow_private_networks,
                    .h2_limits = h2_limits,
                    .max_outgoing_buffer_bytes = command.config.http2_max_outgoing_buffer_bytes,
                    .tls_ciphertext_buffer_bytes = command.config.tls_ciphertext_buffer_bytes,
                    .pool_security_cell_id = command.config.pool_security_cell_id,
                    .pool_policy_id = command.config.pool_policy_id,
                };
            }

            pub fn deinit(self: *ConnectKey, allocator: std.mem.Allocator) void {
                allocator.free(self.authority_host_lower);
                self.* = undefined;
            }

            pub fn matchesCommand(self: ConnectKey, command: Command) bool {
                const origin = parseHttpsOrigin(command.task.url) orelse return false;
                const h2_limits = command.config.http2Limits().normalized() catch return false;
                return self.port == origin.port and
                    self.insecure_tls == command.config.insecure_tls and
                    self.allow_private_networks == command.config.allow_private_networks and
                    limitsEqual(self.h2_limits, h2_limits) and
                    self.max_outgoing_buffer_bytes == command.config.http2_max_outgoing_buffer_bytes and
                    self.tls_ciphertext_buffer_bytes == command.config.tls_ciphertext_buffer_bytes and
                    std.mem.eql(u8, &self.pool_security_cell_id, &command.config.pool_security_cell_id) and
                    std.mem.eql(u8, &self.pool_policy_id, &command.config.pool_policy_id) and
                    std.ascii.eqlIgnoreCase(self.authority_host_lower, origin.host);
            }
        };

        pub fn limitsEqual(a: http2.Limits, b: http2.Limits) bool {
            return a.max_active_streams == b.max_active_streams and
                a.stream_receive_window == b.stream_receive_window and
                a.connection_receive_window == b.connection_receive_window and
                a.receive_window_update_threshold == b.receive_window_update_threshold and
                a.max_pending_body_credit_per_stream == b.max_pending_body_credit_per_stream and
                a.max_pending_body_credit_per_connection == b.max_pending_body_credit_per_connection;
        }
    };
}
