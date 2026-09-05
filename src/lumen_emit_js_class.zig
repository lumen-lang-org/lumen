//! Class and enum codegen for the node target.
//!
//! A class is an ES class: fields are declared in the body (a field without
//! an initializer gets the zero value its type has natively, so `count: int`
//! reads `0` and not `undefined`), `constructor(public x)` parameter
//! properties become `this.x = x` right after `super(...)`, accessors are
//! `get`/`set`, statics `static`, and `#name` fields are JavaScript's own
//! private names. `private`/`protected`/`readonly`, `implements` and
//! interfaces are erased. An `enum` is a frozen object literal with the
//! checker's resolved member values (specs 003, 362, 386).

const std = @import("std");
const ast = @import("lumen_ast.zig");
const types = @import("lumen_types.zig");
const js = @import("lumen_emit_js.zig");
const js_expr = @import("lumen_emit_js_expr.zig");
const js_stmt = @import("lumen_emit_js_stmt.zig");

const Emitter = js.Emitter;
const CompileError = js.CompileError;

/// The value a field of this type holds before the constructor assigns it,
/// matching the native zero value; `null` for an optional, `undefined` (no
/// initializer written) for the reference types a constructor must set.
fn zeroValue(ty: ?types.Type) ?[]const u8 {
    const t = ty orelse return null;
    return switch (t) {
        .i32, .i64, .f64 => "0",
        .bool => "false",
        .string => "\"\"",
        .optional, .none => "null",
        .i32_array, .i64_array, .f64_array, .bool_array, .string_array, .named_array, .nested_array => "[]",
        else => null,
    };
}

pub fn emitEnum(e: *Emitter, d: *const ast.EnumDecl) CompileError!void {
    try e.pad();
    try e.print("const {s} = Object.freeze({{", .{d.name});
    for (d.members, 0..) |m, i| {
        try e.w(if (i > 0) ", " else " ");
        try js.emitPropertyKey(e, m.name);
        try e.w(": ");
        if (m.str_value) |s| {
            try js.emitStrLit(e, s);
        } else {
            try e.print("{d}", .{m.int_value});
        }
    }
    try e.w(" });\n");
}

fn emitMethod(e: *Emitter, m: *const ast.FunctionDecl) CompileError!void {
    try e.pad();
    if (m.is_static) try e.w("static ");
    switch (m.accessor) {
        .getter => try e.w("get "),
        .setter => try e.w("set "),
        .none => if (m.is_async) try e.w("async "),
    }
    try e.w(m.name);
    try js_expr.emitParams(e, m.params);
    try e.w(" {\n");
    e.indent += 1;
    try js_stmt.emitBody(e, m.body);
    e.indent -= 1;
    try e.line("}");
}

fn emitConstructor(e: *Emitter, c: *const ast.ClassDecl) CompileError!void {
    try e.pad();
    try e.w("constructor");
    try js_expr.emitParams(e, c.ctor_params);
    try e.w(" {\n");
    e.indent += 1;
    // The parser already put `this.p = p` for each parameter property after
    // the `super(...)` call (`lumen_parser_decl.zig`), so the body is emitted
    // as it stands.
    try js_stmt.emitBody(e, c.ctor_body);
    e.indent -= 1;
    try e.line("}");
}

pub fn emitClass(e: *Emitter, c: *const ast.ClassDecl) CompileError!void {
    try e.pad();
    try e.print("class {s}", .{c.name});
    if (c.parent) |p| try e.print(" extends {s}", .{p});
    try e.w(" {\n");
    e.indent += 1;
    for (c.fields) |f| {
        try e.pad();
        if (f.is_static) try e.w("static ");
        try e.w(f.name);
        if (f.init) |init| {
            try e.w(" = ");
            try js_expr.emitExpr(e, init);
        } else if (zeroValue(f.checked_type)) |z| {
            try e.w(" = ");
            try e.w(z);
        }
        try e.w(";\n");
    }
    if (c.has_ctor) try emitConstructor(e, c);
    for (c.methods) |*m| try emitMethod(e, m);
    e.indent -= 1;
    try e.line("}");
}

test "a class keeps its shape: fields, parameter properties after super, accessors" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: @import("lumen_diag.zig").Diag = .{};
    var program: ast.Program = .{ .stmts = &.{} };
    var e: Emitter = .{ .arena = arena, .diag = &diag, .program = &program };
    var name_arg: ast.Expr = .{ .str = "square" };
    var super_args = [_]*ast.Expr{&name_arg};
    var side_param: ast.Expr = .{ .var_ref = .{ .name = "side" } };
    var ctor_body = [_]ast.Stmt{
        .{ .super_ctor = .{ .args = &super_args, .line = 2, .col = 3 } },
        .{ .member_assign = .{ .field = "side", .value = &side_param, .line = 2, .col = 3 } },
    };
    var params = [_]ast.FunctionParam{.{ .name = "side", .annotation = "int", .is_property = true }};
    var fields = [_]ast.TypeField{.{ .name = "count", .annotation = "int", .checked_type = .i32 }};
    var side_ref: ast.Expr = .{ .this_expr = {} };
    var side: ast.Expr = .{ .field = .{ .obj = &side_ref, .name = "side" } };
    var area_body = [_]ast.Stmt{.{ .return_stmt = .{ .value = &side, .line = 3, .col = 3 } }};
    var methods = [_]ast.FunctionDecl{.{ .name = "area", .params = &.{}, .return_annotation = "int", .body = &area_body, .accessor = .getter, .line = 3, .col = 1 }};
    const decl: ast.ClassDecl = .{ .name = "Square", .fields = &fields, .has_ctor = true, .ctor_params = &params, .ctor_body = &ctor_body, .methods = &methods, .parent = "Shape", .line = 1, .col = 1 };
    try emitClass(&e, &decl);
    try t.expectEqualStrings(
        \\class Square extends Shape {
        \\  count = 0;
        \\  constructor(side) {
        \\    super("square");
        \\    this.side = side;
        \\  }
        \\  get area() {
        \\    return this.side;
        \\  }
        \\}
        \\
    , e.out.items);
}

test "an enum is a frozen object with the resolved values" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: @import("lumen_diag.zig").Diag = .{};
    var program: ast.Program = .{ .stmts = &.{} };
    var e: Emitter = .{ .arena = arena, .diag = &diag, .program = &program };
    var members = [_]ast.EnumMember{ .{ .name = "Red", .int_value = 0 }, .{ .name = "Blue", .int_value = 4 } };
    const decl: ast.EnumDecl = .{ .name = "Color", .members = &members, .line = 1, .col = 1 };
    try emitEnum(&e, &decl);
    try t.expectEqualStrings("const Color = Object.freeze({ Red: 0, Blue: 4 });\n", e.out.items);
}
