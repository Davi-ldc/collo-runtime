//! Sends the JavaScript exceptions the worker catches at its turn
//! boundaries, and the lines the worker writes about a tenant's code, such
//! as a returned Response it refused, to the tenant's log: the full text, an
//! exception's message and stack, goes to the sink its VM registered, and
//! the worker runtime publishes it to the log ring of the worker's shared
//! page. A tenant's exception is the tenant's event, so it never becomes an
//! operator line; only a failure to format one does. Runs in the worker on
//! the VM thread.
//!
//! The sink registry is process-wide. A worker process has one VM, while a
//! test process may hold several, so each registration is keyed by its VM
//! and only that VM's exceptions reach it.

const std = @import("std");
const bindings = @import("collo_bindings");

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
/// inactive, so that VM's exceptions reach no log.
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

/// Formats `exception`, which stays the caller's, and sends the text to the
/// sink registered for `vm` under `request_id`. When formatting fails, the
/// operator's log gets that failure under `context`, with no tenant text,
/// and the tenant's log gets nothing. Must run on `vm`'s thread.
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
}

/// Sends `message`, a line the worker wrote about the tenant's code under
/// `request_id`, such as the check a returned Response failed, to the sink
/// registered for `vm`, as an exception's text is. Must run on `vm`'s
/// thread.
pub fn logMessage(
    vm: *bindings.Vm,
    request_id: u64,
    message: []const u8,
) void {
    emitToSink(vm, request_id, message);
}
