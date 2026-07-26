//! Codegen for `.static_call` expressions -- `Math.*`, `String.*`,
//! `Array.*`, `fs.*`, `JSON.*`, `Promise.*`, `Worker.*`, and every other
//! `namespace.fn(...)` builtin. Extracted verbatim from `lumen_emit.zig`'s
//! `emitExpr` switch purely by size; behavior is unchanged.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const types = @import("lumen_types.zig");
const em = @import("lumen_emit.zig");
const CompileError = @import("lumen_diag.zig").CompileError;

pub fn emitStaticCall(cl: anytype, w: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    const checked_type = cl.checked_type orelse return error.ParseError;
    if (std.mem.eql(u8, cl.namespace, "Math") and std.mem.eql(u8, cl.name, "abs")) {
        if (checked_type == .f64) {
            // A "whole" float literal like 4.0 emits as the bare
            // numeral `4`, which @abs doesn't comptime_int-coerce
            // on its own -- @as forces the float type.
            try w.appendSlice(arena, "@abs(@as(f64, ");
            try em.emitExpr(cl.args[0], w, arena);
            try w.appendSlice(arena, "))");
        } else {
            try w.print(arena, "@as({s}, @intCast(@abs(", .{try types.zigName(arena, checked_type)});
            try em.emitExpr(cl.args[0], w, arena);
            try w.appendSlice(arena, ")))");
        }
    } else if (std.mem.eql(u8, cl.namespace, "Math") and std.mem.eql(u8, cl.name, "sign")) {
        try w.appendSlice(arena, "@as(i32, if (");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, " < 0) -1 else if (");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, " > 0) 1 else 0)");
    } else if (std.mem.eql(u8, cl.namespace, "Math") and std.mem.eql(u8, cl.name, "sqrt")) {
        const arg_type = cl.checked_arg_type orelse return error.ParseError;
        try w.appendSlice(arena, "@sqrt(");
        if (arg_type == .f64) {
            // A "whole" float literal like 1.0 emits as the bare
            // numeral `1`, which Zig's own math builtins (unlike a
            // normal f64-typed function parameter) don't
            // comptime_int-coerce on their own -- @as forces it.
            try w.appendSlice(arena, "@as(f64, ");
            try em.emitExpr(cl.args[0], w, arena);
            try w.append(arena, ')');
        } else {
            try w.appendSlice(arena, "@as(f64, @floatFromInt(");
            try em.emitExpr(cl.args[0], w, arena);
            try w.appendSlice(arena, "))");
        }
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "Math") and std.mem.eql(u8, cl.name, "random")) {
        // A pseudo-random f64 in [0, 1) from a lazily-seeded global PRNG.
        try w.appendSlice(arena, "__mathRandom()");
    } else if (std.mem.eql(u8, cl.namespace, "Math") and std.mem.eql(u8, cl.name, "fround")) {
        const arg_type = cl.checked_arg_type orelse return error.ParseError;
        try w.appendSlice(arena, "@as(f64, @as(f32, @floatCast(");
        if (arg_type == .f64) {
            try w.appendSlice(arena, "@as(f64, ");
            try em.emitExpr(cl.args[0], w, arena);
            try w.append(arena, ')');
        } else {
            try w.appendSlice(arena, "@as(f64, @floatFromInt(");
            try em.emitExpr(cl.args[0], w, arena);
            try w.appendSlice(arena, "))");
        }
        try w.appendSlice(arena, ")))");
    } else if (std.mem.eql(u8, cl.namespace, "Math") and std.mem.eql(u8, cl.name, "clz32")) {
        try w.appendSlice(arena, "@as(i32, @clz(@as(u32, @bitCast(@as(i32, @truncate(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, "))))))");
    } else if (std.mem.eql(u8, cl.namespace, "Math") and std.mem.eql(u8, cl.name, "imul")) {
        // 32-bit wrapping multiply; truncate each operand to i32 first.
        try w.appendSlice(arena, "(@as(i32, @truncate(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ")) *% @as(i32, @truncate(");
        try em.emitExpr(cl.args[1], w, arena);
        try w.appendSlice(arena, ")))");
    } else if (std.mem.eql(u8, cl.namespace, "Math") and (std.mem.eql(u8, cl.name, "max") or std.mem.eql(u8, cl.name, "min")) and cl.args.len == 1 and cl.args[0].* == .spread) {
        // `Math.min(...arr)` -> a runtime fold over the array.
        const ts = em.TempScope.open(w, arena);
        defer ts.close();
        const s = ts.seq;
        try w.print(arena, "(__mm{d}: {{ const __arr = ", .{s});
        try em.emitExpr(cl.args[0].spread, w, arena);
        try w.print(arena, "; var __r = __arr[0]; for (__arr[1..]) |__e| {{ __r = @{s}(__r, __e); }} break :__mm{d} __r; }})", .{ cl.name, s });
    } else if (std.mem.eql(u8, cl.namespace, "Math") and (std.mem.eql(u8, cl.name, "max") or std.mem.eql(u8, cl.name, "min"))) {
        // Left-fold over all arguments: @max(@max(a, b), c) ...
        for (0..cl.args.len - 1) |_| try w.print(arena, "@{s}(", .{cl.name});
        try em.emitExpr(cl.args[0], w, arena);
        for (cl.args[1..]) |arg| {
            try w.appendSlice(arena, ", ");
            try em.emitExpr(arg, w, arena);
            try w.append(arena, ')');
        }
    } else if (std.mem.eql(u8, cl.namespace, "Math") and std.mem.eql(u8, cl.name, "clamp")) {
        try w.appendSlice(arena, "@min(@max(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.appendSlice(arena, "), ");
        try em.emitExpr(cl.args[2], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "Math") and (std.mem.eql(u8, cl.name, "floor") or std.mem.eql(u8, cl.name, "ceil") or std.mem.eql(u8, cl.name, "round") or std.mem.eql(u8, cl.name, "trunc"))) {
        const arg_type = cl.checked_arg_type orelse return error.ParseError;
        // JS Math.round rounds a half toward +Infinity (floor(x + 0.5)),
        // not away from zero like Zig's @round; the others map directly.
        const is_round = std.mem.eql(u8, cl.name, "round");
        if (is_round) {
            try w.appendSlice(arena, "@as(i32, @intFromFloat(@floor(");
        } else {
            try w.print(arena, "@as(i32, @intFromFloat(@{s}(", .{cl.name});
        }
        if (arg_type == .f64) {
            // See the sqrt branch above: a "whole" float literal
            // like 4.0 emits as the bare numeral `4`, which these
            // builtins don't comptime_int-coerce on their own.
            try w.appendSlice(arena, "@as(f64, ");
            try em.emitExpr(cl.args[0], w, arena);
            try w.append(arena, ')');
        } else {
            try w.appendSlice(arena, "@as(f64, @floatFromInt(");
            try em.emitExpr(cl.args[0], w, arena);
            try w.appendSlice(arena, "))");
        }
        if (is_round) try w.appendSlice(arena, " + 0.5");
        try w.appendSlice(arena, ")))");
    } else if (std.mem.eql(u8, cl.namespace, "Math") and std.mem.eql(u8, cl.name, "pow")) {
        const arg_type = cl.checked_arg_type orelse return error.ParseError;
        try w.appendSlice(arena, "std.math.pow(f64, ");
        if (arg_type == .f64) {
            try em.emitExpr(cl.args[0], w, arena);
            try w.appendSlice(arena, ", ");
            try em.emitExpr(cl.args[1], w, arena);
        } else {
            try w.appendSlice(arena, "@as(f64, @floatFromInt(");
            try em.emitExpr(cl.args[0], w, arena);
            try w.appendSlice(arena, ")), @as(f64, @floatFromInt(");
            try em.emitExpr(cl.args[1], w, arena);
            try w.appendSlice(arena, "))");
        }
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "Math") and (std.mem.eql(u8, cl.name, "log") or std.mem.eql(u8, cl.name, "sin") or std.mem.eql(u8, cl.name, "cos") or std.mem.eql(u8, cl.name, "tan") or std.mem.eql(u8, cl.name, "exp") or std.mem.eql(u8, cl.name, "exp2") or std.mem.eql(u8, cl.name, "log2") or std.mem.eql(u8, cl.name, "log10"))) {
        const arg_type = cl.checked_arg_type orelse return error.ParseError;
        try w.print(arena, "@{s}(", .{cl.name});
        if (arg_type == .f64) {
            try w.appendSlice(arena, "@as(f64, ");
            try em.emitExpr(cl.args[0], w, arena);
            try w.append(arena, ')');
        } else {
            try w.appendSlice(arena, "@as(f64, @floatFromInt(");
            try em.emitExpr(cl.args[0], w, arena);
            try w.appendSlice(arena, "))");
        }
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "Math") and (std.mem.eql(u8, cl.name, "asin") or std.mem.eql(u8, cl.name, "acos") or std.mem.eql(u8, cl.name, "atan") or std.mem.eql(u8, cl.name, "cbrt") or std.mem.eql(u8, cl.name, "sinh") or std.mem.eql(u8, cl.name, "cosh") or std.mem.eql(u8, cl.name, "tanh") or std.mem.eql(u8, cl.name, "asinh") or std.mem.eql(u8, cl.name, "acosh") or std.mem.eql(u8, cl.name, "atanh") or std.mem.eql(u8, cl.name, "expm1") or std.mem.eql(u8, cl.name, "log1p"))) {
        const arg_type = cl.checked_arg_type orelse return error.ParseError;
        try w.print(arena, "std.math.{s}(", .{cl.name});
        if (arg_type == .f64) {
            try w.appendSlice(arena, "@as(f64, ");
            try em.emitExpr(cl.args[0], w, arena);
            try w.append(arena, ')');
        } else {
            try w.appendSlice(arena, "@as(f64, @floatFromInt(");
            try em.emitExpr(cl.args[0], w, arena);
            try w.appendSlice(arena, "))");
        }
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "Math") and (std.mem.eql(u8, cl.name, "atan2") or std.mem.eql(u8, cl.name, "hypot"))) {
        const arg_type = cl.checked_arg_type orelse return error.ParseError;
        const F = struct {
            fn emit(ex: anytype, aty: anytype, ww: *std.ArrayListUnmanaged(u8), ar: std.mem.Allocator) CompileError!void {
                if (aty == .f64) {
                    try ww.appendSlice(ar, "@as(f64, ");
                    try em.emitExpr(ex, ww, ar);
                    try ww.append(ar, ')');
                } else {
                    try ww.appendSlice(ar, "@as(f64, @floatFromInt(");
                    try em.emitExpr(ex, ww, ar);
                    try ww.appendSlice(ar, "))");
                }
            }
        };
        if (std.mem.eql(u8, cl.name, "hypot")) {
            // Left fold: hypot(hypot(a, b), c) ... preserves overflow-safety.
            for (0..cl.args.len - 1) |_| try w.appendSlice(arena, "std.math.hypot(");
            try F.emit(cl.args[0], arg_type, w, arena);
            for (cl.args[1..]) |arg| {
                try w.appendSlice(arena, ", ");
                try F.emit(arg, arg_type, w, arena);
                try w.append(arena, ')');
            }
        } else {
            try w.appendSlice(arena, "std.math.atan2(");
            try F.emit(cl.args[0], arg_type, w, arena);
            try w.appendSlice(arena, ", ");
            try F.emit(cl.args[1], arg_type, w, arena);
            try w.append(arena, ')');
        }
    } else if (std.mem.eql(u8, cl.namespace, "Math") and std.mem.eql(u8, cl.name, "PI")) {
        try w.appendSlice(arena, "@as(f64, std.math.pi)");
    } else if (std.mem.eql(u8, cl.namespace, "Math") and std.mem.eql(u8, cl.name, "E")) {
        try w.appendSlice(arena, "@as(f64, std.math.e)");
    } else if (std.mem.eql(u8, cl.namespace, "Math") and std.mem.eql(u8, cl.name, "LN2")) {
        try w.appendSlice(arena, "@as(f64, std.math.ln2)");
    } else if (std.mem.eql(u8, cl.namespace, "Math") and std.mem.eql(u8, cl.name, "LN10")) {
        try w.appendSlice(arena, "@as(f64, std.math.ln10)");
    } else if (std.mem.eql(u8, cl.namespace, "Math") and std.mem.eql(u8, cl.name, "LOG2E")) {
        try w.appendSlice(arena, "@as(f64, std.math.log2e)");
    } else if (std.mem.eql(u8, cl.namespace, "Math") and std.mem.eql(u8, cl.name, "LOG10E")) {
        try w.appendSlice(arena, "@as(f64, std.math.log10e)");
    } else if (std.mem.eql(u8, cl.namespace, "Math") and std.mem.eql(u8, cl.name, "SQRT2")) {
        try w.appendSlice(arena, "@as(f64, std.math.sqrt2)");
    } else if (std.mem.eql(u8, cl.namespace, "Math") and std.mem.eql(u8, cl.name, "SQRT1_2")) {
        try w.appendSlice(arena, "@as(f64, std.math.sqrt1_2)");
    } else if (std.mem.eql(u8, cl.namespace, "String") and std.mem.eql(u8, cl.name, "isEmpty")) {
        try w.append(arena, '(');
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ".len == 0)");
    } else if (std.mem.eql(u8, cl.namespace, "String") and std.mem.eql(u8, cl.name, "contains")) {
        try w.appendSlice(arena, "(std.mem.indexOf(u8, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.appendSlice(arena, ") != null)");
    } else if (std.mem.eql(u8, cl.namespace, "String") and std.mem.eql(u8, cl.name, "startsWith")) {
        try w.appendSlice(arena, "std.mem.startsWith(u8, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "Number") and std.mem.eql(u8, cl.name, "parseInt")) {
        // Number.parseInt is identical to the global parseInt.
        try w.appendSlice(arena, "__parseInt(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        if (cl.args.len == 2) {
            try w.appendSlice(arena, "@intCast(");
            try em.emitExpr(cl.args[1], w, arena);
            try w.appendSlice(arena, ")");
        } else {
            try w.appendSlice(arena, "0");
        }
        try w.appendSlice(arena, ")");
    } else if (std.mem.eql(u8, cl.namespace, "Number") and std.mem.eql(u8, cl.name, "parseFloat")) {
        try w.appendSlice(arena, "__parseFloat(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ")");
    } else if (std.mem.eql(u8, cl.namespace, "Number") and (std.mem.eql(u8, cl.name, "isInteger") or std.mem.eql(u8, cl.name, "isFinite") or std.mem.eql(u8, cl.name, "isNaN") or std.mem.eql(u8, cl.name, "isSafeInteger"))) {
        // Evaluate the argument as f64 (so the check works uniformly for
        // int and float inputs, and side effects still run).
        const arg_type = cl.checked_arg_type orelse return error.ParseError;
        const F = struct {
            fn emit(ex: anytype, aty: anytype, ww: *std.ArrayListUnmanaged(u8), ar: std.mem.Allocator) CompileError!void {
                if (aty == .f64) {
                    try ww.appendSlice(ar, "@as(f64, ");
                    try em.emitExpr(ex, ww, ar);
                    try ww.append(ar, ')');
                } else {
                    try ww.appendSlice(ar, "@as(f64, @floatFromInt(");
                    try em.emitExpr(ex, ww, ar);
                    try ww.appendSlice(ar, "))");
                }
            }
        };
        if (std.mem.eql(u8, cl.name, "isNaN")) {
            try w.appendSlice(arena, "std.math.isNan(");
            try F.emit(cl.args[0], arg_type, w, arena);
            try w.append(arena, ')');
        } else if (std.mem.eql(u8, cl.name, "isFinite")) {
            try w.appendSlice(arena, "std.math.isFinite(");
            try F.emit(cl.args[0], arg_type, w, arena);
            try w.append(arena, ')');
        } else if (std.mem.eql(u8, cl.name, "isSafeInteger")) {
            try w.appendSlice(arena, "(blk_si: { const __v: f64 = ");
            try F.emit(cl.args[0], arg_type, w, arena);
            try w.appendSlice(arena, "; break :blk_si (std.math.isFinite(__v) and @floor(__v) == __v and @abs(__v) <= 9007199254740991.0); })");
        } else { // isInteger
            try w.appendSlice(arena, "(blk_ni: { const __v: f64 = ");
            try F.emit(cl.args[0], arg_type, w, arena);
            try w.appendSlice(arena, "; break :blk_ni (std.math.isFinite(__v) and @floor(__v) == __v); })");
        }
    } else if (std.mem.eql(u8, cl.namespace, "Number") and std.mem.eql(u8, cl.name, "EPSILON")) {
        try w.appendSlice(arena, "@as(f64, std.math.floatEps(f64))");
    } else if (std.mem.eql(u8, cl.namespace, "Number") and std.mem.eql(u8, cl.name, "MAX_VALUE")) {
        try w.appendSlice(arena, "@as(f64, std.math.floatMax(f64))");
    } else if (std.mem.eql(u8, cl.namespace, "Number") and std.mem.eql(u8, cl.name, "MIN_VALUE")) {
        try w.appendSlice(arena, "@as(f64, std.math.floatTrueMin(f64))");
    } else if (std.mem.eql(u8, cl.namespace, "Number") and std.mem.eql(u8, cl.name, "POSITIVE_INFINITY")) {
        try w.appendSlice(arena, "@as(f64, std.math.inf(f64))");
    } else if (std.mem.eql(u8, cl.namespace, "Number") and std.mem.eql(u8, cl.name, "NEGATIVE_INFINITY")) {
        try w.appendSlice(arena, "@as(f64, -std.math.inf(f64))");
    } else if (std.mem.eql(u8, cl.namespace, "Number") and std.mem.eql(u8, cl.name, "MAX_SAFE_INTEGER")) {
        try w.appendSlice(arena, "@as(f64, 9007199254740991.0)");
    } else if (std.mem.eql(u8, cl.namespace, "Number") and std.mem.eql(u8, cl.name, "MIN_SAFE_INTEGER")) {
        try w.appendSlice(arena, "@as(f64, -9007199254740991.0)");
    } else if (std.mem.eql(u8, cl.namespace, "Number") and std.mem.eql(u8, cl.name, "NaN")) {
        try w.appendSlice(arena, "@as(f64, std.math.nan(f64))");
    } else if (std.mem.eql(u8, cl.namespace, "String") and std.mem.eql(u8, cl.name, "compare")) {
        try w.appendSlice(arena, "@as(i32, switch (std.mem.order(u8, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.appendSlice(arena, ")) { .lt => -1, .eq => 0, .gt => 1 })");
    } else if (std.mem.eql(u8, cl.namespace, "String") and std.mem.eql(u8, cl.name, "fromCodePoint")) {
        // A code point is a character, so each argument is encoded as UTF-8 —
        // one to four bytes (spec 472). `fromCharCode` below is the byte-at-a-
        // time form and stays that way; that the two differ is why there are
        // two names.
        //
        // What is not a code point — a surrogate half, a negative, anything
        // past 0x10FFFF — becomes U+FFFD rather than raising: these values
        // arrive from documents being read, and a malformed escape should mark
        // itself in the text rather than stop the program.
        const ts = em.TempScope.open(w, arena);
        defer ts.close();
        const fcp_lbl = try std.fmt.allocPrint(arena, "__fcp{d}", .{ts.seq});
        try w.print(arena, "({s}: {{ var __b: std.ArrayListUnmanaged(u8) = .empty; ", .{fcp_lbl});
        for (cl.args) |arg| {
            try w.appendSlice(arena, "{ const __cp: i64 = @intCast(");
            try em.emitExpr(arg, w, arena);
            try w.appendSlice(arena,
                "); var __u: [4]u8 = undefined; var __n: usize = 0; " ++
                "if (__cp >= 0 and __cp <= 0x10FFFF and (__cp < 0xD800 or __cp > 0xDFFF)) " ++
                "{ __n = @intCast(std.unicode.utf8Encode(@intCast(__cp), &__u) catch 0); } " ++
                "if (__n == 0) { __b.appendSlice(__sa(), \"\\u{FFFD}\") catch unreachable; } " ++
                "else { __b.appendSlice(__sa(), __u[0..__n]) catch unreachable; } } ");
        }
        try w.print(arena, "break :{s} @as([]const u8, __b.items); }})", .{fcp_lbl});
    } else if (std.mem.eql(u8, cl.namespace, "String") and std.mem.eql(u8, cl.name, "fromCharCode")) {
        const ts = em.TempScope.open(w, arena);
        defer ts.close();
        const fcc_lbl = try std.fmt.allocPrint(arena, "__fcc{d}", .{ts.seq});
        try w.print(arena, "({s}: {{ const __b = __sa().alloc(u8, {d}) catch unreachable; ", .{ fcc_lbl, cl.args.len });
        for (cl.args, 0..) |arg, i| {
            try w.print(arena, "__b[{d}] = @intCast((", .{i});
            try em.emitExpr(arg, w, arena);
            try w.appendSlice(arena, ") & 0xFF); ");
        }
        try w.print(arena, "break :{s} @as([]const u8, __b); }})", .{fcc_lbl});
    } else if (std.mem.eql(u8, cl.namespace, "Array") and std.mem.eql(u8, cl.name, "from") and cl.from_length != null) {
        // Array.from({length: N}, cb): allocate N slots and fill each from the
        // callback, passing a placeholder value (0) and the index.
        const rt = cl.checked_type orelse return error.ParseError;
        const rz = try types.zigName(arena, types.arrayElem(rt) orelse return error.ParseError);
        const idx_arg = if (cl.cb_wants_index) ", @as(i32, @intCast(__i))" else "";
        const ts = em.TempScope.open(w, arena);
        defer ts.close();
        const s = ts.seq;
        try w.print(arena, "(__afl{d}: {{ const __n: usize = @intCast(", .{s});
        try em.emitExpr(cl.from_length.?, w, arena);
        try w.appendSlice(arena, "); const __cb = ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.print(arena, "; const __r = __sa().alloc({s}, __n) catch unreachable; for (0..__n) |__i| {{ __r[__i] = __cb.call(__cb.ctx, @as(i32, 0){s}); }} break :__afl{d} @as([]const {s}, __r); }})", .{ rz, idx_arg, s, rz });
    } else if (std.mem.eql(u8, cl.namespace, "Array") and std.mem.eql(u8, cl.name, "from") and cl.args.len == 2) {
        // Array.from(src, cb): build the source slice, then map each
        // element through the closure into the result array.
        const src = cl.checked_arg_type orelse return error.ParseError;
        const rt = cl.checked_type orelse return error.ParseError;
        const rz = try types.zigName(arena, types.arrayElem(rt) orelse return error.ParseError);
        const idx_arg = if (cl.cb_wants_index) ", @as(i32, @intCast(__i))" else "";
        const ts = em.TempScope.open(w, arena);
        defer ts.close();
        const s = ts.seq;
        try w.print(arena, "(__afm{d}: {{ const __src: ", .{s});
        if (types.isStringLike(src)) {
            // Source elements are single-character strings.
            try w.appendSlice(arena, "[]const []const u8 = __blk: { const __s0 = ");
            try em.emitExpr(cl.args[0], w, arena);
            try w.appendSlice(arena, "; var __p: std.ArrayListUnmanaged([]const u8) = .empty; for (__s0) |*__cp| __p.append(__sa(), __cp[0..1]) catch unreachable; break :__blk __p.items; }");
        } else if (src == .set_type) {
            const ez = try types.zigName(arena, src.set_type.*);
            try w.print(arena, "[]const {s} = (", .{ez});
            try em.emitExpr(cl.args[0], w, arena);
            try w.appendSlice(arena, ").values()");
        } else {
            const ez = try types.zigName(arena, types.arrayElem(src) orelse return error.ParseError);
            try w.print(arena, "[]const {s} = ", .{ez});
            try em.emitExpr(cl.args[0], w, arena);
        }
        try w.appendSlice(arena, "; const __cb = ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.print(arena, "; const __r = __sa().alloc({s}, __src.len) catch unreachable; for (__src, 0..) |__e, __i| {{ __r[__i] = __cb.call(__cb.ctx, __e{s}); }} break :__afm{d} @as([]const {s}, __r); }})", .{ rz, idx_arg, s, rz });
    } else if (std.mem.eql(u8, cl.namespace, "Array") and std.mem.eql(u8, cl.name, "from")) {
        const src = cl.checked_arg_type orelse return error.ParseError;
        const ts = em.TempScope.open(w, arena);
        defer ts.close();
        const s = ts.seq;
        if (types.isStringLike(src)) {
            // String -> array of single-character strings.
            try w.print(arena, "(__afr{d}: {{ const __s = ", .{s});
            try em.emitExpr(cl.args[0], w, arena);
            try w.print(arena, "; var __parts: std.ArrayListUnmanaged([]const u8) = .empty; for (__s) |*__cp| __parts.append(__sa(), __cp[0..1]) catch unreachable; break :__afr{d} @as([]const []const u8, __parts.items); }})", .{s});
        } else if (src == .set_type) {
            // Set -> array of its elements (a copy of the values slice).
            const ez = try types.zigName(arena, src.set_type.*);
            try w.print(arena, "(__afr{d}: {{ const __a = (", .{s});
            try em.emitExpr(cl.args[0], w, arena);
            try w.print(arena, ").values(); const __r = __sa().alloc({s}, __a.len) catch unreachable; @memcpy(__r, __a); break :__afr{d} @as([]const {s}, __r); }})", .{ ez, s, ez });
        } else {
            // Array -> shallow copy.
            const ez = try types.zigName(arena, types.arrayElem(src) orelse return error.ParseError);
            try w.print(arena, "(__afr{d}: {{ const __a = ", .{s});
            try em.emitExpr(cl.args[0], w, arena);
            try w.print(arena, "; const __r = __sa().alloc({s}, __a.len) catch unreachable; @memcpy(__r, __a); break :__afr{d} @as([]const {s}, __r); }})", .{ ez, s, ez });
        }
    } else if (std.mem.eql(u8, cl.namespace, "Array") and std.mem.eql(u8, cl.name, "of")) {
        // Heap-allocate an array from the arguments (avoids returning a
        // pointer to an anonymous tuple literal).
        const et = cl.checked_arg_type orelse return error.ParseError;
        const ez = try types.zigName(arena, et);
        const ts = em.TempScope.open(w, arena);
        defer ts.close();
        const s = ts.seq;
        try w.print(arena, "(__aof{d}: {{ const __r = __sa().alloc({s}, {d}) catch unreachable; ", .{ s, ez, cl.args.len });
        for (cl.args, 0..) |arg, i| {
            try w.print(arena, "__r[{d}] = ", .{i});
            try em.emitExpr(arg, w, arena);
            try w.appendSlice(arena, "; ");
        }
        try w.print(arena, "break :__aof{d} @as([]const {s}, __r); }})", .{ s, ez });
    } else if (std.mem.eql(u8, cl.namespace, "Array") and std.mem.eql(u8, cl.name, "isEmpty")) {
        try w.append(arena, '(');
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ".len == 0)");
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "readFileSync")) {
        if (em.g_options.?.runtime_locations) {
            try em.emitThrowingCallPrefix(w, arena);
            try w.appendSlice(arena, "__readFileSync(__io, __alloc, ");
            try em.emitExpr(cl.args[0], w, arena);
            try w.append(arena, ')');
            try em.emitThrowingCallSuffix(w, arena);
            return;
        }
        try w.appendSlice(arena, "__readFileSync(__io, __alloc, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "readFile")) {
        try w.appendSlice(arena, "__readFileAsync(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "writeFile")) {
        try w.appendSlice(arena, "__writeFileAsync(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "appendFile")) {
        try w.appendSlice(arena, "__appendFileAsync(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "unlink")) {
        try w.appendSlice(arena, "__unlinkAsync(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "mkdir")) {
        try w.appendSlice(arena, "__mkdirAsync(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "rmdir")) {
        try w.appendSlice(arena, "__rmdirAsync(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "stat")) {
        try w.appendSlice(arena, "__statAsync(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "existsSync")) {
        try w.appendSlice(arena, "__existsSync(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "realpathSync")) {
        try w.appendSlice(arena, "__realpathSync(__io, __alloc, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "writeFileSync")) {
        const write_throws = em.g_options.?.runtime_locations;
        if (write_throws) try em.emitThrowingCallPrefix(w, arena);
        try w.appendSlice(arena, "__writeFileSync(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
        if (write_throws) try em.emitThrowingCallSuffix(w, arena);
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "appendFileSync")) {
        try w.appendSlice(arena, "__appendFileSync(__io, __alloc, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "mkdirSync")) {
        try w.appendSlice(arena, "__mkdirSync(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        if (cl.args.len == 2) try em.emitExpr(cl.args[1], w, arena) else try w.appendSlice(arena, "false");
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "unlinkSync")) {
        try w.appendSlice(arena, "__unlinkSync(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "renameSync")) {
        try w.appendSlice(arena, "__renameSync(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "copyFileSync")) {
        try w.appendSlice(arena, "__copyFileSync(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "cpSync")) {
        try w.appendSlice(arena, "__cpSync(__io, __alloc, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.appendSlice(arena, ", ");
        if (cl.args.len == 3) try em.emitExpr(cl.args[2], w, arena) else try w.appendSlice(arena, "false");
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "mkdtempSync")) {
        try w.appendSlice(arena, "__mkdtempSync(__io, __alloc, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "statSync")) {
        try w.appendSlice(arena, "__statSync(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "openSync")) {
        try w.appendSlice(arena, "__openSync(__io, __alloc, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "closeSync")) {
        try w.appendSlice(arena, "__closeSync(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "readSync")) {
        try w.appendSlice(arena, "__readSync(__io, __alloc, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "writeSync")) {
        try w.appendSlice(arena, "__writeSync(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "rmdirSync")) {
        try w.appendSlice(arena, "__rmdirSync(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "rmSync")) {
        try w.appendSlice(arena, "__rmSync(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        if (cl.args.len == 2) try em.emitExpr(cl.args[1], w, arena) else try w.appendSlice(arena, "false");
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "truncateSync")) {
        try w.appendSlice(arena, "__truncateSync(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "linkSync")) {
        try w.appendSlice(arena, "__linkSync(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "symlinkSync")) {
        try w.appendSlice(arena, "__symlinkSync(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "readlinkSync")) {
        try w.appendSlice(arena, "__readlinkSync(__io, __alloc, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "chmodSync")) {
        try w.appendSlice(arena, "__chmodSync(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "accessSync")) {
        try w.appendSlice(arena, "__accessSync(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        if (cl.args.len == 2) try em.emitExpr(cl.args[1], w, arena) else try w.appendSlice(arena, "0");
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "lstatSync")) {
        try w.appendSlice(arena, "__lstatSync(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "fstatSync")) {
        try w.appendSlice(arena, "__fstatSync(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "fchmodSync")) {
        try w.appendSlice(arena, "__fchmodSync(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "lchmodSync")) {
        try w.appendSlice(arena, "__lchmodSync(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "fchownSync")) {
        try w.appendSlice(arena, "__fchownSync(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[2], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "chownSync")) {
        try w.appendSlice(arena, "__chownSync(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[2], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "lchownSync")) {
        try w.appendSlice(arena, "__lchownSync(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[2], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "writevSync")) {
        try w.appendSlice(arena, "__writevSync(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "readvSync")) {
        try w.appendSlice(arena, "__readvSync(__alloc, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and (std.mem.eql(u8, cl.name, "fsyncSync") or std.mem.eql(u8, cl.name, "fdatasyncSync"))) {
        try w.appendSlice(arena, "__fsyncSync(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "ftruncateSync")) {
        try w.appendSlice(arena, "__ftruncateSync(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "futimesSync")) {
        try w.appendSlice(arena, "__futimesSync(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[2], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "utimesSync")) {
        try w.appendSlice(arena, "__utimesSync(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[2], w, arena);
        try w.appendSlice(arena, ", true)");
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "lutimesSync")) {
        try w.appendSlice(arena, "__utimesSync(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[2], w, arena);
        try w.appendSlice(arena, ", false)");
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "readdirSync")) {
        try w.appendSlice(arena, "__readdirSync(__io, __alloc, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "watch")) {
        try w.appendSlice(arena, "__fsWatch(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "createReadStream")) {
        try w.appendSlice(arena, "__fsCreateReadStream(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "createWriteStream")) {
        try w.appendSlice(arena, "__fsCreateWriteStream(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "Buffer") and std.mem.eql(u8, cl.name, "from") and cl.args.len == 1) {
        try w.appendSlice(arena, "__bufferFromUtf8(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "Buffer") and std.mem.eql(u8, cl.name, "from") and cl.args.len == 2) {
        try w.appendSlice(arena, "__bufferFromEncoded(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "Buffer") and std.mem.eql(u8, cl.name, "alloc")) {
        try w.appendSlice(arena, "__bufferAlloc(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "path") and std.mem.eql(u8, cl.name, "basename")) {
        try w.appendSlice(arena, "__pathBasename(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        if (cl.args.len == 2) try em.emitExpr(cl.args[1], w, arena) else try w.appendSlice(arena, "\"\"");
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "path") and std.mem.eql(u8, cl.name, "dirname")) {
        try w.appendSlice(arena, "__pathDirname(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "path") and std.mem.eql(u8, cl.name, "extname")) {
        try w.appendSlice(arena, "std.fs.path.extension(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "path") and std.mem.eql(u8, cl.name, "isAbsolute")) {
        try w.appendSlice(arena, "std.fs.path.isAbsolute(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "path") and std.mem.eql(u8, cl.name, "normalize")) {
        try w.appendSlice(arena, "__pathResolve(__alloc, &.{");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, "})");
    } else if (std.mem.eql(u8, cl.namespace, "path") and std.mem.eql(u8, cl.name, "join")) {
        try w.appendSlice(arena, "__pathJoin(__alloc, &.{ ");
        for (cl.args, 0..) |a, i| {
            if (i > 0) try w.appendSlice(arena, ", ");
            try em.emitExpr(a, w, arena);
        }
        try w.appendSlice(arena, " })");
    } else if (std.mem.eql(u8, cl.namespace, "path") and std.mem.eql(u8, cl.name, "resolve")) {
        try w.appendSlice(arena, "__pathResolve(__io, __alloc, &.{ ");
        for (cl.args, 0..) |a, i| {
            if (i > 0) try w.appendSlice(arena, ", ");
            try em.emitExpr(a, w, arena);
        }
        try w.appendSlice(arena, " })");
    } else if (std.mem.eql(u8, cl.namespace, "path") and std.mem.eql(u8, cl.name, "parse")) {
        try w.appendSlice(arena, "__pathParse(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "path") and std.mem.eql(u8, cl.name, "format")) {
        try w.appendSlice(arena, "__pathFormat(__alloc, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "url") and std.mem.eql(u8, cl.name, "parse")) {
        try w.appendSlice(arena, "__urlParse(__alloc, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "url") and std.mem.eql(u8, cl.name, "format")) {
        try w.appendSlice(arena, "__urlFormat(__alloc, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "child_process") and std.mem.eql(u8, cl.name, "spawnSync")) {
        try w.appendSlice(arena, "__spawnSync(__io, __alloc, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "child_process") and std.mem.eql(u8, cl.name, "spawn")) {
        try w.appendSlice(arena, "__spawn(__io, __alloc, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "assert") and std.mem.eql(u8, cl.name, "ok")) {
        try w.appendSlice(arena, "__assertOk(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "assert") and std.mem.eql(u8, cl.name, "equal")) {
        try w.appendSlice(arena, "__assertEqual(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "assert") and std.mem.eql(u8, cl.name, "__assertStrEqual")) {
        try w.appendSlice(arena, "__assertStrEqual(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "Array") and std.mem.eql(u8, cl.name, "isArray")) {
        // Compile-time verdict; evaluate (and discard) the argument.
        const ts = em.TempScope.open(w, arena);
        defer ts.close();
        const seq = ts.seq;
        try w.print(arena, "(__ia{d}: {{ _ = &(", .{seq});
        try em.emitExpr(cl.args[0], w, arena);
        try w.print(arena, "); break :__ia{d} {s}; }})", .{ seq, if ((cl.checked_arg_type orelse .void) == .bool) "true" else "false" });
    } else if (std.mem.eql(u8, cl.namespace, "Object") and cl.object_entries) {
        // Object.entries(record): [key, value] tuples. Bind the receiver once,
        // then build an array of positional tuple structs.
        const ts = em.TempScope.open(w, arena);
        defer ts.close();
        const seq = ts.seq;
        const tup_zig = try types.zigName(arena, types.arrayElem(cl.checked_type.?).?);
        try w.print(arena, "(__oe{d}: {{ const __rec = ", .{seq});
        try em.emitExpr(cl.args[0], w, arena);
        try w.print(arena, "; break :__oe{d} @as([]const {s}, &.{{ ", .{ seq, tup_zig });
        for (cl.object_keys orelse &.{}, 0..) |k, i| {
            if (i > 0) try w.appendSlice(arena, ", ");
            try w.appendSlice(arena, ".{ .@\"0\" = ");
            try em.emitStrLit(w, arena, k);
            try w.appendSlice(arena, ", .@\"1\" = __rec.");
            try em.emitFieldName(w, arena, k);
            try w.appendSlice(arena, " }");
        }
        try w.appendSlice(arena, " }); })");
    } else if (std.mem.eql(u8, cl.namespace, "Object") and cl.object_values) {
        // Object.values(record): read each field into a homogeneous array,
        // binding the receiver once so a complex expression isn't re-evaluated.
        const ts = em.TempScope.open(w, arena);
        defer ts.close();
        const seq = ts.seq;
        const elem_zig = try types.zigName(arena, types.arrayElem(cl.checked_type.?).?);
        try w.print(arena, "(__ov{d}: {{ const __rec = ", .{seq});
        try em.emitExpr(cl.args[0], w, arena);
        try w.print(arena, "; break :__ov{d} @as([]const {s}, &.{{ ", .{ seq, elem_zig });
        for (cl.object_keys orelse &.{}, 0..) |k, i| {
            if (i > 0) try w.appendSlice(arena, ", ");
            try w.appendSlice(arena, "__rec.");
            try em.emitFieldName(w, arena, k);
        }
        try w.appendSlice(arena, " }); })");
    } else if (std.mem.eql(u8, cl.namespace, "Object") and std.mem.eql(u8, cl.name, "keys")) {
        // Static key list; evaluate (and discard) the receiver so an
        // otherwise-unused local still counts as referenced.
        const ts = em.TempScope.open(w, arena);
        defer ts.close();
        const seq = ts.seq;
        try w.print(arena, "(__ok{d}: {{ _ = &(", .{seq});
        try em.emitExpr(cl.args[0], w, arena);
        try w.print(arena, "); break :__ok{d} @as([]const []const u8, &.{{ ", .{seq});
        for (cl.object_keys orelse &.{}, 0..) |k, i| {
            if (i > 0) try w.appendSlice(arena, ", ");
            try em.emitStrLit(w, arena, k);
        }
        try w.appendSlice(arena, " }); })");
    } else if ((std.mem.eql(u8, cl.namespace, "time") or std.mem.eql(u8, cl.namespace, "Date")) and std.mem.eql(u8, cl.name, "now")) {
        try w.appendSlice(arena, "__timeNow(__io)");
    } else if (std.mem.eql(u8, cl.namespace, "time") and std.mem.eql(u8, cl.name, "monotonic")) {
        try w.appendSlice(arena, "__timeMonotonic(__io)");
    } else if (std.mem.eql(u8, cl.namespace, "http") and std.mem.eql(u8, cl.name, "request")) {
        try w.appendSlice(arena, "__httpRequest(__io, __alloc, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[2], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[3], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "http") and std.mem.eql(u8, cl.name, "get")) {
        try w.appendSlice(arena, "__httpRequest(__io, __alloc, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", \"GET\", \"\", LumenMap([]const u8, []const u8).__init())");
    } else if (std.mem.eql(u8, cl.namespace, "http") and std.mem.eql(u8, cl.name, "stream")) {
        try w.appendSlice(arena, "__httpStream(__io, __alloc, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[2], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[3], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "http") and std.mem.eql(u8, cl.name, "createServer")) {
        // The checker recorded which handler form this call passed (spec
        // 452); the streaming form gets its own connection loop.
        try w.appendSlice(arena, if (cl.http_streaming) "__httpCreateServerStream(__io, __alloc, " else "__httpCreateServer(__io, __alloc, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "net") and std.mem.eql(u8, cl.name, "connect")) {
        try w.appendSlice(arena, "__netConnect(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "net") and std.mem.eql(u8, cl.name, "createServer")) {
        try w.appendSlice(arena, "__netCreateServer(__io, __alloc, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "http") and std.mem.eql(u8, cl.name, "METHODS")) {
        try w.appendSlice(arena, "__httpMethods()");
    } else if (std.mem.eql(u8, cl.namespace, "http") and std.mem.eql(u8, cl.name, "STATUS_CODES")) {
        try w.appendSlice(arena, "__httpStatusCodes()");
    } else if (std.mem.eql(u8, cl.namespace, "JSON") and std.mem.eql(u8, cl.name, "stringify")) {
        if (cl.args.len == 3) {
            try w.appendSlice(arena, "__jsonStringifyPretty(__alloc, ");
            try em.emitExpr(cl.args[0], w, arena);
            try w.appendSlice(arena, ", @as(usize, @intCast(");
            try em.emitExpr(cl.args[2], w, arena);
            try w.appendSlice(arena, ")))");
        } else {
            try w.appendSlice(arena, "__jsonStringify(__alloc, ");
            try em.emitExpr(cl.args[0], w, arena);
            try w.append(arena, ')');
        }
    } else if (std.mem.eql(u8, cl.namespace, "JSON") and std.mem.eql(u8, cl.name, "parse")) {
        const result_type = cl.checked_arg_type orelse .void;
        const zig_name = types.zigName(arena, result_type) catch "void";
        const parse_throws = em.g_options.?.runtime_locations;
        if (parse_throws) try em.emitThrowingCallPrefix(w, arena);
        try w.print(arena, "__jsonParse({s}, __alloc, ", .{zig_name});
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
        if (parse_throws) try em.emitThrowingCallSuffix(w, arena);
    } else if (std.mem.eql(u8, cl.namespace, "path") and std.mem.eql(u8, cl.name, "sep")) {
        try w.appendSlice(arena, "@as([]const u8, \"/\")");
    } else if (std.mem.eql(u8, cl.namespace, "path") and std.mem.eql(u8, cl.name, "delimiter")) {
        try w.appendSlice(arena, "@as([]const u8, \":\")");
    } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "cwd")) {
        try w.appendSlice(arena, "__processCwd(__io, __alloc)");
    } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "chdir")) {
        try w.appendSlice(arena, "__processChdir(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "sleep")) {
        try w.appendSlice(arena, "__processSleep(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "exit")) {
        try w.appendSlice(arena, "std.process.exit(@intCast(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, "))");
    } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "env")) {
        try w.appendSlice(arena, "__processEnv(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "platform")) {
        try w.appendSlice(arena, "__processPlatform()");
    } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "arch")) {
        try w.appendSlice(arena, "__processArch()");
    } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "pid")) {
        try w.appendSlice(arena, "__processPid()");
    } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "argv")) {
        try w.appendSlice(arena, "__lumen_argv");
    } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "uptime")) {
        try w.appendSlice(arena, "__processUptime()");
    } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "hrtime")) {
        try w.appendSlice(arena, "__processHrtime(__io)");
    } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "memoryUsage")) {
        try w.appendSlice(arena, "__processMemoryUsage(__io, __alloc)");
    } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "kill")) {
        try w.appendSlice(arena, "__processKill(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "umask")) {
        try w.appendSlice(arena, "__processUmaskGet()");
    } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "setUmask")) {
        try w.appendSlice(arena, "__processUmaskSet(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "getuid")) {
        try w.appendSlice(arena, "__processGetuid()");
    } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "getgid")) {
        try w.appendSlice(arena, "__processGetgid()");
    } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "geteuid")) {
        try w.appendSlice(arena, "__processGeteuid()");
    } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "getegid")) {
        try w.appendSlice(arena, "__processGetegid()");
    } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "abort")) {
        try w.appendSlice(arena, "std.process.abort()");
    } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "version")) {
        try w.appendSlice(arena, "@as([]const u8, LUMEN_VERSION)");
    } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "stdin")) {
        try w.appendSlice(arena, "__processStdin(__io)");
    } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "stdout")) {
        try w.appendSlice(arena, "__processStdout(__io)");
    } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "stderr")) {
        try w.appendSlice(arena, "__processStderr(__io)");
    } else if (std.mem.eql(u8, cl.namespace, "os") and std.mem.eql(u8, cl.name, "platform")) {
        try w.appendSlice(arena, "__processPlatform()");
    } else if (std.mem.eql(u8, cl.namespace, "os") and std.mem.eql(u8, cl.name, "arch")) {
        try w.appendSlice(arena, "__processArch()");
    } else if (std.mem.eql(u8, cl.namespace, "os") and std.mem.eql(u8, cl.name, "type")) {
        try w.appendSlice(arena, "__osUnameField(\"sysname\")");
    } else if (std.mem.eql(u8, cl.namespace, "os") and std.mem.eql(u8, cl.name, "release")) {
        try w.appendSlice(arena, "__osUnameField(\"release\")");
    } else if (std.mem.eql(u8, cl.namespace, "os") and std.mem.eql(u8, cl.name, "version")) {
        try w.appendSlice(arena, "__osUnameField(\"version\")");
    } else if (std.mem.eql(u8, cl.namespace, "os") and std.mem.eql(u8, cl.name, "machine")) {
        try w.appendSlice(arena, "__osUnameField(\"machine\")");
    } else if (std.mem.eql(u8, cl.namespace, "os") and std.mem.eql(u8, cl.name, "hostname")) {
        try w.appendSlice(arena, "__osUnameField(\"nodename\")");
    } else if (std.mem.eql(u8, cl.namespace, "os") and std.mem.eql(u8, cl.name, "endianness")) {
        try w.appendSlice(arena, "__osEndianness()");
    } else if (std.mem.eql(u8, cl.namespace, "os") and std.mem.eql(u8, cl.name, "tmpdir")) {
        try w.appendSlice(arena, "__osTmpdir()");
    } else if (std.mem.eql(u8, cl.namespace, "os") and std.mem.eql(u8, cl.name, "homedir")) {
        try w.appendSlice(arena, "(__processEnv(\"HOME\") orelse \"\")");
    } else if (std.mem.eql(u8, cl.namespace, "os") and std.mem.eql(u8, cl.name, "uptime")) {
        try w.appendSlice(arena, "@as(i32, @truncate(__osSysinfo().uptime))");
    } else if (std.mem.eql(u8, cl.namespace, "os") and std.mem.eql(u8, cl.name, "totalmem")) {
        try w.appendSlice(arena, "__osMemBytes(true)");
    } else if (std.mem.eql(u8, cl.namespace, "os") and std.mem.eql(u8, cl.name, "freemem")) {
        try w.appendSlice(arena, "__osMemBytes(false)");
    } else if (std.mem.eql(u8, cl.namespace, "os") and std.mem.eql(u8, cl.name, "loadavg")) {
        try w.appendSlice(arena, "__osLoadavg(__alloc)");
    } else if (std.mem.eql(u8, cl.namespace, "os") and std.mem.eql(u8, cl.name, "availableParallelism")) {
        try w.appendSlice(arena, "@as(i32, @intCast(std.Thread.getCpuCount() catch 1))");
    } else if (std.mem.eql(u8, cl.namespace, "os") and std.mem.eql(u8, cl.name, "EOL")) {
        try w.appendSlice(arena, "@as([]const u8, \"\\n\")");
    } else if (std.mem.eql(u8, cl.namespace, "os") and std.mem.eql(u8, cl.name, "devNull")) {
        try w.appendSlice(arena, "@as([]const u8, \"/dev/null\")");
    } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "randomBytes")) {
        try w.appendSlice(arena, "__cryptoRandomBytes(__io, __alloc, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "randomUUID")) {
        try w.appendSlice(arena, "__cryptoRandomUUID(__io, __alloc)");
    } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "sha256")) {
        try w.appendSlice(arena, "__cryptoSha256(__alloc, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "sha1")) {
        try w.appendSlice(arena, "__cryptoSha1(__alloc, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "sha1Bytes")) {
        try w.appendSlice(arena, "__cryptoSha1Bytes(__alloc, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "base64Encode")) {
        try w.appendSlice(arena, "__cryptoBase64Encode(__alloc, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "base64Decode")) {
        try w.appendSlice(arena, "__cryptoBase64Decode(__alloc, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "randomKey")) {
        try w.appendSlice(arena, "__cryptoRandomKey(__io, __alloc)");
    } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "encrypt")) {
        try w.appendSlice(arena, "__cryptoEncrypt(__io, __alloc, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "decrypt")) {
        try w.appendSlice(arena, "__cryptoDecrypt(__alloc, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "randomBytesBuffer")) {
        try w.appendSlice(arena, "__cryptoRandomBytesBuffer(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "hmacSync")) {
        try w.appendSlice(arena, "__cryptoHmacSync(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "encryptSync")) {
        try w.appendSlice(arena, "__cryptoEncryptSync(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[2], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "decryptSync")) {
        try w.appendSlice(arena, "__cryptoDecryptSync(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[2], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "pbkdf2Sync")) {
        try w.appendSlice(arena, "__cryptoPbkdf2Sync(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[2], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[3], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "scryptSync")) {
        try w.appendSlice(arena, "__cryptoScryptSync(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[2], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "timingSafeEqual")) {
        try w.appendSlice(arena, "__cryptoTimingSafeEqual(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "createHash")) {
        try w.appendSlice(arena, "__cryptoCreateHash(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "createHmac")) {
        try w.appendSlice(arena, "__cryptoCreateHmac(");
        try em.emitExpr(cl.args[0], w, arena);
        try w.appendSlice(arena, ", ");
        try em.emitExpr(cl.args[1], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "readline") and std.mem.eql(u8, cl.name, "question")) {
        try w.appendSlice(arena, "__readlineQuestion(__io, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "zlib") and std.mem.eql(u8, cl.name, "gzipSync")) {
        try w.appendSlice(arena, "__zlibCompress(__alloc, .gzip, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "zlib") and std.mem.eql(u8, cl.name, "gunzipSync")) {
        try w.appendSlice(arena, "__zlibDecompress(__alloc, .gzip, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "zlib") and std.mem.eql(u8, cl.name, "deflateSync")) {
        try w.appendSlice(arena, "__zlibCompress(__alloc, .raw, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "zlib") and std.mem.eql(u8, cl.name, "inflateSync")) {
        try w.appendSlice(arena, "__zlibDecompress(__alloc, .raw, ");
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "Promise") and std.mem.eql(u8, cl.name, "resolve")) {
        // Promise.resolve(v) -> an already-resolved promise of v's type.
        const inner = cl.checked_arg_type orelse return error.ParseError;
        try w.print(arena, "__promiseResolved({s}, ", .{try types.zigName(arena, inner)});
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else if (std.mem.eql(u8, cl.namespace, "Promise") and std.mem.eql(u8, cl.name, "all")) {
        // Promise.all([p1, p2, ...]) -> await each (the shared loop drives
        // them all concurrently), collect into a T[], wrap resolved.
        const elem = cl.checked_arg_type orelse return error.ParseError;
        const elem_zig = try types.zigName(arena, elem);
        const items = cl.args[0].array.items;
        const ts = em.TempScope.open(w, arena);
        defer ts.close();
        const seq = ts.seq;
        try w.print(arena, "(__pa{d}: {{ const __r = __sa().alloc({s}, {d}) catch unreachable; ", .{ seq, elem_zig, items.len });
        for (items, 0..) |it, i| {
            try w.print(arena, "__r[{d}] = (", .{i});
            try em.emitExpr(it, w, arena);
            try w.appendSlice(arena, ").await_(); ");
        }
        try w.print(arena, "break :__pa{d} __promiseResolved([]const {s}, @as([]const {s}, __r)); }})", .{ seq, elem_zig, elem_zig });
    } else if (std.mem.eql(u8, cl.namespace, "Worker") and std.mem.eql(u8, cl.name, "run")) {
        // Worker.run(fn) -> spawn fn on a real detached std.Thread,
        // resolving a Promise<T> on the main thread once it finishes.
        const inner = cl.checked_arg_type orelse return error.ParseError;
        try w.print(arena, "__workerRun({s}, ", .{try types.zigName(arena, inner)});
        try em.emitExpr(cl.args[0], w, arena);
        try w.append(arena, ')');
    } else return error.ParseError;
}
