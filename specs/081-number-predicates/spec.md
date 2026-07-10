# Spec 081: Number predicates and float constants

## Goal

The `Number` namespace (spec 080) could parse but not classify numbers. This
adds the standard numeric predicates (`isInteger`, `isFinite`, `isNaN`) and two
float constants (`EPSILON`, `MAX_VALUE`), rounding the namespace out for
validation and tolerance checks.

## Why additive, not breaking

Pure additions to `numberCallType` and the `Number.*` emit chain; the parse
functions are unchanged. The predicates evaluate their argument as `f64`, so
they work uniformly for integer and float inputs.

## API

- `Number.isInteger(x: number): bool` — true if `x` is finite and has no
  fractional part (always true for integer inputs).
- `Number.isFinite(x: number): bool` — true if `x` is not infinite or NaN
  (always true for integer inputs).
- `Number.isNaN(x: number): bool` — true if `x` is NaN (always false for
  integer inputs).
- `Number.EPSILON(): number` — the difference between 1 and the next
  representable `f64`.
- `Number.MAX_VALUE(): number` — the largest finite `f64`.

## Requirements

- **FR-001**: Each predicate takes one numeric argument and returns `bool`; each
  constant takes none and returns `f64`. A non-numeric argument reports
  `E_TYPE_MISMATCH`; a wrong argument count reports `E_ARG_COUNT`.
- **FR-002**: The predicates evaluate their argument (side effects run) and
  give the correct result for both integer and float inputs.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `Number.isInteger(5.0)` -> `true`, `Number.isInteger(3.14)` ->
  `false`, `Number.isNaN(7)` -> `false`, `Number.EPSILON()` -> `2.22e-16`,
  `Number.MAX_VALUE()` -> the largest `f64`.
- **SC-002**: `zig build` and `zig build test` stay green.
