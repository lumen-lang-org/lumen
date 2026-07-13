# 426 — string methods accept a `number` argument in integer positions

## Problem

A string method that takes an integer argument rejected a `number` (`f64`)
value, so a count/index computed as `number` failed:

```ts
const n: number = 3;
"*".repeat(n);                 // error: type mismatch [E_TYPE_MISMATCH]
["a"].map(n => "x".repeat(n)); // n is number (f64) -> error
```

In JS/TS these methods take `number`; the integer requirement was too strict.

## Approach

`lumen_check_methods.zig`, the `.int` argument-kind check: when the argument is
`f64`, wrap it in a truncating `float_to_int` cast to `i32` (matching how JS
coerces the count/index to an integer) instead of failing. Integer arguments are
unchanged. This applies uniformly to `repeat`, `padStart`/`padEnd`, `slice`,
`substring`, the index methods, and `split`'s limit.

## Verification

- `"*".repeat(n)` with `n: number` → `***`; float truncates (`3.9` → `aaa`).
- `["1","2","3"].map(n => "x".repeat(n))` → `x-xx-xxx`.
- `"7".padStart(5.0, "0")` → `00007`; `"hello".slice(1.0)` → `ello`.
- Integer arguments unchanged.
- Full `zig build` + test suite green, plus a comprehensive end-to-end program
  exercising this session's fixes.
