//! Statement codegen -- the `Stmt`-union counterpart of `emitExpr`.
//!
//! `emitStmtWithThrow` is the main dispatch (one case per statement kind),
//! threading the current try/switch "where do I jump on throw/break" targets
//! through nested blocks; `emitStmt` is the common case (no throw target) that
//! delegates to it. Also handles `=`/`+=`/...  assignment lowering
//! (`emitAssignExpr`) and `switch` case-match comparisons
//! (`emitSwitchCaseMatch`).
//!
//! This is the single largest emission concern (every control-flow construct
//! in the language), pulled out of `lumen_emit.zig` as its own file; it calls
//! back into `emitExpr` (still in `lumen_emit.zig`) for every expression a
//! statement contains.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const types = @import("lumen_types.zig");
const diag_mod = @import("lumen_diag.zig");
const emit_mod = @import("lumen_emit.zig");
const analysis = @import("lumen_emit_analysis.zig");
const emit_class = @import("lumen_emit_class.zig");
const emitClass = emit_class.emitClass;
const lumen_opt = @import("lumen_opt.zig");
const collectStrConcat = lumen_opt.collectStrConcat;
const bodyUsesName = lumen_opt.bodyUsesName;

const CompileError = diag_mod.CompileError;
const Expr = ast.Expr;
const Stmt = ast.Stmt;
const CompileOptions = emit_mod.CompileOptions;
const emitExpr = emit_mod.emitExpr;

/// Emit one `let`/`const`/`var` declarator. Shared by single and comma-grouped
/// declarations.
fn emitOneVarDecl(decl: ast.VarDecl, body: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    // In an `__into` body the returned accumulator is the dest parameter, so its
    // local declaration is dropped.
    if (emit_mod.g_cur_into_acc != null and decl.is_accumulator and std.mem.eql(u8, decl.emit_name orelse decl.name, emit_mod.g_cur_into_acc.?)) return;
    if (decl.is_accumulator) {
        // String-builder: a growable buffer instead of an immutable slice. The
        // init is always `""`, so it starts empty.
        try body.print(arena, "    var {s}: std.ArrayListUnmanaged(u8) = .empty;\n", .{decl.emit_name orelse decl.name});
    } else if (decl.is_array_accumulator) {
        // Array-builder: a growable ArrayList(T) instead of an immutable slice,
        // so `a = [...a, x]` appends in amortized O(1). Init is always `[]`.
        const at = decl.checked_type orelse return error.ParseError;
        const et = types.arrayElem(at) orelse return error.ParseError;
        try body.print(arena, "    var {s}: std.ArrayListUnmanaged({s}) = .empty;\n", .{ decl.emit_name orelse decl.name, try types.zigName(arena, et) });
    } else if (decl.no_init) {
        // `let x: T;` with no initializer -> `var x: T = undefined;` (always
        // `var`: an uninitialized binding is meant to be assigned before use).
        const final_zty = decl.checked_type orelse return error.ParseError;
        try body.print(arena, "    var {s}: {s} = undefined;\n", .{ decl.emit_name orelse decl.name, try types.zigName(arena, final_zty) });
    } else if (decl.stack_alloc and decl.init.* == .new_expr and
        !(analysis.g_method_arena != null and analysis.ctorThrows(analysis.g_method_arena.?, decl.init.new_expr.class_name)))
    {
        // Escape analysis proved this instance never leaves the frame: build it
        // on the stack by value and bind the name to its address (no heap alloc,
        // spec 344). A throwing ctor falls through to the heap `__init` path.
        const ne = decl.init.new_expr;
        const cname = ne.class_name;
        const vname = decl.emit_name orelse decl.name;
        const stk = try std.fmt.allocPrint(arena, "__stk_{s}_{d}_{d}", .{ vname, decl.line, decl.col });
        try body.print(arena, "    var {s}: {s} = {s}.__initv(", .{ stk, cname, cname });
        for (ne.args, 0..) |arg, i| {
            if (i > 0) try body.appendSlice(arena, ", ");
            try emitExpr(arg, body, arena);
        }
        try body.print(arena, ");\n    const {s} = &{s};\n", .{ vname, stk });
    } else {
        const final_zty = decl.checked_type orelse return error.ParseError;
        try body.print(arena, "    {s} {s}: {s} = ", .{ if (decl.mutable and decl.reassigned) "var" else "const", decl.emit_name orelse decl.name, try types.zigName(arena, final_zty) });
        // An arrow bound to a name traces under that name (spec 237).
        if (decl.init.* == .arrow) decl.init.arrow.name_hint = decl.name;
        try emitExpr(decl.init, body, arena);
        try body.appendSlice(arena, ";\n");
    }
    // A never-referenced binding warned at check time still compiles (JS
    // semantics); discard it so Zig accepts the unused local (spec 280).
    if (decl.unused) {
        try body.print(arena, "    _ = &{s};\n", .{decl.emit_name orelse decl.name});
    }
}

var g_log_seq: usize = 0;

/// Emit a `[]const u8` expression that renders an array `console.log`-style,
/// e.g. `[1, 2, 3]` or `['a', 'b']`.
fn emitArrayLogString(value: *ast.Expr, elem: types.Type, body: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    g_log_seq += 1;
    const n = g_log_seq;
    try body.print(arena, "(__la{d}: {{ const __arr = ", .{n});
    // A bare array literal emits as a tuple; wrap it in a real slice so it is
    // iterable with a runtime index.
    if (value.* == .array and value.array.elem_type == null) {
        try body.print(arena, "@as([]const {s}, ", .{try types.zigName(arena, elem)});
        try emitExpr(value, body, arena);
        try body.append(arena, ')');
    } else {
        try emitExpr(value, body, arena);
    }
    try body.appendSlice(arena, "; ");
    try emitArrayToStringTail(elem, n, body, arena);
    try body.appendSlice(arena, " })");
}

/// Given `__arr` already bound in scope, emit the loop that renders it to a
/// `[]const u8` and `break :__la{n}`s with the result. Callers open the
/// `(__la{n}: { ... })` block around this.
fn emitArrayToStringTail(elem: types.Type, n: u64, body: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    try body.appendSlice(arena, "var __lb: std.ArrayListUnmanaged(u8) = .empty; __lb.append(__sa(), '[') catch unreachable; for (__arr, 0..) |__le, __li| { if (__li > 0) __lb.appendSlice(__sa(), \", \") catch unreachable; ");
    if (types.isStringLike(elem)) {
        try body.appendSlice(arena, "__lb.append(__sa(), '\\'') catch unreachable; __lb.appendSlice(__sa(), __le) catch unreachable; __lb.append(__sa(), '\\'') catch unreachable;");
    } else {
        const spec = if (elem == .bool) "{}" else "{d}";
        try body.print(arena, "__lb.appendSlice(__sa(), std.fmt.allocPrint(__sa(), \"{s}\", .{{__le}}) catch unreachable) catch unreachable;", .{spec});
    }
    try body.print(arena, " }} __lb.append(__sa(), ']') catch unreachable; break :__la{d} @as([]const u8, __lb.items);", .{n});
}

/// Is this a `T[] | null` optional whose payload is an array we render
/// bracket-style?
fn isOptionalArray(t: types.Type) bool {
    return t == .optional and types.isArray(t.optional.*);
}

/// The `console.log` format spec for one argument: `{s}` for arrays and
/// optional arrays (both rendered to a string first), else `printFormat`.
fn logArgFormat(t: types.Type) []const u8 {
    if (types.isArray(t) or isOptionalArray(t)) return "{s}";
    return analysis.printFormat(t);
}

/// Emit one `console.log` argument, choosing the array / optional-array
/// string renderer or a plain expression.
fn emitLogArg(value: *ast.Expr, t: types.Type, body: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    if (isOptionalArray(t)) {
        try emitOptionalArrayLogString(value, types.arrayElem(t.optional.*) orelse .i32, body, arena);
    } else if (types.isArray(t)) {
        try emitArrayLogString(value, types.arrayElem(t) orelse .i32, body, arena);
    } else {
        try emitExpr(value, body, arena);
    }
}

/// `console.log` of an optional array (`T[] | null`): render "null" when the
/// value is null, otherwise the same bracketed form as a plain array.
fn emitOptionalArrayLogString(value: *ast.Expr, elem: types.Type, body: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    g_log_seq += 1;
    const n = g_log_seq;
    try body.print(arena, "(__lo{d}: {{ const __opt = ", .{n});
    try emitExpr(value, body, arena);
    try body.print(arena, "; if (__opt) |__arr| {{ break :__lo{d} (__la{d}: {{ ", .{ n, n });
    try emitArrayToStringTail(elem, n, body, arena);
    try body.print(arena, " }}); }} else {{ break :__lo{d} @as([]const u8, \"null\"); }} }})", .{n});
}

pub fn emitStmt(stmt: *const Stmt, decls: *std.ArrayListUnmanaged(u8), body: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, options: CompileOptions) CompileError!void {
    return emitStmtWithThrow(stmt, decls, body, arena, null, null, options);
}

pub fn emitAssignExpr(assignment: ast.Assign, body: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    const base = assignment.emit_name orelse assignment.name;
    // A scalar by-reference (`Ref<T>`) param assigns through its pointer.
    const name = if (assignment.deref) try std.fmt.allocPrint(arena, "{s}.*", .{base}) else base;
    try body.print(arena, "{s} = ", .{name});
    try emitCompoundRhs(assignment.op, name, assignment.value, assignment.checked_type, body, arena);
}

/// Emits the right-hand side of an assignment for target `name`: a plain value
/// for `=`, or the folded `(name <op> value)` form for a compound assignment.
/// Multi-char operators (`<<= >>= **= &&= ||= ??=`) can't use the naive
/// `op[0]` char -- `<<=`'s first char is `<`, which would emit a comparison;
/// `**=`'s is `*`, a multiply; etc. Each is lowered explicitly, reusing the
/// same std.math.shl/shr/powi/pow and short-circuit forms the binary
/// operators use (spec 052).
fn emitCompoundRhs(op: []const u8, name: []const u8, value: *ast.Expr, checked_type: ?types.Type, body: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    const eqs = std.mem.eql;
    if (eqs(u8, op, "=")) {
        try emitExpr(value, body, arena);
    } else if (op[0] == '/') {
        // Float division keeps the fraction; integer division truncates.
        if (checked_type != null and checked_type.? == .f64) {
            try body.print(arena, "({s} / ", .{name});
        } else {
            try body.print(arena, "@divTrunc({s}, ", .{name});
        }
        try emitExpr(value, body, arena);
        try body.append(arena, ')');
    } else if (op[0] == '%') {
        try body.print(arena, "@rem({s}, ", .{name});
        try emitExpr(value, body, arena);
        try body.append(arena, ')');
    } else if (eqs(u8, op, "&&=") or eqs(u8, op, "||=")) {
        try body.print(arena, "({s} {s} ", .{ name, if (eqs(u8, op, "&&=")) "and" else "or" });
        try emitExpr(value, body, arena);
        try body.append(arena, ')');
    } else if (eqs(u8, op, "??=")) {
        try body.print(arena, "({s} orelse ", .{name});
        try emitExpr(value, body, arena);
        try body.append(arena, ')');
    } else if (eqs(u8, op, "<<=") or eqs(u8, op, ">>=")) {
        const ty = try types.zigName(arena, checked_type orelse .i32);
        try body.print(arena, "std.math.{s}({s}, {s}, ", .{ if (eqs(u8, op, "<<=")) "shl" else "shr", ty, name });
        try emitExpr(value, body, arena);
        try body.append(arena, ')');
    } else if (eqs(u8, op, "**=")) {
        const t = checked_type orelse .i32;
        const ty = try types.zigName(arena, t);
        if (t == .f64) {
            try body.print(arena, "std.math.pow({s}, {s}, ", .{ ty, name });
            try emitExpr(value, body, arena);
            try body.append(arena, ')');
        } else {
            try body.print(arena, "(std.math.powi({s}, {s}, ", .{ ty, name });
            try emitExpr(value, body, arena);
            try body.appendSlice(arena, ") catch std.process.exit(1))");
        }
    } else if (op[0] == '+' and checked_type != null and checked_type.? == .string) {
        // String `s += x` concatenates, like `s = s + x`.
        try body.print(arena, "(std.mem.concat(__sa(), u8, &.{{ {s}, ", .{name});
        try emitExpr(value, body, arena);
        try body.appendSlice(arena, " }) catch std.process.exit(1))");
    } else {
        // `+= -= *=` and bitwise `&= |= ^=` -- Zig uses the same single char.
        try body.print(arena, "({s} {c} ", .{ name, op[0] });
        try emitExpr(value, body, arena);
        try body.append(arena, ')');
    }
}

/// Whether a switch case/default body contains a `break` that targets the switch
/// itself. Descends through `if`/`try`/`defer` blocks but not into nested loops
/// or switches, whose own `break` binds to that inner construct.
pub fn bodyHasSwitchBreak(body: []const Stmt) bool {
    for (body) |*s| {
        switch (s.*) {
            .break_stmt => return true,
            .if_stmt => |b| {
                if (bodyHasSwitchBreak(b.then_body)) return true;
                if (b.else_body) |eb| if (bodyHasSwitchBreak(eb)) return true;
            },
            .try_stmt => |t| {
                if (bodyHasSwitchBreak(t.try_body)) return true;
                if (bodyHasSwitchBreak(t.catch_body)) return true;
                if (t.finally_body) |fb| if (bodyHasSwitchBreak(fb)) return true;
            },
            .defer_stmt => |d| if (bodyHasSwitchBreak(d.body)) return true,
            else => {},
        }
    }
    return false;
}

/// Whether `stmts` contain a `break`/`continue` targeting the label `name`
/// (recursively, through nested control flow). Zig rejects an unused block
/// label, so a labeled loop only emits its label when the body actually
/// references it (spec 052).
fn bodyReferencesLabel(stmts: []const Stmt, name: []const u8) bool {
    for (stmts) |*s| {
        switch (s.*) {
            .break_stmt, .continue_stmt => |c| if (c.label) |l| {
                if (std.mem.eql(u8, l, name)) return true;
            },
            .if_stmt => |b| {
                if (bodyReferencesLabel(b.then_body, name)) return true;
                if (b.else_body) |eb| if (bodyReferencesLabel(eb, name)) return true;
            },
            .while_stmt => |w| if (bodyReferencesLabel(w.body, name)) return true,
            .do_while_stmt => |w| if (bodyReferencesLabel(w.body, name)) return true,
            .for_stmt => |f| if (bodyReferencesLabel(f.body, name)) return true,
            .for_of_stmt => |f| if (bodyReferencesLabel(f.body, name)) return true,
            .for_in_stmt => |f| if (bodyReferencesLabel(f.body, name)) return true,
            .try_stmt => |t| {
                if (bodyReferencesLabel(t.try_body, name)) return true;
                if (bodyReferencesLabel(t.catch_body, name)) return true;
                if (t.finally_body) |fb| if (bodyReferencesLabel(fb, name)) return true;
            },
            .switch_stmt => |sw| {
                for (sw.cases) |cse| if (bodyReferencesLabel(cse.body, name)) return true;
                if (sw.default_body) |db| if (bodyReferencesLabel(db, name)) return true;
            },
            .defer_stmt => |d| if (bodyReferencesLabel(d.body, name)) return true,
            else => {},
        }
    }
    return false;
}

/// The Zig label prefix (`__lumen_lbl_<name>: `) for a labeled loop, or "" when
/// unlabeled or the label is never targeted (Zig errors on an unused label).
fn labelPrefix(arena: std.mem.Allocator, label: ?[]const u8, loop_body: []const Stmt) CompileError![]const u8 {
    const l = label orelse return "";
    if (!bodyReferencesLabel(loop_body, l)) return "";
    return std.fmt.allocPrint(arena, "__lumen_lbl_{s}: ", .{l});
}

pub fn emitSwitchCaseMatch(switch_type: types.Type, switch_value: *const Expr, case_value: *const Expr, body: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator) CompileError!void {
    // A string enum lowers to its `[]const u8` value, so it compares by bytes.
    const string_like = types.isStringLike(switch_type) or
        (switch_type == .enum_type and switch_type.enum_type.is_string);
    if (string_like) {
        try body.appendSlice(arena, "std.mem.eql(u8, ");
        try emitExpr(switch_value, body, arena);
        try body.appendSlice(arena, ", ");
        try emitExpr(case_value, body, arena);
        try body.append(arena, ')');
    } else {
        try body.append(arena, '(');
        try emitExpr(switch_value, body, arena);
        try body.appendSlice(arena, " == ");
        try emitExpr(case_value, body, arena);
        try body.append(arena, ')');
    }
}

/// Whether control never continues past this statement (an unconditional
/// `return`/`throw`/`break`/`continue`): later statements in the same block
/// are dead code, which Zig rejects, so body emission stops there.
pub fn stmtDiverges(stmt: *const Stmt) bool {
    return switch (stmt.*) {
        .return_stmt, .throw_stmt, .break_stmt, .continue_stmt => true,
        else => false,
    };
}

/// Emit a statement list, dropping unreachable statements after an
/// unconditional diverge (the checker warns about them).
pub fn emitBody(stmts: []const Stmt, decls: *std.ArrayListUnmanaged(u8), body: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, throw_target: ?[]const u8, switch_break_target: ?[]const u8, options: CompileOptions) CompileError!void {
    for (stmts) |*stmt| {
        try emitStmtWithThrow(stmt, decls, body, arena, throw_target, switch_break_target, options);
        if (stmtDiverges(stmt)) break;
    }
}

pub fn emitStmtWithThrow(stmt: *const Stmt, decls: *std.ArrayListUnmanaged(u8), body: *std.ArrayListUnmanaged(u8), arena: std.mem.Allocator, throw_target: ?[]const u8, switch_break_target: ?[]const u8, options: CompileOptions) CompileError!void {
    // Expressions don't see the threaded throw_target parameter; mirror it in
    // a module global so throwing-call sites inside this statement's
    // expressions can route errors to the enclosing try (spec 245).
    const saved_throw_target = emit_mod.g_throw_target;
    emit_mod.g_throw_target = throw_target;
    defer emit_mod.g_throw_target = saved_throw_target;
    if (options.runtime_locations) {
        const line_col: emit_mod.SourceLoc = switch (stmt.*) {
            .type_decl => |decl| .{ .line = decl.line, .col = decl.col },
            .enum_decl => |decl| .{ .line = decl.line, .col = decl.col },
            .extern_decl => |decl| .{ .line = decl.line, .col = decl.col },
            .class_decl => |decl| .{ .line = decl.line, .col = decl.col },
            .member_assign => |ma| .{ .line = ma.line, .col = ma.col },
            .super_ctor => |sc| .{ .line = sc.line, .col = sc.col },
            .test_decl => |decl| .{ .line = decl.line, .col = decl.col },
            .function_decl => |decl| .{ .line = decl.line, .col = decl.col },
            .var_decl => |decl| .{ .line = decl.line, .col = decl.col },
            .var_decl_group => |group| .{ .line = group[0].line, .col = group[0].col },
            .using_decl => |decl| .{ .line = decl.line, .col = decl.col },
            .destructure_decl => |d| .{ .line = d.line, .col = d.col },
            .assign => |assignment| .{ .line = assignment.line, .col = assignment.col },
            .console_log => |log| .{ .line = log.line, .col = log.col },
            .while_stmt => |loop| .{ .line = loop.line, .col = loop.col },
            .do_while_stmt => |loop| .{ .line = loop.line, .col = loop.col },
            .for_stmt => |loop| .{ .line = loop.line, .col = loop.col },
            .for_of_stmt => |loop| .{ .line = loop.line, .col = loop.col },
            .for_in_stmt => |loop| .{ .line = loop.line, .col = loop.col },
            .if_stmt => |branch| .{ .line = branch.line, .col = branch.col },
            .switch_stmt => |switch_stmt| .{ .line = switch_stmt.line, .col = switch_stmt.col },
            .return_stmt => |ret| .{ .line = ret.line, .col = ret.col },
            .throw_stmt => |throw_stmt| .{ .line = throw_stmt.line, .col = throw_stmt.col },
            .try_stmt => |try_stmt| .{ .line = try_stmt.line, .col = try_stmt.col },
            .break_stmt => |control| .{ .line = control.line, .col = control.col },
            .continue_stmt => |control| .{ .line = control.line, .col = control.col },
            .defer_stmt => |d| .{ .line = d.line, .col = d.col },
            .expr_stmt => |expr_stmt| .{ .line = expr_stmt.line, .col = expr_stmt.col },
            .block_stmt => |b| .{ .line = b.line, .col = b.col },
        };
        try body.print(arena, "    __lumen_line = {d}; __lumen_col = {d};\n", .{ line_col.line, line_col.col });
    }

    switch (stmt.*) {
        .block_stmt => |b| {
            try body.appendSlice(arena, "    {\n");
            try emitBody(b.body, decls, body, arena, throw_target, switch_break_target, options);
            try body.appendSlice(arena, "    }\n");
        },
        .type_decl => |decl| {
            if (decl.string_literals != null) return;
            if (decl.int_literals != null) return;
            if (decl.alias != null) return; // aliases are erased: resolve to target
            if (decl.union_variants != null) {
                // A discriminated union lowers to a flat struct holding the union
                // of every variant's fields, each with a default so a single
                // variant's object literal initializes cleanly.
                try decls.print(arena, "const {s} = struct {{\n", .{decl.name});
                for (decl.fields) |field| {
                    const field_type = field.checked_type orelse return error.ParseError;
                    const zty = try types.zigName(arena, field_type);
                    try decls.appendSlice(arena, "    ");
                    try emit_mod.emitFieldName(decls, arena, field.name);
                    try decls.print(arena, ": {s} = {s},\n", .{ zty, try analysis.zigZeroValue(arena, field_type) });
                }
                try decls.appendSlice(arena, "};\n");
                return;
            }
            if (decl.type_params.len > 0) return; // generic template: only specializations emit
            // A method-bearing interface lowers to a vtable type + fat-pointer
            // struct for polymorphic dispatch, not a plain record (spec 428).
            if (decl.is_interface) {
                for (decl.fields) |f| {
                    if (f.checked_type != null and f.checked_type.? == .func_type) {
                        try emit_class.emitIfaceDecl(&decl, decls, arena);
                        return;
                    }
                }
            }
            try decls.print(arena, "const {s} = struct {{\n", .{decl.name});
            for (decl.fields) |field| {
                const field_type = field.checked_type orelse return error.ParseError;
                try decls.appendSlice(arena, "    ");
                try emit_mod.emitFieldName(decls, arena, field.name);
                try decls.print(arena, ": {s},\n", .{try types.zigName(arena, field_type)});
            }
            try decls.appendSlice(arena, "};\n");
        },
        .enum_decl => {}, // members are inlined as constants at each use site
        .extern_decl => |decl| {
            // extern fn name(p0: T, ...) Ret;  -- resolved at link time.
            // A `string` parameter/return crosses the C ABI as a NUL-terminated
            // `const char*`, i.e. Zig `[*:0]const u8`; the call site marshals
            // between that and the Lumen `[]const u8` string.
            try decls.print(arena, "extern fn {s}(", .{decl.name});
            for (decl.params, 0..) |param, i| {
                if (i > 0) try decls.appendSlice(arena, ", ");
                try decls.print(arena, "{s}: {s}", .{ analysis.paramName(param), emit_mod.externZigName(param.checked_type orelse return error.ParseError, arena) });
            }
            try decls.print(arena, ") {s};\n", .{emit_mod.externZigName(decl.checked_return_type orelse return error.ParseError, arena)});
        },
        .class_decl => |*c| {
            if (c.type_params.len > 0) return; // generic template: only specializations emit
            try emitClass(c, decls, arena, throw_target, switch_break_target, options);
        },
        .super_ctor => |sc| {
            // super(args) -> self.__superctor_<Parent>(args);
            const parent = sc.parent orelse return;
            const throws = analysis.g_method_arena != null and analysis.ctorThrows(analysis.g_method_arena.?, parent);
            try body.appendSlice(arena, "    ");
            if (throws) try emit_mod.emitThrowingCallPrefix(body, arena);
            try body.print(arena, "self.__superctor_{s}(", .{parent});
            for (sc.args, 0..) |arg, i| {
                if (i > 0) try body.appendSlice(arena, ", ");
                try emitExpr(arg, body, arena);
            }
            try body.append(arena, ')');
            if (throws) try emit_mod.emitThrowingCallSuffix(body, arena);
            try body.appendSlice(arena, ";\n");
        },
        .member_assign => |ma| {
            // Resolve the receiver expression: `self.` (this), `Class.` (static),
            // a setter call, or `obj.` (external instance field).
            if (ma.is_setter) {
                // obj.prop = value  ->  obj.__set_prop(value);
                try body.appendSlice(arena, "    ");
                try emitExpr(ma.obj.?, body, arena);
                try body.print(arena, ".__set_{s}(", .{ma.field});
                try emitExpr(ma.value, body, arena);
                try body.appendSlice(arena, ");\n");
                return;
            }
            // Build the lvalue prefix string.
            var lv: std.ArrayListUnmanaged(u8) = .empty;
            if (ma.is_static) {
                const owner = ma.class_name orelse "";
                try lv.print(arena, "{s}.__static_{s}_{s}", .{ owner, owner, ma.field });
            } else if (ma.obj) |obj| {
                try emitExpr(obj, &lv, arena);
                try lv.appendSlice(arena, ".");
                try emit_mod.emitFieldName(&lv, arena, ma.field);
            } else {
                try lv.appendSlice(arena, "self.");
                try emit_mod.emitFieldName(&lv, arena, ma.field);
            }
            const lvs = lv.items;
            try body.print(arena, "    {s} = ", .{lvs});
            // Field-target compound assignment reuses the same lowering; the
            // field type isn't threaded here, so `<<=`/`>>=`/`**=` on a
            // non-i32 field would mis-type -- an accepted edge for now (the
            // common `+= -= *= &= |= ^= &&= ||= ??=` forms are unaffected).
            try emitCompoundRhs(ma.op, lvs, ma.value, null, body, arena);
            try body.appendSlice(arena, ";\n");
        },
        .test_decl => |t| {
            // Emit a Zig `test "name" { ... }` block into the top-level decls.
            try decls.appendSlice(arena, "test \"");
            for (t.name) |ch| {
                if (ch == '"' or ch == '\\') try decls.append(arena, '\\');
                try decls.append(arena, ch);
            }
            try decls.appendSlice(arena, "\" {\n");
            // In a test build there is no `main` to fill the hoisted I/O
            // globals; wire them to the test runner's Io so console.log and
            // other I/O builtins work inside tests.
            if (emit_mod.g_program) |prog| if (prog.uses_io) {
                try decls.appendSlice(arena, "    __io = std.testing.io;\n");
            };
            // ...and no `main` to run the module-level initializers either, so
            // each test block calls the generated init function first. The
            // function guards itself, so it runs once per binary, not once per
            // test (spec 449). It must come *after* the `__io` wiring above:
            // an initializer may itself do I/O.
            try decls.print(arena, "    {s}();\n", .{emit_mod.MODULE_INIT_FN});
            try emitBody(t.body, decls, decls, arena, throw_target, switch_break_target, options);
            try decls.appendSlice(arena, "}\n");
        },
        .function_decl => |decl| {
            if (decl.type_params.len > 0) return; // generic template: only specializations emit
            const return_type = decl.checked_return_type orelse types.fromAnnotation(decl.return_annotation);
            // A position marker for the declaration itself, as a comment: the
            // `__lumen_line` markers are statements and so only exist inside a
            // body, which leaves an error on a signature — a parameter shadowing
            // a top-level name, a bad parameter type — attributed to whatever
            // statement was emitted last, usually in another module entirely.
            try decls.print(arena, "// __lumen_decl {d} {d}\n", .{ decl.line, decl.col });
            try decls.print(arena, "fn {s}(", .{try emit_mod.safeGlobalName(arena, decl.name)});
            for (decl.params, 0..) |param, i| {
                if (i > 0) try decls.appendSlice(arena, ", ");
                const param_type = param.checked_type orelse types.fromAnnotation(param.annotation);
                const ztype = if (param.is_ref) try types.refZigName(arena, param_type) else try types.zigName(arena, param_type);
                try decls.print(arena, "{s}: {s}", .{ try analysis.paramSigName(arena, param, decl.body), ztype });
            }
            // An async function returns its declared `*LumenPromise(T)`; `return v`
            // statements in the body resolve the promise with `v`.
            // A throwing function returns an error union so a `throw` can
            // propagate to callers (spec 245).
            const fn_throws = analysis.fnThrows(decl.name);
            if (fn_throws) {
                try decls.print(arena, ") error{{LumenThrow}}!{s} {{\n", .{try types.zigName(arena, return_type)});
            } else {
                try decls.print(arena, ") {s} {{\n", .{try types.zigName(arena, return_type)});
            }
            const saved_can_error = emit_mod.g_fn_can_error;
            emit_mod.g_fn_can_error = fn_throws;
            defer emit_mod.g_fn_can_error = saved_can_error;
            const prev_async_inner = emit_mod.g_async_inner;
            if (decl.is_async and return_type == .promise_type) {
                emit_mod.g_async_inner = try types.zigName(arena, return_type.promise_type.*);
            } else {
                emit_mod.g_async_inner = null;
            }
            defer emit_mod.g_async_inner = prev_async_inner;
            // Stack-trace frame: record this call (entry captures the caller's
            // current statement position, i.e. the call site).
            if (options.runtime_locations) {
                try decls.print(arena, "    __lumenPush(\"{s}\"); defer __lumenPop();\n", .{decl.name});
            }
            try analysis.emitUnusedParamDiscards(decl.params, decl.body, decls, arena);
            try analysis.emitReassignedParamCopies(decl.params, decl.body, decls, arena);
            try emitBody(decl.body, decls, decls, arena, null, null, options);
            // An async `Promise<void>` body may legally fall through without a
            // `return`; emit a trailing resolved promise so the Promise-returning
            // function still returns a value. Skip it when the body already
            // returns on every path (the trailing return would be dead code).
            if (decl.is_async and return_type == .promise_type and return_type.promise_type.* == .void and !analysis.bodyAlwaysReturns(decl.body)) {
                try decls.appendSlice(arena, "    return __promiseResolved(void, {});\n");
            }
            try decls.appendSlice(arena, "}\n");
            // Destination-passing twin: appends straight into a caller buffer.
            if (emit_mod.g_dest_acc) |dm| if (dm.get(decl.name)) |accname| {
                try decls.print(arena, "fn {s}__into({s}: *std.ArrayListUnmanaged(u8)", .{ decl.name, accname });
                for (decl.params) |param| {
                    const param_type = param.checked_type orelse types.fromAnnotation(param.annotation);
                    const ztype = if (param.is_ref) try types.refZigName(arena, param_type) else try types.zigName(arena, param_type);
                    try decls.print(arena, ", {s}: {s}", .{ analysis.paramName(param), ztype });
                }
                try decls.appendSlice(arena, ") void {\n");
                const prev = emit_mod.g_cur_into_acc;
                emit_mod.g_cur_into_acc = accname;
                try analysis.emitUnusedParamDiscards(decl.params, decl.body, decls, arena);
                try emitBody(decl.body, decls, decls, arena, null, null, options);
                emit_mod.g_cur_into_acc = prev;
                try decls.appendSlice(arena, "}\n");
            };
        },
        .var_decl => |decl| try emitOneVarDecl(decl, body, arena),
        .var_decl_group => |group| for (group) |decl| try emitOneVarDecl(decl, body, arena),
        .using_decl => |decl| {
            // `using` lowers to Zig `defer`, which already runs LIFO at scope
            // exit and interleaves correctly with `defer`-statement blocks.
            if (decl.defer_body) |defer_body| {
                // `using x = defer(() => BODY);` — run BODY at scope exit.
                try body.appendSlice(arena, "    defer {\n");
                try emitBody(defer_body, decls, body, arena, throw_target, switch_break_target, options);
                try body.appendSlice(arena, "    }\n");
            } else {
                // `using r = EXPR;` — bind the value, then `defer r.dispose();`.
                const final_zty = decl.checked_type orelse return error.ParseError;
                try body.print(arena, "    const {s}: {s} = ", .{ decl.emit_name orelse decl.name, try types.zigName(arena, final_zty) });
                try emitExpr(decl.init, body, arena);
                try body.appendSlice(arena, ";\n");
                const dispose = decl.dispose_call orelse return error.ParseError;
                try body.appendSlice(arena, "    defer {\n        _ = ");
                try emitExpr(dispose, body, arena);
                try body.appendSlice(arena, ";\n    }\n");
            }
        },
        .destructure_decl => |d| {
            // Bind a temp to the source, then one const per element/field. No
            // wrapping block, so the bindings remain in the enclosing scope.
            const src = try std.fmt.allocPrint(arena, "__lumen_ds_{d}_{d}", .{ d.line, d.col });
            try body.print(arena, "    const {s} = ", .{src});
            // An array-literal source lowers to a tuple; wrap it in a real slice
            // so a rest binding (`src[i..]`) and runtime indexing work.
            if (!d.is_object and d.source.* == .array and d.source.array.elem_type == null and d.bindings.len > 0) {
                const et = d.bindings[0].checked_type orelse .i32;
                const elem_t = if (types.isArray(et)) (types.arrayElem(et) orelse .i32) else et;
                try body.print(arena, "@as([]const {s}, ", .{try types.zigName(arena, elem_t)});
                try emitExpr(d.source, body, arena);
                try body.appendSlice(arena, ")");
            } else {
                try emitExpr(d.source, body, arena);
            }
            try body.appendSlice(arena, ";\n");
            for (d.bindings, 0..) |b, i| {
                const bty = b.checked_type orelse return error.ParseError;
                const bname = b.emit_name orelse b.name;
                if (d.is_assignment) {
                    // `[a, b] = expr` — assign to existing variables.
                    try body.print(arena, "    {s} = ", .{bname});
                } else {
                    try body.print(arena, "    const {s}: {s} = ", .{ bname, try types.zigName(arena, bty) });
                }
                if (d.is_object) {
                    if (b.default_unwraps) {
                        // `{ x = default }` where `x` is optional: an absent
                        // property falls back to the default.
                        try body.print(arena, "{s}.{s} orelse ", .{ src, b.field_name orelse b.name });
                        try emitExpr(b.default.?, body, arena);
                        try body.appendSlice(arena, ";\n");
                    } else {
                        // Required property (always present): the default, if any,
                        // is dead; the field value passes through.
                        try body.print(arena, "{s}.{s};\n", .{ src, b.field_name orelse b.name });
                    }
                } else if (d.is_tuple) {
                    // A tuple lowers to a positional struct: read field `.@"i"`.
                    try body.print(arena, "{s}.@\"{d}\";\n", .{ src, i });
                } else if (b.is_rest) {
                    // The remaining elements as a slice.
                    try body.print(arena, "{s}[{d}..];\n", .{ src, i });
                } else if (b.default) |dv| {
                    // `[a = default]` — use the element when present, else the default.
                    try body.print(arena, "if ({d} < {s}.len) {s}[{d}] else ", .{ i, src, src, i });
                    try emitExpr(dv, body, arena);
                    try body.appendSlice(arena, ";\n");
                } else {
                    try body.print(arena, "{s}[{d}];\n", .{ src, i });
                }
                // JS allows an unused destructured binding; Zig does not. (An
                // assignment target is an existing variable, so no marker.)
                if (!d.is_assignment and !std.mem.eql(u8, bname, "_")) try body.print(arena, "    _ = &{s};\n", .{bname});
            }
        },
        .assign => |assignment| {
            if (assignment.is_array_accumulator) {
                // `a = [...a, e1, e2, ...]` -> append each element after the
                // leading `...a` spread in place. A `...other` element appends
                // that slice; a plain element appends the single value.
                const vname = assignment.emit_name orelse assignment.name;
                const items = assignment.value.array.items;
                for (items[1..]) |it| {
                    if (it.* == .spread) {
                        try body.print(arena, "    {s}.appendSlice(__sa(), ", .{vname});
                        try emitExpr(it.spread, body, arena);
                        try body.appendSlice(arena, ") catch std.process.exit(1);\n");
                    } else {
                        try body.print(arena, "    {s}.append(__sa(), ", .{vname});
                        try emitExpr(it, body, arena);
                        try body.appendSlice(arena, ") catch std.process.exit(1);\n");
                    }
                }
            } else if (assignment.is_accumulator) {
                // `v = v + a + b` -> append a, b in place (skip the leading `v`).
                var parts: std.ArrayListUnmanaged(*const Expr) = .empty;
                try collectStrConcat(assignment.value, &parts, arena);
                const vname = assignment.emit_name orelse assignment.name;
                // The buffer to pass to an `__into` call: the dest itself when this
                // accumulator IS the enclosing `__into` dest (already a pointer),
                // otherwise its address.
                const accptr = if (emit_mod.g_cur_into_acc != null and std.mem.eql(u8, emit_mod.g_cur_into_acc.?, vname)) vname else try std.fmt.allocPrint(arena, "&{s}", .{vname});
                if (parts.items.len >= 1) {
                    for (parts.items[1..]) |p| {
                        if (p.* == .call and p.call.is_into_call) {
                            try body.print(arena, "    {s}__into({s}", .{ p.call.name, accptr });
                            for (p.call.args) |arg| {
                                try body.appendSlice(arena, ", ");
                                try emitExpr(arg, body, arena);
                            }
                            try body.appendSlice(arena, ");\n");
                        } else {
                            try body.print(arena, "    {s}.appendSlice(__sa(), ", .{vname});
                            try emitExpr(p, body, arena);
                            try body.appendSlice(arena, ") catch std.process.exit(1);\n");
                        }
                    }
                }
            } else {
                try body.appendSlice(arena, "    ");
                try emitAssignExpr(assignment, body, arena);
                try body.appendSlice(arena, ";\n");
            }
        },
        .console_log => |log| {
            const log_type = log.checked_type orelse return error.ParseError;
            const dest = if (std.mem.eql(u8, log.method, "log") or std.mem.eql(u8, log.method, "info") or std.mem.eql(u8, log.method, "debug"))
                "__consoleOut(\""
            else if (std.mem.eql(u8, log.method, "trace"))
                "std.debug.print(\"Trace: "
            else
                "std.debug.print(\"";
            // Format string: each argument's spec, space-separated (JS joins
            // console.log args with spaces), then a newline.
            try body.print(arena, "    {s}", .{dest});
            try body.appendSlice(arena, logArgFormat(log_type));
            for (log.extra_types) |et| {
                try body.appendSlice(arena, " ");
                try body.appendSlice(arena, logArgFormat(et));
            }
            try body.appendSlice(arena, "\\n\", .{");
            // Arguments.
            try emitLogArg(log.value, log_type, body, arena);
            for (log.extra_values, log.extra_types) |ev, et| {
                try body.appendSlice(arena, ", ");
                try emitLogArg(ev, et, body, arena);
            }
            try body.appendSlice(arena, "});\n");
        },
        .while_stmt => |loop| {
            try body.print(arena, "    {s}while (", .{try labelPrefix(arena, loop.label, loop.body)});
            try emitExpr(loop.cond, body, arena);
            try body.appendSlice(arena, ") {\n");
            try emitBody(loop.body, decls, body, arena, throw_target, null, options);
            try body.appendSlice(arena, "    }\n");
        },
        .do_while_stmt => |loop| {
            try body.print(arena, "    {s}while (true) : ({{ if (!(", .{try labelPrefix(arena, loop.label, loop.body)});
            try emitExpr(loop.cond, body, arena);
            try body.appendSlice(arena, ")) break; }) {\n");
            try emitBody(loop.body, decls, body, arena, throw_target, null, options);
            try body.appendSlice(arena, "    }\n");
        },
        .for_stmt => |loop| {
            try body.appendSlice(arena, "    {\n");
            if (loop.init) |i| {
                var init_stmt: Stmt = .{ .var_decl = i };
                try emitStmtWithThrow(&init_stmt, decls, body, arena, throw_target, switch_break_target, options);
            }
            for (loop.extra_inits) |extra| {
                var es: Stmt = .{ .var_decl = extra };
                try emitStmtWithThrow(&es, decls, body, arena, throw_target, switch_break_target, options);
            }
            try body.print(arena, "    {s}while (", .{try labelPrefix(arena, loop.label, loop.body)});
            // An omitted condition loops unconditionally.
            if (loop.cond) |c| try emitExpr(c, body, arena) else try body.appendSlice(arena, "true");
            try body.appendSlice(arena, ")");
            // The continue-expression (update step) is emitted only when present.
            if (loop.update) |upd| {
                try body.appendSlice(arena, " : (");
                if (loop.extra_updates.len == 0) {
                    try emitAssignExpr(upd, body, arena);
                } else {
                    // Several updates run each iteration: a block continue-expression.
                    try body.appendSlice(arena, "{ ");
                    try emitAssignExpr(upd, body, arena);
                    try body.appendSlice(arena, "; ");
                    for (loop.extra_updates) |u| {
                        try emitAssignExpr(u, body, arena);
                        try body.appendSlice(arena, "; ");
                    }
                    try body.appendSlice(arena, "}");
                }
                try body.appendSlice(arena, ")");
            }
            try body.appendSlice(arena, " {\n");
            try emitBody(loop.body, decls, body, arena, throw_target, null, options);
            try body.appendSlice(arena, "    }\n");
            try body.appendSlice(arena, "    }\n");
        },
        .for_of_stmt => |loop| {
            const iter_ty = loop.iter_type orelse return error.ParseError;
            // `for (const [k, v] of map)` — iterate the map's keys and values in
            // parallel.
            // `for (const [a, b] of pairs)` over a `[A, B][]` — destructure each
            // tuple element into the two bindings (spec 291).
            if (loop.is_tuple_pairs) {
                const kn = loop.binding_emit_name orelse loop.binding;
                const vn = loop.value_binding;
                const elem_zig = try types.zigName(arena, loop.elem_type orelse return error.ParseError);
                try body.appendSlice(arena, "    {\n    const __tp = ");
                try emitExpr(loop.iterable, body, arena);
                try body.print(arena, ";\n    for (__tp) |__te| {{\n    const {s} = __te.@\"0\"; const {s} = __te.@\"1\";\n", .{ kn, vn });
                try body.print(arena, "    _ = &{s}; _ = &{s}; _ = @as({s}, __te);\n", .{ kn, vn, elem_zig });
                try emitBody(loop.body, decls, body, arena, throw_target, null, options);
                try body.appendSlice(arena, "    }\n    }\n");
                return;
            }
            if (loop.is_pair and !loop.is_array_entries) {
                const kn = loop.binding_emit_name orelse loop.binding;
                const vn = loop.value_binding;
                try body.appendSlice(arena, "    {\n    const __pm = ");
                try emitExpr(loop.iterable, body, arena);
                try body.print(arena, ";\n    for (__pm.keys(), __pm.values()) |{s}, {s}| {{\n", .{ kn, vn });
                try body.print(arena, "    _ = &{s}; _ = &{s};\n", .{ kn, vn });
                try emitBody(loop.body, decls, body, arena, throw_target, null, options);
                try body.appendSlice(arena, "    }\n    }\n");
                return;
            }
            // `for (const [i, v] of arr.entries())` — iterate the receiver array
            // with a running i32 index and the element in parallel.
            if (loop.is_array_entries) {
                const kn = loop.binding_emit_name orelse loop.binding;
                const vn = loop.value_binding;
                const et = loop.elem_type orelse return error.ParseError;
                const et_zig = try types.zigName(arena, et);
                const seq = try std.fmt.allocPrint(arena, "__lumen_en_seq_{d}_{d}", .{ loop.line, loop.col });
                const idx = try std.fmt.allocPrint(arena, "__lumen_en_idx_{d}_{d}", .{ loop.line, loop.col });
                try body.appendSlice(arena, "    {\n");
                try body.print(arena, "    const {s}: []const {s} = ", .{ seq, et_zig });
                try emitExpr(loop.iterable, body, arena);
                try body.appendSlice(arena, ";\n");
                try body.print(arena, "    var {s}: usize = 0;\n", .{idx});
                try body.print(arena, "    {s}while ({s} < {s}.len) : ({s} += 1) {{\n", .{ try labelPrefix(arena, loop.label, loop.body), idx, seq, idx });
                try body.print(arena, "    const {s}: i32 = @intCast({s});\n", .{ kn, idx });
                try body.print(arena, "    const {s}: {s} = {s}[{s}];\n", .{ vn, et_zig, seq, idx });
                if (!std.mem.eql(u8, kn, "_")) try body.print(arena, "    _ = &{s};\n", .{kn});
                if (!std.mem.eql(u8, vn, "_")) try body.print(arena, "    _ = &{s};\n", .{vn});
                try emitBody(loop.body, decls, body, arena, throw_target, null, options);
                try body.appendSlice(arena, "    }\n    }\n");
                return;
            }
            // `for (const i of arr.keys())` — index-only loop over the receiver.
            if (loop.is_array_keys) {
                const kn = loop.binding_emit_name orelse loop.binding;
                const len_name = try std.fmt.allocPrint(arena, "__lumen_ky_len_{d}_{d}", .{ loop.line, loop.col });
                const idx = try std.fmt.allocPrint(arena, "__lumen_ky_idx_{d}_{d}", .{ loop.line, loop.col });
                try body.appendSlice(arena, "    {\n");
                try body.print(arena, "    const {s}: usize = (", .{len_name});
                try emitExpr(loop.iterable, body, arena);
                try body.appendSlice(arena, ").len;\n");
                try body.print(arena, "    var {s}: usize = 0;\n", .{idx});
                try body.print(arena, "    {s}while ({s} < {s}) : ({s} += 1) {{\n", .{ try labelPrefix(arena, loop.label, loop.body), idx, len_name, idx });
                try body.print(arena, "    const {s}: i32 = @intCast({s});\n", .{ kn, idx });
                if (!std.mem.eql(u8, kn, "_")) try body.print(arena, "    _ = &{s};\n", .{kn});
                try emitBody(loop.body, decls, body, arena, throw_target, null, options);
                try body.appendSlice(arena, "    }\n    }\n");
                return;
            }
            const elem_ty = loop.elem_type orelse return error.ParseError;
            const seq = try std.fmt.allocPrint(arena, "__lumen_of_seq_{d}_{d}", .{ loop.line, loop.col });
            const idx = try std.fmt.allocPrint(arena, "__lumen_of_idx_{d}_{d}", .{ loop.line, loop.col });
            const binding = loop.binding_emit_name orelse loop.binding;
            const elem_zig = try types.zigName(arena, elem_ty);
            try body.appendSlice(arena, "    {\n");
            // Annotate the sequence's slice type for arrays so an array *literal*
            // iterable (which lowers to an anonymous tuple) coerces to a real
            // slice and can be indexed at runtime. Strings are already []const u8.
            if (types.isStringLike(iter_ty)) {
                try body.print(arena, "    const {s} = ", .{seq});
            } else {
                try body.print(arena, "    const {s}: []const {s} = ", .{ seq, elem_zig });
            }
            try emitExpr(loop.iterable, body, arena);
            // A Set iterates its values slice (spec 268).
            if (iter_ty == .set_type) try body.appendSlice(arena, ".values()");
            try body.appendSlice(arena, ";\n");
            try body.print(arena, "    var {s}: usize = 0;\n", .{idx});
            try body.print(arena, "    {s}while ({s} < {s}.len) : ({s} += 1) {{\n", .{ try labelPrefix(arena, loop.label, loop.body), idx, seq, idx });
            // String iteration yields single-character substrings ([]const u8);
            // array iteration yields the element directly.
            if (types.isStringLike(iter_ty)) {
                try body.print(arena, "    const {s}: {s} = {s}[{s} .. {s} + 1];\n", .{ binding, elem_zig, seq, idx, idx });
            } else {
                try body.print(arena, "    const {s}: {s} = {s}[{s}];\n", .{ binding, elem_zig, seq, idx });
            }
            // JS allows an unused loop variable; Zig does not. Mark it used so a
            // body that ignores the element still compiles.
            if (!std.mem.eql(u8, binding, "_")) try body.print(arena, "    _ = &{s};\n", .{binding});
            try emitBody(loop.body, decls, body, arena, throw_target, null, options);
            try body.appendSlice(arena, "    }\n");
            try body.appendSlice(arena, "    }\n");
        },
        .for_in_stmt => |loop| {
            const binding = loop.binding_emit_name orelse loop.binding;
            try body.appendSlice(arena, "    {\n");
            if (loop.key_names) |names| {
                // Record: iterate the fixed field-name list. The iterable
                // value itself isn't needed (keys come from its type), but
                // evaluate it for side-effect parity with JS.
                try body.appendSlice(arena, "    _ = ");
                try emitExpr(loop.iterable, body, arena);
                try body.appendSlice(arena, ";\n");
                try body.appendSlice(arena, "    const __forin_keys = [_][]const u8{");
                for (names, 0..) |n, i| {
                    if (i > 0) try body.appendSlice(arena, ", ");
                    try emit_mod.emitStrLit(body, arena, n);
                }
                try body.appendSlice(arena, "};\n");
                try body.print(arena, "    {s}for (__forin_keys) |__forin_k| {{\n    const {s}: []const u8 = __forin_k;\n", .{ try labelPrefix(arena, loop.label, loop.body), binding });
                if (!std.mem.eql(u8, binding, "_")) try body.print(arena, "    _ = &{s};\n", .{binding});
                try emitBody(loop.body, decls, body, arena, throw_target, null, options);
                try body.appendSlice(arena, "    }\n");
            } else {
                // Array: iterate indices 0..len as strings.
                const seq = try std.fmt.allocPrint(arena, "__forin_seq_{d}_{d}", .{ loop.line, loop.col });
                const idx = try std.fmt.allocPrint(arena, "__forin_idx_{d}_{d}", .{ loop.line, loop.col });
                try body.print(arena, "    const {s} = ", .{seq});
                try emitExpr(loop.iterable, body, arena);
                try body.appendSlice(arena, ";\n");
                try body.print(arena, "    var {s}: usize = 0;\n", .{idx});
                try body.print(arena, "    {s}while ({s} < {s}.len) : ({s} += 1) {{\n", .{ try labelPrefix(arena, loop.label, loop.body), idx, seq, idx });
                try body.print(arena, "    const {s}: []const u8 = std.fmt.allocPrint(__alloc, \"{{d}}\", .{{{s}}}) catch unreachable;\n", .{ binding, idx });
                if (!std.mem.eql(u8, binding, "_")) try body.print(arena, "    _ = &{s};\n", .{binding});
                try emitBody(loop.body, decls, body, arena, throw_target, null, options);
                try body.appendSlice(arena, "    }\n");
            }
            try body.appendSlice(arena, "    }\n");
        },
        .if_stmt => |branch| {
            try body.appendSlice(arena, "    if (");
            try emitExpr(branch.cond, body, arena);
            try body.appendSlice(arena, ") {\n");
            try emitBody(branch.then_body, decls, body, arena, throw_target, switch_break_target, options);
            try body.appendSlice(arena, "    }");
            if (branch.else_body) |else_body| {
                try body.appendSlice(arena, " else {\n");
                try emitBody(else_body, decls, body, arena, throw_target, switch_break_target, options);
                try body.appendSlice(arena, "    }");
            }
            try body.appendSlice(arena, "\n");
        },
        .switch_stmt => |switch_stmt| {
            const switch_type = switch_stmt.checked_type orelse return error.ParseError;
            // The break-target label is only emitted when a case actually breaks;
            // a switch whose cases all `return` (e.g. discriminated-union
            // dispatch) needs no label, which Zig would reject as unused.
            var needs_label = false;
            for (switch_stmt.cases) |case| {
                if (bodyHasSwitchBreak(case.body)) needs_label = true;
            }
            if (switch_stmt.default_body) |db| {
                if (bodyHasSwitchBreak(db)) needs_label = true;
            }
            const label = try std.fmt.allocPrint(arena, "__lumen_switch_{d}_{d}", .{ switch_stmt.line, switch_stmt.col });
            const label_target: ?[]const u8 = if (needs_label) label else null;
            if (needs_label) try body.print(arena, "    {s}: {{\n", .{label}) else try body.appendSlice(arena, "    {\n");
            // A case with an empty body falls through to the next clause. Lowering
            // to if/else, gather consecutive empty-body case values and OR their
            // match conditions onto the next non-empty case (`if (v==0 or v==1)`).
            // Trailing empty cases with no following non-empty case fall to the
            // `else` (default) automatically, so they need no branch.
            var pending: std.ArrayListUnmanaged(*Expr) = .empty;
            var emitted_branch = false;
            for (switch_stmt.cases) |case| {
                if (case.body.len == 0) {
                    try pending.append(arena, case.value);
                    continue;
                }
                try body.appendSlice(arena, if (!emitted_branch) "    if (" else "    else if (");
                emitted_branch = true;
                for (pending.items) |pv| {
                    try emitSwitchCaseMatch(switch_type, switch_stmt.value, pv, body, arena);
                    try body.appendSlice(arena, " or ");
                }
                pending.clearRetainingCapacity();
                try emitSwitchCaseMatch(switch_type, switch_stmt.value, case.value, body, arena);
                try body.appendSlice(arena, ") {\n");
                try emitBody(case.body, decls, body, arena, throw_target, label_target, options);
                try body.appendSlice(arena, "    }\n");
            }
            if (switch_stmt.default_body) |default_body| {
                try body.appendSlice(arena, if (!emitted_branch) "    {\n" else "    else {\n");
                try emitBody(default_body, decls, body, arena, throw_target, label_target, options);
                try body.appendSlice(arena, "    }\n");
            } else if (switch_stmt.exhaustive and emitted_branch) {
                // The checker proved every union member is covered; tell Zig's
                // flow analysis the fall-through is impossible (spec 266).
                try body.appendSlice(arena, "    else unreachable;\n");
            }
            try body.appendSlice(arena, "    }\n");
        },
        .return_stmt => |ret| {
            // In an `__into` body, `return <acc>` is already appended into dest -> bare
            // return; any other returned string is appended into dest, then return.
            if (emit_mod.g_cur_into_acc) |dest| {
                if (ret.value) |v| {
                    if (v.* == .var_ref and v.var_ref.is_accumulator and std.mem.eql(u8, v.var_ref.emit_name orelse v.var_ref.name, dest)) {
                        try body.appendSlice(arena, "    return;\n");
                    } else {
                        try body.print(arena, "    {s}.appendSlice(__sa(), ", .{dest});
                        try emitExpr(v, body, arena);
                        try body.appendSlice(arena, ") catch std.process.exit(1);\n    return;\n");
                    }
                } else try body.appendSlice(arena, "    return;\n");
                return;
            }
            if (ret.value) |value| {
                if (emit_mod.g_async_inner) |inner_zig| {
                    // Inside an async body: resolve the promise with the value.
                    try body.print(arena, "    return __promiseResolved({s}, ", .{inner_zig});
                    try emitExpr(value, body, arena);
                    try body.appendSlice(arena, ");\n");
                } else {
                    try body.appendSlice(arena, "    return ");
                    try emitExpr(value, body, arena);
                    try body.appendSlice(arena, ";\n");
                }
            } else if (emit_mod.g_async_inner) |inner_zig| {
                // `return;` in an async `Promise<void>` body resolves with void {}.
                try body.print(arena, "    return __promiseResolved({s}, {{}});\n", .{inner_zig});
            } else {
                try body.appendSlice(arena, "    return;\n");
            }
        },
        .throw_stmt => |throw_stmt| {
            if (throw_target) |target| {
                // Set the enclosing try's slot, then break out of its labeled
                // try block so the remaining try statements are skipped.
                const label = try std.mem.replaceOwned(u8, arena, target, "__lumen_throw_", "__lumen_try_");
                try body.print(arena, "    {s} = ", .{target});
                try emitExpr(throw_stmt.value, body, arena);
                try body.print(arena, ";\n    break :{s};\n", .{label});
            } else if (emit_mod.g_fn_can_error) {
                // Inside a throwing function: stash the message and return the
                // error; the call site unwraps or forwards it (spec 245).
                try body.appendSlice(arena, "    __lumen_err_msg = ");
                try emitExpr(throw_stmt.value, body, arena);
                try body.appendSlice(arena, ";\n    __lumen_throwing = true;\n    return error.LumenThrow;\n");
            } else {
                // An uncaught throw: flag it so the panic handler labels it
                // "Uncaught Error" rather than a generic runtime error.
                try body.appendSlice(arena, "    __lumen_throwing = true;\n    @panic(");
                try emitExpr(throw_stmt.value, body, arena);
                try body.appendSlice(arena, ");\n");
            }
        },
        .try_stmt => |try_stmt| {
            const slot = try std.fmt.allocPrint(arena, "__lumen_throw_{d}_{d}", .{ try_stmt.line, try_stmt.col });
            const label = try std.fmt.allocPrint(arena, "__lumen_try_{d}_{d}", .{ try_stmt.line, try_stmt.col });
            const can_throw = analysis.bodyCanThrow(try_stmt.try_body);
            // The throw slot is only needed when a catch reads it or a
            // throwing body must re-propagate; a no-catch try/finally over a
            // non-throwing body needs none (an unused const would be rejected).
            const need_slot = try_stmt.has_catch or can_throw;
            const slot_kw = if (can_throw) "var" else "const";
            if (need_slot) try body.print(arena, "    {s} {s}: ?[]const u8 = null;\n", .{ slot_kw, slot });
            // Snapshot the stack-trace depth: a caught exception unwinds with
            // its frames left in place (so an uncaught one keeps its trace);
            // the catch restores the depth from before the try (spec 245).
            const depth_snap = try std.fmt.allocPrint(arena, "__lumen_depth_snap_{d}_{d}", .{ try_stmt.line, try_stmt.col });
            const track_depth = try_stmt.has_catch and options.runtime_locations;
            if (track_depth) try body.print(arena, "    const {s} = __lumen_depth;\n", .{depth_snap});
            // Wrap the whole try/catch in an outer block. `finally` lowers to a
            // `defer` at the top of that block, so it always runs on every exit
            // — normal fallthrough, a caught throw, or a rethrow that breaks out
            // to an enclosing try (the defer unwinds before the break leaves).
            try body.appendSlice(arena, "    {\n");
            if (try_stmt.finally_body) |finally_body| {
                try body.appendSlice(arena, "    defer {\n");
                try emitBody(finally_body, decls, body, arena, throw_target, switch_break_target, options);
                try body.appendSlice(arena, "    }\n");
            }
            // The try body runs in a single block so its locals share one scope.
            // When it can throw, the block is labeled so a `throw` can set the
            // slot and break out, skipping the remaining try statements.
            if (can_throw) {
                try body.print(arena, "    {s}: {{\n", .{label});
            } else {
                try body.appendSlice(arena, "    {\n");
            }
            for (try_stmt.try_body) |*try_body_stmt| {
                try emitStmtWithThrow(try_body_stmt, decls, body, arena, slot, switch_break_target, options);
                // A `throw` lowers to a `break`; later siblings are dead code.
                if (analysis.stmtAlwaysThrows(try_body_stmt)) break;
            }
            try body.appendSlice(arena, "    }\n");
            if (!try_stmt.has_catch) {
                // `try { ... } finally { ... }` with no catch: an uncaught throw
                // re-propagates after finally runs. The finally is a `defer` on
                // the enclosing block, so it unwinds before the break/panic.
                if (can_throw) {
                    try body.print(arena, "    if ({s}) |__lumen_rethrow| {{\n", .{slot});
                    if (throw_target) |outer| {
                        const outer_label = try std.mem.replaceOwned(u8, arena, outer, "__lumen_throw_", "__lumen_try_");
                        try body.print(arena, "    {s} = __lumen_rethrow;\n    break :{s};\n", .{ outer, outer_label });
                    } else if (emit_mod.g_fn_can_error) {
                        try body.appendSlice(arena, "    __lumen_err_msg = __lumen_rethrow;\n    __lumen_throwing = true;\n    return error.LumenThrow;\n");
                    } else {
                        try body.appendSlice(arena, "    __lumen_throwing = true;\n    @panic(__lumen_rethrow);\n");
                    }
                    try body.appendSlice(arena, "    }\n");
                }
            } else {
                if (try_stmt.catch_name) |catch_name| {
                    const catch_emit = try_stmt.catch_emit_name orelse catch_name;
                    try body.print(arena, "    if ({s}) |{s}| {{\n", .{ slot, catch_emit });
                    // Zig rejects an unused capture, so discard the binding when
                    // the catch body never reads it.
                    if (!bodyUsesName(try_stmt.catch_body, catch_name)) {
                        try body.print(arena, "    _ = {s};\n", .{catch_emit});
                    }
                } else {
                    // Optional catch binding (spec 052): run the catch body on
                    // any error without capturing it -- no binding to discard.
                    try body.print(arena, "    if ({s} != null) {{\n", .{slot});
                }
                if (track_depth) {
                    // A propagated exception arrived with __lumen_throwing set
                    // and its frames still pushed; catching it ends the unwind.
                    try body.print(arena, "    __lumen_throwing = false;\n    __lumen_depth = {s};\n", .{depth_snap});
                }
                for (try_stmt.catch_body) |*catch_stmt| {
                    try emitStmtWithThrow(catch_stmt, decls, body, arena, throw_target, switch_break_target, options);
                    // A rethrow lowers to a `break`; later siblings are dead code.
                    // Only meaningful when an enclosing try provides a throw target.
                    if (throw_target != null and analysis.stmtAlwaysThrows(catch_stmt)) break;
                }
                try body.appendSlice(arena, "    }\n");
            }
            // When the try can throw and the outer block cannot fall through,
            // emit `unreachable` so Zig's flow analysis agrees a function ending
            // in this try needs no dead trailing return. This holds when the
            // non-throw path returned in the try body and the throw path diverges:
            // for a catch, both bodies always return; for a no-catch try/finally,
            // the try body always returns (the rethrow-if panics/breaks on throw).
            const both_diverge = if (try_stmt.has_catch)
                (try_stmt.catch_body.len > 0 and analysis.bodyAlwaysReturns(try_stmt.try_body) and analysis.bodyAlwaysReturns(try_stmt.catch_body))
            else
                analysis.bodyAlwaysReturns(try_stmt.try_body);
            if (can_throw and both_diverge) {
                try body.appendSlice(arena, "    unreachable;\n");
            }
            try body.appendSlice(arena, "    }\n");
        },
        .defer_stmt => |d| {
            try body.appendSlice(arena, "    defer {\n");
            try emitBody(d.body, decls, body, arena, throw_target, switch_break_target, options);
            try body.appendSlice(arena, "    }\n");
        },
        .break_stmt => |control| {
            if (control.label) |l| {
                try body.print(arena, "    break :__lumen_lbl_{s};\n", .{l});
            } else if (switch_break_target) |target| {
                try body.print(arena, "    break :{s};\n", .{target});
            } else {
                try body.appendSlice(arena, "    break;\n");
            }
        },
        .continue_stmt => |control| {
            if (control.label) |l| {
                try body.print(arena, "    continue :__lumen_lbl_{s};\n", .{l});
            } else {
                try body.appendSlice(arena, "    continue;\n");
            }
        },
        .expr_stmt => |expr_stmt| {
            // A statement whose value is a bare variable or literal is a no-op
            // (e.g. `Object.freeze(p)` rewrites to `p`); emit nothing rather than
            // `_ = p`, which Zig rejects for a const as a pointless discard.
            switch (expr_stmt.value.*) {
                .var_ref, .num, .float, .bool, .str, .null_lit, .this_expr => return,
                else => {},
            }
            const is_serve = expr_stmt.value.* == .call and std.mem.eql(u8, expr_stmt.value.call.name, "serve");
            try body.appendSlice(arena, if (is_serve) "    " else "    _ = ");
            try emitExpr(expr_stmt.value, body, arena);
            try body.appendSlice(arena, ";\n");
        },
    }
}
