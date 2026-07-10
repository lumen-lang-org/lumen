# Spec 096: Math.exp2

## Goal

The unary transcendental group had `exp` (base e) and `log2` but not `exp2`
(base 2). `Math.exp2(x)` computes `2^x`, the natural companion to `log2` and a
common building block for bit-width and scaling math.

## Why additive, not breaking

Pure addition to the unary `Math` builtin group: `exp2` slots in next to
`exp`/`log2`, lowering to the Zig `@exp2` builtin with the same int->f64
argument coercion and `f64` result.

## API

- `Math.exp2(n: number): number` — `2^n`. Integer arguments are coerced to
  `f64`.

## Requirements

- **FR-001**: Takes exactly one numeric argument and returns `f64`. A
  non-numeric argument reports `E_TYPE_MISMATCH`; a wrong argument count reports
  `E_ARG_COUNT`.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `Math.exp2(0)` -> `1`, `Math.exp2(3)` -> `8`,
  `Math.exp2(10)` -> `1024`, `Math.exp2(0.5)` -> `1.414…`.
- **SC-002**: `zig build` and `zig build test` stay green.
