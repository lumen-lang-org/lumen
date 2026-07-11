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
const lexer = @import("lumen_lexer.zig");
const types = @import("lumen_types.zig");

pub const CompileError = diag_mod.CompileError;
pub const Diag = diag_mod.Diag;
pub const LineOrigin = diag_mod.LineOrigin;

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
                    return setDiag(diag, pending_dynamic_write_line, pending_dynamic_write_col, "E_DYNAMIC_PROPERTY_WRITE");
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
                        if (f.is_async) continue;
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
                    .class_decl => |*c| for (c.methods) |*m| {
                        if (m.accessor != .none) continue;
                        if (m.is_async) continue;
                        const key = try std.fmt.allocPrint(arena, "m:{s}", .{m.name});
                        if (throwing_fns.get(key) != null) continue;
                        if (emit_analysis.bodyCanThrow(m.body)) {
                            try throwing_fns.put(arena, key, {});
                            changed = true;
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

    try emitProgram(&program, &decls, &body, arena, options);

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
        try out.appendSlice(arena, "var __lumen_line: u32 = 0;\nvar __lumen_col: u32 = 0;\nvar __lumen_throwing: bool = false;\nvar __lumen_color: bool = false;\nvar __lumen_err_msg: []const u8 = \"\";\n");
        // Call-stack frames for runtime stack traces. Each user function pushes a
        // frame on entry (recording its name and the caller's statement position,
        // i.e. the call site) and pops on exit. Depth keeps counting past the
        // fixed capacity so a deep recursion still reports its true depth.
        try out.appendSlice(arena,
            \\const __LumenFrame = struct { name: []const u8, line: u32, col: u32 };
            \\var __lumen_stack: [128]__LumenFrame = undefined;
            \\var __lumen_depth: usize = 0;
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
            \\            for (self.keys_.items, 0..) |k, i| { _ = cb.call(cb.ctx, self.values_.items[i], k); }
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
    if (program.needs_async_read_file) {
        // `fs.readFile` -- true async read on libxev's io_uring backend (no
        // thread pool, unlike fs.readFileSync's synchronous std.Io.Dir call or
        // Node's libuv-backed fs.readFile, which is always thread-pool-based).
        // The open is synchronous (a fast metadata-only syscall); the read loop
        // (pread at increasing offsets into a fixed chunk, accumulating into a
        // growable buffer until a zero-length read) is fully async, resolving
        // the returned Promise<string> on completion.
        try out.appendSlice(arena,
            \\const __ReadFileChunk = 65536;
            \\const __ReadFileState = struct {
            \\    file: xev.File,
            \\    promise: *LumenPromise([]const u8),
            \\    buf: std.ArrayListUnmanaged(u8) = .empty,
            \\    chunk: [__ReadFileChunk]u8 = undefined,
            \\    offset: u64 = 0,
            \\    completion: xev.Completion = undefined,
            \\    close_completion: xev.Completion = undefined,
            \\    fn onRead(ud: ?*__ReadFileState, loop: *xev.Loop, c: *xev.Completion, file: xev.File, rb: xev.ReadBuffer, result: xev.ReadError!usize) xev.CallbackAction {
            \\        _ = loop;
            \\        _ = c;
            \\        _ = rb;
            \\        const st = ud.?;
            \\        const n = result catch 0;
            \\        if (n == 0) {
            \\            st.promise.resolve(st.buf.toOwnedSlice(__alloc) catch "");
            \\            file.close(&__xev_loop, &st.close_completion, void, null, struct {
            \\                fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: xev.File, _: xev.CloseError!void) xev.CallbackAction {
            \\                    return .disarm;
            \\                }
            \\            }.cb);
            \\            return .disarm;
            \\        }
            \\        st.buf.appendSlice(__alloc, st.chunk[0..n]) catch {};
            \\        st.offset += n;
            \\        st.file.pread(&__xev_loop, &st.completion, .{ .slice = &st.chunk }, st.offset, __ReadFileState, st, onRead);
            \\        return .disarm;
            \\    }
            \\};
            \\fn __readFileAsync(path: []const u8) *LumenPromise([]const u8) {
            \\    const p = LumenPromise([]const u8).create();
            \\    const sync_file = std.Io.Dir.cwd().openFile(__io, path, .{ .mode = .read_only }) catch {
            \\        p.resolve("");
            \\        return p;
            \\    };
            \\    const xf = xev.File.init(sync_file) catch {
            \\        p.resolve("");
            \\        return p;
            \\    };
            \\    const st = __alloc.create(__ReadFileState) catch unreachable;
            \\    st.* = .{ .file = xf, .promise = p };
            \\    st.file.pread(&__xev_loop, &st.completion, .{ .slice = &st.chunk }, 0, __ReadFileState, st, __ReadFileState.onRead);
            \\    return p;
            \\}
            \\
        );
    }
    if (program.needs_async_write_file) {
        // `fs.writeFile` -- the async counterpart to `fs.readFile`. The open
        // (create/truncate) is a fast synchronous metadata call; the write
        // loop (pwrite at increasing offsets, looping on a short write) is
        // fully async, resolving the returned Promise<void> on completion.
        try out.appendSlice(arena,
            \\const __WriteFileState = struct {
            \\    file: xev.File,
            \\    promise: *LumenPromise(void),
            \\    data: []const u8,
            \\    // Where in the file writing starts -- 0 for writeFile, the
            \\    // pre-write file size for appendFile. `offset` below always
            \\    // tracks bytes of `data` written so far, relative to this.
            \\    base_offset: u64 = 0,
            \\    offset: u64 = 0,
            \\    completion: xev.Completion = undefined,
            \\    close_completion: xev.Completion = undefined,
            \\    fn onWrite(ud: ?*__WriteFileState, loop: *xev.Loop, c: *xev.Completion, file: xev.File, wb: xev.WriteBuffer, result: xev.WriteError!usize) xev.CallbackAction {
            \\        _ = loop;
            \\        _ = c;
            \\        _ = wb;
            \\        const st = ud.?;
            \\        const n = result catch 0;
            \\        st.offset += n;
            \\        if (n == 0 or st.offset >= st.data.len) {
            \\            st.promise.resolve({});
            \\            file.close(&__xev_loop, &st.close_completion, void, null, struct {
            \\                fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: xev.File, _: xev.CloseError!void) xev.CallbackAction {
            \\                    return .disarm;
            \\                }
            \\            }.cb);
            \\            return .disarm;
            \\        }
            \\        st.file.pwrite(&__xev_loop, &st.completion, .{ .slice = st.data[st.offset..] }, st.base_offset + st.offset, __WriteFileState, st, onWrite);
            \\        return .disarm;
            \\    }
            \\};
            \\fn __writeFileStart(p: *LumenPromise(void), sync_file: std.Io.File, data: []const u8, base_offset: u64) void {
            \\    const xf = xev.File.init(sync_file) catch {
            \\        p.resolve({});
            \\        return;
            \\    };
            \\    if (data.len == 0) {
            \\        p.resolve({});
            \\        xf.close(&__xev_loop, &(__alloc.create(xev.Completion) catch unreachable).*, void, null, struct {
            \\            fn cb(_: ?*void, _: *xev.Loop, _: *xev.Completion, _: xev.File, _: xev.CloseError!void) xev.CallbackAction {
            \\                return .disarm;
            \\            }
            \\        }.cb);
            \\        return;
            \\    }
            \\    const st = __alloc.create(__WriteFileState) catch unreachable;
            \\    st.* = .{ .file = xf, .promise = p, .data = data, .base_offset = base_offset };
            \\    st.file.pwrite(&__xev_loop, &st.completion, .{ .slice = data }, base_offset, __WriteFileState, st, __WriteFileState.onWrite);
            \\}
            \\fn __writeFileAsync(path: []const u8, data: []const u8) *LumenPromise(void) {
            \\    const p = LumenPromise(void).create();
            \\    const sync_file = std.Io.Dir.cwd().createFile(__io, path, .{}) catch {
            \\        p.resolve({});
            \\        return p;
            \\    };
            \\    __writeFileStart(p, sync_file, data, 0);
            \\    return p;
            \\}
            \\
        );
    }
    if (program.needs_async_append_file) {
        // `fs.appendFile` -- same async write loop as `fs.writeFile`, just
        // starting past the file's existing content instead of at 0. There is
        // no seek/append-mode primitive to lean on here, so the existing size
        // is read with one fast synchronous stat before the async loop starts.
        try out.appendSlice(arena,
            \\fn __appendFileAsync(path: []const u8, data: []const u8) *LumenPromise(void) {
            \\    const p = LumenPromise(void).create();
            \\    const existing_size: u64 = if (std.Io.Dir.cwd().statFile(__io, path, .{}) catch null) |st| st.size else 0;
            \\    const sync_file = std.Io.Dir.cwd().createFile(__io, path, .{ .truncate = false }) catch {
            \\        p.resolve({});
            \\        return p;
            \\    };
            \\    __writeFileStart(p, sync_file, data, existing_size);
            \\    return p;
            \\}
            \\
        );
    }
    try out.appendSlice(arena, decls.items);

    if (program.needs_read_file_sync) {
        try out.appendSlice(arena,
            \\fn __readFileSync(io: std.Io, alloc: std.mem.Allocator, path: []const u8) []const u8 {
            \\    return std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(16 * 1024 * 1024)) catch "";
            \\}
            \\
        );
    }
    if (program.needs_exists_sync) {
        try out.appendSlice(arena,
            \\fn __existsSync(io: std.Io, path: []const u8) bool {
            \\    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
            \\    return true;
            \\}
            \\
        );
    }
    if (program.needs_realpath_sync) {
        // fs.realpathSync (spec 031 revisited): earlier notes assumed this
        // was blocked ("only a raw libc binding exists, not wrapped by the
        // runtime's I/O layer"), but that turned out to be stale -- this
        // Zig version's std.Io.Dir has a real, working realPathFileAlloc
        // (dispatching to a genuine per-OS implementation, not a stub;
        // confirmed by reading the Io.Threaded backend directly). Falls
        // back to returning path unchanged on error (nonexistent path,
        // permissions, ...), the same "fallback, don't crash" shape every
        // other fs function uses.
        try out.appendSlice(arena,
            \\fn __realpathSync(io: std.Io, alloc: std.mem.Allocator, path: []const u8) []const u8 {
            \\    return std.Io.Dir.cwd().realPathFileAlloc(io, path, alloc) catch (alloc.dupe(u8, path) catch path);
            \\}
            \\
        );
    }
    if (program.needs_write_file_sync) {
        try out.appendSlice(arena,
            \\fn __writeFileSync(io: std.Io, path: []const u8, data: []const u8) void {
            \\    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch {};
            \\}
            \\
        );
    }
    if (program.needs_append_file_sync) {
        // No direct append API on this std.Io.Dir; read the existing content (if
        // any), concatenate, and rewrite. Fine for sync, single-writer use.
        try out.appendSlice(arena,
            \\fn __appendFileSync(io: std.Io, alloc: std.mem.Allocator, path: []const u8, data: []const u8) void {
            \\    const existing = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 * 1024 * 1024)) catch "";
            \\    const combined = std.mem.concat(alloc, u8, &.{ existing, data }) catch return;
            \\    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = combined }) catch {};
            \\}
            \\
        );
    }
    if (program.needs_mkdir_sync) {
        try out.appendSlice(arena,
            \\fn __mkdirSync(io: std.Io, path: []const u8, recursive: bool) void {
            \\    if (recursive) {
            \\        std.Io.Dir.cwd().createDirPath(io, path) catch {};
            \\    } else {
            \\        std.Io.Dir.cwd().createDir(io, path, std.Io.File.Permissions.default_dir) catch {};
            \\    }
            \\}
            \\
        );
    }
    if (program.needs_unlink_sync) {
        try out.appendSlice(arena,
            \\fn __unlinkSync(io: std.Io, path: []const u8) void {
            \\    std.Io.Dir.cwd().deleteFile(io, path) catch {};
            \\}
            \\
        );
    }
    if (program.needs_rename_sync) {
        try out.appendSlice(arena,
            \\fn __renameSync(io: std.Io, old_path: []const u8, new_path: []const u8) void {
            \\    std.Io.Dir.rename(std.Io.Dir.cwd(), old_path, std.Io.Dir.cwd(), new_path, io) catch {};
            \\}
            \\
        );
    }
    if (program.needs_copy_file_sync) {
        try out.appendSlice(arena,
            \\fn __copyFileSync(io: std.Io, src_path: []const u8, dest_path: []const u8) void {
            \\    std.Io.Dir.copyFile(std.Io.Dir.cwd(), src_path, std.Io.Dir.cwd(), dest_path, io, .{}) catch {};
            \\}
            \\
        );
    }
    if (program.needs_cp_sync) {
        // Composed from the same primitives as copyFileSync/mkdirSync/iterate:
        // if `src_path` opens as an iterable directory, recurse into it (only
        // when `recursive` is true); otherwise treat it as a single file.
        try out.appendSlice(arena,
            \\fn __cpSync(io: std.Io, alloc: std.mem.Allocator, src_path: []const u8, dest_path: []const u8, recursive: bool) void {
            \\    if (recursive) {
            \\        if (std.Io.Dir.cwd().openDir(io, src_path, .{ .iterate = true })) |src_dir_const| {
            \\            var src_dir = src_dir_const;
            \\            defer src_dir.close(io);
            \\            std.Io.Dir.cwd().createDirPath(io, dest_path) catch {};
            \\            var it = src_dir.iterate();
            \\            while (it.next(io) catch null) |entry| {
            \\                const sub_src = std.fmt.allocPrint(alloc, "{s}/{s}", .{ src_path, entry.name }) catch continue;
            \\                const sub_dest = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dest_path, entry.name }) catch continue;
            \\                __cpSync(io, alloc, sub_src, sub_dest, true);
            \\            }
            \\            return;
            \\        } else |_| {}
            \\    }
            \\    std.Io.Dir.copyFile(std.Io.Dir.cwd(), src_path, std.Io.Dir.cwd(), dest_path, io, .{}) catch {};
            \\}
            \\
        );
    }
    if (program.needs_mkdtemp_sync) {
        // Not Node's mkdtempSync exactly: the suffix is a timestamp mixed with a
        // per-process counter, not cryptographic randomness (no clear
        // std.crypto.random source in this Zig version) -- adequate for a unique
        // scratch directory name, not for anything security-sensitive.
        try out.appendSlice(arena,
            \\var __mkdtemp_counter: u64 = 0;
            \\fn __mkdtempSync(io: std.Io, alloc: std.mem.Allocator, prefix: []const u8) []const u8 {
            \\    const ts = std.Io.Clock.now(.real, io).nanoseconds;
            \\    __mkdtemp_counter +%= 1;
            \\    const mixed: u32 = @as(u32, @truncate(@as(u96, @bitCast(ts)))) ^ @as(u32, @truncate(__mkdtemp_counter *% 2654435761));
            \\    const path = std.fmt.allocPrint(alloc, "{s}{x:0>8}", .{ prefix, mixed }) catch return "";
            \\    std.Io.Dir.cwd().createDir(io, path, std.Io.File.Permissions.default_dir) catch return "";
            \\    return path;
            \\}
            \\
        );
    }
    if (program.needs_stat_sync) {
        // Backs the synthetic `__LumenStat` record type the checker registers
        // for fs.statSync (lumen_check_stdlib.zig): isFile/isDirectory are plain
        // bool fields here, not methods, since builtins can't have methods yet.
        try out.appendSlice(arena,
            \\pub const __LumenStat = struct { size: i32, isFile: bool, isDirectory: bool, mtimeMs: i32 };
            \\fn __statSync(io: std.Io, path: []const u8) __LumenStat {
            \\    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return .{ .size = 0, .isFile = false, .isDirectory = false, .mtimeMs = 0 };
            \\    return .{
            \\        .size = @truncate(@as(i64, @intCast(st.size))),
            \\        .isFile = st.kind == .file,
            \\        .isDirectory = st.kind == .directory,
            \\        .mtimeMs = @truncate(@divTrunc(@as(i96, st.mtime.nanoseconds), 1_000_000)),
            \\    };
            \\}
            \\
        );
    }
    if (program.needs_thread_pool_fs) {
        // Shared plumbing for async fs beyond readFile/writeFile/appendFile
        // (spec 047): those three are true async on libxev's io_uring
        // backend (no thread involved), but libxev's OperationType union has
        // no unlink/mkdir/rmdir/stat op on any backend (checked directly),
        // so those run a real ThreadPool.Task on a worker thread instead --
        // the same shape Node's own libuv uses for most of its async fs, and
        // the same mechanism libxev's own kqueue backend already relies on
        // internally for its file I/O (kqueue has no native completion-based
        // filesystem I/O either). One shared ThreadPool + one shared
        // xev.Async bridge per program, not one per call.
        //
        // LumenPromise.resolve() is a plain, non-atomic field write, and
        // LumenLoop.driveUntil/.drain poll it from the main thread while
        // pumping __xev_loop.run() -- calling .resolve() directly from a
        // worker thread would race that poll. So workers never resolve a
        // promise themselves: they push a completion record onto this
        // mutex-protected queue and wake the loop via xev.Async.notify();
        // only the main-thread wake-up callback below actually calls
        // .resolve(), keeping LumenPromise itself completely unchanged.
        try out.appendSlice(arena,
            \\const __FsDone = struct { ctx: *anyopaque, finish: *const fn (*anyopaque) void };
            \\var __fs_pool: xev.ThreadPool = undefined;
            \\var __fs_async: xev.Async = undefined;
            \\var __fs_async_c: xev.Completion = undefined;
            \\var __fs_done_mutex: std.Io.Mutex = .init;
            \\var __fs_done_queue: std.ArrayListUnmanaged(__FsDone) = .empty;
            \\fn __fsThreadPoolInit() void {
            \\    __fs_pool = xev.ThreadPool.init(.{});
            \\    __fs_async = xev.Async.init() catch unreachable;
            \\    __fs_async.wait(&__xev_loop, &__fs_async_c, void, null, __fsOnWake);
            \\}
            \\fn __fsOnWake(_: ?*void, _: *xev.Loop, _: *xev.Completion, r: xev.Async.WaitError!void) xev.CallbackAction {
            \\    _ = r catch {};
            \\    __fs_done_mutex.lock(__io) catch unreachable;
            \\    const items = __fs_done_queue.toOwnedSlice(__alloc) catch &.{};
            \\    __fs_done_mutex.unlock(__io);
            \\    for (items) |it| it.finish(it.ctx);
            \\    return .rearm;
            \\}
            \\fn __fsPushDone(ctx: *anyopaque, finish: *const fn (*anyopaque) void) void {
            \\    __fs_done_mutex.lock(__io) catch unreachable;
            \\    __fs_done_queue.append(__alloc, .{ .ctx = ctx, .finish = finish }) catch {};
            \\    __fs_done_mutex.unlock(__io);
            \\    __fs_async.notify() catch {};
            \\}
            \\
        );
    }
    if (program.needs_async_unlink) {
        try out.appendSlice(arena,
            \\const __UnlinkState = struct {
            \\    task: xev.ThreadPool.Task = .{ .callback = work },
            \\    path: []const u8,
            \\    promise: *LumenPromise(void),
            \\    fn work(t: *xev.ThreadPool.Task) void {
            \\        const self: *__UnlinkState = @fieldParentPtr("task", t);
            \\        std.Io.Dir.cwd().deleteFile(__io, self.path) catch {};
            \\        __fsPushDone(self, finish);
            \\    }
            \\    fn finish(ctx: *anyopaque) void {
            \\        const self: *__UnlinkState = @ptrCast(@alignCast(ctx));
            \\        self.promise.resolve({});
            \\    }
            \\};
            \\fn __unlinkAsync(path: []const u8) *LumenPromise(void) {
            \\    const p = LumenPromise(void).create();
            \\    const st = __alloc.create(__UnlinkState) catch unreachable;
            \\    st.* = .{ .path = path, .promise = p };
            \\    __fs_pool.schedule(xev.ThreadPool.Batch.from(&st.task));
            \\    return p;
            \\}
            \\
        );
    }
    if (program.needs_async_mkdir) {
        try out.appendSlice(arena,
            \\const __MkdirState = struct {
            \\    task: xev.ThreadPool.Task = .{ .callback = work },
            \\    path: []const u8,
            \\    promise: *LumenPromise(void),
            \\    fn work(t: *xev.ThreadPool.Task) void {
            \\        const self: *__MkdirState = @fieldParentPtr("task", t);
            \\        std.Io.Dir.cwd().createDir(__io, self.path, std.Io.File.Permissions.default_dir) catch {};
            \\        __fsPushDone(self, finish);
            \\    }
            \\    fn finish(ctx: *anyopaque) void {
            \\        const self: *__MkdirState = @ptrCast(@alignCast(ctx));
            \\        self.promise.resolve({});
            \\    }
            \\};
            \\fn __mkdirAsync(path: []const u8) *LumenPromise(void) {
            \\    const p = LumenPromise(void).create();
            \\    const st = __alloc.create(__MkdirState) catch unreachable;
            \\    st.* = .{ .path = path, .promise = p };
            \\    __fs_pool.schedule(xev.ThreadPool.Batch.from(&st.task));
            \\    return p;
            \\}
            \\
        );
    }
    if (program.needs_async_rmdir) {
        try out.appendSlice(arena,
            \\const __RmdirState = struct {
            \\    task: xev.ThreadPool.Task = .{ .callback = work },
            \\    path: []const u8,
            \\    promise: *LumenPromise(void),
            \\    fn work(t: *xev.ThreadPool.Task) void {
            \\        const self: *__RmdirState = @fieldParentPtr("task", t);
            \\        std.Io.Dir.cwd().deleteDir(__io, self.path) catch {};
            \\        __fsPushDone(self, finish);
            \\    }
            \\    fn finish(ctx: *anyopaque) void {
            \\        const self: *__RmdirState = @ptrCast(@alignCast(ctx));
            \\        self.promise.resolve({});
            \\    }
            \\};
            \\fn __rmdirAsync(path: []const u8) *LumenPromise(void) {
            \\    const p = LumenPromise(void).create();
            \\    const st = __alloc.create(__RmdirState) catch unreachable;
            \\    st.* = .{ .path = path, .promise = p };
            \\    __fs_pool.schedule(xev.ThreadPool.Batch.from(&st.task));
            \\    return p;
            \\}
            \\
        );
    }
    if (program.needs_async_stat) {
        try out.appendSlice(arena,
            \\const __StatState = struct {
            \\    task: xev.ThreadPool.Task = .{ .callback = work },
            \\    path: []const u8,
            \\    result: __LumenStat = undefined,
            \\    promise: *LumenPromise(__LumenStat),
            \\    fn work(t: *xev.ThreadPool.Task) void {
            \\        const self: *__StatState = @fieldParentPtr("task", t);
            \\        self.result = __statSync(__io, self.path);
            \\        __fsPushDone(self, finish);
            \\    }
            \\    fn finish(ctx: *anyopaque) void {
            \\        const self: *__StatState = @ptrCast(@alignCast(ctx));
            \\        self.promise.resolve(self.result);
            \\    }
            \\};
            \\fn __statAsync(path: []const u8) *LumenPromise(__LumenStat) {
            \\    const p = LumenPromise(__LumenStat).create();
            \\    const st = __alloc.create(__StatState) catch unreachable;
            \\    st.* = .{ .path = path, .promise = p };
            \\    __fs_pool.schedule(xev.ThreadPool.Batch.from(&st.task));
            \\    return p;
            \\}
            \\
        );
    }
    if (program.needs_worker) {
        // Worker.run(fn) -> Promise<T> (spec 059). Deliberately a bare
        // std.Thread.spawn per call, not the shared xev.ThreadPool spec 047
        // uses for fs: that pool is a fixed, CPU-count-sized set of workers
        // meant for many small, quick blocking syscalls, where queuing is
        // the right trade-off. A Worker models Node's own "one Worker == one
        // real OS thread" CPU-bound-parallelism primitive -- queuing a
        // CPU-bound Worker behind unrelated fs/http pool work would be a
        // real semantic mismatch with what the caller asked for, not just a
        // performance nuance. Confirmed against this project's vendored Zig
        // 0.16.0 `lib/std/Thread.zig` before writing this: `Thread.spawn(config,
        // comptime function, args) SpawnError!Thread` and `Thread.detach(self)
        // void` are exactly what's needed; no join is required since nothing
        // downstream waits on the OS thread itself, only on the Promise.
        //
        // Result handback reuses spec 047's exact worker-notifies-main shape:
        // LumenPromise.resolve() is a plain, non-atomic field write raced
        // against the main thread's await_/driveUntil poll if called from a
        // worker thread directly, so the worker thread never calls it -- it
        // pushes a completion record onto this dedicated, mutex-protected
        // queue and wakes a dedicated xev.Async; only the main-thread wake-up
        // callback below ever calls .resolve(). LumenPromise itself needs no
        // changes. This queue/Async pair is independent of fs's own
        // __fs_done_queue/__fs_async (Worker doesn't require fs to be used).
        try out.appendSlice(arena,
            \\const __WorkerDone = struct { ctx: *anyopaque, finish: *const fn (*anyopaque) void };
            \\var __worker_async: xev.Async = undefined;
            \\var __worker_async_c: xev.Completion = undefined;
            \\var __worker_done_mutex: std.Io.Mutex = .init;
            \\var __worker_done_queue: std.ArrayListUnmanaged(__WorkerDone) = .empty;
            \\fn __workerInit() void {
            \\    __worker_async = xev.Async.init() catch unreachable;
            \\    __worker_async.wait(&__xev_loop, &__worker_async_c, void, null, __workerOnWake);
            \\}
            \\fn __workerOnWake(_: ?*void, _: *xev.Loop, _: *xev.Completion, r: xev.Async.WaitError!void) xev.CallbackAction {
            \\    _ = r catch {};
            \\    __worker_done_mutex.lock(__io) catch unreachable;
            \\    const items = __worker_done_queue.toOwnedSlice(__alloc) catch &.{};
            \\    __worker_done_mutex.unlock(__io);
            \\    for (items) |it| it.finish(it.ctx);
            \\    return .rearm;
            \\}
            \\fn __workerPushDone(ctx: *anyopaque, finish: *const fn (*anyopaque) void) void {
            \\    __worker_done_mutex.lock(__io) catch unreachable;
            \\    __worker_done_queue.append(__alloc, .{ .ctx = ctx, .finish = finish }) catch {};
            \\    __worker_done_mutex.unlock(__io);
            \\    __worker_async.notify() catch {};
            \\}
            \\fn __workerRun(comptime T: type, f: anytype) *LumenPromise(T) {
            \\    const Cb = @TypeOf(f);
            \\    const State = struct {
            \\        f: Cb,
            \\        promise: *LumenPromise(T),
            \\        result: T = undefined,
            \\        fn threadMain(self: *@This()) void {
            \\            self.result = self.f.call(self.f.ctx);
            \\            __workerPushDone(self, finish);
            \\        }
            \\        fn finish(ctx: *anyopaque) void {
            \\            const self: *@This() = @ptrCast(@alignCast(ctx));
            \\            self.promise.resolve(self.result);
            \\        }
            \\    };
            \\    const p = LumenPromise(T).create();
            \\    const st = __alloc.create(State) catch unreachable;
            \\    st.* = .{ .f = f, .promise = p };
            \\    const th = std.Thread.spawn(.{}, State.threadMain, .{st}) catch unreachable;
            \\    th.detach();
            \\    return p;
            \\}
            \\
        );
    }
    if (program.needs_fd_api) {
        // A Lumen "fd" is an index into this table, not a raw OS handle (so the
        // type stays a plain `int`). openSync supports only "r" (read, must
        // exist) and "w" (write, create/truncate) -- "a" (append) needs a seek
        // primitive not available in this Zig version's std.Io.File, so it is
        // deferred. readSync/writeSync work on `string`, not a Buffer type
        // (Lumen has none yet), and are sequential (advance the OS file
        // position), matching Node's positionless readSync/writeSync.
        try out.appendSlice(arena,
            \\var __fd_table: std.ArrayListUnmanaged(std.Io.File) = .empty;
            \\fn __openSync(io: std.Io, alloc: std.mem.Allocator, path: []const u8, flags: []const u8) i32 {
            \\    const file = if (std.mem.eql(u8, flags, "w"))
            \\        std.Io.Dir.cwd().createFile(io, path, .{}) catch return -1
            \\    else if (std.mem.eql(u8, flags, "a")) blk: {
            \\        // Append mode (spec 031 revisited again): std.Io.File's
            \\        // write path issues a raw, position-implicit writev(),
            \\        // so seating the kernel's own fd offset at EOF once via
            \\        // a raw lseek is enough -- every later writeSync call
            \\        // naturally continues from there, no per-call seek or
            \\        // offset tracking needed.
            \\        const f = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false }) catch return -1;
            \\        if (@import("builtin").os.tag == .linux) _ = std.os.linux.lseek(f.handle, 0, std.os.linux.SEEK.END);
            \\        break :blk f;
            \\    } else
            \\        std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return -1;
            \\    __fd_table.append(alloc, file) catch return -1;
            \\    return @intCast(__fd_table.items.len - 1);
            \\}
            \\fn __closeSync(io: std.Io, fd: i32) void {
            \\    if (fd < 0 or @as(usize, @intCast(fd)) >= __fd_table.items.len) return;
            \\    __fd_table.items[@intCast(fd)].close(io);
            \\}
            \\fn __readSync(io: std.Io, alloc: std.mem.Allocator, fd: i32, len: i32) []const u8 {
            \\    if (fd < 0 or @as(usize, @intCast(fd)) >= __fd_table.items.len or len <= 0) return "";
            \\    const buf = alloc.alloc(u8, @intCast(len)) catch return "";
            \\    const n = __fd_table.items[@intCast(fd)].readStreaming(io, &.{buf}) catch return "";
            \\    return buf[0..n];
            \\}
            \\fn __writeSync(io: std.Io, fd: i32, data: []const u8) i32 {
            \\    if (fd < 0 or @as(usize, @intCast(fd)) >= __fd_table.items.len) return 0;
            \\    __fd_table.items[@intCast(fd)].writeStreamingAll(io, data) catch return 0;
            \\    return @intCast(data.len);
            \\}
            \\
        );
    }
    if (program.needs_rmdir_sync) {
        try out.appendSlice(arena,
            \\fn __rmdirSync(io: std.Io, path: []const u8) void {
            \\    std.Io.Dir.cwd().deleteDir(io, path) catch {};
            \\}
            \\
        );
    }
    if (program.needs_rm_sync) {
        try out.appendSlice(arena,
            \\fn __rmSync(io: std.Io, path: []const u8, recursive: bool) void {
            \\    if (recursive) {
            \\        std.Io.Dir.cwd().deleteTree(io, path) catch {};
            \\    } else {
            \\        std.Io.Dir.cwd().deleteFile(io, path) catch {
            \\            std.Io.Dir.cwd().deleteDir(io, path) catch {};
            \\        };
            \\    }
            \\}
            \\
        );
    }
    if (program.needs_truncate_sync) {
        try out.appendSlice(arena,
            \\fn __truncateSync(io: std.Io, path: []const u8, len: i64) void {
            \\    var file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch return;
            \\    defer file.close(io);
            \\    file.setLength(io, @intCast(len)) catch {};
            \\}
            \\
        );
    }
    if (program.needs_link_sync) {
        try out.appendSlice(arena,
            \\fn __linkSync(io: std.Io, existing_path: []const u8, new_path: []const u8) void {
            \\    std.Io.Dir.hardLink(std.Io.Dir.cwd(), existing_path, std.Io.Dir.cwd(), new_path, io, .{}) catch {};
            \\}
            \\
        );
    }
    if (program.needs_symlink_sync) {
        try out.appendSlice(arena,
            \\fn __symlinkSync(io: std.Io, target: []const u8, path: []const u8) void {
            \\    std.Io.Dir.cwd().symLink(io, target, path, .{}) catch {};
            \\}
            \\
        );
    }
    if (program.needs_readlink_sync) {
        try out.appendSlice(arena,
            \\fn __readlinkSync(io: std.Io, alloc: std.mem.Allocator, path: []const u8) []const u8 {
            \\    var buf: [4096]u8 = undefined;
            \\    const n = std.Io.Dir.cwd().readLink(io, path, &buf) catch return "";
            \\    return alloc.dupe(u8, buf[0..n]) catch "";
            \\}
            \\
        );
    }
    if (program.needs_chmod_sync) {
        try out.appendSlice(arena,
            \\fn __chmodSync(io: std.Io, path: []const u8, mode: i64) void {
            \\    var file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return;
            \\    defer file.close(io);
            \\    file.setPermissions(io, std.Io.File.Permissions.fromMode(@intCast(mode))) catch {};
            \\}
            \\
        );
    }
    if (program.needs_access_sync) {
        try out.appendSlice(arena,
            \\fn __accessSync(io: std.Io, path: []const u8, mode: i64) bool {
            \\    const m: u32 = @intCast(mode);
            \\    const opts: std.Io.Dir.AccessOptions = .{
            \\        .read = (m & 4) != 0,
            \\        .write = (m & 2) != 0,
            \\        .execute = (m & 1) != 0,
            \\    };
            \\    std.Io.Dir.cwd().access(io, path, opts) catch return false;
            \\    return true;
            \\}
            \\
        );
    }
    if (program.needs_lstat_sync) {
        // Same `__LumenStat` record as statSync, but `follow_symlinks = false`
        // so a symlink itself is stat'd rather than its target.
        try out.appendSlice(arena,
            \\fn __lstatSync(io: std.Io, path: []const u8) __LumenStat {
            \\    const st = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch return .{ .size = 0, .isFile = false, .isDirectory = false, .mtimeMs = 0 };
            \\    return .{
            \\        .size = @truncate(@as(i64, @intCast(st.size))),
            \\        .isFile = st.kind == .file,
            \\        .isDirectory = st.kind == .directory,
            \\        .mtimeMs = @truncate(@divTrunc(@as(i96, st.mtime.nanoseconds), 1_000_000)),
            \\    };
            \\}
            \\
        );
    }
    if (program.needs_fstat_sync) {
        // fd-based variant of statSync: stats the already-open file in
        // __fd_table rather than re-resolving a path.
        try out.appendSlice(arena,
            \\fn __fstatSync(io: std.Io, fd: i32) __LumenStat {
            \\    if (fd < 0 or @as(usize, @intCast(fd)) >= __fd_table.items.len) return .{ .size = 0, .isFile = false, .isDirectory = false, .mtimeMs = 0 };
            \\    const st = __fd_table.items[@intCast(fd)].stat(io) catch return .{ .size = 0, .isFile = false, .isDirectory = false, .mtimeMs = 0 };
            \\    return .{
            \\        .size = @truncate(@as(i64, @intCast(st.size))),
            \\        .isFile = st.kind == .file,
            \\        .isDirectory = st.kind == .directory,
            \\        .mtimeMs = @truncate(@divTrunc(@as(i96, st.mtime.nanoseconds), 1_000_000)),
            \\    };
            \\}
            \\
        );
    }
    if (program.needs_fchmod_sync) {
        try out.appendSlice(arena,
            \\fn __fchmodSync(io: std.Io, fd: i32, mode: i64) void {
            \\    if (fd < 0 or @as(usize, @intCast(fd)) >= __fd_table.items.len) return;
            \\    __fd_table.items[@intCast(fd)].setPermissions(io, std.Io.File.Permissions.fromMode(@intCast(mode))) catch {};
            \\}
            \\
        );
    }
    if (program.needs_lchmod_sync) {
        // Best effort: not every OS lets you chmod a symlink directly: this
        // opens without following the symlink, then sets permissions on
        // whatever that resolves to.
        try out.appendSlice(arena,
            \\fn __lchmodSync(io: std.Io, path: []const u8, mode: i64) void {
            \\    var file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only, .follow_symlinks = false }) catch return;
            \\    defer file.close(io);
            \\    file.setPermissions(io, std.Io.File.Permissions.fromMode(@intCast(mode))) catch {};
            \\}
            \\
        );
    }
    if (program.needs_fchown_sync) {
        try out.appendSlice(arena,
            \\fn __fchownSync(io: std.Io, fd: i32, uid: i64, gid: i64) void {
            \\    if (fd < 0 or @as(usize, @intCast(fd)) >= __fd_table.items.len) return;
            \\    const u: ?std.posix.uid_t = if (uid < 0) null else @intCast(uid);
            \\    const g: ?std.posix.gid_t = if (gid < 0) null else @intCast(gid);
            \\    __fd_table.items[@intCast(fd)].setOwner(io, u, g) catch {};
            \\}
            \\
        );
    }
    if (program.needs_chown_sync) {
        // fs.chownSync (spec 031 revisited): the path-based Dir.setFileOwner
        // is an unconditional @panic in this Zig version's Io.Threaded
        // backend on Linux, confirmed still true by reading the source
        // directly -- genuinely blocked at that layer. But File.setOwner
        // (the fd-based one fchownSync already uses) is a real, working
        // implementation, not a stub. So this opens the file first and uses
        // that instead, the same "open, then use the file-level method"
        // pattern chmodSync already established, sidestepping the broken
        // path-level wrapper entirely.
        try out.appendSlice(arena,
            \\fn __chownSync(io: std.Io, path: []const u8, uid: i64, gid: i64) void {
            \\    var file = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only }) catch return;
            \\    defer file.close(io);
            \\    const u: ?std.posix.uid_t = if (uid < 0) null else @intCast(uid);
            \\    const g: ?std.posix.gid_t = if (gid < 0) null else @intCast(gid);
            \\    file.setOwner(io, u, g) catch {};
            \\}
            \\
        );
    }
    if (program.needs_lchown_sync) {
        // fs.lchownSync (spec 031 revisited again): must not follow a
        // symlink, so chownSync's "open the file, use File.setOwner" trick
        // doesn't apply here -- there's no way to open a path without
        // following a symlink in this Zig version. But std.os.linux already
        // has a ready-made lchown raw syscall wrapper (fchownat with
        // AT.SYMLINK_NOFOLLOW under the hood), the same "raw Linux syscall,
        // no libc, no std.Io" pattern fs.watch/writevSync already
        // established. No `io` parameter needed -- this never touches
        // std.Io at all.
        try out.appendSlice(arena,
            \\fn __lchownSync(path: []const u8, uid: i64, gid: i64) void {
            \\    if (@import("builtin").os.tag != .linux) return;
            \\    const path_z = std.heap.page_allocator.dupeZ(u8, path) catch return;
            \\    defer std.heap.page_allocator.free(path_z);
            \\    const u: std.posix.uid_t = if (uid < 0) ~@as(std.posix.uid_t, 0) else @intCast(uid);
            \\    const g: std.posix.gid_t = if (gid < 0) ~@as(std.posix.gid_t, 0) else @intCast(gid);
            \\    _ = std.os.linux.lchown(path_z, u, g);
            \\}
            \\
        );
    }
    if (program.needs_writev_sync) {
        // fs.writevSync (spec 031 revisited): std.Io.File has no vectored
        // write wrapper in this Zig version (confirmed absent, not just
        // unused), but the raw std.os.linux.writev syscall does exist --
        // the same "raw Linux syscall, no libc" pattern os.uptime()/
        // fs.watch already established.
        try out.appendSlice(arena,
            \\fn __writevSync(fd: i32, bufs: []const []const u8) i32 {
            \\    if (@import("builtin").os.tag != .linux) return 0;
            \\    if (fd < 0 or @as(usize, @intCast(fd)) >= __fd_table.items.len) return 0;
            \\    const handle = __fd_table.items[@intCast(fd)].handle;
            \\    const iov = std.heap.page_allocator.alloc(std.posix.iovec_const, bufs.len) catch return 0;
            \\    defer std.heap.page_allocator.free(iov);
            \\    for (bufs, 0..) |b, i| iov[i] = .{ .base = b.ptr, .len = b.len };
            \\    const n = std.os.linux.writev(handle, iov.ptr, iov.len);
            \\    return @intCast(n);
            \\}
            \\
        );
    }
    if (program.needs_readv_sync) {
        // fs.readvSync (spec 031 revisited again): reframed, not a direct
        // port of Node's signature. Node's readv fills caller-provided
        // *mutable* buffers, which has no natural shape given Lumen's
        // `string` is immutable. Instead this takes int[] sizes and
        // allocates+owns the buffers itself, doing one real readv syscall
        // to fill them all, then hands back fresh immutable strings sized
        // to what was actually read -- same underlying vectored read, a
        // shape that fits the type system instead of fighting it. readv
        // fills earlier buffers completely before moving to later ones, so
        // slicing each allocated buffer against the remaining byte count
        // (in order) recovers exactly how much each one actually got.
        try out.appendSlice(arena,
            \\fn __readvSync(alloc: std.mem.Allocator, fd: i32, sizes: []const i32) []const []const u8 {
            \\    if (@import("builtin").os.tag != .linux) return &.{};
            \\    if (fd < 0 or @as(usize, @intCast(fd)) >= __fd_table.items.len) return &.{};
            \\    const handle = __fd_table.items[@intCast(fd)].handle;
            \\    const bufs = alloc.alloc([]u8, sizes.len) catch return &.{};
            \\    const iov = alloc.alloc(std.posix.iovec, sizes.len) catch return &.{};
            \\    for (sizes, 0..) |sz, i| {
            \\        const b = alloc.alloc(u8, @intCast(@max(sz, 0))) catch return &.{};
            \\        bufs[i] = b;
            \\        iov[i] = .{ .base = b.ptr, .len = b.len };
            \\    }
            \\    const rc = std.os.linux.readv(handle, iov.ptr, iov.len);
            \\    if (@as(isize, @bitCast(rc)) < 0) return &.{};
            \\    var remaining: usize = rc;
            \\    const result = alloc.alloc([]const u8, sizes.len) catch return &.{};
            \\    for (bufs, 0..) |b, i| {
            \\        const take = @min(b.len, remaining);
            \\        result[i] = b[0..take];
            \\        remaining -= take;
            \\    }
            \\    return result;
            \\}
            \\
        );
    }
    if (program.needs_fsync_sync) {
        // Backs both fsyncSync and fdatasyncSync: Zig's std.Io.File has no
        // data-only sync, so fdatasyncSync is treated as a full sync.
        try out.appendSlice(arena,
            \\fn __fsyncSync(io: std.Io, fd: i32) void {
            \\    if (fd < 0 or @as(usize, @intCast(fd)) >= __fd_table.items.len) return;
            \\    __fd_table.items[@intCast(fd)].sync(io) catch {};
            \\}
            \\
        );
    }
    if (program.needs_ftruncate_sync) {
        try out.appendSlice(arena,
            \\fn __ftruncateSync(io: std.Io, fd: i32, len: i64) void {
            \\    if (fd < 0 or @as(usize, @intCast(fd)) >= __fd_table.items.len) return;
            \\    __fd_table.items[@intCast(fd)].setLength(io, @intCast(len)) catch {};
            \\}
            \\
        );
    }
    if (program.needs_futimes_sync) {
        try out.appendSlice(arena,
            \\fn __futimesSync(io: std.Io, fd: i32, atime_ms: i64, mtime_ms: i64) void {
            \\    if (fd < 0 or @as(usize, @intCast(fd)) >= __fd_table.items.len) return;
            \\    __fd_table.items[@intCast(fd)].setTimestamps(io, .{
            \\        .access_timestamp = .{ .new = .{ .nanoseconds = @as(i96, atime_ms) * 1_000_000 } },
            \\        .modify_timestamp = .{ .new = .{ .nanoseconds = @as(i96, mtime_ms) * 1_000_000 } },
            \\    }) catch {};
            \\}
            \\
        );
    }
    if (program.needs_utimes_sync) {
        // Backs both utimesSync (follow_symlinks=true) and lutimesSync (false).
        try out.appendSlice(arena,
            \\fn __utimesSync(io: std.Io, path: []const u8, atime_ms: i64, mtime_ms: i64, follow_symlinks: bool) void {
            \\    std.Io.Dir.cwd().setTimestamps(io, path, .{
            \\        .follow_symlinks = follow_symlinks,
            \\        .access_timestamp = .{ .new = .{ .nanoseconds = @as(i96, atime_ms) * 1_000_000 } },
            \\        .modify_timestamp = .{ .new = .{ .nanoseconds = @as(i96, mtime_ms) * 1_000_000 } },
            \\    }) catch {};
            \\}
            \\
        );
    }
    if (program.needs_readdir_sync) {
        // string[] is already a plain []const []const u8 slice (not a
        // growable list), so this is a two-pass count-then-fill: no
        // Array.push language feature needed.
        try out.appendSlice(arena,
            \\fn __readdirSync(io: std.Io, alloc: std.mem.Allocator, path: []const u8) []const []const u8 {
            \\    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return &.{};
            \\    defer dir.close(io);
            \\    var count: usize = 0;
            \\    {
            \\        var it = dir.iterate();
            \\        while (it.next(io) catch null) |_| count += 1;
            \\    }
            \\    const names = alloc.alloc([]const u8, count) catch return &.{};
            \\    var it2 = dir.iterate();
            \\    var i: usize = 0;
            \\    while (i < count) {
            \\        const entry = (it2.next(io) catch null) orelse break;
            \\        names[i] = alloc.dupe(u8, entry.name) catch entry.name;
            \\        i += 1;
            \\    }
            \\    return names[0..i];
            \\}
            \\
        );
    }
    if (program.needs_fs_watch) {
        // fs.watch (spec 044): raw inotify, the same "raw Linux syscall, no
        // libc" pattern os.uptime()/uname() already established. Blocking,
        // like http.createServer -- there's no background mechanism to
        // drive an EventEmitter asynchronously here, so this calls
        // `listener` synchronously in a loop that never returns, rather
        // than returning an EventEmitter-based watcher object the way
        // Node's real fs.watch does.
        try out.appendSlice(arena,
            \\fn __fsWatch(path: []const u8, listener: anytype) noreturn {
            \\    if (@import("builtin").os.tag != .linux) std.process.exit(1);
            \\    const inotify = std.os.linux.inotify_init1(0);
            \\    if (@as(isize, @bitCast(inotify)) < 0) std.process.exit(1);
            \\    const fd: i32 = @intCast(inotify);
            \\    const path_z = std.heap.page_allocator.dupeZ(u8, path) catch std.process.exit(1);
            \\    const mask: u32 = std.os.linux.IN.MODIFY | std.os.linux.IN.CREATE | std.os.linux.IN.DELETE | std.os.linux.IN.MOVE;
            \\    const wd = std.os.linux.inotify_add_watch(fd, path_z, mask);
            \\    if (@as(isize, @bitCast(wd)) < 0) std.process.exit(1);
            \\    var buf: [4096]u8 align(@alignOf(std.os.linux.inotify_event)) = undefined;
            \\    while (true) {
            \\        const n = std.posix.read(fd, &buf) catch continue;
            \\        var offset: usize = 0;
            \\        while (offset + @sizeOf(std.os.linux.inotify_event) <= n) {
            \\            const ev: *const std.os.linux.inotify_event = @ptrCast(@alignCast(&buf[offset]));
            \\            const name = ev.getName() orelse path;
            \\            // Node's fs.watch only distinguishes "change" (data
            \\            // modified) from "rename" (created/deleted/moved),
            \\            // not inotify's full event granularity -- matching
            \\            // that convention rather than inventing a new one.
            \\            const event_type: []const u8 = if (ev.mask & std.os.linux.IN.MODIFY != 0) "change" else "rename";
            \\            listener.call(listener.ctx, name, event_type);
            \\            offset += @sizeOf(std.os.linux.inotify_event) + ev.len;
            \\        }
            \\    }
            \\}
            \\
        );
    }
    if (program.needs_fs_streams) {
        // fs.createReadStream/createWriteStream (spec 046): built the same
        // way as Map/Set/EventEmitter (a dedicated, non-generic type), not
        // via Lumen's own array syntax (which has no growable-array support
        // to build one with anyway). Synchronous, blocking .read()/.write()
        // calls -- no async/backpressure integration in this pass. A
        // missing/unopenable file degrades to a stream where .read() always
        // returns "" and .close() is a no-op, the same "return a fallback,
        // don't crash" shape every other fs function already uses.
        try out.appendSlice(arena,
            \\pub const LumenReadableStream = struct {
            \\    file: ?std.Io.File,
            \\    io: std.Io,
            \\    reader: std.Io.File.Reader = undefined,
            \\    fn __init(io: std.Io, file: ?std.Io.File) *LumenReadableStream {
            \\        const p = __sa().create(LumenReadableStream) catch unreachable;
            \\        p.* = .{ .file = file, .io = io };
            \\        if (file) |f| {
            \\            const buf = __sa().alloc(u8, 65536) catch unreachable;
            \\            p.reader = f.readerStreaming(io, buf);
            \\        }
            \\        return p;
            \\    }
            \\    fn read(self: *LumenReadableStream) []const u8 {
            \\        if (self.file == null) return "";
            \\        var scratch: [65536]u8 = undefined;
            \\        const n = self.reader.interface.readSliceShort(&scratch) catch return "";
            \\        if (n == 0) return "";
            \\        return __sa().dupe(u8, scratch[0..n]) catch "";
            \\    }
            \\    // readLine() (spec 053): takeDelimiterInclusive is the same
            \\    // primitive __httpCreateServer's request-line/header parsing
            \\    // already proved out for "read up to and including the next
            \\    // \n" over a std.Io.Reader interface. Deliberately does NOT
            \\    // strip the trailing terminator (see spec.md's "Line
            \\    // reading" section): stripping it would make a genuinely
            \\    // blank line and true end-of-stream both collapse to the
            \\    // same "", making a `while (readLine() != "")` loop stop
            \\    // early on ordinary blank input lines -- a real correctness
            \\    // bug, confirmed directly by testing piped input containing
            \\    // a blank line before fixing this. Only true EOF (checked
            \\    // via takeDelimiterInclusive's EndOfStream, then draining
            \\    // whatever partial bytes -- if any -- are still buffered
            \\    // for a final unterminated line) returns "".
            \\    fn readLine(self: *LumenReadableStream) []const u8 {
            \\        if (self.file == null) return "";
            \\        const raw = self.reader.interface.takeDelimiterInclusive('\n') catch |e| blk: {
            \\            if (e != error.EndOfStream) break :blk "";
            \\            const left = self.reader.interface.buffered();
            \\            if (left.len == 0) break :blk "";
            \\            self.reader.interface.toss(left.len);
            \\            break :blk left;
            \\        };
            \\        if (raw.len == 0) return "";
            \\        return __sa().dupe(u8, raw) catch "";
            \\    }
            \\    fn close(self: *LumenReadableStream) void {
            \\        if (self.file) |f| f.close(self.io);
            \\    }
            \\};
            \\fn __fsCreateReadStream(io: std.Io, path: []const u8) *LumenReadableStream {
            \\    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch null;
            \\    return LumenReadableStream.__init(io, file);
            \\}
            \\pub const LumenWritableStream = struct {
            \\    file: ?std.Io.File,
            \\    io: std.Io,
            \\    writer: std.Io.File.Writer = undefined,
            \\    // flush_each_write (spec 053): off by default so
            \\    // fs.createWriteStream's existing buffered-until-close
            \\    // behavior is unchanged; process.stdout()/stderr() turn this
            \\    // on so writes interleave correctly with console.log, which
            \\    // flushes every call -- see spec 053's "unflushed stdout
            \\    // writes" section.
            \\    flush_each_write: bool = false,
            \\    fn __init(io: std.Io, file: ?std.Io.File) *LumenWritableStream {
            \\        const p = __sa().create(LumenWritableStream) catch unreachable;
            \\        p.* = .{ .file = file, .io = io };
            \\        if (file) |f| {
            \\            const buf = __sa().alloc(u8, 65536) catch unreachable;
            \\            p.writer = f.writerStreaming(io, buf);
            \\        }
            \\        return p;
            \\    }
            \\    fn write(self: *LumenWritableStream, chunk: []const u8) void {
            \\        if (self.file == null) return;
            \\        self.writer.interface.writeAll(chunk) catch {};
            \\        if (self.flush_each_write) self.writer.interface.flush() catch {};
            \\    }
            \\    fn close(self: *LumenWritableStream) void {
            \\        if (self.file) |f| {
            \\            self.writer.interface.flush() catch {};
            \\            f.close(self.io);
            \\        }
            \\    }
            \\};
            \\fn __fsCreateWriteStream(io: std.Io, path: []const u8) *LumenWritableStream {
            \\    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch null;
            \\    return LumenWritableStream.__init(io, file);
            \\}
            \\
        );
    }
    if (program.needs_process_stdio) {
        // process.stdin()/stdout()/stderr() (spec 053): the exact spec
        // 046 stream types, just constructed straight from the real stdio
        // File instead of an opened path -- see spec.md's "Why reuse spec
        // 046's types verbatim" section.
        try out.appendSlice(arena,
            \\fn __processStdin(io: std.Io) *LumenReadableStream {
            \\    return LumenReadableStream.__init(io, std.Io.File.stdin());
            \\}
            \\fn __processStdout(io: std.Io) *LumenWritableStream {
            \\    const s = LumenWritableStream.__init(io, std.Io.File.stdout());
            \\    s.flush_each_write = true;
            \\    return s;
            \\}
            \\fn __processStderr(io: std.Io) *LumenWritableStream {
            \\    const s = LumenWritableStream.__init(io, std.Io.File.stderr());
            \\    s.flush_each_write = true;
            \\    return s;
            \\}
            \\
        );
    }
    if (program.needs_readline) {
        // readline.question (spec 058): a thin, synchronous wrapper over
        // process.stdout()/stdin(), both already shipped by spec 053 --
        // see spec.md's "why one flat function". Strips exactly one
        // trailing \r\n or \n that readLine() deliberately keeps (its own
        // blank-line-vs-EOF fix), since question()'s return value should
        // be "what the user typed", not a line-with-terminator.
        try out.appendSlice(arena,
            \\var __readline_stdin: ?*LumenReadableStream = null;
            \\fn __readlineQuestion(io: std.Io, prompt: []const u8) []const u8 {
            \\    __processStdout(io).write(prompt);
            \\    // A fresh LumenReadableStream per call (like process.stdin()
            \\    // itself) would each open its own std.Io.File.Reader with its
            \\    // own internal read-ahead buffer -- the first call's buffer
            \\    // can silently swallow bytes belonging to the *next* line
            \\    // straight from the pipe, which the next call's brand-new,
            \\    // empty buffer never sees. Confirmed directly: a two-line
            \\    // heredoc lost its second line before this fix. One shared
            \\    // instance across every question() call in the program
            \\    // keeps the same underlying reader (and its buffer) alive.
            \\    if (__readline_stdin == null) __readline_stdin = __processStdin(io);
            \\    var line = __readline_stdin.?.readLine();
            \\    if (line.len == 0) return "";
            \\    if (line[line.len - 1] == '\n') line = line[0 .. line.len - 1];
            \\    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            \\    return line;
            \\}
            \\
        );
    }
    if (program.needs_buffer) {
        // Buffer (spec 056): a dedicated heap-pointer type over `[]const u8`,
        // built the same way Map/Set/ReadableStream are -- allocated via
        // __sa(), the stable arena every other container already uses.
        // `.length` is a real Zig method (`length()`), not a raw `.data.len`
        // field read, matching Map/Set's `.size` -> `.size()` shape (Buffer
        // is heap-pointer-wrapped, not a raw slice, at the Lumen type
        // level) -- see spec.md's design notes for why this precedent was
        // picked over string/array's raw-slice `.length`.
        try out.appendSlice(arena,
            \\pub const LumenBuffer = struct {
            \\    data: []const u8,
            \\    fn __wrap(bytes: []const u8) *LumenBuffer {
            \\        const p = __sa().create(LumenBuffer) catch unreachable;
            \\        p.* = .{ .data = bytes };
            \\        return p;
            \\    }
            \\    fn length(self: *LumenBuffer) i32 {
            \\        return @as(i32, @intCast(self.data.len));
            \\    }
            \\    fn at(self: *LumenBuffer, i: i32) i32 {
            \\        if (i < 0 or i >= @as(i32, @intCast(self.data.len))) return 0;
            \\        return @as(i32, self.data[@intCast(i)]);
            \\    }
            \\    fn slice(self: *LumenBuffer, start: i32, end: i32) *LumenBuffer {
            \\        const len = @as(i32, @intCast(self.data.len));
            \\        var s = start;
            \\        var e = end;
            \\        if (s < 0) s = 0;
            \\        if (s > len) s = len;
            \\        if (e < 0) e = 0;
            \\        if (e > len) e = len;
            \\        if (e < s) e = s;
            \\        return LumenBuffer.__wrap(self.data[@intCast(s)..@intCast(e)]);
            \\    }
            \\    fn equals(self: *LumenBuffer, other: *LumenBuffer) bool {
            \\        return std.mem.eql(u8, self.data, other.data);
            \\    }
            \\    fn toString(self: *LumenBuffer, encoding: []const u8) []const u8 {
            \\        if (std.mem.eql(u8, encoding, "hex")) {
            \\            return std.fmt.allocPrint(__sa(), "{x}", .{self.data}) catch "";
            \\        }
            \\        if (std.mem.eql(u8, encoding, "base64")) {
            \\            const enc = std.base64.standard.Encoder;
            \\            const n = enc.calcSize(self.data.len);
            \\            const buf = __sa().alloc(u8, n) catch return "";
            \\            return enc.encode(buf, self.data);
            \\        }
            \\        return self.data;
            \\    }
            \\};
            \\fn __bufferFromUtf8(s: []const u8) *LumenBuffer {
            \\    return LumenBuffer.__wrap(s);
            \\}
            \\fn __bufferFromEncoded(s: []const u8, encoding: []const u8) *LumenBuffer {
            \\    if (std.mem.eql(u8, encoding, "hex")) {
            \\        if (s.len % 2 != 0) return LumenBuffer.__wrap("");
            \\        const n = s.len / 2;
            \\        const buf = __sa().alloc(u8, n) catch return LumenBuffer.__wrap("");
            \\        _ = std.fmt.hexToBytes(buf, s) catch return LumenBuffer.__wrap("");
            \\        return LumenBuffer.__wrap(buf);
            \\    }
            \\    if (std.mem.eql(u8, encoding, "base64")) {
            \\        const dec = std.base64.standard.Decoder;
            \\        const dlen = dec.calcSizeForSlice(s) catch return LumenBuffer.__wrap("");
            \\        const buf = __sa().alloc(u8, dlen) catch return LumenBuffer.__wrap("");
            \\        dec.decode(buf, s) catch return LumenBuffer.__wrap("");
            \\        return LumenBuffer.__wrap(buf);
            \\    }
            \\    return LumenBuffer.__wrap(s);
            \\}
            \\fn __bufferAlloc(n: i32) *LumenBuffer {
            \\    const size: usize = if (n < 0) 0 else @intCast(n);
            \\    const buf = __sa().alloc(u8, size) catch unreachable;
            \\    @memset(buf, 0);
            \\    return LumenBuffer.__wrap(buf);
            \\}
            \\
        );
    }
    if (program.needs_path_api) {
        // path.* (spec 032): pure string manipulation, no Io parameter at all
        // -- the one stdlib namespace that doesn't thread `io` through.
        // __pathJoin/__pathResolve/normalize all reduce to std.fs.path.resolve:
        // its "cd"-chaining behavior (an absolute segment resets the result,
        // "." and ".." collapse without ever consulting a real working
        // directory) is exactly Node's path.resolve semantics, *except* Node
        // implicitly anchors a fully-relative input to process.cwd() and Zig
        // does not (this Zig version has no working Io.Dir.realpath to get a
        // real cwd string from, the same gap documented for fs.realpathSync).
        try out.appendSlice(arena,
            \\pub const __LumenPathParts = struct { root: []const u8, dir: []const u8, base: []const u8, name: []const u8, ext: []const u8 };
            \\fn __pathBasename(path: []const u8, suffix: []const u8) []const u8 {
            \\    const base = std.fs.path.basename(path);
            \\    if (suffix.len > 0 and base.len > suffix.len and std.mem.endsWith(u8, base, suffix)) {
            \\        return base[0 .. base.len - suffix.len];
            \\    }
            \\    return base;
            \\}
            \\fn __pathDirname(path: []const u8) []const u8 {
            \\    return std.fs.path.dirname(path) orelse ".";
            \\}
            \\fn __pathResolve(io: std.Io, alloc: std.mem.Allocator, paths: []const []const u8) []const u8 {
            \\    // path.resolve (spec 032 revisited): now anchors a fully-
            \\    // relative result to the real cwd, matching Node. Always
            \\    // prepending cwd and letting std.fs.path.resolve's own
            \\    // left-to-right "cd"-chaining logic run is enough -- if a
            \\    // later segment is absolute, that logic already resets the
            \\    // result past the cwd anchor on its own, so there's no need
            \\    // to separately check whether any input is absolute first.
            \\    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            \\    const cwd_len = std.process.currentPath(io, &cwd_buf) catch {
            \\        return std.fs.path.resolve(alloc, paths) catch "";
            \\    };
            \\    const full = alloc.alloc([]const u8, paths.len + 1) catch return std.fs.path.resolve(alloc, paths) catch "";
            \\    full[0] = cwd_buf[0..cwd_len];
            \\    @memcpy(full[1..], paths);
            \\    return std.fs.path.resolve(alloc, full) catch "";
            \\}
            \\fn __pathJoin(alloc: std.mem.Allocator, paths: []const []const u8) []const u8 {
            \\    const naive = std.fs.path.join(alloc, paths) catch return "";
            \\    return std.fs.path.resolve(alloc, &.{naive}) catch naive;
            \\}
            \\fn __pathParse(path: []const u8) __LumenPathParts {
            \\    const ext = std.fs.path.extension(path);
            \\    const base = std.fs.path.basename(path);
            \\    return .{
            \\        .root = if (std.fs.path.isAbsolute(path)) "/" else "",
            \\        .dir = std.fs.path.dirname(path) orelse "",
            \\        .base = base,
            \\        .name = base[0 .. base.len - ext.len],
            \\        .ext = ext,
            \\    };
            \\}
            \\fn __pathFormat(alloc: std.mem.Allocator, parts: __LumenPathParts) []const u8 {
            \\    const dir = if (parts.dir.len > 0) parts.dir else parts.root;
            \\    const base = if (parts.base.len > 0) parts.base else std.fmt.allocPrint(alloc, "{s}{s}", .{ parts.name, parts.ext }) catch "";
            \\    if (dir.len == 0) return base;
            \\    if (dir[dir.len - 1] == '/') return std.fmt.allocPrint(alloc, "{s}{s}", .{ dir, base }) catch base;
            \\    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, base }) catch base;
            \\}
            \\
        );
    }
    if (program.needs_url_api) {
        // url.* (spec 036): the runtime's own URI type (the same one used
        // elsewhere for HTTP requests) does the real parsing; this just walks
        // its already-decoded component fields into a plain record. Pure
        // string work otherwise, same as path -- no syscalls, works
        // identically on the native and wasm targets.
        try out.appendSlice(arena,
            \\pub const __LumenUrlParts = struct { protocol: []const u8, hostname: []const u8, port: []const u8, pathname: []const u8, search: []const u8, hash: []const u8, href: []const u8, query: *LumenMap([]const u8, []const u8) };
            \\fn __urlParseQuery(alloc: std.mem.Allocator, search: []const u8) *LumenMap([]const u8, []const u8) {
            \\    const m = LumenMap([]const u8, []const u8).__init();
            \\    const q = if (search.len > 0 and search[0] == '?') search[1..] else search;
            \\    var it = std.mem.tokenizeScalar(u8, q, '&');
            \\    while (it.next()) |pair| {
            \\        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            \\        const key = alloc.dupe(u8, pair[0..eq]) catch continue;
            \\        const value = alloc.dupe(u8, pair[eq + 1 ..]) catch continue;
            \\        m.set(key, value);
            \\    }
            \\    return m;
            \\}
            \\fn __urlParse(alloc: std.mem.Allocator, str: []const u8) __LumenUrlParts {
            \\    const href = alloc.dupe(u8, str) catch str;
            \\    const parsed = std.Uri.parse(str) catch return .{
            \\        .protocol = "", .hostname = "", .port = "", .pathname = "/", .search = "", .hash = "", .href = href,
            \\        .query = LumenMap([]const u8, []const u8).__init(),
            \\    };
            \\    const protocol = std.fmt.allocPrint(alloc, "{s}:", .{parsed.scheme}) catch "";
            \\    const hostname = if (parsed.host) |h| (h.toRawMaybeAlloc(alloc) catch "") else "";
            \\    const port = if (parsed.port) |p| (std.fmt.allocPrint(alloc, "{d}", .{p}) catch "") else "";
            \\    const raw_path = parsed.path.toRawMaybeAlloc(alloc) catch "/";
            \\    const pathname = if (raw_path.len == 0) "/" else raw_path;
            \\    const search = if (parsed.query) |q| (std.fmt.allocPrint(alloc, "?{s}", .{q.toRawMaybeAlloc(alloc) catch ""}) catch "") else "";
            \\    const hash = if (parsed.fragment) |f| (std.fmt.allocPrint(alloc, "#{s}", .{f.toRawMaybeAlloc(alloc) catch ""}) catch "") else "";
            \\    return .{
            \\        .protocol = protocol,
            \\        .hostname = hostname,
            \\        .port = port,
            \\        .pathname = pathname,
            \\        .search = search,
            \\        .hash = hash,
            \\        .href = href,
            \\        .query = __urlParseQuery(alloc, search),
            \\    };
            \\}
            \\fn __urlFormat(alloc: std.mem.Allocator, parts: __LumenUrlParts) []const u8 {
            \\    const host_port = if (parts.port.len > 0) (std.fmt.allocPrint(alloc, "{s}:{s}", .{ parts.hostname, parts.port }) catch parts.hostname) else parts.hostname;
            \\    return std.fmt.allocPrint(alloc, "{s}//{s}{s}{s}{s}", .{ parts.protocol, host_port, parts.pathname, parts.search, parts.hash }) catch "";
            \\}
            \\
        );
    }
    if (program.needs_child_process_api) {
        // child_process.spawnSync (spec 037): stdout and stderr are read to
        // completion sequentially, then wait() -- a command that writes more
        // than one pipe buffer (~64KB on Linux) to stderr while this is still
        // blocked reading stdout could deadlock. Documented, accepted v1
        // trade-off: real commands' stderr output is typically small.
        try out.appendSlice(arena,
            \\pub const __LumenSpawnResult = struct { stdout: []const u8, stderr: []const u8, status: i32 };
            \\fn __spawnSync(io: std.Io, alloc: std.mem.Allocator, command: []const u8, args: []const []const u8) __LumenSpawnResult {
            \\    const argv = alloc.alloc([]const u8, 1 + args.len) catch return .{ .stdout = "", .stderr = "", .status = -1 };
            \\    argv[0] = command;
            \\    for (args, 0..) |a, i| argv[i + 1] = a;
            \\    var child = std.process.spawn(io, .{
            \\        .argv = argv,
            \\        .stdin = .ignore,
            \\        .stdout = .pipe,
            \\        .stderr = .pipe,
            \\    }) catch return .{ .stdout = "", .stderr = "", .status = -1 };
            \\    var out_buf: [4096]u8 = undefined;
            \\    var out_reader = child.stdout.?.reader(io, &out_buf);
            \\    const stdout_data = out_reader.interface.allocRemaining(alloc, .limited(16 * 1024 * 1024)) catch &.{};
            \\    var err_buf: [4096]u8 = undefined;
            \\    var err_reader = child.stderr.?.reader(io, &err_buf);
            \\    const stderr_data = err_reader.interface.allocRemaining(alloc, .limited(16 * 1024 * 1024)) catch &.{};
            \\    const term = child.wait(io) catch return .{ .stdout = stdout_data, .stderr = stderr_data, .status = -1 };
            \\    const status: i32 = switch (term) {
            \\        .exited => |code| code,
            \\        else => -1,
            \\    };
            \\    return .{ .stdout = stdout_data, .stderr = stderr_data, .status = status };
            \\}
            \\
        );
    }
    if (program.needs_assert) {
        // assert.* wraps the language's own panic mechanism, not the throw/
        // catch machinery (a static call has no access to an enclosing
        // try's throw target) -- a failed assertion crashes the program,
        // uncatchable, the same idiom as C's assert() or an uncaught Node
        // AssertionError.
        try out.appendSlice(arena,
            \\fn __assertOk(cond: bool) void {
            \\    if (!cond) @panic("AssertionError: assert.ok failed");
            \\}
            \\fn __assertEqual(a: anytype, b: anytype) void {
            \\    if (a != b) std.debug.panic("AssertionError: {any} != {any}", .{ a, b });
            \\}
            \\fn __assertStrEqual(a: []const u8, b: []const u8) void {
            \\    if (!std.mem.eql(u8, a, b)) std.debug.panic("AssertionError: \"{s}\" != \"{s}\"", .{ a, b });
            \\}
            \\
        );
    }
    if (program.needs_time_api) {
        // time.now()/monotonic() (spec 041): one clock read each, the same
        // primitive that already backs fs.mkdtempSync's uniqueness suffix.
        // Milliseconds as i64, not int: real epoch milliseconds hugely
        // exceeds a 32-bit range, so truncating the way os.totalmem() does
        // would make the result meaningless rather than an occasional
        // deviation.
        try out.appendSlice(arena,
            \\fn __timeNow(io: std.Io) i64 {
            \\    const ts = std.Io.Clock.now(.real, io);
            \\    return @intCast(@divTrunc(ts.nanoseconds, 1_000_000));
            \\}
            \\fn __timeMonotonic(io: std.Io) i64 {
            \\    const ts = std.Io.Clock.now(.awake, io);
            \\    return @intCast(@divTrunc(ts.nanoseconds, 1_000_000));
            \\}
            \\
        );
    }
    if (program.needs_console_stdout) {
        // console.log/info/debug (spec 048): a real stdout writer. Unlike
        // std.debug.print (which always targets stderr -- the mechanism
        // console.error/warn/trace still use directly), stdout needs the
        // __io-backed std.Io.File writer, the same pattern the compiler
        // CLI's own error reporting already uses for stderr.
        //
        // Bug found in review (spec 046's Streams work hit the same class
        // of bug earlier this session): File.writer() defaults to
        // *positional* writing (each write happens via a position that
        // resets per Writer instance, not a continuing stream position) --
        // its own doc comment says so explicitly ("Positional is more
        // threadsafe, since the global seek position is not affected").
        // Since __consoleOut creates a fresh Writer on every call, every
        // call after the first silently overwrote the previous one instead
        // of appending, when stdout was a redirected file/pipe (as the
        // conformance harness itself does) -- confirmed directly: three
        // console.log calls to a file only left the last line's content.
        // writerStreaming() is the sequential-append variant Streams
        // already established as the correct choice for a real stream like
        // stdout, not a seekable file.
        try out.appendSlice(arena,
            \\fn __consoleOut(comptime __fmt: []const u8, __args: anytype) void {
            \\    var __buf: [4096]u8 = undefined;
            \\    var __w = std.Io.File.stdout().writerStreaming(__io, &__buf);
            \\    __w.interface.print(__fmt, __args) catch return;
            \\    __w.interface.flush() catch {};
            \\}
            \\
        );
    }
    if (program.needs_http_module) {
        // http.request/get (spec 042): one-shot client request via
        // std.http.Client.fetch, with a real method/payload/response body
        // -- a genuine capability upgrade over the old status-only
        // httpGet global. Response headers aren't surfaced: fetch's
        // convenience wrapper only exposes status, reading headers needs
        // the lower-level request/response flow underneath it.
        try out.appendSlice(arena,
            \\pub const __LumenHttpResponse = struct { status: i32, body: []const u8, ok: bool, headers: *LumenMap([]const u8, []const u8) };
            \\fn __httpRequest(io: std.Io, alloc: std.mem.Allocator, url: []const u8, method: []const u8, body: []const u8, headers: *LumenMap([]const u8, []const u8)) __LumenHttpResponse {
            \\    var client: std.http.Client = .{ .allocator = alloc, .io = io };
            \\    defer client.deinit();
            \\    // Loading the system CA bundle means reading and parsing a real
            \\    // certificate file from disk -- skip it entirely for plain http://
            \\    // requests, which never need it, rather than paying that cost on
            \\    // every single call regardless of scheme.
            \\    const resp_headers = LumenMap([]const u8, []const u8).__init();
            \\    if (std.mem.startsWith(u8, url, "https://")) {
            \\        client.ca_bundle.rescan(alloc, io, std.Io.Clock.now(.real, io)) catch return .{ .status = -1, .body = "", .ok = false, .headers = resp_headers };
            \\    }
            \\    const extra_headers = alloc.alloc(std.http.Header, headers.keys_.items.len) catch unreachable;
            \\    for (headers.keys_.items, headers.values_.items, 0..) |k, v, i| extra_headers[i] = .{ .name = k, .value = v };
            \\    var resp_writer: std.Io.Writer.Allocating = .init(alloc);
            \\    const http_method = std.meta.stringToEnum(std.http.Method, method) orelse .GET;
            \\    const payload: ?[]const u8 = if (body.len > 0) body else null;
            \\    const res = client.fetch(.{
            \\        .location = .{ .url = url },
            \\        .method = http_method,
            \\        .payload = payload,
            \\        .extra_headers = extra_headers,
            \\        .response_writer = &resp_writer.writer,
            \\    }) catch return .{ .status = -1, .body = "", .ok = false, .headers = resp_headers };
            \\    const status_code: i32 = @intFromEnum(res.status);
            \\    // Response headers deliberately not populated yet: fetch()'s
            \\    // convenience wrapper only surfaces status. Reading them for real
            \\    // needs the lower-level client.request()/receiveHead()/
            \\    // iterateHeaders() flow underneath it -- confirmed reachable by
            \\    // reading the source, but restructuring this already-working,
            \\    // already-benchmarked call risked regressing it under time
            \\    // pressure, so it's a deliberate, documented follow-up rather
            \\    // than a rushed rewrite (spec 045).
            \\    return .{ .status = status_code, .body = resp_writer.written(), .ok = status_code >= 200 and status_code < 300, .headers = resp_headers };
            \\}
            \\
        );
    }
    if (program.needs_http_server) {
        // http.createServer (spec 042 Phase 2, concurrency in spec 049): a
        // real request-inspecting server, superseding the old canned-response
        // serve() global. Real HTTP/1.1 request-line + header parsing
        // (method, path, Content-Length-based body), reusing the exact
        // manual parsing approach the playground's own compile service
        // already proves works.
        //
        // HTTP keep-alive: the reader/writer (and the underlying buffered
        // state) are set up once per accepted connection, then an inner
        // loop reads and answers requests off that same stream until the
        // client either sends `Connection: close` or the connection drops.
        // Benchmarked ~1.3-1.5x slower than Node's http.createServer before
        // this; root cause was closing the connection after every single
        // response (a fresh TCP handshake per request), the same gap this
        // closes.
        try out.appendSlice(arena,
            \\pub const __LumenHttpRequest = struct { method: []const u8, path: []const u8, body: []const u8 };
            \\
        );
        if (needs_http_threadpool) {
            // Concurrent serving (spec 049): the accept loop used to handle
            // one connection fully (through keep-alive, to disconnect)
            // before looping back to accept() the next one -- genuinely one
            // connection at a time, no concurrency, documented as a known
            // gap in spec 042's Not-planned table. Fixed here by handing
            // each accepted connection's *entire* handling (the keep-alive
            // inner loop below, unchanged from the single-threaded version)
            // to a worker thread from a dedicated libxev `ThreadPool`
            // (`src/ThreadPool.zig` -- a real, generic, standalone
            // worker-thread pool with no OS-specific or event-loop
            // integration required, already proven inside libxev's own
            // kqueue backend), so `accept()` can immediately loop back for
            // the next connection while earlier ones are still being
            // served. `http.createServer` is `noreturn` and never needs to
            // signal a result back to the main thread, so unlike an
            // async-fs-Promise scenario (spec 047), no `xev.Async`/
            // completion-queue wake-up bridge is needed here -- each worker
            // just handles its connection to completion and returns.
            //
            // Known trade-off, documented rather than silently ignored: the
            // handler now genuinely runs on multiple OS threads
            // concurrently. If a handler mutates shared global state,
            // that's now a real data race -- exactly as it would be in any
            // multi-threaded server in any language. Not addressed here
            // (would need a general-purpose locking primitive Lumen doesn't
            // have yet); documented in website/stdlib.html.
            try out.appendSlice(arena,
                \\var __http_pool: xev.ThreadPool = undefined;
                \\fn __httpCreateServer(io: std.Io, alloc: std.mem.Allocator, port: i32, handler: anytype) noreturn {
                \\    _ = alloc;
                \\    const addr = std.Io.net.IpAddress.parse("0.0.0.0", @intCast(port)) catch std.process.exit(1);
                \\    var server = addr.listen(io, .{ .reuse_address = true }) catch std.process.exit(1);
                \\    // `ThreadPool.init` reads the CPU count via a runtime syscall
                \\    // (`std.Thread.getCpuCount`) when `max_threads` isn't set --
                \\    // not comptime-known, so this can't be a container-level
                \\    // initializer (`var x = ThreadPool.init(.{})` at file scope
                \\    // fails to compile: "initializer of container-level variable
                \\    // must be comptime-known"). Initialized here instead, once,
                \\    // before the accept loop starts.
                \\    __http_pool = xev.ThreadPool.init(.{});
                \\    const Handler = @TypeOf(handler);
                \\    const Conn = struct {
                \\        task: xev.ThreadPool.Task = .{ .callback = run },
                \\        io: std.Io,
                \\        stream: std.Io.net.Stream,
                \\        handler: Handler,
                \\        fn run(t: *xev.ThreadPool.Task) void {
                \\            const self: *@This() = @fieldParentPtr("task", t);
                \\            defer std.heap.page_allocator.destroy(self);
                \\            const io2 = self.io;
                \\            const stream = self.stream;
                \\            defer stream.close(io2);
                \\            var read_buf: [16 * 1024]u8 = undefined;
                \\            var reader = stream.reader(io2, &read_buf);
                \\            const r = &reader.interface;
                \\            var write_buf: [16 * 1024]u8 = undefined;
                \\            var writer = stream.writer(io2, &write_buf);
                \\            const w = &writer.interface;
                \\            conn: while (true) {
                \\                var conn_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                \\                defer conn_arena.deinit();
                \\                const carena = conn_arena.allocator();
                \\                const first = r.takeDelimiterInclusive('\n') catch break :conn;
                \\                const line = std.mem.trimEnd(u8, first, "\r\n");
                \\                var it = std.mem.tokenizeScalar(u8, line, ' ');
                \\                const method = it.next() orelse break :conn;
                \\                const path = it.next() orelse break :conn;
                \\                var content_length: usize = 0;
                \\                var keep_alive = true;
                \\                while (true) {
                \\                    const raw = r.takeDelimiterInclusive('\n') catch break;
                \\                    const h = std.mem.trimEnd(u8, raw, "\r\n");
                \\                    if (h.len == 0) break;
                \\                    const colon = std.mem.indexOfScalar(u8, h, ':') orelse continue;
                \\                    const name = std.mem.trim(u8, h[0..colon], " \t");
                \\                    const value = std.mem.trim(u8, h[colon + 1 ..], " \t");
                \\                    if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                \\                        content_length = std.fmt.parseInt(usize, value, 10) catch 0;
                \\                    } else if (std.ascii.eqlIgnoreCase(name, "connection") and std.ascii.eqlIgnoreCase(value, "close")) {
                \\                        keep_alive = false;
                \\                    }
                \\                }
                \\                const body = carena.alloc(u8, content_length) catch break :conn;
                \\                r.readSliceAll(body) catch break :conn;
                \\                const req: __LumenHttpRequest = .{
                \\                    .method = carena.dupe(u8, method) catch break :conn,
                \\                    .path = carena.dupe(u8, path) catch break :conn,
                \\                    .body = body,
                \\                };
                \\                const res = self.handler.call(self.handler.ctx, req);
                \\                const conn_header: []const u8 = if (keep_alive) "keep-alive" else "close";
                \\                w.print("HTTP/1.1 {d} OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: {s}\r\n", .{ res.status, res.body.len, conn_header }) catch break :conn;
                \\                for (res.headers.keys_.items, res.headers.values_.items) |hk, hv| {
                \\                    w.print("{s}: {s}\r\n", .{ hk, hv }) catch break :conn;
                \\                }
                \\                w.writeAll("\r\n") catch break :conn;
                \\                w.writeAll(res.body) catch break :conn;
                \\                w.flush() catch break :conn;
                \\                if (!keep_alive) break :conn;
                \\            }
                \\        }
                \\    };
                \\    while (true) {
                \\        const stream = server.accept(io) catch continue;
                \\        const conn = std.heap.page_allocator.create(Conn) catch {
                \\            stream.close(io);
                \\            continue;
                \\        };
                \\        conn.* = .{ .io = io, .stream = stream, .handler = handler };
                \\        __http_pool.schedule(xev.ThreadPool.Batch.from(&conn.task));
                \\    }
                \\}
                \\
            );
        } else {
            // wasm32-wasi: no real OS threads, and the CLI's own libxev-
            // wiring gate hard-fails any wasm build that references
            // `@import("xev")` at all (async isn't supported there yet, see
            // `compileFile` in lumen.zig) -- so this target keeps the
            // original single-connection-at-a-time loop rather than the
            // thread-pool version above. Matches this function's own
            // pre-spec-049 behavior exactly, not a new limitation.
            try out.appendSlice(arena,
                \\fn __httpCreateServer(io: std.Io, alloc: std.mem.Allocator, port: i32, handler: anytype) noreturn {
                \\    _ = alloc;
                \\    const addr = std.Io.net.IpAddress.parse("0.0.0.0", @intCast(port)) catch std.process.exit(1);
                \\    var server = addr.listen(io, .{ .reuse_address = true }) catch std.process.exit(1);
                \\    while (true) {
                \\        const stream = server.accept(io) catch continue;
                \\        defer stream.close(io);
                \\        var read_buf: [16 * 1024]u8 = undefined;
                \\        var reader = stream.reader(io, &read_buf);
                \\        const r = &reader.interface;
                \\        var write_buf: [16 * 1024]u8 = undefined;
                \\        var writer = stream.writer(io, &write_buf);
                \\        const w = &writer.interface;
                \\        conn: while (true) {
                \\            var conn_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                \\            defer conn_arena.deinit();
                \\            const carena = conn_arena.allocator();
                \\            const first = r.takeDelimiterInclusive('\n') catch break :conn;
                \\            const line = std.mem.trimEnd(u8, first, "\r\n");
                \\            var it = std.mem.tokenizeScalar(u8, line, ' ');
                \\            const method = it.next() orelse break :conn;
                \\            const path = it.next() orelse break :conn;
                \\            var content_length: usize = 0;
                \\            var keep_alive = true;
                \\            while (true) {
                \\                const raw = r.takeDelimiterInclusive('\n') catch break;
                \\                const h = std.mem.trimEnd(u8, raw, "\r\n");
                \\                if (h.len == 0) break;
                \\                const colon = std.mem.indexOfScalar(u8, h, ':') orelse continue;
                \\                const name = std.mem.trim(u8, h[0..colon], " \t");
                \\                const value = std.mem.trim(u8, h[colon + 1 ..], " \t");
                \\                if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                \\                    content_length = std.fmt.parseInt(usize, value, 10) catch 0;
                \\                } else if (std.ascii.eqlIgnoreCase(name, "connection") and std.ascii.eqlIgnoreCase(value, "close")) {
                \\                    keep_alive = false;
                \\                }
                \\            }
                \\            const body = carena.alloc(u8, content_length) catch break :conn;
                \\            r.readSliceAll(body) catch break :conn;
                \\            const req: __LumenHttpRequest = .{
                \\                .method = carena.dupe(u8, method) catch break :conn,
                \\                .path = carena.dupe(u8, path) catch break :conn,
                \\                .body = body,
                \\            };
                \\            const res = handler.call(handler.ctx, req);
                \\            const conn_header: []const u8 = if (keep_alive) "keep-alive" else "close";
                \\            w.print("HTTP/1.1 {d} OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: {s}\r\n", .{ res.status, res.body.len, conn_header }) catch break :conn;
                \\            for (res.headers.keys_.items, res.headers.values_.items) |hk, hv| {
                \\                w.print("{s}: {s}\r\n", .{ hk, hv }) catch break :conn;
                \\            }
                \\            w.writeAll("\r\n") catch break :conn;
                \\            w.writeAll(res.body) catch break :conn;
                \\            w.flush() catch break :conn;
                \\            if (!keep_alive) break :conn;
                \\        }
                \\    }
                \\}
                \\
            );
        }
    }
    if (program.needs_net) {
        // net.connect/net.createServer (spec 054): raw TCP, the layer
        // http's own client/server are already built on but didn't expose
        // directly to Lumen source. LumenSocket wraps a std.Io.net.Stream
        // exactly the way LumenReadableStream/LumenWritableStream (spec
        // 046) wrap a std.Io.File -- an optional stream (null for a
        // failed/refused connect) plus heap-allocated reader/writer
        // buffers via __sa(), degrading to "always read empty, write is a
        // no-op" rather than crashing on a dead connection, the same
        // fallback convention every fs-stream/http path already uses.
        // close() is idempotent (`closed` flag) because
        // net.createServer's accept loop always closes the socket after
        // the handler returns, whether or not the handler already closed
        // it itself.
        try out.appendSlice(arena,
            \\pub const LumenSocket = struct {
            \\    stream: ?std.Io.net.Stream,
            \\    io: std.Io,
            \\    reader: std.Io.net.Stream.Reader = undefined,
            \\    writer: std.Io.net.Stream.Writer = undefined,
            \\    closed: bool = false,
            \\    fn __init(io: std.Io, stream: ?std.Io.net.Stream) *LumenSocket {
            \\        const p = __sa().create(LumenSocket) catch unreachable;
            \\        p.* = .{ .stream = stream, .io = io };
            \\        if (stream) |s| {
            \\            const rbuf = __sa().alloc(u8, 65536) catch unreachable;
            \\            p.reader = s.reader(io, rbuf);
            \\            const wbuf = __sa().alloc(u8, 65536) catch unreachable;
            \\            p.writer = s.writer(io, wbuf);
            \\        }
            \\        return p;
            \\    }
            \\    fn read(self: *LumenSocket) []const u8 {
            \\        if (self.stream == null or self.closed) return "";
            \\        var scratch: [65536]u8 = undefined;
            \\        const n = self.reader.interface.readSliceShort(&scratch) catch return "";
            \\        if (n == 0) return "";
            \\        return __sa().dupe(u8, scratch[0..n]) catch "";
            \\    }
            \\    fn write(self: *LumenSocket, chunk: []const u8) void {
            \\        if (self.stream == null or self.closed) return;
            \\        self.writer.interface.writeAll(chunk) catch return;
            \\        // Flushes on every call, unlike WritableStream (which defers
            \\        // to .close()): a long-lived socket conversation has no
            \\        // single "I'm done" moment the way a one-shot file write
            \\        // does, so buffering until some later .close() would mean
            \\        // the peer never sees the bytes in time. Matches
            \\        // http.createServer's own per-response w.flush() call.
            \\        self.writer.interface.flush() catch {};
            \\    }
            \\    fn close(self: *LumenSocket) void {
            \\        if (self.closed) return;
            \\        self.closed = true;
            \\        if (self.stream) |s| {
            \\            self.writer.interface.flush() catch {};
            \\            s.close(self.io);
            \\        }
            \\    }
            \\};
            \\
        );
        if (program.needs_net_client) {
            try out.appendSlice(arena,
                \\fn __netConnect(io: std.Io, host: []const u8, port: i32) *LumenSocket {
                \\    const hn = std.Io.net.HostName.init(host) catch return LumenSocket.__init(io, null);
                \\    const stream = hn.connect(io, @intCast(port), .{ .mode = .stream }) catch return LumenSocket.__init(io, null);
                \\    return LumenSocket.__init(io, stream);
                \\}
                \\
            );
        }
        if (program.needs_net_server) {
            // Single connection at a time for v1 (spec 054's documented
            // scope, not yet given the spec 049 xev.ThreadPool treatment
            // http.createServer got -- no benchmark or prior request/
            // response cadence exists yet to justify it for raw bytes).
            // Mirrors __httpCreateServer's non-threadpool branch exactly.
            try out.appendSlice(arena,
                \\fn __netCreateServer(io: std.Io, alloc: std.mem.Allocator, port: i32, handler: anytype) noreturn {
                \\    _ = alloc;
                \\    const addr = std.Io.net.IpAddress.parse("0.0.0.0", @intCast(port)) catch std.process.exit(1);
                \\    var server = addr.listen(io, .{ .reuse_address = true }) catch std.process.exit(1);
                \\    while (true) {
                \\        const stream = server.accept(io) catch continue;
                \\        const sock = LumenSocket.__init(io, stream);
                \\        handler.call(handler.ctx, sock);
                \\        sock.close();
                \\    }
                \\}
                \\
            );
        }
    }
    if (program.needs_http_constants) {
        // http.METHODS/STATUS_CODES (spec 049): plain constant data, the
        // real lists Node itself uses -- METHODS from llhttp's own
        // HTTP_METHOD_MAP (checked directly against
        // deps/llhttp/include/llhttp.h in Node's own source, not
        // guessed), alphabetically sorted, matching Node's actual runtime
        // `http.METHODS` output (`methods.slice().sort()`); STATUS_CODES
        // from Node's lib/_http_server.js STATUS_CODES object, verbatim.
        // STATUS_CODES returns `Map<int, string>`, constructed the same
        // way spec 045 first proved a stdlib builtin safely can (build a
        // `LumenMap` internally, `.set()` in a loop, hand back the
        // pointer).
        try out.appendSlice(arena,
            \\fn __httpMethods() []const []const u8 {
            \\    return &.{
            \\        "ACL",       "BIND",     "CHECKOUT", "CONNECT",     "COPY",       "DELETE",
            \\        "GET",       "HEAD",     "LINK",     "LOCK",        "M-SEARCH",   "MERGE",
            \\        "MKACTIVITY", "MKCALENDAR", "MKCOL", "MOVE",        "NOTIFY",     "OPTIONS",
            \\        "PATCH",     "POST",     "PROPFIND", "PROPPATCH",   "PURGE",      "PUT",
            \\        "QUERY",     "REBIND",   "REPORT",   "SEARCH",      "SOURCE",     "SUBSCRIBE",
            \\        "TRACE",     "UNBIND",   "UNLINK",   "UNLOCK",      "UNSUBSCRIBE",
            \\    };
            \\}
            \\fn __httpStatusCodes() *LumenMap(i32, []const u8) {
            \\    const m = LumenMap(i32, []const u8).__init();
            \\    const entries = [_]struct { code: i32, reason: []const u8 }{
            \\        .{ .code = 100, .reason = "Continue" },
            \\        .{ .code = 101, .reason = "Switching Protocols" },
            \\        .{ .code = 102, .reason = "Processing" },
            \\        .{ .code = 103, .reason = "Early Hints" },
            \\        .{ .code = 200, .reason = "OK" },
            \\        .{ .code = 201, .reason = "Created" },
            \\        .{ .code = 202, .reason = "Accepted" },
            \\        .{ .code = 203, .reason = "Non-Authoritative Information" },
            \\        .{ .code = 204, .reason = "No Content" },
            \\        .{ .code = 205, .reason = "Reset Content" },
            \\        .{ .code = 206, .reason = "Partial Content" },
            \\        .{ .code = 207, .reason = "Multi-Status" },
            \\        .{ .code = 208, .reason = "Already Reported" },
            \\        .{ .code = 226, .reason = "IM Used" },
            \\        .{ .code = 300, .reason = "Multiple Choices" },
            \\        .{ .code = 301, .reason = "Moved Permanently" },
            \\        .{ .code = 302, .reason = "Found" },
            \\        .{ .code = 303, .reason = "See Other" },
            \\        .{ .code = 304, .reason = "Not Modified" },
            \\        .{ .code = 305, .reason = "Use Proxy" },
            \\        .{ .code = 307, .reason = "Temporary Redirect" },
            \\        .{ .code = 308, .reason = "Permanent Redirect" },
            \\        .{ .code = 400, .reason = "Bad Request" },
            \\        .{ .code = 401, .reason = "Unauthorized" },
            \\        .{ .code = 402, .reason = "Payment Required" },
            \\        .{ .code = 403, .reason = "Forbidden" },
            \\        .{ .code = 404, .reason = "Not Found" },
            \\        .{ .code = 405, .reason = "Method Not Allowed" },
            \\        .{ .code = 406, .reason = "Not Acceptable" },
            \\        .{ .code = 407, .reason = "Proxy Authentication Required" },
            \\        .{ .code = 408, .reason = "Request Timeout" },
            \\        .{ .code = 409, .reason = "Conflict" },
            \\        .{ .code = 410, .reason = "Gone" },
            \\        .{ .code = 411, .reason = "Length Required" },
            \\        .{ .code = 412, .reason = "Precondition Failed" },
            \\        .{ .code = 413, .reason = "Payload Too Large" },
            \\        .{ .code = 414, .reason = "URI Too Long" },
            \\        .{ .code = 415, .reason = "Unsupported Media Type" },
            \\        .{ .code = 416, .reason = "Range Not Satisfiable" },
            \\        .{ .code = 417, .reason = "Expectation Failed" },
            \\        .{ .code = 418, .reason = "I'm a Teapot" },
            \\        .{ .code = 421, .reason = "Misdirected Request" },
            \\        .{ .code = 422, .reason = "Unprocessable Entity" },
            \\        .{ .code = 423, .reason = "Locked" },
            \\        .{ .code = 424, .reason = "Failed Dependency" },
            \\        .{ .code = 425, .reason = "Too Early" },
            \\        .{ .code = 426, .reason = "Upgrade Required" },
            \\        .{ .code = 428, .reason = "Precondition Required" },
            \\        .{ .code = 429, .reason = "Too Many Requests" },
            \\        .{ .code = 431, .reason = "Request Header Fields Too Large" },
            \\        .{ .code = 451, .reason = "Unavailable For Legal Reasons" },
            \\        .{ .code = 500, .reason = "Internal Server Error" },
            \\        .{ .code = 501, .reason = "Not Implemented" },
            \\        .{ .code = 502, .reason = "Bad Gateway" },
            \\        .{ .code = 503, .reason = "Service Unavailable" },
            \\        .{ .code = 504, .reason = "Gateway Timeout" },
            \\        .{ .code = 505, .reason = "HTTP Version Not Supported" },
            \\        .{ .code = 506, .reason = "Variant Also Negotiates" },
            \\        .{ .code = 507, .reason = "Insufficient Storage" },
            \\        .{ .code = 508, .reason = "Loop Detected" },
            \\        .{ .code = 509, .reason = "Bandwidth Limit Exceeded" },
            \\        .{ .code = 510, .reason = "Not Extended" },
            \\        .{ .code = 511, .reason = "Network Authentication Required" },
            \\    };
            \\    for (entries) |e| m.set(e.code, e.reason);
            \\    return m;
            \\}
            \\
        );
    }
    if (program.needs_json) {
        // JSON.stringify/JSON.parse<T> (spec 051): thin wrappers around
        // std.json's own automatic struct/slice reflection. Lumen record
        // types already lower to real Zig structs with matching field
        // names, confirmed directly (not assumed) that
        // Stringify.valueAlloc/parseFromSlice both round-trip an arbitrary
        // struct correctly with zero custom (de)serialization code. Parse
        // failures fall back to std.mem.zeroes(T), the same "fallback,
        // don't crash" shape every other fallible builtin here uses --
        // for a string field this is a valid empty slice, not a null
        // dereference risk (confirmed, not assumed). The Parsed(T)
        // wrapper's own arena is deliberately never deinit'd, matching
        // this runtime's established "arena everything, reclaim on exit"
        // convention elsewhere.
        try out.appendSlice(arena,
            \\fn __jsonStringify(alloc: std.mem.Allocator, value: anytype) []const u8 {
            \\    return std.json.Stringify.valueAlloc(alloc, value, .{}) catch "";
            \\}
            \\fn __jsonParse(comptime T: type, alloc: std.mem.Allocator, text: []const u8) T {
            \\    const parsed = std.json.parseFromSlice(T, alloc, text, .{}) catch return std.mem.zeroes(T);
            \\    return parsed.value;
            \\}
            \\
        );
    }
    if (program.needs_process_api) {
        // cwd/chdir/env go through Io-abstracted (cwd/chdir) or entry-captured
        // (env, same mechanism as __args) primitives -- none of these need
        // libc linking. platform/arch are resolved at compile time.
        try out.appendSlice(arena,
            \\fn __processCwd(io: std.Io, alloc: std.mem.Allocator) []const u8 {
            \\    var buf: [std.fs.max_path_bytes]u8 = undefined;
            \\    const n = std.process.currentPath(io, &buf) catch return "";
            \\    return alloc.dupe(u8, buf[0..n]) catch "";
            \\}
            \\fn __processChdir(io: std.Io, path: []const u8) void {
            \\    std.process.setCurrentPath(io, path) catch {};
            \\}
            \\fn __processEnv(key: []const u8) ?[]const u8 {
            \\    const v = std.process.Environ.getPosix(__environ, key) orelse return null;
            \\    return v;
            \\}
            \\fn __processPlatform() []const u8 {
            \\    return switch (@import("builtin").os.tag) {
            \\        .linux => "linux",
            \\        .macos => "darwin",
            \\        .windows => "win32",
            \\        .freebsd => "freebsd",
            \\        .openbsd => "openbsd",
            \\        else => "unknown",
            \\    };
            \\}
            \\fn __processArch() []const u8 {
            \\    return switch (@import("builtin").cpu.arch) {
            \\        .x86_64 => "x64",
            \\        .x86 => "ia32",
            \\        .aarch64 => "arm64",
            \\        .arm => "arm",
            \\        .riscv64 => "riscv64",
            \\        else => "unknown",
            \\    };
            \\}
            \\fn __processPid() i32 {
            \\    if (@import("builtin").os.tag != .linux) return 0;
            \\    return @intCast(std.os.linux.getpid());
            \\}
            \\
        );
        // process API completion (spec 050). uptime()/hrtime() reuse the
        // same Io.Clock primitive spec 041's time.now()/time.monotonic()
        // already wired up. memoryUsage() reads /proc/self/status with the
        // same readFileAlloc primitive fs.readFileSync already uses. kill/
        // umask/getuid-family are raw Linux syscalls, no libc. version() is
        // a hardcoded marker -- see spec.md for why it isn't Node's.
        try out.appendSlice(arena,
            \\const LUMEN_VERSION: []const u8 = "0.3.1";
            \\fn __processHrtime(io: std.Io) i64 {
            \\    const ts = std.Io.Clock.now(.awake, io);
            \\    return @intCast(ts.nanoseconds);
            \\}
            \\pub const __LumenProcessMemory = struct { rss: i64, vsize: i64 };
            \\fn __processStatusField(text: []const u8, label: []const u8) i64 {
            \\    var lines = std.mem.splitScalar(u8, text, '\n');
            \\    while (lines.next()) |line| {
            \\        if (!std.mem.startsWith(u8, line, label)) continue;
            \\        const rest = std.mem.trim(u8, line[label.len..], " \t");
            \\        var it = std.mem.splitScalar(u8, rest, ' ');
            \\        const num = it.next() orelse return 0;
            \\        const kb = std.fmt.parseInt(i64, num, 10) catch return 0;
            \\        return kb * 1024;
            \\    }
            \\    return 0;
            \\}
            \\fn __processMemoryUsage(io: std.Io, alloc: std.mem.Allocator) __LumenProcessMemory {
            \\    // /proc entries report st_size == 0, which silently short-circuits
            \\    // Dir.readFileAlloc's default *positional* reader (confirmed by
            \\    // testing directly: it returns a 0-length read for this exact
            \\    // path). readerStreaming does a real sequential read loop instead
            \\    // and reads the real content correctly -- same fix fs.readFileSync
            \\    // doesn't need for ordinary files, but /proc pseudo-files do.
            \\    var file = std.Io.Dir.cwd().openFile(io, "/proc/self/status", .{}) catch return .{ .rss = 0, .vsize = 0 };
            \\    defer file.close(io);
            \\    var buf: [512]u8 = undefined;
            \\    var file_reader = file.readerStreaming(io, &buf);
            \\    const text = file_reader.interface.allocRemaining(alloc, .limited(64 * 1024)) catch return .{ .rss = 0, .vsize = 0 };
            \\    return .{
            \\        .rss = __processStatusField(text, "VmRSS:"),
            \\        .vsize = __processStatusField(text, "VmSize:"),
            \\    };
            \\}
            \\fn __processSignalFromName(name: []const u8) std.os.linux.SIG {
            \\    const stripped = if (std.mem.startsWith(u8, name, "SIG")) name[3..] else name;
            \\    return std.meta.stringToEnum(std.os.linux.SIG, stripped) orelse @enumFromInt(0);
            \\}
            \\fn __processKill(pid: i32, signal: []const u8) bool {
            \\    if (@import("builtin").os.tag != .linux) return false;
            \\    const sig = __processSignalFromName(signal);
            \\    std.posix.kill(pid, sig) catch return false;
            \\    return true;
            \\}
            \\fn __processUmaskRaw(mask: u32) u32 {
            \\    if (@import("builtin").os.tag != .linux) return 0;
            \\    return @truncate(std.os.linux.syscall1(.umask, @as(u64, mask)));
            \\}
            \\fn __processUmaskGet() i32 {
            \\    const old = __processUmaskRaw(0o022);
            \\    _ = __processUmaskRaw(old);
            \\    return @intCast(old);
            \\}
            \\fn __processUmaskSet(mask: i32) i32 {
            \\    return @intCast(__processUmaskRaw(@intCast(mask)));
            \\}
            \\fn __processGetuid() i32 {
            \\    if (@import("builtin").os.tag != .linux) return 0;
            \\    return @intCast(std.os.linux.getuid());
            \\}
            \\fn __processGetgid() i32 {
            \\    if (@import("builtin").os.tag != .linux) return 0;
            \\    return @intCast(std.os.linux.getgid());
            \\}
            \\fn __processGeteuid() i32 {
            \\    if (@import("builtin").os.tag != .linux) return 0;
            \\    return @intCast(std.os.linux.geteuid());
            \\}
            \\fn __processGetegid() i32 {
            \\    if (@import("builtin").os.tag != .linux) return 0;
            \\    return @intCast(std.os.linux.getegid());
            \\}
            \\
        );
    }
    if (program.needs_process_uptime) {
        // A separate block (not folded into needs_process_api above)
        // because this is the only process.* function needing code to run
        // unconditionally in main() before user code -- recording a start
        // timestamp -- which the rest of the namespace doesn't need.
        try out.appendSlice(arena,
            \\var __process_start_ns: i64 = 0;
            \\fn __processUptime() f64 {
            \\    const ts = std.Io.Clock.now(.awake, __io);
            \\    const elapsed_ns = @as(i64, @intCast(ts.nanoseconds)) - __process_start_ns;
            \\    return @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
            \\}
            \\
        );
    }
    if (program.needs_os_api) {
        // Two raw Linux syscalls cover almost this whole namespace: uname()
        // (sysname/nodename/release/version/machine in one call) and
        // sysinfo() (uptime/loads/totalram/freeram in one call). No libc.
        // __osTmpdir/__osHomedir below reference __processEnv, only emitted
        // when program.needs_process_api is set -- safe because Zig only
        // semantically analyzes a function body when it's actually called,
        // and the checker sets needs_process_api whenever tmpdir/homedir
        // (the only functions here that call __processEnv) are used.
        try out.appendSlice(arena,
            \\fn __osUname() std.os.linux.utsname {
            \\    var uts: std.os.linux.utsname = std.mem.zeroes(std.os.linux.utsname);
            \\    if (@import("builtin").os.tag == .linux) _ = std.os.linux.uname(&uts);
            \\    return uts;
            \\}
            \\fn __osUnameField(comptime field: []const u8) []const u8 {
            \\    const uts = __osUname();
            \\    const s = std.mem.sliceTo(&@field(uts, field), 0);
            \\    return __alloc.dupe(u8, s) catch "";
            \\}
            \\fn __osEndianness() []const u8 {
            \\    return switch (@import("builtin").cpu.arch.endian()) {
            \\        .little => "LE",
            \\        .big => "BE",
            \\    };
            \\}
            \\fn __osTmpdir() []const u8 {
            \\    if (__processEnv("TMPDIR")) |v| return v;
            \\    if (__processEnv("TMP")) |v| return v;
            \\    if (__processEnv("TEMP")) |v| return v;
            \\    return "/tmp";
            \\}
            \\fn __osSysinfo() std.os.linux.Sysinfo {
            \\    var info: std.os.linux.Sysinfo = std.mem.zeroes(std.os.linux.Sysinfo);
            \\    if (@import("builtin").os.tag == .linux) _ = std.os.linux.sysinfo(&info);
            \\    return info;
            \\}
            \\fn __osMemBytes(total: bool) i32 {
            \\    const info = __osSysinfo();
            \\    const raw: u64 = if (total) @intCast(info.totalram) else @intCast(info.freeram);
            \\    const bytes: u64 = raw * @as(u64, @intCast(info.mem_unit));
            \\    return @truncate(@as(i64, @intCast(bytes)));
            \\}
            \\fn __osLoadavg(alloc: std.mem.Allocator) []const f64 {
            \\    const info = __osSysinfo();
            \\    const out = alloc.alloc(f64, 3) catch return &.{};
            \\    out[0] = @as(f64, @floatFromInt(info.loads[0])) / 65536.0;
            \\    out[1] = @as(f64, @floatFromInt(info.loads[1])) / 65536.0;
            \\    out[2] = @as(f64, @floatFromInt(info.loads[2])) / 65536.0;
            \\    return out;
            \\}
            \\
        );
    }
    if (program.needs_crypto_api) {
        // Pure computation throughout -- the entropy source and the hash
        // implementation are both just data manipulation, no syscalls, so
        // this works identically on the native and wasm targets.
        try out.appendSlice(arena,
            \\fn __cryptoHexEncode(alloc: std.mem.Allocator, bytes: []const u8) []const u8 {
            \\    const hex_chars = "0123456789abcdef";
            \\    const out = alloc.alloc(u8, bytes.len * 2) catch return "";
            \\    for (bytes, 0..) |b, i| {
            \\        out[i * 2] = hex_chars[b >> 4];
            \\        out[i * 2 + 1] = hex_chars[b & 0x0f];
            \\    }
            \\    return out;
            \\}
            \\fn __cryptoRandomBytes(io: std.Io, alloc: std.mem.Allocator, n: i32) []const u8 {
            \\    const count: usize = @intCast(@max(n, 0));
            \\    const buf = alloc.alloc(u8, count) catch return "";
            \\    std.Io.random(io, buf);
            \\    return __cryptoHexEncode(alloc, buf);
            \\}
            \\fn __cryptoRandomUUID(io: std.Io, alloc: std.mem.Allocator) []const u8 {
            \\    var bytes: [16]u8 = undefined;
            \\    std.Io.random(io, &bytes);
            \\    bytes[6] = (bytes[6] & 0x0f) | 0x40;
            \\    bytes[8] = (bytes[8] & 0x3f) | 0x80;
            \\    const hex = __cryptoHexEncode(alloc, &bytes);
            \\    return std.fmt.allocPrint(alloc, "{s}-{s}-{s}-{s}-{s}", .{
            \\        hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32],
            \\    }) catch "";
            \\}
            \\fn __cryptoSha256(alloc: std.mem.Allocator, data: []const u8) []const u8 {
            \\    var out: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
            \\    std.crypto.hash.sha2.Sha256.hash(data, &out, .{});
            \\    return __cryptoHexEncode(alloc, &out);
            \\}
            \\
        );
    }
    if (program.needs_buffer and program.needs_crypto_api) {
        // spec 057: HMAC-SHA256, AES-256-GCM, and raw (non-hex) random
        // bytes, all Buffer in/out -- see spec.md's "Why additive, not
        // breaking" for why the three hex-string functions above are
        // untouched.
        try out.appendSlice(arena,
            \\fn __cryptoRandomBytesBuffer(io: std.Io, n: i32) *LumenBuffer {
            \\    const count: usize = @intCast(@max(n, 0));
            \\    const buf = __sa().alloc(u8, count) catch return LumenBuffer.__wrap("");
            \\    std.Io.random(io, buf);
            \\    return LumenBuffer.__wrap(buf);
            \\}
            \\fn __cryptoHmacSync(key: *LumenBuffer, data: *LumenBuffer) *LumenBuffer {
            \\    var out: [std.crypto.auth.hmac.sha2.HmacSha256.mac_length]u8 = undefined;
            \\    std.crypto.auth.hmac.sha2.HmacSha256.create(&out, data.data, key.data);
            \\    const buf = __sa().alloc(u8, out.len) catch return LumenBuffer.__wrap("");
            \\    @memcpy(buf, &out);
            \\    return LumenBuffer.__wrap(buf);
            \\}
            \\fn __cryptoEncryptSync(key: *LumenBuffer, iv: *LumenBuffer, data: *LumenBuffer) *LumenBuffer {
            \\    const Aead = std.crypto.aead.aes_gcm.Aes256Gcm;
            \\    if (key.data.len != Aead.key_length or iv.data.len != Aead.nonce_length) return LumenBuffer.__wrap("");
            \\    var k: [Aead.key_length]u8 = undefined;
            \\    @memcpy(&k, key.data);
            \\    var n: [Aead.nonce_length]u8 = undefined;
            \\    @memcpy(&n, iv.data);
            \\    const c = __sa().alloc(u8, data.data.len) catch return LumenBuffer.__wrap("");
            \\    var tag: [Aead.tag_length]u8 = undefined;
            \\    Aead.encrypt(c, &tag, data.data, "", n, k);
            \\    const combined = __sa().alloc(u8, c.len + Aead.tag_length) catch return LumenBuffer.__wrap("");
            \\    @memcpy(combined[0..c.len], c);
            \\    @memcpy(combined[c.len..], &tag);
            \\    return LumenBuffer.__wrap(combined);
            \\}
            \\fn __cryptoDecryptSync(key: *LumenBuffer, iv: *LumenBuffer, data: *LumenBuffer) *LumenBuffer {
            \\    const Aead = std.crypto.aead.aes_gcm.Aes256Gcm;
            \\    if (key.data.len != Aead.key_length or iv.data.len != Aead.nonce_length or data.data.len < Aead.tag_length) return LumenBuffer.__wrap("");
            \\    var k: [Aead.key_length]u8 = undefined;
            \\    @memcpy(&k, key.data);
            \\    var n: [Aead.nonce_length]u8 = undefined;
            \\    @memcpy(&n, iv.data);
            \\    const clen = data.data.len - Aead.tag_length;
            \\    var tag: [Aead.tag_length]u8 = undefined;
            \\    @memcpy(&tag, data.data[clen..]);
            \\    const m = __sa().alloc(u8, clen) catch return LumenBuffer.__wrap("");
            \\    Aead.decrypt(m, data.data[0..clen], tag, "", n, k) catch return LumenBuffer.__wrap("");
            \\    return LumenBuffer.__wrap(m);
            \\}
            \\fn __cryptoPbkdf2Sync(password: *LumenBuffer, salt: *LumenBuffer, iterations: i32, keylen: i32) *LumenBuffer {
            \\    if (iterations < 1 or keylen <= 0) return LumenBuffer.__wrap("");
            \\    const dk = __sa().alloc(u8, @intCast(keylen)) catch return LumenBuffer.__wrap("");
            \\    std.crypto.pwhash.pbkdf2(dk, password.data, salt.data, @intCast(iterations), std.crypto.auth.hmac.sha2.HmacSha256) catch return LumenBuffer.__wrap("");
            \\    return LumenBuffer.__wrap(dk);
            \\}
            \\fn __cryptoScryptSync(password: *LumenBuffer, salt: *LumenBuffer, keylen: i32) *LumenBuffer {
            \\    if (keylen <= 0) return LumenBuffer.__wrap("");
            \\    const dk = __sa().alloc(u8, @intCast(keylen)) catch return LumenBuffer.__wrap("");
            \\    // Node's own crypto.scrypt default cost parameters
            \\    // (N=16384, r=8, p=1) -- see spec 061's "Cost parameter
            \\    // choice" for why this is used instead of Zig's own
            \\    // `owasp`/`interactive` presets.
            \\    const params = std.crypto.pwhash.scrypt.Params{ .ln = 14, .r = 8, .p = 1 };
            \\    std.crypto.pwhash.scrypt.kdf(__sa(), dk, password.data, salt.data, params) catch return LumenBuffer.__wrap("");
            \\    return LumenBuffer.__wrap(dk);
            \\}
            \\fn __cryptoTimingSafeEqual(a: *LumenBuffer, b: *LumenBuffer) bool {
            \\    if (a.data.len != b.data.len) return false;
            \\    var acc: u8 = 0;
            \\    for (a.data, 0..) |x, i| {
            \\        acc |= x ^ b.data[i];
            \\    }
            \\    return acc == 0;
            \\}
            \\
        );
    }
    if (program.needs_streaming_crypto) {
        // crypto.createHash/createHmac (spec 060): a stateful builder over
        // one of four algorithms, chosen at runtime by string (matching
        // Node's own real `createHash('sha256')` runtime-call API -- not
        // compile-time resolved). Each algorithm is a genuinely different
        // Zig type (`std.crypto.hash.Md5`/`Sha1`/`sha2.Sha256`/`sha2.
        // Sha512`, confirmed directly against this Zig 0.16.0 toolchain's
        // lib/std/crypto/{md5,Sha1,sha2}.zig), so `LumenHash` stores them
        // in a tagged union and dispatches with `inline else` so `update`/
        // `digest` are each one method body, not four. `HmacImpl` mirrors
        // this over `std.crypto.auth.hmac.{HmacMd5,HmacSha1}`/`.sha2.
        // {HmacSha256,HmacSha512}` (confirmed against lib/std/crypto/
        // hmac.zig). An unrecognized algorithm name falls back to sha256,
        // matching Buffer.from(s, encoding)'s unrecognized-encoding
        // fallback (spec 056) rather than throwing.
        try out.appendSlice(arena,
            \\const HashImpl = union(enum) {
            \\    md5: std.crypto.hash.Md5,
            \\    sha1: std.crypto.hash.Sha1,
            \\    sha256: std.crypto.hash.sha2.Sha256,
            \\    sha512: std.crypto.hash.sha2.Sha512,
            \\};
            \\pub const LumenHash = struct {
            \\    impl: HashImpl,
            \\    fn update(self: *LumenHash, data: *LumenBuffer) *LumenHash {
            \\        switch (self.impl) {
            \\            inline else => |*h| h.update(data.data),
            \\        }
            \\        return self;
            \\    }
            \\    fn digest(self: *LumenHash) *LumenBuffer {
            \\        switch (self.impl) {
            \\            inline else => |*h| {
            \\                var out: [@TypeOf(h.*).digest_length]u8 = undefined;
            \\                h.final(&out);
            \\                const buf = __sa().alloc(u8, out.len) catch return LumenBuffer.__wrap("");
            \\                @memcpy(buf, &out);
            \\                return LumenBuffer.__wrap(buf);
            \\            },
            \\        }
            \\    }
            \\};
            \\fn __cryptoCreateHash(algorithm: []const u8) *LumenHash {
            \\    const p = __sa().create(LumenHash) catch unreachable;
            \\    if (std.mem.eql(u8, algorithm, "md5")) {
            \\        p.* = .{ .impl = .{ .md5 = std.crypto.hash.Md5.init(.{}) } };
            \\    } else if (std.mem.eql(u8, algorithm, "sha1")) {
            \\        p.* = .{ .impl = .{ .sha1 = std.crypto.hash.Sha1.init(.{}) } };
            \\    } else if (std.mem.eql(u8, algorithm, "sha512")) {
            \\        p.* = .{ .impl = .{ .sha512 = std.crypto.hash.sha2.Sha512.init(.{}) } };
            \\    } else {
            \\        p.* = .{ .impl = .{ .sha256 = std.crypto.hash.sha2.Sha256.init(.{}) } };
            \\    }
            \\    return p;
            \\}
            \\const HmacImpl = union(enum) {
            \\    md5: std.crypto.auth.hmac.HmacMd5,
            \\    sha1: std.crypto.auth.hmac.HmacSha1,
            \\    sha256: std.crypto.auth.hmac.sha2.HmacSha256,
            \\    sha512: std.crypto.auth.hmac.sha2.HmacSha512,
            \\};
            \\pub const LumenHmac = struct {
            \\    impl: HmacImpl,
            \\    fn update(self: *LumenHmac, data: *LumenBuffer) *LumenHmac {
            \\        switch (self.impl) {
            \\            inline else => |*h| h.update(data.data),
            \\        }
            \\        return self;
            \\    }
            \\    fn digest(self: *LumenHmac) *LumenBuffer {
            \\        switch (self.impl) {
            \\            inline else => |*h| {
            \\                var out: [@TypeOf(h.*).mac_length]u8 = undefined;
            \\                h.final(&out);
            \\                const buf = __sa().alloc(u8, out.len) catch return LumenBuffer.__wrap("");
            \\                @memcpy(buf, &out);
            \\                return LumenBuffer.__wrap(buf);
            \\            },
            \\        }
            \\    }
            \\};
            \\fn __cryptoCreateHmac(algorithm: []const u8, key: *LumenBuffer) *LumenHmac {
            \\    const p = __sa().create(LumenHmac) catch unreachable;
            \\    if (std.mem.eql(u8, algorithm, "md5")) {
            \\        p.* = .{ .impl = .{ .md5 = std.crypto.auth.hmac.HmacMd5.init(key.data) } };
            \\    } else if (std.mem.eql(u8, algorithm, "sha1")) {
            \\        p.* = .{ .impl = .{ .sha1 = std.crypto.auth.hmac.HmacSha1.init(key.data) } };
            \\    } else if (std.mem.eql(u8, algorithm, "sha512")) {
            \\        p.* = .{ .impl = .{ .sha512 = std.crypto.auth.hmac.sha2.HmacSha512.init(key.data) } };
            \\    } else {
            \\        p.* = .{ .impl = .{ .sha256 = std.crypto.auth.hmac.sha2.HmacSha256.init(key.data) } };
            \\    }
            \\    return p;
            \\}
            \\
        );
    }
    if (program.needs_zlib_api) {
        // std.compress.flate.Container's raw/gzip/zlib variants are handled
        // internally by Compress/Decompress (header/footer framing, CRC32/
        // Adler32 checksums) -- verified directly against this Zig
        // version's lib/std/compress/flate*.zig rather than assumed, since
        // this API has churned across Zig versions. Compress needs an
        // output writer with > 8 bytes of starting capacity (an internal
        // assert), hence initCapacity rather than a bare .init. Both
        // directions need a caller-owned scratch window of
        // flate.max_window_len (64 KiB) -- heap-allocated via __alloc
        // rather than put on the stack, so this doesn't blow up every call
        // site's frame size.
        try out.appendSlice(arena,
            \\fn __zlibCompress(alloc: std.mem.Allocator, container: std.compress.flate.Container, data: []const u8) []const u8 {
            \\    var allocating = std.Io.Writer.Allocating.initCapacity(alloc, data.len + 64) catch return "";
            \\    defer allocating.deinit();
            \\    const window = alloc.alloc(u8, std.compress.flate.max_window_len) catch return "";
            \\    defer alloc.free(window);
            \\    var c = std.compress.flate.Compress.init(&allocating.writer, window, container, .default) catch return "";
            \\    c.writer.writeAll(data) catch return "";
            \\    c.finish() catch return "";
            \\    return allocating.toOwnedSlice() catch "";
            \\}
            \\fn __zlibDecompress(alloc: std.mem.Allocator, container: std.compress.flate.Container, data: []const u8) []const u8 {
            \\    var reader = std.Io.Reader.fixed(data);
            \\    const window = alloc.alloc(u8, std.compress.flate.max_window_len) catch return "";
            \\    defer alloc.free(window);
            \\    var d = std.compress.flate.Decompress.init(&reader, container, window);
            \\    return d.reader.allocRemaining(alloc, .unlimited) catch return "";
            \\}
            \\
        );
    }
    if (program.needs_httpget) {
        // A real std.http one-shot GET, wrapped to a Lumen-friendly `i64` (status code, or -1 on error).
        try out.appendSlice(arena,
            \\fn __httpGet(io: std.Io, alloc: std.mem.Allocator, url: []const u8) i64 {
            \\    var client: std.http.Client = .{ .allocator = alloc, .io = io };
            \\    defer client.deinit();
            \\    client.ca_bundle.rescan(alloc, io, std.Io.Clock.now(.real, io)) catch return -1;
            \\    const res = client.fetch(.{ .location = .{ .url = url } }) catch return -1;
            \\    return @intFromEnum(res.status);
            \\}
            \\
        );
    }
    if (program.needs_serve) {
        // A real (blocking) HTTP server on std.Io.net — returns the same body to every request.
        try out.appendSlice(arena,
            \\fn __serve(io: std.Io, alloc: std.mem.Allocator, port: i64, body: []const u8) noreturn {
            \\    _ = alloc;
            \\    const addr = std.Io.net.IpAddress.parse("0.0.0.0", @intCast(port)) catch std.process.exit(1);
            \\    var server = addr.listen(io, .{ .reuse_address = true }) catch std.process.exit(1);
            \\    var hbuf: [256]u8 = undefined;
            \\    const head = std.fmt.bufPrint(&hbuf, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch std.process.exit(1);
            \\    while (true) {
            \\        const stream = server.accept(io) catch continue;
            \\        var wbuf: [2048]u8 = undefined;
            \\        var w = stream.writer(io, &wbuf);
            \\        w.interface.writeAll(head) catch {};
            \\        w.interface.writeAll(body) catch {};
            \\        w.interface.flush() catch {};
            \\        stream.close(io);
            \\    }
            \\}
            \\
        );
    }
    if (program.uses_io) {
        try out.appendSlice(arena, "pub fn main(__init: std.process.Init) !void {\n");
        try out.appendSlice(arena, "    __io = __init.io;\n    __alloc = __init.arena.allocator();\n");
        try out.appendSlice(arena, "    __lumen_color = (__init.environ_map.get(\"NO_COLOR\") == null) and (std.Io.File.stderr().isTty(__init.io) catch false);\n");
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
