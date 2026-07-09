# Spec 068: Math inverse trig, cbrt, atan2, hypot, E

## Goal

Spec 065 added the transcendentals backed by direct Zig builtins. This spec
adds the remaining common `Math` functions, which map to `std.math.*` rather
than a `@builtin`: the inverse trig trio (`asin`, `acos`, `atan`), the cube
root (`cbrt`), the two-argument `atan2` and `hypot`, and the `E` constant
(sibling of `PI`).

## Why additive, not breaking

Pure additions to `mathCallType` and the `Math.*` emit chain. Unary and binary
`std.math` groups share the same int->f64 argument coercion as `sqrt`/`pow`;
`E` mirrors `PI` exactly.

## API

- `Math.asin(n: number): number`, `Math.acos(n: number): number`,
  `Math.atan(n: number): number`, `Math.cbrt(n: number): number`
- `Math.atan2(y: number, x: number): number` — angle of the point `(x, y)`.
- `Math.hypot(x: number, y: number): number` — `sqrt(x*x + y*y)` without
  overflow.
- `Math.E(): number` — Euler's number, a zero-arg function like `Math.PI()`.

Integer arguments are coerced to `f64`. Binary functions require both arguments
to share one numeric type (same rule as `pow`/`max`/`min`).

## Requirements

- **FR-001**: Unary functions take one numeric argument; the binary functions
  take two same-typed numeric arguments; `E` takes none. Each returns `f64`.
- **FR-002**: A non-numeric or mismatched-type argument reports
  `E_TYPE_MISMATCH`; a wrong argument count reports `E_ARG_COUNT`.

### Diagnostics
Reuses `E_TYPE_MISMATCH`, `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `Math.cbrt(27)` -> `3`, `Math.hypot(3, 4)` -> `5`,
  `Math.atan2(0, 1)` -> `0`, `Math.E()` -> `2.718…`.
- **SC-002**: `zig build` and `zig build test` stay green.
