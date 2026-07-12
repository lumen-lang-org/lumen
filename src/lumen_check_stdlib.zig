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
const check_methods = @import("lumen_check_methods.zig");

/// A map/forEach callback may be `(T) => U` or `(T, int) => U`: the first
/// parameter is the element and the optional second is its integer index.
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
    if (std.mem.eql(u8, call.namespace, "Date")) return self.dateCallType(program, call, line, col);
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
            return null;
        };
        self.ensureAssignable(program, .buffer_type, call.args[1], line, col) catch {
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
            return null;
        };
        self.ensureAssignable(program, .buffer_type, call.args[1], line, col) catch {
            return null;
        };
        self.ensureAssignable(program, .i32, call.args[2], line, col) catch {
            return null;
        };
        self.ensureAssignable(program, .i32, call.args[3], line, col) catch {
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
            return null;
        };
        self.ensureAssignable(program, .buffer_type, call.args[1], line, col) catch {
            return null;
        };
        self.ensureAssignable(program, .i32, call.args[2], line, col) catch {
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
            return null;
        };
        self.ensureAssignable(program, .buffer_type, call.args[1], line, col) catch {
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
            return null;
        };
        self.ensureAssignable(program, .buffer_type, call.args[1], line, col) catch {
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

/// Date.now(): milliseconds since the Unix epoch, as i64 (promotes to f64 in
/// float contexts via spec 256). The rest of the Date object is future work.
pub fn dateCallType(self: *Checker, program: *ast.Program, call: *ast.StaticCall, line: u32, col: u32) ?types.Type {
    if (std.mem.eql(u8, call.name, "now")) {
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
        if (call.args[0].* == .obj) {
            _ = self.fail(line, col, "JSON.stringify needs a typed value — bind the object literal to a named record type first (`const v: T = { ... }`)") catch {};
            return null;
        }
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
    // `Promise.all([p1, p2, ...])` -> `Promise<T[]>`. Promises are eager (they
    // schedule on the shared event loop at creation), so awaiting each in turn
    // still lets them all make progress concurrently. Restricted to an array
    // literal so the element promises' types are known positionally.
    if (std.mem.eql(u8, call.name, "all")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        if (call.args[0].* != .array) {
            _ = self.fail(line, col, "Promise.all takes an array literal of promises, e.g. `Promise.all([a(), b()])`") catch {};
            return null;
        }
        const items = call.args[0].array.items;
        if (items.len == 0) {
            _ = self.fail(line, col, "Promise.all needs at least one promise") catch {};
            return null;
        }
        var inner: ?types.Type = null;
        for (items) |it| {
            const it_ty = self.exprType(program, it, line, col) orelse return null;
            if (it_ty != .promise_type) {
                const tn = types.tsName(self.arena, it_ty) catch "?";
                const msg = std.fmt.allocPrint(self.arena, "Promise.all elements must be promises, got `{s}`", .{tn}) catch "E_TYPE_MISMATCH";
                _ = self.fail(line, col, msg) catch {};
                return null;
            }
            const t = it_ty.promise_type.*;
            if (inner) |prev| {
                if (!types.same(prev, t)) {
                    _ = self.fail(line, col, "Promise.all elements must all resolve to the same type") catch {};
                    return null;
                }
            } else inner = t;
        }
        const arr_ty = types.arrayOf(inner.?) orelse {
            const tn = types.tsName(self.arena, inner.?) catch "?";
            const msg = std.fmt.allocPrint(self.arena, "Promise.all cannot collect `Promise<{s}>` — the resolved type has no array form", .{tn}) catch "E_TYPE_MISMATCH";
            _ = self.fail(line, col, msg) catch {};
            return null;
        };
        const p = self.arena.create(types.Type) catch return null;
        p.* = arr_ty;
        call.checked_arg_type = inner.?; // element type, drives the alloc
        call.checked_type = .{ .promise_type = p };
        program.uses_io = true;
        program.needs_async = true;
        return .{ .promise_type = p };
    }
    const msg = std.fmt.allocPrint(self.arena, "Promise.{s} is not supported yet — only Promise.resolve(v) and Promise.all([...]); use `async`/`await` for composition", .{call.name}) catch "E_UNSUPPORTED_STD";
    _ = self.fail(line, col, msg) catch {};
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
        // `Math.min(...arr)` / `Math.max(...arr)`: fold over a numeric array.
        if (call.args.len == 1 and call.args[0].* == .spread) {
            const src_type = self.exprType(program, call.args[0].spread, line, col) orelse return null;
            const elem = types.arrayElem(src_type) orelse {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            };
            if (!types.isNumeric(elem)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
            call.checked_arg_type = elem;
            call.checked_type = elem;
            return elem;
        }
        // Variadic: one or more arguments, all of the same numeric type. A
        // single argument (`Math.min(5)`) is just that value, as in JS.
        if (call.args.len < 1) {
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
    // Array.isArray(x): types are static, so the answer is a compile-time
    // bool (spec 275). checked_arg_type carries the verdict for emission.
    if (std.mem.eql(u8, call.name, "isArray")) {
        if (call.args.len != 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const at = self.exprType(program, call.args[0], line, col) orelse return null;
        call.checked_arg_type = if (types.isArray(at)) .bool else .void; // bool => true, void => false
        call.checked_type = .bool;
        return .bool;
    }
    // Array.of(...items): T[] -- build an array from the arguments (all one type).
    if (std.mem.eql(u8, call.name, "of")) {
        if (call.args.len < 1) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const t = self.exprType(program, call.args[0], line, col) orelse return null;
        for (call.args[1..]) |arg| {
            const at = self.exprType(program, arg, line, col) orelse return null;
            if (!types.same(t, at)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
        }
        const res = types.arrayOf(t) orelse {
            _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
            return null;
        };
        call.checked_arg_type = t;
        call.checked_type = res;
        return res;
    }
    // Array.from(x): a string -> array of single-char strings; an array -> copy.
    // Array.from(x, (v, i) => u): map each element through the callback -> u[].
    if (std.mem.eql(u8, call.name, "from")) {
        if (call.args.len != 1 and call.args.len != 2) {
            _ = self.fail(line, col, "E_ARG_COUNT") catch {};
            return null;
        }
        const src = self.exprType(program, call.args[0], line, col) orelse return null;
        call.checked_arg_type = src;
        if (call.args.len == 2) {
            // The source element type: a string yields single-char strings.
            const src_elem: types.Type = if (types.same(.string, src))
                .string
            else if (types.isArray(src))
                (types.arrayElem(src) orelse {
                    _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                    return null;
                })
            else if (src == .set_type)
                src.set_type.*
            else {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            };
            const cb_type = self.checkCbArg(program, call.args[1], &.{ src_elem, .i32 }, line, col) orelse return null;
            if (cb_type != .func_type or !check_methods.cbParamsMatch(cb_type.func_type.params, src_elem)) {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            }
            call.cb_wants_index = cb_type.func_type.params.len == 2;
            const res = types.arrayOf(cb_type.func_type.ret.*) orelse {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            };
            call.checked_type = res;
            return res;
        }
        if (types.same(.string, src)) {
            call.checked_type = types.arrayOf(.string).?;
            return call.checked_type;
        }
        if (types.isArray(src)) {
            call.checked_type = src;
            return src;
        }
        // Array.from(set): the set's elements as an array.
        if (src == .set_type) {
            call.checked_type = types.arrayOf(src.set_type.*) orelse {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            };
            return call.checked_type;
        }
        _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
        return null;
    }
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
