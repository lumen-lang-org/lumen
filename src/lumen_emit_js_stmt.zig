//! Statement codegen for the node target: the `Stmt`-union counterpart of
//! `lumen_emit_js_expr.zig`.
//!
//! Two lowerings are not identity. `using x = ...` and `defer` have no Node
//! equivalent (explicit resource management is not in Node 22), so the rest
//! of the enclosing block moves into `try { ... } finally { dispose }`; two
//! declarations nest, which is the reverse (LIFO) order the language
//! specifies (specs 007, 027). A `switch` case body gets a trailing `break`:
//! the checker already rejected the fallthrough the language forbids (spec
//! 201), and JavaScript would otherwise fall through.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const types = @import("lumen_types.zig");
const js = @import("lumen_emit_js.zig");
const js_expr = @import("lumen_emit_js_expr.zig");
const js_class = @import("lumen_emit_js_class.zig");

const Emitter = js.Emitter;
const CompileError = js.CompileError;
const emitExpr = js_expr.emitExpr;

// ---------------------------------------------------------------------------
// `await` discovery: an arrow or a test body that awaits must be `async`.

pub fn exprHasAwait(x: *const ast.Expr) bool {
    return switch (x.*) {
        .await_expr => true,
        .num, .float, .bool, .str, .regex, .null_lit, .var_ref, .this_expr => false,
        .array => |a| anyHasAwait(a.items),
        .tuple_lit => |t| anyHasAwait(t.items),
        .spread => |i| exprHasAwait(i),
        .neg, .not, .bnot => |i| exprHasAwait(i),
        .non_null => |n| exprHasAwait(n.inner),
        .typeof_expr => |t| exprHasAwait(t.operand),
        .instanceof_expr => |i| exprHasAwait(i.value),
        .inc_dec => |i| exprHasAwait(i.target),
        .bin => |b| exprHasAwait(b.l) or exprHasAwait(b.r),
        .bool_bin => |b| exprHasAwait(b.l) or exprHasAwait(b.r),
        .cmp => |c| exprHasAwait(c.l) or exprHasAwait(c.r),
        .ternary => |t| exprHasAwait(t.cond) or exprHasAwait(t.then_expr) or exprHasAwait(t.else_expr),
        .coalesce => |c| exprHasAwait(c.l) or exprHasAwait(c.r),
        // A nested arrow's awaits are its own.
        .arrow => false,
        .super_call => |s| anyHasAwait(s.args),
        .new_expr => |n| anyHasAwait(n.args),
        .method_call => |m| exprHasAwait(m.obj) or anyHasAwait(m.args),
        .template => |parts| blk: {
            for (parts) |p| if (p.expr) |inner| if (exprHasAwait(inner)) break :blk true;
            break :blk false;
        },
        .obj => |fields| blk: {
            for (fields) |f| if (exprHasAwait(f.value)) break :blk true;
            break :blk false;
        },
        .field => |f| exprHasAwait(f.obj),
        .index => |i| exprHasAwait(i.obj) or exprHasAwait(i.value),
        .call => |c| anyHasAwait(c.args),
        .optional_call => |o| exprHasAwait(o.callee) or anyHasAwait(o.args),
        .static_call => |s| anyHasAwait(s.args),
        .cast => |c| exprHasAwait(c.inner),
    };
}

fn anyHasAwait(items: []const *ast.Expr) bool {
    for (items) |i| if (exprHasAwait(i)) return true;
    return false;
}

pub fn bodyHasAwait(stmts: []const ast.Stmt) bool {
    for (stmts) |*s| if (stmtHasAwait(s)) return true;
    return false;
}

fn stmtHasAwait(s: *const ast.Stmt) bool {
    return switch (s.*) {
        .type_decl, .enum_decl, .extern_decl, .class_decl, .function_decl, .test_decl, .break_stmt, .continue_stmt => false,
        .var_decl => |d| !d.no_init and exprHasAwait(d.init),
        .var_decl_group => |g| blk: {
            for (g) |d| if (!d.no_init and exprHasAwait(d.init)) break :blk true;
            break :blk false;
        },
        .using_decl => |u| exprHasAwait(u.init) or (u.defer_body != null and bodyHasAwait(u.defer_body.?)),
        .destructure_decl => |d| exprHasAwait(d.source),
        .member_assign => |m| exprHasAwait(m.value) or (m.obj != null and exprHasAwait(m.obj.?)),
        .super_ctor => |sc| anyHasAwait(sc.args),
        .assign => |a| exprHasAwait(a.value),
        .console_log => |c| exprHasAwait(c.value) or anyHasAwait(c.extra_values),
        .while_stmt => |w| exprHasAwait(w.cond) or bodyHasAwait(w.body),
        .do_while_stmt => |w| exprHasAwait(w.cond) or bodyHasAwait(w.body),
        .for_stmt => |f| (f.cond != null and exprHasAwait(f.cond.?)) or bodyHasAwait(f.body),
        .for_of_stmt => |f| exprHasAwait(f.iterable) or bodyHasAwait(f.body),
        .for_in_stmt => |f| exprHasAwait(f.iterable) or bodyHasAwait(f.body),
        .if_stmt => |i| exprHasAwait(i.cond) or bodyHasAwait(i.then_body) or (i.else_body != null and bodyHasAwait(i.else_body.?)),
        .switch_stmt => |sw| blk: {
            if (exprHasAwait(sw.value)) break :blk true;
            for (sw.cases) |c| if (bodyHasAwait(c.body)) break :blk true;
            break :blk sw.default_body != null and bodyHasAwait(sw.default_body.?);
        },
        .return_stmt => |r| r.value != null and exprHasAwait(r.value.?),
        .throw_stmt => |t| exprHasAwait(t.value),
        .try_stmt => |t| bodyHasAwait(t.try_body) or bodyHasAwait(t.catch_body) or (t.finally_body != null and bodyHasAwait(t.finally_body.?)),
        .defer_stmt => |d| bodyHasAwait(d.body),
        .expr_stmt => |x| exprHasAwait(x.value),
        .block_stmt => |b| bodyHasAwait(b.body),
    };
}

pub fn arrowIsAsync(a: *const ast.ArrowExpr) bool {
    if (a.body_block) |b| return bodyHasAwait(b);
    if (a.body_expr) |x| return exprHasAwait(x);
    return false;
}

// ---------------------------------------------------------------------------
// Bodies and blocks.

/// Emits the statements of a block. A `using`/`defer` statement takes the
/// rest of the block with it into a `try`, so the loop stops there.
pub fn emitBody(e: *Emitter, stmts: []const ast.Stmt) CompileError!void {
    for (stmts, 0..) |*s, i| {
        switch (s.*) {
            .using_decl => |*u| {
                if (u.defer_body == null) {
                    try e.pad();
                    try e.print("const {s} = ", .{u.name});
                    try emitExpr(e, u.init);
                    try e.w(";\n");
                }
                try emitTryFinally(e, stmts[i + 1 ..], u.defer_body, u.dispose_call, u.name);
                return;
            },
            .defer_stmt => |*d| {
                try emitTryFinally(e, stmts[i + 1 ..], d.body, null, null);
                return;
            },
            else => try emitStmt(e, s),
        }
    }
}

fn emitTryFinally(e: *Emitter, rest: []const ast.Stmt, cleanup_body: ?[]const ast.Stmt, cleanup_call: ?*const ast.Expr, name: ?[]const u8) CompileError!void {
    try e.line("try {");
    e.indent += 1;
    try emitBody(e, rest);
    e.indent -= 1;
    try e.line("} finally {");
    e.indent += 1;
    if (cleanup_body) |body| {
        try emitBody(e, body);
    } else if (cleanup_call) |call| {
        try e.pad();
        try emitExpr(e, call);
        try e.w(";\n");
    } else if (name) |n| {
        try e.pad();
        try e.print("{s}.dispose();\n", .{n});
    }
    e.indent -= 1;
    try e.line("}");
}

fn emitBlock(e: *Emitter, stmts: []const ast.Stmt) CompileError!void {
    try e.w(" {\n");
    e.indent += 1;
    try emitBody(e, stmts);
    e.indent -= 1;
    try e.pad();
    try e.byte('}');
}

fn emitLabel(e: *Emitter, label: ?[]const u8) CompileError!void {
    if (label) |l| try e.print("{s}: ", .{l});
}

fn emitVarDeclInline(e: *Emitter, d: *const ast.VarDecl, with_keyword: bool) CompileError!void {
    if (with_keyword) try e.w(if (d.mutable) "let " else "const ");
    try e.w(d.name);
    if (d.no_init) return;
    try e.w(" = ");
    try emitExpr(e, d.init);
}

fn emitAssignInline(e: *Emitter, a: *const ast.Assign) CompileError!void {
    try e.print("{s} {s} ", .{ a.name, a.op });
    try emitExpr(e, a.value);
}

fn emitDestructPattern(e: *Emitter, d: *const ast.DestructureDecl) CompileError!void {
    try e.w(if (d.is_object) "{ " else "[");
    for (d.bindings, 0..) |b, i| {
        if (i > 0) try e.w(", ");
        if (b.is_rest) try e.w("...");
        if (d.is_object) {
            if (b.field_name) |f| {
                if (!std.mem.eql(u8, f, b.name)) {
                    try js.emitPropertyKey(e, f);
                    try e.w(": ");
                }
            }
        }
        try e.w(b.name);
        if (b.default) |dflt| {
            try e.w(" = ");
            try emitExpr(e, dflt);
        }
    }
    try e.w(if (d.is_object) " }" else "]");
}

/// Whether a case body's last statement already leaves the switch, so no
/// `break` needs appending.
fn endsWithJump(stmts: []const ast.Stmt) bool {
    if (stmts.len == 0) return false;
    return switch (stmts[stmts.len - 1]) {
        .return_stmt, .throw_stmt, .break_stmt, .continue_stmt => true,
        else => false,
    };
}

fn emitCaseBody(e: *Emitter, body: []const ast.Stmt) CompileError!void {
    try e.w(" {\n");
    e.indent += 1;
    try emitBody(e, body);
    if (!endsWithJump(body)) try e.line("break;");
    e.indent -= 1;
    try e.line("}");
}

pub fn emitFunction(e: *Emitter, f: *const ast.FunctionDecl) CompileError!void {
    try e.pad();
    if (f.is_async) try e.w("async ");
    try e.print("function {s}", .{f.name});
    try js_expr.emitParams(e, f.params);
    try emitBlock(e, f.body);
    try e.w("\n");
}

/// A top-level statement. Type declarations and generic templates emit
/// nothing: the checker specialized every use, and a type binds no value.
pub fn emitTopLevel(e: *Emitter, s: *const ast.Stmt) CompileError!void {
    switch (s.*) {
        .function_decl => |*f| if (f.type_params.len > 0) return,
        .class_decl => |*c| if (c.type_params.len > 0) return,
        else => {},
    }
    try emitStmt(e, s);
}

/// The source position of a statement, for diagnostics raised while emitting
/// an expression inside it (expressions carry no position of their own).
pub fn stmtPos(s: *const ast.Stmt) ?[2]u32 {
    return switch (s.*) {
        .var_decl_group => |g| if (g.len > 0) .{ g[0].line, g[0].col } else null,
        inline else => |*v| .{ v.line, v.col },
    };
}

pub fn emitStmt(e: *Emitter, s: *const ast.Stmt) CompileError!void {
    if (stmtPos(s)) |pos| {
        e.cur_line = pos[0];
        e.cur_col = pos[1];
    }
    switch (s.*) {
        .type_decl => {},
        .enum_decl => |*d| try js_class.emitEnum(e, d),
        .test_decl => |*t| {
            try e.pad();
            try e.w("test(");
            try js.emitStrLit(e, t.name);
            try e.w(if (bodyHasAwait(t.body)) ", async () =>" else ", () =>");
            try emitBlock(e, t.body);
            try e.w(");\n");
        },
        .extern_decl => |*d| return e.unsupported(d.line, d.col, "`extern function`", "507"),
        .class_decl => |*c| try js_class.emitClass(e, c),
        .function_decl => |*f| try emitFunction(e, f),
        .var_decl => |*d| {
            try e.pad();
            try emitVarDeclInline(e, d, true);
            try e.w(";\n");
        },
        .var_decl_group => |group| {
            try e.pad();
            for (group, 0..) |*d, i| {
                if (i > 0) try e.w(", ");
                try emitVarDeclInline(e, d, i == 0);
            }
            try e.w(";\n");
        },
        // A `using` as the last statement of its block: nothing follows it,
        // so the `try` body is empty. (emitBody handles every other position.)
        .using_decl => |*u| {
            if (u.defer_body == null) {
                try e.pad();
                try e.print("const {s} = ", .{u.name});
                try emitExpr(e, u.init);
                try e.w(";\n");
            }
            try emitTryFinally(e, &.{}, u.defer_body, u.dispose_call, u.name);
        },
        .destructure_decl => |*d| {
            try e.pad();
            if (d.is_assignment) {
                // An object pattern at statement start reads as a block.
                if (d.is_object) try e.byte('(');
                try emitDestructPattern(e, d);
                try e.w(" = ");
                try emitExpr(e, d.source);
                if (d.is_object) try e.byte(')');
            } else {
                try e.w(if (d.mutable) "let " else "const ");
                try emitDestructPattern(e, d);
                try e.w(" = ");
                try emitExpr(e, d.source);
            }
            try e.w(";\n");
        },
        .member_assign => |*m| {
            try e.pad();
            if (m.obj) |obj| {
                try emitExpr(e, obj);
            } else {
                try e.w("this");
            }
            if (js.isPlainIdent(m.field) or (m.field.len > 1 and m.field[0] == '#')) {
                try e.byte('.');
                try e.w(m.field);
            } else {
                try e.byte('[');
                try js.emitStrLit(e, m.field);
                try e.byte(']');
            }
            try e.print(" {s} ", .{m.op});
            try emitExpr(e, m.value);
            try e.w(";\n");
        },
        .super_ctor => |*sc| {
            try e.pad();
            try e.w("super");
            try js_expr.emitArgs(e, sc.args);
            try e.w(";\n");
        },
        .assign => |*a| {
            try e.pad();
            try emitAssignInline(e, a);
            try e.w(";\n");
        },
        .console_log => |*c| {
            try e.pad();
            try e.print("console.{s}(", .{c.method});
            try emitExpr(e, c.value);
            for (c.extra_values) |v| {
                try e.w(", ");
                try emitExpr(e, v);
            }
            try e.w(");\n");
        },
        .while_stmt => |*w| {
            try e.pad();
            try emitLabel(e, w.label);
            try e.w("while (");
            try emitExpr(e, w.cond);
            try e.byte(')');
            try emitBlock(e, w.body);
            try e.w("\n");
        },
        .do_while_stmt => |*w| {
            try e.pad();
            try emitLabel(e, w.label);
            try e.w("do");
            try emitBlock(e, w.body);
            try e.w(" while (");
            try emitExpr(e, w.cond);
            try e.w(");\n");
        },
        .for_stmt => |*f| {
            try e.pad();
            try emitLabel(e, f.label);
            try e.w("for (");
            if (f.init) |*init| {
                try emitVarDeclInline(e, init, true);
                for (f.extra_inits) |*extra| {
                    try e.w(", ");
                    try emitVarDeclInline(e, extra, false);
                }
            }
            try e.w("; ");
            if (f.cond) |cond| try emitExpr(e, cond);
            try e.w("; ");
            if (f.update) |*upd| {
                try emitAssignInline(e, upd);
                for (f.extra_updates) |*extra| {
                    try e.w(", ");
                    try emitAssignInline(e, extra);
                }
            }
            try e.byte(')');
            try emitBlock(e, f.body);
            try e.w("\n");
        },
        .for_of_stmt => |*f| {
            try e.pad();
            try emitLabel(e, f.label);
            try e.w(if (f.mutable) "for (let " else "for (const ");
            if (f.is_pair or f.is_array_entries or f.is_tuple_pairs) {
                try e.print("[{s}, {s}]", .{ f.binding, f.value_binding });
            } else {
                try e.w(f.binding);
            }
            try e.w(" of ");
            try emitExpr(e, f.iterable);
            // The checker rewrote `arr.entries()` / `arr.keys()` to the bare
            // array for the native loop; JavaScript wants the iterator back.
            if (f.is_array_entries) try e.w(".entries()");
            if (f.is_array_keys) try e.w(".keys()");
            try e.byte(')');
            try emitBlock(e, f.body);
            try e.w("\n");
        },
        .for_in_stmt => |*f| {
            try e.pad();
            try emitLabel(e, f.label);
            try e.print("for ({s} {s} in ", .{ if (f.mutable) "let" else "const", f.binding });
            try emitExpr(e, f.iterable);
            try e.byte(')');
            try emitBlock(e, f.body);
            try e.w("\n");
        },
        .if_stmt => |*i| {
            try e.pad();
            try emitIfChain(e, i);
            try e.w("\n");
        },
        .switch_stmt => |*sw| {
            try e.pad();
            try e.w("switch (");
            try emitExpr(e, sw.value);
            try e.w(") {\n");
            e.indent += 1;
            for (sw.cases) |*c| {
                try e.pad();
                try e.w("case ");
                try emitExpr(e, c.value);
                try e.byte(':');
                try emitCaseBody(e, c.body);
            }
            if (sw.default_body) |body| {
                try e.pad();
                try e.w("default:");
                try emitCaseBody(e, body);
            }
            e.indent -= 1;
            try e.line("}");
        },
        .return_stmt => |*r| {
            try e.pad();
            try e.w("return");
            if (r.value) |v| {
                try e.byte(' ');
                try emitExpr(e, v);
            }
            try e.w(";\n");
        },
        .throw_stmt => |*t| {
            try e.pad();
            try e.w("throw ");
            // `throw "text"` is caught as `e.message == "text"` (spec 249):
            // only an Error carries a message in JavaScript.
            const wraps = t.value.* == .str or t.value.* == .template;
            if (wraps) try e.w("new Error(");
            try emitExpr(e, t.value);
            if (wraps) try e.byte(')');
            try e.w(";\n");
        },
        .try_stmt => |*t| {
            try e.pad();
            try e.w("try");
            try emitBlock(e, t.try_body);
            if (t.has_catch) {
                if (t.catch_name) |n| {
                    try e.print(" catch ({s})", .{n});
                } else {
                    try e.w(" catch");
                }
                try emitBlock(e, t.catch_body);
            }
            if (t.finally_body) |body| {
                try e.w(" finally");
                try emitBlock(e, body);
            }
            try e.w("\n");
        },
        .break_stmt => |*c| {
            try e.pad();
            try e.w("break");
            if (c.label) |l| try e.print(" {s}", .{l});
            try e.w(";\n");
        },
        .continue_stmt => |*c| {
            try e.pad();
            try e.w("continue");
            if (c.label) |l| try e.print(" {s}", .{l});
            try e.w(";\n");
        },
        .defer_stmt => |*d| try emitTryFinally(e, &.{}, d.body, null, null),
        .expr_stmt => |*x| {
            try e.pad();
            // A statement that starts with `{` is a block; wrap the literal.
            const wrap = x.value.* == .obj;
            if (wrap) try e.byte('(');
            try emitExpr(e, x.value);
            if (wrap) try e.byte(')');
            try e.w(";\n");
        },
        .block_stmt => |*b| {
            try e.pad();
            try e.w("{\n");
            e.indent += 1;
            try emitBody(e, b.body);
            e.indent -= 1;
            try e.line("}");
        },
    }
}

fn emitIfChain(e: *Emitter, i: *const ast.IfStmt) CompileError!void {
    try e.w("if (");
    try emitExpr(e, i.cond);
    try e.byte(')');
    try emitBlock(e, i.then_body);
    if (i.else_body) |else_body| {
        try e.w(" else ");
        if (else_body.len == 1 and else_body[0] == .if_stmt) {
            try emitIfChain(e, &else_body[0].if_stmt);
        } else {
            try e.w("{\n");
            e.indent += 1;
            try emitBody(e, else_body);
            e.indent -= 1;
            try e.pad();
            try e.byte('}');
        }
    }
}

test "using and defer lower to try/finally in reverse order" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: @import("lumen_diag.zig").Diag = .{};
    var program: ast.Program = .{ .stmts = &.{} };
    var e: Emitter = .{ .arena = arena, .diag = &diag, .program = &program };
    var open_call: ast.Expr = .{ .call = .{ .name = "open", .args = &.{} } };
    var r_ref: ast.Expr = .{ .var_ref = .{ .name = "r" } };
    var dispose: ast.Expr = .{ .method_call = .{ .obj = &r_ref, .name = "dispose", .args = &.{} } };
    var one: ast.Expr = .{ .num = 1 };
    var two: ast.Expr = .{ .num = 2 };
    var defer_body = [_]ast.Stmt{.{ .console_log = .{ .value = &one, .line = 1, .col = 1 } }};
    var placeholder: ast.Expr = .{ .null_lit = {} };
    const stmts = [_]ast.Stmt{
        .{ .using_decl = .{ .name = "r", .init = &open_call, .dispose_call = &dispose, .line = 1, .col = 1 } },
        .{ .using_decl = .{ .name = "_", .init = &placeholder, .defer_body = &defer_body, .line = 2, .col = 1 } },
        .{ .console_log = .{ .value = &two, .line = 3, .col = 1 } },
    };
    try emitBody(&e, &stmts);
    try t.expectEqualStrings(
        \\const r = open();
        \\try {
        \\  try {
        \\    console.log(2);
        \\  } finally {
        \\    console.log(1);
        \\  }
        \\} finally {
        \\  r.dispose();
        \\}
        \\
    , e.out.items);
}

test "switch cases get the break JavaScript needs and if-chains stay flat" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: @import("lumen_diag.zig").Diag = .{};
    var program: ast.Program = .{ .stmts = &.{} };
    var e: Emitter = .{ .arena = arena, .diag = &diag, .program = &program };
    var k: ast.Expr = .{ .var_ref = .{ .name = "k" } };
    var one: ast.Expr = .{ .num = 1 };
    var a: ast.Expr = .{ .str = "a" };
    var b: ast.Expr = .{ .str = "b" };
    var case_body = [_]ast.Stmt{.{ .console_log = .{ .value = &a, .line = 1, .col = 1 } }};
    var default_body = [_]ast.Stmt{.{ .return_stmt = .{ .value = &b, .line = 1, .col = 1 } }};
    var cases = [_]ast.SwitchCase{.{ .value = &one, .body = &case_body, .line = 1, .col = 1 }};
    const sw: ast.Stmt = .{ .switch_stmt = .{ .value = &k, .cases = &cases, .default_body = &default_body, .line = 1, .col = 1 } };
    try emitStmt(&e, &sw);
    try t.expectEqualStrings(
        \\switch (k) {
        \\  case 1: {
        \\    console.log("a");
        \\    break;
        \\  }
        \\  default: {
        \\    return "b";
        \\  }
        \\}
        \\
    , e.out.items);
}
