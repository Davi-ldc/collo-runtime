//! The import scanner (`server/routes/imports.zig`): every static
//! declaration form it reports, the string-literal `import()` calls it
//! reports as dynamic at any depth, the computed calls, escaped literals,
//! `import.meta` and member uses it skips, code-like text inside strings,
//! templates, comments and regular expressions, the division and regular
//! expression heuristic, line numbers, the module preamble, and each failure
//! with its line.

const std = @import("std");
const routes = @import("collo_server_routes");

const imports = routes.imports;

const Expected = struct { []const u8, imports.Import.Kind };

const Scanned = struct {
    list: std.ArrayList(imports.Import) = .empty,

    fn deinit(self: *Scanned) void {
        self.list.deinit(std.testing.allocator);
    }

    /// Every import reported is static, with these specifiers in order.
    fn expectSpecifiers(self: *const Scanned, expected: []const []const u8) !void {
        try std.testing.expectEqual(expected.len, self.list.items.len);
        for (expected, self.list.items) |specifier, item| {
            try std.testing.expectEqualStrings(specifier, item.specifier);
            try std.testing.expectEqual(imports.Import.Kind.static, item.kind);
        }
    }

    fn expectImports(self: *const Scanned, expected: []const Expected) !void {
        try std.testing.expectEqual(expected.len, self.list.items.len);
        for (expected, self.list.items) |import_expected, item| {
            try std.testing.expectEqualStrings(import_expected[0], item.specifier);
            try std.testing.expectEqual(import_expected[1], item.kind);
        }
    }
};

fn scanOk(source: []const u8) !Scanned {
    var scanned: Scanned = .{};
    errdefer scanned.deinit();
    var failure: imports.Failure = undefined;
    imports.scan(std.testing.allocator, source, &scanned.list, &failure) catch |err| {
        if (err == error.InvalidModuleSource)
            std.debug.print("line {d}: {s}\n", .{ failure.line, failure.reason.describe() });
        return err;
    };
    return scanned;
}

fn expectFailure(source: []const u8, reason: imports.Failure.Reason, line: u32) !void {
    var list: std.ArrayList(imports.Import) = .empty;
    defer list.deinit(std.testing.allocator);
    var failure: imports.Failure = undefined;
    try std.testing.expectError(error.InvalidModuleSource, imports.scan(std.testing.allocator, source, &list, &failure));
    try std.testing.expectEqual(reason, failure.reason);
    try std.testing.expectEqual(line, failure.line);
}

test "every static declaration form is reported in source order" {
    var scanned = try scanOk(
        \\import a from "./a.js";
        \\import "./side.js";
        \\import * as ns from './ns.js';
        \\import { x, y as z } from "./named.js";
        \\import d, { e } from "./mixed.js";
        \\import f, * as g from "./star-default.js"
        \\export * from "./star.js";
        \\export * as all from "./all.js";
        \\export { q, r as s } from "./re.js";
        \\export { "string name" as t } from "./string-name.js";
        \\import from from "./from.js";
        \\import { from as other } from "./from-named.js";
        \\import json from "./data.js" with { type: "javascript" };
    );
    defer scanned.deinit();
    try scanned.expectSpecifiers(&.{
        "./a.js",     "./side.js",         "./ns.js",   "./named.js",
        "./mixed.js", "./star-default.js", "./star.js", "./all.js",
        "./re.js",    "./string-name.js",  "./from.js", "./from-named.js",
        "./data.js",
    });
    try std.testing.expectEqual(@as(u32, 1), scanned.list.items[0].line);
    try std.testing.expectEqual(@as(u32, 13), scanned.list.items[12].line);
}

test "string-literal import() calls are dynamic imports at any depth" {
    var scanned = try scanOk(
        \\const lazy = await import("./top.js");
        \\export async function handler() {
        \\    const a = await import('./nested.js');
        \\    const b = await import(/* why */ "./commented.js" /* not here */);
        \\    return [a, b, `${await import("./in-template.js")}`];
        \\}
        \\import("./options.js", { with: { type: "javascript" } });
        \\import.defer("./deferred.js");
        \\import "./static.js";
    );
    defer scanned.deinit();
    try scanned.expectImports(&.{
        .{ "./top.js", .dynamic },
        .{ "./nested.js", .dynamic },
        .{ "./commented.js", .dynamic },
        .{ "./in-template.js", .dynamic },
        .{ "./options.js", .dynamic },
        .{ "./deferred.js", .dynamic },
        .{ "./static.js", .static },
    });
    try std.testing.expectEqual(@as(u32, 3), scanned.list.items[1].line);
    try std.testing.expectEqual(@as(u32, 5), scanned.list.items[3].line);
}

test "computed import() calls, an escaped literal, import.meta, member and property uses report nothing" {
    var scanned = try scanOk(
        \\const name = "./computed.js";
        \\await import(name);
        \\await import(`./template.js`);
        \\await import(`./${name}`);
        \\await import("./concat-" + name);
        \\await import("./method.js".trim());
        \\await import(ready ? "./a.js" : "./b.js");
        \\await import('./\x61.js');
        \\console.log(import.meta.url);
        \\loader.import("./member.js");
        \\function f() { return { import: 1, export: 2 }; }
        \\class C { import() { return "./method.js"; } }
        \\export const value = 1;
        \\export default function handler() {}
        \\export { value as renamed };
        \\export async function later() {}
    );
    defer scanned.deinit();
    try scanned.expectImports(&.{});
}

test "code-like text in strings, templates, comments and regular expressions is skipped" {
    var scanned = try scanOk(
        \\const s = "import x from './in-string.js'";
        \\const t = `import y from "./in-template.js" ${"import z from './in-expression.js'"}`;
        \\// import a from "./in-line-comment.js";
        \\/* import b from "./in-block-comment.js"; */
        \\const r = /import c from "x"/g.test(s);
        \\import real from "./real.js";
    );
    defer scanned.deinit();
    try scanned.expectSpecifiers(&.{"./real.js"});
    try std.testing.expectEqual(@as(u32, 6), scanned.list.items[0].line);
}

test "divisions are not read as regular expressions" {
    // On the sixth line, the `/ 2` after the function body's `}` looks like
    // the start of a regular expression; it never closes on its line, so the
    // scan reads it as a division.
    var scanned = try scanOk(
        \\const half = total / 2; const third = (a + b) / 3 / 1;
        \\let i = 0; i++ / 2; const q = arr[0] / x;
        \\const ratio = stats.in / stats.return / 2; const quote = "'";
        \\import afterDivision from "./after-division.js";
        \\function g(v) { if (v) /x/.test(v); return /import fake from "x"/; }
        \\const weird = function () {} / 2;
        \\import last from "./last.js";
    );
    defer scanned.deinit();
    try scanned.expectSpecifiers(&.{ "./after-division.js", "./last.js" });
}

test "template expressions nest and resume the template" {
    var scanned = try scanOk(
        \\const deep = `a ${`b ${"}"} c`} d ${ { key: "}" }.key } e`;
        \\import after from "./after-template.js";
    );
    defer scanned.deinit();
    try scanned.expectSpecifiers(&.{"./after-template.js"});
}

test "line numbers count newlines in comments, templates and strings" {
    var scanned = try scanOk("/* one\ntwo */\nconst t = `\n\n`;\nconst s = 'a\\\nb';\nimport x from './x.js';\n");
    defer scanned.deinit();
    try scanned.expectSpecifiers(&.{"./x.js"});
    try std.testing.expectEqual(@as(u32, 8), scanned.list.items[0].line);
}

test "an export list without from does not swallow the next declaration" {
    var scanned = try scanOk("export { a, b }\nimport c from './c.js'\nexport { d }");
    defer scanned.deinit();
    try scanned.expectSpecifiers(&.{"./c.js"});
}

test "a byte order mark and a hashbang line may open the module" {
    var scanned = try scanOk("\xEF\xBB\xBF#!/usr/bin/env collo\nimport x from './x.js';");
    defer scanned.deinit();
    try scanned.expectSpecifiers(&.{"./x.js"});
}

test "malformed source fails with the reason and the line" {
    try expectFailure("const s = 'open\nimport x from './x.js';", .unterminated_string, 1);
    try expectFailure("\nconst t = `open", .unterminated_template, 2);
    try expectFailure("\n\n/* open", .unterminated_comment, 3);
    try expectFailure("import a;", .malformed_declaration, 1);
    try expectFailure("import a from b;", .malformed_declaration, 1);
    try expectFailure("export * ;", .malformed_declaration, 1);
    try expectFailure("export { a } from b;", .malformed_declaration, 1);
    try expectFailure("\nimport a from './\\x61.js';", .escaped_specifier, 2);
    try expectFailure("\n\nexport * from './\\x61.js';", .escaped_specifier, 3);
    try expectFailure("(" ** (imports.nesting_max + 1), .nesting_too_deep, 1);
}

test "a module with more imports than a pack holds modules is rejected" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    for (0..imports.imports_max + 1) |index|
        try source.print(std.testing.allocator, "import './m{d}.js';\n", .{index});
    try expectFailure(source.items, .too_many_imports, @intCast(imports.imports_max + 1));
}
