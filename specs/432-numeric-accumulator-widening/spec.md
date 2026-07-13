# Spec 432 — Numeric accumulator widening

## Problem

`let n = 0` infers `n: i32` (integer literals default to a 32-bit int). A very
common pattern then fails to compile:

```ts
let total = 0;
for (const x of xs) { total = total + x; } // x: number
```

```
error: type mismatch: expected `i32`, got `number`
```

TypeScript types every numeric as `number`, so the accumulator is a float there.
Lumen keeps `int`/`number` distinct (integer counters and array indices need to
stay 32-bit), so a blanket "int literal → number" rule is wrong — but a mutable
`let` that is only ever accumulated into with a float should widen.

## Change

In the plain/compound assignment checker (`lumen_check_stmt.zig`, `.assign`),
when:

- the operator is arithmetic (`=`, `+=`, `-=`, `*=`, `/=`, `%=`, `**=`),
- the target is an unannotated `let` binding still typed as an integer,
- **this assignment is the target's first use** (`was_used` is false), and
- the right-hand side is `number` (`f64`),

the binding is promoted to `number`: its `checked_type` becomes `f64` and the
original initializer is floated through `Number(...)`. The assignment then type-
checks as `number = number`.

The first-use guard is the safety condition. Promotion mutates the declaration
retroactively, so any earlier use that required the integer width (e.g. passing
the variable to an `int` parameter) would otherwise be miscompiled. When the
variable was already referenced, promotion is skipped and the original
`type mismatch` diagnostic stands — annotate `let n: number = 0` to widen
explicitly.

Explicit annotations, integer loop counters, array indices, and integer-only
accumulators are unaffected (their right-hand sides are integer, or the binding
carries an annotation).

## Verification

- `zig build` and `zig build test` clean.
- Widens: `let t = 0; t = t + f()` (f: number) → `2.5`; method/interface
  accumulators (`t = t + c.area()`) → correct float totals; `for` accumulate of
  a `number[]` → float sum.
- Unaffected: integer loop counter + array index → `60`, `20`; integer-only
  accumulator keeps truncating division (`10 / 2` after int adds → `5`).
- Guard: `let n: int = 0; n = n + f()` still errors; a variable used as an
  `int` argument before a float assignment gets a clean `type mismatch` instead
  of a backend crash; `let n: number = 0` is the explicit escape hatch.
