# 419 — reduce accumulator widening + integer-literal ternary in arithmetic

Two related numeric fixes found while probing `reduce` over tuple/record arrays.

## Problem 1 — reduce accumulator width

`reduce` fixed the accumulator type from the seed *before* checking the
callback, so an integer-literal seed whose body folds at a wider numeric type
(e.g. summing an `f64` tuple/record field) mismatched:

```ts
const pairs: [string, number][] = [["a", 1], ["b", 2]];
pairs.reduce((acc, p) => acc + p[1], 0); // error: type mismatch
```

Spec 394 only widened the seed when the array *element* was `f64`/`i64`; here the
element is a tuple and the width comes from a field.

## Problem 2 — integer-literal ternary in a runtime arithmetic context

An integer-literal conditional used in arithmetic inside an arrow/callback body
produced `comptime_int` branches Zig rejects at runtime:

```ts
[1,2,3,4].map(x => x + (x > 2 ? 1 : 0)); // backend: comptime_int depends on runtime control flow
```

The ternary emitted `if (cond) 1 else 0` with no type cast, so two literal
branches stayed `comptime_int`.

## Approach

- **reduce** (`lumen_check_methods.zig`): after checking the callback, if the
  seed is an integer literal, the accumulator is `i32`, and the callback returns
  `f64`/`i64`, widen the seed to that return type and re-check the callback with
  the widened accumulator.
- **ternary** (`lumen_check_expr.zig`): pin a scalar-numeric ternary's
  `result_type` to its type, so the emitter wraps both branches in `@as(T, …)` —
  making integer-literal branches concrete `i32` rather than `comptime_int`.

## Verification

- `pairs.reduce((acc,p) => acc + p[1], 0)` (tuple) → `3`; record-field reduce → `4`.
- `x + (x > 2 ? 1 : 0)` in `map`, arrow, and `reduce` bodies compile and run.
- Integer, `f64`, object-seed, and string-concat reduces unchanged.
- Standalone int ternary, `f64` ternary, string ternary, nested ternary, and
  ternary-in-template all correct.
- Full `zig build` + test suite green.

## Notes

Both are part of the numeric-literal-width family (specs 394, 402–405, 415–417).
