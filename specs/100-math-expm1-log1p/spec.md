# Spec 100: Math.expm1 / Math.log1p

## Goal

`expm1(x)` computes `e^x - 1` and `log1p(x)` computes `ln(1 + x)`, both with
extra precision near zero where the naive `exp(x) - 1` / `log(1 + x)` lose
significant digits. They're the standard tools for small-rate financial and
scientific math.

## Why additive, not breaking

Pure additions to the unary `std.math` group in `mathCallType` and the emit
chain; they inherit the group's int->f64 argument coercion and `f64` result.

## API

- `Math.expm1(n: number): number` — `e^n - 1`.
- `Math.log1p(n: number): number` — `ln(1 + n)`.

Integer arguments are coerced to `f64`.

## Requirements

- **FR-001**: Each takes one numeric argument and returns `f64`; a non-numeric
  argument reports `E_TYPE_MISMATCH`, a wrong argument count reports
  `E_ARG_COUNT`.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `Math.expm1(0)` -> `0`, `Math.log1p(0)` -> `0`,
  `Math.expm1(1)` -> `1.718…`, `Math.log1p(1)` -> `0.693…`.
- **SC-002**: `zig build` and `zig build test` stay green.
