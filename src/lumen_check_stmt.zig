//! Statement and function/class-body type-checking.
//!
//! `checkStmt` is the statement-level dispatch (the `Stmt`-union counterpart of
//! `exprType`): one case per statement kind (`if`/`while`/`for`/`switch`/
//! `try`/`return`/declarations/...), walking the body and recursing into
//! nested blocks. `checkFunctionBody`/`checkClass`/`checkMemberAssign` set up
//! the scope (parameters, `this`, fields) before checking a function/class/
//! field-write's body, and `blockReturns`/`stmtReturns` decide whether a
//! function body returns on every path (so `return`-less branches type-check
//! `void`).
//!
//! Pulled out of `lumen_check.zig` as the "checking a construct's body"
//! concern, separate from generics/class-lookup/stdlib-call typing and from
//! `exprType`/`ensureAssignable` (single-expression typing), which this module
//! calls into but does not define.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const types = @import("lumen_types.zig");
const diag_mod = @import("lumen_diag.zig");
const check_mod = @import("lumen_check.zig");

const Checker = check_mod.Checker;
const CompileError = diag_mod.CompileError;

pub fn declareExtern(self: *Checker, decl: *ast.ExternDecl) CompileError!void {
    if (self.funcs.get(decl.name) != null) return self.fail(decl.line, decl.col, "E_DUPLICATE_BINDING");
    const ret = try self.typeFromAnnotation(decl.return_annotation, decl.line, decl.col);
    if (!check_mod.isCSafe(ret) and ret != .void) return self.fail(decl.line, decl.col, "E_FFI_TYPE");
    decl.checked_return_type = ret;
    for (decl.params) |*param| {
        // `Ref<T>` is not part of the C ABI surface.
        if (check_mod.refInner(param.annotation) != null) return self.fail(decl.line, decl.col, "E_FFI_TYPE");
        param.checked_type = try self.typeFromAnnotation(param.annotation, decl.line, decl.col);
        if (!check_mod.isCSafe(param.checked_type.?)) return self.fail(decl.line, decl.col, "E_FFI_TYPE");
    }
    self.funcs.put(self.arena, decl.name, .{ .params = decl.params, .return_type = ret, .is_extern = true }) catch return error.OutOfMemory;
}

/// Statement position for diagnostics (first carried line/col).
fn stmtPos(stmt: *const ast.Stmt) struct { line: u32, col: u32 } {
    return switch (stmt.*) {
        .type_decl => |d| .{ .line = d.line, .col = d.col },
        .enum_decl => |d| .{ .line = d.line, .col = d.col },
        .test_decl => |d| .{ .line = d.line, .col = d.col },
        .extern_decl => |d| .{ .line = d.line, .col = d.col },
        .class_decl => |d| .{ .line = d.line, .col = d.col },
        .function_decl => |d| .{ .line = d.line, .col = d.col },
        .var_decl => |d| .{ .line = d.line, .col = d.col },
        .var_decl_group => |g| .{ .line = g[0].line, .col = g[0].col },
        .using_decl => |d| .{ .line = d.line, .col = d.col },
        .destructure_decl => |d| .{ .line = d.line, .col = d.col },
        .member_assign => |d| .{ .line = d.line, .col = d.col },
        .super_ctor => |d| .{ .line = d.line, .col = d.col },
        .assign => |d| .{ .line = d.line, .col = d.col },
        .console_log => |d| .{ .line = d.line, .col = d.col },
        .while_stmt => |d| .{ .line = d.line, .col = d.col },
        .do_while_stmt => |d| .{ .line = d.line, .col = d.col },
        .for_stmt => |d| .{ .line = d.line, .col = d.col },
        .for_of_stmt => |d| .{ .line = d.line, .col = d.col },
        .for_in_stmt => |d| .{ .line = d.line, .col = d.col },
        .if_stmt => |d| .{ .line = d.line, .col = d.col },
        .switch_stmt => |d| .{ .line = d.line, .col = d.col },
        .return_stmt => |d| .{ .line = d.line, .col = d.col },
        .throw_stmt => |d| .{ .line = d.line, .col = d.col },
        .try_stmt => |d| .{ .line = d.line, .col = d.col },
        .break_stmt => |d| .{ .line = d.line, .col = d.col },
        .continue_stmt => |d| .{ .line = d.line, .col = d.col },
        .defer_stmt => |d| .{ .line = d.line, .col = d.col },
        .expr_stmt => |d| .{ .line = d.line, .col = d.col },
        .block_stmt => |d| .{ .line = d.line, .col = d.col },
    };
}

/// Warn once for statements that can never run: anything after an
/// unconditional `return`/`throw`/`break`/`continue` in the same block.
fn warnUnreachable(self: *Checker, body: []ast.Stmt) void {
    for (body, 0..) |*stmt, i| {
        const diverges = switch (stmt.*) {
            .return_stmt, .throw_stmt, .break_stmt, .continue_stmt => true,
            else => false,
        };
        if (diverges and i + 1 < body.len) {
            const pos = stmtPos(&body[i + 1]);
            self.warnings.append(self.arena, .{ .line = pos.line, .col = pos.col, .msg = "unreachable code" }) catch {};
            return;
        }
    }
}

pub fn checkBlock(self: *Checker, program: *ast.Program, body: []ast.Stmt) CompileError!void {
    try self.pushScope();
    defer self.popScope();
    // Early-return narrowing (spec 259) appends entries that live until the
    // end of the enclosing block; restore the list on exit.
    const nv_len = self.narrowed_variants.items.len;
    defer self.narrowed_variants.items.len = nv_len;
    const n_len = self.narrowed.items.len;
    defer self.narrowed.items.len = n_len;
    self.nested_stmt_depth += 1;
    defer self.nested_stmt_depth -= 1;
    warnUnreachable(self, body);
    for (body) |*body_stmt| try self.checkStmt(program, body_stmt);
}

pub fn checkFunctionBody(self: *Checker, program: *ast.Program, decl: *ast.FunctionDecl) CompileError!void {
    const previous_return_type = self.current_return_type;
    // Inside an async body, a `return v;` resolves the promise with `v`, so the
    // return value is checked against the promise's inner type `T`.
    self.current_return_type = if (decl.is_async and decl.checked_return_type != null and decl.checked_return_type.? == .promise_type)
        decl.checked_return_type.?.promise_type.*
    else
        decl.checked_return_type;
    defer self.current_return_type = previous_return_type;
    const previous_in_async = self.in_async;
    const previous_in_function = self.in_function;
    self.in_async = decl.is_async;
    self.in_function = true;
    // An async function lowers to a Promise-returning function, so the runtime
    // is required even when the body never awaits.
    if (decl.is_async) program.needs_async = true;
    defer {
        self.in_async = previous_in_async;
        self.in_function = previous_in_function;
    }

    // A default value must be assignable to its parameter's declared type.
    for (decl.params) |param| {
        if (param.default) |d| {
            const pt = param.checked_type orelse return self.fail(decl.line, decl.col, "E_TYPE_MISMATCH");
            self.ensureAssignable(program, pt, d, decl.line, decl.col) catch {
                return self.fail(decl.line, decl.col, "E_TYPE_MISMATCH");
            };
        }
    }
    try self.pushScope();
    defer self.popScope();
    for (decl.params) |param| try self.declareParam(param, decl.line, decl.col);
    self.nested_stmt_depth += 1;
    defer self.nested_stmt_depth -= 1;
    warnUnreachable(self, decl.body);
    for (decl.body) |*body_stmt| try self.checkStmt(program, body_stmt);

    // The effective return type: for an async function this is the promise's
    // inner type (`Promise<void>` need not return), set in current_return_type.
    const return_type = self.current_return_type orelse decl.checked_return_type orelse try self.typeFromAnnotation(decl.return_annotation, decl.line, decl.col);
    if (return_type != .void and !blockReturns(decl.body)) {
        return self.fail(decl.line, decl.col, "E_MISSING_RETURN");
    }
}

pub fn checkClass(self: *Checker, program: *ast.Program, c: *ast.ClassDecl) CompileError!void {
    const prev = self.current_class;
    self.current_class = c.name;
    defer self.current_class = prev;

    // Validate the parent reference and reject inheritance cycles.
    if (c.parent) |pname| {
        if (self.classes.get(pname) == null) return self.fail(c.line, c.col, "E_TYPE_MISMATCH");
        var cur: ?[]const u8 = pname;
        while (cur) |name| {
            if (std.mem.eql(u8, name, c.name)) return self.fail(c.line, c.col, "E_TYPE_MISMATCH");
            cur = (self.classes.get(name) orelse break).parent;
        }
    }

    // `implements I`: every interface member must be provided by the class
    // (own or inherited).
    for (c.implements) |iface| {
        const tinfo = self.type_decls.get(iface) orelse return self.fail(c.line, c.col, "E_TYPE_MISMATCH");
        for (tinfo.fields) |req| {
            if (self.resolveField(c.name, req.name) != null) continue;
            if (self.resolveMethod(c.name, req.name) != null) continue;
            if (self.resolveAccessor(c.name, req.name, .getter) != null) continue;
            const msg = std.fmt.allocPrint(self.arena, "class '{s}' is missing member '{s}' required by interface `{s}`", .{ c.name, req.name, iface }) catch "E_MISSING_MEMBER";
            return self.fail(c.line, c.col, msg);
        }
    }

    // Whether the parent has a parameterized constructor that requires a
    // matching `super(...)` call in this child's constructor.
    const parent_needs_super = blk: {
        var cur = c.parent;
        while (cur) |pname| {
            const pinfo = self.classes.get(pname) orelse break;
            if (pinfo.has_ctor) break :blk pinfo.ctor_params.len > 0;
            cur = pinfo.parent;
        }
        break :blk false;
    };

    if (c.has_ctor) {
        try self.pushScope();
        defer self.popScope();
        for (c.ctor_params) |param| try self.declareParam(param, c.line, c.col);
        self.nested_stmt_depth += 1;
        defer self.nested_stmt_depth -= 1;
        self.in_constructor = true;
        defer self.in_constructor = false;
        // A `super(...)` call, if present, must be the first statement.
        var has_super = false;
        for (c.ctor_body, 0..) |*body_stmt, i| {
            if (body_stmt.* == .super_ctor) {
                if (i != 0) return self.fail(c.line, c.col, "E_MISSING_SUPER");
                has_super = true;
            }
        }
        if (parent_needs_super and !has_super) return self.fail(c.line, c.col, "E_MISSING_SUPER");
        for (c.ctor_body) |*body_stmt| try self.checkStmt(program, body_stmt);
    } else if (parent_needs_super) {
        // No constructor at all but the parent demands super args.
        return self.fail(c.line, c.col, "E_MISSING_SUPER");
    }
    for (c.methods) |*m| try self.checkFunctionBody(program, m);
}

pub fn checkMemberAssign(self: *Checker, program: *ast.Program, ma: *ast.MemberAssign) CompileError!void {
    // `obj.field = value` / `Class.staticField = value` / setter write.
    if (ma.obj) |obj| {
        // Static field write: `Class.field = value`.
        if (obj.* == .var_ref and self.bindingPtr(obj.var_ref.name) == null and self.classes.get(obj.var_ref.name) != null) {
            const cname = obj.var_ref.name;
            const rf = self.resolveStaticField(cname, ma.field) orelse return self.fail(ma.line, ma.col, "E_TYPE_MISMATCH");
            try self.checkVisibility(rf.field.visibility, rf.owner, ma.line, ma.col);
            if (rf.field.is_readonly) return self.fail(ma.line, ma.col, "E_READONLY_ASSIGNMENT");
            ma.is_static = true;
            ma.class_name = rf.owner;
            try self.assignField(program, rf.field.checked_type orelse return error.ParseError, ma);
            return;
        }
        const obj_type = self.exprType(program, obj, ma.line, ma.col) orelse
            return self.inferenceFail(ma.line, ma.col, "cannot infer assignment target type");
        // A record `Ref<T>` parameter is mutable through its pointer: writes to
        // its fields (or fields of a sub-record reached from it) are allowed.
        if (obj_type == .named and self.refRooted(obj)) {
            const ft = self.recordFieldType(obj_type.named, ma.field) orelse
                return self.fail(ma.line, ma.col, "E_TYPE_MISMATCH");
            try self.assignField(program, ft, ma);
            return;
        }
        // Records and other non-class shapes are immutable in V1: writing a
        // field on them is a dynamic property write.
        if (obj_type != .class_type) return self.fail(ma.line, ma.col, "E_DYNAMIC_PROPERTY_WRITE");
        const cls = obj_type.class_type;
        // Setter property write: `obj.prop = value`.
        if (self.resolveField(cls, ma.field) == null) {
            if (self.resolveAccessor(cls, ma.field, .setter)) |ra| {
                try self.checkVisibility(ra.method.visibility, ra.owner, ma.line, ma.col);
                if (!std.mem.eql(u8, ma.op, "=")) return self.fail(ma.line, ma.col, "E_TYPE_MISMATCH");
                ma.is_setter = true;
                ma.class_name = cls;
                const pt = if (ra.method.params.len == 1) ra.method.params[0].checked_type orelse return error.ParseError else return self.fail(ma.line, ma.col, "E_ARG_COUNT");
                try self.ensureAssignable(program, pt, ma.value, ma.line, ma.col);
                return;
            }
            return self.fail(ma.line, ma.col, "E_TYPE_MISMATCH");
        }
        const rf = self.resolveField(cls, ma.field).?;
        try self.checkVisibility(rf.field.visibility, rf.owner, ma.line, ma.col);
        // External writes to readonly fields are never allowed.
        if (rf.field.is_readonly) return self.fail(ma.line, ma.col, "E_READONLY_ASSIGNMENT");
        ma.class_name = rf.owner;
        try self.assignField(program, rf.field.checked_type orelse return error.ParseError, ma);
        return;
    }
    // `this.field = value` inside a method/constructor.
    const cls = self.current_class orelse return self.fail(ma.line, ma.col, "E_RETURN_OUTSIDE_FUNCTION");
    const rf = self.resolveField(cls, ma.field) orelse return self.fail(ma.line, ma.col, "E_TYPE_MISMATCH");
    // readonly: writable only inside a constructor.
    if (rf.field.is_readonly and !self.in_constructor) return self.fail(ma.line, ma.col, "E_READONLY_ASSIGNMENT");
    ma.class_name = rf.owner;
    try self.assignField(program, rf.field.checked_type orelse return error.ParseError, ma);
}

pub fn assignField(self: *Checker, program: *ast.Program, field_type: types.Type, ma: *ast.MemberAssign) CompileError!void {
    if (std.mem.eql(u8, ma.op, "=")) {
        try self.ensureAssignable(program, field_type, ma.value, ma.line, ma.col);
    } else {
        const value_type = self.exprType(program, ma.value, ma.line, ma.col) orelse
            return self.inferenceFail(ma.line, ma.col, "cannot infer assignment type");
        if (!types.isNumeric(field_type) or !types.same(field_type, value_type)) {
            return self.fail(ma.line, ma.col, "E_TYPE_MISMATCH");
        }
    }
}

/// Whether the block unconditionally leaves the enclosing straight-line flow
/// via `break`/`continue` (loop guard clauses, spec 260/262).
pub fn blockBreaksOut(body: []ast.Stmt) bool {
    for (body) |stmt| {
        switch (stmt) {
            .break_stmt, .continue_stmt => return true,
            else => {},
        }
    }
    return false;
}

pub fn blockReturns(body: []ast.Stmt) bool {
    for (body) |stmt| {
        if (stmtReturns(stmt)) return true;
    }
    return false;
}

pub fn stmtReturns(stmt: ast.Stmt) bool {
    return switch (stmt) {
        .return_stmt => true,
        .block_stmt => |b| blockReturns(b.body),
        .if_stmt => |branch| branch.else_body != null and blockReturns(branch.then_body) and blockReturns(branch.else_body.?),
        .throw_stmt => true,
        // A switch returns on all paths when it has a `default` that returns and
        // every case either returns or is an empty fall-through to the next
        // clause (which the fall-through lowering routes to a returning branch).
        .switch_stmt => |sw| blk: {
            const dflt = sw.default_body orelse break :blk false;
            if (!blockReturns(dflt)) break :blk false;
            for (sw.cases) |c| {
                if (c.body.len != 0 and !blockReturns(c.body)) break :blk false;
            }
            break :blk true;
        },
        // A try/catch returns on all paths when both the try body and the catch
        // body return. (The emit appends an `unreachable` when the try can throw
        // so Zig's flow analysis agrees.) A no-catch try/finally returns when its
        // try body returns (an uncaught throw re-propagates out of the function).
        .try_stmt => |t| if (t.has_catch)
            (t.catch_body.len != 0 and blockReturns(t.try_body) and blockReturns(t.catch_body))
        else
            blockReturns(t.try_body),
        else => false,
    };
}

/// Check one `let`/`const`/`var` declarator: resolve its type (annotation or
/// inferred), verify the initializer, and bind the name. Shared by single and
/// comma-grouped declarations.
pub fn checkVarDecl(self: *Checker, program: *ast.Program, decl: *ast.VarDecl) CompileError!void {
    const final_type = if (decl.annotation) |ann|
        try self.typeFromAnnotation(ann, decl.line, decl.col)
    else
        self.exprType(program, decl.init, decl.line, decl.col) orelse
            return self.inferenceFail(decl.line, decl.col, "cannot infer variable type");
    if (final_type == .void) return self.fail(decl.line, decl.col, "E_VOID_VALUE");
    if (final_type == .none) return self.inferenceFail(decl.line, decl.col, "cannot infer type of null; annotate as T | null");

    // A `let x: T;` declaration has no initializer to check; it binds the
    // annotated type directly (mutable, so it can be assigned before use).
    if (!decl.no_init) {
        self.ensureAssignable(program, final_type, decl.init, decl.line, decl.col) catch |e| {
            // Error recovery for multi-error reporting: still bind the name with
            // its declared type so later statements don't cascade into
            // "undefined variable" noise.
            decl.checked_type = final_type;
            self.declare(decl.name, decl, final_type, decl.line, decl.col) catch {};
            return e;
        };
    }
    decl.checked_type = final_type;
    try self.declare(decl.name, decl, final_type, decl.line, decl.col);
}

pub fn checkStmt(self: *Checker, program: *ast.Program, stmt: *ast.Stmt) CompileError!void {
    switch (stmt.*) {
        .block_stmt => |*b| {
            try self.pushScope();
            defer self.popScope();
            try self.checkBlock(program, b.body);
        },
        .type_decl => |*decl| {
            for (decl.fields) |*field| {
                field.checked_type = try self.typeFromAnnotation(field.annotation, decl.line, decl.col);
            }
        },
        .enum_decl => {}, // registered during the hoisting pre-pass
        .extern_decl => {}, // registered during the hoisting pre-pass
        .class_decl => |*c| try self.checkClass(program, c),
        .member_assign => |*ma| try self.checkMemberAssign(program, ma),
        .super_ctor => |*sc| {
            const cls = self.current_class orelse return self.fail(sc.line, sc.col, "E_RETURN_OUTSIDE_FUNCTION");
            if (!self.in_constructor) return self.fail(sc.line, sc.col, "E_TYPE_MISMATCH");
            const parent = (self.classes.get(cls) orelse return self.fail(sc.line, sc.col, "E_TYPE_MISMATCH")).parent orelse
                return self.fail(sc.line, sc.col, "E_TYPE_MISMATCH");
            sc.parent = parent;
            // Resolve the parent's effective constructor params.
            var ctor_params: []ast.FunctionParam = &.{};
            var has_ctor = false;
            var cur: ?[]const u8 = parent;
            while (cur) |pname| {
                const pinfo = self.classes.get(pname) orelse break;
                if (pinfo.has_ctor) {
                    ctor_params = pinfo.ctor_params;
                    has_ctor = true;
                    sc.parent = pname;
                    break;
                }
                cur = pinfo.parent;
            }
            const want: usize = if (has_ctor) ctor_params.len else 0;
            if (sc.args.len != want) return self.fail(sc.line, sc.col, "E_ARG_COUNT");
            for (sc.args, 0..) |arg, i| {
                try self.ensureAssignable(program, ctor_params[i].checked_type orelse return error.ParseError, arg, sc.line, sc.col);
            }
        },
        .test_decl => |*t| {
            self.test_depth += 1;
            defer self.test_depth -= 1;
            try self.checkBlock(program, t.body);
        },

        .function_decl => |*decl| {
            if (self.nested_stmt_depth > 0) return self.fail(decl.line, decl.col, "E_UNSUPPORTED_NESTED_FUNCTION");
            if (decl.checked_return_type == null) try self.declareFunction(decl);
            try self.checkFunctionBody(program, decl);
        },
        .var_decl => |*decl| try self.checkVarDecl(program, decl),
        .var_decl_group => |group| for (group) |*decl| try self.checkVarDecl(program, decl),
        .using_decl => |*decl| {
            if (decl.defer_body) |body| {
                // `using x = defer(() => BODY);` — the helper body runs at scope
                // exit. Check it like a defer block; no value binding is made
                // (the bound name is an opaque Disposable).
                try self.checkBlock(program, body);
            } else {
                // `using r = EXPR;` — the value must be a class instance that
                // exposes `dispose(): void`. Bind `r`, then synthesize and check
                // a `r.dispose()` call to run at scope exit.
                const final_type = if (decl.annotation) |ann|
                    try self.typeFromAnnotation(ann, decl.line, decl.col)
                else
                    self.exprType(program, decl.init, decl.line, decl.col) orelse
                        return self.inferenceFail(decl.line, decl.col, "cannot infer using-declaration type");
                if (final_type != .class_type) return self.fail(decl.line, decl.col, "E_NOT_DISPOSABLE");
                try self.ensureAssignable(program, final_type, decl.init, decl.line, decl.col);
                decl.checked_type = final_type;

                const cls = final_type.class_type;
                const rm = self.resolveMethod(cls, "dispose") orelse return self.fail(decl.line, decl.col, "E_NOT_DISPOSABLE");
                if (rm.method.params.len != 0) return self.fail(decl.line, decl.col, "E_NOT_DISPOSABLE");

                // Declare the binding in the current scope.
                const scope = self.currentScope();
                if (scope.get(decl.name) != null) return self.fail(decl.line, decl.col, "E_DUPLICATE_BINDING");
                const emit_name = try self.freshEmitName(decl.name);
                decl.emit_name = emit_name;
                scope.put(self.arena, decl.name, .{ .ty = final_type, .mutable = false, .emit_name = emit_name }) catch return error.OutOfMemory;

                // Synthesize `name.dispose()` and check it so class_name/emit_name fill in.
                const recv = try self.arena.create(ast.Expr);
                recv.* = .{ .var_ref = .{ .name = decl.name } };
                const call = try self.arena.create(ast.Expr);
                call.* = .{ .method_call = .{ .obj = recv, .name = "dispose", .args = &.{} } };
                _ = self.exprType(program, call, decl.line, decl.col);
                decl.dispose_call = call;
            }
        },
        .destructure_decl => |*d| {
            const src_type = self.exprType(program, d.source, d.line, d.col) orelse
                return self.inferenceFail(d.line, d.col, "cannot infer destructured source type");
            if (d.is_object) {
                const type_name = switch (src_type) {
                    .named => |n| n,
                    else => return self.fail(d.line, d.col, "E_TYPE_MISMATCH"),
                };
                for (d.bindings) |*b| {
                    const field_type = self.fieldType(type_name, b.field_name orelse b.name, d.line, d.col) orelse return error.ParseError;
                    b.checked_type = field_type;
                    const scope = self.currentScope();
                    if (scope.get(b.name) != null) return self.fail(d.line, d.col, "E_DUPLICATE_BINDING");
                    const emit_name = try self.freshEmitName(b.name);
                    b.emit_name = emit_name;
                    scope.put(self.arena, b.name, .{ .ty = field_type, .mutable = d.mutable, .emit_name = emit_name }) catch return error.OutOfMemory;
                }
            } else if (src_type == .tuple_type) {
                // `const [a, b] = tupleValue`: each binding takes the matching
                // positional element type; no rest binding on a fixed tuple.
                const elems = src_type.tuple_type;
                if (d.bindings.len != elems.len) {
                    const tn = types.tsName(self.arena, src_type) catch "tuple";
                    const msg = std.fmt.allocPrint(self.arena, "destructuring pattern has {d} name{s} but `{s}` has {d} element{s}", .{ d.bindings.len, if (d.bindings.len == 1) "" else "s", tn, elems.len, if (elems.len == 1) "" else "s" }) catch "E_TYPE_MISMATCH";
                    // Error recovery: still bind what lines up so later uses
                    // don't cascade into undefined-variable noise.
                    for (d.bindings, 0..) |*b, i| {
                        if (i >= elems.len) break;
                        b.checked_type = elems[i];
                        const scope = self.currentScope();
                        if (scope.get(b.name) == null) {
                            const emit_name = try self.freshEmitName(b.name);
                            b.emit_name = emit_name;
                            scope.put(self.arena, b.name, .{ .ty = elems[i], .mutable = d.mutable, .emit_name = emit_name }) catch {};
                        }
                    }
                    return self.fail(d.line, d.col, msg);
                }
                d.is_tuple = true;
                for (d.bindings, 0..) |*b, i| {
                    if (b.is_rest) return self.fail(d.line, d.col, "E_TYPE_MISMATCH");
                    const bt = elems[i];
                    b.checked_type = bt;
                    const scope = self.currentScope();
                    if (scope.get(b.name) != null) return self.fail(d.line, d.col, "E_DUPLICATE_BINDING");
                    const emit_name = try self.freshEmitName(b.name);
                    b.emit_name = emit_name;
                    scope.put(self.arena, b.name, .{ .ty = bt, .mutable = d.mutable, .emit_name = emit_name }) catch return error.OutOfMemory;
                }
            } else {
                if (!types.isArray(src_type)) {
                    const tn = types.tsName(self.arena, src_type) catch "?";
                    const msg = std.fmt.allocPrint(self.arena, "array destructuring needs an array or tuple, got `{s}`", .{tn}) catch "E_TYPE_MISMATCH";
                    return self.fail(d.line, d.col, msg);
                }
                const elem = types.arrayElem(src_type) orelse return self.fail(d.line, d.col, "E_TYPE_MISMATCH");
                for (d.bindings, 0..) |*b, i| {
                    // A rest binding `...rest` (only valid as the last element)
                    // takes the remaining elements as an array of the same type.
                    if (b.is_rest and i != d.bindings.len - 1) return self.fail(d.line, d.col, "E_TYPE_MISMATCH");
                    const bt: types.Type = if (b.is_rest) src_type else elem;
                    b.checked_type = bt;
                    const scope = self.currentScope();
                    if (scope.get(b.name) != null) return self.fail(d.line, d.col, "E_DUPLICATE_BINDING");
                    const emit_name = try self.freshEmitName(b.name);
                    b.emit_name = emit_name;
                    scope.put(self.arena, b.name, .{ .ty = bt, .mutable = d.mutable, .emit_name = emit_name }) catch return error.OutOfMemory;
                }
            }
        },
        .assign => |*assignment| {
            const found_binding = self.bindingPtr(assignment.name) orelse
                return self.undefined_(assignment.name, assignment.line, assignment.col);
            if (!found_binding.mutable) {
                const msg = std.fmt.allocPrint(self.arena, "cannot assign to '{s}' — it was declared with `const`; use `let {s} = ...` to make it mutable", .{ assignment.name, assignment.name }) catch "E_CONST_ASSIGNMENT";
                return self.fail(assignment.line, assignment.col, msg);
            }
            // A statement-body arrow captures outer bindings by value, so it
            // cannot mutate them (Zig would reject the cross-scope write). Reject
            // it clearly instead of emitting invalid code; use `reduce`/`map` or
            // an expression body for accumulation.
            if (self.current_captures != null) {
                if (self.bindingDepth(assignment.name)) |depth| {
                    if (depth < self.arrow_base) {
                        return self.fail(assignment.line, assignment.col, "E_CAPTURED_MUTATION");
                    }
                }
            }
            const expected_type = found_binding.ty;
            if (std.mem.eql(u8, assignment.op, "=")) {
                switch (expected_type) {
                    .named, .named_array, .union_type, .string_literal_union, .int_literal_union, .optional => {},
                    else => if (self.exprType(program, assignment.value, assignment.line, assignment.col)) |actual_type| {
                        if (!types.same(expected_type, actual_type)) {
                            return self.fail(assignment.line, assignment.col, "E_TYPE_MISMATCH");
                        }
                    } else return self.inferenceFail(assignment.line, assignment.col, "cannot infer assignment type"),
                }
                try self.ensureAssignable(program, expected_type, assignment.value, assignment.line, assignment.col);
            } else {
                // Compound assignment (spec 052 widened the operator set).
                // Each family has its own LHS-type requirement:
                //   &&= ||=  -> bool          (Lumen's &&/|| are bool-only)
                //   ??=      -> optional<T>    (RHS assignable to T)
                //   &= |= ^= <<= >>= -> integer
                //   += -= *= /= %= **= -> numeric (int or number)
                const op = assignment.op;
                const eqs = std.mem.eql;
                if (eqs(u8, op, "??=")) {
                    if (expected_type != .optional) return self.fail(assignment.line, assignment.col, "E_TYPE_MISMATCH");
                    try self.ensureAssignable(program, expected_type, assignment.value, assignment.line, assignment.col);
                } else {
                    const actual_type = self.exprType(program, assignment.value, assignment.line, assignment.col) orelse
                        return self.inferenceFail(assignment.line, assignment.col, "cannot infer assignment type");
                    if (eqs(u8, op, "&&=") or eqs(u8, op, "||=")) {
                        if (!types.same(.bool, expected_type) or !types.same(.bool, actual_type)) {
                            return self.fail(assignment.line, assignment.col, "E_TYPE_MISMATCH");
                        }
                    } else if (eqs(u8, op, "&=") or eqs(u8, op, "|=") or eqs(u8, op, "^=") or eqs(u8, op, "<<=") or eqs(u8, op, ">>=")) {
                        if (!types.isInteger(expected_type) or !types.same(expected_type, actual_type)) {
                            return self.fail(assignment.line, assignment.col, "E_TYPE_MISMATCH");
                        }
                    } else if (eqs(u8, op, "+=") and types.isStringLike(expected_type)) {
                        // String concatenation: `s += x` mirrors `s = s + x`,
                        // coercing a number/bool right-hand side to string.
                        if (!types.isStringLike(actual_type)) {
                            if (types.isNumeric(actual_type) or actual_type == .bool) {
                                assignment.value = self.wrapStringify(assignment.value) catch return error.OutOfMemory;
                            } else {
                                return self.fail(assignment.line, assignment.col, "E_TYPE_MISMATCH");
                            }
                        }
                    } else {
                        // f64 slot accepts an integer RHS via numeric
                        // promotion (spec 256): `total += n`; an i64 slot
                        // accepts an i32 RHS by lossless widening (spec 258).
                        if (expected_type == .f64 and types.isInteger(actual_type)) {
                            assignment.value = self.wrapFloat(assignment.value) catch return error.OutOfMemory;
                        } else if (expected_type == .i64 and actual_type == .i32) {
                            // Zig widens implicitly; nothing to rewrite.
                        } else if (!types.isNumeric(expected_type) or !types.same(expected_type, actual_type)) {
                            return self.fail(assignment.line, assignment.col, "E_TYPE_MISMATCH");
                        }
                    }
                }
                assignment.checked_type = expected_type;
            }
            if (found_binding.decl) |decl| decl.reassigned = true;
            assignment.emit_name = found_binding.emit_name;
            assignment.deref = found_binding.ref_scalar;
        },
        .console_log => |*log| {
            const log_type = self.exprType(program, log.value, log.line, log.col) orelse
                return self.inferenceFail(log.line, log.col, "cannot infer console.log argument type");
            if (log_type == .void) return self.fail(log.line, log.col, "E_VOID_VALUE");
            log.checked_type = log_type;
            if (log.extra_values.len > 0) {
                const ets = self.arena.alloc(types.Type, log.extra_values.len) catch return error.OutOfMemory;
                for (log.extra_values, 0..) |ev, i| {
                    const et = self.exprType(program, ev, log.line, log.col) orelse
                        return self.inferenceFail(log.line, log.col, "cannot infer console.log argument type");
                    if (et == .void) return self.fail(log.line, log.col, "E_VOID_VALUE");
                    ets[i] = et;
                }
                log.extra_types = ets;
            }
            // log/info/debug print to real stdout via the __consoleOut
            // runtime helper, which needs __io; error/warn/trace keep using
            // std.debug.print (real stderr) directly and need no io at all.
            if (std.mem.eql(u8, log.method, "log") or std.mem.eql(u8, log.method, "info") or std.mem.eql(u8, log.method, "debug")) {
                program.uses_io = true;
                program.needs_console_stdout = true;
            }
        },
        .while_stmt => |*loop| {
            const cond_type = self.exprType(program, loop.cond, loop.line, loop.col) orelse
                return self.inferenceFail(loop.line, loop.col, "cannot infer while condition type");
            if (!types.same(.bool, cond_type)) return self.failCondition(loop.line, loop.col, "`while`", cond_type);
            // `while (x != null)` narrows x inside the body (spec 265).
            const loop_narrow = self.narrowTarget(loop.cond);
            const narrow_active = loop_narrow != null and loop_narrow.?.in_then;
            if (narrow_active) self.narrowed.append(self.arena, loop_narrow.?.name) catch return error.OutOfMemory;
            defer if (narrow_active) {
                self.narrowed.items.len -= 1;
            };
            self.loop_depth += 1;
            defer self.loop_depth -= 1;
            try self.checkBlock(program, loop.body);
        },
        .do_while_stmt => |*loop| {
            self.loop_depth += 1;
            defer self.loop_depth -= 1;
            try self.checkBlock(program, loop.body);
            const cond_type = self.exprType(program, loop.cond, loop.line, loop.col) orelse
                return self.inferenceFail(loop.line, loop.col, "cannot infer do-while condition type");
            if (!types.same(.bool, cond_type)) return self.failCondition(loop.line, loop.col, "`do-while`", cond_type);
        },
        .for_stmt => |*loop| {
            try self.pushScope();
            defer self.popScope();
            var init_stmt: ?ast.Stmt = if (loop.init) |i| .{ .var_decl = i } else null;
            if (init_stmt) |*is| try self.checkStmt(program, is);
            for (loop.extra_inits) |*extra| try self.checkVarDecl(program, extra);
            // An omitted condition is an unconditional loop; otherwise it must be
            // a bool.
            if (loop.cond) |cond| {
                const cond_type = self.exprType(program, cond, loop.line, loop.col) orelse
                    return self.inferenceFail(loop.line, loop.col, "cannot infer for condition type");
                if (!types.same(.bool, cond_type)) return self.failCondition(loop.line, loop.col, "`for`", cond_type);
            }
            self.loop_depth += 1;
            defer self.loop_depth -= 1;
            try self.checkBlock(program, loop.body);
            var update_stmt: ?ast.Stmt = if (loop.update) |u| .{ .assign = u } else null;
            if (update_stmt) |*us| try self.checkStmt(program, us);
            for (loop.extra_updates) |*extra| {
                var us: ast.Stmt = .{ .assign = extra.* };
                try self.checkStmt(program, &us);
                extra.* = us.assign;
            }
            // Write init/update back after the update marks the binding
            // reassigned, so the loop variable emits as `var`, not `const`.
            if (init_stmt) |is| loop.init = is.var_decl;
            if (update_stmt) |us| loop.update = us.assign;
        },
        .for_of_stmt => |*loop| {
            // `for (const [i, v] of arr.entries())` — index/value pairs over an
            // array. Handled before generic iterable inference because
            // `.entries()` isn't a standalone array method (it only exists as a
            // for-of iterable here). The iterable is rewritten to the receiver.
            if (loop.is_pair and loop.iterable.* == .method_call and
                std.mem.eql(u8, loop.iterable.method_call.name, "entries"))
            {
                const recv = loop.iterable.method_call.obj;
                const recv_ty = self.exprType(program, recv, loop.line, loop.col) orelse
                    return self.inferenceFail(loop.line, loop.col, "cannot infer for-of iterable type");
                if (types.isArray(recv_ty)) {
                    if (loop.iterable.method_call.args.len != 0) return self.fail(loop.line, loop.col, "E_ARG_COUNT");
                    const et = types.arrayElem(recv_ty) orelse return self.fail(loop.line, loop.col, "E_TYPE_MISMATCH");
                    loop.is_array_entries = true;
                    loop.iterable = recv;
                    loop.iter_type = recv_ty;
                    loop.elem_type = et;
                    try self.pushScope();
                    defer self.popScope();
                    const scope = self.currentScope();
                    const kn = try self.freshEmitName(loop.binding);
                    const vn = try self.freshEmitName(loop.value_binding);
                    loop.binding_emit_name = kn;
                    scope.put(self.arena, loop.binding, .{ .ty = .i32, .mutable = loop.mutable, .emit_name = kn }) catch return error.OutOfMemory;
                    scope.put(self.arena, loop.value_binding, .{ .ty = et, .mutable = loop.mutable, .emit_name = vn }) catch return error.OutOfMemory;
                    loop.value_binding = vn;
                    self.loop_depth += 1;
                    defer self.loop_depth -= 1;
                    try self.checkBlock(program, loop.body);
                    return;
                }
                // `map.entries()` is just the map itself as a key/value iterable;
                // rewrite to the receiver and let the Map pair path below handle it.
                if (recv_ty == .map_type) {
                    if (loop.iterable.method_call.args.len != 0) return self.fail(loop.line, loop.col, "E_ARG_COUNT");
                    loop.iterable = recv;
                }
            }
            const iter_type = self.exprType(program, loop.iterable, loop.line, loop.col) orelse
                return self.inferenceFail(loop.line, loop.col, "cannot infer for-of iterable type");
            loop.iter_type = iter_type;
            // `for (const [k, v] of map)` — pair destructuring over a Map.
            if (loop.is_pair) {
                if (iter_type != .map_type) return self.fail(loop.line, loop.col, "E_TYPE_MISMATCH");
                try self.pushScope();
                defer self.popScope();
                const scope = self.currentScope();
                const kn = try self.freshEmitName(loop.binding);
                const vn = try self.freshEmitName(loop.value_binding);
                loop.binding_emit_name = kn;
                loop.elem_type = vn_marker: {
                    scope.put(self.arena, loop.binding, .{ .ty = iter_type.map_type.key.*, .mutable = loop.mutable, .emit_name = kn }) catch return error.OutOfMemory;
                    scope.put(self.arena, loop.value_binding, .{ .ty = iter_type.map_type.value.*, .mutable = loop.mutable, .emit_name = vn }) catch return error.OutOfMemory;
                    break :vn_marker iter_type.map_type.value.*;
                };
                // Stash the value's emit name in value_binding (rewritten) so emit
                // can use it; store it via a side field.
                loop.value_binding = vn;
                self.loop_depth += 1;
                defer self.loop_depth -= 1;
                try self.checkBlock(program, loop.body);
                return;
            }
            const elem_type: types.Type = if (types.isArray(iter_type))
                (types.arrayElem(iter_type) orelse return self.fail(loop.line, loop.col, "E_TYPE_MISMATCH"))
            else if (types.isStringLike(iter_type))
                .string
            else {
                const tn = types.tsName(self.arena, iter_type) catch "?";
                const msg = std.fmt.allocPrint(self.arena, "`for...of` needs an array, string, or Map — got `{s}`", .{tn}) catch "E_TYPE_MISMATCH";
                return self.fail(loop.line, loop.col, msg);
            };
            loop.elem_type = elem_type;
            try self.pushScope();
            defer self.popScope();
            const scope = self.currentScope();
            const emit_name = try self.freshEmitName(loop.binding);
            loop.binding_emit_name = emit_name;
            scope.put(self.arena, loop.binding, .{ .ty = elem_type, .mutable = loop.mutable, .emit_name = emit_name }) catch return error.OutOfMemory;
            self.loop_depth += 1;
            defer self.loop_depth -= 1;
            try self.checkBlock(program, loop.body);
        },
        .for_in_stmt => |*loop| {
            // for...in (spec 052): iterate a record's field names or an
            // array's indices, both as `string`. Map/Set/scalar iterables
            // are rejected -- there's no meaningful key set for them here.
            const iter_type = self.exprType(program, loop.iterable, loop.line, loop.col) orelse
                return self.inferenceFail(loop.line, loop.col, "cannot infer for-in iterable type");
            if (iter_type == .named) {
                const decl = self.type_decls.get(iter_type.named) orelse
                    return self.fail(loop.line, loop.col, "E_TYPE_MISMATCH");
                const names = self.arena.alloc([]const u8, decl.fields.len) catch return error.OutOfMemory;
                for (decl.fields, 0..) |f, i| names[i] = f.name;
                loop.key_names = names;
            } else if (types.isArray(iter_type)) {
                loop.key_names = null; // runtime indices
                program.uses_io = true; // the index->string uses __alloc
            } else {
                const tn = types.tsName(self.arena, iter_type) catch "?";
                const msg = std.fmt.allocPrint(self.arena, "`for...in` needs a record or array, got `{s}` — to iterate values use `for...of`", .{tn}) catch "E_TYPE_MISMATCH";
                return self.fail(loop.line, loop.col, msg);
            }
            try self.pushScope();
            defer self.popScope();
            const scope = self.currentScope();
            const emit_name = try self.freshEmitName(loop.binding);
            loop.binding_emit_name = emit_name;
            scope.put(self.arena, loop.binding, .{ .ty = .string, .mutable = loop.mutable, .emit_name = emit_name }) catch return error.OutOfMemory;
            self.loop_depth += 1;
            defer self.loop_depth -= 1;
            try self.checkBlock(program, loop.body);
        },
        .if_stmt => |*branch| {
            const cond_type = self.exprType(program, branch.cond, branch.line, branch.col) orelse
                return self.inferenceFail(branch.line, branch.col, "cannot infer if condition type");
            if (!types.same(.bool, cond_type)) return self.failCondition(branch.line, branch.col, "`if`", cond_type);
            const narrow = self.narrowTarget(branch.cond);
            // Discriminant narrowing: `if (s.kind === "circle")` narrows `s` to
            // the matching variant in the then-branch.
            var var_narrowed = false;
            // For a two-variant union, the complement variant (used to narrow
            // the else branch and, when the then-branch always exits, the
            // rest of the enclosing block — spec 259).
            var other_narrow: ?struct { name: []const u8, variant: []const u8 } = null;
            if (branch.cond.* == .cmp) {
                const c = branch.cond.cmp;
                if (std.mem.eql(u8, c.op, "==") or std.mem.eql(u8, c.op, "===")) {
                    var disc_expr: ?*ast.Expr = null;
                    var lit: ?[]const u8 = null;
                    if (c.r.* == .str) {
                        disc_expr = c.l;
                        lit = c.r.str;
                    } else if (c.l.* == .str) {
                        disc_expr = c.r;
                        lit = c.l.str;
                    }
                    if (disc_expr) |de| {
                        if (self.discriminantAccess(de)) |d| {
                            const variant = self.variantForValue(d.union_name, lit.?) orelse return self.fail(branch.line, branch.col, "E_TYPE_MISMATCH");
                            self.narrowed_variants.append(self.arena, .{ .name = d.name, .variant = variant }) catch return error.OutOfMemory;
                            var_narrowed = true;
                            if (self.otherVariant(d.union_name, variant)) |other| {
                                other_narrow = .{ .name = d.name, .variant = other };
                            }
                        }
                    }
                }
            }
            {
                const active = narrow != null and narrow.?.in_then;
                if (active) self.narrowed.append(self.arena, narrow.?.name) catch return error.OutOfMemory;
                defer if (active) {
                    self.narrowed.items.len -= 1;
                };
                defer if (var_narrowed) {
                    self.narrowed_variants.items.len -= 1;
                };
                try self.checkBlock(program, branch.then_body);
            }
            if (branch.else_body) |else_body| {
                const active = narrow != null and !narrow.?.in_then;
                if (active) self.narrowed.append(self.arena, narrow.?.name) catch return error.OutOfMemory;
                defer if (active) {
                    self.narrowed.items.len -= 1;
                };
                var else_narrowed = false;
                if (other_narrow) |on| {
                    self.narrowed_variants.append(self.arena, .{ .name = on.name, .variant = on.variant }) catch return error.OutOfMemory;
                    else_narrowed = true;
                }
                defer if (else_narrowed) {
                    self.narrowed_variants.items.len -= 1;
                };
                try self.checkBlock(program, else_body);
            } else if (blockReturns(branch.then_body) or blockBreaksOut(branch.then_body)) {
                // Guard clause: the then-branch always exits, so its negative
                // narrowing holds for the rest of the enclosing block
                // (checkBlock restores the lists at block exit).
                if (other_narrow) |on| {
                    // `if (s.kind == "circle") { return ... }` — s can only be
                    // the other variant below.
                    self.narrowed_variants.append(self.arena, .{ .name = on.name, .variant = on.variant }) catch return error.OutOfMemory;
                }
                if (narrow != null and !narrow.?.in_then) {
                    // `if (s == null) return ...` — s is non-null below.
                    self.narrowed.append(self.arena, narrow.?.name) catch return error.OutOfMemory;
                }
            }
        },
        .switch_stmt => |*switch_stmt| {
            // A `switch (s.kind)` over a union discriminant narrows `s` to the
            // matching variant inside each case body.
            const disc = self.discriminantAccess(switch_stmt.value);
            const switch_type = self.exprType(program, switch_stmt.value, switch_stmt.line, switch_stmt.col) orelse
                return self.inferenceFail(switch_stmt.line, switch_stmt.col, "cannot infer switch value type");
            switch_stmt.checked_type = switch_type;
            self.switch_depth += 1;
            defer self.switch_depth -= 1;
            for (switch_stmt.cases) |*case| {
                switch (switch_type) {
                    .string_literal_union, .int_literal_union => try self.ensureAssignable(program, switch_type, case.value, case.line, case.col),
                    else => {
                        const case_type = self.exprType(program, case.value, case.line, case.col) orelse
                            return self.inferenceFail(case.line, case.col, "cannot infer switch case type");
                        if (!types.same(switch_type, case_type)) return self.fail(case.line, case.col, "E_TYPE_MISMATCH");
                    },
                }
                var narrowed = false;
                if (disc) |d| {
                    if (case.value.* == .str) {
                        const variant = self.variantForValue(d.union_name, case.value.str) orelse return self.fail(case.line, case.col, "E_TYPE_MISMATCH");
                        self.narrowed_variants.append(self.arena, .{ .name = d.name, .variant = variant }) catch return error.OutOfMemory;
                        narrowed = true;
                    }
                }
                defer if (narrowed) {
                    self.narrowed_variants.items.len -= 1;
                };
                try self.checkBlock(program, case.body);
            }
            if (switch_stmt.default_body) |default_body| try self.checkBlock(program, default_body);
        },
        .expr_stmt => |expr_stmt| {
            _ = self.exprType(program, expr_stmt.value, expr_stmt.line, expr_stmt.col) orelse
                return self.inferenceFail(expr_stmt.line, expr_stmt.col, "cannot infer expression type");
        },
        .return_stmt => |*ret| {
            const expected_return = self.current_return_type orelse
                return self.fail(ret.line, ret.col, "E_RETURN_OUTSIDE_FUNCTION");
            const value = ret.value orelse {
                if (expected_return == .void) {
                    ret.checked_type = .void;
                    return;
                }
                return self.fail(ret.line, ret.col, "E_RETURN_TYPE");
            };
            // ensureAssignable already recorded a detailed expected/got message.
            self.ensureAssignable(program, expected_return, value, ret.line, ret.col) catch return error.ParseError;
            ret.checked_type = expected_return;
        },
        .throw_stmt => |throw_stmt| {
            const thrown_type = self.exprType(program, throw_stmt.value, throw_stmt.line, throw_stmt.col) orelse
                return self.inferenceFail(throw_stmt.line, throw_stmt.col, "cannot infer throw type");
            // `throw new Error("x")` and JS-style `throw "x"` both carry a
            // string message at runtime; anything else names its type.
            if (!types.same(.error_obj, thrown_type) and !types.isStringLike(thrown_type)) {
                const tn = types.tsName(self.arena, thrown_type) catch "?";
                const msg = std.fmt.allocPrint(self.arena, "can only throw an Error or a string, got `{s}` — write `throw new Error(...)`", .{tn}) catch "E_THROW_TYPE";
                return self.fail(throw_stmt.line, throw_stmt.col, msg);
            }
        },
        .try_stmt => |*try_stmt| {
            try self.checkBlock(program, try_stmt.try_body);
            try self.pushScope();
            defer self.popScope();
            try self.declareCatch(try_stmt);
            self.nested_stmt_depth += 1;
            defer self.nested_stmt_depth -= 1;
            for (try_stmt.catch_body) |*catch_stmt| try self.checkStmt(program, catch_stmt);
            if (try_stmt.finally_body) |finally_body| {
                try self.checkBlock(program, finally_body);
            }
        },
        .defer_stmt => |*d| {
            try self.checkBlock(program, d.body);
        },
        .break_stmt => |control| {
            if (self.loop_depth == 0 and self.switch_depth == 0) return self.fail(control.line, control.col, "E_BREAK_OUTSIDE_LOOP");
        },
        .continue_stmt => |control| {
            if (self.loop_depth == 0) return self.fail(control.line, control.col, "E_CONTINUE_OUTSIDE_LOOP");
        },
    }
}
