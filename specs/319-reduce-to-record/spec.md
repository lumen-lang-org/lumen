# Spec 319 — `reduce` with a record accumulator

## Goal

Support folding an array into a record with `reduce`, where the callback returns
an object literal:

```ts
type Acc = { sum: i32; cnt: i32 };
const r = [10, 20].reduce(
  (a: Acc, x: i32) => ({ sum: a.sum + x, cnt: a.cnt + 1 }),
  { sum: 0, cnt: 0 },
);
console.log(r.sum, r.cnt);   // 30 2
```

## Motivation

Spec 299 inferred the accumulator type from the callback's first parameter so an
object-literal seed could be typed. But the callback body is itself an object
literal, which can't be typed on its own, so the callback's return type came back
`void` and `reduce` reported `type mismatch` / `cannot infer variable type`.

## Behavior

`reduce`/`reduceRight` now tell the callback its expected return type (the
accumulator type), so an expression-body arrow whose body is an object or array
literal types against it. Scalar reductions and other array callbacks are
unchanged.

## Implementation

- `src/lumen_check.zig`: an `arrow_return_hint` checker field carries the expected
  return type into the next arrow check (consumed on arrow entry so nested arrows
  do not inherit it).
- `src/lumen_check_expr.zig`: an expression-body arrow with no return annotation
  whose body cannot self-type falls back to checking the body against
  `arrow_return_hint`.
- `src/lumen_check_stdlib.zig`: `reduce`/`reduceRight` set the hint to the
  accumulator type around the callback check.

## Verification

- `zig build` and `zig build test` green.
- Single- and multi-field record reductions run correctly; scalar `reduce` and
  `map`/other callbacks are unchanged.
