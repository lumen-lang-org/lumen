//! Running a decorator (spec 455 slice 2): the protocol, without the plumbing.
//!
//! A decorator is an imported function the compiler calls while compiling. It
//! receives the description of the declaration it was written on and returns a
//! value, which the compiler emits as a constant beside that declaration. This
//! file holds the parts of that exchange that are pure — the signature the
//! bound function must have, the entry point generated to call it, the name of
//! the constant, and the value's translation from JSON to a Lumen literal.
//!
//! The parts that are not pure — writing the entry point, compiling the module,
//! running the binary — live in `lumen.zig`, next to the import resolution they
//! depend on.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const describe = @import("lumen_describe.zig");
const diag_mod = @import("lumen_diag.zig");
const check_stdlib = @import("lumen_check_stdlib.zig");
const types = @import("lumen_types.zig");

/// A decorator that could not run, reported at the decorator's own line in the
/// file that wrote it — never at a line of the generated entry point, and never
/// at a line of the decorator's module unless the module is what failed.
pub const Failure = struct {
    line: u32,
    col: u32,
    msg: []const u8,
};

/// The constant one decorator produced. `decl_line` is the line the decorated
/// declaration starts on: the constant is emitted once that declaration has
/// closed, so everything written after it can use the constant and the value is
/// assigned before any of it runs.
pub const Generated = struct {
    decl_line: u32,
    text: []const u8,
};

/// What the compiler reads off a decorator's own module.
pub const Signature = struct {
    /// The declared return type, which becomes the generated constant's type.
    returns: []const u8,
    /// The description this decorator is handed, narrowed to the keys its own
    /// `Description` type declares (see `narrow`).
    description: []const u8,
};

/// The one parameter type a decorator takes, and the type its module must
/// export for the generated entry point to parse the description into.
pub const description_type = "Description";

/// Checks the bound function against the decorator signature and reports what
/// it should have been when it does not match. The module is read as syntax:
/// the decorator has not been compiled yet, and its return type is a name the
/// program being compiled has to have in scope anyway.
pub fn signature(
    arena: std.mem.Allocator,
    module_source: []const u8,
    module_path: []const u8,
    exported: []const u8,
    app: describe.Application,
    fail: *Failure,
) !Signature {
    var diag: diag_mod.Diag = .{};
    const program = describe.parseAlone(arena, module_source, &diag) catch {
        fail.* = .{ .line = app.line, .col = app.col, .msg = try std.fmt.allocPrint(
            arena,
            "the decorator module {s} does not parse: {s} at line {d}",
            .{ module_path, diag.msg, diag.line },
        ) };
        return error.DecoratorFailed;
    };

    var has_description = false;
    var found: ?ast.FunctionDecl = null;
    for (program.stmts) |stmt| switch (stmt) {
        .type_decl => |t| {
            if (std.mem.eql(u8, t.name, description_type)) has_description = true;
        },
        .function_decl => |f| {
            if (std.mem.eql(u8, f.name, exported)) found = f;
        },
        else => {},
    };

    const f = found orelse return expected(arena, app, module_path, exported, "it declares no such function", fail);
    if (f.params.len != 1 or !std.mem.eql(u8, f.params[0].annotation, description_type))
        return expected(arena, app, module_path, exported, "a decorator takes one description and nothing else", fail);
    if (f.infer_return)
        return expected(arena, app, module_path, exported, "a decorator declares its return type — the constant the compiler emits has it", fail);
    if (!carriesAsJson(f.return_annotation))
        return expected(arena, app, module_path, exported, try std.fmt.allocPrint(
            arena,
            "'{s}' is not a type JSON can carry, and the value travels back as JSON — return a record, a class, an array of either, or a scalar",
            .{f.return_annotation},
        ), fail);
    // The entry point parses the description into the module's own
    // `Description`; until the compiler provides that type, the module declares
    // it, and this is where saying so belongs rather than in a parse error
    // inside generated source.
    if (!has_description)
        return expected(arena, app, module_path, exported, "its module must also export `type Description` for the description to be parsed into", fail);

    return .{ .returns = f.return_annotation, .description = try narrow(arena, program, app.json) };
}

/// The description narrowed to what this decorator's own `Description` type
/// asks for: every key that type does not declare is dropped, recursively,
/// before the JSON reaches the generated entry point.
///
/// `JSON.parse` accepts only the keys its target type declares, so without this
/// every field the description gains breaks every decorator already written —
/// spec 459's `methods` took the 455 suite from ten passing to six on the day
/// it was added, and the format could never have grown again. A decorator now
/// sees exactly what it named, and a key it did not name is invisible to it;
/// `protocol` is what a decorator refuses a description by, not the arrival of
/// a field it never reads.
///
/// Narrowing only ever removes. A key the type declares and the description
/// does not is left missing, and the decorator fails to parse it, which is the
/// right answer: it asked for something the compiler does not describe.
fn narrow(arena: std.mem.Allocator, program: ast.Program, json: []const u8) ![]const u8 {
    var decls: std.StringHashMapUnmanaged([]const ast.TypeField) = .empty;
    for (program.stmts) |stmt| switch (stmt) {
        .type_decl => |t| if (t.alias == null and t.fields.len > 0) try decls.put(arena, t.name, t.fields),
        else => {},
    };
    const parsed = std.json.parseFromSlice(std.json.Value, arena, json, .{}) catch return json;
    const kept = try narrowValue(arena, &decls, parsed.value, description_type);
    return std.json.Stringify.valueAlloc(arena, kept, .{}) catch json;
}

/// One value against one annotation. An annotation naming a record the module
/// declares narrows through it; an array narrows each element; anything else —
/// a scalar, or a type declared somewhere this parse cannot see — is carried
/// through untouched, because nothing here knows enough to drop from it.
fn narrowValue(
    arena: std.mem.Allocator,
    decls: *const std.StringHashMapUnmanaged([]const ast.TypeField),
    value: std.json.Value,
    annotation: []const u8,
) !std.json.Value {
    const a = std.mem.trim(u8, annotation, " \t");
    if (std.mem.endsWith(u8, a, "[]")) {
        if (value != .array) return value;
        const elem = a[0 .. a.len - 2];
        var items: std.json.Array = .init(arena);
        for (value.array.items) |item| try items.append(try narrowValue(arena, decls, item, elem));
        return .{ .array = items };
    }
    const fields = decls.get(a) orelse return value;
    if (value != .object) return value;
    var obj: std.json.ObjectMap = .empty;
    for (fields) |f| {
        const got = value.object.get(f.name) orelse continue;
        try obj.put(arena, f.name, try narrowValue(arena, decls, got, f.annotation));
    }
    return .{ .object = obj };
}

/// Whether a declared return type is one the value can travel back through JSON
/// in. `types.fromAnnotation` keeps any unknown name as a named type, which is
/// right for a record but would also wave through the spellings whose runtime
/// shape JSON does not carry (spec 051), so those are named here and everything
/// else answers to the checker's own predicate.
fn carriesAsJson(annotation: []const u8) bool {
    const a = std.mem.trim(u8, annotation, " \t");
    if (std.mem.startsWith(u8, a, "Map<") or std.mem.startsWith(u8, a, "Set<")) return false;
    if (std.mem.startsWith(u8, a, "[")) return false; // a tuple
    if (std.mem.indexOf(u8, a, "=>") != null) return false; // a function
    return check_stdlib.jsonSerializable(types.fromAnnotation(a));
}

fn expected(
    arena: std.mem.Allocator,
    app: describe.Application,
    module_path: []const u8,
    exported: []const u8,
    why: []const u8,
    fail: *Failure,
) error{ DecoratorFailed, OutOfMemory } {
    fail.* = .{ .line = app.line, .col = app.col, .msg = try std.fmt.allocPrint(
        arena,
        "'@{s}' must be `export function {s}(d: {s}): T` in {s} — {s}",
        .{ app.name, exported, description_type, module_path, why },
    ) };
    return error.DecoratorFailed;
}

/// The program the compiler compiles to run one decorator: read the description
/// off the command line, call the function, print what it returns. `process.argv`
/// here is `[program, ...args]`, so the description is `argv[1]`.
pub fn entrySource(arena: std.mem.Allocator, module_spec: []const u8, exported: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena,
        \\// Generated by the Lumen compiler to run the '{s}' decorator (spec 455).
        \\import {{ {s}, {s} }} from "{s}";
        \\
        \\function main(): void {{
        \\  console.log(JSON.stringify({s}(JSON.parse<{s}>(process.argv[1]))));
        \\}}
        \\
        \\main();
        \\
    , .{ exported, exported, description_type, module_spec, exported, description_type });
}

/// `@entity` on `Agent` gives `entityAgent`: deterministic, needs no hygiene
/// rules, and collides through the ordinary duplicate-binding diagnostic.
pub fn constantName(arena: std.mem.Allocator, decorator: []const u8, target: []const u8) ![]const u8 {
    const name = try std.fmt.allocPrint(arena, "{s}{s}", .{ decorator, target });
    name[decorator.len] = std.ascii.toUpper(name[decorator.len]);
    return name;
}

/// The returned JSON as a Lumen literal. A record literal is JSON with unquoted
/// keys, so this is a syntactic transform and not a parse: the program pays
/// nothing at runtime for a decorator, which it would if the constant were a
/// `JSON.parse` at startup.
pub fn literal(arena: std.mem.Allocator, json: []const u8, app: describe.Application, fail: *Failure) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var p: Reader = .{ .src = std.mem.trim(u8, json, " \t\r\n") };
    p.value(arena, &out) catch {
        fail.* = .{ .line = app.line, .col = app.col, .msg = try std.fmt.allocPrint(
            arena,
            "'@{s}' printed something that is not JSON: {s}",
            .{ app.name, std.mem.trim(u8, json, " \t\r\n") },
        ) };
        return error.DecoratorFailed;
    };
    p.skipSpace();
    if (p.i != p.src.len) {
        fail.* = .{ .line = app.line, .col = app.col, .msg = try std.fmt.allocPrint(
            arena,
            "'@{s}' printed more than one value; a decorator returns one",
            .{app.name},
        ) };
        return error.DecoratorFailed;
    }
    return out.items;
}

const Reader = struct {
    src: []const u8,
    i: usize = 0,

    fn skipSpace(self: *Reader) void {
        while (self.i < self.src.len and (self.src[self.i] == ' ' or self.src[self.i] == '\t' or
            self.src[self.i] == '\n' or self.src[self.i] == '\r')) self.i += 1;
    }

    const Error = error{ NotJson, OutOfMemory };

    fn take(self: *Reader, c: u8) Error!void {
        self.skipSpace();
        if (self.i >= self.src.len or self.src[self.i] != c) return error.NotJson;
        self.i += 1;
    }

    fn value(self: *Reader, arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) Error!void {
        self.skipSpace();
        if (self.i >= self.src.len) return error.NotJson;
        switch (self.src[self.i]) {
            '{' => return self.object(arena, out),
            '[' => return self.array(arena, out),
            '"' => return out.appendSlice(arena, try self.string()),
            else => {
                const start = self.i;
                while (self.i < self.src.len and std.mem.indexOfScalar(u8, ",]} \t\n\r", self.src[self.i]) == null) self.i += 1;
                if (self.i == start) return error.NotJson;
                try out.appendSlice(arena, self.src[start..self.i]);
            },
        }
    }

    fn object(self: *Reader, arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) Error!void {
        try self.take('{');
        self.skipSpace();
        if (self.i < self.src.len and self.src[self.i] == '}') {
            self.i += 1;
            return out.appendSlice(arena, "{}");
        }
        try out.appendSlice(arena, "{ ");
        var first = true;
        while (true) {
            if (!first) try out.appendSlice(arena, ", ");
            first = false;
            const key = try self.string();
            // A key that is not an identifier stays quoted; the checker reports
            // it against the record type, which is where the mismatch is.
            const bare = key[1 .. key.len - 1];
            try out.appendSlice(arena, if (isIdentifier(bare)) bare else key);
            try out.appendSlice(arena, ": ");
            try self.take(':');
            try self.value(arena, out);
            self.skipSpace();
            if (self.i < self.src.len and self.src[self.i] == ',') {
                self.i += 1;
                continue;
            }
            try self.take('}');
            break;
        }
        try out.appendSlice(arena, " }");
    }

    fn array(self: *Reader, arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8)) Error!void {
        try self.take('[');
        self.skipSpace();
        try out.append(arena, '[');
        if (self.i < self.src.len and self.src[self.i] == ']') {
            self.i += 1;
            return out.append(arena, ']');
        }
        var first = true;
        while (true) {
            if (!first) try out.appendSlice(arena, ", ");
            first = false;
            try self.value(arena, out);
            self.skipSpace();
            if (self.i < self.src.len and self.src[self.i] == ',') {
                self.i += 1;
                continue;
            }
            try self.take(']');
            break;
        }
        try out.append(arena, ']');
    }

    /// A JSON string, quotes and escapes included: the two languages spell a
    /// string literal the same way, so it travels verbatim.
    fn string(self: *Reader) Error![]const u8 {
        try self.take('"');
        const start = self.i - 1;
        while (self.i < self.src.len) : (self.i += 1) {
            if (self.src[self.i] == '\\') {
                self.i += 1;
                continue;
            }
            if (self.src[self.i] == '"') {
                self.i += 1;
                return self.src[start..self.i];
            }
        }
        return error.NotJson;
    }
};

fn isIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_' and s[0] != '$') return false;
    for (s[1..]) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '$') return false;
    return true;
}

test "a returned value becomes a record literal, not a runtime parse (spec 455)" {
    var buf: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer buf.deinit();
    const arena = buf.allocator();
    var fail: Failure = undefined;
    const app: describe.Application = .{ .name = "entity", .target = "Agent", .json = "", .line = 3, .col = 1, .decl_line = 4 };
    const eq = std.testing.expectEqualStrings;
    try eq(
        \\{ table: "agents", n: 3, ok: true, rate: 1.5, missing: null }
    , try literal(arena,
        \\{"table":"agents","n":3,"ok":true,"rate":1.5,"missing":null}
    , app, &fail));
    try eq(
        \\{ fields: [{ field: "id", column: "id" }, { field: "n", column: "n" }] }
    , try literal(arena,
        \\{"fields":[{"field":"id","column":"id"},{"field":"n","column":"n"}]}
    , app, &fail));
    // Scalars and empties are values too, and a quoted key that is not an
    // identifier is left for the checker to report against the record type.
    try eq("[]", try literal(arena, "[]", app, &fail));
    try eq("{}", try literal(arena, "{}", app, &fail));
    try eq("42", try literal(arena, "42\n", app, &fail));
    try eq(
        \\"a \"quoted\" name"
    , try literal(arena,
        \\"a \"quoted\" name"
    , app, &fail));
    try eq(
        \\{ "not-an-identifier": 1 }
    , try literal(arena,
        \\{"not-an-identifier":1}
    , app, &fail));
}

test "output that is not one JSON value is refused, naming the decorator (spec 455)" {
    var buf: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer buf.deinit();
    const arena = buf.allocator();
    var fail: Failure = undefined;
    const app: describe.Application = .{ .name = "entity", .target = "Agent", .json = "", .line = 3, .col = 1, .decl_line = 4 };
    for ([_][]const u8{ "", "{\"a\":}", "{\"a\": 1", "1 2", "{\"a\": 1} trailing" }) |out| {
        try std.testing.expectError(error.DecoratorFailed, literal(arena, out, app, &fail));
        try std.testing.expect(std.mem.indexOf(u8, fail.msg, "'@entity'") != null);
        try std.testing.expectEqual(@as(u32, 3), fail.line);
    }
}

test "the constant is named for the decorator and the declaration (spec 455)" {
    var buf: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer buf.deinit();
    const arena = buf.allocator();
    const eq = std.testing.expectEqualStrings;
    try eq("entityAgent", try constantName(arena, "entity", "Agent"));
    try eq("toolSearch", try constantName(arena, "tool", "search"));
}

test "a decorator's signature is read off its module (spec 455)" {
    var buf: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer buf.deinit();
    const arena = buf.allocator();
    const app: describe.Application = .{ .name = "entity", .target = "Agent", .json = "", .line = 3, .col = 1, .decl_line = 4 };
    var fail: Failure = undefined;
    const good =
        \\import { DbRepository } from "./plume.ts";
        \\export type Description = { protocol: int, name: string };
        \\export function entity(d: Description): DbRepository {
        \\  return repository(d.name);
        \\}
        \\
    ;
    try std.testing.expectEqualStrings("DbRepository", (try signature(arena, good, "e.ts", "entity", app, &fail)).returns);

    const bad = [_][]const u8{
        // No such export.
        \\export type Description = { protocol: int };
        \\export function other(d: Description): int { return 1; }
        ,
        // Two parameters, or one that is not a description.
        \\export type Description = { protocol: int };
        \\export function entity(d: Description, x: int): int { return 1; }
        ,
        \\export type Description = { protocol: int };
        \\export function entity(x: int): int { return 1; }
        ,
        // A return type JSON cannot carry.
        \\export type Description = { protocol: int };
        \\export function entity(d: Description): Map<string, int> { return new Map(); }
        ,
        // No `Description` for the description to be parsed into.
        \\export function entity(d: Description): int { return 1; }
        ,
    };
    for (bad) |src| {
        try std.testing.expectError(error.DecoratorFailed, signature(arena, src, "e.ts", "entity", app, &fail));
        try std.testing.expect(std.mem.indexOf(u8, fail.msg, "'@entity' must be") != null);
        try std.testing.expectEqual(@as(u32, 3), fail.line);
    }
}

test "a decorator is handed only the keys its own Description declares (spec 459)" {
    var buf: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer buf.deinit();
    const arena = buf.allocator();
    // What the compiler describes a class as today, methods and all.
    const full =
        \\{"protocol":1,"kind":"class","name":"AgentApi","args":["/agents"],"file":"api.ts","line":2,"fields":[{"name":"base","type":"string","decorators":[]}],"methods":[{"name":"find","returns":"string","params":[{"name":"id","type":"string","decorators":[{"name":"param","args":["the id"]}]}],"decorators":[{"name":"get","args":["/:id"]}]}]}
    ;
    const app: describe.Application = .{ .name = "entity", .target = "AgentApi", .json = full, .line = 3, .col = 1, .decl_line = 4 };
    var fail: Failure = undefined;

    // A decorator written before methods were described: it names the seven
    // keys spec 455 had, and runs against the description spec 459 emits.
    const unaware =
        \\export type DecoratorUse = { name: string, args: string[] };
        \\export type FieldDescription = { name: string, type: string, decorators: DecoratorUse[] };
        \\export type Description = { protocol: int, kind: string, name: string, args: string[], file: string, line: int, fields: FieldDescription[] };
        \\export function entity(d: Description): int { return 1; }
        \\
    ;
    try std.testing.expectEqualStrings(
        \\{"protocol":1,"kind":"class","name":"AgentApi","args":["/agents"],"file":"api.ts","line":2,"fields":[{"name":"base","type":"string","decorators":[]}]}
    , (try signature(arena, unaware, "e.ts", "entity", app, &fail)).description);

    // Narrowing reaches all the way down: a decorator that wants the methods
    // but not their signatures is not handed the signatures.
    const partial =
        \\export type DecoratorUse = { name: string, args: string[] };
        \\export type MethodDescription = { name: string, decorators: DecoratorUse[] };
        \\export type Description = { name: string, methods: MethodDescription[] };
        \\export function entity(d: Description): int { return 1; }
        \\
    ;
    try std.testing.expectEqualStrings(
        \\{"name":"AgentApi","methods":[{"name":"find","decorators":[{"name":"get","args":["/:id"]}]}]}
    , (try signature(arena, partial, "e.ts", "entity", app, &fail)).description);
}

test "the generated entry point reads argv[1], calls, and prints (spec 455)" {
    var buf: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer buf.deinit();
    const arena = buf.allocator();
    try std.testing.expectEqualStrings(
        \\// Generated by the Lumen compiler to run the 'entity' decorator (spec 455).
        \\import { entity, Description } from "./entity.ts";
        \\
        \\function main(): void {
        \\  console.log(JSON.stringify(entity(JSON.parse<Description>(process.argv[1]))));
        \\}
        \\
        \\main();
        \\
    , try entrySource(arena, "./entity.ts", "entity"));
}
