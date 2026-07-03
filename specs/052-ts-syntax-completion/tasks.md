# Tasks: TypeScript syntax completion

Each task is one logically-mergeable slice (one worktree branch at a time),
ordered to minimize merge conflicts per the spec's cluster analysis. Do NOT
run two tasks in the same cluster in parallel. Cluster G (T11) is fully
isolated and may be done at any point / in parallel.

Every task names its files and a real `.ts` program that exercises it, plus
`zig build test` + a clean conformance run at the end.

## Phase 1 — green-lit syntax features

**Progress (batch 1 shipped):** T1, T2, T4, T6 done and verified — see the
`[x]` marks. Also fixed a pre-existing false-positive in the
`E_DYNAMIC_PROPERTY_WRITE` lexer pre-scan (it flagged `readonly [A, B] =`
tuple annotations as indexed writes). Two pre-existing limitations surfaced
while testing and are explicitly NOT part of this spec: nested array types
(`int[][]`) don't parse, and a `throw` from inside a called function isn't
caught by an enclosing `try` (cross-function throw) — both predate spec 052.

- [x] **T1 — `readonly` arrays / `ReadonlyArray<T>` (Cluster D, S).** DO FIRST
  — it stabilizes the annotation grammar. Files: `src/lumen_parser_expr.zig`
  (strip a leading `readonly` at the top of `parseTypeAnnotation`; extend the
  `Array` special-case in `parseTypeMember` to also match `ReadonlyArray`,
  desugaring to `T[]`). No checker/emit/lexer change (type erasure). Verify: a
  `.ts` using `readonly int[]`, `ReadonlyArray<string>`, a `readonly [A, B]`
  tuple, and a nested `ReadonlyArray<readonly int[]>` all compile, run, and
  behave identically to their mutable-typed equivalents.

- [x] **T2 — Object-literal shorthand `{ x }` + static computed keys
  `{ ["k"]: v }` (Cluster E, S).** File: `src/lumen_parser_expr.zig` only
  (object-literal loop ~611-633). Shorthand synthesizes a `var_ref` value;
  computed key accepts a string-literal key only and rejects any dynamic key
  with a parse error. No AST/checker/emit change. Preserve the `...spread`
  branch and trailing-comma logic. Verify: `const y = 1; const o = { y, ["z"]: 2 }`
  round-trips; a dynamic computed key `{ [k]: v }` (runtime `k`) is a clean
  parse error; shorthand of an unknown name still fails type-check.

- [x] **T3 — Compound assignment: logical `??= &&= ||=` AND
  bitwise/shift/exp `&= |= ^= <<= >>= **=` (Cluster A, M).** IMPLEMENT AS ONE
  SLICE — F3 and F4 edit the same lexer branches, the same 3 parser
  whitelists, and the same 2 emit-assign branches. Files: `src/lumen_lexer.zig`
  (new `.op2` tokens, ordered before shorter matches; update doc comments),
  `src/lumen_ast.zig` (`checked_type` on `Assign`/`MemberAssign`),
  `src/lumen_parser.zig` (:241, :670) + `src/lumen_parser_expr.zig` (:644)
  (shared `isCompoundAssignOp` helper), `src/lumen_check_stmt.zig` (bool for
  `&&=/||=`, optional for `??=`, integer for `&=/|=/^=/<<=/>>=`, numeric for
  `**=`), `src/lumen_emit_stmt.zig` (`and`/`or`/`orelse` branches; dedicated
  `std.math.shl/shr` for `<<=/>>=` and `powi`/`pow` for `**=`; `& | ^` reuse
  the existing `op[0]` path). Verify: a `.ts` exercising every operator on the
  right LHS type prints the expected results; `count ||= 5` (numeric LHS) is a
  type error; `x <<= 1`, `x >>= 2`, `x **= 3` produce correct arithmetic (not
  a comparison/multiply from the `op[0]` trap); a `readonly`/float `&=` is
  rejected.

- [x] **T4 — Optional catch binding `catch { ... }` (Cluster B, S).** DO
  before T5. Files: `src/lumen_ast.zig` (`catch_name: ?[]const u8`),
  `src/lumen_parser.zig` (:525-529, guard the paren block on `(`),
  `src/lumen_check.zig` (`declareCatch`, wrap body in `if (catch_name) |n|`),
  `src/lumen_emit_stmt.zig` (:559-565, emit `if (slot != null) {` with NO
  capture when unbound), `src/lumen_check_generics.zig` (optional copies
  fine). Verify: `try { ... } catch { ... }` compiles and runs; `catch {}
  finally {}` and bare `catch {}` both work; `catch ()` (empty parens) is
  still a parse error; the classic `catch (e) { ... }` is unaffected.

- [~] **T5 (for...in DONE, labeled statements pending) — Labeled statements + `for...in` (Cluster B, M+M, PAIRED
  SLICE).** DO after T4; these two share the loop structs and the `for`-parse
  block, so land them together but sequentially internally (labeled first,
  then for-in). Files (labeled): `src/lumen_ast.zig` (`label` on the four loop
  structs + `ControlStmt`), `src/lumen_parser.zig` (label parse + optional
  break/continue label), `src/lumen_check.zig` + `src/lumen_check_stmt.zig`
  (`label_stack`, `E_LABEL_NOT_LOOP`/`E_UNKNOWN_LABEL`), `src/lumen_emit_stmt.zig`
  (`__lumen_lbl_` prefix on the inner `while`, `bodyReferencesLabel` guard for
  Zig's unused-label rule, label beats switch-break). Files (for-in):
  `src/lumen_ast.zig` (`ForInStmt` + union arm), `src/lumen_parser.zig` (`in`
  check before the const-rejection), `src/lumen_check_stmt.zig` (array or
  record, keys-as-string, capture `key_names`), `src/lumen_emit_stmt.zig`
  (index-stringify for arrays, fixed key slice for records), plus the fan-out
  arms in `src/lumen_emit_class.zig`, `src/lumen_emit_analysis.zig` (x2), all
  8 `src/lumen_opt.zig` sites, `src/lumen_check_generics.zig`. Verify:
  `outer: for (...) { for (...) { break outer; continue outer; } }` behaves
  correctly; a labeled non-loop errors; `for (const k in rec)` iterates field
  names in declaration order; `for (const i in arr)` yields string indices;
  for-in over a Map/scalar is rejected.

- [x] **T6 — `satisfies` operator (Cluster C, S).** DO before/with T7 (batch
  the `Expr`-union edits). Files: `src/lumen_ast.zig` (`satisfies` variant,
  `checked_type` = SOURCE type), `src/lumen_parser_expr.zig` (extend the
  `as` postfix loop in `parseUnary`), `src/lumen_check_expr.zig` (directional
  `ensureAssignable`, **return the source type not the target**), `src/lumen_emit.zig`
  (erased). Add the `.satisfies` arm to every exhaustive `Expr` switch the Zig
  compiler flags. Verify: `const x = cfg satisfies Record` keeps `cfg`'s narrow
  type (a later access to a field not in `Record` still checks); a value NOT
  assignable to the target is rejected; `x as A satisfies B` chains.

- [ ] **T7 — Optional chaining on calls + index `a?.b()`, `a?.[i]` (Cluster C,
  M).** Files: `src/lumen_ast.zig` (`optional_chain` + cached type on
  `method_call` and `index`), `src/lumen_parser_expr.zig` (dispatch the `?.`
  branch on `[`/ident+`(`/ident), `src/lumen_check_expr.zig` (require optional
  object, unwrap, wrap result as `?T`; reject `?void`), `src/lumen_emit.zig`
  (`(if (obj) |__oc| @as(?T, ...) else null)`), `src/lumen_check_generics.zig`
  (propagate the flag). SCOPE CUT: `a?.()` deferred (see spec). Verify: a `.ts`
  where `a?.b()` and `a?.[i]` on a non-null value return the wrapped `?T` and
  on a null value yield null; `JSON?.parse(...)` stays a normal call; a
  void-returning `a?.m()` is rejected. Document the local-short-circuit
  divergence in the example.

- [ ] **T8 — `#private` fields (Cluster F, S).** DO after T3 (shares the lexer
  file). Files: `src/lumen_lexer.zig` (`#`-prefixed ident token, slice
  includes the `#`), `src/lumen_parser_decl.zig` (force `.private` when
  `member[0] == '#'`; optional `E_MODIFIER_CONFLICT`), `src/lumen_emit_class.zig`
  + `src/lumen_emit.zig` + `src/lumen_emit_stmt.zig` (`emitFieldName` -> `@"#x"`
  at every field-name site; scrub `#` from static-field mangling). No checker
  change (existing `checkVisibility` handles it). SCOPE: fields only, `#`
  methods deferred. Verify: a class with `#secret` reads/writes it inside
  methods, a public `secret` coexists distinctly, and `obj.#secret` from
  outside the class is `E_PRIVATE_ACCESS`.

- [x] **T9 — Re-exports `export { a } from` / `export * from` (Cluster G, M,
  ISOLATED).** File: `src/lumen.zig` only (textual inliner). Add
  `reexport_all` Kind + update the 4 Kind switches; add `parseReExport`
  (require the ` from "` marker, reuse import validation + `parseNamedBindings`);
  insert its check BEFORE `parseExportList` and the `export ` catch-all in the
  main loop AND in `collectExports`; recurse to inline the source module.
  Verify: a 3-file graph where `barrel.ts` does `export { a } from "./a.ts"`
  and `export * from "./b.ts"`, and `main.ts` imports through `barrel.ts`,
  compiles and runs; a name collision across two `export *` sources surfaces
  `E_DUPLICATE_BINDING`; namespace imports (already working) still work.

## Phase 2 — verification, docs, ship

- [ ] **T10 — Regression + conformance.** `zig build test` passes. One clean,
  non-concurrent `zig build conformance` run shows no new failures vs. `main`.
  Add example programs (valid + a couple of invalid/rejected cases) under the
  relevant `specs/052-ts-syntax-completion/examples/` (or the conformance
  corpus) for each shipped feature — especially the deliberate divergences
  (`readonly` erasure, bool-only `&&=`/`||=`, optional-chain local
  short-circuit, for-in keys-as-string).

- [ ] **T11 — User-facing docs.** Update `website/stdlib.html` (or the
  homepage feature/syntax list) to reflect the newly-supported syntax:
  logical + bitwise/shift/exp compound assignment, optional catch binding,
  labeled statements, `for...in`, `satisfies`, optional chaining on calls/
  index, `readonly` arrays, `#private` fields, object shorthand + static
  computed keys, and `export ... from` re-exports. Note the documented
  divergences and the explicit scope cuts (`a?.()`, `#` methods, general
  computed keys, `as const`/`keyof`/`typeof`/`instanceof`).

- [ ] **T12 — Commit, push, redeploy `lumen-playground`.**

## Deferred / not planned (tracked, not scheduled)

See spec.md's **Not planned** table: `as const`, `typeof` narrowing,
`instanceof` narrowing, `keyof`/indexed-access types, general (dynamic)
computed keys, optional call `a?.()`, `#private` methods, and labeling
arbitrary (non-loop) blocks — each with its specific missing-primitive reason.
Namespace imports (`import * as ns`) are already implemented; only the
re-export half (T9) was outstanding.
