//! Lumen compiler CLI: TypeScript syntax -> generated Zig -> native binary.

const std = @import("std");
const compiler = @import("lumen_compiler.zig");
const describe = @import("lumen_describe.zig");
const decorator = @import("lumen_decorator.zig");

const CompileMode = enum {
    release_safe,
    release_fast,
    /// The self-hosted backend and linker instead of LLVM — measured ~35x
    /// faster on a decorator module (0.6s against 21s). Never the mode of a
    /// binary a user keeps: it exists for compiles whose output is consumed
    /// and thrown away inside this very process, where machine-code quality
    /// buys nothing and the wait is the whole cost.
    debug,

    fn zigName(self: CompileMode) []const u8 {
        return switch (self) {
            .release_safe => "ReleaseSafe",
            .release_fast => "ReleaseFast",
            .debug => "Debug",
        };
    }

    fn runtimeLocations(self: CompileMode) bool {
        return switch (self) {
            .release_safe => true,
            .release_fast => false,
            .debug => true,
        };
    }
};

const lumen_version = @import("lumen_version.zig").lumen_version;

/// Human-readable message for a raw `E_*` diagnostic code. Diagnostics that
/// already carry a formatted message pass through unchanged.
fn humanizeDiag(code: []const u8) []const u8 {
    const eq = std.mem.eql;
    if (eq(u8, code, "E_TYPE_MISMATCH")) return "type mismatch [E_TYPE_MISMATCH]";
    if (eq(u8, code, "E_POSSIBLY_NULL")) return "value may be null [E_POSSIBLY_NULL]";
    if (eq(u8, code, "E_ARG_COUNT")) return "wrong number of arguments [E_ARG_COUNT]";
    if (eq(u8, code, "E_TYPE_ARG_COUNT")) return "wrong number of type arguments [E_TYPE_ARG_COUNT]";
    if (eq(u8, code, "E_MISSING_RETURN")) return "not all code paths return a value [E_MISSING_RETURN]";
    if (eq(u8, code, "E_RETURN_TYPE")) return "returned value does not match the declared return type [E_RETURN_TYPE]";
    if (eq(u8, code, "E_RETURN_OUTSIDE_FUNCTION")) return "'return' outside a function [E_RETURN_OUTSIDE_FUNCTION]";
    if (eq(u8, code, "E_CONST_ASSIGNMENT")) return "cannot assign to a 'const' binding [E_CONST_ASSIGNMENT]";
    if (eq(u8, code, "E_READONLY_ASSIGNMENT")) return "cannot assign to a 'readonly' field [E_READONLY_ASSIGNMENT]";
    if (eq(u8, code, "E_DUPLICATE_BINDING")) return "duplicate declaration of this name [E_DUPLICATE_BINDING]";
    if (eq(u8, code, "E_DUPLICATE_TYPE")) return "a type of this name is declared by another module [E_DUPLICATE_TYPE]";
    if (eq(u8, code, "E_BREAK_OUTSIDE_LOOP")) return "'break' outside a loop or switch [E_BREAK_OUTSIDE_LOOP]";
    if (eq(u8, code, "E_CONTINUE_OUTSIDE_LOOP")) return "'continue' outside a loop [E_CONTINUE_OUTSIDE_LOOP]";
    if (eq(u8, code, "E_MISSING_MEMBER")) return "missing required member [E_MISSING_MEMBER]";
    if (eq(u8, code, "E_MISSING_SUPER")) return "constructor of a derived class must call super(...) [E_MISSING_SUPER]";
    if (eq(u8, code, "E_PRIVATE_ACCESS")) return "member is private [E_PRIVATE_ACCESS]";
    if (eq(u8, code, "E_PROTECTED_ACCESS")) return "member is protected [E_PROTECTED_ACCESS]";
    if (eq(u8, code, "E_THROW_TYPE")) return "only Error values can be thrown [E_THROW_TYPE]";
    if (eq(u8, code, "E_VOID_VALUE")) return "a void expression cannot be used as a value [E_VOID_VALUE]";
    if (eq(u8, code, "E_SPREAD_TARGET")) return "spread argument only allowed for a rest parameter [E_SPREAD_TARGET]";
    if (eq(u8, code, "E_REST_NOT_LAST")) return "a rest parameter must be last [E_REST_NOT_LAST]";
    if (eq(u8, code, "E_REST_NOT_ARRAY")) return "a rest parameter must have an array type [E_REST_NOT_ARRAY]";
    if (eq(u8, code, "E_REQUIRED_AFTER_OPTIONAL")) return "a required parameter cannot follow an optional one [E_REQUIRED_AFTER_OPTIONAL]";
    if (eq(u8, code, "E_CAPTURED_MUTATION")) return "cannot mutate a variable captured by an arrow function — use a `for...of` loop or `reduce` instead [E_CAPTURED_MUTATION]";
    if (eq(u8, code, "E_DYNAMIC_PROPERTY_WRITE")) return "record fields are immutable; build a new object instead [E_DYNAMIC_PROPERTY_WRITE]";
    if (eq(u8, code, "E_AWAIT_OUTSIDE_ASYNC")) return "'await' outside an async function [E_AWAIT_OUTSIDE_ASYNC]";
    if (eq(u8, code, "E_AWAIT_NOT_PROMISE")) return "'await' operand is not a Promise [E_AWAIT_NOT_PROMISE]";
    if (eq(u8, code, "E_ASYNC_RETURN")) return "an async function must declare a Promise<...> return type [E_ASYNC_RETURN]";
    if (eq(u8, code, "E_UNSUPPORTED_NESTED_FUNCTION")) return "nested function declarations are not supported; use an arrow function [E_UNSUPPORTED_NESTED_FUNCTION]";
    if (eq(u8, code, "E_UNSUPPORTED_OPTIONAL_CALL")) return "optional method call (a?.m()) is not supported [E_UNSUPPORTED_OPTIONAL_CALL]";
    if (eq(u8, code, "E_UNSUPPORTED_STD")) return "unsupported standard-library call [E_UNSUPPORTED_STD]";
    if (eq(u8, code, "E_UNSUPPORTED_COMMONJS")) return "CommonJS (require/module.exports) is not supported; use import/export [E_UNSUPPORTED_COMMONJS]";
    if (eq(u8, code, "E_UNSUPPORTED_EVAL")) return "eval is not supported [E_UNSUPPORTED_EVAL]";
    if (eq(u8, code, "E_UNSUPPORTED_PROTOTYPE")) return "prototype manipulation is not supported [E_UNSUPPORTED_PROTOTYPE]";
    if (eq(u8, code, "E_UNTERMINATED_COMMENT")) return "unterminated comment [E_UNTERMINATED_COMMENT]";
    if (eq(u8, code, "E_UNTERMINATED_REGEX")) return "unterminated regex literal [E_UNTERMINATED_REGEX]";
    if (eq(u8, code, "E_INVALID_NUMBER")) return "invalid number literal [E_INVALID_NUMBER]";
    if (eq(u8, code, "E_TYPE_INFER")) return "cannot infer type here; add an annotation [E_TYPE_INFER]";
    if (eq(u8, code, "E_NOT_DISPOSABLE")) return "'using' target has no dispose method [E_NOT_DISPOSABLE]";
    if (eq(u8, code, "E_REF_ARG")) return "a Ref<T> parameter needs a mutable variable argument [E_REF_ARG]";
    if (eq(u8, code, "E_REF_TARGET")) return "invalid Ref<T> target type [E_REF_TARGET]";
    if (eq(u8, code, "E_FFI_TYPE")) return "type not supported across the FFI boundary [E_FFI_TYPE]";
    if (eq(u8, code, "E_UNKNOWN_MATCHER")) return "unknown test matcher [E_UNKNOWN_MATCHER]";
    if (eq(u8, code, "E_DECORATOR_ARG")) return "a decorator argument is metadata, not an expression — pass a string, number or boolean literal [E_DECORATOR_ARG]";
    if (eq(u8, code, "E_DECORATOR_TARGET")) return "a decorator belongs on a class, a class member, a function or a parameter [E_DECORATOR_TARGET]";
    return code;
}

/// Whether diagnostics use ANSI color (stderr is a terminal and NO_COLOR is
/// unset). Decided once at startup.
var g_color: bool = false;
// LUMEN_NO_GC=1 compiles without the conservative collector (the old
// grow-only arena), read once in `main` like `g_color`.
var g_no_gc: bool = false;

/// Merged-source line origins for the file being compiled (import inlining
/// shifts lines); empty when unavailable. Diagnostics display the origin
/// file:line while excerpts read the merged text (identical content).
var g_line_map: []const LineOrigin = &.{};

fn diagOrigin(fallback_file: []const u8, line: u32) LineOrigin {
    if (line >= 1 and line - 1 < g_line_map.len) {
        var o = g_line_map[line - 1];
        // Normalize a `././`-style join for display.
        while (std.mem.startsWith(u8, o.file, "./")) o.file = o.file[2..];
        return o;
    }
    return .{ .file = fallback_file, .line = line };
}

const C_BOLD_RED = "\x1b[1;31m";
const C_BOLD = "\x1b[1m";
const C_CYAN = "\x1b[36m";
const C_GREEN = "\x1b[32m";
const C_DIM = "\x1b[2m";
const C_RESET = "\x1b[0m";

fn printOneDiag(err: *std.Io.Writer, source: []const u8, file: []const u8, diag: compiler.Diag) !void {
    const origin = diagOrigin(file, diag.line);
    if (g_color) {
        try err.print(C_CYAN ++ "{s}:{d}:{d}:" ++ C_RESET ++ " " ++ C_BOLD_RED ++ "error:" ++ C_RESET ++ " " ++ C_BOLD ++ "{s}" ++ C_RESET ++ "\n", .{ origin.file, origin.line, diag.col, humanizeDiag(diag.msg) });
    } else {
        try err.print("{s}:{d}:{d}: error: {s}\n", .{ origin.file, origin.line, diag.col, humanizeDiag(diag.msg) });
    }
    var it = std.mem.splitScalar(u8, source, '\n');
    var n: u32 = 1;
    while (it.next()) |line| : (n += 1) {
        if (n == diag.line) {
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (g_color) {
                try err.print(C_DIM ++ "  {d} |" ++ C_RESET ++ " {s}\n" ++ C_DIM ++ "    |" ++ C_RESET ++ " ", .{ origin.line, trimmed });
            } else {
                try err.print("  {d} | {s}\n    | ", .{ origin.line, trimmed });
            }
            var col: u32 = 1;
            while (col < diag.col) : (col += 1) try err.writeByte(' ');
            // Underline the whole token at the caret (identifier characters, or
            // a quoted string), not just its first character.
            var span: usize = 1;
            if (diag.col >= 1 and diag.col - 1 < trimmed.len) {
                const start: usize = diag.col - 1;
                const c0 = trimmed[start];
                if (std.ascii.isAlphanumeric(c0) or c0 == '_') {
                    var e2 = start + 1;
                    while (e2 < trimmed.len and (std.ascii.isAlphanumeric(trimmed[e2]) or trimmed[e2] == '_')) : (e2 += 1) {}
                    span = e2 - start;
                } else if (c0 == '"') {
                    var e2 = start + 1;
                    while (e2 < trimmed.len and trimmed[e2] != '"') : (e2 += 1) {}
                    span = @min(e2 + 1, trimmed.len) - start;
                }
            }
            if (g_color) try err.writeAll(C_GREEN);
            try err.writeByte('^');
            var k: usize = 1;
            while (k < span) : (k += 1) try err.writeByte('~');
            if (g_color) try err.writeAll(C_RESET);
            try err.writeByte('\n');
            break;
        }
    }
}

fn printDiag(err: *std.Io.Writer, source: []const u8, file: []const u8, diag: compiler.Diag) !void {
    try printOneDiag(err, source, file, diag);
    for (diag.extra) |d| {
        try err.writeAll("\n");
        try printOneDiag(err, source, file, d);
    }
    if (diag.extra.len > 0) {
        try err.print("\n{d} errors\n", .{diag.extra.len + 1});
    }
}

const C_BOLD_YELLOW = "\x1b[1;33m";

fn printWarnings(err: *std.Io.Writer, source: []const u8, file: []const u8, warnings: []const compiler.Diag, errors: ?compiler.Diag) !void {
    for (warnings) |w| {
        // Suppress warnings on a line that already reported an error (e.g. the
        // recovery binding of a failed declaration) — pure noise there.
        if (errors) |e0| {
            if (w.line == e0.line) continue;
            var skip = false;
            for (e0.extra) |d| {
                if (w.line == d.line) skip = true;
            }
            if (skip) continue;
        }
        const worigin = diagOrigin(file, w.line);
        if (g_color) {
            try err.print(C_CYAN ++ "{s}:{d}:{d}:" ++ C_RESET ++ " " ++ C_BOLD_YELLOW ++ "warning:" ++ C_RESET ++ " {s}\n", .{ worigin.file, worigin.line, w.col, w.msg });
        } else {
            try err.print("{s}:{d}:{d}: warning: {s}\n", .{ worigin.file, worigin.line, w.col, w.msg });
        }
        var it = std.mem.splitScalar(u8, source, '\n');
        var n: u32 = 1;
        while (it.next()) |line| : (n += 1) {
            if (n == w.line) {
                try err.print("  {d} | {s}\n", .{ worigin.line, std.mem.trimEnd(u8, line, "\r") });
                break;
            }
        }
    }
}

/// A parsed `import ... from "..."` clause. A module may be pulled in either by
/// its default export (`import name from "..."`) or by a list of named exports
/// (`import { a, b } from "..."`).
const ImportSpec = struct {
    kind: Kind,
    spec: []const u8,

    const Kind = union(enum) {
        /// `import <binding> from "..."` — binds the module's default export.
        default: []const u8,
        /// `import { a, b as c } from "..."` — binds the listed named exports,
        /// optionally renamed (`as`). The module is inlined and each aliased
        /// export is renamed to its alias.
        named: []const NamedBinding,
        /// `import * as ns from "..."` — binds every export under a namespace; the
        /// module is inlined and `ns.member` accesses are rewritten to `member`.
        namespace: []const u8,
    };
};

/// One `{ name }` or `{ name as alias }` entry of a named import.
const NamedBinding = struct { name: []const u8, alias: []const u8 };

/// The local names an import line binds, whatever its form.
fn importedAliases(arena: std.mem.Allocator, kind: ImportSpec.Kind) []const []const u8 {
    switch (kind) {
        .named => |binds| {
            const out = arena.alloc([]const u8, binds.len) catch return &.{};
            for (binds, 0..) |b, i| out[i] = b.alias;
            return out;
        },
        .default, .namespace => |b| {
            const out = arena.alloc([]const u8, 1) catch return &.{};
            out[0] = b;
            return out;
        },
    }
}

/// Splits a comma-separated `{ a, b as c }` binding list into name/alias pairs.
/// Each entry is `name` (alias == name) or `name as alias`. Rejects empty entries
/// and stray punctuation so the import surface stays the TypeScript named form.
fn parseNamedBindings(arena: std.mem.Allocator, inner: []const u8) ![]const NamedBinding {
    var binds: std.ArrayListUnmanaged(NamedBinding) = .empty;
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \t");
        if (entry.len == 0) return error.InvalidImport;
        if (std.mem.indexOf(u8, entry, " as ")) |pos| {
            const name = std.mem.trim(u8, entry[0..pos], " \t");
            const alias = std.mem.trim(u8, entry[pos + 4 ..], " \t");
            if (name.len == 0 or alias.len == 0) return error.InvalidImport;
            if (std.mem.indexOfAny(u8, name, " \t{}*,.") != null or std.mem.indexOfAny(u8, alias, " \t{}*,.") != null) return error.InvalidImport;
            try binds.append(arena, .{ .name = name, .alias = alias });
        } else {
            if (std.mem.indexOfAny(u8, entry, " \t{}*") != null) return error.InvalidImport;
            try binds.append(arena, .{ .name = entry, .alias = entry });
        }
    }
    if (binds.items.len == 0) return error.InvalidImport;
    return binds.items;
}

fn parseImportSpec(arena: std.mem.Allocator, line: []const u8) !?ImportSpec {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, trimmed, "import ")) return null;
    // Either quote style: `from "./x"` or `from './x'` (spec 274).
    const dq = std.mem.indexOf(u8, trimmed, " from \"");
    const sq = std.mem.indexOf(u8, trimmed, " from '");
    const quote: u8 = if (dq != null) '"' else '\'';
    const marker_pos = dq orelse (sq orelse return error.InvalidImport);
    const clause = std.mem.trim(u8, trimmed["import ".len..marker_pos], " \t");
    const spec_start = marker_pos + " from \"".len;
    const spec_end = std.mem.indexOfScalarPos(u8, trimmed, spec_start, quote) orelse return error.InvalidImport;
    const spec = trimmed[spec_start..spec_end];
    const is_local = std.mem.startsWith(u8, spec, "./") or std.mem.startsWith(u8, spec, "../");
    const is_url = std.mem.startsWith(u8, spec, "https://");
    // Local relative or https URL only; reject http://, bare, and others.
    if (!is_local and !is_url) return error.InvalidImport;
    // Extensionless local imports (`./util`, the common TS style) resolve by
    // appending `.ts`; URLs must spell the extension.
    var spec_resolved = spec;
    if (!std.mem.endsWith(u8, spec_resolved, ".ts")) {
        if (!is_local) return error.InvalidImport;
        spec_resolved = try std.fmt.allocPrint(arena, "{s}.ts", .{spec});
    }

    if (std.mem.startsWith(u8, clause, "{")) {
        if (!std.mem.endsWith(u8, clause, "}")) return error.InvalidImport;
        const inner = clause[1 .. clause.len - 1];
        const names = try parseNamedBindings(arena, inner);
        return .{ .kind = .{ .named = names }, .spec = spec_resolved };
    }

    // `import * as ns from "..."` — namespace import.
    if (std.mem.startsWith(u8, clause, "* as ")) {
        const ns = std.mem.trim(u8, clause["* as ".len..], " \t");
        if (ns.len == 0 or std.mem.indexOfAny(u8, ns, " \t{},.*") != null) return error.InvalidImport;
        return .{ .kind = .{ .namespace = ns }, .spec = spec_resolved };
    }

    if (clause.len == 0 or std.mem.indexOfAny(u8, clause, " \t{},*") != null) return error.InvalidImport;
    return .{ .kind = .{ .default = clause }, .spec = spec_resolved };
}

/// Emits an `export default function …` header as a plain `function` under the
/// name the module's default export ended up with in the flat program
/// (`emit_name`): its own name, or the importer's binding when the function is
/// anonymous.
fn appendExportDefaultFunction(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), trimmed: []const u8, emit_name_opt: ?[]const u8) !bool {
    const prefix = "export default function ";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return false;
    const rest = trimmed[prefix.len..];
    const paren = std.mem.indexOfScalar(u8, rest, '(') orelse return error.InvalidImport;
    const original_name = std.mem.trim(u8, rest[0..paren], " \t");
    if (original_name.len == 0 and emit_name_opt == null) return error.InvalidImport;
    const emit_name = emit_name_opt orelse original_name;
    try out.print(arena, "function {s}{s}\n", .{ emit_name, rest[paren..] });
    return true;
}

/// Reads the symbol name introduced by a `export function NAME` / `export const
/// NAME` / `export let NAME` / `export type NAME` declaration, returning the
/// name and the declaration with the `export ` keyword removed.
const NamedExport = struct {
    name: []const u8,
    /// The declaration with the leading `export ` removed.
    decl: []const u8,
};

fn parseNamedExportDecl(trimmed: []const u8) ?NamedExport {
    const decls = [_][]const u8{
        "export function ",
        "export const ",
        "export let ",
        // An `export type` alias binds no runtime value; it flows into the flat
        // program as a plain `type` declaration and is erased by the emitter.
        "export type ",
        // Multi-line declarations (spec 482). Only the line that opens one is
        // seen here: `export ` comes off it and the indented body flows through
        // untouched, because this pass is line-oriented. `scanTopLevelDecls`
        // already lists all three and already tracks their bodies by brace
        // depth, so namespacing and renaming need nothing further.
        "export class ",
        "export interface ",
        "export enum ",
    };
    for (decls) |prefix| {
        if (!std.mem.startsWith(u8, trimmed, prefix)) continue;
        const decl = trimmed["export ".len..];
        const rest = trimmed[prefix.len..];
        // Name runs up to the first `(`, `:`, `=`, `<`, `{`, `;`, or whitespace.
        // `<` stops a generic parameter list (`export type Box<T> = …`) from
        // becoming part of the exported name; `{` does the same for a body
        // opened with no space before it, as `export class C{` may be. The set
        // is `scanTopLevelDecls`'s, so the two passes agree on where a name ends.
        const end = std.mem.indexOfAny(u8, rest, "(:=<{; \t") orelse rest.len;
        const name = std.mem.trim(u8, rest[0..end], " \t");
        if (name.len == 0) return null;
        return .{ .name = name, .decl = decl };
    }
    return null;
}

/// Parses an `export { a, b }` re-export list into its names. Returns null when
/// the line is not such a statement.
fn parseExportList(arena: std.mem.Allocator, trimmed: []const u8) !?[]const NamedBinding {
    if (!std.mem.startsWith(u8, trimmed, "export {")) return null;
    const close = std.mem.indexOfScalar(u8, trimmed, '}') orelse return error.InvalidImport;
    const inner = trimmed["export {".len..close];
    return try parseNamedBindings(arena, inner);
}

/// A `export { a, b } from "..."` or `export * from "..."` re-export (spec 052).
/// `binds` is null for the `export *` (re-export-all) form.
const ReExport = struct { binds: ?[]const NamedBinding, spec: []const u8 };

/// Parses a re-export line -- a `export { ... } from "..."` list or an
/// `export * from "..."` -- reusing the same ` from "<spec>"` marker and
/// local/URL/`.ts` validation as `import`. Returns null when the line is not
/// a `from`-bearing re-export (a plain `export { a }` with no `from` is a
/// re-export *of local symbols* and stays with `parseExportList`).
fn parseReExport(arena: std.mem.Allocator, trimmed: []const u8) !?ReExport {
    if (!std.mem.startsWith(u8, trimmed, "export ")) return null;
    const dq = std.mem.indexOf(u8, trimmed, " from \"");
    const sq = std.mem.indexOf(u8, trimmed, " from '");
    const quote: u8 = if (dq != null) '"' else '\'';
    const marker_pos = dq orelse (sq orelse return null);
    const clause = std.mem.trim(u8, trimmed["export ".len..marker_pos], " \t");
    const spec_start = marker_pos + " from \"".len;
    const spec_end = std.mem.indexOfScalarPos(u8, trimmed, spec_start, quote) orelse return error.InvalidImport;
    const spec = trimmed[spec_start..spec_end];
    const is_local = std.mem.startsWith(u8, spec, "./") or std.mem.startsWith(u8, spec, "../");
    const is_url = std.mem.startsWith(u8, spec, "https://");
    if (!is_local and !is_url) return error.InvalidImport;
    if (!std.mem.endsWith(u8, spec, ".ts")) return error.InvalidImport;

    if (std.mem.eql(u8, clause, "*")) return .{ .binds = null, .spec = spec };
    if (std.mem.startsWith(u8, clause, "{")) {
        if (!std.mem.endsWith(u8, clause, "}")) return error.InvalidImport;
        const inner = clause[1 .. clause.len - 1];
        return .{ .binds = try parseNamedBindings(arena, inner), .spec = spec };
    }
    return error.InvalidImport;
}

/// Collects every symbol a module exports: default-function name (if any),
/// `export function/const/let/type NAME` declarations, and `export { a, b }`
/// lists. Used to validate that named imports refer to real exports.
fn collectExports(arena: std.mem.Allocator, io: std.Io, module_path: []const u8, is_url: bool, source: []const u8, set: *std.StringHashMapUnmanaged(void), depth: u8) !void {
    if (depth > 16) return;
    const dir = if (is_url) blk: {
        const slash = std.mem.lastIndexOfScalar(u8, module_path, '/') orelse break :blk ".";
        break :blk module_path[0..slash];
    } else (std.fs.path.dirname(module_path) orelse ".");
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        // A `from`-bearing re-export (spec 052) is checked first: `export
        // { a } from` exports the listed aliases; `export * from` re-exports
        // every symbol of the source module, which requires reading it.
        if (try parseReExport(arena, trimmed)) |re| {
            if (re.binds) |binds| {
                for (binds) |b| try set.put(arena, b.alias, {});
            } else {
                // `export * from "spec"` -- resolve and recurse to enumerate
                // the source's own exports. Local only; a star re-export from
                // a URL is left unenumerated (best-effort, rare).
                if (std.mem.startsWith(u8, re.spec, "https://")) continue;
                const child = if (is_url) re.spec else std.fs.path.join(arena, &.{ dir, re.spec }) catch continue;
                if (is_url) continue;
                const child_src = std.Io.Dir.cwd().readFileAlloc(io, child, arena, .limited(16 * 1024 * 1024)) catch continue;
                try collectExports(arena, io, child, false, child_src, set, depth + 1);
            }
            continue;
        }
        if (parseNamedExportDecl(trimmed)) |ne| {
            try set.put(arena, ne.name, {});
        } else if (try parseExportList(arena, trimmed)) |binds| {
            for (binds) |b| try set.put(arena, b.alias, {});
        }
    }
}

/// Resolves a relative specifier (`./x.ts`, `../y/z.ts`) against a remote
/// module's base directory URL (the URL up to its last `/`). `..` pops a path
/// segment but never past the host.
fn joinUrl(arena: std.mem.Allocator, base_dir: []const u8, rel: []const u8) ![]const u8 {
    const scheme = "https://";
    var dir = base_dir;
    var r = rel;
    while (true) {
        if (std.mem.startsWith(u8, r, "./")) {
            r = r[2..];
        } else if (std.mem.startsWith(u8, r, "../")) {
            r = r[3..];
            const slash = std.mem.lastIndexOfScalar(u8, dir, '/') orelse return error.InvalidImport;
            if (slash < scheme.len) return error.InvalidImport;
            dir = dir[0..slash];
        } else break;
    }
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, r });
}

/// Net `{`/`}` balance on a line, skipping string literals and line comments so
/// braces inside `"…{…"` or after `//` don't throw off block tracking.
fn braceDelta(line: []const u8) i32 {
    var depth: i32 = 0;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        switch (c) {
            '"', '\'', '`' => {
                i += 1;
                while (i < line.len and line[i] != c) : (i += 1) {
                    if (line[i] == '\\') i += 1;
                }
            },
            '/' => if (i + 1 < line.len and line[i + 1] == '/') return depth,
            '{' => depth += 1,
            '}' => depth -= 1,
            else => {},
        }
    }
    return depth;
}

const PACKAGE_DIR = ".lumen-packages";

fn packagePathFor(arena: std.mem.Allocator, url: []const u8) ![]const u8 {
    const scheme = "https://";
    if (!std.mem.startsWith(u8, url, scheme)) return error.InvalidImport;
    const after = url[scheme.len..];
    if (after.len == 0 or std.mem.indexOfScalar(u8, after, '/') == null) return error.InvalidImport;
    if (std.mem.indexOf(u8, after, "..") != null) return error.InvalidImport;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ PACKAGE_DIR, after });
}

fn urlForPackagePath(arena: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const prefix = PACKAGE_DIR ++ "/";
    const at = std.mem.indexOf(u8, path, prefix) orelse return null;
    const rest = path[at + prefix.len ..];
    if (rest.len == 0) return null;
    return std.fmt.allocPrint(arena, "https://{s}", .{rest}) catch null;
}

var g_no_local: bool = false;

var g_explain_imports: bool = false;

var g_explained: std.ArrayListUnmanaged([]const u8) = .empty;

fn explainResolution(arena: std.mem.Allocator, io: std.Io, url: []const u8, local: []const u8, how: []const u8) void {
    if (!g_explain_imports) return;
    for (g_explained.items) |seen| if (std.mem.eql(u8, seen, url)) return;
    g_explained.append(arena, url) catch {};
    var buf: [2048]u8 = undefined;
    var w: std.Io.File.Writer = .init(.stderr(), io, &buf);
    w.interface.print("lumen: {s} -> {s} [{s}]\n", .{ url, local, how }) catch {};
    w.interface.flush() catch {};
}

fn skipScanDir(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.') return true;
    const skip = [_][]const u8{ "node_modules", "zig-out", "zig-cache", "packages", "target", "dist" };
    for (skip) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

fn addCheckoutIfPresent(
    arena: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    pkg: []const u8,
    rest: []const u8,
    found: *std.ArrayListUnmanaged([]const u8),
    seen: *std.ArrayListUnmanaged(std.Io.File.INode),
) void {
    const candidate = std.fmt.allocPrint(arena, "{s}/packages/{s}/{s}", .{ root, pkg, rest }) catch return;
    const stat = std.Io.Dir.cwd().statFile(io, candidate, .{}) catch return;
    if (stat.kind != .file) return;
    for (seen.items) |inode| if (inode == stat.inode) return;
    seen.append(arena, stat.inode) catch {};
    found.append(arena, candidate) catch {};
}

fn repoRootFrom(arena: std.mem.Allocator, io: std.Io, start_dir: []const u8) ?[]const u8 {
    var up: []const u8 = start_dir;
    var hops: u8 = 0;
    while (hops < 8) : (hops += 1) {
        const git = std.fmt.allocPrint(arena, "{s}/.git", .{up}) catch return null;
        if (std.Io.Dir.cwd().access(io, git, .{})) |_| return up else |_| {}
        const pkgs = std.fmt.allocPrint(arena, "{s}/packages", .{up}) catch return null;
        if (std.Io.Dir.cwd().access(io, pkgs, .{})) |_| return up else |_| {}
        up = std.fmt.allocPrint(arena, "{s}/..", .{up}) catch return null;
    }
    return null;
}

fn openCheckoutFor(arena: std.mem.Allocator, io: std.Io, url: []const u8, start_dir: []const u8) error{AmbiguousPackage}!?[]const u8 {
    if (g_no_local) return null;
    const marker = "/package/";
    const at = std.mem.indexOf(u8, url, marker) orelse return null;
    const after = url[at + marker.len ..];
    if (after.len == 0) return null;
    const root = repoRootFrom(arena, io, start_dir) orelse return null;
    const beside = std.fmt.allocPrint(arena, "{s}/..", .{root}) catch return null;

    var found: std.ArrayListUnmanaged([]const u8) = .empty;
    var seen: std.ArrayListUnmanaged(std.Io.File.INode) = .empty;
    var from: usize = 0;
    while (std.mem.indexOfScalarPos(u8, after, from, '/')) |slash| {
        from = slash + 1;
        const name = after[0..slash];
        const rest = after[slash + 1 ..];
        if (name.len == 0 or rest.len == 0) continue;
        const leaf = std.mem.lastIndexOfScalar(u8, name, '/');
        const pkg = if (leaf) |l| name[l + 1 ..] else name;
        if (pkg.len == 0) continue;

        addCheckoutIfPresent(arena, io, root, pkg, rest, &found, &seen);

        if (std.Io.Dir.cwd().openDir(io, beside, .{ .iterate = true })) |opened| {
            var dir = opened;
            defer dir.close(io);
            var it = dir.iterate();
            while (it.next(io) catch null) |entry| {
                if (entry.kind != .directory) continue;
                if (skipScanDir(entry.name)) continue;
                const child = std.fmt.allocPrint(arena, "{s}/{s}", .{ beside, entry.name }) catch continue;
                addCheckoutIfPresent(arena, io, child, pkg, rest, &found, &seen);
            }
        } else |_| {}
    }

    if (found.items.len > 1) {
        var list: std.ArrayListUnmanaged(u8) = .empty;
        for (found.items) |item| {
            list.appendSlice(arena, "\n  ") catch {};
            list.appendSlice(arena, item) catch {};
        }
        setImportDetail(arena, "{s} is provided by more than one checkout, so which one to build is not decided:{s}\n  set LUMEN_NO_LOCAL=1 to ignore local checkouts and build the fetched copy", .{ url, list.items });
        return error.AmbiguousPackage;
    }
    if (found.items.len == 1) return found.items[0];
    return null;
}

fn resolveUrlToLocal(arena: std.mem.Allocator, io: std.Io, url: []const u8) ![]const u8 {
    if (try openCheckoutFor(arena, io, url, ".")) |local| {
        explainResolution(arena, io, url, local, "local checkout");
        return local;
    }

    const dest = try packagePathFor(arena, url);
    if (std.Io.Dir.cwd().access(io, dest, .{})) |_| {
        explainResolution(arena, io, url, dest, "cached");
        return dest;
    } else |_| {}

    const bytes = try fetchUrl(arena, io, url);
    if (std.fs.path.dirname(dest)) |parent| {
        std.Io.Dir.cwd().createDirPath(io, parent) catch return error.FetchFailed;
    }
    var file = std.Io.Dir.cwd().createFile(io, dest, .{}) catch return error.FetchFailed;
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var w = file.writer(io, &buf);
    w.interface.writeAll(bytes) catch return error.FetchFailed;
    w.interface.flush() catch return error.FetchFailed;
    explainResolution(arena, io, url, dest, "fetched");
    return dest;
}

fn ensurePackageFile(arena: std.mem.Allocator, io: std.Io, path: []const u8) void {
    if (std.Io.Dir.cwd().access(io, path, .{})) |_| return else |_| {}
    const url = urlForPackagePath(arena, path) orelse return;
    _ = resolveUrlToLocal(arena, io, url) catch return;
}

/// Fetches a module's source over HTTPS at build time.
fn fetchUrl(arena: std.mem.Allocator, io: std.Io, url: []const u8) ![]const u8 {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();
    client.ca_bundle.rescan(arena, io, std.Io.Clock.now(.real, io)) catch return error.FetchFailed;
    var aw: std.Io.Writer.Allocating = .init(arena);
    const res = client.fetch(.{ .location = .{ .url = url }, .response_writer = &aw.writer }) catch return error.FetchFailed;
    if (@intFromEnum(res.status) != 200) return error.FetchFailed;
    return aw.toArrayList().items;
}

/// Validates a named import against an already-inlined module by re-reading its
/// source and checking each requested binding is exported. (Default imports and
/// the entry module need no check.)
fn validateNamedImport(
    arena: std.mem.Allocator,
    io: std.Io,
    is_url: bool,
    path: []const u8,
    key: []const u8,
    import_kind: ?ImportSpec.Kind,
) !void {
    const kind = import_kind orelse return;
    const binds = switch (kind) {
        .named => |b| b,
        .default => return,
        .namespace => return,
    };
    const source = if (is_url)
        fetchUrl(arena, io, path) catch {
            setImportDetail(arena, "cannot find module '{s}'", .{displayPath(path)});
            return error.ImportReadFailed;
        }
    else
        std.Io.Dir.cwd().readFileAlloc(io, key, arena, .limited(16 * 1024 * 1024)) catch {
            setImportDetail(arena, "cannot find module '{s}'", .{displayPath(path)});
            return error.ImportReadFailed;
        };
    var exports: std.StringHashMapUnmanaged(void) = .empty;
    try collectExports(arena, io, if (is_url) path else key, is_url, source, &exports, 0);
    for (binds) |b| if (exports.get(b.name) == null) {
        setImportDetail(arena, "'{s}' is not exported by {s} ({s})", .{ b.name, displayPath(path), exportNames(arena, &exports) });
        return error.MissingExport;
    };
}

fn isIdentCh(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '$';
}
fn isIdentStartCh(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
}

/// True when the identifier at `line[i..j]` sits in a position that names a
/// *member* rather than a reference to a binding, and so must never be renamed
/// (spec 451). Two positions qualify:
///
///   * a member access — `obj.name`, `obj?.name` — but not the operand of a
///     spread (`...name`), which is an ordinary reference;
///   * a record field or object key — `name:` where nothing but whitespace, `{`
///     or `,` precedes it on the line, which covers `{ name: v }`, a type body
///     `name: string,` and a parameter list entry on its own line.
///
/// Both are heuristics over a line at a time, not a parse. The known gap is
/// shorthand destructuring (`const { name } = obj`), which is textually
/// indistinguishable from a reference.
fn isMemberPosition(line: []const u8, i: usize, j: usize) bool {
    var k = i;
    while (k > 0 and (line[k - 1] == ' ' or line[k - 1] == '\t')) k -= 1;
    if (k > 0 and line[k - 1] == '.' and !(k >= 2 and line[k - 2] == '.')) return true;
    var m = j;
    while (m < line.len and (line[m] == ' ' or line[m] == '\t')) m += 1;
    if (m >= line.len or line[m] != ':') return false;
    var p = i;
    while (p > 0) : (p -= 1) {
        const pc = line[p - 1];
        if (pc == ' ' or pc == '\t') continue;
        return pc == '{' or pc == ',';
    }
    return true;
}

/// Appends `line` to `out`, identifier-aware: rewrites `ns.member` -> `member`
/// for each namespace alias, and renames any bare identifier matching a
/// `renames` entry to its alias.
///
/// String literals and line comments are copied through untouched, but a
/// template literal's `${…}` interpolations are *not* — they hold ordinary
/// expressions, so identifiers inside them are renamed like any other (spec
/// 451; without this an aliased import used inside a template would dangle).
/// Member and key positions are left alone, see `isMemberPosition`.
fn appendTransformed(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), line: []const u8, namespaces: []const []const u8, renames: []const NamedBinding) !void {
    if (namespaces.len == 0 and renames.len == 0) return out.appendSlice(arena, line);
    // Nesting stack: a `quote` frame is inside a string literal; a `quote == 0`
    // frame is inside a `${…}` interpolation, where `depth` counts the braces
    // opened since, so the matching `}` is recognised. Templates may nest.
    const Frame = struct { quote: u8, depth: u32 };
    var stack: [16]Frame = undefined;
    var sp: usize = 0;
    var i: usize = 0;
    // Set for exactly one identifier: the member that followed a dropped `ns.`,
    // which is a reference despite being preceded by a `.`.
    var ns_member = false;
    while (i < line.len) {
        const c = line[i];
        const in_string = sp > 0 and stack[sp - 1].quote != 0;
        if (in_string) {
            const quote = stack[sp - 1].quote;
            try out.append(arena, c);
            if (c == '\\' and i + 1 < line.len) {
                try out.append(arena, line[i + 1]);
                i += 2;
                continue;
            }
            if (quote == '`' and c == '$' and i + 1 < line.len and line[i + 1] == '{') {
                try out.append(arena, '{');
                i += 2;
                if (sp < stack.len) {
                    stack[sp] = .{ .quote = 0, .depth = 0 };
                    sp += 1;
                }
                continue;
            }
            if (c == quote) sp -= 1;
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'' or c == '`') {
            if (sp < stack.len) {
                stack[sp] = .{ .quote = c, .depth = 0 };
                sp += 1;
            }
            try out.append(arena, c);
            i += 1;
            ns_member = false;
            continue;
        }
        if (c == '/' and i + 1 < line.len and line[i + 1] == '/') return out.appendSlice(arena, line[i..]);
        if (sp > 0 and (c == '{' or c == '}')) {
            if (c == '{') {
                stack[sp - 1].depth += 1;
            } else if (stack[sp - 1].depth == 0) {
                sp -= 1; // end of the `${…}` interpolation
                try out.append(arena, c);
                i += 1;
                ns_member = false;
                continue;
            } else stack[sp - 1].depth -= 1;
        }
        const boundary = i == 0 or !isIdentCh(line[i - 1]);
        if (boundary and isIdentStartCh(c)) {
            const after_ns = ns_member;
            ns_member = false;
            var j = i;
            while (j < line.len and isIdentCh(line[j])) j += 1;
            const ident = line[i..j];
            if (j < line.len and line[j] == '.') {
                var is_ns = false;
                for (namespaces) |ns| if (std.mem.eql(u8, ns, ident)) {
                    is_ns = true;
                    break;
                };
                if (is_ns) {
                    i = j + 1; // drop `ns.`
                    ns_member = true;
                    continue;
                }
            }
            var renamed: ?[]const u8 = null;
            if (after_ns or !isMemberPosition(line, i, j)) {
                for (renames) |r| if (std.mem.eql(u8, r.name, ident)) {
                    renamed = r.alias;
                    break;
                };
            }
            try out.appendSlice(arena, renamed orelse ident);
            i = j;
            continue;
        }
        ns_member = false;
        try out.append(arena, c);
        i += 1;
    }
}

const LineOrigin = compiler.LineOrigin;

/// Human detail for the most recent import-expansion failure (module path,
/// missing name, export list), rendered by compileFile with the error code.
var g_import_detail: ?[]const u8 = null;

fn setImportDetail(arena: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    g_import_detail = std.fmt.allocPrint(arena, fmt, args) catch null;
}

/// Source location for an import-expansion failure that has one — a duplicate
/// type name points at the second declaration, not at the entry file's line 1.
var g_import_loc: ?struct { file: []const u8, line: u32 } = null;

fn setImportLoc(file: []const u8, line: u32) void {
    g_import_loc = .{ .file = file, .line = line };
}

/// Display form of a module path: no `././` stacking.
const TypeOwner = struct {
    key: []const u8,
    path: []const u8,
};

fn displayPath(path: []const u8) []const u8 {
    var p = path;
    while (std.mem.startsWith(u8, p, "./")) p = p[2..];
    return p;
}

fn exportNames(arena: std.mem.Allocator, exports: *std.StringHashMapUnmanaged(void)) []const u8 {
    var names: std.ArrayListUnmanaged(u8) = .empty;
    var it = exports.keyIterator();
    var first = true;
    while (it.next()) |k| {
        if (!first) names.appendSlice(arena, ", ") catch {};
        names.appendSlice(arena, k.*) catch {};
        first = false;
    }
    if (names.items.len == 0) return "nothing is exported";
    return std.fmt.allocPrint(arena, "exports: {s}", .{names.items}) catch "";
}

/// What an inlined module contributes to the flat program: for each name the
/// module exports, the identifier that name actually ended up with. The two are
/// equal in the ordinary case; they differ when a declaration had to be renamed
/// because the flat program already had that name (spec 451), or when a
/// re-export aliases.
///
/// Stored by pointer in `Expander.emitted` because the re-export entries are
/// filled in while the module's own lines are still being walked.
const ModuleInfo = struct {
    path: []const u8,
    exports: std.StringHashMapUnmanaged([]const u8) = .empty,
};

/// Which namespace a top-level declaration binds. The checker keeps type names
/// and value names apart, so the expander does too — a `type Result` and a
/// `const Result` do not collide.
const DeclKind = enum { value, type_name };

const TopDecl = struct {
    name: []const u8,
    kind: DeclKind,
    /// 1-based line in the module's own source, for the duplicate-type report.
    line: u32,
    exported: bool,
    /// `export default function NAME` — importable under the name `default`.
    is_default: bool = false,
};

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// Collects the names a module declares at top level, exported or not. Textual
/// like the rest of the pre-processor: a declaration is a line at brace depth 0
/// that starts in column 0 with a declaration keyword. That is exactly how
/// Lumen sources are written, and anything indented or nested is a body line.
fn scanTopLevelDecls(arena: std.mem.Allocator, source: []const u8, out: *std.ArrayListUnmanaged(TopDecl)) !void {
    const kws = [_]struct { kw: []const u8, kind: DeclKind }{
        .{ .kw = "function ", .kind = .value },
        .{ .kw = "const ", .kind = .value },
        .{ .kw = "let ", .kind = .value },
        .{ .kw = "var ", .kind = .value },
        .{ .kw = "class ", .kind = .value },
        .{ .kw = "enum ", .kind = .value },
        .{ .kw = "type ", .kind = .type_name },
        .{ .kw = "interface ", .kind = .type_name },
    };
    var depth: i32 = 0;
    var src_line: u32 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        src_line += 1;
        const delta = braceDelta(line);
        defer depth += delta;
        if (depth != 0) continue;
        if (line.len == 0 or line[0] == ' ' or line[0] == '\t') continue;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        var rest = trimmed;
        const exported = std.mem.startsWith(u8, rest, "export ");
        if (exported) rest = rest["export ".len..];
        var is_default = false;
        if (std.mem.startsWith(u8, rest, "default ")) {
            if (!exported) continue;
            is_default = true;
            rest = rest["default ".len..];
        }
        if (std.mem.startsWith(u8, rest, "declare ")) rest = rest["declare ".len..];
        if (std.mem.startsWith(u8, rest, "async ")) rest = rest["async ".len..];
        for (kws) |k| {
            if (!std.mem.startsWith(u8, rest, k.kw)) continue;
            const tail = rest[k.kw.len..];
            const end = std.mem.indexOfAny(u8, tail, "(:=<{ \t;") orelse tail.len;
            const name = std.mem.trim(u8, tail[0..end], " \t");
            if (name.len == 0 or !isIdentStartCh(name[0])) break;
            try out.append(arena, .{
                .name = name,
                .kind = k.kind,
                .line = src_line,
                .exported = exported and !is_default,
                .is_default = is_default,
            });
            break;
        }
    }
}

/// Dedup/cycle key for a module. Two spellings of the same module must produce
/// the same key, or it is inlined twice and collides with itself (spec 451 D4).
/// A local path resolves to an absolute path; a URL keeps its path
/// case-sensitive but has its scheme and host lowercased, a default `:443`
/// dropped, empty/`.`/`..` segments resolved and any trailing `/` removed.
/// A module's identity, for deciding whether two imports name the same module.
///
/// Not the path: `resolve` collapses `.` and `..` but leaves a relative path
/// relative, so a package's index reached as `../pkg/index.ts` from one
/// importer and as `index.ts` from another keys two different ways and the
/// module is inlined twice — which surfaces as every type in it being
/// "declared by both". The file's own inode settles it, and a URL is already
/// canonical.
fn moduleIdentity(arena: std.mem.Allocator, io: std.Io, key: []const u8, is_url: bool) []const u8 {
    if (is_url) return key;
    const st = std.Io.Dir.cwd().statFile(io, key, .{}) catch return key;
    return std.fmt.allocPrint(arena, "inode:{d}", .{st.inode}) catch key;
}

fn canonicalModuleKey(arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    const scheme = "https://";
    if (!std.mem.startsWith(u8, path, scheme) and !std.mem.startsWith(u8, path, "HTTPS://"))
        return std.fs.path.resolve(arena, &.{path});
    const after = path[scheme.len..];
    const host_end = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
    var host = try arena.dupe(u8, after[0..host_end]);
    for (host) |*c| c.* = std.ascii.toLower(c.*);
    if (std.mem.endsWith(u8, host, ":443")) host = host[0 .. host.len - 4];

    var segs: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, after[host_end..], '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (segs.items.len > 0) _ = segs.pop();
            continue;
        }
        try segs.append(arena, seg);
    }
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    try buf.appendSlice(arena, scheme);
    try buf.appendSlice(arena, host);
    for (segs.items) |seg| {
        try buf.append(arena, '/');
        try buf.appendSlice(arena, seg);
    }
    return buf.items;
}

/// The decorator that could not run, for `compileFile` to report once the
/// expansion has unwound. Mirrors `g_import_detail`: the expander returns an
/// error, and the located message waits here.
const DecoratorFail = struct { file: []const u8, at: decorator.Failure };
var g_decorator_fail: ?DecoratorFail = null;

/// A decorator module is compiled by the compiler itself, so a decorator whose
/// module carries decorators nests. One level of that is staging; four is a
/// program that has lost track of what it is building.
var g_decorator_depth: u8 = 0;

fn decoratorFailed(arena: std.mem.Allocator, file: []const u8, app: describe.Application, comptime fmt: []const u8, args: anytype) error{ DecoratorFailed, OutOfMemory } {
    g_decorator_fail = .{ .file = file, .at = .{
        .line = app.line,
        .col = app.col,
        .msg = std.fmt.allocPrint(arena, fmt, args) catch "a decorator failed",
    } };
    return error.DecoratorFailed;
}

/// Where a decorator name came from: the import binding that introduced it.
const DecoratorBinding = struct {
    /// The name the module exports it under, which the alias may differ from.
    exported: []const u8,
    /// The module specifier as written, resolved against the importing file.
    spec: []const u8,
};

/// Runs every decorator written in one file and returns the constants they
/// produced (spec 455 D3/D4).
///
/// A decorator is resolved through the file's own imports, its module is
/// compiled standalone with a generated entry point, and the binary is run with
/// the description as its one argument. What it prints is the value; what it
/// writes to stderr is the diagnostic if it exits non-zero. Every failure is
/// reported at the decorator's own line, naming the decorator — a decorator's
/// module failing to compile is a failure of the decorator, not of this file.
///
/// `decorator_lines` collects the import lines that contributed decorator
/// bindings and nothing else, so the caller can leave them out of the flat
/// program: a decorator import contributes a binding to the compiler, and the
/// module's helpers have no business in the namespace of every program that
/// uses it. By line and not by module, since the same module may also be
/// imported for a type the generated constant needs.
fn runDecorators(
    exp: *Expander,
    path: []const u8,
    key: []const u8,
    dir: []const u8,
    source: []const u8,
    apps: []const describe.Application,
    decorator_lines: *std.AutoHashMapUnmanaged(u32, void),
) ![]const decorator.Generated {
    const arena = exp.arena;
    const io = exp.io;

    // Bindings first: a name used as a decorator is not inlined as a value, so
    // which imports to skip has to be known before any line is emitted.
    var bindings: std.StringHashMapUnmanaged(DecoratorBinding) = .empty;
    var line_no: u32 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        const spec = (parseImportSpec(arena, line) catch continue) orelse continue;
        if (spec.kind != .named) continue;
        var only_decorators = true;
        for (spec.kind.named) |b| {
            var used = false;
            for (apps) |app| {
                if (!std.mem.eql(u8, app.name, b.alias)) continue;
                used = true;
                try bindings.put(arena, b.alias, .{ .exported = b.name, .spec = spec.spec });
            }
            if (!used) only_decorators = false;
        }
        if (only_decorators) try decorator_lines.put(arena, line_no, {});
    }

    if (g_decorator_depth >= 4) return decoratorFailed(arena, path, apps[0], "'@{s}' is four decorator modules deep — the compiler stopped rather than staging further", .{apps[0].name});
    g_decorator_depth += 1;
    defer g_decorator_depth -= 1;

    var generated: std.ArrayListUnmanaged(decorator.Generated) = .empty;
    for (apps) |app| {
        const binding = bindings.get(app.name) orelse return decoratorFailed(arena, path, app, "'@{s}' is not imported — a decorator is an ordinary imported function, so add `import {{ {s} }} from \"./…\";`", .{ app.name, app.name });
        const module_path = if (std.mem.startsWith(u8, binding.spec, "https://"))
            resolveUrlToLocal(arena, io, binding.spec) catch
                return decoratorFailed(arena, path, app, "'@{s}' comes from {s}: {s}", .{ app.name, binding.spec, g_import_detail orelse "it could not be resolved to a local file" })
        else
            try std.fs.path.resolve(arena, &.{ dir, binding.spec });

        // A decorator module that reaches the file it decorates cannot be
        // compiled: that file is not finished until this decorator has run.
        var closure: std.StringArrayHashMapUnmanaged(void) = .empty;
        collectWatchPaths(arena, io, module_path, &closure, 0);
        if (closure.contains(key))
            return decoratorFailed(arena, path, app, "'@{s}' cannot run: {s} imports {s}, the file it decorates, so neither can be compiled first", .{ app.name, displayPath(module_path), displayPath(path) });

        const module_source = std.Io.Dir.cwd().readFileAlloc(io, module_path, arena, .limited(16 * 1024 * 1024)) catch
            return decoratorFailed(arena, path, app, "'@{s}' names {s}, which cannot be read", .{ app.name, displayPath(module_path) });

        var fail: decorator.Failure = undefined;
        const sig = decorator.signature(arena, module_source, displayPath(module_path), binding.exported, app, &fail) catch |e| switch (e) {
            error.DecoratorFailed => {
                g_decorator_fail = .{ .file = path, .at = fail };
                return e;
            },
            else => return e,
        };

        const value = try buildAndRun(exp, path, module_path, binding, app, sig.description, sig.described);
        const literal = decorator.literal(arena, value, app, &fail) catch |e| switch (e) {
            error.DecoratorFailed => {
                g_decorator_fail = .{ .file = path, .at = fail };
                return e;
            },
            else => return e,
        };
        try generated.append(arena, .{
            .decl_line = app.decl_line,
            .text = try std.fmt.allocPrint(arena, "let {s}: {s} = {s};\n", .{
                try decorator.constantName(arena, app.name, app.target),
                sig.returns,
                literal,
            }),
        });
    }
    return generated.items;
}

/// Compiles one decorator's module with a generated entry point and runs the
/// binary, returning what it printed. The entry point is written beside the
/// module so its import is the module's own relative path, and so a `// @link`
/// in the module's closure resolves exactly as it does for any other build.
fn buildAndRun(
    exp: *Expander,
    path: []const u8,
    module_path: []const u8,
    binding: DecoratorBinding,
    app: describe.Application,
    /// The description to hand over: `app.json` narrowed to the keys the
    /// module's own description type declares, so a key it never named cannot
    /// fail its parse.
    description: []const u8,
    /// What that module calls the type — every decorator package used to have
    /// to call it `Description`, which is why no two of them could be linked
    /// into one program.
    described: []const u8,
    // Explicit, because this calls the compiler's own entry point: an inferred
    // error set here would close a loop through everything compiling a file can
    // fail with. A failure of the decorator's module is the decorator's failure
    // anyway, so nothing else escapes.
) error{ DecoratorFailed, OutOfMemory }![]const u8 {
    const arena = exp.arena;
    const io = exp.io;

    // One build per decorator, however many sites apply it. The program being
    // built does not depend on the application — the description is argv at
    // run time — so the binary is memoized on (module, exported name) and
    // only the run happens per site. Before this, every @controller in a file
    // rebuilt an identical program from scratch.
    const memo_key = try std.fmt.allocPrint(arena, "{s}:{s}", .{ module_path, binding.exported });
    const exe = exp.decorator_exes.get(memo_key) orelse built: {
        // The entry point is a temporary file in someone else's directory, so
        // its name carries the running process: two compiles of the same
        // decorator at once write and delete their own.
        const entry_name = try std.fmt.allocPrint(arena, ".lumen-decorator-{s}-{x}.ts", .{ binding.exported, std.Thread.getCurrentId() });
        const entry_path = try std.fs.path.join(arena, &.{ std.fs.path.dirname(module_path) orelse ".", entry_name });
        const entry = try decorator.entrySource(arena, try std.fmt.allocPrint(arena, "./{s}", .{std.fs.path.basename(module_path)}), binding.exported, described);
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = entry_path, .data = entry }) catch
            return decoratorFailed(arena, path, app, "'@{s}' could not be run: {s} is not writable, and the generated entry point is written beside the module it calls", .{ app.name, displayPath(std.fs.path.dirname(module_path) orelse ".") });
        defer std.Io.Dir.cwd().deleteFile(io, entry_path) catch {};

        // The decorator's module is the user's own code with its own file and
        // lines, so its diagnostics are the message — captured rather than
        // printed, so they arrive under the decorator that pulled the module
        // in. Debug, not ReleaseSafe: this binary lives for the length of one
        // expansion and its speed of construction is the user's whole wait.
        var captured: std.Io.Writer.Allocating = .init(arena);
        const built = compileFile(arena, io, entry_path, .debug, .build_quiet, &.{}, false, false, &captured.writer) catch |e|
            return decoratorFailed(arena, path, app, "'@{s}' could not be compiled: {s}", .{ app.name, @errorName(e) });
        const exe_path = try std.fmt.allocPrint(arena, "./{s}", .{std.fs.path.stem(entry_name)});
        if (built != 0)
            return decoratorFailed(arena, path, app, "'@{s}' does not compile:\n{s}", .{ app.name, std.mem.trim(u8, captured.written(), "\n") });
        try exp.decorator_exes.put(arena, memo_key, exe_path);
        try exp.decorator_cleanup.append(arena, exe_path);
        break :built exe_path;
    };

    const ran = std.process.run(arena, io, .{ .argv = &.{ exe, description } }) catch
        return decoratorFailed(arena, path, app, "'@{s}' was built but could not be run", .{app.name});
    switch (ran.term) {
        .exited => |code| if (code != 0) return decoratorFailed(arena, path, app, "'@{s}' failed:\n{s}", .{ app.name, std.mem.trim(u8, if (ran.stderr.len > 0) ran.stderr else ran.stdout, "\n") }),
        else => return decoratorFailed(arena, path, app, "'@{s}' was terminated before it returned a value", .{app.name}),
    }
    return ran.stdout;
}

/// Shared state for one expansion of an entry module's import closure.
const Expander = struct {
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.ArrayListUnmanaged(u8),
    line_map: *std.ArrayListUnmanaged(LineOrigin),
    /// Modules on the current recursion path — an import cycle.
    visiting: std.StringHashMapUnmanaged(void) = .empty,
    /// Modules already inlined, by canonical key.
    emitted: std.StringHashMapUnmanaged(*ModuleInfo) = .empty,
    /// Value identifier in the flat program -> key of the module that declared it.
    taken: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Type name in the flat program -> path of the module that declared it.
    /// Which module declares each type name. Keyed by type name, holding the
    /// declaring module's canonical key alongside the path to show, because
    /// the same file reached two ways has two paths and one key — comparing
    /// paths would report a module as conflicting with itself.
    type_owners: std.StringHashMapUnmanaged(TypeOwner) = .empty,
    mangle_seq: u32 = 0,
    /// Decorator binaries already built during this expansion, keyed by
    /// module path + ":" + exported name. A decorator's program does not
    /// depend on the site that applies it — the application arrives as
    /// argv at run time — so fifteen @controller sites are fifteen runs of
    /// ONE binary. Building it fifteen times was the whole of api.ts's
    /// five-minute check: 15 x ~21s of identical work.
    decorator_exes: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// The executables above, for deletion when the expansion finishes —
    /// they outlive one buildAndRun call precisely because they are shared.
    decorator_cleanup: std.ArrayListUnmanaged([]const u8) = .empty,

    fn claimed(self: *Expander, name: []const u8) bool {
        return self.taken.get(name) != null or self.type_owners.get(name) != null;
    }

    /// Whether some OTHER module has already claimed this name. A module
    /// reached by two paths shares one canonical key, so it never counts as
    /// clashing with itself.
    fn ownedByOther(self: *Expander, name: []const u8, id: []const u8) bool {
        if (self.taken.get(name)) |owner| return !std.mem.eql(u8, owner, id);
        if (self.type_owners.get(name)) |owner| return !std.mem.eql(u8, owner.key, id);
        return false;
    }

    /// A `NAME__mN` identifier nothing in the flat program has claimed yet.
    fn freshName(self: *Expander, name: []const u8) ![]const u8 {
        while (true) {
            self.mangle_seq += 1;
            const cand = try std.fmt.allocPrint(self.arena, "{s}__m{d}", .{ name, self.mangle_seq });
            if (!self.claimed(cand)) return cand;
        }
    }
};

/// Inlines `path` (and, recursively, everything it imports) into `exp.out`.
///
/// `import_kind` is how the *parent* pulled this module in, used to validate
/// named bindings and to name a default export. `avoid` lists names this module
/// must not keep: the parent (or an earlier module) already owns them and the
/// parent refers to this module's under a different identifier, so the
/// declaration here is renamed instead — that is the only case in which a
/// definition moves. Every other rename lands on the *importer's* own text.
fn appendExpandedSource(
    exp: *Expander,
    path_in: []const u8,
    import_kind: ?ImportSpec.Kind,
    avoid: []const []const u8,
    depth: u8,
) !*ModuleInfo {
    const arena = exp.arena;
    const io = exp.io;
    const out = exp.out;
    if (depth > 16) return error.InvalidImport;
    var path = path_in;
    if (std.mem.startsWith(u8, path, "https://")) {
        path = resolveUrlToLocal(arena, io, path) catch |e| {
            if (e != error.AmbiguousPackage)
                setImportDetail(arena, "cannot find module '{s}'", .{displayPath(path_in)});
            return error.ImportReadFailed;
        };
    } else {
        ensurePackageFile(arena, io, path);
    }
    const is_url = std.mem.startsWith(u8, path, "https://");
    const key = try canonicalModuleKey(arena, path);
    const id = moduleIdentity(arena, io, key, is_url);
    if (exp.visiting.get(id) != null) {
        setImportDetail(arena, "import cycle through '{s}'", .{displayPath(path)});
        return error.ImportCycle;
    }
    if (exp.emitted.get(id)) |info| {
        // The module is already inlined, but a fresh importer may still request
        // named bindings: validate them against what the module exports.
        try validateNamedImport(arena, io, is_url, path, key, import_kind);
        return info;
    }
    try exp.visiting.put(arena, id, {});
    defer _ = exp.visiting.remove(id);

    const source = if (is_url)
        fetchUrl(arena, io, path) catch {
            setImportDetail(arena, "cannot find module '{s}'", .{displayPath(path)});
            return error.ImportReadFailed;
        }
    else
        std.Io.Dir.cwd().readFileAlloc(io, key, arena, .limited(16 * 1024 * 1024)) catch {
            if (depth == 0) return error.EntryReadFailed;
            setImportDetail(arena, "cannot find module '{s}'", .{displayPath(path)});
            return error.ImportReadFailed;
        };

    // Named imports must name real exports. Default import of the module's
    // default export needs no name check (the rename happens during emit).
    if (import_kind) |kind| switch (kind) {
        .named => |binds| {
            var exports: std.StringHashMapUnmanaged(void) = .empty;
            try collectExports(arena, io, if (is_url) path else key, is_url, source, &exports, 0);
            for (binds) |b| if (exports.get(b.name) == null) {
                setImportDetail(arena, "'{s}' is not exported by {s} ({s})", .{ b.name, displayPath(path), exportNames(arena, &exports) });
                return error.MissingExport;
            };
        },
        .default => {},
        .namespace => {}, // binds all exports; nothing to validate
    };

    const info = try arena.create(ModuleInfo);
    info.* = .{ .path = path };

    const default_binding: ?[]const u8 = if (import_kind) |kind| switch (kind) {
        .default => |b| b,
        .named, .namespace => null,
    } else null;

    // Physical names: what each of this module's own top-level declarations is
    // actually called in the flat program. Identity unless the name is already
    // claimed and an importer asked for it under a different identifier.
    var decls: std.ArrayListUnmanaged(TopDecl) = .empty;
    try scanTopLevelDecls(arena, source, &decls);
    var physical: std.StringHashMapUnmanaged([]const u8) = .empty;
    // Renames applied to THIS module's own text: first the ones forced by a
    // clash above, then one per aliased binding of its own import lines.
    var renames: std.ArrayListUnmanaged(NamedBinding) = .empty;
    var default_physical: ?[]const u8 = null;
    for (decls.items) |d| {
        if (physical.get(d.name) != null) continue;
        const demanded = containsName(avoid, d.name) or
            (d.is_default and default_binding != null and !std.mem.eql(u8, default_binding.?, d.name));
        var name = d.name;
        if (demanded and exp.claimed(d.name)) {
            name = try exp.freshName(d.name);
            try renames.append(arena, .{ .name = d.name, .alias = name });
        } else if (d.kind == .value and !d.is_default and exp.ownedByOther(d.name, id)) {
            // A clash with a name another module already claimed is the
            // compiler's to absorb, not the author's to avoid: two files
            // sharing a spelling is ordinary, and neither author has seen the
            // other's code (spec 473).
            //
            // This holds whether or not the declaration is exported. An export
            // is reached through its module's export table, which records the
            // physical name, so renaming the definition and letting importers
            // resolve through that table is invisible to both authors — which
            // is what a module system is for. Refusing instead made two
            // packages unable to coexist because each had a function called
            // `authHeaders` (spec 476).
            //
            // Only a clash with a DIFFERENT module renames: a module reached
            // twice by two paths is one module, and renaming it against itself
            // would break the second importer.
            name = try exp.freshName(d.name);
            try renames.append(arena, .{ .name = d.name, .alias = name });
        } else if (d.kind == .type_name) {
            if (exp.type_owners.get(d.name)) |owner| {
                // Two modules declaring the same type name is a real conflict,
                // and the flat program cannot hold both. Name them (spec 451 D3).
                if (!std.mem.eql(u8, owner.key, id)) {
                    setImportDetail(arena, "type '{s}' is declared by both {s} and {s}", .{ d.name, displayPath(owner.path), displayPath(path) });
                    setImportLoc(path, d.line);
                    return error.DuplicateTypeName;
                }
            } else if (exp.taken.get(d.name)) |owner| if (!std.mem.eql(u8, owner, id)) {
                // The name is claimed by another module, but for a VALUE: a
                // class, an enum, a function, a binding. The language keeps type
                // names and value names apart, so a type alias here and a class
                // over there are two unrelated declarations that happen to be
                // spelled alike -- the same coincidence spec 476 absorbs between
                // two values, and neither author has seen the other's file.
                //
                // Only the flat program conflates them: a class emits a struct
                // under its own name and so does a record type, and the backend
                // has one namespace where the language has two. Left alone, this
                // module kept the name and the checker resolved its OWN
                // annotations to the other module's class -- the wrong symbol,
                // found silently -- or, once both reached the backend, the
                // generated code was rejected as a duplicate struct member.
                //
                // Rename the declaration and rewrite this module's own
                // references, exactly as for a value. Importers resolve through
                // the export table, which records the physical name, so the
                // rename is invisible to them (spec 488).
                name = try exp.freshName(d.name);
                try renames.append(arena, .{ .name = d.name, .alias = name });
            };
        }
        try physical.put(arena, d.name, name);
        switch (d.kind) {
            .value => if (exp.taken.get(name) == null) try exp.taken.put(arena, name, id),
            .type_name => if (exp.type_owners.get(name) == null) try exp.type_owners.put(arena, name, .{ .key = id, .path = path }),
        }
        if (d.exported) try info.exports.put(arena, d.name, name);
        if (d.is_default) default_physical = name;
    }
    // An anonymous `export default function (…)` has no name of its own, so the
    // importer's binding names it — the one case where an importer still gets to
    // choose the emitted name.
    if (default_physical == null) default_physical = default_binding;
    if (default_physical) |dp| try info.exports.put(arena, "default", dp);

    // Base directory for resolving relative child imports: for a URL it is the
    // URL up to its last `/`; for a local file it is the file's directory.
    const dir = if (is_url) blk: {
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.InvalidImport;
        break :blk path[0..slash];
    } else (std.fs.path.dirname(key) orelse ".");

    // Decorators (spec 455). A file with no `@` in it cannot carry one, and
    // pays nothing here: no parse, no resolution, no build, no run. One that
    // might is parsed on its own to find them — a file whose decorators the
    // parser cannot reach has a real syntax error, which the ordinary pipeline
    // reports against the user's own line rather than from here.
    var generated: []const decorator.Generated = &.{};
    var decorator_lines: std.AutoHashMapUnmanaged(u32, void) = .empty;
    if (std.mem.indexOfScalar(u8, source, '@') != null) {
        var describe_diag: compiler.Diag = .{};
        const apps = describe.collect(arena, source, displayPath(path), &describe_diag) catch &.{};
        if (apps.len > 0) generated = try runDecorators(exp, path, key, dir, source, apps, &decorator_lines);
    }
    var pending: usize = 0;
    var brace_depth: i32 = 0;
    // A generated constant is mapped back to the declaration it belongs to, so
    // a checker error in it lands on a line the user wrote.
    const appendGenerated = struct {
        fn f(a: std.mem.Allocator, e: *Expander, o: *std.ArrayListUnmanaged(u8), file: []const u8, g: decorator.Generated) !void {
            try o.appendSlice(a, g.text);
            var nl = std.mem.count(u8, g.text, "\n");
            while (nl > 0) : (nl -= 1) try e.line_map.append(a, .{ .file = file, .line = g.decl_line });
        }
    }.f;

    // Records `alias -> target` for an identifier this module uses to reach a
    // child's declaration. Skipped when the module declares `alias` itself (a
    // genuine duplicate binding, which the checker reports) and rejected when it
    // would collide with one of this module's own declarations.
    const addImportRename = struct {
        fn f(
            a: std.mem.Allocator,
            list: *std.ArrayListUnmanaged(NamedBinding),
            phys: *std.StringHashMapUnmanaged([]const u8),
            module: []const u8,
            alias: []const u8,
            target: []const u8,
        ) !void {
            if (std.mem.eql(u8, alias, target)) return;
            if (phys.get(alias) != null) return;
            if (phys.get(target) != null) {
                setImportDetail(a, "'{s}' from {s} clashes with a declaration in this file and the module was already inlined, so it cannot be renamed", .{ target, displayPath(module) });
                return error.InvalidImport;
            }
            for (list.items) |r| if (std.mem.eql(u8, r.name, alias)) {
                if (std.mem.eql(u8, r.alias, target)) return;
                setImportDetail(a, "'{s}' is imported from two different modules", .{alias});
                return error.InvalidImport;
            };
            try list.append(a, .{ .name = alias, .alias = target });
        }
    }.f;

    var local_imports: std.StringHashMapUnmanaged(void) = .empty;
    var file_namespaces: std.ArrayListUnmanaged([]const u8) = .empty; // `import * as ns` aliases in this file
    // Tests belong to the module under test, not to importers: strip `test "…"`
    // blocks from imported modules (depth > 0) so they don't leak into the build.
    var test_skip: i32 = 0;
    var src_line: u32 = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        src_line += 1;
        // A generated constant lands once the declaration it was written on has
        // closed: everything after can use it, and its value is assigned before
        // any of that runs (spec 455 D4).
        while (pending < generated.len and brace_depth == 0 and generated[pending].decl_line < src_line) : (pending += 1)
            try appendGenerated(arena, exp, out, path, generated[pending]);
        brace_depth += braceDelta(line);
        const out_len_before = out.items.len;
        var child_recorded = false;
        // Record where any lines appended for this source line came from.
        // A spliced import records its own origins during recursion.
        defer if (!child_recorded) {
            var nl = std.mem.count(u8, out.items[out_len_before..], "\n");
            while (nl > 0) : (nl -= 1) exp.line_map.append(arena, .{ .file = path, .line = src_line }) catch {};
        };
        if (test_skip > 0) {
            test_skip += braceDelta(line);
            continue;
        }
        if (try parseImportSpec(arena, line)) |import_spec| {
            // An import that contributed only decorator bindings is not inlined:
            // it named a function for the compiler to run, and the module's own
            // helpers stay out of this program's namespace (spec 455 D3).
            if (decorator_lines.get(src_line) != null) continue;
            if (local_imports.get(import_spec.spec) != null) {
                setImportDetail(arena, "duplicate import of '{s}'", .{import_spec.spec});
                return error.DuplicateImport;
            }
            try local_imports.put(arena, import_spec.spec, {});
            if (import_spec.kind == .namespace) try file_namespaces.append(arena, import_spec.kind.namespace);
            const child_is_url = std.mem.startsWith(u8, import_spec.spec, "https://");
            // Resolve relative imports against the base dir — a URL base for a
            // remote module (recursive remote packages), a local path otherwise.
            const imported_path = if (child_is_url)
                import_spec.spec
            else if (is_url)
                try joinUrl(arena, dir, import_spec.spec)
            else
                try std.fs.path.join(arena, &.{ dir, import_spec.spec });
            // An aliased binding whose original name is already spoken for is
            // the one case where the child's declaration must move instead.
            var avoid_child: std.ArrayListUnmanaged([]const u8) = .empty;
            if (import_spec.kind == .named) for (import_spec.kind.named) |b| {
                if (std.mem.eql(u8, b.name, b.alias)) continue;
                if (exp.claimed(b.name)) try avoid_child.append(arena, b.name);
            };
            // A name this file imports AND declares itself is not the spelling
            // coincidence spec 476 absorbs: the author asked for the name and
            // then wrote it again, so a call to it has two readings and only
            // they can say which was meant. Absorbing it would pick one
            // silently, so this stays an error (spec 015).
            for (importedAliases(arena, import_spec.kind)) |alias| {
                if (physical.get(alias) == null) continue;
                setImportDetail(arena, "'{s}' is imported here and also declared in this file", .{alias});
                for (decls.items) |d| if (std.mem.eql(u8, d.name, alias)) setImportLoc(path, d.line);
                return error.ShadowedImport;
            }
            child_recorded = true;
            const child = try appendExpandedSource(exp, imported_path, import_spec.kind, avoid_child.items, depth + 1);
            switch (import_spec.kind) {
                .named => |binds| for (binds) |b| {
                    const target = child.exports.get(b.name) orelse b.name;
                    try addImportRename(arena, &renames, &physical, imported_path, b.alias, target);
                },
                .default => |b| {
                    const target = child.exports.get("default") orelse b;
                    try addImportRename(arena, &renames, &physical, imported_path, b, target);
                },
                .namespace => {
                    // `ns.member` drops to `member`; if the child had to move a
                    // declaration, the member reference follows it.
                    var it = child.exports.iterator();
                    while (it.next()) |e| {
                        if (std.mem.eql(u8, e.key_ptr.*, "default")) continue;
                        try addImportRename(arena, &renames, &physical, imported_path, e.key_ptr.*, e.value_ptr.*);
                    }
                },
            }
            continue;
        }
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (depth > 0 and std.mem.startsWith(u8, trimmed, "test \"")) {
            test_skip = braceDelta(line);
            continue;
        }
        if (try appendExportDefaultFunction(arena, out, trimmed, default_physical)) continue;
        // `export { a } from "..."` / `export * from "..."` (spec 052):
        // inline the source module (its symbols flow into the flat program) and
        // republish them under this module's export table. Must be checked
        // before parseExportList below, since a re-export also starts with
        // `export {`. The re-export line itself emits nothing.
        if (try parseReExport(arena, trimmed)) |re| {
            const child_is_url = std.mem.startsWith(u8, re.spec, "https://");
            const re_path = if (child_is_url)
                re.spec
            else if (is_url)
                try joinUrl(arena, dir, re.spec)
            else
                try std.fs.path.join(arena, &.{ dir, re.spec });
            const re_kind: ?ImportSpec.Kind = if (re.binds) |b| .{ .named = b } else null;
            child_recorded = true;
            const child = try appendExpandedSource(exp, re_path, re_kind, &.{}, depth + 1);
            if (re.binds) |binds| {
                for (binds) |b| try info.exports.put(arena, b.alias, child.exports.get(b.name) orelse b.name);
            } else {
                var it = child.exports.iterator();
                while (it.next()) |e| {
                    if (std.mem.eql(u8, e.key_ptr.*, "default")) continue;
                    try info.exports.put(arena, e.key_ptr.*, e.value_ptr.*);
                }
            }
            continue;
        }
        // `export { a, b }` re-export lists carry no declaration of their own:
        // the underlying functions/consts are emitted from their own lines, so
        // the list only records which local name each exported name resolves to.
        if (try parseExportList(arena, trimmed)) |binds| {
            for (binds) |b| try info.exports.put(arena, b.alias, physical.get(b.name) orelse b.name);
            continue;
        }
        // `export function/const/let/type NAME` declarations: drop the `export `
        // keyword and emit the plain declaration into the shared program. An
        // `export type` alias becomes a plain `type` declaration, which binds no
        // runtime value — it is erased by the emitter (spec 451).
        if (parseNamedExportDecl(trimmed)) |ne| {
            // Preserve original indentation by emitting onto its own line.
            try appendTransformed(arena, out, ne.decl, file_namespaces.items, renames.items);
            try out.append(arena, '\n');
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "export ")) return error.InvalidImport;
        try appendTransformed(arena, out, line, file_namespaces.items, renames.items);
        try out.append(arena, '\n');
    }
    // A declaration that closes on the file's last line still gets its constant.
    while (pending < generated.len) : (pending += 1)
        try appendGenerated(arena, exp, out, path, generated[pending]);
    // Keyed by the file's identity, not by a spelling of its path: the same
    // module reached two ways is one module.
    try exp.emitted.put(arena, id, info);
    return info;
}

const ExpandedSource = struct { text: []const u8, line_map: []const LineOrigin };

fn readSourceWithImports(arena: std.mem.Allocator, io: std.Io, path: []const u8) !ExpandedSource {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var line_map: std.ArrayListUnmanaged(LineOrigin) = .empty;
    var exp: Expander = .{ .arena = arena, .io = io, .out = &out, .line_map = &line_map };
    // Decorator binaries are shared across application sites, so they outlive
    // any single build call and are removed here, when nothing can run them
    // again. On the error path they are left behind — a stray temp file is a
    // better failure than deleting evidence mid-diagnosis — and the pid in
    // the name keeps two processes out of each other's files.
    defer for (exp.decorator_cleanup.items) |exe| {
        std.Io.Dir.cwd().deleteFile(io, exe) catch {};
    };
    _ = try appendExpandedSource(&exp, path, null, &.{}, 0);
    return .{ .text = out.items, .line_map = line_map.items };
}

/// Walks the LOCAL import closure of `path`, appending each resolved local file
/// path to `set` (deduplicated). `https://` URL imports are build-time/remote and
/// are deliberately skipped — the watcher only observes files on disk. Malformed
/// imports or missing files are tolerated: the rebuild itself will surface the
/// real diagnostic; the watch set just falls back to whatever resolved cleanly.
fn collectWatchPaths(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    set: *std.StringArrayHashMapUnmanaged(void),
    depth: u8,
) void {
    if (depth > 16) return;
    if (std.mem.startsWith(u8, path, "https://")) return;
    const key = std.fs.path.resolve(arena, &.{path}) catch return;
    if (set.contains(key)) return;
    set.put(arena, key, {}) catch return;

    const source = std.Io.Dir.cwd().readFileAlloc(io, key, arena, .limited(16 * 1024 * 1024)) catch return;
    const dir = std.fs.path.dirname(key) orelse ".";
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const import_spec = (parseImportSpec(arena, line) catch continue) orelse continue;
        if (std.mem.startsWith(u8, import_spec.spec, "https://")) continue;
        const child = std.fs.path.join(arena, &.{ dir, import_spec.spec }) catch continue;
        collectWatchPaths(arena, io, child, set, depth + 1);
    }
}

/// Process-global SIGINT state for `lumen watch`. A signal handler cannot take
/// arguments or touch the arena, so the watch loop publishes the running child's
/// process id here; the handler kills it and flips `interrupted` so the poll loop
/// exits cleanly. On platforms without POSIX signals this stays inert and the
/// watcher is stopped the usual way (the child is still killed between rebuilds).
const WatchSignal = struct {
    var interrupted: std.atomic.Value(bool) = .init(false);
    var child_id: std.atomic.Value(i64) = .init(0);

    fn handle(_: std.posix.SIG) callconv(.c) void {
        const id = child_id.load(.seq_cst);
        if (id != 0) {
            std.posix.kill(@intCast(id), std.posix.SIG.TERM) catch {};
        }
        interrupted.store(true, .seq_cst);
    }
};

/// Builds (and optionally runs) `path` once, returning the freshly spawned child
/// on success when running is enabled. Reuses the exact compile path so build
/// errors print byte-for-byte like `lumen compile`. A previous run, if any, is
/// killed before the new binary is spawned.
fn watchRebuild(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    mode: CompileMode,
    run: bool,
    prev: *?std.process.Child,
    err: *std.Io.Writer,
) !void {
    // Reuse the standard compile path so diagnostics are identical to `lumen
    // compile`. compileFile prints either the diagnostic or the success line.
    const code = compileFile(arena, io, path, mode, .build_exe, &.{}, false, false, err) catch |e| {
        try err.print("watch: rebuild error: {s}\n", .{@errorName(e)});
        try err.flush();
        return;
    };
    if (code != 0) {
        // Keep the last good run alive: a failed build leaves `prev` untouched.
        try err.writeAll("watch: build failed; keeping previous run\n");
        try err.flush();
        return;
    }
    if (!run) {
        try err.flush();
        return;
    }

    // Stop the previous run before launching the rebuilt binary.
    if (prev.*) |*child| {
        WatchSignal.child_id.store(0, .seq_cst);
        child.kill(io);
        prev.* = null;
    }

    const base = std.fs.path.stem(path);
    const exe_name = if (@import("builtin").os.tag == .windows)
        try std.fmt.allocPrint(arena, "{s}.exe", .{base})
    else
        try arena.dupe(u8, base);
    // Spawn via an explicit relative path so it resolves in cwd, not PATH.
    const exe_rel = try std.fmt.allocPrint(arena, "./{s}", .{exe_name});

    const child = std.process.spawn(io, .{
        .argv = &.{exe_rel},
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch {
        try err.print("watch: could not run {s}\n", .{exe_name});
        try err.flush();
        return;
    };
    // `child.id` is an opaque HANDLE on Windows, not an integer PID, and
    // WatchSignal only exists to let a POSIX signal handler `std.posix.kill`
    // the child on Ctrl-C (never installed on Windows to begin with -- see
    // the guard above) -- so there's nothing to store there.
    if (@import("builtin").os.tag != .windows) {
        if (child.id) |id| WatchSignal.child_id.store(@intCast(id), .seq_cst);
    }
    prev.* = child;
    try err.print("watch: running {s}\n", .{exe_rel});
    try err.flush();
}

/// `lumen watch <file.ts>`: rebuild whenever the entry file or any of its local
/// imports changes, re-running the produced binary unless `run` is false.
/// Watching is mtime polling at ~150 ms; the watch set is recomputed each rebuild
/// so newly added/removed local imports are picked up.
fn watchProject(arena: std.mem.Allocator, io: std.Io, path: []const u8, mode: CompileMode, run: bool, err: *std.Io.Writer) !u8 {
    if (!std.mem.endsWith(u8, path, ".ts")) {
        try err.print("error: expected a .ts source file, got {s}\n", .{path});
        return 2;
    }

    // Install a SIGINT/SIGTERM handler so Ctrl-C stops the watcher and kills the
    // running child. Best-effort: only meaningful on POSIX targets.
    if (@import("builtin").os.tag != .windows) {
        var act: std.posix.Sigaction = .{
            .handler = .{ .handler = WatchSignal.handle },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
        std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    }

    var prev: ?std.process.Child = null;
    // A per-poll scratch arena keeps long-running watches from leaking the
    // memory allocated by each rebuild (source reads, watch sets, hashing).
    var poll_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer poll_arena.deinit();

    // Snapshot of (path -> content hash) for the current watch set. Content
    // hashing is used instead of mtime because the file-stat path returns stale
    // modification times after a `zig build-exe` child runs under this I/O, while
    // file reads stay fresh; a 64-bit content hash is a reliable change signal.
    var prev_hashes: std.StringArrayHashMapUnmanaged(u64) = .empty;

    // Initial build.
    try watchRebuild(arena, io, path, mode, run, &prev, err);
    snapshotWatchSet(arena, io, path, &prev_hashes);
    try err.print("watching {d} files (Ctrl-C to stop)\n", .{prev_hashes.count()});
    try err.flush();

    while (!WatchSignal.interrupted.load(.seq_cst)) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(150), .awake) catch break;
        if (WatchSignal.interrupted.load(.seq_cst)) break;

        // Recompute the watch set every poll so import changes are tracked.
        _ = poll_arena.reset(.retain_capacity);
        const pa = poll_arena.allocator();
        var cur: std.StringArrayHashMapUnmanaged(u64) = .empty;
        snapshotWatchSet(pa, io, path, &cur);

        var changed = false;
        // A file appeared/disappeared from the set, or its contents changed.
        if (cur.count() != prev_hashes.count()) changed = true;
        var it = cur.iterator();
        while (it.next()) |entry| {
            if (prev_hashes.get(entry.key_ptr.*)) |old| {
                if (old != entry.value_ptr.*) changed = true;
            } else changed = true;
        }

        if (!changed) continue;

        // Rebuild, then refresh the content snapshot against the new set.
        try watchRebuild(arena, io, path, mode, run, &prev, err);
        prev_hashes.clearRetainingCapacity();
        snapshotWatchSet(arena, io, path, &prev_hashes);
    }

    if (prev) |*child| {
        WatchSignal.child_id.store(0, .seq_cst);
        child.kill(io);
    }
    try err.writeAll("\nwatch: stopped\n");
    try err.flush();
    return 0;
}

/// Fills `out` with (resolved local path -> content hash) for the entry file and
/// its local import closure. A file that cannot be read hashes to 0 so its later
/// appearance registers as a change.
fn snapshotWatchSet(
    arena: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    out: *std.StringArrayHashMapUnmanaged(u64),
) void {
    var set: std.StringArrayHashMapUnmanaged(void) = .empty;
    collectWatchPaths(arena, io, path, &set, 0);
    for (set.keys()) |k| {
        out.put(arena, k, fileHash(arena, io, k)) catch {};
    }
}

/// 64-bit hash of a file's contents (0 when unreadable). File reads stay fresh
/// under this I/O even after a build child runs, making content hashing a
/// reliable change signal for the watch poll loop.
fn fileHash(arena: std.mem.Allocator, io: std.Io, path: []const u8) u64 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024)) catch return 0;
    return std.hash.Wyhash.hash(0, data);
}

const Action = enum { build_exe, build_quiet, run_test, check_only };

/// The ambient declarations that make Lumen `.ts` sources type-check under plain
/// tsc/editors. Embedded from the repo's canonical `/lumen.d.ts` so `lumen init`
/// and the editor experience stay in sync with a single source of truth.
const lumen_dts = @embedFile("lumen.d.ts");

/// Minimal tsconfig that keeps a fresh project tsc-clean: ESNext target/lib (so
/// Math/Array resolve but no DOM globals collide with our ambient `console`),
/// lenient checking, and `noEmit` since Lumen — not tsc — produces the binary.
const tsconfig_json =
    \\{
    \\  "compilerOptions": {
    \\    "target": "ESNext",
    \\    "lib": ["ESNext"],
    \\    "module": "ESNext",
    \\    "moduleResolution": "Bundler",
    \\    "strict": false,
    \\    "noEmit": true,
    \\    "skipLibCheck": true
    \\  },
    \\  "include": ["**/*.ts"]
    \\}
    \\
;

/// Starter program. Compiles and runs with Lumen and type-checks under tsc with
/// the generated `lumen.d.ts`/`tsconfig.json`.
const main_ts =
    \\// A fresh Lumen project. Build and run it with:
    \\//
    \\//   lumen compile main.ts && ./main
    \\//
    \\// This file also type-checks under plain tsc (see lumen.d.ts / tsconfig.json).
    \\
    \\function greet(name: string): string {
    \\  return `Hello, ${name}!`;
    \\}
    \\
    \\const who: string = "Lumen";
    \\console.log(greet(who));
    \\
;

const gitignore_txt =
    \\# Native binaries produced by `lumen compile`
    \\main
    \\*.exe
    \\.lumen-*.zig
    \\
;

const InitFile = struct {
    name: []const u8,
    contents: []const u8,
};

const init_files = [_]InitFile{
    .{ .name = "lumen.d.ts", .contents = lumen_dts },
    .{ .name = "tsconfig.json", .contents = tsconfig_json },
    .{ .name = "main.ts", .contents = main_ts },
    .{ .name = ".gitignore", .contents = gitignore_txt },
};

/// Scaffolds a ready-to-edit Lumen project under `dir` (the current directory
/// when null). Existing files are never overwritten: each is skipped with a
/// notice. Prints a summary and a next-steps line.
fn initProject(io: std.Io, dir: ?[]const u8, out: *std.Io.Writer) !u8 {
    const cwd = std.Io.Dir.cwd();
    if (dir) |d| {
        cwd.createDirPath(io, d) catch {
            try out.print("error: could not create directory {s}\n", .{d});
            return 2;
        };
    }
    var target = if (dir) |d|
        cwd.openDir(io, d, .{}) catch {
            try out.print("error: could not open directory {s}\n", .{d});
            return 2;
        }
    else
        cwd;
    defer if (dir != null) target.close(io);

    const where = dir orelse ".";
    var created: usize = 0;
    var skipped: usize = 0;
    for (init_files) |f| {
        // Skip without clobbering when the file already exists.
        if (target.access(io, f.name, .{})) |_| {
            try out.print("skip {s} (exists)\n", .{f.name});
            skipped += 1;
            continue;
        } else |_| {}
        target.writeFile(io, .{ .sub_path = f.name, .data = f.contents }) catch {
            try out.print("error: could not write {s}\n", .{f.name});
            return 2;
        };
        try out.print("create {s}\n", .{f.name});
        created += 1;
    }

    try out.print("\nInitialized Lumen project in {s} ({d} created, {d} skipped).\n", .{ where, created, skipped });
    if (dir) |d| {
        try out.print("Next: cd {s} && lumen compile main.ts && ./main\n", .{d});
    } else {
        try out.writeAll("Next: lumen compile main.ts && ./main\n");
    }
    return 0;
}

/// Turns a link token into a zig build-exe argument: a bare name `m` becomes
/// `-lm`; a path-like token (`./libfoo.a`, `foo.o`) is passed through verbatim
/// so custom C/C++ objects and archives can be linked.
fn appendLink(arena: std.mem.Allocator, argv: *std.ArrayListUnmanaged([]const u8), token: []const u8) !void {
    if (std.mem.indexOfScalar(u8, token, '/') != null or std.mem.indexOfScalar(u8, token, '.') != null) {
        try argv.append(arena, try arena.dupe(u8, token));
    } else {
        try argv.append(arena, try std.fmt.allocPrint(arena, "-l{s}", .{token}));
    }
}

/// The libxev commit this compiler builds async programs against. Pinned (not
/// `main`) so every compile fetches the identical, previously-verified source
/// tree; bump deliberately when adopting a newer libxev.
const LIBXEV_COMMIT = "9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf";

/// Fetches and extracts libxev's source (the async event loop backing
/// async/await, Promise, and setTimeout) and returns a local path to its
/// `src/main.zig` module root, suitable for `-Mxev=<path>`. libxev is a pure
/// Zig dependency (no system install, no C library, unlike the libuv this
/// replaced), so this mirrors `fetchWasmLib`'s fetch-and-cache shape rather
/// than `pkg-config`: a one-time download (gzip+tar extracted via `std.compress
/// .flate`/`std.tar`) cached by commit, reused on every later compile.
fn fetchLibxev(arena: std.mem.Allocator, io: std.Io) ![]const u8 {
    const cache_dir = ".lumen-libxev-" ++ LIBXEV_COMMIT[0..12];
    const root = cache_dir ++ "/src/main.zig";
    if (std.Io.Dir.cwd().access(io, root, .{})) |_| {
        return root;
    } else |_| {}

    const url = "https://github.com/mitchellh/libxev/archive/" ++ LIBXEV_COMMIT ++ ".tar.gz";
    const bytes = try fetchUrl(arena, io, url);

    var fixed_reader = std.Io.Reader.fixed(bytes);
    const decomp_buf = try arena.alloc(u8, std.compress.flate.max_window_len);
    var decomp = std.compress.flate.Decompress.init(&fixed_reader, .gzip, decomp_buf);

    try std.Io.Dir.cwd().createDirPath(io, cache_dir);
    var out_dir = try std.Io.Dir.cwd().openDir(io, cache_dir, .{ .iterate = true });
    defer out_dir.close(io);
    try std.tar.extract(io, out_dir, &decomp.reader, .{ .strip_components = 1 });

    return root;
}

/// Links from each `// @link <lib>` pragma line in the source.
///
/// A relative path is resolved against the file that wrote the pragma, not the
/// working directory: a package that ships `@link ./shim.o` beside its source
/// links the same object however deep in the tree the program compiling it
/// happens to sit. `g_line_map` supplies the origin, since import inlining has
/// already merged every module into one text by this point.
fn collectLinkLibs(arena: std.mem.Allocator, source: []const u8, argv: *std.ArrayListUnmanaged([]const u8)) !void {
    const marker = "// @link ";
    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_no: u32 = 0;
    while (lines.next()) |line| {
        line_no += 1;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, marker)) continue;
        const lib = std.mem.trim(u8, trimmed[marker.len..], " \t");
        if (lib.len == 0) continue;
        try appendLink(arena, argv, try resolveLinkPath(arena, lib, line_no));
    }
}

/// A `@link` token as the linker should see it. A bare library name and an
/// absolute path pass through; a relative path is joined to the directory of
/// the source file that declared it.
fn resolveLinkPath(arena: std.mem.Allocator, token: []const u8, line_no: u32) ![]const u8 {
    if (token.len == 0 or token[0] == '/') return token;
    if (std.mem.indexOfScalar(u8, token, '/') == null) return token;
    if (line_no == 0 or line_no - 1 >= g_line_map.len) return token;
    const origin = g_line_map[line_no - 1].file;
    const dir = std.fs.path.dirname(origin) orelse return token;
    if (dir.len == 0) return token;
    return try std.fs.path.join(arena, &.{ dir, token });
}

/// The path an `embed(...)` call names, as the compiler should open it.
///
/// Absolute paths pass through; a relative one is joined to the directory of
/// the source file that wrote the call, exactly as `resolveLinkPath` does, so a
/// package that ships a file beside its source embeds the same bytes however
/// deep in the tree the program compiling it happens to sit.
fn resolveEmbedPath(arena: std.mem.Allocator, path: []const u8, line_no: u32) ![]const u8 {
    if (path.len == 0 or path[0] == '/') return path;
    if (line_no == 0 or line_no - 1 >= g_line_map.len) return path;
    const origin = g_line_map[line_no - 1].file;
    // A module fetched over http has no directory on disk to resolve against.
    if (std.mem.startsWith(u8, origin, "https://")) return path;
    const dir = std.fs.path.dirname(origin) orelse return path;
    if (dir.len == 0) return path;
    return try std.fs.path.join(arena, &.{ dir, path });
}

/// Appends `bytes` to `out` as a double-quoted Lumen string literal.
///
/// Only what would not survive is escaped. A quote or a backslash would end or
/// reinterpret the literal; a newline would push the rest of the source onto a
/// line the line map does not describe, so every embedded file has to stay on
/// the one line that wrote the call. Every other byte — including control bytes
/// and UTF-8 continuation bytes — is copied through, because the lexer keeps a
/// literal's bytes raw and `emitStrLit` escapes them again for the backend.
fn appendLumenStrLit(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), bytes: []const u8) !void {
    try out.append(arena, '"');
    for (bytes) |b| switch (b) {
        '"' => try out.appendSlice(arena, "\\\""),
        '\\' => try out.appendSlice(arena, "\\\\"),
        '\n' => try out.appendSlice(arena, "\\n"),
        '\r' => try out.appendSlice(arena, "\\r"),
        '\t' => try out.appendSlice(arena, "\\t"),
        0 => try out.appendSlice(arena, "\\0"),
        else => try out.append(arena, b),
    };
    try out.append(arena, '"');
}

/// Decodes the escapes in a string literal's raw source text. Paths rarely
/// carry any, but a Windows-style `"..\\shim\\x.sql"` has to mean one backslash
/// per pair before the path is opened.
fn unescapeLiteral(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] != '\\' or i + 1 >= raw.len) {
            try out.append(arena, raw[i]);
            continue;
        }
        i += 1;
        try out.append(arena, switch (raw[i]) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            '0' => 0,
            else => raw[i],
        });
    }
    return out.items;
}

const EmbedError = error{EmbedFailed} || std.mem.Allocator.Error;

/// One `embed`/`embedDir` call the scan has recognised, already located.
const EmbedCall = struct {
    /// Byte just past the closing `)`.
    end: usize,
    /// The literal path as written, escapes decoded.
    path: []const u8,
    line: u32,
    col: u32,
};

/// Reads the argument of an `embed`-family call whose name ends at `after_name`,
/// or fails with the "not a literal" diagnostic. The argument has to be a plain
/// string literal: the file is read before anything runs, so an expression here
/// would have nothing to evaluate it with.
fn parseEmbedCall(
    arena: std.mem.Allocator,
    source: []const u8,
    after_name: usize,
    line: u32,
    col: u32,
    diag: *compiler.Diag,
) EmbedError!EmbedCall {
    const notLiteral = struct {
        fn fail(d: *compiler.Diag, l: u32, c: u32) EmbedError {
            d.* = .{ .line = l, .col = c, .msg = "the path must be a literal — the file is read while compiling, so there is nothing to evaluate [E_EMBED]" };
            return error.EmbedFailed;
        }
    }.fail;

    var i = skipBlanks(source, after_name);
    if (i >= source.len or source[i] != '(') return notLiteral(diag, line, col);
    i = skipBlanks(source, i + 1);
    if (i >= source.len or (source[i] != '"' and source[i] != '\'')) return notLiteral(diag, line, col);

    const quote = source[i];
    const lit_start = i + 1;
    i = lit_start;
    while (i < source.len and source[i] != quote and source[i] != '\n') : (i += 1) {
        if (source[i] == '\\' and i + 1 < source.len) i += 1;
    }
    if (i >= source.len or source[i] != quote) return notLiteral(diag, line, col);
    const raw = source[lit_start..i];

    i = skipBlanks(source, i + 1);
    if (i >= source.len or source[i] != ')') return notLiteral(diag, line, col);
    return .{ .end = i + 1, .path = try unescapeLiteral(arena, raw), .line = line, .col = col };
}

fn skipBlanks(source: []const u8, from: usize) usize {
    var i = from;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t')) i += 1;
    return i;
}

/// Replaces every `embed("path")` and `embedDir("path")` call in the merged
/// source with the file contents themselves, before the parser runs.
///
/// The substitution is the whole feature: the checker sees a string literal and
/// the emitter emits a string, so no later phase knows the call existed and the
/// compiled binary never opens the file. Each replacement stays on the line
/// that wrote it, so the line map — and every diagnostic that reads through it
/// — still describes the text.
///
/// The scan tracks string, template, regex and comment state, because `embed(`
/// written inside any of those is text and not a call. That is stricter than
/// the `// @link` pragma scan, which gets away with matching whole lines.
fn expandEmbeds(arena: std.mem.Allocator, io: std.Io, source: []const u8, diag: *compiler.Diag) ![]const u8 {
    if (std.mem.indexOf(u8, source, "embed") == null) return source;

    // `${...}` nesting: one brace counter per open interpolation, so a template
    // inside an interpolation inside a template still closes in the right order.
    const Frame = union(enum) { template, interp: u32 };
    var frames: std.ArrayListUnmanaged(Frame) = .empty;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    var line: u32 = 1;
    var line_start: usize = 0;
    // `/` is division after a value and starts a regex literal otherwise. A
    // regex body may hold an unbalanced quote (`/'/`), so the scan resolves it
    // the way the lexer does rather than opening a string state that never ends.
    var after_value = false;
    // Last significant byte, to tell a call from a member named `embed`.
    var prev_sig: u8 = 0;
    var prev_word: []const u8 = "";

    while (i < source.len) {
        const in_template = frames.items.len > 0 and frames.items[frames.items.len - 1] == .template;
        const c = source[i];
        if (c == '\n') {
            try out.append(arena, c);
            i += 1;
            line += 1;
            line_start = i;
            continue;
        }
        if (in_template) {
            if (c == '\\' and i + 1 < source.len) {
                try out.appendSlice(arena, source[i .. i + 2]);
                i += 2;
                continue;
            }
            if (c == '`') {
                try out.append(arena, c);
                i += 1;
                _ = frames.pop();
                after_value = true;
                prev_sig = '`';
                continue;
            }
            if (c == '$' and i + 1 < source.len and source[i + 1] == '{') {
                try out.appendSlice(arena, "${");
                i += 2;
                try frames.append(arena, .{ .interp = 1 });
                after_value = false;
                prev_sig = '{';
                continue;
            }
            try out.append(arena, c);
            i += 1;
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\r') {
            try out.append(arena, c);
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
            while (i < source.len and source[i] != '\n') : (i += 1) try out.append(arena, source[i]);
            continue;
        }
        if (c == '/' and i + 1 < source.len and source[i + 1] == '*') {
            try out.appendSlice(arena, "/*");
            i += 2;
            while (i < source.len) {
                if (source[i] == '*' and i + 1 < source.len and source[i + 1] == '/') {
                    try out.appendSlice(arena, "*/");
                    i += 2;
                    break;
                }
                if (source[i] == '\n') {
                    line += 1;
                    line_start = i + 1;
                }
                try out.append(arena, source[i]);
                i += 1;
            }
            continue;
        }
        if (c == '"' or c == '\'') {
            const start = i;
            i += 1;
            while (i < source.len and source[i] != c and source[i] != '\n') : (i += 1) {
                if (source[i] == '\\' and i + 1 < source.len) i += 1;
            }
            if (i < source.len and source[i] == c) i += 1;
            try out.appendSlice(arena, source[start..i]);
            after_value = true;
            prev_sig = c;
            continue;
        }
        if (c == '`') {
            try out.append(arena, c);
            i += 1;
            try frames.append(arena, .template);
            continue;
        }
        if (c == '/' and !after_value) {
            const start = i;
            i += 1;
            var in_class = false;
            while (i < source.len and source[i] != '\n') : (i += 1) {
                if (source[i] == '\\' and i + 1 < source.len) {
                    i += 1;
                } else if (source[i] == '[') {
                    in_class = true;
                } else if (source[i] == ']') {
                    in_class = false;
                } else if (source[i] == '/' and !in_class) {
                    break;
                }
            }
            if (i < source.len and source[i] == '/') i += 1;
            while (i < source.len and isIdentCh(source[i])) i += 1;
            try out.appendSlice(arena, source[start..i]);
            after_value = true;
            prev_sig = '/';
            continue;
        }
        if (isIdentStartCh(c)) {
            var e = i + 1;
            while (e < source.len and isIdentCh(source[e])) e += 1;
            const word = source[i..e];
            const is_embed = std.mem.eql(u8, word, "embed") or std.mem.eql(u8, word, "embedDir");
            // `obj.embed(x)` is a method call and `function embed(...)` is a
            // declaration; neither is the compile-time form.
            const shadowed = prev_sig == '.' or std.mem.eql(u8, prev_word, "function");
            // Only a call is the compile-time form. `let embed = "x"` declares
            // a variable and `stringify(embed)` reads one; neither reads a
            // file, so neither is this feature's business.
            //
            // `embed` is not a reserved word. A package should not have to know
            // which names the compiler has taken — that is the same fault as a
            // parameter colliding with another module's function (spec 461),
            // seen from the compiler's side.
            const called = blk: {
                const j = skipBlanks(source, e);
                break :blk j < source.len and source[j] == '(';
            };
            if (is_embed and !shadowed and called) {
                const col: u32 = @intCast(i - line_start + 1);
                const call = try parseEmbedCall(arena, source, e, line, col, diag);
                const resolved = try resolveEmbedPath(arena, call.path, line);
                if (std.mem.eql(u8, word, "embed")) {
                    const bytes = std.Io.Dir.cwd().readFileAlloc(io, resolved, arena, .limited(16 * 1024 * 1024)) catch {
                        diag.* = .{ .line = line, .col = col, .msg = try std.fmt.allocPrint(arena, "cannot embed \"{s}\": no such file [E_EMBED]", .{call.path}) };
                        return error.EmbedFailed;
                    };
                    try appendLumenStrLit(arena, &out, bytes);
                } else {
                    try appendEmbeddedDir(arena, io, &out, resolved, call, diag);
                }
                i = call.end;
                after_value = true;
                prev_sig = ')';
                prev_word = "";
                continue;
            }
            try out.appendSlice(arena, word);
            i = e;
            after_value = !isRegexKeyword(word);
            prev_sig = word[word.len - 1];
            prev_word = word;
            continue;
        }
        if ((c >= '0' and c <= '9')) {
            try out.append(arena, c);
            i += 1;
            after_value = true;
            prev_sig = c;
            prev_word = "";
            continue;
        }
        if (c == '{' or c == '}') {
            if (frames.items.len > 0) {
                switch (frames.items[frames.items.len - 1]) {
                    .interp => |depth| {
                        if (c == '{') {
                            frames.items[frames.items.len - 1] = .{ .interp = depth + 1 };
                        } else if (depth == 1) {
                            _ = frames.pop();
                        } else {
                            frames.items[frames.items.len - 1] = .{ .interp = depth - 1 };
                        }
                    },
                    .template => unreachable, // handled above
                }
            }
        }
        try out.append(arena, c);
        i += 1;
        // `)`, `]` and a postfix `++`/`--` end a value; every other punctuator
        // puts the scan back at an expression start, where `/` is a regex.
        after_value = c == ')' or c == ']' or (c == '+' and prev_sig == '+') or (c == '-' and prev_sig == '-');
        prev_sig = c;
        prev_word = "";
    }
    return out.items;
}

fn isRegexKeyword(id: []const u8) bool {
    const kws = [_][]const u8{ "return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw", "case", "do", "else", "yield", "await" };
    for (kws) |kw| if (std.mem.eql(u8, kw, id)) return true;
    return false;
}

/// Appends the array literal an `embedDir(...)` call stands for: one
/// `{ name, text }` record per regular file directly in `dir`.
///
/// Entries are sorted by name so two builds of unchanged sources produce the
/// same program — directory order is whatever the filesystem hands back, which
/// is neither stable nor sorted. Subdirectories and anything that is not a
/// regular file are skipped rather than reported: a directory is pointed at for
/// what it holds. The compiler reads no meaning into a name; that a file is
/// called `V1__create_agents.sql` is the caller's business.
fn appendEmbeddedDir(
    arena: std.mem.Allocator,
    io: std.Io,
    out: *std.ArrayListUnmanaged(u8),
    dir_path: []const u8,
    call: EmbedCall,
    diag: *compiler.Diag,
) !void {
    const missing = struct {
        fn fail(a: std.mem.Allocator, d: *compiler.Diag, c: EmbedCall) !noreturn {
            d.* = .{ .line = c.line, .col = c.col, .msg = try std.fmt.allocPrint(a, "cannot embed \"{s}\": no such file [E_EMBED]", .{c.path}) };
            return error.EmbedFailed;
        }
    }.fail;

    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch try missing(arena, diag, call);
    defer dir.close(io);

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch try missing(arena, diag, call)) |entry| {
        if (entry.kind != .file) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    if (names.items.len == 0) try missing(arena, diag, call);
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    try out.appendSlice(arena, "[");
    for (names.items, 0..) |name, n| {
        if (n > 0) try out.appendSlice(arena, ", ");
        const full = try std.fs.path.join(arena, &.{ dir_path, name });
        const bytes = dir.readFileAlloc(io, name, arena, .limited(16 * 1024 * 1024)) catch {
            diag.* = .{ .line = call.line, .col = call.col, .msg = try std.fmt.allocPrint(arena, "cannot embed \"{s}\": no such file [E_EMBED]", .{full}) };
            return error.EmbedFailed;
        };
        try out.appendSlice(arena, "{ name: ");
        try appendLumenStrLit(arena, out, name);
        try out.appendSlice(arena, ", text: ");
        try appendLumenStrLit(arena, out, bytes);
        try out.appendSlice(arena, " }");
    }
    try out.appendSlice(arena, "]");
}

/// Writes the lowercase hex SHA-256 of `bytes` into `out`, returning the slice.
fn sha256Hex(out: *[64]u8, bytes: []const u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xf];
    }
    return out[0..64];
}

/// Fetches a prebuilt wasm archive named by a `// @wasm-link <url>` pragma and
/// returns a local path to it, caching by spec in the compile working directory
/// so the (multi-MB) archive is downloaded once per process, not per compile.
/// An optional `#sha256=<hex>` fragment pins the archive: the bytes are verified
/// against it (on download and on cache reuse), so a tampered or swapped artifact
/// is rejected rather than linked.
fn fetchWasmLib(arena: std.mem.Allocator, io: std.Io, spec: []const u8) ![]const u8 {
    var url = spec;
    var want_hash: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, spec, '#')) |hp| {
        url = spec[0..hp];
        const frag = spec[hp + 1 ..];
        const pfx = "sha256=";
        if (std.mem.startsWith(u8, frag, pfx)) want_hash = frag[pfx.len..];
    }

    var h = std.hash.Wyhash.init(0);
    h.update(spec);
    const cache = try std.fmt.allocPrint(arena, ".lumen-wasmlink-{x}.a", .{h.final()});
    var hexbuf: [64]u8 = undefined;

    // Reuse a cached copy, re-verifying its hash when pinned (guards the cache).
    if (std.Io.Dir.cwd().readFileAlloc(io, cache, arena, .limited(256 * 1024 * 1024))) |cached| {
        if (want_hash) |wh| {
            if (std.ascii.eqlIgnoreCase(sha256Hex(&hexbuf, cached), wh)) return cache;
        } else return cache;
    } else |_| {}

    const bytes = try fetchUrl(arena, io, url);
    if (want_hash) |wh| {
        if (!std.ascii.eqlIgnoreCase(sha256Hex(&hexbuf, bytes), wh)) return error.WasmLinkHashMismatch;
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = cache, .data = bytes });
    return cache;
}

/// Links prebuilt wasm archives named by `// @wasm-link <spec>` pragmas into a
/// wasm build. An `https://` spec is fetched (and cached) and linked as a local
/// archive; any other spec passes through `appendLink` (a local path or `-l`
/// name). Linking these archives resolves the program's `extern` (FFI) symbols
/// *inside* the module, so the result is a single self-contained wasm whose only
/// imports are WASI — no host-supplied engine. Returns true if any were linked.
fn collectWasmLinks(arena: std.mem.Allocator, io: std.Io, source: []const u8, argv: *std.ArrayListUnmanaged([]const u8)) !bool {
    const marker = "// @wasm-link ";
    var any = false;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, marker)) continue;
        const spec = std.mem.trim(u8, trimmed[marker.len..], " \t");
        if (spec.len == 0) continue;
        if (std.mem.startsWith(u8, spec, "https://")) {
            const local = try fetchWasmLib(arena, io, spec);
            try argv.append(arena, local);
        } else {
            try appendLink(arena, argv, spec);
        }
        any = true;
    }
    return any;
}

/// Names of `export function NAME(...)` declarations in the entry file — the
/// functions surfaced as callable wasm exports in `--reactor` mode.
fn collectReactorExports(arena: std.mem.Allocator, source: []const u8) ![]const []const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    const pfx = "export function ";
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, t, pfx)) continue;
        const rest = t[pfx.len..];
        const paren = std.mem.indexOfScalar(u8, rest, '(') orelse continue;
        const name = std.mem.trim(u8, rest[0..paren], " \t");
        if (name.len > 0) try names.append(arena, name);
    }
    return names.items;
}

/// Reactor glue appended to the generated Zig: a fixed input buffer the embedder
/// writes into, and per export a `__lumen_call_<name>(ptr, len) -> result_ptr`
/// that runs the `string -> string` function and reports the length via
/// `__lumen_out_len()`. The string arena is reset at each call (the previous
/// result has been read by then), giving repeated calls constant memory.
fn reactorWrappers(arena: std.mem.Allocator, names: []const []const u8) ![]const u8 {
    var w: std.ArrayListUnmanaged(u8) = .empty;
    try w.appendSlice(arena,
        \\
        \\// --- reactor exports (callable string-in / string-out) ---
        \\var __lumen_in_buf: [1 << 20]u8 = undefined;
        \\var __lumen_out_len_val: u32 = 0;
        \\export fn __lumen_in_ptr() u32 { return @intCast(@intFromPtr(&__lumen_in_buf)); }
        \\export fn __lumen_in_cap() u32 { return @intCast(__lumen_in_buf.len); }
        \\export fn __lumen_out_len() u32 { return __lumen_out_len_val; }
        \\
    );
    for (names) |n| {
        try w.print(
            arena,
            "export fn __lumen_call_{s}(__p: u32, __n: u32) u32 {{\n" ++
                "    _ = __sa_arena.reset(.retain_capacity);\n" ++
                "    const __r = {s}(@as([*]const u8, @ptrFromInt(@as(usize, __p)))[0..@as(usize, __n)]);\n" ++
                "    __lumen_out_len_val = @intCast(__r.len);\n" ++
                "    return @intCast(@intFromPtr(__r.ptr));\n" ++
                "}}\n",
            .{ n, n },
        );
    }
    return w.items;
}

/// `lumen describe <file.ts>`: the decorator description JSON for every
/// decorated declaration in one file (spec 455). Deliberately absent from the
/// usage text — it exists to exercise the protocol, not as a user-facing tool.
fn describeFile(arena: std.mem.Allocator, io: std.Io, path: []const u8, err: *std.Io.Writer) !u8 {
    if (!std.mem.endsWith(u8, path, ".ts")) {
        try err.print("error: expected a .ts source file, got {s}\n", .{path});
        return 2;
    }
    const source = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024)) catch {
        try err.print("error: cannot read file {s}\n", .{path});
        return 2;
    };
    var out_buf: [4096]u8 = undefined;
    var out_fw: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    var diag: compiler.Diag = .{};
    describe.describeSource(arena, source, path, &out_fw.interface, &diag) catch |e| switch (e) {
        error.ParseError => {
            try printDiag(err, source, path, diag);
            return 1;
        },
        else => return e,
    };
    try out_fw.interface.flush();
    return 0;
}

fn compileFile(arena: std.mem.Allocator, io: std.Io, path: []const u8, mode: CompileMode, action: Action, cli_libs: []const []const u8, wasm: bool, reactor: bool, err: *std.Io.Writer) !u8 {
    const compile_start = std.Io.Clock.Timestamp.now(io, .awake);
    if (!std.mem.endsWith(u8, path, ".ts")) {
        try err.print("error: expected a .ts source file, got {s}\n", .{path});
        return 2;
    }

    const expanded = readSourceWithImports(arena, io, path) catch |e| {
        const detail = g_import_detail;
        switch (e) {
            error.InvalidImport => try err.print("{s}:1:1: error: {s} [E_UNSUPPORTED_IMPORT]\n", .{ path, detail orelse "unsupported import syntax" }),
            error.ImportReadFailed => try err.print("{s}:1:1: error: {s} [E_IMPORT_NOT_FOUND]\n", .{ path, detail orelse "imported module not found" }),
            error.ImportCycle => try err.print("{s}:1:1: error: {s} [E_IMPORT_CYCLE]\n", .{ path, detail orelse "import cycle detected" }),
            error.DuplicateImport => try err.print("{s}:1:1: error: {s} [E_DUPLICATE_IMPORT]\n", .{ path, detail orelse "module imported twice" }),
            error.MissingExport => try err.print("{s}:1:1: error: {s} [E_MISSING_EXPORT]\n", .{ path, detail orelse "imported name is not exported" }),
            error.DecoratorFailed => {
                const f: DecoratorFail = g_decorator_fail orelse .{ .file = path, .at = .{ .line = 1, .col = 1, .msg = "a decorator failed" } };
                try err.print("{s}:{d}:{d}: error: {s} [E_DECORATOR]\n", .{ displayPath(f.file), f.at.line, f.at.col, f.at.msg });
            },
            error.ShadowedImport => {
                const loc = g_import_loc;
                try err.print("{s}:{d}:1: error: {s} [E_DUPLICATE_BINDING]\n", .{
                    if (loc) |l| displayPath(l.file) else path,
                    if (loc) |l| l.line else 1,
                    detail orelse "a name is both imported and declared here",
                });
            },
            error.DuplicateTypeName => {
                const loc = g_import_loc;
                try err.print("{s}:{d}:1: error: {s} [E_DUPLICATE_TYPE]\n", .{
                    if (loc) |l| displayPath(l.file) else path,
                    if (loc) |l| l.line else 1,
                    detail orelse "a type of this name is declared by another module",
                });
            },
            else => try err.print("error: cannot read file {s}\n", .{path}),
        }
        return 2;
    };
    g_line_map = expanded.line_map;
    defer g_line_map = &.{};

    var diag: compiler.Diag = .{};
    // `embed`/`embedDir` are resolved here, on the merged text and before the
    // parser. Diagnostics keep quoting `written`, the source as the user typed
    // it, so an excerpt shows `embed("./schema.sql")` and not the file it stands
    // for; the substitution never adds or removes a line, so both texts agree on
    // where every line is.
    const written = expanded.text;
    const source = expandEmbeds(arena, io, written, &diag) catch |e| switch (e) {
        error.EmbedFailed => {
            try printDiag(err, written, path, diag);
            return 1;
        },
        else => return e,
    };
    var warnings: std.ArrayListUnmanaged(compiler.Diag) = .empty;
    var zig_src = compiler.compileToZigWithOptions(arena, source, path, &diag, .{
        .runtime_locations = mode.runtimeLocations(),
        .wasm = wasm,
        .gc = !wasm and !g_no_gc,
        .warnings = &warnings,
        .line_map = expanded.line_map,
        .test_mode = action == .run_test,
    }) catch {
        try printDiag(err, written, path, diag);
        try printWarnings(err, written, path, warnings.items, diag);
        return 1;
    };
    try printWarnings(err, written, path, warnings.items, null);

    // `lumen check`: diagnostics only — stop before writing or building anything.
    if (action == .check_only) {
        try err.print("{s}: no errors\n", .{path});
        return 0;
    }

    // `--reactor`: surface the entry file's `export function`s as callable wasm
    // exports (string in/out via linear memory) so an embedder instantiates once
    // and calls them repeatedly, instead of re-running the program per call.
    var reactor_exports: []const []const u8 = &.{};
    if (reactor and wasm) {
        const entry_src = if (std.mem.startsWith(u8, path, "https://"))
            fetchUrl(arena, io, path) catch return error.FetchFailed
        else
            std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 * 1024 * 1024)) catch return error.ImportReadFailed;
        reactor_exports = try collectReactorExports(arena, entry_src);
        if (reactor_exports.len > 0) {
            zig_src = try std.mem.concat(arena, u8, &.{ zig_src, try reactorWrappers(arena, reactor_exports) });
        }
    }

    // The wasm target has no event loop, so async is still unavailable there.
    if (wasm and std.mem.indexOf(u8, zig_src, "@import(\"xev\")") != null) {
        try err.print("{s}:1:1: error: the wasm target does not support async yet\n", .{path});
        return 1;
    }

    // C FFI on wasm: an `extern fn` is resolved by linking a prebuilt wasm
    // archive named by a `// @wasm-link <url>` pragma (the wasm analogue of the
    // native `// @link`). The compiler fetches the archive and links it into the
    // module, so the FFI symbols resolve internally and the output is a single
    // self-contained wasm whose only imports are WASI.
    const wasm_ffi = wasm and std.mem.indexOf(u8, zig_src, "extern fn ") != null;

    const base = std.fs.path.stem(path);
    // The generated backend source is an internal artifact: write it to a hidden
    // temp file and remove it after building, so the user never sees it.
    const gen_path = try std.fmt.allocPrint(arena, ".lumen-{s}.zig", .{base});
    const exe_name = if (wasm)
        try std.fmt.allocPrint(arena, "{s}.wasm", .{base})
    else if (@import("builtin").os.tag == .windows)
        try std.fmt.allocPrint(arena, "{s}.exe", .{base})
    else
        try arena.dupe(u8, base);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = gen_path, .data = zig_src });
    defer std.Io.Dir.cwd().deleteFile(io, gen_path) catch {};

    const emit = try std.fmt.allocPrint(arena, "-femit-bin={s}", .{exe_name});
    // The native backend is invoked as `zig` from PATH. Release archives bundle
    // a private toolchain that the `lumen` launcher injects into PATH, so a
    // downloaded build is self-contained without exposing zig in the user's shell.
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    const needs_xev = !wasm and std.mem.indexOf(u8, zig_src, "@import(\"xev\")") != null;
    switch (action) {
        .build_exe, .build_quiet => if (wasm) {
            try argv.appendSlice(arena, &.{ "zig", "build-exe", gen_path, "-target", "wasm32-wasi", "-O", "ReleaseSmall", emit });
        } else if (needs_xev) {
            // libxev (the async event loop) is a pure-Zig dependency, not a system
            // library: fetched once and wired in as a named module via `-Mxev=`,
            // bare CLI flags (no build.zig needed) -- the same single-file
            // `zig build-exe` invocation as every other compile.
            const xev_root = fetchLibxev(arena, io) catch |e| {
                try err.print("{s}:1:1: error: could not fetch the libxev async runtime: {s}\n", .{ path, @errorName(e) });
                return 1;
            };
            try argv.appendSlice(arena, &.{
                "zig",                                                    "build-exe",
                "--dep",                                                  "xev",
                try std.fmt.allocPrint(arena, "-Mroot={s}", .{gen_path}), try std.fmt.allocPrint(arena, "-Mxev={s}", .{xev_root}),
                "-O",                                                     mode.zigName(),
                emit,
            });
        } else {
            try argv.appendSlice(arena, &.{ "zig", "build-exe", gen_path, "-O", mode.zigName(), emit });
        },
        .run_test => try argv.appendSlice(arena, &.{ "zig", "test", gen_path }),
        .check_only => unreachable, // returned before codegen
    }
    if (wasm) {
        // wasm C FFI: link the prebuilt archive(s) named by `// @wasm-link`, plus
        // the wasi-libc support libraries they reference (math, and the emulated
        // clock/signal shims QuickJS-style libraries use). The archive carries the
        // FFI implementation, so the program needs no host engine.
        if (wasm_ffi) {
            const linked = collectWasmLinks(arena, io, source, &argv) catch |e| {
                try err.print("{s}:1:1: error: could not fetch a // @wasm-link archive: {s}\n", .{ path, @errorName(e) });
                return 1;
            };
            if (!linked) {
                try err.print("{s}:1:1: error: wasm C FFI requires a // @wasm-link <url> archive to link\n", .{path});
                return 1;
            }
            try argv.appendSlice(arena, &.{ "-lc", "-lwasi-emulated-process-clocks", "-lwasi-emulated-signal", "-lm" });
        }
        // Surface the reactor exports (a wasm exe exports only `_start` by default).
        if (reactor_exports.len > 0) {
            try argv.appendSlice(arena, &.{ "--export=__lumen_in_ptr", "--export=__lumen_in_cap", "--export=__lumen_out_len" });
            for (reactor_exports) |n| try argv.append(arena, try std.fmt.allocPrint(arena, "--export=__lumen_call_{s}", .{n}));
        }
    } else {
        // Link C libraries: from `// @link <lib>` source pragmas and `--link` flags.
        try collectLinkLibs(arena, source, &argv);
        for (cli_libs) |lib| try appendLink(arena, &argv, lib);
        // The conservative collector behind `__alloc` is a system library; its
        // externs in the generated source are the signal that it is in play
        // (absent under LUMEN_NO_GC=1 and for programs that never allocate).
        if (std.mem.indexOf(u8, zig_src, "extern fn GC_init") != null) {
            try argv.appendSlice(arena, &.{ "-lgc", "-lc" });
        }
    }
    // Test mode: capture the backend's output and re-render it as concise
    // per-test results (Zig runner internals and generated-file paths stay
    // hidden). Build mode: capture stderr so a failure can be mapped back to
    // the .ts source instead of a black-box "failed to build" line.
    if (action == .run_test) {
        const result = std.process.run(arena, io, .{ .argv = argv.items }) catch {
            try err.print("error: could not run the native backend\n", .{});
            return 2;
        };
        // Pass the test program's own stdout (console.log output) through.
        if (result.stdout.len > 0) {
            var ob: [4096]u8 = undefined;
            var ow: std.Io.File.Writer = .init(.stdout(), io, &ob);
            ow.interface.writeAll(result.stdout) catch {};
            ow.interface.flush() catch {};
        }
        return try renderTestResults(arena, err, written, path, zig_src, gen_path, result.stderr, result.term);
    }
    const result = std.process.run(arena, io, .{ .argv = argv.items }) catch {
        try err.print("error: could not run the native backend\n", .{});
        return 2;
    };
    switch (result.term) {
        .exited => |code| {
            if (code == 0) {
                // `lumen run` keeps the program's output clean: no compile banner.
                if (action != .build_quiet) {
                    const elapsed = compile_start.durationTo(std.Io.Clock.Timestamp.now(io, .awake));
                    const ms: u64 = @intCast(@max(0, @divTrunc(elapsed.raw.nanoseconds, std.time.ns_per_ms)));
                    if (ms >= 1000) {
                        try err.print("compiled {s} -> {s} ({d}.{d}s)\n", .{ path, exe_name, ms / 1000, (ms % 1000) / 100 });
                    } else {
                        try err.print("compiled {s} -> {s} ({d}ms)\n", .{ path, exe_name, ms });
                    }
                }
                return 0;
            }
            try reportBackendFailure(err, written, path, zig_src, gen_path, result.stderr);
            return 1;
        },
        else => {
            try err.print("error: native build terminated abnormally\n", .{});
            return 1;
        },
    }
}

/// The native backend rejected the generated Zig. Map the first Zig error back
/// to the .ts statement that produced it (via the `__lumen_line = N;` position
/// markers the codegen writes before every statement) and report it as a
/// located diagnostic; fall back to the raw backend message otherwise. Either
/// way this is a compiler bug on valid input, so say so.
fn reportBackendFailure(err: *std.Io.Writer, ts_source: []const u8, ts_path: []const u8, zig_src: []const u8, gen_path: []const u8, stderr_text: []const u8) !void {
    var demangle_buf: [4096]u8 = undefined;
    var it = std.mem.splitScalar(u8, stderr_text, '\n');
    while (it.next()) |line| {
        // Match "<gen_path>:LINE:COL: error: MSG".
        if (!std.mem.startsWith(u8, line, gen_path)) continue;
        const rest = line[gen_path.len..];
        if (rest.len < 2 or rest[0] != ':') continue;
        var p: usize = 1;
        var zline: u32 = 0;
        while (p < rest.len and rest[p] >= '0' and rest[p] <= '9') : (p += 1) zline = zline * 10 + (rest[p] - '0');
        const emark = std.mem.indexOf(u8, rest, " error: ") orelse continue;
        const msg = demangleEmitNames(&demangle_buf, rest[emark + " error: ".len ..]);
        // Last position marker at or before the failing generated line.
        var ts_line: u32 = 0;
        var ts_col: u32 = 1;
        var zit = std.mem.splitScalar(u8, zig_src, '\n');
        var n: u32 = 1;
        while (zit.next()) |zl| : (n += 1) {
            if (n > zline) break;
            if (std.mem.indexOf(u8, zl, "__lumen_line = ")) |mark0| {
                var q = mark0 + "__lumen_line = ".len;
                var lv: u32 = 0;
                while (q < zl.len and zl[q] >= '0' and zl[q] <= '9') : (q += 1) lv = lv * 10 + (zl[q] - '0');
                var cv: u32 = 1;
                if (std.mem.indexOf(u8, zl, "__lumen_col = ")) |mark1| {
                    var r = mark1 + "__lumen_col = ".len;
                    cv = 0;
                    while (r < zl.len and zl[r] >= '0' and zl[r] <= '9') : (r += 1) cv = cv * 10 + (zl[r] - '0');
                }
                ts_line = lv;
                ts_col = cv;
            } else if (std.mem.indexOf(u8, zl, "// __lumen_decl ")) |mark2| {
                // A declaration marker. Emitted as a comment because a
                // signature error has no statement to attach to, and a runtime
                // assignment cannot appear at declaration scope.
                var q = mark2 + "// __lumen_decl ".len;
                var lv: u32 = 0;
                while (q < zl.len and zl[q] >= '0' and zl[q] <= '9') : (q += 1) lv = lv * 10 + (zl[q] - '0');
                var cv: u32 = 1;
                if (q < zl.len and zl[q] == ' ') {
                    q += 1;
                    cv = 0;
                    while (q < zl.len and zl[q] >= '0' and zl[q] <= '9') : (q += 1) cv = cv * 10 + (zl[q] - '0');
                }
                if (lv > 0) {
                    ts_line = lv;
                    ts_col = cv;
                }
            }
        }
        if (ts_line > 0) {
            try printDiag(err, ts_source, ts_path, .{ .line = ts_line, .col = ts_col, .msg = msg });
        } else {
            try err.print("{s}: error: {s}\n", .{ ts_path, msg });
        }
        try err.print("note: the native backend rejected this statement's generated code — likely a Lumen compiler bug; please report it\n", .{});
        return;
    }
    try err.print("error: failed to build native binary for {s}\n", .{ts_path});
    // Surface the first few backend lines so the failure is at least diagnosable.
    var shown: u32 = 0;
    var it2 = std.mem.splitScalar(u8, stderr_text, '\n');
    while (it2.next()) |line| {
        if (line.len == 0) continue;
        try err.print("  backend: {s}\n", .{demangleEmitNames(&demangle_buf, line)});
        shown += 1;
        if (shown >= 4) break;
    }
}

/// Rewrite every internal emit name in a backend message back to its source
/// identifier: `__lumen_7_greeting` -> `greeting`, `__lumen_user_main` ->
/// `main`. The checker mangles every declaration (`Checker.freshEmitName`) so
/// generated code can't collide with the runtime prelude; that spelling is an
/// implementation detail and must never reach a user-facing diagnostic
/// (spec 449). Returns `msg` unchanged if it doesn't fit in `buf`.
fn demangleEmitNames(buf: []u8, msg: []const u8) []const u8 {
    const prefix = "__lumen_";
    var out: usize = 0;
    var i: usize = 0;
    while (i < msg.len) {
        if (std.mem.startsWith(u8, msg[i..], prefix)) {
            var j = i + prefix.len;
            // `__lumen_<digits>_` (declaration mangling) or `__lumen_user_`
            // (prelude-collision rename, spec 246).
            if (std.mem.startsWith(u8, msg[j..], "user_")) {
                j += "user_".len;
            } else {
                const digits = j;
                while (j < msg.len and msg[j] >= '0' and msg[j] <= '9') j += 1;
                if (j == digits or j >= msg.len or msg[j] != '_') {
                    // Not a mangled binding — a runtime global like
                    // `__lumen_line`. Leave it alone.
                    if (out >= buf.len) return msg;
                    buf[out] = msg[i];
                    out += 1;
                    i += 1;
                    continue;
                }
                j += 1;
            }
            const start = j;
            while (j < msg.len and (std.ascii.isAlphanumeric(msg[j]) or msg[j] == '_')) j += 1;
            if (j > start) {
                const name = msg[start..j];
                if (out + name.len > buf.len) return msg;
                @memcpy(buf[out..][0..name.len], name);
                out += name.len;
                i = j;
                continue;
            }
        }
        if (out >= buf.len) return msg;
        buf[out] = msg[i];
        out += 1;
        i += 1;
    }
    return buf[0..out];
}

/// Map a line of the generated Zig back to the .ts line via the
/// `__lumen_line = N;` markers the codegen writes before every statement.
fn tsLineForGenLine(zig_src: []const u8, zline: u32) u32 {
    var ts_line: u32 = 0;
    var zit = std.mem.splitScalar(u8, zig_src, '\n');
    var n: u32 = 1;
    while (zit.next()) |zl| : (n += 1) {
        if (n > zline) break;
        if (std.mem.indexOf(u8, zl, "__lumen_line = ")) |mark0| {
            var q = mark0 + "__lumen_line = ".len;
            var lv: u32 = 0;
            while (q < zl.len and zl[q] >= '0' and zl[q] <= '9') : (q += 1) lv = lv * 10 + (zl[q] - '0');
            ts_line = lv;
        }
    }
    return ts_line;
}

/// Re-renders `zig test` runner output as concise per-test results:
///
///   ✓ adds
///   ✗ fails — expected 4, found 3
///       at main.ts:6
///   1 passed, 1 failed
///
/// Failing expects map to the .ts line through the generated-code position
/// markers. If the output has no test results at all the generated code
/// failed to build — fall back to the backend-failure report.
fn renderTestResults(arena: std.mem.Allocator, err: *std.Io.Writer, ts_source: []const u8, ts_path: []const u8, zig_src: []const u8, gen_path: []const u8, stderr_text: []const u8, term: std.process.Child.Term) !u8 {
    const gen_base = std.fs.path.basename(gen_path);
    var saw_result = false;
    var awaiting_location = false; // last test failed; show its first user frame
    var passed: u32 = 0;
    var failed: u32 = 0;
    var it = std.mem.splitScalar(u8, stderr_text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        // "1/2 <gen>.test.<name>...<status>" — one line per test.
        if (std.mem.indexOf(u8, line, ".test.")) |tpos| {
            if (line.len > 0 and line[0] >= '0' and line[0] <= '9') {
                const after = line[tpos + ".test.".len ..];
                const dots = std.mem.indexOf(u8, after, "...") orelse continue;
                const name = after[0..dots];
                const status = after[dots + 3 ..];
                saw_result = true;
                if (std.mem.eql(u8, status, "OK")) {
                    passed += 1;
                    awaiting_location = false;
                    if (g_color) {
                        try err.print(C_GREEN ++ "✓" ++ C_RESET ++ " {s}\n", .{name});
                    } else {
                        try err.print("ok {s}\n", .{name});
                    }
                } else if (std.mem.eql(u8, status, "SKIP")) {
                    awaiting_location = false;
                } else {
                    failed += 1;
                    awaiting_location = true;
                    // A throw inside a test arrives as a panic; render it the
                    // way runtime errors do ("Uncaught Error: msg"), without
                    // the thread id noise.
                    var msg = status;
                    if (std.mem.startsWith(u8, msg, "thread ")) {
                        if (std.mem.indexOf(u8, msg, " panic: ")) |pp| msg = msg[pp + " panic: ".len ..];
                    }
                    const shown = if (msg.ptr != status.ptr) std.fmt.allocPrint(arena, "Uncaught Error: {s}", .{msg}) catch msg else msg;
                    if (g_color) {
                        try err.print(C_BOLD_RED ++ "✗" ++ C_RESET ++ " {s} — " ++ C_BOLD ++ "{s}" ++ C_RESET ++ "\n", .{ name, shown });
                    } else {
                        try err.print("FAIL {s} — {s}\n", .{ name, shown });
                    }
                }
                continue;
            }
        }
        // First stack frame inside the generated file after a failure: map it
        // to the .ts line the failing statement came from.
        if (awaiting_location) {
            if (std.mem.indexOf(u8, line, gen_base)) |gpos| {
                const rest = line[gpos + gen_base.len ..];
                if (rest.len > 1 and rest[0] == ':' and std.mem.indexOf(u8, line, "lib/std") == null) {
                    var p: usize = 1;
                    var zline: u32 = 0;
                    while (p < rest.len and rest[p] >= '0' and rest[p] <= '9') : (p += 1) zline = zline * 10 + (rest[p] - '0');
                    const ts_line = tsLineForGenLine(zig_src, zline);
                    if (ts_line > 0) {
                        const origin = diagOrigin(ts_path, ts_line);
                        awaiting_location = false;
                        if (g_color) {
                            try err.print(C_DIM ++ "    at " ++ C_RESET ++ C_CYAN ++ "{s}:{d}" ++ C_RESET ++ "\n", .{ origin.file, origin.line });
                        } else {
                            try err.print("    at {s}:{d}\n", .{ origin.file, origin.line });
                        }
                    }
                }
            }
        }
    }
    if (!saw_result) {
        // No tests ran: either the file declares none (exit 0) or the
        // generated code failed to build.
        switch (term) {
            .exited => |code| if (code == 0) {
                try err.print("{s}: no tests\n", .{ts_path});
                return 0;
            },
            else => {},
        }
        try reportBackendFailure(err, ts_source, ts_path, zig_src, gen_path, stderr_text);
        return 1;
    }
    if (failed == 0) {
        if (g_color) {
            try err.print(C_GREEN ++ "{d} passed" ++ C_RESET ++ "\n", .{passed});
        } else {
            try err.print("{d} passed\n", .{passed});
        }
        return 0;
    }
    if (g_color) {
        try err.print("{d} passed, " ++ C_BOLD_RED ++ "{d} failed" ++ C_RESET ++ "\n", .{ passed, failed });
    } else {
        try err.print("{d} passed, {d} failed\n", .{ passed, failed });
    }
    return 1;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const io = init.io;

    var err_buf: [4096]u8 = undefined;
    var err_fw: std.Io.File.Writer = .init(.stderr(), io, &err_buf);
    const err = &err_fw.interface;

    // Color diagnostics when stderr is a terminal, honoring NO_COLOR.
    g_no_gc = init.environ_map.get("LUMEN_NO_GC") != null;
    g_no_local = init.environ_map.get("LUMEN_NO_LOCAL") != null;
    g_explain_imports = init.environ_map.get("LUMEN_EXPLAIN_IMPORTS") != null;
    g_color = blk: {
        if (init.environ_map.get("NO_COLOR") != null) break :blk false;
        break :blk std.Io.File.stderr().isTty(io) catch false;
    };

    if (args.len < 2) {
        try err.writeAll("usage: lumen init [dir]\n       lumen compile [--release-fast] <file.ts>\n       lumen run [--release-fast] <file.ts> [args...]\n       lumen check <file.ts>\n       lumen watch [--no-run] <file.ts>\n       lumen test <file.ts>\n");
        try err.flush();
        std.process.exit(2);
    }

    const usage = "usage: lumen init [dir]\n       lumen compile [--release-fast] [--wasm] [--reactor] [--link <lib>] <file.ts>\n       lumen run [--release-fast] <file.ts> [args...]\n       lumen check <file.ts>\n       lumen watch [--no-run] [--release-fast] <file.ts>\n       lumen test <file.ts>\n";
    const code = if (std.mem.eql(u8, args[1], "init")) blk: {
        if (args.len > 3) {
            try err.writeAll(usage);
            break :blk 2;
        }
        const dir: ?[]const u8 = if (args.len == 3) args[2] else null;
        break :blk try initProject(io, dir, err);
    } else if (std.mem.eql(u8, args[1], "test")) blk: {
        if (args.len < 3) {
            try err.writeAll("usage: lumen test <file.ts>\n");
            break :blk 2;
        }
        break :blk try compileFile(arena, io, args[2], .release_safe, .run_test, &.{}, false, false, err);
    } else if (std.mem.eql(u8, args[1], "check")) blk: {
        // `lumen check <file.ts>`: parse + type-check only (fast feedback for
        // editors and CI); no code is generated or built.
        if (args.len < 3) {
            try err.writeAll("usage: lumen check <file.ts>\n");
            break :blk 2;
        }
        break :blk try compileFile(arena, io, args[2], .release_safe, .check_only, &.{}, false, false, err);
    } else if (std.mem.eql(u8, args[1], "describe")) blk: {
        if (args.len < 3) {
            try err.writeAll("usage: lumen describe <file.ts>\n");
            break :blk 2;
        }
        break :blk try describeFile(arena, io, args[2], err);
    } else if (std.mem.eql(u8, args[1], "watch")) blk: {
        if (args.len < 3) {
            try err.writeAll("usage: lumen watch [--no-run] [--release-fast] <file.ts>\n");
            break :blk 2;
        }
        var mode: CompileMode = .release_safe;
        var run = true;
        var source_arg: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--no-run")) {
                run = false;
            } else if (std.mem.eql(u8, arg, "--release-fast")) {
                mode = .release_fast;
            } else if (std.mem.eql(u8, arg, "--release-safe")) {
                mode = .release_safe;
            } else if (source_arg == null) {
                source_arg = arg;
            } else {
                try err.writeAll("usage: lumen watch [--no-run] [--release-fast] <file.ts>\n");
                break :blk 2;
            }
        }
        break :blk try watchProject(arena, io, source_arg orelse {
            try err.writeAll("usage: lumen watch [--no-run] [--release-fast] <file.ts>\n");
            break :blk 2;
        }, mode, run, err);
    } else if (std.mem.eql(u8, args[1], "run")) blk: {
        // `lumen run <file.ts> [args...]`: compile, then execute the produced
        // binary with inherited stdio, forwarding any trailing arguments.
        if (args.len < 3) {
            try err.writeAll("usage: lumen run [--release-fast] <file.ts> [args...]\n");
            break :blk 2;
        }
        var mode: CompileMode = .release_safe;
        var source_arg: ?[]const u8 = null;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (source_arg == null and std.mem.eql(u8, arg, "--release-fast")) {
                mode = .release_fast;
            } else if (source_arg == null) {
                source_arg = arg;
                i += 1;
                break;
            }
        }
        const src = source_arg orelse {
            try err.writeAll("usage: lumen run [--release-fast] <file.ts> [args...]\n");
            break :blk 2;
        };
        const compile_code = try compileFile(arena, io, src, mode, .build_quiet, &.{}, false, false, err);
        if (compile_code != 0) break :blk compile_code;
        try err.flush();
        // Execute ./<stem> forwarding trailing args.
        const stem = std.fs.path.stem(src);
        const exe_rel = if (@import("builtin").os.tag == .windows)
            try std.fmt.allocPrint(arena, "./{s}.exe", .{stem})
        else
            try std.fmt.allocPrint(arena, "./{s}", .{stem});
        var run_argv: std.ArrayListUnmanaged([]const u8) = .empty;
        try run_argv.append(arena, exe_rel);
        while (i < args.len) : (i += 1) try run_argv.append(arena, args[i]);
        var child = std.process.spawn(io, .{
            .argv = run_argv.items,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch {
            try err.print("error: could not run {s}\n", .{exe_rel});
            break :blk 2;
        };
        const term = child.wait(io) catch {
            try err.print("error: {s} was interrupted\n", .{exe_rel});
            break :blk 2;
        };
        break :blk switch (term) {
            .exited => |c| c,
            else => 1,
        };
    } else if (std.mem.eql(u8, args[1], "compile")) blk: {
        if (args.len < 3) {
            try err.writeAll(usage);
            break :blk 2;
        }
        var mode: CompileMode = .release_safe;
        var source_arg: ?[]const u8 = null;
        var libs: std.ArrayListUnmanaged([]const u8) = .empty;
        var wasm = false;
        var reactor = false;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--release-fast")) {
                mode = .release_fast;
            } else if (std.mem.eql(u8, arg, "--release-safe")) {
                mode = .release_safe;
            } else if (std.mem.eql(u8, arg, "--wasm")) {
                wasm = true;
            } else if (std.mem.eql(u8, arg, "--reactor")) {
                reactor = true;
                wasm = true; // reactor implies the wasm target
            } else if (std.mem.eql(u8, arg, "--link")) {
                i += 1;
                if (i >= args.len) {
                    try err.writeAll(usage);
                    break :blk 2;
                }
                try libs.append(arena, args[i]);
            } else if (source_arg == null) {
                source_arg = arg;
            } else {
                try err.writeAll(usage);
                break :blk 2;
            }
        }
        break :blk try compileFile(arena, io, source_arg orelse {
            try err.writeAll(usage);
            break :blk 2;
        }, mode, .build_exe, libs.items, wasm, reactor, err);
    } else if (std.mem.eql(u8, args[1], "version") or std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-v")) blk: {
        try err.print("lumen {s}\n", .{lumen_version});
        break :blk 0;
    } else if (std.mem.eql(u8, args[1], "help") or std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")) blk: {
        try err.writeAll(usage);
        break :blk 0;
    } else if (std.mem.endsWith(u8, args[1], ".ts")) blk: {
        // `lumen file.ts` is shorthand for `lumen compile file.ts`.
        break :blk try compileFile(arena, io, args[1], .release_safe, .build_exe, &.{}, false, false, err);
    } else blk: {
        try err.print("error: unknown command '{s}'\n\n", .{args[1]});
        try err.writeAll(usage);
        break :blk 2;
    };

    try err.flush();
    if (code != 0) std.process.exit(code);
}

test "backend diagnostics never leak internal emit names (spec 449)" {
    var buf: [256]u8 = undefined;
    const eq = std.testing.expectEqualStrings;
    try eq("use of undeclared identifier 'greeting'", demangleEmitNames(&buf, "use of undeclared identifier '__lumen_0_greeting'"));
    try eq("expected 'int', found 'string' in 'n' and 'g'", demangleEmitNames(&buf, "expected 'int', found 'string' in '__lumen_12_n' and '__lumen_3_g'"));
    // Prelude-collision renames (spec 246) demangle too.
    try eq("'main' redeclared", demangleEmitNames(&buf, "'__lumen_user_main' redeclared"));
    // Generated runtime globals are not declaration mangling — left alone.
    try eq("unused '__lumen_line'", demangleEmitNames(&buf, "unused '__lumen_line'"));
    try eq("bare __lumen_", demangleEmitNames(&buf, "bare __lumen_"));
    try eq("no mangled names here", demangleEmitNames(&buf, "no mangled names here"));
    // Too long to rewrite: returned verbatim rather than truncated.
    var small: [4]u8 = undefined;
    try eq("use of '__lumen_0_x'", demangleEmitNames(&small, "use of '__lumen_0_x'"));
}

test "import rewriting leaves member and key positions alone (spec 451)" {
    const arena = std.testing.allocator;
    const renames = [_]NamedBinding{.{ .name = "hello", .alias = "greet" }};
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        // A plain reference is rewritten.
        .{ .in = "let s = hello(name);", .want = "let s = greet(name);" },
        // Member access, optional access and record/object keys are not.
        .{ .in = "let s = box.hello;", .want = "let s = box.hello;" },
        .{ .in = "let s = box?.hello;", .want = "let s = box?.hello;" },
        .{ .in = "return { hello: 1, n: 2 };", .want = "return { hello: 1, n: 2 };" },
        .{ .in = "type Box = { hello: string };", .want = "type Box = { hello: string };" },
        .{ .in = "  hello: string,", .want = "  hello: string," },
        // A spread operand is a reference, not a member.
        .{ .in = "f(...hello);", .want = "f(...greet);" },
        // `${…}` holds an expression, so it is rewritten; the rest of the
        // template literal is not.
        .{ .in = "console.log(`hello ${hello(a)}`);", .want = "console.log(`hello ${greet(a)}`);" },
        .{ .in = "let s = `a ${ { hello: hello(x) } } b hello`;", .want = "let s = `a ${ { hello: greet(x) } } b hello`;" },
        // Strings and line comments are untouched.
        .{ .in = "let s = \"hello\"; // hello", .want = "let s = \"hello\"; // hello" },
    };
    for (cases) |c| {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(arena);
        try appendTransformed(arena, &out, c.in, &.{}, &renames);
        try std.testing.expectEqualStrings(c.want, out.items);
    }
}

test "namespace members still follow a renamed declaration (spec 451)" {
    const arena = std.testing.allocator;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(arena);
    const renames = [_]NamedBinding{.{ .name = "area", .alias = "area__m1" }};
    try appendTransformed(arena, &out, "console.log(geom.area(s));", &.{"geom"}, &renames);
    try std.testing.expectEqualStrings("console.log(area__m1(s));", out.items);
}

test "module keys canonicalise URL spellings (spec 451)" {
    var buf: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer buf.deinit();
    const arena = buf.allocator();
    const eq = std.testing.expectEqualStrings;
    const want = "https://lumen-lang.org/pkg/a.ts";
    for ([_][]const u8{
        "https://lumen-lang.org/pkg/a.ts",
        "https://LUMEN-LANG.ORG/pkg/a.ts",
        "https://lumen-lang.org:443/pkg/a.ts",
        "https://lumen-lang.org//pkg/./a.ts",
        "https://lumen-lang.org/pkg/sub/../a.ts",
    }) |spec| try eq(want, try canonicalModuleKey(arena, spec));
    // A trailing slash is dropped, and the path stays case-sensitive.
    try eq("https://lumen-lang.org/Pkg", try canonicalModuleKey(arena, "https://lumen-lang.org/Pkg/"));
}

test "top-level declarations are found, nested ones are not (spec 451)" {
    const arena = std.testing.allocator;
    var decls: std.ArrayListUnmanaged(TopDecl) = .empty;
    defer decls.deinit(arena);
    try scanTopLevelDecls(arena,
        \\import { a } from "./x.ts";
        \\export type Point = { x: int, y: int };
        \\type Inner = string;
        \\export function origin(): Point {
        \\  const nested = 1;
        \\  return { x: 0, y: 0 };
        \\}
        \\export default function base(): int { return 1; }
        \\export const ANSWER: int = 42;
    , &decls);
    const want = [_]struct { name: []const u8, kind: DeclKind, exported: bool }{
        .{ .name = "Point", .kind = .type_name, .exported = true },
        .{ .name = "Inner", .kind = .type_name, .exported = false },
        .{ .name = "origin", .kind = .value, .exported = true },
        .{ .name = "base", .kind = .value, .exported = false },
        .{ .name = "ANSWER", .kind = .value, .exported = true },
    };
    try std.testing.expectEqual(want.len, decls.items.len);
    for (want, decls.items) |w, got| {
        try std.testing.expectEqualStrings(w.name, got.name);
        try std.testing.expectEqual(w.kind, got.kind);
        try std.testing.expectEqual(w.exported, got.exported);
    }
    try std.testing.expect(decls.items[3].is_default);
}

test "exported declaration names stop at a generic parameter list (spec 451)" {
    const eq = std.testing.expectEqualStrings;
    const cases = [_]struct { line: []const u8, name: []const u8, decl: []const u8 }{
        .{ .line = "export type Point = { x: int };", .name = "Point", .decl = "type Point = { x: int };" },
        .{ .line = "export type Box<T> = { v: T };", .name = "Box", .decl = "type Box<T> = { v: T };" },
        .{ .line = "export type Rec = {", .name = "Rec", .decl = "type Rec = {" },
        .{ .line = "export function identity<T>(x: T): T {", .name = "identity", .decl = "function identity<T>(x: T): T {" },
        .{ .line = "export const ANSWER: int = 42;", .name = "ANSWER", .decl = "const ANSWER: int = 42;" },
        .{ .line = "export let count = 0;", .name = "count", .decl = "let count = 0;" },
        // Multi-line forms (spec 482). Only the opening line reaches here; the
        // body flows through the line-oriented pass untouched.
        .{ .line = "export class BannerApi {", .name = "BannerApi", .decl = "class BannerApi {" },
        .{ .line = "export class Counter<T> {", .name = "Counter", .decl = "class Counter<T> {" },
        // No space before the body, which is why `{` ends a name.
        .{ .line = "export class Tight{", .name = "Tight", .decl = "class Tight{" },
        .{ .line = "export interface Named {", .name = "Named", .decl = "interface Named {" },
        .{ .line = "export enum Colour {", .name = "Colour", .decl = "enum Colour {" },
    };
    for (cases) |c| {
        const got = parseNamedExportDecl(c.line) orelse return error.TestExpectedEqual;
        try eq(c.name, got.name);
        try eq(c.decl, got.decl);
    }
    // Not declaration-bearing export forms.
    try std.testing.expect(parseNamedExportDecl("export { a, b };") == null);
    try std.testing.expect(parseNamedExportDecl("type Point = { x: int };") == null);
    try std.testing.expect(parseNamedExportDecl("class Local {") == null);
}

test "embed( inside a string, comment, template or regex is text, not a call (spec 458)" {
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    // Each source names a file that does not exist: if the scan mistook the
    // text for a call it would fail to read it, so passing through unchanged is
    // the whole assertion.
    const untouched = [_][]const u8{
        "let s = \"embed(\\\"x\\\")\";",
        "let s = 'embed(\"x\")';",
        "// embed(\"x\")",
        "/* embed(\"x\")\n   embedDir(\"y\") */",
        "let s = `embed(\"x\")`;",
        "let s = `a ${ b } embed(\"x\")`;",
        // A regex body may hold an unbalanced quote; the scan must not read it
        // as the start of a string and swallow the rest of the file.
        "let t = s.replace(/'/g, \"\"); let u = \"embed(\\\"x\\\")\";",
        // A member or a declaration of that name is not the compile-time form.
        "let s = box.embed(\"x\");",
        "function embed(p: string): string { return p; }",
    };
    for (untouched) |src| {
        var diag: compiler.Diag = .{};
        const out = try expandEmbeds(arena, std.testing.io, src, &diag);
        try std.testing.expectEqualStrings(src, out);
    }
}

test "embed rejects an argument that is not a literal (spec 458)" {
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var diag: compiler.Diag = .{};
    const src = "const text: string = embed(p);";
    try std.testing.expectError(error.EmbedFailed, expandEmbeds(arena, std.testing.io, src, &diag));
    try std.testing.expectEqual(@as(u32, 1), diag.line);
    try std.testing.expectEqual(@as(u32, 22), diag.col);
    try std.testing.expect(std.mem.indexOf(u8, diag.msg, "[E_EMBED]") != null);
    try std.testing.expect(std.mem.indexOf(u8, diag.msg, "must be a literal") != null);
}

test "embedding escapes what would not survive as a literal (spec 458)" {
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try appendLumenStrLit(arena, &out, "a\"b\\c\nd\te\r\x00f\x1bg");
    // A control byte the lexer has no escape for is copied raw: the literal's
    // bytes stay raw until codegen escapes them again for the backend.
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\te\\r\\0f\x1bg\"", out.items);
}

/// Builds a temporary directory of `.sql` files, runs a one-line program
/// through the substitution against it, and returns the rewritten source.
fn embedTestSource(arena: std.mem.Allocator, tmp: *std.testing.TmpDir, src: []const u8, diag: *compiler.Diag) ![]const u8 {
    const io = std.testing.io;
    // Written out of order on purpose: readdir hands back creation order on
    // most filesystems, which is exactly what the sort has to survive.
    try tmp.dir.writeFile(io, .{ .sub_path = "c.sql", .data = "SELECT \"c\";\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "a.sql", .data = "CREATE a\\b;\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b.sql", .data = "" });
    try tmp.dir.createDirPath(io, "nested");
    try tmp.dir.writeFile(io, .{ .sub_path = "nested/z.sql", .data = "skipped\n" });

    // The line map is how a path resolves against the file that wrote the call,
    // so the fake origin puts the (single-line) program inside the temp dir.
    const origin = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/main.ts", .{tmp.sub_path});
    const map = [_]LineOrigin{.{ .file = origin, .line = 1 }};
    g_line_map = &map;
    defer g_line_map = &.{};
    return expandEmbeds(arena, io, src, diag);
}

test "embedDir lists regular files sorted by name (spec 458)" {
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: compiler.Diag = .{};
    const out = try embedTestSource(arena, &tmp, "let f: F[] = embedDir(\".\");", &diag);
    // Sorted by name whatever order the filesystem reports; `nested/` is not a
    // regular file so it is skipped; contents round-trip through the escaping.
    try std.testing.expectEqualStrings(
        "let f: F[] = [{ name: \"a.sql\", text: \"CREATE a\\\\b;\\n\" }, " ++
            "{ name: \"b.sql\", text: \"\" }, " ++
            "{ name: \"c.sql\", text: \"SELECT \\\"c\\\";\\n\" }];",
        out,
    );
}

test "embed resolves against the file that wrote it (spec 458)" {
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: compiler.Diag = .{};
    const out = try embedTestSource(arena, &tmp, "let s = embed(\"./a.sql\");", &diag);
    try std.testing.expectEqualStrings("let s = \"CREATE a\\\\b;\\n\";", out);
}

test "a missing embed target is a diagnostic naming the path (spec 458)" {
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var diag: compiler.Diag = .{};
    try std.testing.expectError(error.EmbedFailed, embedTestSource(arena, &tmp, "let s = embed(\"./gone.sql\");", &diag));
    try std.testing.expectEqualStrings("cannot embed \"./gone.sql\": no such file [E_EMBED]", diag.msg);
    try std.testing.expectEqual(@as(u32, 9), diag.col);

    diag = .{};
    try std.testing.expectError(error.EmbedFailed, embedTestSource(arena, &tmp, "let f = embedDir(\"./gone\");", &diag));
    try std.testing.expectEqualStrings("cannot embed \"./gone\": no such file [E_EMBED]", diag.msg);
}

test "a package open on disk resolves a URL to the working tree, and one file reached twice is one checkout (spec 486)" {
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "repo/packages/validation");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/packages/validation/validation.ts", .data = "export function validated() {}" });

    const start = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/repo", .{tmp.sub_path});
    const got = try openCheckoutFor(arena, io, "https://lumen-lang.org/package/std-contrib/validation/validation.ts", start);
    try std.testing.expect(got != null);
    try std.testing.expect(std.mem.endsWith(u8, got.?, "packages/validation/validation.ts"));
}

test "two checkouts offering one package is a refusal that names both (spec 486)" {
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "repo/packages/plume");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/packages/plume/plume.ts", .data = "export function q() {}" });
    try tmp.dir.createDirPath(io, "other/packages/plume");
    try tmp.dir.writeFile(io, .{ .sub_path = "other/packages/plume/plume.ts", .data = "export function q() {}" });

    const start = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/repo", .{tmp.sub_path});
    g_import_detail = null;
    try std.testing.expectError(error.AmbiguousPackage, openCheckoutFor(arena, io, "https://lumen-lang.org/package/std-contrib/plume/plume.ts", start));
    const said = g_import_detail orelse return error.TestExpectedDetail;
    try std.testing.expect(std.mem.indexOf(u8, said, "repo/packages/plume/plume.ts") != null);
    try std.testing.expect(std.mem.indexOf(u8, said, "other/packages/plume/plume.ts") != null);
    g_import_detail = null;
}

test "a URL a checkout does not provide is left to be fetched (spec 486)" {
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "repo/packages/validation");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/packages/validation/validation.ts", .data = "export function validated() {}" });

    const start = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/repo", .{tmp.sub_path});
    const got = try openCheckoutFor(arena, io, "https://example.com/package/someone/elsewhere/thing.ts", start);
    try std.testing.expect(got == null);
}

test "a kept copy sits at a path that maps back to the URL it came from (spec 486)" {
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    const url = "https://lumen-lang.org/package/std-contrib/validation/validation.ts";
    const kept = try packagePathFor(arena, url);
    try std.testing.expectEqualStrings(".lumen-packages/lumen-lang.org/package/std-contrib/validation/validation.ts", kept);
    const back = urlForPackagePath(arena, kept) orelse return error.TestExpectedUrl;
    try std.testing.expectEqualStrings(url, back);

    const nested = try packagePathFor(arena, "https://example.com/one.ts");
    try std.testing.expectEqualStrings(".lumen-packages/example.com/one.ts", nested);
}

test "a URL that is not https, names no file, or climbs out of the cache is refused (spec 486)" {
    var scratch: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

    try std.testing.expectError(error.InvalidImport, packagePathFor(arena, "http://lumen-lang.org/a.ts"));
    try std.testing.expectError(error.InvalidImport, packagePathFor(arena, "https://lumen-lang.org"));
    try std.testing.expectError(error.InvalidImport, packagePathFor(arena, "https://lumen-lang.org/../../etc/passwd"));
}
