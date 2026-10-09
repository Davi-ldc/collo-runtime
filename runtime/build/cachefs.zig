//! drvfs guard: the zig local cache on /mnt/<drive> (WSL 9P) stalls builds
//! for 20+ minutes — a whole class of "hung build" reports. Fail closed at
//! configure time instead, naming the fix. Escape hatch for the rare
//! deliberate case: COLLO_ALLOW_DRVFS_CACHE=1 downgrades to a warning.
const std = @import("std");

pub fn assertCacheNotOnDrvfs(b: *std.Build) void {
    const cache_path = b.cache_root.path orelse return; // null = cwd itself
    const cwd = std.process.getCwdAlloc(b.allocator) catch return;
    const resolved = std.fs.path.resolve(b.allocator, &.{ cwd, cache_path }) catch return;
    if (!looksLikeDrvfs(resolved)) return;

    if (b.graph.env_map.get("COLLO_ALLOW_DRVFS_CACHE")) |value| {
        if (std.mem.eql(u8, value, "1")) {
            std.debug.print(
                "warning: zig cache on drvfs ({s}); expect multi-minute stalls (COLLO_ALLOW_DRVFS_CACHE=1)\n",
                .{resolved},
            );
            return;
        }
    }
    std.process.fatal(
        "zig cache dir {s} is on drvfs (/mnt/<drive>, WSL 9P) — builds stall for 20min+.\n" ++
            "Fix: export ZIG_LOCAL_CACHE_DIR=/tmp/collo-zig-cache-build-long (ext4).\n" ++
            "Deliberate override: COLLO_ALLOW_DRVFS_CACHE=1.",
        .{resolved},
    );
}

/// WSL drvfs mounts live at /mnt/<single letter>/ by default. Path-prefix
/// detection covers the real fleet; custom mount points opt out via the env.
fn looksLikeDrvfs(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "/mnt/")) return false;
    const rest = path["/mnt/".len..];
    if (rest.len == 0) return false;
    if (!std.ascii.isAlphabetic(rest[0])) return false;
    return rest.len == 1 or rest[1] == '/';
}

test "looksLikeDrvfs" {
    try std.testing.expect(looksLikeDrvfs("/mnt/c/users/x/repo/.zig-cache"));
    try std.testing.expect(looksLikeDrvfs("/mnt/d"));
    try std.testing.expect(!looksLikeDrvfs("/tmp/collo-zig-cache-build-long"));
    try std.testing.expect(!looksLikeDrvfs("/mnt/wsl/something"));
    try std.testing.expect(!looksLikeDrvfs("/home/user/.cache"));
}
