//! The Abstract Syntax Tree -- the data structure shared by the parser, the
//! checker, and the codegen.
//!
//! This file is pure data: node definitions, no logic. The pipeline uses it like a
//! relay baton:
//!   * the parser (in `lumen_compiler.zig`) builds these nodes from tokens;
//!   * the checker (`lumen_check.zig`) walks them and fills in the resolved-type
//!     fields -- the `?types.Type` fields you see scattered on many nodes -- so the
//!     codegen does not have to re-derive types;
//!   * the codegen (`lumen_compiler.zig`) reads the now-typed nodes to emit Zig.
//!
//! The three central types are `Expr` (expressions), `Stmt` (statements), and
//! `Program` (a whole file). `Expr` and `Stmt` are closed `union(enum)`s, so
//! adding a variant makes every exhaustive `switch` over them fail to compile until
//! it is handled -- a deliberate, very useful to-do list when adding a feature.

const types = @import("lumen_types.zig");

/// An object-literal entry. A normal field has a `name`; a spread entry
/// (`{...src}`) has `is_spread = true`, `name = ""`, and `value` is the source.
pub const FieldInit = struct { name: []const u8, value: *Expr, is_spread: bool = false };

pub const Visibility = enum { public, private, protected };

pub const TypeField = struct {
    name: []const u8,
    annotation: []const u8,
    checked_type: ?types.Type = null,
    visibility: Visibility = .public,
    is_static: bool = false,
    is_readonly: bool = false,
};

pub const EnumValue = union(enum) { int: i64, str: []const u8 };

pub const EnumMember = struct {
    name: []const u8,
    int_value: i64 = 0,
    str_value: ?[]const u8 = null,
};

pub const EnumDecl = struct {
    name: []const u8,
    is_string: bool = false,
    members: []EnumMember,
    line: u32,
    col: u32,
};

pub const TypeDecl = struct {
    name: []const u8,
    fields: []TypeField = &.{},
    string_literals: ?[][]const u8 = null,
    int_literals: ?[]i64 = null,
    // `type X = <annotation>;` — an alias over an existing spellable type.
    alias: ?[]const u8 = null,
    // `type U = A | B | C;` — a discriminated union over named record variants.
    union_variants: ?[][]const u8 = null,
    // Type parameters for a generic interface/type alias, e.g. `Pair<A, B>`.
    // When non-empty the declaration is a template specialized on use.
    type_params: [][]const u8 = &.{},
    line: u32,
    col: u32,
};

pub const FunctionParam = struct {
    name: []const u8,
    annotation: []const u8,
    checked_type: ?types.Type = null,
    // `...rest: T[]` — collects trailing arguments into an array. The annotation
    // names the array type; `checked_type` holds the array type.
    is_rest: bool = false,
    // `x: T = expr` — default value used when the call omits this trailing arg.
    default: ?*Expr = null,
    // `x?: T` — an optional parameter: it may be omitted at the call site (filled
    // with `null`), distinct from a required parameter of an optional type
    // (`x: T | null`, which must be passed). The annotation carries the `?`
    // suffix either way, so this flag records the omittable-at-call-site form.
    is_optional: bool = false,
    // `x: Ref<T>` — a by-reference parameter. `checked_type` holds the inner `T`
    // (the body type-checks as `T`); the param lowers to a single Zig pointer
    // `*T`. Scalar inner types additionally deref reads/writes in the body.
    is_ref: bool = false,
    // True when `is_ref` and the inner `T` is a scalar (int/i64/number/bool),
    // which needs explicit `.*` on reads and assignments in the body. Record and
    // tuple inner types rely on Zig's single-pointer field auto-deref instead.
    ref_scalar: bool = false,
    // A constructor parameter property (`constructor(public x: T)`): declares a
    // field `x` and assigns `this.x = x` at construction.
    is_property: bool = false,
};

/// `extern function name(params): ret;` — an external C-ABI function. No body;
/// resolved at link time. Params/return are restricted to C-safe scalar types.
pub const ExternDecl = struct {
    name: []const u8,
    params: []FunctionParam,
    return_annotation: []const u8,
    checked_return_type: ?types.Type = null,
    line: u32,
    col: u32,
};

pub const ClassDecl = struct {
    name: []const u8,
    fields: []TypeField,
    has_ctor: bool = false,
    ctor_params: []FunctionParam = &.{},
    ctor_body: []Stmt = &.{},
    methods: []FunctionDecl = &.{},
    // Single-inheritance parent class name from `extends Parent`.
    parent: ?[]const u8 = null,
    // Interface names from `implements I, J`.
    implements: [][]const u8 = &.{},
    // Type parameters for a generic class, e.g. `Box<T>`. When non-empty the
    // class is a template; concrete copies are generated per `new C<...>`.
    type_params: [][]const u8 = &.{},
    line: u32,
    col: u32,
};

/// Field/property write. When `obj` is null this is `this.field = value` inside a
/// method/constructor; otherwise it is `obj.field = value` (instance field,
/// static field, or setter property) from anywhere.
pub const MemberAssign = struct {
    field: []const u8,
    op: []const u8 = "=",
    value: *Expr,
    obj: ?*Expr = null,
    // Filled by the checker for emission routing.
    class_name: ?[]const u8 = null,
    is_static: bool = false,
    is_setter: bool = false,
    line: u32,
    col: u32,
};

pub const Accessor = enum { none, getter, setter };

pub const FunctionDecl = struct {
    name: []const u8,
    params: []FunctionParam,
    return_annotation: []const u8,
    checked_return_type: ?types.Type = null,
    // True when the source omitted the `: T` return annotation, so the checker
    // infers the return type from the body's first `return <expr>`.
    infer_return: bool = false,
    body: []Stmt,
    // Class-member modifiers (unused for free functions).
    visibility: Visibility = .public,
    is_static: bool = false,
    accessor: Accessor = .none,
    // `async function ...` — the declared return type must be `Promise<T>`; a
    // `return v;` resolves the promise with `v`.
    is_async: bool = false,
    // Type parameters for a generic function, e.g. `f<T, U>`. When non-empty the
    // function is a template; concrete copies are generated per call instance.
    type_params: [][]const u8 = &.{},
    line: u32,
    col: u32,
};

pub const VarDecl = struct {
    mutable: bool,
    name: []const u8,
    emit_name: ?[]const u8 = null,
    annotation: ?[]const u8,
    checked_type: ?types.Type = null,
    reassigned: bool = false,
    init: *Expr,
    no_init: bool = false, // `let x: T;` — declared with a type but no initializer; emitted as `var x: T = undefined;` (init holds a throwaway placeholder)
    unused: bool = false, // never referenced after declaration (checker warning); emit discards it so Zig accepts the unused local
    line: u32,
    col: u32,
    is_accumulator: bool = false, // string-builder local: emitted as a growable ArrayList(u8)
};

/// `using NAME = EXPR;` — a TypeScript 5.2 resource declaration. The bound value
/// is disposed at the end of the enclosing block/function scope; multiple `using`
/// declarations dispose in reverse (LIFO) order, lowering to Zig `defer`.
///
/// Two disposal shapes are recognized by the checker:
///   * `using x = defer(() => EXPR)` — the built-in `defer` helper. `defer_body`
///     holds the arrow's expression body, run verbatim at scope exit.
///   * `using r = make()` where the value is a class instance exposing
///     `dispose(): void` — `dispose_call` holds the `r.dispose()` call expr.
pub const UsingDecl = struct {
    name: []const u8,
    emit_name: ?[]const u8 = null,
    annotation: ?[]const u8 = null,
    checked_type: ?types.Type = null,
    init: *Expr,
    // `defer(() => BODY)`: the helper body, lowered to statements that run at
    // scope exit (LIFO). When set, there is no value binding — the bound name is
    // an opaque `Disposable` that is never read.
    defer_body: ?[]Stmt = null,
    // Object/class dispose: the `name.dispose()` call run at scope exit.
    dispose_call: ?*Expr = null,
    line: u32,
    col: u32,
};

pub const DestructBinding = struct {
    name: []const u8,
    emit_name: ?[]const u8 = null,
    checked_type: ?types.Type = null,
    is_rest: bool = false, // `[a, ...rest]` — binds the remaining elements as an array
    field_name: ?[]const u8 = null, // `{ field: name }` object rename — the source field to read; `name` is the local binding
    default: ?*Expr = null, // `[a = 1]` — value used when the array is shorter than the pattern
    default_unwraps: bool = false, // object default whose source field is optional: emit `src.field orelse default`
};

pub const DestructureDecl = struct {
    mutable: bool,
    is_object: bool, // true: { x, y } from a record; false: [ a, b ] from an array
    is_tuple: bool = false, // an array-pattern destructuring of a tuple source: bindings read positional struct fields (`.@"i"`) instead of slice indices
    is_assignment: bool = false, // `[a, b] = expr` assigns to existing variables instead of declaring new ones
    bindings: []DestructBinding,
    source: *Expr,
    line: u32,
    col: u32,
};

pub const Assign = struct {
    name: []const u8,
    emit_name: ?[]const u8 = null,
    op: []const u8 = "=",
    value: *Expr,
    line: u32,
    col: u32,
    // True when the target is a scalar `Ref<T>` parameter; the assignment lowers
    // through the pointer as `name.* = ...`.
    deref: bool = false,
    is_accumulator: bool = false, // `v = v + ...` append into a string-builder local
    // The LHS (target) type, recorded by the checker for compound assignments
    // whose lowering needs it -- `<<=`/`>>=` (shl/shr) and `**=` (powi/pow)
    // pick their helper by operand type (spec 052).
    checked_type: ?types.Type = null,
};

pub const ConsoleLog = struct {
    method: []const u8 = "log",
    value: *Expr,
    checked_type: ?types.Type = null,
    extra_values: []*Expr = &.{}, // `console.log(a, b, c)` — args after the first, printed space-separated
    extra_types: []types.Type = &.{}, // checked types of extra_values (filled by the checker)
    line: u32,
    col: u32,
};

pub const WhileStmt = struct {
    cond: *Expr,
    body: []Stmt,
    label: ?[]const u8 = null, // `name: while (...)` labeled loop (spec 052)
    line: u32,
    col: u32,
};

pub const DoWhileStmt = struct {
    body: []Stmt,
    cond: *Expr,
    label: ?[]const u8 = null,
    line: u32,
    col: u32,
};

pub const ForStmt = struct {
    // Each C-style clause is optional: `for (;;)`, `for (; c; )`, `for (i; ; u)`.
    // A missing condition means an unconditional loop (`true`).
    init: ?VarDecl,
    extra_inits: []VarDecl = &.{}, // `for (let i = 0, n = 5; ...)` — the declarators after the first
    cond: ?*Expr,
    update: ?Assign,
    extra_updates: []Assign = &.{}, // `for (...; ...; i++, j--)` — the updates after the first
    body: []Stmt,
    label: ?[]const u8 = null,
    line: u32,
    col: u32,
};

pub const ForOfStmt = struct {
    mutable: bool,
    binding: []const u8,
    binding_emit_name: ?[]const u8 = null,
    is_pair: bool = false, // `for (const [k, v] of map)` — binding is the key, value_binding the value
    is_array_entries: bool = false, // `for (const [i, v] of arr.entries())` — binding is the index (i32), value the element; iterable is rewritten to the receiver array
    is_tuple_pairs: bool = false, // `for (const [a, b] of pairs)` over a `[A, B][]` — binding is element[0], value_binding element[1] (spec 291)
    value_binding: []const u8 = "",
    iterable: *Expr,
    iter_type: ?types.Type = null,
    elem_type: ?types.Type = null,
    body: []Stmt,
    label: ?[]const u8 = null,
    line: u32,
    col: u32,
};

/// `for (const k in x) { ... }` (spec 052). The binding is always `string`
/// -- record field names or array indices as strings, matching JS/TS. The
/// checker fills `key_names` for a record iterable (the fixed field-name
/// list, iterated in declaration order) and leaves it null for an array
/// (indices `0..len` stringified at runtime).
pub const ForInStmt = struct {
    mutable: bool,
    binding: []const u8,
    binding_emit_name: ?[]const u8 = null,
    iterable: *Expr,
    key_names: ?[]const []const u8 = null, // record field names, or null for an array
    body: []Stmt,
    label: ?[]const u8 = null,
    line: u32,
    col: u32,
};

pub const IfStmt = struct {
    cond: *Expr,
    then_body: []Stmt,
    else_body: ?[]Stmt = null,
    line: u32,
    col: u32,
};

pub const SwitchCase = struct {
    value: *Expr,
    body: []Stmt,
    line: u32,
    col: u32,
};

pub const SwitchStmt = struct {
    value: *Expr,
    cases: []SwitchCase,
    default_body: ?[]Stmt = null,
    checked_type: ?types.Type = null,
    // True when the switch is over a literal union and the cases cover every
    // member (spec 266): counts as returning-on-all-paths without a default,
    // and emits a trailing `else unreachable`.
    exhaustive: bool = false,
    line: u32,
    col: u32,
};

pub const ExprStmt = struct {
    value: *Expr,
    line: u32,
    col: u32,
};

pub const ReturnStmt = struct {
    value: ?*Expr = null,
    checked_type: ?types.Type = null,
    line: u32,
    col: u32,
};

pub const ThrowStmt = struct {
    value: *Expr,
    line: u32,
    col: u32,
};

pub const TryStmt = struct {
    try_body: []Stmt,
    // null for optional catch binding `catch { ... }` (spec 052) -- the
    // caught error is discarded, no binding is introduced.
    catch_name: ?[]const u8,
    catch_emit_name: ?[]const u8 = null,
    catch_body: []Stmt,
    has_catch: bool = true, // false for `try { ... } finally { ... }` with no catch clause: an uncaught throw runs finally then re-propagates
    finally_body: ?[]Stmt = null,
    line: u32,
    col: u32,
};

pub const ControlStmt = struct {
    // `break name;` / `continue name;` target a labeled enclosing loop
    // (spec 052); null for the plain forms.
    label: ?[]const u8 = null,
    line: u32,
    col: u32,
};

pub const DeferStmt = struct {
    body: []Stmt,
    line: u32,
    col: u32,
};

pub const TestDecl = struct {
    name: []const u8,
    body: []Stmt,
    line: u32,
    col: u32,
};

/// `super(args);` — invoke the parent constructor. Only valid as the first
/// statement of a child constructor. `parent` is filled by the checker.
pub const SuperCtor = struct {
    args: []*Expr,
    parent: ?[]const u8 = null,
    line: u32,
    col: u32,
};

pub const StaticCall = struct {
    namespace: []const u8,
    name: []const u8,
    args: []*Expr,
    // Explicit `Namespace.method<T>(...)` type arguments -- JSON.parse<T>
    // (spec 051) is the first namespace call needing one; every other
    // static_call's namespace/name pair alone determines its signature.
    type_args: [][]const u8 = &.{},
    checked_type: ?types.Type = null,
    checked_arg_type: ?types.Type = null,
    cb_wants_index: bool = false, // Array.from(src, (v, i) => ...) — the map callback takes the element index
    object_keys: ?[]const []const u8 = null, // Object.keys(record): the static field-name list (spec 264)
};

pub const Stmt = union(enum) {
    type_decl: TypeDecl,
    enum_decl: EnumDecl,
    test_decl: TestDecl,
    extern_decl: ExternDecl,
    class_decl: ClassDecl,
    function_decl: FunctionDecl,
    var_decl: VarDecl,
    var_decl_group: []VarDecl, // `let a = 1, b = 2;` — several declarators in one statement
    using_decl: UsingDecl,
    destructure_decl: DestructureDecl,
    member_assign: MemberAssign,
    super_ctor: SuperCtor,
    assign: Assign,
    console_log: ConsoleLog,
    while_stmt: WhileStmt,
    do_while_stmt: DoWhileStmt,
    for_stmt: ForStmt,
    for_of_stmt: ForOfStmt,
    for_in_stmt: ForInStmt,
    if_stmt: IfStmt,
    switch_stmt: SwitchStmt,
    return_stmt: ReturnStmt,
    throw_stmt: ThrowStmt,
    try_stmt: TryStmt,
    break_stmt: ControlStmt,
    continue_stmt: ControlStmt,
    defer_stmt: DeferStmt,
    expr_stmt: ExprStmt,
    block_stmt: BlockStmt, // a bare `{ ... }` block — a nested lexical scope
};

/// A bare block statement `{ ... }` — introduces a nested lexical scope.
pub const BlockStmt = struct {
    body: []Stmt,
    line: u32,
    col: u32,
};

pub const Program = struct {
    stmts: []Stmt,
    uses_io: bool = false,
    uses_regex: bool = false,
    needs_args: bool = false,
    needs_read_file_sync: bool = false,
    needs_write_file_sync: bool = false,
    needs_append_file_sync: bool = false,
    needs_exists_sync: bool = false,
    needs_realpath_sync: bool = false,
    needs_mkdir_sync: bool = false,
    needs_unlink_sync: bool = false,
    needs_rename_sync: bool = false,
    needs_copy_file_sync: bool = false,
    needs_cp_sync: bool = false,
    needs_mkdtemp_sync: bool = false,
    needs_stat_sync: bool = false,
    needs_fd_api: bool = false,
    needs_async_read_file: bool = false,
    needs_async_write_file: bool = false,
    needs_async_append_file: bool = false,
    needs_async_unlink: bool = false,
    needs_async_mkdir: bool = false,
    needs_async_rmdir: bool = false,
    needs_async_stat: bool = false,
    needs_lstat_sync: bool = false,
    needs_fstat_sync: bool = false,
    needs_fchmod_sync: bool = false,
    needs_fchown_sync: bool = false,
    needs_chown_sync: bool = false,
    needs_lchown_sync: bool = false,
    needs_writev_sync: bool = false,
    needs_readv_sync: bool = false,
    needs_fsync_sync: bool = false,
    needs_ftruncate_sync: bool = false,
    needs_futimes_sync: bool = false,
    needs_utimes_sync: bool = false,
    needs_lchmod_sync: bool = false,
    needs_readdir_sync: bool = false,
    needs_fs_watch: bool = false,
    needs_fs_streams: bool = false,
    needs_process_stdio: bool = false,
    needs_readline: bool = false,
    needs_path_api: bool = false,
    needs_process_api: bool = false,
    needs_process_uptime: bool = false,
    needs_os_api: bool = false,
    needs_crypto_api: bool = false,
    needs_url_api: bool = false,
    needs_zlib_api: bool = false,
    needs_child_process_api: bool = false,
    needs_assert: bool = false,
    needs_time_api: bool = false,
    needs_http_module: bool = false,
    needs_http_server: bool = false,
    needs_http_constants: bool = false,
    needs_net: bool = false,
    needs_net_client: bool = false,
    needs_net_server: bool = false,
    needs_json: bool = false,
    needs_rmdir_sync: bool = false,
    needs_rm_sync: bool = false,
    needs_truncate_sync: bool = false,
    needs_link_sync: bool = false,
    needs_symlink_sync: bool = false,
    needs_readlink_sync: bool = false,
    needs_chmod_sync: bool = false,
    needs_access_sync: bool = false,
    needs_httpget: bool = false,
    needs_serve: bool = false,
    needs_map: bool = false,
    needs_set: bool = false,
    needs_event_emitter: bool = false,
    needs_buffer: bool = false,
    // crypto.createHash/createHmac streaming builder objects (spec 060):
    // gates the LumenHash/LumenHmac runtime block, emitted after (and
    // requiring) needs_buffer, since .digest() returns Buffer.
    needs_streaming_crypto: bool = false,
    // console.log/info/debug (spec 048): a real stdout writer is needed --
    // console.error/warn/trace keep using std.debug.print (real stderr)
    // directly and don't need this.
    needs_console_stdout: bool = false,
    // Async/await: emit the event-loop + Promise runtime and drain the loop in main.
    needs_async: bool = false,
    needs_thread_pool_fs: bool = false,
    // Worker.run(fn) -> Promise<T> (spec 059): a real detached std.Thread per
    // call, bridged back to the main thread via its own xev.Async + queue
    // (independent of needs_thread_pool_fs, which is fs's own ThreadPool).
    needs_worker: bool = false,
};

pub const Expr = union(enum) {
    num: i64,
    float: f64,
    bool: bool,
    str: []const u8,
    regex: struct { source: []const u8, flags: []const u8 }, // `/pattern/flags` literal
    null_lit, // null / undefined
    array: struct { items: []*Expr, elem_type: ?types.Type = null, heap_elem: ?types.Type = null }, // `[a, b, ...rest]`; elem_type is filled by the checker when a spread element is present; heap_elem is the element type of a spread-free literal, so it can heap-allocate (and safely escape a `return`) instead of pointing at a stack tuple
    spread: *Expr, // `...expr` element inside an array literal or call argument list
    tuple_lit: struct { items: []*Expr, tuple_type: ?types.Type = null }, // [a, b] checked against a tuple type
    var_ref: struct { name: []const u8, emit_name: ?[]const u8 = null, unwrap: bool = false, is_func_ref: bool = false, capture: bool = false, func_sig: ?*const types.FuncSig = null, deref: bool = false, is_accumulator: bool = false, builtin_const: ?[]const u8 = null }, // deref: a scalar `Ref<T>` parameter read, emitted as `name.*`; is_accumulator: read of a string-builder local, emitted as `name.items`
    neg: *Expr,
    not: *Expr,
    non_null: struct { inner: *Expr, unwraps: bool = false }, // `x!` — non-null assertion; `unwraps` when the operand is optional (emit `.?`, panics if null); a no-op on a non-optional operand
    bnot: *Expr, // bitwise ~
    typeof_expr: struct { operand: *Expr, result: ?[]const u8 = null }, // `typeof x` — a compile-time type-name string ("number"/"string"/...)
    instanceof_expr: struct { value: *Expr, class_name: []const u8, result: ?bool = null }, // `x instanceof C` — a compile-time bool (classes are non-polymorphic; spec 292)
    inc_dec: struct { target: *Expr, is_inc: bool, is_prefix: bool, checked_type: ?types.Type = null }, // `x++` / `++x` / `x--` / `--x` as an expression value
    await_expr: *Expr, // `await <expr>` — operand is a Promise<T>; yields T
    bin: struct { op: u8, l: *Expr, r: *Expr, checked_type: ?types.Type = null }, // + - * / % & | ^ and L=<< R=>> P=**
    bool_bin: struct { op: []const u8, l: *Expr, r: *Expr }, // && ||
    cmp: struct { op: []const u8, l: *Expr, r: *Expr, checked_operand_type: ?types.Type = null, opt_cmp: u8 = 0 }, // < > <= >= == !=; opt_cmp: 1=left optional vs value, 2=right optional vs value
    ternary: struct { cond: *Expr, then_expr: *Expr, else_expr: *Expr, result_type: ?types.Type = null }, // result_type set when a branch is `null` so both cast to `?T` at emit (spec 303)
    coalesce: struct { l: *Expr, r: *Expr, result_type: ?types.Type = null }, // a ?? b; result_type is the checked result (optional for a chained `a ?? b ?? d`)
    arrow: *ArrowExpr, // (x: T) => expr
    this_expr, // `this` inside a method/constructor
    super_call: struct { name: []const u8, args: []*Expr, parent: ?[]const u8 = null }, // super.m(args)
    new_expr: struct { class_name: []const u8, args: []*Expr, type_args: [][]const u8 = &.{}, container_type: ?types.Type = null }, // new C(args) / new C<T>(args) / new Map/Set<...>()
    method_call: struct { obj: *Expr, name: []const u8, args: []*Expr, class_name: ?[]const u8 = null, is_static: bool = false, array_elem_type: ?types.Type = null, array_acc_type: ?types.Type = null, array_result_type: ?types.Type = null, string_method: bool = false, container_type: ?types.Type = null, optional_chain: bool = false, chain_result_type: ?types.Type = null, cb_wants_index: bool = false, number_method: bool = false, is_console: bool = false, regex_arg: bool = false, sized_fill: bool = false }, // obj.m(args) / Class.m(args) / Map|Set method; is_console: console.log/error/... used as a void expression; regex_arg: a string method (replace) whose first arg is a regex; sized_fill: `new Array(n).fill(v)` fused initializer
    template: []TemplatePart, // `text ${expr} ...`
    obj: []FieldInit,
    field: struct { obj: *Expr, name: []const u8, builtin: ?FieldBuiltin = null, enum_value: ?EnumValue = null, optional_chain: bool = false, chain_field_type: ?types.Type = null, class_name: ?[]const u8 = null, is_static: bool = false, is_getter: bool = false, builtin_const: ?[]const u8 = null, unwrap: bool = false }, // builtin_const: a namespace constant (e.g. Math.PI) emitted as a raw Zig f64 literal
    index: struct { obj: *Expr, value: *Expr, checked_element_type: ?types.Type = null, tuple_index: ?usize = null, optional_chain: bool = false, chain_result_type: ?types.Type = null, string_char: bool = false }, // string_char: `s[i]` on a string, emits the 1-byte substring
    call: struct { name: []const u8, args: []*Expr, emit_name: ?[]const u8 = null, is_closure: bool = false, type_args: [][]const u8 = &.{}, ffi_string_args: []bool = &.{}, ffi_string_return: bool = false, ref_args: []bool = &.{}, is_into_call: bool = false, is_global_parse: bool = false }, // builtin / user / function-value call; type_args from explicit f<T>(...). ffi_* mark a call to an `extern function` so the FFI string marshalling glue is emitted. ref_args[i] true emits `&arg` for a by-reference (`Ref<T>`) parameter. is_into_call: a builder call appended into an accumulator -> emit `f__into(dest, args)`.
    optional_call: struct { callee: *Expr, args: []*Expr, optional_chain: bool = false, chain_result_type: ?types.Type = null }, // `a?.()` (spec 062) -- calling a possibly-null closure value directly, no name involved. callee's static type must be `optional` wrapping `func_type`; short-circuits to null like `a?.b`/`a?.[i]`.
    static_call: StaticCall,
    cast: struct { inner: *Expr, annotation: []const u8, checked_type: ?types.Type = null, is_satisfies: bool = false }, // `expr as T` (safe-subset assertion; erased at emit). is_satisfies: `expr satisfies T` (spec 052) -- checks assignability to T but keeps expr's own narrower type
};

pub const FieldBuiltin = enum {
    length,
    error_message,
    error_name,
    container_size,
    buffer_length,
};

/// A variable captured by a closure: stored by its outer emit-name in a heap
/// environment struct.
pub const Capture = struct { emit_name: []const u8, ty: types.Type };

/// Arrow function expression `(x: T) => expr` (V1: typed params, expression
/// body; may capture enclosing locals by value into a heap environment).
pub const ArrowExpr = struct {
    params: []FunctionParam,
    return_annotation: []const u8 = "",
    checked_return_type: ?types.Type = null,
    body_expr: ?*Expr = null, // expression body `=> expr`; null when body_block is set
    body_block: ?[]Stmt = null, // statement body `=> { ... }` (a void body)
    captures: []Capture = &.{},
    /// Display name for stack traces: the variable the arrow was assigned to
    /// (`const g = (x) => ...` traces as `g`); filled at emit time. Inline
    /// arrows stay null and trace as `<anonymous>`.
    name_hint: ?[]const u8 = null,
};

/// One segment of a template literal: either literal `text` or an interpolated
/// `expr` (with its checked type filled in for formatting).
pub const TemplatePart = struct {
    text: ?[]const u8 = null,
    expr: ?*Expr = null,
    expr_type: ?types.Type = null,
};
