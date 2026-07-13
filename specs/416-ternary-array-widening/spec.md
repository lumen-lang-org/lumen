# 416 — ternary with `int[]` and `number[]` branches unifies to `number[]`

## Problem

A conditional expression whose branches were an `int[]` and a `number[]` failed
to type, even though the `int[]`→`number[]` widening already worked in
assignment position (spec 415):

```ts
const a = [1, 2, 3];        // int[]
const b: number[] = [];
(a.length > b.length ? a : b).join(","); // error: expected `i32[]`, got `number[]`
```

The ternary required both branches to share a type (`types.same`); an `i32[]`
and an `f64[]` never matched.

## Approach

`lumen_check_expr.zig`, ternary branch unification: before failing, detect the
`i32[]` / `f64[]` pair and widen the integer branch — wrap it in the
`int_array_to_float` cast (spec 415), set the ternary's `result_type` to `f64[]`,
and return `f64[]`. The emitter then produces two `f64[]` branches.

## Verification

- `a.length > b.length ? a : b` with `a: int[]`, `b: number[]` → `1,2,3`.
- Integer branch in either position widens (then / else).
- Same-type branches (`number[]`/`number[]`, `int[]`/`int[]`) unchanged.
- Full `zig build` + test suite green.

## Notes

Extends spec 415's `int[]`→`number[]` widening to the ternary-unification path.
Non-array and other numeric-width ternary pairs are unaffected.
