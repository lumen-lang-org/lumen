//! The type checker -- stage 3, between parsing and codegen.
//!
//! Walks the AST the parser produced, computes and validates a `Type` for every
//! expression and declaration, and writes the resolved types back onto the AST
//! nodes (the `?types.Type` fields) so the codegen never re-derives them. Type
//! errors become diagnostics (`lumen_diag.zig`); the first error aborts the build.
//!
//! This is one of the two large files (the other is the codegen). It is a `Checker`
//! struct that threads scope/binding/narrowing state, with one method per construct
//! (expressions, statements, declarations, classes, methods, imports). `exprType`
//! is the heart: given an expression it returns its `Type`, or null plus a
//! diagnostic on error. If you are adding a language feature, this is where its
//! typing rules live; keep the resolved-type fields it sets in sync with what the
//! codegen reads.

const std = @import("std");
const ast = @import("lumen_ast.zig");
const diag_mod = @import("lumen_diag.zig");
const types = @import("lumen_types.zig");
const check_stdlib = @import("lumen_check_stdlib.zig");
const check_methods = @import("lumen_check_methods.zig");
const check_stdlib_os = @import("lumen_check_stdlib_os.zig");
const check_generics = @import("lumen_check_generics.zig");
const check_class = @import("lumen_check_class.zig");
const check_stmt = @import("lumen_check_stmt.zig");
const check_assign = @import("lumen_check_assign.zig");
const check_expr = @import("lumen_check_expr.zig");

const CompileError = diag_mod.CompileError;
const Diag = diag_mod.Diag;

const TypeDeclInfo = struct {
    fields: []ast.TypeField,
    string_literals: ?[][]const u8 = null,
    int_literals: ?[]i64 = null,
};

/// One variant of a discriminated union: its record name and the discriminant
/// literal value that selects it.
const UnionVariant = struct { name: []const u8, disc_value: []const u8 };

const UnionInfo = struct {
    variants: []UnionVariant,
    discriminant: []const u8, // shared discriminant field name
};

/// A union binding narrowed (inside a switch case / if branch) to one variant.
const NarrowedVariant = struct { name: []const u8, variant: []const u8 };

const FunctionInfo = struct {
    params: []ast.FunctionParam,
    return_type: types.Type,
    is_extern: bool = false,
};

const EnumInfo = struct {
    is_string: bool,
    members: []ast.EnumMember,
};

const ClassInfo = struct {
    fields: []ast.TypeField,
    methods: []ast.FunctionDecl,
    ctor_params: []ast.FunctionParam,
    has_ctor: bool,
    parent: ?[]const u8 = null,
};

const Binding = struct {
    ty: types.Type,
    mutable: bool,
    decl: ?*ast.VarDecl = null,
    emit_name: []const u8,
    // Whether the binding was ever referenced (read or written) after its
    // declaration; unreferenced `let`/`const` bindings warn at scope exit.
    used: bool = false,
    // True for a scalar `Ref<T>` parameter: reads and assignments of this name
    // lower through the pointer (`name.*`).
    ref_scalar: bool = false,
    // True for any `Ref<T>` parameter. A record `Ref<T>` is mutable through its
    // pointer, so field writes on it are allowed (unlike plain V1 records).
    is_ref: bool = false,
};

const Scope = std.StringHashMapUnmanaged(Binding);

pub const Checker = struct {
    // Builtin/stdlib call type-checking lives in lumen_check_stdlib.zig (it grows
    // independently of the rest of the checker); aliased back so `self.foo(...)`
    // call sites elsewhere in this file are unchanged.
    pub const arrayMethod = check_methods.arrayMethod;
    pub const mapMethod = check_methods.mapMethod;
    pub const setMethod = check_methods.setMethod;
    pub const eventEmitterMethod = check_methods.eventEmitterMethod;
    pub const readableStreamMethod = check_methods.readableStreamMethod;
    pub const writableStreamMethod = check_methods.writableStreamMethod;
    pub const socketMethod = check_methods.socketMethod;
    pub const bufferMethod = check_methods.bufferMethod;
    pub const bufferCallType = check_stdlib.bufferCallType;
    pub const hashMethod = check_methods.hashMethod;
    pub const hmacMethod = check_methods.hmacMethod;
    pub const stringMethod = check_methods.stringMethod;
    pub const staticCallType = check_stdlib.staticCallType;
    pub const fsCallType = check_stdlib_os.fsCallType;
    pub const pathCallType = check_stdlib_os.pathCallType;
    pub const processCallType = check_stdlib_os.processCallType;
    pub const osCallType = check_stdlib_os.osCallType;
    pub const cryptoCallType = check_stdlib.cryptoCallType;
    pub const urlCallType = check_stdlib.urlCallType;
    pub const childProcessCallType = check_stdlib_os.childProcessCallType;
    pub const assertCallType = check_stdlib.assertCallType;
    pub const timeCallType = check_stdlib.timeCallType;
    pub const dateCallType = check_stdlib.dateCallType;
    pub const httpCallType = check_stdlib.httpCallType;
    pub const netCallType = check_stdlib.netCallType;
    pub const jsonCallType = check_stdlib.jsonCallType;
    pub const zlibCallType = check_stdlib.zlibCallType;
    pub const readlineCallType = check_stdlib_os.readlineCallType;
    pub const promiseCallType = check_stdlib.promiseCallType;
    pub const mathCallType = check_stdlib.mathCallType;
    pub const stringCallType = check_stdlib.stringCallType;
    pub const arrayCallType = check_stdlib.arrayCallType;
    pub const workerCallType = check_stdlib.workerCallType;
    pub const numberCallType = check_stdlib.numberCallType;
    pub const numberInstanceMethod = check_methods.numberInstanceMethod;

    // Generic function/class/type specialization lives in lumen_check_generics.zig.
    pub const isGenericTemplateStmt = check_generics.isGenericTemplateStmt;
    pub const appendStmt = check_generics.appendStmt;
    pub const isIdentChar = check_generics.isIdentChar;
    pub const substAnnotation = check_generics.substAnnotation;
    pub const annTag = check_generics.annTag;
    pub const mangledName = check_generics.mangledName;
    pub const splitTypeArgs = check_generics.splitTypeArgs;
    pub const resolveExplicitTypeArgs = check_generics.resolveExplicitTypeArgs;
    pub const inferTypeArgs = check_generics.inferTypeArgs;
    pub const unifyAnnotation = check_generics.unifyAnnotation;
    pub const specializeFunction = check_generics.specializeFunction;
    pub const specializeClass = check_generics.specializeClass;
    pub const specializeType = check_generics.specializeType;
    pub const substCur = check_generics.substCur;
    pub const cloneBody = check_generics.cloneBody;
    pub const cloneExpr = check_generics.cloneExpr;
    pub const cloneVarDecl = check_generics.cloneVarDecl;
    pub const cloneAssign = check_generics.cloneAssign;
    pub const cloneStmt = check_generics.cloneStmt;

    // Class member resolution lives in lumen_check_class.zig.
    pub const classField = check_class.classField;
    pub const resolveField = check_class.resolveField;
    pub const resolveStaticField = check_class.resolveStaticField;
    pub const resolveMethod = check_class.resolveMethod;
    pub const resolveStaticMethod = check_class.resolveStaticMethod;
    pub const resolveAccessor = check_class.resolveAccessor;
    pub const isSubclassOf = check_class.isSubclassOf;
    pub const checkVisibility = check_class.checkVisibility;
    pub const visibilityOk = check_class.visibilityOk;

    // Statement/function-body/class-body checking lives in lumen_check_stmt.zig.
    pub const declareExtern = check_stmt.declareExtern;
    pub const checkBlock = check_stmt.checkBlock;
    pub const checkFunctionBody = check_stmt.checkFunctionBody;
    pub const checkClass = check_stmt.checkClass;
    pub const checkMemberAssign = check_stmt.checkMemberAssign;
    pub const assignField = check_stmt.assignField;
    pub const checkStmt = check_stmt.checkStmt;
    pub const checkVarDecl = check_stmt.checkVarDecl;

    // Assignability/cast checking lives in lumen_check_assign.zig.
    pub const ensureAssignable = check_assign.ensureAssignable;
    pub const castAllowed = check_assign.castAllowed;

    // Expression type-checking (the core dispatch) lives in lumen_check_expr.zig.
    pub const exprType = check_expr.exprType;
    pub const wrapStringify = check_expr.wrapStringify;
    pub const wrapFloat = check_expr.wrapFloat;
    pub const checkCbArg = check_expr.checkCbArg;
    pub const fieldType = check_expr.fieldType;

    arena: std.mem.Allocator,
    scopes: std.ArrayListUnmanaged(Scope) = .empty,
    type_decls: std.StringHashMapUnmanaged(TypeDeclInfo) = .empty,
    // `type X = <annotation>;` aliases, resolved transitively in typeFromAnnotation.
    aliases: std.StringHashMapUnmanaged([]const u8) = .empty,
    // Discriminated unions keyed by union name.
    unions: std.StringHashMapUnmanaged(UnionInfo) = .empty,
    enums: std.StringHashMapUnmanaged(EnumInfo) = .empty,
    classes: std.StringHashMapUnmanaged(ClassInfo) = .empty,
    funcs: std.StringHashMapUnmanaged(FunctionInfo) = .empty,
    // Generic templates, keyed by base name. These are specialized on use
    // (monomorphization) rather than declared directly into the registries above.
    generic_funcs: std.StringHashMapUnmanaged(*ast.FunctionDecl) = .empty,
    generic_classes: std.StringHashMapUnmanaged(*ast.ClassDecl) = .empty,
    generic_types: std.StringHashMapUnmanaged(*ast.TypeDecl) = .empty,
    // Mangled names of already-emitted specializations (dedup) and the new
    // concrete declarations to append to the program for the emitter.
    specialized: std.StringHashMapUnmanaged(void) = .empty,
    // Heap-allocated so the worklist may grow (nested specializations) without
    // moving the in-progress declaration a `checkStmt` is currently mutating.
    pending_specializations: std.ArrayListUnmanaged(*ast.Stmt) = .empty,
    // Active substitution (type-parameter names -> concrete annotations) used to
    // rewrite annotations inside a generic body while it is being cloned.
    subst_params: []const []const u8 = &.{},
    subst_args: []const []const u8 = &.{},
    current_class: ?[]const u8 = null,
    in_constructor: bool = false,
    next_binding_id: u32 = 0,
    current_return_type: ?types.Type = null,
    // True while checking a function whose return annotation was omitted but the
    // checker could not infer a type (a loop/local binding, a forward-referenced
    // callee, or a record needing not-yet-declared types). A value `return` then
    // guides the user to add an explicit annotation instead of the confusing
    // "expected `void`" mismatch.
    current_return_uninferable: bool = false,
    // While inferring an un-annotated function/arrow/method whose return type
    // could not be determined in the declaration pass: each value `return`
    // records its type here (the body is checked with full scope, so locals and
    // earlier declarations resolve). After the body, this becomes the return
    // type. `null` means no value has been returned yet.
    collected_return: ?types.Type = null,
    // True while checking the body of an `async function` (gates `await`).
    in_async: bool = false,
    // True while checking inside any function/method body (top-level `await` is
    // allowed; `await` inside a non-async function body is rejected).
    in_function: bool = false,
    nested_stmt_depth: u32 = 0,
    loop_depth: u32 = 0,
    switch_depth: u32 = 0,
    test_depth: u32 = 0,
    narrowed: std.ArrayListUnmanaged([]const u8) = .empty,
    narrowed_variants: std.ArrayListUnmanaged(NarrowedVariant) = .empty,
    arrow_base: usize = 0, // scope index at which the current arrow's params start
    // Contextual typing for an arrow-function argument: when a stdlib method
    // knows the callback signature it expects (e.g. `map` wants `(elem) => U`),
    // it sets these hints before checking the callback so a bare untyped param
    // (`v => ...`) can infer its type positionally. Consumed once by the arrow.
    arrow_param_hint: ?[]const types.Type = null,
    // The program being checked, set once at entry, so passes that don't thread
    // `program` (generic specialization) can still infer via `exprType`.
    cur_program: ?*ast.Program = null,
    // The expected return type of the next arrow to be checked (a callback whose
    // caller knows the result type, e.g. `reduce`'s accumulator). Lets an
    // expression-body arrow whose body is an object/array literal type against
    // it. Consumed (cleared) on arrow entry so nested arrows don't inherit it.
    arrow_return_hint: ?types.Type = null,
    current_captures: ?*std.ArrayListUnmanaged(ast.Capture) = null,
    last_line: u32 = 1,
    last_col: u32 = 1,
    last_err: []const u8 = "syntax error",
    // Diagnostics collected while continuing past failed statements (multi-error
    // reporting). The first is the primary; the rest render as `extra`.
    all_diags: std.ArrayListUnmanaged(Diag) = .empty,
    // Non-fatal diagnostics (unused variables, ...) surfaced after the compile.
    warnings: std.ArrayListUnmanaged(Diag) = .empty,

    /// Record the last failure into the multi-error list (deduplicating exact
    /// repeats at the same position) so checking can continue.
    fn recordDiag(self: *Checker) void {
        for (self.all_diags.items) |d| {
            if (d.line == self.last_line and d.col == self.last_col) return;
        }
        self.all_diags.append(self.arena, .{ .line = self.last_line, .col = self.last_col, .msg = self.last_err }) catch {};
    }

    pub fn fail(self: *Checker, line: u32, col: u32, msg: []const u8) CompileError {
        self.last_line = line;
        self.last_col = col;
        self.last_err = msg;
        return error.ParseError;
    }

    pub fn inferenceFail(self: *Checker, line: u32, col: u32, msg: []const u8) CompileError {
        // Keep an existing, more specific diagnostic when it points at this
        // position or somewhere inside it (checking is top-down, so an error
        // recorded at a same-or-later line came from this statement's own
        // subexpressions — e.g. E_CAPTURED_MUTATION inside a callback).
        if (self.last_line >= line and !std.mem.eql(u8, self.last_err, "syntax error")) {
            return error.ParseError;
        }
        return self.fail(line, col, msg);
    }

    /// A type-mismatch diagnostic carrying the expected and actual types in
    /// TypeScript syntax: "type mismatch: expected `i32`, got `string`".
    pub fn failTypeMismatch(self: *Checker, line: u32, col: u32, expected: types.Type, actual: types.Type) CompileError {
        const en = types.tsName(self.arena, expected) catch return self.fail(line, col, "E_TYPE_MISMATCH");
        const an = types.tsName(self.arena, actual) catch return self.fail(line, col, "E_TYPE_MISMATCH");
        // An enum value in a `Name`/`Name[]` slot: the annotation resolved to
        // an unknown named type of the same name — the real gap is that enum
        // arrays/containers aren't supported yet; say so instead of the
        // absurd-looking "expected `Status`, got `Status`".
        if (actual == .enum_type and expected == .named and std.mem.eql(u8, expected.named, actual.enum_type.name)) {
            const msg2 = std.fmt.allocPrint(self.arena, "enum containers are not supported yet — `{s}[]` can be modeled as a string-literal union type (`type {s}2 = \"a\" | \"b\"`) or the backing `i32[]`", .{ actual.enum_type.name, actual.enum_type.name }) catch
                return self.fail(line, col, "E_TYPE_MISMATCH");
            return self.fail(line, col, msg2);
        }
        // A subclass value in a superclass slot: no vtables in V1, so class
        // values are not polymorphic — explain rather than a bare mismatch.
        if (expected == .class_type and actual == .class_type and self.isSubclassOf(actual.class_type, expected.class_type)) {
            const msg2 = std.fmt.allocPrint(self.arena, "class values are not polymorphic — a `{s}` slot cannot hold a `{s}`; declare it as `{s}`, or model the variants as a discriminated union", .{ en, an, an }) catch
                return self.fail(line, col, "E_TYPE_MISMATCH");
            return self.fail(line, col, msg2);
        }
        // A Promise<T> where T was expected is almost always a missing await.
        const forgot_await = actual == .promise_type and types.same(expected, actual.promise_type.*);
        const msg = if (forgot_await)
            std.fmt.allocPrint(self.arena, "type mismatch: expected `{s}`, got `{s}` — did you forget `await`?", .{ en, an }) catch
                return self.fail(line, col, "E_TYPE_MISMATCH")
        else
            std.fmt.allocPrint(self.arena, "type mismatch: expected `{s}`, got `{s}`", .{ en, an }) catch
                return self.fail(line, col, "E_TYPE_MISMATCH");
        return self.fail(line, col, msg);
    }

    pub fn undefined_(self: *Checker, name: []const u8, line: u32, col: u32) CompileError {
        if (self.suggestName(name)) |hint| {
            self.last_err = std.fmt.allocPrint(self.arena, "undefined variable '{s}' — did you mean '{s}'?", .{ name, hint }) catch "undefined variable";
        } else {
            self.last_err = std.fmt.allocPrint(self.arena, "undefined variable '{s}'", .{name}) catch "undefined variable";
        }
        self.last_line = line;
        self.last_col = col;
        return error.ParseError;
    }

    /// Bounded edit distance between two names (insert/delete/substitute cost 1),
    /// giving up early when it must exceed `limit`.
    fn editDistance(a: []const u8, b: []const u8, limit: usize) usize {
        if (a.len > b.len) return editDistance(b, a, limit);
        if (b.len - a.len > limit) return limit + 1;
        var row: [64]usize = undefined;
        if (b.len >= row.len) return limit + 1;
        for (0..a.len + 1) |j| row[j] = j;
        for (b, 0..) |bc, i| {
            var prev = row[0];
            row[0] = i + 1;
            var best = row[0];
            for (a, 0..) |ac, j| {
                const cost: usize = if (ac == bc) 0 else 1;
                const val = @min(@min(row[j + 1] + 1, row[j] + 1), prev + cost);
                prev = row[j + 1];
                row[j + 1] = val;
                if (val < best) best = val;
            }
            if (best > limit) return limit + 1;
        }
        return row[a.len];
    }

    /// Unknown-method diagnostic with a did-you-mean over the receiver's known
    /// method names: "`string` has no method 'toUperCase' — did you mean
    /// 'toUpperCase'?".
    pub fn failUnknownMethod(self: *Checker, line: u32, col: u32, recv: []const u8, name: []const u8, known: []const []const u8) CompileError {
        const limit: usize = if (name.len <= 4) 1 else 2;
        var best: ?[]const u8 = null;
        var best_d: usize = limit + 1;
        for (known) |k| {
            const d = editDistance(name, k, limit);
            if (d < best_d) {
                best_d = d;
                best = k;
            }
        }
        const msg = if (best_d <= limit)
            std.fmt.allocPrint(self.arena, "`{s}` has no method '{s}' — did you mean '{s}'?", .{ recv, name, best.? }) catch "unknown method"
        else
            std.fmt.allocPrint(self.arena, "`{s}` has no method '{s}'", .{ recv, name }) catch "unknown method";
        return self.fail(line, col, msg);
    }

    /// Unknown-field diagnostic: did-you-mean over the type's declared field
    /// names, else the full field list.
    pub fn failUnknownField(self: *Checker, line: u32, col: u32, type_name: []const u8, name: []const u8, known: []const []const u8) CompileError {
        const limit: usize = if (name.len <= 4) 1 else 2;
        var best: ?[]const u8 = null;
        var best_d: usize = limit + 1;
        for (known) |k| {
            const d = editDistance(name, k, limit);
            if (d < best_d) {
                best_d = d;
                best = k;
            }
        }
        if (best_d <= limit) {
            const msg = std.fmt.allocPrint(self.arena, "`{s}` has no property '{s}' — did you mean '{s}'?", .{ type_name, name, best.? }) catch "unknown field";
            return self.fail(line, col, msg);
        }
        var names: std.ArrayListUnmanaged(u8) = .empty;
        for (known, 0..) |k, i| {
            if (i > 0) names.appendSlice(self.arena, ", ") catch {};
            names.appendSlice(self.arena, k) catch {};
        }
        const msg = std.fmt.allocPrint(self.arena, "`{s}` has no property '{s}' — it has: {s}", .{ type_name, name, names.items }) catch "unknown field";
        return self.fail(line, col, msg);
    }

    /// The closest known name to `name` (in-scope bindings, declared functions,
    /// common globals), or null when nothing is close enough to be helpful.
    fn suggestName(self: *Checker, name: []const u8) ?[]const u8 {
        if (name.len < 2) return null;
        // Allow ~1 typo for short names, 2 for longer ones.
        const limit: usize = if (name.len <= 4) 1 else 2;
        var best: ?[]const u8 = null;
        var best_d: usize = limit + 1;
        for (self.scopes.items) |*scope| {
            var it = scope.keyIterator();
            while (it.next()) |k| {
                const d = editDistance(name, k.*, limit);
                if (d < best_d) {
                    best_d = d;
                    best = k.*;
                }
            }
        }
        var fit = self.funcs.keyIterator();
        while (fit.next()) |k| {
            const d = editDistance(name, k.*, limit);
            if (d < best_d) {
                best_d = d;
                best = k.*;
            }
        }
        const globals = [_][]const u8{ "console", "Math", "JSON", "String", "Number", "Boolean", "Array", "Map", "Set", "parseInt", "parseFloat", "isNaN", "isFinite", "true", "false", "null" };
        for (globals) |g| {
            const d = editDistance(name, g, limit);
            if (d < best_d) {
                best_d = d;
                best = g;
            }
        }
        return if (best_d <= limit) best else null;
    }

    pub fn currentScope(self: *Checker) *Scope {
        return &self.scopes.items[self.scopes.items.len - 1];
    }

    pub fn isNarrowed(self: *Checker, name: []const u8) bool {
        for (self.narrowed.items) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }

    /// The variant a union binding is currently narrowed to (innermost wins), or
    /// null if it is not narrowed.
    pub fn narrowedVariant(self: *Checker, name: []const u8) ?[]const u8 {
        var i = self.narrowed_variants.items.len;
        while (i > 0) {
            i -= 1;
            const nv = self.narrowed_variants.items[i];
            if (std.mem.eql(u8, nv.name, name)) return nv.variant;
        }
        return null;
    }

    /// If `cond` is `x != null` / `x !== null` (or undefined) returns the binding
    /// narrowed in the then-branch; `x == null` returns it for the else-branch.
    /// `in_then` says which branch the non-optional narrowing applies to.
    /// The narrowable path of an expression: a plain variable (`x`) or a
    /// field-access chain rooted at one (`x.f`, `a.b.c`, keyed dotted). Any
    /// non-plain segment (index, call, optional-chain) makes it un-narrowable
    /// (re-reading it might not be side-effect-free / stable), so return null.
    pub fn narrowPath(self: *Checker, e: *ast.Expr) ?[]const u8 {
        if (e.* == .var_ref) return e.var_ref.name;
        if (e.* == .this_expr) return "this";
        if (e.* == .field and !e.field.optional_chain) {
            const base = self.narrowPath(e.field.obj) orelse return null;
            return std.fmt.allocPrint(self.arena, "{s}.{s}", .{ base, e.field.name }) catch null;
        }
        return null;
    }

    /// Push every `!= null` (for `&&`) or `== null` (for `||`) narrow target in
    /// `cond`'s operator-chain onto `self.narrowed`, returning how many were
    /// pushed (the caller pops that many). Used so a chain of null-checks all
    /// narrow the operand that follows them (`x != null && y != null && f(x, y)`).
    pub fn collectAndNullChecks(self: *Checker, cond: *ast.Expr, wants_then: bool) usize {
        const chain_op: []const u8 = if (wants_then) "&&" else "||";
        if (cond.* == .bool_bin and std.mem.eql(u8, cond.bool_bin.op, chain_op)) {
            const l = self.collectAndNullChecks(cond.bool_bin.l, wants_then);
            const r = self.collectAndNullChecks(cond.bool_bin.r, wants_then);
            return l + r;
        }
        if (self.narrowTarget(cond)) |nt| {
            if (nt.in_then == wants_then) {
                self.narrowed.append(self.arena, nt.name) catch return 0;
                return 1;
            }
        }
        return 0;
    }

    pub fn narrowTarget(self: *Checker, cond: *ast.Expr) ?struct { name: []const u8, in_then: bool } {
        // `A && B`: a `!= null` null-check in either operand holds in the
        // then-branch (both must be true to enter it), so `if (x != null && ...)`
        // narrows `x` in the body. Only in-then narrowings propagate through `&&`
        // (an else-branch can't tell which operand was false).
        if (cond.* == .bool_bin and std.mem.eql(u8, cond.bool_bin.op, "&&")) {
            if (self.narrowTarget(cond.bool_bin.l)) |nt| {
                if (nt.in_then) return nt;
            }
            if (self.narrowTarget(cond.bool_bin.r)) |nt| {
                if (nt.in_then) return nt;
            }
            return null;
        }
        if (cond.* != .cmp) return null;
        const c = cond.cmp;
        const is_ne = std.mem.eql(u8, c.op, "!=");
        const is_eq = std.mem.eql(u8, c.op, "==");
        if (!is_ne and !is_eq) return null;
        var name: ?[]const u8 = null;
        if (c.r.* == .null_lit) name = self.narrowPath(c.l);
        if (c.l.* == .null_lit) name = self.narrowPath(c.r);
        const n = name orelse return null;
        return .{ .name = n, .in_then = is_ne };
    }

    /// If `expr` is `s.disc` where `s` is a union binding and `disc` is that
    /// union's discriminant field, returns the binding name and union name.
    pub fn discriminantAccess(self: *Checker, expr: *ast.Expr) ?struct { name: []const u8, union_name: []const u8 } {
        if (expr.* != .field) return null;
        const fa = expr.field;
        if (fa.obj.* != .var_ref) return null;
        const var_name = fa.obj.var_ref.name;
        const b = self.binding(var_name) orelse return null;
        if (b.ty != .union_type) return null;
        const uinfo = self.unions.get(b.ty.union_type) orelse return null;
        if (!std.mem.eql(u8, fa.name, uinfo.discriminant)) return null;
        return .{ .name = var_name, .union_name = b.ty.union_type };
    }

    /// The variant of `union_name` selected by discriminant literal `value`.
    /// For a two-variant union, the variant that is NOT `variant`; null for
    /// unions of any other size (no unique complement).
    pub fn otherVariant(self: *Checker, union_name: []const u8, variant: []const u8) ?[]const u8 {
        const uinfo = self.unions.get(union_name) orelse return null;
        if (uinfo.variants.len != 2) return null;
        for (uinfo.variants) |v| {
            if (!std.mem.eql(u8, v.name, variant)) return v.name;
        }
        return null;
    }

    /// Structural width check (spec 278): if every field of record type
    /// `target_name` exists on record type `source_name` with the same type,
    /// returns the target's field names (for building the coercion literal).
    pub fn structuralFields(self: *Checker, target_name: []const u8, source_name: []const u8) ?[]const []const u8 {
        const target = self.type_decls.get(target_name) orelse return null;
        const source = self.type_decls.get(source_name) orelse return null;
        if (target.fields.len == 0) return null;
        const names = self.arena.alloc([]const u8, target.fields.len) catch return null;
        for (target.fields, 0..) |tf, i| {
            const tt = tf.checked_type orelse return null;
            var found = false;
            for (source.fields) |sf| {
                if (std.mem.eql(u8, sf.name, tf.name)) {
                    const st = sf.checked_type orelse return null;
                    if (!types.same(tt, st)) return null;
                    found = true;
                    break;
                }
            }
            if (!found) return null;
            names[i] = tf.name;
        }
        return names;
    }

    pub fn variantForValue(self: *Checker, union_name: []const u8, value: []const u8) ?[]const u8 {
        const uinfo = self.unions.get(union_name) orelse return null;
        for (uinfo.variants) |v| {
            if (std.mem.eql(u8, v.disc_value, value)) return v.name;
        }
        return null;
    }

    pub fn pushScope(self: *Checker) CompileError!void {
        self.scopes.append(self.arena, .empty) catch return error.OutOfMemory;
    }

    pub fn popScope(self: *Checker) void {
        // Warn on `let`/`const` bindings never referenced after declaration.
        // Underscore-prefixed names opt out, matching the common convention.
        var it = self.scopes.items[self.scopes.items.len - 1].iterator();
        while (it.next()) |entry| {
            const b = entry.value_ptr.*;
            if (b.used or b.decl == null) continue;
            const name = entry.key_ptr.*;
            if (name.len > 0 and name[0] == '_') continue;
            const msg = std.fmt.allocPrint(self.arena, "unused variable '{s}'", .{name}) catch continue;
            self.warnings.append(self.arena, .{ .line = b.decl.?.line, .col = b.decl.?.col, .msg = msg }) catch {};
            // Zig rejects unused locals; mark the decl so emission discards it.
            b.decl.?.unused = true;
        }
        self.scopes.items.len -= 1;
    }

    pub fn binding(self: *Checker, name: []const u8) ?Binding {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].getPtr(name)) |found| {
                found.used = true;
                return found.*;
            }
        }
        return null;
    }

    pub fn bindingDepth(self: *Checker, name: []const u8) ?usize {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].get(name) != null) return i;
        }
        return null;
    }

    pub fn bindingPtr(self: *Checker, name: []const u8) ?*Binding {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].getPtr(name)) |found| {
                found.used = true;
                return found;
            }
        }
        return null;
    }

    pub fn freshEmitName(self: *Checker, name: []const u8) CompileError![]const u8 {
        const id = self.next_binding_id;
        self.next_binding_id += 1;
        return std.fmt.allocPrint(self.arena, "__lumen_{d}_{s}", .{ id, name }) catch error.OutOfMemory;
    }

    pub fn declare(self: *Checker, name: []const u8, decl: *ast.VarDecl, ty: types.Type, line: u32, col: u32) CompileError!void {
        const scope = self.currentScope();
        if (scope.get(name) != null) return self.fail(line, col, "E_DUPLICATE_BINDING");
        const emit_name = try self.freshEmitName(name);
        decl.emit_name = emit_name;
        scope.put(self.arena, name, .{ .ty = ty, .mutable = decl.mutable, .decl = decl, .emit_name = emit_name }) catch return error.OutOfMemory;
    }

    pub fn declareParam(self: *Checker, param: ast.FunctionParam, line: u32, col: u32) CompileError!void {
        const scope = self.currentScope();
        if (scope.get(param.name) != null) return self.fail(line, col, "E_DUPLICATE_BINDING");
        const param_type = param.checked_type orelse try self.typeFromAnnotation(param.annotation, line, col);
        scope.put(self.arena, param.name, .{ .ty = param_type, .mutable = true, .emit_name = param.name, .ref_scalar = param.ref_scalar, .is_ref = param.is_ref }) catch return error.OutOfMemory;
    }

    pub fn declareCatch(self: *Checker, stmt: *ast.TryStmt) CompileError!void {
        // Optional catch binding (spec 052): `catch { ... }` binds nothing.
        const name = stmt.catch_name orelse return;
        const scope = self.currentScope();
        if (scope.get(name) != null) return self.fail(stmt.line, stmt.col, "E_DUPLICATE_BINDING");
        const emit_name = try self.freshEmitName(name);
        stmt.catch_emit_name = emit_name;
        scope.put(self.arena, name, .{ .ty = .error_obj, .mutable = false, .emit_name = emit_name }) catch return error.OutOfMemory;
    }

    fn declareType(self: *Checker, name: []const u8, fields: []ast.TypeField, string_literals: ?[][]const u8, int_literals: ?[]i64, line: u32, col: u32) CompileError!void {
        if (self.type_decls.get(name) != null) return self.fail(line, col, "E_DUPLICATE_BINDING");
        self.type_decls.put(self.arena, name, .{ .fields = fields, .string_literals = string_literals, .int_literals = int_literals }) catch return error.OutOfMemory;
    }

    /// Resolve an alias target annotation, following nested aliases up to a depth
    /// bound (cycles fail rather than loop).
    fn resolveAlias(self: *Checker, annotation: []const u8, line: u32, col: u32) CompileError!types.Type {
        var current = annotation;
        var depth: u32 = 0;
        while (self.aliases.get(current)) |next| {
            depth += 1;
            if (depth > 32) return self.fail(line, col, "E_TYPE_MISMATCH"); // alias cycle
            current = next;
        }
        return self.typeFromAnnotation(current, line, col);
    }

    /// Validate a discriminated union: every variant is a declared record sharing
    /// one string-literal discriminant field, and record the variant map plus the
    /// merged flat-struct field set written back onto the declaration.
    fn declareUnion(self: *Checker, decl: *ast.TypeDecl) CompileError!void {
        if (self.type_decls.get(decl.name) != null or self.aliases.get(decl.name) != null or self.unions.get(decl.name) != null) {
            return self.fail(decl.line, decl.col, "E_DUPLICATE_BINDING");
        }
        const variant_names = decl.union_variants orelse return error.ParseError;
        if (variant_names.len < 2) return self.fail(decl.line, decl.col, "E_TYPE_MISMATCH");
        var discriminant: ?[]const u8 = null;
        var variants: std.ArrayListUnmanaged(UnionVariant) = .empty;
        var merged: std.ArrayListUnmanaged(ast.TypeField) = .empty;
        for (variant_names) |vname| {
            const vinfo = self.type_decls.get(vname) orelse return self.fail(decl.line, decl.col, "E_TYPE_MISMATCH");
            if (vinfo.string_literals != null or vinfo.int_literals != null) return self.fail(decl.line, decl.col, "E_TYPE_MISMATCH");
            // Find this variant's discriminant: a field with a string-literal type.
            var disc_field: ?[]const u8 = null;
            var disc_value: ?[]const u8 = null;
            for (self.declFields(vname)) |f| {
                if (f.annotation.len >= 2 and f.annotation[0] == '"' and f.annotation[f.annotation.len - 1] == '"') {
                    if (disc_field != null) return self.fail(decl.line, decl.col, "E_TYPE_MISMATCH"); // ambiguous: two literal fields
                    disc_field = f.name;
                    disc_value = f.annotation[1 .. f.annotation.len - 1];
                }
            }
            const df = disc_field orelse return self.fail(decl.line, decl.col, "E_TYPE_MISMATCH"); // no discriminant
            if (discriminant) |d| {
                if (!std.mem.eql(u8, d, df)) return self.fail(decl.line, decl.col, "E_TYPE_MISMATCH"); // mismatched discriminant field
            } else discriminant = df;
            try variants.append(self.arena, .{ .name = vname, .disc_value = disc_value.? });
            // Merge fields (dedup by name) into the flat struct.
            for (self.declFields(vname)) |f| {
                var present = false;
                for (merged.items) |m| {
                    if (std.mem.eql(u8, m.name, f.name)) present = true;
                }
                if (!present) {
                    try merged.append(self.arena, .{ .name = f.name, .annotation = f.annotation, .checked_type = try self.typeFromAnnotation(f.annotation, decl.line, decl.col) });
                }
            }
        }
        decl.fields = try merged.toOwnedSlice(self.arena);
        self.unions.put(self.arena, decl.name, .{ .variants = try variants.toOwnedSlice(self.arena), .discriminant = discriminant.? }) catch return error.OutOfMemory;
    }

    /// The declared fields of a record type by name (empty if not a record).
    pub fn declFields(self: *Checker, type_name: []const u8) []ast.TypeField {
        if (self.type_decls.get(type_name)) |info| return info.fields;
        return &.{};
    }

    /// Build the record type for a utility type (`Partial<P>`, `Required<P>`,
    /// `Readonly<P>`, `Pick<P, K>`, `Omit<P, K>`) by transforming the fields of a
    /// named source record, registering the result as a synthetic named record
    /// and queuing it for emission (same mechanism as generic specialization).
    /// Returns the synthetic type name.
    pub fn synthUtilityRecord(self: *Checker, base: []const u8, args: []const []const u8, line: u32, col: u32) CompileError![]const u8 {
        // Resolve the source argument to a concrete type; it must be a named
        // record (which itself may be another utility type, so this nests).
        const src_ty = try self.typeFromAnnotation(args[0], line, col);
        if (src_ty != .named) {
            const msg = std.fmt.allocPrint(self.arena, "`{s}<...>` expects a named record type as its first argument", .{base}) catch "utility type needs a record";
            return self.fail(line, col, msg);
        }
        const src_fields = self.declFields(src_ty.named);

        // Cache/mangle by base + every argument (sanitized to an identifier).
        var mangle: std.ArrayListUnmanaged(u8) = .empty;
        mangle.appendSlice(self.arena, "__U_") catch return error.OutOfMemory;
        mangle.appendSlice(self.arena, base) catch return error.OutOfMemory;
        for (args) |a| {
            mangle.append(self.arena, '_') catch return error.OutOfMemory;
            for (a) |ch| mangle.append(self.arena, if (std.ascii.isAlphanumeric(ch)) ch else '_') catch return error.OutOfMemory;
        }
        const mname = mangle.items;
        if (self.type_decls.get(mname) != null) return mname;

        // Pick/Omit take a second argument: a `"a" | "b"` (or single) key set.
        const has_keys = std.mem.eql(u8, base, "Pick") or std.mem.eql(u8, base, "Omit");
        var keys: std.ArrayListUnmanaged([]const u8) = .empty;
        if (has_keys) {
            if (args.len != 2) return self.fail(line, col, "E_TYPE_ARG_COUNT");
            var it = std.mem.splitScalar(u8, args[1], '|');
            while (it.next()) |part| {
                var k = std.mem.trim(u8, part, " ");
                if (k.len >= 2 and (k[0] == '"' or k[0] == '\'')) k = k[1 .. k.len - 1];
                if (k.len > 0) keys.append(self.arena, k) catch return error.OutOfMemory;
            }
        }

        var out: std.ArrayListUnmanaged(ast.TypeField) = .empty;
        for (src_fields) |f| {
            if (has_keys) {
                var found = false;
                for (keys.items) |k| {
                    if (std.mem.eql(u8, k, f.name)) found = true;
                }
                const pick = std.mem.eql(u8, base, "Pick");
                if (pick and !found) continue; // Pick keeps only listed keys
                if (!pick and found) continue; // Omit drops listed keys
            }
            var ann = f.annotation;
            var readonly = f.is_readonly;
            if (std.mem.eql(u8, base, "Partial")) {
                if (!std.mem.endsWith(u8, ann, "?")) ann = std.fmt.allocPrint(self.arena, "{s}?", .{ann}) catch return error.OutOfMemory;
            } else if (std.mem.eql(u8, base, "Required")) {
                if (std.mem.endsWith(u8, ann, "?")) ann = ann[0 .. ann.len - 1];
            } else if (std.mem.eql(u8, base, "Readonly")) {
                readonly = true;
            }
            out.append(self.arena, .{
                .name = f.name,
                .annotation = ann,
                .checked_type = try self.typeFromAnnotation(ann, line, col),
                .is_readonly = readonly,
            }) catch return error.OutOfMemory;
        }
        if (has_keys and out.items.len == 0) {
            const msg = std.fmt.allocPrint(self.arena, "`{s}<{s}, ...>` selected no fields — check the key names", .{ base, src_ty.named }) catch "no fields selected";
            return self.fail(line, col, msg);
        }

        const fields = out.toOwnedSlice(self.arena) catch return error.OutOfMemory;
        self.type_decls.put(self.arena, mname, .{ .fields = fields }) catch return error.OutOfMemory;
        // Queue a `type_decl` statement so the synthetic record emits as a struct.
        const spec = self.arena.create(ast.TypeDecl) catch return error.OutOfMemory;
        spec.* = .{ .name = mname, .fields = fields, .type_params = &.{}, .line = line, .col = col };
        const stmt_ptr = self.arena.create(ast.Stmt) catch return error.OutOfMemory;
        stmt_ptr.* = .{ .type_decl = spec.* };
        self.pending_specializations.append(self.arena, stmt_ptr) catch return error.OutOfMemory;
        return mname;
    }

    /// The declared type of one record field, or null if the type is not a known
    /// record or lacks that field.
    pub fn recordFieldType(self: *Checker, type_name: []const u8, field: []const u8) ?types.Type {
        for (self.declFields(type_name)) |f| {
            if (std.mem.eql(u8, f.name, field)) {
                return f.checked_type orelse (self.typeFromAnnotation(f.annotation, 0, 0) catch null);
            }
        }
        return null;
    }

    /// Whether a record type's field was declared `readonly`.
    pub fn recordFieldReadonly(self: *Checker, type_name: []const u8, field: []const u8) bool {
        for (self.declFields(type_name)) |f| {
            if (std.mem.eql(u8, f.name, field)) return f.is_readonly;
        }
        return false;
    }

    /// Force the root variable of an lvalue path to emit as a mutable (`var`)
    /// binding so the backend can take its address for a by-reference argument.
    pub fn markReassignedRoot(self: *Checker, e: *const ast.Expr) void {
        switch (e.*) {
            .var_ref => |r| if (self.bindingPtr(r.name)) |b| {
                if (b.decl) |d| d.reassigned = true;
            },
            .field => |f| self.markReassignedRoot(f.obj),
            else => {},
        }
    }

    /// Whether an lvalue path's root variable is a mutable binding (a `let`/`var`
    /// or a parameter), so it may be passed by reference.
    pub fn refRootMutable(self: *Checker, e: *const ast.Expr) bool {
        return switch (e.*) {
            .var_ref => |r| if (self.binding(r.name)) |b| b.mutable else false,
            .field => |f| self.refRootMutable(f.obj),
            else => false,
        };
    }

    /// Whether an lvalue path is rooted in a by-reference (`Ref<T>`) parameter, so
    /// writes through it are allowed (the underlying value is mutable in place).
    pub fn refRooted(self: *Checker, e: *const ast.Expr) bool {
        return switch (e.*) {
            .var_ref => |r| if (self.binding(r.name)) |b| b.is_ref else false,
            .field => |f| self.refRooted(f.obj),
            else => false,
        };
    }

    pub fn funcSigType(self: *Checker, finfo: FunctionInfo) CompileError!types.Type {
        const params = self.arena.alloc(types.Type, finfo.params.len) catch return error.OutOfMemory;
        for (finfo.params, 0..) |p, i| params[i] = p.checked_type orelse return error.ParseError;
        const ret_p = self.arena.create(types.Type) catch return error.OutOfMemory;
        ret_p.* = finfo.return_type;
        const sig = self.arena.create(types.FuncSig) catch return error.OutOfMemory;
        sig.* = .{ .params = params, .ret = ret_p };
        return .{ .func_type = sig };
    }

    pub fn typeFromAnnotation(self: *Checker, annotation: []const u8, line: u32, col: u32) CompileError!types.Type {
        // A string-literal member type `"value"` (e.g. a discriminant field) is
        // a single-value string; it erases to `string` for storage and emission.
        if (annotation.len >= 2 and annotation[0] == '"' and annotation[annotation.len - 1] == '"') {
            return .string;
        }
        // Redundant grouping parens `(X)` -> X (spec 297): only when the leading
        // `(` matches the final `)`, so `(i32)=>i32` (a function type, whose `(`
        // closes mid-string) is left for the function-type handler below.
        if (annotation.len >= 2 and annotation[0] == '(' and annotation[annotation.len - 1] == ')') {
            var depth: u32 = 0;
            var matches_last = true;
            for (annotation, 0..) |ch, i| {
                if (ch == '(') depth += 1 else if (ch == ')') {
                    depth -= 1;
                    if (depth == 0 and i != annotation.len - 1) {
                        matches_last = false;
                        break;
                    }
                }
            }
            if (matches_last) return self.typeFromAnnotation(annotation[1 .. annotation.len - 1], line, col);
        }
        // Resolve `type X = <annotation>;` aliases transitively (bounded depth).
        if (self.aliases.get(annotation)) |target| {
            return self.resolveAlias(target, line, col);
        }
        // A discriminated union name resolves to its union type.
        if (self.unions.get(annotation) != null) return .{ .union_type = annotation };
        // `Buffer` (spec 056): a bare built-in type, resolved directly (unlike
        // `ReadableStream`/`WritableStream`, which have no case here today and
        // fall through to a plain `.named` that never matches the real
        // `.readable_stream_type`/`.writable_stream_type` a construction call
        // produces -- verified concretely, not assumed, before adding this).
        if (std.mem.eql(u8, annotation, "Buffer")) return .buffer_type;
        // `Hash`/`Hmac` (spec 060): same bare-type resolution as `Buffer`
        // above, for `let h: Hash = crypto.createHash(...)`-style explicit
        // annotations.
        if (std.mem.eql(u8, annotation, "Hash")) return .hash_type;
        if (std.mem.eql(u8, annotation, "Hmac")) return .hmac_type;
        // Function type: `(T,...)=>R`
        if (annotation.len > 0 and annotation[0] == '(') {
            var depth: u32 = 0;
            var close: usize = 0;
            var found = false;
            for (annotation, 0..) |ch, i| {
                if (ch == '(') {
                    depth += 1;
                } else if (ch == ')') {
                    depth -= 1;
                    if (depth == 0) {
                        close = i;
                        found = true;
                        break;
                    }
                }
            }
            if (found and std.mem.startsWith(u8, annotation[close + 1 ..], "=>")) {
                const params_str = annotation[1..close];
                const ret_str = annotation[close + 3 ..];
                var params: std.ArrayListUnmanaged(types.Type) = .empty;
                if (params_str.len > 0) {
                    var it = std.mem.splitScalar(u8, params_str, ',');
                    while (it.next()) |ps| {
                        try params.append(self.arena, try self.typeFromAnnotation(ps, line, col));
                    }
                }
                const ret_p = self.arena.create(types.Type) catch return error.OutOfMemory;
                ret_p.* = try self.typeFromAnnotation(ret_str, line, col);
                const sig = self.arena.create(types.FuncSig) catch return error.OutOfMemory;
                sig.* = .{ .params = try params.toOwnedSlice(self.arena), .ret = ret_p };
                return .{ .func_type = sig };
            }
        }
        // `keyof P` — the string-literal union of record P's field names (379).
        if (std.mem.startsWith(u8, annotation, "keyof ")) {
            const operand = std.mem.trim(u8, annotation["keyof ".len..], " ");
            // Resolve the operand first so `keyof Pick<P, ...>` (or any utility
            // type) uses the transformed record's fields.
            const op_ty = try self.typeFromAnnotation(operand, line, col);
            const rec = if (op_ty == .named) op_ty.named else operand;
            const fields = self.declFields(rec);
            if (fields.len == 0) {
                const msg = std.fmt.allocPrint(self.arena, "`keyof {s}` expects a record type with fields", .{operand}) catch "keyof needs a record";
                return self.fail(line, col, msg);
            }
            const mname = std.fmt.allocPrint(self.arena, "__keyof_{s}", .{rec}) catch return error.OutOfMemory;
            if (self.type_decls.get(mname) == null) {
                const lits = self.arena.alloc([]const u8, fields.len) catch return error.OutOfMemory;
                for (fields, 0..) |f, i| lits[i] = f.name;
                self.type_decls.put(self.arena, mname, .{ .fields = &.{}, .string_literals = lits }) catch return error.OutOfMemory;
            }
            return .{ .string_literal_union = mname };
        }
        // Indexed-access type `P["field"]` — the declared type of that field (379).
        if (std.mem.endsWith(u8, annotation, "\"]")) {
            if (std.mem.indexOf(u8, annotation, "[\"")) |bi| {
                const base_ann = annotation[0..bi];
                const field = annotation[bi + 2 .. annotation.len - 2];
                const base_ty = try self.typeFromAnnotation(base_ann, line, col);
                const rec = if (base_ty == .named) base_ty.named else base_ann;
                if (self.recordFieldType(rec, field)) |ft| return ft;
                const msg = std.fmt.allocPrint(self.arena, "`{s}[\"{s}\"]`: `{s}` has no field '{s}'", .{ base_ann, field, base_ann, field }) catch "unknown indexed field";
                return self.fail(line, col, msg);
            }
        }
        if (std.mem.endsWith(u8, annotation, "?")) {
            const inner = try self.typeFromAnnotation(annotation[0 .. annotation.len - 1], line, col);
            const p = self.arena.create(types.Type) catch return error.OutOfMemory;
            p.* = inner;
            return .{ .optional = p };
        }
        // General array suffix `T[]` (spec 296): strip one `[]`, resolve the
        // element, and wrap it. Runs after the function-type check above so a
        // function returning an array (`(i32)=>i32[]`) isn't misread. Handles
        // every element kind — scalars/named via `arrayOf`, and arrays (289),
        // tuples (291), and optionals (296) via a heap-allocated inner Type.
        if (std.mem.endsWith(u8, annotation, "[]")) {
            const base_ty = try self.typeFromAnnotation(annotation[0 .. annotation.len - 2], line, col);
            return (types.arrayOfAlloc(self.arena, base_ty) catch return error.OutOfMemory) orelse
                self.fail(line, col, "E_TYPE_MISMATCH");
        }
        // Tuple type `[A, B, ...]` — a bracketed, comma-separated positional list.
        // (Array element annotations end with `[]` and are handled by
        // fromAnnotation, so a leading `[` with matching `]` is always a tuple.)
        if (annotation.len >= 2 and annotation[0] == '[' and annotation[annotation.len - 1] == ']') {
            const inner = annotation[1 .. annotation.len - 1];
            const parts = try self.splitTypeArgs(inner, line, col);
            if (parts.len == 0) return self.fail(line, col, "E_TYPE_MISMATCH");
            const elems = self.arena.alloc(types.Type, parts.len) catch return error.OutOfMemory;
            for (parts, 0..) |p, i| elems[i] = try self.typeFromAnnotation(p, line, col);
            return .{ .tuple_type = elems };
        }
        // Generic type reference `Name<arg, ...>` (interface or class). Specialize
        // the template on demand and resolve to the concrete named/class type.
        if (std.mem.indexOfScalar(u8, annotation, '<')) |lt| {
            if (std.mem.endsWith(u8, annotation, ">")) {
                const base = annotation[0..lt];
                const args = try self.splitTypeArgs(annotation[lt + 1 .. annotation.len - 1], line, col);
                // Built-in generic containers Map<K,V> and Set<T>.
                if (std.mem.eql(u8, base, "Map")) {
                    if (args.len != 2) return self.fail(line, col, "E_TYPE_ARG_COUNT");
                    const k = self.arena.create(types.Type) catch return error.OutOfMemory;
                    const v = self.arena.create(types.Type) catch return error.OutOfMemory;
                    k.* = try self.typeFromAnnotation(args[0], line, col);
                    v.* = try self.typeFromAnnotation(args[1], line, col);
                    const m = self.arena.create(types.MapType) catch return error.OutOfMemory;
                    m.* = .{ .key = k, .value = v };
                    return .{ .map_type = m };
                }
                if (std.mem.eql(u8, base, "Set")) {
                    if (args.len != 1) return self.fail(line, col, "E_TYPE_ARG_COUNT");
                    const e = self.arena.create(types.Type) catch return error.OutOfMemory;
                    e.* = try self.typeFromAnnotation(args[0], line, col);
                    return .{ .set_type = e };
                }
                if (std.mem.eql(u8, base, "Promise")) {
                    if (args.len != 1) return self.fail(line, col, "E_TYPE_ARG_COUNT");
                    const e = self.arena.create(types.Type) catch return error.OutOfMemory;
                    e.* = try self.typeFromAnnotation(args[0], line, col);
                    return .{ .promise_type = e };
                }
                if (self.generic_types.get(base)) |gt| {
                    if (args.len != gt.type_params.len) return self.fail(line, col, "E_TYPE_ARG_COUNT");
                    const mname = try self.specializeType(gt, args, line, col);
                    return .{ .named = mname };
                }
                if (self.generic_classes.get(base)) |gc| {
                    if (args.len != gc.type_params.len) return self.fail(line, col, "E_TYPE_ARG_COUNT");
                    const mname = try self.specializeClass(gc, args, line, col);
                    return .{ .class_type = mname };
                }
                if (std.mem.eql(u8, base, "Record")) {
                    return self.fail(line, col, "Record<K, V> is not supported — use `Map<K, V>` for dynamic key/value storage, or a named `type` with fixed fields");
                }
                if (std.mem.eql(u8, base, "Partial") or std.mem.eql(u8, base, "Readonly") or std.mem.eql(u8, base, "Required") or std.mem.eql(u8, base, "Pick") or std.mem.eql(u8, base, "Omit")) {
                    // Transform a named record's fields at compile time (spec 378).
                    const mname = try self.synthUtilityRecord(base, args, line, col);
                    return .{ .named = mname };
                }
                return self.fail(line, col, "unknown generic type");
            }
        }
        if (self.enums.get(annotation)) |einfo| {
            return .{ .enum_type = .{ .name = annotation, .is_string = einfo.is_string } };
        }
        if (self.classes.get(annotation) != null) {
            return .{ .class_type = annotation };
        }
        if (self.type_decls.get(annotation)) |decl| {
            if (decl.string_literals != null) return .{ .string_literal_union = annotation };
            if (decl.int_literals != null) return .{ .int_literal_union = annotation };
        }
        return types.fromAnnotation(annotation);
    }

    /// Resolve a function/method parameter annotation, intercepting the built-in
    /// by-reference marker `Ref<T>` before the generics machinery treats `Ref` as
    /// a user generic. A `Ref<T>` parameter type-checks as `T` (its `checked_type`
    /// is the inner type) but is passed by single pointer; the inner type must be
    /// a value type (record/interface, scalar, union, enum, or tuple). Classes,
    /// arrays, strings, maps, sets, and promises are already reference-like and
    /// are rejected. A rest `Ref<T>[]` is not supported.
    fn resolveParam(self: *Checker, param: *ast.FunctionParam, line: u32, col: u32) CompileError!void {
        if (refInner(param.annotation)) |inner_ann| {
            if (param.is_rest) return self.fail(line, col, "E_REF_TARGET");
            const inner = try self.typeFromAnnotation(inner_ann, line, col);
            if (inner == .class_type) return self.fail(line, col, "E_REF_TARGET");
            if (!types.isRefAllowed(inner)) return self.fail(line, col, "E_REF_TARGET");
            param.is_ref = true;
            param.ref_scalar = types.isRefScalar(inner);
            param.checked_type = inner;
            return;
        }
        param.checked_type = try self.typeFromAnnotation(param.annotation, line, col);
    }

    pub fn declareFunction(self: *Checker, program: ?*ast.Program, decl: *ast.FunctionDecl) CompileError!void {
        if (self.funcs.get(decl.name) != null) return self.fail(decl.line, decl.col, "E_DUPLICATE_BINDING");
        var return_type = try self.typeFromAnnotation(decl.return_annotation, decl.line, decl.col);
        // An async function must declare a `Promise<T>` return type.
        if (decl.is_async and return_type != .promise_type) return self.fail(decl.line, decl.col, "E_ASYNC_RETURN");
        for (decl.params) |*param| {
            try self.resolveParam(param, decl.line, decl.col);
        }
        try self.validateParamSignature(decl.params);
        // Infer an omitted return type from the body's first `return <expr>`, so
        // a plain function need not annotate it (`function add(a, b) { return a
        // + b; }`). Async functions still require an explicit `Promise<...>`.
        // Runs in the declaration pass, before any body or call site is checked,
        // so callers observe the inferred type. If inference cannot determine a
        // type (e.g. a forward-referenced callee), the type stays `void` and the
        // body check surfaces the real diagnostic.
        if (program) |prog| {
            if (decl.infer_return and !decl.is_async) {
                if (check_stmt.firstReturnExpr(decl.body)) |rexpr| {
                    try self.pushScope();
                    defer self.popScope();
                    for (decl.params) |param| self.declareParam(param, decl.line, decl.col) catch {};
                    if (self.exprType(prog, rexpr, decl.line, decl.col)) |inferred| {
                        if (inferred != .void) return_type = inferred;
                    }
                }
            }
        }
        decl.checked_return_type = return_type;
        self.funcs.put(self.arena, decl.name, .{ .params = decl.params, .return_type = return_type }) catch return error.OutOfMemory;
    }

    /// Validates structural default-value and rest-parameter rules over a resolved
    /// parameter list: a rest param must be the last and array-typed; once a
    /// parameter has a default, every following non-rest parameter must also have
    /// one. Default-value *types* are checked later in checkFunctionBody (where the
    /// program context is available).
    fn validateParamSignature(self: *Checker, params: []ast.FunctionParam) CompileError!void {
        var seen_default = false;
        for (params, 0..) |*param, i| {
            if (param.is_rest) {
                if (i != params.len - 1) return self.fail(0, 0, "E_REST_NOT_LAST");
                const pt = param.checked_type orelse return self.fail(0, 0, "E_TYPE_MISMATCH");
                if (!types.isArray(pt)) return self.fail(0, 0, "E_REST_NOT_ARRAY");
                continue;
            }
            if (param.default != null or param.is_optional) {
                seen_default = true;
            } else if (seen_default) {
                // A required parameter after an optional one is not allowed.
                return self.fail(0, 0, "E_REQUIRED_AFTER_OPTIONAL");
            }
        }
    }

    /// Validates a call's arguments against a parameter list that may include
    /// defaults and a trailing rest parameter, and returns a normalized argument
    /// slice with exactly one entry per parameter (defaults filled in, rest
    /// collected into an array literal). Spread arguments (`...src`) are only
    /// permitted feeding a rest parameter. Returns null after recording a
    /// diagnostic on any mismatch.
    fn plural(n: usize) []const u8 {
        return if (n == 1) "" else "s";
    }

    /// A non-boolean condition (`if (n)`, `while (s)`, ...): truthiness is not
    /// part of the language, so name the construct and suggest the explicit
    /// comparison matching the value's type.
    pub fn failCondition(self: *Checker, line: u32, col: u32, construct: []const u8, cond_type: types.Type) CompileError {
        const tn = types.tsName(self.arena, cond_type) catch return self.fail(line, col, "E_TYPE_MISMATCH");
        const hint: []const u8 = switch (cond_type) {
            .optional => "`x != null`",
            .string, .string_literal_union => "`s != \"\"` or `s.length > 0`",
            else => if (types.isNumeric(cond_type)) "`x != 0`" else if (types.isArray(cond_type)) "`a.length > 0`" else "an explicit comparison",
        };
        const msg = std.fmt.allocPrint(self.arena, "{s} condition must be `boolean`, got `{s}` — truthiness is not supported; write {s}", .{ construct, tn, hint }) catch
            return self.fail(line, col, "E_TYPE_MISMATCH");
        return self.fail(line, col, msg);
    }

    pub fn checkCallArgs(self: *Checker, program: *ast.Program, callee: []const u8, params: []const ast.FunctionParam, args: []const *ast.Expr, line: u32, col: u32) ?[]*ast.Expr {
        // Expand a fixed-tuple spread into positional element accesses:
        // `f(...args)` where `args: [A, B]` becomes `f(args[0], args[1])`, so a
        // tuple can feed exactly-matching positional parameters. Non-tuple
        // spreads (into a rest parameter) are left for the normal path.
        for (args) |a| {
            if (a.* == .spread) {
                const st = self.exprType(program, a.spread, line, col) orelse continue;
                if (st == .tuple_type) {
                    var expanded: std.ArrayListUnmanaged(*ast.Expr) = .empty;
                    for (args) |b| {
                        if (b.* == .spread) {
                            const bt = self.exprType(program, b.spread, line, col);
                            if (bt != null and bt.? == .tuple_type) {
                                for (0..bt.?.tuple_type.len) |i| {
                                    const iv = self.arena.create(ast.Expr) catch return null;
                                    iv.* = .{ .num = @intCast(i) };
                                    const idx = self.arena.create(ast.Expr) catch return null;
                                    idx.* = .{ .index = .{ .obj = b.spread, .value = iv } };
                                    expanded.append(self.arena, idx) catch return null;
                                }
                                continue;
                            }
                        }
                        expanded.append(self.arena, b) catch return null;
                    }
                    return self.checkCallArgs(program, callee, params, expanded.toOwnedSlice(self.arena) catch return null, line, col);
                }
            }
        }
        const has_rest = params.len > 0 and params[params.len - 1].is_rest;
        const fixed_count = if (has_rest) params.len - 1 else params.len;

        // Minimum required positional args: fixed params without a default that
        // are not optional (`x?: T`, which may be omitted and filled with null).
        var required: usize = 0;
        for (params[0..fixed_count]) |p| {
            if (p.default == null and !p.is_optional) required += 1;
        }

        // A spread argument is only valid when it lands in the rest slot.
        for (args, 0..) |a, i| {
            if (a.* == .spread and !(has_rest and i >= fixed_count)) {
                _ = self.fail(line, col, "E_SPREAD_TARGET") catch {};
                return null;
            }
        }

        if (args.len < required or (!has_rest and args.len > fixed_count)) {
            // "expects 2 arguments", "expects 1-3 arguments" (defaults/optionals),
            // "expects at least 1 argument" (rest param).
            const expected: []const u8 = blk: {
                if (has_rest) break :blk std.fmt.allocPrint(self.arena, "at least {d} argument{s}", .{ required, plural(required) }) catch "";
                if (required == fixed_count) break :blk std.fmt.allocPrint(self.arena, "{d} argument{s}", .{ required, plural(required) }) catch "";
                break :blk std.fmt.allocPrint(self.arena, "{d}-{d} arguments", .{ required, fixed_count }) catch "";
            };
            const msg = std.fmt.allocPrint(self.arena, "{s} expects {s}, got {d}", .{ callee, expected, args.len }) catch "E_ARG_COUNT";
            _ = self.fail(line, col, msg) catch {};
            return null;
        }

        var out: std.ArrayListUnmanaged(*ast.Expr) = .empty;

        // Fixed parameters: use the positional arg or fall back to the default.
        for (params[0..fixed_count], 0..) |p, i| {
            const pt = p.checked_type orelse {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            };
            if (i < args.len) {
                self.ensureAssignable(program, pt, args[i], line, col) catch {
                    return null;
                };
                out.append(self.arena, args[i]) catch return null;
            } else if (p.default) |d| {
                out.append(self.arena, d) catch return null;
            } else {
                // An omitted optional parameter (`x?: T`) is filled with null;
                // its checked type is the optional `T | null`.
                const null_expr = self.arena.create(ast.Expr) catch return null;
                null_expr.* = .{ .null_lit = {} };
                out.append(self.arena, null_expr) catch return null;
            }
        }

        if (has_rest) {
            const rest_param = params[params.len - 1];
            const rest_type = rest_param.checked_type orelse {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            };
            const elem_type = types.arrayElem(rest_type) orelse {
                _ = self.fail(line, col, "E_TYPE_MISMATCH") catch {};
                return null;
            };
            const rest_args = args[fixed_count..];
            // Build an array literal node from the trailing args; spread entries
            // carry their array source, plain entries their element value.
            const items = self.arena.alloc(*ast.Expr, rest_args.len) catch return null;
            var has_spread = false;
            for (rest_args, 0..) |a, i| {
                if (a.* == .spread) {
                    has_spread = true;
                    // `f(...set)` / `f(...str)`: rewrite the spread source to
                    // `Array.from(x)` so a Set's values / a string's chars feed
                    // the rest parameter like any array.
                    const sp_type = self.exprType(program, a.spread, line, col) orelse return null;
                    if (sp_type == .set_type or types.isStringLike(sp_type)) {
                        const from_call = self.arena.create(ast.Expr) catch return null;
                        const from_args = self.arena.alloc(*ast.Expr, 1) catch return null;
                        from_args[0] = a.spread;
                        from_call.* = .{ .static_call = .{ .namespace = "Array", .name = "from", .args = from_args } };
                        a.spread = from_call;
                    }
                    self.ensureAssignable(program, rest_type, a.spread, line, col) catch {
                        return null;
                    };
                } else {
                    self.ensureAssignable(program, elem_type, a, line, col) catch {
                        return null;
                    };
                }
                items[i] = a;
            }
            const arr_node = self.arena.create(ast.Expr) catch return null;
            // Use the runtime-concat form (carry elem_type) when spreading or when
            // empty, so the slice gets an explicit element type Zig can coerce.
            const need_typed = has_spread or rest_args.len == 0;
            arr_node.* = .{ .array = .{
                .items = items,
                .elem_type = if (need_typed) elem_type else null,
                // A spread-free gathered rest array still heap-allocates so it
                // can safely escape (e.g. a callee that returns it).
                .heap_elem = if (need_typed) null else elem_type,
            } };
            out.append(self.arena, arr_node) catch return null;
        }

        return out.toOwnedSlice(self.arena) catch return null;
    }

    fn checkProgram(self: *Checker, program: *ast.Program) CompileError!void {
        self.cur_program = program;
        try self.pushScope();
        // Pop the root scope on the way out so top-level unused-variable
        // warnings are collected like any other scope's.
        defer self.popScope();
        // `__LumenHttpRequest`/`__LumenHttpResponse` are registered eagerly,
        // unconditionally, rather than lazily when `http.createServer`'s call
        // site is checked (the way every other record-returning builtin's
        // type gets registered): `http.createServer`'s handler needs an
        // explicit parameter type annotation naming `__LumenHttpRequest`,
        // and that annotation is checked wherever the handler function is
        // declared -- which can be textually *before* the `createServer`
        // call that would otherwise register the type. No other
        // record-returning builtin hits this, since their types are only
        // ever used as an inferred return value, never as a named parameter
        // type that has to resolve before its registering call site is
        // reached. Registering both eagerly costs nothing when `http` isn't
        // used at all.
        check_stdlib.registerLumenHttpRequest(self) orelse {};
        check_stdlib.registerLumenHttpResponse(self) orelse {};
        // Clean, writable aliases for the two names above -- an
        // `http.createServer` handler needs to name its parameter/return
        // types explicitly, and asking users to write the internal
        // double-underscore name directly would be a real rough edge.
        self.aliases.put(self.arena, "HttpRequest", "__LumenHttpRequest") catch {};
        self.aliases.put(self.arena, "HttpResponse", "__LumenHttpResponse") catch {};
        for (program.stmts) |*stmt| {
            if (stmt.* == .type_decl) {
                if (stmt.type_decl.type_params.len > 0) {
                    if (self.generic_types.get(stmt.type_decl.name) != null) return self.fail(stmt.type_decl.line, stmt.type_decl.col, "E_DUPLICATE_BINDING");
                    self.generic_types.put(self.arena, stmt.type_decl.name, &stmt.type_decl) catch return error.OutOfMemory;
                    continue;
                }
                if (stmt.type_decl.alias) |target| {
                    if (self.aliases.get(stmt.type_decl.name) != null or self.type_decls.get(stmt.type_decl.name) != null) return self.fail(stmt.type_decl.line, stmt.type_decl.col, "E_DUPLICATE_BINDING");
                    self.aliases.put(self.arena, stmt.type_decl.name, target) catch return error.OutOfMemory;
                    continue;
                }
                if (stmt.type_decl.union_variants != null) continue; // validated in the union pass below
                // `interface B extends A, C` — merge the parents' fields ahead of
                // B's own (declared earlier in source order, so already
                // registered). A field B redeclares overrides the inherited one.
                if (stmt.type_decl.parents.len > 0) {
                    var merged: std.ArrayListUnmanaged(ast.TypeField) = .empty;
                    for (stmt.type_decl.parents) |pname| {
                        const pinfo = self.type_decls.get(pname) orelse {
                            const msg = std.fmt.allocPrint(self.arena, "`{s}` references `{s}`, but `{s}` is not a known interface or record type", .{ stmt.type_decl.name, pname, pname }) catch "E_TYPE_MISMATCH";
                            return self.fail(stmt.type_decl.line, stmt.type_decl.col, msg);
                        };
                        for (pinfo.fields) |pf| {
                            var overridden = false;
                            for (stmt.type_decl.fields) |own| {
                                if (std.mem.eql(u8, own.name, pf.name)) {
                                    overridden = true;
                                    break;
                                }
                            }
                            if (!overridden) merged.append(self.arena, pf) catch return error.OutOfMemory;
                        }
                    }
                    for (stmt.type_decl.fields) |f| merged.append(self.arena, f) catch return error.OutOfMemory;
                    stmt.type_decl.fields = merged.toOwnedSlice(self.arena) catch return error.OutOfMemory;
                }
                try self.declareType(stmt.type_decl.name, stmt.type_decl.fields, stmt.type_decl.string_literals, stmt.type_decl.int_literals, stmt.type_decl.line, stmt.type_decl.col);
            }
        }
        // Union pass: variants must already be declared records sharing a single
        // string-literal discriminant field. Build the merged flat-struct fields.
        for (program.stmts) |*stmt| {
            if (stmt.* == .type_decl and stmt.type_decl.union_variants != null) {
                try self.declareUnion(&stmt.type_decl);
            }
        }
        for (program.stmts) |*stmt| {
            if (stmt.* == .enum_decl) {
                const e = stmt.enum_decl;
                if (self.enums.get(e.name) != null or self.type_decls.get(e.name) != null) return self.fail(e.line, e.col, "E_DUPLICATE_BINDING");
                self.enums.put(self.arena, e.name, .{ .is_string = e.is_string, .members = e.members }) catch return error.OutOfMemory;
            }
        }
        // Register class names (pass A) so cross-references resolve, then fill
        // field/method/constructor types (pass B).
        for (program.stmts) |*stmt| {
            if (stmt.* == .class_decl) {
                const c = &stmt.class_decl;
                if (c.type_params.len > 0) {
                    if (self.generic_classes.get(c.name) != null) return self.fail(c.line, c.col, "E_DUPLICATE_BINDING");
                    self.generic_classes.put(self.arena, c.name, c) catch return error.OutOfMemory;
                    continue;
                }
                if (self.classes.get(c.name) != null) return self.fail(c.line, c.col, "E_DUPLICATE_BINDING");
                self.classes.put(self.arena, c.name, .{ .fields = c.fields, .methods = c.methods, .ctor_params = c.ctor_params, .has_ctor = c.has_ctor, .parent = c.parent }) catch return error.OutOfMemory;
            }
        }
        for (program.stmts) |*stmt| {
            if (stmt.* == .class_decl and stmt.class_decl.type_params.len == 0) try self.fillClassTypes(program, &stmt.class_decl);
        }
        for (program.stmts) |*stmt| {
            if (stmt.* == .extern_decl) try self.declareExtern(&stmt.extern_decl);
        }
        for (program.stmts) |*stmt| {
            if (stmt.* == .function_decl) {
                if (stmt.function_decl.type_params.len > 0) {
                    if (self.generic_funcs.get(stmt.function_decl.name) != null or self.funcs.get(stmt.function_decl.name) != null) return self.fail(stmt.function_decl.line, stmt.function_decl.col, "E_DUPLICATE_BINDING");
                    self.generic_funcs.put(self.arena, stmt.function_decl.name, &stmt.function_decl) catch return error.OutOfMemory;
                    continue;
                }
                try self.declareFunction(program, &stmt.function_decl);
            }
        }
        for (program.stmts) |*stmt| {
            if (self.isGenericTemplateStmt(stmt)) continue;
            self.checkStmt(program, stmt) catch |e| {
                if (e == error.OutOfMemory) return e;
                self.recordDiag();
                // Stop collecting past the cap; later errors are likely cascades.
                if (self.all_diags.items.len >= 5) break;
            };
        }
        if (self.all_diags.items.len > 0) return error.ParseError;
        // Specializations discovered while checking may themselves reference more
        // generics, so drain the worklist until it stops growing. Each entry is a
        // stable heap pointer, so appending more during a check is safe.
        var i: usize = 0;
        while (i < self.pending_specializations.items.len) : (i += 1) {
            try self.checkStmt(program, self.pending_specializations.items[i]);
        }
        // Append the concrete specializations so the emitter outputs them.
        for (self.pending_specializations.items) |spec| {
            program.stmts = self.appendStmt(program.stmts, spec.*) catch return error.OutOfMemory;
        }
        // Escape analysis (spec 344): mark non-escaping `new C(...)` locals for
        // stack allocation. Runs last, after all method return types (including
        // specializations) are resolved.
        @import("lumen_escape.zig").analyze(self, program);
    }

    /// True for a generic template declaration (skipped by the main check loop
    /// and the emitter; only its specializations are checked/emitted).
    pub fn fillClassTypes(self: *Checker, program: ?*ast.Program, c: *ast.ClassDecl) CompileError!void {
        for (c.fields) |*field| {
            if (field.annotation.len == 0) {
                // `count = 0` — infer the field type from its initializer. During
                // a generic specialization (no `program`), fall back to the
                // lightweight literal/structural inference.
                if (field.init) |ie| {
                    const inferred = if (program) |prog|
                        self.exprType(prog, ie, c.line, c.col)
                    else
                        types.inferExprType(ie);
                    field.checked_type = inferred orelse
                        return self.fail(c.line, c.col, "cannot infer this field's type — add an annotation (`x: T`)");
                    continue;
                }
                return self.fail(c.line, c.col, "cannot infer this field's type — add an annotation (`x: T`)");
            }
            field.checked_type = try self.typeFromAnnotation(field.annotation, c.line, c.col);
        }
        for (c.ctor_params) |*param| {
            // Constructor params become fields; by-reference params are not
            // storable as fields, so reject `Ref<T>` here.
            if (refInner(param.annotation) != null) return self.fail(c.line, c.col, "E_REF_TARGET");
            param.checked_type = try self.typeFromAnnotation(param.annotation, c.line, c.col);
        }
        for (c.methods) |*m| {
            for (m.params) |*param| try self.resolveParam(param, m.line, m.col);
            var ret = try self.typeFromAnnotation(m.return_annotation, m.line, m.col);
            // Infer an omitted method return type from the body's first value
            // `return <expr>` (params in scope), the same as free functions
            // (spec 310). A `this`-based return is not inferable here (the class
            // fields aren't queryable yet) and falls to the annotate-guidance.
            if (m.infer_return and !m.is_async and ret == .void) {
                if (check_stmt.firstReturnExpr(m.body)) |rexpr| {
                    // A getter-style `return this.<field>` resolves against the
                    // class's own fields directly (no expression typing needed).
                    if (thisFieldType(c, rexpr)) |ft| {
                        ret = ft;
                    } else if (program orelse self.cur_program) |prog| {
                        // General inference: type the return expression with the
                        // parameters in scope and `this` bound to this class, so
                        // returns built from params or `this.<field>` expressions
                        // (`this.items[0]`, `this.a + this.b`) infer -- including
                        // in generic specializations (via `cur_program`).
                        const prev_class = self.current_class;
                        self.current_class = c.name;
                        defer self.current_class = prev_class;
                        try self.pushScope();
                        defer self.popScope();
                        for (m.params) |param| self.declareParam(param, m.line, m.col) catch {};
                        if (self.exprType(prog, rexpr, m.line, m.col)) |inferred| {
                            if (inferred != .void) ret = inferred;
                        }
                    }
                }
            }
            m.checked_return_type = ret;
        }
    }

    pub const ResolvedField = struct { field: ast.TypeField, owner: []const u8 };
    pub const ResolvedMethod = struct { method: ast.FunctionDecl, owner: []const u8 };

    pub fn makeFuncType(self: *Checker, params: []const types.Type, ret: types.Type) ?types.Type {
        const ps = self.arena.alloc(types.Type, params.len) catch return null;
        for (params, 0..) |p, i| ps[i] = p;
        const ret_p = self.arena.create(types.Type) catch return null;
        ret_p.* = ret;
        const sig = self.arena.create(types.FuncSig) catch return null;
        sig.* = .{ .params = ps, .ret = ret_p };
        return .{ .func_type = sig };
    }
};

/// Types allowed in extern function signatures: C-ABI scalars plus `string`,
/// which is marshalled to/from a NUL-terminated C `const char*` at the call
/// boundary. Arrays, records, and function types remain rejected (E_FFI_TYPE).
/// If `annotation` is the by-reference marker `Ref<T>`, returns the inner `T`
/// annotation (trimmed); otherwise null. `Ref` is reserved as a built-in marker,
/// so it is matched here before the generics machinery resolves type references.
/// The declared type of `this.<field>` for a class's own fields or property
/// constructor params, or null when `expr` is not such a field access. Used to
/// infer a getter-style method's return type before `this` is in scope.
fn thisFieldType(c: *const ast.ClassDecl, expr: *const ast.Expr) ?types.Type {
    if (expr.* != .field) return null;
    const fa = expr.field;
    if (fa.obj.* != .this_expr) return null;
    for (c.fields) |f| {
        if (std.mem.eql(u8, f.name, fa.name)) return f.checked_type;
    }
    for (c.ctor_params) |p| {
        if (p.is_property and std.mem.eql(u8, p.name, fa.name)) return p.checked_type;
    }
    return null;
}

pub fn refInner(annotation: []const u8) ?[]const u8 {
    const a = std.mem.trim(u8, annotation, " ");
    if (!std.mem.startsWith(u8, a, "Ref<")) return null;
    if (!std.mem.endsWith(u8, a, ">")) return null;
    const inner = a["Ref<".len .. a.len - 1];
    return std.mem.trim(u8, inner, " ");
}

/// Whether an expression is an addressable lvalue eligible to be passed to a
/// by-reference (`Ref<T>`) parameter: a plain variable, or a field path rooted in
/// one (`obj.field`, `obj.a.b`). Literals, temporaries, and computed expressions
/// are rejected.
pub fn isAddressable(e: *const ast.Expr) bool {
    return switch (e.*) {
        .var_ref => true,
        .field => |f| f.enum_value == null and f.builtin == null and !f.is_static and !f.optional_chain and isAddressable(f.obj),
        else => false,
    };
}

pub fn isCSafe(t: types.Type) bool {
    return switch (t) {
        .i32, .i64, .f64, .bool, .string => true,
        else => false,
    };
}

pub fn findField(fields: []ast.FieldInit, name: []const u8) ?ast.FieldInit {
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, name)) return field;
    }
    return null;
}

pub fn checkProgram(arena: std.mem.Allocator, program: *ast.Program, diag: *Diag, warnings: ?*std.ArrayListUnmanaged(Diag)) CompileError!void {
    var checker = Checker{ .arena = arena };
    defer if (warnings) |w| {
        w.appendSlice(arena, checker.warnings.items) catch {};
    };
    checker.checkProgram(program) catch |e| {
        if (checker.all_diags.items.len > 0) {
            const first = checker.all_diags.items[0];
            diag.* = .{ .line = first.line, .col = first.col, .msg = first.msg, .extra = checker.all_diags.items[1..] };
        } else {
            diag.* = .{ .line = checker.last_line, .col = checker.last_col, .msg = checker.last_err };
        }
        return e;
    };
}
