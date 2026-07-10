# Spec 095: Number.isSafeInteger

## Goal

Complete the `Number` predicate set with `isSafeInteger`, the standard check for
whether a value is an integer that can be represented exactly as an `f64`
(magnitude at most `2^53 - 1`).

## Why additive, not breaking

Pure addition to the `Number` predicate group in `numberCallType` and the
emit chain; it evaluates its argument as `f64` like `isInteger`, then also
bounds the magnitude.

## API

- `Number.isSafeInteger(x: number): bool` — true if `x` is finite, has no
  fractional part, and `|x| <= 2^53 - 1`.

## Requirements

- **FR-001**: Takes one numeric argument and returns `bool`; a non-numeric
  argument reports `E_TYPE_MISMATCH`, a wrong argument count reports
  `E_ARG_COUNT`.
- **FR-002**: The check is exact for integer inputs (always true — a 32-bit
  `int` is always safe) and correctly rejects fractional, infinite, or
  out-of-range float inputs.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `Number.isSafeInteger(42)` -> `true`,
  `Number.isSafeInteger(3.14)` -> `false`,
  `Number.isSafeInteger(Number.MAX_VALUE())` -> `false`,
  `Number.isSafeInteger(Number.POSITIVE_INFINITY())` -> `false`.
- **SC-002**: `zig build` and `zig build test` stay green.
