//! Class codegen: lowers a `ClassDecl` to a Zig struct with fields, a `new`
//! constructor, and methods. Handles single inheritance by flattening the
//! `extends` chain (`collectChain`): parent fields/methods are copied down
//! (Zig has no struct inheritance), and `super.m(...)` calls
//! (`collectSuperInStmt`/`collectSuperInExpr`) are rewritten to call the
//! parent's emitted method directly.
//!
//! Pulled out of `lumen_emit.zig` as the "declaring a class" concern,
//! separate from statement/expression emission (which this calls into for
//! method/constructor bodies) and array/string method codegen.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const types = @import("lumen_types.zig");
const diag_mod = @import("lumen_diag.zig");
const emit_mod = @import("lumen_emit.zig");
const analysis = @import("lumen_emit_analysis.zig");
const emit_stmt = @import("lumen_emit_stmt.zig");

const CompileError = diag_mod.CompileError;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const CompileOptions = emit_mod.CompileOptions;
const emitStmtWithThrow = emit_mod.emitStmtWithThrow;
const emitExpr = emit_mod.emitExpr;
const bodyUsesThis = analysis.bodyUsesThis;
const emitUnusedParamDiscards = analysis.emitUnusedParamDiscards;
const zigZeroValue = analysis.zigZeroValue;

pub fn collectChain(c: *const ast.ClassDecl, arena: std.mem.Allocator) CompileError![]*const ast.ClassDecl {
    var list: std.ArrayListUnmanaged(*const ast.ClassDecl) = .empty;
    var cur: ?*const ast.ClassDecl = c;
    while (cur) |cc| {
        try list.append(arena, cc);
        cur = if (cc.parent) |p| emit_mod.findClass(p) else null;
    }
    // Reverse to root-first order.
    const items = list.items;
    var i: usize = 0;
    while (i < items.len / 2) : (i += 1) {
        const t = items[i];
        items[i] = items[items.len - 1 - i];
        items[items.len - 1 - i] = t;
    }
    return items;
}

/// A zero/default initializer literal for a static field of the given type.
pub fn zeroValue(ty: types.Type) []const u8 {
    return switch (ty) {
        .i32, .i64 => "0",
        .f64 => "0",
        .bool => "false",
        .string => "\"\"",
        else => "undefined",
    };
}

/// Lower a class to a Zig struct: ancestor fields are flattened in, instance
/// methods (own + inherited, with overrides) are emitted bound to the struct,
/// `super.method` copies are emitted under internal names, statics become struct
/// globals/free functions, and getters/setters become `__get_`/`__set_` methods.
pub fn emitClass(c: *const ast.ClassDecl, decls: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, throw_target: ?[]const u8, switch_break_target: ?[]const u8, options: CompileOptions) CompileError!void {
    const chain = try collectChain(c, arena);

    try decls.print(arena, "const {s} = struct {{\n", .{c.name});

    // Instance fields, ancestors first (flattened layout).
    for (chain) |cc| {
        for (cc.fields) |field| {
            if (field.is_static) continue;
            try decls.appendSlice(arena, "    ");
            try emit_mod.emitFieldName(decls, arena, field.name);
            try decls.print(arena, ": {s},\n", .{try types.zigName(arena, field.checked_type orelse return error.ParseError)});
        }
    }

    // Static fields -> struct-scoped vars with a zero default. Declared only on
    // the owning class so the whole hierarchy shares one storage location,
    // accessed as `Owner.__static_Owner_field`.
    for (c.fields) |field| {
        if (!field.is_static) continue;
        const ty = field.checked_type orelse return error.ParseError;
        try decls.print(arena, "    var __static_{s}_{s}: {s} = ", .{ c.name, field.name, try types.zigName(arena, ty) });
        // Use the declared initializer (a literal in the common case); a field
        // without one gets the type's zero value.
        if (field.init) |ie| {
            try emitExpr(ie, decls, arena);
        } else {
            try decls.appendSlice(arena, zeroValue(ty));
        }
        try decls.appendSlice(arena, ";\n");
    }

    // Constructor: resolve the nearest ctor among the chain that the most
    // derived class provides; if the class has none, inherit the parent's.
    try decls.print(arena, "    fn __init(", .{});
    var ctor_owner: *const ast.ClassDecl = c;
    if (!c.has_ctor) {
        var k: usize = chain.len;
        while (k > 0) {
            k -= 1;
            if (chain[k].has_ctor) {
                ctor_owner = chain[k];
                break;
            }
        }
    }
    for (ctor_owner.ctor_params, 0..) |param, i| {
        if (i > 0) try decls.appendSlice(arena, ", ");
        try decls.print(arena, "{s}: {s}", .{ try analysis.paramSigName(arena, param, ctor_owner.ctor_body), try types.zigName(arena, param.checked_type orelse return error.ParseError) });
    }
    // A throwing constructor chain returns an error union (spec 248).
    const ctor_throws = analysis.g_method_arena != null and analysis.ctorThrows(analysis.g_method_arena.?, c.name);
    if (ctor_throws) {
        try decls.print(arena, ") error{{LumenThrow}}!*{s} {{\n", .{c.name});
    } else {
        try decls.print(arena, ") *{s} {{\n", .{c.name});
    }
    try decls.print(arena, "    const self = __sa().create({s}) catch unreachable;\n", .{c.name});
    // `create` returns undefined memory; an optional field with no initializer
    // and no ctor assignment must read `null`, not garbage. Null them up front
    // (a ctor that assigns the field overwrites this).
    try emitOptionalFieldNulls(chain, decls, arena);
    {
        const saved_can_error = emit_mod.g_fn_can_error;
        emit_mod.g_fn_can_error = ctor_throws;
        defer emit_mod.g_fn_can_error = saved_can_error;
        try emitUnusedParamDiscards(ctor_owner.ctor_params, ctor_owner.ctor_body, decls, arena);
        try analysis.emitReassignedParamCopies(ctor_owner.ctor_params, ctor_owner.ctor_body, decls, arena);
        try emit_stmt.emitBody(ctor_owner.ctor_body, decls, decls, arena, throw_target, switch_break_target, options);
    }
    try decls.appendSlice(arena, "    return self;\n    }\n");

    // Value-returning constructor for stack allocation (spec 344): builds the
    // instance in place and returns it by value, so a non-escaping `new C(...)`
    // can live on the caller's stack (`var s = C.__initv(...); &s`). Only for a
    // non-throwing ctor chain (throwing ctors keep the heap `__init` path).
    if (!ctor_throws) {
        try decls.print(arena, "    fn __initv(", .{});
        for (ctor_owner.ctor_params, 0..) |param, i| {
            if (i > 0) try decls.appendSlice(arena, ", ");
            try decls.print(arena, "{s}: {s}", .{ try analysis.paramSigName(arena, param, ctor_owner.ctor_body), try types.zigName(arena, param.checked_type orelse return error.ParseError) });
        }
        try decls.print(arena, ") {s} {{\n", .{c.name});
        // A ctor that writes fields needs `var self`; one that never touches
        // `this` (fieldless/empty ctor) leaves it unmutated, so use `const` to
        // avoid Zig's "local variable is never mutated" error.
        const initv_mut = bodyUsesThis(ctor_owner.ctor_body) or hasOptionalNoInit(chain);
        try decls.print(arena, "    {s} self: {s} = undefined;\n", .{ if (initv_mut) "var" else "const", c.name });
        if (initv_mut) try emitOptionalFieldNulls(chain, decls, arena);
        {
            const saved_can_error = emit_mod.g_fn_can_error;
            emit_mod.g_fn_can_error = false;
            defer emit_mod.g_fn_can_error = saved_can_error;
            try emitUnusedParamDiscards(ctor_owner.ctor_params, ctor_owner.ctor_body, decls, arena);
            try analysis.emitReassignedParamCopies(ctor_owner.ctor_params, ctor_owner.ctor_body, decls, arena);
            try emit_stmt.emitBody(ctor_owner.ctor_body, decls, decls, arena, throw_target, switch_break_target, options);
        }
        try decls.appendSlice(arena, "    return self;\n    }\n");
    }

    // Instance methods, getters, setters: most-derived definition wins. Walk the
    // chain root-first; a later (more derived) definition overwrites an earlier
    // one by emitting under the same name, so emit only the resolved definition.
    var emitted: std.StringHashMapUnmanaged(void) = .empty;
    var d: usize = chain.len;
    while (d > 0) {
        d -= 1;
        const cc = chain[d];
        for (cc.methods) |m| {
            if (m.is_static) continue;
            const key = switch (m.accessor) {
                .none => try std.fmt.allocPrint(arena, "m:{s}", .{m.name}),
                .getter => try std.fmt.allocPrint(arena, "g:{s}", .{m.name}),
                .setter => try std.fmt.allocPrint(arena, "s:{s}", .{m.name}),
            };
            if (emitted.contains(key)) continue;
            try emitted.put(arena, key, {});
            try emitClassMethod(c.name, m, decls, arena, throw_target, switch_break_target, options);
        }
    }

    // `super.method` copies: for each super call in the class's methods/ctor,
    // emit a copy of the resolved ancestor method as `__super_<owner>_<name>`.
    var super_emitted: std.StringHashMapUnmanaged(void) = .empty;
    for (c.methods) |m| try emitSuperCopies(c, m.body, decls, arena, &super_emitted, throw_target, switch_break_target, options);
    try emitSuperCopies(c, c.ctor_body, decls, arena, &super_emitted, throw_target, switch_break_target, options);

    // `super(...)` parent-constructor helpers: emit `__superctor_<owner>` for
    // each ancestor that has a constructor, bound to the most-derived struct so
    // its parameters live in their own scope (no shadowing of the child ctor).
    for (chain) |cc| {
        if (std.mem.eql(u8, cc.name, c.name)) continue; // not the class itself
        if (!cc.has_ctor) continue;
        const h_throws = analysis.g_method_arena != null and analysis.ctorThrows(analysis.g_method_arena.?, cc.name);
        try decls.print(arena, "    fn __superctor_{s}(self: *{s}", .{ cc.name, c.name });
        for (cc.ctor_params) |param| {
            try decls.print(arena, ", {s}: {s}", .{ param.name, try types.zigName(arena, param.checked_type orelse return error.ParseError) });
        }
        try decls.appendSlice(arena, if (h_throws) ") error{LumenThrow}!void {\n" else ") void {\n");
        if (!bodyUsesThis(cc.ctor_body)) try decls.appendSlice(arena, "    _ = self;\n");
        {
            const saved_can_error = emit_mod.g_fn_can_error;
            emit_mod.g_fn_can_error = h_throws;
            defer emit_mod.g_fn_can_error = saved_can_error;
            try emitUnusedParamDiscards(cc.ctor_params, cc.ctor_body, decls, arena);
            try emit_stmt.emitBody(cc.ctor_body, decls, decls, arena, throw_target, switch_break_target, options);
        }
        try decls.appendSlice(arena, "    }\n");
    }

    // Static methods -> struct-scoped free functions `__static_m_<name>`,
    // declared only on their owning class and called as `Owner.__static_m_x`.
    {
        const cc = c;
        for (cc.methods) |m| {
            if (!m.is_static) continue;
            const m_throws = m.accessor == .none and analysis.g_method_arena != null and analysis.methodThrows(analysis.g_method_arena.?, m.name);
            try decls.print(arena, "    fn __static_m_{s}(", .{m.name});
            for (m.params, 0..) |param, i| {
                if (i > 0) try decls.appendSlice(arena, ", ");
                try decls.print(arena, "{s}: {s}", .{ try analysis.paramSigName(arena, param, m.body), try types.zigName(arena, param.checked_type orelse return error.ParseError) });
            }
            if (m_throws) {
                try decls.print(arena, ") error{{LumenThrow}}!{s} {{\n", .{try types.zigName(arena, m.checked_return_type orelse return error.ParseError)});
            } else {
                try decls.print(arena, ") {s} {{\n", .{try types.zigName(arena, m.checked_return_type orelse return error.ParseError)});
            }
            const saved_can_error = emit_mod.g_fn_can_error;
            emit_mod.g_fn_can_error = m_throws;
            defer emit_mod.g_fn_can_error = saved_can_error;
            // A static async method resolves its promise on `return`, same as an
            // instance async method (spec 372).
            const s_ret = m.checked_return_type orelse return error.ParseError;
            const s_prev_async = emit_mod.g_async_inner;
            if (m.is_async and s_ret == .promise_type) {
                emit_mod.g_async_inner = try types.zigName(arena, s_ret.promise_type.*);
            } else {
                emit_mod.g_async_inner = null;
            }
            defer emit_mod.g_async_inner = s_prev_async;
            try emitUnusedParamDiscards(m.params, m.body, decls, arena);
            try analysis.emitReassignedParamCopies(m.params, m.body, decls, arena);
            try emit_stmt.emitBody(m.body, decls, decls, arena, throw_target, switch_break_target, options);
            if (m.is_async and s_ret == .promise_type and s_ret.promise_type.* == .void and !analysis.bodyAlwaysReturns(m.body)) {
                try decls.appendSlice(arena, "    return __promiseResolved(void, {});\n");
            }
            try decls.appendSlice(arena, "    }\n");
        }
    }

    try decls.appendSlice(arena, "};\n");
    // Per-interface vtables for polymorphic dispatch (spec 428).
    try emitClassVtables(c, decls, arena);
}

/// Whether any instance field in the chain is optional with no initializer
/// (so it needs an explicit `= null` at construction).
fn hasOptionalNoInit(chain: []const *const ast.ClassDecl) bool {
    for (chain) |cc| {
        for (cc.fields) |field| {
            if (field.is_static) continue;
            if (field.init == null and field.checked_type != null and field.checked_type.? == .optional) return true;
        }
    }
    return false;
}

/// Emit `self.<field> = null;` for every optional instance field with no
/// initializer, so an unset optional field reads `null` rather than undefined.
fn emitOptionalFieldNulls(chain: []const *const ast.ClassDecl, decls: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    for (chain) |cc| {
        for (cc.fields) |field| {
            if (field.is_static) continue;
            if (field.init != null) continue;
            const fty = field.checked_type orelse continue;
            if (fty != .optional) continue;
            try decls.appendSlice(arena, "    self.");
            try emit_mod.emitFieldName(decls, arena, field.name);
            try decls.appendSlice(arena, " = null;\n");
        }
    }
}

pub fn emitClassMethod(self_type: []const u8, m: ast.FunctionDecl, decls: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, throw_target: ?[]const u8, switch_break_target: ?[]const u8, options: CompileOptions) CompileError!void {
    const fn_name = switch (m.accessor) {
        .none => m.name,
        .getter => try std.fmt.allocPrint(arena, "__get_{s}", .{m.name}),
        .setter => try std.fmt.allocPrint(arena, "__set_{s}", .{m.name}),
    };
    // Exception propagation (spec 245/247): a throwing method returns an error
    // union. Super copies are renamed `__super_<owner>_<name>`; strip the
    // prefix back to the source name for the throwing-set lookup and the
    // stack-trace frame.
    var src_name = m.name;
    var frame_owner = self_type;
    if (std.mem.startsWith(u8, src_name, "__super_")) {
        const rest = src_name["__super_".len..];
        if (std.mem.lastIndexOfScalar(u8, rest, '_')) |us| {
            frame_owner = rest[0..us]; // trace the copy as `Owner.method`
            src_name = rest[us + 1 ..];
        }
    }
    const m_throws = m.accessor == .none and analysis.g_method_arena != null and analysis.methodThrows(analysis.g_method_arena.?, src_name);
    // Escape a method name that collides with a Zig keyword/primitive (`test`,
    // `error`, `type`, ...) as `@"name"` (spec 429).
    try decls.appendSlice(arena, "    fn ");
    try emit_mod.emitFieldName(decls, arena, fn_name);
    try decls.print(arena, "(self: *{s}", .{self_type});
    for (m.params) |param| {
        const pt = param.checked_type orelse return error.ParseError;
        const ztype = if (param.is_ref) try types.refZigName(arena, pt) else try types.zigName(arena, pt);
        try decls.print(arena, ", {s}: {s}", .{ try analysis.paramSigName(arena, param, m.body), ztype });
    }
    if (m_throws) {
        try decls.print(arena, ") error{{LumenThrow}}!{s} {{\n", .{try types.zigName(arena, m.checked_return_type orelse return error.ParseError)});
    } else {
        try decls.print(arena, ") {s} {{\n", .{try types.zigName(arena, m.checked_return_type orelse return error.ParseError)});
    }
    const saved_can_error = emit_mod.g_fn_can_error;
    emit_mod.g_fn_can_error = m_throws;
    defer emit_mod.g_fn_can_error = saved_can_error;
    // An async method returns `*LumenPromise(T)`; `return v` in its body resolves
    // the promise with `v` (same as an async free function, spec-established).
    const return_type = m.checked_return_type orelse return error.ParseError;
    const prev_async_inner = emit_mod.g_async_inner;
    if (m.is_async and return_type == .promise_type) {
        emit_mod.g_async_inner = try types.zigName(arena, return_type.promise_type.*);
    } else {
        emit_mod.g_async_inner = null;
    }
    defer emit_mod.g_async_inner = prev_async_inner;
    if (!bodyUsesThis(m.body)) try decls.appendSlice(arena, "    _ = self;\n");
    // Stack-trace frame for the method (shown as `Class.method`).
    if (options.runtime_locations) {
        try decls.print(arena, "    __lumenPush(\"{s}.{s}\"); defer __lumenPop();\n", .{ frame_owner, src_name });
    }
    try emitUnusedParamDiscards(m.params, m.body, decls, arena);
    try analysis.emitReassignedParamCopies(m.params, m.body, decls, arena);
    try emit_stmt.emitBody(m.body, decls, decls, arena, throw_target, switch_break_target, options);
    // An async `Promise<void>` method may fall through without a `return`; emit a
    // trailing resolved promise so it still returns a value.
    if (m.is_async and return_type == .promise_type and return_type.promise_type.* == .void and !analysis.bodyAlwaysReturns(m.body)) {
        try decls.appendSlice(arena, "    return __promiseResolved(void, {});\n");
    }
    try decls.appendSlice(arena, "    }\n");
}

/// Emit `__super_<owner>_<name>` method copies for every `super.method` call
/// referenced inside `body`, bound to the most-derived struct `c`.
pub fn emitSuperCopies(c: *const ast.ClassDecl, body: []const Stmt, decls: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, seen: *std.StringHashMapUnmanaged(void), throw_target: ?[]const u8, switch_break_target: ?[]const u8, options: CompileOptions) CompileError!void {
    for (body) |*stmt| try collectSuperInStmt(c, stmt, decls, arena, seen, throw_target, switch_break_target, options);
}

pub fn collectSuperInStmt(c: *const ast.ClassDecl, stmt: *const Stmt, decls: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, seen: *std.StringHashMapUnmanaged(void), throw_target: ?[]const u8, switch_break_target: ?[]const u8, options: CompileOptions) CompileError!void {
    switch (stmt.*) {
        .expr_stmt => |x| try collectSuperInExpr(c, x.value, decls, arena, seen, throw_target, switch_break_target, options),
        .return_stmt => |r| if (r.value) |v| try collectSuperInExpr(c, v, decls, arena, seen, throw_target, switch_break_target, options),
        .var_decl => |v| try collectSuperInExpr(c, v.init, decls, arena, seen, throw_target, switch_break_target, options),
        .member_assign => |ma| try collectSuperInExpr(c, ma.value, decls, arena, seen, throw_target, switch_break_target, options),
        .console_log => |log| try collectSuperInExpr(c, log.value, decls, arena, seen, throw_target, switch_break_target, options),
        .if_stmt => |b| {
            try collectSuperInExpr(c, b.cond, decls, arena, seen, throw_target, switch_break_target, options);
            try emitSuperCopies(c, b.then_body, decls, arena, seen, throw_target, switch_break_target, options);
            if (b.else_body) |eb| try emitSuperCopies(c, eb, decls, arena, seen, throw_target, switch_break_target, options);
        },
        .while_stmt => |w| try emitSuperCopies(c, w.body, decls, arena, seen, throw_target, switch_break_target, options),
        .for_stmt => |f| try emitSuperCopies(c, f.body, decls, arena, seen, throw_target, switch_break_target, options),
        .for_of_stmt => |f| try emitSuperCopies(c, f.body, decls, arena, seen, throw_target, switch_break_target, options),
        .for_in_stmt => |f| try emitSuperCopies(c, f.body, decls, arena, seen, throw_target, switch_break_target, options),
        else => {},
    }
}

pub fn collectSuperInExpr(c: *const ast.ClassDecl, e: *const Expr, decls: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, seen: *std.StringHashMapUnmanaged(void), throw_target: ?[]const u8, switch_break_target: ?[]const u8, options: CompileOptions) CompileError!void {
    switch (e.*) {
        .super_call => |sc| {
            const owner = sc.parent orelse return;
            const key = try std.fmt.allocPrint(arena, "{s}:{s}", .{ owner, sc.name });
            for (sc.args) |a| try collectSuperInExpr(c, a, decls, arena, seen, throw_target, switch_break_target, options);
            if (seen.contains(key)) return;
            try seen.put(arena, key, {});
            // Find the resolved ancestor method and emit a copy bound to `c`.
            const oc = emit_mod.findClass(owner) orelse return;
            for (oc.methods) |m| {
                if (m.accessor == .none and !m.is_static and std.mem.eql(u8, m.name, sc.name)) {
                    var copy = m;
                    copy.name = try std.fmt.allocPrint(arena, "__super_{s}_{s}", .{ owner, sc.name });
                    try emitClassMethod(c.name, copy, decls, arena, throw_target, switch_break_target, options);
                    // The copied ancestor method may itself call `super.x()`
                    // (a deeper level of the chain); emit those copies too so a
                    // 3+-level `super` chain resolves (spec 352).
                    try emitSuperCopies(c, m.body, decls, arena, seen, throw_target, switch_break_target, options);
                    return;
                }
            }
        },
        .bin => |b| {
            try collectSuperInExpr(c, b.l, decls, arena, seen, throw_target, switch_break_target, options);
            try collectSuperInExpr(c, b.r, decls, arena, seen, throw_target, switch_break_target, options);
        },
        .method_call => |mc| {
            try collectSuperInExpr(c, mc.obj, decls, arena, seen, throw_target, switch_break_target, options);
            for (mc.args) |a| try collectSuperInExpr(c, a, decls, arena, seen, throw_target, switch_break_target, options);
        },
        .call => |cl| for (cl.args) |a| try collectSuperInExpr(c, a, decls, arena, seen, throw_target, switch_break_target, options),
        .field => |f| try collectSuperInExpr(c, f.obj, decls, arena, seen, throw_target, switch_break_target, options),
        else => {},
    }
}

// ===== Interface polymorphism (spec 428) =====

/// Find an interface declaration's method fields by name in the program.
fn ifaceMethods(name: []const u8) ?[]const ast.TypeField {
    const prog = emit_mod.g_program orelse return null;
    for (prog.stmts) |*stmt| {
        if (stmt.* == .type_decl and stmt.type_decl.is_interface and std.mem.eql(u8, stmt.type_decl.name, name)) {
            return stmt.type_decl.fields;
        }
    }
    return null;
}

/// An interface method's vtable return type: `error{LumenThrow}!R` when any
/// implementation of a like-named method throws (the throwing analysis is
/// name-based, so every same-named method shares the throwing signature), else
/// plain `R` (spec 431).
pub fn ifaceMethodThrows(name: []const u8) bool {
    return analysis.g_method_arena != null and analysis.methodThrows(analysis.g_method_arena.?, name);
}

fn vtRetType(name: []const u8, ret: types.Type, arena: std.mem.Allocator) CompileError![]const u8 {
    const r = try types.zigName(arena, ret);
    if (ifaceMethodThrows(name)) return std.fmt.allocPrint(arena, "error{{LumenThrow}}!{s}", .{r});
    return r;
}

/// Emit an interface's vtable type and fat-pointer struct:
///   const VT_<Name> = struct { m: *const fn(*anyopaque, P...) R, ... };
///   const LumenIface_<Name> = struct { __ptr: *anyopaque, __vt: *const VT_<Name> };
pub fn emitIfaceDecl(decl: *const ast.TypeDecl, decls: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    try decls.print(arena, "const VT_{s} = struct {{\n", .{decl.name});
    for (decl.fields) |f| {
        const ft = f.checked_type orelse continue;
        if (ft != .func_type) continue;
        try decls.appendSlice(arena, "    ");
        try emit_mod.emitFieldName(decls, arena, f.name);
        try decls.appendSlice(arena, ": *const fn (*anyopaque");
        for (ft.func_type.params) |p| try decls.print(arena, ", {s}", .{try types.zigName(arena, p)});
        try decls.print(arena, ") {s},\n", .{try vtRetType(f.name, ft.func_type.ret.*, arena)});
    }
    try decls.appendSlice(arena, "};\n");
    try decls.print(arena, "const LumenIface_{s} = struct {{ __ptr: *anyopaque, __vt: *const VT_{s} }};\n", .{ decl.name, decl.name });
}

/// Emit the per-(class, interface) vtable instances for every interface a class
/// implements: each method entry is a wrapper that casts the erased `*anyopaque`
/// back to `*Class` and calls the real method.
pub fn emitClassVtables(c: *const ast.ClassDecl, decls: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    for (c.implements) |iface| {
        const methods = ifaceMethods(iface) orelse continue;
        try decls.print(arena, "const __vt_{s}_{s}: VT_{s} = .{{\n", .{ c.name, iface, iface });
        for (methods) |f| {
            const ft = f.checked_type orelse continue;
            if (ft != .func_type) continue;
            try decls.appendSlice(arena, "    .");
            try emit_mod.emitFieldName(decls, arena, f.name);
            try decls.appendSlice(arena, " = &struct {\n        fn __w(__p: *anyopaque");
            for (ft.func_type.params, 0..) |p, i| try decls.print(arena, ", __a{d}: {s}", .{ i, try types.zigName(arena, p) });
            try decls.print(arena, ") {s} {{\n            return @as(*{s}, @ptrCast(@alignCast(__p))).", .{ try vtRetType(f.name, ft.func_type.ret.*, arena), c.name });
            try emit_mod.emitFieldName(decls, arena, f.name);
            try decls.appendSlice(arena, "(");
            for (ft.func_type.params, 0..) |_, i| {
                if (i > 0) try decls.appendSlice(arena, ", ");
                try decls.print(arena, "__a{d}", .{i});
            }
            try decls.appendSlice(arena, ");\n        }\n    }.__w,\n");
        }
        try decls.appendSlice(arena, "};\n");
    }
}
