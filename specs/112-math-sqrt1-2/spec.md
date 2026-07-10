# Spec 112: Math.SQRT1_2

## Goal

`Math.SQRT1_2` is `1/sqrt(2)` (~0.7071), the last of the standard JavaScript
`Math` named constants Lumen was missing. Adding it completes the set
(`PI, E, LN2, LN10, LOG2E, LOG10E, SQRT2, SQRT1_2`).

## Why additive, not breaking

Pure addition to the zero-arg `Math` constant group in `mathCallType` and the
emit chain; it lowers to `std.math.sqrt1_2`.

## API

- `Math.SQRT1_2(): number` — the square root of 1/2.

## Requirements

- **FR-001**: Takes no arguments and returns `f64`; passing an argument reports
  `E_ARG_COUNT`.

### Diagnostics
Reuses `E_ARG_COUNT`.

## Success Criteria

- **SC-001**: `Math.SQRT1_2()` -> `0.7071067811865476`, and
  `Math.SQRT1_2() * Math.SQRT2()` is `~1`.
- **SC-002**: `zig build` and `zig build test` stay green.
