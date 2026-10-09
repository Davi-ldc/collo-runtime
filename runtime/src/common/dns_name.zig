//! Validation and normalization of host names for routing, TLS SNI and Host
//! headers. A valid name is at most `max_name_bytes` of ASCII letters,
//! digits, hyphens and dots, has no trailing dot, and has no label that is
//! empty, longer than 63 bytes, or starts or ends with a hyphen, so a
//! bracketed IP literal, an underscore or a Unicode name fails. Normalizing
//! trims surrounding whitespace, lowercases ASCII and changes nothing else.
//! Pure functions, callable from any thread.

const std = @import("std");

/// The longest name in dotted text form without a trailing dot, which the
/// 255-octet wire limit of RFC 1035 §2.3.4 allows.
pub const max_name_bytes: usize = 253;

/// Fails with `error.InvalidDomain` unless `name` is a valid host name as
/// described above; it does not trim or lowercase.
pub fn validateName(name: []const u8) !void {
    if (name.len == 0 or name.len > max_name_bytes)
        return error.InvalidDomain;
    if (name[name.len - 1] == '.')
        return error.InvalidDomain;
    if (std.mem.indexOfAny(u8, name, "\x00\r\n\t ") != null)
        return error.InvalidDomain;

    var labels = std.mem.splitScalar(u8, name, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63)
            return error.InvalidDomain;
        if (label[0] == '-' or label[label.len - 1] == '-')
            return error.InvalidDomain;

        for (label) |byte| {
            if (!(std.ascii.isAlphanumeric(byte) or byte == '-'))
                return error.InvalidDomain;
        }
    }
}

/// The trimmed, lowercased name, allocated with `allocator`; the caller
/// frees it.
pub fn normalizeAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, name, &std.ascii.whitespace);
    try validateName(trimmed);

    const out = try allocator.alloc(u8, trimmed.len);
    for (trimmed, 0..) |byte, index|
        out[index] = std.ascii.toLower(byte);
    return out;
}

/// `normalizeAlloc` into `buffer`; the result borrows `buffer`.
pub fn normalizeStack(name: []const u8, buffer: *[max_name_bytes]u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, name, &std.ascii.whitespace);
    try validateName(trimmed);
    if (trimmed.len > buffer.len)
        return error.InvalidDomain;

    for (trimmed, 0..) |byte, index|
        buffer[index] = std.ascii.toLower(byte);
    return buffer[0..trimmed.len];
}

pub fn isValidName(name: []const u8) bool {
    validateName(name) catch return false;
    return true;
}

/// True when `domain` ends with a dot followed by `suffix`, compared without
/// case, so a name is never a subdomain of itself.
pub fn isSubdomainOf(domain: []const u8, suffix: []const u8) bool {
    if (domain.len <= suffix.len)
        return false;
    if (domain[domain.len - suffix.len - 1] != '.')
        return false;
    return std.ascii.endsWithIgnoreCase(domain, suffix);
}
