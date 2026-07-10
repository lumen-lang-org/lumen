# Spec 071: Math hyperbolic functions and named constants

## Goal

Round out `Math` with the hyperbolic family and the remaining standard named
constants. The hyperbolic functions (`sinh`, `cosh`, `tanh` and their inverses
`asinh`, `acosh`, `atanh`) join the existing unary `std.math` group; the
constants (`LN2`, `LN10`, `LOG2E`, `LOG10E`, `SQRT2`) join `PI`/`E` as zero-arg
functions.

## Why additive, not breaking

Pure additions. The six hyperbolic names slot into the unary-`std.math` emit
branch (`std.math.<name>(f64)`) with the same int->f64 coercion; each constant
lowers to its `std.math` value exactly like `PI`/`E`.

## API

- `Math.sinh(n)`, `Math.cosh(n)`, `Math.tanh(n)`, `Math.asinh(n)`,
  `Math.acosh(n)`, `Math.atanh(n)` — `number -> number`.
- `Math.LN2()`, `Math.LN10()`, `Math.LOG2E()`, `Math.LOG10E()`,
  `Math.SQRT2()` — zero-arg `() -> number` constants, like `Math.PI()`.

Integer arguments to the functions are coerced to `f64`.

## Requirements

- **FR-001**: Each function takes one numeric argument and returns `f64`; each
  constant takes no arguments and returns `f64`.
- **FR-002**: A non-numeric argument reports `E_TYPE_MISMATCH`; a wrong argument
  count (including passing arguments to a constant) reports `E_ARG_COUNT`.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `Math.cosh(0)` -> `1`, `Math.tanh(0)` -> `0`, `Math.acosh(1)` ->
  `0`, `Math.LN2()` -> `0.693…`, `Math.SQRT2()` -> `1.414…`.
- **SC-002**: `zig build` and `zig build test` stay green.
