# 425 — generic inference through `T | null` + numeric-width reconciliation

## Problem

The idiomatic get-or-default generic failed to infer:

```ts
function orDefault<T>(x: T | null, d: T): T { return x ?? d; }
const n: number | null = null;
orDefault(n, 99); // error: expected `i32`, got `number | null`
```

Two gaps:

1. `unifyAnnotation` had no case for an optional pattern (`T | null` / `T?`), so
   `T` never bound from the `number | null` argument.
2. Even once it did, `T` bound to `number` from `x` and to `int` from the literal
   `99` — the consistency check rejected the width difference.

## Approach

`lumen_check_generics.zig`, `unifyAnnotation`:

- **Optional pattern**: when the argument is `.optional`, strip a trailing `?` or
  the `| null` / `| undefined` members from the pattern and unify the remaining
  type-parameter pattern against the argument's non-null inner type.
- **Numeric reconciliation**: when a bare type parameter already bound to one
  numeric type and now sees another (`int` vs `number`), reconcile to the wider
  type (`number` if either is `f64`, else `i64`) instead of failing — matching JS
  where numeric literals are `number`.

## Verification

- `orDefault(n, 99)` (`number | null`) → `99`; present value `7.5` → `7.5`;
  string variant → `def`.
- `pick<T>(a: T, b: T)` with `(5.5, 3)` reconciles to `number` → `5.5`.
- A genuine mismatch (`pick(5, "x")`) still reports a type error.
- `T[]`, tuple, `Box<T>`, and explicit-arg inference unchanged.
- Full `zig build` + test suite green.
