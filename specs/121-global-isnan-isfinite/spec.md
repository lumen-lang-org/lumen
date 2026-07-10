# Spec 121: global isNaN / isFinite

## Goal

`isNaN(x)` and `isFinite(x)` are global functions in JavaScript. Supporting the
bare global names complements `Number.isNaN` / `Number.isFinite` (spec 081).

## Why additive, not breaking

The bare names are recognized as builtins only when no user function shadows
them, and return `bool`. Codegen coerces the argument to `f64` with a
`@typeInfo`-based comptime branch so the same emit works for integer and float
inputs (including literals). The `is_global_parse` flag marks the recognized
builtin so user overrides emit normally.

## API

- `isNaN(x: number): bool` — whether `x` is NaN.
- `isFinite(x: number): bool` — whether `x` is finite.

## Requirements

- **FR-001**: Each takes one numeric argument and returns `bool`; a non-numeric
  argument reports `E_TYPE_MISMATCH`, a wrong count reports `E_ARG_COUNT`.
- **FR-002**: A user-defined function named `isNaN`/`isFinite` shadows the
  global.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `isNaN(3.14)` -> `false`, `isFinite(10)` -> `true`,
  `isFinite(Number.POSITIVE_INFINITY())` -> `false`.
- **SC-002**: `zig build` and `zig build test` stay green.
