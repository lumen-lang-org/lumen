//! `lumen describe <file.ts>` -- the decorator description protocol (spec 455).
//!
//! Writes one JSON object per decorator application, in source order, one per
//! line. The object is exactly what a decorator will be handed once decorators
//! run (slice 2), so the format is exercised before anything depends on it.
//!
//! A description is syntax, not types: the file is parsed alone (no imports, no
//! checking) and every `type` is the annotation as written. A decorator that
//! cares about `string[]` versus `string` reads the text.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const diag_mod = @import("lumen_diag.zig");
const parser_mod = @import("lumen_parser.zig");

/// Bumped when the shape below changes, so a decorator can refuse a version it
/// does not know.
pub const protocol = 1;

/// One decorator written on one declaration: the description it will be handed,
/// plus the two positions the compiler needs — the decorator's own line, which
/// every failure of it is reported at, and the declaration's, which decides
/// where the constant it produces lands (spec 455 D4).
pub const Application = struct {
    name: []const u8,
    target: []const u8,
    json: []const u8,
    line: u32,
    col: u32,
    decl_line: u32,
};

/// Every decorator application in one file, in source order.
pub fn collect(
    arena: std.mem.Allocator,
    source: []const u8,
    file: []const u8,
    diag: *diag_mod.Diag,
) ![]const Application {
    const program = try parseAlone(arena, source, diag);
    var apps: std.ArrayListUnmanaged(Application) = .empty;
    for (program.stmts) |stmt| switch (stmt) {
        .class_decl => |c| for (c.decorators) |d| {
            var out: std.Io.Writer.Allocating = .init(arena);
            try writeClass(&out.writer, file, c, d);
            try apps.append(arena, .{
                .name = d.name,
                .target = c.name,
                .json = std.mem.trimEnd(u8, out.written(), "\n"),
                .line = d.line,
                .col = d.col,
                .decl_line = c.line,
            });
        },
        .function_decl => |f| for (f.decorators) |d| {
            var out: std.Io.Writer.Allocating = .init(arena);
            try writeFunction(&out.writer, file, f, d);
            try apps.append(arena, .{
                .name = d.name,
                .target = f.name,
                .json = std.mem.trimEnd(u8, out.written(), "\n"),
                .line = d.line,
                .col = d.col,
                .decl_line = f.line,
            });
        },
        else => {},
    };
    return apps.items;
}

/// Parses one module on its own: module syntax dropped, nothing checked, no
/// imports followed. The description is syntax, and so is everything read off a
/// decorator's own module — its signature and the `Description` type it must
/// export (spec 455 D3).
pub fn parseAlone(arena: std.mem.Allocator, source: []const u8, diag: *diag_mod.Diag) !ast.Program {
    const text = try stripModuleSyntax(arena, source);
    var p = try parser_mod.Parser.init(arena, text);
    return p.parseProgram() catch |e| {
        diag.* = .{ .line = p.cur_line, .col = p.cur_col, .msg = p.last_err };
        return e;
    };
}

pub fn describeSource(
    arena: std.mem.Allocator,
    source: []const u8,
    file: []const u8,
    out: *std.Io.Writer,
    diag: *diag_mod.Diag,
) !void {
    for (try collect(arena, source, file, diag)) |app| {
        try out.writeAll(app.json);
        try out.writeByte('\n');
    }
}

fn writeClass(out: *std.Io.Writer, file: []const u8, c: ast.ClassDecl, d: ast.Decorator) !void {
    try writeHead(out, "class", c.name, file, c.line, d);
    try out.writeAll(",\"fields\":[");
    for (c.fields, 0..) |f, i| {
        if (i > 0) try out.writeByte(',');
        try out.writeAll("{\"name\":");
        try writeString(out, f.name);
        try out.writeAll(",\"type\":");
        try writeString(out, f.annotation);
        try out.writeAll(",\"decorators\":");
        try writeDecorators(out, f.decorators);
        try out.writeByte('}');
    }
    // A method is described exactly as a decorated free function is (spec 459),
    // so a class decorator that turns methods into routes reads one shape, not
    // two. Always present, empty for a class with no methods.
    try out.writeAll("],\"methods\":[");
    for (c.methods, 0..) |m, i| {
        if (i > 0) try out.writeByte(',');
        try out.writeAll("{\"name\":");
        try writeString(out, m.name);
        try out.writeAll(",\"returns\":");
        try writeReturns(out, m);
        try out.writeAll(",\"params\":");
        try writeParams(out, m.params);
        try out.writeAll(",\"decorators\":");
        try writeDecorators(out, m.decorators);
        try out.writeByte('}');
    }
    try out.writeAll("]}\n");
}

fn writeFunction(out: *std.Io.Writer, file: []const u8, f: ast.FunctionDecl, d: ast.Decorator) !void {
    try writeHead(out, "function", f.name, file, f.line, d);
    try out.writeAll(",\"params\":");
    try writeParams(out, f.params);
    try out.writeAll(",\"returns\":");
    try writeReturns(out, f);
    try out.writeAll("}\n");
}

fn writeParams(out: *std.Io.Writer, params: []const ast.FunctionParam) !void {
    try out.writeByte('[');
    for (params, 0..) |p, i| {
        if (i > 0) try out.writeByte(',');
        try out.writeAll("{\"name\":");
        try writeString(out, p.name);
        try out.writeAll(",\"type\":");
        try writeString(out, p.annotation);
        try out.writeAll(",\"decorators\":");
        try writeDecorators(out, p.decorators);
        try out.writeByte('}');
    }
    try out.writeByte(']');
}

/// An omitted return type is inferred from the body, which has not been checked
/// here — the description reports what the source says, so nothing.
fn writeReturns(out: *std.Io.Writer, f: ast.FunctionDecl) !void {
    try writeString(out, if (f.infer_return) "" else f.return_annotation);
}

fn writeHead(out: *std.Io.Writer, kind: []const u8, name: []const u8, file: []const u8, line: u32, d: ast.Decorator) !void {
    try out.print("{{\"protocol\":{d},\"kind\":\"{s}\",\"name\":", .{ protocol, kind });
    try writeString(out, name);
    try out.writeAll(",\"args\":");
    try writeArgs(out, d.args);
    try out.writeAll(",\"argsText\":");
    try writeArgsText(out, d.args);
    try out.writeAll(",\"file\":");
    try writeString(out, file);
    try out.print(",\"line\":{d}", .{line});
}

fn writeDecorators(out: *std.Io.Writer, decorators: []const ast.Decorator) !void {
    try out.writeByte('[');
    for (decorators, 0..) |d, i| {
        if (i > 0) try out.writeByte(',');
        try out.writeAll("{\"name\":");
        try writeString(out, d.name);
        try out.writeAll(",\"args\":");
        try writeArgs(out, d.args);
        try out.writeAll(",\"argsText\":");
        try writeArgsText(out, d.args);
        try out.writeByte('}');
    }
    try out.writeByte(']');
}

/// The same arguments as text, so a decorator's `Description` can receive them.
/// `args` is heterogeneous — `@maxLength(200, "too long")` is an int beside a
/// string — and a Lumen array is homogeneous, so no `Description` can declare a
/// type for it. `argsText` is every argument spelled as a string, which one
/// `string[]` field does receive; a decorator parses back whatever it needs.
fn writeArgsText(out: *std.Io.Writer, args: []const ast.DecoratorArg) !void {
    try out.writeByte('[');
    for (args, 0..) |a, i| {
        if (i > 0) try out.writeByte(',');
        switch (a) {
            .str => |v| try writeString(out, v),
            .ident => |v| try writeString(out, v),
            .int => |v| {
                var buf: [32]u8 = undefined;
                try writeString(out, std.fmt.bufPrint(&buf, "{d}", .{v}) catch "0");
            },
            .flt => |v| {
                var buf: [64]u8 = undefined;
                try writeString(out, std.fmt.bufPrint(&buf, "{d}", .{v}) catch "0");
            },
            .boolean => |v| try writeString(out, if (v) "true" else "false"),
        }
    }
    try out.writeByte(']');
}

fn writeArgs(out: *std.Io.Writer, args: []const ast.DecoratorArg) !void {
    try out.writeByte('[');
    for (args, 0..) |a, i| {
        if (i > 0) try out.writeByte(',');
        switch (a) {
            .str => |s| try writeString(out, s),
            .ident => |v| try writeString(out, v),
            .int => |v| try out.print("{d}", .{v}),
            .flt => |v| try out.print("{d}", .{v}),
            .boolean => |v| try out.writeAll(if (v) "true" else "false"),
        }
    }
    try out.writeByte(']');
}

/// Writes source text as a JSON string. String literals reach the AST raw
/// (escapes and all), so the TypeScript escapes JSON does not share are decoded
/// on the way out and the rest is re-escaped.
fn writeString(out: *std.Io.Writer, raw: []const u8) !void {
    try out.writeByte('"');
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        var c = raw[i];
        if (c == '\\' and i + 1 < raw.len) {
            i += 1;
            // `\uXXXX` is spelled the same in both, so it passes through whole.
            if (raw[i] == 'u') {
                try out.writeAll("\\u");
                continue;
            }
            c = switch (raw[i]) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                '0' => 0,
                else => raw[i],
            };
        }
        switch (c) {
            '"' => try out.writeAll("\\\""),
            '\\' => try out.writeAll("\\\\"),
            '\n' => try out.writeAll("\\n"),
            '\r' => try out.writeAll("\\r"),
            '\t' => try out.writeAll("\\t"),
            else => if (c < 0x20) try out.print("\\u{x:0>4}", .{c}) else try out.writeByte(c),
        }
    }
    try out.writeByte('"');
}

/// Drops the module syntax the parser never sees -- `import` lines and the
/// `export` keyword -- so one file can be parsed on its own. Every line keeps
/// its position, so a description's `line` is the line the user wrote.
fn stripModuleSyntax(arena: std.mem.Allocator, source: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const keep = blk: {
            if (std.mem.startsWith(u8, trimmed, "import ")) break :blk "";
            if (std.mem.startsWith(u8, trimmed, "export {")) break :blk "";
            if (std.mem.startsWith(u8, trimmed, "export *")) break :blk "";
            if (std.mem.startsWith(u8, trimmed, "export default ")) {
                break :blk try std.mem.concat(arena, u8, &.{ line[0..std.mem.indexOf(u8, line, "export default ").?], trimmed["export default ".len..] });
            }
            if (std.mem.startsWith(u8, trimmed, "export ")) {
                break :blk try std.mem.concat(arena, u8, &.{ line[0..std.mem.indexOf(u8, line, "export ").?], trimmed["export ".len..] });
            }
            break :blk line;
        };
        try out.appendSlice(arena, keep);
        try out.append(arena, '\n');
    }
    return out.items;
}

test "a decorated class describes its fields and their decorators (spec 455)" {
    var buf: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer buf.deinit();
    const arena = buf.allocator();
    const src =
        \\import { entity } from "./tools/entity.ts";
        \\
        \\@entity("agents", 2, true)
        \\export class Agent {
        \\  @id @column("id", "text")
        \\  id: string;
        \\  @column("agent_name", "text")
        \\  agentName: string;
        \\  steps: int[];
        \\}
        \\
    ;
    var out: std.Io.Writer.Allocating = .init(arena);
    var diag: diag_mod.Diag = .{};
    try describeSource(arena, src, "agent.ts", &out.writer, &diag);
    try std.testing.expectEqualStrings(
        \\{"protocol":1,"kind":"class","name":"Agent","args":["agents",2,true],"argsText":["agents","2","true"],"file":"agent.ts","line":4,"fields":[{"name":"id","type":"string","decorators":[{"name":"id","args":[],"argsText":[]},{"name":"column","args":["id","text"],"argsText":["id","text"]}]},{"name":"agentName","type":"string","decorators":[{"name":"column","args":["agent_name","text"],"argsText":["agent_name","text"]}]},{"name":"steps","type":"int[]","decorators":[]}],"methods":[]}
        \\
    , out.written());
}

test "a decorated class describes its methods, their params and decorators (spec 459)" {
    var buf: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer buf.deinit();
    const arena = buf.allocator();
    const src =
        \\@controller("/agents")
        \\class AgentApi {
        \\  @get("/:id")
        \\  find(@param("the id") id: string): string { return id; }
        \\  count(): int { return 1; }
        \\}
        \\
    ;
    var out: std.Io.Writer.Allocating = .init(arena);
    var diag: diag_mod.Diag = .{};
    try describeSource(arena, src, "api.ts", &out.writer, &diag);
    try std.testing.expectEqualStrings(
        \\{"protocol":1,"kind":"class","name":"AgentApi","args":["/agents"],"argsText":["/agents"],"file":"api.ts","line":2,"fields":[],"methods":[{"name":"find","returns":"string","params":[{"name":"id","type":"string","decorators":[{"name":"param","args":["the id"],"argsText":["the id"]}]}],"decorators":[{"name":"get","args":["/:id"],"argsText":["/:id"]}]},{"name":"count","returns":"int","params":[],"decorators":[]}]}
        \\
    , out.written());
}

test "a decorated function describes its parameters and return type (spec 455)" {
    var buf: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer buf.deinit();
    const arena = buf.allocator();
    const src =
        \\@tool("search")
        \\function search(@describe("what to look for") q: string, limit: int): string[] {
        \\  return [q];
        \\}
        \\
    ;
    var out: std.Io.Writer.Allocating = .init(arena);
    var diag: diag_mod.Diag = .{};
    try describeSource(arena, src, "tool.ts", &out.writer, &diag);
    try std.testing.expectEqualStrings(
        \\{"protocol":1,"kind":"function","name":"search","args":["search"],"argsText":["search"],"file":"tool.ts","line":2,"params":[{"name":"q","type":"string","decorators":[{"name":"describe","args":["what to look for"],"argsText":["what to look for"]}]},{"name":"limit","type":"int","decorators":[]}],"returns":"string[]"}
        \\
    , out.written());
}

test "an undecorated program describes nothing (spec 455)" {
    var buf: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer buf.deinit();
    const arena = buf.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    var diag: diag_mod.Diag = .{};
    try describeSource(arena, "class Plain { x: int; }\nfunction f(): int { return 1; }\n", "plain.ts", &out.writer, &diag);
    try std.testing.expectEqualStrings("", out.written());
}

test "two decorators on one declaration describe once each, in source order (spec 455)" {
    var buf: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer buf.deinit();
    const arena = buf.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    var diag: diag_mod.Diag = .{};
    try describeSource(arena, "@first @second(1.5)\nclass C { x: int; }\n", "c.ts", &out.writer, &diag);
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out.written(), "\n"), '\n');
    try std.testing.expect(std.mem.indexOf(u8, it.next().?, "\"args\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, it.next().?, "\"args\":[1.5]") != null);
    try std.testing.expect(it.next() == null);
}

test "a decorator argument that is not a literal is refused (spec 455)" {
    var buf: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer buf.deinit();
    const arena = buf.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    var diag: diag_mod.Diag = .{};
    // An expression is still not metadata: a call and arithmetic are refused.
    for ([_][]const u8{
        "@entity(name())\nclass A { x: int; }\n",
        "@entity(1 + 2)\nclass A { x: int; }\n",
    }) |src| {
        try std.testing.expectError(error.ParseError, describeSource(arena, src, "a.ts", &out.writer, &diag));
        try std.testing.expectEqualStrings("E_DECORATOR_ARG", diag.msg);
    }
    // A bare name is a reference, not an expression — `@Guard(needsPg)`. It
    // travels to the decorator as its name, exactly as the quoted form did.
    for ([_][]const u8{
        "@entity(TABLE)\nclass A { x: int; }\n",
        "class A {\n  @column(col)\n  x: int;\n}\n",
    }) |src| {
        var one: std.Io.Writer.Allocating = .init(arena);
        try describeSource(arena, src, "a.ts", &one.writer, &diag);
    }
}

test "a decorator on something that is not a declaration is refused (spec 455)" {
    var buf: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer buf.deinit();
    const arena = buf.allocator();
    var out: std.Io.Writer.Allocating = .init(arena);
    var diag: diag_mod.Diag = .{};
    for ([_][]const u8{
        "@entity(\"a\")\nlet x = 1;\n",
        "@entity(\"a\")\ntype T = { x: int };\n",
        "class A {\n  @entity(\"a\")\n  constructor() {}\n}\n",
    }) |src| {
        try std.testing.expectError(error.ParseError, describeSource(arena, src, "a.ts", &out.writer, &diag));
        try std.testing.expectEqualStrings("E_DECORATOR_TARGET", diag.msg);
    }
}
