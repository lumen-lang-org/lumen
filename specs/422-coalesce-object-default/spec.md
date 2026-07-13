# 422 — object-literal fallback in `??`

## Problem

An object-literal default on the right of `??` failed to type — the natural
"get-or-default record" pattern:

```ts
type P = { name: string };
const m = new Map<string, P>();
m.get("a") ?? { name: "none" }; // error: cannot infer variable/argument type
```

The coalesce checker called `exprType` on the right operand, but a bare object
literal can't self-type, so the whole expression was rejected.

## Approach

`lumen_check_expr.zig`, coalesce check: mirror the empty-array-fallback case —
when the right operand is an object literal and the left's inner type is a named
record, check the literal against that record type with `ensureAssignable` and
take it as the result type, instead of trying to self-type it.

## Verification

- `m.get("a") ?? { name: "none" }` binds and `.name` reads correctly (`bob`).
- Inline `(m.get("a") ?? { name: "none" }).name` → `bob`; miss → `none`.
- Variable default (`?? d`) and empty-array default (`?? []`) unchanged.
- Full `zig build` + test suite green.
