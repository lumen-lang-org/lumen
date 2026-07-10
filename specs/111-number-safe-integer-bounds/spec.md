# Spec 111: Number.MAX_SAFE_INTEGER / MIN_SAFE_INTEGER

## Goal

Complete the `Number` constant set with the safe-integer bounds — the largest
and smallest integers representable exactly as an `f64` (`±(2^53 - 1)`). They
pair with `Number.isSafeInteger` (spec 095) for range checks.

## Why additive, not breaking

Pure additions to the zero-arg `Number` constant group in `numberCallType` and
the emit chain; nothing existing changes.

## API

- `Number.MAX_SAFE_INTEGER(): number` — `9007199254740991`.
- `Number.MIN_SAFE_INTEGER(): number` — `-9007199254740991`.

Both are `f64` (the value is exact in `f64`, but does not fit `int`).

## Requirements

- **FR-001**: Each takes no arguments and returns `f64`; passing an argument
  reports `E_ARG_COUNT`.
- **FR-002**: The values interoperate with `Number.isSafeInteger`:
  `isSafeInteger(MAX_SAFE_INTEGER())` is `true`, and one past it is `false`.

### Diagnostics
Reuses `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `Number.MAX_SAFE_INTEGER()` -> `9007199254740991`,
  `Number.MIN_SAFE_INTEGER()` -> `-9007199254740991`,
  `Number.isSafeInteger(Number.MAX_SAFE_INTEGER())` -> `true`,
  `Number.isSafeInteger(Number.MAX_SAFE_INTEGER() + 1.0)` -> `false`.
- **SC-002**: `zig build` and `zig build test` stay green.
