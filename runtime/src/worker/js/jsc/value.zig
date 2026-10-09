//! Typed ownership for the JavaScript value handles the worker keeps across
//! turns, such as a route's handler or a timer's callback and arguments. Runs
//! in the worker on the VM thread.
//!
//! An owned wrapper holds one reference to a `bindings.Value` handle, whose
//! root keeps the JavaScript value alive until its last reference is
//! released, and releases that reference exactly once. A borrowed wrapper
//! holds a pointer that its owner keeps alive. The object and function types
//! tell the reader what a value holds; only the checked function
//! constructors verify it.

const std = @import("std");
const bindings = @import("collo_bindings");

/// A handle the caller keeps alive for as long as this wrapper is used.
pub const JsValueBorrowed = struct {
    value: *const bindings.Value,

    pub fn raw(self: JsValueBorrowed) *const bindings.Value {
        return self.value;
    }
};

/// One reference to a value handle, or nothing once taken or released.
pub const JsValueOwned = struct {
    value: ?bindings.Value = null,

    /// Takes a new reference to the handle `value` borrows; `vm` is unused.
    /// Fails when the handle is empty, its VM is gone or its reference count
    /// is at the maximum.
    pub fn init(vm: *bindings.Vm, value: JsValueBorrowed) !JsValueOwned {
        _ = vm;
        return .{ .value = try value.value.*.retain() };
    }

    /// Takes ownership of `value`'s reference.
    pub fn fromOwnedValue(value: bindings.Value) JsValueOwned {
        return .{ .value = value };
    }

    /// Releases the reference if the wrapper still holds one.
    pub fn deinit(self: *JsValueOwned) void {
        if (self.value) |*value|
            value.deinit();
        self.* = .{};
    }

    /// Moves the reference into the returned wrapper and leaves this one
    /// empty.
    pub fn take(self: *JsValueOwned) JsValueOwned {
        const value = self.value;
        self.value = null;
        return .{ .value = value };
    }

    /// Borrows the held value. This accessor, `ptr` and `ptrMut` panic on an
    /// empty wrapper, since only a caller bug reads one.
    pub fn borrowed(self: *const JsValueOwned) JsValueBorrowed {
        if (self.value) |*value|
            return .{ .value = value };
        @panic("invalid JsValueOwned");
    }

    pub fn ptr(self: *const JsValueOwned) *const bindings.Value {
        if (self.value) |*value|
            return value;
        @panic("invalid JsValueOwned");
    }

    pub fn ptrMut(self: *JsValueOwned) *bindings.Value {
        if (self.value) |*value|
            return value;
        @panic("invalid JsValueOwned");
    }

    pub fn isValid(self: *const JsValueOwned) bool {
        return self.value != null;
    }
};

pub const JsObjectBorrowed = struct {
    inner: JsValueBorrowed,
};

pub const JsObjectOwned = struct {
    inner: JsValueOwned,

    pub fn fromOwnedValue(value: bindings.Value) JsObjectOwned {
        return .{ .inner = JsValueOwned.fromOwnedValue(value) };
    }

    pub fn deinit(self: *JsObjectOwned) void {
        self.inner.deinit();
    }

    pub fn take(self: *JsObjectOwned) JsObjectOwned {
        return .{ .inner = self.inner.take() };
    }

    pub fn borrowed(self: *const JsObjectOwned) JsObjectBorrowed {
        return .{ .inner = self.inner.borrowed() };
    }
};

pub const JsFunctionBorrowed = struct {
    inner: JsValueBorrowed,
};

pub const JsFunctionOwned = struct {
    inner: JsValueOwned,

    /// Takes a new reference to `value` after checking that it is callable.
    /// Fails with `error.HandlerNotCallable` for a value that is not, or with
    /// the error of the check or of `JsValueOwned.init`.
    pub fn initChecked(vm: *bindings.Vm, value: JsValueBorrowed) !JsFunctionOwned {
        if (!try vm.isCallable(value.raw()))
            return error.HandlerNotCallable;
        return .{ .inner = try JsValueOwned.init(vm, value) };
    }

    /// Takes ownership of `value` on every path and keeps it only when it is
    /// callable. Fails with `error.HandlerNotCallable` for a value that is
    /// not, or with the error of the check, after releasing `value`.
    pub fn fromOwnedValueChecked(vm: *bindings.Vm, value: bindings.Value) !JsFunctionOwned {
        var owned = JsValueOwned.fromOwnedValue(value);
        errdefer owned.deinit();
        if (!try vm.isCallable(owned.ptr()))
            return error.HandlerNotCallable;
        return .{ .inner = owned.take() };
    }

    pub fn deinit(self: *JsFunctionOwned) void {
        self.inner.deinit();
    }

    pub fn take(self: *JsFunctionOwned) JsFunctionOwned {
        return .{ .inner = self.inner.take() };
    }

    pub fn borrowed(self: *const JsFunctionOwned) JsFunctionBorrowed {
        return .{ .inner = self.inner.borrowed() };
    }

    pub fn ptr(self: *const JsFunctionOwned) *const bindings.Value {
        return self.inner.ptr();
    }

    pub fn ptrMut(self: *JsFunctionOwned) *bindings.Value {
        return self.inner.ptrMut();
    }
};

pub fn borrowed(value: *const bindings.Value) JsValueBorrowed {
    return .{ .value = value };
}
