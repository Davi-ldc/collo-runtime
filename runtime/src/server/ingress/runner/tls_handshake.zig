//! The TLS handshake of an ingress connection, on the lane thread that owns
//! the connection slot: drive the handshake, export the traffic keys and hand
//! the socket to kernel TLS, after which the connection speaks HTTP/2.
//!
//! An error a client can cause here closes its connection: each is sorted
//! with the handshake's table (`classifyConnectionError` with
//! `.tls_handshake` in `server/ingress/fault.zig`), and only the lane's own
//! faults leave this file. A close here sends no GOAWAY, since HTTP/2 has not
//! started.

const ktls = @import("collo_ktls");
const fault = @import("../fault.zig");
const connection_flow = @import("connection_flow.zig");
const connection_slot = @import("connection_slot.zig");
const event_sources = @import("event_sources.zig");
const work_queues = @import("work_queues.zig");

/// Advances the handshake of `conn`, a slot in `.tls_handshake`. Returns true
/// when the connection moved on, to HTTP/2 or to a close, and false while it
/// waits for its socket. A failure the client can cause asks the lane to
/// close the connection (`connection_flow.closeRuntimeConnection`). Fails
/// only with a lane fault: `error.MissingTlsConnection` for a handshake slot
/// that has no TLS connection, and the faults of re-arming the socket's poll.
pub fn drive(comptime Worker: type, worker: *Worker, conn: *connection_slot.Slot) fault.LaneFault!bool {
    const tls_conn = &(conn.tls_connection orelse return error.MissingTlsConnection);
    const step = tls_conn.step() catch |err| return closeForHandshakeError(Worker, worker, conn, err);
    switch (step) {
        .want_read => {
            conn.wait_events = event_sources.read_events;
            try connection_flow.Methods(Worker).updateConnectionInterest(worker, conn);
            return false;
        },
        .want_write => {
            conn.wait_events = event_sources.write_events;
            try connection_flow.Methods(Worker).updateConnectionInterest(worker, conn);
            return false;
        },
        .done => {},
    }

    var initial = tls_conn.exportKtlsInitialState() catch |err|
        return closeForHandshakeError(Worker, worker, conn, err);
    defer initial.rekey_state.zero();
    // A failure can leave the socket half configured, with the TLS ULP
    // attached and not both directions keyed, so nothing reads it again: the
    // connection closes.
    ktls.enableKernelRxTx(conn.fd, initial.crypto_info) catch |err|
        return closeForHandshakeError(Worker, worker, conn, err);
    conn.ktls_rekey_state = initial.rekey_state;
    tls_conn.deinit();
    conn.tls_connection = null;
    conn.state = .http2_connection;
    conn.wait_events = event_sources.read_events;
    work_queues.Methods(Worker).enqueueConnection(worker, conn.key.slot);
    return true;
}

/// Asks the lane to close the connection for a failed handshake step, key
/// export or kernel TLS handoff, or returns the error when it is the lane's
/// own. A handshake that failed midway leaves no TLS state to resume, so
/// even an error its table row kept would end the connection.
fn closeForHandshakeError(
    comptime Worker: type,
    worker: *Worker,
    conn: *connection_slot.Slot,
    err: (fault.LaneFault || fault.TlsHandshakeError),
) fault.LaneFault!bool {
    connection_flow.Methods(Worker).closeRuntimeConnection(worker, conn, switch (try fault.classifyConnectionError(.{ .tls_handshake = err })) {
        .close => |close| close,
        .keep => .{ .reason = .tls_handshake_failed, .goaway = null },
    });
    return true;
}
