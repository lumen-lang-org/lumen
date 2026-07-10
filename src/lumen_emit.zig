//! Code generation -- the final stage: typed AST -> Zig source text.
//!
//! There is no separate IR. The `emit*` functions walk the type-checked AST and
//! append Zig source to growing buffers (`decls` for top-level declarations,
//! `body` for `main`'s statements); `lumen.zig` then hands the result to
//! `zig build-exe`. `lumen_compiler.zig` is the thin orchestrator that parses,
//! type-checks, runs the optimization passes, emits the program prologue, and
//! calls `emitProgram` here.
//!
//! Entry point: `emitProgram(program, decls, body, arena, options)`. The bulk is
//! `emitExpr` / `emitStmt` (and `emitStmtWithThrow`, which threads the current
//! try/switch break targets), plus per-construct emitters (`emitClass`,
//! `emitArrayMethod`, `emitStringMethod`, ...). Character/string literals are
//! emitted via `emitStrLit`/`emitRawStrLit`; regex `.test()` on a literal is
//! handed to `regex_specialize.emitTest` (with a fallback to the runtime engine).
//!
//! A few module-level globals carry context that is awkward to thread through
//! every call (the current program for class lookups, destination-passing maps,
//! the async-loop name, monotonic sequence counters for unique temp names). They
//! are set up by `emitProgram`/the orchestrator and read during emission.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const types = @import("lumen_types.zig");
const diag_mod = @import("lumen_diag.zig");
const lumen_opt = @import("lumen_opt.zig");
const regex_specialize = @import("regex_specialize.zig");
const array_string = @import("lumen_emit_array_string.zig");
const emit_stmt = @import("lumen_emit_stmt.zig");

const CompileError = diag_mod.CompileError;
const Diag = diag_mod.Diag;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const Program = ast.Program;

// Array/string instance-method codegen lives in lumen_emit_array_string.zig;
// statement codegen (including emitStmtWithThrow) lives in lumen_emit_stmt.zig.
// Aliased here so bare calls in this file (and `lumen_emit_class.zig`'s import of
// this file) resolve unchanged.
const emitStringMethod = array_string.emitStringMethod;
const emitArrayMethod = array_string.emitArrayMethod;
const emitTemplateText = array_string.emitTemplateText;
pub const emitStmt = emit_stmt.emitStmt;
pub const emitStmtWithThrow = emit_stmt.emitStmtWithThrow;

// AST-walk / pass helpers reused by the codegen (defined in lumen_opt).
const collectStrConcat = lumen_opt.collectStrConcat;
const bodyUsesName = lumen_opt.bodyUsesName;
const markBuilderParts = lumen_opt.markBuilderParts;

/// A source location (line/column) used when emitting panic locations.
pub const SourceLoc = struct { line: u32, col: u32 };

pub fn externZigName(t: types.Type, arena: std.mem.Allocator) []const u8 {
    return switch (t) {
        .string => "[*:0]const u8",
        else => types.zigName(arena, t) catch "void",
    };
}

/// Emits a Zig string literal whose value is the Lumen source string `s` with
/// its escape sequences decoded. The lexer keeps `.str` raw (escapes verbatim),
/// so `\n` `\t` `\r` `\0` `\\` `\"` `\'` are interpreted here and the resulting
/// bytes are re-escaped for the Zig literal.
/// Emits `s` as a Zig string literal preserving its bytes verbatim (no Lumen
/// escape decoding). Used for regex patterns, where `\d`, `\.` etc. are regex
/// escapes that must reach the engine intact, not be interpreted as string
/// escapes. Only Zig's own literal syntax is escaped.
fn emitRawStrLit(w: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, s: []const u8) CompileError!void {
    try w.append(arena, '"');
    for (s) |c| {
        switch (c) {
            '"' => try w.appendSlice(arena, "\\\""),
            '\\' => try w.appendSlice(arena, "\\\\"),
            '\n' => try w.appendSlice(arena, "\\n"),
            '\r' => try w.appendSlice(arena, "\\r"),
            '\t' => try w.appendSlice(arena, "\\t"),
            else => try w.append(arena, c),
        }
    }
    try w.append(arena, '"');
}

/// Emits a struct field name, quoting an ECMAScript `#private` name (spec 052)
/// as `@"#name"` since Zig identifiers can't start with `#`. Ordinary names
/// pass through unchanged.
pub fn emitFieldName(w: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, name: []const u8) CompileError!void {
    if (name.len > 0 and name[0] == '#') {
        try w.print(arena, "@\"{s}\"", .{name});
    } else {
        try w.appendSlice(arena, name);
    }
}

pub fn emitStrLit(w: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, s: []const u8) CompileError!void {
    try w.append(arena, '"');
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        var ch = s[i];
        if (ch == '\\' and i + 1 < s.len) {
            i += 1;
            ch = switch (s[i]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '0' => 0,
                else => s[i], // \\ \" \' \` and any other: the literal character
            };
        }
        switch (ch) {
            '"' => try w.appendSlice(arena, "\\\""),
            '\\' => try w.appendSlice(arena, "\\\\"),
            '\n' => try w.appendSlice(arena, "\\n"),
            '\t' => try w.appendSlice(arena, "\\t"),
            '\r' => try w.appendSlice(arena, "\\r"),
            else => if (ch < 0x20) try w.print(arena, "\\x{x:0>2}", .{ch}) else try w.append(arena, ch),
        }
    }
    try w.append(arena, '"');
}

pub fn emitExpr(e: *const Expr, w: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    switch (e.*) {
        .num => |v| try w.print(arena, "{d}", .{v}),
        // A float literal is `comptime_float` (f128) in Zig; left bare, chains of
        // literal arithmetic fold at f128 precision and print extra digits
        // (`0.1 + 0.2` -> `0.3000...0004`). Pin it to f64 so arithmetic and
        // formatting match JS's double semantics.
        .float => |v| try w.print(arena, "@as(f64, {d})", .{v}),
        .regex => |rx| {
            try w.appendSlice(arena, "__LumenRegExp{ .source = ");
            try emitRawStrLit(w, arena, rx.source);
            try w.appendSlice(arena, ", .flags = ");
            try emitRawStrLit(w, arena, rx.flags);
            try w.appendSlice(arena, " }");
        },
        .null_lit => try w.appendSlice(arena, "null"),
        .bool => |v| try w.appendSlice(arena, if (v) "true" else "false"),
        .str => |s| try emitStrLit(w, arena, s),
        .array => |arr| {
            if (arr.elem_type) |elem| {
                // Array literal with `...spread` entries → runtime concatenation.
                // Each plain entry becomes a one-element slice; each spread emits
                // its source slice directly.
                const ez = try types.zigName(arena, elem);
                try w.print(arena, "(std.mem.concat(__sa(), {s}, &.{{ ", .{ez});
                for (arr.items, 0..) |item, i| {
                    if (i > 0) try w.appendSlice(arena, ", ");
                    if (item.* == .spread) {
                        try emitExpr(item.spread, w, arena);
                    } else {
                        try w.print(arena, "&[_]{s}{{ ", .{ez});
                        try emitExpr(item, w, arena);
                        try w.appendSlice(arena, " }");
                    }
                }
                try w.appendSlice(arena, " }) catch unreachable)");
            } else {
                try w.appendSlice(arena, "&.{ ");
                for (arr.items, 0..) |item, i| {
                    if (i > 0) try w.appendSlice(arena, ", ");
                    try emitExpr(item, w, arena);
                }
                try w.appendSlice(arena, " }");
            }
        },
        .spread => |inner| {
            // A bare spread only appears inside array/call/object emitters, which
            // handle it specially; emitting the inner expression is the safe
            // fallback should one slip through.
            try emitExpr(inner, w, arena);
        },
        .tuple_lit => |t| {
            // A positional struct literal `.{ .@"0" = a, .@"1" = b, ... }`.
            try w.appendSlice(arena, ".{ ");
            for (t.items, 0..) |item, i| {
                if (i > 0) try w.appendSlice(arena, ", ");
                try w.print(arena, ".@\"{d}\" = ", .{i});
                try emitExpr(item, w, arena);
            }
            try w.appendSlice(arena, " }");
        },
        .call => |cl| {
            // builtins lower to a Zig std wrapper taking (__io, __alloc, args...).
            if (std.mem.eql(u8, cl.name, "Error")) {
                if (cl.args.len > 0) try emitExpr(cl.args[0], w, arena);
            } else if (std.mem.eql(u8, cl.name, "parseInt") and cl.is_global_parse) {
                try w.appendSlice(arena, "__parseInt(");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                if (cl.args.len == 2) {
                    try w.appendSlice(arena, "@intCast(");
                    try emitExpr(cl.args[1], w, arena);
                    try w.appendSlice(arena, ")");
                } else {
                    // 0 = infer the radix (honors a `0x` prefix as hex).
                    try w.appendSlice(arena, "0");
                }
                try w.appendSlice(arena, ")");
            } else if (std.mem.eql(u8, cl.name, "parseFloat") and cl.is_global_parse) {
                try w.appendSlice(arena, "__parseFloat(");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ")");
            } else if (std.mem.eql(u8, cl.name, "String") and cl.is_global_parse) {
                // Convert number/bool/string to string with a comptime type branch.
                g_global_pred_seq += 1;
                const s = g_global_pred_seq;
                try w.print(arena, "(__sc{d}: {{ const __v = ", .{s});
                try emitExpr(cl.args[0], w, arena);
                try w.print(arena, "; break :__sc{d} switch (@typeInfo(@TypeOf(__v))) {{ .bool => std.fmt.allocPrint(__sa(), \"{{}}\", .{{__v}}) catch unreachable, .int, .comptime_int, .float, .comptime_float => std.fmt.allocPrint(__sa(), \"{{d}}\", .{{__v}}) catch unreachable, else => @as([]const u8, __v) }}; }})", .{s});
            } else if (std.mem.eql(u8, cl.name, "Number") and cl.is_global_parse) {
                // number/bool/string -> f64; a string that doesn't parse is NaN.
                g_global_pred_seq += 1;
                const s = g_global_pred_seq;
                try w.print(arena, "(__nc{d}: {{ const __v = ", .{s});
                try emitExpr(cl.args[0], w, arena);
                try w.print(arena, "; break :__nc{d} switch (@typeInfo(@TypeOf(__v))) {{ .bool => @as(f64, if (__v) 1 else 0), .int, .comptime_int => @as(f64, @floatFromInt(__v)), .float, .comptime_float => @as(f64, __v), else => std.fmt.parseFloat(f64, __v) catch std.math.nan(f64) }}; }})", .{s});
            } else if (std.mem.eql(u8, cl.name, "Boolean") and cl.is_global_parse) {
                // Truthiness: nonzero number, nonempty string, or the bool itself.
                g_global_pred_seq += 1;
                const s = g_global_pred_seq;
                try w.print(arena, "(__bc{d}: {{ const __v = ", .{s});
                try emitExpr(cl.args[0], w, arena);
                try w.print(arena, "; break :__bc{d} switch (@typeInfo(@TypeOf(__v))) {{ .bool => __v, .int, .comptime_int, .float, .comptime_float => __v != 0, else => __v.len != 0 }}; }})", .{s});
            } else if ((std.mem.eql(u8, cl.name, "isNaN") or std.mem.eql(u8, cl.name, "isFinite")) and cl.is_global_parse) {
                // Coerce the argument to f64 with a comptime type branch so the
                // same emit works for int and float inputs.
                const fn_name = if (std.mem.eql(u8, cl.name, "isNaN")) "isNan" else "isFinite";
                g_global_pred_seq += 1;
                const s = g_global_pred_seq;
                try w.print(arena, "(__gp{d}: {{ const __v = ", .{s});
                try emitExpr(cl.args[0], w, arena);
                try w.print(arena, "; break :__gp{d} std.math.{s}(switch (@typeInfo(@TypeOf(__v))) {{ .float, .comptime_float => @as(f64, __v), else => @as(f64, @floatFromInt(__v)) }}); }})", .{ s, fn_name });
            } else if (std.mem.eql(u8, cl.name, "expect")) {
                try w.appendSlice(arena, "try std.testing.expect(");
                if (cl.args.len > 0) try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.name, "__expectToBe") or std.mem.eql(u8, cl.name, "__expectToEqual") or std.mem.eql(u8, cl.name, "__expectStrEqual")) {
                // `expect(actual).toBe(expected)` lowers to a std.testing helper
                // taking (expected, actual). `.toEqual` is currently a
                // strict-equality alias of `.toBe` for V1 scalar/string values.
                // Strings compare by bytes via expectEqualStrings.
                const helper = if (std.mem.eql(u8, cl.name, "__expectStrEqual"))
                    "try std.testing.expectEqualStrings("
                else
                    "try std.testing.expectEqual(";
                try w.appendSlice(arena, helper);
                if (cl.args.len > 1) try emitExpr(cl.args[1], w, arena);
                try w.appendSlice(arena, ", ");
                if (cl.args.len > 0) try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.name, "argsCount")) {
                try w.appendSlice(arena, "@as(i32, @intCast(__args.len))");
            } else if (std.mem.eql(u8, cl.name, "arg")) {
                try w.appendSlice(arena, "(if (@as(usize, @intCast(");
                if (cl.args.len > 0) try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ")) < __args.len) __args[@as(usize, @intCast(");
                if (cl.args.len > 0) try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, "))] else \"\")");
            } else if (std.mem.eql(u8, cl.name, "httpGet")) {
                try w.appendSlice(arena, "__httpGet(__io, __alloc, ");
                if (cl.args.len > 0) try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.name, "serve")) {
                try w.appendSlice(arena, "__serve(__io, __alloc, ");
                if (cl.args.len > 0) try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                if (cl.args.len > 1) try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.name, "setTimeout")) {
                // setTimeout(cb, ms) -> __setTimeout(cb, @intCast(ms)).
                try w.appendSlice(arena, "__setTimeout(");
                if (cl.args.len > 0) try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", @intCast(");
                if (cl.args.len > 1) try emitExpr(cl.args[1], w, arena);
                try w.appendSlice(arena, "))");
            } else if (std.mem.eql(u8, cl.name, "setInterval")) {
                try w.appendSlice(arena, "__setInterval(");
                if (cl.args.len > 0) try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", @intCast(");
                if (cl.args.len > 1) try emitExpr(cl.args[1], w, arena);
                try w.appendSlice(arena, "))");
            } else if (cl.is_closure) {
                // Function-value call through the fat pointer: f.call(f.ctx, args).
                const fname = cl.emit_name orelse cl.name;
                try w.print(arena, "{s}.call({s}.ctx", .{ fname, fname });
                for (cl.args) |arg| {
                    try w.appendSlice(arena, ", ");
                    try emitExpr(arg, w, arena);
                }
                try w.append(arena, ')');
            } else {
                // A `string` return from an extern function arrives as a raw
                // `[*:0]const u8`; copy it once into an owned Lumen string so the
                // value outlives the C buffer.
                if (cl.ffi_string_return) try w.appendSlice(arena, "(__alloc.dupe(u8, std.mem.span(");
                try w.print(arena, "{s}(", .{cl.emit_name orelse cl.name});
                for (cl.args, 0..) |arg, i| {
                    if (i > 0) try w.appendSlice(arena, ", ");
                    // A `string` argument crosses as a NUL-terminated C string.
                    if (i < cl.ffi_string_args.len and cl.ffi_string_args[i]) {
                        try w.appendSlice(arena, "(std.fmt.allocPrintSentinel(__alloc, \"{s}\", .{");
                        try emitExpr(arg, w, arena);
                        try w.appendSlice(arena, "}, 0) catch unreachable).ptr");
                    } else if (i < cl.ref_args.len and cl.ref_args[i]) {
                        // A by-reference (`Ref<T>`) argument: take its address so
                        // the callee mutates the caller's binding in place.
                        try w.append(arena, '&');
                        try emitExpr(arg, w, arena);
                    } else {
                        try emitExpr(arg, w, arena);
                    }
                }
                try w.append(arena, ')');
                if (cl.ffi_string_return) try w.appendSlice(arena, ")) catch unreachable)");
            }
        },
        .static_call => |cl| {
            const checked_type = cl.checked_type orelse return error.ParseError;
            if (std.mem.eql(u8, cl.namespace, "Math") and std.mem.eql(u8, cl.name, "abs")) {
                if (checked_type == .f64) {
                    // A "whole" float literal like 4.0 emits as the bare
                    // numeral `4`, which @abs doesn't comptime_int-coerce
                    // on its own -- @as forces the float type.
                    try w.appendSlice(arena, "@abs(@as(f64, ");
                    try emitExpr(cl.args[0], w, arena);
                    try w.appendSlice(arena, "))");
                } else {
                    try w.print(arena, "@as({s}, @intCast(@abs(", .{try types.zigName(arena, checked_type)});
                    try emitExpr(cl.args[0], w, arena);
                    try w.appendSlice(arena, ")))");
                }
            } else if (std.mem.eql(u8, cl.namespace, "Math") and std.mem.eql(u8, cl.name, "sign")) {
                try w.appendSlice(arena, "@as(i32, if (");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, " < 0) -1 else if (");
                try emitExpr(cl.args[0], w, arena);
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
                    try emitExpr(cl.args[0], w, arena);
                    try w.append(arena, ')');
                } else {
                    try w.appendSlice(arena, "@as(f64, @floatFromInt(");
                    try emitExpr(cl.args[0], w, arena);
                    try w.appendSlice(arena, "))");
                }
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "Math") and std.mem.eql(u8, cl.name, "fround")) {
                const arg_type = cl.checked_arg_type orelse return error.ParseError;
                try w.appendSlice(arena, "@as(f64, @as(f32, @floatCast(");
                if (arg_type == .f64) {
                    try w.appendSlice(arena, "@as(f64, ");
                    try emitExpr(cl.args[0], w, arena);
                    try w.append(arena, ')');
                } else {
                    try w.appendSlice(arena, "@as(f64, @floatFromInt(");
                    try emitExpr(cl.args[0], w, arena);
                    try w.appendSlice(arena, "))");
                }
                try w.appendSlice(arena, ")))");
            } else if (std.mem.eql(u8, cl.namespace, "Math") and std.mem.eql(u8, cl.name, "clz32")) {
                try w.appendSlice(arena, "@as(i32, @clz(@as(u32, @bitCast(@as(i32, @truncate(");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, "))))))");
            } else if (std.mem.eql(u8, cl.namespace, "Math") and std.mem.eql(u8, cl.name, "imul")) {
                // 32-bit wrapping multiply; truncate each operand to i32 first.
                try w.appendSlice(arena, "(@as(i32, @truncate(");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ")) *% @as(i32, @truncate(");
                try emitExpr(cl.args[1], w, arena);
                try w.appendSlice(arena, ")))");
            } else if (std.mem.eql(u8, cl.namespace, "Math") and (std.mem.eql(u8, cl.name, "max") or std.mem.eql(u8, cl.name, "min")) and cl.args.len == 1 and cl.args[0].* == .spread) {
                // `Math.min(...arr)` -> a runtime fold over the array.
                g_global_pred_seq += 1;
                const s = g_global_pred_seq;
                try w.print(arena, "(__mm{d}: {{ const __arr = ", .{s});
                try emitExpr(cl.args[0].spread, w, arena);
                try w.print(arena, "; var __r = __arr[0]; for (__arr[1..]) |__e| {{ __r = @{s}(__r, __e); }} break :__mm{d} __r; }})", .{ cl.name, s });
            } else if (std.mem.eql(u8, cl.namespace, "Math") and (std.mem.eql(u8, cl.name, "max") or std.mem.eql(u8, cl.name, "min"))) {
                // Left-fold over all arguments: @max(@max(a, b), c) ...
                for (0..cl.args.len - 1) |_| try w.print(arena, "@{s}(", .{cl.name});
                try emitExpr(cl.args[0], w, arena);
                for (cl.args[1..]) |arg| {
                    try w.appendSlice(arena, ", ");
                    try emitExpr(arg, w, arena);
                    try w.append(arena, ')');
                }
            } else if (std.mem.eql(u8, cl.namespace, "Math") and std.mem.eql(u8, cl.name, "clamp")) {
                try w.appendSlice(arena, "@min(@max(");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.appendSlice(arena, "), ");
                try emitExpr(cl.args[2], w, arena);
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
                    try emitExpr(cl.args[0], w, arena);
                    try w.append(arena, ')');
                } else {
                    try w.appendSlice(arena, "@as(f64, @floatFromInt(");
                    try emitExpr(cl.args[0], w, arena);
                    try w.appendSlice(arena, "))");
                }
                if (is_round) try w.appendSlice(arena, " + 0.5");
                try w.appendSlice(arena, ")))");
            } else if (std.mem.eql(u8, cl.namespace, "Math") and std.mem.eql(u8, cl.name, "pow")) {
                const arg_type = cl.checked_arg_type orelse return error.ParseError;
                try w.appendSlice(arena, "std.math.pow(f64, ");
                if (arg_type == .f64) {
                    try emitExpr(cl.args[0], w, arena);
                    try w.appendSlice(arena, ", ");
                    try emitExpr(cl.args[1], w, arena);
                } else {
                    try w.appendSlice(arena, "@as(f64, @floatFromInt(");
                    try emitExpr(cl.args[0], w, arena);
                    try w.appendSlice(arena, ")), @as(f64, @floatFromInt(");
                    try emitExpr(cl.args[1], w, arena);
                    try w.appendSlice(arena, "))");
                }
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "Math") and (std.mem.eql(u8, cl.name, "log") or std.mem.eql(u8, cl.name, "sin") or std.mem.eql(u8, cl.name, "cos") or std.mem.eql(u8, cl.name, "tan") or std.mem.eql(u8, cl.name, "exp") or std.mem.eql(u8, cl.name, "exp2") or std.mem.eql(u8, cl.name, "log2") or std.mem.eql(u8, cl.name, "log10"))) {
                const arg_type = cl.checked_arg_type orelse return error.ParseError;
                try w.print(arena, "@{s}(", .{cl.name});
                if (arg_type == .f64) {
                    try w.appendSlice(arena, "@as(f64, ");
                    try emitExpr(cl.args[0], w, arena);
                    try w.append(arena, ')');
                } else {
                    try w.appendSlice(arena, "@as(f64, @floatFromInt(");
                    try emitExpr(cl.args[0], w, arena);
                    try w.appendSlice(arena, "))");
                }
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "Math") and (std.mem.eql(u8, cl.name, "asin") or std.mem.eql(u8, cl.name, "acos") or std.mem.eql(u8, cl.name, "atan") or std.mem.eql(u8, cl.name, "cbrt") or std.mem.eql(u8, cl.name, "sinh") or std.mem.eql(u8, cl.name, "cosh") or std.mem.eql(u8, cl.name, "tanh") or std.mem.eql(u8, cl.name, "asinh") or std.mem.eql(u8, cl.name, "acosh") or std.mem.eql(u8, cl.name, "atanh") or std.mem.eql(u8, cl.name, "expm1") or std.mem.eql(u8, cl.name, "log1p"))) {
                const arg_type = cl.checked_arg_type orelse return error.ParseError;
                try w.print(arena, "std.math.{s}(", .{cl.name});
                if (arg_type == .f64) {
                    try w.appendSlice(arena, "@as(f64, ");
                    try emitExpr(cl.args[0], w, arena);
                    try w.append(arena, ')');
                } else {
                    try w.appendSlice(arena, "@as(f64, @floatFromInt(");
                    try emitExpr(cl.args[0], w, arena);
                    try w.appendSlice(arena, "))");
                }
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "Math") and (std.mem.eql(u8, cl.name, "atan2") or std.mem.eql(u8, cl.name, "hypot"))) {
                const arg_type = cl.checked_arg_type orelse return error.ParseError;
                const F = struct {
                    fn emit(ex: anytype, aty: anytype, ww: *std.ArrayListUnmanaged(u8), ar: std.mem.Allocator) CompileError!void {
                        if (aty == .f64) {
                            try ww.appendSlice(ar, "@as(f64, ");
                            try emitExpr(ex, ww, ar);
                            try ww.append(ar, ')');
                        } else {
                            try ww.appendSlice(ar, "@as(f64, @floatFromInt(");
                            try emitExpr(ex, ww, ar);
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
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ".len == 0)");
            } else if (std.mem.eql(u8, cl.namespace, "String") and std.mem.eql(u8, cl.name, "contains")) {
                try w.appendSlice(arena, "(std.mem.indexOf(u8, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.appendSlice(arena, ") != null)");
            } else if (std.mem.eql(u8, cl.namespace, "String") and std.mem.eql(u8, cl.name, "startsWith")) {
                try w.appendSlice(arena, "std.mem.startsWith(u8, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "Number") and std.mem.eql(u8, cl.name, "parseInt")) {
                // Number.parseInt is identical to the global parseInt.
                try w.appendSlice(arena, "__parseInt(");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                if (cl.args.len == 2) {
                    try w.appendSlice(arena, "@intCast(");
                    try emitExpr(cl.args[1], w, arena);
                    try w.appendSlice(arena, ")");
                } else {
                    try w.appendSlice(arena, "0");
                }
                try w.appendSlice(arena, ")");
            } else if (std.mem.eql(u8, cl.namespace, "Number") and std.mem.eql(u8, cl.name, "parseFloat")) {
                try w.appendSlice(arena, "__parseFloat(");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ")");
            } else if (std.mem.eql(u8, cl.namespace, "Number") and (std.mem.eql(u8, cl.name, "isInteger") or std.mem.eql(u8, cl.name, "isFinite") or std.mem.eql(u8, cl.name, "isNaN") or std.mem.eql(u8, cl.name, "isSafeInteger"))) {
                // Evaluate the argument as f64 (so the check works uniformly for
                // int and float inputs, and side effects still run).
                const arg_type = cl.checked_arg_type orelse return error.ParseError;
                const F = struct {
                    fn emit(ex: anytype, aty: anytype, ww: *std.ArrayListUnmanaged(u8), ar: std.mem.Allocator) CompileError!void {
                        if (aty == .f64) {
                            try ww.appendSlice(ar, "@as(f64, ");
                            try emitExpr(ex, ww, ar);
                            try ww.append(ar, ')');
                        } else {
                            try ww.appendSlice(ar, "@as(f64, @floatFromInt(");
                            try emitExpr(ex, ww, ar);
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
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.appendSlice(arena, ")) { .lt => -1, .eq => 0, .gt => 1 })");
            } else if (std.mem.eql(u8, cl.namespace, "String") and (std.mem.eql(u8, cl.name, "fromCharCode") or std.mem.eql(u8, cl.name, "fromCodePoint"))) {
                g_from_char_code_seq += 1;
                const fcc_lbl = try std.fmt.allocPrint(arena, "__fcc{d}", .{g_from_char_code_seq});
                try w.print(arena, "({s}: {{ const __b = __sa().alloc(u8, {d}) catch unreachable; ", .{ fcc_lbl, cl.args.len });
                for (cl.args, 0..) |arg, i| {
                    try w.print(arena, "__b[{d}] = @intCast((", .{i});
                    try emitExpr(arg, w, arena);
                    try w.appendSlice(arena, ") & 0xFF); ");
                }
                try w.print(arena, "break :{s} @as([]const u8, __b); }})", .{fcc_lbl});
            } else if (std.mem.eql(u8, cl.namespace, "Array") and std.mem.eql(u8, cl.name, "from")) {
                const src = cl.checked_arg_type orelse return error.ParseError;
                g_global_pred_seq += 1;
                const s = g_global_pred_seq;
                if (types.isStringLike(src)) {
                    // String -> array of single-character strings.
                    try w.print(arena, "(__afr{d}: {{ const __s = ", .{s});
                    try emitExpr(cl.args[0], w, arena);
                    try w.print(arena, "; var __parts: std.ArrayListUnmanaged([]const u8) = .empty; for (__s) |*__cp| __parts.append(__sa(), __cp[0..1]) catch unreachable; break :__afr{d} @as([]const []const u8, __parts.items); }})", .{s});
                } else {
                    // Array -> shallow copy.
                    const ez = try types.zigName(arena, types.arrayElem(src) orelse return error.ParseError);
                    try w.print(arena, "(__afr{d}: {{ const __a = ", .{s});
                    try emitExpr(cl.args[0], w, arena);
                    try w.print(arena, "; const __r = __sa().alloc({s}, __a.len) catch unreachable; @memcpy(__r, __a); break :__afr{d} @as([]const {s}, __r); }})", .{ ez, s, ez });
                }
            } else if (std.mem.eql(u8, cl.namespace, "Array") and std.mem.eql(u8, cl.name, "of")) {
                // Heap-allocate an array from the arguments (avoids returning a
                // pointer to an anonymous tuple literal).
                const et = cl.checked_arg_type orelse return error.ParseError;
                const ez = try types.zigName(arena, et);
                g_global_pred_seq += 1;
                const s = g_global_pred_seq;
                try w.print(arena, "(__aof{d}: {{ const __r = __sa().alloc({s}, {d}) catch unreachable; ", .{ s, ez, cl.args.len });
                for (cl.args, 0..) |arg, i| {
                    try w.print(arena, "__r[{d}] = ", .{i});
                    try emitExpr(arg, w, arena);
                    try w.appendSlice(arena, "; ");
                }
                try w.print(arena, "break :__aof{d} @as([]const {s}, __r); }})", .{ s, ez });
            } else if (std.mem.eql(u8, cl.namespace, "Array") and std.mem.eql(u8, cl.name, "isEmpty")) {
                try w.append(arena, '(');
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ".len == 0)");
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "readFileSync")) {
                try w.appendSlice(arena, "__readFileSync(__io, __alloc, ");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "readFile")) {
                try w.appendSlice(arena, "__readFileAsync(");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "writeFile")) {
                try w.appendSlice(arena, "__writeFileAsync(");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "appendFile")) {
                try w.appendSlice(arena, "__appendFileAsync(");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "unlink")) {
                try w.appendSlice(arena, "__unlinkAsync(");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "mkdir")) {
                try w.appendSlice(arena, "__mkdirAsync(");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "rmdir")) {
                try w.appendSlice(arena, "__rmdirAsync(");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "stat")) {
                try w.appendSlice(arena, "__statAsync(");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "existsSync")) {
                try w.appendSlice(arena, "__existsSync(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "realpathSync")) {
                try w.appendSlice(arena, "__realpathSync(__io, __alloc, ");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "writeFileSync")) {
                try w.appendSlice(arena, "__writeFileSync(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "appendFileSync")) {
                try w.appendSlice(arena, "__appendFileSync(__io, __alloc, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "mkdirSync")) {
                try w.appendSlice(arena, "__mkdirSync(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                if (cl.args.len == 2) try emitExpr(cl.args[1], w, arena) else try w.appendSlice(arena, "false");
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "unlinkSync")) {
                try w.appendSlice(arena, "__unlinkSync(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "renameSync")) {
                try w.appendSlice(arena, "__renameSync(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "copyFileSync")) {
                try w.appendSlice(arena, "__copyFileSync(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "cpSync")) {
                try w.appendSlice(arena, "__cpSync(__io, __alloc, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.appendSlice(arena, ", ");
                if (cl.args.len == 3) try emitExpr(cl.args[2], w, arena) else try w.appendSlice(arena, "false");
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "mkdtempSync")) {
                try w.appendSlice(arena, "__mkdtempSync(__io, __alloc, ");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "statSync")) {
                try w.appendSlice(arena, "__statSync(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "openSync")) {
                try w.appendSlice(arena, "__openSync(__io, __alloc, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "closeSync")) {
                try w.appendSlice(arena, "__closeSync(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "readSync")) {
                try w.appendSlice(arena, "__readSync(__io, __alloc, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "writeSync")) {
                try w.appendSlice(arena, "__writeSync(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "rmdirSync")) {
                try w.appendSlice(arena, "__rmdirSync(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "rmSync")) {
                try w.appendSlice(arena, "__rmSync(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                if (cl.args.len == 2) try emitExpr(cl.args[1], w, arena) else try w.appendSlice(arena, "false");
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "truncateSync")) {
                try w.appendSlice(arena, "__truncateSync(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "linkSync")) {
                try w.appendSlice(arena, "__linkSync(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "symlinkSync")) {
                try w.appendSlice(arena, "__symlinkSync(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "readlinkSync")) {
                try w.appendSlice(arena, "__readlinkSync(__io, __alloc, ");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "chmodSync")) {
                try w.appendSlice(arena, "__chmodSync(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "accessSync")) {
                try w.appendSlice(arena, "__accessSync(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                if (cl.args.len == 2) try emitExpr(cl.args[1], w, arena) else try w.appendSlice(arena, "0");
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "lstatSync")) {
                try w.appendSlice(arena, "__lstatSync(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "fstatSync")) {
                try w.appendSlice(arena, "__fstatSync(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "fchmodSync")) {
                try w.appendSlice(arena, "__fchmodSync(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "lchmodSync")) {
                try w.appendSlice(arena, "__lchmodSync(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "fchownSync")) {
                try w.appendSlice(arena, "__fchownSync(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[2], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "chownSync")) {
                try w.appendSlice(arena, "__chownSync(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[2], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "lchownSync")) {
                try w.appendSlice(arena, "__lchownSync(");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[2], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "writevSync")) {
                try w.appendSlice(arena, "__writevSync(");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "readvSync")) {
                try w.appendSlice(arena, "__readvSync(__alloc, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and (std.mem.eql(u8, cl.name, "fsyncSync") or std.mem.eql(u8, cl.name, "fdatasyncSync"))) {
                try w.appendSlice(arena, "__fsyncSync(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "ftruncateSync")) {
                try w.appendSlice(arena, "__ftruncateSync(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "futimesSync")) {
                try w.appendSlice(arena, "__futimesSync(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[2], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "utimesSync")) {
                try w.appendSlice(arena, "__utimesSync(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[2], w, arena);
                try w.appendSlice(arena, ", true)");
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "lutimesSync")) {
                try w.appendSlice(arena, "__utimesSync(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[2], w, arena);
                try w.appendSlice(arena, ", false)");
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "readdirSync")) {
                try w.appendSlice(arena, "__readdirSync(__io, __alloc, ");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "watch")) {
                try w.appendSlice(arena, "__fsWatch(");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "createReadStream")) {
                try w.appendSlice(arena, "__fsCreateReadStream(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "fs") and std.mem.eql(u8, cl.name, "createWriteStream")) {
                try w.appendSlice(arena, "__fsCreateWriteStream(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "Buffer") and std.mem.eql(u8, cl.name, "from") and cl.args.len == 1) {
                try w.appendSlice(arena, "__bufferFromUtf8(");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "Buffer") and std.mem.eql(u8, cl.name, "from") and cl.args.len == 2) {
                try w.appendSlice(arena, "__bufferFromEncoded(");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "Buffer") and std.mem.eql(u8, cl.name, "alloc")) {
                try w.appendSlice(arena, "__bufferAlloc(");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "path") and std.mem.eql(u8, cl.name, "basename")) {
                try w.appendSlice(arena, "__pathBasename(");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                if (cl.args.len == 2) try emitExpr(cl.args[1], w, arena) else try w.appendSlice(arena, "\"\"");
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "path") and std.mem.eql(u8, cl.name, "dirname")) {
                try w.appendSlice(arena, "__pathDirname(");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "path") and std.mem.eql(u8, cl.name, "extname")) {
                try w.appendSlice(arena, "std.fs.path.extension(");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "path") and std.mem.eql(u8, cl.name, "isAbsolute")) {
                try w.appendSlice(arena, "std.fs.path.isAbsolute(");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "path") and std.mem.eql(u8, cl.name, "normalize")) {
                try w.appendSlice(arena, "__pathResolve(__alloc, &.{");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, "})");
            } else if (std.mem.eql(u8, cl.namespace, "path") and std.mem.eql(u8, cl.name, "join")) {
                try w.appendSlice(arena, "__pathJoin(__alloc, &.{ ");
                for (cl.args, 0..) |a, i| {
                    if (i > 0) try w.appendSlice(arena, ", ");
                    try emitExpr(a, w, arena);
                }
                try w.appendSlice(arena, " })");
            } else if (std.mem.eql(u8, cl.namespace, "path") and std.mem.eql(u8, cl.name, "resolve")) {
                try w.appendSlice(arena, "__pathResolve(__io, __alloc, &.{ ");
                for (cl.args, 0..) |a, i| {
                    if (i > 0) try w.appendSlice(arena, ", ");
                    try emitExpr(a, w, arena);
                }
                try w.appendSlice(arena, " })");
            } else if (std.mem.eql(u8, cl.namespace, "path") and std.mem.eql(u8, cl.name, "parse")) {
                try w.appendSlice(arena, "__pathParse(");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "path") and std.mem.eql(u8, cl.name, "format")) {
                try w.appendSlice(arena, "__pathFormat(__alloc, ");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "url") and std.mem.eql(u8, cl.name, "parse")) {
                try w.appendSlice(arena, "__urlParse(__alloc, ");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "url") and std.mem.eql(u8, cl.name, "format")) {
                try w.appendSlice(arena, "__urlFormat(__alloc, ");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "child_process") and std.mem.eql(u8, cl.name, "spawnSync")) {
                try w.appendSlice(arena, "__spawnSync(__io, __alloc, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "assert") and std.mem.eql(u8, cl.name, "ok")) {
                try w.appendSlice(arena, "__assertOk(");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "assert") and std.mem.eql(u8, cl.name, "equal")) {
                try w.appendSlice(arena, "__assertEqual(");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "assert") and std.mem.eql(u8, cl.name, "__assertStrEqual")) {
                try w.appendSlice(arena, "__assertStrEqual(");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "time") and std.mem.eql(u8, cl.name, "now")) {
                try w.appendSlice(arena, "__timeNow(__io)");
            } else if (std.mem.eql(u8, cl.namespace, "time") and std.mem.eql(u8, cl.name, "monotonic")) {
                try w.appendSlice(arena, "__timeMonotonic(__io)");
            } else if (std.mem.eql(u8, cl.namespace, "http") and std.mem.eql(u8, cl.name, "request")) {
                try w.appendSlice(arena, "__httpRequest(__io, __alloc, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[2], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[3], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "http") and std.mem.eql(u8, cl.name, "get")) {
                try w.appendSlice(arena, "__httpRequest(__io, __alloc, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", \"GET\", \"\", LumenMap([]const u8, []const u8).__init())");
            } else if (std.mem.eql(u8, cl.namespace, "http") and std.mem.eql(u8, cl.name, "createServer")) {
                try w.appendSlice(arena, "__httpCreateServer(__io, __alloc, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "net") and std.mem.eql(u8, cl.name, "connect")) {
                try w.appendSlice(arena, "__netConnect(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "net") and std.mem.eql(u8, cl.name, "createServer")) {
                try w.appendSlice(arena, "__netCreateServer(__io, __alloc, ");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "http") and std.mem.eql(u8, cl.name, "METHODS")) {
                try w.appendSlice(arena, "__httpMethods()");
            } else if (std.mem.eql(u8, cl.namespace, "http") and std.mem.eql(u8, cl.name, "STATUS_CODES")) {
                try w.appendSlice(arena, "__httpStatusCodes()");
            } else if (std.mem.eql(u8, cl.namespace, "JSON") and std.mem.eql(u8, cl.name, "stringify")) {
                try w.appendSlice(arena, "__jsonStringify(__alloc, ");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "JSON") and std.mem.eql(u8, cl.name, "parse")) {
                const result_type = cl.checked_arg_type orelse .void;
                const zig_name = types.zigName(arena, result_type) catch "void";
                try w.print(arena, "__jsonParse({s}, __alloc, ", .{zig_name});
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "path") and std.mem.eql(u8, cl.name, "sep")) {
                try w.appendSlice(arena, "@as([]const u8, \"/\")");
            } else if (std.mem.eql(u8, cl.namespace, "path") and std.mem.eql(u8, cl.name, "delimiter")) {
                try w.appendSlice(arena, "@as([]const u8, \":\")");
            } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "cwd")) {
                try w.appendSlice(arena, "__processCwd(__io, __alloc)");
            } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "chdir")) {
                try w.appendSlice(arena, "__processChdir(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "exit")) {
                try w.appendSlice(arena, "std.process.exit(@intCast(");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, "))");
            } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "env")) {
                try w.appendSlice(arena, "__processEnv(");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "platform")) {
                try w.appendSlice(arena, "__processPlatform()");
            } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "arch")) {
                try w.appendSlice(arena, "__processArch()");
            } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "pid")) {
                try w.appendSlice(arena, "__processPid()");
            } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "argv")) {
                try w.appendSlice(arena, "__args");
            } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "uptime")) {
                try w.appendSlice(arena, "__processUptime()");
            } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "hrtime")) {
                try w.appendSlice(arena, "__processHrtime(__io)");
            } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "memoryUsage")) {
                try w.appendSlice(arena, "__processMemoryUsage(__io, __alloc)");
            } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "kill")) {
                try w.appendSlice(arena, "__processKill(");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "umask")) {
                try w.appendSlice(arena, "__processUmaskGet()");
            } else if (std.mem.eql(u8, cl.namespace, "process") and std.mem.eql(u8, cl.name, "setUmask")) {
                try w.appendSlice(arena, "__processUmaskSet(");
                try emitExpr(cl.args[0], w, arena);
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
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "randomUUID")) {
                try w.appendSlice(arena, "__cryptoRandomUUID(__io, __alloc)");
            } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "sha256")) {
                try w.appendSlice(arena, "__cryptoSha256(__alloc, ");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "randomBytesBuffer")) {
                try w.appendSlice(arena, "__cryptoRandomBytesBuffer(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "hmacSync")) {
                try w.appendSlice(arena, "__cryptoHmacSync(");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "encryptSync")) {
                try w.appendSlice(arena, "__cryptoEncryptSync(");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[2], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "decryptSync")) {
                try w.appendSlice(arena, "__cryptoDecryptSync(");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[2], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "pbkdf2Sync")) {
                try w.appendSlice(arena, "__cryptoPbkdf2Sync(");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[2], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[3], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "scryptSync")) {
                try w.appendSlice(arena, "__cryptoScryptSync(");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[2], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "timingSafeEqual")) {
                try w.appendSlice(arena, "__cryptoTimingSafeEqual(");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "createHash")) {
                try w.appendSlice(arena, "__cryptoCreateHash(");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "crypto") and std.mem.eql(u8, cl.name, "createHmac")) {
                try w.appendSlice(arena, "__cryptoCreateHmac(");
                try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(cl.args[1], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "readline") and std.mem.eql(u8, cl.name, "question")) {
                try w.appendSlice(arena, "__readlineQuestion(__io, ");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "zlib") and std.mem.eql(u8, cl.name, "gzipSync")) {
                try w.appendSlice(arena, "__zlibCompress(__alloc, .gzip, ");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "zlib") and std.mem.eql(u8, cl.name, "gunzipSync")) {
                try w.appendSlice(arena, "__zlibDecompress(__alloc, .gzip, ");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "zlib") and std.mem.eql(u8, cl.name, "deflateSync")) {
                try w.appendSlice(arena, "__zlibCompress(__alloc, .raw, ");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "zlib") and std.mem.eql(u8, cl.name, "inflateSync")) {
                try w.appendSlice(arena, "__zlibDecompress(__alloc, .raw, ");
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "Promise") and std.mem.eql(u8, cl.name, "resolve")) {
                // Promise.resolve(v) -> an already-resolved promise of v's type.
                const inner = cl.checked_arg_type orelse return error.ParseError;
                try w.print(arena, "__promiseResolved({s}, ", .{try types.zigName(arena, inner)});
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else if (std.mem.eql(u8, cl.namespace, "Worker") and std.mem.eql(u8, cl.name, "run")) {
                // Worker.run(fn) -> spawn fn on a real detached std.Thread,
                // resolving a Promise<T> on the main thread once it finishes.
                const inner = cl.checked_arg_type orelse return error.ParseError;
                try w.print(arena, "__workerRun({s}, ", .{try types.zigName(arena, inner)});
                try emitExpr(cl.args[0], w, arena);
                try w.append(arena, ')');
            } else return error.ParseError;
        },
        .var_ref => |ref| {
            if (ref.builtin_const) |c| {
                try w.appendSlice(arena, c);
                return;
            }
            if (ref.is_func_ref) {
                // A named function used as a function value: a fat pointer whose
                // call thunk ignores ctx and forwards to the real function.
                const sig = ref.func_sig orelse return error.ParseError;
                const sname = try types.funcStructName(arena, sig.*);
                try w.print(arena, "{s}{{ .ctx = undefined, .call = struct {{ fn __t(__ctx: *const anyopaque", .{sname});
                for (sig.params, 0..) |p, i| try w.print(arena, ", __p{d}: {s}", .{ i, try types.zigName(arena, p) });
                try w.print(arena, ") {s} {{ _ = __ctx; return {s}(", .{ try types.zigName(arena, sig.ret.*), ref.emit_name orelse ref.name });
                for (sig.params, 0..) |_, i| {
                    if (i > 0) try w.appendSlice(arena, ", ");
                    try w.print(arena, "__p{d}", .{i});
                }
                try w.appendSlice(arena, "); } }.__t }");
            } else {
                if (ref.capture) try w.appendSlice(arena, "__env."); // captured outer binding
                try w.appendSlice(arena, ref.emit_name orelse ref.name);
                if (ref.is_accumulator) try w.appendSlice(arena, ".items"); // string-builder read
                if (ref.deref) try w.appendSlice(arena, ".*"); // scalar by-reference (`Ref<T>`) param read
                if (ref.unwrap) try w.appendSlice(arena, ".?"); // narrowed optional access
            }
        },
        .neg => |inner| {
            try w.appendSlice(arena, "-(");
            try emitExpr(inner, w, arena);
            try w.append(arena, ')');
        },
        .not => |inner| {
            try w.appendSlice(arena, "!(");
            try emitExpr(inner, w, arena);
            try w.append(arena, ')');
        },
        .bnot => |inner| {
            try w.appendSlice(arena, "~(");
            try emitExpr(inner, w, arena);
            try w.append(arena, ')');
        },
        .await_expr => |inner| {
            // Drive the event loop until the awaited promise resolves, then read
            // its value: (<promise>).await_().
            try w.append(arena, '(');
            try emitExpr(inner, w, arena);
            try w.appendSlice(arena, ").await_()");
        },
        .bin => |b| {
            if (b.op == '+' and b.checked_type != null and b.checked_type.? == .string) {
                var parts: std.ArrayListUnmanaged(*const Expr) = .empty;
                try collectStrConcat(e, &parts, arena);
                try w.appendSlice(arena, "(std.mem.concat(__sa(), u8, &.{ ");
                for (parts.items, 0..) |p, idx| {
                    if (idx > 0) try w.appendSlice(arena, ", ");
                    try emitExpr(p, w, arena);
                }
                try w.appendSlice(arena, " }) catch std.process.exit(1))");
            } else if (b.op == '/') {
                // Float division keeps the fraction (`1.0 / 3.0` -> 0.333...);
                // integer division truncates toward zero (@divTrunc).
                if (b.checked_type != null and b.checked_type.? == .f64) {
                    try w.append(arena, '(');
                    try emitExpr(b.l, w, arena);
                    try w.appendSlice(arena, " / ");
                    try emitExpr(b.r, w, arena);
                    try w.append(arena, ')');
                } else {
                    try w.appendSlice(arena, "@divTrunc(");
                    try emitExpr(b.l, w, arena);
                    try w.appendSlice(arena, ", ");
                    try emitExpr(b.r, w, arena);
                    try w.append(arena, ')');
                }
            } else if (b.op == '%') {
                // Zig's `%` rejects signed operands → use @rem (operands are non-negative here).
                try w.appendSlice(arena, "@rem(");
                try emitExpr(b.l, w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(b.r, w, arena);
                try w.append(arena, ')');
            } else if (b.op == 'L' or b.op == 'R') {
                // Shifts: std.math.shl/shr handle the shift-amount cast for signed ints.
                const ty = try types.zigName(arena, b.checked_type orelse .i32);
                try w.print(arena, "std.math.{s}({s}, ", .{ if (b.op == 'L') "shl" else "shr", ty });
                try emitExpr(b.l, w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(b.r, w, arena);
                try w.append(arena, ')');
            } else if (b.op == 'P') {
                // Exponent: powi for integers, pow for floats.
                const t = b.checked_type orelse .i32;
                const ty = try types.zigName(arena, t);
                if (t == .f64) {
                    try w.print(arena, "std.math.pow({s}, ", .{ty});
                    try emitExpr(b.l, w, arena);
                    try w.appendSlice(arena, ", ");
                    try emitExpr(b.r, w, arena);
                    try w.append(arena, ')');
                } else {
                    try w.print(arena, "(std.math.powi({s}, ", .{ty});
                    try emitExpr(b.l, w, arena);
                    try w.appendSlice(arena, ", ");
                    try emitExpr(b.r, w, arena);
                    try w.appendSlice(arena, ") catch std.process.exit(1))");
                }
            } else {
                try w.append(arena, '(');
                try emitExpr(b.l, w, arena);
                try w.print(arena, " {c} ", .{b.op});
                try emitExpr(b.r, w, arena);
                try w.append(arena, ')');
            }
        },
        .bool_bin => |b| {
            try w.append(arena, '(');
            try emitExpr(b.l, w, arena);
            try w.print(arena, " {s} ", .{if (std.mem.eql(u8, b.op, "&&")) "and" else "or"});
            try emitExpr(b.r, w, arena);
            try w.append(arena, ')');
        },
        .cmp => |b| {
            if (b.checked_operand_type != null and b.checked_operand_type.? == .string and (std.mem.eql(u8, b.op, "==") or std.mem.eql(u8, b.op, "!="))) {
                if (std.mem.eql(u8, b.op, "!=")) try w.append(arena, '!');
                try w.appendSlice(arena, "std.mem.eql(u8, ");
                try emitExpr(b.l, w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(b.r, w, arena);
                try w.append(arena, ')');
            } else if (b.checked_operand_type != null and b.checked_operand_type.? == .string) {
                // Lexicographic string comparison (JS `"a" < "b"`).
                const tail = if (std.mem.eql(u8, b.op, "<"))
                    " == .lt)"
                else if (std.mem.eql(u8, b.op, ">"))
                    " == .gt)"
                else if (std.mem.eql(u8, b.op, "<="))
                    " != .gt)"
                else
                    " != .lt)";
                try w.appendSlice(arena, "(std.mem.order(u8, ");
                try emitExpr(b.l, w, arena);
                try w.appendSlice(arena, ", ");
                try emitExpr(b.r, w, arena);
                try w.append(arena, ')');
                try w.appendSlice(arena, tail);
            } else {
                try w.append(arena, '(');
                try emitExpr(b.l, w, arena);
                try w.print(arena, " {s} ", .{b.op});
                try emitExpr(b.r, w, arena);
                try w.append(arena, ')');
            }
        },
        .ternary => |ternary| {
            try w.appendSlice(arena, "(if (");
            try emitExpr(ternary.cond, w, arena);
            try w.appendSlice(arena, ") ");
            try emitExpr(ternary.then_expr, w, arena);
            try w.appendSlice(arena, " else ");
            try emitExpr(ternary.else_expr, w, arena);
            try w.append(arena, ')');
        },
        .coalesce => |c| {
            try w.append(arena, '(');
            try emitExpr(c.l, w, arena);
            try w.appendSlice(arena, " orelse ");
            try emitExpr(c.r, w, arena);
            try w.append(arena, ')');
        },
        .this_expr => try w.appendSlice(arena, "self"),
        .new_expr => |ne| {
            if (ne.container_type) |ct| {
                // `new Error("msg")` -> the message string (same as `Error(...)`).
                if (ct == .error_obj) {
                    try emitExpr(ne.args[0], w, arena);
                    return;
                }
                // Map/Set: allocate the generic container on the heap.
                const tname = (try types.zigName(arena, ct))[1..]; // strip leading '*'
                try w.print(arena, "{s}.__init()", .{tname});
                return;
            }
            try w.print(arena, "{s}.__init(", .{ne.class_name});
            for (ne.args, 0..) |arg, i| {
                if (i > 0) try w.appendSlice(arena, ", ");
                try emitExpr(arg, w, arena);
            }
            try w.append(arena, ')');
        },
        .method_call => |mc| {
            if (mc.container_type != null and mc.container_type.? == .regexp) {
                // Plan B: if the object is a literal regex, try to emit a
                // specialized straight-line matcher; otherwise fall back to the
                // runtime interpreter over (re).source / (re).flags.
                var specialized = false;
                if (mc.obj.* == .regex) {
                    specialized = try regex_specialize.emitTest(mc.obj.regex.source, mc.obj.regex.flags, mc.args[0], emitExpr, w, arena);
                }
                if (!specialized) {
                    try w.appendSlice(arena, "__lumen_regex.search((");
                    try emitExpr(mc.obj, w, arena);
                    try w.appendSlice(arena, ").source, (");
                    try emitExpr(mc.obj, w, arena);
                    try w.appendSlice(arena, ").flags, ");
                    try emitExpr(mc.args[0], w, arena);
                    try w.append(arena, ')');
                }
            } else if (mc.string_method) {
                try emitStringMethod(mc, w, arena);
            } else if (mc.container_type != null) {
                // Map/Set method: dispatch directly to the runtime container method.
                try emitExpr(mc.obj, w, arena);
                try w.print(arena, ".{s}(", .{mc.name});
                for (mc.args, 0..) |arg, i| {
                    if (i > 0) try w.appendSlice(arena, ", ");
                    try emitExpr(arg, w, arena);
                }
                try w.append(arena, ')');
            } else if (mc.number_method) {
                const recv_type = mc.array_elem_type orelse return error.ParseError;
                if (std.mem.eql(u8, mc.name, "toFixed")) {
                    // Format the numeric receiver as f64 with a runtime precision.
                    try w.appendSlice(arena, "(std.fmt.allocPrint(__sa(), \"{d:.[1]}\", .{ ");
                    if (recv_type == .f64) {
                        try w.appendSlice(arena, "@as(f64, ");
                        try emitExpr(mc.obj, w, arena);
                        try w.append(arena, ')');
                    } else {
                        try w.appendSlice(arena, "@as(f64, @floatFromInt(");
                        try emitExpr(mc.obj, w, arena);
                        try w.appendSlice(arena, "))");
                    }
                    try w.appendSlice(arena, ", @as(usize, @intCast(");
                    try emitExpr(mc.args[0], w, arena);
                    try w.appendSlice(arena, ")) }) catch unreachable)");
                } else if (std.mem.eql(u8, mc.name, "toExponential")) {
                    // Format as f64 exponential, then insert the '+' that Zig
                    // omits before a positive exponent, to match JavaScript.
                    g_number_toexp_seq += 1;
                    const s = g_number_toexp_seq;
                    try w.print(arena, "(__nte{d}: {{ const __raw = std.fmt.allocPrint(__sa(), ", .{s});
                    if (mc.args.len == 1) {
                        try w.appendSlice(arena, "\"{e:.[1]}\", .{ ");
                    } else {
                        try w.appendSlice(arena, "\"{e}\", .{ ");
                    }
                    if (recv_type == .f64) {
                        try w.appendSlice(arena, "@as(f64, ");
                        try emitExpr(mc.obj, w, arena);
                        try w.append(arena, ')');
                    } else {
                        try w.appendSlice(arena, "@as(f64, @floatFromInt(");
                        try emitExpr(mc.obj, w, arena);
                        try w.appendSlice(arena, "))");
                    }
                    if (mc.args.len == 1) {
                        try w.appendSlice(arena, ", @as(usize, @intCast(");
                        try emitExpr(mc.args[0], w, arena);
                        try w.appendSlice(arena, "))");
                    }
                    try w.appendSlice(arena, " }) catch unreachable; ");
                    try w.appendSlice(arena, "var __ob: std.ArrayListUnmanaged(u8) = .empty; for (__raw, 0..) |__c, __ci| { __ob.append(__sa(), __c) catch unreachable; if (__c == 'e' and __ci + 1 < __raw.len and __raw[__ci + 1] != '-') __ob.append(__sa(), '+') catch unreachable; } ");
                    try w.print(arena, "break :__nte{d} @as([]const u8, __ob.items); }})", .{s});
                } else { // toString
                    if (mc.args.len == 1) {
                        // Integer receiver, arbitrary radix, via std.fmt.printInt.
                        g_number_tostring_seq += 1;
                        try w.print(arena, "(__nts{d}: {{ var __b: [72]u8 = undefined; const __n = std.fmt.printInt(&__b, @as(i64, @intCast(", .{g_number_tostring_seq});
                        try emitExpr(mc.obj, w, arena);
                        try w.appendSlice(arena, ")), @as(u8, @intCast(");
                        try emitExpr(mc.args[0], w, arena);
                        try w.print(arena, ")), .lower, .{{}}); break :__nts{d} @as([]const u8, __sa().dupe(u8, __b[0..__n]) catch unreachable); }})", .{g_number_tostring_seq});
                    } else {
                        // Base-10 decimal for any number.
                        try w.appendSlice(arena, "(std.fmt.allocPrint(__sa(), \"{d}\", .{ ");
                        try emitExpr(mc.obj, w, arena);
                        try w.appendSlice(arena, " }) catch unreachable)");
                    }
                }
            } else if (mc.array_result_type != null) {
                try emitArrayMethod(mc, w, arena);
            } else if (mc.is_static) {
                // Class.staticMethod(args) -> Class.__static_m_name(args)
                try w.print(arena, "{s}.__static_m_{s}(", .{ mc.class_name orelse "", mc.name });
                for (mc.args, 0..) |arg, i| {
                    if (i > 0) try w.appendSlice(arena, ", ");
                    try emitExpr(arg, w, arena);
                }
                try w.append(arena, ')');
            } else {
                try emitExpr(mc.obj, w, arena);
                try w.print(arena, ".{s}(", .{mc.name});
                for (mc.args, 0..) |arg, i| {
                    if (i > 0) try w.appendSlice(arena, ", ");
                    try emitExpr(arg, w, arena);
                }
                try w.append(arena, ')');
            }
        },
        .super_call => |sc| {
            // super.method(args) -> self.__super_<owner>_method(args)
            try w.print(arena, "self.__super_{s}_{s}(", .{ sc.parent orelse "", sc.name });
            for (sc.args, 0..) |arg, i| {
                if (i > 0) try w.appendSlice(arena, ", ");
                try emitExpr(arg, w, arena);
            }
            try w.append(arena, ')');
        },
        .arrow => |arrow| {
            const ret = arrow.checked_return_type orelse return error.ParseError;
            // Build the fat-pointer struct name for this signature.
            const params = try arena.alloc(types.Type, arrow.params.len);
            for (arrow.params, 0..) |p, i| params[i] = p.checked_type orelse return error.ParseError;
            const ret_p = try arena.create(types.Type);
            ret_p.* = ret;
            const sname = try types.funcStructName(arena, .{ .params = params, .ret = ret_p });
            const ret_zig = try types.zigName(arena, ret);

            const Local = struct {
                fn emitCallFn(a: std.mem.Allocator, ww: *std.ArrayListUnmanaged(u8), ar: *const ast.ArrowExpr, rz: []const u8, capturing: bool) CompileError!void {
                    try ww.appendSlice(a, "struct { fn __a(__ctx: *const anyopaque");
                    for (ar.params) |p| try ww.print(a, ", {s}: {s}", .{ p.name, try types.zigName(a, p.checked_type.?) });
                    try ww.print(a, ") {s} {{ ", .{rz});
                    if (capturing) {
                        try ww.appendSlice(a, "const __env: *const Env = @ptrCast(@alignCast(__ctx)); ");
                    } else {
                        try ww.appendSlice(a, "_ = __ctx; ");
                    }
                    // JS allows unused parameters; Zig does not. Mark each used
                    // so a body that ignores a parameter still compiles.
                    for (ar.params) |p| {
                        if (!std.mem.eql(u8, p.name, "_")) try ww.print(a, "_ = &{s}; ", .{p.name});
                    }
                    try ww.appendSlice(a, "return ");
                    try emitExpr(ar.body_expr, ww, a);
                    try ww.appendSlice(a, "; } }.__a");
                }
            };

            if (arrow.captures.len == 0) {
                try w.print(arena, "{s}{{ .ctx = undefined, .call = ", .{sname});
                try Local.emitCallFn(arena, w, arrow, ret_zig, false);
                try w.appendSlice(arena, " }");
            } else {
                // (blk: { const Env = struct {...}; const __e = heap; __e.* = {...};
                //         break :blk Fn{ .ctx = __e, .call = struct {...}.__a }; })
                try w.appendSlice(arena, "(blk: { const Env = struct { ");
                for (arrow.captures) |c| try w.print(arena, "{s}: {s}, ", .{ c.emit_name, try types.zigName(arena, c.ty) });
                try w.appendSlice(arena, "}; const __e = __sa().create(Env) catch unreachable; __e.* = .{ ");
                for (arrow.captures) |c| try w.print(arena, ".{s} = {s}, ", .{ c.emit_name, c.emit_name });
                try w.print(arena, "}}; break :blk {s}{{ .ctx = __e, .call = ", .{sname});
                try Local.emitCallFn(arena, w, arrow, ret_zig, true);
                try w.appendSlice(arena, " }; })");
            }
        },
        .template => |parts| {
            // `a${e}b` -> (std.fmt.allocPrint(page, "a{s}b", .{ e }) catch unreachable)
            try w.appendSlice(arena, "(std.fmt.allocPrint(__sa(), \"");
            for (parts) |part| {
                if (part.text) |t| {
                    try emitTemplateText(t, w, arena);
                } else {
                    const spec = switch (part.expr_type orelse types.Type.string) {
                        .string, .string_literal_union => "{s}",
                        .bool => "{}",
                        else => "{d}",
                    };
                    try w.appendSlice(arena, spec);
                }
            }
            try w.appendSlice(arena, "\", .{ ");
            var first = true;
            for (parts) |part| {
                if (part.expr) |hole| {
                    if (!first) try w.appendSlice(arena, ", ");
                    try emitExpr(hole, w, arena);
                    first = false;
                }
            }
            try w.appendSlice(arena, " }) catch unreachable)");
        },
        .obj => |fields| {
            try w.appendSlice(arena, ".{ ");
            for (fields, 0..) |f, i| {
                if (i > 0) try w.appendSlice(arena, ", ");
                try w.print(arena, ".{s} = ", .{f.name});
                try emitExpr(f.value, w, arena);
            }
            try w.appendSlice(arena, " }");
        },
        .field => |fa| {
            if (fa.builtin_const) |lit| {
                // A namespace constant (Math.PI, ...) — a raw f64 literal.
                try w.print(arena, "@as(f64, {s})", .{lit});
                return;
            }
            if (fa.optional_chain) {
                // a?.field  ->  (if (a) |__oc| @as(?T, __oc.field) else null)
                // The @as keeps both branches of the same optional type.
                const ft = try types.zigName(arena, fa.chain_field_type orelse .none);
                try w.appendSlice(arena, "(if (");
                try emitExpr(fa.obj, w, arena);
                try w.print(arena, ") |__oc| @as(?{s}, __oc.", .{ft});
                try emitFieldName(w, arena, fa.name);
                try w.appendSlice(arena, ") else null)");
            } else if (fa.enum_value) |ev| {
                switch (ev) {
                    .int => |n| try w.print(arena, "{d}", .{n}),
                    .str => |s| try emitStrLit(w, arena, s),
                }
            } else if (fa.builtin == .length) {
                try w.appendSlice(arena, "@as(i32, @intCast(");
                try emitExpr(fa.obj, w, arena);
                try w.appendSlice(arena, ".len))");
            } else if (fa.builtin == .container_size) {
                try emitExpr(fa.obj, w, arena);
                try w.appendSlice(arena, ".size()");
            } else if (fa.builtin == .buffer_length) {
                try emitExpr(fa.obj, w, arena);
                try w.appendSlice(arena, ".length()");
            } else if (fa.builtin == .error_message) {
                try emitExpr(fa.obj, w, arena);
            } else if (fa.is_static) {
                // Class.staticField -> Owner.__static_Owner_field
                const owner = fa.class_name orelse "";
                try w.print(arena, "{s}.__static_{s}_{s}", .{ owner, owner, fa.name });
            } else if (fa.is_getter) {
                // obj.prop -> obj.__get_prop()
                try emitExpr(fa.obj, w, arena);
                try w.print(arena, ".__get_{s}()", .{fa.name});
            } else {
                try emitExpr(fa.obj, w, arena);
                try w.appendSlice(arena, ".");
                try emitFieldName(w, arena, fa.name);
            }
        },
        .index => |idx| {
            if (idx.optional_chain) {
                // a?.[i] -> (if (a) |__oc| @as(?E, __oc[i]) else null). The
                // index runs against the unwrapped capture, so re-emit this
                // node with obj swapped to `__oc` and the flag cleared.
                const et = try types.zigName(arena, idx.chain_result_type orelse .none);
                var oc_ref: Expr = .{ .var_ref = .{ .name = "__oc", .emit_name = "__oc" } };
                var inner = idx;
                inner.optional_chain = false;
                inner.obj = &oc_ref;
                var inner_expr: Expr = .{ .index = inner };
                try w.appendSlice(arena, "(if (");
                try emitExpr(idx.obj, w, arena);
                try w.print(arena, ") |__oc| @as(?{s}, ", .{et});
                try emitExpr(&inner_expr, w, arena);
                try w.appendSlice(arena, ") else null)");
                return;
            }
            if (idx.tuple_index) |pos| {
                // Tuple positional access -> struct field `t.@"N"`.
                try emitExpr(idx.obj, w, arena);
                try w.print(arena, ".@\"{d}\"", .{pos});
                return;
            }
            if (idx.string_char) {
                // `s[i]` on a string -> the one-byte substring (a string).
                g_global_pred_seq += 1;
                const s = g_global_pred_seq;
                try w.print(arena, "(__si{d}: {{ const __str = ", .{s});
                try emitExpr(idx.obj, w, arena);
                try w.appendSlice(arena, "; const __ix = @as(usize, @intCast(");
                try emitExpr(idx.value, w, arena);
                try w.print(arena, ")); break :__si{d} @as([]const u8, __str[__ix .. __ix + 1]); }})", .{s});
                return;
            }
            try emitExpr(idx.obj, w, arena);
            try w.appendSlice(arena, "[@as(usize, @intCast(");
            try emitExpr(idx.value, w, arena);
            try w.appendSlice(arena, "))]");
        },
        .optional_call => |oc| {
            // a?.() -> (if (a) |__oc| @as(?R, __oc.call(__oc.ctx, args...)) else
            // null). A Lumen closure value is a `{ ctx, call }` struct (spec
            // 006), not a bare Zig function pointer, so the call-through goes
            // via `.call(.ctx, ...)`, matching the non-optional closure `call`
            // case's `f.call(f.ctx, ...)` emission (~line 233).
            const rt = try types.zigName(arena, oc.chain_result_type orelse .none);
            try w.appendSlice(arena, "(if (");
            try emitExpr(oc.callee, w, arena);
            try w.print(arena, ") |__oc| @as(?{s}, __oc.call(__oc.ctx", .{rt});
            for (oc.args) |arg| {
                try w.appendSlice(arena, ", ");
                try emitExpr(arg, w, arena);
            }
            try w.appendSlice(arena, ")) else null)");
        },
        .cast => |c| {
            // `expr as T` is a checker-only assertion; the runtime value is the
            // same flat struct / scalar, so emit the operand unchanged.
            try emitExpr(c.inner, w, arena);
        },
    }
}

/// A neutral default value for a flat union-struct field, used so a single
/// variant's object literal can omit the other variants' fields.
pub const CompileOptions = struct {
    runtime_locations: bool = true,
    // Threaded down from the CLI's `--wasm` flag (spec 049): wasm32-wasi has
    // no real OS threads, and the CLI's own libxev-wiring gate hard-fails any
    // wasm build whose generated source textually contains `@import("xev")`
    // (see `compileFile` in `lumen.zig`) -- so `http.createServer`'s
    // thread-pool-backed concurrent codegen must not emit that import at all
    // under `--wasm`, falling back to the old single-connection-at-a-time
    // loop there instead.
    wasm: bool = false,
};

/// Collect the inheritance chain from a root ancestor down to `c` (inclusive).
var g_program: ?*const Program = null;

// Gives each emitted `String.fromCharCode(...)` block a unique label so nested
// calls don't collide.
var g_from_char_code_seq: usize = 0;

// Unique labels for `number.toString(radix)` blocks.
var g_number_tostring_seq: usize = 0;

// Unique labels for `number.toExponential(...)` blocks.
var g_number_toexp_seq: usize = 0;

// Unique labels for global isNaN/isFinite predicate blocks.
var g_global_pred_seq: usize = 0;

// The Zig spelling of an async function's resolved value type while emitting its
// body, so a `return v;` lowers to `return __promiseResolved(<T>, v);`. Null
// outside an async body (and for plain functions).
pub var g_async_inner: ?[]const u8 = null;

// Destination-passing: string-builder functions (build an accumulator, return it)
// also get an `f__into(dest, …)` form that appends straight into a caller buffer,
// avoiding the intermediate build+copy. `g_dest_acc` maps such a function name to
// its accumulator's name; `g_cur_into_acc` is set while emitting an `__into` body.
pub var g_dest_acc: ?*std.StringHashMapUnmanaged([]const u8) = null;
pub var g_cur_into_acc: ?[]const u8 = null;

pub fn findClass(name: []const u8) ?*const ast.ClassDecl {
    const prog = g_program orelse return null;
    for (prog.stmts) |*stmt| {
        if (stmt.* == .class_decl and std.mem.eql(u8, stmt.class_decl.name, name)) return &stmt.class_decl;
    }
    return null;
}

pub fn emitProgram(program: *const Program, decls: *std.ArrayListUnmanaged(u8), body: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, options: CompileOptions) CompileError!void {
    g_program = program;
    for (program.stmts) |*stmt| try emitStmt(stmt, decls, body, arena, options);
}
