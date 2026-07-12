//! Escape analysis for class instances (spec 344).
//!
//! A `const v = new C(args)` whose instance never escapes its function can be
//! built on the stack instead of the scratch arena — no heap allocation, no
//! lingering memory. This is the compiled-language answer to short-lived object
//! churn (a garbage collector's job elsewhere), matching Lumen's no-runtime
//! model.
//!
//! Soundness rule (conservative — a false "escapes" only costs an optimization):
//!   1. The class `C` is non-generic and its constructor does not throw.
//!   2. `C` never leaks `self`: no method returns a class type (which could be
//!      `return this`), and within every method body and the constructor body
//!      `this` appears only as the receiver of a field read or a method call.
//!   3. The binding `v` appears only as the receiver of a field read (`v.f`) or
//!      a method call (`v.m(...)`) — never bare (as an argument, return value,
//!      array/object element, assignment, index, closure capture, ...).
//! Under these, the instance's address never outlives the stack frame.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const types = @import("lumen_types.zig");
const check_mod = @import("lumen_check.zig");

const Checker = check_mod.Checker;

fn isRef(e: *const ast.Expr, name: []const u8) bool {
    return e.* == .var_ref and std.mem.eql(u8, e.var_ref.name, name);
}

/// Whether the binding `name` escapes anywhere in `e`. A bare reference escapes;
/// the name as the immediate receiver of a field read or method call does not
/// (a field read yields a value, not the instance's own address; a method call
/// on a leak-free class cannot stash `self`).
fn exprEscapes(e: *const ast.Expr, name: []const u8) bool {
    return switch (e.*) {
        .num, .float, .bool, .str, .regex, .null_lit, .this_expr => false,
        .var_ref => |r| std.mem.eql(u8, r.name, name),
        .field => |f| if (isRef(f.obj, name)) false else exprEscapes(f.obj, name),
        .method_call => |mc| blk: {
            var esc = if (isRef(mc.obj, name)) false else exprEscapes(mc.obj, name);
            for (mc.args) |a| esc = esc or exprEscapes(a, name);
            break :blk esc;
        },
        .array => |a| anyEscapes(a.items, name),
        .tuple_lit => |t| anyEscapes(t.items, name),
        .spread => |inner| exprEscapes(inner, name),
        .typeof_expr => |to| exprEscapes(to.operand, name),
        .instanceof_expr => |io| exprEscapes(io.value, name),
        .inc_dec => |id| exprEscapes(id.target, name),
        .neg, .not, .bnot, .await_expr => |inner| exprEscapes(inner, name),
        .non_null => |nn| exprEscapes(nn.inner, name),
        .bin => |b| exprEscapes(b.l, name) or exprEscapes(b.r, name),
        .bool_bin => |b| exprEscapes(b.l, name) or exprEscapes(b.r, name),
        .cmp => |b| exprEscapes(b.l, name) or exprEscapes(b.r, name),
        .ternary => |t| exprEscapes(t.cond, name) or exprEscapes(t.then_expr, name) or exprEscapes(t.else_expr, name),
        .coalesce => |c| exprEscapes(c.l, name) or exprEscapes(c.r, name),
        // A closure that references the name captures it — treat as escaping. An
        // expression-body arrow is checked; a statement-body arrow is opaque here
        // (conservatively escaping).
        .arrow => |a| if (a.body_expr) |be| exprEscapes(be, name) else true,
        .new_expr => |ne| anyEscapes(ne.args, name),
        .super_call => |sc| anyEscapes(sc.args, name),
        .template => |parts| blk: {
            for (parts) |pt| if (pt.expr) |x| {
                if (exprEscapes(x, name)) break :blk true;
            };
            break :blk false;
        },
        .obj => |fields| blk: {
            for (fields) |f| if (exprEscapes(f.value, name)) break :blk true;
            break :blk false;
        },
        .index => |idx| exprEscapes(idx.obj, name) or exprEscapes(idx.value, name),
        .call => |cl| anyEscapes(cl.args, name),
        .static_call => |sc| anyEscapes(sc.args, name),
        .optional_call => |oc| exprEscapes(oc.callee, name) or anyEscapes(oc.args, name),
        .cast => |c| exprEscapes(c.inner, name),
    };
}

fn anyEscapes(items: []const *ast.Expr, name: []const u8) bool {
    for (items) |it| if (exprEscapes(it, name)) return true;
    return false;
}

/// Whether `this` escapes anywhere in `e` (same receiver rule as `exprEscapes`,
/// for the bare `.this_expr` node instead of a named binding).
fn thisEscapes(e: *const ast.Expr) bool {
    return switch (e.*) {
        .num, .float, .bool, .str, .regex, .null_lit, .var_ref => false,
        .this_expr => true,
        .field => |f| if (f.obj.* == .this_expr) false else thisEscapes(f.obj),
        .method_call => |mc| blk: {
            var esc = if (mc.obj.* == .this_expr) false else thisEscapes(mc.obj);
            for (mc.args) |a| esc = esc or thisEscapes(a);
            break :blk esc;
        },
        .array => |a| anyThisEscapes(a.items),
        .tuple_lit => |t| anyThisEscapes(t.items),
        .spread => |inner| thisEscapes(inner),
        .typeof_expr => |to| thisEscapes(to.operand),
        .instanceof_expr => |io| thisEscapes(io.value),
        .inc_dec => |id| thisEscapes(id.target),
        .neg, .not, .bnot, .await_expr => |inner| thisEscapes(inner),
        .non_null => |nn| thisEscapes(nn.inner),
        .bin => |b| thisEscapes(b.l) or thisEscapes(b.r),
        .bool_bin => |b| thisEscapes(b.l) or thisEscapes(b.r),
        .cmp => |b| thisEscapes(b.l) or thisEscapes(b.r),
        .ternary => |t| thisEscapes(t.cond) or thisEscapes(t.then_expr) or thisEscapes(t.else_expr),
        .coalesce => |c| thisEscapes(c.l) or thisEscapes(c.r),
        .arrow => true, // a closure may capture `this`; conservatively escaping
        .new_expr => |ne| anyThisEscapes(ne.args),
        .super_call => |sc| anyThisEscapes(sc.args),
        .template => |parts| blk: {
            for (parts) |pt| if (pt.expr) |x| {
                if (thisEscapes(x)) break :blk true;
            };
            break :blk false;
        },
        .obj => |fields| blk: {
            for (fields) |f| if (thisEscapes(f.value)) break :blk true;
            break :blk false;
        },
        .index => |idx| thisEscapes(idx.obj) or thisEscapes(idx.value),
        .call => |cl| anyThisEscapes(cl.args),
        .static_call => |sc| anyThisEscapes(sc.args),
        .optional_call => |oc| thisEscapes(oc.callee) or anyThisEscapes(oc.args),
        .cast => |c| thisEscapes(c.inner),
    };
}

fn anyThisEscapes(items: []const *ast.Expr) bool {
    for (items) |it| if (thisEscapes(it)) return true;
    return false;
}

/// Whether `this` escapes anywhere in a statement (walks the sub-expressions and
/// nested blocks). Assignments to `this.field` are a field-store: the assigned
/// *value* is checked (storing `this` there would leak it), but the `this.field`
/// target itself is not a leak.
fn stmtThisEscapes(stmt: *const ast.Stmt) bool {
    return switch (stmt.*) {
        .var_decl => |d| if (d.no_init) false else thisEscapes(d.init),
        .var_decl_group => |g| blk: {
            for (g) |*d| if (!d.no_init and thisEscapes(d.init)) break :blk true;
            break :blk false;
        },
        .assign => |a| thisEscapes(a.value),
        .member_assign => |ma| thisEscapes(ma.value),
        .return_stmt => |r| if (r.value) |v| thisEscapes(v) else false,
        .throw_stmt => |t| thisEscapes(t.value),
        .expr_stmt => |es| thisEscapes(es.value),
        .console_log => |l| blk: {
            if (thisEscapes(l.value)) break :blk true;
            for (l.extra_values) |v| if (thisEscapes(v)) break :blk true;
            break :blk false;
        },
        .if_stmt => |s| thisEscapes(s.cond) or bodyThisEscapes(s.then_body) or (if (s.else_body) |eb| bodyThisEscapes(eb) else false),
        .while_stmt => |s| thisEscapes(s.cond) or bodyThisEscapes(s.body),
        .do_while_stmt => |s| thisEscapes(s.cond) or bodyThisEscapes(s.body),
        .for_stmt => |s| bodyThisEscapes(s.body) or (if (s.cond) |c| thisEscapes(c) else false),
        .for_of_stmt => |s| thisEscapes(s.iterable) or bodyThisEscapes(s.body),
        .for_in_stmt => |s| thisEscapes(s.iterable) or bodyThisEscapes(s.body),
        .switch_stmt => |s| blk: {
            if (thisEscapes(s.value)) break :blk true;
            for (s.cases) |c| if (bodyThisEscapes(c.body)) break :blk true;
            if (s.default_body) |db| if (bodyThisEscapes(db)) break :blk true;
            break :blk false;
        },
        .block_stmt => |b| bodyThisEscapes(b.body),
        .try_stmt => |t| bodyThisEscapes(t.try_body) or bodyThisEscapes(t.catch_body) or (if (t.finally_body) |fb| bodyThisEscapes(fb) else false),
        .super_ctor => |sc| anyThisEscapes(sc.args),
        else => false,
    };
}

fn bodyThisEscapes(body: []const ast.Stmt) bool {
    for (body) |*s| if (stmtThisEscapes(s)) return true;
    return false;
}

/// Whether a binding `name` escapes anywhere in a statement list. Also bails
/// (returns true) if the name is re-declared in the body, since the escape scan
/// cannot then attribute uses to the right binding.
fn stmtRefEscapes(stmt: *const ast.Stmt, name: []const u8) bool {
    return switch (stmt.*) {
        .var_decl => |d| (!d.no_init and exprEscapes(d.init, name)),
        .var_decl_group => |g| blk: {
            for (g) |*d| if (!d.no_init and exprEscapes(d.init, name)) break :blk true;
            break :blk false;
        },
        .assign => |a| std.mem.eql(u8, a.name, name) or exprEscapes(a.value, name),
        .member_assign => |ma| exprEscapes(ma.value, name),
        .return_stmt => |r| if (r.value) |v| exprEscapes(v, name) else false,
        .throw_stmt => |t| exprEscapes(t.value, name),
        .expr_stmt => |es| exprEscapes(es.value, name),
        .console_log => |l| blk: {
            if (exprEscapes(l.value, name)) break :blk true;
            for (l.extra_values) |v| if (exprEscapes(v, name)) break :blk true;
            break :blk false;
        },
        .if_stmt => |s| exprEscapes(s.cond, name) or bodyRefEscapes(s.then_body, name) or (if (s.else_body) |eb| bodyRefEscapes(eb, name) else false),
        .while_stmt => |s| exprEscapes(s.cond, name) or bodyRefEscapes(s.body, name),
        .do_while_stmt => |s| exprEscapes(s.cond, name) or bodyRefEscapes(s.body, name),
        .for_stmt => |s| bodyRefEscapes(s.body, name) or (if (s.cond) |c| exprEscapes(c, name) else false),
        .for_of_stmt => |s| exprEscapes(s.iterable, name) or bodyRefEscapes(s.body, name),
        .for_in_stmt => |s| exprEscapes(s.iterable, name) or bodyRefEscapes(s.body, name),
        .switch_stmt => |s| blk: {
            if (exprEscapes(s.value, name)) break :blk true;
            for (s.cases) |c| if (bodyRefEscapes(c.body, name)) break :blk true;
            if (s.default_body) |db| if (bodyRefEscapes(db, name)) break :blk true;
            break :blk false;
        },
        .block_stmt => |b| bodyRefEscapes(b.body, name),
        .try_stmt => |t| bodyRefEscapes(t.try_body, name) or bodyRefEscapes(t.catch_body, name) or (if (t.finally_body) |fb| bodyRefEscapes(fb, name) else false),
        .super_ctor => |sc| anyEscapes(sc.args, name),
        else => false,
    };
}

fn bodyRefEscapes(body: []const ast.Stmt, name: []const u8) bool {
    for (body) |*s| if (stmtRefEscapes(s, name)) return true;
    return false;
}

/// Count top-level (and nested) `var_decl`s that bind `name`, to detect
/// re-declaration/shadowing (which would make the whole-body escape scan
/// unsound).
fn declCount(body: []const ast.Stmt, name: []const u8) usize {
    var n: usize = 0;
    for (body) |*s| n += stmtDeclCount(s, name);
    return n;
}

fn stmtDeclCount(stmt: *const ast.Stmt, name: []const u8) usize {
    return switch (stmt.*) {
        .var_decl => |d| @intFromBool(std.mem.eql(u8, d.name, name)),
        .var_decl_group => |g| blk: {
            var n: usize = 0;
            for (g) |*d| n += @intFromBool(std.mem.eql(u8, d.name, name));
            break :blk n;
        },
        .if_stmt => |s| declCount(s.then_body, name) + (if (s.else_body) |eb| declCount(eb, name) else 0),
        .while_stmt => |s| declCount(s.body, name),
        .do_while_stmt => |s| declCount(s.body, name),
        .for_stmt => |s| declCount(s.body, name),
        .for_of_stmt => |s| declCount(s.body, name),
        .for_in_stmt => |s| declCount(s.body, name),
        .switch_stmt => |s| blk: {
            var n: usize = 0;
            for (s.cases) |c| n += declCount(c.body, name);
            if (s.default_body) |db| n += declCount(db, name);
            break :blk n;
        },
        .block_stmt => |b| declCount(b.body, name),
        .try_stmt => |t| declCount(t.try_body, name) + declCount(t.catch_body, name) + (if (t.finally_body) |fb| declCount(fb, name) else 0),
        else => 0,
    };
}

/// Whether instances of class `cname` never leak `self`, so their address can
/// live on a caller's stack. Requires: no method returns a class type, and
/// every method body and the constructor body keeps `this` to receiver
/// positions only.
fn classSelfSafe(self: *Checker, cname: []const u8) bool {
    const info = self.classes.get(cname) orelse return false;
    // Inherited members matter too: walk the ancestor chain.
    var cur: ?[]const u8 = cname;
    while (cur) |cn| {
        const ci = self.classes.get(cn) orelse return false;
        for (ci.methods) |m| {
            if (m.checked_return_type) |rt| {
                if (rt == .class_type) return false;
            }
            if (bodyThisEscapes(m.body)) return false;
        }
        cur = ci.parent;
    }
    _ = info;
    return true;
}

/// Mark stack-allocatable `new C(...)` bindings in a function/method body.
fn analyzeBody(self: *Checker, body: []ast.Stmt) void {
    for (body) |*stmt| {
        switch (stmt.*) {
            .var_decl => |*d| maybeMark(self, d, body),
            .var_decl_group => |g| for (g) |*d| maybeMark(self, d, body),
            // Recurse into nested scopes; the escape scan still runs over the
            // whole enclosing body, which is a sound over-approximation.
            .if_stmt => |*s| {
                analyzeBody(self, s.then_body);
                if (s.else_body) |eb| analyzeBody(self, eb);
            },
            .while_stmt => |*s| analyzeBody(self, s.body),
            .do_while_stmt => |*s| analyzeBody(self, s.body),
            .for_stmt => |*s| analyzeBody(self, s.body),
            .for_of_stmt => |*s| analyzeBody(self, s.body),
            .for_in_stmt => |*s| analyzeBody(self, s.body),
            .switch_stmt => |*s| {
                for (s.cases) |*c| analyzeBody(self, c.body);
                if (s.default_body) |db| analyzeBody(self, db);
            },
            .block_stmt => |*b| analyzeBody(self, b.body),
            .try_stmt => |*t| {
                analyzeBody(self, t.try_body);
                analyzeBody(self, t.catch_body);
                if (t.finally_body) |fb| analyzeBody(self, fb);
            },
            else => {},
        }
    }
}

fn maybeMark(self: *Checker, d: *ast.VarDecl, enclosing: []const ast.Stmt) void {
    if (d.no_init) return;
    if (d.init.* != .new_expr) return;
    const ne = d.init.new_expr;
    if (ne.container_type != null) return; // Map/Set/Error/etc., not a class
    if (ne.type_args.len != 0) return; // a generic instantiation
    const cname = ne.class_name;
    _ = self.classes.get(cname) orelse return;
    if (!classSelfSafe(self, cname)) return;
    // The binding must not be re-declared and must never escape.
    if (declCount(enclosing, d.name) != 1) return;
    if (bodyRefEscapes(enclosing, d.name)) return;
    d.stack_alloc = true;
}

/// Entry point: run over every top-level function and every class method.
pub fn analyze(self: *Checker, program: *ast.Program) void {
    for (program.stmts) |*stmt| {
        switch (stmt.*) {
            .function_decl => |*f| {
                if (f.type_params.len == 0) analyzeBody(self, f.body);
            },
            .class_decl => |*c| {
                for (c.methods) |*m| analyzeBody(self, m.body);
                analyzeBody(self, c.ctor_body);
            },
            else => {},
        }
    }
}
