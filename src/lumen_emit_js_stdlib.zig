//! The standard library on the node target: which calls print as written and
//! which need a hand, because the runtime package (spec 503) shaped a
//! namespace to Lumen's calls but JavaScript's own methods keep JavaScript's
//! conventions.
//!
//! Static calls (`Math.floor`, `fs.readFileSync`, `process.platform()`) are
//! identity: the runtime exports every name the checker accepts, in Lumen's
//! shape. Instance methods are JavaScript's, and the one convention that
//! differs is "nothing there": `find`, `at`, `pop`, `Map.get` answer
//! `undefined` where the language says `null`, so those calls get `?? null`.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const types = @import("lumen_types.zig");
const check_methods = @import("lumen_check_methods.zig");

// ---------------------------------------------------------------------------
// String methods (spec 505). A string value is a JavaScript string of bytes,
// one code unit per byte, so a method that only indexes, searches, slices or
// concatenates is JavaScript's own: the byte operation *is* the operation.
// The ones below differ, and route through `__lang` (the runtime package's
// `lib/lang.mjs`), which computes what the native runtime computes:
//
// - `charCodeAt`/`codePointAt`: the byte, or `-1` past the end (spec 101),
//   where JavaScript answers `NaN`.
// - `toUpperCase`/`toLowerCase`: ASCII only (spec 063); JavaScript would
//   case-map the byte 0xE9 as `é`, and `ß` to two code units.
// - `trim`/`trimStart`/`trimEnd`: space, tab, CR, LF only; JavaScript also
//   strips 0xA0 and 0x85, which are bytes of `à` and `…`.
// - `localeCompare`: byte order, -1/0/1 (spec 109); no locale.
// - `repeat`: a negative count is an empty string, not a `RangeError`.
// - `replace`/`replaceAll` with a string pattern: the replacement is text
//   (`$&` is two characters) and an empty pattern matches nothing (spec 063);
//   the regex forms stay JavaScript's.

const StringLowering = struct { name: []const u8, helper: ?[]const u8 };

/// Every method the checker accepts on a string (`string_method_names`) and
/// its lowering: `null` prints the call as written, otherwise the `__lang`
/// function that takes the receiver first.
const string_methods = [_]StringLowering{
    .{ .name = "charAt", .helper = null },
    .{ .name = "at", .helper = null },
    .{ .name = "charCodeAt", .helper = "charCodeAt" },
    .{ .name = "codePointAt", .helper = "charCodeAt" },
    .{ .name = "indexOf", .helper = null },
    .{ .name = "lastIndexOf", .helper = null },
    .{ .name = "localeCompare", .helper = "localeCompare" },
    .{ .name = "includes", .helper = null },
    .{ .name = "startsWith", .helper = null },
    .{ .name = "endsWith", .helper = null },
    .{ .name = "slice", .helper = null },
    .{ .name = "substring", .helper = null },
    .{ .name = "repeat", .helper = "repeat" },
    .{ .name = "padStart", .helper = null },
    .{ .name = "padEnd", .helper = null },
    .{ .name = "replace", .helper = "replace" },
    .{ .name = "replaceAll", .helper = "replaceAll" },
    .{ .name = "toUpperCase", .helper = "toUpperCase" },
    .{ .name = "toLowerCase", .helper = "toLowerCase" },
    .{ .name = "trim", .helper = "trim" },
    .{ .name = "trimStart", .helper = "trimStart" },
    .{ .name = "trimEnd", .helper = "trimEnd" },
    .{ .name = "split", .helper = null },
    .{ .name = "concat", .helper = null },
    .{ .name = "search", .helper = null },
    .{ .name = "match", .helper = null },
};

/// The `__lang` helper a string method call routes through, or `null` when
/// the JavaScript method computes the byte result itself. A regex-pattern
/// `replace`/`replaceAll` is JavaScript's (`regex_arg`).
pub fn stringMethodHelper(m: anytype) ?[]const u8 {
    if (!m.string_method or m.regex_arg) return null;
    for (string_methods) |sm| if (std.mem.eql(u8, sm.name, m.name)) return sm.helper;
    return null;
}

/// Whether this method answers `undefined` for a missing value in JavaScript
/// where Lumen's type is `T | null`, so the call must be followed by `?? null`.
pub fn nullOnMissing(m: anytype) bool {
    const name = m.name;
    if (m.array_elem_type != null or m.array_result_type != null) {
        return std.mem.eql(u8, name, "find") or std.mem.eql(u8, name, "findLast") or std.mem.eql(u8, name, "at") or std.mem.eql(u8, name, "pop") or std.mem.eql(u8, name, "shift");
    }
    if (m.string_method) return std.mem.eql(u8, name, "at");
    if (m.container_type) |ct| {
        if (ct == .map_type) return std.mem.eql(u8, name, "get");
    }
    return false;
}

/// The static calls the runtime package only stubs (spec 503 T012): they
/// block or thread natively and need spec 508's I/O broker. Reported at
/// compile time rather than thrown at run time (FR-005).
pub fn unsupportedStaticCall(ns: []const u8, name: []const u8) ?[]const u8 {
    const eq = std.mem.eql;
    if (eq(u8, ns, "net")) return "`net.*`";
    if (eq(u8, ns, "http") and (eq(u8, name, "request") or eq(u8, name, "get") or eq(u8, name, "stream") or eq(u8, name, "createServer"))) return "`http.request`/`get`/`stream`/`createServer`";
    if (eq(u8, ns, "child_process") and eq(u8, name, "spawn")) return "`child_process.spawn`";
    if (eq(u8, ns, "Worker") and eq(u8, name, "run")) return "`Worker.run`";
    return null;
}

/// Whether this method answers an iterator in JavaScript where the language
/// says array (`Map.keys()` is `string[]`, spec 360), so the call is wrapped
/// in `Array.from(...)`.
pub fn iteratorToArray(m: anytype) bool {
    const ct = m.container_type orelse return false;
    if (ct != .map_type and ct != .set_type) return false;
    return std.mem.eql(u8, m.name, "keys") or std.mem.eql(u8, m.name, "values") or std.mem.eql(u8, m.name, "entries");
}

test "only the methods whose miss is undefined get the null" {
    const t = std.testing;
    var obj: ast.Expr = .{ .var_ref = .{ .name = "xs" } };
    const find = ast.Expr{ .method_call = .{ .obj = &obj, .name = "find", .args = &.{}, .array_elem_type = .i32 } };
    try t.expect(nullOnMissing(find.method_call));
    const filter = ast.Expr{ .method_call = .{ .obj = &obj, .name = "filter", .args = &.{}, .array_elem_type = .i32 } };
    try t.expect(!nullOnMissing(filter.method_call));
    const own_find = ast.Expr{ .method_call = .{ .obj = &obj, .name = "find", .args = &.{} } };
    try t.expect(!nullOnMissing(own_find.method_call));
}

test "the refusals name calls the checker accepts, and all of `net` (503 names.json)" {
    // `names.json` is what `tools/stdlib_names.py` extracted from the checker:
    // every namespace call a program can make. A refusal for a name the
    // checker does not accept would be dead; a `net` call it accepts and
    // this table lets through would reach the runtime's stub instead of the
    // compile-time diagnostic FR-005 promises.
    const t = std.testing;
    var parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, @embedFile("names.json"), .{});
    defer parsed.deinit();
    const namespaces = parsed.value.object.get("namespaces").?.object;
    const refused = [_][2][]const u8{
        .{ "net", "connect" },         .{ "net", "createServer" }, .{ "http", "request" },
        .{ "http", "get" },            .{ "http", "stream" },      .{ "http", "createServer" },
        .{ "child_process", "spawn" }, .{ "Worker", "run" },
    };
    for (refused) |r| {
        try t.expect(unsupportedStaticCall(r[0], r[1]) != null);
        var known = false;
        for (namespaces.get(r[0]).?.array.items) |n| if (std.mem.eql(u8, n.string, r[1])) {
            known = true;
        };
        try t.expect(known);
    }
    for (namespaces.get("net").?.array.items) |n| try t.expect(unsupportedStaticCall("net", n.string) != null);
    // The rest of `http` and `child_process` is real in the runtime package.
    try t.expect(unsupportedStaticCall("http", "METHODS") == null);
    try t.expect(unsupportedStaticCall("child_process", "spawnSync") == null);
}

test "every string method the checker accepts has a node lowering" {
    const t = std.testing;
    for (check_methods.string_method_names) |name| {
        var found = false;
        for (string_methods) |sm| if (std.mem.eql(u8, sm.name, name)) {
            found = true;
        };
        try t.expect(found);
    }
    try t.expectEqual(check_methods.string_method_names.len, string_methods.len);
    var obj: ast.Expr = .{ .var_ref = .{ .name = "s" } };
    const upper = ast.Expr{ .method_call = .{ .obj = &obj, .name = "toUpperCase", .args = &.{}, .string_method = true } };
    try t.expectEqualStrings("toUpperCase", stringMethodHelper(upper.method_call).?);
    const code = ast.Expr{ .method_call = .{ .obj = &obj, .name = "codePointAt", .args = &.{}, .string_method = true } };
    try t.expectEqualStrings("charCodeAt", stringMethodHelper(code.method_call).?);
    const slice = ast.Expr{ .method_call = .{ .obj = &obj, .name = "slice", .args = &.{}, .string_method = true } };
    try t.expect(stringMethodHelper(slice.method_call) == null);
    // The regex form of `replace` is JavaScript's; an array method of the
    // same name is not a string method at all.
    const re = ast.Expr{ .method_call = .{ .obj = &obj, .name = "replace", .args = &.{}, .string_method = true, .regex_arg = true } };
    try t.expect(stringMethodHelper(re.method_call) == null);
    const arr = ast.Expr{ .method_call = .{ .obj = &obj, .name = "at", .args = &.{}, .array_elem_type = .i32 } };
    try t.expect(stringMethodHelper(arr.method_call) == null);
}
