# Spec 082: variadic Math.min / Math.max

## Goal

`Math.min`/`Math.max` accepted exactly two arguments, so reducing a handful of
values meant nesting calls. This makes them variadic (two or more arguments), as
in JavaScript.

## Why additive, not breaking

Pure relaxation of the existing `Math.min`/`Math.max` argument rule: two
arguments behave exactly as before; additional arguments extend the reduction.
All arguments must share one numeric type (the existing same-type rule).

## API

- `Math.max(a: number, b: number, ...rest: number): number` — the largest
  argument.
- `Math.min(a: number, b: number, ...rest: number): number` — the smallest
  argument.

At least two arguments are required, all of the same numeric type.

## Requirements

- **FR-001**: Fewer than two arguments reports `E_ARG_COUNT`. Every argument
  must be numeric and of the same type as the first; a mismatch reports
  `E_TYPE_MISMATCH`.
- **FR-002**: The result type equals the shared argument type.
- **FR-003**: The two-argument form behaves exactly as before.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `Math.max(3, 1, 4, 1, 5, 9, 2, 6)` -> `9`,
  `Math.min(3, 1, 4, 1, 5, 9, 2, 6)` -> `1`, `Math.max(-5, -2, -9)` -> `-2`,
  `Math.max(1.5, 2.5, 0.5)` -> `2.5`.
- **SC-002**: `zig build` and `zig build test` stay green.
