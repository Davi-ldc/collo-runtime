//! HTTP/1 on the owner thread: each fetch drives its hop's exchange
//! (`transport.Http1Exchange`) and then its body continuation, parking on
//! its wire, on its own dial, or on its consumer between steps.
//!
//! A step consumes only what the wire already holds and reports what it
//! needs next, the same grain as an HTTP/2 entry's events, so one fast body
//! cannot hold the owner thread and no fairness budget is needed. A fetch
//! waiting on its wire is watched like an HTTP/2 entry, as a wire source
//! with a stall deadline renewed at every park; a fetch parked on its
//! consumer keeps only the total request deadline, and its wake is the
//! `.h1_resume` credit the gateway returns; a fetch waiting on its dial is
//! watched through the dial. Fetches are heap objects, so watch contexts and
//! dial waiters can point at them while the list moves.
//!
//! A fetch holds its hop, whose task reference keeps its response queue
//! alive, and a credit source (`credit_sources.zig`) until it ends. The
//! exchange leases idle connections from the owner's HTTP/1 pool itself and
//! asks for a dial only on a miss; every wire HTTP/1 code no longer needs
//! goes back through the pool's release hook to the data driver.
//!
//! Thread: the engine's owner thread alone.

const std = @import("std");
const core = @import("collo_egress_core");
const transport = @import("../transport/root.zig");
const task_model = @import("../task.zig");
const owner_mod = @import("owner.zig");
const root = @import("root.zig");
const result = @import("result.zig");
const dial = @import("dial.zig");
const h2 = @import("h2.zig");
const credit_sources = @import("credit_sources.zig");

const Hop = owner_mod.Hop;
const IoInterest = transport.IoInterest;
const Owner = owner_mod.Owner;
const ResponseQueue = core.ResponseQueue;
const Task = task_model.Task;
const Wire = transport.Wire;
const monotonicNowNs = transport.config.monotonicNowNs;

pub const Fetch = struct {
    hop: Hop,
    /// The task's queue, which the hop's task reference keeps alive.
    queue: *ResponseQueue,
    /// The id the body's resume credits name.
    source_id: u64,
    phase: Phase,
    park: Park = .running,
    headers_published: bool = false,
    /// A connection handed over before the exchange asked for one: the
    /// http/1.1 wire of the shared dial whose first waiter this fetch was,
    /// given at its exchange's first `.connect`.
    offered_wire: ?*Wire = null,

    const Phase = union(enum) {
        exchange: *transport.Http1Exchange,
        body: *transport.Http1BodyContinuation,
    };

    const Park = union(enum) {
        /// Being driven; holds no watch.
        running,
        dialing: *dial.Dial,
        io: Io,
        /// Consumer backpressure, woken by an `.h1_resume` credit.
        credit,
    };

    const Io = struct {
        interest: IoInterest,
        /// The error a stall deadline reports when it fires before the total
        /// request deadline.
        timeout_err: anyerror,
        deadline_mono_ns: u64,
        /// Redirect-drain parks: expiry gives up connection reuse instead of
        /// failing the fetch.
        abandon_reuse_on_expire: bool,
    };

    fn wire(self: *const Fetch) ?*Wire {
        return switch (self.phase) {
            .exchange => |exchange| exchange.connectionWire(),
            .body => |continuation| continuation.wire,
        };
    }

    fn expiredErrorAt(self: *const Fetch, now_mono_ns: u64) anyerror {
        if (self.hop.config().requestDeadlineExpiredAt(now_mono_ns))
            return error.FetchRequestDeadlineExceeded;
        return switch (self.park) {
            .io => |io| io.timeout_err,
            .running, .dialing, .credit => error.FetchReadTimeout,
        };
    }
};

/// Starts `hop` as an HTTP/1 fetch and drives it until it parks. `wire`, if
/// given, is a fresh http/1.1 connection to its origin for its first
/// `.connect`. Takes `hop` and `wire`.
pub fn start(owner: *Owner, hop: Hop, wire: ?*Wire) void {
    var owned = hop;
    owner.h1_fetches.ensureUnusedCapacity(owner.allocator, 1) catch |err| {
        if (wire) |unused| owner.releaseWire(unused);
        owner.failHop(&owned, err);
        return;
    };
    const fetch = owner.allocator.create(Fetch) catch |err| {
        if (wire) |unused| owner.releaseWire(unused);
        owner.failHop(&owned, err);
        return;
    };
    const source_id = owner.engine.acquireSource(.{ .h1 = fetch }, 0) catch |err| {
        owner.allocator.destroy(fetch);
        if (wire) |unused| owner.releaseWire(unused);
        owner.failHop(&owned, err);
        return;
    };
    fetch.* = .{
        .hop = owned,
        .queue = owned.task().response_body,
        .source_id = source_id,
        .phase = undefined,
        .offered_wire = wire,
    };
    const exchange = newExchange(owner, fetch) catch |err| {
        destroyUnsettled(owner, fetch, err);
        return;
    };
    fetch.phase = .{ .exchange = exchange };
    owner.h1_fetches.appendAssumeCapacity(fetch);
    drive(owner, fetch);
}

fn newExchange(owner: *Owner, fetch: *Fetch) !*transport.Http1Exchange {
    const task = fetch.hop.task();
    return transport.Http1Exchange.init(
        owner.allocator,
        &owner.http1_pool,
        &fetch.hop.plan,
        task.body,
        fetch.hop.config().*,
        .{
            .redirect_mode = transport.RedirectMode.fromFlags(task.flags),
            .max_redirects = fetch.hop.config().max_redirects,
        },
        task.redirect_count,
        fetch.source_id,
        fetch.queue,
        owner.engine,
        wakeBody,
        .{ .token = .{ .ptr = task, .generation = fetch.hop.readyToken().generation } },
    );
}

/// Fails a fetch that never joined the list and frees it.
fn destroyUnsettled(owner: *Owner, fetch: *Fetch, err: anyerror) void {
    if (fetch.offered_wire) |unused|
        owner.releaseWire(unused);
    owner.engine.retireSource(fetch.source_id);
    var hop = fetch.hop;
    owner.allocator.destroy(fetch);
    owner.failHop(&hop, err);
}

/// Steps the fetch until it parks or ends: on its start, and whenever its
/// wire is ready, its dial delivered, its consumer freed capacity or a
/// redirect-drain park gave up reuse.
pub fn drive(owner: *Owner, fetch: *Fetch) void {
    advance(owner, fetch, null);
}

/// `drive`, with the data driver's failure of the fetch's wire, if any,
/// handed to the exchange first: a pooled wire that dies under the request
/// head replays the request on a fresh dial when the exchange allows it
/// (`Exchange.failWire`).
fn advance(owner: *Owner, fetch: *Fetch, wire_failure: ?anyerror) void {
    fetch.park = .running;
    var pending_failure = wire_failure;
    while (true) {
        switch (fetch.phase) {
            .exchange => |exchange| {
                const next = if (pending_failure) |failure| exchange.failWire(failure) else exchange.drive();
                pending_failure = null;
                const need = next catch |err| {
                    end(owner, fetch, .{ .failed = err });
                    return;
                };
                switch (need) {
                    .io => |io| {
                        if (exchange.connectionWire() == null) {
                            end(owner, fetch, .{ .failed = error.FetchWriteFailed });
                            return;
                        }
                        parkIo(fetch, io.interest, io.timeout_err, io.on_expire == .abandon_reuse);
                        return;
                    },
                    .connect => {
                        if (fetch.offered_wire) |offered| {
                            fetch.offered_wire = null;
                            exchange.adoptConnection(offered);
                            continue;
                        }
                        const own_dial = dial.startPrivate(owner, fetch) catch |err| {
                            end(owner, fetch, .{ .failed = err });
                            return;
                        };
                        fetch.park = .{ .dialing = own_dial };
                        return;
                    },
                    .publish_head => |head| {
                        publishHead(owner, fetch, head) catch |err| {
                            end(owner, fetch, .{ .failed = err });
                            return;
                        };
                        fetch.headers_published = true;
                        exchange.markPublished();
                    },
                    .redirect => |redirect| {
                        if (!followRedirect(owner, fetch, redirect))
                            return;
                    },
                    .body => |continuation| {
                        // The continuation owns the wire now.
                        exchange.deinit();
                        fetch.phase = .{ .body = continuation };
                    },
                    .done => {
                        // The head was published and the exchange settled the
                        // body inline without waking anyone.
                        exchange.deinit();
                        owner.wake(.{ .task_ready = fetch.hop.readyToken() });
                        destroy(owner, fetch);
                        return;
                    },
                }
            },
            .body => |continuation| {
                if (pending_failure) |failure| {
                    end(owner, fetch, .{ .failed = failure });
                    return;
                }
                const step = continuation.step() catch |err| {
                    end(owner, fetch, .{ .failed = err });
                    return;
                };
                switch (step) {
                    .done => {
                        continuation.finish();
                        destroy(owner, fetch);
                        return;
                    },
                    .paused => {
                        fetch.park = .credit;
                        return;
                    },
                    .wait => |interest| {
                        parkIo(fetch, interest, error.FetchReadTimeout, false);
                        return;
                    },
                }
            },
        }
    }
}

/// Parks on the wire with a fresh stall window: every park gets
/// `socket_timeout_ms`, capped by the total request deadline, so a transfer
/// that keeps progressing keeps renewing it and only origin silence fires.
fn parkIo(fetch: *Fetch, interest: IoInterest, timeout_err: anyerror, abandon_reuse_on_expire: bool) void {
    const now_ns = monotonicNowNs() catch std.math.maxInt(u64);
    fetch.park = .{ .io = .{
        .interest = interest,
        .timeout_err = timeout_err,
        .deadline_mono_ns = fetch.hop.config().stallDeadlineFromNow(now_ns),
        .abandon_reuse_on_expire = abandon_reuse_on_expire,
    } };
}

fn publishHead(owner: *Owner, fetch: *Fetch, head: *const transport.StreamedResponseHead) !void {
    const task = fetch.hop.task();
    const allocator = task.resultAllocator();
    const status_text = try allocator.dupe(u8, head.status_text);
    const url = try allocator.dupe(u8, head.url);
    const headers = try task.copyResponseHeaders(head.headers);
    result.publishResult(task, .{ .success = .{
        .status = head.status,
        .status_text = status_text,
        .url = url,
        .headers = headers,
        .redirected = head.redirected,
    } }, owner.engine.wake_ctx, owner.engine.wake_fn.?);
}

/// One hop ended in a redirect: the task takes the target, and the next hop
/// runs on a fresh exchange of this fetch, or moves to HTTP/2 when its
/// origin speaks it. Returns true when the fetch goes on here.
fn followRedirect(owner: *Owner, fetch: *Fetch, redirect: transport.RedirectTarget) bool {
    const task = fetch.hop.task();
    const replace_failed: ?anyerror = blk: {
        task.replaceRequest(redirect.url, redirect.method, redirect.body, redirect.headers) catch |err|
            break :blk err;
        break :blk null;
    };
    owner.allocator.free(redirect.url);
    owner.allocator.free(redirect.method);
    transport.freeHeaders(owner.allocator, redirect.headers);
    if (replace_failed) |err| {
        end(owner, fetch, .{ .failed = err });
        return false;
    }
    task.redirect_count += 1;

    const plan = transport.prepareRequest(owner.allocator, task.url, task.method, task.headers, fetch.hop.config().*) catch |err| {
        end(owner, fetch, .{ .failed = err });
        return false;
    };
    // The finished exchange borrows the old plan, so it goes first.
    fetch.phase.exchange.deinit();
    fetch.hop.plan.deinit();
    fetch.hop.plan = plan;
    if (owner.usesHttp2(&fetch.hop)) {
        h2.start(owner, removeKeepingHop(owner, fetch));
        return false;
    }
    const next_exchange = newExchange(owner, fetch) catch |err| {
        removeAndFail(owner, fetch, err);
        return false;
    };
    fetch.phase = .{ .exchange = next_exchange };
    return true;
}

/// The fetch's watch deadline passed. A redirect-drain park only gives up
/// connection reuse, since the drain exists only to keep the connection
/// reusable; anything else fails with the park's stage error, or the
/// request-deadline error when the total clock ran out.
pub fn expired(owner: *Owner, fetch: *Fetch) void {
    const now_ns = monotonicNowNs() catch std.math.maxInt(u64);
    switch (fetch.park) {
        .io => |io| {
            if (io.abandon_reuse_on_expire and !fetch.hop.config().requestDeadlineExpiredAt(now_ns)) {
                switch (fetch.phase) {
                    .exchange => |exchange| exchange.abandonRedirectDrain(),
                    .body => {},
                }
                drive(owner, fetch);
                return;
            }
            end(owner, fetch, .{ .failed = fetch.expiredErrorAt(now_ns) });
        },
        .credit => end(owner, fetch, .{ .failed = fetch.expiredErrorAt(now_ns) }),
        // The dial watches its own deadlines.
        .running, .dialing => {},
    }
}

/// The data driver failed a receive or send on the fetch's wire. The
/// exchange decides whether the request replays; a body ends.
pub fn failed(owner: *Owner, fetch: *Fetch, err: anyerror) void {
    advance(owner, fetch, err);
}

/// The consumer freed capacity for `fetch`'s body (`credit_sources.zig`).
/// Only a body parked on credit reacts: any other means the release raced
/// ahead of a pause that never happened, and every later pause comes from an
/// append that attaches its own credit, so dropping it loses no wake.
pub fn applyResume(owner: *Owner, fetch: *Fetch, credit: credit_sources.Credit) void {
    if (!credit.resumed)
        return;
    if (fetch.park == .credit)
        drive(owner, fetch);
}

/// Hands `fetch`, waiting on its dial, the dial's connection. The dial
/// already let go of the fetch.
pub fn adoptDialedWire(owner: *Owner, fetch: *Fetch, wire: *Wire) void {
    std.debug.assert(fetch.park == .dialing);
    fetch.offered_wire = wire;
    drive(owner, fetch);
}

/// Ends `fetch`, waiting on its dial, with the dial's failure. The dial
/// already let go of the fetch.
pub fn dialFailed(owner: *Owner, fetch: *Fetch, err: anyerror) void {
    std.debug.assert(fetch.park == .dialing);
    fetch.park = .running;
    end(owner, fetch, .{ .failed = err });
}

/// Applies a cancel message. Returns false when no HTTP/1 fetch belongs to
/// `task`.
pub fn cancelTask(owner: *Owner, task: *Task) bool {
    for (owner.h1_fetches.items) |fetch| {
        if (fetch.hop.task() != task)
            continue;
        switch (fetch.park) {
            .dialing => |own_dial| {
                fetch.park = .running;
                dial.leave(owner, own_dial, fetch);
            },
            .running, .io, .credit => {},
        }
        end(owner, fetch, .canceled);
        return true;
    }
    return false;
}

const Ending = union(enum) {
    failed: anyerror,
    canceled,
};

/// Settles and frees the fetch. Before publication a failure fails the task
/// and a cancel completes it canceled; after it the queue fails and the
/// task is woken. A body continuation does both itself.
fn end(owner: *Owner, fetch: *Fetch, ending: Ending) void {
    const message = switch (ending) {
        .failed => |err| @errorName(err),
        .canceled => @errorName(error.FetchAborted),
    };
    switch (fetch.phase) {
        .exchange => |exchange| {
            exchange.deinit();
            if (fetch.headers_published) {
                _ = fetch.queue.fail(owner.allocator, message);
                owner.wake(.{ .task_ready = fetch.hop.readyToken() });
            } else switch (ending) {
                .failed => |err| result.publishFailure(fetch.hop.task(), err, owner.engine.wake_ctx, owner.engine.wake_fn.?),
                .canceled => result.completeCanceled(fetch.hop.task(), owner.engine.wake_ctx, owner.engine.wake_fn.?),
            }
        },
        .body => |continuation| continuation.failAndDeinit(message),
    }
    destroy(owner, fetch);
}

/// Takes a fetch whose phase was already released out of the list, keeping
/// its hop for the caller.
fn removeKeepingHop(owner: *Owner, fetch: *Fetch) Hop {
    unlist(owner, fetch);
    if (fetch.offered_wire) |unused|
        owner.releaseWire(unused);
    owner.engine.retireSource(fetch.source_id);
    const hop = fetch.hop;
    owner.allocator.destroy(fetch);
    return hop;
}

/// Fails a listed fetch whose phase was already released.
fn removeAndFail(owner: *Owner, fetch: *Fetch, err: anyerror) void {
    var hop = removeKeepingHop(owner, fetch);
    owner.failHop(&hop, err);
}

/// Frees a settled fetch whose phase was already released.
fn destroy(owner: *Owner, fetch: *Fetch) void {
    unlist(owner, fetch);
    if (fetch.offered_wire) |unused|
        owner.releaseWire(unused);
    owner.engine.retireSource(fetch.source_id);
    fetch.hop.deinit();
    owner.allocator.destroy(fetch);
}

fn unlist(owner: *Owner, fetch: *Fetch) void {
    for (owner.h1_fetches.items, 0..) |candidate, index| {
        if (candidate == fetch) {
            _ = owner.h1_fetches.orderedRemove(index);
            break;
        }
    }
    owner.watch_dirty = true;
}

pub fn appendWatches(owner: *Owner) void {
    for (owner.h1_fetches.items) |fetch| {
        switch (fetch.park) {
            .io => |io| {
                const wire = fetch.wire() orelse continue;
                owner.appendWatch(.{ .h1 = fetch }, .{
                    .context = undefined,
                    .io = .{ .wire = wire },
                    .deadline_mono_ns = io.deadline_mono_ns,
                    .want_read = io.interest == .read,
                    .want_write = io.interest == .write,
                });
            },
            // A consumer that holds the body cannot outlive the fetch's own
            // budget.
            .credit => {
                const deadline = fetch.hop.config().requestDeadlineOrUnbounded();
                if (deadline == std.math.maxInt(u64))
                    continue;
                owner.appendWatch(.{ .h1 = fetch }, .{
                    .context = undefined,
                    .deadline_mono_ns = deadline,
                });
            },
            .running, .dialing => {},
        }
    }
}

/// Settles every HTTP/1 fetch with `err`; a fetch waiting on its dial leaves
/// it first.
pub fn settleAll(owner: *Owner, err: anyerror) void {
    while (owner.h1_fetches.items.len != 0) {
        const fetch = owner.h1_fetches.items[owner.h1_fetches.items.len - 1];
        switch (fetch.park) {
            .dialing => |own_dial| {
                fetch.park = .running;
                dial.leave(owner, own_dial, fetch);
            },
            .running, .io, .credit => {},
        }
        end(owner, fetch, .{ .failed = err });
    }
}

/// Turns a body-ready event of an HTTP/1 body into the engine's wake.
fn wakeBody(context: ?*anyopaque, event: transport.BodyReadyEvent) void {
    const engine: *root.Engine = @ptrCast(@alignCast(context.?));
    switch (event) {
        .generic => engine.wake(.generic),
        .token => |ready| engine.wake(.{ .task_ready = .{
            .task = @ptrCast(@alignCast(ready.ptr)),
            .generation = ready.generation,
        } }),
    }
}
