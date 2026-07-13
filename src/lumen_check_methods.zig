//! Type-checking for stdlib *instance* methods: methods called on a value of
//! a builtin type -- arrays (`.map`, `.filter`, `.push`...), Maps/Sets,
//! strings, Buffers, sockets, streams, EventEmitters, numbers, and crypto
//! Hash/Hmac objects. Split out of `lumen_check_stdlib.zig` purely by size;
//! the static-namespace calls (`fs.*`, `Math.*`, ...) stay there.
//!
//! Same convention as `lumen_check_stdlib.zig`: each function is a `Checker`
//! method physically defined here (explicit `self: *Checker` first parameter)
//! and aliased back onto the `Checker` type in `lumen_check.zig`, relying on
//! Zig's support for circular *references* between files.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const types = @import("lumen_types.zig");
const check_mod = @import("lumen_check.zig");

const Checker = check_mod.Checker;

pub fn cbParamsMatch(params: []const types.Type, elem: types.Type) bool {
    if (params.len == 1) return types.same(params[0], elem);
    if (params.len == 2) return types.same(params[0], elem) and types.isInteger(params[1]);
    return false;
}

pub fn arrayMethod(self: *Checker, program: *ast.Program, mc: anytype, obj_type: types.Type, line: u32, col: u32) ?types.Type {
    const elem = types.arrayElem(obj_type) orelse {
        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
        return null;
    };
    mc.array_elem_type = elem;
    const name = mc.name;
    const eq = std.mem.eql;

    // Methods taking a `(T) => bool` or `(T, int) => bool` predicate; the
    // optional second parameter is the element index.
    if (eq(u8, name, "filter") or eq(u8, name, "find") or eq(u8, name, "some") or eq(u8, name, "every")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const cb_type = self.checkCbArg(program, mc.args[0], &.{ elem, .i32 }, line, col) orelse return null;
        if (cb_type != .func_type or !cbParamsMatch(cb_type.func_type.params, elem) or !types.same(cb_type.func_type.ret.*, .bool)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        mc.cb_wants_index = cb_type.func_type.params.len == 2;
        if (eq(u8, name, "some") or eq(u8, name, "every")) {
            mc.array_result_type = .bool;
            return .bool;
        }
        if (eq(u8, name, "filter")) {
            mc.array_result_type = obj_type;
            return obj_type;
        }
        // find -> T | null
        const inner = self.arena.create(types.Type) catch return null;
        inner.* = elem;
        const res = types.Type{ .optional = inner };
        mc.array_result_type = res;
        return res;
    }

    // map((T) => U): U[] or map((T, int) => U): U[]  — the optional second
    // callback parameter is the element index; result element type is the
    // callback return type.
    if (eq(u8, name, "map")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const cb_type = self.checkCbArg(program, mc.args[0], &.{ elem, .i32 }, line, col) orelse return null;
        if (cb_type != .func_type or !cbParamsMatch(cb_type.func_type.params, elem)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        mc.cb_wants_index = cb_type.func_type.params.len == 2;
        const u = cb_type.func_type.ret.*;
        const res = (types.arrayOfAlloc(self.arena, u) catch return null) orelse {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        mc.array_result_type = res;
        return res;
    }

    // flat(): T[] on a T[][] — concatenate the inner arrays into one (spec 301).
    if (eq(u8, name, "flat")) {
        if (mc.args.len != 0) {
            _ = self.fail(line, col, "'flat' expects no arguments (one level of flattening)") catch {};
            return null;
        }
        if (!types.isArray(elem)) {
            const tn = types.tsName(self.arena, obj_type) catch "?";
            const msg = std.fmt.allocPrint(self.arena, "`.flat()` needs an array of arrays, got `{s}`", .{tn}) catch "E_TYPE_MISMATCH";
            _ = self.fail(line, col, msg) catch {};
            return null;
        }
        mc.array_result_type = elem;
        mc.array_elem_type = elem;
        return elem;
    }

    // flatMap((T) => U[]): U[] — the callback returns an array per element; the
    // results are concatenated into one flat array. The optional second callback
    // parameter is the element index.
    if (eq(u8, name, "flatMap")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const cb_type = self.checkCbArg(program, mc.args[0], &.{ elem, .i32 }, line, col) orelse return null;
        if (cb_type != .func_type or !cbParamsMatch(cb_type.func_type.params, elem)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        // The callback must return an array; the result element type is that
        // array's element type (a flat U[], never a nested array).
        const ret = cb_type.func_type.ret.*;
        if (!types.isArray(ret)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        mc.cb_wants_index = cb_type.func_type.params.len == 2;
        mc.array_result_type = ret;
        return ret;
    }

    // forEach((T) => void): void or forEach((T, int) => void): void
    if (eq(u8, name, "forEach")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const cb_type = self.checkCbArg(program, mc.args[0], &.{ elem, .i32 }, line, col) orelse return null;
        if (cb_type != .func_type or !cbParamsMatch(cb_type.func_type.params, elem)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        mc.cb_wants_index = cb_type.func_type.params.len == 2;
        mc.array_result_type = .void;
        return .void;
    }

    // reduce / reduceRight ((U, T) => U or (U, T, int) => U, init: U): U — init
    // fixes the accumulator type; the optional third callback parameter is the
    // element index. reduceRight folds from the end. With no init argument the
    // accumulator type is the element type and the first element seeds the fold.
    if (eq(u8, name, "reduce") or eq(u8, name, "reduceRight")) {
        if (mc.args.len != 1 and mc.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        // The accumulator type: from the seed (arg 1) normally, but a seed that
        // is a bare object literal can't self-infer — take the accumulator type
        // from the annotated callback's first parameter and check the seed
        // against it (spec 299).
        const acc = blk_acc: {
            if (mc.args.len != 2) break :blk_acc elem;
            if (mc.args[1].* == .obj and mc.args[0].* == .arrow and mc.args[0].arrow.params.len >= 1 and mc.args[0].arrow.params[0].annotation.len > 0) {
                const at = self.typeFromAnnotation(mc.args[0].arrow.params[0].annotation, line, col) catch break :blk_acc (self.exprType(program, mc.args[1], line, col) orelse return null);
                self.ensureAssignable(program, at, mc.args[1], line, col) catch return null;
                break :blk_acc at;
            }
            // A bare integer-literal seed (`reduce(..., 0)`) over an f64/i64
            // array should fold at the element's width, matching JS where every
            // numeric literal is `number`. Widen the seed to the element type so
            // the accumulator and callback return line up (spec 394).
            if (mc.args[1].* == .num and (elem == .f64 or elem == .i64)) {
                self.ensureAssignable(program, elem, mc.args[1], line, col) catch return null;
                break :blk_acc elem;
            }
            break :blk_acc (self.exprType(program, mc.args[1], line, col) orelse return null);
        };
        var acc_ty = acc;
        // The callback returns the accumulator type; hint it so an object/array
        // literal body (`(a, x) => ({ ...a })`) types against it.
        self.arrow_return_hint = acc_ty;
        var cb_type_opt = self.checkCbArg(program, mc.args[0], &.{ acc_ty, elem, .i32 }, line, col);
        self.arrow_return_hint = null;
        var cb_type = cb_type_opt orelse return null;
        // An integer-literal seed whose body actually folds at a wider numeric
        // type (e.g. `acc + tuple[1]` where the tuple field is `f64`): re-fold
        // with the accumulator widened to the callback's return type (spec 419).
        if (cb_type == .func_type and mc.args.len == 2 and mc.args[1].* == .num and
            acc_ty == .i32 and (cb_type.func_type.ret.* == .f64 or cb_type.func_type.ret.* == .i64))
        {
            const wider = cb_type.func_type.ret.*;
            self.ensureAssignable(program, wider, mc.args[1], line, col) catch return null;
            acc_ty = wider;
            self.arrow_return_hint = acc_ty;
            cb_type_opt = self.checkCbArg(program, mc.args[0], &.{ acc_ty, elem, .i32 }, line, col);
            self.arrow_return_hint = null;
            cb_type = cb_type_opt orelse return null;
        }
        const p = if (cb_type == .func_type) cb_type.func_type.params else &[_]types.Type{};
        const shape_ok = (p.len == 2 or p.len == 3) and
            types.same(p[0], acc_ty) and types.same(p[1], elem) and
            (p.len == 2 or types.isInteger(p[2]));
        if (cb_type != .func_type or !shape_ok or !types.same(cb_type.func_type.ret.*, acc_ty)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        mc.cb_wants_index = p.len == 3;
        mc.array_acc_type = acc_ty;
        mc.array_result_type = acc_ty;
        return acc_ty;
    }

    // findIndex((T) => bool): int  — first matching index, or -1.
    if (eq(u8, name, "findIndex")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const cb_type = self.checkCbArg(program, mc.args[0], &.{ elem, .i32 }, line, col) orelse return null;
        if (cb_type != .func_type or !cbParamsMatch(cb_type.func_type.params, elem) or !types.same(cb_type.func_type.ret.*, .bool)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        mc.cb_wants_index = cb_type.func_type.params.len == 2;
        mc.array_result_type = .i32;
        return .i32;
    }

    // findLast(pred): T | null  /  findLastIndex(pred): int — like find /
    // findIndex but scanning for the LAST match. Same optional-index predicate.
    if (eq(u8, name, "findLast") or eq(u8, name, "findLastIndex")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const cb_type = self.checkCbArg(program, mc.args[0], &.{ elem, .i32 }, line, col) orelse return null;
        if (cb_type != .func_type or !cbParamsMatch(cb_type.func_type.params, elem) or !types.same(cb_type.func_type.ret.*, .bool)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        mc.cb_wants_index = cb_type.func_type.params.len == 2;
        if (eq(u8, name, "findLastIndex")) {
            mc.array_result_type = .i32;
            return .i32;
        }
        const inner = self.arena.create(types.Type) catch return null;
        inner.* = elem;
        const res = types.Type{ .optional = inner };
        mc.array_result_type = res;
        return res;
    }

    // indexOf(x, from?) / includes(x, from?) / lastIndexOf(x, from?): each takes
    // an optional integer start index (for lastIndexOf, the backward-search
    // upper bound).
    if (eq(u8, name, "indexOf") or eq(u8, name, "lastIndexOf") or eq(u8, name, "includes")) {
        if (mc.args.len < 1 or mc.args.len > 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        self.ensureAssignable(program, elem, mc.args[0], line, col) catch {
            return null;
        };
        if (mc.args.len == 2) {
            const ft = self.exprType(program, mc.args[1], line, col) orelse return null;
            if (!types.isInteger(ft)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        const res: types.Type = if (eq(u8, name, "includes")) .bool else .i32;
        mc.array_result_type = res;
        return res;
    }

    // at(i: int): T | null  — element at i (negative counts from the end),
    // or null when out of range. Optional result, like find.
    if (eq(u8, name, "at")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const at = self.exprType(program, mc.args[0], line, col) orelse return null;
        if (!types.isInteger(at)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        const inner = self.arena.create(types.Type) catch return null;
        inner.* = elem;
        const res = types.Type{ .optional = inner };
        mc.array_result_type = res;
        return res;
    }

    // copyWithin(target: int, start?: int, end?: int): T[]  — a copy with the
    // block [start, end) copied to position target (immutable; new array).
    if (eq(u8, name, "copyWithin")) {
        if (mc.args.len < 1 or mc.args.len > 3) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        for (mc.args) |arg| {
            const at = self.exprType(program, arg, line, col) orelse return null;
            if (!types.isInteger(at)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        mc.array_result_type = obj_type;
        return obj_type;
    }

    // fill(value: T, start?: int, end?: int): T[]  — a copy with [start, end)
    // set to value (immutable; returns a new array). JS range semantics.
    if (eq(u8, name, "fill")) {
        if (mc.args.len < 1 or mc.args.len > 3) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        self.ensureAssignable(program, elem, mc.args[0], line, col) catch {
            return null;
        };
        for (mc.args[1..]) |arg| {
            const at = self.exprType(program, arg, line, col) orelse return null;
            if (!types.isInteger(at)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        mc.array_result_type = obj_type;
        return obj_type;
    }

    // with(i: int, value: T): T[]  — a copy with index i replaced (immutable
    // update). Negative i counts from the end; out of range leaves the copy
    // unchanged (rather than trapping).
    if (eq(u8, name, "with")) {
        if (mc.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const it = self.exprType(program, mc.args[0], line, col) orelse return null;
        if (!types.isInteger(it)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        self.ensureAssignable(program, elem, mc.args[1], line, col) catch {
            return null;
        };
        mc.array_result_type = obj_type;
        return obj_type;
    }

    // concat(other: T[]): T[]  — a new array, both sources untouched.
    if (eq(u8, name, "concat")) {
        // Variadic: each argument is another array of the same element type.
        if (mc.args.len < 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        for (mc.args) |arg| {
            self.ensureAssignable(program, obj_type, arg, line, col) catch {
                return null;
            };
        }
        mc.array_result_type = obj_type;
        return obj_type;
    }

    // sort/toSorted((a: T, b: T) => int): T[]  — a new array ordered by the
    // comparator (negative => a before b), source untouched. Stable. Both names
    // are equivalent here since Lumen arrays are immutable.
    if (eq(u8, name, "sort") or eq(u8, name, "toSorted")) {
        // No comparator: default ascending order (numeric for numbers,
        // lexicographic for strings).
        if (mc.args.len == 0) {
            if (!types.isNumeric(elem) and !types.isStringLike(elem)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
            mc.array_result_type = obj_type;
            return obj_type;
        }
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        // The comparator returns any number (only its sign matters), so accept
        // an `i32`/`i64`/`f64` return — `(a, b) => a.x - b.x` over `number`
        // fields yields `f64`, which JS treats identically.
        const cb_type = self.checkCbArg(program, mc.args[0], &.{ elem, elem }, line, col) orelse return null;
        const cp = if (cb_type == .func_type) cb_type.func_type.params else &[_]types.Type{};
        if (cb_type != .func_type or cp.len != 2 or !types.same(cp[0], elem) or !types.same(cp[1], elem) or !types.isNumeric(cb_type.func_type.ret.*)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        mc.array_result_type = obj_type;
        return obj_type;
    }

    // reverse/toReversed(): T[]  — a new array, source untouched.
    if (eq(u8, name, "reverse") or eq(u8, name, "toReversed")) {
        if (mc.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        mc.array_result_type = obj_type;
        return obj_type;
    }

    // slice(start: int, end?: int): T[]  — clamped like string slice, no
    // negative-from-end indexing (consistent with spec 014).
    if (eq(u8, name, "slice")) {
        if (mc.args.len > 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        for (mc.args) |arg| {
            const at = self.exprType(program, arg, line, col) orelse return null;
            if (!types.isInteger(at)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        mc.array_result_type = obj_type;
        return obj_type;
    }

    // toString(): string -- comma-joined, identical to `join()`.
    if (eq(u8, name, "toString")) {
        if (mc.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        mc.array_result_type = .string;
        return .string;
    }

    // join(sep?: string): string
    if (eq(u8, name, "join")) {
        if (mc.args.len > 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        if (mc.args.len == 1) {
            self.ensureAssignable(program, .string, mc.args[0], line, col) catch {
                return null;
            };
        }
        mc.array_result_type = .string;
        return .string;
    }

    // The classic JS mutators are excluded by design (arrays are immutable);
    // point at the immutable alternative instead of a generic unknown-method.
    const mutator_hint: ?[]const u8 = blk: {
        if (eq(u8, mc.name, "push")) break :blk "arrays are immutable — use `a = [...a, x]` or `a.concat([x])`";
        if (eq(u8, mc.name, "pop")) break :blk "arrays are immutable — use `a[a.length - 1]` then `a.slice(0, -1)`";
        if (eq(u8, mc.name, "shift")) break :blk "arrays are immutable — use `a[0]` then `a.slice(1)`";
        if (eq(u8, mc.name, "unshift")) break :blk "arrays are immutable — use `a = [x, ...a]`";
        if (eq(u8, mc.name, "splice")) break :blk "arrays are immutable — use `slice`/`concat`/`with` to build a new array";
        break :blk null;
    };
    if (mutator_hint) |hint| {
        const msg = std.fmt.allocPrint(self.arena, "`array.{s}` is not supported: {s}", .{ mc.name, hint }) catch "unsupported array mutator";
        _ = self.fail(line, col, msg) catch {};
        return null;
    }
    _ = self.failUnknownMethod(line, col, "array", mc.name, &.{ "map", "filter", "find", "findIndex", "findLast", "findLastIndex", "forEach", "some", "every", "reduce", "reduceRight", "flat", "flatMap", "includes", "indexOf", "lastIndexOf", "join", "toString", "slice", "concat", "reverse", "sort", "toSorted", "at", "fill", "with", "copyWithin", "entries", "keys", "values" }) catch {};
    return null;
}

/// Validate a method call on a `Map<K,V>` receiver and return its result type.
pub fn mapMethod(self: *Checker, program: *ast.Program, mc: anytype, obj_type: types.Type, line: u32, col: u32) ?types.Type {
    mc.container_type = obj_type;
    const key = obj_type.map_type.key.*;
    const value = obj_type.map_type.value.*;
    const name = mc.name;
    const eq = std.mem.eql;

    if (eq(u8, name, "clear")) {
        if (mc.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        return .void;
    }
    if (eq(u8, name, "set")) {
        if (mc.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        self.ensureAssignable(program, key, mc.args[0], line, col) catch {
            return null;
        };
        self.ensureAssignable(program, value, mc.args[1], line, col) catch {
            return null;
        };
        return .void;
    }
    if (eq(u8, name, "get")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        self.ensureAssignable(program, key, mc.args[0], line, col) catch {
            return null;
        };
        const inner = self.arena.create(types.Type) catch return null;
        inner.* = value;
        return .{ .optional = inner };
    }
    if (eq(u8, name, "has") or eq(u8, name, "delete")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        self.ensureAssignable(program, key, mc.args[0], line, col) catch {
            return null;
        };
        return .bool;
    }
    if (eq(u8, name, "keys")) {
        if (mc.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        return types.arrayOf(key) orelse {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
    }
    if (eq(u8, name, "values")) {
        if (mc.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        return types.arrayOf(value) orelse {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
    }
    if (eq(u8, name, "forEach")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        // The callback may take just the value (`(v) => ...`) or the value and
        // key (`(v, k) => ...`), matching JS `Map.forEach`.
        const cb_type = self.checkCbArg(program, mc.args[0], &.{ value, key }, line, col) orelse return null;
        if (cb_type != .func_type or cb_type.func_type.params.len < 1 or cb_type.func_type.params.len > 2 or
            !types.same(cb_type.func_type.params[0], value) or
            (cb_type.func_type.params.len == 2 and !types.same(cb_type.func_type.params[1], key)))
        {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        return .void;
    }
    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
    return null;
}

/// Validate a method call on a `Set<T>` receiver and return its result type.
pub fn setMethod(self: *Checker, program: *ast.Program, mc: anytype, obj_type: types.Type, line: u32, col: u32) ?types.Type {
    mc.container_type = obj_type;
    const elem = obj_type.set_type.*;
    const name = mc.name;
    const eq = std.mem.eql;

    if (eq(u8, name, "clear")) {
        if (mc.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        return .void;
    }
    if (eq(u8, name, "add")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        self.ensureAssignable(program, elem, mc.args[0], line, col) catch {
            return null;
        };
        return .void;
    }
    if (eq(u8, name, "has") or eq(u8, name, "delete")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        self.ensureAssignable(program, elem, mc.args[0], line, col) catch {
            return null;
        };
        return .bool;
    }
    // values() / keys() -- in a Set both yield the elements in insertion order.
    if (eq(u8, name, "values") or eq(u8, name, "keys")) {
        if (mc.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        return types.arrayOf(elem) orelse {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
    }
    if (eq(u8, name, "forEach")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const want = self.makeFuncType(&.{elem}, .void) orelse return null;
        self.arrow_param_hint = &.{elem};
        self.ensureAssignable(program, want, mc.args[0], line, col) catch {
            self.arrow_param_hint = null;
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        self.arrow_param_hint = null;
        return .void;
    }
    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
    return null;
}

/// Validate a method call on an `EventEmitter<T>` receiver and return its
/// statically-known result type. Mirrors `mapMethod`/`setMethod`. Every
/// event name on one instance shares the same payload type T -- see
/// spec 043 for why (Lumen has no way to express "this string key selects
/// this listener signature" the way Node's untyped EventEmitter does).
pub fn eventEmitterMethod(self: *Checker, program: *ast.Program, mc: anytype, obj_type: types.Type, line: u32, col: u32) ?types.Type {
    mc.container_type = obj_type;
    const payload = obj_type.event_emitter_type.*;
    const name = mc.name;
    const eq = std.mem.eql;

    if (eq(u8, name, "on") or eq(u8, name, "once")) {
        if (mc.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const name_type = self.exprType(program, mc.args[0], line, col) orelse return null;
        if (!types.same(.string, name_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        const want = self.makeFuncType(&.{payload}, .void) orelse return null;
        self.ensureAssignable(program, want, mc.args[1], line, col) catch {
            return null;
        };
        return .void;
    }
    if (eq(u8, name, "emit")) {
        if (mc.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const name_type = self.exprType(program, mc.args[0], line, col) orelse return null;
        if (!types.same(.string, name_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        self.ensureAssignable(program, payload, mc.args[1], line, col) catch {
            return null;
        };
        return .void;
    }
    if (eq(u8, name, "removeAllListeners")) {
        if (mc.args.len > 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        // Zig has no default-parameter overloading, so the 0-arg ("clear
        // everything") and 1-arg ("clear one name") forms need distinct
        // runtime method names -- routed here, the same renaming trick
        // `assert.equal` uses to route to a distinct string-comparison
        // function.
        if (mc.args.len == 1) {
            const name_type = self.exprType(program, mc.args[0], line, col) orelse return null;
            if (!types.same(.string, name_type)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
            mc.name = "removeListenersFor";
        }
        return .void;
    }
    if (eq(u8, name, "listenerCount")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const name_type = self.exprType(program, mc.args[0], line, col) orelse return null;
        if (!types.same(.string, name_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        return .i32;
    }
    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
    return null;
}

/// Validate a method call on a `ReadableStream` receiver (spec 046,
/// `fs.createReadStream`'s return type). Mirrors `mapMethod`/`setMethod`/
/// `eventEmitterMethod`.
pub fn readableStreamMethod(self: *Checker, program: *ast.Program, mc: anytype, obj_type: types.Type, line: u32, col: u32) ?types.Type {
    _ = program;
    mc.container_type = obj_type;
    const name = mc.name;
    const eq = std.mem.eql;

    if (eq(u8, name, "read")) {
        if (mc.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        return .string;
    }
    // readLine() (spec 053): line-oriented convenience over the same
    // reader every ReadableStream already owns -- see spec 053's "Line
    // reading" section for why this shape (not an event-based
    // readline.createInterface) was chosen.
    if (eq(u8, name, "readLine")) {
        if (mc.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        return .string;
    }
    if (eq(u8, name, "close")) {
        if (mc.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        return .void;
    }
    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
    return null;
}

/// Validate a method call on a `WritableStream` receiver (spec 046,
/// `fs.createWriteStream`'s return type). Mirrors `readableStreamMethod`.
pub fn writableStreamMethod(self: *Checker, program: *ast.Program, mc: anytype, obj_type: types.Type, line: u32, col: u32) ?types.Type {
    mc.container_type = obj_type;
    const name = mc.name;
    const eq = std.mem.eql;

    if (eq(u8, name, "write")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const chunk_type = self.exprType(program, mc.args[0], line, col) orelse return null;
        if (!types.same(.string, chunk_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        return .void;
    }
    if (eq(u8, name, "close")) {
        if (mc.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        return .void;
    }
    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
    return null;
}

/// Validate a method call on a `Socket` receiver (spec 054, `net.connect`'s
/// return type and `net.createServer`'s handler argument type). Mirrors
/// `writableStreamMethod` almost exactly (a socket is also a byte-chunk
/// reader/writer), plus `close()`.
pub fn socketMethod(self: *Checker, program: *ast.Program, mc: anytype, obj_type: types.Type, line: u32, col: u32) ?types.Type {
    mc.container_type = obj_type;
    const name = mc.name;
    const eq = std.mem.eql;

    if (eq(u8, name, "read")) {
        if (mc.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        return .string;
    }
    if (eq(u8, name, "write")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const chunk_type = self.exprType(program, mc.args[0], line, col) orelse return null;
        if (!types.same(.string, chunk_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        return .void;
    }
    if (eq(u8, name, "close")) {
        if (mc.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        return .void;
    }
    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
    return null;
}

/// Validate a method call on a `Buffer` receiver (spec 056). Mirrors
/// `readableStreamMethod`/`writableStreamMethod`.
pub fn bufferMethod(self: *Checker, program: *ast.Program, mc: anytype, obj_type: types.Type, line: u32, col: u32) ?types.Type {
    mc.container_type = obj_type;
    const name = mc.name;
    const eq = std.mem.eql;

    if (eq(u8, name, "toString")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        self.ensureAssignable(program, .string, mc.args[0], line, col) catch {
            return null;
        };
        return .string;
    }
    if (eq(u8, name, "at")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const at = self.exprType(program, mc.args[0], line, col) orelse return null;
        if (!types.isInteger(at)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        return .i32;
    }
    if (eq(u8, name, "slice")) {
        if (mc.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        for (mc.args) |arg| {
            const at = self.exprType(program, arg, line, col) orelse return null;
            if (!types.isInteger(at)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        return .buffer_type;
    }
    if (eq(u8, name, "equals")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        self.ensureAssignable(program, .buffer_type, mc.args[0], line, col) catch {
            return null;
        };
        return .bool;
    }
    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
    return null;
}

/// Validate an instance method call on a numeric receiver (int/f64).
/// Currently: `toFixed(digits: int): string`.
pub fn numberInstanceMethod(self: *Checker, program: *ast.Program, mc: anytype, obj_type: types.Type, line: u32, col: u32) ?types.Type {
    mc.number_method = true;
    mc.array_elem_type = obj_type; // receiver numeric type, for emit coercion
    const name = mc.name;
    if (std.mem.eql(u8, name, "toFixed")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const at = self.exprType(program, mc.args[0], line, col) orelse return null;
        if (!types.isInteger(at)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        return .string;
    }
    // toExponential(digits?): exponential notation, optional fraction digits.
    if (std.mem.eql(u8, name, "toExponential")) {
        if (mc.args.len > 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        if (mc.args.len == 1) {
            const dt = self.exprType(program, mc.args[0], line, col) orelse return null;
            if (!types.isInteger(dt)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        return .string;
    }
    // toPrecision(digits): the number formatted to `digits` significant digits.
    if (std.mem.eql(u8, name, "toPrecision")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const dt = self.exprType(program, mc.args[0], line, col) orelse return null;
        if (!types.isInteger(dt)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.needs_to_precision = true;
        return .string;
    }
    // toString(radix?): base-10 decimal for any number; with a radix, the
    // receiver must be an integer (arbitrary-base int formatting).
    if (std.mem.eql(u8, name, "toString")) {
        if (mc.args.len > 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        if (mc.args.len == 1) {
            const rt = self.exprType(program, mc.args[0], line, col) orelse return null;
            if (!types.isInteger(rt) or !types.isInteger(obj_type)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        return .string;
    }
    {
        const tn = types.tsName(self.arena, obj_type) catch "number";
        _ = self.failUnknownMethod(line, col, tn, name, &.{ "toFixed", "toPrecision", "toExponential", "toString" }) catch {};
    }
    return null;
}

/// Validate an instance method call on a `string` receiver and return its
/// statically-known result type. Mirrors `arrayMethod`.
pub fn stringMethod(self: *Checker, program: *ast.Program, mc: anytype, line: u32, col: u32) ?types.Type {
    mc.string_method = true;
    const name = mc.name;
    const eq = std.mem.eql;

    // replace(pattern: RegExp, repl: string): string -- the regex form. The
    // string-pattern form is handled by the fixed-arity spec table below.
    if ((eq(u8, name, "replace") or eq(u8, name, "replaceAll")) and mc.args.len == 2) {
        const p0 = self.exprType(program, mc.args[0], line, col) orelse return null;
        if (p0 == .regexp) {
            self.ensureAssignable(program, .string, mc.args[1], line, col) catch {
                return null;
            };
            mc.regex_arg = true;
            program.uses_regex = true;
            mc.array_result_type = .string;
            return .string;
        }
    }

    // search(pattern: RegExp): int -- the index of the first match, or -1.
    if (eq(u8, name, "search") and mc.args.len == 1) {
        const p0 = self.exprType(program, mc.args[0], line, col) orelse return null;
        if (p0 == .regexp) {
            mc.regex_arg = true;
            program.uses_regex = true;
            mc.array_result_type = .i32;
            return .i32;
        }
    }

    // match(pattern: RegExp): string[] | null -- element 0 is the first match's
    // full text, or null when the pattern doesn't match. Capture groups are not
    // populated in V1 (the regex runtime tracks match spans, not group spans).
    if (eq(u8, name, "match") and mc.args.len == 1) {
        const p0 = self.exprType(program, mc.args[0], line, col) orelse return null;
        if (p0 == .regexp) {
            mc.regex_arg = true;
            program.uses_regex = true;
            const inner = self.arena.create(types.Type) catch return null;
            inner.* = types.arrayOf(.string).?;
            const rt = types.Type{ .optional = inner };
            mc.array_result_type = rt;
            return rt;
        }
    }

    // split(separator: RegExp): string[] -- the regex form. The string-separator
    // form is handled by the fixed-arity spec table below.
    if (eq(u8, name, "split") and mc.args.len == 1) {
        const p0 = self.exprType(program, mc.args[0], line, col) orelse return null;
        if (p0 == .regexp) {
            mc.regex_arg = true;
            program.uses_regex = true;
            const rt = types.arrayOf(.string).?;
            mc.array_result_type = rt;
            return rt;
        }
    }

    // concat(...strings): string -- variadic, doesn't fit the fixed-arity spec
    // table below, so validate it directly.
    if (eq(u8, name, "concat")) {
        if (mc.args.len < 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        for (mc.args) |arg| {
            self.ensureAssignable(program, .string, arg, line, col) catch {
                return null;
            };
        }
        mc.array_result_type = .string;
        return .string;
    }

    const ArgKind = enum { string, int };
    const Spec = struct { min: usize, max: usize, kinds: []const ArgKind, result: types.Type };

    // Each method's expected argument shape and result type.
    const spec: Spec = blk: {
        if (eq(u8, name, "charAt")) break :blk .{ .min = 1, .max = 1, .kinds = &.{.int}, .result = .string };
        if (eq(u8, name, "at")) break :blk .{ .min = 1, .max = 1, .kinds = &.{.int}, .result = .string };
        if (eq(u8, name, "charCodeAt")) break :blk .{ .min = 1, .max = 1, .kinds = &.{.int}, .result = .i32 };
        if (eq(u8, name, "codePointAt")) break :blk .{ .min = 1, .max = 1, .kinds = &.{.int}, .result = .i32 };
        if (eq(u8, name, "indexOf")) break :blk .{ .min = 1, .max = 2, .kinds = &.{ .string, .int }, .result = .i32 };
        if (eq(u8, name, "lastIndexOf")) break :blk .{ .min = 1, .max = 1, .kinds = &.{.string}, .result = .i32 };
        if (eq(u8, name, "localeCompare")) break :blk .{ .min = 1, .max = 1, .kinds = &.{.string}, .result = .i32 };
        if (eq(u8, name, "includes")) break :blk .{ .min = 1, .max = 2, .kinds = &.{ .string, .int }, .result = .bool };
        if (eq(u8, name, "startsWith")) break :blk .{ .min = 1, .max = 2, .kinds = &.{ .string, .int }, .result = .bool };
        if (eq(u8, name, "endsWith")) break :blk .{ .min = 1, .max = 2, .kinds = &.{ .string, .int }, .result = .bool };
        if (eq(u8, name, "slice")) break :blk .{ .min = 0, .max = 2, .kinds = &.{ .int, .int }, .result = .string };
        if (eq(u8, name, "substring")) break :blk .{ .min = 0, .max = 2, .kinds = &.{ .int, .int }, .result = .string };
        if (eq(u8, name, "repeat")) break :blk .{ .min = 1, .max = 1, .kinds = &.{.int}, .result = .string };
        if (eq(u8, name, "padStart")) break :blk .{ .min = 1, .max = 2, .kinds = &.{ .int, .string }, .result = .string };
        if (eq(u8, name, "padEnd")) break :blk .{ .min = 1, .max = 2, .kinds = &.{ .int, .string }, .result = .string };
        if (eq(u8, name, "replace")) break :blk .{ .min = 2, .max = 2, .kinds = &.{ .string, .string }, .result = .string };
        if (eq(u8, name, "replaceAll")) break :blk .{ .min = 2, .max = 2, .kinds = &.{ .string, .string }, .result = .string };
        if (eq(u8, name, "toUpperCase")) break :blk .{ .min = 0, .max = 0, .kinds = &.{}, .result = .string };
        if (eq(u8, name, "toLowerCase")) break :blk .{ .min = 0, .max = 0, .kinds = &.{}, .result = .string };
        if (eq(u8, name, "trim")) break :blk .{ .min = 0, .max = 0, .kinds = &.{}, .result = .string };
        if (eq(u8, name, "trimStart")) break :blk .{ .min = 0, .max = 0, .kinds = &.{}, .result = .string };
        if (eq(u8, name, "trimEnd")) break :blk .{ .min = 0, .max = 0, .kinds = &.{}, .result = .string };
        if (eq(u8, name, "split")) break :blk .{ .min = 0, .max = 2, .kinds = &.{ .string, .int }, .result = types.arrayOf(.string).? };
        _ = self.failUnknownMethod(line, col, "string", name, &.{ "charAt", "at", "charCodeAt", "codePointAt", "indexOf", "lastIndexOf", "localeCompare", "includes", "startsWith", "endsWith", "slice", "substring", "repeat", "padStart", "padEnd", "replace", "replaceAll", "toUpperCase", "toLowerCase", "trim", "trimStart", "trimEnd", "split", "concat", "search", "toString" }) catch {};
        return null;
    };

    if (mc.args.len < spec.min or mc.args.len > spec.max) {
        _ = self.fail(line, col, "E_ARG_COUNT") catch {};
        return null;
    }
    for (mc.args, 0..) |arg, i| {
        switch (spec.kinds[i]) {
            .string => self.ensureAssignable(program, .string, arg, line, col) catch {
                return null;
            },
            .int => {
                const at = self.exprType(program, arg, line, col) orelse return null;
                if (!types.isInteger(at)) {
                    // A `number` (f64) argument in an integer position — e.g.
                    // `s.repeat(n)` where `n: number` — truncates to an integer,
                    // matching JS/TS where these take `number` (spec 426).
                    if (at == .f64) {
                        const inner = self.arena.create(ast.Expr) catch return null;
                        inner.* = arg.*;
                        arg.* = .{ .cast = .{ .inner = inner, .annotation = "int", .checked_type = .i32, .float_to_int = true } };
                    } else {
                        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                        return null;
                    }
                }
            },
        }
    }
    // `str.at(i)` is `string | undefined` in JS/TS — out-of-range yields
    // undefined, so the result is optional (matching array `.at`). `charAt`
    // keeps returning `""` for out-of-range, so it stays a plain string.
    if (eq(u8, name, "at")) {
        const inner = self.arena.create(types.Type) catch return null;
        inner.* = .string;
        const res = types.Type{ .optional = inner };
        mc.array_result_type = res;
        return res;
    }
    mc.array_result_type = spec.result;
    return spec.result;
}


/// Validate a method call on a `Hash` receiver (spec 060): `crypto.
/// createHash(algorithm)`'s return type. Mirrors `bufferMethod`'s shape.
pub fn hashMethod(self: *Checker, program: *ast.Program, mc: anytype, obj_type: types.Type, line: u32, col: u32) ?types.Type {
    mc.container_type = obj_type;
    const name = mc.name;
    const eq = std.mem.eql;

    if (eq(u8, name, "update")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        self.ensureAssignable(program, .buffer_type, mc.args[0], line, col) catch {
            return null;
        };
        return .hash_type; // returns self, for chaining
    }
    if (eq(u8, name, "digest")) {
        if (mc.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.needs_buffer = true;
        return .buffer_type;
    }
    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
    return null;
}

/// Validate a method call on a `Hmac` receiver (spec 060): `crypto.
/// createHmac(algorithm, key)`'s return type. Mirrors `hashMethod`.
pub fn hmacMethod(self: *Checker, program: *ast.Program, mc: anytype, obj_type: types.Type, line: u32, col: u32) ?types.Type {
    mc.container_type = obj_type;
    const name = mc.name;
    const eq = std.mem.eql;

    if (eq(u8, name, "update")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        self.ensureAssignable(program, .buffer_type, mc.args[0], line, col) catch {
            return null;
        };
        return .hmac_type; // returns self, for chaining
    }
    if (eq(u8, name, "digest")) {
        if (mc.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.needs_buffer = true;
        return .buffer_type;
    }
    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
    return null;
}

