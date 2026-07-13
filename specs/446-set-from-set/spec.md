# Spec 446 — `new Set` from another Set

## Problem

`new Set(otherSet)` — copying a set, the natural way to start a union — was
rejected because the `Set` constructor only accepted an array:

```ts
const a = new Set<number>([1, 2, 3]);
const b = new Set<number>(a);   // error: expected `number[]`, got `Set<number>`
```

## Change

In the `Set` constructor checker (`lumen_check_expr.zig`), when the single
argument's type is a `Set`, it is rewritten to `Array.from(arg)` — the same
values-slice conversion the `[...set]` spread already uses. From there the
existing array-source path handles element-type inference, checking, and the
copy-loop emission, so `new Set(otherSet)` builds an independent copy.

The rewrite is idempotent (after it, the argument is an array, so a re-check
sees no `Set`), and element inference without explicit type arguments
(`new Set(a)`) works because `Array.from(a)` types as `T[]`.

## Verification

- `zig build` and `zig build test` clean.
- `new Set<number>(a)` copies a set; `.size` is correct.
- `new Set(a)` (inferred) copies, and mutating the copy leaves the source
  unchanged (independent sets).
- A set-union pattern (`let u = new Set(a); for (const x of b) u.add(x)`) works.
