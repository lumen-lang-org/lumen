# 402 — `switch` over a `number` discriminant accepts integer-literal cases

## Problem

A `switch` whose discriminant is `number` (`f64`) rejected integer-literal case
labels:

```ts
function f(n: number): string {
  switch (n) {
    case 1: return "one";   // error: type mismatch [E_TYPE_MISMATCH]
    default: return "other";
  }
}
```

Case labels were checked with strict `types.same(switch_type, case_type)`. A bare
`1` types as `i32`, the discriminant as `f64`, so every integer case on a
`number` switch failed — including grouped/fallthrough cases (`case 1: case 2:`).
`int`-typed and string discriminants already worked.

## Approach

`lumen_check_stmt.zig`, switch-case checking: when the discriminant is `f64` or
`i64`, check each case value with `ensureAssignable(switch_type, case.value)`
instead of strict equality. This applies the same integer-literal→`f64`/`i64`
widening used for variable initializers, `reduce` seeds (spec 394), and Set/Map
initializers (spec 397). String and `int`/`i32` discriminants keep their exact
paths.

## Verification

- `switch (n: number) { case 1: … }` → `one`.
- Grouped/fallthrough `case 1: case 2:` on a `number` switch → `low`.
- Float case label `case 1.5:` → `one-half`.
- `int` discriminant and string discriminant switches unchanged.
- Full `zig build` + test suite green.

## Notes

Same numeric-literal-width family as specs 394 and 397. Grouped empty cases
(`case 1: case 2: <body>`) already worked structurally; they were only blocked
by this discriminant type-check.
