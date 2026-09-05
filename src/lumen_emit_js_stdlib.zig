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
