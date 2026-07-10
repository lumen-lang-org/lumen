# Spec 126: Number.NaN

## Goal

Complete the `Number` constant set with `Number.NaN()` — the namespaced form of
the not-a-number value, alongside the bare global `NaN` (spec 122).

## Why additive, not breaking

Pure addition to the zero-arg `Number` constant group in `numberCallType` and
the emit chain; it lowers to `std.math.nan(f64)`.

## API

- `Number.NaN(): number` — not-a-number.

## Requirements

- **FR-001**: Takes no arguments and returns `f64`; passing an argument reports
  `E_ARG_COUNT`.
- **FR-002**: Interoperates with the predicates: `isNaN(Number.NaN())` is
  `true`, `isFinite(Number.NaN())` is `false`.

### Diagnostics
Reuses `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `isNaN(Number.NaN())` -> `true`, `isFinite(Number.NaN())` ->
  `false`.
- **SC-002**: `zig build` and `zig build test` stay green.
