# 390 — Type-guard narrowing in a ternary condition

## Problem

A user-defined type guard (spec 384) narrowed in an `if` statement but not in a
ternary condition:

```ts
function isOk(r: Result): r is Ok { return r.kind === "ok"; }
const s = isOk(r) ? "ok:" + r.value : "err";   // error: r not narrowed to Ok
```

The ternary applied only `narrowTarget` (null-checks), not the predicate-call
narrowing.

## Change

`lumen_check_expr.zig`, the `.ternary` case of `exprType`: when the condition is
a type-guard call (`predicateVariantNarrow`), push the narrowed variant while
typing the then-branch and pop it before the else-branch — the same mechanism
the `if` handler uses.

## Verified

`zig build` + `zig build test` green. Probes:

- `isA(u) ? "a:" + u.x : "other"` → `f(a)="a:5"`, `f(b)="other"`.
- Predicate narrowing in an `if` (spec 384) still works.
- Null-check ternary narrowing (`x != null ? x : 0`) unchanged.
- Broad regression combining guards, computed enums, `Partial<Record<…>>`,
  default-assignment narrowing, and async variant returns runs end-to-end.
