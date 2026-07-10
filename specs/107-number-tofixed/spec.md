# Spec 107: number toFixed

## Goal

Formatting a number with a fixed number of decimals (money, percentages,
tables) required manual work. `toFixed` is the standard method; adding it also
introduces the first *instance* method on a numeric receiver, opening the door
to more number methods later.

## Why additive, not breaking

New capability: a numeric receiver (`int` or `f64`) now dispatches to
`numberInstanceMethod` in the method-call checker, alongside string/array/map.
A `number_method` flag on the method-call node routes codegen to the toFixed
lowering. Nothing existing changes.

## API

Instance method on any numeric value:

- `toFixed(digits: int): string` — the receiver formatted as a fixed-point
  decimal string with exactly `digits` fractional digits. Integer receivers are
  formatted as `f64`.

## Requirements

- **FR-001**: `toFixed` takes exactly one integer argument and returns `string`;
  a non-integer argument reports `E_TYPE_MISMATCH`, a wrong argument count
  reports `E_ARG_COUNT`. An unknown method on a numeric receiver reports
  `E_TYPE_MISMATCH`.
- **FR-002**: The result has exactly `digits` digits after the decimal point
  (none, and no point, when `digits` is `0`).

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `(3.14159).toFixed(2)` -> `"3.14"`, `(3.14159).toFixed(0)` ->
  `"3"`, `(9.5).toFixed(2)` -> `"9.50"`, and an `int` receiver `(5).toFixed(2)`
  -> `"5.00"`.
- **SC-002**: `zig build` and `zig build test` stay green.
