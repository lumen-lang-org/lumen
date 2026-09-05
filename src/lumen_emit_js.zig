//! The JavaScript backend (spec 504): the checked AST -> ECMAScript module text
//! for `lumen compile --target node`.
//!
//! A sibling of `lumen_emit.zig`, fed the same `ast.Program` after the same
//! front end (lexer, parser, checker, import inlining, `embed` expansion). The
//! AST is TypeScript-shaped, so most nodes print their source form back:
//! annotations, `type`/`interface` declarations, casts and non-null assertions
//! are erased, and the few constructs Node lacks (`using`/`defer`, `enum`,
//! optional parameters filled with `null`, the checker's numeric rewrites) are
//! lowered here. The generated text keeps the user's identifiers and statement
//! order (FR-004); it is meant to be read.
//!
//! Layout: this file holds the emitter state, the literal writers and the
//! program driver; `lumen_emit_js_expr.zig` the expression switch,
//! `lumen_emit_js_stmt.zig` the statement switch (with the `try/finally`
//! lowering of `using`/`defer`), `lumen_emit_js_class.zig` classes and enums.
//!
//! A construct this target cannot lower yet is refused at its source position
//! with `E_TARGET_UNSUPPORTED`, naming the spec that adds it (FR-005); it never
//! becomes a Node runtime error.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const types = @import("lumen_types.zig");
const diag_mod = @import("lumen_diag.zig");
const js_stmt = @import("lumen_emit_js_stmt.zig");

pub const CompileError = diag_mod.CompileError;

/// Emitter state: the output buffer, the indentation level, and where to put a
/// diagnostic. One per program; every `emit*` function takes it first.
pub const Emitter = struct {
    arena: std.mem.Allocator,
    out: std.ArrayListUnmanaged(u8) = .empty,
    indent: usize = 0,
    diag: *diag_mod.Diag,
    program: *const ast.Program,
    /// Position of the statement being emitted, for a diagnostic raised from
    /// inside an expression (which carries no position of its own).
    cur_line: u32 = 0,
    cur_col: u32 = 0,
    /// Where a non-fatal diagnostic goes (the CLI prints them after the
    /// compile); null when nobody is collecting.
    warnings: ?*std.ArrayListUnmanaged(diag_mod.Diag) = null,
    /// `W_I64_PRECISION` is raised once per program (spec 505): every `i64`
    /// is a JavaScript number here, so the first literal past 2^53 says so
    /// and the rest would only repeat it.
    i64_warned: bool = false,

    /// Records a warning at the current statement's position.
    pub fn warn(self: *Emitter, msg: []const u8) void {
        const sink = self.warnings orelse return;
        sink.append(self.arena, .{ .line = self.cur_line, .col = self.cur_col, .msg = msg }) catch {};
    }

    pub fn w(self: *Emitter, s: []const u8) CompileError!void {
        self.out.appendSlice(self.arena, s) catch return error.OutOfMemory;
    }

    pub fn byte(self: *Emitter, c: u8) CompileError!void {
        self.out.append(self.arena, c) catch return error.OutOfMemory;
    }

    pub fn print(self: *Emitter, comptime fmt: []const u8, args: anytype) CompileError!void {
        self.out.print(self.arena, fmt, args) catch return error.OutOfMemory;
    }

    /// Writes the current indentation (two spaces per level).
    pub fn pad(self: *Emitter) CompileError!void {
        var i: usize = 0;
        while (i < self.indent) : (i += 1) try self.w("  ");
    }

    /// One indented line.
    pub fn line(self: *Emitter, s: []const u8) CompileError!void {
        try self.pad();
        try self.w(s);
        try self.w("\n");
    }

    /// A construct this backend does not lower yet (FR-005). The message names
    /// the construct and the spec that adds it, so the reader knows whether to
    /// wait or to restructure.
    pub fn unsupported(self: *Emitter, line_no: u32, col: u32, what: []const u8, spec: []const u8) CompileError {
        self.diag.* = .{
            .line = line_no,
            .col = col,
            .msg = std.fmt.allocPrint(self.arena, "{s} is not supported by the node target yet (spec {s}) [E_TARGET_UNSUPPORTED]", .{ what, spec }) catch return error.OutOfMemory,
        };
        return error.ParseError;
    }
};

/// Decodes one raw-literal escape the way the native emitter does
/// (`lumen_emit.zig` `emitStrLit`): `\n` `\t` `\r` `\0` are control bytes,
/// every other `\c` is the character `c` itself. Returns the decoded byte and
/// how many input bytes were consumed.
fn decodeEscape(s: []const u8, i: usize) struct { ch: u8, len: usize } {
    if (s[i] == '\\' and i + 1 < s.len) {
        const ch: u8 = switch (s[i + 1]) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            '0' => 0,
            else => s[i + 1],
        };
        return .{ .ch = ch, .len = 2 };
    }
    return .{ .ch = s[i], .len = 1 };
}

/// Writes one decoded byte into a JavaScript literal delimited by `quote`.
/// A Lumen string is its UTF-8 bytes, and on this target a string value is a
/// JavaScript string with one code unit per byte (spec 505, decision 1), so a
/// byte above 0x7f is spelled `\xNN`: written raw it would be read as a
/// character of the module's UTF-8 text, one code unit for two or more bytes.
/// Control bytes are escaped so the literal never spans a line (spec 502).
fn writeLitByte(e: *Emitter, ch: u8, quote: u8) CompileError!void {
    switch (ch) {
        '\\' => try e.w("\\\\"),
        '\n' => try e.w("\\n"),
        '\r' => try e.w("\\r"),
        '\t' => try e.w("\\t"),
        else => {
            if (ch == quote) {
                try e.byte('\\');
                try e.byte(ch);
            } else if (ch < 0x20 or ch >= 0x7f) {
                try e.print("\\x{X:0>2}", .{ch});
            } else {
                try e.byte(ch);
            }
        },
    }
}

/// A double-quoted JavaScript string literal for a raw source literal (the
/// text between the quotes, escapes verbatim, as the lexer stores it).
pub fn emitStrLit(e: *Emitter, s: []const u8) CompileError!void {
    try e.byte('"');
    var i: usize = 0;
    while (i < s.len) {
        const d = decodeEscape(s, i);
        i += d.len;
        try writeLitByte(e, d.ch, '"');
    }
    try e.byte('"');
}

/// The literal text of a template part inside backticks: decoded like a
/// string literal, then re-escaped so a backtick or a `${` in the text stays
/// text.
pub fn emitTemplateText(e: *Emitter, s: []const u8) CompileError!void {
    var i: usize = 0;
    while (i < s.len) {
        const d = decodeEscape(s, i);
        i += d.len;
        if (d.ch == '$' and i < s.len and s[i] == '{') {
            try e.w("\\$");
            continue;
        }
        try writeLitByte(e, d.ch, '`');
    }
}

/// The source of a regex literal, matched against byte strings: a byte above
/// 0x7f in the pattern is spelled `\xNN` so it matches the one code unit
/// that byte is, as the native regex runtime matches bytes. Everything else
/// is the pattern as written, escapes included.
pub fn emitRegexSource(e: *Emitter, s: []const u8) CompileError!void {
    for (s) |ch| {
        if (ch >= 0x7f) {
            try e.print("\\x{X:0>2}", .{ch});
        } else {
            try e.byte(ch);
        }
    }
}

pub fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
}

pub fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

/// Whether `name` can stand unquoted as a property key or a member name.
pub fn isPlainIdent(name: []const u8) bool {
    if (name.len == 0 or !isIdentStart(name[0])) return false;
    for (name[1..]) |c| if (!isIdentChar(c)) return false;
    return true;
}

/// An object-literal key: bare when it is an identifier, quoted otherwise.
pub fn emitPropertyKey(e: *Emitter, name: []const u8) CompileError!void {
    if (isPlainIdent(name)) {
        try e.w(name);
    } else {
        try emitStrLit(e, name);
    }
}

/// A float literal that reads back as the same double: Zig's `{d}` prints
/// the shortest round-trip decimal, which is also a JavaScript literal.
pub fn emitFloat(e: *Emitter, v: f64) CompileError!void {
    if (std.math.isNan(v)) return e.w("NaN");
    if (std.math.isInf(v)) return e.w(if (v < 0) "-Infinity" else "Infinity");
    try e.print("{d}", .{v});
}

/// Whether the program declares a generic function template of this name, so
/// a call to it must name the checker's specialization (`call.emit_name`)
/// rather than the template, which is never emitted.
pub fn isGenericFunction(e: *Emitter, name: []const u8) bool {
    for (e.program.stmts) |stmt| switch (stmt) {
        .function_decl => |f| if (f.type_params.len > 0 and std.mem.eql(u8, f.name, name)) return true,
        else => {},
    };
    return false;
}

// ---------------------------------------------------------------------------
// Modules. The front end inlined every import into one flat program; the
// line map still says which source file each statement came from, and the
// expander recorded the import edges, so the output mirrors the source graph
// one module per file (FR-004). A module imports a name when it refers to a
// declaration another module owns, and exports exactly the names other
// modules import; an edge that carries no name is kept as a bare import so
// the imported module's top-level code still runs, and in the same order.

pub const EmittedModule = struct { out: []const u8, text: []const u8 };

pub const Output = struct {
    /// The entry module's path under `modules/`.
    entry_out: []const u8,
    modules: []const EmittedModule,
};

const Module = struct {
    file: []const u8,
    out: []const u8,
    stmts: std.ArrayListUnmanaged(*const ast.Stmt) = .empty,
    /// Top-level value names this module declares.
    decls: std.StringHashMapUnmanaged(void) = .empty,
    /// Names this module refers to (own and foreign).
    refs: std.StringHashMapUnmanaged(void) = .empty,
    /// Names other modules import from this one.
    exports: std.StringHashMapUnmanaged(void) = .empty,
};

/// The module a top-level statement came from: the line map's origin for its
/// line, or the entry file when there is no map (a single-file program).
fn originFile(e: *Emitter, s: *const ast.Stmt, line_map: []const diag_mod.LineOrigin, entry: []const u8) []const u8 {
    _ = e;
    const pos = js_stmt.stmtPos(s) orelse return entry;
    const line = pos[0];
    if (line == 0 or line > line_map.len) return entry;
    return line_map[line - 1].file;
}

fn declaredNames(e: *Emitter, s: *const ast.Stmt, set: *std.StringHashMapUnmanaged(void)) CompileError!void {
    const put = struct {
        fn f(em: *Emitter, st: *std.StringHashMapUnmanaged(void), name: []const u8) CompileError!void {
            st.put(em.arena, name, {}) catch return error.OutOfMemory;
        }
    }.f;
    switch (s.*) {
        .function_decl => |f| if (f.type_params.len == 0) try put(e, set, f.name),
        .class_decl => |c| if (c.type_params.len == 0) try put(e, set, c.name),
        .enum_decl => |d| try put(e, set, d.name),
        .var_decl => |d| try put(e, set, d.name),
        .var_decl_group => |g| for (g) |d| try put(e, set, d.name),
        .using_decl => |u| try put(e, set, u.name),
        .destructure_decl => |d| for (d.bindings) |b| try put(e, set, b.name),
        else => {},
    }
}

fn ref(e: *Emitter, set: *std.StringHashMapUnmanaged(void), name: []const u8) CompileError!void {
    set.put(e.arena, name, {}) catch return error.OutOfMemory;
}

fn refsInExprs(e: *Emitter, set: *std.StringHashMapUnmanaged(void), items: []const *ast.Expr) CompileError!void {
    for (items) |x| try refsInExpr(e, set, x);
}

/// Every name an expression refers to that could be a top-level declaration
/// of some module: variables, called functions (a generic call refers to its
/// specialization), constructed and tested classes.
fn refsInExpr(e: *Emitter, set: *std.StringHashMapUnmanaged(void), x: *const ast.Expr) CompileError!void {
    switch (x.*) {
        .num, .float, .bool, .str, .regex, .null_lit, .this_expr => {},
        .var_ref => |r| try ref(e, set, r.name),
        .array => |a| try refsInExprs(e, set, a.items),
        .tuple_lit => |t| try refsInExprs(e, set, t.items),
        .spread, .neg, .not, .bnot, .await_expr => |inner| try refsInExpr(e, set, inner),
        .non_null => |n| try refsInExpr(e, set, n.inner),
        .typeof_expr => |t| try refsInExpr(e, set, t.operand),
        .instanceof_expr => |i| {
            try refsInExpr(e, set, i.value);
            try ref(e, set, i.class_name);
        },
        .inc_dec => |i| try refsInExpr(e, set, i.target),
        .bin => |b| {
            try refsInExpr(e, set, b.l);
            try refsInExpr(e, set, b.r);
        },
        .bool_bin => |b| {
            try refsInExpr(e, set, b.l);
            try refsInExpr(e, set, b.r);
        },
        .cmp => |c| {
            try refsInExpr(e, set, c.l);
            try refsInExpr(e, set, c.r);
        },
        .ternary => |t| {
            try refsInExpr(e, set, t.cond);
            try refsInExpr(e, set, t.then_expr);
            try refsInExpr(e, set, t.else_expr);
        },
        .coalesce => |c| {
            try refsInExpr(e, set, c.l);
            try refsInExpr(e, set, c.r);
        },
        .arrow => |a| {
            for (a.params) |p| if (p.default) |d| try refsInExpr(e, set, d);
            if (a.body_expr) |body| try refsInExpr(e, set, body);
            if (a.body_block) |body| try refsInBody(e, set, body);
        },
        .super_call => |sc| try refsInExprs(e, set, sc.args),
        .new_expr => |n| {
            try ref(e, set, n.class_name);
            try refsInExprs(e, set, n.args);
        },
        .method_call => |m| {
            try refsInExpr(e, set, m.obj);
            try refsInExprs(e, set, m.args);
        },
        .template => |parts| for (parts) |p| if (p.expr) |inner| try refsInExpr(e, set, inner),
        .obj => |fields| for (fields) |f| try refsInExpr(e, set, f.value),
        .field => |f| try refsInExpr(e, set, f.obj),
        .index => |i| {
            try refsInExpr(e, set, i.obj);
            try refsInExpr(e, set, i.value);
        },
        .call => |c| {
            const name = if (c.emit_name != null and isGenericFunction(e, c.name)) c.emit_name.? else c.name;
            try ref(e, set, name);
            try refsInExprs(e, set, c.args);
        },
        .optional_call => |o| {
            try refsInExpr(e, set, o.callee);
            try refsInExprs(e, set, o.args);
        },
        .static_call => |sc| try refsInExprs(e, set, sc.args),
        .cast => |c| try refsInExpr(e, set, c.inner),
    }
}

fn refsInParams(e: *Emitter, set: *std.StringHashMapUnmanaged(void), params: []const ast.FunctionParam) CompileError!void {
    for (params) |p| if (p.default) |d| try refsInExpr(e, set, d);
}

fn refsInBody(e: *Emitter, set: *std.StringHashMapUnmanaged(void), stmts: []const ast.Stmt) CompileError!void {
    for (stmts) |*s| try refsInStmt(e, set, s);
}

fn refsInStmt(e: *Emitter, set: *std.StringHashMapUnmanaged(void), s: *const ast.Stmt) CompileError!void {
    switch (s.*) {
        .type_decl, .enum_decl, .extern_decl, .break_stmt, .continue_stmt => {},
        .test_decl => |t| try refsInBody(e, set, t.body),
        .class_decl => |c| {
            if (c.type_params.len > 0) return;
            if (c.parent) |p| try ref(e, set, p);
            for (c.fields) |f| if (f.init) |init| try refsInExpr(e, set, init);
            try refsInParams(e, set, c.ctor_params);
            try refsInBody(e, set, c.ctor_body);
            for (c.methods) |m| {
                try refsInParams(e, set, m.params);
                try refsInBody(e, set, m.body);
            }
        },
        .function_decl => |f| {
            if (f.type_params.len > 0) return;
            try refsInParams(e, set, f.params);
            try refsInBody(e, set, f.body);
        },
        .var_decl => |d| if (!d.no_init) try refsInExpr(e, set, d.init),
        .var_decl_group => |g| for (g) |d| if (!d.no_init) try refsInExpr(e, set, d.init),
        .using_decl => |u| {
            try refsInExpr(e, set, u.init);
            if (u.defer_body) |body| try refsInBody(e, set, body);
            if (u.dispose_call) |call| try refsInExpr(e, set, call);
        },
        .destructure_decl => |d| {
            try refsInExpr(e, set, d.source);
            for (d.bindings) |b| if (b.default) |dflt| try refsInExpr(e, set, dflt);
        },
        .member_assign => |m| {
            if (m.obj) |obj| try refsInExpr(e, set, obj);
            try refsInExpr(e, set, m.value);
        },
        .super_ctor => |sc| try refsInExprs(e, set, sc.args),
        .assign => |a| {
            try ref(e, set, a.name);
            try refsInExpr(e, set, a.value);
        },
        .console_log => |c| {
            try refsInExpr(e, set, c.value);
            try refsInExprs(e, set, c.extra_values);
        },
        .while_stmt => |w| {
            try refsInExpr(e, set, w.cond);
            try refsInBody(e, set, w.body);
        },
        .do_while_stmt => |w| {
            try refsInExpr(e, set, w.cond);
            try refsInBody(e, set, w.body);
        },
        .for_stmt => |f| {
            if (f.init) |init| if (!init.no_init) try refsInExpr(e, set, init.init);
            for (f.extra_inits) |init| if (!init.no_init) try refsInExpr(e, set, init.init);
            if (f.cond) |c| try refsInExpr(e, set, c);
            if (f.update) |u| try refsInExpr(e, set, u.value);
            for (f.extra_updates) |u| try refsInExpr(e, set, u.value);
            try refsInBody(e, set, f.body);
        },
        .for_of_stmt => |f| {
            try refsInExpr(e, set, f.iterable);
            try refsInBody(e, set, f.body);
        },
        .for_in_stmt => |f| {
            try refsInExpr(e, set, f.iterable);
            try refsInBody(e, set, f.body);
        },
        .if_stmt => |i| {
            try refsInExpr(e, set, i.cond);
            try refsInBody(e, set, i.then_body);
            if (i.else_body) |body| try refsInBody(e, set, body);
        },
        .switch_stmt => |sw| {
            try refsInExpr(e, set, sw.value);
            for (sw.cases) |c| {
                try refsInExpr(e, set, c.value);
                try refsInBody(e, set, c.body);
            }
            if (sw.default_body) |body| try refsInBody(e, set, body);
        },
        .return_stmt => |r| if (r.value) |v| try refsInExpr(e, set, v),
        .throw_stmt => |t| try refsInExpr(e, set, t.value),
        .try_stmt => |t| {
            try refsInBody(e, set, t.try_body);
            try refsInBody(e, set, t.catch_body);
            if (t.finally_body) |body| try refsInBody(e, set, body);
        },
        .defer_stmt => |d| try refsInBody(e, set, d.body),
        .expr_stmt => |x| try refsInExpr(e, set, x.value),
        .block_stmt => |b| try refsInBody(e, set, b.body),
    }
}

/// The import specifier from module `from` to module `to`, both paths under
/// `modules/`: `./` or `../` relative, never bare.
fn relativeSpecifier(arena: std.mem.Allocator, from: []const u8, to: []const u8) CompileError![]const u8 {
    const from_dir = std.fs.path.dirname(from) orelse "";
    var from_parts = std.mem.splitScalar(u8, from_dir, '/');
    var to_parts = std.mem.splitScalar(u8, to, '/');
    // Drop the shared leading directories.
    var shared: usize = 0;
    var fp = from_parts.next();
    var tp = to_parts.next();
    while (fp != null and tp != null and fp.?.len > 0 and std.mem.eql(u8, fp.?, tp.?)) {
        shared += 1;
        fp = from_parts.next();
        tp = to_parts.next();
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var ups: usize = 0;
    if (fp != null and fp.?.len > 0) {
        ups += 1;
        while (from_parts.next()) |_| ups += 1;
    }
    if (ups == 0) out.appendSlice(arena, "./") catch return error.OutOfMemory;
    var i: usize = 0;
    while (i < ups) : (i += 1) out.appendSlice(arena, "../") catch return error.OutOfMemory;
    // The rest of `to`: the first unshared part, then everything after.
    if (tp) |first| out.appendSlice(arena, first) catch return error.OutOfMemory;
    while (to_parts.next()) |part| {
        out.append(arena, '/') catch return error.OutOfMemory;
        out.appendSlice(arena, part) catch return error.OutOfMemory;
    }
    return out.items;
}

fn isExportable(s: *const ast.Stmt) bool {
    return switch (s.*) {
        .function_decl, .class_decl, .enum_decl, .var_decl, .var_decl_group, .destructure_decl => true,
        else => false,
    };
}

fn stmtExported(s: *const ast.Stmt, exports: *const std.StringHashMapUnmanaged(void)) bool {
    if (!isExportable(s)) return false;
    return switch (s.*) {
        .function_decl => |f| exports.get(f.name) != null,
        .class_decl => |c| exports.get(c.name) != null,
        .enum_decl => |d| exports.get(d.name) != null,
        .var_decl => |d| exports.get(d.name) != null,
        .var_decl_group => |g| blk: {
            for (g) |d| if (exports.get(d.name) != null) break :blk true;
            break :blk false;
        },
        .destructure_decl => |d| blk: {
            for (d.bindings) |b| if (exports.get(b.name) != null) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

/// The program as ECMAScript modules, one per source file.
pub fn emitProgram(program: *const ast.Program, arena: std.mem.Allocator, diag: *diag_mod.Diag, warnings: ?*std.ArrayListUnmanaged(diag_mod.Diag), entry: []const u8, line_map: []const diag_mod.LineOrigin, module_paths: []const diag_mod.ModulePath, module_edges: []const diag_mod.ModuleEdge) CompileError!Output {
    var e: Emitter = .{ .arena = arena, .diag = diag, .program = program, .warnings = warnings };

    // Modules in the order the front end inlined them (dependencies first),
    // each with its statements in source order.
    var modules: std.ArrayListUnmanaged(*Module) = .empty;
    var by_file: std.StringHashMapUnmanaged(*Module) = .empty;
    const moduleFor = struct {
        fn f(em: *Emitter, list: *std.ArrayListUnmanaged(*Module), map: *std.StringHashMapUnmanaged(*Module), paths: []const diag_mod.ModulePath, file: []const u8) CompileError!*Module {
            if (map.get(file)) |m| return m;
            var out: []const u8 = file;
            for (paths) |p| if (std.mem.eql(u8, p.file, file)) {
                out = p.out;
                break;
            };
            const m = em.arena.create(Module) catch return error.OutOfMemory;
            m.* = .{ .file = file, .out = out };
            list.append(em.arena, m) catch return error.OutOfMemory;
            map.put(em.arena, file, m) catch return error.OutOfMemory;
            return m;
        }
    }.f;
    // The inlined text puts each imported module before the importer's own
    // lines, so registering modules in line-map order lists dependencies
    // first; the entry, whose first lines may be imports, is registered by
    // its first own statement like any other.
    for (program.stmts) |*s| {
        const m = try moduleFor(&e, &modules, &by_file, module_paths, originFile(&e, s, line_map, entry));
        m.stmts.append(arena, s) catch return error.OutOfMemory;
        try declaredNames(&e, s, &m.decls);
    }
    const entry_module = try moduleFor(&e, &modules, &by_file, module_paths, entry);

    // References, then who owns each: a foreign owner becomes an import.
    for (modules.items) |m| {
        for (m.stmts.items) |s| try refsInStmt(&e, &m.refs, s);
    }
    for (modules.items) |m| {
        var it = m.refs.keyIterator();
        while (it.next()) |name| {
            if (m.decls.get(name.*) != null) continue;
            for (modules.items) |other| {
                if (other == m or other.decls.get(name.*) == null) continue;
                other.exports.put(arena, name.*, {}) catch return error.OutOfMemory;
            }
        }
    }

    var emitted: std.ArrayListUnmanaged(EmittedModule) = .empty;
    for (modules.items) |m| {
        e.out = .empty;
        e.indent = 0;
        try e.print("// Generated by lumen --target node from {s}. Edit the .ts source, not this file.\n", .{try displayFile(arena, m.file)});
        // Imports: the source edges first (bare when no name is needed, so the
        // module's top-level code runs and in the inlined order), then any
        // module a reference reaches without a direct edge.
        var imported: std.StringHashMapUnmanaged(void) = .empty;
        for (module_edges) |edge| {
            if (!std.mem.eql(u8, edge.from, m.file)) continue;
            const dep = by_file.get(edge.to) orelse continue;
            if (imported.get(dep.file) != null) continue;
            imported.put(arena, dep.file, {}) catch return error.OutOfMemory;
            try emitImport(&e, m, dep);
        }
        for (modules.items) |dep| {
            if (dep == m or imported.get(dep.file) != null) continue;
            if (!importsAnything(m, dep)) continue;
            try emitImport(&e, m, dep);
        }
        for (m.stmts.items) |s| {
            if (stmtExported(s, &m.exports)) try e.w("export ");
            try js_stmt.emitTopLevel(&e, s);
        }
        emitted.append(arena, .{ .out = m.out, .text = e.out.items }) catch return error.OutOfMemory;
    }
    return .{ .entry_out = entry_module.out, .modules = emitted.items };
}

/// A source path for the module header with `.` and `..` segments folded,
/// as the expander joined it (`a/./b`, `app/../lib/x.ts`).
fn displayFile(arena: std.mem.Allocator, file: []const u8) CompileError![]const u8 {
    if (std.mem.startsWith(u8, file, "https://")) return file;
    var segs: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, file, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..") and segs.items.len > 0 and !std.mem.eql(u8, segs.items[segs.items.len - 1], "..")) {
            _ = segs.pop();
            continue;
        }
        segs.append(arena, seg) catch return error.OutOfMemory;
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (segs.items, 0..) |seg, i| {
        if (i > 0) out.append(arena, '/') catch return error.OutOfMemory;
        out.appendSlice(arena, seg) catch return error.OutOfMemory;
    }
    return out.items;
}

fn importsAnything(m: *const Module, dep: *const Module) bool {
    var it = m.refs.keyIterator();
    while (it.next()) |name| {
        if (m.decls.get(name.*) == null and dep.decls.get(name.*) != null) return true;
    }
    return false;
}

fn emitImport(e: *Emitter, m: *const Module, dep: *const Module) CompileError!void {
    // The names, in the order they are declared in `dep` so the line is stable.
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    for (dep.stmts.items) |s| {
        var declared: std.StringHashMapUnmanaged(void) = .empty;
        try declaredNames(e, s, &declared);
        var it = declared.keyIterator();
        while (it.next()) |name| {
            if (m.decls.get(name.*) == null and m.refs.get(name.*) != null) names.append(e.arena, name.*) catch return error.OutOfMemory;
        }
    }
    const spec = try relativeSpecifier(e.arena, m.out, dep.out);
    if (names.items.len == 0) {
        try e.print("import \"{s}\";\n", .{spec});
        return;
    }
    try e.w("import { ");
    for (names.items, 0..) |name, i| {
        if (i > 0) try e.w(", ");
        try e.w(name);
    }
    try e.print(" }} from \"{s}\";\n", .{spec});
}

test "a module refers to a sibling through a relative specifier" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try t.expectEqualStrings("./geometry.mjs", try relativeSpecifier(arena, "main.mjs", "geometry.mjs"));
    try t.expectEqualStrings("./lib/geometry.mjs", try relativeSpecifier(arena, "main.mjs", "lib/geometry.mjs"));
    try t.expectEqualStrings("../main.mjs", try relativeSpecifier(arena, "lib/geometry.mjs", "main.mjs"));
    try t.expectEqualStrings("../../https/example.com/pkg/mod.mjs", try relativeSpecifier(arena, "app/src/main.mjs", "https/example.com/pkg/mod.mjs"));
    try t.expectEqualStrings("./b.mjs", try relativeSpecifier(arena, "app/a.mjs", "app/b.mjs"));
}

test "string literals decode source escapes and re-escape for JavaScript" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var diag: diag_mod.Diag = .{};
    var program: ast.Program = .{ .stmts = &.{} };
    var e: Emitter = .{ .arena = arena_state.allocator(), .diag = &diag, .program = &program };
    // A raw line break (spec 502) and the escape spelling both become `\n`.
    try emitStrLit(&e, "a\nb");
    try t.expectEqualStrings("\"a\\nb\"", e.out.items);
    e.out.clearRetainingCapacity();
    try emitStrLit(&e, "a\\nb");
    try t.expectEqualStrings("\"a\\nb\"", e.out.items);
    // A single-quoted source literal may hold a bare double quote.
    e.out.clearRetainingCapacity();
    try emitStrLit(&e, "say \"hi\" and \\'bye\\'");
    try t.expectEqualStrings("\"say \\\"hi\\\" and 'bye'\"", e.out.items);
    // Template text keeps `${` literal and escapes backticks.
    e.out.clearRetainingCapacity();
    try emitTemplateText(&e, "cost: \\${x} `q`");
    try t.expectEqualStrings("cost: \\${x} \\`q\\`", e.out.items);
    // A string is its UTF-8 bytes, one code unit each (spec 505): "é" is
    // two, and a raw DEL or a byte above 0x7f is never written as text.
    e.out.clearRetainingCapacity();
    try emitStrLit(&e, "h\xC3\xA9\x7f");
    try t.expectEqualStrings("\"h\\xC3\\xA9\\x7F\"", e.out.items);
    e.out.clearRetainingCapacity();
    try emitTemplateText(&e, "\xE2\x80\xA6");
    try t.expectEqualStrings("\\xE2\\x80\\xA6", e.out.items);
    e.out.clearRetainingCapacity();
    try emitRegexSource(&e, "^\xC3\xA9+\\d$");
    try t.expectEqualStrings("^\\xC3\\xA9+\\d$", e.out.items);
}

test "floats print as round-trip JavaScript literals" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var diag: diag_mod.Diag = .{};
    var program: ast.Program = .{ .stmts = &.{} };
    var e: Emitter = .{ .arena = arena_state.allocator(), .diag = &diag, .program = &program };
    try emitFloat(&e, 0.1);
    try t.expectEqualStrings("0.1", e.out.items);
    e.out.clearRetainingCapacity();
    try emitFloat(&e, 3.0);
    try t.expectEqualStrings("3", e.out.items);
    e.out.clearRetainingCapacity();
    try emitFloat(&e, std.math.inf(f64));
    try t.expectEqualStrings("Infinity", e.out.items);
}

test "the hot path emits no runtime helper (spec 505 SC-003)" {
    // `+`, `==`, `length`, `[i]`, `slice`, `indexOf` on byte strings are
    // JavaScript's own operations; a helper call on any of them would be a
    // regression in the representation, not a lowering choice.
    const t = std.testing;
    const compiler = @import("lumen_compiler.zig");
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var diag: diag_mod.Diag = .{};
    const out = try compiler.compileToJsWithOptions(arena_state.allocator(), @embedFile("hot_path.ts"), &diag, .{ .target = .node, .entry_file = "hot_path.ts" });
    try t.expect(out.modules.len == 1);
    try t.expect(std.mem.indexOf(u8, out.modules[0].text, "__lang.") == null);
    try t.expect(std.mem.indexOf(u8, out.modules[0].text, "joined.slice(0, 3)") != null);
}

test {
    _ = @import("lumen_emit_js_stdlib.zig");
    _ = @import("lumen_emit_js_expr.zig");
    _ = @import("lumen_emit_js_stmt.zig");
    _ = @import("lumen_emit_js_class.zig");
}
