//! Expression type-checking -- `exprType` is the heart of the checker: given
//! any `*ast.Expr`, return its `Type` (or `null` plus a diagnostic). One case
//! per `Expr` union variant (literals, binary/unary ops, calls, field access,
//! indexing, object/array literals, closures, ...), recording resolved types
//! and emission hints back onto the node so the codegen never re-derives them.
//! `fieldType` resolves a named record's field type by name, used both here
//! (plain `.field` access) and by callers checking object-literal shapes.
//!
//! This is the single largest piece of the checker (every other module here
//! -- assignability, class resolution, generics, stdlib calls, statements --
//! exists to be called FROM `exprType`, directly or via `checkStmt`). It is
//! kept in its own file because of size, not because it is more separable
//! than the rest: expect it to call into `self.*` methods defined all over
//! the other `lumen_check_*.zig` files.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const types = @import("lumen_types.zig");
const diag_mod = @import("lumen_diag.zig");
const check_mod = @import("lumen_check.zig");

const Checker = check_mod.Checker;
const CompileError = diag_mod.CompileError;

/// Type-check a callback argument with positional param-type hints in scope, so
/// a bare untyped arrow param (`v => ...`) infers its type from the expected
/// signature. The hint is cleared afterward whether or not it was consumed (the
/// argument may be a named function reference rather than an arrow).
pub fn checkCbArg(self: *Checker, program: *ast.Program, e: *ast.Expr, hint: []const types.Type, line: u32, col: u32) ?types.Type {
    self.arrow_param_hint = hint;
    const t = self.exprType(program, e, line, col);
    self.arrow_param_hint = null;
    return t;
}

/// Wrap an expression in the runtime `String(...)` conversion so a numeric or
/// boolean operand of a string `+` becomes a string. Reuses the global
/// String() codegen (a comptime type switch), which needs no arg type recorded.
pub fn wrapStringify(self: *Checker, e: *ast.Expr) !*ast.Expr {
    const args = try self.arena.alloc(*ast.Expr, 1);
    args[0] = e;
    const node = try self.arena.create(ast.Expr);
    node.* = .{ .call = .{ .name = "String", .args = args, .is_global_parse = true } };
    return node;
}

pub fn exprType(self: *Checker, program: *ast.Program, e: *ast.Expr, line: u32, col: u32) ?types.Type {
    return switch (e.*) {
        .var_ref => |*ref| blk: {
            const found_binding = self.binding(ref.name) orelse {
                // A top-level function name used as a value.
                if (self.funcs.get(ref.name)) |finfo| {
                    ref.is_func_ref = true;
                    const t = self.funcSigType(finfo) catch return null;
                    ref.func_sig = t.func_type;
                    break :blk t;
                }
                // Global float constants NaN / Infinity.
                if (std.mem.eql(u8, ref.name, "NaN")) {
                    ref.builtin_const = "@as(f64, std.math.nan(f64))";
                    break :blk types.Type.f64;
                }
                if (std.mem.eql(u8, ref.name, "Infinity")) {
                    ref.builtin_const = "@as(f64, std.math.inf(f64))";
                    break :blk types.Type.f64;
                }
                _ = self.undefined_(ref.name, line, col) catch {};
                return null;
            };
            ref.emit_name = found_binding.emit_name;
            ref.deref = found_binding.ref_scalar;
            // Inside an arrow body, a reference to a binding declared outside
            // the arrow is a capture (stored in the closure's heap env).
            if (self.current_captures) |caps| {
                if (self.bindingDepth(ref.name)) |depth| {
                    if (depth < self.arrow_base) {
                        ref.capture = true;
                        var present = false;
                        for (caps.items) |c| {
                            if (std.mem.eql(u8, c.emit_name, found_binding.emit_name)) present = true;
                        }
                        if (!present) caps.append(self.arena, .{ .emit_name = found_binding.emit_name, .ty = found_binding.ty }) catch return null;
                    }
                }
            }
            if (found_binding.ty == .optional and self.isNarrowed(ref.name)) {
                ref.unwrap = true;
                break :blk found_binding.ty.optional.*;
            }
            ref.unwrap = false;
            break :blk found_binding.ty;
        },
        .neg => |inner| self.exprType(program, inner, line, col),
        .inc_dec => |*id| {
            // `x++` / `++x` (and --): the target must be a mutable numeric
            // variable. Mark it reassigned so it emits as `var`.
            const t = self.exprType(program, id.target, line, col) orelse return null;
            if (!types.isNumeric(t)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
            if (id.target.* == .var_ref) {
                const b = self.bindingPtr(id.target.var_ref.name) orelse {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                };
                if (!b.mutable) {
                    _ = self.fail(line, col, "E_CONST_ASSIGNMENT") catch {};
                    return null;
                }
                if (b.decl) |d| d.reassigned = true;
            }
            id.checked_type = t;
            return t;
        },
        .typeof_expr => |*to| {
            // `typeof x` resolves to a compile-time string from x's static type.
            const t = self.exprType(program, to.operand, line, col) orelse return null;
            to.result = switch (t) {
                .i32, .i64, .f64, .int_literal_union => "number",
                .string, .string_literal_union => "string",
                .bool => "boolean",
                .func_type => "function",
                .optional, .none => "undefined",
                else => "object",
            };
            return .string;
        },
        .not => |inner| {
            const inner_type = self.exprType(program, inner, line, col) orelse return null;
            if (!types.same(.bool, inner_type)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
            return .bool;
        },
        .bnot => |inner| {
            const inner_type = self.exprType(program, inner, line, col) orelse return null;
            if (!types.isInteger(inner_type)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
            return inner_type;
        },
        .await_expr => |inner| {
            // `await` is only valid inside an async function body or at the
            // top level of the program (not inside a non-async function).
            if (self.in_function and !self.in_async) {
                _ = self.fail(line, col, "E_AWAIT_OUTSIDE_ASYNC") catch {};
                return null;
            }
            const operand_type = self.exprType(program, inner, line, col) orelse return null;
            if (operand_type != .promise_type) {
                _ = self.fail(line, col, "E_AWAIT_NOT_PROMISE") catch {};
                return null;
            }
            program.needs_async = true;
            return operand_type.promise_type.*;
        },
        .bin => |*bin| {
            const left_type = self.exprType(program, bin.l, line, col) orelse return null;
            const right_type = self.exprType(program, bin.r, line, col) orelse return null;
            if (bin.op == '+' and types.same(.string, left_type) and types.same(.string, right_type)) {
                bin.checked_type = .string;
                return .string;
            }
            // TS-style `+`: if either operand is a string, the expression is a
            // string concatenation; a number/bool operand is coerced to string
            // (`"n=" + 1` -> "n=1"). Wrap the non-string side in the runtime
            // String() conversion so the concat sees two strings.
            if (bin.op == '+' and (types.isStringLike(left_type) or types.isStringLike(right_type))) {
                const l_ok = types.isStringLike(left_type) or types.isNumeric(left_type) or left_type == .bool;
                const r_ok = types.isStringLike(right_type) or types.isNumeric(right_type) or right_type == .bool;
                if (l_ok and r_ok) {
                    if (!types.isStringLike(left_type)) bin.l = self.wrapStringify(bin.l) catch return null;
                    if (!types.isStringLike(right_type)) bin.r = self.wrapStringify(bin.r) catch return null;
                    bin.checked_type = .string;
                    return .string;
                }
            }
            // Bitwise and shift operators require integer operands.
            if (bin.op == '&' or bin.op == '|' or bin.op == '^' or bin.op == 'L' or bin.op == 'R') {
                if (!types.isInteger(left_type) or !types.isInteger(right_type) or !types.same(left_type, right_type)) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                bin.checked_type = left_type;
                return left_type;
            }
            if (!types.isNumeric(left_type) or !types.same(left_type, right_type)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
            bin.checked_type = left_type;
            return left_type;
        },
        .bool_bin => |bin| {
            const left_type = self.exprType(program, bin.l, line, col) orelse return null;
            const right_type = self.exprType(program, bin.r, line, col) orelse return null;
            if (!types.same(.bool, left_type) or !types.same(.bool, right_type)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
            return .bool;
        },
        .cmp => |*cmp| {
            const left_type = self.exprType(program, cmp.l, line, col) orelse return null;
            const right_type = self.exprType(program, cmp.r, line, col) orelse return null;
            if ((std.mem.eql(u8, cmp.op, "==") or std.mem.eql(u8, cmp.op, "!=")) and types.isStringLike(left_type) and types.isStringLike(right_type)) {
                cmp.checked_operand_type = .string;
                return .bool;
            }
            // Relational string comparison is lexicographic (JS `"a" < "b"`).
            if ((std.mem.eql(u8, cmp.op, "<") or std.mem.eql(u8, cmp.op, ">") or
                std.mem.eql(u8, cmp.op, "<=") or std.mem.eql(u8, cmp.op, ">=")) and
                types.isStringLike(left_type) and types.isStringLike(right_type))
            {
                cmp.checked_operand_type = .string;
                return .bool;
            }
            // Comparing an optional value against null/undefined (the
            // narrowing condition `x != null`) is allowed and yields bool.
            if ((std.mem.eql(u8, cmp.op, "==") or std.mem.eql(u8, cmp.op, "!=")) and
                (left_type == .optional or left_type == .none) and
                (right_type == .optional or right_type == .none))
            {
                return .bool;
            }
            // Comparing an optional against a plain value (`map.get(k) === v`):
            // null compares unequal; otherwise the inner value is compared.
            if ((std.mem.eql(u8, cmp.op, "==") or std.mem.eql(u8, cmp.op, "!=")) and
                left_type == .optional and right_type != .optional and right_type != .none and
                types.same(left_type.optional.*, right_type))
            {
                cmp.opt_cmp = 1;
                cmp.checked_operand_type = right_type;
                return .bool;
            }
            if ((std.mem.eql(u8, cmp.op, "==") or std.mem.eql(u8, cmp.op, "!=")) and
                right_type == .optional and left_type != .optional and left_type != .none and
                types.same(right_type.optional.*, left_type))
            {
                cmp.opt_cmp = 2;
                cmp.checked_operand_type = left_type;
                return .bool;
            }
            // A numeric literal union compares like its integer backing type.
            if ((std.mem.eql(u8, cmp.op, "==") or std.mem.eql(u8, cmp.op, "!=")) and
                ((left_type == .int_literal_union and (right_type == .i32 or right_type == .int_literal_union)) or
                    (right_type == .int_literal_union and left_type == .i32)))
            {
                return .bool;
            }
            // A bare integer literal compares against an i64 operand as i64
            // (Expr.num already carries a real i64 value; its type only
            // *infers* to i32 without this context). Without this,
            // comparing any i64-returning value (process.hrtime(),
            // memoryUsage() fields, ...) against a literal like `0` failed
            // to compile at all.
            if (left_type == .i64 and right_type == .i32 and cmp.r.* == .num) {
                cmp.checked_operand_type = .i64;
                return .bool;
            }
            if (right_type == .i64 and left_type == .i32 and cmp.l.* == .num) {
                cmp.checked_operand_type = .i64;
                return .bool;
            }
            // Same gap, f64 side: `process.uptime() >= 0` (a bare int
            // literal against process.uptime()'s f64 result) hit this too.
            if (left_type == .f64 and right_type == .i32 and cmp.r.* == .num) {
                cmp.checked_operand_type = .f64;
                return .bool;
            }
            if (right_type == .f64 and left_type == .i32 and cmp.l.* == .num) {
                cmp.checked_operand_type = .f64;
                return .bool;
            }
            // String-backed enum equality uses content comparison.
            if ((std.mem.eql(u8, cmp.op, "==") or std.mem.eql(u8, cmp.op, "!=")) and
                left_type == .enum_type and right_type == .enum_type and
                std.mem.eql(u8, left_type.enum_type.name, right_type.enum_type.name) and left_type.enum_type.is_string)
            {
                cmp.checked_operand_type = .string;
                return .bool;
            }
            if (!types.same(left_type, right_type)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
            if (!std.mem.eql(u8, cmp.op, "==") and !std.mem.eql(u8, cmp.op, "!=") and !types.isNumeric(left_type)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
            cmp.checked_operand_type = left_type;
            return .bool;
        },
        .ternary => |ternary| {
            const cond_type = self.exprType(program, ternary.cond, line, col) orelse return null;
            if (!types.same(.bool, cond_type)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
            const then_type = self.exprType(program, ternary.then_expr, line, col) orelse return null;
            const else_type = self.exprType(program, ternary.else_expr, line, col) orelse return null;
            if (!types.same(then_type, else_type)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
            return then_type;
        },
        .arrow => |arrow| {
            // Consume any contextual param hints set by the enclosing call, then
            // clear them so a nested arrow in the body doesn't reuse them.
            const hint = self.arrow_param_hint;
            self.arrow_param_hint = null;
            for (arrow.params, 0..) |*p, i| {
                if (p.annotation.len == 0) {
                    if (hint != null and i < hint.?.len) {
                        p.checked_type = hint.?[i];
                    } else {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    }
                } else {
                    p.checked_type = self.typeFromAnnotation(p.annotation, line, col) catch return null;
                }
            }
            // Check the body with outer scopes still visible; references to
            // bindings declared outside the arrow are recorded as captures.
            const saved_base = self.arrow_base;
            const saved_caps = self.current_captures;
            var caps: std.ArrayListUnmanaged(ast.Capture) = .empty;
            self.pushScope() catch return null;
            self.arrow_base = self.scopes.items.len - 1;
            self.current_captures = &caps;
            for (arrow.params) |p| {
                self.currentScope().put(self.arena, p.name, .{ .ty = p.checked_type.?, .mutable = true, .emit_name = p.name }) catch return null;
            }
            // Arrow functions are not async in this subset, so `await` inside an
            // arrow body is rejected (it is not on an awaiting code path).
            const saved_in_async = self.in_async;
            const saved_in_function = self.in_function;
            self.in_async = false;
            self.in_function = true;
            var body_type: ?types.Type = null;
            if (arrow.body_block) |block| {
                // Statement-body arrow: a void body. `return;` is allowed;
                // `return <value>;` is rejected (a value body must use `=> expr`).
                const saved_ret = self.current_return_type;
                self.current_return_type = .void;
                body_type = .void;
                for (block) |*stmt| {
                    self.checkStmt(program, stmt) catch {
                        body_type = null;
                        break;
                    };
                }
                self.current_return_type = saved_ret;
            } else {
                body_type = self.exprType(program, arrow.body_expr.?, line, col);
            }
            self.in_async = saved_in_async;
            self.in_function = saved_in_function;
            self.popScope();
            self.arrow_base = saved_base;
            self.current_captures = saved_caps;
            arrow.captures = caps.toOwnedSlice(self.arena) catch return null;
            const bt = body_type orelse return null;
            var ret: types.Type = bt;
            if (arrow.return_annotation.len > 0) {
                ret = self.typeFromAnnotation(arrow.return_annotation, line, col) catch return null;
                if (!types.same(ret, bt)) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
            }
            arrow.checked_return_type = ret;
            const params = self.arena.alloc(types.Type, arrow.params.len) catch return null;
            for (arrow.params, 0..) |p, i| params[i] = p.checked_type.?;
            const ret_p = self.arena.create(types.Type) catch return null;
            ret_p.* = ret;
            const sig = self.arena.create(types.FuncSig) catch return null;
            sig.* = .{ .params = params, .ret = ret_p };
            return .{ .func_type = sig };
        },
        .template => |parts| {
            for (parts) |*part| {
                if (part.expr) |hole| {
                    const ht = self.exprType(program, hole, line, col) orelse return null;
                    if (!types.isStringLike(ht) and !types.isNumeric(ht) and ht != .bool) {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    }
                    part.expr_type = ht;
                }
            }
            return .string;
        },
        .coalesce => |*c| {
            const left_type = self.exprType(program, c.l, line, col) orelse return null;
            if (left_type != .optional) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
            const inner = left_type.optional.*;
            self.ensureAssignable(program, inner, c.r, line, col) catch return null;
            return inner;
        },
        .array => |*arr| {
            const items = arr.items;
            if (items.len == 0) {
                _ = self.fail(line, col, "cannot infer array type") catch {};
                return null;
            }
            // The element type of each entry: a normal entry contributes its
            // own type; a `...src` spread contributes its source array's
            // element type. All entries must agree.
            var elem_type: ?types.Type = null;
            var has_spread = false;
            for (items) |item| {
                var this_elem: types.Type = undefined;
                if (item.* == .spread) {
                    has_spread = true;
                    const src_type = self.exprType(program, item.spread, line, col) orelse return null;
                    if (!types.isArray(src_type)) {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    }
                    this_elem = types.arrayElem(src_type) orelse {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    };
                } else {
                    this_elem = self.exprType(program, item, line, col) orelse return null;
                }
                if (elem_type) |et| {
                    if (!types.same(et, this_elem)) {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    }
                } else elem_type = this_elem;
            }
            const result = types.arrayOf(elem_type.?) orelse {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            };
            if (has_spread) arr.elem_type = elem_type;
            return result;
        },
        .tuple_lit => |t| t.tuple_type,
        .field => |*field| {
            // Enum member access: `EnumName.Member` resolves to the enum type
            // and carries the member's backing value for emission.
            if (field.obj.* == .var_ref) {
                if (self.enums.get(field.obj.var_ref.name)) |einfo| {
                    for (einfo.members) |m| {
                        if (std.mem.eql(u8, m.name, field.name)) {
                            field.enum_value = if (einfo.is_string) .{ .str = m.str_value orelse "" } else .{ .int = m.int_value };
                            return .{ .enum_type = .{ .name = field.obj.var_ref.name, .is_string = einfo.is_string } };
                        }
                    }
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                // `Math.PI` and the other Math constants read as f64 properties.
                if (std.mem.eql(u8, field.obj.var_ref.name, "Math") and
                    self.bindingPtr("Math") == null)
                {
                    const lit: ?[]const u8 =
                        if (std.mem.eql(u8, field.name, "PI")) "3.141592653589793" else if (std.mem.eql(u8, field.name, "E")) "2.718281828459045" else if (std.mem.eql(u8, field.name, "LN2")) "0.6931471805599453" else if (std.mem.eql(u8, field.name, "LN10")) "2.302585092994046" else if (std.mem.eql(u8, field.name, "LOG2E")) "1.4426950408889634" else if (std.mem.eql(u8, field.name, "LOG10E")) "0.4342944819032518" else if (std.mem.eql(u8, field.name, "SQRT2")) "1.4142135623730951" else if (std.mem.eql(u8, field.name, "SQRT1_2")) "0.7071067811865476" else null;
                    if (lit) |l| {
                        field.builtin_const = l;
                        return .f64;
                    }
                }
                // `ClassName.staticField` — a static member read. Only when the
                // name is a class and not shadowed by a local binding.
                if (self.bindingPtr(field.obj.var_ref.name) == null) {
                    if (self.classes.get(field.obj.var_ref.name) != null) {
                        const cname = field.obj.var_ref.name;
                        const rf = self.resolveStaticField(cname, field.name) orelse {
                            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                            return null;
                        };
                        if (!self.visibilityOk(rf.field.visibility, rf.owner, line, col)) return null;
                        field.is_static = true;
                        field.class_name = rf.owner;
                        return rf.field.checked_type;
                    }
                }
            }
            const obj_type = self.exprType(program, field.obj, line, col) orelse return null;
            if (field.optional_chain) {
                if (obj_type != .optional) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                const inner = obj_type.optional.*;
                const field_type = switch (inner) {
                    .named => |type_name| self.fieldType(type_name, field.name, line, col) orelse return null,
                    else => {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    },
                };
                field.chain_field_type = field_type;
                const p = self.arena.create(types.Type) catch return null;
                p.* = field_type;
                return .{ .optional = p };
            }
            if ((types.isStringLike(obj_type) or types.isArray(obj_type)) and std.mem.eql(u8, field.name, "length")) {
                field.builtin = .length;
                // `int` (i32) is the language's integer; typing length as i32
                // lets the common `for`/`while (i < x.length)` index idiom and
                // `charAt(i)`/`substring(...)` compose without an unusable i64.
                return .i32;
            }
            if ((types.isMap(obj_type) or types.isSet(obj_type)) and std.mem.eql(u8, field.name, "size")) {
                field.builtin = .container_size;
                return .i32;
            }
            if (types.isBuffer(obj_type) and std.mem.eql(u8, field.name, "length")) {
                field.builtin = .buffer_length;
                return .i32;
            }
            if (obj_type == .error_obj and std.mem.eql(u8, field.name, "message")) {
                field.builtin = .error_message;
                return .string;
            }
            if (obj_type == .regexp and (std.mem.eql(u8, field.name, "source") or std.mem.eql(u8, field.name, "flags"))) {
                return .string;
            }
            return switch (obj_type) {
                .named => |type_name| self.fieldType(type_name, field.name, line, col),
                .union_type => |union_name| blk2: {
                    // If the union binding is narrowed to a variant, read that
                    // variant's fields; otherwise only the discriminant field.
                    if (field.obj.* == .var_ref) {
                        if (self.narrowedVariant(field.obj.var_ref.name)) |variant| {
                            break :blk2 self.fieldType(variant, field.name, line, col);
                        }
                    }
                    const uinfo = self.unions.get(union_name) orelse return null;
                    if (std.mem.eql(u8, field.name, uinfo.discriminant)) break :blk2 .string;
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                },
                .class_type => |class_name| blk3: {
                    // Instance field read, walking the inheritance chain.
                    if (self.resolveField(class_name, field.name)) |rf| {
                        if (!self.visibilityOk(rf.field.visibility, rf.owner, line, col)) return null;
                        field.class_name = rf.owner;
                        break :blk3 rf.field.checked_type;
                    }
                    // Getter accessor read: `obj.prop`.
                    if (self.resolveAccessor(class_name, field.name, .getter)) |ra| {
                        if (!self.visibilityOk(ra.method.visibility, ra.owner, line, col)) return null;
                        field.is_getter = true;
                        field.class_name = class_name;
                        break :blk3 ra.method.checked_return_type orelse return null;
                    }
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                },
                else => null,
            };
        },
        .this_expr => blk: {
            const cls = self.current_class orelse {
                _ = self.fail(line, col, "E_RETURN_OUTSIDE_FUNCTION") catch {};
                return null;
            };
            break :blk .{ .class_type = cls };
        },
        .new_expr => |*ne| {
            // `new Error("msg")` is equivalent to `Error("msg")` -> error_obj.
            if (std.mem.eql(u8, ne.class_name, "Error") and self.classes.get("Error") == null) {
                if (ne.args.len != 1) {
                    _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                    return null;
                }
                const message_type = self.exprType(program, ne.args[0], line, col) orelse return null;
                if (!types.same(.string, message_type)) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                ne.container_type = .error_obj;
                return .error_obj;
            }
            // Built-in container instantiation `new Map<K,V>()` / `new Set<T>()`.
            if (std.mem.eql(u8, ne.class_name, "Map") and self.classes.get("Map") == null) {
                const k = self.arena.create(types.Type) catch return null;
                const v = self.arena.create(types.Type) catch return null;
                if (ne.type_args.len == 2) {
                    k.* = self.typeFromAnnotation(ne.type_args[0], line, col) catch return null;
                    v.* = self.typeFromAnnotation(ne.type_args[1], line, col) catch return null;
                } else if (ne.type_args.len != 0) {
                    _ = self.fail(line, col, "E_TYPE_ARG_COUNT") catch {};
                    return null;
                }
                // Optional entries initializer: an array literal of `[key, value]`
                // pairs, `new Map([["a", 1], ["b", 2]])`.
                if (ne.args.len == 1) {
                    if (ne.args[0].* != .array) {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    }
                    for (ne.args[0].array.items, 0..) |entry, ei| {
                        if (entry.* != .array or entry.array.items.len != 2) {
                            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                            return null;
                        }
                        const kt = self.exprType(program, entry.array.items[0], line, col) orelse return null;
                        const vt = self.exprType(program, entry.array.items[1], line, col) orelse return null;
                        if (ne.type_args.len == 0 and ei == 0) {
                            // Infer K/V from the first entry.
                            k.* = kt;
                            v.* = vt;
                        } else if (!types.same(k.*, kt) or !types.same(v.*, vt)) {
                            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                            return null;
                        }
                    }
                    if (ne.type_args.len == 0 and ne.args[0].array.items.len == 0) {
                        _ = self.fail(line, col, "E_TYPE_ARG_COUNT") catch {};
                        return null;
                    }
                } else if (ne.args.len != 0) {
                    _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                    return null;
                } else if (ne.type_args.len == 0) {
                    _ = self.fail(line, col, "E_TYPE_ARG_COUNT") catch {};
                    return null;
                }
                const m = self.arena.create(types.MapType) catch return null;
                m.* = .{ .key = k, .value = v };
                const ct = types.Type{ .map_type = m };
                ne.container_type = ct;
                program.needs_map = true;
                return ct;
            }
            if (std.mem.eql(u8, ne.class_name, "Set") and self.classes.get("Set") == null) {
                const set_elem = self.arena.create(types.Type) catch return null;
                if (ne.type_args.len == 1) {
                    set_elem.* = self.typeFromAnnotation(ne.type_args[0], line, col) catch return null;
                } else if (ne.type_args.len == 0 and ne.args.len == 1) {
                    // Infer `Set<T>` from the initializer array's element type.
                    const at = self.exprType(program, ne.args[0], line, col) orelse return null;
                    set_elem.* = types.arrayElem(at) orelse {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    };
                } else {
                    _ = self.fail(line, col, "E_TYPE_ARG_COUNT") catch {};
                    return null;
                }
                // Optional initializer: an array of elements (`new Set([1,2,3])`).
                if (ne.args.len == 1) {
                    const at = self.exprType(program, ne.args[0], line, col) orelse return null;
                    const ae = types.arrayElem(at) orelse {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    };
                    if (!types.same(ae, set_elem.*)) {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    }
                } else if (ne.args.len != 0) {
                    _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                    return null;
                }
                const ct = types.Type{ .set_type = set_elem };
                ne.container_type = ct;
                program.needs_set = true;
                return ct;
            }
            if (std.mem.eql(u8, ne.class_name, "EventEmitter") and self.classes.get("EventEmitter") == null) {
                if (ne.type_args.len != 1) {
                    _ = self.fail(line, col, "E_TYPE_ARG_COUNT") catch {};
                    return null;
                }
                if (ne.args.len != 0) {
                    _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                    return null;
                }
                const payload = self.arena.create(types.Type) catch return null;
                payload.* = self.typeFromAnnotation(ne.type_args[0], line, col) catch return null;
                const ct = types.Type{ .event_emitter_type = payload };
                ne.container_type = ct;
                program.needs_event_emitter = true;
                return ct;
            }
            // Generic class instantiation `new C<...>(...)`: specialize the
            // class and retarget `new` to the concrete mangled class.
            if (self.generic_classes.get(ne.class_name)) |gcls| {
                const type_args = self.resolveExplicitTypeArgs(gcls.type_params, ne.type_args, line, col) catch return null;
                const mname = self.specializeClass(gcls, type_args, line, col) catch return null;
                ne.class_name = mname;
                ne.type_args = &.{}; // retargeted to a concrete class; keep re-checks idempotent
                // fall through to the concrete validation below
            } else if (ne.type_args.len > 0) {
                // Type arguments on a non-generic class are an error.
                _ = self.fail(line, col, "E_TYPE_ARG_COUNT") catch {};
                return null;
            }
            const info = self.classes.get(ne.class_name) orelse {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            };
            // Resolve the effective constructor: the class's own, else the
            // nearest inherited one.
            var ctor_params: []ast.FunctionParam = info.ctor_params;
            var has_ctor = info.has_ctor;
            if (!has_ctor) {
                var cur = info.parent;
                while (cur) |pname| {
                    const pinfo = self.classes.get(pname) orelse break;
                    if (pinfo.has_ctor) {
                        ctor_params = pinfo.ctor_params;
                        has_ctor = true;
                        break;
                    }
                    cur = pinfo.parent;
                }
            }
            if (has_ctor) {
                if (ne.args.len != ctor_params.len) {
                    _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                    return null;
                }
                for (ne.args, ctor_params) |arg, p| {
                    const pt = p.checked_type orelse return null;
                    self.ensureAssignable(program, pt, arg, line, col) catch {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    };
                }
            } else if (ne.args.len != 0) {
                _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                return null;
            }
            return .{ .class_type = ne.class_name };
        },
        .method_call => |*mc| {
            // Optional method call `a?.b()` (spec 052) is deferred: unlike
            // optional field/index, the method-call resolver recomputes the
            // receiver type internally across many dispatch/return paths, so
            // unwrapping the optional receiver and re-wrapping every result
            // would need a disproportionate refactor. Rejected cleanly for
            // now (optional field `a?.b` and optional index `a?.[i]` work).
            if (mc.optional_chain) {
                _ = self.fail(line, col, "E_UNSUPPORTED_OPTIONAL_CALL") catch {};
                return null;
            }
            // `console.log(x)` (and .info/.debug/.error/.warn/.trace) used as a
            // void expression — enables it inside an arrow body, e.g.
            // `xs.forEach(x => console.log(x))`.
            if (mc.obj.* == .var_ref and std.mem.eql(u8, mc.obj.var_ref.name, "console") and
                self.bindingPtr("console") == null and
                (std.mem.eql(u8, mc.name, "log") or std.mem.eql(u8, mc.name, "info") or
                    std.mem.eql(u8, mc.name, "debug") or std.mem.eql(u8, mc.name, "error") or
                    std.mem.eql(u8, mc.name, "warn") or std.mem.eql(u8, mc.name, "trace")))
            {
                if (mc.args.len < 1) {
                    _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                    return null;
                }
                // Each argument must be printable; wrap it in String() so the
                // emitter can format any number of args uniformly as strings
                // (joined by spaces, JS-style).
                for (mc.args, 0..) |arg, i| {
                    const at = self.exprType(program, arg, line, col) orelse return null;
                    if (!types.isStringLike(at) and !types.isNumeric(at) and at != .bool) {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    }
                    if (!types.isStringLike(at)) mc.args[i] = self.wrapStringify(arg) catch return null;
                }
                mc.is_console = true;
                mc.array_elem_type = .string;
                // log/info/debug print to real stdout via __consoleOut, which
                // needs __io hoisted; error/warn/trace use std.debug.print.
                if (std.mem.eql(u8, mc.name, "log") or std.mem.eql(u8, mc.name, "info") or std.mem.eql(u8, mc.name, "debug")) {
                    program.uses_io = true;
                    program.needs_console_stdout = true;
                }
                return .void;
            }
            // `ClassName.staticMethod(args)` — static method call.
            if (mc.obj.* == .var_ref and self.bindingPtr(mc.obj.var_ref.name) == null and self.classes.get(mc.obj.var_ref.name) != null) {
                const cname = mc.obj.var_ref.name;
                const rm = self.resolveStaticMethod(cname, mc.name) orelse {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                };
                if (!self.visibilityOk(rm.method.visibility, rm.owner, line, col)) return null;
                if (mc.args.len != rm.method.params.len) {
                    _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                    return null;
                }
                for (mc.args, rm.method.params) |arg, p| {
                    self.ensureAssignable(program, p.checked_type orelse return null, arg, line, col) catch {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    };
                }
                mc.is_static = true;
                mc.class_name = rm.owner;
                return rm.method.checked_return_type orelse return null;
            }
            const obj_type = self.exprType(program, mc.obj, line, col) orelse return null;
            if (obj_type == .regexp) {
                // `re.test(s)` -> bool. (Other regex methods arrive in later cycles.)
                if (!std.mem.eql(u8, mc.name, "test")) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                if (mc.args.len != 1) {
                    _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                    return null;
                }
                self.ensureAssignable(program, .string, mc.args[0], line, col) catch {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                };
                mc.container_type = .regexp; // sentinel for codegen
                return .bool;
            }
            if (types.isArray(obj_type)) {
                return self.arrayMethod(program, mc, obj_type, line, col);
            }
            if (types.isStringLike(obj_type)) {
                return self.stringMethod(program, mc, line, col);
            }
            if (types.isNumeric(obj_type)) {
                return self.numberInstanceMethod(program, mc, obj_type, line, col);
            }
            if (types.isMap(obj_type)) {
                return self.mapMethod(program, mc, obj_type, line, col);
            }
            if (types.isSet(obj_type)) {
                return self.setMethod(program, mc, obj_type, line, col);
            }
            if (types.isEventEmitter(obj_type)) {
                return self.eventEmitterMethod(program, mc, obj_type, line, col);
            }
            if (types.isReadableStream(obj_type)) {
                return self.readableStreamMethod(program, mc, obj_type, line, col);
            }
            if (types.isWritableStream(obj_type)) {
                return self.writableStreamMethod(program, mc, obj_type, line, col);
            }
            if (types.isSocket(obj_type)) {
                return self.socketMethod(program, mc, obj_type, line, col);
            }
            if (types.isBuffer(obj_type)) {
                return self.bufferMethod(program, mc, obj_type, line, col);
            }
            if (types.isHash(obj_type)) {
                return self.hashMethod(program, mc, obj_type, line, col);
            }
            if (types.isHmac(obj_type)) {
                return self.hmacMethod(program, mc, obj_type, line, col);
            }
            if (obj_type != .class_type) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
            const cls = obj_type.class_type;
            const rm = self.resolveMethod(cls, mc.name) orelse {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            };
            if (!self.visibilityOk(rm.method.visibility, rm.owner, line, col)) return null;
            if (mc.args.len != rm.method.params.len) {
                _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                return null;
            }
            for (mc.args, rm.method.params) |arg, p| {
                self.ensureAssignable(program, p.checked_type orelse return null, arg, line, col) catch {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                };
            }
            // Methods are emitted on the most-derived struct (flattened), so
            // the call dispatches on the static receiver class.
            mc.class_name = cls;
            return rm.method.checked_return_type orelse return null;
        },
        .super_call => |*sc| {
            const cls = self.current_class orelse {
                _ = self.fail(line, col, "E_RETURN_OUTSIDE_FUNCTION") catch {};
                return null;
            };
            const parent = (self.classes.get(cls) orelse return null).parent orelse {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            };
            const rm = self.resolveMethod(parent, sc.name) orelse {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            };
            if (sc.args.len != rm.method.params.len) {
                _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                return null;
            }
            for (sc.args, rm.method.params) |arg, p| {
                self.ensureAssignable(program, p.checked_type orelse return null, arg, line, col) catch {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                };
            }
            sc.parent = rm.owner;
            return rm.method.checked_return_type orelse return null;
        },
        .index => |*index| {
            var obj_type = self.exprType(program, index.obj, line, col) orelse return null;
            // Optional index `a?.[i]` (spec 052): the object must be
            // optional; unwrap it and wrap the element type back into an
            // optional (so a null object yields null, not an error).
            if (index.optional_chain) {
                if (obj_type != .optional) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                obj_type = obj_type.optional.*;
            }
            const elem_result: types.Type = blk: {
                // Tuple indexed access: requires an integer-literal index in range.
                if (obj_type == .tuple_type) {
                    const elems = obj_type.tuple_type;
                    if (index.value.* != .num or index.value.num < 0 or index.value.num >= @as(i64, @intCast(elems.len))) {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    }
                    const pos: usize = @intCast(index.value.num);
                    index.tuple_index = pos;
                    index.checked_element_type = elems[pos];
                    break :blk elems[pos];
                }
                const index_type = self.exprType(program, index.value, line, col) orelse return null;
                if (!types.same(.i32, index_type) and !types.same(.i64, index_type)) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                // `s[i]` on a string is the single-character substring at `i`
                // (a string), matching JS/TS.
                if (types.isStringLike(obj_type)) {
                    index.checked_element_type = .string;
                    index.string_char = true;
                    break :blk .string;
                }
                const elem_type = types.arrayElem(obj_type) orelse {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                };
                index.checked_element_type = elem_type;
                break :blk elem_type;
            };
            if (index.optional_chain) {
                index.chain_result_type = elem_result;
                const p = self.arena.create(types.Type) catch return null;
                p.* = elem_result;
                return .{ .optional = p };
            }
            return elem_result;
        },
        .obj => null,
        .optional_call => |*oc| {
            // `a?.()` (spec 062): calling a possibly-null closure value
            // directly. Narrower than `a?.b`/`a?.[i]`'s "any nullable
            // value" -- the unwrapped type must specifically be a
            // `func_type`, not just non-optional.
            const callee_type = self.exprType(program, oc.callee, line, col) orelse return null;
            if (callee_type != .optional) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
            const inner = callee_type.optional.*;
            if (inner != .func_type) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
            const sig = inner.func_type;
            if (oc.args.len != sig.params.len) {
                _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                return null;
            }
            for (oc.args, sig.params) |arg, pt| {
                self.ensureAssignable(program, pt, arg, line, col) catch {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                };
            }
            // A void-returning callee has no meaningful `?void` -- reject,
            // matching spec 052's own precedent for `a?.b()` on a void method.
            if (sig.ret.* == .void) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
            oc.chain_result_type = sig.ret.*;
            const p = self.arena.create(types.Type) catch return null;
            p.* = sig.ret.*;
            return .{ .optional = p };
        },
        .call => |*call| {
            // Global parseInt/parseFloat: aliases of Number.parseInt/parseFloat.
            if ((std.mem.eql(u8, call.name, "parseInt") or std.mem.eql(u8, call.name, "parseFloat")) and self.funcs.get(call.name) == null) {
                const is_int = std.mem.eql(u8, call.name, "parseInt");
                const max_args: usize = if (is_int) 2 else 1;
                if (call.args.len < 1 or call.args.len > max_args) {
                    _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                    return null;
                }
                const s_type = self.exprType(program, call.args[0], line, col) orelse return null;
                if (!types.same(.string, s_type)) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                if (call.args.len == 2) {
                    const r_type = self.exprType(program, call.args[1], line, col) orelse return null;
                    if (!types.isInteger(r_type)) {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    }
                }
                call.is_global_parse = true;
                const inner = self.arena.create(types.Type) catch return null;
                inner.* = if (is_int) .i32 else .f64;
                return .{ .optional = inner };
            }
            // Global String(x) conversion: number/bool/string -> string.
            if (std.mem.eql(u8, call.name, "String") and self.funcs.get(call.name) == null) {
                if (call.args.len != 1) {
                    _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                    return null;
                }
                const at = self.exprType(program, call.args[0], line, col) orelse return null;
                if (!types.isNumeric(at) and !types.same(.string, at) and at != .bool) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                call.is_global_parse = true;
                return .string;
            }
            // Global Number(x) conversion: number/bool/string -> f64 (NaN if a
            // string doesn't parse).
            if (std.mem.eql(u8, call.name, "Number") and self.funcs.get(call.name) == null) {
                if (call.args.len != 1) {
                    _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                    return null;
                }
                const at = self.exprType(program, call.args[0], line, col) orelse return null;
                if (!types.isNumeric(at) and !types.same(.string, at) and at != .bool) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                call.is_global_parse = true;
                return .f64;
            }
            // Global Boolean(x) conversion: truthiness of number/bool/string.
            if (std.mem.eql(u8, call.name, "Boolean") and self.funcs.get(call.name) == null) {
                if (call.args.len != 1) {
                    _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                    return null;
                }
                const at = self.exprType(program, call.args[0], line, col) orelse return null;
                if (!types.isNumeric(at) and !types.same(.string, at) and at != .bool) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                call.is_global_parse = true;
                return .bool;
            }
            // Global isNaN/isFinite: numeric predicate -> bool.
            if ((std.mem.eql(u8, call.name, "isNaN") or std.mem.eql(u8, call.name, "isFinite")) and self.funcs.get(call.name) == null) {
                if (call.args.len != 1) {
                    _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                    return null;
                }
                const at = self.exprType(program, call.args[0], line, col) orelse return null;
                if (!types.isNumeric(at)) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                call.is_global_parse = true;
                return .bool;
            }
            if (std.mem.eql(u8, call.name, "Error")) {
                if (call.args.len != 1) {
                    _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                    return null;
                }
                const message_type = self.exprType(program, call.args[0], line, col) orelse return null;
                if (!types.same(.string, message_type)) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                return .error_obj;
            }
            if (std.mem.eql(u8, call.name, "expect")) {
                if (self.test_depth == 0) {
                    _ = self.fail(line, col, "expect is only allowed inside a test block") catch {};
                    return null;
                }
                if (call.args.len != 1) {
                    _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                    return null;
                }
                const cond_type = self.exprType(program, call.args[0], line, col) orelse return null;
                if (!types.same(.bool, cond_type)) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                return .void;
            }
            // Matcher form `expect(actual).toBe(expected)` / `.toEqual(...)`:
            // both operands must share a type; lowers to std.testing.expectEqual.
            if (std.mem.eql(u8, call.name, "__expectToBe") or std.mem.eql(u8, call.name, "__expectToEqual")) {
                if (self.test_depth == 0) {
                    _ = self.fail(line, col, "expect is only allowed inside a test block") catch {};
                    return null;
                }
                if (call.args.len != 2) {
                    _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                    return null;
                }
                const actual_type = self.exprType(program, call.args[0], line, col) orelse return null;
                const expected_type = self.exprType(program, call.args[1], line, col) orelse return null;
                if (!types.same(actual_type, expected_type)) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                // Strings compare by bytes, not slice identity, so route the
                // string case to a distinct lowering.
                if (types.same(.string, actual_type)) {
                    call.name = "__expectStrEqual";
                }
                return .void;
            }
            if (std.mem.eql(u8, call.name, "argsCount")) {
                if (call.args.len != 0) {
                    _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                    return null;
                }
                program.uses_io = true;
                program.needs_args = true;
                return .i32;
            }
            if (std.mem.eql(u8, call.name, "arg")) {
                if (call.args.len != 1) {
                    _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                    return null;
                }
                const index_type = self.exprType(program, call.args[0], line, col) orelse return null;
                if (!types.same(.i32, index_type)) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                program.uses_io = true;
                program.needs_args = true;
                return .string;
            }
            if (std.mem.eql(u8, call.name, "httpGet")) {
                for (call.args) |arg| _ = self.exprType(program, arg, line, col) orelse return null;
                program.uses_io = true;
                program.needs_httpget = true;
                return .i64;
            }
            if (std.mem.eql(u8, call.name, "serve")) {
                for (call.args) |arg| _ = self.exprType(program, arg, line, col) orelse return null;
                program.uses_io = true;
                program.needs_serve = true;
                return .void;
            }
            if (std.mem.eql(u8, call.name, "setTimeout") or std.mem.eql(u8, call.name, "setInterval")) {
                if (call.args.len != 2) {
                    _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                    return null;
                }
                // First arg: a `() => void` callback function value.
                const cb_type = self.exprType(program, call.args[0], line, col) orelse return null;
                const cb_ok = cb_type == .func_type and cb_type.func_type.params.len == 0 and cb_type.func_type.ret.* == .void;
                if (!cb_ok) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                // Second arg: an integer millisecond delay.
                const ms_type = self.exprType(program, call.args[1], line, col) orelse return null;
                if (!types.isInteger(ms_type)) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                program.uses_io = true;
                program.needs_async = true;
                // A handle (spec 038), like an fs.openSync fd -- not `void`
                // anymore, so `clearTimeout`/`clearInterval` have something
                // to cancel.
                return .i32;
            }
            if (std.mem.eql(u8, call.name, "clearTimeout") or std.mem.eql(u8, call.name, "clearInterval")) {
                if (call.args.len != 1) {
                    _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                    return null;
                }
                const id_type = self.exprType(program, call.args[0], line, col) orelse return null;
                if (!types.same(.i32, id_type)) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
                // clearTimeout/clearInterval are the same runtime function
                // under the hood (spec 038) -- both just flip a
                // cancellation flag looked up by id.
                call.name = "__clearTimer";
                program.uses_io = true;
                program.needs_async = true;
                return .void;
            }
            // A call to a generic function: resolve type arguments
            // (explicit or inferred), specialize, and retarget the call.
            if (self.generic_funcs.get(call.name)) |gdecl| {
                const type_args = if (call.type_args.len > 0)
                    (self.resolveExplicitTypeArgs(gdecl.type_params, call.type_args, line, col) catch return null)
                else
                    (self.inferTypeArgs(program, gdecl.type_params, gdecl.params, call.args, line, col) catch return null);
                const spec = self.specializeFunction(gdecl, type_args, line, col) catch return null;
                const info = self.funcs.get(spec.name) orelse return null;
                if (call.args.len != info.params.len) {
                    _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                    return null;
                }
                for (call.args, info.params) |arg, param| {
                    const pt = param.checked_type orelse return null;
                    self.ensureAssignable(program, pt, arg, line, col) catch {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    };
                }
                call.emit_name = spec.name;
                return spec.ret;
            }
            const func = self.funcs.get(call.name) orelse {
                // Calling a function-typed binding (parameter or local).
                if (self.binding(call.name)) |b| {
                    if (b.ty == .func_type) {
                        const sig = b.ty.func_type;
                        if (call.args.len != sig.params.len) {
                            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                            return null;
                        }
                        for (call.args, sig.params) |arg, pt| {
                            self.ensureAssignable(program, pt, arg, line, col) catch {
                                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                                return null;
                            };
                        }
                        call.emit_name = b.emit_name;
                        call.is_closure = true;
                        return sig.ret.*;
                    }
                }
                _ = self.fail(line, col, "unknown function") catch {};
                return null;
            };
            // A by-reference (`Ref<T>`) parameter requires an addressable
            // lvalue argument; mark each so the emitter inserts `&arg`.
            var any_ref = false;
            for (func.params) |p| {
                if (p.is_ref) any_ref = true;
            }
            if (any_ref) {
                const flags = self.arena.alloc(bool, func.params.len) catch return null;
                for (func.params, 0..) |p, i| {
                    flags[i] = p.is_ref;
                    if (p.is_ref) {
                        if (i >= call.args.len or !check_mod.isAddressable(call.args[i]) or !self.refRootMutable(call.args[i])) {
                            _ = self.fail(line, col, "E_REF_ARG") catch {};
                            return null;
                        }
                        // Taking the address of a local requires a mutable
                        // (`var`) binding; force one for the root variable.
                        self.markReassignedRoot(call.args[i]);
                    }
                }
                call.ref_args = flags;
            }
            call.args = self.checkCallArgs(program, func.params, call.args, line, col) orelse return null;
            if (func.is_extern) {
                // Mark string params/return so the emitter inserts the FFI
                // marshalling glue (NUL-terminate in, copy out).
                const flags = self.arena.alloc(bool, func.params.len) catch return null;
                var any_string = func.return_type == .string;
                for (func.params, 0..) |p, i| {
                    flags[i] = (p.checked_type orelse types.Type.void) == .string;
                    if (flags[i]) any_string = true;
                }
                call.ffi_string_args = flags;
                call.ffi_string_return = func.return_type == .string;
                // The marshalling glue uses the shared `__alloc`, which is
                // only emitted when the program uses I/O plumbing.
                if (any_string) program.uses_io = true;
            }
            return func.return_type;
        },
        .static_call => |*call| {
            return self.staticCallType(program, call, line, col);
        },
        .cast => |*c| {
            const target = self.typeFromAnnotation(c.annotation, line, col) catch return null;
            if (c.is_satisfies) {
                // `expr satisfies T` (spec 052): verify expr is assignable to
                // T using full structural assignability (which also validates
                // object/array literals against T, unlike `as`), and take T
                // as the result type. TS's "satisfies keeps the operand's own
                // narrower type" nuance is moot in Lumen -- there are no
                // value-level literal types or scalar unions for the operand
                // to carry a narrower type than T, so an `int` is `int` and a
                // record typed as T is T. The distinction from `as T` is that
                // satisfies does a real assignability check (a non-assignable
                // value is a type error) rather than a representation-only
                // assertion. Documented as a divergence.
                self.ensureAssignable(program, target, c.inner, line, col) catch {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                };
                c.checked_type = target;
                return target;
            }
            const source = self.exprType(program, c.inner, line, col) orelse return null;
            if (!self.castAllowed(source, target)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
            c.checked_type = target;
            return target;
        },
        .regex => {
            // Flag regex use so the (capture-heavy) regex runtime is only
            // emitted when needed -- otherwise its short capture names shadow
            // like-named user functions (`function f`, `p`, `s`, ...).
            program.uses_regex = true;
            return types.inferExprType(e);
        },
        else => types.inferExprType(e),
    };
}

pub fn fieldType(self: *Checker, type_name: []const u8, field_name: []const u8, line: u32, col: u32) ?types.Type {
    const decl = self.type_decls.get(type_name) orelse {
        _ = self.fail(line, col, "unknown type name") catch {};
        return null;
    };
    for (decl.fields) |field| {
        if (std.mem.eql(u8, field.name, field_name)) {
            return field.checked_type orelse {
                _ = self.fail(line, col, "unknown field type") catch {};
                return null;
            };
        }
    }
    _ = self.fail(line, col, "unknown field") catch {};
    return null;
}
