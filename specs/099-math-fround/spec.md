# Spec 099: Math.fround

## Goal

`Math.fround` rounds a number to the nearest value representable as a 32-bit
float, then returns it as a normal number. It's the standard way to emulate
single-precision arithmetic or match values produced by float32 buffers.

## Why additive, not breaking

Pure addition to `mathCallType` and the `Math.*` emit chain; nothing existing
changes.

## API

- `Math.fround(x: number): number` — `x` coerced to `f32` and back to `f64`.
  Integer arguments are coerced to `f64` first.

## Requirements

- **FR-001**: Takes exactly one numeric argument and returns `f64`; a
  non-numeric argument reports `E_TYPE_MISMATCH`, a wrong argument count reports
  `E_ARG_COUNT`.
- **FR-002**: The result is the nearest 32-bit-float value, so values not
  exactly representable in `f32` (e.g. `1.1`) round accordingly.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `Math.fround(1.5)` -> `1.5`, `Math.fround(5)` -> `5`,
  `Math.fround(1.1)` -> `1.100000023841858`.
- **SC-002**: `zig build` and `zig build test` stay green.
