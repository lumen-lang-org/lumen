//! Small static-analysis helpers used while emitting statements and class
//! bodies: does this statement/body always throw or always return (decides
//! whether a trailing `unreachable`/fallthrough is needed), does it
//! reference `this` (decides whether a method needs `_ = self;` to silence
//! Zig's unused-parameter check), and a couple of formatting/zero-value
//! helpers (`printFormat` for `console.log`, `zigZeroValue` for default
//! field initializers).
//!
//! Pure analysis -- no emission beyond `emitUnusedParamDiscards`, which
//! writes the `_ = name;` discard lines themselves. Shared by
//! `lumen_emit_class.zig` and `lumen_emit_stmt.zig`.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const types = @import("lumen_types.zig");
const diag_mod = @import("lumen_diag.zig");
const lumen_opt = @import("lumen_opt.zig");

const CompileError = diag_mod.CompileError;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const bodyUsesName = lumen_opt.bodyUsesName;

pub fn zigZeroValue(arena: std.mem.Allocator, t: types.Type) CompileError![]const u8 {
    _ = arena;
    return switch (t) {
        .i32, .i64, .int_literal_union => "0",
        .f64 => "0",
        .bool => "false",
        .enum_type => |e| if (e.is_string) "\"\"" else "0",
        .string, .string_literal_union, .error_obj => "\"\"",
        .i32_array, .i64_array, .f64_array, .bool_array, .string_array => "&.{}",
        .named_array => "&.{}",
        .optional, .none => "null",
        else => "undefined",
    };
}

/// Function names whose calls can throw (exception propagation, spec 245).
/// Populated by the compiler's fixpoint pass before emission; null disables
/// call-aware throw analysis (e.g. release-fast builds keep panic semantics).
pub var g_throwing_fns: ?*const std.StringHashMapUnmanaged(void) = null;

/// Arena for building method lookup keys inside `exprCanThrow` (set alongside
/// g_throwing_fns by the compiler's fixpoint pass).
pub var g_method_arena: ?std.mem.Allocator = null;

/// Whether calling the named function can raise a Lumen exception.
pub fn fnThrows(name: []const u8) bool {
    const set = g_throwing_fns orelse return false;
    return set.get(name) != null;
}

/// Whether calling a class method with this name can raise a Lumen exception.
/// Method keys are name-based ("m:<name>") across all classes so emission and
/// call sites agree even through inheritance and super copies; a same-named
/// non-throwing method just carries an error union that never errors.
pub fn methodThrows(arena: std.mem.Allocator, name: []const u8) bool {
    const set = g_throwing_fns orelse return false;
    const key = std.fmt.allocPrint(arena, "m:{s}", .{name}) catch return false;
    return set.get(key) != null;
}

/// Whether evaluating this expression can raise a Lumen exception — i.e. it
/// contains a call to a function in the throwing set. Arrow-function bodies
/// don't count: an arrow is a value here, not an evaluation.
pub fn exprCanThrow(e: *const Expr) bool {
    if (g_throwing_fns == null) return false;
    return switch (e.*) {
        .call => |c| blk: {
            if (!c.is_closure and !c.is_into_call and fnThrows(c.emit_name orelse c.name)) break :blk true;
            for (c.args) |a| if (exprCanThrow(a)) break :blk true;
            break :blk false;
        },
        .array => |a| blk: {
            for (a.items) |item| if (exprCanThrow(item)) break :blk true;
            break :blk false;
        },
        .tuple_lit => |t| blk: {
            for (t.items) |item| if (exprCanThrow(item)) break :blk true;
            break :blk false;
        },
        .spread => |inner| exprCanThrow(inner),
        .neg, .not, .bnot, .await_expr => |inner| exprCanThrow(inner),
        .inc_dec => |i| exprCanThrow(i.target),
        .bin => |b| exprCanThrow(b.l) or exprCanThrow(b.r),
        .bool_bin => |b| exprCanThrow(b.l) or exprCanThrow(b.r),
        .cmp => |c| exprCanThrow(c.l) or exprCanThrow(c.r),
        .coalesce => |c| exprCanThrow(c.l) or exprCanThrow(c.r),
        .ternary => |t| exprCanThrow(t.cond) or exprCanThrow(t.then_expr) or exprCanThrow(t.else_expr),
        .super_call => |sc| blk: {
            if (g_method_arena) |ma| if (methodThrows(ma, sc.name)) break :blk true;
            for (sc.args) |a| if (exprCanThrow(a)) break :blk true;
            break :blk false;
        },
        .new_expr => |ne| blk: {
            for (ne.args) |a| if (exprCanThrow(a)) break :blk true;
            break :blk false;
        },
        .method_call => |mc| blk: {
            if (mc.class_name != null and !mc.is_console) {
                if (g_method_arena) |ma| if (methodThrows(ma, mc.name)) break :blk true;
            }
            if (exprCanThrow(mc.obj)) break :blk true;
            for (mc.args) |a| if (exprCanThrow(a)) break :blk true;
            break :blk false;
        },
        .optional_call => |oc| blk: {
            if (exprCanThrow(oc.callee)) break :blk true;
            for (oc.args) |a| if (exprCanThrow(a)) break :blk true;
            break :blk false;
        },
        .static_call => |sc| blk: {
            for (sc.args) |a| if (exprCanThrow(a)) break :blk true;
            break :blk false;
        },
        .template => |parts| blk: {
            for (parts) |part| if (part.expr) |hole| if (exprCanThrow(hole)) break :blk true;
            break :blk false;
        },
        .obj => |fields| blk: {
            for (fields) |f| if (exprCanThrow(f.value)) break :blk true;
            break :blk false;
        },
        .field => |f| exprCanThrow(f.obj),
        .index => |i| exprCanThrow(i.obj) or exprCanThrow(i.value),
        .cast => |c| exprCanThrow(c.inner),
        else => false,
    };
}

pub fn stmtCanThrow(stmt: *const Stmt) bool {
    return switch (stmt.*) {
        .throw_stmt => true,
        .while_stmt => |w| exprCanThrow(w.cond) or bodyCanThrow(w.body),
        .do_while_stmt => |w| exprCanThrow(w.cond) or bodyCanThrow(w.body),
        .for_stmt => |f| blk: {
            if (f.init) |i| if (!i.no_init and exprCanThrow(i.init)) break :blk true;
            for (f.extra_inits) |i| if (!i.no_init and exprCanThrow(i.init)) break :blk true;
            if (f.cond) |c| if (exprCanThrow(c)) break :blk true;
            if (f.update) |u| if (exprCanThrow(u.value)) break :blk true;
            for (f.extra_updates) |u| if (exprCanThrow(u.value)) break :blk true;
            break :blk bodyCanThrow(f.body);
        },
        .for_of_stmt => |f| exprCanThrow(f.iterable) or bodyCanThrow(f.body),
        .for_in_stmt => |f| exprCanThrow(f.iterable) or bodyCanThrow(f.body),
        .if_stmt => |b| exprCanThrow(b.cond) or bodyCanThrow(b.then_body) or (b.else_body != null and bodyCanThrow(b.else_body.?)),
        .switch_stmt => |sw| blk: {
            if (exprCanThrow(sw.value)) break :blk true;
            for (sw.cases) |cse| if (bodyCanThrow(cse.body)) break :blk true;
            if (sw.default_body) |db| if (bodyCanThrow(db)) break :blk true;
            break :blk false;
        },
        .defer_stmt => |d| bodyCanThrow(d.body),
        .block_stmt => |b| bodyCanThrow(b.body),
        .using_decl => |u| if (u.defer_body) |b| bodyCanThrow(b) else false,
        .var_decl => |d| !d.no_init and exprCanThrow(d.init),
        .var_decl_group => |group| blk: {
            for (group) |d| if (!d.no_init and exprCanThrow(d.init)) break :blk true;
            break :blk false;
        },
        .destructure_decl => |d| exprCanThrow(d.source),
        .assign => |a| exprCanThrow(a.value),
        .member_assign => |ma| exprCanThrow(ma.value),
        .console_log => |log| blk: {
            if (exprCanThrow(log.value)) break :blk true;
            for (log.extra_values) |v| if (exprCanThrow(v)) break :blk true;
            break :blk false;
        },
        .return_stmt => |r| r.value != null and exprCanThrow(r.value.?),
        .expr_stmt => |es| exprCanThrow(es.value),
        // A nested try swallows throws from its own try body via its own slot;
        // it propagates to the outer slot only if its catch or finally throws --
        // or, for a no-catch `try/finally`, if its try body throws (which
        // re-propagates after finally).
        .try_stmt => |t| (!t.has_catch and bodyCanThrow(t.try_body)) or bodyCanThrow(t.catch_body) or (t.finally_body != null and bodyCanThrow(t.finally_body.?)),
        else => false,
    };
}

pub fn bodyCanThrow(body: []const Stmt) bool {
    for (body) |*stmt| if (stmtCanThrow(stmt)) return true;
    return false;
}

/// Whether a statement unconditionally diverts control via `throw` (lowered to
/// a `break` out of the enclosing try). Anything after such a statement in the
/// same try body is dead code, which Zig rejects, so the emitter stops there.
pub fn stmtAlwaysThrows(stmt: *const Stmt) bool {
    return switch (stmt.*) {
        .throw_stmt => true,
        .if_stmt => |b| b.else_body != null and bodyAlwaysThrows(b.then_body) and bodyAlwaysThrows(b.else_body.?),
        else => false,
    };
}

pub fn bodyAlwaysThrows(body: []const Stmt) bool {
    if (body.len == 0) return false;
    return stmtAlwaysThrows(&body[body.len - 1]);
}

/// Whether a statement unconditionally diverts control via `return` or `throw`
/// (used to decide whether an async `Promise<void>` body needs a trailing
/// resolved-promise return, which would otherwise be unreachable code).
pub fn stmtAlwaysReturns(stmt: *const Stmt) bool {
    return switch (stmt.*) {
        .return_stmt, .throw_stmt => true,
        .if_stmt => |b| b.else_body != null and bodyAlwaysReturns(b.then_body) and bodyAlwaysReturns(b.else_body.?),
        else => false,
    };
}

pub fn bodyAlwaysReturns(body: []const Stmt) bool {
    for (body) |*stmt| if (stmtAlwaysReturns(stmt)) return true;
    return false;
}

/// Whether an expression reads `this` (so the enclosing method needs `self`).
pub fn exprUsesThis(e: *const Expr) bool {
    return switch (e.*) {
        .this_expr => true,
        .num, .float, .bool, .str, .regex, .null_lit, .var_ref => false,
        .array => |a| blk: {
            for (a.items) |it| if (exprUsesThis(it)) break :blk true;
            break :blk false;
        },
        .tuple_lit => |t| blk: {
            for (t.items) |it| if (exprUsesThis(it)) break :blk true;
            break :blk false;
        },
        .spread => |inner| exprUsesThis(inner),
        .typeof_expr => |to| exprUsesThis(to.operand),
        .inc_dec => |id| exprUsesThis(id.target),
        .neg, .not, .bnot, .await_expr => |inner| exprUsesThis(inner),
        .bin => |b| exprUsesThis(b.l) or exprUsesThis(b.r),
        .bool_bin => |b| exprUsesThis(b.l) or exprUsesThis(b.r),
        .cmp => |b| exprUsesThis(b.l) or exprUsesThis(b.r),
        .ternary => |t| exprUsesThis(t.cond) or exprUsesThis(t.then_expr) or exprUsesThis(t.else_expr),
        .coalesce => |c| exprUsesThis(c.l) or exprUsesThis(c.r),
        .arrow => |a| if (a.body_expr) |be| exprUsesThis(be) else false,
        .new_expr => |ne| blk: {
            for (ne.args) |it| if (exprUsesThis(it)) break :blk true;
            break :blk false;
        },
        .method_call => |mc| blk: {
            if (exprUsesThis(mc.obj)) break :blk true;
            for (mc.args) |it| if (exprUsesThis(it)) break :blk true;
            break :blk false;
        },
        .super_call => true, // emits `self.__super_...`
        .template => |parts| blk: {
            for (parts) |pt| if (pt.expr) |x| {
                if (exprUsesThis(x)) break :blk true;
            };
            break :blk false;
        },
        .obj => |fields| blk: {
            for (fields) |f| if (exprUsesThis(f.value)) break :blk true;
            break :blk false;
        },
        .field => |f| exprUsesThis(f.obj),
        .index => |idx| exprUsesThis(idx.obj) or exprUsesThis(idx.value),
        .call => |cl| blk: {
            for (cl.args) |it| if (exprUsesThis(it)) break :blk true;
            break :blk false;
        },
        .static_call => |sc| blk: {
            for (sc.args) |it| if (exprUsesThis(it)) break :blk true;
            break :blk false;
        },
        .optional_call => |oc| blk: {
            if (exprUsesThis(oc.callee)) break :blk true;
            for (oc.args) |it| if (exprUsesThis(it)) break :blk true;
            break :blk false;
        },
        .cast => |c| exprUsesThis(c.inner),
    };
}

pub fn stmtUsesThis(stmt: *const Stmt) bool {
    return switch (stmt.*) {
        .member_assign => |ma| ma.obj == null or exprUsesThis(ma.obj.?) or exprUsesThis(ma.value),
        .super_ctor => true, // inlined parent ctor writes `self.field`
        .var_decl => |d| exprUsesThis(d.init),
        .destructure_decl => |d| exprUsesThis(d.source),
        .assign => |a| exprUsesThis(a.value),
        .console_log => |log| exprUsesThis(log.value),
        .return_stmt => |r| if (r.value) |x| exprUsesThis(x) else false,
        .throw_stmt => |t| exprUsesThis(t.value),
        .expr_stmt => |x| exprUsesThis(x.value),
        .while_stmt => |w| exprUsesThis(w.cond) or bodyUsesThis(w.body),
        .do_while_stmt => |w| exprUsesThis(w.cond) or bodyUsesThis(w.body),
        .for_stmt => |f| (f.init != null and exprUsesThis(f.init.?.init)) or (f.cond != null and exprUsesThis(f.cond.?)) or (f.update != null and exprUsesThis(f.update.?.value)) or bodyUsesThis(f.body),
        .for_of_stmt => |f| exprUsesThis(f.iterable) or bodyUsesThis(f.body),
        .for_in_stmt => |f| exprUsesThis(f.iterable) or bodyUsesThis(f.body),
        .if_stmt => |b| exprUsesThis(b.cond) or bodyUsesThis(b.then_body) or (b.else_body != null and bodyUsesThis(b.else_body.?)),
        .switch_stmt => |sw| blk: {
            if (exprUsesThis(sw.value)) break :blk true;
            for (sw.cases) |cse| if (exprUsesThis(cse.value) or bodyUsesThis(cse.body)) break :blk true;
            if (sw.default_body) |db| if (bodyUsesThis(db)) break :blk true;
            break :blk false;
        },
        .try_stmt => |t| bodyUsesThis(t.try_body) or bodyUsesThis(t.catch_body) or (t.finally_body != null and bodyUsesThis(t.finally_body.?)),
        .defer_stmt => |d| bodyUsesThis(d.body),
        .using_decl => |u| blk: {
            if (u.defer_body) |b| if (bodyUsesThis(b)) break :blk true;
            if (u.dispose_call) |d| if (exprUsesThis(d)) break :blk true;
            break :blk exprUsesThis(u.init);
        },
        else => false,
    };
}

pub fn bodyUsesThis(body: []const Stmt) bool {
    for (body) |*s| if (stmtUsesThis(s)) return true;
    return false;
}

/// Emit `_ = name;` discards for any parameters the body never references, so
/// the generated Zig function compiles. (A no-op for fully-used parameter lists,
/// so non-generic functions are unaffected.)
pub fn emitUnusedParamDiscards(params: []const ast.FunctionParam, body: []const Stmt, w: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    for (params) |param| {
        if (!bodyUsesName(body, param.name)) {
            try w.print(arena, "    _ = {s};\n", .{param.name});
        }
    }
}

pub fn printFormat(t: types.Type) []const u8 {
    return switch (t) {
        .string, .string_literal_union => "{s}",
        .bool => "{}",
        .enum_type => |e| if (e.is_string) "{s}" else "{d}",
        .optional => |inner| switch (inner.*) {
            .string, .string_literal_union => "{?s}",
            .bool => "{?}",
            else => "{?d}",
        },
        else => "{d}",
    };
}
