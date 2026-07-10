# Spec 110: number toExponential

## Goal

`toExponential` formats a number in exponential (scientific) notation, with an
optional number of fraction digits — the standard form for very large/small
magnitudes.

## Why additive, not breaking

Pure addition to `numberInstanceMethod` (spec 107) and the number-method emit
branch; nothing existing changes.

## API

Instance method on any numeric value:

- `toExponential(digits?: int): string` — the receiver in exponential notation.
  With `digits`, exactly that many fraction digits; without, as many as needed.
  The exponent always carries a sign (`e+4`, `e-4`) to match JavaScript.

## Requirements

- **FR-001**: Takes zero or one integer argument and returns `string`; a
  non-integer argument reports `E_TYPE_MISMATCH`, more than one reports
  `E_ARG_COUNT`.
- **FR-002**: A positive exponent is written with an explicit `+` (Zig omits it,
  so codegen inserts it), matching JavaScript's `toExponential`.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `(12345.678).toExponential(2)` -> `"1.23e+4"`,
  `(12345.678).toExponential()` -> `"1.2345678e+4"`,
  `(0.00012).toExponential(2)` -> `"1.20e-4"`, `(100).toExponential(1)` ->
  `"1.0e+2"`.
- **SC-002**: `zig build` and `zig build test` stay green.
