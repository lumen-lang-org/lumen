//! Type-checking for stdlib/builtin calls: `Math.*`, `String.*`, `Array.*`,
//! `fs.*`, `Promise.*` static namespace calls, plus instance methods on
//! arrays/Maps/Sets/strings (`.push`, `.get`, `.indexOf`, ...).
//!
//! Each function here validates a call's argument count and types, sets any
//! `program.needs_*`/`program.uses_io` flags the codegen prologue needs, fills
//! the resolved type onto the AST node (e.g. `call.checked_type`), and returns
//! the call's result `Type` (or `null` plus a diagnostic on error). This is
//! pulled out of `lumen_check.zig` because it grows independently of the rest
//! of the checker -- adding a new `fs.*Sync` function (see `fsCallType`) never
//! needs to touch scoping, narrowing, generics, or class resolution.
//!
//! These are `Checker` methods physically defined in a different file: they
//! take `self: *Checker` as an explicit first parameter and are aliased back
//! onto the `Checker` type in `lumen_check.zig` (`pub const arrayMethod =
//! lumen_check_stdlib.arrayMethod;`), so `self.arrayMethod(...)` call sites
//! elsewhere in the checker are unchanged. This relies on Zig allowing a
//! circular `@import` between this file and `lumen_check.zig` (this file needs
//! the `Checker` type; `lumen_check.zig` needs these functions) -- supported
//! because it is a circular *reference*, not a circular *type definition*.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const types = @import("lumen_types.zig");
const check_mod = @import("lumen_check.zig");

const Checker = check_mod.Checker;

/// A map/forEach callback may be `(T) => U` or `(T, int) => U`: the first
/// parameter is the element and the optional second is its integer index.
fn cbParamsMatch(params: []const types.Type, elem: types.Type) bool {
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
        const cb_type = self.exprType(program, mc.args[0], line, col) orelse return null;
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
        const cb_type = self.exprType(program, mc.args[0], line, col) orelse return null;
        if (cb_type != .func_type or !cbParamsMatch(cb_type.func_type.params, elem)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        mc.cb_wants_index = cb_type.func_type.params.len == 2;
        const u = cb_type.func_type.ret.*;
        const res = types.arrayOf(u) orelse {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        mc.array_result_type = res;
        return res;
    }

    // forEach((T) => void): void or forEach((T, int) => void): void
    if (eq(u8, name, "forEach")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const cb_type = self.exprType(program, mc.args[0], line, col) orelse return null;
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
    // element index. reduceRight folds from the end.
    if (eq(u8, name, "reduce") or eq(u8, name, "reduceRight")) {
        if (mc.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const acc = self.exprType(program, mc.args[1], line, col) orelse return null;
        const cb_type = self.exprType(program, mc.args[0], line, col) orelse return null;
        const p = if (cb_type == .func_type) cb_type.func_type.params else &[_]types.Type{};
        const shape_ok = (p.len == 2 or p.len == 3) and
            types.same(p[0], acc) and types.same(p[1], elem) and
            (p.len == 2 or types.isInteger(p[2]));
        if (cb_type != .func_type or !shape_ok or !types.same(cb_type.func_type.ret.*, acc)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        mc.cb_wants_index = p.len == 3;
        mc.array_acc_type = acc;
        mc.array_result_type = acc;
        return acc;
    }

    // findIndex((T) => bool): int  — first matching index, or -1.
    if (eq(u8, name, "findIndex")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const cb_type = self.exprType(program, mc.args[0], line, col) orelse return null;
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
        const cb_type = self.exprType(program, mc.args[0], line, col) orelse return null;
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
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
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
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
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
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        mc.array_result_type = obj_type;
        return obj_type;
    }

    // concat(other: T[]): T[]  — a new array, both sources untouched.
    if (eq(u8, name, "concat")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        self.ensureAssignable(program, obj_type, mc.args[0], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        mc.array_result_type = obj_type;
        return obj_type;
    }

    // sort/toSorted((a: T, b: T) => int): T[]  — a new array ordered by the
    // comparator (negative => a before b), source untouched. Stable. Both names
    // are equivalent here since Lumen arrays are immutable.
    if (eq(u8, name, "sort") or eq(u8, name, "toSorted")) {
        if (mc.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const want = self.makeFuncType(&.{ elem, elem }, .i32) orelse return null;
        self.ensureAssignable(program, want, mc.args[0], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
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

    // join(sep?: string): string
    if (eq(u8, name, "join")) {
        if (mc.args.len > 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        if (mc.args.len == 1) {
            self.ensureAssignable(program, .string, mc.args[0], line, col) catch {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            };
        }
        mc.array_result_type = .string;
        return .string;
    }

    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
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
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        self.ensureAssignable(program, value, mc.args[1], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
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
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
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
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
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
        const want = self.makeFuncType(&.{ value, key }, .void) orelse return null;
        self.ensureAssignable(program, want, mc.args[0], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
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
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
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
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
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
        self.ensureAssignable(program, want, mc.args[0], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
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
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
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
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
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
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
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
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
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
    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
    return null;
}

/// Validate an instance method call on a `string` receiver and return its
/// statically-known result type. Mirrors `arrayMethod`.
pub fn stringMethod(self: *Checker, program: *ast.Program, mc: anytype, line: u32, col: u32) ?types.Type {
    mc.string_method = true;
    const name = mc.name;
    const eq = std.mem.eql;

    // concat(...strings): string -- variadic, doesn't fit the fixed-arity spec
    // table below, so validate it directly.
    if (eq(u8, name, "concat")) {
        if (mc.args.len < 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        for (mc.args) |arg| {
            self.ensureAssignable(program, .string, arg, line, col) catch {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
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
        if (eq(u8, name, "slice")) break :blk .{ .min = 1, .max = 2, .kinds = &.{ .int, .int }, .result = .string };
        if (eq(u8, name, "substring")) break :blk .{ .min = 1, .max = 2, .kinds = &.{ .int, .int }, .result = .string };
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
        if (eq(u8, name, "split")) break :blk .{ .min = 1, .max = 2, .kinds = &.{ .string, .int }, .result = types.arrayOf(.string).? };
        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
        return null;
    };

    if (mc.args.len < spec.min or mc.args.len > spec.max) {
        _ = self.fail(line, col, "E_ARG_COUNT") catch {};
        return null;
    }
    for (mc.args, 0..) |arg, i| {
        switch (spec.kinds[i]) {
            .string => self.ensureAssignable(program, .string, arg, line, col) catch {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            },
            .int => {
                const at = self.exprType(program, arg, line, col) orelse return null;
                if (!types.isInteger(at)) {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                }
            },
        }
    }
    mc.array_result_type = spec.result;
    return spec.result;
}

pub fn staticCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    if (std.mem.eql(u8, call.namespace, "Math")) return self.mathCallType(program, call, line, col);
    if (std.mem.eql(u8, call.namespace, "String")) return self.stringCallType(program, call, line, col);
    if (std.mem.eql(u8, call.namespace, "Array")) return self.arrayCallType(program, call, line, col);
    if (std.mem.eql(u8, call.namespace, "fs")) return self.fsCallType(program, call, line, col);
    if (std.mem.eql(u8, call.namespace, "path")) return self.pathCallType(program, call, line, col);
    if (std.mem.eql(u8, call.namespace, "process")) return self.processCallType(program, call, line, col);
    if (std.mem.eql(u8, call.namespace, "os")) return self.osCallType(program, call, line, col);
    if (std.mem.eql(u8, call.namespace, "crypto")) return self.cryptoCallType(program, call, line, col);
    if (std.mem.eql(u8, call.namespace, "url")) return self.urlCallType(program, call, line, col);
    if (std.mem.eql(u8, call.namespace, "child_process")) return self.childProcessCallType(program, call, line, col);
    if (std.mem.eql(u8, call.namespace, "assert")) return self.assertCallType(program, call, line, col);
    if (std.mem.eql(u8, call.namespace, "time")) return self.timeCallType(program, call, line, col);
    if (std.mem.eql(u8, call.namespace, "http")) return self.httpCallType(program, call, line, col);
    if (std.mem.eql(u8, call.namespace, "net")) return self.netCallType(program, call, line, col);
    if (std.mem.eql(u8, call.namespace, "JSON")) return self.jsonCallType(program, call, line, col);
    if (std.mem.eql(u8, call.namespace, "zlib")) return self.zlibCallType(program, call, line, col);
    if (std.mem.eql(u8, call.namespace, "Promise")) return self.promiseCallType(program, call, line, col);
    if (std.mem.eql(u8, call.namespace, "Buffer")) return self.bufferCallType(program, call, line, col);
    if (std.mem.eql(u8, call.namespace, "readline")) return self.readlineCallType(program, call, line, col);
    if (std.mem.eql(u8, call.namespace, "Worker")) return self.workerCallType(program, call, line, col);
    if (std.mem.eql(u8, call.namespace, "Number")) return self.numberCallType(program, call, line, col);
    _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
    return null;
}

/// Number.parseInt(s, radix?) / Number.parseFloat(s): string -> number, or null
/// when the whole string is not a valid number. Strict (the entire string must
/// parse), unlike JavaScript's lenient prefix parse.
pub fn numberCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    // Predicates on a numeric value -> bool.
    if (std.mem.eql(u8, call.name, "isInteger") or std.mem.eql(u8, call.name, "isFinite") or
        std.mem.eql(u8, call.name, "isNaN") or std.mem.eql(u8, call.name, "isSafeInteger"))
    {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const at = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.isNumeric(at)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        call.checked_arg_type = at;
        call.checked_type = .bool;
        return .bool;
    }
    // Zero-arg float constants.
    if (std.mem.eql(u8, call.name, "EPSILON") or std.mem.eql(u8, call.name, "MAX_VALUE") or
        std.mem.eql(u8, call.name, "MIN_VALUE") or std.mem.eql(u8, call.name, "POSITIVE_INFINITY") or
        std.mem.eql(u8, call.name, "NEGATIVE_INFINITY") or std.mem.eql(u8, call.name, "MAX_SAFE_INTEGER") or
        std.mem.eql(u8, call.name, "MIN_SAFE_INTEGER") or std.mem.eql(u8, call.name, "NaN"))
    {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        call.checked_type = .f64;
        return .f64;
    }
    const is_int = std.mem.eql(u8, call.name, "parseInt");
    const is_float = std.mem.eql(u8, call.name, "parseFloat");
    if (!is_int and !is_float) {
        _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
        return null;
    }
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
    const inner = self.arena.create(types.Type) catch return null;
    inner.* = if (is_int) .i32 else .f64;
    const res = types.Type{ .optional = inner };
    call.checked_type = res;
    return res;
}

/// `Worker.run(fn) -> Promise<T>` (spec 059): `fn` must be a zero-parameter
/// function value whose return type is one of the four scalar types verified
/// safe to hand back across a real OS thread boundary this pass (see
/// spec.md's thread-safety-boundary section) -- strings/arrays/objects are
/// deliberately not accepted yet.
pub fn workerCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    if (std.mem.eql(u8, call.name, "run")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const cb_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (cb_type != .func_type or cb_type.func_type.params.len != 0) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        const ret = cb_type.func_type.ret.*;
        switch (ret) {
            .i32, .i64, .f64, .bool => {},
            else => {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            },
        }
        const p = self.arena.create(types.Type) catch return null;
        p.* = ret;
        const result = types.Type{ .promise_type = p };
        call.checked_arg_type = ret;
        call.checked_type = result;
        program.uses_io = true;
        program.needs_async = true;
        program.needs_worker = true;
        return result;
    }
    _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
    return null;
}

/// `Buffer.from`/`Buffer.alloc` static constructors (spec 056). Mirrors
/// `fsCallType`'s shape for a namespace with a small, fixed function set.
pub fn bufferCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    if (std.mem.eql(u8, call.name, "from")) {
        if (call.args.len != 1 and call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const s_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, s_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        if (call.args.len == 2) {
            const enc_type = self.exprType(program, call.args[1], line, col) orelse return null;
            if (!types.same(.string, enc_type)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        program.needs_buffer = true;
        call.checked_type = .buffer_type;
        return .buffer_type;
    }
    if (std.mem.eql(u8, call.name, "alloc")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const n_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.isInteger(n_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.needs_buffer = true;
        call.checked_type = .buffer_type;
        return .buffer_type;
    }
    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
    return null;
}

pub fn fsCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    if (std.mem.eql(u8, call.name, "readFileSync")) {
        if (call.args.len != 1 and call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        if (call.args.len == 2) {
            const encoding_type = self.exprType(program, call.args[1], line, col) orelse return null;
            if (!types.same(.string, encoding_type)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        program.uses_io = true;
        program.needs_read_file_sync = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "existsSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_exists_sync = true;
        call.checked_type = .bool;
        return .bool;
    }
    if (std.mem.eql(u8, call.name, "realpathSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_realpath_sync = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "writeFileSync") or std.mem.eql(u8, call.name, "appendFileSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const data_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, path_type) or !types.same(.string, data_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        if (std.mem.eql(u8, call.name, "writeFileSync")) program.needs_write_file_sync = true else program.needs_append_file_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "mkdirSync")) {
        if (call.args.len != 1 and call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        if (call.args.len == 2) {
            const recursive_type = self.exprType(program, call.args[1], line, col) orelse return null;
            if (!types.same(.bool, recursive_type)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        program.uses_io = true;
        program.needs_mkdir_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "unlinkSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_unlink_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "renameSync") or std.mem.eql(u8, call.name, "copyFileSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const a_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const b_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, a_type) or !types.same(.string, b_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        if (std.mem.eql(u8, call.name, "renameSync")) program.needs_rename_sync = true else program.needs_copy_file_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "rmdirSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_rmdir_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "rmSync")) {
        if (call.args.len != 1 and call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        if (call.args.len == 2) {
            const recursive_type = self.exprType(program, call.args[1], line, col) orelse return null;
            if (!types.same(.bool, recursive_type)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        program.uses_io = true;
        program.needs_rm_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "truncateSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const len_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, path_type) or !types.isInteger(len_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_truncate_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "linkSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const a_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const b_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, a_type) or !types.same(.string, b_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_link_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "symlinkSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const a_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const b_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, a_type) or !types.same(.string, b_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_symlink_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "readlinkSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_readlink_sync = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "chmodSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const mode_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, path_type) or !types.isInteger(mode_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_chmod_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "accessSync")) {
        if (call.args.len != 1 and call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        if (call.args.len == 2) {
            const mode_type = self.exprType(program, call.args[1], line, col) orelse return null;
            if (!types.isInteger(mode_type)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        program.uses_io = true;
        program.needs_access_sync = true;
        call.checked_type = .bool;
        return .bool;
    }
    if (std.mem.eql(u8, call.name, "cpSync")) {
        if (call.args.len != 2 and call.args.len != 3) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const a_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const b_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, a_type) or !types.same(.string, b_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        if (call.args.len == 3) {
            const recursive_type = self.exprType(program, call.args[2], line, col) orelse return null;
            if (!types.same(.bool, recursive_type)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        program.uses_io = true;
        program.needs_cp_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "mkdtempSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const prefix_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, prefix_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_mkdtemp_sync = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "statSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        // A builtin record return: lazily register a synthetic record type
        // (`__LumenStat`) the first time a stat-family function is used, then
        // return it like any user-declared `type X = {...}`. This is a
        // deliberate deviation from Node: isFile/isDirectory are plain bool
        // fields here, not methods (Lumen has no method dispatch on a
        // builtin-record type yet).
        registerLumenStat(self) orelse return null;
        program.uses_io = true;
        program.needs_stat_sync = true;
        call.checked_type = .{ .named = "__LumenStat" };
        return .{ .named = "__LumenStat" };
    }
    if (std.mem.eql(u8, call.name, "openSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const flags_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, path_type) or !types.same(.string, flags_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_fd_api = true;
        call.checked_type = .i32;
        return .i32;
    }
    if (std.mem.eql(u8, call.name, "closeSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const fd_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.isInteger(fd_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_fd_api = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "readSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const fd_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const len_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.isInteger(fd_type) or !types.isInteger(len_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_fd_api = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "writeSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const fd_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const data_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.isInteger(fd_type) or !types.same(.string, data_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_fd_api = true;
        call.checked_type = .i32;
        return .i32;
    }
    if (std.mem.eql(u8, call.name, "readFile")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        // `fs.readFile(path)` -> `Promise<string>`, read via libxev's io_uring
        // backend (true async file I/O, no thread pool) instead of the
        // synchronous `fs.readFileSync`.
        const p = self.arena.create(types.Type) catch return null;
        p.* = .string;
        const result = types.Type{ .promise_type = p };
        call.checked_type = result;
        program.uses_io = true;
        program.needs_async = true;
        program.needs_async_read_file = true;
        return result;
    }
    if (std.mem.eql(u8, call.name, "writeFile")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const data_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, path_type) or !types.same(.string, data_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        // `fs.writeFile(path, data)` -> `Promise<void>`, the async counterpart
        // to `fs.readFile` -- true non-blocking I/O, no thread pool.
        const p = self.arena.create(types.Type) catch return null;
        p.* = .void;
        const result = types.Type{ .promise_type = p };
        call.checked_type = result;
        program.uses_io = true;
        program.needs_async = true;
        program.needs_async_write_file = true;
        return result;
    }
    if (std.mem.eql(u8, call.name, "appendFile")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const data_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, path_type) or !types.same(.string, data_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        // `fs.appendFile(path, data)` -> `Promise<void>`, the async counterpart
        // to `fs.appendFileSync`.
        const p = self.arena.create(types.Type) catch return null;
        p.* = .void;
        const result = types.Type{ .promise_type = p };
        call.checked_type = result;
        program.uses_io = true;
        program.needs_async = true;
        program.needs_async_append_file = true;
        return result;
    }
    if (std.mem.eql(u8, call.name, "unlink")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        // `fs.unlink(path)` -> `Promise<void>` (spec 047): unlike
        // readFile/writeFile/appendFile, this runs on a real thread pool --
        // libxev's own OperationType union has no async unlink primitive on
        // any backend (checked directly), so this dispatches the blocking
        // syscall to a worker thread and bridges the result back via
        // xev.Async, the same pattern libxev's own kqueue backend uses
        // internally for its file I/O.
        const p = self.arena.create(types.Type) catch return null;
        p.* = .void;
        const result = types.Type{ .promise_type = p };
        call.checked_type = result;
        program.uses_io = true;
        program.needs_async = true;
        program.needs_thread_pool_fs = true;
        program.needs_async_unlink = true;
        return result;
    }
    if (std.mem.eql(u8, call.name, "mkdir")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        const p = self.arena.create(types.Type) catch return null;
        p.* = .void;
        const result = types.Type{ .promise_type = p };
        call.checked_type = result;
        program.uses_io = true;
        program.needs_async = true;
        program.needs_thread_pool_fs = true;
        program.needs_async_mkdir = true;
        return result;
    }
    if (std.mem.eql(u8, call.name, "rmdir")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        const p = self.arena.create(types.Type) catch return null;
        p.* = .void;
        const result = types.Type{ .promise_type = p };
        call.checked_type = result;
        program.uses_io = true;
        program.needs_async = true;
        program.needs_thread_pool_fs = true;
        program.needs_async_rmdir = true;
        return result;
    }
    if (std.mem.eql(u8, call.name, "stat")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        registerLumenStat(self) orelse return null;
        const p = self.arena.create(types.Type) catch return null;
        p.* = .{ .named = "__LumenStat" };
        const result = types.Type{ .promise_type = p };
        call.checked_type = result;
        program.uses_io = true;
        program.needs_async = true;
        program.needs_thread_pool_fs = true;
        program.needs_stat_sync = true;
        program.needs_async_stat = true;
        return result;
    }
    if (std.mem.eql(u8, call.name, "lstatSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        registerLumenStat(self) orelse return null;
        program.uses_io = true;
        program.needs_lstat_sync = true;
        call.checked_type = .{ .named = "__LumenStat" };
        return .{ .named = "__LumenStat" };
    }
    if (std.mem.eql(u8, call.name, "fstatSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const fd_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.isInteger(fd_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        registerLumenStat(self) orelse return null;
        program.uses_io = true;
        program.needs_fstat_sync = true;
        call.checked_type = .{ .named = "__LumenStat" };
        return .{ .named = "__LumenStat" };
    }
    if (std.mem.eql(u8, call.name, "fchmodSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const fd_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const mode_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.isInteger(fd_type) or !types.isInteger(mode_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_fchmod_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "lchmodSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const mode_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, path_type) or !types.isInteger(mode_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_lchmod_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "fchownSync")) {
        if (call.args.len != 3) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const fd_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const uid_type = self.exprType(program, call.args[1], line, col) orelse return null;
        const gid_type = self.exprType(program, call.args[2], line, col) orelse return null;
        if (!types.isInteger(fd_type) or !types.isInteger(uid_type) or !types.isInteger(gid_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_fchown_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "chownSync")) {
        if (call.args.len != 3) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const uid_type = self.exprType(program, call.args[1], line, col) orelse return null;
        const gid_type = self.exprType(program, call.args[2], line, col) orelse return null;
        if (!types.same(.string, path_type) or !types.isInteger(uid_type) or !types.isInteger(gid_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_chown_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "lchownSync")) {
        if (call.args.len != 3) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const uid_type = self.exprType(program, call.args[1], line, col) orelse return null;
        const gid_type = self.exprType(program, call.args[2], line, col) orelse return null;
        if (!types.same(.string, path_type) or !types.isInteger(uid_type) or !types.isInteger(gid_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.needs_lchown_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "writevSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const fd_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const bufs_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.isInteger(fd_type) or !types.same(.string_array, bufs_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_writev_sync = true;
        call.checked_type = .i32;
        return .i32;
    }
    if (std.mem.eql(u8, call.name, "readvSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const fd_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const sizes_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.isInteger(fd_type) or !types.same(.i32_array, sizes_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_readv_sync = true;
        call.checked_type = .string_array;
        return .string_array;
    }
    if (std.mem.eql(u8, call.name, "fsyncSync") or std.mem.eql(u8, call.name, "fdatasyncSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const fd_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.isInteger(fd_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_fsync_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "ftruncateSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const fd_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const len_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.isInteger(fd_type) or !types.isInteger(len_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_ftruncate_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "futimesSync")) {
        if (call.args.len != 3) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const fd_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const atime_type = self.exprType(program, call.args[1], line, col) orelse return null;
        const mtime_type = self.exprType(program, call.args[2], line, col) orelse return null;
        if (!types.isInteger(fd_type) or !types.isInteger(atime_type) or !types.isInteger(mtime_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_futimes_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "utimesSync") or std.mem.eql(u8, call.name, "lutimesSync")) {
        if (call.args.len != 3) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const atime_type = self.exprType(program, call.args[1], line, col) orelse return null;
        const mtime_type = self.exprType(program, call.args[2], line, col) orelse return null;
        if (!types.same(.string, path_type) or !types.isInteger(atime_type) or !types.isInteger(mtime_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_utimes_sync = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "readdirSync")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_readdir_sync = true;
        call.checked_type = .string_array;
        return .string_array;
    }
    if (std.mem.eql(u8, call.name, "watch")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        const want = self.makeFuncType(&.{ .string, .string }, .void) orelse return null;
        self.ensureAssignable(program, want, call.args[1], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        program.needs_fs_watch = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "createReadStream")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_fs_streams = true;
        call.checked_type = .readable_stream_type;
        return .readable_stream_type;
    }
    if (std.mem.eql(u8, call.name, "createWriteStream")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const path_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, path_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_fs_streams = true;
        call.checked_type = .writable_stream_type;
        return .writable_stream_type;
    }
    _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
    return null;
}

// Lazily registers the synthetic `__LumenStat` record type (shared by
// statSync/lstatSync/fstatSync) into the same `type_decls` map a user
// `type X = {...}` declaration would use. See statSync above for the full
// rationale; this just factors out the now-repeated registration so each
// stat-family branch can call it without duplicating the field list.
fn registerLumenStat(self: *Checker) ?void {
    if (self.type_decls.get("__LumenStat") == null) {
        const fields = self.arena.alloc(ast.TypeField, 4) catch return null;
        fields[0] = .{ .name = "size", .annotation = "int", .checked_type = .i32 };
        fields[1] = .{ .name = "isFile", .annotation = "bool", .checked_type = .bool };
        fields[2] = .{ .name = "isDirectory", .annotation = "bool", .checked_type = .bool };
        fields[3] = .{ .name = "mtimeMs", .annotation = "int", .checked_type = .i32 };
        self.type_decls.put(self.arena, "__LumenStat", .{ .fields = fields }) catch return null;
    }
}

// `path.*` (spec 032): pure string manipulation, no `std.Io`/syscalls --
// unlike every `fs.*` function, nothing here ever touches `io`. It still
// sets `program.uses_io` purely to get the prologue to declare `__alloc`
// (the codegen ties that declaration to the same flag as `__io`'s; several
// path functions allocate even though none of them do file I/O).
pub fn pathCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    if (std.mem.eql(u8, call.name, "basename")) {
        if (call.args.len != 1 and call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        for (call.args) |a| {
            const t = self.exprType(program, a, line, col) orelse return null;
            if (!types.same(.string, t)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        program.uses_io = true;
        program.needs_path_api = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "dirname") or std.mem.eql(u8, call.name, "extname") or std.mem.eql(u8, call.name, "normalize")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const t = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, t)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_path_api = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "isAbsolute")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const t = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, t)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_path_api = true;
        call.checked_type = .bool;
        return .bool;
    }
    if (std.mem.eql(u8, call.name, "join")) {
        if (call.args.len < 2 or call.args.len > 6) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        for (call.args) |a| {
            const t = self.exprType(program, a, line, col) orelse return null;
            if (!types.same(.string, t)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        program.uses_io = true;
        program.needs_path_api = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "resolve")) {
        if (call.args.len < 1 or call.args.len > 6) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        for (call.args) |a| {
            const t = self.exprType(program, a, line, col) orelse return null;
            if (!types.same(.string, t)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        program.uses_io = true;
        program.needs_path_api = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "parse")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const t = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, t)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        registerLumenPathParts(self) orelse return null;
        program.uses_io = true;
        program.needs_path_api = true;
        call.checked_type = .{ .named = "__LumenPathParts" };
        return .{ .named = "__LumenPathParts" };
    }
    if (std.mem.eql(u8, call.name, "format")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        registerLumenPathParts(self) orelse return null;
        self.ensureAssignable(program, .{ .named = "__LumenPathParts" }, call.args[0], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        program.uses_io = true;
        program.needs_path_api = true;
        call.checked_type = .string;
        return .string;
    }
    // `path.sep()` / `path.delimiter()`: Node exposes these as plain string
    // properties (`path.sep`, no call), but Lumen has no static-namespace
    // constant-property mechanism yet -- only call dispatch. Exposed as
    // zero-arg functions instead; a deliberate, documented deviation rather
    // than inventing a whole new expression form for two constants.
    if (std.mem.eql(u8, call.name, "sep") or std.mem.eql(u8, call.name, "delimiter")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_path_api = true;
        call.checked_type = .string;
        return .string;
    }
    _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
    return null;
}

// Lazily registers the synthetic `__LumenPathParts` record type (shared by
// `path.parse`'s return value and `path.format`'s parameter), following the
// exact pattern `registerLumenStat` introduced for `fs.statSync`. All five
// fields are plain (non-optional) strings -- a deliberate simplification vs.
// Node, where `path.format`'s argument may omit any field. Round-tripping
// `path.format(path.parse(p))` works perfectly; constructing a literal by
// hand requires every field.
fn registerLumenPathParts(self: *Checker) ?void {
    if (self.type_decls.get("__LumenPathParts") == null) {
        const fields = self.arena.alloc(ast.TypeField, 5) catch return null;
        fields[0] = .{ .name = "root", .annotation = "string", .checked_type = .string };
        fields[1] = .{ .name = "dir", .annotation = "string", .checked_type = .string };
        fields[2] = .{ .name = "base", .annotation = "string", .checked_type = .string };
        fields[3] = .{ .name = "name", .annotation = "string", .checked_type = .string };
        fields[4] = .{ .name = "ext", .annotation = "string", .checked_type = .string };
        self.type_decls.put(self.arena, "__LumenPathParts", .{ .fields = fields }) catch return null;
    }
}

// `process.*` (spec 033): mixed bag -- cwd/chdir/env go through std.process's
// own Io-abstracted primitives (so they need `io`, like `fs`); platform/arch
// are compile-time constants; pid/argv are cheap reads of state Zig's own
// entry already captured, no Io involved at all (argv reuses the existing
// `__args` machinery `argsCount()`/`arg(i)` already set up).
pub fn processCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    if (std.mem.eql(u8, call.name, "cwd")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "chdir")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const t = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, t)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "exit")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const t = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.isInteger(t)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "env")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const t = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, t)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        const inner = self.arena.create(types.Type) catch return null;
        inner.* = .string;
        const result = types.Type{ .optional = inner };
        call.checked_type = result;
        return result;
    }
    if (std.mem.eql(u8, call.name, "platform") or std.mem.eql(u8, call.name, "arch")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "pid")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        call.checked_type = .i32;
        return .i32;
    }
    if (std.mem.eql(u8, call.name, "argv")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        program.needs_args = true;
        call.checked_type = .string_array;
        return .string_array;
    }
    // process API completion (spec 050): uptime/hrtime reuse the same
    // Io.Clock primitive spec 041's time.now()/time.monotonic() already
    // wired up. uptime() additionally needs a start timestamp recorded once
    // in main(), gated by its own needs_process_uptime flag (the other
    // functions in this namespace don't need any main()-time setup).
    if (std.mem.eql(u8, call.name, "uptime")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        program.needs_process_uptime = true;
        call.checked_type = .f64;
        return .f64;
    }
    // hrtime() is a scalar i64 nanosecond count, not Node's [seconds, ns]
    // tuple -- see spec.md's "hrtime shape" section for why: Lumen's i64 is
    // a real 64-bit integer (not an IEEE-754 double), so it doesn't have
    // the precision problem the tuple exists to work around in JS.
    if (std.mem.eql(u8, call.name, "hrtime")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        call.checked_type = .i64;
        return .i64;
    }
    if (std.mem.eql(u8, call.name, "memoryUsage")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        registerLumenProcessMemory(self) orelse return null;
        program.uses_io = true;
        program.needs_process_api = true;
        call.checked_type = .{ .named = "__LumenProcessMemory" };
        return .{ .named = "__LumenProcessMemory" };
    }
    if (std.mem.eql(u8, call.name, "kill")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const pid_t = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.isInteger(pid_t)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        const sig_t = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, sig_t)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        call.checked_type = .bool;
        return .bool;
    }
    if (std.mem.eql(u8, call.name, "umask")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        call.checked_type = .i32;
        return .i32;
    }
    if (std.mem.eql(u8, call.name, "setUmask")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const t = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.isInteger(t)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        call.checked_type = .i32;
        return .i32;
    }
    // getuid/getgid/geteuid/getegid (spec 050): POSIX-only, same shape as
    // the existing pid() -- raw syscalls, 0 fallback on non-Linux targets.
    if (std.mem.eql(u8, call.name, "getuid") or std.mem.eql(u8, call.name, "getgid") or
        std.mem.eql(u8, call.name, "geteuid") or std.mem.eql(u8, call.name, "getegid"))
    {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        call.checked_type = .i32;
        return .i32;
    }
    if (std.mem.eql(u8, call.name, "abort")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        call.checked_type = .void;
        return .void;
    }
    // Lumen's own version marker, not Node's -- see spec.md's "version
    // marker" section.
    if (std.mem.eql(u8, call.name, "version")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_process_api = true;
        call.checked_type = .string;
        return .string;
    }
    // stdio streams (spec 053): process.stdin()/stdout()/stderr() reuse
    // spec 046's exact ReadableStream/WritableStream types, just wired to
    // the real stdio fds instead of an opened file -- see spec.md's "Why
    // reuse spec 046's types verbatim" section. needs_fs_streams is set
    // alongside needs_process_stdio so the shared struct definitions are
    // emitted even in a program that never calls
    // fs.createReadStream/createWriteStream directly.
    if (std.mem.eql(u8, call.name, "stdin")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_fs_streams = true;
        program.needs_process_stdio = true;
        call.checked_type = .readable_stream_type;
        return .readable_stream_type;
    }
    if (std.mem.eql(u8, call.name, "stdout") or std.mem.eql(u8, call.name, "stderr")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_fs_streams = true;
        program.needs_process_stdio = true;
        call.checked_type = .writable_stream_type;
        return .writable_stream_type;
    }
    _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
    return null;
}

// Lazily registers the synthetic `__LumenProcessMemory` record type shared
// by `process.memoryUsage()`, following the same pattern
// `registerLumenStat`/`registerLumenPathParts` already established. Only
// `rss`/`vsize` -- see spec.md's "memoryUsage(): which /proc/self/status
// fields are real" section for why those two and not a faked Node-shaped
// heap breakdown.
fn registerLumenProcessMemory(self: *Checker) ?void {
    if (self.type_decls.get("__LumenProcessMemory") == null) {
        const fields = self.arena.alloc(ast.TypeField, 2) catch return null;
        fields[0] = .{ .name = "rss", .annotation = "i64", .checked_type = .i64 };
        fields[1] = .{ .name = "vsize", .annotation = "i64", .checked_type = .i64 };
        self.type_decls.put(self.arena, "__LumenProcessMemory", .{ .fields = fields }) catch return null;
    }
}

// `os.*` (spec 034): almost entirely two syscalls (uname, sysinfo), no libc.
// `platform()`/`arch()` intentionally duplicate `process.*`'s mapping rather
// than share it at the language level -- Node defines both independently
// with identical values, so this matches Node's actual shape.
pub fn osCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    const string_fns = [_][]const u8{
        "platform", "arch",       "type",   "release", "version", "machine",
        "hostname", "endianness", "tmpdir", "homedir", "EOL",     "devNull",
    };
    for (string_fns) |name| {
        if (std.mem.eql(u8, call.name, name)) {
            if (call.args.len != 0) {
                _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                return null;
            }
            program.uses_io = true;
            program.needs_os_api = true;
            // Every os.* helper is emitted as one unconditional block, and
            // Zig checks top-level declarations eagerly (not only when
            // called) -- so __osTmpdir/__osHomedir's reference to
            // __processEnv must resolve even if the program never calls
            // tmpdir()/homedir(). Simplest fix: any os.* usage pulls in
            // process's __environ/__processEnv machinery (spec 033), not
            // just the two functions that actually need it.
            program.needs_process_api = true;
            call.checked_type = .string;
            return .string;
        }
    }
    const int_fns = [_][]const u8{ "uptime", "totalmem", "freemem", "availableParallelism" };
    for (int_fns) |name| {
        if (std.mem.eql(u8, call.name, name)) {
            if (call.args.len != 0) {
                _ = self.fail(line, col, "E_ARG_COUNT") catch {};
                return null;
            }
            program.uses_io = true;
            program.needs_os_api = true;
            program.needs_process_api = true;
            call.checked_type = .i32;
            return .i32;
        }
    }
    if (std.mem.eql(u8, call.name, "loadavg")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_os_api = true;
        program.needs_process_api = true;
        call.checked_type = .f64_array;
        return .f64_array;
    }
    _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
    return null;
}

pub fn cryptoCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    if (std.mem.eql(u8, call.name, "randomBytes")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const n_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.i32, n_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_crypto_api = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "randomUUID")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_crypto_api = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "sha256")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const data_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, data_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        // sha256 does no I/O, but __cryptoSha256 still needs __alloc for the
        // hex-encoded output, and __alloc's declaration is gated on uses_io.
        program.uses_io = true;
        program.needs_crypto_api = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "randomBytesBuffer")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const n_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.i32, n_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_crypto_api = true;
        program.needs_buffer = true;
        call.checked_type = .buffer_type;
        return .buffer_type;
    }
    if (std.mem.eql(u8, call.name, "hmacSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        self.ensureAssignable(program, .buffer_type, call.args[0], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        self.ensureAssignable(program, .buffer_type, call.args[1], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        program.uses_io = true;
        program.needs_crypto_api = true;
        program.needs_buffer = true;
        call.checked_type = .buffer_type;
        return .buffer_type;
    }
    if (std.mem.eql(u8, call.name, "encryptSync") or std.mem.eql(u8, call.name, "decryptSync")) {
        if (call.args.len != 3) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        for (call.args) |arg| {
            self.ensureAssignable(program, .buffer_type, arg, line, col) catch {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            };
        }
        program.uses_io = true;
        program.needs_crypto_api = true;
        program.needs_buffer = true;
        call.checked_type = .buffer_type;
        return .buffer_type;
    }
    if (std.mem.eql(u8, call.name, "pbkdf2Sync")) {
        if (call.args.len != 4) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        self.ensureAssignable(program, .buffer_type, call.args[0], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        self.ensureAssignable(program, .buffer_type, call.args[1], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        self.ensureAssignable(program, .i32, call.args[2], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        self.ensureAssignable(program, .i32, call.args[3], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        program.needs_crypto_api = true;
        program.needs_buffer = true;
        call.checked_type = .buffer_type;
        return .buffer_type;
    }
    if (std.mem.eql(u8, call.name, "scryptSync")) {
        if (call.args.len != 3) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        self.ensureAssignable(program, .buffer_type, call.args[0], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        self.ensureAssignable(program, .buffer_type, call.args[1], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        self.ensureAssignable(program, .i32, call.args[2], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        program.needs_crypto_api = true;
        program.needs_buffer = true;
        call.checked_type = .buffer_type;
        return .buffer_type;
    }
    if (std.mem.eql(u8, call.name, "timingSafeEqual")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        self.ensureAssignable(program, .buffer_type, call.args[0], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        self.ensureAssignable(program, .buffer_type, call.args[1], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        program.needs_crypto_api = true;
        program.needs_buffer = true;
        call.checked_type = .bool;
        return .bool;
    }
    if (std.mem.eql(u8, call.name, "createHash")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        self.ensureAssignable(program, .string, call.args[0], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        program.needs_buffer = true;
        program.needs_streaming_crypto = true;
        call.checked_type = .hash_type;
        return .hash_type;
    }
    if (std.mem.eql(u8, call.name, "createHmac")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        self.ensureAssignable(program, .string, call.args[0], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        self.ensureAssignable(program, .buffer_type, call.args[1], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        program.needs_buffer = true;
        program.needs_streaming_crypto = true;
        call.checked_type = .hmac_type;
        return .hmac_type;
    }
    _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
    return null;
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
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
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
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
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

/// Validate a `readline.*` static call (spec 058). One function, reusing
/// `process.stdin()`/`process.stdout()` directly -- see spec.md.
pub fn readlineCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    if (std.mem.eql(u8, call.name, "question")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const prompt_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, prompt_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_fs_streams = true;
        program.needs_process_stdio = true;
        program.needs_readline = true;
        call.checked_type = .string;
        return .string;
    }
    _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
    return null;
}

pub fn zlibCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    const one_string_arg_fns = [_][]const u8{ "gzipSync", "gunzipSync", "deflateSync", "inflateSync" };
    var matched = false;
    for (one_string_arg_fns) |fn_name| {
        if (std.mem.eql(u8, call.name, fn_name)) {
            matched = true;
            break;
        }
    }
    if (!matched) {
        _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
        return null;
    }
    if (call.args.len != 1) {
        _ = self.fail(line, col, "E_ARG_COUNT") catch {};
        return null;
    }
    const data_type = self.exprType(program, call.args[0], line, col) orelse return null;
    if (!types.same(.string, data_type)) {
        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
        return null;
    }
    program.uses_io = true;
    program.needs_zlib_api = true;
    call.checked_type = .string;
    return .string;
}

pub fn urlCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    if (std.mem.eql(u8, call.name, "parse")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const t = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, t)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        registerLumenUrlParts(self) orelse return null;
        program.uses_io = true;
        program.needs_url_api = true;
        program.needs_map = true;
        call.checked_type = .{ .named = "__LumenUrlParts" };
        return .{ .named = "__LumenUrlParts" };
    }
    if (std.mem.eql(u8, call.name, "format")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        registerLumenUrlParts(self) orelse return null;
        self.ensureAssignable(program, .{ .named = "__LumenUrlParts" }, call.args[0], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        program.uses_io = true;
        program.needs_url_api = true;
        program.needs_map = true;
        call.checked_type = .string;
        return .string;
    }
    _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
    return null;
}

// Lazily registers the synthetic `__LumenUrlParts` record type (shared by
// `url.parse`'s return value and `url.format`'s parameter), following the
// exact pattern `registerLumenPathParts` introduced for `path.parse`. All
// seven fields are plain (non-optional) strings, same simplification as
// path's record.
fn registerLumenUrlParts(self: *Checker) ?void {
    if (self.type_decls.get("__LumenUrlParts") == null) {
        const fields = self.arena.alloc(ast.TypeField, 8) catch return null;
        fields[0] = .{ .name = "protocol", .annotation = "string", .checked_type = .string };
        fields[1] = .{ .name = "hostname", .annotation = "string", .checked_type = .string };
        fields[2] = .{ .name = "port", .annotation = "string", .checked_type = .string };
        fields[3] = .{ .name = "pathname", .annotation = "string", .checked_type = .string };
        fields[4] = .{ .name = "search", .annotation = "string", .checked_type = .string };
        fields[5] = .{ .name = "hash", .annotation = "string", .checked_type = .string };
        fields[6] = .{ .name = "href", .annotation = "string", .checked_type = .string };
        // spec 045: `search` stays the raw "?a=1&b=2" string as-is; `query`
        // is additive, the same string parsed into key/value pairs.
        const key_ty = self.arena.create(types.Type) catch return null;
        key_ty.* = .string;
        const val_ty = self.arena.create(types.Type) catch return null;
        val_ty.* = .string;
        const map_ty = self.arena.create(types.MapType) catch return null;
        map_ty.* = .{ .key = key_ty, .value = val_ty };
        fields[7] = .{ .name = "query", .annotation = "Map<string,string>", .checked_type = .{ .map_type = map_ty } };
        self.type_decls.put(self.arena, "__LumenUrlParts", .{ .fields = fields }) catch return null;
    }
}

pub fn childProcessCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    if (std.mem.eql(u8, call.name, "spawnSync")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const cmd_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const args_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, cmd_type) or !types.same(.string_array, args_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        registerLumenSpawnResult(self) orelse return null;
        program.uses_io = true;
        program.needs_child_process_api = true;
        call.checked_type = .{ .named = "__LumenSpawnResult" };
        return .{ .named = "__LumenSpawnResult" };
    }
    _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
    return null;
}

// Lazily registers the synthetic `__LumenSpawnResult` record type returned by
// `child_process.spawnSync`, following the exact pattern
// `registerLumenPathParts`/`registerLumenUrlParts` introduced.
fn registerLumenSpawnResult(self: *Checker) ?void {
    if (self.type_decls.get("__LumenSpawnResult") == null) {
        const fields = self.arena.alloc(ast.TypeField, 3) catch return null;
        fields[0] = .{ .name = "stdout", .annotation = "string", .checked_type = .string };
        fields[1] = .{ .name = "stderr", .annotation = "string", .checked_type = .string };
        fields[2] = .{ .name = "status", .annotation = "int", .checked_type = .i32 };
        self.type_decls.put(self.arena, "__LumenSpawnResult", .{ .fields = fields }) catch return null;
    }
}

// `assert.*`: wraps the language's own panic mechanism rather than the
// throw/catch machinery, since a static call has no access to an enclosing
// try's throw target. A failed assertion crashes the program (uncatchable),
// the same idiom as C's assert() or an uncaught Node AssertionError.
pub fn assertCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    if (std.mem.eql(u8, call.name, "ok")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const cond_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.bool, cond_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.needs_assert = true;
        call.checked_type = .void;
        return .void;
    }
    if (std.mem.eql(u8, call.name, "equal")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const a_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const b_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(a_type, b_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        // Strings compare by bytes, not slice identity -- same routing
        // trick `expect(...).toBe(...)` uses for `__expectStrEqual`.
        if (types.same(.string, a_type)) {
            call.name = "__assertStrEqual";
        }
        program.needs_assert = true;
        call.checked_type = .void;
        return .void;
    }
    _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
    return null;
}

pub fn timeCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    if (std.mem.eql(u8, call.name, "now") or std.mem.eql(u8, call.name, "monotonic")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_time_api = true;
        call.checked_type = .i64;
        return .i64;
    }
    _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
    return null;
}

pub fn httpCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    if (std.mem.eql(u8, call.name, "request")) {
        if (call.args.len != 4) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const url_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const method_type = self.exprType(program, call.args[1], line, col) orelse return null;
        const body_type = self.exprType(program, call.args[2], line, col) orelse return null;
        if (!types.same(.string, url_type) or !types.same(.string, method_type) or !types.same(.string, body_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        const key_ty = self.arena.create(types.Type) catch return null;
        key_ty.* = .string;
        const val_ty = self.arena.create(types.Type) catch return null;
        val_ty.* = .string;
        const map_ty = self.arena.create(types.MapType) catch return null;
        map_ty.* = .{ .key = key_ty, .value = val_ty };
        const headers_type = self.exprType(program, call.args[3], line, col) orelse return null;
        if (!types.same(.{ .map_type = map_ty }, headers_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        registerLumenHttpResponse(self) orelse return null;
        program.uses_io = true;
        program.needs_http_module = true;
        program.needs_map = true;
        call.checked_type = .{ .named = "__LumenHttpResponse" };
        return .{ .named = "__LumenHttpResponse" };
    }
    if (std.mem.eql(u8, call.name, "get")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const url_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, url_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        registerLumenHttpResponse(self) orelse return null;
        program.uses_io = true;
        program.needs_http_module = true;
        program.needs_map = true;
        call.checked_type = .{ .named = "__LumenHttpResponse" };
        return .{ .named = "__LumenHttpResponse" };
    }
    if (std.mem.eql(u8, call.name, "createServer")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const port_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.i32, port_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        registerLumenHttpRequest(self) orelse return null;
        registerLumenHttpResponse(self) orelse return null;
        const want = self.makeFuncType(&.{.{ .named = "__LumenHttpRequest" }}, .{ .named = "__LumenHttpResponse" }) orelse return null;
        self.ensureAssignable(program, want, call.args[1], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        program.uses_io = true;
        program.needs_http_module = true;
        program.needs_http_server = true;
        program.needs_map = true;
        call.checked_type = .void;
        return .void;
    }
    // `http.METHODS`/`STATUS_CODES` (spec 049): zero-arg "functions" for
    // what are really constants, the same deviation `Math.PI()`/`os.EOL()`
    // already established -- Lumen has no static namespace member/property
    // access, only namespace *calls*.
    if (std.mem.eql(u8, call.name, "METHODS")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_http_constants = true;
        // __httpMethods() and __httpStatusCodes() are emitted together
        // under one needs_http_constants-gated block, so a program using
        // METHODS without STATUS_CODES still needs LumenMap in scope for
        // the latter to reference -- confirmed as a real bug: `http.METHODS()`
        // alone failed to compile with "use of undeclared identifier
        // 'LumenMap'" before this fix, since only STATUS_CODES's branch set
        // needs_map.
        program.needs_map = true;
        call.checked_type = .string_array;
        return .string_array;
    }
    if (std.mem.eql(u8, call.name, "STATUS_CODES")) {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const key_ty = self.arena.create(types.Type) catch return null;
        key_ty.* = .i32;
        const val_ty = self.arena.create(types.Type) catch return null;
        val_ty.* = .string;
        const map_ty = self.arena.create(types.MapType) catch return null;
        map_ty.* = .{ .key = key_ty, .value = val_ty };
        program.uses_io = true;
        program.needs_http_constants = true;
        program.needs_map = true;
        call.checked_type = .{ .map_type = map_ty };
        return .{ .map_type = map_ty };
    }
    _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
    return null;
}

/// `net.*` (spec 054): raw TCP sockets, the layer `http`'s client/server are
/// already built on but didn't expose directly. `net.connect` yields a
/// `Socket` (see `socketMethod`); `net.createServer`'s handler receives one
/// per accepted connection.
pub fn netCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    if (std.mem.eql(u8, call.name, "connect")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const host_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const port_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, host_type) or !types.same(.i32, port_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        program.uses_io = true;
        program.needs_net = true;
        program.needs_net_client = true;
        call.checked_type = .socket_type;
        return .socket_type;
    }
    if (std.mem.eql(u8, call.name, "createServer")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const port_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.i32, port_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        const want = self.makeFuncType(&.{.socket_type}, .void) orelse return null;
        self.ensureAssignable(program, want, call.args[1], line, col) catch {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        program.uses_io = true;
        program.needs_net = true;
        program.needs_net_server = true;
        call.checked_type = .void;
        return .void;
    }
    _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
    return null;
}

// `JSON.*` (spec 051): thin wrappers around std.json's own automatic struct
// reflection -- Lumen record types already lower to real Zig structs with
// matching field names, confirmed directly (not assumed) that
// std.json.Stringify.valueAlloc/parseFromSlice both work on an arbitrary
// struct with zero custom (de)serialization code needed.
pub fn jsonCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    if (std.mem.eql(u8, call.name, "stringify")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        // T is inferred from the argument, same as every other Lumen
        // builtin -- no explicit type argument needed (there's a real
        // value to infer from, unlike parse<T> below).
        const value_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!jsonSerializable(value_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        call.checked_arg_type = value_type;
        program.uses_io = true;
        program.needs_json = true;
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "parse")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        if (call.type_args.len != 1) {
            // JSON.parse<T>(text) -- T can't be inferred from a string,
            // unlike stringify's value argument above.
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        const text_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, text_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        const result_type = self.typeFromAnnotation(call.type_args[0], line, col) catch return null;
        if (!jsonSerializable(result_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        call.checked_arg_type = result_type;
        program.uses_io = true;
        program.needs_json = true;
        call.checked_type = result_type;
        return result_type;
    }
    _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
    return null;
}

// Whether `t` is a type std.json's automatic struct/slice reflection can
// round-trip directly: primitives, named records (which lower to real Zig
// structs with matching field names), and arrays of either. Map/Set/tuple
// deliberately excluded -- those lower to Lumen-specific runtime types
// (LumenMap/LumenSet/positional structs) std.json's default reflection
// doesn't understand the shape of (see spec 051's "Not planned" table).
fn jsonSerializable(t: types.Type) bool {
    return switch (t) {
        .string, .i32, .i64, .f64, .bool => true,
        .named => true,
        .i32_array, .i64_array, .f64_array, .bool_array, .string_array, .named_array => true,
        else => false,
    };
}

// Lazily registers the synthetic `__LumenHttpResponse` record type returned
// by `http.request`/`http.get`, and returned by `http.createServer`'s
// handler, following the exact pattern `registerLumenSpawnResult`
// introduced.
pub fn registerLumenHttpResponse(self: *Checker) ?void {
    if (self.type_decls.get("__LumenHttpResponse") == null) {
        const fields = self.arena.alloc(ast.TypeField, 4) catch return null;
        fields[0] = .{ .name = "status", .annotation = "int", .checked_type = .i32 };
        fields[1] = .{ .name = "body", .annotation = "string", .checked_type = .string };
        fields[2] = .{ .name = "ok", .annotation = "bool", .checked_type = .bool };
        // spec 045: shared by the client's returned response (real response
        // headers) and the server handler's return value (headers the
        // handler chooses to send back).
        const key_ty = self.arena.create(types.Type) catch return null;
        key_ty.* = .string;
        const val_ty = self.arena.create(types.Type) catch return null;
        val_ty.* = .string;
        const map_ty = self.arena.create(types.MapType) catch return null;
        map_ty.* = .{ .key = key_ty, .value = val_ty };
        fields[3] = .{ .name = "headers", .annotation = "Map<string,string>", .checked_type = .{ .map_type = map_ty } };
        self.type_decls.put(self.arena, "__LumenHttpResponse", .{ .fields = fields }) catch return null;
    }
}

// Lazily registers the synthetic `__LumenHttpRequest` record type passed to
// `http.createServer`'s handler.
pub fn registerLumenHttpRequest(self: *Checker) ?void {
    if (self.type_decls.get("__LumenHttpRequest") == null) {
        const fields = self.arena.alloc(ast.TypeField, 3) catch return null;
        fields[0] = .{ .name = "method", .annotation = "string", .checked_type = .string };
        fields[1] = .{ .name = "path", .annotation = "string", .checked_type = .string };
        fields[2] = .{ .name = "body", .annotation = "string", .checked_type = .string };
        self.type_decls.put(self.arena, "__LumenHttpRequest", .{ .fields = fields }) catch return null;
    }
}

pub fn promiseCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    // `Promise.resolve(v)` -> an already-resolved `Promise<typeof v>`.
    if (std.mem.eql(u8, call.name, "resolve")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const inner = self.exprType(program, call.args[0], line, col) orelse return null;
        const p = self.arena.create(types.Type) catch return null;
        p.* = inner;
        const result = types.Type{ .promise_type = p };
        // Inner type drives `__promiseResolved(T, v)`; result is `Promise<T>`.
        call.checked_arg_type = inner;
        call.checked_type = result;
        program.uses_io = true;
        program.needs_async = true;
        return result;
    }
    _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
    return null;
}

pub fn mathCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    if (std.mem.eql(u8, call.name, "abs") or std.mem.eql(u8, call.name, "sign") or std.mem.eql(u8, call.name, "sqrt")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const arg_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.isNumeric(arg_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        call.checked_arg_type = arg_type;
        call.checked_type = if (std.mem.eql(u8, call.name, "sign")) .i32 else if (std.mem.eql(u8, call.name, "sqrt")) .f64 else arg_type;
        return call.checked_type;
    }
    // fround(x): number -- round to the nearest 32-bit float, back to f64.
    if (std.mem.eql(u8, call.name, "fround")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const at = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.isNumeric(at)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        call.checked_arg_type = at;
        call.checked_type = .f64;
        return .f64;
    }
    // clz32(x): int -- count leading zero bits in the 32-bit representation.
    if (std.mem.eql(u8, call.name, "clz32")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const at = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.isInteger(at)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        call.checked_type = .i32;
        return .i32;
    }
    // imul(a, b): int -- 32-bit wrapping integer multiply.
    if (std.mem.eql(u8, call.name, "imul")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        for (call.args) |arg| {
            const at = self.exprType(program, arg, line, col) orelse return null;
            if (!types.isInteger(at)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        call.checked_type = .i32;
        return .i32;
    }
    if (std.mem.eql(u8, call.name, "max") or std.mem.eql(u8, call.name, "min")) {
        // Variadic: two or more arguments, all of the same numeric type.
        if (call.args.len < 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const first_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.isNumeric(first_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        for (call.args[1..]) |arg| {
            const at = self.exprType(program, arg, line, col) orelse return null;
            if (!types.same(first_type, at)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        call.checked_arg_type = first_type;
        call.checked_type = first_type;
        return first_type;
    }
    if (std.mem.eql(u8, call.name, "clamp")) {
        if (call.args.len != 3) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const value_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const min_type = self.exprType(program, call.args[1], line, col) orelse return null;
        const max_type = self.exprType(program, call.args[2], line, col) orelse return null;
        if (!types.isNumeric(value_type) or !types.same(value_type, min_type) or !types.same(value_type, max_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        call.checked_arg_type = value_type;
        call.checked_type = value_type;
        return value_type;
    }
    // floor/ceil/round/trunc always produce a whole number -- return int,
    // same reasoning as `sign` (the value is inherently integral).
    if (std.mem.eql(u8, call.name, "floor") or std.mem.eql(u8, call.name, "ceil") or std.mem.eql(u8, call.name, "round") or std.mem.eql(u8, call.name, "trunc")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const arg_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.isNumeric(arg_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        call.checked_arg_type = arg_type;
        call.checked_type = .i32;
        return .i32;
    }
    // pow/log/sin/cos always return `number` -- like `sqrt`, the result can
    // be fractional even from integer inputs.
    if (std.mem.eql(u8, call.name, "pow")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const base_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const exp_type = self.exprType(program, call.args[1], line, col) orelse return null;
        // Same-type requirement as max/min: simpler than tracking two
        // independent arg types just to decide each one's int-to-f64
        // conversion, and Node's Math.pow doesn't distinguish int vs float
        // arguments anyway (there's only "number").
        if (!types.isNumeric(base_type) or !types.same(base_type, exp_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        call.checked_arg_type = base_type;
        call.checked_type = .f64;
        return .f64;
    }
    if (std.mem.eql(u8, call.name, "log") or std.mem.eql(u8, call.name, "sin") or std.mem.eql(u8, call.name, "cos") or
        std.mem.eql(u8, call.name, "tan") or std.mem.eql(u8, call.name, "exp") or std.mem.eql(u8, call.name, "exp2") or
        std.mem.eql(u8, call.name, "log2") or std.mem.eql(u8, call.name, "log10"))
    {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const arg_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.isNumeric(arg_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        call.checked_arg_type = arg_type;
        call.checked_type = .f64;
        return .f64;
    }
    // Unary std.math functions (no direct Zig builtin): inverse trig, cbrt,
    // and the hyperbolic family.
    if (std.mem.eql(u8, call.name, "asin") or std.mem.eql(u8, call.name, "acos") or
        std.mem.eql(u8, call.name, "atan") or std.mem.eql(u8, call.name, "cbrt") or
        std.mem.eql(u8, call.name, "sinh") or std.mem.eql(u8, call.name, "cosh") or
        std.mem.eql(u8, call.name, "tanh") or std.mem.eql(u8, call.name, "asinh") or
        std.mem.eql(u8, call.name, "acosh") or std.mem.eql(u8, call.name, "atanh") or
        std.mem.eql(u8, call.name, "expm1") or std.mem.eql(u8, call.name, "log1p"))
    {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const arg_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.isNumeric(arg_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        call.checked_arg_type = arg_type;
        call.checked_type = .f64;
        return .f64;
    }
    // Binary std.math functions. Same-type args as pow/max/min: simpler than
    // tracking two independent arg types just to pick each one's coercion.
    // atan2 is strictly binary; hypot is variadic (two or more, same type).
    if (std.mem.eql(u8, call.name, "atan2") or std.mem.eql(u8, call.name, "hypot")) {
        const is_hypot = std.mem.eql(u8, call.name, "hypot");
        const ok_count = if (is_hypot) call.args.len >= 2 else call.args.len == 2;
        if (!ok_count) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const a_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.isNumeric(a_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        for (call.args[1..]) |arg| {
            const at = self.exprType(program, arg, line, col) orelse return null;
            if (!types.same(a_type, at)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        call.checked_arg_type = a_type;
        call.checked_type = .f64;
        return .f64;
    }
    // Math.PI() / Math.E() -- zero-arg functions, not properties, the same
    // deviation as path.sep()/process.platform() (no static-namespace
    // constant-property mechanism yet).
    if (std.mem.eql(u8, call.name, "PI") or std.mem.eql(u8, call.name, "E") or
        std.mem.eql(u8, call.name, "LN2") or std.mem.eql(u8, call.name, "LN10") or
        std.mem.eql(u8, call.name, "LOG2E") or std.mem.eql(u8, call.name, "LOG10E") or
        std.mem.eql(u8, call.name, "SQRT2") or std.mem.eql(u8, call.name, "SQRT1_2"))
    {
        if (call.args.len != 0) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        call.checked_type = .f64;
        return .f64;
    }
    _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
    return null;
}

pub fn stringCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    if (std.mem.eql(u8, call.name, "isEmpty")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const arg_type = self.exprType(program, call.args[0], line, col) orelse return null;
        if (!types.same(.string, arg_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        call.checked_type = .bool;
        return .bool;
    }
    if (std.mem.eql(u8, call.name, "fromCharCode") or std.mem.eql(u8, call.name, "fromCodePoint")) {
        // Variadic: one byte per code, each masked to & 0xFF.
        if (call.args.len < 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        for (call.args) |arg| {
            const arg_type = self.exprType(program, arg, line, col) orelse return null;
            if (!types.isInteger(arg_type)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        call.checked_type = .string;
        return .string;
    }
    if (std.mem.eql(u8, call.name, "contains") or std.mem.eql(u8, call.name, "startsWith")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const left_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const right_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, left_type) or !types.same(.string, right_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        call.checked_type = .bool;
        return .bool;
    }
    // String.compare(a, b): int -- lexicographic byte ordering, -1/0/1. Gives
    // string[] a usable `sort` comparator.
    if (std.mem.eql(u8, call.name, "compare")) {
        if (call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const left_type = self.exprType(program, call.args[0], line, col) orelse return null;
        const right_type = self.exprType(program, call.args[1], line, col) orelse return null;
        if (!types.same(.string, left_type) or !types.same(.string, right_type)) {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        }
        call.checked_type = .i32;
        return .i32;
    }
    _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
    return null;
}

pub fn arrayCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    if (!std.mem.eql(u8, call.name, "isEmpty")) {
        _ = self.fail(line, col, "E_UNSUPPORTED_STD") catch {};
        return null;
    }
    if (call.args.len != 1) {
        _ = self.fail(line, col, "E_ARG_COUNT") catch {};
        return null;
    }
    const arg_type = self.exprType(program, call.args[0], line, col) orelse return null;
    if (!types.isArray(arg_type)) {
        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
        return null;
    }
    call.checked_type = .bool;
    return .bool;
}
