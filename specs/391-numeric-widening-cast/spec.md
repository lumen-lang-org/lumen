# 391 — Numeric `as` casts (`i32 as f64`, `f64 as i32`)

## Problem

`x as f64` on an integer expression was rejected (`E_TYPE_MISMATCH`), even though
the same widening happens implicitly in assignment and argument position:

```ts
Math.sqrt((x * x + y * y) as f64)   // error — `as` is representation-preserving
```

`as` was defined as representation-preserving only, and int→float changes the
runtime representation.

## Change

`lumen_check_expr.zig`, the `.cast` case: recognize numeric widening and convert
rather than assert.

- `<int> as f64` — rewrite the cast to the `Number(...)` promotion (the same
  node assignment/argument coercion emits), yielding `f64`.
- `i32 as i64` — a lossless widening the backend coerces directly; keep the
  operand and retype.
- `<f64> as i32` / `as i64` — truncates toward zero (`@intFromFloat(@trunc(...))`),
  via a `float_to_int` flag on the cast node.

Other `as` casts (literal-union → string, alias ↔ underlying, identity) go
through the existing representation-preserving `castAllowed` check unchanged.

## Verified

`zig build` + `zig build test` green. Probes:

- `x as f64` (x: i32) → usable as a float (`f / 2.0` = `2.5`).
- `(x*x + y*y) as f64` inside `Math.sqrt` → `5`.
- `x as i64` → `15` (`5 * 3` at i64).
- `Point.dist()` computing `Math.sqrt((…) as f64)` → `5`.
- `(3.7) as i32` = `3`, `(-3.7) as i32` = `-3` (truncation matches Node's `Math.trunc`).
- Round-trip `i as f64` then `(f * 2.0) as i32` = `10`.
- `s as string` on a string-literal union still works.
