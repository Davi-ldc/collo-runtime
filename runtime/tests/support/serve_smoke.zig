//! The serve smoke: one request through the installed `collo serve`, as a
//! user runs it, and the last check of `zig build smoke`
//! (runtime/build/smoke.zig). It starts `<collo> serve <entry> --listen
//! 127.0.0.1:0` and waits for the listening line on the server's stderr. It
//! sends SIGHUP to the server's process group, which the server leads, as a
//! terminal's hangup does: the server reopens its analytics files, none
//! here, and must keep serving. Then it sends one h2 GET over TLS that
//! accepts the server's generated certificate, and compares the body with
//! the one the entry answers (runtime/tests/integration/fixtures/cli/hello.js).
//! Last it sends SIGINT to the group, as a terminal's Ctrl-C does, and
//! expects exit status 0, followed by EOF on the server's stderr. The zygote
//! and the gateway run in sessions of their own, so neither signal reaches
//! them and the server must stop them itself; they inherit its stderr, so
//! the EOF proves neither outlived it.
//!
//! The driver runs as its own process with two threads. The main thread
//! drives the server; a detached forwarder thread copies the server's stderr
//! to the driver's and finds the listening line in it. Every wait is
//! bounded, so a server that never listens, never answers or never exits
//! fails the smoke instead of hanging the build; the GET's waits are bounded
//! by the TLS shim's socket timeouts. A failed check kills the server with
//! SIGKILL and reaps it before the driver exits. The server inherits the
//! driver's environment, which carries its worker cgroup root.

const std = @import("std");
const collo_os = @import("collo_os");
const tls_shim = @import("collo_test_tls_shim");

const process = collo_os.process;
const Term = std.process.Child.Term;

/// What `collo serve` prints on stderr once it accepts connections, followed
/// by the address it listens on.
const listening_prefix = "collo: listening on https://";
/// Port 0 asks the kernel for an ephemeral port, so two smokes never
/// collide.
const listen_address = "127.0.0.1:0";
/// The host the listening line must name, since the TLS shim connects only
/// to 127.0.0.1.
const listen_host = "127.0.0.1";
const request_path = "/smoke";

/// From spawn to the listening line. The boot builds the route's artifacts
/// and spawns the zygote, which warms its VM, and a Debug engine does that
/// many times slower than a release one.
const listening_timeout_ms: u64 = 60_000;
/// From the stop signal to exit. Nothing is in flight by then, so this covers
/// the server's teardown, whose waits for each process it started are bounded
/// by `PROCESS_EXIT_WAIT_MS` in `common/limits/process.zig`.
const exit_timeout_ms: i32 = 15_000;
/// From SIGKILL to exit, which needs no cooperation from the server.
const kill_timeout_ms: i32 = 5_000;
/// From the server's exit to EOF on its stderr.
const stderr_close_timeout_ms: u64 = 5_000;
/// Room for the fixture's body, which echoes the request URL.
const body_bytes_max = 1024;
/// The longest stderr line scanned for the listening line; a longer line
/// cannot be it.
const line_bytes_max = 512;

const exit_success: u8 = 0;
const exit_failure: u8 = 1;
const exit_usage: u8 = 2;

const SmokeError = error{SmokeFailed};

pub fn main() u8 {
    // Process lifetime: everything the driver allocates lives until it exits.
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = std.process.argsAlloc(arena) catch |err| {
        report("cannot read the command line: {s}", .{@errorName(err)});
        return exit_failure;
    };
    if (args.len != 3) {
        report("usage: serve_smoke <collo> <entry.js>", .{});
        return exit_usage;
    }
    // Every failure was reported where it happened.
    run(arena, args[1], args[2]) catch |err| switch (err) {
        error.SmokeFailed => return exit_failure,
    };
    report("ok", .{});
    return exit_success;
}

fn run(arena: std.mem.Allocator, collo_path: []const u8, entry_path: []const u8) SmokeError!void {
    var server: Server = undefined;
    try server.start(arena, collo_path, entry_path);
    defer server.deinit();

    const forwarder = try StderrForwarder.start(server.takeStderr());
    forwarder.listening.timedWait(listening_timeout_ms * std.time.ns_per_ms) catch return failed(
        "no listening line on the server's stderr within {d} ms",
        .{listening_timeout_ms},
    );
    const address = forwarder.listeningAddress() orelse {
        const term = try server.waitExit(exit_timeout_ms) orelse
            return failed("the server closed its stderr before listening and still runs", .{});
        const end: TermFormat = .{ .term = term };
        return failed("the server exited before listening, with {f}", .{end});
    };
    const port = listeningPort(address) orelse return failed(
        "the server listens on {s}, not on {s} with an ephemeral port",
        .{ address, listen_host },
    );

    // A hangup the server did not take as a reopen would end it with the
    // default action, which the GET or the exit status below then reports.
    try server.signalGroup(std.posix.SIG.HUP);
    try expectHelloBody(address, port);

    try server.signalGroup(std.posix.SIG.INT);
    const term = try server.waitExit(exit_timeout_ms) orelse
        return failed("the server did not exit within {d} ms of SIGINT", .{exit_timeout_ms});
    switch (term) {
        .Exited => |status| if (status != exit_success)
            return failed("the server exited with status {d} after SIGINT to its process group", .{status}),
        .Signal, .Stopped, .Unknown => return failed(
            "the server ended with {f} after SIGINT to its process group",
            .{TermFormat{ .term = term }},
        ),
    }

    forwarder.closed.timedWait(stderr_close_timeout_ms * std.time.ns_per_ms) catch return failed(
        "the server exited, but its stderr stayed open for {d} ms: a process it started lives on",
        .{stderr_close_timeout_ms},
    );
    if (forwarder.read_error) |err|
        return failed("reading the server's stderr failed: {s}", .{@errorName(err)});
}

/// One GET of `request_path` to the server on `port`, sent with `address`
/// as its authority, whose body must be the fixture's answer.
fn expectHelloBody(address: []const u8, port: u16) SmokeError!void {
    // `address` comes from a line of at most `line_bytes_max` bytes.
    var authority_buffer: [line_bytes_max + 1]u8 = undefined;
    const authority = std.fmt.bufPrintZ(&authority_buffer, "{s}", .{address}) catch unreachable;
    const peer: tls_shim.H2Peer = .{
        .material = null,
        .authority = authority.ptr,
        .port = port,
        .trust = .any_certificate,
    };
    var body_buffer: [body_bytes_max]u8 = undefined;
    var body_len: u64 = 0;
    const status = tls_shim.collo_test_h2_get(
        &peer,
        request_path,
        &body_buffer,
        body_buffer.len,
        &body_len,
        null,
        0,
        null,
        null,
    );
    if (status != 0) {
        const reason = std.mem.span(tls_shim.collo_test_tls_last_error());
        return failed("the GET of {s} failed: {s}", .{ request_path, reason });
    }
    if (body_len > body_buffer.len) return failed(
        "the response body has {d} bytes, more than the {d} it may have",
        .{ body_len, body_buffer.len },
    );
    const body = body_buffer[0..@intCast(body_len)];

    // The fixture echoes the method and the URL, whose base is the
    // authority this request carried.
    var expected_buffer: [body_bytes_max]u8 = undefined;
    const expected = std.fmt.bufPrint(
        &expected_buffer,
        "hello from GET https://{s}{s}\n",
        .{ address, request_path },
    ) catch return failed("the expected body exceeds {d} bytes", .{body_bytes_max});
    if (!std.mem.eql(u8, body, expected)) {
        return failed("the response body is \"{f}\", expected \"{f}\"", .{
            std.zig.fmtString(body),
            std.zig.fmtString(expected),
        });
    }
}

/// The port of a listening address that must be `listen_host:<port>` with a
/// port the kernel chose.
fn listeningPort(address: []const u8) ?u16 {
    const host_prefix = listen_host ++ ":";
    if (!std.mem.startsWith(u8, address, host_prefix)) return null;
    const port = std.fmt.parseUnsigned(u16, address[host_prefix.len..], 10) catch return null;
    if (port == 0) return null;
    return port;
}

/// The `collo serve` process under test. `deinit` leaves no server running:
/// it kills and reaps one that has not been reaped.
const Server = struct {
    child: std.process.Child,
    /// The kill and the waits go through the pidfd, which keeps naming this
    /// process after it is reaped, when its pid may already be reused.
    pidfd: std.posix.fd_t,
    reaped: bool,

    fn start(
        self: *Server,
        arena: std.mem.Allocator,
        collo_path: []const u8,
        entry_path: []const u8,
    ) SmokeError!void {
        const argv = arena.dupe(
            []const u8,
            &.{ collo_path, "serve", entry_path, "--listen", listen_address },
        ) catch return failed("cannot allocate the server's command line", .{});
        self.child = std.process.Child.init(argv, arena);
        self.child.stdin_behavior = .Ignore;
        self.child.stdout_behavior = .Inherit;
        self.child.stderr_behavior = .Pipe;
        // A process group of its own, which `signalGroup` signals whole.
        self.child.pgid = 0;
        self.child.spawn() catch |err|
            return failed("cannot start {s}: {s}", .{ collo_path, @errorName(err) });
        // `spawn` returns once the fork succeeds; this waits for the exec.
        self.child.waitForSpawn() catch |err| {
            self.child.stderr.?.close();
            return failed("cannot start {s}: {s}", .{ collo_path, @errorName(err) });
        };
        self.reaped = false;
        self.pidfd = process.openPidFd(@intCast(self.child.id)) catch |err| {
            // The server is not reaped yet, so its pid still names it.
            std.posix.kill(self.child.id, std.posix.SIG.KILL) catch |kill_err|
                report("cannot kill the server: {s}", .{@errorName(kill_err)});
            if (self.child.wait()) |_| {} else |wait_err| {
                report("cannot reap the server: {s}", .{@errorName(wait_err)});
            }
            return failed("cannot open a pidfd for the server: {s}", .{@errorName(err)});
        };
    }

    fn deinit(self: *Server) void {
        if (!self.reaped) self.kill();
        std.posix.close(self.pidfd);
        self.* = undefined;
    }

    /// Hands the stderr pipe to its reader. The child keeps no reference to
    /// it, so reaping the server never closes the pipe under the forwarder.
    fn takeStderr(self: *Server) std.fs.File {
        const pipe = self.child.stderr.?;
        self.child.stderr = null;
        return pipe;
    }

    /// Signals every process in the server's group, as a terminal signals its
    /// foreground group. The server leads that group and is not reaped yet,
    /// so its pid still names the group.
    fn signalGroup(self: *Server, signal_number: u8) SmokeError!void {
        std.debug.assert(!self.reaped);
        std.posix.kill(-self.child.id, signal_number) catch |err| return failed(
            "cannot send signal {d} to the server's process group: {s}",
            .{ signal_number, @errorName(err) },
        );
    }

    /// How the server ended, once it exits within `timeout_ms`; null while
    /// it still runs.
    fn waitExit(self: *Server, timeout_ms: i32) SmokeError!?Term {
        std.debug.assert(!self.reaped);
        const exited = process.waitForPidFdExit(self.pidfd, timeout_ms) catch |err|
            return failed("cannot wait for the server: {s}", .{@errorName(err)});
        if (!exited) return null;
        return try self.reap();
    }

    fn reap(self: *Server) SmokeError!Term {
        const term = self.child.wait() catch |err|
            return failed("cannot reap the server: {s}", .{@errorName(err)});
        self.reaped = true;
        return term;
    }

    fn kill(self: *Server) void {
        process.pidFdSendSignal(self.pidfd, std.posix.SIG.KILL) catch |err| switch (err) {
            // It exited on its own and only waits to be reaped.
            error.ProcessNotFound => {},
            else => report("cannot kill the server: {s}", .{@errorName(err)}),
        };
        const exited = process.waitForPidFdExit(self.pidfd, kill_timeout_ms) catch |err| {
            report("cannot wait for the killed server: {s}", .{@errorName(err)});
            return;
        };
        if (!exited) {
            report("the server did not exit within {d} ms of SIGKILL", .{kill_timeout_ms});
            return;
        }
        // `reap` reports its own failure, and the smoke has failed already.
        _ = self.reap() catch return;
    }
};

/// Reads the server's stderr until EOF, copies it to the driver's stderr and
/// finds the listening line. The forwarder thread is detached and may still
/// read after `main` returns, when a process holding the pipe outlives the
/// server, so its state has process lifetime and is never freed.
const StderrForwarder = struct {
    pipe: std.fs.File,
    /// Set once the listening line was found, or once the pipe ended without
    /// it. `found` and the address are final once it is set.
    listening: std.Thread.ResetEvent = .{},
    /// Set once the pipe reached EOF or failed. `read_error` is final once
    /// it is set.
    closed: std.Thread.ResetEvent = .{},
    found: bool = false,
    address_buffer: [line_bytes_max]u8 = undefined,
    address_len: usize = 0,
    read_error: ?std.fs.File.ReadError = null,
    /// The line being assembled while the listening line is still missing.
    line_buffer: [line_bytes_max]u8 = undefined,
    line_len: usize = 0,
    /// The current line outgrew `line_buffer` and is skipped up to its end.
    line_overflowed: bool = false,

    /// Takes ownership of `pipe`, which the forwarder thread closes at EOF.
    fn start(pipe: std.fs.File) SmokeError!*StderrForwarder {
        const forwarder = std.heap.page_allocator.create(StderrForwarder) catch {
            pipe.close();
            return failed("cannot allocate the stderr forwarder", .{});
        };
        forwarder.* = .{ .pipe = pipe };
        const thread = std.Thread.spawn(.{}, forward, .{forwarder}) catch |err| {
            pipe.close();
            std.heap.page_allocator.destroy(forwarder);
            return failed("cannot start the stderr forwarder: {s}", .{@errorName(err)});
        };
        thread.detach();
        return forwarder;
    }

    /// The address of the listening line, or null when the pipe ended before
    /// one. Valid once `listening` is set.
    fn listeningAddress(self: *const StderrForwarder) ?[]const u8 {
        if (!self.found) return null;
        return self.address_buffer[0..self.address_len];
    }

    fn forward(self: *StderrForwarder) void {
        defer self.closed.set();
        // Wakes a main thread still waiting for the listening line when the
        // pipe ends first; once the line was found it changes nothing.
        defer self.listening.set();
        defer self.pipe.close();

        var forwarding = true;
        var chunk: [4096]u8 = undefined;
        // Ends at EOF, which comes once the server and every process
        // holding its stderr have exited.
        while (true) {
            const read_len = self.pipe.read(&chunk) catch |err| {
                self.read_error = err;
                return;
            };
            if (read_len == 0) return;
            const bytes = chunk[0..read_len];
            if (forwarding) {
                var no_buffer: [0]u8 = undefined;
                const stderr = std.debug.lockStderrWriter(&no_buffer);
                defer std.debug.unlockStderrWriter();
                stderr.writeAll(bytes) catch {
                    // The driver's stderr is gone and nothing can report it.
                    // The pipe is still drained, so the server never blocks
                    // on a full one.
                    forwarding = false;
                };
            }
            if (!self.found) self.scan(bytes);
        }
    }

    fn scan(self: *StderrForwarder, bytes: []const u8) void {
        for (bytes) |byte| {
            if (byte != '\n') {
                if (self.line_len < self.line_buffer.len) {
                    self.line_buffer[self.line_len] = byte;
                    self.line_len += 1;
                } else {
                    self.line_overflowed = true;
                }
                continue;
            }
            const line = self.line_buffer[0..self.line_len];
            if (!self.line_overflowed and self.publishIfListening(line)) return;
            self.line_len = 0;
            self.line_overflowed = false;
        }
    }

    fn publishIfListening(self: *StderrForwarder, line: []const u8) bool {
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (!std.mem.startsWith(u8, trimmed, listening_prefix)) return false;
        const address = trimmed[listening_prefix.len..];
        @memcpy(self.address_buffer[0..address.len], address);
        self.address_len = address.len;
        self.found = true;
        self.listening.set();
        return true;
    }
};

const TermFormat = struct {
    term: Term,

    pub fn format(self: TermFormat, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.term) {
            .Exited => |status| try writer.print("exit status {d}", .{status}),
            .Signal => |signal_number| try writer.print("signal {d}", .{signal_number}),
            .Stopped => |signal_number| try writer.print("a stop by signal {d}", .{signal_number}),
            .Unknown => |status| try writer.print("wait status {d}", .{status}),
        }
    }
};

fn report(comptime format: []const u8, args: anytype) void {
    std.debug.print("serve smoke: " ++ format ++ "\n", args);
}

fn failed(comptime format: []const u8, args: anytype) SmokeError {
    report(format, args);
    return error.SmokeFailed;
}
