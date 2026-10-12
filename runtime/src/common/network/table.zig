//! The policy image: the grants and policies of one configuration, in the
//! byte layout the server writes once at boot and seals into a memfd, and
//! the table the gateway decodes from it at its hello and matches every
//! fetch against for its life (`grant.zig`). Both processes compile this
//! file, so the layout and the rules below are the whole contract between
//! them.
//!
//! Layout, in the native byte order of both targets, which is
//! little-endian (asserted below): a `Header`, then `grant_count`
//! `GrantRecord`s, `rule_count` `RuleRecord`s, `policy_count`
//! `PolicyRecord`s, `member_count` u16 grant indices, and `name_bytes`
//! bytes of names. Each grant owns the next `rule_count` rules after the
//! previous grant's, in canonical order (`Pattern.order`), and each name or
//! suffix rule owns the next `name_len` name bytes after the previous one's.
//! Each policy owns the next `member_count` members after the previous
//! policy's, in increasing grant order. The header's digest is the SHA-256
//! of every byte after it, so a byte changed anywhere past the magic fails
//! the image, and the gateway can fold the digest into its pool isolation
//! ids.
//!
//! A valid image holds what `Builder` writes and nothing else. Every count
//! is within its bound, and together the counts give the image's exact
//! length. Every grant has 1 to `rules_per_grant_max` rules, flags of 0 or
//! 1, and keeps the rules of `setting.zig`. Every rule has a known kind,
//! zeros in the fields its kind does not use, and either a canonical name
//! (`pattern.isCanonicalName`) or an address of a class an entry may name;
//! `*` names no port, and the rules of a grant strictly increase, so none
//! repeats. Policy 0 has no member, every other policy has 1 to
//! `members_per_policy_max`, and every member names a grant. `check` holds
//! an image to all of it, and `decode` builds views only over an image that
//! passed.
//!
//! The image comes only from the server, so a refused image is a server bug
//! and ends the gateway that read it. `Builder` runs on the server's boot
//! thread, and `check` and `decode` on the gateway's loop thread at its
//! hello.

const std = @import("std");
const builtin = @import("builtin");
const server_limits = @import("collo_limits").server;
const address = @import("address.zig");
const grant_mod = @import("grant.zig");
const pattern = @import("pattern.zig");
const setting_mod = @import("setting.zig");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Grant = grant_mod.Grant;
const Pattern = pattern.Pattern;
const Policy = grant_mod.Policy;
const Setting = setting_mod.Setting;

comptime {
    // Records are copied between the image and memory as they lie.
    assert(builtin.cpu.arch.endian() == .little);
}

/// One grant per `network` setting a configuration can declare: the global
/// one, one per worker definition and one per route.
pub const grants_max: usize = 1 + server_limits.worker_definitions_max + server_limits.routes_max;

/// Policy 0, one policy per route and one union per worker definition.
pub const policies_max: usize = 1 + server_limits.routes_max + server_limits.worker_definitions_max;

/// The entries of every setting of one configuration.
pub const rules_max: usize = server_limits.network_allow_entries_total_max;

/// The entries of one setting.
pub const rules_per_grant_max: usize = setting_mod.entries_max;

/// A union holds at most one grant per route of its worker definition.
pub const members_per_policy_max: usize = server_limits.routes_per_definition_max;

/// One member for each route's policy, and at most one more per route
/// across the unions, since every route belongs to one worker definition.
pub const members_max: usize = 2 * server_limits.routes_max;

/// Every rule a name of the longest length.
pub const name_bytes_max: usize = rules_max * pattern.name_bytes_max;

/// The largest image the gateway accepts from its hello.
pub const image_bytes_max: usize = @sizeOf(Header) +
    grants_max * @sizeOf(GrantRecord) +
    rules_max * @sizeOf(RuleRecord) +
    policies_max * @sizeOf(PolicyRecord) +
    members_max * @sizeOf(GrantId) +
    name_bytes_max;

pub const GrantId = u16;
pub const PolicyId = u16;

/// The policy with no grant, present in every image.
pub const deny_all_id: PolicyId = 0;

comptime {
    // A token carries its policy id in a u16, and a member is a u16 grant
    // index.
    assert(policies_max - 1 <= std.math.maxInt(PolicyId));
    assert(grants_max - 1 <= std.math.maxInt(GrantId));
    assert(rules_per_grant_max <= std.math.maxInt(u16));
    assert(members_per_policy_max <= std.math.maxInt(u16));
    assert(rules_per_grant_max <= rules_max);
    assert(members_per_policy_max <= members_max);
    // A rule holds its name's length in a byte.
    assert(pattern.name_bytes_max <= std.math.maxInt(u8));
    // The header holds every count in a u32, and the hello the length.
    assert(image_bytes_max <= std.math.maxInt(u32));
}

pub const magic = [4]u8{ 'C', 'N', 'P', '1' };

pub const Header = extern struct {
    magic: [4]u8,
    /// SHA-256 of every byte after this field.
    digest: [Sha256.digest_length]u8,
    grant_count: u32,
    rule_count: u32,
    policy_count: u32,
    member_count: u32,
    name_bytes: u32,
};

pub const GrantRecord = extern struct {
    rule_count: u16,
    allow_http: u8,
    allow_private_networks: u8,
};

pub const RuleRecord = extern struct {
    /// A `pattern.Kind`.
    kind: u8,
    /// The length of a name or suffix; 0 for the other kinds.
    name_len: u8,
    /// 0 for the default port of the scheme.
    port: u16,
    /// An IPv4 address in its first 4 bytes, or an IPv6 address; zero
    /// wherever the kind holds no address byte.
    address: [16]u8,
};

pub const PolicyRecord = extern struct {
    member_count: u16,
};

/// The digest covers the image from this offset to its end.
pub const digest_end: usize = @offsetOf(Header, "digest") + Sha256.digest_length;

comptime {
    assert(@sizeOf(Header) == 56);
    assert(@offsetOf(Header, "digest") == 4);
    assert(@offsetOf(Header, "grant_count") == digest_end);
    assert(@offsetOf(Header, "name_bytes") == 52);
    assert(@sizeOf(GrantRecord) == 4);
    assert(@offsetOf(GrantRecord, "allow_private_networks") == 3);
    assert(@sizeOf(RuleRecord) == 20);
    assert(@offsetOf(RuleRecord, "port") == 2);
    assert(@offsetOf(RuleRecord, "address") == 4);
    assert(@sizeOf(PolicyRecord) == 2);
}

/// Why `check` refused an image, named after the part at fault.
pub const Problem = enum {
    /// Shorter than a header.
    truncated,
    magic,
    /// The digest does not match the bytes after it.
    digest,
    grant_count,
    rule_count,
    /// Zero, since policy 0 is always present, or past `policies_max`.
    policy_count,
    member_count,
    name_bytes,
    /// The image is not exactly as long as its counts say.
    length,
    /// A grant flag other than 0 or 1.
    grant_flag,
    /// A grant with no rule or more than `rules_per_grant_max`.
    grant_rules,
    /// The grants' rule counts do not add up to `rule_count`.
    rule_total,
    rule_kind,
    /// A field the rule's kind does not use holds a nonzero byte.
    rule_unused,
    /// `*` with a port.
    rule_port,
    /// A name or suffix that is empty or not canonical.
    rule_name,
    /// An address of a class no entry may name.
    rule_address,
    /// A grant's rules out of canonical order, or repeated.
    rule_order,
    /// The rules' names do not fill the name bytes exactly.
    name_total,
    /// A private address in a grant without `allowPrivateNetworks`.
    private_address,
    /// `allowPrivateNetworks` in a grant with no rule that can reach a
    /// private address.
    private_unused,
    /// Policy 0 with a member.
    policy_zero,
    /// Another policy with no member or more than `members_per_policy_max`.
    policy_members,
    /// The policies' member counts do not add up to `member_count`.
    member_total,
    /// A policy's members out of increasing order, or repeated.
    member_order,
    /// A member past the last grant.
    member_grant,
};

/// Null when `image` keeps every rule of this file's header.
pub fn check(image: []const u8) ?Problem {
    if (image.len < @sizeOf(Header))
        return .truncated;
    const header = readHeader(image);
    if (!std.mem.eql(u8, &header.magic, &magic))
        return .magic;
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(image[digest_end..], &digest, .{});
    if (!std.mem.eql(u8, &digest, &header.digest))
        return .digest;

    if (header.grant_count > grants_max)
        return .grant_count;
    if (header.rule_count > rules_max)
        return .rule_count;
    if (header.policy_count == 0 or header.policy_count > policies_max)
        return .policy_count;
    if (header.member_count > members_max)
        return .member_count;
    if (header.name_bytes > name_bytes_max)
        return .name_bytes;
    const layout = Layout.init(header);
    if (image.len != layout.total)
        return .length;

    if (checkGrants(image, layout)) |problem|
        return problem;
    return checkPolicies(image, layout);
}

/// Writes the digest of an image whose other bytes are final.
pub fn seal(image: []u8) void {
    assert(image.len >= @sizeOf(Header));
    const digest = image[@offsetOf(Header, "digest")..][0..Sha256.digest_length];
    Sha256.hash(image[digest_end..], digest, .{});
}

pub fn readHeader(image: []const u8) Header {
    assert(image.len >= @sizeOf(Header));
    return std.mem.bytesToValue(Header, image[0..@sizeOf(Header)]);
}

/// Where each part of an image starts.
pub const Layout = struct {
    grant_count: usize,
    rule_count: usize,
    policy_count: usize,
    member_count: usize,
    name_bytes: usize,
    grants_offset: usize,
    rules_offset: usize,
    policies_offset: usize,
    members_offset: usize,
    names_offset: usize,
    /// The image's exact length.
    total: usize,

    /// The layout a header's counts give. Every count must be within its
    /// bound, which keeps every offset at or below `image_bytes_max`.
    pub fn init(header: Header) Layout {
        assert(header.grant_count <= grants_max);
        assert(header.rule_count <= rules_max);
        assert(header.policy_count <= policies_max);
        assert(header.member_count <= members_max);
        assert(header.name_bytes <= name_bytes_max);
        const grant_count: usize = header.grant_count;
        const rule_count: usize = header.rule_count;
        const policy_count: usize = header.policy_count;
        const member_count: usize = header.member_count;
        const name_bytes: usize = header.name_bytes;
        const grants_offset: usize = @sizeOf(Header);
        const rules_offset = grants_offset + grant_count * @sizeOf(GrantRecord);
        const policies_offset = rules_offset + rule_count * @sizeOf(RuleRecord);
        const members_offset = policies_offset + policy_count * @sizeOf(PolicyRecord);
        const names_offset = members_offset + member_count * @sizeOf(GrantId);
        return .{
            .grant_count = grant_count,
            .rule_count = rule_count,
            .policy_count = policy_count,
            .member_count = member_count,
            .name_bytes = name_bytes,
            .grants_offset = grants_offset,
            .rules_offset = rules_offset,
            .policies_offset = policies_offset,
            .members_offset = members_offset,
            .names_offset = names_offset,
            .total = names_offset + name_bytes,
        };
    }

    pub fn grantOffset(layout: Layout, index: usize) usize {
        assert(index < layout.grant_count);
        return layout.grants_offset + index * @sizeOf(GrantRecord);
    }

    pub fn ruleOffset(layout: Layout, index: usize) usize {
        assert(index < layout.rule_count);
        return layout.rules_offset + index * @sizeOf(RuleRecord);
    }

    pub fn policyOffset(layout: Layout, index: usize) usize {
        assert(index < layout.policy_count);
        return layout.policies_offset + index * @sizeOf(PolicyRecord);
    }

    pub fn memberOffset(layout: Layout, index: usize) usize {
        assert(index < layout.member_count);
        return layout.members_offset + index * @sizeOf(GrantId);
    }

    fn grantAt(layout: Layout, image: []const u8, index: usize) GrantRecord {
        return readRecord(GrantRecord, image, layout.grantOffset(index));
    }

    fn ruleAt(layout: Layout, image: []const u8, index: usize) RuleRecord {
        return readRecord(RuleRecord, image, layout.ruleOffset(index));
    }

    fn policyAt(layout: Layout, image: []const u8, index: usize) PolicyRecord {
        return readRecord(PolicyRecord, image, layout.policyOffset(index));
    }

    fn memberAt(layout: Layout, image: []const u8, index: usize) GrantId {
        return std.mem.readInt(GrantId, image[layout.memberOffset(index)..][0..@sizeOf(GrantId)], .little);
    }

    fn names(layout: Layout, image: []const u8) []const u8 {
        return image[layout.names_offset..][0..layout.name_bytes];
    }
};

/// The grants and policies of one image, decoded into memory the table
/// owns. The gateway keeps it from its hello to its exit; `Policy` values
/// point into it and live no longer.
pub const Table = struct {
    grants: []Grant,
    policies: []Policy,
    rules: []Pattern,
    members: []*const Grant,
    names: []u8,
    /// The image's digest, which tells this table apart from any other.
    digest: [Sha256.digest_length]u8,

    pub const DecodeError = Allocator.Error || error{InvalidPolicyImage};

    /// Checks `image` whole and decodes it into a table that holds copies
    /// of everything it needs, so `image` may be freed afterwards. Fails
    /// with `error.InvalidPolicyImage` for an image `check` refuses. The
    /// caller frees the table with `deinit` and the same `gpa`.
    pub fn decode(gpa: Allocator, image: []const u8) DecodeError!Table {
        if (check(image) != null)
            return error.InvalidPolicyImage;
        const header = readHeader(image);
        const layout = Layout.init(header);

        const names = try gpa.dupe(u8, layout.names(image));
        errdefer gpa.free(names);
        const rules = try gpa.alloc(Pattern, layout.rule_count);
        errdefer gpa.free(rules);
        const grants = try gpa.alloc(Grant, layout.grant_count);
        errdefer gpa.free(grants);
        const members = try gpa.alloc(*const Grant, layout.member_count);
        errdefer gpa.free(members);
        const policies = try gpa.alloc(Policy, layout.policy_count);

        var name_offset: usize = 0;
        for (rules, 0..) |*rule, index| {
            rule.* = switch (readRule(layout.ruleAt(image, index), names, &name_offset)) {
                .rule => |decoded| decoded,
                // `check` passed on these same bytes.
                .problem => unreachable,
            };
        }
        var rule_index: usize = 0;
        for (grants, 0..) |*grant, index| {
            const record = layout.grantAt(image, index);
            grant.* = grantView(record, rules[rule_index..][0..record.rule_count]);
            rule_index += record.rule_count;
        }
        var member_index: usize = 0;
        for (policies, 0..) |*entry, index| {
            const count: usize = layout.policyAt(image, index).member_count;
            const policy_members = members[member_index..][0..count];
            for (policy_members, member_index..) |*member, slot|
                member.* = &grants[layout.memberAt(image, slot)];
            entry.* = .{ .grants = policy_members };
            member_index += count;
        }
        assert(rule_index == rules.len);
        assert(member_index == members.len);

        return .{
            .grants = grants,
            .policies = policies,
            .rules = rules,
            .members = members,
            .names = names,
            .digest = header.digest,
        };
    }

    pub fn deinit(table: *Table, gpa: Allocator) void {
        gpa.free(table.policies);
        gpa.free(table.members);
        gpa.free(table.grants);
        gpa.free(table.rules);
        gpa.free(table.names);
        table.* = undefined;
    }

    /// The policy `id` names, or null for an id past the table. Only the
    /// server mints ids, so null means a server bug.
    pub fn policy(table: *const Table, id: PolicyId) ?Policy {
        if (id < table.policies.len)
            return table.policies[id];
        return null;
    }
};

/// Collects the grants and policies of one configuration and writes their
/// image. Equal grants and equal policies are stored once, so each id names
/// one distinct grant or policy. Policy 0 is always present and has no
/// member. The builder owns copies of everything it was given.
pub const Builder = struct {
    gpa: Allocator,
    grants: std.ArrayList(BuiltGrant),
    /// The members of policies 1 and up, policy `index + 1` at `index`.
    policies: std.ArrayList([]const GrantId),
    rule_count: usize,
    member_count: usize,
    name_bytes: usize,

    const BuiltGrant = struct {
        allow_http: bool,
        allow_private_networks: bool,
        /// In canonical order. Names point into `names`, which holds them
        /// in rule order, as the image does.
        rules: []Pattern,
        names: []u8,

        fn holds(built: *const BuiltGrant, value: Setting, sorted: []const Pattern) bool {
            if (built.allow_http != value.allow_http)
                return false;
            if (built.allow_private_networks != value.allow_private_networks)
                return false;
            if (built.rules.len != sorted.len)
                return false;
            for (built.rules, sorted) |left, right| {
                if (!left.eql(right))
                    return false;
            }
            return true;
        }
    };

    pub const Error = Allocator.Error || error{
        /// A setting the configuration parser would have refused, or one
        /// with an empty allow list, which compiles to policy 0 instead of
        /// a grant.
        InvalidSetting,
        /// A grant id the builder never returned, or more distinct members
        /// than `members_per_policy_max`.
        InvalidPolicy,
        /// Past `grants_max`, `rules_max`, `policies_max` or `members_max`.
        TableFull,
    };

    pub fn init(gpa: Allocator) Builder {
        return .{
            .gpa = gpa,
            .grants = .empty,
            .policies = .empty,
            .rule_count = 0,
            .member_count = 0,
            .name_bytes = 0,
        };
    }

    pub fn deinit(builder: *Builder) void {
        for (builder.grants.items) |grant| {
            builder.gpa.free(grant.rules);
            builder.gpa.free(grant.names);
        }
        builder.grants.deinit(builder.gpa);
        for (builder.policies.items) |members|
            builder.gpa.free(members);
        builder.policies.deinit(builder.gpa);
        builder.* = undefined;
    }

    /// Adds the grant of `value` and returns its id, or the id of an equal
    /// grant added before: the same entries in any order and the same
    /// flags. Every pattern must be one `pattern.parse` could produce, and
    /// the setting must pass `setting.check` with a nonempty list.
    pub fn addGrant(builder: *Builder, value: Setting) Error!GrantId {
        if (value.allow.len == 0)
            return error.InvalidSetting;
        for (value.allow) |entry| {
            if (!entry.isCanonical())
                return error.InvalidSetting;
        }
        if (setting_mod.check(value) != null)
            return error.InvalidSetting;
        assert(value.allow.len <= rules_per_grant_max);

        var sorted_buffer: [rules_per_grant_max]Pattern = undefined;
        const sorted = sorted_buffer[0..value.allow.len];
        @memcpy(sorted, value.allow);
        std.mem.sort(Pattern, sorted, {}, Pattern.lessThan);
        for (builder.grants.items, 0..) |*built, index| {
            if (built.holds(value, sorted))
                return @intCast(index);
        }
        if (builder.grants.items.len == grants_max)
            return error.TableFull;
        if (sorted.len > rules_max - builder.rule_count)
            return error.TableFull;

        const gpa = builder.gpa;
        try builder.grants.ensureUnusedCapacity(gpa, 1);
        const rules = try gpa.dupe(Pattern, sorted);
        errdefer gpa.free(rules);
        var name_bytes: usize = 0;
        for (rules) |rule|
            name_bytes += ruleName(rule).len;
        const names = try gpa.alloc(u8, name_bytes);

        var name_offset: usize = 0;
        for (rules) |*rule| {
            const name = ruleName(rule.*);
            const copy = names[name_offset..][0..name.len];
            @memcpy(copy, name);
            switch (rule.host) {
                .name => rule.host = .{ .name = copy },
                .suffix => rule.host = .{ .suffix = copy },
                .any, .ipv4, .ipv6 => {},
            }
            name_offset += name.len;
        }
        assert(name_offset == names.len);

        builder.grants.appendAssumeCapacity(.{
            .allow_http = value.allow_http,
            .allow_private_networks = value.allow_private_networks,
            .rules = rules,
            .names = names,
        });
        builder.rule_count += rules.len;
        builder.name_bytes += names.len;
        return @intCast(builder.grants.items.len - 1);
    }

    /// Adds the policy whose members are `grants`, in any order and with
    /// repeats, and returns its id, or the id of an equal policy added
    /// before. No grant at all is policy 0.
    pub fn addPolicy(builder: *Builder, grants: []const GrantId) Error!PolicyId {
        var seen = std.StaticBitSet(grants_max).initEmpty();
        for (grants) |id| {
            if (id >= builder.grants.items.len)
                return error.InvalidPolicy;
            seen.set(id);
        }
        const count = seen.count();
        if (count == 0)
            return deny_all_id;
        if (count > members_per_policy_max)
            return error.InvalidPolicy;

        var member_buffer: [members_per_policy_max]GrantId = undefined;
        var filled: usize = 0;
        var ids = seen.iterator(.{});
        while (ids.next()) |id| {
            member_buffer[filled] = @intCast(id);
            filled += 1;
        }
        assert(filled == count);
        const members = member_buffer[0..count];
        for (builder.policies.items, 1..) |existing, id| {
            if (std.mem.eql(GrantId, existing, members))
                return @intCast(id);
        }
        // Policy 0 takes one of the `policies_max` ids.
        if (builder.policies.items.len + 1 == policies_max)
            return error.TableFull;
        if (count > members_max - builder.member_count)
            return error.TableFull;

        const gpa = builder.gpa;
        try builder.policies.ensureUnusedCapacity(gpa, 1);
        const owned = try gpa.dupe(GrantId, members);
        builder.policies.appendAssumeCapacity(owned);
        builder.member_count += count;
        return @intCast(builder.policies.items.len);
    }

    /// The image of everything added so far, sealed, allocated with `gpa`;
    /// the caller frees it.
    pub fn encode(builder: *const Builder, gpa: Allocator) Allocator.Error![]u8 {
        const header: Header = .{
            .magic = magic,
            .digest = @splat(0),
            .grant_count = @intCast(builder.grants.items.len),
            .rule_count = @intCast(builder.rule_count),
            .policy_count = @intCast(builder.policies.items.len + 1),
            .member_count = @intCast(builder.member_count),
            .name_bytes = @intCast(builder.name_bytes),
        };
        const layout = Layout.init(header);
        const image = try gpa.alloc(u8, layout.total);
        writeRecord(image, 0, header);

        var rule_index: usize = 0;
        var name_offset: usize = 0;
        for (builder.grants.items, 0..) |grant, index| {
            writeRecord(image, layout.grantOffset(index), GrantRecord{
                .rule_count = @intCast(grant.rules.len),
                .allow_http = @intFromBool(grant.allow_http),
                .allow_private_networks = @intFromBool(grant.allow_private_networks),
            });
            for (grant.rules) |rule| {
                writeRecord(image, layout.ruleOffset(rule_index), ruleRecord(rule));
                rule_index += 1;
            }
            @memcpy(image[layout.names_offset + name_offset ..][0..grant.names.len], grant.names);
            name_offset += grant.names.len;
        }
        assert(rule_index == layout.rule_count);
        assert(name_offset == layout.name_bytes);

        writeRecord(image, layout.policyOffset(deny_all_id), PolicyRecord{ .member_count = 0 });
        var member_index: usize = 0;
        for (builder.policies.items, 1..) |members, id| {
            writeRecord(image, layout.policyOffset(id), PolicyRecord{ .member_count = @intCast(members.len) });
            for (members) |member| {
                const slot = image[layout.memberOffset(member_index)..][0..@sizeOf(GrantId)];
                std.mem.writeInt(GrantId, slot, member, .little);
                member_index += 1;
            }
        }
        assert(member_index == layout.member_count);

        seal(image);
        assert(check(image) == null);
        return image;
    }
};

const RuleRead = union(enum) {
    rule: Pattern,
    problem: Problem,
};

/// Reads one rule, taking a name's bytes from `names` at `name_offset` and
/// advancing it. A name in the result borrows `names`.
fn readRule(record: RuleRecord, names: []const u8, name_offset: *usize) RuleRead {
    const kind = std.enums.fromInt(pattern.Kind, record.kind) orelse return .{ .problem = .rule_kind };
    switch (kind) {
        .any => {
            if (record.name_len != 0 or !std.mem.allEqual(u8, &record.address, 0))
                return .{ .problem = .rule_unused };
            if (record.port != 0)
                return .{ .problem = .rule_port };
            return .{ .rule = .{ .host = .any, .port = 0 } };
        },
        .name, .suffix => {
            if (!std.mem.allEqual(u8, &record.address, 0))
                return .{ .problem = .rule_unused };
            if (record.name_len > names.len - name_offset.*)
                return .{ .problem = .name_total };
            const name = names[name_offset.*..][0..record.name_len];
            if (!pattern.isCanonicalName(name))
                return .{ .problem = .rule_name };
            name_offset.* += name.len;
            const host: pattern.Host = if (kind == .name) .{ .name = name } else .{ .suffix = name };
            return .{ .rule = .{ .host = host, .port = record.port } };
        },
        .ipv4 => {
            if (record.name_len != 0 or !std.mem.allEqual(u8, record.address[4..], 0))
                return .{ .problem = .rule_unused };
            const bytes = record.address[0..4].*;
            if (pattern.literalProblem(address.classifyIpv4(bytes)) != null)
                return .{ .problem = .rule_address };
            return .{ .rule = .{ .host = .{ .ipv4 = bytes }, .port = record.port } };
        },
        .ipv6 => {
            if (record.name_len != 0)
                return .{ .problem = .rule_unused };
            if (pattern.literalProblem(address.classifyIpv6(record.address)) != null)
                return .{ .problem = .rule_address };
            return .{ .rule = .{ .host = .{ .ipv6 = record.address }, .port = record.port } };
        },
    }
}

fn checkGrants(image: []const u8, layout: Layout) ?Problem {
    const names = layout.names(image);
    var rule_index: usize = 0;
    var name_offset: usize = 0;
    for (0..layout.grant_count) |grant_index| {
        const record = layout.grantAt(image, grant_index);
        if (record.allow_http > 1 or record.allow_private_networks > 1)
            return .grant_flag;
        if (record.rule_count == 0 or record.rule_count > rules_per_grant_max)
            return .grant_rules;
        if (record.rule_count > layout.rule_count - rule_index)
            return .rule_total;

        // The rules of `setting.check`, on the rules as they lie: the
        // canonical order refuses a repeat, and the flags must be usable.
        var previous: ?Pattern = null;
        var reaches_private = false;
        for (rule_index..rule_index + record.rule_count) |index| {
            const rule = switch (readRule(layout.ruleAt(image, index), names, &name_offset)) {
                .rule => |value| value,
                .problem => |problem| return problem,
            };
            if (previous) |earlier| {
                if (earlier.order(rule) != .lt)
                    return .rule_order;
            }
            if (rule.isPrivateAddress() and record.allow_private_networks == 0)
                return .private_address;
            if (rule.canReachPrivate())
                reaches_private = true;
            previous = rule;
        }
        if (record.allow_private_networks == 1 and !reaches_private)
            return .private_unused;
        rule_index += record.rule_count;
    }
    if (rule_index != layout.rule_count)
        return .rule_total;
    if (name_offset != layout.name_bytes)
        return .name_total;
    return null;
}

fn checkPolicies(image: []const u8, layout: Layout) ?Problem {
    var member_index: usize = 0;
    for (0..layout.policy_count) |policy_index| {
        const count: usize = layout.policyAt(image, policy_index).member_count;
        if (policy_index == deny_all_id) {
            if (count != 0)
                return .policy_zero;
        } else {
            if (count == 0 or count > members_per_policy_max)
                return .policy_members;
        }
        if (count > layout.member_count - member_index)
            return .member_total;

        var previous: ?GrantId = null;
        for (member_index..member_index + count) |index| {
            const member = layout.memberAt(image, index);
            if (member >= layout.grant_count)
                return .member_grant;
            if (previous) |earlier| {
                if (member <= earlier)
                    return .member_order;
            }
            previous = member;
        }
        member_index += count;
    }
    if (member_index != layout.member_count)
        return .member_total;
    return null;
}

/// The grant whose rules, in canonical order, are `rules`: `*` first when
/// present, then a run of each other kind in `pattern.Kind` order.
fn grantView(record: GrantRecord, rules: []const Pattern) Grant {
    var cursor: usize = 0;
    const any = rules.len > 0 and std.meta.activeTag(rules[0].host) == .any;
    if (any)
        cursor = 1;
    const names = takeKind(rules, &cursor, .name);
    const suffixes = takeKind(rules, &cursor, .suffix);
    const ipv4 = takeKind(rules, &cursor, .ipv4);
    const ipv6 = takeKind(rules, &cursor, .ipv6);
    assert(cursor == rules.len);
    return .{
        .allow_http = record.allow_http == 1,
        .allow_private_networks = record.allow_private_networks == 1,
        .any = any,
        .names = names,
        .suffixes = suffixes,
        .ipv4 = ipv4,
        .ipv6 = ipv6,
    };
}

fn takeKind(rules: []const Pattern, cursor: *usize, kind: pattern.Kind) []const Pattern {
    const start = cursor.*;
    while (cursor.* < rules.len and std.meta.activeTag(rules[cursor.*].host) == kind)
        cursor.* += 1;
    return rules[start..cursor.*];
}

fn ruleRecord(rule: Pattern) RuleRecord {
    var record: RuleRecord = .{
        .kind = @intFromEnum(std.meta.activeTag(rule.host)),
        .name_len = 0,
        .port = rule.port,
        .address = @splat(0),
    };
    switch (rule.host) {
        .any => {},
        .name, .suffix => |name| record.name_len = @intCast(name.len),
        .ipv4 => |bytes| @memcpy(record.address[0..4], &bytes),
        .ipv6 => |bytes| record.address = bytes,
    }
    return record;
}

fn ruleName(rule: Pattern) []const u8 {
    return switch (rule.host) {
        .name, .suffix => |name| name,
        .any, .ipv4, .ipv6 => "",
    };
}

fn readRecord(comptime Record: type, image: []const u8, offset: usize) Record {
    return std.mem.bytesToValue(Record, image[offset..][0..@sizeOf(Record)]);
}

fn writeRecord(image: []u8, offset: usize, record: anytype) void {
    const bytes = std.mem.asBytes(&record);
    @memcpy(image[offset..][0..bytes.len], bytes);
}
