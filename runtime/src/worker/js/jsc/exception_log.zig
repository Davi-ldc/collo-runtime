//! Logs the JavaScript exceptions the worker catches at its turn boundaries,
//! for two readers. The tenant gets the full formatted exception, message and
//! stack, through the sink its VM registered; the worker runtime publishes it
//! to the log ring of the worker's shared page. The operator's `std.log` line
//! carries only the text's length and a digest prefix, so tenant data in an
//! exception message stays out of the operator's log, unless the worker was
//! started with full exception logging. Runs in the worker on the VM thread.
//!
//! The sink registry and the logging switch are process-wide. A worker
//! process has one VM, while a test process may hold several, so each
//! registration is keyed by its VM and only that VM's exceptions reach it.

const std = @import("std");
const builtin = @import("builtin");
const bindings = @import("collo_bindings");

const digest_hex_len: usize = 16;
var log_full_exceptions = std.atomic.Value(bool).init(builtin.mode == .Debug);

/// Receives the full formatted exception of one request, borrowed for the
/// call.
pub const Sink = *const fn (ctx: ?*anyopaque, request_id: u64, message: []const u8) void;

/// A sink bound to the VM whose exceptions it receives. The registrant owns
/// the struct and keeps it at a fixed address from `setRegistration` until
/// `clearRegistrationIf`.
pub const Registration = struct {
    vm_identity: ?*const anyopaque,
    sink: Sink,
    ctx: ?*anyopaque,
};

/// Registry slots, one per registered VM. A slot's identity and registration
/// are separate atomics: an emitter matches the identity of its own VM before
/// it reads the registration, so it never dereferences another VM's. A
/// matched registration is alive when read because emission runs on that
/// VM's thread, the same thread that later clears the registration.
const max_slots = 8;
var slot_identities = [_]std.atomic.Value(?*const anyopaque){
    std.atomic.Value(?*const anyopaque).init(null),
} ** max_slots;
var slot_registrations = [_]std.atomic.Value(?*const Registration){
    std.atomic.Value(?*const Registration).init(null),
} ** max_slots;

/// Claims a free slot for `reg`, which must stay alive until
/// `clearRegistrationIf`. With every slot taken it warns and leaves the sink
/// inactive, so that VM's exceptions reach only `std.log`.
pub fn setRegistration(reg: *const Registration) void {
    for (&slot_identities, &slot_registrations) |*slot_identity, *slot_registration| {
        if (slot_identity.cmpxchgStrong(null, reg.vm_identity, .acq_rel, .acquire) == null) {
            slot_registration.store(reg, .release);
            return;
        }
    }
    std.log.warn("exception sink registry full; sink inactive for this runtime", .{});
}

/// Frees the slot holding `reg`, if any; another registration's slot is left
/// alone.
pub fn clearRegistrationIf(reg: *const Registration) void {
    for (&slot_identities, &slot_registrations) |*slot_identity, *slot_registration| {
        // The registration goes before the identity, so an emitter that
        // matched the identity reads either the live registration or null.
        if (slot_registration.cmpxchgStrong(reg, null, .acq_rel, .acquire) == null) {
            slot_identity.store(null, .release);
            return;
        }
    }
}

fn emitToSink(vm: *bindings.Vm, request_id: u64, message: []const u8) void {
    const identity = vm.rawIdentity();
    for (&slot_identities, &slot_registrations) |*slot_identity, *slot_registration| {
        if (slot_identity.load(.acquire) != identity)
            continue;
        const reg = slot_registration.load(.acquire) orelse continue;
        reg.sink(reg.ctx, request_id, message);
        return;
    }
}

pub const Config = struct {
    log_full_exceptions: bool = builtin.mode == .Debug,
};

/// Sets whether `std.log` gets full exception text. The switch is
/// process-wide, so the last call wins for every VM in the process.
pub fn configure(config: Config) void {
    log_full_exceptions.store(config.log_full_exceptions, .release);
}

/// Formats `exception`, which stays the caller's, sends the text to the sink
/// registered for `vm` and logs it under `context` for `request_id`. When
/// formatting fails, that failure is logged instead and neither reader gets
/// the exception. Must run on `vm`'s thread.
pub fn logException(
    vm: *bindings.Vm,
    request_id: u64,
    exception: *const bindings.Value,
    context: []const u8,
) void {
    var formatted = vm.exceptionFormat(exception) catch |err| {
        std.log.warn(
            "{s} request_id={d}; failed to format exception: {s}",
            .{ context, request_id, @errorName(err) },
        );
        return;
    };
    defer formatted.deinit();
    emitToSink(vm, request_id, formatted.slice());
    logFormatted(request_id, context, formatted.slice());
}

/// Logs already formatted exception text to `std.log`: in full when
/// configured, otherwise as its length and the first `digest_hex_len` hex
/// digits of its SHA-256, so repeats of one exception can still be matched.
pub fn logFormatted(request_id: u64, context: []const u8, formatted: []const u8) void {
    if (shouldLogFullException()) {
        std.log.warn("{s} request_id={d}: {s}", .{ context, request_id, formatted });
        return;
    }

    const digest = shortDigestHex(formatted);
    std.log.warn(
        "{s} request_id={d} message_len={d} digest={s}",
        .{ context, request_id, formatted.len, digest[0..] },
    );
}

fn shouldLogFullException() bool {
    return log_full_exceptions.load(.acquire);
}

fn shortDigestHex(bytes: []const u8) [digest_hex_len]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    var out: [digest_hex_len]u8 = undefined;
    @memcpy(&out, hex[0..digest_hex_len]);
    return out;
}
