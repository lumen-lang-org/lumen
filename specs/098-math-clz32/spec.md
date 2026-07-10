# Spec 098: Math.clz32

## Goal

`Math.clz32` counts the leading zero bits in a value's 32-bit representation —
the standard primitive for computing integer log2, bit-width, and fast
normalization.

## Why additive, not breaking

Pure addition to `mathCallType` and the `Math.*` emit chain; nothing existing
changes.

## API

- `Math.clz32(x: int): int` — the number of leading zero bits in the unsigned
  32-bit representation of `x`, in `[0, 32]`.

## Requirements

- **FR-001**: Takes exactly one integer argument and returns `int`; a
  non-integer argument reports `E_TYPE_MISMATCH`, a wrong argument count reports
  `E_ARG_COUNT`.
- **FR-002**: `clz32(0)` is `32`; a value with the high bit set is `0`.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `Math.clz32(1)` -> `31`, `Math.clz32(0)` -> `32`,
  `Math.clz32(255)` -> `24`, `Math.clz32(-1)` -> `0`.
- **SC-002**: `zig build` and `zig build test` stay green.
