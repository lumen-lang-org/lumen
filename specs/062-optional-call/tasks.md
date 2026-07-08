# Tasks: spec 062 optional call `a?.()`

- [x] **T1 — AST: `optional_call` `Expr` variant.** File:
  `src/lumen_ast.zig`. Add `optional_call: struct { callee: *Expr, args:
  []*Expr, optional_chain: bool = true, chain_result_type: ?types.Type =
  null }` beside `method_call`/`field`/`index`.

- [x] **T2 — Parser.** File: `src/lumen_parser_expr.zig`,
  `parsePostfixFrom`'s `?.` branch. After the existing `[` (optional index)
  check and before the `self.cur != .ident` guard, add: if `self.isOp('(')`,
  parse a normal argument list and build `.optional_call = .{ .callee = e,
  .args = ... }`, `continue`. Do not require an ident.

- [x] **T3 — Checker.** File: `src/lumen_check_expr.zig`, new
  `.optional_call => |*oc|` arm in `exprType`. Callee type must be
  `.optional` wrapping `.func_type` (`E_TYPE_MISMATCH` otherwise — narrower
  than "any nullable value"). Arg count/types checked against
  `sig.params` (`E_ARG_COUNT` / `E_TYPE_MISMATCH`, reusing the closure-call
  model at ~869-887). Reject `sig.ret.* == .void` with `E_TYPE_MISMATCH`
  (matches spec 052's `a?.b()`-on-void precedent). Set
  `oc.chain_result_type = sig.ret.*`, return `.{ .optional = &sig.ret.* }`
  (arena-allocated).

- [x] **T4 — Emit.** File: `src/lumen_emit.zig`. New `.optional_call => |oc|`
  arm: `(if (<callee>) |__oc| @as(?R, __oc.call(__oc.ctx, <args>)) else
  null)` — the `f.call(f.ctx, args)` shape matches the existing non-optional
  closure-call emission for `call.is_closure` (~line 233).

- [x] **T5 — Generics clone.** File: `src/lumen_check_generics.zig`,
  `cloneExpr`. New `.optional_call` arm deep-cloning `callee`+`args`,
  propagating `optional_chain` (checker re-derives `chain_result_type`).

- [x] **T6 — Exhaustiveness fan-out.** Add `optional_call` to every switch
  the Zig compiler flags after T1 lands: `types.inferExprType`
  (`src/lumen_types.zig`, joins the existing `null`-returning list),
  `exprUsesThis`/`exprUsesName`/`markAccExpr`/`accBadRef`
  (`src/lumen_emit_analysis.zig`, `src/lumen_opt.zig`), and any other
  exhaustive `Expr` switch flagged by the build. Use the compiler's
  exhaustiveness errors as the checklist per spec 052's own process — don't
  hand-enumerate.

- [x] **T7 — Example programs + manual verification.** Add
  `specs/062-optional-call/examples/valid/*.ts` covering: `cb?.()` on a null
  closure (no call, evaluates to null, no crash); `cb?.()` on a set closure
  (calls through, returns value); `obj.cb?.()` (field-chained); `getCb()?.()`
  (call-chained). Add `specs/062-optional-call/examples/invalid/*.ts`
  covering: void-returning optional closure rejected; non-optional/
  non-func_type callee before `?.()` rejected. Compile and run each valid
  program through `zig-out/bin/lumen`, confirm output; compile each invalid
  program and confirm the expected diagnostic.

- [x] **T8 — Regression + conformance.** `zig build test` clean. One full,
  clean, non-concurrent `zig build conformance` run — confirm no regression
  from the current 206-passed/0-failed baseline (kill any stray zig process
  first; do not run a second concurrent conformance pass).

- [x] **T9 — Docs.** Update `website/index.html`'s syntax feature list (the
  same place spec 052's syntax additions were reflected) with `a?.()`, terse,
  no Zig-internals wording. Note the local-short-circuit divergence if the
  existing `a?.b`/`a?.[i]` entry already does.

- [x] **T10 — Commit.** One commit, no `Co-Authored-By` trailer (CLAUDE.md
  hard rule).
