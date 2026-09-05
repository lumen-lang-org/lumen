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
/// Control bytes are escaped so the literal never spans a line (spec 502);
/// bytes above 0x7f pass through, as the module is UTF-8 like the source.
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
            } else if (ch < 0x20 or ch == 0x7f) {
                try e.print("\\x{x:0>2}", .{ch});
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

/// The program as one ECMAScript module: every top-level statement in source
/// order, generic templates and type declarations erased. Splitting per source
/// module is spec 504 phase 3 (T011); until then the entry file imports this
/// single module.
pub fn emitProgram(program: *const ast.Program, arena: std.mem.Allocator, diag: *diag_mod.Diag) CompileError![]const u8 {
    var e: Emitter = .{ .arena = arena, .diag = diag, .program = program };
    try e.w("// Generated by lumen --target node. Edit the .ts source, not this file.\n");
    for (program.stmts) |*stmt| try js_stmt.emitTopLevel(&e, stmt);
    return e.out.items;
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

test {
    _ = @import("lumen_emit_js_expr.zig");
    _ = @import("lumen_emit_js_stmt.zig");
    _ = @import("lumen_emit_js_class.zig");
}
