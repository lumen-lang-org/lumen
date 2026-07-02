# Spec 052: TypeScript syntax completion

**Feature Branch**: `main` (milestone 052) | **Status**: Draft

## Goal

Close the remaining, genuinely-implementable gaps in TypeScript **syntax**
support — the surface-level constructs a TS programmer expects to just work,
that the compiler currently rejects at parse time or silently under-handles.
This is a syntax pass, not a stdlib pass: no new namespaces, no runtime APIs.

Every feature here was re-checked from scratch against the current source
(not assumed from an old roadmap), the same diligence specs 050/051 applied.
Each shipped item is pure static sugar that lowers onto machinery Lumen
already has — Zig short-circuit operators, Zig labeled loops, existing
`ensureAssignable`, existing `private` visibility enforcement, the existing
textual module inliner. None of them requires the JavaScript dynamism the
guardrails exclude (no prototypes, no `any`/`unknown`, no dynamic object
shape, no RTTI). The features that *would* require that dynamism are
documented in **Not planned** with the specific missing primitive, not a
hand-wave.

A recurring theme: several of these constructs (`typeof`/`instanceof`
narrowing, `keyof`/indexed-access, `as const`) look like small syntax
additions but are actually *type-system* features whose value depends on
value-level literal types, scalar unions, or per-instance runtime tags that
Lumen deliberately omits. Those are called out as out-of-scope with the real
reason, exactly the way spec 018 documents decorators/abstract classes and
the fs/json specs document their deferrals.

## Shipping this milestone

Eleven features are green-lit. They are grouped into **conflict clusters** by
the core files they contend on, and ordered so an implementer can take them
one worktree-branch at a time with each slice rebasing cleanly onto the last.
The hard rule: **features inside the same cluster edit the same switch bodies
/ operator tables / AST unions and MUST NOT be implemented in parallel** —
sequence them adjacently or land them as one slice.

### Cluster D — type-annotation parser (do FIRST, it stabilizes the annotation grammar)

**F1. `readonly` arrays / `ReadonlyArray<T>` — complexity S.**
Type erasure: accept the syntax, strip `readonly`, desugar to plain `T[]`.
This is correctly scoped because Lumen arrays are *already* immutable in
practice — `arrayMethod` (`src/lumen_check_stdlib.zig:29-149`) exposes no
mutating methods and index-write `arr[i] = x` is not even a parseable
statement (`src/lumen_parser.zig:687-691` has no `=` after a postfix;
`src/lumen_emit.zig:1187` is read-only). So there is nothing extra to forbid,
and a real `Type` variant would be dead weight until in-place mutation lands.

- `src/lumen_parser_expr.zig` `parseTypeAnnotation` (line ~138): at the very
  top, before the `(`/`[`/`parseTypeMember` dispatch, add
  `if (self.cur == .ident and eql(self.cur.ident, "readonly")) try self.advance();`.
  Placing it at the top handles `readonly T[]`, `readonly [A, B]` (readonly
  tuples), and nested element positions uniformly, since tuple/function/array
  element annotations all recurse through `parseTypeAnnotation`.
- `src/lumen_parser_expr.zig` `parseTypeMember` (line ~50): extend the
  existing `Array` special-case to also match `ReadonlyArray`, desugaring
  `ReadonlyArray<T>` to the canonical `T[]` string exactly like `Array<T>`.
- No checker/emit/types change: the annotation reaching `typeFromAnnotation`
  is already plain `T[]`. `readonly` is a contextual identifier (no lexer
  token), so no lexer change.
- Accepted laxness (documented, not a bug): erasure makes `readonly int[]`
  and `int[]` the *same* type, so passing a readonly array where a mutable
  one is expected is silently allowed. Harmless today because no mutation
  exists; revisit only if arrays ever gain in-place mutation, at which point
  the full-marker alternative (a `readonly_array` `Type` variant threaded
  through `same`/`ensureAssignable`/`zigName`) becomes worth its cost.

Land this first: it is the smallest change and it touches the annotation
parser that the (out-of-scope) `keyof`/`as const` features would also touch,
so a stable annotation grammar de-risks any future type-level work.

### Cluster E — object-literal parser (standalone, parser-only)

**F2. Object-literal shorthand `{ x }` and static computed keys `{ ["k"]: v }` — complexity S.**
Both desugar entirely in the object-literal loop at
`src/lumen_parser_expr.zig:611-633` with **no AST/checker/emit change**,
because a field is stored as `FieldInit{ name, value }` and the existing
contextual object-literal checker (`src/lumen_check_assign.zig:45-93`)
resolves whatever value expression it's handed.

- **Shorthand `{ x }` == `{ x: x }`** (fully feasible): after reading `fname`
  and advancing, branch on the next token instead of unconditionally calling
  `expectOp(':')`. On `:`, parse the value as today; otherwise (next is `,`
  or `}`) synthesize the value as a `var_ref` node
  (`self.node(.{ .var_ref = .{ .name = fname } })`) and append
  `FieldInit{ .name = fname, .value = vref }`. The contextual checker then
  resolves the `var_ref` via binding lookup + `ensureAssignable`; unknown
  names already fail in `exprType`, so no new error path.
- **Computed key — static-string subset ONLY** `{ ["foo"]: v }` == `{ foo: v }`:
  before the `if (self.cur != .ident)` guard, add an `isOp('[')` branch that
  parses `[ expr ] :`. If the key node is a string literal (`.str`), take
  `fname = key.str` and append a normal `FieldInit`. If the key is anything
  else, reject with a parse error — a **runtime/dynamic key cannot produce a
  closed record shape and is out of scope by design** (see Not planned).
- Both new branches must end with the same trailing-comma-or-break logic the
  existing field path uses, and must not disturb the `...spread` branch.

### Cluster A — lexer operator table + compound-assignment parser/emit sites (IMPLEMENT TOGETHER)

**F3 + F4 are one coordinated slice.** They edit the *exact same* lexer
operator branches, the *same three* parser assignment whitelists
(`src/lumen_parser.zig:241`, `:670`, and `src/lumen_parser_expr.zig:644`),
and the *same two* emit-assign branches (`emitAssignExpr` and `member_assign`
in `src/lumen_emit_stmt.zig`). Doing them in parallel guarantees merge
conflicts; do them as one branch, or strictly back-to-back.

**F3. Logical assignment `??=` `&&=` `||=` — complexity M.**
Pure syntactic sugar onto Zig short-circuit operators, RHS-eval semantics
preserved:
- `a &&= b` -> `a = (a and b)` (LHS must be `bool`)
- `a ||= b` -> `a = (a or b)` (LHS must be `bool`)
- `a ??= b` -> `a = (a orelse b)` (LHS must be `optional<T>`)

Restrict `&&=`/`||=` to `bool` LHS and `??=` to `optional<T>` LHS — crisp and
static, consistent with Lumen's bool-only `&&`/`||` (no truthiness). Document
that `count ||= 5` is a *type error* here, unlike TS.

- Lexer (`src/lumen_lexer.zig`): emit 3-char `.op2` tokens BEFORE the existing
  2-char handlers. In the `|` block (~167) check for `||=` before returning
  `.cmp "||"`; in the `&` block (~177) check `&&=` before `.cmp "&&"`; in the
  `??` block (~209) check `??=` before `.op2 "??"`. **Ordering is
  load-bearing** — the 3-char checks must precede the shorter-match returns
  or the `=` gets split off. Update the doc-comment operator lists (~line 28).
- Parser: extend the op2 disjunction at `:241`/`:670` (member-assign) and
  `parseAssignmentTail` at `parser_expr.zig:644` (simple-assign) with the
  three new strings. No AST change: `Assign.op`/`MemberAssign.op` are already
  `[]const u8`.
- Checker (`src/lumen_check_stmt.zig`, both the `.assign` case ~:389 and
  `assignField` ~:216): dispatch on op — `&&=`/`||=` require `bool` LHS+RHS;
  `??=` requires optional LHS and reuses `ensureAssignable` against the inner
  type; arithmetic keeps the existing `isNumeric && same` check. Keep the
  setter guard (`if (!eql(ma.op,"=")) fail`) — logical compound on a
  setter/getter stays rejected.
- Emit (`src/lumen_emit_stmt.zig`, `emitAssignExpr` ~:42 and `member_assign`
  ~:208): add branches keyed on the full op string before the generic
  `op[0]` fallback: `&&=`->`and`, `||=`->`or`, `??=`->`orelse`.

**F4. Bitwise / shift / exponent compound assignment `&=` `|=` `^=` `<<=` `>>=` `**=` — complexity M.**
Reuses the already-implemented binary `& | ^ << >> **` operators (checker
rules and `std.math.shl`/`shr`/`powi`/`pow` emission both exist at
`src/lumen_emit.zig:930-954`). Purely additive tokenization + lowering.

- Lexer (`src/lumen_lexer.zig`): add trailing-`=` recognition ordered before
  the shorter-match branches. `&=`/`|=`/`^=` as 2-char `.op2`; `<<=`/`>>=`/`**=`
  as 3-char `.op2` (the field is a `[]const u8` slice, so 3 chars is fine — do
  NOT touch the separate `.op3` used for `...`). Disambiguate `&=` vs `&&`,
  `|=` vs `||`, `<<=` vs `<<`, `**=` vs `**` by checking the specific trailing
  char.
- AST (`src/lumen_ast.zig`): add `checked_type: ?types.Type = null` to
  `Assign` (~:205) and `MemberAssign` (~:117), so emit knows the element type
  for `shl`/`shr`/`powi`.
- Parser: extend the same three whitelists as F3 (factor a shared
  `isCompoundAssignOp` helper across F3/F4).
- Checker (`src/lumen_check_stmt.zig`): for `&= |= ^= <<= >>=` require
  `types.isInteger(expected) && types.same(expected, value)` (mirror the
  binary rule at `check_expr.zig:102`); for `**=` keep the numeric rule; set
  `checked_type` on success.
- Emit (`src/lumen_emit_stmt.zig`): **the `op[0]` trap is the crux** — the
  existing emit uses only the first char. `& | ^` already lower correctly
  through the `{c}` fallback (they *are* valid Zig infix ops), so **no emit
  change for those three**. But `<<=`/`>>=` need dedicated
  `std.math.shl/shr(T, name, value)` branches and `**=` needs
  `std.math.powi(T, name, value) catch ...` (int) / `std.math.pow` (f64),
  because `op[0]` for those is `<`/`>`/`*` and would emit a comparison or a
  multiply. `T = types.zigName(checked_type)`.
- Type strictness: `& | ^ << >>` must reject float operands (integer-only),
  matching the binary rule and `specs/003-.../examples/invalid/bitwise-float.ts`.

### Cluster B — statement dispatch, loop structs, try/catch, Stmt union (SEQUENCE these three)

All three add/modify arms in the same switch bodies: `parseStmt`'s keyword
dispatch, the `Stmt` union in `src/lumen_ast.zig`, the stmt switch in
`src/lumen_check_stmt.zig`, the stmt switch in `src/lumen_emit_stmt.zig`, and
the clone switch in `src/lumen_check_generics.zig`. Implement **sequentially**,
never in parallel. Recommended internal order: F5 (catch, smallest, distinct
try/catch region) → then F6 + F7 as a paired slice (they share loop structs
and the `for`-parsing block most heavily).

**F5. Optional catch binding `catch { ... }` (no `(e)`) — complexity S.**
Currently the parser hard-requires the parenthesized binding
(`src/lumen_parser.zig:525-529`: unconditional `expectOp('(')`, ident,
`expectOp(')')`), so `catch {` fails outright. The emitter already tolerates
an unread binding, so the only real work is representing *absence*.

- AST (`src/lumen_ast.zig:304-312` `TryStmt`): change
  `catch_name: []const u8` to `catch_name: ?[]const u8`. `catch_emit_name` is
  already optional.
- Parser (`:525-529`): guard the paren-binding block on `self.isOp('(')`;
  leave `catch_name = null` when absent. Keeps ident-only (no destructuring).
  `catch ()` (empty parens) correctly still errors, matching TS.
- Checker (`src/lumen_check.zig:344-350` `declareCatch`): wrap the whole body
  in `if (stmt.catch_name) |name| { ... }`; declare nothing when null. Skip
  the `E_DUPLICATE_BINDING` check when there's no name.
- Emit (`src/lumen_emit_stmt.zig:559-565`): when a binding exists, keep
  `if (slot) |emit| {`; when absent emit `if (slot != null) {` — **do not emit
  a capture** (`|_|`), because Zig forbids an unused capture. The non-binding
  branch must never read `catch_emit_name`.
- Generics clone (`src/lumen_check_generics.zig:458`): an optional copies fine
  by value, no change beyond type-checking.

**F6. Labeled statements + labeled `break`/`continue` — complexity M.**
Scope: labeling **loops only** (`for`/`for-of`/`while`/`do-while`), which
covers the meaningful `break`/`continue` targets. Labeling arbitrary blocks
is out of scope. Zig has first-class labeled loops (`lbl: while (...) {}`,
`break :lbl`, `continue :lbl`) — a direct 1:1 lowering.

- AST: add `label: ?[]const u8 = null` to `WhileStmt`, `DoWhileStmt`,
  `ForStmt`, `ForOfStmt`, and `ControlStmt` (all additive/defaulted).
- Parser: at statement start, after reading a leading `ident`, if the next
  token is `:` consume it, recursively `parseStmt()`, and stamp `.label` on
  the resulting loop variant — reject non-loop targets with `E_LABEL_NOT_LOOP`.
  For `break`/`continue` (`src/lumen_parser.zig:491-499`), read an optional
  trailing ident label before `expectOp(';')`.
- Checker: add a `label_stack` to `Checker`; push/pop around each loop body;
  in `break`/`continue`, if a label is named verify it is on the stack else
  `E_UNKNOWN_LABEL` (keep the existing depth checks for the unlabeled case).
  Reject a duplicate label already live in the nesting chain for a clean
  diagnostic (Zig itself errors on shadowed labels).
- Emit (`src/lumen_emit_stmt.zig`): prefix generated labels with
  `__lumen_lbl_` (avoiding Zig keywords and the existing
  `__lumen_switch_`/`__lumen_try_` internal labels). Attach the label to the
  inner `while` for `for`/`for-of` (which wrap in an unlabeled block), not the
  wrapping `{`. In the `break` arm, check `control.label` FIRST so
  `break outer` beats the switch-break fallback.
- **Zig rejects unused labels** (TS permits them): add a
  `bodyReferencesLabel(body, name)` helper (analogous to `bodyHasSwitchBreak`)
  and only emit the label prefix when the body actually targets it.

**F7. `for...in` loops — complexity M.**
Mirror the fully-implemented `for-of` pipeline. Lumen's static semantics:
for-in yields **KEYS as `string`**. Arrays yield stringified indices
`"0".."len-1"` (TS's own foot-gun); closed records yield their statically-
known field names in declaration order; Map/Set/tuple/scalars are rejected
with `E_TYPE_MISMATCH`.

- AST: add `ForInStmt` (like `ForOfStmt` but binding is always `string`;
  stash `key_names: ?[][]const u8` filled during checking so emit needs no
  registry lookup for records) and a `for_in_stmt` arm on the `Stmt` union.
- Parser (`src/lumen_parser.zig` ~:419): in the `for` branch, add an `in`
  check mirroring the `of` check, placed **before** the C-style
  `if (is_const) return error.ParseError` so `for (const k in x)` is allowed.
  No lexer token — `in` arrives as `.ident` via `isKw`.
- Checker (`src/lumen_check_stmt.zig` ~:446): require array or resolvable
  `named` record; capture ordered field names for records; bind the loop var
  as `.string`; increment `loop_depth` around the body.
- Emit (`src/lumen_emit_stmt.zig` ~:416): arrays iterate indices and
  stringify each (needs a `usize`->`[]const u8` prelude helper if none
  exists); records iterate a fixed `[_][]const u8{...}` key slice.
- **Fan-out sites** (same as `for-of`, easy to miss): add a `for_in_stmt` arm
  in `src/lumen_emit_class.zig:212` (`emitSuperCopies`),
  `src/lumen_emit_analysis.zig:45`&`:167` (`bodyCanThrow`/`bodyUsesThis`), all
  8 sites in `src/lumen_opt.zig`, and the clone switch in
  `src/lumen_check_generics.zig:451`. The Zig compiler flags each
  non-exhaustive switch, which pinpoints them all.
- **Honesty note for the spec body**: for-in exists in TS mainly to drive
  `obj[key]` dynamic indexed access, which Lumen deliberately lacks (see
  `keyof`/indexed-access in Not planned). Without it the string key can only
  be printed/compared/collected, so for-in is functionally thin in isolation.
  It is feasible (keys are statically known, no reflection) and shipped for
  completeness, but document the limited utility loudly.

### Cluster C — Expr union, postfix/unary parser, expr checker, expr emit (BATCH the AST edits)

Both features add/modify arms in the `Expr` union (`src/lumen_ast.zig`), the
`parseUnary`/`parsePostfixFrom` region of `src/lumen_parser_expr.zig`, the
`exprType` dispatch of `src/lumen_check_expr.zig`, the `Expr` switch in
`src/lumen_emit.zig`, and `cloneExpr` in `src/lumen_check_generics.zig`.
Batch the union edits so the two diffs don't overlap; the Zig compiler's
exhaustiveness errors will find every switch that needs a new arm.

**F8. `satisfies` operator (`expr satisfies T`) — complexity S.**
A near-clone of the existing `as T` assertion. The one meaningful difference
is the entire point: `as` uses bidirectional `castAllowed` and *replaces* the
expression's type with the target; `satisfies` uses directional
`ensureAssignable` and *preserves* the inferred source type. No lexer change
(`satisfies`, like `as`, lexes as a plain ident).

- AST: add a `satisfies` variant beside `cast`, with
  `checked_type` holding the **source** type (unlike `cast`, which stores the
  target), because the expression evaluates to the source type.
- Parser: extend the postfix loop in `parseUnary`
  (`src/lumen_parser_expr.zig:359-364`) from `while (self.isKw("as"))` to
  `while (self.isKw("as") or self.isKw("satisfies"))`, branch inside, reuse
  `parseTypeAnnotation()`. Keeping both in one loop preserves left-assoc
  chaining (`x as A satisfies B`).
- Checker: add a `.satisfies` case beside `.cast`: resolve the target, get
  the source type, call `ensureAssignable(target, inner)` (directional — the
  whole point), then **return the SOURCE type, not the target**. Returning the
  target would silently reimplement `as`; this is the main correctness trap.
- Emit: `.satisfies => try emitExpr(s.inner, ...)` — purely erased.

**F9. Optional chaining on calls and index `a?.b()`, `a?.[i]` — complexity M (partially-present).**
`?.` is implemented today only for field access
(`src/lumen_parser_expr.zig:373-378` always builds a `field` node after
`?.`). Follow the existing house pattern for `a?.field`, which
short-circuits **locally** (one `?.` yields `?T`; it does not short-circuit a
whole trailing chain the way real TS does) and reuses the
`(if (obj) |__oc| @as(?T, ...) else null)` emit shape.

- AST: add `optional_chain: bool = false` + a result/element type field to
  the `method_call` struct (~:481) and the `index` struct (~:485), mirroring
  the field-access template.
- Parser: in the `?.` branch, dispatch on the next token instead of forcing
  an ident — `[` -> optional index; ident then `(` -> optional method call;
  ident alone -> the existing optional field. Force `method_call`/`field`
  under `?.` (skip the static-namespace branch — `JSON?.parse` is nonsensical
  since namespaces are never optional).
- Checker: for `mc.optional_chain`/`index.optional_chain`, require the object
  type is `optional`, unwrap, run normal method/element resolution against the
  inner type, then wrap the result as `?R`/`?E` and stash the unwrapped type.
- Emit: wrap method-call and index emission in the same
  `(if (obj) |__oc| @as(?T, __oc.method(args)) else null)` shape.
- Generics clone: propagate the new `optional_chain` flag at the `method_call`
  (~:391) and `index` (~:409) clone sites (the checker re-derives the cached
  types).
- **Scope cut, stated explicitly**: `a?.()` (calling a nullable value) is
  deferred — Lumen has no general "call an arbitrary expr" AST node
  (`call` keys off a name string), so it's a separate, lower-value case. Ship
  `a?.b()` + `a?.[i]` only. Also: `a?.b()` on a `void`-returning method has no
  meaningful `?void` — reject in the checker with `E_TYPE_MISMATCH`.
- **Divergence to document**: local vs full short-circuit. Real TS makes
  `a?.b.c()` yield undefined for the whole chain when `a` is null; Lumen's
  field impl (and this extension) only short-circuits one hop, so each `?.`
  yields `?T` and the trailing access must itself be `?.` to continue.

### Cluster F — lexer `#` + class-decl parser + class emit (sequence after Cluster A's lexer work)

**F10. ECMAScript `#private` fields — complexity S.**
The ordinary `private` modifier already fully works (spec 018:
`checkVisibility` enforces class-body-only access, no subclass access), which
is *exactly* the semantics of `#` hard-private in Lumen's static model. So
`#name` is essentially a `private` field in a separate name-space. Scope V1
to `#` **fields only**; `#method()` is a noted follow-up. No dynamism needed.

- Lexer (`src/lumen_lexer.zig`): add a `c == '#'` case before the final
  `isIdentStart` block — require the next byte to start an identifier
  (`E_UNEXPECTED_CHAR` otherwise), then consume `#` + the ident run and return
  a `.ident` token **whose slice includes the leading `#`**. Keeping `#name`
  as an `ident` means every downstream `self.cur == .ident` site accepts it
  unchanged. (This shares the lexer file with Cluster A — sequence, don't
  parallelize.)
- Parser (`src/lumen_parser_decl.zig`): the modifier loop already breaks on
  `#foo` and captures it as a normal member name. Add ONE rule: if
  `member[0] == '#'`, force `visibility = .private` (optionally reject
  `private #x` / an explicit modifier as `E_MODIFIER_CONFLICT`, matching TS).
  Member access `obj.#x` and write `this.#x = v` already accept the `#name`
  ident token.
- Checker: **no new code** — the existing `checkVisibility` fires
  `E_PRIVATE_ACCESS` for out-of-class `#x`, and lookup is by exact string, so
  public `x` and private `#x` coexist as distinct names.
- Emit: Zig struct fields can't contain `#`. Add an `emitFieldName` helper
  that writes a **Zig quoted identifier** `@"#name"` (distinct from `x`, no
  collision) when `name[0] == '#'`, else the bare name. Use it at every
  field-name emit site: struct-field decl (`emit_class.zig:71`), field read
  (`emit.zig` ~:1184 and the optional-chain `__oc.` path ~:1156), field write
  (`emit_stmt.zig:203`/`:205`). Scrub `#` from the `__static_<class>_<field>`
  mangling for static private fields.
- **Name-space distinctness is the trap**: emit must NOT strip `#` to a bare
  `x` (would collide with a public `x`) — the `@"#x"` form guarantees
  distinct, valid Zig identifiers.

### Cluster G — textual module inliner (fully isolated, parallelizable)

**F11. Re-exports `export { a } from "..."` / `export * from "..."` — complexity M (partially-present).**
Namespace imports (`import * as ns from "..."`) are **already fully
implemented** in the CLI inliner `src/lumen.zig` (`.namespace` Kind,
`file_namespaces`, `ns.member`->`member` rewrite; documented in
`README.md:48`). Re-exports are the missing half and are currently **broken**:
`export { x } from "./x.ts"` is silently swallowed by `parseExportList`
(dropping the line so `x.ts` is never inlined and `x` is undefined), and
`export * from` hits the `startsWith("export ")` catch-all and errors.

All changes are confined to `src/lumen.zig` (the textual inliner) — **no
lexer/parser/AST/checker/emit change**, matching the spec-015 convention that
module resolution is textual pre-processing. Re-exporting a symbol just means
inlining the source module so its declarations land in the single flattened
top-level scope; a further importer then resolves them like any binding.

- Add a `reexport_all` variant to `ImportSpec.Kind`; update the 4 exhaustive
  Kind switches.
- Add `parseReExport` matching `export * from "..."` / `export { ... } from
  "..."` by requiring the ` from "` marker (reuse `parseImportSpec`'s
  marker/spec-extraction/validation and `parseNamedBindings`). Return null
  when there's no ` from "` marker so plain `export { a, b }` still falls
  through.
- In the main loop, insert the `parseReExport` check **BEFORE**
  `parseExportList` and **BEFORE** the `startsWith("export ")` error, resolve
  the child path with the existing url/join logic, and recurse into
  `appendExpandedSource` with the child kind.
- Update `collectExports` so a module's re-exports count as its own exports
  (needed for a grandparent importing through a re-exporter). For
  `export * from`, first-slice may skip star transitivity (runtime still works
  because inlining provides all symbols — only the parent's `MissingExport`
  pre-check is affected); thread `io` + base-dir into `collectExports` to make
  it fully transitive if needed.
- **Ordering is load-bearing** in both the main loop and `collectExports`:
  the re-export branch must precede `parseExportList` (which today falsely
  records `export { x } from` names as local exports) and the `export `
  catch-all error.

## Not planned

Documented with the specific missing primitive, in the style of spec 018's
decorator/abstract-class exclusions. These are not "too hard" — they are
constructs whose value depends on type-system machinery Lumen deliberately
omits, so shipping the *syntax* would deliver no real feature (or would
require the very JS dynamism the guardrails forbid).

| Feature | Status | Real reason |
| --- | --- | --- |
| `import * as ns from "..."` (namespace import) | **already present** | Fully implemented in the `src/lumen.zig` inliner: `.namespace` Kind, `file_namespaces` alias tracking, `ns.member`->`member` rewrite on inlined lines, documented in `README.md:48`. Only the *re-export* half (F11) was missing. |
| `as const` assertions | **out of scope** | No representation in Lumen. Literal narrowing needs a value-keyed single-literal type, but string literals erase to `string` (`lumen_check.zig:477`) and `string_literal_union`/`int_literal_union` are *named alias decls*, not per-value types. Deep `readonly` needs a `readonly` type Lumen doesn't have (records/arrays are mutable-typed). Moot anyway: string and literal-union types already cast freely. A real impl would need a new value-keyed literal `Type` variant rippling through `same`/`zigName`/`widen`/`castAllowed`. |
| `typeof x === "..."` narrowing | **out of scope** | Narrowing is only meaningful when a binding's static type spans more than one `typeof` category — i.e. a scalar union (`string \| number`) or a dynamic `any`/`unknown`. The closed `Type` enum (`lumen_types.zig:18-51`) has **neither** by design, and spec 017 explicitly excludes "unions of scalars." `string_literal_union`/`int_literal_union` are decoys: every member is still a `string`/`int`, so `typeof` yields one constant category. Every binding already has a single statically-known type, so a `typeof` guard is always compile-time-constant — it can never narrow. Also not parseable today: `parseUnary` has no `typeof` prefix rule and there is no AST node for it. |
| `instanceof` narrowing (`if (x instanceof Cls)`) | **infeasible** | Requires per-instance runtime type information (RTTI), which contradicts the flattened-struct class model. Three design mismatches: (1) no value form to narrow — Lumen unions are *discriminated record unions*, a class union `Cat \| Dog` is not expressible; (2) no polymorphic class values — `class_type` is by-name identity, `isSubclassOf` is used only for `E_PROTECTED_ACCESS` visibility, never assignability, so a `Dog` cannot be stored in an `Animal`-typed variable; (3) no RTTI — inheritance is implemented by *flattening* parent fields/methods into each child's standalone struct, so instances carry no tag/vtable/common base and `x instanceof Dog` has nothing to test at runtime. The Lumen-idiomatic substitute already exists: model closed class sets as a discriminated union of records, narrowed via the discriminant. `instanceof` isn't even a distinct token today (it's a plain ident used only for regex disambiguation). |
| `keyof T` and indexed-access types `T[K]` | **out of scope** | The valuable form is the generic accessor `get<T, K extends keyof T>(o: T, k: K): T[K]`, which needs two things Lumen intentionally lacks: (1) value-level literal string types — `typeFromAnnotation` erases `"name"` to `.string`, so at `get(p, "name")` `K` infers as `string` and the compiler can't compute which field `T[K]` selects; and (2) general heterogeneous unions for `T[keyof T]` — Lumen has only literal-unions and discriminated record unions (`parseTypeAnnotation` rejects general `\|`). Same class of omission as mapped/conditional types. Constraint syntax `<K extends keyof T>` can't even parse (`parseTypeParams` reads bare idents only). A non-generic slice (`keyof ConcreteRecord`, `Rec["field"]`) is feasible but near-useless — it only works when the record and key are literally spelled out, exactly when the programmer could write the field type by hand. Skip. |
| General computed keys `{ [k]: v }` with a runtime `k` | **out of scope** | Lumen uses closed record shapes with statically-known field names (guardrail: no dynamic object shape mutation). A runtime string key needs an open/dynamic map or `any`, which the guardrails forbid. Only the compile-time-constant-string subset ships (F2). |
| Optional call `a?.()` (nullable callee) | **deferred (this pass)** | No general "call an arbitrary expression" AST node — `call` keys off a name string; closure calls are `call` with `is_closure`. A separate, lower-value case than `a?.b()`/`a?.[i]` (F9), deferred rather than rushed. |
| `#private` **methods** | **deferred (this pass)** | F10 ships `#` fields. Private methods need the same `@"..."` mangling on fn names AND every call site + the `m:/g:/s:` dispatch keys — a larger, follow-up slice in spec 018's incremental style. |
| Labeling arbitrary blocks (non-loop labeled statements) | **out of scope (this pass)** | F6 labels loops only, covering the meaningful `break`/`continue` targets. Labeled blocks with `break label` out of a plain `{}` are lower-value and rejected at parse time via `E_LABEL_NOT_LOOP`. |

## Design notes — cross-feature interactions the implementer must respect

- **Lexer ordering is load-bearing (Cluster A + F10).** Every new
  compound-assignment token (`??= &&= ||= &= |= ^= <<= >>= **=`) must be
  matched *before* the existing shorter-match branch for the same lead char,
  or the trailing `=` is split off. The new `#` case (F10) shares the lexer
  file with Cluster A — sequence them, never branch both in parallel off the
  same base.
- **`src/lumen_parser_expr.zig` is a shared file across four clusters** (D:
  `parseTypeAnnotation`/`parseTypeMember`; E: object-literal loop; C:
  `parseUnary`/`parsePostfixFrom`; A: `parseAssignmentTail`). They touch
  *distinct functions*, so textual conflicts are minimal, but land them in the
  recommended order (D → E → A → C) so each rebases onto a stable file.
- **Batch the `Expr`-union edits (Cluster C).** `satisfies` and optional-call/
  index both add/modify `Expr` union arms; the Zig compiler's exhaustiveness
  errors will pinpoint every `check`/`emit`/`clone` switch that needs a new
  arm — use that as the checklist, don't hand-enumerate.
- **Cluster B's three features share the same switch bodies** (`parseStmt`
  dispatch, `Stmt` union, `check_stmt`/`emit_stmt` switches,
  `check_generics` clone). Implement strictly sequentially. F6+F7 additionally
  share the loop structs and the `for`-parsing block, so pair them.
- **`for...in` fan-out.** Adding `ForInStmt` requires arms in `emit_class`,
  `emit_analysis` (x2), all 8 `lumen_opt.zig` sites, and `check_generics`.
  Missing any one is a `zig build` error, not a silent bug — lean on that.
- **Optional-chaining local-short-circuit divergence** must be documented in
  the example programs, not just the spec: each `?.` yields `?T` and does not
  propagate nullishness through a trailing non-`?.` access, unlike real TS.
- **`readonly` erasure laxness** (F1) and **`&&=`/`||=` bool-only strictness**
  (F3) are deliberate divergences from TS — both belong in the user-facing
  notes so they aren't mistaken for bugs.
- **Cluster G (`src/lumen.zig`) is fully isolated** and can be implemented in
  parallel with any other cluster — it shares no files with the compiler
  pipeline.
