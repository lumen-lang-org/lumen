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
const emit_static = @import("lumen_emit_static.zig");
const ast = @import("lumen_ast.zig");
const types = @import("lumen_types.zig");
const diag_mod = @import("lumen_diag.zig");
const lumen_opt = @import("lumen_opt.zig");
const regex_specialize = @import("regex_specialize.zig");
const array_string = @import("lumen_emit_array_string.zig");
const emit_stmt = @import("lumen_emit_stmt.zig");
const analysis = @import("lumen_emit_analysis.zig");

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
/// Field names that collide with Zig keywords/primitives must be spelled
/// `@"name"` in the generated code (spec 282). TS happily allows them.
fn isZigReservedField(name: []const u8) bool {
    const reserved = [_][]const u8{ "error", "test", "var", "const", "fn", "type", "pub", "if", "else", "while", "for", "return", "switch", "struct", "enum", "union", "defer", "try", "catch", "and", "or", "break", "continue", "export", "extern", "inline", "noalias", "comptime", "unreachable", "async", "await", "suspend", "resume", "opaque", "orelse", "align", "callconv", "anytype", "volatile", "null", "true", "false", "undefined" };
    for (reserved) |kw| {
        if (std.mem.eql(u8, name, kw)) return true;
    }
    return false;
}

pub fn emitFieldName(w: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, name: []const u8) CompileError!void {
    if ((name.len > 0 and name[0] == '#') or isZigReservedField(name)) {
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
        // formatting match JS's double semantics. Use `{e}` (shortest
        // round-trip scientific) rather than `{d}`: `{d}` expands a large
        // magnitude like `1e308` to a 309-digit integer literal that Zig cannot
        // coerce to f64, whereas `{e}` always yields a valid float literal.
        .float => |v| try w.print(arena, "@as(f64, {e})", .{v}),
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
            } else if (arr.heap_elem) |het| {
                // A spread-free literal: heap-allocate the elements (page
                // allocator, allocate-and-leak) so the slice can escape a
                // `return` or be stored, rather than pointing at a stack tuple
                // (`&.{...}`) that dangles once the enclosing frame returns.
                const ez = try types.zigName(arena, het);
                g_global_pred_seq += 1;
                const s = g_global_pred_seq;
                // The temp is seq-suffixed so a nested array literal (`[[1],[2]]`)
                // doesn't shadow the outer one's `__r` (spec 289).
                try w.print(arena, "(__arl{d}: {{ const __r{d} = __sa().alloc({s}, {d}) catch unreachable; ", .{ s, s, ez, arr.items.len });
                for (arr.items, 0..) |item, i| {
                    try w.print(arena, "__r{d}[{d}] = ", .{ s, i });
                    try emitExpr(item, w, arena);
                    try w.appendSlice(arena, "; ");
                }
                try w.print(arena, "break :__arl{d} @as([]const {s}, __r{d}); }})", .{ s, ez, s });
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
                try w.appendSlice(arena, "@as(i32, @intCast(__lumen_argv.len))");
            } else if (std.mem.eql(u8, cl.name, "arg")) {
                try w.appendSlice(arena, "(if (@as(usize, @intCast(");
                if (cl.args.len > 0) try emitExpr(cl.args[0], w, arena);
                try w.appendSlice(arena, ")) < __lumen_argv.len) __lumen_argv[@as(usize, @intCast(");
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
                // Exception propagation (spec 245): a call to a throwing
                // function comes back as an error union. Inside a try body the
                // error routes to the catch (set the slot, break out); inside
                // another throwing function it forwards with `try`; anywhere
                // else it is uncaught -- panic with the thrown message so the
                // runtime error/trace machinery reports it.
                const callee_throws = analysis.fnThrows(cl.emit_name orelse cl.name);
                if (callee_throws) {
                    if (g_throw_target != null) {
                        try w.appendSlice(arena, "(");
                    } else if (g_fn_can_error) {
                        try w.appendSlice(arena, "(try ");
                    } else {
                        try w.appendSlice(arena, "(");
                    }
                }
                // A `string` return from an extern function arrives as a raw
                // `[*:0]const u8`; copy it once into an owned Lumen string so the
                // value outlives the C buffer.
                if (cl.ffi_string_return) try w.appendSlice(arena, "(__alloc.dupe(u8, std.mem.span(");
                try w.print(arena, "{s}(", .{try safeGlobalName(arena, cl.emit_name orelse cl.name)});
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
                if (analysis.fnThrows(cl.emit_name orelse cl.name)) {
                    if (g_throw_target) |slot| {
                        const label = try std.mem.replaceOwned(u8, arena, slot, "__lumen_throw_", "__lumen_try_");
                        try w.print(arena, " catch {{ {s} = __lumen_err_msg; break :{s}; }})", .{ slot, label });
                    } else if (g_fn_can_error) {
                        try w.appendSlice(arena, ")");
                    } else {
                        try w.appendSlice(arena, " catch @panic(__lumen_err_msg))");
                    }
                }
            }
        },
        .static_call => |cl| try emit_static.emitStaticCall(cl, w, arena),
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
                try w.print(arena, ") {s} {{ _ = __ctx; return {s}(", .{ try types.zigName(arena, sig.ret.*), try safeGlobalName(arena, ref.emit_name orelse ref.name) });
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
        .inc_dec => |id| {
            const op = if (id.is_inc) "+= 1" else "-= 1";
            g_global_pred_seq += 1;
            const s = g_global_pred_seq;
            if (id.is_prefix) {
                // ++x: increment, then yield the new value.
                try w.print(arena, "(__id{d}: {{ ", .{s});
                try emitExpr(id.target, w, arena);
                try w.print(arena, " {s}; break :__id{d} ", .{ op, s });
                try emitExpr(id.target, w, arena);
                try w.appendSlice(arena, "; })");
            } else {
                // x++: yield the old value, then increment.
                const tz = try types.zigName(arena, id.checked_type orelse .i32);
                try w.print(arena, "(__id{d}: {{ const __o: {s} = ", .{ s, tz });
                try emitExpr(id.target, w, arena);
                try w.appendSlice(arena, "; ");
                try emitExpr(id.target, w, arena);
                try w.print(arena, " {s}; break :__id{d} __o; }})", .{ op, s });
            }
        },
        .typeof_expr => |to| {
            // A compile-time constant string (the operand's static type name).
            // The operand is still evaluated and discarded so its side effects
            // run and its binding counts as used.
            g_global_pred_seq += 1;
            const s = g_global_pred_seq;
            try w.print(arena, "(__tof{d}: {{ _ = ", .{s});
            try emitExpr(to.operand, w, arena);
            try w.print(arena, "; break :__tof{d} @as([]const u8, ", .{s});
            try emitStrLit(w, arena, to.result orelse "object");
            try w.appendSlice(arena, "); })");
        },
        .instanceof_expr => |io| {
            // Compile-time verdict; evaluate (discard) the operand.
            g_global_pred_seq += 1;
            const s = g_global_pred_seq;
            try w.print(arena, "(__iof{d}: {{ _ = &(", .{s});
            try emitExpr(io.value, w, arena);
            try w.print(arena, "); break :__iof{d} {s}; }})", .{ s, if (io.result orelse false) "true" else "false" });
        },
        .not => |inner| {
            try w.appendSlice(arena, "!(");
            try emitExpr(inner, w, arena);
            try w.append(arena, ')');
        },
        .non_null => |nn| {
            // `x!` — unwrap an optional (`.?`, panics if null). A no-op when the
            // operand is not optional.
            if (nn.unwraps) {
                try w.append(arena, '(');
                try emitExpr(nn.inner, w, arena);
                try w.appendSlice(arena, ").?");
            } else {
                try emitExpr(nn.inner, w, arena);
            }
        },
        .bnot => |inner| {
            // Bitwise NOT needs a fixed-width operand: `~` on a bare
            // `comptime_int` literal (`~5`) is a Zig error. Pin to i32 (JS
            // bitwise operates on 32-bit integers), which is a no-op for an
            // already-i32 operand.
            try w.appendSlice(arena, "~(@as(i32, ");
            try emitExpr(inner, w, arena);
            try w.appendSlice(arena, "))");
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
            if (b.opt_cmp != 0) {
                // `optional === value`: null compares unequal; otherwise unwrap
                // and compare the inner value.
                const opt_side = if (b.opt_cmp == 1) b.l else b.r;
                const val_side = if (b.opt_cmp == 1) b.r else b.l;
                const is_neq = std.mem.eql(u8, b.op, "!=");
                const inner_str = b.checked_operand_type != null and b.checked_operand_type.? == .string;
                try w.appendSlice(arena, "(if (");
                try emitExpr(opt_side, w, arena);
                try w.appendSlice(arena, ") |__ov| (");
                if (inner_str) {
                    if (is_neq) try w.append(arena, '!');
                    try w.appendSlice(arena, "std.mem.eql(u8, __ov, ");
                    try emitExpr(val_side, w, arena);
                    try w.append(arena, ')');
                } else {
                    try w.appendSlice(arena, "__ov ");
                    try w.appendSlice(arena, if (is_neq) "!= " else "== ");
                    try emitExpr(val_side, w, arena);
                }
                try w.print(arena, ") else {s})", .{if (is_neq) "true" else "false"});
                return;
            }
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
            // When a branch is `null`, both branches are cast to `?T` so Zig's
            // peer-type resolution keeps the whole expression optional (spec 303).
            if (ternary.result_type) |rt| {
                const rz = try types.zigName(arena, rt);
                try w.appendSlice(arena, "(if (");
                try emitExpr(ternary.cond, w, arena);
                try w.print(arena, ") @as({s}, ", .{rz});
                try emitExpr(ternary.then_expr, w, arena);
                try w.print(arena, ") else @as({s}, ", .{rz});
                try emitExpr(ternary.else_expr, w, arena);
                try w.appendSlice(arena, "))");
                return;
            }
            try w.appendSlice(arena, "(if (");
            try emitExpr(ternary.cond, w, arena);
            try w.appendSlice(arena, ") ");
            try emitExpr(ternary.then_expr, w, arena);
            try w.appendSlice(arena, " else ");
            try emitExpr(ternary.else_expr, w, arena);
            try w.append(arena, ')');
        },
        .coalesce => |c| {
            // `l ?? r` as `if (l) |__cv| __cv else r`. Unlike `l orelse r`, this
            // keeps the result optional when `r` is itself optional (a chained
            // `a ?? b ?? d`), via Zig peer-type resolution of the two branches.
            g_global_pred_seq += 1;
            const s = g_global_pred_seq;
            // Pin the then-branch to the result type so Zig peer-resolution keeps
            // the whole expression optional when `r` is optional (chained `??`).
            const rt = try types.zigName(arena, c.result_type orelse .none);
            try w.appendSlice(arena, "(if (");
            try emitExpr(c.l, w, arena);
            try w.print(arena, ") |__cv{d}| @as({s}, __cv{d}) else ", .{ s, rt, s });
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
                // `new Set([1,2,3])`: init then add each element.
                if (ct == .set_type and ne.args.len == 1) {
                    const elem = ct.set_type.*;
                    const ez = try types.zigName(arena, elem);
                    g_global_pred_seq += 1;
                    const s = g_global_pred_seq;
                    try w.print(arena, "(__seti{d}: {{ const __c = {s}.__init(); const __src = ", .{ s, tname });
                    if (ne.args[0].* == .array and ne.args[0].array.elem_type == null) {
                        try w.print(arena, "@as([]const {s}, ", .{ez});
                        try emitExpr(ne.args[0], w, arena);
                        try w.append(arena, ')');
                    } else {
                        try emitExpr(ne.args[0], w, arena);
                    }
                    try w.print(arena, "; for (__src) |__e| {{ __c.add(__e); }} break :__seti{d} __c; }})", .{s});
                    return;
                }
                // `new Map([[k, v], ...])`: init then set each entry.
                if (ct == .map_type and ne.args.len == 1 and ne.args[0].* == .array) {
                    g_global_pred_seq += 1;
                    const s = g_global_pred_seq;
                    try w.print(arena, "(__mapi{d}: {{ const __c = {s}.__init(); ", .{ s, tname });
                    for (ne.args[0].array.items) |entry| {
                        try w.appendSlice(arena, "__c.set(");
                        try emitExpr(entry.array.items[0], w, arena);
                        try w.appendSlice(arena, ", ");
                        try emitExpr(entry.array.items[1], w, arena);
                        try w.appendSlice(arena, "); ");
                    }
                    try w.print(arena, "break :__mapi{d} __c; }})", .{s});
                    return;
                }
                try w.print(arena, "{s}.__init()", .{tname});
                return;
            }
            const ctor_throws = analysis.g_method_arena != null and analysis.ctorThrows(analysis.g_method_arena.?, ne.class_name);
            if (ctor_throws) try emitThrowingCallPrefix(w, arena);
            try w.print(arena, "{s}.__init(", .{ne.class_name});
            for (ne.args, 0..) |arg, i| {
                if (i > 0) try w.appendSlice(arena, ", ");
                try emitExpr(arg, w, arena);
            }
            try w.append(arena, ')');
            if (ctor_throws) try emitThrowingCallSuffix(w, arena);
        },
        .method_call => |mc| {
            if (mc.sized_fill) {
                // `new Array(n).fill(v)` / `Array(n).fill(v)`: allocate an
                // n-length slice and memset every element to v.
                const et = mc.array_elem_type orelse return error.ParseError;
                const ez = try types.zigName(arena, et);
                const n_expr = switch (mc.obj.*) {
                    .new_expr => |ne| ne.args[0],
                    .call => |c| c.args[0],
                    else => return error.ParseError,
                };
                g_global_pred_seq += 1;
                const s = g_global_pred_seq;
                try w.print(arena, "(__sf{d}: {{ const __n: usize = @intCast(", .{s});
                try emitExpr(n_expr, w, arena);
                try w.print(arena, "); const __r = __sa().alloc({s}, __n) catch unreachable; @memset(__r, ", .{ez});
                try emitExpr(mc.args[0], w, arena);
                try w.print(arena, "); break :__sf{d} @as([]const {s}, __r); }})", .{ s, ez });
                return;
            }
            if (mc.is_console) {
                // console.log/... as a void expression: print, then yield {}.
                // Every argument was wrapped to a string by the checker, so each
                // formats with "{s}", space-separated (JS semantics).
                g_global_pred_seq += 1;
                const s = g_global_pred_seq;
                try w.print(arena, "(__cl{d}: {{ ", .{s});
                const prefix = if (std.mem.eql(u8, mc.name, "log") or std.mem.eql(u8, mc.name, "info") or std.mem.eql(u8, mc.name, "debug"))
                    "__consoleOut(\""
                else if (std.mem.eql(u8, mc.name, "trace"))
                    "std.debug.print(\"Trace: "
                else
                    "std.debug.print(\"";
                try w.appendSlice(arena, prefix);
                for (mc.args, 0..) |_, i| {
                    if (i > 0) try w.appendSlice(arena, " ");
                    try w.appendSlice(arena, "{s}");
                }
                try w.appendSlice(arena, "\\n\", .{");
                for (mc.args, 0..) |arg, i| {
                    if (i > 0) try w.appendSlice(arena, ", ");
                    try emitExpr(arg, w, arena);
                }
                try w.print(arena, "}}); break :__cl{d} {{}}; }})", .{s});
                return;
            }
            if (mc.container_type != null and mc.container_type.? == .error_obj) {
                // e.toString() -> "Error: " ++ message (error_obj is the message).
                try w.appendSlice(arena, "(std.mem.concat(__sa(), u8, &.{ \"Error: \", ");
                try emitExpr(mc.obj, w, arena);
                try w.appendSlice(arena, " }) catch unreachable)");
            } else if (mc.container_type != null and mc.container_type.? == .regexp) {
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
                } else if (std.mem.eql(u8, mc.name, "toPrecision")) {
                    // Significant-digit formatting via the __numToPrecision helper.
                    try w.appendSlice(arena, "__numToPrecision(");
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
                    try w.appendSlice(arena, ")))");
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
                const throws = analysis.g_method_arena != null and analysis.methodThrows(analysis.g_method_arena.?, mc.name);
                if (throws) try emitThrowingCallPrefix(w, arena);
                // Class.staticMethod(args) -> Class.__static_m_name(args)
                try w.print(arena, "{s}.__static_m_{s}(", .{ mc.class_name orelse "", mc.name });
                for (mc.args, 0..) |arg, i| {
                    if (i > 0) try w.appendSlice(arena, ", ");
                    try emitExpr(arg, w, arena);
                }
                try w.append(arena, ')');
                if (throws) try emitThrowingCallSuffix(w, arena);
            } else {
                const throws = mc.class_name != null and analysis.g_method_arena != null and analysis.methodThrows(analysis.g_method_arena.?, mc.name);
                if (throws) try emitThrowingCallPrefix(w, arena);
                try emitExpr(mc.obj, w, arena);
                try w.print(arena, ".{s}(", .{mc.name});
                for (mc.args, 0..) |arg, i| {
                    if (i > 0) try w.appendSlice(arena, ", ");
                    try emitExpr(arg, w, arena);
                }
                try w.append(arena, ')');
                if (throws) try emitThrowingCallSuffix(w, arena);
            }
        },
        .super_call => |sc| {
            const throws = analysis.g_method_arena != null and analysis.methodThrows(analysis.g_method_arena.?, sc.name);
            if (throws) try emitThrowingCallPrefix(w, arena);
            // super.method(args) -> self.__super_<owner>_method(args)
            try w.print(arena, "self.__super_{s}_{s}(", .{ sc.parent orelse "", sc.name });
            for (sc.args, 0..) |arg, i| {
                if (i > 0) try w.appendSlice(arena, ", ");
                try emitExpr(arg, w, arena);
            }
            try w.append(arena, ')');
            if (throws) try emitThrowingCallSuffix(w, arena);
        },
        .arrow => |arrow| {
            // An arrow body is its own (non-error-union) function: calls to
            // throwing functions inside it must not `try`-forward or break to
            // an outer try label across the function boundary (spec 245).
            const saved_can_error = g_fn_can_error;
            const saved_throw_target = g_throw_target;
            g_fn_can_error = false;
            g_throw_target = null;
            defer {
                g_fn_can_error = saved_can_error;
                g_throw_target = saved_throw_target;
            }
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
                    try ww.appendSlice(a, "struct { fn __afn(__ctx: *const anyopaque");
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
                    // Stack-trace frame: named after the binding when known
                    // (`const g = ... => ...` traces as `g`), else <anonymous>.
                    if (g_options.?.runtime_locations) {
                        try ww.print(a, "__lumenPush(\"{s}\"); defer __lumenPop(); ", .{ar.name_hint orelse "<anonymous>"});
                    }
                    if (ar.body_block) |block| {
                        // Statement-body arrow (a void body): emit the statements,
                        // no trailing return. Statements emit their decls and code
                        // into the same buffer (a nested named decl in an arrow
                        // body is not part of this subset).
                        try ww.appendSlice(a, "\n");
                        for (block) |*stmt| try emit_stmt.emitStmtWithThrow(stmt, ww, ww, a, null, null, g_options.?);
                        try ww.appendSlice(a, "} }.__afn");
                    } else {
                        try ww.appendSlice(a, "return ");
                        try emitExpr(ar.body_expr.?, ww, a);
                        try ww.appendSlice(a, "; } }.__afn");
                    }
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
                try w.append(arena, '.');
                try emitFieldName(w, arena, f.name);
                try w.appendSlice(arena, " = ");
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
                try w.print(arena, ") |__oc| @as(?{s}, ", .{ft});
                // A builtin field (`?.length`/`?.size`) lowers to its Zig form on
                // the unwrapped value, not a literal `.length` member.
                if (fa.builtin == .length or fa.builtin == .buffer_length) {
                    try w.appendSlice(arena, "@as(i32, @intCast(__oc.len))");
                } else if (fa.builtin == .container_size) {
                    try w.appendSlice(arena, "__oc.size()");
                } else {
                    try w.appendSlice(arena, "__oc.");
                    try emitFieldName(w, arena, fa.name);
                }
                try w.appendSlice(arena, ") else null)");
            } else if (fa.enum_value) |ev| {
                switch (ev) {
                    .int => |n| try w.print(arena, "{d}", .{n}),
                    .str => |s| try emitStrLit(w, arena, s),
                }
            } else if (fa.builtin == .length) {
                // A bare array-literal receiver lowers to a tuple, which has no
                // runtime `.len`; but with no spread element (elem_type == null)
                // its length is the static item count. Emit that directly.
                if (fa.obj.* == .array and fa.obj.array.elem_type == null) {
                    try w.print(arena, "@as(i32, {d})", .{fa.obj.array.items.len});
                } else {
                    try w.appendSlice(arena, "@as(i32, @intCast(");
                    try emitExpr(fa.obj, w, arena);
                    try w.appendSlice(arena, ".len))");
                }
            } else if (fa.builtin == .container_size) {
                try emitExpr(fa.obj, w, arena);
                try w.appendSlice(arena, ".size()");
            } else if (fa.builtin == .buffer_length) {
                try emitExpr(fa.obj, w, arena);
                try w.appendSlice(arena, ".length()");
            } else if (fa.builtin == .error_message) {
                try emitExpr(fa.obj, w, arena);
            } else if (fa.builtin == .error_name) {
                // Always "Error"; evaluate (discard) the receiver for any side effect.
                g_global_pred_seq += 1;
                try w.print(arena, "(__en{d}: {{ _ = &(", .{g_global_pred_seq});
                try emitExpr(fa.obj, w, arena);
                try w.print(arena, "); break :__en{d} @as([]const u8, \"Error\"); }})", .{g_global_pred_seq});
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
                if (fa.unwrap) try w.appendSlice(arena, ".?"); // narrowed optional field (spec 261)
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
            // A bare array-literal receiver lowers to a tuple; wrap it in a real
            // slice so a runtime index works (`["a","b"][x]`).
            if (idx.obj.* == .array and idx.obj.array.elem_type == null and idx.checked_element_type != null) {
                try w.print(arena, "@as([]const {s}, ", .{try types.zigName(arena, idx.checked_element_type.?)});
                try emitExpr(idx.obj, w, arena);
                try w.append(arena, ')');
            } else {
                try emitExpr(idx.obj, w, arena);
            }
            try w.appendSlice(arena, "[@as(usize, @intCast(");
            try emitExpr(idx.value, w, arena);
            try w.appendSlice(arena, "))]");
        },
        .optional_call => |oc| {
            // A direct value call `f()` on a computed function value (spec 298):
            // evaluate the callee once, then call through its `{ ctx, call }`
            // fat pointer.
            if (!oc.optional_chain) {
                g_global_pred_seq += 1;
                const s = g_global_pred_seq;
                try w.print(arena, "(__vc{d}: {{ const __f = ", .{s});
                try emitExpr(oc.callee, w, arena);
                try w.print(arena, "; break :__vc{d} __f.call(__f.ctx", .{s});
                for (oc.args) |arg| {
                    try w.appendSlice(arena, ", ");
                    try emitExpr(arg, w, arena);
                }
                try w.appendSlice(arena, "); })");
                return;
            }
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
    // When set, non-fatal diagnostics (unused variables, ...) are appended here
    // for the caller to render after the compile.
    warnings: ?*std.ArrayListUnmanaged(@import("lumen_diag.zig").Diag) = null,
    // Merged-line origins from import inlining; when non-empty the generated
    // runtime remaps panic positions and stack frames to the original files.
    line_map: []const @import("lumen_diag.zig").LineOrigin = &.{},
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
pub var g_program: ?*const Program = null;

/// Compile options captured at program-emit time so nested emitters (a
/// statement-body arrow) can reach them without threading them through every
/// `emitExpr` call.
pub var g_options: ?CompileOptions = null;

// Gives each emitted `String.fromCharCode(...)` block a unique label so nested
// calls don't collide.
pub var g_from_char_code_seq: usize = 0;

// Unique labels for `number.toString(radix)` blocks.
pub var g_number_tostring_seq: usize = 0;

// Unique labels for `number.toExponential(...)` blocks.
pub var g_number_toexp_seq: usize = 0;

// Unique labels for global isNaN/isFinite predicate blocks.
pub var g_global_pred_seq: usize = 0;

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

// Exception propagation (spec 245): the innermost try's throw slot while its
// body is being emitted (calls to throwing functions route errors there), and
// whether the function being emitted returns an error union (calls forward
// with `try`). Saved/restored around nested statement and arrow emission.
pub var g_throw_target: ?[]const u8 = null;
pub var g_fn_can_error: bool = false;

/// Opens a throwing-call wrapper by context (spec 245): a plain paren inside
/// a try body or at an uncaught site, `(try ` when forwarding from another
/// throwing function. Closed by `emitThrowingCallSuffix`.
pub fn emitThrowingCallPrefix(w: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    if (g_throw_target == null and g_fn_can_error) {
        try w.appendSlice(arena, "(try ");
    } else {
        try w.appendSlice(arena, "(");
    }
}

/// Closes a throwing-call wrapper: route to the enclosing try's catch slot,
/// nothing extra when `try`-forwarded, else panic with the thrown message.
pub fn emitThrowingCallSuffix(w: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    if (g_throw_target) |slot| {
        const label = try std.mem.replaceOwned(u8, arena, slot, "__lumen_throw_", "__lumen_try_");
        try w.print(arena, " catch {{ {s} = __lumen_err_msg; break :{s}; }})", .{ slot, label });
    } else if (g_fn_can_error) {
        try w.appendSlice(arena, ")");
    } else {
        try w.appendSlice(arena, " catch @panic(__lumen_err_msg))");
    }
}

/// A user function whose name collides with a generated-code global (`main`,
/// `std`, `xev`, `builtin`) emits under a prefixed name; stack-trace frames
/// and diagnostics keep the source name (spec 246).
pub fn safeGlobalName(arena: std.mem.Allocator, name: []const u8) CompileError![]const u8 {
    const eq = std.mem.eql;
    // A user global function whose name is a Zig keyword can't be emitted bare,
    // and one that matches a generated runtime helper's parameter name (`name`,
    // `value`, ...) would be shadowed by that parameter ("shadows declaration").
    // Both classes are renamed to a reserved prefix; call sites, function-ref
    // wrappers, and the declaration all route through this function, so the
    // rename stays consistent.
    if (isZigReservedField(name)) {
        return std.fmt.allocPrint(arena, "__lumen_user_{s}", .{name});
    }
    const collide = [_][]const u8{ "main", "std", "xev", "builtin", "cb", "chunk", "data", "encoding", "i", "key", "name", "other", "start", "v", "value", "bytes", "ctx", "io", "t", "self", "Self" };
    for (collide) |c| {
        if (eq(u8, name, c)) return std.fmt.allocPrint(arena, "__lumen_user_{s}", .{name});
    }
    return name;
}

pub fn findClass(name: []const u8) ?*const ast.ClassDecl {
    const prog = g_program orelse return null;
    for (prog.stmts) |*stmt| {
        if (stmt.* == .class_decl and std.mem.eql(u8, stmt.class_decl.name, name)) return &stmt.class_decl;
    }
    return null;
}

/// A type whose top-level binding can be promoted to a module global
/// (declared `undefined`, initialized in `main`) so functions can reference it.
/// Its initializer must emit as a self-contained expression — true for scalars,
/// arrays, records, tuples, maps/sets, and optionals. Function/closure values
/// (which carry captures) and value-less types are excluded.
fn promotableType(t: types.Type) bool {
    return switch (t) {
        .func_type, .void, .none => false,
        else => true,
    };
}

/// Whether any function/method/constructor body references `name` (so a
/// top-level binding of that name must live at module scope, not in `main`).
fn referencedByFunction(program: *const Program, name: []const u8) bool {
    for (program.stmts) |*stmt| {
        switch (stmt.*) {
            .function_decl => |*f| if (bodyUsesName(f.body, name)) return true,
            .class_decl => |*c| {
                for (c.methods) |m| if (bodyUsesName(m.body, name)) return true;
                if (bodyUsesName(c.ctor_body, name)) return true;
            },
            else => {},
        }
    }
    return false;
}

pub fn emitProgram(program: *const Program, decls: *std.ArrayListUnmanaged(u8), body: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, options: CompileOptions) CompileError!void {
    g_program = program;
    g_options = options;
    for (program.stmts) |*stmt| {
        // A top-level scalar binding referenced from within a function can't be
        // a `main` local (Zig functions don't see them); emit it as a module
        // global declared `undefined` and assigned at its top-level position in
        // `main`, preserving evaluation order and side effects.
        if (stmt.* == .var_decl) {
            const d = &stmt.var_decl;
            if (d.checked_type) |t| {
                if (promotableType(t) and !d.is_accumulator and referencedByFunction(program, d.name)) {
                    const nm = d.emit_name orelse d.name;
                    try decls.print(arena, "var {s}: {s} = undefined;\n", .{ nm, try types.zigName(arena, t) });
                    if (!d.no_init) {
                        try body.print(arena, "    {s} = ", .{nm});
                        try emitExpr(d.init, body, arena);
                        try body.appendSlice(arena, ";\n");
                    }
                    continue;
                }
            }
        }
        try emitStmt(stmt, decls, body, arena, options);
    }
}
