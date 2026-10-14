//! The `node:fs` binding (`bindings/host_functions/node/fs.cpp`) in a VM of the test process,
//! against a temporary directory named by absolute paths: reads and writes that keep every byte,
//! for an empty file and one over 64 KiB; a UTF-8 read that keeps a leading BOM and replaces
//! invalid bytes; EISDIR and ENOTDIR from the kernel and a promise form's rejection; the codes of
//! argument errors; ENOTEMPTY with both paths of a rename; `exists` answering false where Node's
//! existsSync does; an error's `path` as the caller passed it; listings in the byte order Node
//! uses; and a relative path resolved against the process's working directory.
//!
//! `enableNodeFsForWorker` opens node:fs for the whole process and nothing closes it, so the
//! closed state, where every operation fails with EPERM, cannot be observed in this process. What
//! confines node:fs in a worker, its sandbox, and the answers inside it (EROFS on the read-only
//! root, EXDEV out of `/tmp`, `/var/task` as the working directory) are covered by
//! `zygote-integration` (`runtime/tests/integration/zygote.zig`). Lane: `bindings-test`.

const std = @import("std");
const support = @import("bindings_support");

const allocator = std.testing.allocator;

/// A temporary directory and its absolute path.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    path_buffer: [std.fs.max_path_bytes]u8 = undefined,
    path_len: usize = 0,

    fn init(target: *Fixture) !void {
        target.* = .{ .tmp = std.testing.tmpDir(.{}) };
        errdefer target.tmp.cleanup();
        target.path_len = (try target.tmp.dir.realpath(".", &target.path_buffer)).len;
    }

    fn deinit(self: *Fixture) void {
        self.tmp.cleanup();
    }

    fn path(self: *const Fixture) []const u8 {
        return self.path_buffer[0..self.path_len];
    }

    fn write(self: *Fixture, sub_path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(sub_path)) |parent|
            try self.tmp.dir.makePath(parent);
        try self.tmp.dir.writeFile(.{ .sub_path = sub_path, .data = data });
    }
};

/// Evaluates `body` as a module of a VM with node:fs enabled, after `fs` is imported and `dir`
/// holds the fixture's absolute path, and expects its default export, a string, to be
/// `expected`. `body` may use top-level await on the promise forms, which return promises that
/// are already settled.
fn expectModuleResult(fixture: *const Fixture, body: []const u8, expected: []const u8) !void {
    const source = try std.fmt.allocPrint(allocator, "import fs from \"node:fs\";\nconst dir = {f};\n{s}", .{
        std.json.fmt(fixture.path(), .{}),
        body,
    });
    defer allocator.free(source);

    var vm = try support.createVm();
    defer vm.deinit();
    try vm.enableNodeFsForWorker();
    try support.registerModule(&vm, "/var/task/fs-test.js", source);
    try support.evaluateOk(&vm, "/var/task/fs-test.js");
    var result = try support.getExportOk(&vm, "/var/task/fs-test.js", "default");
    defer result.deinit();
    try support.expectValueString(&vm, &result, expected);
}

test "reads and writes without an encoding keep every byte, for an empty file and one over 64 KiB" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    // Every byte value, most of them invalid as UTF-8 at their position.
    var bytes: [70_000]u8 = undefined;
    for (&bytes, 0..) |*byte, index|
        byte.* = @truncate(index *% 7);
    try fixture.write("in.bin", &bytes);
    try fixture.write("empty.bin", "");

    try expectModuleResult(&fixture,
        \\const data = fs.readFileSync(dir + "/in.bin");
        \\fs.writeFileSync(dir + "/out.bin", data);
        \\const empty = fs.readFileSync(dir + "/empty.bin");
        \\fs.writeFileSync(dir + "/empty-out.bin", empty);
        \\const lazy = await fs.promises.readFile(dir + "/in.bin");
        \\export default [data instanceof Uint8Array, data.length, empty instanceof Uint8Array, empty.length, lazy.length].join(":");
    , "true:70000:true:0:70000");

    const written = try fixture.tmp.dir.readFileAlloc(allocator, "out.bin", bytes.len + 1);
    defer allocator.free(written);
    try std.testing.expectEqualSlices(u8, &bytes, written);
    const empty = try fixture.tmp.dir.statFile("empty-out.bin");
    try std.testing.expectEqual(@as(u64, 0), empty.size);
}

test "a UTF-8 read keeps a leading BOM and replaces each invalid byte" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.write("bom.txt", "\xEF\xBB\xBFa\xFFb");

    try expectModuleResult(&fixture,
        \\const text = fs.readFileSync(dir + "/bom.txt", "utf8");
        \\export default [...text].map((c) => c.codePointAt(0).toString(16)).join(",");
    , "feff,61,fffd,62");
}

test "a directory read is EISDIR, a file listed is ENOTDIR, and a rejected promise carries its code" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.write("file.txt", "x");
    try fixture.tmp.dir.makePath("sub");

    try expectModuleResult(&fixture,
        \\const failure = (f) => { try { f(); return "none"; } catch (e) { return e.code + "/" + e.syscall; } };
        \\const rejectedRead = await fs.promises.readFile(dir + "/missing").then(() => "none", (e) => e.code + "/" + e.syscall);
        \\const rejectedList = await fs.readdir(dir + "/file.txt").then(() => "none", (e) => e.code + "/" + e.syscall);
        \\export default [
        \\    failure(() => fs.readFileSync(dir + "/sub")),
        \\    failure(() => fs.readdirSync(dir + "/file.txt")),
        \\    rejectedRead,
        \\    rejectedList,
        \\].join(" ");
    , "EISDIR/read ENOTDIR/openat ENOENT/openat ENOTDIR/openat");
}

test "argument errors carry Node's codes" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.write("file.txt", "x");

    try expectModuleResult(&fixture,
        \\const code = (f) => { try { f(); return "none"; } catch (e) { return e.code; } };
        \\export default [
        \\    code(() => fs.readFileSync()),
        \\    code(() => fs.readFileSync(42)),
        \\    code(() => fs.statSync(dir + "/a\u0000b")),
        \\    code(() => fs.readFileSync(dir + "/file.txt", "latin1")),
        \\    code(() => fs.writeFileSync(dir + "/w.txt", 42)),
        \\].join(" ");
    , "ERR_INVALID_ARG_TYPE ERR_INVALID_ARG_TYPE ERR_INVALID_ARG_VALUE ERR_INVALID_ARG_VALUE ERR_INVALID_ARG_TYPE");
}

test "renaming a directory onto a non-empty one reports ENOTEMPTY with both paths" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.tmp.dir.makePath("from");
    try fixture.write("full/x", "x");

    try expectModuleResult(&fixture,
        \\let result = "none";
        \\try {
        \\    fs.renameSync(dir + "/from", dir + "/full");
        \\} catch (e) {
        \\    result = [e.code, e.syscall, e.path === dir + "/from", e.dest === dir + "/full"].join(":");
        \\}
        \\export default result;
    , "ENOTEMPTY:rename:true:true");
}

test "exists answers false for a name too long and for a path argument that is missing, not a string or holds a NUL" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.write("file.txt", "x");

    try expectModuleResult(&fixture,
        \\export default [
        \\    fs.existsSync(dir + "/file.txt"),
        \\    fs.existsSync(dir + "/" + "a".repeat(300)),
        \\    fs.existsSync(),
        \\    fs.existsSync(123),
        \\    fs.existsSync(dir + "/a\u0000b"),
        \\    await fs.exists(),
        \\    await fs.promises.exists(dir + "/file.txt"),
        \\].join(":");
    , "true:false:false:false:false:false:true");
}

test "an error's path is the string the caller passed, lone surrogate included" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    try expectModuleResult(&fixture,
        \\let same = "none";
        \\try {
        \\    fs.readFileSync(dir + "/\uD800");
        \\} catch (e) {
        \\    same = String(e.code === "ENOENT" && e.path === dir + "/\uD800");
        \\}
        \\export default same;
    , "true");
}

test "a listing is sorted by the bytes of the names, as Node sorts it" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    // The code point 0xFF01 is EF BC 81 and 0x1F600 is F0 9F 98 80, so the bytes put 0xFF01
    // first; the UTF-16 code units put the high surrogate of 0x1F600, 0xD83D, before 0xFF01.
    for ([_][]const u8{ "b", "\xF0\x9F\x98\x80", "B", "\xEF\xBC\x81", "a" }) |name| {
        const sub_path = try std.fs.path.join(allocator, &.{ "names", name });
        defer allocator.free(sub_path);
        try fixture.write(sub_path, "");
    }

    try expectModuleResult(&fixture,
        \\const listed = fs.readdirSync(dir + "/names");
        \\const lazy = await fs.promises.readdir(dir + "/names");
        \\export default listed.join("|") + "#" + lazy.join("|");
    , "B|a|b|\u{FF01}|\u{1F600}#B|a|b|\u{FF01}|\u{1F600}");
}

test "a relative path resolves against the process's working directory" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    try fixture.write("marker.txt", "m");
    // `std.testing.tmpDir` makes its directory under `.zig-cache/tmp/` of the working directory.
    const relative = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&fixture.tmp.sub_path});
    defer allocator.free(relative);
    const body = try std.fmt.allocPrint(allocator,
        \\const relative = {f};
        \\fs.writeFileSync(relative + "/relative.txt", "rel");
        \\export default fs.readdirSync(relative).join(",") + "|" + fs.readFileSync(dir + "/relative.txt", "utf8");
    , .{std.json.fmt(relative, .{})});
    defer allocator.free(body);

    try expectModuleResult(&fixture, body, "marker.txt,relative.txt|rel");
}
