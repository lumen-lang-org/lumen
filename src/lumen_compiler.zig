//! TypeScript-syntax -> Zig -> native compiler seed.
//!
//! NOT part of the ECMAScript engine or the Test262 path. A SEPARATE,
//! self-contained front-end that takes a small statically-typed TypeScript
//! syntax subset and lowers it to Zig source, which `zig build-exe` then turns
//! into a native binary. Using Zig as the backend means we write the front-end
//! and lowering first; optimization, native codegen, and cross-compilation come
//! from Zig/LLVM.
//!
//! ## What lives in this (large) file
//! Three stages share it; this is the biggest source file and the main candidate
//! for further splitting:
//!   * `Parser` -- turns the lexer's tokens into the AST (`parsePrimary`,
//!     `parseExpr`, `parseStmt`, and friends).
//!   * Codegen -- `emitProgram` / `emitStmt` / `emitExpr` walk the *typed* AST and
//!     append Zig source text to a buffer. There is no separate IR: we emit Zig
//!     directly, then `lumen.zig` shells out to `zig build-exe`.
//!   * Optimization passes over the AST (string-builder accumulators,
//!     destination-passing into a caller's buffer, chained-concat flattening) that
//!     exist purely to allocate less in the generated program.
//!
//! Generated programs allocate from a single never-freed arena (`__sa_arena`), so
//! the passes above are about avoiding allocations rather than freeing them. When
//! emitting character comparisons we use raw byte values (`== 46`) to sidestep Zig
//! char-literal escaping. Splitting this file into parser/codegen/passes modules is
//! an ongoing, conformance-guarded effort -- `regex_specialize.zig` was the first
//! seam pulled out (see the `.method_call` regex case in `emitExpr`).
const std = @import("std");

// The regex runtime engine, embedded verbatim into programs that use regex.
const REGEX_RT = @embedFile("regex_rt.zig");

// JS-semantics parseInt/parseFloat, emitted into every program's prelude.
//
// `__rng_state`/`__rng_ready` at the end of this block are `threadlocal` for the
// reason spec 468 gives: a generator's state belongs to the stream drawing from
// it, and two HTTP handlers on two pool threads calling `Math.random()` at once
// would otherwise interleave their reads and writes of one Xoshiro state -- and
// race the lazy-init flag, so both could seed it. Per-thread is also the better
// seed: the anchor is a stack address, and each thread's stack is its own.
const PARSE_RT =
    \\fn __parseInt(__s: []const u8, __radix_in: i32) ?i32 {
    \\    var __i: usize = 0;
    \\    while (__i < __s.len and (__s[__i] == ' ' or __s[__i] == '\t' or __s[__i] == '\n' or __s[__i] == '\r')) : (__i += 1) {}
    \\    var __neg = false;
    \\    if (__i < __s.len and (__s[__i] == '+' or __s[__i] == '-')) { __neg = __s[__i] == '-'; __i += 1; }
    \\    var __radix: i64 = __radix_in;
    \\    if ((__radix == 16 or __radix == 0) and __i + 1 < __s.len and __s[__i] == '0' and (__s[__i + 1] == 'x' or __s[__i + 1] == 'X')) { __i += 2; __radix = 16; }
    \\    if (__radix == 0) __radix = 10;
    \\    if (__radix < 2 or __radix > 36) return null;
    \\    var __val: i64 = 0;
    \\    var __any = false;
    \\    while (__i < __s.len) : (__i += 1) {
    \\        const __ch = __s[__i];
    \\        const __d: i64 = if (__ch >= '0' and __ch <= '9') @as(i64, __ch - '0') else if (__ch >= 'a' and __ch <= 'z') @as(i64, __ch - 'a' + 10) else if (__ch >= 'A' and __ch <= 'Z') @as(i64, __ch - 'A' + 10) else 255;
    \\        if (__d >= __radix) break;
    \\        __val = __val * __radix + __d;
    \\        __any = true;
    \\        if (__val > 2147483648) return null;
    \\    }
    \\    if (!__any) return null;
    \\    if (__neg) __val = -__val;
    \\    if (__val > 2147483647 or __val < -2147483648) return null;
    \\    return @intCast(__val);
    \\}
    \\fn __parseFloat(__s: []const u8) ?f64 {
    \\    var __i: usize = 0;
    \\    while (__i < __s.len and (__s[__i] == ' ' or __s[__i] == '\t' or __s[__i] == '\n' or __s[__i] == '\r')) : (__i += 1) {}
    \\    const __start = __i;
    \\    if (__i < __s.len and (__s[__i] == '+' or __s[__i] == '-')) __i += 1;
    \\    while (__i < __s.len) : (__i += 1) {
    \\        const __ch = __s[__i];
    \\        if ((__ch >= '0' and __ch <= '9') or __ch == '.' or __ch == 'e' or __ch == 'E' or __ch == '+' or __ch == '-') continue;
    \\        break;
    \\    }
    \\    var __end = __i;
    \\    while (__end > __start) : (__end -= 1) {
    \\        if (std.fmt.parseFloat(f64, __s[__start..__end])) |__v| return __v else |_| {}
    \\    }
    \\    return null;
    \\}
    \\fn __uriHex(__n: u8) u8 { return if (__n < 10) '0' + __n else 'A' + (__n - 10); }
    \\fn __encodeURIComponent(__s: []const u8) []const u8 {
    \\    var __b: std.ArrayListUnmanaged(u8) = .empty;
    \\    for (__s) |__c| {
    \\        const __unreserved = (__c >= 'A' and __c <= 'Z') or (__c >= 'a' and __c <= 'z') or (__c >= '0' and __c <= '9') or __c == '-' or __c == '_' or __c == '.' or __c == '!' or __c == '~' or __c == '*' or __c == '\'' or __c == '(' or __c == ')';
    \\        if (__unreserved) {
    \\            __b.append(__sa(), __c) catch unreachable;
    \\        } else {
    \\            __b.append(__sa(), '%') catch unreachable;
    \\            __b.append(__sa(), __uriHex(__c >> 4)) catch unreachable;
    \\            __b.append(__sa(), __uriHex(__c & 0x0f)) catch unreachable;
    \\        }
    \\    }
    \\    return __b.items;
    \\}
    \\fn __uriUnhex(__c: u8) ?u8 {
    \\    if (__c >= '0' and __c <= '9') return __c - '0';
    \\    if (__c >= 'A' and __c <= 'F') return __c - 'A' + 10;
    \\    if (__c >= 'a' and __c <= 'f') return __c - 'a' + 10;
    \\    return null;
    \\}
    \\fn __decodeURIComponent(__s: []const u8) []const u8 {
    \\    var __b: std.ArrayListUnmanaged(u8) = .empty;
    \\    var __i: usize = 0;
    \\    while (__i < __s.len) : (__i += 1) {
    \\        if (__s[__i] == '%' and __i + 2 < __s.len) {
    \\            const __hi = __uriUnhex(__s[__i + 1]);
    \\            const __lo = __uriUnhex(__s[__i + 2]);
    \\            if (__hi != null and __lo != null) {
    \\                __b.append(__sa(), (__hi.? << 4) | __lo.?) catch unreachable;
    \\                __i += 2;
    \\                continue;
    \\            }
    \\        }
    \\        __b.append(__sa(), __s[__i]) catch unreachable;
    \\    }
    \\    return __b.items;
    \\}
    \\threadlocal var __rng_state: std.Random.DefaultPrng = undefined;
    \\threadlocal var __rng_ready: bool = false;
    \\fn __mathRandom() f64 {
    \\    if (!__rng_ready) {
    \\        var __anchor: u8 = 0;
    \\        __rng_state = std.Random.DefaultPrng.init(@intFromPtr(&__anchor));
    \\        __rng_ready = true;
    \\    }
    \\    return __rng_state.random().float(f64);
    \\}
;
// Compile-time regex specialization (Plan B): parses a literal pattern at build
// time and emits a pattern-specific straight-line matcher. See regex_specialize.zig.
const regex_specialize = @import("regex_specialize.zig");
const lumen_opt = @import("lumen_opt.zig");
const lumen_emit = @import("lumen_emit.zig");
const emit_analysis = @import("lumen_emit_analysis.zig");
pub const CompileOptions = lumen_emit.CompileOptions;
const emitProgram = lumen_emit.emitProgram;
const collectDestPassable = lumen_opt.collectDestPassable;
const markBuilderParts = lumen_opt.markBuilderParts;
const markAccumulators = lumen_opt.markAccumulators;
const lumen_parser = @import("lumen_parser.zig");
const Parser = lumen_parser.Parser;
const ast = @import("lumen_ast.zig");
const check = @import("lumen_check.zig");
const diag_mod = @import("lumen_diag.zig");
const runtime_fs = @import("lumen_runtime_fs.zig");
const runtime_os = @import("lumen_runtime_os.zig");
const runtime_net = @import("lumen_runtime_net.zig");
const lexer = @import("lumen_lexer.zig");
const types = @import("lumen_types.zig");

pub const CompileError = diag_mod.CompileError;
pub const Diag = diag_mod.Diag;
pub const LineOrigin = diag_mod.LineOrigin;

fn findClassDecl(program: *const ast.Program, name: []const u8) ?*const ast.ClassDecl {
    for (program.stmts) |*stmt| {
        if (stmt.* == .class_decl and std.mem.eql(u8, stmt.class_decl.name, name)) return &stmt.class_decl;
    }
    return null;
}

const Lexer = lexer.Lexer;

/// Builtins that lower to a Zig std wrapper (need __io/__alloc threaded in).
fn setDiag(diag: *Diag, line: u32, col: u32, msg: []const u8) CompileError {
    diag.* = .{ .line = line, .col = col, .msg = msg };
    return error.ParseError;
}

fn rejectUnsupportedDynamic(source: []const u8, diag: *Diag) CompileError!void {
    const eq = std.mem.eql;
    var lex = Lexer{ .src = source };
    var prev_was_dot = false;
    var prev_was_ident = false;
    var pending_dynamic_write_line: u32 = 0;
    var pending_dynamic_write_col: u32 = 0;
    var bracket_depth: u32 = 0;
    var bracket_candidate_line: u32 = 0;
    var bracket_candidate_col: u32 = 0;
    var bracket_has_content = false;

    while (true) {
        const tok = lex.next() catch {
            return setDiag(diag, lex.tok_line, lex.tok_col, lex.err_code orelse "syntax error");
        };
        switch (tok) {
            .eof => return,
            .ident => |name| {
                if (bracket_depth > 0) bracket_has_content = true;
                if (pending_dynamic_write_line != 0) {
                    pending_dynamic_write_line = 0;
                    pending_dynamic_write_col = 0;
                }
                if (eq(u8, name, "eval")) {
                    return setDiag(diag, lex.tok_line, lex.tok_col, "E_UNSUPPORTED_EVAL");
                }
                if (eq(u8, name, "require")) {
                    return setDiag(diag, lex.tok_line, lex.tok_col, "E_UNSUPPORTED_COMMONJS");
                }
                if (prev_was_dot and eq(u8, name, "prototype")) {
                    return setDiag(diag, lex.tok_line, lex.tok_col, "E_UNSUPPORTED_PROTOTYPE");
                }
                // Dotted property writes are validated precisely by the checker
                // (class fields, statics, and setters are allowed; record-shape
                // mutation is rejected there as E_DYNAMIC_PROPERTY_WRITE). Only
                // bracket-indexed writes (`obj["k"] = ...`) are flagged here.
                prev_was_dot = false;
                // A declaration keyword before `[` is array destructuring, not an
                // indexed dynamic write, so it must not start a write candidate.
                // `readonly` before `[` is a `readonly [A, B]` tuple type
                // annotation (spec 052), likewise never an indexed write.
                prev_was_ident = !(eq(u8, name, "let") or eq(u8, name, "const") or eq(u8, name, "var") or eq(u8, name, "readonly"));
            },
            .op => |ch| {
                if (bracket_depth > 0 and ch != '[' and ch != ']') bracket_has_content = true;
                if (ch == '=' and pending_dynamic_write_line != 0) {
                    return setDiag(diag, pending_dynamic_write_line, pending_dynamic_write_col, "indexed assignment (`x[i] = ...`) is not supported — arrays and records are immutable; build a new value instead (e.g. `a = [...a.slice(0, i), v, ...a.slice(i + 1)]`)");
                }
                if (ch == '[' and prev_was_ident and bracket_depth == 0) {
                    bracket_candidate_line = lex.tok_line;
                    bracket_candidate_col = lex.tok_col;
                    bracket_depth = 1;
                    bracket_has_content = false;
                } else if (ch == '[' and bracket_depth > 0) {
                    bracket_depth += 1;
                } else if (ch == ']' and bracket_depth > 0) {
                    bracket_depth -= 1;
                    if (bracket_depth == 0 and bracket_has_content) {
                        pending_dynamic_write_line = bracket_candidate_line;
                        pending_dynamic_write_col = bracket_candidate_col;
                    }
                } else if (pending_dynamic_write_line != 0 and ch != '=') {
                    pending_dynamic_write_line = 0;
                    pending_dynamic_write_col = 0;
                }
                prev_was_dot = ch == '.';
                prev_was_ident = false;
            },
            else => {
                if (bracket_depth > 0) bracket_has_content = true;
                if (pending_dynamic_write_line != 0) {
                    pending_dynamic_write_line = 0;
                    pending_dynamic_write_col = 0;
                }
                prev_was_dot = false;
                prev_was_ident = false;
            },
        }
    }
}

// ── parser ───────────────────────────────────────────────────────────────────

// ── emit ─────────────────────────────────────────────────────────────────────

/// Zig type for an extern (C-ABI) signature slot. Identical to `types.zigName`
/// except a Lumen `string` maps to `[*:0]const u8` (a NUL-terminated C string)
/// rather than the slice `[]const u8`.
pub fn compileToZig(arena: std.mem.Allocator, source: []const u8, filename: []const u8, diag: *Diag) CompileError![]const u8 {
    return compileToZigWithOptions(arena, source, filename, diag, .{});
}

pub fn compileToZigWithOptions(arena: std.mem.Allocator, source: []const u8, filename: []const u8, diag: *Diag, options: CompileOptions) CompileError![]const u8 {
    try rejectUnsupportedDynamic(source, diag);

    var p = try Parser.init(arena, source);
    var program = p.parseProgram() catch |e| {
        diag.* = .{ .line = p.cur_line, .col = p.cur_col, .msg = p.last_err };
        return e;
    };

    try check.checkProgram(arena, &program, diag, options.warnings);

    // Compile append-only string locals into growable buffers (O(n) builds).
    try markAccumulators(program.stmts, &.{}, arena);

    // Destination-passing: builder functions also get an `f__into(dest,…)` form;
    // mark builder calls appended into accumulators so they call it directly.
    var dest_map: std.StringHashMapUnmanaged([]const u8) = .empty;
    try collectDestPassable(program.stmts, &dest_map, arena);
    try markBuilderParts(program.stmts, &dest_map, arena);
    lumen_emit.g_dest_acc = &dest_map;
    defer lumen_emit.g_dest_acc = null;

    // Exception propagation (spec 245): compute which functions can throw
    // (directly or transitively through calls) so they emit as Zig error
    // unions and their call sites unwrap/route the error. Skipped for
    // release-fast builds (no runtime location tracking): throws stay panics.
    var throwing_fns: std.StringHashMapUnmanaged(void) = .empty;
    if (options.runtime_locations) {
        emit_analysis.g_throwing_fns = &throwing_fns;
        emit_analysis.g_method_arena = arena;
        var changed = true;
        while (changed) {
            changed = false;
            for (program.stmts) |*fs| {
                switch (fs.*) {
                    .function_decl => |*f| {
                        if (f.type_params.len > 0) continue; // generic template: only specializations emit
                        if (dest_map.get(f.name) != null) continue; // builder __into twins keep panic semantics
                        if (throwing_fns.get(f.name) != null) continue;
                        if (emit_analysis.bodyCanThrow(f.body)) {
                            try throwing_fns.put(arena, f.name, {});
                            changed = true;
                        }
                    },
                    // Methods key by name across classes ("m:<name>") so call
                    // sites, inherited copies, and super copies stay consistent.
                    // Constructors key per class ("c:<class>"): the class's
                    // resolved ctor chain (own body, or the inherited one).
                    .class_decl => |*c| {
                        for (c.methods) |*m| {
                            if (m.accessor != .none) continue;
                            const key = try std.fmt.allocPrint(arena, "m:{s}", .{m.name});
                            if (throwing_fns.get(key) != null) continue;
                            if (emit_analysis.bodyCanThrow(m.body)) {
                                try throwing_fns.put(arena, key, {});
                                changed = true;
                            }
                        }
                        const ckey = try std.fmt.allocPrint(arena, "c:{s}", .{c.name});
                        if (throwing_fns.get(ckey) == null) {
                            // Resolve the effective ctor: own, else nearest ancestor's.
                            var owner: *const ast.ClassDecl = c;
                            while (!owner.has_ctor) {
                                const pname = owner.parent orelse break;
                                owner = findClassDecl(&program, pname) orelse break;
                            }
                            const throws = if (owner.has_ctor)
                                (if (std.mem.eql(u8, owner.name, c.name))
                                    emit_analysis.bodyCanThrow(owner.ctor_body)
                                else
                                    throwing_fns.get(std.fmt.allocPrint(arena, "c:{s}", .{owner.name}) catch unreachable) != null)
                            else
                                false;
                            if (throws) {
                                try throwing_fns.put(arena, ckey, {});
                                changed = true;
                            }
                        }
                    },
                    else => {},
                }
            }
        }
    }
    defer {
        emit_analysis.g_throwing_fns = null;
        emit_analysis.g_method_arena = null;
    }

    var decls: std.ArrayListUnmanaged(u8) = .empty; // top-level struct type definitions
    var body: std.ArrayListUnmanaged(u8) = .empty;

    // Collect function-value signatures used during emission so we can emit one
    // fat-pointer struct definition per distinct signature.
    var sig_list: std.ArrayListUnmanaged(types.SigEntry) = .empty;
    types.g_sig_registry = &sig_list;
    types.g_sig_arena = arena;
    var tuple_list: std.ArrayListUnmanaged(types.TupleEntry) = .empty;
    types.g_tuple_registry = &tuple_list;
    defer {
        types.g_sig_registry = null;
        types.g_sig_arena = null;
        types.g_tuple_registry = null;
    }

    try emitProgram(&program, &decls, &body, arena, options, diag);

    // The async event loop reads `__io`/`__alloc`, so async programs use I/O
    // plumbing and the `main(__init)` shape even if they never touch other I/O.
    if (program.needs_async) program.uses_io = true;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(arena, "const std = @import(\"std\");\n");
    try out.appendSlice(arena, "var __sa_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);\nfn __sa() std.mem.Allocator { return __sa_arena.allocator(); }\n");
    // JS-semantics parseInt/parseFloat: skip leading whitespace, read an optional
    // sign, then consume the longest valid numeric prefix, ignoring trailing
    // garbage. parseInt honors a `0x` prefix when the radix is 16 or unspecified
    // (radix 0 sentinel). No valid digits -> null (JS NaN).
    try out.appendSlice(arena, PARSE_RT);
    try out.appendSlice(arena, "\n");
    // `number.toPrecision(p)` -> ECMAScript significant-digit formatting. Only
    // emitted when used (short helper, but keeps the prelude minimal).
    if (program.needs_to_precision) {
        try out.appendSlice(arena,
            \\fn __numToPrecision(__x: f64, __p: usize) []const u8 {
            \\    if (__x == 0) {
            \\        if (__p <= 1) return "0";
            \\        return std.fmt.allocPrint(__sa(), "{d:.[1]}", .{ @as(f64, 0), __p - 1 }) catch "0";
            \\    }
            \\    const __neg = __x < 0;
            \\    const __ax = @abs(__x);
            \\    const __e: i32 = @intFromFloat(@floor(@log10(__ax)));
            \\    var __body: []const u8 = undefined;
            \\    if (__e < -6 or __e >= @as(i32, @intCast(__p))) {
            \\        // Exponential notation with p-1 fraction digits, JS '+' sign.
            \\        const __raw = std.fmt.allocPrint(__sa(), "{e:.[1]}", .{ __ax, __p - 1 }) catch return "";
            \\        var __ob: std.ArrayListUnmanaged(u8) = .empty;
            \\        for (__raw, 0..) |__c, __ci| {
            \\            __ob.append(__sa(), __c) catch return "";
            \\            if (__c == 'e' and __ci + 1 < __raw.len and __raw[__ci + 1] != '-') __ob.append(__sa(), '+') catch return "";
            \\        }
            \\        __body = __ob.items;
            \\    } else {
            \\        const __frac: i32 = @as(i32, @intCast(__p)) - 1 - __e;
            \\        const __fd: usize = if (__frac < 0) 0 else @intCast(__frac);
            \\        __body = std.fmt.allocPrint(__sa(), "{d:.[1]}", .{ __ax, __fd }) catch return "";
            \\    }
            \\    if (__neg) return std.mem.concat(__sa(), u8, &.{ "-", __body }) catch return __body;
            \\    return __body;
            \\}
            \\
        );
    }
    // `number.toLocaleString()` -> en-US grouped decimal: comma thousands
    // separators on the integer part, up to 3 trailing-zero-trimmed fraction
    // digits (the ECMAScript default). Emitted only when used.
    if (program.needs_to_locale) {
        try out.appendSlice(arena,
            \\fn __numLocaleString(__x: f64) []const u8 {
            \\    const __neg = __x < 0;
            \\    // Round to 3 fraction digits, then split integer / fraction text.
            \\    const __raw = std.fmt.allocPrint(__sa(), "{d:.3}", .{@abs(__x)}) catch return "";
            \\    const __dot = std.mem.indexOfScalar(u8, __raw, '.') orelse __raw.len;
            \\    const __int = __raw[0..__dot];
            \\    var __frac: []const u8 = if (__dot < __raw.len) __raw[__dot + 1 ..] else "";
            \\    while (__frac.len > 0 and __frac[__frac.len - 1] == '0') __frac = __frac[0 .. __frac.len - 1];
            \\    var __ob: std.ArrayListUnmanaged(u8) = .empty;
            \\    if (__neg) __ob.append(__sa(), '-') catch return "";
            \\    // Group the integer digits into threes from the right.
            \\    for (__int, 0..) |__c, __i| {
            \\        if (__i > 0 and (__int.len - __i) % 3 == 0) __ob.append(__sa(), ',') catch return "";
            \\        __ob.append(__sa(), __c) catch return "";
            \\    }
            \\    if (__frac.len > 0) {
            \\        __ob.append(__sa(), '.') catch return "";
            \\        __ob.appendSlice(__sa(), __frac) catch return "";
            \\    }
            \\    return __ob.items;
            \\}
            \\
        );
    }
    // Regex literal value: the source/flags strings. Matching methods are added in
    // later cycles; for now it carries `.source` and `.flags`. Only emitted when
    // the program actually uses a regex -- the runtime's short capture names
    // (`f`, `p`, `s`, ...) would otherwise shadow like-named user functions.
    if (program.uses_regex) {
        try out.appendSlice(arena, "const __LumenRegExp = struct { source: []const u8, flags: []const u8 };\n");
        try out.appendSlice(arena, REGEX_RT);
        try out.appendSlice(arena, "\n");
    }
    // Async programs run their event loop on libxev (a pure-Zig dependency: no
    // system install, unlike the libuv this replaced). The CLI auto-fetches it
    // and injects `-Mxev=...` into the native build whenever a program uses
    // async, so this import resolves without any user configuration.
    // spec 049: `http.createServer`'s concurrent-serving codegen also needs
    // libxev, for its standalone `ThreadPool` (not the event loop) -- but
    // only on native targets; see `CompileOptions.wasm`'s doc comment for
    // why the import is skipped entirely under `--wasm`.
    const needs_http_threadpool = program.needs_http_server and !options.wasm;
    if (program.needs_async or needs_http_threadpool) {
        try out.appendSlice(arena, "const xev = @import(\"xev\");\n");
    }

    // I/O plumbing is hoisted to file scope so builtins (arg, fs, httpGet, …)
    // work inside functions, not just at the top level. `main` assigns these.
    if (program.uses_io) {
        try out.appendSlice(arena, "var __io: std.Io = undefined;\n");
        try out.appendSlice(arena, "var __alloc: std.mem.Allocator = std.heap.page_allocator;\n");
    }
    if (program.needs_args) {
        try out.appendSlice(arena, "var __lumen_argv: []const []const u8 = &.{};\n");
    }
    if (program.needs_process_api) {
        try out.appendSlice(arena, "var __environ: std.process.Environ = .empty;\n");
    }

    if (options.runtime_locations) {
        // Sanitize the filename for a Zig string literal (backslashes/quotes break it).
        const safe_name = try arena.dupe(u8, filename);
        for (safe_name) |*ch| if (ch.* == '\\' or ch.* == '"') {
            ch.* = '/';
        };

        try out.print(arena, "const __lumen_file = \"{s}\";\n", .{safe_name});
        // Where execution is, what is being thrown, and why: all of it belongs to
        // one call stack, and a program with an `http.createServer` has as many
        // call stacks as the connection pool has worker threads (spec 468). Kept
        // process-global, two handlers running at once interleave their writes to
        // these: one handler's `throw` is read by another's `catch`, and the two
        // depth counters collide badly enough to underflow `__lumen_depth` and
        // abort the whole server. `threadlocal` is the honest description of what
        // this state is -- per call stack, not per process -- and costs a
        // register-offset load rather than a lock. `__lumen_color` stays global:
        // `main` writes it once before any thread exists and nothing writes it
        // again, so every thread wants the same answer.
        try out.appendSlice(arena, "threadlocal var __lumen_line: u32 = 0;\nthreadlocal var __lumen_col: u32 = 0;\nthreadlocal var __lumen_throwing: bool = false;\nvar __lumen_color: bool = false;\nthreadlocal var __lumen_err_msg: []const u8 = \"\";\n");
        // Call-stack frames for runtime stack traces. Each user function pushes a
        // frame on entry (recording its name and the caller's statement position,
        // i.e. the call site) and pops on exit. Depth keeps counting past the
        // fixed capacity so a deep recursion still reports its true depth.
        try out.appendSlice(arena,
            \\const __LumenFrame = struct { name: []const u8, line: u32, col: u32 };
            \\threadlocal var __lumen_stack: [128]__LumenFrame = undefined;
            \\threadlocal var __lumen_depth: usize = 0;
            \\fn __lumenPush(name: []const u8) void {
            \\    if (__lumen_depth < __lumen_stack.len) __lumen_stack[__lumen_depth] = .{ .name = name, .line = __lumen_line, .col = __lumen_col };
            \\    __lumen_depth += 1;
            \\}
            \\fn __lumenPop() void {
            \\    // While an exception unwinds (error return), keep the frames so
            \\    // an uncaught error still prints the full throw-site trace; a
            \\    // catch restores the depth it saved at try entry.
            \\    if (__lumen_throwing) return;
            \\    __lumen_depth -= 1;
            \\}
            \\
        );
        // Embed the .ts source as a multiline string (no escaping needed) so the handler can show the line.
        try out.appendSlice(arena, "const __lumen_src =\n");
        {
            var lines = std.mem.splitScalar(u8, source, '\n');
            while (lines.next()) |l| {
                const t = std.mem.trimEnd(u8, l, "\r");
                try out.print(arena, "    \\\\{s}\n", .{t});
            }
        }
        try out.appendSlice(arena, ";\n");
        // Origin table for import-inlined programs: maps a merged-source line
        // back to the file/line the user wrote, so runtime errors and stack
        // frames report real positions. Identity when there are no imports.
        try out.appendSlice(arena, "const __LumenOrigin = struct { file: []const u8, line: u32 };\n");
        if (options.line_map.len > 0) {
            try out.appendSlice(arena, "const __lumen_origins = [_]__LumenOrigin{\n");
            for (options.line_map) |o| {
                const safe_file = try arena.dupe(u8, o.file);
                for (safe_file) |*ch| if (ch.* == '\\' or ch.* == '"') {
                    ch.* = '/';
                };
                var display: []const u8 = safe_file;
                while (std.mem.startsWith(u8, display, "./")) display = display[2..];
                try out.print(arena, "    .{{ .file = \"{s}\", .line = {d} }},\n", .{ display, o.line });
            }
            try out.appendSlice(arena, "};\n");
            try out.appendSlice(arena,
                \\fn __lumenOrigin(line: u32) __LumenOrigin {
                \\    if (line >= 1 and line - 1 < __lumen_origins.len) return __lumen_origins[line - 1];
                \\    return .{ .file = __lumen_file, .line = line };
                \\}
                \\
            );
        } else {
            try out.appendSlice(arena,
                \\fn __lumenOrigin(line: u32) __LumenOrigin {
                \\    return .{ .file = __lumen_file, .line = line };
                \\}
                \\
            );
        }
        // Custom panic handler -> map the native runtime error back to the .ts source: file:line:col +
        // the offending source line + a caret.
        try out.appendSlice(arena,
            \\fn __lumenPanic(msg: []const u8, _: ?usize) noreturn {
            \\    const __kind: []const u8 = if (__lumen_throwing) "Uncaught Error" else "runtime error";
            \\    const __cc: []const u8 = if (__lumen_color) "\x1b[36m" else "";
            \\    const __cr: []const u8 = if (__lumen_color) "\x1b[1;31m" else "";
            \\    const __cg: []const u8 = if (__lumen_color) "\x1b[32m" else "";
            \\    const __cd: []const u8 = if (__lumen_color) "\x1b[2m" else "";
            \\    const __c0: []const u8 = if (__lumen_color) "\x1b[0m" else "";
            \\    const __org = __lumenOrigin(__lumen_line);
            \\    std.debug.print("\n{s}{s}:{d}:{d}:{s} {s}{s}:{s} {s}\n", .{ __cc, __org.file, __org.line, __lumen_col, __c0, __cr, __kind, __c0, msg });
            \\    var __it = std.mem.splitScalar(u8, __lumen_src, '\n');
            \\    var __n: u32 = 1;
            \\    while (__it.next()) |__l| : (__n += 1) {
            \\        if (__n == __lumen_line) {
            \\            std.debug.print("{s}  {d} |{s} {s}\n{s}    |{s} ", .{ __cd, __org.line, __c0, __l, __cd, __c0 });
            \\            var __k: u32 = 1;
            \\            while (__k < __lumen_col) : (__k += 1) std.debug.print(" ", .{});
            \\            std.debug.print("{s}^{s}\n", .{ __cg, __c0 });
            \\            break;
            \\        }
            \\    }
            \\    // Call-stack trace, innermost frame first. Each frame's shown
            \\    // location is where execution currently is inside it: the failing
            \\    // statement for the innermost, the call site for outer frames.
            \\    if (__lumen_depth > 0) {
            \\        var __loc_line = __lumen_line;
            \\        var __loc_col = __lumen_col;
            \\        var __k = @min(__lumen_depth, __lumen_stack.len);
            \\        if (__lumen_depth > __lumen_stack.len) {
            \\            std.debug.print("    ... {d} deeper frames omitted\n", .{__lumen_depth - __lumen_stack.len});
            \\        }
            \\        while (__k > 0) {
            \\            __k -= 1;
            \\            const __fo = __lumenOrigin(__loc_line);
            \\            std.debug.print("    at {s} ({s}:{d}:{d})\n", .{ __lumen_stack[__k].name, __fo.file, __fo.line, __loc_col });
            \\            __loc_line = __lumen_stack[__k].line;
            \\            __loc_col = __lumen_stack[__k].col;
            \\        }
            \\        const __mo = __lumenOrigin(__loc_line);
            \\        std.debug.print("    at <main> ({s}:{d}:{d})\n", .{ __mo.file, __mo.line, __loc_col });
            \\    }
            \\    std.process.exit(1);
            \\}
            \\pub const panic = std.debug.FullPanic(__lumenPanic);
            \\
        );
    }
    // Emit a fat-pointer struct per function-value signature. Iterate by index
    // because emitting a signature's param/return types can register more.
    {
        var i: usize = 0;
        while (i < sig_list.items.len) : (i += 1) {
            const entry = sig_list.items[i];
            try out.print(arena, "const {s} = struct {{ ctx: *const anyopaque, call: *const fn (*const anyopaque", .{entry.name});
            for (entry.sig.params) |param_ty| try out.print(arena, ", {s}", .{try types.zigName(arena, param_ty)});
            try out.print(arena, ") {s} }};\n", .{try types.zigName(arena, entry.sig.ret.*)});
        }
    }
    // Emit one nominal struct per distinct tuple shape. Iterate by index because
    // emitting an element type can register a nested tuple shape.
    {
        var i: usize = 0;
        while (i < tuple_list.items.len) : (i += 1) {
            const entry = tuple_list.items[i];
            try out.print(arena, "const {s} = struct {{ ", .{entry.name});
            for (entry.elems, 0..) |el, j| {
                try out.print(arena, "@\"{d}\": {s}, ", .{ j, try types.zigName(arena, el) });
            }
            try out.appendSlice(arena, "};\n");
        }
    }
    if (program.needs_map or program.needs_set) {
        // Value equality that treats `[]const u8` (strings) specially.
        try out.appendSlice(arena,
            \\fn __lumenEql(comptime T: type, a: T, b: T) bool {
            \\    if (T == []const u8) return std.mem.eql(u8, a, b);
            \\    return a == b;
            \\}
            \\
        );
    }
    if (program.needs_map) {
        // Insertion-ordered Map<K, V>: linear-probe over parallel key/value lists
        // so keys()/values()/forEach iterate in insertion order deterministically.
        try out.appendSlice(arena,
            \\fn LumenMap(comptime K: type, comptime V: type) type {
            \\    return struct {
            \\        const Self = @This();
            \\        keys_: std.ArrayListUnmanaged(K) = .empty,
            \\        values_: std.ArrayListUnmanaged(V) = .empty,
            \\        fn __init() *Self {
            \\            const p = __sa().create(Self) catch unreachable;
            \\            p.* = .{};
            \\            return p;
            \\        }
            \\        fn __find(self: *Self, key: K) ?usize {
            \\            for (self.keys_.items, 0..) |k, i| { if (__lumenEql(K, k, key)) return i; }
            \\            return null;
            \\        }
            \\        fn set(self: *Self, key: K, value: V) void {
            \\            if (self.__find(key)) |i| { self.values_.items[i] = value; return; }
            \\            self.keys_.append(__sa(), key) catch unreachable;
            \\            self.values_.append(__sa(), value) catch unreachable;
            \\        }
            \\        fn get(self: *Self, key: K) ?V {
            \\            if (self.__find(key)) |i| return self.values_.items[i];
            \\            return null;
            \\        }
            \\        fn has(self: *Self, key: K) bool { return self.__find(key) != null; }
            \\        fn delete(self: *Self, key: K) bool {
            \\            if (self.__find(key)) |i| {
            \\                _ = self.keys_.orderedRemove(i);
            \\                _ = self.values_.orderedRemove(i);
            \\                return true;
            \\            }
            \\            return false;
            \\        }
            \\        fn size(self: *Self) i32 { return @intCast(self.keys_.items.len); }
            \\        fn clear(self: *Self) void { self.keys_.clearRetainingCapacity(); self.values_.clearRetainingCapacity(); }
            \\        fn keys(self: *Self) []const K { return self.keys_.items; }
            \\        fn values(self: *Self) []const V { return self.values_.items; }
            \\        fn forEach(self: *Self, cb: anytype) void {
            \\            const __np = @typeInfo(@typeInfo(@TypeOf(cb.call)).pointer.child).@"fn".params.len;
            \\            for (self.keys_.items, 0..) |k, i| {
            \\                if (__np == 3) { _ = cb.call(cb.ctx, self.values_.items[i], k); }
            \\                else { _ = cb.call(cb.ctx, self.values_.items[i]); }
            \\            }
            \\        }
            \\    };
            \\}
            \\
        );
    }
    if (program.needs_set) {
        // Insertion-ordered Set<T>.
        try out.appendSlice(arena,
            \\fn LumenSet(comptime T: type) type {
            \\    return struct {
            \\        const Self = @This();
            \\        items_: std.ArrayListUnmanaged(T) = .empty,
            \\        fn __init() *Self {
            \\            const p = __sa().create(Self) catch unreachable;
            \\            p.* = .{};
            \\            return p;
            \\        }
            \\        fn __find(self: *Self, value: T) ?usize {
            \\            for (self.items_.items, 0..) |v, i| { if (__lumenEql(T, v, value)) return i; }
            \\            return null;
            \\        }
            \\        fn add(self: *Self, value: T) void {
            \\            if (self.__find(value) != null) return;
            \\            self.items_.append(__sa(), value) catch unreachable;
            \\        }
            \\        fn has(self: *Self, value: T) bool { return self.__find(value) != null; }
            \\        fn delete(self: *Self, value: T) bool {
            \\            if (self.__find(value)) |i| { _ = self.items_.orderedRemove(i); return true; }
            \\            return false;
            \\        }
            \\        fn size(self: *Self) i32 { return @intCast(self.items_.items.len); }
            \\        fn clear(self: *Self) void { self.items_.clearRetainingCapacity(); }
            \\        fn values(self: *Self) []const T { return self.items_.items; }
            \\        fn keys(self: *Self) []const T { return self.items_.items; }
            \\        fn forEach(self: *Self, cb: anytype) void {
            \\            for (self.items_.items) |v| { _ = cb.call(cb.ctx, v); }
            \\        }
            \\    };
            \\}
            \\
        );
    }
    if (program.needs_event_emitter) {
        // EventEmitter<T> (spec 043): one payload type T shared by every
        // event name on an instance (Lumen has no way to give each string
        // key its own listener signature the way Node's untyped emitter
        // does). Listener storage is a Zig-internal StringHashMap of
        // growable listener lists -- Lumen's own array type has no push
        // support yet, but that's invisible here since none of this is
        // constructed via Lumen array syntax.
        try out.appendSlice(arena,
            \\fn LumenEventEmitter(comptime T: type) type {
            \\    const CallFn = *const fn (*const anyopaque, T) void;
            \\    const Listener = struct { ctx: *const anyopaque, call: CallFn, once: bool };
            \\    return struct {
            \\        const Self = @This();
            \\        listeners: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Listener)) = .empty,
            \\        fn __init() *Self {
            \\            const p = __sa().create(Self) catch unreachable;
            \\            p.* = .{};
            \\            return p;
            \\        }
            \\        fn __add(self: *Self, name: []const u8, listener: anytype, is_once: bool) void {
            \\            const gop = self.listeners.getOrPut(__sa(), name) catch unreachable;
            \\            if (!gop.found_existing) gop.value_ptr.* = .empty;
            \\            gop.value_ptr.append(__sa(), .{ .ctx = listener.ctx, .call = listener.call, .once = is_once }) catch unreachable;
            \\        }
            \\        fn on(self: *Self, name: []const u8, listener: anytype) void {
            \\            self.__add(name, listener, false);
            \\        }
            \\        fn once(self: *Self, name: []const u8, listener: anytype) void {
            \\            self.__add(name, listener, true);
            \\        }
            \\        fn emit(self: *Self, name: []const u8, value: T) void {
            \\            const list = self.listeners.getPtr(name) orelse return;
            \\            var has_once = false;
            \\            for (list.items) |l| {
            \\                l.call(l.ctx, value);
            \\                if (l.once) has_once = true;
            \\            }
            \\            if (!has_once) return;
            \\            var keep: std.ArrayListUnmanaged(Listener) = .empty;
            \\            for (list.items) |l| {
            \\                if (!l.once) keep.append(__sa(), l) catch unreachable;
            \\            }
            \\            list.deinit(__sa());
            \\            list.* = keep;
            \\        }
            \\        fn removeAllListeners(self: *Self) void {
            \\            var it = self.listeners.valueIterator();
            \\            while (it.next()) |list| list.clearRetainingCapacity();
            \\        }
            \\        fn removeListenersFor(self: *Self, name: []const u8) void {
            \\            if (self.listeners.getPtr(name)) |list| list.clearRetainingCapacity();
            \\        }
            \\        fn listenerCount(self: *Self, name: []const u8) i32 {
            \\            if (self.listeners.get(name)) |list| return @intCast(list.items.len);
            \\            return 0;
            \\        }
            \\    };
            \\}
            \\
        );
    }
    if (program.needs_async) {
        // The event loop is libxev. `setTimeout` schedules an `xev.Timer`;
        // `await` drives the loop one event at a time (`loop.run(.once)`) until
        // the awaited promise resolves, then reads its value; the program ends by
        // draining remaining work with `loop.run(.until_done)`. This is sound for
        // the supported subset (already-resolved and timer-resolved promises) and
        // keeps timer ordering deterministic (libxev, like libuv, fires
        // equal-deadline timers in start order).
        try out.appendSlice(arena,
            \\var __xev_loop: xev.Loop = undefined;
            \\const LumenLoop = struct {
            \\    fn init() void { __xev_loop = xev.Loop.init(.{}) catch unreachable; }
            \\    fn driveUntil(ctx: *const anyopaque, done: *const fn (*const anyopaque) bool) void {
            \\        while (!done(ctx)) {
            \\            __xev_loop.run(.once) catch break;
            \\        }
            \\    }
            \\    fn drain() void { __xev_loop.run(.until_done) catch {}; }
            \\};
            \\fn LumenPromise(comptime T: type) type {
            \\    return struct {
            \\        const Self = @This();
            \\        resolved: bool = false,
            \\        value: T = undefined,
            \\        fn create() *Self {
            \\            const p = __alloc.create(Self) catch unreachable;
            \\            p.* = .{};
            \\            return p;
            \\        }
            \\        fn resolve(self: *Self, v: T) void { self.resolved = true; self.value = v; }
            \\        fn isResolved(ctx: *const anyopaque) bool {
            \\            const self: *const Self = @ptrCast(@alignCast(ctx));
            \\            return self.resolved;
            \\        }
            \\        fn await_(self: *Self) T {
            \\            LumenLoop.driveUntil(self, isResolved);
            \\            return self.value;
            \\        }
            \\    };
            \\}
            \\fn __promiseResolved(comptime T: type, v: T) *LumenPromise(T) {
            \\    const p = LumenPromise(T).create();
            \\    p.resolve(v);
            \\    return p;
            \\}
            \\const __TimerCancelFlag = struct { cancelled: bool = false };
            \\var __timer_ids: std.AutoHashMapUnmanaged(i32, *__TimerCancelFlag) = .empty;
            \\var __timer_next_id: i32 = 1;
            \\fn __timerRegister(flag: *__TimerCancelFlag) i32 {
            \\    const id = __timer_next_id;
            \\    __timer_next_id += 1;
            \\    __timer_ids.put(__alloc, id, flag) catch {};
            \\    return id;
            \\}
            \\fn __clearTimer(id: i32) void {
            \\    if (__timer_ids.get(id)) |flag| flag.cancelled = true;
            \\}
            \\fn __setTimeout(cb: anytype, ms: i64) i32 {
            \\    const Cb = @TypeOf(cb);
            \\    const Holder = struct {
            \\        f: Cb,
            \\        timer: xev.Timer,
            \\        completion: xev.Completion = undefined,
            \\        flag: *__TimerCancelFlag,
            \\        fn onTimer(ud: ?*@This(), loop: *xev.Loop, c: *xev.Completion, result: xev.Timer.RunError!void) xev.CallbackAction {
            \\            _ = loop;
            \\            _ = c;
            \\            _ = result catch {};
            \\            if (!ud.?.flag.cancelled) ud.?.f.call(ud.?.f.ctx);
            \\            return .disarm;
            \\        }
            \\    };
            \\    const flag = __alloc.create(__TimerCancelFlag) catch unreachable;
            \\    flag.* = .{};
            \\    const h = __alloc.create(Holder) catch unreachable;
            \\    h.* = .{ .f = cb, .timer = xev.Timer.init() catch unreachable, .flag = flag };
            \\    const delay: u64 = if (ms > 0) @intCast(ms) else 0;
            \\    h.timer.run(&__xev_loop, &h.completion, delay, Holder, h, Holder.onTimer);
            \\    return __timerRegister(flag);
            \\}
            \\fn __setInterval(cb: anytype, ms: i64) i32 {
            \\    const Cb = @TypeOf(cb);
            \\    const Holder = struct {
            \\        f: Cb,
            \\        timer: xev.Timer,
            \\        completion: xev.Completion = undefined,
            \\        flag: *__TimerCancelFlag,
            \\        delay: u64,
            \\        fn onTimer(ud: ?*@This(), loop: *xev.Loop, c: *xev.Completion, result: xev.Timer.RunError!void) xev.CallbackAction {
            \\            _ = loop;
            \\            _ = c;
            \\            _ = result catch {};
            \\            const self = ud.?;
            \\            if (self.flag.cancelled) return .disarm;
            \\            self.f.call(self.f.ctx);
            \\            if (self.flag.cancelled) return .disarm;
            \\            self.timer.run(&__xev_loop, &self.completion, self.delay, @This(), self, onTimer);
            \\            return .disarm;
            \\        }
            \\    };
            \\    const flag = __alloc.create(__TimerCancelFlag) catch unreachable;
            \\    flag.* = .{};
            \\    const delay: u64 = if (ms > 0) @intCast(ms) else 0;
            \\    const h = __alloc.create(Holder) catch unreachable;
            \\    h.* = .{ .f = cb, .timer = xev.Timer.init() catch unreachable, .flag = flag, .delay = delay };
            \\    h.timer.run(&__xev_loop, &h.completion, delay, Holder, h, Holder.onTimer);
            \\    return __timerRegister(flag);
            \\}
            \\
        );
    }
    try runtime_fs.emitFsRuntime(arena, &out, &program, options, decls.items);
    try runtime_os.emitStdioRuntime(arena, &out, &program, options);
    try runtime_net.emitNetRuntime(arena, &out, &program, options);
    try runtime_os.emitOsCryptoRuntime(arena, &out, &program, options);
    if (program.uses_io) {
        try out.appendSlice(arena, "pub fn main(__init: std.process.Init) !void {\n");
        try out.appendSlice(arena, "    __io = __init.io;\n    __alloc = __init.arena.allocator();\n");
        // `__lumen_color` only exists when runtime location/diagnostic globals are
        // emitted (release-fast omits them), so gate its initialization to match.
        if (options.runtime_locations) {
            try out.appendSlice(arena, "    __lumen_color = (__init.environ_map.get(\"NO_COLOR\") == null) and (std.Io.File.stderr().isTty(__init.io) catch false);\n");
        }
        if (program.needs_args) {
            try out.appendSlice(arena, "    __lumen_argv = __init.minimal.args.toSlice(__alloc) catch std.process.exit(1);\n");
        }
        if (program.needs_process_api) {
            try out.appendSlice(arena, "    __environ = __init.minimal.environ;\n");
        }
        if (program.needs_process_uptime) {
            try out.appendSlice(arena, "    __process_start_ns = @intCast(std.Io.Clock.now(.awake, __io).nanoseconds);\n");
        }
        if (program.needs_async) {
            try out.appendSlice(arena, "    LumenLoop.init();\n");
        }
        if (program.needs_thread_pool_fs) {
            try out.appendSlice(arena, "    __fsThreadPoolInit();\n");
        }
        if (program.needs_worker) {
            try out.appendSlice(arena, "    __workerInit();\n");
        }
    } else {
        try out.appendSlice(arena, "pub fn main() void {\n");
    }
    try out.appendSlice(arena, body.items);
    if (program.needs_thread_pool_fs or program.needs_worker) {
        // LumenLoop.drain() (below) runs the loop with RunMode.until_done,
        // whose only stop condition is "no active completions left"
        // (verified by reading the io_uring backend's tick_ directly). The
        // xev.Async wait this program registers to bridge thread-pool
        // completions back to the main thread is deliberately persistent
        // (it re-arms every time, by design -- it has to stay armed to
        // catch *future* completions), so it never lets that count reach
        // zero: drain() would hang forever. Any explicit `await` the user
        // wrote has already run by this point in `main`'s body anyway, so
        // this skips drain and exits directly -- the same "exit rather than
        // wait for a background thread pool to naturally join" shape most
        // programs with one use. xev.ThreadPool's own worker threads block
        // forever waiting for more work otherwise, with nothing to join
        // them once there's no more application work left. Worker.run's own
        // detached std.Thread.spawn workers have the same problem for the
        // same reason (nothing left to join them once main work is done),
        // so needs_worker shares this exact exit-early branch.
        try out.appendSlice(arena, "    std.process.exit(0);\n");
    } else if (program.needs_async) {
        // Drain any remaining timers/microtasks so fire-and-forget
        // setTimeout callbacks run before the program exits.
        try out.appendSlice(arena, "    LumenLoop.drain();\n");
    }
    try out.appendSlice(arena, "}\n");
    return out.items;
}
