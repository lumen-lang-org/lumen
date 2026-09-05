//! Expression codegen for the node target: the `Expr`-union counterpart of
//! `lumen_emit.zig`'s `emitExpr`, printing JavaScript.
//!
//! Most arms print the source form back. The ones that do not are the
//! checker's Zig-motivated rewrites, listed in spec 504's plan.md (§Risks):
//! `String(x)`/`Number(x)` wrappers (identity in JavaScript), `float_to_int`
//! casts (`Math.trunc`), ternary/coalesce result casts (erased), and
//! `for (const [i, v] of arr.entries())` whose iterable the checker rewrote to
//! the bare array (rebuilt in the statement emitter).

const std = @import("std");
const ast = @import("lumen_ast.zig");
const js = @import("lumen_emit_js.zig");
const js_stmt = @import("lumen_emit_js_stmt.zig");
const js_stdlib = @import("lumen_emit_js_stdlib.zig");

const Emitter = js.Emitter;
const CompileError = js.CompileError;
const Expr = ast.Expr;

/// Binding strength of an expression's outermost operator, JavaScript's
/// table: a ternary binds loosest, a member access or call tightest. An
/// operand is parenthesized only when it binds more loosely than the
/// position it lands in, so `a + b * c` and `(a + b) * c` both read as
/// written.
fn prec(x: *const Expr) i8 {
    return switch (x.*) {
        .arrow => -1,
        .ternary => 0,
        .coalesce => 1,
        .bool_bin => |b| if (std.mem.eql(u8, b.op, "||")) 2 else 3,
        .bin => |b| if (isIntDivision(b)) PREC_MEMBER else switch (b.op) {
            '|' => 4,
            '^' => 5,
            '&' => 6,
            'L', 'R' => 9,
            '+', '-' => 10,
            'P' => 12,
            else => 11,
        },
        .cmp => |c| if (std.mem.eql(u8, c.op, "==") or std.mem.eql(u8, c.op, "!=")) 7 else 8,
        .instanceof_expr => 8,
        .neg, .not, .bnot, .typeof_expr, .await_expr => 13,
        .inc_dec => |i| if (i.is_prefix) 13 else 14,
        .cast => |c| if (c.float_to_int) 14 else prec(c.inner),
        .non_null => |n| prec(n.inner),
        else => 14,
    };
}

const PREC_UNARY: i8 = 13;
const PREC_MEMBER: i8 = 14;

/// Whether a `/` divides integers, so it truncates toward zero (spec 137):
/// the native emitter picks `@divTrunc` unless the checker typed the result
/// `number`, and this target mirrors that decision with `__lang.divInt`.
fn isIntDivision(b: anytype) bool {
    return b.op == '/' and (b.checked_type == null or b.checked_type.? != .f64);
}

/// Emits `x` where an expression binding at least as tightly as `min` is
/// expected, parenthesizing it otherwise.
fn emitAt(e: *Emitter, x: *const Expr, min: i8) CompileError!void {
    if (prec(x) < min) {
        try e.byte('(');
        try emitExpr(e, x);
        try e.byte(')');
    } else {
        try emitExpr(e, x);
    }
}

/// The receiver of a member access or call: a literal that JavaScript would
/// misread in that position (`{}.x` is a block, `1.x` a number) is
/// parenthesized too.
fn emitReceiver(e: *Emitter, x: *const Expr) CompileError!void {
    switch (x.*) {
        .obj, .num, .float => {
            try e.byte('(');
            try emitExpr(e, x);
            try e.byte(')');
        },
        else => try emitAt(e, x, PREC_MEMBER),
    }
}

pub fn emitArgs(e: *Emitter, args: []const *Expr) CompileError!void {
    try emitArgsFor(e, args, &.{});
}

/// The argument list of a call to `params`. The checker packed the arguments
/// for a `...rest` parameter into one array literal (the native rest is a
/// slice); JavaScript's rest parameter collects them itself, so the packed
/// literal is spliced back into the list, its own spreads kept.
pub fn emitArgsFor(e: *Emitter, args: []const *Expr, params: []const ast.FunctionParam) CompileError!void {
    try e.byte('(');
    const packed_rest = params.len > 0 and params[params.len - 1].is_rest and args.len == params.len and args[args.len - 1].* == .array;
    const plain = if (packed_rest) args[0 .. args.len - 1] else args;
    var n: usize = 0;
    for (plain) |a| {
        if (n > 0) try e.w(", ");
        try emitExpr(e, a);
        n += 1;
    }
    if (packed_rest) for (args[args.len - 1].array.items) |a| {
        if (n > 0) try e.w(", ");
        try emitExpr(e, a);
        n += 1;
    };
    try e.byte(')');
}

/// The parameters of the top-level function `name`, for splicing a packed
/// rest argument; empty when it is not a user function.
fn functionParams(e: *Emitter, name: []const u8) []const ast.FunctionParam {
    for (e.program.stmts) |stmt| switch (stmt) {
        .function_decl => |f| if (f.type_params.len == 0 and std.mem.eql(u8, f.name, name)) return f.params,
        else => {},
    };
    return &.{};
}

fn findClass(e: *Emitter, name: []const u8) ?*const ast.ClassDecl {
    for (e.program.stmts) |*stmt| switch (stmt.*) {
        .class_decl => |*c| if (c.type_params.len == 0 and std.mem.eql(u8, c.name, name)) return c,
        else => {},
    };
    return null;
}

/// The parameters of method `name` on class `class_name` or an ancestor.
fn methodParams(e: *Emitter, class_name: []const u8, name: []const u8) []const ast.FunctionParam {
    var cur: ?[]const u8 = class_name;
    while (cur) |cn| {
        const c = findClass(e, cn) orelse return &.{};
        for (c.methods) |m| if (std.mem.eql(u8, m.name, name)) return m.params;
        cur = c.parent;
    }
    return &.{};
}

/// The constructor parameters that apply to `new C(...)`: the class's own or
/// the nearest ancestor's (spec 269).
fn ctorParams(e: *Emitter, class_name: []const u8) []const ast.FunctionParam {
    var cur: ?[]const u8 = class_name;
    while (cur) |cn| {
        const c = findClass(e, cn) orelse return &.{};
        if (c.has_ctor) return c.ctor_params;
        cur = c.parent;
    }
    return &.{};
}

/// A parameter list, shared by functions, methods and arrows: defaults as
/// written, an omittable `x?: T` filled with `null` (what the native call
/// site passes), rest parameters spread.
pub fn emitParams(e: *Emitter, params: []const ast.FunctionParam) CompileError!void {
    try e.byte('(');
    for (params, 0..) |p, i| {
        if (i > 0) try e.w(", ");
        if (p.is_rest) try e.w("...");
        try e.w(p.name);
        if (p.default) |d| {
            try e.w(" = ");
            try emitExpr(e, d);
        } else if (p.is_optional) {
            try e.w(" = null");
        }
    }
    try e.byte(')');
}

fn emitArrow(e: *Emitter, a: *const ast.ArrowExpr) CompileError!void {
    if (js_stmt.arrowIsAsync(a)) try e.w("async ");
    try emitParams(e, a.params);
    try e.w(" => ");
    if (a.body_block) |body| {
        try e.w("{\n");
        e.indent += 1;
        try js_stmt.emitBody(e, body);
        e.indent -= 1;
        try e.pad();
        try e.byte('}');
    } else if (a.body_expr) |body| {
        // `=> {...}` would read as a block: an object body needs parentheses.
        if (body.* == .obj) {
            try e.byte('(');
            try emitExpr(e, body);
            try e.byte(')');
        } else {
            try emitExpr(e, body);
        }
    } else {
        try e.w("{}");
    }
}

fn emitFieldAccess(e: *Emitter, name: []const u8, optional_chain: bool) CompileError!void {
    if (js.isPlainIdent(name) or (name.len > 1 and name[0] == '#' and js.isPlainIdent(name[1..]))) {
        try e.w(if (optional_chain) "?." else ".");
        try e.w(name);
    } else {
        try e.w(if (optional_chain) "?.[" else "[");
        try js.emitStrLit(e, name);
        try e.byte(']');
    }
}

/// A `number` (f64) printed the way the native runtime prints one (spec 505
/// decision 2): `__lang.fmt` writes every digit where JavaScript would switch
/// to `1e+21`, and `nan`/`inf` for the non-finite values.
fn emitFloatToString(e: *Emitter, x: *const Expr) CompileError!void {
    try e.w("__lang.fmt(");
    try emitExpr(e, x);
    try e.byte(')');
}

/// Whether an integer literal is exact as a JavaScript number: past 2^53 the
/// native `i64` holds it and a double does not.
pub fn exactAsDouble(n: i64) bool {
    return n >= -(1 << 53) and n <= (1 << 53);
}

pub fn emitExpr(e: *Emitter, x: *const Expr) CompileError!void {
    switch (x.*) {
        .num => |n| {
            if (!exactAsDouble(n) and !e.i64_warned) {
                e.i64_warned = true;
                e.warn("an integer literal past 2^53 is rounded on the node target, where `i64` is a JavaScript number [W_I64_PRECISION]");
            }
            try e.print("{d}", .{n});
        },
        .float => |f| try js.emitFloat(e, f),
        .bool => |b| try e.w(if (b) "true" else "false"),
        .str => |s| try js.emitStrLit(e, s),
        .regex => |r| {
            try e.byte('/');
            try js.emitRegexSource(e, r.source);
            try e.byte('/');
            try e.w(r.flags);
        },
        .null_lit => try e.w("null"),
        .array => |a| {
            try e.byte('[');
            for (a.items, 0..) |item, i| {
                if (i > 0) try e.w(", ");
                try emitExpr(e, item);
            }
            try e.byte(']');
        },
        .tuple_lit => |t| {
            try e.byte('[');
            for (t.items, 0..) |item, i| {
                if (i > 0) try e.w(", ");
                try emitExpr(e, item);
            }
            try e.byte(']');
        },
        .spread => |inner| {
            try e.w("...");
            try emitAt(e, inner, 0);
        },
        // The name as written: shadowing is legal in JavaScript, so the
        // checker's `emit_name` renames (spec 461) are not needed here.
        .var_ref => |r| try e.w(r.name),
        .neg => |inner| {
            try e.byte('-');
            // `- -x` must not fuse into `--x`.
            if (inner.* == .neg or (inner.* == .num and inner.num < 0) or (inner.* == .inc_dec and inner.inc_dec.is_prefix and !inner.inc_dec.is_inc)) {
                try e.byte('(');
                try emitExpr(e, inner);
                try e.byte(')');
            } else {
                try emitAt(e, inner, PREC_UNARY);
            }
        },
        .not => |inner| {
            try e.byte('!');
            try emitAt(e, inner, PREC_UNARY);
        },
        .bnot => |inner| {
            try e.byte('~');
            try emitAt(e, inner, PREC_UNARY);
        },
        .non_null => |n| try emitExpr(e, n.inner),
        .typeof_expr => |t| {
            try e.w("typeof ");
            try emitAt(e, t.operand, PREC_UNARY);
        },
        .instanceof_expr => |i| {
            try emitAt(e, i.value, 8);
            try e.w(" instanceof ");
            try e.w(i.class_name);
        },
        .inc_dec => |i| {
            const op: []const u8 = if (i.is_inc) "++" else "--";
            if (i.is_prefix) try e.w(op);
            try emitExpr(e, i.target);
            if (!i.is_prefix) try e.w(op);
        },
        .await_expr => |inner| {
            try e.w("await ");
            try emitAt(e, inner, PREC_UNARY);
        },
        .bin => |b| {
            // Integer division truncates (spec 137); JavaScript's `/` would
            // keep the fraction. `%` already truncates toward zero in both.
            if (isIntDivision(b)) {
                try e.w("__lang.divInt(");
                try emitExpr(e, b.l);
                try e.w(", ");
                try emitExpr(e, b.r);
                try e.byte(')');
                return;
            }
            const p = prec(x);
            // `**` associates to the right, and `-2 ** 2` is a syntax error:
            // its left operand is parenthesized down to a unary.
            try emitAt(e, b.l, if (b.op == 'P') PREC_MEMBER else p);
            try e.byte(' ');
            switch (b.op) {
                'L' => try e.w("<<"),
                'R' => try e.w(">>"),
                'P' => try e.w("**"),
                else => try e.byte(b.op),
            }
            try e.byte(' ');
            try emitAt(e, b.r, if (b.op == 'P') p else p + 1);
        },
        .bool_bin => |b| {
            const p = prec(x);
            try emitAt(e, b.l, p);
            try e.print(" {s} ", .{b.op});
            try emitAt(e, b.r, p + 1);
        },
        // Operand types already agree (the checker saw to it), so `==` and
        // `===` coincide; the loose form also treats an `undefined` a JavaScript
        // API hands back as the `null` the language means.
        .cmp => |c| {
            const p = prec(x);
            try emitAt(e, c.l, p);
            try e.print(" {s} ", .{c.op});
            try emitAt(e, c.r, p + 1);
        },
        .ternary => |t| {
            try emitAt(e, t.cond, 1);
            try e.w(" ? ");
            try emitAt(e, t.then_expr, 0);
            try e.w(" : ");
            try emitAt(e, t.else_expr, 0);
        },
        // `a || b ?? c` is a syntax error whichever way it groups, so a
        // logical operand of `??` is always parenthesized.
        .coalesce => |c| {
            try emitAt(e, c.l, if (c.l.* == .bool_bin) PREC_MEMBER else 1);
            try e.w(" ?? ");
            try emitAt(e, c.r, if (c.r.* == .bool_bin) PREC_MEMBER else 2);
        },
        .arrow => |a| try emitArrow(e, a),
        .this_expr => try e.w("this"),
        .super_call => |s| {
            try e.w("super.");
            try e.w(s.name);
            try emitArgs(e, s.args);
        },
        .new_expr => |n| {
            try e.w("new ");
            try e.w(n.class_name);
            try emitArgsFor(e, n.args, ctorParams(e, n.class_name));
        },
        .method_call => |m| {
            // A string method whose JavaScript namesake computes something
            // else on a byte string goes through the runtime (spec 505): the
            // helper takes the receiver first. Through `?.` the receiver may
            // be null, and a plain call cannot short-circuit, so the guard is
            // written out with the receiver evaluated once.
            if (js_stdlib.stringMethodHelper(m)) |helper| {
                if (m.optional_chain) try e.w("((__s) => __s == null ? null : ");
                try e.w("__lang.");
                try e.w(helper);
                try e.byte('(');
                if (m.optional_chain) try e.w("__s") else try emitExpr(e, m.obj);
                for (m.args) |a| {
                    try e.w(", ");
                    try emitExpr(e, a);
                }
                try e.byte(')');
                if (m.optional_chain) {
                    try e.w(")(");
                    try emitExpr(e, m.obj);
                    try e.byte(')');
                }
                return;
            }
            // `x.toString()` of a `number` prints it as the native runtime does.
            if (m.number_method and m.args.len == 0 and std.mem.eql(u8, m.name, "toString") and m.array_elem_type != null and m.array_elem_type.? == .f64) {
                return emitFloatToString(e, m.obj);
            }
            const null_on_missing = js_stdlib.nullOnMissing(m);
            const to_array = js_stdlib.iteratorToArray(m);
            if (null_on_missing) try e.byte('(');
            if (to_array) try e.w("Array.from(");
            try emitReceiver(e, m.obj);
            try emitFieldAccess(e, m.name, m.optional_chain);
            try emitArgsFor(e, m.args, if (m.class_name) |cn| methodParams(e, cn, m.name) else &.{});
            if (to_array) try e.byte(')');
            if (null_on_missing) try e.w(" ?? null)");
        },
        .template => |parts| {
            try e.byte('`');
            for (parts) |p| {
                if (p.text) |t| try js.emitTemplateText(e, t);
                if (p.expr) |inner| {
                    try e.w("${");
                    if (p.expr_type != null and p.expr_type.? == .f64) {
                        try emitFloatToString(e, inner);
                    } else {
                        try emitExpr(e, inner);
                    }
                    try e.byte('}');
                }
            }
            try e.byte('`');
        },
        .obj => |fields| {
            if (fields.len == 0) return e.w("{}");
            try e.w("{ ");
            for (fields, 0..) |f, i| {
                if (i > 0) try e.w(", ");
                if (f.is_spread) {
                    try e.w("...");
                    try emitAt(e, f.value, 0);
                    continue;
                }
                try js.emitPropertyKey(e, f.name);
                try e.w(": ");
                try emitExpr(e, f.value);
            }
            try e.w(" }");
        },
        .field => |f| {
            try emitReceiver(e, f.obj);
            const name: []const u8 = if (f.builtin) |b| switch (b) {
                .length, .buffer_length => "length",
                .error_message => "message",
                .error_name => "name",
                .container_size => "size",
            } else f.name;
            try emitFieldAccess(e, name, f.optional_chain);
            // A namespace constant (`Math.PI`, `Number.NaN`) is a call in the
            // runtime package, which serves every name in the language's call
            // shape (`Math.PI()` is also accepted); the property form is
            // called so the value is the number, not the function.
            if (f.builtin_const != null) try e.w("()");
        },
        .index => |i| {
            try emitReceiver(e, i.obj);
            try e.w(if (i.optional_chain) "?.[" else "[");
            try emitExpr(e, i.value);
            try e.byte(']');
        },
        .call => |c| {
            for (c.ref_args) |is_ref| if (is_ref) return e.unsupported(e.cur_line, e.cur_col, "a `Ref<T>` argument", "507");
            if (c.ffi_string_return or c.ffi_string_args.len > 0) return e.unsupported(e.cur_line, e.cur_col, "a call to an `extern function`", "507");
            // The checker's numeric promotion wraps an `int` operand in
            // `Number(...)` (spec 255); on a literal that is noise in JavaScript,
            // where every number is already a double.
            if (c.is_global_parse and c.args.len == 1 and std.mem.eql(u8, c.name, "Number") and (c.args[0].* == .num or c.args[0].* == .float)) {
                return emitExpr(e, c.args[0]);
            }
            // `String(x)` of a `number` prints it as the native runtime does.
            if (c.is_global_parse and c.args.len == 1 and std.mem.eql(u8, c.name, "String") and c.stringify_type != null and c.stringify_type.? == .f64) {
                return emitFloatToString(e, c.args[0]);
            }
            // `expect(actual).toBe(expected)` / `.toEqual(expected)`: the
            // parser folds the matcher into one call carrying both values
            // (spec 008); the runtime's `expect` takes them back as the
            // matcher call (spec 506).
            // (`__expectStrEqual` is the checker's `toBe` on strings, which
            // natively compares bytes; a byte string is one JavaScript value.)
            if (c.args.len == 2 and (std.mem.eql(u8, c.name, "__expectToBe") or std.mem.eql(u8, c.name, "__expectToEqual") or std.mem.eql(u8, c.name, "__expectStrEqual"))) {
                try e.w("expect(");
                try emitExpr(e, c.args[0]);
                try e.w(if (std.mem.eql(u8, c.name, "__expectToEqual")) ").toEqual(" else ").toBe(");
                try emitExpr(e, c.args[1]);
                try e.byte(')');
                return;
            }
            // A call to a generic function names the specialization the checker
            // made for these type arguments; the template itself is never emitted.
            const name = if (c.emit_name != null and js.isGenericFunction(e, c.name)) c.emit_name.? else c.name;
            try e.w(name);
            try emitArgsFor(e, c.args, functionParams(e, name));
        },
        .optional_call => |o| {
            try emitReceiver(e, o.callee);
            try e.w("?.");
            try emitArgs(e, o.args);
        },
        .static_call => |s| {
            if (js_stdlib.unsupportedStaticCall(s.namespace, s.name)) |what| return e.unsupported(e.cur_line, e.cur_col, what, "508");
            try e.w(s.namespace);
            try e.byte('.');
            try e.w(s.name);
            try emitArgs(e, s.args);
        },
        .cast => |c| {
            if (c.float_to_int) {
                try e.w("Math.trunc(");
                try emitExpr(e, c.inner);
                try e.byte(')');
            } else {
                try emitExpr(e, c.inner);
            }
        },
    }
}

test "operands keep their grouping and unary minus never fuses" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: @import("lumen_diag.zig").Diag = .{};
    var program: ast.Program = .{ .stmts = &.{} };
    var e: Emitter = .{ .arena = arena, .diag = &diag, .program = &program };
    var a: Expr = .{ .var_ref = .{ .name = "a" } };
    var b: Expr = .{ .var_ref = .{ .name = "b" } };
    var c: Expr = .{ .var_ref = .{ .name = "c" } };
    var sum: Expr = .{ .bin = .{ .op = '+', .l = &a, .r = &b } };
    var prod: Expr = .{ .bin = .{ .op = '*', .l = &sum, .r = &c } };
    try emitExpr(&e, &prod);
    try t.expectEqualStrings("(a + b) * c", e.out.items);
    e.out.clearRetainingCapacity();
    var prod2: Expr = .{ .bin = .{ .op = '*', .l = &b, .r = &c } };
    var sum2: Expr = .{ .bin = .{ .op = '+', .l = &a, .r = &prod2 } };
    try emitExpr(&e, &sum2);
    try t.expectEqualStrings("a + b * c", e.out.items);
    e.out.clearRetainingCapacity();
    var sum3: Expr = .{ .bin = .{ .op = '+', .l = &sum, .r = &c } };
    try emitExpr(&e, &sum3);
    try t.expectEqualStrings("a + b + c", e.out.items);
    e.out.clearRetainingCapacity();
    var diff: Expr = .{ .bin = .{ .op = '-', .l = &a, .r = &sum } };
    try emitExpr(&e, &diff);
    try t.expectEqualStrings("a - (a + b)", e.out.items);
    e.out.clearRetainingCapacity();
    var either: Expr = .{ .bool_bin = .{ .op = "||", .l = &a, .r = &b } };
    var coal: Expr = .{ .coalesce = .{ .l = &either, .r = &c } };
    try emitExpr(&e, &coal);
    try t.expectEqualStrings("(a || b) ?? c", e.out.items);
    e.out.clearRetainingCapacity();
    var neg_a: Expr = .{ .neg = &a };
    var neg_neg: Expr = .{ .neg = &neg_a };
    try emitExpr(&e, &neg_neg);
    try t.expectEqualStrings("-(-a)", e.out.items);
    e.out.clearRetainingCapacity();
    var pow: Expr = .{ .bin = .{ .op = 'P', .l = &neg_a, .r = &b } };
    try emitExpr(&e, &pow);
    try t.expectEqualStrings("(-a) ** b", e.out.items);
}

test "division is emitted by the checked type and string methods by their byte semantics" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: @import("lumen_diag.zig").Diag = .{};
    var program: ast.Program = .{ .stmts = &.{} };
    var e: Emitter = .{ .arena = arena, .diag = &diag, .program = &program };
    var a: Expr = .{ .var_ref = .{ .name = "a" } };
    var b: Expr = .{ .var_ref = .{ .name = "b" } };
    var c: Expr = .{ .var_ref = .{ .name = "c" } };
    // `int / int` truncates through the runtime; `number / number` is `/`.
    var int_div: Expr = .{ .bin = .{ .op = '/', .l = &a, .r = &b, .checked_type = .i32 } };
    var scaled: Expr = .{ .bin = .{ .op = '*', .l = &int_div, .r = &c } };
    try emitExpr(&e, &scaled);
    try t.expectEqualStrings("__lang.divInt(a, b) * c", e.out.items);
    e.out.clearRetainingCapacity();
    var float_div: Expr = .{ .bin = .{ .op = '/', .l = &a, .r = &b, .checked_type = .f64 } };
    try emitExpr(&e, &float_div);
    try t.expectEqualStrings("a / b", e.out.items);
    e.out.clearRetainingCapacity();
    var rem: Expr = .{ .bin = .{ .op = '%', .l = &a, .r = &b, .checked_type = .i32 } };
    try emitExpr(&e, &rem);
    try t.expectEqualStrings("a % b", e.out.items);
    // A byte-semantics method takes the receiver first; an identity one
    // prints as written; through `?.` the receiver is guarded.
    e.out.clearRetainingCapacity();
    var s: Expr = .{ .var_ref = .{ .name = "s" } };
    var i: Expr = .{ .num = 1 };
    var args = [_]*Expr{&i};
    var code: Expr = .{ .method_call = .{ .obj = &s, .name = "charCodeAt", .args = &args, .string_method = true, .array_result_type = .i32 } };
    try emitExpr(&e, &code);
    try t.expectEqualStrings("__lang.charCodeAt(s, 1)", e.out.items);
    e.out.clearRetainingCapacity();
    var slice: Expr = .{ .method_call = .{ .obj = &s, .name = "slice", .args = &args, .string_method = true, .array_result_type = .string } };
    try emitExpr(&e, &slice);
    try t.expectEqualStrings("s.slice(1)", e.out.items);
    e.out.clearRetainingCapacity();
    var opt_trim: Expr = .{ .method_call = .{ .obj = &s, .name = "trim", .args = &.{}, .string_method = true, .optional_chain = true } };
    try emitExpr(&e, &opt_trim);
    try t.expectEqualStrings("((__s) => __s == null ? null : __lang.trim(__s))(s)", e.out.items);
    // A regex pattern is matched against bytes: its non-ASCII bytes are escaped.
    e.out.clearRetainingCapacity();
    var re: Expr = .{ .regex = .{ .source = "\xC3\xA9+", .flags = "g" } };
    try emitExpr(&e, &re);
    try t.expectEqualStrings("/\\xC3\\xA9+/g", e.out.items);
}

test "a number becomes text through __lang.fmt, and a literal past 2^53 warns once" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: @import("lumen_diag.zig").Diag = .{};
    var warnings: std.ArrayListUnmanaged(@import("lumen_diag.zig").Diag) = .empty;
    var program: ast.Program = .{ .stmts = &.{} };
    var e: Emitter = .{ .arena = arena, .diag = &diag, .program = &program, .warnings = &warnings };
    var x: Expr = .{ .var_ref = .{ .name = "x" } };
    var x_args = [_]*Expr{&x};
    var str_f64: Expr = .{ .call = .{ .name = "String", .args = &x_args, .is_global_parse = true, .stringify_type = .f64 } };
    try emitExpr(&e, &str_f64);
    try t.expectEqualStrings("__lang.fmt(x)", e.out.items);
    e.out.clearRetainingCapacity();
    var str_i32: Expr = .{ .call = .{ .name = "String", .args = &x_args, .is_global_parse = true, .stringify_type = .i32 } };
    try emitExpr(&e, &str_i32);
    try t.expectEqualStrings("String(x)", e.out.items);
    e.out.clearRetainingCapacity();
    var parts = [_]ast.TemplatePart{ .{ .text = "v=" }, .{ .expr = &x, .expr_type = .f64 } };
    var tpl: Expr = .{ .template = &parts };
    try emitExpr(&e, &tpl);
    try t.expectEqualStrings("`v=${__lang.fmt(x)}`", e.out.items);
    e.out.clearRetainingCapacity();
    var to_str: Expr = .{ .method_call = .{ .obj = &x, .name = "toString", .args = &.{}, .number_method = true, .array_elem_type = .f64 } };
    try emitExpr(&e, &to_str);
    try t.expectEqualStrings("__lang.fmt(x)", e.out.items);
    // A namespace constant is read through its call, so it is a number.
    e.out.clearRetainingCapacity();
    var math: Expr = .{ .var_ref = .{ .name = "Math" } };
    var pi: Expr = .{ .field = .{ .obj = &math, .name = "PI", .builtin_const = "3.141592653589793" } };
    try emitExpr(&e, &pi);
    try t.expectEqualStrings("Math.PI()", e.out.items);
    // Two literals past 2^53: one warning.
    e.out.clearRetainingCapacity();
    var big: Expr = .{ .num = 9007199254740993 };
    var small: Expr = .{ .num = 9007199254740992 };
    try emitExpr(&e, &small);
    try t.expectEqual(@as(usize, 0), warnings.items.len);
    try emitExpr(&e, &big);
    try emitExpr(&e, &big);
    try t.expectEqual(@as(usize, 1), warnings.items.len);
    try t.expect(std.mem.indexOf(u8, warnings.items[0].msg, "[W_I64_PRECISION]") != null);
}
