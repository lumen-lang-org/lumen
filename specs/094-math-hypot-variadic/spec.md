# Spec 094: variadic Math.hypot

## Goal

`Math.hypot` accepted exactly two arguments. In JavaScript it takes any number
of arguments and returns the square root of the sum of their squares (the
Euclidean norm in N dimensions). This makes it variadic.

## Why additive, not breaking

Pure relaxation of `Math.hypot`'s argument rule: two arguments behave exactly as
before. `atan2` remains strictly binary. All `hypot` arguments must share one
numeric type (the existing same-type rule).

## API

- `Math.hypot(a: number, b: number, ...rest: number): number` — `sqrt(a² + b²
  + …)`, computed as a left fold of the overflow-safe two-argument
  `std.math.hypot` so intermediate squares don't overflow.

At least two arguments are required, all of the same numeric type.

## Requirements

- **FR-001**: Fewer than two arguments reports `E_ARG_COUNT`. Every argument
  must be numeric and of the same type as the first; a mismatch reports
  `E_TYPE_MISMATCH`. `atan2` still requires exactly two arguments.
- **FR-002**: The result is `f64`.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `Math.hypot(3, 4)` -> `5`, `Math.hypot(2, 3, 6)` -> `7`,
  `Math.hypot(1, 2, 2, 4)` -> `5`.
- **SC-002**: `zig build` and `zig build test` stay green.
