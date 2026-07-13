# 403 — `Math.max`/`Math.min` accept mixed integer/float arguments

## Problem

`Math.max` / `Math.min` required every argument to be the exact same numeric
type, so mixing a float and an integer literal failed:

```ts
Math.max(1.5, 3);   // error: type mismatch [E_TYPE_MISMATCH]
Math.min(2, 1.5);   // error
Math.max(x, 1.5);   // x: i32 — error
```

The variadic check compared each argument to the first with `types.same`, so an
`f64` and an `i32` never matched — even though in JS every numeric literal is
`number`.

## Approach

`lumen_check_stdlib.zig`, `Math.max`/`min` variadic path: compute the widest
numeric type across all arguments (`f64` > `i64` > `i32`), then check each
argument against it with `ensureAssignable`, applying the same integer→`f64`/`i64`
widening used elsewhere. The result type is the widest type — so an all-integer
call still returns `i32` (`Math.max(1,2) + 1` stays integer arithmetic), while
any float argument promotes the whole fold (and its result) to `f64`. The
`Math.min(...arr)` / `Math.max(...arr)` spread-fold path is unchanged.

## Verification

- `Math.max(1.5, 3)` → `3`; `Math.min(2, 1.5)` → `1.5`.
- `Math.max(x, 1.5)` with `x: i32` → `2`.
- All-integer `Math.max(1,5,3)` → `5`, result stays `i32` (`Math.max(1,2)+1` → `3`).
- All-float and `Math.min(...arr)` spread unchanged.
- Full `zig build` + test suite green.

## Notes

Same numeric-literal-width family as specs 394, 397, 402.
