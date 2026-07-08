# Spec 062: optional call `a?.()`

**Feature Branch**: `main` (milestone 062) | **Status**: Draft

## Goal

Ship `a?.()` — calling a possibly-null/undefined closure value directly,
without a following method/field name. This is the sibling of spec 052's
optional field `a?.b` and optional index `a?.[i]` (F9), which spec 052's
"Not planned" table explicitly deferred:

> Optional call `a?.()` (nullable callee) | **deferred (this pass)** | No
> general "call an arbitrary expression" AST node — `call` keys off a name
> string; closure calls are `call` with `is_closure`. A separate, lower-value
> case than `a?.b()`/`a?.[i]` (F9), deferred rather than rushed.

Note spec 052 also ended up deferring `a?.b()` (optional *method* call) at
implementation time, for an unrelated reason: the method-call resolver
recomputes its receiver type across many internal dispatch paths, so
unwrapping-then-rewrapping every result path was a disproportionate checker
refactor (see `specs/052-ts-syntax-completion/tasks.md` T7, `E_UNSUPPORTED_OPTIONAL_CALL`
in `src/lumen_check_expr.zig`). `a?.()` does not hit that obstacle: calling a
`func_type` value has exactly one resolution path (no method dispatch, no
namespace/static/array/string/map/set special cases), so it composes cleanly
with the checker in the same shape as `a?.[i]`.

## Scope

`a?.()` applies when the expression immediately before `?.()` has a
**nullable/optional closure type** — `Type.optional` wrapping a
`Type.func_type` (`src/lumen_types.zig:18-51`). Concretely:

- `cb?.()` — `cb: (() => R) | undefined`, a plain variable/parameter binding.
- `obj.cb?.()` — a field access yielding an optional `func_type`.
- `getCb()?.()` — a preceding call/chain yielding an optional `func_type`.

Calling a **non-optional** closure (`cb()` where `cb: () => R`) is untouched
— that's the existing `call` node with `is_closure = true`. `a?.()` is a new
case only for the optional-wrapped closure.

## Design

### AST

`src/lumen_ast.zig` gains a new `Expr` variant, `optional_call`, carrying the
callee as an `*Expr` directly (there is still no general "call an arbitrary
expression" node for the *non-optional* case — this variant exists
specifically for the optional-callee shape, mirroring `method_call`/`field`/
`index`'s `obj: *Expr` + `optional_chain: bool` + a chain-result-type field):

```zig
optional_call: struct {
    callee: *Expr,
    args: []*Expr,
    optional_chain: bool = false, // set true by the parser; always true in
                                   // practice for this node, kept for naming
                                   // symmetry with method_call/field/index
    chain_result_type: ?types.Type = null,
},
```

Unlike `call`, which resolves a callee by name (`call.name` looked up in
`self.funcs`/`self.binding`), `optional_call.callee` is an arbitrary
already-parsed expression — exactly the general "call an expression" shape
spec 052 said didn't exist, scoped narrowly to the one case that needs it.

### Parser

`src/lumen_parser_expr.zig`'s `parsePostfixFrom`, inside the existing `?.`
branch, dispatches on the token right after `?.`:

- `[` → optional index (existing).
- `(` → **new**: optional call on the expression built up so far (`e`), not
  a method call needing a name. Parses a normal argument list.
- ident → optional method call / optional field (existing).

`a?.()` therefore does not require `self.cur == .ident` after `?.` — the `(`
branch is checked before the ident-only guard.

### Checker

New `.optional_call` case in `exprType` (`src/lumen_check_expr.zig`):

1. Compute the callee's static type.
2. It must be `.optional`; unwrap it (`E_TYPE_MISMATCH` otherwise).
3. The unwrapped type must be `.func_type` (`E_TYPE_MISMATCH` otherwise —
   this is the narrower constraint the general case doesn't need: not just
   "any nullable value" but specifically a nullable *closure*).
4. Arg count must match `sig.params.len` (`E_ARG_COUNT`); each arg must be
   `ensureAssignable` to the matching param type (`E_TYPE_MISMATCH`) — the
   same rule the existing closure `call` case already applies
   (`src/lumen_check_expr.zig` ~869-887).
5. **Void-returning callee is rejected**, matching spec 052's own precedent
   for `a?.b()` on a void method (documented there as "no meaningful
   `?void`"): `sig.ret.* == .void` → `E_TYPE_MISMATCH`.
6. Result type is `?R` (`R` = `sig.ret.*`), stored on `chain_result_type` for
   emit, exactly like `index.chain_result_type`/`field.chain_field_type`.

### Emit

`src/lumen_emit.zig` emits the same short-circuit-to-null shape the other
`optional_chain` cases already use, applied to the closure-call convention
(`f.call(f.ctx, args...)`, since a Lumen closure value is a
`{ ctx, call }` struct, not a bare Zig function pointer):

```zig
(if (<callee>) |__oc| @as(?R, __oc.call(__oc.ctx, <args>)) else null)
```

### Generics clone

`src/lumen_check_generics.zig`'s `cloneExpr` gains an `.optional_call` arm
that deep-clones `callee` and `args` and propagates `optional_chain` (the
checker re-derives `chain_result_type` on the clone, the same pattern
`method_call`/`field`/`index` already follow).

### Other exhaustive `Expr` switches

Adding a union variant means every exhaustive switch over `Expr` needs an
arm. Per spec 052's own recommended process, the Zig compiler's
exhaustiveness errors after adding the variant are the checklist, not a
hand-enumeration. Sites found this way: `types.inferExprType`
(`src/lumen_types.zig`, already returns `null` for `call`/`method_call`/etc,
so `optional_call` joins that list), `exprUsesThis`/`exprUsesName` and
`markAccExpr` (`src/lumen_emit_analysis.zig`, `src/lumen_opt.zig`), and
`bodyCanThrow`-style helpers wherever they switch on `Expr` exhaustively
(sites with a catch-all `else =>` do not need a new arm but get one anyway
where doing so is more correct than silently falling into the default).

## Divergence from real TypeScript (documented, matching the existing
optional-chain convention)

Same **local, not full, short-circuit** divergence spec 052 already
documents for `a?.b`/`a?.[i]`: each `?.` yields `?T` on its own and does
**not** propagate nullishness through a trailing non-`?.` access. Real TS
makes `a?.().b` short-circuit the whole chain to `undefined` when `a` is
null; Lumen's `a?.()` only short-circuits the call itself — a subsequent
`.b` on the `?T` result must itself be written `?.b` (or the code must
narrow/unwrap first) to continue the chain. This is called out again here,
in the example programs, exactly as spec 052 requires for every
optional-chain feature.

## Not planned (unchanged from spec 052)

`a?.b()` (optional *method* call) remains deferred with
`E_UNSUPPORTED_OPTIONAL_CALL`, for the reason spec 052 recorded (method
resolution's receiver-type recomputation), which this spec does not touch.
`a?.()` is the closure-only case and does not share that obstacle.

## Verification

Real `.ts` programs, compiled and run through `zig-out/bin/lumen`
(`specs/062-optional-call/examples/valid/`):

- `cb?.()` where `cb` is a null/undefined optional closure: does not call
  through, the whole expression evaluates to `null`/`undefined`, no crash.
- `cb?.()` where `cb` is a set optional closure: calls through and returns
  the closure's value.
- `obj.cb?.()` — optional call chained off a field access.
- `getCb()?.()` — optional call chained off a preceding call's result.
- A void-returning optional closure is rejected at type-check time
  (`specs/062-optional-call/examples/invalid/`), matching the documented
  `?void` rule.
- A non-optional, non-func_type callee before `?.()` is rejected
  (`E_TYPE_MISMATCH`).
