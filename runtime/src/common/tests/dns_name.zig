//! Normalization, validation and subdomain matching of DNS names in
//! `collo_dns_name`. Host header parsing, which applies the same validation
//! after splitting off the port, is tested in `http.zig`.

const std = @import("std");
const domain = @import("collo_dns_name");

test "domain normalization lowercases strict DNS names" {
    const normalized = try domain.normalizeAlloc(std.testing.allocator, " Demo.Example.TEST ");
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings("demo.example.test", normalized);
}

test "domain validation rejects unsafe labels" {
    try std.testing.expectError(error.InvalidDomain, domain.validateName(""));
    try std.testing.expectError(error.InvalidDomain, domain.validateName("demo..example.test"));
    try std.testing.expectError(error.InvalidDomain, domain.validateName("-demo.example.test"));
    try std.testing.expectError(error.InvalidDomain, domain.validateName("demo.example.test."));
}

test "subdomain helper requires a strict dotted suffix match" {
    try std.testing.expect(domain.isSubdomainOf("demo.example.test", "example.test"));
    try std.testing.expect(domain.isSubdomainOf("DEMO.EXAMPLE.TEST", "example.test"));
    try std.testing.expect(!domain.isSubdomainOf("example.test", "example.test"));
    try std.testing.expect(!domain.isSubdomainOf("badexample.test", "example.test"));
}
