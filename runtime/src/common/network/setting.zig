//! One `network` setting as the configuration declares it: the allow list
//! in configuration order and the two flags. The configuration parser
//! checks each setting it reads with `check` and reports the result at the
//! key it names, and the policy image builder (`table.zig`) refuses a
//! setting that fails it, so the server never compiles a grant the parser
//! would have refused.
//!
//! A setting fails when its list is longer than `entries_max`, when an
//! entry repeats an earlier one in canonical form, when it names a private
//! address without `allowPrivateNetworks`, or when a flag can admit nothing:
//! `allowPrivateNetworks` without an entry that can reach a private address
//! (`*` covers public addresses only, and a public address is never
//! private), or `allowHttp` with an empty list. An empty list with neither
//! flag is valid and admits nothing, which is how a route drops the grant it
//! would inherit.
//!
//! Pure functions; any thread may call them.

const std = @import("std");
const server_limits = @import("collo_limits").server;
const pattern = @import("pattern.zig");

const Pattern = pattern.Pattern;

/// Entries one allow list may hold.
pub const entries_max: usize = server_limits.network_allow_entries_max;

pub const Setting = struct {
    /// Canonical patterns from `pattern.parse`, in configuration order.
    allow: []const Pattern,
    allow_http: bool = false,
    allow_private_networks: bool = false,
};

/// Why `check` refused a setting.
pub const Problem = enum {
    too_many_entries,
    duplicate_entry,
    private_address_needs_flag,
    private_flag_unused,
    http_flag_unused,

    /// The sentence the configuration parser reports after the key path of
    /// the entry or flag at fault.
    pub fn describe(problem: Problem) []const u8 {
        return switch (problem) {
            .too_many_entries => std.fmt.comptimePrint("an allow list holds at most {d} entries; one *.suffix entry covers every name under a domain", .{entries_max}),
            .duplicate_entry => "the entry repeats an earlier entry of the same list",
            .private_address_needs_flag => "the entry is a private address; set allowPrivateNetworks to allow it",
            .private_flag_unused => "allowPrivateNetworks needs an entry that names a private host or address, since \"*\" covers public addresses only",
            .http_flag_unused => "allowHttp has no effect while the allow list is empty",
        };
    }
};

/// What `check` refused, and where.
pub const Violation = struct {
    problem: Problem,
    /// The entry at fault, for `duplicate_entry` and
    /// `private_address_needs_flag`; 0 for the others.
    index: usize = 0,
    /// The earlier entry a `duplicate_entry` repeats.
    earlier: usize = 0,
};

/// Null when `value` admits exactly what it says. Every pattern must be one
/// `pattern.parse` produced; the first violation in list order wins, and
/// the flags are checked after the entries.
pub fn check(value: Setting) ?Violation {
    if (value.allow.len > entries_max)
        return .{ .problem = .too_many_entries };

    var reaches_private = false;
    for (value.allow, 0..) |entry, index| {
        for (value.allow[0..index], 0..) |previous, earlier| {
            if (entry.eql(previous))
                return .{ .problem = .duplicate_entry, .index = index, .earlier = earlier };
        }
        if (entry.isPrivateAddress() and !value.allow_private_networks)
            return .{ .problem = .private_address_needs_flag, .index = index };
        if (entry.canReachPrivate())
            reaches_private = true;
    }
    if (value.allow_private_networks and !reaches_private)
        return .{ .problem = .private_flag_unused };
    if (value.allow_http and value.allow.len == 0)
        return .{ .problem = .http_flag_unused };
    return null;
}
