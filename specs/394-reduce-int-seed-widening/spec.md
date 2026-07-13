# 394 — reduce/reduceRight: widen an integer-literal seed to the element type

## Problem

The canonical fold example failed on an `f64` array:

```ts
const a: number[] = [1.5, 2.5];
a.reduce((x, y) => x + y, 0); // error: type mismatch [E_TYPE_MISMATCH]
```

`reduce` fixes the accumulator type from the seed. A bare integer literal `0`
types as `i32`, so the accumulator became `i32` while the callback body
`x + y` produced `f64` (element width). Accumulator ≠ callback return, so the
shape check rejected it. The workaround was writing `0.0`, which TypeScript
never requires — every numeric literal there is `number`.

The same bit `Object.values(record).reduce((x, y) => x + y, 0)` and any
`i64[]` fold seeded with `0`.

## Approach

In the reduce accumulator-type resolution (`lumen_check_methods.zig`), before
falling back to `exprType(seed)`, special-case a bare integer-literal seed
(`mc.args[1].* == .num`) over an `f64` or `i64` element array: run
`ensureAssignable(elem, seed)` — which already performs the integer→f64
`Number()` rewrite / lossless i64 widening — and take the accumulator type from
the element. `i32` arrays are untouched (the seed already matches), object /
float / annotated-callback seeds keep their existing paths.

## Verification

- `[1.5,2.5].reduce((x,y)=>x+y,0)` → `4`.
- `Object.values({a:80,b:90}).reduce((x,y)=>x+y,0)` → `170`.
- `i64[]` fold seeded with `0` → `60`.
- `int[]` fold seeded with `0` unchanged → `6`.
- Float seed (`10.0`) and object seed (`{sum:0.0}`) paths unchanged.
- Full `zig build` + test suite green.

## Notes

Bare `bigint` literal syntax in an array (`[10n, 20n]`) is a separate,
unrelated parser gap and is not addressed here — `i64[]` covers the fold case.
