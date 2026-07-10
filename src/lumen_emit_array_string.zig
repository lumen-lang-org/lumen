//! Codegen for array and string instance methods (`.filter`, `.map`,
//! `.reduce`, `.indexOf`, `.join`, `.slice`, `.split`, `.toUpperCase`, ...)
//! and template-literal text escaping.
//!
//! Each array/string method lowers to a small inline Zig snippet (a loop or a
//! direct `std.mem`/`std.ArrayList` call) rather than a shared runtime
//! function, so the bulk of this file is per-method emission logic keyed off
//! `mc.name`. `g_array_method_seq`/`g_string_method_seq` give each emitted
//! snippet's temporaries a unique suffix so nested/sequential method calls in
//! one expression never collide.
//!
//! Pulled out of `lumen_emit.zig` as the largest single "instance method
//! lowering" concern, parallel to `lumen_check_stdlib.zig` on the checking
//! side.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const types = @import("lumen_types.zig");
const diag_mod = @import("lumen_diag.zig");
const emit_mod = @import("lumen_emit.zig");

const CompileError = diag_mod.CompileError;
const Expr = ast.Expr;
const emitExpr = emit_mod.emitExpr;

pub fn emitElemEq(elem: types.Type, needle: *const Expr, w: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    if (types.isStringLike(elem)) {
        try w.appendSlice(arena, "std.mem.eql(u8, __e, ");
        try emitExpr(needle, w, arena);
        try w.append(arena, ')');
    } else {
        try w.appendSlice(arena, "(__e == ");
        try emitExpr(needle, w, arena);
        try w.append(arena, ')');
    }
}

/// Emit `const __start: isize = ...;` for `indexOf`/`includes`: the optional
/// second argument is a start index that counts from the end when negative,
/// clamped into `[0, len]`; with no argument the scan starts at 0. Assumes
/// `__arr` is already bound in the surrounding block.
fn emitArrayStart(mc: anytype, w: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    if (mc.args.len == 2) {
        try w.appendSlice(arena, "const __len: isize = @intCast(__arr.len); const __from: isize = @intCast(");
        try emitExpr(mc.args[1], w, arena);
        try w.appendSlice(arena, "); const __start: isize = if (__from < 0) (if (__len + __from < 0) 0 else __len + __from) else __from; ");
    } else {
        try w.appendSlice(arena, "const __start: isize = 0; ");
    }
}

/// Monotonic counter giving each emitted array-method block a unique label so
/// chained/nested calls (`xs.map(...).filter(...)`) don't collide on `blk`.
var g_array_method_seq: usize = 0;

/// Lower an array higher-order / value method `arr.m(args)` to an inline Zig
/// expression block over the underlying slice. Callbacks are invoked through the
/// uniform function-value representation (`__cb.call(__cb.ctx, ...)`).
pub fn emitArrayMethod(mc: anytype, w: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    const elem = mc.array_elem_type orelse return error.ParseError;
    const result = mc.array_result_type orelse return error.ParseError;
    const elem_zig = try types.zigName(arena, elem);
    const eq = std.mem.eql;
    const name = mc.name;
    g_array_method_seq += 1;
    const lbl = try std.fmt.allocPrint(arena, "__am{d}", .{g_array_method_seq});

    if (eq(u8, name, "map")) {
        const u = types.arrayElem(result) orelse return error.ParseError;
        const u_zig = try types.zigName(arena, u);
        const idx_arg = if (mc.cb_wants_index) ", @as(i32, @intCast(__i))" else "";
        try w.print(arena, "({s}: {{ const __arr = ", .{lbl});
        try emitExpr(mc.obj, w, arena);
        try w.appendSlice(arena, "; const __cb = ");
        try emitExpr(mc.args[0], w, arena);
        try w.print(arena, "; const __r = __sa().alloc({s}, __arr.len) catch unreachable; for (__arr, 0..) |__e, __i| {{ __r[__i] = __cb.call(__cb.ctx, __e{s}); }} break :{s} @as([]const {s}, __r); }})", .{ u_zig, idx_arg, lbl, u_zig });
        return;
    }

    if (eq(u8, name, "filter")) {
        const loop_hdr = if (mc.cb_wants_index) "for (__arr, 0..) |__e, __i|" else "for (__arr) |__e|";
        const idx_arg = if (mc.cb_wants_index) ", @as(i32, @intCast(__i))" else "";
        try w.print(arena, "({s}: {{ const __arr = ", .{lbl});
        try emitExpr(mc.obj, w, arena);
        try w.appendSlice(arena, "; const __cb = ");
        try emitExpr(mc.args[0], w, arena);
        try w.print(arena, "; var __r: std.ArrayListUnmanaged({s}) = .empty; {s} {{ if (__cb.call(__cb.ctx, __e{s})) __r.append(__sa(), __e) catch unreachable; }} break :{s} @as([]const {s}, __r.items); }})", .{ elem_zig, loop_hdr, idx_arg, lbl, elem_zig });
        return;
    }

    if (eq(u8, name, "forEach")) {
        const loop_hdr = if (mc.cb_wants_index) "for (__arr, 0..) |__e, __i|" else "for (__arr) |__e|";
        const idx_arg = if (mc.cb_wants_index) ", @as(i32, @intCast(__i))" else "";
        try w.print(arena, "({s}: {{ const __arr = ", .{lbl});
        try emitExpr(mc.obj, w, arena);
        try w.appendSlice(arena, "; const __cb = ");
        try emitExpr(mc.args[0], w, arena);
        try w.print(arena, "; {s} {{ __cb.call(__cb.ctx, __e{s}); }} break :{s} {{}}; }})", .{ loop_hdr, idx_arg, lbl });
        return;
    }

    if (eq(u8, name, "reduce")) {
        const acc = mc.array_acc_type orelse return error.ParseError;
        const acc_zig = try types.zigName(arena, acc);
        try w.print(arena, "({s}: {{ const __arr = ", .{lbl});
        try emitExpr(mc.obj, w, arena);
        try w.appendSlice(arena, "; const __cb = ");
        try emitExpr(mc.args[0], w, arena);
        try w.print(arena, "; var __acc: {s} = ", .{acc_zig});
        try emitExpr(mc.args[1], w, arena);
        const loop_hdr = if (mc.cb_wants_index) "for (__arr, 0..) |__e, __i|" else "for (__arr) |__e|";
        const idx_arg = if (mc.cb_wants_index) ", @as(i32, @intCast(__i))" else "";
        try w.print(arena, "; {s} {{ __acc = __cb.call(__cb.ctx, __acc, __e{s}); }} break :{s} __acc; }})", .{ loop_hdr, idx_arg, lbl });
        return;
    }

    if (eq(u8, name, "find")) {
        const loop_hdr = if (mc.cb_wants_index) "for (__arr, 0..) |__e, __i|" else "for (__arr) |__e|";
        const idx_arg = if (mc.cb_wants_index) ", @as(i32, @intCast(__i))" else "";
        try w.print(arena, "({s}: {{ const __arr = ", .{lbl});
        try emitExpr(mc.obj, w, arena);
        try w.appendSlice(arena, "; const __cb = ");
        try emitExpr(mc.args[0], w, arena);
        try w.print(arena, "; var __found: ?{s} = null; {s} {{ if (__cb.call(__cb.ctx, __e{s})) {{ __found = __e; break; }} }} break :{s} __found; }})", .{ elem_zig, loop_hdr, idx_arg, lbl });
        return;
    }

    if (eq(u8, name, "some")) {
        const loop_hdr = if (mc.cb_wants_index) "for (__arr, 0..) |__e, __i|" else "for (__arr) |__e|";
        const idx_arg = if (mc.cb_wants_index) ", @as(i32, @intCast(__i))" else "";
        try w.print(arena, "({s}: {{ const __arr = ", .{lbl});
        try emitExpr(mc.obj, w, arena);
        try w.appendSlice(arena, "; const __cb = ");
        try emitExpr(mc.args[0], w, arena);
        try w.print(arena, "; var __r = false; {s} {{ if (__cb.call(__cb.ctx, __e{s})) {{ __r = true; break; }} }} break :{s} __r; }})", .{ loop_hdr, idx_arg, lbl });
        return;
    }

    if (eq(u8, name, "every")) {
        const loop_hdr = if (mc.cb_wants_index) "for (__arr, 0..) |__e, __i|" else "for (__arr) |__e|";
        const idx_arg = if (mc.cb_wants_index) ", @as(i32, @intCast(__i))" else "";
        try w.print(arena, "({s}: {{ const __arr = ", .{lbl});
        try emitExpr(mc.obj, w, arena);
        try w.appendSlice(arena, "; const __cb = ");
        try emitExpr(mc.args[0], w, arena);
        try w.print(arena, "; var __r = true; {s} {{ if (!__cb.call(__cb.ctx, __e{s})) {{ __r = false; break; }} }} break :{s} __r; }})", .{ loop_hdr, idx_arg, lbl });
        return;
    }

    if (eq(u8, name, "findIndex")) {
        const idx_arg = if (mc.cb_wants_index) ", @as(i32, @intCast(__i))" else "";
        try w.print(arena, "({s}: {{ const __arr = ", .{lbl});
        try emitExpr(mc.obj, w, arena);
        try w.appendSlice(arena, "; const __cb = ");
        try emitExpr(mc.args[0], w, arena);
        try w.print(arena, "; var __idx: i32 = -1; for (__arr, 0..) |__e, __i| {{ if (__cb.call(__cb.ctx, __e{s})) {{ __idx = @as(i32, @intCast(__i)); break; }} }} break :{s} __idx; }})", .{ idx_arg, lbl });
        return;
    }

    if (eq(u8, name, "findLast")) {
        const loop_hdr = if (mc.cb_wants_index) "for (__arr, 0..) |__e, __i|" else "for (__arr) |__e|";
        const idx_arg = if (mc.cb_wants_index) ", @as(i32, @intCast(__i))" else "";
        try w.print(arena, "({s}: {{ const __arr = ", .{lbl});
        try emitExpr(mc.obj, w, arena);
        try w.appendSlice(arena, "; const __cb = ");
        try emitExpr(mc.args[0], w, arena);
        try w.print(arena, "; var __found: ?{s} = null; {s} {{ if (__cb.call(__cb.ctx, __e{s})) __found = __e; }} break :{s} __found; }})", .{ elem_zig, loop_hdr, idx_arg, lbl });
        return;
    }

    if (eq(u8, name, "findLastIndex")) {
        const idx_arg = if (mc.cb_wants_index) ", @as(i32, @intCast(__i))" else "";
        try w.print(arena, "({s}: {{ const __arr = ", .{lbl});
        try emitExpr(mc.obj, w, arena);
        try w.appendSlice(arena, "; const __cb = ");
        try emitExpr(mc.args[0], w, arena);
        try w.print(arena, "; var __idx: i32 = -1; for (__arr, 0..) |__e, __i| {{ if (__cb.call(__cb.ctx, __e{s})) __idx = @as(i32, @intCast(__i)); }} break :{s} __idx; }})", .{ idx_arg, lbl });
        return;
    }

    if (eq(u8, name, "indexOf")) {
        try w.print(arena, "({s}: {{ const __arr = ", .{lbl});
        try emitExpr(mc.obj, w, arena);
        try w.appendSlice(arena, "; ");
        try emitArrayStart(mc, w, arena);
        try w.appendSlice(arena, "var __idx: i32 = -1; for (__arr, 0..) |__e, __i| { if (@as(isize, @intCast(__i)) < __start) continue; if (");
        try emitElemEq(elem, mc.args[0], w, arena);
        try w.print(arena, ") {{ __idx = @as(i32, @intCast(__i)); break; }} }} break :{s} __idx; }})", .{lbl});
        return;
    }

    if (eq(u8, name, "lastIndexOf")) {
        try w.print(arena, "({s}: {{ const __arr = ", .{lbl});
        try emitExpr(mc.obj, w, arena);
        try w.appendSlice(arena, "; var __idx: i32 = -1; for (__arr, 0..) |__e, __i| { if (");
        try emitElemEq(elem, mc.args[0], w, arena);
        try w.print(arena, ") {{ __idx = @as(i32, @intCast(__i)); }} }} break :{s} __idx; }})", .{lbl});
        return;
    }

    if (eq(u8, name, "includes")) {
        try w.print(arena, "({s}: {{ const __arr = ", .{lbl});
        try emitExpr(mc.obj, w, arena);
        try w.appendSlice(arena, "; ");
        try emitArrayStart(mc, w, arena);
        try w.appendSlice(arena, "var __r = false; for (__arr, 0..) |__e, __i| { if (@as(isize, @intCast(__i)) < __start) continue; if (");
        try emitElemEq(elem, mc.args[0], w, arena);
        try w.print(arena, ") {{ __r = true; break; }} }} break :{s} __r; }})", .{lbl});
        return;
    }

    if (eq(u8, name, "at")) {
        try w.print(arena, "({s}: {{ const __arr = ", .{lbl});
        try emitExpr(mc.obj, w, arena);
        try w.appendSlice(arena, "; const __len: isize = @intCast(__arr.len); const __i: isize = @intCast(");
        try emitExpr(mc.args[0], w, arena);
        try w.print(arena, "); const __j: isize = if (__i < 0) __len + __i else __i; break :{s} @as(?{s}, if (__j >= 0 and __j < __len) __arr[@intCast(__j)] else null); }})", .{ lbl, elem_zig });
        return;
    }

    if (eq(u8, name, "concat")) {
        try w.print(arena, "({s}: {{ const __arr = ", .{lbl});
        try emitExpr(mc.obj, w, arena);
        try w.appendSlice(arena, "; const __other = ");
        try emitExpr(mc.args[0], w, arena);
        try w.print(arena, "; const __r = __sa().alloc({s}, __arr.len + __other.len) catch unreachable; @memcpy(__r[0..__arr.len], __arr); @memcpy(__r[__arr.len..], __other); break :{s} @as([]const {s}, __r); }})", .{ elem_zig, lbl, elem_zig });
        return;
    }

    if (eq(u8, name, "sort")) {
        try w.print(arena, "({s}: {{ const __arr = ", .{lbl});
        try emitExpr(mc.obj, w, arena);
        try w.appendSlice(arena, "; const __cb = ");
        try emitExpr(mc.args[0], w, arena);
        try w.print(arena, "; const __r = __sa().alloc({s}, __arr.len) catch unreachable; @memcpy(__r, __arr); std.mem.sort({s}, __r, __cb, struct {{ fn __lt(__c: @TypeOf(__cb), __a: {s}, __b: {s}) bool {{ return __c.call(__c.ctx, __a, __b) < 0; }} }}.__lt); break :{s} @as([]const {s}, __r); }})", .{ elem_zig, elem_zig, elem_zig, elem_zig, lbl, elem_zig });
        return;
    }

    if (eq(u8, name, "reverse")) {
        try w.print(arena, "({s}: {{ const __arr = ", .{lbl});
        try emitExpr(mc.obj, w, arena);
        try w.print(arena, "; const __r = __sa().alloc({s}, __arr.len) catch unreachable; for (__arr, 0..) |__e, __i| {{ __r[__arr.len - 1 - __i] = __e; }} break :{s} @as([]const {s}, __r); }})", .{ elem_zig, lbl, elem_zig });
        return;
    }

    if (eq(u8, name, "slice")) {
        try w.print(arena, "({s}: {{ const __arr = ", .{lbl});
        try emitExpr(mc.obj, w, arena);
        try w.appendSlice(arena, "; const __len: isize = @intCast(__arr.len); const __a: isize = @intCast(");
        if (mc.args.len >= 1) {
            try emitExpr(mc.args[0], w, arena);
        } else {
            try w.appendSlice(arena, "@as(isize, 0)");
        }
        try w.appendSlice(arena, "); const __b: isize = ");
        if (mc.args.len == 2) {
            try w.appendSlice(arena, "@intCast(");
            try emitExpr(mc.args[1], w, arena);
            try w.appendSlice(arena, ")");
        } else {
            try w.appendSlice(arena, "__len");
        }
        try w.appendSlice(arena, "; const __c0: isize = if (__a < 0) 0 else if (__a > __len) __len else __a; ");
        try w.appendSlice(arena, "const __c1: isize = if (__b < 0) 0 else if (__b > __len) __len else __b; ");
        try w.appendSlice(arena, "const __hi: isize = if (__c1 < __c0) __c0 else __c1; ");
        try w.print(arena, "break :{s} @as([]const {s}, __arr[@intCast(__c0)..@intCast(__hi)]); }})", .{ lbl, elem_zig });
        return;
    }

    if (eq(u8, name, "join")) {
        const spec = switch (elem) {
            .string, .string_literal_union => "{s}",
            .bool => "{}",
            else => "{d}",
        };
        try w.print(arena, "({s}: {{ const __arr = ", .{lbl});
        try emitExpr(mc.obj, w, arena);
        try w.appendSlice(arena, "; const __sep: []const u8 = ");
        if (mc.args.len == 1) {
            try emitExpr(mc.args[0], w, arena);
        } else {
            try w.appendSlice(arena, "\",\"");
        }
        try w.appendSlice(arena, "; var __buf: std.ArrayListUnmanaged(u8) = .empty; for (__arr, 0..) |__e, __i| { if (__i > 0) __buf.appendSlice(__sa(), __sep) catch unreachable; ");
        try w.print(arena, "__buf.appendSlice(__sa(), std.fmt.allocPrint(__sa(), \"{s}\", .{{__e}}) catch unreachable) catch unreachable; }} break :{s} @as([]const u8, __buf.items); }})", .{ spec, lbl });
        return;
    }

    return error.ParseError;
}

/// Monotonic counter giving each emitted string-method block a unique label.
var g_string_method_seq: usize = 0;

/// Lower a string instance method `s.m(args)` to an inline Zig expression block
/// over the underlying byte slice. Results are allocated with the page allocator
/// (allocate-and-leak), matching the array-method lowering.
pub fn emitStringMethod(mc: anytype, w: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    const eq = std.mem.eql;
    const name = mc.name;
    g_string_method_seq += 1;
    const lbl = try std.fmt.allocPrint(arena, "__sm{d}", .{g_string_method_seq});

    // Open the block and bind `__s` to the receiver string.
    try w.print(arena, "({s}: {{ const __s: []const u8 = ", .{lbl});
    try emitExpr(mc.obj, w, arena);
    try w.appendSlice(arena, "; ");

    // Helper to emit an argument coerced to isize (indices may be i32 or i64).
    const A = struct {
        fn idx(varname: []const u8, e: anytype, ww: *std.ArrayListUnmanaged(u8), ar: std.mem.Allocator) CompileError!void {
            try ww.print(ar, "const {s}: isize = @intCast(", .{varname});
            try emitExpr(e, ww, ar);
            try ww.appendSlice(ar, "); ");
        }
    };

    if (eq(u8, name, "charAt")) {
        try A.idx("__i", mc.args[0], w, arena);
        try w.print(arena, "break :{s} @as([]const u8, if (__i >= 0 and __i < @as(isize, @intCast(__s.len))) __s[@intCast(__i)..@as(usize, @intCast(__i)) + 1] else \"\"); }})", .{lbl});
        return;
    }

    if (eq(u8, name, "charCodeAt")) {
        try A.idx("__i", mc.args[0], w, arena);
        try w.print(arena, "break :{s} @as(i32, if (__i >= 0 and __i < @as(isize, @intCast(__s.len))) @intCast(__s[@intCast(__i)]) else -1); }})", .{lbl});
        return;
    }

    if (eq(u8, name, "at")) {
        try A.idx("__i0", mc.args[0], w, arena);
        try w.appendSlice(arena, "const __len: isize = @intCast(__s.len); const __i: isize = if (__i0 < 0) __len + __i0 else __i0; ");
        try w.print(arena, "break :{s} @as([]const u8, if (__i >= 0 and __i < __len) __s[@intCast(__i)..@as(usize, @intCast(__i)) + 1] else \"\"); }})", .{lbl});
        return;
    }

    if (eq(u8, name, "indexOf")) {
        try w.appendSlice(arena, "const __needle: []const u8 = ");
        try emitExpr(mc.args[0], w, arena);
        if (mc.args.len == 2) {
            try w.appendSlice(arena, "; const __from: isize = @intCast(");
            try emitExpr(mc.args[1], w, arena);
            try w.appendSlice(arena, "); const __start: usize = if (__from < 0) 0 else if (__from > @as(isize, @intCast(__s.len))) __s.len else @intCast(__from); ");
            try w.print(arena, "break :{s} @as(i32, if (std.mem.indexOfPos(u8, __s, __start, __needle)) |__p| @intCast(__p) else -1); }})", .{lbl});
        } else {
            try w.print(arena, "; break :{s} @as(i32, if (std.mem.indexOf(u8, __s, __needle)) |__p| @intCast(__p) else -1); }})", .{lbl});
        }
        return;
    }

    if (eq(u8, name, "lastIndexOf")) {
        try w.appendSlice(arena, "const __needle: []const u8 = ");
        try emitExpr(mc.args[0], w, arena);
        try w.print(arena, "; break :{s} @as(i32, if (std.mem.lastIndexOf(u8, __s, __needle)) |__p| @intCast(__p) else -1); }})", .{lbl});
        return;
    }

    if (eq(u8, name, "includes")) {
        try w.appendSlice(arena, "const __needle: []const u8 = ");
        try emitExpr(mc.args[0], w, arena);
        if (mc.args.len == 2) {
            try w.appendSlice(arena, "; const __from: isize = @intCast(");
            try emitExpr(mc.args[1], w, arena);
            try w.appendSlice(arena, "); const __start: usize = if (__from < 0) 0 else if (__from > @as(isize, @intCast(__s.len))) __s.len else @intCast(__from); ");
            try w.print(arena, "break :{s} (std.mem.indexOfPos(u8, __s, __start, __needle) != null); }})", .{lbl});
        } else {
            try w.print(arena, "; break :{s} (std.mem.indexOf(u8, __s, __needle) != null); }})", .{lbl});
        }
        return;
    }

    if (eq(u8, name, "startsWith")) {
        try w.appendSlice(arena, "const __needle: []const u8 = ");
        try emitExpr(mc.args[0], w, arena);
        if (mc.args.len == 2) {
            try w.appendSlice(arena, "; const __from: isize = @intCast(");
            try emitExpr(mc.args[1], w, arena);
            try w.appendSlice(arena, "); const __start: usize = if (__from < 0) 0 else if (__from > @as(isize, @intCast(__s.len))) __s.len else @intCast(__from); ");
            try w.print(arena, "break :{s} std.mem.startsWith(u8, __s[__start..], __needle); }})", .{lbl});
        } else {
            try w.print(arena, "; break :{s} std.mem.startsWith(u8, __s, __needle); }})", .{lbl});
        }
        return;
    }

    if (eq(u8, name, "endsWith")) {
        try w.appendSlice(arena, "const __needle: []const u8 = ");
        try emitExpr(mc.args[0], w, arena);
        if (mc.args.len == 2) {
            try w.appendSlice(arena, "; const __ep: isize = @intCast(");
            try emitExpr(mc.args[1], w, arena);
            try w.appendSlice(arena, "); const __end: usize = if (__ep < 0) 0 else if (__ep > @as(isize, @intCast(__s.len))) __s.len else @intCast(__ep); ");
            try w.print(arena, "break :{s} std.mem.endsWith(u8, __s[0..__end], __needle); }})", .{lbl});
        } else {
            try w.print(arena, "; break :{s} std.mem.endsWith(u8, __s, __needle); }})", .{lbl});
        }
        return;
    }

    if (eq(u8, name, "slice") or eq(u8, name, "substring")) {
        const is_sub = eq(u8, name, "substring");
        try w.appendSlice(arena, "const __len: isize = @intCast(__s.len); ");
        try A.idx("__a", mc.args[0], w, arena);
        if (mc.args.len == 2) {
            try A.idx("__b", mc.args[1], w, arena);
        } else {
            try w.appendSlice(arena, "const __b: isize = __len; ");
        }
        // Clamp both endpoints into [0, len].
        try w.appendSlice(arena, "const __c0: isize = if (__a < 0) 0 else if (__a > __len) __len else __a; ");
        try w.appendSlice(arena, "const __c1: isize = if (__b < 0) 0 else if (__b > __len) __len else __b; ");
        if (is_sub) {
            // substring swaps so the smaller endpoint is the start.
            try w.appendSlice(arena, "const __lo: isize = if (__c0 < __c1) __c0 else __c1; const __hi: isize = if (__c0 < __c1) __c1 else __c0; ");
        } else {
            // slice yields empty when start > end.
            try w.appendSlice(arena, "const __lo: isize = __c0; const __hi: isize = if (__c1 < __c0) __c0 else __c1; ");
        }
        try w.print(arena, "break :{s} @as([]const u8, __s[@intCast(__lo)..@intCast(__hi)]); }})", .{lbl});
        return;
    }

    if (eq(u8, name, "toUpperCase")) {
        try w.print(arena, "const __r = __sa().alloc(u8, __s.len) catch unreachable; for (__s, 0..) |__c, __i| {{ __r[__i] = std.ascii.toUpper(__c); }} break :{s} @as([]const u8, __r); }})", .{lbl});
        return;
    }

    if (eq(u8, name, "toLowerCase")) {
        try w.print(arena, "const __r = __sa().alloc(u8, __s.len) catch unreachable; for (__s, 0..) |__c, __i| {{ __r[__i] = std.ascii.toLower(__c); }} break :{s} @as([]const u8, __r); }})", .{lbl});
        return;
    }

    if (eq(u8, name, "trim")) {
        try w.print(arena, "break :{s} @as([]const u8, std.mem.trim(u8, __s, \" \\t\\r\\n\")); }})", .{lbl});
        return;
    }

    if (eq(u8, name, "trimStart")) {
        try w.print(arena, "break :{s} @as([]const u8, std.mem.trimStart(u8, __s, \" \\t\\r\\n\")); }})", .{lbl});
        return;
    }

    if (eq(u8, name, "trimEnd")) {
        try w.print(arena, "break :{s} @as([]const u8, std.mem.trimEnd(u8, __s, \" \\t\\r\\n\")); }})", .{lbl});
        return;
    }

    if (eq(u8, name, "repeat")) {
        try A.idx("__n", mc.args[0], w, arena);
        try w.appendSlice(arena, "const __count: usize = if (__n < 0) 0 else @intCast(__n); ");
        try w.appendSlice(arena, "var __buf: std.ArrayListUnmanaged(u8) = .empty; var __k: usize = 0; while (__k < __count) : (__k += 1) { __buf.appendSlice(__sa(), __s) catch unreachable; } ");
        try w.print(arena, "break :{s} @as([]const u8, __buf.items); }})", .{lbl});
        return;
    }

    if (eq(u8, name, "padStart")) {
        try A.idx("__target", mc.args[0], w, arena);
        try w.appendSlice(arena, "const __pad: []const u8 = ");
        if (mc.args.len == 2) {
            try emitExpr(mc.args[1], w, arena);
        } else {
            try w.appendSlice(arena, "\" \"");
        }
        try w.appendSlice(arena, "; const __goal: usize = if (__target < 0) 0 else @intCast(__target); ");
        try w.appendSlice(arena, "var __buf: std.ArrayListUnmanaged(u8) = .empty; if (__goal > __s.len and __pad.len > 0) { var __need: usize = __goal - __s.len; while (__need > 0) { const __take = if (__need < __pad.len) __need else __pad.len; __buf.appendSlice(__sa(), __pad[0..__take]) catch unreachable; __need -= __take; } } ");
        try w.appendSlice(arena, "__buf.appendSlice(__sa(), __s) catch unreachable; ");
        try w.print(arena, "break :{s} @as([]const u8, __buf.items); }})", .{lbl});
        return;
    }

    if (eq(u8, name, "padEnd")) {
        try A.idx("__target", mc.args[0], w, arena);
        try w.appendSlice(arena, "const __pad: []const u8 = ");
        if (mc.args.len == 2) {
            try emitExpr(mc.args[1], w, arena);
        } else {
            try w.appendSlice(arena, "\" \"");
        }
        try w.appendSlice(arena, "; const __goal: usize = if (__target < 0) 0 else @intCast(__target); ");
        try w.appendSlice(arena, "var __buf: std.ArrayListUnmanaged(u8) = .empty; __buf.appendSlice(__sa(), __s) catch unreachable; ");
        try w.appendSlice(arena, "if (__goal > __s.len and __pad.len > 0) { var __need: usize = __goal - __s.len; while (__need > 0) { const __take = if (__need < __pad.len) __need else __pad.len; __buf.appendSlice(__sa(), __pad[0..__take]) catch unreachable; __need -= __take; } } ");
        try w.print(arena, "break :{s} @as([]const u8, __buf.items); }})", .{lbl});
        return;
    }

    if (eq(u8, name, "replace")) {
        try w.appendSlice(arena, "const __from: []const u8 = ");
        try emitExpr(mc.args[0], w, arena);
        try w.appendSlice(arena, "; const __to: []const u8 = ");
        try emitExpr(mc.args[1], w, arena);
        try w.appendSlice(arena, "; var __buf: std.ArrayListUnmanaged(u8) = .empty; if (__from.len > 0) { if (std.mem.indexOf(u8, __s, __from)) |__p| { __buf.appendSlice(__sa(), __s[0..__p]) catch unreachable; __buf.appendSlice(__sa(), __to) catch unreachable; __buf.appendSlice(__sa(), __s[__p + __from.len ..]) catch unreachable; } else { __buf.appendSlice(__sa(), __s) catch unreachable; } } else { __buf.appendSlice(__sa(), __s) catch unreachable; } ");
        try w.print(arena, "break :{s} @as([]const u8, __buf.items); }})", .{lbl});
        return;
    }

    if (eq(u8, name, "replaceAll")) {
        try w.appendSlice(arena, "const __from: []const u8 = ");
        try emitExpr(mc.args[0], w, arena);
        try w.appendSlice(arena, "; const __to: []const u8 = ");
        try emitExpr(mc.args[1], w, arena);
        try w.appendSlice(arena, "; var __buf: std.ArrayListUnmanaged(u8) = .empty; if (__from.len > 0) { var __rest: []const u8 = __s; while (std.mem.indexOf(u8, __rest, __from)) |__p| { __buf.appendSlice(__sa(), __rest[0..__p]) catch unreachable; __buf.appendSlice(__sa(), __to) catch unreachable; __rest = __rest[__p + __from.len ..]; } __buf.appendSlice(__sa(), __rest) catch unreachable; } else { __buf.appendSlice(__sa(), __s) catch unreachable; } ");
        try w.print(arena, "break :{s} @as([]const u8, __buf.items); }})", .{lbl});
        return;
    }

    if (eq(u8, name, "split")) {
        try w.appendSlice(arena, "const __sep: []const u8 = ");
        try emitExpr(mc.args[0], w, arena);
        try w.appendSlice(arena, "; var __parts: std.ArrayListUnmanaged([]const u8) = .empty; ");
        try w.appendSlice(arena, "if (__sep.len == 0) { for (__s) |*__cp| __parts.append(__sa(), __cp[0..1]) catch unreachable; } ");
        try w.appendSlice(arena, "else { var __it = std.mem.splitSequence(u8, __s, __sep); while (__it.next()) |__seg| __parts.append(__sa(), __seg) catch unreachable; } ");
        if (mc.args.len == 2) {
            try w.appendSlice(arena, "const __lim: isize = @intCast(");
            try emitExpr(mc.args[1], w, arena);
            try w.appendSlice(arena, "); const __cap: usize = if (__lim < 0) __parts.items.len else @intCast(__lim); const __n: usize = if (__cap < __parts.items.len) __cap else __parts.items.len; ");
            try w.print(arena, "break :{s} @as([]const []const u8, __parts.items[0..__n]); }})", .{lbl});
        } else {
            try w.print(arena, "break :{s} @as([]const []const u8, __parts.items); }})", .{lbl});
        }
        return;
    }

    return error.ParseError;
}

/// Escapes template literal text for embedding inside a Zig `std.fmt` format
/// string literal: quotes/backslashes escaped, braces doubled, control chars
/// turned into escape sequences.
pub fn emitTemplateText(text: []const u8, w: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    for (text) |ch| {
        switch (ch) {
            '"' => try w.appendSlice(arena, "\\\""),
            '\\' => try w.appendSlice(arena, "\\\\"),
            '{' => try w.appendSlice(arena, "{{"),
            '}' => try w.appendSlice(arena, "}}"),
            '\n' => try w.appendSlice(arena, "\\n"),
            '\r' => try w.appendSlice(arena, "\\r"),
            '\t' => try w.appendSlice(arena, "\\t"),
            else => try w.append(arena, ch),
        }
    }
}
