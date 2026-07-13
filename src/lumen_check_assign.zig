//! Assignability and cast checking: "can a value of type X be used where Y is
//! expected" (`ensureAssignable`, called at every declaration/assignment/call
//! argument/return) and "is `expr as T` a sound type assertion"
//! (`castAllowed`, used by the `as` cast operator).
//!
//! Pulled out as a self-contained "type compatibility" concern, distinct from
//! computing an expression's type in the first place (`exprType`, in
//! `lumen_check_expr.zig`), which calls into this.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const types = @import("lumen_types.zig");
const diag_mod = @import("lumen_diag.zig");
const check_mod = @import("lumen_check.zig");

const Checker = check_mod.Checker;
const CompileError = diag_mod.CompileError;

pub fn ensureAssignable(self: *Checker, program: *ast.Program, expected: types.Type, value: *ast.Expr, line: u32, col: u32) CompileError!void {
    switch (expected) {
        .string_literal_union => |type_name| {
            const decl = self.type_decls.get(type_name) orelse return self.fail(line, col, "unknown type name");
            const literals = decl.string_literals orelse return self.fail(line, col, "E_TYPE_MISMATCH");
            if (value.* == .str) {
                for (literals) |literal| {
                    if (std.mem.eql(u8, literal, value.str)) return;
                }
                // Name the union's members (spec 281).
                var opts: std.ArrayListUnmanaged(u8) = .empty;
                for (literals, 0..) |literal, i| {
                    if (i > 0) opts.appendSlice(self.arena, " | ") catch {};
                    opts.append(self.arena, '"') catch {};
                    opts.appendSlice(self.arena, literal) catch {};
                    opts.append(self.arena, '"') catch {};
                }
                // A synthetic `keyof P` union displays as `keyof P`, not its
                // internal mangled name.
                const disp = if (std.mem.startsWith(u8, type_name, "__keyof_"))
                    std.fmt.allocPrint(self.arena, "keyof {s}", .{type_name["__keyof_".len..]}) catch type_name
                else
                    type_name;
                const msg = std.fmt.allocPrint(self.arena, "\"{s}\" is not a valid `{s}` — expected {s}", .{ value.str, disp, opts.items }) catch "E_TYPE_MISMATCH";
                return self.fail(line, col, msg);
            }
            const actual_type = self.exprType(program, value, line, col) orelse return self.inferenceFail(line, col, "E_TYPE_MISMATCH");
            if (!types.same(expected, actual_type)) return self.failTypeMismatch(line, col, expected, actual_type);
        },
        .int_literal_union => |type_name| {
            const decl = self.type_decls.get(type_name) orelse return self.fail(line, col, "unknown type name");
            const literals = decl.int_literals orelse return self.fail(line, col, "E_TYPE_MISMATCH");
            if (value.* == .num) {
                for (literals) |literal| {
                    if (literal == value.num) return;
                }
                return self.fail(line, col, "E_TYPE_MISMATCH");
            }
            const actual_type = self.exprType(program, value, line, col) orelse return self.inferenceFail(line, col, "E_TYPE_MISMATCH");
            if (!types.same(expected, actual_type)) return self.failTypeMismatch(line, col, expected, actual_type);
        },
        .named => |type_name| {
            if (value.* != .obj) {
                const actual_type = self.exprType(program, value, line, col) orelse return self.inferenceFail(line, col, "E_TYPE_MISMATCH");
                if (!types.same(expected, actual_type)) {
                    // Structural width subtyping (spec 278): a record value
                    // whose type declares (at least) every field of the target
                    // — same names, same types — coerces by building the
                    // narrower record from field reads. Only cheap,
                    // re-emittable sources (a variable or a field path)
                    // qualify, since each target field re-reads the source.
                    if (actual_type == .named and (value.* == .var_ref or value.* == .field)) {
                        if (self.structuralFields(type_name, actual_type.named)) |target_fields| {
                            const inits = self.arena.alloc(ast.FieldInit, target_fields.len) catch return error.OutOfMemory;
                            const src = self.arena.create(ast.Expr) catch return error.OutOfMemory;
                            src.* = value.*;
                            for (target_fields, 0..) |fname, i| {
                                const fread = self.arena.create(ast.Expr) catch return error.OutOfMemory;
                                fread.* = .{ .field = .{ .obj = src, .name = fname } };
                                inits[i] = .{ .name = fname, .value = fread };
                            }
                            value.* = .{ .obj = inits };
                            return self.ensureAssignable(program, expected, value, line, col);
                        }
                    }
                    return self.failTypeMismatch(line, col, expected, actual_type);
                }
                return;
            }
            const decl = self.type_decls.get(type_name) orelse return self.fail(line, col, "unknown type name");
            if (decl.string_literals != null) return self.fail(line, col, "E_TYPE_MISMATCH");
            const provided = value.obj;
            // A single `...src` spread may supply any fields not written
            // explicitly. The spread source must be a record assignable to the
            // target type.
            var spread_src: ?*ast.Expr = null;
            for (provided) |pf| {
                if (pf.is_spread) {
                    if (spread_src != null) return self.fail(line, col, "E_TYPE_MISMATCH");
                    try self.ensureAssignable(program, expected, pf.value, line, col);
                    spread_src = pf.value;
                    continue;
                }
                // Reject explicit fields not declared on the target type,
                // listing what the type does have.
                var known = false;
                for (decl.fields) |df| {
                    if (std.mem.eql(u8, df.name, pf.name)) known = true;
                }
                if (!known) {
                    var names: std.ArrayListUnmanaged(u8) = .empty;
                    for (decl.fields, 0..) |df, fi| {
                        if (fi > 0) names.appendSlice(self.arena, ", ") catch {};
                        names.appendSlice(self.arena, df.name) catch {};
                    }
                    const msg = std.fmt.allocPrint(self.arena, "object literal has unknown property '{s}' — `{s}` has: {s}", .{ pf.name, type_name, names.items }) catch "E_TYPE_MISMATCH";
                    return self.fail(line, col, msg);
                }
            }
            // Build the literal in declared order, filling omitted optional
            // fields with the absent value so emission has every field.
            const ordered = self.arena.alloc(ast.FieldInit, decl.fields.len) catch return error.OutOfMemory;
            for (decl.fields, 0..) |expected_field, i| {
                const expected_field_type = expected_field.checked_type orelse return self.fail(line, col, "unknown field type");
                if (check_mod.findField(provided, expected_field.name)) |value_field| {
                    try self.ensureAssignable(program, expected_field_type, value_field.value, line, col);
                    ordered[i] = value_field;
                } else if (spread_src) |src| {
                    // Inherit the field from the spread source: `src.field`.
                    const fref = self.arena.create(ast.Expr) catch return error.OutOfMemory;
                    fref.* = .{ .field = .{ .obj = src, .name = expected_field.name } };
                    ordered[i] = .{ .name = expected_field.name, .value = fref };
                } else if (expected_field_type == .optional) {
                    const absent = self.arena.create(ast.Expr) catch return error.OutOfMemory;
                    absent.* = .null_lit;
                    ordered[i] = .{ .name = expected_field.name, .value = absent };
                } else {
                    const tn = types.tsName(self.arena, expected_field_type) catch "?";
                    const msg = std.fmt.allocPrint(self.arena, "object literal is missing property '{s}' (`{s}`) required by `{s}`", .{ expected_field.name, tn, type_name }) catch "E_TYPE_MISMATCH";
                    return self.fail(line, col, msg);
                }
            }
            value.* = .{ .obj = ordered };
        },
        .union_type => |union_name| {
            const uinfo = self.unions.get(union_name) orelse return self.fail(line, col, "unknown type name");
            // A ternary whose branches are different variants (`flag ? a : b`)
            // is assignable to the union when each branch is: check each side
            // against the union so both coerce independently (spec 385).
            if (value.* == .ternary) {
                const t = value.ternary;
                const ct = self.exprType(program, t.cond, line, col) orelse return self.inferenceFail(line, col, "E_TYPE_MISMATCH");
                if (!types.same(.bool, ct)) return self.failCondition(line, col, "ternary", ct);
                try self.ensureAssignable(program, expected, t.then_expr, line, col);
                try self.ensureAssignable(program, expected, t.else_expr, line, col);
                value.ternary.result_type = expected;
                return;
            }
            // A union value flows through (same union, narrowed variant, or a
            // value already typed as one of the variants).
            if (value.* != .obj) {
                const actual_type = self.exprType(program, value, line, col) orelse return self.inferenceFail(line, col, "E_TYPE_MISMATCH");
                if (types.same(expected, actual_type)) return;
                if (actual_type == .named) {
                    for (uinfo.variants) |v| {
                        if (std.mem.eql(u8, v.name, actual_type.named)) {
                            // A variant record value used where the union is
                            // expected: the union lowers to a flat struct (every
                            // variant field, defaulted), so a variant-typed value
                            // doesn't coerce as-is. Rewrite cheap re-emittable
                            // sources into an object literal of field reads — the
                            // emitted anonymous literal coerces to the flat
                            // struct, defaults filling the other variants'
                            // fields (same trick as structural width subtyping).
                            // Only a variable or field path is cheap to re-emit
                            // (each target field re-reads the source). Any other
                            // expression (a call result, a ternary) would be
                            // re-evaluated per field, so it must be bound to a
                            // local first — reject with that guidance rather than
                            // emit code the backend can't type.
                            if (!(value.* == .var_ref or value.* == .field)) {
                                const msg = std.fmt.allocPrint(self.arena, "a `{s}` value coerces to `{s}` only from a variable or field — bind it to a `const` first (`const t = ...; ...: {s} = t`)", .{ actual_type.named, union_name, union_name }) catch "E_TYPE_MISMATCH";
                                return self.fail(line, col, msg);
                            }
                            const vfields = self.declFields(v.name);
                            const inits = self.arena.alloc(ast.FieldInit, vfields.len) catch return error.OutOfMemory;
                            const src = self.arena.create(ast.Expr) catch return error.OutOfMemory;
                            src.* = value.*;
                            for (vfields, 0..) |vf, i| {
                                const fread = self.arena.create(ast.Expr) catch return error.OutOfMemory;
                                fread.* = .{ .field = .{ .obj = src, .name = vf.name } };
                                inits[i] = .{ .name = vf.name, .value = fread };
                            }
                            value.* = .{ .obj = inits };
                            return;
                        }
                    }
                }
                return self.fail(line, col, "E_TYPE_MISMATCH");
            }
            // An object literal must match exactly one variant. Match on the
            // discriminant field's literal value, then validate as that record.
            const disc_field = check_mod.findField(value.obj, uinfo.discriminant) orelse return self.fail(line, col, "E_TYPE_MISMATCH");
            if (disc_field.value.* != .str) return self.fail(line, col, "E_TYPE_MISMATCH");
            const tag = disc_field.value.str;
            for (uinfo.variants) |v| {
                if (std.mem.eql(u8, v.disc_value, tag)) {
                    return self.ensureAssignable(program, .{ .named = v.name }, value, line, col);
                }
            }
            return self.fail(line, col, "E_TYPE_MISMATCH");
        },
        .optional => |inner| {
            if (value.* == .null_lit) return; // absent is always assignable
            if (self.exprType(program, value, line, col)) |actual| {
                if (types.same(expected, actual)) return; // optional <- same optional
                if (actual == .none) return;
            }
            // otherwise the value must be assignable to the non-optional type
            return self.ensureAssignable(program, inner.*, value, line, col);
        },
        .i32_array, .i64_array, .f64_array, .bool_array, .string_array, .named_array, .nested_array => {
            if (value.* != .array) {
                const actual_type = self.exprType(program, value, line, col) orelse return self.inferenceFail(line, col, "E_TYPE_MISMATCH");
                // An `i32[]` value flowing into a `number[]` (`f64[]`) slot widens
                // elementwise — arrays are immutable, so the conversion copy is
                // safe. Matches TS, where every numeric array is `number[]`
                // (spec 415).
                if (expected == .f64_array and actual_type == .i32_array) {
                    const inner = self.arena.create(ast.Expr) catch return error.OutOfMemory;
                    inner.* = value.*;
                    value.* = .{ .cast = .{ .inner = inner, .annotation = "number[]", .checked_type = .f64_array, .int_array_to_float = true } };
                    return;
                }
                if (!types.same(expected, actual_type)) return self.failTypeMismatch(line, col, expected, actual_type);
                return;
            }
            const elem_type = types.arrayElem(expected) orelse return self.fail(line, col, "E_TYPE_MISMATCH");
            var has_spread = false;
            for (value.array.items) |item| {
                if (item.* == .spread) {
                    has_spread = true;
                    // A `...set` / `...str` spread contributes its elements; rewrite
                    // it to `...Array.from(x)` so it flows through the array path,
                    // matching the inference side (spec 397/414).
                    const src_type = self.exprType(program, item.spread, line, col) orelse return self.inferenceFail(line, col, "E_TYPE_MISMATCH");
                    if (src_type == .set_type or types.isStringLike(src_type)) {
                        const from_call = self.arena.create(ast.Expr) catch return error.OutOfMemory;
                        const from_args = self.arena.alloc(*ast.Expr, 1) catch return error.OutOfMemory;
                        from_args[0] = item.spread;
                        from_call.* = .{ .static_call = .{ .namespace = "Array", .name = "from", .args = from_args } };
                        item.spread = from_call;
                    }
                    // `...src` must itself be an array of the same element type.
                    try self.ensureAssignable(program, expected, item.spread, line, col);
                } else {
                    try self.ensureAssignable(program, elem_type, item, line, col);
                }
            }
            if (has_spread) value.array.elem_type = elem_type else value.array.heap_elem = elem_type;
        },
        .tuple_type => |elems| {
            // A tuple is written as an array literal of matching length whose
            // elements satisfy each position's declared type. Rewrite the
            // `.array` node into a `.tuple_lit` carrying the tuple type so the
            // emitter produces a positional struct rather than a slice.
            const items = switch (value.*) {
                .array => |a| a.items,
                .tuple_lit => |t| t.items,
                else => {
                    const actual_type = self.exprType(program, value, line, col) orelse return self.inferenceFail(line, col, "E_TYPE_MISMATCH");
                    if (!types.same(expected, actual_type)) return self.failTypeMismatch(line, col, expected, actual_type);
                    return;
                },
            };
            if (items.len != elems.len) return self.fail(line, col, "E_TYPE_MISMATCH");
            for (items, elems) |item, et| {
                try self.ensureAssignable(program, et, item, line, col);
            }
            value.* = .{ .tuple_lit = .{ .items = items, .tuple_type = expected } };
        },
        .i64 => {
            // A bare integer literal (`const x: i64 = 5;`) carries a real
            // i64 value in the AST already (Expr.num is i64, not i32), but
            // its *inferred* type without this context defaults to i32 --
            // so the generic path below would reject it as a mismatch.
            // Found while reviewing spec 050's new i64-returning functions
            // (process.hrtime()/memoryUsage()): those values couldn't even
            // be compared against a literal (`mem.rss > 0` failed to
            // compile) without this. Only bare literals get this pass --
            // an i32-*typed variable* still can't implicitly narrow/widen
            // into an i64 slot, matching every other integer width here.
            if (value.* == .num) return;
            const actual_type = self.exprType(program, value, line, col) orelse return self.inferenceFail(line, col, "E_TYPE_MISMATCH");
            // Lossless widening (spec 258): an i32 value flows into an i64
            // slot as-is (the emitted Zig coerces smaller ints implicitly).
            if (actual_type == .i32) return;
            if (!types.same(expected, actual_type)) return self.failTypeMismatch(line, col, expected, actual_type);
        },
        .f64 => {
            // Same gap as .i64 above, hit by the same review pass:
            // `process.uptime() >= 0` (a bare int literal against an f64
            // value) failed for the identical reason. A bare integer
            // literal is comptime_int at the Zig emit layer, which Zig
            // itself coerces to f64 without any extra cast needed here --
            // this is purely a checker-side gap, not an emit-side one.
            if (value.* == .num) return;
            const actual_type = self.exprType(program, value, line, col) orelse return self.inferenceFail(line, col, "E_TYPE_MISMATCH");
            // JS-style numeric promotion (spec 255/256): an integer value —
            // or a numeric enum, whose backing value is an integer (spec 294) —
            // flows into an f64 slot through the runtime Number() conversion.
            if (types.isInteger(actual_type) or (actual_type == .enum_type and !actual_type.enum_type.is_string)) {
                const inner = self.arena.create(ast.Expr) catch return error.OutOfMemory;
                inner.* = value.*;
                const args = self.arena.alloc(*ast.Expr, 1) catch return error.OutOfMemory;
                args[0] = inner;
                value.* = .{ .call = .{ .name = "Number", .args = args, .is_global_parse = true } };
                return;
            }
            if (!types.same(expected, actual_type)) return self.failTypeMismatch(line, col, expected, actual_type);
        },
        .func_type => |fsig| {
            // An untyped arrow argument to a function-typed parameter borrows the
            // parameter's declared parameter types as contextual hints, so
            // `apply(x => x * 2, ...)` infers `x: i32` from `f: (x: i32) => i32`.
            // A typed arrow / named function value flows through the plain check.
            if (value.* == .arrow) {
                const actual = self.checkCbArg(program, value, fsig.params, line, col) orelse
                    return self.fail(line, col, "E_TYPE_MISMATCH");
                if (!types.same(expected, actual)) return self.fail(line, col, "E_TYPE_MISMATCH");
                return;
            }
            const actual_type = self.exprType(program, value, line, col) orelse return self.inferenceFail(line, col, "E_TYPE_MISMATCH");
            if (!types.same(expected, actual_type)) return self.failTypeMismatch(line, col, expected, actual_type);
        },
        .iface_type => |iface_name| {
            const actual_type = self.exprType(program, value, line, col) orelse return self.inferenceFail(line, col, "E_TYPE_MISMATCH");
            // Same interface flows through directly.
            if (actual_type == .iface_type and std.mem.eql(u8, actual_type.iface_type, iface_name)) return;
            // A class instance implementing the interface coerces into its fat
            // pointer: wrap it in an `iface_class` cast the emitter lowers to a
            // `{ __ptr, __vt }` value (spec 428).
            if (actual_type == .class_type and check_mod.classImplements(self, actual_type.class_type, iface_name)) {
                const inner = self.arena.create(ast.Expr) catch return error.OutOfMemory;
                inner.* = value.*;
                value.* = .{ .cast = .{ .inner = inner, .annotation = iface_name, .checked_type = expected, .iface_class = actual_type.class_type } };
                return;
            }
            return self.failTypeMismatch(line, col, expected, actual_type);
        },
        else => {
            const actual_type = self.exprType(program, value, line, col) orelse return self.inferenceFail(line, col, "E_TYPE_MISMATCH");
            // An enum member assigns to its backing type (spec 294): a numeric
            // enum to `i32`, a string enum to `string` — the enum lowers to
            // exactly that value at runtime.
            if (actual_type == .enum_type) {
                if (expected == .i32 and !actual_type.enum_type.is_string) return;
                if (expected == .string and actual_type.enum_type.is_string) return;
            }
            // A string-literal union (incl. `keyof P`) widens to `string`; both
            // erase to the same runtime representation.
            if (expected == .string and actual_type == .string_literal_union) return;
            if (!types.same(expected, actual_type)) return self.failTypeMismatch(line, col, expected, actual_type);
        },
    }
}

/// Whether `expr as T` is in the safe, representation-preserving subset: the
/// assertion is erased to the operand, so source and target must share the
/// same emitted layout. This covers identity, alias <-> underlying type, and
/// literal-union widening (`"a" | "b"` -> string, `1 | 2` -> int).
pub fn castAllowed(self: *Checker, source: types.Type, target: types.Type) bool {
    if (types.same(source, target)) return true;
    // A string-literal-union value may be asserted to/from string.
    if (source == .string_literal_union and target == .string) return true;
    if (source == .string and target == .string_literal_union) return true;
    if (source == .int_literal_union and target == .i32) return true;
    if (source == .i32 and target == .int_literal_union) return true;
    // Otherwise require an identical emitted layout so erasure stays sound.
    const sn = types.zigName(self.arena, source) catch return false;
    const tn = types.zigName(self.arena, target) catch return false;
    return std.mem.eql(u8, sn, tn);
}
